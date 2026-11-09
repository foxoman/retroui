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
- `examples/` -- the example apps (Gallery, Retro Photo, Retro Files,
  Retro Mail, Retro Communicator, Retro Board, Retro Task Manager, HR
  Book, Notepad, Ledger, Charts...). They are
  built only when asked, one at a time (`nimble photo`, `nimble photoexe`,
  `RETRO_APP=photo nimble exe`...), never by `nimble install`. GitHub's
  Release workflow (`.github/workflows/release.yml`, on a `v...` tag or by
  hand) builds Gallery, Files, Photo, Board and Mail for Linux, Windows,
  Android and macOS onto the release.
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
  one, and use only calls API 23 has (the APKs start on Android 7).
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
- `tools/compare/` -- Hello in egui, iced and Slint, and `compare.sh`
  measuring them and the kit the same way (memory, size, CPU).
- `docs/syntax.md` -- the study of the syntax: every form as a whole program
  with a picture of what it draws. The programs are `tools/syntaxshots/ex/`
  (the page's code plus `#>` script lines and `mark` lines it leaves out);
  `sh tools/syntaxshots/make.sh` remakes `docs/syntax/*.png` and checks the
  page's code is the programs' (needs Pillow). `docs/syntax/frame-loop.png`
  is drawn by hand.

## Before you change anything

1. Read `README.md`, the top of `CHANGELOG.md` and the module you touch
   (every exported symbol has a `##` doc comment).
2. Build what you touch and run its tests:
   `nim c -r --hints:off tests/test_<name>.nim`; the whole suite is
   `nimble test` (all must pass before a commit). A change to the
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
   `test_hardening`. Also `python3 tools/returncheck.py`, `nimble fuzz`,
   `sh tests/run32.sh` (and `RETRO32_UBSAN=1`), and the checks of what
   changed: `tests/web/run.sh`, `tests/web/node.sh`, `tests/wayland/run.sh`,
   `tests/kiosk/run.sh`, `tests/store/linux.sh`. GitHub runs the long ones
   every night (`.github/workflows/nightly.yml`: sanitizers, long fuzzing,
   libFuzzer on `tests/fuzz/libfuzz.nim`, 32-bit, WebAssembly); a crash's
   input is in the run's artifacts.
5. Before every release, **`sh tools/cicheck.sh`**: what GitHub's CI runs
   (the return check, the warnings, the tests, a short fuzz, the fake
   Android, WebAssembly under Node, the tools, the programs in subfolders
   found from their config) -- all must pass; a release never goes out
   with a CI step not run here. **No warnings:** `sh tools/warncheck.sh`
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
   and macOS.

## Rules

- **Nim 2.2 leaks** in three shapes, worked around in the kit: `return x`
  after `result` was already set, `return nil` too (write `result = x;
  return`, or keep the value in a local until it is whole;
  `python3 tools/returncheck.py` finds every one and must say 0); `x = y`
  after `x` was filled in a loop or a branch
  (`swap`, or give `x` a value where it is declared); a call that may raise
  whose result goes into a field (into a `let` first, then the field). And
  where a reader fills `result` and then raises (a damaged file), a caller
  that reads into a variable it already has keeps the half: read into a
  variable of the reader's own, then `result = move` it (`readGltf`); a
  string `result` set before a `raise` is never freed; Nim's base64
  `decode` raising on a wrong letter leaks, so the kit uses
  `codec.unbase64`.

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
  `sh tools/syntaxshots/make.sh`), `docs/designer.md` (Retro Designer),
  `llms.txt`. A new or changed control: `python3 tools/gendesigner.py`
  too, and `tests/test_designer.nim` must still pass (every control of the
  Widget Box dropped into one app has to compile).
- **Looks:** the Windows 3.1 look and FreeSans drawn in gray (its heights
  on whole pixels, its strokes as the font has them; "Sharp" text is an
  option). Check a change by looking at a screenshot.
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
  named in a `Co-Authored-By:` line.
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
