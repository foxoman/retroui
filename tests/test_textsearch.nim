## Tests of Find and Change (retroui/textsearch): patterns as GREP writes them -- digits
## (Arabic-Indic too), words, spaces, classes, groups, either-or, counts, the fewest, a line's
## start and end, word edges -- found in characters, not bytes; changes with their groups,
## each text keeping its styles; plain words in any case or as whole words; a story editor's
## changes keeping the styles of what did not change; a pattern that cannot be read refused.

import std/strutils except strip
import std/unicode except strip
import retroui/[textengine, textsearch]

proc all(p, s: string; ic = false): seq[string] =
  let cps = block:
    var c: seq[int]
    for r in s.toRunes: c.add int(r)
    c
  for m in compilePattern(p, ic).findAll(s):
    var w = ""
    for k in m.a ..< m.b: w.add $Rune(cps[k])
    result.add w

block patterns:
  doAssert all(r"\d+", "a 12 b 345 ٦٧") == @["12", "345", "٦٧"]
  doAssert all(r"\w+", "one, two-3 كلمة") == @["one", "two", "3", "كلمة"]
  doAssert all(r"[aeiou]", "Retro") == @["e", "o"]
  doAssert all(r"[^a-z ]", "abc DEF") == @["D", "E", "F"]
  doAssert all(r"colou?r", "color colour colr") == @["color", "colour"]
  doAssert all(r"(cat|dog)s?", "cats, a dog, catalog") == @["cats", "dog", "cat"]
  doAssert all(r"\bcat\b", "cats, a cat, catalog") == @["cat"]
  doAssert all(r"\d{3}-\d{4}", "555-1234 55-12345") == @["555-1234"]
  doAssert all(r"a.*?b", "axxbyyb") == @["axxb"] and all(r"a.*b", "axxbyyb") == @["axxbyyb"]
  doAssert all(r"^\w+", "one two\nthree four") == @["one", "three"]
  doAssert all(r"\w+$", "one two\nthree four") == @["two", "four"]
  doAssert all(r"CAT", "cat Cat", ic = true) == @["cat", "Cat"]
  doAssert all(r"\s+", "a \t b") == @[" \t "]
  doAssert all(r"x{2,3}", "x xx xxxx") == @["xx", "xxx"]
  for bad in ["(abc", "abc)", "[abc", "*a", "a{3,1}"]:
    var refused = false
    try: discard compilePattern(bad)
    except PatternError: refused = true
    doAssert refused, bad

block changesKeepStyles:
  var st = defaultStyle()
  var red = st
  red.color = 0xFFFF0000'u32
  var t = newText("Call ", st)
  t.spans.add TextSpan(text: "555-1234", style: red)
  t.spans.add TextSpan(text: " or 555-9876 today.", style: st)
  doAssert t.changeIn(r"(\d{3})-(\d{4})", "$2/$1", patterns = true) == 2
  doAssert t.plainText == "Call 1234/555 or 9876/555 today.", t.plainText
  doAssert t.styleAt(6).color == 0xFFFF0000'u32, "the change in the style of what it changed"
  doAssert t.styleAt(0).color == st.color and t.styleAt(t.runeLen - 1).color == st.color
  # plain words: any case, whole words
  var w = newText("The cat and the Cat; concatenate.")
  doAssert w.findIn("cat").len == 3 and w.findIn("cat", matchCase = true).len == 2
  doAssert w.changeIn("cat", "dog", wholeWord = true) == 2
  doAssert w.plainText == "The dog and the dog; concatenate."
  # Arabic
  var a = newText("مرحبا بالعالم، مرحبا ١٢٣")
  doAssert a.changeIn("مرحبا", "أهلا") == 2 and a.plainText == "أهلا بالعالم، أهلا ١٢٣"
  doAssert a.findIn(r"\d+", patterns = true).len == 1

block storyEditor:
  var st = defaultStyle()
  var bold = st
  bold.fauxBold = true
  var t = newText("Hello ", st)
  t.spans.add TextSpan(text: "bold", style: bold)
  t.spans.add TextSpan(text: " world", style: st)
  t.editPlain("Hello very bold world!")
  doAssert t.plainText == "Hello very bold world!"
  var boldAt = -1
  for i in 0 ..< t.runeLen:
    if t.styleAt(i).fauxBold:
      boldAt = i
      break
  doAssert boldAt in 6 .. 11, $boldAt
  t.editPlain("Hello very bold world!")             # (the same: nothing changes)
  doAssert t.plainText == "Hello very bold world!"

block glyphsAndQueries:
  # the Glyph search: a character in a font (or any), changed to another in a font of its own
  doAssert glyphOf("é") == 0xE9 and glyphOf("U+00E9") == 0xE9 and glyphOf("0x41") == 0x41 and glyphOf("ab") == -1
  var st = defaultStyle()
  var serif = st
  serif.family = "FreeSerif"
  var t = newText("a*b*", st, 0, 0)
  t.spans.add TextSpan(text: "c*", style: serif)
  doAssert t.findGlyph(ord('*')).len == 3 and t.findGlyph(ord('*'), "FreeSerif").len == 1
  doAssert t.findGlyph(ord('*'), "freesans").len == 2, "the text's own font: FreeSans"
  var u = t
  doAssert u.changeGlyph(ord('*'), "FreeSerif", 0x2022) == 1
  doAssert u.plainText == "a*b*c\u2022"
  var v = t
  doAssert v.changeGlyph(ord('*'), "", 0x2605, toFamily = "FreeSerif") == 3
  doAssert v.plainText == "a\u2605b\u2605c\u2605"
  for sp in v.spans:
    if "\u2605" in sp.text: doAssert sp.style.family == "FreeSerif"
    if "a" in sp.text: doAssert sp.style.family != "FreeSerif"
  # the queries it comes with: each pattern read; some at work
  let qs = builtInQueries()
  doAssert qs.len >= 8
  for q in qs:
    if q.kind == qkGrep: discard compilePattern(q.what)
  proc run(name, s: string): string =
    var t = newText(s, defaultStyle(), 0, 0)
    for q in builtInQueries():
      if q.name == name: discard t.changeIn(q.what, q.change, patterns = true)
    t.plainText
  doAssert run("Multiple Space to Single Space", "a   b  c") == "a b c"
  doAssert run("Remove Trailing Whitespace", "a  \nb\t") == "a\nb"
  doAssert run("Dash to En Dash (between numbers)", "pages 10 - 12") == "pages 10\u201312"
  doAssert run("Phone Number Conversion", "(555) 123-4567") == "555.123.4567"
  doAssert run("Straight Quotes to Typographer's", "say \"hi\" now") == "say \u201Chi\u201D now"
  doAssert run("Remove Tatweel (Kashida)", "\u0645\u0640\u0640\u062D") == "\u0645\u062D"
  doAssert run("Latin Comma to Arabic Comma (after Arabic)", "\u0645, b, c") == "\u0645\u060C b, c"
  doAssert run("Multiple Return to Single Return", "a\n\n\nb") == "a\nb"
  # kept as JSON
  var mine = SavedQuery(name: "Stars", kind: qkGlyph, what: "*", change: "U+2605", toFont: "FreeSerif")
  let back = queriesFrom(queriesToJson(@[mine, qs[0]]))
  doAssert back.len == 2 and back[0].kind == qkGlyph and back[0].toFont == "FreeSerif" and back[1].what == qs[0].what

echo "test_textsearch: ok"
