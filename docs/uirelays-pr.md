Android and iOS drivers, pen input, optional OpenGL and platform-service relays, WinAPI and X11 fixes

This adds two phone drivers (Android and iOS), pen input for the desktop drivers, two optional relay groups (`gpuRelays` for OpenGL and `systemRelays` for platform services), and some smaller additions and fixes. Each commit does one thing and builds on its own, so the PR can be reviewed commit by commit, or split if you would rather merge it in parts.

## Commits

1. **input: keys for `[ ] ; ' \ `` ` and the context menu key.** Adds these keys in WinAPI, X11, GTK4, SDL2 and SDL3. X11 also gets the slash key.
2. **input: `Event.hasMods`.** WinAPI, X11 and Cocoa now set `mods` on mouse events too, and `hasMods` says when they did. In X11, a modifier key's own press and release now report the state after the key.
3. **WinAPI fixes:**
   - Alt+key and F10 reach the app as key events; Alt+F4 still closes the window.
   - The mouse is captured during a drag, and its coordinates are read as signed numbers.
   - An emoji (a UTF-16 surrogate pair) arrives as one character.
   - The window's client area is now the size the app asked for.
4. **input: `BackButton` and `ForwardButton`** (the mouse's side buttons) from WinAPI, X11 and Cocoa.
5. **screen: `curSizeNWSE`, `curSizeNESW` and `curMove`** cursors in every driver.
6. **X11: the scale without `Xft.dpi`.** X11 now reads `GDK_SCALE`, then `QT_SCALE_FACTOR`, then the monitor's physical size (XRandR, loaded at run time). It rounds to steps of 25% and never goes below 100%.
7. **X11: `drawRGBA` no longer hashes every pixel.** Each picture counts as a change. When a frame only put pictures, the refresh copies just the area they covered.
8. **screen: `pointerHeight` relay.** It reports the drawn mouse-pointer size so tooltips can sit below the pointer. Implemented for WinAPI.
9. **screen, input: phones.**
   - `ScreenLayout` gets the safe-area margins (`safeTop`, `safeBottom`, `safeLeft`, `safeRight`) and `touch`.
   - New events: `AppPauseEvent`, `AppResumeEvent`, and `GestureEvent` (`scale`, `dx`, `dy`, `phase`). Events also get `fromMouse`.
   - `WindowHiddenEvent` and `WindowShownEvent`: a desktop window minimized and back (X11: unmapped or `_NET_WM_STATE_HIDDEN`; WinAPI: `SIZE_MINIMIZED`; macOS: into the Dock), so an app can leave out drawing nobody sees while its timers go on.
   - SDL3 fills these in, maps Android's back key to Escape, and turns text input on only while `WantTextInput` is set.
10. **SDL3: `TTF_SetFontStyle` loads from SDL_ttf.** `-d:sdl3` no longer needs `-lSDL3_ttf` passed by hand.
11. **screen: `GpuRelays`** (optional): an OpenGL context on the window.
    - WinAPI uses WGL.
    - X11 uses OpenGL ES 2 through EGL, loaded at run time by `eglload.nim`, so nothing new is linked.
    - A driver without it draws as before.
12. **input: pen pressure, tilt, azimuth and twist**, plus the eraser end. Supported in WinAPI (WM_POINTER), X11 (XInput 2, libXi loaded at run time), macOS, GTK4 and SDL3. The mouse path is unchanged. `drivers/penaxes.nim` does the conversions, and `tests/penaxestest.nim` tests them.
13. **services: `SystemRelays`** (optional): the app's data folder, opening links and files, the standard folders, storage permission, decoding photos, minimize, and `systemCall`. The defaults cover the desktop systems.
14. **Android driver (NativeActivity).**
    - Touch, mouse, pen and two-finger gestures; keys with the keyboard's own characters.
    - Rectangles, lines, points and RGBA pictures; text in the system font, which shapes Arabic.
    - The clipboard, links, and OpenGL ES through EGL.
    - It runs with a plain `NativeActivity`. `drivers/android/UiRelaysActivity.java` is an optional subclass that adds text without key codes, the on-screen keyboard, insets and system-bar colors.
15. **iOS driver (UIKit).** Touch, the keyboard, hardware keys, the clipboard and CoreText text. It shares `surface_driver.nim` with Android.
16. **README and doc/drivers.md:** the new relays, events and layout fields, and how to build for Android and iOS.

## Compatibility

- **New enum values** in `KeyCode`, `EventKind`, `MouseButton` and `CursorKind`. A `case` over these enums with no `else` branch needs the new values.
- **New fields** in `Event` and `ScreenLayout` default to zero or false. Drivers that do not set them behave as before.
- **WinAPI:** Alt+key and F10 now come to the app as key events (Alt+F4 still closes the window). The window's client area is the size asked for; before, the title bar and borders were taken out of it.
- **X11:** `drawRGBA` no longer hashes pixels (see commit 7).
- `gpuRelays` and `systemRelays` are optional.

## Testing

On Linux, for every commit:
- **X11:** the examples build, and `tinyniftest`, `layouttest`, `rgbatest`, `penaxestest` and `nativealphatest` (under xvfb) pass.
- **Windows:** the examples cross-build with MinGW.
- **SDL3, SDL2, GTK4 and macOS:** `nim check` of `examples/paint.nim` passes.
- **Android** (from commit 14 on): `examples/hello.nim` compiles and links as `libmain.so` (arm64, API 24).
- **iOS** (from commit 15 on): `nim check --os:macosx -d:ios` passes.

Not built here: the Cocoa and UIKit Objective-C code (no Mac), and the siwin and FigDraw drivers (only their cursor mapping changed). `tests/inputtest.nim` already fails to compile on master (`isCommandChord`); this PR does not touch it.
