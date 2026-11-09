## Platform services for apps: a folder for the app's files, small saved
## settings, opening links, and what kind of device this is.

import std/[os, tables, strutils, osproc]
import uirelays/target   # (androidApp: an APK, not a program in Termux)
import uirelays/[services, input]
import core, gfx
from ttf import sfntOf

export services.dataDir, services.openUrl, services.platformName,
       services.openFile, services.shareFile, services.places,
       services.storageAccess, services.requestStorageAccess,
       services.minimizeApp
export input.getClipboardText, input.putClipboardText
export tables   # (Settings is a table: len, hasKey, [], []=, pairs...)

proc isMobile*(): bool =
  ## A phone or tablet (touch screen, back button, on-screen keyboard).
  ui.touch or platformName() in ["android", "ios"]

type Settings* = OrderedTable[string, string]

proc settingsFiles(app: string): tuple[file, before: string] =
  ## Where `app`'s settings are kept, and where they were before ("": the
  ## same place). A phone gives every name the app's one folder: there each
  ## name has a file of its own -- the app's settings and its look's are two
  ## -- and the one they all shared before is read until that is written.
  let dir = dataDir(app)
  if app.len > 0 and dir == dataDir(""):
    let name = folderName(app).multiReplace(("/", "_"), ("\\", "_"))
    (dir / "settings" / (name & ".ini"), dir / "settings.ini")
  else:
    (dir / "settings.ini", "")

proc unescape(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      result.add(if s[i+1] == 'n': '\n' else: s[i+1])
      i += 2
    else:
      result.add s[i]
      inc i

proc loadSettings*(app: string): Settings =
  ## The settings `saveSettings` stored for `app` (empty the first time).
  let (file, before) = settingsFiles(app)
  let path = if before.len > 0 and not fileExists(file) and fileExists(before): before
             else: file
  try:
    for line in lines(path):
      var k = 0
      while k < line.len and line[k] != '=':
        if line[k] == '\\': inc k
        inc k
      if k > 0 and k < line.len:
        result[unescape(line[0 ..< k])] = unescape(line[k+1 .. ^1])
  except IOError, OSError:
    discard

proc saveSettings*(app: string; s: Settings): bool {.discardable.} =
  ## Store `s` in the app's data folder; written to a temporary file and
  ## moved into place, so a crash never leaves half a file. False when it
  ## could not be written (a full disk): the app goes on.
  var text = ""
  for k, v in s:
    text.add k.multiReplace(("\\", "\\\\"), ("=", "\\="), ("\n", "\\n"))
    text.add '='
    text.add v.multiReplace(("\\", "\\\\"), ("\n", "\\n"))
    text.add '\n'
  let f = settingsFiles(app).file
  try:
    createDir(f.parentDir)
    writeFile(f & ".tmp", text)
    moveFile(f & ".tmp", f)
    result = true
  except IOError, OSError:
    result = false

proc get*(s: Settings; key: string; default = ""): string =
  ## A setting (`default` when it is not set).
  s.getOrDefault(key, default)

proc getInt*(s: Settings; key: string; default = 0): int =
  ## A setting as a number (`default` when it is not set or not a number).
  try: parseInt(s.getOrDefault(key, $default)) except ValueError: default

proc getBool*(s: Settings; key: string; default = false): bool =
  ## A setting as true or false (`default` when it is not set).
  s.getOrDefault(key, $default) == "true"

proc put*(s: var Settings; key: string; value: string) = s[key] = value
  ## Set a setting (`saveSettings` stores them).
proc put*(s: var Settings; key: string; value: int | bool) = s[key] = $value
  ## Set a setting (`saveSettings` stores them).

var uiFontPath* = ""
  ## The file of the UI's font when it is one of the user's (`loadUiFontFile`).

proc styleBeside*(path: string; bold, italic: bool): string =
  ## Another style of a font file, when it lies beside it ("X-Regular.ttf":
  ## "X-Bold.ttf", "X-Italic.ttf", "X-BoldItalic.ttf"; "X.ttf": "XBold.ttf",
  ## "X Bold.ttf"...; Windows' "arial.ttf": "arialbd.ttf", "ariali.ttf",
  ## "arialbi.ttf"); "" when there is none.
  let (dir, name, ext) = path.splitFile
  # (the path's own separator: building for Windows elsewhere, `/` would be `\`)
  let sep = if '/' in path: "/" else: $DirSep
  var stems: seq[string]
  for sfx in ["-Regular", " Regular", "_Regular", "Regular", "-Roman", "-Book"]:
    if name.endsWith(sfx): stems.add name[0 ..< name.len - sfx.len]
  stems.add name
  let sfxs = if bold and italic: @["-BoldItalic", "-BoldOblique", " Bold Italic", "_BoldItalic", "BoldItalic",
                                   "BoldOblique", "bi", "z"]
             elif bold: @["-Bold", " Bold", "_Bold", "Bold", "bd", "b", "-bold"]
             elif italic: @["-Italic", "-Oblique", " Italic", "_Italic", "Italic", "Oblique", "i", "-italic"]
             else: @[]
  for st in stems:
    for b in sfxs:
      let p = dir & sep & st & b & ext
      if p != path and fileExists(p): return p
  ""

proc boldBeside*(path: string): string = styleBeside(path, true, false)
  ## The bold of a font file, when it lies beside it ("X-Regular.ttf":
  ## "X-Bold.ttf", "X.ttf": "XBold.ttf", "X-Bold.ttf", "X Bold.ttf").

const
  appFontPath {.strdefine: "retroAppFont".} = ""
    ## a font built into the app (`-d:retroAppFont=path/X-Regular.ttf`,
    ## its bold beside it): the app's own, read at build time
  appFontBoldPath {.strdefine: "retroAppFontBold".} = ""
    ## its bold, when it is not beside it
  appFontBoldFile = (when appFontBoldPath.len > 0: appFontBoldPath
                     elif appFontPath.len > 0: boldBeside(appFontPath)
                     else: "")
  appFontItalicFile = (when appFontPath.len > 0: styleBeside(appFontPath, false, true) else: "")
  appFontBoldItalicFile = (when appFontPath.len > 0: styleBeside(appFontPath, true, true) else: "")
  appFontRegular = (when appFontPath.len > 0: staticRead(appFontPath) else: "")
  appFontBold = (when appFontBoldFile.len > 0: staticRead(appFontBoldFile) else: "")
  appFontItalic = (when appFontItalicFile.len > 0: staticRead(appFontItalicFile) else: "")
  appFontBoldItalic = (when appFontBoldItalicFile.len > 0: staticRead(appFontBoldItalicFile) else: "")
  appFontKey* = "builtin:" & (when appFontPath.len > 0: appFontPath.splitFile.name else: "")
    ## what `uiFontPath` says while the app's own font is the UI's

proc hasAppFont*(): bool = appFontRegular.len > 0
  ## The app was built with a font of its own (`-d:retroAppFont`).

proc loadUiFontFile*(path: string) =
  ## The font in `path` (a .ttf, or the first face of a .ttc; its bold,
  ## italic and bold italic beside it, when there are) as the UI's font
  ## (`ufFile`); `appFontKey`: the app's own font, built in. Raises
  ## `IOError` or `FontError`.
  if path == appFontKey and hasAppFont():
    setUiFontFile(appFontRegular, appFontBold, appFontItalic, appFontBoldItalic)
  else:
    proc styleFile(bold, italic: bool): string =
      let p = styleBeside(path, bold, italic)
      if p.len > 0: sfntOf(readFile(p), 0) else: ""
    setUiFontFile(sfntOf(readFile(path), 0), styleFile(true, false), styleFile(false, true),
                  styleFile(true, true))
  uiFontPath = path

proc useAppFont*() =
  ## The app's own font (built in with `-d:retroAppFont`) as the UI's;
  ## nothing when there is none. Apps built so start with it (until the
  ## user chooses another in `appearanceSettings`).
  if hasAppFont():
    try: loadUiFontFile(appFontKey)
    except CatchableError: discard

proc uiFontKey*(f: UiFont): string =
  ## The word settings keep font `f` as: "sans", "serif", "mono", "file"
  ## (what `storeAppearance` writes; `uiFontOfKey` reads it back).
  case f
  of ufSans: "sans"
  of ufSerif: "serif"
  of ufMono: "mono"
  of ufFile: "file"

proc uiFontOfKey*(key: string; f: var UiFont): bool =
  ## The font `key` names (a word of `uiFontKey`, or one of before: "w98",
  ## "retro", "smooth" and "opensans" are FreeSans now, "kawkab" and
  ## "fixedsys" FreeMono), into `f`; false for an unknown word or "file" (a
  ## font from a file: `loadUiFontFile`).
  case key
  of "sans", "w98", "retro", "smooth", "opensans": f = ufSans
  of "serif": f = ufSerif
  of "mono", "kawkab", "fixedsys": f = ufMono
  of "system": f = ufSans            # (the system's font, offered for a while: FreeSans)
  else: return false
  true

proc recentFiles*(s: Settings; key = "recent"): seq[string] =
  ## The files last opened (or saved), the newest first (`addRecentFile`).
  for i in 1 .. 100:
    let p = s.getOrDefault(key & "." & $i, "")
    if p.len == 0: break
    result.add p

proc addRecentFile*(s: var Settings; path: string; keep = 10; key = "recent") =
  ## `path` first in the list of recent files (once), keeping `keep` (0:
  ## the list is cleared). Store `s` with `saveSettings`.
  var l = recentFiles(s, key)
  let i = l.find(path)
  if i >= 0: l.delete(i)
  if path.len > 0: l.insert(path, 0)
  if l.len > keep: l.setLen(max(0, keep))
  for i in 1 .. 100: s.del(key & "." & $i)
  for i, p in l: s[key & "." & $(i + 1)] = p

proc storeAppearance*(s: var Settings) =
  ## Puts the look the user chose (colors, sizes, font, the window's frame)
  ## into `s`.
  let t = themeIndex()
  if t >= 0: s["look.colors"] = $t
  s["look.size"] = $uiScale()
  s["look.text"] = $textScale()
  s["look.smooth"] = $smoothScrolling
  s["look.controls"] = (case controlSizes()
                        of csAuto: "auto"
                        of csDesktop: "desktop"
                        of csTouch: "touch")
  s["look.hdtext"] = $hdText()
  s["look.icons"] = (case iconStyle()
                     of isAuto: "auto"
                     of isPixel: "pixel"
                     of isLine: "line")
  s["look.gpu"] = (case gpuMode()
                   of gmAuto: "auto"
                   of gmGpu: "gpu"
                   of gmCpu: "cpu")
  s["look.font"] = uiFontKey(uiFont())
  s["look.fontv"] = "3"
  if uiFontPath.len > 0: s["look.fontfile"] = uiFontPath
  # (the text's edges kept only when not the system's choice)
  if subpixelText() != systemSubpixelText():
    s["look.textedges"] = (if subpixelText(): "sharp" else: "smooth")
  else: s.del("look.textedges")
  # (the window's frame is kept by the toolkit itself, for every app:
  # `chooseClassicFrame`; the key stores of before held it)
  s.del("look.frame")

proc restoreAppearance*(s: Settings) =
  ## Brings back the look `storeAppearance` stored.
  let t = s.getInt("look.colors", -1)
  if t in 0 .. builtinThemes.high:
    ui.theme = builtinThemes[t].theme
    invalidate()
  themeFromEnv()
  # ($RETRO_SCALE, when set, wins over what was kept -- as $RETRO_THEME does)
  if s.hasKey("look.size") and not existsEnv("RETRO_SCALE"): setUiScale(s.getInt("look.size", 100))
  if s.hasKey("look.text"): setTextScale(s.getInt("look.text", 100))
  if s.hasKey("look.smooth"): setSmoothScrolling(s.getBool("look.smooth", true))
  if not existsEnv("RETRO_TEXT"):
    case s.getOrDefault("look.textedges", "")
    of "sharp": setSubpixelText(true)
    of "smooth": setSubpixelText(false)
    else: discard
  # ($RETRO_CONTROLS and $RETRO_TOUCH, when set, win over what was kept)
  case (if sizesFromEnv().len > 0: "" else: s.getOrDefault("look.controls", ""))
  of "auto": setControlSizes(csAuto)
  of "desktop": setControlSizes(csDesktop)
  of "touch": setControlSizes(csTouch)
  else: discard
  if s.hasKey("look.hdtext"): setHdText(s.getBool("look.hdtext", true))
  case s.getOrDefault("look.icons", "")
  of "pixel": setIconStyle(isPixel)
  of "line": setIconStyle(isLine)
  of "auto": setIconStyle(isAuto)
  else: discard
  # ($RETRO_GPU, when set, wins over what was kept)
  case (if existsEnv("RETRO_GPU"): "" else: s.getOrDefault("look.gpu", ""))
  of "auto": setGpuMode(gmAuto)
  of "gpu": setGpuMode(gmGpu)
  of "cpu": setGpuMode(gmCpu)
  else: discard
  # (the frame a store of before kept: the user's choice, kept from now on
  # by the toolkit -- unless one was made since; $RETRO_FRAME wins)
  if not existsEnv("RETRO_FRAME") and keptFrame().len == 0:
    case s.getOrDefault("look.frame", "")
    of "classic": chooseClassicFrame(true)
    of "system": chooseClassicFrame(false)
    else: discard
  # (stored before FreeFont -- "look.fontv" under 3 -- a built-in font was
  # one of the old ones, gone now: the default again, FreeSans; a font from
  # a file stays one)
  let font = s.getOrDefault("look.font", "")
  let current = s.getInt("look.fontv", 0) >= 3
  var uf: UiFont
  if font == "file":
    # (the font from a file: when it is still there)
    let p = s.getOrDefault("look.fontfile", "")
    if (p.len > 0 and fileExists(p)) or (p == appFontKey and hasAppFont()):
      try: loadUiFontFile(p)
      except CatchableError: discard
  elif font.len == 0 or not current:
    setUiFont(ufSans)
    if font.len == 0: useAppFont()      # (nothing chosen yet: the app's own font, when it has one)
  elif uiFontOfKey(font, uf):
    setUiFont(uf)

proc canOpenTerminal*(): bool =
  ## `openTerminal` can work here (a desktop).
  when androidApp or defined(ios): false else: true

proc openTerminal*(dir: string): bool {.discardable.} =
  ## Opens a terminal window in the folder `dir` (the system's own: on
  ## Linux $TERMINAL or the first of the usual ones there; Windows
  ## Terminal or the command prompt; macOS's Terminal). False when none
  ## could be started.
  when androidApp or defined(ios):
    false
  else:
    proc start(exe: string; args: openArray[string]): bool =
      try:
        let p = startProcess(exe, workingDir = dir, args = args, options = {poUsePath, poDaemon})
        p.close()
        true
      except OSError: false
    when defined(windows):
      if findExe("wt").len > 0 and start("wt", ["-d", dir]): return true
      start("cmd.exe", ["/c", "start", "cmd.exe", "/K", "cd /d \"" & dir & "\""])
    elif defined(macosx):
      start("open", ["-a", "Terminal", dir])
    else:
      var tried: seq[string]
      let own = getEnv("TERMINAL")
      if own.len > 0: tried.add own
      tried.add ["x-terminal-emulator", "gnome-terminal", "konsole", "xfce4-terminal",
                 "kitty", "alacritty", "wezterm", "foot", "tilix", "mate-terminal",
                 "lxterminal", "terminator", "xterm"]
      for t in tried:
        if findExe(t).len > 0:
          # (each starts in the working folder; gnome-terminal and konsole are told too)
          let args = case t
                     of "gnome-terminal", "mate-terminal", "xfce4-terminal", "tilix":
                       @["--working-directory=" & dir]
                     of "konsole": @["--workdir", dir]
                     else: @[]
          if start(t, args): return true
      false
