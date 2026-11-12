## Retro Navigator: a web browser in the manner of 1995's -- the tool bar
## with its labels, the Location box, the directory buttons, a logo that
## moves while a page loads, the key in the status bar, bookmarks, the Go
## menu -- around the system's own engine (WebView2, WKWebView, WebKitGTK,
## Android's WebView), so today's web works in it: sign-ins, maps, video.
## And what a browser has now: tabs (shown when there are two), ads and
## trackers blocked, secure connections, links loaded ahead, tabs that
## sleep, browsing data cleared. Where the system has no engine it shows its
## own pages and opens the others in the browser.
##
##   nimble navigator     (or: nim c -r -d:release examples/navigator.nim;
##                         Linux and BSD: libwebkit2gtk-4.1 installed)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, json, math]
import retroui
import navigator/[places, pages]

const
  NavigatorVersion = "0.2.0"
  SleepAfter = 10 * 60_000                         # a tab not seen this long sleeps (ms)
  IconPng = staticRead("assets/navigator-icon.png")
  Directory = [("&Welcome", "about:welcome"),
               ("What's &New", "https://github.com/foxoman/retroui/blob/main/CHANGELOG.md"),
               ("Net &Search", ""),                # (the search engine's home)
               ("Net &Directory", "https://www.wikipedia.org"),
               ("Hand&book", "about:handbook"),
               ("Soft&ware", "https://github.com/foxoman/retroui")]

type
  Tab = object
    ## A tab: a page and its own `webView`.
    key: string                       # its `webView`'s
    asked: string                     # the address the page was given
    nextGo: string                    # (given again next frame: see `go`)
    location: string                  # the Location box, while it is shown
    typed: bool                       # something was typed in it, not gone to yet
    trail: seq[string]                # Retro Navigator's own pages before this one: the
                                      # engine keeps none of them to go back to
    shown, title: string              # the page shown, as the Location box says it
    loading: bool
    progress: int
    canBack, canForward: bool
    zoom: float
    blocked: int                      # ads and trackers kept off this page
    seen: int                         # (`ui.now` it was last shown)
    asleep: bool                      # its view was let go (`sleepTabs`)

var
  prefs = loadSettings(SettingsName)
  marks = bookmarks(prefs)
  session: seq[Place]                 # this session's pages, the last first (the Go menu)
  tabList: seq[Tab]
  cur = 0                             # the tab shown
  lastCur = -1
  made = 0                            # (tabs made: their keys)
  closedTabs: seq[string]             # the pages of the tabs closed, the last last
  menuTab = 0                         # (the tab whose menu is open)
  locId: Id                           # (the Location box's id, from the frame before)
  native = true                       # the system's engine shows the pages
  status = ""
  shields = shieldsOf(prefs)
  shieldJs = ""                       # (the script the tabs were made with)
  sleepTabs = prefs.getOrDefault("sleepTabs", "off") == "on"
  showToolbar = prefs.getOrDefault("toolbar", "on") != "off"
  showLocation = prefs.getOrDefault("location", "on") != "off"
  showDirectory = prefs.getOrDefault("directory", "on") != "off"
  showAbout, showPrefs, showMarks, showSource, showClear, openDlg = false
  prefTab = 0                         # Preferences: General, Appearance, Security, Network
  homeEdit = ""
  searchSel = searchOf(prefs)
  shieldEdit = shields
  sleepEdit = sleepTabs
  allowedEdit: seq[string]
  allowedSel = 0
  clearPages, clearSites = true
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

template t: untyped = tabList[cur]

proc go(t: var Tab; url: string; secure = true) =
  ## Shows `url` in `t` (an address, or "about:welcome" and "about:handbook");
  ## over https when the shield asks for it (`secure`: an address typed with
  ## "http://" is not).
  var u = url.strip
  if u.len == 0: return
  if secure and shHttps in shields: u = secureUrl(u)
  t.location = u
  t.typed = false
  status = ""
  if ui.focus == locId: ui.focus = 0
  if t.shown.startsWith("about:") and t.shown != "about:blank" and t.shown != u:
    t.trail.add t.shown
    if t.trail.len > 50: t.trail.delete(0)
  if pageFor(u) != pageFor(t.asked): t.asked = u
  elif t.shown == u: webReload(t.key)           # (that page now: again)
  else:
    # (the engine went on from it: given again, through a blank page)
    t.asked = "about:blank"
    t.nextGo = u

proc goBack(t: var Tab) =
  ## The page before: the engine's, else the last of Retro Navigator's own.
  if t.canBack: webGoBack(t.key)
  elif t.trail.len > 0:
    let p = t.trail.pop()
    let n = t.trail.len
    t.go(p)
    t.trail.setLen(n)                         # (not this page on it again)

proc newTab(url: string; behind = false) =
  ## A tab at the end with `url`, shown (or not: `behind`; it loads when it
  ## is first shown).
  inc made
  var n = Tab(key: "page" & $made, zoom: 1.0, progress: 100, seen: ui.now)
  webStartScript(n.key, shieldJs)
  n.go(url)
  tabList.add n
  if not behind: cur = tabList.high

proc remake(t: var Tab) =
  ## Lets `t`'s view go: it is made again with the page it showed when it is
  ## next shown (with the shield's script then; its Back is lost).
  if t.shown.len > 0 and t.shown != "about:blank":
    t.asked = t.shown
    t.nextGo = ""
  webClose(t.key)
  t.loading = false
  t.canBack = false
  t.canForward = false
  if t.zoom != 1.0: webZoom(t.key, t.zoom)

proc applyShields() =
  ## The shield's script for every tab: those made with another one are
  ## made again.
  let js = startScript(shields, adsAllowedOf(prefs))
  if js == shieldJs: return
  let first = shieldJs.len == 0
  shieldJs = js
  for x in tabList.mitems:
    if not first: x.remake()
    webStartScript(x.key, js)

proc closeTab(i: int) =
  ## Closes tab `i` (not the last one).
  if tabList.len < 2 or i notin 0 .. tabList.high: return
  let gone = tabList[i]
  if gone.shown.len > 0 and gone.shown != "about:blank":
    closedTabs.add gone.shown
    if closedTabs.len > 20: closedTabs.delete(0)
  webClose(gone.key)
  webStartScript(gone.key, "")
  tabList.delete(i)
  if i < cur or cur > tabList.high: dec cur

proc tabName(x: Tab): string =
  ## A tab's label: its page's title, else its host.
  let u = if x.shown.len > 0 and x.shown != "about:blank": x.shown else: x.asked
  if x.title.len > 0: x.title
  elif x.loading and x.shown.len == 0: "Loading..."
  elif hostOf(u).len > 0: hostOf(u)
  elif u.len > 0 and u != "about:blank": u
  else: "New Tab"

proc keepPrefs() =
  ## Keeps the preferences and the bookmarks (with the look the file holds).
  var s = loadSettings(SettingsName)
  s["toolbar"] = (if showToolbar: "on" else: "off")
  s["location"] = (if showLocation: "on" else: "off")
  s["directory"] = (if showDirectory: "on" else: "off")
  s["home"] = homeOf(prefs)
  s["search"] = $searchOf(prefs)
  s.setShields(shields)
  s["sleepTabs"] = (if sleepTabs: "on" else: "off")
  s["adsAllowed"] = adsAllowedOf(prefs).join(" ")
  s.setBookmarks(marks)
  saveSettings(SettingsName, s)
  prefs = s

proc addMark() =
  if t.shown.len == 0 or t.shown == "about:blank": return
  let name = if t.title.len > 0: t.title else: t.shown
  if marks.addBookmark(Place(title: name, url: t.shown)):
    keepPrefs()
    status = "Bookmark added: " & name
  else: status = "This page is in the bookmarks already"

proc findInPage(backwards = false) =
  ## The next match of the find bar's text on the page (`window.find`).
  if finder.what.len == 0:
    finder.open = true
    return
  findAsk = webRun(t.key, "window.find(" & $(%finder.what) & "," & $finder.matchCase & "," &
                          $backwards & ",true)")

proc setZoom(z: float) =
  t.zoom = clamp(round(z * 10) / 10, 0.5, 3.0)
  webZoom(t.key, t.zoom)

proc openPrefs(tab: int) =
  ## Preferences, at its tab `tab`.
  homeEdit = homeOf(prefs)
  searchSel = searchOf(prefs)
  shieldEdit = shields
  sleepEdit = sleepTabs
  allowedEdit = adsAllowedOf(prefs)
  allowedSel = 0
  prefTab = tab
  showPrefs = true

proc shieldBox(label: string; x: Shield) =
  ## A check box for what the shield does, in Preferences.
  var on = x in shieldEdit
  if checkbox(label, on):
    if on: shieldEdit.incl x else: shieldEdit.excl x

proc clearData() =
  ## Clear Browsing Data: the pages visited (and every tab's Back), and what
  ## sites keep.
  if clearPages:
    session.setLen(0)
    closedTabs.setLen(0)
    for x in tabList.mitems:
      x.trail.setLen(0)
      x.remake()
  if clearSites: webClearData()
  status = "Browsing data cleared"

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
applyShields()

app "Retro Navigator", 900, 680, id = SettingsName, look = SettingsName, icon = IconPng:
  if tabList.len == 0: newTab(homeOf(prefs))
  cur = clamp(cur, 0, tabList.high)
  if cur != lastCur:                         # (another tab: its own status)
    lastCur = cur
    status = ""
  let wanted = (if t.title.len > 0: t.title & " - " else: "") & "Retro Navigator"
  if ui.title != wanted: setTitle(wanted)
  let host = hostOf(t.shown)
  let adsHere = adsAllowedOn(prefs, host)

  menubar:
    menu "&File":
      if menuItem("New &Tab", "Ctrl+T"): newTab(homeOf(prefs))
      if menuItem("Open &Location...", "Ctrl+L"): ui.focus = locId
      if menuItem("&Open File...", "Ctrl+O"): openDlg = true
      menuSeparator()
      if menuItem("&Close Tab", "Ctrl+W", enabled = tabList.len > 1): closeTab(cur)
      if menuItem("&Reopen Closed Tab", "Ctrl+Shift+T", enabled = closedTabs.len > 0):
        newTab(closedTabs.pop())
      menuSeparator()
      if menuItem("&Print...", "Ctrl+P", enabled = native): webPrint(t.key)
      menuSeparator()
      if menuItem("E&xit"): quitApp()
    menu "&Edit":
      if menuItem("&Find...", "Ctrl+F"): finder.open = true
      if menuItem("Find A&gain", "F3", enabled = finder.what.len > 0): findInPage()
    menu "&View":
      if menuItem("&Reload", "F5"): webReload(t.key)
      if menuItem("&Stop Loading", "Esc", enabled = t.loading): webStop(t.key)
      menuSeparator()
      if menuItem("&Larger", enabled = native and t.zoom < 3.0): setZoom(t.zoom + 0.1)
      if menuItem("S&maller", enabled = native and t.zoom > 0.5): setZoom(t.zoom - 0.1)
      if menuItem("&Actual Size", enabled = t.zoom != 1.0): setZoom(1.0)
      menuSeparator()
      if menuItem("Document So&urce", enabled = native):
        sourceAsk = webRun(t.key, "document.documentElement.outerHTML")
    menu "&Go":
      if menuItem("&Back", "Alt+Left", enabled = t.canBack or t.trail.len > 0): t.goBack()
      if menuItem("&Forward", "Alt+Right", enabled = t.canForward): webGoForward(t.key)
      if menuItem("&Home", "Alt+Home"): t.go(homeOf(prefs))
      if menuItem("&Stop Loading", "Esc", enabled = t.loading): webStop(t.key)
      if session.len > 0: menuSeparator()
      for i, p in session:
        let name = (if p.title.len > 0: p.title else: p.url).replace("&", "&&")
        if menuItem((if i < 10: "&" & $((i + 1) mod 10) & " " else: "") & name): t.go(p.url)
    menu "&Bookmarks":
      if menuItem("&Add Bookmark", "Ctrl+D", enabled = t.shown.len > 0): addMark()
      if menuItem("&View Bookmarks..."):
        markSel = 0
        showMarks = true
      if marks.len > 0: menuSeparator()
      for m in marks:
        if menuItem(m.title.replace("&", "&&")): t.go(m.url)
    menu "&Options":
      if menuItem("&General Preferences..."): openPrefs(0)
      if menuItem("&Appearance..."): openPrefs(1)
      if menuItem("&Security Preferences..."): openPrefs(2)
      if menuItem("&Network Preferences..."): openPrefs(3)
      menuSeparator()
      if menuItem("Allow Ads on This S&ite", checked = adsHere,
                  enabled = shBlockAds in shields and host.len > 0):
        prefs.allowAds(host, not adsHere)
        keepPrefs()
        applyShields()
      if menuItem("Clear Browsing &Data...", "Ctrl+Shift+Delete"): showClear = true
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
        if menuItem(name): t.go(if url.len > 0: url else: Searches[searchOf(prefs)][2])
    menu "&Help":
      if menuItem("&Handbook"): t.go("about:handbook")
      menuSeparator()
      if menuItem("&About Retro Navigator..."): showAbout = true

  if showToolbar:
    toolbar:
      if barButton(pxBack, "Back", "Back (Alt+Left)", enabled = t.canBack or t.trail.len > 0):
        t.goBack()
      if barButton(pxForward, "Forward", "Forward (Alt+Right)", enabled = t.canForward):
        webGoForward(t.key)
      if barButton(pxHome, "Home", "Home (Alt+Home)"): t.go(homeOf(prefs))
      toolSeparator()
      if barButton(pxRefresh, "Reload", "Reload (F5)"): webReload(t.key)
      if barButton(pxOpen, "Open", "Open a file (Ctrl+O)"): openDlg = true
      if barButton(pxPrint, "Print", "Print (Ctrl+P)", enabled = native): webPrint(t.key)
      if barButton(pxSearch, "Find", "Find on this page (Ctrl+F)"): finder.open = true
      toolSeparator()
      if barButton(pxStop, "Stop", "Stop loading (Esc)", enabled = t.loading): webStop(t.key)
      # the logo, at the right: it moves while a page loads; a click goes home
      let lw = CtrlH + FontH + dp(5) - 6
      if available() > lw + dp(8):
        space(available() - lw)
        let r = place(lw, lw)
        let hit = interact(idOf("logo"), r, focusable = false)
        if accessOn: accessNode(arButton, "Home", id = idOf("logo"), r = r)
        logo(r, t.loading)
        if hit.hover and canHover(): ui.tip = "Home"
        if hit.clicked: t.go(homeOf(prefs))

  # (the window's own keys, before the Location box takes them)
  if hotkeyPressed("Ctrl+T"): newTab(homeOf(prefs))
  if hotkeyPressed("Ctrl+W"): closeTab(cur)
  if hotkeyPressed("Ctrl+Shift+T") and closedTabs.len > 0: newTab(closedTabs.pop())
  if hotkeyPressed("Ctrl+Shift+Delete"): showClear = true

  if showLocation:
    row([dp(76), -1]):
      label "&Location:"
      if edit(t.location): t.typed = true
      locId = ui.lastId
    if ui.focus == locId and keyHit(KeyEnter):
      # (typed with "http://": gone to as it is)
      t.go(locationUrl(t.location, Searches[searchOf(prefs)][1]),
           secure = not t.location.strip.toLowerAscii.startsWith("http://"))
    elif ui.focus == locId and t.typed and keyHit(KeyEsc):
      t.location = t.shown                   # (Esc: what was typed let go)
      t.typed = false
  if showDirectory and not isCompact():
    row:
      for (name, url) in Directory:
        if button(name): t.go(if url.len > 0: url else: Searches[searchOf(prefs)][2])

  # the tabs, when there are two or more
  if tabList.len > 1:
    var labels, glyphs: seq[string]
    for x in tabList:
      labels.add tabName(x)
      glyphs.add(if x.loading: pxHourglass else: "")
    let te = tabStrip(labels, cur, glyphs, look = tlDocument)
    if te.added: newTab(homeOf(prefs))
    if te.closed >= 0: closeTab(te.closed)
    if te.moved.a >= 0 and te.moved.b in 0 .. tabList.high:
      let m = tabList[te.moved.a]
      tabList.delete(te.moved.a)
      tabList.insert(m, te.moved.b)
      if cur == te.moved.a: cur = te.moved.b
      elif cur == te.moved.b: cur = te.moved.a
    if te.menu >= 0: menuTab = te.menu
    contextMenu:                             # a tab's menu (right click, long press)
      let i = clamp(menuTab, 0, tabList.high)
      if menuItem("&New Tab", "Ctrl+T"): newTab(homeOf(prefs))
      if menuItem("&Duplicate Tab"):
        newTab(if tabList[i].shown.len > 0: tabList[i].shown else: tabList[i].asked)
      menuSeparator()
      if menuItem("&Close Tab", "Ctrl+W"): closeTab(i)
      if menuItem("Close &Other Tabs"):
        let keep = tabList[i].key
        for j in countdown(tabList.high, 0):
          if tabList[j].key != keep: closeTab(j)
        cur = 0
    cur = clamp(cur, 0, tabList.high)

  let fe = findBar(finder)
  if fe.next: findInPage()
  if fe.prev: findInPage(backwards = true)

  # the status bar: what happens, what the shield kept off, the key (whole:
  # https), how much is loaded
  var parts = @[(if status.len > 0: status
                 elif t.loading: "Loading " & (if t.shown.len > 0: t.shown else: t.asked) & "..."
                 elif not native: "No web engine here: pages on the web open in your browser"
                 else: "Document: Done")]
  if native and shBlockAds in shields:
    parts.add(if adsHere: "Ads allowed" else: pxFilter & " " & $t.blocked & " blocked")
  parts.add(if isSecure(t.shown): pxKey & " Secure" else: pxWarning & " Not secure")
  parts.add(if t.loading: $t.progress & "%" else: "Ready")
  statusbar(parts)

  # the page
  t.seen = ui.now
  t.asleep = false
  let ev = webView(pageFor(t.asked), key = t.key, engine = weSystem)
  if t.nextGo.len > 0 and t.asked == "about:blank":
    t.asked = t.nextGo
    t.nextGo = ""
  native = ev.native
  t.loading = ev.loading
  t.progress = ev.progress
  t.canBack = ev.canGoBack
  t.canForward = ev.canGoForward
  t.title = ev.title
  # (our own pages and the blank one in between: the address they were asked by)
  let now = if ev.url.len == 0 or ev.url.startsWith("html:") or ev.url == "about:blank" or
               ev.url.startsWith("data:text/html"): t.asked
            else: ev.url
  if now != t.shown:
    t.shown = now
    t.blocked = 0
    if not t.typed: t.location = t.shown
  if not t.loading and t.shown.len > 0 and t.shown != "about:blank" and
     (session.len == 0 or session[0].url != t.shown or session[0].title != t.title):
    session.visit(Place(title: t.title, url: t.shown))
  if ev.link.len > 0: t.go(ev.link)            # (a link in a page the kit shows itself)
  if ev.opened: status = "Opened in your browser: " & t.asked
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
  var links: seq[(string, bool)]              # (links into a new tab: made after)
  for m in ev.messages:
    if m.startsWith("blocked:"):
      try: t.blocked = parseInt(m[8 .. ^1])
      except ValueError: discard
    elif m.startsWith("tab:"): links.add (m[4 .. ^1], true)
    elif m.startsWith("newtab:"): links.add (m[7 .. ^1], false)
  for (u, behind) in links:
    newTab(u, behind)
    if behind: status = "Opened in a new tab: " & u

  # tabs not seen for a while sleep: their views let go
  if sleepTabs:
    for i, x in tabList.mpairs:
      if i != cur and not x.asleep and x.shown.len > 0 and ui.now - x.seen > SleepAfter:
        x.remake()
        x.asleep = true

  # the keys (while the page has the keyboard, its own come first)
  if hotkeyPressed("Ctrl+L"):
    ui.focus = locId
    var st = state(locId)
    st.anchor = 0
    st.caret = t.location.len
    state(locId) = st
  if hotkeyPressed("Alt+Left"): t.goBack()
  if hotkeyPressed("Alt+Right"): webGoForward(t.key)
  if hotkeyPressed("Alt+Home"): t.go(homeOf(prefs))
  if hotkeyPressed("F5"): webReload(t.key)
  if t.loading and hotkeyPressed("Esc"): webStop(t.key)
  if hotkeyPressed("Ctrl+D"): addMark()
  if hotkeyPressed("Ctrl+F"): finder.open = true
  if hotkeyPressed("F3"): findInPage(ShiftPressed in ui.mods)
  if hotkeyPressed("Ctrl+O"): openDlg = true
  if hotkeyPressed("Ctrl+P") and native: webPrint(t.key)

  if filePicker(openDlg, picked, fmOpen, ["*.html", "*.htm", "*.svg", "*.txt", "*.pdf", "*"],
                "Open File"):
    t.go(locationUrl(picked))

  dialog(showMarks, "Bookmarks", 460):
    var names: seq[string]
    for m in marks: names.add m.title & "  --  " & m.url
    listbox(names, markSel, rows = 10)
    row:
      spring()
      if button("&Go To", isDefault = true, enabled = marks.len > 0):
        showMarks = false
        t.go(marks[clamp(markSel, 0, marks.high)].url)
      if button("&Remove", enabled = marks.len > 0):
        marks.delete(clamp(markSel, 0, marks.high))
        markSel = clamp(markSel, 0, max(0, marks.high))
        keepPrefs()
      if button("Close"): showMarks = false

  dialog(showPrefs, "Preferences", 520):
    tabs(prefTab, ["General", "Appearance", "Security", "Network"], sameHeight = true):
      case prefTab
      of 0:
        form dp(110):
          field "&Home page:":
            row([-1, 0]):
              edit homeEdit
              if button("Use &Current", enabled = t.shown.len > 0): homeEdit = t.shown
          field "&Search with:":
            var names: seq[string]
            for (name, _, _) in Searches: names.add name
            discard combo(names, searchSel)
      of 1:
        discard appearanceSettings()         # (shown at once)
      of 2:
        shieldBox("&Block ads and trackers (pages load faster)", shBlockAds)
        shieldBox("Ask sites &not to track me (Global Privacy Control)", shNoTrack)
        shieldBox("Always use &secure connections (https)", shHttps)
        label "Ads are allowed on these sites:"
        listbox(allowedEdit, allowedSel, rows = 4)
        row:
          if button("&Remove", enabled = allowedEdit.len > 0):
            allowedEdit.delete(clamp(allowedSel, 0, allowedEdit.high))
            allowedSel = clamp(allowedSel, 0, max(0, allowedEdit.high))
          spring()
          if button("Clear Browsing &Data..."): showClear = true
      else:
        shieldBox("&Load a link ahead when the pointer rests on it", shPreload)
        shieldBox("Keep videos and sounds from &playing by themselves", shNoAutoplay)
        discard checkbox("Let tabs not looked at for 10 minutes s&leep (frees memory)", sleepEdit)
    row:
      spring()
      if button("OK", isDefault = true):
        prefs["home"] = (if homeEdit.strip.len > 0: homeEdit.strip else: "about:welcome")
        prefs["search"] = $searchSel
        prefs["adsAllowed"] = allowedEdit.join(" ")
        shields = shieldEdit
        sleepTabs = sleepEdit
        keepPrefs()
        applyShields()
        showPrefs = false
      if button("Cancel"): showPrefs = false

  dialog(showClear, "Clear Browsing Data", 460):
    label "Clear from Retro Navigator:"
    checkbox("&Pages visited (the Go menu, and Back in every tab)", clearPages)
    checkbox("&Cookies, cache and site data (signs you out of sites)", clearSites)
    row:
      spring()
      if button("Clear", isDefault = true, enabled = clearPages or clearSites):
        clearData()
        showClear = false
      if button("Cancel"): showClear = false

  dialog(showSource, "Document Source", 640):
    label t.shown
    editArea(source, lines = 18, wrap = false, readOnly = true)
    row:
      spring()
      if button("Close", isDefault = true): showSource = false

  aboutBox(showAbout, "Retro Navigator", NavigatorVersion,
           ["A web browser in the manner of 1995's, made with Retro Nim UI.",
            "The pages are drawn by the system's own engine."],
           tagline = "A web browser", iconPng = IconPng,
           url = "https://github.com/foxoman/retroui")
