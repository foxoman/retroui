## Retro Nim UI (`retroui`) -- a small, fast, dependency-free Windows 3.1
## style UI toolkit for business and desktop apps, one code base for
## Windows (GDI), macOS (Cocoa), Linux and BSD (X11, Wayland, or a screen
## with no desktop), Android, iOS and the web (WebAssembly).
##
## Immediate mode: write the UI as plain code that runs once per frame;
## widgets are procs bound to your own variables. `import retroui` brings
## everything:
##
## ================  ==========================================================
## Module            What it has
## ================  ==========================================================
## `core`            the frame loop, input, layout (rows, columns, adaptive)
## `widgets`         buttons, check boxes, fields, lists, menus, tabs, dialogs
## `business`        grids (with cell kinds), trees, dates, numbers, forms
## `extras`          switches, chips, cards, banners, settings rows, phone parts
## `morecontrols`    range slider, menu and split buttons, tags, autocomplete, knob, accordion
## `records`         masked fields, record navigator, property and tree grids, wizards
## `desktop`         MDI windows, find and replace, hot keys, the About box
## `toolcustom`      Customize Toolbar: the user picks a tool bar's buttons
## `dock`            docked panels as Photoshop's: tabbed groups, icons, floating palettes
## `charts`          21 kinds of business chart, CSV tables, PNG export
## `planning`        kanban, Gantt, agenda, org chart, KPI tiles
## `report`, `pdf`   reports from Nim or HTML templates; PDF; printing; preview
## `templates`       Mustache-style text templates
## `mapview`         a world map with values, markers and routes
## `view3d`          a 3D view of meshes and models
## `canvas2d`        the HTML5 Canvas 2D API: paths, gradients, text, pictures
## `htmlview`        HTML (a safe subset) and the system's web view
## `markdown`        Markdown views
## `media`           sound, video, animated GIFs
## `native`          any API of the system: C libraries, Java, Objective-C, Win32
## `files`, `docfs`  folders, file jobs, the trash, other apps' documents
## `filewidgets`     file lists, previews, path and drive bars, the folder tree
## `imaging`, `zip`  PNG / JPEG / BMP pictures, zip archives
## `background`      work on worker threads
## `memwatch`        the device's memory; caches that let go when it runs short
## `thumbcache`      thumbnails of slow files kept on disk
## `platform`        settings, places, open / share, the clipboard, storage
## ================  ==========================================================
##
## Imported on their own (`import retroui/http`), as they bring a C library
## or a thread of their own:
##
## ================  ==========================================================
## `http`            web requests from any thread: WinHTTP, libcurl, Java
## `netconn`         connections to a server with the system's TLS (STARTTLS too)
## `imap`, `smtp`    a mail account's folders and messages; sending through its server
## `mailsetup`       where an address's mail is: its IMAP and SMTP servers
## `oauth`           signing in in the system browser (OAuth 2.0, PKCE)
## `secrets`         tokens kept safe: DPAPI, the keychain, libsecret
## `db`              SQLite (compiled in) with full-text search
## `mime`            mail messages: reading, writing, charsets, addresses
## `richedit`        a rich text editor that reads and writes HTML
## `spell`           spelling (the system's checker, Hunspell) and AutoCorrect
## `mailimport`      mail brought in: Outlook Express (.dbx, .mbx), mbox, .eml
## `notify`          the system's notifications (and the unread count on the icon)
## `bgcheck`         a check the system runs while the app is closed (Android)
## `vault`, `rsa`    encryption with a password, RSA keys
## `tilemap`, `geo`  street maps from any service, places and routes
## `mvt`, `pmtiles`  vector tiles; PMTiles and MBTiles archives
## `gltf`            models from Blender and other tools (glTF, .blend)
## `capture`         the camera and the microphone
## `mediasession`    the system's media controls (lock screen, taskbar)
## `sign`, `msix`    signatures (JAR, Authenticode, time stamps), MSIX packages
## `macapp`          macOS bundles signed ad hoc, .icns, iOS archives
## `buildjobs`       how hard a build pushes the computer: C compilers as the memory
##                   allows (at most four in Termux), a build stopped half way told
## `system`          the system's features in one API: share, the place, speech,
##                   the device, starting with the computer (docs/system.md)
## `update`          updates inside the app: a signed update file (Ed25519), the
##                   download checked, installed (retrokit update-key, update-sign)
## `xmpp`            chat (XMPP: contacts, rooms, files, history; a WebSocket in a page)
## ================  ==========================================================
##
## .. code-block:: nim
##   import retroui
##   var name = "World"
##   app "Hello", 320, 120:
##     row([60, -1]):
##       label "&Name:"
##       edit name
##     if button("&Greet", isDefault = true): echo "Hello, ", name

import retroui/[core, widgets, business, extras, markdown, icons, nerdicons,
                pixelicons, platform, files, docfs, imaging, zip, background,
                textfile, filewidgets, charts, memwatch, thumbcache]
export core, widgets, business, extras, markdown, icons, nerdicons, pixelicons,
       platform, files, docfs, imaging, zip, background, textfile, filewidgets, charts,
       memwatch, thumbcache
import retroui/[records, desktop, planning, view3d, mapview, htmlview, native, media,
                report, pdf, templates, canvas2d, morecontrols, dock, toolcustom, inspect,
                drive]
export records, desktop, planning, view3d, mapview, htmlview, native, media,
       report, pdf, templates, canvas2d, morecontrols, dock, toolcustom, inspect, drive

import std/macros

var appLook = ""   # (the settings `app`'s `look` keeps the look in)

proc keepLook*(name: string) =
  ## Stores the look the user chose (`storeAppearance`) in the settings
  ## `name`, its other keys kept.
  var s = loadSettings(name)
  storeAppearance(s)
  saveSettings(name, s)

proc openApp*(title: string; w, h: int; theme = ui.theme; frame = wfAsBuilt;
              userFrame = true; gpu = gpuMode(); zoom = 0; scale = 0;
              font = uiFont(); id = ""; icon = ""; look = ""; resizable = true) =
  ## `app`'s start: opens the window with `app`'s options, which are the
  ## same by name (see `app` for each and its default). For an app that runs
  ## its own frame loop instead of `app`'s block:
  ##
  ## ```nim
  ## openApp("Hello", 320, 120, look = "hello")
  ## while beginFrame():
  ##   captionBar()
  ##   label "Hello"
  ##   endFrame()
  ##   appFrameDone()
  ## closeApp()
  ## ```
  if id.len > 0: appIdent = id
  userFrameChoice = userFrame
  case frame
  of wfSystem: setClassicFrame(false)
  of wfClassic: setClassicFrame(true)
  of wfAsBuilt: discard
  if gpu != gpuMode(): setGpuMode(gpu)
  if font != uiFont(): setUiFont(font)
  if scale > 0: setUiScale(scale)
  if not resizable: setResizable(false)
  if icon.len > 0: windowIcon = windowIconFromPng(icon)
  startApp(title, w, h, theme, zoom)
  # (the system's settings for every app: less movement, larger text --
  # what the user chose in the app's own look, below, comes over them)
  let sp = systemPrefs()
  if sp.reduceMotion: setSmoothScrolling(false)
  if sp.textScale > 1.05: setTextScale(int(sp.textScale * 100 + 0.5))
  appLook = look
  if look.len > 0:
    restoreAppearance(loadSettings(look))
    discard lookChanged()        # (what was brought back is no change)

proc appFrameDone*() =
  ## Called after each of `app`'s frames: keeps the look (the `look`
  ## settings of `openApp`) when the user changed it in the frame.
  if appLook.len > 0 and lookChanged(): keepLook(appLook)

proc closeApp*() =
  ## `app`'s end: the look kept (`look`), the window closed.
  if appLook.len > 0: keepLook(appLook)
  stopApp()

macro app*(args: varargs[untyped]): untyped =
  ## Opens a window and runs the block once per frame until it is closed
  ## (a phone's app takes the whole screen):
  ##
  ## .. code-block:: nim
  ##   app "Hello", 320, 120:                 # title, width, height
  ##     label "Hello"
  ##   app "Hello", 320, 120, Dark:           # in a theme
  ##     label "Hello"
  ##   const ledgerIcon = staticRead("ledger.png")
  ##   app "Ledger", 900, 600, frame = wfClassic, look = "ledger",
  ##       icon = ledgerIcon:
  ##     label "Hello"
  ##
  ## The options, by name, all optional:
  ##
  ## - `theme`: the colors (`builtinThemes`, or your own `Theme`)
  ## - `frame`: the window's frame on desktops -- `wfAsBuilt` (what
  ##   `-d:retroFrame` built in: the system's unless it says classic),
  ##   `wfSystem`, `wfClassic` (Windows 3.1's, drawn by the app)
  ## - `userFrame`: the user may switch the frame -- the 3.1 frame's
  ##   control menu, Windows' system menu, `appearanceSettings` -- and the
  ##   choice is kept (true, the default); false keeps the app's
  ## - `gpu`: `gmAuto` (the GPU when it is a real one), `gmGpu`, `gmCpu`
  ## - `zoom`: whole-pixel magnification (0: the display's own scale)
  ## - `scale`: the size of everything in percent (0: as kept or 100)
  ## - `font`: the UI's font (`UiFont`)
  ## - `id`: the app's name for what the toolkit keeps for it (the frame the
  ##   user chose, the fault log): the title without its version when ""
  ## - `icon`: the window's picture, a PNG's bytes (a `const` of `staticRead`)
  ## - `look`: the settings to keep the look in (`appearanceSettings`'s
  ##   colors, sizes, font...): brought back at the start, kept as it changes
  ## - `resizable`: the user may size and maximize the window (true, the
  ##   default); false keeps the size the app gave it -- no sizing border,
  ##   no maximize button, no size grip on the 3.1 frame (`setResizable`)
  ##
  ## $RETRO_FRAME, $RETRO_GPU, $RETRO_SCALE, $RETRO_THEME, $RETRO_SIZE and
  ## $RETRO_ZOOM win over them, for tests and screenshots. $RETRO_WINDOW=1
  ## (`retrokit run --window`) opens the app as a window in its 3.1 frame,
  ## in the middle of a desktop the toolkit draws, where the screen has no
  ## window manager (Termux:X11).
  if args.len < 4 or args[^1].kind notin {nnkStmtList, nnkStmtListExpr}:
    error("app: a title, a width, a height, options by name, then the block " &
          "(app \"Hello\", 320, 120: ...)", args)
  let body = args[^1]
  var start = newCall(bindSym"openApp")
  for i in 0 ..< args.len - 1: start.add args[i]
  let beginF = bindSym"beginFrame"
  let caption = bindSym"captionBar"
  let stoppedNow = bindSym"stoppedScreen"
  let endF = bindSym"endFrame"
  let done = bindSym"appFrameDone"
  let close = bindSym"closeApp"
  when defined(wasm):
    # (a browser page runs the frames: the block is one of them)
    let frames = bindSym"webFrames"
    let running = bindSym"appRunning"
    result = quote do:
      `start`
      `frames`(proc () =
        if `beginF`():
          `caption`()
          if not `stoppedNow`():
            `body`
          `endF`()
          `done`()
        if not `running`(): `close`())
  else:
    result = quote do:
      `start`
      while `beginF`():
        `caption`()
        if not `stoppedNow`():
          `body`
        `endF`()
        `done`()
      `close`()
