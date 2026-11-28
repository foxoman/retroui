## A Mac app's menus in the system's menu bar at the top of the screen, as Mac apps have them:
## the app's `menubar` is walked each frame (not drawn: the window has no bar of its own) and
## the system's built from it -- its menus and submenus, lines, check marks, grayed items, key
## equivalents (Ctrl+S as Command-S) -- between the app's own menu and Window. Choosing one is
## as a click on it in the window. `macMenuBar = false` keeps the bar in the window. Nothing on
## other systems.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

var macMenuBar* = true
  ## On a Mac, the menu bar's menus in the system's menu bar (false: in the window, as elsewhere).

when defined(macosx) and not defined(ios):
  import std/[hashes, strutils]
  import core, widgets, commandhud, native

  var
    built: Hash = Hash(-1)
    paths: seq[seq[string]]         # (each item's path, by its tag)
    inserted: seq[ObjcId]           # (the menu bar's items made: taken out before the next)
    target: ObjcId

  proc onPick(self: ObjcId; cmd: ObjcSel; sender: ObjcId) {.cdecl.} =
    let tag = objcSend(int, sender, "tag")
    if tag >= 0 and tag < paths.len: pickMenuCommand(paths[tag])

  proc objc_allocateClassPair(super: pointer; name: cstring; extra: int): pointer {.importc, cdecl.}
  proc objc_registerClassPair(cls: pointer) {.importc, cdecl.}
  proc class_addMethod(cls, name, imp: pointer; types: cstring): bool {.importc, cdecl.}

  proc app(): ObjcId = objcSend(ObjcId, objcClass("NSApplication"), "sharedApplication")

  proc keyOf(keys: string): tuple[key: string; mods: uint] =
    ## ("Ctrl+Shift+S": "s" with Command and Shift; keys a menu can't show: none)
    if keys.len == 0: return
    let parts = keys.split('+')
    let k = parts[^1].strip
    for p in parts[0 ..< parts.high]:
      case p.strip.toLowerAscii
      of "ctrl", "cmd", "command": result.mods = result.mods or (1'u shl 20)
      of "shift": result.mods = result.mods or (1'u shl 17)
      of "alt", "option": result.mods = result.mods or (1'u shl 19)
      else: discard
    if k.len == 1: result.key = k.toLowerAscii
    if result.key.len == 0: result.mods = 0     # (Del, F5...: not shown on the menu)

  proc nsMenu(title: string): ObjcId =
    result = objcSend(ObjcId, objcSend(ObjcId, objcClass("NSMenu"), "alloc"), "initWithTitle:", nsString(title))
    objcSend(void, result, "setAutoenablesItems:", false)

  proc nsTitle(label: string): string =
    ## (Windows' "&" before the access key left out; "..." as the one character)
    var s = splitMnemonic(label).text
    if s.endsWith("..."): s = s[0 ..< s.len - 3] & "…"
    s

  proc build() =
    var h: Hash = 0
    for c in menuWalked:
      h = h !& hash(c.path) !& hash(c.keys) !& hash(c.enabled) !& hash(c.checked)
    h = !$h
    if h == built: return
    built = h
    autoreleasePool:
      let main = objcSend(ObjcId, app(), "mainMenu")
      if main == nil: return
      if target == nil:
        var cls = cast[pointer](objcClass("RetroMenuTarget"))
        if cls == nil:
          cls = objc_allocateClassPair(cast[pointer](objcClass("NSObject")), "RetroMenuTarget", 0)
          discard class_addMethod(cls, cast[pointer](sel("pick:")), cast[pointer](onPick), "v@:@")
          objc_registerClassPair(cls)
        target = objcSend(ObjcId, objcSend(ObjcId, cast[ObjcId](cls), "alloc"), "init")
      for it in inserted: objcSend(void, main, "removeItem:", it)
      inserted.setLen(0)
      paths.setLen(0)
      var stack: seq[ObjcId]          # (the menu open at each depth)
      var at = 1                      # (after the app's own menu)
      for c in menuWalked:
        if c.path.len == 0: continue
        let last = c.path[^1]
        if last == "\x01":
          # (a menu or a submenu starts: its title, at depth path.len - 1)
          let depth = c.path.len - 1
          stack.setLen(max(0, depth - 1))
          let m = nsMenu(nsTitle(c.path[^2]))
          let item = objcSend(ObjcId, objcSend(ObjcId, objcClass("NSMenuItem"), "alloc"),
                              "initWithTitle:action:keyEquivalent:", nsString(nsTitle(c.path[^2])), nil, nsString(""))
          objcSend(void, item, "setSubmenu:", m)
          if depth == 1:
            objcSend(void, main, "insertItem:atIndex:", item, at)
            inc at
            inserted.add item
          elif stack.len > 0:
            objcSend(void, stack[^1], "addItem:", item)
          stack.add m
        elif last == "-":
          let depth = c.path.len - 1
          if depth >= 1 and depth <= stack.len:
            objcSend(void, stack[depth - 1], "addItem:", objcSend(ObjcId, objcClass("NSMenuItem"), "separatorItem"))
        else:
          let depth = c.path.len - 1
          if depth < 1 or depth > stack.len: continue
          let (key, mods) = keyOf(c.keys)
          let item = objcSend(ObjcId, objcSend(ObjcId, objcClass("NSMenuItem"), "alloc"),
                              "initWithTitle:action:keyEquivalent:", nsString(nsTitle(last)), sel("pick:"),
                              nsString(key))
          if key.len > 0: objcSend(void, item, "setKeyEquivalentModifierMask:", mods)
          objcSend(void, item, "setTarget:", target)
          objcSend(void, item, "setTag:", paths.len)
          objcSend(void, item, "setEnabled:", c.enabled)
          if c.checked: objcSend(void, item, "setState:", 1)
          objcSend(void, stack[depth - 1], "addItem:", item)
          paths.add c.path

  proc systemBarUp(): bool {.nimcall.} =
    macMenuBar and (try: objcSend(ObjcId, app(), "mainMenu") != nil except CatchableError: false)

  menuBarElsewhere = systemBarUp
  menuMirror = build
