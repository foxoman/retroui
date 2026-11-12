## Retro Navigator: a web browser in the manner of 1995's -- the tool bar
## with its labels, the Location box, the directory buttons, a logo that
## moves while a page loads, the key in the status bar, bookmarks, the Go
## menu -- around the system's own engine (WebView2, WKWebView, WebKitGTK,
## Android's WebView), so today's web works in it: sign-ins, maps, video.
## Where the system has none it shows its own pages and opens the others in
## the browser.
##
##   nimble navigator     (or: nim c -r -d:release examples/navigator.nim;
##                         Linux and BSD: libwebkit2gtk-4.1 installed)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, json, math]
import retroui
import navigator/[places, pages]

const
  NavigatorVersion = "0.1.0"
  Key = "page"                                     # (the page's `webView`)
  IconPng = staticRead("assets/navigator-icon.png")
  Directory = [("&Welcome", "about:welcome"),
               ("What's &New", "https://github.com/foxoman/retroui/blob/main/CHANGELOG.md"),
               ("Net &Search", ""),                # (the search engine's home)
               ("Net &Directory", "https://www.wikipedia.org"),
               ("Hand&book", "about:handbook"),
               ("Soft&ware", "https://github.com/foxoman/retroui")]

var
  prefs = loadSettings(SettingsName)
  marks = bookmarks(prefs)
  session: seq[Place]                 # this session's pages, the last first (the Go menu)
  asked = homeOf(prefs)               # the address the page was given
  nextGo = ""                         # (given again next frame: see `go`)
  location = asked                    # the Location box
  locId: Id                           # (its id, from the frame before)
  typed = false                       # something was typed in it, not gone to yet
  trail: seq[string]                  # Retro Navigator's own pages before this one: the
                                      # engine keeps none of them to go back to
  shown = ""                          # the page shown, as the Location box says it
  title = ""
  loading = false
  progress = 100
  canBack, canForward = false
  native = true                       # the system's engine shows the pages
  zoom = 1.0
  status = ""
  showToolbar = prefs.getOrDefault("toolbar", "on") != "off"
  showLocation = prefs.getOrDefault("location", "on") != "off"
  showDirectory = prefs.getOrDefault("directory", "on") != "off"
  showAbout, showPrefs, showLook, showMarks, showSource, openDlg = false
  homeEdit = ""
  searchSel = searchOf(prefs)
  markSel = 0
  source = ""
  sourceAsk, findAsk = 0
  finder = FindState()
  picked = ""

proc pageFor(url: string): string =
  ## What the engine is given for `url`: Retro Navigator's own pages as their
  ## HTML.
  case url
  of "about:welcome": "html:" & welcomeHtml
  of "about:handbook": "html:" & handbookHtml
  else: url

proc go(url: string) =
  ## Shows `url` (an address, or "about:welcome" and "about:handbook").
  let u = url.strip
  if u.len == 0: return
  location = u
  typed = false
  status = ""
  if ui.focus == locId: ui.focus = 0
  if shown.startsWith("about:") and shown != "about:blank" and shown != u:
    trail.add shown
    if trail.len > 50: trail.delete(0)
  if pageFor(u) != pageFor(asked): asked = u
  elif shown == u: webReload(Key)               # (that page now: again)
  else:
    # (the engine went on from it: given again, through a blank page)
    asked = "about:blank"
    nextGo = u

proc goBack() =
  ## The page before: the engine's, else the last of Retro Navigator's own.
  if canBack: webGoBack(Key)
  elif trail.len > 0:
    let p = trail.pop()
    let n = trail.len
    go(p)
    trail.setLen(n)                           # (not this page on it again)

proc keepPrefs() =
  ## Keeps the preferences and the bookmarks (with the look the file holds).
  var s = loadSettings(SettingsName)
  s["toolbar"] = (if showToolbar: "on" else: "off")
  s["location"] = (if showLocation: "on" else: "off")
  s["directory"] = (if showDirectory: "on" else: "off")
  s["home"] = homeOf(prefs)
  s["search"] = $searchOf(prefs)
  s.setBookmarks(marks)
  saveSettings(SettingsName, s)
  prefs = s

proc addMark() =
  if shown.len == 0 or shown == "about:blank": return
  if marks.addBookmark(Place(title: (if title.len > 0: title else: shown), url: shown)):
    keepPrefs()
    status = "Bookmark added: " & (if title.len > 0: title else: shown)
  else: status = "This page is in the bookmarks already"

proc findInPage(backwards = false) =
  ## The next match of the find bar's text on the page (`window.find`).
  if finder.what.len == 0:
    finder.open = true
    return
  findAsk = webRun(Key, "window.find(" & $(%finder.what) & "," & $finder.matchCase & "," &
                        $backwards & ",true)")

proc setZoom(z: float) =
  zoom = clamp(round(z * 10) / 10, 0.5, 3.0)
  webZoom(Key, zoom)

proc logo(r: Rect; moving: bool) =
  ## Retro Navigator's logo, at the right of the tool bar: a planet with its
  ## ring in the night; while a page loads a comet goes round it and the
  ## stars twinkle. (The art is its own, drawn here.)
  let s = max(1, dp(1))
  fill(r, color(0, 0, 48))
  box(r, ui.theme.frame)
  const stars = [(0.14, 0.18), (0.82, 0.14), (0.30, 0.84), (0.88, 0.72), (0.56, 0.10),
                 (0.10, 0.62), (0.70, 0.88)]
  for i, (sx, sy) in stars:
    let lit = moving and (ui.now div 160 + i) mod 3 == 0
    fill(rect(r.x + int(sx * float(r.w)), r.y + int(sy * float(r.h)), s, s),
         if lit: color(255, 240, 128) else: color(200, 210, 255))
  let d = min(r.w, r.h) * 44 div 100
  let p = rect(r.x + (r.w - d) div 2, r.y + (r.h - d) div 2, d, d)
  roundRect(p, d / 2, color(0, 128, 192))
  let hd = max(2, d * 2 div 5)
  roundRect(rect(p.x + d div 5, p.y + d div 6, hd, hd), hd / 2, color(127, 212, 255))
  for k in 0 ..< s:
    line(p.x - d div 3, p.y + d * 2 div 3 + k, p.x + d + d div 3, p.y + d div 3 + k,
         color(255, 208, 64))
  # the comet: still at the top right, or going round
  let a = if moving: float(ui.now mod 1400) / 1400 * TAU else: -PI / 4
  let rx = float(r.w) * 0.38
  let ry = float(r.h) * 0.36
  let cx = float(r.x + r.w div 2)
  let cy = float(r.y + r.h div 2)
  for k in countdown(3, 1):
    let b = a - 0.22 * float(k)
    let fade = uint8(255 - k * 55)
    fill(rect(int(cx + cos(b) * rx), int(cy + sin(b) * ry), s, s), color(fade, fade, 160))
  fill(rect(int(cx + cos(a) * rx) - s, int(cy + sin(a) * ry) - s, 3 * s, 3 * s),
       color(255, 236, 140))
  if moving: wakeIn(60)

setToolbarLook(blTextBelow)

app "Retro Navigator", 900, 680, id = SettingsName, look = SettingsName, icon = IconPng:
  let wanted = (if title.len > 0: title & " - " else: "") & "Retro Navigator"
  if ui.title != wanted: setTitle(wanted)

  menubar:
    menu "&File":
      if menuItem("Open &Location...", "Ctrl+L"): ui.focus = locId
      if menuItem("&Open File...", "Ctrl+O"): openDlg = true
      menuSeparator()
      if menuItem("&Print...", "Ctrl+P", enabled = native): webPrint(Key)
      menuSeparator()
      if menuItem("E&xit"): quitApp()
    menu "&Edit":
      if menuItem("&Find...", "Ctrl+F"): finder.open = true
      if menuItem("Find A&gain", "F3", enabled = finder.what.len > 0): findInPage()
    menu "&View":
      if menuItem("&Reload", "F5"): webReload(Key)
      if menuItem("&Stop Loading", "Esc", enabled = loading): webStop(Key)
      menuSeparator()
      if menuItem("&Larger", enabled = native and zoom < 3.0): setZoom(zoom + 0.1)
      if menuItem("S&maller", enabled = native and zoom > 0.5): setZoom(zoom - 0.1)
      if menuItem("&Actual Size", enabled = zoom != 1.0): setZoom(1.0)
      menuSeparator()
      if menuItem("Document So&urce", enabled = native):
        sourceAsk = webRun(Key, "document.documentElement.outerHTML")
    menu "&Go":
      if menuItem("&Back", "Alt+Left", enabled = canBack or trail.len > 0): goBack()
      if menuItem("&Forward", "Alt+Right", enabled = canForward): webGoForward(Key)
      if menuItem("&Home", "Alt+Home"): go(homeOf(prefs))
      if menuItem("&Stop Loading", "Esc", enabled = loading): webStop(Key)
      if session.len > 0: menuSeparator()
      for i, p in session:
        let name = (if p.title.len > 0: p.title else: p.url).replace("&", "&&")
        if menuItem((if i < 10: "&" & $((i + 1) mod 10) & " " else: "") & name): go(p.url)
    menu "&Bookmarks":
      if menuItem("&Add Bookmark", "Ctrl+D", enabled = shown.len > 0): addMark()
      if menuItem("&View Bookmarks..."):
        markSel = 0
        showMarks = true
      if marks.len > 0: menuSeparator()
      for m in marks:
        if menuItem(m.title.replace("&", "&&")): go(m.url)
    menu "&Options":
      if menuItem("&General Preferences..."):
        homeEdit = homeOf(prefs)
        searchSel = searchOf(prefs)
        showPrefs = true
      if menuItem("&Appearance..."): showLook = true
      menuSeparator()
      if menuItem("Show &Toolbar", checked = showToolbar):
        showToolbar = not showToolbar
        keepPrefs()
      if menuItem("Show &Location", checked = showLocation):
        showLocation = not showLocation
        keepPrefs()
      if menuItem("Show &Directory Buttons", checked = showDirectory):
        showDirectory = not showDirectory
        keepPrefs()
    menu "&Directory":
      for (name, url) in Directory:
        if menuItem(name): go(if url.len > 0: url else: Searches[searchOf(prefs)][2])
    menu "&Help":
      if menuItem("&Handbook"): go("about:handbook")
      menuSeparator()
      if menuItem("&About Retro Navigator..."): showAbout = true

  if showToolbar:
    toolbar:
      if barButton(pxBack, "Back", "Back (Alt+Left)", enabled = canBack or trail.len > 0): goBack()
      if barButton(pxForward, "Forward", "Forward (Alt+Right)", enabled = canForward):
        webGoForward(Key)
      if barButton(pxHome, "Home", "Home (Alt+Home)"): go(homeOf(prefs))
      toolSeparator()
      if barButton(pxRefresh, "Reload", "Reload (F5)"): webReload(Key)
      if barButton(pxOpen, "Open", "Open a file (Ctrl+O)"): openDlg = true
      if barButton(pxPrint, "Print", "Print (Ctrl+P)", enabled = native): webPrint(Key)
      if barButton(pxSearch, "Find", "Find on this page (Ctrl+F)"): finder.open = true
      toolSeparator()
      if barButton(pxStop, "Stop", "Stop loading (Esc)", enabled = loading): webStop(Key)
      # the logo, at the right: it moves while a page loads; a click goes home
      let lw = CtrlH + FontH + dp(5) - 6
      if available() > lw + dp(8):
        space(available() - lw)
        let r = place(lw, lw)
        let hit = interact(idOf("logo"), r, focusable = false)
        if accessOn: accessNode(arButton, "Home", id = idOf("logo"), r = r)
        logo(r, loading)
        if hit.hover and canHover(): ui.tip = "Home"
        if hit.clicked: go(homeOf(prefs))

  if showLocation:
    row([dp(76), -1]):
      label "&Location:"
      if edit(location): typed = true
      locId = ui.lastId
    if ui.focus == locId and keyHit(KeyEnter):
      go(locationUrl(location, Searches[searchOf(prefs)][1]))
    elif ui.focus == locId and typed and keyHit(KeyEsc):
      location = shown                       # (Esc: what was typed let go)
      typed = false
  if showDirectory and not isCompact():
    row:
      for (name, url) in Directory:
        if button(name): go(if url.len > 0: url else: Searches[searchOf(prefs)][2])

  let fe = findBar(finder)
  if fe.next: findInPage()
  if fe.prev: findInPage(backwards = true)

  # the status bar: what happens, the key (whole: https), how much is loaded
  statusbar((if status.len > 0: status
             elif loading: "Loading " & (if shown.len > 0: shown else: asked) & "..."
             elif not native: "No web engine here: pages on the web open in your browser"
             else: "Document: Done"),
            (if isSecure(shown): pxKey & " Secure" else: pxWarning & " Not secure"),
            (if loading: $progress & "%" else: "Ready"))

  # the page
  let ev = webView(pageFor(asked), key = Key, engine = weSystem)
  if nextGo.len > 0 and asked == "about:blank":
    asked = nextGo
    nextGo = ""
  native = ev.native
  loading = ev.loading
  progress = ev.progress
  canBack = ev.canGoBack
  canForward = ev.canGoForward
  title = ev.title
  # (our own pages and the blank one in between: the address they were asked by)
  let now = if ev.url.len == 0 or ev.url.startsWith("html:") or ev.url == "about:blank" or
               ev.url.startsWith("data:text/html"): asked
            else: ev.url
  if now != shown:
    shown = now
    if not typed: location = shown
  if not loading and shown.len > 0 and shown != "about:blank" and
     (session.len == 0 or session[0].url != shown or session[0].title != title):
    session.visit(Place(title: title, url: shown))
  if ev.link.len > 0: go(ev.link)              # (a link in a page the kit shows itself)
  if ev.opened: status = "Opened in your browser: " & asked
  if ev.back: quitApp()                        # (Android's Back with no page before)
  for d in ev.downloads:
    let name = if d.file.len > 0: d.file.extractFilename else: d.url
    status = if d.failed: "Download failed: " & name
             elif d.done: "Saved in Downloads: " & name
             else: "Downloading " & name & " " & $d.progress & "%"
  for r in ev.results:
    if r.id == sourceAsk:
      try: source = parseJson(r.value).getStr
      except CatchableError: source = r.error
      showSource = true
    elif r.id == findAsk:
      status = if r.value == "true": "" else: "Cannot find \"" & finder.what & "\""

  # the keys (while the page has the keyboard, its own come first)
  if hotkeyPressed("Ctrl+L"):
    ui.focus = locId
    var st = state(locId)
    st.anchor = 0
    st.caret = location.len
    state(locId) = st
  if hotkeyPressed("Alt+Left"): goBack()
  if hotkeyPressed("Alt+Right"): webGoForward(Key)
  if hotkeyPressed("Alt+Home"): go(homeOf(prefs))
  if hotkeyPressed("F5"): webReload(Key)
  if loading and hotkeyPressed("Esc"): webStop(Key)
  if hotkeyPressed("Ctrl+D"): addMark()
  if hotkeyPressed("Ctrl+F"): finder.open = true
  if hotkeyPressed("F3"): findInPage(ShiftPressed in ui.mods)
  if hotkeyPressed("Ctrl+O"): openDlg = true
  if hotkeyPressed("Ctrl+P") and native: webPrint(Key)

  if filePicker(openDlg, picked, fmOpen, ["*.html", "*.htm", "*.svg", "*.txt", "*.pdf", "*"],
                "Open File"):
    go(locationUrl(picked))

  dialog(showMarks, "Bookmarks", 460):
    var names: seq[string]
    for m in marks: names.add m.title & "  --  " & m.url
    listbox(names, markSel, rows = 10)
    row:
      spring()
      if button("&Go To", isDefault = true, enabled = marks.len > 0):
        showMarks = false
        go(marks[clamp(markSel, 0, marks.high)].url)
      if button("&Remove", enabled = marks.len > 0):
        marks.delete(clamp(markSel, 0, marks.high))
        markSel = clamp(markSel, 0, max(0, marks.high))
        keepPrefs()
      if button("Close"): showMarks = false

  dialog(showPrefs, "General Preferences", 480):
    form dp(110):
      field "&Home page:":
        row([-1, 0]):
          edit homeEdit
          if button("Use &Current", enabled = shown.len > 0): homeEdit = shown
      field "&Search with:":
        var names: seq[string]
        for (name, _, _) in Searches: names.add name
        combo(names, searchSel)
    row:
      spring()
      if button("OK", isDefault = true):
        prefs["home"] = (if homeEdit.strip.len > 0: homeEdit.strip else: "about:welcome")
        prefs["search"] = $searchSel
        keepPrefs()
        showPrefs = false
      if button("Cancel"): showPrefs = false

  dialog(showLook, "Appearance", 480):
    appearanceSettings()
    row:
      spring()
      if button("Close", isDefault = true): showLook = false

  dialog(showSource, "Document Source", 640):
    label shown
    editArea(source, lines = 18, wrap = false, readOnly = true)
    row:
      spring()
      if button("Close", isDefault = true): showSource = false

  aboutBox(showAbout, "Retro Navigator", NavigatorVersion,
           ["A web browser in the manner of 1995's, made with Retro Nim UI.",
            "The pages are drawn by the system's own engine."],
           tagline = "A web browser", iconPng = IconPng,
           url = "https://github.com/foxoman/retroui")
