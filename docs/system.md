# The system's features: one API for every system

Notifications, sharing, the place, speech, the camera, the media keys,
secrets, signing in, updates, files... An app made with Retro Nim UI asks
for them with the same calls on Linux, Windows, macOS, Android, iOS and in
a web page; each system answers with its own feature. This page says what
each call does on each system, what the app has to declare for it, and how
to write it so the app works everywhere -- including where a system has no
such feature.

```nim
import retroui, retroui/system      # notifications, sharing, the place, speech...
```

`retroui/system` brings the small ones together (and re-exports
`retroui/notify` and the device's calls of `retroui/native`). The bigger
ones are modules of their own: `retroui/capture`, `retroui/mediasession`,
`retroui/secrets`, `retroui/oauth`, `retroui/update`, `retroui/http`,
`retroui/bgcheck`.

## Three rules that make it work everywhere

1. **No call waits on the system.** Something that takes the system time
   (the place, a permission, a picked file) answers "waiting" now and is
   asked again in a later frame: call it every frame while you need it.
   The kit draws a frame by itself when the answer comes.
2. **"Not here" is an answer, not an error.** Where a system has no such
   feature the call answers `false` (or `psNone`, -1, ""), and the app
   offers what it can instead: a Copy button where there is no share
   sheet, a label where there is no notification.
3. **Ask from a click.** Phones and browsers ask the user before the
   first notification, the place, the camera, the microphone, a pop-up
   window: ask when the user did something that needs it (a button), not
   at start-up.

```nim
var askPlace = false
app "Shop", 420, 300:
  if button("&Notify"):
    if not notify("Order 1042", "Ready at the counter", tag = "orders"):
      toast("Order 1042 is ready")              # no system notifications here
  if button("&Share"):
    if not share(text = "Order 1042 is ready", url = "https://example.com/o/1042"):
      putClipboardText("https://example.com/o/1042")
      toast("Link copied")
  if button("&Where am I?"): askPlace = true
  if askPlace:
    let p = location()
    case p.state
    of psOk: label "At " & $p.lat & ", " & $p.lon & " (" & $int(p.accuracy) & " m)"
    of psWaiting: label "Looking..."
    of psDenied: label "The place was not allowed."
    of psNone: label "No place on this device."
```

---

## What each system does

✓ works, – nothing there (the call answers false or none); *in italics*:
what it needs (see "What the app declares").

| Call | Linux, BSD | Windows | macOS | Android app | iOS | Web page |
|---|---|---|---|---|---|---|
| `notify`, `clearNotification` | ✓ D-Bus (GNOME, KDE, dunst...) | ✓ a toast | ✓ Notification Center | ✓ *permission* | – | ✓ *asks* |
| `setBadge` | – | – | ✓ the Dock | ✓ launchers | – | ✓ installed app |
| `share` (text, link, files) | – | – | ✓ share menu | ✓ share sheet | ✓ share sheet | ✓ Web Share *(not Firefox desktop)* |
| `haptic` | – | – | ✓ trackpads | ✓ | ✓ | ✓ phones |
| `vibrate` | – | – | – | ✓ *permission* | ✓ | ✓ phones |
| `location` | – *(Termux: ✓)* | – | ✓ *Info.plist* | ✓ *permission* | ✓ *Info.plist* | ✓ *https, asks* |
| `speak`, `stopSpeaking`, `speaking` | ✓ spd-say / espeak-ng | ✓ the system's voices | ✓ | ✓ | ✓ | ✓ |
| `setOpenAtLogin`, `openAtLogin` | ✓ autostart entry | ✓ Run key | ✓ launch agent | – | – | – |
| `requestAttention` | ✓ X11 urgency | ✓ the taskbar flashes | ✓ the Dock bounces | – | – | ✓ the tab's title |
| `online` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `systemLanguage` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `battery`, `batteryLevel` | ✓ | ✓ | – | ✓ | ✓ | ✓ *(Chrome)* |
| `systemDarkMode` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `keepScreenOn` | – | ✓ | – | ✓ | ✓ | ✓ Wake Lock |
| `revealFile`, `openFile` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ *a download* |
| `deviceInfo`, `deviceName`, `osVersion` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ the browser |
| `beepSystem` | ✓ X11 bell | ✓ | ✓ | ✓ | ✓ | ✓ a tone |
| `openSettings` | ✓ | ✓ | ✓ | ✓ | ✓ | – |
| camera, microphone (`retroui/capture`) | ✓ V4L2, PulseAudio | ✓ Media Foundation | ✓ AVFoundation | ✓ *permission* | ✓ *Info.plist* | ✓ *https, asks* |
| media keys (`retroui/mediasession`) | ✓ MPRIS | ✓ SMTC | ✓ Now Playing | ✓ MediaSession | ✓ | ✓ Media Session |
| secrets (`retroui/secrets`) | ✓ keyring / sealed file | ✓ DPAPI | ✓ keychain | ✓ sealed file | ✓ | ✓ WebCrypto |
| signing in (`retroui/oauth`) | ✓ the browser | ✓ | ✓ | ✓ | ✓ | ✓ *a pop-up* |
| updates (`retroui/update`) | ✓ AppImage, packages | ✓ | ✓ *.dmg, .pkg* | ✓ *the installer* | – | ✓ the service worker |
| background checks (`retroui/bgcheck`) | – | – | – | ✓ *`--background`* | – | – |
| open / save files | ✓ the kit's dialog | ✓ | ✓ | ✓ | ✓ | ✓ the browser's chooser, downloads |
| printing (`printPdf`) | ✓ CUPS | ✓ the PDF reader | ✓ CUPS | ✓ the print dialog | – | ✓ the browser's print |
| chat (`retroui/xmpp`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ *threads build*, WebSocket |

### What the app declares

**Android** (`retroapk` / `retrokit apk`):

| For | Add |
|---|---|
| notifications (Android 13+) | `--permission:POST_NOTIFICATIONS` |
| `vibrate` | `--permission:VIBRATE` |
| `location` | `--permission:ACCESS_COARSE_LOCATION` (`precise`: `ACCESS_FINE_LOCATION`) |
| camera, microphone | `--permission:CAMERA`, `--permission:RECORD_AUDIO` |
| background checks | `--background` |
| installing an update's APK | `--permission:REQUEST_INSTALL_PACKAGES` |

The window asks the user the first time (never a background check).

**iOS and macOS**: the app's Info.plist says why it asks (`retroios` and
`tools/macapp.sh` write them): `NSLocationWhenInUseUsageDescription`,
`NSCameraUsageDescription`, `NSMicrophoneUsageDescription`.

**Web** (`retrokit web`): the page served over https (or from
localhost); the browser asks the user the first time. Chat, and an
app's own threads: `retrokit web --threads` (see [Web pages](#web-pages)).

---

## Notifications and the badge

```nim
import retroui, retroui/notify      # (also through retroui/system)

discard notifyAvailable()           # at start: the system asked once, ahead
if not notify("New mail", "Khalid: the drill plan", tag = "inbox"):
  toast("Khalid: the drill plan", title = "New mail")
clearNotification("inbox")          # taken away (read)
setBadge(unread)                    # the count on the app's icon
```

`tag` replaces the notification shown before with the same tag. With
`retroui/bgcheck` an Android app notifies while it is closed.

## Sharing

```nim
if not share(text = "The report", files = ["/home/me/report.pdf"], title = "Report"):
  revealFile("/home/me/report.pdf")   # no share sheet: show it in the file manager
```

## A tap felt, a buzz

```nim
haptic(hSuccess)        # hTap, hHeavy, hSuccess, hWarning, hError, hSelection
vibrate(80)             # ms
```

## The place

```nim
let p = location(precise = false)   # every frame while it is needed
if p.state == psOk: showOnMap(p.lat, p.lon)
stopLocation()                      # done: the battery thanks you
```

`psWaiting` until the first fix; then it is kept up to date while the app
asks.

## Speech

```nim
speak("Your order is ready")
speak("طلبك جاهز", lang = "ar", rate = 0.9)
if speaking(): label "Speaking..."
stopSpeaking()
```

Linux needs speech-dispatcher (`spd-say`) or `espeak-ng` installed.

## Starting with the computer, the user's attention

```nim
checkbox "Start with the computer", startAtLogin
if startAtLogin != openAtLogin("Retro Mail"):
  setOpenAtLogin(startAtLogin, "Retro Mail")
requestAttention()      # the taskbar flashes, the Dock bounces, the tab blinks
```

## The device

```nim
let d = deviceInfo()
label d.name & " -- " & d.system & ", " & $d.cpus & " cores, " & d.language
if d.battery.level >= 0: label "Battery " & $d.battery.level & "%" & (if d.battery.charging: " (charging)" else: "")
if not online(): label "Offline: the changes are kept until the network is back"
keepScreenOn(true)      # a presentation
```

## The camera and the microphone

```nim
import retroui, retroui/capture
app "Camera", 640, 520:
  let cam = cameraView(height = 420)          # on while it is drawn
  if cam.error.len > 0: label cam.error
  if button("&Photo"): cameraPhoto("", "photo.jpg")
  if button(if recordingSound(): "&Stop" else: "&Voice"):
    if recordingSound(): discard stopRecordingSound() else: discard recordSound("note.wav")
  progress(soundLevel())
```

In a web page the picture comes through getUserMedia; a recording is a
16-bit WAV written where the app said.

## The media keys and the lock screen

```nim
import retroui/mediasession
setNowPlaying(NowPlaying(title: song.title, artist: song.artist, playing: playing,
                         positionMs: pos, durationMs: dur, canNext: true, canPrevious: true))
for k in mediaKeys():
  case k.key
  of mkPlayPause: playing = not playing
  of mkNext: nextSong()
  of mkSeekTo: seekTo(k.ms)
  else: discard
```

## Secrets

```nim
import retroui/secrets
discard saveSecret("Retro Mail", "account 1", $(%tokens))
let saved = loadSecret("Retro Mail", "account 1")     # "" when none
deleteSecret("Retro Mail", "account 1")
```

A web page keeps them in its storage, sealed with a key the browser keeps
for the site and never hands out.

## Signing in (Microsoft 365, Google)

```nim
import retroui/oauth
let ms = microsoftProvider(clientId, scopes = ["https://graph.microsoft.com/Mail.ReadWrite"])
var flow = beginSignIn(ms, loginHint = "sultan@example.com")    # from a click
case flow.state
of osWaiting: label "Finish signing in in your browser"
of osDone: tokens = flow.tokens
of osFailed: label flow.error
of osCancelled: discard
```

Desktops and phones open the system's browser and take the answer on
localhost. A web page opens a pop-up that comes back to `oauth.html`
beside the page: register `https://YOUR.SITE/APP/oauth.html` as the
redirect address (Microsoft: a "Single-page application").

## Updates inside the app

```nim
import retroui/update
const updateKey = "01VFThQl2g..."              # printed by `retrokit update-key`
let u = checkForUpdate("https://example.com/notes/update.json", updateKey, AppVersion)
if u.available:                               # (say so: u.version, u.notes; on a yes:)
  let file = downloadUpdate(u)                  # its SHA-256 checked
  if installUpdate(file): restartApp()
```

You publish `update.json` (the newest version, its file for each system)
and `update.json.sig`: `retrokit update-key` once, then `retrokit
update-sign update.json` for each release. The app takes nothing that
your key did not sign. `checkForUpdate` and `downloadUpdate` wait for the
network: call them on a thread of your own (`retroui/background`) or at a
moment the app may wait.

## Files: open, save, print

```nim
if button("&Open..."): picking = true
if filePicker(picking, path, fmOpen, ["*.txt"]): text = readFile(path)
if button("Save &As..."): saving = true
if filePicker(saving, savePath, fmSave, ["*.pdf"]): writeFile(savePath, pdf)
discard printPdf("report.pdf")                  # CUPS, the PDF reader, Android's or the browser's dialog
```

In a web page Open is the browser's file chooser, and Save As writes in
`/downloads`, which the page hands to the user (the browser's Save As, or
a download).

## Anything else: the system's own API

`retroui/native` calls any C library, Java on Android, Objective-C on
Apple systems and Win32, from Nim (see `docs/controls.md`, Native); in a
web page `systemCall(name, arg)` reaches retro.js, and a page of your own
can add calls (`Retro.boot({ imports })`).

---

## Web pages

What a page can do depends on the browser:

| Feature | How |
|---|---|
| threads (`createThread`, the kit's drawing on every core) | `retrokit web --threads`: a second build with them, taken where the page can share memory with its workers (crossOriginIsolated). The page's service worker sets that up on any server (the page loads once more the first time). `?threads=0` tries the page without. An app that needs them (Retro Mail): `--threads-only`. |
| files the app writes | in the page's storage (IndexedDB), kept across visits under `/data` and the home folder; `/downloads` goes to the user |
| HTTP | `httpRequest` as everywhere; another site must allow the page (CORS) |
| chat (XMPP) | over a WebSocket (RFC 7395): the server must offer one (Prosody's `mod_websocket`, ejabberd's `ejabberd_http_ws`) |
| the 3D view | WebGL 2 (a context of its own) |
| screen readers | the window's controls as ARIA elements over the canvas, the focus said as it moves (`Retro.boot({ accessible: false })` turns it off) |
| printing | the browser's print dialog with the PDF |

Not in a page: processes (`osproc`), raw sockets, the file system of the
computer (only what the user picks), background checks.
