# Retro Atelier -- included by photo.nim
#
# The assistant (Window > Assistant, or Edit > Ask AI): a conversation with the AI Connector's
# service that works the image with Retro Atelier's own tools -- text and shapes added, layers
# set, a selection made, menu commands run, a picture made from words -- each change asked
# first and one step to undo. Pictures from words, Generative Fill and Generative Expand go
# through the image service (Edit > AI Connector). Off until a service is set.

const assistSystem = "You are the assistant inside Retro Atelier, an editor of photos, drawings and pages. " &
  "You change the open image with your tools; look at the document (the document tool) before you change " &
  "it. Positions and sizes are in the image's pixels, from its top left corner. Colors are #RRGGBB. " &
  "Layers are counted from 0 at the bottom. Text in Arabic is fine: write it as it reads. Say briefly what " &
  "you did, in the language the user writes in."

var
  assistPicture = true           ## (a picture of the image goes with each message)
  genRun: tuple[job: Job[AiImageAnswer]; d: Doc; kind: int; prompt: string; at: Rect;
                done: proc (text: string) {.closure.}]
  genExpandOld: Rect             ## (Generative Expand: where the picture was in the grown canvas)

proc hexOf(s: string; dflt: uint32): uint32 =
  ## ("#RRGGBB" as a pixel, opaque)
  var c: Color
  if parseHexColor(s, c): 0xFF000000'u32 or (uint32(c.r) shl 16) or (uint32(c.g) shl 8) or uint32(c.b)
  else: dflt

proc pictureOfDoc(d: Doc; r: Rect): Bitmap =
  ## (the image as it shows, in `r`: mixed into a buffer as big as the document --
  ## `compositeInto` writes where `r` is in it -- then that part taken out)
  var all = newSeq[uint32](d.w * d.h)
  d.compositeInto(all, r, d.layers)
  if r.x == 0 and r.y == 0 and r.w == d.w and r.h == d.h: return Bitmap(w: d.w, h: d.h, px: all)
  result = Bitmap(w: r.w, h: r.h, px: newSeq[uint32](r.w * r.h))
  for y in 0 ..< r.h:
    let sy = r.y + y
    if sy < 0 or sy >= d.h: continue
    for x in 0 ..< r.w:
      let sx = r.x + x
      if sx >= 0 and sx < d.w: result.px[y * r.w + x] = all[sy * d.w + sx]

proc docText(d: Doc): string =
  ## (the document, told to the service)
  if d == nil: return "No image is open."
  result = "\"" & d.name & "\", " & $d.w & " x " & $d.h & " pixels, " & $d.layers.len & " layers (0 at the bottom):"
  for i, L in d.layers:
    let b = d.layerBox(L)
    result.add "\n" & $i & ". \"" & L.name & "\" -- " & layerKindName(L)[1] &
               (if L.isText: " saying \"" & L.text.plainText.substr(0, 80) & "\"" else: "") &
               (if not L.visible: ", hidden" else: "") & (if L.opacity < 100: ", opacity " & $L.opacity else: "") &
               (if b.w > 0: ", at " & $b.x & "," & $b.y & " size " & $b.w & " x " & $b.h else: ", empty") &
               (if i == d.cur: " (the current layer)" else: "")
  if d.hasSelection:
    let s = d.selBounds
    result.add "\nA selection: " & $s.x & "," & $s.y & " size " & $s.w & " x " & $s.h & "."
  else: result.add "\nNo selection."

proc layerArg(d: Doc; a: JsonNode): int =
  ## (a tool's layer: by its index or its name; -1 none)
  if a.hasKey("layer") and a["layer"].kind == JInt: return (if a["layer"].getInt in 0 ..< d.layers.len: a["layer"].getInt else: -1)
  let n = a{"layer"}.getStr(a{"name"}.getStr)
  for i, L in d.layers:
    if cmpIgnoreCase(L.name, n) == 0: return i
  try:
    let i = parseInt(n)
    if i in 0 ..< d.layers.len: return i
  except ValueError: discard
  -1

# ---- pictures through the image service --------------------------------------------------------------------------

proc genLayerName(kind: int; prompt: string): string =
  let p = if prompt.len > 40: prompt[0 ..< 40] & "..." else: prompt
  case kind
  of 0: (if p.len > 0: p else: "Generative Fill")
  of 1: "Generative Expand"
  else: (if p.len > 0: p else: "Generated Image")

proc genFinish() =
  ## (the service's picture back: laid on a new layer where it was asked)
  let r = genRun.job
  let d = genRun.d
  let tell = genRun.done
  genRun.job = nil
  genRun.done = nil
  var said = ""
  if r == nil or not r.done:
    said = "the image service did not answer" & (if r != nil and r.failed: ": " & r.error else: "")
  elif r.value.error.len > 0: said = r.value.error
  elif d == nil or not docs.anyIt(it.doc == d): said = "the image was closed meanwhile"
  else:
    let p = r.value.picture
    let at = genRun.at
    d.layersChange(case genRun.kind
                   of 0: "Generative Fill"
                   of 1: "Generative Expand"
                   else: "Generate Image"):
      let L = d.addLayer(genLayerName(genRun.kind, genRun.prompt), above = (if genRun.kind == 1: d.layers.high else: d.cur))
      for y in 0 ..< at.h:
        let dy = at.y + y
        if dy < 0 or dy >= d.h: continue
        for x in 0 ..< at.w:
          let dx = at.x + x
          if dx < 0 or dx >= d.w: continue
          L.px[dy * d.w + dx] = p.px[y * p.w + x]
      inc L.ver
      d.cur = d.layers.find(L)
      # (Generative Fill shows only in the selection; Expand only where the canvas grew)
      if genRun.kind == 0 and d.hasSelection: d.addLayerMask(mfRevealSelection, d.cur)
      elif genRun.kind == 1:
        d.addLayerMask(mfRevealAll, d.cur)
        let m = d.layers[d.cur].mask
        if m != nil:
          # (the old picture's place hidden: the layer shows only what is new)
          for y in 0 ..< d.h:
            for x in 0 ..< d.w:
              if x >= genExpandOld.x and x < genExpandOld.x + genExpandOld.w and
                 y >= genExpandOld.y and y < genExpandOld.y + genExpandOld.h:
                m.px[y * d.w + x] = 0xFF000000'u32
          inc m.ver
    d.markAll()
    said = (case genRun.kind
            of 0: "filled the selection"
            of 1: "grew the canvas and filled what is new"
            else: "made the picture") & " -- a new layer, \"" & genLayerName(genRun.kind, genRun.prompt) & "\"" &
           (if r.value.note.len > 0: " (the service: " & r.value.note & ")" else: "")
  status = (if said.len > 0: "AI: " & said else: status)
  if tell != nil: tell(said)

proc startGen(kind: int; prompt: string; w = 0, h = 0; at = Rect(); done: proc (text: string) {.closure.} = nil): string =
  ## Asks the image service for Generative Fill (0: the selection made again as `prompt` says --
  ## empty: filled from what is round it), Generative Expand (1: the canvas grown to `w` x `h`,
  ## what is new made) or a picture from words (2: in `at`, else the selection's box, else the
  ## whole image). "" or why not.
  let d = cur()
  if d == nil: return "no image is open"
  if genRun.job != nil and genRun.job.running: return "the image service is still working on the last one"
  loadImgAi()
  if not imgAi.s.connected: return "no image service is set (Edit > AI Connector > Pictures)"
  let s = imgAi.s
  var work: Job[AiImageAnswer]
  var place: Rect
  case kind
  of 0:
    let sb = if d.hasSelection: d.selBounds else: Rect()
    if sb.w <= 0 or sb.h <= 0: return "nothing is selected: select what to fill first"
    # (some of what is round it too, so that what is made matches)
    let mx = max(16, sb.w div 3)
    let my = max(16, sb.h div 3)
    place = rect(max(0, sb.x - mx), max(0, sb.y - my), 0, 0)
    place.w = min(d.w, sb.x + sb.w + mx) - place.x
    place.h = min(d.h, sb.y + sb.h + my) - place.y
    let img = pictureOfDoc(d, place)
    var mask = Bitmap(w: place.w, h: place.h, px: newSeq[uint32](place.w * place.h))
    for y in 0 ..< place.h:
      for x in 0 ..< place.w:
        mask.px[y * place.w + x] = if d.selAt((place.y + y) * d.w + place.x + x) > 0: 0'u32 else: 0xFF000000'u32
    let words = if prompt.strip.len > 0: prompt
                else: "Fill the clear part of the mask with what would be there, matching the rest of the " &
                      "picture -- its light, its colors, its grain; take away what was there."
    work = job(proc (): AiImageAnswer {.gcsafe.} =
      {.cast(gcsafe).}: editImage(s, words, img, mask), onDone = genFinish)
  of 1:
    let nw = clamp(w, d.w, d.w * 3)
    let nh = clamp(h, d.h, d.h * 3)
    if nw == d.w and nh == d.h: return "the canvas is that size already"
    let old = pictureOfDoc(d, rect(0, 0, d.w, d.h))
    d.snapStep("Canvas Size")
    try: d.canvasSize(nw, nh, 1, 1, 0'u32)
    except ValueError:
      d.endStep()
      return "too big"
    d.endStep()
    if active != nil: active.fitWindow()
    genExpandOld = rect((nw - old.w) div 2, (nh - old.h) div 2, old.w, old.h)
    place = rect(0, 0, nw, nh)
    var img = Bitmap(w: nw, h: nh, px: newSeq[uint32](nw * nh))
    var mask = Bitmap(w: nw, h: nh, px: newSeq[uint32](nw * nh))
    for y in 0 ..< old.h:
      for x in 0 ..< old.w:
        let k = (genExpandOld.y + y) * nw + genExpandOld.x + x
        img.px[k] = old.px[y * old.w + x]
        mask.px[k] = 0xFF000000'u32
    let words = if prompt.strip.len > 0: prompt & " -- the picture carried on past its edges"
                else: "Carry the picture on past its edges into the clear part, as if the photo had been " &
                      "taken wider: the same scene, light and colors."
    work = job(proc (): AiImageAnswer {.gcsafe.} =
      {.cast(gcsafe).}: editImage(s, words, img, mask), onDone = genFinish)
  else:
    if prompt.strip.len == 0: return "say what the picture should show"
    place = if at.w > 0 and at.h > 0: at
            elif d.hasSelection: d.selBounds
            else: rect(0, 0, d.w, d.h)
    let (pw, ph) = (place.w, place.h)
    work = job(proc (): AiImageAnswer {.gcsafe.} =
      {.cast(gcsafe).}: generateImage(s, prompt, pw, ph), onDone = genFinish)
  genRun = (work, d, kind, prompt, place, done)
  status = "AI: asking the image service..."
  ""

proc genDialog() =
  if not genDlg.open: return
  let title = ["Generative Fill", "Generative Expand", "Generate Image"][clamp(genDlg.kind, 0, 2)]
  loadImgAi(withKey = false)
  var go = false
  dialog(genDlg.open, title, 460):
    if not imgAi.s.connected:
      paragraph("No image service is set: Edit > AI Connector, Pictures.", color = ui.theme.gray)
    case genDlg.kind
    of 0: paragraph("The selection made again by your image service, as you describe it -- or, said nothing, " &
                    "filled from what is round it. It comes as a new layer, masked to the selection.")
    of 1:
      paragraph("The canvas grown round the image, and what is new made by your image service to carry the " &
                "picture on. It comes as a new layer.")
      row([90, 90, 30, 90]):
        label "Width:"
        spin(genDlg.w, 1, 30000, w = dp(86))
        label "Height:"
        spin(genDlg.h, 1, 30000, w = dp(86))
    else: paragraph("A new picture from your words, on a new layer -- the size of the selection, else of the image.")
    label("Describe it" & (if genDlg.kind == 2: ":" else: " (or leave it empty):"))
    editArea(genDlg.prompt, lines = 3)
    row:
      spring()
      if button("&Generate", isDefault = true, w = dp(96),
                enabled = imgAi.s.connected and (genDlg.kind != 2 or genDlg.prompt.strip.len > 0)): go = true
      if button("Cancel", w = dp(80)): genDlg.open = false
  if go:
    genDlg.open = false
    let why = startGen(genDlg.kind, genDlg.prompt, genDlg.w, genDlg.h)
    if why.len > 0: status = title & ": " & why

# ---- the assistant's tools ------------------------------------------------------------------------------------

proc leanCommandTool(): AiTool =
  ## (the device's own model: the commands not listed in the tool -- hundreds of names would be
  ## thousands of tokens to read first -- but matched as it writes one, with the nearest
  ## offered when it is not one)
  aiTool("run_command", "Runs one of Retro Atelier's menu commands by its name as in the menus: Black & White, " &
         "Invert, Gaussian Blur..., Flatten Image, Image Size..., Trim..., Crop...",
         [param("command", "string", "the command's name")],
    proc (a: JsonNode): string =
      let want = a{"command"}.getStr.strip.strip(chars = {'.'})
      var near: seq[string]
      for c in appCommands():
        let bare = c.strip(chars = {'.'})
        if cmpIgnoreCase(bare, want) == 0:
          runCommand(c)
          return "ran " & c
        if want.len >= 3 and want.toLowerAscii in c.toLowerAscii and near.len < 8: near.add c
      "not a command of Retro Atelier: " & want & (if near.len > 0: " (near: " & near.join(", ") & ")" else: ""),
    confirm = true)

proc assistTools(device = false): seq[AiTool] =
  result.add aiTool("document", "Describes the open image: its size, its layers (index, name, kind, where), " &
                    "the current layer, the selection.", [],
    proc (a: JsonNode): string = docText(cur()))
  result.add(if device: leanCommandTool() else: commandTool(appCommands(), proc (c: string) = runCommand(c)))
  result.add aiTool("add_text", "Adds a type layer: text at x, y (the first line's baseline starts there).",
    [param("text", "string", "what it says (\\n: a new line)"), param("x", "number", "pixels from the left"),
     param("y", "number", "pixels from the top"), param("size", "number", "its size in pixels", optional = true),
     param("color", "string", "#RRGGBB", optional = true),
     param("weight", "string", "Regular, Bold, Light, Black...", optional = true),
     param("font", "string", "a font family (Dastkhat if not given)", optional = true)],
    proc (a: JsonNode): string =
      let d = cur()
      if d == nil: return "no image is open"
      var st = typeStyle
      st.size = a{"size"}.getFloat(max(12.0, d.h.float / 12)).float32
      st.color = hexOf(a{"color"}.getStr, 0xFF000000'u32)
      if a{"font"}.getStr.len > 0: st.family = a{"font"}.getStr
      if a{"weight"}.getStr.len > 0: st.style = a{"weight"}.getStr
      var t = newText(a{"text"}.getStr, st, a{"x"}.getFloat.float32, a{"y"}.getFloat.float32)
      if startsArabic(a{"text"}.getStr): t.spans[0].style.lang = "ar"
      var L: Layer
      d.layersChange("AI: Add Text"):
        L = d.addTextLayer(t, above = d.cur)
        d.cur = d.layers.find(L)
      d.markAll()
      "added a type layer, \"" & L.name & "\", at index " & $d.cur,
    confirm = true)
  result.add aiTool("add_shape", "Adds a shape layer: a rectangle, an ellipse or a line, filled and stroked.",
    [param("kind", "string", "the shape", ["rectangle", "ellipse", "line"]),
     param("x", "number", "its left"), param("y", "number", "its top"), param("w", "number", "its width"),
     param("h", "number", "its height"), param("fill", "string", "#RRGGBB, or none", optional = true),
     param("stroke", "string", "#RRGGBB, or none", optional = true),
     param("stroke_width", "number", "pixels", optional = true),
     param("radius", "number", "a rectangle's rounded corners", optional = true)],
    proc (a: JsonNode): string =
      let d = cur()
      if d == nil: return "no image is open"
      let x = a{"x"}.getFloat
      let y = a{"y"}.getFloat
      let w = a{"w"}.getFloat(100)
      let h = a{"h"}.getFloat(100)
      var sd = ShapeData(strokeWidth: a{"stroke_width"}.getFloat(0))
      case a{"kind"}.getStr
      of "ellipse":
        sd.path = ellipsePath(x, y, x + w, y + h)
        sd.kind = "Ellipse"
      of "line":
        sd.path = linePath(x, y, x + w, y + h, max(1.0, sd.strokeWidth))
        sd.kind = "Line"
      else:
        sd.radius = a{"radius"}.getFloat(0)
        sd.path = rectPath(x, y, x + w, y + h, sd.radius)
        sd.kind = "Rectangle"
      let f = a{"fill"}.getStr("#808080")
      if f != "none": sd.fill = solidPaint(hexOf(f, 0xFF808080'u32))
      let s = a{"stroke"}.getStr("none")
      if s != "none" and sd.strokeWidth > 0: sd.stroke = solidPaint(hexOf(s, 0xFF000000'u32))
      if sd.kind == "Line" and sd.fill.kind == spNone: sd.fill = solidPaint(hexOf(s, 0xFF000000'u32))
      var L: Layer
      d.layersChange("AI: Add Shape"):
        L = d.addShapeLayer(sd, above = d.cur)
        d.cur = d.layers.find(L)
      d.markAll()
      "added a shape layer, \"" & L.name & "\", at index " & $d.cur,
    confirm = true)
  if not device:
    # (vector art from the conversation: the service writes the SVG, kept to shapes before it is read)
    result.add aiTool("add_vector", "Adds vector art as shape layers you can change: an SVG of plain shapes " &
                      "(path, rect, circle, ellipse, polygon, polyline, line, g, linear and radial gradients; " &
                      "colors as #rrggbb; no text or images) fitted into x, y, w, h (the middle of the image if " &
                      "not given).",
      [param("svg", "string", "the SVG document, <svg viewBox=\"0 0 512 512\">...</svg>"),
       param("x", "number", "its left", optional = true), param("y", "number", "its top", optional = true),
       param("w", "number", "its width", optional = true), param("h", "number", "its height", optional = true),
       param("name", "string", "the group's name", optional = true)],
      proc (a: JsonNode): string =
        let d = cur()
        if d == nil: return "no image is open"
        let svg = svgOfAnswer(a{"svg"}.getStr)
        if svg.len == 0: return "that is not an SVG of shapes"
        let side = max(64, min(d.w, d.h) * 3 div 4)
        let w = max(8, int(a{"w"}.getFloat(float(side))))
        let h = max(8, int(a{"h"}.getFloat(float(side))))
        let at = rect(int(a{"x"}.getFloat(float((d.w - w) div 2))), int(a{"y"}.getFloat(float((d.h - h) div 2))), w, h)
        let made = d.placeSvg(svg, at)
        if made.len == 0: return "nothing in it to draw"
        if a{"name"}.getStr.len > 0: made[0].name = a{"name"}.getStr
        d.markAll()
        "added the vector art as " & $made.len & " layers, \"" & made[0].name & "\"",
      confirm = true)
  result.add aiTool("set_layer", "Changes a layer: makes it the current one, renames it, shows or hides it, its " &
                    "opacity, moves it by dx, dy, or deletes it.",
    [param("layer", "string", "its index or its name"), param("current", "boolean", "make it the current layer", optional = true),
     param("rename", "string", "a new name", optional = true), param("visible", "boolean", "shown", optional = true),
     param("opacity", "integer", "0..100", optional = true), param("dx", "number", "move right by", optional = true),
     param("dy", "number", "move down by", optional = true), param("delete", "boolean", "delete it", optional = true)],
    proc (a: JsonNode): string =
      let d = cur()
      if d == nil: return "no image is open"
      let i = d.layerArg(a)
      if i < 0: return "no such layer: " & $a{"layer"}
      let L = d.layers[i]
      var did: seq[string]
      d.layersChange("AI: Layer"):
        if a{"rename"}.getStr.len > 0:
          L.name = a{"rename"}.getStr
          did.add "renamed"
        if a.hasKey("visible"):
          L.visible = a{"visible"}.getBool
          did.add(if L.visible: "shown" else: "hidden")
        if a.hasKey("opacity"):
          L.opacity = clamp(a{"opacity"}.getInt, 0, 100)
          did.add "opacity " & $L.opacity
        if a.hasKey("dx") or a.hasKey("dy"):
          d.shiftLayers(@[L], int(a{"dx"}.getFloat), int(a{"dy"}.getFloat))
          did.add "moved"
        if a{"current"}.getBool:
          d.cur = i
          did.add "made current"
        if a{"delete"}.getBool and d.layers.len > 1:
          d.cur = i
          d.deleteLayer()
          did.add "deleted"
        inc L.ver
      d.markAll()
      if did.len == 0: "nothing to change" else: "layer \"" & L.name & "\": " & did.join(", "),
    confirm = true)
  result.add aiTool("select", "Selects a rectangle or an ellipse of the image (or all, or none).",
    [param("shape", "string", "what to select", ["rectangle", "ellipse", "all", "none"]),
     param("x", "number", "", optional = true), param("y", "number", "", optional = true),
     param("w", "number", "", optional = true), param("h", "number", "", optional = true)],
    proc (a: JsonNode): string =
      let d = cur()
      if d == nil: return "no image is open"
      case a{"shape"}.getStr
      of "all": runCommand("All")
      of "none": runCommand("None")
      else:
        let r = rect(int(a{"x"}.getFloat), int(a{"y"}.getFloat), max(1, int(a{"w"}.getFloat)), max(1, int(a{"h"}.getFloat)))
        let round = a{"shape"}.getStr == "ellipse"
        var m = newSeq[uint8](d.w * d.h)
        let (cx, cy, rx, ry) = (r.x.float + r.w / 2, r.y.float + r.h / 2, r.w / 2, r.h / 2)
        for y in max(0, r.y) ..< min(d.h, r.y + r.h):
          for x in max(0, r.x) ..< min(d.w, r.x + r.w):
            let (u, v) = ((x.float + 0.5 - cx) / rx, (y.float + 0.5 - cy) / ry)
            if not round or u * u + v * v <= 1.0:
              m[y * d.w + x] = 255
        d.beginStep("AI: Select")
        d.setSelection(m)
        d.endStep()
        inc d.selVer
      d.markAll()
      if d.hasSelection: "selected " & $d.selBounds else: "nothing selected")
  result.add aiToolLater("generate_image", "Makes a picture from words through the image service, on a new layer: " &
                         "at x, y, w, h if given, else the selection's box, else the whole image.",
    [param("prompt", "string", "what the picture shows, in detail"),
     param("x", "number", "", optional = true), param("y", "number", "", optional = true),
     param("w", "number", "", optional = true), param("h", "number", "", optional = true)],
    proc (a: JsonNode; done: proc (text: string) {.closure.}) =
      let at = if a.hasKey("w") and a.hasKey("h"):
                 rect(int(a{"x"}.getFloat), int(a{"y"}.getFloat), int(a{"w"}.getFloat), int(a{"h"}.getFloat))
               else: Rect()
      let why = startGen(2, a{"prompt"}.getStr, at = at, done = done)
      if why.len > 0: done(why),
    confirm = true)
  result.add aiToolLater("generative_fill", "Makes the selection again through the image service as the prompt " &
                         "says (empty: filled from what is round it -- to remove something), on a new layer.",
    [param("prompt", "string", "what should be there (\"\" to take away what is there)", optional = true)],
    proc (a: JsonNode; done: proc (text: string) {.closure.}) =
      let why = startGen(0, a{"prompt"}.getStr, done = done)
      if why.len > 0: done(why),
    confirm = true)

proc atelierChat(): AiChat =
  ## (the assistant's conversation: made when first wanted, the service asked of the keyring then;
  ## the device's own model with fewer tools -- what it reads first is read slowly -- and no
  ## picture, which it cannot see)
  let device = aiDlg.s.kind == akDevice
  if assist == nil or (assist.settings.kind == akDevice) != device:
    loadAi()
    if assist != nil: assist.close()
    var tools = assistTools(device)
    if device and not imgAi.s.connected:
      var i = 0
      while i < tools.len:
        if tools[i].name in ["generate_image", "generative_fill"]: tools.delete(i) else: inc i
    assist = newAiChat(aiDlg.s, assistSystem, tools)
    assist.context = proc (): string = docText(cur())
    assist.attach = proc (): string =
      let d = cur()
      if not assistPicture or d == nil or aiDlg.s.kind == akDevice: return ""
      let b = thumbnail(pictureOfDoc(d, rect(0, 0, d.w, d.h)), 768, 768)
      encodePng(b, level = 3)
  else:
    assist.settings = aiDlg.s
  assist

proc assistantBody() =
  ## (the Assistant panel)
  loadAi(withKey = false)
  if not aiDlg.s.connected:
    paragraph("Connect an AI service of your own -- on your computer (Ollama, LM Studio) or online -- and ask " &
              "here for what you want done: it uses Retro Atelier's tools, asking before each change.",
              color = ui.theme.gray)
    if button("AI Connector...", w = dp(130)): aiDlg.open = true
    return
  let c = atelierChat()
  if aiDlg.s.kind != akDevice: checkbox("Show it the image", assistPicture)
  else: label(tr("This device's model: ") & aiDlg.s.model, color = ui.theme.gray)
  assistantPanel(c)

# (the same tools for an AI agent outside, when the app is driven: RETRO_DRIVE, `retrokit mcp`)
var toolsOffered = false
proc offerTools() {.nimcall.} =
  if toolsOffered or drivePort() == 0: return
  toolsOffered = true
  publishTools(assistTools())
beginFrameHooks.add offerTools

# ---- Type > Shorten to Fit: overset text made shorter by the AI service ---------------------------------------

proc runeLenOf(s: string): int = unicode.runeLen(s)

const shortenSystem = "You shorten texts to fit a box of a page layout. Keep the meaning, the language, the tone " &
  "and the paragraphs. Answer with the shortened text only: no quotes, no notes, nothing else."

proc shortenDone() =
  ## (the answer: the box's text, one step to undo; still overset -- asked again, shorter, twice at most)
  let run = fitRun
  fitRun.job = nil
  var (t, err) = onceAnswer(aiDlg.s, run.job)
  let L = run.layer
  let d = run.d
  if err.len > 0:
    status = tr("Shorten to Fit: ") & err
    return
  if d == nil or L notin d.layers or not L.isText:
    status = tr("Shorten to Fit: the box is gone")
    return
  t = t.strip(chars = Whitespace + {'"', '\'', '`'})
  if t.len == 0:
    status = tr("Shorten to Fit: the service answered nothing")
    return
  var nt = L.text
  let style = if nt.spans.len > 0: nt.spans[0].style else: CharStyle()
  nt.spans = @[TextSpan(text: t, style: style)]
  d.stepOnce("Shorten to Fit", proc () = d.setText(L, nt))
  d.markAll()
  if layoutText(d.effectiveText(L)).overflow >= 0 and run.tries < 2:
    startShorten(L, run.tries + 1)
  else:
    status = tr("Shortened to ") & $t.runeLenOf & tr(" letters") &
             (if layoutText(d.effectiveText(L)).overflow >= 0: tr(" -- still overset: size the box or flow it on")
              else: tr(" -- it fits"))

proc startShorten(L: Layer; tries = 0) =
  ## (the box's overset text sent to the service, to be made as short as fits -- the whole
  ## text in its first span's style)
  let d = cur()
  if d == nil or L == nil or not L.isText or L.text.boxW <= 0: return
  if fitRun.job != nil and fitRun.job.running:
    status = tr("Shorten to Fit: the last one is not done yet")
    return
  loadAi()
  if not aiDlg.s.connected:
    status = tr("Shorten to Fit: connect an AI service first (Edit > AI Connector)")
    aiDlg.open = true
    return
  let text = L.text.plainText
  let lay = layoutText(d.effectiveText(L))
  if lay.overflow < 0 and tries == 0:
    status = tr("Shorten to Fit: the text fits its box already")
    return
  let fits = if lay.overflow >= 0: lay.overflow else: text.runeLenOf
  let want = max(4, int(float(fits) * (0.92 - 0.12 * float(tries))))
  fitRun = (askOnce(aiDlg.s, shortenSystem, "Shorten this to at most " & $want & " characters:\n\n" & text,
                    onDone = shortenDone), L, d, tries, want)
  status = tr("Shortening the text to ") & $want & tr(" letters...")

# ---- Edit > Generate Vector: vector art from words, by the AI service or this device's model ------------------

var vecRun: tuple[job: Job[HttpResponse]; d: Doc; prompt: string; at: Rect]
  ## (the request out: the image it is for, where it goes)

proc vecDone() =
  ## (the answer: its drawing as shapes, in a group named after the words -- one step to undo)
  let run = vecRun
  vecRun.job = nil
  let (svg, err) = vectorAnswer(aiDlg.s, run.job)
  let d = run.d
  if err.len > 0:
    status = tr("Generate Vector: ") & err
    return
  if d == nil or not docs.anyIt(it.doc == d):
    status = tr("Generate Vector: the image was closed meanwhile")
    return
  let made = d.placeSvg(svg, run.at)
  if made.len == 0:
    status = tr("Generate Vector: the answer had no drawing in it")
    return
  let name = if run.prompt.len > 40: run.prompt[0 ..< 40] & "..." else: run.prompt
  made[0].name = name
  d.markAll()
  status = tr("Generate Vector: made as shapes -- ") & $made.len & tr(" layers, to change as any")

proc vecDialog() =
  ## Edit > Generate Vector: words to vector art -- a subject, a scene, an icon, a pattern -- drawn by
  ## the AI service (or this device's model: Edit > Models) as shapes to edit, in the selection, else
  ## over the middle of the image
  if not vecDlg.open: return
  loadAi()
  var go = false
  dialog(vecDlg.open, "Generate Vector", 460):
    if not aiDlg.s.connected:
      paragraph("No AI service is set: Edit > AI Connector (or a model on this device: Edit > Models).",
                color = ui.theme.gray)
    paragraph("Vector art from your words, as shapes you can change -- in the selection, else in the middle " &
              "of the image." & (if aiDlg.s.kind == akDevice: " This device's model draws it: simple shapes." else: ""))
    row([110, -1]):
      label "Content type:"
      var names: seq[string]
      for k in VectorKind: names.add tr($k)
      combo(names, vecDlg.kind, w = dp(140))
    checkbox("In the foreground and background colors", vecDlg.inColors)
    label("Describe it:")
    editArea(vecDlg.prompt, lines = 3)
    row:
      spring()
      if button("&Generate", isDefault = true, w = dp(96),
                enabled = aiDlg.s.connected and vecDlg.prompt.strip.len > 0 and
                          (vecRun.job == nil or not vecRun.job.running)): go = true
      if button("Cancel", w = dp(80)): vecDlg.open = false
  if go:
    vecDlg.open = false
    let d = cur()
    if d == nil: return
    var at = if d.hasSelection: d.selBounds else: rect(0, 0, 0, 0)
    if at.w < 8 or at.h < 8:
      let side = max(64, min(d.w, d.h) * 3 div 4)
      at = rect((d.w - side) div 2, (d.h - side) div 2, side, side)
    let colors = if vecDlg.inColors: @[fg, bg] else: @[]
    let p = vecDlg.prompt.strip
    vecRun = (askVector(aiDlg.s, p, VectorKind(clamp(vecDlg.kind, 0, ord(high(VectorKind)))), colors,
                        onDone = vecDone), d, p, at)
    status = tr("Generate Vector: asking ") & (if aiDlg.s.kind == akDevice: tr("this device's model...")
                                               else: tr("the AI service..."))
