## An app's words, for translators: `retrokit strings app.nim --lang:ar`
## collects every text the app shows (what its labels, buttons, menus,
## titles and `tr` / `trn` calls say) into app-ar.txt, one line each, for
## a translator to fill in; `loadUiStrings` reads it back for
## `setUiLanguage`:
##
## .. code-block:: nim
##   setUiLanguage("ar", loadUiStrings(getAppDir() / "app-ar.txt"))
##
## The file is plain text, a line for each text: the English, " = ", what
## it is in the other language (empty: not translated yet). A text with
## forms for numbers (`trn`) has its forms between "|": "{n} file|{n}
## files = ..." -- in the language's order (Arabic: zero, one, two, few,
## many, other). Lines starting with # are notes. Run it again after
## changing the app: the translations there are kept, new texts added.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, tables, sets]

const uiProcs = ["label", "button", "menuItem", "menu", "checkbox", "radio", "group",
                 "card", "tab", "field", "tooltip", "tr", "trn", "msgBox", "dialog",
                 "settingCombo", "settingButtons", "settingSwitch", "barButton", "link",
                 "statusbar", "setTitle", "toast", "banner", "heading", "section",
                 "pageHeader", "aboutBox", "app", "openApp", "paragraph", "chip", "switch",
                 "segmented", "toolButton", "submenu", "styledText", "caption", "help",
                 "beginDialog", "emptyState", "infoProp", "textProp", "groupBox"]
  ## (the calls whose first text is shown to the user)

proc plainLabel(s: string): string =
  ## (a label as `tr` looks it up: "&" left out, "&&" one "&")
  var i = 0
  while i < s.len:
    if s[i] == '&':
      if i + 1 < s.len and s[i + 1] == '&':
        result.add '&'
        inc i
    else: result.add s[i]
    inc i

proc unescape(s: string; i: var int): string =
  ## (a Nim string literal from s[i] -- its opening quote -- to its end; i
  ## after it)
  inc i
  while i < s.len and s[i] != '"':
    if s[i] == '\\' and i + 1 < s.len:
      inc i
      case s[i]
      of 'n': result.add '\n'
      of 't': result.add '\t'
      of '"': result.add '"'
      of '\\': result.add '\\'
      of '\'': result.add '\''
      else:
        result.add '\\'
        result.add s[i]
    elif s[i] == '\n':                   # (not a string after all)
      result = ""
      return
    else: result.add s[i]
    inc i
  inc i

proc collectFrom*(code: string; into: var seq[string]; seen: var HashSet[string]) =
  ## The texts the calls in `code` show (see `uiProcs`), in order, each
  ## once.
  var i = 0
  template keep(t: string) =
    let k = plainLabel(t)
    if k.strip.len > 0 and k notin seen and not k.startsWith("http"):
      seen.incl k
      into.add k
  while i < code.len:
    let c = code[i]
    if c == '#':
      # (a comment: to the end of the line; ## doc comments too)
      while i < code.len and code[i] != '\n': inc i
      continue
    if c == '"':
      if code.continuesWith("\"\"\"", i):
        let e = code.find("\"\"\"", i + 3)
        i = if e < 0: code.len else: e + 3
      else: discard unescape(code, i)
      continue
    if c in IdentStartChars and (i == 0 or code[i - 1] notin IdentChars + {'.'}):
      var j = i
      while j < code.len and code[j] in IdentChars: inc j
      let word = code[i ..< j]
      i = j
      if word in uiProcs:
        var k = j
        while k < code.len and code[k] in {' ', '('}: inc k
        if word == "trn":
          # (its number first: the forms after it)
          while k < code.len and code[k] notin {',', '\n', '"'}: inc k
          if k < code.len and code[k] == ',': inc k
          while k < code.len and code[k] == ' ': inc k
        if k < code.len and code[k] == '"' and not code.continuesWith("\"\"\"", k):
          let first = unescape(code, k)
          if word == "trn":
            # (both forms: "one|many")
            var m = k
            while m < code.len and code[m] in {' ', ','}: inc m
            if m < code.len and code[m] == '"':
              let second = unescape(code, m)
              keep(first & "|" & second)
              i = m
              continue
          if first.len > 0 and '\n' notin first: keep(first)
          i = k
      continue
    inc i

proc collectUiStrings*(files: openArray[string]): seq[string] =
  ## The texts the app made of `files` shows, each once, in the order met.
  var seen: HashSet[string]
  for f in files:
    try: collectFrom(readFile(f), result, seen)
    except IOError: discard

proc keyOut(k: string): string =
  ## (a text as the file has it: its line breaks and its "=" escaped)
  k.replace("\\", "\\\\").replace("\n", "\\n").replace("=", "\\=")

proc keyIn(k: string): string =
  var i = 0
  while i < k.len:
    if k[i] == '\\' and i + 1 < k.len:
      inc i
      result.add(if k[i] == 'n': '\n' else: k[i])
    else: result.add k[i]
    inc i

proc parseUiStrings*(text: string): seq[(string, string)] =
  ## The pairs of a strings file (see the module's notes).
  for line in text.splitLines:
    if line.len == 0 or line.startsWith("#"): continue
    # (the first " = " not escaped: an "=" in the English is "\=")
    var eq = -1
    var i = 0
    while i < line.len:
      if line[i] == '\\': i += 2; continue
      if line.continuesWith(" =", i) and (i + 2 == line.len or line[i + 2] == ' '):
        eq = i
        break
      inc i
    if eq < 0: continue
    let v = if eq + 3 <= line.len: line[eq + 3 .. ^1] else: ""
    result.add (keyIn(line[0 ..< eq]), v.replace("\\n", "\n"))

proc loadUiStrings*(path: string): seq[(string, string)] =
  ## A strings file read (empty when it is not there): for `setUiLanguage`.
  try: parseUiStrings(readFile(path)) except IOError, OSError: @[]

proc writeUiStrings*(keys: openArray[string]; kept: openArray[(string, string)];
                     lang: string): string =
  ## A strings file for `lang` of `keys`, the translations in `kept` kept
  ## (also those of texts the app no longer has, at the end: a translator's
  ## work is not lost).
  var known = initTable[string, string]()
  for (k, v) in kept: known[k] = v
  result = "# The texts of the app, for " & lang & ": the English, \" = \", then the\n" &
           "# translation (empty: not done yet). Forms for numbers between \"|\".\n"
  var done = initHashSet[string]()
  for k in keys:
    done.incl k
    result.add keyOut(k) & " = " & known.getOrDefault(k, "").replace("\n", "\\n") & "\n"
  var old = false
  for (k, v) in kept:
    if k notin done and v.len > 0:
      if not old:
        result.add "# no longer in the app:\n"
        old = true
      result.add keyOut(k) & " = " & v.replace("\n", "\\n") & "\n"

proc appSources*(main: string): seq[string] =
  ## The .nim files of the app whose main file is `main`: it and those in
  ## its folder's folder of the same name (examples/mail.nim and
  ## examples/mail/), and in its own folder when it is the only app there.
  result.add main
  let (dir, name, _) = main.splitFile
  let sub = dir / name
  if dirExists(sub):
    for f in walkDirRec(sub):
      if f.endsWith(".nim"): result.add f
