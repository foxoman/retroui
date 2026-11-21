# Working on Retro Nim UI

Rules for anyone changing this repository -- people and AI coding agents
alike. To build an app *with* the kit, read `skills/retroui/SKILL.md`.

## The project

- Retro Nim UI (`retroui`), a Windows 3.1 style immediate-mode UI toolkit
  for Nim, by Sultan Al Isaiee (@foxoman) -- www.foxoman.net --
  sultan@foxoman.net. Repository: https://github.com/foxoman/retroui
- `src/retroui.nim` and `src/retroui/` -- the toolkit;
  `src/retroui/uirelays/` -- the platform layer (a fork of nim-lang's
  uirelays, kept generic: see below); `src/retroapk.nim`, `retroios.nim`,
  `retrokit.nim` -- the command-line tools; `retroweb.nim` (web pages) and
  `retrostore.nim` (store packages, 3D models) are retrokit's commands.
- `examples/` -- the example apps (Gallery, Retro Atelier, Retro Files,
  Retro Mail, Retro Communicator, Retro Board, Retro Task Manager, HR
  Book, Retro Navigator, Retro DNS, Retro Podcast, 7GUIs, Notepad,
  Ledger, Charts...). They are
  built only when asked, one at a time (`nimble photo`, `nimble photoexe`,
  `RETRO_APP=photo nimble exe`...), never by `nimble install`. GitHub's
  Release workflow (`.github/workflows/release.yml`, on a `v...` tag or by
  hand) builds Gallery, Files, Photo, Board, Mail, Navigator, DNS, 7GUIs
  and Podcast for Linux, Windows, Android and macOS onto the release.
- `src/retrodesigner/` -- Retro Designer, the visual designer
  (`retrokit designer app.nim` builds it once per computer and runs it;
  docs/designer.md). It reads and changes the user's own `.nim` file with
  Nim's parser (`compiler/parser`), as edits of the text at the nodes'
  places: a change keeps the user's comments, blank lines and style, and is
  read again before it is kept. `registry.nim` is made by `python3
  tools/gendesigner.py` (never by hand): run it after adding or changing a
  control or an example of the guide. It stands on public parts of the kit
  (`windowBox`, `inert`, `showMenu`/`hideMenu`, `ui.measuring`/`notePlaced`,
  `peekId`); keep them generic -- they are for any preview, not the
  designer's alone. It is purely a designer: it never runs or compiles the
  user's app.
- `tests/` -- headless tests on a fake screen driver (`tests/harness.nim`).
- Jobs (`retroui/jobs`): a worker runs a closure made on the screen's
  thread; the closure goes back to that thread to be let go of, and a
  job's value is moved out, never shared (ORC counts a closure's
  references on one thread only). A loop that makes jobs makes each in a
  proc of its own (closures in a loop share the loop's variables).
- No thread for each task: a thread that ends leaves behind what ORC's
  cycle collector began for it (`docs/nim-bugs.md` 6, about 4 KB each).
  Work goes to the kit's lasting workers (`retroui/jobs`), or to one
  thread kept for the program's life (`retroui/admin`).
- uirelays' X11 and Wayland drivers also wait on the descriptors of
  `addWaitSource` (the tray's D-Bus connection): a kit module that needs
  the loop woken by a socket adds one there, generic, never a driver of
  its own.
- `docs/customizing.md` -- how a control is made to look different (its
  options), how controls are put together, how one is drawn, and how the
  kit itself is changed; `examples/bmi.nim` is its worked example, and
  `tests/test_looks.nim` runs its samples. A new look is an option with a
  default that draws what was drawn before (`accent = false`, `boxed =
  false`, `h = 0`, `style = TextStyle()`, an enum such as `GroupLook`),
  never a second control; a colour a scheme may want its own of is a
  `Theme` field with alpha 0 meaning "made from the others", read through
  a proc (`accentColor()`, `goodColor()`); a control that takes a `style`
  is measured with it (`labelWidth(label, st)`, `lineHeight(st)`).
  Every scheme in `builtinThemes` keeps its text readable -- 4.5 to 1 on
  the window, the fields, the buttons, the highlight and the accent
  (`tests/test_looks.nim` fails otherwise).
- Layout in Retro Atelier is the kit's: `retroui/photobook` (a `Book` of
  page `Doc`s: facing pages, masters, numbers, text from page to page,
  ".rpb", PDF), Text Wrap in `retroui/photo` and `retroui/textengine`
  (`Layer.wrap`, `wrapSide`, `wrapOpts`, `wrapHoles`, `wrapOutline`, `wrapContour`
  -- an object's real outline from its pixels, its edges or a document path --;
  `wrapBoundary`, `wrapHandles` to draw and drag it; `rewrap` while a layer is
  dragged follows its live shift or warp; `TextData.holes` and `wrapLeast`; tab stops
  `ParaStyle.tabs` -- `tabAdv` in `layoutPlain` sets each tab as its line is broken; tables
  `tableLaid` (cells `TableStyle.cells`, rows `rowFmts`, a continued box's `tableRow0` and
  `tableHead` set by `remainder`), Table and Cell Styles in `retroui/photo`; the line breaker's `freeSpans`). The app (`examples/photo/book.nim`)
  only shows them. A page's document is an ordinary `Doc`; the book sees
  changes by `Doc.ver`. Pages not shown are parked: never keep a page's
  `Doc` across a call that parks (`park`, `reflow`, `saveBook`,
  `saveBookPdf`, `autoflow`) unless it is in `keep`. An object across the
  spine is its page's; its part on the facing page is a copy
  (`Layer.fromSpan`) that `syncSpread` and `doc` make again -- never
  edit a copy, change the object. The baseline grid is the book's
  (`BookSetup.baseline`); a text on it carries the grid's step and start
  (`TextData.gridStep`, `gridStart`, set by `alignToGrid`), and
  `setSetup` moves them when the grid changes. Drop caps are the type
  engine's (`ParaStyle.dropLines`): the big letters are drawn apart, the
  same letters stay in the text as wide as nothing (carets and indexes
  as they were).
  `tests/test_photobook.nim` and `tests/test_photobookapp.nim`.
- Vectors from pictures and type: `retroui/imagetrace` (`traceImage`),
  `retroui/photovector` (`textShapes`, `blendShapes`); templates for new
  drawings and books: `retroui/layouttemplates` (no app code in them --
  each template builds a `Book` or is SVG). A new layer's pixels must
  stay memory the system gives as zeros: clear a layer with `clearSet`,
  never by writing zeros over all of it (a layer a shape or text is
  drawn on at once: `addLayer(fresh = true)`, and its first drawing
  clears nothing -- never for a layer whose pixels something else
  writes first), and keep the composite equal
  with `compositeSpans` on and off (`tests/test_photospeed.nim`).
  `tests/test_imagetrace.nim`, `tests/test_outlines.nim`.
- Tables, a font for each script, charts, maps, live shapes, IDML and
  Check Document are the kit's: `retroui/textengine` (`TableStyle`,
  `tableTheme`, `ScriptFont`, `scriptFontsApplied` -- anything that reads
  runs of one font, as the PSD writer and IDML do, takes the text through
  it), `retroui/infographics` (`chartSvg`, `mapSvg`: SVG placed with
  `placeSvg`, so a chart is shapes and type), `retroui/liveshapes`,
  `retroui/idml`, `retroui/preflight`. What an app keeps with a layer
  (a chart's or a live shape's settings, as JSON) goes in `Layer.meta`,
  which undo and the file keep. A dialog that changes the document live
  opens one step when it opens, applies when its settings differ from the
  ones last applied, ends the step on OK, and cancels it on Cancel -- or
  when it is closed any other way (a `pending` flag, checked before the
  dialog is drawn). `tests/test_infographics.nim`, `tests/test_idml.nim`.
- Notes, lists, search, merge, frames, the grid and brushes are the
  kit's too: footnotes and endnotes and Auto-Size in `retroui/textengine`
  (`insertNote`, `tidyNotes`, `autoSized`: `drawText` sizes the box, so
  undo keeps it), `retroui/booklists` (table of contents, index),
  `retroui/hyphenate` (Liang's patterns, a word in its `CharStyle.lang`:
  `vendor/hyph-*.tex` keep their notices; the programs build in the
  `.tex.z` beside each -- after changing a `.tex`, pack it again with
  `python3 tools/packlzma.py src/retroui/vendor/hyph-*.tex`, which
  `test_textengine` checks), `retroui/textsearch` (GREP patterns over
  characters; glyphs and saved queries), `retroui/hijri` (the Hijri
  dates of the Text Variables: Umm al-Qura's table, its MIT notice in
  `vendor/LICENSE-hijridate.txt`), `retroui/quran` (a Tanzil text
  file the user downloads or has; never put the Quran's text in the
  repository, a test's data or an app: Tanzil's terms want it copied
  verbatim with its source named -- `test_arabictype` has five ayat as
  they are written, to read), `retroui/geopatterns` (Islamic patterns as one path),
  `retroui/datamerge`, `retroui/perspectivegrid` (`ontoPlane`,
  `pixelsOntoPlane`; the grid is `Doc.perspective`, saved),
  `retroui/pathbrush`. Text in a box keeps to it: what does not fit is
  overset (`TextLayout.overflow`), never drawn below the box. Threaded
  frames: `threadText` and `unthreadText` on a page, `threadPages` and
  `unlinkPages(keepText = false)` across a book's pages, as the layout
  program does it (a box's own words go to the story's end; a broken
  thread empties the boxes after it). IDML writes a thread as one story,
  each frame naming the one before and after it, and reads it back so.
  A painted layer copied keeps its memory sparse: `sparseCopy`, never a
  plain `seq` copy of a big layer. `tests/test_handpass.nim` uses every
  tool through the window's input and undoes it all: a tool that changes
  the picture without an undo step, or a step that does not take back
  what it did, fails it.
- The three programs' ways are the kit's too: new blurs in
  `retroui/photoblurs`, the drawing program's path tools in
  `retroui/pathtools`, live effects (Distort & Transform, Warp, Repeat)
  in `retroui/liveeffects` -- set as `liveEffectsHook` and drawn each
  time the shape is, never baked into its path until Expand Appearance;
  more fills and strokes are `ShapeData.appearance`, brushes and widths
  `StrokeBrush` and `WidthPoint`. A paragraph's format is its own:
  `CharStyle.para` names one of `TextData.paraFmts` (0 the text's
  `para`), the paragraph's first letter says which; change paragraphs
  with `setParaFmt` and `changeParas`, never by setting `para` while the
  text has others, and let `insertText` and `deleteText` keep them even
  (`evenParas`, `tidyParaFmts`: the first paragraph's format is always
  `para`, what lists and drop caps read). The Paragraph Composer is used
  for justified text only (Auto), so text set before keeps its lines.
  Text variables (`<file>`, `<date>`, `<head:Style>`, `<ref:name>`) are
  shown by `effectiveText`, written as they are while typed; a book knows
  each page's destinations and running heads (saved with the page) so a
  cross-reference needs no page opened. Links and bookmarks reach the
  PDF through `PdfOptions.dests` and `pageMap`, filled by the book's
  export. Object Styles set only what their `use` flags say. The hot
  loops of mixing, blurring and resampling are in `retroui/simd`
  (`simdkern.h`, the compilers' vectors): a change there keeps the plain
  loop's result -- `tests/test_simd.nim` checks it both ways
  (`-d:retroNoSimd`) -- and is measured with `-d:useMalloc` before it
  stays. `tests/test_photoparity.nim` drives the new tools, panels and
  dialogs of Retro Atelier through its menus and its window's input.
  A layer's pixels are `L.px` (a proc: it opens a parked layer out
  again) over the field `pxRaw`; a layer made in code sets `pxRaw` in
  its constructor, and nothing else reads the field. The layers under
  the current one are kept mixed in tiles (`compositeBelow`), known
  fresh by those layers' settings and their `ver`: whatever changes a
  layer's pixels raises its `ver` (and calls `markAll`), or the tiles
  show what was. A new
  kernel in `simdkern.h`/`simdmix.h` gives the very pixels of the plain
  loop, with AVX2 (`forceAvx2`) and without -- `test_simd` checks both.
  Masters based on masters: `setBasedOn` refuses a ring, and a master's
  own copy of its parent's layers (`fromMaster` set) is never copied on
  again nor written to IDML as its own.
  The kit's own kernels (`retroui/simdkit`, `simdkit.h`: the UI
  renderer's rows, JPEG, PNG, zlib, the camera and video) keep the plain
  loop's very bytes, on x86 with AVX2 (`kitForceAvx2`) and without, on
  32-bit and on ARM -- `test_simdkit` checks each against its loop; one
  that cannot be sure (JPEG's IDCT past its bounds) hands the work back to
  the loop. Helpers taking or giving 32-byte vectors are macros in
  `simdkit.h` and `simdllm.h`: a function of AVX2 and one without pass
  them two ways, and a build without optimizing calls them (the model's
  rows read the wrong place in the tests' builds) -- `tools/warncheck.sh`
  checks every header. What follows a change in another
  layer -- a Flex Layout's frames, a Global Edit's shapes -- is done in the
  same step through `stepEndHook` (`touch`, `touchLayers` there, never
  `endStep`), so one undo takes both back and an undo is not followed. A
  layer's print and reader settings are `L.attrs` (`LayerAttrs`: saved
  only when set); text that is changed while tracked carries who and when
  in its `CharStyle` (`added`, `deleted`, `memo`, `condition`), and
  `effectiveText` leaves out what is deleted or hidden as it prints.
  `retroui/aiconnect` sends nothing until the user has set a service, and
  Retro Atelier shows the commands before running them; its key is kept
  in `retroui/secrets` (`saveAiSettings`/`loadAiSettings`), never in a
  settings file, and asked for only when it is wanted (`withKey`). Spot inks are named on `ShapePaint.spot`; a name
  `Doc.spotInks` does not hold prints in process inks.
- Open and Save As on a phone: `retroui/systemfiles` behind `fileDialog`
  and `filePicker` (Android: `tools/android/RetroActivity.java`, then
  `sh tools/android/build_dex.sh`; iOS: through the Objective-C runtime).
  Its logic is tested with a made-up system (`tests/test_systemfiles.nim`);
  the two real ones are not run by any test.
- SVG in Retro Atelier: `retroui/svgimport` reads (shapes, text, pictures,
  groups, patterns, filters, masks, blending; `svgPieces`, `placeSvg`),
  `retroui/photosvg` writes (`svgOf`, `svgLosses`, `svgOwn`). What one
  writes the other must read back the same: `tests/test_photosvg.nim`
  opens what was written and compares the layers, the type, the picture
  and the file written again. How it is drawn is compared with resvg:
  `tests/data/svg/*.svg`, each with a .png of it as resvg draws it; a new
  thing read gets a drawing there (`fx-*.svg`: made with resvg_py, 96
  pixels wide, FreeSans given for the text), and where resvg and the
  specification differ (feMorphology's size, feDisplacementMap, an
  feOffset's own rectangle, `direction: rtl`'s start, `text-transform`)
  the specification is followed and tested by numbers instead. What an
  SVG has no word for is written in `data-retro-*` attributes and read
  back by `placeSvg` alone; JSON from a file is read through `ownJson`
  (its length and depth bounded). Text is set on any thread: a thread
  other than the first has faces of its own (`typeWorker`, FreeSans,
  FreeSerif, FreeMono only) -- nothing of the type engine's tables is
  shared between threads. A picture an SVG names by a file is read only
  under the SVG's own folder.
- **The window's thread never asks a disk anything.** A disk may take
  as long as it likes -- a network drive that is not connected, a cloud
  folder -- and the window, its Exit too, would wait with it. What a
  widget needs of the file system each frame it asks with `later`
  (`retroui/background`: answered with what is known, asked on a thread);
  what the user asked for, with `askNow` (waited for a second and a half
  at most). No `dirExists`, `walkDir`, `getFileInfo`, `diskSpace` or read
  of a file in what is drawn every frame; a cloud file that is not on the
  disk (`FileItem.offline`) is read only when it is opened. On Windows a
  window that stops answering writes where (`retroui/hangwatch`): a
  report of one names the proc to move off the thread.
- Mail's checks (`retroui/mailauth`, `retroui/mailsafety`,
  `retroui/domains`, `retroui/dnsquery`) believe a provider's
  Authentication-Results only from its own servers and only the topmost
  (`providerAuthservs`, or one learned from 50 messages and 80 in a
  hundred); a DKIM signature counts only when its domain is the From
  address's own or its organization's, and one that proves nothing (SHA-1,
  `l=`, a testing key, a key under 1024 bits) is never counted as proof.
  `tests/test_mailauth.nim` holds RFC 8463's example and messages another
  program signed: a change to canonicalization keeps them verifying. The
  names kept for examples (.test, .example, example.com...) are never asked
  of DNS. The Public Suffix List and the confusables are vendored data
  (`THIRD-PARTY-NOTICES.md`): fetched again from publicsuffix.org and
  Unicode's own files, packed with `tools/packlzma.py`. Google Fonts'
  families (`src/retroui/googlefontlist.txt`, `googleFontCatalog`) are made
  by `tools/gengooglefonts.py` from the google-font-metadata package's
  api-response.json (npm pack, in a folder of its own); never by hand.
- An encrypted database (`openDb(path, key = ...)`, `src/retroui/cryptvfs.c`):
  4096-byte pages with 40 kept free for each page's nonce and tag, made so
  when the file is new (`SQLITE_FCNTL_RESERVE_BYTES`); the VFS refuses to
  write a page whose last 40 bytes are not zero or a first page that does
  not say so, rather than lose data. SQLite's temporary data stays in
  memory; a rollback journal and temporary files are encrypted too.
  `tests/test_dbcrypt.nim` kills a writer part way: run it after any change
  there. Retro Mail's store is encrypted by default (its key in
  `retroui/secrets`); `secureStore` runs before anything opens it. The
  key is asked of the keyring on a thread of its own (`keyMain`) while the
  window shows -- a keychain that waits for its password, or one that never
  answers (a home of a test's own on macOS), never holds the first frame;
  `storeKey` asks it once and keeps it. `retroui/secrets`' tools stop
  after two minutes and are not asked again then (the files instead).
  Sending over SMTP never writes the Bcc header (`withoutBcc`).
- Several layers picked (Retro Atelier, `examples/photo/picking.nim`):
  shown as the document's own program shows them (`pickLook`: a photo,
  a drawing -- SVG, AI, EPS --, a page of a book); what a transform of
  them changes is `transformLayersOf` (each picked, a group's layers,
  those linked), carried by `retroui/photowarp`'s `LayerShot` (`shotsOf`,
  `carryShots`, `liveShots`, `putDownShots`): pixels shown live and warped
  once at the end (each only where it has something), shapes and type made
  again as the corners move (turned type set through its corners,
  `TextData.persp`), all in one step. A setting of the Layers panel goes
  to every picked layer (`pickedLayersOf`); a layer's color is
  `Layer.label` (`LayerColors`; PSD's 'lclr').
- Header files of the kit's C (`simdkern.h`, `simdkit.h`, `simdtext.h`)
  are named by cutting the module's own path (`currentSourcePath()` up to
  its last slash), never with `os./` or `parentDir`: those turn "/" into
  "\" when Windows is the target, and the release builds Windows programs
  on Linux.
- Tashkeel is what a combining mark made (`ShapedGlyph.fromMark`), never
  every mark glyph of the font: a font may build its letters from a
  dotless shape and dot glyphs (Reem Kufi), marks in GDEF too, and those
  dots are the letter's -- the tashkeel's color, raise and hiding leave
  them alone. A new font's shaping is checked against HarfBuzz
  (`otshape-cases.txt.z`, made with uharfbuzz) before its fix is trusted.
- A loop of the kit that calls the app's own code (a panel's body, a
  window's, a callback) walks a copy of its list and skips what has left
  it: that code may open, close or move what the list holds, and Nim's
  `items` stops the program when a list changes under it (`retroui/dock`'s
  `dockPanels`).
- `UndoStack.record` keeps two whole copies of its value a step, up to 200
  steps: an app records that way only what is small; a list or a table
  that grows with the user's data (Retro Podcast's shows, its played
  episodes) goes through `did` with closures holding what changed.
- A closed image in Retro Atelier lets go of all it was (`forgetDoc`,
  called by `closeDoc`): a variable of the app that holds a `Doc`, a
  `DocWin` or one of its layers -- a dialog's, a cache's, a drag's -- is
  dropped there too, or every image closed stays in memory. Under random
  input the memory log (`RETRO_MEMLOG`) says how many are still alive
  (`docsAlive`; one is the Scratch panel's pad, always there).
- A file that is a device or a pipe is never read (`specialFile`,
  `FileItem.special`): a read of one may never end. A read made while
  drawing (`retroui/textfile`: a text or hex shown a piece at a time)
  stops at an `IOError` and keeps why (`error`): some files give one
  partway -- Linux's own under /sys, a disk failing, a share gone. A size
  or a place a file gives is checked against what is left by taking away
  (`at > size - n`), never by adding (`at + n > size`): a damaged 64-bit
  number near the largest overflows the sum, a Defect and not the reader's
  own error (`retroui/zip`'s zip64, found by `fuzz_store`). What an app
  does that reaches outside itself -- ending a process, following feeds
  without end -- is not done under random input (`smokeOn()`): the soak
  runs for an hour on GitHub with a real network and real processes.
- `docs/controls.md` -- every control with pictures, made by `tools/shots.nim`.
  Pictures that change only with the day (the calendar, the agenda, the
  Gantt chart, the About and splash boxes, the file pickers) are not
  committed again unless their control changed.
- Screen readers: `src/retroui/uirelays/access.nim` (the tree, its roles,
  states, requests: generic), `core.nim` builds it while one listens
  (`accessNode`, `accessBegin`/`accessEnd`, `accessPress`, `accessSet`);
  the drivers hand it on: `uirelays/atspi.nim` over `uirelays/dbus.nim`
  (X11), `drivers/winuia.nim` (Windows, included by the WinAPI driver),
  `cocoa_backend.m`, `uikit_backend.m`, `tools/android/RetroAccess.java`.
  A new control adds itself (`accessNode` after its `interact`; parts --
  items, tabs -- with `accessSubId`) and takes a press from `accessPress`.
- Input methods: `TextEditingEvent` (`composing`), `ui.composing`, drawn by
  `editAt`; X11 XIM callbacks, Windows IMM, macOS marked text, GTK 4
  preedit, Android `tools/android/RetroInput.java`.
- The Java of the APKs (`tools/android/*.java`) is compiled into
  `src/retroui/androiddex.nim` by `sh tools/android/build_dex.sh` (javac,
  an android.jar of API 23, dx or dalvik-exchange): run it after changing
  one, and use only calls API 23 has (the APKs start on Android 7). An
  app's own Java goes in with `retroapk --java:DIR`
  (`examples/retrodns/glue`): its `classes.dex` is committed too, made
  again by `sh examples/retrodns/build.sh dex` after its Java changes
  (javac against glue/stubs, then d8 or dx: no android.jar).
- The web view (`webView`, in `htmlview.nim`): the system's engines are
  `webnative.nim` and the file it includes for each system --
  `webnative_gtk.nim` (WebKitGTK, in a GTK thread of its own, its window
  put inside the X11 driver's), `webnative_win.nim` (WebView2 through COM),
  `webnative_wk.nim` (WKWebView through the Objective-C runtime) -- all
  loaded at run time, never linked. An APK's is `tools/android/RetroWeb.java`
  through `systemCall("web.show")`, `"web.info"`..., the protocol
  `tests/test_htmlview.nim` fakes. A new command goes into every one of
  them (the same `webNative*` proc, a `web.` call in the Java) and into the
  fake. The page's side is `retro.post(text)` and a `retro` event on
  `window`, the same everywhere.
- The drivers without a library under them: `drivers/wayland_driver.nim`
  (Wayland's protocol in `wlwire.nim`, shared memory in `pixbuf.nim`,
  fonts through `ftfonts.nim`, keys through `xkbload.nim`; cursors and key
  names shared with X11 in `cursorart.nim`, `keysyms.nim`),
  `drivers/fb_driver.nim` (DRM/KMS, the framebuffer, evdev: the ioctl
  structures are Nim objects whose sizes the kernel checks -- keep them
  exact), `drivers/web_driver.nim` (WebAssembly). `backend.nim` picks the
  Linux driver (`useScreen`, `RETRO_DRIVER`).
- **The web build:** `src/retroweb.nim` carries `src/retroui/web/libc` (the
  C library: only what Nim's C and the kit call; a missing function shows
  as wasm-ld's "undefined symbol", or at run time as an import the page
  lacks) and `web/retro.js` (the page: files, input, sound, video, fetch,
  the iframe web view, the system's calls in `call(name, arg)`, the
  threads' workers); `tests/web/run.sh` checks both in Chromium, with and
  without threads, and `tests/web/node.sh` runs headless tests as
  WebAssembly under Node. A web build is 32-bit: `when defined(wasm)` for
  what differs, and `tests/run32.sh` before a release (`int` overflows show
  there). Threads (`--threads`): `web/libc/threads.c` (futexes; the page's
  thread spins and serves the workers' calls, `rl_thread_serve`), the heap
  behind a lock (`alloc.c`), `RetroThreads` and `threadWorker` in retro.js
  (each worker a mailbox of shared memory; an import a worker does not do
  itself the page does for it). Code that differs with threads:
  `compileOption("threads")` -- a build without them must still compile.
  A new import that a worker can do itself (no DOM) goes into its `local`
  list. An exported Nim proc called from the page catches every exception
  (Nim's goto exceptions would leave the error set and stop the next
  frame). The system's features (`retroui/system`, `docs/system.md`): a
  new one is a `call` name in retro.js, a branch in each system's part of
  the proc, a line in docs/system.md's table, and a check in
  `tests/web/webcheck.nim` and `tests/test_system.nim`.
- **Maps:** `tilemap.nim` (the widget, sources, cache, workers), `geo.nim`
  (services: each provider's request and answer in one `case`, the tests'
  answers in `tests/test_tilemap.nim`), `mvt.nim`, `pmtiles.nim`. A new
  service adds its request, its reader and a saved answer to the test.
- **3D:** `view3d.nim` (scene, nodes, clips, skinning, the CPU's lit
  triangles), `view3dgl.nim` (the GPU's: included where OpenGL is),
  `gltf.nim` (read and write; every index and size checked through `item`,
  `view`, `fits`: keep them). `tests/carscene.nim` is the test car.
- **Store packages:** `sign.nim` (DER, CMS, JAR, Authenticode, time
  stamps), `msix.nim`, `macapp.nim` (bundles, `.icns`, the ad hoc
  signature, `.ipa`); `retroapk.nim`'s `protoXml` and `protoResources`
  for App Bundles. Check a change with `sh tests/store/linux.sh`
  (osslsigncode, jarsigner, bundletool, rcodesign); Windows and macOS
  check theirs on GitHub (`tests/store/windows.ps1`, `mac.sh`).
  `linuxpkg.nim` writes the .deb, .rpm, PKGBUILD and install.sh with no
  tool installed (`retrokit linux`): check a change with `dpkg-deb -I -c`
  and `rpm -qip`, `rpm -K` (both digests OK) and `rpm --root DIR -ivh`.
  `install.nim` is the app installing itself for the user (no package).
- **The web view's two ways:** `webbind.nim` makes a Nim proc a function
  the app's pages call (`retro.call`; the macro reads its parameters, the
  TypeScript is made at run time by `tsOf`); `htmlview.nim` carries the
  calls (`takeCall`: the view's token, its page trusted -- the app's own
  or `webTrust` -- then the handler). A page's script must never be able
  to pretend what the engine says: full screen, the block list's count
  come from the engines (`WebNativeState`), not from page messages.
- `tools/compare/` -- Hello in egui, iced and Slint, and `compare.sh`
  measuring them and the kit the same way (memory, size, CPU).
- `tools/bench.nim`, `tools/bench.py` -- the kit's own benchmark (start,
  memory and processor at rest, a list, a dashboard, a document busy):
  `python3 tools/bench.py` writes `docs/benchmarks.md`; run it again when a
  change could cost speed or memory. `sh tools/appbench.sh` measures the
  apps themselves (size, first frame, memory at rest and at most, the
  processor at rest) for the page's last table; its smoke run clicks at
  random, so run it as a user of its own (`APPBENCH_PREBUILT=1` measures
  programs built by another).
- `docs/syntax.md` -- the study of the syntax: every form as a whole program
  with a picture of what it draws. The programs are `tools/syntaxshots/ex/`
  (the page's code plus `#>` script lines and `mark` lines it leaves out);
  `sh tools/syntaxshots/make.sh` remakes `docs/syntax/*.png` and checks the
  page's code is the programs' (needs Pillow). `docs/syntax/frame-loop.png`
  is drawn by hand.
- `tutorials/` -- the lessons, easy to advanced. Each step is a whole
  program (`tutorials/LESSON/stepN.nim`, with `#>` script lines the lesson
  leaves out; `#> build-only` for those built, not pictured), shown in the
  lesson's README.md as it is. `nimble tutorials` (`sh
  tools/tutorialshots/make.sh`) remakes the pictures and builds every
  step for every system; CI checks the lessons show their steps' code.

## Before you change anything

1. Read `README.md`, the top of `CHANGELOG.md` and the module you touch
   (every exported symbol has a `##` doc comment).
2. Build what you touch and run its tests:
   `nim c -r --hints:off tests/test_<name>.nim`; the whole suite is
   `nimble test` (all must pass before a commit; `sh tests/runall.sh`,
   as many at once as there are cores, a log each in `build/tests`; a
   test named "flaky" failed with the others running: find why -- a
   fixed port, a shared file, a timing -- rather than leave it). A
   change to the
   Android driver (`uirelays/drivers/android*`): `sh
   tests/android_mock/run.sh` too (the driver on a fake Android; a new
   NDK function needs its fake in `tests/android_mock/mock_android.c`).
3. A change to a driver, the drawing or the web view: the live check too
   (`tests/live/livecheck.nim` on a real window; it ends with 0 when every
   check passed). A change to how one of its pages draws: `sh
   tools/live/makeref.sh`, then look at `tests/live/ref` before it is kept.
   GitHub runs it on every system (`.github/workflows/systems.yml`) on a
   push to `main` (the only branch: no `next` to try it first).
4. Before a release, run the tests under the sanitizers too (the command
   is at the top of `tests/lsan.supp`); a leak found goes into
   `test_hardening`. Also `python3 tools/returncheck.py` and
   `python3 tools/writecheck.py` (both on GitHub too), `nimble fuzz`,
   `sh tests/run32.sh` (and `RETRO32_UBSAN=1`), and the checks of what
   changed: `tests/web/run.sh`, `tests/web/node.sh`, `tests/wayland/run.sh`,
   `tests/kiosk/run.sh`, `tests/store/linux.sh`. GitHub runs the long ones
   every night (`.github/workflows/nightly.yml`: sanitizers, long fuzzing,
   libFuzzer on `tests/fuzz/libfuzz.nim`, 32-bit, WebAssembly, the tests
   three times over, ten apps soaked); a crash's input is in the run's
   artifacts. An app changed: `sh tools/soak.sh 10 APP` (ten minutes of
   random input, its memory watched; as a user of its own: the clicks
   delete what they reach) -- a fault it finds has its stack in a build
   with `--stackTrace:on --lineTrace:on` and the same `RETRO_SMOKE_SEED`. Built with `-d:retroSanitized` there, a
   test's limit of time or memory allows for the sanitizers (some 7 times
   slower, freed memory kept a while). A workflow installs Ubuntu packages
   with `sh tools/apt.sh PKGS` (never `apt-get` itself): it tries again
   when a mirror does not answer.
5. Before every release, **`sh tools/uirelays.sh merge`**: what
   nim-lang/uirelays has new merged into the `uirelays` branch, then
   `pull`, and what it changes in retroui fixed and tested (the upstream
   commit merged goes into `src/retroui/uirelays/VERSION`); it says when
   the branch has upstream's last commit already. Also look at upstream's
   open pull requests (`git ls-remote https://github.com/nim-lang/uirelays
   'refs/pull/*'`) for a fix retroui needs before upstream takes it.
   Then **`sh tools/cicheck.sh`**: what GitHub's CI runs
   (the return check, the warnings, the tests, a short fuzz, the fake
   Android, WebAssembly under Node, the tools, the programs in subfolders
   found from their config) -- all must pass; a release never goes out
   with a CI step not run here. **From a clean clone:** the commit cloned
   into an empty folder, and the tests that read files of their own
   (`tests/data`) run there, the new ones as 32-bit programs too
   (`sh tests/run32.sh test_...`) -- a file `.gitignore` names is on this
   machine and not in the commit (0.50.0's test APK was not, and failed
   GitHub's tests on every system). **No warnings:** `sh tools/warncheck.sh`
   checks the kit's own files as every system builds them (Linux, Termux,
   an Android app, Windows, macOS, iOS, the web with threads and
   without), the examples and the tests. A module imported for what it
   sets up when imported (photodevelop, photoshapes, photostyles,
   photodeep, photohdr, rawformats, parallel: they fill retroui/photo's
   and codec's hooks) is never taken out for an "unused" warning: it is
   imported between `{.push warning[UnusedImport]: off.}` and `{.pop.}`,
   with a word on what it sets up (`tests/test_photoapp.nim` checks Retro
   Photo's); an import used on some systems only is imported under the
   same `when` as its use, an early `return` for one system gets an `else`
   for the rest. A program in a subfolder of `tests/` or `tools/` finds the
   kit through that folder's `config.nims` (`thisDir()`, not
   `$projectDir`).
6. A change to an Android app or to `tools/android/*.java`: `nimble
   emuapks` and `sh tests/android/apps.sh` on an emulator when one is
   there (the systems workflow does it on Android 11 and 15); Java changes
   need `sh tools/android/build_dex.sh` (javac, `dx`, an android.jar) and
   the regenerated `src/retroui/androiddex.nim` committed. A native crash
   there is named: the emulator's APKs are `--debuggable`, and a stripped
   APK's names are in `APP-symbols/` beside it (`retrokit symbolize`).
7. A change to an app, to how frames run (waking, carets, drawing) or to a
   driver: **`sh tests/smoke/run.sh`** (`xvfb-run -a` before it on Linux
   without a screen) -- each app started for real (`RETRO_SMOKE`), its
   first frame timed, 3 seconds untouched measured, then driven by
   clicks and keys. An app at rest runs next to no frames: one that is
   busy while untouched (a widget that asks for a frame each frame, a
   setter that draws again when nothing changed) fails it, as a fault, a
   crash or a hang does. The systems workflow runs it on Linux, Windows
   and macOS. Then **`sh tests/drive/run.sh`**: the apps driven by their
   controls' names (`RETRO_DRIVE`), every tab and every menu, every page
   by Tab alone, no `&` letter used twice where one Alt reaches both --
   the window, a dialog (`TOUR_STRICT=1`: a finding fails it, as on the CI's Linux job);
   `build/drive/tour --touch APPS` as a finger finds them (too small, only
   under a mouse, a long press's menu).
8. To see what an app does, use it as a person would, by its controls'
   names: start it with `RETRO_DRIVE=7000` and `retrokit drive 7000 tree`
   / `click NAME` / `type TEXT` / `key ctrl+s` / `wait NAME` (each answered
   once the app has done it); in a headless test, `accessKeep = true` and
   `findNode(accessLast, "OK", {arButton})` with `nodeRect`. `RETRO_INSPECT=1`
   (or F12 in a debug build) says why each frame ran and which line asked
   for it -- the place to look when an app is not at rest. For a picture of
   an app in a given state (release pictures, a README), no port:
   `RETRO_SCRIPT="click:Add;type:Milk" RETRO_SNAPSHOT=out.png ./app`
   (`RETRO_SIZE` its size); `RETRO_PLAY` for a film of a feature.

## Rules

- **Nim 2.4 is the kit's compiler; Nim 2.2 its fallback.** Build, test
  and release with Nim 2.4 (CI's main jobs, the APKs, the web pages, the
  releases' files); CI runs the whole suite with Nim 2.2.6 too, so code
  stays within what 2.2 compiles: no 2.4-only syntax in the kit (sum
  types, `{.cyclic.}` imports, `owned` refs), and the checks for 2.2's
  leaks (`tools/returncheck.py`, `tools/writecheck.py`) still pass.
- **Movement through `animated` or `retroui/motion`** (`sprung`,
  `presence`, `glided`, `dragSnap`, `staggered`, `fixedSteps`): they ask for
  frames only while something moves and are at their end at once when
  less movement is asked (`reducedMotion`). Not a `wakeIn` of an app's own
  every frame for a decoration -- an app at rest takes no time.
  `test_motion` runs them on a clock of its own (`inputRelays.getTicks`).
- **A question and what follows it is a flow** (`retroui/flows`): ask,
  wait for a save or a worker, go on -- written one after another in
  `flow(name): ...`, not as flags kept across frames. Its templates take
  their own names (`ownedFlow`, not an overload of `flow`: the compiler
  tries a body against a string parameter first and fails on `yield`), and
  build their steps through procs (a template's parameter named like an
  object's field replaces the field's name too).
- **AI goes through the user's own service, off until it is set**
  (`retroui/aiconnect`, `retroui/aichat`, `retroui/aiimage`): nothing is
  sent before; keys in `retroui/secrets`, never in a settings file. A tool
  that changes something `confirm`s (the assistant asks; Allow All for the
  conversation); a tool's change is one step to undo. Tools run on the UI
  thread (`aiTool`; `aiToolLater` when the work ends in a later frame);
  the request and an image service's work go on a worker (a job's closure
  copies what it needs). An app's assistant is `assistantPanel`, its
  window's controls `uiTools`; `publishTools` for agents outside
  (`retrokit mcp`). The tests speak to `tests/aimock.py`, never to a real
  service.
- **The device's own model is one more service, never bundled**
  (`retroui/llm`, `retroui/modelstore`, `retroui/devicemodel`,
  `retroui/meaning`): an app offers models through `modelStoreDialog` --
  downloaded when the user asks, into the models folder outside the app,
  their checksum checked; a model is never put into an APK or the
  repository. A model the store offers has a license that lets any app use
  it (MIT, Apache 2.0) and its SHA-256 from its maker's page. What a small
  model reads first it reads slowly: give it fewer tools (no enums of
  hundreds of commands), what changes last (`aichat` puts the context in
  the newest message for it), and less text. The tests use the small
  models of `tests/data/llm` (made by `tools/genllm.py`, against numpy's
  own reference: change a kernel, run it); a change to `simdllm.h` builds
  with `-f` (Nim does not see a header change).
- **Models of pictures run in jobs, on `retroui/nnet`'s own threads**
  (`retroui/nnet`, `retroui/vision`): the kit's `parallelFor` belongs to
  the drawing thread, so the runner has its own pool, one model at a time
  (`run` holds it); an app runs `depthOf`, `subjectOf`, `readText` in a
  `job` (or on the UI thread with `stop` ticking the busy box, as Retro
  Atelier's hooks do). A node's inputs are its own (moved at their last
  use, else copied): an operation may change or move them, never a
  weight. A new operation gets a graph in `tools/gennet.py` checked
  against onnxruntime; a real model, `tools/netcheck.py` then
  `tools/netcheck.nim`. The store's models of pictures are as its
  language models: downloaded when asked, checked, never bundled.
- **A graph's layout without a window is `retroui/forcelayout`**; the
  control (`graphView`) is `retroui/forcegraph`, which imports the UI. A
  module that draws nothing on screen (`retroui/board`) imports the
  layout alone.
- **Nim 2.4 refuses a loop variable kept by a nested proc**
  (`for (kind, title) in [...]: grid(..., proc () = use(kind))`: "'kind'
  is of type <lent string> which cannot be captured"). Give the loop a
  copy as its first line (`let kind = kind`). Only a real build says so,
  not `nim check`, so the warning check misses it:
  `python3 tools/lentfix.py FILE.nim` with Nim 2.4 finds and fixes them.
- **Nim 2.2 leaks** in three shapes, worked around in the kit: `return x`
  after `result` was already set, `return nil` too (write `result = x;
  return`, or keep the value in a local until it is whole;
  `python3 tools/returncheck.py` finds every one and must say 0); `x = y`
  after `x` was filled in a loop or a branch -- a `var x: T` declared
  without a value, and `result` too (give `x` a value where it is
  declared, `result` one at the proc's start; `python3
  tools/writecheck.py` finds every one and must say 0); a call that may raise
  whose result goes into a field (into a `let` first, then the field). And
  where a reader fills `result` and then raises (a damaged file), a caller
  that reads into a variable it already has keeps the half: read into a
  variable of the reader's own, then `result = move` it (`readGltf`); a
  string `result` set before a `raise` is never freed; Nim's base64
  `decode` raising on a wrong letter leaks, so the kit uses
  `codec.unbase64`.
- **JSON from outside, a table's lists:** walk a JSON list or object with
  `getElems` / `getFields` (`items` and `pairs` on a node that is missing
  or of another kind stop the program); walk a table's seq in place
  (`for x in t[k]`) only when nothing in the loop adds to the table or
  takes from it -- it moves its entries, and the loop reads where the seq
  no longer is (Retro Files' folder tree stopped so: walk a copy).
- **Nim's `unicode.strip`** cuts the last letter of a line ending in a
  letter whose last byte is 0x85 or 0xA0 (Thai ภ, †, a Chinese character in
  32: `docs/nim-bugs.md`), and it is the `strip` a module that imports
  `std/unicode` whole calls. A module that strips imports `std/unicode
  except strip` (strutils' `strip` then); `tests/test_hardening.nim`
  (`noRuneStrip`) keeps it so.
- **The focus ring** is the kit's, drawn once at the frame's end round the
  rectangle `interact` (or `tabStop`, `focusAt`) was given, while
  `ui.focusCues` is on (Tab, F6, the arrows; a click turns it off). A new
  control draws none itself. One whose `interact` takes a part of it only
  (a list beside its scroll bar) calls `if hit.focused: focusFrame(r)`
  with its whole rectangle; a text box of a new kind sets `ui.editsText`
  when focused, so its arrows bring no ring.
- **A control's ids:** a widget calls `idOf` once and uses that id for
  `interact`, its keys and its reader's node (a second `idOf` of the same
  label is another id: the node would not be the widget's --
  `oneIdPerWidget`). A widget with more than one stop of Tab (a range's
  two ends) registers each (`interact` with an empty rectangle, or
  `tabStop`). Reader nodes take the focus when Tab stops at them: the kit
  marks them at the frame's end from the stops; a control acting on Enter
  sets `ui.takesEnter` (`enterIsClaimed`). Tool buttons are a run, one
  stop (`toolRun` in widgets: the first button's stop, `first = false` so
  a window does not start there); a container of the kit that is a part
  of the window (a pane, a docked panel, an MDI window, a tool bar) is an
  `area` for F6 (`beginArea`/`endArea` round its content).
- **The first frame:** what it can do without waits for `framesShown() >
  0`; data the kit carries packed is unpacked on a thread (`unpacking`:
  `unpackSoon`, then `unpacked` where it is needed); tables made once go
  in a `const` (built with the program) or are made when first needed --
  not at a module's start.

- **Voice:** comments, docs and messages in the repository speak as the
  developer, Sultan Al Isaiee, to his users and developers: plain, short
  sentences. Never as an assistant or a test machine ("tested here", "on
  this machine", "I could not").
- **Doc comments:** every exported proc, template, macro, type, field and
  constant has one (what it does, parameters and defaults, what it
  returns). `nimble docs` must build without warnings. A new control goes
  into `docs/controls.md` (`tools/controlscheck.py` fails otherwise) with
  its example in `tools/shots.nim`.
- **Keep these up to date with every change** to the API, the build or
  the behaviour: `skills/retroui/SKILL.md` (how to build apps with the
  kit), this file, `README.md`, `CHANGELOG.md` (the top section),
  `BUILDING.md` (builds), `docs/controls.md` (controls), `docs/syntax.md`
  (when the syntax or what a form draws changes: run
  `sh tools/syntaxshots/make.sh`), `tutorials/` (when what a lesson uses
  changes: `nimble tutorials`), `docs/designer.md` (Retro Designer),
  `docs/customizing.md` (a new option that changes a control's look, a
  new building block for controls), `llms.txt`, `examples/README.md` (a new example, or one whose look or
  purpose changed: its section and its picture -- `sh
  tools/exampleshots.sh NAME` for those the README has no picture of). A
  new or changed control: `python3 tools/gendesigner.py`
  too, and `tests/test_designer.nim` must still pass (every control of the
  Widget Box dropped into one app has to compile).
- **The built-in fonts** are GNU FreeFont 0412 cut by
  `tools/genfreefont.py`; letters added since (Vietnamese, Thai) come with
  `--add` from any FreeFont release, the rest of each face kept as it is:
  a newer release cut whole is bigger for the same letters.
- **Looks:** the Windows 3.1 look and FreeSans drawn in gray (its heights
  on whole pixels, its strokes as the font has them; "Sharp" text is an
  option); the title bars the kit draws have Windows 95's minimize,
  maximize and close buttons (`captionButtons`, 3.1's two a setting away):
  a new title bar draws its buttons with `captionButton` and `captionMark`.
  Check a change by looking at a screenshot.
- **The same everywhere:** behaviour and looks must match on Windows,
  macOS, Linux/BSD and Android; platform conventions (Cmd on macOS) go in
  the drivers, not in the app code. A frame relay added to `FrameRelays`
  (as `setResizable`) is filled in every desktop driver that can, and the
  ones that cannot are named in its doc comment.
- **Android: an app or a program in Termux.** Nim builds both with
  `--os:android`. `androidApp` (`uirelays/target`) is an APK (the
  activity, JNI, the app's folders); `androidShell` is a program run in
  Termux (X11 on Termux:X11, files and services as on Linux). Use
  `androidApp` for anything of the activity's; `defined(android)` only
  for what Android's libc and system are either way (bionic's malloc,
  /system/fonts, /storage). An APK, an iOS app and a web page have no
  command line: Nim's `paramCount`, `paramStr` and `commandLineParams`
  raise there, so apps and modules ask `appArguments()` (none there);
  `tests/test_hardening.nim` fails on any other use (Retro Files closed
  at its start as an APK because of one).
- **A driver's C and Objective-C build on their own**: the uirelays tests
  compile `cocoa_backend.m` (and others) as plain C, without Nim. What such
  a file calls in Nim gets a weak stand-in there
  (`__attribute__((weak)) void cocoa_accessListen(void) {}`); the Nim
  side's `exportc` proc takes its place when the program is linked.
- **uirelays** (`src/retroui/uirelays`): generic, in upstream's style, no
  Retro names or app logic (the X11 driver's `x11EventHook`, `x11Display`,
  `x11Window`, `x11Wake` are generic too: what any program that manages
  windows needs; Retro Desktop is one). It is the same code as the `uirelays` branch:
  after changing it, `sh tools/uirelays.sh push "message"`; `sh
  tools/uirelays.sh merge` brings upstream's new commits (nim-lang/uirelays
  master) into the branch, then `pull`. It stays inside the package (no
  separate nimble dependency) until upstream has the branch's work.
- **A frame that changes nothing takes no memory**: no string, seq or
  closure made in the drawing of a control (buffers kept from frame to
  frame, `idOfLabel` instead of `idOf(a & b)`, templates instead of nested
  procs, `swap` a widget's state out and back). `tests/bench.nim` with
  `-d:nimAllocStats` counts them (0 in the gallery's frames).
- **No dependencies to install:** link only what every system has
  (libc; Windows' system DLLs); load anything else at run time and work
  without it.
- **Credits:** the About boxes credit only Sultan Al Isaiee
  (`RetroCredit`). Commits are authored by him; an AI that helped is
  named in a `Co-Authored-By:` line, and that is all: no link to the
  session it worked in, in a commit or anywhere in the repository.
- **Never commit** private fonts (Helvetica World), secrets (Retro Mail's
  Google/Microsoft ids: from the environment at build time), signing keys
  and update keys (`*.secret`; the tests make their own in a temporary
  folder), build outputs, or real
  personal data in examples and tests (sample data is made up: names, and
  numbers like +968 0000 0123).
- **Third parties:** a part of someone else's (a font, data, code) goes
  into `THIRD-PARTY-NOTICES.md` with its license text beside it; nothing
  GPL is linked into apps (FreeFont's font exception covers the fonts).
- **Commits and pushes:** only the developer pushes.
