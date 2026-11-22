## Tests of retroui/lorem, placeholder text: as many paragraphs as asked, Latin, Arabic or the two in
## turn, each of three to five sentences, neighbours not alike, the same each time; a few words; a
## cut at a sentence's end.

import std/strutils
from std/unicode import runes, runeLen, runeSubStr
import retroui/lorem

var passed = 0
template check(cond: bool; what: string) =
  doAssert cond, what
  inc passed
  echo "  ok   ", what

proc arabicLetters(s: string): int =
  for r in s.runes:
    if int32(r) in 0x0621'i32 .. 0x064A'i32: inc result

proc latinLetters(s: string): int =
  for c in s:
    if c in {'a'..'z', 'A'..'Z'}: inc result

check lorem().startsWith("Lorem ipsum dolor sit amet") and lorem().count('\n') == 0, "one paragraph of Lorem Ipsum"
check lorem(0).count('\n') == 0 and lorem(0).len > 0, "none asked: one"
let five = lorem(5).split('\n')
check five.len == 5, "five paragraphs"
var sentencesOk = true
for p in five:
  let n = p.count(". ")  + 1
  if n < 3 or n > 5: sentencesOk = false
check sentencesOk, "each of three to five sentences"
var apart = true
for i in 1 ..< 30:
  if lorem(31).split('\n')[i] == lorem(31).split('\n')[i - 1]: apart = false
check apart, "no two together alike (30 paragraphs)"
check lorem(7) == lorem(7), "the same each time"

let ar = lorem(3, loremArabic)
check ar.split('\n').len == 3 and arabicLetters(ar) > 200 and latinLetters(ar) == 0, "Arabic: three paragraphs, no Latin"
check "١٢" in lorem(16, loremArabic), "Arabic: Arabic-Indic digits in it"

let both = lorem(4, loremBoth).split('\n')
check both.len == 4 and arabicLetters(both[0]) > 0 and latinLetters(both[0]) == 0 and
      latinLetters(both[1]) > 0 and arabicLetters(both[1]) == 0 and arabicLetters(both[2]) > 0,
      "both: Arabic, Latin, Arabic, Latin"
check both[1] == loremParagraph(0) and both[2] == loremParagraph(1, loremArabic), "both: each language's own order"

check loremWords(3) == "Lorem ipsum dolor", "three words"
let aw = loremWords(4, loremArabic)
check aw.splitWhitespace.len == 4 and arabicLetters(aw) > 0 and "،" notin aw and not aw.endsWith("."),
      "Arabic words, no stops: " & aw

let t = lorem(2)
let cut = loremSentenceEnd(t, 100)
check cut > 0 and cut <= 100 and t.runeSubStr(0, cut).endsWith("."), "cut at a sentence's end before 100"
check loremSentenceEnd(t, 5) == -1, "no sentence ended: -1"
let ta = lorem(1, loremArabic)
let ca = loremSentenceEnd(ta, ta.runeLen)
check ca == ta.runeLen, "Arabic: its last stop the end"

echo "test_lorem: ", passed, " passed"
