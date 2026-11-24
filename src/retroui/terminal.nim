## A terminal in a box of the window: a shell, or any program that runs in one -- `top`, `vim`,
## `htop`, a build -- through a pseudo-terminal (Linux, macOS, the BSDs, Android), drawn as an
## xterm draws it: its colors (16, 256, every RGB), bold, italic, underlined, inverse; its
## cursor; the lines that scrolled off kept to scroll back to; the screen a full-screen program
## draws on and leaves; lines and boxes drawn whole from cell to cell. Text chosen with the mouse
## is copied (Ctrl+Shift+C; Cmd+C on a Mac), pasted (Ctrl+Shift+V, Shift+Insert), a program
## that asks for the mouse gets its clicks and the wheel.
##
## .. code-block:: nim
##   import retroui, retroui/terminal
##
##   var term = newTerminal()
##   discard term.spawn()                  # the user's shell ($SHELL)
##
##   app "Shell", 800, 500:
##     terminalView(term, lines = -1)      # the height that is left
##     if not term.running: label "The shell ended (" & $term.exitCode & ")"
##
## Without a program, a terminal shows what the app writes to it (`feed`) -- a build's output
## in its colors, a log -- and what is typed into it goes to `onInput` (a console of the app's
## own). On Windows the program runs in Windows 10's pseudo-console (1809 and later: `spawn`
## says so in `error` on an older one).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[deques, strutils, os, uri, monotimes, times]
from std/unicode import Rune, toUtf8
import core, widgets
import uirelays/input

when defined(posix) and not defined(js) and not defined(emscripten) and not defined(wasm):
  import std/posix
  const hasPty = true
  proc posix_openpt(flags: cint): cint {.importc, header: "<stdlib.h>".}
  proc grantpt(fd: cint): cint {.importc, header: "<stdlib.h>".}
  proc unlockpt(fd: cint): cint {.importc, header: "<stdlib.h>".}
  proc ptsname(fd: cint): cstring {.importc, header: "<stdlib.h>".}
  var TIOCSCTTY {.importc, header: "<sys/ioctl.h>".}: culong
  var TIOCSWINSZ {.importc, header: "<sys/ioctl.h>".}: culong
  type Winsize {.importc: "struct winsize", header: "<sys/ioctl.h>", pure.} = object
    ws_row, ws_col, ws_xpixel, ws_ypixel: cushort
  proc ioctl(fd: cint; req: culong): cint {.importc, header: "<sys/ioctl.h>", varargs.}

else:
  const hasPty = false

when defined(windows):
  import std/dynlib
  const hasConPty = true
  type
    Coord {.pure.} = object
      x, y: int16
    StartupInfoW {.pure.} = object
      cb: int32
      lpReserved, lpDesktop, lpTitle: pointer
      dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags: int32
      wShowWindow, cbReserved2: int16
      lpReserved2: pointer
      hStdInput, hStdOutput, hStdError: pointer
    StartupInfoExW {.pure.} = object
      startupInfo: StartupInfoW
      lpAttributeList: pointer
    ProcessInformation {.pure.} = object
      hProcess, hThread: pointer
      dwProcessId, dwThreadId: int32
    CreatePcProc = proc (size: Coord; hin, hout: pointer; flags: int32; pc: ptr pointer): int32 {.stdcall, gcsafe.}
    ResizePcProc = proc (pc: pointer; size: Coord): int32 {.stdcall, gcsafe.}
    ClosePcProc = proc (pc: pointer) {.stdcall, gcsafe.}
  proc CreatePipe(r, w: ptr pointer; sa: pointer; size: int32): int32 {.stdcall, dynlib: "kernel32", importc.}
  proc CloseHandle(h: pointer): int32 {.stdcall, dynlib: "kernel32", importc.}
  proc ReadFile(h: pointer; buf: pointer; n: int32; got: ptr int32; ov: pointer): int32 {.
    stdcall, dynlib: "kernel32", importc.}
  proc WriteFile(h: pointer; buf: pointer; n: int32; put: ptr int32; ov: pointer): int32 {.
    stdcall, dynlib: "kernel32", importc.}
  proc PeekNamedPipe(h: pointer; buf: pointer; n: int32; got, avail, left: ptr int32): int32 {.
    stdcall, dynlib: "kernel32", importc.}
  proc InitializeProcThreadAttributeList(list: pointer; count, flags: int32; size: ptr csize_t): int32 {.
    stdcall, dynlib: "kernel32", importc.}
  proc UpdateProcThreadAttribute(list: pointer; flags: int32; attr: uint; value: pointer; size: csize_t;
                                 prev, retSize: pointer): int32 {.stdcall, dynlib: "kernel32", importc.}
  proc DeleteProcThreadAttributeList(list: pointer) {.stdcall, dynlib: "kernel32", importc.}
  proc CreateProcessW(app: pointer; cmd: WideCString; pa, ta: pointer; inherit, flags: int32; env: pointer;
                      cwd: WideCString; si: pointer; pi: ptr ProcessInformation): int32 {.
    stdcall, dynlib: "kernel32", importc.}
  proc WaitForSingleObject(h: pointer; ms: int32): int32 {.stdcall, dynlib: "kernel32", importc.}
  proc GetExitCodeProcess(h: pointer; code: ptr int32): int32 {.stdcall, dynlib: "kernel32", importc.}
  proc TerminateProcess(h: pointer; code: int32): int32 {.stdcall, dynlib: "kernel32", importc.}
  proc GetLastError(): int32 {.stdcall, dynlib: "kernel32", importc.}
  var conPty: tuple[tried: bool; create: CreatePcProc; resize: ResizePcProc; close: ClosePcProc]
    ## (Windows 10's pseudo-console, 1809 and later: looked up, so the program starts on an older one)

  proc findConPty(): bool =
    if not conPty.tried:
      conPty.tried = true
      let k = loadLib("kernel32.dll")
      if k != nil:
        conPty.create = cast[CreatePcProc](k.symAddr("CreatePseudoConsole"))
        conPty.resize = cast[ResizePcProc](k.symAddr("ResizePseudoConsole"))
        conPty.close = cast[ClosePcProc](k.symAddr("ClosePseudoConsole"))
    conPty.create != nil and conPty.resize != nil and conPty.close != nil
else:
  const hasConPty = false

type
  TermAttr* = enum
    ## How a character is drawn.
    taBold, taFaint, taItalic, taUnderline, taBlink, taInverse, taHidden, taStrike

  TermCell* = object
    ## A cell of the screen.
    ch*: int32             ## the character (0: blank; -1: the right half of a wide one)
    fg*, bg*: uint32       ## 0: the default color; 0x1000000 + n: color n of the 256;
                           ## 0x2000000 + RGB: that color
    attrs*: set[TermAttr]

  TermLine* = object
    ## A row of cells, `wrapped` when the text goes on in the next (copied as one line).
    cells*: seq[TermCell]
    wrapped*: bool

  TermColors* = object
    ## The colors a terminal is drawn in: its text and its background, the 16 the programs
    ## name (black, red, green, yellow, blue, magenta, cyan, white, then the bright eight),
    ## the cursor's and the chosen text's.
    fg*, bg*, cursor*, selection*: Color
    ansi*: array[16, Color]

  ParseState = enum psGround, psEsc, psEscHash, psCharset, psCsi, psOsc, psOscEsc, psStr, psStrEsc

  Terminal* = ref object
    ## A terminal: its screen and what scrolled off it, and the program in it (`spawn`).
    cols*, rows*: int        ## its size in cells (set by `terminalView` from its box)
    title*: string           ## what the program called its window (OSC 0 or 2)
    cwd*: string             ## the folder the shell says it is in (OSC 7), when it says
    maxScrollback*: int      ## the lines kept that scrolled off (10,000 by default)
    colors*: TermColors      ## the colors it is drawn in
    themed*: bool            ## its colors from the scheme, light or dark (true by default)
    fontSize*: float         ## its text, in sizes of the UI's (1.0)
    bells*: int              ## how many times the program rang (BEL)
    onInput*: proc (data: string)
      ## what is typed into a terminal with no program in it (the bytes a program would get)
    onTitle*: proc (title: string)
      ## the program named its window
    running*: bool           ## a program is in it (`spawn`) and has not ended
    exitCode*: int           ## how it ended (-1: by a signal; its number in `exitSignal`)
    exitSignal*: int
    error*: string           ## why `spawn` failed
    # the screens
    main, alt: seq[TermLine]
    onAlt: bool
    sb: Deque[TermLine]      # (what scrolled off the main screen, the oldest first)
    cx, cy: int
    wrapNext: bool
    pen: TermCell
    saved: array[2, tuple[cx, cy: int; pen: TermCell; g0, g1, gl: int; origin: bool]]
    top, bottom: int         # (the scroll region, rows inclusive)
    tabs: seq[bool]
    # modes
    appCursor, appKeypad, autowrap, cursorOn, bracketed, origin, insertMode: bool
    mouseMode: int           # (0 none, 1000 clicks, 1002 drags too, 1003 every move)
    mouseSgr: bool
    cursorShape*: int        ## (DECSCUSR: 0-2 a block, 3-4 a line under, 5-6 a bar)
    g0, g1, gl: int          # (the character sets: 0 ASCII, 1 the line-drawing one; which is in use)
    lastCh: int32
    # the parser
    state: ParseState
    params: seq[int]
    subs: seq[bool]          # (each parameter after a colon)
    private: char
    inter: string
    osc: string
    utfNeed, utfCp: int
    # the program
    fd: cint
    pid: int
    when defined(windows):
      hpc, hin, hout, hproc: pointer
    inbuf, outbuf: string
    # the view
    viewTop: int             # (pixels scrolled back from the bottom: 0 follows what comes)
    pushed: int              # (lines scrolled off since the view last looked)
    selA, selB: tuple[line, col: int]   # (the chosen text: lines counted from the oldest kept)
    selOn, selecting: bool
    mouseDownAt: int
    lastMouseCell: tuple[col, row: int]
    ver: int

const
  Blank = TermCell()
  DarkColors* = TermColors(
    fg: Color(r: 214, g: 214, b: 214, a: 255), bg: Color(r: 24, g: 24, b: 28, a: 255),
    cursor: Color(r: 230, g: 230, b: 230, a: 255), selection: Color(r: 60, g: 90, b: 150, a: 255),
    ansi: [Color(r: 0, g: 0, b: 0, a: 255), Color(r: 205, g: 49, b: 49, a: 255),
           Color(r: 13, g: 188, b: 121, a: 255), Color(r: 229, g: 229, b: 16, a: 255),
           Color(r: 36, g: 114, b: 200, a: 255), Color(r: 188, g: 63, b: 188, a: 255),
           Color(r: 17, g: 168, b: 205, a: 255), Color(r: 229, g: 229, b: 229, a: 255),
           Color(r: 102, g: 102, b: 102, a: 255), Color(r: 241, g: 76, b: 76, a: 255),
           Color(r: 35, g: 209, b: 139, a: 255), Color(r: 245, g: 245, b: 67, a: 255),
           Color(r: 59, g: 142, b: 234, a: 255), Color(r: 214, g: 112, b: 214, a: 255),
           Color(r: 41, g: 184, b: 219, a: 255), Color(r: 255, g: 255, b: 255, a: 255)])
    ## A dark terminal's colors.
  LightColors* = TermColors(
    fg: Color(r: 30, g: 30, b: 30, a: 255), bg: Color(r: 255, g: 255, b: 255, a: 255),
    cursor: Color(r: 30, g: 30, b: 30, a: 255), selection: Color(r: 173, g: 214, b: 255, a: 255),
    ansi: [Color(r: 0, g: 0, b: 0, a: 255), Color(r: 205, g: 49, b: 49, a: 255),
           Color(r: 0, g: 140, b: 70, a: 255), Color(r: 150, g: 120, b: 0, a: 255),
           Color(r: 4, g: 81, b: 165, a: 255), Color(r: 188, g: 5, b: 188, a: 255),
           Color(r: 5, g: 130, b: 160, a: 255), Color(r: 85, g: 85, b: 85, a: 255),
           Color(r: 102, g: 102, b: 102, a: 255), Color(r: 205, g: 49, b: 49, a: 255),
           Color(r: 20, g: 160, b: 90, a: 255), Color(r: 160, g: 130, b: 0, a: 255),
           Color(r: 4, g: 81, b: 165, a: 255), Color(r: 188, g: 5, b: 188, a: 255),
           Color(r: 5, g: 130, b: 160, a: 255), Color(r: 30, g: 30, b: 30, a: 255)])
    ## A light terminal's colors (yellow and white dark enough to read on white).
  LineChars = [0x25C6'i32, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0x00B0, 0x00B1, 0x2424, 0x240B,
               0x2518, 0x2510, 0x250C, 0x2514, 0x253C, 0x23BA, 0x23BB, 0x2500, 0x23BC, 0x23BD,
               0x251C, 0x2524, 0x2534, 0x252C, 0x2502, 0x2264, 0x2265, 0x03C0, 0x2260, 0x00A3, 0x00B7]
    ## (the DEC line-drawing set, ` to ~)

# ---- cells and lines -------------------------------------------------------------------------

proc charWidth*(c: int32): int =
  ## How many cells a character takes: 2 for the wide ones (Chinese, Japanese, Korean, most
  ## emoji), 0 for a mark that goes on the one before, else 1.
  let c = int(c)
  if c < 0x300: return 1
  if (c >= 0x300 and c <= 0x36F) or (c >= 0x483 and c <= 0x489) or (c >= 0x591 and c <= 0x5BD) or
     (c >= 0x610 and c <= 0x61A) or (c >= 0x64B and c <= 0x65F) or c == 0x670 or
     (c >= 0x6D6 and c <= 0x6DC) or (c >= 0x6DF and c <= 0x6E4) or (c >= 0x900 and c <= 0x902) or
     c == 0x93C or (c >= 0x941 and c <= 0x948) or c == 0x94D or (c >= 0xE31 and c <= 0xE3A and c != 0xE32 and c != 0xE33) or
     (c >= 0xE47 and c <= 0xE4E) or (c >= 0x1AB0 and c <= 0x1AFF) or (c >= 0x1DC0 and c <= 0x1DFF) or
     (c >= 0x200B and c <= 0x200F) or (c >= 0x20D0 and c <= 0x20FF) or (c >= 0xFE00 and c <= 0xFE0F) or
     (c >= 0xFE20 and c <= 0xFE2F) or c == 0xFEFF or (c >= 0xE0100 and c <= 0xE01EF):
    return 0
  if (c >= 0x1100 and c <= 0x115F) or c == 0x2329 or c == 0x232A or (c >= 0x231A and c <= 0x231B) or
     (c >= 0x23E9 and c <= 0x23EC) or c == 0x23F0 or c == 0x23F3 or (c >= 0x25FD and c <= 0x25FE) or
     (c >= 0x2614 and c <= 0x2615) or (c >= 0x2648 and c <= 0x2653) or c == 0x267F or c == 0x2693 or
     c == 0x26A1 or (c >= 0x26AA and c <= 0x26AB) or (c >= 0x26BD and c <= 0x26BE) or
     (c >= 0x26C4 and c <= 0x26C5) or c == 0x26CE or c == 0x26D4 or c == 0x26EA or
     (c >= 0x26F2 and c <= 0x26F3) or c == 0x26F5 or c == 0x26FA or c == 0x26FD or c == 0x2705 or
     (c >= 0x270A and c <= 0x270B) or c == 0x2728 or c == 0x274C or c == 0x274E or
     (c >= 0x2753 and c <= 0x2755) or c == 0x2757 or (c >= 0x2795 and c <= 0x2797) or c == 0x27B0 or
     c == 0x27BF or (c >= 0x2B1B and c <= 0x2B1C) or c == 0x2B50 or c == 0x2B55 or
     (c >= 0x2E80 and c <= 0x303E) or (c >= 0x3041 and c <= 0x33FF) or (c >= 0x3400 and c <= 0x4DBF) or
     (c >= 0x4E00 and c <= 0x9FFF) or (c >= 0xA000 and c <= 0xA4CF) or (c >= 0xA960 and c <= 0xA97F) or
     (c >= 0xAC00 and c <= 0xD7A3) or (c >= 0xF900 and c <= 0xFAFF) or (c >= 0xFE10 and c <= 0xFE19) or
     (c >= 0xFE30 and c <= 0xFE6F) or (c >= 0xFF00 and c <= 0xFF60) or (c >= 0xFFE0 and c <= 0xFFE6) or
     (c >= 0x16FE0 and c <= 0x18AFF) or (c >= 0x1B000 and c <= 0x1B2FF) or c == 0x1F004 or c == 0x1F0CF or
     c == 0x1F18E or (c >= 0x1F191 and c <= 0x1F19A) or (c >= 0x1F200 and c <= 0x1F251) or
     (c >= 0x1F300 and c <= 0x1F320) or (c >= 0x1F32D and c <= 0x1F335) or (c >= 0x1F337 and c <= 0x1F37C) or
     (c >= 0x1F37E and c <= 0x1F393) or (c >= 0x1F3A0 and c <= 0x1F3CA) or (c >= 0x1F3CF and c <= 0x1F3D3) or
     (c >= 0x1F3E0 and c <= 0x1F3F0) or c == 0x1F3F4 or (c >= 0x1F3F8 and c <= 0x1F43E) or c == 0x1F440 or
     (c >= 0x1F442 and c <= 0x1F4FC) or (c >= 0x1F4FF and c <= 0x1F53D) or (c >= 0x1F54B and c <= 0x1F54E) or
     (c >= 0x1F550 and c <= 0x1F567) or c == 0x1F57A or (c >= 0x1F595 and c <= 0x1F596) or c == 0x1F5A4 or
     (c >= 0x1F5FB and c <= 0x1F64F) or (c >= 0x1F680 and c <= 0x1F6C5) or c == 0x1F6CC or
     (c >= 0x1F6D0 and c <= 0x1F6D2) or (c >= 0x1F6D5 and c <= 0x1F6D7) or (c >= 0x1F6EB and c <= 0x1F6EC) or
     (c >= 0x1F6F4 and c <= 0x1F6FC) or (c >= 0x1F7E0 and c <= 0x1F7EB) or (c >= 0x1F90C and c <= 0x1F93A) or
     (c >= 0x1F93C and c <= 0x1F945) or (c >= 0x1F947 and c <= 0x1F9FF) or (c >= 0x1FA70 and c <= 0x1FAFF) or
     (c >= 0x20000 and c <= 0x3FFFD):
    return 2
  1

proc blankLine(n: int; bg: uint32 = 0): TermLine =
  result.cells = newSeq[TermCell](n)
  if bg != 0:
    for c in result.cells.mitems: c.bg = bg

proc screen(t: Terminal): var seq[TermLine] {.inline.} =
  if t.onAlt: return t.alt
  t.main

proc erased(t: Terminal): TermCell {.inline.} =
  ## (a cell erased now: blank, in the pen's background -- as xterm erases)
  TermCell(bg: t.pen.bg)

proc resetTabs(t: Terminal) =
  t.tabs = newSeq[bool](t.cols)
  for i in countup(8, t.cols - 1, 8): t.tabs[i] = true

proc newTerminal*(cols = 80; rows = 24; scrollback = 10_000): Terminal =
  ## A terminal of `cols` x `rows` cells (the view sizes it to its box), keeping `scrollback`
  ## lines that scrolled off.
  result = Terminal(cols: max(2, cols), rows: max(1, rows), maxScrollback: scrollback, autowrap: true,
                    cursorOn: true, themed: true, fontSize: 1.0, fd: -1, colors: DarkColors)
  for i in 0 ..< result.rows:
    result.main.add blankLine(result.cols)
    result.alt.add blankLine(result.cols)
  result.bottom = result.rows - 1
  result.resetTabs()

proc scrollbackLines*(t: Terminal): int = t.sb.len
  ## How many lines that scrolled off are kept.

proc line*(t: Terminal; row: int): TermLine =
  ## Row `row` of the screen shown now (0 the top).
  t.screen[clamp(row, 0, t.rows - 1)]

proc scrolledLine*(t: Terminal; i: int): TermLine =
  ## Line `i` of those that scrolled off (0 the oldest kept).
  t.sb[i]

proc cell*(t: Terminal; col, row: int): TermCell =
  ## The cell at `col`, `row` of the screen shown now.
  let l = t.line(row)
  if col >= 0 and col < l.cells.len: l.cells[col] else: Blank

proc cursor*(t: Terminal): tuple[col, row: int] = (t.cx, t.cy)
  ## Where the cursor is.

proc onAltScreen*(t: Terminal): bool = t.onAlt
  ## A full-screen program draws on the other screen now (its own: what was there comes back
  ## when it ends).

proc lineText(l: TermLine): string =
  for c in l.cells:
    if c.ch > 0: result.add Rune(c.ch).toUtf8
    elif c.ch == 0: result.add ' '

proc text*(t: Terminal; row: int): string =
  ## The text of row `row` of the screen, its blanks at the end left out.
  t.line(row).lineText.strip(leading = false)

proc screenText*(t: Terminal): string =
  ## The screen's text, a line a row (the blanks at their ends left out).
  for r in 0 ..< t.rows:
    if r > 0: result.add '\n'
    result.add t.text(r)

# ---- what the program does to the screen -----------------------------------------------------

proc pushScrollback(t: Terminal; l: sink TermLine) =
  if t.maxScrollback <= 0: return
  t.sb.addLast l
  while t.sb.len > t.maxScrollback:
    discard t.sb.popFirst()
    # (the chosen text counted from the oldest kept: one up; gone past the top)
    dec t.selA.line
    dec t.selB.line
    if t.selA.line < 0 or t.selB.line < 0: t.selOn = false

proc scrollUp(t: Terminal; n: int) =
  ## (the scroll region up `n` lines, blank ones at its bottom; off the top of the whole main
  ## screen, into what is kept)
  let n = clamp(n, 1, t.bottom - t.top + 1)
  template s: untyped = t.screen
  for k in 0 ..< n:
    let gone = move s[t.top]
    for r in t.top ..< t.bottom: s[r] = move s[r + 1]
    s[t.bottom] = blankLine(t.cols, t.pen.bg)
    if not t.onAlt and t.top == 0: t.pushScrollback(gone)
  if not t.onAlt and t.top == 0: t.pushed += n     # (a view scrolled back stays put: `terminalView`)
  inc t.ver

proc scrollDown(t: Terminal; n: int) =
  let n = clamp(n, 1, t.bottom - t.top + 1)
  template s: untyped = t.screen
  for k in 0 ..< n:
    for r in countdown(t.bottom, t.top + 1): s[r] = move s[r - 1]
    s[t.top] = blankLine(t.cols, t.pen.bg)
  inc t.ver

proc lineFeed(t: Terminal) =
  t.wrapNext = false
  if t.cy == t.bottom: t.scrollUp(1)
  elif t.cy < t.rows - 1: inc t.cy

proc reverseIndex(t: Terminal) =
  t.wrapNext = false
  if t.cy == t.top: t.scrollDown(1)
  elif t.cy > 0: dec t.cy

proc moveTo(t: Terminal; col, row: int) =
  ## (the cursor to `col`, `row`; in origin mode the rows are the scroll region's)
  t.wrapNext = false
  t.cx = clamp(col, 0, t.cols - 1)
  if t.origin: t.cy = clamp(row + t.top, t.top, t.bottom)
  else: t.cy = clamp(row, 0, t.rows - 1)

proc eraseCells(t: Terminal; row, a, b: int) =
  ## (cells `a` ..< `b` of `row` erased)
  if row < 0 or row >= t.rows: return
  let e = t.erased()
  for c in max(0, a) ..< min(t.cols, b): t.screen[row].cells[c] = e
  if b >= t.cols: t.screen[row].wrapped = false
  inc t.ver

proc fullReset(t: Terminal) =
  t.pen = Blank
  t.onAlt = false
  for l in t.main.mitems: l = blankLine(t.cols)
  for l in t.alt.mitems: l = blankLine(t.cols)
  t.cx = 0
  t.cy = 0
  t.wrapNext = false
  t.top = 0
  t.bottom = t.rows - 1
  t.appCursor = false
  t.appKeypad = false
  t.autowrap = true
  t.cursorOn = true
  t.bracketed = false
  t.origin = false
  t.insertMode = false
  t.mouseMode = 0
  t.mouseSgr = false
  t.g0 = 0
  t.g1 = 0
  t.gl = 0
  t.resetTabs()
  inc t.ver

proc saveCursor(t: Terminal) =
  t.saved[ord(t.onAlt)] = (t.cx, t.cy, t.pen, t.g0, t.g1, t.gl, t.origin)

proc restoreCursor(t: Terminal) =
  let s = t.saved[ord(t.onAlt)]
  t.cx = clamp(s.cx, 0, t.cols - 1)
  t.cy = clamp(s.cy, 0, t.rows - 1)
  t.pen = s.pen
  t.g0 = s.g0
  t.g1 = s.g1
  t.gl = s.gl
  t.origin = s.origin
  t.wrapNext = false

proc useAlt(t: Terminal; on: bool; clear: bool) =
  if on == t.onAlt: return
  t.onAlt = on
  if on and clear:
    for l in t.alt.mitems: l = blankLine(t.cols)
  t.top = 0
  t.bottom = t.rows - 1
  t.viewTop = 0
  t.selOn = false
  inc t.ver

proc put(t: Terminal; c: int32) =
  ## (a character the program wrote, at the cursor)
  var c = c
  let set = if t.gl == 0: t.g0 else: t.g1
  if set == 1 and c >= 0x60 and c <= 0x7E: c = LineChars[c - 0x60]
  let w = charWidth(c)
  if w == 0:
    return                            # (a mark on the character before: not drawn here)
  if t.wrapNext and t.autowrap:
    t.screen[t.cy].wrapped = true
    t.cx = 0
    t.lineFeed()
  t.wrapNext = false
  if w == 2 and t.cx == t.cols - 1:
    # (no room for both halves: on the next line)
    if t.autowrap:
      t.screen[t.cy].cells[t.cx] = t.erased()
      t.screen[t.cy].wrapped = true
      t.cx = 0
      t.lineFeed()
    else: return
  template row: untyped = t.screen[t.cy].cells
  if t.insertMode:
    for k in countdown(t.cols - 1, t.cx + w): row[k] = row[k - w]
  # (half of a wide one written over: the other half blank)
  if row[t.cx].ch == -1 and t.cx > 0: row[t.cx - 1].ch = 0
  if t.cx + w < t.cols and row[t.cx + w].ch == -1: row[t.cx + w].ch = 0
  var cell = t.pen
  cell.ch = c
  row[t.cx] = cell
  if w == 2:
    cell.ch = -1
    row[t.cx + 1] = cell
  t.lastCh = c
  t.cx += w
  if t.cx >= t.cols:
    t.cx = t.cols - 1
    t.wrapNext = true
  inc t.ver

proc tabForward(t: Terminal; n = 1) =
  for k in 0 ..< max(1, n):
    var x = t.cx + 1
    while x < t.cols - 1 and not t.tabs[x]: inc x
    t.cx = min(x, t.cols - 1)
  t.wrapNext = false

proc tabBack(t: Terminal; n = 1) =
  for k in 0 ..< max(1, n):
    var x = t.cx - 1
    while x > 0 and not t.tabs[x]: dec x
    t.cx = max(0, x)
  t.wrapNext = false

proc control(t: Terminal; b: char) =
  case b
  of '\a':
    inc t.bells
  of '\b':
    if t.wrapNext: t.wrapNext = false
    elif t.cx > 0: dec t.cx
  of '\t': t.tabForward()
  of '\n', '\v', '\f': t.lineFeed()
  of '\r':
    t.cx = 0
    t.wrapNext = false
  of '\x0E': t.gl = 1
  of '\x0F': t.gl = 0
  else: discard

proc param(t: Terminal; i: int; default = 0): int {.inline.} =
  ## (CSI parameter `i`, `default` when it is missing or 0 -- as most take it)
  if i < t.params.len and t.params[i] > 0: t.params[i] else: default

proc answer(t: Terminal; s: string) =
  ## (what the terminal says back to the program: a cursor's place, what it is)
  t.outbuf.add s

proc colorParam(t: Terminal; i: var int): uint32 =
  ## (38/48's color: 5;n or 2;r;g;b, with colons or semicolons; `i` at the 38, left at the last
  ## parameter used)
  if i + 1 >= t.params.len: return 0
  let kind = t.params[i + 1]
  if kind == 5 and i + 2 < t.params.len:
    i += 2
    return 0x1000000'u32 + uint32(clamp(t.params[i], 0, 255))
  if kind == 2:
    # (38:2::r:g:b -- a color space first, empty -- or 38;2;r;g;b)
    var j = i + 2
    let colons = i + 1 < t.subs.len and t.subs[i + 1]
    if colons and j + 3 < t.params.len and t.subs[j + 3]: inc j
    if j + 2 < t.params.len:
      i = j + 2
      return 0x2000000'u32 or (uint32(clamp(t.params[j], 0, 255)) shl 16) or
             (uint32(clamp(t.params[j + 1], 0, 255)) shl 8) or uint32(clamp(t.params[j + 2], 0, 255))
  i += 1
  0

proc sgr(t: Terminal) =
  if t.params.len == 0:
    t.pen = Blank
    return
  var i = 0
  while i < t.params.len:
    let p = t.params[i]
    case p
    of 0:
      let ch = t.pen.ch
      t.pen = Blank
      t.pen.ch = ch
    of 1: t.pen.attrs.incl taBold
    of 2: t.pen.attrs.incl taFaint
    of 3: t.pen.attrs.incl taItalic
    of 4:
      if i + 1 < t.subs.len and t.subs[i + 1]:
        # (4:0 none, 4:n a kind of line under: one is drawn)
        inc i
        if t.params[i] == 0: t.pen.attrs.excl taUnderline else: t.pen.attrs.incl taUnderline
      else: t.pen.attrs.incl taUnderline
    of 5, 6: t.pen.attrs.incl taBlink
    of 7: t.pen.attrs.incl taInverse
    of 8: t.pen.attrs.incl taHidden
    of 9: t.pen.attrs.incl taStrike
    of 21: t.pen.attrs.incl taUnderline
    of 22: t.pen.attrs = t.pen.attrs - {taBold, taFaint}
    of 23: t.pen.attrs.excl taItalic
    of 24: t.pen.attrs.excl taUnderline
    of 25: t.pen.attrs.excl taBlink
    of 27: t.pen.attrs.excl taInverse
    of 28: t.pen.attrs.excl taHidden
    of 29: t.pen.attrs.excl taStrike
    of 30 .. 37: t.pen.fg = 0x1000000'u32 + uint32(p - 30)
    of 38: t.pen.fg = t.colorParam(i)
    of 39: t.pen.fg = 0
    of 40 .. 47: t.pen.bg = 0x1000000'u32 + uint32(p - 40)
    of 48: t.pen.bg = t.colorParam(i)
    of 49: t.pen.bg = 0
    of 58: discard t.colorParam(i)        # (the line under's color: drawn in the text's)
    of 90 .. 97: t.pen.fg = 0x1000000'u32 + uint32(p - 90 + 8)
    of 100 .. 107: t.pen.bg = 0x1000000'u32 + uint32(p - 100 + 8)
    else: discard
    inc i

proc setMode(t: Terminal; on: bool) =
  if t.private == '?':
    for p in t.params:
      case p
      of 1: t.appCursor = on
      of 6:
        t.origin = on
        t.moveTo(0, 0)
      of 7: t.autowrap = on
      of 25: t.cursorOn = on
      of 47, 1047: t.useAlt(on, clear = on and p == 1047)
      of 1048:
        if on: t.saveCursor() else: t.restoreCursor()
      of 1049:
        if on:
          t.saveCursor()
          t.useAlt(true, clear = true)
          t.saveCursor()
        else:
          t.useAlt(false, clear = false)
          t.restoreCursor()
      of 1000, 1002, 1003: t.mouseMode = if on: p else: 0
      of 1006: t.mouseSgr = on
      of 2004: t.bracketed = on
      else: discard
  else:
    for p in t.params:
      if p == 4: t.insertMode = on

proc csi(t: Terminal; final: char) =
  let n = t.param(0, 1)
  if t.inter == " " and final == 'q':
    t.cursorShape = t.param(0, 0)
    return
  if t.inter == "!" and final == 'p':
    # (a soft reset: the modes, the pen, the region; the screen kept)
    t.pen = Blank
    t.top = 0
    t.bottom = t.rows - 1
    t.origin = false
    t.autowrap = true
    t.cursorOn = true
    t.insertMode = false
    t.appCursor = false
    return
  if t.inter.len > 0: return
  case final
  of '@':
    if t.private == '\0':
      let row = addr t.screen[t.cy].cells
      for k in countdown(t.cols - 1, t.cx + n):
        row[][k] = row[][k - n]
      t.eraseCells(t.cy, t.cx, min(t.cols, t.cx + n))
  of 'A': t.moveTo(t.cx, (if t.origin: t.cy - t.top else: t.cy) - n)
  of 'B', 'e': t.moveTo(t.cx, (if t.origin: t.cy - t.top else: t.cy) + n)
  of 'C', 'a': t.moveTo(t.cx + n, if t.origin: t.cy - t.top else: t.cy)
  of 'D': t.moveTo(t.cx - n, if t.origin: t.cy - t.top else: t.cy)
  of 'E': t.moveTo(0, (if t.origin: t.cy - t.top else: t.cy) + n)
  of 'F': t.moveTo(0, (if t.origin: t.cy - t.top else: t.cy) - n)
  of 'G', '`': t.moveTo(n - 1, if t.origin: t.cy - t.top else: t.cy)
  of 'H', 'f': t.moveTo(t.param(1, 1) - 1, n - 1)
  of 'I': t.tabForward(n)
  of 'J':
    case t.param(0, 0)
    of 0:
      t.eraseCells(t.cy, t.cx, t.cols)
      for r in t.cy + 1 ..< t.rows: t.eraseCells(r, 0, t.cols)
    of 1:
      for r in 0 ..< t.cy: t.eraseCells(r, 0, t.cols)
      t.eraseCells(t.cy, 0, t.cx + 1)
    of 2:
      for r in 0 ..< t.rows: t.eraseCells(r, 0, t.cols)
    of 3:
      t.sb.clear()
      t.viewTop = 0
      t.selOn = false
    else: discard
  of 'K':
    case t.param(0, 0)
    of 0: t.eraseCells(t.cy, t.cx, t.cols)
    of 1: t.eraseCells(t.cy, 0, t.cx + 1)
    of 2: t.eraseCells(t.cy, 0, t.cols)
    else: discard
  of 'L', 'M':
    if t.cy >= t.top and t.cy <= t.bottom:
      let keep = t.top
      t.top = t.cy
      if final == 'L': t.scrollDown(n) else:
        # (lines deleted here are not what scrolled off the screen)
        let n2 = clamp(n, 1, t.bottom - t.top + 1)
        for k in 0 ..< n2:
          for r in t.top ..< t.bottom: t.screen[r] = move t.screen[r + 1]
          t.screen[t.bottom] = blankLine(t.cols, t.pen.bg)
      t.top = keep
      t.cx = 0
      t.wrapNext = false
  of 'P':
    let row = addr t.screen[t.cy].cells
    let k = min(n, t.cols - t.cx)
    for c in t.cx ..< t.cols - k: row[][c] = row[][c + k]
    t.eraseCells(t.cy, t.cols - k, t.cols)
  of 'S':
    if t.private == '\0': t.scrollUp(n)
  of 'T':
    if t.private == '\0' and t.params.len <= 1: t.scrollDown(n)
  of 'X': t.eraseCells(t.cy, t.cx, t.cx + n)
  of 'Z': t.tabBack(n)
  of 'b':
    if t.lastCh > 0:
      for k in 0 ..< min(n, 65535): t.put(t.lastCh)
  of 'c':
    if t.private == '>': t.answer("\e[>0;10;1c")
    elif t.private == '\0': t.answer("\e[?62;22c")
  of 'd': t.moveTo(t.cx, n - 1)
  of 'g':
    case t.param(0, 0)
    of 0:
      if t.cx < t.tabs.len: t.tabs[t.cx] = false
    of 3:
      for x in t.tabs.mitems: x = false
    else: discard
  of 'h': t.setMode(true)
  of 'l': t.setMode(false)
  of 'm':
    if t.private == '\0': t.sgr()
  of 'n':
    if t.private == '\0':
      case t.param(0, 0)
      of 5: t.answer("\e[0n")
      of 6: t.answer("\e[" & $((if t.origin: t.cy - t.top else: t.cy) + 1) & ";" & $(t.cx + 1) & "R")
      else: discard
  of 'r':
    if t.private == '\0':
      let a = t.param(0, 1) - 1
      let b = t.param(1, t.rows) - 1
      if a < b and b < t.rows:
        t.top = a
        t.bottom = b
        t.moveTo(0, 0)
  of 's':
    if t.private == '\0' and t.params.len == 0: t.saveCursor()
  of 'u':
    if t.private == '\0': t.restoreCursor()
  of 't':
    if t.param(0, 0) == 18: t.answer("\e[8;" & $t.rows & ";" & $t.cols & "t")
  else: discard

proc oscDone(t: Terminal) =
  let semi = t.osc.find(';')
  if semi < 0: return
  let what = t.osc[0 ..< semi]
  let v = t.osc[semi + 1 .. ^1]
  case what
  of "0", "2":
    t.title = v
    if t.onTitle != nil: t.onTitle(v)
  of "7":
    # (file://host/path: the folder the shell is in)
    if v.startsWith("file://"):
      let p = v.find('/', 7)
      if p >= 0: t.cwd = decodeUrl(v[p .. ^1])
  else: discard

proc escDispatch(t: Terminal; b: char) =
  case b
  of '[':
    t.state = psCsi
    t.params.setLen(0)
    t.subs.setLen(0)
    t.private = '\0'
    t.inter.setLen(0)
    return
  of ']':
    t.state = psOsc
    t.osc.setLen(0)
    return
  of 'P', 'X', '^', '_':
    t.state = psStr
    return
  of '(', ')':
    t.inter = $b
    t.state = psCharset
    return
  of '*', '+':
    t.inter = "x"                       # (G2, G3: taken and left)
    t.state = psCharset
    return
  of '#':
    t.state = psEscHash
    return
  of '7': t.saveCursor()
  of '8': t.restoreCursor()
  of 'D': t.lineFeed()
  of 'E':
    t.cx = 0
    t.lineFeed()
  of 'M': t.reverseIndex()
  of 'H':
    if t.cx < t.tabs.len: t.tabs[t.cx] = true
  of 'c': t.fullReset()
  of '=': t.appKeypad = true
  of '>': t.appKeypad = false
  else: discard
  t.state = psGround

proc feedByte(t: Terminal; b: char) =
  case t.state
  of psGround:
    if t.utfNeed > 0:
      if (ord(b) and 0xC0) == 0x80:
        t.utfCp = (t.utfCp shl 6) or (ord(b) and 0x3F)
        dec t.utfNeed
        if t.utfNeed == 0: t.put(int32(t.utfCp))
        return
      t.utfNeed = 0
      t.put(0xFFFD)                     # (a sequence cut short)
    let o = ord(b)
    if o < 0x20:
      if b == '\e': t.state = psEsc
      else: t.control(b)
    elif o < 0x7F: t.put(int32(o))
    elif o == 0x7F: discard
    elif (o and 0xE0) == 0xC0:
      t.utfNeed = 1
      t.utfCp = o and 0x1F
    elif (o and 0xF0) == 0xE0:
      t.utfNeed = 2
      t.utfCp = o and 0x0F
    elif (o and 0xF8) == 0xF0:
      t.utfNeed = 3
      t.utfCp = o and 0x07
    else: t.put(0xFFFD)
  of psEsc:
    if ord(b) < 0x20:
      if b == '\e': discard
      else: t.control(b)
    else: t.escDispatch(b)
  of psEscHash:
    if b == '8':
      # (DECALN: the screen filled with E)
      for r in 0 ..< t.rows:
        for c in 0 ..< t.cols: t.screen[r].cells[c] = TermCell(ch: int32('E'))
      inc t.ver
    t.state = psGround
  of psCharset:
    let set = if b == '0': 1 else: 0
    if t.inter == "(": t.g0 = set
    elif t.inter == ")": t.g1 = set
    t.inter.setLen(0)
    t.state = psGround
  of psCsi:
    case b
    of '0' .. '9':
      if t.params.len == 0:
        t.params.add 0
        t.subs.add false
      t.params[^1] = min(t.params[^1] * 10 + (ord(b) - ord('0')), 1_000_000)
    of ';', ':':
      if t.params.len == 0:
        t.params.add 0
        t.subs.add false
      t.params.add 0
      t.subs.add b == ':'
    of '?', '>', '<', '=':
      if t.params.len == 0 and t.inter.len == 0: t.private = b
    of ' ' .. '/':
      t.inter.add b
    of '@' .. '~':
      t.csi(b)
      t.state = psGround
    of '\e': t.state = psEsc
    else:
      if ord(b) < 0x20: t.control(b)
      else: t.state = psGround
  of psOsc:
    case b
    of '\a':
      t.oscDone()
      t.state = psGround
    of '\e': t.state = psOscEsc
    else:
      if t.osc.len < 4096: t.osc.add b
  of psOscEsc:
    t.oscDone()
    t.state = psGround
    if b != '\\': t.escDispatch(b)
  of psStr:
    if b == '\e': t.state = psStrEsc
    elif b == '\a': t.state = psGround
  of psStrEsc:
    t.state = if b == '\\': psGround else: psStr

proc feed*(t: Terminal; data: string) =
  ## `data` written to the terminal, as a program writes it: text, and the escape sequences
  ## that move the cursor, color, erase, scroll.
  for b in data: t.feedByte(b)

proc takeAnswers*(t: Terminal): string =
  ## What the terminal said back to the program since (the cursor's place asked for, what kind
  ## of terminal it is): sent to the program by itself when there is one.
  result = move t.outbuf
  t.outbuf = ""

proc resize*(t: Terminal; cols, rows: int) =
  ## The screen made `cols` x `rows` cells (the view does it as its box changes): lines cut or
  ## made longer; fewer rows, the top ones scroll off -- the cursor's row stays in sight; the
  ## program is told (SIGWINCH).
  let cols = max(2, cols)
  let rows = max(1, rows)
  if cols == t.cols and rows == t.rows: return
  for which in 0 .. 1:
    let sp = if which == 0: addr t.main else: addr t.alt
    template s: untyped = sp[]
    let onIt = (which == 1) == t.onAlt
    if rows < t.rows:
      # (the rows under the cursor go first, then the top ones scroll off)
      var extra = t.rows - rows
      while extra > 0 and s.len > 1 and (not onIt or s.len - 1 > t.cy):
        var blank = true
        for c in s[^1].cells:
          if c.ch != 0: blank = false
        if not blank: break
        s.setLen(s.len - 1)
        dec extra
      while extra > 0:
        let l = s[0]
        s.delete(0)
        if which == 0: t.pushScrollback(l)
        if onIt: t.cy = max(0, t.cy - 1)
        dec extra
    while s.len < rows: s.add blankLine(cols)
    for l in s.mitems:
      l.cells.setLen(cols)
      if cols < t.cols and l.cells[^1].ch == -1 and cols >= 2: l.cells[^1].ch = 0
  t.cols = cols
  t.rows = rows
  t.cx = min(t.cx, cols - 1)
  t.cy = min(t.cy, rows - 1)
  t.top = 0
  t.bottom = rows - 1
  t.wrapNext = false
  t.resetTabs()
  inc t.ver
  when hasPty:
    if t.fd >= 0:
      var ws: Winsize
      ws.ws_row = cushort(rows)
      ws.ws_col = cushort(cols)
      discard ioctl(t.fd, TIOCSWINSZ, addr ws)
  elif hasConPty:
    if t.hpc != nil: discard conPty.resize(t.hpc, Coord(x: int16(cols), y: int16(rows)))

# ---- the program in it ------------------------------------------------------------------------

var liveTerms: seq[Terminal]         ## (the terminals with a program, read by the window's wait)
var waitHooked = false

when hasPty:
  proc reap(t: Terminal) =
    ## (the program ended: how; the terminal let go of it)
    if t.pid > 0:
      var st: cint
      let r = waitpid(Pid(t.pid), st, WNOHANG)
      if r == Pid(t.pid):
        if WIFEXITED(st): t.exitCode = int(WEXITSTATUS(st))
        elif WIFSIGNALED(st):
          t.exitCode = -1
          t.exitSignal = int(WTERMSIG(st))
        t.pid = 0
      elif r == 0: return               # (still there: its end read again later)
      else: t.pid = 0
    if t.fd >= 0:
      discard posix.close(t.fd)
      t.fd = -1
    t.running = false
    let i = liveTerms.find(t)
    if i >= 0: liveTerms.delete(i)
    inc t.ver

  proc pump(t: Terminal): bool =
    ## (what the program wrote, read into `inbuf`; true when something came or it ended)
    if t.fd < 0:
      if t.running and t.pid > 0: t.reap()
      return false
    var buf: array[16384, char]
    while t.inbuf.len < 8 shl 20:
      let n = read(t.fd, addr buf[0], buf.len)
      if n > 0:
        let at = t.inbuf.len
        t.inbuf.setLen(at + n)
        copyMem(addr t.inbuf[at], addr buf[0], n)
        result = true
      elif n == 0 or (n < 0 and errno != EAGAIN and errno != EWOULDBLOCK and errno != EINTR):
        # (its end of the terminal closed: it ended)
        discard posix.close(t.fd)
        t.fd = -1
        t.reap()
        return true
      else: break

  proc flushOut(t: Terminal) =
    while t.fd >= 0 and t.outbuf.len > 0:
      let n = write(t.fd, addr t.outbuf[0], t.outbuf.len)
      if n > 0: t.outbuf.delete(0 .. n - 1)
      else: break

  proc waitFds(): seq[cint] {.nimcall, gcsafe.} =
    {.cast(gcsafe).}:
      for t in liveTerms:
        if t.fd >= 0 and t.inbuf.len < 8 shl 20: result.add t.fd

  proc waitReady(): bool {.nimcall, gcsafe.} =
    {.cast(gcsafe).}:
      var i = 0
      while i < liveTerms.len:
        let t = liveTerms[i]
        if t.pump(): result = true
        if i < liveTerms.len and liveTerms[i] == t: inc i
elif hasConPty:
  proc reap(t: Terminal) =
    ## (the program ended, or is let go of: how it ended; the pseudo-console and the pipes closed)
    if t.hproc != nil:
      var code: int32
      if GetExitCodeProcess(t.hproc, addr code) != 0: t.exitCode = int(code)
      discard CloseHandle(t.hproc)
      t.hproc = nil
    if t.hpc != nil:
      conPty.close(t.hpc)
      t.hpc = nil
    for h in [addr t.hin, addr t.hout]:
      if h[] != nil:
        discard CloseHandle(h[])
        h[] = nil
    t.running = false
    let i = liveTerms.find(t)
    if i >= 0: liveTerms.delete(i)
    inc t.ver

  proc pump(t: Terminal): bool =
    ## (what the program wrote, read into `inbuf` -- only what is there: nothing waits; true when
    ## something came or it ended)
    if t.hout == nil: return false
    var buf: array[16384, char]
    while t.inbuf.len < 8 shl 20:
      var avail: int32
      if PeekNamedPipe(t.hout, nil, 0, nil, addr avail, nil) == 0:
        t.reap()
        return true
      if avail <= 0: break
      var got: int32
      if ReadFile(t.hout, addr buf[0], min(avail, int32(buf.len)), addr got, nil) == 0 or got <= 0: break
      let at = t.inbuf.len
      t.inbuf.setLen(at + got)
      copyMem(addr t.inbuf[at], addr buf[0], got)
      result = true
    if not result and t.hproc != nil and WaitForSingleObject(t.hproc, 0) == 0:
      # (it ended: what it wrote last taken, then let go of)
      t.reap()
      result = true

  proc flushOut(t: Terminal) =
    while t.hin != nil and t.outbuf.len > 0:
      var put: int32
      if WriteFile(t.hin, addr t.outbuf[0], int32(t.outbuf.len), addr put, nil) == 0 or put <= 0: break
      t.outbuf.delete(0 .. int(put) - 1)
else:
  proc pump(t: Terminal): bool = false
  proc flushOut(t: Terminal) = discard

proc defaultShell*(): seq[string] =
  ## The user's shell: $SHELL, else /bin/sh (/system/bin/sh on Android); on Windows %COMSPEC%
  ## (cmd.exe).
  when defined(windows):
    let c = getEnv("COMSPEC")
    return @[if c.len > 0: c else: "cmd.exe"]
  else:
    let sh = getEnv("SHELL")
    if sh.len > 0 and fileExists(sh): @[sh]
    elif fileExists("/system/bin/sh"): @["/system/bin/sh"]
    else: @["/bin/sh"]

proc spawn*(t: Terminal; command: seq[string] = @[]; cwd = ""; env: openArray[(string, string)] = []): bool =
  ## Runs `command` (the user's shell when empty: `defaultShell`) in the terminal, in `cwd`,
  ## with `env` added to its environment (TERM is xterm-256color); false, and why in `error`,
  ## when it cannot. What it writes is shown as it comes, what is typed goes to it; `running`
  ## while it goes on, `exitCode` once it ended.
  let cmd = if command.len > 0: command else: defaultShell()
  t.error = ""
  when hasConPty:
    if t.running: return true
    if not findConPty():
      t.error = "a program in a terminal needs Windows 10 (1809) or later"
      return false
    var inR, inW, outR, outW: pointer
    if CreatePipe(addr inR, addr inW, nil, 0) == 0 or CreatePipe(addr outR, addr outW, nil, 0) == 0:
      t.error = "no pipe: " & $GetLastError()
      return false
    var pc: pointer
    let hr = conPty.create(Coord(x: int16(t.cols), y: int16(t.rows)), inR, outW, 0, addr pc)
    # (the pseudo-console has its own of these two now)
    discard CloseHandle(inR)
    discard CloseHandle(outW)
    if hr != 0 or pc == nil:
      t.error = "no pseudo-console: " & toHex(hr)
      discard CloseHandle(inW)
      discard CloseHandle(outR)
      return false
    var size: csize_t
    discard InitializeProcThreadAttributeList(nil, 1, 0, addr size)
    var list = newSeq[byte](max(1, int(size)))
    var si: StartupInfoExW
    si.startupInfo.cb = int32(sizeof(StartupInfoExW))
    si.lpAttributeList = addr list[0]
    const PseudoConsole = 0x00020016'u
    if InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, addr size) == 0 or
       UpdateProcThreadAttribute(si.lpAttributeList, 0, PseudoConsole, pc, csize_t(sizeof(pointer)),
                                 nil, nil) == 0:
      t.error = "no pseudo-console for the program: " & $GetLastError()
      conPty.close(pc)
      discard CloseHandle(inW)
      discard CloseHandle(outR)
      return false
    var line = ""
    for i, a in cmd:
      if i > 0: line.add ' '
      line.add quoteShellWindows(a)
    # (the environment: the program's own and `env`, in UTF-16, each ended by a 0, a 0 after all)
    var block16: seq[uint16]
    var skip: seq[string]
    for (k, _) in env: skip.add k.toUpperAscii
    var entries: seq[string]
    for k, v in envPairs():
      if k.toUpperAscii notin skip: entries.add k & "=" & v
    for (k, v) in env: entries.add k & "=" & v
    for e in entries:
      let w = newWideCString(e)
      for i in 0 ..< w.len: block16.add uint16(w[i])
      block16.add 0
    block16.add 0
    var pi: ProcessInformation
    const ExtendedStartupInfo = 0x00080000'i32
    const UnicodeEnvironment = 0x00000400'i32
    let wline = newWideCString(line)
    let wcwd = newWideCString(cwd)
    var cwdArg: WideCString = nil
    if cwd.len > 0: cwdArg = wcwd
    let ok = CreateProcessW(nil, wline, nil, nil, 0, ExtendedStartupInfo or UnicodeEnvironment,
                            addr block16[0], cwdArg, addr si, addr pi)
    DeleteProcThreadAttributeList(si.lpAttributeList)
    if ok == 0:
      t.error = cmd[0] & ": not started (" & $GetLastError() & ")"
      conPty.close(pc)
      discard CloseHandle(inW)
      discard CloseHandle(outR)
      return false
    discard CloseHandle(pi.hThread)
    t.hpc = pc
    t.hin = inW
    t.hout = outR
    t.hproc = pi.hProcess
    t.pid = int(pi.dwProcessId)
    t.running = true
    t.exitCode = 0
    liveTerms.add t
    true
  elif not hasPty:
    t.error = "a program in a terminal is not there on this system"
    return false
  else:
    if t.running: return true
    let m = posix_openpt(O_RDWR or O_NOCTTY)
    if m < 0 or grantpt(m) != 0 or unlockpt(m) != 0:
      t.error = "no pseudo-terminal: " & $strerror(errno)
      if m >= 0: discard posix.close(m)
      return false
    let slaveName = $ptsname(m)
    var ws: Winsize
    ws.ws_row = cushort(t.rows)
    ws.ws_col = cushort(t.cols)
    discard ioctl(m, TIOCSWINSZ, addr ws)
    # (all the child needs made before it is made: between fork and exec only what is safe
    # there -- no memory taken, no lock)
    var envs: seq[string]
    var skip = @["TERM", "COLORTERM", "COLUMNS", "LINES"]
    for (k, _) in env: skip.add k
    for k, v in envPairs():
      if k notin skip: envs.add k & "=" & v
    envs.add "TERM=xterm-256color"
    envs.add "COLORTERM=truecolor"
    for (k, v) in env: envs.add k & "=" & v
    let exe = if '/' in cmd[0]: cmd[0] else: findExe(cmd[0])
    if exe.len == 0 or not fileExists(exe):
      t.error = cmd[0] & ": not found"
      discard posix.close(m)
      return false
    let argv = allocCStringArray(cmd)
    let envp = allocCStringArray(envs)
    let path = cstring(exe)
    let dir = cstring(cwd)
    let slave = cstring(slaveName)
    let pid = fork()
    if pid == 0:
      discard setsid()
      let s = posix.open(slave, O_RDWR)
      if s < 0: exitnow(126)
      discard ioctl(s, TIOCSCTTY, 0)
      discard dup2(s, 0)
      discard dup2(s, 1)
      discard dup2(s, 2)
      if s > 2: discard posix.close(s)
      discard posix.close(m)
      if dir[0] != '\0': discard chdir(dir)
      discard execve(path, argv, envp)
      exitnow(127)
    deallocCStringArray(argv)
    deallocCStringArray(envp)
    if pid < 0:
      t.error = "the program was not started: " & $strerror(errno)
      discard posix.close(m)
      return false
    discard fcntl(m, F_SETFL, fcntl(m, F_GETFL) or O_NONBLOCK)
    discard fcntl(m, F_SETFD, fcntl(m, F_GETFD) or FD_CLOEXEC)
    t.fd = m
    t.pid = int(pid)
    t.running = true
    t.exitCode = 0
    t.exitSignal = 0
    liveTerms.add t
    if not waitHooked:
      waitHooked = true
      addWaitSource(waitFds, waitReady)
    true

proc send*(t: Terminal; data: string) =
  ## `data` to the program, as if typed (to `onInput` when there is none).
  if data.len == 0: return
  if t.running:
    t.outbuf.add data
    t.flushOut()
  elif t.onInput != nil: t.onInput(data)

proc paste*(t: Terminal; text: string) =
  ## `text` given to the program as pasted (marked so for one that asks: a shell then takes it
  ## as text, not as commands typed).
  var s = text.replace("\r\n", "\r").replace('\n', '\r')
  if t.bracketed: s = "\e[200~" & s.replace("\e[201~", "") & "\e[201~"
  t.send(s)

proc stop*(t: Terminal; signal = 1) =
  ## The program told to end (SIGHUP by default: as when a terminal is closed; on Windows it is
  ## ended).
  when hasPty:
    if t.pid > 0: discard kill(Pid(t.pid), cint(signal))
  elif hasConPty:
    if t.hproc != nil: discard TerminateProcess(t.hproc, 1)

proc close*(t: Terminal) =
  ## The program ended and the terminal let go of it.
  when hasPty:
    if t.pid > 0:
      discard kill(Pid(t.pid), SIGHUP)
      if t.fd >= 0:
        discard posix.close(t.fd)
        t.fd = -1
      var st: cint
      for i in 0 ..< 50:
        if waitpid(Pid(t.pid), st, WNOHANG) != 0: break
        os.sleep(2)
      if waitpid(Pid(t.pid), st, WNOHANG) == 0:
        discard kill(Pid(t.pid), SIGKILL)
        discard waitpid(Pid(t.pid), st, 0)
      t.pid = 0
    t.reap()
  elif hasConPty:
    if t.hproc != nil and WaitForSingleObject(t.hproc, 0) != 0: discard TerminateProcess(t.hproc, 1)
    if t.running: t.reap()

proc update*(t: Terminal): bool {.discardable.} =
  ## What the program wrote since, taken and shown; the terminal's answers sent to it. The view
  ## does it each frame; a terminal not drawn can be kept going with it. True when something
  ## came.
  if t.running: result = t.pump()
  if t.inbuf.len > 0:
    let data = move t.inbuf
    t.inbuf = ""
    t.feed(data)
    result = true
  if t.outbuf.len > 0:
    if t.running: t.flushOut()
    else: t.outbuf.setLen(0)

proc waitOutput*(t: Terminal; text: string; ms = 5000): bool =
  ## Updates the terminal until `text` is on its screen (true) or `ms` went by (false): for
  ## tests and scripts.
  let until = getMonoTime() + initDuration(milliseconds = ms)
  while true:
    t.update()
    if text in t.screenText(): return true
    if getMonoTime() > until or (not t.running and t.inbuf.len == 0): return text in t.screenText()
    os.sleep(5)

# ---- the keys --------------------------------------------------------------------------------

proc keyBytes*(t: Terminal; key: KeyCode; mods: set[Modifier]): string =
  ## What a key sends a program (as xterm sends it), "" for a key that sends nothing by itself
  ## (a letter: its text comes as typed).
  let ctrl = when defined(macosx) or defined(ios): GuiPressed in mods else: CtrlPressed in mods
  let alt = AltPressed in mods
  let shift = ShiftPressed in mods
  let m = 1 + (if shift: 1 else: 0) + (if alt: 2 else: 0) + (if ctrl: 4 else: 0)
  template cursorKey(c: char): string =
    (if m > 1: "\e[1;" & $m & c elif t.appCursor: "\eO" & c else: "\e[" & c)
  template tilde(n: int): string =
    (if m > 1: "\e[" & $n & ";" & $m & "~" else: "\e[" & $n & "~")
  template fkey(c: char): string =
    (if m > 1: "\e[1;" & $m & c else: "\eO" & c)
  case key
  of KeyUp: cursorKey('A')
  of KeyDown: cursorKey('B')
  of KeyRight: cursorKey('C')
  of KeyLeft: cursorKey('D')
  of KeyHome: cursorKey('H')
  of KeyEnd: cursorKey('F')
  of KeyInsert: tilde(2)
  of KeyDelete: tilde(3)
  of KeyPageUp: tilde(5)
  of KeyPageDown: tilde(6)
  of KeyF1: fkey('P')
  of KeyF2: fkey('Q')
  of KeyF3: fkey('R')
  of KeyF4: fkey('S')
  of KeyF5: tilde(15)
  of KeyF6: tilde(17)
  of KeyF7: tilde(18)
  of KeyF8: tilde(19)
  of KeyF9: tilde(20)
  of KeyF10: tilde(21)
  of KeyF11: tilde(23)
  of KeyF12: tilde(24)
  of KeyEnter: (if alt: "\e\r" else: "\r")
  of KeyTab: (if shift: "\e[Z" else: "\t")
  of KeyBackspace: (if ctrl: "\b" elif alt: "\e\x7F" else: "\x7F")
  of KeyEsc: "\e"
  of KeyA .. KeyZ:
    let c = char(ord('a') + ord(key) - ord(KeyA))
    if ctrl: (if alt: "\e" else: "") & $char(ord(c) - ord('a') + 1)
    elif alt: "\e" & (if shift: c.toUpperAscii else: c)
    else: ""
  of KeySpace: (if ctrl: "\0" else: "")
  of Key0 .. Key9:
    if ctrl:
      case key
      of Key2: "\0"
      of Key3: "\e"
      of Key4: "\x1C"
      of Key5: "\x1D"
      of Key6: "\x1E"
      of Key7: "\x1F"
      of Key8: "\x7F"
      else: ""
    elif alt: "\e" & char(ord('0') + ord(key) - ord(Key0))
    else: ""
  of KeyLeftBracket: (if ctrl: "\e" else: "")
  of KeyBackslash: (if ctrl: "\x1C" else: "")
  of KeyRightBracket: (if ctrl: "\x1D" else: "")
  of KeySlash, KeyMinus: (if ctrl: "\x1F" else: "")
  else: ""

# ---- the view ---------------------------------------------------------------------------------

proc colorOf(t: Terminal; v: uint32; fg: bool): Color =
  let k = v shr 24
  if k == 0: return (if fg: t.colors.fg else: t.colors.bg)
  if k == 2: return Color(r: uint8((v shr 16) and 255), g: uint8((v shr 8) and 255), b: uint8(v and 255), a: 255)
  let n = int(v and 255)
  if n < 16: return t.colors.ansi[n]
  if n < 232:
    const steps = [0'u8, 95, 135, 175, 215, 255]
    let i = n - 16
    return Color(r: steps[i div 36], g: steps[(i div 6) mod 6], b: steps[i mod 6], a: 255)
  let g = uint8(8 + (n - 232) * 10)
  Color(r: g, g: g, b: g, a: 255)

proc totalLines(t: Terminal): int = (if t.onAlt: 0 else: t.sb.len) + t.rows

proc lineAt(t: Terminal; i: int): ptr TermLine =
  ## (line `i` of all there is to see: what scrolled off, then the screen)
  let k = if t.onAlt: 0 else: t.sb.len
  if i < k: addr t.sb[i] else: addr t.screen[clamp(i - k, 0, t.rows - 1)]

proc ordered(t: Terminal): tuple[a, b: tuple[line, col: int]] =
  if t.selA.line < t.selB.line or (t.selA.line == t.selB.line and t.selA.col <= t.selB.col): (t.selA, t.selB)
  else: (t.selB, t.selA)

proc selected(t: Terminal; line, col: int): bool {.inline.} =
  if not t.selOn: return false
  let (a, b) = t.ordered()
  if line < a.line or line > b.line: return false
  if line == a.line and col < a.col: return false
  if line == b.line and col > b.col: return false
  true

proc selectionText*(t: Terminal): string =
  ## The text chosen with the mouse ("" when none): a line a row, rows the text wrapped across
  ## joined.
  if not t.selOn: return ""
  let (a, b) = t.ordered()
  for i in a.line .. b.line:
    if i < 0 or i >= t.totalLines: continue
    let l = t.lineAt(i)
    let c0 = if i == a.line: a.col else: 0
    let c1 = if i == b.line: min(b.col, l.cells.high) else: l.cells.high
    var s = ""
    for c in c0 .. c1:
      if c < 0 or c >= l.cells.len: continue
      let ch = l.cells[c].ch
      if ch > 0: s.add Rune(ch).toUtf8
      elif ch == 0: s.add ' '
    if not (i < b.line and l.wrapped): s = s.strip(leading = false)
    result.add s
    if i < b.line and not l.wrapped: result.add '\n'

proc selectAll*(t: Terminal) =
  ## All there is to see chosen: what scrolled off and the screen.
  t.selA = (0, 0)
  t.selB = (t.totalLines - 1, t.cols - 1)
  t.selOn = true

proc clearScrollback*(t: Terminal) =
  ## What scrolled off forgotten.
  t.sb.clear()
  t.viewTop = 0
  t.selOn = false
  inc t.ver

proc boxChar(c: int32; r: Rect; col: Color; cw: int): bool =
  ## (lines and blocks drawn whole from cell to cell, as the programs that draw boxes mean
  ## them; false for another character)
  let c = int(c)
  if c < 0x2500 or c > 0x259F: return false
  let thin = max(1, (cw + 4) div 8)
  let thick = max(2, thin * 2)
  let mx = r.x + (r.w - thin) div 2
  let my = r.y + (r.h - thin) div 2
  # (each line: none, thin, thick, double -- left, right, up, down)
  var l, rt, u, d = 0
  case c
  of 0x2500: (l, rt) = (1, 1)
  of 0x2501: (l, rt) = (2, 2)
  of 0x2502: (u, d) = (1, 1)
  of 0x2503: (u, d) = (2, 2)
  of 0x250C, 0x256D: (rt, d) = (1, 1)
  of 0x250F: (rt, d) = (2, 2)
  of 0x2510, 0x256E: (l, d) = (1, 1)
  of 0x2513: (l, d) = (2, 2)
  of 0x2514, 0x2570: (rt, u) = (1, 1)
  of 0x2517: (rt, u) = (2, 2)
  of 0x2518, 0x256F: (l, u) = (1, 1)
  of 0x251B: (l, u) = (2, 2)
  of 0x251C: (rt, u, d) = (1, 1, 1)
  of 0x2523: (rt, u, d) = (2, 2, 2)
  of 0x2524: (l, u, d) = (1, 1, 1)
  of 0x252B: (l, u, d) = (2, 2, 2)
  of 0x252C: (l, rt, d) = (1, 1, 1)
  of 0x2533: (l, rt, d) = (2, 2, 2)
  of 0x2534: (l, rt, u) = (1, 1, 1)
  of 0x253B: (l, rt, u) = (2, 2, 2)
  of 0x253C: (l, rt, u, d) = (1, 1, 1, 1)
  of 0x254B: (l, rt, u, d) = (2, 2, 2, 2)
  of 0x2550: (l, rt) = (3, 3)
  of 0x2551: (u, d) = (3, 3)
  of 0x2554: (rt, d) = (3, 3)
  of 0x2557: (l, d) = (3, 3)
  of 0x255A: (rt, u) = (3, 3)
  of 0x255D: (l, u) = (3, 3)
  of 0x2560: (rt, u, d) = (3, 3, 3)
  of 0x2563: (l, u, d) = (3, 3, 3)
  of 0x2566: (l, rt, d) = (3, 3, 3)
  of 0x2569: (l, rt, u) = (3, 3, 3)
  of 0x256C: (l, rt, u, d) = (3, 3, 3, 3)
  of 0x2574: l = 1
  of 0x2575: u = 1
  of 0x2576: rt = 1
  of 0x2577: d = 1
  of 0x2580: fill(rect(r.x, r.y, r.w, r.h div 2), col); return true
  of 0x2588: fill(r, col); return true
  of 0x2590: fill(rect(r.x + r.w div 2, r.y, r.w - r.w div 2, r.h), col); return true
  of 0x2581 .. 0x2587:
    let h = r.h * (c - 0x2580) div 8
    fill(rect(r.x, r.y + r.h - h, r.w, h), col); return true
  of 0x2589 .. 0x258F:
    let w = r.w * (0x2590 - c) div 8
    fill(rect(r.x, r.y, w, r.h), col); return true
  of 0x2591, 0x2592, 0x2593:
    let a = [64, 128, 192][c - 0x2591]
    fill(r, Color(r: col.r, g: col.g, b: col.b, a: uint8(a))); return true
  else: return false
  template seg(n: int; horiz: bool; a, b: int) =
    if n > 0:
      let w = if n == 2: thick else: thin
      if horiz:
        let y0 = r.y + (r.h - w) div 2
        if n == 3:
          fill(rect(a, my - thin, b - a, thin), col)
          fill(rect(a, my + thin, b - a, thin), col)
        else: fill(rect(a, y0, b - a, w), col)
      else:
        let x0 = r.x + (r.w - w) div 2
        if n == 3:
          fill(rect(mx - thin, a, thin, b - a), col)
          fill(rect(mx + thin, a, thin, b - a), col)
        else: fill(rect(x0, a, w, b - a), col)
  let cxm = mx + thin            # (where a line across meets the middle, past it by a line's width)
  let cym = my + thin
  seg(l, true, r.x, if u + d > 0: cxm + (if l == 3: thin else: 0) else: r.x + r.w div 2 + thin)
  seg(rt, true, if u + d > 0: mx - (if rt == 3: thin else: 0) else: r.x + r.w div 2, r.x + r.w)
  seg(u, false, r.y, if l + rt > 0: cym + (if u == 3: thin else: 0) else: r.y + r.h div 2 + thin)
  seg(d, false, if l + rt > 0: my - (if d == 3: thin else: 0) else: r.y + r.h div 2, r.y + r.h)
  true

proc mouseReport(t: Terminal; button, col, row: int; press: bool; motion = false) =
  ## (a mouse event to a program that asked for them)
  var b = button
  if motion: b += 32
  if t.mouseSgr:
    t.send("\e[<" & $b & ";" & $(col + 1) & ";" & $(row + 1) & (if press: "M" else: "m"))
  else:
    if not press: b = 3
    if col + 33 > 255 or row + 33 > 255: return
    t.send("\e[M" & char(32 + b) & char(33 + col) & char(33 + row))

proc terminalView*(t: Terminal; w = 0; lines = 24; focusFirst = false) =
  ## The terminal in a box `w` wide (0: the row's width) and `lines` rows of its text high (-1:
  ## the height left) -- its size in cells made to fit it, the program told. Takes the keys
  ## while it has the focus (Tab and the arrows too), the wheel scrolls back through what
  ## scrolled off; the mouse chooses text (double-click a word, triple a line), Ctrl+Shift+C
  ## copies it, Ctrl+Shift+V and Shift+Insert paste; a right click has the same in a menu.
  let st = style(mono = true, size = t.fontSize)
  let cw = max(1, textWidth("M", st))
  let lh = max(1, lineHeight(st))
  let h = if lines < 0: remainingH() else: lines * lh + 4
  let r = place(if w > 0: w else: 0, h, fill = w <= 0)
  let id = makeId(mixId(fnv("terminal"), uint32(cast[uint](t) shr 4 and 0xFFFFFFFF'u)))
  let hit = interact(id, r)
  if focusFirst and ui.focus == 0: ui.focus = id
  beginKeepSides(r)                  # (left to right in a right-to-left window too, the mouse read so)
  if t.themed:
    t.colors = if themeIsDark(ui.theme): DarkColors else: LightColors
  let bar = SbW
  let inner = rect(r.x + 2, r.y + 2, r.w - 4 - bar, r.h - 4)
  let cols = max(2, inner.w div cw)
  let rows = max(1, inner.h div lh)
  if cols != t.cols or rows != t.rows: t.resize(cols, rows)
  # what the program wrote, shown (a view scrolled back kept on the lines it shows)
  let before = t.ver
  t.update()
  if t.viewTop > 0: t.viewTop += t.pushed * lh
  t.pushed = 0
  # the keys
  let mac = defined(macosx) or defined(ios)
  if hit.focused and canInput():
    ui.takesText = true
    ui.editsText = true
    ui.takesEnter = true
    let copyKey = if mac: ui.key == KeyC and CtrlPressed in ui.mods
                  else: ui.key == KeyC and CtrlPressed in ui.mods and ShiftPressed in ui.mods
    let pasteKey = (if mac: ui.key == KeyV and CtrlPressed in ui.mods
                    else: ui.key == KeyV and CtrlPressed in ui.mods and ShiftPressed in ui.mods) or
                   (ui.key == KeyInsert and ShiftPressed in ui.mods)
    var sent = false
    if ui.typed.len > 0:
      # (what was typed before this frame's key: first)
      t.send(ui.typed)
      ui.typed = ""
      sent = true
    if copyKey and not ui.keyUsed:
      ui.keyUsed = true
      if t.selOn: putClipboardText(t.selectionText())
    elif pasteKey and not ui.keyUsed:
      ui.keyUsed = true
      t.paste(getClipboardText())
      sent = true
    elif ui.key != KeyNone and not ui.keyUsed and not (mac and CtrlPressed in ui.mods):
      let b = t.keyBytes(ui.key, ui.mods)
      if b.len > 0:
        ui.keyUsed = true
        t.send(b)
        sent = true
    if sent:
      t.viewTop = 0
      t.selOn = false
      wakeIn(5)                          # (the echo, soon)
  # the wheel: back through what scrolled off; a full-screen program gets it as the arrows (or
  # as the mouse, when it asked for it)
  let sbLines = if t.onAlt: 0 else: t.sb.len
  if ui.wheel != 0 and not ui.wheelUsed and mouseIn(r) and canInput():
    let mcol = clamp((ui.mx - inner.x) div cw, 0, t.cols - 1)
    let mrow = clamp((ui.my - inner.y) div lh, 0, t.rows - 1)
    if t.mouseMode != 0 and ShiftPressed notin ui.mods:
      for k in 0 ..< min(abs(ui.wheel), 5):
        t.mouseReport(if ui.wheel > 0: 64 else: 65, mcol, mrow, true)
      ui.wheelUsed = true
    elif t.onAlt:
      for k in 0 ..< min(abs(ui.wheel) * 3, 15): t.send(t.keyBytes(if ui.wheel > 0: KeyUp else: KeyDown, {}))
      ui.wheelUsed = true
  var off = max(0, sbLines * lh - t.viewTop)    # (pixels from the oldest line to the view's top)
  let maxOff = sbLines * lh
  scrollWheel(id, off, maxOff, inner, 3 * lh)
  scrollTick(id, off, maxOff)
  # the mouse: text chosen, or the program's when it asked
  template cellAt(px, py: int): tuple[line, col: int] =
    (clamp((py - inner.y + off) div lh, 0, t.totalLines - 1), clamp((px - inner.x) div cw, 0, t.cols - 1))
  if canInput() and mouseIn(inner) and t.mouseMode != 0 and ShiftPressed notin ui.mods and
     t.viewTop == 0:
    let mcol = clamp((ui.mx - inner.x) div cw, 0, t.cols - 1)
    let mrow = clamp((ui.my - inner.y) div lh, 0, t.rows - 1)
    if ui.pressed:
      ui.focus = id
      t.mouseReport(0, mcol, mrow, true)
      t.mouseDownAt = 1
    elif ui.released and t.mouseDownAt != 0:
      t.mouseReport(0, mcol, mrow, false)
      t.mouseDownAt = 0
    elif (ui.mouseDown and t.mouseMode >= 1002 or t.mouseMode == 1003) and
         (mcol, mrow) != t.lastMouseCell:
      t.mouseReport(if ui.mouseDown: 0 else: 3, mcol, mrow, true, motion = true)
    t.lastMouseCell = (mcol, mrow)
  else:
    if hit.down and ui.pressed:
      let c = cellAt(ui.mx, ui.my)
      t.selecting = true
      t.selA = c
      t.selB = c
      t.selOn = false
      let clicks = ui.clicks
      if clicks >= 2:
        # (a word: what is not a blank or a mark either way; three clicks: the line)
        let l = t.lineAt(c.line)
        if clicks >= 3:
          t.selA = (c.line, 0)
          t.selB = (c.line, t.cols - 1)
        else:
          proc wordy(ch: int32): bool = ch > 0 and (ch > 127 or char(ch).isAlphaNumeric or char(ch) in "-_./~:@%+")
          var a = c.col
          var b = c.col
          while a > 0 and l.cells.len > a - 1 and wordy(l.cells[a - 1].ch): dec a
          while b + 1 < l.cells.len and wordy(l.cells[b + 1].ch): inc b
          t.selA = (c.line, a)
          t.selB = (c.line, b)
        t.selOn = true
        t.selecting = false
    elif t.selecting and ui.mouseDown and ui.active == id:
      let c = cellAt(ui.mx, ui.my)
      if c != t.selA or t.selOn:
        t.selB = c
        t.selOn = true
      # (dragged past the top or the bottom: scrolled)
      if ui.my < inner.y and off > 0: off = max(0, off - lh)
      elif ui.my > inner.y + inner.h and off < maxOff: off = min(maxOff, off + lh)
      wakeIn(40)
    elif t.selecting and not ui.mouseDown:
      t.selecting = false
  t.viewTop = maxOff - off
  # draw: the background, then each row -- its colors, its text, its lines and blocks
  fill(r, t.colors.bg)
  pushClip(inner)
  let first = off div lh
  let y0 = inner.y - (off mod lh)
  let cursorLine = sbLines + t.cy
  for k in 0 .. inner.h div lh + 1:
    let li = first + k
    if li >= t.totalLines: break
    let l = t.lineAt(li)
    let y = y0 + k * lh
    var c = 0
    while c < l.cells.len and c < t.cols:
      let cell = l.cells[c]
      var fg = t.colorOf(cell.fg, true)
      var bg = t.colorOf(cell.bg, false)
      if taInverse in cell.attrs: swap(fg, bg)
      if taFaint in cell.attrs: fg = mixColor(fg, bg, 0.45)
      let wide = c + 1 < l.cells.len and l.cells[c + 1].ch == -1
      let cells = if wide: 2 else: 1
      let x = inner.x + c * cw
      if t.selected(li, c):
        bg = t.colors.selection
        if themeIsDark(ui.theme) or t.colors.bg.r < 128: fg = color(255, 255, 255)
      let onCursor = li == cursorLine and c == t.cx and t.cursorOn and t.viewTop == 0 and
                     (t.cursorShape <= 2)
      if onCursor and hit.focused:
        swap(fg, bg)
        bg = t.colors.cursor
        fg = t.colors.bg
      if bg != t.colors.bg: fill(rect(x, y, cw * cells, lh), bg)
      if cell.ch > 32 and taHidden notin cell.attrs:
        let cr = rect(x, y, cw * cells, lh)
        if not boxChar(cell.ch, cr, fg, cw):
          let s = Rune(cell.ch).toUtf8
          let bold = taBold in cell.attrs
          let gs = style(mono = true, size = t.fontSize, bold = bold, italic = taItalic in cell.attrs)
          if cell.ch < 128: text(x, y, s, fg, gs)
          else:
            # (a character of another width in the font: in the middle of its cells)
            let gw = textWidth(s, gs)
            text(x + (cw * cells - gw) div 2, y, s, fg, gs)
      if taUnderline in cell.attrs: fill(rect(x, y + lh - max(1, lh div 12) - 1, cw * cells, max(1, lh div 12)), fg)
      if taStrike in cell.attrs: fill(rect(x, y + lh div 2, cw * cells, max(1, lh div 14)), fg)
      c += cells
  # the cursor: a block (hollow without the focus), a line under, a bar
  if t.cursorOn and t.viewTop == 0 and cursorLine >= first and cursorLine <= first + inner.h div lh + 1:
    let x = inner.x + t.cx * cw
    let y = y0 + (cursorLine - first) * lh
    let cc = t.colors.cursor
    if t.cursorShape in [3, 4]: fill(rect(x, y + lh - max(2, lh div 8), cw, max(2, lh div 8)), cc)
    elif t.cursorShape in [5, 6]: fill(rect(x, y, max(2, cw div 6), lh), cc)
    elif not hit.focused: box(rect(x, y, cw, lh), cc)
  popClip()
  endKeepSides()
  # the scroll bar
  if maxOff > 0:
    var v = off
    scrollBarFor(id + 77, id, rect(r.x + r.w - bar, r.y, bar, r.h), true, v, maxOff,
                 max(lh, inner.h - lh), lh)
    if v != off: t.viewTop = maxOff - v
  box(r, if hit.focused: ui.theme.select else: mixColor(t.colors.bg, t.colors.fg, 0.25))
  # the right click's menu
  contextMenu:
    if menuItem("&Copy", if mac: "Cmd+C" else: "Ctrl+Shift+C", enabled = t.selOn):
      putClipboardText(t.selectionText())
    if menuItem("&Paste", if mac: "Cmd+V" else: "Ctrl+Shift+V"):
      t.paste(getClipboardText())
    menuSeparator()
    if menuItem("Select &All"): t.selectAll()
    if menuItem("C&lear Scrollback"): t.clearScrollback()
  # more frames: what comes from the program wakes the window where it can, else it is asked
  # for now and then
  if t.ver != before: wakeIn(16)             # (more may come at once)
  if t.running:
    const watched = (defined(linux) or defined(bsd)) and not defined(android)
    wakeIn(if watched: 1000 else: 33)
