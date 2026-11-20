## Models for the app's own AI (`retroui/llm`, `retroui/devicemodel`), downloaded when you ask
## for one, as Google Fonts are: a list of small ones whose licenses let any app use them, each
## fetched into a folder outside the app -- an APK stays small, and on a computer every app of
## the kit shares one copy -- with how far it is, Cancel (Download again goes on from where it
## stopped), its checksum checked before it is used, and Delete.
##
## .. code-block:: nim
##   if not isInstalled(storeModels[0]): modelStore.open = true   # the window: modelStoreDialog()
##   let path = modelPath(storeModels[0])                          # a GGUF file: loadLlm(path)
##
## `modelStoreDialog` is the window (Download, Cancel, Delete, each model's license and size);
## `deviceModelPicker` lets a form choose an installed model, and `aiServiceForm` is the form an
## app's AI Connector shows: the kind of service, and its address, model and key -- or, for the
## device's own, which model.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, algorithm]
import core, widgets, jobs, fetch, sha2, aiconnect, zip
import uirelays/services

type
  ModelUse* = enum
    ## What a model is for.
    muChat,                      ## a conversation: the assistant, summaries, text made shorter
    muEmbed,                     ## texts as vectors: search by meaning
    muDepth,                     ## how near each place of a picture is (`retroui/vision`)
    muSubject,                   ## a picture's subject
    muText                       ## the text in a picture (a detector and a reader)

  ModelFile* = object
    ## One more file of a model (a reader beside its detector).
    file*: string                ## its name in `modelsFolder`
    url*: string                 ## where it is downloaded from
    sha256*: string              ## the checksum of what is downloaded (lowercase hex)
    size*: int64                 ## its bytes, about
    member*: string              ## when set: `url` is a zip archive (a Python wheel), the file
                                 ## this member of it -- taken out once the archive is checked

  StoreModel* = object
    ## A model the store offers.
    id*: string                  ## (its name in settings: "bitnet-2b")
    name*: string                ## as shown: "BitNet b1.58 2B"
    use*: ModelUse
    file*: string                ## its file's name in `modelsFolder`
    url*: string                 ## where it is downloaded from
    sha256*: string              ## its checksum (lowercase hex)
    size*: int64                 ## its bytes, about (for how far a download is)
    member*: string              ## (as `ModelFile.member`)
    more*: seq[ModelFile]        ## its other files
    license*, licenseUrl*: string
    maker*: string
    languages*: string           ## what it reads and writes well
    note*: string                ## one line of what it is good at

const storeModels*: seq[StoreModel] = @[
  StoreModel(id: "bitnet-2b", name: "BitNet b1.58 2B", use: muChat, file: "ggml-model-i2_s.gguf",
             url: "https://huggingface.co/microsoft/bitnet-b1.58-2B-4T-gguf/resolve/main/ggml-model-i2_s.gguf",
             sha256: "4221b252fdd5fd25e15847adfeb5ee88886506ba50b8a34548374492884c2162", size: 1_187_000_000,
             license: "MIT", licenseUrl: "https://huggingface.co/microsoft/bitnet-b1.58-2B-4T",
             maker: "Microsoft", languages: "English",
             note: "Ternary weights (-1, 0, 1): quick and small for its size; a research model, best at short " &
                   "answers and summaries in English."),
  StoreModel(id: "qwen3-1.7b", name: "Qwen3 1.7B", use: muChat, file: "Qwen3-1.7B-Q8_0.gguf",
             url: "https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q8_0.gguf",
             sha256: "061b54daade076b5d3362dac252678d17da8c68f07560be70818cace6590cb1a", size: 1_830_000_000,
             license: "Apache 2.0", licenseUrl: "https://huggingface.co/Qwen/Qwen3-1.7B",
             maker: "Alibaba's Qwen team", languages: "English, Arabic and many more",
             note: "Uses the app's tools (the assistant's commands) best of these, and writes Arabic."),
  StoreModel(id: "qwen3-embed-0.6b", name: "Qwen3 Embedding 0.6B", use: muEmbed,
             file: "Qwen3-Embedding-0.6B-Q8_0.gguf",
             url: "https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/main/Qwen3-Embedding-0.6B-Q8_0.gguf",
             sha256: "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439", size: 639_000_000,
             license: "Apache 2.0", licenseUrl: "https://huggingface.co/Qwen/Qwen3-Embedding-0.6B",
             maker: "Alibaba's Qwen team", languages: "English, Arabic and many more",
             note: "Search by meaning: finds mail and documents that say what you ask in other words."),
  StoreModel(id: "depth-anything-v2-small", name: "Depth Anything V2 Small", use: muDepth,
             file: "depth_anything_v2_vits_dynamic.onnx",
             url: "https://github.com/fabio-sim/Depth-Anything-ONNX/releases/download/v2.0.0/" &
                  "depth_anything_v2_vits_dynamic.onnx",
             sha256: "46c4e8eeda3a27f34701831b6a2ec7753d7b38779b215acb5633424703deed8f", size: 99_092_268,
             license: "Apache 2.0", licenseUrl: "https://github.com/DepthAnything/Depth-Anything-V2",
             maker: "Depth Anything (the University of Hong Kong and TikTok)", languages: "",
             note: "How near each place of a photo is: Depth Blur, Lens Blur and Relight with the photo's " &
                   "own depth."),
  StoreModel(id: "u2netp", name: "U-2-Net (small)", use: muSubject, file: "u2netp.onnx",
             url: "https://github.com/danielgatis/rembg/releases/download/v0.0.0/u2netp.onnx",
             sha256: "309c8469258dda742793dce0ebea8e6dd393174f89934733ecc8b14c76f4ddd8", size: 4_574_861,
             license: "Apache 2.0", licenseUrl: "https://github.com/xuebinqin/U-2-Net",
             maker: "Xuebin Qin and others (University of Alberta)", languages: "",
             note: "The subject of a photo: Select Subject and Remove Background -- small and quick."),
  StoreModel(id: "u2net", name: "U-2-Net", use: muSubject, file: "u2net.onnx",
             url: "https://github.com/danielgatis/rembg/releases/download/v0.0.0/u2net.onnx",
             sha256: "8d10d2f3bb75ae3b6d527c77944fc5e7dcd94b29809d47a739a7a728a912b491", size: 175_997_641,
             license: "Apache 2.0", licenseUrl: "https://github.com/xuebinqin/U-2-Net",
             maker: "Xuebin Qin and others (University of Alberta)", languages: "",
             note: "The subject of a photo, finer than the small one's edges: Select Subject and " &
                   "Remove Background."),
  StoreModel(id: "ppocr-v3", name: "PP-OCRv3", use: muText, file: "ch_PP-OCRv3_det_infer.onnx",
             url: "https://files.pythonhosted.org/packages/b7/ef/0df9a58310895ab357f85df67935af6a8fb98f0965c7476" &
                  "cee6fcb966a7e/rapidocr_onnxruntime-1.2.3-py3-none-any.whl",
             sha256: "c707d3a6eb72d13119afe9602d3cc36d8b2a4a4d74e9575cf1b0e67ed6a27819", size: 12_326_259,
             member: "rapidocr_onnxruntime/models/ch_PP-OCRv3_det_infer.onnx",
             more: @[ModelFile(file: "ch_PP-OCRv3_rec_infer.onnx",
                               url: "https://files.pythonhosted.org/packages/b7/ef/0df9a58310895ab357f85df679" &
                                    "35af6a8fb98f0965c7476cee6fcb966a7e/rapidocr_onnxruntime-1.2.3-py3-none-any.whl",
                               sha256: "c707d3a6eb72d13119afe9602d3cc36d8b2a4a4d74e9575cf1b0e67ed6a27819",
                               member: "rapidocr_onnxruntime/models/ch_PP-OCRv3_rec_infer.onnx")],
             license: "Apache 2.0", licenseUrl: "https://github.com/PaddlePaddle/PaddleOCR",
             maker: "Baidu's PaddleOCR (as RapidOCR packs it)", languages: "English, Chinese",
             note: "The text in photos and scans: Type > Text in Picture."),
  StoreModel(id: "ppocr-v3-arabic", name: "PP-OCRv3 Arabic", use: muText, file: "arabic_PP-OCRv3_rec.onnx",
             url: "https://huggingface.co/monkt/paddleocr-onnx/resolve/main/languages/arabic/rec.onnx",
             sha256: "7982d371612785238fd99080cff36354deaec84fdc6ff7da9c82af4243fa0c9a", size: 8_980_000,
             more: @[ModelFile(file: "PP-OCRv3_det.onnx",
                               url: "https://huggingface.co/monkt/paddleocr-onnx/resolve/main/detection/v3/det.onnx",
                               sha256: "ee40e80071ba3a320d4efda75f3e22047a7d049e9bf7bcaaf9daea23fc21b935",
                               size: 2_430_000)],
             license: "Apache 2.0", licenseUrl: "https://github.com/PaddlePaddle/PaddleOCR",
             maker: "Baidu's PaddleOCR (as monkt's ONNX files have it)", languages: "Arabic, Persian, Urdu",
             note: "The Arabic text in photos and scans: Type > Text in Picture."),
]
  ## The models offered: each license lets any app use it, as it is, for free.

var modelsDir* = ""
  ## Where models are kept ("": $RETRO_MODELS, else the kit's own folder, "Retro Models", in
  ## the system's place for an app's data -- outside the app, shared by the kit's apps).

proc modelsFolder*(): string =
  ## The folder models are kept in.
  if modelsDir.len > 0: return modelsDir
  let e = getEnv("RETRO_MODELS")
  if e.len > 0: return e
  try: dataDir("Retro Models") / "Models" except CatchableError: getTempDir() / "Retro Models"

proc modelPath*(m: StoreModel): string = modelsFolder() / m.file
  ## Where the model's file is (or goes).

proc filesOf*(m: StoreModel): seq[ModelFile] =
  ## All of the model's files, its first first.
  result.add ModelFile(file: m.file, url: m.url, sha256: m.sha256, size: m.size, member: m.member)
  result.add m.more

proc modelFilePath*(m: StoreModel; file: string): string = modelsFolder() / file
  ## Where one of the model's files is (`ModelFile.file`).

proc storeModel*(id: string): StoreModel =
  ## The store's model by its `id` (none: an empty one).
  for m in storeModels:
    if m.id == id: return m

proc isInstalled*(m: StoreModel): bool =
  ## It is downloaded -- each of its files -- and its checksums were found right.
  if m.file.len == 0: return false
  for f in m.filesOf:
    let p = modelsFolder() / f.file
    if not fileExists(p): return false
    let ok = try: readFile(p & ".ok").strip == f.sha256 except CatchableError: false
    if not ok: return false
  true

proc installedModels*(use: ModelUse): seq[StoreModel] =
  ## The store's models of `use` that are downloaded.
  for m in storeModels:
    if m.use == use and m.isInstalled: result.add m

proc otherModelFiles*(): seq[string] =
  ## GGUF files put in `modelsFolder` by hand (not the store's): a model of your own.
  var known: seq[string]
  for m in storeModels: known.add m.file
  try:
    # (walkDir: Android before 9 has no glob)
    for kind, f in walkDir(modelsFolder()):
      if kind in {pcFile, pcLinkToFile} and f.endsWith(".gguf") and f.extractFilename notin known: result.add f
  except OSError: discard
  result.sort()

proc modelSizeText*(bytes: int64): string =
  ## "1.19 GB", "639 MB" (as the store shows sizes: thousands, as the makers give them).
  if bytes >= 1_000_000_000: formatFloat(float(bytes) / 1e9, ffDecimal, 2) & " GB"
  else: $(bytes div 1_000_000) & " MB"

proc fileSha256*(path: string; stop: proc (): bool {.closure, gcsafe.} = nil;
                 progress: proc (f: float) {.closure, gcsafe.} = nil): string =
  ## The SHA-256 of a file of any size, read a piece at a time (lowercase hex; "" when it
  ## could not be read or `stop` said so).
  var f: File
  if not open(f, path, fmRead): return ""
  defer: f.close()
  let total = max(1'i64, getFileSize(f))
  var s = initSha256()
  var buf = newSeq[byte](1 shl 20)
  var done = 0'i64
  while true:
    let n = f.readBuffer(addr buf[0], buf.len)
    if n <= 0: break
    s.update(buf.toOpenArray(0, n - 1))
    done += n
    if progress != nil: progress(float(done) / float(total))
    if stop != nil and stop(): return ""
  let d = s.finish()
  for b in d: result.add toHex(int(b), 2).toLowerAscii

# ---- downloads --------------------------------------------------------------------------------------------

type Getting = object
  id: string
  job: Job[string]
  checking: bool                 ## (its checksum being worked out)

var
  getting: seq[Getting]
  lastError: seq[(string, string)]   ## (a model's id: why its download failed)

proc downloading*(m: StoreModel): bool =
  ## Its download (or its check) is running.
  for g in getting:
    if g.id == m.id and g.job != nil and g.job.running: return true

proc archivePath(f: ModelFile; dir = modelsFolder()): string =
  ## (where an archive a file is taken from is downloaded: one for every file of it)
  dir / ("." & f.sha256[0 ..< min(16, f.sha256.len)] & ".zip")

proc downloadPath(f: ModelFile; dir = modelsFolder()): string =
  if f.member.len > 0: archivePath(f, dir) else: dir / f.file

proc totalOf(m: StoreModel): int64 =
  ## (the bytes to download: an archive counted once)
  var seen: seq[string]
  for f in m.filesOf:
    if f.url notin seen:
      seen.add f.url
      result += max(0'i64, f.size)

proc progressOf*(m: StoreModel): float =
  ## How far its download is, 0 .. 1 (the check after it: its own 0 .. 1).
  for g in getting:
    if g.id == m.id and g.job != nil:
      let p = g.job.progress
      if p > 0: return p
      var got = 0'i64
      var seen: seq[string]
      for f in m.filesOf:
        let d = downloadPath(f)
        if d in seen: continue
        seen.add d
        got += (if fileExists(d): (try: getFileSize(d) except OSError: 0'i64) else: downloadedSoFar(d))
      return clamp(float(got) / float(max(1'i64, m.totalOf)), 0.0, 0.99)

proc partOf*(m: StoreModel): int64 =
  ## How much of it a stopped download left (0: none): Download goes on from there.
  for f in m.filesOf:
    result += (try: getFileSize(downloadPath(f) & ".part") except OSError: 0'i64)

proc errorOf*(m: StoreModel): string =
  ## Why its last download failed ("": it did not).
  for (id, e) in lastError:
    if id == m.id: return e

proc forget(id: string) =
  var i = 0
  while i < lastError.len:
    if lastError[i][0] == id: lastError.delete(i) else: inc i

proc fetchFile(f: ModelFile; dir: string; c: JobCtl): string {.gcsafe.} =
  ## (one file of a model, downloaded -- going on from what a stopped one left -- and checked;
  ## a member taken out of its archive; "" when it is there, else why not)
  let dest = dir / f.file
  let ok = try: readFile(dest & ".ok").strip == f.sha256 except CatchableError: false
  if ok and fileExists(dest): return ""
  let got = downloadPath(f, dir)
  let gotOk = try: readFile(got & ".ok").strip == f.sha256 except CatchableError: false
  if not (gotOk and fileExists(got)):
    let err = downloadFile(f.url, got, timeoutSec = 0, resume = true)
    if err.len > 0: return err
    let sum = fileSha256(got, proc (): bool = c.cancelled, proc (p: float) = c.progress(max(0.001, p)))
    if c.cancelled: return "stopped"
    if sum != f.sha256:
      try: removeFile(got) except OSError: discard
      return "the file came damaged (its checksum is not the model's): download it again"
    writeFile(got & ".ok", f.sha256 & "\n")
  if f.member.len > 0:
    try:
      var found = false
      for e in zipEntries(got):
        if e.name == f.member:
          # (inflating ticks the busy box: on the UI thread alone -- here, nothing)
          {.cast(gcsafe).}: writeFile(dest, readEntry(got, e))
          found = true
          break
      if not found: return f.member & " is not in the archive"
    except CatchableError as e:
      return "the archive could not be read: " & e.msg
    writeFile(dest & ".ok", f.sha256 & "\n")
  ""

proc getModel*(m: StoreModel; onDone: proc () {.closure.} = nil) =
  ## Downloads `m` on a worker (`retroui/jobs`) -- each of its files -- going on from what a
  ## stopped one left, then checks each file's checksum: a damaged file is taken away; files
  ## that are members of an archive are taken out of it, and the archive let go of.
  ## `downloading`, `progressOf` and `errorOf` say how it goes; `onDone` runs on the UI thread
  ## when it ends.
  if m.downloading or m.file.len == 0: return
  forget(m.id)
  let files = m.filesOf
  let (dest, id, dir) = (modelPath(m), m.id, modelsFolder())
  var g = Getting(id: id)
  g.job = job(proc (c: JobCtl): string {.gcsafe.} =
    for f in files:
      let err = fetchFile(f, dir, c)
      if err.len > 0: raise newException(IOError, err)
    # (the archives, every member out of them: let go)
    for f in files:
      if f.member.len > 0:
        for x in [archivePath(f, dir), archivePath(f, dir) & ".ok"]:
          try: removeFile(x) except OSError: discard
    dest,
    proc () =
      for i in 0 ..< getting.len:
        if getting[i].id == id:
          let j = getting[i].job
          if j.failed and j.error != "stopped": lastError.add (id, j.error)
          getting.delete(i)
          break
      if onDone != nil: onDone())
  getting.add g

proc stopModel*(m: StoreModel) =
  ## Stops its download (what came is kept: Download goes on from there).
  for f in m.filesOf: stopDownload(downloadPath(f))
  for g in getting:
    if g.id == m.id and g.job != nil: g.job.cancel()

proc deleteModel*(m: StoreModel) =
  ## Takes the model away from this device (and what a stopped download left).
  if m.downloading: m.stopModel()
  for f in m.filesOf:
    let p = modelsFolder() / f.file
    for x in [p, p & ".ok", p & ".part", p & ".stop"]:
      try: removeFile(x) except OSError: discard
    if f.member.len > 0:
      let a = archivePath(f)
      for x in [a, a & ".ok", a & ".part", a & ".stop"]:
        try: removeFile(x) except OSError: discard
  forget(m.id)

# ---- the window ---------------------------------------------------------------------------------------------

proc modelStoreDialog*(open: var bool; uses: set[ModelUse] = {muChat, muEmbed};
                       onChange: proc () {.closure.} = nil) =
  ## The models window: each of the store's models of `uses` with what it is, its maker and
  ## license, its size, and Download (Cancel while it comes, and how far it is) or Delete.
  ## `onChange` runs when one is installed or taken away.
  if not open: return
  dialog(open, tr("Models on This Device"), 560):
    paragraph(tr("Models this app runs itself: what you ask them never leaves the device. Each is " &
                 "downloaded once, for every app of the kit; nothing is downloaded until you ask."),
              color = ui.theme.gray)
    for m in storeModels:
      if m.use notin uses: continue
      separator()
      row([-1, 110]):
        label(m.name & "  (" & modelSizeText(m.totalOf) & ")", bold = true)
        if m.downloading:
          if button(tr("Cancel"), w = dp(100)): m.stopModel()
        elif m.isInstalled:
          if button(tr("Delete"), w = dp(100)):
            m.deleteModel()
            if onChange != nil: onChange()
        else:
          let part = m.partOf
          if button(if part > 0: tr("Go On") else: tr("Download"), w = dp(100)):
            m.getModel(onChange)
      paragraph(tr(m.note), color = ui.theme.gray)
      label(m.maker & " -- " & tr("license: ") & m.license &
            (if m.languages.len > 0: " -- " & tr(m.languages) else: ""), color = ui.theme.gray)
      if m.downloading:
        progress(m.progressOf)
      elif m.isInstalled:
        label(tr("Installed"), color = ui.theme.gray)
      elif m.partOf > 0:
        label(tr("Stopped: ") & modelSizeText(m.partOf) & tr(" of ") & modelSizeText(m.totalOf) & tr(" came"),
              color = ui.theme.gray)
      let e = m.errorOf
      if e.len > 0: label(tr("Not downloaded: ") & e)
    separator()
    label(tr("Kept in: ") & modelsFolder(), color = ui.theme.gray)
    row:
      spring()
      if button(tr("Close"), isDefault = true, w = dp(80)): open = false

proc deviceModelPicker*(path: var string; use = muChat; w = 0): bool {.discardable.} =
  ## A list of the installed models of `use` (and GGUF files put in the folder by hand) to
  ## choose one; `path` its file. True when the choice changed.
  var names: seq[string]
  var paths: seq[string]
  for m in installedModels(use):
    names.add m.name
    paths.add modelPath(m)
  if use == muChat:
    for f in otherModelFiles():
      names.add f.extractFilename
      paths.add f
  if names.len == 0:
    label(tr("No model is installed yet."), color = ui.theme.gray)
    return false
  var sel = max(0, paths.find(path))
  if paths.find(path) < 0:
    path = paths[0]
    result = true
  if combo(names, sel, w = w):
    path = paths[sel]
    result = true

proc modelName*(path: string): string =
  ## The name of the model in the file `path`: the store's, or the file's own.
  for m in storeModels:
    if m.file == path.extractFilename: return m.name
  path.extractFilename.changeFileExt("")

proc aiServiceForm*(s: var AiSettings; openModels: var bool; labelW = 100): bool {.discardable.} =
  ## The AI Connector's form: the kind of service (`AiKind`), then its address, model and key --
  ## or, the device's own, which installed model (and Models..., which sets `openModels`: the
  ## app shows `modelStoreDialog`). True when something changed.
  row([labelW, -1]):
    label tr("Speaks:")
    var k = ord(s.kind)
    if combo([tr($akOpenAi), tr($akAnthropic), tr($akDevice)], k, w = dp(300)):
      let was = s.kind
      s.kind = AiKind(k)
      if s.kind == akDevice: s.url = ""
      elif s.url.len == 0 or s.url == defaultUrl(was) or was == akDevice: s.url = defaultUrl(s.kind)
      if was == akDevice: s.model = ""
      result = true
  if s.kind == akDevice:
    row([labelW, -1, 100]):
      label tr("Model:")
      if deviceModelPicker(s.url): result = true
      if button(tr("Models..."), w = dp(96)): openModels = true
    if s.url.len > 0: s.model = modelName(s.url)
    paragraph(tr("It runs here: nothing you ask leaves this device. It answers slower than a service " &
                 "online, and the small models know less."), color = ui.theme.gray)
  else:
    row([labelW, -1]):
      label tr("Address:")
      if edit(s.url): result = true
    row([labelW, -1]):
      label tr("Model:")
      if edit(s.model): result = true
    row([labelW, -1]):
      label tr("Key:")
      if edit(s.key, password = true): result = true
