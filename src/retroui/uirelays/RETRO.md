# uirelays in retro

`src/retroui/uirelays` is [uirelays](https://github.com/nim-lang/uirelays)
with my changes for phones, tablets, pens and the GPU, so retro needs no
other package. Import it as `retroui/uirelays`.

It is the same code as `src/uirelays` on the **`uirelays` branch** of this
repository: upstream's history with my commits on it, upstream merged in
up to the commit in `VERSION`, ready to go upstream as a pull request. Nothing in it
knows about retro -- it stays a library for any Nim program.

## Keeping the two the same

    tools/uirelays.sh push "X11: what changed"   # src/retroui/uirelays -> a commit on the branch
    tools/uirelays.sh pull                       # the branch -> src/retroui/uirelays
    tools/uirelays.sh diff                       # what differs between them
    tools/uirelays.sh merge                      # upstream's new commits into the branch, then pull

`merge` fetches nim-lang/uirelays master and merges it into the branch in
a worktree of its own; when the two changed the same lines it stops and
says where, to finish there by hand (`git add`, `git commit`), then
`tools/uirelays.sh pull`. Write the upstream commit merged into `VERSION`.

## Sending it upstream

    git push https://github.com/foxoman/uirelays.git uirelays:android-ios-pens-gpu

then open the pull request on nim-lang/uirelays from that branch; its text
is in `docs/uirelays-pr.md`.

## What it adds to upstream

- `drivers/android_driver.nim`, `drivers/android_glue.c` -- Android: a
  NativeActivity, the app on its own thread, input through the activity's
  input queue (touch, mouse, pens, two-finger gestures, keys with the
  keyboard's own characters), the frame put in the window with
  `ANativeWindow_lock`, clipboard, links, system-font text (Arabic shaped),
  OpenGL ES through EGL. `drivers/android/UiRelaysActivity.java` is an
  optional activity for text without key codes, the keyboard, insets and the
  system bars; retro's own is `tools/android/RetroActivity.java`, which also
  answers `uirelaysCall` (documents of other apps, media, printing...).
- `drivers/uikit_driver.nim`, `drivers/uikit_backend.m` -- iOS with UIKit.
- `drivers/surface_driver.nim` -- the relays both phone drivers share.
- `services.nim` -- `systemRelays`: data folder, links, files, places,
  storage access, photo decoding, `systemCall`.
- `target.nim` -- `androidApp` (an APK: the NativeActivity driver) and
  `androidShell` (a program run in Termux: the X11 driver, on
  Termux:X11), both built with `--os:android`.
- Files dropped on the window (`FileDropEvent`: WM_DROPFILES, XDND) and
  dragged out of it (`startFileDragOut`, `fileDragRelays`: OLE's DoDragDrop
  with CF_HDROP and the shell's IDList Array, XDND as the source with
  `text/uri-list`, a Cocoa dragging session with file URLs);
  `filesOfUriList`, `uriListOfFiles`, `hdropOfFiles`.
- A window without the system's frame, for an app that draws its own
  (`frameRelays`, `windowPartAt`, `canDrawFrame`, `setSystemFrame`,
  `startWindowMove`, `startWindowResize`, `maximizeWindow`,
  `windowActive`, `setFrameMenuItem`): WinAPI (the system menu's item),
  Cocoa (the menu bar's Window menu), X11 (EWMH, or the driver's own
  moving, sizing and maximizing without a window manager), GTK 4 (Wayland
  too), SDL 3 and SDL 2 (the hit test), Siwin; minimize for SDL and GTK.
- `eglload.nim` -- EGL loaded at run time; `gpuRelays` in `screen.nim`.
- Screen readers: `access.nim` (a tree of nodes -- role, name, value,
  states, place, range, caret -- and `accessRelays` to hand it on, with the
  requests that come back: press, focus, set a value, a step), `dbus.nim`
  (a D-Bus client in Nim: the wire format, EXTERNAL sign-in, calls and
  signals) and `atspi.nim` (AT-SPI 2 over it: Accessible, Component,
  Action, Text, EditableText, Value, the events Orca follows); the X11
  driver serves it, the WinAPI driver UI Automation (`drivers/winuia.nim`:
  the provider's COM tables in Nim, WM_GETOBJECT), Cocoa NSAccessibility,
  UIKit UIAccessibilityElement, Android an AccessibilityNodeProvider
  through `systemRelays`.
- Input methods: `TextEditingEvent` (what is being composed, its caret) and
  `textCaretRelay`: X11 XIM (preedit callbacks, else the spot, else none),
  WinAPI IMM (the composition string and its caret), Cocoa marked text,
  GTK 4 preedit, Android an InputConnection.
- `SurfaceRelays` in `screen.nim` (`lockSurface`, `presentSurface`): the
  window's own pixels lent to draw into -- X11 MIT-SHM (libXext loaded at
  run time; libandroid-shmem in Termux), a WinAPI DIB section with only
  the changed rectangles painted, Cocoa redrawing only those; a program
  that does not lock it draws through `putRGBA` as before. X11 also takes the scale of the monitor
  the window is on (RandR).
- Windows of another program's put inside the app's (a web view): a click
  in the app's window takes the keyboard back from them (X11, WinAPI;
  UIKit lets such a view keep it until its own view is touched);
  `winWindow` gives the WinAPI driver's window, as `x11Window` the X11
  driver's.
- `drivers/wayland_driver.nim` -- Wayland spoken directly over its socket
  (`drivers/wlwire.nim`: the wire protocol, no libwayland): windows in
  shared memory (`drivers/pixbuf.nim`), fractional scaling, the system's
  frame where the compositor draws one, the clipboard and drops, the
  keyboard's layout through libxkbcommon loaded at run time
  (`drivers/xkbload.nim`; `drivers/keysyms.nim`, shared with X11), input
  methods, touch, cursors (the compositor's shapes, else
  `drivers/cursorart.nim`, shared with X11), text through fontconfig and
  FreeType loaded at run time (`drivers/ftfonts.nim`), screen readers.
  `-d:wayland` builds it alone; a Linux build has it with X11 and picks
  one as it starts (`backend.useWayland`: `RETRO_DRIVER`, else a Wayland
  session without an X display).
- `drivers/fb_driver.nim` -- a screen with no windowing system: DRM/KMS (a
  dumb buffer in the connector's mode) or the framebuffer device, drawn
  from a shadow buffer (`pixbuf.nim`) with a software cursor; input read
  from evdev itself (keyboards with the system's layout through
  `xkbload.nim`, mice, touch screens and pads, pens), devices plugged in
  while it runs, the console switched with Ctrl+Alt+F1..F12 (VT_PROCESS).
  `-d:kiosk` builds it alone; a Linux build has it and takes it on a text
  console (`backend.useScreen`: `RETRO_DRIVER=kms|fb`, else no X11 or
  Wayland and a screen there). `RETRO_FB_FILE` and `RETRO_FB_INPUT` give
  it a file as the screen and pipes as the devices, for tests.
- `drivers/web_driver.nim` -- a page in the browser (`-d:wasm`, WebAssembly):
  the frame put on a canvas, input, the clipboard, fonts and sound through
  functions the page gives the program (its imports), a frame at a time.
- More windows than the program's own: `WindowsRelays` in `screen.nim`
  (`openWindow`, `closeWindow`, `setTitle`, `layout`, `target`, `toFront`)
  and `Event.window`, the window an event came to (0 the program's). Each
  window has its own back buffer; `target` says which one drawing goes to.
  X11 (transient for the program's window), WinAPI (owned windows of the
  same class), Cocoa and Wayland (`framed`: whether the system draws their
  frame); the other drivers have one window.
- `drivers/penaxes.nim` -- a pen's pressure, lean and turn from what each
  system reports.
- `input.nim`, `screen.nim`: more keys, the mouse's side buttons,
  `hasMods`, pens, `AppPauseEvent` / `AppResumeEvent`, `GestureEvent`, the
  safe area and `touch`, diagonal and move cursors, `pointerHeight`,
  `OutsideWindow` (the pointer left the window).
- The same input on every system: Cmd reported as Ctrl on macOS and iOS
  (Control as the Gui key, Control + click a right click); AltGr neither
  Ctrl nor Alt on Windows; X11's keys of a non-Latin layout (Ctrl+C with a
  Cyrillic, Greek or Hebrew one, Ctrl+1 on AZERTY) by the Latin layout's;
  the keypad's keys everywhere; the sideways wheel (`x`) everywhere, the
  wheel's and touch pads' fractions of a notch kept; clicks counted for
  each button, with the system's double-click time and distance; the
  modifiers on every event of the phones; `setTextCaret` for the input
  methods of Windows and macOS.
- `services.nim`: `standardFolder` (XDG's user-dirs, Windows' Known
  Folders), `folderName`, the BSDs' names in `platformName`.
- Driver fixes: WinAPI (Alt shortcuts, mouse capture, signed coordinates,
  surrogate pairs, the client size, the size Windows suggests at a change
  of density, CR LF in the clipboard, 64-bit ticks), X11 (the scale
  without `Xft.dpi`, the first window's size at the scale, only the
  pictures' part copied, `_NET_WM_NAME`, large pastes (INCR) and Latin-1,
  the monotonic clock, the BSDs' library names), Cocoa (the app's name in
  the title and the menus, Hide, Minimize, Close, files dropped from the
  Finder, the system's cursors), SDL3 (safe area, text input on demand,
  TTF_SetFontStyle linked).
