# (included by photo.nim) Lengths in the rulers' unit (Preferences > Units & Rulers): every
# layout dialog's lengths are shown and typed in it, kept as they were (the document's pixels,
# or points).

proc unitDecimalsOf(u: RulerUnit): int =
  case u
  of ruPixels: 0
  of ruPoints, ruPicas, ruMillimeters, ruPercent: 1
  of ruCentimeters: 2
  of ruInches: 3

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
