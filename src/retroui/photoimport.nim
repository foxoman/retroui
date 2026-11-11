## PDF, Illustrator (.ai), PostScript and EPS files as Retro Photo
## documents, and PostScript and EPS written from them.
##
## Opening a PDF or an .ai page draws it at the resolution asked (as
## Photoshop's Import PDF does), onto a transparent layer -- or, for an
## Illustrator drawing, keeps its outlines as shape layers (sharp,
## editable) with its text and pictures on a layer above. An EPS gives its
## picture: a Photoshop or Retro Photo EPS's own pixels (%ImageData), else
## the TIFF preview it carries; a PostScript file Retro Photo wrote, its
## picture too. `savePs` writes Level 2 PostScript (or an EPS): the image
## at the document's resolution, in RGB or the printing inks, with type and
## shapes as outlines over it. `retroui/photofiles`' `openPicture` opens these
## files through it.
##
## ```nim
## let d = importPdf(readFile("flyer.pdf"), "flyer",
##                   ImportOptions(page: 0, ppi: 150, shapes: true))
## d.savePs("flyer.eps", eps = true)
## ```

import std/[os, strutils, math]
import gfx, photo, photoshapes, photoinks, pdfread, textengine, imageformats

type
  ImportOptions* = object
    ## How a PDF or an .ai page becomes a document.
    page*: int               ## which page (0: the first)
    ppi*: float              ## pixels an inch (0: 300)
    shapes*: bool            ## its outlines as shape layers (an Illustrator drawing), when they are
                             ## not too many
    maxShapes*: int          ## ... at most so many layers of them (0: 48)

proc pathOf(subs: seq[seq[tuple[op: char; x1, y1, x2, y2, x3, y3: float]]]): Path =
  for sub in subs:
    var sp = SubPath(op: poAdd)
    for o in sub:
      case o.op
      of 'm': sp.pts.add PathPoint(p: (o.x1, o.y1), inH: (o.x1, o.y1), outH: (o.x1, o.y1))
      of 'l': sp.pts.add PathPoint(p: (o.x1, o.y1), inH: (o.x1, o.y1), outH: (o.x1, o.y1))
      of 'c':
        if sp.pts.len > 0: sp.pts[^1].outH = (o.x1, o.y1)
        sp.pts.add PathPoint(p: (o.x3, o.y3), inH: (o.x2, o.y2), outH: (o.x3, o.y3))
      of 'h': sp.closed = true
      else: discard
    # (closed back onto its first point: the two made one)
    if sp.closed and sp.pts.len > 2 and abs(sp.pts[^1].p[0] - sp.pts[0].p[0]) < 1e-6 and
       abs(sp.pts[^1].p[1] - sp.pts[0].p[1]) < 1e-6:
      sp.pts[0].inH = sp.pts[^1].inH
      sp.pts.setLen(sp.pts.len - 1)
    if sp.pts.len > 0: result.subs.add sp

proc importPdf*(data: string; name: string; o = ImportOptions()): Doc =
  ## A page of a PDF (or an .ai) as a document. Raises `IOError`.
  let f = try: openPdf(data)
          except PdfError as e: raise newException(IOError, e.msg)
  let page = clamp(o.page, 0, f.pageCount - 1)
  let ppi = if o.ppi > 0: o.ppi else: 300.0
  let (pw, ph) = f.pageSize(page)
  let w = max(1, int(ceil(pw * ppi / 72)))
  let h = max(1, int(ceil(ph * ppi / 72)))
  if not sizeOk(w, h): raise newException(IOError, "too big at that resolution")
  result = newDoc(w, h, 0'u32, dpi = ppi, name = name)
  result.layers[0].background = false
  result.layers[0].name = "Layer 1"
  var shapesDone = false
  if o.shapes:
    let vs = f.pageVectors(page, ppi)
    # (paths painted alike, one after another: one shape layer)
    var groups: seq[seq[PdfVector]]
    for v in vs:
      if groups.len > 0 and groups[^1][0].fill == v.fill and groups[^1][0].stroke == v.stroke and
         abs(groups[^1][0].width - v.width) < 0.01 and groups[^1][0].evenOdd == v.evenOdd:
        groups[^1].add v
      else: groups.add @[v]
    let most = if o.maxShapes > 0: o.maxShapes else: 48
    if groups.len > 0 and groups.len <= most:
      shapesDone = true
      result.layers.setLen(0)
      for gi, g in groups:
        var s = ShapeData(kind: "")
        for v in g:
          let pth = pathOf(v.subs)
          for sp in pth.subs: s.path.subs.add sp
        let v = g[0]
        if (v.fill shr 24) != 0:
          s.fill = ShapePaint(kind: spColor, color: v.fill or 0xFF000000'u32,
                              opacity: max(1, int(round((v.fill shr 24).float / 255 * 100))))
        if (v.stroke shr 24) != 0 and v.width > 0:
          s.stroke = ShapePaint(kind: spColor, color: v.stroke or 0xFF000000'u32,
                                opacity: max(1, int(round((v.stroke shr 24).float / 255 * 100))))
          s.strokeWidth = v.width
          s.align = saCenter
        discard result.addShapeLayer(s, "Shape " & $(gi + 1))
      # the text and the pictures, on a layer above
      let rest = f.renderPage(page, ppi, background = 0, maxPixels = high(int), paths = false)
      var any = false
      for p in rest.px:
        if (p shr 24) != 0:
          any = true
          break
      if any:
        let L = result.addLayer("Text and Pictures")
        if rest.w == w and rest.h == h: L.px = rest.px
        inc L.ver
  if not shapesDone:
    let b = f.renderPage(page, ppi, background = 0, maxPixels = high(int))
    if b.w == w and b.h == h: result.layers[0].px = b.px
    else:
      for y in 0 ..< min(h, b.h):
        for x in 0 ..< min(w, b.w): result.layers[0].px[y * w + x] = b.px[y * b.w + x]
    inc result.layers[0].ver
  result.cur = result.layers.high
  result.markAll()
  result.modified = false

proc pdfPages*(data: string): seq[tuple[w, h: float]] =
  ## The pages of a PDF (their sizes in points), for an import dialog; empty
  ## when it is not one.
  try:
    let f = openPdf(data)
    for i in 0 ..< f.pageCount: result.add f.pageSize(i)
  except PdfError: discard

# ---- PostScript and EPS, written -----------------------------------------------------------------------

proc a85(data: string): string =
  ## ASCII85, in lines (PostScript's ~> ended).
  var col = 0
  var i = 0
  while i < data.len:
    let n = min(4, data.len - i)
    var v = 0'u32
    for k in 0 ..< 4: v = (v shl 8) or (if k < n: uint32(ord(data[i + k])) else: 0'u32)
    if v == 0 and n == 4:
      result.add 'z'
      inc col
    else:
      var c: array[5, char]
      var t = v
      for k in countdown(4, 0):
        c[k] = char(int(t mod 85) + 33)
        t = t div 85
      for k in 0 .. n:
        result.add c[k]
        inc col
    if col >= 72:
      result.add '\n'
      col = 0
    i += 4
  result.add "~>\n"

proc savePs*(d: Doc; path: string; eps = false; cmyk = false; vectors = true) =
  ## The document as PostScript (Level 2; `eps`: an EPS, to place in other
  ## programs): the picture at its size and resolution, in RGB (or the
  ## printing inks), type and shapes as outlines over it. Retro Photo (and
  ## Photoshop) read its picture back (%ImageData).
  let dpi = if d.dpi > 0: d.dpi else: 72.0
  let k = 72 / dpi
  let pw = d.w.float * k
  let ph = d.h.float * k
  # (type and shapes above everything else drawn as outlines; the rest a picture)
  var vectorLayers: seq[Layer]
  if vectors:
    var top = d.layers.len
    while top > 0:
      let L = d.layers[top - 1]
      if L.visible and (L.isText or (L.isShape and L.shape.fill.kind in {spNone, spColor} and
         L.shape.stroke.kind in {spNone, spColor})) and L.mode == bmNormal and not L.hasStyle and
         L.depth == 0 and not L.clipped and (L.mask == nil or L.maskOff):
        vectorLayers.insert(L, 0)
        dec top
      else: break
  var hidden: seq[Layer]
  for L in vectorLayers:
    if L.visible:
      L.visible = false
      hidden.add L
  d.markAll()
  d.updateComposite()
  let comp = d.compCopy
  for L in hidden: L.visible = true
  d.markAll()
  d.updateComposite()
  var o = newStringOfCap(d.w * d.h * 4)
  o.add(if eps: "%!PS-Adobe-3.0 EPSF-3.0\n" else: "%!PS-Adobe-3.0\n")
  o.add "%%Creator: Retro Photo\n%%Title: " & d.name & "\n"
  o.add "%%BoundingBox: 0 0 " & $int(ceil(pw)) & " " & $int(ceil(ph)) & "\n"
  o.add "%%HiResBoundingBox: 0 0 " & formatFloat(pw, ffDecimal, 3) & " " & formatFloat(ph, ffDecimal, 3) & "\n"
  o.add "%%LanguageLevel: 2\n%%Pages: 1\n%%EndComments\n"
  if not eps: o.add "%%Page: 1 1\n<< /PageSize [" & formatFloat(pw, ffDecimal, 3) & " " &
                    formatFloat(ph, ffDecimal, 3) & "] >> setpagedevice\n"
  o.add "gsave\n"
  # the picture: white under its transparency (PostScript has none)
  let n = if cmyk: 4 else: 3
  var raw = newStringOfCap(d.w * d.h * n)
  for p in comp:
    let c = blendPx(0xFFFFFFFF'u32, p, 255, bmNormal)
    if cmyk:
      let ink = inkOf(c)
      for i in 0 .. 3: raw.add char(ink[i])
    else:
      raw.add char((c shr 16) and 255)
      raw.add char((c shr 8) and 255)
      raw.add char(c and 255)
  o.add "%ImageData: " & $d.w & " " & $d.h & " 8 " & $n & " 0 1 2 \"beginimage\"\n"
  o.add formatFloat(pw, ffDecimal, 4) & " " & formatFloat(ph, ffDecimal, 4) & " scale\n"
  o.add(if cmyk: "/DeviceCMYK setcolorspace\n" else: "/DeviceRGB setcolorspace\n")
  o.add "<< /ImageType 1 /Width " & $d.w & " /Height " & $d.h & " /BitsPerComponent 8 /Decode [" &
        (if cmyk: "0 1 0 1 0 1 0 1" else: "0 1 0 1 0 1") & "] /ImageMatrix [" & $d.w & " 0 0 -" & $d.h &
        " 0 " & $d.h & "] /DataSource currentfile /ASCII85Decode filter /RunLengthDecode filter >>\n"
  o.add "%%BeginData: beginimage\nimage\n"
  # (run-length coded, then ASCII85)
  var rl = newStringOfCap(raw.len)
  var i = 0
  while i < raw.len:
    var j = i + 1
    while j < raw.len and j - i < 128 and raw[j] == raw[i]: inc j
    if j - i >= 3:
      rl.add char(257 - (j - i))
      rl.add raw[i]
      i = j
    else:
      var e = i
      while e < raw.len and e - i < 128 and not (e + 2 < raw.len and raw[e] == raw[e + 1] and raw[e] == raw[e + 2]):
        inc e
      if e == i: e = i + 1
      rl.add char(e - i - 1)
      rl.add raw[i ..< e]
      i = e
  rl.add char(128)
  o.add a85(rl)
  o.add "%%EndData\ngrestore\n"
  # type and shapes: outlines (points from the bottom left)
  proc pt(x, y: float): string = formatFloat(x * k, ffDecimal, 3) & " " & formatFloat(ph - y * k, ffDecimal, 3)
  proc colorOps(c: uint32): string =
    if cmyk:
      let ink = inkOf(c)
      formatFloat(ink[0].float / 255, ffDecimal, 4) & " " & formatFloat(ink[1].float / 255, ffDecimal, 4) & " " &
        formatFloat(ink[2].float / 255, ffDecimal, 4) & " " & formatFloat(ink[3].float / 255, ffDecimal, 4) &
        " setcmykcolor\n"
    else:
      formatFloat(((c shr 16) and 255).float / 255, ffDecimal, 4) & " " &
        formatFloat(((c shr 8) and 255).float / 255, ffDecimal, 4) & " " &
        formatFloat((c and 255).float / 255, ffDecimal, 4) & " setrgbcolor\n"
  for L in vectorLayers:
    o.add "gsave\n"
    if L.isText:
      for t in textOutlines(L.text, layoutText(L.text), fine = true):
        o.add "newpath\n"
        for poly in t.polys:
          if poly.len < 3: continue
          o.add pt(poly[0][0], poly[0][1]) & " moveto\n"
          for q in 1 ..< poly.len: o.add pt(poly[q][0], poly[q][1]) & " lineto\n"
          o.add "closepath\n"
        o.add colorOps(t.color) & "fill\n"
    else:
      let s = L.shape
      let ends = s.endsPath           # (a line's arrowheads: filled, the line cut back under them)
      var pth = ""
      for sp in s.trimmedPath.subs:
        if sp.pts.len == 0: continue
        pth.add pt(sp.pts[0].p[0], sp.pts[0].p[1]) & " moveto\n"
        let nn = sp.pts.len
        for q in 0 ..< (if sp.closed: nn else: nn - 1):
          let a = sp.pts[q]
          let b = sp.pts[(q + 1) mod nn]
          if a.outH == a.p and b.inH == b.p: pth.add pt(b.p[0], b.p[1]) & " lineto\n"
          else: pth.add pt(a.outH[0], a.outH[1]) & " " & pt(b.inH[0], b.inH[1]) & " " & pt(b.p[0], b.p[1]) &
                        " curveto\n"
        if sp.closed: pth.add "closepath\n"
      if s.fill.kind == spColor: o.add "newpath\n" & pth & colorOps(s.fill.color) & "fill\n"
      if s.stroke.kind == spColor and s.strokeWidth > 0:
        o.add "newpath\n" & pth & colorOps(s.stroke.color) & formatFloat(s.strokeWidth * k, ffDecimal, 3) &
              " setlinewidth\nstroke\n"
        if ends.subs.len > 0:
          o.add "newpath\n"
          for sp in ends.subs:
            if sp.pts.len < 3: continue
            o.add pt(sp.pts[0].p[0], sp.pts[0].p[1]) & " moveto\n"
            for q in 1 ..< sp.pts.len: o.add pt(sp.pts[q].p[0], sp.pts[q].p[1]) & " lineto\n"
            o.add "closepath\n"
          o.add colorOps(s.stroke.color) & "fill\n"
    o.add "grestore\n"
  if not eps: o.add "showpage\n"
  o.add "%%Trailer\n%%EOF\n"
  let part = path & ".part"
  writeFile(part, o)
  moveFile(part, path)

# ---- PostScript and EPS, read --------------------------------------------------------------------------

proc importPs*(data: string; name: string): Doc =
  ## The picture of an EPS or PostScript file: its own pixels when Photoshop
  ## or Retro Photo wrote it (%ImageData), else the TIFF preview an EPS
  ## carries. Raises `IOError` when it has neither (drawing PostScript
  ## itself is not done).
  result = nil         # (a value at once: see tools/writecheck.py)
  var ps = data
  var tiff = ""
  if data.len > 30 and data[0 .. 3] == "\xC5\xD0\xD3\xC6":
    # (a DOS EPS: PostScript and a TIFF preview side by side)
    proc le32(at: int): int =
      ord(data[at]) or (ord(data[at + 1]) shl 8) or (ord(data[at + 2]) shl 16) or (ord(data[at + 3]) shl 24)
    let psAt = le32(4)
    let psLen = le32(8)
    let tAt = le32(20)
    let tLen = le32(24)
    if psAt + psLen <= data.len: ps = data[psAt ..< psAt + psLen]
    if tAt > 0 and tLen > 0 and tAt + tLen <= data.len: tiff = data[tAt ..< tAt + tLen]
  let at = ps.find("%ImageData:")
  if at >= 0:
    let line = ps[at + 11 ..< ps.find('\n', at)].strip
    let v = line.split(' ')
    if v.len >= 4:
      let w = try: parseInt(v[0]) except ValueError: 0
      let h = try: parseInt(v[1]) except ValueError: 0
      let bits = try: parseInt(v[2]) except ValueError: 0
      let n = try: parseInt(v[3]) except ValueError: 0
      if w > 0 and h > 0 and bits == 8 and n in [1, 3, 4] and sizeOk(w, h):
        # (our own: ASCII85 + run-length, after "image"; Photoshop's: binary
        # or hex after its "beginimage" line)
        var raw = ""
        let ours = ps.find("/ASCII85Decode filter /RunLengthDecode filter", at)
        let img = ps.find("\nimage\n", at)
        if ours >= 0 and img >= 0:
          var e = ps.find("~>", img)
          if e < 0: e = ps.len
          var acc = 0'u32
          var cnt = 0
          var rl = ""
          for c in ps[img + 7 ..< e]:
            if c in {' ', '\n', '\r', '\t'}: continue
            if c == 'z' and cnt == 0:
              rl.add "\0\0\0\0"
              continue
            acc = acc * 85 + uint32(ord(c) - 33)
            inc cnt
            if cnt == 5:
              for s in countdown(3, 0): rl.add char((acc shr (8 * s)) and 255)
              acc = 0
              cnt = 0
          if cnt > 0:
            for _ in cnt ..< 5: acc = acc * 85 + 84
            for s in 0 ..< cnt - 1: rl.add char((acc shr (8 * (3 - s))) and 255)
          var i = 0
          while i < rl.len:
            let l = ord(rl[i])
            inc i
            if l == 128: break
            if l < 128:
              raw.add rl[i ..< min(rl.len, i + l + 1)]
              i += l + 1
            elif i < rl.len:
              for _ in 0 ..< 257 - l: raw.add rl[i]
              inc i
        else:
          let bi = ps.find("beginimage", at + 11)
          var p = ps.find('\n', if bi >= 0: bi else: at)
          if p >= 0:
            inc p
            let need = w * h * n
            # (binary, or hex)
            var hex = true
            for k in p ..< min(ps.len, p + 64):
              if ps[k] notin {'0' .. '9', 'a' .. 'f', 'A' .. 'F', '\n', '\r', ' '}: hex = false
            if hex:
              var hi = -1
              while p < ps.len and raw.len < need:
                let c = ps[p]
                inc p
                let d = case c
                        of '0' .. '9': ord(c) - ord('0')
                        of 'a' .. 'f': ord(c) - ord('a') + 10
                        of 'A' .. 'F': ord(c) - ord('A') + 10
                        else: -1
                if d < 0: continue
                if hi < 0: hi = d
                else:
                  raw.add char(hi * 16 + d)
                  hi = -1
            else: raw = ps[p ..< min(ps.len, p + need)]
        if raw.len >= w * h * n:
          result = newDoc(w, h, 0xFFFFFFFF'u32, name = name)
          let L = result.layers[0]
          for i in 0 ..< w * h:
            L.px[i] = case n
                      of 1: grayPx(ord(raw[i]))
                      of 3: argb(255, ord(raw[3 * i]), ord(raw[3 * i + 1]), ord(raw[3 * i + 2]))
                      else:
                        # (Photoshop's CMYK EPS keeps the inks inverted)
                        let photoshop = ours < 0
                        var c = [ord(raw[4 * i]), ord(raw[4 * i + 1]), ord(raw[4 * i + 2]), ord(raw[4 * i + 3])]
                        if photoshop:
                          for x in c.mitems: x = 255 - x
                        printed(c[0], c[1], c[2], c[3]) or 0xFF000000'u32
          # (its size: the bounding box)
          let bb = ps.find("%%BoundingBox:")
          if bb >= 0:
            let bv = ps[bb + 14 ..< ps.find('\n', bb)].strip.split(' ')
            if bv.len == 4:
              try:
                let wpt = parseFloat(bv[2]) - parseFloat(bv[0])
                if wpt > 0: result.dpi = w.float / wpt * 72
              except ValueError: discard
          inc L.ver
          result.markAll()
          result.modified = false
          return
  if tiff.len > 0:
    try:
      let b = decodeTiff(tiff)
      if b != nil:
        result = newDoc(b.w, b.h, 0xFFFFFFFF'u32, name = name)
        result.layers[0].px = b.px
        inc result.layers[0].ver
        result.markAll()
        result.modified = false
        return
    except CatchableError: discard
  raise newException(IOError, "this PostScript has no picture Retro Photo can read (only drawing " &
                     "commands, and no preview)")
