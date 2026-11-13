## Retro Navigator's places (examples/navigator/places): what the Location
## box goes to, the bookmarks kept, the pages of a session and the history,
## what the Location box suggests, the shield's settings, its script and
## its block list, the looks of pages.

import std/[os, strutils]
import retroui/platform
import ../examples/navigator/places

block location:
  let dd = Searches[0][1]
  doAssert locationUrl("") == ""
  doAssert locationUrl("  nim-lang.org ") == "https://nim-lang.org"
  doAssert locationUrl("http://example.com/a?b=1") == "http://example.com/a?b=1"
  doAssert locationUrl("https://example.com") == "https://example.com"
  doAssert locationUrl("about:welcome") == "about:welcome"
  doAssert locationUrl("localhost:8080/app") == "https://localhost:8080/app"
  doAssert locationUrl("192.168.1.1/admin") == "https://192.168.1.1/admin"
  doAssert locationUrl("news.ycombinator.com/item?id=1") == "https://news.ycombinator.com/item?id=1"
  # words, a version, a name with no place: searched for
  doAssert locationUrl("retro nim ui") == dd & "retro+nim+ui"
  doAssert locationUrl("v1.2") == dd & "v1.2"
  doAssert locationUrl("nim") == dd & "nim"
  doAssert locationUrl("what is 2+2?") == dd & "what+is+2%2B2%3F"
  doAssert locationUrl("القرآن") == dd & "%D8%A7%D9%84%D9%82%D8%B1%D8%A2%D9%86"
  doAssert locationUrl("nim", Searches[3][1]).startsWith("https://en.wikipedia.org/")
  # a file that is there
  let f = getTempDir() / "navigator-test.html"
  writeFile(f, "<p>hi</p>")
  doAssert locationUrl(f) == (if f[0] == '/': "file://" & f else: "file:///" & f.replace('\\', '/')),
    locationUrl(f)
  removeFile(f)
  doAssert locationUrl("/no/such/file.html") == dd & "%2Fno%2Fsuch%2Ffile.html"

block secure:
  doAssert isSecure("https://example.com") and isSecure("about:welcome")
  doAssert not isSecure("http://example.com")

block bookmarksKept:
  var s: Settings
  doAssert bookmarks(s) == @StartBookmarks, "the first start's"
  var marks: seq[Place]
  doAssert marks.addBookmark(Place(title: "A\tB", url: "https://a.org"))
  doAssert not marks.addBookmark(Place(title: "again", url: "https://a.org")), "once"
  doAssert marks.addBookmark(Place(title: "", url: "https://b.org"))
  s.setBookmarks(marks)
  let back = bookmarks(s)
  doAssert back.len == 2 and back[0] == Place(title: "A B", url: "https://a.org") and
           back[1].title == "https://b.org", $back
  s.setBookmarks(@[marks[1]])
  doAssert bookmarks(s).len == 1 and not s.hasKey("bookmark.2"), "a removed one goes"
  s.setBookmarks(@[])
  doAssert bookmarks(s).len == 0, "none kept: none (not the first start's)"

block session:
  var pages: seq[Place]
  for i in 1 .. 20: pages.visit(Place(title: $i, url: "https://x.org/" & $i))
  doAssert pages.len == 15 and pages[0].title == "20"
  pages.visit(Place(title: "again", url: "https://x.org/18"))
  doAssert pages.len == 15 and pages[0].title == "again" and pages[1].title == "20"

block settings:
  var s: Settings
  doAssert homeOf(s) == "about:welcome" and searchOf(s) == 0
  s["search"] = "x"
  doAssert searchOf(s) == 0
  s["search"] = "9"
  doAssert searchOf(s) == Searches.high

block secureUrls:
  doAssert secureUrl("http://example.com/a?b=1") == "https://example.com/a?b=1"
  doAssert secureUrl("HTTP://Example.com") == "https://Example.com"
  doAssert secureUrl("https://example.com") == "https://example.com"
  doAssert secureUrl("about:welcome") == "about:welcome"
  for local in ["http://localhost:8080/x", "http://192.168.1.1/admin", "http://10.0.0.2",
                "http://172.20.1.1", "http://printer.local/", "http://127.0.0.1:3000"]:
    doAssert secureUrl(local) == local, local
  doAssert secureUrl("http://172.32.1.1") == "https://172.32.1.1", "not a local network"
  doAssert hostOf("https://WWW.Example.com:8080/a") == "www.example.com"
  doAssert hostOf("about:welcome") == ""

block adHosts:
  doAssert isAdHost("doubleclick.net") and isAdHost("securepubads.g.doubleclick.net")
  doAssert isAdHost("WWW.Google-Analytics.com")
  doAssert isAdHost("mc.yandex.ru") and not isAdHost("yandex.ru"), "the tracker, not the search"
  doAssert not isAdHost("example.com") and not isAdHost("notdoubleclick.net")

block shieldSettings:
  var s: Settings
  doAssert shieldsOf(s) == DefaultShields
  s.setShields({shNoAutoplay})
  doAssert shieldsOf(s) == {shNoAutoplay} and s["blockAds"] == "off"
  doAssert adsAllowedOf(s).len == 0 and not adsAllowedOn(s, "news.example.com")
  s.allowAds("Example.com", true)
  s.allowAds("example.com", true)
  doAssert adsAllowedOf(s) == @["example.com"], "once"
  doAssert adsAllowedOn(s, "news.example.com") and not adsAllowedOn(s, "example.org")
  doAssert not adsAllowedOn(s, ""), "no host: no site"
  s.allowAds("example.com", false)
  doAssert adsAllowedOf(s).len == 0

block script:
  let all = startScript({shBlockAds, shNoTrack, shHttps, shNoAutoplay, shPreload}, ["a.org"])
  let none = startScript({})
  # links into a new tab: always; the rest when asked
  for js in [all, none]:
    doAssert js.startsWith("(function(){") and js.endsWith("})();")
    doAssert "'tab:'" in js and "'newtab:'" in js and "var up=" in js
  doAssert "var up=1" in all and "var up=0" in none
  doAssert "globalPrivacyControl" in all and "globalPrivacyControl" notin none
  doAssert "doubleclick.net" in all and "doubleclick.net" notin none
  doAssert "\"a.org\"" in all, "the sites ads are allowed on"
  doAssert "HTMLMediaElement" in all and "prefetch" in all
  doAssert "HTMLMediaElement" notin none and "prefetch" notin none
  doAssert "</script" notin all.toLowerAscii, "nothing that ends a script tag"

block historyKept:
  var h: seq[Place]
  for i in 1 .. 5: h.visit(Place(title: "P\t" & $i, url: "https://x.org/" & $i), HistoryKept)
  let back = readHistory(historyText(h))
  doAssert back.len == 5 and back[0] == Place(title: "P 5", url: "https://x.org/5"), $back
  doAssert readHistory("no tab here\n\tjust an address\nT\thttps://a.org\n").len == 2
  var many: seq[Place]
  for i in 1 .. HistoryKept + 50: many.add Place(title: $i, url: "https://y.org/" & $i)
  doAssert readHistory(historyText(many)).len == HistoryKept

block suggested:
  let s = suggestions([Place(url: "https://b.org"), Place(url: "https://a.org"),
                       Place(url: "about:blank")],
                      [Place(url: "https://a.org"), Place(url: "https://c.org")])
  doAssert s == @["https://b.org", "https://a.org", "https://c.org"], $s

block blockLists:
  let hosts = parseBlockList("""
# a hosts file
0.0.0.0 ads.example.com
127.0.0.1 localhost
0.0.0.0 track.example.net more.example.net   # two on a line
! an ad blocker's
||cdn.adnet.io^
||cdn.adnet.io^$third-party
||example.org/ads/*
[Adblock Plus 2.0]
plain.example.com
not a host
""")
  doAssert hosts == @["ads.example.com", "track.example.net", "more.example.net", "cdn.adnet.io",
                      "plain.example.com"], $hosts
  doAssert AdHosts.len > 200 and AdPatterns.len > 5
  for p in AdPatterns: doAssert p.startsWith("*://"), p
  doAssert "ytp-ad-skip-button" in startScript({shBlockAds}) and "ad-showing" in startScript({shBlockAds})

block looks:
  let c = ClassicColors
  doAssert lookScript(lkModern, c, false) == ""
  let bars = lookScript(lkModern, c, true)
  doAssert "::-webkit-scrollbar" in bars and "scrollbar-color:auto" in bars and
           "Times New Roman" notin bars
  let classic = lookScript(lkClassic, c, false)
  doAssert "Times New Roman" in classic and "border-radius:0" in classic and
           "MutationObserver" notin classic, "Classic: the site's scripts run"
  let plain = lookScript(lkPlain, c, true)
  doAssert "MutationObserver" in plain and "SCRIPT" in plain and "NOSCRIPT" in plain and
           "data-src" in plain
  for js in [bars, classic, plain]:
    doAssert js.startsWith("(function(){") and js.endsWith("})();") and
             "</script" notin js.toLowerAscii
  var s: Settings
  doAssert lookOf(s) == lkModern
  s["look"] = "plain"
  doAssert lookOf(s) == lkPlain
  s["look"] = "nonsense"
  doAssert lookOf(s) == lkModern

echo "test_navigator: ok"
