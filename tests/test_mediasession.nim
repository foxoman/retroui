## The system's media controls on Linux: the app's MPRIS player on a
## session bus of the test's own -- its state and track as a desktop's
## media applet reads them, and the applet's buttons (Play/Pause, Next,
## SetPosition, Seek) coming back in `mediaKeys`. Skipped without
## dbus-daemon.

import std/[os, osproc, strutils]
import retroui
import retroui/[mediasession]
import retroui/uirelays/dbus
import harness

when not defined(linux):
  echo "test_mediasession: Linux only"
  quit 0

if findExe("dbus-daemon").len == 0:
  echo "test_mediasession: skipped (no dbus-daemon)"
  quit 0

let addrFile = getTempDir() / "retro-mpris-bus-" & $getCurrentProcessId()
doAssert execShellCmd("dbus-daemon --session --fork --print-pid=4 --print-address=3 3>" &
                      quoteShell(addrFile) & " 4>" & quoteShell(addrFile & ".pid") &
                      " >/dev/null 2>&1 </dev/null") == 0
putEnv("DBUS_SESSION_BUS_ADDRESS", readFile(addrFile).strip.splitLines[0])

fakeDriver()
var keys: seq[MediaKeyEvent]
var np = NowPlaying(title: "Morning Raga", artist: "Al Isaiee Ensemble", album: "Sohar",
                    playing: true, positionMs: 1000, durationMs: 180000,
                    canNext: true, canPrevious: false, canSeek: true)
view = proc () =
  setNowPlaying(np)
  for k in mediaKeys(): keys.add k
appIdent = "retro-test"
startApp("mpris", 300, 200)
run(2)

let name = mediaSessionBusName()
doAssert name.startsWith("org.mpris.MediaPlayer2.retro_test.instance"), name

# a desktop's applet: another connection on the bus
let applet = sessionBus()
doAssert applet != nil

proc ask(member, sig: string; body = ""; iface = "org.freedesktop.DBus.Properties"): DBusMsg =
  ## A call to the app's player, answered in the app's next frames.
  let serial = applet.call(name, "/org/mpris/MediaPlayer2", iface, member, sig, body)
  for _ in 0 ..< 50:
    run(1)
    for m in applet.receive():
      if m.replySerial == serial: return m
    sleep(5)

proc getProp(iface, prop: string): DBusMsg =
  var w: DBusWriter
  w.str(iface)
  w.str(prop)
  ask("Get", "ss", w.buf)

block status:
  let r = getProp("org.mpris.MediaPlayer2.Player", "PlaybackStatus")
  doAssert r.kind == dkMethodReturn, $r.kind & " " & r.errorName
  var rd = r.reader()
  let v = rd.variant()
  doAssert v.text == "Playing", v.text

block metadata:
  let r = getProp("org.mpris.MediaPlayer2.Player", "Metadata")
  doAssert r.kind == dkMethodReturn
  doAssert "Morning Raga" in r.body and "Al Isaiee Ensemble" in r.body and "Sohar" in r.body
  doAssert "xesam:title" in r.body and "mpris:length" in r.body

block capabilities:
  var rd = getProp("org.mpris.MediaPlayer2.Player", "CanGoNext").reader()
  doAssert rd.variant().num == 1
  rd = getProp("org.mpris.MediaPlayer2.Player", "CanGoPrevious").reader()
  doAssert rd.variant().num == 0
  rd = getProp("org.mpris.MediaPlayer2", "Identity").reader()
  doAssert rd.variant().text == "mpris"

block getAll:
  var w: DBusWriter
  w.str("org.mpris.MediaPlayer2.Player")
  let r = ask("GetAll", "s", w.buf)
  doAssert r.kind == dkMethodReturn and "PlaybackStatus" in r.body and "CanSeek" in r.body

block introspect:
  let r = ask("Introspect", "", iface = "org.freedesktop.DBus.Introspectable")
  doAssert r.kind == dkMethodReturn and "org.mpris.MediaPlayer2.Player" in r.body

block buttons:
  keys.setLen(0)
  discard ask("PlayPause", "", iface = "org.mpris.MediaPlayer2.Player")
  discard ask("Next", "", iface = "org.mpris.MediaPlayer2.Player")
  var w: DBusWriter
  w.str("/org/retro/track/1")
  w.u64(uint64(42_000_000))                  # 42 s, in microseconds
  discard ask("SetPosition", "ox", w.buf, iface = "org.mpris.MediaPlayer2.Player")
  var w2: DBusWriter
  w2.u64(cast[uint64](-5_000_000'i64))       # back 5 s
  discard ask("Seek", "x", w2.buf, iface = "org.mpris.MediaPlayer2.Player")
  run(2)
  doAssert keys.len == 4, $keys
  doAssert keys[0].key == mkPlayPause and keys[1].key == mkNext
  doAssert keys[2].key == mkSeekTo and keys[2].ms == 42_000
  doAssert keys[3].key == mkSeekBy and keys[3].ms == -5_000

block changes:
  # a pause is news (PlaybackStatus "Paused" for the applet)
  np.playing = false
  run(2)
  let r = getProp("org.mpris.MediaPlayer2.Player", "PlaybackStatus")
  var rd = r.reader()
  doAssert rd.variant().text == "Paused"
  endNowPlaying()
  view = proc () = discard
  run(1)
  rd = getProp("org.mpris.MediaPlayer2.Player", "PlaybackStatus").reader()
  doAssert rd.variant().text == "Stopped"

applet.close()
discard execShellCmd("kill " & readFile(addrFile & ".pid").strip & " 2>/dev/null")
removeFile(addrFile)
removeFile(addrFile & ".pid")
echo "test_mediasession: ok"
