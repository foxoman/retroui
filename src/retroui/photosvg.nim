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

import std/[strutils, math, base64, json]
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
    if (p.style == 5 and p.points.len > 0) or (p.style == 6 and p.meshCols >= 2 and p.points.len >= 4):
      # (a freeform gradient, a gradient mesh: SVG has neither -- its colors as a picture over the box)
      let bw = clamp(box.w, 1, 512)
      let bh = clamp(box.h, 1, 512)
      let b = newBitmap(bw, bh)
      for y in 0 ..< bh:
        for x in 0 ..< bw:
          let u = (x.float + 0.5) / bw.float
          let v = (y.float + 0.5) / bh.float
          b.px[y * bw + x] = if p.style == 5: freeformAt(p.points, u, v) else: meshAt(p.points, p.meshCols, u, v)
      b.opaque = false
      defs.add "<pattern id=\"" & id & "\" patternUnits=\"userSpaceOnUse\" x=\"" & num(box.x.float) & "\" y=\"" &
               num(box.y.float) & "\" width=\"" & num(max(1, box.w).float) & "\" height=\"" & num(max(1, box.h).float) &
               "\"><image width=\"" & num(max(1, box.w).float) & "\" height=\"" & num(max(1, box.h).float) &
               "\" preserveAspectRatio=\"none\" href=\"data:image/png;base64," & encode(encodePng(b)) & "\"/></pattern>"
      return "url(#" & id & ")"
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
  of spPattern:
    # (a pattern: its tile a picture, repeated from the document's corner)
    if p.pw <= 0 or p.ph <= 0 or p.pattern.len != p.pw * p.ph: return hexColor(p.color)
    let b = newBitmap(p.pw, p.ph)
    b.px = p.pattern
    b.opaque = false
    let k = (if p.scale > 0: p.scale else: 100).float / 100
    defs.add "<pattern id=\"" & id & "\" patternUnits=\"userSpaceOnUse\" width=\"" & num(p.pw.float * k) &
             "\" height=\"" & num(p.ph.float * k) & "\"><image width=\"" & num(p.pw.float * k) & "\" height=\"" &
             num(p.ph.float * k) & "\" preserveAspectRatio=\"none\" href=\"data:image/png;base64," &
             encode(encodePng(b)) & "\"/></pattern>"
    "url(#" & id & ")"

proc pngData(px: seq[uint32]; w, h: int; r: Rect): string =
  ## (part of a layer as a PNG, base64)
  let b = newBitmap(r.w, r.h)
  for y in 0 ..< r.h:
    for x in 0 ..< r.w: b.px[y * r.w + x] = px[(r.y + y) * w + r.x + x]
  b.opaque = false
  "data:image/png;base64," & encode(encodePng(b))

proc clipBase(d: Doc; i: int): Layer =
  ## (the layer a clipped layer is clipped to: the first under it, as deep,
  ## that is not clipped itself; nil when there is none it can be written by)
  if not d.layers[i].clipped: return nil
  for k in countdown(i - 1, 0):
    let B = d.layers[k]
    if B.depth < d.layers[i].depth: return nil
    if B.depth > d.layers[i].depth: continue
    if not B.clipped: return (if B.group or B.px.len != d.w * d.h: nil else: B)
  nil

proc maskDef(d: Doc; i: int; id: string; defs: var string): string =
  ## (a layer's mask and what it is clipped to, as one mask in `defs`:
  ## white where it shows; "" when it has neither)
  let L = d.layers[i]
  let own = if L.mask != nil and not L.maskOff and L.mask.px.len == d.w * d.h: L.mask else: nil
  let base = d.clipBase(i)
  if own == nil and base == nil: return ""
  var x0 = d.w
  var y0 = d.h
  var x1 = -1
  var y1 = -1
  var v = newSeq[uint8](d.w * d.h)
  for y in 0 ..< d.h:
    for x in 0 ..< d.w:
      let k = y * d.w + x
      var g = 255'u32
      if own != nil: g = own.px[k] and 255
      if base != nil:
        var a = base.px[k] shr 24
        if base.mask != nil and not base.maskOff and base.mask.px.len == d.w * d.h:
          a = (a * (base.mask.px[k] and 255) + 127) div 255
        g = (g * a + 127) div 255
      v[k] = uint8(g)
      if g > 0:
        x0 = min(x0, x)
        y0 = min(y0, y)
        x1 = max(x1, x)
        y1 = max(y1, y)
  if x1 < x0:
    # (nothing shows: a mask of nothing)
    defs.add "<mask id=\"" & id & "\" maskUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" width=\"" & $d.w &
             "\" height=\"" & $d.h & "\"/>"
    return " mask=\"url(#" & id & ")\""
  let b = newBitmap(x1 - x0 + 1, y1 - y0 + 1)
  for y in y0 .. y1:
    for x in x0 .. x1:
      let g = uint32(v[y * d.w + x])
      b.px[(y - y0) * b.w + x - x0] = 0xFF000000'u32 or (g shl 16) or (g shl 8) or g
  defs.add "<mask id=\"" & id & "\" maskUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" width=\"" & $d.w &
           "\" height=\"" & $d.h & "\"><image x=\"" & $x0 & "\" y=\"" & $y0 & "\" width=\"" & $b.w &
           "\" height=\"" & $b.h & "\" href=\"data:image/png;base64," & encode(encodePng(b)) & "\"/></mask>"
  " mask=\"url(#" & id & ")\""

proc shadowDef(d: Doc; L: Layer; id: string; defs: var string): string =
  ## (a layer's Drop Shadow -- or its Outer Glow, a shadow that lies under
  ## it -- as a filter in `defs`; "" when it has neither)
  if L.fx.hidden: return ""
  var e = L.fx.fx[fxDropShadow]
  var glow = false
  if not e.on:
    e = L.fx.fx[fxOuterGlow]
    glow = true
  if not e.on: return ""
  let a = degToRad(e.angle.float)
  let dx = if glow: 0.0 else: -cos(a) * e.distance.float
  let dy = if glow: 0.0 else: sin(a) * e.distance.float
  let alpha = (e.color shr 24).float / 255 * clamp(e.opacity, 0, 100).float / 100
  defs.add "<filter id=\"" & id & "\" filterUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" width=\"" & $d.w &
           "\" height=\"" & $d.h & "\"><feDropShadow dx=\"" & num(dx) & "\" dy=\"" & num(dy) &
           "\" stdDeviation=\"" & num(e.size.float / 2) & "\" flood-color=\"" & hexColor(e.color) &
           "\" flood-opacity=\"" & num(alpha) & "\"/></filter>"
  " filter=\"url(#" & id & ")\""

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
  if not all and (st.allCaps != base.allCaps or st.smallCaps != base.smallCaps):
    # (a run's own; the whole text's goes with its element's other styles: `capsCss`)
    result.add " style=\"text-transform:" & (if st.allCaps: "uppercase" else: "none") & ";font-variant:" &
               (if st.smallCaps: "small-caps" else: "normal") & "\""
  if st.script != base.script or (all and st.script != scNormal):
    result.add " baseline-shift=\"" & (case st.script
                                       of scSuper: "super"
                                       of scSub: "sub"
                                       else: "baseline") & "\""

proc capsCss(st: CharStyle): string =
  ## (all capitals, small capitals: as CSS says them)
  if st.allCaps: result.add "text-transform:uppercase;"
  if st.smallCaps: result.add "font-variant:small-caps;"

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

proc svgOwn*(d: Doc): seq[string] =
  ## What of the document its SVG holds for Retro Photo alone: written in
  ## attributes of its own (data-retro-fx, data-retro-mode,
  ## data-retro-adjust), read back as it was, and not shown by other
  ## programs -- adjustment layers, the layer effects SVG has nothing for,
  ## the blending modes CSS has no name for. To say when it is saved.
  var adjust, modes: bool
  var fx: seq[string]
  for i, L in d.layers:
    if L.adjust.kind.len > 0: adjust = true
    if not L.fx.hidden:
      for kind, e in L.fx.fx:
        if not e.on: continue
        let shown = kind == fxDropShadow or (kind == fxOuterGlow and not L.fx.fx[fxDropShadow].on) or
                    (L.isText and kind in {fxStroke, fxGradientOverlay})
        if not shown and $kind notin fx: fx.add $kind
    if L.mode != bmNormal and cssBlend(L.mode).len == 0 and not (L.group and L.passThrough): modes = true
  if adjust: result.add "adjustment layers"
  if fx.len > 0: result.add "layer effects (" & fx.join(", ") & ")"
  if modes: result.add "some blending modes"

proc svgLosses*(d: Doc): seq[string] =
  ## What of the document an SVG does not hold (`svgOf` leaves it out, or
  ## writes pixels for it): to say when it is saved as one. Kept, and so
  ## not named: layer masks and clipping masks (as masks), Drop Shadow and
  ## Outer Glow (as a filter), a type layer's Stroke and Gradient Overlay,
  ## and what is kept for Retro Photo alone (`svgOwn`).
  var smart, clipGroup, adjustMask: bool
  for i, L in d.layers:
    if L.adjust.kind.len > 0:
      # (an adjustment layer's own mask: not written)
      for p in L.px:
        if (p and 255) != 255:
          adjustMask = true
          break
      continue
    if L.clipped and d.clipBase(i) == nil: clipGroup = true
    if L.isSmart: smart = true
  if adjustMask: result.add "the masks of adjustment layers"
  if clipGroup: result.add "clipping to a group"
  if smart: result.add "Smart Objects (kept as pictures)"
  if d.depth > 8: result.add "more than 8 bits a channel"


proc svgOf*(d: Doc; pixels = true; outlines = false): string =
  ## The document as an SVG file (`pixels`: its pixel layers too, as
  ## pictures; else only its shapes and text). Each layer under its name
  ## (`data-name`; its id the name without spaces), groups as `<g>`; layer
  ## masks and clipping masks as masks; Drop Shadow as a filter; a pattern
  ## fill as a pattern. `outlines`: type as its letters' outlines (paths)
  ## -- it looks the same where its fonts are not, and is no longer text.
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
  proc quoted(s: string): string =
    ## (JSON as an attribute's value, in single quotes)
    "'" & s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("'", "&apos;")) & "'"
  for li, L in d.layers:
    let dp = max(0, L.depth)
    while bufs.len <= dp: bufs.add ""
    let vis = if L.visible: "" else: " visibility=\"hidden\""
    if L.adjust.kind.len > 0:
      # (an adjustment layer: nothing an SVG can show -- an empty group that says what it is, for
      # Retro Photo to make it again)
      var aj = %*{"kind": L.adjust.kind, "args": L.adjust.args}
      if L.adjust.data.len > 0: aj["data"] = %L.adjust.data
      bufs[dp].add "<g" & naming(L, ids, n) & " data-retro-adjust=" & quoted($aj) &
                   (if L.clipped: " data-retro-clipped=\"1\"" else: "") & vis &
                   (if L.opacity < 100: " opacity=\"" & num(L.opacity / 100) & "\"" else: "") & "/>\n"
      inc n
      continue
    let blend = if L.group and L.passThrough: "" else: cssBlend(L.mode)
    let op = (if L.opacity < 100: " opacity=\"" & num(L.opacity / 100) & "\"" else: "") &
             d.maskDef(li, "mk" & $n, defs) & d.shadowDef(L, "fx" & $n, defs)
    # (what CSS alone says: the blending mode -- with a text's capitals, in one style)
    let css = if blend.len > 0: "mix-blend-mode:" & blend & ";" else: ""
    let sty = if css.len > 0: " style=\"" & css & "\"" else: ""
    # (for Retro Photo itself: the layer's effects as they are, a blending mode CSS has no name for)
    var own = ""
    var kept = L.fx
    # (type written as outlines: its Stroke is the outlines' own line)
    if L.isText and outlines: kept.fx[fxStroke].on = false
    var anyFx = false
    for e in kept.fx:
      if e.on: anyFx = true
    if anyFx:
      var fj = toJson(kept)
      if L.fill < 100: fj["fill"] = %L.fill          # (its Fill, which the effects are not under)
      own.add " data-retro-fx=" & quoted($fj)
    if L.mode != bmNormal and blend.len == 0 and not (L.group and L.passThrough):
      own.add " data-retro-mode=\"" & xmlText($L.mode) & "\""
    let name = naming(L, ids, n) & own
    inc n
    if L.group:
      # (a group: what is in it was written before it, a depth deeper)
      var inner = ""
      while bufs.len > dp + 1: inner = bufs.pop() & inner
      bufs[dp].add "<g" & name & (if L.visible: "" else: " display=\"none\"") & op & sty & ">\n" & inner &
                   "</g>\n"
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
      var a = "<path" & name & vis & op & sty & " d=\"" & sh.trimmedPath.pathData & "\" fill=\"" &
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
    elif L.isText and (outlines or L.text.table.on or L.text.notes.len > 0):
      # (the text as its letters' outlines: one path a color; a table, notes so too, their lines with them)
      let td = d.effectiveText(L)
      var col = 0'u32
      var pd = ""
      var first = true
      # (its Stroke: the outlines' own; Fill at 0: nothing but it)
      var line = ""
      var hollow = false
      if not L.fx.hidden:
        let sk = L.fx.fx[fxStroke]
        if sk.on and sk.size > 0:
          hollow = L.fill == 0
          line = " stroke=\"" & hexColor(sk.color) & "\" stroke-width=\"" &
                 num(sk.size.float * (if sk.style == 0: 2 else: 1)) & "\" stroke-linejoin=\"round\"" &
                 (if sk.opacity in 1 .. 99: " stroke-opacity=\"" & num(sk.opacity / 100) & "\"" else: "") &
                 (if sk.style == 0 and not hollow: " paint-order=\"stroke\"" else: "")
      template flushPath() =
        if pd.len > 0:
          body.add "<path" & (if first: name else: "") & vis & op & sty & " d=\"" & pd & "\" fill=\"" &
                   (if hollow: "none" else: hexColor(col)) & "\"" &
                   (if (col shr 24) < 255 and not hollow: " fill-opacity=\"" & num((col shr 24).float / 255) & "\""
                    else: "") & " fill-rule=\"nonzero\"" & line & "/>\n"
          first = false
          pd = ""
      for o in textOutlines(td, layoutText(td), fine = true):
        if o.color != col: flushPath()
        col = o.color
        for poly in o.polys:
          if poly.len < 3: continue
          for k, v in poly: pd.add (if k == 0: "M" else: "L") & num(v[0]) & " " & num(v[1])
          pd.add "Z"
      flushPath()
    elif L.isText:
      # (the text as text: each line where it is laid out, each run in its look)
      let td = d.effectiveText(L)
      let lay = layoutText(td)
      let st = td.styleAt(0)
      var runes = newSeq[string]()
      for r in td.plainText.runes: runes.add $r
      var t = "<text" & name & vis & op & " xml:space=\"preserve\"" & styleAttrs(st, st, true)
      if css.len > 0 or capsCss(st).len > 0: t.add " style=\"" & css & capsCss(st) & "\""
      if td.vertical: t.add " writing-mode=\"vertical-rl\""
      if not L.fx.hidden:
        # (its Stroke: its letters' outline -- outside them: under them, twice as wide; its
        # Gradient Overlay: its fill)
        let sk = L.fx.fx[fxStroke]
        if sk.on and sk.size > 0:
          t.add " stroke=\"" & hexColor(sk.color) & "\" stroke-width=\"" &
                num(sk.size.float * (if sk.style == 0: 2 else: 1)) & "\" stroke-linejoin=\"round\"" &
                (if sk.opacity in 1 .. 99: " stroke-opacity=\"" & num(sk.opacity / 100) & "\"" else: "") &
                (if sk.style == 0: " paint-order=\"stroke\"" else: "")
          # (Fill at 0: the outline alone)
          if L.fill == 0: t.add " fill-opacity=\"0\""
        let go = L.fx.fx[fxGradientOverlay]
        if go.on:
          let a = degToRad(go.angle.float)
          let (c0, c1) = if go.down: (go.color2, go.color) else: (go.color, go.color2)
          if go.style == 1:
            defs.add "<radialGradient id=\"tg" & $n & "\" cx=\"0.5\" cy=\"0.5\" r=\"0.5\">"
          else:
            defs.add "<linearGradient id=\"tg" & $n & "\" x1=\"" & num(0.5 - cos(a) / 2) & "\" y1=\"" &
                     num(0.5 + sin(a) / 2) & "\" x2=\"" & num(0.5 + cos(a) / 2) & "\" y2=\"" & num(0.5 - sin(a) / 2) &
                     "\">"
          defs.add "<stop offset=\"0\" stop-color=\"" & hexColor(c0) & "\"/><stop offset=\"1\" stop-color=\"" &
                   hexColor(c1) & "\"/>" & (if go.style == 1: "</radialGradient>" else: "</linearGradient>")
          t.add " fill=\"url(#tg" & $n & ")\""
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
          # (running down: an SVG's x is the middle of the letters' height, they lie on their side)
          let x = (if ln.rtl: ln.x1 elif anchor > 0 and not rtl: td.x else: ln.x0) +
                  (if td.vertical: 0.35'f32 * st.size else: 0'f32)
          t.add "<tspan x=\"" & num(x) & "\" y=\"" & num(ln.baseline) & "\"" &
                (if ln.rtl: " direction=\"rtl\" text-anchor=\"start\"" else: "") & ">" & s & "</tspan>"
      body.add t & "</text>\n"
    elif pixels and L.px.len == d.w * d.h:
      let r = d.contentBounds(L)
      if r.w <= 0 or r.h <= 0: continue
      # (one opaque color all over, as a Background is: a rectangle)
      var flat = r.w == d.w and r.h == d.h and (L.px[0] shr 24) == 255
      if flat:
        let c = L.px[0]
        for p in L.px:
          if p != c:
            flat = false
            break
      if flat:
        body.add "<rect" & name & vis & op & sty & " width=\"" & $d.w & "\" height=\"" & $d.h & "\" fill=\"" &
                 hexColor(L.px[0]) & "\"/>\n"
      else:
        body.add "<image" & name & vis & op & sty & " x=\"" & $r.x & "\" y=\"" & $r.y & "\" width=\"" & $r.w &
                 "\" height=\"" & $r.h & "\" href=\"" & pngData(L.px, d.w, d.h, r) & "\"/>\n"
    bufs[^1].add body
  var all = ""
  for b in bufs: all.add b
  result = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" &
           "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" & $d.w & "\" height=\"" & $d.h &
           "\" viewBox=\"0 0 " & $d.w & " " & $d.h & "\">\n"
  if d.name.len > 0: result.add "<title>" & xmlText(d.name) & "</title>\n"
  if defs.len > 0: result.add "<defs>" & defs & "</defs>\n"
  result.add all & "</svg>\n"
