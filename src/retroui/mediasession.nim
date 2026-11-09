## The system's media controls: what the app plays shown where the system
## shows it -- the lock screen, the notification shade, the taskbar's
## media flyout, the menu bar's Now Playing, the desktop's media applet --
## and what the user presses there (and on a keyboard's or a headset's
## media keys) handed to the app.
##
## - Linux, BSD, Termux:X11: MPRIS over D-Bus (`retroui/uirelays/dbus`:
##   nothing linked); GNOME, KDE, playerctl and the media keys use it.
## - Windows 8 and later: the System Media Transport Controls, through
##   Windows' runtime (WinRT), for the app's window.
## - macOS and iOS: MPNowPlayingInfoCenter and MPRemoteCommandCenter.
## - Android: a MediaSession with its notification
##   (`tools/android/RetroSession.java`).
## - A web page: the browser's Media Session (a phone's lock screen, the
##   browser's media hub, a headset's keys).
##
## .. code-block:: nim
##   app "Player", 600, 400:
##     setNowPlaying(NowPlaying(title: song.title, artist: song.artist,
##                              playing: playing, positionMs: pos, durationMs: dur,
##                              canNext: true, canPrevious: true))
##     for k in mediaKeys():
##       case k.key
##       of mkPlayPause: playing = not playing
##       of mkNext: nextSong()
##       of mkSeekTo: seekTo(k.ms)
##       else: discard
##
## `setNowPlaying` may be called every frame: it tells the system only
## what changed. `endNowPlaying` lets the controls go (the app plays
## nothing any more).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/times
import uirelays/target
when not (androidApp or defined(windows) or defined(macosx)):
  import std/os
when not (defined(windows) or defined(macosx)):
  import std/strutils
when androidApp or defined(wasm):
  import uirelays/services
import core

type
  MediaKey* = enum
    ## What the system's controls asked.
    mkPlay, mkPause, mkPlayPause, mkStop, mkNext, mkPrevious,
    mkSeekTo      ## go to `ms`
    mkSeekBy      ## go on (or back: negative) by `ms`
    mkRaise       ## show the app (its entry in the desktop's applet)
  MediaKeyEvent* = object
    ## A press of the system's media controls.
    key*: MediaKey
    ms*: int                   ## mkSeekTo: where; mkSeekBy: by how much
  NowPlaying* = object
    ## What plays, as the system shows it.
    title*, artist*, album*: string
    artPath*: string           ## a picture of it (a PNG or JPEG file; "": none)
    playing*: bool             ## playing (else paused)
    positionMs*, durationMs*: int
    canNext*, canPrevious*, canSeek*: bool
    video*: bool               ## a video (else music)

var
  current: NowPlaying
  active = false               ## the system has been told
  posAt = 0.0                  ## when `current.positionMs` was true (epochTime)
  pending: seq[MediaKeyEvent]  ## pressed, not yet taken

proc same(a, b: NowPlaying): bool =
  a.title == b.title and a.artist == b.artist and a.album == b.album and
    a.artPath == b.artPath and a.playing == b.playing and a.durationMs == b.durationMs and
    a.canNext == b.canNext and a.canPrevious == b.canPrevious and a.canSeek == b.canSeek and
    a.video == b.video and abs(a.positionMs - b.positionMs) < 1500

proc positionNow(): int =
  ## Where it is now: as set, and on since then while it plays.
  result = current.positionMs
  if current.playing: result += int((epochTime() - posAt) * 1000)
  if current.durationMs > 0: result = min(result, current.durationMs)

proc press(k: MediaKey; ms = 0) =
  pending.add MediaKeyEvent(key: k, ms: ms)
  ui.redraw = true

# ---- Linux, BSD: MPRIS ------------------------------------------------------------------------------

when not (androidApp or defined(windows) or defined(macosx) or defined(ios) or
          defined(js) or defined(wasm)):
  import uirelays/dbus

  var
    bus: DBusConn
    busTried = false
    busName = ""

  const
    ObjPath = "/org/mpris/MediaPlayer2"
    RootIface = "org.mpris.MediaPlayer2"
    PlayerIface = "org.mpris.MediaPlayer2.Player"
    PropsIface = "org.freedesktop.DBus.Properties"
    Introspection = """<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
 <interface name="org.mpris.MediaPlayer2">
  <method name="Raise"/><method name="Quit"/>
  <property name="CanQuit" type="b" access="read"/><property name="CanRaise" type="b" access="read"/>
  <property name="HasTrackList" type="b" access="read"/><property name="Identity" type="s" access="read"/>
  <property name="SupportedUriSchemes" type="as" access="read"/>
  <property name="SupportedMimeTypes" type="as" access="read"/>
 </interface>
 <interface name="org.mpris.MediaPlayer2.Player">
  <method name="Next"/><method name="Previous"/><method name="Pause"/><method name="PlayPause"/>
  <method name="Stop"/><method name="Play"/>
  <method name="Seek"><arg name="Offset" type="x" direction="in"/></method>
  <method name="SetPosition"><arg name="TrackId" type="o" direction="in"/><arg name="Position" type="x" direction="in"/></method>
  <method name="OpenUri"><arg name="Uri" type="s" direction="in"/></method>
  <signal name="Seeked"><arg name="Position" type="x"/></signal>
  <property name="PlaybackStatus" type="s" access="read"/><property name="Rate" type="d" access="read"/>
  <property name="Metadata" type="a{sv}" access="read"/><property name="Volume" type="d" access="read"/>
  <property name="Position" type="x" access="read"/><property name="MinimumRate" type="d" access="read"/>
  <property name="MaximumRate" type="d" access="read"/><property name="CanGoNext" type="b" access="read"/>
  <property name="CanGoPrevious" type="b" access="read"/><property name="CanPlay" type="b" access="read"/>
  <property name="CanPause" type="b" access="read"/><property name="CanSeek" type="b" access="read"/>
  <property name="CanControl" type="b" access="read"/>
 </interface>
 <interface name="org.freedesktop.DBus.Properties">
  <method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
  <method name="GetAll"><arg type="s" direction="in"/><arg type="a{sv}" direction="out"/></method>
  <method name="Set"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/></method>
  <signal name="PropertiesChanged"><arg type="s"/><arg type="a{sv}"/><arg type="as"/></signal>
 </interface>
 <interface name="org.freedesktop.DBus.Introspectable">
  <method name="Introspect"><arg type="s" direction="out"/></method>
 </interface>
</node>"""

  proc i64(w: var DBusWriter; v: int64) = w.u64(cast[uint64](v))

  proc strings(w: var DBusWriter; l: openArray[string]) =
    let a = w.beginArray(4)
    for s in l: w.str(s)
    w.endArray(a)

  proc fileUri(p: string): string =
    result = "file://"
    for c in p.absolutePath:
      if c in {'a'..'z', 'A'..'Z', '0'..'9', '/', '-', '_', '.', '~'}: result.add c
      else: result.add '%' & toHex(ord(c), 2)

  proc metadata(w: var DBusWriter) =
    ## The track as MPRIS describes it (a{sv}).
    let a = w.beginArray(8)
    template entry(k: string; body: untyped) =
      w.struct()
      w.str(k)
      body
    entry("mpris:trackid"):
      w.sig("o")
      w.str("/org/retro/track/1")
    if current.durationMs > 0:
      entry("mpris:length"):
        w.sig("x")
        w.i64(int64(current.durationMs) * 1000)
    if current.title.len > 0: entry("xesam:title"): w.variantStr(current.title)
    if current.artist.len > 0:
      entry("xesam:artist"):
        w.sig("as")
        w.strings([current.artist])
    if current.album.len > 0: entry("xesam:album"): w.variantStr(current.album)
    if current.artPath.len > 0 and fileExists(current.artPath):
      entry("mpris:artUrl"): w.variantStr(fileUri(current.artPath))
    w.endArray(a)

  proc status(): string =
    if not active: "Stopped" elif current.playing: "Playing" else: "Paused"

  proc property(w: var DBusWriter; iface, name: string): bool =
    ## The value of a property, as a variant; false when there is none.
    result = true
    if iface == RootIface or iface.len == 0 and name in ["Identity", "CanQuit", "CanRaise"]:
      case name
      of "CanQuit": w.variantBool(false)
      of "CanRaise": w.variantBool(true)
      of "HasTrackList": w.variantBool(false)
      of "Identity": w.variantStr(if ui.title.len > 0: ui.title else: appIdent)
      of "DesktopEntry": w.variantStr(appIdent)
      of "SupportedUriSchemes", "SupportedMimeTypes":
        w.sig("as")
        w.strings([])
      else: result = false
      return
    case name
    of "PlaybackStatus": w.variantStr(status())
    of "Rate", "MinimumRate", "MaximumRate", "Volume": w.variantF64(1.0)
    of "Metadata":
      w.sig("a{sv}")
      w.metadata()
    of "Position":
      w.sig("x")
      w.i64(int64(positionNow()) * 1000)
    of "CanGoNext": w.variantBool(current.canNext)
    of "CanGoPrevious": w.variantBool(current.canPrevious)
    of "CanPlay", "CanPause", "CanControl": w.variantBool(true)
    of "CanSeek": w.variantBool(current.canSeek and current.durationMs > 0)
    else: result = false

  const
    RootProps = ["CanQuit", "CanRaise", "HasTrackList", "Identity", "DesktopEntry",
                 "SupportedUriSchemes", "SupportedMimeTypes"]
    PlayerProps = ["PlaybackStatus", "Rate", "MinimumRate", "MaximumRate", "Volume",
                   "Metadata", "Position", "CanGoNext", "CanGoPrevious", "CanPlay",
                   "CanPause", "CanControl", "CanSeek"]

  proc allOf(w: var DBusWriter; iface: string) =
    let a = w.beginArray(8)
    for name in (if iface == RootIface: @RootProps else: @PlayerProps):
      w.struct()
      w.str(name)
      discard w.property(iface, name)
    w.endArray(a)

  proc changed() =
    ## PropertiesChanged: the player's state and track.
    if bus == nil: return
    var w: DBusWriter
    w.str(PlayerIface)
    let a = w.beginArray(8)
    for name in ["PlaybackStatus", "Metadata", "CanGoNext", "CanGoPrevious", "CanSeek"]:
      w.struct()
      w.str(name)
      discard w.property(PlayerIface, name)
    w.endArray(a)
    w.strings([])
    bus.signal(ObjPath, PropsIface, "PropertiesChanged", "sa{sv}as", w.buf)

  proc connect(): bool =
    if bus != nil: return bus.fd >= 0
    if busTried: return false
    busTried = true
    bus = sessionBus()
    if bus == nil: return false
    var id = ""
    for c in (if appIdent.len > 0: appIdent else: "retro"):
      if c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: id.add c
      else: id.add '_'
    if id.len == 0 or id[0] in {'0'..'9'}: id = "app_" & id
    busName = "org.mpris.MediaPlayer2." & id & ".instance" & $getCurrentProcessId()
    var w: DBusWriter
    w.str(busName)
    w.u32(4)                                    # DBUS_NAME_FLAG_DO_NOT_QUEUE
    let r = bus.callWait("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                         "RequestName", "su", w.buf)
    if r.kind != dkMethodReturn:
      bus.close()
      bus = nil
      return false
    true

  proc handle(m: DBusMsg) =
    if m.kind != dkMethodCall: return
    var r = m.reader()
    case m.member
    of "Get":
      let iface = r.str()
      let name = r.str()
      var w: DBusWriter
      if w.property(iface, name): bus.reply(m, "v", w.buf)
      else: bus.replyError(m, "org.freedesktop.DBus.Error.UnknownProperty", name)
    of "GetAll":
      var w: DBusWriter
      w.allOf(r.str())
      bus.reply(m, "a{sv}", w.buf)
    of "Set": bus.reply(m)
    of "Introspect":
      var w: DBusWriter
      w.str(Introspection)
      bus.reply(m, "s", w.buf)
    of "Ping", "GetMachineId": bus.reply(m)
    of "Play":
      press(mkPlay)
      bus.reply(m)
    of "Pause":
      press(mkPause)
      bus.reply(m)
    of "PlayPause":
      press(mkPlayPause)
      bus.reply(m)
    of "Stop":
      press(mkStop)
      bus.reply(m)
    of "Next":
      press(mkNext)
      bus.reply(m)
    of "Previous":
      press(mkPrevious)
      bus.reply(m)
    of "Seek":
      press(mkSeekBy, int(cast[int64](r.u64()) div 1000))
      bus.reply(m)
    of "SetPosition":
      discard r.str()                           # (the track: there is one)
      press(mkSeekTo, int(cast[int64](r.u64()) div 1000))
      bus.reply(m)
    of "Raise":
      press(mkRaise)
      bus.reply(m)
    of "Quit", "OpenUri": bus.reply(m)
    else: bus.replyError(m, "org.freedesktop.DBus.Error.UnknownMethod", m.member)

  proc pump() =
    if bus == nil or bus.fd < 0: return
    for m in bus.receive(): handle(m)

  proc tell(old: NowPlaying; first: bool) =
    if not connect(): return
    changed()
    if not first and abs(current.positionMs - old.positionMs) >= 1500:
      var w: DBusWriter
      w.i64(int64(current.positionMs) * 1000)
      bus.signal(ObjPath, PlayerIface, "Seeked", "x", w.buf)

  proc untell() =
    if bus == nil: return
    changed()

  proc mediaSessionBusName*(): string = busName
    ## The bus name the app's controls have on D-Bus ("" before
    ## `setNowPlaying`): `playerctl -p NAME`, tests.

# ---- Android: a MediaSession (tools/android/RetroSession.java) ------------------------------------

elif androidApp:
  proc tell(old: NowPlaying; first: bool) =
    discard systemCall("session.set", [current.title, current.artist, current.album,
      current.artPath, (if current.playing: "1" else: "0"), $current.positionMs,
      $current.durationMs, (if current.canNext: "1" else: "0"),
      (if current.canPrevious: "1" else: "0"), (if current.canSeek: "1" else: "0")].join("\t"))

  proc untell() = discard systemCall("session.end", "")

  proc pump() =
    let s = systemCall("session.keys", "")
    if s.len == 0 or s == "\0": return
    for line in s.split('\n'):
      let p = line.split('\t')
      if p.len == 0 or p[0].len == 0: continue
      let ms = if p.len > 1: (try: parseInt(p[1]) except ValueError: 0) else: 0
      case p[0]
      of "play": press(mkPlay)
      of "pause": press(mkPause)
      of "toggle": press(mkPlayPause)
      of "stop": press(mkStop)
      of "next": press(mkNext)
      of "previous": press(mkPrevious)
      of "seek": press(mkSeekTo, ms)
      else: discard

# ---- Windows: the System Media Transport Controls ---------------------------------------------------

elif defined(windows):
  include mediasession_win

# ---- macOS, iOS: MPNowPlayingInfoCenter, MPRemoteCommandCenter --------------------------------------

elif defined(macosx) or defined(ios):
  include mediasession_apple

# ---- a web page: the browser's Media Session (a phone's lock screen, a
# desktop browser's media hub, a headset's keys) -------------------------------------------------

elif defined(wasm):
  proc webJson(s: string): string =
    result = "\""
    for c in s:
      case c
      of '"': result.add "\\\""
      of '\\': result.add "\\\\"
      of '\0' .. '\x1f': discard
      else: result.add c
    result.add '"'

  proc tell(old: NowPlaying; first: bool) =
    discard systemCall("media.set", "{\"title\":" & webJson(current.title) &
      ",\"artist\":" & webJson(current.artist) & ",\"album\":" & webJson(current.album) &
      ",\"art\":" & webJson(if current.artPath.len > 0: absolutePath(current.artPath) else: "") &
      ",\"playing\":" & $current.playing & ",\"position\":" & $(current.positionMs / 1000) &
      ",\"duration\":" & $(current.durationMs / 1000) & ",\"next\":" & $current.canNext &
      ",\"previous\":" & $current.canPrevious & ",\"seek\":" & $current.canSeek & "}")

  proc untell() = discard systemCall("media.clear", "")

  proc pump() =
    if not active: return
    while true:
      let s = systemCall("media.pressed", "")
      if s.len == 0 or s == "\0": return
      let p = s.split('\t')
      let ms = if p.len > 1: (try: parseInt(p[1]) except ValueError: 0) else: 0
      case p[0]
      of "play": press(mkPlay)
      of "pause": press(mkPause)
      of "stop": press(mkStop)
      of "nexttrack": press(mkNext)
      of "previoustrack": press(mkPrevious)
      of "seekto": press(mkSeekTo, ms)
      of "seekbackward": press(mkSeekBy, -10000)
      of "seekforward": press(mkSeekBy, 10000)
      else: discard

else:
  proc tell(old: NowPlaying; first: bool) = discard
  proc untell() = discard
  proc pump() = discard

# ---- for every system -------------------------------------------------------------------------------

when not declared(mediaSessionBusName):
  proc mediaSessionBusName*(): string = ""
    ## The bus name the app's controls have on D-Bus: "" here (D-Bus is
    ## Linux's and the BSDs'). (Retro Designer lists it on every system.)

var hooked = false

proc sessionFrame() {.nimcall.} = pump()

proc hook() =
  if not hooked:
    hooked = true
    beginFrameHooks.add sessionFrame

proc setNowPlaying*(np: NowPlaying) =
  ## What the app plays, for the system's media controls; the controls'
  ## presses come in `mediaKeys`. Call it when it changes, or every frame:
  ## the system is told only what changed (a position that keeps time with
  ## the playing is not news).
  hook()
  if active and same(np, current) and np.positionMs != current.positionMs:
    # (only the position: kept for the next look, not sent)
    if abs(np.positionMs - positionNow()) < 1500:
      return
  if active and same(np, current) and np.positionMs == current.positionMs: return
  let old = current
  let first = not active
  current = np
  posAt = epochTime()
  active = true
  tell(old, first)

proc endNowPlaying*() =
  ## The app plays nothing now: the system's controls let it go.
  if not active: return
  active = false
  current.playing = false
  untell()

proc mediaKeys*(): seq[MediaKeyEvent] =
  ## What the system's media controls asked since the last frame (the lock
  ## screen, the media keys of a keyboard or a headset, the desktop's media
  ## applet). Empty (and nothing made) when nothing was pressed.
  hook()
  pump()
  if pending.len > 0: swap(result, pending)
