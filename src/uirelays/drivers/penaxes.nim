# How a pen is held, from what the desktop systems report about it, into the
# pen fields of `Event`. Pure arithmetic, shared by the drivers for
# Windows, X11, macOS, GTK4 and SDL3, and tested on its own in
# tests/penaxestest.nim.
# Kept to plain procs and libc's <math.h>: the X11 driver that imports it is
# also built with the second compiler.

import ../input

proc c_atan2(y, x: cdouble): cdouble {.importc: "atan2", header: "<math.h>".}
proc c_atan(x: cdouble): cdouble {.importc: "atan", header: "<math.h>".}
proc c_tan(x: cdouble): cdouble {.importc: "tan", header: "<math.h>".}
proc c_sqrt(x: cdouble): cdouble {.importc: "sqrt", header: "<math.h>".}
proc c_fmod(x, y: cdouble): cdouble {.importc: "fmod", header: "<math.h>".}

const
  PenPi = 3.141592653589793
  PenHalfPi = 1.5707963267948966
  PenDegToRad = 0.017453292519943295

proc clampTo(v, lo, hi: float): float {.inline.} =
  if v < lo: lo elif v > hi: hi else: v

proc turnDegrees*(deg: float): float =
  ## An angle in degrees brought into 0 ..< 360.
  result = c_fmod(deg, 360.0)
  if result < 0: result += 360.0
  if result >= 360.0: result = 0

proc penLean*(tiltXDeg, tiltYDeg: float; tilt, azimuth: var float32) =
  ## A pen's lean from the two angles tablets report -- degrees from upright
  ## seen along each axis, + when the top of the pen leans right (x) or
  ## towards the bottom of the screen (y) -- as `Event` has it: how far from
  ## upright (radians, 0 .. pi/2) and which way the top leans (radians, 0 to
  ## the right, clockwise, 0 ..< 2 pi).
  let ax = clampTo(tiltXDeg, -90, 90)
  let ay = clampTo(tiltYDeg, -90, 90)
  var t, a: float
  if ax == 0 and ay == 0:
    t = 0
    a = 0
  elif abs(ax) >= 90 or abs(ay) >= 90:
    # lying flat: only the direction is left
    t = PenHalfPi
    let dx = (if abs(ax) >= 90: (if ax > 0: 1.0 else: -1.0) else: 0.0)
    let dy = (if abs(ay) >= 90: (if ay > 0: 1.0 else: -1.0) else: 0.0)
    a = c_atan2(dy, dx)
  else:
    let tx = c_tan(ax * PenDegToRad)
    let ty = c_tan(ay * PenDegToRad)
    t = c_atan(c_sqrt(tx * tx + ty * ty))
    a = c_atan2(ty, tx)
  if a < 0: a += 2 * PenPi
  tilt = float32(t)
  azimuth = float32(a)

proc setPen*(e: var Event; pressure, tiltXDeg, tiltYDeg, twistDeg: float;
             eraser: bool) =
  ## Marks `e` as a pen's and fills in how it is held: `pressure` 0 .. 1,
  ## the lean as for `penLean`, its turn in degrees clockwise, and whether
  ## it is the eraser end (`twist` -1, as the touch drivers have it).
  e.pen = true
  e.fromMouse = true          # a pen, not a finger: it hovers
  e.pressure = float32(clampTo(pressure, 0, 1))
  penLean(tiltXDeg, tiltYDeg, e.tilt, e.azimuth)
  e.twist = if eraser: -1'f32 else: float32(turnDegrees(twistDeg))

# ---- Windows (WM_POINTER, POINTER_PEN_INFO) ----

const
  PenFlagBarrel* = 0x1'u32    ## PEN_FLAG_BARREL: the side button is down
  PenFlagInverted* = 0x2'u32  ## PEN_FLAG_INVERTED: the eraser end is near
  PenFlagEraser* = 0x4'u32    ## PEN_FLAG_ERASER: the eraser end touches
  PenMaskPressure* = 0x1'u32  ## PEN_MASK_PRESSURE: `pressure` is valid
  PenMaskRotation* = 0x2'u32  ## PEN_MASK_ROTATION: `rotation` is valid
  PenMaskTiltX* = 0x4'u32     ## PEN_MASK_TILT_X
  PenMaskTiltY* = 0x8'u32     ## PEN_MASK_TILT_Y

proc penFromWindows*(e: var Event; pressure, rotation: uint32;
                     tiltX, tiltY: int32; penFlags, penMask: uint32;
                     inContact: bool) =
  ## A Windows pen (POINTER_PEN_INFO): pressure 0 .. 1024, rotation in
  ## degrees clockwise, tilts -90 .. 90 degrees (+ right, + towards the
  ## user). What the pen does not report: pressed all the way while it
  ## touches, upright, not turned.
  let p = if (penMask and PenMaskPressure) != 0: float(pressure) / 1024.0
          elif inContact: 1.0
          else: 0.0
  let tx = if (penMask and PenMaskTiltX) != 0: float(tiltX) else: 0.0
  let ty = if (penMask and PenMaskTiltY) != 0: float(tiltY) else: 0.0
  let r = if (penMask and PenMaskRotation) != 0: float(rotation) else: 0.0
  setPen(e, p, tx, ty, r,
         (penFlags and (PenFlagInverted or PenFlagEraser)) != 0)

# ---- macOS (NSEvent of a tablet) ----

const CocoaTiltDegrees* = 60.0
  ## What a tilt of 1 is on macOS, which reports tilt scaled to -1 .. 1: the
  ## lean at the end of a tablet's range (Wacom's pens report up to about
  ## 60 degrees; Qt scales by the same).

proc penFromCocoa*(e: var Event; pressure, tiltX, tiltY, rotation: float;
                   eraser: bool) =
  ## A macOS tablet event: `pressure` 0 .. 1, `tilt` x and y -1 .. 1 (+y:
  ## the top leans towards the top of the tablet), `rotation` in degrees
  ## counter-clockwise; `eraser` from the proximity event.
  setPen(e, pressure, tiltX * CocoaTiltDegrees, -tiltY * CocoaTiltDegrees,
         -rotation, eraser)

# ---- SDL3 (SDL_PenAxis) ----

proc penFromSdl3*(e: var Event; axes: array[7, float32]; eraser: bool) =
  ## SDL3's pen axes as SDL_EVENT_PEN_AXIS last reported them, in its order
  ## (pressure 0 .. 1, x tilt and y tilt -90 .. 90 degrees, distance,
  ## rotation -180 .. 180 degrees clockwise, slider, tangential pressure).
  setPen(e, float(axes[0]), float(axes[1]), float(axes[2]), float(axes[4]),
         eraser)

# ---- X11 (XInput 2 valuators of a tablet device) ----

type
  PenValuator* = object
    ## One axis of a tablet device: which of its valuators says it, that
    ## valuator's range and the last value it had.
    number*: int              ## (-1: the device has none)
    lo*, hi*: float
    value*: float

  TabletDevice* = object
    ## A pen (or its eraser end) as an X input device.
    id*: int                  ## the X input device
    name*: string
    eraser*: bool             ## the eraser end (by the device's name or type)
    pressure*, tiltX*, tiltY*, rotation*: PenValuator
    rotationRz*: bool         ## `rotation` is xf86-input-libinput's "Abs Rz"
                              ## (+-max is a whole turn), not "Abs Wheel"

const PenAxisLabels* = ["Abs Pressure", "Abs Tilt X", "Abs Tilt Y",
                        "Abs Wheel", "Abs Rz"]
  ## The valuator labels (X atoms) a tablet's axes go by.

proc newTabletDevice*(id: int; name: string): TabletDevice =
  ## A device with none of the axes yet.
  result = TabletDevice(id: id, name: name)
  result.pressure.number = -1
  result.tiltX.number = -1
  result.tiltY.number = -1
  result.rotation.number = -1

proc addValuator*(t: var TabletDevice; label: string; number: int;
                  lo, hi, value: float) =
  ## The device's valuator `number`, labelled `label`, with its range.
  let v = PenValuator(number: number, lo: lo, hi: hi, value: value)
  if label == PenAxisLabels[0]: t.pressure = v
  elif label == PenAxisLabels[1]: t.tiltX = v
  elif label == PenAxisLabels[2]: t.tiltY = v
  elif label == PenAxisLabels[3]:
    if t.rotation.number < 0: t.rotation = v
  elif label == PenAxisLabels[4]:
    t.rotation = v
    t.rotationRz = true

proc lowered(s: string): string =
  result = s
  for i in 0 ..< result.len:
    if result[i] in {'A' .. 'Z'}: result[i] = char(ord(result[i]) + 32)

proc contains(s, part: string): bool =
  if part.len == 0: return true
  var i = 0
  while i + part.len <= s.len:
    var k = 0
    while k < part.len and s[i + k] == part[k]: inc k
    if k == part.len: return true
    inc i
  false

proc isEraserName*(name: string): bool =
  ## The device is a pen's eraser end, by its name ("... eraser" from the
  ## Wacom driver and Xwayland, "... Eraser (0x...)" from libinput's).
  lowered(name).contains("eraser")

proc isTablet*(t: TabletDevice): bool =
  ## A pen: it reports pressure, and either leans or is called one (a touch
  ## pad or screen that reports pressure is not).
  if t.pressure.number < 0 or t.pressure.hi <= t.pressure.lo: return false
  if t.tiltX.number >= 0 or t.tiltY.number >= 0: return true
  let n = lowered(t.name)
  for w in ["pen", "stylus", "eraser", "tablet", "wacom", "tool"]:
    if n.contains(w): return true
  false

proc updateValuators*(t: var TabletDevice; mask: ptr UncheckedArray[uint8];
                      maskLen: int; values: ptr UncheckedArray[float64]) =
  ## The values an XInput 2 event carries (one for each bit set in `mask`,
  ## in order) into the device's axes; an axis the event leaves out keeps
  ## its last value.
  if mask == nil or values == nil: return
  var k = 0
  for bit in 0 ..< maskLen * 8:
    if (mask[bit shr 3] and uint8(1 shl (bit and 7))) == 0: continue
    let v = float(values[k])
    inc k
    if bit == t.pressure.number: t.pressure.value = v
    if bit == t.tiltX.number: t.tiltX.value = v
    if bit == t.tiltY.number: t.tiltY.value = v
    if bit == t.rotation.number: t.rotation.value = v

proc tiltDegrees(v: PenValuator): float =
  if v.number < 0 or v.hi <= v.lo: return 0
  if v.lo < 0 and v.hi > 0 and v.lo >= -90 and v.hi <= 90:
    v.value                   # degrees (Wacom, libinput, Xwayland: -64 .. 63)
  else:
    # another range: its ends taken as a tablet's usual +-64 degrees
    ((v.value - v.lo) / (v.hi - v.lo) * 2 - 1) * 64

proc rotationDegrees(t: TabletDevice): float =
  let v = t.rotation
  if v.number < 0 or v.hi <= v.lo: return 0
  if t.rotationRz:
    # xf86-input-libinput: degrees * max / 360
    v.value * 360 / max(abs(v.lo), abs(v.hi))
  elif v.lo < 0:
    # the Wacom driver and Xwayland: 5 to a degree, 0 with the buttons to
    # the right (Xwayland: (degrees + 90) * 5)
    v.value * 360 / (v.hi - v.lo + 1) - 90
  else:
    (v.value - v.lo) * 360 / (v.hi - v.lo + 1)

proc penFromTablet*(e: var Event; t: TabletDevice) =
  ## How the pen of tablet device `t` is held now, into `e`.
  let p = t.pressure
  let pressure = if p.number >= 0 and p.hi > p.lo: (p.value - p.lo) / (p.hi - p.lo)
                 else: 1.0
  setPen(e, pressure, tiltDegrees(t.tiltX), tiltDegrees(t.tiltY),
         rotationDegrees(t), t.eraser)
