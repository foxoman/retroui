## The device's own AI service (`retroui/devicemodel`) and the model store
## (`retroui/modelstore`): a conversation and its tools as the model reads them (Qwen 3's
## tags), its tool calls read back (in tags, alone, after its thinking), its answer as an
## OpenAI-compatible service's; a chat of `retroui/aichat` with `akDevice` answered by a small
## model of the tests' own, its words shown as they come, stopped; a model downloaded (a file
## address: offline), stopped and gone on with, its checksum checked, a damaged one refused,
## deleted; search by meaning (an index made, kept, read again only for what changed, a question's
## nearest); the store's window and the AI Connector's form drawn.

import std/[os, strutils, json, times]
import retroui, retroui/[headless, aichat, assistant, devicemodel, modelstore, sha2, fetch, meaning, jobs, zip]

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

const data = currentSourcePath().parentDir / "data" / "llm"
let tiny = data / "tiny-qwen3.gguf"

useHeadless(800, 600)
startApp("Device model", 800, 600)

echo "the conversation as the model reads it"
block turns:
  let req = %*{"messages": [
    {"role": "system", "content": "You help."},
    {"role": "user", "content": [{"type": "text", "text": "add milk"}, {"type": "image_url", "image_url": {"url": "x"}}]},
    {"role": "assistant", "content": "", "tool_calls": [{"id": "c1", "type": "function",
      "function": {"name": "add_note", "arguments": "{\"text\":\"milk\"}"}}]},
    {"role": "tool", "tool_call_id": "c1", "content": "added"},
    {"role": "tool", "tool_call_id": "c2", "content": "also"}],
    "tools": [{"type": "function", "function": {"name": "add_note", "description": "Adds a note.",
                                                "parameters": {"type": "object"}}}]}
  let t = turnsOf(req)
  check t.len == 4 and t[0].role == "system" and "# Tools" in t[0].text and "\"add_note\"" in t[0].text and
        "<tool_call>" in t[0].text, "the tools told in the system's turn, as Qwen 3 is told"
  check "a picture" in t[1].text, "a picture said in words (the model sees none)"
  check t[2].role == "assistant" and "<tool_call>" in t[2].text and "\"milk\"" in t[2].text, "its call in tags"
  check t[3].role == "user" and t[3].text.count("<tool_response>") == 2, "the tools' answers, one round together"
  let n = turnsOf(%*{"messages": [{"role": "user", "content": "hi"}], "tools": req["tools"]})
  check n.len == 2 and n[0].role == "system", "no system turn: one made for the tools"

echo "its answers read back"
block calls:
  var (w, c) = callsOf("Sure.\n<tool_call>\n{\"name\": \"add_note\", \"arguments\": {\"text\": \"milk\"}}\n</tool_call>")
  check w == "Sure." and c.len == 1 and c[0]["arguments"]["text"].getStr == "milk", "a call in tags, and words"
  (w, c) = callsOf("<think>\nhmm\n</think>\n\n<tool_call>{\"name\":\"a\",\"arguments\":{}}</tool_call>" &
                   "<tool_call>{\"name\":\"b\",\"arguments\":{\"n\":1}}</tool_call>")
  check w == "" and c.len == 2 and c[1]["name"].getStr == "b", "two calls, the thinking left out"
  (w, c) = callsOf("```json\n{\"name\": \"add_note\", \"arguments\": {\"text\": \"x\"}}\n```")
  check c.len == 1 and w == "", "a call alone without its tags"
  (w, c) = callsOf("The answer is {\"a\": 1}.")
  check c.len == 0 and w == "The answer is {\"a\": 1}.", "JSON in words is not a call"
  (w, c) = callsOf("<tool_call>not json</tool_call> ok")
  check c.len == 0 and w == "ok", "a broken call left out"
  let j = parseJson(answerJson("done", [%*{"name": "add_note", "arguments": {"text": "x"}}]))
  let m = j["choices"][0]["message"]
  check m["content"].getStr == "done" and m["tool_calls"][0]["function"]["arguments"].getStr == "{\"text\":\"x\"}",
        "the answer as OpenAI's"
  let (msg, err) = chatReply(akDevice, answerJson("hi", []))
  check err == "" and msg.text == "hi", "aichat reads it"

echo "the model answers"
block answer:
  let body = $(%*{"max_tokens": 8, "temperature": 0,
                  "messages": [{"role": "system", "content": "Be brief."}, {"role": "user", "content": "Hello"}]})
  let r = deviceAnswer(tiny, body)
  check r.status == 200, "an answer from the model on this device: " & r.error
  let j = parseJson(r.body)
  check j["choices"][0]["message"]["role"].getStr == "assistant", "  in OpenAI's shape"
  let r2 = deviceAnswer(tiny, body)
  check r2.body == r.body, "the same request, the same answer (temperature 0; the model kept loaded)"
  let bad = deviceAnswer(data / "nothing.gguf", body)
  check bad.status == 0 and "cannot open" in bad.error, "a model not there: why"
  check deviceAnswer(tiny, "{").status == 0, "a request that is not JSON"

echo "a chat with the device's own model"
var drawPanel: AiChat
proc frame() =
  discard beginFrame()
  if drawPanel != nil: assistantPanel(drawPanel)
  else: label "chat"
  endFrame()

block chat:
  # (a model that answers in words: the tiny Qwen's first token is often its end)
  let s = AiSettings(kind: akDevice, url: data / "tiny-bitnet.gguf")
  check s.connected and not AiSettings(kind: akDevice, url: data / "nothing.gguf").connected,
        "connected when its model's file is there"
  let c = newAiChat(s, "Be brief.")
  drawPanel = c
  c.send("Hello there")
  check c.state == ciAsking, "asked"
  let t0 = epochTime()
  while c.busy and epochTime() - t0 < 60:
    frame()
    sleep(5)
  check not c.busy and c.error == "" and c.messages.len == 2 and c.messages[1].role == arAssistant,
        "it answered: " & c.error
  drawPanel = nil
  c.close()

block stopIt:
  let c = newAiChat(AiSettings(kind: akDevice, url: tiny))
  c.send("Write a long story")
  frame()
  c.stop()
  check c.state == ciIdle, "stopped"
  c.close()

echo "the model store"
block store:
  let dir = getTempDir() / "retroui-test-models"
  removeDir(dir)
  createDir(dir)
  modelsDir = dir / "Models"
  let src = dir / "source.gguf"
  copyFile(tiny, src)
  let want = fileSha256(src)
  var hex = ""
  for b in sha256(readFile(src)): hex.add toHex(int(b), 2).toLowerAscii
  check want == hex and want.len == 64, "a file's checksum, read a piece at a time"
  let m = StoreModel(id: "tiny", name: "Tiny", use: muChat, file: "tiny.gguf", url: "file://" & src,
                     sha256: want, size: getFileSize(src))
  check not m.isInstalled and m.partOf == 0, "not there yet"
  # (stopped half way, then gone on with: a part of it there already)
  createDir(modelsDir)
  writeFile(modelPath(m) & ".part", readFile(src)[0 ..< 100_000])
  check m.partOf == 100_000, "what a stopped download left"
  let err = downloadFile(m.url, modelPath(m), timeoutSec = 0, resume = true)
  check err == "" and readFile(modelPath(m)) == readFile(src), "gone on with: the whole file " & err
  removeFile(modelPath(m))
  var ended = false
  getModel(m, proc () = ended = true)
  check m.downloading, "downloading"
  let t0 = epochTime()
  while not ended and epochTime() - t0 < 30:
    frame()
    sleep(5)
  check ended and m.isInstalled and m.errorOf == "", "downloaded and checked: installed " & m.errorOf
  check modelPath(m) in otherModelFiles(), "  (a file not on the store's list: as one of your own)"
  var p = ""
  discard beginFrame()
  # (the store's models are not installed here: only the file put in by hand would show)
  endFrame()
  # (a damaged one: its checksum not the model's)
  let bad = StoreModel(id: "bad", name: "Bad", use: muChat, file: "bad.gguf", url: "file://" & src,
                       sha256: "00" & want[2 .. ^1], size: getFileSize(src))
  ended = false
  getModel(bad, proc () = ended = true)
  let t1 = epochTime()
  while not ended and epochTime() - t1 < 30:
    frame()
    sleep(5)
  check not bad.isInstalled and "damaged" in bad.errorOf and not fileExists(modelPath(bad)),
        "a damaged one refused and taken away: " & bad.errorOf
  m.deleteModel()
  check not m.isInstalled and not fileExists(modelPath(m)), "deleted"
  # (a model of several files: one of its own, two out of an archive -- a Python wheel's way)
  var z = newZipWriter()
  z.addFile("pkg/models/det.onnx", "the detector")
  z.addFile("pkg/models/rec.onnx", "the reader")
  z.addFile("pkg/other.py", "print()")
  let wheel = dir / "pkg.whl"
  writeFile(wheel, z.finish())
  let wsum = fileSha256(wheel)
  let multi = StoreModel(id: "multi", name: "Multi", use: muText, file: "det.onnx", url: "file://" & wheel,
                         sha256: wsum, size: getFileSize(wheel), member: "pkg/models/det.onnx",
                         more: @[ModelFile(file: "rec.onnx", url: "file://" & wheel, sha256: wsum,
                                           member: "pkg/models/rec.onnx"),
                                 ModelFile(file: "words.txt", url: "file://" & src, sha256: want,
                                           size: getFileSize(src))])
  check multi.filesOf.len == 3 and not multi.isInstalled, "a model of three files: not there"
  ended = false
  getModel(multi, proc () = ended = true)
  let t2 = epochTime()
  while not ended and epochTime() - t2 < 30:
    frame()
    sleep(5)
  check ended and multi.isInstalled and multi.errorOf == "", "each file downloaded and checked: " & multi.errorOf
  check readFile(modelsDir / "det.onnx") == "the detector" and readFile(modelsDir / "rec.onnx") == "the reader" and
        readFile(modelsDir / "words.txt") == readFile(src), "  the members taken out of the archive"
  var leftovers = 0
  for f in walkFiles(modelsDir / ".*.zip*"): inc leftovers
  check leftovers == 0, "  the archive let go of"
  removeFile(modelsDir / "rec.onnx")
  check not multi.isInstalled, "one file gone: not installed"
  multi.deleteModel()
  check not fileExists(modelsDir / "det.onnx") and not fileExists(modelsDir / "words.txt.ok"), "all its files deleted"
  check storeModel("ppocr-v3").more.len == 1 and storeModel("ppocr-v3").member.len > 0 and
        storeModel("u2netp").use == muSubject and storeModel("depth-anything-v2-small").use == muDepth,
        "the store's models of pictures"
  # (a GGUF of your own, put in the folder)
  copyFile(src, modelsDir / "mine.gguf")
  check otherModelFiles() == @[modelsDir / "mine.gguf"], "a model of your own in the folder"
  discard beginFrame()
  check deviceModelPicker(p) and p == modelsDir / "mine.gguf", "the picker offers it"
  endFrame()
  check modelName(p) == "mine" and modelName("/x/ggml-model-i2_s.gguf") == "BitNet b1.58 2B", "a model's name"
  check modelSizeText(1_187_000_000) == "1.19 GB" and modelSizeText(639_000_000) == "639 MB", "sizes"
  removeDir(dir)
  modelsDir = ""

echo "search by meaning"
block meaningIndex:
  let dir = getTempDir() / "retroui-test-meaning"
  removeDir(dir)
  let ix = openMeaningIndex(dir / "m.idx", tiny)
  check ix.len == 0, "a new index: empty"
  let items: seq[MeaningItem] = @[("a", "1", "The fox runs."), ("b", "1", "Hello, world!"),
                                  ("c", "1", "مرحبا بالعالم")]
  var ended = false
  let j = ix.update(items, proc () = ended = true)
  let t0 = epochTime()
  while not ended and epochTime() - t0 < 60:
    frame()
    sleep(5)
  check ended and j.value == 3 and ix.len == 3, "three texts made vectors"
  let direct = deviceEmbed(tiny, ["Hello, world!"])
  check abs(similarity(ix.vecs[1], direct[0]) - 1) < 1e-5, "  the model's own vectors"
  check not ix.needs("a", "1") and ix.needs("a", "2") and ix.needs("z", "1"), "what is new or changed"
  let back = openMeaningIndex(dir / "m.idx", tiny)
  check back.len == 3 and back.keys == ix.keys and abs(similarity(back.vecs[2], ix.vecs[2]) - 1) < 1e-6,
        "kept in its file, read back"
  check openMeaningIndex(dir / "m.idx", data / "tiny-qwen2.gguf").len == 0, "another model's: started again"
  ended = false
  let j2 = ix.update(@[("a", "1", "The fox runs."), ("b", "2", "Hello again")], proc () = ended = true)
  while not ended: (frame(); sleep(5))
  check j2.value == 1, "only what changed read again"
  ended = false
  let f = ix.find("Find the text", "Hello, world!", onDone = proc () = ended = true)
  while not ended: (frame(); sleep(5))
  check f.value.len == 3 and f.value[0].score >= f.value[1].score and f.value[1].score >= f.value[2].score,
        "a question's nearest first: " & $f.value
  let r = ix.rank(direct[0], count = 1, within = ["c"])
  check r.len == 1 and r[0].key == "c", "among some only"
  ix.keep(["a", "c"])
  check ix.len == 2 and ix.needs("b", "2"), "the gone let go"
  removeDir(dir)

echo "the windows"
block windows:
  var open = true
  var s = AiSettings(kind: akDevice)
  var models = false
  for i in 0 ..< 3:
    discard beginFrame()
    modelStoreDialog(open)
    aiServiceForm(s, models)
    endFrame()
  check open, "the store's window drawn"
  check storeModels.len == 8 and storeModels[0].license == "MIT" and storeModels[2].use == muEmbed,
        "the store: BitNet (MIT), Qwen3 (Apache 2.0), an embedding model, and the models of pictures"
  for m in storeModels:
    for f in m.filesOf:
      # (each from Hugging Face, a GitHub release or PyPI -- an archive's member named in it)
      check f.sha256.len == 64 and f.url.startsWith("https://") and
            (f.member.len > 0 and f.member.endsWith(f.file) or f.url.endsWith(f.file) or
             f.url.endsWith(".onnx")),
            "  " & m.name & ", " & f.file & ": its checksum and address"
    check m.license in ["MIT", "Apache 2.0"] and m.licenseUrl.startsWith("https://"), "  " & m.name & "'s license"
  for i in 0 ..< 3:
    discard beginFrame()
    modelStoreDialog(open, {muChat, muEmbed, muDepth, muSubject, muText})
    endFrame()
  check open, "the window with every kind of model"

if failures > 0:
  echo failures, " failed"
  quit 1
echo "test_devicemodel: all passed"
