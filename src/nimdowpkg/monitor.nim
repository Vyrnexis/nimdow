import
  std/options,
  strutils,
  tables,
  listutils,
  sequtils,
  sugar

import
  taggedclients,
  area,
  layouts/layout,
  layouts/masterstacklayout,
  config/configloader,
  statusbar,
  wl/protocols/river_window_management_v1,
  logger

export options

type
  Monitor* = ref object of RootObj
    id*: MonitorID
    ## The River output this monitor was built from.
    output*: RiverOutputV1
    area*: Area
    config: Config
    monitorSettings*: MonitorSettings
    windowSettings: WindowSettings
    previousTagID*: TagID
    layoutOffset*: LayoutOffset
    ## Height reserved at the top of the monitor for the status bar
    ## (0 while the bar is disabled or unavailable).
    barHeight*: uint
    ## Space taken by layer shell surfaces (e.g. another bar) at each edge,
    ## from river_layer_shell_output_v1.non_exclusive_area.
    reserved*: LayoutOffset
    ## Nil when the bar is unavailable (no wl_compositor/wl_shm).
    statusBar*: StatusBar
    isStatusBarEnabled*: bool
    taggedClients*: TaggedClients

proc doLayout*(this: Monitor)
proc updateMonitor*(this: Monitor)
proc setSelectedClient*(this: Monitor, client: Client)

proc newMonitor*(
  id: MonitorID,
  output: RiverOutputV1,
  area: Area,
  currentConfig: Config
): Monitor =
  result = Monitor()
  result.id = id
  result.output = output
  result.area = area
  result.config = currentConfig
  if currentConfig.monitorSettings.hasKey(id):
    result.monitorSettings = currentConfig.monitorSettings[id]
  else:
    result.monitorSettings = currentConfig.defaultMonitorSettings
  result.windowSettings = currentConfig.windowSettings
  result.taggedClients = newTaggedClients(tagCount)
  result.isStatusBarEnabled = true
  for i in 1..tagCount:
    let tagSetting = result.monitorSettings.tagSettings[i]
    let tag: Tag = newTag(
      id = i,
      layout = newMasterStackLayout(
        monitorArea = area,
        gapSize = result.monitorSettings.layoutSettings.gapSize,
        defaultWidth = tagSetting.defaultMasterWidthPercentage,
        borderWidth = currentConfig.windowSettings.borderWidth,
        masterSlots = tagSetting.numMasterWindows.uint,
        layoutOffset = result.layoutOffset,
        outerGap = result.monitorSettings.layoutSettings.outerGap
      )
    )
    result.taggedClients.tags.add(tag)

  # Select the 2nd tag as the previous tag.
  result.previousTagID = result.taggedClients.tags[1].id

  result.taggedClients.selectedTags = initOrderedSet[TagID](tagCount)
  result.taggedClients.selectedTags.incl(1)
  result.updateMonitor()

proc reservedBarHeight(this: Monitor): uint =
  if this.statusBar != nil and this.isStatusBarEnabled:
    this.monitorSettings.barSettings.height
  else:
    0

proc calcLayoutOffset(this: Monitor): LayoutOffset =
  ## Layer shell reservations plus nimdow's own bar, which sits below any
  ## layer surface reserving the top edge.
  (
    this.reserved.top + this.barHeight,
    this.reserved.left,
    this.reserved.bottom,
    this.reserved.right
  )

proc updateMonitor*(this: Monitor) =
  ## Recomputes the layout offset (bar space) and relayouts, e.g. after the
  ## output geometry changed.
  this.barHeight = this.reservedBarHeight()
  this.layoutOffset = this.calcLayoutOffset()
  for tag in this.taggedClients.tags:
    tag.layout.monitorArea = this.area
    if tag.layout of MasterStackLayout:
      cast[MasterStackLayout](tag.layout).setDefaultWidth(this.layoutOffset)
  this.doLayout()

########################################################
#### Helper procs, iterators, templates, and macros ####
########################################################

template tags*(this: Monitor): seq[Tag] =
  this.taggedClients.tags

template selectedTags*(this: Monitor): OrderedSet[TagID] =
  this.taggedClients.selectedTags

template clients*(this: Monitor): DoublyLinkedList[Client] =
  this.taggedClients.clients

template clientSelection*(this: Monitor): seq[Client] =
  this.taggedClients.clientSelection

proc windowSettings*(this: Monitor): WindowSettings = this.windowSettings

proc enableStatusBar*(this: Monitor) =
  this.isStatusBarEnabled = true
  this.updateMonitor()

proc disableStatusBar*(this: Monitor) =
  this.isStatusBarEnabled = false
  this.updateMonitor()

proc toggleStatusBar*(this: Monitor) =
  if this.statusBar == nil:
    log "Status bar is unavailable", lvlWarn
  elif this.isStatusBarEnabled:
    this.disableStatusBar()
  else:
    this.enableStatusBar()

proc syncStatusBar*(this: Monitor, isSelected: bool) =
  ## Hands the bar what it should show. The bar redraws only when this differs
  ## from what it last drew (see `StatusBar.flush`).
  if this.statusBar == nil:
    return
  let currClient = this.taggedClients.currClient
  var tagStates: seq[BarTag]
  for tagID in this.monitorSettings.tagSettings.keys():
    var state = BarTag(empty: true)
    for node in this.taggedClients.clientWithTagIter(tagID):
      state.empty = false
      state.urgent = state.urgent or node.value.isUrgent
      if node.value == currClient:
        state.hasCurrent = true
    state.selected = this.selectedTags.contains(tagID)
    tagStates.add state
  this.statusBar.update(
    tagStates,
    if currClient != nil: currClient.title else: "",
    isSelected
  )

proc setConfig*(this: Monitor, config: Config) =
  this.config = config
  this.windowSettings = config.windowSettings
  if config.monitorSettings.hasKey(this.id):
    this.monitorSettings = config.monitorSettings[this.id]
  else:
    this.monitorSettings = config.defaultMonitorSettings

  this.barHeight = this.reservedBarHeight()
  this.layoutOffset = this.calcLayoutOffset()
  if this.statusBar != nil:
    this.statusBar.setConfig(
      this.monitorSettings.barSettings, this.monitorSettings.tagSettings
    )

  for i, tag in this.tags:
    let tagSetting = this.monitorSettings.tagSettings[i + 1]
    tag.layout.gapSize = this.monitorSettings.layoutSettings.gapSize
    tag.layout.borderWidth = this.windowSettings.borderWidth
    tag.layout.masterSlots = tagSetting.numMasterWindows.uint
    let masterLayout = cast[MasterStackLayout](tag.layout)
    masterLayout.outerGap = this.monitorSettings.layoutSettings.outerGap
    masterLayout.defaultWidth = tagSetting.defaultMasterWidthPercentage
    masterLayout.setDefaultWidth(this.layoutOffset)

  for client in this.taggedClients.clients:
    if client.borderWidth != 0 or this.monitorSettings.layoutSettings.outerGap > 0:
      client.borderWidth = this.windowSettings.borderWidth
    client.oldBorderWidth = this.windowSettings.borderWidth

  this.doLayout()

proc setSelectedClient*(this: Monitor, client: Client) =
  ## Marks the client as the most recently selected. The selected client of the
  ## selected tags is what gets keyboard focus on the next manage sequence.
  if client != nil:
    if client.isUrgent:
      client.setUrgent(false)

    if this.clients.find(client.window) == nil:
      log "Attempted to select a client not on the current tags"
      return

    this.taggedClients.selectClient(client.window)

proc tagIDFromArg*(this: Monitor, arg: string): Option[TagID] =
  ## Parses a tag number from an action argument (the key name or IPC argument).
  try:
    let tagNumber = parseInt(arg)
    if tagNumber < 1 or tagNumber > this.tags.len:
      raise newException(Exception, "Invalid tag number: " & $tagNumber)

    return this.tags[tagNumber - 1].id.option
  except:
    log "Invalid tag number \"" & arg & "\": " & getCurrentExceptionMsg(), lvlError

proc focusClient*(this: Monitor, client: Client) =
  this.setSelectedClient(client)

proc doLayout*(this: Monitor) =
  ## Revalidates the current layout of the viewed tag(s).
  ## Only computes areas and visibility; nothing is sent to River until the
  ## next manage/render sequence.
  let tag = this.taggedClients.findFirstSelectedTag()
  if tag != nil:
    tag.layout.arrange(
      this.taggedClients.findCurrentClients(),
      this.layoutOffset
    )

  # Only the topmost (most recently selected) fullscreen client is shown while
  # there is one on the viewed tags, and it gets the focus.
  var topmostFullscreen: Client
  for client in this.taggedClients.currClientsSelectionNewToOldIter:
    if client.isFullscreen:
      topmostFullscreen = client
      break
  if topmostFullscreen != nil and
     this.taggedClients.currClient != topmostFullscreen:
    this.taggedClients.selectClient(topmostFullscreen.window)

  for client in this.clients.mitems:
    client.isVisible =
      client.tagIDs.anyIt(this.selectedTags.contains(it)) and
      (topmostFullscreen == nil or client == topmostFullscreen)

proc removeWindow*(this: Monitor, window: Window): bool =
  ## Returns if the window was removed.
  ## After a window is removed, you should typically call doLayout.
  return this.taggedClients.removeByWindow(window)

proc toggleTagsForClient*(
  this: Monitor,
  client: var Client,
  tagIDs: varargs[TagID]
) =
  # Cache if the client was on the current tags.
  let wasOnCurrTags = client.tagIDs.anyIt(this.selectedTags.contains(it))

  var firstTagToggledOff: int = 0
  for id in tagIDs:
    if client.tagIDs.contains(id):
      if firstTagToggledOff == 0:
        firstTagToggledOff = id
      client.tagIDs.excl(id)
    else:
      client.tagIDs.incl(id)

  # Ensure the client is assigned at least one tag.
  if client.tagIDs.len == 0:
    client.tagIDs.incl(firstTagToggledOff.TagID)

  # Perform the layout if the client was removed from the current tags.
  if wasOnCurrTags and not client.tagIDs.anyIt(this.selectedTags.contains(it)):
    this.doLayout()

proc toggleSelectedTagsForClient*(this: Monitor, client: var Client) =
  let selectedTags: OrderedSet[TagID] = this.selectedTags
  let tagIDs = toSeq(selectedTags.items)
  this.toggleTagsForClient(client, tagIDs)

proc addClient*(this: Monitor, client: var Client, assignToSelectedTags: bool = true) =
  this.clients.append(client)
  this.clientSelection.add(client)
  if assignToSelectedTags:
    client.tagIDs.clear()
    this.toggleSelectedTagsForClient(client)
  this.doLayout()

proc rotateClients*(this: Monitor) =
  let clientNode = this.taggedClients.findLastLayoutNode()
  if clientNode != nil:
    this.clients.remove(clientNode)
    this.clients.prepend(clientNode)
    this.doLayout()

proc moveClientToTag*(this: Monitor, client: Client, destinationTagID: TagID) =
  if client.tagIDs.len == 1 and destinationTagID in client.tagIDs:
    return

  # Change client tags to only destinationTag id.
  client.tagIDs.clear()
  client.tagIDs.incl(destinationTagID)

  this.doLayout()

  if destinationTagID in this.selectedTags:
    this.setSelectedClient(client)

proc moveSelectedWindowToTag*(this: Monitor, tagID: TagID) =
  this.taggedClients.withSomeCurrClient(client):
    this.moveClientToTag(client, tagID)

proc toggleTags*(this: Monitor, tagIDs: varargs[TagID]) =
  ## Views the given tags.

  for id in tagIDs:
    if this.selectedTags.contains(id):
      this.selectedTags.excl(id)
    else:
      this.selectedTags.incl(id)

  this.doLayout()

proc setSelectedTags*(this: Monitor, tagIDs: varargs[TagID]) =
  ## Views the given tags.

  # Select only the given tags
  this.selectedTags.clear()
  for id in tagIDs:
    this.selectedTags.incl(id)
  this.doLayout()

proc focusNextClient*(this: Monitor, reversed: bool) =
  ## Focuses the next client in the stack.
  let currClient = this.taggedClients.currClient
  if currClient != nil and currClient.isFullscreen:
    # Fullscreen clients should be the ONLY thing you interact with.
    return

  let node = this.taggedClients.findNextCurrClient(currClient, reversed)
  if node != nil:
    this.focusClient(node.value)

proc focusNextClient*(this: Monitor) =
  ## Focuses the next client in the stack.
  this.focusNextClient(false)

proc focusPreviousClient*(this: Monitor) =
  ## Focuses the previous client in the stack.
  this.focusNextClient(true)

proc moveClientNext*(
  this: Monitor,
  reversed: bool
) =
  ## Moves the client to the next position in the stack.
  var currNode = this.taggedClients.currClientNode
  if currNode == nil:
    return

  var node = this.taggedClients.findNextCurrClient(
    currNode.value,
    reversed,
    (client: Client) => not client.isFloating and not client.isFixedSize
  )

  if node != nil and node.value != nil:
    swap(currNode, node)
    this.setSelectedClient(node.value)
    this.doLayout()

proc moveClientNext*(this: Monitor) =
  ## Moves the client to the next position in the stack.
  this.moveClientNext(false)

proc moveClientPrevious*(this: Monitor) =
  ## Moves the client to the previous position in the stack.
  this.moveClientNext(true)

proc setFullscreen*(this: Monitor, client: Client, fullscreen: bool) =
  ## Fullscreen is realised by `river_window_v1.fullscreen` in the next manage
  ## sequence; here only the state changes. The client's own area is kept so it
  ## is restored when leaving fullscreen.
  if client.isFullscreen == fullscreen:
    return
  client.isFullscreen = fullscreen
  this.doLayout()

proc toggleFullscreenForSelectedClient*(this: Monitor) =
  this.taggedClients.withSomeCurrClient(client):
    this.setFullscreen(client, not client.isFullscreen)

proc setFloating*(this: Monitor, client: Client, floating: bool) =
  ## Changes the client's floating state and relayouts. A floating client keeps
  ## the area it had (the last tiled area when it was tiled before).
  if floating == client.isFloating:
    return

  client.oldFloatingState = client.isFloating
  client.isFloating = floating

  if floating:
    if client.borderWidth == 0:
      client.oldBorderWidth = 0
      client.borderWidth = this.windowSettings.borderWidth
    let
      maxWidth = this.area.width.int - this.layoutOffset.left.int -
        this.layoutOffset.right.int - client.borderWidth.int * 2
      maxHeight = this.area.height.int - this.layoutOffset.top.int -
        this.layoutOffset.bottom.int - client.borderWidth.int * 2
    if client.width.int > maxWidth and maxWidth > 0:
      client.width = maxWidth.uint
    if client.height.int > maxHeight and maxHeight > 0:
      client.height = maxHeight.uint

  this.doLayout()

proc toggleFloatingForSelectedClient*(this: Monitor) =
  this.taggedClients.withSomeCurrClient(client):
    if client.isFixedSize or client.isFullscreen:
      return
    this.setFloating(client, not client.isFloating)

proc findNext*(monitors: openArray[Monitor], current: Monitor): int =
  ## Finds the next monitor index from index `i` (exclusive), iterating forward.
  ## This search will loop the array.
  for i in countup(monitors.low, monitors.high):
    if monitors[i] == current:
      if i == monitors.high:
        return monitors.low
      return i + 1
  return -1

proc findPrevious*(monitors: openArray[Monitor], current: Monitor): int =
  ## Finds the next monitor index from index `i` (exclusive), iterating backward.
  ## This search will loop the array.
  for i in countdown(monitors.high, monitors.low):
    if monitors[i] == current:
      if i == monitors.low:
        return monitors.high
      return i - 1
  return -1

proc find*(monitors: OrderedTable[MonitorID, Monitor], x, y: int): tuple[index: int, monitor: Monitor] =
  ## Finds a monitor's index based on the given location.
  ## -1 is returned if no monitors contain the location.

  for i, monitor in monitors:
    if monitor.area.contains(x, y):
      return (i, monitor)

  var shortestDist = float.high
  # Find the closest monitor based on distance to its center.
  for i, monitor in monitors:
    let dist = min(shortestDist, monitor.area.distanceToCenterSquared(x, y))
    if dist < shortestDist:
      shortestDist = dist
      result = (i, monitor)
