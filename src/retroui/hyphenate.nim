## Hyphenation: where an English word may be broken at the end of a line,
## by Frank Liang's method with the American English patterns TeX uses
## (Gerard Kuiken's, `vendor/hyph-en-us.tex`: read when the program is
## built). A word of letters only, at least five long; two letters kept
## before a break and three after, as the patterns ask.
##
## - `hyphenPoints`: the places in a word a hyphen may go (after which
##   letter).
## - `hyphenated`: the word with them shown ("hy-phen-ation").
##
## `retroui/textengine` breaks a paragraph's words with it when its
## `ParaStyle.hyphenate` is on (Paragraph > Hyphenate).
##
## .. code-block:: nim
##   import retroui/hyphenate
##   echo hyphenated("typesetting")      # type-set-ting
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, tables]

const patternsFile = staticRead("vendor/hyph-en-us.tex")

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
  pats: Table[string, seq[uint8]]   # letters -> their values (one more than the letters)
  exc: Table[string, seq[int]]      # a word the patterns get wrong -> its places
  longest: int

proc build(): Hyphenator =
  let (pats, exc) = parseTex(patternsFile)
  for p in pats:
    var letters = ""
    var vals = @[0'u8]
    for ch in p:
      if ch in '0' .. '9': vals[^1] = uint8(ord(ch) - ord('0'))
      else:
        letters.add ch
        vals.add 0
    result.pats[letters] = vals
    result.longest = max(result.longest, letters.len)
  for e in exc:
    var w = ""
    var at: seq[int]
    for ch in e:
      if ch == '-': at.add w.len
      else: w.add ch
    result.exc[w] = at

var hy: Hyphenator
var built = false

proc hyphenPoints*(word: string; left = 2; right = 3): seq[int] =
  ## Where `word` (ASCII letters) may be broken: the number of letters before each place
  ## ("table": @[2] for "ta-ble"). Nothing for a word shorter than `left` + `right`, or with
  ## anything but letters in it.
  if word.len < left + right: return
  for ch in word:
    if ch notin {'a' .. 'z', 'A' .. 'Z'}: return
  {.cast(gcsafe).}:
    if not built:
      hy = build()
      built = true
    let w = word.toLowerAscii
    if w in hy.exc:
      for p in hy.exc[w]:
        if p >= left and p <= w.len - right: result.add p
      return
    let s = "." & w & "."
    var vals = newSeq[uint8](s.len + 1)
    for i in 0 ..< s.len:
      for n in 1 .. min(hy.longest, s.len - i):
        let v = hy.pats.getOrDefault(s[i ..< i + n])
        if v.len == 0: continue
        for k, x in v:
          if x > vals[i + k]: vals[i + k] = x
    # (vals[i] is between s[i-1] and s[i]: in the word, after letter p is vals[p + 1])
    for p in left .. w.len - right:
      if (vals[p + 1] and 1) == 1: result.add p

proc hyphenated*(word: string; mark = "-"): string =
  ## `word` with its hyphenation places shown ("hy-phen-ation").
  let pts = hyphenPoints(word)
  var last = 0
  for p in pts:
    result.add word[last ..< p] & mark
    last = p
  result.add word[last .. ^1]
