## Compares the pictures `tests/live/livecheck.nim` saved on a system with
## the ones in `tests/live/ref` (made on Linux): the kit draws its own
## pixels, so every system should come out the same -- within a few pixels
## (a caret, a font the system stands in with). A picture twice or three
## times as big (a Retina or 200 % screen) is compared at the reference's
## size; one of another shape (a phone's screen) is not compared. Writes
## `NAME-diff.png` (the differing pixels in red) beside each one that
## differs, and a line per picture; ends with 1 when one is off.
##
##   nim c -r tools/live/compare.nim OUT_DIR [REF_DIR] [--limit:0.5]

import std/[os, strutils, parseutils]
import retroui/[gfx, imaging]

proc load(path: string): Bitmap =
  try: decodePng(readFile(path)) except CatchableError, Defect: nil

proc shrunk(b: Bitmap; k: int): Bitmap =
  ## `b` made `k` times smaller, each pixel the average of its k x k.
  result = newBitmap(b.w div k, b.h div k)
  for y in 0 ..< result.h:
    for x in 0 ..< result.w:
      var r, g, bl = 0
      for dy in 0 ..< k:
        for dx in 0 ..< k:
          let p = b.px[(y * k + dy) * b.w + x * k + dx]
          r += int((p shr 16) and 255)
          g += int((p shr 8) and 255)
          bl += int(p and 255)
      let n = k * k
      result.px[y * result.w + x] = 0xFF000000'u32 or uint32(r div n) shl 16 or
                                    uint32(g div n) shl 8 or uint32(bl div n)

proc main(): int =
  var dirs: seq[string]
  var limit = 0.5               # percent of the pixels that may differ
  for a in commandLineParams():
    if a.startsWith("--limit:"): discard parseFloat(a, limit, 8)
    else: dirs.add a
  if dirs.len == 0: quit "usage: compare OUT_DIR [REF_DIR] [--limit:0.5]"
  let outDir = dirs[0]
  let refDir = if dirs.len > 1: dirs[1] else: currentSourcePath().parentDir / ".." / ".." / "tests" / "live" / "ref"
  var bad = 0
  var seen = 0
  for path in walkFiles(refDir / "*.png"):
    let name = path.extractFilename
    let want = load(path)
    var got = load(outDir / name)
    inc seen
    if got == nil:
      echo "MISSING ", name
      inc bad
      continue
    if got.w != want.w or got.h != want.h:
      let k = got.w div max(1, want.w)
      if k >= 2 and got.w == want.w * k and got.h == want.h * k:
        # (drawn at 2x: sharper text than the reference's, averaged down)
        got = shrunk(got, k)
        echo "  ", name, " was drawn at ", k, "x"
      else:
        # (a phone's screen, of its own shape: the picture is there to look
        # at -- the artifact -- not to compare with a desktop's)
        echo "OTHER ", name, ": ", got.w, "x", got.h, " (a screen of its own shape: not compared)"
        continue
    var diff = newBitmap(want.w, want.h)
    var n = 0
    for i in 0 ..< want.px.len:
      let a = want.px[i]
      let b = got.px[i]
      var d = 0
      for sh in [0, 8, 16]:
        d = max(d, abs(int((a shr sh) and 255) - int((b shr sh) and 255)))
      if d > 40:
        inc n
        diff.px[i] = 0xFFFF0000'u32
      else:
        # (the picture faded, to see where the red is)
        let l = (int((a shr 16) and 255) + int((a shr 8) and 255) + int(a and 255)) div 3
        let f = uint32(160 + l * 95 div 255)
        diff.px[i] = 0xFF000000'u32 or f shl 16 or f shl 8 or f
    let pct = 100.0 * float(n) / float(max(1, want.px.len))
    let scaled = want.w != 0 and load(outDir / name).w != want.w
    if pct > (if scaled: max(limit, 8.0) else: limit):
      echo "DIFFERS ", name, ": ", formatFloat(pct, ffDecimal, 2), "% of the pixels"
      discard diff.savePng(outDir / name.changeFileExt("") & "-diff.png")
      inc bad
    else:
      echo "SAME ", name, " (", n, " pixels off)"
  if seen == 0:
    echo "no reference pictures in ", refDir
    return 1
  echo (if bad == 0: "every picture as on Linux" else: $bad & " of " & $seen & " off")
  if bad > 0: 1 else: 0

quit main()
