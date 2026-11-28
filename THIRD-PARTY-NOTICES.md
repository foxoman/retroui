# Third-party notices

Retro Nim UI is mine and MIT licensed (`LICENSE`). A few parts of it come
from others, under their own licenses; this file lists each one, where it
is, what an app made with the kit carries, and what you need to do when
you ship one. Every license text is in the repository beside the part.

## Carried in apps (only when the app uses the part)

| Part | Where | License | What it is for |
|---|---|---|---|
| Suhar App and Suhar App Read 2.800 (my own typeface, four styles each; Sultan Al Isaiee, The Suhar Project Authors) | `src/retroui/fonts/SuharApp*.ttf(.z)`, `LICENSE-Suhar.txt` | SIL Open Font License 1.1 | the text of every app: the UI's (Suhar App), paragraphs (Suhar App Read) |
| GNU FreeFont (FreeSans, FreeSerif, FreeMono, four styles each; subsets) | `src/retroui/fonts/Free*.ttf(.z)`, `LICENSE-FreeFont.txt` | GPL 3 with the font exception | the text of every app, PDFs |
| Symbols Nerd Font (a subset: `Icons.ttf`) | `src/retroui/fonts/Icons.ttf(.z)`, `LICENSE-NerdFonts.txt` | MIT and SIL Open Font License 1.1 | the icons |
| Dastkhat 1.210 (Dastyar; derived from Vazirmatn, Saber Rastikerdar and the Vazirmatn Project Authors; its Latin from Roboto, Google LLC) | `src/retroui/fonts/dastkhat/Dastkhat-Variable.ttf.z` (the variable font as published, packed), `OFL-Dastkhat.txt`, `NOTICES-Dastkhat.txt` | SIL Open Font License 1.1 (Roboto's Latin: Apache License 2.0) | `retroui/dastkhat`: Retro Atelier's type -- Arabic, Persian and Latin in nine weights |
| Scheherazade New 4.500, Lateef 4.400 (SIL Global, with Reserved Font Names "Scheherazade", "Lateef" and "SIL"), Markazi Text 1.000 (the Markazi Text Project Authors), Regular and Bold each | `src/retroui/fonts/arabic/*.ttf.z` (the fonts as published, packed), `OFL-ScheherazadeNew.txt`, `OFL-Lateef.txt`, `OFL-MarkaziText.txt` | SIL Open Font License 1.1 | `retroui/arabicfonts`: Retro Atelier's Arabic book and text faces (Persian, Urdu, Pashto, Sindhi too) |
| Handwriting fonts (Architects Daughter, Aref Ruqaa, Caveat, Gochi Hand, Indie Flower, Patrick Hand) | `src/retroui/fonts/hand/`, an `OFL-*.txt` beside each | SIL Open Font License 1.1 | the whiteboard's hand lettering |
| Natural Earth country outlines (through world-atlas) | `src/retroui/worlddata.nim`, `fonts/LICENSE-NaturalEarth.txt` | public domain (world-atlas: ISC) | the map view's world |
| uirelays | `src/retroui/uirelays/`, `LICENSE.md`, my changes in `RETRO.md` | MIT | the drivers' interface |
| SQLite | `src/retroui/vendor/sqlite/` | public domain | `retroui/db` |
| Monocypher (and its Ed25519) | `src/retroui/vendor/monocypher.c`, `monocypher-ed25519.c`, `LICENCE-Monocypher.md` | 2-clause BSD or CC0 | `retroui/vault`, the chat's end-to-end encryption, `retroui/update`'s signatures, an encrypted database (`retroui/db`, `cryptvfs.c`), mail's Ed25519 DKIM signatures (`retroui/mailauth`) |
| The Public Suffix List (Mozilla Foundation and its contributors) | `src/retroui/vendor/public_suffix_list.dat` (its notice at its top; its comments left out) and the same packed, `public_suffix_list.dat.z` | Mozilla Public License 2.0 | `retroui/domains`: the part of a name someone registered (who a message is from, links that are not what they say) |
| Unicode's confusable characters (UTS #39, `confusables.txt`, version 18.0.0) | `src/retroui/vendor/confusables-ascii.txt` (only those that look like ASCII letters and digits; its notice at its top) | Unicode License v3 | `retroui/domains`: names made to look like other names |
| Hyphenation patterns for American English (Gerard D. C. Kuiken, from hyph-utf8) | `src/retroui/vendor/hyph-en-us.tex` (its notice at its top) | permissive: copying and changing it allowed, its copyright notice and this notice kept | `retroui/hyphenate`: English words broken at a line's end |
| Hyphenation patterns for French (Daniel Flipo, Bernard Gaulle, Arthur Reutenauer), German's reformed spelling, 2006 (the German-speaking Trennmuster team: Stephan Hennig, Werner Lemberg and others), Spanish (Javier Bezos, CervanTeX), Italian (Claudio Beccari), Portuguese (Pedro J. de Rezende, J. Joao Dias Almeida, Leonardo Araujo, Aline Benevides) and Dutch (Piet Tutelaers), from hyph-utf8 | `src/retroui/vendor/hyph-fr.tex`, `hyph-de-1996.tex`, `hyph-es.tex`, `hyph-it.tex`, `hyph-pt.tex`, `hyph-nl.tex` (each its notice at its top) | MIT (French, German, Spanish, Dutch), MIT or LPPL 1.3 (Italian), 3-clause BSD (Portuguese) | `retroui/hyphenate`: words broken in their language |
| The Umm al-Qura calendar's month starts (Mohammed Alshehri's hijridate package) | the table in `src/retroui/hijri.nim`, `src/retroui/vendor/LICENSE-hijridate.txt` | MIT | `retroui/hijri`: Hijri dates, the Text Variables' `<hijri>` |
| Google Fonts' list of families (their names, kinds and whether they have Arabic letters: Google Fonts' developer API, as the google-font-metadata package keeps it) | `src/retroui/googlefontlist.txt` (made by `tools/gengooglefonts.py`) | facts, no font in it (google-font-metadata: MIT) | `retroui/googlefonts`: `googleFontCatalog`, Retro Atelier's Get Google Fonts -- each font fetched comes with its own license (OFL, Apache 2.0, UFL) in Google's repository |

The font exception of FreeFont means a document or an app that embeds
the fonts is not covered by the GPL because of them; the fonts themselves
stay GPL (keep `LICENSE-FreeFont.txt` with them if you ship them as
files). Everything else above asks only that its notice goes with it:
put this file, or the license texts it names, with your app (its About
box, its folder, or its store listing's licenses page). The Public Suffix
List is under the Mozilla Public License 2.0: the file stays under it (its
source is publicsuffix.org's own list), and the program that carries it is
not affected.

The DKIM test messages (`tests/data/dkim/`) are RFC 8463's own example
(the IETF Trust's, with its keys published in the RFC) and messages signed
for the tests with keys made for them and thrown away.

The shaper (`retroui/otshape`) is my own code, tested against HarfBuzz's
output run by run. Its Arabic fallback and its fallback mark positioning
follow HarfBuzz's (`hb-ot-shaper-arabic-fallback.hh`,
`hb-ot-shape-fallback.cc`), and the ligature tables in it are HarfBuzz's
(`hb-ot-shaper-arabic-table.hh`, made from Unicode's data), as are the
lookups for the Arabic fonts encoded as Windows-1256
(`hb-ot-shaper-arabic-win1256.hh`, in `retroui/otshape`) and the map of
the private-use codes of Simplified and Traditional Arabic
(`hb-ot-shaper-arabic-pua.hh`, in `retroui/ttf`): HarfBuzz is
under the "Old MIT" license -- Copyright © 2010-2022 Google, Inc.; ©
2006-2012 Behdad Esfahbod and others -- which asks that this notice go
with copies: permission to use, copy, modify and distribute it is granted,
without fee, provided the copyright notice and these paragraphs appear in
all copies; it is provided "as is", without warranty.

Unicode's conformance tests for the bidi algorithm (`tests/data/unicode/
BidiTest.txt.z`, `BidiCharacterTest.txt.z`, version 18.0.0, packed) are
Unicode's, under the Unicode License v3 (`LICENSE-Unicode.txt` beside
them); `tests/test_bidi.nim` runs every line of them. They are never
carried in an app.

The tests' fonts made from FreeSerif and FreeMono (`tests/data/fonts/
ArabicNoLayout-Test.*`, `ArabicLegacy-Test.ttf`, `HebrewThaiNoLayout-Test.ttf`, `OldBitmap-Test.fon`,
`OldType1-Test.pfb`, `OldSymbol-Test.pfb`: `tools/genlegacy.py`,
`tools/genoldfonts.py`) are FreeFont's, GPL 3 with the font exception;
they are never carried in an app. `SuharNoForms-Test.ttf`, `SuharMarks-Test.ttf` and
`SuharMarksNoLayout-Test.ttf` (`tools/gensuhartestfonts.py`) are cut from Suhar App, and
`SuharVar-Test.ttf` from Suhar's variable font, SIL Open Font License 1.1 (`Suhar-OFL.txt`). `Win1256-Test.ttf` and
`ArabicPua-Test.ttf` (plain boxes, `tools/genlegacy.py`) are made for the
tests, public domain.

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
- **The Quran's text** (`retroui/quran`; Retro Atelier's Type > Quran...,
  when the user downloads it): Tanzil's Quran text (tanzil.net), under
  its terms -- copied verbatim, never changed, tanzil.net named as its
  source. It is never carried in an app or the repository; the file is
  kept as Tanzil gives it, its notice with it.
- **Google Fonts** (`retroui/googlefonts`, when an app downloads a family):
  each family's license (mostly SIL Open Font License 1.1), saved with it.
- **Language models** (`retroui/modelstore`, when the user downloads one;
  never carried in an app or the repository): BitNet b1.58 2B 4T
  (Microsoft, MIT License), Qwen3 1.7B and Qwen3 Embedding 0.6B (Alibaba's
  Qwen team, Apache License 2.0), from their makers' pages on Hugging Face;
  the store shows each one's license before it is downloaded. The code
  that runs them (`retroui/llm`, `retroui/gguf`, `retroui/llmtokens`,
  `simdllm.h`) is the kit's own: it reads the GGUF format and the layouts
  of the weights as llama.cpp and bitnet.cpp (both MIT) describe them, and
  copies no code of theirs.
- **Models of pictures** (`retroui/modelstore`, when the user downloads
  one; never carried in an app or the repository): Depth Anything V2 Small
  (Apache License 2.0; the ONNX file as fabio-sim's Depth-Anything-ONNX
  releases it, Apache 2.0), U-2-Net and its small one (Xuebin Qin and
  others, Apache License 2.0; the ONNX files as rembg releases them, MIT),
  PaddleOCR's PP-OCRv3 detector and readers (Baidu, Apache License 2.0;
  as RapidOCR packs them on PyPI, Apache 2.0, and as monkt's
  paddleocr-onnx has the Arabic one, Apache 2.0). The Arabic reader's
  characters (`arabicChars` in `retroui/vision`) are its dictionary's,
  from PaddleOCR (Apache License 2.0). The code that runs them
  (`retroui/onnx`, `retroui/nnet`, `simdnet.h`, `retroui/vision`) is the
  kit's own: it reads the ONNX format as its specification describes it
  and follows the models' published pre- and post-processing (DB's boxes,
  CTC), and copies no code of onnxruntime's or PaddleOCR's.
- **The test graphs' generator** (`tools/gennet.py`, run only to make
  `tests/data/nnet` again) and `tools/netcheck.py`: numpy (BSD), onnx and
  onnxruntime (MIT), installed by whoever runs them.
- **The test models' generator** (`tools/genllm.py`, run only to make
  `tests/data/llm` again): numpy (BSD), gguf-py (MIT) and Hugging Face's
  `tokenizers` (Apache 2.0), installed by whoever runs it.

## Reached on the system, not carried

X11, Wayland, the Linux framebuffer and DRM, D-Bus and AT-SPI, fontconfig
and FreeType, WebKitGTK and GStreamer, PulseAudio, curl (a program the
kit runs for downloads);
Windows' own libraries (WinAPI, Direct2D, Media Foundation, WebView2,
UI Automation); Apple's frameworks (Cocoa, UIKit, AVFoundation, WebKit);
Android's (the NDK's system libraries, WebView, MediaSession). The kit
opens them while it runs; they are the system's, under the system's
licenses, and an app does not ship them.
