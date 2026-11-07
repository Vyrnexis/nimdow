import
  hashes,
  sets

import
  area,
  taginfo,
  wl/protocols/river_window_management_v1

type
  PointerRequestKind* = enum
    prNone, prMove, prResize

  FullscreenRequest* = enum
    frNone, frEnter, frExit

  Window* = RiverWindowV1
  ## The river window handle is what identifies a client.

  Client* = ref object of RootObj
    window*: Window
    node*: RiverNodeV1
    tagIDs*: HashSet[TagID]
    # Desired state. Event handlers and actions only change these fields;
    # they are flushed to River during the next manage/render sequence.
    area*: Area
    oldArea*: Area
    borderWidth*: uint
    oldBorderWidth*: uint
    ## Desired visibility (the monitor's selected tags contain one of our tags).
    isVisible*: bool
    isFullscreen*: bool
    isFloating*: bool
    oldFloatingState*: bool
    # Non-resizable
    isFixedSize*: bool
    needsResize*: bool
    needsFullscreen*: bool
    isUrgent*: bool
    # Bookkeeping for the pending-state flush.
    ## No state has been sent to River for this client yet.
    isNew*: bool
    ## River told us the window is gone; destroyed at the next manage sequence.
    isClosed*: bool
    ## close() must be sent during the next manage sequence.
    closeRequested*: bool
    ## Last visibility sent to River.
    sentVisible*: bool
    # Window info reported by River.
    appId*: string
    title*: string
    ## The window has a parent (dialog/transient); it floats.
    hasParent*: bool
    ## Preferred min/max size (river_window_v1.dimensions_hint); 0 = no preference.
    minWidth*, minHeight*, maxWidth*, maxHeight*: int
    ## parent/dimensions_hint changed; re-evaluated in the next manage sequence.
    hintsDirty*: bool
    ## Place the (floating) client in the middle of its monitor once its size is known.
    needsCenter*: bool
    ## Requests made by the client, handled in the next manage sequence.
    fullscreenRequest*: FullscreenRequest
    pointerRequest*: PointerRequestKind
    pointerRequestSeat*: RiverSeatV1
    pointerRequestEdges*: uint32
    # What was last sent to River.
    sentFullscreen*: bool
    sentFullscreenOutput*: RiverOutputV1
    sentTiled*: bool
    ## Dimensions the window actually took (river_window_v1.dimensions).
    reportedWidth*, reportedHeight*: int
    # Clients start as unmapped; this property signifies if it was ever mapped.
    hasBeenMapped*: bool

proc hash*(this: Client): Hash

proc newClient*(window: Window, tagIDs: varargs[TagID]): Client =
  Client(
    window: window,
    tagIDs: tagIDs.toHashSet(),
    isNew: true,
    sentVisible: true, # River considers new windows shown.
    hasBeenMapped: false
  )

# Area helper procs
proc x*(this: Client): int = this.area.x
proc `x=`*(this: Client, x: int) {.inline.} = this.area.x = x
proc y*(this: Client): int = this.area.y
proc `y=`*(this: Client, y: int) {.inline.} = this.area.y = y
proc width*(this: Client): uint = this.area.width
proc `width=`*(this: Client, width: uint) {.inline.} = this.area.width = width
proc height*(this: Client): uint = this.area.height
proc `height=`*(this: Client, height: uint) {.inline.} = this.area.height = height

# Old area helper procs
proc oldX*(this: Client): int = this.oldArea.x
proc `oldx=`*(this: Client, x: int) {.inline.} = this.oldArea.x = x
proc oldY*(this: Client): int = this.oldArea.y
proc `oldy=`*(this: Client, y: int) {.inline.} = this.oldArea.y = y
proc oldWidth*(this: Client): uint = this.oldArea.width
proc `oldwidth=`*(this: Client, width: uint) {.inline.} = this.oldArea.width = width
proc oldHeight*(this: Client): uint = this.oldArea.height
proc `oldheight=`*(this: Client, height: uint) {.inline.} = this.oldArea.height = height

proc totalWidth*(this: Client): int {.inline.} = this.width.int + this.borderWidth.int * 2
proc totalHeight*(this: Client): int {.inline.} = this.height.int + this.borderWidth.int * 2

proc resize*(this: Client, x, y: int, width, height: uint) =
  ## Records the desired area (excluding border); applied on the next manage/render.
  this.oldArea = this.area
  this.area = (x, y, width, height)

proc setLocation*(this: Client, x, y: int) =
  this.oldX = this.x
  this.x = x
  this.oldY = this.y
  this.y = y

proc setUrgent*(this: Client, isUrgent: bool) =
  this.isUrgent = isUrgent

proc isNormal*(this: Client): bool =
  ## If the client is "normal".
  ## This currently means the client is not fixed.
  not this.isFixedSize

func find*[T](clients: openArray[T], window: Window): int =
  ## Finds a Client's index by its relative window.
  ## If a client is not found, -1 is returned.
  for i, client in clients:
    if client.window == window:
      return i
  return -1

proc findNext(clients: openArray[Client], i: int = 0, condition: proc(client: Client): bool): int =
  ## Finds the next client index from index `i` (exclusive), iterating forward.
  ## This search will loop the array.
  for j in countup(i + 1, clients.high):
    if condition(clients[j]):
      return j
  for j in countup(clients.low, i - 1):
    if condition(clients[j]):
      return j
  return -1

proc findPrevious*(clients: openArray[Client], i: int = 0, condition: proc(client: Client): bool): int =
  ## Finds the next client index from index `i` (exclusive), iterating backward.
  ## This search will loop the array.
  for j in countdown(i - 1, clients.low):
    if condition(clients[j]):
      return j
  for j in countdown(clients.high, i + 1):
    if condition(clients[j]):
      return j
  return -1

proc findNextNormal*(clients: openArray[Client], i: int = 0): int =
  ## Finds the next normal client index from index `i` (exclusive), iterating forward.
  ## This search will loop the array.
  return findNext(clients, i, proc (client: Client): bool = client.isNormal)

proc findNextTiled*(clients: openArray[Client], i: int = 0): int =
  ## Finds the next tiled client index from index `i` (exclusive), iterating forward.
  ## This search will loop the array.
  return findNext(
    clients,
    i,
    proc (client: Client): bool =
      client.isNormal and not client.isFloating and not client.isFullscreen
  )

proc findPreviousNormal*(clients: openArray[Client], i: int = 0): int =
  ## Finds the next normal client index from index `i` (exclusive), iterating backward.
  ## This search will loop the array.
  return findPrevious(clients, i, proc (client: Client): bool = client.isNormal)

proc findPreviousTiled*(clients: openArray[Client], i: int = 0): int =
  ## Finds the next tiled client index from index `i` (exclusive), iterating backward.
  ## This search will loop the array.
  return findPrevious(
    clients,
    i,
    proc (client: Client): bool =
      client.isNormal and not client.isFloating and not client.isFullscreen
  )

proc hash*(this: Client): Hash = !$hash(cast[int](this.window))

