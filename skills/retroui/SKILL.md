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
   (and docs/customizing.md beside it: making a control look different, making your own)
   and https://github.com/foxoman/retroui/blob/main/docs/hig.md -- the interface guidelines: how a
   desktop app and a phone app should behave, each rule with the call it takes; follow them
   (examples/higdesk.nim and examples/higphone.nim do all of it)
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

Needs Nim 2.4 (2.2 still builds it) and a C compiler. Build with
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
look the user picks), `resizable` (false: the window keeps its size),
`version` (what a fault's report says). A
misspelled option is a compile error. An app with its own loop uses
`openApp(...)`, `while beginFrame(): ...; endFrame(); appFrameDone()`,
`closeApp()` -- and first in each frame `if stoppedFrame(): (endFrame();
continue)`: when the last run crashed, its report shows before the app's
code runs (`app` does this itself); ask `stoppedPending()` before bringing
back what was open, and leave it out when `startFresh()` (ticked by
itself when the app stopped again right after that screen's Start). Set
`reportedVersion = "1.2"` before the window opens: the report says it. Files
named on the command line: `appArguments()` (none in a phone's app).

The whole syntax, every form as a small program with a picture of what it
draws (what each number in `row([50, -1, 0, -2])` gives, binding, events,
containers, dialogs, ids in loops, the rules), is in `docs/syntax.md`
(github.com/foxoman/retroui/blob/main/docs/syntax.md); step-by-step lessons,
each step a whole program, in `tutorials/`. Row widths, in short:
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
  callback or `finished()`; `later(akDiskSpace, dir)`, `later(akFolders,
  dir)`... for what a frame wants to know of a disk -- never `dirExists`,
  `walkDir` or a file read in what is drawn every frame: a network drive
  that is not connected holds the window for half a minute),
  `retroui/parallel` (`parallelFor`,
  `parallelRows`), `httpRequest` from a thread; `busy("Saving..."): ...`
  shows a busy box for work that must run on the UI thread. Ask for a
  frame later with `wakeIn(ms)`; for something that moves by itself where
  it is drawn (an animation, a clock), `wakeInShown(rect, ms)`: no frames
  while it is out of view, so an app at rest takes no CPU. A window
  minimized or covered all over draws nothing (`ui.hidden`; its frames and
  timers go on): read what changes by itself less often then. A caret
  rests after `CaretBlinkFor` (10 s). Setters such as `setToolbarLook`,
  `setTabLook`, `setUiScale` are cheap every frame: only a change draws
  again -- a call of your own that sets `ui.redraw` or `wakeIn` every frame
  keeps the app busy for nothing.
- **Long lists you draw yourself:** a `for` loop of labels or rows costs
  every row on every frame (and a key or a click runs the frame twice).
  For thousands, draw them with `visibleRows` inside a `panel` or
  `scrollPanel`: only the rows in view are drawn, the others keep their
  room (`varying = true` for rows of their own heights, a chat's wrapped
  lines). Or use `grid` / `listbox`, which do it themselves.
  ```nim
  panel:
    for i in visibleRows(lines.len, key = "log", varying = true):
      withId(i): paragraph(lines[i])
  ```
- **Wrapping text yourself:** don't measure a growing line with
  `textWidth(line & " " & word)` for every word -- that measures each line
  again and again. A `LineMeter` carries the width on, the same number
  `textWidth` would give (plain ASCII; `m.ok` false: use `textWidth`):
  ```nim
  var m = lineMeter()            # (bold, mag as textWidth's)
  m.add "The quick"
  var cand = m
  cand.add " brown"
  if cand.width > maxW: echo "a new line" else: m = cand
  ```
  `paragraph` and `wrapLines` wrap so already.
- **Check it at rest:** `RETRO_SMOKE=14 ./app` starts it for real, times
  the first frame (`firstFrameMs()`), measures 3 seconds untouched, then
  clicks and types until 14 s; it ends 0 (ok), 1 (a fault) or 2 (busy
  while untouched), with a line on stderr (and in `$RETRO_SMOKE_OUT`). Run
  it in a home of its own: the clicks reach anything. The kit's
  `tests/smoke/run.sh` does it for its apps. For a leak: `RETRO_SMOKE=3600
  RETRO_SMOKE_STAY=1 RETRO_DEVICE_MB=2048 ./app` (an hour; an Exit clicked
  does not end it; the caches sized as on a 2 GB phone) with its memory
  watched -- the kit's `tools/soak.sh` does it and says which kept growing.
- **See why it draws:** F12 in a debug build (`RETRO_INSPECT=1` in any)
  shows the inspector: each frame's time, **why it ran** (the input, or
  the line that asked: `ui.redraw = true at app.nim:42`, `wakeIn at
  ...`), what the next one waits for, the control under the mouse and
  the frame's controls by name, and where the last frames' time went (the
  frame profiler's spans and counters). An app at rest says "at rest".
- **See where a frame's time goes:** `RETRO_TRACE=trace.json ./app` writes
  each frame as a Chrome trace (chrome://tracing, ui.perfetto.dev):
  the app's code, finishing, drawing, the GPU's draw and swap, with
  counters (draw calls, vertices, bytes sent). Spans of your own:
  `profiled("load"): ...` and `profCount("rows", n)` (`retroui/frameprof`;
  off, a test of one bool). Measure before and after a change for speed.
- **Use it from outside, by its controls' names:** `RETRO_DRIVE=7000 ./app
  &`, then `retrokit drive 7000 tree`, `click "Save"`, `click 120,40`,
  `type "Ada"`, `key ctrl+s`, `set "Name:" Ada`, `wait "Saved" --timeout
  3000`, `quit` -- each answered once the app has done it (exit 1 when it
  could not). From Nim: `retroui/driveclient` (`driveConnect`, `ask`,
  `request`). In a headless test of your own, `accessKeep = true` and
  `findNode(accessLast, "OK", {arButton})` / `nodeRect` find a control by
  name. Give a control without a label before it a name
  (`accessName "Celsius"`) so readers and drivers can find it. A node's
  id (`"node": 1234` in JSON) finds it exactly; a name alone prefers a
  control to a label of the same text. Retro Designer's View > Names and
  Tab Order shows the stops of Tab and the unnamed controls.
- **Tab is the keyboard's**: every control Tab stops at, in order
  (`tabStops()`; `tabIndex 1`, `tabIndex 2`... before controls put them
  first). A run of tool buttons is one stop (the arrows go along it). F6
  goes from part to part (tool bars, split panes, docked panels, MDI
  windows, the menu bar; `area "key": ...` for a part of your own). An app
  that gives Tab a meaning of its own (hide the
  panels, as image editors do) does it only when `not focusInControls()`
  -- else Tab must go on to the next control -- and sets `autoFocus =
  false` when its keys are its canvas's until a control is clicked.
  While the keyboard moves about, the focused control wears a ring in the
  highlight colour (as today's Windows; a click shows none): the kit
  draws it, round any control. A control drawn by hand that keeps the
  focus itself calls `focusAt(rect)`; `focusRing = false` turns it off.
  Give each `&` letter once in a window and in a dialog: the tour
  (`tests/drive/run.sh`) finds one used twice (in a menu a shared letter
  lights the next item that has it, as in Windows).
- **Start fast**: work the first frame can do without waits for
  `framesShown() > 0`; `scanFontsSoon()` at the start of an app that lists
  the system's fonts; `addFontData(..., packed = true)` early (unpacked on
  a thread from then). A font offered only to be shown once (a preview of
  a font file) is let go after with `dropFontData(family)`: offered fonts
  are kept for as long as the app runs.
- `&` in a label underlines the next letter (Alt+letter). `isDefault = true`
  makes Enter press the button -- unless the focused control acts on Enter
  itself (a drop-down, a date, a button, a grid cell, a multi-line text
  box). A control of your own that acts on Enter sets `ui.takesEnter =
  true` while it has the focus, so the default button leaves Enter to it.
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
  `numberEdit` / `intEdit` selects its text, so typing replaces it. Number
  boxes (`spin`, `popupSlider`, `numberEdit`, `intEdit`) take a little sum
  too ("1200/2": `evalNumber`).

## 5. Layout

`row:` / `row([w1, w2, -1]):` (left to right; a plain `row:` wraps when
full, and a label ending in ':' wraps with its field -- `keepWithNext()`
for another pair), plain statements stack top to bottom, `group "Title":`, `card`, `form(labelWidth): field("&Name:"): edit x`,
`spring()` (pushes the rest to the far side: a row's right end, a column's bottom), `space(n)`, `adaptive(minW): ...`
(columns that fold into one on a phone), `scrollPanel`/`panel(h)`/`pane`
(a list or a carousel inside one passes a swipe on to it at its ends, as
on Android: nothing to do),
`tabs`, `split`/`vsplit`, `sidePane`, `menubar: menu "&File": if menuItem("&Open", "Ctrl+O"): ...` (Ctrl+Shift+P searches its commands),
`toolbar:`, `statusbar(...)`, MDI windows (`mdiArea`, `mdiWindow`; `noPin` for no pin in the title bar), docking (`retroui/dock`).
Sizes are design pixels; the kit scales them to the screen (`dp(n)` for your own).

Forms: `form(90): field("&Name:"): edit name` -- `90` is the caption
column in design pixels (`form(0)`: as wide as the widest caption). The
control fills the rest of the row; give it `w = ...` to make it narrower,
or put several in a `row:` inside the `field`. `field("")` lines a control
up under the others. When the row is narrower than the captions plus about
200 pixels (a phone), each caption goes above its control.

## 6. Controls (docs/controls.md has all 528, with pictures)

Text: `label`, `paragraph`, `heading`, `styledText`, `link`, `badge`, `icon`, `iconLabel`, `image`, `tooltip`.
Buttons: `button`, `segmented`, `menuButton`, `splitButton`, `buttonRow`.
Choices: `checkbox` (on, off or mixed: `checkbox(label, var CheckState)`, `mixedOf(bools)` -- for things chosen together that differ), `radio`, `toggle`, `chips`, `tagInput`, `rating`, `unfoldButton("&Options", open)` (Options >>).
Text input: `edit` (`maxLen`; `autoExit`: full, the next box takes the keys -- a code in parts), `editArea`, `searchBox`, `autocomplete`, `maskedEdit`, `comboEdit`, `hotkeyEdit`, code (`codeEdit(s, lang = clNim)`: colored, line numbers, indent, Ctrl+/, find), rich text (`richEdit`, `richToolbar`).
Numbers, dates, colors: `spin` (`wrap = true` for minutes, degrees), `numberSpin(v, lo, hi, step, decimals, sizes = [8.0, 9, 10, 12])` (a type size with the usual ones in a list), `intEdit`, `numberEdit`, `slider`, `progress`, `datePicker`, `calendar`, `timePicker`, `colorPicker`, `colorWell` (`alpha = true` for a color that may be see-through: Opacity, Transparent).
Lists and data: `listbox`, `combo`, `grid` (the data grid with editing, sorting, totals), `gridOf(rows, sel)` (a grid of a seq of your object: a column a field, sorted for you), `tree`.
Files: `fileDialog`, `fileList`, `folderTree`, `filePicker` (`pickerFolder`: the folder it shows), `filePreview`, `placesView`. On a phone, `systemFiles(true)` at the start makes `fileDialog` and `filePicker` the system's own picker (Android, iOS; what the app saves goes back into the document by itself); without it, `filePicker` on Android starts in the user's Pictures (it asks for Android's access to the user's files when it has none). A color from anywhere in the window (an eyedropper): `readScreenPixel(x, y)`, then `screenPixelRead()` once the next frame is drawn.
Charts and more: `chart` (21 kinds, from your numbers or a CSV table), `barChart`, `lineChart`, `pieChart`, `liveGraph` (a task manager's graph that moves: a frame costs a copy), the world map (`retroui/mapview`), street maps (`tileMap`, `retroui/tilemap`; places and routes `retroui/geo`), 3D (`retroui/view3d`; Blender's models `retroui/gltf`),
HTML and Markdown (`htmlView`: its CSS, flexible boxes and grids too), web pages (`webView`), canvas (`canvas`, `retroui/canvas2d`), reports and PDF (`retroui/report`),
sound and video (`retroui/media`; the system's media controls `retroui/mediasession`; camera and microphone `retroui/capture`), spreadsheets (`retroui/xlsx`), more windows (`window`),
an image editor's engine (`retroui/photo`: layers, masks, styles, type, shapes; books of pages `retroui/photobook`; a picture as vector shapes `retroui/imagetrace`; type as shapes and blends `retroui/photovector`; presets and templates for new drawings and books `retroui/layouttemplates`; charts and maps as SVG `retroui/infographics`; diagrams typed as a few lines in two languages and placed as shape and type layers in a group -- a family tree, a dendrogram, a timeline, a numbered list, a note, a title (`placeDiagram`, `diagramOf`, `diagramParts`, `defaultDiagram`, `diagramThemes`) -- and bilingual slides as artboards with a header, a footer and `<#> / <##>` page numbers (`newCarousel`, `placeSlideFrame`, `slideContent`) `retroui/diagrams` (a group made in code is open: set `collapsed = true` before adding layers beside it); type measured in points at a document's resolution as the photo program does (`ViewPrefs.typeUnit`, `typeUnitPixels(u, dpi)` in `retroui/photowidgets`: show a type length as `px / typeUnitPixels(...)`); type, a shape or a Smart Object moved whole by `beginMove` while a selection is made (`movesWhole`: never ask to rasterize for a move); shapes from a few numbers `retroui/liveshapes`; IDML `retroui/idml`; Check Document `retroui/preflight`; tables, a font for each script, footnotes and Auto-Size in `retroui/textengine`; Text Wrap's free spans of a line `freeSpans`, an object's outline and offsets `wrapOutline`, `wrapOpts`, its real shape `wrapContour` (its pixels, its edges, a document path), its boundary and handles `wrapBoundary`/`wrapHandles`, the text round it while it is dragged (`rewrap` during the step) in `retroui/photo`; layers put inside a frame `putInside`; 3D on shapes `retroui/threed` (`ShapeData.threeD`, `defaultThreeD`; faces as vectors); dimensions that follow what they measure `retroui/dimensions` (`addDimension`, `anchorAt`, `updateDimensions` after a step); Export for Screens `retroui/screenexport` (`exportForScreens`: scales with suffixes, PNG/JPEG/WebP/SVG/PDF; artboards as a PDF of pages or spreads `saveArtboardsPdf`, `artboardSheets`); DXF drawings `retroui/dxf` (`importDxf`); EPS drawings as shapes `retroui/psvector` (`psShapes`); animated PNG `retroui/apng` (`decodeApng`, `encodeApng`; `exportAnimation(format = "apng")`); Select > Same `selectSame` (`SameBy`); Align To a key object or the artboard `alignBox`; artboards as the drawing program's -- pages of the canvas the document keeps, not layers (`Doc.boards`, `Artboard`; `addArtboard`, `moveArtboard` with its artwork or alone, `duplicateArtboard`, `resizeArtboard`, `rearrangeArtboards`, `fitArtboardTo`, `convertToArtboards`, `artboardPicture`; as pages: `<#>` in type on one its number `boardOfText`/`syncBoardNumbers`, `Doc.boardFirst`, facing in spreads `Doc.boardFacing`/`boardSpreads`/`boardSide`, `placeArtboard`, `snapArtboardMove`, `moveToArtboard`, `artboardFolios` in `retroui/photocc`; the canvas grows for them, `Doc.grown` and `keepInView` keep the view in place); Distribute Spacing by a value `distributeSpacing`; Isolation Mode `isolate`/`inIsolation`; Draw Behind and Draw Inside `Doc.drawMode`; Align to Pixel Grid `alignToPixels`, `Doc.pixelAlign`; a gradient along or across a stroke `ShapePaint.onStroke`; the space between objects `gapAt`, dragged `applyGap` (`GapKind`), a frame sized `sizeLayerBox`; a layer copied for another document `layerFor`, put in `placeLayers`; tab stops `ParaStyle.tabs` (`TabStop`: Left, Right, Center, Align On, a leader; `setTab`, `removeTab`; "\b" a Right Indent Tab); tables with real cells (`TableCell`: merged `rowSpan`/`colSpan`, fill, `CellStroke` sides, inset, `vAlign`, rotation; `TableRowFmt` heights; `footerRows`; `mergeCells`, `insertRow`, `insertColumn`, `cellOfChar`; Table and Cell Styles `setTableStyle`, `applyCellStyle` in `retroui/photo`); submenus in submenus (`submenu` in a `submenu`, four deep); .otf fonts' PostScript outlines `retroui/cff` (read by `parseFace` itself); colour fonts and emoji (COLR/CPAL layers `colorLayers`, sbix and CBDT pictures `colorPicture`, `isColorGlyph`; `TextOutline.picture` -- draw it, do not fill it; an emoji font in the font folders for what no other font has); font folders looked through a little each frame `fontScan`; threaded text frames `threadText`/`threadPages`; a table of contents and an index `retroui/booklists`; hyphenation `retroui/hyphenate`; Find/Change with GREP `retroui/textsearch`; Data Merge `retroui/datamerge`; a perspective grid `retroui/perspectivegrid`; brushes along a path `retroui/pathbrush`; more blurs `retroui/photoblurs`; the drawing program's path tools `retroui/pathtools` and live effects `retroui/liveeffects`; each paragraph its own format, the Paragraph Composer, keeps, spans, nested and GREP styles in `retroui/textengine` -- change paragraphs with `setParaFmt`/`changeParas`; Object Styles, Graphic Styles, Find/Change's Object search (`findObjects`, `changeObjects`), text variables (the Hijri date: `retroui/hijri`), hyperlinks and bookmarks in `retroui/photo`; hyphenation in seven languages by each word's `CharStyle.lang`; hanging punctuation and Optical Margin Alignment (`ParaStyle.hanging`, `TextData.opticalMargin`); nested line styles (`ParaStyle.lineStyles`); masters based on masters (`setBasedOn`); Data Merge into files (`exportRows`); layers renamed by content (`autoRename`, `retroui/photocc`); idle layers kept small (`parkLayer`, `parkAll`); spot inks and separations `retroui/inks`, `retroui/photoseps`; a tagged PDF with alt text, form fields, buttons and page transitions (`LayerAttrs`, `PdfOptions.tagged`, `interactive`); conditional text, track changes and notes (`withConditions`, `trackedInsert`, `acceptChanges`, `addMemo`); equations `retroui/mathtype`; a row or a column of frames `retroui/flexlayout` (`setFlex`, `arrangeFlex` in `retroui/vectormake`); EPUB and web pages `retroui/publish`, `retroui/photopublish`; Global Edit, Live Paint, Intertwine, Pattern Options and Tidy Up `retroui/vectormake`; Envelope Distort (`leEnvelope`); Relight, Upscale and an object's shadow `retroui/photorelight`; mockups `retroui/mockups`; styles and font pairs `retroui/designstyles`; an AI service of the user's own `retroui/aiconnect` -- nothing sent before one is set, its commands shown before they run, kept with `saveAiSettings`/`loadAiSettings` (the key in the keyring); work that follows each change in its own step: `stepEndHook`; the phone's folder picker behind `fileDialog(..., fmFolder)` with `systemFiles(true)`; a brush's dabs along a stroke, pressure to size and opacity, stamped on the GPU where there is one and on the CPU to the same pixels: `retroui/ink` (`dabsAlong`, `stampInk`); a big brush painted behind its stroke, the stroke drawn over the picture until it ends: `deferDabs`, `paintDabs` and `strokeInk` in `retroui/photopaint`, `PhotoView.ink`; products of matrices on the GPU from any thread but the one drawing the window: `retroui/gpucompute` (`gpuMatmul`; WebGPU in a page's threads), which the image models' runner uses by itself where it is quicker, `setNetGpu`; Arabic searched as written either way `arabicFolded`/`findFolded`, `findIn(..., arabic = true)` in `retroui/textsearch`; white spaces of a set width `fixedSpaceEm`, Copyfit `copyfit`, the tashkeel moved `CharStyle.markShift`, `<#->`/`<#+>` the pages a story comes from and goes on in (`Doc.jumps`); the Quran's text from a Tanzil file `retroui/quran` (`loadQuran`, `passage`, `search`, `checkTyped` -- never bundle the text); Islamic patterns as a shape's path `retroui/geopatterns` (`geoPattern`, `geoBorder`)). A program with no window (a command line, a server, a test that takes a picture of it): `retroui/headless` (`useHeadless` before `startApp`, `headlessInput`, `headlessShot`).

**Parts most apps need** (all in `import retroui` but jobs, tray, feeds):

```nim
import retroui, retroui/jobs

type Person = object
  name {.caption: "Full name", required, maxLen: 40.}: string
  age {.limits: (16, 70).}: int
  notes {.multiline: 3, help: "Anything to know".}: string
  id {.noForm.}: int

var p = Person()
var people: seq[Person]
var sel = 0
var history: UndoStack
var nav = initPages("list")
var load: Job[HttpResponse]

app "Staff", 520, 420:
  menubar:
    menu "&Edit": undoMenuItems(history)            # "Undo Add", grayed when nothing
  pageView(nav):                                    # pages over pages; Back: Esc, Alt+Left, the phone's
    case nav.page
    of "list":
      pageHeader(nav, "Staff")
      gridOf(people, sel, height = 8)               # a column a field; a header's click sorts
      if button("&New..."): nav.push("edit")
      if button("&Load"): load = fetch("https://example.com/staff.json")   # on a worker
      if load != nil and load.done: discard          # load.value.body, read between frames
    of "edit":
      pageHeader(nav, "New person")
      formOf(p)                                     # a field each; what is wrong said under it
      if button("&Add", enabled = formValid(p)):
        let before = people
        people.add p
        history.record("Add", people, before)
        nav.pop()
  undoKeys(history)                                 # Ctrl+Z, Ctrl+Y: after the text boxes
```

- `history.record(label, v, before)` keeps two whole copies of `v` a step
  (up to 200 steps): for a small value. For a big one (a list of shows
  with their episodes, a table of every item's state) use
  `history.did(label, undo, redo)` with closures that hold only what
  changed (the one row, and where it was).
- `job(proc (c: JobCtl): T = ...)` runs on a worker; read `progress`,
  `done`, `value`, `failed`, `error`, `cancel()` in the frames. The
  closure must not touch the UI or the app's globals (copy what it needs
  into locals first); in a loop, make each job in a proc of its own.
- `listDetail(open, listW): list do: detail` -- a list beside its details,
  one over the other on a phone.
- `animated(target, ms)` glides a number (a panel's x, a bar's width);
  `start = 0` counts up from there the first time (a score as its page opens);
  `easedSince(shownAt, ms, delay)` a page's own timeline (bars rising one after another).
- `retroui/motion`: `sprung(target, springBouncy)` (a spring: sent elsewhere
  half way it turns with its speed), `presence(shown)` (`.present` while it
  comes in or goes out, `.t` 0..1 to move and fade by), `glided(place(w, h),
  key = item.name)` (a box the layout moved glides there; a scroll does
  not), `dragSnap(r, points)` (`.r`, `.dragging`, `.snapped`),
  `staggered(i)`, `fixedSteps(10, running = playing)` (`.n` steps, `.alpha`),
  `played(open, [tween(0, 90, 400, cvExpo), tween(0, 1, 250, cvBack)])` (timed
  steps one after another -- back when `open` turns false; `together`, `loop`),
  `travelled(r, key)` (a box flying across the window: a card into its dialog).
  Frames only while something moves; at the end at once with less movement.
- `appeared(r, key = item.id)`: true the frame a box comes into sight (load a
  list's pictures only then); `resized(r)`: laid out at another size.
- From the command line, any app: `RETRO_SCRIPT="click:Add;type:Milk;key:enter"
  RETRO_SNAPSHOT=out.png ./app` (steps, then its picture, the app ended; 1 when
  a step fails); `RETRO_PLAY=...` plays them in the window (a demo film).
- `retroui/flows`: steps that wait, one after another --
  `discard flow("close"): (case ask("Save?", ["&Yes", "&No", "Cancel"]) of 1:
  save(); waitUntil(not saving) ...; return ends it)`; `pickFile`,
  `onWorker(T, work)`, `pause(ms)`, `nextFrame()`; `ownedFlow(owner, name)`
  with `cancelFlows(owner)` when its window closes. Not state flags kept
  across frames for a question and its answer.
- `retroui/fontfolders`: `useFontFolders(app)` at the start,
  `fontFoldersPanel(app)` in settings -- the user's own font folders on
  every system; any font file Windows has is read (.ttf, .otf, .ttc, CFF2,
  .fon/.fnt bitmap fonts, .pfb/.pfa Type 1, .woff: `retroui/fontconv`),
  and `unreadFontFiles(app)` says which could not be and why.
- The command search: every app with a menu bar has it on Ctrl+Shift+P
  (`retroui/commandhud`, nothing to write); `commandHudKeys = ""` for an
  app with its own search, `openCommandHud()` from a menu item.
- Placeholder text for a form, a list or a page being laid out:
  `lorem(3)` (Lorem Ipsum), `lorem(2, loremArabic)`, `lorem(4, loremBoth)`
  (the two in turn), `loremWords(4)` for a title -- `retroui/lorem`, in
  `import retroui`.
- A value worked out from others that is slow to work out (a filtered and
  sorted list of thousands): `import retroui/signals`; `let q = signal("")`,
  `let shown = computed(proc (): seq[Row] = rows.filterIt(q.value in it.name))`,
  then `shown.value` in the frame -- worked out again only when `q` changed
  (`q.value = text` sets it and asks for a frame). Not for ordinary state:
  an immediate mode frame reads plain variables.
- An app's image filters of today's editors: `retroui/photomore`
  (`shakeReduction`, `bilateralBlur`, `colorGrading`, `astroStack`...) --
  each a `FilterFn` of `retroui/photofx`.
- `retroui/dastkhat`: `carryDastkhat()` -- Arabic, Persian and Latin in one
  font, nine weights (`fontStyles("Dastkhat")`: Thin .. Black); a variable
  font's weights are styles (`fontFace(family, "SemiBold")`).
- `retroui/queries`: `let q = query("feed:" & url, proc (): seq[Item] =
  load(url), maxAge = 600_000)` -- the same entry for every page asking (loaded
  once on a worker; `q.loading`, `q.has`, `q.value`, `q.failed`, `q.error`);
  `invalidate("feed:")` loads them again (the old value shown meanwhile);
  `setQuery(key, v)` puts a change in at once. Use it for anything several
  pages show that comes from a server or a slow file.
- `retroui/arabicfonts`: `carryArabicFonts()` -- Scheherazade New, Lateef and
  Markazi Text (`ArabicFamilies`), Regular and Bold: Arabic for books, Persian,
  Urdu, Pashto, Sindhi.
- Shaping and bidi are the kit's own Nim (`retroui/otshape`, `retroui/typeset`):
  never link HarfBuzz or FriBidi into an app for them -- Arabic shapes as
  HarfBuzz 15 does, the Windows 3.1 Arabic fonts too, and the bidi algorithm
  passes Unicode's conformance tests. `fontCombo` lists the fonts used last
  first, then A to Z (`recentFonts`: keep it in the app's settings;
  `fontListOrder`, `noteFontUsed`); `glyphPicker` shows every glyph of a font.
- `retroui/forcegraph`: `var g = newForceGraph(); g.link(g.addNode("a", "A"),
  g.addNode("b", "B"))`, then `graphView(g, dp(300), sel)` (`look = nlBox` for
  a mind map; `.clicked`, `.doubleClicked`, `.dropped`). The layout alone,
  no window: `retroui/forcelayout` (`settle`, then `g.x[i]`, `g.y[i]`).
- AI with the user's own service (`retroui/aichat`, `retroui/assistant`):
  `let chat = newAiChat(loadAiSettings(app), "You help with...", [aiTool("add_note",
  "Adds a note.", [param("text", "string", "the note")], proc (a: JsonNode): string =
  notes.add a["text"].getStr; "added", confirm = true)])`, then
  `assistantPanel(chat)` in a pane; `chat.tools.add uiTools()` lets it work the
  app's controls by name; `aiToolLater` for a tool done frames later (`done(text)`);
  `publishTools(tools)` for agents outside (`retrokit mcp PORT` with RETRO_DRIVE).
  Pictures: `retroui/aiimage` (`generateImage`, `editImage` through a mask,
  `removeFromImage`) as a job's work -- OpenAI's images API, or a ComfyUI server
  of the user's (`kind = "comfyui"`, its address and checkpoint; `retroui/comfyui`:
  `comfyPing`, `comfyModels`, `comfyLama`, `comfyGenerate`, `comfyFill`). Vector art: `askVector(settings, words, vkIcon)` then
  `vectorAnswer` (an SVG of shapes only) and `doc.placeSvg(svg, box)`
  (`retroui/aivector`; `akDevice` works offline); the whole dialog is
  `vectorDialog(newVectorAsk(), settings, proc (svg, error, words: string) = ...)`
  (open it with `ask.open = true`). A tool that changes
  something: `confirm = true`.
- The device's own model (`retroui/modelstore`, `retroui/devicemodel`): the AI
  Connector's form is `aiServiceForm(settings, modelsOpen)` (it offers "This
  device", `akDevice`), and `modelStoreDialog(modelsOpen)` downloads models when
  asked; then `newAiChat(settings, ...)` works offline. One answer, no
  conversation: `askOnce(settings, system, text, onDone)` and
  `onceAnswer(settings, job)`. Search by meaning: `retroui/meaning`
  (`openMeaningIndex(file, modelPath(m))`, `update(items)`, `find(task,
  question)`). Never put a model in the app.
- Pictures through trained models (`retroui/nnet`, `retroui/vision`), each in a
  `job`: `depthOf(loadNet(modelPath(storeModel("depth-anything-v2-small"))), px,
  w, h)` (0 .. 1, 1 nearest), `subjectOf(net, px, w, h)` (0 .. 255),
  `readText(det, rec, px, w, h)` (`TextLine`: `text`, `corners`, `score`; the
  files of `storeModel("ppocr-v3")` by `filesOf`/`modelFilePath`; Arabic:
  `chars = arabicChars, arabic = true`). `modelStoreDialog(open, {muDepth,
  muSubject, muText})` offers them.
- `trayIcon(png, tip, ["&Show", "-", "E&xit"])` (`retroui/tray`) every
  frame while wanted: `.clicked`, `.picked` (the item's index).
- `retroui/feeds`: `parseFeed(xml)` (RSS, Atom), `parseOpml`, `toOpml`.
- Translations: `retrokit strings app.nim --lang:ar` writes app-ar.txt;
  `setUiLanguage("ar", @toolkitArabic, loadUiStrings(path))` (or a
  `const` table of `("English", "translation")` pairs, keys without the
  mnemonic's `&`); numbers in text with `trn(n, "{n} file", "{n} files")`;
  `RETRO_LANG=pseudo` shows what is not translated. Every text the user
  reads goes through a control or `tr` -- a status line drawn with `text`
  is `tr(...)` first; a text glued from fixed parts and values
  (`"Could not open " & name`, `"Page " & $i & " of " & $n`) has its parts
  translated when they are keys with their spaces ("Could not open ",
  " of "). README's "Translating an app" has the whole of it.
- Video: `videoView(url, height, w, autoplay = true, controls = false, key = "tv")` -- on
  Android the system's player in a window of its own over the app (nothing of the app's drawn
  over its picture: put a player's bars above and below it); `videoFullScreen("tv", true)`
  while it is drawn as big as the window (the phone on its side, the bars away).
- Sound: `audioView(url, speed = 1.5, title = "...", key = "player")`,
  `seekVideo("player", ms)`, `playVideo("player")`; it plays on in the
  background on Android (retroapk adds the service) and iOS. A player the app
  draws itself (a music app): `audioPlayer(path, "music", autoplay = true)` every
  frame (its `VideoEvent`: playing, `ended` in the frame it ended, position,
  length), `setPlayerVolume("music", 0.7)`, `setPlayerEqualizer("music", gains)`
  (10 bands, `EqualizerBands`; `playerEqualizer()` says if there is one); with
  `setNowPlaying` and `mediaKeys()` for the lock screen. The phone's music:
  `musicAccess()` / `askMusicAccess()` (Android asks the user), `musicFolders()`;
  each file's tags and cover with `retroui/audiotags` (`readAudioTags(path)`), on
  a `job` for a library. Its event's
  `error` says why the system could not play it (show it). Plain
  `http://` addresses need `retroapk --cleartext` / `retroios --cleartext`
  (else the kit asks for https).
- Shared in: `retroapk --share-target:text/plain,image/*` puts an Android
  app in the other apps' share sheets, `--opens:image/*,application/pdf` in
  a file manager's "Open with"; `sharedIn()` (`retroui/system`, each frame)
  gives what came: `text`, `files` (copied into the cache), `origins` (the
  document each came from when it may be written back to:
  `adoptSystemFile(file, origin)` writes the copy's changes back).
- Android extras (`retroui/system`): `notify(..., actions = ["Mark as
  read"])` puts buttons on a notification and `notificationActions()`
  (each frame) gives the presses as (tag, action); `retroapk --widget`
  gives the app a home-screen widget that `homeWidget(title, text,
  ["Pause"])` fills (its presses: the tag "widget"); `installApk(path)`
  hands a package to the installer (`--permission:REQUEST_INSTALL_PACKAGES`),
  `retroui/apkinfo`'s `readApk` reads one. The camera: `cameraCaps`,
  `cameraZoom`, `cameraFlash`, `cameraFocus`, `cameraExposure`; on
  Android `cameraPhoto` is full size and the view zooms with two fingers.

**What the interface guidelines ask, and the calls** (docs/hig.md):
on the desktop, `menuItem(..., hint = "What it does")` with `statusbar(menuHint())`,
`isDefault` for the item a double click does; `helpText "..."` after a control
whose use isn't plain (Shift+F1, `startHelpMode()`, F1); properties in
`let a = propertySheet(open, "Name Properties", page, ["General", "Summary"], 420, changed): ...`
bound to copies, `saOk`/`saApply` put them back; `closeGuard(dirty, name, save)` once a frame
after the content ("Save changes?" when the window closes; `saveChangesBox` for another
document replacing it); `msgBox(open, title, msg, ["OK"], miInfo, dontAsk)` for a tip;
`singleInstance("id")` first thing (false: quit). On a phone, `navBar(title, action = if
editing: "Done" else: "Edit", done = editing)` and `editTableGroup(header, editing): rows`
(`.deleted`, `tableMoved()`); `if beginModalSheet(open, "New Item", done = "Add",
doneEnabled = ok): ...; if endModalSheet(open) == shDone: add()` (call `endModalSheet` only
when `beginModalSheet` was true); `actionSheet(open, "", actions, anchor = ui.lastRect)`;
`bottomNav(items, sel, badges, search = i)`; `largeTitle(title, subtitle)` first in the page's
panel; `skeletonRows(n)` while loading; `liftMenu(ui.lastRect, key, actions)` after a row;
work saved by itself: `var items = restoreState("items", defaults)` and `keepState("items",
items)` in the frame -- no Save on a phone. `retroui/modern` has `largeTitle`, `skeletonRows`,
`liftMenu`, `growing`.

**The glass effect** (the Glass look): the kit's bars, menus, sheets and alerts are glass by
themselves; an app's own important control: `glassButton(label, prominent = true)`,
`glassSurface(r, radius, tint, clear = true)`; tool bar groups between `toolSeparator()`s;
`glassTint` (0 clear .. 1 tinted), `glassSolid` (reduced transparency, the system's followed),
`scrollEdge(r, top)` beside an app's own bar over scrolling content. Never glass on content.

**The device** (`import retroui/device`): `takeLink()` each frame (`retroapk
--links:myapp`, `retroios --links:myapp`, `registerLinks(["myapp"])` on Linux and Windows),
`askUnlock(reason)` then `unlockAnswer() == laOk`, `motion()`/`shaken()`, `pictureInPicture()`
(`retroapk --pip`), `dragToApps(paths)`/`droppedFromApps()` (Android), purchases
`storeStart()` until `ssReady`, `storeProducts(ids)`, `storeBuy(id)`, `storeEvent()` each frame,
`storeFinish(purchase, consumable)` (Android: the app brings Play Billing with `--java`). Codes:
`qrRead(bitmap)`, `barcodeRead(bitmap)` (`retroui/barcode`), `scannerView()` (`retroui/scanner`).
Values with every version kept cheaply (undo of a big document, last frame's state):
`retroui/persist` (`PVec`, `PMap`, `PSet`, `Rope`, `diff`); any value as text: `retroui/nif`
(`saveNif(path, v)`, `loadNif(path, T, default)`).

**The system's features** (`import retroui/system`; docs/system.md has
every system's answer and what the app declares): `notify`, `setBadge`,
`share`, `haptic`, `vibrate`, `location` (every frame while needed:
`psWaiting` until the first fix), `speak`, `setOpenAtLogin`,
`requestAttention`, `online`, `systemLanguage`, `battery`, `deviceInfo`,
`revealFile`. "Not here" answers false (never raises): fall back
(`share` false -> `putClipboardText`; `notify` false -> `toast`). Ask from a
click (phones and browsers ask the user). Secrets: `retroui/secrets` (on
macOS and Linux a keyring may wait for its password: ask for a secret
needed at start on a thread, not in the first frame);
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
`loadHistory`; examples/taskman.nim uses all of it. A command as the
computer's administrator (a setting of the whole computer): `import
retroui/admin` -- `runAsAdmin(key, exe, args, why)` each frame until it is
not `adWaiting` (the system asks: UAC, polkit's pkexec, macOS's password
dialog; `adNone` on phones and pages; `canRunAsAdmin()`). An Android app's
own Java (a service, a receiver, a VPN): `retroapk --java:DIR` puts
DIR/classes.dex in as classes2.dex and DIR/manifest.txt's entries in the
manifest; call it by reflection (`retroui/native`). examples/retrodns.nim
does both.

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
(`car.nodeNames`); `retrokit model car.blend` lists them. `car.addShadow()`
lays its soft shadow on the ground (again after its pose changes).

**A scene made in code**: `var s = Scene3()`, `s.materials.add
material3("Gold", color(255, 196, 60), metallic = 0.7, glow = 0.4)`,
`var b = box(0.7, 1, 0.7, name = "Year 1")`, `b.material = 0`,
`b.pos = vec3(...)`, `b.scale = ...`, `s.add b`; `addLine`, `addLabel`;
`fitView(s, cam)`. Meshes move each frame (`s.meshes[i].scale.y = h`);
`view3d(s, cam).picked` is the mesh tapped. Drawn on the GPU where frames
are, materials or not (examples/grow.nim).

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
web need `retroapk --permission:INTERNET` in an APK, and `--cleartext` for
pages on plain http. The app's own pages:
`webAppFolder(dir)` then `webView(webAppUrl("index.html"), ...)` (they
fetch each other as a site's files do); `webPermit(key, {wpCamera})` lets
a page use the camera; `webPrint(key)` prints it. `webStartScript(key, js)`
puts a script in every page of the view before the page's own (set it
before the view's first draw; to change it, set it and `webClose(key)`);
`webClearData()` clears the engine's cookies, storage and cache.
`webBlockList(hosts, patterns, spared)` keeps the engine from fetching an ad
blocker's list (`WebEvent.kept` counts it on WebView2 and Android);
`webScrollBars(key)` (before the first draw) makes the page's scroll bars the
kit's own, beside the view; `WebEvent.fullscreen` is true while a video of the page is full screen (then
`fullScreenWindow(true)` and hide the app's bars); `webSnapshot(key)` is the
page's last picture (`webSnapshotNow` asks for one). The app's own pages call
its procs typed: `import retroui/webbind`, `webBind addNote` (the page:
`await retro.call("addNote", n)`; `webClientTs()` its TypeScript), events with
`webEmit(key, name, json)` (`retro.on`), other sites allowed with `webTrust`.

**The system's other parts** (`retroui/system`, docs/system.md): `metered()`,
`systemWoke()` (true the frame after the computer slept), `systemPrefs()`
(less movement, high contrast, the text's size: the kit follows them),
`keepScreenOn(true)` on every system; `copyPicture(bitmap)` and
`pastePicture()` (the clipboard's pictures); `globalHotkey("Ctrl+Alt+N")` (a
shortcut of the whole desktop: Windows, X11, macOS); `watchFolder(dir)` and
`changes(w)` each frame (`retroui/files`); `retroui/install` (the app
installs itself for the user: `installFlags`, `installForUser`).
`retrokit linux PROGRAM` makes .deb, .rpm, PKGBUILD and a .tar.gz with
install.sh; `RETRO_LANG=pseudo` shows every text stretched and marked, to try
a layout for other languages.

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
  rcpts, rawMessage)`: "" when sent; a Bcc header is never sent),
  `retroui/mailsetup` (`findMailServers(email)`: IMAP, SMTP, POP3, a JMAP
  session, `appPassword` -- where the provider wants one); IMAP's `idle(c,
  seconds, stop)` waits for new mail (push); `retroui/pop3`
  (`pop3Connect`, `uidl`, `retr`, `dele`, `quit`), `retroui/jmap`
  (`jmapConnect(url, jmapBearer(token))`, `mailboxes`, `queryEmails`,
  `getEmails`, `emailChanges`, `download`, `sendRaw`), `retroui/ews`
  (Exchange: `ewsConnect(url, "DOMAIN\\user", password)` -- Basic, else NTLM
  by `retroui/ntlm` -- `folders`, `syncItems`, `getItems`, `mimeOf`,
  `sendMime`); blocking: on a thread of their own. Who a message is from:
  `retroui/mailauth` (`checkSender(raw, providerAuthservs(host))`: DKIM
  verified here, the provider's Authentication-Results from its own servers
  only, DMARC policy) and `retroui/mailsafety` (`cleanMail(html)`: tracking
  pictures out, tracking codes off links, links that are not what they say;
  `senderWarnings(name, address, knownDomains)`; `linkWarning(href, text)`
  before opening one); `retroui/domains` (the Public Suffix List's
  `registrableDomain`, IDN `toAsciiHost`/`toUnicodeHost`, look-alikes:
  `skeleton`, `looksLike`, `mixedScripts`); `retroui/dnsquery` (`dnsQuery(name,
  "TXT")`: the system's resolver, DNS over HTTPS where there is none). An
  encrypted database: `openDb(path, key = key32)` (`encryptDb`, `decryptDb`
  for a file made without one). `import
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

- Themes: `ui.theme = Dark` (`builtinThemes`: 28, ten of them made for
  phones -- Notes, Snow, Mint, Sky, Blossom, Lavender, Sunset, Graphite,
  Dusk, Night Notes), or the `theme` option; a `Theme` of your own is an
  object of colours. Never write a fixed colour for "good" or "bad":
  `goodColor()`, `warnColor()`, `badColor()`, `infoColor()` (and
  `goodBack()`... behind text) follow the scheme, dark ones too.
- A look of your own is the kit's controls with options, not controls
  drawn again (docs/customizing.md; `examples/bmi.nim`):
  `button("Save", accent = true, style = style(bold = true, size = 1.3), h = 42)`,
  `spin(n, 0, 99, w = 110, h = 44, style = style(size = 1.5))` (`edit`,
  `intEdit`, `numberEdit` too), `group "Title", glCaption: ...`,
  `radio("Metric", unit, 0, boxed = true)`, `withTheme(t): ...`,
  `withTextStyle(style(size = 1.2)): ...`, `gauge(title, v, lo, hi, bands)`
  and `rangeBar(bands, v, lo)` with `Band(upTo: 25, label: "Healthy")`,
  `pill("Paid", goodColor(), nfCheck)`, `toolSeparator(line = true)`,
  `toolSpace()` (what follows: at the bar's right end), and for the 3.1
  frame `app(..., captionIcon = true, captionAlign = caLeft, captionStyle
  = style(...))`. Only what no option gives is drawn on a `canvas` (its
  sizes are real pixels: `canvas(dp(120), dp(40))`).
- Text size: 12 pixels per em at 100 % on desktops and tablets, 15 on
  phones; controls grow with the text. `setTextScale(120)` (the user's text
  size), `setUiScale(125)` (everything), `setBaseTextSize(14)` (your app's
  100 %).
- Fonts: Suhar App (the default -- Latin and Arabic drawn together --; its paragraphs in
  Suhar App Read: `paragraph`, Markdown, `style(read = true)`), FreeSans, FreeSerif,
  FreeMono (`setUiFont(ufSans)`...), built in with Arabic, Thai and Vietnamese -- the
  symbols the kit writes (∀ ∂ ∈ ∝ ⟨ ⟩ ☎ ♀ ♂ ♭ ♮ ♯...) drawn into Suhar, a letter it has not
  drawn (Thai) from FreeFont; `loadUiFontFile(path)` for a font of your own,
  `setUiFontVariable(data)` one variable font file for every style (its weights, italic and
  optical size); a font's own GSUB and GPOS shape its Arabic (with presentation forms or
  without); `label`, `paragraph`, `styledText`, `heading` grow by what their marks reach
  (`inkReach`), `setTallLines(true)` makes every line tall for fully vowelled text; an Arabic
  paragraph in an English interface is set from the right (`lineStart`); `appearanceSettings` lets
  the user choose (theme, font, text size, Sharp text, window frame,
  title bar buttons) and
  `look = "myapp"` keeps it.
- Arabic and right-to-left text work everywhere (joined, bidi);
  `setRightToLeft(true)` (or `setUiLanguage("ar")`) mirrors the interface -- captions on
  the right, rows from the right; `setRtlInterface(true)` alone only makes mixed lines read
  right to left. Markdown in Arabic reads
  right to left by itself: its lists' bullets, its quotes' bars and its
  tables' first column at the right.
- The window frame: the system's or the Windows 3.1 frame (`frame` option;
  users switch from the control or system menu; kept per app). The 3.1
  frame takes the theme's colors and has a size grip in its bottom right
  corner (the status bar's end; `sizeGrip()` says where). `resizable = false`
  (`setResizable`) keeps the window's size: no sizing border, maximize
  button or grip, and the system's frame fixed too.
- Matte and Gloss: `uiLook = lookMatte` (flat and sharp; `MatteLight`, `MatteDark`)
  or `lookGloss` (glossy -- iOS 6's parts measured and drawn in code --, lit bars, menus as
  popover lists, a switch with ON and OFF, a black tab bar, the window plain or with
  pinstripes (`glossPinstripes = true`), its blue parts in the scheme's hue -- `glossTone(s, v)`,
  `glossTint(iOS6color)`, `glossDetail()` -- gray buttons and
  the default one blue -- `button(label, isDefault = true)`; `GlossLight`, `GlossDark`), at the same sizes; `glassLook()` is true in them too, `matteLook()` and
  `glossLook()` tell them apart; `lookSchemes(look)`, `titleBar`, `barFace`, `tintedFace`.
  `GlossOnyx` is Gloss's third scheme (black, crimson; a floating tab bar and pill buttons:
  `glossOnyx()`). Glass draws cards with `glassPlate(r, radius)` and the lit, glowing blue with
  `glassBlue(r, radius)` (`modernGlass()`: Glass itself). Its modern glass effect
  (`glassEffect`, on by default; "Glass effect" in Appearance): the tab bar a glass capsule
  floating over the content, which runs under it and scrolls its end out from under it
  (`ui.floatInset` -- the page and panels do it themselves), the navigation bar, a search bar
  under it and the status bar one band of glass over the content -- put the page in a plain
  `beginPanel(-1, key, plain = true)` (or a `pageView`) right under them and it scrolls up under
  the glass, seen through it blurred --, the bars' buttons glass, menus, dialogs, sheets, alerts
  and the side menu glass with lit edges; `glassSurface(r, radius)` draws a pane of it for an
  app's own floating part (`glassRim`, `glassFx()`; `glassBandFace(r)` a bar's glass). On a touch
  screen in the newer looks every scroll bar is a thin line over the content (`overlayBars`);
  `scrollBarFor(..., overlay = false)` keeps the bar where a finger doesn't move the view. On Android and iOS Glass and Gloss
  are the phone's (`phoneLook()`): touch sizes on a tablet, dialogs as pages; and the look's own
  colors follow the system's dark theme (`systemColors`, on there by default;
  `followSystemColors()` runs in `appFrameDone`) -- don't fix a phone app to a light scheme.
  The default look is Classic on computers and the web, Gloss on Android and iOS (set
  `uiLook` before the app starts for a look of the app's own). In Gloss a scheme not of its
  own (`glossOwnScheme()`) colors the bars, the tab bar and the side menu; the status bar
  over the app's bars is the top bar's color, darker (`statusBarColor()`).
- The phone controls' own colors and sizes, as `Theme` is for colors: `mobileStyle =
  MobileStyle(bar: c, barText: c, statusBar: c, tabBar: c, tabText: c, tabChosen: c,
  sideMenu: c, sideMenuText: c, group: c, groupLine: c, rowText: c, rowDetail: c,
  groupCorner: 14.0, rowHeight: 50)` -- each left out stays the look's --, or
  `withMobileStyle(s): ...` for a part of the window.
- Settings rows (`settingToggle`, `settingCombo`, `settingLink`...) in a `tableGroup` are its
  rows, as a phone's settings: `settingCombo` shows the chosen one at its end and opens a page
  of choices (over the dialog it is in: `afterDialog(proc () = ...)` does that for a dialog of
  your own opened from a control in a dialog). `appearanceSettings()` groups its rows by itself
  with touch sizes in Glass, Matte or Gloss. `settingToggle` and `settingCombo` know their row
  by its title, so `var b = prefs.getBool(...); if settingToggle("X", b): save(b)` works; other
  controls bound to a variable (`checkbox`, `slider`, `edit`) are known by its address: bind
  those to a global or an object's field, never a local made in the frame.
- On Android an app is a window like other apps' in split screen, a tablet's small floating
  window and desktop windowing (the system's frame round it, sized down to 320 by 320 dp): lay
  it out for every size (`isCompact()`), don't fix the orientation unless it must be.
- A phone app is made for tablets too: `isCompact()` (a phone in portrait) gives pages one
  over another with Back; otherwise (a tablet, a phone on its side, a computer) put the list
  down the left -- about a third, at most 340 dp -- and the page chosen beside it, each
  under its own `navBar` (Back only past the first page beside it), the row shown drawn
  chosen with `tableRow(selected = true)`; the phone's Back then closes the app. Draw both
  in its tests. `listDetail(open, listW)` does it for a simple list and its details.
- Controls from phones, on desktops too (`retroui/mobile`): `navBar(title, back, action)`
  (returns `npBack`, `npAction`), `wheelPicker(items, sel)` (and `wheelPicker(count, item,
  sel)`), `dateWheels(d)`, `timeWheels(h, m, minuteStep, hours12)`, `quantity(v, lo, hi)`,
  `pageDots(page, pages)`, `swipeRow(title, actions, detail, glyph)` (a `SwipeHit`:
  `clicked`, `action`), `actionSheet(open, title, actions, destructive)` (the index picked;
  `tableRow(...).menu` -- a finger held on a row, a right click -- is when to open one for it),
  `cardShelf(cards, key)` (a sideways shelf of `ShelfCard`s: the one tapped),
  `textKeyboard(kbEmail, keNext)` before a text box (the phone's keyboard it asks for; number
  boxes ask for digits by themselves; Next comes as Tab), `pullRefresh(loading)` right after
  `beginPanel` (true once when pulled down: fetch again),
  `bottomSheet(open, title): ...`, `popover(open, anchor, width): ...` (`anchor`:
  `ui.lastRect` after the button), `alertBox(open, title, message, buttons, cancel)`
  (the button pressed), `searchBar(s)`, `actionBar(actions, back, signature)` (before
  the content; -2 Back), `wheelGroup: ...`, `roundButton(rkAdd, label)` (a round button
  with a sign: `rkAdd`, `rkRemove`, `rkDetail`, `rkInfo`), `indexBar(letters, h)` (A to Z
  down a list's side: the letter under the finger while it is down, else -1),
  `messageBubble(text, bkMine, time)` (`bkTheirs`, `bkMine`, `bkMineText`), `clockFace(h,
  m, s, night = true, label = "Tokyo")`, `appIcon(glyph, label, tint, badge)` (a home
  screen's icon: true when tapped), `texture(r, txLinen)` (`txPaper`, `txFelt`, `txLeather`,
  `txPinstripe`: drawn in code), `checkRow(title, done, detail, flagged = true)` (a to-do's
  row: its round check `toggled`, the rest `clicked`), `editRow(title, i)` in a list being
  edited (a `RowEdit`: `reDelete`, `reMove` from `index` to `to` -- change the list after
  the loop), `vslider(v, lo, hi, h, label)` (an equalizer's band), `ratingStars(v)`,
  `coverFlow(covers, sel, titles, subtitles)` (the one opened, else -1),
  `slideToConfirm(label)`, `bigButton(label, btGreen)`, `edit(s, hint = "New task")`, a
  side menu (`sideMenu(menuOpen, 280): sideMenuHeader("Music"); if sideMenuItem("Radio",
  nfWifi, selected = place == 5): ...` -- opened by `navBar(title, menu = true) == npBack`
  at a place's first page; on a tablet the same items down the left, `sideMenuBack(r)`
  under them), and rows in groups as a phone's settings:
  `tableGroup(header, footer): tableRow(title, detail, taChevron, glyph, subtitle,
  picture = cover, tint = color, selected = shownBeside)` (a `TableHit`: `clicked`, `info`), `tableSwitch`,
  `tableButton`. A phone app with its own bars: `appNavBars = true` (no 3.1 caption in
  the newer looks); `RETRO_LOOK=gloss RETRO_SIZE=390x800 RETRO_TOUCH=1` to try it on a
  desktop.
- The Glass look: `uiLook = lookGlass` before `startApp` (users pick "Look" in
  `appearanceSettings`, kept with `look`) draws every control as frosted glass --
  capsule buttons, rounded check boxes and switches in the highlight, slim scroll
  bars, rounded menus and groups -- at 3.1's sizes, in any scheme (`GlassLight`,
  `GlassDark` are made for it; the high-contrast ones stay Classic). `glassLook()`
  tells a control of the app's own which to draw; `glassFace`, `glassWell`,
  `glassAccent`, `fieldFace` (a field, rounded, the ring while it has the keys),
  `glassTrack` (a segmented choice's), `glassCard` (a card's color), `softShadow`,
  `selectFill`, `roundFrame` and `roundRectShaded` draw its parts. Its menus, dialogs
  and dropped lists are real frosted glass (`frostedGlass`; `frostedFace(r, back)`
  for a popup of the app's own). A page's tabs are a segmented control over a card,
  groups and cards rounded cards.
- A terminal: `import retroui/terminal`; `var term = newTerminal(); discard term.spawn()`
  (the user's shell; `spawn(@["htop"], cwd = dir)` another program) and
  `terminalView(term, lines = -1)` each frame -- xterm's colors and keys, scrolling back,
  copy (Ctrl+Shift+C) and paste, the mouse to a program that asks; `running`,
  `exitCode`, `title`. With no program, `feed(text)` shows an app's output in its colors
  and `onInput` gets what is typed. Linux, macOS, the BSDs, Android, Windows 10 (1809+).
  kitty's keyboard and graphics protocols for the programs that ask (`kbFlags`;
  `showPicture(png, cols, rows)` shows one of the app's own). Menus: `terminalView(term,
  menu = proc () = ...)` adds the app's items to its right-click menu; in the menu bar,
  `terminalEditItems(term)`, `terminalViewItems(term)` (text bigger, smaller: `zoomText`),
  `terminalItems(term)` (Clear Scrollback, Reset); `findText(text, back)` and
  `selectNone` for a find bar; `terminalKeysFirst(term)` before the menu bar gives the
  program Alt and a letter and F10 (bash, mc). Arabic and Hebrew show as they are read
  (`term.bidi`, true; `shownText(row)`); `term.boldBright` (bold in the bright colors, a
  PC's), `term.boldText` (every letter bold); Shift+PgUp/PgDn scroll back.
- Surfaces: `surface frostedSurface(): ...` -- a panel that blurs what is under it
  (a photo, a map), rounded and shadowed, what is in it kept in its corners;
  `Surface(blur, face, corner, shadow, border, pad)` for another (a card that
  floats: `Surface(face: ui.theme.face, corner: 8, shadow: 10)`); `drawSurface(r,
  s)` at a rectangle of the app's. `backdropBlur(r, radius, tint, corner)` blurs
  what is drawn so far under `r` (kept while that does not change: cheap to leave
  on screen); `masked(r, corner): ...` keeps what is drawn inside rounded corners
  (a picture in a circle: `corner` half its side).
- Title bars the kit draws (the 3.1 frame, dialogs, `mdiWindow`s) have
  Windows 95's minimize, maximize and close buttons; X does what Alt+F4,
  Esc (a dialog) or Ctrl+F4 (an inner window) does, so `closeRequested`
  still lets the app ask to save. `captionButtons = cbWin31` before
  `startApp` gives 3.1's two triangles and no close button; users pick
  either in `appearanceSettings` ("Title bar buttons", kept with `look`)
  or the 3.1 frame's window menu. A `msgBox` whose last button is not
  Cancel, Close or OK (Yes/No) grays its X. Windows 11 shows its snap
  layouts over the 3.1 frame's maximize button.
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
  (`ui.composing`) and comes as typed text when settled (iOS too). On a
  phone the box with the focus is scrolled above the on-screen keyboard.
- Scaling: sizes and text follow the screen's scale exactly (125 %, 150 %,
  175 %...), lines stay on whole pixels; nothing to do in an app.

## 9. Build and package

```sh
nim c -r -d:release -d:useMalloc app.nim                      # this computer
nim c -d:release -d:mingw --cpu:amd64 --app:gui app.nim        # Windows .exe from Linux/macOS (MinGW)
RETRO_APP=photo nimble exe                                     # a kit example for Windows: zig 0.15's clang, else MinGW
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
start fresh each time but for what `keep` names (`import retroui/keep`;
`keep page, names` after they are declared: each comes back as the run
before left it -- anything `std/jsonutils` reads and writes; nothing is kept
outside `--watch`). `retrokit run --android app.nim` builds the APK, installs
it on the phone adb sees, starts it and shows its log (`--watch`: again on
every save). `retrokit run --watch app.nim` does the same on any
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
many, "signal 9": BUILDING.md, "Building on a phone or tablet"). The
APK's library is stripped; its names are kept beside it in
`APP-symbols/ABI/libmain.so`: keep that with each APK, and `retrokit
symbolize report.txt APP-symbols` names a crash report's frames
(`--debuggable` leaves them in the APK). The activity is `singleTask`:
the app's start runs once in a process, so an app's globals are set up
once.
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
- A finger's press just beside a small control is its, as if 44 points across
  (`TouchTarget`); a tap moved 8 points (`TouchSlop`) is a drag; a long press is
  the right click (on a word in a text box: the word chosen; on a list's row:
  that row). A control of the app's own: every clickable part through
  `interact`, its hover only for `hit.showsHover`.

## 11. Common mistakes

- A `col` in a plain `row` takes all the room left, so what comes after it
  (a combo, tool buttons) is squeezed to nothing: give the row its widths,
  `row([40, -1, 0])` (a picture, the text, then the control at its own
  width). Two panels in a plain `row` are the same: `row([-1, 130])`.
- Keeping state in a local inside the frame block (it resets every frame).
- The same control drawn twice in a loop without `withId` (they share state).
- Blocking work (big files, network) in the frame code: the window freezes.
  Use `job` / `fetch` (`retroui/jobs`).
- A closure for `job` made in a `for` loop: every one sees the loop's last
  values. Make each job in a proc that takes the values.
- Calling controls outside the `app` block (or outside `beginFrame` ... `endFrame`).
- Guessing a parameter name: check the signature in the source or docs.
- Drawing a button, a panel or a number box by hand to change its colour,
  its text or its height: it loses the keyboard, the focus ring and the
  screen reader. Use the control's options (section 8, docs/customizing.md).
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
- `var x: seq[T]` (a string, a picture, an object of them) declared without
  a value, given one in an `if` or filled in a loop, and then given another
  (`x = sorted(x)`, `x = @[]`): Nim 2.2 never frees the first. The same for
  `result`. Give `x` its value where it is declared (`var x: seq[T] =
  @[]`), `result` one at the proc's start; `python3
  path/to/retroui/tools/writecheck.py app.nim src/` finds them.
