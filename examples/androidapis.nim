## Android APIs: one page for each of the phone's features an app reaches from Nim with Retro Nim
## UI -- notifications (with buttons, and from the background), vibration and taps felt, sharing
## in and out, files, the camera and its scanner, the place, the battery, the network and dark
## mode, the clipboard, speech, a home screen widget, keeping the screen on, Android's own Java by
## reflection, the motion sensors and a shake, links that open the app, the screen lock, picture
## in picture, drag and drop with the app beside it, purchases in the app, and the app's state
## kept when Android ends it. Each page's code is short and stands alone: copy the one you need.
##
## Build it with every feature on (the links, the widget, the share sheet, the background check,
## picture in picture):
##
##   retroapk examples/androidapis.nim --name:"Android APIs" --id:org.retro.apis --links:retroapis \
##     --widget --share-target:text/plain,image/* --background --pip
##
## On a desktop it runs too: each page says what it does there.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, os, times]
import retroui, retroui/[system, device, capture, scanner, bgcheck]
import retroui/uirelays/input

type Page = enum
  pHome = "Android APIs", pNotify = "Notifications", pFeel = "Vibration",
  pShare = "Sharing", pFiles = "Files", pCamera = "Camera and Scanner",
  pPlace = "Place", pDevice = "Battery, Network, Dark Mode", pClipboard = "Clipboard",
  pSpeech = "Speech", pWidget = "Home Screen Widget", pScreen = "Keep the Screen On",
  pJava = "Java by Reflection", pMotion = "Motion and Shake", pLinks = "Links",
  pLock = "Screen Lock", pPip = "Picture in Picture", pDrag = "Drag and Drop",
  pStore = "Purchases", pState = "State Kept"

type Kept = object
  ## (what is kept when Android ends the app: the page open, a note being written)
  page: Page
  note: string

var
  kept = restoreState("apis", Kept())
  log: seq[string]
  photoPath = ""
  pickOpen = false
  pickedPath = ""
  speakText = "Hello from Retro Nim UI"
  screenOn = false
  ticks = 0
  scanned = ""
  products: seq[Product]

proc say(s: string) =
  log.insert(now().format("HH:mm:ss") & "  " & s, 0)
  if log.len > 30: log.setLen(30)

# ---- the background check: new things told in a notification while the app is closed ----------
proc checkInBackground() {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    discard notify("Android APIs", "The background check ran at " & now().format("HH:mm"), tag = "bg")
onBackgroundCheck(checkInBackground)

proc back() =
  kept.page = pHome

proc header() =
  if navBar($kept.page, back = "Back") == npBack: back()

proc logView() =
  if log.len > 0:
    tableGroup("What happened"):
      for l in log: discard tableRow(l)

app "Android APIs", 420, 760, look = "apis":
  keepState("apis", kept)
  if backPressed() and kept.page != pHome:
    cancelClose()
    back()
  # (a link that opened the app: retroapis://page/notify)
  let link = takeLink()
  if link.len > 0:
    say "opened by the link " & link
    for p in Page:
      if link.toLowerAscii.endsWith("/" & ($p).split(' ')[0].toLowerAscii): kept.page = p
  # (a notification's button pressed)
  for (tag, action) in notificationActions(): say "the notification " & tag & ": " & action
  # (what other apps shared or dropped)
  let shared = sharedIn()
  if shared.text.len > 0 or shared.files.len > 0: say "shared in: " & shared.text & " " & shared.files.join(", ")
  let dropped = droppedFromApps()
  if dropped.files.len > 0 or dropped.texts.len > 0:
    say "dropped from another app: " & (dropped.files & dropped.texts).join(", ")
  case kept.page
  of pHome:
    discard navBar($pHome)
    beginPanel(-1, "home", plain = true)
    largeTitle("Android APIs", "Tap one to try it")
    tableGroup("The phone"):
      for p in pNotify .. pState:
        if tableRow($p, accessory = taChevron).clicked: kept.page = p
    endPanel()
  of pNotify:
    header()
    paragraph "A notification of the system, with buttons; one from the background every 15 minutes (the APK made with --background)."
    if bigButton("Notify Now"):
      say(if notify("Android APIs", "Hello from a notification", tag = "hello", actions = ["Reply", "Done"]): "notified"
          else: "notifications are off for the app")
    if bigButton("Check in the Background Every 15 Minutes", btGray):
      say(if scheduleBackgroundCheck(15): "the background check is scheduled" else: "no background checks here")
    if bigButton("Badge 3 on the Icon", btGray): setBadge(3)
    if bigButton("Clear", btGray):
      clearNotification("hello")
      setBadge(0)
    logView()
  of pFeel:
    header()
    for (name, kind) in [("A Tap", hTap), ("A Firm Tap", hHeavy), ("Success", hSuccess), ("Warning", hWarning),
                         ("Error", hError), ("A Step", hSelection)]:
      if bigButton(name, btGray): say name & ": " & (if haptic(kind): "felt" else: "nothing to feel here")
    if bigButton("Vibrate Half a Second", btGray): discard vibrate(500)
    logView()
  of pShare:
    header()
    paragraph "Out: the share sheet. In: this app is in other apps' share sheets (--share-target); what comes shows below."
    if bigButton("Share Text"): discard share(text = "Made with Retro Nim UI", url = "https://github.com/foxoman/retroui")
    if photoPath.len > 0 and bigButton("Share the Photo", btGray): discard share(files = [photoPath])
    logView()
  of pFiles:
    header()
    if bigButton("Pick a File"): pickOpen = true
    if fileDialog(pickOpen, pickedPath, fmOpen):
      say "picked " & pickedPath & " (" & $getFileSize(pickedPath) & " bytes)"
    let mine = dataDir("") / "note.txt"
    if bigButton("Write a File of the App's Own", btGray):
      writeFile(mine, "written " & $now())
      say "wrote " & mine
    if fileExists(mine) and bigButton("Open It with Another App", btGray): discard openFile(mine)
    logView()
  of pCamera:
    header()
    let got = scannerView(height = 300)
    if got.text.len > 0:
      scanned = got.text
      say (if got.qr: "QR: " else: $got.kind & ": ") & got.text
    if scanned.len > 0: label "Read: " & scanned
    if bigButton("Take a Photo", btGray):
      photoPath = getTempDir() / "apis-photo.jpg"
      cameraPhoto("scan:", photoPath)
    logView()
  of pPlace:
    header()
    let p = location()
    case p.state
    of psOk: label formatFloat(p.lat, ffDecimal, 5) & ", " & formatFloat(p.lon, ffDecimal, 5) &
                   " (within " & $int(p.accuracy) & " m)"
    else: label "Finding the place... (" & $p.state & ")"
    if bigButton("Stop", btGray): stopLocation()
  of pDevice:
    header()
    let b = battery()
    tableGroup("Now"):
      discard tableRow("Battery", detail = (if b.level < 0: "unknown" else: $b.level & " %" & (if b.charging: ", charging" else: "")))
      discard tableRow("Online", detail = (if online(): "yes" else: "no") & (if metered(): ", metered" else: ""))
      discard tableRow("Dark mode", detail = if systemDarkMode(): "on" else: "off")
      discard tableRow("Language", detail = systemLanguage())
      let d = deviceInfo()
      discard tableRow("Device", detail = d.name & ", " & d.system)
  of pClipboard:
    header()
    if bigButton("Copy the Time"):
      putClipboardText($now())
      say "copied"
    if bigButton("Paste", btGray): say "the clipboard: " & getClipboardText()
    logView()
  of pSpeech:
    header()
    edit speakText
    if bigButton("Speak"): discard speak(speakText)
    if speaking() and bigButton("Stop", btGray): stopSpeaking()
  of pWidget:
    header()
    paragraph "The APK made with --widget has a home screen widget: its title, a line and two buttons, set from here."
    if bigButton("Set the Widget"):
      say(if homeWidget("Android APIs", "Set at " & now().format("HH:mm"), ["Open", "Notify"]): "set" else: "no widget here")
  of pScreen:
    header()
    if toggle("Keep the screen on", screenOn): discard keepScreenOn(screenOn)
    paragraph "While it is on, the screen doesn't dim or lock (a recipe, a map, a video)."
  of pJava:
    header()
    paragraph "Any of Android's own Java, by name: here android.os.Build's fields and a static method."
    when defined(android):
      if bigButton("Read android.os.Build"):
        say "MODEL " & javaStatic("android.os.Build", "MODEL")
        say "SDK " & javaStatic("android.os.Build$VERSION", "SDK_INT")
        say "a random UUID " & javaStatic("java.util.UUID", "randomUUID")
    else:
      label "(on Android only)"
    logView()
  of pMotion:
    header()
    discard startMotion()
    let m = motion()
    if m.ok:
      label "Tilt: " & formatFloat(m.tiltX, ffDecimal, 2) & " across, " & formatFloat(m.tiltY, ffDecimal, 2) & " along"
      label "Jolt: " & formatFloat(m.jolt[0], ffDecimal, 1) & " " & formatFloat(m.jolt[1], ffDecimal, 1) & " " &
            formatFloat(m.jolt[2], ffDecimal, 1) & " m/s²"
      wakeIn(100)
    else: label "No motion sensors here."
    if shaken(): say "shaken!"
    if toggle("The glass's light follows the tilt (Glass look)", glassTilt): discard
    logView()
  of pLinks:
    header()
    paragraph "The APK made with --links:retroapis opens for links like retroapis://page/notify -- try one from a message or a web page. On Linux and Windows: registerLinks."
    if bigButton("Register retroapis: Here (Desktops)", btGray):
      say(if registerLinks(["retroapis"]): "registered" else: "said in the APK instead")
    logView()
  of pLock:
    header()
    paragraph "The system's own sheet: a fingerprint, a face, or the screen lock's PIN or pattern."
    if bigButton("Show the Secret"):
      if not askUnlock("To show the secret"): say "no screen lock here"
    case unlockAnswer()
    of laOk: label "The secret: 42"
    of laFailed: label "Not shown."
    of laAsking: label "Asking..."
    else: discard
    logView()
  of pPip:
    header()
    if inPictureInPicture():
      label "In a small window"
      label $ticks
    else:
      paragraph "The app goes on in a small window over the others (the APK made with --pip): a video, a timer."
      if bigButton("Go Small"): say(if pictureInPicture(): "small" else: "not here")
      label "Counting: " & $ticks
    inc ticks
    wakeIn(1000)
  of pDrag:
    header()
    paragraph "Put another app beside this one (split screen). Hold the card, then drag it there; drop a photo or text here from it."
    let card = place(0, dp(70), fill = true)
    roundRect(card, float(dp(12)), accentColor())
    text(card.x + dp(16), card.y + dp(24), "note.txt -- hold and drag me", color(255, 255, 255))
    let mine = dataDir("") / "note.txt"
    if not fileExists(mine): writeFile(mine, "A note from Android APIs")
    if fileDragSource(card, proc (): seq[string] = @[mine]): say "dragged out"
    logView()
  of pStore:
    header()
    paragraph "Google Play's billing: the app brings Play Billing's library with --java (its classes.dex); the kit finds it by name. Products are set up in the Play Console."
    case storeStart()
    of ssReady:
      if products.len == 0 and bigButton("Ask for the Products"): discard storeProducts(["coins_100", "pro"])
      for p in products:
        if tableRow(p.title, detail = p.price, subtitle = p.description).clicked: discard storeBuy(p.id)
      if bigButton("What I Own", btGray): discard storeOwned()
    of ssUnavailable: label "No store here (no billing library in the APK, or a desktop)."
    else: label "Connecting to the store..."
    let e = storeEvent()
    case e.kind
    of seProduct: products.add e.product
    of sePurchase:
      say "bought " & e.purchase.products.join(", ")
      if e.purchase.state == 1: discard storeFinish(e.purchase, consumable = "coins_100" in e.purchase.products)
    of seError: say "the store said no (" & $e.code & ")"
    of seNone: discard
    logView()
  of pState:
    header()
    paragraph "Android may end the app while it is away; what is kept here -- the page open, this note -- comes back as it was (keepState, restoreState)."
    editArea(kept.note, lines = 5)
