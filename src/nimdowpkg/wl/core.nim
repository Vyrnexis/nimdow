## Hand-written bindings to libwayland-client's core API (wl_display, wl_proxy).
## The generated protocol modules in `protocols/` build on this.

{.passC: gorge("pkg-config --cflags wayland-client xkbcommon").}
{.passL: gorge("pkg-config --libs wayland-client xkbcommon").}

type
  WlFixed* = int32 ## wl_fixed_t, 24.8 signed fixed point.

  WlProxy* = object
  WlDisplayObj* = object
  WlDisplay* = ptr WlDisplayObj

  WlMessage* = object
    name*: cstring
    signature*: cstring
    types*: ptr ptr WlInterface

  WlInterface* = object
    name*: cstring
    version*: cint
    methodCount*: cint
    methods*: ptr WlMessage
    eventCount*: cint
    events*: ptr WlMessage

  WlArray* = object
    size*: csize_t
    alloc*: csize_t
    data*: pointer

const
  WL_MARSHAL_FLAG_DESTROY* = 1'u32

proc wlFixedToFloat*(f: WlFixed): float {.inline.} = f.float / 256.0
proc wlFixedFromFloat*(d: float): WlFixed {.inline.} = WlFixed(d * 256.0)

# --- wl_display ---

proc wl_display_connect*(name: cstring): WlDisplay {.importc, cdecl.}
proc wl_display_connect_to_fd*(fd: cint): WlDisplay {.importc, cdecl.}
proc wl_display_disconnect*(d: WlDisplay) {.importc, cdecl.}
proc wl_display_get_fd*(d: WlDisplay): cint {.importc, cdecl.}
proc wl_display_dispatch*(d: WlDisplay): cint {.importc, cdecl.}
proc wl_display_dispatch_pending*(d: WlDisplay): cint {.importc, cdecl.}
proc wl_display_roundtrip*(d: WlDisplay): cint {.importc, cdecl.}
proc wl_display_flush*(d: WlDisplay): cint {.importc, cdecl.}
proc wl_display_prepare_read*(d: WlDisplay): cint {.importc, cdecl.}
proc wl_display_cancel_read*(d: WlDisplay) {.importc, cdecl.}
proc wl_display_read_events*(d: WlDisplay): cint {.importc, cdecl.}
proc wl_display_get_error*(d: WlDisplay): cint {.importc, cdecl.}

# --- wl_proxy ---

proc wl_proxy_marshal_flags*(proxy: ptr WlProxy, opcode: uint32, iface: ptr WlInterface,
    version: uint32, flags: uint32): ptr WlProxy {.importc, cdecl, varargs, discardable.}
proc wl_proxy_add_listener*(proxy: ptr WlProxy, implementation: ptr pointer,
    data: pointer): cint {.importc, cdecl.}
proc wl_proxy_get_user_data*(proxy: ptr WlProxy): pointer {.importc, cdecl.}
proc wl_proxy_set_user_data*(proxy: ptr WlProxy, data: pointer) {.importc, cdecl.}
proc wl_proxy_get_version*(proxy: ptr WlProxy): uint32 {.importc, cdecl.}
proc wl_proxy_get_id*(proxy: ptr WlProxy): uint32 {.importc, cdecl.}
proc wl_proxy_destroy*(proxy: ptr WlProxy) {.importc, cdecl.}
