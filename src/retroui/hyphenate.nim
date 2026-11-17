## Hyphenation: where a word may be broken at the end of a line, by Frank
## Liang's method with the patterns TeX uses (from hyph-utf8, read when the
## program is built, each with its notice at its top): American English
## (Gerard Kuiken's, `vendor/hyph-en-us.tex`), French (`hyph-fr.tex`),
## German, the reformed spelling of 2006 (`hyph-de-1996.tex`), Spanish (`hyph-es.tex`),
## Italian (`hyph-it.tex`), Portuguese (`hyph-pt.tex`) and Dutch
## (`hyph-nl.tex`). A word of letters only (accented ones too; French and
## Italian an apostrophe in it as well: "l'homme"); as many letters kept
## before a break and after as each language's patterns ask (English two
## and three, Portuguese two and three, the others two and two).
##
## - `hyphenPoints`: the places in a word a hyphen may go (after which
##   letter).
## - `hyphenated`: the word with them shown ("hy-phen-ation").
## - `hyphenLanguages`: the languages there are patterns for ("en", "fr"...).
##
## `retroui/textengine` breaks a paragraph's words with it when its
## `ParaStyle.hyphenate` is on (Paragraph > Hyphenate), in each word's
## language (`CharStyle.lang`, the Character panel's Language).
##
## .. code-block:: nim
##   import retroui/hyphenate
##   echo hyphenated("typesetting")              # type-set-ting
##   echo hyphenated("Silbentrennung", lang = "de")  # Sil-ben-tren-nung
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, tables]
import unpacking
import std/unicode except strip, splitWhitespace

const
  hyphenLanguages* = ["en", "fr", "de", "es", "it", "pt", "nl"]
    ## The languages words can be hyphenated in (ISO 639-1 codes; "en": American English,
    ## "de": German's reformed spelling)
  sources = [staticRead("vendor/hyph-en-us.tex.z"), staticRead("vendor/hyph-fr.tex.z"),
             staticRead("vendor/hyph-de-1996.tex.z"), staticRead("vendor/hyph-es.tex.z"),
             staticRead("vendor/hyph-it.tex.z"), staticRead("vendor/hyph-pt.tex.z"),
             staticRead("vendor/hyph-nl.tex.z")]
    # (each file packed with LZMA, `tools/packlzma.py vendor/hyph-*.tex`: a third of the size
    # in a program; unpacked the first time a word in its language is hyphenated)
  mins = [(2, 3), (2, 2), (2, 2), (2, 2), (2, 2), (2, 3), (2, 2)]
    # (the letters kept before a break and after it, as each language's patterns ask)

proc parseTex(src: string): tuple[pats: seq[string]; exc: seq[string]] =
  ## (the \patterns{...} and \hyphenation{...} of a TeX patterns file)
  var mode = 0
  for raw in src.splitLines:
    var line = raw
    let c = line.find('%')
    if c >= 0: line = line[0 ..< c]
    line = line.strip
    if line.len == 0: continue
    if line.startsWith("\\patterns{"):
      mode = 1
      line = line["\\patterns{".len .. ^1]
    elif line.startsWith("\\hyphenation{"):
      mode = 2
      line = line["\\hyphenation{".len .. ^1]
    if mode == 0: continue
    var ended = false
    if '}' in line:
      line = line[0 ..< line.find('}')]
      ended = true
    for w in line.splitWhitespace:
      if mode == 1: result.pats.add w else: result.exc.add w
    if ended: mode = 0

type Hyphenator = object
  pats: Table[string, seq[uint8]]   # letters (UTF-8) -> their values (one more than the letters)
  exc: Table[string, seq[int]]      # a word the patterns get wrong -> its places (in letters)
  longest: int                      # (letters)
  apostrophe: bool                  # (its patterns have the apostrophe as a letter)

proc build(src: string): Hyphenator =
  let (pats, exc) = parseTex(src)
  for p in pats:
    var letters = ""
    var vals = @[0'u8]
    var n = 0
    for r in p.runes:
      if r.int in ord('0') .. ord('9'): vals[^1] = uint8(r.int - ord('0'))
      else:
        letters.add r
        vals.add 0
        inc n
    result.pats[letters] = vals
    result.longest = max(result.longest, n)
    if '\'' in letters: result.apostrophe = true
  for e in exc:
    var w = ""
    var at: seq[int]
    var n = 0
    for r in e.runes:
      if r == Rune('-'): at.add n
      else:
        w.add r
        inc n
    result.exc[w] = at

var hys: array[hyphenLanguages.len, Hyphenator]
var built: array[hyphenLanguages.len, bool]

proc langIndex(lang: string): int =
  ## (the patterns for a language tag: "fr", "fr-FR", "de_DE", "German"...; English's when
  ## there are none)
  let l = lang.toLowerAscii
  if l.len >= 2:
    let k = hyphenLanguages.find(l[0 .. 1])
    if k >= 0: return k
  for (name, k) in [("french", 1), ("german", 2), ("deutsch", 2), ("spanish", 3), ("español", 3),
                    ("italian", 4), ("portuguese", 5), ("dutch", 6), ("nederlands", 6)]:
    if l.startsWith(name): return k
  0

proc hasPatterns*(lang: string): bool =
  ## Words in `lang` ("fr", "de-DE"...) are hyphenated with patterns of its own (not English's).
  let l = lang.toLowerAscii
  l.startsWith("en") or langIndex(lang) != 0

proc hyphenPoints*(word: string; left = -1; right = -1; lang = "en"): seq[int] =
  ## Where `word` (UTF-8 letters) may be broken: the number of letters before each place
  ## ("table": @[2] for "ta-ble"). Nothing for a word shorter than `left` + `right` (-1: as the
  ## language's patterns ask), or with anything but letters in it. `lang`: its language
  ## (`hyphenLanguages`; another: English's patterns).
  let li = langIndex(lang)
  let left = if left < 0: mins[li][0] else: left
  let right = if right < 0: mins[li][1] else: right
  {.cast(gcsafe).}:
    if not built[li]:
      hys[li] = build(unpackBytes(sources[li]))
      built[li] = true
    let hy = addr hys[li]
    var letters: seq[string]
    for r in word.runes:
      var r = r
      if r == Rune(0x2019): r = Rune('\'')        # (a typographer's apostrophe: the patterns' own)
      if r == Rune('\''):
        if not hy.apostrophe: return
      elif not r.isAlpha: return
      letters.add $r.toLower
    let n = letters.len
    if n < left + right: return
    let w = letters.join
    if w in hy.exc:
      for p in hy.exc[w]:
        if p >= left and p <= n - right: result.add p
      return
    let s = @["."] & letters & @["."]
    var vals = newSeq[uint8](s.len + 1)
    for i in 0 ..< s.len:
      var key = ""
      for m in 1 .. min(hy.longest, s.len - i):
        key.add s[i + m - 1]
        let v = hy.pats.getOrDefault(key)
        if v.len == 0: continue
        for k, x in v:
          if x > vals[i + k]: vals[i + k] = x
    # (vals[i] is between s[i-1] and s[i]: in the word, after letter p is vals[p + 1])
    for p in left .. n - right:
      if (vals[p + 1] and 1) == 1 and letters[p - 1] != "'" and letters[p] != "'": result.add p

proc hyphenated*(word: string; mark = "-"; lang = "en"): string =
  ## `word` with its hyphenation places shown ("hy-phen-ation").
  let pts = hyphenPoints(word, lang = lang)
  var last = 0
  var i = 0
  for r in word.runes:
    if last < pts.len and i == pts[last]:
      result.add mark
      inc last
    result.add r
    inc i
