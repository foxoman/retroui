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

import std/[deques, strutils, os, uri, monotimes, times, tables, base64, sequtils]
from std/unicode import Rune, toUtf8, runeLen
import core, widgets, codec, imaging
from typeset import bidiInfo, visualOrderOf
import uirelays/[input, target]

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

  TermPicture = object
    ## (a picture placed in the text, by its top left cell: it scrolls with its line)
    image: int               # (its image's id)
    place: int               # (its placement's id, 0: none given)
    col: int
    cols, rows: int          # (the cells it covers)
    dx, dy: int              # (device pixels into its first cell)
    z: int                   # (under the text when < 0)
    scaled: bool             # (its cells given: it fills them; else as many pixels as sent)

  TermLine* = object
    ## A row of cells, `wrapped` when the text goes on in the next (copied as one line).
    cells*: seq[TermCell]
    wrapped*: bool
    pics: seq[TermPicture]

  TermImage = ref object
    ## (a picture the program sent: the kitty graphics protocol)
    bmp: Bitmap
    number: int              # (the number it was sent with, I=: 0 none)
    bytes: int
    serial: int              # (how recently it was sent: the oldest let go of first)

  TermColors* = object
    ## The colors a terminal is drawn in: its text and its background, the 16 the programs
    ## name (black, red, green, yellow, blue, magenta, cyan, white, then the bright eight),
    ## the cursor's and the chosen text's.
    fg*, bg*, cursor*, selection*: Color
    ansi*: array[16, Color]

  ParseState = enum psGround, psEsc, psEscHash, psCharset, psCsi, psOsc, psOscEsc, psStr, psStrEsc,
    psApc, psApcEsc

  Terminal* = ref object
    ## A terminal: its screen and what scrolled off it, and the program in it (`spawn`).
    cols*, rows*: int        ## its size in cells (set by `terminalView` from its box)
    title*: string           ## what the program called its window (OSC 0 or 2)
    cwd*: string             ## the folder the shell says it is in (OSC 7), when it says
    maxScrollback*: int      ## the lines kept that scrolled off (10,000 by default)
    colors*: TermColors      ## the colors it is drawn in
    themed*: bool            ## its colors from the scheme, light or dark (true by default)
    fontSize*: float         ## its text, in sizes of the UI's (1.0)
    boldBright*: bool        ## bold text in the bright eight of the 16 colors, as a PC's text
                             ## screen and xterm showed it (the text's own color too, when it
                             ## is one of the eight but black: MS-DOS's gray made white)
    boldText*: bool          ## every letter bold, as a PC's chunky text screen
    bidi*: bool              ## right-to-left text -- Arabic, Hebrew -- shown as it is read: a
                             ## line in the order Unicode's bidirectional algorithm gives
                             ## (its direction its first strong letter's), Arabic's letters
                             ## joined (true); false: each character in its cell as written,
                             ## for a program that orders its text itself
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
    showLine: int            # (a line the view scrolls to: `findText`; -1 none)
    selA, selB: tuple[line, col: int]   # (the chosen text: lines counted from the oldest kept)
    selOn, selecting: bool
    mouseDownAt: int
    lastMouseCell: tuple[col, row: int]
    ver: int
    # the kitty keyboard protocol: its flags, a stack each screen
    kbStack: array[2, seq[int]]
    # the kitty graphics protocol
    apc: string
    images: Table[int, TermImage]
    imageSerial, imageBytes, nextImage: int
    gfxMore: bool                     # (a picture sent in pieces: more to come)
    gfxKeys: Table[char, string]
    gfxData: string
    cellPxW*, cellPxH*: int  ## a cell's size in device pixels (the view sets it; programs ask)
    picsOn*: bool            ## pictures a program sends are shown (kitty graphics; true)
    viewId: core.Id          # (the view's id, the frame before: `terminalKeysFirst`)

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

proc parseIntOr(s: string; d: int): int =
  try: parseInt(s) except ValueError: d

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
                    cursorOn: true, themed: true, fontSize: 1.0, fd: -1, colors: DarkColors,
                    cellPxW: 8, cellPxH: 16, picsOn: true, nextImage: 1 shl 30, showLine: -1,
                    bidi: true)
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
  t.images.clear()
  t.imageBytes = 0
  t.gfxMore = false
  t.kbStack = [@[], @[]]
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

proc kbFlags*(t: Terminal): int =
  ## The kitty keyboard protocol's flags the program asked for on the screen shown now (0: keys
  ## as xterm sends them): 1 Esc and modified keys told apart, 2 releases too, 4 the shifted
  ## key too, 8 every key as an escape, 16 the text with it.
  let st = t.kbStack[ord(t.onAlt)]
  if st.len > 0: st[^1] else: 0

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
      for r in 0 ..< t.rows:
        t.eraseCells(r, 0, t.cols)
        t.screen[r].pics.setLen(0)
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
    # (the kitty keyboard protocol: its flags pushed, popped, set, asked for; without a mark,
    # the cursor put back)
    let st = addr t.kbStack[ord(t.onAlt)]
    case t.private
    of '\0': t.restoreCursor()
    of '?': t.answer("\e[?" & $t.kbFlags & "u")
    of '>':
      st[].add t.param(0, 0) and 31
      if st[].len > 64: st[].delete(0)
    of '<':
      for k in 0 ..< max(1, t.param(0, 1)):
        if st[].len > 0: st[].setLen(st[].len - 1)
    of '=':
      let f = t.param(0, 0) and 31
      let cur = t.kbFlags
      let nv = case t.param(1, 1)
               of 2: cur or f
               of 3: cur and not f
               else: f
      if st[].len == 0: st[].add nv else: st[^1] = nv
    else: discard
  of 't':
    case t.param(0, 0)
    of 14: t.answer("\e[4;" & $(t.rows * t.cellPxH) & ";" & $(t.cols * t.cellPxW) & "t")
    of 16: t.answer("\e[6;" & $t.cellPxH & ";" & $t.cellPxW & "t")
    of 18: t.answer("\e[8;" & $t.rows & ";" & $t.cols & "t")
    else: discard
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

# ---- the kitty graphics protocol: pictures in the text -----------------------------------------

const ImageQuota = 320 shl 20
  ## (the pictures' pixels kept at most: past it the oldest not on the screen are let go of)

proc gfxAnswer(t: Terminal; k: Table[char, string]; msg: string) =
  ## (an answer to a picture's command: OK or why not -- told only when it had an id or a
  ## number, and not asked to be quiet)
  let quiet = parseIntOr(k.getOrDefault('q', "0"), 0)
  if (msg == "OK" and quiet >= 1) or quiet >= 2: return
  var ids = ""
  if k.hasKey('i'): ids.add "i=" & k['i']
  if k.hasKey('I'): ids.add (if ids.len > 0: "," else: "") & "I=" & k['I']
  if ids.len == 0: return
  if k.hasKey('p'): ids.add ",p=" & k['p']
  t.answer("\e_G" & ids & ";" & msg & "\e\\")

proc imageById(t: Terminal; k: Table[char, string]): int =
  ## (the image a command names: by its id, or the newest sent with its number; 0 none)
  let i = parseIntOr(k.getOrDefault('i', "0"), 0)
  if i > 0: return (if t.images.hasKey(i): i else: 0)
  let n = parseIntOr(k.getOrDefault('I', "0"), 0)
  if n > 0:
    var best = -1
    for id, im in t.images:
      if im.number == n and im.serial > best:
        best = im.serial
        result = id

proc placedIds(t: Terminal): seq[int] =
  for l in t.main:
    for p in l.pics: result.add p.image
  for l in t.alt:
    for p in l.pics: result.add p.image
  for i in 0 ..< t.sb.len:
    for p in t.sb[i].pics: result.add p.image

proc trimImages(t: Terminal) =
  ## (past the quota, the oldest images let go of -- first those placed nowhere)
  if t.imageBytes <= ImageQuota: return
  let placed = t.placedIds()
  for pass in 0 .. 1:
    while t.imageBytes > ImageQuota:
      var oldest = 0
      var serial = high(int)
      for id, im in t.images:
        if (pass == 1 or id notin placed) and im.serial < serial:
          serial = im.serial
          oldest = id
      if oldest == 0: break
      t.imageBytes -= t.images[oldest].bytes
      t.images.del oldest

proc placePicture(t: Terminal; id: int; k: Table[char, string]) =
  ## (an image put at the cursor, cells as many as it needs at the cell's size or as asked;
  ## the cursor after it unless C=1)
  let im = t.images[id]
  template num(c: char; d = 0): int = parseIntOr(k.getOrDefault(c, ""), d)
  var bmp = im.bmp
  let sx = clamp(num('x'), 0, bmp.w - 1)
  let sy = clamp(num('y'), 0, bmp.h - 1)
  let sw = if num('w') > 0: min(num('w'), bmp.w - sx) else: bmp.w - sx
  let sh = if num('h') > 0: min(num('h'), bmp.h - sy) else: bmp.h - sy
  var useId = id
  if sx != 0 or sy != 0 or sw != bmp.w or sh != bmp.h:
    # (a part of it: a picture of that part, kept as an image of its own)
    let part = newBitmap(max(1, sw), max(1, sh))
    for y in 0 ..< sh:
      for x in 0 ..< sw: part.px[y * sw + x] = bmp.px[(sy + y) * bmp.w + sx + x]
    part.changed()
    inc t.nextImage
    useId = t.nextImage
    inc t.imageSerial
    t.images[useId] = TermImage(bmp: part, bytes: sw * sh * 4, serial: t.imageSerial)
    t.imageBytes += sw * sh * 4
  let cw = max(1, t.cellPxW)
  let ch = max(1, t.cellPxH)
  let dx = clamp(num('X'), 0, cw - 1)
  let dy = clamp(num('Y'), 0, ch - 1)
  var cols = if num('c') > 0: num('c') else: max(1, (sw + dx + cw - 1) div cw)
  var rows = if num('r') > 0: num('r') else: max(1, (sh + dy + ch - 1) div ch)
  # (one of them given: the other as the picture's shape says)
  if num('c') > 0 and num('r') <= 0: rows = max(1, (cols * cw * sh div max(1, sw) + ch - 1) div ch)
  if num('r') > 0 and num('c') <= 0: cols = max(1, (rows * ch * sw div max(1, sh) + cw - 1) div cw)
  let scaled = num('c') > 0 or num('r') > 0
  let pid = num('p')
  # (a placement of the same image with the same id: moved here)
  if pid > 0:
    for l in t.screen.mitems:
      l.pics.keepItIf(not (it.image == id and it.place == pid))
  t.screen[t.cy].pics.add TermPicture(image: useId, place: pid, col: t.cx, cols: cols, rows: rows,
                                      dx: dx, dy: dy, z: num('z'), scaled: scaled)
  if num('C') != 1:
    for k in 1 ..< rows: t.lineFeed()
    t.cx = min(t.cols - 1, t.cx + cols)
    t.wrapNext = false
  inc t.ver

proc deletePictures(t: Terminal; k: Table[char, string]) =
  ## (a=d: placements taken away -- all, an image's, those at a cell, a column, a row, a layer;
  ## the upper-case kinds let go of the image too once nothing shows it)
  let what = k.getOrDefault('d', "a")
  let d = if what.len > 0: what[0] else: 'a'
  let free = d in {'A'..'Z'}
  template num(c: char; dv = 0): int = parseIntOr(k.getOrDefault(c, ""), dv)
  let id = t.imageById(k)
  let pid = num('p')
  let cx = num('x') - 1
  let cy = num('y') - 1
  var gone: seq[int]
  proc covers(p: TermPicture; row, col, r, c: int): bool =
    (c < 0 or (c >= p.col and c < p.col + p.cols)) and (r < 0 or (r >= row and r < row + p.rows))
  for row in 0 ..< t.rows:
    var kept: seq[TermPicture]
    for p in t.screen[row].pics:
      let hit = case d.toLowerAscii
                of 'a': true
                of 'i', 'n': id != 0 and p.image == id and (pid == 0 or p.place == pid)
                of 'c': covers(p, row, p.col, t.cy, t.cx)
                of 'p': covers(p, row, p.col, cy, cx)
                of 'x': cx >= p.col and cx < p.col + p.cols
                of 'y': cy >= row and cy < row + p.rows
                of 'z': p.z == num('z')
                else: false
      if hit: gone.add p.image else: kept.add p
    t.screen[row].pics = kept
  if d in {'i', 'I', 'n', 'N'} and id != 0:
    # (an image's placements in what scrolled off too)
    for i in 0 ..< t.sb.len:
      t.sb[i].pics.keepItIf(not (it.image == id and (pid == 0 or it.place == pid)))
    gone.add id
  if free:
    let placed = t.placedIds()
    for g in gone:
      if g notin placed and t.images.hasKey(g):
        t.imageBytes -= t.images[g].bytes
        t.images.del g
  inc t.ver

proc graphics(t: Terminal; cmd: string) =
  ## A command of the kitty graphics protocol (ESC _ G keys ; data ESC \): a picture sent --
  ## PNG, RGB or RGBA, straight or zlib'ed, here or in a file, in one piece or many -- shown,
  ## put, asked about, taken away.
  let semi = cmd.find(';')
  var k: Table[char, string]
  for part in (if semi < 0: cmd else: cmd[0 ..< semi]).split(','):
    if part.len >= 3 and part[1] == '=': k[part[0]] = part[2 .. ^1]
  var payload = if semi < 0: "" else: cmd[semi + 1 .. ^1]
  template num(c: char; d = 0): int = parseIntOr(k.getOrDefault(c, ""), d)
  if t.gfxMore:
    # (the next piece of a picture sent in pieces: its keys were the first piece's)
    if t.gfxData.len < 64 shl 20: t.gfxData.add payload
    if num('m') == 1: return
    t.gfxMore = false
    k = t.gfxKeys
    payload = move t.gfxData
    t.gfxData = ""
  elif num('m') == 1:
    t.gfxMore = true
    t.gfxKeys = k
    t.gfxData = payload
    return
  let action = k.getOrDefault('a', "t")
  case (if action.len > 0: action[0] else: 't')
  of 't', 'T', 'q':
    var data = ""
    try:
      let raw = decode(payload.strip)
      case k.getOrDefault('t', "d")
      of "d": data = raw
      of "f", "t":
        # (a file named: read; a temporary one, once read, removed -- only from the temp folder,
        # and only one the protocol names so)
        let path = raw
        if not fileExists(path): raise newException(IOError, "no such file")
        data = readFile(path)
        let off = num('O')
        let size = num('S')
        if off > 0 or size > 0: data = data[min(off, data.len) ..< (if size > 0: min(data.len, off + size) else: data.len)]
        if k.getOrDefault('t', "") == "t" and "tty-graphics-protocol" in path and
           path.startsWith(getTempDir()):
          removeFile(path)
      else: raise newException(ValueError, "the medium is not supported")
      if k.getOrDefault('o', "") == "z":
        let b = zlibDecompress(data.toOpenArrayByte(0, data.high), maxOut = 256 shl 20)
        data = newString(b.len)
        if b.len > 0: copyMem(addr data[0], unsafeAddr b[0], b.len)
    except CatchableError:
      t.gfxAnswer(k, "EINVAL:" & getCurrentExceptionMsg().replace(';', ',').replace('\e', ' '))
      return
    var bmp: Bitmap
    let fmt = num('f', 32)
    try:
      case fmt
      of 100: bmp = decodePng(data)
      of 24, 32:
        let w = num('s')
        let h = num('v')
        let bpp = fmt div 8
        if w <= 0 or h <= 0 or w > 10000 or h > 10000 or data.len < w * h * bpp:
          raise newException(ValueError, "the size does not fit the data")
        bmp = newBitmap(w, h)
        for i in 0 ..< w * h:
          let a = if bpp == 4: uint32(ord(data[i * 4 + 3])) else: 255'u32
          bmp.px[i] = (a shl 24) or (uint32(ord(data[i * bpp])) shl 16) or
                      (uint32(ord(data[i * bpp + 1])) shl 8) or uint32(ord(data[i * bpp + 2]))
        bmp.changed()
      else: raise newException(ValueError, "the format is not supported")
    except CatchableError:
      t.gfxAnswer(k, "EBADPNG:" & getCurrentExceptionMsg().replace(';', ',').replace('\e', ' '))
      return
    if action == "q":
      t.gfxAnswer(k, "OK")
      return
    var id = num('i')
    if id <= 0:
      inc t.nextImage
      id = t.nextImage
    if t.images.hasKey(id): t.imageBytes -= t.images[id].bytes
    inc t.imageSerial
    t.images[id] = TermImage(bmp: bmp, number: num('I'), bytes: bmp.w * bmp.h * 4, serial: t.imageSerial)
    t.imageBytes += bmp.w * bmp.h * 4
    if num('I') > 0 and not k.hasKey('i'): k['i'] = $id
    if action == "T" and t.picsOn: t.placePicture(id, k)
    t.trimImages()
    t.gfxAnswer(k, "OK")
  of 'p':
    let id = t.imageById(k)
    if id == 0:
      t.gfxAnswer(k, "ENOENT:no such image")
      return
    if t.picsOn: t.placePicture(id, k)
    t.gfxAnswer(k, "OK")
  of 'd': t.deletePictures(k)
  else: t.gfxAnswer(k, "EINVAL:not supported")

proc apcDone(t: Terminal) =
  ## (an application program command ended: the kitty graphics protocol's, else left)
  if t.apc.len > 0 and t.apc[0] == 'G': t.graphics(t.apc[1 .. ^1])
  t.apc.setLen(0)

proc pictureCount*(t: Terminal): int =
  ## How many pictures are placed in the screen and what scrolled off (the kitty graphics
  ## protocol's placements).
  for l in t.main: result += l.pics.len
  for l in t.alt: result += l.pics.len
  for i in 0 ..< t.sb.len: result += t.sb[i].pics.len

proc imageCount*(t: Terminal): int = t.images.len
  ## How many pictures the program sent are kept (placed or not).

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
  of 'P', 'X', '^':
    t.state = psStr
    return
  of '_':
    t.state = psApc
    t.apc.setLen(0)
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
  of psApc:
    if b == '\e': t.state = psApcEsc
    elif b == '\a':
      t.apcDone()
      t.state = psGround
    elif t.apc.len < 96 shl 20: t.apc.add b
  of psApcEsc:
    if b == '\\':
      t.apcDone()
      t.state = psGround
    else:
      t.apc.add '\e'
      t.apc.add b
      t.state = psApc

proc feed*(t: Terminal; data: string) =
  ## `data` written to the terminal, as a program writes it: text, and the escape sequences
  ## that move the cursor, color, erase, scroll.
  for b in data: t.feedByte(b)

proc showPicture*(t: Terminal; png: string; cols = 0; rows = 0) =
  ## A picture (a PNG file's bytes) shown at the cursor as a program shows one by kitty's
  ## graphics protocol -- `cols` x `rows` cells (0: as big as it is), the cursor moved past it,
  ## scrolled with the text: what an app shows of its own in the terminal it writes to (`feed`).
  if png.len == 0: return
  let data = base64.encode(png)
  var i = 0
  while true:
    let n = min(4096, data.len - i)
    let more = i + n < data.len
    var head = if i == 0: "a=T,f=100,q=2" & (if cols > 0: ",c=" & $cols else: "") &
                          (if rows > 0: ",r=" & $rows else: "")
               else: "q=2"
    head.add(if more: ",m=1" else: ",m=0")
    t.feed("\e_G" & head & ";" & data[i ..< i + n] & "\e\\")
    i += n
    if not more: break

proc takeAnswers*(t: Terminal): string =
  ## What the terminal said back to the program since (the cursor's place asked for, what kind
  ## of terminal it is): sent to the program by itself when there is one.
  result = move t.outbuf
  t.outbuf = ""

proc tellSize(t: Terminal) =
  ## (the program told the terminal's size: its cells, and its pixels)
  when hasPty:
    if t.fd >= 0:
      var ws: Winsize
      ws.ws_row = cushort(t.rows)
      ws.ws_col = cushort(t.cols)
      ws.ws_xpixel = cushort(clamp(t.cols * t.cellPxW, 0, 65535))
      ws.ws_ypixel = cushort(clamp(t.rows * t.cellPxH, 0, 65535))
      discard ioctl(t.fd, TIOCSWINSZ, addr ws)
  elif hasConPty:
    if t.hpc != nil: discard conPty.resize(t.hpc, Coord(x: int16(t.cols), y: int16(t.rows)))

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
  t.tellSize()

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
    ws.ws_xpixel = cushort(clamp(t.cols * t.cellPxW, 0, 65535))
    ws.ws_ypixel = cushort(clamp(t.rows * t.cellPxH, 0, 65535))
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
      # (the signals as a shell expects them: what the app ignores or catches, the program
      # does not -- a pipe closed ends `yes | head`, a child ended is waited for)
      for sig in [SIGPIPE, SIGCHLD, SIGINT, SIGQUIT, SIGTERM, SIGHUP]: discard signal(sig, SIG_DFL)
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

proc keyText(key: KeyCode; shift: bool): string

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
  of KeySlash, KeyMinus: (if ctrl: "\x1F" elif alt: "\e" & keyText(key, shift) else: "")
  else:
    # (Alt and a mark: Esc before it, as xterm's metaSendsEscape -- bash's Alt+. and Alt+<)
    if alt and not ctrl and keyText(key, shift).len > 0: "\e" & keyText(key, shift) else: ""

proc keyText(key: KeyCode; shift: bool): string =
  ## (the text a key types on a US keyboard, shifted or not: "" for a key that types none)
  const plain = [(KeyComma, ',', '<'), (KeyPeriod, '.', '>'), (KeySlash, '/', '?'), (KeyMinus, '-', '_'),
                 (KeyEqual, '=', '+'), (KeyLeftBracket, '[', '{'), (KeyRightBracket, ']', '}'),
                 (KeySemicolon, ';', ':'), (KeyQuote, '\'', '"'), (KeyBackslash, '\\', '|'),
                 (KeyBackquote, '`', '~'), (KeyPlus, '+', '+'), (KeySpace, ' ', ' ')]
  const digits = ")!@#$%^&*("
  case key
  of KeyA .. KeyZ:
    let c = char(ord('a') + ord(key) - ord(KeyA))
    $(if shift: c.toUpperAscii else: c)
  of Key0 .. Key9:
    let i = ord(key) - ord(Key0)
    $(if shift: digits[i] else: char(ord('0') + i))
  else:
    for (k, a, b) in plain:
      if k == key: return $(if shift: b else: a)
    ""

proc kittyKeyBytes*(t: Terminal; key: KeyCode; mods: set[Modifier]; release = false): string =
  ## What a key sends a program that turned the kitty keyboard protocol on (`kbFlags`): Esc and
  ## Ctrl, Alt and Super with any key told apart from what typing makes (CSI code;mods u); with
  ## flag 2 the key let go (`release`) too; with 4 the shifted key; with 8 every key, text too,
  ## as an escape, and with 16 the text it types. "" for a key the text it types says enough
  ## (or a release not asked for).
  let flags = t.kbFlags
  let mac = defined(macosx) or defined(ios)
  let ctrl = if mac: GuiPressed in mods else: CtrlPressed in mods
  let super = if mac: CtrlPressed in mods else: GuiPressed in mods
  let alt = AltPressed in mods
  let shift = ShiftPressed in mods
  let m = 1 + (if shift: 1 else: 0) + (if alt: 2 else: 0) + (if ctrl: 4 else: 0) + (if super: 8 else: 0)
  let all = (flags and 8) != 0
  let events = (flags and 2) != 0
  if release and not events: return ""
  # (the key's number, and the form of its escape: u, ~ or a letter)
  var code = 0
  var final = 'u'
  case key
  of KeyEnter: code = 13
  of KeyTab: code = 9
  of KeyBackspace: code = 127
  of KeyEsc: code = 27
  of KeyInsert: (code, final) = (2, '~')
  of KeyDelete: (code, final) = (3, '~')
  of KeyPageUp: (code, final) = (5, '~')
  of KeyPageDown: (code, final) = (6, '~')
  of KeyUp: (code, final) = (1, 'A')
  of KeyDown: (code, final) = (1, 'B')
  of KeyRight: (code, final) = (1, 'C')
  of KeyLeft: (code, final) = (1, 'D')
  of KeyHome: (code, final) = (1, 'H')
  of KeyEnd: (code, final) = (1, 'F')
  of KeyF1: (code, final) = (1, 'P')
  of KeyF2: (code, final) = (1, 'Q')
  of KeyF3: (code, final) = (13, '~')
  of KeyF4: (code, final) = (1, 'S')
  of KeyF5: (code, final) = (15, '~')
  of KeyF6: (code, final) = (17, '~')
  of KeyF7: (code, final) = (18, '~')
  of KeyF8: (code, final) = (19, '~')
  of KeyF9: (code, final) = (20, '~')
  of KeyF10: (code, final) = (21, '~')
  of KeyF11: (code, final) = (23, '~')
  of KeyF12: (code, final) = (24, '~')
  of KeyCapslock: code = 57358
  of KeyMenu: code = 57363
  else:
    let txt = keyText(key, false)
    if txt.len == 0: return ""
    code = ord(txt[0])
  let texty = final == 'u' and code >= 32 and code < 127
  # what typing says enough: a key that types text, with nothing but Shift; Enter, Tab and
  # Backspace with no modifier -- unless every key is asked for as an escape
  if not all and not release:
    if texty and (m == 1 or m == 2): return ""
    if code in [13, 9, 127] and final == 'u' and m == 1: return ""
    if final != 'u' and m == 1 and not events:
      return t.keyBytes(key, mods)          # (the arrows, F1-F12...: as xterm sends them)
  if release and not all and code in [13, 9, 127] and final == 'u': return ""
  var keyField = $code
  if (flags and 4) != 0 and shift and texty:
    let sh = keyText(key, true)
    if sh.len > 0 and sh[0] != char(code): keyField.add ":" & $ord(sh[0])
  var modField = ""
  if m != 1 or release: modField = $m
  if release: modField.add ":3"
  var textField = ""
  if all and (flags and 16) != 0 and texty and not release and not ctrl and not alt and not super:
    let tx = keyText(key, shift)
    if tx.len > 0: textField = $ord(tx[0])
  if final != 'u':
    # (the legacy forms with their numbers: CSI 1;mods A -- the 1 left out alone)
    if modField.len == 0: return (if code == 1: "\e[" & final else: "\e[" & $code & final)
    return "\e[" & $code & ";" & modField & final
  result = "\e[" & keyField
  if modField.len > 0 or textField.len > 0: result.add ";" & (if modField.len > 0: modField else: "1")
  if textField.len > 0: result.add ";" & textField
  result.add 'u'

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

proc brightOf(t: Terminal; v: uint32): uint32 =
  ## (a bold letter's color with `boldBright`: one of the eight, its bright one; the text's own
  ## color, the bright one of the eight it is -- not black: black on white stays black)
  let k = v shr 24
  if k == 1 and (v and 255) < 8: return v + 8
  if k == 0:
    for i in 1 ..< 8:
      if t.colors.ansi[i] == t.colors.fg: return 0x1000000'u32 + uint32(i + 8)
  v

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

proc selectionStart*(t: Terminal): tuple[line, col: int] =
  ## Where the chosen text begins: its line, counted from the oldest kept that scrolled off
  ## (then the screen's), and its cell; (-1, -1) when none is chosen.
  if not t.selOn: (-1, -1) else: t.ordered().a

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

proc selectNone*(t: Terminal) =
  ## Nothing chosen (a find starts again from the bottom).
  if t.selOn:
    t.selOn = false
    inc t.ver

proc clearScrollback*(t: Terminal) =
  ## What scrolled off forgotten.
  t.sb.clear()
  t.viewTop = 0
  t.selOn = false
  inc t.ver

proc reset*(t: Terminal; clear = false) =
  ## The terminal as it starts: the modes, the colors, the character sets, the pictures and the
  ## keys' flags back, the screen blank; `clear`: what scrolled off forgotten too. The program
  ## goes on.
  t.fullReset()
  if clear: t.clearScrollback()

proc findText*(t: Terminal; text: string; back = true; matchCase = false): bool =
  ## The next `text` in what scrolled off and the screen -- before the text chosen (`back`) or
  ## after it, from the bottom (or the top) when none is -- chosen, and the view scrolled to it;
  ## false when there is no more.
  if text.len == 0: return false
  let needle = if matchCase: text else: text.toLowerAscii
  let n = t.totalLines
  var li = if t.selOn: t.ordered().a.line else: (if back: n - 1 else: 0)
  var from0 = if t.selOn: t.ordered().a.col else: (if back: t.cols else: -1)
  for step in 0 ..< n + 1:
    if li < 0 or li >= n: return false
    let l = t.lineAt(li)
    # (the line's text, and where each of its characters is a cell)
    var hay = ""
    var cellAt: seq[int]
    for c, cell in l.cells:
      if cell.ch == -1: continue
      let piece = if cell.ch > 0: Rune(cell.ch).toUtf8 else: " "
      for b in piece:
        hay.add b
        cellAt.add c
    if not matchCase: hay = hay.toLowerAscii
    var found = -1
    if back:
      var at = hay.rfind(needle)
      while at >= 0 and cellAt[at] >= from0:
        at = if at > 0: hay.rfind(needle, last = at - 1) else: -1
      found = at
    else:
      var at = hay.find(needle)
      while at >= 0 and cellAt[at] <= from0: at = hay.find(needle, at + 1)
      found = at
    if found >= 0:
      t.selA = (li, cellAt[found])
      t.selB = (li, cellAt[min(cellAt.high, found + needle.len - 1)])
      t.selOn = true
      t.showLine = li
      inc t.ver
      return true
    li += (if back: -1 else: 1)
    from0 = if back: t.cols + 1 else: -1
  false

proc zoomText*(t: Terminal; steps: int) =
  ## The terminal's text bigger (`steps` > 0) or smaller by a tenth a step, between half and
  ## three times the UI's; 0: as big as the UI's.
  t.fontSize = if steps == 0: 1.0 else: clamp(t.fontSize + 0.1 * float(steps), 0.5, 3.0)
  inc t.ver

proc terminalEditItems*(t: Terminal) =
  ## The terminal's Copy, Paste and Select All as items of a menu of the app's own (its menu
  ## bar's Edit menu), with their keys.
  let mac = defined(macosx) or defined(ios)
  if menuItem("&Copy", if mac: "Cmd+C" else: "Ctrl+Shift+C", enabled = t.selOn):
    putClipboardText(t.selectionText())
  if menuItem("&Paste", if mac: "Cmd+V" else: "Ctrl+Shift+V"):
    t.paste(getClipboardText())
  if menuItem("Select &All"): t.selectAll()

proc terminalViewItems*(t: Terminal) =
  ## The terminal's text bigger, smaller and back to its size, as items of a menu of the app's
  ## own (View), with their keys.
  let mac = defined(macosx) or defined(ios)
  if menuItem("&Bigger Text", if mac: "Cmd+Shift+=" else: "Ctrl+Shift+="): t.zoomText(1)
  if menuItem("&Smaller Text", if mac: "Cmd+Shift+-" else: "Ctrl+Shift+-"): t.zoomText(-1)
  if menuItem("&Normal Size", if mac: "Cmd+Shift+0" else: "Ctrl+Shift+0"): t.zoomText(0)

proc terminalItems*(t: Terminal) =
  ## The terminal's own commands as items of a menu of the app's own (Terminal): Clear
  ## Scrollback, Reset, Reset and Clear.
  if menuItem("C&lear Scrollback"): t.clearScrollback()
  if menuItem("&Reset"): t.reset()
  if menuItem("Reset and &Clear"): t.reset(clear = true)

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

proc memoColor(t: Terminal; memo: var tuple[raw: uint32; c: Color]; raw: uint32; fg: bool): Color {.inline.} =
  ## (`colorOf`, the last one kept: a row's cells mostly share their colors)
  if raw != memo.raw: memo = (raw, t.colorOf(raw, fg))
  memo.c

type
  BidiRow = object
    ## (a row with right-to-left letters, as it is shown)
    line: TermLine           # (its cells in the order they are shown)
    logOf: seq[int]          # (each place shown: the column the program wrote it in)
    visOf: seq[int]          # (each column: the place it is shown at)
    rtl: seq[bool]           # (each place shown: in a right-to-left run -- drawn with its run)

proc rtlLetter(c: int32): bool {.inline.} =
  ## (a letter of a right-to-left script: Hebrew, Arabic, Syriac, Thaana, N'Ko..., their
  ## presentation forms)
  (c >= 0x0590 and c <= 0x08FF) or (c >= 0xFB1D and c <= 0xFDFF) or (c >= 0xFE70 and c <= 0xFEFF) or
    (c >= 0x10800 and c <= 0x10FFF) or (c >= 0x1E800 and c <= 0x1EFFF)

proc bidiRow(t: Terminal; l: ptr TermLine; br: var BidiRow): bool =
  ## A row with right-to-left letters in the order it is read: the Unicode bidirectional
  ## algorithm on the row's text up to its last letter (the blanks after stay where they are),
  ## the row's direction its first strong letter's -- a prompt's line left to right with the
  ## Arabic typed in it right to left, a line of an Arabic file right to left. False for a row
  ## of left-to-right text alone (shown as written).
  if not t.bidi: return false
  let n = min(l.cells.len, t.cols)
  var any = false
  for c in 0 ..< n:
    if rtlLetter(l.cells[c].ch):
      any = true
      break
  if not any: return false
  var ends = n
  while ends > 0 and l.cells[ends - 1].ch in [0'i32, 32'i32] and l.cells[ends - 1].bg == 0 and
        l.cells[ends - 1].attrs * {taInverse, taUnderline, taStrike} == {}:
    dec ends
  # (each character: a cell, or a wide one's two)
  var units: seq[tuple[col, cells: int]]
  var s = ""
  var c = 0
  while c < ends:
    let ch = l.cells[c].ch
    let k = if c + 1 < n and l.cells[c + 1].ch == -1 and ch > 0: 2 else: 1
    units.add (c, k)
    s.add(if ch > 32 and ch < 0x110000: Rune(ch).toUtf8 else: " ")
    c += k
  let info = bidiInfo(s)
  if info.levels.len != units.len: return false
  let order = visualOrderOf(info.levels)
  br.line.cells.setLen(n)
  br.logOf.setLen(n)
  br.visOf.setLen(n)
  br.rtl.setLen(n)
  for i in 0 ..< n:
    br.line.cells[i] = l.cells[i]
    br.logOf[i] = i
    br.rtl[i] = false
  var vc = 0
  for k in order:
    let u = units[k]
    for j in 0 ..< u.cells:
      br.line.cells[vc + j] = l.cells[u.col + j]
      br.logOf[vc + j] = u.col + j
      br.rtl[vc + j] = (info.levels[k] and 1) == 1
    vc += u.cells
  for i in 0 ..< n: br.visOf[br.logOf[i]] = i
  true

proc shownText*(t: Terminal; row: int): string =
  ## The text of row `row` of the screen as it is shown, its cells from left to right: a row
  ## with right-to-left letters (Arabic, Hebrew) in the order it is read (`bidi`), else as
  ## `text`.
  var br: BidiRow
  let l = addr t.screen[clamp(row, 0, t.rows - 1)]
  if not t.bidiRow(l, br): return t.text(row)
  br.line.lineText.strip(leading = false)

proc logicalCol(t: Terminal; li, col: int): int =
  ## (the column the program wrote what is shown at place `col` of line `li` in)
  var br: BidiRow
  if col < t.cols and t.bidiRow(t.lineAt(li), br) and col < br.logOf.len: br.logOf[col] else: col

var
  rowBidi: BidiRow                 # (the row drawn, when it has right-to-left letters)
  rowFg: seq[Color]                # (a row's letters' colors, worked out once: kept for the next)
  rowText: string                  # (a run of a row's letters)

proc terminalKeysFirst*(t: Terminal) =
  ## The keys an app's menu bar would take -- Alt and a letter, F10 -- given to the program in
  ## the terminal while it has the focus (bash's Alt+B and Alt+F, Midnight Commander's and
  ## htop's F10): call it before the menu bar. Alt pressed and let go alone still opens the
  ## menu bar, and so does the mouse.
  if ui.key == KeyNone or ui.keyUsed or t.viewId == 0 or ui.focus != t.viewId or not canInput() or
     ui.popup != 0: return
  if not (ui.key == KeyF10 or (AltPressed in ui.mods and CtrlPressed notin ui.mods and ui.mnemonic != '\0')):
    return
  let b = if t.kbFlags != 0: t.kittyKeyBytes(ui.key, ui.mods) else: t.keyBytes(ui.key, ui.mods)
  if b.len == 0: return
  ui.keyUsed = true
  ui.mnemonic = '\0'
  t.send(b)
  t.viewTop = 0
  t.selOn = false
  wakeIn(5)

proc terminalView*(t: Terminal; w = 0; lines = 24; focusFirst = false; menu: proc () = nil) =
  ## The terminal in a box `w` wide (0: the row's width) and `lines` rows of its text high (-1:
  ## the height left) -- its size in cells made to fit it, the program told. Takes the keys
  ## while it has the focus (Tab and the arrows too) -- as kitty sends them to a program that
  ## asks (`kbFlags`) -- the wheel scrolls back through what scrolled off; the mouse chooses
  ## text (double-click a word, triple a line), Ctrl+Shift+C copies it, Ctrl+Shift+V and
  ## Shift+Insert paste, Ctrl+Shift+= and Ctrl+Shift+- make its text bigger and smaller
  ## (Ctrl+Shift+0: back). The pictures a program sends by kitty's graphics protocol are shown
  ## in their cells. A right click has a menu: Copy, Paste, Select All, then what `menu` adds
  ## (its `menuItem`s: the app's own), then the terminal's own (`terminalItems`). For the
  ## app's menu bar: `terminalEditItems`, `terminalViewItems`, `terminalItems`.
  let st = style(mono = true, size = t.fontSize)
  let cw = max(1, textWidth("M", st))
  let lh = max(1, lineHeight(st))
  let h = if lines < 0: remainingH() else: lines * lh + 4
  let r = place(if w > 0: w else: 0, h, fill = w <= 0)
  let id = makeId(mixId(fnv("terminal"), uint32(cast[uint](t) shr 4 and 0xFFFFFFFF'u)))
  t.viewId = id
  let hit = interact(id, r)
  if focusFirst and ui.focus == 0: ui.focus = id
  beginKeepSides(r)                  # (left to right in a right-to-left window too, the mouse read so)
  if t.themed:
    t.colors = if themeIsDark(ui.theme): DarkColors else: LightColors
  let bar = SbW
  let inner = rect(r.x + 2, r.y + 2, r.w - 4 - bar, r.h - 4)
  let cols = max(2, inner.w div cw)
  let rows = max(1, inner.h div lh)
  if cw * pxScale != t.cellPxW or lh * pxScale != t.cellPxH:
    # (a cell's size in pixels, for the programs that size pictures by it)
    t.cellPxW = cw * pxScale
    t.cellPxH = lh * pxScale
    t.tellSize()
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
    # (the text's size: Ctrl+Shift+=, Ctrl+Shift+-, Ctrl+Shift+0 -- Cmd on a Mac)
    let zoomMods = if mac: CtrlPressed in ui.mods and ShiftPressed in ui.mods
                   else: CtrlPressed in ui.mods and ShiftPressed in ui.mods
    if zoomMods and not ui.keyUsed and ui.key in {KeyEqual, KeyPlus, KeyMinus, Key0}:
      ui.keyUsed = true
      t.zoomText(case ui.key
                 of KeyMinus: -1
                 of Key0: 0
                 else: 1)
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
    elif ui.key in {KeyPageUp, KeyPageDown} and ShiftPressed in ui.mods and CtrlPressed notin ui.mods and
         AltPressed notin ui.mods and not t.onAlt and not ui.keyUsed:
      # (Shift+Page Up and Page Down: back through what scrolled off and down again, a screen
      # at a time, as xterm has them)
      ui.keyUsed = true
      let page = max(1, t.rows - 1) * lh
      t.viewTop = clamp(t.viewTop + (if ui.key == KeyPageUp: page else: -page), 0, t.sb.len * lh)
    elif ui.key != KeyNone and not ui.keyUsed and not (mac and CtrlPressed in ui.mods and t.kbFlags == 0):
      let b = if t.kbFlags != 0: t.kittyKeyBytes(ui.key, ui.mods) else: t.keyBytes(ui.key, ui.mods)
      if b.len > 0:
        ui.keyUsed = true
        t.send(b)
        sent = true
        # (a key sent as an escape: the text it types, coming after it, not sent again)
        if t.kbFlags != 0 and keyText(ui.key, false).len > 0: dropKeyText = true
    if ui.keyUp != KeyNone and (t.kbFlags and 2) != 0:
      t.send(t.kittyKeyBytes(ui.keyUp, ui.mods, release = true))
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
  if t.showLine >= 0:
    # (a line found: in the middle of the view)
    off = clamp(t.showLine * lh - (inner.h - lh) div 2, 0, maxOff)
    t.showLine = -1
  scrollWheel(id, off, maxOff, inner, 3 * lh)
  scrollTick(id, off, maxOff)
  # the mouse: text chosen, or the program's when it asked
  template cellAt(px, py: int): tuple[line, col: int] =
    # (where the program wrote what is shown there: a right-to-left row is shown in another order)
    block:
      let li = clamp((py - inner.y + off) div lh, 0, t.totalLines - 1)
      (li, t.logicalCol(li, clamp((px - inner.x) div cw, 0, t.cols - 1)))
  if canInput() and mouseIn(inner) and t.mouseMode != 0 and ShiftPressed notin ui.mods and
     t.viewTop == 0:
    let mrow = clamp((ui.my - inner.y) div lh, 0, t.rows - 1)
    let mcol = t.logicalCol(sbLines + mrow, clamp((ui.mx - inner.x) div cw, 0, t.cols - 1))
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
  # draw: the background, then each row -- its colors, its text, its lines and blocks (Glass: a
  # rounded field, the highlight's ring while it has the keys)
  let glass = glassLook()
  if glass: fieldFace(r, t.colors.bg, focused = hit.focused)
  else: fill(r, t.colors.bg)
  pushClip(inner)
  let first = off div lh
  let y0 = inner.y - (off mod lh)
  let cursorLine = sbLines + t.cy
  template drawPictures(under: bool) =
    # (each picture from its line on, a line above the view's top reaching into it too; drawn at
    # its cells' size, in pixels as the program sent it)
    if t.picsOn:
      for li in max(0, first - 200) .. min(t.totalLines - 1, first + inner.h div lh + 1):
        let l = t.lineAt(li)
        for p in l.pics:
          if (p.z < 0) != under or not t.images.hasKey(p.image): continue
          let im = t.images[p.image]
          let s = max(1, pxScale)
          let pr = rect(inner.x + p.col * cw + p.dx div s, y0 + (li - first) * lh + p.dy div s,
                        (im.bmp.w + s - 1) div s, (im.bmp.h + s - 1) div s)
          let room = rect(inner.x + p.col * cw, y0 + (li - first) * lh, p.cols * cw, p.rows * lh)
          if pr.y > inner.y + inner.h or pr.y + pr.h < inner.y: continue
          pushClip(intersect(room, inner))
          # (its cells given: it fills them; else as many pixels as it was sent with)
          if p.scaled: drawBitmap(rect(pr.x, pr.y, room.w - (pr.x - room.x), room.h - (pr.y - room.y)), im.bmp)
          else: drawBitmap(pr, im.bmp)
          popClip()
  drawPictures(true)
  # (each row in two passes: its backgrounds, a fill for a run of cells of one color; then its
  # letters, a command for a run of plain ASCII in one color and style -- `textCells`, each
  # letter in its cell -- the others a cell at a time)
  let styles = [style(mono = true, size = t.fontSize, bold = t.boldText),
                style(mono = true, size = t.fontSize, bold = true),
                style(mono = true, size = t.fontSize, italic = true),
                style(mono = true, size = t.fontSize, bold = true, italic = true)]
  var memoFg, memoBg = (raw: high(uint32), c: Color())
  var cursorCol = t.cx                 # (where the cursor is shown: another place in a right-to-left row)
  for k in 0 .. inner.h div lh + 1:
    let li = first + k
    if li >= t.totalLines: break
    var l = t.lineAt(li)
    let y = y0 + k * lh
    let n = min(l.cells.len, t.cols)
    if rowFg.len < n: rowFg.setLen(n)
    # (a row with right-to-left letters: its cells in the order they are read, each one's own
    # column kept for the chosen text and the cursor)
    let bidi = t.bidiRow(l, rowBidi)
    if bidi:
      l = addr rowBidi.line
      if li == cursorLine and t.cx < rowBidi.visOf.len: cursorCol = rowBidi.visOf[t.cx]
    # the backgrounds, and each cell's colors
    var bgX = -1
    var bgEnd = 0
    var bgC: Color
    var c = 0
    while c < n:
      let cell = l.cells[c]
      var fg = t.memoColor(memoFg, (if t.boldBright and taBold in cell.attrs: t.brightOf(cell.fg) else: cell.fg), true)
      var bg = t.memoColor(memoBg, cell.bg, false)
      if taInverse in cell.attrs: swap(fg, bg)
      if taFaint in cell.attrs: fg = mixColor(fg, bg, 0.45)
      let wide = c + 1 < l.cells.len and l.cells[c + 1].ch == -1
      let cells = if wide: 2 else: 1
      let x = inner.x + c * cw
      let own = if bidi: rowBidi.logOf[c] else: c
      if t.selected(li, own):
        bg = t.colors.selection
        let sc = t.colors.selection
        if int(sc.r) * 3 + int(sc.g) * 6 + int(sc.b) < 1280: fg = color(255, 255, 255)   # (on a dark one)
      let onCursor = li == cursorLine and own == t.cx and t.cursorOn and t.viewTop == 0 and
                     (t.cursorShape <= 2)
      if onCursor and hit.focused and ui.active31:
        swap(fg, bg)
        bg = t.colors.cursor
        fg = t.colors.bg
      rowFg[c] = fg
      if bg != t.colors.bg:
        if bgX >= 0 and bgEnd == x and bgC == bg: bgEnd = x + cw * cells
        else:
          if bgX >= 0: fill(rect(bgX, y, bgEnd - bgX, lh), bgC)
          bgX = x
          bgEnd = x + cw * cells
          bgC = bg
      c += cells
    if bgX >= 0: fill(rect(bgX, y, bgEnd - bgX, lh), bgC)
    # the letters, the lines under and through
    var runX = -1
    var runEnd = 0
    var runFg: Color
    var runSt = 0
    rowText.setLen(0)
    c = 0
    while c < n:
      let cell = l.cells[c]
      let wide = c + 1 < l.cells.len and l.cells[c + 1].ch == -1
      let cells = if wide: 2 else: 1
      let x = inner.x + c * cw
      let fg = rowFg[c]
      if bidi and rowBidi.rtl[c] and cell.ch > 32 and taHidden notin cell.attrs:
        # (a right-to-left run -- the cells after this one in it of its color and style, to its
        # last letter -- drawn as one text: Arabic's letters joined, in the run's cells)
        let sk = ord(taBold in cell.attrs or t.boldText) + 2 * ord(taItalic in cell.attrs)
        var e = c
        var last = c
        while e + 1 < n and rowBidi.rtl[e + 1] and rowFg[e + 1] == fg and
              (ord(taBold in l.cells[e + 1].attrs or t.boldText) + 2 * ord(taItalic in l.cells[e + 1].attrs) == sk or
               l.cells[e + 1].ch <= 32):
          inc e
          if l.cells[e].ch > 32: last = e
        var word = ""
        for v in countdown(last, c):
          let ch = l.cells[v].ch
          if ch > 32 and ch < 0x110000: word.add Rune(ch).toUtf8
          elif ch != -1: word.add ' '
        let room = (last - c + 1) * cw
        var st = styles[sk]
        var w = textWidth(word, st)
        if w > room:
          # (wider than its cells in the font: smaller, to keep in them)
          st.size = max(0.3'f32, (if st.size > 0: st.size else: 1'f32) * float32(room) / float32(w))
          w = textWidth(word, st)
        text(x + (room - w) div 2, y + (lh - lineHeight(st)) div 2, word, fg, st)
        for v in c .. last:
          let vc = l.cells[v]
          let vx = inner.x + v * cw
          if taUnderline in vc.attrs: fill(rect(vx, y + lh - max(1, lh div 12) - 1, cw, max(1, lh div 12)), rowFg[v])
          if taStrike in vc.attrs: fill(rect(vx, y + lh div 2, cw, max(1, lh div 14)), rowFg[v])
        c = last + 1
        continue
      if cell.ch > 32 and taHidden notin cell.attrs:
        let sk = ord(taBold in cell.attrs or t.boldText) + 2 * ord(taItalic in cell.attrs)
        if cell.ch < 127:
          if runX >= 0 and runFg == fg and runSt == sk:
            # (the cells between, blanks or drawn alone, as spaces)
            for _ in 0 ..< (x - runEnd) div cw: rowText.add ' '
          else:
            if runX >= 0: textCells(runX, y, rowText, runFg, styles[runSt], cw)
            rowText.setLen(0)
            runX = x
            runFg = fg
            runSt = sk
          rowText.add char(cell.ch)
          runEnd = x + cw
        else:
          let cr = rect(x, y, cw * cells, lh)
          if not boxChar(cell.ch, cr, fg, cw):
            # (a character of another width in the font: in the middle of its cells)
            let s = Rune(cell.ch).toUtf8
            let gs = styles[sk]
            let gw = textWidth(s, gs)
            text(x + (cw * cells - gw) div 2, y, s, fg, gs)
      if taUnderline in cell.attrs: fill(rect(x, y + lh - max(1, lh div 12) - 1, cw * cells, max(1, lh div 12)), fg)
      if taStrike in cell.attrs: fill(rect(x, y + lh div 2, cw * cells, max(1, lh div 14)), fg)
      c += cells
    if runX >= 0: textCells(runX, y, rowText, runFg, styles[runSt], cw)
  # the cursor: a block (hollow without the focus), a line under, a bar
  if t.cursorOn and t.viewTop == 0 and cursorLine >= first and cursorLine <= first + inner.h div lh + 1:
    let x = inner.x + cursorCol * cw
    let y = y0 + (cursorLine - first) * lh
    let cc = t.colors.cursor
    if t.cursorShape in [3, 4]: fill(rect(x, y + lh - max(2, lh div 8), cw, max(2, lh div 8)), cc)
    elif t.cursorShape in [5, 6]: fill(rect(x, y, max(2, cw div 6), lh), cc)
    elif not hit.focused or not ui.active31: box(rect(x, y, cw, lh), cc)   # (hollow: another has the keys)
  drawPictures(false)
  popClip()
  endKeepSides()
  # the scroll bar
  if maxOff > 0:
    var v = off
    let sb = if glass: rect(r.x + r.w - bar - 1, r.y + dp(4), bar, r.h - 2 * dp(4))
             else: rect(r.x + r.w - bar, r.y, bar, r.h)
    scrollBarFor(id + 77, id, sb, true, v, maxOff, max(lh, inner.h - lh), lh)
    if v != off: t.viewTop = maxOff - v
  if not glass: box(r, if hit.focused: ui.theme.select else: mixColor(t.colors.bg, t.colors.fg, 0.25))
  if accessible():
    # (a screen reader reads the screen as text, its caret where the cursor is)
    var s = ""
    var caret = 0
    for row in 0 ..< t.rows:
      let line = t.text(row)
      if row > 0: s.add '\n'
      if row == t.cy: caret = s.runeLen + min(t.cx, line.runeLen)
      s.add line
    let k = accessNode(arTextArea, t.title, s, {asMultiLine}, id, r)
    accessText(k, caret, caret, caret)
  # the right click's menu: Copy, Paste, Select All, the app's own items, the terminal's
  contextMenu:
    t.terminalEditItems()
    if menu != nil:
      menuSeparator()
      menu()
    menuSeparator()
    t.terminalItems()
  # more frames: what comes from the program wakes the window where it can, else it is asked
  # for now and then
  if t.ver != before: wakeIn(16)             # (more may come at once)
  if t.running:
    const watched = (defined(linux) or defined(bsd)) and not androidApp   # (a program in Termux: X11's)
    wakeIn(if watched: 1000 else: 33)
