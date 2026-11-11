## The system's own features in one place: notifications and the badge,
## sharing, a tap felt, the place, speech, starting with the computer,
## asking for the user's attention, the network, the language, the
## battery, the device -- on Linux, Windows, macOS, Android, iOS and in a
## web page, with the same calls. `docs/system.md` has what each system
## does, with examples.
##
## Every call is quick and never waits on the system: an answer that comes
## later (the place, a battery, a permission) is asked again in a later
## frame (the call says "waiting" until then, and the kit draws a frame
## when it comes). Where a system has no such feature, the call answers
## false (or `psNone`, -1, "") -- the app then offers what it can instead
## (a Copy button where there is no share sheet).
##
## .. code-block:: nim
##   import retroui, retroui/system
##   app "Shop", 400, 300:
##     if button("&Notify"): notify("Order 1042", "Ready at the counter", tag = "orders")
##     if button("&Share"):
##       if not share(text = "Order 1042 is ready", url = "https://example.com/o/1042"):
##         putClipboardText("https://example.com/o/1042")       # no share sheet here
##     if button("&Where am I?"): askPlace = true
##     if askPlace:
##       let p = location()
##       case p.state
##       of psOk: label "At " & $p.lat & ", " & $p.lon
##       of psWaiting: label "Looking..."
##       of psDenied: label "The place was not allowed."
##       of psNone: label "No place on this device."
##     if button("S&peak"): discard speak("Your order is ready")
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, times]
import uirelays/target   # (androidApp: an APK, not a program in Termux)
when not defined(wasm):
  import std/osproc
when not (defined(wasm) or androidApp):
  import std/streams
import uirelays/services
import native, notify

export notify.notify, notify.notifyAvailable, notify.clearNotification, notify.setBadge,
       notify.badgeCount
export native.vibrate, native.deviceName, native.osVersion, native.batteryLevel,
       native.systemDarkMode, native.beepSystem, native.userName, native.keepScreenOn,
       native.openSettings
export services.openUrl, services.openFile, services.shareFile, services.platformName,
       services.places, services.minimizeApp, services.dataDir, services.systemCall

type
  Haptic* = enum
    ## How a tap felt (`haptic`) is meant.
    hTap          ## a light tap: a button, a key
    hHeavy        ## a firm one: a long press, a snap into place
    hSuccess      ## something went well
    hWarning      ## look again
    hError        ## it did not work
    hSelection    ## a step in a picker or a list

  PlaceState* = enum
    psNone        ## no place on this system (or it cannot tell)
    psWaiting     ## asked: the user is being asked, or the device is looking
    psDenied      ## the user (or the system's settings) did not allow it
    psOk          ## `lat`, `lon` and `accuracy` are there

  Place* = object
    ## Where the device is (`location`).
    state*: PlaceState
    lat*, lon*: float        ## degrees (WGS 84: what maps use)
    accuracy*: float         ## meters (how far the truth may be)
    at*: float               ## when it was known (epochTime)

  Battery* = object
    level*: int              ## percent, -1 when unknown (no battery, a system that does not tell)
    charging*: bool

  DeviceInfo* = object
    ## The device in one call (`deviceInfo`).
    name*: string            ## "Pixel 9", "Foxoman's MacBook", "Chrome 131 on Windows"
    system*: string          ## "Android 15", "macOS 14.1", "Ubuntu 24.04.1 LTS", "Web (Windows)"
    platform*: string        ## `platformName()`: "linux", "windows", "macos", "android", "ios", "web"...
    language*: string        ## "en-US", "ar-OM"
    mobile*: bool            ## a phone or a tablet
    dark*: bool              ## the user chose a dark look
    online*: bool
    battery*: Battery
    cpus*: int

when defined(macosx) or defined(ios):
  proc frameworkLoaded(path: string): bool =
    nativeLib(path) != nil

# ---- small helpers ---------------------------------------------------------------------------------

proc jsonText(s: string): string =
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    of '\0' .. '\x08', '\x0b', '\x0c', '\x0e' .. '\x1f': discard
    else: result.add c
  result.add '"'

proc answered(s: string): bool = s.len > 0 and s != "\0"

proc parsePlace(s: string): Place =
  ## "ok LAT LON ACCURACY" / "waiting" / "denied" / "none"
  if s.startsWith("ok "):
    let f = s.split(' ')
    if f.len >= 4:
      try:
        return Place(state: psOk, lat: parseFloat(f[1]), lon: parseFloat(f[2]),
                     accuracy: parseFloat(f[3]), at: epochTime())
      except ValueError: discard
  case s
  of "waiting", "asked": Place(state: psWaiting)
  of "denied": Place(state: psDenied)
  else: Place(state: psNone)

when not defined(wasm) and not androidApp:
  var running: seq[Process]          # (speech: the programs speaking)

  proc reap() =
    var keep: seq[Process]
    for p in running:
      if p.running: keep.add p
      else: p.close()
    running = keep

  proc spawn(exe: string; args: openArray[string]; input = ""): bool =
    ## A program started and not waited for (its input written, closed).
    if exe.len == 0: return false
    try:
      let p = startProcess(exe, args = args, options = {poUsePath})
      if input.len > 0:
        p.inputStream.write(input)
      p.inputStream.close()
      running.add p
      true
    except OSError, IOError:
      false

# ---- sharing ---------------------------------------------------------------------------------------

proc share*(text = ""; url = ""; files: openArray[string] = []; title = ""): bool {.discardable.} =
  ## Offers `text`, a link (`url`) or `files` to the user's other apps:
  ## the share sheet of Android and iOS, macOS's share menu, the browser's
  ## (Web Share: phones, Safari, Chrome and Edge on Windows and macOS).
  ## False where the system has none (Windows and Linux desktops, Firefox):
  ## the app then offers Copy (`putClipboardText`) or Save As instead.
  if text.len == 0 and url.len == 0 and files.len == 0: return false
  when defined(wasm):
    var fs = ""
    for f in files: fs.add (if fs.len > 0: "," else: "") & jsonText(f)
    systemCall("share", "{\"title\":" & jsonText(title) & ",\"text\":" & jsonText(text) &
               ",\"url\":" & jsonText(url) & ",\"files\":[" & fs & "]}") == "1"
  elif androidApp:
    if files.len > 0: return shareFile(files[0])
    if not javaAvailable(): return false
    let body = if url.len > 0 and text.len > 0: text & "\n" & url elif url.len > 0: url else: text
    javaStatic("org.retro.RetroSystem", "shareText", jactivity(), title, body) == "1"
  elif defined(ios) or defined(macosx):
    try:
      autoreleasePool:
        let items = objcSend(ObjcId, objcClass("NSMutableArray"), "array")
        if text.len > 0: objcSend(void, items, "addObject:", nsString(text))
        if url.len > 0:
          let u = objcSend(ObjcId, objcClass("NSURL"), "URLWithString:", nsString(url))
          if u != nil: objcSend(void, items, "addObject:", u)
        for f in files:
          let u = objcSend(ObjcId, objcClass("NSURL"), "fileURLWithPath:", nsString(absolutePath(f)))
          if u != nil: objcSend(void, items, "addObject:", u)
        if objcSend(int, items, "count") == 0: return false
        when defined(ios):
          let app = objcSend(ObjcId, objcClass("UIApplication"), "sharedApplication")
          let win = objcSend(ObjcId, app, "keyWindow")
          let root = if win != nil: objcSend(ObjcId, win, "rootViewController") else: ObjcId(nil)
          if root == nil: return false
          let vc = objcSend(ObjcId, objcSend(ObjcId, objcClass("UIActivityViewController"), "alloc"),
                            "initWithActivityItems:applicationActivities:", items, ObjcId(nil))
          # (an iPad shows it as a popover: from the middle of the window)
          let pop = objcSend(ObjcId, vc, "popoverPresentationController")
          if pop != nil:
            let view = objcSend(ObjcId, root, "view")
            objcSend(void, pop, "setSourceView:", view)
          objcSend(void, root, "presentViewController:animated:completion:", vc, true, ObjcId(nil))
          result = true
        else:
          let app = objcSend(ObjcId, objcClass("NSApplication"), "sharedApplication")
          let win = objcSend(ObjcId, app, "keyWindow")
          if win == nil: return false
          let view = objcSend(ObjcId, win, "contentView")
          let picker = objcSend(ObjcId, objcSend(ObjcId, objcClass("NSSharingServicePicker"), "alloc"),
                                "initWithItems:", items)
          type NSRect = object
            x, y, w, h: float
          let bounds = objcSend(NSRect, view, "bounds")
          let at = NSRect(x: bounds.w / 2, y: bounds.h / 2, w: 1, h: 1)
          objcSend(void, picker, "showRelativeToRect:ofView:preferredEdge:", at, view, 1)  # NSMinYEdge
          result = true
    except CatchableError: result = false
  else:
    false

# ---- a tap felt ------------------------------------------------------------------------------------

proc haptic*(kind = hTap): bool {.discardable.} =
  ## A tap the user feels (phones; Mac trackpads; a web page on a phone):
  ## after a button, a snap into place, a success or an error. False where
  ## nothing is felt -- nothing to do then.
  when defined(wasm):
    let pattern = case kind
      of hTap, hSelection: "8"
      of hHeavy: "20"
      of hSuccess: "10,40,10"
      of hWarning: "20,60,20"
      of hError: "30,40,30,40,30"
    systemCall("vibrate", pattern) == "1"
  elif androidApp:
    if not javaAvailable(): return false
    let k = case kind
      of hTap: 0
      of hHeavy: 1
      of hSuccess: 2
      of hWarning: 3
      of hError: 4
      of hSelection: 5
    javaStatic("org.retro.RetroSystem", "haptic", jactivity(), k) == "1"
  elif defined(ios):
    try:
      autoreleasePool:
        case kind
        of hSuccess, hWarning, hError:
          let g = objcSend(ObjcId, objcSend(ObjcId, objcClass("UINotificationFeedbackGenerator"), "alloc"), "init")
          let n = if kind == hSuccess: 0 elif kind == hWarning: 1 else: 2
          objcSend(void, g, "notificationOccurred:", n)
          objcSend(void, g, "release")
        of hSelection:
          let g = objcSend(ObjcId, objcSend(ObjcId, objcClass("UISelectionFeedbackGenerator"), "alloc"), "init")
          objcSend(void, g, "selectionChanged")
          objcSend(void, g, "release")
        else:
          let g = objcSend(ObjcId, objcSend(ObjcId, objcClass("UIImpactFeedbackGenerator"), "alloc"),
                           "initWithStyle:", (if kind == hHeavy: 2 else: 0))
          objcSend(void, g, "impactOccurred")
          objcSend(void, g, "release")
      true
    except CatchableError: false
  elif defined(macosx):
    try:
      let p = objcSend(ObjcId, objcClass("NSHapticFeedbackManager"), "defaultPerformer")
      if p == nil: return false
      let pattern = case kind
        of hSelection, hTap: 1      # alignment
        of hHeavy: 2                # level change
        else: 0                     # generic
      objcSend(void, p, "performFeedbackPattern:performanceTime:", pattern, 1)
      true
    except CatchableError: false
  else:
    false

# ---- the place -------------------------------------------------------------------------------------

when not defined(wasm) and not androidApp and (defined(ios) or defined(macosx)):
  var placeManager: ObjcId

when not defined(wasm) and not androidApp and not defined(ios) and not defined(macosx) and
     not defined(windows):
  var termuxPlace: tuple[p: Process; started: float; answer: string]

proc location*(precise = false): Place =
  ## Where the device is: asked the first time (the user is asked to allow
  ## it), then kept up to date while the app asks; `psWaiting` until the
  ## first fix comes. `precise` asks for the GPS (more battery; a phone
  ## outdoors) instead of the network's few hundred meters. Web pages
  ## (served over https), Android (the APK needs
  ## `retroapk --permission:ACCESS_COARSE_LOCATION`, or FINE for `precise`),
  ## iOS and macOS (the app's Info.plist says why:
  ## NSLocationWhenInUseUsageDescription), Termux (Termux:API);
  ## `psNone` on Windows and Linux desktops.
  when defined(wasm):
    parsePlace(systemCall("location", if precise: "fine" else: ""))
  elif androidApp:
    if not javaAvailable(): return Place(state: psNone)
    parsePlace(javaStatic("org.retro.RetroSystem", "location", jactivity(), precise))
  elif defined(ios) or defined(macosx):
    try:
      if placeManager == nil:
        if not frameworkLoaded("/System/Library/Frameworks/CoreLocation.framework/CoreLocation"):
          return Place(state: psNone)
        placeManager = objcSend(ObjcId, objcSend(ObjcId, objcClass("CLLocationManager"), "alloc"), "init")
        if placeManager == nil: return Place(state: psNone)
        objcSend(void, placeManager, "setDesiredAccuracy:", (if precise: -1.0 else: 100.0))
        if respondsTo(placeManager, "requestWhenInUseAuthorization"):
          objcSend(void, placeManager, "requestWhenInUseAuthorization")
        objcSend(void, placeManager, "startUpdatingLocation")
      let status = if respondsTo(placeManager, "authorizationStatus"):
                     objcSend(int, placeManager, "authorizationStatus")
                   else: objcSend(int, objcClass("CLLocationManager"), "authorizationStatus")
      if status in [1, 2]: return Place(state: psDenied)      # restricted, denied
      let loc = objcSend(ObjcId, placeManager, "location")
      if loc == nil: return Place(state: psWaiting)
      type Coordinate = object
        lat, lon: float
      let c = objcSend(Coordinate, loc, "coordinate")
      Place(state: psOk, lat: c.lat, lon: c.lon, accuracy: objcSend(float, loc, "horizontalAccuracy"),
            at: epochTime())
    except CatchableError: Place(state: psNone)
  elif defined(windows):
    Place(state: psNone)
  else:
    # Termux: termux-location, run in the background; its answer kept
    if not inTermux() or findExe("termux-location").len == 0: return Place(state: psNone)
    if termuxPlace.p != nil and not termuxPlace.p.running:
      termuxPlace.answer = try: termuxPlace.p.outputStream.readAll() except IOError, OSError: ""
      termuxPlace.p.close()
      termuxPlace.p = nil
    if termuxPlace.p == nil and epochTime() - termuxPlace.started > 30:
      termuxPlace.started = epochTime()
      try:
        termuxPlace.p = startProcess("termux-location", args = ["-p", if precise: "gps" else: "network",
                                     "-r", "once"], options = {poUsePath})
      except OSError: return Place(state: psNone)
    let j = termuxPlace.answer
    proc num(key: string): float =
      let i = j.find("\"" & key & "\"")
      if i < 0: return NaN
      var k = j.find(':', i) + 1
      while k < j.len and j[k] == ' ': inc k
      var e = k
      while e < j.len and j[e] in {'0'..'9', '-', '.', 'e', 'E', '+'}: inc e
      try: parseFloat(j[k ..< e]) except ValueError: NaN
    let lat = num("latitude")
    let lon = num("longitude")
    if lat == lat and lon == lon:
      Place(state: psOk, lat: lat, lon: lon, accuracy: (let a = num("accuracy"); if a == a: a else: 0.0),
            at: termuxPlace.started)
    elif "denied" in j.toLowerAscii or "permission" in j.toLowerAscii: Place(state: psDenied)
    else: Place(state: psWaiting)

proc stopLocation*() =
  ## Stops keeping the place up to date (the battery thanks you); the next
  ## `location` starts again.
  when defined(wasm):
    discard systemCall("location.stop", "")
  elif androidApp:
    if javaAvailable(): discard javaStatic("org.retro.RetroSystem", "stopLocation", jactivity())
  elif defined(ios) or defined(macosx):
    if placeManager != nil:
      try: objcSend(void, placeManager, "stopUpdatingLocation")
      except CatchableError: discard
      placeManager = nil

# ---- speech ----------------------------------------------------------------------------------------

when defined(ios) or defined(macosx):
  var synth: ObjcId

proc speak*(text: string; lang = ""; rate = 1.0): bool {.discardable.} =
  ## Says `text` aloud with the system's voice (`lang` "ar", "en-GB"...:
  ## a voice of that language where there is one; `rate` 1 is normal, 0.5
  ## slower, 2 faster). Speech that was going on carries on first. Web
  ## pages, Android, iOS, macOS, Windows (its voices, through PowerShell),
  ## Linux (speech-dispatcher's `spd-say`, or `espeak-ng`), Termux
  ## (Termux:API). False where there is no voice.
  if text.strip.len == 0: return false
  when defined(wasm):
    systemCall("speak", "{\"text\":" & jsonText(text) & ",\"lang\":" & jsonText(lang) &
               ",\"rate\":" & $rate & "}") == "1"
  elif androidApp:
    if not javaAvailable(): return false
    javaStatic("org.retro.RetroSystem", "speak", jactivity(), text, lang, rate) == "1"
  elif defined(ios) or defined(macosx):
    try:
      if not frameworkLoaded("/System/Library/Frameworks/AVFoundation.framework/AVFoundation"):
        return false
      if synth == nil:
        synth = objcSend(ObjcId, objcSend(ObjcId, objcClass("AVSpeechSynthesizer"), "alloc"), "init")
      if synth == nil: return false
      autoreleasePool:
        let u = objcSend(ObjcId, objcClass("AVSpeechUtterance"), "speechUtteranceWithString:", nsString(text))
        if lang.len > 0:
          let v = objcSend(ObjcId, objcClass("AVSpeechSynthesisVoice"), "voiceWithLanguage:", nsString(lang))
          if v != nil: objcSend(void, u, "setVoice:", v)
        # (AVSpeechUtteranceDefaultSpeechRate is 0.5 of 0..1)
        objcSend(void, u, "setRate:", float32(clamp(0.5 * rate, 0.1, 1.0)))
        objcSend(void, synth, "speakUtterance:", u)
      true
    except CatchableError: false
  elif defined(windows):
    reap()
    let ps = findExe("powershell")
    let script = "Add-Type -AssemblyName System.Speech; $s = New-Object System.Speech.Synthesis.SpeechSynthesizer; " &
                 "$s.Rate = " & $clamp(int((rate - 1.0) * 6), -10, 10) & "; " &
                 (if lang.len > 0: "try { $v = $s.GetInstalledVoices() | Where-Object { $_.VoiceInfo.Culture.Name -like '" &
                                   lang.replace("'", "") & "*' } | Select-Object -First 1; if ($v) { $s.SelectVoice($v.VoiceInfo.Name) } } catch {}; "
                  else: "") &
                 "$s.Speak([Console]::In.ReadToEnd())"
    spawn(ps, ["-NoProfile", "-NonInteractive", "-Command", script], text)
  else:
    reap()
    if inTermux() and findExe("termux-tts-speak").len > 0:
      return spawn("termux-tts-speak", (if lang.len > 0: @["-l", lang] else: @[]) & @["-r", $rate], text)
    let spd = findExe("spd-say")
    if spd.len > 0:
      var args = @["-r", $clamp(int((rate - 1.0) * 50), -100, 100)]
      if lang.len > 0: args.add ["-l", lang.split('-')[0]]
      args.add text
      return spawn(spd, args)
    for exe in ["espeak-ng", "espeak"]:
      let e = findExe(exe)
      if e.len > 0:
        var args = @["-s", $int(175 * rate)]
        if lang.len > 0: args.add ["-v", lang.toLowerAscii]
        args.add "--stdin"
        return spawn(e, args, text)
    false

proc stopSpeaking*() =
  ## Stops what `speak` is saying (and what it was going to say).
  when defined(wasm):
    discard systemCall("speak.stop", "")
  elif androidApp:
    if javaAvailable(): discard javaStatic("org.retro.RetroSystem", "stopSpeaking")
  elif defined(ios) or defined(macosx):
    if synth != nil:
      try: discard objcSend(bool, synth, "stopSpeakingAtBoundary:", 0)
      except CatchableError: discard
  else:
    when not defined(windows):
      let spd = findExe("spd-say")
      if spd.len > 0:
        try: discard execCmdEx(quoteShell(spd) & " -C")
        except OSError: discard
    for p in running:
      try:
        if p.running: p.terminate()
      except OSError: discard
    reap()

proc speaking*(): bool =
  ## `speak` is still saying something.
  when defined(wasm):
    systemCall("speaking", "") == "1"
  elif androidApp:
    javaAvailable() and javaStatic("org.retro.RetroSystem", "speaking") == "1"
  elif defined(ios) or defined(macosx):
    synth != nil and objcSend(bool, synth, "isSpeaking")
  else:
    reap()
    running.len > 0

# ---- starting with the computer --------------------------------------------------------------------

proc appId(app: string): string =
  ## A file name of the app: "Retro Mail" -> "retro-mail".
  result = ""         # (a value at once: see tools/writecheck.py)
  let name = if app.len > 0: app else: getAppFilename().splitFile.name
  for c in name.toLowerAscii:
    if c in {'a'..'z', '0'..'9'}: result.add c
    elif result.len > 0 and result[^1] != '-': result.add '-'
  result = result.strip(chars = {'-'})
  if result.len == 0: result = "app"

when defined(windows):
  proc RegSetKeyValueW(key: int; sub, name: WideCString; kind: uint32; data: pointer;
                       size: uint32): int32 {.stdcall, dynlib: "advapi32", importc.}
  proc RegDeleteKeyValueW(key: int; sub, name: WideCString): int32 {.stdcall, dynlib: "advapi32", importc.}
  proc RegGetValueW(key: int; sub, name: WideCString; flags: uint32; kind: ptr uint32;
                    data: pointer; size: ptr uint32): int32 {.stdcall, dynlib: "advapi32", importc.}
  const
    HkeyCurrentUser = int(0x80000001'u32)
    RunKey = "Software\\Microsoft\\Windows\\CurrentVersion\\Run"

proc openAtLogin*(app = ""): bool =
  ## The app starts when the user logs in (`setOpenAtLogin`). Desktops.
  let id = appId(app)
  when defined(wasm) or androidApp or defined(ios):
    false
  elif defined(windows):
    var size = 0'u32
    RegGetValueW(HkeyCurrentUser, newWideCString(RunKey), newWideCString(id), 0x2,  # RRF_RT_REG_SZ
                 nil, nil, addr size) == 0
  elif defined(macosx):
    fileExists(getHomeDir() / "Library/LaunchAgents" / ("app." & id & ".plist"))
  else:
    let f = getConfigDir() / "autostart" / (id & ".desktop")
    fileExists(f) and "Hidden=true" notin (try: readFile(f) except IOError: "")

proc setOpenAtLogin*(on: bool; app = ""; command = ""): bool {.discardable.} =
  ## Starts the app when the user logs in (`on`), or not any more. `app`
  ## is its name ("Retro Mail"; the program's name when ""), `command` what
  ## starts it (this program when ""). Windows (the Run key), macOS (a
  ## launch agent), Linux and the BSDs (an autostart entry, freedesktop's).
  ## False on phones and in web pages, where the system decides.
  let id = appId(app)
  let cmd = if command.len > 0: command else: getAppFilename()
  try:
    when defined(wasm) or androidApp or defined(ios):
      false
    elif defined(windows):
      if on:
        let v = newWideCString("\"" & cmd & "\"")
        var w = newSeq[uint16](len(v) + 1)                   # (with its 0)
        for i in 0 ..< len(v): w[i] = uint16(v[i])
        RegSetKeyValueW(HkeyCurrentUser, newWideCString(RunKey), newWideCString(id), 1,  # REG_SZ
                        addr w[0], uint32(w.len * 2)) == 0
      else:
        let r = RegDeleteKeyValueW(HkeyCurrentUser, newWideCString(RunKey), newWideCString(id))
        r == 0 or r == 2                                     # (2: not there)
    elif defined(macosx):
      let dir = getHomeDir() / "Library/LaunchAgents"
      let f = dir / ("app." & id & ".plist")
      if on:
        createDir(dir)
        writeFile(f, """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>app.$1</string>
  <key>ProgramArguments</key><array><string>$2</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
""" % [id, cmd.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"))])
      elif fileExists(f): removeFile(f)
      true
    else:
      let dir = getConfigDir() / "autostart"
      let f = dir / (id & ".desktop")
      if on:
        createDir(dir)
        let name = if app.len > 0: app else: getAppFilename().splitFile.name
        writeFile(f, "[Desktop Entry]\nType=Application\nName=" & name & "\nExec=" &
                     (if ' ' in cmd: "\"" & cmd & "\"" else: cmd) &
                     "\nX-GNOME-Autostart-enabled=true\n")
      elif fileExists(f): removeFile(f)
      true
  except CatchableError:
    false

# ---- attention, the network, the language, the battery, the device ----------------------------------

proc requestAttention*(): bool {.discardable.} =
  ## Asks the user to look at the app while it is behind others: the
  ## taskbar's button flashes (Windows), the Dock's icon bounces (macOS),
  ## the window manager marks it (X11), the tab's title blinks (a web page).
  ## Nothing when the app is in front already. False where the system has
  ## no such sign (Wayland, phones).
  when defined(macosx) and not defined(ios):
    try:
      let app = objcSend(ObjcId, objcClass("NSApplication"), "sharedApplication")
      discard objcSend(int, app, "requestUserAttention:", 10)      # NSInformationalRequest
      true
    except CatchableError: false
  else:
    systemCall("attention", "") == "1"

proc online*(): bool =
  ## The device has a network (as far as it can tell: a network can be
  ## there and the internet not). True when it cannot tell.
  when defined(wasm):
    systemCall("online", "") != "0"
  elif androidApp:
    not javaAvailable() or javaStatic("org.retro.RetroSystem", "online", jactivity()) != "0"
  elif defined(windows):
    proc InternetGetConnectedState(flags: ptr uint32; reserved: uint32): int32 {.stdcall, dynlib: "wininet", importc.}
    var f: uint32
    InternetGetConnectedState(addr f, 0) != 0
  elif defined(linux):
    # a default route (Linux): no network has none
    try:
      for line in lines("/proc/net/route"):
        let f = line.splitWhitespace
        if f.len > 2 and f[1] == "00000000" and f[0] != "lo": return true
      false
    except IOError, OSError: true
  else:
    true

proc systemLanguage*(): string =
  ## The user's language, as a tag: "en-US", "ar-OM", "fr".
  result = ""         # (a value at once: see tools/writecheck.py)
  try:
    when defined(wasm):
      result = systemCall("language", "")
    elif androidApp:
      if javaAvailable(): result = javaStatic("org.retro.RetroSystem", "language")
    elif defined(ios) or defined(macosx):
      autoreleasePool:
        let langs = objcSend(ObjcId, objcClass("NSLocale"), "preferredLanguages")
        if langs != nil and objcSend(int, langs, "count") > 0:
          result = toNim(objcSend(ObjcId, langs, "objectAtIndex:", 0))
    elif defined(windows):
      proc GetUserDefaultLocaleName(buf: ptr uint16; n: int32): int32 {.stdcall, dynlib: "kernel32", importc.}
      var buf: array[85, uint16]
      let n = GetUserDefaultLocaleName(addr buf[0], int32(buf.len))
      for i in 0 ..< max(0, n - 1): result.add char(buf[i] and 0x7F)
    if result.len == 0:
      for v in ["LC_ALL", "LC_MESSAGES", "LANG"]:
        # (C, POSIX and C.UTF-8 name no language: the next one, else English)
        let s = getEnv(v).split('.')[0].split('@')[0]
        if s.len > 0 and s notin ["C", "POSIX"]:
          result = s.replace('_', '-')
          break
  except CatchableError: discard
  if result.len == 0 or result == "\0": result = "en"

proc battery*(): Battery =
  ## The battery: its charge in percent (-1 when unknown) and whether it
  ## is charging (as far as the system tells).
  result.level = batteryLevel()
  try:
    when defined(wasm):
      result.charging = "charging" in systemCall("battery", "")
    elif defined(linux) and not androidApp:
      for kind, dir in walkDir("/sys/class/power_supply"):
        if (try: readFile(dir / "type").strip except IOError: "") == "Battery":
          result.charging = (try: readFile(dir / "status").strip except IOError: "") in ["Charging", "Full"]
          break
  except CatchableError: discard

proc revealFile*(path: string): bool {.discardable.} =
  ## Shows `path` in the system's file manager, selected (Explorer, the
  ## Finder, the desktop's file manager); in a web page and on phones, the
  ## file is handed over as `openFile` does.
  let full = absolutePath(path)
  if not fileExists(full) and not dirExists(full): return false
  try:
    when defined(wasm) or androidApp or defined(ios):
      openFile(full)
    elif defined(windows):
      discard startProcess("explorer.exe", args = ["/select," & full], options = {poUsePath, poDaemon})
      true
    elif defined(macosx):
      discard startProcess("open", args = ["-R", full], options = {poUsePath, poDaemon})
      true
    else:
      # freedesktop's FileManager1 (Nautilus, Dolphin, Nemo, Thunar...), else the folder
      let gdbus = findExe("gdbus")
      if gdbus.len > 0:
        let (_, code) = execCmdEx(quoteShell(gdbus) & " call --session --dest org.freedesktop.FileManager1" &
          " --object-path /org/freedesktop/FileManager1 --method org.freedesktop.FileManager1.ShowItems " &
          quoteShell("['file://" & full.replace("'", "%27") & "']") & " ''")
        if code == 0: return true
      openFile(full.parentDir)
  except CatchableError:
    false

proc deviceInfo*(): DeviceInfo =
  ## The device in one call (the battery and the dark look asked again
  ## each time: cheap).
  DeviceInfo(name: deviceName(), system: osVersion(), platform: platformName(),
             language: systemLanguage(),
             mobile: platformName() in ["android", "ios"] or androidApp,
             dark: systemDarkMode(), online: online(), battery: battery(),
             cpus: (when defined(wasm): (try: parseInt(systemCall("cpus", "")) except ValueError: 1)
                    else: max(1, countProcessors())))
