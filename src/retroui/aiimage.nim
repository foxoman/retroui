## Pictures from words, and a picture changed where a mask says, by an image service of your
## own -- any that speaks OpenAI's images API (OpenAI's own, or a server on your computer that
## takes the same requests). Off until you set one; nothing is sent before. What an app makes
## of them: a new picture or layer from a description, a selection filled ("generative fill"),
## a canvas grown with what would be round it ("expand"), something taken out ("remove").
##
## .. code-block:: nim
##   let s = loadAiImageSettings("photo")
##   let a = generateImage(s, "a lighthouse at dusk, oil painting", 1600, 1000)
##   if a.error.len == 0: addLayerFrom(a.picture)
##   # the part of `photo` where `mask` is clear made again, as `prompt` says
##   let b = editImage(s, "a red umbrella", photo, mask)
##
## Both wait for the service (a job's work: `retroui/jobs`). The service makes a few sizes
## only (1024 x 1024, 1536 x 1024, 1024 x 1536): the nearest in shape is asked and the
## picture comes back at the size asked. The key is kept in `retroui/secrets`.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, strutils, base64]
import gfx, http, imaging, jpeg, platform, secrets

type
  AiImageSettings* = object
    ## An image service (empty `url`: none).
    url*: string                 ## its images address (".../v1/images/generations"; edits next to it)
    model*: string               ## the model asked ("gpt-image-1", "dall-e-2"...)
    key*: string                 ## your key for it
    timeoutSec*: int             ## (0: 180)

  AiImageAnswer* = object
    ## What came back.
    picture*: Bitmap             ## the picture, at the size asked (nil: none)
    note*: string                ## what the service said of it (its revised prompt)
    error*: string               ## why there is none ("" there is)

const DefaultImageUrl* = "https://api.openai.com/v1/images/generations"
  ## OpenAI's images address.

proc connected*(s: AiImageSettings): bool =
  ## A service is set.
  s.url.strip.len > 0 and s.model.strip.len > 0

proc editsUrl*(s: AiImageSettings): string =
  ## The address that changes a picture (next to the one that makes them).
  let u = s.url.strip
  if u.endsWith("/generations"): u[0 ..< u.len - "generations".len] & "edits"
  elif u.endsWith("/"): u & "edits"
  else: u.rsplit('/', 1)[0] & "/edits"

proc serviceSize*(w, h: int): tuple[w, h: int] =
  ## The size the service is asked for a picture of `w` x `h`: the nearest of its shapes.
  if w * 5 > h * 6: (1536, 1024)
  elif h * 5 > w * 6: (1024, 1536)
  else: (1024, 1024)

proc headersOf(s: AiImageSettings): seq[(string, string)] =
  if s.key.len > 0: result.add ("Authorization", "Bearer " & s.key)

proc imageRequest*(s: AiImageSettings; prompt: string; w, h: int):
    tuple[url: string; headers: seq[(string, string)]; body: string] =
  ## The request for a new picture of about `w` x `h`.
  let (sw, sh) = serviceSize(w, h)
  result.url = s.url.strip
  result.headers = s.headersOf & @[("Content-Type", "application/json")]
  var body = %*{"model": s.model, "prompt": prompt, "n": 1, "size": $sw & "x" & $sh}
  # (DALL-E answers with a link unless asked for the bytes; the newer models always send them)
  if s.model.startsWith("dall-e"): body["response_format"] = %"b64_json"
  result.body = $body

proc fitTo(b: Bitmap; w, h: int): Bitmap =
  ## (`b` scaled to fill `w` x `h`, its middle kept where the shapes differ)
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

proc multipart(fields: openArray[(string, string)]; files: openArray[(string, string, string)]):
    tuple[body, contentType: string] =
  ## (a form with files: `files` as name, file name, bytes)
  const boundary = "----retroui-form-7d3f9a2c1b5e8064"
  var b = ""
  for (k, v) in fields:
    b.add "--" & boundary & "\r\nContent-Disposition: form-data; name=\"" & k & "\"\r\n\r\n" & v & "\r\n"
  for (k, name, data) in files:
    b.add "--" & boundary & "\r\nContent-Disposition: form-data; name=\"" & k & "\"; filename=\"" & name &
          "\"\r\nContent-Type: image/png\r\n\r\n"
    b.add data
    b.add "\r\n"
  b.add "--" & boundary & "--\r\n"
  (b, "multipart/form-data; boundary=" & boundary)

proc editRequest*(s: AiImageSettings; prompt: string; image, mask: Bitmap):
    tuple[url: string; headers: seq[(string, string)]; body: string] =
  ## The request that makes `image` again where `mask` is clear (its alpha 0), as `prompt`
  ## says. Both go at the service's size.
  let (sw, sh) = serviceSize(image.w, image.h)
  let img = fitTo(image, sw, sh)
  let m = fitTo(mask, sw, sh)
  var fields = @[("model", s.model), ("prompt", prompt), ("n", "1"), ("size", $sw & "x" & $sh)]
  if s.model.startsWith("dall-e"): fields.add ("response_format", "b64_json")
  let (body, ct) = multipart(fields, [("image", "image.png", encodePng(img, level = 3, alpha = 1)),
                                      ("mask", "mask.png", encodePng(m, level = 3, alpha = 1))])
  result.url = s.editsUrl
  result.headers = s.headersOf & @[("Content-Type", ct)]
  result.body = body

proc pictureOfBytes(data: string): Bitmap =
  if data.len > 3 and data[0] == '\xFF' and data[1] == '\xD8': decodeJpeg(data)
  else: decodePng(data)

proc imageReply*(body: string; w, h: int): AiImageAnswer =
  ## The picture in the service's answer, at `w` x `h`, or why there is none.
  let j = try: parseJson(body) except CatchableError: nil
  if j == nil or j.kind != JObject: return AiImageAnswer(error: "the service's answer is not JSON")
  if j.hasKey("error"):
    let e = j["error"]
    return AiImageAnswer(error: if e.kind == JObject: e{"message"}.getStr($e) else: $e)
  for d in j{"data"}.getElems:
    let b64 = d{"b64_json"}.getStr
    if b64.len == 0: continue
    var bytes = ""
    try: bytes = base64.decode(b64)
    except ValueError: return AiImageAnswer(error: "the service's picture could not be read")
    let p = pictureOfBytes(bytes)
    if p == nil or p.w <= 0: return AiImageAnswer(error: "the service's picture could not be read")
    return AiImageAnswer(picture: fitTo(p, w, h), note: d{"revised_prompt"}.getStr)
  AiImageAnswer(error: "the service sent no picture")

proc send(s: AiImageSettings; r: tuple[url: string; headers: seq[(string, string)]; body: string];
          w, h: int): AiImageAnswer =
  let resp = httpRequest("POST", r.url, r.headers, r.body, timeoutSec = (if s.timeoutSec > 0: s.timeoutSec else: 180))
  if resp.status == 0: return AiImageAnswer(error: resp.error)
  result = imageReply(resp.body, w, h)
  if result.error.len > 0 and resp.status >= 400: result.error = "HTTP " & $resp.status & ": " & result.error

proc generateImage*(s: AiImageSettings; prompt: string; w, h: int): AiImageAnswer =
  ## A new picture of `w` x `h` as `prompt` describes it (waits for the service).
  if not s.connected: return AiImageAnswer(error: "no image service is set")
  if prompt.strip.len == 0: return AiImageAnswer(error: "nothing was described")
  s.send(s.imageRequest(prompt, w, h), w, h)

proc editImage*(s: AiImageSettings; prompt: string; image, mask: Bitmap): AiImageAnswer =
  ## `image` made again where `mask` is clear (alpha 0), as `prompt` says; the rest as it
  ## was, as near as the service keeps it (an app lays the answer over the original through
  ## the same mask). The answer at `image`'s size.
  if not s.connected: return AiImageAnswer(error: "no image service is set")
  if image == nil or mask == nil or image.w <= 0 or mask.w != image.w or mask.h != image.h:
    return AiImageAnswer(error: "the picture and its mask are not the same size")
  s.send(s.editRequest(prompt, image, mask), image.w, image.h)

const AiImageKeyName* = "AI image key"
  ## The name the image service's key is kept under in `retroui/secrets`.

proc saveAiImageSettings*(app: string; s: AiImageSettings): bool {.discardable.} =
  ## Keeps the image service for `app`: address and model in its settings, the key in the
  ## keyring (empty: forgotten).
  var st = loadSettings(app)
  st["aiimage.url"] = s.url
  st["aiimage.model"] = s.model
  if s.timeoutSec > 0: st["aiimage.timeout"] = $s.timeoutSec
  else: st.del "aiimage.timeout"
  result = saveSettings(app, st)
  if s.key.len > 0: result = saveSecret(app, AiImageKeyName, s.key) and result
  else: deleteSecret(app, AiImageKeyName)

proc loadAiImageSettings*(app: string; withKey = true): AiImageSettings =
  ## The image service kept for `app` (none: not connected); its key asked of the keyring
  ## only `withKey`.
  let st = loadSettings(app)
  result.url = st.getOrDefault("aiimage.url")
  result.model = st.getOrDefault("aiimage.model")
  try: result.timeoutSec = clamp(parseInt(st.getOrDefault("aiimage.timeout", "0")), 0, 900)
  except ValueError: discard
  if withKey: result.key = loadSecret(app, AiImageKeyName)
