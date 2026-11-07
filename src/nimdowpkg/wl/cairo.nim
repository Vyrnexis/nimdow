## Minimal hand-written bindings to cairo and pango(cairo): just what the
## status bar needs.

{.passC: gorge("pkg-config --cflags cairo pangocairo").}
{.passL: gorge("pkg-config --libs cairo pangocairo").}

type
  CairoObj = object
  CairoSurfaceObj = object
  Cairo* = ptr CairoObj
  CairoSurface* = ptr CairoSurfaceObj

  PangoLayoutObj = object
  PangoFontDescObj = object
  PangoLayout* = ptr PangoLayoutObj
  PangoFontDescription* = ptr PangoFontDescObj

  PangoRectangle* = object
    x*, y*, width*, height*: cint

const
  CAIRO_FORMAT_ARGB32* = 0.cint
  CAIRO_OPERATOR_SOURCE* = 1.cint
  CAIRO_OPERATOR_OVER* = 2.cint
  PANGO_SCALE* = 1024
  PANGO_ELLIPSIZE_END* = 3.cint

# --- cairo ---

proc cairo_image_surface_create_for_data*(data: pointer, format: cint,
    width, height, stride: cint): CairoSurface {.importc, cdecl.}
proc cairo_image_surface_create*(format: cint, width, height: cint): CairoSurface
  {.importc, cdecl.}
proc cairo_image_surface_create_from_png*(filename: cstring): CairoSurface
  {.importc, cdecl.}
proc cairo_image_surface_get_data*(s: CairoSurface): pointer {.importc, cdecl.}
proc cairo_image_surface_get_stride*(s: CairoSurface): cint {.importc, cdecl.}
proc cairo_image_surface_get_width*(s: CairoSurface): cint {.importc, cdecl.}
proc cairo_image_surface_get_height*(s: CairoSurface): cint {.importc, cdecl.}
proc cairo_surface_status*(s: CairoSurface): cint {.importc, cdecl.}
proc cairo_surface_mark_dirty*(s: CairoSurface) {.importc, cdecl.}
proc cairo_set_source_surface*(cr: Cairo, s: CairoSurface, x, y: cdouble)
  {.importc, cdecl.}
proc cairo_save*(cr: Cairo) {.importc, cdecl.}
proc cairo_restore*(cr: Cairo) {.importc, cdecl.}
proc cairo_translate*(cr: Cairo, x, y: cdouble) {.importc, cdecl.}
proc cairo_scale*(cr: Cairo, x, y: cdouble) {.importc, cdecl.}
proc cairo_surface_destroy*(s: CairoSurface) {.importc, cdecl.}
proc cairo_surface_set_device_scale*(s: CairoSurface, x, y: cdouble)
  {.importc, cdecl.}
proc cairo_surface_flush*(s: CairoSurface) {.importc, cdecl.}
proc cairo_create*(s: CairoSurface): Cairo {.importc, cdecl.}
proc cairo_destroy*(cr: Cairo) {.importc, cdecl.}
proc cairo_set_source_rgba*(cr: Cairo, r, g, b, a: cdouble) {.importc, cdecl.}
proc cairo_set_operator*(cr: Cairo, op: cint) {.importc, cdecl.}
proc cairo_rectangle*(cr: Cairo, x, y, w, h: cdouble) {.importc, cdecl.}
proc cairo_fill*(cr: Cairo) {.importc, cdecl.}
proc cairo_paint*(cr: Cairo) {.importc, cdecl.}
proc cairo_move_to*(cr: Cairo, x, y: cdouble) {.importc, cdecl.}
proc cairo_line_to*(cr: Cairo, x, y: cdouble) {.importc, cdecl.}
proc cairo_arc*(cr: Cairo, xc, yc, radius, angle1, angle2: cdouble) {.importc, cdecl.}
proc cairo_new_path*(cr: Cairo) {.importc, cdecl.}
proc cairo_stroke*(cr: Cairo) {.importc, cdecl.}
proc cairo_set_line_width*(cr: Cairo, width: cdouble) {.importc, cdecl.}

# --- pango ---

proc pango_cairo_create_layout*(cr: Cairo): PangoLayout {.importc, cdecl.}
proc pango_cairo_show_layout*(cr: Cairo, layout: PangoLayout) {.importc, cdecl.}
proc pango_layout_set_text*(l: PangoLayout, text: cstring, length: cint) {.importc, cdecl.}
proc pango_layout_set_font_description*(l: PangoLayout,
    desc: PangoFontDescription) {.importc, cdecl.}
proc pango_layout_set_width*(l: PangoLayout, width: cint) {.importc, cdecl.}
proc pango_layout_set_ellipsize*(l: PangoLayout, mode: cint) {.importc, cdecl.}
proc pango_layout_get_pixel_size*(l: PangoLayout, width, height: ptr cint) {.importc, cdecl.}
proc pango_layout_get_pixel_extents*(l: PangoLayout,
    ink, logical: ptr PangoRectangle) {.importc, cdecl.}
proc pango_layout_index_to_pos*(l: PangoLayout, index: cint,
    pos: ptr PangoRectangle) {.importc, cdecl.}
proc pango_font_description_from_string*(s: cstring): PangoFontDescription {.importc, cdecl.}
proc pango_font_description_free*(d: PangoFontDescription) {.importc, cdecl.}
proc g_object_unref*(o: pointer) {.importc, cdecl.}
