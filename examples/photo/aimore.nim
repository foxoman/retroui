# Retro Atelier -- included by photo.nim
#
# The generative edits of 2026's photo and drawing programs, through the services of Edit > AI
# Connector (nothing is sent until one is set): Generate Background, Generative Upscale, Style
# Transfer, Camera Angle, Rotate Object, Recompose, Remove Ambient Effect, Smart Portrait,
# Makeup Transfer and Landscape Mixer by the image service, each a new layer (or a new document)
# to keep or throw away; Generative Recolor, Text to Pattern, Generative Shape Fill, Rewrite and
# Turntable by the AI service.

type
  AiEdit = enum
    aeBackground = "Generate Background", aeUpscale = "Generative Upscale", aeStyle = "Style Transfer",
    aeAngle = "Camera Angle", aeRotate = "Rotate Object", aeRecompose = "Recompose",
    aeAmbient = "Remove Ambient Effect", aePortrait = "Smart Portrait", aeMakeup = "Makeup Transfer",
    aeLandscape = "Landscape Mixer"

  AiTask = object
    ## (one picture asked of the image service)
    img, mask: Bitmap            ## what is sent: the picture, clear where it is made again
    prompt: string
    crop: Rect                   ## the part of the answer used (in `img`'s pixels)
    at: Rect                     ## where it goes in the result (stretched to it)
    feather: int                 ## its edges blended into what is there (Generative Upscale's tiles)

const
  aiBlurb: array[AiEdit, string] = [
    "The subject kept, the rest made again as you say -- a beach, a studio, a city at night -- with the " &
      "light to match. The subject is the selection, else the one found.",
    "The picture 2 or 4 times bigger, its detail made at the new size, a tile at a time (a new document).",
    "The picture drawn again in a style: words, or another open picture's look.",
    "The same scene as the camera would see it from somewhere else.",
    "The selected thing turned, its side shown; the rest as it is.",
    "The picture made again for another frame: its subject where you say.",
    "Haze, reflections in glass, smoke, rain or a lens flare taken out.",
    "The face changed: a smile, older or younger, the eyes and head turned, the light moved.",
    "The makeup of a face in another open picture put on the face here.",
    "The landscape in another season, time of day or weather."]
  aiStyles = ["Oil Painting", "Watercolor", "Pencil Sketch", "Ink Drawing", "Anime", "Comic Book", "Pixel Art",
              "Stained Glass", "Mosaic", "3D Render", "Clay", "Ukiyo-e Woodcut", "Impressionist",
              "Pop Art", "Vintage Photo"]
  aiAngles = ["From the Left", "From the Right", "From Above", "From Below", "Closer", "Farther Back",
              "With a Wider Lens"]
  aiAmbient = ["Haze", "Reflections in Glass", "Smoke", "Rain", "Lens Flare", "Color Cast"]
  aiSeasons = ["As It Is", "Spring", "Summer", "Autumn", "Winter"]
  aiTimes = ["As It Is", "Sunrise", "Midday", "Sunset", "Blue Hour", "Night"]
  aiWeathers = ["As It Is", "Clear", "Fog", "Rain", "Snow", "Storm"]
  aiAspects = ["As It Is", "Square", "4:5", "3:2", "16:9", "9:16"]
  aiPlaces = ["In the Middle", "On the Left Third", "On the Right Third"]
  rewriteHow = ["Shorter", "Longer", "Simpler", "More Formal", "Friendlier", "More Persuasive", "Fix the Grammar",
                "In Arabic", "In English"]

var
  aiEditDlg: tuple[open: bool; kind: AiEdit; words: string; style, source, strength: int; keepColors: bool;
                   factor, angle, amount, turn, ambient, season, time, weather, aspect, place: int;
                   smile, age, gaze, head, light, hair: int] =
    (false, aeBackground, "", 0, 0, 100, false, 0, 0, 30, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
  aiRun: tuple[job: Job[AiImageAnswer]; d: Doc; name: string; tasks: seq[AiTask]; k: int; buf: seq[uint32];
               w, h: int; newDoc: bool; reveal: seq[uint8]; opacity: int; stop: bool]
  textAi: tuple[open: bool; what: int; words: string; how: int; turn: int]
    ## (Generative Recolor 0, Text to Pattern 1, Generative Shape Fill 2, Rewrite 3, Turntable 4)
  textRun: tuple[job: Job[HttpResponse]; img: Job[AiImageAnswer]; d: Doc; layer: Layer; what: int; words: string;
                 box: Rect]

proc aiDone()

proc mixPx(a, b: uint32; t: float): uint32 =
  ## (`a` to `b` by `t`, 0..1)
  proc m(x, y: int): int = int(round(float(x) + (float(y) - float(x)) * t))
  argb(m(aOf(a), aOf(b)), m(rOf(a), rOf(b)), m(gOf(a), gOf(b)), m(bOf(a), bOf(b)))

proc fitSend(b: Bitmap; side = 1536): Bitmap =
  ## (a picture no bigger than the service makes: what is sent)
  let k = float(side) / float(max(b.w, b.h))
  if k >= 1: b
  else: scaledBmp(b, max(1, int(float(b.w) * k)), max(1, int(float(b.h) * k)))

proc maskBmp(w, h: int; clearAt: proc (x, y: int): bool): Bitmap =
  ## (the mask sent: clear where the picture is made again)
  result = Bitmap(w: w, h: h, px: newSeq[uint32](w * h))
  for y in 0 ..< h:
    for x in 0 ..< w: result.px[y * w + x] = if clearAt(x, y): 0'u32 else: 0xFF000000'u32

proc wholeTask(d: Doc; prompt: string; clearAt: proc (x, y: int): bool = nil): AiTask =
  ## (the whole picture sent, made again where `clearAt` says -- everywhere when nil)
  let full = pictureOfDoc(d, rect(0, 0, d.w, d.h))
  let img = fitSend(full)
  let kx = d.w / img.w
  let ky = d.h / img.h
  let mask = maskBmp(img.w, img.h, proc (x, y: int): bool =
    clearAt == nil or clearAt(min(d.w - 1, int(float(x) * kx)), min(d.h - 1, int(float(y) * ky))))
  AiTask(img: img, mask: mask, prompt: prompt, crop: rect(0, 0, img.w, img.h), at: rect(0, 0, d.w, d.h))

proc withReference(t: var AiTask; refB: Bitmap) =
  ## (another picture put beside the one sent, kept as it is, for the service to take its look --
  ## the answer's right part used)
  let rw = max(1, refB.w * t.img.h div max(1, refB.h))
  let rs = scaledBmp(refB, rw, t.img.h)
  let W = rw + t.img.w
  var img = Bitmap(w: W, h: t.img.h, px: newSeq[uint32](W * t.img.h))
  var mask = Bitmap(w: W, h: t.img.h, px: newSeq[uint32](W * t.img.h))
  for y in 0 ..< t.img.h:
    for x in 0 ..< rw:
      img.px[y * W + x] = rs.px[y * rw + x]
      mask.px[y * W + x] = 0xFF000000'u32
    for x in 0 ..< t.img.w:
      img.px[y * W + rw + x] = t.img.px[y * t.img.w + x]
      mask.px[y * W + rw + x] = t.mask.px[y * t.img.w + x]
  let s = fitSend(img)
  let k = s.w / W
  t.img = s
  t.mask = scaledBmp(mask, s.w, s.h)
  for p in t.mask.px.mitems: p = (if aOf(p) >= 128: 0xFF000000'u32 else: 0'u32)
  t.crop = rect(int(float(rw) * k), 0, s.w - int(float(rw) * k), s.h)

proc otherDocs(d: Doc): seq[Doc] =
  for dw in docs:
    if dw.doc != d: result.add dw.doc

proc subjectMask(d: Doc): seq[uint8] =
  ## (the subject: the selection, else the one found)
  if d.hasSelection:
    result = newSeq[uint8](d.w * d.h)
    for i in 0 ..< d.w * d.h: result[i] = uint8(d.selAt(i))
  else: result = d.selectSubject()

proc degree(v: int): string =
  ## (how much, in words: a slider's value)
  let a = abs(v)
  if a < 34: "a little " elif a < 67: "" else: "much "

proc aiNext() =
  ## (the next picture asked)
  let t = aiRun.tasks[aiRun.k]
  let s = imgAi.s
  let (img, mask, words) = (t.img, t.mask, t.prompt)
  aiRun.job = job(proc (): AiImageAnswer {.gcsafe.} =
    {.cast(gcsafe).}: editImage(s, words, img, mask), onDone = aiDone)
  status = tr("AI: ") & tr(aiRun.name) & (if aiRun.tasks.len > 1: " " & $(aiRun.k + 1) & tr(" of ") & $aiRun.tasks.len
                                           else: "") & "..."

proc aiFinish() =
  ## (all of it back: the new layer, or the new document)
  let d = aiRun.d
  if aiRun.newDoc:
    let nd = newUntitled(aiRun.w, aiRun.h, 0, name = d.name & " (" & tr(aiRun.name) & ")")
    nd.layers[0].px = aiRun.buf
    inc nd.layers[0].ver
    nd.markAll()
    addDoc(nd)
  else:
    d.layersChange(aiRun.name):
      let L = d.addLayer(tr(aiRun.name), above = d.cur)
      for i in 0 ..< min(L.px.len, aiRun.buf.len): L.px[i] = aiRun.buf[i]
      L.opacity = clamp(aiRun.opacity, 0, 100)
      inc L.ver
      d.cur = d.layers.find(L)
      if aiRun.reveal.len == d.w * d.h:
        d.addLayerMask(mfRevealAll, d.cur)
        let m = d.layers[d.cur].mask
        if m != nil:
          for i in 0 ..< m.px.len: m.px[i] = grayPx(int(aiRun.reveal[i]))
          inc m.ver
    d.markAll()
  status = tr("AI: ") & tr(aiRun.name) & tr(" -- done") & (if aiRun.newDoc: tr(", a new document") else: tr(", a new layer"))
  aiRun.tasks = @[]
  aiRun.buf = @[]

proc aiDone() =
  let r = aiRun.job
  aiRun.job = nil
  let d = aiRun.d
  if d == nil or not docs.anyIt(it.doc == d):
    status = tr("AI: the image was closed meanwhile")
    aiRun.tasks = @[]
    return
  if r == nil or not r.done or r.value.error.len > 0 or r.value.picture == nil:
    status = tr("AI: ") & (if r != nil and r.done and r.value.error.len > 0: r.value.error
                          elif r != nil and r.failed: r.error else: tr("the image service did not answer"))
    aiRun.tasks = @[]
    aiRun.buf = @[]
    return
  let t = aiRun.tasks[aiRun.k]
  var p = r.value.picture
  if p.w != t.img.w or p.h != t.img.h: p = scaledBmp(p, t.img.w, t.img.h)
  # (the part used, made the size it goes in)
  var part = Bitmap(w: t.crop.w, h: t.crop.h, px: newSeq[uint32](t.crop.w * t.crop.h))
  for y in 0 ..< t.crop.h:
    for x in 0 ..< t.crop.w: part.px[y * t.crop.w + x] = p.px[(t.crop.y + y) * p.w + t.crop.x + x]
  part = scaledBmp(part, t.at.w, t.at.h)
  let W = aiRun.w
  let H = aiRun.h
  let f = float(max(1, t.feather))
  for y in 0 ..< t.at.h:
    let dy = t.at.y + y
    if dy < 0 or dy >= H: continue
    var wy = 1.0
    if t.feather > 0:
      if t.at.y > 0: wy = min(wy, float(y) / f)
      if t.at.y + t.at.h < H: wy = min(wy, float(t.at.h - 1 - y) / f)
    for x in 0 ..< t.at.w:
      let dx = t.at.x + x
      if dx < 0 or dx >= W: continue
      let src = part.px[y * t.at.w + x]
      var w = wy
      if t.feather > 0:
        if t.at.x > 0: w = min(w, float(x) / f)
        if t.at.x + t.at.w < W: w = min(w, float(t.at.w - 1 - x) / f)
      let i = dy * W + dx
      if w >= 1 or t.feather == 0: aiRun.buf[i] = src
      elif w > 0: aiRun.buf[i] = mixPx(aiRun.buf[i], src, w)
  inc aiRun.k
  if aiRun.k < aiRun.tasks.len and not aiRun.stop: aiNext()
  else: aiFinish()

proc startAiEdit(d: Doc) =
  ## (what the dialog says, asked)
  let e = aiEditDlg
  var tasks: seq[AiTask]
  var newDoc = false
  var reveal: seq[uint8]
  var W = d.w
  var H = d.h
  var base: seq[uint32]
  let words = e.words.strip
  case e.kind
  of aeBackground:
    let m = d.subjectMask
    if m.len != d.w * d.h:
      status = tr("Generate Background: no subject was found -- select it first")
      return
    let bgWords = if words.len > 0: words else: "a soft, plain studio background"
    tasks.add d.wholeTask("Keep the subject (the opaque part) exactly as it is. Make everything else again as: " &
                          bgWords & ". Match the light, the shadows and the perspective to the subject.",
                          proc (x, y: int): bool = m[y * d.w + x] < 128)
    reveal = newSeq[uint8](m.len)
    for i in 0 ..< m.len: reveal[i] = 255'u8 - m[i]
  of aeUpscale:
    let k = [2, 4][clamp(e.factor, 0, 1)]
    W = d.w * k
    H = d.h * k
    if W * H > 400_000_000:
      status = tr("Generative Upscale: too big")
      return
    newDoc = true
    let full = pictureOfDoc(d, rect(0, 0, d.w, d.h))
    base = resample(full.px, d.w, d.h, W, H)
    const T = 1024
    const O = 128
    var ty = 0
    while true:
      var tx = 0
      let th = min(T, H - ty)
      while true:
        let tw = min(T, W - tx)
        var img = Bitmap(w: tw, h: th, px: newSeq[uint32](tw * th))
        for y in 0 ..< th:
          for x in 0 ..< tw: img.px[y * tw + x] = base[(ty + y) * W + tx + x]
        tasks.add AiTask(img: img, mask: maskBmp(tw, th, proc (x, y: int): bool = true),
                         prompt: "This is a part of a photo made bigger. Give it the fine, natural detail of a sharp " &
                                 "photo at this size: the same things, colors, light and layout -- nothing added, " &
                                 "nothing taken away, nothing moved.",
                         crop: rect(0, 0, tw, th), at: rect(tx, ty, tw, th), feather: O)
        if tx + tw >= W: break
        tx += T - O
      if ty + th >= H: break
      ty += T - O
  of aeStyle:
    let others = d.otherDocs
    var t = d.wholeTask("")
    if e.source == 1:
      if others.len == 0:
        status = tr("Style Transfer: open the picture whose look to take")
        return
      let o = others[clamp(e.style, 0, others.high)]
      t.withReference(pictureOfDoc(o, rect(0, 0, o.w, o.h)))
      t.prompt = "Redraw the right-hand picture in the style of the left-hand one -- its brushwork, its colors, " &
                 "its texture -- keeping what the right-hand picture shows and where" &
                 (if e.keepColors: ", and the right-hand picture's own colors." else: ".")
    else:
      let st = if words.len > 0: words else: aiStyles[clamp(e.style, 0, aiStyles.high)]
      t.prompt = "Redraw this picture as " & st & ", keeping what it shows and where" &
                 (if e.keepColors: ", and its colors." else: ".")
    tasks.add t
  of aeAngle:
    let dir = aiAngles[clamp(e.angle, 0, aiAngles.high)].toLowerAscii
    tasks.add d.wholeTask("Show the same scene as the camera would see it " & dir & " (about " & $e.amount &
                          " degrees): the same things, light, colors and style." &
                          (if words.len > 0: " " & words else: ""))
  of aeRotate:
    if not d.hasSelection:
      status = tr("Rotate Object: select the thing to turn first")
      return
    let b = d.selBounds
    let mx = b.w div 4
    let my = b.h div 4
    let box = rect(max(0, b.x - mx), max(0, b.y - my), 0, 0)
    let bw = min(d.w, b.x + b.w + mx) - box.x
    let bh = min(d.h, b.y + b.h + my) - box.y
    let dir = ["to its left", "to its right", "up", "down"][clamp(e.turn, 0, 3)]
    tasks.add d.wholeTask("Turn the object in the clear part " & $e.amount & " degrees " & dir &
                          ", showing its side: the same object, its colors and light; what is round it carried on.",
                          proc (x, y: int): bool = x >= box.x and y >= box.y and x < box.x + bw and y < box.y + bh)
    reveal = newSeq[uint8](d.w * d.h)
    for y in box.y ..< box.y + bh:
      for x in box.x ..< box.x + bw: reveal[y * d.w + x] = 255
  of aeRecompose:
    let (aw, ah) = case e.aspect
                   of 1: (1, 1)
                   of 2: (4, 5)
                   of 3: (3, 2)
                   of 4: (16, 9)
                   of 5: (9, 16)
                   else: (d.w, d.h)
    # (the same number of pixels, in the new shape)
    let area = float(d.w * d.h)
    W = max(16, int(sqrt(area * float(aw) / float(ah))))
    H = max(16, int(float(W) * float(ah) / float(aw)))
    newDoc = e.aspect > 0
    let full = pictureOfDoc(d, rect(0, 0, d.w, d.h))
    let k = min(W / d.w, H / d.h)
    let fw = max(1, int(float(d.w) * k))
    let fh = max(1, int(float(d.h) * k))
    let fit = scaledBmp(full, fw, fh)
    var img = Bitmap(w: W, h: H, px: newSeq[uint32](W * H))
    for y in 0 ..< fh:
      for x in 0 ..< fw: img.px[(y + (H - fh) div 2) * W + x + (W - fw) div 2] = fit.px[y * fw + x]
    let s = fitSend(img)
    tasks.add AiTask(img: s, mask: maskBmp(s.w, s.h, proc (x, y: int): bool = true),
                     prompt: "Recompose this photo for a frame of " & $W & " by " & $H & " with its main subject " &
                             aiPlaces[clamp(e.place, 0, 2)].toLowerAscii & ": the same scene, things, light and " &
                             "colors, the empty parts filled as the scene would carry on." &
                             (if words.len > 0: " " & words else: ""),
                     crop: rect(0, 0, s.w, s.h), at: rect(0, 0, W, H))
  of aeAmbient:
    let what = aiAmbient[clamp(e.ambient, 0, aiAmbient.high)].toLowerAscii
    tasks.add d.wholeTask("Take the " & what & " out of this photo, as if it had been taken without it; change " &
                          "nothing else.")
  of aePortrait:
    var asks: seq[string]
    if e.smile > 0: asks.add "make the person smile " & degree(e.smile) & "more"
    elif e.smile < 0: asks.add "make the person look " & degree(e.smile) & "more serious"
    if e.age > 0: asks.add "make the person look " & degree(e.age) & "older"
    elif e.age < 0: asks.add "make the person look " & degree(e.age) & "younger"
    if e.gaze != 0: asks.add "turn the eyes " & degree(e.gaze) & (if e.gaze < 0: "to the left" else: "to the right")
    if e.head != 0: asks.add "turn the head " & degree(e.head) & (if e.head < 0: "to the left" else: "to the right")
    if e.light != 0: asks.add "move the light on the face " & degree(e.light) &
                              (if e.light < 0: "to the left" else: "to the right")
    if e.hair > 0: asks.add "make the hair " & degree(e.hair) & "thicker"
    elif e.hair < 0: asks.add "make the hair " & degree(e.hair) & "thinner"
    if words.len > 0: asks.add words
    if asks.len == 0:
      status = tr("Smart Portrait: move a slider first")
      return
    tasks.add d.wholeTask("In this portrait, " & asks.join("; ") & ". Keep who the person is, their clothes, " &
                          "the background and the light otherwise.")
  of aeMakeup:
    let others = d.otherDocs
    if others.len == 0:
      status = tr("Makeup Transfer: open the picture of the face whose makeup to take")
      return
    let o = others[clamp(e.source, 0, others.high)]
    var t = d.wholeTask("")
    t.withReference(pictureOfDoc(o, rect(0, 0, o.w, o.h)))
    t.prompt = "Put the makeup of the face on the left -- its eyes, lips, cheeks, its colors -- on the face on the " &
               "right; keep who the right-hand person is, and the rest of the right-hand picture as it is."
    tasks.add t
  of aeLandscape:
    var asks: seq[string]
    if e.season > 0: asks.add "in " & aiSeasons[e.season].toLowerAscii
    if e.time > 0: asks.add "at " & aiTimes[e.time].toLowerAscii
    if e.weather > 0: asks.add "with " & aiWeathers[e.weather].toLowerAscii & " weather"
    if words.len > 0: asks.add words
    if asks.len == 0:
      status = tr("Landscape Mixer: pick a season, a time or the weather first")
      return
    tasks.add d.wholeTask("Show this landscape " & asks.join(", ") & ": the same place, the same view, its " &
                          "light and colors changed to match.")
  aiRun = (nil, d, $e.kind, tasks, 0, (if base.len > 0: base else: newSeq[uint32](W * H)), W, H, newDoc, reveal,
           (if e.kind == aeStyle: e.strength else: 100), false)
  aiNext()

proc aiEditDialog() =
  if not aiEditDlg.open: return
  let d = cur()
  if d == nil:
    aiEditDlg.open = false
    return
  let busy = aiRun.job != nil and aiRun.job.running
  var go = false
  dialog(aiEditDlg.open, tr($aiEditDlg.kind), 480):
    var k = ord(aiEditDlg.kind)
    var names: seq[string]
    for e in AiEdit: names.add tr($e)
    row([110, -1]):
      label "Edit:"
      if combo(names, k, w = dp(240)): aiEditDlg.kind = AiEdit(k)
    paragraph(aiBlurb[aiEditDlg.kind], color = ui.theme.gray)
    let others = d.otherDocs
    var docNames: seq[string]
    for o in others: docNames.add o.name
    case aiEditDlg.kind
    of aeBackground:
      row([110, -1]):
        label "Background:"
        discard edit(aiEditDlg.words, w = dp(320))
    of aeUpscale:
      row([110, -1]):
        label "Size:"
        combo(["2 Times", "4 Times"], aiEditDlg.factor, w = dp(120))
      let k2 = [2, 4][clamp(aiEditDlg.factor, 0, 1)]
      let n = ((d.w * k2 + 895) div 896) * ((d.h * k2 + 895) div 896)
      label($(d.w * k2) & " x " & $(d.h * k2) & "   " & $n & tr(" pictures asked"), color = ui.theme.gray)
    of aeStyle:
      row([110, -1]):
        label "From:"
        combo(["A Style", "Another Picture"], aiEditDlg.source, w = dp(160))
      if aiEditDlg.source == 1:
        row([110, -1]):
          label "Picture:"
          if docNames.len == 0: label("(open another picture)", color = ui.theme.gray)
          else: combo(docNames, aiEditDlg.style, w = dp(240))
      else:
        row([110, -1]):
          label "Style:"
          combo(aiStyles, aiEditDlg.style, w = dp(200))
        row([110, -1]):
          label "Or:"
          discard edit(aiEditDlg.words, w = dp(240))
      checkbox("Keep the colors", aiEditDlg.keepColors)
      optSlider("Strength:", aiEditDlg.strength, 0, 100)
    of aeAngle:
      row([110, -1]):
        label "Camera:"
        combo(aiAngles, aiEditDlg.angle, w = dp(180))
      optSlider("How Far:", aiEditDlg.amount, 5, 90, "°")
    of aeRotate:
      row([110, -1]):
        label "Turn:"
        combo(["Left", "Right", "Up", "Down"], aiEditDlg.turn, w = dp(120))
      optSlider("By:", aiEditDlg.amount, 5, 180, "°")
      if not d.hasSelection: label("Select the thing to turn first.", color = color(200, 40, 40))
    of aeRecompose:
      row([110, -1]):
        label "Frame:"
        combo(aiAspects, aiEditDlg.aspect, w = dp(120))
      row([110, -1]):
        label "Subject:"
        combo(aiPlaces, aiEditDlg.place, w = dp(180))
    of aeAmbient:
      row([110, -1]):
        label "Remove:"
        combo(aiAmbient, aiEditDlg.ambient, w = dp(200))
    of aePortrait:
      optSlider("Happiness:", aiEditDlg.smile, -100, 100)
      optSlider("Facial Age:", aiEditDlg.age, -100, 100)
      optSlider("Eye Direction:", aiEditDlg.gaze, -100, 100)
      optSlider("Head Direction:", aiEditDlg.head, -100, 100)
      optSlider("Light Direction:", aiEditDlg.light, -100, 100)
      optSlider("Hair Thickness:", aiEditDlg.hair, -100, 100)
    of aeMakeup:
      row([110, -1]):
        label "Reference:"
        if docNames.len == 0: label("(open the picture of the face)", color = ui.theme.gray)
        else: combo(docNames, aiEditDlg.source, w = dp(240))
    of aeLandscape:
      row([110, -1]):
        label "Season:"
        combo(aiSeasons, aiEditDlg.season, w = dp(140))
      row([110, -1]):
        label "Time of Day:"
        combo(aiTimes, aiEditDlg.time, w = dp(140))
      row([110, -1]):
        label "Weather:"
        combo(aiWeathers, aiEditDlg.weather, w = dp(140))
    if aiEditDlg.kind in {aeAngle, aeRecompose, aePortrait, aeLandscape}:
      row([110, -1]):
        label "Also:"
        discard edit(aiEditDlg.words, w = dp(320))
    if busy:
      label(status, color = ui.theme.gray)
    row:
      if busy and button("Stop", w = dp(80)): aiRun.stop = true
      spring()
      if button("OK", isDefault = true, w = dp(80), enabled = not busy): go = true
      if button("Close", w = dp(80)): aiEditDlg.open = false
  if go:
    loadImgAi()
    if not imgAi.s.connected:
      status = tr("Connect an image service first: Edit > AI Connector > Pictures")
      return
    d.startAiEdit()

# ---- by the AI service: colors, patterns, shape fills, words, a drawing turned ---------------------------------------

proc parseColors(t: string): seq[uint32] =
  ## (#RRGGBB colors in what the service said)
  var i = 0
  while i < t.len:
    if t[i] == '#' and i + 7 <= t.len:
      let h = t[i + 1 .. i + 6]
      if h.allIt(it in HexDigits):
        result.add 0xFF000000'u32 or uint32(parseHexInt(h))
        i += 7
        continue
    inc i

proc seamless(b: var Bitmap) =
  ## (a tile made to repeat without a seam: blended with itself moved by half, where its edges are)
  let w = b.w
  let h = b.h
  let src = b.px
  for y in 0 ..< h:
    for x in 0 ..< w:
      let ex = float(min(x, w - 1 - x)) / (w / 2)
      let ey = float(min(y, h - 1 - y)) / (h / 2)
      let t = clamp(1 - min(ex, ey) * 3, 0.0, 1.0)     # (1 at the edges, 0 a third of the way in)
      if t > 0:
        b.px[y * w + x] = mixPx(src[y * w + x], src[((y + h div 2) mod h) * w + (x + w div 2) mod w], t * 0.5)

proc textAiDone() =
  let run = textRun
  textRun.job = nil
  let d = run.d
  if d == nil or not docs.anyIt(it.doc == d):
    status = tr("AI: the image was closed meanwhile")
    return
  case run.what
  of 0:
    let (t, err) = onceAnswer(aiDlg.s, run.job)
    if err.len > 0:
      status = tr("Generative Recolor: ") & err
      return
    let pal = parseColors(t)
    if pal.len < 2:
      status = tr("Generative Recolor: the service gave no colors")
      return
    d.recolor(pal, "\"" & run.words & "\"")
  of 3:
    var (t, err) = onceAnswer(aiDlg.s, run.job)
    let L = run.layer
    if err.len > 0:
      status = tr("Rewrite: ") & err
      return
    if L notin d.layers or not L.isText:
      status = tr("Rewrite: the text is gone")
      return
    t = t.strip(chars = Whitespace + {'"', '\'', '`'})
    if t.len == 0: return
    var nt = L.text
    let style = if nt.spans.len > 0: nt.spans[0].style else: CharStyle()
    nt.spans = @[TextSpan(text: t, style: style)]
    d.stepOnce("Rewrite", proc () = d.setText(L, nt))
    d.markAll()
    status = tr("Rewritten: ") & rewriteHow[clamp(textAi.how, 0, rewriteHow.high)]
  else:
    let (svg, err) = vectorAnswer(aiDlg.s, run.job)
    if svg.len == 0:
      status = tr("Turntable: ") & err
      return
    let made = d.placeSvg(svg, run.box)
    if made.len == 0:
      status = tr("Turntable: the answer had no drawing in it")
      return
    made[0].name = tr("Turned ") & $((textAi.turn + 1) * 45) & "°"
    d.markAll()
    status = tr("Turntable: the drawing turned, as a new group")

proc imageAiDone() =
  let r = textRun.img
  textRun.img = nil
  let d = textRun.d
  if d == nil or not docs.anyIt(it.doc == d): return
  if r == nil or not r.done or r.value.picture == nil:
    status = tr("AI: ") & (if r != nil and r.done: r.value.error else: tr("the image service did not answer"))
    return
  var p = r.value.picture
  if textRun.what == 1:
    seamless(p)
    pattern = p.px
    patternW = p.w
    patternH = p.h
    status = tr("Text to Pattern: the pattern is set -- Edit > Fill or Layer > New Fill Layer > Pattern")
  else:
    let S = textRun.layer
    if S notin d.layers: return
    let b = textRun.box
    if p.w != b.w or p.h != b.h: p = scaledBmp(p, b.w, b.h)
    d.layersChange("Generative Shape Fill"):
      let L = d.addLayer(textRun.words.substr(0, 40), above = d.layers.find(S))
      for y in 0 ..< b.h:
        let dy = b.y + y
        if dy < 0 or dy >= d.h: continue
        for x in 0 ..< b.w:
          let dx = b.x + x
          if dx >= 0 and dx < d.w: L.px[dy * d.w + dx] = p.px[y * b.w + x]
      L.clipped = true
      inc L.ver
      d.cur = d.layers.find(L)
    d.markAll()
    status = tr("Generative Shape Fill: a picture in the shape (a clipping mask)")

proc startTextAi(d: Doc) =
  let words = textAi.words.strip
  textRun.d = d
  textRun.what = textAi.what
  textRun.words = words
  case textAi.what
  of 0:
    loadAi()
    if not aiDlg.s.connected:
      status = tr("Connect an AI service first: Edit > AI Connector")
      return
    textRun.job = askOnce(aiDlg.s, "You pick colors for designs. Answer only with five to eight colors as #RRGGBB, " &
                          "separated by spaces, from the darkest to the lightest.",
                          "Colors for: " & (if words.len > 0: words else: "a calm, modern design"), onDone = textAiDone)
  of 1, 2:
    loadImgAi()
    if not imgAi.s.connected:
      status = tr("Connect an image service first: Edit > AI Connector > Pictures")
      return
    let s = imgAi.s
    var w, h: int
    var prompt: string
    if textAi.what == 1:
      (w, h) = (1024, 1024)
      prompt = "A seamless, tiling pattern of " & (if words.len > 0: words else: "small flowers") &
               ", flat and even, filling the whole square; its left edge carries on from its right, its top from " &
               "its bottom."
    else:
      let L = d.current
      if L == nil or not L.isShape:
        status = tr("Generative Shape Fill: pick a shape first")
        return
      let b = d.objectBox(L)
      if not b.ok: return
      textRun.layer = L
      textRun.box = rect(int(b.x0), int(b.y0), max(8, int(b.x1 - b.x0)), max(8, int(b.y1 - b.y0)))
      (w, h) = (textRun.box.w, textRun.box.h)
      prompt = (if words.len > 0: words else: "a rich, detailed texture") & ", filling the whole picture to its edges"
    textRun.img = job(proc (): AiImageAnswer {.gcsafe.} =
      {.cast(gcsafe).}: generateImage(s, prompt, w, h), onDone = imageAiDone)
  of 3:
    let L = d.current
    if L == nil or not L.isText:
      status = tr("Rewrite: pick a type layer first")
      return
    loadAi()
    if not aiDlg.s.connected:
      status = tr("Connect an AI service first: Edit > AI Connector")
      return
    textRun.layer = L
    let how = rewriteHow[clamp(textAi.how, 0, rewriteHow.high)]
    let ask = case textAi.how
              of 7: "Translate this into Arabic"
              of 8: "Translate this into English"
              of 6: "Fix the spelling and grammar of this, changing nothing else"
              else: "Rewrite this to be " & how.toLowerAscii & ", keeping its meaning"
    textRun.job = askOnce(aiDlg.s, "You rewrite text for designs. Answer only with the new text -- no quotes, no notes.",
                          ask & (if words.len > 0: " (" & words & ")" else: "") & ":\n\n" & L.text.plainText,
                          onDone = textAiDone)
  else:
    var idx = d.pickedLayers
    if idx.len == 0: idx = @[d.cur]
    let o = newDoc(d.w, d.h, 0'u32, d.dpi, d.name)
    o.layers.setLen(0)
    var box = (x0: 1e9, y0: 1e9, x1: -1e9, y1: -1e9)
    for i in idx:
      if i < 0 or i >= d.layers.len: continue
      let L = d.layers[i]
      if not (L.isShape or L.isText or L.group): continue
      o.layers.add layerCopy(L, L.name)
      let b = d.objectBox(L)
      if b.ok:
        box = (min(box.x0, b.x0), min(box.y0, b.y0), max(box.x1, b.x1), max(box.y1, b.y1))
    if o.layers.len == 0 or box.x1 <= box.x0:
      status = tr("Turntable: pick the shapes of a drawing first")
      return
    loadAi()
    if not aiDlg.s.connected:
      status = tr("Connect an AI service first: Edit > AI Connector")
      return
    textRun.box = rect(int(box.x1) + 16, int(box.y0), int(box.x1 - box.x0), int(box.y1 - box.y0))
    if textRun.box.x + textRun.box.w > d.w: textRun.box.x = max(0, int(box.x0))
    textRun.job = askVector(aiDlg.s, "Redraw this drawing turned " & $((textAi.turn + 1) * 45) &
                            " degrees round its upright axis, as if seen from the side -- the same thing, its " &
                            "colors and style:\n\n" & o.svgOf(pixels = false), vkSubject, onDone = textAiDone)
  status = tr("AI: asking...")

proc textAiDialog() =
  if not textAi.open: return
  let d = cur()
  if d == nil:
    textAi.open = false
    return
  let title = ["Generative Recolor", "Text to Pattern", "Generative Shape Fill", "Rewrite", "Turntable"][textAi.what]
  var go = false
  dialog(textAi.open, title, 440):
    case textAi.what
    of 0: paragraph("The shapes' and the type's colors made a palette you describe: \"autumn forest\", \"a " &
                    "1970s poster\", \"calm blues\".", color = ui.theme.gray)
    of 1: paragraph("A pattern from words, made to repeat without a seam: the pattern to fill with.",
                    color = ui.theme.gray)
    of 2: paragraph("A picture from words inside the shape picked, as a layer clipped to it.", color = ui.theme.gray)
    of 3: paragraph("The type layer's words written again.", color = ui.theme.gray)
    else: paragraph("The shapes picked drawn again, turned to show their side, beside them.", color = ui.theme.gray)
    if textAi.what == 3:
      row([110, -1]):
        label "How:"
        combo(rewriteHow, textAi.how, w = dp(200))
    if textAi.what == 4:
      row([110, -1]):
        label "Turn:"
        combo(["45°", "90°", "135°", "180°", "225°", "270°", "315°"], textAi.turn, w = dp(100))
    row([110, -1]):
      label(if textAi.what in {3, 4}: "Also:" else: "Words:")
      discard edit(textAi.words, w = dp(280))
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): go = true
      if button("Cancel", w = dp(80)): textAi.open = false
  if go:
    textAi.open = false
    d.startTextAi()

proc aiMoreDialogs() =
  aiEditDialog()
  textAiDialog()

proc aiMoreCommand(name: string): bool =
  let d = cur()
  result = true
  let n = name.strip(chars = {'.'})
  for e in AiEdit:
    if n == $e:
      if d != nil:
        aiEditDlg.kind = e
        aiEditDlg.open = true
      return
  let k = ["Generative Recolor", "Text to Pattern", "Generative Shape Fill", "Rewrite", "Turntable"].find(n)
  if k >= 0:
    if d != nil:
      textAi.what = k
      textAi.open = true
    return
  result = false
