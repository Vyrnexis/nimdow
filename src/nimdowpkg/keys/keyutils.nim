import
  strutils,
  tables

import ../wl/protocols/river_window_management_v1

## Key helpers for River's xkb bindings (xkbcommon keysyms).

type Keysym* = uint32

const NoSymbol* = 0'u32

proc xkb_keysym_from_name(name: cstring, flags: cint): uint32 {.
  importc, cdecl, header: "<xkbcommon/xkbcommon.h>".}

## A table of key modifier names to their respective River modifier masks.
## River has no equivalent of caps lock/mod2 (num lock); those are ignored
## (mapped to no modifier) since River matches bindings regardless of locks.
const ModifierTable* = {
  "control": RIVER_SEAT_V1_MODIFIERS_CTRL,
  "shift": RIVER_SEAT_V1_MODIFIERS_SHIFT,
  "alt": RIVER_SEAT_V1_MODIFIERS_MOD1,
  "super": RIVER_SEAT_V1_MODIFIERS_MOD4,
  "caps lock": RIVER_SEAT_V1_MODIFIERS_NONE,
  "mod1": RIVER_SEAT_V1_MODIFIERS_MOD1,
  "mod2": RIVER_SEAT_V1_MODIFIERS_NONE,
  "mod3": RIVER_SEAT_V1_MODIFIERS_MOD3,
  "mod4": RIVER_SEAT_V1_MODIFIERS_MOD4,
  "mod5": RIVER_SEAT_V1_MODIFIERS_MOD5,
}.toTable()

proc toKeysym*(key: string): Keysym =
  ## Converts a key name (e.g. "Return", "i", "comma", "1") to an xkbcommon keysym.
  ## Returns NoSymbol if the name is unknown.
  ##
  ## River matches a binding against the keysym of the physical key at its base
  ## level (shift is NOT applied; Super+Shift+1 matches the keysym `1`, not
  ## `exclam`) and requires the modifiers to match exactly. So letters must be
  ## lowercase: a config key "R" (keysym `R`, shift level) could never match.
  if key.len == 1 and key[0] in {'A'..'Z'}:
    return xkb_keysym_from_name(key.toLowerAscii.cstring, 0)
  xkb_keysym_from_name(key.cstring, 0)
