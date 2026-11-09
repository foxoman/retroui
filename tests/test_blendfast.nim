## The composite's quick ways give the same pixels as the plain ones: the
## blend tables over opaque pixels (`overOpaque`), and the adjustment
## tables by channel (`channelTables`) against the 3-D table read between
## its colors (`lutAt`).

import std/random
import retroui/photo {.all.}
import retroui/gfx

var r = initRand(7)

block overOpaqueIsBlendPx:
  for m in BlendMode:
    if m != bmNormal and m notin SepModes: continue
    let lut = sepLut(m)
    for _ in 0 ..< 20000:
      let d = 0xFF000000'u32 or uint32(r.rand(0xFFFFFF))
      let s = uint32(r.rand(0xFFFFFF)) or (uint32(r.rand(255)) shl 24)
      let a = r.rand(1 .. 255)
      let ea = a * int(s shr 24) div 255
      let want = blendPx(d, s, a, m)
      let got = if ea > 0: overOpaque(d, s, ea, lut) else: d
      doAssert got == want, $m & ": " & $d & " " & $s & " " & $a

block compositeMatchesBlendPx:
  # every mode of a layer over an opaque picture, a part see-through
  const W = 48
  const H = 32
  let d = newDoc(W, H, 0xFFFFFFFF'u32)
  for i in 0 ..< W * H: d.layers[0].px[i] = 0xFF000000'u32 or uint32(r.rand(0xFFFFFF))
  inc d.layers[0].ver
  var modes: seq[BlendMode]
  for m in LayerModes:
    if m != bmDissolve: modes.add m
  for m in modes:
    let L = d.addLayer($m)
    for i in 0 ..< W * H:
      L.px[i] = if r.rand(9) == 0: 0'u32 else: uint32(r.rand(0xFFFFFF)) or (uint32(r.rand(255)) shl 24)
    L.mode = m
    L.opacity = 70
    inc L.ver
  d.markAll()
  d.updateComposite()
  let got = d.toBitmap()
  for y in 0 ..< H:
    for x in 0 ..< W:
      var want = d.layers[0].px[y * W + x]
      for k in 1 ..< d.layers.len:
        let L = d.layers[k]
        let s = L.px[y * W + x]
        if (s shr 24) == 0: continue
        want = blendPx(want, s, 70 * 255 div 100, L.mode, x, y)
      doAssert got.px[y * W + x] == want, $d.layers[1 + (y * W + x) mod modes.len].mode

block channelTablesMatchLutAt:
  var sep, mixed = 0
  for a in [Adjustment(kind: "Curves", args: @[3.0, 0, 0, 128, 150, 255, 255, 2, 0, 0, 255, 255,
                                                2, 0, 0, 255, 255, 2, 0, 0, 255, 255]),
            Adjustment(kind: "Levels", args: @[20.0, 1.4, 230, 0, 255]),
            Adjustment(kind: "Brightness/Contrast", args: @[30.0, 20]),
            Adjustment(kind: "Invert"),
            Adjustment(kind: "Hue/Saturation", args: @[40.0, 20, 0]),
            Adjustment(kind: "Black & White")]:
    let lut = adjustmentLut(a)
    if lut.len != LutN * LutN * LutN: continue
    let t = channelTables(lut)
    if t.len == 0:
      inc mixed
      continue
    inc sep
    let lp = cast[ptr UncheckedArray[uint32]](unsafeAddr lut[0])
    for _ in 0 ..< 50000:
      let p = 0xFF000000'u32 or uint32(r.rand(0xFFFFFF))
      let want = lutAt(lp, p)
      let got = 0xFF000000'u32 or (uint32(t[int((p shr 16) and 255)]) shl 16) or
                (uint32(t[256 + int((p shr 8) and 255)]) shl 8) or uint32(t[512 + int(p and 255)])
      doAssert got == want, a.kind
  doAssert sep >= 3, "Curves, Levels, Invert go by channel: " & $sep
  doAssert mixed >= 1, "Hue/Saturation and Black & White mix the channels"

echo "test_blendfast: ok"
