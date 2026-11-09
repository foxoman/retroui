## A mouse and a keyboard that are not there, for testing the Wayland
## driver on a compositor without devices (sway headless): they are made
## once with wlroots' virtual pointer and the virtual keyboard protocol
## and kept while the commands on the standard input (or the arguments)
## are played:
##
##   abs X Y W H        the pointer to X, Y of a W x H screen (the
##                      compositor's units)
##   move DX DY         ... by so much
##   down / up / click  the left button (`down right`, `click middle`...)
##   wheel N            the wheel N notches (up: N > 0)
##   key NAME           a key pressed and let go (enter, tab, esc, a,
##                      ctrl+a, shift+tab...)
##   type TEXT          ASCII text, typed on a US keyboard
##   wait MS            a pause
##
## Built with the toolkit's own Wayland code (no libwayland).

import std/[os, strutils, posix]
import retroui/uirelays/drivers/[wlwire, xkbload]

var
  conn: WlConn
  reg, seat, vpManager, vkManager, vp, vk: uint32
  done: seq[uint32]
  time = 1'u32

proc roundtrip() =
  let cb = conn.newId()
  conn.send(1, 0, wu(cb))
  discard conn.flush()
  while cb notin done and not conn.failed:
    if conn.readSome(1000):
      var m: WlMsg
      while conn.next(m):
        if m.obj == 1 and m.op == 1: conn.idDeleted(m.u32)
        elif m.obj == 1 and m.op == 0:
          discard m.u32
          discard m.u32
          quit "vinput: protocol error: " & m.str
        elif m.obj == reg and m.op == 0:
          let name = m.u32
          let iface = m.str
          let version = m.u32
          var id = 0'u32
          case iface
          of "wl_seat":
            if seat == 0: seat = conn.newId(); id = seat
          of "zwlr_virtual_pointer_manager_v1": vpManager = conn.newId(); id = vpManager
          of "zwp_virtual_keyboard_manager_v1": vkManager = conn.newId(); id = vkManager
          else: discard
          if id != 0: conn.send(reg, 0, wu(name), ws(iface), wu(min(version, 2)), wu(id))
        elif m.op == 0 and m.obj != reg:
          done.add m.obj

proc tick(): uint32 =
  time += 10
  time

const names = {"enter": 28, "return": 28, "tab": 15, "esc": 1, "escape": 1, "backspace": 14,
               "delete": 111, "left": 105, "right": 106, "up": 103, "down": 108, "home": 102,
               "end": 107, "pageup": 104, "pagedown": 109, "space": 57, "f1": 59, "f2": 60,
               "f10": 68, "menu": 127}

const usRow1 = "1234567890-="
const usRow2 = "qwertyuiop[]"
const usRow3 = "asdfghjkl;'`"
const usRow4 = "\\zxcvbnm,./"
const shifted = "!@#$%^&*()_+QWERTYUIOP{}ASDFGHJKL:\"~|ZXCVBNM<>?"
const plain   = "1234567890-=qwertyuiop[]asdfghjkl;'`\\zxcvbnm,./"

proc codeOf(c: char): int =
  ## evdev's code of a character on a US keyboard (0: none).
  let i1 = usRow1.find(c)
  if i1 >= 0: return 2 + i1
  let i2 = usRow2.find(c)
  if i2 >= 0: return 16 + i2
  let i3 = usRow3.find(c)
  if i3 >= 0: return 30 + i3
  let i4 = usRow4.find(c)
  if i4 >= 0: return 43 + i4
  if c == ' ': return 57
  0

proc mods(shift, ctrl, alt: bool) =
  var m = 0'u32
  if shift: m = m or 1
  if ctrl: m = m or 4
  if alt: m = m or 8
  conn.send(vk, 2, wu(m), wu(0), wu(0), wu(0))

proc press(code: int; shift = false; ctrl = false; alt = false) =
  if shift: conn.send(vk, 1, wu(tick()), wu(42), wu(1))
  if ctrl: conn.send(vk, 1, wu(tick()), wu(29), wu(1))
  if alt: conn.send(vk, 1, wu(tick()), wu(56), wu(1))
  mods(shift, ctrl, alt)
  conn.send(vk, 1, wu(tick()), wu(code), wu(1))
  conn.send(vk, 1, wu(tick()), wu(code), wu(0))
  if alt: conn.send(vk, 1, wu(tick()), wu(56), wu(0))
  if ctrl: conn.send(vk, 1, wu(tick()), wu(29), wu(0))
  if shift: conn.send(vk, 1, wu(tick()), wu(42), wu(0))
  mods(false, false, false)
  roundtrip()

proc button(which: string): uint32 =
  case which
  of "right": 0x111
  of "middle": 0x112
  else: 0x110

proc run(line: string) =
  let parts = line.strip.splitWhitespace
  if parts.len == 0 or parts[0].startsWith("#"): return
  let rest = if line.strip.len > parts[0].len: line.strip[parts[0].len + 1 .. ^1] else: ""
  case parts[0]
  of "abs":
    let (x, y, w, h) = (parseInt(parts[1]), parseInt(parts[2]), parseInt(parts[3]), parseInt(parts[4]))
    conn.send(vp, 1, wu(tick()), wu(x), wu(y), wu(w), wu(h))
    conn.send(vp, 4)
  of "move":
    conn.send(vp, 0, wu(tick()), wfixed(parseFloat(parts[1])), wfixed(parseFloat(parts[2])))
    conn.send(vp, 4)
  of "down", "up":
    conn.send(vp, 2, wu(tick()), wu(button(if parts.len > 1: parts[1] else: "left")),
              wu(if parts[0] == "down": 1 else: 0))
    conn.send(vp, 4)
  of "click":
    let b = button(if parts.len > 1: parts[1] else: "left")
    conn.send(vp, 2, wu(tick()), wu(b), wu(1))
    conn.send(vp, 4)
    roundtrip()
    conn.send(vp, 2, wu(tick()), wu(b), wu(0))
    conn.send(vp, 4)
  of "wheel":
    let n = parseInt(parts[1])
    conn.send(vp, 5, wu(0))                                  # axis_source: wheel
    conn.send(vp, 7, wu(tick()), wu(0), wfixed(float(-n * 15)), wi(-n))   # axis_discrete
    conn.send(vp, 4)
  of "key":
    var shift, ctrl, alt = false
    var name = ""
    for p in parts[1].toLowerAscii.split('+'):
      case p
      of "shift": shift = true
      of "ctrl": ctrl = true
      of "alt": alt = true
      else: name = p
    var code = 0
    for (n, c) in names:
      if n == name: code = c
    if code == 0 and name.len == 1: code = codeOf(name[0])
    if code == 0: quit "vinput: no such key: " & parts[1]
    press(code, shift, ctrl, alt)
  of "type":
    for c in rest:
      let i = shifted.find(c)
      if i >= 0: press(codeOf(plain[i]), shift = true)
      elif codeOf(c) != 0: press(codeOf(c))
  of "wait": sleep(parseInt(parts[1]))
  else: quit "vinput: what is " & parts[0] & "?"
  roundtrip()

conn = wlConnect()
if conn == nil: quit "vinput: no Wayland compositor"
reg = conn.newId()
conn.send(1, 1, wu(reg))                                     # get_registry
roundtrip()
roundtrip()
if seat == 0 or vpManager == 0 or vkManager == 0:
  quit "vinput: the compositor has no virtual pointer or keyboard"
vp = conn.newId()
conn.send(vpManager, 0, wu(seat), wu(vp))                     # create_virtual_pointer
vk = conn.newId()
conn.send(vkManager, 0, wu(seat), wu(vk))                     # create_virtual_keyboard
var kb: XkbKeyboard
if not kb.fromSystem("us"): quit "vinput: libxkbcommon is needed"
let km = kb.keymapText
let fd = memFile(km.len + 1)
discard posix.write(fd, unsafeAddr km[0], km.len)
var nul = '\0'
discard posix.write(fd, addr nul, 1)
conn.send(vk, 0, wu(1), wfd(fd), wu(km.len + 1))             # keymap
discard conn.flush()
discard posix.close(fd)
roundtrip()
sleep(300)                                                    # (the clients get the devices)
if paramCount() > 0:
  for i in 1 .. paramCount(): run(paramStr(i))
else:
  for line in stdin.lines: run(line)
sleep(200)
