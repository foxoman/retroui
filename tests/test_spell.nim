## Tests of spell checking and AutoCorrect (`retroui/spell`): the words looked
## at, the system's checker (Hunspell on Linux), the user's dictionary and
## AutoCorrect list kept on disk, Arabic, speed.
##
##   nim c -r tests/test_spell.nim
##
## Built for Windows (`-d:mingw`) and run under Wine, it checks that a
## system without the checker says so and nothing breaks; on Windows 8 and
## later the checks of the words run too.

import std/[os, strutils, times, monotimes, sequtils]

# (the user's lists in a folder of the test's, not in the real ones)
let data = getTempDir() / "retro-test-spell"
removeDir(data)
createDir(data)
putEnv("XDG_DATA_HOME", data)
putEnv("APPDATA", data)

import retroui/spell

proc words(t: string): seq[string] =
  for (a, b) in spellWords(t): result.add t[a ..< b]

proc typed(t: string; lang = ""): string =
  ## `t` as AutoCorrect leaves it when its last character was just typed.
  let r = autoCorrect(t, t.len, lang)
  if r.replacement.len == 0: t else: t[0 ..< r.a] & r.replacement & t[r.b .. ^1]

echo "  checker: ", (if spellBackend().len > 0: spellBackend() else: "none"),
     ", languages: ", spellLanguages(), ", the user's: ", spellUserLanguage()

# ---- the words looked at ------------------------------------------------------------------------------

block wordsAndSkipping:
  doAssert words("Hello, world! It's fine.") == @["Hello", "world", "It's", "fine"]
  # digits, acronyms, single letters, addresses are not checked
  doAssert words("abc123 4x4 2026 NASA HR A I b ok") == @["ok"], $words("abc123 4x4 2026 NASA HR A I b ok")
  doAssert words("see https://nim-lang.org/docs or www.foxoman.net, mail me@foxoman.net now") ==
           @["see", "or", "mail", "now"], $words("see https://nim-lang.org/docs or www.foxoman.net")
  doAssert words("nim-lang.org and #tag and C:\\Users\\x") == @["and", "and"]
  # apostrophes inside a word stay, at its ends they go; hyphens split
  doAssert words("don't 'quoted' students' rock’n’roll") == @["don't", "quoted", "students", "rock’n’roll"],
           $words("don't 'quoted' students' rock’n’roll")
  doAssert words("well-known e-mail") == @["well", "known", "mail"]
  doAssert words("snake_case camelCase") == @["camelCase"]
  # Unicode: accents, Arabic with its marks, Arabic digits
  doAssert words("naïve café") == @["naïve", "café"]
  doAssert words("مَرْحَبًا بالعالم ٢٠٢٦ ع") == @["مَرْحَبًا", "بالعالم"], $words("مَرْحَبًا بالعالم ٢٠٢٦ ع")
  doAssert words("نص،عربي؟ نعم") == @["نص", "عربي", "نعم"]
  # what is not checked is never misspelled
  for w in ["NASA", "abc123", "x", "https://teh.com", "me@teh.com", "٢٠٢٦"]:
    doAssert not isMisspelled(w), w

# ---- AutoCorrect: the lists (the same everywhere) --------------------------------------------------

block autoCorrectLists:
  autoCorrectEnable(acSuggest, false)        # (the lists alone here)
  doAssert autoCorrectEnabled(acReplace) and autoCorrectEnabled(acCapitalize)
  doAssert not autoCorrectEnabled(acSuggestArabic), "off at first"
  doAssert typed("hello teh ") == "hello the "
  doAssert typed("so Teh ") == "so The "
  doAssert typed("so TEH ") == "so THE "
  doAssert typed("so adn,") == "so and,"
  doAssert typed("he said teh.") == "he said teh.", "a period may be in an address: wait"
  doAssert typed("he said teh. ") == "he said the. "
  doAssert typed("so i ") == "so I "
  doAssert typed("so i'm ") == "so I'm "
  doAssert typed("so dont ") == "so don't "
  doAssert typed("there is alot ") == "there is a lot "
  doAssert typed("hello (c)") == "hello ©"
  doAssert typed("a -->") == "a →"
  doAssert typed("so \"teh\"") == "so \"the\""
  # a sentence's first letter
  doAssert typed("hello ") == "Hello "
  doAssert typed("Fine. this ") == "Fine. This "
  doAssert typed("Fine! teh ") == "Fine! The "
  doAssert typed("Fine. iPhone ") == "Fine. iPhone ", "a word with capitals stays"
  doAssert typed("See e.g. this ") == "See e.g. this "
  doAssert typed("Mr. smith ") == "Mr. smith "
  doAssert typed("J. smith ") == "J. smith "
  doAssert typed("Wait... then ") == "Wait... then "
  autoCorrectEnable(acCapitalize, false)
  doAssert typed("hello ") == "hello "
  doAssert typed("teh ") == "the "
  autoCorrectEnable(acCapitalize)
  # addresses are left alone
  doAssert typed("see http://teh ") == "see http://teh "
  doAssert typed("see www.teh.com ") == "see www.teh.com "
  doAssert typed("mail me@teh.com ") == "mail me@teh.com "
  doAssert typed("see teh.com/x ") == "see teh.com/x "
  doAssert typed("so 2teh ") == "so 2teh "
  # Arabic
  doAssert typed("ذهبت الى ") == "ذهبت إلى "
  doAssert typed("انا ") == "أنا "
  doAssert typed("قال اذا،") == "قال إذا،"
  doAssert typed("لاكن ") == "لكن "
  doAssert typed("هاذا ") == "هذا "
  doAssert typed("ذالك ") == "ذلك "
  doAssert typed("سنلتقي ان شاء الله ") == "سنلتقي إن شاء الله "
  doAssert typed("سنلتقي انشاء الله. ") == "سنلتقي إن شاء الله. "
  doAssert typed("سنلتقي انشاء الله،") == "سنلتقي إن شاء الله،"
  doAssert typed("ايضا ") == "أيضاً "
  doAssert typed("تم إستلام ") == "تم استلام "
  # ... a correct word never changes
  for w in ["إلى", "أنا", "إذا", "لكن", "هذا", "ذلك", "كتاب", "إنشاء", "انشاء", "ان", "على", "علي",
            "الذي", "اللذين", "استلام", "أيضاً", "الله"]:
    doAssert typed(w & " ") == w & " ", w
  # English words in Arabic ones' places: the English list is for English
  doAssert typed("dont ", "fr") == "Dont ", "French has \"dont\""
  doAssert autoCorrectLookup("teh") == "the" and autoCorrectLookup("Teh") == "The"
  doAssert autoCorrectLookup("الى") == "إلى" and autoCorrectLookup("the") == ""
  doAssert autoCorrectEntries().len > 300

block autoCorrectOwnList:
  doAssert not fileExists(autoCorrectFile())
  autoCorrectAdd("btw", "by the way")
  autoCorrectAdd("ق.م", "قبل الميلاد")
  autoCorrectAdd("om ltd", "Oman Ltd.")
  doAssert typed("ok btw ") == "ok by the way "
  doAssert typed("ok Btw ") == "ok By the way "
  doAssert typed("for om ltd ") == "for Oman Ltd. "
  autoCorrectRemove("teh")                    # a built-in one: it stays out
  doAssert typed("so teh ") == "so teh "
  doAssert autoCorrectEntries().anyIt(it.typed == "btw" and it.own)
  doAssert not autoCorrectEntries().anyIt(it.typed == "teh")
  # kept on disk, read again
  let saved = readFile(autoCorrectFile())
  doAssert "btw\tby the way\n" in saved and "teh\t\n" in saved, saved
  spellReload()
  doAssert typed("ok btw ") == "ok by the way "
  doAssert typed("so teh ") == "so teh "
  autoCorrectRemove("btw")
  autoCorrectAdd("teh", "the")                # back
  doAssert typed("ok btw ") == "ok btw "
  doAssert typed("so teh ") == "so the "
  autoCorrectEnable(acReplace, false)
  doAssert typed("so teh ") == "so teh "
  autoCorrectEnable(acReplace)
  autoCorrectEnable(acSuggest)

# ---- the system's checker ---------------------------------------------------------------------------

if not spellAvailable():
  echo "  (no spell checker here: the checks of the words are skipped)"
  doAssert not isMisspelled("recieve") and spellSuggest("recieve").len == 0
  doAssert spellLanguages().len == 0 or spellBackend().len > 0
  spellIgnore("x")                            # (nothing breaks)
  spellAdd("Foxoman")
  doAssert fileExists(spellWordsFile())

if spellAvailable("en-US"):
  block english:
    doAssert spellLanguageOf("hello") == "en-US"
    for w in ["receive", "Hello", "don't", "well-known", "The", "people"]:
      doAssert not isMisspelled(w), w
    for w in ["recieve", "teh", "dont", "wel-known", "Helo", "peolpe"]:
      doAssert isMisspelled(w), w
    let s = spellSuggest("recieve")
    doAssert s.len > 0 and s.len <= 6 and s[0] == "receive", $s
    doAssert spellSuggest("recieve", max = 1).len == 1
    doAssert "people" in spellSuggest("peolpe"), $spellSuggest("peolpe")
    doAssert spellSuggest("Recieve")[0] == "Receive", "the capital kept"

  block ignoreAndAdd:
    let g0 = spellGeneration()
    doAssert isMisspelled("Foxoman") and isMisspelled("Sohari")
    spellAdd("Foxoman")
    doAssert spellGeneration() != g0, "verdicts kept elsewhere must be looked at again"
    doAssert not isMisspelled("Foxoman")
    spellIgnore("Sohari")
    doAssert not isMisspelled("Sohari")
    spellAdd("nimony")
    doAssert not isMisspelled("Nimony"), "added in lower case: the capital at a sentence's start too"
    doAssert "Foxoman" in readFile(spellWordsFile()).splitLines
    # read again: the user's words stay, what was ignored is forgotten
    spellReload()
    doAssert not isMisspelled("Foxoman") and isMisspelled("Sohari")
    # Hunspell learns them: suggested too
    if spellBackend() == "hunspell":
      doAssert "Foxoman" in spellSuggest("Foxomann"), $spellSuggest("Foxomann")

  block autoCorrectSuggestions:
    # a misspelled word with one suggestion one letter away takes it
    doAssert typed("the langauge ") == "the language ", typed("the langauge ")
    doAssert typed("I recieve ") == "I receive "
    doAssert typed("I Foxomann ") == "I Foxomann ", "a name (a capital) stays"
    doAssert typed("I helo ") == "I helo ", "more than one suggestion: none taken"
    doAssert typed("I tha ") == "I tha ", "three letters or fewer: left alone"
    autoCorrectEnable(acSuggest, false)
    doAssert typed("the langauge ") == "the langauge "
    autoCorrectEnable(acSuggest)

  block speed:
    # a long mail, 5,000 words, some misspelled
    let vocab = ["the", "meeting", "tomorrow", "recieve", "schedule", "employees", "training",
                 "hotel", "guests", "quality", "teh", "report", "Sohar", "documents", "pleese",
                 "department", "manager", "approval", "occured", "salary"]
    var text = ""
    for i in 0 ..< 5000:
      text.add vocab[(i * 7 + i div 13) mod vocab.len]
      text.add(if i mod 17 == 16: ". " else: " ")
    let t0 = getMonoTime()
    let ws = spellWords(text)
    var bad = 0
    for (a, b) in ws:
      if isMisspelled(text[a ..< b]): inc bad
    let first = (getMonoTime() - t0).inMicroseconds.float / 1000
    doAssert ws.len == 5000 and bad > 0, $(ws.len, bad)
    var again = 1e9
    for round in 0 ..< 5:
      let t1 = getMonoTime()
      var bad2 = 0
      for (a, b) in spellWords(text):
        if isMisspelled(text[a ..< b]): inc bad2
      again = min(again, (getMonoTime() - t1).inMicroseconds.float / 1000)
      doAssert bad2 == bad
    # what a screen shows (about 400 words), checked again each frame
    let screen = text[0 ..< ws[400][0]]
    var shown = 1e9
    for round in 0 ..< 5:
      let t2 = getMonoTime()
      for (a, b) in spellWords(screen): discard isMisspelled(screen[a ..< b])
      shown = min(shown, (getMonoTime() - t2).inMicroseconds.float / 1000)
    echo "  5,000 words: first ", first.formatFloat(ffDecimal, 2), " ms, again ",
         again.formatFloat(ffDecimal, 2), " ms; a screen of 400 again ",
         shown.formatFloat(ffDecimal, 3), " ms"
    # (a debug build is some ten times slower; the editor keeps each
    # paragraph's verdicts besides: a frame asks nothing again)
    # (and the sanitizers some 7 times slower than that)
    const slower = when defined(retroSanitized): 7.0 else: 1.0
    doAssert again < (when defined(release): 2.0 else: 30.0) * slower, "5,000 words checked again: " & $again & " ms"
    doAssert shown < (when defined(release): 0.5 else: 3.0) * slower, "a screen checked again: " & $shown & " ms"

if spellAvailable("ar"):
  block arabic:
    doAssert spellLanguageOf("مرحبا") == "ar" and spellLanguageOf("hello") == "en-US"
    for w in ["مرحبا", "كتاب", "إلى", "الكتاب", "مَرْحَبًا"]:
      doAssert not isMisspelled(w), w
    for w in ["كتابب", "الى"]:
      doAssert isMisspelled(w), w
    doAssert "كتاب" in spellSuggest("كتابب"), $spellSuggest("كتابب")
    # a mail of both: each word in its own language
    let mixed = "Dear team, الاجتماع غداً in the hotel. شكرا recieve كتابب"
    var bad: seq[string]
    for (a, b) in spellWords(mixed):
      if isMisspelled(mixed[a ..< b]): bad.add mixed[a ..< b]
    doAssert bad == @["recieve", "كتابب"], $bad
    # an English dictionary does not judge Arabic letters
    doAssert not isMisspelled("كتابب", "en-US")
    # Arabic suggestions are not taken as one types, unless asked
    doAssert typed("قرأت كتابب ") == "قرأت كتابب "
    spellAdd("سوهاري")
    doAssert not isMisspelled("سوهاري")

echo "spell: all tests passed"
