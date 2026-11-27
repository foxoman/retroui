## Mutation fuzzer for the decoders and parsers of retro: damaged copies of
## the files in a folder of seeds go through the PNG, BMP and JPEG decoders,
## inflate, the zip reader, the Markdown parser, the big-file reader and the music files' tags.
## A Defect (index, range, overflow...) or a crash is a bug; a
## CatchableError is the decoder rejecting bad input, which is fine.
##
##   nim c -d:release --stackTrace:on --lineTrace:on tests/fuzz/fuzz.nim
##   tests/fuzz/fuzz tests/fuzz/seeds 20000            # every target
##   tests/fuzz/fuzz tests/fuzz/seeds 50000 jpg 7      # one target, one seed
##
## Inputs that crash are saved as crash-*.bin in the current folder.

import std/[os, random, strutils, tables, sets, times]
import retroui/[imaging, jpeg, codec, zip, markdown, gfx, textfile, audiotags]

let here = paramStr(1)
let iters = if paramCount() >= 2: parseInt(paramStr(2)) else: 20000
let only = if paramCount() >= 3: paramStr(3) else: ""
randomize(if paramCount() >= 4: parseInt(paramStr(4)) else: int(epochTime() * 1000) mod 100000)

var seen: HashSet[string]
var bugs = 0

proc report(target: string; e: ref Exception; input: string) =
  let tr = e.getStackTrace()
  var key = target & ":" & $e.name
  for line in tr.splitLines:
    if "retro" in line and "fuzz.nim" notin line:
      key = target & ":" & $e.name & ":" & line.strip
  if key in seen: return
  seen.incl key
  inc bugs
  let f = getCurrentDir() / ("crash-" & $bugs & "-" & target & ".bin")
  writeFile(f, input)
  echo "BUG ", target, " ", e.name, ": ", e.msg
  echo tr
  echo "   saved ", f

proc fixPngCrcs(s: var string) =
  var p = 8
  while p + 12 <= s.len:
    let n = (ord(s[p]) shl 24) or (ord(s[p+1]) shl 16) or (ord(s[p+2]) shl 8) or ord(s[p+3])
    if n < 0 or p + 12 + n > s.len: break
    let c = crc32(toBytes(s[p + 4 ..< p + 8 + n]))
    s[p + 8 + n] = char((c shr 24) and 255)
    s[p + 9 + n] = char((c shr 16) and 255)
    s[p + 10 + n] = char((c shr 8) and 255)
    s[p + 11 + n] = char(c and 255)
    p += 12 + n

proc mutate(s: string): string =
  result = s
  let n = rand(1 .. 8)
  for _ in 0 ..< n:
    if result.len == 0: result = "\0"
    case rand(9)
    of 0, 1:
      let i = rand(result.high)
      result[i] = char(ord(result[i]) xor (1 shl rand(7)))
    of 2:
      result[rand(result.high)] = char(rand(255))
    of 3:
      result[rand(result.high)] = sample(['\0', '\1', '\x7F', '\x80', '\xFF', '\x10', '\x08'])
    of 4:
      if result.len >= 4:
        let i = rand(result.len - 4)
        let v = sample([0x7FFFFFFF'u32, 0xFFFFFFFF'u32, 0x10000'u32, 0'u32, 0x8000'u32,
                        0xFFFF'u32, 1'u32, 0x40000000'u32])
        if rand(1) == 0:
          for k in 0 .. 3: result[i + k] = char((v shr (24 - 8 * k)) and 255)
        else:
          for k in 0 .. 3: result[i + k] = char((v shr (8 * k)) and 255)
    of 5:
      result.setLen(rand(result.len))
    of 6:
      if result.len > 2:
        let a = rand(result.high)
        let b = min(result.len, a + rand(64))
        result.insert(result[a ..< b], rand(result.len))
    of 7:
      if result.len > 2:
        let a = rand(result.high)
        let b = min(result.len, a + rand(64))
        result.delete(a ..< b)
    else:
      if result.len >= 2:
        let i = rand(result.len - 2)
        let v = sample([0xFFFF, 0, 0x8000, 0x7FFF, 1, 0xFF00])
        result[i] = char(v shr 8)
        result[i + 1] = char(v and 255)

var seeds: Table[string, seq[string]]
for kind, p in walkDir(here):
  if kind != pcFile or p.extractFilename.startsWith("crash") or
     p.extractFilename.startsWith("last"): continue
  let e = p.splitFile.ext.toLowerAscii
  if e in [".png", ".jpg", ".bmp", ".zip", ".md"]:
    seeds.mgetOrPut(e, @[]).add readFile(p)
  elif e in [".mp3", ".flac", ".m4a", ".opus", ".ogg", ".wav"]:
    seeds.mgetOrPut(".audio", @[]).add readFile(p)

let tmpFile = getTempDir() / "retro-fuzz-input.bin"   # (the file-based targets read it)

proc run(target, input: string) =
  writeFile(tmpFile, input)
  try:
    case target
    of "png": discard decodePng(input)
    of "bmp": discard decodeBmp(input)
    of "jpg": discard decodeJpeg(input)
    of "jpg8": discard decodeJpeg(input, 8)
    of "jpgsize": discard jpegSize(input)
    of "size": discard pictureSize(tmpFile)
    of "load": discard loadPicture(tmpFile, 64, 64)
    of "inflate": discard zlibDecompress(toBytes(input))
    of "zip":
      for e in zipEntries(tmpFile):
        try: discard readEntry(tmpFile, e) except CatchableError: discard
    of "md": discard parseMarkdown(input)
    of "tags":
      discard readAudioTagsFrom(input)
      discard readAudioTags(tmpFile, picture = false)
    of "text":
      let t = openTextFile(tmpFile)
      while not t.done: t.index(5)
      for i in 0 ..< min(t.lineCount, 50): discard t.line(i)
      discard t.line(-1)
      discard t.line(t.lineCount + 5)
      t.close()
      let h = openHexFile(tmpFile)
      for i in 0 ..< min(h.lineCount, 20): discard h.line(i)
      h.close()
    else: discard
  except CatchableError:
    discard
  except Defect as e:
    report(target, e, input)

# the seeds must decode
for s in seeds.getOrDefault(".png"): doAssert decodePng(s).w > 0
for s in seeds.getOrDefault(".bmp"): doAssert decodeBmp(s).w > 0
for s in seeds.getOrDefault(".jpg"): doAssert decodeJpeg(s).w > 0

let plan = [("png", ".png"), ("bmp", ".bmp"), ("jpg", ".jpg"), ("jpg8", ".jpg"),
            ("jpgsize", ".jpg"), ("size", ".png"), ("size", ".jpg"), ("size", ".bmp"),
            ("load", ".png"), ("load", ".jpg"), ("inflate", ".zip"), ("zip", ".zip"),
            ("md", ".md"), ("text", ".md"), ("tags", ".audio")]
let t0 = epochTime()
for (target, ext) in plan:
  if only.len > 0 and target != only: continue
  let ss = seeds.getOrDefault(ext)
  if ss.len == 0: continue
  for i in 0 ..< iters:
    var input = mutate(sample(ss))
    if ext == ".png" and rand(1) == 0: fixPngCrcs(input)
    if target == "inflate":
      # deflate data: a zlib stream of a seed, mutated
      var z = ""
      for b in zlibCompress(toBytes(sample(ss))): z.add char(b)
      input = mutate(z)
    run(target, input)
  echo target, " ", ext, " done (", formatFloat(epochTime() - t0, ffDecimal, 1), " s)"
echo "bugs: ", bugs
removeFile(tmpFile)
