## Popup menus for the tray's dbusmenu sessions: one `river_shell_surface_v1`
## per menu level (the root menu and its open submenus), drawn with cairo +
## pango into a double-buffered wl_shm pool, like the status bar (same fonts
## and colors, fractional scale through wp_viewporter).
##
## The menu *data* lives in the tray (`Tray.menu`, see tray.nim); this module
## only shows it. The state machine runs in manage sequences (`manage`):
##  * pointer events of the popup surfaces (routed by statusbar.nim through
##    `InputTarget`) and key events of the seat's wl_keyboard are queued and
##    handled there; hover only changes the highlight, which is redrawn by
##    the next `flush`;
##  * popups are created/destroyed to follow the tray's session, positions
##    are computed from the clicked icon (below the bar, flipped up when it
##    does not fit, submenus to the right, flipped left when needed);
##  * the root popup gets the seat's keyboard focus (`keyboardShell`, applied
##    by the window manager with river_seat_v1.focus_shell_surface).
## `flush` (render sequence) positions the nodes, places them on top of
## everything and commits changed buffers.

import
  std/[posix, tables, strutils, json]

import
  logger,
  config/configloader,
  statusbar,
  tray/tray,
  tray/icons,
  wl/client as wlclient,
  wl/cairo,
  wl/protocols/[river_window_management_v1, viewporter, fractional_scale_v1]

{.passC: gorge("pkg-config --cflags xkbcommon").}

const
  border = 1
  padV = 3
  markerW = 24
  textGap = 8
  arrowW = 20
  separatorH = 7
  iconSize = 16
  # Keysyms (xkbcommon-keysyms.h).
  keyEscape = 0xff1b'u32
  keyReturn = 0xff0d'u32
  keyKpEnter = 0xff8d'u32
  keySpace = 0x20'u32
  keyUp = 0xff52'u32
  keyDown = 0xff54'u32
  keyLeft = 0xff51'u32
  keyRight = 0xff53'u32
  # Timers (milliseconds).
  hoverOpenMs = 200
  hoverSwitchMs = 300
  tooltipMs = 600
  defaultRepeatRate = 25
  defaultRepeatDelay = 600
  tipPadH = 6

type
  Row = object
    ## Position inside the popup.
    y, h: int
    entry: MenuEntry

  ShmBuf = ref object
    popup: MenuPopup
    buffer: WlBuffer
    busy: bool

  MenuPopup = ref object
    mgr: MenuManager
    ## 0: the root menu.
    level: int
    ## dbusmenu id of the entry this popup is the submenu of (0: the root).
    parentId: int
    entries: seq[MenuEntry]
    rows: seq[Row]
    ## Index of the highlighted row, -1: none.
    selected: int
    ## Position on the screen and size, in logical pixels.
    x, y, width, height: int
    ## Incremented when the content or the layout changed.
    contentGen: int
    target: InputTarget
    surface: WlSurface
    shell: RiverShellSurfaceV1
    node: RiverNodeV1
    viewport: WpViewport
    fractional: WpFractionalScaleV1
    scale120: int
    mem: pointer
    memSize: int
    bufW, bufH: int
    buffers: array[2, ShmBuf]
    nextBuffer: int
    mapped: bool
    drawnKey: string
    icons: Table[string, CairoSurface]
    ## Not empty: this is a tooltip showing these lines (no rows, no input).
    tip: seq[string]

  MenuInputKind = enum
    miHover, miClick, miKey

  MenuInput = object
    kind: MenuInputKind
    popup: MenuPopup
    row: int
    sym: uint32

  MenuManager* = ref object
    ctx: BarContext
    popups: seq[MenuPopup]
    ## The tray session and its tree version the popups show.
    gen, version: int
    ## The bar whose style (colors, font) and scale the popups use.
    bar: StatusBar
    area: tuple[x, y, w, h: int]
    ## The clicked icon (position on the screen) and the bottom of the bar.
    anchorX, anchorY, anchorBottom: int
    inputs: seq[MenuInput]
    ## Hover intent: the submenu of entry `pendEntry` of `pendPopup` is opened
    ## (or the open one closed) at `pendDue` unless the pointer moved on.
    pendPopup: MenuPopup
    pendEntry: int
    pendDue: int64
    ## Key repeat (wl_keyboard.repeat_info) of the held Up/Down key.
    repeatRate, repeatDelay: int
    heldKey, heldSym: uint32
    nextRepeat: int64
    repeatCount: int
    ## Tooltip: the tray icon under the pointer (-1: none) and when its
    ## tooltip is due (0: not pending).
    tip: MenuPopup
    tipUid: int
    hoverBar: StatusBar
    hoverUid, suppressUid: int
    hoverDue: int64
    ## `checkTimers` told the event loop about the due timers.
    timerNotified: bool
    pendingFlush: bool
    keyboardFocused: bool
    keyboardSurface: WlSurface
    # xkbcommon
    xkbContext, xkbKeymap, xkbState: pointer

proc memfd_create(name: cstring, flags: cuint): cint
  {.importc, header: "<sys/mman.h>".}

proc xkb_context_new(flags: cint): pointer
  {.importc, header: "<xkbcommon/xkbcommon.h>".}
proc xkb_keymap_new_from_buffer(ctx: pointer, buffer: cstring, length: csize_t,
  format, flags: cint): pointer {.importc, header: "<xkbcommon/xkbcommon.h>".}
proc xkb_keymap_unref(keymap: pointer) {.importc, header: "<xkbcommon/xkbcommon.h>".}
proc xkb_state_new(keymap: pointer): pointer {.importc, header: "<xkbcommon/xkbcommon.h>".}
proc xkb_state_unref(state: pointer) {.importc, header: "<xkbcommon/xkbcommon.h>".}
proc xkb_state_update_mask(state: pointer, depressed, latched, locked, depressedLayout,
  latchedLayout, lockedLayout: uint32): cint {.importc, header: "<xkbcommon/xkbcommon.h>".}
proc xkb_state_key_get_one_sym(state: pointer, key: uint32): uint32
  {.importc, header: "<xkbcommon/xkbcommon.h>".}

proc selectable(entry: MenuEntry): bool = entry.enabled and not entry.separator

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

proc toRgba(hex: int, alpha = 1.0): tuple[r, g, b, a: float] =
  (((hex shr 16) and 0xff).float / 255, ((hex shr 8) and 0xff).float / 255,
    (hex and 0xff).float / 255, alpha)

proc oneLine(s: string): string =
  result = s
  for c in result.mitems:
    if c in {'\n', '\r', '\t'}:
      c = ' '

proc newLayout(cr: Cairo, text: string, desc: PangoFontDescription): PangoLayout =
  result = pango_cairo_create_layout(cr)
  pango_layout_set_font_description(result, desc)
  pango_layout_set_text(result, text.cstring, text.len.cint)

proc textSize(cr: Cairo, text: string, desc: PangoFontDescription): tuple[w, h: int] =
  let layout = newLayout(cr, text, desc)
  var w, h: cint
  pango_layout_get_pixel_size(layout, addr w, addr h)
  g_object_unref(layout)
  (w.int, h.int)

proc computeLayout(popup: MenuPopup) =
  ## Rows and size from the entries and the bar's font.
  let
    m = popup.mgr
    settings = m.bar.barSettings
    desc = m.bar.fontDescription
    surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1)
    cr = cairo_create(surface)
  let
    textH = textSize(cr, "Ag", desc).h
    rowH = max(m.bar.height, textH + 6)
  if popup.tip.len > 0:
    var maxW = 0
    for line in popup.tip:
      maxW = max(maxW, textSize(cr, oneLine(line), desc).w)
    popup.width = maxW + 2 * (border + tipPadH)
    popup.height = textH * popup.tip.len + 2 * (border + padV)
    cairo_destroy(cr)
    cairo_surface_destroy(surface)
    inc popup.contentGen
    return
  var
    y = border + padV
    maxText = 0
  popup.rows.setLen 0
  for entry in popup.entries:
    if entry.separator:
      popup.rows.add Row(y: y, h: separatorH, entry: entry)
      y += separatorH
    else:
      maxText = max(maxText, textSize(cr, oneLine(entry.label), desc).w)
      popup.rows.add Row(y: y, h: rowH, entry: entry)
      y += rowH
  cairo_destroy(cr)
  cairo_surface_destroy(surface)
  popup.width = max(settings.menuWidthMin.int, 2 * border + markerW + maxText + textGap + arrowW)
  popup.height = y + padV + border
  if popup.selected >= popup.rows.len:
    popup.selected = -1
  inc popup.contentGen

proc rowAt(popup: MenuPopup, x, y: int): int =
  result = -1
  if x < border or x >= popup.width - border:
    return
  for i, row in popup.rows:
    if y >= row.y and y < row.y + row.h:
      return i

proc firstSelectable(popup: MenuPopup): int =
  result = -1
  for i, row in popup.rows:
    if row.entry.selectable:
      return i

proc place(popup: MenuPopup, parent: MenuPopup) =
  ## Root: below the clicked icon (above it when that does not fit). Submenus:
  ## to the right of the parent, aligned with the entry that opened them.
  let
    m = popup.mgr
    a = m.area
    left = a.x
    right = a.x + a.w
    top = a.y
    bottom = a.y + a.h
  var x, y: int
  if parent == nil:
    x = m.anchorX
    y = m.anchorBottom
    if y + popup.height > bottom:
      if m.anchorY - popup.height >= top:
        y = m.anchorY - popup.height
      else:
        y = bottom - popup.height
  else:
    x = parent.x + parent.width - border
    y = parent.y
    for row in parent.rows:
      if row.entry.id == popup.parentId:
        y = parent.y + row.y - padV - border
        break
    if x + popup.width > right:
      x = parent.x - popup.width + border
  x = max(left, min(x, right - popup.width))
  y = max(top, min(y, bottom - popup.height))
  popup.x = x
  popup.y = y

# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

proc iconFor(popup: MenuPopup, name: string): CairoSurface =
  ## The entry's icon rendered for this popup's scale (cached, nil: none).
  let
    px = max(1, (iconSize * popup.scale120 + 60) div 120)
    key = name & "|" & $px
  if key in popup.icons:
    return popup.icons[key]
  let file = findIconFile(name, "", px)
  if file.len > 0:
    result = renderFile(file, px)
  popup.icons[key] = result

proc drawRow(popup: MenuPopup, cr: Cairo, index: int) =
  let
    m = popup.mgr
    settings = m.bar.barSettings
    desc = m.bar.fontDescription
    row = popup.rows[index]
    entry = row.entry
    fg = toRgba(settings.fgColor)
    sel = toRgba(settings.selectionColor)
    left = border
    width = popup.width - 2 * border
  if entry.separator:
    cairo_set_source_rgba(cr, fg.r, fg.g, fg.b, 0.25)
    cairo_rectangle(cr, (left + 6).cdouble, (row.y + row.h div 2).cdouble,
      (width - 12).cdouble, 1)
    cairo_fill(cr)
    return
  let alpha = if entry.enabled: 1.0 else: 0.4
  if index == popup.selected and entry.enabled:
    cairo_set_source_rgba(cr, sel.r, sel.g, sel.b, 0.3)
    cairo_rectangle(cr, left.cdouble, row.y.cdouble, width.cdouble, row.h.cdouble)
    cairo_fill(cr)
  cairo_set_source_rgba(cr, fg.r, fg.g, fg.b, alpha)
  # Marker column: check mark, radio dot or the icon.
  let
    cx = left + markerW div 2
    cy = row.y + row.h div 2
  case entry.toggle
  of mtCheck:
    if entry.checked:
      cairo_set_line_width(cr, 1.6)
      cairo_new_path(cr)
      cairo_move_to(cr, (cx - 4).cdouble, (cy).cdouble)
      cairo_line_to(cr, (cx - 1).cdouble, (cy + 3).cdouble)
      cairo_line_to(cr, (cx + 4).cdouble, (cy - 3).cdouble)
      cairo_stroke(cr)
  of mtRadio:
    cairo_new_path(cr)
    cairo_arc(cr, cx.cdouble, cy.cdouble, 3.0, 0.0, 6.2831853)
    if entry.checked:
      cairo_fill(cr)
    else:
      cairo_set_line_width(cr, 1.0)
      cairo_stroke(cr)
  of mtNone:
    if entry.iconName.len > 0:
      let icon = popup.iconFor(entry.iconName)
      if icon != nil:
        let px = max(1, (iconSize * popup.scale120 + 60) div 120)
        cairo_save(cr)
        cairo_translate(cr, (cx - iconSize div 2).cdouble, (cy - iconSize div 2).cdouble)
        cairo_scale(cr, iconSize.float / px.float, iconSize.float / px.float)
        cairo_set_source_surface(cr, icon, 0, 0)
        cairo_paint(cr)
        cairo_restore(cr)
        cairo_set_source_rgba(cr, fg.r, fg.g, fg.b, alpha)
  # Label.
  let layout = newLayout(cr, oneLine(entry.label), desc)
  var w, h: cint
  pango_layout_get_pixel_size(layout, addr w, addr h)
  cairo_move_to(cr, (left + markerW).cdouble, (row.y + (row.h - h.int) div 2).cdouble)
  pango_cairo_show_layout(cr, layout)
  g_object_unref(layout)
  # Submenu arrow.
  if entry.submenu:
    let arrow = newLayout(cr, "\xE2\x80\xBA", desc)
    pango_layout_get_pixel_size(arrow, addr w, addr h)
    cairo_move_to(cr, (popup.width - border - arrowW + (arrowW - w.int) div 2 - 2).cdouble,
      (row.y + (row.h - h.int) div 2).cdouble)
    pango_cairo_show_layout(cr, arrow)
    g_object_unref(arrow)

proc draw(popup: MenuPopup, data: pointer) =
  let
    settings = popup.mgr.bar.barSettings
    surface = cairo_image_surface_create_for_data(
      data, CAIRO_FORMAT_ARGB32, popup.bufW.cint, popup.bufH.cint, (popup.bufW * 4).cint)
  cairo_surface_set_device_scale(surface,
    popup.bufW.float / popup.width.float, popup.bufH.float / popup.height.float)
  let
    cr = cairo_create(surface)
    bg = toRgba(settings.bgColor)
    bc = toRgba(settings.menuBorderColor)
  cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE)
  cairo_set_source_rgba(cr, bc.r, bc.g, bc.b, 1.0)
  cairo_rectangle(cr, 0, 0, popup.width.cdouble, popup.height.cdouble)
  cairo_fill(cr)
  cairo_set_source_rgba(cr, bg.r, bg.g, bg.b, 1.0)
  cairo_rectangle(cr, border.cdouble, border.cdouble, (popup.width - 2 * border).cdouble,
    (popup.height - 2 * border).cdouble)
  cairo_fill(cr)
  cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
  if popup.tip.len > 0:
    let
      fg = toRgba(settings.fgColor)
      desc = popup.mgr.bar.fontDescription
      lineH = (popup.height - 2 * (border + padV)) div popup.tip.len
    cairo_set_source_rgba(cr, fg.r, fg.g, fg.b, 1.0)
    for i, line in popup.tip:
      let layout = newLayout(cr, oneLine(line), desc)
      cairo_move_to(cr, (border + tipPadH).cdouble, (border + padV + i * lineH).cdouble)
      pango_cairo_show_layout(cr, layout)
      g_object_unref(layout)
  for i in 0 ..< popup.rows.len:
    popup.drawRow(cr, i)
  cairo_destroy(cr)
  cairo_surface_flush(surface)
  cairo_surface_destroy(surface)

# ---------------------------------------------------------------------------
# Shared memory buffers
# ---------------------------------------------------------------------------

proc bufferRelease(data: pointer, obj: WlBuffer) {.cdecl.} =
  let buf = cast[ShmBuf](data)
  buf.busy = false
  let m = buf.popup.mgr
  if m.pendingFlush:
    m.pendingFlush = false
    if m.ctx.requestManage != nil:
      m.ctx.requestManage()

var bufferListener = wl_buffer_noop_listener()
bufferListener.release = bufferRelease

proc freeBuffers(popup: MenuPopup) =
  for i in 0 .. popup.buffers.high:
    if popup.buffers[i] != nil:
      wl_buffer_destroy(popup.buffers[i].buffer)
      GC_unref popup.buffers[i]
      popup.buffers[i] = nil
  if popup.mem != nil:
    discard munmap(popup.mem, popup.memSize)
    popup.mem = nil
  popup.bufW = 0
  popup.bufH = 0

proc allocBuffers(popup: MenuPopup, width, height: int): bool =
  popup.freeBuffers()
  let
    stride = width * 4
    size = stride * height * 2
    fd = memfd_create("nimdow-menu", 1.cuint)
  if fd < 0:
    log "memfd_create failed", lvlError
    return false
  if ftruncate(fd, size.Off) != 0:
    discard close(fd)
    return false
  let mem = mmap(nil, size, PROT_READ or PROT_WRITE, MAP_SHARED, fd, 0)
  if mem == MAP_FAILED:
    discard close(fd)
    return false
  popup.mem = mem
  popup.memSize = size
  popup.bufW = width
  popup.bufH = height
  let pool = wl_shm_create_pool(popup.mgr.ctx.shm, fd, size.int32)
  for i in 0 .. popup.buffers.high:
    let buf = ShmBuf(popup: popup)
    GC_ref buf
    buf.buffer = wl_shm_pool_create_buffer(
      pool, (i * stride * height).int32, width.int32, height.int32, stride.int32,
      WL_SHM_FORMAT_ARGB8888)
    discard wl_buffer_add_listener(buf.buffer, addr bufferListener, cast[pointer](buf))
    popup.buffers[i] = buf
  wl_shm_pool_destroy(pool)
  discard close(fd)
  return true

# ---------------------------------------------------------------------------
# Popups
# ---------------------------------------------------------------------------

proc scaleChanged(popup: MenuPopup, scale120: int) =
  if scale120 > 0 and scale120 != popup.scale120:
    popup.scale120 = scale120
    popup.target.scale120 = scale120
    inc popup.contentGen
    if popup.mgr.ctx.requestManage != nil:
      popup.mgr.ctx.requestManage()

proc fractionalPreferredScale(data: pointer, obj: WpFractionalScaleV1,
    scale: uint32) {.cdecl.} =
  cast[MenuPopup](data).scaleChanged(scale.int)

var fractionalListener = wp_fractional_scale_v1_noop_listener()
fractionalListener.preferred_scale = fractionalPreferredScale

proc surfacePreferredBufferScale(data: pointer, obj: WlSurface, factor: int32) {.cdecl.} =
  let popup = cast[MenuPopup](data)
  if popup.fractional == nil:
    popup.scaleChanged(factor.int * 120)

var surfaceListener = wl_surface_noop_listener()
surfaceListener.preferred_buffer_scale = surfacePreferredBufferScale

proc requestManage(m: MenuManager) =
  if m.ctx.requestManage != nil:
    m.ctx.requestManage()

proc onMotion(popup: MenuPopup, x, y: int) =
  let
    m = popup.mgr
    row = popup.rowAt(x, y)
    newSel = if row >= 0 and popup.rows[row].entry.selectable: row else: -1
  if row >= 0 or popup.selected != -1:
    if newSel != popup.selected:
      popup.selected = newSel
    m.inputs.add MenuInput(kind: miHover, popup: popup, row: row)
    m.requestManage()

proc newPopup(m: MenuManager, level, parentId: int, entries: seq[MenuEntry],
    tip: seq[string] = @[]): MenuPopup =
  let ctx = m.ctx
  result = MenuPopup(
    mgr: m, level: level, parentId: parentId, entries: entries, selected: -1, tip: tip,
    scale120: max(120, m.bar.scale120), icons: initTable[string, CairoSurface]()
  )
  GC_ref result
  result.surface = wl_compositor_create_surface(ctx.compositor)
  discard wl_surface_add_listener(result.surface, addr surfaceListener, cast[pointer](result))
  if ctx.fractionalManager != nil:
    result.viewport = wp_viewporter_get_viewport(ctx.viewporter, result.surface)
    result.fractional = wp_fractional_scale_manager_v1_get_fractional_scale(
      ctx.fractionalManager, result.surface)
    discard wp_fractional_scale_v1_add_listener(
      result.fractional, addr fractionalListener, cast[pointer](result))
  result.shell = river_window_manager_v1_get_shell_surface(ctx.manager, result.surface)
  result.node = river_shell_surface_v1_get_node(result.shell)
  let popup = result
  if tip.len > 0:
    # A tooltip never takes the pointer: an empty input region.
    let region = wl_compositor_create_region(ctx.compositor)
    wl_surface_set_input_region(result.surface, region)
    wl_region_destroy(region)
    result.computeLayout()
    return
  result.target = InputTarget(
    surface: result.surface, scale120: result.scale120,
    enter: proc(x, y: int) = popup.onMotion(x, y),
    motion: proc(x, y: int) = popup.onMotion(x, y),
    button: proc(button, x, y: int) =
      if button in 1 .. 3:
        let row = popup.rowAt(x, y)
        if row >= 0:
          popup.mgr.inputs.add MenuInput(kind: miClick, popup: popup, row: row)
          popup.mgr.requestManage(),
    leave: proc() =
      # The highlight stays on the entry that has its submenu open.
      let m = popup.mgr
      m.inputs.add MenuInput(kind: miHover, popup: popup, row: -1)
      m.requestManage()
      let idx = m.popups.find(popup)
      if idx >= 0 and idx == m.popups.high:
        popup.selected = -1
        m.requestManage()
  )
  ctx.targets.add result.target
  result.computeLayout()

proc destroyPopup(m: MenuManager, popup: MenuPopup) =
  if popup.target != nil:
    m.ctx.removeTarget(popup.target)
  if m.pendPopup == popup:
    m.pendPopup = nil
  popup.freeBuffers()
  for surface in popup.icons.values:
    if surface != nil:
      cairo_surface_destroy(surface)
  popup.icons.clear()
  river_node_v1_destroy(popup.node)
  river_shell_surface_v1_destroy(popup.shell)
  if popup.fractional != nil:
    wp_fractional_scale_v1_destroy(popup.fractional)
    wp_viewport_destroy(popup.viewport)
  wl_surface_destroy(popup.surface)
  let index = m.popups.find(popup)
  if index >= 0:
    m.popups.delete index
  GC_unref popup

proc closeFrom(m: MenuManager, tray: Tray, first: int) =
  ## Destroys the popups from index `first` on (the deepest first), telling
  ## the tray about the closed submenus.
  while m.popups.len > first and m.popups.len > 0:
    let popup = m.popups[^1]
    if popup.level > 0 and tray != nil:
      tray.menuSubmenuClosed(popup.parentId)
    m.destroyPopup(popup)

proc openSubmenu(m: MenuManager, tray: Tray, popup: MenuPopup, row: int,
    selectFirst: bool) =
  let index = m.popups.find(popup)
  if index < 0 or row < 0 or row >= popup.rows.len:
    return
  let entry = popup.rows[row].entry
  if not entry.selectable or not entry.submenu:
    return
  if m.popups.len > index + 1:
    if m.popups[index + 1].parentId == entry.id:
      if selectFirst:
        m.popups[index + 1].selected = m.popups[index + 1].firstSelectable()
      return
    m.closeFrom(tray, index + 1)
  let kids = entry.visibleChildren()
  if kids.len == 0:
    return
  popup.selected = row
  let child = m.newPopup(popup.level + 1, entry.id, kids)
  if selectFirst:
    child.selected = child.firstSelectable()
  child.place(popup)
  m.popups.add child
  tray.menuSubmenuOpened(entry.id)

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

proc moveSelection(popup: MenuPopup, step: int) =
  ## Up/Down: the next enabled entry, skipping separators, wrapping around.
  let n = popup.rows.len
  if n == 0:
    return
  var i = popup.selected
  for _ in 0 ..< n:
    i = if i < 0: (if step > 0: 0 else: n - 1) else: (i + step + n) mod n
    if popup.rows[i].entry.selectable:
      popup.selected = i
      return

proc clearPending(m: MenuManager) =
  m.pendPopup = nil

proc schedule(m: MenuManager, popup: MenuPopup, entryId, delayMs: int) =
  if m.pendPopup == popup and m.pendEntry == entryId:
    return
  m.pendPopup = popup
  m.pendEntry = entryId
  m.pendDue = nowMs() + delayMs

proc runPending(m: MenuManager, tray: Tray) =
  ## Hover intent: the pointer stayed on the entry long enough.
  if m.pendPopup == nil or nowMs() < m.pendDue:
    return
  let
    popup = m.pendPopup
    id = m.pendEntry
    index = m.popups.find(popup)
  m.clearPending()
  if index < 0:
    return
  for r, row in popup.rows:
    if row.entry.id != id:
      continue
    if row.entry.selectable and row.entry.submenu:
      m.openSubmenu(tray, popup, r, false)
    elif m.popups.len > index + 1:
      m.closeFrom(tray, index + 1)
    return

proc repeatKeys(m: MenuManager) =
  ## Queues the key events the held Up/Down key repeats since the last call.
  if m.heldSym == 0 or m.nextRepeat <= 0:
    return
  let
    now = nowMs()
    interval = int64(max(1, 1000 div max(1, m.repeatRate)))
  var steps = 0
  while now >= m.nextRepeat and steps < 8:
    m.inputs.add MenuInput(kind: miKey, sym: m.heldSym)
    inc m.repeatCount
    inc steps
    m.nextRepeat += interval
  if now >= m.nextRepeat:
    m.nextRepeat = now + interval

proc stopRepeat(m: MenuManager) =
  m.heldSym = 0
  m.heldKey = 0
  m.nextRepeat = 0

proc handleInputs(m: MenuManager, tray: Tray) =
  let inputs = m.inputs
  m.inputs.setLen 0
  for input in inputs:
    if tray.menu == nil:
      break
    case input.kind
    of miHover:
      let popup = input.popup
      let index = m.popups.find(popup)
      if index < 0:
        continue
      if input.row < 0 or input.row >= popup.rows.len:
        # The pointer left the rows: a pending open of this popup is moot.
        if m.pendPopup == popup:
          m.clearPending()
        continue
      let entry = popup.rows[input.row].entry
      # The pointer reached another popup: a pending switch is moot.
      if m.pendPopup != nil and m.pendPopup != popup:
        m.clearPending()
      let childOpen = m.popups.len > index + 1
      if not entry.selectable:
        if not childOpen:
          m.clearPending()
      elif entry.submenu:
        if childOpen and m.popups[index + 1].parentId == entry.id:
          m.clearPending()
        else:
          m.schedule(popup, entry.id, if childOpen: hoverSwitchMs else: hoverOpenMs)
      elif childOpen:
        # Another entry of the parent: its submenu goes away, after a short
        # grace for a pointer moving diagonally toward it.
        m.schedule(popup, entry.id, hoverSwitchMs)
      else:
        m.clearPending()
    of miClick:
      m.clearPending()
      let popup = input.popup
      if m.popups.find(popup) < 0 or input.row >= popup.rows.len:
        continue
      let entry = popup.rows[input.row].entry
      if not entry.selectable:
        continue
      if entry.submenu:
        m.openSubmenu(tray, popup, input.row, false)
      else:
        tray.menuActivate(entry.id)
    of miKey:
      if m.popups.len == 0:
        continue
      let
        top = m.popups[^1]
        sym = input.sym
      if sym == keyEscape:
        tray.closeMenu()
      elif sym == keyDown:
        top.moveSelection(1)
      elif sym == keyUp:
        top.moveSelection(-1)
      elif sym == keyLeft:
        if m.popups.len > 1:
          m.closeFrom(tray, m.popups.len - 1)
      elif sym == keyRight or sym in [keyReturn, keyKpEnter, keySpace]:
        if top.selected >= 0 and top.selected < top.rows.len:
          let entry = top.rows[top.selected].entry
          if entry.submenu:
            m.openSubmenu(tray, top, top.selected, true)
          elif sym != keyRight and entry.selectable:
            tray.menuActivate(entry.id)

proc keyboardKeymap(data: pointer, obj: WlKeyboard, format: uint32, fd: cint,
    size: uint32) {.cdecl.} =
  let m = cast[MenuManager](data)
  if format == WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 and size > 0:
    let mem = mmap(nil, size.int, PROT_READ, MAP_PRIVATE, fd, 0)
    if mem != MAP_FAILED:
      if m.xkbContext == nil:
        m.xkbContext = xkb_context_new(0)
      let keymap = xkb_keymap_new_from_buffer(
        m.xkbContext, cast[cstring](mem), (size - 1).csize_t, 1, 0)
      discard munmap(mem, size.int)
      if keymap != nil:
        if m.xkbState != nil:
          xkb_state_unref(m.xkbState)
        if m.xkbKeymap != nil:
          xkb_keymap_unref(m.xkbKeymap)
        m.xkbKeymap = keymap
        m.xkbState = xkb_state_new(keymap)
  discard close(fd)

proc keyboardEnter(data: pointer, obj: WlKeyboard, serial: uint32, surface: WlSurface,
    keys: ptr WlArray) {.cdecl.} =
  let m = cast[MenuManager](data)
  for popup in m.popups:
    if popup.surface == surface:
      m.keyboardFocused = true
      m.keyboardSurface = surface

proc keyboardLeave(data: pointer, obj: WlKeyboard, serial: uint32,
    surface: WlSurface) {.cdecl.} =
  # A late leave of an already destroyed popup must not clear a newer focus.
  let m = cast[MenuManager](data)
  if surface.isNil or surface == m.keyboardSurface:
    m.keyboardFocused = false
    m.stopRepeat()

proc evdevSym(key: uint32): uint32 =
  ## Without a keymap: the navigation keys by their evdev codes.
  case key
  of 1: keyEscape
  of 28: keyReturn
  of 96: keyKpEnter
  of 57: keySpace
  of 103: keyUp
  of 108: keyDown
  of 105: keyLeft
  of 106: keyRight
  else: 0'u32

proc keyboardKey(data: pointer, obj: WlKeyboard, serial, time, key, state: uint32) {.cdecl.} =
  let m = cast[MenuManager](data)
  if state != WL_KEYBOARD_KEY_STATE_PRESSED:
    if key == m.heldKey:
      m.stopRepeat()
    return
  if not m.keyboardFocused:
    return
  let sym =
    if m.xkbState != nil: xkb_state_key_get_one_sym(m.xkbState, key + 8)
    else: evdevSym(key)
  m.inputs.add MenuInput(kind: miKey, sym: sym)
  if sym in [keyUp, keyDown] and m.repeatRate > 0:
    m.heldKey = key
    m.heldSym = sym
    m.nextRepeat = nowMs() + m.repeatDelay
  else:
    m.stopRepeat()
  m.requestManage()

proc keyboardRepeatInfo(data: pointer, obj: WlKeyboard, rate, delay: int32) {.cdecl.} =
  let m = cast[MenuManager](data)
  m.repeatRate = rate.int
  m.repeatDelay = max(0, delay.int)
  if rate <= 0:
    m.stopRepeat()

proc keyboardModifiers(data: pointer, obj: WlKeyboard, serial, depressed, latched, locked,
    group: uint32) {.cdecl.} =
  let m = cast[MenuManager](data)
  if m.xkbState != nil:
    discard xkb_state_update_mask(m.xkbState, depressed, latched, locked, 0, 0, group)

var keyboardListener = wl_keyboard_noop_listener()
keyboardListener.keymap = keyboardKeymap
keyboardListener.enter = keyboardEnter
keyboardListener.leave = keyboardLeave
keyboardListener.key = keyboardKey
keyboardListener.modifiers = keyboardModifiers
keyboardListener.repeat_info = keyboardRepeatInfo

proc newMenuManager*(ctx: BarContext): MenuManager =
  ## Hooks into the bar context's keyboards (set up before the seats' first
  ## capabilities event).
  result = MenuManager(ctx: ctx, version: -1, repeatRate: defaultRepeatRate,
    repeatDelay: defaultRepeatDelay, tipUid: -1, hoverUid: -1, suppressUid: -1)
  GC_ref result
  let m = result
  ctx.barHover = proc(bar: StatusBar, x, y: int) =
    let uid = bar.trayIconAt(x, y).uid
    if uid == m.hoverUid and bar == m.hoverBar:
      return
    m.hoverBar = bar
    m.hoverUid = uid
    if uid != m.suppressUid:
      m.suppressUid = -1
    m.hoverDue = if uid >= 0 and uid != m.suppressUid: nowMs() + tooltipMs else: 0
    if m.tip != nil:
      m.requestManage()
  ctx.barLeave = proc() =
    m.hoverUid = -1
    m.suppressUid = -1
    m.hoverDue = 0
    if m.tip != nil:
      m.requestManage()
  ctx.onKeyboard = proc(keyboard: WlKeyboard) =
    discard wl_keyboard_add_listener(keyboard, addr keyboardListener, cast[pointer](m))

# ---------------------------------------------------------------------------
# Manage / render sequences
# ---------------------------------------------------------------------------

proc isOpen*(m: MenuManager): bool = m != nil and m.popups.len > 0

proc keyboardShell*(m: MenuManager): RiverShellSurfaceV1 =
  ## The shell surface that should have the keyboard focus (nil: none, or not
  ## mapped yet).
  if m != nil and m.popups.len > 0 and m.popups[0].mapped:
    return m.popups[0].shell

proc refreshPopups(m: MenuManager, tray: Tray) =
  ## The session's tree changed: update the popups (closing those whose
  ## submenu is gone).
  var i = 0
  while i < m.popups.len:
    let
      popup = m.popups[i]
      node = tray.menu.root.find(popup.parentId)
      kids = node.visibleChildren()
    if node == nil or kids.len == 0 or (i > 0 and not node.submenu):
      if i == 0:
        tray.closeMenu()
      else:
        m.closeFrom(tray, i)
      return
    var selectedId = -1
    if popup.selected >= 0 and popup.selected < popup.rows.len:
      selectedId = popup.rows[popup.selected].entry.id
    popup.entries = kids
    popup.selected = -1
    popup.computeLayout()
    for r, row in popup.rows:
      if row.entry.id == selectedId and row.entry.selectable:
        popup.selected = r
    popup.place(if i == 0: nil else: m.popups[i - 1])
    inc i

proc beginManage*(m: MenuManager) =
  ## First call of a manage sequence: the due timers are being handled.
  m.timerNotified = false

proc hoverBar*(m: MenuManager): StatusBar = m.hoverBar

proc tooltipClicked*(m: MenuManager, uid: int) =
  ## The icon was clicked: no tooltip until the pointer leaves it.
  m.suppressUid = uid
  m.hoverDue = 0

proc hideTooltip(m: MenuManager) =
  if m.tip != nil:
    m.destroyPopup(m.tip)
    m.tip = nil
  m.tipUid = -1

proc manageTooltip*(m: MenuManager, tray: Tray, bar: StatusBar,
    area: tuple[x, y, w, h: int]) =
  ## Shows the tooltip of the hovered tray icon once its delay passed, hides
  ## it when the pointer left, the icon was clicked or a menu is open. `bar`
  ## is the bar under the pointer (nil: it is gone). Manage sequence only.
  var want = -1
  var item: TrayItem
  if tray != nil and bar != nil and bar == m.hoverBar and tray.menu == nil and
      m.hoverUid >= 0 and m.hoverUid != m.suppressUid:
    item = tray.findItem(m.hoverUid)
    if item != nil and item.loaded:
      want = m.hoverUid
  if tray != nil and tray.menu != nil:
    m.hoverDue = 0
  if m.tip != nil and want != m.tipUid:
    m.hideTooltip()
  if m.hoverDue <= 0 or nowMs() < m.hoverDue:
    return
  # Due: consumed whether or not a tooltip can be shown (no timer spinning).
  m.hoverDue = 0
  if want < 0 or m.tip != nil:
    return
  let lines = item.tooltipLines()
  if lines.len == 0:
    return
  var region: TrayRegion
  var found = false
  for r in bar.trayLayout():
    if r.uid == want:
      region = r
      found = true
  if not found:
    return
  m.bar = bar
  let tip = m.newPopup(0, 0, @[], lines)
  var
    x = region.x + region.width div 2 - tip.width div 2
    y = bar.origin.y + bar.height
  if area.w > 0 and area.h > 0:
    x = max(area.x, min(x, area.x + area.w - tip.width))
    y = max(area.y, min(y, area.y + area.h - tip.height))
  tip.x = x
  tip.y = y
  m.tip = tip
  m.tipUid = want

proc timeoutMs*(m: MenuManager): int =
  ## How long the event loop may sleep for the hover, tooltip and key repeat
  ## timers (-1: no timer pending, or the loop was told already).
  result = -1
  if m == nil or m.timerNotified:
    return
  let now = nowMs()
  template consider(due: int64) =
    let wait = int(max(0'i64, due - now))
    if result < 0 or wait < result:
      result = wait
  if m.pendPopup != nil:
    consider m.pendDue
  if m.hoverDue > 0:
    consider m.hoverDue
  if m.heldSym != 0 and m.nextRepeat > 0:
    consider m.nextRepeat

proc checkTimers*(m: MenuManager): bool =
  ## True once when a timer is due: the caller starts a manage sequence.
  if m == nil or m.timerNotified or m.timeoutMs() != 0:
    return false
  m.timerNotified = true
  return true

proc manage*(m: MenuManager, tray: Tray, bar: StatusBar,
    area: tuple[x, y, w, h: int]) =
  ## Handles the queued input and brings the popups in line with the tray's
  ## menu session. `bar` is the bar of the monitor the menu was opened on
  ## (nil: none, the menu is closed) and `area` the area its popups must stay
  ## in. Manage sequence only.
  if tray != nil and tray.menu != nil and bar == nil:
    tray.closeMenu()
  if tray == nil or tray.menu == nil:
    m.closeFrom(nil, 0)
    m.clearPending()
    m.stopRepeat()
    m.inputs.setLen 0
    m.gen = 0
    m.version = -1
    return
  let session = tray.menu
  if m.gen != session.gen:
    m.closeFrom(nil, 0)
    m.inputs.setLen 0
    m.gen = session.gen
    m.version = -1
  if not session.loaded:
    return
  m.bar = bar
  m.area = area
  m.anchorX = session.anchorX
  m.anchorY = session.anchorY
  m.anchorBottom = bar.origin.y + bar.height

  if m.popups.len > 0:
    m.repeatKeys()
    m.handleInputs(tray)
    m.runPending(tray)
    if tray.menu == nil:
      m.closeFrom(nil, 0)
      m.gen = 0
      m.version = -1
      return
  if m.popups.len == 0:
    let kids = session.root.visibleChildren()
    if kids.len == 0:
      tray.closeMenu()
      return
    let popup = m.newPopup(0, 0, kids)
    popup.place(nil)
    m.popups.add popup
    m.version = session.version
  elif m.version != session.version:
    m.version = session.version
    m.refreshPopups(tray)

proc flush*(m: MenuManager) =
  ## Positions the popups, puts them on top of everything and redraws the
  ## ones that changed. Render sequence only.
  if m == nil:
    return
  var all = m.popups
  if m.tip != nil:
    all.add m.tip
  for popup in all:
    river_node_v1_set_position(popup.node, popup.x.int32, popup.y.int32)
    river_node_v1_place_top(popup.node)
    let key = $popup.width & "x" & $popup.height & "@" & $popup.scale120 & "#" &
      $popup.contentGen & "/" & $popup.selected & "/" & $popup.x & "," & $popup.y
    if popup.drawnKey == key:
      continue
    let
      pixelWidth = (popup.width * popup.scale120 + 60) div 120
      pixelHeight = (popup.height * popup.scale120 + 60) div 120
    if popup.bufW != pixelWidth or popup.bufH != pixelHeight or popup.mem == nil:
      if not popup.allocBuffers(pixelWidth, pixelHeight):
        continue
    var index = -1
    for offset in 0 .. popup.buffers.high:
      let candidate = (popup.nextBuffer + offset) mod popup.buffers.len
      if not popup.buffers[candidate].busy:
        index = candidate
        break
    if index == -1:
      m.pendingFlush = true
      continue
    popup.nextBuffer = (index + 1) mod popup.buffers.len
    popup.draw(cast[pointer](cast[int](popup.mem) + index * pixelWidth * 4 * pixelHeight))
    if popup.viewport != nil:
      wl_surface_set_buffer_scale(popup.surface, 1)
      wp_viewport_set_destination(popup.viewport, popup.width.int32, popup.height.int32)
    else:
      wl_surface_set_buffer_scale(popup.surface, (popup.scale120 div 120).int32)
    river_shell_surface_v1_sync_next_commit(popup.shell)
    wl_surface_attach(popup.surface, popup.buffers[index].buffer, 0, 0)
    wl_surface_damage_buffer(popup.surface, 0, 0, pixelWidth.int32, pixelHeight.int32)
    wl_surface_commit(popup.surface)
    popup.buffers[index].busy = true
    popup.drawnKey = key
    if not popup.mapped:
      popup.mapped = true
      # The keyboard focus can go to it now.
      m.requestManage()

proc entryJson(entry: MenuEntry): JsonNode =
  %*{
    "id": entry.id, "label": entry.label, "enabled": entry.enabled,
    "type": (if entry.separator: "separator" else: "standard"),
    "toggle": (case entry.toggle
      of mtCheck: "checkmark"
      of mtRadio: "radio"
      of mtNone: ""),
    "checked": entry.checked, "submenu": entry.submenu
  }

proc dumpJson*(m: MenuManager, tray: Tray): JsonNode =
  ## The `menu` object of `--dumpState`.
  result = %*{
    "open": m != nil and m.popups.len > 0,
    "loading": tray != nil and tray.menu != nil and m.popups.len == 0,
    "itemUid": (if tray != nil and tray.menu != nil: tray.menu.uid else: -1),
    "keyboardFocus": m != nil and m.keyboardFocused,
    "submenuOpen": m != nil and m.popups.len > 1,
    "keyRepeats": (if m != nil: m.repeatCount else: 0),
    "tooltip": {"visible": false},
    "entries": newJArray(),
    "submenuEntries": newJArray(),
    "popups": newJArray()
  }
  if m == nil:
    return
  if m.tip != nil:
    result["tooltip"] = %*{
      "visible": m.tip.mapped, "text": m.tip.tip.join("\n"), "x": m.tip.x,
      "y": m.tip.y, "width": m.tip.width, "height": m.tip.height, "uid": m.tipUid
    }
  for popup in m.popups:
    var rows = newJArray()
    for row in popup.rows:
      rows.add %*{
        "id": row.entry.id, "y": popup.y + row.y, "height": row.h,
        "label": row.entry.label
      }
    result["popups"].add %*{
      "level": popup.level, "x": popup.x, "y": popup.y, "width": popup.width,
      "height": popup.height, "mapped": popup.mapped, "selected": popup.selected,
      "parentId": popup.parentId, "rows": rows
    }
    let key = if popup.level == 0: "entries" else: "submenuEntries"
    if popup.level <= 1:
      for entry in popup.entries:
        result[key].add entryJson(entry)
