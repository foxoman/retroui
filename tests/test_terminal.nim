## The terminal (`retroui/terminal`): what a program writes -- text, colors of the 16, the 256
## and RGB, the cursor moved, lines erased, a region scrolled, the other screen and back, wide
## characters, the line-drawing set, the answers it asks for -- on the screen as xterm has it;
## lines scrolled off kept; a size changed; the keys as xterm sends them; a shell in a
## pseudo-terminal answering what is typed, told its size; the view taking the keys, choosing
## and copying text.

import std/[os, strutils]
import retroui/uirelays/[coords, input, screen, access]
import retroui, retroui/[terminal, imaging, codec]
import std/base64
import harness

proc fed(s: string; cols = 20; rows = 5): Terminal =
  result = newTerminal(cols, rows)
  result.feed(s)

block plainText:
  let t = fed("hello\r\nworld")
  doAssert t.text(0) == "hello" and t.text(1) == "world", t.screenText
  doAssert t.cursor == (5, 1)

block colors:
  let t = fed("\e[31mR\e[1;42mG\e[0m \e[38;5;196mX\e[48;2;10;20;30mY\e[38:2::1:2:3mZ\e[39;49m.")
  doAssert t.cell(0, 0).fg == 0x1000001'u32 and t.cell(0, 0).bg == 0
  doAssert t.cell(1, 0).bg == 0x1000002'u32 and taBold in t.cell(1, 0).attrs
  doAssert t.cell(2, 0).fg == 0 and t.cell(2, 0).attrs == {}
  doAssert t.cell(3, 0).fg == 0x1000000'u32 + 196
  doAssert t.cell(4, 0).bg == 0x20A141E'u32
  doAssert t.cell(5, 0).fg == 0x2010203'u32, toHex(t.cell(5, 0).fg)
  doAssert t.cell(6, 0).fg == 0 and t.cell(6, 0).bg == 0
  let u = fed("\e[4;7;9mu\e[24;27;29mv\e[95mw\e[103mx")
  doAssert {taUnderline, taInverse, taStrike} <= u.cell(0, 0).attrs and u.cell(1, 0).attrs == {}
  doAssert u.cell(2, 0).fg == 0x100000D'u32 and u.cell(3, 0).bg == 0x100000B'u32

block cursorAndErase:
  let t = fed("abcdefghij\r\nklmnopqrst\e[1;5H*\e[2;3H\e[K")
  doAssert t.text(0) == "abcd*fghij" and t.text(1) == "kl", t.screenText
  t.feed("\e[1;3H\e[1K")
  doAssert t.text(0) == "   d*fghij"
  t.feed("\e[2J")
  doAssert t.screenText.strip == ""
  t.feed("\e[3;4Hx\e[A\e[2Dy\e[2Cz\e[Gq")
  doAssert t.text(1) == "q y  z" and t.text(2) == "   x", t.screenText
  t.feed("\e[3;1H12345\e[3;2H\e[2P")
  doAssert t.text(2) == "145", t.text(2)
  t.feed("\e[2@")
  doAssert t.text(2) == "1  45"
  t.feed("\e[3;1H\e[3X")
  doAssert t.text(2) == "   45"

block wrapAndScroll:
  let t = newTerminal(5, 3, scrollback = 100)
  t.feed("123456789")
  doAssert t.text(0) == "12345" and t.text(1) == "6789"
  doAssert t.line(0).wrapped
  t.feed("\r\nA\r\nB\r\nC")
  doAssert t.scrollbackLines == 2 and t.scrolledLine(0).cells[0].ch == int32('1')
  doAssert t.text(0) == "A" and t.text(2) == "C"
  # (a region: only it scrolls)
  let r = fed("1\r\n2\r\n3\r\n4\r\n5", 5, 5)
  r.feed("\e[2;4r\e[4;1H\nX")
  doAssert r.text(0) == "1" and r.text(1) == "3" and r.text(2) == "4" and r.text(3) == "X" and r.text(4) == "5",
    r.screenText
  doAssert r.scrollbackLines == 0
  r.feed("\e[2;1H\eM")                   # (reverse index at the region's top)
  doAssert r.text(1) == "" and r.text(2) == "3"
  r.feed("\e[r\e[1;1H\e[2L")
  doAssert r.text(0) == "" and r.text(2) == "1"
  r.feed("\e[1M")
  doAssert r.text(1) == "1"

block otherScreen:
  let t = fed("shell$ ")
  t.feed("\e[?1049h\e[HFULL SCREEN")
  doAssert t.onAltScreen and t.text(0) == "FULL SCREEN" and t.text(1) == ""
  t.feed("\e[?1049l")
  doAssert not t.onAltScreen and t.text(0) == "shell$" and t.cursor == (7, 0)

block wideAndLines:
  let t = fed("a漢b\e(0lqk\e(Bx")
  doAssert t.cell(1, 0).ch == 0x6F22 and t.cell(2, 0).ch == -1 and t.cell(3, 0).ch == int32('b')
  doAssert t.cell(4, 0).ch == 0x250C and t.cell(5, 0).ch == 0x2500 and t.cell(6, 0).ch == 0x2510
  doAssert t.cell(7, 0).ch == int32('x')
  doAssert charWidth(0x1F600) == 2 and charWidth(0x301) == 0 and charWidth(int32('A')) == 1

block answersAndModes:
  let t = fed("ab\e[6n\e[c\e[5n")
  doAssert t.takeAnswers() == "\e[1;3R\e[?62;22c\e[0n"
  t.feed("\e]0;my title\a\e]2;other\e\\")
  doAssert t.title == "other"
  t.feed("\e[?1h")
  doAssert t.keyBytes(KeyUp, {}) == "\eOA"
  t.feed("\e[?1l")
  doAssert t.keyBytes(KeyUp, {}) == "\e[A" and t.keyBytes(KeyUp, {ShiftPressed}) == "\e[1;2A"
  doAssert t.keyBytes(KeyF5, {}) == "\e[15~" and t.keyBytes(KeyDelete, {}) == "\e[3~"
  doAssert t.keyBytes(KeyTab, {ShiftPressed}) == "\e[Z" and t.keyBytes(KeyBackspace, {}) == "\x7F"
  when not (defined(macosx) or defined(ios)):
    doAssert t.keyBytes(KeyC, {CtrlPressed}) == "\x03" and t.keyBytes(KeyD, {CtrlPressed}) == "\x04"
  doAssert t.keyBytes(KeyX, {AltPressed}) == "\ex" and t.keyBytes(KeyA, {}) == ""
  t.feed("\tA\e[2b")
  doAssert t.text(0) == "ab      AAA", t.text(0)

block resized:
  let t = newTerminal(10, 4, scrollback = 50)
  t.feed("1\r\n2\r\n3\r\n4")
  t.resize(6, 2)
  doAssert t.cols == 6 and t.rows == 2 and t.text(0) == "3" and t.text(1) == "4", t.screenText
  doAssert t.scrollbackLines == 2 and t.cursor.row == 1
  t.resize(12, 5)
  doAssert t.rows == 5 and t.text(0) == "3" and t.line(0).cells.len == 12

block selection:
  let t = newTerminal(10, 3)
  t.feed("one two\r\nthree")
  t.selectAll()
  doAssert t.selectionText().startsWith("one two\nthree"), t.selectionText()

block found:
  let t = newTerminal(20, 4, scrollback = 50)
  for i in 0 ..< 10: t.feed("line " & $i & " apple\r\n")
  doAssert t.findText("APPLE")                        # (from the bottom up, any case)
  doAssert t.selectionText() == "apple" and t.selectionStart.line == 9
  doAssert t.findText("apple") and t.selectionStart.line == 8
  doAssert t.findText("line 2") and t.selectionText() == "line 2"
  doAssert not t.findText("line 2", matchCase = true) or t.selectionStart.line < 2
  doAssert not t.findText("pear")
  t.selectNone()                                       # (nothing chosen: from the bottom again)
  doAssert t.selectionStart == (-1, -1)
  doAssert t.findText("apple") and t.selectionStart.line == 9
  t.zoomText(2)
  doAssert abs(t.fontSize - 1.2) < 1e-9
  t.zoomText(0)
  doAssert t.fontSize == 1.0
  t.feed("\e[31mred")
  t.reset(clear = true)
  doAssert t.scrollbackLines == 0 and t.screenText.strip == "" and t.cursor == (0, 0)

block rightToLeft:
  # (a row with Arabic or Hebrew shown in the order it is read: the Unicode bidirectional
  # algorithm, the row's direction its first strong letter's; what the program wrote unchanged)
  let t = fed("ab \u0645\u0631\u062D\u0628\u0627 cd\r\n\u05E9\u05DC\u05D5\u05DD abc\r\nplain", 30, 4)
  doAssert t.text(0) == "ab \u0645\u0631\u062D\u0628\u0627 cd"
  doAssert t.shownText(0) == "ab \u0627\u0628\u062D\u0631\u0645 cd", t.shownText(0)
  doAssert t.shownText(1) == "abc \u05DD\u05D5\u05DC\u05E9", t.shownText(1)
  doAssert t.shownText(2) == "plain"
  t.bidi = false
  doAssert t.shownText(0) == t.text(0)

block kittyKeyboard:
  let t = newTerminal()
  doAssert t.kbFlags == 0
  t.feed("\e[?u")
  doAssert t.takeAnswers() == "\e[?0u"
  t.feed("\e[>1u")                                   # (Esc and modified keys told apart)
  doAssert t.kbFlags == 1
  doAssert t.kittyKeyBytes(KeyEsc, {}) == "\e[27u"
  when not (defined(macosx) or defined(ios)):
    doAssert t.kittyKeyBytes(KeyA, {CtrlPressed}) == "\e[97;5u"
    doAssert t.kittyKeyBytes(KeyEnter, {CtrlPressed}) == "\e[13;5u"
  doAssert t.kittyKeyBytes(KeyA, {}) == "" and t.kittyKeyBytes(KeyA, {ShiftPressed}) == ""   # (typed)
  doAssert t.kittyKeyBytes(KeyA, {AltPressed}) == "\e[97;3u"
  doAssert t.kittyKeyBytes(KeyEnter, {}) == "" and t.kittyKeyBytes(KeyUp, {}) == "\e[A"
  doAssert t.kittyKeyBytes(KeyUp, {ShiftPressed}) == "\e[1;2A"
  doAssert t.kittyKeyBytes(KeyF3, {AltPressed}) == "\e[13;3~"
  doAssert t.kittyKeyBytes(KeyA, {AltPressed}, release = true) == "", "no releases asked for"
  t.feed("\e[=11;1u")                                # (set: 1, 2, 8)
  doAssert t.kbFlags == 11
  doAssert t.kittyKeyBytes(KeyA, {}) == "\e[97u", "every key an escape"
  doAssert t.kittyKeyBytes(KeyA, {}, release = true) == "\e[97;1:3u"
  doAssert t.kittyKeyBytes(KeyEnter, {}) == "\e[13u"
  t.feed("\e[=16;2u")                                # (or: the text too)
  doAssert t.kbFlags == 27 and t.kittyKeyBytes(KeyB, {ShiftPressed}) == "\e[98;2;66u"
  t.feed("\e[>4u")                                   # (pushed: the shifted key)
  doAssert t.kbFlags == 4
  t.feed("\e[=12;1u")
  doAssert t.kittyKeyBytes(KeyB, {ShiftPressed}) == "\e[98:66;2u"
  t.feed("\e[<u")                                    # (popped: the flags before)
  doAssert t.kbFlags == 27
  t.feed("\e[?1049h")                                # (the other screen: a stack of its own)
  doAssert t.kbFlags == 0
  t.feed("\e[?1049l\e[<5u")
  doAssert t.kbFlags == 0

proc apc(keys: string; data = ""): string = "\e_G" & keys & (if data.len > 0: ";" & data else: "") & "\e\\"

block kittyGraphics:
  let t = newTerminal(40, 10)
  # (an RGBA picture of 2 x 2 sent and shown: at the cursor, the cursor after it)
  var px = ""
  for c in [0xFF0000FF'u32, 0x00FF00FF'u32, 0x0000FFFF'u32, 0xFFFFFFFF'u32]:
    for k in [24, 16, 8, 0]: px.add char((c shr k) and 255)
  t.feed("ab" & apc("a=T,f=32,s=2,v=2,i=7", encode(px)))
  doAssert t.takeAnswers() == "\e_Gi=7;OK\e\\"
  doAssert t.imageCount == 1 and t.pictureCount == 1
  doAssert t.cursor == (3, 0), $t.cursor
  # (quiet: no answer; a placement of it again, 3 cells by 2, the cursor left where it is)
  t.feed("\r\n" & apc("a=p,i=7,c=3,r=2,C=1,q=1"))
  doAssert t.takeAnswers() == "" and t.pictureCount == 2 and t.cursor == (0, 1)
  # (a PNG in two pieces, zlib'ed, with a number: its id told)
  let png = encodePng(newBitmap(16, 8, 0xFF336699'u32))
  let z = zlibCompress(png.toOpenArrayByte(0, png.high))
  var zs = newString(z.len)
  copyMem(addr zs[0], unsafeAddr z[0], z.len)
  let b64 = encode(zs)
  t.feed(apc("a=T,f=100,o=z,I=5,m=1", b64[0 ..< 20]) & apc("m=0", b64[20 .. ^1]))
  let ans = t.takeAnswers()
  doAssert ans.startsWith("\e_Gi=") and ans.endsWith(",I=5;OK\e\\"), ans.escape
  doAssert t.imageCount == 2 and t.pictureCount == 3
  # (asked about: not kept)
  t.feed(apc("a=q,i=31,s=1,v=1,f=24", encode("\x01\x02\x03")))
  doAssert t.takeAnswers() == "\e_Gi=31;OK\e\\" and t.imageCount == 2
  # (wrong data: told why)
  t.feed(apc("a=T,i=9,f=32,s=4,v=4", encode("short")))
  doAssert t.takeAnswers().startsWith("\e_Gi=9;EBADPNG")
  t.feed(apc("a=p,i=99"))
  doAssert t.takeAnswers().startsWith("\e_Gi=99;ENOENT")
  # (it scrolls with its line, into what scrolled off)
  for i in 0 ..< 12: t.feed("\r\n")
  doAssert t.pictureCount == 3 and t.scrollbackLines > 0
  # (taken away: an image's placements, and with D the image too)
  t.feed(apc("a=d,d=I,i=7"))
  doAssert t.pictureCount == 1 and t.imageCount == 1, $t.pictureCount & " " & $t.imageCount
  t.feed(apc("a=d,d=a"))
  doAssert t.imageCount == 1, "a: placements only"
  # (the cell's size in pixels, asked)
  t.feed("\e[16t")
  doAssert t.takeAnswers() == "\e[6;16;8t"
  # (the app's own picture, in pieces as the protocol wants them: shown, nothing said back -- no
  # answer typed into a shell)
  let big = encodePng(newBitmap(64, 64, 0xFF808080'u32))
  let pics = t.pictureCount
  t.showPicture(big & newString(6000), rows = 2)   # (more than one piece of 4096)
  doAssert t.takeAnswers() == "" and t.pictureCount == pics + 1, $t.pictureCount

when defined(posix):
  block shell:
    let t = newTerminal(50, 12)
    doAssert t.spawn(@["/bin/sh", "-c", "printf '\\033[32mgreen\\033[0m\\n'; stty size; exit 3"]), t.error
    doAssert t.waitOutput("12 50", 20_000), t.screenText
    doAssert t.text(0) == "green" and t.cell(0, 0).fg == 0x1000002'u32
    for i in 0 ..< 4000:
      t.update()
      if not t.running: break
      os.sleep(5)
    doAssert not t.running and t.exitCode == 3, $t.exitCode
  block interactive:
    let t = newTerminal(60, 10)
    doAssert t.spawn(@["/bin/sh"], env = [("PS1", "$ ")]), t.error
    t.send("echo $((6*7)) $TERM\r")
    doAssert t.waitOutput("42 xterm-256color", 20_000), t.screenText
    t.resize(40, 8)
    t.send("stty size\r")
    doAssert t.waitOutput("8 40", 20_000), t.screenText
    t.close()
    doAssert not t.running

# the view: the keys, the text chosen and copied
fakeDriver()
var term = newTerminal()
var typed = ""
term.onInput = proc (d: string) = typed.add d
term.feed("first line\r\nsecond line")
var box: Rect
view = proc () =
  terminalView(term, lines = 10, focusFirst = true)
  box = ui.lastRect
var told: seq[AccessNode]
accessRelays.update = proc (nodes: openArray[AccessNode]; focus: int) = told = @nodes
startApp("terminal", W, H)
run(2)
doAssert term.cols > 20 and term.rows == 10, $term.cols & "x" & $term.rows
typeText("ls")
run()
key(KeyEnter)
run()
key(KeyUp)
run()
doAssert typed == "ls\r\e[A", typed.escape
# (a double click on a word chooses it; copied)
let cw = (box.w - 4 - 16) div term.cols
down(box.x + 2 + cw * 8, box.y + 2 + 3, clicks = 2)
run()
up(box.x + 2 + cw * 8, box.y + 2 + 3)
run()
key(KeyC, {CtrlPressed, ShiftPressed})
run()
doAssert getClipboardText() == "line", getClipboardText()
# (a double click on an Arabic word where it is shown chooses it: the mouse goes through the
# order shown)
term.feed("\e[H\e[2Jab \u0645\u0631\u062D\u0628\u0627 cd")
run(2)
down(box.x + 2 + cw * 4 + cw div 2, box.y + 2 + 3, clicks = 2)
run()
up(box.x + 2 + cw * 4 + cw div 2, box.y + 2 + 3)
run()
key(KeyC, {CtrlPressed, ShiftPressed})
run()
doAssert getClipboardText() == "\u0645\u0631\u062D\u0628\u0627", getClipboardText().escape
# (bold in the bright eight, `boldBright`: a block drawn bold red is the bright red)
let lhView = (box.h - 4) div term.rows
term.themed = false
term.colors = LightColors
term.colors.ansi[1] = color(160, 0, 0)
term.colors.ansi[9] = color(250, 0, 0)
term.feed("\e[H\e[2J\e[1;31m\u2588\e[0m")
run(2)
doAssert px(box.x + 3, box.y + 2 + lhView div 2) == 0xA00000'u32 or
         px(box.x + 3, box.y + 2 + lhView div 2) == 0x0000A0'u32, toHex(px(box.x + 3, box.y + 2 + lhView div 2))
term.boldBright = true
run(2)
let bright = px(box.x + 3, box.y + 2 + lhView div 2)
doAssert bright == 0xFA0000'u32 or bright == 0x0000FA'u32, toHex(bright)
term.boldBright = false
# (Shift+Page Up and Page Down: back through what scrolled off and down again, nothing sent)
for i in 0 ..< 30: term.feed("line " & $i & "\r\n")
run(2)
proc shot(): seq[uint32] =
  for y in box.y + 2 ..< box.y + box.h - 2:
    for x in box.x + 2 ..< box.x + box.w div 2: result.add px(x, y)
let atBottom = shot()
typed = ""
key(KeyPageUp, {ShiftPressed})
run(2)
doAssert typed == "" and shot() != atBottom, typed.escape
key(KeyPageDown, {ShiftPressed})
run(2)
doAssert typed == "" and shot() == atBottom, typed.escape
# (a screen reader reads the screen, its caret at the cursor)
term.feed("$ ")
accessListening = true
run(3)
var found = false
for n in told:
  if n.role == arTextArea and "line 29" in n.value:
    found = true
    doAssert asFocused in n.states
    doAssert n.caret == n.value.strip(leading = false).len, $n.caret & " of " & n.value.escape
doAssert found, $told.len
accessListening = false
# (the keys a menu bar would take, the program's while the terminal has the focus:
# `terminalKeysFirst` before the menu bar; Alt and a mark is Esc and the mark)
var opened = false
view = proc () =
  terminalKeysFirst(term)
  menubar:
    menu "&File":
      opened = true
      if menuItem("E&xit"): discard
  terminalView(term, lines = 10, focusFirst = true)
  box = ui.lastRect
run(2)
typed = ""
key(KeyF, {AltPressed})
run(2)
doAssert typed == "\ef" and not opened and ui.popup == 0, typed.escape
key(KeyF10)
run(2)
doAssert typed == "\ef\e[21~" and not opened, typed.escape
key(KeyPeriod, {AltPressed})
run(2)
doAssert typed == "\ef\e[21~\e.", typed.escape
echo "test_terminal: ok"
