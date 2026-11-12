## The Windows 3.1 window frame on desktops (`setClassicFrame`), headless:
## where its parts are, what a press on each asks of the system (move, size,
## maximize, minimize, close; Windows 95's buttons and 3.1's,
## `captionButtons`), the parts a system's hit test is told
## (`windowPartAt`), the control menu, the colors of an inactive window,
## how the bars move down under it, switching it at run time, the item in
## the system's menu and its check mark, and keeping the choice.

import std/[os, strutils]
import retroui
import retroui/uirelays/[input, screen, services]
import harness

fakeDriver()
# (what the toolkit keeps for the app -- the frame the user chose -- in a
# folder of the test's own)
let keepHome = getTempDir() / "retro-test-frame-" & $getCurrentProcessId()
putEnv("XDG_DATA_HOME", keepHome)
removeDir(keepHome)

# ---- a system that can do without its frame ----------------------------------------------------

var
  systemFrame = true                  # the system's frame is on
  drags: seq[tuple[part: WindowPart; keyboard: bool]]
  maxed = false
  activeWin = true
  minimized = 0
  asked: tuple[w, h: int]             # the window size the app asked for
  cursorNow = curDefault

proc fakeSetSystemFrame(on: bool): bool =
  systemFrame = on
  true
proc fakeDrag(part: WindowPart; keyboard: bool): bool =
  drags.add (part, keyboard)
  # (the system took the button's release: the driver reports it)
  if not keyboard: queue.add Event(kind: MouseUpEvent, x: 1, y: 1, button: LeftButton)
  true
proc fakeSetMaximized(on: bool) =
  maxed = on
  queue.add Event(kind: WindowResizeEvent, x: W, y: H)
proc fakeMinimize(): bool =
  inc minimized
  true
var
  menuLabel = ""                      # the app's item in the system's menu
  menuChecked = false                 # ... and its check mark
  menuPicked = false
frameRelays = FrameRelays(setSystemFrame: fakeSetSystemFrame, dragWindow: fakeDrag,
                          setMaximized: fakeSetMaximized,
                          maximized: proc (): bool = maxed,
                          active: proc (): bool = activeWin,
                          menuItem: proc (label: string; checked: bool) =
                            menuLabel = label
                            menuChecked = checked,
                          menuItemChosen: proc (): bool =
                            result = menuPicked
                            menuPicked = false)
systemRelays.minimize = fakeMinimize
let harnessCreate = windowRelays.createWindow
windowRelays.createWindow = proc (l: var ScreenLayout; icon: pointer; iconLen: int) =
  asked = (l.width, l.height)
  harnessCreate(l, icon, iconLen)
windowRelays.setCursor = proc (c: CursorKind) = cursorNow = c

# Built with the system's frame (the default); RETRO_FRAME wins over that.
doAssert retroFrame == "system"
putEnv("RETRO_FRAME", "classic")
startApp("frame", 400, 300)
doAssert classicFrame() and classicFrameWanted() and canClassicFrame()
doAssert not systemFrame, "the window is made without the system's frame"
# (the frame goes round the size asked for -- its title bar as the metrics
# had it before the window, a pixel or so off -- either way -- what the font
# then makes it)
doAssert asked.w == 400 + 2 * 5 and asked.h - 300 - 2 * 5 in MenuH .. MenuH + 2,
  "the frame goes round the size asked for: " & $asked
# (the system's menu has the 3.1 frame's item, checked: it is on)
doAssert menuLabel == "Windows 3.1 &Frame" and menuChecked

var closes = 0
view = proc () =
  menubar:
    menu "&File":
      discard menuItem("&Open")
  label "Content"
  statusbar("Ready")
  if closeRequested():
    inc closes
    cancelClose()
run(2)

const Navy = 0x000080'u32
const White = 0xFFFFFF'u32
const Black = 0x000000'u32
const Gray = 0xC0C0C0'u32
let ch = MenuH            # the title bar's height (and its buttons' size)
let c = 5 + ch            # where the corners' parts end along the border
# the buttons at the right (Windows 95's, the default): close, then two
# pixels apart, maximize and minimize; `b` the border
proc closeR(b = 5): Rect = rect(W - b - ch, b, ch, ch)
proc maxR(b = 5): Rect = rect(W - b - 2 * ch - 2, b, ch, ch)
proc minR(b = 5): Rect = rect(W - b - 3 * ch - 2, b, ch, ch)

block layout:
  # the border all round, the title bar (and its line) inside it: the bars
  # and the content start below, as under a phone's title bar
  doAssert ui.frameBorder == 5 and ui.captionH == ch + 1
  doAssert ui.safe == (5, 5, 5, 5), $ui.safe
  doAssert ui.barY == 5 + ch + 1 + MenuH + 1, "the menu bar is under the title bar"
  doAssert ui.bottom < H - 5, "the status bar is over the bottom border"
  let f = frameLayout()
  doAssert f.caption == rect(5, 5, W - 10, ch), $f.caption
  doAssert f.controlBox == rect(5, 5, ch, ch)
  doAssert f.close == closeR() and f.maximize == maxR() and f.minimize == minR(), $f
  doAssert f.corner == c

block drawn:
  doAssert px(0, 200) == Black and px(W - 1, 200) == Black, "the outer line"
  doAssert px(2, 200) == Gray and px(W - 3, 200) == Gray, "the gray band"
  doAssert px(4, 200) == Black and px(W - 5, 200) == Black, "the inner line"
  doAssert px(320, H - 3) == Gray, "the band at the bottom"
  # the dark lines across the band, where the corners' parts end
  doAssert px(c, 2) == Black and px(2, c) == Black, "top left corner lines"
  doAssert px(W - c, 2) == Black and px(W - 3, c) == Black, "top right"
  doAssert px(2, H - 1 - c) == Black and px(c, H - 3) == Black, "bottom left"
  doAssert px(c - 1, 2) == Gray and px(c + 1, 2) == Gray
  # the active title bar, the line under it, the menu bar under that
  doAssert px(40, 10) == Navy and px(minR().x - 10, 10) == Navy, "the title bar"
  doAssert px(40, 5 + ch) == Black, "the line under the title bar"
  doAssert px(100, 5 + ch + 4) == White, "the menu bar"
  doAssert px(8, 8) == Gray, "the control-menu box"

block parts:
  for (x, y, want) in [(0, 0, fpTopLeft), (2, c - 1, fpTopLeft), (2, c, fpLeft),
                       (2, 240, fpLeft), (W - 1, 240, fpRight), (320, 1, fpTop),
                       (320, H - 1, fpBottom), (W - 1, H - 1, fpBottomRight),
                       (c - 1, H - 2, fpBottomLeft), (W - 2, 2, fpTopRight),
                       (W - 2, H - c, fpBottomRight), (W - 2, H - c - 1, fpRight),
                       (10, 10, fpControlBox), (W - 10, 10, fpClose),
                       (maxR().x + 5, 10, fpMaximize), (minR().x + 5, 10, fpMinimize),
                       (W - 6 - ch, 10, fpCaption), (320, 10, fpCaption),
                       (320, 5 + ch, fpCaption), (320, 6 + ch, fpNone),
                       (320, 240, fpNone)]:
    doAssert framePartAt(x, y) == want, $(x, y) & ": " & $framePartAt(x, y)
  doAssert systemPart(fpCaption) == wpCaption and systemPart(fpTopLeft) == wpTopLeft
  doAssert systemPart(fpMinimize) == wpClient and systemPart(fpClose) == wpClient
  # right to left the window is drawn mirrored: its left edge is on the right
  ui.rtl = true
  doAssert systemPart(fpLeft) == wpRight and systemPart(fpBottomLeft) == wpBottomRight
  ui.rtl = false

block hitTest:
  # what the toolkit tells a system that asks where the frame is before a
  # press comes (SDL's hit test): the title bar and the border, not its
  # buttons nor the content -- but the maximize button, over which Windows
  # 11 shows its snap layouts (the press still the app's)
  doAssert windowPartAt != nil
  for (x, y, want) in [(320, 12, wpCaption), (2, 240, wpLeft), (W - 1, 240, wpRight),
                       (320, 1, wpTop), (320, H - 1, wpBottom), (0, 0, wpTopLeft),
                       (W - 2, H - 2, wpBottomRight), (10, 10, wpClient),
                       (W - 10, 10, wpClient), (minR().x + 5, 10, wpClient),
                       (maxR().x + 5, 10, wpMaxButton), (320, 240, wpClient)]:
    doAssert windowPartAt(x, y) == want, $(x, y) & ": " & $windowPartAt(x, y)
  # right to left: the same edges on the screen
  ui.rtl = true
  doAssert windowPartAt(2, 240) == wpLeft and windowPartAt(W - 2, H - 2) == wpBottomRight
  ui.rtl = false
  # a menu open: a press anywhere is the app's (it closes the menu)
  ui.popup = Id(7)
  doAssert windowPartAt(320, 12) == wpClient
  ui.popup = Id(0)

block moveAndSize:
  # the title bar moves the window, the border and its corners size it:
  # the system does it, from the press
  down(320, 12)
  run()
  doAssert drags == @[(wpCaption, false)], $drags
  run()
  doAssert not ui.mouseDown, "the release the system took is reported"
  for (x, y, want) in [(2, 240, wpLeft), (W - 2, H - 2, wpBottomRight),
                       (320, 1, wpTop), (W - 2, 2, wpTopRight)]:
    drags.setLen 0
    down(x, y)
    run(2)
    doAssert drags == @[(want, false)], $(x, y) & ": " & $drags
  # the sizing arrows over the border
  move(2, 240)
  run()
  doAssert cursorNow == curSizeWE, $cursorNow
  move(W - 2, H - 2)
  run()
  doAssert cursorNow == curSizeNWSE, $cursorNow
  move(320, H - 2)
  run()
  doAssert cursorNow == curSizeNS
  move(320, 200)
  run()
  doAssert cursorNow != curSizeNS

block maximize:
  # a double click on the title bar maximizes: no border then, the title bar
  # at the top of the screen, the bars right under it
  drags.setLen 0
  down(320, 12, clicks = 2)
  run()
  up(320, 12)
  run(2)
  doAssert maxed and drags.len == 0
  doAssert ui.frameBorder == 0 and ui.safe == (0, 0, 0, 0)
  doAssert ui.barY == ch + 1 + MenuH + 1
  doAssert framePartAt(0, 240) == fpNone and framePartAt(320, 10) == fpCaption
  let mx = maxR(0)
  doAssert frameLayout().maximize == mx and frameLayout().close == closeR(0)
  doAssert px(0, 200) != Black, "no border"
  # the maximize button restores
  click(mx)
  run()
  doAssert not maxed and ui.frameBorder == 5
  click(maxR())
  run()
  doAssert maxed
  click(mx)
  run()
  doAssert not maxed

block minimize:
  click(minR())
  doAssert minimized == 1

block closeButton:
  # Windows 95's close button: the X, a little apart from the others (the
  # title bar's color between); a click asks the app to close, as Alt+F4
  let x = closeR()
  let face = rect(x.x + 1, x.y, x.w - 1, x.h)
  doAssert px(face.x + face.w div 2, face.y + face.h div 2) == Black, "the X's middle"
  doAssert px(face.x + 2, face.y + face.h div 2) == Gray, "its face"
  doAssert px(W - 6 - ch, 10) == Navy, "the gap before it"
  move(x.x + 5, x.y + 5)
  run(2)
  doAssert ui.tip == "Close", ui.tip
  # a press that leaves it does nothing
  down(x.x + 5, x.y + 5)
  run()
  up(320, 200)
  run(2)
  doAssert closes == 0 and not maxed and minimized == 1
  click(x, dx = 5)
  run()
  doAssert closes == 1, $closes

block win31Buttons:
  # Windows 3.1's buttons: minimize and maximize at the right, no close
  # button (the control-menu box closes); a change shows at once
  captionButtons = cbWin31
  run(2)
  let f = frameLayout()
  doAssert f.close.w == 0 and f.maximize == rect(W - 5 - ch, 5, ch, ch) and
           f.minimize == rect(W - 5 - 2 * ch, 5, ch, ch), $f
  doAssert framePartAt(W - 10, 10) == fpMaximize and framePartAt(W - 10 - ch, 10) == fpMinimize
  doAssert px(W - 6 - ch, 10) != Navy, "no gap: the buttons side by side"
  click(f.minimize, dx = 5)
  doAssert minimized == 2
  captionButtons = cbWin95
  run(2)
  doAssert frameLayout().close == closeR()

block controlMenu:
  # a click on the control-menu box opens its menu; its letters choose
  click(rect(5, 5, ch, ch), dx = 8)
  doAssert ui.popup != 0, "the control menu is open"
  key(KeyX)                        # Ma&ximize
  run(2)
  doAssert maxed and ui.popup == 0
  key(KeySpace, {AltPressed})      # Alt+Space opens it too
  run()
  doAssert ui.popup != 0
  key(KeyR)                        # &Restore
  run(2)
  doAssert not maxed
  key(KeySpace, {AltPressed})
  run()
  drags.setLen 0
  key(KeyM)                        # &Move: with the arrow keys
  run(2)
  doAssert drags == @[(wpCaption, true)], $drags
  # Windows 3.1 &Buttons: 3.1's two buttons, kept with the look; and back
  discard lookChanged()
  key(KeySpace, {AltPressed})
  run()
  key(KeyB)
  run(2)
  doAssert captionButtons == cbWin31 and lookChanged() and frameLayout().close.w == 0
  key(KeySpace, {AltPressed})
  run()
  key(KeyB)                        # Windows 95 &Buttons
  run(2)
  doAssert captionButtons == cbWin95 and frameLayout().close == closeR()
  key(KeySpace, {AltPressed})
  run()
  key(KeyEsc)
  run()
  doAssert ui.popup == 0
  # a double click on the box closes the window (the app is asked first)
  down(10, 10)
  run()
  up(10, 10)
  run()
  down(10, 10, clicks = 2)
  run()
  up(10, 10)
  run(2)
  doAssert closes == 2, $closes
  doAssert ui.popup == 0

block inactive:
  # another window in front: the title bar white, its title black
  queue.add Event(kind: WindowFocusLostEvent)
  activeWin = false
  run()
  doAssert px(40, 10) == White, "an inactive title bar"
  queue.add Event(kind: WindowFocusGainedEvent)
  activeWin = true
  run()
  doAssert px(40, 10) == Navy

block menusUnderIt:
  # the menu bar's menus open under the title bar, and a click on the frame
  # while one is open only closes it
  click(rect(5 + 4, 5 + ch + 1, 30, MenuH), dx = 8)
  doAssert ui.popup != 0 and ui.menuOpen
  drags.setLen 0
  down(320, 12)
  run()
  up(320, 12)
  run()
  doAssert ui.popup == 0 and drags.len == 0

block runTime:
  # switched off: the system's frame again, nothing over the bars
  setClassicFrame(false)
  run(2)
  doAssert systemFrame and not classicFrame()
  doAssert not menuChecked, "the system menu's item follows it"
  doAssert windowPartAt(320, 12) == wpClient, "no frame of the app's to hit"
  doAssert ui.frameBorder == 0 and ui.captionH == 0 and ui.barY == MenuH + 1
  doAssert framePartAt(2, 240) == fpNone
  doAssert px(100, 5) == White, "the menu bar at the top"
  # and on again
  setClassicFrame(true)
  run(2)
  doAssert not systemFrame and classicFrame() and ui.frameBorder == 5
  doAssert px(40, 10) == Navy
  doAssert menuChecked

block settings:
  # the user's choice is kept by the toolkit for the app (its window.ini),
  # not in the app's settings; a store of before is brought over once
  doAssert appIdent == "frame" and menuLabel == "Windows 3.1 &Frame",
    "the system's menu offers the 3.1 frame: " & menuLabel
  var s: Settings
  s["look.frame"] = "classic"
  storeAppearance(s)
  doAssert not s.hasKey("look.frame"), "the app's settings no longer keep it"
  delEnv("RETRO_FRAME")
  doAssert keptFrame() == ""
  chooseClassicFrame(false)
  run()
  doAssert not classicFrame() and keptFrame() == "system"
  doAssert readFile(keepHome / "frame" / "window.ini").strip == "frame=system"
  # picked in the system's menu: the 3.1 frame, kept
  menuPicked = true
  run(2)
  doAssert classicFrame() and keptFrame() == "classic", "the system menu's item"
  doAssert menuChecked, "checked now"
  # an old store's choice is not brought over once one is kept
  s["look.frame"] = "system"
  restoreAppearance(s)
  doAssert classicFrame() and keptFrame() == "classic"
  # RETRO_FRAME wins at the start, and is not kept
  putEnv("RETRO_FRAME", "system")
  restoreAppearance(s)
  doAssert classicFrame() and keptFrame() == "classic"
  delEnv("RETRO_FRAME")
  # the title bars' buttons are kept with the look; a store of before has
  # none, and the app's own stays
  s.del("look.buttons")
  captionButtons = cbWin31
  restoreAppearance(s)
  doAssert captionButtons == cbWin31
  storeAppearance(s)
  doAssert s["look.buttons"] == "win31"
  captionButtons = cbWin95
  restoreAppearance(s)
  doAssert captionButtons == cbWin31, "the user's choice wins"
  captionButtons = cbWin95
  run()

block altSpace:
  # Alt+Space opens the window's menu -- the 3.1 control menu, or the
  # system's -- and never presses the focused button
  var pressed = 0
  let before = view
  view = proc () =
    if button("&Quit"): inc pressed
  run(2)
  key(KeyTab)
  run(2)
  setClassicFrame(false)
  run(2)
  key(KeySpace, {AltPressed})
  run(3)
  doAssert pressed == 0, "Alt+Space with the system's frame presses nothing"
  setClassicFrame(true)
  run(2)
  key(KeySpace, {AltPressed})
  run(3)
  doAssert pressed == 0 and ui.popup != 0, "Alt+Space: the control menu"
  key(KeyEsc)
  run(2)
  view = before

block frameNotBack:
  # a window that cannot have the system's frame back while it is open
  # (Siwin on Windows) keeps the 3.1 one: never a window without a frame
  doAssert classicFrame()
  frameRelays.setSystemFrame = proc (on: bool): bool = not on
  setClassicFrame(false)
  run()
  doAssert classicFrame() and ui.frameBorder == 5
  frameRelays.setSystemFrame = fakeSetSystemFrame
  setClassicFrame(true)
  run()

block noFrameWhereItCannot:
  # a system that cannot do without its frame (phones, a driver without
  # frame relays): asked for, the 3.1 frame is not drawn
  let saved = frameRelays
  setClassicFrame(false)
  frameRelays = FrameRelays()
  doAssert not canClassicFrame()
  setClassicFrame(true)
  run()
  doAssert not classicFrame() and classicFrameWanted() and ui.frameBorder == 0
  frameRelays = saved
  setClassicFrame(true)
  run()
  doAssert classicFrame()

block sizeGripAndResizable:
  # the size grip: a scroll bar's width square inside the frame's bottom
  # right corner (over the status bar's end here); it sizes the window as
  # that corner does
  run(2)
  let g = sizeGrip()
  doAssert g == rect(W - 5 - SbW, H - 5 - SbW, SbW, SbW), $g
  doAssert framePartAt(g.x + 2, g.y + 2) == fpBottomRight
  doAssert windowPartAt(g.x + 2, g.y + 2) == wpBottomRight, "a system's hit test is told"
  var light, dark = 0
  for y in g.y ..< g.y + g.h:
    for x in g.x ..< g.x + g.w:
      if px(x, y) == White: inc light
      elif px(x, y) == 0x808080'u32: inc dark
  doAssert light > 0 and dark > light, "its ridges: " & $(light, dark)
  drags.setLen 0
  down(g.x + g.w div 2, g.y + g.h div 2)
  run(2)
  doAssert drags == @[(wpBottomRight, false)], $drags
  # a window that keeps its size (`app`'s `resizable = false`): the system
  # is told, and the frame has no grip, no sizing border, no maximize button
  var told: seq[bool]
  frameRelays.setResizable = proc (on: bool) = told.add on
  setResizable(false)
  run(2)
  doAssert told == @[false] and not resizable()
  doAssert sizeGrip().w == 0
  let f = frameLayout()
  doAssert f.maximize.w == 0 and f.close == closeR() and
           f.minimize == rect(W - 5 - 2 * ch - 2, 5, ch, ch), $f
  doAssert framePartAt(W - 10, 10) == fpClose and framePartAt(f.minimize.x + 5, 10) == fpMinimize
  for (x, y) in [(2, 240), (W - 2, H - 2), (320, 1), (g.x + 2, g.y + 2)]:
    doAssert framePartAt(x, y) == fpNone, $(x, y) & ": " & $framePartAt(x, y)
  doAssert px(c, 2) == Gray, "no sizing marks across the border"
  # a double click on the title bar does not maximize it
  maxed = false
  drags.setLen 0
  down(320, 12, clicks = 2)
  run(2)
  up(320, 12)
  run(2)
  doAssert not maxed
  setResizable(true)
  run(2)
  doAssert sizeGrip().w > 0 and told == @[false, true]

block minimized:
  # minimized (the driver's WindowHiddenEvent): frames and timers go on,
  # nothing is drawn; back again (WindowShownEvent): drawn whole
  var n = 0
  var frames = 0
  view = proc () =
    inc frames
    label "Count " & $n
  run(3)
  let shown = pixels
  queue.add Event(kind: WindowHiddenEvent)
  run(1)
  doAssert ui.hidden
  for i in 0 ..< 5:
    inc n
    let before = frames
    run(1)
    doAssert frames > before, "the app's frames go on"
  doAssert pixels == shown, "nothing drawn while nobody sees it"
  queue.add Event(kind: WindowShownEvent)
  run(2)
  doAssert not ui.hidden
  doAssert pixels != shown, "drawn again, with what changed"

block caretRests:
  # a text box with the focus: its caret blinks (a frame each half second)
  # for 10 seconds after it last moved, then stays shown -- no more frames
  var s = "hello"
  view = proc () =
    edit(s, w = 200)
  run(2)
  key(KeyTab)
  run(2)
  ticks += 600
  run(1)
  doAssert ui.wakeAt > 0, "it blinks"
  ticks += CaretBlinkFor + 100
  run(2)
  doAssert ui.wakeAt == 0, "left alone 10 seconds: no frames for it (" & $(ui.wakeAt - ui.now) & ")"
  typeText("!")
  run(2)
  doAssert ui.wakeAt > 0, "typed: it blinks again"

# ---- a letter typed is on the screen with the frame that took it ---------------------------------

block typedShownAtOnce:
  var s = ""
  var r: Rect
  view = proc () =
    edit s
    r = ui.lastRect
  run(3)
  click(r)
  run(2)
  let before = pixels
  typeText("W")
  var frames = 0
  while s.len == 0 and frames < 10:
    discard beginFrame()
    view()
    endFrame()
    inc frames
    ticks += 16
  doAssert s == "W"
  doAssert pixels != before, "the frame that took the letter is shown at once"
  run(2)

removeDir(keepHome)
echo "test_frame: ok"
