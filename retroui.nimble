import std/strutils

# Package

version       = "0.34.0"
author        = "Sultan Al Isaiee (@foxoman) <sultan@foxoman.net>"
description   = "Retro Nim UI (retroui): a small, fast, dependency-free Windows 3.1 style UI toolkit for business and desktop apps on Windows, macOS, Linux, Android and iOS"
license       = "MIT"
srcDir        = "src"
skipDirs      = @["examples", "tests", "tools", "docs"]
installExt    = @["nim", "nims", "c", "m", "h", "md", "ttf", "z", "txt"]   # drivers' C and Objective-C, fonts
bin           = @["retroapk", "retroios", "retrokit"]   # Android, iOS, new apps / doctor

# Dependencies

requires "nim >= 2.0.0"

# Tasks

task gallery, "Build and run the control gallery":
  exec "nim c -r -d:release examples/gallery.nim"

task ledger, "Build and run the Ledger business example":
  exec "nim c -r -d:release examples/ledger.nim"

task files, "Build and run Retro Files, the file manager example":
  exec "nim c -r -d:release examples/filemanager.nim"

task notepad, "Build and run the Notepad example":
  exec "nim c -r -d:release examples/notepad.nim"

task charts, "Build and run Chart Viewer (a CSV file as charts)":
  exec "nim c -r -d:release examples/charts.nim"

task invoice, "Build and run the invoice example (HTML template, PDF, printing)":
  exec "nim c -r -d:release examples/invoice.nim"

task test, "Run the headless tests":
  for t in ["test_widgets", "test_business", "test_text", "test_bidi", "test_files", "test_apps",
            "test_explorer", "test_input", "test_docfs", "test_records", "test_desktop",
            "test_charts", "test_planning", "test_mapview", "test_view3d", "test_htmlview",
            "test_media", "test_native", "test_canvas2d", "test_pdf", "test_report",
            "test_scroll", "test_apk", "test_xlsx", "test_letters", "test_photo",
            "test_parallel", "test_textengine", "test_uifonts", "test_photomore", "test_photopro", "test_photoapp",
            "test_photomerge", "test_icc", "test_brushfiles", "test_raw", "test_brushes",
            "test_adobefiles", "test_deep", "test_gpu", "test_rsa", "test_morecontrols", "test_neural", "test_photopdf", "test_pdfread", "test_googlefonts", "test_filecolumns", "test_blendfast", "test_dock", "test_presets", "test_photocc", "test_photoartistic", "test_photohdr", "test_channelspanel", "test_photodeep", "test_photoanim", "test_photovp", "test_photosvg", "test_otshape", "test_icccmyk", "test_webp", "test_exrgif", "test_rawformats", "test_rscript", "test_psdround", "test_phototemplates", "test_gpucomposite", "test_penmap", "test_systemimage", "test_qrcode", "test_videoenc", "test_jxl", "test_assetstore", "test_svgimport", "test_morepictures", "test_memcache", "test_memsoak", "test_filespeed", "test_filesapp", "test_bigpicture", "test_edgetrace", "test_board", "test_boardapp", "test_http", "test_oauth", "test_secrets", "test_db", "test_mime", "test_htmlmail", "test_richedit", "test_mail", "test_toolcustom", "test_mailextra", "test_calendar", "test_spell", "test_mailimport", "test_frame", "test_filedrop", "test_notify", "test_bgcheck", "test_fileout", "test_widgetfixes", "test_x11close", "test_hardening", "test_gpuparts", "test_busykeys", "test_drawalloc", "test_hrbook", "test_x11input", "test_xmpp", "test_omemo", "test_retrokit", "test_access", "test_scale", "test_touchsizes", "test_mediasession", "test_capture", "test_windows", "test_shm", "test_atspi", "test_designer", "test_tilemap", "test_gltf", "test_store", "test_system", "test_update", "test_fontsoption", "test_keys", "test_stopped", "test_buildjobs", "test_imap", "test_sysmon", "test_taskman"]:
    exec "nim c -r --hints:off tests/" & t & ".nim"
  # (fewer faces built in: the others drawn with FreeSans)
  exec "nim c -r --hints:off -d:retroFonts=ui tests/test_fontsoption.nim"

task fuzz, "Feed damaged files to the decoders and random input to the widgets":
  exec "nim c -r -d:release --stackTrace:on --lineTrace:on tests/fuzz/fuzz.nim tests/fuzz/seeds 20000"
  exec "nim c -r -d:release --stackTrace:on --lineTrace:on tests/fuzz/fuzzui.nim 1000"
  for f in ["fuzz_charts", "fuzz_htmlview", "fuzz_view3d", "fuzz_media", "fuzz_canvas2d",
            "fuzz_report", "fuzz_photo", "fuzz_store", "fuzz_models", "fuzz_maps"]:
    exec "nim c -r -d:release --stackTrace:on --lineTrace:on tests/fuzz/" & f & ".nim"

task docs, "Make the API reference (docs/api) and the controls reference (docs/controls.md)":
  exec "nim doc --hints:off --project --index:on --outdir:docs/api src/retroui.nim"
  # the generated data modules (the map, Arabic's forms) would only list numbers
  for m in ["worlddata", "arabicdata"]:
    writeFile("docs/api/retroui/" & m & ".html",
              "<!DOCTYPE html><meta charset=\"utf-8\"><title>retroui/" & m & "</title>" &
              "<p>Generated data (the world map, Arabic's letter forms) used by the toolkit; see " &
              "<code>src/retroui/" & m & ".nim</code>.</p>")
  for f in listFiles("docs/api") & listFiles("docs/api/retroui") &
           listFiles("docs/api/retroui/uirelays") & listFiles("docs/api/retroui/uirelays/drivers"):
    if f.endsWith(".idx"): rmFile(f)
  exec "nim c -r -d:release --hints:off tools/shots.nim"

task bench, "Measure how long a frame takes (RETRO_GPU=gpu: with OpenGL, off screen)":
  # (-d:nimAllocStats: each line also says how much memory a change takes)
  exec "nim c -r -d:release -d:nimAllocStats tests/bench.nim"

# ---- one command each: nothing to install by hand ----------------------------------------
#
# A desktop build needs only Nim and the C compiler it came with (X11,
# Win32, Cocoa are reached at run time). An APK needs clang with lld, or
# zig (retroapk carries Android's headers and libraries itself; the NDK
# only when neither is there, fetched once into ~/.retro/ndk), and the
# package is signed here (a debug key made in ~/.retro/android, or the
# one in $RETRO_KEYS). The examples are built only when asked, one at a
# time: `nimble photoexe`, or `RETRO_APP=photo nimble exe` for any app of
# the table below.

type RetroApp = tuple
  key, src, name, stem, id, version, icon, apk: string
  code: int
  small: bool                            ## built for size (--opt:size)

const RetroApps: seq[RetroApp] = @[
  # the apps: every package of each is made from this table
  (key: "photo", src: "examples/photo.nim", name: "Retro Photo", stem: "RetroPhoto",
   id: "org.retro.photo", version: "4.9.8", icon: "examples/assets/photo-icon-512.png",
   apk: "--orientation:landscape --storage --permission:INTERNET --nim:-d:lto", code: 31, small: false),
  (key: "files", src: "examples/filemanager.nim", name: "Retro Files", stem: "RetroFiles",
   id: "org.retro.files", version: "3.3.7", icon: "examples/assets/filemanager-icon.png",
   apk: "--storage --nim:-d:lto", code: 40, small: true),
  (key: "board", src: "examples/retroboard.nim", name: "Retro Board", stem: "RetroBoard",
   id: "org.retro.board", version: "1.3.7", icon: "examples/assets/board-icon-512.png",
   apk: "--storage --nim:-d:lto", code: 11, small: true),
  (key: "mail", src: "examples/mail.nim", name: "Retro Mail", stem: "RetroMail",
   id: "org.retro.mail", version: "1.1.3", icon: "examples/assets/mail-icon-512.png",
   apk: "--permission:INTERNET --permission:POST_NOTIFICATIONS --background --nim:-d:lto", code: 8, small: false),
  (key: "taskman", src: "examples/taskman.nim", name: "Retro Task Manager", stem: "RetroTaskManager",
   id: "org.retro.taskman", version: "1.0.3", icon: "examples/assets/taskman-icon-512.png",
   apk: "--nim:-d:lto", code: 4, small: true),
  (key: "hrbook", src: "examples/hrbook.nim", name: "HR Book", stem: "HRBook",
   id: "org.retro.hrbook", version: "0.2.3", icon: "examples/assets/hrbook-icon-512.png",
   apk: "--storage --nim:-d:lto", code: 5, small: true),
  (key: "gallery", src: "examples/gallery.nim", name: "Retro Gallery", stem: "RetroGallery",
   id: "org.retro.gallery", version: "0.34.0", icon: "examples/assets/gallery-icon.png",
   apk: "--permission:INTERNET --permission:VIBRATE --nim:-d:lto --nim:--opt:size", code: 219, small: true),
  # the small examples (the gallery's icon)
  (key: "notepad", src: "examples/notepad.nim", name: "Retro Notepad", stem: "RetroNotepad",
   id: "org.retro.notepad", version: "0.34.0", icon: "examples/assets/gallery-icon.png",
   apk: "--storage --nim:-d:lto --nim:--opt:size", code: 219, small: true),
  (key: "ledger", src: "examples/ledger.nim", name: "Retro Ledger", stem: "RetroLedger",
   id: "org.retro.ledger", version: "0.34.0", icon: "examples/assets/gallery-icon.png",
   apk: "--nim:-d:lto --nim:--opt:size", code: 219, small: true),
  (key: "charts", src: "examples/charts.nim", name: "Retro Charts", stem: "RetroCharts",
   id: "org.retro.charts", version: "0.34.0", icon: "examples/assets/gallery-icon.png",
   apk: "--storage --nim:-d:lto --nim:--opt:size", code: 219, small: true),
  (key: "invoice", src: "examples/invoice.nim", name: "Retro Invoice", stem: "RetroInvoice",
   id: "org.retro.invoice", version: "0.34.0", icon: "examples/assets/gallery-icon.png",
   apk: "--storage --nim:-d:lto --nim:--opt:size", code: 219, small: true),
  (key: "native", src: "examples/native.nim", name: "Retro Native", stem: "RetroNative",
   id: "org.retro.native", version: "0.34.0", icon: "examples/assets/gallery-icon.png",
   apk: "--permission:VIBRATE --nim:-d:lto --nim:--opt:size", code: 219, small: true),
  (key: "hello", src: "examples/hello.nim", name: "Retro Hello", stem: "RetroHello",
   id: "org.retro.hello", version: "0.34.0", icon: "examples/assets/gallery-icon.png",
   apk: "--nim:-d:lto --nim:--opt:size", code: 219, small: true)]

proc app(key: string): RetroApp =
  for a in RetroApps:
    if a.key == key: return a
  quit "no app " & key

proc nimcacheFor(a: RetroApp; kind: string): string =
  ## (a nimcache of its own for each kind of build: Nim reuses an object file
  ## whose C is unchanged, whatever compiler made it -- the objects of a
  ## Linux build cannot be linked into a Windows one, nor gcc's with zig's)
  getEnv("XDG_CACHE_HOME", getEnv("HOME") & "/.cache") & "/nim/" & a.key & "_" & kind

proc apkOf(a: RetroApp; extra = "") =
  ## (an app as an APK, build/<Stem>.apk)
  mkDir "build"
  exec "nim c -r -d:release --hints:off src/retroapk.nim " & a.src &
       " --name:\"" & a.name & "\" --id:" & a.id & " --icon:" & a.icon &
       " --version:" & a.version & " --code:" & $a.code & " " & a.apk &
       " -o:build/" & a.stem & ".apk " & extra

proc frameOpt(): string =
  ## (the window's frame a desktop build draws: RETRO_FRAME=classic for
  ## Windows 3.1's, drawn by the app itself; system, or not set, for the
  ## system's own)
  case getEnv("RETRO_FRAME")
  of "classic": "-d:retroFrame=classic "
  of "", "system": ""
  else: quit "RETRO_FRAME is classic or system"

proc exeOf(a: RetroApp) =
  ## (an app for Windows from Linux or macOS, with its icon and version:
  ## MinGW's x86_64-w64-mingw32-gcc and -windres; build/win/<Stem>.exe)
  mkDir "build/win"
  let res = "build/win/" & a.stem & "-res.o"
  exec "nim c -r -d:release --hints:off tools/winicon.nim " & a.icon & " \"" & a.name & "\" " &
       a.version & " " & res
  exec "nim c -d:release -d:lto --passL:-s " & (if a.small: "--opt:size " else: "") &
       frameOpt() & "--nimcache:\"" & a.nimcacheFor("win") & "\" " &
       "-d:mingw --cpu:amd64 --app:gui --hints:off --passL:" & res &
       " -o:build/win/" & a.stem & ".exe " & a.src

proc appImageOf(a: RetroApp) =
  ## (an app for Linux packed as an AppImage with its icon, version and menu
  ## entry: tools/appimage.nim -- appimagetool and its runtime are fetched
  ## once into ~/.cache/retro-appimage. With zig, on the PATH or
  ## `pip install ziglang`, it is linked against glibc 2.31 by
  ## tools/zigcc.sh, so it runs on older systems than this one too; its LTO
  ## is ThinLTO, as the whole-program kind takes over 3 GB for Photo.)
  mkDir "build/linux"
  let bin = a.stem.toLowerAscii
  var cc = "-d:lto "
  if findExe("zig").len > 0 or gorgeEx("python3 -m ziglang version").exitCode == 0:
    let zigcc = thisDir() & "/tools/zigcc.sh"
    exec "chmod +x " & zigcc
    cc = "-d:lto_incremental --cc:clang --clang.exe:" & zigcc & " --clang.linkerexe:" & zigcc & " "
  else:
    echo "(no zig: linked with this computer's glibc; `pip install ziglang` for older systems)"
  exec "nim c -d:release " & cc & "--passL:-s " & (if a.small: "--opt:size " else: "") &
       frameOpt() & "--nimcache:\"" & a.nimcacheFor("appimage") & "\" --hints:off -o:build/linux/" &
       bin & " " & a.src
  exec "nim c -r -d:release --hints:off tools/appimage.nim build/linux/" & bin & " \"" & a.name &
       "\" " & a.version & " " & a.icon & " build/" & a.stem & "-x86_64.AppImage"

proc macAppOf(a: RetroApp) =
  ## (an app for macOS as an .app, zipped: build/mac/<Stem>-macOS.zip;
  ## tools/macapp.sh makes the bundle, its icon and its Info.plist)
  mkDir "build/mac"
  let bin = "build/mac/" & a.stem.toLowerAscii
  exec "nim c -d:release -d:lto -d:strip " & (if a.small: "--opt:size " else: "") &
       "--nimcache:\"" & a.nimcacheFor("mac") & "\" --hints:off -o:" & bin & " " & a.src
  exec "sh tools/macapp.sh " & bin & " \"" & a.name & "\" " & a.version & " " & a.icon & " " &
       a.id & " build/mac/" & a.stem & "-macOS.zip"

proc chosenApp(): RetroApp =
  ## (the app of $RETRO_APP, for the tasks that build any one of them)
  let k = getEnv("RETRO_APP")
  if k.len == 0:
    var keys: seq[string]
    for a in RetroApps: keys.add a.key
    quit "say which app: RETRO_APP=<" & keys.join("|") & "> nimble <task>"
  app(k)

task exe, "One app for Windows from Linux or macOS: RETRO_APP=photo nimble exe (build/win/; needs MinGW)":
  exeOf(chosenApp())

task appapk, "One app as an Android APK: RETRO_APP=photo nimble appapk (build/)":
  apkOf(chosenApp())

task appimage, "One app as a Linux AppImage: RETRO_APP=photo nimble appimage (build/)":
  appImageOf(chosenApp())

task macapp, "One app for macOS, on a Mac: RETRO_APP=photo nimble macapp (build/mac/)":
  macAppOf(chosenApp())

task hrbook, "Build and run HR Book, the HR records app":
  exec "nim c -r -d:release examples/hrbook.nim"

task photo, "Build and run Retro Photo, the image editor":
  exec "nim c -r -d:release examples/photo.nim"

task magazine, "Make the sample magazine with Retro Photo's engine (build/magazine: .rpd, .png, .pdf)":
  exec "nim c -r -d:release --hints:off examples/magazine.nim build/magazine"

task board, "Build and run Retro Board, the whiteboard":
  exec "nim c -r -d:release examples/retroboard.nim"

task taskman, "Build and run Retro Task Manager, what the computer is doing":
  exec "nim c -r -d:release examples/taskman.nim"

task taskmanapk, "Build Retro Task Manager as an Android APK (build/RetroTaskManager.apk)":
  apkOf(app("taskman"))

task taskmanexe, "Retro Task Manager for Windows from Linux or macOS (needs MinGW: x86_64-w64-mingw32-gcc)":
  exeOf(app("taskman"))

task mail, "Build and run Retro Mail, the mail program (Microsoft 365, Outlook.com, Gmail)":
  exec "nim c -r -d:release examples/mail.nim"

task communicator, "Build and run Retro Communicator, the chat program (XMPP; OpenSSL at run time)":
  exec "nim c -r -d:release examples/communicator.nim"

task mailapk, "Build Retro Mail as an Android APK (build/RetroMail.apk)":
  apkOf(app("mail"))

task mailexe, "Retro Mail for Windows from Linux or macOS (needs MinGW: x86_64-w64-mingw32-gcc)":
  exeOf(app("mail"))

task photoapk, "Build Retro Photo as an Android APK (build/RetroPhoto.apk)":
  apkOf(app("photo"))

task photoinstall, "Build Retro Photo's APK and install it on the phone or tablet plugged in (adb)":
  apkOf(app("photo"), "--install --run")

task boardapk, "Build Retro Board as an Android APK (build/RetroBoard.apk)":
  apkOf(app("board"))

task boardinstall, "Build Retro Board's APK and install it on the phone or tablet plugged in (adb)":
  apkOf(app("board"), "--install --run")

task galleryapk, "Build the control gallery as an Android APK (build/RetroGallery.apk)":
  apkOf(app("gallery"))

task galleryinstall, "Build the control gallery's APK and install it on the phone or tablet plugged in (adb)":
  apkOf(app("gallery"), "--install --run")

task apk, "Build Retro Files as an Android APK (build/RetroFiles.apk)":
  apkOf(app("files"))

task filesinstall, "Build Retro Files' APK and install it on the phone or tablet plugged in (adb)":
  apkOf(app("files"), "--install --run")

task apks, "Every app as an Android APK (build/*.apk)":
  for a in RetroApps: apkOf(a)

task emuapks, "The main apps' APKs for Android's emulator (x86_64, debuggable): build/apps, and its list.txt":
  # (tests/android/apps.sh opens each of them, with and without its permissions)
  mkDir "build/apps"
  var list = ""
  for a in RetroApps:
    if a.key notin ["files", "photo", "board", "gallery", "mail", "hrbook", "notepad"]: continue
    exec "nim c -r -d:release --hints:off src/retroapk.nim " & a.src &
         " --name:\"" & a.name & "\" --id:" & a.id & " --icon:" & a.icon &
         " --version:" & a.version & " --code:" & $a.code & " " & a.apk &
         " --abi:x86_64 --debuggable -o:build/apps/" & a.stem & ".apk"
    list.add a.id & " build/apps/" & a.stem & ".apk\n"
  writeFile("build/apps/list.txt", list)

task ndk, "Fetch the Android NDK now (~/.retro/ndk; needed only without clang+lld or zig)":
  exec "nim c -r -d:release --hints:off src/retroapk.nim --fetch-ndk"

task apps, "Build every example app for this computer (build/)":
  mkDir "build"
  for app in ["gallery", "hello", "notepad", "ledger", "filemanager", "charts", "invoice", "native", "photo", "retroboard",
              "taskman"]:
    # (built for size, as their packages are, but Photo: its filters want speed)
    var small = true
    for a in RetroApps:
      if a.src == "examples/" & app & ".nim": small = a.small
    exec "nim c -d:release -d:strip -d:lto " & (if small: "--opt:size " else: "") & frameOpt() &
         "--hints:off -o:build/" & app & " examples/" & app & ".nim"

task dist, "Everything to hand out: the apps for this computer and the Android APKs (build/)":
  exec "nimble apps"
  exec "nimble apks"

task photoexe, "Retro Photo for Windows from Linux or macOS (needs MinGW: x86_64-w64-mingw32-gcc)":
  exeOf(app("photo"))

task galleryexe, "The control gallery for Windows from Linux or macOS (needs MinGW: x86_64-w64-mingw32-gcc)":
  exeOf(app("gallery"))

task filesexe, "Retro Files for Windows from Linux or macOS (needs MinGW: x86_64-w64-mingw32-gcc)":
  exeOf(app("files"))

task boardexe, "Retro Board for Windows from Linux or macOS (needs MinGW: x86_64-w64-mingw32-gcc)":
  exeOf(app("board"))

task exes, "Every app for Windows from Linux or macOS (build/win/*.exe; needs MinGW)":
  for a in RetroApps: exeOf(a)

task photoappimage, "Retro Photo as a Linux AppImage (build/RetroPhoto-x86_64.AppImage)":
  appImageOf(app("photo"))

task galleryappimage, "The control gallery as a Linux AppImage (build/RetroGallery-x86_64.AppImage)":
  appImageOf(app("gallery"))

task filesappimage, "Retro Files as a Linux AppImage (build/RetroFiles-x86_64.AppImage)":
  appImageOf(app("files"))

task boardappimage, "Retro Board as a Linux AppImage (build/RetroBoard-x86_64.AppImage)":
  appImageOf(app("board"))

task appimages, "Every app as a Linux AppImage (build/*-x86_64.AppImage)":
  for a in RetroApps: appImageOf(a)

task macapps, "Every app for macOS, on a Mac (build/mac/*-macOS.zip: the .app zipped)":
  for a in RetroApps: macAppOf(a)
