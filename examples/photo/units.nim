# (included by photo.nim) Lengths in the rulers' unit (Preferences > Units & Rulers): every
# layout dialog's lengths are shown and typed in it, kept as they were (the document's pixels,
# or points).

proc unitDecimalsOf(u: RulerUnit): int =
  case u
  of ruPixels: 0
  of ruPoints, ruPicas, ruMillimeters, ruPercent: 1
  of ruCentimeters: 2
  of ruInches: 3

proc defaultGutter(d: Doc): float32 =
  ## (the room between a text box's columns when none was given: 12 points -- a pica, the layout
  ## programs' -- at the document's resolution: 50 pixels at 300 ppi, not 12)
  float32(12.0 * max(1.0, (if d != nil: d.dpi else: 72.0)) / 72.0)

proc gutterShown(d: Doc; t: TextData): float32 =
  ## (a text box's gutter as its dialogs show it: its own; with none, in columns, the 12 pixels
  ## the type engine gives it; in one column, what its columns will get)
  if t.gutter > 0: t.gutter elif max(1, t.columns) > 1: 12'f32 else: d.defaultGutter

proc printSize(d: Doc; px: float32): string =
  ## (a length in pixels as it prints, when the rulers count pixels: "= 4.2 mm at 300 ppi" -- a
  ## gutter of 50 pixels is narrow on a page of 300 ppi; "" in another unit, which says it)
  if viewPrefs.rulerUnit != ruPixels or d == nil: return ""
  let dpi = max(1.0, d.dpi)
  let mm = float(px) / dpi * 25.4
  "= " & formatFloat(mm, ffDecimal, (if mm < 10: 1 else: 0)) & " mm " & tr("at") & " " & $int(round(dpi)) & " ppi"

proc unitShort(): string =
  ## (the rulers' unit's short name: "mm", "pt", "px"...)
  unitAbbrev(viewPrefs.rulerUnit)

proc lengthField(d: Doc; px: var float32; w: int; lo = 0.0; hi = 99999.0; enabled = true): bool =
  ## (a length kept in the document's pixels, shown and typed in the rulers' unit -- with its
  ## pixels' worth of decimals, so a pixel is never lost; `lo` and `hi` in pixels)
  let u = viewPrefs.rulerUnit
  let per = if d != nil: unitPixels(u, d.dpi, d.w) else: 1.0
  var v = float(px) / per
  let dec = if u == ruPixels: (if abs(float(px) - round(float(px))) > 0.01: 1 else: 0)
            else: unitDecimalsOf(u)
  if numberEdit(v, decimals = dec, w = w, lo = lo / per, hi = hi / per, thousands = false, enabled = enabled):
    px = float32(clamp(v * per, lo, hi))
    return true

proc lengthField(d: Doc; px: var int; w: int; lo = 0; hi = 99999; enabled = true): bool =
  ## (the same for a length kept in whole pixels)
  var f = float32(px)
  if d.lengthField(f, w, lo.float, hi.float, enabled):
    px = int(round(f))
    return true

proc pointsField(d: Doc; pts: float32; w: int; enabled = true): tuple[changed: bool; pts: float32] =
  ## (a length kept in points, shown and typed in the rulers' unit)
  let u = viewPrefs.rulerUnit
  let perUnit = unitPixels(u, d.dpi, d.w) / (max(1.0, d.dpi) / 72)       # (points in one unit)
  var v = float(pts) / perUnit
  if numberEdit(v, decimals = unitDecimalsOf(u), w = w, lo = -9999, hi = 9999, enabled = enabled):
    result = (true, float32(v * perUnit))
  else: result = (false, pts)

var sidesLinked: Table[string, bool]   ## (each four-sided field's link: on or off, by its key)

proc sidesFields(d: Doc; v: var array[4, float32]; key: string;
                 caps: array[4, string] = ["Top:", "Right:", "Bottom:", "Left:"]; lo = 0.0; hi = 4000.0): bool =
  ## (four lengths -- top, right, bottom, left, as the type engine keeps them -- in two rows, top
  ## and left, bottom and right, with a link beside them: on, the one typed in gives all four its
  ## value, as the layout program's "Make all settings the same"; on at first when they are equal)
  var linked = sidesLinked.getOrDefault(key, v[0] == v[1] and v[1] == v[2] and v[2] == v[3])
  let was = v
  row([80, 84, 70, 84, -1]):
    label caps[0]
    discard d.lengthField(v[0], dp(80), lo, hi)
    label caps[3]
    discard d.lengthField(v[3], dp(80), lo, hi)
    if toolButton(glyphIcon(nfLink, ui.theme.text, dp(15)),
                  if linked: tr("Make all settings the same: on (click: off)")
                  else: tr("Make all settings the same: off (click: on)"), down = linked):
      linked = not linked
      if linked: v = [v[0], v[0], v[0], v[0]]
  row([80, 84, 70, 84, -1]):
    label caps[2]
    discard d.lengthField(v[2], dp(80), lo, hi)
    label caps[1]
    discard d.lengthField(v[1], dp(80), lo, hi)
    label unitShort()
  if linked and v != was:
    # (linked: the side that changed gives the others its value)
    for k in 0 .. 3:
      if v[k] != was[k]:
        v = [v[k], v[k], v[k], v[k]]
        break
  sidesLinked[key] = linked
  v != was

proc typePixels(d: Doc): float =
  ## (pixels in one of type's unit -- Preferences > Units & Rulers > Type -- at the document's
  ## resolution: a point is 4.2 pixels at 300 ppi; with no document, at 72)
  typeUnitPixels(viewPrefs.typeUnit, if d != nil: d.dpi else: 72.0)

proc typeShort(): string =
  ## (type's unit's short name: "pt", "px", "mm")
  typeUnitAbbrev(viewPrefs.typeUnit)

const typeSizes: array[TypeUnit, seq[float]] = [
  @[6.0, 7, 8, 9, 10, 11, 12, 14, 18, 21, 24, 30, 36, 48, 60, 72],     # points
  @[8.0, 10, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64, 72, 96, 128], # pixels
  @[2.0, 2.5, 3, 3.5, 4, 5, 6, 8, 10, 12, 15, 20, 25]]                 # millimeters
  ## (the sizes a size box lists, in type's unit: the photo program's in points)

proc typeField(d: Doc; px: float32; w: int; id: string; lo = 0.0; hi = 99999.0;
               enabled = true; size = false): tuple[changed: bool; px: float32] =
  ## (a length of type -- a size, a leading, a shift, an indent -- kept in the document's pixels,
  ## shown and typed in type's unit, points by default, as the photo program shows it: "12",
  ## "10.5"; a box with arrows that step it a point -- half a millimeter --, and for a size the
  ## usual sizes in a list beside it (`size`); `lo` and `hi` in that unit; `id` its own, each
  ## field another)
  let per = d.typePixels
  var v = float(px) / per
  let mm = viewPrefs.typeUnit == tuMillimeters
  pushId(id)
  let room = (if fingers(): dp(26) else: dp(16)) + (if size: SbW else: 0)
  let ch = numberSpin(v, lo, hi, step = (if mm: 0.5 else: 1.0), decimals = (if mm: 2 else: 1),
                      w = w + room, sizes = (if size: typeSizes[viewPrefs.typeUnit] else: @[]),
                      enabled = enabled)
  popId()
  if ch: result = (true, float32(v * per))
  else: result = (false, px)

proc pointsOf(d: Doc; px: float): float =
  ## (pixels of the document in points: 67 pixels at 400 ppi are 12 points)
  px * 72 / max(1.0, if d != nil: d.dpi else: 72.0)

proc pixelsOf(d: Doc; pt: float): float =
  ## (points in the document's pixels)
  pt * max(1.0, if d != nil: d.dpi else: 72.0) / 72
