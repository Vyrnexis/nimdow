## Icons for the system tray: a simplified freedesktop icon theme lookup, and
## rendering of PNG/SVG files and SNI pixmaps into cairo ARGB32 surfaces.
##
## Lookup order for an icon name: the item's IconThemePath, the user's theme,
## its Inherits chain, hicolor, then the pixmaps directories. A name like
## "a-b-c" falls back to "a-b" and "a" when nothing was found. Results are
## cached.

import
  std/[os, strutils, tables, algorithm, sets]

import
  ../wl/cairo,
  ../wl/rsvg

type
  IconPixmap* = object
    width*, height*: int
    ## ARGB32, one byte per channel in network byte order (A, R, G, B).
    data*: string

  DirKind = enum dkFixed, dkScalable, dkThreshold

  ThemeDir = object
    path: string
    size, scale, minSize, maxSize, threshold: int
    kind: DirKind

  Theme = ref object
    name: string
    inherits: seq[string]
    dirs: seq[ThemeDir]

var
  themeName = ""
  themes: Table[string, Theme]
  lookupCache: Table[string, string]
  bases: seq[string]

proc iconBaseDirs(): seq[string] =
  if bases.len > 0:
    return bases
  let home = getHomeDir()
  var dirs = @[home / ".icons"]
  dirs.add getEnv("XDG_DATA_HOME", home / ".local/share") / "icons"
  let dataDirs = getEnv("XDG_DATA_DIRS", "/usr/local/share:/usr/share")
  for dir in dataDirs.split(':'):
    if dir.len > 0:
      dirs.add dir / "icons"
  for dir in dirs:
    if dirExists(dir) and dir notin bases:
      bases.add dir
  return bases

proc iniValue(path, key: string): string =
  ## First `key=value` of an ini file (any section).
  try:
    for line in lines(path):
      let l = line.strip()
      if l.startsWith(key & "="):
        return l[key.len + 1 .. ^1].strip()
  except IOError:
    discard

proc setIconTheme*(configured: string) =
  ## Picks the user's icon theme: the configured name, else the GTK settings,
  ## else Adwaita (when installed), else hicolor.
  themeName = configured
  if themeName.len == 0:
    let home = getHomeDir()
    for file in [home / ".config/gtk-3.0/settings.ini", home / ".config/gtk-4.0/settings.ini"]:
      themeName = iniValue(file, "gtk-icon-theme-name").strip(chars = {'"', '\''})
      if themeName.len > 0:
        break
  if themeName.len == 0:
    themeName = "hicolor"
    for base in iconBaseDirs():
      if dirExists(base / "Adwaita"):
        themeName = "Adwaita"
        break
  clear themes
  clear lookupCache

proc parseTheme(name: string): Theme =
  result = Theme(name: name)
  var indexFile = ""
  for base in iconBaseDirs():
    if fileExists(base / name / "index.theme"):
      indexFile = base / name / "index.theme"
      break
  if indexFile.len == 0:
    return
  var
    sections = initOrderedTable[string, Table[string, string]]()
    current = ""
  try:
    for line in lines(indexFile):
      let l = line.strip()
      if l.len == 0 or l[0] == '#':
        continue
      if l[0] == '[' and l[^1] == ']':
        current = l[1 .. ^2]
        sections[current] = initTable[string, string]()
      elif current.len > 0:
        let eq = l.find('=')
        if eq > 0:
          sections[current][l[0 ..< eq].strip()] = l[eq + 1 .. ^1].strip()
  except IOError:
    return
  if "Icon Theme" notin sections:
    return
  let header = sections["Icon Theme"]
  for inherit in header.getOrDefault("Inherits").split(','):
    if inherit.strip().len > 0:
      result.inherits.add inherit.strip()
  var dirNames = header.getOrDefault("Directories").split(',')
  dirNames.add header.getOrDefault("ScaledDirectories").split(',')
  for dirName in dirNames:
    let dirName = dirName.strip()
    if dirName.len == 0 or dirName notin sections:
      continue
    let s = sections[dirName]
    proc num(key: string, default: int): int =
      try: parseInt(s.getOrDefault(key, $default)) except ValueError: default
    var dir = ThemeDir(path: dirName, size: num("Size", 0), scale: max(1, num("Scale", 1)))
    dir.minSize = num("MinSize", dir.size)
    dir.maxSize = num("MaxSize", dir.size)
    dir.threshold = num("Threshold", 2)
    dir.kind =
      case s.getOrDefault("Type", "Threshold").toLowerAscii()
      of "fixed": dkFixed
      of "scalable": dkScalable
      else: dkThreshold
    result.dirs.add dir

proc getTheme(name: string): Theme =
  if name notin themes:
    themes[name] = parseTheme(name)
  themes[name]

proc distance(dir: ThemeDir, px: int): int =
  ## How far the directory's icons are from the wanted pixel size.
  case dir.kind
  of dkFixed:
    abs(dir.size * dir.scale - px)
  of dkScalable:
    if px < dir.minSize * dir.scale: dir.minSize * dir.scale - px
    elif px > dir.maxSize * dir.scale: px - dir.maxSize * dir.scale
    else: 0
  of dkThreshold:
    let lo = (dir.size - dir.threshold) * dir.scale
    let hi = (dir.size + dir.threshold) * dir.scale
    if px < lo: lo - px
    elif px > hi: px - hi
    else: 0

proc findFlat(dir, name: string): string =
  for ext in [".svg", ".png"]:
    if fileExists(dir / name & ext):
      return dir / name & ext

proc findInTheme(theme: Theme, name: string, px: int, searchBases: seq[string]): string =
  var dirs = theme.dirs
  dirs.sort(proc(a, b: ThemeDir): int =
    let c = cmp(distance(a, px), distance(b, px))
    if c != 0: c else: cmp(ord(b.kind == dkScalable), ord(a.kind == dkScalable))
  )
  for dir in dirs:
    for base in searchBases:
      let found = findFlat(base / theme.name / dir.path, name)
      if found.len > 0:
        return found

proc lookupOnce(name: string, px: int, searchBases: seq[string]): string =
  # The theme chain: the user's theme, its parents (breadth first), hicolor.
  var
    chain: seq[string]
    queue = @[themeName]
    seen = initHashSet[string]()
  while queue.len > 0:
    let n = queue[0]
    queue.delete 0
    if n in seen:
      continue
    seen.incl n
    chain.add n
    for parent in getTheme(n).inherits:
      queue.add parent
  if "hicolor" notin seen:
    chain.add "hicolor"
  for t in chain:
    let found = findInTheme(getTheme(t), name, px, searchBases)
    if found.len > 0:
      return found

proc findIconFile*(name, themePath: string, px: int): string =
  ## Returns the path of an icon file for `name`, or "" when there is none.
  if name.len == 0:
    return ""
  if name[0] == '/':
    return if fileExists(name): name else: ""
  if themeName.len == 0:
    setIconTheme("")
  let key = name & "|" & $px & "|" & themePath
  if key in lookupCache:
    return lookupCache[key]
  var
    searchBases = iconBaseDirs()
    found = ""
  if themePath.len > 0:
    searchBases.insert themePath
  var candidate = name
  while found.len == 0:
    if themePath.len > 0:
      found = findFlat(themePath, candidate)
    if found.len == 0:
      found = lookupOnce(candidate, px, searchBases)
    if found.len == 0:
      for dir in getEnv("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(':') &
          @["/usr/share"]:
        if dir.len > 0:
          found = findFlat(dir / "pixmaps", candidate)
          if found.len > 0:
            break
    if found.len > 0:
      break
    let dash = candidate.rfind('-')
    if dash <= 0:
      break
    candidate = candidate[0 ..< dash]
  lookupCache[key] = found
  return found

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

proc newSquare(px: int): CairoSurface =
  result = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, px.cint, px.cint)
  if cairo_surface_status(result) != 0:
    cairo_surface_destroy(result)
    return nil

proc scaleInto(src: CairoSurface, px: int): CairoSurface =
  ## Draws `src` centered in a new px*px surface, keeping the aspect ratio.
  let
    w = cairo_image_surface_get_width(src).float
    h = cairo_image_surface_get_height(src).float
  if w <= 0 or h <= 0:
    return nil
  result = newSquare(px)
  if result == nil:
    return
  let
    cr = cairo_create(result)
    factor = min(px.float / w, px.float / h)
  cairo_translate(cr, (px.float - w * factor) / 2, (px.float - h * factor) / 2)
  cairo_scale(cr, factor, factor)
  cairo_set_source_surface(cr, src, 0, 0)
  cairo_paint(cr)
  cairo_destroy(cr)

proc renderFile*(path: string, px: int): CairoSurface =
  ## Loads a PNG or SVG file as a px*px ARGB32 surface (nil on failure).
  if px <= 0:
    return nil
  if path.toLowerAscii().endsWith(".svg"):
    let handle = rsvg_handle_new_from_file(path.cstring, nil)
    if handle == nil:
      return nil
    result = newSquare(px)
    if result != nil:
      let cr = cairo_create(result)
      var viewport = RsvgRectangle(x: 0, y: 0, width: px.cdouble, height: px.cdouble)
      if rsvg_handle_render_document(handle, cr, addr viewport, nil) == 0:
        cairo_surface_destroy(result)
        result = nil
      cairo_destroy(cr)
    g_object_unref(handle)
  elif path.toLowerAscii().endsWith(".png"):
    let src = cairo_image_surface_create_from_png(path.cstring)
    if src == nil:
      return nil
    if cairo_surface_status(src) == 0:
      result = scaleInto(src, px)
    cairo_surface_destroy(src)

proc choosePixmap*(pixmaps: seq[IconPixmap], px: int): int =
  ## Index of the smallest pixmap that is at least `px` large, else the
  ## largest one; -1 without usable pixmaps.
  result = -1
  for i, p in pixmaps:
    if p.width <= 0 or p.height <= 0 or p.data.len < p.width * p.height * 4:
      continue
    if result == -1:
      result = i
      continue
    let
      best = max(pixmaps[result].width, pixmaps[result].height)
      size = max(p.width, p.height)
    if best >= px:
      if size >= px and size < best:
        result = i
    elif size > best:
      result = i

proc renderPixmap*(pixmap: IconPixmap, px: int): CairoSurface =
  ## Converts an SNI pixmap (ARGB32, network byte order) to a px*px surface
  ## (premultiplied, native endian).
  if px <= 0 or pixmap.width <= 0 or pixmap.height <= 0 or
      pixmap.data.len < pixmap.width * pixmap.height * 4:
    return nil
  let src = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, pixmap.width.cint, pixmap.height.cint)
  if cairo_surface_status(src) != 0:
    cairo_surface_destroy(src)
    return nil
  let
    stride = cairo_image_surface_get_stride(src)
    mem = cairo_image_surface_get_data(src)
  for y in 0 ..< pixmap.height:
    let row = cast[ptr UncheckedArray[uint32]](cast[int](mem) + y * stride)
    for x in 0 ..< pixmap.width:
      let i = (y * pixmap.width + x) * 4
      let
        a = pixmap.data[i].uint32
        r = pixmap.data[i + 1].uint32
        g = pixmap.data[i + 2].uint32
        b = pixmap.data[i + 3].uint32
      row[x] = (a shl 24) or (((r * a + 127) div 255) shl 16) or
        (((g * a + 127) div 255) shl 8) or ((b * a + 127) div 255)
  cairo_surface_mark_dirty(src)
  result = scaleInto(src, px)
  cairo_surface_destroy(src)
