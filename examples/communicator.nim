## Retro Communicator: an instant messenger in the look of 1999 -- the
## friends list with its groups, who is online and who is away, a window
## for each conversation, chat rooms, away messages, profiles with a
## picture, files sent -- on XMPP (Jabber): an account on any public server,
## made from inside the app where the server allows it, talking to anyone on
## any XMPP app (Conversations, Gajim, Monal, Dino...). No server of mine to
## run, no phone number, no email.
##
## Your history stays on your device (a log per friend), and where your
## server keeps an archive of your messages (most do: XEP-0313) it is
## brought in when you sign on -- what you said from your phone shows on
## the computer, and a new device gets the conversations of before.
## Voice messages: the microphone button records (Termux:API's microphone
## on a phone, PulseAudio or ALSA on Linux) and sends it as a file, as
## Conversations and the others do; a voice message that comes plays here.
## Talks are end-to-end encrypted with OMEMO (the lock button), as
## Conversations, Monal, Gajim and Dino do it, when the other one's app has
## it: the server carries words it cannot read; files and voice messages
## sent in such a talk are locked too (aesgcm://). The fingerprints are in
## Info and My Profile, to compare them side by side.
## The password is kept by the system's keyring when you ask it to be saved.
##
## Build: `nim c -d:release -d:ssl examples/communicator.nim` (OpenSSL,
## loaded at run time). `RETRO_COMM_INSECURE=1` accepts a server's
## self-signed certificate (a server of your own, for trying).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, tables, times, algorithm, base64, typedthreads, locks, sets, osproc, hashes, exitprocs, uri, sequtils]
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)
import retroui
import retroui/[qrcode, xmpp, media, mediaaudio, notify, http, secrets, omemo]
when not defined(windows): import std/posix

const
  App = "retro-communicator"
  brand = color(0, 100, 130)
  brandSoft = color(200, 228, 236)
  online = color(0, 160, 0)
  awayC = color(210, 140, 0)
  busyC = color(200, 0, 0)
  idle = color(128, 128, 128)
  me = color(192, 0, 0)
  them = color(0, 0, 192)
  good = color(0, 128, 0)
  States = ["Available", "Away", "Busy", "Invisible"]
  Shows = ["", "away", "dnd", ""]
  Servers = ["yax.im", "xmpp.jp", "jabber.hot-chilli.net", "jabberes.org", "chatterboxtown.us"]
    ## public servers that have made accounts from apps (any other can be typed)

type
  Screen = enum scWelcome, scSignOn, scCreate, scDone, scMain

  Buddy = ref object
    jid, name, subscription, status, typing: string
    groups: seq[string]
    ask: bool
    shows: Table[string, string]   ## resource -> show ("" available)
    photo: Bitmap
    vcard: seq[(string, string)]

  Line = object
    who, text, time, url, id: string
    aid: string                    ## its id in the server's archive ("" not known)
    at: string                     ## when, in UTC (ISO 8601: sorts as text; "" before 0.22)
    mine, system, delivered: bool
    locked: bool                   ## it came or went encrypted (OMEMO)
    failed: bool                   ## it could not go

  Up = object
    ## a file going: its talk, the file, and when the talk is encrypted the
    ## locked copy uploaded and its secret
    t: Talk
    path, sent, secret: string

  Talk = ref object
    jid: string
    room: bool
    nick: string
    win: MdiWindow
    lines: seq[Line]
    draft: string
    occupants: seq[string]
    subject: string
    unread: int
    composing: bool
    lastKey: float
    autoReplied: bool
    stick: bool                    ## the transcript follows the newest line
    stuck: int                     ## ... frames it went to the bottom for that
    asking: string                 ## an archive's page asked for it ("" none)
    archiveEnd: bool               ## the archive has nothing earlier
    secure: bool                   ## messages go encrypted (OMEMO)

var
  conf: Settings
  screen = scWelcome
  address, password, server, newName, newPassword, newPassword2: string
  savePassword = true
  autoSignOn = false
  insecure = getEnv("RETRO_COMM_INSECURE") == "1"
  showPassword = false
  signing = false
  registering = false
  said = ""                        ## what went wrong, or what happens now
  myState = 0
  myNote = ""
  noteSent = ""
  noteAt = 0.0
  awayMessage = "I am away from the computer right now."
  soundsOn = true
  buddies: OrderedTable[string, Buddy]
  talks: seq[Talk]
  asks: seq[(string, string)]      ## who asks to add you, the name they gave
  closedGroups: seq[string]
  find = ""
  selected = ""
  friendsWin = MdiWindow(title: "Friends", r: rect(8, 8, 270, 440), open: true, glyph: pxUser, grip: true)
  friendsSized = false             ## (the Friends window's first size: at the interface's size)
  qrPic: Bitmap
  services: Table[string, string]  ## "upload", "rooms" -> the service's address
  myPhoto: Bitmap
  myFields: seq[(string, string)]
  wantedOff = false                ## signed off on purpose (no reconnecting)
  retryAt = 0.0
  retries = 0
  # dialogs
  showAdd, showAsks, showInfo, showProfile, showAway, showRoom, showRename, showAbout,
    showSendFile, showRemove: bool
  addJid, addName, addGroup = ""
  infoJid = ""
  renameName, renameGroup = ""
  roomJid, roomNick = ""
  sendPath = ""
  sendTo: Talk
  profileName, profileAbout, profilePhoto = ""
  uploads: Table[string, Up]       ## the slot's id -> the file going
  # the server's archive
  archiveOn = false                ## the server keeps one
  syncing = ""                     ## the page asked for now when signing on ("" none)
  syncLast = ""                    ## the last archive id the sync took
  liveLast = ""                    ## the last archive id of a message that came meanwhile
  earlier: Table[string, seq[Line]]   ## a talk's earlier page, as it comes (the asking's id)
  seenIds: Table[string, HashSet[string]]   ## per friend: the ids in the log (no line twice)
  # end-to-end encryption
  keys: OmemoStore                 ## this device's OMEMO (nil: no libcrypto)
  plainFor: seq[string]            ## the friends you turned the lock off for
  # voice messages
  recTalk: Talk                    ## recording for this talk (nil none)
  recProc: Process
  recFile = ""
  recStart = 0.0
  playing = ""                     ## the voice message playing (its address)
  playId: SoundId
  playProc: Process

# ---- the files: settings, history ----------------------------------------------------------------

proc dataPath(name: string): string =
  result = dataDir(App) / name
  createDir(result.parentDir)

proc keep() =
  conf["address"] = address
  conf["server"] = server
  conf["savePassword"] = (if savePassword: "1" else: "0")
  conf["autoSignOn"] = (if autoSignOn: "1" else: "0")
  conf["state"] = $myState
  conf["note"] = myNote
  conf["away"] = awayMessage
  conf["sounds"] = (if soundsOn: "1" else: "0")
  conf["closed"] = closedGroups.join("\t")
  conf["plain"] = plainFor.join("\t")
  discard saveSettings(App, conf)

proc logFile(jid: string): string = dataPath("logs" / jid.replace("/", "_") & ".log")

proc logText(l: Line): string =
  ## A line of the log: when, who, mine, the file, the words, its id, its
  ## archive id, when in UTC (the last three since 0.22: older lines have
  ## five fields).
  [l.time, l.who, (if l.mine: "1" else: "0"), l.url,
   l.text.replace("\n", "\\n").replace("\t", " "), l.id, l.aid, l.at, (if l.locked: "1" else: "")].join("\t")

proc lineOf(s: string): (bool, Line) =
  let f = s.split('\t')
  if f.len < 5: return (false, Line())
  var l = Line(time: f[0], who: f[1], mine: f[2] == "1", url: f[3],
               text: f[4].replace("\\n", "\n"), delivered: true)
  if f.len >= 7:
    l.id = f[5]
    l.aid = f[6]
  if f.len >= 8: l.at = f[7]
  if f.len >= 9: l.locked = f[8] == "1"
  (true, l)

proc keyOf(l: Line): string = (if l.mine: "1" else: "0") & ":" & l.text
  ## (a line known by its words, for lines kept before they had ids)

var lastAt: Table[string, string]   ## per friend: when the log's newest line was said

proc seen(jid: string): var HashSet[string] =
  ## The ids (and words) of what the log of `jid` holds: an archive's
  ## message already here is not added again.
  if not seenIds.hasKey(jid):
    var ids = initHashSet[string]()
    try:
      for s in readFile(logFile(jid)).splitLines:
        let (ok, l) = lineOf(s)
        if ok:
          if l.id.len > 0: ids.incl "i:" & l.id
          if l.aid.len > 0: ids.incl "a:" & l.aid
          if l.id.len == 0 and l.aid.len == 0: ids.incl keyOf(l)
          if l.at > lastAt.getOrDefault(jid): lastAt[jid] = l.at
    except CatchableError: discard
    seenIds[jid] = ids
  seenIds[jid]

proc remember(jid: string; l: Line) =
  if l.id.len > 0: seen(jid).incl "i:" & l.id
  if l.aid.len > 0: seen(jid).incl "a:" & l.aid
  if l.id.len == 0 and l.aid.len == 0: seen(jid).incl keyOf(l)

proc logLine(jid: string; l: Line) =
  ## A line kept: at the end, or -- said before the newest (the archive
  ## brings what another device said while this one was off) -- where it
  ## goes by its time.
  discard seen(jid)
  try:
    if l.at.len == 0 or l.at >= lastAt.getOrDefault(jid):
      let f = open(logFile(jid), fmAppend)
      f.writeLine(logText(l))
      f.close()
      if l.at.len > 0: lastAt[jid] = l.at
    else:
      var all = readFile(logFile(jid)).splitLines
      while all.len > 0 and all[^1].len == 0: all.setLen(all.len - 1)
      var k = all.len
      while k > 0:
        let (ok, o) = lineOf(all[k - 1])
        if ok and o.at.len > 0 and o.at <= l.at: break
        if ok and o.at.len == 0: break       # (older lines, without times)
        dec k
      all.insert(logText(l), k)
      writeFile(logFile(jid), all.join("\n") & "\n")
  except CatchableError: discard
  remember(jid, l)

proc logEarlier(jid: string; lines: seq[Line]) =
  ## Lines from before the log's first, put at its start.
  try:
    var all = ""
    for l in lines:
      all.add logText(l) & "\n"
      remember(jid, l)
    let old = if fileExists(logFile(jid)): readFile(logFile(jid)) else: ""
    writeFile(logFile(jid), all & old)
  except CatchableError: discard

proc history(jid: string): seq[Line] =
  ## The last lines said with `jid` (the log on this device).
  try:
    var all = readFile(logFile(jid)).splitLines
    if all.len > 120: all = all[^120 .. ^1]
    for s in all:
      let (ok, l) = lineOf(s)
      if ok: result.add l
  except CatchableError: discard

# ---- sounds: of its own, made here ---------------------------------------------------------------

var doorOpen, doorClose, msgIn, msgOut: Sound

proc makeSounds() =
  doorOpen = joinSounds([makeTone(523, 70, 0.35), makeTone(659, 70, 0.35), makeTone(784, 120, 0.35)])
  doorClose = joinSounds([makeTone(784, 70, 0.3), makeTone(523, 140, 0.3)])
  msgIn = joinSounds([makeTone(1046, 60, 0.3), makeTone(1318, 110, 0.3)])
  msgOut = makeTone(880, 50, 0.2)

proc play(s: Sound) =
  if soundsOn and s != nil: discard playSound(s)

# ---- people --------------------------------------------------------------------------------------

proc nameOf(jid: string): string =
  let b = buddies.getOrDefault(jid)
  if b != nil and b.name.len > 0: b.name
  elif b != nil and b.vcard.len > 0:
    var n = ""
    for (k, v) in b.vcard:
      if k in ["NICKNAME", "FN"] and v.len > 0 and n.len == 0: n = v
    if n.len > 0: n else: localOf(jid)
  elif localOf(jid).len > 0: localOf(jid)
  else: jid

proc showOf(b: Buddy): string =
  ## "unavailable", or the best of its devices' ("" available first).
  if b == nil or b.shows.len == 0: return "unavailable"
  result = "xa"
  for s in b.shows.values:
    if s in ["", "chat"]: result = ""; return
    if s == "away" and result == "xa": result = "away"
    if s == "dnd": result = "dnd"

proc stateColor(show: string): Color =
  case show
  of "", "chat": online
  of "away", "xa": awayC
  of "dnd": busyC
  else: idle

proc stateName(show: string): string =
  case show
  of "", "chat": "Available"
  of "away": "Away"
  of "xa": "Away for long"
  of "dnd": "Busy"
  else: "Offline"

proc now12(): string = now().format("h:mm tt")

proc nowAt(): string = now().utc.format("yyyy-MM-dd'T'HH:mm:ss")
  ## (now, as a line's `at`)

proc atOf(stamp: string): string = (if stamp.len >= 19: stamp[0 ..< 19] else: nowAt())

proc stampTime(stamp: string): string =
  ## A server's time (ISO 8601, UTC) as this device's: "Nov 1 2:00 PM".
  if stamp.len < 19: return now12()
  try: stamp[0 ..< 19].parse("yyyy-MM-dd'T'HH:mm:ss", utc()).local.format("MMM d h:mm tt")
  except CatchableError: stamp

proc photoOf(fields: seq[(string, string)]): Bitmap =
  var data, kind = ""
  for (k, v) in fields:
    if k == "PHOTO": data = v
    if k == "TYPE": kind = v
  if data.len == 0: return nil
  try:
    let ext = if "png" in kind: ".png" elif "gif" in kind: ".gif" else: ".jpg"
    let f = getTempDir() / "retro-comm-photo" & ext
    writeFile(f, decode(data))
    result = loadPicture(f, 96, 96)
    removeFile(f)
  except CatchableError: result = nil

proc picture(name: string; pic: Bitmap; size: int) =
  if pic != nil:
    let r = place(size, size)
    drawBitmap(r, pic)
  else:
    avatar(name, size = size)

# ---- conversations -------------------------------------------------------------------------------

proc talkWith(jid: string; room = false; open = true): Talk =
  for t in talks:
    if t.jid == jid: return t
  # (beside the friends, a step lower than the one before, at the
  # interface's size; inside the area)
  let area = mdiAreaRect()
  let k = talks.len mod 6
  var r = rect(friendsWin.r.x + friendsWin.r.w + dp(12) + k * dp(24), dp(16) + k * dp(24), dp(440), dp(400))
  if area.w > 0:
    r.w = max(dp(280), min(r.w, area.w - r.x - dp(8)))
    if r.x + r.w > area.w: r.x = max(dp(8), area.w - r.w - dp(8))
    r.h = max(dp(220), min(r.h, area.h - r.y - dp(40)))     # (its title bar too)
  result = Talk(jid: jid, room: room, stick: true,
                win: MdiWindow(title: (if room: jid else: nameOf(jid)), open: open, grip: true,
                               glyph: (if room: nfComments else: nfComment), r: r))
  if not room: result.lines = history(jid)
  talks.add result
  if not room and keys != nil:
    result.secure = keys.omemoKnows(jid) and jid notin plainFor
    if xmppRunning(): keys.omemoRefresh(jid)
  if not room and result.lines.len == 0 and archiveOn and xmppRunning():
    # (nothing here yet, on this device: the conversation of before)
    result.asking = askArchive(with = jid, latest = true, max = 50)
    earlier[result.asking] = @[]

proc addLine(t: Talk; l: Line) =
  # (in the order said: a line from the archive may go before the last ones)
  var k = t.lines.len
  if l.at.len > 0:
    while k > 0 and t.lines[k - 1].at > l.at: dec k
  t.lines.insert(l, k)
  if t.lines.len > 500: t.lines.delete(0)
  if not t.room: logLine(t.jid, l)
  t.stick = true

proc systemLine(t: Talk; s: string) =
  t.lines.add Line(text: s, system: true, time: now12(), at: nowAt())

proc send(t: Talk) =
  let body = t.draft.strip
  if body.len == 0 or not xmppRunning(): return
  if t.room:
    sendRoom(t.jid, body)
  else:
    let id = if t.secure and keys != nil: keys.omemoSend(t.jid, body) else: sendChat(t.jid, body)
    t.addLine Line(who: localOf(myJid), text: body, time: now12(), mine: true, id: id, at: nowAt(),
                   locked: t.secure and keys != nil)
    play(msgOut)
  t.draft = ""
  t.composing = false

# ---- signing on and off --------------------------------------------------------------------------

proc signOn() =
  if address.strip.len == 0 or password.len == 0 or '@' notin address:
    said = "Write your whole address (name@server) and your password."
    return
  address = address.strip.toLowerAscii
  if savePassword: discard saveSecret(App, address, password)
  else: deleteSecret(App, address)
  keep()
  buddies.clear()
  archiveOn = false
  syncing = ""
  signing = true
  wantedOff = false
  said = "Connecting..."
  xmppStart(address, password, insecure = insecure, show = Shows[myState], status = myNote)

proc signOff() =
  wantedOff = true
  xmppStop()

proc createAccount() =
  let name = newName.strip.toLowerAscii
  if name.len < 2 or name.contains({'@', ' ', '/'}):
    said = "A screen name of letters and numbers, without spaces."
    return
  if newPassword.len < 6:
    said = "A password of 6 or more letters."
    return
  if newPassword != newPassword2:
    said = "The two passwords are not the same."
    return
  address = name & "@" & server.strip.toLowerAscii
  password = newPassword
  registering = true
  said = "Making the account on " & server & "..."
  xmppStart(address, password, insecure = insecure, register = true)

# ---- uploads: a file put where the server says, its address sent --------------------------------

type UploadJob = object
  id, putUrl, getUrl, path, mime: string
  headers: seq[(string, string)]

var
  upLock: Lock
  upDone {.guard: upLock.}: seq[(string, string, string)]    ## id, address, what went wrong
  upThreads: seq[ref Thread[UploadJob]]

proc mimeOf(path: string): string =
  case path.splitFile.ext.toLowerAscii
  of ".m4a": "audio/mp4"
  of ".aac": "audio/aac"
  of ".ogg", ".oga", ".opus": "audio/ogg"
  of ".wav": "audio/wav"
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".gif": "image/gif"
  of ".webp": "image/webp"
  of ".pdf": "application/pdf"
  of ".txt": "text/plain"
  of ".mp3": "audio/mpeg"
  of ".mp4": "video/mp4"
  else: "application/octet-stream"

proc uploadNow(j: UploadJob) {.thread.} =
  var err = ""
  try:
    var hs = @[("Content-Type", j.mime)]
    for h in j.headers: hs.add h
    let r = httpRequest("PUT", j.putUrl, hs, readFile(j.path), timeoutSec = 120)
    if not r.ok: err = "the server did not take the file (" & $r.status & ")"
  except CatchableError as e: err = e.msg
  {.cast(gcsafe).}:
    withLock upLock: upDone.add (j.id, j.getUrl, err)

proc plainPath(url: string): string =
  ## (an address without what follows "?" or "#")
  result = url
  for c in ['#', '?']:
    let q = result.find(c)
    if q >= 0: result = result[0 ..< q]

proc isAudio(path: string): bool =
  ## A voice message (or another sound): by its name's end.
  let p = plainPath(path)
  p.toLowerAscii.splitFile.ext in [".m4a", ".aac", ".mp3", ".ogg", ".oga", ".opus", ".wav", ".amr", ".flac", ".weba"]

proc voicePath(url: string): string =
  ## Where a voice message (or a file) is kept here, by its address.
  dataPath("voice" / toHex(cast[uint64](hash(url))) & plainPath(url).splitFile.ext.toLowerAscii)

proc recorded(path: string): bool = path.parentDir == dataPath("voice" / "x").parentDir
  ## (a voice message recorded here, not a file chosen)

proc sendFile(t: Talk; path: string) =
  let svc = services.getOrDefault("upload")
  if svc.len == 0:
    t.systemLine("Your server takes no files (it has no HTTP upload).")
    return
  let size = try: getFileSize(path) except CatchableError: -1'i64
  if size <= 0:
    t.systemLine("Cannot read " & path.extractFilename & ".")
    return
  var up = Up(t: t, path: path, sent: path)
  var mime = mimeOf(path)
  if t.secure and keys != nil and not t.room:
    # (an encrypted talk: the file locked before it goes; its key goes in the message)
    try:
      let (data, secret) = encryptFile(readFile(path))
      up.sent = dataPath("voice" / "upload-" & newId() & path.splitFile.ext)
      writeFile(up.sent, data)
      up.secret = secret
      mime = "application/octet-stream"
    except CatchableError as e:
      t.systemLine("Could not lock " & path.extractFilename & ": " & e.msg)
      return
  let id = askUpload(svc, path.extractFilename, getFileSize(up.sent), mime)
  uploads[id] = up
  t.systemLine(if recorded(path): "Sending the voice message..." else: "Sending " & path.extractFilename & "...")

proc uploadsDone() =
  var done: seq[(string, string, string)]
  withLock upLock:
    done = move upDone
    upDone = @[]
  for (id, plainUrl, err) in done:
    if not uploads.hasKey(id): continue
    let up = uploads[id]
    let (t, path) = (up.t, up.path)
    uploads.del id
    if up.sent != up.path:
      try: removeFile(up.sent) except CatchableError: discard
    # (an encrypted talk: the aesgcm:// address, its key after "#", goes inside the message)
    let url = if up.secret.len > 0: aesgcmUrl(plainUrl, up.secret) else: plainUrl
    if err.len > 0: t.systemLine("Could not send " & path.extractFilename & ": " & err)
    if err.len == 0 and isAudio(path):
      # (a voice message sent: kept here under its address, to play it back)
      try:
        if recorded(path): moveFile(path, voicePath(url)) else: copyFile(path, voicePath(url))
      except CatchableError: discard
    if err.len > 0: discard
    elif t.room: sendRoom(t.jid, url, url)
    elif up.secret.len > 0 and keys != nil:
      let mid = keys.omemoSend(t.jid, url)
      t.addLine Line(who: localOf(myJid), text: path.extractFilename, url: url, time: now12(), at: nowAt(),
                     mine: true, id: mid, locked: true)
    else:
      let mid = sendChat(t.jid, url, url)
      t.addLine Line(who: localOf(myJid), text: path.extractFilename, url: url, time: now12(), at: nowAt(),
                     mine: true, id: mid)

# ---- voice messages: recorded here, sent as a file; played when they come ------------------------

const MaxVoice = 300.0             ## seconds: a voice message ends by itself after five minutes

proc termuxMic(): bool = findExe("termux-microphone-record").len > 0

proc canRecord(): bool =
  ## A microphone this app can record from: Termux:API's (a phone), or
  ## PulseAudio's or ALSA's (Linux).
  when defined(android) or defined(ios) or defined(windows) or defined(macosx): false
  else: termuxMic() or findExe("parecord").len > 0 or findExe("arecord").len > 0

proc startRecording(t: Talk) =
  if not services.hasKey("upload"):
    t.systemLine("Your server takes no files (it has no HTTP upload): no voice messages.")
    return
  let stamp = now().format("yyyy-MM-dd' 'HH.mm.ss")
  try:
    if termuxMic():
      recFile = dataPath("voice" / "Voice " & stamp & ".m4a")
      discard execShellCmd("termux-microphone-record -f " & quoteShell(recFile) & " -e aac -l 0 >/dev/null 2>&1")
      recProc = nil
    else:
      recFile = dataPath("voice" / "Voice " & stamp & ".wav")
      recProc = if findExe("parecord").len > 0:
                  startProcess("parecord", args = ["--file-format=wav", recFile], options = {poUsePath})
                else: startProcess("arecord", args = ["-q", "-f", "cd", recFile], options = {poUsePath})
  except CatchableError as e:
    t.systemLine("Could not record: " & e.msg)
    return
  recTalk = t
  recStart = epochTime()

proc stopRecording(send: bool) =
  ## The recording ended: sent (a .m4a, as the other apps play it), or let go.
  let t = recTalk
  if t == nil: return
  recTalk = nil
  if termuxMic():
    discard execShellCmd("termux-microphone-record -q >/dev/null 2>&1")
    sleep(500)                     # (the file is finished by Termux:API's app)
  elif recProc != nil:
    when not defined(windows):
      discard posix.kill(Pid(recProc.processID), SIGINT)   # (it finishes the file)
    discard recProc.waitForExit(3000)
    recProc.close()
    recProc = nil
  var path = recFile
  if not send or epochTime() - recStart < 0.8:
    try: removeFile(path) except CatchableError: discard
    if send: t.systemLine("That was too short to send.")
    return
  if path.endsWith(".wav") and ffmpegExe().len > 0:
    # (WAV is big: AAC in an .m4a, which Conversations, Monal and the others play)
    let m4a = path.changeFileExt(".m4a")
    let code = execShellCmd(quoteShell(ffmpegExe()) & " -y -loglevel quiet -i " & quoteShell(path) &
                            " -ac 1 -c:a aac -b:a 48k " & quoteShell(m4a))
    if code == 0 and fileExists(m4a):
      try: removeFile(path) except CatchableError: discard
      path = m4a
  sendFile(t, path)

type FetchJob = object
  url, path: string
  open: bool                       ## a file to open once it is here (not a voice message to play)
  plainHttp: bool                  ## (a server of your own without TLS: aesgcm:// over http too)

var
  fetchLock: Lock
  fetchDone {.guard: fetchLock.}: seq[(string, string, bool)]   ## the address, what went wrong, to open
  fetching: Table[string, ref Thread[FetchJob]]

proc fetchNow(j: FetchJob) {.thread.} =
  var err = ""
  try:
    var r = HttpResponse()
    if j.plainHttp and j.url.isAesgcm:
      # (a server of your own, for trying: its files may be on plain http)
      r = httpRequest("GET", "http://" & fetchUrlOf(j.url)[8 .. ^1], timeoutSec = 10)
    if r.status == 0: r = httpRequest("GET", fetchUrlOf(j.url), timeoutSec = 60)
    if r.ok:
      # (a file of an encrypted talk: opened with the key in its address)
      {.cast(gcsafe).}:
        writeFile(j.path, if j.url.isAesgcm: decryptFile(j.url, r.body) else: r.body)
    else: err = "the server says " & $r.status
  except CatchableError as e: err = e.msg
  {.cast(gcsafe).}:
    withLock fetchLock: fetchDone.add (j.url, err, j.open)

proc fetchFile(url: string; open: bool) =
  if not fetching.hasKey(url):
    var th = new Thread[FetchJob]
    createThread(th[], fetchNow, FetchJob(url: url, path: voicePath(url), open: open, plainHttp: insecure))
    fetching[url] = th

proc openFile(url: string) =
  ## A file sent in a talk: an encrypted one fetched and opened here first;
  ## another opened where it is.
  if not url.isAesgcm: discard openUrl(url)
  elif fileExists(voicePath(url)): discard openUrl(voicePath(url))
  else: fetchFile(url, true)

proc stopPlaying() =
  if playId != NoSound: stopSound(playId)
  playId = NoSound
  if playProc != nil:
    try:
      playProc.terminate()
      discard playProc.waitForExit(1000)
      playProc.close()
    except CatchableError: discard
    playProc = nil
  if playing.len > 0 and termuxMic() and findExe("termux-media-player").len > 0:
    discard execShellCmd("termux-media-player stop >/dev/null 2>&1")
  playing = ""

proc playVoice(url: string) =
  ## A voice message: played from here once it is here (fetched first).
  stopPlaying()
  let path = voicePath(url)
  if not fileExists(path):
    fetchFile(url, false)
    playing = url
    return
  playing = url
  playId = playSound(path)
  if playId != NoSound: return
  # (where the system's sound cannot play it: a player that can)
  for (exe, args) in [("mpv", @["--no-video", "--really-quiet", path]),
                      ("ffplay", @["-nodisp", "-autoexit", "-loglevel", "quiet", path])]:
    if findExe(exe).len > 0:
      try:
        playProc = startProcess(exe, args = args, options = {poUsePath})
        return
      except CatchableError: discard
  if findExe("termux-media-player").len > 0:
    discard execShellCmd("termux-media-player play " & quoteShell(path) & " >/dev/null 2>&1")
    return
  playing = ""
  discard openUrl(path)

proc voiceTick() =
  ## Each frame: the fetched ones played, the ended ones let go.
  var done: seq[(string, string, bool)]
  withLock fetchLock:
    done = move fetchDone
    fetchDone = @[]
  for (url, err, open) in done:
    if fetching.hasKey(url):
      joinThread(fetching[url][])
      fetching.del url
    if open:
      if err.len > 0: said = "Could not get the file: " & err
      else: discard openUrl(voicePath(url))
    elif url == playing:
      if err.len > 0:
        playing = ""
        said = "Could not get the voice message: " & err
      else: playVoice(url)
  if playing.len > 0 and not fetching.hasKey(playing):
    if playProc != nil and not playProc.running:
      playProc.close()
      playProc = nil
      playing = ""
    elif playId != NoSound and not soundPlaying(playId):
      playId = NoSound
      playing = ""
  if recTalk != nil and epochTime() - recStart > MaxVoice: stopRecording(true)

# ---- what came ------------------------------------------------------------------------------------

proc noteArchived(aid: string) =
  ## The newest message's archive id: the next sign-on brings what came after it.
  if aid.len == 0: return
  conf["archiveLast"] = aid
  conf["archiveFor"] = address
  discard saveSettings(App, conf)

proc startSync() =
  ## What came since the last time (or, the first time on this device, in
  ## the last 30 days), from the server's archive, a page at a time.
  let last = if conf.getOrDefault("archiveFor", "") == address: conf.getOrDefault("archiveLast", "") else: ""
  liveLast = ""
  syncLast = ""
  syncing = if last.len > 0: askArchive(after = last, max = 100)
            else: askArchive(start = (now().utc - 30.days).format("yyyy-MM-dd'T'HH:mm:ss'Z'"), max = 100)

proc unlock(e: XmppEvent; l: var Line): bool =
  ## An encrypted message's words put in its line (false: it had none -- a
  ## message that only moves the keys on -- and shows nothing).
  if not isEncrypted(e): return true
  l.locked = true
  if keys == nil:
    l.text = "(An encrypted message: this device cannot read OMEMO.)"
    return true
  let (ok, words, why) = keys.omemoDecrypt(e)
  if ok and words.len == 0: return false
  if ok:
    l.text = words
    l.url = ""
    # (a file in an encrypted talk: its address alone, aesgcm://)
    if ' ' notin words and '\n' notin words and (words.isAesgcm or (words.startsWith("http") and isAudio(words))):
      l.url = words
      l.text = plainPath(words).extractFilename.decodeUrl
  else:
    l.text = "(An encrypted message this device cannot read: " & why & ".)"
  true

proc archivedLine(e: XmppEvent): Line =
  Line(who: (if e.mine: localOf(myJid) else: nameOf(e.jid)), text: e.text, url: e.url, mine: e.mine,
       at: atOf(e.stamp),
       time: stampTime(e.stamp), id: e.id, aid: e.archiveId, delivered: true)

proc alreadyHere(jid: string; l: Line): bool =
  ## The log has it: by its archive id, its id, or (lines kept before they
  ## had ids) its words.
  let s = seen(jid)
  (l.aid.len > 0 and ("a:" & l.aid) in s) or (l.id.len > 0 and ("i:" & l.id) in s) or keyOf(l) in s

proc buddy(jid: string): Buddy =
  result = buddies.getOrDefault(jid)
  if result == nil:
    result = Buddy(jid: jid, subscription: "none")
    buddies[jid] = result

proc takeEvents() =
  for e in xmppEvents():
    if keys != nil and keys.omemoHandle(e): continue      # (OMEMO's own answers)
    case e.kind
    of xeConnecting: said = e.text & "..."
    of xeOnline:
      signing = false
      retries = 0
      screen = scMain
      said = ""
      noteSent = myNote
      if myState == 3: goInvisible()
      askVcard("")
      play(doorOpen)
      # (this device's keys: published, and the friends' devices asked for)
      if omemoAvailable():
        try:
          if keys == nil or keys.account != bareJid(address).toLowerAscii:
            keys = omemoOpen(dataDir(App) / "keys", address)
          keys.omemoStart()
          for t in talks:
            if not t.room: keys.omemoRefresh(t.jid, force = true)
        except CatchableError as x:
          keys = nil
          said = "Encryption is off: " & x.msg
    of xeOffline:
      signing = false
      archiveOn = false
      syncing = ""
      earlier.clear()
      for t in talks: t.asking = ""
      if registering:
        registering = false
      elif screen == scMain:
        for b in buddies.values: b.shows.clear()
        if wantedOff or e.text.len == 0:
          screen = scSignOn
          said = "Signed off."
        else:
          said = "The connection was lost (" & e.text & "): trying again..."
          retryAt = epochTime() + float(min(120, 5 * (1 shl min(retries, 5))))
          inc retries
    of xeError:
      if e.id.len > 0 and uploads.hasKey(e.id):
        let up = uploads[e.id]
        uploads.del e.id
        up.t.systemLine("Could not send " & up.path.extractFilename & ": " & e.text)
      elif e.jid.len > 0:
        for t in talks:
          if t.jid == e.jid: t.systemLine(e.text)
      elif screen != scMain or signing or registering: said = e.text
      else: said = e.text
    of xeRegistered:
      registering = false
      screen = scDone
      said = ""
      qrPic = nil
      if savePassword: discard saveSecret(App, address, password)
      keep()
    of xeRoster:
      if not e.removed and e.contacts.len > 1 or (e.contacts.len == 1 and buddies.len == 0 and not e.removed):
        discard
      for c in e.contacts:
        if c.subscription == "remove":
          buddies.del c.jid
          continue
        let b = buddy(c.jid)
        b.name = c.name
        b.groups = c.groups
        b.subscription = c.subscription
        b.ask = c.ask
        if b.vcard.len == 0: askVcard(c.jid)
    of xePresence:
      if e.jid == bareJid(myJid): continue
      let b = buddy(e.jid)
      let wasOn = b.showOf != "unavailable"
      if e.show == "unavailable": b.shows.del e.resource
      else:
        b.shows[e.resource] = e.show
        b.status = e.text
      let isOn = b.showOf != "unavailable"
      if isOn and not wasOn: play(doorOpen)
      elif wasOn and not isOn: play(doorClose)
    of xeMessage:
      if (e.archiveId.len > 0 and ("a:" & e.archiveId) in seen(e.jid)) or
         (e.id.len > 0 and ("i:" & e.id) in seen(e.jid)):
        continue                   # (the archive brought it already)
      let when2 = if e.stamp.len > 0: stampTime(e.stamp) else: now12()
      var l = if e.carbon:
                Line(who: localOf(myJid), text: e.text, url: e.url, time: when2, mine: true, delivered: true,
                     id: e.id, aid: e.archiveId, at: atOf(e.stamp))
              else:
                Line(who: nameOf(e.jid), text: e.text, url: e.url, time: when2, id: e.id, aid: e.archiveId,
                     at: atOf(e.stamp))
      if not unlock(e, l): continue
      let t = talkWith(e.jid)
      t.win.open = true
      let b = buddies.getOrDefault(e.jid)
      if b != nil: b.typing = ""
      if e.archiveId.len > 0:
        if syncing.len > 0: liveLast = e.archiveId
        else: noteArchived(e.archiveId)
      t.addLine l
      if l.locked and not t.secure and e.jid notin plainFor: t.secure = keys != nil
      if not e.carbon:
        if not mdiIsActive(t.win): inc t.unread
        play(msgIn)
        discard notify(nameOf(e.jid), (if l.url.len > 0: "sent a file" else: l.text), app = "Retro Communicator",
                       tag = e.jid)
        # (away: the away message, once a conversation)
        if myState in [1, 2] and not t.autoReplied and awayMessage.len > 0:
          t.autoReplied = true
          discard (if t.secure and keys != nil: keys.omemoSend(e.jid, "Auto response: " & awayMessage)
                   else: sendChat(e.jid, "Auto response: " & awayMessage))
          t.systemLine("Your away message was sent.")
    of xeState:
      let b = buddies.getOrDefault(e.jid)
      if b != nil: b.typing = (if e.show == "composing": "typing" elif e.show == "paused": "stopped typing" else: "")
    of xeReceipt:
      for t in talks:
        if t.jid == e.jid:
          for l in t.lines.mitems:
            if l.id == e.id: l.delivered = true
    of xeAsk:
      var known = false
      for (j, _) in asks:
        if j == e.jid: known = true
      # (someone already let in: let them in again, quietly)
      let b = buddies.getOrDefault(e.jid)
      if b != nil and b.subscription in ["to", "both"] and not known: answerAsk(e.jid, true)
      elif not known:
        asks.add (e.jid, e.text)
        showAsks = true
        play(msgIn)
    of xeAnswer:
      let t = talkWith(e.jid, open = false)
      t.systemLine(nameOf(e.jid) & (if e.show == "subscribed": " added you back." else: " did not add you."))
    of xeVcard:
      if e.jid == bareJid(myJid) or e.jid == bareJid(address):
        myFields = e.fields
        myPhoto = photoOf(e.fields)
      else:
        let b = buddy(e.jid)
        b.vcard = e.fields
        b.photo = photoOf(e.fields)
    of xeRoomMessage:
      let t = talkWith(e.jid, room = true)
      let mine = e.resource == t.nick
      t.addLine Line(who: e.resource, text: e.text, url: e.url, mine: mine, at: atOf(e.stamp),
                     time: (if e.stamp.len > 0: "earlier" else: now12()))
      if not mine and not mdiIsActive(t.win): inc t.unread
    of xeRoomPresence:
      let t = talkWith(e.jid, room = true)
      if e.show == "unavailable":
        let k = t.occupants.find(e.resource)
        if k >= 0:
          t.occupants.delete(k)
          t.systemLine(e.resource & " left.")
      elif e.resource notin t.occupants:
        t.occupants.add e.resource
        t.occupants.sort(cmpIgnoreCase)
        if t.lines.len > 0: t.systemLine(e.resource & " came in.")
    of xeRoomSubject:
      talkWith(e.jid, room = true).subject = e.text
    of xeSlot:
      if uploads.hasKey(e.id):
        let up = uploads[e.id]
        var th = new Thread[UploadJob]
        createThread(th[], uploadNow, UploadJob(id: e.id, putUrl: e.putUrl, getUrl: e.url, path: up.sent,
                     mime: (if up.secret.len > 0: "application/octet-stream" else: mimeOf(up.path)),
                     headers: e.headers))
        upThreads.add th
    of xeStanza: discard
    of xeServices:
      for (k, v) in e.fields:
        services[k] = v
        if k == "archive" and not archiveOn:
          archiveOn = true
          startSync()
    of xeArchived:
      if e.resource == syncing:
        # (said while this device was off, from another one or to it)
        var l = archivedLine(e)
        if not alreadyHere(e.jid, l) and unlock(e, l):
          var open: Talk = nil
          for t in talks:
            if t.jid == e.jid: open = t
          if open != nil: open.addLine l
          else: logLine(e.jid, l)
      elif earlier.hasKey(e.resource):
        var l = archivedLine(e)
        if not alreadyHere(e.jid, l) and unlock(e, l): earlier[e.resource].add l
    of xeArchiveDone:
      if e.id == syncing:
        if e.text.len > 0: syncLast = e.text
        if e.show != "complete" and e.text.len > 0:
          liveLast = ""
          syncing = askArchive(after = e.text, max = 100)
        else:
          syncing = ""
          noteArchived(if liveLast.len > 0: liveLast else: syncLast)
      elif earlier.hasKey(e.id):
        let got = earlier[e.id]
        earlier.del e.id
        for t in talks:
          if t.asking == e.id:
            t.asking = ""
            if e.show == "complete" or got.len == 0: t.archiveEnd = true
            if got.len > 0:
              logEarlier(t.jid, got)
              t.lines = got & t.lines

proc keysTick() =
  ## What OMEMO says: a message that could not go, a friend's devices known.
  if keys == nil: return
  for n in keys.omemoNotes():
    case n.kind
    of onSent: discard
    of onFailed:
      for t in talks:
        if t.jid == n.jid:
          for l in t.lines.mitems:
            if l.id == n.id: l.failed = true
          t.systemLine("Not sent: " & n.text & ". The lock button off sends it unencrypted.")
    of onDevices:
      for t in talks:
        if t.jid == n.jid and not t.room and n.jid notin plainFor and keys.omemoKnows(n.jid): t.secure = true
    of onError:
      var told = false
      for t in talks:
        if t.jid == n.jid:
          t.systemLine(n.text)
          told = true
      if not told: said = n.text

# ---- the screens ---------------------------------------------------------------------------------

proc band(title, sub: string; tall = false) =
  let h = if tall: 104 else: 50
  let r = place(0, dp(h), fill = true)
  fill(r, brand)
  let s = if tall: 3.4 else: 2.0
  let iw = textWidth(nfComments, style(size = s))
  let ix = r.x + dp(12)
  text(ix, r.y + (r.h - int(float(FontH) * s)) div 2, nfComments, color(255, 255, 255), style(size = s))
  let tx = ix + iw + dp(10)
  let ts = if tall: 1.55 else: 1.25
  let th = int(float(FontH) * ts) + (if sub.len > 0: FontH + dp(2) else: 0)
  let ty = r.y + (r.h - th) div 2
  text(tx, ty, title, color(255, 255, 255), style(bold = true, size = ts))
  if sub.len > 0: text(tx, ty + int(float(FontH) * ts) + dp(2), sub, brandSoft, style())

proc note(glyph, s: string; c = good) = iconLabel(glyph, s, color = c, iconColor = c)

proc saidLine() =
  if said.len > 0:
    let bad = not said.endsWith("...") and said != "Signed off."
    iconLabel((if bad: pxWarning else: pxInfo), said, color = (if bad: color(170, 60, 0) else: idle))

proc welcome() =
  band("Retro Communicator", "Talk to your friends, the 1999 way", tall = true)
  space(10)
  heading("Welcome", 2)
  label("Chat with your friends one to one or in rooms, see who is online, set an away message.")
  space(6)
  if button("&Create a new account", isDefault = true, w = dp(270)):
    screen = scCreate
    said = ""
  space(2)
  if button("I &already have an account", w = dp(270)):
    screen = scSignOn
    said = ""
  space(10)
  note(nfCheck, "Free -- no email, no phone number")
  note(nfCheck, "Talks with any XMPP (Jabber) app")
  note(nfCheck, "Your history stays on your device")

proc signOnBox() =
  band("Sign On", "Your address and your password")
  space(6)
  form(64):
    field("&Address:"): edit(address)
    field("&Password:"): edit(password, password = true)
  checkbox("&Save password", savePassword)
  checkbox("Sign on a&utomatically", autoSignOn)
  checkbox("Accept the server's own certificate (a server of yours)", insecure)
  space(4)
  saidLine()
  row:
    if button("< &Back", w = 70, enabled = not signing): screen = scWelcome
    spring()
    if signing:
      if button("Cancel", w = 90): signOff()
    elif button("Sign &On", isDefault = true, w = 90): signOn()
  if signing: wakeIn(200)

proc createBox() =
  band("Create your account", "A screen name, a password, a server")
  space(6)
  form(96):
    field("Screen &name:"): edit(newName)
    field("&Password:"): edit(newPassword, password = not showPassword)
    field("A&gain:"): edit(newPassword2, password = not showPassword)
    field(""): checkbox("&Show the password", showPassword)
    field("Ser&ver:"): comboEdit(server, Servers)
  if newName.len > 0 and server.len > 0:
    note(nfAt, "Your address: " & newName.strip.toLowerAscii & "@" & server.strip, idle)
  iconLabel(pxWarning, "Keep your password safe: it cannot be reset.", color = color(150, 80, 0))
  label("Some servers make accounts only on their web site: then make it there, and sign on.",
        enabled = false)
  space(4)
  saidLine()
  row:
    if button("< &Back", w = 80, enabled = not registering): screen = scWelcome
    spring()
    if button("&Create Account", isDefault = true, w = 130, enabled = not registering): createAccount()
  if registering: wakeIn(200)

proc addMeCode(size = 3) =
  if qrPic.isNil:
    qrPic = qrBitmap(qrEncode("xmpp:" & bareJid(address) & "?roster"), scale = size, border = 2)
  row:
    space(max(0, (ui.w - qrPic.w) div 2 - dp(12)))
    drawBitmap(place(qrPic.w, qrPic.h), qrPic)

proc doneBox() =
  band("You are in!", "Your account is made")
  space(8)
  label(bareJid(address), bold = true)
  label("Give this address to your friends -- or let them scan it:", color = idle)
  space(4)
  addMeCode()
  space(6)
  if button("Sign &On now", isDefault = true, w = dp(270)): signOn()
  saidLine()
  if signing: wakeIn(200)

proc friendRow(b: Buddy) =
  let sh = b.showOf
  withId(b.jid):
    let r = place(0, max(dp(30), lineHeight() * 2 + dp(4)), fill = true)
    let hit = interact(idOf("buddy:" & b.jid), r, focusable = false)
    if selected == b.jid: fill(r, ui.theme.select)
    let ink = if selected == b.jid: ui.theme.selectText elif sh == "unavailable": idle else: ui.theme.text
    let s = dp(26)
    if b.photo != nil: drawBitmap(rect(r.x + dp(4), r.y + (r.h - s) div 2, s, s), b.photo)
    else:
      disc(float(r.x + dp(4) + s div 2), float(r.y + r.h div 2), float(s) / 2, stateColor(sh))
      let nm = nameOf(b.jid)
      let ini = if nm.len > 0: $nm.runeAt(0).toUpper else: "?"
      text(r.x + dp(4) + (s - textWidth(ini, true)) div 2, r.y + (r.h - lineHeight()) div 2, ini,
           color(255, 255, 255), true)
    let tx = r.x + s + dp(10)
    text(tx, r.y + dp(2), nameOf(b.jid) & (if b.ask: "  (waiting)" else: ""), ink, sh != "unavailable")
    let sub = if b.typing.len > 0: b.typing elif b.status.len > 0: b.status else: stateName(sh)
    text(tx, r.y + dp(2) + lineHeight(), sub, (if selected == b.jid: ui.theme.selectText else: idle))
    disc(float(r.x + r.w - dp(12)), float(r.y + r.h div 2), float(dp(4)), stateColor(sh))
    if hit.clicked or (hit.hover and ui.pressed):
      selected = b.jid
    if hit.hover and ui.pressed and ui.clicks >= 2 or (hit.clicked and (fingers() or isMobile())):
      let t = talkWith(b.jid)
      t.win.open = true
      t.unread = 0
      mdiActivate(t.win)
    if hit.hover and ui.rpressed:
      selected = b.jid
      openPopupMenu("buddy", ui.mx, ui.my)

proc groupedBuddies(): seq[(string, seq[Buddy])] =
  var groups: OrderedTable[string, seq[Buddy]]
  var offline: seq[Buddy]
  let f = find.strip.toLowerAscii
  for b in buddies.values:
    if f.len > 0 and f notin nameOf(b.jid).toLowerAscii and f notin b.jid: continue
    if b.showOf == "unavailable":
      offline.add b
      continue
    let g = if b.groups.len > 0: b.groups[0] else: "Friends"
    groups.mgetOrPut(g, @[]).add b
  for g, list in groups.mpairs:
    list.sort(proc (a, b: Buddy): int = cmpIgnoreCase(nameOf(a.jid), nameOf(b.jid)))
    result.add (g, list)
  result.sort(proc (a, b: (string, seq[Buddy])): int = cmpIgnoreCase(a[0], b[0]))
  offline.sort(proc (a, b: Buddy): int = cmpIgnoreCase(nameOf(a.jid), nameOf(b.jid)))
  result.add ("Offline", offline)

proc setMyPresence() =
  if myState == 3: goInvisible()
  else: setPresence(Shows[myState], myNote)
  noteSent = myNote
  keep()

proc friendsList() =
  # (the name takes what the picture and the state leave: a long address
  # must not push the state off the window)
  row([40, -1, 0]):
    picture(localOf(address), myPhoto, dp(40))
    col:
      label(localOf(address), bold = true)
      label(bareJid(address), color = idle)
    if combo(States, myState, w = dp(100)): setMyPresence()
  if edit(myNote): noteAt = epochTime()
  if myNote != noteSent and epochTime() - noteAt > 1.2 and xmppRunning(): setMyPresence()
  searchBox(find, "Find a friend")
  panel(max(dp(80), remainingH() - CtrlH - 2 * Gap)):
    for (g, list) in groupedBuddies():
      let closed = g in closedGroups
      let on = if g == "Offline": list.len else: list.len
      withId(g):
        if link((if closed: "+ " else: "- ") & g & "  (" & $on & ")"):
          if closed: closedGroups.delete(closedGroups.find(g)) else: closedGroups.add g
          keep()
      if not closed:
        for b in list: friendRow(b)
    if buddies.len == 0:
      label("No friends yet: Add one (People > Add a Friend).", enabled = false)
  popupMenu("buddy"):
    if menuItem("&Talk"):
      let t = talkWith(selected)
      t.win.open = true
      mdiActivate(t.win)
    if menuItem("&Info"):
      infoJid = selected
      askVcard(selected)
      showInfo = true
    if menuItem("Re&name / Group..."):
      let b = buddies.getOrDefault(selected)
      if b != nil:
        renameName = nameOf(selected)
        renameGroup = (if b.groups.len > 0: b.groups[0] else: "")
        showRename = true
    menuSeparator()
    if menuItem("&Remove"): showRemove = true
  row:
    if button("&Talk", w = 54, enabled = selected.len > 0):
      let t = talkWith(selected)
      t.win.open = true
      mdiActivate(t.win)
    if button("&Room", w = 54):
      roomNick = localOf(address)
      if roomJid.len == 0 and services.hasKey("rooms"): roomJid = "lounge@" & services["rooms"]
      showRoom = true
    if button("A&dd", w = 54):
      addJid = ""
      addName = ""
      showAdd = true
    if button("A&way", w = 54): showAway = true

proc conversation(t: Talk) =
  let b = buddies.getOrDefault(t.jid)
  # (who it is takes what the picture and the buttons leave: a long name
  # or a room's address must not push the buttons off the window)
  row(if t.room: @[36, -1, 0, 0] else: @[36, -1, 0, 0, 0, 0]):
    if t.room:
      icon(nfComments, brand, 1.4)
      col:
        label(t.jid, bold = true)
        label(if t.subject.len > 0: t.subject else: $t.occupants.len & " here", color = idle)
    else:
      picture(nameOf(t.jid), (if b != nil: b.photo else: nil), dp(36))
      col:
        label(nameOf(t.jid), bold = true)
        let sh = if b != nil: b.showOf else: "unavailable"
        label(if b != nil and b.status.len > 0: b.status else: stateName(sh), color = stateColor(sh))
    if not t.room and toolButton(if t.secure: nfLock else: nfUnlock,
                                 (if t.secure: "Encrypted (OMEMO): click to send unencrypted"
                                  else: "Not encrypted: click to encrypt (OMEMO)"),
                                 down = t.secure, enabled = keys != nil):
      if t.secure:
        t.secure = false
        if t.jid notin plainFor: plainFor.add t.jid
        keep()
        t.systemLine("Messages to " & nameOf(t.jid) & " go unencrypted now: the server can read them.")
      else:
        plainFor.keepItIf(it != t.jid)
        keep()
        if keys.omemoKnows(t.jid):
          t.secure = true
          t.systemLine("Messages to " & nameOf(t.jid) & " go encrypted now (OMEMO).")
        else:
          keys.omemoRefresh(t.jid, force = true)
          t.systemLine("No device of " & nameOf(t.jid) & " with OMEMO is known yet: asking their server; " &
                       "encryption turns on when one is found.")
    if toolButton(nfMicrophone, (if recTalk == t: "Stop and send" else: "Voice message"),
                  down = recTalk == t, enabled = canRecord() and (recTalk == nil or recTalk == t)):
      if recTalk == t: stopRecording(true)
      else: startRecording(t)
    if toolButton(nfPaperclip, "Send a file"):
      sendTo = t
      sendPath = getHomeDir()
      showSendFile = true
    if not t.room and toolButton(nfUser, "Info"):
      infoJid = t.jid
      askVcard(t.jid)
      showInfo = true
  let listH = max(dp(80), remainingH() - EditH - CtrlH - 3 * Gap - lineHeight())
  proc transcript(t: Talk; h: int) =
    beginPanel(h, key = "talk" & t.jid)
    if archiveOn and not t.room and not t.archiveEnd:
      # (the server's archive: what was said before the first line here)
      if t.asking.len > 0: label("Asking the server...", color = idle)
      elif link("Earlier messages"):
        var before = ""
        for l in t.lines:
          if l.aid.len > 0 and before.len == 0: before = l.aid
        t.asking = if before.len > 0: askArchive(with = t.jid, before = before, max = 50)
                   else: askArchive(with = t.jid, latest = true, max = 50)
        earlier[t.asking] = @[]
    # (only the lines in view are drawn: a long talk costs what is on the
    # screen, and typing in the box below stays quick)
    for i in visibleRows(t.lines.len, key = "lines" & t.jid, varying = true):
      let l = t.lines[i]
      withId(i):
        if l.system:
          label(l.text, color = idle, literal = true)
        else:
          row:
            label(l.who, bold = true, color = (if l.mine: me else: them), literal = true)
            label(l.time, color = idle)
            if l.locked: label(nfLock, color = (if l.failed: busyC else: good), literal = true)
            if l.url.len == 0: label(l.text & (if l.failed: "   (not sent)" else: ""), literal = true,
                                     color = (if l.failed: busyC else: Color()))
          if l.url.len > 0 and isAudio(l.url):
            row:
              space(16)
              let now = playing == l.url
              let shown = if now and fetching.hasKey(l.url): nfMicrophone & "  Voice message   Getting it..."
                          elif now: nfStop & "  Voice message   Stop"
                          else: nfPlay & "  Voice message   Play"
              if link(shown):
                if now: stopPlaying() else: playVoice(l.url)
          elif l.url.len > 0:
            row:
              space(16)
              let getting = fetching.hasKey(l.url)
              if link(nfPaperclip & " " & (if l.text != l.url: l.text else: l.url.extractFilename) &
                      (if getting: "   Getting it..." else: "   Open")) and not getting:
                openFile(l.url)
    if not t.room and t.lines.len > 0 and t.lines[^1].mine and t.lines[^1].delivered:
      label("Delivered", color = idle)
    let bottom = place(0, 1, fill = true)
    if t.stick:
      revealInPanel(bottom, glide = false)
      # (the lines at the bottom are measured as they are drawn: down there
      # once more while their heights come in, so it ends at the bottom)
      inc t.stuck
      if not ui.redraw or t.stuck >= 4:
        t.stick = false
        t.stuck = 0
    endPanel()
  if t.room:
    # (the talk, and beside it who is in the room)
    row([-1, 130]):
      col:
        transcript(t, listH)
      col:
        label("In the room", bold = true)
        beginPanel(max(dp(40), listH - lineHeight() - Gap), key = "who" & t.jid)
        for o in t.occupants: label(o, literal = true)
        endPanel()
  else:
    transcript(t, listH)
  if recTalk == t:
    let secs = int(epochTime() - recStart)
    row:
      label(nfCircle & "  Recording " & $(secs div 60) & ":" & align($(secs mod 60), 2, '0') &
            "   (the microphone button again sends it)", color = busyC, literal = true)
      spring()
      if link("Cancel"): stopRecording(false)
    wakeIn(250)
  else:
    label(if b != nil and b.typing.len > 0: nameOf(t.jid) & " is " & b.typing & "..." else: " ", color = idle)
  row([-1, 70]):
    if edit(t.draft):
      t.lastKey = epochTime()
      if not t.room and not t.composing and t.draft.len > 0 and xmppRunning():
        t.composing = true
        sendState(t.jid, "composing")
    let enter = ui.key == KeyEnter and ui.lastId != 0
    if button("&Send", isDefault = true) or (enter and t.draft.len > 0 and mdiIsActive(t.win)): send(t)
  if t.composing and epochTime() - t.lastKey > 5:
    t.composing = false
    if xmppRunning(): sendState(t.jid, "paused")
  if mdiIsActive(t.win): t.unread = 0

proc dialogs() =
  if showAdd:
    dialog(showAdd, "Add a Friend", 400):
      form 0:
        field "&Address:": edit addJid
        field "&Name:": edit addName
        field "&Group:": edit addGroup
      label("They are asked to let you see when they are online.", enabled = false)
      row:
        spring()
        if button("OK", isDefault = true, enabled = '@' in addJid):
          addContact(addJid.strip.toLowerAscii, addName.strip,
                     (if addGroup.strip.len > 0: @[addGroup.strip] else: @[]))
          showAdd = false
        if button("Cancel"): showAdd = false
  if showAsks and asks.len > 0:
    let (jid, nick) = asks[0]
    dialog(showAsks, "Someone Wants to Add You", 420):
      label((if nick.len > 0: nick & " (" & jid & ")" else: jid), bold = true, literal = true)
      label("wants to add you to their friends.")
      row:
        spring()
        if button("&Accept and Add Back", isDefault = true):
          answerAsk(jid, true)
          if not buddies.hasKey(jid): addContact(jid, nick)
          asks.delete(0)
        if button("&Deny"):
          answerAsk(jid, false)
          asks.delete(0)
    if asks.len == 0: showAsks = false
  if showInfo:
    let b = buddies.getOrDefault(infoJid)
    dialog(showInfo, "Info: " & nameOf(infoJid), 420):
      row:
        picture(nameOf(infoJid), (if b != nil: b.photo else: nil), dp(64))
        space(6)
        col:
          label(nameOf(infoJid), bold = true)
          label(infoJid, color = idle)
          if b != nil: label(stateName(b.showOf) & (if b.status.len > 0: ": " & b.status else: ""))
      if b != nil:
        for (k, v) in b.vcard:
          if k notin ["PHOTO", "TYPE"] and v.len > 0:
            row:
              label(case k
                    of "FN": "Name:"
                    of "NICKNAME": "Nickname:"
                    of "DESC": "About:"
                    of "URL": "Web:"
                    of "BDAY": "Birthday:"
                    else: k & ":", bold = true)
              label(v, literal = true)
        label("Sees you: " & (if b.subscription in ["from", "both"]: "yes" else: "no") &
              "    You see them: " & (if b.subscription in ["to", "both"]: "yes" else: "no"), color = idle)
      if keys != nil:
        # (their devices' fingerprints: compare them with what their app shows)
        label(nfLock & "  Encryption (OMEMO): their devices", bold = true, literal = true)
        let devs = keys.omemoDevices(infoJid)
        if devs.len == 0: label("None known: their app may not have OMEMO.", color = idle)
        for i, d in devs:
          withId("dev" & $d.id):
            let fp = d.fingerprint
            let c = if d.trust == tDistrusted: busyC elif d.trust == tVerified: good else: Color()
            if fp.len > 0:
              # (in two lines of four groups, as the other apps show it)
              styledText(fp[0 ..< 35], style(mono = true), color = c)
              styledText(fp[36 .. ^1] & (if d.active: "" else: "   (gone)"), style(mono = true), color = c)
            else: label("Device " & $d.id & " (no key seen yet)", color = c)
            row:
              label(case d.trust
                    of tVerified: "Verified"
                    of tDistrusted: "Not trusted: gets no messages"
                    of tUndecided: "Trusted until you verify one of theirs", color = idle)
              spring()
              if d.trust != tVerified and fp.len > 0 and button("&Verified", w = 80):
                keys.omemoTrust(infoJid, d.id, tVerified)
              if d.trust != tDistrusted and button("&Don't Trust", w = 96):
                keys.omemoTrust(infoJid, d.id, tDistrusted)
        label("Yours:", color = idle)
        styledText(keys.omemoFingerprint[0 ..< 35], style(mono = true), color = idle)
        styledText(keys.omemoFingerprint[36 .. ^1], style(mono = true), color = idle)
      row:
        spring()
        if button("OK", isDefault = true): showInfo = false
  if showRename:
    dialog(showRename, "Rename", 360):
      form 0:
        field "&Name:": edit renameName
        field "&Group:": edit renameGroup
      row:
        spring()
        if button("OK", isDefault = true):
          changeContact(selected, renameName.strip, (if renameGroup.strip.len > 0: @[renameGroup.strip] else: @[]))
          showRename = false
        if button("Cancel"): showRename = false
  if showRemove:
    if msgBox(showRemove, "Remove", "Remove " & nameOf(selected) & " from your friends?",
              ["&Remove", "Cancel"], miQuestion) == 1:
      removeContact(selected)
      selected = ""
  if showAway:
    dialog(showAway, "Away Message", 420):
      label("Sent once to each friend who writes while you are away or busy:")
      editArea(awayMessage, lines = 3)
      row:
        spring()
        if button("&I'm Away", isDefault = true):
          myState = 1
          for t in talks: t.autoReplied = false
          setMyPresence()
          showAway = false
        if button("OK"):
          keep()
          showAway = false
  if showRoom:
    dialog(showRoom, "Join a Chat Room", 420):
      form 0:
        field "&Room:": edit roomJid
        field "&Your name:": edit roomNick
      if services.hasKey("rooms"):
        label("Rooms on your server: name@" & services["rooms"], enabled = false)
      row:
        spring()
        if button("&Join", isDefault = true, enabled = '@' in roomJid and roomNick.len > 0):
          let t = talkWith(roomJid.strip.toLowerAscii, room = true)
          t.nick = roomNick.strip
          t.win.open = true
          joinRoom(t.jid, t.nick)
          showRoom = false
        if button("Cancel"): showRoom = false
  if showProfile:
    dialog(showProfile, "My Profile", 440):
      row:
        picture(localOf(address), myPhoto, dp(64))
        space(6)
        col:
          if button("&Picture..."): profilePhoto = getHomeDir()
          label("PNG or JPEG, small", enabled = false)
      form 0:
        field "&Name:": edit profileName
        field "&About:": edit profileAbout
      addMeCode(2)
      label("Friends scan this to add you", color = idle)
      if keys != nil:
        label(nfLock & "  This device's fingerprint (OMEMO):", bold = true, literal = true)
        styledText(keys.omemoFingerprint[0 ..< 35], style(mono = true))
        styledText(keys.omemoFingerprint[36 .. ^1], style(mono = true))
        label("Friends compare it with what their app shows for you.", color = idle)
      row:
        spring()
        if button("OK", isDefault = true):
          var fs = @[("FN", profileName), ("NICKNAME", profileName), ("DESC", profileAbout)]
          for (k, v) in myFields:
            if k in ["PHOTO", "TYPE"]: fs.add (k, v)
          setVcard(fs)
          myFields = fs
          showProfile = false
        if button("Cancel"): showProfile = false
    if profilePhoto.len > 0:
      var open = true
      if fileDialog(open, profilePhoto, fmOpen, ["Pictures (*.png;*.jpg;*.jpeg)"]):
        try:
          let data = readFile(profilePhoto)
          if data.len > 200_000:
            said = "That picture is too big (200 KB at most)."
          else:
            var fs: seq[(string, string)]
            for (k, v) in myFields:
              if k notin ["PHOTO", "TYPE"]: fs.add (k, v)
            fs.add ("PHOTO", encode(data))
            fs.add ("TYPE", (if profilePhoto.toLowerAscii.endsWith(".png"): "image/png" else: "image/jpeg"))
            myFields = fs
            myPhoto = photoOf(fs)
        except CatchableError: discard
        profilePhoto = ""
      elif not open: profilePhoto = ""
  if showSendFile and sendTo != nil:
    if fileDialog(showSendFile, sendPath, fmOpen, ["All Files (*.*)"], title = "Send a File"):
      sendFile(sendTo, sendPath)
  aboutBox(showAbout, "Retro Communicator", "1.3.1",
           ["An instant messenger on XMPP: any public server, any XMPP app.",
            "Developed by Sultan Al Isaiee @foxoman"])

proc mainScreen() =
  menubar:
    menu "&Communicator":
      if menuItem("My &Profile..."):
        profileName = ""
        profileAbout = ""
        for (k, v) in myFields:
          if k == "FN": profileName = v
          if k == "DESC": profileAbout = v
        showProfile = true
      if menuItem("&Away Message..."): showAway = true
      if menuItem("&Sounds", checked = soundsOn):
        soundsOn = not soundsOn
        keep()
      menuSeparator()
      if menuItem("Sign &Off"): signOff()
      if menuItem("E&xit", "Alt+F4"): quitApp()
    menu "&People":
      if menuItem("&Add a Friend..."):
        addJid = ""
        addName = ""
        showAdd = true
      if menuItem("&Join a Chat Room..."):
        roomNick = localOf(address)
        showRoom = true
      if menuItem("&Requests (" & $asks.len & ")", enabled = asks.len > 0): showAsks = true
    menu "&Window":
      if menuItem("&Friends"):
        friendsWin.open = true
        mdiActivate(friendsWin)
      menuSeparator()
      mdiWindowMenu()
    menu "&Help":
      if menuItem("&About Retro Communicator..."): showAbout = true
  if not friendsSized:
    let area = mdiAreaRect()
    if area.w > 0:
      friendsSized = true
      friendsWin.r = rect(dp(8), dp(8), max(dp(200), min(dp(280), area.w - dp(16))),
                          max(dp(240), min(dp(460), area.h - dp(48))))   # (its title bar too)
  mdiArea(-1 - lineHeight() - dp(8)):
    mdiWindow(friendsWin):
      friendsList()
    for t in talks:
      if not t.win.open: continue
      t.win.title = (if t.room: t.jid else: nameOf(t.jid)) & (if t.unread > 0: "  (" & $t.unread & ")" else: "")
      withId(t.jid):
        mdiWindow(t.win):
          conversation(t)
      if not t.win.open and t.room: leaveRoom(t.jid, t.nick)
  var open = 0
  for t in talks:
    if t.win.open: inc open
  statusbar((if xmppRunning() and said.len == 0: "Online as " & localOf(address) & " -- " & States[myState]
             else: said), $open & " conversation" & (if open == 1: "" else: "s"))

# ---- the start ----------------------------------------------------------------------------------

conf = loadSettings(App)
address = conf.getOrDefault("address", "")
server = conf.getOrDefault("server", Servers[0])
savePassword = conf.getOrDefault("savePassword", "1") == "1"
autoSignOn = conf.getOrDefault("autoSignOn", "0") == "1"
try: myState = clamp(parseInt(conf.getOrDefault("state", "0")), 0, 3) except ValueError: discard
myNote = conf.getOrDefault("note", "")
awayMessage = conf.getOrDefault("away", awayMessage)
soundsOn = conf.getOrDefault("sounds", "1") == "1"
closedGroups = conf.getOrDefault("closed", "Offline").split('\t')
plainFor = conf.getOrDefault("plain", "").split('\t')
initLock(upLock)
initLock(fetchLock)
addExitProc(proc () =
  stopRecording(false)            # (no microphone left recording)
  stopPlaying())
makeSounds()
if address.len > 0:
  password = loadSecret(App, address)
  screen = scSignOn
  if autoSignOn and password.len > 0: signOn()

app "Retro Communicator", 760, 520:
  takeEvents()
  keysTick()
  uploadsDone()
  voiceTick()
  # (the connection lost: tried again, more slowly each time)
  if retryAt > 0 and epochTime() >= retryAt and not xmppRunning():
    retryAt = 0
    signing = true
    xmppStart(address, password, insecure = insecure, show = Shows[myState], status = myNote)
  if xmppRunning() or retryAt > 0 or uploads.len > 0 or playing.len > 0: wakeIn(250)
  case screen
  of scWelcome: welcome()
  of scSignOn: signOnBox()
  of scCreate: createBox()
  of scDone: doneBox()
  of scMain: mainScreen()
  dialogs()
