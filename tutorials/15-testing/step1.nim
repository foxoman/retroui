#> build-only
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
