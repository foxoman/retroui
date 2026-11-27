## A ComfyUI server of your own -- on your computer, reached by its address on your network
## (`http://192.168.1.20:8188`) -- making pictures for an app: from words; a picture's part made
## again where a mask says (fill, expand); something taken out (remove: the LaMa model when the
## server has comfyui-inpaint-nodes, else the picture's own model asked for what would be
## behind it). Through ComfyUI's own HTTP API -- `/system_stats`, `/object_info`, `/upload/image`,
## `/prompt`, `/history`, `/view` -- with workflows made here; nothing to install in ComfyUI
## but a checkpoint (and, for Remove at its best, the inpaint nodes and big-lama.pt).
##
## .. code-block:: nim
##   if comfyPing(url) == "":
##     let models = comfyModels(url)                 # the checkpoints it has
##     let a = comfyGenerate(url, models[0], "a lighthouse at dusk", 1600, 1000)
##     let b = comfyFill(url, models[0], "a red umbrella", photo, mask)   # mask clear: made again
##
## Each waits for the server (a job's work: `retroui/jobs`): the picture is sent, the workflow
## queued, its history asked every second until it is done, its picture fetched. Sizes go to the
## server at about a million pixels, in steps of 8, and come back at the size asked.
## `retroui/aiimage` uses it when its service's `kind` is "comfyui".
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net

import std/[json, strutils, random, os, times, uri, math]
import gfx, http, imaging, jpeg

type ComfyAnswer* = object
  picture*: Bitmap               ## the picture made (nil: none)
  error*: string                 ## why there is none ("" there is)

const
  ComfyNegative* = "blurry, lowres, watermark, text, deformed, bad anatomy"
    ## (what a picture is asked not to be)
  RemoveWords* = "empty background, nothing there, seamless, the same surface and light as around it"
    ## (Remove without LaMa: what is asked where the thing was)
  RemoveNegative* = "person, object, animal, text, logo, watermark, frame"

proc fitTo*(b: Bitmap; w, h: int): Bitmap =
  ## `b` scaled to fill `w` x `h`, its middle kept where the shapes differ (each pixel the mean of
  ## those under it). `retroui/aiimage` uses it too.
  if b == nil or w <= 0 or h <= 0: return b
  if b.w == w and b.h == h: return b
  result = Bitmap(w: w, h: h, px: newSeq[uint32](w * h))
  let sc = max(w / b.w, h / b.h)
  let ox = (b.w.float * sc - w.float) / 2
  let oy = (b.h.float * sc - h.float) / 2
  # (each pixel the mean of the source pixels under it: a picture made smaller stays smooth)
  for y in 0 ..< h:
    let sy0 = (y.float + oy) / sc
    let sy1 = (y.float + 1 + oy) / sc
    let ya = clamp(int(sy0), 0, b.h - 1)
    let yb = clamp(max(int(sy1 - 1e-6), ya), 0, b.h - 1)
    for x in 0 ..< w:
      let sx0 = (x.float + ox) / sc
      let sx1 = (x.float + 1 + ox) / sc
      let xa = clamp(int(sx0), 0, b.w - 1)
      let xb = clamp(max(int(sx1 - 1e-6), xa), 0, b.w - 1)
      var a, r, g, bl, n = 0
      for yy in ya .. yb:
        for xx in xa .. xb:
          let p = b.px[yy * b.w + xx]
          a += int(p shr 24); r += int((p shr 16) and 255); g += int((p shr 8) and 255); bl += int(p and 255)
          inc n
      result.px[y * w + x] = (uint32(a div n) shl 24) or (uint32(r div n) shl 16) or
                             (uint32(g div n) shl 8) or uint32(bl div n)

proc comfyBase*(url: string): string =
  ## The server's address as requests take it: no slash at its end, http:// when none was given.
  result = url.strip.strip(leading = false, chars = {'/'})
  if result.len > 0 and "://" notin result: result = "http://" & result

proc getJson(url: string; timeoutSec = 15): tuple[j: JsonNode; error: string] =
  let r = httpRequest("GET", url, timeoutSec = timeoutSec)
  if r.status == 0: return (nil, (if r.error.len > 0: r.error else: "no answer"))
  if r.status >= 400: return (nil, "HTTP " & $r.status)
  try: (parseJson(r.body), "")
  except CatchableError: (nil, "its answer is not JSON")

proc comfyPing*(url: string; timeoutSec = 5): string =
  ## "" when a ComfyUI server answers at `url`, else why not.
  let b = comfyBase(url)
  if b.len == 0: return "no address"
  let (j, e) = getJson(b & "/system_stats", timeoutSec)
  if e.len > 0: return e
  if j.kind != JObject or not j.hasKey("system"): return "it is not a ComfyUI server"
  ""

proc choices(j: JsonNode; node, input: string): seq[string] =
  ## (the names a node's input takes, as /object_info says: the first of its list)
  let spec = j{node}{"input"}{"required"}{input}
  if spec != nil and spec.kind == JArray and spec.len > 0 and spec[0].kind == JArray:
    for v in spec[0].getElems:
      if v.kind == JString: result.add v.getStr

proc comfyModels*(url: string): seq[string] =
  ## The checkpoints the server has (its `models/checkpoints`), as its loader lists them.
  let (j, e) = getJson(comfyBase(url) & "/object_info/CheckpointLoaderSimple")
  if e.len == 0 and j != nil: result = choices(j, "CheckpointLoaderSimple", "ckpt_name")

proc comfyLama*(url: string): string =
  ## The LaMa model the server's inpaint nodes have ("" when it has none, or not the nodes).
  let (j, e) = getJson(comfyBase(url) & "/object_info/INPAINT_LoadInpaintModel")
  if e.len > 0 or j == nil: return ""
  for m in choices(j, "INPAINT_LoadInpaintModel", "model_name"):
    if "lama" in m.toLowerAscii: return m

proc workSize*(w, h: int): tuple[w, h: int] =
  ## The size a picture of `w` x `h` goes to the server at: about a million pixels, its shape
  ## kept, each side a multiple of 8 (256 at least).
  let k = sqrt(1024.0 * 1024.0 / float(max(1, w * h)))
  result.w = max(256, int(round(float(w) * k / 8)) * 8)
  result.h = max(256, int(round(float(h) * k / 8)) * 8)

proc node(cls: string; inputs: JsonNode): JsonNode = %*{"class_type": cls, "inputs": inputs}

proc txt2imgGraph*(ckpt, prompt, negative: string; w, h, seed: int; steps = 25): JsonNode =
  ## The workflow that makes a picture of `w` x `h` from `prompt` with checkpoint `ckpt`.
  %*{
    "4": node("CheckpointLoaderSimple", %*{"ckpt_name": ckpt}),
    "6": node("CLIPTextEncode", %*{"text": prompt, "clip": ["4", 1]}),
    "7": node("CLIPTextEncode", %*{"text": negative, "clip": ["4", 1]}),
    "5": node("EmptyLatentImage", %*{"width": w, "height": h, "batch_size": 1}),
    "3": node("KSampler", %*{"seed": seed, "steps": steps, "cfg": 7.0, "sampler_name": "euler",
                              "scheduler": "normal", "denoise": 1.0, "model": ["4", 0],
                              "positive": ["6", 0], "negative": ["7", 0], "latent_image": ["5", 0]}),
    "8": node("VAEDecode", %*{"samples": ["3", 0], "vae": ["4", 2]}),
    "9": node("SaveImage", %*{"filename_prefix": "retroui", "images": ["8", 0]})}

proc inpaintGraph*(ckpt, image, prompt, negative: string; seed: int; steps = 25): JsonNode =
  ## The workflow that makes `image` (a picture the server has, its clear part the mask) again
  ## where it is clear, as `prompt` says.
  %*{
    "4": node("CheckpointLoaderSimple", %*{"ckpt_name": ckpt}),
    "6": node("CLIPTextEncode", %*{"text": prompt, "clip": ["4", 1]}),
    "7": node("CLIPTextEncode", %*{"text": negative, "clip": ["4", 1]}),
    "10": node("LoadImage", %*{"image": image}),
    "11": node("VAEEncodeForInpaint", %*{"pixels": ["10", 0], "vae": ["4", 2], "mask": ["10", 1],
                                         "grow_mask_by": 8}),
    "3": node("KSampler", %*{"seed": seed, "steps": steps, "cfg": 7.0, "sampler_name": "euler",
                              "scheduler": "normal", "denoise": 1.0, "model": ["4", 0],
                              "positive": ["6", 0], "negative": ["7", 0], "latent_image": ["11", 0]}),
    "8": node("VAEDecode", %*{"samples": ["3", 0], "vae": ["4", 2]}),
    "9": node("SaveImage", %*{"filename_prefix": "retroui", "images": ["8", 0]})}

proc lamaGraph*(lama, image: string; seed: int): JsonNode =
  ## The workflow that takes out what is under `image`'s clear part with the LaMa model `lama`
  ## (comfyui-inpaint-nodes).
  %*{
    "1": node("LoadImage", %*{"image": image}),
    "2": node("INPAINT_LoadInpaintModel", %*{"model_name": lama}),
    "3": node("INPAINT_InpaintWithModel", %*{"inpaint_model": ["2", 0], "image": ["1", 0],
                                             "mask": ["1", 1], "seed": seed}),
    "4": node("SaveImage", %*{"filename_prefix": "retroui", "images": ["3", 0]})}

proc formFile(name, fileName, data: string; fields: openArray[(string, string)]): tuple[body, contentType: string] =
  const boundary = "----retroui-comfy-5b81e2a94c"
  var b = ""
  for (k, v) in fields:
    b.add "--" & boundary & "\r\nContent-Disposition: form-data; name=\"" & k & "\"\r\n\r\n" & v & "\r\n"
  b.add "--" & boundary & "\r\nContent-Disposition: form-data; name=\"" & name & "\"; filename=\"" &
        fileName & "\"\r\nContent-Type: image/png\r\n\r\n" & data & "\r\n--" & boundary & "--\r\n"
  (b, "multipart/form-data; boundary=" & boundary)

proc upload(base, fileName, png: string): tuple[name, error: string] =
  ## (a picture sent to the server's input folder: the name its LoadImage takes)
  let (body, ct) = formFile("image", fileName, png, [("type", "input"), ("overwrite", "true")])
  let r = httpRequest("POST", base & "/upload/image", @[("Content-Type", ct)], body, timeoutSec = 60)
  if r.status == 0: return ("", if r.error.len > 0: r.error else: "no answer")
  if r.status >= 400: return ("", "the picture was not taken: HTTP " & $r.status)
  try:
    let j = parseJson(r.body)
    let sub = j{"subfolder"}.getStr
    result.name = (if sub.len > 0: sub & "/" else: "") & j{"name"}.getStr
    if result.name.len == 0: result.error = "the server named no picture"
  except CatchableError: result.error = "the server's answer is not JSON"

proc picOf(data: string): Bitmap =
  if data.len > 3 and data[0] == '\xFF' and data[1] == '\xD8': decodeJpeg(data) else: decodePng(data)

proc runGraph*(url: string; graph: JsonNode; timeoutSec = 300): ComfyAnswer =
  ## Queues `graph` on the server, waits for it (its history asked every second, `timeoutSec` at
  ## most) and fetches the first picture it saved.
  let base = comfyBase(url)
  let r = httpRequest("POST", base & "/prompt", @[("Content-Type", "application/json")],
                      $(%*{"prompt": graph, "client_id": "retroui"}), timeoutSec = 30)
  if r.status == 0: return ComfyAnswer(error: if r.error.len > 0: r.error else: "no answer")
  let j = try: parseJson(r.body) except CatchableError: nil
  if r.status >= 400 or j == nil or j{"prompt_id"}.getStr.len == 0:
    var why = "the server did not take the work"
    if j != nil and j{"error"} != nil:
      why = j{"error"}{"message"}.getStr(why)
      let detail = j{"error"}{"details"}.getStr
      if detail.len > 0: why.add ": " & detail
    return ComfyAnswer(error: why)
  let id = j{"prompt_id"}.getStr
  let until = epochTime() + float(timeoutSec)
  while epochTime() < until:
    sleep(1000)
    let (h, e) = getJson(base & "/history/" & id)
    if e.len > 0 or h == nil or not h.hasKey(id): continue
    let entry = h[id]
    let st = entry{"status"}{"status_str"}.getStr
    if st == "error":
      var why = "the work failed on the server"
      for m in entry{"status"}{"messages"}.getElems:
        if m.kind == JArray and m.len >= 2 and m[0].getStr == "execution_error":
          why = m[1]{"exception_message"}.getStr(why).strip
      return ComfyAnswer(error: why)
    let outs = entry{"outputs"}
    if outs == nil or outs.kind != JObject: continue
    for _, o in outs.pairs:
      for im in o{"images"}.getElems:
        let q = "filename=" & encodeUrl(im{"filename"}.getStr) & "&subfolder=" & encodeUrl(im{"subfolder"}.getStr) &
                "&type=" & encodeUrl(im{"type"}.getStr("output"))
        let v = httpRequest("GET", base & "/view?" & q, timeoutSec = 60)
        if v.status != 200: return ComfyAnswer(error: "its picture could not be fetched: HTTP " & $v.status)
        let p = picOf(v.body)
        if p == nil: return ComfyAnswer(error: "its picture could not be read")
        return ComfyAnswer(picture: p)
    if entry{"status"}{"completed"}.getBool: return ComfyAnswer(error: "the work saved no picture")
  ComfyAnswer(error: "the server took longer than " & $timeoutSec & " seconds")

proc pickModel(url, ckpt: string): string =
  if ckpt.strip.len > 0: return ckpt.strip
  let ms = comfyModels(url)
  if ms.len > 0: ms[0] else: ""

proc comfyGenerate*(url, ckpt, prompt: string; w, h: int; timeoutSec = 300): ComfyAnswer =
  ## A picture of `w` x `h` as `prompt` describes it, with checkpoint `ckpt` (""; the server's
  ## first).
  let m = pickModel(url, ckpt)
  if m.len == 0: return ComfyAnswer(error: "the server has no checkpoint (models/checkpoints)")
  let (sw, sh) = workSize(w, h)
  result = runGraph(url, txt2imgGraph(m, prompt, ComfyNegative, sw, sh, rand(int32.high.int)), timeoutSec)
  if result.picture != nil: result.picture = fitTo(result.picture, w, h)

proc maskedPng(image, mask: Bitmap; w, h: int): string =
  ## (`image` at `w` x `h`, clear where `mask` is: ComfyUI's LoadImage takes the clear part as
  ## its mask)
  let img = fitTo(image, w, h)
  let m = fitTo(mask, w, h)
  var b = Bitmap(w: w, h: h, px: newSeq[uint32](w * h))
  for i in 0 ..< w * h:
    let keep = (m.px[i] shr 24) >= 128
    b.px[i] = if keep: img.px[i] or 0xFF000000'u32 else: img.px[i] and 0x00FFFFFF'u32
  encodePng(b, level = 3, alpha = 1)

proc comfyFill*(url, ckpt, prompt: string; image, mask: Bitmap; remove = false;
                timeoutSec = 300): ComfyAnswer =
  ## `image` made again where `mask` is clear (alpha 0), as `prompt` says -- or, `remove`, what is
  ## there taken out (LaMa when the server has it). The answer at `image`'s size.
  if image == nil or mask == nil or image.w <= 0 or mask.w != image.w or mask.h != image.h:
    return ComfyAnswer(error: "the picture and its mask are not the same size")
  let base = comfyBase(url)
  let (sw, sh) = workSize(image.w, image.h)
  let (name, e) = upload(base, "retroui-" & $rand(1_000_000) & ".png", maskedPng(image, mask, sw, sh))
  if e.len > 0: return ComfyAnswer(error: e)
  let lama = if remove: comfyLama(url) else: ""
  var a: ComfyAnswer
  if lama.len > 0:
    a = runGraph(url, lamaGraph(lama, name, rand(int32.high.int)), timeoutSec)
  else:
    let m = pickModel(url, ckpt)
    if m.len == 0: return ComfyAnswer(error: "the server has no checkpoint (models/checkpoints)")
    let words = if remove or prompt.strip.len == 0: RemoveWords else: prompt
    a = runGraph(url, inpaintGraph(m, name, words, if remove: RemoveNegative else: ComfyNegative,
                                   rand(int32.high.int)), timeoutSec)
  if a.picture != nil: a.picture = fitTo(a.picture, image.w, image.h)
  a
