## A document as SVG: its shape layers as vector shapes (their paths,
## fills -- colors and linear or radial gradients -- and strokes, with
## dashes, caps and joins), its type layers as text (the text kept, each
## run in its own font, size and color; text on a path along its path: it
## can be edited in a drawing program, and here when the file is opened
## again), and its other layers as pictures; its groups as groups; in
## their order, opacity, blending mode and visibility, under their names.
## File > Save As (an .svg) and File > Export > SVG; `svgLosses` says what
## of a document an SVG does not hold.
##
## ```nim
## writeFile("logo.svg", d.svgOf())
## ```

import std/[strutils, math, base64]
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)
import gfx, photo, photoshapes, textengine, imaging

proc hexColor(c: uint32): string = "#" & toHex(int(c and 0xFFFFFF), 6).toLowerAscii

proc num(v: float): string =
  ## (a number as SVG writes it: short)
  let r = round(v * 100) / 100
  if r == floor(r): $int(r) else: formatFloat(r, ffDecimal, 2).strip(leading = false, chars = {'0'})

proc xmlText(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"))

proc pathData*(p: Path): string =
  ## A path's outline as SVG path data (cubic Béziers).
  for sp in p.subs:
    if sp.pts.len == 0: continue
    let p0 = sp.pts[0]
    result.add "M" & num(p0.p[0]) & " " & num(p0.p[1])
    for i in 1 .. sp.pts.high + (if sp.closed: 1 else: 0):
      let a = sp.pts[(i - 1) mod sp.pts.len]
      let b = sp.pts[i mod sp.pts.len]
      if a.outH == a.p and b.inH == b.p:
        result.add "L" & num(b.p[0]) & " " & num(b.p[1])
      else:
        result.add "C" & num(a.outH[0]) & " " & num(a.outH[1]) & " " & num(b.inH[0]) & " " & num(b.inH[1]) & " " &
                   num(b.p[0]) & " " & num(b.p[1])
    if sp.closed: result.add "Z"

proc paintOf(p: ShapePaint; id: string; box: Rect; defs: var string): string =
  ## (a fill or stroke: a color, or a gradient put in `defs`)
  case p.kind
  of spNone: "none"
  of spColor: hexColor(p.color)
  of spGradient:
    var stops = p.stops
    if stops.len == 0:
      stops = @[GradientStop(at: 0, color: p.color, mid: 0.5), GradientStop(at: 1, color: p.color2, mid: 0.5)]
    if p.reverse:
      var r: seq[GradientStop]
      for k in countdown(stops.high, 0): r.add GradientStop(at: 1 - stops[k].at, color: stops[k].color, mid: 0.5)
      stops = r
    let cx = box.x.float + box.w / 2
    let cy = box.y.float + box.h / 2
    if p.style == 1:
      defs.add "<radialGradient id=\"" & id & "\" gradientUnits=\"userSpaceOnUse\" cx=\"" & num(cx) & "\" cy=\"" &
               num(cy) & "\" r=\"" & num(max(box.w, box.h) / 2) & "\">"
    else:
      let a = degToRad(p.angle.float)
      let half = (abs(cos(a)) * box.w.float + abs(sin(a)) * box.h.float) / 2
      defs.add "<linearGradient id=\"" & id & "\" gradientUnits=\"userSpaceOnUse\" x1=\"" & num(cx - cos(a) * half) &
               "\" y1=\"" & num(cy + sin(a) * half) & "\" x2=\"" & num(cx + cos(a) * half) & "\" y2=\"" &
               num(cy - sin(a) * half) & "\">"
    for s in stops:
      defs.add "<stop offset=\"" & num(s.at) & "\" stop-color=\"" & hexColor(s.color) & "\"" &
               (if (s.color shr 24) < 255: " stop-opacity=\"" & num((s.color shr 24).float / 255) & "\"" else: "") &
               "/>"
    defs.add (if p.style == 1: "</radialGradient>" else: "</linearGradient>")
    "url(#" & id & ")"
  else: hexColor(p.color)

proc pngData(px: seq[uint32]; w, h: int; r: Rect; mask: Layer): string =
  ## (part of a layer as a PNG, base64: what its mask hides left out)
  let b = newBitmap(r.w, r.h)
  let masked = mask != nil and mask.px.len == px.len
  for y in 0 ..< r.h:
    for x in 0 ..< r.w:
      var p = px[(r.y + y) * w + r.x + x]
      if masked:
        let m = mask.px[(r.y + y) * w + r.x + x] and 255
        p = (p and 0xFFFFFF'u32) or ((((p shr 24) * m + 127) div 255) shl 24)
      b.px[y * r.w + x] = p
  b.opaque = false
  "data:image/png;base64," & encode(encodePng(b))

proc cssFamily(f: string): string =
  ## (a family as font-family names it: a kind of font after it, for where
  ## it is not installed)
  let fam = if f.len > 0: f else: defaultFamily
  let low = fam.toLowerAscii
  let kind = if "mono" in low or "courier" in low: "monospace"
             elif "serif" in low and "sans" notin low: "serif"
             else: "sans-serif"
  (if ' ' in fam: "'" & fam.replace("'", "") & "'" else: fam) & ", " & kind

proc bold(st: CharStyle): bool = st.fauxBold or "bold" in st.style.toLowerAscii or "black" in st.style.toLowerAscii
proc italic(st: CharStyle): bool =
  st.fauxItalic or "italic" in st.style.toLowerAscii or "oblique" in st.style.toLowerAscii

proc styleAttrs(st: CharStyle; base: CharStyle; all: bool): string =
  ## (a run's look as attributes: all of it, or what differs from `base`)
  if all or st.family != base.family: result.add " font-family=\"" & xmlText(cssFamily(st.family)) & "\""
  if all or st.size != base.size: result.add " font-size=\"" & num(st.size) & "\""
  if all or st.color != base.color:
    result.add " fill=\"" & hexColor(st.color) & "\""
    if (st.color shr 24) < 255 or (not all and (base.color shr 24) < 255):
      result.add " fill-opacity=\"" & num((st.color shr 24).float / 255) & "\""
  if bold(st) != bold(base) or (all and bold(st)):
    result.add " font-weight=\"" & (if bold(st): "bold" else: "normal") & "\""
  if italic(st) != italic(base) or (all and italic(st)):
    result.add " font-style=\"" & (if italic(st): "italic" else: "normal") & "\""
  if st.underline != base.underline or st.strike != base.strike or (all and (st.underline or st.strike)):
    result.add " text-decoration=\"" & (if st.underline and st.strike: "underline line-through"
                                        elif st.underline: "underline"
                                        elif st.strike: "line-through"
                                        else: "none") & "\""
  if st.tracking != base.tracking or (all and st.tracking != 0):
    result.add " letter-spacing=\"" & num(st.tracking.float / 1000 * st.size) & "\""
  if st.script != base.script or (all and st.script != scNormal):
    result.add " baseline-shift=\"" & (case st.script
                                       of scSuper: "super"
                                       of scSub: "sub"
                                       else: "baseline") & "\""

proc runsOf(td: TextData; runes: seq[string]; a, b: int; base: CharStyle): string =
  ## (the characters `a` ..< `b`: each run that looks other than `base` in
  ## a tspan of its own)
  var k = a
  while k < min(b, runes.len):
    let st = td.styleAt(k)
    var s = ""
    var j = k
    while j < min(b, runes.len) and td.styleAt(j) == st:
      if runes[j] != "\n": s.add runes[j]
      inc j
    k = j
    if s.len == 0: continue
    let at = styleAttrs(st, base, false)
    if at.len > 0: result.add "<tspan" & at & ">" & xmlText(s) & "</tspan>"
    else: result.add xmlText(s)

proc cssBlend(m: BlendMode): string =
  ## (a blending mode CSS has too; "": it has not)
  case m
  of bmMultiply: "multiply"
  of bmScreen: "screen"
  of bmOverlay: "overlay"
  of bmDarken: "darken"
  of bmLighten: "lighten"
  of bmColorDodge: "color-dodge"
  of bmColorBurn: "color-burn"
  of bmHardLight: "hard-light"
  of bmSoftLight: "soft-light"
  of bmDifference: "difference"
  of bmExclusion: "exclusion"
  of bmHue: "hue"
  of bmSaturation: "saturation"
  of bmColor: "color"
  of bmLuminosity: "luminosity"
  else: ""

proc svgLosses*(d: Doc): seq[string] =
  ## What of the document an SVG does not hold (`svgOf` leaves it out, or
  ## writes pixels for it): to say when it is saved as one.
  var adjust, fx, masks, clipped, modes, smart: bool
  for L in d.layers:
    if L.adjust.kind.len > 0: adjust = true
    if L.hasFx: fx = true
    if L.mask != nil and not L.maskOff and (L.isShape or L.isText or L.group): masks = true
    if L.clipped: clipped = true
    if L.mode != bmNormal and cssBlend(L.mode).len == 0 and not (L.group and L.passThrough): modes = true
    if L.isSmart: smart = true
  if adjust: result.add "adjustment layers"
  if fx: result.add "layer effects"
  if masks: result.add "masks on shapes, type and groups"
  if clipped: result.add "clipping masks"
  if modes: result.add "some blending modes"
  if smart: result.add "Smart Objects (kept as pictures)"
  if d.depth > 8: result.add "more than 8 bits a channel"


proc svgOf*(d: Doc; pixels = true): string =
  ## The document as an SVG file (`pixels`: its pixel layers too, as
  ## pictures; else only its shapes and text). Each layer under its name
  ## (`data-name`; its id the name without spaces), groups as `<g>`.
  var defs = ""
  var n = 0
  var ids: seq[string]
  var bufs = @[""]                      # (what is written, for each depth of groups)
  proc naming(L: Layer; ids: var seq[string]; n: int): string =
    var id = ""
    for ch in L.name:
      id.add (if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '.'} or ch.ord >= 128: ch else: '_')
    if id.len == 0 or id[0] in {'0' .. '9', '-', '.'}: id = "layer_" & id
    if id in ids: id.add "_" & $n
    ids.add id
    " id=\"" & xmlText(id) & "\" data-name=\"" & xmlText(L.name) & "\""
  for L in d.layers:
    if L.adjust.kind.len > 0: continue
    let dp = max(0, L.depth)
    while bufs.len <= dp: bufs.add ""
    let vis = if L.visible: "" else: " visibility=\"hidden\""
    let blend = if L.group and L.passThrough: "" else: cssBlend(L.mode)
    let op = (if L.opacity < 100: " opacity=\"" & num(L.opacity / 100) & "\"" else: "") &
             (if blend.len > 0: " style=\"mix-blend-mode:" & blend & "\"" else: "")
    let name = naming(L, ids, n)
    inc n
    if L.group:
      # (a group: what is in it was written before it, a depth deeper)
      var inner = ""
      while bufs.len > dp + 1: inner = bufs.pop() & inner
      bufs[dp].add "<g" & name & (if L.visible: "" else: " display=\"none\"") & op & ">\n" & inner & "</g>\n"
      continue
    while bufs.len > dp + 1:
      # (layers deeper than this one with no group over them: where they are)
      let x = bufs.pop()
      bufs[^1].add x
    var body = ""
    if L.isShape and not L.isFill:
      let sh = L.shape
      let box = d.layerBox(L)
      # (a line with arrowheads: cut back where they cover it; they follow, filled)
      var a = "<path" & name & vis & op & " d=\"" & sh.trimmedPath.pathData & "\" fill=\"" &
              paintOf(sh.fill, "g" & $n & "f", box, defs) & "\" fill-rule=\"nonzero\""
      if sh.fill.opacity in 1 .. 99: a.add " fill-opacity=\"" & num(sh.fill.opacity / 100) & "\""
      if sh.stroke.kind != spNone and sh.strokeWidth > 0:
        # (a stroke inside or outside its outline, as SVG has none: twice as wide, the half
        # that is not there cut off -- by the outline itself, or by all but it -- or, outside
        # an opaque fill, under the fill; said in data-stroke-align, for it to be opened as
        # it was)
        var closedOnly = sh.path.subs.len > 0
        for sp in sh.path.subs:
          if not sp.closed: closedOnly = false
        let solidFill = sh.fill.kind == spColor and sh.fill.opacity notin 1 .. 99 and (sh.fill.color shr 24) == 255
        var wide = 1.0
        if closedOnly and sh.align == saInside:
          defs.add "<clipPath id=\"sa" & $n & "\"><path d=\"" & sh.trimmedPath.pathData & "\"/></clipPath>"
          a.add " clip-path=\"url(#sa" & $n & ")\" data-stroke-align=\"inside\""
          wide = 2
        elif closedOnly and sh.align == saOutside and solidFill:
          a.add " paint-order=\"stroke\" data-stroke-align=\"outside\""
          wide = 2
        elif closedOnly and sh.align == saOutside and sh.fill.kind == spNone:
          let far = num(float(max(d.w, d.h)) * 4 + sh.strokeWidth * 4)
          defs.add "<clipPath id=\"sa" & $n & "\"><path clip-rule=\"evenodd\" d=\"M-" & far & " -" & far & "L" & far &
                   " -" & far & "L" & far & " " & far & "L-" & far & " " & far & "Z" & sh.trimmedPath.pathData &
                   "\"/></clipPath>"
          a.add " clip-path=\"url(#sa" & $n & ")\" data-stroke-align=\"outside\""
          wide = 2
        a.add " stroke=\"" & paintOf(sh.stroke, "g" & $n & "s", box, defs) & "\" stroke-width=\"" &
              num(sh.strokeWidth * wide) & "\""
        if sh.stroke.opacity in 1 .. 99: a.add " stroke-opacity=\"" & num(sh.stroke.opacity / 100) & "\""
        a.add " stroke-linecap=\"" & (case sh.cap
                                       of lcRound: "round"
                                       of lcSquare: "square"
                                       else: "butt") & "\""
        a.add " stroke-linejoin=\"" & (case sh.join
                                        of ljRound: "round"
                                        of ljBevel: "bevel"
                                        else: "miter") & "\""
        if sh.dashes.len > 0:
          var ds: seq[string]
          for v in sh.dashes: ds.add num(v * sh.strokeWidth)
          a.add " stroke-dasharray=\"" & ds.join(" ") & "\""
      body.add a & "/>\n"
      if sh.hasEnds and sh.stroke.kind == spColor and sh.strokeWidth > 0:
        body.add "<path" & vis & op & " d=\"" & sh.endsPath.pathData & "\" fill=\"" &
                 paintOf(sh.stroke, "g" & $n & "e", box, defs) & "\" fill-rule=\"nonzero\"/>\n"
    elif L.isText:
      # (the text as text: each line where it is laid out, each run in its look)
      let td = d.effectiveText(L)
      let lay = layoutText(td)
      let st = td.styleAt(0)
      var runes = newSeq[string]()
      for r in td.plainText.runes: runes.add $r
      var t = "<text" & name & vis & op & " xml:space=\"preserve\"" & styleAttrs(st, st, true)
      if td.onPath and not td.vertical:
        # (along its path: the path in the defs, the text on it)
        var pd = ""
        for k, p in td.path: pd.add (if k == 0: "M" else: "L") & num(p[0]) & " " & num(p[1])
        defs.add "<path id=\"tp" & $n & "\" d=\"" & pd & "\"/>"
        t.add "><textPath href=\"#tp" & $n & "\"" &
              (if td.pathOffset != 0: " startOffset=\"" & num(td.pathOffset) & "\"" else: "") & ">" &
              runsOf(td, runes, 0, runes.len, st) & "</textPath>"
      else:
        # (point text set from its middle or its end: said so, for the lines
        # to stay one text where it is opened again)
        let point = td.boxW <= 0 and not td.vertical and not td.warped
        let anchor = if not point: 0
                     elif td.para.align in {textCenter, justifyCenter}: 1
                     elif td.para.align in {textRight, justifyRight}: 2
                     else: 0
        var rtl = false
        for ln in lay.lines:
          if ln.rtl: rtl = true
        if anchor > 0 and not rtl: t.add " text-anchor=\"" & (if anchor == 1: "middle" else: "end") & "\""
        t.add ">"
        for ln in lay.lines:
          let s = runsOf(td, runes, ln.first, ln.last, st)
          if s.strip.len == 0: continue
          let x = if ln.rtl: ln.x1 elif anchor > 0 and not rtl: td.x else: ln.x0
          t.add "<tspan x=\"" & num(x) & "\" y=\"" & num(ln.baseline) & "\"" &
                (if ln.rtl: " direction=\"rtl\" text-anchor=\"start\"" else: "") & ">" & s & "</tspan>"
      body.add t & "</text>\n"
    elif pixels and L.px.len == d.w * d.h:
      let r = d.contentBounds(L)
      if r.w <= 0 or r.h <= 0: continue
      let mask = if L.mask != nil and not L.maskOff: L.mask else: nil
      # (one opaque color all over, as a Background is: a rectangle)
      var flat = mask == nil and r.w == d.w and r.h == d.h and (L.px[0] shr 24) == 255
      if flat:
        let c = L.px[0]
        for p in L.px:
          if p != c:
            flat = false
            break
      if flat:
        body.add "<rect" & name & vis & op & " width=\"" & $d.w & "\" height=\"" & $d.h & "\" fill=\"" &
                 hexColor(L.px[0]) & "\"/>\n"
      else:
        body.add "<image" & name & vis & op & " x=\"" & $r.x & "\" y=\"" & $r.y & "\" width=\"" & $r.w &
                 "\" height=\"" & $r.h & "\" href=\"" & pngData(L.px, d.w, d.h, r, mask) & "\"/>\n"
    bufs[^1].add body
  var all = ""
  for b in bufs: all.add b
  result = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" &
           "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" & $d.w & "\" height=\"" & $d.h &
           "\" viewBox=\"0 0 " & $d.w & " " & $d.h & "\">\n"
  if d.name.len > 0: result.add "<title>" & xmlText(d.name) & "</title>\n"
  if defs.len > 0: result.add "<defs>" & defs & "</defs>\n"
  result.add all & "</svg>\n"
