# Lesson 15: Testing your app

**Level:** advanced · **Time:** 30 minutes · **You learn:** tests without a window, and driving a real one

## Without a window

```nim
## A test of your app without a window: the kit's fake driver, scripted
## input, then checks. Copy tests/harness.nim from the kit next to it.
import harness, retroui
import retroui/uirelays/input

fakeDriver()
startApp("test", W, H)

var name = "World"
var greeted = ""
var greetRect: Rect

view = proc () =                     # your app's frame, as `app`'s block
  edit name
  if button("&Greet"): greeted = "Hello, " & name & "!"
  greetRect = ui.lastRect

run(2)                               # two frames: the layout settles
click(greetRect)                     # down, a frame, up, a frame
doAssert greeted == "Hello, World!"
key(KeyG, {AltPressed}); run()       # Alt+G: the underlined letter
doAssert greeted == "Hello, World!"
echo "ok"
```

The kit's fake driver (`tests/harness.nim` in the kit: copy it next to your tests) runs frames with no screen: `click`, `key`, `typeText`, `down`/`move`/`up` queue input, `run(n)` runs frames until it is used, and `px(x, y)` reads a pixel. `ui.lastRect` is where the control drawn last is. It runs in CI on every system, and as WebAssembly under Node.

## A real window, driven by its controls' names

```sh
RETRO_DRIVE=7000 ./myapp &
retrokit drive 7000 click "New"
retrokit drive 7000 type "Shopping list"
retrokit drive 7000 key ctrl+s
retrokit drive 7000 wait "Saved" --timeout 3000
retrokit drive 7000 tree                 # every control, as screen readers see them
```

`RETRO_DRIVE` lets a program on the same machine use the app as a person would, by its controls' names -- from a shell script, Python or `retroui/driveclient` in Nim. Retro Designer's File > Export Driver Test writes one for a window. F12 in a debug build (or `RETRO_INSPECT=1`) shows why each frame ran and the control under the mouse.

## Checks the kit runs on itself

- `RETRO_SMOKE=14 ./myapp`: the app started for real, its first frame timed, 3 s untouched measured (an app at rest should run next to no frames), then clicks and keys until it ends; a fault fails it.
- The kit's `tools/returncheck.py` and `tools/writecheck.py` find two patterns Nim 2.2 leaks with: `python3 path/to/retroui/tools/returncheck.py app.nim`.

## What you learned

- The fake driver; `RETRO_DRIVE` and `retrokit drive`; `RETRO_SMOKE`.

## Try it

Write a test for the to-do list of Lesson 2: add two tasks, tick one, and check "1 left".
