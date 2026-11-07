# Nim port of tinyrwm (https://codeberg.org/river/tinyrwm, c/tinyrwm.c by Isaac
# Freund, 0BSD): a minimal River window manager.
#
# Bindings (Super = Mod4):
#   Super+Space     spawn a terminal
#   Super+Q         close the focused window
#   Super+N         focus the bottom-most window (cycles the stack)
#   Super+Escape    exit the session
#   Super+LMB drag  move the hovered window
#   Super+RMB drag  resize the hovered window

import std/[posix, os, selectors]
import nimdowpkg/wl/client
import nimdowpkg/wl/protocols/[river_window_management_v1, river_xkb_bindings_v1]

const
  Terminal = "alacritty"

  # xkbcommon keysyms (xkbcommon-keysyms.h) and linux input event codes.
  KeySpace = 0x0020'u32
  KeyQ = 0x0071'u32
  KeyN = 0x006e'u32
  KeyEscape = 0xff1b'u32
  BtnLeft = 0x110'u32
  BtnRight = 0x111'u32

type
  Action = enum
    aNone, aSpawnTerminal, aClose, aFocusNext, aMove, aResize, aExit

  SeatOp = enum
    opNone, opMove, opResize

  Output = ref object
    obj: RiverOutputV1
    removed: bool

  Seat = ref object
    obj: RiverSeatV1
    isNew, removed: bool
    focused, hovered, interacted: Window
    xkbBindings: seq[XkbBinding]
    pointerBindings: seq[PointerBinding]
    pendingAction: Action
    op: SeatOp
    # for opMove and opResize
    opWindow: Window
    opStartX, opStartY: int32
    opDx, opDy: int32
    opRelease: bool
    # for opResize only
    opStartWidth, opStartHeight: int32
    opEdges: uint32

  Window = ref object
    obj: RiverWindowV1
    node: RiverNodeV1
    isNew, closed: bool
    x, y, width, height: int32
    pointerMoveRequested: Seat
    pointerResizeRequested: Seat
    pointerResizeRequestedEdges: uint32

  XkbBinding = ref object
    obj: RiverXkbBindingV1
    seat: Seat
    action: Action

  PointerBinding = ref object
    obj: RiverPointerBindingV1
    seat: Seat
    action: Action

  WindowManager = object
    outputs: seq[Output]
    windows: seq[Window] # bottom to top
    seats: seq[Seat]

var
  wm: WindowManager
  windowManager: RiverWindowManagerV1
  xkbBindings: RiverXkbBindingsV1

# Objects handed to libwayland as listener data are pinned with GC_ref and
# released again (GC_unref) when the corresponding protocol object is destroyed.
proc dropAt[T](s: var seq[T], item: T) =
  let i = s.find(item)
  if i >= 0: s.delete i

# --- outputs ---

proc outputRemoved(data: pointer, obj: RiverOutputV1) {.cdecl.} =
  cast[Output](data).removed = true

var outputListener = river_output_v1_noop_listener()
outputListener.removed = outputRemoved

proc outputMaybeDestroy(output: Output) =
  if not output.removed: return
  river_output_v1_destroy(output.obj)
  wm.outputs.dropAt output
  GC_unref output

# --- windows ---

proc windowClosed(data: pointer, obj: RiverWindowV1) {.cdecl.} =
  cast[Window](data).closed = true

proc windowDimensions(data: pointer, obj: RiverWindowV1, width, height: int32) {.cdecl.} =
  let window = cast[Window](data)
  window.width = width
  window.height = height

proc windowPointerMoveRequested(data: pointer, obj: RiverWindowV1,
    seat: RiverSeatV1) {.cdecl.} =
  cast[Window](data).pointerMoveRequested = cast[Seat](river_seat_v1_get_user_data(seat))

proc windowPointerResizeRequested(data: pointer, obj: RiverWindowV1,
    seat: RiverSeatV1, edges: uint32) {.cdecl.} =
  let window = cast[Window](data)
  window.pointerResizeRequested = cast[Seat](river_seat_v1_get_user_data(seat))
  window.pointerResizeRequestedEdges = edges

var windowListener = river_window_v1_noop_listener()
windowListener.closed = windowClosed
windowListener.dimensions = windowDimensions
windowListener.pointer_move_requested = windowPointerMoveRequested
windowListener.pointer_resize_requested = windowPointerResizeRequested

proc windowSetPosition(window: Window, x, y: int32) =
  river_node_v1_set_position(window.node, x, y)
  window.x = x
  window.y = y

# --- bindings ---

proc xkbBindingPressed(data: pointer, obj: RiverXkbBindingV1) {.cdecl.} =
  let binding = cast[XkbBinding](data)
  binding.seat.pendingAction = binding.action

var xkbBindingListener = river_xkb_binding_v1_noop_listener()
xkbBindingListener.pressed = xkbBindingPressed

proc xkbBindingDestroy(binding: XkbBinding) =
  river_xkb_binding_v1_destroy(binding.obj)
  GC_unref binding

proc xkbBindingCreate(seat: Seat, mods: uint32, keysym: uint32, action: Action) =
  let binding = XkbBinding(seat: seat, action: action)
  binding.obj = river_xkb_bindings_v1_get_xkb_binding(xkbBindings, seat.obj, keysym, mods)
  GC_ref binding
  discard river_xkb_binding_v1_add_listener(binding.obj, addr xkbBindingListener,
      cast[pointer](binding))
  river_xkb_binding_v1_enable(binding.obj)
  seat.xkbBindings.add binding

proc pointerBindingPressed(data: pointer, obj: RiverPointerBindingV1) {.cdecl.} =
  let binding = cast[PointerBinding](data)
  binding.seat.pendingAction = binding.action

var pointerBindingListener = river_pointer_binding_v1_noop_listener()
pointerBindingListener.pressed = pointerBindingPressed

proc pointerBindingDestroy(binding: PointerBinding) =
  river_pointer_binding_v1_destroy(binding.obj)
  GC_unref binding

proc pointerBindingCreate(seat: Seat, mods: uint32, button: uint32, action: Action) =
  let binding = PointerBinding(seat: seat, action: action)
  binding.obj = river_seat_v1_get_pointer_binding(seat.obj, button, mods)
  GC_ref binding
  discard river_pointer_binding_v1_add_listener(binding.obj, addr pointerBindingListener,
      cast[pointer](binding))
  river_pointer_binding_v1_enable(binding.obj)
  seat.pointerBindings.add binding

# --- seats ---

proc seatRemoved(data: pointer, obj: RiverSeatV1) {.cdecl.} =
  cast[Seat](data).removed = true

proc seatPointerEnter(data: pointer, obj: RiverSeatV1, window: RiverWindowV1) {.cdecl.} =
  cast[Seat](data).hovered = cast[Window](river_window_v1_get_user_data(window))

proc seatPointerLeave(data: pointer, obj: RiverSeatV1) {.cdecl.} =
  cast[Seat](data).hovered = nil

proc seatWindowInteraction(data: pointer, obj: RiverSeatV1, window: RiverWindowV1) {.cdecl.} =
  cast[Seat](data).interacted = cast[Window](river_window_v1_get_user_data(window))

proc seatOpDelta(data: pointer, obj: RiverSeatV1, dx, dy: int32) {.cdecl.} =
  let seat = cast[Seat](data)
  seat.opDx = dx
  seat.opDy = dy

proc seatOpRelease(data: pointer, obj: RiverSeatV1) {.cdecl.} =
  cast[Seat](data).opRelease = true

var seatListener = river_seat_v1_noop_listener()
seatListener.removed = seatRemoved
seatListener.pointer_enter = seatPointerEnter
seatListener.pointer_leave = seatPointerLeave
seatListener.window_interaction = seatWindowInteraction
seatListener.op_delta = seatOpDelta
seatListener.op_release = seatOpRelease

proc seatMaybeDestroy(seat: Seat) =
  if not seat.removed: return
  for b in seat.xkbBindings: xkbBindingDestroy b
  for b in seat.pointerBindings: pointerBindingDestroy b
  seat.xkbBindings.setLen 0
  seat.pointerBindings.setLen 0
  river_seat_v1_destroy(seat.obj)
  wm.seats.dropAt seat
  GC_unref seat

proc windowMaybeDestroy(window: Window) =
  if not window.closed: return
  for seat in wm.seats:
    if seat.focused == window:
      seat.focused = nil
    # Not in tinyrwm.c: avoid keeping a destroyed window as a request target.
    if seat.hovered == window: seat.hovered = nil
    if seat.interacted == window: seat.interacted = nil
    if seat.opWindow == window:
      river_seat_v1_op_end(seat.obj)
      seat.op = opNone
      seat.opWindow = nil
  river_window_v1_destroy(window.obj)
  wm.windows.dropAt window
  GC_unref window

proc seatFocus(seat: Seat, target: Window) =
  var window = target
  # Focus the top window (if any) when there is no explicit target.
  if window.isNil and wm.windows.len > 0:
    window = wm.windows[^1]

  if seat.focused == window: return

  if not window.isNil:
    river_seat_v1_focus_window(seat.obj, window.obj)
    river_node_v1_place_top(window.node)
    wm.windows.dropAt window
    wm.windows.add window
  else:
    river_seat_v1_clear_focus(seat.obj)

  seat.focused = window

proc seatPointerMove(seat: Seat, window: Window) =
  seatFocus(seat, window)
  river_seat_v1_op_start_pointer(seat.obj)
  seat.op = opMove
  seat.opWindow = window
  seat.opStartX = window.x
  seat.opStartY = window.y
  seat.opDx = 0
  seat.opDy = 0

proc seatPointerResize(seat: Seat, window: Window, edges: uint32) =
  seatFocus(seat, window)
  river_window_v1_inform_resize_start(window.obj)
  river_seat_v1_op_start_pointer(seat.obj)
  seat.op = opResize
  seat.opWindow = window
  seat.opEdges = edges
  seat.opStartX = window.x
  seat.opStartY = window.y
  seat.opStartWidth = window.width
  seat.opStartHeight = window.height
  seat.opDx = 0
  seat.opDy = 0

proc spawnTerminal() =
  let pid = fork()
  if pid == 0:
    var args = allocCStringArray([Terminal])
    discard execvp(Terminal, args)
    posix.exitnow(1)

proc seatAction(seat: Seat, action: Action) =
  case action
  of aNone: discard
  of aSpawnTerminal: spawnTerminal()
  of aClose:
    if not seat.focused.isNil:
      river_window_v1_close(seat.focused.obj)
  of aFocusNext:
    if wm.windows.len > 0:
      # Focus the bottom window
      seatFocus(seat, wm.windows[0])
  of aMove:
    if seat.op == opNone and not seat.hovered.isNil:
      seatPointerMove(seat, seat.hovered)
  of aResize:
    if seat.op == opNone and not seat.hovered.isNil:
      seatPointerResize(seat, seat.hovered,
          RIVER_WINDOW_V1_EDGES_BOTTOM or RIVER_WINDOW_V1_EDGES_RIGHT)
  of aExit:
    river_window_manager_v1_exit_session(windowManager)

proc windowManage(window: Window) =
  if window.isNew:
    window.isNew = false
    windowSetPosition(window, 0, 0)
    river_window_v1_propose_dimensions(window.obj, 0, 0)
  if not window.pointerMoveRequested.isNil:
    seatPointerMove(window.pointerMoveRequested, window)
    window.pointerMoveRequested = nil
  if not window.pointerResizeRequested.isNil:
    seatPointerResize(window.pointerResizeRequested, window,
        window.pointerResizeRequestedEdges)
    window.pointerResizeRequested = nil

proc seatManage(seat: Seat) =
  if seat.isNew:
    seat.isNew = false
    const super = RIVER_SEAT_V1_MODIFIERS_MOD4
    xkbBindingCreate(seat, super, KeySpace, aSpawnTerminal)
    xkbBindingCreate(seat, super, KeyQ, aClose)
    xkbBindingCreate(seat, super, KeyN, aFocusNext)
    xkbBindingCreate(seat, super, KeyEscape, aExit)
    pointerBindingCreate(seat, super, BtnLeft, aMove)
    pointerBindingCreate(seat, super, BtnRight, aResize)

  # If no window was interacted with in the current manage sequence,
  # intentionally pass nil to ensure the window on top has focus.
  # This is necessary to handle new windows for example.
  seatFocus(seat, seat.interacted)
  seat.interacted = nil

  seatAction(seat, seat.pendingAction)
  seat.pendingAction = aNone

  case seat.op
  of opNone: discard
  of opMove:
    if seat.opRelease:
      river_seat_v1_op_end(seat.obj)
      seat.op = opNone
      seat.opWindow = nil
  of opResize:
    if seat.opRelease:
      river_window_v1_inform_resize_end(seat.opWindow.obj)
      river_seat_v1_op_end(seat.obj)
      seat.op = opNone
      seat.opWindow = nil
    else:
      var width = seat.opStartWidth
      var height = seat.opStartHeight
      if (seat.opEdges and RIVER_WINDOW_V1_EDGES_LEFT) != 0: width -= seat.opDx
      if (seat.opEdges and RIVER_WINDOW_V1_EDGES_RIGHT) != 0: width += seat.opDx
      if (seat.opEdges and RIVER_WINDOW_V1_EDGES_TOP) != 0: height -= seat.opDy
      if (seat.opEdges and RIVER_WINDOW_V1_EDGES_BOTTOM) != 0: height += seat.opDy
      river_window_v1_propose_dimensions(seat.opWindow.obj, max(width, 1'i32),
          max(height, 1'i32))
  seat.opRelease = false

proc seatRender(seat: Seat) =
  case seat.op
  of opNone: discard
  of opMove:
    windowSetPosition(seat.opWindow, seat.opStartX + seat.opDx, seat.opStartY + seat.opDy)
  of opResize:
    var x = seat.opStartX
    var y = seat.opStartY
    if (seat.opEdges and RIVER_WINDOW_V1_EDGES_LEFT) != 0:
      x += seat.opStartWidth - seat.opWindow.width
    if (seat.opEdges and RIVER_WINDOW_V1_EDGES_TOP) != 0:
      y += seat.opStartHeight - seat.opWindow.height
    windowSetPosition(seat.opWindow, x, y)

# --- window manager ---

proc wmUnavailable(data: pointer, obj: RiverWindowManagerV1) {.cdecl.} =
  stderr.writeLine "error: another window manager is already running"
  quit(1)

proc wmFinished(data: pointer, obj: RiverWindowManagerV1) {.cdecl.} =
  quit(0)

proc wmManageStart(data: pointer, obj: RiverWindowManagerV1) {.cdecl.} =
  # Destroy closed windows and removed outputs/seats. Iterate over copies since
  # the destroy procs modify the lists.
  for output in wm.outputs[0 .. ^1]: outputMaybeDestroy output
  for window in wm.windows[0 .. ^1]: windowMaybeDestroy window
  for seat in wm.seats[0 .. ^1]: seatMaybeDestroy seat

  # Carry out window management policy (windowManage may reorder wm.windows).
  for window in wm.windows[0 .. ^1]: windowManage window
  for seat in wm.seats[0 .. ^1]: seatManage seat

  river_window_manager_v1_manage_finish(windowManager)

proc wmRenderStart(data: pointer, obj: RiverWindowManagerV1) {.cdecl.} =
  for seat in wm.seats: seatRender seat
  river_window_manager_v1_render_finish(windowManager)

proc wmWindow(data: pointer, obj: RiverWindowManagerV1, w: RiverWindowV1) {.cdecl.} =
  let window = Window(obj: w, isNew: true)
  window.node = river_window_v1_get_node(w)
  GC_ref window
  discard river_window_v1_add_listener(w, addr windowListener, cast[pointer](window))
  wm.windows.add window

proc wmOutput(data: pointer, obj: RiverWindowManagerV1, o: RiverOutputV1) {.cdecl.} =
  let output = Output(obj: o)
  GC_ref output
  discard river_output_v1_add_listener(o, addr outputListener, cast[pointer](output))
  wm.outputs.add output

proc wmSeat(data: pointer, obj: RiverWindowManagerV1, s: RiverSeatV1) {.cdecl.} =
  let seat = Seat(obj: s, isNew: true)
  GC_ref seat
  discard river_seat_v1_add_listener(s, addr seatListener, cast[pointer](seat))
  wm.seats.add seat

var wmListener = river_window_manager_v1_noop_listener()
wmListener.unavailable = wmUnavailable
wmListener.finished = wmFinished
wmListener.manage_start = wmManageStart
wmListener.render_start = wmRenderStart
wmListener.window = wmWindow
wmListener.output = wmOutput
wmListener.seat = wmSeat

# --- main ---

proc fatal(msg: string) =
  stderr.writeLine msg
  quit(1)

proc main() =
  let display = connect()
  if display.isNil:
    fatal "failed to connect to Wayland server"

  # Avoid passing WAYLAND_DEBUG on to our children.
  # It only matters if it's set when the display is created.
  delEnv("WAYLAND_DEBUG")

  # Ensure children are automatically reaped.
  signal(SIGCHLD, SIG_IGN)

  let registry = discoverGlobals(display)
  let wmGlobal = registry.find("river_window_manager_v1")
  let xkbGlobal = registry.find("river_xkb_bindings_v1")
  if wmGlobal.version >= 4:
    windowManager = bindGlobal[RiverWindowManagerV1](registry, wmGlobal,
        river_window_manager_v1_interface, 4)
  if xkbGlobal.version >= 1:
    xkbBindings = bindGlobal[RiverXkbBindingsV1](registry, xkbGlobal,
        river_xkb_bindings_v1_interface, 1)

  if windowManager.isNil or xkbBindings.isNil:
    fatal "river_window_manager_v1 or river_xkb_bindings_v1 " &
        "not supported by the Wayland server"

  discard river_window_manager_v1_add_listener(windowManager, addr wmListener, nil)

  let fd = display.fd()
  let selector = newSelector[int]()
  selector.registerHandle(fd.int, {Event.Read}, 0)

  while true:
    # Standard libwayland read protocol: dispatch whatever is queued, flush our
    # requests, wait for the socket, then read and dispatch.
    prepareRead(display)

    var flushed = true
    if display.flush() < 0:
      if errno != EAGAIN:
        display.cancelRead()
        fatal "flush failed"
      flushed = false
    selector.updateHandle(fd.int, if flushed: {Event.Read} else: {Event.Read, Event.Write})

    var readable = false
    for key in selector.select(-1):
      if Event.Read in key.events or Event.Error in key.events:
        readable = true

    if readable:
      if display.readEvents() < 0: fatal "dispatch failed"
    else:
      display.cancelRead()

    if display.dispatchPending() < 0: fatal "dispatch failed"

main()
