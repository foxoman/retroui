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
