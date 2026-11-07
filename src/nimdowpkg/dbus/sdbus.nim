## Minimal hand-written bindings to sd-bus (libsystemd): just what the system
## tray needs. Every call here is non-blocking except `sd_bus_open_user`
## (connect + Hello, done once at startup).

{.passC: gorge("pkg-config --cflags libsystemd").}
{.passL: gorge("pkg-config --libs libsystemd").}

type
  SdBusObj = object
  SdBusMessageObj = object
  SdBusSlotObj = object
  SdBus* = ptr SdBusObj
  SdBusMessage* = ptr SdBusMessageObj
  SdBusSlot* = ptr SdBusSlotObj

  SdBusError* {.bycopy.} = object
    name*: cstring
    message*: cstring
    needFree*: cint

  SdBusMessageHandler* = proc(m: SdBusMessage, userdata: pointer,
    err: ptr SdBusError): cint {.cdecl.}

const
  ## Flags of org.freedesktop.DBus.RequestName.
  DBUS_NAME_FLAG_DO_NOT_QUEUE* = 4'u32

# --- connection ---

proc sd_bus_open_user*(bus: ptr SdBus): cint {.importc, cdecl.}
proc sd_bus_close*(bus: SdBus) {.importc, cdecl.}
proc sd_bus_unref*(bus: SdBus): SdBus {.importc, cdecl, discardable.}
proc sd_bus_get_fd*(bus: SdBus): cint {.importc, cdecl.}
proc sd_bus_get_events*(bus: SdBus): cint {.importc, cdecl.}
proc sd_bus_get_timeout*(bus: SdBus, usec: ptr uint64): cint {.importc, cdecl.}
proc sd_bus_process*(bus: SdBus, ret: ptr SdBusMessage): cint {.importc, cdecl.}
proc sd_bus_get_unique_name*(bus: SdBus, unique: ptr cstring): cint {.importc, cdecl.}

# --- slots ---

proc sd_bus_slot_unref*(slot: SdBusSlot): SdBusSlot {.importc, cdecl, discardable.}

# --- calls, signals, matches ---

proc sd_bus_call_method_async*(bus: SdBus, slot: ptr SdBusSlot,
    destination, path, ifaceName, member: cstring,
    callback: SdBusMessageHandler, userdata: pointer,
    types: cstring): cint {.importc, cdecl, varargs.}
proc sd_bus_match_signal*(bus: SdBus, slot: ptr SdBusSlot,
    sender, path, ifaceName, member: cstring,
    callback: SdBusMessageHandler, userdata: pointer): cint {.importc, cdecl.}
proc sd_bus_emit_signal*(bus: SdBus, path, ifaceName, member: cstring,
    types: cstring): cint {.importc, cdecl, varargs.}
proc sd_bus_emit_properties_changed*(bus: SdBus, path, ifaceName,
    name: cstring): cint {.importc, cdecl, varargs.}
proc sd_bus_reply_method_return*(call: SdBusMessage, types: cstring): cint
  {.importc, cdecl, varargs.}

# --- messages ---

proc sd_bus_message_get_sender*(m: SdBusMessage): cstring {.importc, cdecl.}
proc sd_bus_message_get_path*(m: SdBusMessage): cstring {.importc, cdecl.}
proc sd_bus_message_get_member*(m: SdBusMessage): cstring {.importc, cdecl.}
proc sd_bus_message_get_errno*(m: SdBusMessage): cint {.importc, cdecl.}
proc sd_bus_message_is_method_error*(m: SdBusMessage, name: cstring): cint
  {.importc, cdecl.}
proc sd_bus_message_append*(m: SdBusMessage, types: cstring): cint
  {.importc, cdecl, varargs.}
proc sd_bus_message_append_strv*(m: SdBusMessage, l: cstringArray): cint
  {.importc, cdecl.}
proc sd_bus_message_read*(m: SdBusMessage, types: cstring): cint
  {.importc, cdecl, varargs.}
proc sd_bus_message_read_array*(m: SdBusMessage, kind: char,
    p: ptr pointer, size: ptr csize_t): cint {.importc, cdecl.}
proc sd_bus_message_skip*(m: SdBusMessage, types: cstring): cint {.importc, cdecl.}
proc sd_bus_message_peek_type*(m: SdBusMessage, kind: ptr char,
    contents: ptr cstring): cint {.importc, cdecl.}
proc sd_bus_message_enter_container*(m: SdBusMessage, kind: char,
    contents: cstring): cint {.importc, cdecl.}
proc sd_bus_message_exit_container*(m: SdBusMessage): cint {.importc, cdecl.}
proc sd_bus_message_at_end*(m: SdBusMessage, complete: cint): cint {.importc, cdecl.}

# --- the watcher object (see watcher_vtable.c) ---

{.compile: "watcher_vtable.c".}

proc nimdow_watcher_install*(bus: SdBus, slot: ptr SdBusSlot,
    userdata: pointer): cint {.importc, cdecl.}
