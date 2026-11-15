# Contributing to Retro Nim UI

Thanks for helping. A few things keep the toolkit what it is:

- **Into the toolkit first.** A feature an app needs goes into `src/retro`
  (a widget, a service, an engine call) and the app uses it; the examples
  are thin.
- **1994 in the look, today in the behavior.** Windows 3.1 / 98 visuals --
  bevels, dithers, pixel icons, the System and MS Sans Serif type -- with
  what people expect now: touch, HD and 4K, dark themes, keyboard and mouse
  everywhere, screen readers' basics.
- **No dependencies.** Nim and a C compiler; the platform's own libraries are
  loaded at run time. Fonts, icons and codecs are in the tree.
- **Documented.** Every module starts with a `##` header and every exported
  proc, type and template has a `##` comment (`nimble docs` builds the
  reference from them). Write them short and plain.
- **Tested.** `nimble test` runs the headless tests (a fake screen driver;
  no display needed); add one for what you change. `nimble fuzz` feeds the
  decoders damaged files.

## Layout

| Folder | What is there |
|---|---|
| `src/retroui.nim` | the package: `import retroui` brings everything |
| `src/retroui/` | the modules (see the table at the top of `retro.nim`) |
| `src/retroui/uirelays/` | the screen drivers: X11, Win32, Cocoa, Android, iOS -- the `uirelays` branch's code (`tools/uirelays.sh`, `RETRO.md` there) |
| `src/retroapk.nim`, `src/retroios.nim`, `src/retrokit.nim` | the APK and iOS builders, the helper |
| `examples/` | the apps: gallery, Retro Files, Retro Atelier, Ledger, Notepad, Charts... |
| `tests/` | the tests, the fuzzers, benchmarks |
| `tools/` | maintainers' generators (fonts, icons, world data) and the screenshot tool |
| `docs/` | the controls reference and screenshots; `docs/api` is generated |

## Before a pull request

```sh
nimble test          # all green
nimble fuzz          # no crash
nimble docs          # the reference builds without warnings
```

Commit messages: what changed and why, in a sentence or two.
