## Tests of retroui/comfyui (and retroui/aiimage with a ComfyUI server) against a made-up ComfyUI
## on this computer: found (its checkpoints, its LaMa), a picture from words (the workflow it got:
## the checkpoint, the words, a size in steps of 8), a fill (the picture sent clear where the mask
## is, the inpaint workflow), a remove (LaMa's workflow when it has it), a work that failed on the
## server (its words said), no server (said); the work size; the address as typed.

import std/[net, json, strutils, os, locks]
import retroui, retroui/[comfyui, aiimage, imaging, http]

var passed = 0
template check(cond: bool; what: string) =
  doAssert cond, what
  inc passed
  echo "  ok   ", what

# ---- the made-up server ----------------------------------------------------------------------------------

var
  seenLock: Lock
  graphs: seq[string]               ## (the workflows it was given, as JSON)
  uploads: seq[string]              ## (the pictures sent to it)
  failNext = false                  ## (the next work fails on it)
  withLama = true
initLock(seenLock)

proc pngOf(w, h: int; c: uint32): string =
  var b = Bitmap(w: w, h: h, px: newSeq[uint32](w * h))
  for i in 0 ..< w * h: b.px[i] = c
  encodePng(b)

proc answer(c: Socket; status: string; body: string; ct = "application/json") =
  c.send("HTTP/1.1 " & status & "\r\nContent-Type: " & ct & "\r\nContent-Length: " & $body.len &
         "\r\nConnection: close\r\n\r\n" & body)

proc serve(s: Socket) {.thread.} =
  {.cast(gcsafe).}:
    var failing = false
    while true:
      var c: Socket
      try: s.accept(c)
      except CatchableError: break
      var req = ""
      while "\r\n\r\n" notin req:
        let ch = c.recv(1)
        if ch.len == 0: break
        req.add ch
      var n = 0
      for line in req.splitLines:
        if line.toLowerAscii.startsWith("content-length:"): n = parseInt(line.split(':')[1].strip)
      var body = ""
      while body.len < n:
        let part = c.recv(n - body.len)
        if part.len == 0: break
        body.add part
      let first = req.splitLines[0].split(' ')
      let path = if first.len > 1: first[1] else: ""
      if path == "/quit":
        c.answer("200 OK", "{}")
        c.close()
        break
      if path == "/system_stats": c.answer("200 OK", $(%*{"system": {"os": "posix"}, "devices": []}))
      elif path == "/object_info/CheckpointLoaderSimple":
        c.answer("200 OK", $(%*{"CheckpointLoaderSimple": {"input": {"required": {"ckpt_name":
                 [["dreams-v1.safetensors", "inpaint-v2.safetensors"]]}}}}))
      elif path == "/object_info/INPAINT_LoadInpaintModel":
        if withLama:
          c.answer("200 OK", $(%*{"INPAINT_LoadInpaintModel": {"input": {"required": {"model_name":
                   [["MAT_Places512_G_fp16.safetensors", "big-lama.pt"]]}}}}))
        else: c.answer("200 OK", "{}")
      elif path == "/upload/image":
        withLock seenLock: uploads.add body
        c.answer("200 OK", $(%*{"name": "retroui-in.png", "subfolder": "", "type": "input"}))
      elif path == "/prompt":
        withLock seenLock:
          graphs.add body
          failing = failNext
        c.answer("200 OK", $(%*{"prompt_id": "p" & $graphs.len, "number": 1, "node_errors": {}}))
      elif path.startsWith("/history/"):
        let id = path[9 .. ^1]
        if failing:
          c.answer("200 OK", $(%*{id: {"outputs": {}, "status": {"status_str": "error", "completed": false,
            "messages": [["execution_error", {"exception_message": "Out of memory on the device"}]]}}}))
        else:
          c.answer("200 OK", $(%*{id: {"outputs": {"9": {"images": [{"filename": "retroui_0001.png",
            "subfolder": "", "type": "output"}]}}, "status": {"status_str": "success", "completed": true}}}))
      elif path.startsWith("/view?"): c.answer("200 OK", pngOf(64, 40, 0xFF3366CC'u32), "image/png")
      else: c.answer("404 Not Found", "{}")
      c.close()

var srv = newSocket()
srv.setSockOpt(OptReuseAddr, true)
srv.bindAddr(Port(0), "127.0.0.1")
srv.listen()
let port = srv.getLocalAddr()[1]
var th: Thread[Socket]
createThread(th, serve, srv)
let url = "127.0.0.1:" & $port & "/"

# ---- found ----------------------------------------------------------------------------------------------------

check comfyBase(" 192.168.1.20:8188/ ") == "http://192.168.1.20:8188", "the address as typed: http, no slash at its end"
check workSize(1600, 1000) == (1296, 808) and workSize(1600, 1000).w mod 8 == 0, "the work size: about a million pixels, in 8s"
check comfyPing(url) == "", "a ComfyUI server found"
check comfyModels(url) == @["dreams-v1.safetensors", "inpaint-v2.safetensors"], "its checkpoints"
check comfyLama(url) == "big-lama.pt", "its LaMa"
check comfyPing("127.0.0.1:1").len > 0, "no server: said why"

# ---- from words -----------------------------------------------------------------------------------------------

let a = comfyGenerate(url, "", "a lighthouse at dusk", 1600, 1000)
check a.error == "" and a.picture != nil and a.picture.w == 1600 and a.picture.h == 1000,
      "a picture from words, at the size asked: " & a.error
var g = parseJson(graphs[^1])
check g{"prompt"}{"4"}{"inputs"}{"ckpt_name"}.getStr == "dreams-v1.safetensors", "no checkpoint chosen: its first"
check g{"prompt"}{"6"}{"inputs"}{"text"}.getStr == "a lighthouse at dusk" and
      g{"prompt"}{"5"}{"inputs"}{"width"}.getInt == 1296, "the workflow: the words, the work size"

# ---- fill, remove ---------------------------------------------------------------------------------------------

var img = Bitmap(w: 200, h: 100, px: newSeq[uint32](200 * 100))
var mask = Bitmap(w: 200, h: 100, px: newSeq[uint32](200 * 100))
for i in 0 ..< img.px.len:
  img.px[i] = 0xFF808080'u32
  mask.px[i] = if (i mod 200) < 100: 0xFF000000'u32 else: 0'u32     # (its right half to make again)
let f = comfyFill(url, "inpaint-v2.safetensors", "a red umbrella", img, mask)
check f.error == "" and f.picture != nil and f.picture.w == 200 and f.picture.h == 100, "a fill, at the picture's size"
g = parseJson(graphs[^1])
check g{"prompt"}{"11"}{"class_type"}.getStr == "VAEEncodeForInpaint" and
      g{"prompt"}{"10"}{"inputs"}{"image"}.getStr == "retroui-in.png" and
      g{"prompt"}{"4"}{"inputs"}{"ckpt_name"}.getStr == "inpaint-v2.safetensors" and
      g{"prompt"}{"6"}{"inputs"}{"text"}.getStr == "a red umbrella", "the inpaint workflow, the picture sent"
let up = uploads[^1]
let pngAt = up.find("\x89PNG")
let sent = decodePng(up[pngAt .. ^1])
check sent != nil and (sent.px[0] shr 24) == 255 and (sent.px[sent.w - 1] shr 24) == 0,
      "the picture sent clear where the mask is: ComfyUI's mask"
let r = comfyFill(url, "", "", img, mask, remove = true)
g = parseJson(graphs[^1])
check r.error == "" and g{"prompt"}{"2"}{"inputs"}{"model_name"}.getStr == "big-lama.pt", "Remove: LaMa, when it has it"
withLama = false
discard comfyFill(url, "", "", img, mask, remove = true)
g = parseJson(graphs[^1])
check g{"prompt"}{"6"}{"inputs"}{"text"}.getStr == RemoveWords, "Remove without LaMa: the model asked for what is behind"
withLama = true

# ---- through retroui/aiimage ------------------------------------------------------------------------------------

let s = AiImageSettings(kind: "comfyui", url: url)
check s.connected and s.comfy, "a ComfyUI service: its address is enough"
check generateImage(s, "a boat", 300, 200).picture.w == 300, "generateImage through it"
check editImage(s, "sand", img, mask).picture.w == 200, "editImage through it"
check removeFromImage(s, img, mask).error == "", "removeFromImage through it"
failNext = true
let bad = generateImage(s, "a boat", 300, 200)
check bad.picture == nil and "Out of memory" in bad.error, "a work that failed on the server: its words"
failNext = false
discard saveAiImageSettings("comfytest", s)
let kept = loadAiImageSettings("comfytest", withKey = false)
check kept.kind == "comfyui" and kept.url == url, "kept: the kind, the address"

discard httpRequest("GET", "http://127.0.0.1:" & $port & "/quit", timeoutSec = 5)
joinThread(th)
srv.close()
echo "comfyui: ", passed, " ok"
