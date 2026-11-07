## Minimal bindings to librsvg, used to render SVG tray icons.

{.passC: gorge("pkg-config --cflags librsvg-2.0").}
{.passL: gorge("pkg-config --libs librsvg-2.0").}

import cairo

type
  RsvgHandleObj = object
  RsvgHandle* = ptr RsvgHandleObj
  RsvgRectangle* {.bycopy.} = object
    x*, y*, width*, height*: cdouble

proc rsvg_handle_new_from_file*(filename: cstring, error: pointer): RsvgHandle
  {.importc, cdecl.}
proc rsvg_handle_render_document*(handle: RsvgHandle, cr: Cairo,
    viewport: ptr RsvgRectangle, error: pointer): cint {.importc, cdecl.}
