## Tests of retroui/uistrings (`retrokit strings`: an app's texts for
## translators, kept across runs) and of `trn` and `pluralForm`.

import std/[sets, strutils]
import retroui

block collect:
  let code = """
import retroui
# label "not this: a comment"
app "Notes", 300, 200:
  label "Hello"
  if button("&Save"): discard
  menuItem("E&xit", "Alt+F4")
  label tr("Fahrenheit = Celsius")
  label trn(n, "{n} file", "{n} files")
  let s = "not a label"
  label "Hello"
  label "https://example.com"
  let doc = \"\"\"label "inside a long string\"\"\"
"""
  var keys: seq[string]
  var seen: HashSet[string]
  collectFrom(code, keys, seen)
  doAssert keys == @["Notes", "Hello", "Save", "Exit", "Fahrenheit = Celsius",
                     "{n} file|{n} files"], $keys

block roundTrip:
  let keys = @["Save", "Fahrenheit = Celsius", "{n} file|{n} files", "Two\nlines"]
  let first = writeUiStrings(keys, [], "ar")
  doAssert "Fahrenheit \\= Celsius = " in first
  # a translator fills two in; the app gets a new text and loses one
  var filled = first.replace("Save = ", "Save = حفظ").replace(
    "{n} file|{n} files = ", "{n} file|{n} files = لا ملفات|ملف واحد|ملفان|{n} ملفات|{n} ملفًا|{n} ملف")
  let pairs = parseUiStrings(filled)
  doAssert ("Save", "حفظ") in pairs
  doAssert ("Fahrenheit = Celsius", "") in pairs
  doAssert ("Two\nlines", "") in pairs
  let again = writeUiStrings(@["{n} file|{n} files", "Open"], pairs, "ar")
  doAssert "Open = \n" in again
  doAssert "# no longer in the app:\nSave = حفظ" in again      # (not lost)
  setUiLanguage("ar", parseUiStrings(again))
  doAssert trn(0, "{n} file", "{n} files") == "لا ملفات"
  doAssert trn(2, "{n} file", "{n} files") == "ملفان"
  doAssert trn(5, "{n} file", "{n} files") == "5 ملفات"
  doAssert trn(11, "{n} file", "{n} files") == "11 ملفًا"
  doAssert trn(100, "{n} file", "{n} files") == "100 ملف"
  setUiLanguage("en")
  doAssert trn(1, "{n} file", "{n} files") == "1 file"
  doAssert trn(3, "{n} file", "{n} files") == "3 files"

block plurals:
  doAssert pluralForm("en", 1) == 0 and pluralForm("en", 0) == 1
  doAssert pluralForm("fr", 0) == 0 and pluralForm("fr", 2) == 1
  doAssert pluralForm("ru", 21) == 0 and pluralForm("ru", 23) == 1 and pluralForm("ru", 12) == 2
  doAssert pluralForm("pl", 1) == 0 and pluralForm("pl", 22) == 1 and pluralForm("pl", 21) == 2
  doAssert pluralForm("ar", 103) == 3 and pluralForm("ar", 199) == 4 and pluralForm("ar", 200) == 5
  doAssert pluralForm("ja", 7) == 0

echo "uistrings OK"
