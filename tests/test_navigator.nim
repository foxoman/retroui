## Retro Navigator's places (examples/navigator/places): what the Location
## box goes to, the bookmarks kept, the pages of a session.

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

echo "test_navigator: ok"
