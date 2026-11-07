import
  std/exitprocs,
  std/posix,
  os,
  net,
  selectors,
  strutils,
  strformat,
  tables,
  parsetoml

import
  nimdowpkg/windowmanager,
  nimdowpkg/tray/tray,
  nimdowpkg/config/configloader,
  nimdowpkg/ipc/cli,
  nimdowpkg/ipc/ipc,
  nimdowpkg/wmcommands,
  nimdowpkg/spawn,
  nimdowpkg/logger

proc handleCommand(str: string, windowmanager: WindowManager) =
  ## Runs the action for an IPC message: `nimdow-ipc <command> [argument]`.
  ## The argument (e.g. a tag number for `goToTag`) is passed as the key.
  let split = str.split()
  if split.len < 2:
    log "Not enough arguments.", lvlWarn
    return

  if split[0] != ipcPrefix:
    log fmt"Commands must be prefixed with {ipcPrefix}", lvlWarn
    return

  let command = split[1].toLower()
  if command == $wmcStatus:
    # The status text keeps its whitespace: everything after the command.
    let parts = str.split(' ', maxsplit = 2)
    windowmanager.setStatus(if parts.len > 2: parts[2] else: "")
    windowmanager.markDirty()
    return

  let commandOpt = parseCommand(command)
  if commandOpt.isSome:
    let table = windowmanager.config.actionIdentifierTable
    if table.hasKey(command):
      let arg = if split.len > 2: split[2] else: ""
      table[command]((arg, 0'u32))
      # The state changed outside of a manage sequence: have River start one.
      windowmanager.markDirty()

proc fatal(msg: string) =
  stderr.writeLine msg
  quit(1)

when isMainModule:
  if not cli.handleCommandLineParams():
    quit()

  let loadedConfig = newConfig()

  var configTable: TomlTable
  try:
    configTable = loadConfigFile()
  except:
    log getCurrentExceptionMsg(), lvlError

  # Reap spawned processes (autostart and key bindings).
  installChildReaper()

  var nimdow: WindowManager
  try:
    nimdow = newWindowManager(loadedConfig, configTable)
  except:
    fatal getCurrentExceptionMsg()

  addExitProc(proc() =
    discard tryRemoveFile(ipc.socketLoc)
  )

  logger.enabled = loadedConfig.loggingEnabled

  log "Starting Nimdow " & version

  nimdow.startTray()

  try:
    loadedConfig.populateAppRules(configTable)
    loadedConfig.runAutostartCommands(configTable)
  except:
    log getCurrentExceptionMsg(), lvlError

  let
    selector = newSelector[int]()
    display = nimdow.display
    displayFd = display.fd().int
    ipcSocket = ipc.initIPCSocket()
    ipcSocketFd = ipcSocket.getFd().int

  selector.registerHandle(displayFd, {Event.Read}, 0)
  selector.registerHandle(ipcSocketFd, {Event.Read}, 1)

  # The tray's D-Bus connection (-1 while it is not registered with the selector).
  var trayFd = -1

  while true:
    # Standard libwayland read protocol: dispatch whatever is queued, flush our
    # requests, wait for the sockets, then read and dispatch.
    prepareRead(display)

    var flushed = true
    if display.flush() < 0:
      if errno != EAGAIN:
        display.cancelRead()
        fatal "flush failed"
      flushed = false
    selector.updateHandle(
      displayFd,
      if flushed: {Event.Read} else: {Event.Read, Event.Write}
    )

    # The D-Bus connection: wait for what sd-bus asks for, wake up for its
    # timeouts and for the tray's debounced refetches.
    var
      busReadable = false
      timeout = -1
    let tray = nimdow.tray
    if tray != nil and tray.alive:
      let events = tray.events()
      var wanted: set[Event] = {Event.Read}
      if (events and POLLOUT.int) != 0: wanted.incl Event.Write
      if trayFd < 0:
        trayFd = tray.fd()
        selector.registerHandle(trayFd, wanted, 2)
      else:
        selector.updateHandle(trayFd, wanted)
      timeout = tray.timeoutMs()
    elif trayFd >= 0:
      selector.unregister(trayFd)
      trayFd = -1

    var displayReadable, ipcReadable = false
    for event in selector.select(timeout):
      if event.fd == displayFd:
        if Event.Read in event.events or Event.Error in event.events:
          displayReadable = true
      elif event.fd == ipcSocketFd:
        ipcReadable = true
      elif event.fd == trayFd:
        busReadable = true

    if displayReadable:
      if display.readEvents() < 0: fatal "failed to read Wayland events"
    else:
      display.cancelRead()

    if ipcReadable:
      var client: Socket
      try:
        ipcSocket.accept(client, flags = {})
        let received = client.recv(MaxLineLength)
        client.close()
        handleCommand(received, nimdow)
      except:
        # Client disconnected when we tried to accept.
        discard

    # Always processed (not only when readable): sd-bus may have queued
    # messages or timeouts, and due refetches run here. Never blocks.
    if tray != nil and tray.alive:
      tray.process()
      discard busReadable

    if display.dispatchPending() < 0: fatal "failed to dispatch Wayland events"
