## The tray icon on Linux: the app's StatusNotifierItem on a session bus
## of the test's own, registered with a stand-in for the desktop's tray
## (the StatusNotifierWatcher, on a thread), its properties and menu as
## the tray reads them, and a click and a menu item coming back as the
## app's events. Skipped without dbus-daemon.

import std/[os, strutils, atomics]
import retroui
import retroui/tray
import retroui/uirelays/dbus
import harness

when not defined(linux):
  echo "test_tray: Linux only"
  quit 0

if findExe("dbus-daemon").len == 0:
  echo "test_tray: skipped (no dbus-daemon)"
  quit 0

let addrFile = getTempDir() / "retro-tray-bus-" & $getCurrentProcessId()
doAssert execShellCmd("dbus-daemon --session --fork --print-pid=4 --print-address=3 3>" &
                      quoteShell(addrFile) & " 4>" & quoteShell(addrFile & ".pid") &
                      " >/dev/null 2>&1 </dev/null") == 0
putEnv("DBUS_SESSION_BUS_ADDRESS", readFile(addrFile).strip.splitLines[0])

# the desktop's tray: the watcher items register with
var watcherUp, registered, stop: Atomic[bool]
proc watcher() {.thread.} =
  let bus = sessionBus()
  var w: DBusWriter
  w.str("org.kde.StatusNotifierWatcher")
  w.u32(4)
  discard bus.callWait("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                       "RequestName", "su", w.buf)
  watcherUp.store(true)
  while not stop.load:
    for m in bus.receive():
      if m.kind == dkMethodCall and m.member == "RegisterStatusNotifierItem":
        bus.reply(m)
        registered.store(true)
    sleep(5)
  bus.close()
var th: Thread[void]
createThread(th, watcher)
while not watcherUp.load: sleep(5)

const png = staticRead("../examples/assets/podcast-icon.png")
fakeDriver()
var tip = "Playing: nothing"
var clicks = 0
var picked: seq[int]
var shown = true
view = proc () =
  if shown:
    let t = trayIcon(png, tip, ["&Show", "-", "E&xit"])
    if t.clicked: inc clicks
    if t.picked >= 0: picked.add t.picked
startApp("tray", W, H)
run(2)
doAssert trayIconShown() and registered.load

# the tray's side: another connection
let host = sessionBus()
var item = ""
block name:
  let r = host.callWait("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                        "ListNames")
  for part in r.body.split('\0'):
    let i = part.find("org.kde.StatusNotifierItem-")
    if i >= 0: item = part[i .. ^1]
  doAssert item.endsWith("-1"), item

proc ask(path, iface, member, sig: string; body = ""): DBusMsg =
  ## (a call to the app's item, answered in its next frames)
  let serial = host.call(item, path, iface, member, sig, body)
  for _ in 0 ..< 100:
    run(1)
    for m in host.receive():
      if m.replySerial == serial: return m
    sleep(5)

proc prop(name: string): DBusMsg =
  var w: DBusWriter
  w.str("org.kde.StatusNotifierItem")
  w.str(name)
  ask("/StatusNotifierItem", "org.freedesktop.DBus.Properties", "Get", "ss", w.buf)

block properties:
  var rd = prop("Title").reader()
  doAssert rd.variant().text == "Playing: nothing"
  rd = prop("Status").reader()
  doAssert rd.variant().text == "Active"
  let pix = prop("IconPixmap")
  doAssert pix.kind == dkMethodReturn and pix.body.len > 22 * 22 * 4 + 32 * 32 * 4
  let m = prop("Menu")
  doAssert "/MenuBar" in m.body

block menu:
  var w: DBusWriter
  w.i32(0)
  w.i32(-1)
  let a = w.beginArray(4)
  w.endArray(a)
  let r = ask("/MenuBar", "com.canonical.dbusmenu", "GetLayout", "iias", w.buf)
  doAssert r.kind == dkMethodReturn, r.errorName
  doAssert "_Show" in r.body and "E_xit" in r.body and "separator" in r.body

block events:
  var w: DBusWriter
  w.i32(10)
  w.i32(10)
  discard ask("/StatusNotifierItem", "org.kde.StatusNotifierItem", "Activate", "ii", w.buf)
  run(2)
  doAssert clicks == 1
  var e: DBusWriter
  e.i32(3)                 # (the third item: Exit, after the separator)
  e.str("clicked")
  e.variantInt(0)
  e.u32(0)
  discard ask("/MenuBar", "com.canonical.dbusmenu", "Event", "isvu", e.buf)
  run(2)
  doAssert picked == @[2], $picked

block changes:
  tip = "Playing: Episode 2"
  run(2)
  var rd = prop("Title").reader()
  doAssert rd.variant().text == "Playing: Episode 2"
  shown = false            # (a frame without trayIcon: it goes)
  run(3)
  doAssert not trayIconShown()

stop.store(true)
joinThread(th)
host.close()
try:
  discard execShellCmd("kill " & readFile(addrFile & ".pid").strip & " 2>/dev/null")
  removeFile(addrFile)
  removeFile(addrFile & ".pid")
except IOError, OSError: discard
echo "tray OK"
