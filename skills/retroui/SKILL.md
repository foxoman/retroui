---
name: retroui
description: Build desktop and mobile apps with Retro Nim UI (the retroui Nim package, github.com/foxoman/retroui): Windows 3.1 style, immediate mode, Windows, macOS, Linux, Android, iOS. Use for any app, form or tool made with retroui, or to fix or package one.
---

# Building apps with Retro Nim UI (`retroui`)

Retro Nim UI is a Windows 3.1 style UI toolkit for Nim by Sultan Al Isaiee
(@foxoman). It is immediate mode, has no dependencies to install (its own
fonts, icons, PDF writer, image decoders), and builds the same app for
Windows, macOS, Linux/BSD (X11, Wayland through XWayland), Android and iOS.

## 1. Read the latest docs first

The toolkit changes between releases. Before writing code, read the
current documents from the official repository (main branch) and follow
them where they differ from this file:

1. https://github.com/foxoman/retroui/blob/main/README.md -- what is in the kit, how it works
2. https://github.com/foxoman/retroui/blob/main/docs/controls.md -- every control: signature, example, pictures
3. https://github.com/foxoman/retroui/blob/main/CHANGELOG.md -- what changed (the top section is the newest)
4. https://github.com/foxoman/retroui/blob/main/BUILDING.md -- desktop (Windows, macOS, Linux), Android and iOS builds, signing
5. https://github.com/foxoman/retroui/blob/main/AGENTS.md -- rules for working on the kit itself
6. https://github.com/foxoman/retroui/blob/main/skills/retroui/SKILL.md -- the newest copy of this skill

In a clone, read the same files locally; `nimble docs` makes the full API
reference in `docs/api`. When you are unsure of a proc's parameters, look
at its signature in `src/retroui/*.nim` (every exported symbol has a doc
comment) instead of guessing.

## 2. Install and start a project

```sh
nimble install retroui                 # the library and its tools: retrokit, retroapk, retroios
retrokit doctor                        # checks the C compiler, the screen libraries, Android tools
retrokit new myapp --kind:business     # kinds: hello, form, business, files, charts
cd myapp && nimble run
```

Needs Nim 2.0+ (2.2 or 2.4) and a C compiler. Build with
`-d:release -d:useMalloc` (memory goes back to the system).

The person may design the windows by hand in **Retro Designer**:
`retrokit designer app.nim` draws the file's windows with the real controls
and writes every change (controls dropped, moved, grouped, properties,
events) into the same `.nim` file -- no form file, the code stays theirs
(docs/designer.md). Write apps it can read: windows as `app` blocks or
procs that draw controls, values written out in the calls, the code of an
event under its control (`if button("&Save"): save()`), `var` lines at the
top for what the controls bind. While the designer has a file it is
read-only with a `.NAME.lock` beside it: do not write the file then (ask to
close the designer, or use its Edit Code).

## 3. The shape of every app

```nim
import retroui

var name = "World"
var greeting = ""

app "Hello", 320, 120:                 # title, width, height, then the frame's code
  row([50, -1]):                       # widths: pixels, -1 = the rest
    label "&Name:"
    edit name                          # edits `name` in place
  row:
    if button("&Greet", isDefault = true):
      greeting = "Hello, " & name & "!"
    if button("E&xit"): quitApp()
  label greeting
```

`app` runs its block once per frame until the window closes. Options go by
name after the size: `theme`, `frame` (wfAsBuilt, wfSystem, wfClassic),
`userFrame`, `gpu` (gmAuto, gmGpu, gmCpu), `scale`, `font` (ufSans, ufSerif,
ufMono), `zoom`, `id`, `icon` (PNG bytes, `staticRead`), `look` (keeps the
look the user picks), `resizable` (false: the window keeps its size). A
misspelled option is a compile error. An app with its own loop uses
`openApp(...)`, `while beginFrame(): ...; endFrame(); appFrameDone()`,
`closeApp()` -- and first in each frame `if stoppedFrame(): (endFrame();
continue)`: when the last run crashed, its report shows before the app's
code runs (`app` does this itself); ask `stoppedPending()` before bringing
back what was open, and leave it out when `startFresh()`. Set
`reportedVersion = "1.2"` before the window opens: the report says it. Files
named on the command line: `appArguments()` (none in a phone's app).

The whole syntax, every form as a small program with a picture of what it
draws (what each number in `row([50, -1, 0, -2])` gives, binding, events,
containers, dialogs, ids in loops, the rules), is in `docs/syntax.md`
(github.com/foxoman/retroui/blob/main/docs/syntax.md). Row widths, in short:
a number above 0 is that many design pixels, `0` the control's own width,
`-1` one share of what is left, `-2` two shares; no list is each control at
its own width; more controls than widths start the widths again on a new
line.

## 4. Immediate mode: the rules that prevent most mistakes

- Controls are proc calls made **every frame**; there are no widget
  objects or callbacks. A control returns true when it was clicked or
  changed something: `if button("OK"): save()`.
- **State lives in your variables** (globals or an object you keep), never
  in locals of the frame block: a local is new every frame.
- **Ids:** a control is known by its variable or label. Controls drawn in
  a loop need their own ids: `for i, r in rows: withId(i): ...` (or
  `pushId(i)` / `popId()`, or a control's `key` parameter).
- **Never block the frame.** Long work goes off the UI thread:
  `retroui/background` (`pictureAsync`, `folderAsync`, results by
  callback or `finished()`), `retroui/parallel` (`parallelFor`,
  `parallelRows`), `httpRequest` from a thread; `busy("Saving..."): ...`
  shows a busy box for work that must run on the UI thread. Ask for a
  frame later with `wakeIn(ms)`; for something that moves by itself where
  it is drawn (an animation, a clock), `wakeInShown(rect, ms)`: no frames
  while it is out of view, so an app at rest takes no CPU.
- `&` in a label underlines the next letter (Alt+letter). `isDefault = true`
  makes Enter press the button.
- Dialogs and popups are drawn by the same frame code, opened by a
  variable (`var showAbout = false` ... `aboutBox(showAbout, "My App", ...)`).
- `aboutBox` shows the toolkit's credit (`RetroCredit`, with its web site
  and mail) on its first page by itself: do not pass it again. Its
  `credits` page is for others: `credits = [RetroFontCredit, "Icons: ..."]`.
- **Keyboard shortcuts:** the shortcut text of `menuItem("&Open...", "Ctrl+O")`
  is only shown in the menu. Handle the key every frame, outside the
  `menubar` block: `if hotkeyPressed("Ctrl+O"): openDlg = true` (on a Mac
  "Ctrl+O" is Cmd+O). The controls share their keys (docs/syntax.md has
  the table): a control of your own that drops something open opens on
  `dropKey()` (F4, Alt+Down) and Enter, and closes on them, Alt+Up or Esc.
  On a Mac, Option + a letter types (no underlined letters); an app or a
  test that wants Alt's letters there sets `optionLetters = true`.
- **Focus:** call `focusFirstText()` when a screen or dialog opens so the
  user can type at once (`focusFirstText(inDialog = true)` for a dialog
  opened this frame); `focusNext()` moves to the next control. Clicking a
  `numberEdit` / `intEdit` selects its text, so typing replaces it.

## 5. Layout

`row:` / `row([w1, w2, -1]):` (left to right), plain statements stack top
to bottom, `group "Title":`, `card`, `form(labelWidth): field("&Name:"): edit x`,
`spring()` (pushes the rest to the far side), `space(n)`, `adaptive(minW): ...`
(columns that fold into one on a phone), `scrollPanel`/`panel(h)`/`pane`,
`tabs`, `split`/`vsplit`, `sidePane`, `menubar: menu "&File": if menuItem("&Open", "Ctrl+O"): ...`,
`toolbar:`, `statusbar(...)`, MDI windows (`mdiArea`, `mdiWindow`; `noPin` for no pin in the title bar), docking (`retroui/dock`).
Sizes are design pixels; the kit scales them to the screen (`dp(n)` for your own).

Forms: `form(90): field("&Name:"): edit name` -- `90` is the caption
column in design pixels (`form(0)`: as wide as the widest caption). The
control fills the rest of the row; give it `w = ...` to make it narrower,
or put several in a `row:` inside the `field`. `field("")` lines a control
up under the others. When the row is narrower than the captions plus about
200 pixels (a phone), each caption goes above its control.

## 6. Controls (docs/controls.md has all 383, with pictures)

Text: `label`, `paragraph`, `heading`, `styledText`, `link`, `badge`, `icon`, `iconLabel`, `image`, `tooltip`.
Buttons: `button`, `segmented`, `menuButton`, `splitButton`, `buttonRow`.
Choices: `checkbox`, `radio`, `toggle`, `chips`, `tagInput`, `rating`.
Text input: `edit`, `editArea`, `searchBox`, `autocomplete`, `maskedEdit`, `comboEdit`, `hotkeyEdit`, rich text (`richEdit`, `richToolbar`).
Numbers, dates, colors: `spin`, `intEdit`, `numberEdit`, `slider`, `progress`, `datePicker`, `calendar`, `timePicker`, `colorPicker`, `colorWell`.
Lists and data: `listbox`, `combo`, `grid` (the data grid with editing, sorting, totals), `tree`.
Files: `fileDialog`, `fileList`, `folderTree`, `filePicker`, `filePreview`, `placesView`.
Charts and more: `chart` (21 kinds, from your numbers or a CSV table), `barChart`, `lineChart`, `pieChart`, `liveGraph` (a task manager's graph that moves: a frame costs a copy), the world map (`retroui/mapview`), street maps (`tileMap`, `retroui/tilemap`; places and routes `retroui/geo`), 3D (`retroui/view3d`; Blender's models `retroui/gltf`),
HTML and Markdown (`htmlView`), web pages (`webView`), canvas (`canvas`, `retroui/canvas2d`), reports and PDF (`retroui/report`),
sound and video (`retroui/media`; the system's media controls `retroui/mediasession`; camera and microphone `retroui/capture`), spreadsheets (`retroui/xlsx`), more windows (`window`).

**The system's features** (`import retroui/system`; docs/system.md has
every system's answer and what the app declares): `notify`, `setBadge`,
`share`, `haptic`, `vibrate`, `location` (every frame while needed:
`psWaiting` until the first fix), `speak`, `setOpenAtLogin`,
`requestAttention`, `online`, `systemLanguage`, `battery`, `deviceInfo`,
`revealFile`. "Not here" answers false (never raises): fall back
(`share` false -> `putClipboardText`; `notify` false -> `toast`). Ask from a
click (phones and browsers ask the user). Secrets: `retroui/secrets`;
signing in: `retroui/oauth`; updates inside the app, signed:
`retroui/update` (`checkForUpdate(url, publicKey, version)`,
`downloadUpdate`, `installUpdate`, `restartApp`; `retrokit update-key`,
`retrokit update-sign update.json`). What the computer is doing:
`import retroui/sysmon` -- `startMonitor()` once, then `latestSample()` in
the frame (never waits; nil before the first: the processor, its cores,
the memory, the disks, the network, the battery, every process),
`monitorHistory()` for graphs, `setMonitorInterval` (slower while hidden),
`endProcess(p)` (refuses an id that is another program's by now),
`setPriority`, `startupItems`, `connections`, `appendHistory` /
`loadHistory`; examples/taskman.nim uses all of it.

**A street map with a route** (`import retroui/[tilemap, geo]`):

```nim
var city = TileMapState(lat: 23.588, lon: 58.3829, zoom: 12)   # (beside your other state)
let src = osmTiles()          # light use only; a business app: googleTiles(key), mapTilerVector(key),
                              # azureTiles(key)... or pmtilesSource("city.pmtiles") offline
var trip: Route
# in the frame:
if button("&Route"):
  let r = route([(23.588, 58.383), (23.614, 58.593)], service(gpOsrm))   # waits; routeAsync does not
  if r.ok: trip = r.route
let ev = tileMap(city, src, markers = [MapMarker(lat: 23.614, lon: 58.593, label: "Airport")],
                 shapes = [routeShape(trip)])
if ev.clicked: echo ev.lat, ", ", ev.lon
```

**A model from Blender** (`import retroui/[view3d, gltf]`): export glTF
(`.glb`, "Animation" on), name the parts the app moves; then

```nim
var car = loadGltf("car.glb")     # (beside your other state); a .blend: loadModel3
var cam = camera3()
fitView(car, cam)
# in the frame:
if button("&Door"): car.play("DoorOpen", loop = false)   # its clips by name: car.animationNames
if button("&Red"): car.recolor("CarPaint", color(170, 0, 20))
car.animate(1 / 60)                                     # every frame, while clips play
let ev = view3d(car, cam)
if ev.clicked: echo ev.nodeName                         # the part picked: "Door_L"
```

`turnNode`, `moveNode`, `setVisible`, `tint` take a part's name
(`car.nodeNames`); `retrokit model car.blend` lists them.

**More windows**: `window(toolsOpen, "Tools", 240, 360): body` -- a
window of the system's own, drawn where the frame reaches it; its close
button sets the `bool` to false; not drawn, it closes (a dialog on phones
and in the browser).

**A web page with scripts** (help pages, a map or chart made in JavaScript,
a sign-in page): `webView(url, key = "k", engine = weSystem)` shows it in
the system's browser (WebView2, WKWebView, WebKitGTK, Android's WebView),
placed over the widget; without that engine on the system, or with `weKit`,
the kit draws local pages itself and offers web pages to the browser. The
page and the app talk without callbacks:

```nim
var ask = 0
var title = ""

# in the frame:
webAllow("help", ["nim-lang.org"])           # others kept out: page.blocked
let page = webView("help/index.html", key = "help", engine = weSystem)
for m in page.messages: handle(m)            # retro.post(text) in the page
if button("&Dark"): webPost("help", "dark")  # window "retro" event: e.detail
if button("&Title"): ask = webRun("help", "document.title")
for r in page.results:                       # a later frame: r.id, r.value (JSON), r.error
  if r.id == ask: title = r.value
```

Keep the `key` the same every frame; draw the view every frame it should
show (a view not drawn is hidden). `webRun` and `webPost` are actions:
call them on an event (a button, a message), not on every frame. `webGoBack`, `webGoForward`,
`webReload`, `webStop`, `webZoom`, `webClose` take the key. Pages on the
web need `retroapk --permission:INTERNET` in an APK. The app's own pages:
`webAppFolder(dir)` then `webView(webAppUrl("index.html"), ...)` (they
fetch each other as a site's files do); `webPermit(key, {wpCamera})` lets
a page use the camera; `webPrint(key)` prints it.

**Grid sorting:** the grid does not reorder your data. Keep the order in
your own variables, pass it in for the header's arrow, and sort a list of
row numbers when a header is clicked:

```nim
import std/[algorithm, sequtils]       # sort, toSeq

var people: seq[Person]
var order: seq[int]                    # people[order[i]] is row i
var sortCol = -1
var sortDesc = false
var cols = @[Column(title: "Name", width: 160), Column(title: "Salary", width: 90)]

proc cellOf(row, col: int): string =
  let p = people[order[row]]
  if col == 0: p.name else: formatNumber(p.salary, 2)

# in the frame:
if order.len != people.len: order = toSeq(0 ..< people.len)
let ev = grid(cols, order.len, cellOf, sel, height = -1,
              sortColumn = sortCol, sortDescending = sortDesc)
if ev.sorted:
  sortCol = ev.sortColumn
  sortDesc = ev.sortDescending
  order.sort(proc (a, b: int): int =
    let c = if sortCol == 0: cmp(people[a].name, people[b].name)
            else: cmp(people[a].salary, people[b].salary)
    if sortDesc: -c else: c)
if ev.activated: editPerson(order[sel])        # double click or Enter
if ev.edited: discard                          # ev.row, ev.col, ev.text: the new cell text
```

The `GridEvent` fields: `selChanged`, `activated`, `sorted` (`sortColumn`,
`sortDescending`), `edited` (`row`, `col`, `text`), `toggled`, `clicked`,
`rightClicked`, `hot`, drag and drop (`dragStarted`, `dropOver`, `dropped`).
Rows on screen are the only ones `cell` is asked for, so a large table
costs what its visible rows cost.

## 7. Files, settings and CSV

- **Where to keep files:** `dataDir("myapp") / "people.csv"` -- a folder
  only this app writes to (on Android and iOS the app's own folder); `/`
  for paths comes from `std/os`, which `import retroui` does not bring.
- **Settings:** `var s = loadSettings("myapp")` (an ordered table of
  strings, empty the first time); `s["lastFile"] = path;
  saveSettings("myapp", s)` (written safely; false when it could not be).
- **CSV:** `readCsv(path)` / `parseCsv(text)` give a `DataTable`
  (`headers`, `rows`, `error`; `cell(row, col)`, `column("Sales")` as
  numbers, `colIndex("Name")`). Write one with `writeCsv(path, table)` or
  `toCsv(table)`; `csvLine(cells)` and `csvField(s)` quote as needed.
  All of them are in `retroui/charts` (part of `import retroui`).
- **Network:** `import retroui/http` -- `httpRequest("GET", url)` from any
  thread (status, headers, body; `error` when no answer came). `import
  retroui/netconn` -- a connection with the system's TLS: `netOpen(host,
  port, tls = true)`, `readLine`, `readBytes`, `write`, `startTls` after a
  protocol's STARTTLS (raises `NetError`). Mail: `retroui/imap`
  (`imapConnect`, `login`, `listFolders`, `select`, `uidSearch`,
  `fetchHeaders`, `fetchMessage`, `addFlags`, `move`, `append`),
  `retroui/smtp` (`smtpSend(host, port, security, user, password, from,
  rcpts, rawMessage)`: "" when sent), `retroui/mailsetup`
  (`findMailServers(email)`); blocking: on a thread of their own. `import
  retroui/xmpp` -- chat: `xmppStart(jid, password)`, take `xmppEvents()`
  every frame (with `wakeIn(250)` while `xmppRunning()`), `sendChat(to,
  text)`; the server's history: when xeServices says "archive",
  `askArchive(after = lastId)` brings xeArchived then xeArchiveDone (ask
  again `after` its `text` until `show == "complete"`); keep each message's
  `archiveId` so none comes twice. End-to-end encryption: `import
  retroui/omemo` -- `omemoOpen(dir, jid)`, `omemoHandle(e)` first for each
  event, `omemoStart()` on xeOnline, `omemoDecrypt(e)` when
  `isEncrypted(e)`, `omemoSend(to, text)`, `omemoNotes()` every frame.
  Build with `-d:ssl`.
  `examples/communicator.nim` is a whole messenger on it.
- **PDF of your own text:** `import retroui/report` -- `newReport`,
  `paragraph`, `table`, `savePdf` (or `reportFromHtml(html)`); Notepad's
  File > Print to PDF is a short example.

## 8. Looks, text and the window

- Themes: `ui.theme = Dark` (`builtinThemes`), or the `theme` option.
- Text size: 12 pixels per em at 100 % on desktops and tablets, 15 on
  phones; controls grow with the text. `setTextScale(120)` (the user's text
  size), `setUiScale(125)` (everything), `setBaseTextSize(14)` (your app's
  100 %).
- Fonts: FreeSans (default), FreeSerif, FreeMono, built in with Arabic;
  `loadUiFontFile(path)` for a font of your own; `appearanceSettings` lets
  the user choose (theme, font, text size, Sharp text, window frame) and
  `look = "myapp"` keeps it.
- Arabic and right-to-left text work everywhere (joined, bidi);
  `setRtlInterface(true)` mirrors the interface. Markdown in Arabic reads
  right to left by itself: its lists' bullets, its quotes' bars and its
  tables' first column at the right.
- The window frame: the system's or the Windows 3.1 frame (`frame` option;
  users switch from the control or system menu; kept per app). The 3.1
  frame takes the theme's colors and has a size grip in its bottom right
  corner (the status bar's end; `sizeGrip()` says where). `resizable = false`
  (`setResizable`) keeps the window's size: no sizing border, maximize
  button or grip, and the system's frame fixed too.
- Screen readers (Orca, NVDA, Narrator, VoiceOver, TalkBack) read every
  control by itself: its role, its label (a `label` before a box names the
  box: write `row([60, -1]): label "&Name:"; edit name`), its value and
  state; they press, type into and move the focus as the user would. What
  you draw yourself (`canvas`, `fill`, `text`) is not read: give it a node,
  `accessNode(arImage, "Sales by month", id = 0, r = r)` (or `arLabel`,
  `arButton`...), and an icon-only control a name, `accessName("Delete")`
  before it. `accessible()` is true while a screen reader listens (nothing
  is built otherwise); `RETRO_ACCESS=1` builds the tree to try it.
- Input methods (Chinese, Japanese, Korean, a phone keyboard's word) need
  nothing: what they compose is drawn in the text box at the caret
  (`ui.composing`) and comes as typed text when settled.
- Scaling: sizes and text follow the screen's scale exactly (125 %, 150 %,
  175 %...), lines stay on whole pixels; nothing to do in an app.

## 9. Build and package

```sh
nim c -r -d:release -d:useMalloc app.nim                      # this computer
nim c -d:release -d:mingw --cpu:amd64 --app:gui app.nim        # Windows .exe from Linux/macOS (MinGW)
retroapk app.nim --name:"My App" --id:com.me.myapp             # Android APK: no SDK, no NDK needed
retroios app.nim --simulator --run                             # iOS, on a Mac with Xcode
retrokit small app.nim                                         # smallest desktop build
retrokit web app.nim                                           # a web page (clang + lld, no Emscripten)
retrokit web app.nim --threads                                 # ... and a build with threads where the browser allows
retrokit run --web --watch app.nim                             # ... served, rebuilt on every save
nim c -d:release -d:retroFonts=ui app.nim                      # fewer fonts built in: a smaller program
```

For the stores (all made in Nim; `--help` on each; BUILDING.md "Shipping
to the stores"):

```sh
retrokit aab app.nim --key:upload.pem --cert:upload.der        # Google Play (an App Bundle)
retrokit sign app.exe --key:k.pem --cert:c.pem --timestamp:http://timestamp.digicert.com
retrokit msix app.exe --name:Company.App --version:1.2.0.0 --key:k.pem --cert:c.pem
retrokit mac app --name:"My App" --id:com.me.app               # .app signed ad hoc (any system)
retrokit mac app --sign:"Developer ID Application: ..." --notarize:PROFILE   # on a Mac
retroios app.nim --sign:... --profile:appstore.mobileprovision --ipa        # App Store
retrokit model car.blend                                       # a 3D model as the .glb the app carries
```

Without `--key`/`--cert` a test key is made (never publish with it).

A Linux build runs on X11, on Wayland (its own driver, no libwayland) and
on a console with no desktop (the screen driver: DRM/KMS or the
framebuffer, evdev input): `RETRO_DRIVER=x11|wayland|kms|fb` chooses,
`-d:wayland` or `-d:kiosk` builds only one. A web build is 32-bit with no
raw sockets: keep work short in the frame (without `--threads` the kit's
`background` tasks run there); code that starts threads compiles both
ways (`when compileOption("threads")`); `httpRequest` reaches the page's
own site with a short address; a file written in `/downloads` goes to the
user; chat (`retroui/xmpp`) needs `--threads` and a server with a
WebSocket.

In Termux on Android, `nim c -r app.nim` runs the app on Termux:X11
(`pkg install x11-repo termux-x11-nightly libx11`): it starts the X server
when none runs, brings Termux:X11 to the front and fills its screen;
`retroapk` makes the APK. To see the app as a desktop window while working
on it: `retrokit run --window app.nim` (`RETRO_WINDOW=1`): a desktop drawn
over the screen, the app at its own size grown by the tablet's density, in
the middle, in its 3.1 frame, moved and sized there, kept in view when the
screen changes size; `--scale:N`, `--size:WxH`, `--theme:NAME` too.
`retrokit run --live app.nim` (`--window` + `--watch`) builds it again on
every save and shows the new one where the window was; the app's variables
start fresh each time. `retrokit run --watch app.nim` does the same on any
desktop (Windows, macOS, Linux): the X11, Windows, macOS and SDL drivers
reopen the window where it was ($RETRO_WINDOW_STATE, `keptWindowPlace` /
`keepWindowPlace` in `uirelays/services`). (`uirelays/target`: `androidApp` is an APK,
`androidShell` a program in Termux.) A program that manages other X11
windows (a window manager, a desktop) gets every event first with
`x11EventHook` (`retroui/uirelays/drivers/x11_driver`; `x11Display`,
`x11Window`, `x11Wake`): see Retro Desktop, github.com/foxoman/retrodesktop.
On X11 the cursors are drawn at the screen's scale when it is 150% or more
(`x11DrawnCursors`: 1 always, 0 never).

A window drawn inside the window (a preview, a guide's picture, a
designer): `windowBox(rect): body` lays `body` out as a window at that
rectangle (its menu bar, bars and dialogs kept in it), `inert: body` draws
without input (its dialogs and menus do not take the window's);
`showMenu(["&File"])` / `hideMenu` open a menu bar's menu as if clicked;
`ui.measuring` with `notePlaced` tells where things were drawn.

`retroapk` needs only clang with lld (or Zig); without either it fetches
the NDK. Keep `~/.retro/android` (the signing key) for updates. It adds
the permissions the app's code needs (camera, microphone, notifications,
the place, vibration, the network) and says which; the app asks the user
the first time a feature is used and must go on when the answer is no
(every call answers false or "denied", never raises). In Termux a build
runs at most four C compilers (`--jobs:N`; Android stops builds with too
many, "signal 9": BUILDING.md, "Building on a phone or tablet").
`retrokit run --web --threads` builds once; `--lto:thin` links a web page
with much less memory. Details per OS in BUILDING.md.

## 10. Check your work

- Compile and run it; look at it. On a headless Linux, under `Xvfb` (with
  no window manager the window sits at the top left, so crop the screen to
  the app's size):

  ```sh
  Xvfb :99 -screen 0 1280x900x24 & sleep 1
  DISPLAY=:99 ./app & sleep 2
  DISPLAY=:99 import -window root -crop 640x480+0+0 +repage shot.png   # the app's width x height
  ```
- Headless tests: the kit's fake driver (`tests/harness.nim` in the repo:
  `fakeDriver()`, `startApp`, `run()`, `click`, `key`, `px(x, y)`) drives an
  app without a screen.
- `RETRO_SIZE=420x840 RETRO_TOUCH=1 ./app` tries a phone's size on a desktop;
  `RETRO_TOUCH=1` alone gives finger-sized controls on a tablet or a desktop
  (`RETRO_CONTROLS=touch|desktop|auto` for the sizes only). Put
  `appearanceSettings()` in the app's settings so users choose their sizes.

## 11. Common mistakes

- A `col` in a plain `row` takes all the room left, so what comes after it
  (a combo, tool buttons) is squeezed to nothing: give the row its widths,
  `row([40, -1, 0])` (a picture, the text, then the control at its own
  width). Two panels in a plain `row` are the same: `row([-1, 130])`.
- Keeping state in a local inside the frame block (it resets every frame).
- The same control drawn twice in a loop without `withId` (they share state).
- Blocking work (big files, network) in the frame code: the window freezes.
- Calling controls outside the `app` block (or outside `beginFrame` ... `endFrame`).
- Guessing a parameter name: check the signature in the source or docs.
- A shortcut written only in `menuItem(..., "Ctrl+S")`: it is a label; handle it
  with `hotkeyPressed("Ctrl+S")`.
- Passing `RetroCredit` to `aboutBox`: it is there already (it would show twice).
- `paramCount`, `paramStr` or `commandLineParams` in an app: an Android or
  iOS app and a web page have no command line, Nim raises, and the app
  closes at its start. `appArguments()` gives none there.
- Expecting `grid` to sort the data: it reports the header click (`ev.sorted`);
  you sort.
- Using the old name `retro` (`import retro`, `nimble install retro`): the package
  and its modules are `retroui` (`import retroui`, `import retroui/http`).
- A text box without a label before it (or an icon-only tool button without a
  tip): a screen reader reads it as nothing. Put the label first, or
  `accessName("...")`.
- Making a string or a seq in the frame code of something that does not change
  (`"Total: " & $n` every frame is fine; building big lists every frame is not):
  an unchanged frame of the kit itself takes no memory.
- `return x` (or `return nil`) after `result` was set, in a proc that returns
  a picture, a string, a seq or an object: Nim 2.2 never frees what `result`
  held. Write `result = x; return`, or build the value in a local and set
  `result` once at the end. The kit's `tools/returncheck.py` finds them:
  `python3 path/to/retroui/tools/returncheck.py app.nim src/`.
