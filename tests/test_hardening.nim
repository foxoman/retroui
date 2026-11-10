## Bugs found by hard-testing the toolkit (sanitizers, random input, odd
## looks), kept fixed, headless.

import std/[os, strutils, random]
import retroui
import retroui/[zip, photo, jxl, exr, morepictures, gltf, sign, codec]
import retroui/uirelays/[screen, services]
import harness

fakeDriver()
startApp("hardening", 640, 480)

# The bytes the C heap has given out (glibc, with -d:useMalloc as the tests
# are built): what a leak makes grow. 0 where it cannot be told (another C
# library, or a sanitizer's malloc -- LeakSanitizer tells it there).
when defined(linux) and defined(useMalloc) and not defined(android):
  type MallInfo2 {.importc: "struct mallinfo2", header: "<malloc.h>".} = object
    uordblks: csize_t
  proc mallinfo2(): MallInfo2 {.importc, header: "<malloc.h>".}
  proc heapInUse(): int = int(mallinfo2().uordblks)
else:
  proc heapInUse(): int = 0

template leaksNot(what: string; rounds: int; body: untyped) =
  ## `body` run `rounds` times keeps the heap where it was (give or take).
  for _ in 0 ..< 3: body                       # (caches and first growth)
  let before = heapInUse()
  for _ in 0 ..< rounds: body
  let grew = heapInUse() - before
  doAssert before == 0 or grew < 64 * 1024, what & ": the heap grew " & $grew & " bytes"

block paletteTabLabelsShow:
  # the tabs behind a palette's front tab: their label stands out from
  # their face in every built-in theme (in Gray it was gray on dark gray)
  for b in builtinThemes:
    ui.theme = b.theme
    var ink: Color
    var face: uint32
    view = proc () =
      ink = paletteTabFace(rect(10, 10, 60, 20), front = false, hover = false)
    run(2)
    face = px(30, 20)
    let back = color(uint8(face shr 16 and 255), uint8(face shr 8 and 255), uint8(face and 255))
    doAssert abs(lumaOfColor(ink) - lumaOfColor(back)) >= 70,
      b.name & ": a tab behind, label " & $lumaOfColor(ink) & " on " & $lumaOfColor(back)
  ui.theme = Classic

block pngReadFreesItsData:
  # every PNG read left its compressed data behind: `idat = @[]` after a
  # loop that filled it was taken by Nim 2.2 for a first value (no destroy)
  let b = newBitmap(120, 90)
  for i in 0 ..< b.px.len: b.px[i] = 0xFF000000'u32 or (uint32(i) * 2654435761'u32)
  let png = encodePng(b)
  leaksNot("decodePng", 200):
    doAssert decodePng(png).w == 120

block funnelChartFreesItsTexts:
  # a funnel too narrow for its texts with shares: `texts = shorter` leaked
  # the texts each frame (the same Nim 2.2 trouble)
  view = proc () =
    pushFrame(rect(0, 0, 300, 0))
    chart("", chFunnel, ["Leads from the web site", "Qualified by the sales team",
                         "Proposals sent", "Won"],
          [series("", [1200.0, 640, 310, 75])], height = 190)
    discard popFrame()
  run(2)
  leaksNot("funnelChart", 400):
    run(1)

block damagedZipEntriesFreed:
  # an entry whose checksum does not match: its content was put in
  # `result` before the check raised, and Nim 2.2 never freed it
  var z = newZipWriter()
  z.addFile("a.txt", "x".repeat(20_000))
  var zipData = z.finish()
  let dir = getTempDir() / "retro-hardening"
  createDir(dir)
  let path = dir / "damaged.zip"
  writeFile(path, zipData)
  var e = zipEntries(path)[0]
  e.crc = e.crc xor 1
  leaksNot("readEntry", 100):
    doAssertRaises(ZipError): discard readEntry(path, e)
  removeDir(dir)

block mixedPictureFreed:
  # a picture of two layers asked for its one plain layer (each frame):
  # `return nil` over the first layer found kept that layer counted, and it
  # was never freed with the picture (Nim 2.2's `return` does not destroy
  # the `result` it replaces)
  leaksNot("a picture of two layers", 30):
    let d = newDoc(64, 64, 0xFFFFFFFF'u32)
    discard d.addLayer("two")
    d.updateComposite()
    doAssert d.simpleLayer == nil

block damagedPicturesFreed:
  # damaged JPEG XL files and OpenEXR files cut short: what a reader had
  # read before it failed, going into a field, was never freed
  let data = currentSourcePath().parentDir / "data"
  var r = initRand(7)
  var damaged: seq[string]
  for name in ["ll-graphic-e9.jxl", "vd-up2.jxl", "ll-16.jxl", "ll-patches.jxl", "md-lossy.jxl"]:
    let f = readFile(data / "jxl" / name)
    for _ in 0 ..< 40:
      var d = f
      for _ in 0 .. r.rand(4): d[r.rand(d.high)] = char(r.rand(255))
      damaged.add d
  leaksNot("damaged JPEG XL files", 4):
    for d in damaged:
      try: discard decodeJxlFrames(d)
      except JxlError: discard
  let exr = readFile(data / "exr" / "rgba_b44.exr")
  leaksNot("OpenEXR files cut short", 4):
    for n in 9 ..< 600:
      try: discard readExr(exr[0 ..< n])
      except ValueError: discard

block listColumnsKeepApart:
  # a list's tab stops grow with the UI's size and a column's text stops
  # short of the next (at 150% the columns ran into each other)
  setUiScale(150)
  var sel = -1
  let items = ["WWWWWWWWWWWWWWWWWWWWWWWW\tWWW", "AB\tCD"]
  view = proc () =
    pushFrame(rect(0, 0, 600, 0))
    listbox(items, sel, rows = 3, tabs = [110, 160])
    discard popFrame()
  run(3)
  proc ink(x, y: int): bool = (px(x, y) and 0xFF) < 100     # (black text on white)
  # the first row's band: where the text is (rows of the frame's lines,
  # dark across the whole list, left out)
  var top = -1
  var left = W
  for y in 2 ..< 80:
    var n = 0
    for x in 4 ..< 590:
      if ink(x, y): inc n
    if n == 0 or n > 300: continue
    if top < 0: top = y
    if y < top + FontH div 2:
      for x in 4 ..< 590:
        if ink(x, y):
          left = min(left, x)
          break
  doAssert top > 0 and left < W, "the list's text is drawn"
  let stop = left + dp(110)                    # (where the second column starts)
  for x in stop - dp(3) .. stop - 2:
    for y in top ..< top + FontH div 2:
      doAssert not ink(x, y), "the first column's text runs into the second at x " & $x
  setUiScale(100)

block returnAfterResultFreesIt:
  # `return x` after `result` was set leaks the old value in Nim 2.2: a
  # picture the system decodes (every picture on Android, iOS, macOS and
  # Windows), a damaged HDR file, a picture of a PDF the kit does not read
  # -- each kept its pixels until the program ended
  let saved = systemRelays.decodeImage
  systemRelays.decodeImage = proc (path: string; maxW, maxH: int):
                                  tuple[w, h: int; px: seq[uint32]] =
    (300, 200, newSeq[uint32](300 * 200))
  leaksNot("a picture the system decodes", 40):
    let b = loadPicture("/nonexistent/retro-system-decoded.jpg", 64, 64)
    doAssert b != nil and b.w == 64
  systemRelays.decodeImage = saved
  addMorePictures()
  let hdr = getTempDir() / "retro-hardening.hdr"
  # (400 x 400, its first row packed, a run of no length in it: refused
  # after the picture was made)
  writeFile(hdr, "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 400 +X 400\n\x02\x02\x01\x90" &
                 "\x00".repeat(15000))
  leaksNot("a damaged HDR file", 40):
    doAssert loadPicture(hdr, 64, 64) == nil
  removeFile(hdr)

block halfReadFreed:
  # a model that an error stops half read, into a variable the caller
  # already has; a PEM with a letter base64 does not have (Nim's `decode`
  # raised part way): neither may keep what it had made
  var good = "{\"asset\":{\"version\":\"2.0\"},\"materials\":["
  for i in 0 ..< 200: good.add "{\"name\":\"paint " & $i & "\"},"
  let broken = good & "{\"name\":5}],\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":99}}]}]}"
  var scene: Scene3
  leaksNot("a model stopped half read", 40):
    try:
      scene = readGltf(broken)
    except GltfError: discard
  let pem = "-----BEGIN CERTIFICATE-----\n" & "QUJD".repeat(4000) & "*\n-----END CERTIFICATE-----\n"
  leaksNot("a damaged PEM", 40):
    try: discard readCerts(pem)
    except SignError: discard
  doAssert unbase64(" QU\nJD ") == "ABC"
  doAssertRaises(ValueError): discard unbase64("QU=JD")

block noCommandLineInApps:
  # Retro Files 3.3.x closed at once as an APK: it asked `paramCount`, which
  # raises in an Android app (no command line). The apps and the kit's
  # modules ask `appArguments` (none there); only it, the update's restart
  # on a desktop and the Magazine example (a command-line tool) may ask Nim.
  doAssert appArguments() == commandLineParams()
  let allowed = ["src/retroui/core.nim", "src/retroui/update.nim", "examples/magazine.nim"]
  let root = currentSourcePath().parentDir.parentDir
  var bad: seq[string]
  for dir in ["src/retroui", "examples"]:
    for f in walkDirRec(root / dir):
      if not f.endsWith(".nim") or "/build/" in f: continue
      let rel = f.relativePath(root).replace('\\', '/')     # (Windows' too)
      if rel in allowed: continue
      var n = 0
      for line in readFile(f).splitLines:
        inc n
        let code = line.split('#')[0]
        for call in ["paramCount(", "paramStr(", "commandLineParams("]:
          if call in code: bad.add rel & "(" & $n & "): " & line.strip
  doAssert bad.len == 0, "asks the command line where an app may have none:\n" & bad.join("\n")

block noCFunctionCallsItself:
  # Every Mac app (0.29 to 0.32) stopped at its first event: the Cocoa
  # backend's sendOne called itself where it meant [NSApp sendEvent:]. A C
  # or Objective-C function of the drivers that calls itself: none (they
  # have no recursion meant).
  let root = currentSourcePath().parentDir.parentDir
  var found: seq[string]
  for f in walkDirRec(root / "src" / "retroui"):
    if not (f.endsWith(".c") or f.endsWith(".m")) or "/web/libc/" in f.replace('\\', '/') or
       "/vendor/" in f.replace('\\', '/'): continue
    var name = ""
    for line in readFile(f).splitLines:
      if name.len == 0:
        # (a function's first line: "static void sendOne(NSEvent *ev) {")
        if line.len > 0 and line[0] notin {' ', '\t', '#', '/', '*', '}'} and line.endsWith(") {") and
           not line.startsWith("@") and not line.startsWith("-") and not line.startsWith("+"):
          let open = line.find('(')
          if open > 0:
            var k = open - 1
            while k >= 0 and line[k] in IdentChars: dec k
            name = line[k + 1 ..< open]
            if name in ["if", "while", "for", "switch"]: name = ""
      elif line.startsWith("}"):
        name = ""
      elif (name & "(") in line and not line.strip.startsWith("//") and not line.strip.startsWith("*"):
        let at = line.find(name & "(")
        if at == 0 or line[at - 1] notin IdentChars:
          found.add f.relativePath(root) & ": " & name & " calls itself: " & line.strip
  doAssert found.len == 0, found.join("\n")

block androidStartRunsOnce:
  # Retro Photo stopped on Android's emulator, in its start, when a second
  # activity ran the app's start again in the same process: the filters'
  # table still held the first run's closures, counted as cycle roots of the
  # first app thread, and the new thread's empty list was read at -1. Now
  # the activity is the task's only one (singleTask), the app goes on in a
  # second one made while it runs (the first finished), every callback of
  # an activity no longer the app's is let go, and the cycles' roots are
  # collected when NimMain returns.
  let root = currentSourcePath().parentDir.parentDir
  let glue = readFile(root / "src/retroui/uirelays/drivers/android_glue.c")
  var unguarded: seq[string]
  var name = ""
  var guarded = true
  for line in glue.splitLines:
    if line.startsWith("static void on") and "(ANativeActivity *a" in line:
      if name.len > 0 and not guarded: unguarded.add name
      name = line[len("static void ") ..< line.find('(')]
      guarded = "g.activity" in line
    elif name.len > 0:
      if "g.activity" in line or "onInputQueueCreated(a" in line or "onNativeWindowCreated(a" in line:
        guarded = true
      if line.startsWith("}"):
        if not guarded: unguarded.add name
        name = ""
  doAssert unguarded.len == 0, "an activity's callback that does not ask whose app it is: " & unguarded.join(", ")
  var mains, ended = 0
  for line in glue.splitLines:
    if line.strip.startsWith("NimMain();"): inc mains
    if line.strip.startsWith("uirelays_main_ended();"): inc ended
  doAssert mains >= 2 and ended == mains, "NimMain without the collect after it"
  doAssert "if (!ended) {" in glue and "ANativeActivity_finish(old);" in glue and
           "setCallbacks(activity);\n      ANativeActivity_finish(old);" in glue
  doAssert "uirelays_main_ended" in readFile(root / "src/retroui/uirelays/drivers/android_driver.nim")
  let apk = readFile(root / "src/retroapk.nim")
  doAssert "iAttr(\"launchMode\", 0x0101001d, 2)" in apk, "the activity: singleTask"

echo "hardening tests passed"
