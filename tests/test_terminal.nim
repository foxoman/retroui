## The terminal (`retroui/terminal`): what a program writes -- text, colors of the 16, the 256
## and RGB, the cursor moved, lines erased, a region scrolled, the other screen and back, wide
## characters, the line-drawing set, the answers it asks for -- on the screen as xterm has it;
## lines scrolled off kept; a size changed; the keys as xterm sends them; a shell in a
## pseudo-terminal answering what is typed, told its size; the view taking the keys, choosing
## and copying text.

import std/[os, strutils]
import retroui/uirelays/[coords, input, screen]
import retroui, retroui/terminal
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
echo "test_terminal: ok"
