# (included by photo.nim) The photo editors' file and photo commands that the others here did not
# have: the Measurement Log, Define Custom Shape, Transform Selection, Copy CSS and Copy SVG, New
# Layer Based Slice, Manage Missing Fonts, Conditional Mode Change, Delete All Empty Layers, Flatten
# All Layer Effects and Masks, Layer Comps to Files, Artboards to PDF, Color Lookup Tables, Render
# Video, Zoomify, Generate Image Assets, Version History, Timelapse, Script Events, Droplets, Save
# for Web, Focus Merge, Astrophotography Stack, 360 views, Decompose Layers, Layer to 3D, Select
# People, Content Credentials.

var
  measureDlg = false
  xfSelDlg: tuple[open: bool; scale, rotate: float; dx, dy: int] = (false, 100.0, 0.0, 0, 0)
  fontsDlg: tuple[open: bool; missing: seq[string]; repl: seq[int]]
  condDlg: tuple[open: bool; target: int; from0: array[6, bool]] = (false, 0, [true, true, true, true, true, true])
  cubePick = false
  cubePath = ""
  videoPick = false
  videoPath = ""
  zoomPick = false
  zoomPath = ""
  imageAssets: seq[pointer]              ## the documents whose layers named as files are saved with them
  savedState: Table[pointer, tuple[modified: bool; path: string]]
  versionsDlg: tuple[open: bool; sel: int; list: seq[string]]
  timelapse: tuple[on: bool; doc: Doc; ver, at: int; frames: seq[Bitmap]]
  scriptEvents: array[5, string]         ## Start, New, Open, Save, Close: a script file or "Action: NAME"
  eventsDlg = false
  eventsLoaded = false
  dropletDlg: tuple[open: bool; action: int; outDir: string]
  webDlg: tuple[open: bool; format, quality, colors: int; dither: bool; preview: Bitmap; key: string; bytes: int]
  webPick = false
  webPath = ""
  focusMergeNext = false
  astroDlg: tuple[open: bool; lights, darks, flats, bias: seq[string]; pick: int; mode: int; align, gradient: bool] =
    (false, @[], @[], @[], @[], -1, 2, true, true)
  astroPicking = false
  astroPath = ""
  view360: Table[pointer, tuple[src: Doc; yaw, pitch, fov: float]]
  pano360Dlg: tuple[open: bool; yaw, pitch, fov: int] = (false, 0, 0, 90)
  crDlg: tuple[open: bool; onExport: bool; author: string]
  docsSeen = 0
  startedEvents = false

proc scaledBmp(b: Bitmap; w, h: int): Bitmap =
  ## (`b` made `w` x `h`)
  if b.w == w and b.h == h: return b
  Bitmap(w: w, h: h, px: resample(b.px, b.w, b.h, w, h))

proc imageAssetsOn(d: Doc): bool = d != nil and cast[pointer](d) in imageAssets
proc timelapseOn(): bool = timelapse.on
proc measureShown(): bool = measureDlg

# ---- Measurement Log --------------------------------------------------------------------------------------------

proc recordMeasurement(d: Doc) =
  ## (Record Measurements: the selection's area and perimeter, the ruler's length and angle, the
  ## Count tool's count)
  if d.hasSelection:
    var area = 0
    var edge = 0
    for y in 0 ..< d.h:
      for x in 0 ..< d.w:
        let i = y * d.w + x
        if d.selAt(i) >= 128:
          inc area
          if x == 0 or y == 0 or x == d.w - 1 or y == d.h - 1 or d.selAt(i - 1) < 128 or d.selAt(i + 1) < 128 or
             d.selAt(i - d.w) < 128 or d.selAt(i + d.w) < 128: inc edge
    logMeasurement(d, "Selection", area.float, edge.float, 1)
  else:
    logMeasurement(d, "Document", float(d.w * d.h), float(2 * (d.w + d.h)), 1)

proc measurementDialog() =
  if not measureDlg: return
  let d = cur()
  dialog(measureDlg, "Measurement Log", 560):
    var rows: seq[string]
    for m in measureLog:
      rows.add m.label & "   " & m.doc & "   " & m.at & "   " & tr("area ") & formatFloat(m.area, ffDecimal, 1) &
               "   " & tr("perimeter ") & formatFloat(m.perimeter, ffDecimal, 1) &
               (if m.count > 1: "   " & tr("count ") & $m.count else: "")
    var sel = -1
    discard listbox(rows, sel, rows = 10, w = dp(520))
    row:
      if button("Record Measurements", w = dp(170), enabled = d != nil): d.recordMeasurement()
      if button("Export...", w = dp(90), enabled = measureLog.len > 0):
        var csv = "Label,Document,Date,Area,Perimeter,Length,Angle,Count\n"
        for m in measureLog:
          csv.add m.label & "," & m.doc & "," & m.at & "," & $m.area & "," & $m.perimeter & "," & $m.length & "," &
                  $m.angle & "," & $m.count & "\n"
        let p = picturesDir() / "Measurement Log.csv"
        try:
          writeFile(p, csv)
          status = tr("Saved ") & p
        except IOError: status = tr("Could not save ") & p
      if button("Clear", w = dp(70)): measureLog = @[]
      spring()
      if button("Close", w = dp(80)): measureDlg = false

# ---- Define Custom Shape -------------------------------------------------------------------------------------

proc definedShapesPath(): string = dataDir(AppData) / "Defined Shapes.json"

proc loadDefinedShapes() =
  try:
    let j = parseJson(readFile(definedShapesPath()))
    for e in j.getElems:
      var parts: seq[(PathOp, string)]
      for p in e{"parts"}.getElems:
        var op = poAdd
        for o in PathOp:
          if $o == p{"op"}.getStr: op = o
        parts.add (op, p{"d"}.getStr)
      if parts.len > 0:
        CustomShapes.add CustomShape(name: e{"name"}.getStr("Shape"), category: "Defined", parts: parts)
  except CatchableError: discard

proc defineCustomShape(d: Doc; name: string) =
  ## Edit > Define Custom Shape: the current shape (or path) kept in the Shapes panel's "Defined" set,
  ## drawn again with the Custom Shape tool -- kept for next time.
  var p: Path
  if d.current.isShape: p = d.current.shape.path
  elif d.curPath >= 0 and d.curPath < d.paths.len: p = d.paths[d.curPath]
  if p.subs.len == 0:
    status = tr("Define Custom Shape: pick a shape layer or a path")
    return
  let (x0, y0, x1, y1) = pathBounds(p)
  let s = 100 / max(1e-6, max(x1 - x0, y1 - y0))
  var parts: seq[(PathOp, string)]
  for k, sp in p.subs:
    var one = Path(subs: @[sp])
    one.mapPoints(proc (x, y: float): (float, float) = ((x - x0) * s, (y - y0) * s))
    parts.add ((if k == 0: poAdd else: sp.op), pathData(one))
  CustomShapes.add CustomShape(name: name, category: "Defined", parts: parts)
  var a = newJArray()
  for c in CustomShapes:
    if c.category != "Defined": continue
    var ps = newJArray()
    for (op, dd) in c.parts: ps.add %*{"op": $op, "d": dd}
    a.add %*{"name": c.name, "parts": ps}
  try:
    createDir(definedShapesPath().parentDir)
    writeFile(definedShapesPath(), $a)
  except CatchableError: discard
  status = tr("Defined the shape \"") & name & tr("\": the Shapes panel, the Defined set")

# ---- Transform Selection, Copy CSS and SVG, slices ------------------------------------------------------------

proc transformSelection(d: Doc) =
  ## Select > Transform Selection: the selection's outline made bigger or smaller, turned and moved
  ## round its middle -- the pixels under it left as they are.
  if not d.hasSelection: return
  let b = d.selBounds
  let cx = float(b.x) + float(b.w) / 2
  let cy = float(b.y) + float(b.h) / 2
  let s = max(0.01, xfSelDlg.scale / 100)
  let a = degToRad(xfSelDlg.rotate)
  let ca = cos(a)
  let sa = sin(a)
  var ns = newSeq[uint8](d.w * d.h)
  for y in 0 ..< d.h:
    for x in 0 ..< d.w:
      # (where it came from: back through the move, the turn and the size)
      let px = float(x) + 0.5 - cx - float(xfSelDlg.dx)
      let py = float(y) + 0.5 - cy - float(xfSelDlg.dy)
      let ux = (px * ca + py * sa) / s + cx
      let uy = (-px * sa + py * ca) / s + cy
      let ix = int(floor(ux))
      let iy = int(floor(uy))
      if ix >= 0 and iy >= 0 and ix < d.w and iy < d.h: ns[y * d.w + x] = uint8(d.selAt(iy * d.w + ix))
  d.beginStep("Transform Selection")
  d.touchSel()
  d.sel = ns
  inc d.selVer
  d.endStep()

proc cssOf(d: Doc; L: Layer): string =
  ## (Layer > Copy CSS: the layer as a web page's box would be styled)
  let b = d.objectBox(L)
  let name = L.name.toLowerAscii.multiReplace([(" ", "-"), (".", "-")])
  proc hex(c: uint32): string = "#" & toHex(int(c and 0xFFFFFF), 6).toLowerAscii
  proc rgba(c: uint32): string =
    if aOf(c) == 255: hex(c)
    else: "rgba(" & $rOf(c) & ", " & $gOf(c) & ", " & $bOf(c) & ", " & formatFloat(aOf(c) / 255, ffDecimal, 2) & ")"
  result = "." & name & " {\n  position: absolute;\n"
  if b.ok:
    result.add "  left: " & $int(round(b.x0)) & "px;\n  top: " & $int(round(b.y0)) & "px;\n"
    result.add "  width: " & $int(round(b.x1 - b.x0)) & "px;\n  height: " & $int(round(b.y1 - b.y0)) & "px;\n"
  if L.opacity < 100: result.add "  opacity: " & formatFloat(L.opacity / 100, ffDecimal, 2) & ";\n"
  if L.isShape:
    let s = L.shape
    case s.fill.kind
    of spColor: result.add "  background: " & rgba(s.fill.color) & ";\n"
    of spGradient:
      var stops: seq[string]
      if s.fill.stops.len >= 2:
        for st in s.fill.stops: stops.add rgba(st.color) & " " & $int(round(st.at * 100)) & "%"
      else: stops = @[rgba(s.fill.color), rgba(s.fill.color2)]
      result.add "  background: linear-gradient(" & $((90 - s.fill.angle + 360) mod 360) & "deg, " & stops.join(", ") & ");\n"
    else: discard
    if s.stroke.kind == spColor and s.strokeWidth > 0:
      result.add "  border: " & formatFloat(s.strokeWidth, ffDecimal, 1) & "px solid " & rgba(s.stroke.color) & ";\n"
    if s.radius > 0: result.add "  border-radius: " & $int(round(s.radius)) & "px;\n"
    elif s.kind == "Ellipse": result.add "  border-radius: 50%;\n"
  if L.isText and L.text.spans.len > 0:
    let st = L.text.spans[0].style
    result.add "  font-family: \"" & (if st.family.len > 0: st.family else: "FreeSans") & "\";\n"
    result.add "  font-size: " & formatFloat(st.size, ffDecimal, 1) & "px;\n"
    if "Bold" in st.style: result.add "  font-weight: bold;\n"
    if "Italic" in st.style: result.add "  font-style: italic;\n"
    result.add "  color: " & rgba(st.color) & ";\n"
  let sh = L.fx.fx[fxDropShadow]
  if sh.on and not L.fx.hidden:
    let a = degToRad(float(sh.angle))
    result.add "  box-shadow: " & $int(round(-cos(a) * float(sh.distance))) & "px " &
               $int(round(sin(a) * float(sh.distance))) & "px " & $sh.size & "px " &
               rgba(withAlpha(sh.color, sh.opacity * 255 div 100)) & ";\n"
  result.add "}\n"

proc copySvgOf(d: Doc) =
  ## Layer > Copy SVG: the layers picked as SVG, to paste into a web page or a drawing program.
  var idx = d.pickedLayers
  if idx.len == 0: idx = @[d.cur]
  let o = newDoc(d.w, d.h, 0'u32, d.dpi, d.name)
  o.layers.setLen(0)
  for i in idx:
    if i >= 0 and i < d.layers.len: o.layers.add layerCopy(d.layers[i], d.layers[i].name)
  putClipboardText(o.svgOf())
  status = tr("Copied as SVG")

# ---- fonts, modes, layers ----------------------------------------------------------------------------------------

proc startManageFonts(d: Doc) =
  let have = fontFamilies()
  fontsDlg.missing = @[]
  for L in d.layers:
    if L.isText:
      for sp in L.text.spans:
        let f = sp.style.family
        if f.len > 0 and f notin have and f notin fontsDlg.missing: fontsDlg.missing.add f
  fontsDlg.repl = newSeq[int](fontsDlg.missing.len)
  fontsDlg.open = true

proc manageFontsDialog() =
  if not fontsDlg.open: return
  let d = cur()
  if d == nil:
    fontsDlg.open = false
    return
  let fams = fontFamilies()
  var go = false
  dialog(fontsDlg.open, "Manage Missing Fonts", 460):
    if fontsDlg.missing.len == 0: paragraph("Every font this document uses is here.", color = ui.theme.gray)
    for k, f in fontsDlg.missing:
      row([170, -1]):
        label f
        pushId("mf" & $k)
        combo(fams, fontsDlg.repl[k], w = dp(240))
        popId()
    row:
      if button("Get Google Fonts...", w = dp(150)): runCommand("Get Google Fonts...")
      spring()
      if button("Replace", isDefault = true, w = dp(80), enabled = fontsDlg.missing.len > 0): go = true
      if button("Cancel", w = dp(80)): fontsDlg.open = false
  if go:
    fontsDlg.open = false
    d.beginStep("Manage Missing Fonts")
    d.touchLayers()
    for L in d.layers:
      if not L.isText: continue
      var t = L.text
      var changed = false
      for sp in t.spans.mitems:
        let k = fontsDlg.missing.find(sp.style.family)
        if k >= 0 and fontsDlg.repl[k] in 0 .. fams.high:
          sp.style.family = fams[fontsDlg.repl[k]]
          changed = true
      if changed:
        L.text = t
        d.drawText(L)
    d.markAll()
    d.endStep()

const condModes = ["Bitmap", "Grayscale", "Duotone", "Indexed Color", "RGB Color", "CMYK Color", "Lab Color"]

proc conditionalModeDialog() =
  if not condDlg.open: return
  var go = false
  dialog(condDlg.open, "Conditional Mode Change", 360):
    label("Source Mode:", bold = true)
    for k, n in ["Bitmap", "Grayscale", "Indexed Color", "RGB Color", "CMYK Color", "Lab Color"]:
      checkbox(n, condDlg.from0[k])
    row([110, -1]):
      label "Target Mode:"
      combo(["Grayscale", "RGB Color", "CMYK Color", "Lab Color", "Indexed Color"], condDlg.target, w = dp(140))
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): go = true
      if button("Cancel", w = dp(80)): condDlg.open = false
  if go:
    condDlg.open = false
    let d = cur()
    if d == nil: return
    let src = [cmBitmap, cmGray, cmIndexed, cmRGB, cmCMYK, cmLab]
    var ok = false
    for k, m in src:
      if condDlg.from0[k] and d.mode == m: ok = true
    if ok:
      runCommand(["Grayscale", "RGB Color", "CMYK Color", "Lab Color", "Indexed Color..."][condDlg.target])
      if recording: record(ActStep(kind: acCommand, name: ["Grayscale", "RGB Color", "CMYK Color", "Lab Color",
                                                           "Indexed Color..."][condDlg.target]))
    else: status = tr("Conditional Mode Change: the image's mode is not one of those picked")

proc eachLayerCommand(d: Doc; what: string) =
  ## (Delete All Empty Layers, Flatten All Layer Effects, Flatten All Masks: the script's work)
  d.beginStep(what)
  d.touchLayers()
  var n = 0
  for i in countdown(d.layers.high, 0):
    let L = d.layers[i]
    case what
    of "Delete All Empty Layers":
      if not L.group and not L.background and not L.isShape and not L.isText and L.adjust.kind.len == 0 and
         L.px.len == d.w * d.h and d.layerBox(L).w <= 0:
        d.deleteLayer(i)
        inc n
    of "Flatten All Layer Effects":
      if L.hasFx and not L.group:
        d.cur = i
        runCommand("Rasterize Layer Style")
        inc n
    else:
      if L.mask != nil and not L.group:
        d.cur = i
        runCommand("Apply Layer Mask")
        inc n
  d.endStep()
  status = what & ": " & $n

proc layerCompsToFiles(d: Doc) =
  if d.comps.len == 0:
    status = tr("Layer Comps to Files: the image has no layer comps (Window > Layer Comps)")
    return
  let dir = (if d.path.len > 0: d.path.parentDir else: picturesDir()) / (d.name & " Comps")
  try: createDir(dir) except OSError: discard
  var n = 0
  for c in d.comps:
    d.applyComp(c)
    d.markAll()
    d.updateComposite()
    if d.toBitmap.savePng(dir / (c.name.replace("/", "-") & ".png")): inc n
  status = $n & tr(" comps saved in ") & dir

proc artboardsToPdf(d: Doc) =
  ## File > Export > Artboards to PDF: one PDF, each artboard a page of its own size -- what is on
  ## it, its type and shapes as vectors, over its paper -- in their order.
  if d.boards.len == 0: return
  let p = (if d.path.len > 0: d.path.parentDir else: picturesDir()) / (d.name & " Artboards.pdf")
  try:
    let o = pdfPreset(ppPrint)
    var pdf = newPressPdf(o, d.name)
    for it in d.artboardItems(): pdf.addDocPage(d.itemDoc(it), o)
    pdf.save(p)
    status = tr("Saved ") & p
  except CatchableError: status = tr("Could not save ") & p

# ---- Color Lookup Tables, Render Video, Zoomify -----------------------------------------------------------------

proc exportCube(d: Doc; path: string) =
  ## File > Export > Color Lookup Tables: what the image's adjustment layers do to color, as a 3D LUT
  ## (.cube, 33 x 33 x 33) for a video editor, a camera, another photo program.
  const n = 33
  let side = n * n
  let o = newDoc(side, n, 0xFF000000'u32, 72, "lut")
  for b in 0 ..< n:
    for g in 0 ..< n:
      for r in 0 ..< n:
        o.layers[0].px[b * side + g * n + r] = argb(255, r * 255 div (n - 1), g * 255 div (n - 1), b * 255 div (n - 1))
  var any = false
  for L in d.layers:
    if L.adjust.kind.len > 0 and L.visible:
      let A = o.newAdjustmentLayer(L.adjust)
      A.opacity = L.opacity
      any = true
  if not any:
    status = tr("Color Lookup Tables: the image has no adjustment layers")
    return
  o.markAll()
  o.updateComposite()
  let c = o.compPtr
  var s = "TITLE \"" & d.name & "\"\nLUT_3D_SIZE " & $n & "\n"
  for b in 0 ..< n:
    for g in 0 ..< n:
      for r in 0 ..< n:
        let p = c[b * side + g * n + r]
        s.add formatFloat(rOf(p) / 255, ffDecimal, 6) & " " & formatFloat(gOf(p) / 255, ffDecimal, 6) & " " &
              formatFloat(bOf(p) / 255, ffDecimal, 6) & "\n"
  try:
    writeFile(path, s)
    status = tr("Saved ") & path
  except IOError: status = tr("Could not save ") & path

proc renderVideo(d: Doc; path: string) =
  ## File > Export > Render Video: the Timeline's frames as an MP4 (H.264), each shown as long as it
  ## says; no frames: a still of ten seconds.
  let fps = 30.0
  let w = d.w and not 1
  let h = d.h and not 1
  let v = beginVideo(path, w, h, fps)
  if v == nil:
    status = tr("Could not write ") & path
    return
  beginBusy("Render Video")
  try:
    proc put(b: Bitmap; times: int) =
      var c = b
      if b.w != w or b.h != h:
        c = Bitmap(w: w, h: h, px: newSeq[uint32](w * h))
        for y in 0 ..< h:
          for x in 0 ..< w: c.px[y * w + x] = b.px[y * b.w + x]
      for k in 0 ..< max(1, times): discard v.addFrame(c)
    if d.frames.len == 0:
      d.updateComposite()
      put(d.toBitmap(0xFFFFFFFF'u32), int(fps * 10))
    else:
      let was = d.frameCur
      for k in 0 ..< d.frames.len:
        d.showFrame(k)
        d.markAll()
        d.updateComposite()
        put(d.toBitmap(0xFFFFFFFF'u32), max(1, int(round(float(max(40, d.frames[k].delay)) / 1000 * fps))))
      d.showFrame(was)
      d.markAll()
    if v.finish(): status = tr("Saved ") & path else: status = tr("Could not write ") & path
  finally: endBusy()

proc urlPart(s: string): string =
  ## (`s` as a part of a web address: what is not a letter or a digit as %XX)
  for c in s:
    if c in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.', '~'}: result.add c
    else: result.add "%" & toHex(ord(c), 2)

proc exportZoomify(d: Doc; dir: string) =
  ## File > Export > Zoomify: the picture as tiles at every size (Deep Zoom, .dzi) with a page that
  ## shows it -- zoom and pan a huge picture on the web, only the tiles seen loaded.
  d.updateComposite()
  let full = d.toBitmap(0xFFFFFFFF'u32)
  let base = dir / d.name
  let tdir = base & "_files"
  beginBusy("Zoomify")
  try:
    createDir(tdir)
    var levels = 0
    var s = max(full.w, full.h)
    while s > 1:
      s = (s + 1) div 2
      inc levels
    var cur = full
    for lv in countdown(levels, 0):
      let ld = tdir / $lv
      createDir(ld)
      for ty in 0 .. (cur.h - 1) div 256:
        for tx in 0 .. (cur.w - 1) div 256:
          let x0 = tx * 256
          let y0 = ty * 256
          let tw = min(256, cur.w - x0)
          let th = min(256, cur.h - y0)
          var t = Bitmap(w: tw, h: th, px: newSeq[uint32](tw * th))
          for y in 0 ..< th:
            for x in 0 ..< tw: t.px[y * tw + x] = cur.px[(y0 + y) * cur.w + x0 + x]
          writeFile(ld / ($tx & "_" & $ty & ".jpg"), encodeJpeg(t, 85))
      # (the next level: half the size)
      if cur.w > 1 or cur.h > 1:
        let nw = max(1, (cur.w + 1) div 2)
        let nh = max(1, (cur.h + 1) div 2)
        var nb = Bitmap(w: nw, h: nh, px: newSeq[uint32](nw * nh))
        for y in 0 ..< nh:
          for x in 0 ..< nw:
            var acc = [0, 0, 0]
            var c = 0
            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)]:
              let sx = min(cur.w - 1, x * 2 + dx)
              let sy = min(cur.h - 1, y * 2 + dy)
              let p = cur.px[sy * cur.w + sx]
              acc[0] += rOf(p); acc[1] += gOf(p); acc[2] += bOf(p)
              inc c
            nb.px[y * nw + x] = argb(255, acc[0] div c, acc[1] div c, acc[2] div c)
        cur = nb
    writeFile(base & ".dzi", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Image TileSize=\"256\" Overlap=\"0\" " &
              "Format=\"jpg\" xmlns=\"http://schemas.microsoft.com/deepzoom/2008\"><Size Width=\"" & $full.w &
              "\" Height=\"" & $full.h & "\"/></Image>\n")
    let html = """<!doctype html><meta charset="utf-8"><title>""" & d.name & """</title>
<style>html,body{margin:0;height:100%;overflow:hidden;background:#222}#v{position:absolute;inset:0;cursor:grab}
#v img{position:absolute;image-rendering:auto;user-select:none}</style><div id="v"></div><script>
const W=""" & $full.w & ",H=" & $full.h & ",L=" & $levels & ",T=256,base=" & "\"" & urlPart(d.name) & "_files/\"" & """;
let z=Math.min(innerWidth/W,innerHeight/H),ox=(innerWidth-W*z)/2,oy=(innerHeight-H*z)/2;const v=document.getElementById('v');
function draw(){v.innerHTML='';let lv=Math.min(L,Math.max(0,Math.ceil(Math.log2(z*Math.max(W,H)))));
const s=Math.pow(2,L-lv),lw=Math.ceil(W/s),lh=Math.ceil(H/s),k=z*s;
for(let ty=0;ty*T<lh;ty++)for(let tx=0;tx*T<lw;tx++){const x=ox+tx*T*k,y=oy+ty*T*k;
if(x>innerWidth||y>innerHeight||x+T*k<0||y+T*k<0)continue;const i=new Image();i.src=base+lv+'/'+tx+'_'+ty+'.jpg';
i.style.left=x+'px';i.style.top=y+'px';i.style.width=Math.min(T,lw-tx*T)*k+'px';v.appendChild(i);}}
v.onwheel=e=>{e.preventDefault();const f=e.deltaY<0?1.25:0.8;ox=e.clientX-(e.clientX-ox)*f;oy=e.clientY-(e.clientY-oy)*f;z*=f;draw();};
let d0=null;v.onpointerdown=e=>{d0=[e.clientX,e.clientY,ox,oy];v.setPointerCapture(e.pointerId)};
v.onpointermove=e=>{if(d0){ox=d0[2]+e.clientX-d0[0];oy=d0[3]+e.clientY-d0[1];draw();}};v.onpointerup=()=>d0=null;draw();</script>
"""
    writeFile(base & ".html", html)
    status = tr("Saved ") & base & ".html"
  except CatchableError:
    status = tr("Could not save in ") & dir
  finally: endBusy()

# ---- after a save: image assets, version history, the Save event -----------------------------------------------

proc generateAssets(d: Doc) =
  ## Generate > Image Assets: each layer named like a file ("logo.png", "50% hero.jpg", "200x100
  ## icon.png", several by commas) saved in "<document>-assets" each time the document is saved.
  let dir = (if d.path.len > 0: d.path.parentDir else: picturesDir()) / (d.name & "-assets")
  var n = 0
  for L in d.layers:
    for spec0 in L.name.split(','):
      var spec = spec0.strip
      let ext = spec.splitFile.ext.toLowerAscii
      if ext notin [".png", ".jpg", ".jpeg", ".webp", ".gif"]: continue
      var scale = 1.0
      var fw, fh = 0
      let parts = spec.splitWhitespace
      if parts.len > 1:
        let p0 = parts[0]
        if p0.endsWith("%"):
          try: scale = parseFloat(p0[0 ..< ^1]) / 100 except ValueError: discard
          spec = parts[1 .. ^1].join(" ")
        elif 'x' in p0:
          try:
            fw = parseInt(p0.split('x')[0])
            fh = parseInt(p0.split('x')[1])
            spec = parts[1 .. ^1].join(" ")
          except ValueError: discard
      let r = d.layerBox(L)
      if r.w <= 0: continue
      # (the layer alone, as it looks: drawn by itself)
      var px = newSeq[uint32](d.w * d.h)
      d.compositeInto(px, r, @[L])
      var b = Bitmap(w: r.w, h: r.h, px: newSeq[uint32](r.w * r.h))
      for y in 0 ..< r.h:
        for x in 0 ..< r.w: b.px[y * r.w + x] = px[(r.y + y) * d.w + r.x + x]
      let tw = if fw > 0: fw else: max(1, int(round(float(r.w) * scale)))
      let th = if fh > 0: fh else: max(1, int(round(float(r.h) * scale)))
      if tw != r.w or th != r.h: b = b.scaledBmp(tw, th)
      try:
        createDir(dir)
        let path = dir / spec
        case ext
        of ".jpg", ".jpeg": writeFile(path, encodeJpeg(b, 90))
        of ".webp": writeFile(path, encodeWebp(b, 90))
        of ".gif": writeFile(path, encodeGif(b.w, b.h, quantize(b.px)))
        else: discard b.savePng(path)
        inc n
      except CatchableError: discard
  if n > 0: status = $n & tr(" image assets saved in ") & dir

proc versionDir(d: Doc): string =
  d.path.parentDir / ("." & d.path.extractFilename & ".versions")

proc keepVersion(d: Doc) =
  ## (Version History: a copy of what was saved, the last twenty kept)
  if d.path.len == 0 or not fileExists(d.path): return
  let dir = d.versionDir
  try:
    createDir(dir)
    let stem = dir / now().format("yyyy-MM-dd HH.mm.ss")
    var to = stem & d.path.splitFile.ext
    var k = 2
    while fileExists(to):                 # (saved twice in a second)
      to = stem & " (" & $k & ")" & d.path.splitFile.ext
      inc k
    copyFile(d.path, to)
    var all: seq[string]
    for kind, f in walkDir(dir):          # (no glob: Android before 9 has none)
      if kind == pcFile: all.add f
    all.sort()
    while all.len > 20:
      removeFile(all[0])
      all.delete(0)
  except CatchableError: discard

proc runEvent(k: int) =
  ## (Script Events Manager: the script or action set for an event, run)
  if not eventsLoaded:
    eventsLoaded = true
    try:
      let j = parseJson(readFile(dataDir(AppData) / "Script Events.json"))
      for i in 0 .. 4: scriptEvents[i] = j{$i}.getStr("")
    except CatchableError: discard
  let what = scriptEvents[k]
  if what.len == 0: return
  if what.startsWith("Action: "): runCommand("Play Action: " & what["Action: ".len .. ^1])
  elif fileExists(what): runScriptFile(what)

proc watchDocs() =
  ## (each frame: what happened to the documents -- a save, one opened or closed -- for the image
  ## assets, the versions, the timelapse and the script events)
  if not startedEvents:
    startedEvents = true
    loadDefinedShapes()
    runEvent(0)
  if docs.len > docsSeen:
    let d = docs[^1].doc
    runEvent(if d.path.len > 0: 2 else: 1)
  elif docs.len < docsSeen: runEvent(4)
  docsSeen = docs.len
  for dw in docs:
    let d = dw.doc
    let key = cast[pointer](d)
    let was = savedState.getOrDefault(key, (d.modified, d.path))
    if (was.modified and not d.modified and d.path.len > 0) or (was.path != d.path and d.path.len > 0 and not d.modified):
      # (just saved)
      if key in imageAssets: d.generateAssets()
      d.keepVersion()
      runEvent(3)
    savedState[key] = (d.modified, d.path)
  # the timelapse: a picture after each change
  if timelapse.on and active != nil:
    let d = active.doc
    if d == timelapse.doc and d.ver != timelapse.ver and not d.stepOpen and ui.now - timelapse.at > 400 and
       timelapse.frames.len < 4000:
      timelapse.ver = d.ver
      timelapse.at = ui.now
      d.updateComposite()
      var b = d.toBitmap(0xFFFFFFFF'u32)
      let k = 960 / max(1, max(b.w, b.h))
      if k < 1: b = b.scaledBmp(max(2, int(float(b.w) * k)) and not 1, max(2, int(float(b.h) * k)) and not 1)
      timelapse.frames.add b

proc exportTimelapse(path: string) =
  if timelapse.frames.len == 0: return
  let w = timelapse.frames[^1].w and not 1
  let h = timelapse.frames[^1].h and not 1
  let v = beginVideo(path, w, h, 12)
  if v == nil:
    status = tr("Could not write ") & path
    return
  for b in timelapse.frames:
    var c = b
    if b.w != w or b.h != h: c = b.scaledBmp(w, h)
    discard v.addFrame(c)
  for k in 0 ..< 24: discard v.addFrame(timelapse.frames[^1].scaledBmp(w, h))
  if v.finish(): status = tr("Saved ") & path

# ---- Save for Web ------------------------------------------------------------------------------------------------

proc webEncode(b: Bitmap): string =
  case webDlg.format
  of 0: encodeJpeg(b, webDlg.quality)
  of 1: encodePng(b)
  of 2: encodePngIndexed(b.w, b.h, quantize(b.px, clamp(webDlg.colors, 2, 256)))
  of 3: encodeGif(b.w, b.h, quantize(b.px, clamp(webDlg.colors, 2, 256)))
  else: encodeWebp(b, webDlg.quality)

proc webDecode(data: string): Bitmap =
  ## (what the format gives back: the preview)
  case webDlg.format
  of 0: decodeJpeg(data)
  of 4: decodeWebp(data)
  else: decodePng(data)

proc saveForWebDialog() =
  if not webDlg.open: return
  let d = cur()
  if d == nil:
    webDlg.open = false
    return
  let key = $webDlg.format & "/" & $webDlg.quality & "/" & $webDlg.colors & "/" & $d.ver
  if key != webDlg.key and not ui.mouseDown:
    d.updateComposite()
    var b = d.toBitmap(0xFFFFFFFF'u32)
    let data = webEncode(b)
    webDlg.bytes = data.len
    # (the preview: a part of it as the format gives it back)
    let s = min(1.0, 320 / max(1, max(b.w, b.h)))
    let small = b.scaledBmp(max(1, int(float(b.w) * s)), max(1, int(float(b.h) * s)))
    let enc = if webDlg.format == 3: encodePngIndexed(small.w, small.h, quantize(small.px, clamp(webDlg.colors, 2, 256)))
              else: webEncode(small)                     # (GIF's look: PNG-8's, the same palette)
    let back = try: webDecode(enc) except CatchableError: small
    webDlg.preview = if back != nil: back else: small
    webDlg.preview.changed()
    webDlg.key = key
  dialog(webDlg.open, "Save for Web (Legacy)", 560):
    row([330, -1]):
      col:
        let r = place(dp(320), dp(240))
        box(r, ui.theme.frame)
        if webDlg.preview != nil:
          let k = min(r.w / webDlg.preview.w, r.h / webDlg.preview.h)
          drawBitmap(rect(r.x, r.y, int(float(webDlg.preview.w) * k), int(float(webDlg.preview.h) * k)), webDlg.preview)
        label(formatSize(webDlg.bytes) & "   " & tr("at 1 Mbps: ") &
              formatFloat(float(webDlg.bytes) * 8 / 1_000_000, ffDecimal, 1) & " s", color = ui.theme.gray)
      col:
        row:
          label "Format:"
          combo(["JPEG", "PNG-24", "PNG-8", "GIF", "WebP"], webDlg.format, w = dp(110))
        if webDlg.format in {0, 4}: optSlider("Quality:", webDlg.quality, 1, 100, "")
        if webDlg.format in {2, 3}: optSlider("Colors:", webDlg.colors, 2, 256, "")
        space(dp(8))
        if button("Save...", isDefault = true, w = dp(100)): webPick = true
        if button("Cancel", w = dp(100)): webDlg.open = false
  let ext = [".jpg", ".png", ".png", ".gif", ".webp"][clamp(webDlg.format, 0, 4)]
  if filePicker(webPick, webPath, fmSave, ["*" & ext], "Save for Web"):
    var p = webPath
    if not p.toLowerAscii.endsWith(ext): p.add ext
    d.updateComposite()
    try:
      writeFile(p, webEncode(d.toBitmap(0xFFFFFFFF'u32)))
      status = tr("Saved ") & p
      webDlg.open = false
    except IOError: status = tr("Could not save ") & p

# ---- Astrophotography Stack ----------------------------------------------------------------------------------

proc astroDialog() =
  if not astroDlg.open: return
  var go = false
  dialog(astroDlg.open, "Astrophotography Stack", 520):
    paragraph("Frames of the night sky made one: calibrated by the dark, flat and bias frames, lined up on " &
              "the stars, stacked so the noise goes and the faint stars come out.", color = ui.theme.gray)
    for (k, n) in [(0, "Light Frames"), (1, "Dark Frames"), (2, "Flat Frames"), (3, "Bias Frames")]:
      let list = case k
                 of 0: astroDlg.lights
                 of 1: astroDlg.darks
                 of 2: astroDlg.flats
                 else: astroDlg.bias
      row([150, -1, 80, 60]):
        label(tr(n) & ": " & $list.len, bold = k == 0)
        label(if list.len > 0: list[^1].extractFilename else: "", color = ui.theme.gray)
        pushId("astroadd" & $k)
        if button("Add...", w = dp(76)):
          astroDlg.pick = k
          astroPicking = true
        if button("Clear", w = dp(56)):
          case k
          of 0: astroDlg.lights = @[]
          of 1: astroDlg.darks = @[]
          of 2: astroDlg.flats = @[]
          else: astroDlg.bias = @[]
        popId()
    row([150, -1]):
      label "Stacking:"
      combo(["Mean", "Median", "Sigma Clipping"], astroDlg.mode, w = dp(160))
    checkbox("Line up on the stars", astroDlg.align)
    checkbox("Remove the background gradient", astroDlg.gradient)
    row:
      spring()
      if button("Stack", isDefault = true, w = dp(80), enabled = astroDlg.lights.len > 0): go = true
      if button("Cancel", w = dp(80)): astroDlg.open = false
  if filePicker(astroPicking, astroPath, fmOpen, ["*.png", "*.jpg", "*.jpeg", "*.tif", "*.tiff", "*.webp", "*.rpd",
                                                  "*.dng", "*.cr2", "*.nef", "*.arw"], "Add Frames"):
    case astroDlg.pick
    of 0: astroDlg.lights.add astroPath
    of 1: astroDlg.darks.add astroPath
    of 2: astroDlg.flats.add astroPath
    else: astroDlg.bias.add astroPath
  if go:
    astroDlg.open = false
    beginBusy("Astrophotography Stack")
    try:
      proc load(ps: seq[string]): seq[Img] =
        for p in ps:
          let b = try: loadPicture(p, 20000, 20000) except CatchableError: nil
          if b != nil: result.add Img(w: b.w, h: b.h, px: b.px)
      let lights = load(astroDlg.lights)
      if lights.len == 0:
        status = tr("Could not read the light frames")
        return
      var im = astroStack(lights, load(astroDlg.darks), load(astroDlg.flats), load(astroDlg.bias),
                          astroDlg.align, astroDlg.mode)
      if astroDlg.gradient: im = removeGradient(100)(im, rect(0, 0, im.w, im.h))
      let d = newUntitled(im.w, im.h, 0, name = "Stacked")
      d.layers[0].px = im.px
      inc d.layers[0].ver
      d.markAll()
      addDoc(d)
      status = tr("Stacked ") & $lights.len & tr(" frames: Image > Adjustments > Levels or Curves brings the faint " &
                                                   "stars out")
    finally: endBusy()

# ---- 360 views ----------------------------------------------------------------------------------------------------

proc pano360Dialog() =
  if not pano360Dlg.open: return
  let d = cur()
  if d == nil:
    pano360Dlg.open = false
    return
  var go = false
  dialog(pano360Dlg.open, "Edit 360 View", 360):
    paragraph("A flat view of the 360 picture to edit as any picture; Image > 360 Panorama > Apply View puts " &
              "what you changed back.", color = ui.theme.gray)
    optSlider("Look Round:", pano360Dlg.yaw, -180, 180, "°")
    optSlider("Look Up:", pano360Dlg.pitch, -90, 90, "°")
    optSlider("Field of View:", pano360Dlg.fov, 20, 150, "°")
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): go = true
      if button("Cancel", w = dp(80)): pano360Dlg.open = false
  if go:
    pano360Dlg.open = false
    d.updateComposite()
    let src = Img(w: d.w, h: d.h, px: d.toBitmap.px)
    let w = min(2048, d.w div 2)
    let h = w * 3 div 4
    let v = equirectView(src, pano360Dlg.yaw.float, pano360Dlg.pitch.float, pano360Dlg.fov.float, w, h)
    let nd = newUntitled(w, h, 0, name = d.name & " 360 View")
    nd.layers[0].px = v.px
    inc nd.layers[0].ver
    nd.markAll()
    view360[cast[pointer](nd)] = (d, pano360Dlg.yaw.float, pano360Dlg.pitch.float, pano360Dlg.fov.float)
    addDoc(nd)

proc apply360(d: Doc) =
  let key = cast[pointer](d)
  if key notin view360:
    status = tr("Apply View: make the view with Image > 360 Panorama > Edit View first")
    return
  let (src, yaw, pitch, fov) = view360[key]
  if not docs.anyIt(it.doc == src):
    status = tr("The 360 picture was closed")
    return
  d.updateComposite()
  let view = Img(w: d.w, h: d.h, px: d.toBitmap.px)
  let L = src.layer
  if L.px.len != src.w * src.h: return
  src.beginStep("Apply 360 View")
  src.touch(L, src.bounds)
  var pano = Img(w: src.w, h: src.h, px: L.px)
  equirectApply(pano, view, yaw, pitch, fov)
  L.px = pano.px
  inc L.ver
  src.markAll()
  src.endStep()
  status = tr("The view put back into ") & src.name

# ---- Decompose, Layer to 3D, Select People -------------------------------------------------------------------

proc decomposeLayers(d: Doc) =
  ## Layer > Decompose Layers (Affinity's Scene Decomposition): a flat picture split into a layer for
  ## each thing in it the picture's regions find (Object Finder), the background behind them filled
  ## from what is round.
  let L = d.current
  if L == nil or L.px.len != d.w * d.h or L.isShape or L.isText: return
  beginBusy("Decompose Layers")
  try:
    let src = Img(w: d.w, h: d.h, px: L.px)
    let seg = segment(src, 320, 1400, minSize = (d.w * d.h) div 400)
    # (the big regions that do not touch the edges much: things, not the ground)
    var things: seq[int]
    for k, b in seg.boxes:
      let area = b.w * b.h
      if area < seg.w * seg.h div 200 or area > seg.w * seg.h * 2 div 3: continue
      things.add k
    if things.len == 0:
      status = tr("Decompose Layers: no separate things were found")
      return
    d.beginStep("Decompose Layers")
    d.touchLayers()
    var made = 0
    for k in things[0 ..< min(12, things.len)]:
      let m = findObject(src, seg, k)
      if m.len != d.w * d.h: continue
      let N = d.newLayer(tr("Object ") & $(made + 1))
      for i in 0 ..< m.len:
        if m[i] > 0: N.px[i] = withAlpha(L.px[i], aOf(L.px[i]) * int(m[i]) div 255)
      d.layers.insert(N, d.layers.find(L) + 1 + made)
      inc made
    d.cur = d.layers.find(L) + made
    d.markAll()
    d.endStep()
    status = tr("Decompose Layers: ") & $made & tr(" layers over the picture")
  finally: endBusy()

proc layerTo3d(d: Doc) =
  ## Layer > Layer to 3D: the layer as a relief -- light high, dark low -- saved as a 3D model (.glb)
  ## beside the document, for a 3D program, a web page, a printer.
  let L = d.current
  if L == nil or L.px.len != d.w * d.h: return
  let r = d.layerBox(L)
  if r.w < 2 or r.h < 2: return
  var src = Img(w: r.w, h: r.h, px: newSeq[uint32](r.w * r.h))
  for y in 0 ..< r.h:
    for x in 0 ..< r.w: src.px[y * r.w + x] = L.px[(r.y + y) * d.w + r.x + x]
  let step = max(1, max(r.w, r.h) div 256)
  let m = heightfieldMesh(src, float(max(r.w, r.h)) * 0.08, step)
  var mesh = newMesh(L.name)
  let k = 1 / float32(max(r.w, r.h))
  for (x, y, z) in m.verts: mesh.verts.add vec3((x - float32(r.w) / 2) * k, -(y - float32(r.h) / 2) * k, z * k)
  mesh.tris = m.tris
  for c in m.colors: mesh.colors.add colorOf(c)
  mesh.smooth = true
  let p = (if d.path.len > 0: d.path.parentDir else: picturesDir()) / (L.name.replace("/", "-") & ".glb")
  try:
    writeFile(p, toGlb(Scene3(meshes: @[mesh])))
    status = tr("Saved ") & p
  except CatchableError: status = tr("Could not save ") & p

proc selectPeople(d: Doc) =
  ## Select > People: the people in the picture selected -- the subject, kept where it holds a face.
  beginBusy("Select People")
  try:
    let m = d.selectSubject()
    if m.len != d.w * d.h:
      status = tr("Select People: no one was found")
      return
    d.beginStep("Select People")
    d.touchSel()
    d.sel = m
    inc d.selVer
    d.endStep()
  finally: endBusy()

# ---- the dialogs, the commands -----------------------------------------------------------------------------------

proc droplets(): string =
  ## (where a droplet is made: the desktop, else the home folder)
  for n in ["Desktop", "desktop"]:
    if dirExists(getHomeDir() / n): return getHomeDir() / n
  getHomeDir()

proc fileMoreDialogs() =
  watchDocs()
  measurementDialog()
  manageFontsDialog()
  conditionalModeDialog()
  saveForWebDialog()
  astroDialog()
  pano360Dialog()
  let d = cur()
  if focusMergeNext and d != nil and d.layers.len > 1 and d.name.startsWith("Untitled Stack"):
    focusMergeNext = false
    d.autoBlend(true)
    status = tr("Focus Merge: each part from the frame where it is sharpest")
  if xfSelDlg.open:
    var go = false
    dialog(xfSelDlg.open, "Transform Selection", 320):
      row([110, -1]):
        label "Scale:"
        discard numberEdit(xfSelDlg.scale, decimals = 1, w = dp(80), lo = 1, hi = 1000)
      row([110, -1]):
        label "Rotate:"
        discard numberEdit(xfSelDlg.rotate, decimals = 1, w = dp(80), lo = -360, hi = 360)
      row([110, -1]):
        label "Move across:"
        spin(xfSelDlg.dx, -30000, 30000, w = dp(80))
      row([110, -1]):
        label "Move down:"
        spin(xfSelDlg.dy, -30000, 30000, w = dp(80))
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)): go = true
        if button("Cancel", w = dp(80)): xfSelDlg.open = false
    if go and d != nil:
      xfSelDlg.open = false
      d.transformSelection()
  if filePicker(cubePick, cubePath, fmSave, ["*.cube"], "Export Color Lookup Tables"):
    if d != nil: d.exportCube(if cubePath.endsWith(".cube"): cubePath else: cubePath & ".cube")
  if filePicker(videoPick, videoPath, fmSave, ["*.mp4"], "Render Video"):
    let p = if videoPath.toLowerAscii.endsWith(".mp4"): videoPath else: videoPath & ".mp4"
    if timelapse.frames.len > 0 and not timelapse.on and d != nil and d == timelapse.doc and d.frames.len == 0:
      exportTimelapse(p)
    elif d != nil: d.renderVideo(p)
  if filePicker(zoomPick, zoomPath, fmFolder, [], "Zoomify"):
    if d != nil: d.exportZoomify(zoomPath)
  if versionsDlg.open and d != nil:
    var names: seq[string]
    for p in versionsDlg.list: names.add p.extractFilename
    dialog(versionsDlg.open, "Version History", 420):
      if names.len == 0: paragraph("No versions yet: each save keeps one (the last twenty).", color = ui.theme.gray)
      discard listbox(names, versionsDlg.sel, rows = 10, w = dp(380))
      row:
        if button("Open", w = dp(80), enabled = versionsDlg.sel in 0 .. versionsDlg.list.high):
          let o = try: loadRpd(versionsDlg.list[versionsDlg.sel]) except CatchableError: nil
          if o != nil:
            o.name = d.name & " (" & names[versionsDlg.sel] & ")"
            o.path = ""
            addDoc(o)
        spring()
        if button("Close", w = dp(80)): versionsDlg.open = false
  if eventsDlg:
    dialog(eventsDlg, "Script Events Manager", 460):
      paragraph("A script (its file) or an action (\"Action: its name\") run when it happens.", color = ui.theme.gray)
      for k, n in ["Start Application", "New Document", "Open Document", "Save Document", "Close Document"]:
        row([150, -1]):
          label n
          pushId("ev" & $k)
          discard edit(scriptEvents[k], w = dp(280))
          popId()
      row:
        spring()
        if button("Done", isDefault = true, w = dp(80)):
          eventsDlg = false
          var j = newJObject()
          for i in 0 .. 4: j[$i] = %scriptEvents[i]
          try:
            createDir(dataDir(AppData))
            writeFile(dataDir(AppData) / "Script Events.json", $j)
          except CatchableError: discard
  if dropletDlg.open:
    if not actionsLoaded: loadActions()
    var names: seq[string]
    for a in actions: names.add a.name
    var go = false
    dialog(dropletDlg.open, "Create Droplet", 440):
      paragraph("A little program on the desktop: pictures dropped on it are opened, the action played, " &
                "saved in the folder -- Retro Atelier without its window.", color = ui.theme.gray)
      row([90, -1]):
        label "Action:"
        combo(names, dropletDlg.action, w = dp(280))
      row([90, -1]):
        label "Save in:"
        discard edit(dropletDlg.outDir, w = dp(280))
      row:
        spring()
        if button("Create", isDefault = true, w = dp(80), enabled = names.len > 0): go = true
        if button("Cancel", w = dp(80)): dropletDlg.open = false
    if go and dropletDlg.action in 0 .. names.high:
      dropletDlg.open = false
      let act = names[dropletDlg.action]
      let exe = getAppFilename()
      let outd = if dropletDlg.outDir.len > 0: dropletDlg.outDir else: picturesDir() / "Droplet"
      let base = droplets() / (act.replace("/", "-") & " Droplet")
      try:
        when defined(windows):
          writeFile(base & ".cmd", "@echo off\r\nif not exist \"" & outd & "\" mkdir \"" & outd & "\"\r\n" &
                    ":next\r\nif \"%~1\"==\"\" goto :eof\r\n\"" & exe & "\" --headless \"%~1\" --run \"Play Action: " &
                    act & "\" --save \"" & outd & "\\%~n1.png\"\r\nshift\r\ngoto next\r\n")
        else:
          writeFile(base & ".sh", "#!/bin/sh\nmkdir -p '" & outd & "'\nfor f in \"$@\"; do\n  n=$(basename \"$f\")\n" &
                    "  '" & exe & "' --headless \"$f\" --run 'Play Action: " & act & "' --save '" & outd &
                    "'/\"${n%.*}.png\"\ndone\n")
          setFilePermissions(base & ".sh", {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec,
                                            fpOthersRead, fpOthersExec})
        status = tr("Droplet made on the desktop: drop pictures on it")
      except CatchableError: status = tr("Could not make the droplet")
  if crDlg.open and d != nil:
    dialog(crDlg.open, "Content Credentials", 460):
      paragraph("How this picture was made, kept with what you export: the app, who made it, the edits " &
                "(History), the date -- a record anyone can read beside the picture (a .json beside the file).",
                color = ui.theme.gray)
      row([90, -1]):
        label "Author:"
        discard edit(crDlg.author, w = dp(300))
      checkbox("Write it beside each export", crDlg.onExport)
      row:
        if button("Save Now", w = dp(100)):
          var steps = newJArray()
          for k, s in d.historyStates:
            if k <= d.historyAt: steps.add %s
          let j = %*{"claim_generator": AppName & " " & AppVersion, "title": d.name, "author": crDlg.author,
                     "created": now().format("yyyy-MM-dd'T'HH:mm:sszzz"), "actions": steps,
                     "note": "Content Credentials as a plain record (not C2PA-signed)"}
          let p = (if d.path.len > 0: d.path.parentDir else: picturesDir()) / (d.name & ".credentials.json")
          try:
            writeFile(p, j.pretty)
            status = tr("Saved ") & p
          except IOError: status = tr("Could not save ") & p
        spring()
        if button("Close", w = dp(80)): crDlg.open = false

proc fileMoreCommand(name: string): bool =
  let d = cur()
  result = true
  if name.startsWith("Play Action: "):
    if not actionsLoaded: loadActions()
    let n = name["Play Action: ".len .. ^1]
    for i, a in actions:
      if a.name == n:
        playAction(i)
        return
    status = tr("No action named ") & n
    return
  case name
  of "Measurement Log": measureDlg = not measureDlg
  of "Record Measurements": (if d != nil: d.recordMeasurement())
  of "Define Custom Shape...":
    if d != nil: d.defineCustomShape(if d.current.isShape: d.current.name else: tr("Shape ") & $(CustomShapes.len + 1))
  of "Transform Selection...": (if d != nil and d.hasSelection: xfSelDlg.open = true)
  of "Copy CSS":
    if d != nil:
      var css = ""
      var idx = d.pickedLayers
      if idx.len == 0: idx = @[d.cur]
      for i in idx: css.add d.cssOf(d.layers[i])
      putClipboardText(css)
      status = tr("Copied as CSS")
  of "Copy SVG": (if d != nil: d.copySvgOf())
  of "New Layer Based Slice":
    if d != nil:
      let r = d.layerBox(d.current)
      if r.w > 0:
        slices.add (d, r)
        status = tr("A slice round the layer")
  of "Manage Missing Fonts...": (if d != nil: d.startManageFonts())
  of "Conditional Mode Change...": condDlg.open = true
  of "Delete All Empty Layers", "Flatten All Layer Effects", "Flatten All Masks": (if d != nil: d.eachLayerCommand(name))
  of "Layer Comps to Files...": (if d != nil: d.layerCompsToFiles())
  of "Artboards to PDF...": (if d != nil: d.artboardsToPdf())
  of "Color Lookup Tables...": cubePick = true
  of "Render Video...": videoPick = true
  of "Zoomify...": zoomPick = true
  of "Image Assets":
    if d != nil:
      let k = cast[pointer](d)
      if k in imageAssets: imageAssets.keepItIf(it != k)
      else:
        imageAssets.add k
        status = tr("Image Assets: layers named like files (\"logo.png\", \"50% hero.jpg\") saved with each save")
  of "Version History...":
    if d != nil:
      versionsDlg.list = @[]
      if d.path.len > 0:
        for kind, f in walkDir(d.versionDir):
          if kind == pcFile: versionsDlg.list.add f
      versionsDlg.list.sort(proc (a, b: string): int = cmp(b, a))
      versionsDlg.sel = -1
      versionsDlg.open = true
  of "Record Timelapse":
    if timelapse.on:
      timelapse.on = false
      status = $timelapse.frames.len & tr(" pictures of the work: File > Export > Render Video saves them")
    elif d != nil:
      timelapse = (true, d, -1, 0, newSeq[Bitmap]())
      status = tr("Timelapse: each change kept as a picture")
  of "Script Events Manager...": eventsDlg = true
  of "Create Droplet...":
    dropletDlg.open = true
  of "Save for Web (Legacy)...":
    if d != nil:
      webDlg.open = true
      webDlg.key = ""
      if webDlg.quality == 0: webDlg = (true, 0, 80, 128, true, nil, "", 0)
  of "Focus Merge...":
    focusMergeNext = true
    mgStackAlign = true
    startMerge(mkStack)
  of "Astrophotography Stack...": astroDlg.open = true
  of "Remove Background Gradient...": startFilter("Remove Background Gradient")
  of "Edit 360 View...": (if d != nil: pano360Dlg.open = true)
  of "Apply 360 View": (if d != nil: d.apply360())
  of "Decompose Layers": (if d != nil: d.decomposeLayers())
  of "Layer to 3D": (if d != nil: d.layerTo3d())
  of "People": (if d != nil: d.selectPeople())
  of "Content Credentials...": crDlg.open = true
  else: result = aiMoreCommand(name)
