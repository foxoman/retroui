## A document as SVG: its shape layers as vector shapes (their paths,
## fills -- colors and linear or radial gradients -- and strokes, with
## dashes, caps and joins), its type layers as text (the text kept: it can
## be edited in a drawing program), and its other layers as pictures; in
## their order, opacity and visibility. File > Export > SVG.
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

proc pngData(px: seq[uint32]; w, h: int; r: Rect): string =
  ## (part of a layer as a PNG, base64)
  let b = newBitmap(r.w, r.h)
  for y in 0 ..< r.h:
    for x in 0 ..< r.w: b.px[y * r.w + x] = px[(r.y + y) * w + r.x + x]
  "data:image/png;base64," & encode(encodePng(b))

proc svgOf*(d: Doc; pixels = true): string =
  ## The document as an SVG file (`pixels`: its pixel layers too, as
  ## pictures; else only its shapes and text).
  var defs = ""
  var body = ""
  var n = 0
  for L in d.layers:
    if L.group or L.adjust.kind.len > 0: continue
    let vis = if L.visible: "" else: " visibility=\"hidden\""
    let op = if L.opacity < 100: " opacity=\"" & num(L.opacity / 100) & "\"" else: ""
    let name = " id=\"" & xmlText(L.name).replace(" ", "_") & "_" & $n & "\""
    inc n
    if L.isShape and not L.isFill:
      let sh = L.shape
      let box = d.layerBox(L)
      # (a line with arrowheads: cut back where they cover it; they follow, filled)
      var a = "<path" & name & vis & op & " d=\"" & sh.trimmedPath.pathData & "\" fill=\"" &
              paintOf(sh.fill, "g" & $n & "f", box, defs) & "\" fill-rule=\"nonzero\""
      if sh.fill.opacity in 1 .. 99: a.add " fill-opacity=\"" & num(sh.fill.opacity / 100) & "\""
      if sh.stroke.kind != spNone and sh.strokeWidth > 0:
        a.add " stroke=\"" & paintOf(sh.stroke, "g" & $n & "s", box, defs) & "\" stroke-width=\"" &
              num(sh.strokeWidth) & "\""
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
      # (the text as text: each line where it is laid out)
      let lay = layoutText(d.effectiveText(L))
      let st = L.text.styleAt(0)
      var t = "<text" & name & vis & op & " font-family=\"" & xmlText(st.family) & "\" font-size=\"" &
              num(st.size) & "\" fill=\"" & hexColor(st.color) & "\"" &
              (if st.fauxBold or "bold" in st.style.toLowerAscii: " font-weight=\"bold\"" else: "") &
              (if st.fauxItalic or "italic" in st.style.toLowerAscii: " font-style=\"italic\"" else: "") & ">"
      let plain = L.text.plainText
      var runes = newSeq[string]()
      for r in plain.runes: runes.add $r
      for ln in lay.lines:
        var s = ""
        for k in ln.first ..< min(ln.last, runes.len):
          if runes[k] != "\n": s.add runes[k]
        if s.strip.len == 0: continue
        t.add "<tspan x=\"" & num(if ln.rtl: ln.x1 else: ln.x0) & "\" y=\"" & num(ln.baseline) & "\"" &
              (if ln.rtl: " direction=\"rtl\" text-anchor=\"start\"" else: "") & ">" & xmlText(s) & "</tspan>"
      body.add t & "</text>\n"
    elif pixels and L.px.len == d.w * d.h:
      let r = d.contentBounds(L)
      if r.w <= 0 or r.h <= 0: continue
      body.add "<image" & name & vis & op & " x=\"" & $r.x & "\" y=\"" & $r.y & "\" width=\"" & $r.w &
               "\" height=\"" & $r.h & "\" href=\"" & pngData(L.px, d.w, d.h, r) & "\"/>\n"
  result = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" &
           "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" & $d.w & "\" height=\"" & $d.h &
           "\" viewBox=\"0 0 " & $d.w & " " & $d.h & "\">\n"
  if defs.len > 0: result.add "<defs>" & defs & "</defs>\n"
  result.add body & "</svg>\n"
