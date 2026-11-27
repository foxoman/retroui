## Retro Music's TV: the free channels of the world -- the Free-TV list (github.com/Free-TV/IPTV),
## fetched when TV is opened, nothing of it in the app --, by country, their logos fetched as they
## show, a search over them, your channels kept. A channel plays in the app, as the players of
## 2012 showed a film: Done and its name over it, the time, its picture, a panel with the channel
## before, play or pause and the next under it. Left while it plays -- Done, the phone's Home --,
## its sound goes on in the app's own player, as a station's does: in the background, on the lock
## screen, with a headset's keys.

import std/[strutils, json, os]
import retroui
import retroui/[jobs, http]
import local, online

type Channel* = object
  name*, logo*, country*, url*: string
  geo*: bool                             ## it may be seen only in its own country (Free-TV's circled G)

const
  TvListUrl* = "https://raw.githubusercontent.com/Free-TV/IPTV/master/playlist.m3u8"
    ## (the list, fetched as it is now: Free-TV keeps it)
  TvKeep = "tv.json"

var
  tvChannels*: seq[Channel]
  tvState* = 0                           ## 0 not asked, 1 on its way, 2 here, -1 it did not come
  tvJob: Job[HttpResponse]
  tvWords* = ""
  tvFavs*: seq[Channel]                  ## your channels (kept, with their addresses)
  tvPage* = ""                           ## "" the countries, "c:" & a country's name
  tvOpen* = false                        ## a channel's player on the screen
  tvList: seq[Channel]                   ## (the channels the player goes along: the list it came from)
  tvAt = -1
  tvFull = false                         ## (the picture the whole screen: the phone on its side)
  tvPaused = false
  tvSince = 0                            ## (when it started: the time it has played, live)

proc attr(line, name: string): string =
  let k = line.find(name & "=\"")
  if k < 0: return ""
  let a = k + name.len + 2
  let b = line.find('"', a)
  if b < 0: "" else: line[a ..< b]

proc cleanName(s: string): tuple[name: string; geo: bool] =
  ## (Free-TV's marks out of a name -- circled G: seen in its country only; circled S, Y, M --;
  ## they are not shown)
  result.geo = "\u24BC" in s
  result.name = s.multiReplace(("\u24BC", ""), ("\u24C8", ""), ("\u24CE", ""), ("\u24C2", "")).strip

proc parseM3u*(text: string): seq[Channel] =
  ## The channels of an M3U list: an `#EXTINF` line before each address -- its `tvg-logo`,
  ## `group-title` (the country) and its name after the first comma outside quotes. Lines it
  ## does not know are passed over; an address with no `#EXTINF` before it is named by itself;
  ## a YouTube page (no stream to play) is left out.
  var cur: Channel
  var have = false
  for raw in text.splitLines:
    let l = raw.strip
    if l.len == 0: continue
    if l.startsWith("#EXTINF"):
      cur = Channel(logo: attr(l, "tvg-logo"), country: attr(l, "group-title"))
      # (the name: after the first comma outside quotes -- a name may have commas of its own)
      var quoted = false
      var comma = -1
      for i, c in l:
        if c == '"': quoted = not quoted
        elif c == ',' and not quoted:
          comma = i
          break
      let n = if comma >= 0: l[comma + 1 .. ^1] else: attr(l, "tvg-name")
      (cur.name, cur.geo) = cleanName(if n.strip.len > 0: n else: attr(l, "tvg-name"))
      have = true
    elif l.startsWith("#"): continue
    else:
      let low = l.toLowerAscii
      if not (low.startsWith("http://") or low.startsWith("https://")) or "youtube.com/" in low or
         "youtu.be/" in low:
        have = false
        continue
      if not have: cur = Channel(name: l)
      cur.url = l
      if cur.name.len == 0: cur.name = l
      result.add cur
      have = false

proc countries*(list: openArray[Channel]): seq[tuple[name: string; count: int]] =
  ## The countries of `list` in their order, with how many channels each has.
  for c in list:
    let g = if c.country.len > 0: c.country else: "Other"
    var found = false
    for e in result.mitems:
      if e.name == g:
        inc e.count
        found = true
        break
    if not found: result.add (g, 1)

proc findChannels*(list: openArray[Channel]; words: string): seq[Channel] =
  ## The channels whose name or country has every one of `words`.
  let ws = words.toLowerAscii.splitWhitespace
  for c in list:
    let hay = (c.name & " " & c.country).toLowerAscii
    var ok = true
    for w in ws:
      if w notin hay: ok = false
    if ok: result.add c

proc channelSong*(c: Channel): Song =
  ## A channel as a song of the app's player: live, its sound only, its logo the cover.
  Song(path: c.url, title: c.name, artist: c.country, coverUrl: c.logo, origin: "TV", live: true)

# ---- kept ------------------------------------------------------------------------------------------

proc keepPath(): string = dataDir("RetroMusic") / TvKeep

proc saveTv*() =
  var favs = newJArray()
  for c in tvFavs: favs.add %*{"name": c.name, "logo": c.logo, "country": c.country, "url": c.url}
  try:
    createDir(dataDir("RetroMusic"))
    writeFile(keepPath(), $(%*{"favs": favs}))
  except CatchableError: discard

proc loadTv*() =
  tvFavs.setLen(0)
  try:
    let j = parseJson(readFile(keepPath()))
    for c in j{"favs"}.getElems:
      tvFavs.add Channel(name: c{"name"}.getStr, logo: c{"logo"}.getStr, country: c{"country"}.getStr,
                         url: c{"url"}.getStr)
  except CatchableError: discard

proc isFav*(c: Channel): bool =
  for f in tvFavs:
    if f.url == c.url: return true

proc toggleFav*(c: Channel) =
  for i, f in tvFavs:
    if f.url == c.url:
      tvFavs.delete(i)
      saveTv()
      return
  tvFavs.add c
  saveTv()

# ---- the list, asked for ----------------------------------------------------------------------------

proc askTv*() =
  ## The channels' list, asked for (once, and again after it did not come).
  if tvState in [1, 2]: return
  tvJob = if onlineFetch != nil: onlineFetch(TvListUrl) else: fetch(TvListUrl, timeoutSec = 30)
  tvState = 1

proc pollTv*() =
  ## Every frame: the list, when it came.
  if tvState != 1 or not tvJob.ended: return
  let resp = if tvJob.done: tvJob.value else: HttpResponse(error: tvJob.error)
  if resp.status == 200:
    tvChannels = parseM3u(resp.body)
    tvState = if tvChannels.len > 0: 2 else: -1
  else: tvState = -1
  if tvState == -1: onlineNote = "The channels' list did not come -- is the phone online?"
  ui.redraw = true

# ---- the pages -----------------------------------------------------------------------------------------

proc pic(url: string): Bitmap =
  if url.len > 0 and onlineCover != nil: onlineCover(url) else: nil

proc watch*(list: openArray[Channel]; at: int) =
  ## A channel of `list` played on the screen (the app's own sound paused: one at a time).
  if at < 0 or at >= list.len: return
  tvList = @list
  tvAt = at
  tvOpen = true
  tvPaused = false
  tvSince = ui.now
  if localPlaying: pauseLocal()
  closeVideo("tv")

proc channelRows(list: openArray[Channel]; key: string) =
  ## (channels in rows, their logos: a tap plays one, its star keeps it)
  tableGroup(""):
    for i, c in list:
      let h = tableRow(c.name, if isFav(c): "★" else: "", taChevron, picture = pic(c.logo),
                       subtitle = if c.geo: c.country & " · in its country only" else: c.country,
                       glyph = if c.logo.len == 0: nfVideo else: "", key = key & ":" & c.url)
      if h.clicked: watch(list, i)
      if h.menu: toggleFav(c)

proc tvTitle*(): string =
  if tvPage.startsWith("c:"): tvPage[2 .. ^1] else: "TV"

proc tvBack*(): string =
  if tvPage.len > 0: "TV" else: ""

proc tvScreen*() =
  ## TV's pages: your channels and the countries, or a country's channels; the search over all.
  askTv()
  discard searchBar(tvWords, "Channels, countries")
  if tvWords.strip.len > 0:
    let found = findChannels(tvChannels, tvWords)
    if found.len == 0:
      emptyState(nfVideo, if tvState == 1: "Looking..." else: "No channel matches",
                 detail = "A channel's name or its country.")
    else: channelRows(found, "found")
    return
  if tvPage.startsWith("c:"):
    let want = tvPage[2 .. ^1]
    var list: seq[Channel]
    for c in tvChannels:
      if c.country == want or (want == "Other" and c.country.len == 0): list.add c
    channelRows(list, "c")
    return
  if tvFavs.len > 0:
    label("Your Channels", bold = true)
    channelRows(tvFavs, "fav")
  case tvState
  of 1, 0: emptyState(nfVideo, "The channels are on their way", detail = "The free channels of the world.")
  of -1:
    emptyState(nfVideo, "The channels' list did not come", detail = "Pull down, or come back when the phone is online.")
    if button("Try Again"): tvState = 0
  else:
    tableGroup("Countries", "Free channels, as Free-TV lists them (github.com/Free-TV/IPTV). Hold a " &
                            "channel to keep it in Your Channels."):
      for (name, n) in countries(tvChannels):
        if tableRow(name, $n, taChevron, key = "country:" & name).clicked: tvPage = "c:" & name

# ---- the player ----------------------------------------------------------------------------------------

proc setFull(on: bool) =
  ## (the picture the whole screen, or as it was)
  if tvFull == on: return
  tvFull = on
  videoFullScreen("tv", on)

proc soundOn*() =
  ## (the player left while it plays: the channel's sound goes on in the app's own player)
  if not tvOpen: return
  let playing = not tvPaused
  setFull(false)
  closeVideo("tv")
  tvOpen = false
  if playing and tvAt >= 0 and tvAt < tvList.len:
    playRemote([channelSong(tvList[tvAt])], 0)
    toast("The sound goes on -- Now Playing")

proc clockText(ms: int): string =
  let s = max(0, ms) div 1000
  if s >= 3600: $(s div 3600) & ":" & align($((s div 60) mod 60), 2, '0') & ":" & align($(s mod 60), 2, '0')
  else: $(s div 60) & ":" & align($(s mod 60), 2, '0')

proc barButton(id: Id; r: Rect; label: string; primary = false): bool =
  ## (a button on the player's dark bars: Gloss's glossy one, the others' a pill of smoked glass)
  let h = interact(id, r)
  if glossLook(): glossBarButton(r, h.down, done = primary)
  else:
    roundRect(r, float(r.h) / 2, withAlpha(if primary: accentColor() else: color(255, 255, 255),
                                           if primary: (if h.down: 200 else: 255) elif h.down: 70 else: 40))
  let st = style(bold = true)
  text(r.x + (r.w - textWidth(label, st)) div 2, r.y + (r.h - lineHeight(st)) div 2, label,
       color(255, 255, 255), st)
  if accessOn: accessNode(arButton, label, id = id, r = r)
  h.clicked

proc roundGlyph(id: Id; cx, cy, d: int; glyph, name: string; size = 1.6): bool =
  let r = rect(cx - d div 2, cy - d div 2, d, d)
  let h = interact(id, r)
  if h.down: disc(float(cx), float(cy), float(d) / 2, withAlpha(color(255, 255, 255), 40))
  let gs = style(size = size)
  text(cx - textWidth(glyph, gs) div 2, cy - lineHeight(gs) div 2, glyph, color(255, 255, 255), gs)
  if accessOn: accessNode(arButton, name, id = id, r = r)
  h.clicked

proc tvPlayer*(area: Rect) =
  ## The channel on the screen, drawn whole in `area`: a dark bar with Done, its name and Full
  ## Screen; under it the time it has played (or where it is, and a bar to go along a
  ## recording); the picture; a panel with the channel before, play or pause and the next. The
  ## phone's Back is Done. Full Screen: the picture the whole screen, the phone on its side -- a
  ## tap or Back, as it was. Left while it plays, its sound goes on (`soundOn`).
  if tvAt < 0 or tvAt >= tvList.len:
    tvOpen = false
    return
  let c = tvList[tvAt]
  let id = idOf("tvplayer")
  if tvFull:
    # (the whole window, its bars' places too; a tap -- taken before the picture's own -- or Back:
    # out of it)
    let whole = rect(ui.winX, 0, ui.w, ui.h)
    fill(whole, color(0, 0, 0))
    let tap = interact(id + 9, whole, focusable = false)
    pushFrame(rect(whole.x, whole.y, whole.w, 0))
    let ev = videoView(c.url, height = whole.h, w = whole.w, autoplay = true, controls = false, key = "tv",
                       title = c.name)
    discard popFrame()
    if ev.playing: tvPaused = false
    if accessOn: accessNode(arButton, "Leave Full Screen", id = id + 9, r = whole)
    if canInput() and backPressed():
      cancelClose()
      setFull(false)
    elif canInput() and keyHit(KeyEsc): setFull(false)
    elif tap.clicked: setFull(false)
    if ui.paused and not tvPaused: soundOn()
    return
  fill(area, color(0, 0, 0))
  # the top bar: Done, the name and the country, the picture's size
  let topH = if fingers(): dp(46) else: dp(40)
  let top = rect(area.x, area.y, area.w, topH)
  if glossLook(): roundRectShaded(top, 0, color(58, 60, 66), color(22, 23, 26))
  else: fill(top, color(28, 29, 32))
  hline(top.x, top.y + top.h - 1, top.w, color(0, 0, 0))
  let bh = if fingers(): dp(32) else: dp(28)
  let doneR = rect(top.x + dp(8), top.y + (topH - bh) div 2, dp(64), bh)
  var done = barButton(id + 1, doneR, "Done", primary = true)
  let sizeR = rect(top.x + top.w - dp(8) - bh, top.y + (topH - bh) div 2, bh, bh)
  if roundGlyph(id + 2, sizeR.x + bh div 2, sizeR.y + bh div 2, bh, nfExpand, "Full Screen", 1.1):
    setFull(true)
  let st = style(bold = true)
  let tw = top.w - 2 * (doneR.w + dp(20))
  let nm = ellipsize(c.name, tw, st)
  text(top.x + (top.w - textWidth(nm, st)) div 2, top.y + (topH - lineHeight(st) - FontH) div 2, nm,
       color(255, 255, 255), st)
  let co = ellipsize(c.country, tw)
  text(top.x + (top.w - textWidth(co)) div 2, top.y + (topH - lineHeight(st) - FontH) div 2 + lineHeight(st), co,
       color(170, 172, 178))
  # the time: how long it has played (live), or where it is and the bar along it
  let timeH = if fingers(): dp(36) else: dp(30)
  let tr = rect(area.x, top.y + topH, area.w, timeH)
  fill(tr, color(16, 16, 18))
  # the panel at the foot
  let panelH = if fingers(): dp(70) else: dp(58)
  let foot = rect(area.x, area.y + area.h - panelH - dp(16), area.w, panelH + dp(16))
  let mid = rect(area.x, tr.y + tr.h, area.w, foot.y - tr.y - tr.h)
  # the picture: in the place between the bars, in its own shape (the player keeps it)
  let vr = mid
  pushFrame(rect(vr.x, vr.y, vr.w, 0))
  let ev = videoView(c.url, height = vr.h, w = vr.w, autoplay = true, controls = false, key = "tv",
                     title = c.name)
  discard popFrame()
  if ev.playing: tvPaused = false
  let live = ev.durationMs <= 0
  let tst = style(bold = true, size = 0.9)
  if live:
    let t = clockText(ui.now - tvSince)
    text(tr.x + dp(12), tr.y + (timeH - lineHeight(tst)) div 2, t, color(255, 255, 255), tst)
    let pill = "LIVE"
    let pw = textWidth(pill, tst) + dp(14)
    let pr = rect(tr.x + tr.w - pw - dp(12), tr.y + (timeH - lineHeight(tst) - dp(4)) div 2, pw,
                  lineHeight(tst) + dp(4))
    roundRect(pr, float(pr.h) / 2, color(214, 34, 54))
    text(pr.x + dp(7), pr.y + dp(2), pill, color(255, 255, 255), tst)
    if not tvPaused: wakeIn(500)
  else:
    let a = clockText(ev.positionMs)
    let b = "-" & clockText(max(0, ev.durationMs - ev.positionMs))
    let tw0 = textWidth("-0:00:00", tst) + dp(14)
    text(tr.x + dp(10), tr.y + (timeH - lineHeight(tst)) div 2, a, color(255, 255, 255), tst)
    text(tr.x + tr.w - dp(10) - textWidth(b, tst), tr.y + (timeH - lineHeight(tst)) div 2, b,
         color(255, 255, 255), tst)
    pushFrame(rect(tr.x + tw0, tr.y + (timeH - CtrlH) div 2, tr.w - 2 * tw0, 0))
    var at = ev.positionMs div 1000
    if slider(at, 0, max(1, ev.durationMs div 1000), ticks = 0): seekVideo("tv", at * 1000)
    discard popFrame()
  if ev.error.len > 0:
    let e = ellipsize(ev.error, mid.w - dp(24))
    text(mid.x + (mid.w - textWidth(e)) div 2, mid.y + mid.h - FontH - dp(8), e, color(255, 150, 150))
  # the panel: the channel before, play or pause, the next; your channel's star
  let pw = min(foot.w - dp(32), dp(320))
  let pr = rect(foot.x + (foot.w - pw) div 2, foot.y, pw, panelH)
  softShadow(pr, float(dp(18)), 4)
  roundRect(pr, float(dp(18)), withAlpha(color(52, 54, 60), 220))
  if glossLook():
    pushClip(rect(pr.x, pr.y, pr.w, pr.h div 2))
    roundRect(pr, float(dp(18)), withAlpha(color(255, 255, 255), 22))
    popClip()
  roundFrame(pr, float(dp(18)), 1, withAlpha(color(255, 255, 255), 50))
  let d = panelH - dp(14)
  let cy = pr.y + pr.h div 2
  let step = pw div 4
  let fav = isFav(c)
  if roundGlyph(id + 3, pr.x + step div 2, cy, d, if fav: nfStar else: nfStarO,
                if fav: "Out of Your Channels" else: "Keep in Your Channels", 1.2):
    toggleFav(c)
  if roundGlyph(id + 4, pr.x + step + step div 2, cy, d, nfStepBackward, "The channel before") and tvAt > 0:
    watch(tvList, tvAt - 1)
  if roundGlyph(id + 5, pr.x + 2 * step + step div 2, cy, d, if tvPaused: nfPlay else: nfPause,
                if tvPaused: "Play" else: "Pause", 1.9):
    tvPaused = not tvPaused
    playVideo("tv", not tvPaused)
  if roundGlyph(id + 6, pr.x + 3 * step + step div 2, cy, d, nfStepForward, "The next channel") and
     tvAt < tvList.len - 1:
    watch(tvList, tvAt + 1)
  # Done, the phone's Back, Esc: the sound goes on; the app sent away while it plays too
  if canInput() and backPressed():
    cancelClose()                        # (the app stays: only the player goes)
    done = true
  elif canInput() and keyHit(KeyEsc): done = true
  if done or (ui.paused and not tvPaused): soundOn()
