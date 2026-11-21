## Ink (`retroui/ink`): dabs spaced along a stroke, pressure to size and opacity, the spacing
## carried from one part of a stroke to the next; stamped on the CPU -- a hard dab full in its
## middle, nothing past its edge, the eraser taking away -- and on the GPU (off screen, EGL) to
## the CPU's pixels within a few levels; the GPU skipped where there is none.

import std/[os, math]
import retroui/[gfx, ink]
import retroui/uirelays/[eglload, screen]

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

block dabs:
  var carry = 0'f32
  let s = InkStroke(size: 20, spacing: 0.5, sizeByPressure: true, opacityByPressure: true)
  let d = dabsAlong([(0'f32, 0'f32, 0.5'f32), (100'f32, 0'f32, 1'f32)], s, carry)
  check d.len == 11, "a dab every 10 pixels over 100 (" & $d.len & ")"
  check abs(d[0].size - 10) < 0.01 and abs(d[^1].size - 20) < 0.01 and abs(d[5].opacity - 0.75) < 0.01,
        "pressure to size and opacity, read between the points"
  # the rest of the stroke: the spacing goes on from where it was
  let more = dabsAlong([(100'f32, 0'f32, 1'f32), (125'f32, 0'f32, 1'f32)], s, carry)
  check more.len == 2 and abs(more[0].x - 110) < 0.01 and abs(more[1].x - 120) < 0.01,
        "the next part of the stroke: on at 110 and 120"
  var c2 = 0'f32
  let one = dabsAlong([(5'f32, 5'f32, 1'f32)], s, c2)
  check one.len == 1, "a tap: one dab"

block cpu:
  var px = newSeq[uint32](64 * 64)
  for p in px.mitems: p = 0xFFFFFFFF'u32
  let r = stampInk(px, 64, 64, InkTip(hardness: 1), [InkDab(x: 32, y: 32, size: 30, roundness: 1, opacity: 1)],
                   0xFFFF0000'u32, useGpu = false)
  check not r.gpu and r.r.w > 0, "on the CPU"
  check px[32 * 64 + 32] == 0xFFFF0000'u32, "a hard dab: full in its middle"
  check px[32 * 64 + 2] == 0xFFFFFFFF'u32 and px[2 * 64 + 2] == 0xFFFFFFFF'u32, "nothing past its edge"
  discard stampInk(px, 64, 64, InkTip(hardness: 1), [InkDab(x: 32, y: 32, size: 10, roundness: 1, opacity: 1)],
                   0, erase = true, useGpu = false)
  check (px[32 * 64 + 32] shr 24) == 0, "the eraser: nothing left in its middle"
  check px[32 * 64 + 20] == 0xFFFF0000'u32, "the red round it kept"
  # a soft dab on a clear picture: its middle strong, its edge faint
  var clear = newSeq[uint32](64 * 64)
  discard stampInk(clear, 64, 64, InkTip(hardness: 0), [InkDab(x: 32, y: 32, size: 40, roundness: 1, opacity: 1)],
                   0xFF0000FF'u32, useGpu = false)
  let mid = int(clear[32 * 64 + 32] shr 24)
  let edge = int(clear[32 * 64 + 50] shr 24)
  check mid > 240 and edge > 0 and edge < 100 and (clear[32 * 64 + 32] and 0xFFFFFF'u32) == 0x0000FF'u32,
        "soft: strong in the middle, faint near the edge, its color kept (" & $mid & ", " & $edge & ")"

block gpu:
  putEnv("RETRO_GPU", "1")
  var egl: Egl
  if not egl.openOffscreen(64, 64):
    echo "  (no OpenGL here: the GPU's ink not tried)"
  else:
    eglload.current = egl
    gpuRelays = GpuRelays(
      startGpu: proc (): bool = true,
      stopGpu: proc () = discard,
      swapGpu: proc (): bool = true,
      gpuProc: proc (name: cstring): pointer = eglload.current.glProc(name),
      gpuIsEs: proc (): bool = true,
      gpuGeneration: proc (): int = 0,
      gpuReady: proc (): bool = true)
    setGpuMode(gmGpu)
    discard present(64, 64, true)
    check gpuFiltersReady(), "the GPU can draw into textures"
    var base = newSeq[uint32](300 * 200)
    for i in 0 ..< base.len: base[i] = if (i div 7) mod 3 == 0: 0x80336699'u32 else: 0xFFEEDDCC'u32
    var carry = 0'f32
    let s = InkStroke(size: 36, spacing: 0.2, flow: 0.6, sizeByPressure: true, angle: 30, roundness: 0.6)
    let dabs = dabsAlong([(20'f32, 30'f32, 0.2'f32), (150'f32, 170'f32, 1'f32), (280'f32, 40'f32, 0.6'f32)], s, carry)
    var a = base
    var b = base
    gpuInkMinPixels = 1
    let ra = stampInk(a, 300, 200, InkTip(hardness: 0.4), dabs, 0xFF22AA44'u32, useGpu = true)
    let rb = stampInk(b, 300, 200, InkTip(hardness: 0.4), dabs, 0xFF22AA44'u32, useGpu = false)
    check ra.gpu and not rb.gpu, "one on the GPU, one on the CPU"
    var worst = 0
    for i in 0 ..< a.len:
      for sh in [24, 16, 8, 0]:
        worst = max(worst, abs(int((a[i] shr sh) and 255) - int((b[i] shr sh) and 255)))
    check worst <= 6, "the GPU's pixels the CPU's within a few levels (" & $worst & ")"
    var e1 = a
    var e2 = a
    discard stampInk(e1, 300, 200, InkTip(hardness: 1), dabs[0 .. 5], 0, erase = true, useGpu = true)
    discard stampInk(e2, 300, 200, InkTip(hardness: 1), dabs[0 .. 5], 0, erase = true, useGpu = false)
    var worstE = 0
    for i in 0 ..< e1.len: worstE = max(worstE, abs(int(e1[i] shr 24) - int(e2[i] shr 24)))
    check worstE <= 3, "the eraser on the GPU as on the CPU (" & $worstE & ")"

if failures > 0:
  echo "test_ink: ", failures, " failed"
  quit(1)
echo "test_ink: all passed"
