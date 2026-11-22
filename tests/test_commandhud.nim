## Tests of retroui/commandhud, the command search, in a window with menus: its keys open it, the
## menus are walked (submenus too) and not drawn, what is typed finds the command -- a few
## letters of each word, the one chosen lately first --, Enter does it as its menu would, a
## command that cannot be chosen now is listed and not done, Esc closes it.

import std/strutils
import retroui, retroui/headless
import retroui/uirelays/input

useHeadless(640, 480)
startApp("Commands", 640, 480)
var clock = 1000
inputRelays.getTicks = proc (): int = clock

var did: seq[string]
var canPaste = false
proc frame() =
  clock += 16
  discard beginFrame()
  menubar:
    menu "&File":
      if menuItem("&New", "Ctrl+N"): did.add "new"
      if menuItem("Save &As...", "Ctrl+Shift+S"): did.add "save as"
      menuSeparator()
      if menuItem("E&xit"): did.add "exit"
    menu "&Edit":
      if menuItem("&Paste", "Ctrl+V", enabled = canPaste): did.add "paste"
      submenu "&Transform":
        if menuItem("&Rotate 90°"): did.add "rotate"
        if menuItem("&Flip Horizontal"): did.add "flip"
  label "a window with menus"
  endFrame()

proc key(k: KeyCode; mods: set[Modifier] = {}) =
  headlessInput(Event(kind: KeyDownEvent, key: k, mods: mods, hasMods: true))
  frame()
  headlessInput(Event(kind: KeyUpEvent, key: k, mods: {}, hasMods: true))
  frame()

proc typeText(s: string) =
  ## (as a keyboard: a key press, then the character)
  for c in s:
    headlessInput(Event(kind: KeyDownEvent, key: KeyNone, hasMods: true))
    var e = Event(kind: TextInputEvent)
    e.text[0] = c
    headlessInput(e)
    frame()
  frame()

var passed = 0
template check(cond: bool; what: string) =
  doAssert cond, what & " (did: " & $did & ")"
  inc passed
  echo "  ok   ", what

frame()
check not commandHudOpen(), "closed at first"
key(KeyP, {CtrlPressed, ShiftPressed})
check commandHudOpen(), "Ctrl+Shift+P opens it"
frame()
var paths: seq[string]
for c in menuWalked: paths.add c.path.join(" > ")
check "File > Save As..." in paths and "Edit > Transform > Flip Horizontal" in paths and paths.len == 6,
      "every menu walked, submenus too: " & $paths
check did.len == 0, "walking runs nothing"

typeText("tr fl")
check commandHudText() == "tr fl", "typed: " & commandHudText()
key(KeyEnter)
frame()
check did == @["flip"], "\"tr fl\" finds Edit > Transform > Flip Horizontal; Enter does it"
check not commandHudOpen(), "closed after"

did.setLen(0)
key(KeyP, {CtrlPressed, ShiftPressed})
frame()
key(KeyEnter)
frame()
check did == @["flip"], "nothing typed: the one done last comes first"

did.setLen(0)
key(KeyP, {CtrlPressed, ShiftPressed})
typeText("paste")
key(KeyEnter)
frame()
check did.len == 0 and commandHudOpen(), "a command that cannot be chosen now: listed, not done"
key(KeyEsc)
check not commandHudOpen(), "Esc closes it"

canPaste = true
key(KeyP, {CtrlPressed, ShiftPressed})
typeText("sv as")
key(KeyEnter)
frame()
check did == @["save as"], "\"sv as\": Save As... (its letters in order)"

commandHudKeys = ""
key(KeyP, {CtrlPressed, ShiftPressed})
check not commandHudOpen(), "no keys: not opened by them"
commandHudKeys = "Ctrl+Shift+P"
openCommandHud()
frame()
check commandHudOpen(), "openCommandHud opens it"
key(KeyEsc)

stopApp()
echo "test_commandhud: ", passed, " passed"
