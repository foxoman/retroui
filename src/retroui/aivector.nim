## Vector art from words: a subject, a scene, an icon or a pattern drawn by an AI as an SVG of
## plain shapes -- online with the user's own service, offline with the device's own model
## (`retroui/devicemodel`, an `AiSettings` of kind `akDevice`) -- then placed as shapes the user
## edits (`placeSvg` in `retroui/svgimport`), as the drawing program's Text to Vector Graphic.
##
## .. code-block:: nim
##   import retroui/[aichat, aivector, svgimport]
##   let j = askVector(settings, "a date palm at sunset", vkSubject)
##   ...                                   # (frames go on; then, once it has ended)
##   let (svg, err) = vectorAnswer(settings, j)
##   if svg.len > 0: discard doc.placeSvg(svg, rect(100, 100, 600, 600))
##
## Or the whole dialog, as Retro Atelier's Edit > Generate Vector and Retro Board's Draw from
## Words have it -- the words, the kind, the colors; the request on a worker; the SVG handed back:
##
## .. code-block:: nim
##   var ask = newVectorAsk()
##   ...
##   if button("Draw from words..."): ask.open = true
##   vectorDialog(ask, settings, proc (svg, error, words: string) =
##     if svg.len > 0: discard doc.placeSvg(svg, box) else: toast(error))
##
## What comes back is kept to shapes: an answer's words round the SVG are left out, and what an
## SVG could do besides drawing -- scripts, pictures and pages fetched, links, events, styles from
## elsewhere -- is taken out before it is read (`safeSvg`). Nothing is sent before the user has
## set a service (`retroui/aiconnect`); the device's model is downloaded only when asked.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, xmlparser, xmltree, strtabs]
import core, widgets, aichat, jobs

type
  VectorKind* = enum
    ## What is drawn (as the drawing program's Text to Vector Graphic's Content Type).
    vkSubject = "Subject"      ## one thing on nothing
    vkScene = "Scene"          ## a whole picture, its background too
    vkIcon = "Icon"            ## a simple icon, few shapes, flat colors
    vkPattern = "Pattern"      ## a tile that repeats seamlessly

const
  SafeElements = ["svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon",
                  "defs", "linearGradient", "radialGradient", "stop", "title", "desc", "clipPath"]
    ## (the elements an answer's SVG keeps: shapes, groups, gradients)
  SafeAttrs = ["viewBox", "width", "height", "xmlns", "version", "id", "d", "x", "y", "x1", "y1",
               "x2", "y2", "cx", "cy", "r", "rx", "ry", "fx", "fy", "points", "transform", "fill",
               "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit",
               "stroke-dasharray", "stroke-opacity", "fill-opacity", "fill-rule", "clip-rule",
               "opacity", "offset", "stop-color", "stop-opacity", "gradientUnits",
               "gradientTransform", "spreadMethod", "clip-path", "clipPathUnits",
               "preserveAspectRatio"]
    ## (... and the attributes: geometry and paint; no events, links or styles)

proc vectorSystem*(kind: VectorKind; colors: openArray[uint32] = []): string =
  ## What the service is told first: answer with one SVG of plain shapes for `kind` -- in these
  ## colors (ARGB) when given.
  result = "You are a vector illustrator. Answer with one SVG document and nothing else: " &
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 512 512\">...</svg>. " &
    "Use only path, rect, circle, ellipse, polygon, polyline, line, g, linearGradient, " &
    "radialGradient and stop; colors as #rrggbb in fill and stroke attributes; no text, no images, " &
    "no style elements, no scripts, no links. Keep it under 60 shapes, each shape's path short, " &
    "the drawing filling the view box. "
  result.add case kind
    of vkSubject: "Draw the subject alone, centered, on no background (nothing behind it)."
    of vkScene: "Draw a whole scene: a background over all of the view box, then what is in it."
    of vkIcon: "Draw a simple, bold, flat icon: few shapes, two to four colors, no gradients."
    of vkPattern: "Draw one tile of a seamless pattern: what leaves one edge comes back at the " &
                  "opposite edge, a background over all of the view box."
  if colors.len > 0:
    var cs: seq[string]
    for c in colors: cs.add "#" & toHex(int(c and 0xFFFFFF'u32), 6).toLowerAscii
    result.add " Use these colors: " & cs.join(", ") & "."

proc cleaned(n: XmlNode): XmlNode =
  ## (an element kept to shapes: nil when it is not one)
  if n.kind != xnElement: return nil
  let tag = n.tag.split(':')[^1]
  if tag notin SafeElements: return nil
  var attrs = newStringTable()
  if n.attrs != nil:
    for k, v in n.attrs:
      let key = k.split(':')[^1]
      if key notin SafeAttrs: continue
      let lv = v.toLowerAscii
      # (a paint or a clip from elsewhere: only within the document, `url(#id)`)
      if "url(" in lv and not lv.replace(" ", "").contains("url(#"): continue
      if "javascript:" in lv or "expression(" in lv: continue
      attrs[key] = v
  if tag == "svg": attrs["xmlns"] = "http://www.w3.org/2000/svg"
  result = newXmlTree(tag, [], attrs)
  for c in n:
    if c.kind == xnElement:
      let k = cleaned(c)
      if k != nil: result.add k
    elif c.kind in {xnText, xnCData} and tag in ["title", "desc"]:
      result.add newText(c.text)

proc safeSvg*(svg: string): string =
  ## The SVG kept to what draws: its shapes, groups and gradients, their geometry and paint --
  ## without scripts, pictures, text, links, events, styles or anything fetched; "" when it is
  ## not an SVG.
  try:
    let root = parseXml(svg)
    if root.kind != xnElement or root.tag.split(':')[^1] != "svg": return ""
    let c = cleaned(root)
    if c == nil: return ""
    var shapes = 0
    proc count(n: XmlNode) =
      for k in n:
        if k.kind == xnElement:
          if k.tag in ["path", "rect", "circle", "ellipse", "line", "polyline", "polygon"]: inc shapes
          count(k)
    count(c)
    if shapes == 0: return ""
    result = $c
  except CatchableError:
    result = ""

proc svgOfAnswer*(text: string): string =
  ## The SVG in an answer's words -- in a code block or not, words round it -- kept to shapes
  ## (`safeSvg`); "" when there is none.
  let lo = text.toLowerAscii
  let a = lo.find("<svg")
  if a < 0: return ""
  let b = lo.rfind("</svg>")
  if b < a: return ""
  safeSvg(text[a ..< b + 6])

proc askVector*(s: AiSettings; prompt: string; kind = vkSubject; colors: openArray[uint32] = [];
                onDone: proc () {.closure.} = nil): Job[HttpResponse] =
  ## Vector art of `prompt` asked of the service `s` (or the device's model: `akDevice`), on a
  ## worker; `vectorAnswer` once it has ended.
  askOnce(s, vectorSystem(kind, colors), prompt, onDone)

proc vectorAnswer*(s: AiSettings; j: Job[HttpResponse]): tuple[svg, error: string] =
  ## The SVG `askVector`'s job brought, kept to shapes -- or why there is none ("", "" while it
  ## runs).
  let (text, err) = onceAnswer(s, j)
  if err.len > 0: return ("", err)
  if text.len == 0: return ("", "")
  let svg = svgOfAnswer(text)
  if svg.len == 0: return ("", "the answer had no drawing in it")
  (svg, "")

type
  VectorAsk* = ref object
    ## Generate Vector's dialog, kept by the app (`newVectorAsk`) and shown with `vectorDialog`:
    ## open it with `open = true`.
    open*: bool
    words*: string             ## what to draw
    kind*: VectorKind
    inColors*: bool            ## in the app's colors (`vectorDialog`'s `colors`)
    busy*: bool                ## a request out
    job: Job[HttpResponse]

proc newVectorAsk*(kind = vkSubject): VectorAsk =
  ## Generate Vector's dialog, closed.
  VectorAsk(kind: kind)

proc vectorDialog*(v: VectorAsk; s: AiSettings; onDone: proc (svg, error, words: string) {.closure.};
                   colors: openArray[uint32] = []; title = "Generate Vector";
                   hint = "Vector art from your words, as shapes you can change.") =
  ## The dialog (when `v.open`): `hint` (what the art becomes in the app), the words, the content
  ## type, "In these colors" (when `colors` are given: the app's foreground and background),
  ## Generate. The answer comes to `onDone` between frames: the SVG kept to shapes, or why there
  ## is none. With no service set (`s.connected` false) it says where to set one; the device's
  ## model (`akDevice`) works offline.
  if v == nil or not v.open: return
  var go = false
  dialog(v.open, title, 460):
    if not s.connected:
      paragraph("No AI service is set yet: set one in the AI Connector (or a model on this device) first.",
                color = ui.theme.gray)
    paragraph(tr(hint) & (if s.kind == akDevice: " " & tr("This device's model draws it: simple shapes.") else: ""))
    row([110, -1]):
      label "Content type:"
      var names: seq[string]
      for k in VectorKind: names.add $k
      var k = ord(v.kind)
      if combo(names, k, w = dp(140)): v.kind = VectorKind(clamp(k, 0, ord(high(VectorKind))))
    if colors.len > 0: checkbox("In the foreground and background colors", v.inColors)
    label("Describe it:")
    editArea(v.words, lines = 3)
    row:
      spring()
      if button("&Generate", isDefault = true, w = dp(96),
                enabled = s.connected and v.words.strip.len > 0 and not v.busy): go = true
      if button("Cancel", w = dp(80)): v.open = false
  if go:
    v.open = false
    v.busy = true
    let words = v.words.strip
    let cs = if v.inColors: @colors else: @[]
    let vv = v
    v.job = askVector(s, words, v.kind, cs, onDone = proc () =
      vv.busy = false
      let (svg, err) = vectorAnswer(s, vv.job)
      onDone(svg, err, words))
