## Podcast and news feeds: RSS 2.0 (with the iTunes and Podcasting 2.0
## tags podcasts carry), Atom, and OPML -- the list of feeds podcast apps
## import and export. Pure Nim (std/xmlparser): every system, web pages
## too. Fetching them is `retroui/jobs`' `fetch`.
##
## .. code-block:: nim
##   import retroui, retroui/[jobs, feeds]
##   var get = fetch("https://feeds.example.com/show.xml")
##   var show: Feed
##   app "Show", 400, 300:
##     if get != nil and get.done:
##       show = parseFeed(get.value.body, "https://feeds.example.com/show.xml")
##       get = nil
##     label show.title, bold = true
##     for e in show.episodes: label e.title & " (" & clockText(e.seconds) & ")"
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[xmlparser, xmltree, strutils, streams, times, json]
from std/unicode import Rune, toUTF8

type
  Episode* = object
    ## An item of a feed: a podcast's episode, a news article.
    title*, guid*, link*: string
    audio*: string           ## the enclosure's address (the episode's sound or video)
    mime*: string            ## its type ("audio/mpeg")
    bytes*: int64            ## its size (0: not said)
    notes*: string           ## the show notes / summary (HTML as the feed has it)
    image*: string           ## its own picture's address ("" : the feed's)
    seconds*: int            ## how long it is (0: not said)
    published*: int64        ## when, in Unix seconds (0: not said)
    season*, number*: int    ## its season and number (0: not said)
    chapters*: string        ## the address of its chapters (Podcasting 2.0)
    transcript*: string      ## the address of its transcript (Podcasting 2.0)
  Feed* = object
    ## A feed read: what it is about and its items, newest first as the
    ## feed lists them.
    url*: string             ## where it was read from
    title*, link*, author*, description*, image*, language*: string
    episodes*: seq[Episode]
  FeedLink* = tuple[title, url: string]
    ## A feed in an OPML list.
  Chapter* = object
    ## A chapter of an episode (Podcasting 2.0's chapters file).
    start*: float            ## where it starts, in seconds
    title*: string
    url*, image*: string     ## a link and a picture it has ("": none)

proc parseDuration*(s: string): int =
  ## A length as feeds write it -- "1:02:03", "62:03", "3723", "3723.5" --
  ## in seconds (0 when it is none of these).
  let t = s.strip
  if t.len == 0: return 0
  var parts = t.split(':')
  for p in parts:
    if p.len == 0 or not p.allCharsInSet(Digits + {'.'}): return 0
  for p in parts:
    result = result * 60 + int(try: parseFloat(p) except ValueError: 0.0)

proc clockText*(seconds: int): string =
  ## A length to show: "1:02:03", "42:07" ("" when not known).
  if seconds <= 0: return ""
  let h = seconds div 3600
  let m = seconds mod 3600 div 60
  let s = seconds mod 60
  if h > 0: $h & ":" & align($m, 2, '0') & ":" & align($s, 2, '0')
  else: $m & ":" & align($s, 2, '0')

const months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

proc parseFeedDate*(s: string): int64 =
  ## A date as feeds write it -- RSS's "Wed, 02 Oct 2024 13:00:00 GMT"
  ## (or "+0400", "EST"...), Atom's "2024-10-02T13:00:00Z" -- in Unix
  ## seconds (0 when it cannot be read).
  let t = s.strip
  if t.len < 8: return 0
  var y, mo, d, h, mi, sec, off: int
  try:
    if t[4] == '-':
      # ISO 8601 / RFC 3339
      y = parseInt(t[0 .. 3]); mo = parseInt(t[5 .. 6]); d = parseInt(t[8 .. 9])
      if t.len >= 19:
        h = parseInt(t[11 .. 12]); mi = parseInt(t[14 .. 15]); sec = parseInt(t[17 .. 18])
      var z = 19
      while z < t.len and t[z] in Digits + {'.'}: inc z
      if z < t.len and t[z] in {'+', '-'} and z + 5 < t.len + 1:
        let sign = if t[z] == '-': -1 else: 1
        let hh = parseInt(t[z + 1 .. z + 2])
        let mm = parseInt(t[^2 .. ^1])
        off = sign * (hh * 60 + mm)
    else:
      # RFC 822: [Day,] DD Mon YYYY HH:MM[:SS] ZONE
      var w = t.replace(",", " ").splitWhitespace
      if w.len > 0 and w[0].len >= 3 and w[0][0].isAlphaAscii: w.delete(0)
      if w.len < 3: return 0
      d = parseInt(w[0])
      mo = months.find(w[1][0 .. min(2, w[1].high)].toLowerAscii) + 1
      if mo == 0: return 0
      y = parseInt(w[2])
      if y < 100: y += (if y < 70: 2000 else: 1900)
      if w.len > 3:
        let c = w[3].split(':')
        h = parseInt(c[0])
        if c.len > 1: mi = parseInt(c[1])
        if c.len > 2: sec = parseInt(c[2])
      if w.len > 4:
        let z = w[4]
        if z.len == 5 and z[0] in {'+', '-'}:
          off = (if z[0] == '-': -1 else: 1) * (parseInt(z[1 .. 2]) * 60 + parseInt(z[3 .. 4]))
        else:
          off = case z.toUpperAscii
            of "EST": -300
            of "EDT", "CDT": (if z.toUpperAscii == "EDT": -240 else: -300)
            of "CST", "MDT": (if z.toUpperAscii == "CST": -360 else: -360)
            of "MST", "PDT": -420
            of "PST": -480
            else: 0
  except ValueError, IndexDefect:
    return 0
  if mo notin 1 .. 12 or d notin 1 .. 31: return 0
  try:
    let dt = dateTime(y, Month(mo), MonthdayRange(min(d, getDaysInMonth(Month(mo), y))),
                      HourRange(clamp(h, 0, 23)), MinuteRange(clamp(mi, 0, 59)),
                      SecondRange(clamp(sec, 0, 59)), zone = utc())
    dt.toTime.toUnix - int64(off) * 60
  except CatchableError:
    0

proc text(n: XmlNode; tag: string): string =
  ## (the text of `n`'s first child `tag`, CDATA too; "" when none)
  if n == nil: return ""
  let c = n.child(tag)
  if c == nil: return ""
  var t = ""
  for k in c:
    if k.kind in {xnText, xnCData, xnEntity}: t.add k.text
  result = t.strip

proc firstOf(n: XmlNode; tags: openArray[string]): string =
  for t in tags:
    result = n.text(t)
    if result.len > 0: return

proc attrOf(n: XmlNode; tag, attr: string): string =
  if n == nil: return ""
  let c = n.child(tag)
  if c == nil or c.attrs == nil: "" else: c.attr(attr)

proc readXml(xml: string): XmlNode =
  ## (the document's root; nil when it is not XML at all)
  var errors: seq[string]
  try:
    result = parseXml(newStringStream(xml), "feed", errors, {})
  except CatchableError:
    result = nil

proc parseFeed*(xml: string; url = ""): Feed =
  ## The feed in `xml` (RSS or Atom), read from `url`. Raises ValueError
  ## when it is neither (a web page, an error page).
  result.url = url
  let root = readXml(xml)
  if root == nil or root.kind != xnElement: raise newException(ValueError, "not a feed")
  let tag = root.tag.toLowerAscii
  if tag == "rss" or tag == "rdf:rdf":
    let ch = if tag == "rss": root.child("channel") else: root.child("channel")
    if ch == nil: raise newException(ValueError, "an RSS feed without its channel")
    result.title = ch.text("title")
    result.link = ch.text("link")
    result.description = ch.firstOf(["description", "itunes:summary"])
    result.author = ch.firstOf(["itunes:author", "managingEditor", "dc:creator"])
    result.language = ch.text("language")
    result.image = ch.attrOf("itunes:image", "href")
    if result.image.len == 0:
      let im = ch.child("image")
      if im != nil: result.image = im.text("url")
    let items = if tag == "rss": ch.findAll("item") else: root.findAll("item")
    for it in items:
      var e = Episode(title: it.text("title"), link: it.text("link"))
      e.guid = it.text("guid")
      let enc = it.child("enclosure")
      if enc != nil and enc.attrs != nil:
        e.audio = enc.attr("url")
        e.mime = enc.attr("type")
        e.bytes = (try: parseBiggestInt(enc.attr("length")) except ValueError: 0)
      e.notes = it.firstOf(["content:encoded", "description", "itunes:summary"])
      e.image = it.attrOf("itunes:image", "href")
      e.seconds = parseDuration(it.text("itunes:duration"))
      e.published = parseFeedDate(it.firstOf(["pubDate", "dc:date"]))
      e.season = (try: parseInt(it.text("itunes:season")) except ValueError: 0)
      e.number = (try: parseInt(it.text("itunes:episode")) except ValueError: 0)
      e.chapters = it.attrOf("podcast:chapters", "url")
      e.transcript = it.attrOf("podcast:transcript", "url")
      if e.guid.len == 0: e.guid = if e.audio.len > 0: e.audio else: e.link
      result.episodes.add e
  elif tag == "feed":
    # Atom
    result.title = root.text("title")
    result.description = root.firstOf(["subtitle", "summary"])
    result.image = root.firstOf(["logo", "icon"])
    let au = root.child("author")
    if au != nil: result.author = au.text("name")
    for l in root.findAll("link"):
      if l.attrs != nil and l.attr("rel") in ["", "alternate"] and result.link.len == 0:
        result.link = l.attr("href")
    for it in root.findAll("entry"):
      var e = Episode(title: it.text("title"), guid: it.text("id"))
      for l in it.findAll("link"):
        if l.attrs == nil: continue
        case l.attr("rel")
        of "enclosure":
          e.audio = l.attr("href")
          e.mime = l.attr("type")
          e.bytes = (try: parseBiggestInt(l.attr("length")) except ValueError: 0)
        of "", "alternate":
          if e.link.len == 0: e.link = l.attr("href")
        else: discard
      e.notes = it.firstOf(["content", "summary"])
      e.published = parseFeedDate(it.firstOf(["published", "updated"]))
      if e.guid.len == 0: e.guid = if e.audio.len > 0: e.audio else: e.link
      result.episodes.add e
  else:
    raise newException(ValueError, "not a feed (" & root.tag & ")")

proc parseOpml*(xml: string): seq[FeedLink] =
  ## The feeds of an OPML list (podcast apps' export), folders flattened.
  let root = readXml(xml)
  if root == nil or root.kind != xnElement: return
  for o in root.findAll("outline"):
    if o.attrs == nil: continue
    let u = o.attr("xmlUrl")
    if u.len > 0:
      let t = if o.attr("title").len > 0: o.attr("title") else: o.attr("text")
      result.add (t, u)

proc toOpml*(feeds: openArray[FeedLink]; title = "Podcasts"): string =
  ## An OPML list of `feeds`, for another podcast app to import.
  result = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\">\n  <head><title>" &
           xmltree.escape(title) & "</title></head>\n  <body>\n"
  for f in feeds:
    result.add "    <outline type=\"rss\" text=\"" & xmltree.escape(f.title) & "\" title=\"" &
               xmltree.escape(f.title) & "\" xmlUrl=\"" & xmltree.escape(f.url) & "\"/>\n"
  result.add "  </body>\n</opml>\n"

proc plainText*(html: string): string =
  ## Show notes' HTML as plain text: tags left out, paragraphs and line
  ## breaks kept, the common entities read.
  var o = ""
  var i = 0
  while i < html.len:
    let c = html[i]
    if c == '<':
      let e = html.find('>', i)
      if e < 0: break
      let t = html[i + 1 ..< e].toLowerAscii.strip(chars = {'/', ' '})
      let name = t.split({' ', '/'})[0]
      if name in ["p", "br", "div", "li", "h1", "h2", "h3", "h4", "tr"] and
         o.len > 0 and not o.endsWith("\n"):
        o.add '\n'
      if name == "li" and html[i + 1] != '/': o.add "- "
      i = e + 1
    elif c == '&':
      let e = html.find(';', i)
      if e > i and e - i <= 8:
        let ent = html[i + 1 ..< e]
        case ent
        of "amp": o.add '&'
        of "lt": o.add '<'
        of "gt": o.add '>'
        of "quot": o.add '"'
        of "apos", "#39": o.add '\''
        of "nbsp": o.add ' '
        else:
          if ent.startsWith("#"):
            let n = try: (if ent.startsWith("#x"): parseHexInt(ent[2 .. ^1]) else: parseInt(ent[1 .. ^1]))
                    except ValueError: 32
            o.add Rune(n).toUTF8
          else: o.add html[i .. e]
        i = e + 1
      else:
        o.add c
        inc i
    else:
      o.add c
      inc i
  # (runs of blank lines: one)
  var lines: seq[string]
  for l in o.splitLines:
    let s = l.strip
    if s.len > 0 or (lines.len > 0 and lines[^1].len > 0): lines.add s
  result = lines.join("\n").strip

proc parseChapters*(text: string): seq[Chapter] =
  ## The chapters of an episode's chapters file (`Episode.chapters` names
  ## it: Podcasting 2.0's JSON), in order; empty when it is not one.
  try:
    let j = parseJson(text)
    for c in j{"chapters"}:
      if c{"toc"}.getBool(true):           # (a chapter kept out of the list: toc false)
        result.add Chapter(start: c{"startTime"}.getFloat(c{"startTime"}.getInt.float),
                           title: c{"title"}.getStr, url: c{"url"}.getStr, image: c{"img"}.getStr)
  except CatchableError:
    discard

proc transcriptText*(text: string): string =
  ## An episode's transcript as text to read: WebVTT's and SubRip's cue
  ## numbers and times left out, the lines of a speaker joined; HTML as
  ## `plainText`; anything else as it is.
  let t = text.strip
  if t.startsWith("<"): return plainText(t)
  var o = ""
  var para = ""
  for raw in t.splitLines:
    let l = raw.strip
    if l.len == 0 or l == "WEBVTT" or l.startsWith("NOTE") or "-->" in l or
       l.allCharsInSet(Digits):
      if l.len == 0 and para.len > 0:
        o.add para & "\n"
        para = ""
      continue
    # (a voice tag: "<v Sultan>Hello" as "Sultan: Hello")
    var line = l
    if line.startsWith("<v ") and '>' in line:
      let e = line.find('>')
      line = line[3 ..< e] & ": " & line[e + 1 .. ^1]
    para.add (if para.len > 0: " " else: "") & line.replace("</v>", "")
  if para.len > 0: o.add para & "\n"
  result = o.strip
