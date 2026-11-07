## Convenience layer over the generated core `wayland` protocol module:
## connecting, global discovery/binding and an event-loop friendly dispatch.

import ./protocols/wayland
export wayland

{.passC: gorge("pkg-config --cflags wayland-client xkbcommon").}
{.passL: gorge("pkg-config --libs wayland-client xkbcommon").}

type
  Global* = object
    name*: uint32
    iface*: string
    version*: uint32

  Registry* = ref object
    obj*: WlRegistry
    globals*: seq[Global]
    ## Called for globals advertised after `discoverGlobals` returned
    ## (hotplugged seats, ...).
    onGlobal*: proc(g: Global) {.closure.}

proc registryGlobal(data: pointer, reg: WlRegistry, name: uint32,
    `interface`: cstring, version: uint32) {.cdecl.} =
  let r = cast[Registry](data)
  let g = Global(name: name, iface: $`interface`, version: version)
  r.globals.add g
  if r.onGlobal != nil:
    r.onGlobal(g)

proc registryGlobalRemove(data: pointer, reg: WlRegistry, name: uint32) {.cdecl.} =
  let r = cast[Registry](data)
  for i in 0 ..< r.globals.len:
    if r.globals[i].name == name:
      r.globals.delete i
      break

var registryListener = WlRegistryListener(global: registryGlobal,
    global_remove: registryGlobalRemove)

proc connect*(name: string = ""): WlDisplay =
  ## Connects to the compositor ($WAYLAND_DISPLAY when `name` is empty).
  ## Returns nil on failure.
  wl_display_connect(if name.len == 0: nil else: name.cstring)

proc fd*(d: WlDisplay): cint = wl_display_get_fd(d)

proc discoverGlobals*(d: WlDisplay): Registry =
  ## Fetches the registry and performs a roundtrip so `globals` is populated.
  ## The returned Registry is kept alive for the lifetime of the process.
  result = Registry(obj: wl_display_get_registry(d))
  GC_ref(result)
  discard wl_registry_add_listener(result.obj, addr registryListener, cast[pointer](result))
  discard wl_display_roundtrip(d)

proc find*(r: Registry, iface: string): Global =
  ## First advertised global named `iface`; `version == 0` when absent.
  for g in r.globals:
    if g.iface == iface: return g

proc bindGlobal*[T](r: Registry, g: Global, iface: var WlInterface,
    version: uint32): T =
  ## Binds a global as `min(version, g.version)`.
  let v = min(version, g.version)
  cast[T](wl_registry_bind(r.obj, g.name, addr iface, v))

proc prepareRead*(d: WlDisplay) =
  ## Standard libwayland threaded-read preamble: leaves the display ready for
  ## `readEvents`/`cancelRead`.
  while wl_display_prepare_read(d) != 0:
    discard wl_display_dispatch_pending(d)

proc flush*(d: WlDisplay): cint = wl_display_flush(d)
proc readEvents*(d: WlDisplay): cint = wl_display_read_events(d)
proc cancelRead*(d: WlDisplay) = wl_display_cancel_read(d)
proc dispatchPending*(d: WlDisplay): cint = wl_display_dispatch_pending(d)
proc roundtrip*(d: WlDisplay): cint = wl_display_roundtrip(d)
