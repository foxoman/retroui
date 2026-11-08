## libxkbcommon, loaded at run time: the keyboard's layout as the system has
## it (a Wayland compositor hands it over; a framebuffer driver makes it
## from the system's settings) -- the keysym each key gives with the
## modifiers down, the text it types, dead keys and compose sequences.
## Nothing is linked: without the library a driver falls back on a US
## keyboard (`keysyms.usKeysym`).

import std/[dynlib, os]

type
  XkbHandles = object
    ctx, keymap, state: pointer
    compose, composeState: pointer

  XkbKeyboard* = object
    ## A keyboard's layout and its state now.
    h: XkbHandles
    shiftIdx, ctrlIdx, altIdx, superIdx: uint32
    ready*: bool

const
  XKB_KEYMAP_FORMAT_TEXT_V1 = 1.cint
  XKB_STATE_MODS_EFFECTIVE = 8.cint
  XKB_COMPOSE_FEED_ACCEPTED = 1.cint
  XKB_COMPOSE_COMPOSING* = 1.cint
  XKB_COMPOSE_COMPOSED* = 2.cint
  XKB_COMPOSE_CANCELLED* = 3.cint

var
  xkbState = 0          ## 0 not tried, 1 loaded, -1 not there
  ctxNew: proc (flags: cint): pointer {.cdecl, gcsafe.}
  keymapFromString: proc (ctx: pointer; s: cstring; format, flags: cint): pointer {.cdecl, gcsafe.}
  keymapFromNames: proc (ctx: pointer; names: pointer; flags: cint): pointer {.cdecl, gcsafe.}
  keymapUnref: proc (k: pointer) {.cdecl, gcsafe.}
  keymapAsString: proc (k: pointer; format: cint): cstring {.cdecl, gcsafe.}
  stateNew: proc (k: pointer): pointer {.cdecl, gcsafe.}
  stateUnref: proc (s: pointer) {.cdecl, gcsafe.}
  stateUpdateMask: proc (s: pointer; dep, lat, lock, dl, ll, grp: uint32): cint {.cdecl, gcsafe.}
  stateUpdateKey: proc (s: pointer; key: uint32; dir: cint): cint {.cdecl, gcsafe.}
  stateOneSym: proc (s: pointer; key: uint32): uint32 {.cdecl, gcsafe.}
  stateUtf8: proc (s: pointer; key: uint32; buf: cstring; size: csize_t): cint {.cdecl, gcsafe.}
  stateModIndexActive: proc (s: pointer; idx: uint32; kind: cint): cint {.cdecl, gcsafe.}
  keymapModIndex: proc (k: pointer; name: cstring): uint32 {.cdecl, gcsafe.}
  keymapRepeats: proc (k: pointer; key: uint32): cint {.cdecl, gcsafe.}
  keymapNumLayouts: proc (k: pointer): uint32 {.cdecl, gcsafe.}
  keymapSymsByLevel: proc (k: pointer; key, layout, level: uint32;
                           syms: ptr ptr UncheckedArray[uint32]): cint {.cdecl, gcsafe.}
  composeTableNew: proc (ctx: pointer; locale: cstring; flags: cint): pointer {.cdecl, gcsafe.}
  composeStateNew: proc (t: pointer; flags: cint): pointer {.cdecl, gcsafe.}
  composeFeed: proc (s: pointer; sym: uint32): cint {.cdecl, gcsafe.}
  composeStatus: proc (s: pointer): cint {.cdecl, gcsafe.}
  composeUtf8: proc (s: pointer; buf: cstring; size: csize_t): cint {.cdecl, gcsafe.}
  composeReset: proc (s: pointer) {.cdecl, gcsafe.}

proc loadXkb*(): bool =
  ## libxkbcommon is there (loaded the first time).
  if xkbState == 0:
    xkbState = -1
    let lib = loadLib("libxkbcommon.so.0")
    if lib == nil: return false
    template get(v, name) =
      v = cast[typeof(v)](lib.symAddr(name))
    get(ctxNew, "xkb_context_new")
    get(keymapFromString, "xkb_keymap_new_from_string")
    get(keymapFromNames, "xkb_keymap_new_from_names")
    get(keymapUnref, "xkb_keymap_unref")
    get(keymapAsString, "xkb_keymap_get_as_string")
    get(stateNew, "xkb_state_new")
    get(stateUnref, "xkb_state_unref")
    get(stateUpdateMask, "xkb_state_update_mask")
    get(stateUpdateKey, "xkb_state_update_key")
    get(stateOneSym, "xkb_state_key_get_one_sym")
    get(stateUtf8, "xkb_state_key_get_utf8")
    get(stateModIndexActive, "xkb_state_mod_index_is_active")
    get(keymapModIndex, "xkb_keymap_mod_get_index")
    get(keymapRepeats, "xkb_keymap_key_repeats")
    get(keymapNumLayouts, "xkb_keymap_num_layouts")
    get(keymapSymsByLevel, "xkb_keymap_key_get_syms_by_level")
    get(composeTableNew, "xkb_compose_table_new_from_locale")
    get(composeStateNew, "xkb_compose_state_new")
    get(composeFeed, "xkb_compose_state_feed")
    get(composeStatus, "xkb_compose_state_get_status")
    get(composeUtf8, "xkb_compose_state_get_utf8")
    get(composeReset, "xkb_compose_state_reset")
    if ctxNew != nil and keymapFromString != nil and stateNew != nil and
       stateUpdateMask != nil and stateOneSym != nil and stateUtf8 != nil and
       stateModIndexActive != nil and keymapModIndex != nil and keymapUnref != nil and
       stateUnref != nil:
      xkbState = 1
  xkbState == 1

proc free*(k: var XkbKeyboard) =
  if k.h.state != nil: stateUnref(k.h.state)
  if k.h.keymap != nil: keymapUnref(k.h.keymap)
  k.h.state = nil
  k.h.keymap = nil
  k.ready = false

proc localeName(): string =
  for v in ["LC_ALL", "LC_CTYPE", "LANG"]:
    let s = getEnv(v)
    if s.len > 0: return s
  "C"

proc setup(k: var XkbKeyboard; keymap: pointer): bool =
  if keymap == nil: return false
  let st = stateNew(keymap)
  if st == nil:
    keymapUnref(keymap)
    return false
  k.free()
  k.h.keymap = keymap
  k.h.state = st
  k.shiftIdx = keymapModIndex(keymap, "Shift")
  k.ctrlIdx = keymapModIndex(keymap, "Control")
  k.altIdx = keymapModIndex(keymap, "Mod1")
  k.superIdx = keymapModIndex(keymap, "Mod4")
  if k.h.compose == nil and composeTableNew != nil and composeStateNew != nil:
    let t = composeTableNew(k.h.ctx, cstring(localeName()), 0)
    if t != nil: k.h.composeState = composeStateNew(t, 0)
    k.h.compose = t
  k.ready = true
  true

proc fromText*(k: var XkbKeyboard; text: string): bool =
  ## The layout a compositor sent (XKB's text format).
  if not loadXkb(): return false
  if k.h.ctx == nil: k.h.ctx = ctxNew(0)
  if k.h.ctx == nil: return false
  k.setup(keymapFromString(k.h.ctx, cstring(text), XKB_KEYMAP_FORMAT_TEXT_V1, 0))

proc fromSystem*(k: var XkbKeyboard; layout = ""; variant = ""): bool =
  ## The system's layout (XKB_DEFAULT_LAYOUT and the like, else `layout`).
  if not loadXkb() or keymapFromNames == nil: return false
  if k.h.ctx == nil: k.h.ctx = ctxNew(0)
  if k.h.ctx == nil: return false
  type RuleNames = object
    rules, model, layout, variant, options: cstring
  var names = RuleNames()
  if layout.len > 0: names.layout = cstring(layout)
  if variant.len > 0: names.variant = cstring(variant)
  k.setup(keymapFromNames(k.h.ctx, addr names, 0))

proc updateMask*(k: var XkbKeyboard; depressed, latched, locked, group: uint32) =
  if k.ready: discard stateUpdateMask(k.h.state, depressed, latched, locked, 0, 0, group)

proc updateKey*(k: var XkbKeyboard; key: uint32; down: bool) =
  ## (a driver that reads the keys itself keeps the state so: `key` is the
  ## evdev code + 8)
  if k.ready and stateUpdateKey != nil: discard stateUpdateKey(k.h.state, key, if down: 1 else: 0)

proc sym*(k: XkbKeyboard; key: uint32): uint32 =
  ## The keysym of `key` (evdev code + 8) with the modifiers now.
  if k.ready: stateOneSym(k.h.state, key) else: 0

proc text*(k: XkbKeyboard; key: uint32): string =
  ## The text `key` types now.
  if not k.ready: return ""
  var buf: array[64, char]
  let n = stateUtf8(k.h.state, key, cast[cstring](addr buf[0]), buf.len.csize_t)
  if n <= 0: return ""
  for i in 0 ..< min(n.int, buf.len - 1): result.add buf[i]

proc latinSyms*(k: XkbKeyboard; key: uint32): seq[uint32] =
  ## What `key` gives in every layout, unshifted then shifted: a key of a
  ## Cyrillic or Greek layout is found by its Latin letter (Ctrl+C).
  if not k.ready or keymapSymsByLevel == nil or keymapNumLayouts == nil: return
  for layout in 0'u32 ..< keymapNumLayouts(k.h.keymap):
    for level in 0'u32 .. 1'u32:
      var syms: ptr UncheckedArray[uint32]
      let n = keymapSymsByLevel(k.h.keymap, key, layout, level, addr syms)
      for i in 0 ..< n.int: result.add syms[i]

proc active(k: XkbKeyboard; idx: uint32): bool =
  idx != 0xFFFFFFFF'u32 and stateModIndexActive(k.h.state, idx, XKB_STATE_MODS_EFFECTIVE) > 0

proc shift*(k: XkbKeyboard): bool = k.ready and k.active(k.shiftIdx)
proc ctrl*(k: XkbKeyboard): bool = k.ready and k.active(k.ctrlIdx)
proc alt*(k: XkbKeyboard): bool = k.ready and k.active(k.altIdx)
proc super*(k: XkbKeyboard): bool = k.ready and k.active(k.superIdx)

proc repeats*(k: XkbKeyboard; key: uint32): bool =
  ## The key repeats when held (letters, arrows; not Shift).
  if not k.ready or keymapRepeats == nil: return true
  keymapRepeats(k.h.keymap, key) != 0

proc compose*(k: var XkbKeyboard; sym: uint32; text: var string): cint =
  ## A keysym through dead keys and compose sequences: 0 nothing of theirs
  ## (`text` stays the key's), `XKB_COMPOSE_COMPOSING` (no text yet),
  ## `XKB_COMPOSE_COMPOSED` (`text` is what was composed),
  ## `XKB_COMPOSE_CANCELLED` (no text).
  let s = k.h.composeState
  if s == nil or composeFeed == nil or composeStatus == nil: return 0
  if composeFeed(s, sym) != XKB_COMPOSE_FEED_ACCEPTED: return 0
  result = composeStatus(s)
  case result
  of XKB_COMPOSE_COMPOSED:
    var buf: array[64, char]
    let n = composeUtf8(s, cast[cstring](addr buf[0]), buf.len.csize_t)
    text = ""
    for i in 0 ..< max(0, min(n.int, buf.len - 1)): text.add buf[i]
    composeReset(s)
  of XKB_COMPOSE_CANCELLED:
    text = ""
    composeReset(s)
  of XKB_COMPOSE_COMPOSING:
    text = ""
  else:
    result = 0

proc keymapText*(k: XkbKeyboard): string =
  ## The layout in XKB's text format (what a Wayland compositor sends; a
  ## virtual keyboard sends it the other way).
  if not k.ready or keymapAsString == nil: return ""
  let p = keymapAsString(k.h.keymap, XKB_KEYMAP_FORMAT_TEXT_V1)
  if p == nil: return ""
  result = $p
  proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}
  c_free(p)
