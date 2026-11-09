# Third-party notices

Retro Nim UI is mine and MIT licensed (`LICENSE`). A few parts of it come
from others, under their own licenses; this file lists each one, where it
is, what an app made with the kit carries, and what you need to do when
you ship one. Every license text is in the repository beside the part.

## Carried in apps (only when the app uses the part)

| Part | Where | License | What it is for |
|---|---|---|---|
| GNU FreeFont (FreeSans, FreeSerif, FreeMono, four styles each; subsets) | `src/retroui/fonts/Free*.ttf(.z)`, `LICENSE-FreeFont.txt` | GPL 3 with the font exception | the text of every app, PDFs |
| Symbols Nerd Font (a subset: `Icons.ttf`) | `src/retroui/fonts/Icons.ttf(.z)`, `LICENSE-NerdFonts.txt` | MIT and SIL Open Font License 1.1 | the icons |
| Handwriting fonts (Architects Daughter, Aref Ruqaa, Caveat, Gochi Hand, Indie Flower, Patrick Hand) | `src/retroui/fonts/hand/`, an `OFL-*.txt` beside each | SIL Open Font License 1.1 | the whiteboard's hand lettering |
| Natural Earth country outlines (through world-atlas) | `src/retroui/worlddata.nim`, `fonts/LICENSE-NaturalEarth.txt` | public domain (world-atlas: ISC) | the map view's world |
| uirelays | `src/retroui/uirelays/`, `LICENSE.md`, my changes in `RETRO.md` | MIT | the drivers' interface |
| SQLite | `src/retroui/vendor/sqlite/` | public domain | `retroui/db` |
| Monocypher (and its Ed25519) | `src/retroui/vendor/monocypher.c`, `monocypher-ed25519.c`, `LICENCE-Monocypher.md` | 2-clause BSD or CC0 | `retroui/vault`, the chat's end-to-end encryption, `retroui/update`'s signatures |

The font exception of FreeFont means a document or an app that embeds
the fonts is not covered by the GPL because of them; the fonts themselves
stay GPL (keep `LICENSE-FreeFont.txt` with them if you ship them as
files). Everything else above asks only that its notice goes with it:
put this file, or the license texts it names, with your app (its About
box, its folder, or its store listing's licenses page).

JPEG XL (`retroui/jxl`) is my own code written from the standard;
`src/retroui/vendor/LICENSE-jxl-references.txt` says what I read to write
it. Nothing of libjxl is in it.

## Carried by the tools (not in a desktop app)

| Part | Where | License |
|---|---|---|
| Android's headers and stub libraries (bionic, the NDK's platform headers, liblog) and LLVM's compiler-rt builtins, for APKs without the NDK | `tools/android/sysroot.tar.gz` (its `licenses/` folder has each NOTICE) | Apache 2.0, BSD; compiler-rt: Apache 2.0 with LLVM's exceptions |
| The Java activity in every APK | `tools/android/*.java`, built into `retroui/androiddex` | mine (MIT) |
| The C library of a web build | `src/retroui/web/libc` | mine (MIT) |

An APK links compiler-rt's builtins statically; LLVM's exception says
that needs no notice. The stub libraries are only linked against: the
phone's own libraries run.

## Fetched or run only when asked

- **Android NDK** (`retroapk --fetch-ndk`, or when nothing else can build
  an APK): Google's terms, shown on the NDK's page.
- **Blender** (`retroui/gltf`'s `blendToGlb`, `.blend` files): Blender is
  GPL; the kit runs it as a separate program to export glTF and reads the
  file it writes. Nothing of Blender is linked into an app.
- **Map tiles and the places and routes services** (`retroui/tilemap`,
  `retroui/geo`): each service's own terms. OpenStreetMap's tiles and
  Nominatim ask for "© OpenStreetMap contributors" on the map (the map
  shows each source's `attribution`) and forbid bulk downloads (`keepArea`
  refuses them); Google, Mapbox, HERE, Azure Maps, TomTom, MapTiler,
  Stadia, Esri, Amap, Tencent and Tianditu need your own key and your
  agreement with them.
- **Google Fonts** (`retroui/googlefonts`, when an app downloads a family):
  each family's license (mostly SIL Open Font License 1.1), saved with it.

## Reached on the system, not carried

X11, Wayland, the Linux framebuffer and DRM, D-Bus and AT-SPI, fontconfig
and FreeType, WebKitGTK and GStreamer, PulseAudio, curl (a program the
kit runs for downloads);
Windows' own libraries (WinAPI, Direct2D, Media Foundation, WebView2,
UI Automation); Apple's frameworks (Cocoa, UIKit, AVFoundation, WebKit);
Android's (the NDK's system libraries, WebView, MediaSession). The kit
opens them while it runs; they are the system's, under the system's
licenses, and an app does not ship them.
