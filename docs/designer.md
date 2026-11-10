# Retro Designer

Retro Designer is the visual designer of Retro Nim UI. It opens an ordinary
`.nim` file -- the one you build and run -- and shows its windows drawn with
the real controls. You drop controls from the Widget Box, drag them where
they go, put them in rows and groups, set their properties and add their
events, and every change is written into the same file as Nim, touching only
the lines that changed. There is no form file and no generated code to keep
beside your own, and no code editor: when you want to write what a button
does, your editor opens at that line, and the designer takes the file back
when you close it.

![Retro Designer: a menu of Ledger opened and its item chosen](designer/menu.png)

```sh
retrokit designer app.nim       # opens app.nim (a new one when there is none)
retrokit designer               # a new window to design
retrokit designer --rebuild     # builds the designer again first
```

## Getting it

Retro Designer comes with Retro Nim UI: `nimble install retroui` installs
its sources beside the toolkit's, and `retrokit designer` builds it the first
time you run it -- for this computer, with this Nim -- into the toolkit's
cache folder (`~/.cache/retroui` on Linux, `%LOCALAPPDATA%\retroui` on
Windows, `~/Library/Caches/retroui` on macOS). That takes a minute or two
once; after that it starts at once. A new version of Retro Nim UI, or a
change to its sources, builds it again by itself.

It reads your files with Nim's own parser, so it needs the Nim compiler's
sources; `retrokit` checks that the parser builds from them before it builds
the designer. A Nim installed from nim-lang.org, choosenim, Homebrew or a
Linux package has them beside its `lib` folder; when yours does not,
`retrokit` installs nimble's `compiler` package (`nimble install compiler`)
and uses that. Since Nim 2.4 the compiler's sources also import two folders
of Nim's `dist` (nimony and checksums), which some packages leave out --
Termux's among them: `retrokit` then makes a copy of the sources in its
cache folder (`nim-2.4.0` there) with what your Nim has of those folders, and
fetches the rest with git (`pkg install git` in Termux), at the commits your
Nim's version pins, once. `retrokit doctor`
says which of these your Nim needs.

It runs where Retro Nim UI runs on a desktop: Windows, macOS, Linux and BSD
(X11), and Termux on Android with Termux:X11.

## The window

![Designing Hello: a button chosen, its properties at the right](designer/hello.png)

- **The Widget Box** (left): every control of the kit, by the parts of the
  [controls guide](controls.md), with a box to find one by name. Click one,
  then click on the window where it goes -- or drag it there. What it needs
  comes with it: its variables (named so that they are new in your file)
  and the modules it uses (`import retroui/richedit`, `import std/os`).
- **The window being designed** (middle): the file's window in its 3.1
  frame. The **Page** list has every window of the file and, under each
  one, its dialogs; **Look** shows it on a touch screen, in the dark
  scheme, or right to left. Drag the frame's corner to change the window's
  size (the numbers of `app "Title", 480, 320:` change).
- **The Object Tree** (top right): what the window has, in the order of
  the file -- rows, groups, the controls in them, `if` and `case` with their
  arms. `*` marks a control with an event, `~` code the designer shows
  without changing (a loop, a call of one of your procs).
- **Properties, Events, Variables** (bottom right): the chosen control's
  parameters; its event; the file's variables.

## What a window is

The designer finds the windows of a file by themselves:

- an `app "Title", w, h:` block,
- a window opened by hand: `openApp(...)` and its `while beginFrame():` loop,
- every proc that draws controls (`proc invoicesPage() =`): each one is a
  page of its own, and where a window calls it, its controls are drawn
  there. A proc of menu items (the content of a menu, kept apart) is shown
  as that menu, open.

A **dialog** (`dialog`, `wizard`) is listed under its window in the Page
list. Choose it, or one of its controls in the Object Tree, and it is shown
open over its window, as it will be; choose something of the window and it
closes again.

![The invoice dialog of Ledger designed over its window](designer/dialog.png)

A **menu** is the same: choose a menu, a menu item or a submenu (in the tree,
or click the menu's title on the window) and the menu opens with it; click
its items to choose them.

**Tabs and branches.** What a `case` or an `if` draws depends on your
variables. The designer draws the arm that holds while you design (with the
values your `var` lines start with), and the arm of whatever you choose: a
control on the third tab shows the third tab. Choosing an arm in the Object
Tree shows that arm.

## Designing

| | |
|---|---|
| Add a control | choose it in the Widget Box, click on the window (Ctrl+click: add more of it); or drag it there |
| Choose | click it; Ctrl+click adds to what is chosen; Esc chooses the container it is in |
| Move | drag it (a line shows where it goes, in a row, a group, a tab); Alt+Up, Alt+Down |
| Put in a row, a group | choose controls side by side, then Ctrl+R (a row) or Ctrl+G (a group); Layout also puts them in a column, a panel, a card or a form |
| Take out of a container | Layout > Take Out of Its Container: its controls go where it was |
| Cut, copy, paste, duplicate | Ctrl+X, Ctrl+C, Ctrl+V, Ctrl+D: the controls as Nim, pasted after what is chosen |
| Delete | Del (the last control of a body leaves a `discard`) |
| Undo, redo | Ctrl+Z, Ctrl+Y (Ctrl+Shift+Z) |
| Save | Ctrl+S |
| Preview | F5 |
| Your code | Enter, or a double click: the control's event added; on one that has it, your editor at its code |

Every change is checked before it is made: a change that would leave the file
not reading as Nim is not made (the status bar says why).

### Properties

The chosen control's parameters, under its name. A value written out in the
file -- a text, a number, a check, a color, one of an enum's values, a list
-- is shown and changed here (one of the kit's pictures or symbols by name,
`pxOpen` or `nfSave`, is chosen from the list of them); what your code
works out is shown as code
(`= dateStyle == dsMDY`) and stays yours (type a new value to replace it).
A parameter the control changes (`edit name`: a `var`) takes a variable's
name; a name the file does not have yet becomes a new `var` at the top.
**Reset** takes the parameter out of the call: the control's default again.

### Events

A control that tells you it was used -- a button clicked, a box changed, a
menu item chosen -- has an event: the code under it. **Add the Clicked
Event** makes the control's line

```nim
if button("&Save"):
  discard
```

and **Edit Code** opens your editor at the `discard`.

### Variables

The file's variables and what they start with; change a value here and the
`var` line changes. **Rename** renames a variable everywhere it is used --
not a field or an argument of the same name, and not inside a proc that has
its own of that name.

### Names and the keyboard

**View > Names and Tab Order** shows on the window what a screen reader --
and the kit's driver, which finds controls the same way (`RETRO_DRIVE`,
`retrokit drive`) -- knows of it: each stop of Tab numbered in the order Tab
goes, and the controls it cannot name outlined in red: a box with no label
before it, a button with only an icon and no tooltip. Choose a control and
Properties says how it is read (`Read as: button "Save"`). One without a
name has **Name It...**: the name you give it is written before it as
`accessName "..."`. One with a name has **Driver Command**: the command
that clicks it (`click "Save" --role button`) copied, for
`retrokit drive PORT ...` while the app runs with `RETRO_DRIVE=PORT`.

## Preview

F5 shows the window as it will be: its controls work -- type in the boxes,
open the menus, switch the tabs -- and the Look list tries it on a touch
screen, dark, or right to left. Its code does not run: the preview is of
the window, not of the app (run the app with `retrokit run --watch app.nim`
beside the designer to see both). Esc or F5 ends it.

![The preview of Ledger, dark, its View menu open](designer/preview.png)

## The file and your editor

The designer and your editor never change the file at the same time. While
the designer has it:

- it writes a lock beside it, `.app.nim.lock` (who has it, since when);
- the file is kept from other programs: read-only on Linux, macOS, BSD and
  Termux (most editors say so when they open it), held open so that no one
  else may write it on Windows;
- a second designer opening it shows it and does not change it.

**Edit Code** saves the file, lets it go (the lock goes, the file is
writable again) and opens your editor at the line. The designer waits;
when you close the editor it takes the file back, reads it again with what
you wrote, and you go on designing. Undo goes back past the editor's
changes too.

The editor is set in **Edit > Settings**: a command where `{file}` and
`{line}` are put in, as `code --wait -g {file}:{line}` or `kate --block
--line {line} {file}`. Without one the designer finds one by itself: ned in a
terminal window when it is installed, else `$VISUAL` or `$EDITOR`
(a terminal editor -- vim, nano, helix, micro -- in a terminal window),
else VS Code, else Notepad on Windows, TextEdit on macOS, nano in a
terminal on Linux. A GUI editor must wait until its window is closed (VS
Code's `--wait`, Kate's `--block`, `gedit --wait`, `open -W`), or the
designer takes the file back at once.

A designer that ends (closed, the session logged out, killed) puts the file
back as it was: its rights, and no lock. One that crashed leaves its lock;
the next designer to open the file sees that it is gone and takes it over.

## What the designer draws

The designer does not run your app. It reads the file and calls each control
with what is written there:

- a value written out is used as it is; your variables start with the value
  of their `var` lines (and a call it cannot work out, like
  `settings.getInt("width", 170)`, with its default: 170);
- what only your code works out is left to the control's default;
- a `for` over a list written out (`for s in ["Classic", "Gray"]:`) or a
  range (`for z in 0 .. 3:`) draws its controls for each value; over
  anything else, once;
- a control that needs data only your code has (a grid's cells, a chart's
  series from a file) is drawn as a dashed box with its name, where it goes
  and as large as it will be;
- a control drawn as nothing (a label of an empty text) is shown as a
  dotted place, so that you see it and can choose it (not in the preview);
- a `webView` is drawn by the kit's own engine, whatever its `engine` or
  `RETRO_WEB` say: local pages and `html:` text as the kit draws them, a
  page on the web as its address (the system's browser would be a window
  of its own over the designer), and the web view's commands (`webRun`,
  `webPost`, `webGoBack`...) do nothing;
- what is not a control -- your code between them -- stays as it is and is
  never changed.

## For developers

- `src/retrodesigner/`: `source.nim` reads the file with Nim's parser
  (`compiler/parser`) and makes every change as an edit of the text at the
  nodes' places -- your comments, blank lines and style stay -- each change
  read again before it is kept; `model.nim` finds the pages and what is on
  them; `evaluate.nim` draws a page with the real controls inside a
  `windowBox`, `inert`, keeping where each item went (`ui.measuring`,
  `notePlaced`); `lock.nim` the hold on the file and the editor;
  `retrodesigner.nim` the window.
- `src/retrodesigner/registry.nim` -- what the designer knows of the
  controls: their parameters and a call for each, the layout templates with
  bodies, enums and constants, and the Widget Box (the guide's examples
  from `tools/shots.nim`) -- is made by `python3 tools/gendesigner.py`, which
  reads the API with `nim jsondoc` and leaves out what does not compile. Run
  it after adding or changing a control.
- The toolkit's parts it stands on are public: `windowBox` (a window drawn
  in a rectangle of this one), `inert` (drawn without input, its dialogs
  and menus not taking the window's), `showMenu` / `hideMenu`,
  `ui.measuring` and `notePlaced`, `peekId`.
- `tests/test_designer.nim` reads and draws every example app, deletes
  each of their controls, drops every control of the Widget Box into one app
  and compiles it, and makes each kind of change.
