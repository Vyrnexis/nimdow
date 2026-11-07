## The menu tree of a dbusmenu (pure data, no D-Bus).

type
  MenuToggle* = enum
    mtNone, mtCheck, mtRadio

  MenuEntry* = ref object
    id*: int
    label*: string
    enabled*, visible*: bool
    separator*: bool
    toggle*: MenuToggle
    checked*: bool
    ## The entry opens a submenu (`children-display` = "submenu" or children).
    submenu*: bool
    iconName*: string
    children*: seq[MenuEntry]

proc stripMnemonics*(label: string): string =
  ## "_File" -> "File", "Save __as" -> "Save _as".
  var i = 0
  while i < label.len:
    if label[i] == '_':
      if i + 1 < label.len and label[i + 1] == '_':
        result.add '_'
        i += 2
      else:
        inc i
    else:
      result.add label[i]
      inc i

proc visibleChildren*(entry: MenuEntry): seq[MenuEntry] =
  if entry == nil:
    return
  for child in entry.children:
    if child.visible:
      result.add child

proc find*(root: MenuEntry, id: int): MenuEntry =
  if root == nil:
    return nil
  if root.id == id:
    return root
  for child in root.children:
    let found = child.find(id)
    if found != nil:
      return found

