## Tests of the "pro" parts of Retro Photo's engine: layer groups (pass
## through and isolated), Blend If, mask density and feather, arranging.

import std/[unittest, math, os]
import retroui/photo

proc px(d: Doc; x, y: int): uint32 =
  d.updateComposite()
  d.compPtr[y * d.w + x]

proc solid(d: Doc; L: Layer; c: uint32) =
  for p in L.px.mitems: p = c

suite "layer groups":
  test "a pass-through group at 100 % changes nothing":
    let d = newDoc(8, 8, 0xFFFFFFFF'u32)
    let a = d.addLayer("A")
    d.solid(a, 0xFF0000FF'u32)
    a.opacity = 50
    let before = d.px(3, 3)
    let g = d.groupLayers(@[d.layers.find(a)])
    check g != nil
    check g.group and g.passThrough
    check d.layers.len == 3
    check d.layers[2] == g and d.layers[1] == a and a.depth == 1
    check d.px(3, 3) == before
    g.opacity = 0
    d.markAll()
    check d.px(3, 3) == 0xFFFFFFFF'u32

  test "a pass-through group with opacity mixes with what is under it":
    let d = newDoc(4, 4, 0xFFFFFFFF'u32)
    let a = d.addLayer("A")
    d.solid(a, 0xFF000000'u32)
    let g = d.groupLayers(@[2 - 1])
    g.opacity = 50
    d.markAll()
    let p = d.px(1, 1)
    check abs(rOf(p) - 128) <= 1

  test "an adjustment in an isolated group changes only its layers":
    let d = newDoc(4, 4, 0xFF808080'u32)
    let a = d.addLayer("A")
    for i in 0 ..< 8: a.px[i] = 0xFF404040'u32          # (the top half)
    discard d.newAdjustmentLayer(Adjustment(kind: "Invert"))
    for p in d.layers[^1].px.mitems: p = 0xFFFFFFFF'u32
    let g = d.groupLayers(@[1, 2])
    check g.depth == 0 and d.layers[1].depth == 1 and d.layers[2].depth == 1
    # pass through: the Background is inverted too
    let through = d.px(0, 3)
    g.passThrough = false
    g.mode = bmNormal
    d.markAll()
    let alone = d.px(0, 3)
    if adjustmentLut != nil:
      check through != alone
    check alone == 0xFF808080'u32

  test "a hidden group hides its layers":
    let d = newDoc(4, 4, 0xFFFFFFFF'u32)
    let a = d.addLayer("A")
    d.solid(a, 0xFF00FF00'u32)
    let g = d.groupLayers(@[1])
    g.visible = false
    d.markAll()
    check d.px(0, 0) == 0xFFFFFFFF'u32
    check not d.shownInTree(1)

  test "nested groups, ungroup, delete and duplicate whole groups":
    let d = newDoc(4, 4, 0xFFFFFFFF'u32)
    discard d.addLayer("A")
    discard d.addLayer("B")
    let inner = d.groupLayers(@[1, 2], "Inner")
    let outer = d.groupLayers(@[d.layers.find(inner)], "Outer")
    check d.layers.len == 5
    check outer.depth == 0 and inner.depth == 1 and d.layers[1].depth == 2
    check d.blockStart(4) == 1
    check d.parentOf(1) == 3 and d.parentOf(3) == 4
    discard d.duplicateLayer(4)
    check d.layers.len == 9
    check d.layers[8].name == "Outer copy" and d.layers[8].group
    d.deleteLayer(8)
    check d.layers.len == 5
    d.ungroup(4)
    check d.layers.len == 4
    check inner.depth == 0 and d.layers[1].depth == 1

  test "arranging in and out of groups":
    let d = newDoc(4, 4, 0xFFFFFFFF'u32)
    let a = d.addLayer("A")
    let b = d.addLayer("B")
    let g = d.groupLayers(@[d.layers.find(b)], "G")
    # A is under the group: forward into it (at its bottom)
    d.cur = d.layers.find(a)
    check d.arrange(arForward)
    check a.depth == 1 and d.parentOf(d.layers.find(a)) == d.layers.find(g)
    # out of it again, under it
    d.cur = d.layers.find(a)
    check d.arrange(arBackward)
    check a.depth == 0 and d.layers.find(a) < d.layers.find(g)
    # to the front: over the group
    check d.arrange(arFront)
    check d.layers[^1] == a and a.depth == 0
    check not d.arrange(arFront)
    # the Background does not move
    d.cur = 0
    check not d.arrange(arForward)

  test "merging a group":
    let d = newDoc(4, 4, 0xFFFFFFFF'u32)
    let a = d.addLayer("A")
    d.solid(a, 0xFFFF0000'u32)
    let g = d.groupLayers(@[1])
    let before = d.px(2, 2)
    d.cur = d.layers.find(g)
    d.mergeDown()
    check d.layers.len == 2
    check not d.layers[1].group
    check d.px(2, 2) == before

  test "undo keeps groups":
    let d = newDoc(4, 4, 0xFFFFFFFF'u32)
    discard d.addLayer("A")
    d.beginStep("Group")
    d.touchLayers()
    discard d.groupLayers(@[1])
    d.endStep()
    check d.layers.len == 3
    d.undo()
    check d.layers.len == 2 and d.layers[1].depth == 0
    d.redo()
    check d.layers.len == 3 and d.layers[2].group and d.layers[1].depth == 1

  test "groups survive saving":
    let d = newDoc(6, 5, 0xFFFFFFFF'u32)
    let a = d.addLayer("A")
    d.solid(a, 0xFF112233'u32)
    let g = d.groupLayers(@[1], "Folder")
    g.passThrough = false
    g.mode = bmMultiply
    g.collapsed = true
    let path = "/tmp/test_groups.rpd"
    d.saveRpd(path)
    let e = loadRpd(path)
    check e.layers.len == 3
    check e.layers[2].group and e.layers[2].name == "Folder" and not e.layers[2].passThrough
    check e.layers[2].mode == bmMultiply and e.layers[2].collapsed
    check e.layers[1].depth == 1
    check e.px(1, 1) == d.px(1, 1)
    removeFile(path)

suite "blending":
  test "Blend If: this layer's darks left out":
    let d = newDoc(2, 1, 0xFFFFFFFF'u32)
    let a = d.addLayer("A")
    a.px[0] = 0xFF101010'u32
    a.px[1] = 0xFFE0E0E0'u32
    a.blendIf.this = [64, 64, 255, 255]
    d.markAll()
    check d.px(0, 0) == 0xFFFFFFFF'u32
    check d.px(1, 0) == 0xFFE0E0E0'u32

  test "Blend If: only over the darks under it, split":
    let d = newDoc(3, 1, 0xFF000000'u32)
    d.layers[0].px[1] = 0xFF808080'u32
    d.layers[0].px[2] = 0xFFFFFFFF'u32
    let a = d.addLayer("A")
    d.solid(a, 0xFFFF0000'u32)
    a.blendIf.under = [0, 0, 64, 192]
    d.markAll()
    check d.px(0, 0) == 0xFFFF0000'u32
    check d.px(2, 0) == 0xFFFFFFFF'u32
    let m = d.px(1, 0)
    check rOf(m) > 128 and gOf(m) > 0 and gOf(m) < 128

  test "mask density and feather":
    let d = newDoc(32, 1, 0xFFFFFFFF'u32)
    let a = d.addLayer("A")
    d.solid(a, 0xFF000000'u32)
    d.addLayerMask(mfHideAll)
    for x in 16 ..< 32: a.mask.px[x] = 0xFFFFFFFF'u32
    d.markAll()
    check d.px(4, 0) == 0xFFFFFFFF'u32
    a.maskDensity = 50
    d.markAll()
    check abs(rOf(d.px(4, 0)) - 128) <= 2
    a.maskDensity = 100
    a.maskFeather = 6
    d.markAll()
    let edge = rOf(d.px(15, 0))
    check edge > 40 and edge < 215
    check d.px(0, 0) == 0xFFFFFFFF'u32 or rOf(d.px(0, 0)) > 240

  test "zeroed pixels":
    let z = zeroPixels(300_000)
    check z.len == 300_000
    var nz = 0
    for v in z:
      if v != 0: inc nz
    check nz == 0

suite "history":
  test "states, going back and forth":
    let d = newDoc(8, 8, 0xFFFFFFFF'u32)
    for c in [0xFF000001'u32, 0xFF000002'u32, 0xFF000003'u32]:
      d.beginStep("Fill " & $(c and 255))
      d.fillSelection(c)
      d.endStep()
    check d.historyStates == @["Open", "Fill 1", "Fill 2", "Fill 3"]
    check d.historyAt == 3
    d.goToHistory(1)
    check d.layers[0].px[0] == 0xFF000001'u32
    check d.historyStates.len == 4 and d.historyAt == 1
    d.goToHistory(3)
    check d.layers[0].px[0] == 0xFF000003'u32

  test "the pixels of a state, back and forward":
    let d = newDoc(70, 70, 0xFFFFFFFF'u32)
    let L = d.layers[0]
    for c in [0xFF000001'u32, 0xFF000002'u32, 0xFF000003'u32]:
      d.beginStep("Fill")
      d.fillSelection(c)
      d.endStep()
    check d.statePixels(L, 0)[69 * 70 + 69] == 0xFFFFFFFF'u32
    check d.statePixels(L, 1)[5] == 0xFF000001'u32
    check d.statePixels(L, 3)[5] == 0xFF000003'u32
    d.goToHistory(1)
    check d.statePixels(L, 2)[5] == 0xFF000002'u32
    check d.statePixels(L, 3)[5] == 0xFF000003'u32
    check L.px[5] == 0xFF000001'u32

  test "snapshots":
    let d = newDoc(40, 30, 0xFFFFFFFF'u32)
    let L = d.layers[0]
    d.takeSnapshot()
    d.beginStep("Fill")
    d.fillSelection(0xFF102030'u32)
    d.endStep()
    check d.snapshots.len == 1 and d.snapshots[0].name == "Snapshot 1"
    check d.snapshotPixels(L, 0)[0] == 0xFFFFFFFF'u32
    d.revertToSnapshot(0)
    check L.px[0] == 0xFFFFFFFF'u32
    d.undo()
    check L.px[0] == 0xFF102030'u32

import retroui/[photofx, photowarp, textengine]

suite "warps and Smart Objects":
  proc pattern(w, h: int): seq[uint32] =
    result = newSeq[uint32](w * h)
    for y in 0 ..< h:
      for x in 0 ..< w: result[y * w + x] = argb(255, x * 255 div max(1, w - 1), y * 255 div max(1, h - 1), (x xor y) and 255)

  test "a picture drawn on a flat grid is itself":
    let src = Img(w: 40, h: 30, px: pattern(40, 30))
    var dst = newSeq[uint32](40 * 30)
    var pos, tex: seq[MeshPt]
    for j in 0 .. 3:
      for i in 0 .. 4:
        pos.add (i.float * 10, j.float * 10)
        tex.add (i.float * 10, j.float * 10)
    drawMesh(dst, 40, 30, src, 4, 3, pos, tex)
    var off = 0
    for i in 0 ..< dst.len:
      if dst[i] != src.px[i]: inc off
    check off == 0

  test "Warp: flat, then a style":
    let px = pattern(60, 40)
    let same = warpRect(px, 60, 40, rect(10, 5, 40, 30), identityMesh())
    var off = 0
    for i in 0 ..< px.len:
      if abs(rOf(same[i]) - rOf(px[i])) > 2: inc off
    check off < 10
    let arc = presetMesh(TextWarp(style: wsArc, bend: 50), 0.75)
    check not arc.isIdentity
    check identityMesh().isIdentity
    let (x, y) = identityMesh().meshPoint(0.5, 0.25)
    check abs(x - 0.5) < 1e-9 and abs(y - 0.25) < 1e-9

  test "Puppet Warp: pins":
    check puppetPoint([(10.0, 10.0)], [(15.0, 12.0)], 50, 50) == (55.0, 52.0)
    let (x, y) = puppetPoint([(0.0, 0.0), (100.0, 0.0)], [(5.0, 5.0), (105.0, 5.0)], 50, 50)
    check abs(x - 55) < 1e-6 and abs(y - 55) < 1e-6
    # turned a quarter: the point goes round with them
    let (rx, ry) = puppetPoint([(-10.0, 0.0), (10.0, 0.0)], [(0.0, -10.0), (0.0, 10.0)], 0, 5)
    check abs(rx + 5) < 1e-6 and abs(ry) < 1e-6
    let (ax, ay) = puppetPoint([(0.0, 0.0), (10.0, 0.0), (0.0, 10.0)], [(0.0, 0.0), (20.0, 0.0), (0.0, 10.0)],
                               5, 5, pmDistort)
    check abs(ax - 10) < 1e-6 and abs(ay - 5) < 1e-6
    let px = pattern(50, 50)
    let moved = puppetWarp(px, 50, 50, rect(0, 0, 50, 50), [(25.0, 25.0)], [(30.0, 25.0)])
    check moved[25 * 50 + 30] == px[25 * 50 + 25] or abs(rOf(moved[25 * 50 + 30]) - rOf(px[25 * 50 + 25])) <= 2

  test "Smart Objects: drawn from what they hold, kept":
    let d = newDoc(80, 60, 0xFFFFFFFF'u32)
    let L = d.addLayer("S")
    L.px = pattern(80, 60)
    L.smart = smartOf(L.px, 80, 60, rect(10, 10, 40, 30), "thing")
    let r = renderSmart(L.smart, 80, 60)
    check r[10 * 80 + 10] == L.px[10 * 80 + 10] and r[39 * 80 + 49] == L.px[39 * 80 + 49]
    check (r[5 * 80 + 5] shr 24) == 0
    # twice as big: lossless (from the picture held, not the pixels)
    let big = renderSmart(L.smart.withQuad(quadOf(rect(0, 0, 80, 60))), 80, 60)
    check abs(rOf(big[59 * 80 + 79]) - rOf(L.px[39 * 80 + 49])) <= 6
    # filters: done in order, when on
    var calls = 0
    let inv = proc (f: SmartFilter): FilterFn =
      inc calls
      invert()
    let s2 = L.smart.withFilters(@[SmartFilter(name: "Invert", opacity: 100), SmartFilter(name: "Invert", off: true)])
    let fr = renderSmart(s2, 80, 60, inv)
    check calls == 1
    check (fr[20 * 80 + 20] and 0xFFFFFF'u32) == ((L.px[20 * 80 + 20] xor 0xFFFFFF'u32) and 0xFFFFFF'u32)
    # saved and read back
    L.smart = s2.withWarp(@(presetMesh(TextWarp(style: wsBulge, bend: 30), 0.75)))
    L.px = renderSmart(L.smart, 80, 60, inv)
    let path = "/tmp/test_smart.rpd"
    d.saveRpd(path)
    let e = loadRpd(path)
    let S = e.layers[1].smart
    check S != nil and S.w == 40 and S.h == 30 and S.name == "thing"
    check S.filters.len == 2 and S.filters[1].off and S.warp.len == 16
    check S.quad == L.smart.quad and S.src == L.smart.src
    removeFile(path)
    # moved whole with the Move tool: its corners go with its pixels -- its box, what it is drawn
    # again into -- and come back with them when undone; moved by a nudge the same
    d.cur = d.layers.find(L)
    let q0 = L.smart.quad
    let p0 = L.px[20 * 80 + 20]
    d.beginStep("Move")
    var lift = d.beginMove(0)
    d.moveTo(lift, 7, 5)
    d.endMove(lift)
    d.endStep()
    check L.smart.quad[0] == (q0[0][0] + 7, q0[0][1] + 5) and L.smart.quad[2] == (q0[2][0] + 7, q0[2][1] + 5)
    check L.px[25 * 80 + 27] == p0
    d.undo()
    check L.smart.quad == q0 and L.px[20 * 80 + 20] == p0
    d.redo()
    check L.smart.quad[0] == (q0[0][0] + 7, q0[0][1] + 5)
    d.undo()
    d.beginStep("Nudge")
    d.shiftLayers(@[L], 3, 0)
    d.endStep()
    check L.smart.quad[1] == (q0[1][0] + 3, q0[1][1]) and L.px[20 * 80 + 23] == p0
    d.undo()
    check L.smart.quad == q0

  test "the Blur Gallery":
    let src = Img(w: 64, h: 32, px: pattern(64, 32))
    var rad = newSeq[float32](64 * 32)
    check variableBlur(src, rad, 8).px == src.px
    for y in 0 ..< 32:
      for x in 32 ..< 64: rad[y * 64 + x] = 8
    let o = variableBlur(src, rad, 8)
    check o.px[16 * 64 + 5] == src.px[16 * 64 + 5]
    var diff = 0
    for x in 40 ..< 60:
      if o.px[16 * 64 + x] != src.px[16 * 64 + x]: inc diff
    check diff > 10
    let iris = irisRadius(100, 100, 50, 50, 30, 30, 0, 0.5, 20)
    check iris[50 * 100 + 50] == 0 and iris[0] == 20
    let tilt = tiltShiftRadius(100, 100, 50, 50, 0, 10, 10, 15)
    check tilt[50 * 100 + 3] == 0 and tilt[0] == 15
    let field = fieldRadius(10, 10, [(0.5, 0.5, 0.0), (9.5, 9.5, 10.0)])
    check field[0] == 0 and field[99] == 10 and field[5 * 10 + 5] > 0
