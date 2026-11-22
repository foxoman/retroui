## Tests of retroui/proctexture, Procedural Texture: formulas read (and what is wrong with one
## said), each value and function, a channel left as it was, the shared value, the presets drawn
## (clouds vary, the checkerboard's squares exact, the vignette dark at the corners only), the
## same picture each time.

import std/[math, strutils]
import retroui/[gfx, photofx, proctexture]

var passed = 0
template check(cond: bool; what: string) =
  doAssert cond, what
  inc passed
  echo "  ok   ", what

proc img(w, h: int; c = 0xFF808080'u32): Img =
  result = newImg(w, h)
  for i in 0 ..< w * h: result.px[i] = c

proc paint(t: TextureFormula; w = 64, h = 48; c = 0xFF808080'u32; values: openArray[float] = []): Img =
  proceduralTexture(t, values)(img(w, h, c), rect(0, 0, w, h))

proc red(p: uint32): int = int((p shr 16) and 255)
proc green(p: uint32): int = int((p shr 8) and 255)
proc blue(p: uint32): int = int(p and 255)

check textureError("sin(x * pi) + clamp(rad, 0, 1) * (L > 0.5 ? 1 : 0.2)") == "", "a good formula"
check "no function" in textureError("foo(1)"), "an unknown function said: " & textureError("foo(1)")
check "no value" in textureError("q + 1"), "an unknown value said"
check "takes 3" in textureError("mix(1, 2)"), "too few values said: " & textureError("mix(1, 2)")
check "')'" in textureError("(1 + 2"), "a missing ) said"
check textureError("") == "", "empty: the channel kept"

let flat = TextureFormula(name: "t", r: "0.25 + 0.5", g: "", b: "2^-1 * B * 2", a: "1 > 0 && 0 < 1 ? 1 : 0")
let p = paint(flat, 4, 4, 0xC0204080'u32).px[0]
check red(p) == 191 and green(p) == 0x40 and blue(p) == 0x80 and (p shr 24) == 255,
      "values, the channel kept, ^, && and ?: (" & p.toHex & ")"
let pos = TextureFormula(name: "t", r: "rx", g: "ry", b: "x / (w - 1)")
let im = paint(pos, 11, 5)
check red(im.px[0]) == 12 and red(im.px[10]) == 243 and blue(im.px[10]) == 255 and green(im.px[4 * 11]) == 230,
      "where the pixel is: rx, ry, x and w"
let mid = TextureFormula(name: "t", r: "rad < 0.1 ? 1 : 0", g: "abs(ang) < 0.01 && cx > 0.5 ? 1 : 0")
let m = paint(mid, 41, 41)
check red(m.px[20 * 41 + 20]) == 255 and red(m.px[0]) == 0 and green(m.px[20 * 41 + 40]) == 255,
      "cx, cy, rad and ang from the middle"
let shared = TextureFormula(name: "t", v: "0.5 * p0", r: "v", g: "v * 2", b: "v * 4")
let sp = paint(shared, 2, 2, values = [0.5]).px[0]
check red(sp) == 64 and green(sp) == 128 and blue(sp) == 255, "the shared value and a slider"

var noiseOk = true
for i in 0 ..< 200:
  let x = i.float * 0.37
  for f in ["noise(" & $x & ", 1.3)", "fbm(" & $x & ", 2.1, 5)", "cells(" & $x & ", 0.7)", "rnd(" & $x & ", 4)"]:
    let v = red(paint(TextureFormula(name: "n", r: f), 1, 1).px[0])
    if v < 0 or v > 255: noiseOk = false
check noiseOk, "noise, fbm, cells and rnd within 0..1"
let n1 = paint(TextureFormula(name: "n", r: "noise(rx * 8, ry * 8)"), 32, 32)
var lo, hi = 128
for q in n1.px:
  lo = min(lo, red(q))
  hi = max(hi, red(q))
check hi - lo > 80, "noise varies (" & $lo & ".." & $hi & ")"
var smooth = true
for i in 1 ..< 32:
  if abs(red(n1.px[i]) - red(n1.px[i - 1])) > 64: smooth = false
check smooth, "... smoothly"

proc preset(name: string): TextureFormula =
  for t in texturePresets:
    if t.name == name: return t
  doAssert false, name

for t in texturePresets:
  for f in [t.v, t.r, t.g, t.b, t.a]: doAssert textureError(f) == "", t.name & ": " & f & ": " & textureError(f)
check texturePresets.len >= 12, $texturePresets.len & " presets, every formula read"
let clouds = paint(preset("Clouds"), 80, 60)
var cl, ch = 255
ch = 0
for q in clouds.px:
  cl = min(cl, red(q))
  ch = max(ch, red(q))
check ch - cl > 40 and blue(clouds.px[0]) == 255, "Clouds vary, in a blue sky"
let ck = paint(preset("Checkerboard"), 64, 64, values = [16.0, 1.0])
check red(ck.px[0]) == 0 and red(ck.px[16]) == 255 and red(ck.px[16 * 64]) == 255 and red(ck.px[16 * 64 + 16]) == 0,
      "the checkerboard's squares exact"
let vg = paint(preset("Vignette"), 60, 60, 0xFFC0C0C0'u32)
check red(vg.px[30 * 60 + 30]) == 0xC0 and red(vg.px[0]) < 0x60, "the vignette: dark at the corners, not in the middle"
check paint(preset("Wood"), 40, 40).px == paint(preset("Wood"), 40, 40).px, "the same picture each time"

echo "test_proctexture: ", passed, " passed"
