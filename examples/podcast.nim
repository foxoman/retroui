## Retro Podcast: a podcast player for every system Retro Nim UI runs on --
## Windows, macOS, Linux, Android, iOS and web pages. Find shows by name
## (Apple's podcast directory), follow their feeds (RSS, Atom), import and
## export OPML, play at any speed from where you left off, download for
## the road, a queue, a sleep timer, the system's media controls, the
## sound playing on in the background (an Android phone's notification,
## iOS's background audio), and an icon in the tray on a desktop.
##
## Built from the kit's parts: `retroui/feeds` (RSS, Atom, OPML),
## `retroui/jobs` (feeds, searches and downloads on worker threads),
## `audioView` (speed, seekVideo, playVideo), `pageView` and `listDetail`
## (one column on a phone, two on a desktop), `UndoStack` (Unfollow is
## undone), `mediasession` and `retroui/tray`.
##
##   nim c -d:release examples/podcast.nim
##
## In a web page (`retrokit web examples/podcast.nim`) the browser asks a
## feed's site to allow the page (CORS); most podcast hosts do not, so
## Settings has a proxy put before each feed's address.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, json, tables, strutils]
import retroui
import retroui/[jobs, tray, mediasession]
from retroui/system import sharedIn
import podcast/library

const
  PodcastVersion = "1.1.0"
  IconPng = staticRead("assets/podcast-icon.png")
  PlayerKey = "podcast-player"
  Speeds = [0.75, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
  SleepNames = ["Off", "15 minutes", "30 minutes", "45 minutes", "1 hour", "End of the episode"]
  SleepMinutes = [0, 15, 30, 45, 60, -1]

type Found = object
  title, author, feed, art: string

var
  lib = load()
  history: UndoStack         # (Edit, Undo: an Unfollow, a Mark Played, the queue's changes)
  nav = initPages("home")
  section = 0                   # Library, Queue, Downloads, Find
  showSel = 0
  epSel = 0
  queueSel = 0
  dlSel = 0
  foundSel = 0
  showOpen = false           # (a phone: the show's episodes over the list)
  addUrl = ""
  query = ""
  found: seq[Found]
  searching: Job[seq[Found]]
  refreshing: Table[string, Job[Feed]]     # by the feed's address
  downloading: Table[string, Job[string]]  # by the episode's sound address
  fetchingArt: Table[string, Job[string]]  # by the picture's address
  status = "Ready"
  sleepIdx = 0
  sleepAt = 0                # (ui.now when the sleep timer pauses; 0 none)
  lastPos, lastDur = 0
  lastPlaying = false
  lastError = ""
  dirty = false
  savedAt = 0
  addOpen, aboutOpen, lookOpen, settingsOpen = false
  importOpen, exportOpen = false
  opmlPath = ""
  lastSection = 0
  epTab = 0                    # (the episode page's tab: Notes, Chapters, Transcript)
  startedUp = false            # (the first frame: the feeds read again, if Settings says so)
  chapterSel = 0
  extras: Table[string, string]            # chapters and transcripts fetched, by address
  fetchingExtra: Table[string, Job[string]]
  savedRevision = 0            # (history.revision when the library was saved)
  wasAdding = false
  epCols = @[Column(title: "Episode", width: 300), Column(title: "Date", width: 96),
             Column(title: "Length", width: 64), progressColumn("Played", 70),
             iconColumn("", 26)]

# ---- the network: feeds, the directory, downloads, pictures (jobs) ----------------------------------

proc proxied(): string =
  when defined(wasm): lib.proxy else: ""

proc refresh(url: string) =
  ## Reads the show's feed again (on a worker).
  if url in refreshing and not refreshing[url].ended: return
  let proxy = proxied()
  refreshing[url] = job(proc (): Feed = readFeedAt(url, proxy))

proc refreshAll() =
  for s in lib.shows: refresh(s.url)
  status = "Checking " & $lib.shows.len & " shows for new episodes..."

proc follow(url: string) =
  ## Follows the show whose feed is at `url` (its episodes come with the feed).
  let u = url.strip
  if u.len == 0: return
  if lib.showOf(u) < 0:
    lib.shows.add Show(url: u, title: u)
    dirty = true
  showSel = lib.showOf(u)
  refresh(u)
  status = "Reading " & u & "..."

proc search(q: string; directory: int) =
  ## Asks a directory for shows: Apple's podcast directory, or fyyd (an
  ## open one, of the shows' own feeds).
  let proxy = proxied()
  let term = q.strip
  if term.len == 0: return
  searching = job(proc (): seq[Found] =
    let url = if directory == 1: "https://api.fyyd.de/0.2/search/podcast?count=40&title=" & urlEncode(term)
              else: "https://itunes.apple.com/search?media=podcast&limit=40&term=" & urlEncode(term)
    let r = httpRequest("GET", proxy & url, timeoutSec = 30)
    if not r.ok:
      raise newException(IOError, if r.status == 0: r.error else: "the directory answered " & $r.status)
    let j = parseJson(r.body)
    if directory == 1:
      for it in j{"data"}:
        if it{"xmlURL"}.getStr.len > 0:
          result.add Found(title: it{"title"}.getStr, author: it{"author"}.getStr,
                           feed: it{"xmlURL"}.getStr, art: it{"imgURL"}.getStr)
    else:
      for it in j{"results"}:
        if it{"feedUrl"}.getStr.len > 0:
          result.add Found(title: it{"collectionName"}.getStr, author: it{"artistName"}.getStr,
                           feed: it{"feedUrl"}.getStr, art: it{"artworkUrl100"}.getStr))

proc download(audio, mime: string) =
  ## The episode to the disk, on a worker (straight to its file: not through
  ## memory).
  if audio in downloading and not downloading[audio].ended: return
  downloading[audio] = jobs.download(audio, fileFor(audio, mime),
                                     {"User-Agent": "RetroPodcast/" & PodcastVersion})
  status = "Downloading..."

proc downloadPart(e: Episode): float =
  ## (how far its download is: the bytes there of those the feed said; -1
  ## when the feed did not say)
  if e.bytes <= 0: -1.0
  else: clamp(downloadedSoFar(fileFor(e.audio, e.mime)).float / e.bytes.float, 0.0, 1.0)

proc artOf(url: string): string =
  ## The show's picture as a file ("" until it is fetched).
  if url.len == 0: return ""
  if url.startsWith("file://"): return url[7 .. ^1]     # (a feed file's own picture)
  let f = artFor(url)
  if fileExists(f): return f
  if url notin fetchingArt:
    fetchingArt[url] = job(proc (): string =
      let r = httpRequest("GET", url, timeoutSec = 30)
      if r.ok and r.body.len > 0:
        createDir(f.parentDir)
        writeFile(f, r.body)
      f)
  ""

proc jobsDone() =
  ## (what the workers finished, taken in)
  var gone: seq[string]
  for url, j in refreshing:
    if not j.ended: continue
    gone.add url
    let i = lib.showOf(url)
    if j.done and i >= 0:
      var known: seq[string]
      for e in lib.shows[i].episodes: known.add e.audio
      let wasEmpty = known.len == 0
      let before = lib.shows[i].episodes.len
      lib.shows[i] = lib.shows[i].merge(j.value)
      let n = lib.shows[i].episodes.len - before
      # (Settings: a show's new episodes downloaded as they come -- not a whole
      # show just followed: its newest one alone then)
      if lib.autoDownload and not defined(wasm):
        var took = 0
        for e in lib.shows[i].episodes:
          if took >= 2 or (wasEmpty and took >= 1): break
          if e.audio notin known and lib.heard.getOrDefault(e.audio).file.len == 0:
            download(e.audio, e.mime)
            inc took
      status = lib.shows[i].title & (if n > 0: ": " & $n & " new" else: ": up to date")
      dirty = true
    elif j.failed:
      status = "Could not read " & url & ": " & j.error
  for u in gone: refreshing.del u
  gone.setLen 0
  for audio, j in downloading:
    if not j.ended: continue
    gone.add audio
    if j.done:
      lib.heard.mgetOrPut(audio, Heard()).file = j.value
      status = "Downloaded"
      dirty = true
    elif j.failed: status = "The download failed: " & j.error
  for u in gone: downloading.del u
  if searching != nil and searching.ended:
    if searching.done:
      found = searching.value
      foundSel = 0
      status = $found.len & " shows found"
    else: status = "The directory could not be asked: " & searching.error
    searching = nil

# ---- playing --------------------------------------------------------------------------------------

proc episodeOf(audio: string): Episode =
  let (s, e) = lib.find(audio)
  if s >= 0: lib.shows[s].episodes[e] else: Episode(audio: audio, title: audio.extractFilename)

proc play(audio: string) =
  ## Plays the episode from where it was left.
  if audio.len == 0: return
  lib.nowPlaying = audio
  let h = lib.heard.getOrDefault(audio)
  if h.posMs > 0 and not h.played: seekVideo(PlayerKey, h.posMs)
  playVideo(PlayerKey)
  let i = lib.queue.find(audio)
  if i >= 0: lib.queue.delete(i)
  dirty = true

proc playNext(): bool =
  if lib.queue.len == 0: return false
  play(lib.queue[0])
  true

proc markPlayed(audio: string; played = true) =
  let before = lib.heard
  var h = lib.heard.getOrDefault(audio)
  h.played = played
  h.posMs = 0
  lib.heard[audio] = h
  history.record(if played: "Mark Played" else: "Mark Unplayed", lib.heard, before)
  dirty = true

proc enqueue(audio: string) =
  if audio.len > 0 and audio notin lib.queue and audio != lib.nowPlaying:
    let before = lib.queue
    lib.queue.add audio
    history.record("Add to Queue", lib.queue, before)
    status = "Added to the queue"
    dirty = true

proc unfollow(i: int) =
  if i notin 0 ..< lib.shows.len: return
  let before = lib.shows
  let title = lib.shows[i].title
  lib.shows.delete(i)
  history.record("Unfollow", lib.shows, before)
  showSel = min(showSel, lib.shows.len - 1)
  status = "Unfollowed " & title & " (Edit, Undo brings it back)"
  dirty = true

proc playedPart(e: Episode): float =
  let h = lib.heard.getOrDefault(e.audio)
  if h.played: 1.0
  elif e.seconds > 0: clamp(h.posMs / (e.seconds * 1000), 0.0, 1.0)
  else: 0.0

proc unplayed(s: Show): int =
  for e in s.episodes:
    if not lib.heard.getOrDefault(e.audio).played: inc result

proc listRows(buttons = true): int =
  ## (the rows of a list that fit in the room left, its buttons under it)
  max(3, (remainingH() - 6 - (if buttons: CtrlH + 2 * Gap else: 0)) div ItemH)

proc gridRows(): int =
  ## (the same for the episodes' grid: its header, rows a little taller)
  max(3, (remainingH() - (ItemH + 6) - CtrlH - 2 * Gap - 4) div (ItemH + 2))

proc speedName(x: float): string =
  ## (1.5 as "1.5x", 1.0 as "1x")
  formatFloat(x, ffDecimal, 2).strip(leading = false, chars = {'0'}).strip(
    leading = false, chars = {'.'}) & "x"

proc skip(seconds: int) =
  seekVideo(PlayerKey, clamp(lastPos + seconds * 1000, 0, max(0, lastDur - 500)))

proc playerBar() =
  ## The player along the bottom: what plays, its buttons, speed and sleep.
  let audio = lib.nowPlaying
  if audio.len == 0:
    label("Nothing playing. Pick an episode and press Play (or Enter).", color = ui.theme.gray)
    return
  let ep = episodeOf(audio)
  let (si, _) = lib.find(audio)
  let show = if si >= 0: lib.shows[si].title else: ""
  let art = if si >= 0: artOf(if ep.image.len > 0: ep.image else: lib.shows[si].image) else: ""
  row:
    if art.len > 0: pictureBox(art, CtrlH, CtrlH)
    if button("« " & $lib.skipBack & " s"): skip(-lib.skipBack)
    tooltip "Back (Ctrl+Left)"
    if button($lib.skipAhead & " s »"): skip(lib.skipAhead)
    tooltip "Ahead (Ctrl+Right)"
    var sp = max(0, Speeds.find(lib.speed))
    var names: seq[string]
    for s in Speeds: names.add speedName(s)
    if combo(names, sp, w = dp(70)):
      lib.speed = Speeds[sp]
      dirty = true
    tooltip "Speed"
    if combo(SleepNames, sleepIdx, w = dp(150)):
      sleepAt = if SleepMinutes[sleepIdx] > 0: ui.now + SleepMinutes[sleepIdx] * 60_000 else: 0
      status = if sleepIdx == 0: "No sleep timer" else: "Sleep timer: " & SleepNames[sleepIdx].toLowerAscii
    tooltip "Sleep timer"
    if button("&Next", enabled = lib.queue.len > 0): discard playNext()
  let e = audioView(lib.source(audio), height = dp(52), key = PlayerKey, speed = lib.speed,
                    title = ep.title & (if show.len > 0: "  ·  " & show else: ""))
  lastPos = e.positionMs
  lastDur = e.durationMs
  lastPlaying = e.playing
  if e.error.len > 0 and e.error != lastError:
    status = e.error & " Play tries again; Download keeps it on the device."
  lastError = e.error
  if e.positionMs > 0:
    var h = lib.heard.getOrDefault(audio)
    if abs(h.posMs - e.positionMs) >= 5000:
      h.posMs = e.positionMs
      lib.heard[audio] = h
      dirty = true
  if e.ended:
    var h = lib.heard.getOrDefault(audio)
    h.played = true
    h.posMs = 0
    lib.heard[audio] = h
    dirty = true
    if sleepIdx == SleepNames.high:
      sleepIdx = 0
      status = "Stopped at the end of the episode (sleep timer)"
    elif not playNext(): status = "Played to the end"
  if sleepAt > 0 and ui.now >= sleepAt:
    playVideo(PlayerKey, false)
    sleepAt = 0
    sleepIdx = 0
    status = "Paused by the sleep timer"
  # the system's controls: the lock screen, the notification, the media keys
  setNowPlaying(NowPlaying(title: ep.title, artist: show, album: show, artPath: art,
                           playing: e.playing, positionMs: e.positionMs, durationMs: e.durationMs,
                           canNext: lib.queue.len > 0, canSeek: true))
  for k in mediaKeys():
    case k.key
    of mkPlay: playVideo(PlayerKey)
    of mkPause, mkStop: playVideo(PlayerKey, false)
    of mkPlayPause: playVideo(PlayerKey, not e.playing)
    of mkNext: discard playNext()
    of mkPrevious: skip(-lib.skipBack)
    of mkSeekTo: seekVideo(PlayerKey, k.ms)
    of mkSeekBy: skip(k.ms div 1000)
    of mkRaise: discard

# ---- the views ------------------------------------------------------------------------------------

proc episodeButtons(e: Episode) =
  row:
    if button("&Play", pxPlay, enabled = e.audio.len > 0):
      play(e.audio)
    if button("&Queue", pxAdd, enabled = e.audio notin lib.queue): enqueue(e.audio)
    let h = lib.heard.getOrDefault(e.audio)
    if h.file.len > 0 and fileExists(h.file):
      if button("&Remove Download", pxDelete):
        try: removeFile(h.file) except OSError: discard
        lib.heard[e.audio].file = ""
        dirty = true
    elif e.audio in downloading:
      let part = downloadPart(e)
      if part >= 0: progress(part, w = dp(110))
      else: label "Downloading...", color = ui.theme.gray
    else:
      if button("&Download", pxDownloads, enabled = not defined(wasm)): download(e.audio, e.mime)
    if button(if h.played: "Mark &Unplayed" else: "Mark Pla&yed", pxCheck):
      markPlayed(e.audio, not h.played)
    if button("&Notes...", pxText): nav.push("episode")

proc showView() =
  ## A show: its picture and words, its episodes, what to do with one.
  if showSel notin 0 ..< lib.shows.len: return
  let s = lib.shows[showSel]
  row:
    let art = artOf(s.image)
    if art.len > 0: pictureBox(art, dp(64), dp(64))
    col:
      label s.title, bold = true
      if s.author.len > 0: label s.author, color = ui.theme.gray
      row:
        if button("&Refresh", pxRefresh, enabled = s.url notin refreshing): refresh(s.url)
        if button("Un&follow", pxRemove): unfollow(showSel)
  if s.url in refreshing and s.episodes.len == 0:
    spinner()
    return
  let eps = s.episodes
  if eps.len == 0:
    emptyState(pxMusic, "No episodes", h = dp(120), detail = "Its feed has no sounds to play.")
    return
  epSel = clamp(epSel, 0, eps.len - 1)
  let g = grid(epCols, eps.len, proc (r, c: int): string =
                 let e = eps[r]
                 case c
                 of 0: e.title
                 of 1: dateText(e.published)
                 of 2: clockText(e.seconds)
                 of 3: $playedPart(e)
                 else:
                   let h = lib.heard.getOrDefault(e.audio)
                   if e.audio == lib.nowPlaying: "Speaker"
                   elif h.file.len > 0: "Downloads"
                   else: "",
               epSel, height = gridRows())
  if g.activated: play(eps[epSel].audio)
  episodeButtons(eps[epSel])

proc libraryView() =
  if lib.shows.len == 0:
    emptyState(pxMusic, "No podcasts yet", h = remainingH(),
               detail = "Find one by its name (Find), add a feed's address (File, Add a Podcast), " &
                        "or bring your list from another app (File, Import OPML).")
    return
  showSel = clamp(showSel, 0, lib.shows.len - 1)
  listDetail(showOpen, dp(240)):
    var names: seq[string]
    for s in lib.shows:
      let n = unplayed(s)
      names.add s.title & "\t" & (if n > 0: $n else: "")
    if listbox(names, showSel, rows = listRows(buttons = false), tabs = [dp(190)]):
      showOpen = true
      epSel = 0
  do:
    showView()

proc queueView() =
  if lib.queue.len == 0:
    emptyState(pxAdd, "The queue is empty", h = remainingH(),
               detail = "Episodes added with Queue play one after another.")
    return
  queueSel = clamp(queueSel, 0, lib.queue.len - 1)
  var names: seq[string]
  for a in lib.queue: names.add episodeOf(a).title
  if listbox(names, queueSel, rows = listRows()): discard
  row:
    if button("&Play", pxPlay): play(lib.queue[queueSel])
    let before = lib.queue
    if button("Move &Up", pxUp, enabled = queueSel > 0):
      swap(lib.queue[queueSel], lib.queue[queueSel - 1])
      dec queueSel
      history.record("Move", lib.queue, before)
    if button("&Remove", pxRemove):
      lib.queue.delete(queueSel)
      history.record("Remove from Queue", lib.queue, before)
    dirty = dirty or lib.queue != before

proc downloadsView() =
  var list: seq[string]
  for a, h in lib.heard:
    if h.file.len > 0 and fileExists(h.file): list.add a
  for a in downloading.keys:
    if a notin list: list.add a
  if list.len == 0:
    emptyState(pxDownloads, "No downloads", h = remainingH(),
               detail = "Episodes downloaded play without the network.")
    return
  dlSel = clamp(dlSel, 0, list.len - 1)
  var names: seq[string]
  for a in list:
    let e = episodeOf(a)
    let part = downloadPart(e)
    names.add e.title & "\t" & (if a in downloading: (if part >= 0: $int(part * 100) & " %" else: "Downloading...")
                                 else: $(getFileSize(lib.heard[a].file) div 1_000_000) & " MB")
  discard listbox(names, dlSel, rows = listRows(), tabs = [dp(380)])
  row:
    if button("&Play", pxPlay): play(list[dlSel])
    if button("&Remove Download", pxDelete, enabled = list[dlSel] notin downloading):
      try: removeFile(lib.heard[list[dlSel]].file) except OSError: discard
      lib.heard[list[dlSel]].file = ""
      dirty = true

proc findView() =
  row:
    if searchBox(query, "A show's name", w = dp(260)): discard
    if combo(["Apple Podcasts", "fyyd"], lib.directory, w = dp(130)): dirty = true
    tooltip "The directory to ask"
    if button("&Search", pxSearch, isDefault = true, enabled = query.strip.len > 0 and searching == nil):
      search(query, lib.directory)
  if searching != nil:
    spinner()
    return
  if found.len == 0:
    emptyState(pxSearch, "Find a podcast", h = remainingH(),
               detail = "Shows come from Apple's podcast directory or fyyd; following one reads its own feed.")
    return
  foundSel = clamp(foundSel, 0, found.len - 1)
  var names: seq[string]
  for f in found: names.add f.title & "\t" & f.author
  let picked = listbox(names, foundSel, rows = listRows(), tabs = [dp(320)])
  discard picked
  row:
    let f = found[foundSel]
    let following = lib.showOf(f.feed) >= 0
    if button(if following: "Following" else: "F&ollow", pxAdd, enabled = not following):
      follow(f.feed)
      section = 0
      showOpen = true

proc extraOf(url: string): string =
  ## (a chapters or transcript file: fetched once, then its text; "" until then)
  if url.len == 0: return ""
  if url in extras: return extras[url]
  if url notin fetchingExtra:
    let proxy = proxied()
    fetchingExtra[url] = job(proc (): string =
      let r = httpRequest("GET", proxy & url, timeoutSec = 30)
      if not r.ok: raise newException(IOError, if r.status == 0: r.error else: "answered " & $r.status)
      r.body)
  let j = fetchingExtra[url]
  if j.ended:
    extras[url] = if j.done: j.value else: ""
    fetchingExtra.del url
    return extras[url]
  ""

proc episodePage() =
  ## An episode's page: its notes (HTML), its chapters and its transcript
  ## when the feed has them (Podcasting 2.0), its buttons.
  var e = episodeOf(lib.nowPlaying)
  if showSel in 0 ..< lib.shows.len and epSel in 0 ..< lib.shows[showSel].episodes.len and section == 0:
    e = lib.shows[showSel].episodes[epSel]
  pageHeader(nav, e.title)
  label(dateText(e.published) & (if e.seconds > 0: "  ·  " & clockText(e.seconds) else: "") &
        (if e.number > 0: "  ·  Episode " & $e.number else: ""), color = ui.theme.gray)
  episodeButtons(e)
  var names = @["N&otes"]
  if e.chapters.len > 0: names.add "&Chapters"
  if e.transcript.len > 0: names.add "&Transcript"
  epTab = clamp(epTab, 0, names.high)
  tabs(epTab, names):
    case names[epTab]
    of "&Chapters":
      let chs = parseChapters(extraOf(e.chapters))
      if chs.len == 0:
        if e.chapters in fetchingExtra: spinner() else: label "No chapters could be read."
      else:
        var rows: seq[string]
        for c in chs: rows.add clockText(int(c.start)) & "\t" & c.title
        if chapterSel >= rows.len: chapterSel = 0
        if listbox(rows, chapterSel, rows = listRows(), tabs = [dp(70)]):
          # (a chapter picked: the episode played from it)
          if lib.nowPlaying != e.audio: play(e.audio)
          seekVideo(PlayerKey, int(chs[chapterSel].start * 1000))
          playVideo(PlayerKey)
    of "&Transcript":
      let t = extraOf(e.transcript)
      if t.len == 0:
        if e.transcript in fetchingExtra: spinner() else: label "No transcript could be read."
      else:
        var text = transcriptText(t)
        editArea(text, lines = -1, readOnly = true)
    else:
      let ev = htmlView(if e.notes.len > 0: e.notes else: "<p>No notes.</p>", height = remainingH(),
                        key = "notes:" & e.audio)
      if ev.link.len > 0: openUrl(ev.link)

proc trayFrame() =
  ## (an icon in the tray with the player's buttons: Settings)
  if lib.tray:
    let t = trayIcon(IconPng, "Retro Podcast" & (if lib.nowPlaying.len > 0: ": " &
                     episodeOf(lib.nowPlaying).title else: ""),
                     [if lastPlaying: "&Pause" else: "&Play", "&Back " & $lib.skipBack & " s",
                      "&Ahead " & $lib.skipAhead & " s", "-", "E&xit"])
    case t.picked
    of 0: playVideo(PlayerKey, not lastPlaying)
    of 1: skip(-lib.skipBack)
    of 2: skip(lib.skipAhead)
    of 4: quitApp()
    else: discard

# ---- the app --------------------------------------------------------------------------------------

when isMainModule and not declared(podcastUnderTest):
  app "Retro Podcast", 860, 600, id = "podcast", look = "podcast", icon = IconPng,
      version = PodcastVersion:
    menubar:
      menu "&File":
        if menuItem("&Add a Podcast...", "Ctrl+N"): addOpen = true
        if menuItem("&Refresh All", "F5"): refreshAll()
        menuSeparator()
        if menuItem("&Import OPML..."): importOpen = true
        if menuItem("&Export OPML...", enabled = lib.shows.len > 0): exportOpen = true
        menuSeparator()
        if menuItem("E&xit"): quitApp()
      menu "&Edit":
        undoMenuItems(history)
      menu "&Play":
        if menuItem(if lastPlaying: "&Pause" else: "&Play", "Ctrl+P", enabled = lib.nowPlaying.len > 0):
          playVideo(PlayerKey, not lastPlaying)
        if menuItem("&Back " & $lib.skipBack & " s", "Ctrl+Left"): skip(-lib.skipBack)
        if menuItem("&Ahead " & $lib.skipAhead & " s", "Ctrl+Right"): skip(lib.skipAhead)
        if menuItem("&Next in the Queue", enabled = lib.queue.len > 0): discard playNext()
        menuSeparator()
        submenu "&Speed":
          for s in Speeds:
            if menuItem(speedName(s), checked = lib.speed == s):
              lib.speed = s
              dirty = true
        submenu "S&leep Timer":
          for i, n in SleepNames:
            if menuItem(n, checked = sleepIdx == i):
              sleepIdx = i
              sleepAt = if SleepMinutes[i] > 0: ui.now + SleepMinutes[i] * 60_000 else: 0
      menu "&View":
        for i, n in ["&Library", "&Queue", "&Downloads", "F&ind"]:
          if menuItem(n, "Ctrl+" & $(i + 1), checked = section == i):
            section = i
            nav.goHome()
        menuSeparator()
        if menuItem("&Settings..."): settingsOpen = true
        if menuItem("&Appearance..."): lookOpen = true
      menu "&Help":
        if menuItem("&About Retro Podcast..."): aboutOpen = true
    # (the menus' shortcuts)
    if hotkeyPressed("Ctrl+N"): addOpen = true
    if hotkeyPressed("F5"): refreshAll()
    if hotkeyPressed("Ctrl+P") and lib.nowPlaying.len > 0: playVideo(PlayerKey, not lastPlaying)
    if hotkeyPressed("Ctrl+Left"): skip(-lib.skipBack)
    if hotkeyPressed("Ctrl+Right"): skip(lib.skipAhead)
    for i in 0 .. 3:
      if hotkeyPressed("Ctrl+" & $(i + 1)):
        section = i
        nav.goHome()

    toolbar:
      if barButton(pxAdd, "Add"): addOpen = true
      if barButton(pxRefresh, "Refresh", enabled = lib.shows.len > 0 and refreshing.len == 0): refreshAll()
      toolSeparator()
      if barButton(if lastPlaying: pxPause else: pxPlay, if lastPlaying: "Pause" else: "Play",
                   enabled = lib.nowPlaying.len > 0):
        playVideo(PlayerKey, not lastPlaying)
      if barButton(pxBack, "Back", enabled = lib.nowPlaying.len > 0): skip(-lib.skipBack)
      if barButton(pxForward, "Ahead", enabled = lib.nowPlaying.len > 0): skip(lib.skipAhead)
    statusbar(status, if lib.queue.len > 0: $lib.queue.len & " queued" else: "",
              if sleepAt > 0: "Sleep in " & $((sleepAt - ui.now) div 60_000 + 1) & " min" else: "")

    jobsDone()
    if not startedUp:
      startedUp = true
      if lib.checkAtStart and lib.shows.len > 0: refreshAll()
    # (a link shared from another app -- Android's share sheet: followed)
    let came = sharedIn()
    for word in came.text.splitWhitespace:
      if word.startsWith("http://") or word.startsWith("https://"):
        follow(word)
        section = 0
        break
    row:
      if segmented(["&Library", "&Queue", "&Downloads", "F&ind"], section): nav.goHome()
    # (Find, and Add's dialog: the keyboard in their text box at once)
    if section != lastSection and section == 3: focusFirstText()
    lastSection = section
    if addOpen and not wasAdding: focusFirstText(inDialog = true)
    wasAdding = addOpen
    # the page, then the player under it
    let playerH = if lib.nowPlaying.len > 0: CtrlH + dp(52) + 3 * Gap + dp(4) else: CtrlH + 2 * Gap
    pageView(nav, max(dp(120), remainingH() - playerH)):
      case nav.page
      of "episode": episodePage()
      else:
        case section
        of 1: queueView()
        of 2: downloadsView()
        of 3: findView()
        else: libraryView()
    playerBar()
    undoKeys(history)

    trayFrame()

    # dialogs
    dialog(addOpen, "Add a Podcast", 440):
      label "The address of the show's feed (RSS or Atom), or a feed file:"
      edit(addUrl)
      row:
        spring()
        if button("&Add", isDefault = true, enabled = addUrl.strip.len > 0):
          follow(addUrl)
          addUrl = ""
          addOpen = false
          section = 0
        if button("Cancel"): addOpen = false
    if filePicker(importOpen, opmlPath, patterns = ["*.opml", "*.xml"]):
      try:
        var n = 0
        for f in parseOpml(readFile(opmlPath)):
          if lib.showOf(f.url) < 0:
            follow(f.url)
            inc n
        status = "Imported " & $n & " shows"
      except IOError: status = "Could not read " & opmlPath
    if filePicker(exportOpen, opmlPath, mode = fmSave, patterns = ["*.opml"]):
      var links: seq[FeedLink]
      for s in lib.shows: links.add (s.title, s.url)
      try:
        writeFile(opmlPath, toOpml(links, "Retro Podcast"))
        status = "Exported " & $links.len & " shows to " & opmlPath.extractFilename
      except IOError: status = "Could not write " & opmlPath
    dialog(settingsOpen, "Settings", 460):
      form(dp(150)):
        field("Back by (seconds):"):
          if intEdit(lib.skipBack, lo = 5, hi = 120): dirty = true
        field("Ahead by (seconds):"):
          if intEdit(lib.skipAhead, lo = 5, hi = 300): dirty = true
        field(""):
          if checkbox("An icon in the &tray (desktops)", lib.tray): dirty = true
        field(""):
          if checkbox("&Check for new episodes when it starts", lib.checkAtStart): dirty = true
        field(""):
          if checkbox("&Download new episodes as they come", lib.autoDownload): dirty = true
        when defined(wasm):
          field("Feed proxy:"):
            if edit(lib.proxy): dirty = true
          field(""):
            label("Put before a feed's address: most podcast sites do not let web pages read " &
                  "their feeds (CORS).", color = ui.theme.gray)
      row:
        spring()
        if button("OK", isDefault = true): settingsOpen = false
    dialog(lookOpen, "Appearance", 460):
      discard appearanceSettings()
      row:
        spring()
        if button("OK", isDefault = true): lookOpen = false
    aboutBox(aboutOpen, "Retro Podcast", PodcastVersion,
             ["A podcast player for Windows, macOS, Linux, Android, iOS and web pages, made " &
              "with Retro Nim UI: shows found by name or by feed, OPML, any speed, where you " &
              "left off, downloads, a queue, a sleep timer, the system's media controls."],
             tagline = "Podcasts, 1994 style", iconPng = IconPng,
             url = "https://github.com/foxoman/retroui")

    # (the library saved a moment after it changed -- an Undo too --, and when the app ends)
    if history.revision != savedRevision:
      savedRevision = history.revision
      dirty = true
    if dirty and ui.now - savedAt > 2000:
      lib.save()
      dirty = false
      savedAt = ui.now
    if closeRequested() and dirty: lib.save()
