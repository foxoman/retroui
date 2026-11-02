## A pen's pressure, lean, turn and eraser end from what the desktop systems
## report (Windows' POINTER_PEN_INFO, X11 tablet valuators, macOS tablet
## events, SDL3 pen axes) into `Event` -- the arithmetic the drivers share,
## without a tablet.

import std/math
import uirelays/input
import uirelays/drivers/penaxes

proc near(a, b: float; eps = 1e-4): bool = abs(a - b) <= eps

# ---- the lean: two plane angles into how far and which way ----

block:
  var t, a: float32
  penLean(0, 0, t, a)
  doAssert t == 0 and a == 0
  penLean(45, 0, t, a)                   # leaning right
  doAssert near(t, PI / 4) and near(a, 0), $t & " " & $a
  penLean(0, 45, t, a)                   # towards the bottom: clockwise a quarter
  doAssert near(t, PI / 4) and near(a, PI / 2), $t & " " & $a
  penLean(-30, 0, t, a)                  # leaning left
  doAssert near(t, PI / 6) and near(a, PI), $t & " " & $a
  penLean(0, -60, t, a)                  # towards the top
  doAssert near(t, PI / 3) and near(a, 3 * PI / 2), $t & " " & $a
  penLean(45, 45, t, a)                  # both: further than either
  doAssert near(t, arctan(sqrt(2.0))) and near(a, PI / 4), $t & " " & $a
  penLean(90, 0, t, a)                   # lying flat
  doAssert near(t, PI / 2) and near(a, 0)
  penLean(0, -90, t, a)
  doAssert near(t, PI / 2) and near(a, 3 * PI / 2)
  penLean(120, 0, t, a)                  # past the range: flat
  doAssert near(t, PI / 2)

doAssert near(turnDegrees(-90), 270) and near(turnDegrees(720), 0) and
         near(turnDegrees(359.5), 359.5)

# ---- Windows ----

block:
  var e = Event(kind: MouseMoveEvent)
  penFromWindows(e, 512, 30, 45, 0, 0,
                 PenMaskPressure or PenMaskRotation or PenMaskTiltX or PenMaskTiltY, true)
  doAssert e.pen and e.fromMouse
  doAssert near(e.pressure, 0.5) and near(e.tilt, PI / 4) and near(e.azimuth, 0)
  doAssert near(e.twist, 30)
  # a pen that reports no pressure: all the way while it touches, none in the air
  e = Event()
  penFromWindows(e, 0, 0, 0, 0, 0, 0, true)
  doAssert e.pen and e.pressure == 1 and e.tilt == 0 and e.twist == 0
  e = Event()
  penFromWindows(e, 0, 0, 0, 0, 0, 0, false)
  doAssert e.pressure == 0
  # pressure beyond 1024 is still 1; tilts not in the mask are not read
  e = Event()
  penFromWindows(e, 2000, 0, 70, -70, 0, PenMaskPressure, true)
  doAssert e.pressure == 1 and e.tilt == 0
  # the eraser end: near (inverted) or touching
  for flags in [PenFlagInverted, PenFlagEraser, PenFlagEraser or PenFlagBarrel]:
    e = Event()
    penFromWindows(e, 300, 90, 0, 0, flags, PenMaskPressure or PenMaskRotation, true)
    doAssert e.twist == -1 and near(e.pressure, 300 / 1024)
  e = Event()
  penFromWindows(e, 300, 90, 0, 0, PenFlagBarrel, PenMaskPressure or PenMaskRotation, true)
  doAssert near(e.twist, 90)

# ---- X11: an XInput 2 tablet device's valuators ----

proc maskOf(bits: openArray[int]): array[4, uint8] =
  for b in bits: result[b shr 3] = result[b shr 3] or uint8(1 shl (b and 7))

block:
  # the Wacom driver: x, y, pressure 0 .. 65535, tilts -64 .. 63, wheel -900 .. 899
  var t = newTabletDevice(12, "Wacom Intuos Pro M Pen stylus")
  t.addValuator("Abs X", 0, 0, 44800, 0)
  t.addValuator("Abs Y", 1, 0, 29600, 0)
  t.addValuator("Abs Pressure", 2, 0, 65535, 0)
  t.addValuator("Abs Tilt X", 3, -64, 63, 0)
  t.addValuator("Abs Tilt Y", 4, -64, 63, 0)
  t.addValuator("Abs Wheel", 5, -900, 899, 0)
  doAssert t.isTablet and not isEraserName(t.name)
  var mask = maskOf([0, 1, 2, 3, 4, 5])
  var vals = [1000.0, 2000.0, 32767.5, 30.0, 0.0, 450.0]
  t.updateValuators(cast[ptr UncheckedArray[uint8]](addr mask[0]), mask.len,
                    cast[ptr UncheckedArray[float64]](addr vals[0]))
  var e = Event(kind: MouseMoveEvent)
  penFromTablet(e, t)
  doAssert e.pen and near(e.pressure, 0.5) and near(e.tilt, PI / 6) and near(e.azimuth, 0)
  doAssert near(e.twist, 0), $e.twist             # 450 / 5 - 90
  # an event with only the pressure: the lean stays what it was
  mask = maskOf([2])
  vals[0] = 65535
  t.updateValuators(cast[ptr UncheckedArray[uint8]](addr mask[0]), mask.len,
                    cast[ptr UncheckedArray[float64]](addr vals[0]))
  e = Event()
  penFromTablet(e, t)
  doAssert near(e.pressure, 1) and near(e.tilt, PI / 6)
  # values packed for the bits that are set, in order: tilt y alone
  mask = maskOf([4])
  vals[0] = -45
  t.updateValuators(cast[ptr UncheckedArray[uint8]](addr mask[0]), mask.len,
                    cast[ptr UncheckedArray[float64]](addr vals[0]))
  e = Event()
  penFromTablet(e, t)
  var lt, la: float32
  penLean(30, -45, lt, la)
  doAssert near(e.tilt, lt) and near(e.azimuth, la) and near(e.pressure, 1)

block:
  # xf86-input-libinput: its eraser tool, rotation as "Abs Rz" (+-max a whole turn)
  var t = newTabletDevice(15, "Wacom Intuos Pro M Pen Eraser (0x8028c7a7)")
  t.addValuator("Abs Pressure", 2, 0, 65536, 0)
  t.addValuator("Abs Tilt X", 3, -64, 64, 0)
  t.addValuator("Abs Tilt Y", 4, -64, 64, 0)
  t.addValuator("Abs Rz", 5, -16777215, 16777215, 0)
  t.eraser = isEraserName(t.name)
  doAssert t.isTablet and t.eraser and t.rotationRz
  var mask = maskOf([2, 5])
  var vals = [16384.0, 16777215.0 / 4]
  t.updateValuators(cast[ptr UncheckedArray[uint8]](addr mask[0]), mask.len,
                    cast[ptr UncheckedArray[float64]](addr vals[0]))
  var e = Event()
  penFromTablet(e, t)
  doAssert e.twist == -1 and near(e.pressure, 0.25)
  t.eraser = false
  e = Event()
  penFromTablet(e, t)
  doAssert near(e.twist, 90), $e.twist

block:
  # Xwayland's devices
  doAssert isEraserName("xwayland-tablet eraser:9")
  doAssert not isEraserName("xwayland-tablet stylus:9")
  # a touch pad that reports pressure is not a pen; one with no range neither
  var pad = newTabletDevice(9, "SynPS/2 Synaptics TouchPad")
  pad.addValuator("Abs Pressure", 2, 0, 255, 0)
  doAssert not pad.isTablet
  var odd = newTabletDevice(10, "Some Stylus")
  odd.addValuator("Abs Pressure", 2, 0, 0, 0)
  doAssert not odd.isTablet
  # a tablet without a pressure valuator would not be found; one without
  # tilt is still a pen by its name
  var plain = newTabletDevice(11, "UGTABLET 6 inch PenTablet Pen (0)")
  plain.addValuator("Abs Pressure", 2, 0, 8191, 0)
  doAssert plain.isTablet
  # tilt in a range other than degrees: its ends are +-64 degrees
  plain.addValuator("Abs Tilt X", 3, 0, 127, 0)
  var mask = maskOf([3])
  var vals = [127.0]
  plain.updateValuators(cast[ptr UncheckedArray[uint8]](addr mask[0]), mask.len,
                        cast[ptr UncheckedArray[float64]](addr vals[0]))
  var e = Event()
  penFromTablet(e, plain)
  doAssert near(e.tilt, 64 * PI / 180, 1e-3) and near(e.pressure, 0)

# ---- macOS ----

block:
  var e = Event()
  penFromCocoa(e, 0.75, 0.5, 0.5, 30, false)    # +y on macOS: the top leans up
  var lt, la: float32
  penLean(30, -30, lt, la)
  doAssert e.pen and near(e.pressure, 0.75) and near(e.tilt, lt) and near(e.azimuth, la)
  doAssert near(e.twist, 330)                  # counter-clockwise 30 is clockwise 330
  e = Event()
  penFromCocoa(e, 0.2, 0, 0, 0, true)
  doAssert e.twist == -1 and near(e.pressure, 0.2) and e.tilt == 0

# ---- SDL3 ----

block:
  var e = Event()
  penFromSdl3(e, [0.4'f32, -45, 0, 0, -90, 0, 0], false)
  doAssert e.pen and near(e.pressure, 0.4) and near(e.tilt, PI / 4) and near(e.azimuth, PI)
  doAssert near(e.twist, 270)
  e = Event()
  penFromSdl3(e, [1.5'f32, 0, 0, 0, 0, 0, 0], true)
  doAssert e.pressure == 1 and e.twist == -1

echo "pen mapping tests passed"
