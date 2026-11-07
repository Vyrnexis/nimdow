## Minimal bindings to libwayland-cursor (loading Xcursor themes into wl_shm).

import ./protocols/wayland

{.passC: gorge("pkg-config --cflags wayland-cursor").}
{.passL: gorge("pkg-config --libs wayland-cursor").}

type
  WlCursorThemeObj = object
  WlCursorTheme* = ptr WlCursorThemeObj

  WlCursorImage* = object
    width*, height*, hotspotX*, hotspotY*, delay*: uint32

  WlCursor* = object
    imageCount*: cuint
    images*: ptr UncheckedArray[ptr WlCursorImage]
    name*: cstring

proc wl_cursor_theme_load*(name: cstring, size: cint, shm: WlShm): WlCursorTheme
  {.importc, cdecl.}
proc wl_cursor_theme_destroy*(theme: WlCursorTheme) {.importc, cdecl.}
proc wl_cursor_theme_get_cursor*(theme: WlCursorTheme, name: cstring): ptr WlCursor
  {.importc, cdecl.}
proc wl_cursor_image_get_buffer*(image: ptr WlCursorImage): WlBuffer
  {.importc, cdecl.}
