## HTML read into a tree, forgivingly: what browsers make of messy pages
## and of the HTML mail programs write, near enough -- unclosed
## paragraphs, list items and cells closed by what follows, misnested
## tags, missing end tags, stray end tags kept from closing tables, a head
## left open, comments (Outlook's conditional ones too), CDATA, character
## references, bytes that are not UTF-8 (taken as Windows-1252).
##
## The contents of `<script>`, `<style>`, `<title>`, `<textarea>` are raw
## text: never read as HTML. Style sheets are handed out (`HtmlDoc.styles`)
## for `htmlcss` to read; the rest is left out.
##
## Used by `htmlview` (the widgets) and `htmllayout` (the layout engine);
## use it directly to read what a page holds (its links, its text).
##
## ```nim
## proc links(n: HNode; into: var seq[string]) =
##   if n.tag == "a" and n.hasAttr("href"): into.add n.attr("href")
##   for k in n.kids: links(k, into)
##
## let doc = parseHtml("<p>See <a href=\"https://nim-lang.org\">Nim</a>")
## var found: seq[string]
## links(doc.root, found)        # @["https://nim-lang.org"]
## ```

import std/[strutils, tables]
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)

const
  MaxHtml* = 4_000_000       ## bytes of HTML read (the rest is left out)
  MaxDepth* = 96             ## elements in elements deeper than this are taken flat
  MaxNodes* = 250_000        ## elements and texts
  MaxAttrs = 32              ## attributes read per element
  MaxStyleText = 600_000     ## bytes of style sheets kept

# ---- entities -----------------------------------------------------------------------------------

const namedEntities = {
  "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
  "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
  "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›", "lsquo": "‘",
  "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„",
  "bull": "•", "bullet": "•", "middot": "·", "centerdot": "·", "times": "×",
  "divide": "÷", "deg": "°", "plusmn": "±", "micro": "µ", "para": "¶", "sect": "§",
  "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "curren": "¤", "larr": "←",
  "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔", "lArr": "⇐", "rArr": "⇒",
  "hArr": "⇔", "crarr": "↵", "check": "✓", "checkmark": "✓", "cross": "✗",
  "frac12": "½", "half": "½", "frac14": "¼", "frac34": "¾", "frac13": "⅓",
  "frac23": "⅔", "sup1": "¹", "sup2": "²", "sup3": "³", "ordf": "ª", "ordm": "º",
  "iexcl": "¡", "iquest": "¿", "shy": "­", "ensp": " ", "emsp": " ",
  "emsp13": " ", "emsp14": " ", "numsp": " ", "puncsp": " ",
  "thinsp": " ", "hairsp": " ", "ZeroWidthSpace": "​",
  "zwj": "‍", "zwnj": "‌", "lrm": "‎", "rlm": "‏",
  "NoBreak": "⁠", "NewLine": "\n", "Tab": "\t",
  "dagger": "†", "Dagger": "‡", "permil": "‰", "prime": "′", "Prime": "″",
  "oline": "‾", "frasl": "⁄", "minus": "−", "lowast": "∗", "infin": "∞",
  "ne": "≠", "le": "≤", "ge": "≥", "asymp": "≈", "equiv": "≡", "sum": "∑",
  "prod": "∏", "radic": "√", "part": "∂", "int": "∫", "forall": "∀", "exist": "∃",
  "empty": "∅", "nabla": "∇", "isin": "∈", "notin": "∉", "ni": "∋", "prop": "∝",
  "and": "∧", "or": "∨", "cap": "∩", "cup": "∪", "there4": "∴", "sim": "∼",
  "cong": "≅", "sub": "⊂", "sup": "⊃", "sube": "⊆", "supe": "⊇", "oplus": "⊕",
  "otimes": "⊗", "perp": "⊥", "sdot": "⋅", "lceil": "⌈", "rceil": "⌉",
  "lfloor": "⌊", "rfloor": "⌋", "lang": "⟨", "rang": "⟩", "loz": "◊",
  "spades": "♠", "clubs": "♣", "hearts": "♥", "diams": "♦", "not": "¬",
  "macr": "¯", "acute": "´", "cedil": "¸", "uml": "¨", "brvbar": "¦",
  "star": "☆", "starf": "★", "phone": "☎", "female": "♀", "male": "♂",
  "sharp": "♯", "flat": "♭", "natural": "♮", "copysr": "℗", "caret": "⁁",
  "hyphen": "‐", "dash": "‐", "horbar": "―", "Vert": "‖", "nldr": "‥",
  "excl": "!", "num": "#", "dollar": "$", "percnt": "%", "lpar": "(", "rpar": ")",
  "ast": "*", "plus": "+", "comma": ",", "period": ".", "sol": "/", "colon": ":",
  "semi": ";", "equals": "=", "quest": "?", "commat": "@", "lsqb": "[",
  "lbrack": "[", "bsol": "\\", "rsqb": "]", "rbrack": "]", "Hat": "^",
  "lowbar": "_", "grave": "`", "lcub": "{", "lbrace": "{", "verbar": "|",
  "vert": "|", "rcub": "}", "rbrace": "}", "tilde": "˜", "circ": "ˆ",
  "Agrave": "À", "Aacute": "Á", "Acirc": "Â", "Atilde": "Ã", "Auml": "Ä",
  "Aring": "Å", "AElig": "Æ", "Ccedil": "Ç", "Egrave": "È", "Eacute": "É",
  "Ecirc": "Ê", "Euml": "Ë", "Igrave": "Ì", "Iacute": "Í", "Icirc": "Î",
  "Iuml": "Ï", "ETH": "Ð", "Ntilde": "Ñ", "Ograve": "Ò", "Oacute": "Ó",
  "Ocirc": "Ô", "Otilde": "Õ", "Ouml": "Ö", "Oslash": "Ø", "Ugrave": "Ù",
  "Uacute": "Ú", "Ucirc": "Û", "Uuml": "Ü", "Yacute": "Ý", "THORN": "Þ",
  "szlig": "ß", "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã",
  "auml": "ä", "aring": "å", "aelig": "æ", "ccedil": "ç", "egrave": "è",
  "eacute": "é", "ecirc": "ê", "euml": "ë", "igrave": "ì", "iacute": "í",
  "icirc": "î", "iuml": "ï", "eth": "ð", "ntilde": "ñ", "ograve": "ò",
  "oacute": "ó", "ocirc": "ô", "otilde": "õ", "ouml": "ö", "oslash": "ø",
  "ugrave": "ù", "uacute": "ú", "ucirc": "û", "uuml": "ü", "yacute": "ý",
  "thorn": "þ", "yuml": "ÿ", "OElig": "Œ", "oelig": "œ", "Scaron": "Š",
  "scaron": "š", "Yuml": "Ÿ", "fnof": "ƒ", "Zcaron": "Ž", "zcaron": "ž",
  "Ccaron": "Č", "ccaron": "č", "Lstrok": "Ł", "lstrok": "ł", "Sacute": "Ś",
  "sacute": "ś", "Zdot": "Ż", "zdot": "ż", "Eogon": "Ę", "eogon": "ę",
  "Aogon": "Ą", "aogon": "ą", "Nacute": "Ń", "nacute": "ń", "Gbreve": "Ğ",
  "gbreve": "ğ", "Idot": "İ", "imath": "ı", "inodot": "ı", "Scedil": "Ş",
  "scedil": "ş", "Rcaron": "Ř", "rcaron": "ř", "Ecaron": "Ě", "ecaron": "ě",
  "Alpha": "Α", "Beta": "Β", "Gamma": "Γ", "Delta": "Δ", "Epsilon": "Ε",
  "Zeta": "Ζ", "Eta": "Η", "Theta": "Θ", "Iota": "Ι", "Kappa": "Κ",
  "Lambda": "Λ", "Mu": "Μ", "Nu": "Ν", "Xi": "Ξ", "Omicron": "Ο", "Pi": "Π",
  "Rho": "Ρ", "Sigma": "Σ", "Tau": "Τ", "Upsilon": "Υ", "Phi": "Φ", "Chi": "Χ",
  "Psi": "Ψ", "Omega": "Ω", "alpha": "α", "beta": "β", "gamma": "γ",
  "delta": "δ", "epsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ",
  "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
  "omicron": "ο", "pi": "π", "rho": "ρ", "sigmaf": "ς", "sigma": "σ", "tau": "τ",
  "upsilon": "υ", "phi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω"}.toTable

const legacyEntities = ["amp", "lt", "gt", "quot", "nbsp", "copy", "reg", "eacute",
                        "egrave", "agrave", "aacute", "uuml", "ouml", "auml", "deg",
                        "middot", "times", "laquo", "raquo", "pound", "yen", "sect"]
  ## named without the ';' in old pages

proc decodeEntities*(t: string; inAttr = false): string =
  ## `t` with its character references ("&amp;", "&#169;", "&#xA9;")
  ## replaced by the characters. `inAttr`: as in an attribute's value,
  ## where "&copy=2" in an address stays as it is.
  if '&' notin t: return t
  result = newStringOfCap(t.len)
  var i = 0
  while i < t.len:
    let ch = t[i]
    if ch != '&':
      result.add ch
      inc i
      continue
    var j = i + 1
    if j < t.len and t[j] == '#':
      inc j
      var hex = false
      if j < t.len and t[j] in {'x', 'X'}:
        hex = true
        inc j
      var v = 0
      var n = 0
      while j < t.len and n < 8 and (if hex: t[j] in HexDigits else: t[j] in Digits):
        v = v * (if hex: 16 else: 10) +
            (if t[j] in Digits: ord(t[j]) - ord('0')
             else: ord(t[j].toLowerAscii) - ord('a') + 10)
        inc j
        inc n
      if n == 0:
        result.add ch
        inc i
        continue
      if j < t.len and t[j] == ';': inc j
      # (the C1 range: what Windows-1252 has there, as browsers do)
      if v in 0x80 .. 0x9F:
        const c1 = [0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
                    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
                    0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
                    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178]
        v = c1[v - 0x80]
      if v == 0 or v > 0x10FFFF or v in 0xD800 .. 0xDFFF: v = 0xFFFD
      result.add $Rune(v)
      i = j
      continue
    var name = ""
    while j < t.len and name.len < 32 and t[j].isAlphaNumeric:
      name.add t[j]
      inc j
    if j < t.len and t[j] == ';' and namedEntities.hasKey(name):
      result.add namedEntities[name]
      i = j + 1
    elif name in legacyEntities and
         not (inAttr and j < t.len and (t[j] == '=' or t[j].isAlphaNumeric)):
      result.add namedEntities[name]
      i = j
    else:
      result.add ch
      inc i

proc htmlEscape*(s: string): string =
  ## `s` safe to put in HTML text: & < > " escaped.
  result = newStringOfCap(s.len + 8)
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    else: result.add c

const cp1252 = [0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
                0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
                0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
                0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178]

proc fixUtf8*(s: string): string =
  ## `s` as valid UTF-8: bytes that are not (a mail in Latin-1 or
  ## Windows-1252 that says nothing) taken as Windows-1252; NUL left out.
  if validateUtf8(s) < 0 and '\0' notin s: return s
  result = newStringOfCap(s.len + 16)
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '\0':
      inc i
      continue
    if ord(c) < 0x80:
      result.add c
      inc i
      continue
    let n = runeLenAt(s, i)
    if n > 1 and i + n <= s.len and validateUtf8(s[i ..< i + n]) < 0:
      result.add s[i ..< i + n]
      i += n
      continue
    let b = ord(c)
    result.add $Rune(if b < 0xA0: cp1252[b - 0x80] else: b)
    inc i

# ---- the document tree ------------------------------------------------------------------------

type
  HNode* = ref object
    ## An element (`tag` its name, lower case) or a text (`tag` "").
    tag*: string               ## the element's name, "" for a text
    text*: string              ## a text's characters
    attrs*: seq[(string, string)]  ## names (lower case) and values
    kids*: seq[HNode]          ## what is in it, in order
    parent* {.cursor.}: HNode  ## what it is in
    classes*: seq[string]      ## its class names
    id*: string                ## its id

  HtmlDoc* = object
    ## A page read: its tree, its title, its style sheets.
    root*: HNode               ## the tree ("#root" holds what the page has)
    title*: string             ## its <title>
    styles*: seq[string]       ## its <style> blocks
    nodes*: int                ## elements and texts in it

proc attr*(n: HNode; name: string): string =
  ## The value of attribute `name` ("" when it has none).
  for (k, v) in n.attrs:
    if k == name: return v

proc hasAttr*(n: HNode; name: string): bool =
  ## Whether the element has attribute `name`.
  for (k, _) in n.attrs:
    if k == name: return true

const
  voidTags = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link",
              "meta", "param", "source", "track", "wbr", "keygen", "frame",
              "basefont", "isindex", "image"]
  rawTags = ["script", "style", "textarea", "title", "xmp", "iframe", "noembed",
             "noframes", "plaintext"]
  headTags = ["title", "meta", "link", "style", "script", "base", "noscript",
              "template", "basefont", "bgsound", "xml"]
  closesP = ["address", "article", "aside", "blockquote", "center", "details",
             "dialog", "dir", "div", "dl", "fieldset", "figcaption", "figure",
             "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup",
             "hr", "main", "menu", "nav", "ol", "p", "pre", "section", "summary",
             "table", "ul", "li", "dd", "dt", "search"]
  pScope = ["table", "td", "th", "caption", "html", "button", "object", "template",
            "marquee", "applet"]
  cellScope = ["td", "th", "table", "caption", "html", "template", "marquee",
               "object", "applet"]
    ## what an end tag of another element does not reach past
  headings* = ["h1", "h2", "h3", "h4", "h5", "h6"]
    ## the headings' tags

proc findCI(s, what: string; start: int): int =
  ## `what` (lower case) in `s` from `start`, letters in any case.
  let n = what.len
  var i = start
  while i + n <= s.len:
    var k = 0
    while k < n and s[i + k].toLowerAscii == what[k]: inc k
    if k == n: return i
    inc i
  -1

proc parseHtml*(src: string): HtmlDoc =
  ## `src` read into a tree, the way browsers read messy pages (near enough).
  let s = fixUtf8(if src.len > MaxHtml: src[0 ..< MaxHtml] else: src)
  let root = HNode(tag: "#root")
  result.root = root
  var stack = @[root]
  var nodes = 0
  var gotTitle = false
  var styleBytes = 0
  template top: HNode = stack[^1]
  proc addText(stack: var seq[HNode]; t: string; nodes: var int) =
    if t.len == 0: return
    let p = stack[^1]
    if p.kids.len > 0 and p.kids[^1].tag.len == 0:
      p.kids[^1].text.add t
    else:
      inc nodes
      p.kids.add HNode(text: t, parent: p)
  proc closeTo(stack: var seq[HNode]; names: openArray[string];
               bounds: openArray[string]): bool =
    ## Closes up to the nearest open element named one of `names`, unless
    ## an element in `bounds` comes first.
    for k in countdown(stack.high, 1):
      let t = stack[k].tag
      if t in names:
        stack.setLen(k)
        return true
      if t in bounds: return false
  proc inHead(stack: seq[HNode]): bool =
    for k in countdown(stack.high, 1):
      if stack[k].tag == "head": return true
  var i = 0
  while i < s.len and nodes < MaxNodes:
    let lt = s.find('<', i)
    let textEnd = if lt < 0: s.len else: lt
    if textEnd > i:
      let t = decodeEntities(s[i ..< textEnd])
      # (text in a head left open: the body has begun)
      if inHead(stack) and t.strip.len > 0: discard closeTo(stack, ["head"], [])
      addText(stack, t, nodes)
    if lt < 0: break
    i = lt
    if i + 1 >= s.len:
      addText(stack, "<", nodes)
      break
    let c1 = s[i + 1]
    if s.continuesWith("<!--", i):
      # a comment (Outlook's "<!--[if mso]> ... <![endif]-->" too)
      let e = s.find("-->", i + 4)
      i = if e < 0: s.len else: e + 3
      continue
    if s.continuesWith("<![CDATA[", i):
      let e = s.find("]]>", i + 9)
      let body = if e < 0: s[i + 9 .. ^1] else: s[i + 9 ..< e]
      addText(stack, body, nodes)
      i = if e < 0: s.len else: e + 3
      continue
    if c1 in {'!', '?'}:
      # a doctype, "<![if !mso]>" (its content is shown), "<?xml ...?>"
      let e = s.find('>', i + 2)
      i = if e < 0: s.len else: e + 1
      continue
    if c1 == '/' and i + 2 < s.len and s[i + 2].isAlphaAscii:
      # an end tag
      var j = i + 2
      var name = ""
      while j < s.len and (s[j].isAlphaNumeric or s[j] in {'-', ':', '_'}) and name.len < 32:
        name.add s[j].toLowerAscii
        inc j
      let e = s.find('>', j)
      i = if e < 0: s.len else: e + 1
      case name
      of "br":
        inc nodes
        top.kids.add HNode(tag: "br", parent: top)
      of "p":
        discard closeTo(stack, ["p"], pScope)
      of "h1", "h2", "h3", "h4", "h5", "h6":
        discard closeTo(stack, headings, cellScope)
      of "td", "th":
        discard closeTo(stack, [name], ["table"])
      of "tr":
        discard closeTo(stack, ["tr"], ["table"])
      of "thead", "tbody", "tfoot":
        discard closeTo(stack, [name], ["table"])
      of "table", "caption", "template":
        discard closeTo(stack, [name], [])
      of "body", "html":
        discard              # (what comes after is still the body's)
      of "li":
        discard closeTo(stack, ["li"], ["ul", "ol", "menu", "dir", "td", "th", "table"])
      else:
        discard closeTo(stack, [name], cellScope)
      continue
    if not c1.isAlphaAscii:
      addText(stack, "<", nodes)
      inc i
      continue
    # a start tag, its attributes
    var j = i + 1
    var name = ""
    while j < s.len and (s[j].isAlphaNumeric or s[j] in {'-', ':', '_'}) and name.len < 32:
      name.add s[j].toLowerAscii
      inc j
    if name == "image": name = "img"
    var attrs: seq[(string, string)]
    var selfClose = false
    while j < s.len:
      while j < s.len and s[j] in {' ', '\t', '\n', '\r', '\f'}: inc j
      if j >= s.len: break
      if s[j] == '>':
        inc j
        break
      if s[j] == '/':
        selfClose = j + 1 < s.len and s[j + 1] == '>'
        inc j
        continue
      var an = ""
      while j < s.len and s[j] notin {' ', '\t', '\n', '\r', '\f', '=', '>', '/'}:
        if an.len < 64: an.add s[j].toLowerAscii
        inc j
      if an.len == 0:
        inc j
        continue
      while j < s.len and s[j] in {' ', '\t', '\n', '\r', '\f'}: inc j
      var av = ""
      if j < s.len and s[j] == '=':
        inc j
        while j < s.len and s[j] in {' ', '\t', '\n', '\r', '\f'}: inc j
        if j < s.len and s[j] in {'"', '\''}:
          let q = s[j]
          let e = s.find(q, j + 1)
          let stop = if e < 0: s.len else: e
          av = s[j + 1 ..< stop]
          j = stop + 1
        else:
          let st = j
          while j < s.len and s[j] notin {' ', '\t', '\n', '\r', '\f', '>'}: inc j
          av = s[st ..< j]
      if attrs.len < MaxAttrs and av.len <= 100_000:
        var dup = false
        for (k, _) in attrs:
          if k == an: dup = true
        if not dup: attrs.add (an, decodeEntities(av, inAttr = true))
    i = min(j, s.len)
    # the head ends where the body's content begins
    if name notin headTags and name != "head" and name != "html" and inHead(stack):
      discard closeTo(stack, ["head"], [])
    # raw text: up to its end tag, not read as HTML
    if name in rawTags and not selfClose:
      let e = findCI(s, "</" & name, i)
      let body = if e < 0: s[i .. ^1] else: s[i ..< e]
      if name == "title" and not gotTitle:
        gotTitle = true
        result.title = strutils.splitWhitespace(decodeEntities(body)).join(" ")
      elif name == "style":
        if styleBytes + body.len <= MaxStyleText:
          styleBytes += body.len
          result.styles.add body
      elif name in ["xmp", "plaintext"]:
        inc nodes
        let n = HNode(tag: "pre", parent: top)
        n.kids = @[HNode(text: body, parent: n)]
        top.kids.add n
      if e < 0: i = s.len
      else:
        let gt = s.find('>', e)
        i = if gt < 0: s.len else: gt + 1
      continue
    # what this one closes first
    if name in closesP: discard closeTo(stack, ["p"], pScope)
    case name
    of "li": discard closeTo(stack, ["li"], ["ul", "ol", "menu", "dir", "table", "td", "th"])
    of "dt", "dd": discard closeTo(stack, ["dt", "dd"], ["dl", "table", "td", "th"])
    of "tr": discard closeTo(stack, ["tr", "td", "th"], ["table"])
    of "td", "th": discard closeTo(stack, ["td", "th"], ["tr", "table"])
    of "thead", "tbody", "tfoot":
      discard closeTo(stack, ["thead", "tbody", "tfoot"], ["table"])
    of "h1", "h2", "h3", "h4", "h5", "h6":
      if top.tag in headings: discard stack.pop()
    of "a": discard closeTo(stack, ["a"], ["table", "td", "th"])
    of "option", "optgroup": discard closeTo(stack, ["option"], ["select"])
    of "body":
      # a second body (pasted pages): its attributes join the first's
      var b: HNode = nil
      for k in stack:
        if k.tag == "body": b = k
      if b != nil:
        for a in attrs:
          if not b.hasAttr(a[0]): b.attrs.add a
        continue
    else: discard
    inc nodes
    let n = HNode(tag: name, attrs: attrs, parent: top)
    for (k, v) in attrs:
      if k == "class":
        for c in strutils.splitWhitespace(v):
          if n.classes.len < 16: n.classes.add c
      elif k == "id": n.id = v
    top.kids.add n
    if name notin voidTags and not selfClose and stack.len < MaxDepth:
      stack.add n
  result.nodes = nodes
