## Retro Navigator's places: what the Location box takes to an address, the
## bookmarks, the pages of this session, the shield's settings, and the
## settings they are kept in.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, uri, sequtils]
import retroui/platform
import shield
export shield

type
  Place* = object
    ## A page: its title and its address.
    title*, url*: string

const
  SettingsName* = "navigator"
    ## The settings Retro Navigator keeps (the look with them).
  Searches* = [("DuckDuckGo", "https://duckduckgo.com/?q=", "https://duckduckgo.com"),
               ("Google", "https://www.google.com/search?q=", "https://www.google.com"),
               ("Bing", "https://www.bing.com/search?q=", "https://www.bing.com"),
               ("Wikipedia", "https://en.wikipedia.org/w/index.php?search=",
                "https://www.wikipedia.org")]
    ## The search engines a Location that is not an address goes to: the
    ## name, the address the words are added to, the home page.
  StartBookmarks* = [
    Place(title: "Retro Nim UI", url: "https://github.com/foxoman/retroui"),
    Place(title: "Nim", url: "https://nim-lang.org"),
    Place(title: "Wikipedia", url: "https://www.wikipedia.org"),
    Place(title: "Hacker News", url: "https://news.ycombinator.com")]
    ## The bookmarks of a first start.

proc looksLikeHost(s: string): bool =
  ## "example.com", "localhost:8080/x", "192.168.1.1/admin": a place to go
  ## to, not words to search for.
  if s.len == 0 or ' ' in s: return false
  let host = s.split({'/', '?', '#'}, 1)[0]
  let name = host.split(':', 1)[0]
  if name == "localhost": return true
  if name.len < 3 or name[0] == '.' or name[^1] == '.' or '.' notin name: return false
  for c in name:
    if c in {'"', '<', '>', '\\', '^', '`', '{', '|', '}', '@'}: return false
  let parts = name.split('.')
  if parts.len == 4 and parts.allIt(it.len in 1 .. 3 and it.allCharsInSet(Digits)):
    return true                                     # (an IPv4 address)
  let top = parts[^1]
  top.len >= 2 and not top.allCharsInSet(Digits)    # (a name ends in letters: "v1.2" is searched)

proc locationUrl*(typed: string; search = Searches[0][1]): string =
  ## The address the Location box goes to for what was typed: an address as
  ## it is ("https://...", "file://...", "about:..."), a host with
  ## "https://" before it, a file or folder that is there as "file://", and
  ## anything else searched for with `search` (the query added to it).
  let t = typed.strip
  if t.len == 0: return ""
  let lower = t.toLowerAscii
  if "://" in t or lower.startsWith("about:") or lower.startsWith("mailto:") or
     lower.startsWith("data:"):
    return t
  if t[0] in {'/', '~'} or (t.len > 2 and t[1] == ':' and t[2] in {'\\', '/'}):
    let p = expandTilde(t)
    if fileExists(p) or dirExists(p):
      return if p[0] == '/': "file://" & p else: "file:///" & p.replace('\\', '/')
  if looksLikeHost(t): return "https://" & t
  search & encodeUrl(t, usePlus = true)

proc isSecure*(url: string): bool =
  ## The page came over an encrypted connection (https), or from this
  ## computer.
  let l = url.toLowerAscii
  l.startsWith("https://") or l.startsWith("file:") or l.startsWith("about:") or
    l.startsWith("html:") or l.startsWith("app://") or l.len == 0

proc hostOf*(url: string): string =
  ## The host of `url` ("www.example.com"), lower case; "" for none.
  try: parseUri(url).hostname.toLowerAscii
  except CatchableError: ""

proc secureUrl*(url: string): string =
  ## `url` over an encrypted connection: "http://" made "https://", not on
  ## this computer or the local network (`isLocalHost`).
  if url.toLowerAscii.startsWith("http://") and not isLocalHost(hostOf(url)):
    "https://" & url[7 .. ^1]
  else: url

proc visit*(pages: var seq[Place]; p: Place; keep = 15) =
  ## `p` first in the pages of this session (once), `keep` of them.
  if p.url.len == 0: return
  for i in countdown(pages.high, 0):
    if pages[i].url == p.url: pages.delete(i)
  pages.insert(p, 0)
  if pages.len > keep: pages.setLen(keep)

proc bookmarks*(s: Settings): seq[Place] =
  ## The bookmarks kept in `s` (`StartBookmarks` when none were kept yet).
  if not s.hasKey("bookmarks"): return @StartBookmarks
  for i in 1 .. 1000:
    let v = s.getOrDefault("bookmark." & $i, "")
    if v.len == 0: break
    let tab = v.find('\t')
    if tab > 0: result.add Place(title: v[0 ..< tab], url: v[tab + 1 .. ^1])

proc setBookmarks*(s: var Settings; marks: openArray[Place]) =
  ## Keeps `marks` in `s` as its bookmarks.
  var i = 1
  while s.hasKey("bookmark." & $i):
    s.del("bookmark." & $i)
    inc i
  for k, p in marks:
    let title = if p.title.len > 0: p.title.replace('\t', ' ') else: p.url
    s["bookmark." & $(k + 1)] = title & "\t" & p.url
  s["bookmarks"] = $marks.len

proc addBookmark*(marks: var seq[Place]; p: Place): bool {.discardable.} =
  ## `p` added at the end of `marks`, unless its address is there already.
  if p.url.len == 0: return false
  for m in marks:
    if m.url == p.url: return false
  marks.add p
  true

proc searchOf*(s: Settings): int =
  ## Which of `Searches` the Location box searches with.
  try: clamp(s.getOrDefault("search", "0").parseInt, 0, Searches.high)
  except ValueError: 0

proc homeOf*(s: Settings): string =
  ## The home page ("about:welcome": the welcome page).
  s.getOrDefault("home", "about:welcome")

proc shieldsOf*(s: Settings): set[Shield] =
  ## What the shield does (`DefaultShields` for those not set yet).
  for x in Shield:
    let v = s.getOrDefault($x, "")
    if v == "on" or (v.len == 0 and x in DefaultShields): result.incl x

proc setShields*(s: var Settings; on: set[Shield]) =
  for x in Shield: s[$x] = (if x in on: "on" else: "off")

proc adsAllowedOf*(s: Settings): seq[string] =
  ## The sites ads are allowed on (the shield leaves them be).
  for h in s.getOrDefault("adsAllowed", "").splitWhitespace: result.add h

proc allowAds*(s: var Settings; host: string; allowed: bool) =
  ## Ads allowed on `host` (and the sites under it), or not.
  var l = adsAllowedOf(s)
  let h = host.toLowerAscii
  l.keepItIf(it != h)
  if allowed and h.len > 0: l.add h
  s["adsAllowed"] = l.join(" ")

proc adsAllowedOn*(s: Settings; host: string): bool =
  ## The shield leaves `host` be: it is one of `adsAllowedOf` or under one.
  host.len > 0 and isAdHost(host, adsAllowedOf(s))
