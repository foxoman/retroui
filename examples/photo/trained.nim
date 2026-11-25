# Retro Atelier -- included by photo.nim
#
# Trained models on this device (retroui/nnet, retroui/vision), downloaded from Edit > Models on
# This Device: Select Subject and Remove Background with U-2-Net, Depth Blur, Lens Blur and
# Relight with Depth Anything's depth -- each the program's own way when none is there -- and
# Type > Text in Picture with PaddleOCR's readers (English and Chinese, Arabic).

var
  netCache: seq[(string, Net)]          ## (models loaded: kept while the program runs)
  readDlg: tuple[open: bool; job: Job[seq[TextLine]]; lines: seq[TextLine]; text: string; model: int;
                 err: string; doc: Doc; area: Rect]

proc netOf(path: string): Net =
  ## (the model in `path`, loaded once)
  for (p, n) in netCache:
    if p == path: return n
  result = loadNet(path)
  netCache.add (path, result)

proc installedOf(use: ModelUse): seq[StoreModel] =
  ## (the store's models of `use` on this device, the larger first: finer)
  result = installedModels(use)
  result.sort(proc (a, b: StoreModel): int = cmp(b.size, a.size))

proc keepAlive(): bool =
  ## (between a model's steps on the UI thread: the window kept alive, the busy box drawn)
  busyTick()
  false

proc trainedHooks() =
  ## Select Subject, Remove Background, the depth of Depth Blur, Lens Blur and Relight: a
  ## trained model's when one is on the device.
  subjectHook = proc (src: Img): seq[uint8] =
    let ms = installedOf(muSubject)
    if ms.len == 0: return
    try:
      beginBusy(tr("Finding the subject"))
      defer: endBusy()
      result = subjectOf(netOf(modelPath(ms[0])), src.px, src.w, src.h, keepAlive)
    except CatchableError as e:
      status = tr("The subject model failed: ") & e.msg
      result.setLen(0)
  depthHook = proc (src: Img): seq[uint8] =
    let ms = installedOf(muDepth)
    if ms.len == 0: return
    try:
      beginBusy(tr("Seeing the depth"))
      defer: endBusy()
      let near = depthOf(netOf(modelPath(ms[0])), src.px, src.w, src.h, stop = keepAlive)
      if near.len != src.w * src.h: return
      result = newSeq[uint8](near.len)
      for i, v in near: result[i] = uint8(255 - clamp(int(v * 255 + 0.5), 0, 255))
    except CatchableError as e:
      status = tr("The depth model failed: ") & e.msg
      result.setLen(0)

# ---- Type > Text in Picture ---------------------------------------------------------------------------

proc readersOn(): seq[StoreModel] = installedModels(muText)

proc openReadText() =
  ## Type > Text in Picture: the window; the text read at once when a reader is on the device.
  let d = cur()
  if d == nil: return
  readDlg.open = true
  readDlg.lines.setLen(0)
  readDlg.err = ""
  readDlg.doc = d
  readDlg.area = if d.hasSelection: d.selBounds else: d.bounds
  if readDlg.area.w <= 0 or readDlg.area.h <= 0: readDlg.area = d.bounds

proc startReading() =
  ## (the picture as it looks -- the selection's box, else all of it -- read on a worker)
  let d = readDlg.doc
  let rs = readersOn()
  if d == nil or rs.len == 0: return
  let m = rs[clamp(readDlg.model, 0, rs.high)]
  var det, rec = ""
  for f in m.filesOf:
    if "det" in f.file: det = modelFilePath(m, f.file) else: rec = modelFilePath(m, f.file)
  let arabic = "arabic" in m.id
  d.updateComposite()
  let r = readDlg.area
  var px = newSeq[uint32](r.w * r.h)
  let all = d.compCopy
  for y in 0 ..< r.h:
    for x in 0 ..< r.w: px[y * r.w + x] = all[(r.y + y) * d.w + r.x + x]
  let (w, h) = (r.w, r.h)
  readDlg.lines.setLen(0)
  readDlg.err = ""
  readDlg.job = job(proc (c: JobCtl): seq[TextLine] {.gcsafe.} =
    # (the models loaded here, on the worker: their own, let go when it ends)
    {.cast(gcsafe).}:
      readText(loadNet(det), loadNet(rec), px, w, h, chars = (if arabic: @arabicChars else: @[]),
               arabic = arabic, stop = proc (): bool = c.cancelled),
    proc () =
      let j = readDlg.job
      if j.done:
        readDlg.lines = j.value
        readDlg.text = ""
        for l in readDlg.lines: readDlg.text.add l.text & "\n"
        if readDlg.lines.len == 0: readDlg.err = tr("No text found")
      elif j.failed: readDlg.err = j.error)

proc placeLines(d: Doc; lines: seq[TextLine]; at: Rect) =
  ## (each line a type layer over the line it was found in, as wide as it -- its height within
  ## reason -- in the type tool's font; one step)
  if lines.len == 0: return
  d.layersChange("Text in Picture"):
    for l in lines:
      let c = l.corners
      let high = max(1.0, hypot(c[3][0] - c[0][0], c[3][1] - c[0][1]))
      let wide = hypot(c[1][0] - c[0][0], c[1][1] - c[0][1])
      var st = typeStyle.scaledStyle(typeScale())
      st.color = fg
      st.size = float32(high)
      let L = d.addTextLayer(newText(l.text, st, float32(at.x.float + c[0][0]), float32(at.y.float + c[3][1])))
      # (the detector's box holds the letters, about cap height to baseline: the letters as drawn
      # as wide as it -- their size never under 0.6 or over 1.6 of its height --, their middle on
      # its middle)
      var (b, size) = (L.textBounds, high)
      for _ in 0 ..< 3:        # (again while a part of it fell off the picture)
        let want = if b.w > 0: clamp(size * wide / b.w.float, high * 0.6, high * 1.6) else: size
        if abs(want - size) < 0.25: break
        L.text = L.text.sizesScaled(float32(want / size))
        size = want
        d.drawText(L)
        b = L.textBounds
      if b.w > 0:
        let mid = (c[0][1] + c[3][1]) / 2
        L.text.x += float32(at.x.float + c[0][0] - b.x.float)
        L.text.y += float32(at.y.float + mid - (b.y.float + b.h / 2))
        d.drawText(L)
    d.markAll()
  status = $lines.len & tr(" lines added as type layers")

proc readTextDialog() =
  if not readDlg.open: return
  let running = readDlg.job != nil and readDlg.job.running
  dialog(readDlg.open, tr("Text in Picture"), 520):
    let rs = readersOn()
    if rs.len == 0:
      paragraph(tr("No reader of text is on this device yet: Models... downloads one (PP-OCRv3 reads " &
                   "English and Chinese, PP-OCRv3 Arabic reads Arabic, Persian and Urdu)."), color = ui.theme.gray)
      row:
        spring()
        if button(tr("Models..."), w = dp(96)): modelsOpen = true
        if button(tr("Close"), isDefault = true, w = dp(80)): readDlg.open = false
      return
    row([110, -1]):
      label tr("Reader:")
      var names: seq[string]
      for m in rs: names.add m.name & " (" & tr(m.languages) & ")"
      readDlg.model = clamp(readDlg.model, 0, rs.high)
      discard combo(names, readDlg.model, w = dp(320))
    label(tr("Reads: ") & (if readDlg.doc != nil and readDlg.area != readDlg.doc.bounds: tr("the selection")
                           else: tr("the whole picture")), color = ui.theme.gray)
    if running:
      label(tr("Reading the text..."))
    elif readDlg.err.len > 0:
      label(readDlg.err)
    if readDlg.lines.len > 0:
      editArea(readDlg.text, lines = 8)        # (to change before it is copied)
    row:
      if button(tr("Read"), isDefault = readDlg.lines.len == 0 and not running, w = dp(80), enabled = not running):
        startReading()
      if button(tr("Copy All"), w = dp(90), enabled = readDlg.lines.len > 0):
        putClipboardText(readDlg.text.strip)
        status = tr("The text is on the clipboard")
      if button(tr("Add as Type"), w = dp(110), enabled = readDlg.lines.len > 0 and readDlg.doc != nil):
        placeLines(readDlg.doc, readDlg.lines, readDlg.area)
        readDlg.open = false
      spring()
      if button(tr("Close"), w = dp(80)):
        if running: readDlg.job.cancel()
        readDlg.open = false
