import
  std/[options, tables, sets, math, strutils, sequtils, os, algorithm, parseutils],
  parsetoml

import
  taggedclients,
  monitor,
  statusbar,
  tag,
  area,
  config/configloader,
  config/apprules,
  layouts/[layout, masterstacklayout],
  keys/keyutils,
  wmcommands,
  wl/client as wlclient,
  wl/protocols/[river_window_management_v1, river_xkb_bindings_v1, river_layer_shell_v1],
  logger,
  listutils

export wlclient

## The River window manager.
##
## River is double buffered: event handlers and actions only mutate nimdow's own
## state (Client, Monitor, TaggedClients). The state is flushed to River in
##  - `manage_start`: show/hide, propose_dimensions, focus_window, close,
##    binding setup; ends with `manage_finish`.
##  - `render_start`: set_position, set_borders, stacking; ends with
##    `render_finish`.
## Actions invoked outside of a manage sequence (IPC) call `markDirty` so River
## starts a manage sequence.

type
  Output = ref object
    obj: RiverOutputV1
    x, y, width, height: int32
    hasGeometry: bool
    removed: bool
    monitor: Monitor
    ## Nil when the layer shell is unavailable.
    layerOutput: RiverLayerShellOutputV1
    ## The area left by layer surfaces' exclusive zones (global coordinates).
    freeX, freeY, freeWidth, freeHeight: int32
    hasFreeArea: bool

  XkbBinding = ref object
    obj: RiverXkbBindingV1
    combo: KeyCombo

  PointerBinding = ref object
    obj: RiverPointerBindingV1
    seat: Seat
    kind: PointerRequestKind

  SeatOp = enum
    soNone, soMove, soResize

  ## Keyboard focus held by a layer shell surface (launcher, lock screen, ...).
  LayerFocus = enum
    lfNone, lfNonExclusive, lfExclusive

  Seat = ref object
    obj: RiverSeatV1
    isNew, removed: bool
    layerSeat: RiverLayerShellSeatV1
    layerFocus: LayerFocus
    xkbBindings: seq[XkbBinding]
    pointerBindings: seq[PointerBinding]
    ## Window under the pointer.
    hovered: Window
    pointerX, pointerY: int32
    pointerChanged: bool
    ## Set by a pointer binding (modKey + button) and handled in the manage sequence.
    pendingPointerOp: PointerRequestKind
    # Interactive move/resize (river_seat_v1.op_start_pointer).
    op: SeatOp
    opClient: Client
    ## The client's area when its first op_delta arrived.
    opStart: Area
    ## The client has been made floating and the start area was recorded.
    opStarted: bool
    opDx, opDy: int32
    opRelease: bool
    opEdges: uint32
    ## Window that was last sent to River as keyboard focus.
    focused: Window
    ## Window interacted with (clicked) since the last manage sequence.
    interacted: Window

  WindowManager* = ref object
    display*: WlDisplay
    manager: RiverWindowManagerV1
    xkbBindings: RiverXkbBindingsV1
    ## Nil when River does not offer layer shell: layer surfaces are then
    ## closed by River.
    layerShell: RiverLayerShellV1
    ## The output set as default for new layer surfaces.
    layerDefault: Output
    config*: Config
    outputs: seq[Output]
    monitors: OrderedTable[MonitorID, Monitor]
    selectedMonitor: Monitor
    seats: seq[Seat]
    ## Clients that are not on any monitor (new, or their monitor went away).
    unassigned: seq[Client]
    ## Hidden clients, not on any monitor. Last in, first out.
    scratchpad: seq[Client]
    ## The pointer is moved here (to the client, else the monitor's center) in
    ## the next manage sequence.
    warpMonitor: Monitor
    warpClient: Client
    nextMonitorID: MonitorID
    ## Nil when the status bar is unavailable.
    barCtx: BarContext
    ## The status as set with `setStatus` (may contain per monitor statuses).
    status: string
    ## Key combos pressed since the last manage sequence.
    pressedCombos: seq[KeyCombo]
    bindingsDirty: bool

const
  ## Per monitor statuses: "NIMDOW_MONITOR_INDEX=0 first NIMDOW_MONITOR_INDEX=1 second"
  StatusMonitorPrefix = "NIMDOW_MONITOR_INDEX="

var wm: WindowManager

proc mapConfigActions*(this: WindowManager)

proc markDirty*(this: WindowManager) =
  ## Ask River to start a manage sequence (used after actions that ran
  ## outside of one).
  river_window_manager_v1_manage_dirty(this.manager)

template dropAt[T](s: var seq[T], item: T) =
  let i = s.find(item)
  if i >= 0: s.delete i

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

iterator allClients(this: WindowManager): Client =
  for monitor in this.monitors.values():
    for client in monitor.clients.items:
      yield client

proc findClient(this: WindowManager, window: Window): Client =
  for client in this.allClients:
    if client.window == window:
      return client
  for client in this.unassigned:
    if client.window == window:
      return client
  for client in this.scratchpad:
    if client.window == window:
      return client

proc sortedMonitors(this: WindowManager): seq[Monitor] =
  ## Monitors ordered by position (x, then y).
  for monitor in this.monitors.values():
    result.add monitor
  result.sort(proc(a, b: Monitor): int =
    result = cmp(a.area.x, b.area.x)
    if result == 0:
      result = cmp(a.area.y, b.area.y)
  )

proc applyStatus(this: WindowManager) =
  ## Hands the status to the bars of all monitors.
  let statuses = this.status.split(StatusMonitorPrefix)
  if statuses.len == 1:
    for monitor in this.monitors.values():
      if monitor.statusBar != nil:
        monitor.statusBar.setStatus(statuses[0])
    return
  try:
    for rawStatus in statuses[1 .. statuses.high]:
      let
        monitorIndexAsStr = rawStatus[0 .. skipUntil(rawStatus, Whitespace) - 1]
        monitorID = parseInt(monitorIndexAsStr) + 1
      if not this.monitors.hasKey(monitorID):
        raise newException(ValueError, "monitor index " & monitorIndexAsStr & " is out of range")
      let monitor = this.monitors[monitorID]
      if monitor.statusBar != nil:
        var status = rawStatus
        status.removePrefix(monitorIndexAsStr)
        monitor.statusBar.setStatus(status)
  except ValueError:
    let msg = getCurrentExceptionMsg()
    for monitor in this.monitors.values():
      if monitor.statusBar != nil:
        monitor.statusBar.setStatus(msg)
    log msg, lvlError

proc setStatus*(this: WindowManager, status: string) =
  ## Sets the text shown on the right of the status bars (`nimdow --status`).
  ## The caller must `markDirty` so the bars are redrawn.
  this.status = status
  this.applyStatus()

proc monitorOf(this: WindowManager, client: Client): Monitor =
  for monitor in this.monitors.values():
    if monitor.clients.find(client.window) != nil:
      return monitor

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc findRelativeTag(this: WindowManager, offset: int): Tag =
  let selectedTag = this.selectedMonitor.taggedClients.findFirstSelectedTag
  if selectedTag.isNil:
    return

  var tagNumber = abs((selectedTag.id + offset) mod this.selectedMonitor.tags.len)
  if tagNumber <= 0:
    tagNumber = this.selectedMonitor.tags.len
  return this.selectedMonitor.tags[tagNumber - 1]

template findLeftTag(this: WindowManager): Tag =
  this.findRelativeTag(-1)

template findRightTag(this: WindowManager): Tag =
  this.findRelativeTag(1)

proc increaseMasterCount(this: WindowManager) =
  let firstSelectedTag = this.selectedMonitor.taggedClients.findFirstSelectedTag()
  if firstSelectedTag == nil:
    return

  var layout = firstSelectedTag.layout
  if layout of MasterStackLayout:
    MasterStackLayout(layout).masterSlots.inc
    this.selectedMonitor.doLayout()

proc decreaseMasterCount(this: WindowManager) =
  let firstSelectedTag = this.selectedMonitor.taggedClients.findFirstSelectedTag()
  if firstSelectedTag == nil:
    return

  var layout = firstSelectedTag.layout
  if layout of MasterStackLayout:
    var masterStackLayout = MasterStackLayout(layout)
    if masterStackLayout.masterSlots.int > 0:
      masterStackLayout.masterSlots.dec
      this.selectedMonitor.doLayout()

proc goToTag(this: WindowManager, tagID: TagID) =
  # Check if only the same tag is shown
  let selectedTags = this.selectedMonitor.selectedTags

  var destTag = tagID
  if selectedTags.len == 1:
    # Find the only selected tag
    var selectedTag: TagID
    for tag in selectedTags:
      selectedTag = tag
      break

    # If attempting to select the same single tag, view the previous tag instead.
    if this.selectedMonitor.previousTagID != 0 and selectedTag == destTag:
      destTag = this.selectedMonitor.previousTagID

    # Swap the previous tag.
    this.selectedMonitor.previousTagID = selectedTag

  this.selectedMonitor.setSelectedTags(destTag)

template modWidthDiff(this: WindowManager, diff: int) =
  let firstTag = this.selectedMonitor.taggedClients.findFirstSelectedTag
  if firstTag != nil and firstTag.layout of MasterStackLayout:
    let masterStackLayout = cast[MasterStackLayout](firstTag.layout)
    let screenWidth = masterStackLayout.calcScreenWidth(this.selectedMonitor.layoutOffset)

    if
      (diff > 0 and masterStackLayout.widthDiff < 0) or
      (diff < 0 and masterStackLayout.widthDiff > 0) or
      masterStackLayout.calcClientWidth(screenWidth.uint).int - abs(masterStackLayout.widthDiff).int - abs(
          diff).int > 0:
        masterStackLayout.widthDiff += diff
        this.selectedMonitor.doLayout()

proc increaseMasterWidth(this: WindowManager) =
  this.modWidthDiff(this.selectedMonitor.monitorSettings.layoutSettings.resizeStep.int)

proc decreaseMasterWidth(this: WindowManager) =
  this.modWidthDiff(-this.selectedMonitor.monitorSettings.layoutSettings.resizeStep.int)

proc destroySelectedWindow*(this: WindowManager) =
  ## Asks the selected window to close (sent during the next manage sequence).
  this.selectedMonitor.taggedClients.withSomeCurrClient(client):
    client.closeRequested = true

proc focusMonitor(this: WindowManager, monitor: Monitor) =
  ## Selects the monitor; the pointer follows to its current client.
  if monitor == nil:
    return
  this.selectedMonitor = monitor
  this.warpMonitor = monitor
  this.warpClient = monitor.taggedClients.currClient

proc focusMonitorIndex(this: WindowManager, index: int) =
  ## `index` is zero-based, in position order.
  let monitors = this.sortedMonitors()
  if index in 0 .. monitors.high:
    this.focusMonitor(monitors[index])

proc focusNextMonitor(this: WindowManager) =
  let monitors = this.sortedMonitors()
  this.focusMonitorIndex(monitors.findNext(this.selectedMonitor))

proc focusPreviousMonitor(this: WindowManager) =
  let monitors = this.sortedMonitors()
  this.focusMonitorIndex(monitors.findPrevious(this.selectedMonitor))

proc moveClientToMonitor(
  this: WindowManager,
  client: Client,
  destination: Monitor,
  keepPosition: bool = false
) =
  ## Moves the client to the selected tags of `destination`, which becomes the
  ## selected monitor. A floating client keeps its offset in the monitor
  ## (or its absolute position if `keepPosition`).
  let start = this.monitorOf(client)
  if start == nil or destination == nil or start == destination:
    return

  if start.removeWindow(client.window):
    start.doLayout()

  if client.isFloating and not keepPosition:
    client.x = destination.area.x + (client.x - start.area.x)
    client.y = destination.area.y + (client.y - start.area.y)

  this.selectedMonitor = destination
  var c = client
  destination.addClient(c)
  if not keepPosition:
    # (A client dropped after a drag is already under the pointer.)
    this.warpMonitor = destination
    this.warpClient = client

proc moveSelectedClientToMonitor(this: WindowManager, destination: Monitor) =
  let client = this.selectedMonitor.taggedClients.currClient
  if client != nil:
    this.moveClientToMonitor(client, destination)

proc moveWindowToNextMonitor(this: WindowManager) =
  let monitors = this.sortedMonitors()
  let i = monitors.findNext(this.selectedMonitor)
  if i >= 0:
    this.moveSelectedClientToMonitor(monitors[i])

proc moveWindowToPreviousMonitor(this: WindowManager) =
  let monitors = this.sortedMonitors()
  let i = monitors.findPrevious(this.selectedMonitor)
  if i >= 0:
    this.moveSelectedClientToMonitor(monitors[i])

proc moveWindowToScratchpad(this: WindowManager) =
  let client = this.selectedMonitor.taggedClients.currClient
  if client == nil:
    return
  client.tagIDs.clear()
  discard this.selectedMonitor.removeWindow(client.window)
  this.selectedMonitor.doLayout()
  client.isVisible = false
  this.scratchpad.add client

proc popScratchpad(this: WindowManager) =
  if this.scratchpad.len == 0:
    return
  var client = this.scratchpad.pop()
  let monitor = this.selectedMonitor
  let settings = this.config.scratchpadSettings

  if not client.isFullscreen and not client.isFloating and not client.isFixedSize:
    client.borderWidth = this.config.windowSettings.borderWidth
    client.area = (
      monitor.area.x + (monitor.area.width.int - settings.width) div 2,
      monitor.area.y + (monitor.area.height.int - settings.height) div 2,
      max(1, settings.width).uint,
      max(1, settings.height).uint
    )
    client.isFloating = true
  else:
    let
      width = if client.width > 0: client.width.int else: client.reportedWidth
      height = if client.height > 0: client.height.int else: client.reportedHeight
    client.x = monitor.area.x + (monitor.area.width.int - width) div 2
    client.y = monitor.area.y + (monitor.area.height.int - height) div 2
  client.needsCenter = false
  monitor.addClient(client)
  this.warpMonitor = monitor
  this.warpClient = client

proc jumpToUrgentWindow(this: WindowManager) =
  ## Selects the first urgent client. River's window management protocol has no
  ## urgency event, so nothing ever marks a client urgent (`Client.setUrgent`
  ## is the hook for when it does); this is then a no-op.
  for monitor in this.sortedMonitors():
    for client in monitor.clientSelection:
      if client.isUrgent and client.tagIDs.len > 0:
        if not client.tagIDs.anyIt(monitor.selectedTags.contains(it)):
          for id in monitor.selectedTags:
            monitor.previousTagID = id
            break
          for id in client.tagIDs:
            monitor.setSelectedTags(id)
            break
        this.selectedMonitor = monitor
        monitor.setSelectedClient(client)
        this.warpMonitor = monitor
        this.warpClient = client
        return
  log "jumpToUrgentWindow: no urgent windows (River has no urgency event, " &
    "so windows are never marked urgent)", lvlInfo

proc reloadConfig*(this: WindowManager) =
  let
    oldConfig = this.config
    oldLoggingEnabled = logger.enabled

  this.config = newConfig()

  try:
    let configTable = configloader.loadConfigFile()
    this.config.populateAppRules(configTable)
    this.mapConfigActions()
    this.config.populateKeyComboTable(configTable)
    this.config.populateGeneralSettings(configTable)
    logger.enabled = this.config.loggingEnabled
  except:
    logger.enabled = oldLoggingEnabled
    # If the config fails to load, restore the old config.
    this.config = oldConfig
    log getCurrentExceptionMsg(), lvlError

  for monitor in this.monitors.mvalues():
    monitor.setConfig(this.config)

  # Bindings are re-created from the new key combos in the next manage sequence.
  this.bindingsDirty = true

template createControl(keyCombo: untyped, id: string, action: untyped) =
  this.config.configureAction(id, proc(keyCombo: KeyCombo) = action)

proc mapConfigActions*(this: WindowManager) =
  ## Maps available user configuration options to window manager actions.
  ## The `key` of the key combo is the argument for tag actions (a tag number).
  createControl(keyCombo, $wmcReloadConfig):
    this.reloadConfig()

  createControl(keyCombo, $wmcIncreaseMasterCount):
    this.increaseMasterCount()

  createControl(keyCombo, $wmcDecreaseMasterCount):
    this.decreaseMasterCount()

  createControl(keyCombo, $wmcMoveWindowToPreviousMonitor):
    this.moveWindowToPreviousMonitor()

  createControl(keyCombo, $wmcMoveWindowToNextMonitor):
    this.moveWindowToNextMonitor()

  createControl(keyCombo, $wmcFocusPreviousMonitor):
    this.focusPreviousMonitor()

  createControl(keyCombo, $wmcFocusNextMonitor):
    this.focusNextMonitor()

  createControl(keyCombo, $wmcGoToTag):
    var tagIDOpt = this.selectedMonitor.tagIDFromArg(keyCombo.key)
    if tagIDOpt.isSome:
      this.goToTag(tagIDOpt.get)

  createControl(keyCombo, $wmcGoToLeftTag):
    let leftTag = this.findLeftTag()
    if leftTag != nil:
      this.goToTag(leftTag.id)

  createControl(keyCombo, $wmcGoToRightTag):
    let rightTag = this.findRightTag()
    if rightTag != nil:
      this.goToTag(rightTag.id)

  createControl(keyCombo, $wmcGoToPreviousTag):
    var previousTag = this.selectedMonitor.previousTagID
    if previousTag != 0:
      this.goToTag(previousTag)

  createControl(keyCombo, $wmcMoveWindowToPreviousTag):
    var previousTagID = this.selectedMonitor.previousTagID
    if previousTagID != 0:
      this.selectedMonitor.moveSelectedWindowToTag(previousTagID)

  createControl(keyCombo, $wmcToggleTagView):
    let tagIDOpt = this.selectedMonitor.tagIDFromArg(keyCombo.key)
    if tagIDOpt.isSome:
      this.selectedMonitor.toggleTags(tagIDOpt.get)

  createControl(keyCombo, $wmcToggleWindowTag):
    this.selectedMonitor.taggedClients.withSomeCurrClient(client):
      let tagIDOpt = this.selectedMonitor.tagIDFromArg(keyCombo.key)
      if tagIDOpt.isSome:
        this.selectedMonitor.toggleTagsForClient(client, tagIDOpt.get)

  createControl(keyCombo, $wmcFocusNext):
    this.selectedMonitor.focusNextClient()

  createControl(keyCombo, $wmcFocusPrevious):
    this.selectedMonitor.focusPreviousClient()

  createControl(keyCombo, $wmcMoveWindowPrevious):
    this.selectedMonitor.moveClientPrevious()

  createControl(keyCombo, $wmcMoveWindowNext):
    this.selectedMonitor.moveClientNext()

  createControl(keyCombo, $wmcMoveWindowToTag):
    let tagIDOpt = this.selectedMonitor.tagIDFromArg(keyCombo.key)
    if tagIDOpt.isSome:
      this.selectedMonitor.moveSelectedWindowToTag(tagIDOpt.get)

  createControl(keyCombo, $wmcMoveWindowToLeftTag):
    let leftTag = this.findLeftTag()
    if leftTag != nil:
      this.selectedMonitor.moveSelectedWindowToTag(leftTag.id)

  createControl(keyCombo, $wmcMoveWindowToRightTag):
    let rightTag = this.findRightTag()
    if rightTag != nil:
      this.selectedMonitor.moveSelectedWindowToTag(rightTag.id)

  createControl(keyCombo, $wmcToggleFullscreen):
    this.selectedMonitor.toggleFullscreenForSelectedClient()

  createControl(keyCombo, $wmcDestroySelectedWindow):
    this.destroySelectedWindow()

  createControl(keyCombo, $wmcToggleFloating):
    this.selectedMonitor.toggleFloatingForSelectedClient()

  createControl(keyCombo, $wmcJumpToUrgentWindow):
    this.jumpToUrgentWindow()

  createControl(keyCombo, $wmcIncreaseMasterWidth):
    this.increaseMasterWidth()

  createControl(keyCombo, $wmcDecreaseMasterWidth):
    this.decreaseMasterWidth()

  createControl(keyCombo, $wmcMoveWindowToScratchpad):
    this.moveWindowToScratchpad()

  createControl(keyCombo, $wmcPopScratchpad):
    this.popScratchpad()

  createControl(keyCombo, $wmcRotateclients):
    this.selectedMonitor.rotateClients()

  createControl(keyCombo, $wmcToggleStatusBar):
    this.selectedMonitor.toggleStatusBar()

  # Ends the whole River session (killing nimdow alone leaves River running).
  createControl(keyCombo, $wmcExitSession):
    river_window_manager_v1_exit_session(this.manager)

# ---------------------------------------------------------------------------
# Windows
# ---------------------------------------------------------------------------

proc windowClosed(data: pointer, obj: RiverWindowV1) {.cdecl.} =
  cast[Client](data).isClosed = true

proc windowDimensions(data: pointer, obj: RiverWindowV1, width, height: int32) {.cdecl.} =
  let client = cast[Client](data)
  client.reportedWidth = width
  client.reportedHeight = height

proc windowAppId(data: pointer, obj: RiverWindowV1, appId: cstring) {.cdecl.} =
  cast[Client](data).appId = if appId.isNil: "" else: $appId

proc windowTitle(data: pointer, obj: RiverWindowV1, title: cstring) {.cdecl.} =
  cast[Client](data).title = if title.isNil: "" else: $title

proc windowDimensionsHint(
  data: pointer, obj: RiverWindowV1, minWidth, minHeight, maxWidth, maxHeight: int32
) {.cdecl.} =
  let client = cast[Client](data)
  client.minWidth = minWidth
  client.minHeight = minHeight
  client.maxWidth = maxWidth
  client.maxHeight = maxHeight
  client.hintsDirty = true

proc windowParent(data: pointer, obj: RiverWindowV1, parent: RiverWindowV1) {.cdecl.} =
  let client = cast[Client](data)
  client.hasParent = not parent.isNil
  client.hintsDirty = true

proc windowFullscreenRequested(
  data: pointer, obj: RiverWindowV1, output: RiverOutputV1
) {.cdecl.} =
  cast[Client](data).fullscreenRequest = frEnter

proc windowExitFullscreenRequested(data: pointer, obj: RiverWindowV1) {.cdecl.} =
  cast[Client](data).fullscreenRequest = frExit

proc windowPointerMoveRequested(
  data: pointer, obj: RiverWindowV1, seat: RiverSeatV1
) {.cdecl.} =
  let client = cast[Client](data)
  client.pointerRequest = prMove
  client.pointerRequestSeat = seat

proc windowPointerResizeRequested(
  data: pointer, obj: RiverWindowV1, seat: RiverSeatV1, edges: uint32
) {.cdecl.} =
  let client = cast[Client](data)
  client.pointerRequest = prResize
  client.pointerRequestSeat = seat
  client.pointerRequestEdges = edges

# maximize_requested/unmaximize_requested are ignored: tiled windows stay
# tiled and nimdow never tells a window that it is maximized.
var windowListener = river_window_v1_noop_listener()
windowListener.closed = windowClosed
windowListener.dimensions = windowDimensions
windowListener.app_id = windowAppId
windowListener.title = windowTitle
windowListener.dimensions_hint = windowDimensionsHint
windowListener.parent = windowParent
windowListener.fullscreen_requested = windowFullscreenRequested
windowListener.exit_fullscreen_requested = windowExitFullscreenRequested
windowListener.pointer_move_requested = windowPointerMoveRequested
windowListener.pointer_resize_requested = windowPointerResizeRequested

proc wmWindow(data: pointer, obj: RiverWindowManagerV1, w: RiverWindowV1) {.cdecl.} =
  let client = newClient(w)
  client.node = river_window_v1_get_node(w)
  GC_ref client
  discard river_window_v1_add_listener(w, addr windowListener, cast[pointer](client))
  # Placed on a monitor at the next manage sequence.
  wm.unassigned.add client

proc endSeatOp(seat: Seat) =
  ## Ends the interactive op of the seat. Manage sequence only.
  if seat.op == soResize and seat.opClient != nil:
    river_window_v1_inform_resize_end(seat.opClient.window)
  river_seat_v1_op_end(seat.obj)
  seat.op = soNone
  seat.opClient = nil
  seat.opStarted = false
  seat.opRelease = false

proc destroyClient(this: WindowManager, client: Client) =
  for monitor in this.monitors.values():
    if monitor.removeWindow(client.window):
      monitor.doLayout()
  this.unassigned.dropAt client
  this.scratchpad.dropAt client
  if this.warpClient == client: this.warpClient = nil
  for seat in this.seats:
    if seat.focused == client.window: seat.focused = nil
    if seat.interacted == client.window: seat.interacted = nil
    if seat.hovered == client.window: seat.hovered = nil
    if seat.opClient == client: seat.endSeatOp()
  river_window_v1_destroy(client.window)
  GC_unref client

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

proc outputRemoved(data: pointer, obj: RiverOutputV1) {.cdecl.} =
  cast[Output](data).removed = true

proc outputPosition(data: pointer, obj: RiverOutputV1, x, y: int32) {.cdecl.} =
  let output = cast[Output](data)
  output.x = x
  output.y = y

proc outputDimensions(data: pointer, obj: RiverOutputV1, width, height: int32) {.cdecl.} =
  let output = cast[Output](data)
  output.width = width
  output.height = height
  output.hasGeometry = true

proc layerNonExclusiveArea(
  data: pointer, obj: RiverLayerShellOutputV1, x, y, width, height: int32
) {.cdecl.} =
  let output = cast[Output](data)
  output.freeX = x
  output.freeY = y
  output.freeWidth = width
  output.freeHeight = height
  output.hasFreeArea = true

var layerOutputListener = river_layer_shell_output_v1_noop_listener()
layerOutputListener.non_exclusive_area = layerNonExclusiveArea

var outputListener = river_output_v1_noop_listener()
outputListener.removed = outputRemoved
outputListener.position = outputPosition
outputListener.dimensions = outputDimensions

proc wmOutput(data: pointer, obj: RiverWindowManagerV1, o: RiverOutputV1) {.cdecl.} =
  let output = Output(obj: o)
  GC_ref output
  discard river_output_v1_add_listener(o, addr outputListener, cast[pointer](output))
  if wm.layerShell != nil:
    output.layerOutput = river_layer_shell_v1_get_output(wm.layerShell, o)
    discard river_layer_shell_output_v1_add_listener(
      output.layerOutput, addr layerOutputListener, cast[pointer](output)
    )
  wm.outputs.add output

proc outputArea(output: Output): Area =
  (output.x.int, output.y.int, output.width.uint, output.height.uint)

proc reservedEdges(output: Output): LayoutOffset =
  ## Space taken by layer surfaces at each edge of the output.
  if not output.hasFreeArea:
    return
  let
    top = clamp(output.freeY - output.y, 0, output.height)
    left = clamp(output.freeX - output.x, 0, output.width)
    bottom = clamp(
      (output.y + output.height) - (output.freeY + output.freeHeight), 0, output.height
    )
    right = clamp(
      (output.x + output.width) - (output.freeX + output.freeWidth), 0, output.width
    )
  # Never reserve the whole output.
  if top + bottom >= output.height or left + right >= output.width:
    return
  (top.uint, left.uint, bottom.uint, right.uint)

proc syncOutputs(this: WindowManager) =
  ## Creates monitors for new outputs (in position order), updates changed
  ## geometry and removes monitors of removed outputs (their clients move to
  ## another monitor).
  for output in this.outputs[0 .. ^1]:
    if output.removed:
      if output.monitor != nil:
        let monitor = output.monitor
        for client in monitor.clients.items:
          # Fullscreen is re-requested on the new monitor's output.
          client.sentFullscreen = false
          client.sentFullscreenOutput = nil
          this.unassigned.add client
        if monitor.statusBar != nil:
          monitor.statusBar.destroy()
          monitor.statusBar = nil
        for id, m in this.monitors.pairs:
          if m == monitor:
            this.monitors.del id
            break
        if this.warpMonitor == monitor:
          this.warpMonitor = nil
          this.warpClient = nil
        if this.selectedMonitor == monitor:
          this.selectedMonitor = nil
          for m in this.sortedMonitors():
            this.selectedMonitor = m
            break
      if output.layerOutput != nil:
        river_layer_shell_output_v1_destroy(output.layerOutput)
        output.layerOutput = nil
      if this.layerDefault == output:
        this.layerDefault = nil
      river_output_v1_destroy(output.obj)
      this.outputs.dropAt output
      GC_unref output
    elif output.hasGeometry and output.monitor != nil and
         output.monitor.area != output.outputArea:
      output.monitor.area = output.outputArea
      output.monitor.reserved = output.reservedEdges()
      output.monitor.updateMonitor()
    elif output.monitor != nil and output.monitor.reserved != output.reservedEdges():
      # A layer surface (another bar, ...) was mapped, changed or went away.
      output.monitor.reserved = output.reservedEdges()
      output.monitor.updateMonitor()

  var fresh: seq[Output]
  for output in this.outputs:
    if output.hasGeometry and output.monitor == nil:
      fresh.add output
  fresh.sort(proc(a, b: Output): int =
    result = cmp(a.x, b.x)
    if result == 0:
      result = cmp(a.y, b.y)
  )
  for output in fresh:
    let id = this.nextMonitorID
    inc this.nextMonitorID
    output.monitor = newMonitor(id, output.obj, output.outputArea, this.config)
    output.monitor.reserved = output.reservedEdges()
    this.monitors[id] = output.monitor
    if this.barCtx != nil:
      let settings = output.monitor.monitorSettings
      output.monitor.statusBar = newStatusBar(
        this.barCtx, settings.barSettings, settings.tagSettings
      )
      # Reserves the bar's space.
      output.monitor.updateMonitor()
    if this.selectedMonitor == nil:
      this.selectedMonitor = output.monitor
  if fresh.len > 0:
    this.applyStatus()

proc findAppRule(this: WindowManager, client: Client): AppRule =
  ## The first rule matching the client. The app_id serves as both the
  ## class and the instance.
  for rule in this.config.appRules:
    if rule.matches(client.title, client.appId, client.appId):
      return rule

proc centerIfAtOrigin(client: Client, monitor: Monitor) =
  ## Original centerClientIfNeeded: a floating client at the top-left corner
  ## of the monitor is centered once its size is known.
  if client.x <= monitor.area.x and client.y <= monitor.area.y:
    client.needsCenter = true

proc applyHints(this: WindowManager, client: Client, monitor: Monitor) =
  ## Dialogs/transients (a parent) and fixed size windows (min == max) float.
  client.hintsDirty = false
  var autoFloat = client.hasParent
  if client.minWidth > 0 and client.minWidth == client.maxWidth and
     client.minHeight > 0 and client.minHeight == client.maxHeight:
    autoFloat = true
    client.width = max(client.width, client.minWidth.uint)
    client.height = max(client.height, client.minHeight.uint)
  if autoFloat and not client.isFloating and not client.isFullscreen:
    if monitor != nil:
      monitor.setFloating(client, true)
    else:
      client.isFloating = true
    client.centerIfAtOrigin(monitor)

proc assignUnassigned(this: WindowManager) =
  ## Puts clients on a monitor (kept waiting if there is none yet): new clients
  ## by their app rule or on the selected monitor (which follows the pointer),
  ## clients of removed outputs on the selected monitor.
  if this.selectedMonitor == nil:
    return
  let monitors = this.sortedMonitors()
  for client in this.unassigned:
    var
      c = client
      monitor = this.selectedMonitor
      rule: AppRule
    if client.isNew:
      rule = this.findAppRule(client)
      client.borderWidth = this.config.windowSettings.borderWidth
      if rule != nil and rule.monitorID in 1 .. monitors.len:
        monitor = monitors[rule.monitorID - 1]
      client.area = (monitor.area.x, monitor.area.y, 0.uint, 0.uint)

      if rule != nil:
        if rule.tagIDs.len > 0:
          client.tagIDs.clear()
          for tagID in rule.tagIDs:
            client.tagIDs.incl tagID
        case rule.state
        of wsFloating:
          client.isFloating = true
          if rule.x >= 0: client.x = monitor.area.x + rule.x
          if rule.y >= 0: client.y = monitor.area.y + rule.y
          if rule.width > 0: client.width = rule.width.uint
          if rule.height > 0: client.height = rule.height.uint
        of wsFullscreen:
          client.isFullscreen = true
        of wsNormal:
          discard

      monitor.addClient(c, rule == nil or rule.tagIDs.len == 0)
      this.applyHints(client, monitor)
      if client.isFloating:
        client.centerIfAtOrigin(monitor)
      if client.isFullscreen:
        monitor.setSelectedClient(client)
        monitor.doLayout()
    else:
      monitor.addClient(c)
  this.unassigned.setLen 0

# ---------------------------------------------------------------------------
# Seats and key bindings
# ---------------------------------------------------------------------------

proc xkbBindingPressed(data: pointer, obj: RiverXkbBindingV1) {.cdecl.} =
  wm.pressedCombos.add cast[XkbBinding](data).combo

var xkbBindingListener = river_xkb_binding_v1_noop_listener()
xkbBindingListener.pressed = xkbBindingPressed

proc pointerBindingPressed(data: pointer, obj: RiverPointerBindingV1) {.cdecl.} =
  let binding = cast[PointerBinding](data)
  binding.seat.pendingPointerOp = binding.kind

var pointerBindingListener = river_pointer_binding_v1_noop_listener()
pointerBindingListener.pressed = pointerBindingPressed

const
  BtnLeft = 0x110'u32
  BtnRight = 0x111'u32

proc destroyBindings(seat: Seat) =
  for binding in seat.xkbBindings:
    river_xkb_binding_v1_destroy(binding.obj)
    GC_unref binding
  seat.xkbBindings.setLen 0
  for binding in seat.pointerBindings:
    river_pointer_binding_v1_destroy(binding.obj)
    GC_unref binding
  seat.pointerBindings.setLen 0

proc createBindings(this: WindowManager, seat: Seat) =
  for combo in this.config.keyComboTable.keys():
    let binding = XkbBinding(combo: combo)
    binding.obj = river_xkb_bindings_v1_get_xkb_binding(
      this.xkbBindings, seat.obj, combo.key.toKeysym(), combo.modifiers
    )
    GC_ref binding
    discard river_xkb_binding_v1_add_listener(
      binding.obj, addr xkbBindingListener, cast[pointer](binding)
    )
    river_xkb_binding_v1_enable(binding.obj)
    seat.xkbBindings.add binding

  # modKey + left button moves, modKey + right button resizes.
  let modKey = this.config.windowSettings.modKey.uint32
  for (button, kind) in [(BtnLeft, prMove), (BtnRight, prResize)]:
    let binding = PointerBinding(seat: seat, kind: kind)
    binding.obj = river_seat_v1_get_pointer_binding(seat.obj, button, modKey)
    GC_ref binding
    discard river_pointer_binding_v1_add_listener(
      binding.obj, addr pointerBindingListener, cast[pointer](binding)
    )
    river_pointer_binding_v1_enable(binding.obj)
    seat.pointerBindings.add binding

proc layerFocusExclusive(data: pointer, obj: RiverLayerShellSeatV1) {.cdecl.} =
  cast[Seat](data).layerFocus = lfExclusive

proc layerFocusNonExclusive(data: pointer, obj: RiverLayerShellSeatV1) {.cdecl.} =
  cast[Seat](data).layerFocus = lfNonExclusive

proc layerFocusNone(data: pointer, obj: RiverLayerShellSeatV1) {.cdecl.} =
  let seat = cast[Seat](data)
  seat.layerFocus = lfNone
  # Return focus to the window: it is sent again in the next manage sequence.
  seat.focused = nil

var layerSeatListener = river_layer_shell_seat_v1_noop_listener()
layerSeatListener.focus_exclusive = layerFocusExclusive
layerSeatListener.focus_non_exclusive = layerFocusNonExclusive
layerSeatListener.focus_none = layerFocusNone

proc seatRemoved(data: pointer, obj: RiverSeatV1) {.cdecl.} =
  cast[Seat](data).removed = true

proc seatWindowInteraction(data: pointer, obj: RiverSeatV1, window: RiverWindowV1) {.cdecl.} =
  cast[Seat](data).interacted = window

proc seatPointerEnter(data: pointer, obj: RiverSeatV1, window: RiverWindowV1) {.cdecl.} =
  cast[Seat](data).hovered = window

proc seatPointerLeave(data: pointer, obj: RiverSeatV1) {.cdecl.} =
  cast[Seat](data).hovered = nil

proc seatPointerPosition(data: pointer, obj: RiverSeatV1, x, y: int32) {.cdecl.} =
  let seat = cast[Seat](data)
  seat.pointerX = x
  seat.pointerY = y
  seat.pointerChanged = true

proc seatOpDelta(data: pointer, obj: RiverSeatV1, dx, dy: int32) {.cdecl.} =
  let seat = cast[Seat](data)
  seat.opDx = dx
  seat.opDy = dy

proc seatOpRelease(data: pointer, obj: RiverSeatV1) {.cdecl.} =
  cast[Seat](data).opRelease = true

var seatListener = river_seat_v1_noop_listener()
seatListener.removed = seatRemoved
seatListener.window_interaction = seatWindowInteraction
seatListener.pointer_enter = seatPointerEnter
seatListener.pointer_leave = seatPointerLeave
seatListener.pointer_position = seatPointerPosition
seatListener.op_delta = seatOpDelta
seatListener.op_release = seatOpRelease

proc wmSeat(data: pointer, obj: RiverWindowManagerV1, s: RiverSeatV1) {.cdecl.} =
  let seat = Seat(obj: s, isNew: true)
  GC_ref seat
  discard river_seat_v1_add_listener(s, addr seatListener, cast[pointer](seat))
  if wm.layerShell != nil:
    seat.layerSeat = river_layer_shell_v1_get_seat(wm.layerShell, s)
    discard river_layer_shell_seat_v1_add_listener(
      seat.layerSeat, addr layerSeatListener, cast[pointer](seat)
    )
  wm.seats.add seat

proc syncSeats(this: WindowManager) =
  for seat in this.seats[0 .. ^1]:
    if seat.removed:
      seat.destroyBindings()
      if seat.layerSeat != nil:
        river_layer_shell_seat_v1_destroy(seat.layerSeat)
      river_seat_v1_destroy(seat.obj)
      this.seats.dropAt seat
      GC_unref seat
    elif seat.isNew or this.bindingsDirty:
      seat.destroyBindings()
      this.createBindings(seat)
      seat.isNew = false
  this.bindingsDirty = false

# ---------------------------------------------------------------------------
# Status bar clicks
# ---------------------------------------------------------------------------

proc handleBarClicks(this: WindowManager) =
  ## Handles the clicks and scrolls queued by the bars' wl_pointer listeners.
  ## Manage sequence only.
  if this.barCtx == nil:
    return
  let clicks = this.barCtx.clicks
  this.barCtx.clicks.setLen 0
  for click in clicks:
    var monitor: Monitor
    for m in this.monitors.values():
      if m.statusBar == click.bar:
        monitor = m
        break
    if monitor == nil:
      continue
    this.selectedMonitor = monitor

    let
      bar = click.bar
      clicked = bar.regionAt(click.x, click.y)
    if clicked.regionID == -1:
      # Nothing was clicked
      continue

    if clicked.regionID in 0 ..< bar.tagCount:
      case click.button
      of 4, 5:
        let
          scrollUp = click.button == 4
          left = scrollUp != this.config.reverseTagScrolling
          tag = if left: this.findLeftTag() else: this.findRightTag()
        if tag != nil:
          this.goToTag(tag.id)
      else:
        this.goToTag(clicked.regionID + 1)
      continue

    # The window title is region 0, the status regions follow.
    let regionID =
      if clicked.regionID == bar.tagCount: 0
      else: clicked.regionID - bar.tagCount
    if this.config.regionClickActionTable.hasKey(regionID):
      this.config.regionClickActionTable[regionID](
        clicked.index,
        clicked.width,
        clicked.regionCord,
        clicked.clickCord,
        click.button
      )

# ---------------------------------------------------------------------------
# Interactive move/resize
# ---------------------------------------------------------------------------

proc selectClient(this: WindowManager, client: Client) =
  let monitor = this.monitorOf(client)
  if monitor != nil:
    this.selectedMonitor = monitor
    monitor.setSelectedClient(client)

proc startSeatOp(
  this: WindowManager, seat: Seat, client: Client, kind: PointerRequestKind, edges: uint32
) =
  ## Starts moving/resizing the client with the seat's pointer. The client
  ## becomes floating with the first motion (op_delta).
  if seat.op != soNone or client == nil or client.isFullscreen or
     this.monitorOf(client) == nil:
    return
  this.selectClient(client)
  river_seat_v1_op_start_pointer(seat.obj)
  seat.op = if kind == prMove: soMove else: soResize
  seat.opClient = client
  seat.opEdges = edges
  seat.opStarted = false
  seat.opRelease = false
  seat.opDx = 0
  seat.opDy = 0
  if seat.op == soResize:
    river_window_v1_inform_resize_start(client.window)

proc manageSeatOp(this: WindowManager, seat: Seat) =
  ## Advances the interactive op: the client's area follows the pointer.
  if seat.op == soNone:
    return
  let client = seat.opClient
  let monitor = this.monitorOf(client)
  if monitor == nil:
    seat.endSeatOp()
    return

  if not seat.opStarted and (seat.opDx != 0 or seat.opDy != 0):
    seat.opStarted = true
    monitor.setFloating(client, true)
    # A window that has not been sized by us yet is moved/resized as it is.
    if client.width == 0: client.width = max(client.reportedWidth, 1).uint
    if client.height == 0: client.height = max(client.reportedHeight, 1).uint
    client.needsCenter = false
    seat.opStart = client.area

  if seat.opStarted:
    let start = seat.opStart
    if seat.op == soMove:
      client.setLocation(start.x + seat.opDx.int, start.y + seat.opDy.int)
    else:
      var
        width = start.width.int
        height = start.height.int
      if (seat.opEdges and RIVER_WINDOW_V1_EDGES_LEFT) != 0: width -= seat.opDx
      if (seat.opEdges and RIVER_WINDOW_V1_EDGES_RIGHT) != 0: width += seat.opDx
      if (seat.opEdges and RIVER_WINDOW_V1_EDGES_TOP) != 0: height -= seat.opDy
      if (seat.opEdges and RIVER_WINDOW_V1_EDGES_BOTTOM) != 0: height += seat.opDy
      width = max(width, 1)
      height = max(height, 1)
      var x = start.x
      var y = start.y
      if (seat.opEdges and RIVER_WINDOW_V1_EDGES_LEFT) != 0:
        x += start.width.int - width
      if (seat.opEdges and RIVER_WINDOW_V1_EDGES_TOP) != 0:
        y += start.height.int - height
      client.resize(x, y, width.uint, height.uint)

  if seat.opRelease:
    let started = seat.opStarted
    seat.endSeatOp()
    if started:
      # Dropped on another monitor: the client belongs to that monitor now.
      let
        centerX = client.x + client.totalWidth div 2
        centerY = client.y + client.totalHeight div 2
        (_, target) = this.monitors.find(centerX, centerY)
      if target != nil and target != monitor:
        this.moveClientToMonitor(client, target, keepPosition = true)

# ---------------------------------------------------------------------------
# Manage / render sequences
# ---------------------------------------------------------------------------

proc flushVisibility(client: Client) =
  if client.isVisible != client.sentVisible:
    if client.isVisible:
      river_window_v1_show(client.window)
    else:
      river_window_v1_hide(client.window)
    client.sentVisible = client.isVisible

proc applyManageState(this: WindowManager) =
  ## Sends window management state (and show/hide) to River.
  for monitor in this.monitors.values():
    monitor.doLayout()
    for client in monitor.clients.items:
      if client.closeRequested:
        client.closeRequested = false
        river_window_v1_close(client.window)

      client.flushVisibility()

      # Fullscreen is handled by River (position and dimensions).
      if client.isFullscreen:
        if not client.sentFullscreen or client.sentFullscreenOutput != monitor.output:
          river_window_v1_fullscreen(client.window, monitor.output)
          if not client.sentFullscreen:
            river_window_v1_inform_fullscreen(client.window)
          client.sentFullscreen = true
          client.sentFullscreenOutput = monitor.output
      elif client.sentFullscreen:
        river_window_v1_exit_fullscreen(client.window)
        river_window_v1_inform_not_fullscreen(client.window)
        client.sentFullscreen = false
        client.sentFullscreenOutput = nil

      # Floating clients without a size yet (0) let the window choose.
      if client.isVisible and not client.isFullscreen:
        river_window_v1_propose_dimensions(
          client.window, client.width.int32, client.height.int32
        )

      if client.isNew:
        # nimdow draws its own borders; ask clients not to draw title bars.
        river_window_v1_use_ssd(client.window)
      # Tiled windows drop shadows/rounded corners.
      let tiled = not client.isFloating and not client.isFullscreen
      if tiled != client.sentTiled:
        river_window_v1_set_tiled(client.window,
          if tiled:
            RIVER_WINDOW_V1_EDGES_TOP or RIVER_WINDOW_V1_EDGES_BOTTOM or
              RIVER_WINDOW_V1_EDGES_LEFT or RIVER_WINDOW_V1_EDGES_RIGHT
          else:
            RIVER_WINDOW_V1_EDGES_NONE)
        client.sentTiled = tiled
      client.isNew = false

  for client in this.scratchpad:
    client.isVisible = false
    client.flushVisibility()
    client.isNew = false

  # Keyboard focus follows the selected client of the selected monitor.
  var focusTarget: Client
  if this.selectedMonitor != nil:
    focusTarget = this.selectedMonitor.taggedClients.currClient
  for seat in this.seats:
    if seat.layerFocus == lfExclusive:
      # A layer surface holds the keyboard; River ignores focus requests until
      # focus_none, after which the window is focused again.
      continue
    if focusTarget != nil:
      if seat.focused != focusTarget.window:
        river_seat_v1_focus_window(seat.obj, focusTarget.window)
        seat.focused = focusTarget.window
    elif seat.focused != nil:
      river_seat_v1_clear_focus(seat.obj)
      seat.focused = nil

  # New layer surfaces without an output go to the selected monitor.
  if this.selectedMonitor != nil and
      (this.layerDefault == nil or this.layerDefault.monitor != this.selectedMonitor):
    for output in this.outputs:
      if output.monitor == this.selectedMonitor and output.layerOutput != nil:
        river_layer_shell_output_v1_set_default(output.layerOutput)
        this.layerDefault = output
        break

  # Move the pointer along with a monitor focus change.
  if this.warpMonitor != nil and this.seats.len > 0:
    var x, y: int
    let client = this.warpClient
    if client != nil and not client.isFullscreen and client.isVisible:
      x = client.x + client.totalWidth div 2
      y = client.y + client.totalHeight div 2
    else:
      let center = this.warpMonitor.area.center()
      x = center.x.int
      y = center.y.int
    river_seat_v1_pointer_warp(this.seats[0].obj, x.int32, y.int32)
  this.warpMonitor = nil
  this.warpClient = nil

proc onManageStart(this: WindowManager) =
  this.syncOutputs()

  # Remove closed windows.
  var closed: seq[Client]
  for client in this.allClients:
    if client.isClosed: closed.add client
  for client in this.unassigned:
    if client.isClosed: closed.add client
  for client in this.scratchpad:
    if client.isClosed: closed.add client
  for client in closed:
    this.destroyClient(client)

  # The selected monitor follows the pointer.
  for seat in this.seats:
    if seat.pointerChanged:
      seat.pointerChanged = false
      let (_, monitor) = this.monitors.find(seat.pointerX.int, seat.pointerY.int)
      if monitor != nil:
        this.selectedMonitor = monitor

  this.assignUnassigned()
  this.syncSeats()

  # Client requests and changed hints.
  var clients: seq[Client]
  for client in this.allClients:
    clients.add client
  for client in clients:
    let monitor = this.monitorOf(client)
    if monitor == nil:
      continue
    if client.hintsDirty:
      this.applyHints(client, monitor)
    case client.fullscreenRequest
    of frEnter: monitor.setFullscreen(client, true)
    of frExit: monitor.setFullscreen(client, false)
    of frNone: discard
    client.fullscreenRequest = frNone
    if client.pointerRequest != prNone:
      for seat in this.seats:
        if seat.obj == client.pointerRequestSeat:
          this.startSeatOp(
            seat, client, client.pointerRequest,
            if client.pointerRequest == prMove: 0'u32
            else: client.pointerRequestEdges
          )
      client.pointerRequest = prNone

  # Click-to-focus.
  for seat in this.seats:
    if seat.interacted != nil:
      let client = this.findClient(seat.interacted)
      seat.interacted = nil
      if seat.layerFocus == lfNonExclusive:
        # A click on a window takes focus back from the layer surface.
        seat.focused = nil
      if client != nil:
        this.selectClient(client)

  this.handleBarClicks()

  # modKey + button: move/resize the window under the pointer.
  for seat in this.seats:
    let pending = seat.pendingPointerOp
    seat.pendingPointerOp = prNone
    if pending != prNone and seat.hovered != nil:
      this.startSeatOp(
        seat, this.findClient(seat.hovered), pending,
        if pending == prMove: 0'u32
        else: RIVER_WINDOW_V1_EDGES_BOTTOM or RIVER_WINDOW_V1_EDGES_RIGHT
      )

  # Key bindings. Actions may reload the config, so work on a copy.
  let combos = this.pressedCombos
  this.pressedCombos.setLen 0
  for combo in combos:
    if this.selectedMonitor != nil and this.config.keyComboTable.hasKey(combo):
      this.config.keyComboTable[combo](combo)
  # A reload in the loop above needs its bindings now.
  this.syncSeats()

  for seat in this.seats:
    this.manageSeatOp(seat)

  this.applyManageState()
  river_window_manager_v1_manage_finish(this.manager)

proc colorChannel(value: int, shift: int): uint32 =
  ## 8-bit channel to the 32-bit range used by River.
  uint32((value shr shift) and 0xff) * 0x01010101'u32

proc centerOnMonitor(client: Client, monitor: Monitor) =
  ## Centers a floating client whose size is known (the size it was given, or
  ## what the window chose).
  if client.width == 0: client.width = max(client.reportedWidth, 0).uint
  if client.height == 0: client.height = max(client.reportedHeight, 0).uint
  if client.width == 0 or client.height == 0:
    return
  let area = monitor.area
  client.x = (area.x.float + (area.width.float - client.totalWidth.float) / 2).int
  client.y = (area.y.float + (area.height.float - client.totalHeight.float) / 2).int
  client.needsCenter = false

proc applyRenderState(this: WindowManager) =
  ## Sends rendering state (position, borders, stacking) to River.
  var focusedClient: Client
  if this.selectedMonitor != nil:
    focusedClient = this.selectedMonitor.taggedClients.currClient
  # No window is focused while a layer surface (launcher, ...) holds the keyboard.
  for seat in this.seats:
    if seat.layerFocus == lfExclusive:
      focusedClient = nil

  for monitor in this.monitors.values():
    let settings = monitor.windowSettings
    if monitor.statusBar != nil:
      monitor.syncStatusBar(monitor == this.selectedMonitor)
      # Below the layer surfaces reserving space at the top.
      monitor.statusBar.flush(
        monitor.area.x + monitor.reserved.left.int,
        monitor.area.y + monitor.reserved.top.int,
        monitor.area.width.int - monitor.reserved.left.int - monitor.reserved.right.int,
        monitor.isStatusBarEnabled
      )
    for client in monitor.clients.items:
      if not client.isVisible:
        continue
      if client.needsCenter and client.isFloating:
        client.centerOnMonitor(monitor)
      let color =
        if client.isUrgent: settings.borderColorUrgent
        elif client == focusedClient: settings.borderColorFocused
        else: settings.borderColorUnfocused
      let bw = if client.isFullscreen: 0'i32 else: client.borderWidth.int32
      # River positions fullscreen windows itself. Layout areas include the
      # border; River positions the window content.
      if not client.isFullscreen:
        river_node_v1_set_position(
          client.node, (client.x + bw).int32, (client.y + bw).int32
        )
      river_window_v1_set_borders(
        client.window,
        RIVER_WINDOW_V1_EDGES_TOP or RIVER_WINDOW_V1_EDGES_BOTTOM or
          RIVER_WINDOW_V1_EDGES_LEFT or RIVER_WINDOW_V1_EDGES_RIGHT,
        bw,
        colorChannel(color, 16), colorChannel(color, 8), colorChannel(color, 0),
        0xffffffff'u32
      )

    # Stacking, bottom to top: tiled, floating (least recently selected
    # first), status bar, fullscreen. River does not render shell surfaces
    # below the top fullscreen window, so the bar hides while one is shown.
    for client in monitor.clientSelection:
      if client.isVisible and not client.isFloating and not client.isFullscreen:
        river_node_v1_place_top(client.node)
    for client in monitor.clientSelection:
      if client.isVisible and client.isFloating and not client.isFullscreen:
        river_node_v1_place_top(client.node)
    if monitor.statusBar != nil:
      river_node_v1_place_top(monitor.statusBar.node)
    for client in monitor.clientSelection:
      if client.isVisible and client.isFullscreen:
        river_node_v1_place_top(client.node)

proc onRenderStart(this: WindowManager) =
  this.applyRenderState()
  river_window_manager_v1_render_finish(this.manager)

# ---------------------------------------------------------------------------
# Window manager global
# ---------------------------------------------------------------------------

proc wmUnavailable(data: pointer, obj: RiverWindowManagerV1) {.cdecl.} =
  stderr.writeLine "error: another window manager is already running"
  quit(1)

proc wmFinished(data: pointer, obj: RiverWindowManagerV1) {.cdecl.} =
  quit(0)

proc wmManageStart(data: pointer, obj: RiverWindowManagerV1) {.cdecl.} =
  wm.onManageStart()

proc wmRenderStart(data: pointer, obj: RiverWindowManagerV1) {.cdecl.} =
  wm.onRenderStart()

var wmListener = river_window_manager_v1_noop_listener()
wmListener.unavailable = wmUnavailable
wmListener.finished = wmFinished
wmListener.manage_start = wmManageStart
wmListener.render_start = wmRenderStart
wmListener.window = wmWindow
wmListener.output = wmOutput
wmListener.seat = wmSeat

proc newWindowManager*(config: Config, configTable: TomlTable): WindowManager =
  ## Connects to River and binds the window management globals.
  ## Raises an Exception when River (or a required global) is unavailable.
  result = WindowManager(config: config, nextMonitorID: 1)
  wm = result

  result.display = connect()
  if result.display.isNil:
    raise newException(Exception, "failed to connect to the Wayland server")

  # Avoid passing WAYLAND_DEBUG on to our children.
  delEnv("WAYLAND_DEBUG")

  let registry = discoverGlobals(result.display)
  let wmGlobal = registry.find("river_window_manager_v1")
  let xkbGlobal = registry.find("river_xkb_bindings_v1")
  if wmGlobal.version >= 4:
    result.manager = bindGlobal[RiverWindowManagerV1](
      registry, wmGlobal, river_window_manager_v1_interface, 4
    )
  if xkbGlobal.version >= 1:
    result.xkbBindings = bindGlobal[RiverXkbBindingsV1](
      registry, xkbGlobal, river_xkb_bindings_v1_interface, 1
    )
  let layerGlobal = registry.find("river_layer_shell_v1")
  if layerGlobal.version >= 1:
    result.layerShell = bindGlobal[RiverLayerShellV1](
      registry, layerGlobal, river_layer_shell_v1_interface, 1
    )
  else:
    log "river_layer_shell_v1 not available: layer surfaces will not work", lvlWarn
  if result.manager.isNil or result.xkbBindings.isNil:
    raise newException(
      Exception,
      "river_window_manager_v1 or river_xkb_bindings_v1 not supported by the Wayland server"
    )

  result.barCtx = newBarContext(registry, result.manager)
  if result.barCtx == nil:
    log "wl_compositor/wl_shm not available: the status bar is disabled", lvlWarn
  else:
    result.barCtx.requestManage = proc() = wm.markDirty()

  # Config setup
  try:
    result.mapConfigActions()
    result.config.populateKeyComboTable(configTable)
    result.config.populateGeneralSettings(configTable)
  except:
    log getCurrentExceptionMsg(), lvlError

  discard river_window_manager_v1_add_listener(result.manager, addr wmListener, nil)
  # Receive the initial globals (outputs, seats) before the event loop starts.
  discard result.display.roundtrip()
