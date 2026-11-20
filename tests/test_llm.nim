## A language model run here (`retroui/llm`, `retroui/gguf`, `retroui/llmtokens`): four small
## models of random weights, one of each kind -- Llama (F16, Q8_0, Q4_0, its rope's own
## frequencies, SentencePiece), BitNet b1.58 (I2_S, sub-norms, ReLU squared), BitNet (TQ2_0
## with tensor scales) and Qwen 2 (TQ1_0, biases) -- their scores token by token and their
## greedy answers against numpy's (tools/genllm.py), the byte-pair tokens against Hugging
## Face's tokenizer, each kind's rows (the vectors' and the plain loops') against the weights read
## back, the conversation forms, a conversation kept between answers, the text in whole letters,
## and files that are not models.

import std/[json, os, unicode]
import retroui/simdkit
include "../src/retroui/llm"            # (its rows, inside)

const data = currentSourcePath().parentDir / "data" / "llm"

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

let expected = parseFile(data / "expected.json")

block tokens:
  let m = loadLlm(data / "tiny-bitnet-b158.gguf")
  for text, ids in expected["bpe"].pairs:
    var want: seq[int]
    for i in ids: want.add i.getInt
    let got = m.tok.encode(text, special = true)
    check got == want, "byte pairs: " & text.escape & (if got != want: " got " & $got & " want " & $want else: "")
    check m.tok.decode(got) == text.multiReplace(("<|start_header_id|>", ""), ("<|end_header_id|>", ""),
                                                ("<|eot_id|>", "")), "  read back"
  check m.tok.encode("Hi", bos = true)[0] == m.tok.bos, "the start token first"
  m.close()
  let q = loadLlm(data / "tiny-qwen3.gguf")
  check q.tok.digits == 1 and q.tok.addEos and not q.tok.addBos, "Qwen's: a digit at a time, an end token"
  for text, ids in expected["qwen"].pairs:
    var want: seq[int]
    for i in ids: want.add i.getInt
    let got = q.tok.encode(text, special = true)
    check got == want, "Qwen's byte pairs: " & text.escape & (if got != want: " got " & $got & " want " & $want else: "")
  q.close()
  let s = loadLlm(data / "tiny-llama.gguf")
  check s.tok.kind == tkPieces, "SentencePiece"
  for text, ids in expected["spm"].pairs:
    var want: seq[int]
    for i in ids: want.add i.getInt
    let got = s.tok.encode(text, special = false)
    check got == want, "pieces: " & text.escape & (if got != want: " got " & $got & " want " & $want else: "")
    check s.tok.decode(got) == text, "  read back"
  s.close()

proc checkRows(avx: int32) =
  # (each kind's row times an input: the kernel's against the weights read back, in float64 --
  # exact for the ternary kinds, whose input is whole numbers; Q8_0's and Q4_0's whole numbers
  # too, a scale each 32)
  kitForceAvx2(avx)
  var r = initRand(11)
  for (file, names) in [("tiny-llama", @["blk.0.attn_q.weight", "blk.0.ffn_gate.weight", "blk.0.ffn_down.weight",
                                         "output.weight"]),
                        ("tiny-bitnet-b158", @["blk.0.attn_q.weight", "blk.1.ffn_down.weight"]),
                        ("tiny-bitnet", @["blk.0.attn_k.weight", "blk.0.ffn_up.weight", "output.weight"]),
                        ("tiny-qwen2", @["blk.0.ffn_gate.weight", "blk.1.ffn_down.weight"])]:
    let g = openGguf(data / file & ".gguf")
    for name in names:
      let m = g.matOf(name, name.replace(".weight", ".scale"))
      var x = newSeq[float32](m.cols)
      for i in 0 ..< x.len: x[i] = float32(r.gauss())
      var y = newSeq[float32](m.rows)
      m.mul(x, y)
      var xs = x
      var xq = newSeq[int8](x.len)
      var back = 1.0
      if ternary(m.kind):
        back = float(quant8(addr x[0], addr xq[0], x.len))
        for i in 0 ..< x.len: xs[i] = float32(xq[i])
      elif m.kind in {gtQ8_0, gtQ4_0}:
        # (a scale each 32, as llama.cpp's)
        for blk in 0 ..< x.len div 32:
          let sc = quant8(addr x[blk * 32], addr xq[blk * 32], 32)
          for i in blk * 32 ..< blk * 32 + 32: xs[i] = float32(float(xq[i]) * float(sc))
      var worst = 0.0
      var row: seq[float32]
      for i in 0 ..< m.rows:
        m.rowOf(i, row)
        var want = 0.0
        for c in 0 ..< m.cols: want += float(row[c]) * float(xs[c])
        want *= back
        worst = max(worst, abs(float(y[i]) - want) / max(1.0, abs(want)))
      check worst < (if ternary(m.kind): 1e-6 else: 2e-5),
            file & " " & name & " (" & kindName(m.kind) & (if avx == 1: ", AVX2 if there" else: "") &
            ") off by " & formatFloat(worst, ffScientific, 1)
    g.close()

checkRows(0)
checkRows(1)
kitForceAvx2(-1)

block models:
  for name, e in expected["models"].pairs:
    let m = loadLlm(data / name & ".gguf")
    echo "  ", name, ": ", m.describe()
    let st = newLlmState(m)
    var worst = 0.0
    var maxOk = true
    for i, t in e["prompt"].getElems:
      st.step(t.getInt)
      if e["logits"].hasKey($i):
        var top = 0.0
        for v in e["logits"][$i]: top = max(top, abs(v.getFloat))
        for j, v in e["logits"][$i].getElems:
          worst = max(worst, abs(float(st.logits[j]) - v.getFloat) / max(1.0, top))
        var best = 0
        for j in 1 ..< st.logits.len:
          if st.logits[j] > st.logits[best]: best = j
        if best != e["logits"]["max" & $i].getInt: maxOk = false
    # (a ternary row's input rounded to whole numbers: a value at a half, 115.500015 here and
    # 115.49999 there, moves a score by a step -- the rows themselves are checked above)
    let near = if name in ["tiny-llama", "tiny-qwen3"]: 2e-3 else: 4e-2
    check worst < near, name & ": the scores as numpy's (off by " & formatFloat(worst, ffScientific, 2) & ")"
    check maxOk, name & ": the likeliest token as numpy's"
    var want: seq[int]
    for g in e["greedy"]: want.add g.getInt
    var got: seq[int]
    for k in 0 ..< want.len:
      let t = st.pick(sampling(temperature = 0, repeatPenalty = 1))
      got.add t
      st.step(t)
    check got == want, name & ": its greedy answer as numpy's" & (if got != want: " " & $got & " " & $want else: "")
    m.close()

block together:
  # (a prompt read together -- `readMany`: each matrix read once for all its tokens -- gives the
  # very numbers reading it a token at a time gives, and the conversation goes on the same)
  for name in ["tiny-llama", "tiny-bitnet-b158", "tiny-bitnet", "tiny-qwen2", "tiny-qwen3"]:
    let m = loadLlm(data / name & ".gguf")
    let a = newLlmState(m)
    let b = newLlmState(m)
    var toks: seq[int]
    for i in 0 ..< 13: toks.add (i * 37 + 5) mod m.nVocab
    for t in toks: a.step(t)
    b.readMany(toks)
    check a.logits == b.logits and a.hidden == b.hidden and a.pos == b.pos and a.tokens == b.tokens,
          name & ": read together, the same scores"
    a.step(3)
    b.step(3)
    check a.logits == b.logits, "  and the next token's"
    let c = newLlmState(m)
    c.readMany(toks[0 .. 5])
    c.readMany(toks[6 .. ^1])
    c.step(3)
    check c.logits == a.logits, "  in two pieces too"
    m.close()

block embeddings:
  let m = loadLlm(data / "tiny-qwen3.gguf")
  check m.pooling == poolLast and m.headDim == 48, "Qwen 3: the last token's vector, heads of 48"
  let st = newLlmState(m)
  let e = expected["models"]["tiny-qwen3"]
  var vecs: seq[seq[float32]]
  for text, want in e["embed"].pairs:
    let v = m.embed(st, text)
    vecs.add v
    var worst = 0.0
    for j, x in want.getElems: worst = max(worst, abs(float(v[j]) - x.getFloat))
    check worst < 1e-4, "a text's vector as numpy's: " & text & " (off by " & formatFloat(worst, ffScientific, 1) & ")"
  var worst = 0.0
  for i in 0 ..< vecs.len:
    for j in 0 ..< vecs.len:
      worst = max(worst, abs(float(similarity(vecs[i], vecs[j])) - e["similar"][i][j].getFloat))
  check worst < 1e-4, "how near they are, as numpy's"
  check st.pos == 0, "  the state left empty"
  m.close()

block forms:
  let b = loadLlm(data / "tiny-bitnet-b158.gguf")
  check b.form == cfRoles and b.act == actReluSquared and b.neox, "BitNet b1.58: its roles, ReLU squared"
  check b.chatPrompt([("system", "Be brief."), ("user", "Hi ")]) ==
        "System: Be brief.<|eot_id|>User: Hi<|eot_id|>Assistant: ", "  its conversation"
  b.close()
  let l = loadLlm(data / "tiny-bitnet.gguf")
  check l.form == cfLlama3, "a Llama 3 template: its headers"
  check l.chatPrompt([("user", "Hi")]) ==
        "<|start_header_id|>user<|end_header_id|>\n\nHi<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n",
        "  its conversation"
  l.close()
  let q = loadLlm(data / "tiny-qwen2.gguf")
  check q.form == cfChatMl, "ChatML"
  check q.chatPrompt([("user", "Hi")]) == "<|im_start|>user\nHi<|im_end|>\n<|im_start|>assistant\n", "  its conversation"
  q.close()

block conversation:
  let m = loadLlm(data / "tiny-bitnet-b158.gguf")
  let st = newLlmState(m, seed = 7)
  var pieces: seq[string]
  let how = sampling(temperature = 0.9)
  let a = m.chat(st, "You answer.", "مرحبا", maxTokens = 12, how = how,
                 onText = proc (t: string): bool = pieces.add t; true)
  check pieces.len > 0, "its text as it comes"
  var whole = true
  for p in pieces:
    if validateUtf8(p) >= 0: whole = false
  check whole, "  in whole letters"
  check pieces.join("").strip == a, "  the same as the answer"
  let read = st.pos
  var turns = @[(role: "system", text: "You answer."), (role: "user", text: "مرحبا"),
                (role: "assistant", text: a), (role: "user", text: "again")]
  let prompt = m.tok.encode(m.chatPrompt(turns), special = true, bos = true)
  discard m.chat(st, turns, maxTokens = 1, how = how)
  check st.pos > read and st.pos <= prompt.len + 1, "the conversation kept: only what is new read"
  var stopped = 0
  discard m.chat(st, "", "x", maxTokens = 50, how = how, onText = proc (t: string): bool = inc stopped; false)
  check stopped == 1, "false back: no more"
  st.reset()
  check st.pos == 0 and st.tokens.len == 0, "reset"
  m.close()

block notModels:
  let dir = getTempDir() / "retroui-test-llm"
  createDir(dir)
  writeFile(dir / "not.gguf", "hello, this is not a model at all")
  var said = ""
  try: discard loadLlm(dir / "not.gguf")
  except CatchableError as e: said = e.msg
  check "not a GGUF" in said, "a file that is not one: " & said
  let whole = readFile(data / "tiny-llama.gguf")
  writeFile(dir / "cut.gguf", whole[0 ..< 3000])
  said = ""
  try: discard loadLlm(dir / "cut.gguf")
  except CatchableError as e: said = e.msg
  check "cut short" in said or "past the file" in said, "one cut short: " & said
  said = ""
  try: discard loadLlm(dir / "missing.gguf")
  except CatchableError as e: said = e.msg
  check "cannot open" in said, "one not there"
  removeDir(dir)

if failures > 0:
  echo failures, " failed"
  quit 1
echo "test_llm: all passed"
