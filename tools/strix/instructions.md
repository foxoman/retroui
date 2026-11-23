# What Strix checks in Retro Nim UI

Retro Nim UI is a desktop, phone and web UI kit in Nim (`src/retroui`) with
its tools (`src/retrokit.nim`, `src/retroapk.nim`, `src/retroweb.nim`) and the
apps in `examples/`. It is not a web service: look for what a file, a page,
a message or a program on the same computer can make an app do.

Report only what you can show with a proof of concept against this code.
Leave out the bundled third-party sources (`src/retroui/vendor`,
`src/retroui/uirelays/drivers/*/vendor`) and the test data (`tests/fuzz/seeds`).

## Where to look first

- **Files a user opens** (they come from anywhere): the decoders and parsers
  -- PSD, TIFF, PNG, JPEG, WebP, GIF, EXR, raw photos (`src/retroui/photo*.nim`,
  `imageformats.nim`, `psd.nim`, `rawphoto.nim`, `cr3.nim`, `exr.nim`), fonts
  (`ttf.nim`, `cff.nim`, `fontconv.nim`), PDF (`pdfread*.nim`), SVG
  (`svgimport.nim`), IDML (`idml.nim`), glTF and .blend (`gltf.nim`), XLSX,
  ZIP and 7z (`zip.nim`, `lzma.nim`). Memory safety, endless loops, huge
  allocations, and paths in an archive that leave the folder it is unpacked
  into (`..`, absolute paths, links).
- **The automation endpoint** (`src/retroui/drive.nim`, `RETRO_DRIVE=PORT`)
  and the MCP server over it (`src/retroui/mcpserver.nim`, `retrokit mcp`):
  they must listen on 127.0.0.1 only, and take nothing a page in a browser
  can send (DNS rebinding, a cross-site POST).
- **Web pages inside an app** (`webView` in `src/retroui/htmlview.nim`, `webbind.nim`): what
  a page can call of the app through `webBind`, and whether it can reach
  files or the app's other pages.
- **HTML mail** (`src/retroui/htmlview.nim`, `mailsafety.nim`, `mailauth.nim`,
  `examples/mail`): scripts, remote pictures loaded without asking, links
  that hide where they go, a sender that is not who it says.
- **The network** (`src/retroui/http.nim`, `fetch.nim`, `oauth.nim`): TLS
  checked, redirects to other schemes, tokens kept out of logs and URLs.
- **Secrets and updates** (`src/retroui/secrets.nim`, `update.nim`,
  `sign.nim`): keys in the system's keyring, an update applied only when its
  signature is good, no downgrade.
- **The web build** (`src/retroweb.nim`, `src/retroui/web/`): `retrokit run
  --web` serves on 127.0.0.1; the page's service worker and what it caches.
- **Retro DNS** (`examples/retrodns.nim`): a DNS server on the user's
  machine -- what a packet from the network can do to it.
- **Command lines built from user input** (`osproc` calls in the kit and the
  tools): arguments passed as a list, never through a shell.

## How to build and run

Nim 2.4 and a C compiler: `nim c -d:release examples/APP.nim`. The tests run
headless: `nim c -r tests/test_NAME.nim` (a fake screen driver, no window).
`tests/fuzz/fuzz.nim` feeds damaged files to the decoders.
