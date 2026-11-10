## Makes docs/controls.md -- the guide to Retro Nim UI: getting started,
## layout, every control by kind, and the looks -- and its pictures
## (docs/controls/*.png). For each control: what it does, its pictures (as
## it is, on a touch screen, in a dark color scheme; some in more states),
## the example code that drew them, and its signatures with their doc
## comments, read from src/.
##
##   nim c -r -d:release --hints:off tools/shots.nim      (from the repository's root)
##   SHOTS_ONLY=button,combo ./shots                      only these pictures, no guide
##
## Headless: a fake screen driver, the built-in fonts, no window. The files
## the file controls show are made in the temp folder ($HOME is set to a
## sample home there) and removed at the end. `python3 tools/controlscheck.py`
## checks that the guide shows every control.

import std/[os, strutils, tables, algorithm, sequtils, json, math]
from std/times import fromUnix, epochTime
from std/unicode import runes, toUTF8
import retroui
import retroui/[textwidgets, richedit, qrcode, pdfview, tilemap, mvt, capture, mediasession, system,
                secrets, update]
import retroui/uirelays/[coords, screen, input, services]
include "../tests/carscene"

# ---- a sample home: the files the file controls show ------------------------------------------------

let
  sampleRoot = getTempDir() / "retro-shots"
  sampleHome = sampleRoot / "Sultan"

proc samplePicture(w, h, seed: int): Bitmap =
  ## A sky, a sea and a sun: something for the picture views to show.
  result = newBitmap(w, h)
  let skies = [(30, 60, 160), (200, 90, 40), (40, 120, 60), (10, 10, 50)]
  let (r0, g0, b0) = skies[seed mod skies.len]
  for y in 0 ..< h:
    for x in 0 ..< w:
      let t = y / h
      var r = int(r0.float * (1 - t) + 230 * t)
      var g = int(g0.float * (1 - t) + 200 * t)
      var b = int(b0.float * (1 - t) + 160 * t)
      if y > h * 2 div 3:
        r = 20 + (x * 3 + seed * 40) mod 30
        g = 90 + (y * 2) mod 40
        b = 150 + (x + y) mod 60
      let dx = x - w * (2 + seed mod 3) div 5
      let dy = y - h div 3
      if dx * dx + dy * dy < (h div 7) * (h div 7):
        r = 255; g = 220; b = 80
      result.px[y * w + x] = 0xFF000000'u32 or (uint32(r) shl 16) or (uint32(g) shl 8) or uint32(b)
  result.changed()

proc makeSampleHome() =
  if dirExists(sampleRoot): removeDir(sampleRoot)
  for d in ["Desktop", "Documents", "Documents/Invoices", "Documents/Projects", "Downloads",
            "Music", "Pictures", "Videos", ".local/share/Trash/files", ".local/share/Trash/info"]:
    createDir(sampleHome / d)
  let docs = sampleHome / "Documents"
  writeFile(docs / "Budget 2026.csv", "Month,Amount\nJan,120\nFeb,95\nMar,140\nApr,180\n")
  writeFile(docs / "Notes.md", "# Notes\n\n- Stock count on Friday\n- Call Al Noor Trading\n")
  writeFile(docs / "Letter.txt", "Dear Maryam,\n\nThe new price list is ready.\n\nSultan\n")
  writeFile(docs / "Invoices" / "Invoice 42.txt", "Invoice 42\nPaper A4  10  45.000\n")
  writeFile(docs / "Projects" / "Plan.txt", "1. Sketch\n2. Build\n3. Ship\n")
  writeFile(docs / "Projects" / "Letter.txt", "An older letter.\n")
  var q = newReport("Quote Q-118", author = "Gulf Print House")
  q.heading("Quote Q-118")
  q.paragraph("For Al Noor Trading: business cards, letterheads and a roll-up banner.")
  var t = newTable(["Item", "Qty", "Amount"], widths = [-3.0, -1, -1],
                   aligns = [alLeft, alRight, alRight])
  t.addRow(["Business cards", "2", "25.000"])
  t.addRow(["Letterheads", "3", "76.500"])
  t.addTotals(["Total (OMR)", "", "101.500"])
  q.table(t)
  q.savePdf(docs / "Quote Q-118.pdf")
  for i, n in ["Beach", "Sunset", "Garden", "Night"]:
    savePng(samplePicture(320, 220, i), sampleHome / "Pictures" / (n & ".png"))
  copyFile("tests/data/media/clip.avi", sampleHome / "Videos" / "Harbour.avi")
  copyFile("tests/data/media/beep.ogg", sampleHome / "Music" / "Morning bell.ogg")
  writeFile(sampleHome / "Downloads" / "setup-notes.txt", "Install, then restart.\n")
  # the trash (the freedesktop.org one; what trashList shows on Linux)
  let trash = sampleHome / ".local/share/Trash"
  writeFile(trash / "files" / "Old budget.csv", "Month,Amount\nJan,100\n")
  writeFile(trash / "info" / "Old budget.csv.trashinfo",
            "[Trash Info]\nPath=" & docs / "Old budget.csv" & "\nDeletionDate=2026-10-26T16:05:00\n")
  # one date for all, so the pictures stay the same from one run to the next
  for f in walkDirRec(sampleHome, {pcFile, pcDir}):
    setLastModificationTime(f, fromUnix(1793097000))

makeSampleHome()
putEnv("HOME", sampleHome)
putEnv("XDG_DATA_HOME", sampleHome / ".local/share")
putEnv("XDG_CONFIG_HOME", sampleHome / ".config")

# ---- a fake screen of any size ---------------------------------------------------------------------

var
  W = 360
  H = 120
  touchNow = false
  pixels: seq[uint32]
  queue: seq[Event]
  ticks = 1000
  clip = ""
  view: proc ()

proc samplePlaces(): seq[tuple[name, path: string]] {.nimcall.} =
  @[("Home", getHomeDir()), ("Desktop", getHomeDir() / "Desktop"),
    ("Documents", getHomeDir() / "Documents"), ("Downloads", getHomeDir() / "Downloads"),
    ("Music", getHomeDir() / "Music"), ("Pictures", getHomeDir() / "Pictures"),
    ("Videos", getHomeDir() / "Videos")]

proc fakeDriver() =
  windowRelays.createWindow = proc (l: var ScreenLayout; icon: pointer; iconLen: int) =
    l.width = W; l.height = H; l.scaleX = 1; l.scaleY = 1; l.uiScale = 100
  windowRelays.getWindowLayout = proc (): ScreenLayout =
    ScreenLayout(width: W, height: H, scaleX: 1, scaleY: 1, uiScale: 100, touch: touchNow)
  windowRelays.refresh = proc () = discard
  windowRelays.setWindowTitle = proc (t: string) = discard
  windowRelays.setCursor = proc (c: CursorKind) = discard
  drawRelays.blitRGBA = proc (p: ptr UncheckedArray[uint32]; w, h: int;
                              dst: Rect; f: RGBAFormat): bool =
    for y in 0 ..< h:
      for x in 0 ..< w:
        let i = (dst.y + y) * W + dst.x + x
        if i >= 0 and i < pixels.len: pixels[i] = p[y * w + x]
    true
  inputRelays.pollEvent = proc (e: var Event; fl: set[InputFlag]): bool =
    if queue.len == 0: return false
    e = queue[0]
    queue.delete(0)
    true
  inputRelays.waitEvent = proc (e: var Event; t: int; fl: set[InputFlag]): bool =
    inputRelays.pollEvent(e, fl)
  inputRelays.getTicks = proc (): int = ticks
  inputRelays.shutdown = proc () = discard
  clipboardRelays.getText = proc (): string = clip
  clipboardRelays.putText = proc (t: string) = clip = t
  fontRelays.openFont = proc (path: string; size: int; style: FontStyles;
                              metrics: var FontMetrics): Font = Font(0)
  fontRelays.closeFont = proc (f: Font) = discard
  fontRelays.getFontMetrics = proc (f: Font): FontMetrics = FontMetrics()
  fontRelays.measureText = proc (f: Font; text: string): TextExtent = TextExtent()
  fontRelays.drawText = proc (f: Font; x, y: int; text: string;
                              fg, bg: Color): TextExtent = TextExtent()
  fontRelays.drawMeasuredText = nil
  systemRelays.places = samplePlaces
  # a window whose frame the app may draw (the 3.1 frame's picture)
  frameRelays.setSystemFrame = proc (on: bool): bool {.nimcall.} = true

proc run(n = 1) =
  var i = 0
  while i < n or queue.len > 0:
    if i > 200:
      echo "too many frames; queue: ", queue.len
      quit 1
    if not beginFrame():
      echo "the app ended"
      quit 1
    view()
    endFrame()
    inc i
    ticks += 16

proc settle(ms: int) =
  ## Frames for `ms` milliseconds of real time: work on other threads (a
  ## folder listed, pictures decoded) gets done.
  let t0 = epochTime()
  while (epochTime() - t0) * 1000 < ms.float:
    run(1)
    os.sleep(15)
  run(2)

proc resize(w, h: int; touch: bool) =
  W = w
  H = h
  touchNow = touch
  pixels = newSeq[uint32](W * H)
  queue.add Event(kind: WindowResizeEvent, x: W, y: H)
  run(2)

# ---- the guide's parts and examples -----------------------------------------------------------------

type
  ShotState = enum
    ssNormal = "Normal", ssTouch = "Touch screen", ssDark = "Dark scheme",
    ssFocused = "Keyboard focus", ssHover = "Mouse over", ssPressed = "Pressed",
    ssOpen = "Clicked / open", ssDisabled = "Disabled"
  Act = enum
    ## What is done to the control before every picture of it.
    acNone, acClick, acRightClick, acRest, acType, acDoubleClick
  Look = object
    ## A picture in a look of its own (a theme, a font, a size).
    label: string
    on, off: proc ()
    w, h: int                 ## 0: the example's
    touch: bool
  Shot = object
    name, part, title, about: string
    apis: seq[string]
    w, h: int
    states: seq[ShotState]
    looks: seq[Look]
    act: Act
    typed: string
    settle: int               ## ms of real time before the pictures
    inline: bool              ## shown where a part's text says {{pictures:name}}
    noPicture: string         ## why there is no picture
    decls, code: string
    draw: proc ()
    reset: proc ()            ## after each picture: the state put back
  Part = object
    title, intro, outro: string

var
  parts: seq[Part]
  shots: seq[Shot]
  shotEnabled = true          ## false while the Disabled picture is drawn
  target: Rect                ## where the mouse goes (`aim` after the widget)
  aimed = false

proc part(title: string; intro = ""; outro = "") =
  parts.add Part(title: title, intro: intro, outro: outro)

template aim() =
  ## The widget drawn last is the one the mouse goes to.
  target = ui.lastRect
  aimed = true

template aimAt(fx, fy: float) =
  ## The mouse goes to this point of the widget drawn last (fractions of
  ## its width and height).
  target = rect(ui.lastRect.x + int(ui.lastRect.w.float * fx),
                ui.lastRect.y + int(ui.lastRect.h.float * fy), 0, 0)
  aimed = true

const
  std3 = @[ssNormal, ssTouch, ssDark]
  basic = @[ssNormal, ssTouch, ssDark, ssFocused, ssHover, ssPressed, ssDisabled]
  basicNoHover = @[ssNormal, ssTouch, ssDark, ssFocused, ssPressed, ssDisabled]
  input4 = @[ssNormal, ssTouch, ssDark, ssFocused, ssDisabled]
  focus4 = @[ssNormal, ssTouch, ssDark, ssFocused]
  popup4 = @[ssNormal, ssTouch, ssDark, ssOpen]

template example(nm, ttl, ab: string; ww, hh: int; apiNames: openArray[string];
                 st: seq[ShotState]; body: untyped) =
  shots.add Shot(name: nm, part: parts[^1].title, title: ttl, about: ab, apis: @apiNames,
                 w: ww, h: hh, states: st, code: astToStr(body), draw: proc () = body)

template example(nm, ttl, ab: string; ww, hh: int; apiNames: openArray[string];
                 st: seq[ShotState]; setup, body: untyped) =
  setup
  shots.add Shot(name: nm, part: parts[^1].title, title: ttl, about: ab, apis: @apiNames,
                 w: ww, h: hh, states: st, decls: astToStr(setup), code: astToStr(body),
                 draw: proc () = body)

proc opts(act = acNone; typed = ""; settle = 0; inline = false; noPicture = "";
          looks: seq[Look] = @[]; reset: proc () = nil) =
  ## More about the example just made.
  shots[^1].act = act
  shots[^1].typed = typed
  shots[^1].settle = settle
  shots[^1].inline = inline
  shots[^1].noPicture = noPicture
  shots[^1].looks = looks
  shots[^1].reset = reset

proc look(label: string; on, off: proc (); w = 0; h = 0; touch = false): Look =
  Look(label: label, on: on, off: off, w: w, h: h, touch: touch)

# ======================================================================================================
# Getting started
# ======================================================================================================

part("Getting started", """
### Install

You need **Nim 2.0 or newer** and **a C compiler** (on Windows `choosenim`
brings MinGW-w64; on macOS `xcode-select --install`; on Linux `gcc` or
`clang` from your package manager; in Termux `pkg install nim clang`).
Then:

```sh
nimble install retroui                  # the library and its tools
retrokit doctor                       # checks what your machine has, and says how to fix it
retrokit new myapp --kind:business    # a ready app: hello, form, business, files, charts
cd myapp && nimble run
```

Nothing else to install: no GTK, Qt, SDL or browser engine. The fonts,
icons, PDF writer and decoders are built in, and only what an app calls
is linked.

### A first app

```nim
import retroui

var name = "World"
var greeting = ""

app "Hello", 320, 120:
  row([50, -1]):
    label "&Name:"
    edit name
  row:
    if button("&Greet", isDefault = true):
      greeting = "Hello, " & name & "!"
    if button("E&xit"): quitApp()
  label greeting
```

{{pictures:hello}}

`app` opens the window and runs its block once per frame, until the window
is closed. On a phone the app takes the whole screen.

### How immediate mode works

- **Controls are calls.** The UI is plain code that runs every frame. A
  control draws itself where the layout puts it and returns what happened.
  There are no widget objects to make, keep or free, and no callbacks.
- **A click is a `true`.** `if button("OK"): save()` -- `button` returns
  true in the frame it is clicked. `checkbox`, `edit`, `slider` and the
  others return true when they changed something.
- **Your variables hold the state.** `edit name` edits `name` in place;
  `checkbox("&Bold", bold)` flips `bold`; `listbox(items, sel)` moves
  `sel`. What your code draws is what the screen shows, so the screen is
  never out of step with your data.
- **Ids come by themselves.** A control is known by the variable it is
  bound to, or by its label (two "OK" buttons in one frame are told apart
  by their order). When a loop draws the same controls for each row, give
  each row its own id: `withId(i): ...` (or `pushId(i)` ... `popId()`).
  Some controls take a `key` for the same purpose.
- **Frames only when needed.** A frame runs when input comes, when a timer
  asks for one (`wakeIn(ms)`), or when work on another thread is done.
  Between frames the app sleeps. An unchanged frame is not drawn at all.
- **Mouse, keyboard and fingers.** Every control takes all three: Tab and
  the arrows, Space and Enter, `&` letters with Alt; a tap, a drag to
  scroll, a long press for the menu.

### The app's options

`app` takes options by name after the size, all optional:

```nim
const ledgerIcon = staticRead("ledger.png")

app "Ledger", 900, 600,
    theme = Dark,          # the colors (builtinThemes, or a Theme of your own)
    frame = wfClassic,     # wfAsBuilt (the default), wfSystem, wfClassic (Windows 3.1's)
    userFrame = true,      # the user may switch the frame (kept for the app)
    gpu = gmAuto,          # gmAuto, gmGpu, gmCpu
    scale = 125,           # the size of everything, in percent
    font = ufSans,         # the UI's font: ufSans, ufSerif, ufMono
    zoom = 0,              # whole-pixel magnification (0: the display's)
    id = "ledger",         # the app's name for what the toolkit keeps for it
    icon = ledgerIcon,     # the window's picture (a PNG's bytes)
    look = "ledger":       # keep the look the user picks (appearanceSettings)
  label "Hello"
```

A misspelled option is a compile error that lists them all. `RETRO_FRAME`,
`RETRO_GPU`, `RETRO_SCALE`, `RETRO_THEME`, `RETRO_SIZE` and `RETRO_ZOOM`
win over them when the app starts: handy for trying a phone's size on a
desktop (`RETRO_SIZE=420x840 RETRO_TOUCH=1 ./myapp`).

An app that runs its own frame loop calls `openApp` with the same options:

```nim
openApp("Hello", 320, 120, look = "hello")
while beginFrame():
  captionBar()
  label "Hello"
  endFrame()
  appFrameDone()
closeApp()
```

### Building and running

```sh
nim c -r -d:release -d:useMalloc hello.nim   # build and run
retrokit run hello.nim                       # the same, in one word
retrokit small hello.nim                     # the smallest build: optimized for size, stripped
retroapk hello.nim --install                 # an Android APK (on a phone, in Termux)
```

Build with `-d:useMalloc` (or put `switch("define", "useMalloc")` in your
`config.nims`): with it the memory a program lets go of goes back to the
system. From a clone of the repository, `nimble gallery` runs every
control in one window, and `nimble files`, `nimble ledger`, `nimble mail`
the bigger examples.

**Android, iOS, Windows from Linux, signing:** step by step in
[BUILDING.md](../BUILDING.md). An APK needs no Java, Gradle or Android
SDK, and no NDK when the computer has clang with lld, or zig.
""")

var helloName = "World"
var helloGreeting = "Hello, World!"
example("hello", "A first app", "", 320, 110, [], std3):
  row([50, -1]):
    label "&Name:"
    edit helloName
  row:
    if button("&Greet", isDefault = true):
      helloGreeting = "Hello, " & helloName & "!"
    if button("E&xit"): discard
  label helloGreeting
opts(inline = true)

# ======================================================================================================
# Layout
# ======================================================================================================

part("Layout", """
Controls go down the window, one under the other. `row` puts them side
by side, `col` stacks them inside a row, and groups, cards, forms, tabs and
splitters hold them. Sizes are **design pixels**: they grow with the
screen's density and with the size the user picks, so the same numbers fit
a phone, a laptop and a 4K screen. The window's content scrolls when it is
taller or wider than the window, always with the standard scroll bars.
""")

example("rows", "Rows and columns",
        "`row` puts controls side by side at their own widths; when the row is full they wrap. `col` makes a column inside a row.",
        360, 110, ["row", "col", "rowPx"], std3):
  var colA = true
  var colB = false
do:
  row:
    button "One"
    button "Two"
    button "Three"
  row:
    col:
      label "A column"
      checkbox("in a row", colA)
    col:
      label "Another one"
      checkbox("beside it", colB)

example("rowwidths", "Widths in a row",
        "`row([widths])` gives each control its width: a number is fixed, -1 shares the room left, -2 takes two shares, 0 is the control's own width.",
        380, 100, [], std3):
  var firstName = "Sultan"
  var lastName = "Al Isaiee"
  var docPath = "Documents/Budget.csv"
do:
  row([80, -1]):
    label "Name:"
    edit firstName
  row([80, -1, -2]):
    label "Shares:"
    edit firstName
    edit lastName
  row([80, 0, -1]):
    label "Own width:"
    button "Browse..."
    edit docPath

example("spring", "spring and space",
        "`spring()` pushes what comes after it to the row's right end: the place for OK and Cancel. `space(px)` leaves room, down in a column or right in a row.",
        380, 90, ["spring", "space"], std3):
  row:
    label "Total: 120.000"
    spring()
    button("OK", isDefault = true)
    button "Cancel"
  space(12)
  row:
    button "Left"
    space(40)
    button "After a space"

example("group", "Groups, cards and separators",
        "A group box frames controls that belong together, as a 3.1 dialog does. A card is a raised panel with a title: the tiles of a dashboard. `separator` draws an etched line.",
        380, 130, ["group", "card", "separator"], std3):
  row([-1, -1]):
    group("Group box"):
      label "In a 3.1 group box"
    card("Card"):
      label "A raised panel"
  separator()
  label "Under a separator"

example("form", "Forms and fields",
        "`form` lines up labels and their controls in two columns (0: the labels as wide as the longest). On a phone the label goes above its control.",
        340, 120, ["form", "field"], std3):
  var customer = "Al Noor Trading"
  var invoiceAmount = 1234.5
  var paid = true
do:
  form 0:
    field "&Customer:": edit customer
    field "&Amount:": numberEdit invoiceAmount
    field "": checkbox("&Paid", paid)

example("adaptive", "adaptive, and the window's size",
        "`adaptive(minW)` makes as many equal columns as fit, each at least `minW` wide, and its cards flow through them. Three columns on a desktop, one on a phone, from the same code. `isCompact`, `sizeClass` and `responsive` tell the code how much room there is.",
        520, 130, ["adaptive", "responsive", "isCompact", "sizeClass", "columnsFor", "dp"], std3):
  adaptive(140):
    card("Sales"): label "OMR 1,240"
    card("Stock"): label "312 items"
    card("Orders"): label "18 open"
opts(looks = @[look("A desktop window", proc () = discard, proc () = discard),
               look("A phone", proc () = discard, proc () = discard, w = 230, h = 260, touch = true)])

example("scroll", "Scrolling: scrollPanel, panel, pane",
        "The window's page scrolls by itself. `scrollPanel(height)` scrolls a part of it, in a frame; `panel` is a framed white page down to the bottom (a page beside a tree, as in File Manager); `pane` scrolls on the dialog's face. `withId` gives the rows drawn by a loop ids of their own. Rows you draw yourself cost on every frame, each one: `visibleRows` draws only those in view and keeps the others' room, so a list of thousands costs what fits on the screen.",
        340, 140, ["scrollPanel", "panel", "pane", "visibleRows", "revealInPanel", "withId", "pushId"], std3):
  var scrollChecks = newSeq[bool](20)
do:
  label "Twenty rows in 100 pixels:"
  scrollPanel 100:
    for i in visibleRows(scrollChecks.len):
      withId(i):
        checkbox("Item " & $(i + 1), scrollChecks[i])

example("tabs", "Tabs",
        "Pages of a dialog. `sel` is the page shown; Ctrl+Tab and the arrows move between them. `sameHeight` keeps the pages one height, so the dialog does not jump.",
        340, 110, ["tabs", "setTabLook"], focus4):
  var tabSel = 0
do:
  tabs(tabSel, ["&General", "&Look", "&Advanced"], sameHeight = true):
    label("The page of tab " & $(tabSel + 1))

example("split", "Splitters: split, vsplit",
        "Two panes with a bar between them to drag: side by side (`split`) or one above the other (`vsplit`). `pos` is where the bar is; keep it in your settings.",
        360, 110, ["split", "vsplit", "splitBar"], std3):
  var split1 = 140
  var splitFruits = @["Apple", "Banana", "Cherry", "Dates", "Figs", "Grapes"]
  var splitFruit = 1
do:
  split(split1, 100):
    listbox(splitFruits, splitFruit, rows = -1)
  do:
    paragraph("Drag the bar between the panes.")

example("sidepane", "sidePane",
        "Content with a details pane beside it when there is room, and under it on a phone held upright: the details pane of an explorer, the inspector of an editor.",
        400, 110, ["sidePane", "paneBeside"], std3):
  var paneW = 150
  var paneH = 100
  var paneFruits = @["Apple", "Banana", "Cherry", "Dates"]
  var paneFruit = 0
do:
  sidePane(true, paneW, paneH):
    listbox(paneFruits, paneFruit, rows = -1)
  do:
    factList({"Name": paneFruits[paneFruit], "Kind": "Fruit"})

# ======================================================================================================
# Text
# ======================================================================================================

part("Text", """
Text, headings, links, icons and tips. Text is FreeSans unless the app
chooses another font (see [Looks](#looks)); Arabic is joined and runs right
to left everywhere.
""")

example("label", "label, paragraph, heading",
        "Static text. A `&` before a letter underlines it, and Alt with that letter moves the focus to the control after the label.",
        360, 120, ["label", "paragraph", "heading"], std3):
  heading("Quarterly report", 2)
  label "&Name: (a label with a mnemonic)"
  paragraph("A paragraph wraps to the room it has, as 3.1's static text did.")

example("styledtext", "styledText, link, badge",
        "Text in a style of its own (bold, italic, mono, underlined, larger), a link that is true when clicked, and a small count in a colored badge.",
        360, 90, ["styledText", "link", "badge"], std3):
  styledText("Bold, italic and mono", style(bold = true))
  styledText("Italic, underlined", style(italic = true, underline = true))
  row:
    if link("Open the website"): discard
    badge("3")
    badge("NEW", color(0, 128, 0))

example("icons", "icon, iconLabel, image",
        "The 109 pixel icons of the 3.1 manner (`px...`) and the Nerd Fonts symbols (`nf...`) are text: `icon` draws one, `iconLabel` one with a label. `image` draws an `Icon` at its size.",
        360, 110, ["icon", "iconLabel", "image"], std3):
  row:
    for g in [pxFolder, pxComputer, pxTrashFull, pxWarning, pxPrint, pxSave]: icon(g, size = 2.0)
  iconLabel(pxDocuments, "Documents")
  iconLabel(nfGithub, "Nerd Fonts icons too", iconColor = color(0, 0, 128))
  image(glyphIcon(nfFolderOpen, color(222, 170, 40), 32))

example("tooltip", "tooltip",
        "A tip for the control drawn last, shown when the mouse rests on it. Fingers have no hover, so a touch screen shows none.",
        320, 80, ["tooltip"], std3):
  if button("&Save"): discard
  tooltip "Save the document (Ctrl+S)"
opts(act = acRest)

# ======================================================================================================
# Buttons
# ======================================================================================================

part("Buttons")

example("button", "button",
        "A push button: true in the frame it is clicked. `isDefault` gives it the 3.1 default ring, and Enter clicks it.",
        300, 60, ["button"], basic):
  var okClicks = 0
do:
  row:
    if button("&OK", isDefault = true, enabled = shotEnabled): inc okClicks
    aim()
    button("Cancel", enabled = shotEnabled)

example("picbuttons", "Buttons with a picture",
        "A button with an icon shows it four ways: the text beside it, below it, the icon only (the text becomes its tooltip), or the text only. `glyphPic` makes a Nerd Fonts symbol the picture.",
        420, 80, ["glyphPic"], std3):
  row:
    button("Open", pxOpen, blTextBeside)
    button("Print", pxPrint, blTextBelow)
    button("Save", glyphPic(nfContentSave), blIconOnly)
    button("Text only", pxSave, blTextOnly)

example("segmented", "segmented",
        "A row of joined buttons of which one is down: Day, Week, Month.",
        300, 60, ["segmented"], basicNoHover):
  var view2 = 1
do:
  segmented(["Day", "Week", "Month"], view2, enabled = shotEnabled)
  aim()

example("menubutton", "menuButton, splitButton",
        "A button that drops a menu (`menuButton`: the index chosen, else -1), and a button with two parts (`splitButton`): the left one does the usual thing, the arrow offers the others.",
        340, 140, ["menuButton", "splitButton"], std3):
  row:
    let pick = menuButton("&Export", ["PNG", "JPEG", "-", "PDF"])
    aim()
    if pick >= 0: discard
    let sb = splitButton("&Save", ["Save As...", "Save a Copy..."])
    if sb.clicked: discard
opts(act = acClick)

example("buttonrow", "buttonRow",
        "The buttons at the foot of a dialog, right-aligned, the first the default: the number clicked (from 1), else 0.",
        340, 60, ["buttonRow"], std3):
  case buttonRow(["OK", "Cancel", "Help"])
  of 1: discard
  of 2: discard
  else: discard

example("buttonat", "buttonAt",
        "A button at a place of your own: over a picture, on a bar you lay out yourself. `down` draws it held in.",
        300, 90, ["buttonAt"], std3):
  var mapZoom = 3
do:
  let r = canvas(220, 60)
  fill(r, color(0, 96, 128))
  if buttonAt("zoom-in", rect(r.x + 8, r.y + 8, 30, 24), "+"): inc mapZoom
  if buttonAt("zoom-out", rect(r.x + 42, r.y + 8, 30, 24), "-"): dec mapZoom
  discard buttonAt("layers", rect(r.x + 76, r.y + 8, 30, 24), "", pxPictures, blIconOnly, down = true)

# ======================================================================================================
# Choices
# ======================================================================================================

part("Choices")

example("checkbox", "checkbox",
        "A yes or no, bound to a `bool`: the 3.1 box with its X. True when it flips.",
        300, 70, ["checkbox"], basicNoHover):
  var autoSave = true
  var backups = false
do:
  checkbox("&Auto save", autoSave, enabled = shotEnabled)
  aim()
  checkbox("Keep &backups", backups, enabled = shotEnabled)

example("radio", "radio",
        "One of several: each radio button sets the `int` to its value when clicked.",
        300, 90, ["radio"], basicNoHover):
  var size = 1
do:
  radio("&Small", size, 0, enabled = shotEnabled)
  radio("&Medium", size, 1, enabled = shotEnabled)
  aim()
  radio("&Large", size, 2, enabled = shotEnabled)

example("toggle", "toggle (a switch)",
        "An on/off switch in the manner of 3.1's slide switches. Click, tap or slide it; Space, Left and Right with the focus. `switchAt` is its behavior at a place of your own.",
        300, 60, ["toggle", "switchAt", "switchSize"], basicNoHover):
  var wifi = true
do:
  toggle("&Wi-Fi", wifi, enabled = shotEnabled)
  aim()

example("chips", "chips",
        "Words to turn on and off (filters), each with its x when `closable`: `ev.clicked` and `ev.closed` say which.",
        340, 60, ["chips"], @[ssNormal, ssTouch, ssDark, ssFocused, ssHover]):
  var tags = @["nim", "retro", "ui"]
  var tagOn = @[true, false, false]
do:
  let ev = chips(tags, tagOn, closable = true, enabled = shotEnabled)
  aimAt(0.5, 0.5)
  if ev.clicked >= 0: tagOn[ev.clicked] = not tagOn[ev.clicked]

example("taginput", "tagInput",
        "Tags as chips and a box to type the next one: Enter, a comma or Tab adds it, Backspace in the empty box takes the last one off.",
        340, 60, ["tagInput"], std3):
  var tagList = @["invoice", "paid"]
  var tagText = ""
do:
  tagInput(tagList, tagText)

example("rating", "rating",
        "Stars, one to five: click one, or use the arrows.",
        300, 60, ["rating"], basic):
  var stars = 3
do:
  rating(stars, enabled = shotEnabled)
  aim()

# ======================================================================================================
# Text input
# ======================================================================================================

part("Text input", """
Every text box has Cut, Copy, Paste, Undo and its menu (a right click, a
long press), selects with the mouse, the keyboard and fingers, and takes
Arabic and any text the system's input method gives. Its caret blinks for
`CaretBlinkFor` (10 seconds) after it last moved, then stays shown: a
window left with a text box focused runs no frames.
""")

example("edit", "edit",
        "A one-line text box bound to a `string`: true when the text changed. `password` hides it, `readOnly` lets it be selected and copied only.",
        320, 90, ["edit", "editAt"], input4):
  var name = "Sultan"
  var secret = "hunter2"
do:
  form 0:
    field "&Name:": edit(name, enabled = shotEnabled)
    field "&Password:": edit(secret, password = true, enabled = shotEnabled)

example("editarea", "editArea",
        "Text of several lines, `lines` high (-1: down to the bottom), with its scroll bars.",
        320, 110, ["editArea"], input4):
  var notes = "Line one\nLine two\nLine three"
do:
  editArea(notes, lines = 4, enabled = shotEnabled)

example("searchbox", "searchBox",
        "A box with a magnifier, its hint while empty, and an x that clears it.",
        320, 60, ["searchBox"], input4):
  var query = "invoices"
do:
  searchBox(query, "Search invoices", enabled = shotEnabled)

example("autocomplete", "autocomplete",
        "A text box whose choices that match drop under it as you type: Down and Up pick, Enter or a click takes one.",
        320, 170, ["autocomplete"], std3):
  var acCity = ""
do:
  autocomplete(acCity, ["Muscat", "Muttrah", "Sohar", "Salalah", "Nizwa", "Sur"], w = 200)
  aim()
opts(act = acType, typed = "Mu", reset = proc () = acCity = "")

example("maskededit", "maskedEdit",
        "Typing into a mask: `#` a digit, `A` a letter, `U` an upper-case letter, `X` a letter or digit, `*` anything. `maskRaw` gives what was typed without the mask.",
        320, 60, ["maskedEdit", "maskFormat", "maskFull", "maskRaw"], input4):
  var phone = "96891234"
do:
  row:
    label "&Phone:"
    maskedEdit(phone, "+### #### ####", enabled = shotEnabled)

example("comboedit", "comboEdit",
        "A text box with a list beside it: type anything, or drop the list (Alt+Down, F4, the arrow) and pick. It suggests what begins with what is typed.",
        320, 170, ["comboEdit"], popup4):
  var city = "Ber"
do:
  comboEdit(city, ["Berlin", "Bern", "Beirut", "Muscat", "Sohar"], w = 180, enabled = shotEnabled)
  aim()

example("hotkeyedit", "hotkeyEdit",
        "A box that takes the next key pressed, with Ctrl, Alt and Shift, as a shortcut (\"Ctrl+Shift+S\"). `hotkeyPressed` tells when that shortcut is pressed.",
        320, 60, ["hotkeyEdit", "hotkeyText", "parseHotkey", "hotkeyPressed"], input4):
  var hotkey = "Ctrl+Shift+S"
do:
  row:
    label "&Save as:"
    hotkeyEdit(hotkey, enabled = shotEnabled)

# ======================================================================================================
# Numbers, dates, colors
# ======================================================================================================

part("Numbers, dates, colors", """
Numbers are typed and shown as the user reads them ("1,234.50";
`formatNumber`, `parseNumber`). `Date` is a plain (year, month, day) with
`today()`, `addDays`, `addMonths`, `weekday` and `parseDate`.
""")

example("numbers", "spin, intEdit, numberEdit",
        "Numbers to type: `spin` with its arrows (the wheel and Up/Down too), `intEdit` whole numbers, `numberEdit` decimals with `lo`, `hi` and `decimals`.",
        340, 100, ["spin", "intEdit", "numberEdit"], input4):
  var copies = 2
  var qty = 12
  var amount = 1234.5
do:
  form 0:
    field "&Copies:": spin(copies, 1, 99, enabled = shotEnabled)
    field "&Quantity:": intEdit(qty, enabled = shotEnabled)
    field "&Amount:": numberEdit(amount, enabled = shotEnabled)

example("slider", "slider, progress",
        "A track bar for a value between two ends, and a 3.1 progress bar (0.0 to 1.0).",
        340, 80, ["slider", "progress"], basicNoHover):
  var volume = 40
do:
  slider(volume, 0, 100, enabled = shotEnabled)
  aim()
  progress(0.62)

example("rangeslider", "rangeSlider",
        "A track bar with two thumbs: a range from `lo` to `hi`. Drag either, or the band between them to move both.",
        340, 60, ["rangeSlider"], focus4):
  var priceLo = 120
  var priceHi = 380
do:
  rangeSlider(priceLo, priceHi, 0, 500)

example("popupslider", "popupSlider",
        "A number box with a slider that drops from its arrow, as a tool's options bar has for Opacity: type the number, or press the arrow and drag.",
        280, 110, ["popupSlider"], popup4):
  var opacity = 80
do:
  row:
    label "Opacity:"
    popupSlider(opacity, 0, 100, w = 60)
    aimAt(0.92, 0.5)
opts(reset = proc () = opacity = 80)

example("knob", "knob",
        "A round knob (a volume, a balance): drag up or right to turn it up; the wheel and the arrows too. Its value shows under it.",
        200, 110, ["knob"], focus4):
  var knobVolume = 65
  var knobBass = 30
do:
  row:
    knob(knobVolume, 0, 100, size = 56, label = "Vol")
    knob(knobBass, 0, 100, size = 56, label = "Bass")

example("datepicker", "datePicker",
        "A date field with a calendar that drops down (Alt+Down or F4). Type the date, or pick it.",
        320, 230, ["datePicker"], @[ssNormal, ssTouch, ssDark, ssFocused, ssOpen, ssDisabled]):
  var day = date(2026, 10, 27)
do:
  datePicker(day, enabled = shotEnabled)
  aim()

example("calendar", "calendar",
        "A month to pick a day from: the arrows move the day, Page Up and Page Down the month.",
        300, 210, ["calendar"], focus4):
  var calDay = date(2026, 10, 27)
do:
  calendar(calDay, enabled = shotEnabled)

example("daterange", "dateRange, presetRange",
        "From and to, with the ranges people ask for most (This month, Last year...) in a list.",
        460, 60, ["dateRange", "presetRange"], focus4):
  var fromDay = date(2026, 10, 1)
  var toDay = date(2026, 10, 31)
do:
  dateRange(fromDay, toDay)

example("timepicker", "timePicker",
        "Hours and minutes, each with its spin arrows.",
        300, 60, ["timePicker"], input4):
  var hh = 9
  var mm = 30
do:
  timePicker(hh, mm, enabled = shotEnabled)

example("colorpicker", "colorPicker",
        "The 48 basic colors of the 3.1 Color dialog, a preview and a box for \"#RRGGBB\".",
        320, 180, ["colorPicker", "hexOf", "parseHexColor"], @[ssNormal, ssDark, ssFocused, ssDisabled]):
  var pick = color(0, 128, 128)
do:
  colorPicker(pick, enabled = shotEnabled)

example("colorwell", "colorWell and the Color dialog",
        "A swatch of a color: a click opens the Color dialog -- the basic and custom colors, the spectrum, Hue, Sat, Lum, Red, Green, Blue and \"#RRGGBB\". OK sets the color. The pictures show the dialog after a click.",
        560, 400, ["colorWell", "openColorDialog", "colorDialogResult", "storeCustomColors", "restoreCustomColors"], std3):
  var wellColor = color(30, 120, 200)
do:
  row:
    label "Color:"
    colorWell(wellColor, "label-color", w = 60)
    aim()
opts(act = acClick)

# ======================================================================================================
# Lists and data
# ======================================================================================================

part("Lists and data", """
Lists, grids and trees draw only the rows in view, so 100,000 rows cost
what 20 do. They scroll with the wheel, the scroll bars, the keys and a
finger, select with Ctrl and Shift, and find a row as its first letters are
typed.
""")

example("listbox", "listbox",
        "A list to pick one item from: `sel` is its index. `rows` is its height in items (-1: down to the bottom).",
        260, 130, ["listbox"], @[ssNormal, ssTouch, ssDark, ssFocused, ssHover, ssDisabled]):
  var fruits = @["Apple", "Banana", "Cherry", "Dates", "Figs", "Grapes"]
  var fruit = 1
do:
  listbox(fruits, fruit, rows = 5, enabled = shotEnabled)
  aim()

example("combo", "combo",
        "A drop-down list: one item shown, the list under it when it is opened (a click, Enter, Alt+Down, F4 -- `dropKey` is that key for a control of your own). Typing a letter picks the next item that begins with it.",
        260, 190, ["combo", "dropKey"], @[ssNormal, ssTouch, ssDark, ssFocused, ssOpen, ssDisabled]):
  var comboFruits = @["Apple", "Banana", "Cherry", "Dates", "Figs", "Grapes"]
  var fruitCombo = 2
do:
  combo(comboFruits, fruitCombo, w = 160, enabled = shotEnabled)
  aim()

example("checklist", "checkList",
        "A list whose items each have a check box.",
        260, 110, ["checkList"], input4):
  var checks = @[true, false, true, false]
do:
  checkList(["Cash", "Bank", "Cards", "Vouchers"], checks, rows = 4, enabled = shotEnabled)

example("fontcombo", "fontCombo, fontStyleCombo",
        "Drop-down lists of the font families (the built-in ones and the system's) and of a family's styles, each shown in its own letters. From `retroui/textwidgets`.",
        300, 260, ["fontCombo", "fontStyleCombo", "fontSample"], popup4):
  var fontFamily = "FreeSerif"
  var fontStyle = "Bold"
do:
  row:
    fontCombo(fontFamily, w = 160)
    aim()
    fontStyleCombo(fontFamily, fontStyle, w = 100)

example("grid", "grid",
        "Rows and columns, the rows from a `seq` or from a proc (so a million cost what twenty do). Click a header to sort, drag its edge to size it; F2 or typing edits an `editable` cell.",
        300, 120, ["grid", "column", "sortRows", "gridEdit"], input4):
  var cols = @[column("Item", 130), numberColumn("Qty", 50), numberColumn("Price", 70)]
  var gridSel = 1
do:
  grid(cols, @[@["Paper", "10", "4.50"], @["Ink", "2", "21.00"], @["Pens", "40", "0.80"]],
       gridSel, height = 4, enabled = shotEnabled)

example("datagrid", "grid with cell kinds",
        "The columns of a business screen: numbers, check boxes, status colors, drop-down choices, buttons, bars, links, icons and cells you draw. `style` colors a cell, `rowHeaders` adds the record indicator, `footer` a totals row.",
        600, 150, ["numberColumn", "checkColumn", "colorColumn", "choiceColumn", "buttonColumn", "progressColumn", "linkColumn", "iconColumn", "customColumn", "cellStyle", "namedColor", "isChecked"], focus4):
  var orderCols = @[column("Order", 120), numberColumn("Amount", 70), colorColumn("DA", 30),
                    colorColumn("PD", 30), checkColumn("S", 28),
                    choiceColumn("Store", ["Engineering", "Kitchen", "Cafeteria"], 100),
                    buttonColumn("", 56)]
  var orders = @[@["Pool glass door", "70.000", "green", "green", "1", "Engineering", "Open"],
                 @["Stewarding", "51.800", "green", "blue", "0", "Kitchen", "Open"],
                 @["Bread for canteen", "54.155", "orange", "green", "0", "Cafeteria", "Open"]]
  var orderSel = 0
do:
  grid(orderCols, orders.len, proc (r, c: int): string = orders[r][c], orderSel,
       height = 3, rowHeaders = true,
       style = proc (r, c: int): CellStyle =
         (if c == 1 and r == 0: cellStyle(fg = color(200, 0, 0), bold = true) else: CellStyle()),
       footer = proc (c: int): string =
         (if c == 0: "Total" elif c == 1: "175.955" else: ""))

example("tree", "tree, branch, leaf",
        "A tree view: `sel` is the path of the node picked (\"My computer/Documents\"). A `branch` shows its children while its `bool` is true, so they can be read only when it is opened.",
        260, 150, ["tree", "branch", "leaf", "treeClicked"], focus4):
  var treeSel = "My computer/Documents"
  var treeOpen = true
  var treeOpen2 = false
do:
  tree(treeSel, 7):
    branch("My computer", treeOpen):
      leaf("Documents")
      branch("Pictures", treeOpen2):
        leaf("Holidays")
      leaf("Music")

example("treegrid", "treeGrid",
        "A tree with columns: a chart of accounts, a bill of materials.",
        300, 130, ["treeGrid"], focus4):
  var accCols = @[column("Account", 170), numberColumn("Balance", 90)]
  var accRows = @[TreeRow(level: 0, cells: @["Assets", "15,000.00"], open: true),
                  TreeRow(level: 1, cells: @["Cash", "5,000.00"]),
                  TreeRow(level: 1, cells: @["Bank", "10,000.00"]),
                  TreeRow(level: 0, cells: @["Liabilities", "4,000.00"])]
  var accSel = 1
do:
  treeGrid(accCols, accRows, accSel, height = 4)

example("iconview", "iconView",
        "Items as large pictures with their names under them (the Large icons view), as tiles with a detail line, or as small icons. You draw each picture.",
        360, 150, ["iconView"], focus4):
  var iconSel = 0
  var iconMarked: seq[bool]
do:
  iconView(6, proc (i: int): string = ["Reports", "Budget", "Photos", "Music", "Notes", "Setup"][i],
           proc (i: int; r: Rect) =
             let g = [pxFolder, pxSheet, pxPictures, pxMusic, pxText, pxApp][i]
             image(r.x + (r.w - 32) div 2, r.y + (r.h - 32) div 2, glyphIcon(g, ui.theme.text, 32)),
           iconSel, iconMarked, height = 130)

example("lineview", "lineView",
        "Lines of text from a proc, any number of them: a log, a huge file. Only the lines in view are asked for.",
        340, 110, ["lineView"], @[ssNormal, ssDark, ssFocused]):
  var logSel = 3
do:
  lineView(100000, proc (i: int): string = "2026-10-27 10:" & $(i mod 60) & " request " & $i & " ok",
           logSel, height = 100, numbers = true)

example("duallist", "dualList",
        "Two lists to move items between (the buttons, a double click, Enter), and to order the chosen ones.",
        640, 200, ["dualList"], focus4):
  var avail = @["Cash", "Bank", "Sales"]
  var chosen = @["Rent", "Salaries"]
do:
  dualList(avail, chosen, rows = 5)

example("propertygrid", "propertyGrid",
        "Properties by category: text, numbers, yes/no, choices, colors and dates, with a help line for the one picked.",
        320, 250, ["propertyGrid", "textProp", "numberProp", "intProp", "boolProp", "choiceProp", "colorProp", "dateProp", "infoProp", "valueText"], focus4):
  var props = @[textProp("Name", "Main store", "General", "What the store is called"),
                boolProp("Active", true, "General"),
                choiceProp("Region", ["North", "South", "East"], 1, "General"),
                numberProp("Budget", 1500.5, 2, "Money"),
                colorProp("Label", color(0, 128, 0), "Look")]
  var propSel = 0
do:
  propertyGrid(props, propSel, height = 220)

example("imageview", "imageView",
        "A picture to look at: fitted while `zoom` is 0, else that many screen pixels per picture pixel. The wheel zooms, a double click goes between fitted and actual size, a drag moves it.",
        340, 200, ["imageView"], focus4):
  var beach = loadPicture(getHomeDir() / "Pictures" / "Beach.png")
  var picZoom = 0.0
do:
  imageView(beach, picZoom, height = 180)

# ======================================================================================================
# Progress and status
# ======================================================================================================

part("Progress and status")

example("status", "progressRing, spinner, sparkline, usageBar",
        "A ring of progress, a busy spinner, a small line of numbers, and a bar of how full something is.",
        360, 100, ["progressRing", "spinner", "sparkline", "usageBar"], std3):
  row:
    progressRing(0.62)
    spinner()
    col:
      sparkline([3.0, 5, 4, 7, 6, 9, 8, 11], w = 140, h = 30)
      usageBar(62, 100, w = 140)

example("banner", "banner",
        "A message across the page, with its buttons (the index clicked, or 0 for its x).",
        420, 90, ["banner"], @[ssNormal, ssTouch, ssDark, ssHover]):
  discard banner("A new version is ready.", bkInfo, ["Update"])
  aimAt(0.8, 0.5)
  discard banner("Low on storage: 300 MB left.", bkWarning, closable = false)

example("toast", "toast",
        "A balloon in the style of Windows 95 and 98: pale yellow, with its tail, an icon and a title. It goes away by itself. The pictures show it after the button was clicked.",
        420, 150, ["toast", "dismissToast", "toastShown", "toastArea"], std3):
  if button("&Save"):
    toast("Saved \"Budget.csv\" to Documents.", glyph = pxCheck, title = "Ledger")
  aim()
opts(act = acClick)

example("snackbar", "showSnackbar, snackbar",
        "A bar at the bottom that says what was just done, with one action: the Undo of today's apps. `showSnackbar` asks for it; `snackbar()`, once a frame, draws it and is true when its action is clicked.",
        420, 120, ["showSnackbar", "snackbar", "hideSnackbar", "snackbarShown"], std3):
  if button("&Delete 3 messages"):
    showSnackbar("3 messages deleted")
  aim()
  if snackbar(): discard
opts(act = acClick)

example("ledpill", "led, pill",
        "A small light, lit or dark, with its label; and a word in a colored tag (\"Paid\", \"Overdue\").",
        300, 70, ["led", "pill"], std3):
  row:
    led(true, "Online")
    led(false, "Syncing", color(255, 160, 0))
    pill("Paid", color(0, 140, 0))
    pill("Overdue", color(200, 0, 0))

example("timeline", "timeline",
        "Events down a line: the time, a dot (the current one filled), a title and a line of detail.",
        320, 140, ["timeline"], std3):
  timeline([("09:00", "Order placed", "Al Noor Trading"), ("11:30", "Packed", ""),
            ("14:10", "Shipped", "by courier")], current = 1)

example("emptystate", "emptyState, busyState",
        "What a list shows when it has nothing (an icon, a line, what to do), and while it is loading.",
        360, 110, ["emptyState", "busyState"], std3):
  row([-1, -1]):
    emptyState(pxInbox, "No messages", 100)
    busyState("Loading...", 100)

example("statusbar", "statusbar",
        "The bar at the bottom of the window, of texts: the first takes the spare room. Content above it can fill down to it (`rows = -1`).",
        420, 60, ["statusbar"], std3):
  statusbar("Ready", "NUM", "12:30")

example("statusrow", "statusRow, statusSep",
        "A status bar with controls in it (a zoom field, a menu arrow, texts), its parts parted by `statusSep`.",
        420, 60, ["statusRow", "statusSep"], std3):
  var zoomPct = 100
do:
  statusRow:
    row:
      label "Page 3 of 12"
      statusSep()
      label "Zoom:"
      spin(zoomPct, 10, 400, w = 70)

# ======================================================================================================
# Containers
# ======================================================================================================

part("Containers", """
Groups, cards, forms, tabs, scrolling and splitters are in
[Layout](#layout). Here are the ones that fold and the tabs of documents.
""")

example("expander", "expander",
        "A header that folds away what most people do not need.",
        300, 90, ["expander"], focus4):
  var more = true
do:
  expander("Advanced settings", more):
    label "Hidden until it is opened"

example("accordion", "accordionHeader",
        "Sections of which one is open at a time: true for the open one, so draw its content then.",
        300, 130, ["accordionHeader"], focus4):
  var openSection = 0
do:
  for i, t in ["General", "Advanced", "About"]:
    if accordionHeader(t, i, openSection):
      label("The " & t & " section")

example("tabstrip", "tabStrip (document tabs)",
        "The tabs of open documents, each with its icon and its x, and a + for a new one; tabs can be dragged to order them.",
        400, 60, ["tabStrip"], @[ssNormal, ssTouch, ssDark, ssFocused, ssHover]):
  var docTab = 0
  var docTabs = @["Report.txt", "Notes.md", "Budget.csv"]
do:
  discard tabStrip(docTabs, docTab, [pxText, pxMarkdown, pxSheet])
  aimAt(0.45, 0.5)

# ======================================================================================================
# Menus and bars
# ======================================================================================================

part("Menus and bars")

example("menu", "menubar, menu, menuItem, submenu",
        "The window's menu bar: `menuItem` is true when chosen, with its shortcut, a check mark or disabled. Alt, F10 and the letters work as in 3.1.",
        320, 180, ["menubar", "menu", "menuItem", "submenu", "menuSeparator"], popup4):
  menubar:
    menu "&File":
      discard menuItem("&New", "Ctrl+N")
      discard menuItem("&Open...", "Ctrl+O")
      menuSeparator()
      discard menuItem("&Save", "Ctrl+S", enabled = false)
      discard menuItem("&Word wrap", checked = true)
    menu "&Edit":
      discard menuItem("&Undo", "Ctrl+Z")
  target = rect(8, 2, 30, 14)
  aimed = true

example("contextmenu", "contextMenu",
        "A menu for the control drawn last, opened by a right click, a long press or the menu key. The pictures show it open.",
        320, 150, ["contextMenu"], std3):
  label "Right click here, or hold a finger on it"
  contextMenu:
    discard menuItem("&Copy", "Ctrl+C")
    discard menuItem("&Paste", "Ctrl+V")
    menuSeparator()
    discard menuItem("P&roperties")
opts(act = acRightClick)

example("popupmenu", "popupMenu, openPopupMenu",
        "A menu dropped where you say: under a button, at the mouse. `openPopupMenu(key, x, y)` opens it, `popupMenu(key)` draws its items.",
        300, 140, ["popupMenu", "openPopupMenu", "popupMenuOpen"], std3):
  var sortBy = 0
do:
  if button("&Sort by"):
    openPopupMenu("sort", ui.lastRect.x, ui.lastRect.y + ui.lastRect.h)
  aim()
  popupMenu("sort"):
    if menuItem("&Name", checked = sortBy == 0): sortBy = 0
    if menuItem("&Date", checked = sortBy == 1): sortBy = 1
    if menuItem("&Size", checked = sortBy == 2): sortBy = 2
opts(act = acClick)

example("breadcrumb", "breadcrumb",
        "Where the user is, each part a link back: the index clicked, else -1.",
        380, 60, ["breadcrumb"], @[ssNormal, ssTouch, ssDark, ssHover]):
  breadcrumb(["C:", "Users", "Foxoman", "Documents"])
  aimAt(0.4, 0.5)

example("pager", "pager, stepper",
        "Pages to go through (|< < 3 of 12 > >|), and the steps of a task (Cart, Address, Payment) with the one reached.",
        380, 100, ["pager", "stepper"], focus4):
  var page = 3
  var stepAt = 1
do:
  pager(page, 12)
  discard stepper(["Cart", "Address", "Payment"], stepAt)

example("recordnav", "recordNav",
        "The record navigator of a form: first, previous, \"3 of 20\", next, last, New, Delete and Save (`raNew`, `raSave`...).",
        640, 60, ["recordNav"], focus4):
  var recPos = 2
do:
  discard recordNav(recPos, 20, dirty = true)

example("findbar", "findBar, findIn, replaceAllIn",
        "A bar to find and replace text in: Enter or F3 the next match, Shift+F3 the one before, Esc closes it. The app does the finding with `findIn` and `replaceAllIn`.",
        760, 80, ["findBar", "findIn", "replaceAllIn"], std3):
  var findState = FindState(open: true, what: "cat", replacing: true)
do:
  discard findBar(findState)
opts(reset = proc () = findState.open = true)

# ======================================================================================================
# Dialogs
# ======================================================================================================

part("Dialogs", """
Dialogs are modal, have the 3.1 frame, drag by their titles and scroll
when they are taller than the screen; on a phone they take the screen.
Each is drawn while its `open` is true, and sets it false when it closes,
so `if button("Save as..."): saveOpen = true` is all it takes to show one.
""")

example("msgbox", "msgBox",
        "A message with its icon and buttons: the button clicked (from 1) in the frame it closes, else 0.",
        400, 170, ["msgBox", "msgIcon"], std3):
  var msgOpen = true
do:
  discard msgBox(msgOpen, "Retro Files", "Delete \"Budget.csv\" for good?\nThis cannot be undone.",
                 ["&Delete", "Cancel"], miWarning)
opts(reset = proc () = msgOpen = true)

example("inputbox", "inputBox",
        "A question with a text box: true once, when OK is clicked.",
        400, 160, ["inputBox"], std3):
  var inputOpen = true
  var inputText = "Untitled"
do:
  discard inputBox(inputOpen, "Save as", "&File name:", inputText)
opts(reset = proc () = inputOpen = true)

example("dialog", "dialog",
        "A dialog of your own: any controls in its body. Esc closes it.",
        400, 180, ["dialog"], std3):
  var dlgOpen = true
  var dlgCopies = 2
  var collate = true
do:
  dialog(dlgOpen, "Page setup", 300):
    form 0:
      field "&Copies:": spin(dlgCopies, 1, 99)
      field "": checkbox("&Collate", collate)
    row:
      spring()
      if button("OK", isDefault = true): dlgOpen = false
      if button("Cancel"): dlgOpen = false
opts(reset = proc () = dlgOpen = true)

example("progressbox", "progressBox",
        "A modal box with a progress bar while work goes on: true once when the user cancels.",
        420, 170, ["progressBox"], std3):
  var copying = true
do:
  if progressBox(copying, "Copying", "Copying 12 files to Backup...", 0.45,
                 detail = "Budget 2026.csv"):
    discard
opts(reset = proc () = copying = true)

example("wizard", "wizard, stepDone",
        "A dialog of steps with Back, Next and Finish. `stepDone(false)` keeps Next disabled until the step is filled in.",
        700, 260, ["wizard", "stepDone"], std3):
  var wizOpen = true
  var wizStep = 1
  var street = "Al Khuwair Street"
do:
  discard wizard(wizOpen, "New company", wizStep, ["Name", "Address", "Bank", "Done"], 480):
    label "&Street:"
    edit street
opts(reset = proc () = wizOpen = true)

example("aboutbox", "aboutBox",
        "The About dialog: a banner in the blue of a 1994 Setup screen with the icon, name and version; pages About, What's New and Credits; Copy Info for a report of a fault.",
        500, 400, ["aboutBox"], @[ssNormal, ssDark]):
  var aboutOpen = true
do:
  aboutBox(aboutOpen, "Ledger", "2.0", ["(c) 2026 Foxoman. Small business accounts."],
           glyph = pxSheet, tagline = "Small business accounts",
           whatsNew = ["Invoices in PDF", "Bank files read"], credits = [RetroFontCredit])
opts(reset = proc () = aboutOpen = true)

example("splashbox", "splashBox",
        "The box a program shows while it starts, as the About box looks, with a progress bar of blocks.",
        560, 380, ["splashBox"], @[ssNormal, ssDark]):
  splashBox("Ledger", "2.0", "Small business accounts", glyph = pxSheet, progress = 0.4,
            note = "Reading the accounts...")

example("problembox", "problemBox, reportProblem",
        "Report a Problem: the fault log (or your text) for the user to add what they were doing, then Copy or Send by Email. `problemBox` every frame also opens it by itself after a run that ended in a fault.",
        520, 360, ["problemBox", "reportProblem"], std3):
  if button("&Report a Problem..."):
    reportProblem("The total was wrong after the bank file was read.")
  aim()
  problemBox("Ledger", "2.0")
opts(act = acClick)

example("stoppedscreen", "stoppedScreen, stoppedFrame, stoppedPending, startFresh, showStoppedScreen",
        "What a run that ended in a crash wrote down -- an error nothing caught, a fault of the native code, Java's on Android -- shown when the app starts again, before any of its own code runs (`app` does it; an app with its own frame loop calls `stoppedFrame` first in each frame, and asks `stoppedPending` before bringing back what was open): Copy, Send by Email, Start. `startFresh` is true when the user chose to start without what was open the last time.",
        520, 360, ["stoppedScreen", "stoppedFrame", "stoppedPending", "startFresh", "showStoppedScreen"], std3):
  const report = "--- the app stopped\nSIGSEGV: memory that is not the program's (signal 11) at address 0x0\n" &
                 "  #00 0x7a1c2e4b10 libmain.so+0x14fb10\n  #01 0x7a1c2e3f2c libmain.so+0x14ef2c\n"
  showStoppedScreen(report)
do:
  discard stoppedScreen()
opts(reset = proc () = showStoppedScreen(report))

example("filedialog", "fileDialog (3.1)",
        "The Windows 3.1 Open and Save As dialog: the file name with its list, the folders, the drives and the file types. True once, with `path` set.",
        520, 380, ["fileDialog"], std3):
  var openOld = true
  var oldPath = getHomeDir() / "Documents"
do:
  if fileDialog(openOld, oldPath, fmOpen, ["Text files (*.txt)", "All Files (*.*)"]):
    discard
opts(settle = 300, reset = proc () = openOld = true)

# ======================================================================================================
# App parts
# ======================================================================================================

part("App parts", """
What an app is made of around its content: tool bars, the status bar,
windows in the window, docked panels, the shortcuts the user picks, the
settings page and the parts of a phone app.
""")

example("toolbar", "toolbar, toolButton, toolSeparator",
        "A tool bar of small buttons; those that do not fit go into a \"more\" menu. `down` shows a button held in. Its buttons are one stop of Tab, as in Windows: the arrows go along them, Home and End to the ends, Space or Enter presses the one lit (any run of tool buttons is so: a palette's tools); a window starts at its first box, not at its tool bar. F6 goes to it from the other parts of the window.",
        360, 70, ["toolbar", "toolButton", "toolSeparator"], @[ssNormal, ssTouch, ssDark, ssHover, ssPressed]):
  toolbar:
    toolButton(pxNew, "New")
    aim()
    toolButton(pxOpen, "Open")
    toolButton(pxSave, "Save", enabled = shotEnabled)
    toolSeparator()
    toolButton(pxCut, "Cut")
    toolButton(pxCopy, "Copy")
    toolButton(pxPaste, "Paste", down = true)

example("window", "window",
        "A window of the system's own beside the app's: a tool palette, a second view for another monitor, a preview. It is laid out and drawn as the app's window is, with its own menus and dialogs, at the place in the frame the app draws it; its close button sets the `bool` to false, and it closes when it is no longer drawn. X11, Wayland, Windows and macOS open real windows; on phones, in the browser and on a screen without a desktop it is a dialog over the app.",
        380, 120, ["window", "inWindow", "captionBar"], std3):
  var toolsOpen = true
  var bold = false
do:
  if button("&Tools..."): toolsOpen = true
  window(toolsOpen, "Tools", 240, 160):
    checkbox("&Bold", bold)
opts(noPicture = "The window is the system's: it has the app's look inside a frame of the system's.")

example("windowbox", "windowBox, inert, showMenu, hideMenu",
        "A window drawn inside this one at a rectangle -- its menu bar, tool bar and status bar along the rectangle's edges, its dialogs and menus kept in it -- the way a designer or a guide shows a window. `inert` draws it without input (its dialogs do not take the window's); `showMenu` opens one of its menus as if it was clicked, `hideMenu` closes it again.",
        380, 210, ["windowBox", "inert", "showMenu", "hideMenu"], @[ssNormal, ssDark]):
  let frame = place(available(), 180)
  windowFrame(frame, 4)
  let box = inset(frame, 4)
  inert:
    windowBox(box):
      let shown = showMenu(["&File"])
      menubar:
        menu "&File":
          discard menuItem("&Open...", "Ctrl+O")
          discard menuItem("E&xit")
        menu "&Help":
          discard menuItem("&Contents")
          discard menuItem("&About")
      hideMenu(shown)
      row:
        spring()
        label "A window in the window"
      discard button("OK")
      statusbar("Ready")

example("barbutton", "barButton, setToolbarLook",
        "Tool bar buttons with a picture and a label, shown as the bar's look says: icons only, or the text below or beside them (Explorer's \"Text Labels\"). An app can offer it as a setting.",
        380, 80, ["barButton", "setToolbarLook"], std3):
  setToolbarLook(blTextBelow)
  toolbar:
    if barButton(pxBack, "Back"): discard
    if barButton(pxForward, "Forward"): discard
    toolSeparator()
    if barButton(pxCopy, "Copy", tip = "Copy (Ctrl+C)"): discard
    if barButton(pxDelete, "Delete"): discard

example("customizetoolbar", "customizeToolbar",
        "The Customize Toolbar dialog of Windows 95: the buttons the bar can have, the ones it has, their order, and how labels show. The app keeps the bar as a list of keys (`toolKeys`, `toolKeysText`).",
        620, 420, ["customizeToolbar", "toolKeys", "toolKeysText"], std3):
  var customizing = true
  var barKeys = @["new", "open", "-", "print"]
  var barLook = blTextBelow
  let toolChoices = [ToolChoice(key: "new", label: "New", glyph: pxNew),
                     ToolChoice(key: "open", label: "Open", glyph: pxOpen),
                     ToolChoice(key: "save", label: "Save", glyph: pxSave),
                     ToolChoice(key: "print", label: "Print", glyph: pxPrint),
                     ToolChoice(key: "mail", label: "Mail", glyph: pxMail)]
do:
  if customizeToolbar(customizing, barKeys, toolChoices, ["new", "open", "-", "print"], barLook):
    discard
opts(reset = proc () = customizing = true)

example("mdi", "mdiArea, mdiWindow, mdiWindowMenu",
        "Windows in the window, as in Program Manager: the 3.1 frame, moved by their title bars, sized by their edges, minimized to icons, maximized, Ctrl+F6 to the next. Keep each `MdiWindow` in a global. `mdiWindowMenu` fills a Window menu: Cascade, Tile and the windows.",
        380, 240, ["mdiArea", "mdiWindow", "mdiWindowMenu", "mdiCascade", "mdiTile", "mdiActivate"], std3):
  var mdi1 = MdiWindow(title: "Accounts", r: rect(8, 8, 200, 110), open: true)
  var mdi2 = MdiWindow(title: "Invoices", r: rect(120, 50, 200, 110), open: true)
  var mdi3 = MdiWindow(title: "Notes", open: true, minimized: true)
do:
  mdiArea(-1):
    mdiWindow(mdi1):
      label "Cash   5,000"
      label "Bank  10,000"
    mdiWindow(mdi2):
      label "Invoice 42"
    mdiWindow(mdi3):
      label "Notes"

example("dock", "dockPanels: docked panels",
        "Panels as today's Photoshop docks them, drawn as 1994 drew its palettes: columns of tabbed groups down the right of an `mdiArea`, a column folded to icons, panels dragged between groups or out into floating palettes. The `Dock` keeps where they are (`toJson`, `loadDock`).",
        620, 300, ["dockPanels", "newDock", "addColumn", "addGroup", "dockPanel", "panelHeader"], std3):
  var docDock = block:
    var dk = newDock()
    discard dk.addColumn()
    discard dk.addGroup(0, [dockPanel("props", "Properties", nfSliders),
                            dockPanel("info", "Info", nfInfo)], share = 45)
    discard dk.addGroup(0, [dockPanel("layers", "Layers", nfImageMultiple)], share = 55)
    discard dk.addColumn(iconic = true)
    discard dk.addGroup(1, [dockPanel("history", "History", nfHistory),
                            dockPanel("swatches", "Swatches", nfPalette)])
    dk
  var docWin = MdiWindow(title: "Untitled-1", r: rect(10, 10, 220, 150), open: true)
  var dockOpacity = 80
  var layerOn = [true, true, false]
do:
  mdiArea(-1, "work"):
    mdiWindow(docWin):
      label "The document"
    discard dockPanels(docDock, "work", proc (key: string) =
      case key
      of "props":
        label "Opacity:"
        slider(dockOpacity, 0, 100)
      of "layers":
        for i, n in ["Text", "Shapes", "Background"]:
          checkbox(n, layerOn[i])
      else: label("The " & key & " panel"))

example("palettetabs", "paletteTabs",
        "The tabs of a palette that holds several (Layers, Channels, Paths): the one shown joined to the palette, the others behind it, and the arrow of the palette's menu.",
        320, 70, ["paletteTabs"], std3):
  var palTab = 0
do:
  discard paletteTabs(["Layers", "Channels", "Paths"], palTab)

example("keymap", "keymapEditor, keymapPressed",
        "Shortcuts the user picks: a `Keymap` holds the app's defaults and the user's changes; `keymapEditor` lets them change them; `keymapPressed` says which command's keys were pressed.",
        380, 230, ["keymapEditor", "keymapPressed", "Keymap", "keyFor", "setKey", "storeKeymap", "restoreKeymap"], focus4):
  var keys = Keymap(defaults: @[("Ctrl+N", "New"), ("Ctrl+O", "Open"), ("Ctrl+S", "Save"),
                                ("Ctrl+P", "Print")])
do:
  keymapEditor(keys, ["New", "Open", "Save", "Save As", "Print"], height = 120)
  case keymapPressed(keys)
  of "Save": discard
  else: discard

example("settings", "settingToggle, settingChoice, settingSlider, settingCombo, settingButtons, settingLink",
        "The rows of a settings page, as a phone's or the 3.1 Control Panel's: a title, a line under it and its control at the right.",
        420, 260, ["settingToggle", "settingChoice", "settingSlider", "settingButtons", "settingCombo", "settingLink"], focus4):
  var setOn = true
  var setChoice = 1
  var setLevel = 60
  var setCombo = 0
do:
  settingToggle("Notifications", setOn, "For new messages")
  discard settingChoice("Sync", ["Hourly", "Daily", "Never"], setChoice)
  discard settingSlider("Brightness", setLevel, 0, 100, suffix = "%")
  discard settingCombo("Color scheme", ["Classic", "Ocean", "Desert"], setCombo)
  discard settingButtons("Cache", ["Clear"], "12 MB")

example("appearance", "appearanceSettings",
        "The look of every app in a few rows: the color scheme, the size of everything, the size of the text, controls for a mouse or fingers, the window's frame and the font. `app`'s `look` keeps the user's choice by itself.",
        460, 560, ["appearanceSettings", "storeAppearance", "restoreAppearance"], std3):
  appearanceSettings()

example("avatar", "avatar, factList",
        "A person's initials in a colored circle (true when clicked), and facts as name and value lines.",
        360, 100, ["avatar", "initialsOf", "factList"], std3):
  row:
    avatar("Sultan Al-Said")
    avatar("Maryam Ali")
    col:
      factList({"Orders": "10", "Best month": "May"})

example("bottomnav", "bottomNav, fab",
        "The parts of a phone app: the navigation bar at the bottom and the round floating button.",
        360, 160, ["bottomNav", "fab"], std3):
  var nav = 0
do:
  label "Content"
  discard bottomNav([(pxHome, "Home"), (pxSearch, "Search"), (pxUser, "Me")], nav)
  discard fab(nfPlus, "New")

example("captionbar", "captionBar",
        "The window's 3.1 title bar where the app draws it: on phones and tablets, and on desktops with the 3.1 frame. `app` calls it every frame, so an app has nothing to do. See [The window's frame](#the-windows-frame).",
        360, 60, ["captionBar"], std3):
  captionBar()
opts(noPicture = "Drawn with the window's frame: see the pictures in [The window's frame](#the-windows-frame).")

# ======================================================================================================
# Files
# ======================================================================================================

part("Files", """
What a file manager, an Open dialog or a photo app is made of
(`retroui/filewidgets`). Folders are listed on another thread and pictures
decoded there, so a folder of 50,000 files opens at once. The pictures here
show a sample home folder.
""")

example("filelist", "fileList",
        "The items of a `FolderModel` as rows with columns (`fvDetails`), large icons (`fvIcons`, pictures as thumbnails) or tiles. Selecting, sorting, renaming (F2), type-ahead and drag and drop come with it.",
        640, 200, ["fileList", "newFolderModel", "fileIcon"], focus4):
  var folder = newFolderModel(getHomeDir() / "Documents")
do:
  let ev = fileList(folder, fvDetails, height = 180)
  if ev.activated:
    if ev.item.isDir: folder.open(ev.item.path)
    else: discard openFile(ev.item.path)
opts(settle = 400)

example("fileicons", "fileList: large icons",
        "The same list as icons; pictures show as thumbnails, decoded in the background.",
        480, 200, [], std3):
  var pics = newFolderModel(getHomeDir() / "Pictures")
do:
  discard fileList(pics, fvIcons, height = 180)
opts(settle = 800)

example("foldertree", "folderTree",
        "The places of the device (home, documents, drives) and your favorites, each opening into its folders. Files can be dragged onto them.",
        280, 220, ["folderTree"], focus4):
  var treeFolder = getHomeDir() / "Documents"
do:
  let ev = folderTree(treeFolder, [getHomeDir() / "Documents" / "Invoices"], rows = 10)
  if ev.picked: discard
opts(settle = 300)

example("placesview", "placesView",
        "\"This device\": the places and your favorites as tiles with how full their disks are. The folder clicked, else \"\".",
        480, 260, ["placesView"], std3):
  let f = placesView([getHomeDir() / "Documents" / "Invoices"])
  if f.len > 0: discard
opts(settle = 300)

example("filepreview", "filePreview",
        "The details pane: the file the mouse rests on, else the one selected, else the folder -- its picture or the start of its text, its size and dates, Open, Share and Properties.",
        300, 400, ["filePreview"], std3):
  var preview = newFolderModel(getHomeDir() / "Pictures")
  preview.selectAfterLoad([getHomeDir() / "Pictures" / "Beach.png"])
do:
  discard filePreview(preview)
opts(settle = 800)

example("pathbar", "pathBar",
        "The folder as a row of its folders, as in Explorer: click one to go there, the arrow after it for its folders; a click on the empty part turns it into a box to type a path.",
        480, 50, ["pathBar"], @[ssNormal, ssTouch, ssDark, ssHover]):
  discard pathBar("/home/sultan/Documents/Reports/2026")
  aimAt(0.3, 0.5)

example("drivebar", "driveBar",
        "The drive buttons of File Manager: the places, and your favorites.",
        480, 50, ["driveBar"], @[ssNormal, ssTouch, ssDark, ssHover]):
  discard driveBar(getHomeDir(), [getHomeDir() / "Documents"])

example("filepicker", "filePicker",
        "A modern Open and Save dialog (the whole screen on a phone): places, a path bar, the folder, a preview of the file, and for saving a name. `patterns` limits the files shown; `fmFolder` picks a folder.",
        780, 540, ["filePicker"], std3):
  var pickOpen = true
  var picked = getHomeDir() / "Pictures"
do:
  if filePicker(pickOpen, picked, fmOpen, ["*.png", "*.jpg"]):
    discard
opts(settle = 800, reset = proc () = pickOpen = true)

example("trashlist", "trashList",
        "The system's trash: what was deleted, from where and when, with Restore, Delete forever and Empty the trash.",
        680, 200, ["trashList", "newTrashList"], std3):
  var trashBin = block:
    var t = newTrashList()
    t.reload()
    t
do:
  let te = trashList(trashBin, height = 180)
  if te.changed: discard
opts(settle = 300)

example("properties", "propertiesDialog",
        "The properties of files and folders: where they are, their size (folders are measured while it is open), dates, permissions.",
        460, 380, ["propertiesDialog"], std3):
  var propsOpen = true
  let budget = listFolder(getHomeDir() / "Documents").filterIt(it.name == "Budget 2026.csv")
do:
  propertiesDialog(propsOpen, budget)
opts(settle = 300, reset = proc () = propsOpen = true)

example("runjob", "runJobDialog",
        "Runs a copy, move, delete or zip job a slice a frame with a progress box, and asks Replace, Keep both or Skip when a name is taken (as in the pictures).",
        480, 240, ["runJobDialog", "newJob"], std3):
  var copyJob = newJob(jkCopy, [getHomeDir() / "Documents" / "Letter.txt"],
                       getHomeDir() / "Documents" / "Projects")
do:
  if copyJob != nil and runJobDialog(copyJob, "Copying"):
    copyJob = nil
opts(settle = 200, reset = proc () =
  copyJob = newJob(jkCopy, [getHomeDir() / "Documents" / "Letter.txt"],
                   getHomeDir() / "Documents" / "Projects"))

example("textfileview", "textFileView, hexFileView",
        "A text file of any size, its lines counted a few milliseconds a frame while the first are shown; and any file as hex, read as it is shown.",
        500, 260, ["textFileView", "hexFileView", "openTextFile", "openHexFile"], std3):
  var letter = openTextFile(getHomeDir() / "Documents" / "Letter.txt")
  var letterHex = openHexFile(getHomeDir() / "Documents" / "Letter.txt")
  var lineSel = 0
  var hexSel = 0
do:
  textFileView(letter, lineSel, height = 110)
  hexFileView(letterHex, hexSel, height = 110)
opts(settle = 200)

example("picturebox", "pictureBox",
        "A picture file as a control: busy dots while it is decoded, an icon if it cannot be.",
        340, 130, ["pictureBox"], std3):
  row:
    pictureBox(getHomeDir() / "Pictures" / "Beach.png", w = 140, h = 100)
    pictureBox(getHomeDir() / "Pictures" / "Sunset.png", w = 140, h = 100)
opts(settle = 600)

example("storagedialog", "storageDialog",
        "On Android, the dialog that asks the user to let the app reach the shared storage (`askStorage`). Draw it every frame with the other dialogs; elsewhere it draws nothing.",
        300, 60, ["storageDialog", "askStorage"], std3):
  storageDialog()
opts(noPicture = "It shows only on Android.")

# ======================================================================================================
# Charts
# ======================================================================================================

part("Charts", """
`chart` draws 21 kinds of business chart from a few lines, or straight from
a CSV table. Every chart has round axis numbers, a legend (click an entry to
hide its series), a tooltip (the mouse, a tap or the arrows), and numbers as
money, shares or 1.2K (`NumFormat`). `exportPng` saves one as a picture.
""")

var chMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun"]
var salesTable = parseCsv("Month,Sales,Costs,Staff,Target,Open,High,Low,Close\n" &
                 "Jan,120,80,5,130,10,14,8,12\nFeb,150,95,6,140,12,15,10,11\n" &
                 "Mar,90,70,4,150,11,13,7,9\nApr,180,100,7,160,9,16,8,15\n" &
                 "May,210,120,8,170,15,19,13,18\nJun,250,130,9,180,18,22,16,17")

proc kindCols(k: ChartKind): seq[string] =
  case k
  of chScatter: @["Sales", "Costs"]
  of chBubble: @["Sales", "Costs", "Staff"]
  of chCandle: @["Open", "High", "Low", "Close"]
  of chBullet: @["Sales", "Target"]
  of chPie, chDonut, chFunnel, chTreemap, chWaterfall, chHistogram, chGauge: @["Sales"]
  of chHeatmap: @["Sales", "Costs", "Target"]
  else: @["Sales", "Costs"]

example("chart", "chart",
        "A chart of series over labels. `ev.clicked` and `ev.index` tell which bar, point or slice was clicked (or picked with Enter).",
        440, 240, ["chart", "series", "lineSeries", "xySeries", "ohlcSeries", "chartColors"], @[ssNormal, ssTouch, ssDark, ssFocused, ssHover]):
  chart("Sales by month", chBar, chMonths,
        [series("2025", [120.0, 150, 90, 180, 210, 250]),
         series("2026", [140.0, 170, 130, 190, 240, 280])], height = 220)
  aimAt(0.77, 0.6)

example("chartcombo", "A combo chart",
        "Bars, and a line on a second axis with its own number format. `ChartOpts` sets the titles, axis names, legend, data labels, ranges, bands and colors.",
        440, 240, ["ChartOpts", "NumFormat"], std3):
  chart(chCombo, chMonths,
        [series("Revenue", [120.0, 150, 90, 180, 210, 250]),
         lineSeries("Margin", [0.21, 0.25, 0.18, 0.27, 0.3, 0.33])],
        ChartOpts(title: "Revenue and margin", format: NumFormat(prefix: "$", suffix: "K"),
                  format2: NumFormat(percent: true), dataLabels: false), height = 220)

example("gauge", "gauge",
        "One value on a dial, with a target and bands.",
        260, 200, ["gauge"], std3):
  gauge("Sales vs target", 78, hi = 100, target = 90, format = NumFormat(suffix: "%"),
        height = 180)

example("simplecharts", "barChart, lineChart, pieChart",
        "The quick ones: a list of numbers as bars, lines or slices, in one call.",
        620, 200, ["barChart", "lineChart", "pieChart"], std3):
  row([-1, -1, -1]):
    barChart([12.0, 18, 9, 22], ["Q1", "Q2", "Q3", "Q4"], title = "Orders")
    lineChart([@[3.0, 5, 4, 7, 6], @[2.0, 3, 5, 4, 6]], ["M", "T", "W", "T", "F"],
              ["Sohar", "Muscat"], title = "Guests")
    pieChart([45.0, 30, 25], ["Rooms", "Food", "Spa"], title = "Revenue")

example("chartkinds", "The 21 kinds of chart",
        "Every kind from one CSV table: `chart(title, kind, table, labelColumn, valueColumns)`. `readCsv` reads a file (comma, semicolon or tab; quotes; a BOM); `writeCsv` saves one.",
        960, 1200, ["parseCsv", "readCsv", "writeCsv", "toCsv", "csvLine", "csvField", "tableSeries", "exportPng"], @[ssNormal]):
  adaptive(230):
    for k in ChartKind:
      card($k):
        chart("", k, salesTable, "Month", kindCols(k), height = 150)

example("livegraph", "liveGraph",
        "A task manager's graph: the last values, the newest at the right, on a grid that moves with them. Give it a number that grows by one with each new value: the picture is kept and moved a step, only the new part drawn -- a frame costs a copy, however many values (retroui/sysmon reads the numbers).",
        440, 120, ["liveGraph"], std3):
  var lgValues: seq[float]
  for i in 0 ..< 60: lgValues.add 35 + 25 * sin(i.float / 4) + float((i * 37) mod 11)
do:
  liveGraph("guide", lgValues, 60, h = 100, label = "% Utilization", caption = "60 seconds")

# ======================================================================================================
# Planning and dashboards
# ======================================================================================================

part("Planning and dashboards", """
What a project, sales or service app shows its work with. They take the
mouse, the keyboard and fingers, and draw only what is in view, so
thousands of tasks or cards stay quick.
""")

example("kpi", "kpiTile, statCard, kpiRow",
        "The numbers of a dashboard: a value with its change (green or red), a target and a sparkline; `kpiRow` wraps them to the width.",
        660, 150, ["kpiTile", "statCard", "kpiRow"], focus4):
  kpiRow:
    kpiTile("Revenue", "OMR 84,120", 0.125, "vs last month",
            trend = [3.0, 4, 3.5, 5, 6, 5.5, 7], target = 0.68)
    kpiTile("Complaints", "12", -0.2, "vs last month", lowerIsBetter = true,
            color = color(219, 68, 55))
    statCard(pxUser, "Guests", "214", "38 arriving today", color(15, 157, 88))

example("kanban", "kanbanBoard",
        "Lanes of cards: drag a card to another lane (a finger: hold, then move), or Ctrl and the arrows; Enter opens it. A lane can have a work limit.",
        640, 260, ["kanbanBoard"], focus4):
  var kanbanLanes = @[
    KanbanLane(title: "To do", cards: @[
      KanbanCard(title: "Price list", detail: "For the new menu", tag: color(219, 68, 55),
                 who: "Sultan Al-Said", due: date(2026, 10, 30)),
      KanbanCard(title: "Staff rota", who: "Amal Z")]),
    KanbanLane(title: "Doing", limit: 2, cards: @[
      KanbanCard(title: "Pool repair", detail: "Pump and filter", tag: color(66, 133, 244))]),
    KanbanLane(title: "Done", cards: @[KanbanCard(title: "Fire drill")])]
  var kanbanSel: KanbanPos = (0, 0)
do:
  kanbanBoard(kanbanLanes, kanbanSel)

example("gantt", "ganttView",
        "Tasks on a day, week or month scale, with weekends and today marked, parts that fold and links between tasks. Drag a bar to move it, its ends to change its dates.",
        680, 200, ["ganttView"], focus4):
  var ganttTasks = @[
    GanttTask(name: "Opening", start: date(2026, 10, 20), finish: date(2026, 11, 12)),
    GanttTask(name: "Kitchen", start: date(2026, 10, 20), finish: date(2026, 10, 28),
              progress: 0.7, level: 1, color: color(219, 68, 55)),
    GanttTask(name: "Rooms", start: date(2026, 10, 25), finish: date(2026, 11, 4),
              progress: 0.3, level: 1, deps: @[1]),
    GanttTask(name: "Soft opening", start: date(2026, 11, 10), finish: date(2026, 11, 10),
              level: 1, milestone: true, deps: @[2])]
  var taskSel = 1
  var ganttScale = gsDay
do:
  ganttView(ganttTasks, taskSel, ganttScale)

example("agenda", "agendaView",
        "Appointments by month, week or day; drag one to move it, its edge to make it longer.",
        600, 330, ["agendaView"], focus4):
  var agendaItems = @[
    Appointment(title: "Audit", day: date(2026, 10, 27), start: 9 * 60, finish: 11 * 60),
    Appointment(title: "Holiday", day: date(2026, 10, 29), allDay: true, color: color(15, 157, 88)),
    Appointment(title: "Review", day: date(2026, 10, 28), start: 14 * 60, finish: 15 * 60 + 30)]
  var agendaDay = date(2026, 10, 27)
  var agendaMode = amMonth
do:
  agendaView(agendaItems, agendaDay, agendaMode)

example("orgchart", "orgChart",
        "Who reports to whom, as boxes and lines; branches fold.",
        560, 240, ["orgChart"], focus4):
  var orgStaff = @[
    OrgNode(name: "Amal Al-Harthy", title: "General manager", parent: -1),
    OrgNode(name: "Badr Al-Kindi", title: "Rooms", parent: 0, color: color(66, 133, 244)),
    OrgNode(name: "Dana Al-Said", title: "Food & beverage", parent: 0, color: color(219, 68, 55)),
    OrgNode(name: "Eid Saleh", title: "Front office", parent: 1),
    OrgNode(name: "Huda Nasser", title: "Restaurant", parent: 2)]
  var orgSel = 0
do:
  orgChart(orgStaff, orgSel)

# ======================================================================================================
# Maps and 3D
# ======================================================================================================

part("Maps and 3D")

example("mapview", "mapView",
        "A world map with values by country (colored), markers and routes; it pans, zooms (the wheel, a pinch) and says which country is under the mouse. The map is built in: no tiles, no network.",
        600, 320, ["mapView", "cityMarker", "fitTo", "zoomTo", "resetView", "countryName", "countryCode", "latLonOf"], @[ssNormal, ssTouch, ssDark, ssHover]):
  var worldMap = MapState()
do:
  mapView(worldMap, height = 300,
          values = [("OM", 120.0), ("AE", 340.0), ("SA", 510.0), ("IN", 800.0),
                    ("GB", 380.0), ("US", 950.0)],
          markers = [cityMarker("Muscat", size = 6), cityMarker("London")],
          routes = [MapRoute(fromLat: 23.59, fromLon: 58.41, toLat: 51.51, toLon: -0.13)],
          legendTitle = "Sales")
  aimAt(0.24, 0.5)

var
  modelScene = Scene3()
  modelCam = camera3()
  barsScene = bars3d(@[@[12.0, 18, 9, 22], @[8.0, 14, 16, 11]], ["North", "South"],
                ["Q1", "Q2", "Q3", "Q4"], showValues = true)
  barsCam = camera3(yaw = 30, pitch = 28)
block:
  var b = box(1.2, 0.6, 0.8, color(0, 0, 160), name = "Base")
  b.edges = true
  discard modelScene.add b
  var sp = sphere(0.45, color(200, 0, 0), name = "Ball")
  sp.pos = vec3(0, 0.75, 0)
  discard modelScene.add sp
  modelScene.addGrid(4, 8, -0.3)
  fitView(modelScene, modelCam)
  fitView(barsScene, barsCam)

block:
  # a vector map of a coast of our own, as a folder of tiles (no network)
  var w: MvtWriter
  w.addFeature("water", mgPolygon, [@[(0, 0), (4096, 0), (4096, 1500), (2600, 1900), (1500, 2500),
                                      (0, 2300), (0, 0)]])
  w.addFeature("landuse", mgPolygon, [@[(2600, 2600), (3500, 2600), (3500, 3400), (2600, 3400), (2600, 2600)]],
               {"class": "park"})
  w.addFeature("transportation", mgLine, [@[(0, 3000), (1800, 2800), (4096, 3200)]], {"class": "motorway"})
  w.addFeature("transportation", mgLine, [@[(1200, 2600), (1300, 4096)], @[(2200, 2200), (2400, 4096)]],
               {"class": "primary"})
  w.addFeature("place", mgPoint, [@[(1500, 2900)]], {"class": "city", "name": "Muscat"})
  w.addFeature("place", mgPoint, [@[(3300, 3700)]], {"class": "town", "name": "Seeb"})
  w.addFeature("transportation_name", mgLine, [@[(0, 3000), (1800, 2800), (4096, 3200)]], {"name": "Route 1"})
  # (the tile of zoom 12 where Muscat is: the guide shows it larger)
  let tiles = sampleRoot / "tiles"
  createDir(tiles / "12" / "2712")
  writeFile(tiles / "12" / "2712" / "1771.pbf", w.toMvt())

example("tilemap", "tileMap",
        "A street map from any map service (OpenStreetMap, Google, Azure Maps, Mapbox, HERE, MapTiler, Esri, TomTom, Stadia, AMap, Tencent, Tianditu) or maps of your own (PMTiles, MBTiles, a folder; vector tiles drawn by the kit): dragged, zoomed with the wheel, fingers, keys and its buttons, with markers, lines, areas, circles and routes over it. Places and routes come from `retroui/geo`. The picture is a vector tile of the guide's own.",
        600, 320, ["tileMap", "fitBounds", "fitPoints", "centerOn", "metersPerPixel", "mapPointOf",
                   "routeShape", "geoJsonShapes", "keepArea", "tilesIn", "loadingTiles", "clearTileCache",
                   "osmTiles", "openTopoMap", "cartoTiles", "googleTiles", "azureTiles", "mapboxTiles",
                   "mapboxVector", "hereTiles", "mapTilerTiles", "mapTilerVector", "protomapsVector",
                   "esriTiles", "tomTomTiles", "stadiaTiles", "amapTiles", "tencentTiles", "tiandituTiles",
                   "pmtilesSource", "mbtilesSource", "folderSource", "tileJsonSource", "mapKitPage",
                   "googleMapsPage", "tileUrl", "quadkey"], @[ssNormal, ssTouch, ssDark]):
  var coast = TileMapState(lat: 23.59341, lon: 58.40332, zoom: 13.25)
  let coastTiles = folderSource(sampleRoot / "tiles", "pbf", maxZoom = 12, attribution = "The guide's own map")
do:
  tileMap(coast, coastTiles, height = 300,
          markers = [MapMarker(lat: 23.59046, lon: 58.38512, label: "Office")],
          shapes = [MapShape(kind: msLine, points: @[(23.59046, 58.38512), (23.59636, 58.42804)], label: "Delivery")])
opts(settle = 1500)

example("view3d", "view3d",
        "A 3D view of meshes and models (OBJ, STL): boxes, spheres, cylinders, cones and planes, a grid and axes. Drag to turn it, the wheel to zoom.",
        380, 260, ["view3d", "box", "sphere", "cylinder", "cone", "plane", "loadModel", "addGrid", "addAxes", "addShadow", "fitView", "camera3", "render3d"], focus4):
  view3d(modelScene, modelCam, height = 240)

example("model3d", "Models: parts and clips",
        "A model's parts are nodes the app finds by name and moves, turns, hides and tints; its clips play. Models come from Blender and every 3D tool as glTF (`loadGltf` in `retroui/gltf`; a `.blend` through Blender: `loadModel3`, or once with `retrokit model`), or are made in code. The picture is a car made in code, its door's clip half played.",
        380, 260, ["play", "stop", "isPlaying", "animate", "seekAnimation", "animationNames", "nodeNames",
                   "setVisible", "tint", "turnNode", "moveNode", "recolor", "findNode", "newNode", "addNode",
                   "loadGltf", "loadModel3", "toGlb", "view3dOnGpu", "view3dPicture"], @[ssNormal, ssDark]):
  var car3d = carScene()
  var car3dCam = camera3(yaw = 35, pitch = 18)
  fitView(car3d, car3dCam)
  car3d.seekAnimation("DoorOpen", 0.6)
do:
  view3d(car3d, car3dCam, height = 240)

example("bars3d", "bars3d",
        "A 3D bar chart, shown in a `view3d`.",
        380, 260, ["bars3d"], @[ssNormal, ssDark]):
  view3d(barsScene, barsCam, height = 240)

# ======================================================================================================
# HTML, Markdown and rich text
# ======================================================================================================

part("HTML, Markdown and rich text", """
`htmlView` draws a safe subset of HTML and CSS itself: no browser engine, no
scripts. `webView` shows a web page with the system's own browser engine
when you choose it (`engine = weSystem`, or `RETRO_WEB=system`): WebView2 on
Windows, WKWebView on macOS and iOS, WebKitGTK on Linux and BSD, and always
in an Android app its WebView. Its scripts run and talk to your app. With
the kit's own engine local pages are drawn by the kit and a page on the web
gets a button that opens it in the browser.
""")

example("htmlview", "htmlView, htmlBlock",
        "HTML: headings, paragraphs, bold, colors, tables, lists, pictures and links (reported when clicked). `htmlBlock` is the same without its own scroll bar, as a part of a page.",
        420, 230, ["htmlView", "htmlBlock", "htmlToMarkdown"], focus4):
  htmlView("<h3>Sales <u>report</u></h3><p>Up <b>12%</b>, costs " &
           "<span style=\"color:#c00\">down</span>, <mark>new store</mark> open.</p>" &
           "<table><tr><th>Month</th><th align=right>Sales</th></tr>" &
           "<tr><td>August</td><td align=right>1,020</td></tr>" &
           "<tr><td>September</td><td align=right>980</td></tr></table>" &
           "<ul><li>North<li>South</ul>", height = 210)

example("webview", "webView, webRun, webPost",
        "A web page in the window. With the system's engine (`engine = weSystem`; the default in an Android app) the page is the system's browser placed over the widget: scripts, forms, video, its own Back and Forward. Its scripts talk to the app: `retro.post(text)` in the page comes in `messages`, `webPost` sends a `retro` event to the page, `webRun` runs a script and its answer comes in `results`. `webAllow` keeps it to the hosts you trust, `webZoom` sizes it. The picture is the kit's own engine (the system's view is drawn by the system, not here).",
        420, 220, ["webView", "webGoBack", "webGoForward", "webReload", "webStop", "webRun",
                   "webPost", "webAllow", "webZoom", "webClose", "webPermit", "webPrint",
                   "webAppFolder", "webAppUrl"], std3):
  let ev = webView("html:<title>Order 1042</title><h3>Order 1042</h3>" &
                   "<p>Ready to <b>ship</b> on Sunday.</p><ul><li>12 chairs<li>2 tables</ul>",
                   height = 150, key = "order", engine = weSystem)
  row([70, 70, -1]):
    if button("&Back", enabled = ev.canGoBack): webGoBack("order")
    if button("&Ask"): webRun("order", "document.title")
    label ev.title                # (an answer of webRun: ev.results)

example("markdownview", "markdownView, markdown",
        "Markdown: headings, emphasis, code, lists, task lists (a click ticks them: `toggleTask`), tables, quotes and links -- right to left where they are in Arabic. Screen readers read its words (`mdPlainText`).",
        420, 230, ["markdownView", "markdown", "mdPlainText"], focus4):
  markdownView("# Notes\n\nSome **bold**, *italic* and `code`.\n\n" &
               "- [x] Invoices sent\n- [ ] Stock count\n\n" &
               "| Item | Qty |\n|---|--:|\n| Paper | 10 |\n| Ink | 2 |\n", height = 210)

example("richedit", "richEdit, richToolbar",
        "A rich text editor (bold, italic, colors, sizes, lists, quotes, links, alignment) with its tool bar; it reads and writes HTML (`richFromHtml`, `toHtml`) and checks spelling where the system can. From `retroui/richedit`.",
        640, 280, ["richEdit", "richToolbar", "richFromHtml", "richDoc", "toHtml", "toPlainText"], focus4):
  var letterDoc = richFromHtml("<p>Dear <b>Maryam</b>,</p><p>The new <i>price list</i> is " &
                               "<span style=\"color:#c00000\">ready</span>:</p>" &
                               "<ul><li>Rooms</li><li>Food</li></ul><p>Sultan</p>")
do:
  richToolbar(letterDoc)
  richEdit(letterDoc, height = 180)

# ======================================================================================================
# Canvas and reports
# ======================================================================================================

part("Canvas and reports")

example("canvas", "canvas: your own drawing",
        "Room for your own drawing: draw into the rectangle it returns with `fill`, `box`, `line`, `text`, `image`, `drawBitmap`, and the smooth `disc`, `ring`, `roundRect`, `polygon`, `thickLine`, `pieSlice`.",
        320, 140, ["canvas", "gfx.fill", "gfx.box", "gfx.line", "gfx.disc", "gfx.roundRect", "gfx.drawBitmap"], std3):
  let r = canvas(280, 110)
  fill(r, color(255, 255, 240))
  box(r, ui.theme.frame)
  roundRect(rect(r.x + 12, r.y + 12, 100, 40), 8, color(0, 0, 128))
  text(r.x + 26, r.y + 24, "Drawn", color(255, 255, 255), true)
  disc(float(r.x + 180), float(r.y + 55), 30, color(200, 0, 0))
  line(r.x + 12, r.y + 90, r.x + 268, r.y + 70, color(0, 128, 0))

example("canvas2d", "canvas2d (the HTML5 Canvas 2D API)",
        "The whole HTML5 Canvas 2D API in Nim: paths, curves, gradients, patterns, shadows, text, pictures, transforms and compositing, as on the web. `newCanvas2D` draws off screen (`toBitmap`, `savePng`).",
        380, 230, ["canvas2d", "canvas2dWith", "beginCanvas2D", "newCanvas2D"], std3):
  canvas2d(ctx, 360, 210):
    let sky = ctx.createLinearGradient(0, 0, 0, 210)
    sky.addColorStop(0, "#000080")
    sky.addColorStop(1, "#1084d0")
    ctx.fillStyle = sky
    ctx.fillRect(0, 0, 360, 210)
    ctx.fillStyle = "#2e7d32"
    ctx.beginPath()
    ctx.moveTo(0, 210)
    ctx.bezierCurveTo(110, 100, 220, 220, 360, 130)
    ctx.lineTo(360, 210)
    ctx.closePath()
    ctx.fill()
    ctx.shadowColor = "rgba(0, 0, 0, 0.5)"
    ctx.shadowBlur = 8
    ctx.shadowOffsetX = 4
    ctx.shadowOffsetY = 4
    ctx.fillStyle = "gold"
    ctx.beginPath()
    ctx.arc(270, 60, 34, 0, 2 * PI)
    ctx.fill()
    ctx.shadowColor = "transparent"
    ctx.font = "bold 20px sans-serif"
    ctx.fillStyle = "white"
    ctx.fillText("Retro canvas", 16, 34)

const shotTemplate = """
<header><span>Gulf Print House</span><span>Quote {{number}}</span></header>
<footer><span></span><span>Page {page} of {pages}</span></footer>
<h1>Quote {{number}}</h1><p>For <b>{{customer}}</b>:</p>
<table><thead><tr><th width="60%">Item</th><th align="right">Qty</th><th align="right">Amount</th></tr></thead>
<tbody>{{#lines}}<tr><td>{{name}}</td><td>{{qty}}</td><td>{{amount|n3}}</td></tr>{{/lines}}</tbody>
<tfoot><tr><td colspan="2" align="right">Total (OMR)</td><td>{{total|n3}}</td></tr></tfoot></table>"""

example("reportview", "reportView (an HTML template: PDF, printing)",
        "Reports, invoices and lists laid out on pages, from an HTML template and data or from Nim code; shown on a gray desk with page buttons and zoom, saved as PDF or PNG, or printed.",
        520, 380, ["reportView", "reportViewPage", "reportFromHtml", "renderTemplate", "report.newReport", "report.header", "report.footer", "report.newTable", "report.addRow", "report.addTotals", "report.savePdf", "report.savePng", "report.printReport", "report.printPdf"], focus4):
  let shotReport = reportFromHtml(renderTemplate(shotTemplate, %*{"number": "Q-118",
    "customer": "Al Noor Trading", "total": 268.5,
    "lines": [{"name": "Business cards", "qty": 2, "amount": 25.0},
              {"name": "Letterheads", "qty": 3, "amount": 76.5},
              {"name": "Roll-up banner", "qty": 1, "amount": 167.0}]}))
do:
  reportView(shotReport, height = 360)

example("pdfview", "pdfView",
        "A PDF file's pages one under another, each drawn at the size it is shown; the wheel, the scroll bars and a finger move along, Ctrl and the wheel zoom. Call `addPdfPreviews()` once at the start: it teaches the toolkit to draw PDF pages (and the file controls to show them). `pdfPreview` gives a file's first page as a picture. From `retroui/pdfview`.",
        440, 320, ["pdfView", "openPdfView", "addPdfPreviews", "pdfPreview"], focus4):
  addPdfPreviews()
  var quotePdf = openPdfView(getHomeDir() / "Documents" / "Quote Q-118.pdf")
do:
  pdfView(quotePdf, height = 300)
opts(settle = 600)

example("qrcode", "QR codes",
        "`qrEncode` makes the QR code of a text, `qrBitmap` its picture, to draw with `drawBitmap` (or put in a report). From `retroui/qrcode`.",
        240, 160, ["qrBitmap", "qrEncode"], std3):
  let qr = qrBitmap(qrEncode("https://www.foxoman.net"), scale = 4)
do:
  drawBitmap(canvas(qr.w, qr.h), qr)
  label "www.foxoman.net"

# ======================================================================================================
# Sound and video
# ======================================================================================================

part("Sound and video", """
`playSound` plays a WAV file or its bytes, `tone` and `beep` make a sound
of their own, and `uiSound` plays the system's sounds for a message or an
error. They have no picture.
""")

example("animation", "animation (animated GIFs)",
        "The frames of `loadGif` played round and round, each for its delay. The app wakes only when the next frame is due.",
        300, 70, ["animation", "loadGif", "playSound", "tone", "beep", "uiSound"], std3):
  let gifFrames = loadGif(readFile("examples/assets/pattern.gif"))
do:
  row:
    animation(gifFrames, height = 48)
    label "An animated GIF"

example("videoview", "videoView",
        "A video with play, pause, a position bar and the time: a file or a web address (HLS where the system plays it), played by the system's own player and drawn by the kit in the window -- Media Foundation on Windows, AVFoundation on macOS and iOS, GStreamer on Linux, Android's VideoView. Space plays and pauses.",
        420, 280, ["videoView", "closeVideo"], std3):
  let movie = getHomeDir() / "Videos" / "Harbour.avi"
do:
  videoView(movie, height = 260)
opts(settle = 1200)

example("cameraview", "cameraView",
        "The camera's live picture in the window, drawn by the kit under its menus and dialogs, through the system's own API (Video4Linux, Media Foundation, AVFoundation, Camera2; getUserMedia in a web page): photos, videos of it, and sound recorded from the microphone.",
        420, 300, ["cameraView", "cameras", "cameraPhoto", "cameraRecord", "cameraStop", "cameraFrame",
                   "cameraClose", "recordSound", "stopRecordingSound", "recordingSound", "soundLevel"], std3):
  let cam = cameraView(height = 240)
  row:
    if button("&Photo"): cameraPhoto("", "photo.jpg")
    if button(if cam.recording: "&Stop" else: "&Record"):
      if cam.recording: cameraStop() else: cameraRecord("", "clip.mp4")
opts(noPicture = "The picture is the camera's.")

example("nowplaying", "setNowPlaying, mediaKeys",
        "What the app plays, shown where the system shows it -- the lock screen, the notification shade, the taskbar's media flyout, the menu bar's Now Playing, the desktop's media applet, the browser's media hub -- and what the user presses there and on media keys, handed to the app (MPRIS, the System Media Transport Controls, MPNowPlayingInfoCenter, a MediaSession, the browser's Media Session). Call it every frame: the system is told only what changed.",
        420, 80, ["setNowPlaying", "endNowPlaying", "mediaKeys"], std3):
  setNowPlaying(NowPlaying(title: "Morning bell", artist: "Retro", playing: true,
                           positionMs: 12_000, durationMs: 95_000, canNext: true))
  for k in mediaKeys():
    if k.key == mkPlayPause: discard
opts(noPicture = "The system draws it, outside the app.")

example("audioview", "audioView",
        "A sound file to play: its name, play and pause, a position bar and the time (MP3, OGG, FLAC, WAV where the system plays them).",
        420, 140, ["audioView"], std3):
  let song = getHomeDir() / "Music" / "Morning bell.ogg"
do:
  audioView(song, height = 120)
opts(settle = 600)

# ======================================================================================================
# The system's features
# ======================================================================================================

part("The system's features", """
`retroui/system` asks each system for its own notifications, share sheet,
place, voice, haptics and more, with the same calls everywhere -- Linux,
Windows, macOS, Android, iOS and a web page. Nothing waits on the system
(an answer that comes later is asked again next frame), and "not here" is
an answer (false, `psNone`, -1), never an error: the app offers what it
can instead. [docs/system.md](system.md) has what each call does on each
system and what an app declares for it (Android permissions, Info.plist,
https).
""")

example("notify", "notify, share, haptic",
        "Tell the user outside the window (`notify`: the system's notification; `setBadge`: the count on the app's icon), offer something to other apps (`share`: a share sheet, a share menu, Web Share), a tap felt (`haptic`), a buzz (`vibrate`). False where the system has none: the example falls back to a toast and the clipboard.",
        420, 70, ["notify", "clearNotification", "setBadge", "share", "haptic", "vibrate", "requestAttention"], std3):
  row:
    if button("&Notify"):
      if not notify("Order 1042", "Ready at the counter", tag = "orders"):
        toast("Order 1042 is ready")
    if button("&Share"):
      if not share(text = "Order 1042", url = "https://example.com/o/1042"):
        putClipboardText("https://example.com/o/1042")
    if button("&Tap"): haptic(hSuccess)
    if button("&Attention"): requestAttention()

example("location", "location, speak",
        "Where the device is (`location`: `psWaiting` until the first fix, the user asked the first time; `stopLocation` when done) and words said aloud with the system's voice (`speak`, `stopSpeaking`, `speaking`).",
        420, 90, ["location", "stopLocation", "speak", "stopSpeaking", "speaking"], std3):
  var sysPlace = false
do:
  row:
    if button("&Where am I?"): sysPlace = true
    if button("S&peak"): speak("Your order is ready")
    if button("Sto&p"): stopSpeaking()
  if sysPlace:
    let p = location()
    label(case p.state
          of psOk: "At " & $p.lat & ", " & $p.lon
          of psWaiting: "Looking..."
          of psDenied: "The place was not allowed."
          of psNone: "No place on this device.")

example("deviceinfo", "deviceInfo, setOpenAtLogin",
        "The device in one call (`deviceInfo`: its name, system, language, battery, dark look, network, cores), the app started with the computer (`setOpenAtLogin`: Windows' Run key, a launch agent, an autostart entry), `online`, `systemLanguage`, `battery`, `revealFile`.",
        420, 160, ["deviceInfo", "online", "systemLanguage", "battery", "revealFile", "setOpenAtLogin",
                   "openAtLogin"], std3):
  let d = deviceInfo()
  factList({"Device": d.name, "System": d.system, "Language": d.language,
            "Network": (if d.online: "connected" else: "offline")})
  var atLogin = openAtLogin("Shop")
  if toggle("Start with the &computer", atLogin): setOpenAtLogin(atLogin, "Shop")
opts(noPicture = "It shows the device it runs on.")

example("secrets", "saveSecret, loadSecret",
        "Small secrets -- a sign-in's tokens, an API's key -- kept where other users and programs cannot read them: DPAPI on Windows, the keychain on macOS, the desktop's keyring on Linux, a sealed file on phones, WebCrypto in a web page.",
        420, 70, ["saveSecret", "loadSecret", "deleteSecret"], std3):
  var sysSaid = ""
do:
  row:
    if button("&Keep the key"): sysSaid = $saveSecret("Shop", "api key", "k-1042")
    if button("&Read it"): sysSaid = loadSecret("Shop", "api key")
    if button("&Forget it"): deleteSecret("Shop", "api key")
  label sysSaid

example("updates", "checkForUpdate, downloadUpdate, installUpdate",
        "Updates inside the app: the update file you publish, its signature checked (Ed25519) with the public key built into the app, the file for this system downloaded and its SHA-256 checked, then installed (`restartApp`). `retrokit update-key` makes the key, `retrokit update-sign update.json` signs each release. It waits for the network: on a thread of its own, or at a moment the app may wait.",
        420, 70, ["checkForUpdate", "downloadUpdate", "installUpdate", "restartApp", "newerVersion"], std3):
  var updateSaid = ""
do:
  if button("Check for &updates"):
    let u = checkForUpdate("https://example.com/shop/update.json", "01VFThQl2gEEkWYqnvsvw+bbRTD59hQ2SAdg6kBwDjU=", "1.2.0")
    if u.available:
      let file = downloadUpdate(u)
      if installUpdate(file): restartApp()
    else: updateSaid = if u.error.len > 0: u.error else: "This is the newest."
  label updateSaid

# ======================================================================================================
# Looks
# ======================================================================================================

var lookName = "Al Noor Trading"
var lookPaid = true
var lookItems = @["Rooms", "Food", "Spa", "Laundry"]
var lookSel = 1

proc sampleUi() =
  ## A few controls to show a look on.
  menubar:
    menu "&File": discard menuItem("&Open")
    menu "&Edit": discard menuItem("&Copy")
  toolbar:
    toolButton(pxNew, "New")
    toolButton(pxOpen, "Open")
    toolButton(pxSave, "Save")
    toolSeparator()
    toolButton(pxPrint, "Print")
  row([-1, -1]):
    group("Order"):
      edit lookName
      checkbox("&Paid", lookPaid)
      row:
        button("&OK", isDefault = true)
        button("Cancel")
    col:
      listbox(lookItems, lookSel, rows = 4)
      progress(0.6)

proc themeLook(name: string; t: Theme): Look =
  let before = Classic
  look(name, proc () = ui.theme = t, proc () = ui.theme = before)

part("Looks", """
### Themes

Nine color schemes come with the kit (`builtinThemes`): Classic, Gray,
Dark, OLED Black, Ocean, Desert, Plum, Hot Dog and Paper. Set one with
`ui.theme = Ocean` or `app`'s `theme`, or let the user pick it in
`appearanceSettings`. A `Theme` of your own is an object of colors
(`window`, `text`, `face`, `select`...).

{{pictures:themes}}

### Dark mode

Dark and OLED Black are the dark schemes (`themeIsDark`); in them the pixel
icons are drawn as their line twins, in the text's color (`setIconStyle`).
To follow the system: `if systemDarkMode(): ui.theme = Dark`. OLED Black is
true black, for phones whose pixels are off where it is black.

### Size and text size

The UI follows the screen's scale by itself -- 125 %, 150 %, 175 % as asked,
the scale of the monitor the window is on, and of the one it is moved to --
with lines on whole pixels so they stay sharp. `setUiScale(125)` makes everything larger (Ctrl + / - / 0 do it too,
and the phone title bar's menu); `setTextScale(130)` only the text, the
controls growing with it; `setBaseTextSize(14)` changes the size at 100%
(12 pixels per em on desktops and tablets, 15 on phones).
`setControlSizes(csTouch)` gives finger-sized controls on any screen.

{{pictures:sizes}}

### Fonts

Text is **FreeSans** unless the app chooses another font: GNU FreeFont's
sans, in the manner of Helvetica, built in with its bold, oblique and bold
oblique, drawn smooth in gray with the font's own line gap. `setUiFont(ufSerif)`
gives **FreeSerif** (in the manner of Times), `setUiFont(ufMono)` **FreeMono**
(in the manner of Courier); code, editors and hex are FreeMono whatever
the UI's font. Arabic is everywhere, joined and right to left (FreeSerif's).

**A font file:** `loadUiFontFile("fonts/MyFont-Regular.ttf")` (its bold
and italic beside it are found by their names), or build the app with
`-d:retroAppFont=fonts/MyFont-Regular.ttf` to carry its own font.
`builtinUiFonts` lists the built-in ones for a menu of your own.

**Sharp text:** `setSubpixelText(true)` (or "Text edges: Sharp" in
`appearanceSettings`, or `RETRO_TEXT=sharp`) draws the letters in the
screen's red, green and blue strips, three times as fine across, as
Windows' ClearType does. It is off by default.

{{pictures:fonts}}

### The window's frame

A desktop app has the system's own frame, or the one Windows 3.1 had: the
gray sizing border, the navy title bar with the control-menu box at its
left and the minimize and maximize buttons at its right, and a size grip in
the bottom right corner. The app draws it itself, in the theme's colors, and
the system still does the rest: drag the title bar to move the window (Aero
Snap on Windows), the border or the grip to size it (a finger takes the grip
too), a double click to maximize it, Alt+Space for the control menu.
`resizable = false` keeps the window's size: no sizing border, no maximize
button, no grip, and the system's frame the same.

```nim
app "Ledger", 640, 480, frame = wfClassic:   # wfAsBuilt (the default), wfSystem, wfClassic
  ...
app "Calculator", 260, 320, resizable = false:   # the window keeps its size
  ...
```

Or build with `-d:retroFrame=classic`, or start with `RETRO_FRAME=classic`.
**The user can always switch:** the 3.1 frame's control menu has
"Windows' Own Frame", Windows' system menu gets "Windows 3.1 Frame", and
`appearanceSettings` offers it as "Window"; the choice is kept for the
app. `setClassicFrame(on)` changes it while the app runs and `classicFrame()`
says which one is on; `userFrame = false` takes the choice away. Phones keep
their own.

{{pictures:frame}}
""")

example("themes", "Themes", "", 420, 200, ["builtinThemes"], @[ssNormal]):
  sampleUi()
opts(inline = true, looks = builtinThemes.mapIt(themeLook(it.name, it.theme)))

example("sizes", "Sizes", "", 420, 200, [], @[ssNormal]):
  sampleUi()
opts(inline = true, looks = @[
  look("100% (the normal size)", proc () = discard, proc () = discard),
  look("setUiScale(150)", proc () = setUiScale(150), proc () = setUiScale(100), w = 620, h = 250),
  look("setTextScale(130)", proc () = setTextScale(130), proc () = setTextScale(100), w = 520, h = 210)])

example("fonts", "Fonts", "", 420, 200, [], @[ssNormal]):
  sampleUi()
opts(inline = true, looks = @[
  look("FreeSans (ufSans, the default)", proc () = discard, proc () = discard),
  look("FreeSerif (ufSerif)", proc () = setUiFont(ufSerif), proc () = setUiFont(ufSans)),
  look("FreeMono (ufMono)", proc () = setUiFont(ufMono), proc () = setUiFont(ufSans)),
  look("Sharp text (setSubpixelText)", proc () = setSubpixelText(true), proc () = setSubpixelText(false))])

example("frame", "The window's frame", "", 440, 200, [], @[ssNormal]):
  captionBar()
  menubar:
    menu "&File": discard menuItem("&Open")
    menu "&Window": discard menuItem("&Cascade")
  label "The 3.1 frame, drawn by the app"
opts(inline = true, looks = @[
  look("Windows 3.1 frame (frame = wfClassic)", proc () = (setTitle("Ledger"); setClassicFrame(true)),
       proc () = setClassicFrame(false)),
  look("In a dark scheme", proc () = (setTitle("Ledger"); setClassicFrame(true); ui.theme = Dark),
       proc () = (setClassicFrame(false); ui.theme = Classic))])

# Screen readers and input methods
# ======================================================================================================

part("Screen readers and input methods", """
Every control tells screen readers what it is, its name, its value and its
state as it is drawn: Orca on Linux and BSD (AT-SPI, which the kit speaks
over D-Bus itself), NVDA, JAWS and Narrator on Windows (UI Automation),
VoiceOver on macOS and iOS, TalkBack on Android. The screen reader also
moves the focus, presses buttons, menu items, list and grid items, tree
nodes and calendar days, checks boxes, puts text in boxes and moves sliders
and spin boxes: each comes into the next frame as the click or the typing
would. The grid is read as a table, the tree with each item's depth, a chart
by its title, kind, series and the point the keys are on. Nothing of this
is made while no screen reader listens (`RETRO_ACCESS=1` makes it anyway,
to try it).

A label names the control after it, so a form needs nothing more. What an
app draws itself (`canvas`, `fill`, `text`) is read once it says what it is:
`accessNode` gives it a role and a name, `accessName` names an icon-only
button, `accessNameOr` gives a box the name it has when no label names it
(a placeholder), `accessBegin` / `accessEnd` group nodes (a list of your
own, its items with `accessItem`), `accessRange` gives a value its range. A
control of your own takes a screen reader's press through `interact`, as a
click.

**Input methods** (pinyin, kana, hangul, a phone keyboard's word) compose in
the text box itself: what is being composed is drawn underlined at the
caret and typed when it is settled -- XIM on X11, IMM on Windows, marked
text on macOS, GTK 4's preedit, the kit's own input connection on Android,
UITextInput on iOS. `ui.composing` holds it for a text box of your own.
""", outro = """
### The keyboard alone: Tab's order and F6

Tab goes through the controls in the order they are drawn, a run of tool
buttons one stop (the arrows go along it). `tabIndex` before a control puts
it first; F6 and Shift+F6 go from one part of the window to the next, each
back at the control it had the focus on: the tool bars, the panes of a
split, the docked panels, the windows in the window, the menu bar -- and
a part of your own:

```nim
row:
  tabIndex 1
  edit first        # (Tab: first, then last, then the city)
  tabIndex 3
  edit city
tabIndex 2
edit last
area "preview":     # (F6 comes here, to the list's selection)
  listbox(items, sel)
```

{{api:tabStops}}

{{api:tabIndex}}

{{api:area}}

{{api:beginArea}}

{{api:endArea}}

### The inspector and the driver: controls found by their names

The names screen readers read are how the inspector (F12; `RETRO_INSPECT=1`)
shows the controls, how a program uses an app from outside
(`RETRO_DRIVE=PORT`, `retrokit drive PORT click OK`; README, "The inspector
and the driver") and how a test finds them without coordinates:

```nim
accessKeep = true                                   # the last frame's tree in accessLast
let i = findNode(accessLast, "Save", {arButton})    # -1: none
click(nodeRect(accessLast[i]))                      # (the tests' harness)
```

```nim
proc findNode*(tree: openArray[AccessNode]; name: string; roles: set[AccessRole] = {};
               nth = 0): int
```

The control called `name` (any case; failing that, one whose name has it
in it; "" any), of one of `roles`, the `nth` of them; -1 when there is none.

```nim
proc nodeRect*(n: AccessNode): Rect
proc nodeAt*(tree: openArray[AccessNode]; x, y: int): int
proc nodeLine*(n: AccessNode): string
```

A node's place in the window's logical pixels; the smallest control at a
point (0: the window); a node as one line (`Button "OK"`, `Text field
"Name:" = Ada`).

```nim
proc showInspector*(on = true)
proc inspectorShown*(): bool
proc startDriver*(port: int): int
proc drivePort*(): int
```

Show the inspector as F12 does; listen for a driver as `RETRO_DRIVE` does
(0: any free port; the port, or 0). `whyFrames` and `frameCause` (the
core) say why each frame ran.
""")

example("access", "Screen readers: what an app draws itself",
        "The label names the box; the picture is read as \"Sales by month\"; the " &
        "button with only an icon is read as \"Print\".", 420, 150,
        ["accessNode", "accessName", "accessNameOr", "accessBegin", "accessEnd", "accessItem",
         "accessRange", "accessible"], @[ssNormal]):
  row([60, -1]):
    label "&Name:"
    edit lookName
  row:
    let r = canvas(dp(160), dp(60))
    fill(r, ui.theme.field)
    for i, v in [30, 45, 25, 55]:
      fill(rect(r.x + dp(10) + i * dp(36), r.y + r.h - dp(v), dp(24), dp(v)), ui.theme.select)
    accessNode(arImage, "Sales by month", id = 0, r = r)
    accessName("Print")
    if button("", pxPrint): discard

# ---- reading the API from the sources -------------------------------------------------------------

type ApiDoc = object
  sig, doc, module: string

const apiModules = ["widgets", "extras", "business", "morecontrols", "records", "desktop",
  "toolcustom", "dock", "textwidgets", "filewidgets", "charts", "planning", "mapview",
  "view3d", "htmlview", "markdown", "richedit", "media", "qrcode", "pdfview", "core", "gfx",
  "platform", "files", "textfile", "mediagif", "imaging", "templates", "native", "canvas2d",
  "report", "tilemap", "gltf", "capture", "mediasession"]
  ## Where the API is read from; a name in several is shown from the first
  ## (or as "module.name").

proc bodyEq(s: string): int =
  ## Where the `=` that starts a routine's body is in its declaration, -1
  ## when there is none (a forward declaration).
  var depth = 0
  var i = 0
  var inStr = false
  while i < s.len:
    let c = s[i]
    if inStr:
      if c == '\\': inc i
      elif c == '"': inStr = false
    elif c == '"': inStr = true
    elif c == '`':
      let j = s.find('`', i + 1)
      if j > i: i = j
    elif c in {'(', '['}: inc depth
    elif c in {')', ']'}: dec depth
    elif c == '#' and depth == 0: return -1
    elif c == '=' and depth == 0 and i > 0 and s[i - 1] == ' ' and
         (i + 1 >= s.len or s[i + 1] in {' ', '\n'}):
      return i
    inc i
  -1

proc readApi(): Table[string, seq[ApiDoc]] =
  for m in apiModules:
    let f = "src" / "retroui" / (m & ".nim")
    if not fileExists(f): continue
    let lines = readFile(f).splitLines
    var i = 0
    while i < lines.len:
      let l = lines[i]
      if (l.startsWith("proc ") or l.startsWith("template ") or l.startsWith("func ") or
          l.startsWith("macro ") or l.startsWith("iterator ")) and "*" in l.split('(')[0]:
        let head = l.split(' ', 1)[1]
        let name = if head.startsWith("`"): head[1 ..< head.find('`', 1)]
                   else: head.split({'*', '(', '[', ':'})[0]
        # the declaration, up to the `=` of its body
        var decl = l
        var j = i
        var at = bodyEq(decl)
        while at < 0 and j + 1 < lines.len and j < i + 10 and lines[j + 1].startsWith("    ") and
              not lines[j + 1].strip.startsWith("##"):
          inc j
          decl.add "\n" & lines[j]
          at = bodyEq(decl)
        if at < 0:                       # a forward declaration: the routine comes later
          i = j + 1
          continue
        let sig = decl[0 ..< at].strip
        var doc: seq[string]
        var k = j + 1
        while k < lines.len and lines[k].strip.startsWith("##"):
          # (`## text`: the one space after `##` goes; more is indentation,
          # which a code block's lines keep)
          var dl = lines[k].strip[2 .. ^1]
          if dl.startsWith(' '): dl = dl[1 .. ^1]
          doc.add dl.strip(leading = false)
          inc k
        result.mgetOrPut(name, @[]).add ApiDoc(sig: sig, doc: doc.join("\n"), module: m)
        i = k
      else: inc i

proc apiOf(api: Table[string, seq[ApiDoc]]; a: string): seq[ApiDoc] =
  ## The definitions of `a` ("name", or "module.name") from one module.
  var name = a
  var module = ""
  if '.' in a:
    module = a.split('.')[0]
    name = a.split('.')[1]
  let all = api.getOrDefault(name)
  if module.len == 0:
    for m in apiModules:
      if all.anyIt(it.module == m):
        module = m
        break
  all.filterIt(it.module == module)

proc cleanCode(code: string): string =
  ## The example as an app would write it (without the tool's helpers).
  var lines: seq[string]
  for l in code.splitLines:
    if l.strip in ["aim()", "aimed = true"] or l.strip.startsWith("target = ") or
       l.strip.startsWith("aimAt("): continue
    lines.add l.multiReplace((", enabled = shotEnabled", ""), ("enabled = shotEnabled", ""),
                             ("(, ", "("))
  lines.join("\n").strip

proc docText(d: string): string =
  ## The doc comment as Markdown: its code blocks kept as code.
  var outL: seq[string]
  var inCode = false
  for l in d.splitLines:
    if l.startsWith(".. code-block::"):
      outL.add "```nim"
      inCode = true
    elif inCode and l.len > 0 and not l.startsWith("  "):
      outL.add "```"
      inCode = false
      outL.add l
    elif inCode: outL.add(if l.startsWith("  "): l[2 .. ^1] else: l)
    else: outL.add l
  if inCode: outL.add "```"
  outL.join("\n")

# ---- drawing the pictures ---------------------------------------------------------------------------

proc capture(path: string) =
  ## The screen, cut down to what was drawn on it (and a margin).
  var counts = initCountTable[uint32]()
  for x in 0 ..< W:
    counts.inc pixels[x]
    counts.inc pixels[(H - 1) * W + x]
  for y in 0 ..< H:
    counts.inc pixels[y * W]
    counts.inc pixels[y * W + W - 1]
  let bg = counts.largest.key
  var x0 = W
  var y0 = H
  var x1 = -1
  var y1 = -1
  for y in 0 ..< H:
    for x in 0 ..< W:
      if pixels[y * W + x] != bg:
        x0 = min(x0, x); x1 = max(x1, x)
        y0 = min(y0, y); y1 = max(y1, y)
  if x1 < 0: (x0, y0, x1, y1) = (0, 0, W - 1, H - 1)
  const m = 6
  x0 = max(0, x0 - m); y0 = max(0, y0 - m)
  x1 = min(W - 1, x1 + m); y1 = min(H - 1, y1 + m)
  let b = newBitmap(x1 - x0 + 1, y1 - y0 + 1)
  for y in y0 .. y1:
    for x in x0 .. x1:
      b.px[(y - y0) * b.w + x - x0] = pixels[y * W + x] or 0xFF000000'u32
  writeFile(path, encodePng(b, level = 9))

proc press(x, y: int; button = LeftButton; clicks = 1) =
  queue.add Event(kind: MouseMoveEvent, x: x, y: y)
  queue.add Event(kind: MouseDownEvent, x: x, y: y, button: button, clicks: clicks)
  run(1)

proc release(x, y: int; button = LeftButton) =
  queue.add Event(kind: MouseUpEvent, x: x, y: y, button: button)
  run(3)

proc typeText(s: string) =
  for r in runes(s):
    var e = Event(kind: TextInputEvent)
    let t = toUTF8(r)
    for i in 0 ..< min(4, t.len): e.text[i] = t[i]
    queue.add e
  run(3)

proc fileOf(s: Shot; label: string): string =
  ## "button-touch-screen.png"
  var words = ""
  for c in label.toLowerAscii:
    if c in {'a'..'z', '0'..'9'}: words.add c
    elif c in {' ', '-', '_'}: words.add ' '
  s.name & "-" & words.split(' ').filterIt(it.len > 0).join("-") & ".png"

proc shoot(s: Shot; st: ShotState; outDir: string; lk: Look = Look()): string =
  if existsEnv("SHOTS_VERBOSE"): echo s.name, " ", st, " ", lk.label
  shotEnabled = st != ssDisabled
  let classic = ui.theme
  if st == ssDark:
    for t in builtinThemes:
      if t.name == "Dark": ui.theme = t.theme
  if lk.on != nil: lk.on()
  # (a touch screen's controls are bigger: more room down, for dialogs too)
  let touch = st == ssTouch or lk.touch
  let h = if lk.h > 0: lk.h else: s.h
  resize(if lk.w > 0: lk.w else: s.w, (if touch and lk.h == 0: h * 3 div 2 else: h), touch)
  ui.popup = 0
  ui.focus = 0
  queue.add Event(kind: MouseMoveEvent, x: W + 50, y: H + 50)
  view = proc () =
    # a focusable spot out of sight takes the focus first, so "Normal"
    # shows no focus and Tab gives it to the control
    discard interact(Id(0x5ec0ffee'u32), rect(-40, -40, 1, 1))
    if closeRequested(): cancelClose()       # (Esc and Back close the app otherwise)
    aimed = false
    s.draw()
    if not aimed: target = ui.lastRect
  run(4)
  if s.settle > 0: settle(s.settle)
  # a screen as large as the content: nothing scrolls (and the picture is cut
  # down to what was drawn)
  for _ in 0 ..< 4:
    if not ui.pageOn and ui.pageMaxX == 0: break
    resize(W + (if ui.pageMaxX > 0: ui.pageMaxX + SbW + 8 else: 0),
           H + (if ui.pageOn: ui.pageMax + SbW + 8 else: 0), touchNow)
    run(4)
  let cx = target.x + min(target.w div 2, dp(24))
  let cy = target.y + target.h div 2
  case s.act
  of acClick:
    press(cx, cy)
    release(cx, cy)
    queue.add Event(kind: MouseMoveEvent, x: W + 50, y: H + 50)
    run(3)
  of acDoubleClick:
    press(cx, cy)
    release(cx, cy)
    press(cx, cy, clicks = 2)
    release(cx, cy)
  of acRightClick:
    if touchNow:                         # a long press
      press(cx, cy)
      ticks += 800
      run(3)
      release(cx, cy)
    else:
      press(cx, cy, RightButton)
      release(cx, cy, RightButton)
  of acRest:
    queue.add Event(kind: MouseMoveEvent, x: cx, y: cy)
    run(2)
    ticks += 800
    run(3)
  of acType:
    press(cx, cy)
    release(cx, cy)
    typeText(s.typed)
  of acNone: discard
  if s.settle > 0 and s.act != acNone: settle(s.settle div 2)
  case st
  of ssFocused:
    queue.add Event(kind: KeyDownEvent, key: KeyTab)
    queue.add Event(kind: KeyUpEvent, key: KeyTab)
    run(3)
  of ssHover:
    queue.add Event(kind: MouseMoveEvent, x: cx, y: cy)
    run(3)
  of ssPressed:
    press(cx, cy)
    run(1)
  of ssOpen:
    press(cx, cy)
    release(cx, cy)
  else: discard
  let file = s.fileOf(if lk.label.len > 0: lk.label else: $st)
  capture(outDir / file)
  # let go away from it, close what opened, put back what changed
  queue.add Event(kind: MouseMoveEvent, x: W + 50, y: H + 50)
  queue.add Event(kind: MouseUpEvent, x: W + 50, y: H + 50, button: LeftButton)
  queue.add Event(kind: KeyDownEvent, key: KeyEsc)
  queue.add Event(kind: KeyUpEvent, key: KeyEsc)
  run(2)
  ui.popup = 0
  dismissToast()
  hideSnackbar()
  if lk.off != nil: lk.off()
  ui.theme = classic
  setToolbarLook(blDefault)
  shotEnabled = true
  if s.reset != nil: s.reset()
  file

proc slug(s: string; used: var CountTable[string]): string =
  ## The anchor GitHub gives a heading.
  for c in s.toLowerAscii:
    if c in {'a'..'z', '0'..'9', '-', '_'}: result.add c
    elif c == ' ': result.add '-'
    elif ord(c) >= 128: result.add c
  let n = used[result]
  used.inc result
  if n > 0: result.add "-" & $n

proc pictureTables(s: Shot; outDir: string; count: var int): string =
  ## The pictures of an example: the three of every control, then its other
  ## states; or one for each of its looks.
  proc table(heads, cells: seq[string]): string =
    "| " & heads.join(" | ") & " |\n|" & heads.mapIt("---").join("|") & "|\n| " &
      cells.join(" | ") & " |\n\n"
  if s.noPicture.len > 0:
    return "*" & s.noPicture & "*\n\n"
  if s.looks.len > 0:
    var heads, cells: seq[string]
    for lk in s.looks:
      let file = shoot(s, ssNormal, outDir, lk)
      heads.add lk.label
      cells.add "![" & s.title & ": " & lk.label & "](controls/" & file & ")"
      inc count
    # two pictures a row: the looks are big
    var i = 0
    while i < heads.len:
      result.add table(heads[i ..< min(i + 2, heads.len)], cells[i ..< min(i + 2, cells.len)])
      i += 2
    return
  var heads, cells, moreH, moreC: seq[string]
  for st in s.states:
    let file = shoot(s, st, outDir)
    let cell = "![" & s.title & ", " & ($st).toLowerAscii & "](controls/" & file & ")"
    if st in {ssNormal, ssTouch, ssDark}:
      heads.add $st
      cells.add cell
    else:
      moreH.add $st
      moreC.add cell
    inc count
  if heads.len > 0: result.add table(heads, cells)
  if moreH.len > 0:
    result.add "More states:\n\n" & table(moreH, moreC)

proc main() =
  let outDir = "docs" / "controls"
  let only = getEnv("SHOTS_ONLY").split(',').filterIt(it.len > 0)
  createDir(outDir)
  if only.len == 0:
    for f in walkFiles(outDir / "*.png"): removeFile(f)
  fakeDriver()
  pixels = newSeq[uint32](W * H)
  view = proc () = discard
  startApp("shots", W, H)
  if only.len > 0:
    var count = 0
    for s in shots:
      if s.name in only: discard pictureTables(s, outDir, count)
    echo count, " pictures in ", outDir, " (the guide not written)"
    removeDir(sampleRoot)
    return
  let api = readApi()
  var used = initCountTable[string]()
  var count = 0
  var body = ""
  var contents = ""
  var pictures = initTable[string, string]()
  for s in shots:
    if s.inline: pictures[s.name] = pictureTables(s, outDir, count)
  for p in parts:
    let pslug = slug(p.title, used)
    body.add "## " & p.title & "\n\n"
    var entries: seq[string]
    if p.intro.len > 0:
      var intro = p.intro.strip
      for name, pics in pictures:
        intro = intro.replace("{{pictures:" & name & "}}", pics.strip)
      var inCode = false
      for l in intro.splitLines:
        if l.startsWith("```"): inCode = not inCode
        if not inCode and l.startsWith("### "):
          entries.add "[" & l[4 .. ^1] & "](#" & slug(l[4 .. ^1], used) & ")"
      body.add intro & "\n\n"
    for s in shots:
      if s.part != p.title or s.inline: continue
      entries.add "[" & s.title & "](#" & slug(s.title, used) & ")"
      body.add "### " & s.title & "\n\n"
      if s.about.len > 0: body.add s.about & "\n\n"
      body.add pictureTables(s, outDir, count)
      var code = cleanCode(s.code)
      if s.decls.len > 0: code = cleanCode(s.decls) & "\n\n" & code
      body.add "```nim\n" & code & "\n```\n\n"
      var sigs = ""
      var shown: seq[string]
      for a in s.apis:
        if a in shown: continue
        shown.add a
        for d in apiOf(api, a):
          sigs.add "```nim\n" & d.sig & "\n```\n\n"
          if d.doc.len > 0: sigs.add docText(d.doc) & "\n\n"
      if sigs.len > 0: body.add "**API**\n\n" & sigs
    if p.outro.len > 0:
      var outro = p.outro.strip
      while true:
        let at = outro.find("{{api:")
        if at < 0: break
        let e = outro.find("}}", at)
        var sigs = ""
        for d in apiOf(api, outro[at + 6 ..< e]):
          sigs.add "```nim\n" & d.sig & "\n```\n\n"
          if d.doc.len > 0: sigs.add docText(d.doc) & "\n\n"
        outro = outro[0 ..< at] & sigs.strip & outro[e + 2 .. ^1]
      var inCode = false
      for l in outro.splitLines:
        if l.startsWith("```"): inCode = not inCode
        if not inCode and l.startsWith("### "):
          entries.add "[" & l[4 .. ^1] & "](#" & slug(l[4 .. ^1], used) & ")"
      body.add outro & "\n\n"
    contents.add "- **[" & p.title & "](#" & pslug & ")**" &
                 (if entries.len > 0: ": " & entries.join(" · ") else: "") & "\n"
  let md = "# Retro Nim UI: the guide\n\n" &
    "Every control of Retro Nim UI, with pictures: what it does, how it looks, an\n" &
    "example, and its API. Start with [Getting started](#getting-started) and\n" &
    "[Layout](#layout); then look up the controls you need. The pictures show\n" &
    "each control as it is, on a touch screen and in a dark color scheme (some\n" &
    "in more states too), and they are drawn from the very example beside them,\n" &
    "so they always match the toolkit.\n\n" &
    "Every control works with the mouse, the keyboard (Tab, F6, the arrows, Space,\n" &
    "Enter, Esc, `&` letters with Alt, the menu key), fingers (a tap, a drag to\n" &
    "scroll, a long press for the menu) and screen readers (see\n" &
    "[Screen readers and input methods](#screen-readers-and-input-methods)).\n" &
    "The [README](../README.md) tells the rest:\n" &
    "files, mail, the image editor, the system's own APIs, Android and iOS. The\n" &
    "reference of every module is made by `nimble docs` into `docs/api/`.\n\n" &
    "-- Sultan Al Isaiee ([@foxoman](https://github.com/foxoman))\n\n" &
    "## Contents\n\n" & contents & "\n" & body.strip & "\n\n---\n\n" &
    "This guide and its pictures are made by `tools/shots.nim` (`nimble docs`);\n" &
    "`tools/controlscheck.py` checks that it shows every control.\n"
  writeFile("docs" / "controls.md", md)
  removeDir(sampleRoot)
  echo shots.len, " examples, ", count, " pictures in ", outDir

main()
