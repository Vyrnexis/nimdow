## System tray: StatusNotifierItem (SNI) over D-Bus, using sd-bus.
##
## Roles:
##  * Watcher: we try to own `org.kde.StatusNotifierWatcher` (without replacing
##    anybody). If we get it, apps register their items with us.
##  * Host: we own `org.kde.StatusNotifierHost-<pid>` and register it with the
##    watcher. If somebody else owns the watcher (noctalia, waybar, ...) we only
##    act as a host: we read its RegisteredStatusNotifierItems and follow its
##    StatusNotifierItem(Un)Registered signals. When that watcher goes away we
##    try to take over the name.
##  * Items: the properties of each item are fetched with an asynchronous
##    Properties.GetAll; the item's New* signals schedule a (debounced) refetch.
##
## Nothing here blocks: every call is `sd_bus_call_method_async` and the
## callbacks only change the tray state and call `onChange`. The event loop
## (src/nimdow.nim) waits on `fd` with `events`/`timeoutMs` and calls `process`.
##
## Async call replies find their context through a request id passed as the
## userdata (so a reply for a removed item is simply ignored).
##
## Context menus (com.canonical.dbusmenu, see dbusmenu.nim): `openMenu` starts
## a `MenuSession` (AboutToShow(0), then GetLayout) whose tree the popup
## (menupopup.nim) draws. The session follows the menu's LayoutUpdated and
## ItemsPropertiesUpdated signals with debounced refetches until `closeMenu`.

import
  std/[posix, tables, strutils, os]

import
  ../dbus/sdbus,
  ../logger,
  ../wl/cairo,
  dbusmenu,
  icons

export icons.IconPixmap
export dbusmenu

const
  WatcherName = "org.kde.StatusNotifierWatcher"
  WatcherPath = "/StatusNotifierWatcher"
  ItemInterfaces = ["org.kde.StatusNotifierItem", "org.freedesktop.StatusNotifierItem"]
  DefaultItemPath = "/StatusNotifierItem"
  PropertiesInterface = "org.freedesktop.DBus.Properties"
  DebounceMs = 50

type
  ItemStatus* = enum
    isPassive, isActive, isNeedsAttention

  TrayItem* = ref object
    uid*: int
    ## As registered: a bus name and an object path.
    service*, path*: string
    ## Unique bus name of the item (signals come from it).
    owner: string
    ## The SNI ifaceName name that answered.
    iface*: string
    loaded*: bool
    id*, title*, tooltipTitle*, tooltipText*: string
    status*: ItemStatus
    iconName, attentionIconName, themePath: string
    pixmaps, attentionPixmaps: seq[IconPixmap]
    isMenu*: bool
    ## dbusmenu object path (for the menu popup).
    menu*: string
    refetchAt: int64
    # Rendered icon cache.
    cache: CairoSurface
    cacheKey: string
    cacheReal: bool
    cacheDesc: string

  RequestKind = enum
    rkItemProps, rkWatcherItems, rkHostName, rkWatcherName, rkRegisterHost, rkAction,
    rkMenuAbout, rkMenuLayout

  Request = object
    kind: RequestKind
    uid: int
    ifaceIndex: int
    what: string
    ## Menu session the request belongs to, and the menu entry it is about.
    gen: int
    menuId: int

  ## An open (or loading) context menu of an item.
  MenuSession* = ref object
    gen*: int
    uid*: int
    ## The clicked icon's position on the screen.
    anchorX*, anchorY*: int
    ## `root` is valid.
    loaded*: bool
    root*: MenuEntry
    ## Incremented whenever `root` is replaced.
    version*: int
    ## Where the menu lives.
    service, owner, path: string
    slots: seq[SdBusSlot]
    refetchAt: int64
    ## Submenus an "opened" event was sent for.
    openIds: seq[int]

  Tray* = ref object
    bus: SdBus
    items*: seq[TrayItem]
    ## Incremented whenever something visible changed.
    version*: int
    onChange*: proc() {.closure.}
    uniqueName: string
    hostName: string
    nextUid, nextRequest, nextMenuGen: int
    requests: Table[int, Request]
    ## The open context menu (nil: none).
    menu*: MenuSession
    ownsWatcher*: bool
    hostNameDone, watcherDone, hostNameOwned: bool
    ## Hosts registered with our own watcher.
    hosts: seq[string]

var gTray: Tray

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc nowMs*(): int64 =
  var ts: Timespec
  discard clock_gettime(CLOCK_MONOTONIC, ts)
  ts.tv_sec.int64 * 1000 + ts.tv_nsec.int64 div 1_000_000

proc plainText*(markup: string): string =
  ## Simple markup (tags, a few entities) removed; `<br>` and `</p>` become
  ## line breaks.
  var
    inTag = false
    tag = ""
    text = ""
  for c in markup:
    if inTag:
      if c == '>':
        inTag = false
        let name = tag.toLowerAscii().strip(chars = {'/', ' '})
        if name.startsWith("br") or name == "p":
          text.add '\n'
      else:
        tag.add c
    elif c == '<':
      inTag = true
      tag = ""
    else:
      text.add c
  result = text.multiReplace(("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"),
    ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&"))

proc tooltipLines*(item: TrayItem): seq[string] =
  ## What the tooltip shows: the ToolTip title (and the first line of its
  ## description), else the Title, else the Id.
  proc firstLine(s: string): string =
    for line in plainText(s).splitLines():
      if line.strip().len > 0:
        return line.strip()
  let title = firstLine(item.tooltipTitle)
  if title.len > 0:
    result.add title
    let desc = firstLine(item.tooltipText)
    if desc.len > 0:
      result.add desc
    return
  for candidate in [item.title, item.id]:
    let line = firstLine(candidate)
    if line.len > 0:
      return @[line]

proc toStr(s: cstring): string =
  if s == nil: "" else: $s

proc changed(t: Tray) =
  inc t.version
  if t.onChange != nil:
    t.onChange()

proc alive*(t: Tray): bool = t.bus != nil

proc fd*(t: Tray): int =
  if t.bus == nil: -1 else: sd_bus_get_fd(t.bus).int

proc events*(t: Tray): int =
  ## poll(2) event bits sd-bus wants to wait for.
  if t.bus == nil: 0 else: max(0, sd_bus_get_events(t.bus).int)

proc timeoutMs*(t: Tray): int =
  ## How long the event loop may sleep (-1: forever).
  if t.bus == nil:
    return -1
  var usec: uint64
  result = -1
  if sd_bus_get_timeout(t.bus, addr usec) >= 0 and usec != high(uint64):
    var ts: Timespec
    discard clock_gettime(CLOCK_MONOTONIC, ts)
    let now = ts.tv_sec.uint64 * 1_000_000'u64 + ts.tv_nsec.uint64 div 1000
    result = if usec <= now: 0 else: ((usec - now) div 1000 + 1).int
  for item in t.items:
    if item.refetchAt > 0:
      let wait = max(0'i64, item.refetchAt - nowMs()).int
      if result < 0 or wait < result:
        result = wait
  if t.menu != nil and t.menu.refetchAt > 0:
    let wait = max(0'i64, t.menu.refetchAt - nowMs()).int
    if result < 0 or wait < result:
      result = wait

proc newRequest(t: Tray, req: Request): pointer =
  inc t.nextRequest
  t.requests[t.nextRequest] = req
  cast[pointer](t.nextRequest)

proc findItem*(t: Tray, uid: int): TrayItem =
  for item in t.items:
    if item.uid == uid:
      return item

proc itemSpec(item: TrayItem): string = item.service & item.path

proc findBySpec(t: Tray, service, path: string): TrayItem =
  for item in t.items:
    if item.path == path and (item.service == service or item.owner == service or
        (item.owner.len > 0 and item.owner == service)):
      return item

proc freeCache(item: TrayItem) =
  if item.cache != nil:
    cairo_surface_destroy(item.cache)
    item.cache = nil
  item.cacheKey = ""

# ---------------------------------------------------------------------------
# Own watcher: signals and properties
# ---------------------------------------------------------------------------

proc emitWatcher(t: Tray, member: string, arg = "") =
  if not t.ownsWatcher or t.bus == nil:
    return
  if arg.len > 0:
    discard sd_bus_emit_signal(t.bus, WatcherPath, WatcherName, member.cstring, "s", arg.cstring)
  else:
    discard sd_bus_emit_signal(t.bus, WatcherPath, WatcherName, member.cstring, "")

proc emitProperty(t: Tray, name: string) =
  if t.ownsWatcher and t.bus != nil:
    discard sd_bus_emit_properties_changed(t.bus, WatcherPath, WatcherName, name.cstring, nil)

proc closeMenu*(t: Tray)

proc removeItem(t: Tray, item: TrayItem) =
  let index = t.items.find(item)
  if index < 0:
    return
  if t.menu != nil and t.menu.uid == item.uid:
    t.closeMenu()
  t.items.delete index
  item.freeCache()
  t.emitWatcher("StatusNotifierItemUnregistered", item.itemSpec)
  t.emitProperty("RegisteredStatusNotifierItems")
  t.changed()

# ---------------------------------------------------------------------------
# Async calls
# ---------------------------------------------------------------------------

proc onReply(m: SdBusMessage, userdata: pointer, err: ptr SdBusError): cint {.cdecl.}

proc fetchMenuLayout(t: Tray) =
  let menu = t.menu
  if menu == nil or t.bus == nil:
    return
  let req = t.newRequest(Request(kind: rkMenuLayout, gen: menu.gen))
  if not callGetLayout(t.bus, menu.service, menu.path, onReply, req):
    t.requests.del cast[int](req)

proc fetchItem(t: Tray, item: TrayItem, ifaceIndex: int) =
  let iface =
    if ifaceIndex == 0 and item.iface.len > 0: item.iface
    else: ItemInterfaces[ifaceIndex]
  let req = t.newRequest(Request(kind: rkItemProps, uid: item.uid, ifaceIndex: ifaceIndex))
  if sd_bus_call_method_async(
      t.bus, nil, item.service.cstring, item.path.cstring, PropertiesInterface,
      "GetAll", onReply, req, "s", iface.cstring) < 0:
    t.requests.del cast[int](req)

proc addItem(t: Tray, service, path, sender: string) =
  if service.len == 0 or t.bus == nil:
    return
  if t.findBySpec(service, path) != nil:
    return
  inc t.nextUid
  let item = TrayItem(
    uid: t.nextUid, service: service, path: path,
    owner: if service[0] == ':': service else: "",
    status: isActive
  )
  t.items.add item
  t.emitWatcher("StatusNotifierItemRegistered", item.itemSpec)
  t.emitProperty("RegisteredStatusNotifierItems")
  t.fetchItem(item, 0)

proc addSpec(t: Tray, spec, sender: string) =
  ## A registered item: "service/path", a bare service, or a path (the
  ## sender is then the service).
  if spec.startsWith("/"):
    t.addItem(sender, spec, sender)
  else:
    let slash = spec.find('/')
    if slash > 0:
      t.addItem(spec[0 ..< slash], spec[slash .. ^1], sender)
    else:
      t.addItem(spec, DefaultItemPath, sender)

proc registerHost(t: Tray) =
  ## Makes the watcher (ours or somebody else's) know about our host.
  if not (t.hostNameDone and t.watcherDone and t.hostNameOwned):
    return
  if t.ownsWatcher:
    if t.hostName notin t.hosts:
      t.hosts.add t.hostName
      t.emitProperty("IsStatusNotifierHostRegistered")
      t.emitWatcher("StatusNotifierHostRegistered")
  else:
    let req = t.newRequest(Request(kind: rkRegisterHost))
    if sd_bus_call_method_async(
        t.bus, nil, WatcherName, WatcherPath, WatcherName, "RegisterStatusNotifierHost",
        onReply, req, "s", t.hostName.cstring) < 0:
      t.requests.del cast[int](req)

proc fetchWatcherItems(t: Tray) =
  let req = t.newRequest(Request(kind: rkWatcherItems))
  if sd_bus_call_method_async(
      t.bus, nil, WatcherName, WatcherPath, PropertiesInterface, "GetAll", onReply, req,
      "s", WatcherName) < 0:
    t.requests.del cast[int](req)

proc requestName(t: Tray, name: string, flags: uint32, kind: RequestKind) =
  let req = t.newRequest(Request(kind: kind))
  if sd_bus_call_method_async(
      t.bus, nil, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
      "RequestName", onReply, req, "su", name.cstring, flags) < 0:
    t.requests.del cast[int](req)

proc watcherStatusKnown(t: Tray) =
  ## We know whether we own the watcher: host registration, or follow the
  ## other watcher.
  t.watcherDone = true
  if t.ownsWatcher:
    log "tray: acting as StatusNotifierWatcher", lvlDebug
  else:
    log "tray: another StatusNotifierWatcher exists, acting as a host only", lvlDebug
    t.fetchWatcherItems()
  t.registerHost()

# ---------------------------------------------------------------------------
# Reply parsing
# ---------------------------------------------------------------------------

proc readString(m: SdBusMessage, kind: char): string =
  ## Reads a string-like basic value.
  var s: cstring
  let sig = [kind, '\0']
  if sd_bus_message_read(m, cast[cstring](unsafeAddr sig[0]), addr s) >= 0:
    result = toStr(s)

proc readPixmaps(m: SdBusMessage): seq[IconPixmap] =
  if sd_bus_message_enter_container(m, 'a', "(iiay)") <= 0:
    return
  while sd_bus_message_enter_container(m, 'r', "iiay") > 0:
    var w, h: cint
    var p: pointer
    var size: csize_t
    if sd_bus_message_read(m, "ii", addr w, addr h) < 0 or
        sd_bus_message_read_array(m, 'y', addr p, addr size) < 0:
      discard sd_bus_message_exit_container(m)
      break
    var pixmap = IconPixmap(width: w, height: h)
    if p != nil and size > 0 and size < 64'u * 1024 * 1024:
      pixmap.data = newString(size.int)
      copyMem(addr pixmap.data[0], p, size.int)
    result.add pixmap
    discard sd_bus_message_exit_container(m)
  discard sd_bus_message_exit_container(m)

proc parseItemProps(m: SdBusMessage, item: TrayItem): bool =
  ## Applies a Properties.GetAll reply (a{sv}) to the item.
  if sd_bus_message_enter_container(m, 'a', "{sv}") <= 0:
    return false
  # Properties not in the reply are back to their defaults.
  item.id = ""
  item.title = ""
  item.tooltipTitle = ""
  item.tooltipText = ""
  item.status = isActive
  item.iconName = ""
  item.attentionIconName = ""
  item.themePath = ""
  item.pixmaps = @[]
  item.attentionPixmaps = @[]
  item.isMenu = false
  item.menu = ""
  var count = 0
  while sd_bus_message_enter_container(m, 'e', "sv") > 0:
    inc count
    var key: cstring
    var kind: char
    var contents: cstring
    if sd_bus_message_read(m, "s", addr key) < 0 or
        sd_bus_message_peek_type(m, addr kind, addr contents) < 0 or
        sd_bus_message_enter_container(m, 'v', contents) < 0:
      return false
    let
      name = $key
      sig = $contents
    var handled = true
    case name
    of "Id": (if sig == "s": item.id = readString(m, 's') else: handled = false)
    of "Title": (if sig == "s": item.title = readString(m, 's') else: handled = false)
    of "IconName": (if sig == "s": item.iconName = readString(m, 's') else: handled = false)
    of "AttentionIconName":
      if sig == "s": item.attentionIconName = readString(m, 's') else: handled = false
    of "IconThemePath":
      if sig == "s": item.themePath = readString(m, 's') else: handled = false
    of "Menu":
      if sig == "o":
        item.menu = readString(m, 'o')
        if item.menu == "/":
          # "No menu".
          item.menu = ""
      else: handled = false
    of "Status":
      if sig == "s":
        case readString(m, 's')
        of "Passive": item.status = isPassive
        of "NeedsAttention": item.status = isNeedsAttention
        else: item.status = isActive
      else: handled = false
    of "ItemIsMenu":
      if sig == "b":
        var b: cint
        if sd_bus_message_read(m, "b", addr b) >= 0:
          item.isMenu = b != 0
      else: handled = false
    of "IconPixmap": (if sig == "a(iiay)": item.pixmaps = readPixmaps(m) else: handled = false)
    of "AttentionIconPixmap":
      if sig == "a(iiay)": item.attentionPixmaps = readPixmaps(m) else: handled = false
    of "ToolTip":
      if sig == "(sa(iiay)ss)" and sd_bus_message_enter_container(m, 'r', "sa(iiay)ss") > 0:
        discard readString(m, 's')
        discard sd_bus_message_skip(m, "a(iiay)")
        item.tooltipTitle = readString(m, 's')
        item.tooltipText = readString(m, 's')
        discard sd_bus_message_exit_container(m)
      else: handled = false
    else: handled = false
    if not handled:
      discard sd_bus_message_skip(m, contents)
    discard sd_bus_message_exit_container(m)  # variant
    discard sd_bus_message_exit_container(m)  # dict entry
  discard sd_bus_message_exit_container(m)
  return count > 0

proc parseWatcherItems(t: Tray, m: SdBusMessage) =
  if sd_bus_message_enter_container(m, 'a', "{sv}") <= 0:
    return
  while sd_bus_message_enter_container(m, 'e', "sv") > 0:
    var key: cstring
    var kind: char
    var contents: cstring
    if sd_bus_message_read(m, "s", addr key) < 0 or
        sd_bus_message_peek_type(m, addr kind, addr contents) < 0 or
        sd_bus_message_enter_container(m, 'v', contents) < 0:
      return
    if $key == "RegisteredStatusNotifierItems" and $contents == "as":
      if sd_bus_message_enter_container(m, 'a', "s") > 0:
        var spec: cstring
        while sd_bus_message_read(m, "s", addr spec) > 0:
          t.addSpec($spec, "")
        discard sd_bus_message_exit_container(m)
    else:
      discard sd_bus_message_skip(m, contents)
    discard sd_bus_message_exit_container(m)
    discard sd_bus_message_exit_container(m)
  discard sd_bus_message_exit_container(m)

proc onReply(m: SdBusMessage, userdata: pointer, err: ptr SdBusError): cint {.cdecl.} =
  let t = gTray
  if t == nil:
    return 0
  let id = cast[int](userdata)
  if id notin t.requests:
    return 0
  let req = t.requests[id]
  t.requests.del id
  let failed = sd_bus_message_is_method_error(m, nil) != 0
  try:
    case req.kind
    of rkItemProps:
      let item = t.findItem(req.uid)
      if item == nil:
        return 0
      if not failed and parseItemProps(m, item):
        item.iface = ItemInterfaces[req.ifaceIndex]
        item.loaded = true
        let sender = toStr(sd_bus_message_get_sender(m))
        if sender.len > 0:
          item.owner = sender
        item.freeCache()
        t.changed()
      elif req.ifaceIndex + 1 < ItemInterfaces.len and item.iface.len == 0:
        # Some items only implement the org.freedesktop name.
        t.fetchItem(item, req.ifaceIndex + 1)
      elif not item.loaded:
        log "tray: dropping item " & item.itemSpec & " (properties unavailable)", lvlDebug
        t.removeItem(item)
    of rkWatcherItems:
      if not failed:
        t.parseWatcherItems(m)
    of rkHostName:
      var code: uint32
      t.hostNameOwned = not failed and sd_bus_message_read(m, "u", addr code) >= 0 and
        (code == 1 or code == 4)
      t.hostNameDone = true
      t.registerHost()
    of rkWatcherName:
      var code: uint32
      t.ownsWatcher = not failed and sd_bus_message_read(m, "u", addr code) >= 0 and
        (code == 1 or code == 4)
      t.watcherStatusKnown()
    of rkRegisterHost:
      if failed:
        log "tray: RegisterStatusNotifierHost failed", lvlDebug
    of rkAction:
      if failed:
        log "tray: " & req.what & " failed", lvlDebug
    of rkMenuAbout:
      let menu = t.menu
      if menu == nil or menu.gen != req.gen:
        return 0
      var needsUpdate: cint
      if req.menuId == 0:
        # The result of AboutToShow(0) and its errors do not matter.
        t.fetchMenuLayout()
      elif not failed and sd_bus_message_read(m, "b", addr needsUpdate) >= 0 and
          needsUpdate != 0:
        t.fetchMenuLayout()
    of rkMenuLayout:
      let menu = t.menu
      if menu == nil or menu.gen != req.gen:
        return 0
      var layout: tuple[ok: bool, revision: uint32, root: MenuEntry]
      if not failed:
        layout = readLayout(m)
      if not layout.ok:
        log "tray: GetLayout failed", lvlDebug
        if not menu.loaded:
          t.closeMenu()
      else:
        log "tray: menu layout loaded: " & $layout.root.children.len & " entries", lvlDebug
        menu.root = layout.root
        menu.loaded = true
        inc menu.version
        t.changed()
  except CatchableError:
    log "tray: " & getCurrentExceptionMsg(), lvlError
  return 0

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

proc onItemSignal(m: SdBusMessage, userdata: pointer, err: ptr SdBusError): cint {.cdecl.} =
  let t = gTray
  if t == nil:
    return 0
  let
    sender = toStr(sd_bus_message_get_sender(m))
    path = toStr(sd_bus_message_get_path(m))
    member = toStr(sd_bus_message_get_member(m))
  if member notin ["NewIcon", "NewAttentionIcon", "NewStatus", "NewTitle", "NewToolTip",
      "NewIconThemePath"]:
    return 0
  for item in t.items:
    if item.loaded and item.owner == sender and item.path == path:
      if item.refetchAt == 0:
        item.refetchAt = nowMs() + DebounceMs
  return 0

proc onWatcherSignal(m: SdBusMessage, userdata: pointer, err: ptr SdBusError): cint {.cdecl.} =
  ## Signals of another watcher (ours are ignored).
  let t = gTray
  if t == nil or t.ownsWatcher or toStr(sd_bus_message_get_sender(m)) == t.uniqueName:
    return 0
  let member = toStr(sd_bus_message_get_member(m))
  var spec: cstring
  case member
  of "StatusNotifierItemRegistered":
    if sd_bus_message_read(m, "s", addr spec) >= 0:
      t.addSpec($spec, toStr(sd_bus_message_get_sender(m)))
  of "StatusNotifierItemUnregistered":
    if sd_bus_message_read(m, "s", addr spec) >= 0:
      let s = $spec
      let slash = s.find('/')
      let (service, path) =
        if slash > 0: (s[0 ..< slash], s[slash .. ^1]) else: (s, DefaultItemPath)
      let item = t.findBySpec(service, path)
      if item != nil:
        t.removeItem(item)
  else: discard
  return 0

proc onNameOwnerChanged(m: SdBusMessage, userdata: pointer,
    err: ptr SdBusError): cint {.cdecl.} =
  let t = gTray
  if t == nil:
    return 0
  var name, oldOwner, newOwner: cstring
  if sd_bus_message_read(m, "sss", addr name, addr oldOwner, addr newOwner) < 0:
    return 0
  let (n, o, w) = ($name, $oldOwner, $newOwner)
  if w.len == 0:
    var gone: seq[TrayItem]
    for item in t.items:
      if item.service == n or (item.owner.len > 0 and (item.owner == n or item.owner == o)):
        gone.add item
    for item in gone:
      t.removeItem(item)
    let hostIndex = t.hosts.find(n)
    if hostIndex >= 0:
      t.hosts.delete hostIndex
      t.emitProperty("IsStatusNotifierHostRegistered")
    if n == WatcherName and not t.ownsWatcher:
      # The other watcher is gone: take over.
      t.watcherDone = false
      t.requestName(WatcherName, DBUS_NAME_FLAG_DO_NOT_QUEUE, rkWatcherName)
  elif n == WatcherName and not t.ownsWatcher and w != t.uniqueName:
    # A (new) other watcher: register with it and read its items.
    t.watcherStatusKnown()
  return 0

# ---------------------------------------------------------------------------
# Our watcher's methods and properties (called from watcher_vtable.c)
# ---------------------------------------------------------------------------

proc watcherRegisterItem(m: SdBusMessage, userdata: pointer,
    err: ptr SdBusError): cint {.exportc: "nimdow_watcher_register_item", cdecl.} =
  var spec: cstring
  if sd_bus_message_read(m, "s", addr spec) < 0:
    return -22
  discard sd_bus_reply_method_return(m, nil)
  try:
    if gTray != nil:
      gTray.addSpec($spec, toStr(sd_bus_message_get_sender(m)))
  except CatchableError:
    discard
  return 1

proc watcherRegisterHost(m: SdBusMessage, userdata: pointer,
    err: ptr SdBusError): cint {.exportc: "nimdow_watcher_register_host", cdecl.} =
  var name: cstring
  if sd_bus_message_read(m, "s", addr name) < 0:
    return -22
  discard sd_bus_reply_method_return(m, nil)
  let t = gTray
  if t != nil and $name notin t.hosts:
    t.hosts.add $name
    t.emitProperty("IsStatusNotifierHostRegistered")
    t.emitWatcher("StatusNotifierHostRegistered")
  return 1

proc watcherPropItems(bus: SdBus, path, ifaceName, property: cstring, reply: SdBusMessage,
    userdata: pointer, err: ptr SdBusError): cint
    {.exportc: "nimdow_watcher_prop_items", cdecl.} =
  var specs: seq[string]
  if gTray != nil:
    for item in gTray.items:
      specs.add item.itemSpec
  let arr = allocCStringArray(specs)
  result = sd_bus_message_append_strv(reply, arr)
  deallocCStringArray(arr)

proc watcherPropHost(bus: SdBus, path, ifaceName, property: cstring, reply: SdBusMessage,
    userdata: pointer, err: ptr SdBusError): cint
    {.exportc: "nimdow_watcher_prop_host", cdecl.} =
  let registered: cint = if gTray != nil and gTray.hosts.len > 0: 1 else: 0
  sd_bus_message_append(reply, "b", registered)

proc watcherPropVersion(bus: SdBus, path, ifaceName, property: cstring, reply: SdBusMessage,
    userdata: pointer, err: ptr SdBusError): cint
    {.exportc: "nimdow_watcher_prop_version", cdecl.} =
  sd_bus_message_append(reply, "i", 0.cint)

# ---------------------------------------------------------------------------
# Public ifaceName
# ---------------------------------------------------------------------------

proc shutdown(t: Tray) =
  if t.menu != nil:
    for slot in t.menu.slots:
      discard sd_bus_slot_unref(slot)
    t.menu = nil
  if t.bus != nil:
    sd_bus_close(t.bus)
    sd_bus_unref(t.bus)
    t.bus = nil
  for item in t.items:
    item.freeCache()
  t.items.setLen 0
  t.changed()

proc stop*(t: Tray) =
  ## Closes the bus connection (the tray names go away with it).
  t.shutdown()

proc process*(t: Tray) =
  ## Runs due refetches and processes everything sd-bus has pending. Never
  ## blocks: the caller waits on `fd`.
  if t.bus == nil:
    return
  let now = nowMs()
  for item in t.items:
    if item.refetchAt > 0 and item.refetchAt <= now:
      item.refetchAt = 0
      t.fetchItem(item, 0)
  if t.menu != nil and t.menu.refetchAt > 0 and t.menu.refetchAt <= now:
    t.menu.refetchAt = 0
    t.fetchMenuLayout()
  while t.bus != nil:
    let r = sd_bus_process(t.bus, nil)
    if r < 0:
      log "tray: lost the D-Bus connection (" & $r & ")", lvlWarn
      t.shutdown()
      break
    if r == 0:
      break

proc newTray*(iconTheme: string, onChange: proc() {.closure.}): Tray =
  ## Connects to the session bus and starts the watcher/host roles. Returns nil
  ## when there is no session bus. (sd_bus_open_user connects synchronously; it
  ## runs once at startup.)
  var bus: SdBus
  if sd_bus_open_user(addr bus) < 0 or bus == nil:
    log "tray: cannot connect to the D-Bus session bus, the tray is disabled", lvlWarn
    return nil
  result = Tray(bus: bus, onChange: onChange, requests: initTable[int, Request]())
  gTray = result
  setIconTheme(iconTheme)
  var unique: cstring
  discard sd_bus_get_unique_name(bus, addr unique)
  result.uniqueName = toStr(unique)
  result.hostName = "org.kde.StatusNotifierHost-" & $getpid()
  if nimdow_watcher_install(bus, nil, nil) < 0:
    log "tray: cannot export the watcher object", lvlWarn
  discard sd_bus_match_signal(bus, nil, "org.freedesktop.DBus", "/org/freedesktop/DBus",
    "org.freedesktop.DBus", "NameOwnerChanged", onNameOwnerChanged, nil)
  for iface in ItemInterfaces:
    discard sd_bus_match_signal(bus, nil, nil, nil, iface.cstring, nil, onItemSignal, nil)
  discard sd_bus_match_signal(bus, nil, nil, WatcherPath, WatcherName, nil,
    onWatcherSignal, nil)
  result.requestName(result.hostName, DBUS_NAME_FLAG_DO_NOT_QUEUE, rkHostName)
  result.requestName(WatcherName, DBUS_NAME_FLAG_DO_NOT_QUEUE, rkWatcherName)
  result.process()

proc visibleItems*(t: Tray): seq[TrayItem] =
  if t == nil:
    return
  for item in t.items:
    if item.loaded and item.status != isPassive:
      result.add item

proc iconSurface*(item: TrayItem, px: int): tuple[surface: CairoSurface, real: bool, desc: string] =
  ## The item's icon as a px*px surface (owned by the item; nil, real=false
  ## when there is none: the caller draws a placeholder).
  let key = $px & "|" & $item.status
  if item.cacheKey == key:
    return (item.cache, item.cacheReal, item.cacheDesc)
  item.freeCache()
  let attention = item.status == isNeedsAttention and
    (item.attentionIconName.len > 0 or item.attentionPixmaps.len > 0)
  let
    name = if attention: item.attentionIconName else: item.iconName
    pixmaps = if attention: item.attentionPixmaps else: item.pixmaps
  var
    surface: CairoSurface
    desc = "none"
  if name.len > 0:
    let file = findIconFile(name, item.themePath, px)
    if file.len > 0:
      surface = renderFile(file, px)
      if surface != nil:
        desc = "file:" & file
  if surface == nil:
    let index = choosePixmap(pixmaps, px)
    if index >= 0:
      surface = renderPixmap(pixmaps[index], px)
      if surface != nil:
        let p = pixmaps[index]
        desc = "pixmap:" & $p.width & "x" & $p.height & ":" &
          toHex(p.data[1 .. 3]) & "-" & toHex(p.data[p.data.len - 3 .. ^1])
  item.cache = surface
  item.cacheKey = key
  item.cacheReal = surface != nil
  item.cacheDesc = desc
  return (item.cache, item.cacheReal, item.cacheDesc)

proc call(t: Tray, item: TrayItem, member, what: string, types: cstring, a: int = 0, b: int = 0,
    s: cstring = nil) =
  if t.bus == nil:
    return
  let
    iface = if item.iface.len > 0: item.iface else: ItemInterfaces[0]
    req = t.newRequest(Request(kind: rkAction, what: what))
  var r: cint
  if types == "ii":
    r = sd_bus_call_method_async(t.bus, nil, item.service.cstring, item.path.cstring,
      iface.cstring, member.cstring, onReply, req, "ii", a.cint, b.cint)
  else:
    r = sd_bus_call_method_async(t.bus, nil, item.service.cstring, item.path.cstring,
      iface.cstring, member.cstring, onReply, req, "is", a.cint, s)
  if r < 0:
    t.requests.del cast[int](req)

# ---------------------------------------------------------------------------
# Context menus
# ---------------------------------------------------------------------------

proc onMenuSignal(m: SdBusMessage, userdata: pointer, err: ptr SdBusError): cint {.cdecl.} =
  ## LayoutUpdated / ItemsPropertiesUpdated of the open menu: refetch.
  let t = gTray
  if t == nil or t.menu == nil or t.menu.gen != cast[int](userdata):
    return 0
  if t.menu.refetchAt == 0:
    t.menu.refetchAt = nowMs() + DebounceMs
  return 0

proc menuCall(t: Tray, session: MenuSession, id: int, event: string) =
  ## Event(id, event) of the session's menu (best effort).
  if t.bus == nil:
    return
  let req = t.newRequest(Request(kind: rkAction, what: "menu event " & event))
  if not callEvent(t.bus, session.service, session.path, id, event,
      (nowMs() and 0xffffffff).uint32, onReply, req):
    t.requests.del cast[int](req)

proc closeMenu*(t: Tray) =
  ## Closes the open context menu: "closed" for its open submenus, signals
  ## unsubscribed.
  let menu = t.menu
  if menu == nil:
    return
  t.menu = nil
  log "tray: menu closed (" & menu.path & ")", lvlDebug
  for id in menu.openIds:
    t.menuCall(menu, id, "closed")
  for slot in menu.slots:
    discard sd_bus_slot_unref(slot)
  t.changed()

proc openMenu*(t: Tray, item: TrayItem, x, y: int) =
  ## Starts the context menu of the item (closing the open one): AboutToShow(0),
  ## then GetLayout; `t.menu.loaded` tells when the tree can be drawn.
  t.closeMenu()
  if t.bus == nil or item.menu.len == 0:
    return
  inc t.nextMenuGen
  let menu = MenuSession(
    gen: t.nextMenuGen, uid: item.uid, anchorX: x, anchorY: y,
    service: item.service, owner: if item.owner.len > 0: item.owner else: item.service,
    path: item.menu
  )
  t.menu = menu
  for member in ["LayoutUpdated", "ItemsPropertiesUpdated"]:
    var slot: SdBusSlot
    if sd_bus_match_signal(t.bus, addr slot, menu.owner.cstring, menu.path.cstring,
        MenuInterface, member.cstring, onMenuSignal, cast[pointer](menu.gen)) >= 0:
      menu.slots.add slot
  let req = t.newRequest(Request(kind: rkMenuAbout, gen: menu.gen, menuId: 0))
  if not callAboutToShow(t.bus, menu.service, menu.path, 0, onReply, req):
    t.requests.del cast[int](req)
    t.closeMenu()
    return
  t.changed()

proc menuActivate*(t: Tray, id: int) =
  ## The entry was clicked: Event(id, "clicked"), then the menu closes.
  let menu = t.menu
  if menu == nil:
    return
  t.menuCall(menu, id, "clicked")
  t.closeMenu()

proc menuSubmenuOpened*(t: Tray, id: int) =
  let menu = t.menu
  if menu == nil or id in menu.openIds:
    return
  menu.openIds.add id
  let req = t.newRequest(Request(kind: rkMenuAbout, gen: menu.gen, menuId: id))
  if not callAboutToShow(t.bus, menu.service, menu.path, id, onReply, req):
    t.requests.del cast[int](req)
  t.menuCall(menu, id, "opened")

proc menuSubmenuClosed*(t: Tray, id: int) =
  let menu = t.menu
  if menu == nil or id notin menu.openIds:
    return
  menu.openIds.delete menu.openIds.find(id)
  t.menuCall(menu, id, "closed")

proc menuOpenFor*(t: Tray, uid: int): bool =
  t != nil and t.menu != nil and t.menu.uid == uid

proc toggleMenu(t: Tray, item: TrayItem, x, y: int) =
  ## Clicking the icon of the open menu closes it.
  if t.menuOpenFor(item.uid):
    t.closeMenu()
  else:
    t.openMenu(item, x, y)

proc click*(t: Tray, uid, button, x, y: int) =
  ## A click or scroll on the item's icon (button numbers as in the bar:
  ## 1 left, 2 middle, 3 right, 4 scroll up, 5 scroll down). x/y: the icon's
  ## position on the screen.
  let item = t.findItem(uid)
  if item == nil:
    return
  case button
  of 1:
    if item.isMenu and item.menu.len > 0:
      t.toggleMenu(item, x, y)
    elif item.isMenu:
      t.call(item, "ContextMenu", "ContextMenu", "ii", x, y)
    else:
      t.call(item, "Activate", "Activate", "ii", x, y)
  of 2: t.call(item, "SecondaryActivate", "SecondaryActivate", "ii", x, y)
  of 3:
    if item.menu.len > 0:
      t.toggleMenu(item, x, y)
    else:
      t.call(item, "ContextMenu", "ContextMenu", "ii", x, y)
  of 4: t.call(item, "Scroll", "Scroll", "is", -1, s = "vertical")
  of 5: t.call(item, "Scroll", "Scroll", "is", 1, s = "vertical")
  else: discard
