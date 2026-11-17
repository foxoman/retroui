## The inks a document prints with: the four process inks and its spot colors (a brand's own
## color, a metallic, a varnish -- an ink of its own, a plate of its own), what the Ink
## Manager says of them (a spot printed in process inks instead; one ink printed as another,
## an alias), the plates a pixel makes (Separations Preview: each ink alone or some together,
## how much ink is at a point) and overprinting (Overprint Preview: an object's inks printed
## over what is under it instead of knocking it out -- where it has none of an ink, the one
## under it shows, as presses do it with the nonzero overprint mode).
##
## .. code-block:: nim
##   import retroui/inks
##   let brand = spotInk("Retro Red", 0xFFC8102E'u32)          # its CMYK from the inks' setup
##   var s = InkSettings()
##   s.toProcess.add "Retro Red"                               # (no plate for it: in CMYK)
##   echo plates(@[brand], s).len                              # 4
##   let p = separationPx([0'u8, 255, 255, 0], [], [true, true, true, true], plates(@[], s))
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, strutils]
import photoinks

type
  SpotKind* = enum
    ## How a spot ink prints with the others (the Ink Manager's Type).
    skNormal = "Normal",                 ## as most inks: under and over the others
    skTransparent = "Transparent",       ## a varnish, a clear coat: shows what is under it
    skOpaque = "Opaque",                 ## a metallic, an opaque white: hides what is under it
    skOpaqueIgnore = "OpaqueIgnore"      ## ... and left out of trapping

  SpotInk* = object
    ## A spot color: an ink of its own.
    name*: string                        ## its name, as the printer knows it
    color*: uint32                       ## how it looks (sRGB, opaque)
    cmyk*: Ink                           ## how it is printed in process inks (C, M, Y, K 0..255)
    kind*: SpotKind                      ## how it prints with the others
    density*: float                      ## its neutral density (0: from its color)

  InkSettings* = object
    ## The Ink Manager: what prints on which plate.
    allToProcess*: bool                  ## All Spots to Process: no plates but the four
    toProcess*: seq[string]              ## these spots printed in process inks
    aliases*: seq[tuple[ink, asInk: string]]  ## Ink Alias: `ink` printed on `asInk`'s plate

  Plate* = object
    ## A plate of the press: an ink.
    name*: string                        ## "Cyan", "Magenta", "Yellow", "Black", or a spot's
    color*: uint32                       ## the ink's color
    process*: int                        ## a process ink: its channel (0 C .. 3 K); -1 a spot
    spots*: seq[int]                     ## a spot plate: the spot inks printed on it (an alias's too)

const
  ProcessNames* = ["Cyan", "Magenta", "Yellow", "Black"]
    ## The process inks' names.
  ProcessColors* = [0xFF00AEEF'u32, 0xFFEC008C'u32, 0xFFFFF200'u32, 0xFF231F20'u32]
    ## ... and how each looks alone on paper.

proc spotInk*(name: string; color: uint32; kind = skNormal): SpotInk =
  ## A spot ink of that look, its process inks as the inks' setup separates the color.
  SpotInk(name: name, color: color or 0xFF000000'u32, cmyk: inkOf(color or 0xFF000000'u32), kind: kind)

proc findSpot*(spots: openArray[SpotInk]; name: string): int =
  ## Where the ink called `name` is (case aside), -1 none.
  for i, s in spots:
    if cmpIgnoreCase(s.name, name) == 0: return i
  -1

proc resolved*(s: InkSettings; name: string): string =
  ## The ink `name` is printed as: its alias's (an alias of an alias followed; a loop stops).
  result = name
  for _ in 0 .. 16:
    var moved = false
    for a in s.aliases:
      if cmpIgnoreCase(a.ink, result) == 0 and a.asInk.len > 0 and cmpIgnoreCase(a.asInk, result) != 0:
        result = a.asInk
        moved = true
        break
    if not moved: return

proc toProcessOn*(s: InkSettings; name: string): bool =
  ## Spot ink `name` is printed in process inks (All Spots to Process, or it is listed, or
  ## the ink it is printed as is).
  if s.allToProcess: return true
  let r = s.resolved(name)
  for n in s.toProcess:
    if cmpIgnoreCase(n, name) == 0 or cmpIgnoreCase(n, r) == 0: return true
  if cmpIgnoreCase(r, name) != 0 and r in ProcessNames: return true

proc plates*(spots: openArray[SpotInk]; s: InkSettings): seq[Plate] =
  ## The plates the document makes: the four process inks, then a plate for each spot ink
  ## that has one (not printed in process inks; an alias's ink on the plate of the ink it is
  ## printed as).
  for i in 0 .. 3: result.add Plate(name: ProcessNames[i], color: ProcessColors[i], process: i)
  for i, sp in spots:
    if s.toProcessOn(sp.name): continue
    let r = s.resolved(sp.name)
    var found = -1
    for k in 4 ..< result.len:
      if cmpIgnoreCase(result[k].name, r) == 0: found = k
    if found < 0:
      let j = spots.findSpot(r)
      result.add Plate(name: r, color: (if j >= 0: spots[j].color else: sp.color), process: -1)
      found = result.high
    result[found].spots.add i

proc plateOfSpot*(ps: openArray[Plate]; spot: int): int =
  ## The plate spot ink `spot` prints on, -1 none (it is printed in process inks).
  for k, p in ps:
    if spot in p.spots: return k
  -1

proc inkAmounts*(ps: openArray[Plate]; process: Ink; spotAmt: openArray[uint8];
                 spots: openArray[SpotInk]): seq[int] =
  ## How much of each plate's ink (0..255) a point gets: its process inks, and the spot inks
  ## at it (`spotAmt`, one for each of `spots`) -- each on its plate, or in process inks
  ## when it has none.
  result = newSeq[int](ps.len)
  var c = [int(process[0]), int(process[1]), int(process[2]), int(process[3])]
  for i, a in spotAmt:
    if a == 0 or i >= spots.len: continue
    let k = ps.plateOfSpot(i)
    if k >= 0: result[k] = min(255, result[k] + int(a))
    else:
      # (in process inks: its CMYK, so much of it, over what is there)
      for n in 0 .. 3:
        let v = int(spots[i].cmyk[n]) * int(a) div 255
        c[n] = c[n] + v - c[n] * v div 255
  for k, p in ps:
    if p.process >= 0: result[k] = clamp(c[p.process], 0, 255)

proc coverage*(amounts: openArray[int]): int =
  ## The total ink at a point, % (each ink 0..100: 400 % is the most of the four).
  for a in amounts: result += (a * 100 + 127) div 255

proc separationPx*(amounts: openArray[int]; shown: openArray[bool]; ps: openArray[Plate];
                   blackPlates = false): uint32 =
  ## How a point looks with only the plates `shown` printed (Separations Preview): each ink
  ## over the paper by its amount; one plate alone in black when `blackPlates` (Show Single
  ## Plates in Black).
  var n = 0
  var one = -1
  for k in 0 ..< min(shown.len, ps.len):
    if shown[k]:
      inc n
      one = k
  if n == 1 and blackPlates and one < amounts.len:
    let v = uint32(255 - amounts[one])
    return 0xFF000000'u32 or (v shl 16) or (v shl 8) or v
  var r, g, b = 255
  for k in 0 ..< min(shown.len, min(ps.len, amounts.len)):
    if not shown[k] or amounts[k] == 0: continue
    let a = amounts[k]
    let c = ps[k].color
    # (an ink filters the light: the paper's white times the ink's color, by how much of it)
    r = r * (255 * 255 - a * (255 - int((c shr 16) and 255))) div (255 * 255)
    g = g * (255 * 255 - a * (255 - int((c shr 8) and 255))) div (255 * 255)
    b = b * (255 * 255 - a * (255 - int(c and 255))) div (255 * 255)
  0xFF000000'u32 or (uint32(r) shl 16) or (uint32(g) shl 8) or uint32(b)

proc overprinted*(under, over: Ink; alpha: int; overprint: bool): Ink =
  ## The process inks where `over` (an object's, `alpha` 0..255 of it) is printed on `under`:
  ## knocked out -- `over` replaces them, by its alpha -- or overprinted, where an ink of
  ## `over` is 0 the one under it staying (the nonzero overprint mode).
  for n in 0 .. 3:
    let u = int(under[n])
    let o = int(over[n])
    result[n] = if overprint and o == 0: under[n]
                else: uint8(u + (o - u) * alpha div 255)

proc toJson*(s: SpotInk): JsonNode =
  result = %*{"name": s.name, "color": s.color, "cmyk": [s.cmyk[0], s.cmyk[1], s.cmyk[2], s.cmyk[3]]}
  if s.kind != skNormal: result["kind"] = %($s.kind)
  if s.density > 0: result["density"] = %s.density

proc spotFrom*(j: JsonNode): SpotInk =
  result.name = j{"name"}.getStr
  result.color = uint32(j{"color"}.getBiggestInt(0xFF000000)) or 0xFF000000'u32
  let c = j{"cmyk"}.getElems
  if c.len == 4:
    for n in 0 .. 3: result.cmyk[n] = uint8(clamp(c[n].getInt, 0, 255))
  else: result.cmyk = inkOf(result.color)
  for k in SpotKind:
    if $k == j{"kind"}.getStr: result.kind = k
  result.density = j{"density"}.getFloat(0)

proc toJson*(s: InkSettings): JsonNode =
  result = newJObject()
  if s.allToProcess: result["allToProcess"] = %true
  if s.toProcess.len > 0: result["toProcess"] = %s.toProcess
  if s.aliases.len > 0:
    var a = newJArray()
    for (i, t) in s.aliases: a.add %[i, t]
    result["aliases"] = a

proc inkSettingsFrom*(j: JsonNode): InkSettings =
  if j == nil or j.kind != JObject: return
  result.allToProcess = j{"allToProcess"}.getBool
  for n in j{"toProcess"}.getElems: result.toProcess.add n.getStr
  for a in j{"aliases"}.getElems:
    if a.len == 2: result.aliases.add (a[0].getStr, a[1].getStr)
