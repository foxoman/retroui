# Security

Retro Nim UI reads files people open, pages and mail from the network,
pictures, models, maps, archives; it signs the packages apps ship in. I
take a hole in any of that seriously, and I would rather hear about it
early from you than late from someone who used it.

## Telling me about a problem

Write to me at **sultan@foxoman.net** with "security" in the subject. Do
not open a public issue for it. Please send:

- the version (`retroui.nimble`, or `RetroVersion` in an app) and the system
- what goes wrong, and what someone could do with it
- the smallest file, page or program that shows it, if you have one

I answer every report, say what I found, and tell you when a fix is out.
When a release fixes a security problem, the CHANGELOG says so in its
first lines, and I thank you there by name unless you would rather not.

## Versions

I fix security problems in the newest release. Until 1.0 every release
can change what an app calls, so the fix comes in the next version, not
in a patch of an older one; the CHANGELOG says what to change, if
anything.

## What the kit does to be safe

The README's "Safety" section has the whole list; in short:

- **Every reader checks what it reads.** Pictures (PNG, JPEG, GIF, WebP,
  JPEG XL, PSD, camera raw, EXR), fonts, PDF, zip archives (ZIP64
  too), mail, HTML and Markdown, CSV and spreadsheets, 3D models (OBJ, STL,
  glTF), vector tiles and tile archives, the map services' answers,
  certificates and the programs it signs: a damaged or hostile file is
  refused with an error, never a crash. Sizes have limits (a "zip bomb"
  stops at what its directory says; pictures over 120 million pixels are
  refused), and names that would climb out of a folder are refused.
- **Fuzzed and checked for memory faults.** `nimble fuzz` feeds hundreds
  of thousands of damaged inputs to every reader and random input to the
  widgets; the decoders run under libFuzzer every night; the tests also
  run under AddressSanitizer, UBSan and LeakSanitizer, as 32-bit programs
  (an `int` as small as WebAssembly's) and as WebAssembly, so a number
  that only fits in 64 bits is caught.
- **Pages do not run code.** The kit's own HTML view has no scripts and
  never reaches the network. The system's web view (`webView`) is the
  system's browser engine, with its own protections; an app decides what
  it opens.
- **Secrets stay the user's.** `retroui/secrets` keeps tokens in the
  system's keychain (DPAPI on Windows, the keychain on macOS, the desktop
  keyring on Linux), or encrypted (XChaCha20-Poly1305) in a file only
  that user can read; a web page seals them (AES-GCM) with a WebCrypto key
  the browser keeps and never hands out.
- **Updates come only from you.** `retroui/update` takes an update only
  when its file is signed (Ed25519) by the key whose public half is built
  into the app, and only a download whose SHA-256 is the signed one.
- **Network.** `retroui/http` goes through the system's own HTTP and TLS
  (WinHTTP on Windows, libcurl on Linux, macOS and the BSDs, Java's on
  Android, the browser's in a web page), which check certificates;
  nothing in the kit turns that off.
- **Files written safely.** Settings, documents and pictures are written
  to a temporary file and moved into place.

## Signing keys

`retroapk`, `retrokit sign` and `retrokit msix` sign in Nim (`retrokit
mac` signs ad hoc, with no key, or calls `codesign` with yours). Without
your own key they make a **test** key once, in `~/.retro/android` and
`~/.retro/windows` (or `$RETRO_KEYS`): fine to try a build, never to
publish with. For a store, use your own: Google Play's
upload key, a code signing certificate from an authority (Windows), your
Developer ID (macOS, through `codesign` on a Mac). Keep the key files out
of your repository and your app's folder; the kit never writes a key
anywhere but where you tell it, and never sends one anywhere. Stamp
Windows signatures with the time (`--timestamp:URL`) so they stay good
after the certificate expires.

The key that signs updates (`retrokit update-key`: `update-key.secret`)
is yours alone: anyone with it can ship to your users. Keep it out of the
repository (`.gitignore` has `*.secret`) and give it to CI as a secret
(`RETRO_UPDATE_KEY`).
