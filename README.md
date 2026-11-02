# uirelays

Native Nim UI library based on the idea of "relays" -- dependency injection
via global callbacks. Has Windows API, X11, Cocoa, GTK4, SDL2, SDL3, FigDraw,
Android and iOS support. Write UI apps as easily as terminal apps!

[![focim](screenshots/focim.png)](https://github.com/Araq/focim)

*[focim](https://github.com/Araq/focim), the Focussed Nim Editor, is
written with it.*

## Getting started

`import uirelays` is all you need -- it re-exports everything and
automatically initializes the native backend for the current platform
(WinAPI on Windows, Cocoa on macOS, X11 on Linux/BSD). Override with
`-d:sdl3`, `-d:sdl2`, `-d:gtk4`, or a FigDraw Nimble feature.

For finer control, import the submodules directly and call `initBackend()`
yourself:

```nim
import uirelays/[coords, screen, input, backend]
initBackend()
```

## Installation

Install this package with Nimble:

```sh
nimble install
```

Backend selection:

- Default on Windows: WinAPI
- Default on macOS: Cocoa
- Default on Linux/BSD: X11
- Android (`--os:android`): the NativeActivity driver; iOS (`-d:ios`): UIKit
- Optional overrides: `-d:gtk4`, `-d:sdl3`, `-d:sdl2`
- Optional features: `siwin`, `figDrawWindy`, and `figDrawSiwin`

### Siwin windows with native drawing

The `siwin` feature uses Siwin's software windows and event loop, with native
Core Graphics, GDI, or Xft/XRender drawing. It does not create a FigDraw GPU
renderer. Unix sessions use X11, including XWayland on Wayland desktops.

```sh
atlas install --feature:uirelays.siwin
nim c -d:features.uirelays.siwin examples/hello.nim
```

The existing `features.uirelays.figDrawSiwin` and `figDrawSiwin` flags also
select native Siwin drawing. The old feature still installs FigDraw for
compatibility; the `siwin` feature only needs Siwin.

The Siwin driver uses Siwin's blocking global event loop for
`waitEvent`, while `pollEvent` remains nonblocking. Presenting a frame with
`refresh()` does not request another application repaint. Native expose and
resize events still request redraws. A persistent native drawing surface
preserves contents across presentation and resize. This driver requires
Siwin 1.1.2 or newer.

To run the real-window alpha, presentation, and resize regression test:

```sh
nim r tests/siwinnativetest.nim
# Linux: xvfb-run -a nim r tests/siwinnativetest.nim
```

### Optional FigDraw GPU backends

The Windy integration and the explicit legacy Siwin GPU adapter use FigDraw
for GPU presentation. They are separate from native Siwin drawing:

```sh
atlas install --feature:uirelays.figDrawWindy
nim c -d:features.uirelays.figDrawWindy examples/hello.nim

atlas install --feature:uirelays.figDrawSiwin
nim c -d:features.uirelays.figDrawSiwinGpu examples/hello.nim
```

The default Cocoa, WinAPI, and X11 drivers use platform drawing APIs as well.
Windy and Siwin selections are mutually exclusive.

### Nim Packages For SDL Backends

The SDL backends need extra Nim packages in addition to the native system
libraries:

```sh
nimble install sdl3
nimble install sdl2
```

Install `sdl3` when building with `-d:sdl3`. Install `sdl2` when building
with `-d:sdl2`.

### Linux

Choose the backend you want and install its native development packages.

#### Ubuntu

Default X11 backend:

```sh
sudo apt install libx11-dev libxft-dev
```

GTK4 backend:

```sh
sudo apt install libgtk-4-dev libpango1.0-dev libcairo2-dev libfontconfig1-dev libglib2.0-dev pkg-config
```

SDL3 backend:

```sh
sudo apt install libsdl3-dev libsdl3-ttf-dev
nimble install sdl3
```

SDL2 backend:

```sh
sudo apt install libsdl2-dev libsdl2-ttf-dev
nimble install sdl2
```

#### Fedora

Default X11 backend:

```sh
sudo dnf install libX11-devel libXft-devel
```

GTK4 backend:

```sh
sudo dnf install gtk4-devel pango-devel cairo-devel fontconfig-devel glib2-devel pkgconf-pkg-config
```

SDL3 backend:

```sh
sudo dnf install SDL3-devel SDL3_ttf-devel
nimble install sdl3
```

SDL2 backend:

```sh
sudo dnf install SDL2-devel SDL2_ttf-devel
nimble install sdl2
```
#### Arch

Default X11 backend:

```sh
sudo pacman -S libx11 libxft
```

GTK4 backend:

```sh
sudo pacman -S gtk4 pango cairo fontconfig glib2 pkgconf
```

SDL3 backend:

```sh
sudo pacman -S sdl3 sdl3_ttf
nimble install sdl3
```

SDL2 backend:

```sh
sudo pacman -S sdl2-compat sdl2_ttf
nimble install sdl2
```

### macOS

The default Cocoa backend needs no extra native libraries.

```sh
nim c examples/hello.nim
```

For SDL backends on macOS, install the SDL libraries with your preferred
package manager, then install the matching Nim package:

```sh
nimble install sdl3
nimble install sdl2
```

### Windows

The default WinAPI backend needs no extra native libraries.

```sh
nim c examples/hello.nim
```

For SDL backends on Windows, install the SDL native libraries separately
and then install the matching Nim package:

```sh
nimble sdl3
nimble install sdl2
```

### Build Examples

Use the default backend for your platform:

```sh
nim c examples/hello.nim
```

Force a specific backend:

```sh
nim c -d:gtk4 examples/hello.nim
nim c -d:sdl3 examples/hello.nim
nim c -d:sdl2 examples/hello.nim
nim c --define:"features.uirelays.figDrawWindy" examples/hello.nim
nim c --define:"features.uirelays.figDrawSiwin" examples/hello.nim
```

## Apps

- [focim](https://github.com/Araq/focim) -- the Focussed Nim Editor: a code
  editor with an integrated terminal, laid out and colored by an editable
  config file. It lived in this repository until it outgrew it; the widgets it
  is made of -- SynEdit, the terminal panel, the clipboard history -- went with
  it, since they were an editor's parts and not a UI library's.

## Examples

- [hello.nim](examples/hello.nim) -- Minimal window with text rendering
- [paint.nim](examples/paint.nim) -- Simple drawing app with explicit submodule imports
- [layout_demo.nim](examples/layout_demo.nim) -- NIF layout system demo
- [todo.nim](examples/todo.nim) -- Todo list app

## Architecture

The library is split into five relay groups, and two optional ones:

| Module | Relays | Purpose |
|--------|--------|---------|
| `screen` | `windowRelays` | Window lifecycle, cursor, clip rect |
| `screen` | `fontRelays` | Font loading, text measurement and rendering |
| `screen` | `drawRelays` | Rectangles, lines, points, images |
| `input` | `inputRelays` | Events, timing, shutdown |
| `input` | `clipboardRelays` | Copy/paste |
| `screen` | `gpuRelays` | Optional: OpenGL (ES 2 or 2.1) on the window |
| `services` | `systemRelays` | Optional: the app's data folder, links, files, places |

Drivers populate these relay objects at init time. Application code calls
convenience wrappers (`fillRect`, `drawText`, `waitEvent`, ...) that
dispatch through the relays. No virtual calls, no inheritance, no heap
allocation -- just plain proc pointers.

## Drivers

| Driver | Platform | Dependencies |
|--------|----------|-------------|
| `winapi_driver` | Windows | None (GDI) |
| `cocoa_driver` | macOS | None (AppKit) |
| `x11_driver` | Linux/BSD | libX11, libXft |
| `gtk4_driver` | Linux/BSD | GTK4, Cairo, Pango |
| `sdl3_driver` | Cross-platform | SDL3, SDL3_ttf |
| `sdl2_driver` | Cross-platform | SDL2, SDL2_ttf |
| `figdraw_windy_driver` | Cross-platform | FigDraw, Windy |
| `figdraw_siwin_driver` | Cross-platform | FigDraw, siwin |
| `android_driver` | Android | None (NDK: libandroid, liblog) |
| `uikit_driver` | iOS | None (UIKit) |

See [Writing a custom driver](doc/drivers.md) for a guide on
adding support for a new platform or graphics toolkit.

## Phones, tablets and pens

- `ScreenLayout.safeTop`, `safeBottom`, `safeLeft`, `safeRight`: the margins
  a status bar, a notch or a gesture bar cover; `touch`: the main pointer is
  a finger.
- `AppPauseEvent` / `AppResumeEvent`: the app went to the background and
  came back (stop drawing; draw everything again).
- `GestureEvent`: two fingers -- `scale`, `dx`, `dy` round their middle
  `x`, `y`, and the `phase`. `fromMouse`: on a touch screen, the pointer is a
  mouse or a pen.
- Pens: `pen`, `pressure`, `tilt`, `azimuth` and `twist` on the mouse events
  a pen makes -- from Windows (WM_POINTER), X11 (XInput 2), macOS, GTK4, SDL3
  and Android (`drivers/penaxes` does the arithmetic).
- `hasMods`: the event's `mods` are filled in (mouse events too, not only
  keys). `BackButton`, `ForwardButton`: the mouse's side buttons.

### OpenGL

Drivers that can draw with OpenGL on their window offer `gpuRelays` (WinAPI
with WGL, X11 with EGL loaded at run time, Android). `startGpu()` makes a context
current; the app then draws every frame with OpenGL, `swapGpu()` shows it, and
`stopGpu()` goes back to `drawRGBA`. A driver without it keeps drawing as
before.

### Android

Build the app as `libmain.so` and pack it into an APK whose activity is
`android.app.NativeActivity` (with `android.app.lib_name` = `main`), or
[UiRelaysActivity](src/uirelays/drivers/android/UiRelaysActivity.java) for
text without key codes (Arabic, emoji), the keyboard and the system bars:

```sh
nim c --os:android --cpu:arm64 --app:lib --noMain -d:noSignalHandler \
  --cc:clang --clang.exe:aarch64-linux-android24-clang \
  --clang.linkerexe:aarch64-linux-android24-clang -o:libmain.so app.nim
```

### iOS

On a Mac, compile with `--os:macosx -d:ios` and the iOS SDK's clang
(`xcrun --sdk iphoneos clang`), and put the program in an .app bundle with an
`Info.plist` that has `UILaunchScreen` (iOS 14 and later).

## Drawing full-resolution images

`drawRGBA(pixels, width, height, destination)` draws an opaque image of packed
`0x00RRGGBB` words into a destination in driver coordinates. Cocoa, WinAPI,
X11, GTK4, and the FigDraw siwin/Windy drivers support it. The driver copies or consumes the
buffer before returning.

On a Retina surface, rasterize `layout.width * layout.scaleX` by
`layout.height * layout.scaleY` pixels, then draw into
`rect(0, 0, layout.width, layout.height)`. Each source pixel then maps to a
backing pixel. Native text and drawing continue to use logical coordinates.

WinAPI and X11 expose physical window pixels, with fractional UI enlargement
reported by `ScreenLayout.uiScale` (for example, 125 or 150). Rasterizing the
full window dimensions then draws pixels directly. X11 resamples only when
source and destination sizes actually differ; its ordinary HiDPI path does
not copy or filter the image.

The existing `blitRGBA` retains its clipping-only behavior. `drawRGBA` falls
back to it when source and destination dimensions match, and returns `false`
for unsupported drawing requests. Cocoa also preserves the last backing image
during live resize, until the application repaints the new dimensions.

Pass `RGBAFormat.argbPremultiplied` to either method to composite a translucent
image over previous drawing. Pixels are then host-order `0xAARRGGBB` words,
with each RGB channel already multiplied by alpha. For example,
`0x80800000` is half-transparent red, and `0x00000000` is transparent.

```nim
var pixels = [0x80800000'u32, 0x00000000'u32]
discard drawRGBA(cast[ptr UncheckedArray[uint32]](addr pixels[0]),
  2, 1, rect(20, 20, 2, 1), RGBAFormat.argbPremultiplied)
```

Cocoa uses Core Graphics, WinAPI uses GDI `AlphaBlend`, X11 uses XRender,
and GTK4 uses Cairo for source-over composition. The optional FigDraw drivers
also preserve premultiplied alpha. SDL2/SDL3 currently return `false` for alpha
buffers. Omitting the format retains the original opaque RGB behavior, including
buffers whose unused top byte is zero. Scaling and clipping rules are unchanged.
Custom drivers must add the `format: RGBAFormat` parameter to their two RGBA
relay callbacks; unsupported formats should return `false` without drawing.

## Layout

A window's boxes are described in NIF -- a
parenthesized format read by the dependency-free lexer in `uirelays/tinynif`
-- and `uirelays/layout` turns that description into a `Rect` per name:

```
(layout
  (toolbar (lines 2))
  (cols
    (sidebar (px 250))
    (editor))
  (status (lines 1)))
```

`(rows ...)` stacks its children top to bottom, `(cols ...)` places them left
to right, and either may hold the other. Every other tag is a leaf that names
a widget and may state its size along the axis its parent divides: `(px 250)`
in logical pixels, `(lines 5)` in text lines, `(stretch 2)` in shares of what
is left over. `resolve` computes the rects; `hitTest` says which name a click
landed in. See [layout_demo.nim](examples/layout_demo.nim).

The borders are draggable, and nothing has to be drawn for them to be: the
`gap` `resolve` leaves between adjacent boxes is already there, so it is the
grip. `splitterAt` says which border a pointer is on, `dragTo` moves it, and
`$` writes the layout back out as the text it came from -- with the new sizes
in the unit each box was already written in, a `(px N)` staying pixels and a
`(lines N)` snapping to whole lines. An application that keeps its layout in a
file therefore gets mouse-resizable panels without keeping a second copy of
the sizes anywhere: what the pointer moves is what the file says.

The tree grows and shrinks the same way. `splitCell` puts a second box beside
one that is there -- to its right or below it -- taking the room out of that
box alone, halved in whatever unit it was written in, so no other border
moves; `removeCell` takes a box out again and folds away the container it
empties. `cellNames` says what is in the layout, which is how an application
works out which widgets it needs. Since a split is an edit of the tree and the
tree is the file, an application that spawns and closes panels stores nothing
about them: what the window holds is what the layout says, and one more cell
typed into the file by hand is one more panel.

## License

MIT
