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
| a notification's buttons (`notificationActions`) | – | – | – | ✓ | – | – |
| `homeWidget` | – | – | – | ✓ *`--widget`* | – | – |
| `installApk` | – | – | – | ✓ *permission* | – | – |
| `setBadge` | – | – | ✓ the Dock | ✓ launchers | – | ✓ installed app |
| `share` (text, link, files) | – | – | ✓ share menu | ✓ share sheet | ✓ share sheet | ✓ Web Share *(not Firefox desktop)* |
| `haptic` | – | – | ✓ trackpads | ✓ | ✓ | ✓ phones |
| `vibrate` | – | – | – | ✓ *permission* | ✓ | ✓ phones |
| `location` | – *(Termux: ✓)* | – | ✓ *Info.plist* | ✓ *permission* | ✓ *Info.plist* | ✓ *https, asks* |
| `speak`, `stopSpeaking`, `speaking` | ✓ spd-say / espeak-ng | ✓ the system's voices | ✓ | ✓ | ✓ | ✓ |
| `setOpenAtLogin`, `openAtLogin` | ✓ autostart entry | ✓ Run key | ✓ launch agent | – | – | – |
| `requestAttention` | ✓ X11 urgency | ✓ the taskbar flashes | ✓ the Dock bounces | – | – | ✓ the tab's title |
| `online` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `metered` | ✓ NetworkManager | ✓ *Windows 10 2004* | – | ✓ | – | ✓ *Data Saver, a phone's data* |
| `systemWoke` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `systemPrefs` (less movement, contrast, text size) | ✓ GNOME | ✓ | ✓ | ✓ | ✓ | ✓ *(no text size)* |
| `systemLanguage` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `battery`, `batteryLevel` | ✓ | ✓ | – | ✓ | ✓ | ✓ *(Chrome)* |
| `systemDarkMode` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `keepScreenOn` | ✓ systemd-inhibit | ✓ | ✓ caffeinate | ✓ | ✓ | ✓ Wake Lock |
| `revealFile`, `openFile` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ *a download* |
| `deviceInfo`, `deviceName`, `osVersion` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ the browser |
| `beepSystem` | ✓ X11 bell | ✓ | ✓ | ✓ | ✓ | ✓ a tone |
| `openSettings` | ✓ | ✓ | ✓ | ✓ | ✓ | – |
| camera, microphone (`retroui/capture`) | ✓ V4L2, PulseAudio | ✓ Media Foundation | ✓ AVFoundation | ✓ *permission* | ✓ *Info.plist* | ✓ *https, asks* |
| the camera's zoom, flash, focus, exposure; full-size photos (`cameraCaps`) | – | – | – | ✓ Camera2 | – | – |
| media keys (`retroui/mediasession`) | ✓ MPRIS | ✓ SMTC | ✓ Now Playing | ✓ MediaSession | ✓ | ✓ Media Session |
| a sound playing on in the background (`audioView`) | ✓ | ✓ | ✓ | ✓ *a foreground service* | ✓ *UIBackgroundModes* | ✓ while the tab is open |
| an icon in the tray (`retroui/tray`) | ✓ StatusNotifierItem *(KDE, XFCE, Cinnamon; GNOME with AppIndicator)* | ✓ the notification area | ✓ the menu bar | – | – | – |
| secrets (`retroui/secrets`) | ✓ keyring / sealed file | ✓ DPAPI | ✓ keychain | ✓ sealed file | ✓ | ✓ WebCrypto |
| signing in (`retroui/oauth`) | ✓ the browser | ✓ | ✓ | ✓ | ✓ | ✓ *a pop-up* |
| updates (`retroui/update`) | ✓ AppImage, packages | ✓ | ✓ *.dmg, .pkg* | ✓ *the installer* | – | ✓ the service worker |
| background checks (`retroui/bgcheck`) | – | – | – | ✓ *`--background`* | – | – |
| open / save files | ✓ the kit's dialog | ✓ | ✓ | ✓ | ✓ | ✓ the browser's chooser, downloads |
| printing (`printPdf`) | ✓ CUPS | ✓ the PDF reader | ✓ CUPS | ✓ the print dialog | – | ✓ the browser's print |
| chat (`retroui/xmpp`) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ *threads build*, WebSocket |
| a command as the administrator (`retroui/admin`) | ✓ polkit's pkexec | ✓ UAC | ✓ the password dialog | – | – | – |
| pictures on the clipboard (`copyPicture`, `pastePicture`) | ✓ X11, Wayland, GTK 4 | ✓ DIB and PNG | ✓ PNG, TIFF | – | – | ✓ copy *(not paste)* |
| shortcuts of the whole desktop (`globalHotkey`) | ✓ X11 *(not Wayland)* | ✓ | ✓ | – | – | – |
| a folder watched (`watchFolder`) | ✓ | ✓ | ✓ | ✓ the app's files | ✓ the app's files | – |
| installed for the user alone (`retroui/install`) | ✓ ~/.local | ✓ %LOCALAPPDATA%, Start menu, Settings | ✓ ~/Applications | – | – | – |

### What the app declares

**Android** (`retroapk` / `retrokit apk`): the permissions of what the
app's code uses are added by `retroapk` itself -- it reads the compiled
code and says which it added; the hardware they imply is listed as not
required, so the app installs on a device without a camera or GPS.
`--no-auto-permissions` leaves them out (then add them yourself):

| For | Added by itself | Else |
|---|---|---|
| notifications (Android 13+) | ✓ (`notify`) | `--permission:POST_NOTIFICATIONS` |
| `vibrate`, `haptic` | ✓ | `--permission:VIBRATE` |
| `location` | ✓ | `--permission:ACCESS_COARSE_LOCATION`, `ACCESS_FINE_LOCATION` |
| camera, microphone | ✓ (`cameraView`, `recordSound`...) | `--permission:CAMERA`, `--permission:RECORD_AUDIO` |
| the network | ✓ (`httpRequest`, downloads, chat, `webView`) | `--permission:INTERNET` |
| background checks | | `--background` |
| plain `http://` addresses (Android 9+ refuses them; the kit asks for https instead) | | `--cleartext` (a browser, a podcast player) |
| in the other apps' share sheets (`sharedIn`) | | `--share-target:text/plain,image/*` |
| a widget on the home screen (`homeWidget`) | | `--widget` |
| a sound playing on in the background (`audioView`) | ✓ (`FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK`, the playback service) | `--permission:FOREGROUND_SERVICE --permission:FOREGROUND_SERVICE_MEDIA_PLAYBACK` |
| Java of the app's own (a service, a receiver) | | `--java:DIR` (its classes.dex, its manifest.txt) |
| installing an update's APK, or another app's (`installApk`) | | `--permission:REQUEST_INSTALL_PACKAGES` |

The window asks the user the first time a feature is used (never a
background check); a "no" makes the call answer false or `psDenied`, and
the app goes on.

**iOS and macOS**: the app's Info.plist says why it asks (`retroios` and
`tools/macapp.sh` write them): `NSLocationWhenInUseUsageDescription`,
`NSCameraUsageDescription`, `NSMicrophoneUsageDescription`; and
`UIBackgroundModes` audio when the app plays sounds with `audioView`
(`retroios` sees it in the compiled code), so they play on in the
background. `retroios --cleartext` lets the app use plain `http://`
addresses (App Transport Security's `NSAllowsArbitraryLoads`).

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

Buttons on it (Android: at most three; elsewhere the notification
without them):

```nim
discard notify("New mail", "3 new messages", tag = "inbox", actions = ["Mark as read"])
for (tag, action) in notificationActions():   # each frame, the first ones too
  if tag == "inbox" and action == "Mark as read": unread = 0
```

A press opens the app (or brings it up) and takes the notification away.

## A widget on the home screen

An Android app made with `retroapk --widget` has a widget the user puts
on the home screen: its icon, a title, a line or two, two buttons. The
app says what it shows, and it stays so while the app is closed:

```nim
homeWidget("Retro Podcast", "Now playing: Episode 12", ["Pause", "Ahead"])
for (tag, action) in notificationActions():
  if tag == "widget" and action == "Pause": playVideo("player", false)
```

A tap on the widget opens the app; a button opens it too and comes as an
action with the tag "widget". False (nothing) elsewhere. Retro DNS's
widget turns it on and off; Retro Podcast's plays and pauses.

## Installing an app

```nim
case installApk("/sdcard/Download/notes.apk")   # Android's installer asks the user
of aiInstaller: discard
of aiAllowFirst: toast("Allow Retro Files to install apps, then press Install again")
of aiNotDeclared: toast("Built without --permission:REQUEST_INSTALL_PACKAGES")
of aiFailed, aiNotHere: toast("It cannot be installed here")
```

`retroui/apkinfo` reads a package without installing it: `readApk(path)`
gives its name, version, package, the Android versions, its permissions,
its activities and services, and its icon (Retro Files shows them).

## Sharing

```nim
if not share(text = "The report", files = ["/home/me/report.pdf"], title = "Report"):
  revealFile("/home/me/report.pdf")   # no share sheet: show it in the file manager
```

The other way, the app in the other apps' share sheets (Android: the APK
made with `retroapk --share-target:text/plain,image/*`):

```nim
let came = sharedIn()                 # each frame: what came since, taken
if came.text.len > 0: follow(came.text)
for f in came.files: openPicture(f)   # copied into the app's cache
```

A desktop app gets files on its command line instead (`appArguments`).

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

## The network, sleep, the user's settings

```nim
if metered(): label "On a metered network: pictures load when you open them"
if systemWoke(): fetchAgain = true      # (the computer slept: what is shown may be old)
let p = systemPrefs()                   # less movement, high contrast, larger text
if p.reduceMotion: animate = false
```

`metered` is true on a phone's data, a hotspot or a network the user marked
metered (Windows, NetworkManager, Android, a browser's Data Saver). The kit
follows `systemPrefs` as an app starts: no glides when the user wants less
movement, larger text when the system's is larger (the app's own Appearance
settings come over them).

## Pictures on the clipboard, shortcuts of the whole desktop

```nim
if button("&Copy Picture"): discard copyPicture(chart)   # any program pastes it
let pic = pastePicture()                                  # nil: none
if globalHotkey("Ctrl+Alt+N"): showNote = true            # the app need not be in front
```

`copyPicture` puts a `Bitmap` on the clipboard as PNG (and as a DIB on
Windows, TIFF on a Mac). `globalHotkey` asks the system for the shortcut
the first time it is called -- `globalHotkeyTaken` says whether it got it:
another program may have it -- and is true in the frame it was pressed,
whichever program was in front. Wayland leaves such shortcuts to the
desktop's own settings.

## A folder watched

```nim
import retroui/files
let w = watchFolder(getHomeDir() / "Notes", recursive = true)
app "Notes", 600, 400:
  for c in w.changes():                   # every frame: it looks once a second
    echo c.kind, " ", c.path               # fcCreated, fcChanged, fcRemoved
```

It compares the files' sizes and times, the same on every system and over a
network share, at most 8192 files. It looks on the thread that calls it:
for a folder on a network drive, or one of thousands of files, look less
often (`everyMs`) or call `changes` from a job (`retroui/jobs`) -- the
window should not wait for a disk.

## A window that stops answering

On Windows every app has a watch on its own window (`retroui/hangwatch`,
nothing to call): when the window has not taken its messages for five
seconds -- Windows would write "Not responding" on it -- the procs its
thread is in go to the fault log, the innermost first, and the next
start's Report a Problem box (`problemBox`) shows them:

```
--- the window did not answer for 5 seconds: its thread was in
  ntdll.dll+054084
  kernelbase.dll+074202
  hasSubFolders@files  (RetroFiles.exe+21c6a4)
  folderNode@filewidgets  (RetroFiles.exe+24e41b)
```

The names come from the table of the program's procs that `nimble exe`
puts at the program's end (tools/winsym.py). What such a report names is
what to move off the window's thread: a disk asked (`later`, `askNow` of
`retroui/background`), a long piece of work (`retroui/jobs`, `busy`).

## Installed for the user alone

```nim
import retroui, retroui/install
const me = InstallInfo(id: "notes", name: "Notes", version: "1.2", publisher: "Me",
                       iconPng: staticRead("notes.png"))
if installFlags(me): quit 0               # Notes.exe --install, --uninstall
app "Notes", 600, 400:
  if not runningInstalled(me) and button("&Install for Me"): discard installForUser(me)
```

The program puts itself in the user's own folders, with no administrator and
no installer to make: Windows' %LOCALAPPDATA%\Programs, a Start menu entry
and an entry in Settings > Apps that uninstalls it (`--uninstall`); Linux's
~/.local/bin with its menu entry and icon; a Mac's ~/Applications. There it
is the user's own file, so `retroui/update` replaces it with no question.
`retrokit linux` makes the packages of the systems' own package managers
(.deb, .rpm, Arch's PKGBUILD) and a .tar.gz with an `install.sh` that does
the same as `installForUser`.

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

On an Android phone the picture stands up as the phone is held, a photo
is a JPEG at the sensor's whole size, two fingers on the view zoom and a
tap focuses there; the app sets the rest:

```nim
let caps = cameraCaps()                       # what this camera has (all 0 elsewhere)
if caps.zoomMax > 1: cameraZoom("", 2.0)      # under 1: the wide lens, where there is one
if caps.flash: cameraFlash("", cflAuto)       # cflOff, cflAuto, cflOn, cflTorch
cameraExposure("", -0.7)                      # EV, in caps.exposureMin .. exposureMax
cameraFocus("", 0.5, 0.3)                     # a point of the picture (0..1); -1: by itself
```

`cameras()` names each lens with its focal length (a wide one, a tele
one); `CameraEvent.zoom` is the zoom now.

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
your key did not sign. `update-sign` lists each file's pieces too: an app
downloads only the pieces its own file (and the updates it downloaded
before) does not hold -- HTTP ranges, which GitHub's releases and most
servers give; a server without them sends the whole file -- then checks the
whole file's SHA-256 as before (`updateFetched` says how much came). `checkForUpdate` and `downloadUpdate` wait for the
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

On Android and iOS an app may have the system's own picker instead of the
kit's dialog -- the phone's storage, an SD card, Drive, Files, any app
that offers its documents -- with one line at its start:

```nim
systemFiles(true)          # nothing happens on a desktop or in a web page
```

The same `fileDialog` and `filePicker` calls then show it (opening a
file, naming one to save; picking a folder stays the kit's). The systems
give documents, not paths, so the app is given a copy in its cache: the
document picked to open, and the file to save. What the app writes there
is handed back by itself, a moment after it was written: on Android into
the document it came from or the one "save to" made (a later Save goes
there without asking); on iOS Files asks where it goes. The app needs no
access to the storage for it. `systemFilesNote()` says what could not be
written back; an app that does not call its dialogs every frame calls
`pumpSystemFiles()` (`retroui/systemfiles`).

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

## A command as the administrator

`retroui/admin` runs a short command as the computer's administrator --
a setting of the whole computer, as Retro DNS's DNS servers -- the system
asking the user first: Windows with its UAC dialog, macOS with its
password dialog, Linux and the BSDs with polkit's (`pkexec`). It runs on a
thread of its own, so the window keeps drawing; ask again each frame
until it is no longer waiting. Phones and pages have no administrator:
`canRunAsAdmin()` is false there, and the answer `adNone`.

```nim
import retroui, retroui/admin
var asked = false
app "Settings", 400, 200:
  if button("&Flush the DNS cache", enabled = canRunAsAdmin()): asked = true
  if asked:
    let r = runAsAdmin("flush", "resolvectl", ["flush-caches"], why = "Settings flushes the DNS cache.")
    case r.state
    of adWaiting: wakeIn(200)
    of adDone: asked = false; toast(if r.code == 0: "Done" else: r.output)
    of adRefused: asked = false; toast("Not allowed")
    of adNone, adFailed: asked = false; toast(r.output)
```

On Windows the command gives nothing back but its exit code: a script
that must say why it failed writes it to a file (Retro DNS's does).

