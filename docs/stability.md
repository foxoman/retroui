# What stays the same: the API before 1.0

Retro Nim UI is not 1.0 yet. Until it is, a minor version (0.30, 0.31...)
may change an API -- but not silently, and not the parts most apps are
made of. This page says which parts are settled, which are still
moving, and how a change reaches you.

## Settled: kept as they are

What almost every app uses. These keep their names, their parameters and
what they do; a new parameter comes with a default, so code that
compiled still compiles.

| Module | What |
|---|---|
| `core` | `app`, the frame loop, `row` / `col` / `place`, `ui.*` you read, `wakeIn`, `quitApp`, themes, scale |
| `widgets` | `label`, `button`, `edit`, `checkbox`, `radio`, `listbox`, `combo`, the menus, `tabs`, `msgBox`, `toast`, `progress`, `slider` |
| `business` | `grid` and its columns, `tree`, `datePicker`, `numberEdit`, `inputBox`, `progressBox`, `Date` and its procs, `fileDialog` |
| `files`, `filewidgets` | the folder model, `filePicker`, file jobs |
| `imaging` | `Bitmap`, `decodePng` / `decodeJpeg`, `encodePng` / `encodeJpeg`, `loadPicture` |
| `platform`, `uirelays/services` | `openUrl`, `openFile`, `places`, the clipboard, `dataDir` |
| `charts`, `report`, `pdf` | the chart kinds, reports, `printPdf` |
| `http`, `db`, `secrets` | `httpRequest`, `openDb` / `exec` / `rows`, `saveSecret` / `loadSecret` |
| `uirelays` | the relays a driver fills (a new relay is optional: drivers without it keep working) |
| tools | `retrokit new / run / web / apk / small`, `retroapk`'s options |

## Still moving

Newer, or still finding their shape: they may be renamed or change
their parameters in a minor version.

| Module | Why |
|---|---|
| `system` | new in 0.30: the calls may still be gathered differently |
| `update` | new in 0.30 (the update file's fields are settled; the procs may grow options) |
| `capture`, `mediasession` | the camera's and the media keys' events may gain fields |
| `view3d`, `gltf`, `tilemap`, `geo`, `mvt` | the 3D view and the maps grow with each release |
| `photo*`, `dock`, `toolcustom` | Retro Photo's parts, shared with apps as they settle |
| `xmpp`, `omemo`, `mime`, `mailimport`, `richedit`, `spell` | Retro Mail and the communicator's parts |
| `designer` and the designer's file format | Retro Designer is young |
| the web build (`retroweb` options, `Retro.boot` options) | the page's side grows with the browsers |

## How a change reaches you

- **CHANGELOG.md** names every change to a public proc, type or option,
  under the version that makes it, with what to write instead.
- **Deprecated before removed**: a settled proc that goes is first marked
  `{.deprecated: "use X".}` for at least one minor version (the compiler
  says so where you call it), then removed.
- **A changed meaning** (same name, different behaviour) is never done to
  a settled proc: it gets a new name.
- **Files the kit writes** (settings, thumbnail caches, the database's
  tables of Retro Mail, saved documents) are read by later versions; a
  format that changes carries its version and is converted on reading.

## After 1.0

Semantic versioning: 1.x keeps every settled and every moving part that
1.0 has (a moving part that is not ready stays out of 1.0, or is marked
experimental in its documentation); anything that breaks waits for 2.0.
