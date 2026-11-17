## Tests of Mockups (retroui/mockups): each scene drawn, the design a Smart Object in its
## place under the scene's light and shade, seen where it should be.

import retroui/[photo, mockups]

var design = newSeq[uint32](60 * 40)
for i in 0 ..< design.len: design[i] = 0xFFD02020'u32

for k in MockupKind:
  let d = makeMockup(k, design, 60, 40, 400, 300, color = 0xFFF0F0F0'u32)
  doAssert d.layers.len == 3, $k
  let D = d.layers[1]
  doAssert D.isSmart and D.smart.w == 60 and D.name == "Your Design"
  doAssert d.layers[2].mode == bmMultiply and d.layers[2].clipped
  # the design where it goes: red in the middle of its place
  let q = D.smart.quad
  let cx = int((q[0][0] + q[1][0] + q[2][0] + q[3][0]) / 4)
  let cy = int((q[0][1] + q[1][1] + q[2][1] + q[3][1]) / 4)
  doAssert cx in 0 ..< 400 and cy in 0 ..< 300, $k
  d.updateComposite()
  let p = d.compCopy[cy * 400 + cx]
  let r = int((p shr 16) and 255)
  let g = int((p shr 8) and 255)
  doAssert r > g + 60, $k & ": " & $r & " " & $g
  # and the scene round it: not red far from it
  let corner = d.compCopy[5 * 400 + 5]
  doAssert int((corner shr 16) and 255) - int((corner shr 8) and 255) < 30, $k
  if k == mkMug: doAssert D.smart.warp.len == 16        # (bent round the mug)

echo "mockups ok"
