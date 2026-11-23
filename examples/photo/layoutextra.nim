# (included by photo.nim) The layout program's commands that the others here did not have: Create
# Guides, Adjust Layout and Create Alternate Layout (the page another size, what is on it following
# by a rule: Scale or Re-center), Auto Style, Quick Apply, Insert HTML, Basic and Directional
# Feather, Clipping Path (Detect Edges), Multi-State Objects, Content-Aware Fit, Snippets, Stroke
# Styles, Flattener Preview, Articles, Accessibility Check, Sidenotes and Merge Document.

var
  guidesDlg: tuple[open: bool; rows, cols: int; rowGutter, colGutter: float32; fitMargins, removeOld: bool] =
    (false, 2, 2, 12, 12, true, true)
  adjustDlg: tuple[open: bool; w, h: int; rule: int; alternate: bool] = (false, 0, 0, 0, false)
  quickDlg: tuple[open: bool; find: string; sel: int]
  htmlDlg: tuple[open: bool; code: string]
  featherDlg: tuple[open: bool; directional: bool; width, choke, noise: int; corners: int;
                    sides: array[4, int]; angle: int] = (false, false, 12, 0, 0, 1, [0, 0, 0, 0], 0)
  clipDlg: tuple[open: bool; threshold, tolerance: int; inset: int; invert: bool] = (false, 25, 2, 0, false)
  checkDlg: tuple[open: bool; issues: seq[tuple[layer: Layer; what: string]]; sel: int]
  articles: Table[pointer, seq[int]]           ## each document's Articles: its layers' uids, in reading order
  articlesDlg: tuple[open: bool; sel: int]
  strokeStyleDlg: tuple[open: bool; pick: int]

proc layoutTargets(d: Doc): seq[Layer] =
  ## (the layers picked, else the current one -- not the Background)
  for i in d.pickedLayers:
    if i >= 0 and i < d.layers.len and not d.layers[i].background: result.add d.layers[i]
  if result.len == 0 and d.current != nil and not d.current.background: result.add d.current

proc pageBox(d: Doc): Rect =
  ## (the page the guides go on: a book page's margins, else the whole canvas)
  let bw = curBook()
  if bw != nil and guidesDlg.fitMargins: bw.book.marginBox(bw.page) else: d.bounds

# ---- guides -----------------------------------------------------------------------------------------------------

proc createGuides(d: Doc) =
  ## Layout > Create Guides: rows and columns with gutters across the margins (or the page).
  let r = d.pageBox
  d.beginStep("Create Guides")
  d.touchLayers()
  if guidesDlg.removeOld: d.guides.setLen(0)
  let rows = max(1, guidesDlg.rows)
  let cols = max(1, guidesDlg.cols)
  let rg = guidesDlg.rowGutter.float
  let cg = guidesDlg.colGutter.float
  let ch = (r.h.float - rg * float(rows - 1)) / float(rows)
  let cw = (r.w.float - cg * float(cols - 1)) / float(cols)
  for k in 0 .. rows:
    let y0 = r.y.float + float(k) * (ch + rg)
    if k > 0 and k < rows:
      d.guides.add Guide(vertical: false, pos: y0 - rg)
      if rg > 0: d.guides.add Guide(vertical: false, pos: y0)
    elif k == 0 or k == rows: d.guides.add Guide(vertical: false, pos: (if k == 0: r.y.float else: float(r.y + r.h)))
  for k in 0 .. cols:
    let x0 = r.x.float + float(k) * (cw + cg)
    if k > 0 and k < cols:
      d.guides.add Guide(vertical: true, pos: x0 - cg)
      if cg > 0: d.guides.add Guide(vertical: true, pos: x0)
    elif k == 0 or k == cols: d.guides.add Guide(vertical: true, pos: (if k == 0: r.x.float else: float(r.x + r.w)))
  inc d.ver
  d.endStep()

# ---- Adjust Layout, Alternate Layout ---------------------------------------------------------------------------

proc adjustLayout(d: Doc; nw, nh, rule: int) =
  ## (the page made `nw` x `nh`, what is on it following: 0 scaled with it, 1 kept its size, moved so
  ## it stays as far from the middle -- the layout program's Liquid Layout rules Scale and Re-center)
  if nw < 1 or nh < 1: return
  let sx = nw / d.w
  let sy = nh / d.h
  let s = min(sx, sy)
  let ox = (nw - d.w) div 2
  let oy = (nh - d.h) div 2
  let w0 = d.w
  let h0 = d.h
  d.snapStep("Adjust Layout")
  try: d.canvasSize(nw, nh, 1, 1, 0'u32)
  except ValueError:
    d.endStep()
    return
  # (the canvas grew round the middle: everything moved by `ox`, `oy` already)
  if rule == 0:
    for L in d.layers:
      if L.group or L.background: continue
      if L.isShape:
        var sh = L.shape
        sh.path.mapPoints(proc (x, y: float): (float, float) =
          let cx = float(nw) / 2 + (x - float(nw) / 2) * s
          let cy = float(nh) / 2 + (y - float(nh) / 2) * s
          (cx, cy))
        sh.strokeWidth *= s
        d.setShape(L, sh)
      elif L.isText:
        var t = L.text
        t.x = float32(float(nw) / 2 + (float(t.x) - float(nw) / 2) * s)
        t.y = float32(float(nh) / 2 + (float(t.y) - float(nh) / 2) * s)
        t.boxW *= float32(s)
        t.boxH *= float32(s)
        for sp in t.spans.mitems: sp.style.size *= float32(s)
        L.text = t
        d.drawText(L)
      elif L.px.len == d.w * d.h:
        let b = d.layerBox(L)
        if b.w > 0 and b.h > 0:
          let nb = rect(int(float(nw) / 2 + (float(b.x) - float(nw) / 2) * s),
                        int(float(nh) / 2 + (float(b.y) - float(nh) / 2) * s), max(1, int(float(b.w) * s)),
                        max(1, int(float(b.h) * s)))
          d.transformLayer(L, b, nb)
  discard w0
  discard h0
  discard ox
  discard oy
  d.markAll()
  d.endStep()
  d.modified = true

# ---- Auto Style ------------------------------------------------------------------------------------------------

proc autoStyle(d: Doc) =
  ## Type > Auto Style: the type picked styled by what each paragraph is -- the first a title, short
  ## lines without a full stop headings, lines that begin with "-", "*" or "•" a list, the rest
  ## body text (each made bigger, bolder, indented as it should be).
  let L = d.current
  if L == nil or not L.isText:
    status = tr("Auto Style: pick a type layer")
    return
  d.beginStep("Auto Style")
  d.touchLayers()
  var t = L.text
  let txt = t.plainText
  let base = if t.spans.len > 0: t.spans[0].style.size else: 16'f32
  var paras: seq[(int, int, string)]       # (from, to, its text)
  var start = 0
  var k = 0
  var cur = ""
  for r in txt.runes:
    if r == Rune('\n'):
      paras.add (start, k, cur)
      start = k + 1
      cur = ""
    else: cur.add r.toUTF8
    inc k
  paras.add (start, k, cur)
  for i, (a, b, s) in paras:
    if b <= a: continue
    let st = s.strip
    if i == 0 and st.runeLen < 90:
      t.restyle(a, b, proc (c: var CharStyle) =
        c.size = base * 1.8
        c.style = "Bold")
    elif st.runeLen < 60 and st.len > 0 and st[^1] notin {'.', ',', ';', ':', '!', '?'}:
      t.restyle(a, b, proc (c: var CharStyle) =
        c.size = base * 1.3
        c.style = "Bold")
    elif st.startsWith("- ") or st.startsWith("* ") or st.startsWith("•"):
      t.restyle(a, b, proc (c: var CharStyle) = c.size = base)
    else:
      t.restyle(a, b, proc (c: var CharStyle) = c.size = base)
  L.text = t
  d.drawText(L)
  d.markAll()
  d.endStep()
  status = tr("Auto Style: ") & $paras.len & tr(" paragraphs styled")

# ---- Insert HTML -------------------------------------------------------------------------------------------------

proc insertHtml(d: Doc) =
  ## Object > Insert HTML: the code kept with a frame on the page (a video, a map, a form to embed
  ## in the page's HTML and EPUB export), its text shown in the frame.
  let code = htmlDlg.code
  if code.strip.len == 0: return
  let w = min(d.w * 2 div 3, 600)
  let h = min(d.h div 2, 340)
  let x = (d.w - w) div 2
  let y = (d.h - h) div 2
  d.beginStep("Insert HTML")
  d.touchLayers()
  var s = ShapeData(path: Path(subs: @[SubPath(closed: true, pts: @[
                      PathPoint(p: (x.float, y.float), inH: (x.float, y.float), outH: (x.float, y.float)),
                      PathPoint(p: (float(x + w), y.float), inH: (float(x + w), y.float), outH: (float(x + w), y.float)),
                      PathPoint(p: (float(x + w), float(y + h)), inH: (float(x + w), float(y + h)), outH: (float(x + w), float(y + h))),
                      PathPoint(p: (x.float, float(y + h)), inH: (x.float, float(y + h)), outH: (x.float, float(y + h)))])]),
                    fill: solidPaint(0xFFF2F2F2'u32), stroke: solidPaint(0xFF9A9A9A'u32), strokeWidth: 1,
                    kind: "Rectangle")
  let F = d.addShapeLayer(s, name = "HTML")
  F.meta = $(%*{"html": code})
  var t = newText(("HTML\n" & htmlToText(code)).substr(0, 600), typingStyle())
  t.x = float32(x + 10)
  t.y = float32(y + 10)
  t.boxW = float32(w - 20)
  t.boxH = float32(h - 20)
  discard d.addTextLayer(t)
  d.endStep()

# ---- feathers ----------------------------------------------------------------------------------------------------

proc featherMask(d: Doc; L: Layer) =
  ## Basic Feather: the layer's edges fading out over `width` pixels (choked first, corners rounded
  ## or sharp, a little noise); Directional Feather: each side its own width -- into its mask.
  let n = d.w * d.h
  if L.px.len != n: return
  var a = newSeq[float32](n)
  for i in 0 ..< n: a[i] = float32(aOf(L.px[i])) / 255
  # (how far each pixel is inside the layer's shape: a distance, row then column)
  var dist = newSeq[float32](n)
  const big = 1e9'f32
  for i in 0 ..< n: dist[i] = if a[i] > 0.5: big else: 0
  for y in 0 ..< d.h:
    var run = 0'f32
    for x in 0 ..< d.w:
      if dist[y * d.w + x] == 0: run = 0 else: run += 1
      dist[y * d.w + x] = min(dist[y * d.w + x], run)
    run = 0
    for x in countdown(d.w - 1, 0):
      if dist[y * d.w + x] == 0: run = 0 else: run += 1
      dist[y * d.w + x] = min(dist[y * d.w + x], run)
  if not featherDlg.directional:
    for x in 0 ..< d.w:
      var run = 0'f32
      for y in 0 ..< d.h:
        if dist[y * d.w + x] == 0: run = 0 else: run += 1
        dist[y * d.w + x] = min(dist[y * d.w + x], run)
      run = 0
      for y in countdown(d.h - 1, 0):
        if dist[y * d.w + x] == 0: run = 0 else: run += 1
        dist[y * d.w + x] = min(dist[y * d.w + x], run)
  var m = newSeq[uint8](n)
  let b = d.layerBox(L)
  var rng = initRand(7)
  for y in 0 ..< d.h:
    for x in 0 ..< d.w:
      let i = y * d.w + x
      var v: float
      if featherDlg.directional:
        # (each side its own: top, bottom, left, right)
        let s = featherDlg.sides
        var f = 1.0
        if s[0] > 0: f = min(f, float(y - b.y) / float(s[0]))
        if s[1] > 0: f = min(f, float(b.y + b.h - 1 - y) / float(s[1]))
        if s[2] > 0: f = min(f, float(x - b.x) / float(s[2]))
        if s[3] > 0: f = min(f, float(b.x + b.w - 1 - x) / float(s[3]))
        v = clamp(f, 0, 1)
      else:
        let w = max(1, featherDlg.width).float
        let dd = float(dist[i]) - float(featherDlg.choke) / 100 * w
        v = clamp(dd / w, 0, 1)
        if featherDlg.corners == 1: v = v * v * (3 - 2 * v)          # (rounded: smooth)
        elif featherDlg.corners == 2: v = sqrt(v)                   # (diffused)
      if featherDlg.noise > 0 and v > 0 and v < 1:
        v = clamp(v + (rng.rand(1.0) - 0.5) * float(featherDlg.noise) / 100, 0, 1)
      m[i] = uint8(round(v * 255))
  if L.mask == nil and L.adjust.kind.len == 0: d.addLayerMask(mfRevealAll, d.layers.find(L))
  if L.mask != nil:
    for i in 0 ..< n:
      let old = rOf(L.mask.px[i])
      L.mask.px[i] = grayPx(old * int(m[i]) div 255)
    inc L.mask.ver
  d.markAll()

# ---- Clipping Path (Detect Edges) ----------------------------------------------------------------------------

proc clippingPath(d: Doc) =
  ## Object > Clipping Path: a picture shown only where it is not its background -- the color of its
  ## edges, `threshold` levels away or more --, as a path (Paths: "Clipping Path") and a mask.
  let L = d.current
  if L == nil or L.px.len != d.w * d.h or L.isShape or L.isText: return
  let b = d.layerBox(L)
  if b.w < 2 or b.h < 2: return
  # (the background's color: the mean of its border)
  var acc = [0, 0, 0]
  var cnt = 0
  for x in b.x ..< b.x + b.w:
    for y in [b.y, b.y + b.h - 1]:
      let p = L.px[y * d.w + x]
      acc[0] += rOf(p); acc[1] += gOf(p); acc[2] += bOf(p)
      inc cnt
  let bgc = [acc[0] div max(1, cnt), acc[1] div max(1, cnt), acc[2] div max(1, cnt)]
  var m = newSeq[uint8](d.w * d.h)
  for y in b.y ..< b.y + b.h:
    for x in b.x ..< b.x + b.w:
      let p = L.px[y * d.w + x]
      let diff = max(abs(rOf(p) - bgc[0]), max(abs(gOf(p) - bgc[1]), abs(bOf(p) - bgc[2])))
      var on = aOf(p) > 16 and diff > clipDlg.threshold
      if clipDlg.invert: on = not on
      m[y * d.w + x] = if on: 255 else: 0
  let tr0 = tracedPath(m, d.w, d.h, max(0.5, clipDlg.tolerance.float / 2))
  var p = if clipDlg.inset != 0: offsetPath(tr0, d.w, d.h, -clipDlg.inset.float) else: tr0
  p.name = "Clipping Path"
  d.beginStep("Clipping Path")
  d.touchLayers()
  d.paths.add p
  d.curPath = d.paths.high
  if L.mask == nil: d.addLayerMask(mfRevealAll, d.layers.find(L))
  if L.mask != nil:
    for i in 0 ..< d.w * d.h: L.mask.px[i] = grayPx(int(m[i]))
    inc L.mask.ver
  d.markAll()
  d.endStep()

# ---- Multi-State Objects -------------------------------------------------------------------------------------

proc msoOf(d: Doc): Layer =
  ## (the multi-state object the current layer is, or is in)
  var i = d.cur
  while i >= 0 and i < d.layers.len:
    let L = d.layers[i]
    if L.group and "\"mso\"" in L.meta: return L
    var j = i + 1
    while j < d.layers.len and d.layers[j].depth >= L.depth: inc j
    if j >= d.layers.len: return nil
    i = j

proc msoStates(d: Doc; g: Layer): seq[Layer] =
  let gi = d.layers.find(g)
  for j in d.blockStart(gi) ..< gi:
    if d.layers[j].depth == g.depth + 1: result.add d.layers[j]

proc msoShow(d: Doc; g: Layer; k: int) =
  let ss = d.msoStates(g)
  if ss.len == 0: return
  let kk = ((k mod ss.len) + ss.len) mod ss.len
  for i, L in ss: L.visible = i == kk
  g.meta = $(%*{"mso": {"state": kk}})
  d.markAll()
  status = tr("State ") & $(kk + 1) & tr(" of ") & $ss.len & ": " & ss[kk].name

# ---- Content-Aware Fit ------------------------------------------------------------------------------------------

proc contentAwareFit(d: Doc) =
  ## Object > Fitting > Content-Aware Fit: the picture made to fill its frame, the part with the
  ## most going on in it -- the subject -- in the middle of the frame.
  let (frame, content) = frameAndContent(d)
  if frame == nil or content == nil:
    status = tr("Content-Aware Fit: pick a frame with a picture in it")
    return
  runCommand("Fill Frame Proportionally")
  let fb = d.objectBox(frame)
  let cb = d.layerBox(content)
  if not fb.ok or cb.w <= 0: return
  # (where the detail is: the gradient's weight, its middle)
  var sx, sy, sw = 0.0
  for y in countup(cb.y + 1, cb.y + cb.h - 2, 2):
    for x in countup(cb.x + 1, cb.x + cb.w - 2, 2):
      let i = y * d.w + x
      let g = abs(lumaOf(content.px[i + 1]) - lumaOf(content.px[i - 1])) +
              abs(lumaOf(content.px[i + d.w]) - lumaOf(content.px[i - d.w]))
      let w = float(g * g)
      sx += float(x) * w
      sy += float(y) * w
      sw += w
  if sw <= 0: return
  let mx = sx / sw
  let my = sy / sw
  var dx = int(round((fb.x0 + fb.x1) / 2 - mx))
  var dy = int(round((fb.y0 + fb.y1) / 2 - my))
  # (the frame kept full: no further than the picture reaches)
  dx = clamp(dx, int(ceil(fb.x1)) - (cb.x + cb.w), int(floor(fb.x0)) - cb.x)
  dy = clamp(dy, int(ceil(fb.y1)) - (cb.y + cb.h), int(floor(fb.y0)) - cb.y)
  if dx != 0 or dy != 0:
    d.beginStep("Content-Aware Fit")
    d.touchLayers()
    d.shiftLayers(@[content], dx, dy)
    d.endStep()

# ---- Stroke Styles ----------------------------------------------------------------------------------------------

const strokeStyles: array[10, tuple[name: string; dashes: seq[float]; double: bool]] = [
  ("Solid", @[], false), ("Dashed", @[4.0, 2], false), ("Dashed (3 and 2)", @[3.0, 2], false),
  ("Dashed (4 and 4)", @[4.0, 4], false), ("Dotted", @[0.01, 2], false), ("Japanese Dots", @[0.01, 1.6], false),
  ("Dash Dot", @[4.0, 2, 0.01, 2], false), ("Long Dash", @[8.0, 3], false), ("Thick - Thin", @[], true),
  ("Thin - Thin", @[], true)]

proc applyStrokeStyle(d: Doc; k: int) =
  ## (the shapes picked stroked in one of the layout program's stroke styles: dashes, dots, or two
  ## lines -- a thick and a thin, two thin)
  let ss = d.pickedShapes
  if ss.len == 0: return
  let st = strokeStyles[clamp(k, 0, strokeStyles.high)]
  d.beginStep("Stroke Style")
  d.touchLayers()
  for L in ss:
    var s = L.shape
    if s.stroke.kind == spNone: s.stroke = solidPaint(fg or 0xFF000000'u32)
    s.dashes = st.dashes
    if st.dashes.len > 0 and st.dashes[0] < 0.1: s.cap = lcRound
    s.appearance = @[]
    if st.double:
      # (two lines: the stroke, a gap of the paper's color down its middle)
      let thin = st.name == "Thin - Thin"
      s.appearance.add Appearance(kind: apStroke, paint: solidPaint(0xFFFFFFFF'u32),
                                  width: s.strokeWidth * (if thin: 0.34 else: 0.25), align: (if thin: saCenter else: saInside))
    d.setShape(L, s)
  d.endStep()

# ---- Accessibility Check ---------------------------------------------------------------------------------------

proc checkDocument(d: Doc) =
  ## Window > Accessibility Check: what a reader may have trouble with -- text too small or
  ## too faint on what is under it, a picture with no words for those who cannot see it, text that
  ## does not fit its box, a font that is not here, a picture of too few pixels for print, an empty
  ## frame, words not in the dictionary.
  checkDlg.issues = @[]
  d.updateComposite()
  let comp = d.compPtr
  let fonts = fontFamilies()
  for L in d.layers:
    if not L.visible: continue
    if L.isText:
      let t = L.text
      var small = false
      var missing = ""
      for sp in t.spans:
        if sp.style.size > 0 and sp.style.size / float32(max(1.0, d.dpi)) * 72 < 7: small = true
        if sp.style.family.len > 0 and sp.style.family notin fonts and missing.len == 0: missing = sp.style.family
      if small: checkDlg.issues.add (L, tr("Text smaller than 7 points"))
      if missing.len > 0: checkDlg.issues.add (L, tr("A font that is not here: ") & missing)
      if t.boxW > 0 and layoutText(t).overflow >= 0: checkDlg.issues.add (L, tr("Overset text: it does not all fit"))
      if t.plainText.strip.len == 0: checkDlg.issues.add (L, tr("An empty text frame"))
      # (contrast: its color against what is under its middle -- WCAG asks 4.5 to 1)
      let b = d.layerBox(L)
      if b.w > 0 and t.spans.len > 0:
        let cx = clamp(b.x + b.w div 2, 0, d.w - 1)
        let cy = clamp(b.y + b.h div 2, 0, d.h - 1)
        var under = 0xFFFFFFFF'u32
        let i = d.layers.find(L)
        if i > 0:
          var buf = newSeq[uint32](d.w * d.h)
          d.compositeInto(buf, rect(cx, cy, 1, 1), d.layers[0 ..< i])
          under = buf[cy * d.w + cx]
        proc lum(p: uint32): float =
          proc ch(v: int): float =
            let c = v / 255
            if c <= 0.03928: c / 12.92 else: pow((c + 0.055) / 1.055, 2.4)
          0.2126 * ch(rOf(p)) + 0.7152 * ch(gOf(p)) + 0.0722 * ch(bOf(p))
        let l1 = lum(t.spans[0].style.color)
        let l2 = lum(under)
        let ratio = (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
        if ratio < 4.5:
          checkDlg.issues.add (L, tr("Low contrast: ") & formatFloat(ratio, ffDecimal, 1) & tr(" to 1 (4.5 wanted)"))
    elif L.isSmart or (L.px.len == d.w * d.h and not L.isShape and not L.group and L.adjust.kind.len == 0 and
                       not L.background):
      if L.attrs.alt.len == 0 and L.isSmart:
        checkDlg.issues.add (L, tr("A picture with no alternative text (Object Export Options)"))
      if L.isSmart:
        let b = d.layerBox(L)
        if b.w > 0 and L.smart.w > 0:
          let ppi = float(L.smart.w) / (float(b.w) / max(1.0, d.dpi))
          if ppi < 150: checkDlg.issues.add (L, tr("Too few pixels for print: ") & $int(ppi) & " ppi")
    elif L.attrs.placeholder != 0:
      let i = d.layers.find(L)
      if i + 1 >= d.layers.len or not d.layers[i + 1].clipped:
        checkDlg.issues.add (L, tr("An empty picture frame"))
  discard comp
  # (the words the spelling check does not know)
  for L in d.layers:
    if L.isText and L.visible:
      let bad = misspelled(L.text)
      if bad.len > 0:
        var ws: seq[string]
        for b in bad[0 ..< min(5, bad.len)]: ws.add b.word
        checkDlg.issues.add (L, tr("Spelling: ") & ws.join(", "))
  if d.info.title.len == 0: checkDlg.issues.add (nil, tr("The document has no title (File > File Info)"))
  checkDlg.sel = -1
  checkDlg.open = true

# ---- Sidenotes, Merge Document, Snippets ------------------------------------------------------------------------

proc insertSidenote(d: Doc) =
  ## Type > Insert Sidenote: a note in the margin beside the line the caret is on (or the type layer's
  ## top), smaller, anchored to the text -- it moves with that line as the text flows.
  let T = d.current
  if T == nil or not T.isText:
    status = tr("Insert Sidenote: pick a type layer")
    return
  let b = d.layerBox(T)
  let w = max(60, min(d.w - (b.x + b.w) - 16, 180))
  let atRight = b.x + b.w + 16 + w <= d.w
  let x = if atRight: b.x + b.w + 16 else: max(0, b.x - 16 - w)
  d.beginStep("Insert Sidenote")
  d.touchLayers()
  var st = if T.text.spans.len > 0: T.text.spans[0].style else: typingStyle()
  st.size = max(6'f32, st.size * 0.72)
  var t = newText(tr("Sidenote"), st)
  t.x = float32(x)
  t.y = float32(b.y)
  t.boxW = float32(w)
  t.boxH = float32(max(40, int(st.size * 6)))
  let N = d.addTextLayer(t)
  N.name = tr("Sidenote")
  discard d.anchorToText(N, T)
  d.cur = d.layers.find(N)
  d.endStep()

proc mergeDocument(d: Doc; path: string) =
  ## File > Merge Document: another document's layers put into this one, in a group named after it.
  let o = try: loadRpd(path) except CatchableError: nil
  if o == nil:
    status = tr("Could not read ") & path.extractFilename
    return
  d.beginStep("Merge Document")
  d.touchLayers()
  var made: seq[int]
  for L in o.layers:
    if L.background: continue
    var C = layerCopy(L, L.name)
    if C.px.len != d.w * d.h and not C.isShape and not C.isText and not C.group:
      # (pixels of another size: placed at the top left, cut to this canvas)
      var px = newSeq[uint32](d.w * d.h)
      for y in 0 ..< min(d.h, o.h):
        for x in 0 ..< min(d.w, o.w): px[y * d.w + x] = L.px[y * o.w + x]
      C.px = px
    d.layers.insert(C, d.layers.len)
    made.add d.layers.high
    if C.isShape: d.setShape(C, C.shape)
    elif C.isText: d.drawText(C)
  if made.len > 0: discard d.groupLayers(made, path.splitFile.name)
  d.markAll()
  d.endStep()
  status = tr("Merge Document: ") & $made.len & tr(" layers from ") & path.extractFilename

var snippetPick = false
var snippetPath = ""
var mergePick = false
var mergePath = ""
var snippetMode = 0                  ## 0 export, 1 place

proc exportSnippet(d: Doc; path: string) =
  ## File > Export > Snippet: the layers picked as a document of their own (.rpd) to place in another.
  let o = newDoc(d.w, d.h, 0'u32, d.dpi, path.splitFile.name)
  o.layers.setLen(0)
  for L in d.layoutTargets: o.layers.add layerCopy(L, L.name)
  if o.layers.len == 0: return
  try:
    o.saveRpd(path)
    status = tr("Snippet saved: ") & path.extractFilename
  except CatchableError:
    status = tr("Could not save ") & path.extractFilename

# ---- the dialogs and the commands --------------------------------------------------------------------------------

proc layoutExtraDialogs() =
  let d = cur()
  if guidesDlg.open:
    var go = false
    dialog(guidesDlg.open, "Create Guides", 340):
      row([110, -1]):
        label "Rows:"
        spin(guidesDlg.rows, 1, 100, w = dp(70))
      row([110, -1]):
        label "Row Gutter:"
        if d != nil: discard d.lengthField(guidesDlg.rowGutter, dp(80))
      row([110, -1]):
        label "Columns:"
        spin(guidesDlg.cols, 1, 100, w = dp(70))
      row([110, -1]):
        label "Column Gutter:"
        if d != nil: discard d.lengthField(guidesDlg.colGutter, dp(80))
      label("Fit Guides to:", bold = true)
      var k = if guidesDlg.fitMargins: 0 else: 1
      if radio("Margins", k, 0): guidesDlg.fitMargins = true
      if radio("Page", k, 1): guidesDlg.fitMargins = false
      checkbox("Remove Existing Ruler Guides", guidesDlg.removeOld)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)): go = true
        if button("Cancel", w = dp(80)): guidesDlg.open = false
    if go and d != nil:
      guidesDlg.open = false
      d.createGuides()
  if adjustDlg.open:
    var go = false
    dialog(adjustDlg.open, if adjustDlg.alternate: "Create Alternate Layout" else: "Adjust Layout", 360):
      if adjustDlg.alternate:
        paragraph("A copy of this document in another size -- for a phone, a tablet, a poster -- what is on it " &
                  "following the rule.", color = ui.theme.gray)
      row([110, -1]):
        label "Width:"
        spin(adjustDlg.w, 1, 30000, w = dp(80))
      row([110, -1]):
        label "Height:"
        spin(adjustDlg.h, 1, 30000, w = dp(80))
      row:
        for (n, w, h) in [("Phone", 1080, 1920), ("Tablet", 1536, 2048), ("A4", 2480, 3508), ("Wide", 1920, 1080)]:
          if button(n, w = dp(70)):
            adjustDlg.w = w
            adjustDlg.h = h
      label("Liquid Layout Rule:", bold = true)
      radio("Scale (everything grows or shrinks with the page)", adjustDlg.rule, 0)
      radio("Re-center (everything keeps its size, round the middle)", adjustDlg.rule, 1)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)): go = true
        if button("Cancel", w = dp(80)): adjustDlg.open = false
    if go and d != nil:
      adjustDlg.open = false
      if adjustDlg.alternate:
        # (a copy through the document's own file format: everything it has)
        let tmp = getTempDir() / ("atelier-alt-" & $getCurrentProcessId() & ".rpd")
        var c: Doc = nil
        try:
          d.saveRpd(tmp)
          c = loadRpd(tmp)
        except CatchableError: c = nil
        try: removeFile(tmp) except OSError: discard
        if c != nil:
          c.name = d.name & " " & $adjustDlg.w & "x" & $adjustDlg.h
          c.path = ""
          c.adjustLayout(adjustDlg.w, adjustDlg.h, adjustDlg.rule)
          addDoc(c)
      else: d.adjustLayout(adjustDlg.w, adjustDlg.h, adjustDlg.rule)
  if quickDlg.open and d != nil:
    var names: seq[(string, string)]           # (shown, what it is)
    for s in d.paraStyles: names.add (s.name & "  (" & tr("paragraph style") & ")", "p:" & s.name)
    for s in d.charStyles: names.add (s.name & "  (" & tr("character style") & ")", "c:" & s.name)
    for s in stylePresets(): names.add (s.name & "  (" & tr("layer style") & ")", "l:" & s.name)
    var shown: seq[string]
    var keys: seq[string]
    for (n, k) in names:
      if quickDlg.find.len == 0 or n.toLowerAscii.contains(quickDlg.find.toLowerAscii):
        shown.add n
        keys.add k
    var go = false
    dialog(quickDlg.open, "Quick Apply", 380):
      if edit(quickDlg.find, w = dp(340)): quickDlg.sel = 0
      quickDlg.sel = clamp(quickDlg.sel, -1, shown.high)
      if listbox(shown, quickDlg.sel, rows = 10, w = dp(340)) and doubleClicked(): go = true
      row:
        spring()
        if button("Apply", isDefault = true, w = dp(80), enabled = quickDlg.sel >= 0): go = true
        if button("Cancel", w = dp(80)): quickDlg.open = false
    if go and quickDlg.sel in 0 .. keys.high:
      quickDlg.open = false
      let k = keys[quickDlg.sel]
      let L = d.current
      d.beginStep("Quick Apply")
      d.touchLayers()
      case k[0]
      of 'p':
        if L.isText: d.applyParaStyle(L, k[2 .. ^1])
      of 'c':
        if L.isText: d.applyCharStyle(L, 0, L.text.plainText.runeLen, k[2 .. ^1])
      else:
        for s in stylePresets():
          if s.name == k[2 .. ^1]: L.fx = s.fx
        inc L.ver
      d.markAll()
      d.endStep()
  if htmlDlg.open:
    var go = false
    dialog(htmlDlg.open, "Insert HTML", 460):
      paragraph("HTML to embed -- a video, a map, a form: kept with a frame on the page, put in the page's HTML " &
                "and EPUB as it is.", color = ui.theme.gray)
      editArea(htmlDlg.code, lines = 8)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)): go = true
        if button("Cancel", w = dp(80)): htmlDlg.open = false
    if go and d != nil:
      htmlDlg.open = false
      d.insertHtml()
  if featherDlg.open:
    var go = false
    dialog(featherDlg.open, if featherDlg.directional: "Directional Feather" else: "Basic Feather", 340):
      if featherDlg.directional:
        for (k, n) in [(0, "Top:"), (1, "Bottom:"), (2, "Left:"), (3, "Right:")]:
          optSlider(n, featherDlg.sides[k], 0, 500, " px")
      else:
        optSlider("Feather Width:", featherDlg.width, 1, 500, " px")
        optSlider("Choke:", featherDlg.choke, 0, 100)
        row([110, -1]):
          label "Corners:"
          combo(["Sharp", "Rounded", "Diffused"], featherDlg.corners, w = dp(120))
      optSlider("Noise:", featherDlg.noise, 0, 100)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)): go = true
        if button("Cancel", w = dp(80)): featherDlg.open = false
    if go and d != nil:
      featherDlg.open = false
      let L = d.current
      if L != nil and not L.background:
        d.beginStep(if featherDlg.directional: "Directional Feather" else: "Basic Feather")
        d.touchLayers()
        d.featherMask(L)
        d.endStep()
  if clipDlg.open:
    var go = false
    dialog(clipDlg.open, "Clipping Path", 340):
      label("Type: Detect Edges", bold = true)
      optSlider("Threshold:", clipDlg.threshold, 0, 255, "")
      optSlider("Tolerance:", clipDlg.tolerance, 0, 10, "")
      optSlider("Inset Frame:", clipDlg.inset, -50, 50, " px")
      checkbox("Invert", clipDlg.invert)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)): go = true
        if button("Cancel", w = dp(80)): clipDlg.open = false
    if go and d != nil:
      clipDlg.open = false
      d.clippingPath()
  if checkDlg.open and d != nil:
    dialog(checkDlg.open, "Accessibility Check", 520):
      if checkDlg.issues.len == 0:
        paragraph("No issues found.", color = ui.theme.gray)
      else:
        var shown: seq[string]
        for (L, w) in checkDlg.issues: shown.add (if L != nil: L.name & ": " else: "") & w
        if listbox(shown, checkDlg.sel, rows = 12, w = dp(480)):
          let L = checkDlg.issues[clamp(checkDlg.sel, 0, checkDlg.issues.high)].layer
          if L != nil and L in d.layers:
            d.clearPicks()
            d.cur = d.layers.find(L)
            inc d.ver
      row:
        label($checkDlg.issues.len & tr(" issues"), color = ui.theme.gray)
        spring()
        if button("Check Again", w = dp(110)): d.checkDocument()
        if button("Close", w = dp(80)): checkDlg.open = false
  if articlesDlg.open and d != nil:
    var list = articles.getOrDefault(cast[pointer](d))
    var shown: seq[string]
    for u in list:
      let L = d.layerOfUid(u)
      shown.add (if L != nil: L.name else: tr("(gone)"))
    dialog(articlesDlg.open, "Articles", 420):
      paragraph("The reading order of what is on the page -- for EPUB, a reflowed page, a screen reader.",
                color = ui.theme.gray)
      discard listbox(shown, articlesDlg.sel, rows = 10, w = dp(380))
      row:
        if button("Add Picked", w = dp(100)):
          for L in d.layoutTargets:
            let u = uidOf(L)
            if u notin list: list.add u
        if button("Up", w = dp(50), enabled = articlesDlg.sel > 0):
          swap(list[articlesDlg.sel], list[articlesDlg.sel - 1])
          dec articlesDlg.sel
        if button("Down", w = dp(60), enabled = articlesDlg.sel in 0 ..< list.high):
          swap(list[articlesDlg.sel], list[articlesDlg.sel + 1])
          inc articlesDlg.sel
        if button("Remove", w = dp(70), enabled = articlesDlg.sel in 0 .. list.high):
          list.delete(articlesDlg.sel)
          articlesDlg.sel = min(articlesDlg.sel, list.high)
      row:
        if button("Export as Text...", w = dp(130), enabled = list.len > 0):
          var txt = ""
          for u in list:
            let L = d.layerOfUid(u)
            if L != nil and L.isText: txt.add L.text.plainText & "\n\n"
            elif L != nil and L.attrs.alt.len > 0: txt.add "[" & L.attrs.alt & "]\n\n"
          let p = (if d.path.len > 0: d.path.parentDir else: picturesDir()) / (d.name & " articles.txt")
          try:
            writeFile(p, txt)
            status = tr("Saved ") & p
          except IOError: status = tr("Could not save ") & p
        spring()
        if button("Close", w = dp(80)): articlesDlg.open = false
    articles[cast[pointer](d)] = list
  if strokeStyleDlg.open and d != nil:
    var names: seq[string]
    for s in strokeStyles: names.add s.name
    var go = false
    dialog(strokeStyleDlg.open, "Stroke Styles", 300):
      discard listbox(names, strokeStyleDlg.pick, rows = strokeStyles.len, w = dp(260))
      row:
        spring()
        if button("Apply", isDefault = true, w = dp(80)): go = true
        if button("Cancel", w = dp(80)): strokeStyleDlg.open = false
    if go:
      strokeStyleDlg.open = false
      d.applyStrokeStyle(strokeStyleDlg.pick)
  if filePicker(snippetPick, snippetPath, (if snippetMode == 0: fmSave else: fmOpen), ["*.rpd"],
                if snippetMode == 0: "Export Snippet" else: "Place Snippet"):
    if d != nil:
      if snippetMode == 0: d.exportSnippet(if snippetPath.endsWith(".rpd"): snippetPath else: snippetPath & ".rpd")
      else: d.mergeDocument(snippetPath)
  if filePicker(mergePick, mergePath, fmOpen, ["*.rpd"], "Merge Document"):
    if d != nil: d.mergeDocument(mergePath)

proc flattenerOverlay(dw: DocWin) =
  ## (View > Flattener Preview: what will be flattened when printed or saved as PDF/X-1a -- a layer
  ## less than opaque, in another blend mode, with effects -- shaded red)
  if not flattenerPreview: return
  let d = dw.doc
  for L in d.layers:
    if not L.visible or L.group or L.background: continue
    if L.opacity < 100 or L.mode != bmNormal or L.hasFx or L.fill < 100:
      let b = d.layerBox(L)
      if b.w <= 0: continue
      let (x0, y0) = dw.view.toScreen(d, b.x.float, b.y.float)
      let (x1, y1) = dw.view.toScreen(d, float(b.x + b.w), float(b.y + b.h))
      fill(rect(x0, y0, max(1, x1 - x0), max(1, y1 - y0)), color(230, 30, 30, 70))

proc layoutExtraCommand(name: string): bool =
  let d = cur()
  result = true
  if name.startsWith("Stroke Style: "):
    if d != nil:
      let n = name["Stroke Style: ".len .. ^1]
      for k, s in strokeStyles:
        if s.name == n: d.applyStrokeStyle(k)
    return
  case name
  of "Create Guides...": guidesDlg.open = true
  of "Adjust Layout...", "Create Alternate Layout...":
    if d != nil: adjustDlg = (true, d.w, d.h, adjustDlg.rule, name.startsWith("Create"))
  of "Auto Style": (if d != nil: d.autoStyle())
  of "Quick Apply...":
    quickDlg.open = true
    quickDlg.find = ""
    quickDlg.sel = 0
  of "Insert HTML...": htmlDlg.open = true
  of "Basic Feather...":
    featherDlg.open = true
    featherDlg.directional = false
  of "Directional Feather...":
    featherDlg.open = true
    featherDlg.directional = true
  of "Clipping Path...": clipDlg.open = true
  of "Convert to Multi-State Object":
    if d != nil:
      var idx = d.pickedLayers
      if idx.len < 2:
        status = tr("Multi-State Object: pick two layers or more -- each becomes a state")
        return
      d.beginStep("Convert to Multi-State Object")
      d.touchLayers()
      let g = d.groupLayers(idx, "Multi-State")
      if g != nil: d.msoShow(g, 0)
      d.endStep()
  of "Next State", "Previous State":
    if d != nil:
      let g = d.msoOf
      if g != nil:
        var k = 0
        try: k = parseJson(g.meta){"mso"}{"state"}.getInt(0)
        except CatchableError: discard
        d.beginStep(name)
        d.touchLayers()
        d.msoShow(g, k + (if name == "Next State": 1 else: -1))
        d.endStep()
      else: status = tr("Pick a multi-state object")
  of "Content-Aware Fit": (if d != nil: d.contentAwareFit())
  of "Stroke Styles...": strokeStyleDlg.open = true
  of "Flattener Preview":
    flattenerPreview = not flattenerPreview
    if d != nil: d.markAll()
  of "Articles...": articlesDlg.open = true
  of "Accessibility Check...": (if d != nil: d.checkDocument())
  of "Insert Sidenote": (if d != nil: d.insertSidenote())
  of "Merge Document...": mergePick = true
  of "Export Snippet...":
    snippetMode = 0
    snippetPick = true
  of "Place Snippet...":
    snippetMode = 1
    snippetPick = true
  else: result = false
