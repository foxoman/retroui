## A language model's tokenizer, from its GGUF file: text into the model's token numbers and
## back. Byte-level BPE (GPT-2's and Llama 3's kind: `tokenizer.ggml.model` "gpt2") and
## SentencePiece BPE (Llama 2's kind: "llama"), the special tokens (`<|eot_id|>`...) kept
## whole when asked.
##
## .. code-block:: nim
##   let tk = tokenizerOf(openGguf("model.gguf"))
##   let ids = tk.encode("Hello, world", special = false)
##   echo tk.decode(ids)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[tables, strutils, unicode, algorithm]
import gguf

type
  TokKind* = enum
    ## How the text is cut.
    tkBytePairs,                 ## byte-level BPE (gpt2)
    tkPieces                     ## SentencePiece BPE (llama)

  Tokenizer* = ref object
    ## A model's tokens.
    kind*: TokKind
    tokens*: seq[string]
    ids: Table[string, int]
    ranks: Table[string, int]    ## ("a b": its merge's rank)
    scores: seq[float]
    special*: seq[int]           ## (control tokens: kept whole, never shown)
    specials: seq[(string, int)] ## (their texts, longest first)
    bos*, eos*, eot*: int        ## (-1: none)
    addBos*, addEos*: bool
    digits*: int                 ## (how many digits a word takes: Llama 3's 3, Qwen's 1)
    byteToRune: array[256, string]
    runeToByte: Table[string, byte]
    byteTok: array[256, int]     ## (SentencePiece's <0xNN> tokens: -1 none)

proc gpt2Bytes(tk: Tokenizer) =
  ## (GPT-2's bytes as letters: the printable ones themselves, the rest moved past 255)
  var n = 0
  for b in 0 .. 255:
    let shown = b in ord('!') .. ord('~') or b in 0xA1 .. 0xAC or b in 0xAE .. 0xFF
    let r = if shown: Rune(b) else: (inc n; Rune(255 + n))
    tk.byteToRune[b] = $r
    tk.runeToByte[$r] = byte(b)

proc tokenizerOf*(g: Gguf): Tokenizer =
  ## The tokenizer the model carries (raises `GgufError` when it has none).
  result = Tokenizer(bos: -1, eos: -1, eot: -1)
  result.tokens = g.strings("tokenizer.ggml.tokens")
  if result.tokens.len == 0: raise newException(GgufError, g.path & " has no tokenizer")
  for i, t in result.tokens: result.ids[t] = i
  let model = g.strOf("tokenizer.ggml.model", "gpt2")
  result.kind = if model == "llama": tkPieces else: tkBytePairs
  for i, m in g.strings("tokenizer.ggml.merges"): result.ranks[m] = i
  result.scores = g.numbers("tokenizer.ggml.scores")
  let types = g.numbers("tokenizer.ggml.token_type")
  for i, t in types:
    if int(t) == 3 and i < result.tokens.len:        # (CONTROL)
      result.special.add i
      result.specials.add (result.tokens[i], i)
  result.specials.sort(proc (a, b: (string, int)): int = cmp(b[0].len, a[0].len))
  result.bos = g.intOf("tokenizer.ggml.bos_token_id", -1)
  result.eos = g.intOf("tokenizer.ggml.eos_token_id", -1)
  result.eot = g.intOf("tokenizer.ggml.eot_token_id", -1)
  if result.eot < 0 and "<|eot_id|>" in result.ids: result.eot = result.ids["<|eot_id|>"]
  if result.eot < 0 and "<|im_end|>" in result.ids: result.eot = result.ids["<|im_end|>"]
  result.addBos = g.intOf("tokenizer.ggml.add_bos_token", 1) != 0 and result.bos >= 0
  result.addEos = g.intOf("tokenizer.ggml.add_eos_token", 0) != 0 and result.eos >= 0
  result.digits = if g.strOf("tokenizer.ggml.pre") in ["qwen2", "qwen35"]: 1 else: 3
  result.gpt2Bytes()
  for b in 0 .. 255:
    let name = "<0x" & toHex(b, 2) & ">"
    result.byteTok[b] = result.ids.getOrDefault(name, -1)

proc id*(tk: Tokenizer; token: string): int = tk.ids.getOrDefault(token, -1)
  ## A token's number (-1: not one of the model's).

# ---- cutting text into words first (Llama 3's pattern, by hand) ------------------------------------------

proc isLetter(r: Rune): bool = r.isAlpha or int(r) in 0x0300 .. 0x036F or int(r) in 0x064B .. 0x065F
proc isNumber(r: Rune): bool =
  let c = int(r)
  c in ord('0') .. ord('9') or c in 0x0660 .. 0x0669 or c in 0x06F0 .. 0x06F9
proc isSpace(r: Rune): bool = r.isWhiteSpace

proc words*(s: string; digits = 3): seq[string] =
  ## The text in pieces as Llama 3's pre-tokenizer cuts it: contractions, letters with one sign
  ## before them, up to three digits (Qwen's: `digits` 1), signs with a space before them, line
  ## ends, spaces.
  let rs = s.toRunes
  var i = 0
  let n = rs.len
  proc low(r: Rune): Rune = r.toLower
  while i < n:
    let r = rs[i]
    # 's 't 're 've 'm 'll 'd
    if r == Rune('\'') and i + 1 < n:
      var took = 0
      for c in ["ll", "re", "ve", "s", "t", "m", "d"]:
        if i + c.len < n:
          var ok = true
          for k in 0 ..< c.len:
            if low(rs[i + 1 + k]) != Rune(c[k]): ok = false
          if ok:
            took = c.len
            break
      if took > 0:
        result.add $rs[i .. i + took]
        i += took + 1
        continue
    # [^\r\n\p{L}\p{N}]?\p{L}+
    if r.isLetter or (not r.isLetter and not r.isNumber and r != Rune('\r') and r != Rune('\n') and
                      i + 1 < n and rs[i + 1].isLetter):
      var j = i + 1
      while j < n and rs[j].isLetter: inc j
      result.add $rs[i ..< j]
      i = j
      continue
    # \p{N}{1,3}
    if r.isNumber:
      var j = i
      while j < n and j - i < digits and rs[j].isNumber: inc j
      result.add $rs[i ..< j]
      i = j
      continue
    # " ?[^\s\p{L}\p{N}]+[\r\n]*"
    let sign = proc (q: Rune): bool = not q.isSpace and not q.isLetter and not q.isNumber
    if sign(r) or (r == Rune(' ') and i + 1 < n and sign(rs[i + 1])):
      var j = i + 1
      while j < n and sign(rs[j]): inc j
      while j < n and (rs[j] == Rune('\r') or rs[j] == Rune('\n')): inc j
      result.add $rs[i ..< j]
      i = j
      continue
    # \s*[\r\n]+ | \s+(?!\S) | \s+
    if r.isSpace:
      var j = i
      while j < n and rs[j].isSpace: inc j
      # (the spaces up to the last line end, when there is one)
      var lastNl = -1
      for k in i ..< j:
        if rs[k] == Rune('\n') or rs[k] == Rune('\r'): lastNl = k
      if lastNl >= 0:
        result.add $rs[i .. lastNl]
        i = lastNl + 1
        continue
      # (before a word: its last space goes with the word)
      if j < n and j - i > 1:
        result.add $rs[i ..< j - 1]
        i = j - 1
        continue
      if j < n and j - i == 1 and not rs[j].isSpace:
        # (one space before something that takes none: a piece of its own)
        result.add $rs[i ..< j]
        i = j
        continue
      result.add $rs[i ..< j]
      i = j
      continue
    result.add $r
    inc i

# ---- byte pairs -----------------------------------------------------------------------------------------

proc bpe(tk: Tokenizer; word: string; into: var seq[int]) =
  ## (one word's bytes as letters, merged by rank)
  var parts: seq[string]
  for c in word: parts.add tk.byteToRune[ord(c)]
  while parts.len > 1:
    var best = high(int)
    var at = -1
    for i in 0 ..< parts.high:
      let r = tk.ranks.getOrDefault(parts[i] & " " & parts[i + 1], high(int))
      if r < best:
        best = r
        at = i
    if at < 0: break
    let merged = parts[at] & parts[at + 1]
    var next: seq[string]
    var i = 0
    while i < parts.len:
      if i < parts.high and parts[i] & " " & parts[i + 1] == parts[at] & " " & parts[at + 1]:
        next.add merged
        i += 2
      else:
        next.add parts[i]
        inc i
    parts = next
  for p in parts:
    let t = tk.ids.getOrDefault(p, -1)
    if t >= 0: into.add t
    else:
      # (a piece the vocabulary has not: its letters one by one)
      for r in p.runes:
        let x = tk.ids.getOrDefault($r, -1)
        if x >= 0: into.add x

# ---- SentencePiece ----------------------------------------------------------------------------------------

proc pieces(tk: Tokenizer; text: string; into: var seq[int]) =
  ## (Llama 2's: letters merged by the best score that is a token, bytes for what is not)
  var parts: seq[string]
  for r in text.runes: parts.add $r
  while parts.len > 1:
    var best = -Inf
    var at = -1
    for i in 0 ..< parts.high:
      let t = tk.ids.getOrDefault(parts[i] & parts[i + 1], -1)
      if t >= 0:
        let sc = if t < tk.scores.len: tk.scores[t] else: 0.0
        if sc > best:
          best = sc
          at = i
    if at < 0: break
    parts[at] = parts[at] & parts[at + 1]
    parts.delete(at + 1)
  for p in parts:
    let t = tk.ids.getOrDefault(p, -1)
    if t >= 0: into.add t
    else:
      for c in p:
        let b = tk.byteTok[ord(c)]
        if b >= 0: into.add b

proc encode*(tk: Tokenizer; text: string; special = true; bos = false): seq[int] =
  ## `text` as token numbers; `special`: the control tokens written in it (`<|eot_id|>`) taken
  ## as themselves; `bos`: the start token first, when the model wants it.
  if bos and tk.addBos: result.add tk.bos
  var rest = text
  var chunks: seq[(string, int)]        # (text, or -1 / a special token's number)
  while rest.len > 0:
    var at = -1
    var which = -1
    if special:
      for (s, id) in tk.specials:
        let k = rest.find(s)
        if k >= 0 and (at < 0 or k < at):
          at = k
          which = id
    if at < 0:
      chunks.add (rest, -1)
      break
    if at > 0: chunks.add (rest[0 ..< at], -1)
    chunks.add ("", which)
    rest = rest[at + tk.tokens[which].len .. ^1]
  for (s, id) in chunks:
    if id >= 0:
      result.add id
      continue
    case tk.kind
    of tkBytePairs:
      for w in words(s, max(1, tk.digits)): tk.bpe(w, result)
    of tkPieces:
      tk.pieces("▁" & s.replace(" ", "▁"), result)

proc piece*(tk: Tokenizer; id: int): string =
  ## What one token reads as (a control token: "").
  if id < 0 or id >= tk.tokens.len or id in tk.special: return ""
  let t = tk.tokens[id]
  case tk.kind
  of tkBytePairs:
    for r in t.runes:
      let k = $r
      if k in tk.runeToByte: result.add char(tk.runeToByte[k])
      else: result.add k
  of tkPieces:
    if t.len == 6 and t.startsWith("<0x") and t.endsWith(">"):
      try: result.add char(parseHexInt(t[3 .. 4]))
      except ValueError: result.add t
    else: result.add t.replace("▁", " ")

proc decode*(tk: Tokenizer; ids: openArray[int]): string =
  ## The text of token numbers (control tokens left out).
  for i in ids: result.add tk.piece(i)
  if tk.kind == tkPieces and result.startsWith(" "): result.delete(0 .. 0)
