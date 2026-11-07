## nimdowinput: injects keyboard and pointer input into a Wayland compositor
## through zwp_virtual_keyboard_v1 and zwlr_virtual_pointer_v1 (test tool for
## tests/e2e/run.sh).
##
##   nimdowinput key super+shift+1
##   nimdowinput type "hello"
##   nimdowinput move X Y            (absolute, in output coordinates)
##   nimdowinput click left|right|middle
##   nimdowinput drag super left X1 Y1 X2 Y2
##   nimdowinput scroll up|down
##
## NIMDOWINPUT_EXTENT=WxH overrides the extent used for absolute motion (the
## first wl_output's mode by default).
import std/[os, strutils, posix, times]

import ../../src/nimdowpkg/wl/client
import ../../src/nimdowpkg/wl/protocols/[
  virtual_keyboard_unstable_v1, wlr_virtual_pointer_unstable_v1]

{.passC: gorge("pkg-config --cflags xkbcommon").}
{.passL: gorge("pkg-config --libs xkbcommon").}

type
  XkbRuleNames {.importc: "struct xkb_rule_names", header: "<xkbcommon/xkbcommon.h>".} = object
    rules, model, layout, variant, options: cstring
  XkbContext = distinct pointer
  XkbKeymap = distinct pointer

proc xkb_context_new(flags: cint): XkbContext {.importc, header: "<xkbcommon/xkbcommon.h>".}
proc xkb_keymap_new_from_names(ctx: XkbContext, names: ptr XkbRuleNames,
  flags: cint): XkbKeymap {.importc, header: "<xkbcommon/xkbcommon.h>".}
proc xkb_keymap_get_as_string(km: XkbKeymap, format: cint): cstring {.
  importc, header: "<xkbcommon/xkbcommon.h>".}
proc xkb_keymap_min_keycode(km: XkbKeymap): uint32 {.importc, header: "<xkbcommon/xkbcommon.h>".}
proc xkb_keymap_max_keycode(km: XkbKeymap): uint32 {.importc, header: "<xkbcommon/xkbcommon.h>".}
proc xkb_keymap_num_levels_for_key(km: XkbKeymap, key: uint32, layout: uint32): uint32 {.
  importc, header: "<xkbcommon/xkbcommon.h>".}
proc xkbSymsByLevel(km: XkbKeymap, key, layout, level: uint32,
  syms: ptr pointer): cint {.importc: "nimdowinput_syms_by_level", nodecl.}
proc xkb_keymap_mod_get_index(km: XkbKeymap, name: cstring): uint32 {.
  importc, header: "<xkbcommon/xkbcommon.h>".}
proc xkb_keysym_from_name(name: cstring, flags: cint): uint32 {.
  importc, header: "<xkbcommon/xkbcommon.h>".}
{.emit: """/*INCLUDESECTION*/
#define _GNU_SOURCE
#include <sys/mman.h>
#include <xkbcommon/xkbcommon.h>
static int nimdowinput_syms_by_level(void *km, unsigned key, unsigned layout, unsigned level, void **out) {
  return xkb_keymap_key_get_syms_by_level((struct xkb_keymap *)km, key, layout, level, (const xkb_keysym_t **)out);
}
""".}
proc xkb_utf32_to_keysym(ucs: uint32): uint32 {.importc, header: "<xkbcommon/xkbcommon.h>".}
proc memfd_create(name: cstring, flags: cuint): cint {.importc, nodecl.}

const
  ModInvalid = 0xffffffff'u32
  BtnLeft = 0x110'u32
  BtnRight = 0x111'u32
  BtnMiddle = 0x112'u32

type
  Key = tuple[code: uint32, level: int]
  Mod = tuple[name: string, xkbName: string, keysym: string]

const mods: array[4, Mod] = [
  ("super", "Mod4", "Super_L"), ("shift", "Shift", "Shift_L"),
  ("control", "Control", "Control_L"), ("alt", "Mod1", "Alt_L")]

var
  display: WlDisplay
  seat: WlSeat
  output: WlOutput
  kbManager: ZwpVirtualKeyboardManagerV1
  ptrManager: ZwlrVirtualPointerManagerV1
  keyboard: ZwpVirtualKeyboardV1
  vptr: ZwlrVirtualPointerV1
  keymap: XkbKeymap
  extentW, extentH: uint32

proc die(msg: string) =
  stderr.writeLine "nimdowinput: " & msg
  quit(1)

proc nowMs(): uint32 =
  uint32(epochTime() * 1000) and 0x7fffffff'u32

proc settle(ms = 40) =
  ## Gets the requests to the compositor and gives it time to process them.
  discard display.roundtrip()
  sleep(ms)

proc outputMode(data: pointer, o: WlOutput, flags: uint32, w, h, refresh: int32) {.cdecl.} =
  if (flags and 1) != 0 or extentW == 0:
    extentW = w.uint32
    extentH = h.uint32

proc setupKeyboard() =
  if kbManager.isNil: die "zwp_virtual_keyboard_manager_v1 not available"
  let ctx = xkb_context_new(0)
  var names = XkbRuleNames(rules: "evdev", model: "pc105", layout: "us")
  keymap = xkb_keymap_new_from_names(ctx, addr names, 0)
  if cast[pointer](keymap).isNil: die "failed to build the xkb keymap"
  let str = xkb_keymap_get_as_string(keymap, 1)
  let size = str.len + 1
  let fd = memfd_create("nimdowinput-keymap", 0)
  if fd < 0: die "memfd_create failed"
  if write(fd, cast[pointer](str), size) != size: die "writing keymap failed"
  keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(kbManager, seat)
  zwp_virtual_keyboard_v1_keymap(keyboard, 1, fd, size.uint32)
  settle()
  discard close(fd)

proc setupPointer() =
  if ptrManager.isNil: die "zwlr_virtual_pointer_manager_v1 not available"
  vptr = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(ptrManager, seat)
  let env = getEnv("NIMDOWINPUT_EXTENT")
  if env.len > 0:
    let parts = env.split('x')
    extentW = parts[0].parseUInt.uint32
    extentH = parts[1].parseUInt.uint32
  if extentW == 0 or extentH == 0: die "unknown output extent (set NIMDOWINPUT_EXTENT)"

proc findKey(sym: uint32): Key =
  ## The evdev keycode (+ xkb level) producing the keysym on layout 0.
  for kc in xkb_keymap_min_keycode(keymap) .. xkb_keymap_max_keycode(keymap):
    let levels = xkb_keymap_num_levels_for_key(keymap, kc, 0)
    for level in 0'u32 ..< levels:
      var syms: pointer
      let n = xkbSymsByLevel(keymap, kc, 0, level, addr syms)
      if n >= 1 and cast[ptr uint32](syms)[] == sym:
        # evdev keycode = xkb keycode - 8
        return (kc - 8, level.int)
  die "no key produces keysym " & $sym

proc keyFor(name: string): Key =
  var sym = xkb_keysym_from_name(name.cstring, 0)
  if sym == 0: sym = xkb_keysym_from_name(name.cstring, 1) # case insensitive
  if sym == 0: die "unknown key \"" & name & "\""
  findKey(sym)

proc modMask(name: string): uint32 =
  for m in mods:
    if m.name == name or (name == "ctrl" and m.name == "control") or
       (name == "mod4" and m.name == "super") or (name == "mod1" and m.name == "alt"):
      let idx = xkb_keymap_mod_get_index(keymap, m.xkbName.cstring)
      if idx == ModInvalid: die "keymap has no modifier " & m.xkbName
      return 1'u32 shl idx
  die "unknown modifier \"" & name & "\""

proc modKeyCode(name: string): uint32 =
  for m in mods:
    if m.name == name or (name == "ctrl" and m.name == "control") or
       (name == "mod4" and m.name == "super") or (name == "mod1" and m.name == "alt"):
      return keyFor(m.keysym).code

proc sendKey(code: uint32, down: bool) =
  zwp_virtual_keyboard_v1_key(keyboard, nowMs(), code, if down: 1 else: 0)
  settle(15)

proc setMods(mask: uint32) =
  zwp_virtual_keyboard_v1_modifiers(keyboard, mask, 0, 0, 0)
  settle(15)

proc pressMods(names: seq[string]): uint32 =
  ## Presses the modifier keys and announces them; returns the mask.
  for n in names:
    sendKey(modKeyCode(n), true)
    result = result or modMask(n)
  setMods(result)

proc releaseMods(names: seq[string]) =
  setMods(0)
  for i in countdown(names.high, 0):
    sendKey(modKeyCode(names[i]), false)

proc tapKey(spec: string) =
  var parts = spec.split('+')
  let key = keyFor(parts.pop())
  for i in 0 ..< parts.len: parts[i] = parts[i].toLowerAscii
  if key.level > 0 and "shift" notin parts: parts.add "shift"
  discard pressMods(parts)
  sendKey(key.code, true)
  sleep(20)
  sendKey(key.code, false)
  releaseMods(parts)
  settle(60)

proc typeText(text: string) =
  ## Types ASCII text (shift is pressed for the shifted level of a key).
  for c in text:
    let key = findKey(xkb_utf32_to_keysym(c.uint32))
    let names = if key.level > 0: @["shift"] else: @[]
    discard pressMods(names)
    sendKey(key.code, true)
    sleep(10)
    sendKey(key.code, false)
    releaseMods(names)
    settle(20)

proc frame() = zwlr_virtual_pointer_v1_frame(vptr)

proc moveTo(x, y: int) =
  zwlr_virtual_pointer_v1_motion_absolute(vptr, nowMs(), x.uint32, y.uint32, extentW, extentH)
  frame()
  settle(30)

proc buttonCode(name: string): uint32 =
  case name
  of "left": BtnLeft
  of "right": BtnRight
  of "middle": BtnMiddle
  else: die "unknown button \"" & name & "\""; 0

proc button(code: uint32, down: bool) =
  zwlr_virtual_pointer_v1_button(vptr, nowMs(), code, if down: 1 else: 0)
  frame()
  settle(40)

proc click(name: string) =
  let code = buttonCode(name)
  button(code, true)
  button(code, false)

proc scroll(dir: string) =
  # One wheel notch is 15 units; the bar acts on larger accumulations.
  let value = if dir == "up": -15.0 else: 15.0
  zwlr_virtual_pointer_v1_axis_source(vptr, 0) # wheel
  zwlr_virtual_pointer_v1_axis(vptr, nowMs(), 0, wlFixedFromFloat(value))
  zwlr_virtual_pointer_v1_axis_discrete(vptr, nowMs(), 0, wlFixedFromFloat(value),
    if dir == "up": -1 else: 1)
  frame()
  settle(60)

proc drag(modName, btn: string, x1, y1, x2, y2: int) =
  let names = if modName == "none": @[] else: @[modName]
  moveTo(x1, y1)
  discard pressMods(names)
  let code = buttonCode(btn)
  button(code, true)
  const steps = 10
  for i in 1 .. steps:
    moveTo(x1 + (x2 - x1) * i div steps, y1 + (y2 - y1) * i div steps)
    sleep(20)
  button(code, false)
  releaseMods(names)
  settle(60)

proc usage() =
  die "usage: nimdowinput key <combo> | type <text> | move X Y | click <button> | " &
    "drag <mod|none> <button> X1 Y1 X2 Y2 | scroll up|down | sleep MS"

when isMainModule:
  if paramCount() < 1: usage()
  display = connect()
  if display.isNil: die "failed to connect to the Wayland server"
  let registry = discoverGlobals(display)
  proc bindOne[T](iface: string, wlIface: var WlInterface, version: uint32): T =
    let g = registry.find(iface)
    if g.version == 0: return nil
    bindGlobal[T](registry, g, wlIface, version)
  seat = bindOne[WlSeat]("wl_seat", wl_seat_interface, 1)
  output = bindOne[WlOutput]("wl_output", wl_output_interface, 2)
  kbManager = bindOne[ZwpVirtualKeyboardManagerV1](
    "zwp_virtual_keyboard_manager_v1", zwp_virtual_keyboard_manager_v1_interface, 1)
  ptrManager = bindOne[ZwlrVirtualPointerManagerV1](
    "zwlr_virtual_pointer_manager_v1", zwlr_virtual_pointer_manager_v1_interface, 1)
  if seat.isNil: die "no wl_seat"
  if not output.isNil:
    var listener = wl_output_noop_listener()
    listener.mode = outputMode
    discard wl_output_add_listener(output, addr listener, nil)
    discard display.roundtrip()

  let args = commandLineParams()
  proc i(n: int): int = args[n].parseInt
  case args[0]
  of "key":
    if args.len != 2: usage()
    setupKeyboard()
    tapKey(args[1])
  of "type":
    if args.len != 2: usage()
    setupKeyboard()
    typeText(args[1])
  of "move":
    if args.len != 3: usage()
    setupPointer()
    moveTo(i(1), i(2))
  of "click":
    if args.len != 2: usage()
    setupPointer()
    click(args[1])
  of "scroll":
    if args.len != 2 or args[1] notin ["up", "down"]: usage()
    setupPointer()
    scroll(args[1])
  of "drag":
    if args.len != 7: usage()
    setupKeyboard()
    setupPointer()
    drag(args[1].toLowerAscii, args[2], i(3), i(4), i(5), i(6))
  of "sleep":
    sleep(i(1))
  else: usage()
  settle(30)
