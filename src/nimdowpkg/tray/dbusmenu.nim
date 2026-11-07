## Client side of com.canonical.dbusmenu: the menu tree of a tray item, parsed
## from `GetLayout` replies, and the (asynchronous) calls the popup needs.
##
## This module only knows about messages. The tray (tray.nim) owns the bus,
## the request bookkeeping and the menu session; the popup (menupopup.nim)
## draws the tree.

import
  ../dbus/sdbus,
  menutree

export menutree

const
  MenuInterface* = "com.canonical.dbusmenu"
  ## Deepest submenu nesting that is parsed.
  MaxDepth = 8

proc toStr(s: cstring): string =
  if s == nil: "" else: $s

proc readBool(m: SdBusMessage, default: bool): bool =
  var b: cint
  if sd_bus_message_read(m, "b", addr b) >= 0: b != 0 else: default

proc readEntry(m: SdBusMessage, depth: int): MenuEntry =
  ## Reads one `(ia{sv}av)`. Returns nil when the message is malformed.
  if sd_bus_message_enter_container(m, 'r', "ia{sv}av") <= 0:
    return nil
  result = MenuEntry(enabled: true, visible: true)
  var id: cint
  if sd_bus_message_read(m, "i", addr id) < 0:
    discard sd_bus_message_exit_container(m)
    return nil
  result.id = id
  var kindOfSubmenu = false
  if sd_bus_message_enter_container(m, 'a', "{sv}") > 0:
    while sd_bus_message_enter_container(m, 'e', "sv") > 0:
      var
        key: cstring
        kind: char
        contents: cstring
      if sd_bus_message_read(m, "s", addr key) < 0 or
          sd_bus_message_peek_type(m, addr kind, addr contents) < 0 or
          sd_bus_message_enter_container(m, 'v', contents) < 0:
        discard sd_bus_message_exit_container(m)
        break
      let
        name = toStr(key)
        sig = toStr(contents)
      var handled = true
      case name
      of "label":
        if sig == "s":
          var s: cstring
          if sd_bus_message_read(m, "s", addr s) >= 0:
            result.label = stripMnemonics(toStr(s))
        else: handled = false
      of "enabled": (if sig == "b": result.enabled = readBool(m, true) else: handled = false)
      of "visible": (if sig == "b": result.visible = readBool(m, true) else: handled = false)
      of "type":
        if sig == "s":
          var s: cstring
          if sd_bus_message_read(m, "s", addr s) >= 0:
            result.separator = toStr(s) == "separator"
        else: handled = false
      of "toggle-type":
        if sig == "s":
          var s: cstring
          if sd_bus_message_read(m, "s", addr s) >= 0:
            result.toggle =
              case toStr(s)
              of "checkmark": mtCheck
              of "radio": mtRadio
              else: mtNone
        else: handled = false
      of "toggle-state":
        if sig == "i":
          var i: cint
          if sd_bus_message_read(m, "i", addr i) >= 0:
            result.checked = i == 1
        elif sig == "b":
          result.checked = readBool(m, false)
        else: handled = false
      of "children-display":
        if sig == "s":
          var s: cstring
          if sd_bus_message_read(m, "s", addr s) >= 0:
            kindOfSubmenu = toStr(s) == "submenu"
        else: handled = false
      of "icon-name":
        if sig == "s":
          var s: cstring
          if sd_bus_message_read(m, "s", addr s) >= 0:
            result.iconName = toStr(s)
        else: handled = false
      else: handled = false
      if not handled:
        discard sd_bus_message_skip(m, contents)
      discard sd_bus_message_exit_container(m)  # variant
      discard sd_bus_message_exit_container(m)  # dict entry
    discard sd_bus_message_exit_container(m)
  if sd_bus_message_enter_container(m, 'a', "v") > 0:
    while sd_bus_message_enter_container(m, 'v', "(ia{sv}av)") > 0:
      if depth < MaxDepth:
        let child = readEntry(m, depth + 1)
        if child != nil:
          result.children.add child
      else:
        discard sd_bus_message_skip(m, "(ia{sv}av)")
      discard sd_bus_message_exit_container(m)
    discard sd_bus_message_exit_container(m)
  discard sd_bus_message_exit_container(m)
  result.submenu = kindOfSubmenu or result.children.len > 0

proc readLayout*(m: SdBusMessage): tuple[ok: bool, revision: uint32, root: MenuEntry] =
  ## Parses a GetLayout reply `u(ia{sv}av)`.
  var revision: uint32
  if sd_bus_message_read(m, "u", addr revision) < 0:
    return
  let root = readEntry(m, 0)
  if root == nil:
    return
  (true, revision, root)

proc readSignalRevision*(m: SdBusMessage): uint32 =
  ## The revision of a LayoutUpdated signal `ui`.
  var revision: uint32
  if sd_bus_message_read(m, "u", addr revision) >= 0:
    result = revision

# ---------------------------------------------------------------------------
# Calls (asynchronous: the reply goes to `callback` with `userdata`)
# ---------------------------------------------------------------------------

proc callAboutToShow*(bus: SdBus, service, path: string, id: int,
    callback: SdBusMessageHandler, userdata: pointer): bool =
  sd_bus_call_method_async(bus, nil, service.cstring, path.cstring, MenuInterface,
    "AboutToShow", callback, userdata, "i", id.cint) >= 0

proc callGetLayout*(bus: SdBus, service, path: string,
    callback: SdBusMessageHandler, userdata: pointer): bool =
  ## GetLayout(parentId = 0, recursionDepth = -1, propertyNames = []).
  sd_bus_call_method_async(bus, nil, service.cstring, path.cstring, MenuInterface,
    "GetLayout", callback, userdata, "iias", 0.cint, -1.cint, nil.pointer) >= 0

proc callEvent*(bus: SdBus, service, path: string, id: int, eventId: string,
    timestamp: uint32, callback: SdBusMessageHandler, userdata: pointer): bool =
  ## Event(id, eventId, data = variant int32 0, timestamp).
  sd_bus_call_method_async(bus, nil, service.cstring, path.cstring, MenuInterface,
    "Event", callback, userdata, "isvu", id.cint, eventId.cstring, "i".cstring, 0.cint,
    timestamp) >= 0
