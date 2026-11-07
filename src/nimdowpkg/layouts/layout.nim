import
  ../client,
  ../area

type
  Layout* = ref object of RootObj
    name*: string
    monitorArea*: Area
    gapSize*: uint
    borderWidth*: uint
    masterSlots*: uint
  LayoutOffset* = tuple[top, left, bottom, right: uint]

proc newLayout*(name: string, monitorArea: Area, gapSize: uint, borderWidth: uint): Layout =
  Layout(name: name, gapSize: gapSize, borderWidth: borderWidth)

method arrange*(this: Layout, clients: seq[Client], offset: LayoutOffset) {.base.} =
  echo "Not implemented for base class"

