# Building Retro apps: desktop, Android, iOS and the web, step by step

Retro builds its own Android packages: `retroapk` compiles the app and
writes and signs the APK itself. You do **not** need the Android SDK,
Android Studio, Java, Gradle, OpenSSL or apksigner -- and not the Android
NDK either: `retroapk` carries Android's headers and libraries inside
itself (a 1.2 MB sysroot) and builds with any **clang that has lld**, or
with **zig**. Only when neither is there does it fetch the NDK (about
700 MB) once, as a fallback.

iOS apps are built on a Mac with Xcode by `retroios`: no Xcode project.

A web page is built by `retrokit web` with clang and wasm-ld alone: no
Emscripten. The packages the stores take -- an App Bundle, an MSIX, a
signed Windows program, a signed macOS app, an .ipa -- are made and
signed in Nim by `retrokit` ("Shipping to the stores", at the end).

`retroapk`, `retroios` and `retrokit` come with the package: after
`nimble install retroui` they are on your PATH (in `~/.nimble/bin`).
`retrokit doctor` checks what a machine has and says what is missing.

---

## Desktop: Windows, macOS, Linux and BSD

A desktop app needs Nim and a C compiler, nothing more: the kit links only
what every system has (Windows' own DLLs, Cocoa, libc; X11 is loaded when
the app starts).

```sh
nim c -r -d:release -d:useMalloc app.nim     # build and run on this computer (or: retrokit run app.nim)
retrokit small app.nim                       # the smallest: --opt:size, LTO, stripped
```

**Windows, on Windows:** the Nim zip for Windows comes with MinGW;
`nim c -d:release -d:useMalloc --app:gui app.nim` makes `app.exe`
(`--app:gui`: no console window).

**Windows, from Linux or macOS:** install MinGW-w64 (`apt install
mingw-w64`, `dnf install mingw64-gcc`, `brew install mingw-w64`), then

```sh
nim c -d:release -d:useMalloc -d:mingw --cpu:amd64 --app:gui app.nim
```

One `.exe`, no DLLs beside it. Wine runs it for a first look
(`wine app.exe`). To give it an icon and a version, in a clone of the
repository:

```sh
nim c -r tools/winicon.nim icon.png "My App" 1.0 build/myapp-res.o
nim c -d:release -d:useMalloc -d:mingw --cpu:amd64 --app:gui --passL:build/myapp-res.o app.nim
```

**macOS:** `xcode-select --install` gives the compiler. `sh
tools/macapp.sh program "My App" 1.0 icon.png com.me.myapp out.zip` (in a
clone) makes the `.app` with its icon and zips it.

**Linux:** gcc or clang; no `-dev` packages (libX11 is loaded when the
app starts; Wayland is spoken by the kit itself). `nim c -r tools/appimage.nim program "My App" 1.0
icon.png MyApp-x86_64.AppImage` (in a clone) packs it as an AppImage, one
file with its icon and menu entry.

The same build runs on X11, on Wayland and on a screen with no desktop;
it takes what it finds, and the environment chooses:

| | |
|---|---|
| `RETRO_DRIVER=x11` / `wayland` | X11 (or XWayland) / the Wayland driver (taken by itself when there is no X11; fontconfig and FreeType, loaded when it starts, find its fonts) |
| `RETRO_DRIVER=kms` / `fb` | the screen driver: DRM/KMS, or the framebuffer (taken by itself on a text console with no X11 or Wayland) |
| `-d:wayland`, `-d:kiosk` | a build with only that driver (smaller; a kiosk image needs nothing else) |
| `RETRO_KMS_CARD=/dev/dri/card1`, `RETRO_KMS_MODE=1280x800`, `RETRO_FBDEV=/dev/fb1` | the screen driver's screen and mode |
| `RETRO_FB_GRAB=0` | the screen driver leaves the input devices to others too |
| `RETRO_WAYLAND_DEBUG=1` (or `2`) | what the Wayland driver finds (and every event) |

The screen driver needs the user in the `video` and `input` groups (or
root), and a console of its own: on a kiosk, start the app from a systemd
service on `tty1` (`TTYPath=/dev/tty1`, `StandardInput=tty`).

**BSD:** as on Linux, with the system's clang and X11 (or Wayland) from
packages.

**The examples** are built only when you ask, one at a time:
`RETRO_APP=photo nimble exe` (Windows, from Linux or macOS),
`RETRO_APP=photo nimble appimage`, `RETRO_APP=photo nimble macapp` (on a
Mac), `RETRO_APP=photo nimble appapk`; the apps are listed in
`retroui.nimble` (`RetroApps`).

**Apps that use `retroui/xmpp`** (Retro Communicator: `nimble
communicator`) build with `-d:ssl`: Nim's TLS through OpenSSL, loaded when
the app starts (libssl 3 or 1.1, which Linux, the BSDs and Termux have; on
Windows the OpenSSL DLLs beside the .exe). `examples/communicator.nims`
turns it on for the example. Its voice messages record with Termux:API's
`termux-microphone-record` (a phone, in Termux) or PulseAudio's `parecord`
or ALSA's `arecord` (Linux), and ffmpeg, where it is, makes them AAC; they
play with the system's sound, or mpv or ffplay. Its encryption
(`retroui/omemo`) uses libcrypto 1.1.1 or later, the same OpenSSL; where
it is missing, talks go unencrypted and the lock button is grayed.

**Connections (`retroui/netconn`: Retro Mail's IMAP and SMTP) need
nothing at build time:** each system's own TLS -- SChannel on Windows,
Secure Transport on macOS and iOS, Java in an Android app -- and on Linux,
the BSDs and Termux OpenSSL's libssl (3 or 1.1), loaded the first time a
connection is encrypted (a program without it still starts; Termux: `pkg
install openssl`).

**Screen readers and input methods need nothing at build time**: the
app speaks AT-SPI over D-Bus itself on Linux and BSD (Orca reads it when
the desktop runs the accessibility bus, as GNOME, KDE and Retro Desktop
do), UI Automation on Windows, the system's own API on macOS, iOS and
Android. To try them without a screen reader, in a clone:

- `RETRO_ACCESS=1 retrokit run app.nim` makes the tree even when no screen
  reader listens; `accerciser` (Linux) or Windows' Inspect show it.
- `nimble test` runs `test_access` headless and `test_atspi` on an X
  server with AT-SPI's bus (`apt install at-spi2-core dbus-x11`; skipped
  without them); `test_uia` runs under Wine
  (`nim c -d:mingw --cpu:amd64 -o:t.exe tests/test_uia.nim && RETRO_ACCESS=1 wine t.exe`).
- An input method on X11: `apt install uim-xim uim-anthy` (Japanese), then
  `LANG=ja_JP.UTF-8 XMODIFIERS=@im=uim uim-xim &` before the app.
- `RETRO_SURFACE=0` draws without shared memory (MIT-SHM on X11, the DIB
  section on Windows), to compare.

**The inspector and the driver need nothing at build time either.** F12
over an app built without `-d:release` (or any build started with
`RETRO_INSPECT=1`) shows why each frame ran, the control under the mouse
and the frame's controls. An app started with `RETRO_DRIVE=7000` is used
from outside by its controls' names: `retrokit drive 7000 click OK`,
`retrokit drive 7000 type "Ada"`, `retrokit drive 7000 tree` (README,
"The inspector and the driver"). Only 127.0.0.1 can connect. On Android:

```sh
retroapk app.nim --permission:INTERNET --install    # (sockets, even to the phone itself)
adb shell am start -n org.example.app/org.retro.RetroActivity --es RETRO_DRIVE 7000
adb forward tcp:7000 tcp:7000
retrokit drive 7000 tree
```

**The system's web view needs nothing at build time either**
(`webView(url, engine = weSystem)`, README "Web and HTML"): the engine is
loaded when the first page is shown, and without it the kit's own engine
shows the page.

- Linux and BSD (the X11 driver): WebKitGTK for GTK 3 -- `apt install
  libwebkit2gtk-4.1-0` (Debian, Ubuntu), `dnf install webkit2gtk4.1`
  (Fedora), `pacman -S webkit2gtk-4.1` (Arch), the BSDs' `webkit2-gtk`
  package; 4.0 does too. GTK runs in a thread of its own, its window put
  inside the app's.
- Termux, on Termux:X11: `pkg install x11-repo && pkg install
  webkit2gtk-4.1`.
- Windows 10 and 11: WebView2, the Edge engine Windows keeps up to date.
  `WebView2Loader.dll` beside the `.exe` (from Microsoft's
  `Microsoft.Web.WebView2` package, `build/native/x64`) is the surest
  start; without it the kit finds the engine where Windows keeps it. A
  page's data (cookies, storage) is kept in
  `%LOCALAPPDATA%\<program>\WebView2`.
- macOS and iOS: WKWebView, part of the system.
- Android: the APK's own (`tools/android/RetroWeb.java`, in every APK);
  pages on the web need `retroapk --permission:INTERNET`.

`RETRO_WEB=system` makes every `webView` that does not name its engine use
the system's (`kit` the kit's), to try an app both ways; `RETRO_WEB_TOOLS=1`
turns on the engine's developer tools.

**Retro Designer** (`retrokit designer app.nim`, [docs/designer.md](docs/designer.md))
builds itself the first time it runs, with the Nim and the C compiler you
build your apps with, into the toolkit's cache folder
(`retrodesigner` there; `--rebuild` builds it again). It reads files with
Nim's own parser, so it is compiled against the compiler's sources: those
beside the Nim that builds it (a Nim from nim-lang.org, choosenim, Homebrew
or a Linux package has them), else nimble's `compiler` package, which
`retrokit` installs when it has to. `retrokit` first checks that the parser
builds from them. Nim 2.4's compiler sources import `dist/nimony` and
`dist/checksums`, which Termux's package (and nimble's `compiler` package)
leave out: `retrokit` copies the sources into its cache (`nim-VERSION`) with
what the system has of `dist`, and fetches the rest with git, at the commits
that Nim version's `koch.nim` pins.
By hand, in a clone:

```sh
nim c -d:release -d:useMalloc --path:<nim>/ src/retrodesigner/retrodesigner.nim   # <nim>: the folder with compiler/ and lib/
```

On Windows it is built `--app:gui`; in Termux with Termux's clang (Android
before 9 has no `glob()`, which the compiler's sources name: a stand-in in
`src/retrodesigner/androidglob.c` is linked). Its tests:
`nim c -r tests/test_designer.nim` (it finds the compiler's sources the same
way, `tests/test_designer.nims`).

**The web:** clang with the WebAssembly target and wasm-ld (LLVM's lld):
`apt install clang lld`, `dnf install clang lld`, `brew install llvm
lld`, LLVM's installer on Windows. Then

```sh
retrokit web app.nim --files:data --icon:icon.png --name:"My App"   # build/web
retrokit run --web --watch app.nim      # served on http://localhost:8765, rebuilt on every save
```

`--out:DIR` puts the page elsewhere, `--small` optimizes for size (`-Oz`),
`--debug` keeps Nim's checks and stack traces, `--jobs:N` runs N C
compilers at once (else one a core while the memory lasts; at most 4 in
Termux), `--lto:full|thin|none` chooses how the program is optimized as a
whole (below); anything else goes to the compiler.

**How the program is linked:** `full` (the default) optimizes the whole
program at once -- the Gallery's link takes 1.5 GB; `thin` does it in
pieces on threads of one process -- 0.9 GB, the page 6 % bigger -- and is
the default in Termux and where less than 3 GB is free; `none` skips it:
the quickest build, the default of `retrokit run --web` (to try it, on
your own computer). Put `build/web` on any web server (HTTPS, for the service
worker); the page is `index.html`. The C library is compiled once into
the cache (`RETROWEB_CACHE` another folder), once with threads and once
without.

What is beside the page: `app.wasm` and its gzipped copy `app.wasm.gz`
(for servers that hand such copies out: nginx's `gzip_static`; GitHub
Pages and the like compress by themselves), `retro.js`, `kit/fonts/` (the
kit's fonts, fetched when a face is first used), `app/` (`--files`),
`oauth.html` (where a sign-in comes back to, `retroui/oauth`), the
manifest, the icons and `sw.js` (the service worker).

**Threads:** `--threads` builds the app twice, `app.wasm` and
`app-threads.wasm` (`--threads:on`, WebAssembly's atomics, one shared
memory of up to 1 GB) -- `retrokit run --web --threads` once, with
threads only (its server lets the page use them); the page takes the second where the browser lets
it share memory with Web Workers (crossOriginIsolated: the server sends
`Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp` -- the page's service worker
adds them on any server, the page loading once more the first time;
`retrokit run --web` sends them itself). `--threads:N` starts N workers
with the page (the cores, at most 8, else); `--threads-only` builds only
with threads (an app that needs them; elsewhere the page says so). Code
that starts threads itself compiles both ways: `when
compileOption("threads")`. Other sites' pages in a frame need to allow
being embedded (`Cross-Origin-Resource-Policy`) in a page with threads.

**Fonts in programs:** `-d:retroFonts=all` (the default: twelve faces,
1.0 MB), `sans`, `ui` (FreeSans and its bold) or `none`: the faces left
out are read from `fonts/` beside the program (the `.ttf.z` files of
`src/retroui/fonts`) or `$RETRO_FONTS`, else drawn with FreeSans.

**What CI checks, here:** `sh tools/cicheck.sh` runs the steps GitHub's CI
runs -- the return check, the warnings on every system
(`sh tools/warncheck.sh`: the kit's own files have none, as Linux,
Termux, an Android app, Windows, macOS, iOS and the web build them, and
neither have the examples and the tests), the
tests, a short fuzz, the Android driver on a fake Android, the tests as
WebAssembly, the tools -- and ends with the number that failed
(`quick`: the longer ones left out).

**Testing it all**, in a clone: `nimble test` (headless), `nimble fuzz`,
`sh tests/run32.sh` (as 32-bit programs: `apt install gcc-multilib` and
the i386 X11 libraries), `sh tests/web/run.sh` (Playwright's Chromium),
`sh tests/wayland/run.sh` (sway), `sh tests/kiosk/run.sh`,
`sh tests/store/linux.sh`, `sh tests/web/node.sh` (the headless tests as
WebAssembly under Node), `python3 tools/returncheck.py` (no `return x`
after `result` was set: Nim 2.2 leaks the old value; `docs/nim-bugs.md`).
The decoders under libFuzzer (clang):

```sh
nim c --cc:clang --noMain -d:useMalloc -d:release --debugger:native \
  --passC:"-fsanitize=fuzzer,address,undefined -fno-sanitize=function" \
  --passL:"-fsanitize=fuzzer,address,undefined" -d:fuzzTarget=png -o:lf tests/fuzz/libfuzz.nim
./lf -max_total_time=300 corpus/ tests/fuzz/seeds
```

Under the sanitizers:

```sh
ASAN_OPTIONS=detect_leaks=1 LSAN_OPTIONS=suppressions=tests/lsan.supp \
nim c -r --hints:off --cc:clang -d:useMalloc --debugger:native \
  --passC:"-fsanitize=address,undefined -fno-omit-frame-pointer -fno-sanitize=function" \
  --passL:"-fsanitize=address,undefined" tests/test_widgets.nim
```

---

## Android

What each system needs (Nim builds `retroapk` itself with its usual C
compiler; clang + lld or zig compile the app for Android):

| System | Nim | Android compiler (no NDK) |
|---|---|---|
| Windows 10/11 | the Nim zip (with MinGW) | the LLVM installer, or zig |
| macOS | `brew install nim` | `brew install llvm lld`, or `brew install zig` |
| Linux | choosenim or the distribution's `nim` | `clang` and `lld` packages, or zig |
| FreeBSD, OpenBSD, NetBSD | `nim` from packages | clang and lld (base system or packages), or zig |
| Termux (on the phone) | `pkg install nim` | `pkg install clang ndk-sysroot` |

### Windows 10 or 11

1. **Nim.** Download the Nim zip for Windows (x86_64) from
   <https://nim-lang.org/install_windows.html>, unzip it to `C:\nim`, run
   `C:\nim\finish.exe`, and answer yes to adding Nim to the PATH and to
   downloading MinGW (the C compiler). Open a new terminal (PowerShell or
   cmd) and check: `nim -v`, `gcc -v`.
2. **The Android compiler**, one of:
   - **LLVM:** `winget install LLVM.LLVM`, or the installer
     (`LLVM-<version>-win64.exe`) from
     <https://github.com/llvm/llvm-project/releases>. It goes into
     `C:\Program Files\LLVM` with `clang.exe` and `ld.lld.exe`;
     `retroapk` looks there by itself, on the PATH or not.
   - **Zig:** `winget install zig.zig`, or the zip from
     <https://ziglang.org/download/> with its folder added to the PATH, or
     `pip install ziglang`.
3. **Retro.** `nimble install retroui` (or, from the source folder,
   `nimble install` there).
4. **Build.** In your app's folder:

   ```bat
   retroapk app.nim --name:"My App" --id:com.me.myapp
   ```

   The first build unpacks the sysroot into
   `%USERPROFILE%\.retro\android-sysroot` (once, about 8 MB), then makes
   `app.apk` next to `app.nim`.
5. **Put it on the phone:** see [Installing on the phone](#installing-on-the-phone).

### macOS (Apple Silicon or Intel)

1. **The C compiler for Nim:** `xcode-select --install` (the Command Line
   Tools; the whole Xcode is only needed for iOS).
2. **Nim:** `brew install nim` (Homebrew: <https://brew.sh>), or
   `curl https://nim-lang.org/choosenim/init.sh -sSf | sh`.
3. **The Android compiler:** `brew install llvm lld` -- Apple's own clang
   has no lld, so `retroapk` takes Homebrew's from
   `/opt/homebrew/opt/llvm/bin` (`/usr/local/opt/llvm/bin` on Intel); nothing
   to add to the PATH. Or `brew install zig`.
4. **Retro:** `nimble install retroui`.
5. **Build:**

   ```sh
   retroapk app.nim --name:"My App" --id:com.me.myapp
   ```

### Linux

1. **The C compilers:** Debian/Ubuntu `sudo apt install gcc clang lld`,
   Fedora `sudo dnf install gcc clang lld`, Arch `sudo pacman -S gcc clang lld`
   (or zig instead of clang and lld).
2. **Nim:** `curl https://nim-lang.org/choosenim/init.sh -sSf | sh` (or
   your distribution's `nim` package if it is 2.2 or newer).
3. **Retro:** `nimble install retroui`.
4. **Build:** `retroapk app.nim --name:"My App" --id:com.me.myapp`.

### FreeBSD, OpenBSD, NetBSD

Google makes the NDK for Windows, macOS and Linux only; with the sysroot
in `retroapk` a BSD needs none:

1. **Nim:** `pkg install nim` (FreeBSD), `pkg_add nim` (OpenBSD),
   `pkgin install nim` (NetBSD).
2. **The Android compiler:** a clang and an `ld.lld`: FreeBSD's base
   system has both (or `pkg install llvm`); on OpenBSD and NetBSD, clang
   and lld from packages or ports. Or zig from packages.
3. **Retro and the build** as on Linux.

`retroapk` tries each clang it finds with a small Android library first
and takes the first that works (`retrokit doctor` shows which one); a
clang built without the AArch64 or X86 targets is passed over.

### On the phone itself (Termux)

```sh
pkg install nim clang ndk-sysroot openssl-tool git
nimble install retroui
retroapk app.nim --name:"My App" --install     # the installer asks to confirm
```

Termux's clang builds for the phone's own ABI; with `pkg install lld` the
sysroot in `retroapk` builds the others too (`--abi:x86_64`...).

### Building on a phone or tablet

A build starts the Nim compiler (about 600 MB of memory for a big app),
C compilers, and a linker. Android watches all of it:

- **"[Process completed (signal 9)]":** Android 12 and later stop an app's
  processes when there are many of them (32, for all apps together), or
  when they use much of the processor while the app is in the background;
  with little memory it stops them too. The kit's builds run as many C
  compilers as the free memory allows and at most four in Termux; the next
  build says when the last one was stopped, and goes on from what it had
  compiled. Fewer: `--jobs:1` (or `RETRO_JOBS=1`).
- **Keep Termux in front** while it builds (or `termux-wake-lock`).
- **Turn Android's limit off:** Android 14 and later -- Settings, Developer
  options, "Disable child process restrictions". Android 12 and 13 -- from
  a computer with adb (or Termux's `adb` paired by Wireless debugging):
  `adb shell "settings put global settings_enable_monitor_phantom_procs false"`
  (Android 12L, 13), or
  `adb shell "/system/bin/device_config put activity_manager max_phantom_processes 2147483647"`
  (Android 12).
- **Web pages:** `retrokit run --web` builds once and links quickly; `retrokit
  web` links in pieces in Termux (`--lto:thin`, 0.9 GB instead of 1.5 GB for
  the Gallery).

### A desktop app in Termux, on Termux:X11

The same app also runs in Termux itself, in a window on Termux:X11 (the
Termux:X11 app, from F-Droid or its GitHub releases), with no APK:

```sh
pkg install x11-repo
pkg install termux-x11-nightly libx11 nim clang git
nimble install retroui
nim c -r -d:release -d:useMalloc app.nim
```

That is all: when no X server is running the app starts Termux:X11's
(`termux-x11 :0`, and `DISPLAY=:0` when it is not set), brings the
Termux:X11 app to the front and opens there. With no window manager on
Termux:X11 (as it comes) the window fills the screen and turns with the
tablet, as an Android app does; it is as big as the tablet's density says
(200 % on a 320 dpi screen; `RETRO_SCALE=150`, or Ctrl + and Ctrl -, for
another size; `RETRO_TOUCH=1` for finger-sized controls). For windows you
can move and size, run a window manager on Termux:X11 first (`pkg install
openbox`, then `openbox &`, a whole desktop such as xfce4, or
[Retro Desktop](https://github.com/foxoman/retrodesktop), the 3.1 desktop I
made with the kit): the app then opens as an ordinary window, and Termux:X11
is not brought to the front again (the desktop is there already).

**While working on an app, see it as a window:** `retrokit run --window
app.nim` (or `RETRO_WINDOW=1` before any program built with the kit). With
no window manager, the toolkit then draws a desktop (the 3.1 teal) over the
screen and opens the app on it at its own size grown by the tablet's density,
in the middle, in its 3.1 frame: move it by the title bar, size it by the
border or the grip in its corner (fingers too), maximize it, use its control
menu. Keys go to it, also after a tap on the desktop; the desktop follows the
tablet when it turns and when Termux:X11's window is made floating or sized,
and the window stays in view. It prints the size it came to and the scales behind it;
`--scale:125` (or `RETRO_SCALE=125`) makes everything and the window larger,
`--size:420x840` and `--theme:Dark` try a layout and a look. With a window
manager running, `--window` just gives the app its 3.1 frame.
`retrokit run --live app.nim` does the same and builds the app again on
every save of a `.nim` file in its folder, starting the new one where the
window was (code that does not build leaves the old one running).
`--watch` alone does that on any desktop: Windows, macOS, Linux.

A program can be the window manager itself: the X11 driver hands each event
to `x11EventHook` (in `retroui/uirelays/drivers/x11_driver`) before it looks
at it, and gives its connection and window (`x11Display`, `x11Window`);
`x11Wake` runs a frame. Retro Desktop is made that way.

The cursor font X has is 16 pixels, whatever the screen: on a dense one
(150% and more) the driver draws the cursors itself, in the classic shapes,
at the screen's scale. `x11DrawnCursors = 1` asks for them always, `0`
never (the cursor font, or a cursor theme through libXcursor).

In Termux, Nim builds for Android, so the kit decides by what is built:
an APK's library (`--app:lib`, what `retroapk` makes) gets Android's own
driver; a program run from the shell gets the X11 driver, its files and
services as on Linux, and draws on the CPU.

### How the compiler is chosen

1. `--cc:PATH` or `RETRO_ANDROID_CC` (a compiler of your own);
2. Termux's clang, in Termux;
3. an NDK that is there: `ANDROID_NDK_HOME`, `ANDROID_NDK_ROOT`,
   `ANDROID_HOME/ndk/*`, or one fetched before into `~/.retro/ndk`;
4. **no NDK:** a clang with lld -- Homebrew's llvm (macOS), the PATH's
   clang, `C:\Program Files\LLVM\bin` (Windows), `clang-18` and the like --,
   then zig (on the PATH, or pip's `ziglang`), each with the sysroot;
5. none of these: the NDK is fetched into `~/.retro/ndk` (Windows' own
   `curl` and `tar`, the .dmg with `hdiutil` on a Mac, `unzip` on Linux).

`--toolchain:clang`, `--toolchain:zig` or `--toolchain:ndk` (or
`RETRO_ANDROID_TOOLCHAIN`) picks one. The sysroot has arm64-v8a (phones
and tablets) and x86_64 (the emulator, Chromebooks) from API 24 (Android 7,
the kit's lowest); the 32-bit ABIs (`armeabi-v7a`, `x86`) and `--min-sdk`
below 24 use the NDK. Android before 10 has no native thread-local storage,
so below `--min-sdk:29` the libraries use emulated TLS; zig cannot make it in
an LTO link, so with zig `-d:lto` is left out there (a somewhat bigger
library).

The sysroot: bionic's headers and the kernel's uapi headers, the NDK's
`android/*.h`, `log.h`, `jni.h`; for each ABI the crt objects, stubs of
`libc.so`, `libm.so`, `libdl.so`, `liblog.so` and `libandroid.so` (made from
Android's own symbol lists, as the NDK's are; the phone has the real
ones), and LLVM's compiler-rt builtins. `libEGL` and `libGLESv2` are not
linked: the kit opens them at run time. It is unpacked once into
`~/.retro/android-sysroot/api24-<checksum>` (`RETRO_SYSROOT_DIR` puts it, or
a sysroot of your own, elsewhere). `tools/android/mksysroot.sh` makes it
again from the AOSP and LLVM sources at pinned revisions (same sources and
same clang, same archive). Its `NOTICE` and `licenses/` say where each part
comes from: bionic (BSD and Apache-2.0), frameworks/native and
frameworks/base, liblog and libnativehelper (Apache-2.0), compiler-rt
(Apache-2.0 WITH LLVM-exception).

### The options you will use

```sh
retroapk app.nim --name:"My App" --id:com.me.myapp \
  --version:1.2 --code:3 \             # the version shown, and its number (higher for each update)
  --icon:icon.png \                    # 512x512 PNG (else a drawn 3.1 window)
  --abi:arm64-v8a,x86_64 \            # phones (arm64 is the default) and the emulator
  --permission:INTERNET \              # one --permission for each
  --orientation:landscape \            # or portrait (default: any)
  -o:build/MyApp.apk
```

`--aab` makes an Android App Bundle for Google Play instead (below).
`retroapk --help` lists every option. The examples have tasks:
`nimble galleryapk`, `nimble photoapk`, `nimble apk` (Retro Files),
`nimble mailapk`, `nimble boardapk`, `nimble taskmanapk`, `nimble apks` (all), into `build/`.
`nimble ndk` fetches the NDK now, for machines that will use it.

### Signing

The first build makes a signing key in `~/.retro/android`
(`%USERPROFILE%\.retro\android` on Windows). **Keep that folder** (copy it
somewhere safe): Android installs an update only when it is signed with
the same key as the app on the phone. For a key of your own:
`--key:key.pem --cert:cert.der`; `RETRO_KEYS=folder` keeps the debug key
elsewhere.

### For Google Play

Play takes an App Bundle signed with your **upload key**:

```sh
openssl req -x509 -newkey rsa:2048 -nodes -keyout upload.pem -out upload.crt \
  -days 9125 -subj "/CN=My Company"                        # once; keep both files safe
openssl x509 -in upload.crt -outform DER -out upload.der
retroapk app.nim --aab --name:"My App" --id:com.me.myapp --version:1.2 --code:3 \
  --abi:arm64-v8a,x86_64 --key:upload.pem --cert:upload.der   # app.aab
```

In Play Console, let Google keep the app's signing key (Play App
Signing) and upload `app.aab`; register `upload.der` as the upload key the
first time. To try a bundle before uploading it, Google's bundletool makes
the APKs a phone gets: `java -jar bundletool.jar build-apks
--bundle=app.aab --output=app.apks --mode=universal`.

### Installing on the phone

- **Without a cable:** copy the .apk to the phone (a USB cable as a
  drive, a cloud folder, an email to yourself), tap it in the phone's
  Files app and allow "Install unknown apps" for that app when asked.
- **With adb** (Android's command-line tool -- "SDK Platform-Tools", a
  small zip of its own, not the SDK:
  <https://developer.android.com/tools/releases/platform-tools>; unzip it
  and add the folder to the PATH): turn on USB debugging on the phone
  (Settings > About phone > tap Build number 7 times; then Developer
  options > USB debugging), plug it in, and

  ```sh
  retroapk app.nim --name:"My App" --run        # builds, installs, starts
  adb logcat -s retro                           # the app's echo output
  ```

### If something goes wrong

- **"... cannot build for x86_64":** that clang lacks the target or
  its lld; `retroapk` goes on to the next clang, then zig. `--verbose`
  shows every command, `--toolchain:zig` skips clang.
- **A damaged sysroot:** delete `~/.retro/android-sysroot`; the next
  build unpacks it again.
- **The NDK download stops half way:** delete `~/.retro/ndk` and build
  again (or `nimble ndk`). Behind a proxy, set `HTTPS_PROXY`; with no
  internet, download the NDK zip yourself and set `RETRO_NDK_URL=file:///path/to/android-ndk-r27c-linux.zip`.
- **You already have an NDK:** set `ANDROID_NDK_HOME` to it (any r23 or
  newer); it is used first and nothing is downloaded.
- **"App not installed" on the phone:** the app is already there signed
  with another key (uninstall it first), or the `--code` is lower than the
  installed one's.
- **The app closes as it opens:** open it again -- the kit wrote down what
  stopped it (a crash of its Nim code, of the native code or of Java) and
  shows it first, before the app runs, with Copy and Send by Email; "Start
  without what was open the last time" opens it without the document,
  folder or board that may have caused it (ticked by itself when it
  stopped again right after that screen's Start).
- **A crash report with addresses only** (`libmain.so+0x386786`, or
  logcat's `#00 pc 0000000000386786 .../libmain.so`): the APK's library
  is stripped, and `retroapk` keeps a copy with its functions' names beside
  the APK, in `APP-symbols/ABI/libmain.so` (llvm-strip: the NDK's, LLVM's,
  or on the PATH; without one the library is linked stripped and no copy
  is kept). Keep that folder with each APK you hand out (the Release has
  `APP-symbols.zip`); `retrokit symbolize report.txt build/RetroPhoto-symbols`
  names the frames.
- **One activity:** the manifest makes the activity its task's only one
  (`singleTask`), so starting the app again -- its icon, an intent,
  `adb shell am start` -- brings it back as it was. The app's start runs
  once at a time in a process: a running app goes on in an activity made
  beside it or in its place (the old one finishes), and an app that ended
  starts again in the next one with the first run's cycles collected.
- **Permissions:** `retroapk` reads what the app's compiled code uses --
  the camera, the microphone, notifications, the place, a buzz, the
  network -- and lists those permissions in the manifest by itself (it says
  which; `--no-auto-permissions` leaves them out). The app asks the user
  the first time the feature is used (Android 6 and later), and goes on
  without it when the answer is no.
- **Built for Android's emulator:** `nimble emuapks` (x86_64, debuggable);
  `sh tests/android/apps.sh build/apps/list.txt` opens each with and
  without its permissions, turns the screen both ways, puts it away and
  brings it back, drives it with the monkey and fails on a crash (the
  systems workflow does it on Android 11 and 15). A debuggable
  APK's library is not stripped, so a native crash's frames are named
  (with the NDK's `llvm-addr2line`), and Nim's stack traces are on.

---

## iOS (on a Mac)

### Once

1. **Xcode** from the App Store. Open it once, let it install its
   components, and accept the licence (`sudo xcodebuild -license accept`).
   In Xcode > Settings > Components (Platforms), install the iOS
   Simulator runtime.
2. **Nim:** `brew install nim`.
3. **Retro:** `nimble install retroui` (gives `retroios`).

### In the Simulator

```sh
open -a Simulator                               # starts an iPhone in the Simulator
retroios app.nim --simulator --run              # builds, installs and starts it there
```

The app is built into `build/ios-app/App.app` beside `app.nim` (`build/ios-<file>/<Name>.app`; `-o:` puts it elsewhere).

### On your iPhone or iPad

1. **An Apple ID in Xcode:** Xcode > Settings > Accounts > + > Apple ID. A
   free account can put apps on your own devices (they expire after 7
   days); a paid Apple Developer account (99 USD a year) is needed for a
   year's signing, TestFlight and the App Store.
2. **Developer Mode on the device:** plug it in, trust the Mac, then on
   the device Settings > Privacy & Security > Developer Mode > on (it
   restarts).
3. **A provisioning profile for your app's id.** The simplest way: in
   Xcode, File > New > Project > iOS App, give it the same bundle id you
   will use (`com.me.myapp`), choose your team under Signing &
   Capabilities, pick your device and press Run once. Xcode makes the
   profile; it is in `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`
   (older Xcode: `~/Library/MobileDevice/Provisioning Profiles/`). Copy it
   next to your app as `dev.mobileprovision`.
4. **Your signing identity's name:**

   ```sh
   security find-identity -v -p codesigning
   # 1) ABCD... "Apple Development: Sultan Al Isaiee (TEAMID1234)"
   ```

5. **Your device's name:** `xcrun devicectl list devices`.
6. **Build, sign, install and start:**

   ```sh
   retroios app.nim --name:"My App" --id:com.me.myapp \
     --sign:"Apple Development: Sultan Al Isaiee (TEAMID1234)" \
     --profile:dev.mobileprovision --device:"My iPhone" --run
   ```

   The first time, the device may say the developer is not trusted:
   Settings > General > VPN & Device Management > your Apple ID > Trust.

### For TestFlight or the App Store

Sign with an "Apple Distribution" identity and an App Store
provisioning profile (made at <https://developer.apple.com/account>);
`--ipa` packs the bundle as the .ipa you send with Apple's Transporter app
(or `xcrun altool --upload-app`):

```sh
retroios app.nim --name:"My App" --id:com.me.myapp --version:1.0 --code:1 \
  --sign:"Apple Distribution: Sultan Al Isaiee (TEAMID1234)" --profile:appstore.mobileprovision --ipa
```

`retrokit ipa build/ios-app/MyApp.app` packs a bundle you built and signed
before. (The .ipa follows Apple's documented layout, `Payload/<Name>.app`;
an upload to App Store Connect is not yet among the verified steps below.)

### Options

`retroios --help`: `--name`, `--id`, `--version`, `--code`, `--icon`
(1024x1024 PNG), `--min-ios` (default 14.0), `--simulator`, `--sign`,
`--profile`, `--device`, `--run`, `--ipa`, `--nim:FLAG`, `-o:Dir.app`, `--verbose`.
Without a Mac, `retroios app.nim --sdk:iPhoneOS.sdk` (an iOS SDK copied
from a Mac, and LLVM's `lld`) links an unsigned bundle -- to check that
the app compiles for iOS.

---

## Shipping to the stores

Every package below is made and signed by `retrokit` in Nim, on any
system; only Apple's own signature and notarization need a Mac. Each
command has `--help`.

### Windows: a signed program, an MSIX

A code signing certificate comes from an authority (DigiCert, Sectigo,
SSL.com, Certum, or Microsoft's Trusted Signing) as a `.pfx`; take its key
and certificate out once:

```sh
openssl pkcs12 -in my.pfx -nocerts -nodes -out key.pem
openssl pkcs12 -in my.pfx -clcerts -nokeys -out cert.pem     # yours
openssl pkcs12 -in my.pfx -cacerts -nokeys -out chain.pem    # the authority's
```

```sh
retrokit sign app.exe --key:key.pem --cert:cert.pem --chain:chain.pem --name:"My App" \
  --url:https://me.example --timestamp:http://timestamp.digicert.com
retrokit msix app.exe --name:MyCompany.MyApp --display:"My App" --version:1.2.0.0 \
  --icon:icon.png --files:data --key:key.pem --cert:cert.pem --chain:chain.pem \
  --timestamp:http://timestamp.digicert.com                # app.msix, the program inside signed too
```

The time stamp keeps the signature good after the certificate expires;
use your authority's server. The MSIX's publisher is your certificate's
subject (read from it); for the **Microsoft Store**, take the package
name, publisher and publisher name Partner Center gives the app (`--name`,
and a certificate whose subject is that publisher, or let the Store sign
it: upload it as it is). `--capability:internetClient` (and webcam,
microphone...) adds what the app uses; `--arch` is read from the program.

**To install it yourself**, Windows must trust the certificate: with a
test certificate (no `--key`: one made in `~/.retro/windows`), as an
administrator, `Import-Certificate -FilePath dev-cert.der
-CertStoreLocation Cert:\LocalMachine\TrustedPeople`, then open the .msix
or `Add-AppxPackage app.msix`.

### macOS: an app signed, notarized, stapled

```sh
nim c -d:release app.nim                                   # on a Mac (or give a program built there)
retrokit mac app --name:"My App" --id:com.me.myapp --version:1.2 --icon:icon.png   # signed ad hoc
retrokit mac app.nim --universal ...                      # built here for Apple silicon and Intel
```

That `.app` (and its `.zip`) runs on the Mac that made it and on Apple
silicon anywhere; one downloaded from the web asks once (right click,
Open). For people to open it without asking, sign it with your **Developer
ID** and have Apple notarize it, on a Mac:

```sh
xcrun notarytool store-credentials myprofile --apple-id me@example.com --team-id TEAMID1234
retrokit mac app --name:"My App" --id:com.me.myapp \
  --sign:"Developer ID Application: Sultan Al Isaiee (TEAMID1234)" --notarize:myprofile
```

It is signed with the hardened runtime and a secure time stamp, sent to
Apple, waited for, and the ticket stapled to it; the zip beside it is what
you put on your site. `--entitlements:app.entitlements` adds what the app
needs (the camera's and the microphone's usage texts are in its
Info.plist already).

### Android, iOS, the web

Google Play: `retroapk --aab` (above, "For Google Play"). The App Store:
`retroios --ipa` (above). The web: `retrokit web` (above).

### Updates inside the app

For an app shipped outside the stores (an AppImage, a Windows program, a
page): `retroui/update` takes your releases by itself, signed by you.

```sh
retrokit update-key                  # once: update-key.secret, and the public key for the app
```

Keep `update-key.secret` out of the repository (`.gitignore` has
`*.secret`); in CI give it as a secret, `RETRO_UPDATE_KEY` (the key itself).
Put the public key in the app (`checkForUpdate(url, updateKey, version)`).
For each release, beside its files, write `update.json`:

```json
{ "version": "1.3.0", "notes": "Faster search.",
  "files": { "linux-x86_64": { "url": "https://example.com/notes/Notes-1.3.0.AppImage" },
             "windows-x86_64": { "url": "https://example.com/notes/Notes-1.3.0.exe" } } }
```

```sh
retrokit update-sign update.json     # each file's size and SHA-256 filled in; update.json.sig
```

and publish `update.json`, `update.json.sig` and the files where the app
looks. The systems' names: `linux-x86_64`, `linux-arm64`, `windows-x86_64`,
`windows-arm64`, `macos-arm64`, `macos-x86_64`, `android-arm64`, `web`.

### Verified

APKs: built without the NDK on Linux for arm64-v8a and x86_64, with
clang 18 + lld and with zig 0.17; each `libmain.so` checked
(its machine, the libraries it needs, no symbol outside Android's system
libraries, 16 KB page alignment) and each APK verified with `apksigner` and
`aapt`. Built with the NDK's compiler before, and run on an Android tablet.
App Bundles: `bundletool validate`, `bundletool build-apks` (the APK's
manifest and resources as aapt2 makes them), `jarsigner -verify`.
Windows programs and MSIX packages: `osslsigncode verify` (the
Authenticode digest, the MSIX's four digests, the time stamp of an
authority made with OpenSSL); on GitHub, Windows' own
`Get-AuthenticodeSignature`, `signtool verify` and `makeappx`, and the
MSIX installed and removed. macOS apps signed ad hoc: `rcodesign verify`,
the sealed resources the same as `rcodesign`'s to the byte; on GitHub,
`codesign --verify --deep --strict` and the app run. Windows and macOS find
their compilers in the places above and follow the same steps (a `.cmd`
wrapper on Windows); the NDK download for them follows Google's packages
(zip, .dmg). iOS: compiled and linked against the iOS SDK; the Simulator
runs the live check on GitHub; the device steps are Apple's standard ones.
Not yet tried: an upload to Google Play, to Partner Center, to App Store
Connect; Apple's notarization from `retrokit mac` (its steps are Apple's
own commands).

## Every RETRO_ setting

An app built with the kit reads these from its environment when it starts
(none is needed: each has a default). On Android an app has no
environment of its own: `adb shell am start -n PACKAGE/org.retro.RetroActivity
--es RETRO_DRIVE 7000` gives it the settings its start names.

**The window and the look**

| Setting | What it does |
|---|---|
| `RETRO_DRIVER=x11`, `wayland`, `kms`, `fb` | the driver on Linux and BSD (else the one there is) |
| `RETRO_FRAME=classic` / `system` | the 3.1 frame the kit draws, or the system's |
| `RETRO_CAPTION=1` | the phone's title bar on a desktop |
| `RETRO_SIZE=420x840` | the window this many design pixels (to try layouts) |
| `RETRO_SCALE=150` | everything this percent of its size, the window too |
| `RETRO_ZOOM=2` | whole driver pixels per design pixel (1-4) |
| `RETRO_TOUCH=1`, `RETRO_CONTROLS=touch` / `desktop` / `auto` | as on a touch screen; the controls' sizes only |
| `RETRO_THEME=Dark` | a built-in theme |
| `RETRO_TEXT=sharp` / `sharp-bgr` | letters drawn in the screen's color strips |
| `RETRO_WINDOW=1` | on a screen with no window manager (Termux:X11): the app as a window of its own size, on a desktop the kit draws |
| `RETRO_WINDOW_STATE=FILE` | where the window's place and size are kept (`retrokit run --watch`) |
| `RETRO_GPU=cpu` / `gpu` / `auto` | drawing on the CPU or with OpenGL |
| `RETRO_GPU_KEEP=0` | the GPU keeps no pictures between frames (to compare) |
| `RETRO_SURFACE=0` | no memory shared with the screen (MIT-SHM, the DIB section): the frame copied |
| `RETRO_3D_GPU=0` | the 3D view drawn on the CPU |
| `RETRO_KMS_CARD`, `RETRO_KMS_MODE`, `RETRO_FBDEV` | the screen driver's card, mode, framebuffer |
| `RETRO_FB_GRAB=0` | the screen driver leaves the input devices to others too |
| `RETRO_FB_INPUT=/dev/input/event3,...` | the screen driver's input devices (else all it finds) |
| `RETRO_FB_FILE=FILE` | the screen driver draws into a file (tests) |
| `RETRO_FONTS=FOLDER` | the faces a build with fewer fonts (`-d:retroFonts`) left out, read from there |

**What the app does**

| Setting | What it does |
|---|---|
| `RETRO_INSPECT=1` | the inspector shown from the start (F12 in any build) |
| `RETRO_DRIVE=PORT` | the driver: a program on this machine uses the app by its controls' names (`retrokit drive`) |
| `RETRO_ACCESS=1` | the screen readers' tree made with no screen reader |
| `RETRO_SMOKE=SECONDS`, `RETRO_SMOKE_OUT=FILE` | the smoke run: the first frame timed, 3 s untouched measured, then clicks and keys |
| `RETRO_STATS=1` | the frames' times and counts on stderr, every 2 seconds, and each frame of 250 ms or more (where the mouse was, the key) |
| `RETRO_THREADS=N` | the worker threads (else one a processor, at most 16) |
| `RETRO_WEB=system` | every `webView` in the system's browser engine |
| `RETRO_WEB_TOOLS=1` | the system's web view with its developer tools |
| `RETRO_SPELL=none` | no spell checking (else the system's checker, or Hunspell) |
| `RETRO_SECRETS_DIR=FOLDER` | `saveSecret` keeps secrets in files there, not in the system's keychain |
| `RETRO_HTTP_CURL_COMMAND=1` | `httpRequest` runs the `curl` program, not libcurl |
| `RETRO_MAIL_ISPDB=URL`, `RETRO_MAIL_DOH=URL` | where Retro Mail's setup looks a mail server up |
| `RETRO_BLENDER=PATH` | the Blender that turns `.blend` models into glTF |
| `RETRO_GPU_COMPOSITE=0` | Retro Photo's layers put together on the CPU |
| `RETRO_GPU_DEBUG=1`, `RETRO_3D_DEBUG=1`, `RETRO_WAYLAND_DEBUG=1` | what the GPU, the 3D view, the Wayland driver find, on stderr |

**The tools** (`retrokit`, `retroapk`, `retroweb`)

| Setting | What it does |
|---|---|
| `RETRO_APP=NAME` | the app of `retroui.nimble`'s table the `nimble` tasks build |
| `RETRO_JOBS=N` | C compilers at once |
| `RETRO_KEYS=FOLDER` | the Android signing keys (else `~/.retro/android`) |
| `RETRO_ANDROID_CC=PATH`, `RETRO_ANDROID_TOOLCHAIN=clang` / `zig` / `ndk` | the compiler for APKs |
| `RETRO_SYSROOT_DIR=FOLDER` | where Android's small sysroot is unpacked |
| `RETRO_NDK_DIR=FOLDER`, `RETRO_NDK_URL=URL` | where the NDK is kept, and where it comes from |
| `RETRO_TIMESTAMP=URL` | the time-stamp authority for Windows' signatures |
| `RETRO_UPDATE_KEY=KEY` | the key `retrokit update-sign` signs with (in CI, a secret) |
