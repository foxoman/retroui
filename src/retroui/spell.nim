## Spell checking and AutoCorrect, as Outlook and Word do them while one
## writes, with the system's own checker -- nothing to install, nothing
## compiled in:
##
## - **Linux, BSD, Termux:** Hunspell (`libhunspell`, loaded at run time)
##   with the dictionaries of `/usr/share/hunspell`, `/usr/share/myspell`,
##   `~/.local/share/hunspell` and `$DICPATH`; Enchant 2 where Hunspell's
##   library is not there.
## - **Windows 8 and later:** the system's spell checker (`ISpellChecker`,
##   through COM) -- the one Office and Edge use, with the user's own
##   dictionary.
## - **macOS:** `NSSpellChecker`.
## - **Android and iOS apps:** none (the phone's keyboard corrects what is
##   typed): `spellAvailable` is false; AutoCorrect's lists still work.
##
## Each word is checked in the language of its script: an Arabic word with
## the Arabic dictionary, a Latin one with the user's language (or English),
## so a mail that mixes them is checked right. Verdicts are cached: a word
## is asked about once. Numbers, words with digits, acronyms in capitals,
## single letters, web and e-mail addresses are not checked.
##
## AutoCorrect (`autoCorrect`, which `richEdit` calls as one types) fixes
## the word just ended from Word's list in English ("teh", "dont", "(c)")
## and a careful one in Arabic ("الى", "ان شاء الله"), from the user's own
## list (`autoCorrectAdd`), from a spelling suggestion when there is only
## one near; and capitalizes sentences. Each kind can be turned off
## (`autoCorrectEnable`).
##
## .. code-block:: nim
##   import retroui/spell
##   if spellAvailable():
##     echo isMisspelled("recieve")          # true
##     echo spellSuggest("recieve")          # @["receive", ...]
##     spellAdd("Foxoman")                   # kept in the user's own dictionary
##   autoCorrectAdd("btw", "by the way")     # kept in the user's own list
##
## `RETRO_SPELL=enchant` (or `none`) in the environment chooses the checker
## on Linux, for tests.

import std/[os, strutils, tables, sets, algorithm, sequtils]
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)
when not defined(ios):
  import std/dynlib
import uirelays/services
when defined(macosx) and not defined(ios):
  import native

type
  Script = enum
    scNone, scLatin, scArabic, scHebrew, scCyrillic, scGreek, scArmenian,
    scGeorgian, scDevanagari, scBengali, scTamil, scThai, scHangul, scOther, scMixed

  Engine = enum enNone, enHunspell, enEnchant, enWindows, enMac

  Checker = ref object
    tag: string            ## the language, "en-US"
    script: Script
    h: pointer             ## the engine's own: Hunspell, EnchantDict, ISpellChecker
    toDict, fromDict: pointer  ## (Hunspell with a dictionary not in UTF-8: iconv)
    latin1: bool           ## (... in ISO 8859-1, without iconv)

const
  MaxWordBytes = 100       ## longer "words" (codes, base64) are not checked
  MaxCache = 200_000

var
  engine = enNone
  engineReady = false
  dictTags: seq[string]            ## the engine's languages, "en-US" (and their aliases)
  shownTags: seq[string]           ## ... each dictionary once (`spellLanguages`)
  dictFiles: Table[string, string] ## (Hunspell) tag -> the .aff's path, without ".aff"
  verdicts: Table[string, bool]    ## word (or language & '\x1F' & word) -> misspelled
  ignored: HashSet[string]
  userWords: HashSet[string]
  userLoaded = false
  generation = 1
  userLang = ""

type Opened = object
  checkers: Table[string, Checker] ## opened (nil: there is none for that language)
# (a checker, once opened, is the program's to its very end: kept where
# Nim's globals are not destroyed as it ends, so the system's library still
# holds its dictionary then rather than seeming to have lost it)
let opened = cast[ptr Opened](allocShared0(sizeof(Opened)))
template checkers: untyped = opened.checkers

# ---- words ----------------------------------------------------------------------------------------

proc isMark(c: int): bool =
  ## A combining mark (a vowel sign, a shadda...): part of the letter before.
  c in 0x0300 .. 0x036F or c in 0x0483 .. 0x0489 or c in 0x0591 .. 0x05BD or
    c == 0x05BF or c in 0x05C1 .. 0x05C2 or c in 0x05C4 .. 0x05C5 or c == 0x05C7 or
    c in 0x0610 .. 0x061A or c in 0x064B .. 0x065F or c == 0x0670 or
    c in 0x06D6 .. 0x06DC or c in 0x06DF .. 0x06E4 or c in 0x06E7 .. 0x06E8 or
    c in 0x06EA .. 0x06ED or c == 0x0711 or c in 0x0730 .. 0x074A or
    c in 0x08D3 .. 0x08FF or c == 0x0E31 or c in 0x0E34 .. 0x0E3A or c in 0x0E47 .. 0x0E4E or
    c in 0x1AB0 .. 0x1AFF or c in 0x1DC0 .. 0x1DFF or
    c in 0x20D0 .. 0x20FF or c in 0xFE00 .. 0xFE0F or c in 0xFE20 .. 0xFE2F

proc isDigitRune(c: int): bool =
  c in 0x30 .. 0x39 or c in 0x0660 .. 0x0669 or c in 0x06F0 .. 0x06F9 or
    c in 0x07C0 .. 0x07C9 or c in 0x0966 .. 0x096F or c in 0x09E6 .. 0x09EF or
    c in 0x0BE6 .. 0x0BEF or c in 0x0E50 .. 0x0E59 or c in 0xFF10 .. 0xFF19

proc isApostrophe(c: int): bool = c == 0x27 or c == 0x2019 or c == 0x02BC

proc isSpaceRune(c: int): bool =
  c in {0x09, 0x0A, 0x0D, 0x20, 0xA0} or c in 0x2000 .. 0x200B or
    c == 0x2028 or c == 0x2029 or c == 0x202F or c == 0x205F or c == 0x3000 or c == 0xFEFF

proc isLetter(c: int): bool =
  if c < 0x80: return c in 0x41 .. 0x5A or c in 0x61 .. 0x7A
  if isMark(c) or isDigitRune(c): return false
  if c in 0x0900 .. 0x0DFF:                  # (Indic vowel signs are letters here)
    return c != 0x0964 and c != 0x0965 and c != 0x0970
  Rune(c).isAlpha

proc scriptOf(c: int): Script =
  if c < 0x0250 or c in 0x1E00 .. 0x1EFF or c in 0x2C60 .. 0x2C7F or c in 0xA720 .. 0xA7FF or
     c in 0xFB00 .. 0xFB06 or c in 0xFF21 .. 0xFF5A: scLatin
  elif c in 0x0600 .. 0x06FF or c in 0x0750 .. 0x077F or c in 0x08A0 .. 0x08FF or
       c in 0xFB50 .. 0xFDFF or c in 0xFE70 .. 0xFEFF: scArabic
  elif c in 0x0590 .. 0x05FF or c in 0xFB1D .. 0xFB4F: scHebrew
  elif c in 0x0400 .. 0x052F or c in 0x1C80 .. 0x1C8F or c in 0x2DE0 .. 0x2DFF or
       c in 0xA640 .. 0xA69F: scCyrillic
  elif c in 0x0370 .. 0x03FF or c in 0x1F00 .. 0x1FFF: scGreek
  elif c in 0x0530 .. 0x058F: scArmenian
  elif c in 0x10A0 .. 0x10FF: scGeorgian
  elif c in 0x0900 .. 0x097F: scDevanagari
  elif c in 0x0980 .. 0x09FF: scBengali
  elif c in 0x0B80 .. 0x0BFF: scTamil
  elif c in 0x0E00 .. 0x0E7F: scThai
  elif c in 0xAC00 .. 0xD7AF or c in 0x1100 .. 0x11FF or c in 0x3130 .. 0x318F: scHangul
  else: scOther

proc scriptOfWord(w: string): Script =
  ## The script of the letters of `w` (scMixed: more than one).
  result = scNone
  for r in w.runes:
    let c = int(r)
    if not isLetter(c): continue
    let s = scriptOf(c)
    if result == scNone: result = s
    elif s != result: result = scMixed; return

proc scriptOfLang(tag: string): Script =
  ## The script a language is written in (by its first subtag).
  let p = tag.split({'-', '_'})[0].toLowerAscii
  case p
  of "ar", "fa", "ur", "ps", "ckb", "sd", "ug", "ks": scArabic
  of "he", "yi", "iw": scHebrew
  of "ru", "uk", "be", "bg", "mk", "kk", "ky", "mn", "tg", "tt", "ba", "cv", "sr": scCyrillic
  of "el": scGreek
  of "hy": scArmenian
  of "ka": scGeorgian
  of "hi", "mr", "ne", "sa", "kok", "mai": scDevanagari
  of "bn", "as": scBengali
  of "ta": scTamil
  of "th": scThai
  of "ko": scHangul
  else: scLatin

proc acceptWord(text: string; a, b: int): bool =
  ## The word at bytes `a ..< b` is one to check: no digits or '_', more
  ## than one letter, not all capitals, not too long.
  if b - a > MaxWordBytes: return false
  var letters, upper, lower = 0
  var i = a
  while i < b:
    let ch = text[i]
    if ch.uint8 < 0x80:
      inc i
      case ch
      of 'a'..'z':
        inc letters
        inc lower
      of 'A'..'Z':
        inc letters
        inc upper
      of '0'..'9', '_': return false
      else: discard
      continue
    var r: Rune
    fastRuneAt(text, i, r, true)
    let c = int(r)
    if isDigitRune(c): return false
    if isLetter(c):
      inc letters
      if r.isUpper: inc upper
      elif r.isLower: inc lower
  letters >= 2 and not (upper >= 2 and lower == 0)

proc startsWithCI(s: string; a: int; what: string): bool =
  if a + what.len > s.len: return false
  for k in 0 ..< what.len:
    if s[a + k].toLowerAscii != what[k]: return false
  true

proc skipChunk(s: string; a, b: int): bool =
  ## Bytes `a ..< b` of `s` (text between spaces) are a web or e-mail
  ## address, a path, a hashtag: not words.
  if a >= b: return true
  var dots, slashes, colons = 0
  for k in a ..< b:
    case s[k]
    of '.': inc dots
    of '/': inc slashes
    of ':': inc colons
    of '@', '\\': return true
    else: discard
  if s[a] == '#': return true
  if dots == 0 and slashes == 0 and colons == 0: return false
  if colons > 0:
    for k in a ..< b - 2:
      if s[k] == ':' and s[k + 1] == '/' and s[k + 2] == '/': return true
    if startsWithCI(s, a, "mailto:"): return true
  if startsWithCI(s, a, "www."): return true
  if s[a] == '/' and slashes > 1: return true
  if dots == 0: return false
  # a domain: lower case letters, a dot, two or more letters ("nim-lang.org/doc")
  var e = b
  while e > a and s[e - 1] in {'.', ',', ';', ':', '!', '?', ')', '"', '\''}: dec e
  var dot = -1
  for k in a ..< e:
    let c = s[k]
    if c == '.': dot = k
    elif c == '/': break
    elif c notin {'a'..'z', '0'..'9', '-', '_', '~', '%', '?', '=', '&'}: return false
  if dot <= a or dot >= e - 1: return false
  for k in a ..< e:
    if s[k] notin {'a'..'z', '0'..'9', '.', '-', '/', '_', '~', '%', '?', '=', '&'}: return false
  var n = 0
  var k = dot + 1
  while k < e and s[k] in {'a'..'z'}:
    inc n
    inc k
  n >= 2 and (k == e or s[k] == '/')

proc skipChunk(s: string): bool {.inline.} = skipChunk(s, 0, s.len)

proc spellWords*(text: string): seq[tuple[a, b: int]] =
  ## The words of `text` a spell checker looks at, as byte ranges (`b` past
  ## the end): letters and the apostrophes between them ("don't"), split at
  ## hyphens; numbers, words with digits, acronyms, single letters, web
  ## and e-mail addresses left out.
  var i = 0
  while i < text.len:
    # a chunk: text between spaces
    var r: Rune
    var j = i
    fastRuneAt(text, j, r, true)
    if isSpaceRune(int(r)):
      i = j
      continue
    let c0 = i
    var c1 = j
    while c1 < text.len:
      var k = c1
      fastRuneAt(text, k, r, true)
      if isSpaceRune(int(r)): break
      c1 = k
    if not skipChunk(text, c0, c1):
      # its words
      var p = c0
      while p < c1:
        var q = p
        fastRuneAt(text, q, r, true)
        let c = int(r)
        if not (isLetter(c) or isDigitRune(c) or c == ord('_')):
          p = q
          continue
        let a = p
        var b = q
        while b < c1:
          var n = b
          fastRuneAt(text, n, r, true)
          let d = int(r)
          if isLetter(d) or isMark(d) or isDigitRune(d) or d == ord('_'):
            b = n
          elif isApostrophe(d) or d in 0x200C .. 0x200D:
            # (inside a word only: a letter after it)
            if n < c1:
              var m = n
              var r2: Rune
              fastRuneAt(text, m, r2, true)
              if isLetter(int(r2)):
                b = n
                continue
            break
          else: break
        if acceptWord(text, a, b): result.add (a, b)
        p = b
    i = c1

proc trimWord(w: string): string =
  ## `w` without spaces and apostrophes at its ends.
  var a = 0
  var b = w.len
  while true:
    if a < b and w[a] in {' ', '\''}: inc a
    elif a + 3 <= b and w[a .. a + 2] == "\xE2\x80\x99": a += 3
    else: break
  while true:
    if b > a and w[b - 1] in {' ', '\''}: dec b
    elif b - 3 >= a and w[b - 3 ..< b] == "\xE2\x80\x99": b -= 3
    else: break
  w[a ..< b]

# ---- languages --------------------------------------------------------------------------------------

proc normTag(t: string): string =
  ## "en_us.UTF-8" -> "en-US"; "" for "C", "POSIX".
  var s = t.strip
  for c in ['.', '@']:
    let k = s.find(c)
    if k >= 0: s.setLen(k)
  if s.len == 0 or s in ["C", "POSIX"]: return ""
  let parts = s.replace('_', '-').split('-')
  result = parts[0].toLowerAscii
  for i in 1 ..< parts.len:
    let p = parts[i]
    if p.len == 0: continue
    result.add '-'
    result.add(if p.len == 2: p.toUpperAscii
               elif p.len == 4: p[0].toUpperAscii & p[1 .. ^1].toLowerAscii
               else: p)

proc primary(t: string): string = t.split('-')[0]

proc pickTag(want: string; have: openArray[string]): string =
  ## The language of `have` that serves `want` best ("" none): itself, the
  ## language without its region, or one of its regions.
  let w = normTag(want)
  if w.len == 0: return ""
  for h in have:
    if cmpIgnoreCase(h, w) == 0: return h
  let p = primary(w)
  for h in have:
    if cmpIgnoreCase(h, p) == 0: return h
  let pref = case p
             of "en": @["en-US", "en-GB", "en-CA", "en-AU"]
             of "ar": @["ar-SA", "ar-EG", "ar-AE"]
             else: @[p & "-" & p.toUpperAscii]
  for f in pref:
    for h in have:
      if cmpIgnoreCase(h, f) == 0: return h
  for h in have:
    if cmpIgnoreCase(primary(h), p) == 0: return h

# ---- Hunspell and Enchant (Linux, BSD, Termux) --------------------------------------------------------

when not defined(windows) and not defined(macosx) and not defined(ios):
  type
    HunCreate = proc (aff, dic: cstring): pointer {.cdecl, gcsafe.}
    HunSpell = proc (h: pointer; w: cstring): cint {.cdecl, gcsafe.}
    HunSuggest = proc (h: pointer; list: ptr cstringArray; w: cstring): cint {.cdecl, gcsafe.}
    HunFree = proc (h: pointer; list: ptr cstringArray; n: cint) {.cdecl, gcsafe.}
    HunAdd = proc (h: pointer; w: cstring): cint {.cdecl, gcsafe.}
    HunEnc = proc (h: pointer): cstring {.cdecl, gcsafe.}
    EnDescribe = proc (tag, provider, desc, file: cstring; data: pointer) {.cdecl, gcsafe.}
    IconvOpen = proc (to, frm: cstring): pointer {.cdecl, gcsafe.}
    IconvRun = proc (cd: pointer; inb: ptr cstring; inl: ptr csize_t; outb: ptr cstring;
                     outl: ptr csize_t): csize_t {.cdecl, gcsafe.}
  var
    hunCreate: HunCreate
    hunSpell: HunSpell
    hunSuggest: HunSuggest
    hunFree: HunFree
    hunAdd: HunAdd
    hunEnc: HunEnc
    enInit: proc (): pointer {.cdecl, gcsafe.}
    enRequest: proc (b: pointer; tag: cstring): pointer {.cdecl, gcsafe.}
    enList: proc (b: pointer; fn: EnDescribe; data: pointer) {.cdecl, gcsafe.}
    enCheck: proc (d: pointer; w: cstring; n: int): cint {.cdecl, gcsafe.}
    enSuggest: proc (d: pointer; w: cstring; n: int; count: ptr csize_t): cstringArray {.cdecl, gcsafe.}
    enFreeList: proc (d: pointer; list: cstringArray) {.cdecl, gcsafe.}
    enAddSession: proc (d: pointer; w: cstring; n: int) {.cdecl, gcsafe.}
    enBroker: pointer
    iconvOpen: IconvOpen
    iconvRun: IconvRun

  proc dictDirs(): seq[string] =
    for d in getEnv("DICPATH").split(PathSep): result.add d
    let home = getHomeDir()
    result.add home / ".local" / "share" / "hunspell"
    result.add (let x = getEnv("XDG_DATA_HOME"); if x.len > 0: x else: home / ".local" / "share") / "hunspell"
    result.add home / ".hunspell"
    let prefix = getEnv("PREFIX")              # Termux
    if prefix.len > 0: result.add prefix / "share" / "hunspell"
    for base in ["/usr/share", "/usr/local/share", "/usr/pkg/share", "/app/share",
                 "/data/data/com.termux/files/usr/share"]:
      result.add base / "hunspell"
      result.add base / "myspell"
      result.add base / "myspell" / "dicts"

  proc findDicts() =
    ## The dictionaries there are: an .aff and a .dic of one name.
    var seen: HashSet[string]
    var short: Table[string, string]           # real file -> the shortest tag for it
    for dir in dictDirs():
      if dir.len == 0 or not dirExists(dir): continue
      try:
        for kind, path in walkDir(dir):
          if not path.endsWith(".aff"): continue
          let stem = path[0 ..< path.len - 4]
          let name = stem.extractFilename
          if name.startsWith("hyph") or not fileExists(stem & ".dic"): continue
          let tag = normTag(name)
          if tag.len == 0 or tag in dictFiles: continue
          dictFiles[tag] = stem
          dictTags.add tag
          # (each dictionary once: by its own file's name, else its shortest)
          let real = try: expandFilename(path) except OSError: path
          let own = normTag(real.extractFilename.changeFileExt(""))
          let had = short.getOrDefault(real)
          if had.len == 0 or tag == own or
             (had != own and (tag.len < had.len or (tag.len == had.len and tag < had))):
            short[real] = tag
      except OSError: discard
    for tag in short.values:
      if tag notin seen:
        seen.incl tag
        shownTags.add tag
    dictTags.sort()
    shownTags.sort()

  proc loadHunspell(): bool =
    let lib = loadLib("libhunspell-1.7.so.0")
    var h = lib
    for n in ["libhunspell-1.7.so", "libhunspell-1.6.so.0", "libhunspell-1.5.so.0",
              "libhunspell-1.4.so.0", "libhunspell.so"]:
      if h != nil: break
      h = loadLib(n)
    if h == nil: return false
    hunCreate = cast[HunCreate](h.symAddr("Hunspell_create"))
    hunSpell = cast[HunSpell](h.symAddr("Hunspell_spell"))
    hunSuggest = cast[HunSuggest](h.symAddr("Hunspell_suggest"))
    hunFree = cast[HunFree](h.symAddr("Hunspell_free_list"))
    hunAdd = cast[HunAdd](h.symAddr("Hunspell_add"))
    hunEnc = cast[HunEnc](h.symAddr("Hunspell_get_dic_encoding"))
    if hunCreate == nil or hunSpell == nil or hunSuggest == nil or hunFree == nil: return false
    findDicts()
    true

  proc loadEnchant(): bool =
    let h = loadLib("libenchant-2.so.2")
    let lib = if h != nil: h else: loadLib("libenchant-2.so")
    if lib == nil: return false
    enInit = cast[typeof(enInit)](lib.symAddr("enchant_broker_init"))
    enRequest = cast[typeof(enRequest)](lib.symAddr("enchant_broker_request_dict"))
    enList = cast[typeof(enList)](lib.symAddr("enchant_broker_list_dicts"))
    enCheck = cast[typeof(enCheck)](lib.symAddr("enchant_dict_check"))
    enSuggest = cast[typeof(enSuggest)](lib.symAddr("enchant_dict_suggest"))
    enFreeList = cast[typeof(enFreeList)](lib.symAddr("enchant_dict_free_string_list"))
    enAddSession = cast[typeof(enAddSession)](lib.symAddr("enchant_dict_add_to_session"))
    if enInit == nil or enRequest == nil or enList == nil or enCheck == nil or
       enSuggest == nil or enFreeList == nil: return false
    enBroker = enInit()
    if enBroker == nil: return false
    proc describe(tag, provider, desc, file: cstring; data: pointer) {.cdecl, gcsafe.} =
      {.cast(gcsafe).}:
        let t = normTag($tag)
        if t.len > 0 and t notin dictTags: dictTags.add t
    enList(enBroker, describe, nil)
    dictTags.sort()
    shownTags = dictTags
    true

  proc iconvReady(): bool =
    if iconvOpen != nil: return true
    for n in ["libc.so.6", "libiconv.so.2", "libiconv.so", "libc.so"]:
      let lib = loadLib(n)
      if lib == nil: continue
      for (o, r) in [("iconv_open", "iconv"), ("libiconv_open", "libiconv")]:
        let po = lib.symAddr(cstring(o))
        let pr = lib.symAddr(cstring(r))
        if po != nil and pr != nil:
          iconvOpen = cast[IconvOpen](po)
          iconvRun = cast[IconvRun](pr)
          return true
    false

  proc convert(cd: pointer; s: string; ok: var bool): string =
    ## `s` in another encoding through iconv's `cd`.
    ok = false
    if s.len == 0:
      ok = true
      return ""
    discard iconvRun(cd, nil, nil, nil, nil)
    result = newString(s.len * 4 + 8)
    var inp = cstring(s)
    var inl = csize_t(s.len)
    var outp = cast[cstring](addr result[0])
    var outl = csize_t(result.len)
    if iconvRun(cd, addr inp, addr inl, addr outp, addr outl) == cast[csize_t](-1): result = ""; return
    result.setLen(result.len - int(outl))
    ok = true

  proc toLatin1(s: string; ok: var bool): string =
    ok = true
    for r in s.runes:
      if int(r) > 255:
        ok = false
        result = ""
        return
      result.add char(int(r))

  proc fromLatin1(s: string): string =
    for c in s: result.add Rune(ord(c)).toUTF8

  proc dictWord(c: Checker; w: string; ok: var bool): string =
    ## `w` in the encoding of `c`'s dictionary.
    if c.toDict != nil: convert(c.toDict, w, ok)
    elif c.latin1: toLatin1(w, ok)
    else:
      ok = true
      w

  proc utf8Word(c: Checker; w: string): string =
    result = ""         # (a value at once: see tools/writecheck.py)
    var ok = false
    if c.fromDict != nil:
      result = convert(c.fromDict, w, ok)
      if not ok: result = ""
    elif c.latin1: result = fromLatin1(w)
    else: result = w

  proc openHunspell(tag: string): Checker =
    let stem = dictFiles.getOrDefault(tag)
    if stem.len == 0: return nil
    let h = hunCreate(cstring(stem & ".aff"), cstring(stem & ".dic"))
    if h == nil: return nil
    result = Checker(tag: tag, script: scriptOfLang(tag), h: h)
    let enc = if hunEnc != nil: ($hunEnc(h)).toUpperAscii.replace("-", "").replace("_", "") else: "UTF8"
    if enc notin ["UTF8", ""]:
      let name = ($hunEnc(h))
      if iconvReady():
        let a = iconvOpen(cstring(name), "UTF-8")
        let b = iconvOpen("UTF-8", cstring(name))
        if a != cast[pointer](-1) and b != cast[pointer](-1) and a != nil and b != nil:
          result.toDict = a
          result.fromDict = b
      if result.toDict == nil:
        if enc in ["ISO88591", "LATIN1"]: result.latin1 = true
        else: result = nil; return
    # the user's own words, for the suggestions too
    if hunAdd != nil:
      for w in userWords:
        var ok = false
        let dw = result.dictWord(w, ok)
        if ok and scriptOfWord(w) in {result.script, scNone}: discard hunAdd(h, cstring(dw))

  proc openEnchant(tag: string): Checker =
    let names = [tag.replace('-', '_'), tag]
    for n in names:
      let d = enRequest(enBroker, cstring(n))
      if d != nil:
        result = Checker(tag: tag, script: scriptOfLang(tag), h: d)
        if enAddSession != nil:
          for w in userWords: enAddSession(d, cstring(w), w.len)
        return

  proc systemLanguage(): string =
    for v in ["LC_ALL", "LC_MESSAGES", "LANG"]:
      let t = normTag(getEnv(v))
      if t.len > 0: return t
    let l = getEnv("LANGUAGE").split(':')[0]
    normTag(l)

# ---- Windows: ISpellChecker through COM --------------------------------------------------------------

when defined(windows):
  type WGuid = object
    d1: uint32
    d2, d3: uint16
    d4: array[8, uint8]
  const
    ClsidFactory = WGuid(d1: 0x7AB36653'u32, d2: 0x1796, d3: 0x484B,
                         d4: [0xBD'u8, 0xFA, 0xE7, 0x4F, 0x1D, 0xB7, 0xC1, 0xDC])
    IidFactory = WGuid(d1: 0x8E018A9D'u32, d2: 0x2415, d3: 0x4677,
                       d4: [0xBF'u8, 0x08, 0x79, 0x4E, 0xA6, 0x1F, 0x94, 0xBB])
  var
    coInit: proc (r: pointer; model: uint32): int32 {.stdcall, gcsafe.}
    coCreate: proc (clsid: ptr WGuid; outer: pointer; ctx: uint32; iid: ptr WGuid;
                    obj: ptr pointer): int32 {.stdcall, gcsafe.}
    coFree: proc (p: pointer) {.stdcall, gcsafe.}
    userLocale: proc (buf: ptr uint16; n: int32): int32 {.stdcall, gcsafe.}
    factory: pointer

  template slot(o: pointer; i: int): pointer =
    cast[ptr UncheckedArray[pointer]](cast[ptr pointer](o)[])[i]

  proc release(o: pointer) =
    if o != nil: discard cast[proc (o: pointer): uint32 {.stdcall, gcsafe.}](slot(o, 2))(o)

  proc wide(s: string): WideCString = newWideCString(s)

  proc takeText(p: pointer): string =
    ## A string the system made (CoTaskMemAlloc), as UTF-8; it is freed.
    if p == nil: return ""
    result = $cast[WideCString](p)
    coFree(p)

  proc enumStrings(e: pointer): seq[string] =
    ## The strings of an IEnumString (released).
    if e == nil: return
    let next = cast[proc (o: pointer; n: uint32; s: ptr pointer; got: ptr uint32): int32
                    {.stdcall, gcsafe.}](slot(e, 3))
    for i in 0 ..< 1000:
      var p: pointer
      var got: uint32
      if next(e, 1, addr p, addr got) != 0 or got == 0: break
      result.add takeText(p)
    release(e)

  proc loadWindows(): bool =
    let ole = loadLib("ole32.dll")
    let k32 = loadLib("kernel32.dll")
    if ole == nil: return false
    coInit = cast[typeof(coInit)](ole.symAddr("CoInitializeEx"))
    coCreate = cast[typeof(coCreate)](ole.symAddr("CoCreateInstance"))
    coFree = cast[typeof(coFree)](ole.symAddr("CoTaskMemFree"))
    if k32 != nil: userLocale = cast[typeof(userLocale)](k32.symAddr("GetUserDefaultLocaleName"))
    if coInit == nil or coCreate == nil or coFree == nil: return false
    discard coInit(nil, 2)                    # COINIT_APARTMENTTHREADED (or as it was)
    var clsid = ClsidFactory
    var iid = IidFactory
    var f: pointer
    if coCreate(addr clsid, nil, 1, addr iid, addr f) != 0 or f == nil: return false
    factory = f
    # get_SupportedLanguages
    var e: pointer
    let langs = cast[proc (o: pointer; e: ptr pointer): int32 {.stdcall, gcsafe.}](slot(f, 3))
    if langs(f, addr e) == 0:
      for t in enumStrings(e):
        let n = normTag(t)
        if n.len > 0 and n notin dictTags: dictTags.add n
    dictTags.sort()
    shownTags = dictTags
    true

  proc openWindows(tag: string): Checker =
    if factory == nil: return nil
    var ok: int32
    let supported = cast[proc (o: pointer; t: WideCString; v: ptr int32): int32
                         {.stdcall, gcsafe.}](slot(factory, 4))
    if supported(factory, wide(tag), addr ok) != 0 or ok == 0: return nil
    var c: pointer
    let create = cast[proc (o: pointer; t: WideCString; v: ptr pointer): int32
                      {.stdcall, gcsafe.}](slot(factory, 5))
    if create(factory, wide(tag), addr c) != 0 or c == nil: return nil
    Checker(tag: tag, script: scriptOfLang(tag), h: c)

  proc winCheck(c: Checker; w: string): bool =
    ## True when `w` is spelled right (ISpellChecker::Check finds nothing).
    var e: pointer
    let check = cast[proc (o: pointer; t: WideCString; e: ptr pointer): int32
                     {.stdcall, gcsafe.}](slot(c.h, 4))
    if check(c.h, wide(w), addr e) != 0 or e == nil: return true
    var err: pointer
    let next = cast[proc (o: pointer; v: ptr pointer): int32 {.stdcall, gcsafe.}](slot(e, 3))
    result = not (next(e, addr err) == 0 and err != nil)
    release(err)
    release(e)

  proc winSuggest(c: Checker; w: string): seq[string] =
    var e: pointer
    let suggest = cast[proc (o: pointer; t: WideCString; e: ptr pointer): int32
                       {.stdcall, gcsafe.}](slot(c.h, 5))
    let hr = suggest(c.h, wide(w), addr e)
    if hr == 0: result = enumStrings(e)
    else: release(e)                          # (S_FALSE: spelled right)

  proc winWord(c: Checker; i: int; w: string) =
    ## ISpellChecker::Add (6) or Ignore (7).
    let f = cast[proc (o: pointer; t: WideCString): int32 {.stdcall, gcsafe.}](slot(c.h, i))
    discard f(c.h, wide(w))

  proc systemLanguage(): string =
    if userLocale == nil:
      let k32 = loadLib("kernel32.dll")
      if k32 != nil: userLocale = cast[typeof(userLocale)](k32.symAddr("GetUserDefaultLocaleName"))
    if userLocale == nil: return ""
    var buf: array[86, uint16]
    if userLocale(addr buf[0], int32(buf.len)) > 0:
      result = normTag($cast[WideCString](addr buf[0]))

# ---- macOS: NSSpellChecker -----------------------------------------------------------------------------

when defined(macosx) and not defined(ios):
  type NSRange = object
    location, length: uint
  const NSNotFound = uint(high(int))
  var
    macChecker: ObjcId
    macDocTag: int

  proc nsArrayStrings(a: ObjcId): seq[string] =
    if a == nil: return
    let n = objcSend(int, a, "count")
    for i in 0 ..< n: result.add toNim(objcSend(ObjcId, a, "objectAtIndex:", i))

  proc loadMac(): bool =
    discard loadLib("/System/Library/Frameworks/AppKit.framework/AppKit")
    let cls = objcClass("NSSpellChecker")
    if cls == nil: return false
    autoreleasePool:
      macChecker = objcSend(ObjcId, cls, "sharedSpellChecker")
      if macChecker == nil: return false
      macDocTag = objcSend(int, cls, "uniqueSpellDocumentTag")
      for t in nsArrayStrings(objcSend(ObjcId, macChecker, "availableLanguages")):
        let n = normTag(t)
        if n.len > 0 and n notin dictTags: dictTags.add n
    dictTags.sort()
    shownTags = dictTags
    true

  proc macLang(c: Checker): string = c.tag.replace('-', '_')

  proc macCheck(c: Checker; w: string): bool =
    autoreleasePool:
      let r = objcSend(NSRange, macChecker,
                       "checkSpellingOfString:startingAt:language:wrap:inSpellDocumentWithTag:wordCount:",
                       nsString(w), 0, nsString(c.macLang), false, macDocTag, pointer(nil))
      result = r.location == NSNotFound or r.length == 0

  proc macSuggest(c: Checker; w: string): seq[string] =
    autoreleasePool:
      let s = nsString(w)
      let n = objcSend(int, s, "length")
      let a = objcSend(ObjcId, macChecker, "guessesForWordRange:inString:language:inSpellDocumentWithTag:",
                       NSRange(location: 0, length: uint(n)), s, nsString(c.macLang), macDocTag)
      result = nsArrayStrings(a)

  proc systemLanguage(): string =
    autoreleasePool:
      let langs = objcSend(ObjcId, objcClass("NSLocale"), "preferredLanguages")
      let all = nsArrayStrings(langs)
      if all.len > 0: result = normTag(all[0])

when defined(ios):
  proc systemLanguage(): string = ""

# ---- the engine ------------------------------------------------------------------------------------

proc start() =
  ## Finds the system's checker and its languages (once).
  if engineReady: return
  engineReady = true
  userLang = systemLanguage()
  if userLang.len == 0: userLang = "en-US"
  let want = getEnv("RETRO_SPELL").toLowerAscii
  if want == "none": return
  when defined(windows):
    if loadWindows(): engine = enWindows
  elif defined(ios):
    discard
  elif defined(macosx):
    if loadMac(): engine = enMac
  else:
    if want != "enchant" and loadHunspell() and dictTags.len > 0: engine = enHunspell
    elif loadEnchant(): engine = enEnchant
    elif want == "enchant" and loadHunspell(): engine = enHunspell

proc loadUserWords() =
  if userLoaded: return
  userLoaded = true
  try:
    let path = dataDir("retro") / "words.txt"
    if fileExists(path):
      for ln in lines(path):
        let w = ln.strip
        if w.len > 0 and not w.startsWith('#'): userWords.incl w
  except IOError, OSError: discard

proc checkerFor(tag: string): Checker =
  ## The checker of language `tag` (opened the first time; nil: none).
  start()
  if engine == enNone or tag.len == 0: return nil
  if tag in checkers: return checkers[tag]
  loadUserWords()
  let t = pickTag(tag, dictTags)
  var c: Checker = nil
  if t.len > 0:
    if t in checkers: c = checkers[t]
    else:
      case engine
      of enHunspell:
        when declared(openHunspell): c = openHunspell(t)
      of enEnchant:
        when declared(openEnchant): c = openEnchant(t)
      of enWindows:
        when declared(openWindows): c = openWindows(t)
      of enMac:
        when declared(loadMac): c = Checker(tag: t, script: scriptOfLang(t))
      of enNone: discard
      checkers[t] = c
  checkers[tag] = c
  c

proc engineSpells(c: Checker; w: string): bool =
  ## The checker says `w` is right.
  case engine
  of enHunspell:
    when declared(hunSpell):
      var ok = false
      let dw = c.dictWord(w, ok)
      if not ok: return true                 # (letters its dictionary has not)
      hunSpell(c.h, cstring(dw)) != 0
    else: true
  of enEnchant:
    when declared(enCheck): enCheck(c.h, cstring(w), w.len) == 0
    else: true
  of enWindows:
    when declared(winCheck): winCheck(c, w)
    else: true
  of enMac:
    when declared(macCheck): macCheck(c, w)
    else: true
  of enNone: true

proc engineSuggest(c: Checker; w: string): seq[string] =
  case engine
  of enHunspell:
    when declared(hunSuggest):
      var ok = false
      let dw = c.dictWord(w, ok)
      if not ok: return
      var list: cstringArray
      let n = hunSuggest(c.h, addr list, cstring(dw))
      if list != nil:
        for i in 0 ..< n:
          let s = c.utf8Word($list[i])
          if s.len > 0: result.add s
        hunFree(c.h, addr list, n)
  of enEnchant:
    when declared(enSuggest):
      var n: csize_t
      let list = enSuggest(c.h, cstring(w), w.len, addr n)
      if list != nil:
        for i in 0 ..< int(n): result.add $list[i]
        enFreeList(c.h, list)
  of enWindows:
    when declared(winSuggest): result = winSuggest(c, w)
  of enMac:
    when declared(macSuggest): result = macSuggest(c, w)
  of enNone: discard

proc forget() =
  ## Verdicts given so far may be wrong now.
  verdicts.clear()
  inc generation

# ---- the API ---------------------------------------------------------------------------------------

proc spellBackend*(): string =
  ## Which checker answers: "hunspell", "enchant", "windows", "macos", or ""
  ## when there is none.
  start()
  case engine
  of enHunspell: "hunspell"
  of enEnchant: "enchant"
  of enWindows: "windows"
  of enMac: "macos"
  of enNone: ""

proc spellLanguages*(): seq[string] =
  ## The languages there are dictionaries for ("en-US", "ar", "fr"...).
  start()
  if engine == enNone: @[] else: shownTags

proc spellUserLanguage*(): string =
  ## The user's language as the system says ("en-US", "ar-OM").
  start()
  userLang

proc spellAvailable*(lang = ""): bool =
  ## A checker for `lang` is here. "": for the user's language -- or, when
  ## there is none for it, for any language (each word is checked in the
  ## language of its script).
  start()
  if engine == enNone: return false
  if lang.len > 0: return pickTag(lang, dictTags).len > 0
  pickTag(userLang, dictTags).len > 0 or dictTags.len > 0

proc spellGeneration*(): int =
  ## A number that changes when verdicts given before may be different now
  ## (a word was ignored or added): what keeps them can tell.
  generation

proc spellLanguageOf*(word: string): string =
  ## The language `word` is checked in, by its script: an Arabic word in
  ## Arabic ("ar") when there is an Arabic dictionary, a Latin one in the
  ## user's language (or English when that is not written in Latin
  ## letters); else the user's language.
  start()
  let sc = scriptOfWord(word)
  if sc in {scNone, scMixed, scOther} or sc == scriptOfLang(userLang): return userLang
  let pref = case sc
             of scArabic: @["ar"]
             of scLatin: @["en-US", "en"]
             of scCyrillic: @["ru"]
             of scHebrew: @["he"]
             else: @[]
  for p in pref:
    let t = pickTag(p, dictTags)
    if t.len > 0: return t
  for t in dictTags:
    if scriptOfLang(t) == sc: return t
  userLang

proc isUserWord(w: string): bool =
  if w in ignored or w in userWords: return true
  # "nim" added: "Nim" (at a sentence's start) too
  var first = true
  var low = ""
  for r in w.runes:
    low.add(if first: r.toLower.toUTF8 else: r.toUTF8)
    first = false
  low != w and (low in ignored or low in userWords)

proc misspelledWord(w, lang: string): bool =
  ## (one word, as `spellWords` finds them)
  if isUserWord(w): return false
  let tag = if lang.len > 0: lang else: spellLanguageOf(w)
  let c = checkerFor(tag)
  if c == nil: return false
  let sc = scriptOfWord(w)
  if sc != c.script: return false             # (a dictionary knows its own letters only)
  if engineSpells(c, w): return false
  if "\xE2\x80\x99" in w and engineSpells(c, w.replace("\xE2\x80\x99", "'")): return false
  true

proc isMisspelled*(word: string; lang = ""): bool =
  ## `word` is not in the dictionary of `lang` ("": the language of its
  ## script, see `spellLanguageOf`), nor ignored, nor the user's own.
  ## False when there is no checker for it, and for what is not checked
  ## (numbers, acronyms, addresses). A hyphenated word: any of its parts.
  ## Cached: asking again costs a table look-up.
  let key = if lang.len == 0: word else: lang & '\x1F' & word
  let v = verdicts.getOrDefault(key, false)
  if v or key in verdicts: return v
  start()
  result = false
  if engine != enNone:
    let w = trimWord(word)
    for (a, b) in spellWords(w):
      if misspelledWord(w[a ..< b], lang):
        result = true
        break
  if verdicts.len >= MaxCache: verdicts.clear()
  verdicts[key] = result

proc spellSuggest*(word: string; lang = ""; max = 6): seq[string] =
  ## Up to `max` corrections of `word`, the likeliest first (none when
  ## there is no checker for its language).
  let w = trimWord(word)
  if w.len == 0 or max <= 0: return
  let c = checkerFor(if lang.len > 0: lang else: spellLanguageOf(w))
  if c == nil: return
  # (the word cut in two -- "at ached" -- after the others)
  var splits: seq[string]
  for s in engineSuggest(c, w):
    if s == w or s in result or s in splits: continue
    if (' ' in s and ' ' notin w) or ('-' in s and '-' notin w): splits.add s
    else: result.add s
  for s in splits: result.add s
  if result.len > max: result.setLen(max)

proc spellIgnore*(word: string) =
  ## `word` is not marked again, in this session.
  let w = trimWord(word)
  if w.len == 0: return
  ignored.incl w
  when defined(windows):
    let c = checkerFor(spellLanguageOf(w))
    if c != nil: winWord(c, 7, w)
  forget()

proc spellAdd*(word: string) =
  ## Adds `word` to the user's own dictionary (`dataDir("retro")/words.txt`;
  ## on Windows the system's too, which Office shares): never marked again.
  let w = trimWord(word)
  if w.len == 0 or '\n' in w: return
  loadUserWords()
  if w notin userWords:
    userWords.incl w
    try:
      let f = open(dataDir("retro") / "words.txt", fmAppend)
      f.writeLine w
      f.close()
    except IOError, OSError: discard
  # the open checkers learn it (for their suggestions)
  for c in checkers.values:
    if c == nil or scriptOfWord(w) notin {c.script, scNone}: continue
    case engine
    of enHunspell:
      when declared(hunAdd):
        var ok = false
        let dw = c.dictWord(w, ok)
        if ok and hunAdd != nil: discard hunAdd(c.h, cstring(dw))
    of enEnchant:
      when declared(enAddSession):
        if enAddSession != nil: enAddSession(c.h, cstring(w), w.len)
    of enWindows:
      when defined(windows): winWord(c, 6, w)
      else: discard
    of enMac:
      when declared(macChecker):
        autoreleasePool:
          objcSend(void, macChecker, "learnWord:", nsString(w))
      else: discard
    of enNone: discard
  forget()

proc spellWordsFile*(): string =
  ## Where the user's own dictionary is kept: a word a line.
  dataDir("retro") / "words.txt"

# ---- AutoCorrect ------------------------------------------------------------------------------------

type AutoCorrectKind* = enum
  ## What AutoCorrect does while one types (`autoCorrectEnable`).
  acReplace = "Replace text as you type"
    ## the AutoCorrect lists: "teh" -> "the", "(c)" -> "©", "الى" -> "إلى"
  acSuggest = "Use the spelling checker's suggestions"
    ## a misspelled word (more than 3 letters) with a single suggestion one
    ## letter away takes it (not Arabic)
  acSuggestArabic = "Use the spelling checker's suggestions in Arabic"
    ## ... Arabic words too (off at first)
  acCapitalize = "Capitalize the first letter of sentences"

const
  EnglishList = """
abbout|about;abotu|about;abouta|about a;aboutit|about it;abscence|absence;accesories|accessories;
accidant|accident;accomodate|accommodate;accomodation|accommodation;accross|across;acheive|achieve;
acheived|achieved;acheiving|achieving;acn|can;acommodate|accommodate;acomodate|accommodate;
actualyl|actually;additinal|additional;addtional|additional;adequit|adequate;adn|and;agian|again;
ahppen|happen;ahve|have;allwasy|always;allwyas|always;almots|almost;almsot|almost;alomst|almost;
alot|a lot;alraedy|already;alreayd|already;alreday|already;alwasy|always;alwats|always;alwyas|always;
amde|made;amke|make;amkes|makes;anbd|and;andone|and one;andteh|and the;andthe|and the;anothe|another;
anual|annual;apparant|apparent;apparrent|apparent;appearence|appearance;applicaiton|application;
applicaitons|applications;applyed|applied;appointiment|appointment;approrpiate|appropriate;
aquisition|acquisition;aquisitions|acquisitions;arent|aren't;arguement|argument;arguements|arguments;
arond|around;artical|article;articel|article;assistent|assistant;asthe|as the;atention|attention;
atthe|at the;audeince|audience;audiance|audience;availalbe|available;awya|away;aywa|away;bakc|back;
balence|balance;ballance|balance;baout|about;bcak|back;beacuse|because;becasue|because;becaus|because;
becauseof|because of;becausethe|because the;becauseyou|because you;becomeing|becoming;becomming|becoming;
becuase|because;becuse|because;befoer|before;beggining|beginning;begining|beginning;beginnig|beginning;
beleive|believe;belive|believe;beteen|between;beween|between;bewteen|between;bve|be;calulated|calculated;
candidtae|candidate;candidtaes|candidates;catagory|category;categiory|category;certian|certain;
challange|challenge;challanges|challenges;chaneg|change;chanegs|changes;changable|changeable;
changeing|changing;changng|changing;charachter|character;charachters|characters;charactor|character;
charecter|character;cheif|chief;chekc|check;chnage|change;cieling|ceiling;circut|circuit;claer|clear;
claerly|clearly;cliant|client;cna|can;colection|collection;comanies|companies;comany|company;
comapnies|companies;comapny|company;combintation|combination;comited|committed;comittee|committee;
commadn|command;comming|coming;commitee|committee;committe|committee;committment|commitment;
committments|commitments;comntain|contain;compleatly|completely;completly|completely;
completness|completeness;comunicate|communicate;comunity|community;condolances|condolences;
conected|connected;conferance|conference;confirmmation|confirmation;consultent|consultant;
convertable|convertible;cooperatoin|cooperation;corproation|corporation;coudl|could;coudln't|couldn't;
couldnt|couldn't;couldthe|could the;cpoy|copy;csae|case;cusotmer|customer;cusotmers|customers;
cutsomer|customer;cutsomers|customers;cxan|can;dcument|document;deatils|details;decison|decision;
decisons|decisions;defendent|defendant;definately|definitely;definatly|definitely;deptartment|department;
desicion|decision;desicions|decisions;develope|develop;developement|development;
developements|developments;developor|developer;developors|developers;develpment|development;
diaplay|display;didint|didn't;didnot|did not;didnt|didn't;difefrent|different;diferences|differences;
differance|difference;differances|differences;differant|different;differemt|different;differnt|different;
diffrent|different;directer|director;disatisfied|dissatisfied;discoverd|discovered;disign|design;
dispaly|display;distribusion|distribution;divsion|division;docuement|document;docuemnt|document;
documetn|document;documnet|document;documnets|documents;doens't|doesn't;doese|does;doesnt|doesn't;
doign|doing;doimg|doing;dollers|dollars;donig|doing;dont|don't;dosn't|doesn't;driveing|driving;
efel|feel;effecient|efficient;efort|effort;eforts|efforts;ehr|her;eligable|eligible;embarass|embarrass;
emial|email;enought|enough;equippment|equipment;equivalant|equivalent;esle|else;especally|especially;
especialyl|especially;espesially|especially;excellant|excellent;excercise|exercise;exchagne|exchange;
excitment|excitement;exhcange|exchange;experiance|experience;exprience|experience;exprienced|experienced;
eyt|yet;faeture|feature;faetures|features;familair|familiar;familar|familiar;familliar|familiar;
feild|field;feilds|fields;fianlly|finally;fidn|find;finalyl|finally;firends|friends;firts|first;
follwo|follow;follwoing|following;fonud|found;foriegn|foreign;freind|friend;freindly|friendly;
frmo|from;fromthe|from the;fwe|few;garantee|guarantee;gaurd|guard;gerat|great;geting|getting;
gievn|given;giveing|giving;gloabl|global;goign|going;gonig|going;govenment|government;
goverment|government;gruop|group;gruops|groups;grwo|grow;guidlines|guidelines;hadbeen|had been;
haev|have;hapen|happen;hapened|happened;hapening|happening;hapens|happens;happend|happened;
hasbeen|has been;hasnt|hasn't;havebeen|have been;havent|haven't;haveing|having;hda|had;hearign|hearing;
helpfull|helpful;hesaid|he said;hewas|he was;hge|he;hismelf|himself;hlep|help;hsa|has;hsi|his;hte|the;
htere|there;htese|these;htey|they;hting|thing;htink|think;htis|this;hvae|have;hvaing|having;hwich|which;
i|I;i'd|I'd;i'll|I'll;i'm|I'm;i've|I've;idae|idea;idaes|ideas;im|I'm;imediately|immediately;
immediatly|immediately;importent|important;importnat|important;impossable|impossible;
improvemnt|improvement;improvment|improvement;indepedent|independent;independance|independence;
independant|independent;influance|influence;infomation|information;informatoin|information;
inital|initial;instaleld|installed;insted|instead;insurence|insurance;inteh|in the;inthe|in the;
inwhich|in which;isnt|isn't;isthe|is the;itis|it is;itnerest|interest;itnerested|interested;
itneresting|interesting;itwas|it was;iwll|will;iwth|with;jsut|just;knowldge|knowledge;knowlege|knowledge;
knwo|know;knwon|known;knwos|knows;konw|know;konwn|known;konws|knows;labratory|laboratory;
lastyear|last year;learnign|learning;lenght|length;levle|level;libary|library;librarry|library;
librery|library;liek|like;liekd|liked;liev|live;likly|likely;lisense|license;littel|little;
litttle|little;liveing|living;loev|love;lonly|lonely;lookign|looking;maintenence|maintenance;
makeing|making;managment|management;mantain|maintain;marraige|marriage;memeber|member;merchent|merchant;
mesage|message;mesages|messages;mkae|make;mkaes|makes;mkaing|making;moeny|money;morgage|mortgage;
mroe|more;mysefl|myself;myu|my;necassarily|necessarily;necassary|necessary;neccessarily|necessarily;
neccessary|necessary;necesarily|necessarily;necesary|necessary;negotiaing|negotiating;nkow|know;
nothign|nothing;nver|never;nwe|new;nwo|now;obediant|obedient;ocasion|occasion;occassion|occasion;
occured|occurred;occurence|occurrence;occurrance|occurrence;ocur|occur;oeprator|operator;ofits|of its;
ofthe|of the;oging|going;ohter|other;omre|more;oneof|one of;onthe|on the;onyl|only;oppasite|opposite;
opperation|operation;oppertunity|opportunity;opposate|opposite;opposit|opposite;
oppotunities|opportunities;oppotunity|opportunity;orginization|organization;orginized|organized;
otehr|other;otu|out;outof|out of;overthe|over the;owrk|work;owuld|would;papaer|paper;
parliment|parliament;partof|part of;paymetn|payment;paymetns|payments;pciture|picture;peice|piece;
peices|pieces;peolpe|people;peopel|people;percentof|percent of;performence|performance;perhasp|perhaps;
perhpas|perhaps;permanant|permanent;perminent|permanent;personalyl|personally;pleasent|pleasant;
poeple|people;porblem|problem;porblems|problems;porvide|provide;possable|possible;postition|position;
potentialy|potentially;pregnent|pregnant;presance|presence;probelm|problem;probelms|problems;
prominant|prominent;psoition|position;ptogress|progress;puting|putting;pwoer|power;quater|quarter;
quaters|quarters;quesion|question;quesions|questions;questiosn|questions;questoin|question;
quetion|question;quetions|questions;realyl|really;reccomend|recommend;reccommend|recommend;
receieve|receive;recieve|receive;recieved|received;recieving|receiving;recomend|recommend;
recomendation|recommendation;recomendations|recommendations;recomended|recommended;reconize|recognize;
recrod|record;religous|religious;reluctent|reluctant;remeber|remember;reommend|recommend;
representives|representatives;reserach|research;resollution|resolution;resorces|resources;
responce|response;responsability|responsibility;responsable|responsible;responsiblity|responsibility;
restaraunt|restaurant;restuarant|restaurant;reult|result;reveiw|review;reveiwing|reviewing;
rumers|rumors;rwite|write;rythm|rhythm;saidhe|said he;saidit|said it;saidthat|said that;
saidthe|said the;scedule|schedule;sceduled|scheduled;secratary|secretary;sectino|section;seh|she;
selectoin|selection;sentance|sentence;separeate|separate;seperate|separate;seperately|separately;
shcool|school;shesaid|she said;shineing|shining;shiped|shipped;shoudl|should;shoudln't|shouldn't;
shouldnt|shouldn't;showinf|showing;signifacnt|significant;simalar|similar;similiar|similar;
simpyl|simply;sincerly|sincerely;sitll|still;smae|same;smoe|some;soem|some;sohw|show;soical|social;
somethign|something;someting|something;somewaht|somewhat;somthing|something;somtimes|sometimes;
soudn|sound;soudns|sounds;speach|speech;specificaly|specifically;specificalyl|specifically;
statment|statement;statments|statements;stnad|stand;stopry|story;stoyr|story;stpo|stop;
strentgh|strength;stroy|story;struggel|struggle;strugle|struggle;studnet|student;
successfull|successful;successfuly|successfully;sucess|success;sucessfull|successful;
sufficiant|sufficient;suposed|supposed;suppossed|supposed;suprise|surprise;suprised|surprised;
swiming|swimming;tahn|than;taht|that;talekd|talked;talkign|talking;tath|that;tecnical|technical;
teh|the;tehy|they;tghe|the;tghis|this;thansk|thanks;thats|that's;thatthe|that the;thecompany|the company;
thefirst|the first;thegovernment|the government;themself|themselves;themselfs|themselves;
thenew|the new;theres|there's;thesame|the same;thetwo|the two;theyre|they're;thgat|that;thge|the;
thier|their;thigsn|things;thisyear|this year;thna|than;thne|then;thnig|thing;thnigs|things;
threatend|threatened;thsi|this;thsoe|those;thta|that;tihs|this;timne|time;tiogether|together;tje|the;
tjhe|the;tkae|take;tkaes|takes;tkaing|taking;tlaking|talking;todya|today;togehter|together;
tomorow|tomorrow;tommorow|tomorrow;tommorrow|tomorrow;tongiht|tonight;tonihgt|tonight;totaly|totally;
totalyl|totally;tothe|to the;towrad|toward;transfered|transferred;truely|truly;truley|truly;
tryed|tried;tthe|the;tyhat|that;tyhe|the;udnerstand|understand;understnad|understand;unliek|unlike;
untill|until;useing|using;usualyl|usually;veyr|very;virtualyl|virtually;vrey|very;waht|what;
wasnt|wasn't;watn|want;wehn|when;werent|weren't;wern't|weren't;whcih|which;wherre|where;whic|which;
whihc|which;whta|what;wief|wife;wierd|weird;wiht|with;windoes|windows;withe|with;wiull|will;wnat|want;
wnated|wanted;wnats|wants;woh|who;wohle|whole;wokr|work;woudl|would;woudln't|wouldn't;wouldbe|would be;
wouldnt|wouldn't;wriet|write;writting|writing;wrod|word;wroet|wrote;wroking|working;wtih|with;
wuould|would;wya|way;yera|year;yeras|years;yersa|years;yoiu|you;youare|you are;youre|you're;
youve|you've;ytou|you;yuo|you;yuor|your;
(c)|©;(r)|®;(tm)|™;-->|→;<--|←;==>|⇒;<==|⇐;<=>|⇔"""
    ## Word's classic list (lower case: "Teh" becomes "The", "TEH" "THE").

  ArabicList = """
الى|إلى;انا|أنا;اذا|إذا;ايضا|أيضاً;ايضاً|أيضاً;لاكن|لكن;هاذا|هذا;هاذه|هذه;هاذان|هذان;ذالك|ذلك;
هاؤلاء|هؤلاء;هاولاء|هؤلاء;هأولاء|هؤلاء;اولئك|أولئك;الأن|الآن;الان|الآن;اللذي|الذي;اللذى|الذي;
اللتي|التي;شيئ|شيء;انت|أنت;انتم|أنتم;الحمدلله|الحمد لله;انشالله|إن شاء الله;إنشالله|إن شاء الله;
انشاء الله|إن شاء الله;إنشاء الله|إن شاء الله;ان شاء الله|إن شاء الله;ماشاء الله|ما شاء الله;
ماشاءالله|ما شاء الله;باذن الله|بإذن الله;إستخدام|استخدام;إستقبال|استقبال;إستلام|استلام;
إستفسار|استفسار;إستمارة|استمارة;إجتماع|اجتماع;إنتظار|انتظار;إختيار|اختيار;إتصال|اتصال;
إنتهاء|انتهاء;إعتماد|اعتماد;إقتراح|اقتراح;إحتياج|احتياج"""
    ## Common Arabic slips: hamzas left out where only one reading is a
    ## word, a hamza where none goes, letters in excess.

  Abbreviations = ["mr", "mrs", "ms", "dr", "prof", "st", "no", "nos", "vs", "etc", "e.g", "i.e",
                   "approx", "inc", "ltd", "co", "corp", "jr", "sr", "cf", "ca", "fig", "a.m",
                   "p.m", "dept", "est", "tel", "ext", "ref", "jan", "feb", "mar", "apr", "jun",
                   "jul", "aug", "sep", "sept", "oct", "nov", "dec"]
    ## a period after these does not end a sentence

var
  acOn = {acReplace, acSuggest, acCapitalize}
  acBuiltIn: Table[string, string]   ## typed (lower case for English) -> replacement
  acOwn: Table[string, string]       ## the user's (a replacement "": a built-in one taken out)
  acPhrases: seq[string]             ## the entries of more than one word, longest first
  acSymbols: seq[(string, string)]   ## the entries that end in a symbol: "(c)", "-->"
  acLoaded = false

proc autoCorrectFile*(): string =
  ## Where the user's own AutoCorrect entries are kept: "typed<TAB>replacement"
  ## a line.
  dataDir("retro") / "autocorrect.txt"

proc acIndex() =
  acPhrases.setLen(0)
  acSymbols.setLen(0)
  for k, v in acOwn:
    if v.len > 0 and ' ' in k: acPhrases.add k
  for k in acBuiltIn.keys:
    if ' ' in k and k notin acOwn: acPhrases.add k
  acPhrases.sort(proc (a, b: string): int = cmp(b.len, a.len))
  proc symbolic(k: string): bool =
    var r: Rune
    var last = 0
    var i = 0
    while i < k.len:
      fastRuneAt(k, i, r, true)
      last = int(r)
    not (isLetter(last) or isMark(last) or isDigitRune(last) or last == ord('_') or isApostrophe(last))
  for k, v in acOwn:
    if v.len > 0 and symbolic(k): acSymbols.add (k, v)
  for k, v in acBuiltIn:
    if k notin acOwn and symbolic(k): acSymbols.add (k, v)

proc acLoad() =
  if acLoaded: return
  acLoaded = true
  for list in [EnglishList, ArabicList]:
    for e in list.split({';', '\n'}):
      let e2 = e.strip
      let k = e2.find('|')
      if k > 0: acBuiltIn[e2[0 ..< k]] = e2[k + 1 .. ^1]
  try:
    let path = autoCorrectFile()
    if fileExists(path):
      for ln in lines(path):
        let k = ln.find('\t')
        if k > 0: acOwn[ln[0 ..< k]] = ln[k + 1 .. ^1].strip(leading = false, chars = {'\r'})
  except IOError, OSError: discard
  acIndex()

proc acSave() =
  try:
    var keys = toSeq(acOwn.keys)
    keys.sort()
    var s = ""
    for k in keys: s.add k & '\t' & acOwn[k] & '\n'
    writeFile(autoCorrectFile(), s)
  except IOError, OSError: discard

proc autoCorrectEnable*(kind: AutoCorrectKind; on = true) =
  ## Turns one kind of AutoCorrect on or off (for every editor; the lists,
  ## the suggestions in English and others, capitals are on at first).
  if on: acOn.incl kind else: acOn.excl kind

proc autoCorrectEnabled*(kind: AutoCorrectKind): bool = kind in acOn
  ## That kind of AutoCorrect is on.

proc autoCorrectAdd*(typed, replacement: string) =
  ## `typed` becomes `replacement` as one types it (the user's own list,
  ## kept in `autoCorrectFile`); several words are fine ("btw" -> "by the
  ## way", "ان شاء الله" -> "إن شاء الله").
  let t = typed.strip
  let r = replacement.strip
  if t.len == 0 or r.len == 0 or '\t' in t or '\n' in t or '\n' in r or '\t' in r: return
  acLoad()
  acOwn[t] = r
  acIndex()
  acSave()

proc autoCorrectRemove*(typed: string) =
  ## Takes `typed` out of AutoCorrect (one of the built-in entries too: it
  ## stays out).
  let t = typed.strip
  if t.len == 0: return
  acLoad()
  if t in acBuiltIn or t.toLower in acBuiltIn: acOwn[t] = ""
  else: acOwn.del t
  acIndex()
  acSave()

proc autoCorrectEntries*(): seq[tuple[typed, replacement: string; own: bool]] =
  ## The AutoCorrect entries (the built-in ones and the user's), sorted;
  ## `own`: the user's.
  acLoad()
  for k, v in acBuiltIn:
    if k notin acOwn: result.add (k, v, false)
  for k, v in acOwn:
    if v.len > 0: result.add (k, v, true)
  result.sort(proc (a, b: tuple[typed, replacement: string; own: bool]): int = cmp(a.typed, b.typed))

proc adaptCase(typed, by: string): string =
  ## `by` in the capitals `typed` had: "Teh" -> "The", "TEH" -> "THE".
  var letters, upper = 0
  var firstUpper = false
  var first = true
  for r in typed.runes:
    if r.isAlpha:
      inc letters
      if r.isUpper:
        inc upper
        if first: firstUpper = true
      first = false
  if letters >= 2 and upper == letters: return by.toUpper
  if firstUpper and by.len > 0:
    let r0 = by.runeAt(0)
    return r0.toUpper.toUTF8 & by[r0.size .. ^1]
  by

proc acLookup(w: string; english, arabic: bool): tuple[found: bool; by: string] =
  ## The list's replacement for `w` ("" with `found`: taken out).
  acLoad()
  if w in acOwn: return (true, acOwn[w])
  let low = w.toLower
  if low != w and low in acOwn:
    let v = acOwn[low]
    return (true, if v.len > 0: adaptCase(w, v) else: "")
  if english and low in acBuiltIn and scriptOfWord(low) == scLatin:
    return (true, adaptCase(w, acBuiltIn[low]))
  if arabic and w in acBuiltIn and scriptOfWord(w) == scArabic: return (true, acBuiltIn[w])
  (false, "")

proc acLangOf(w, lang: string): string =
  ## The language AutoCorrect takes `w` in: `lang`, else the user's when
  ## its script is the word's, else Arabic or English by the script.
  if lang.len > 0: return lang
  start()
  let sc = scriptOfWord(w)
  if sc == scriptOfLang(userLang) or sc in {scNone, scMixed, scOther}: userLang
  elif sc == scArabic: "ar"
  elif sc == scLatin: "en"
  else: userLang

proc autoCorrectLookup*(typed: string; lang = ""): string =
  ## What the AutoCorrect lists make of `typed` ("" nothing): the user's
  ## list, then English's for an English word, Arabic's for an Arabic one.
  let l = primary(normTag(acLangOf(typed, lang)))
  let (found, by) = acLookup(typed, l == "en", l == "ar")
  if found and by != typed: by else: ""

proc runeBack(s: string; i: int): int =
  ## The start of the character that ends at byte `i`.
  var j = i - 1
  while j > 0 and (s[j].uint8 and 0xC0) == 0x80: dec j
  max(0, j)

proc runeAtB(s: string; i: int): int =
  var r: Rune
  var k = i
  fastRuneAt(s, k, r, true)
  int(r)

proc isWordRune(c: int): bool =
  isLetter(c) or isMark(c) or isDigitRune(c) or c == ord('_')

proc editDistance1(a, b: string): bool =
  ## `a` and `b` are one letter apart: one put in, taken out, changed, or two
  ## side by side swapped.
  let x = a.toLower.toRunes
  let y = b.toLower.toRunes
  if abs(x.len - y.len) > 1 or x == y: return false
  if x.len == y.len:
    var diffs: seq[int]
    for i in 0 ..< x.len:
      if x[i] != y[i]: diffs.add i
    if diffs.len == 1: return true
    return diffs.len == 2 and diffs[1] == diffs[0] + 1 and
           x[diffs[0]] == y[diffs[1]] and x[diffs[1]] == y[diffs[0]]
  let (s, l) = if x.len < y.len: (x, y) else: (y, x)
  var i = 0
  while i < s.len and s[i] == l[i]: inc i
  s[i .. ^1] == l[i + 1 .. ^1]

proc sentenceStart(text: string; a: int): bool =
  ## The word at byte `a` starts a sentence: the paragraph's first, or after
  ## ".", "!", "?" and a space (not after "e.g." or "Mr.").
  var i = a
  while i > 0 and runeAtB(text, runeBack(text, i)) in [ord('"'), ord('\''), ord('('), ord('['),
                                                         0x201C, 0x2018, 0xAB, 0xBF, 0xA1]:
    i = runeBack(text, i)
  var spaces = 0
  while i > 0 and isSpaceRune(runeAtB(text, runeBack(text, i))):
    i = runeBack(text, i)
    inc spaces
  if i == 0: return true
  if spaces == 0: return false
  while i > 0 and text[i - 1] in {'"', '\'', ')', ']'}: dec i
  if i == 0 or text[i - 1] notin {'.', '!', '?'}: return false
  if text[i - 1] in {'!', '?'}: return true
  # a period: not an abbreviation's, not "..."
  let dotAt = i - 1
  if dotAt > 0 and text[dotAt - 1] == '.': return false
  var k = dotAt
  while k > 0 and (isLetter(runeAtB(text, runeBack(text, k))) or text[k - 1] == '.'):
    k = runeBack(text, k)
  let before = text[k ..< dotAt].toLower
  if before.runeLen <= 1: return false            # (an initial: "J. Smith")
  before notin Abbreviations

proc autoCorrect*(text: string; caret: int; lang = ""): tuple[a, b: int; replacement: string] =
  ## What AutoCorrect makes of what was just typed: the character before
  ## byte `caret` of `text` (a paragraph; "\n" after it for Enter). When it
  ## ends a word -- a space, a punctuation mark -- the word before it (or
  ## the words, "ان شاء الله") from the lists, a spelling suggestion, a
  ## capital at a sentence's start; symbols ("(c)", "-->") as their last
  ## character is typed. The result: bytes `a ..< b` of `text` become
  ## `replacement` ("" when nothing changes). Words in web and e-mail
  ## addresses are left alone. `lang`: the language ("": by the script).
  result = (caret, caret, "")
  if caret <= 0 or caret > text.len or acOn == {}: return
  let k = runeBack(text, caret)
  let typed = runeAtB(text, k)
  if isWordRune(typed) or isApostrophe(typed): return
  # symbols: an entry that the character typed ends
  if acReplace in acOn:
    acLoad()
    for (key, by) in acSymbols:
      if key.len <= caret and text.continuesWith(key, caret - key.len):
        let s0 = caret - key.len
        if s0 == 0 or isSpaceRune(runeAtB(text, runeBack(text, s0))):
          result = (s0, caret, by); return
  # (not the end of a word: inside an address or a number)
  if typed in [ord('.'), ord(':'), ord('/'), ord('@'), ord('-'), ord('#'), ord('&'), ord('='),
               ord('+'), ord('%'), ord('~'), ord('_')]:
    return
  # the word before it (a period or colon between: "teh. ")
  var e = k
  if e > 0 and text[e - 1] in {'.', ':'} and e >= 2 and isWordRune(runeAtB(text, runeBack(text, e - 1))):
    dec e
  if e > 0 and isApostrophe(runeAtB(text, runeBack(text, e))): e = runeBack(text, e)
  var a = e
  while a > 0:
    let p = runeBack(text, a)
    let c = runeAtB(text, p)
    if isWordRune(c) or c in 0x200C .. 0x200D: a = p
    elif isApostrophe(c) and p > 0 and isWordRune(runeAtB(text, runeBack(text, p))): a = p
    else: break
  if a == e: return
  # at a word's start: not in an address ("www.teh", "me@teh", "a/teh")
  if a > 0:
    let c = runeAtB(text, runeBack(text, a))
    if not (isSpaceRune(c) or c in [ord('('), ord('['), ord('{'), ord('"'), ord('\''), 0x201C,
                                    0x2018, 0xAB, 0xBF, 0xA1]):
      return
  var c0 = a
  while c0 > 0 and not isSpaceRune(runeAtB(text, runeBack(text, c0))): c0 = runeBack(text, c0)
  if skipChunk(text, c0, e): return
  let word = text[a ..< e]
  var hasDigit = false
  for r in word.runes:
    if isDigitRune(int(r)): hasDigit = true
  if hasDigit: return
  let wl = primary(normTag(acLangOf(word, lang)))
  let sc = scriptOfWord(word)
  var by = ""
  var from0 = a
  var listed = false
  if acReplace in acOn:
    # entries of more words first ("ان شاء الله")
    for ph in acPhrases:
      if ph.len > e: continue
      let s0 = e - ph.len
      let seg = text[s0 ..< e]
      let psc = scriptOfWord(ph)
      if seg != ph and not (psc == scLatin and seg.toLower == ph.toLower): continue
      if s0 > 0 and not isSpaceRune(runeAtB(text, runeBack(text, s0))): continue
      let own = ph in acOwn
      if not own and not (psc == scArabic and wl == "ar" or psc == scLatin and wl == "en"):
        continue
      by = adaptCase(seg, if own: acOwn[ph] else: acBuiltIn[ph])
      from0 = s0
      break
    if by.len == 0:
      let (found, v) = acLookup(word, wl == "en", wl == "ar")
      listed = found                             # (taken out of the list: v is "")
      by = v
  # a spelling suggestion one letter away
  let suggestOn = if sc == scArabic: acSuggestArabic in acOn else: acSuggest in acOn
  if by.len == 0 and not listed and suggestOn and word.runeLen > 3 and sc != scMixed:
    var capsInside = false
    var first = true
    for r in word.runes:
      if not first and r.isUpper: capsInside = true
      first = false
    let firstUp = word.runeAt(0).isUpper
    if not capsInside and (not firstUp or sentenceStart(text, a)) and isMisspelled(word, lang):
      var near: seq[string]
      for s in spellSuggest(word, lang, 10):
        var plain = true
        for c in s:
          if c in {' ', '-', '\''}: plain = false
        if plain and editDistance1(word, s): near.add s
      if near.len == 1: by = adaptCase(word, near[0])
  # a capital at a sentence's start
  if acCapitalize in acOn and sc in {scLatin, scCyrillic, scGreek} and sentenceStart(text, from0):
    let cur = if by.len > 0: by else: word
    var allLower = true
    for r in cur.runes:
      if r.isUpper: allLower = false
    let r0 = cur.runeAt(0)
    if allLower and r0.isLower: by = r0.toUpper.toUTF8 & cur[r0.size .. ^1]
  if by.len > 0 and by != text[from0 ..< e]: result = (from0, e, by)

proc spellReload*() =
  ## Forgets the words ignored and the verdicts given, and reads the user's
  ## dictionary and AutoCorrect entries again (another program may have
  ## changed them).
  ignored.clear()
  userWords.clear()
  userLoaded = false
  loadUserWords()
  acBuiltIn.clear()
  acOwn.clear()
  acLoaded = false
  forget()
