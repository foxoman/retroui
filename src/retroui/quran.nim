## The Quran's text for typesetting: read from a Tanzil text file (tanzil.net/download -- the
## Uthmani or simple text, "Text (with aya numbers)": a line `sura|aya|text` for each ayah), kept
## as it is; looked up by sura and ayah, searched with Arabic matched as written either way
## (harakat, tatweel, hamza's seats, ى/ي, ة/ه: `retroui/textsearch`'s `arabicFolded`); a passage
## put together with the end-of-ayah sign and its number after each ayah; a text typed by hand
## checked against it, letter by letter and mark by mark. Each ayah's number in ornate brackets
## (﴿١﴾, which most Arabic fonts have) or after the end-of-ayah sign (۝١: a Quran font's ornament).
##
## .. code-block:: nim
##   let q = loadQuran(dataDir() / "quran-uthmani.txt")
##   echo suraName(1), ": ", q.passage(1, 1, 7)
##   for (s, a) in q.search("الحمد لله"): echo s, ":", a
##
## Nothing of the text comes with the kit: the user downloads it from Tanzil (its terms: copied
## verbatim, never changed, its source named), and `quranUrl` is where Tanzil hands it out.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, os]
import std/unicode except strip
import textsearch

const
  quranUrl* = "https://tanzil.net/pub/download/index.php?marks=true&sajdah=true&rub=true&tatweel=true" &
              "&quranType=uthmani&outType=txt-2&agree=true"
    ## Where Tanzil hands out its Uthmani text, a line `sura|aya|text` an ayah (what its download
    ## page's form asks for); the page itself is tanzil.net/download.
  quranFile* = "quran-uthmani.txt"
    ## The name the app keeps the downloaded text under.
  AyahEnd* = "۝"
    ## The end-of-ayah sign (۝), its number after it in Arabic-Indic digits (`ayahMark`).
  AyahOpen* = "﴿"
  AyahClose* = "﴾"
    ## The ornate brackets an ayah's number is put in (﴿١﴾), the first at its right.

  SuraNames: array[114, string] = [
    "الفاتحة", "البقرة", "آل عمران", "النساء", "المائدة", "الأنعام", "الأعراف", "الأنفال", "التوبة",
    "يونس", "هود", "يوسف", "الرعد", "إبراهيم", "الحجر", "النحل", "الإسراء", "الكهف", "مريم", "طه",
    "الأنبياء", "الحج", "المؤمنون", "النور", "الفرقان", "الشعراء", "النمل", "القصص", "العنكبوت",
    "الروم", "لقمان", "السجدة", "الأحزاب", "سبأ", "فاطر", "يس", "الصافات", "ص", "الزمر", "غافر",
    "فصلت", "الشورى", "الزخرف", "الدخان", "الجاثية", "الأحقاف", "محمد", "الفتح", "الحجرات", "ق",
    "الذاريات", "الطور", "النجم", "القمر", "الرحمن", "الواقعة", "الحديد", "المجادلة", "الحشر",
    "الممتحنة", "الصف", "الجمعة", "المنافقون", "التغابن", "الطلاق", "التحريم", "الملك", "القلم",
    "الحاقة", "المعارج", "نوح", "الجن", "المزمل", "المدثر", "القيامة", "الإنسان", "المرسلات", "النبأ",
    "النازعات", "عبس", "التكوير", "الانفطار", "المطففين", "الانشقاق", "البروج", "الطارق", "الأعلى",
    "الغاشية", "الفجر", "البلد", "الشمس", "الليل", "الضحى", "الشرح", "التين", "العلق", "القدر",
    "البينة", "الزلزلة", "العاديات", "القارعة", "التكاثر", "العصر", "الهمزة", "الفيل", "قريش",
    "الماعون", "الكوثر", "الكافرون", "النصر", "المسد", "الإخلاص", "الفلق", "الناس"]

type
  Ayah* = object
    ## One ayah: its sura (1..114), its number in it, its text as the file has it.
    sura*, aya*: int
    text*: string

  AyahEnds* = enum
    ## How `passage` ends each ayah.
    aeBrackets          ## its number in ornate brackets, ﴿١٢﴾: drawn so by most Arabic fonts
    aeSign              ## the end-of-ayah sign and its number, ۝١٢: one ornament in a Quran font
                        ## (others draw a frame beside the number)
    aeNone              ## nothing

  Quran* = object
    ## The text read (`parseQuran`, `loadQuran`): its ayat in order; where each sura starts.
    ayat*: seq[Ayah]
    starts: array[116, int]      # (the first ayah of each sura, 1-based; 115: the end)
    folded: seq[string]          # (each ayah as Arabic is matched either way)

proc suraName*(n: int): string =
  ## Sura `n`'s name in Arabic ("" past 1..114).
  if n in 1 .. 114: SuraNames[n - 1] else: ""

proc arabicDigits*(n: int): string =
  ## `n` in Arabic-Indic digits (١٢٣).
  for c in $n: result.add $Rune(0x0660 + ord(c) - ord('0'))

proc ayahMark*(n: int; ends = aeBrackets): string =
  ## The end of ayah `n`: its number in ornate brackets (﴿١٢﴾), or the end-of-ayah sign and its
  ## number (۝١٢, which a Quran font draws as one ornament); "" for `aeNone`.
  case ends
  of aeBrackets: AyahOpen & arabicDigits(n) & AyahClose
  of aeSign: AyahEnd & arabicDigits(n)
  of aeNone: ""

proc parseQuran*(data: string): Quran =
  ## A Tanzil text file's ayat (`sura|aya|text` lines; its notes, after `#`, and empty lines left
  ## out). Raises ValueError when no line is an ayah.
  for raw in data.splitLines:
    let line = raw.strip(chars = {' ', '\t', '\r', '\xEF', '\xBB', '\xBF'})
    if line.len == 0 or line[0] == '#': continue
    let p = line.split('|', 2)
    if p.len < 3: continue
    try:
      let s = parseInt(p[0].strip)
      let a = parseInt(p[1].strip)
      if s notin 1 .. 114 or a < 1: continue
      result.ayat.add Ayah(sura: s, aya: a, text: p[2].strip)
    except ValueError: discard
  if result.ayat.len == 0: raise newException(ValueError, "not a Quran text: no line `sura|aya|text`")
  for i in 0 .. 115: result.starts[i] = -1
  for i, ay in result.ayat:
    if result.starts[ay.sura] < 0: result.starts[ay.sura] = i
    result.folded.add arabicFolded(ay.text)
  result.starts[115] = result.ayat.len

proc loadQuran*(path: string): Quran =
  ## The text of a Tanzil file (`parseQuran`). Raises IOError, ValueError.
  parseQuran(readFile(path))

proc suras*(q: Quran): int =
  ## How many suras the text has (114 for the whole Quran; fewer in a part).
  for s in 1 .. 114:
    if q.starts[s] >= 0: inc result

proc ayatIn*(q: Quran; sura: int): int =
  ## How many ayat sura `sura` has in the text (0: not in it).
  if sura notin 1 .. 114 or q.starts[sura] < 0: return 0
  var i = q.starts[sura]
  while i < q.ayat.len and q.ayat[i].sura == sura:
    inc result
    inc i

proc indexOf(q: Quran; sura, aya: int): int =
  if sura notin 1 .. 114 or q.starts[sura] < 0: return -1
  let i = q.starts[sura] + aya - 1
  if i >= 0 and i < q.ayat.len and q.ayat[i].sura == sura and q.ayat[i].aya == aya: return i
  for k in q.starts[sura] ..< q.ayat.len:
    if q.ayat[k].sura != sura: break
    if q.ayat[k].aya == aya: return k
  -1

proc ayah*(q: Quran; sura, aya: int): string =
  ## The text of ayah `aya` of sura `sura` ("" when the text does not have it).
  let i = q.indexOf(sura, aya)
  if i >= 0: q.ayat[i].text else: ""

proc passage*(q: Quran; sura, first, last: int; ends = aeBrackets): string =
  ## Ayat `first` .. `last` of sura `sura`, a space between them, each followed by its number
  ## (`ayahMark`: in ornate brackets, after the end-of-ayah sign, or none).
  for a in max(1, first) .. last:
    let t = q.ayah(sura, a)
    if t.len == 0: continue
    if result.len > 0: result.add ' '
    result.add t
    if ends != aeNone: result.add " " & ayahMark(a, ends)

proc search*(q: Quran; words: string; max = 200): seq[tuple[sura, aya: int]] =
  ## The ayat with `words` in them, in order, Arabic matched as written either way -- with or
  ## without harakat, tatweel, hamza's seats, ى/ي, ة/ه --, at most `max`.
  let w = arabicFolded(words).strip
  if w.len == 0: return
  for i, f in q.folded:
    if w in f:
      result.add (q.ayat[i].sura, q.ayat[i].aya)
      if result.len >= max: break

proc checkTyped*(q: Quran; typed: string; sura, first, last: int): seq[tuple[a, b: int]] =
  ## Where `typed` -- ayat `first` .. `last` of sura `sura` typed by hand, ayah numbers and their
  ## signs in it or not -- differs from the text: runs of its characters (`a` ..< `b`, counted in
  ## runes) whose letters or marks are not the text's there, in order. Spaces and tatweel do not
  ## count; a word left out shows where it should be (an empty run). Empty: the same.
  proc keep(c: int): bool =
    not (c == 0x0640 or c == 0x06DD or c == 0xFD3E or c == 0xFD3F or c in 0x0660 .. 0x0669 or c in 0x06F0 .. 0x06F9 or
         c in ord('0') .. ord('9') or Rune(c).isWhiteSpace or c in [0x06DE, 0x06E9])
  var src: seq[int]
  for r in q.passage(sura, first, last, aeNone).runes:
    if keep(int(r)): src.add int(r)
  var tc: seq[int]
  var at: seq[int]                 # (where each kept character of `typed` is, in runes)
  var n = 0
  for r in typed.runes:
    if keep(int(r)):
      tc.add int(r)
      at.add n
    inc n
  # (the two lined up: the longest common run of characters, an edit at a time between)
  let m = tc.len
  let k = src.len
  if m * k > 40_000_000:
    # (too long to line up: the first place they part)
    var i = 0
    while i < min(m, k) and tc[i] == src[i]: inc i
    if i < m or i < k:
      let here = if i < m: at[i] else: n
      result.add (here, n)
    return
  var dp = newSeq[int32]((m + 1) * (k + 1))
  for i in countdown(m - 1, 0):
    for j in countdown(k - 1, 0):
      dp[i * (k + 1) + j] = if tc[i] == src[j]: dp[(i + 1) * (k + 1) + j + 1] + 1
                            else: max(dp[(i + 1) * (k + 1) + j], dp[i * (k + 1) + j + 1])
  var i = 0
  var j = 0
  var runA = -1
  var runB = -1
  template close() =
    if runA >= 0:
      result.add (runA, runB)
      runA = -1
  while i < m or j < k:
    if i < m and j < k and tc[i] == src[j]:
      close()
      inc i
      inc j
    elif j < k and (i >= m or dp[i * (k + 1) + j + 1] >= dp[(i + 1) * (k + 1) + j]):
      # (the text has a character `typed` lacks: an empty run where it should be)
      let here = if i < m: at[i] else: n
      if runA < 0: (runA, runB) = (here, here)
      inc j
    else:
      # (`typed` has a character the text does not)
      if runA < 0: runA = at[i]
      runB = at[i] + 1
      inc i
  close()
