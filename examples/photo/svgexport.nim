# Retro Photo -- included by photo.nim
#
# SVG: File > New SVG Drawing (an empty drawing that File > Save writes as
# an SVG), File > Export > SVG -- the shapes as paths, the type as text,
# the rest as pictures inside it (retroui/photosvg) -- and File > Export >
# SVG, Type as Outlines: the letters as paths, for where the fonts are not
# (a printer's, another computer). An .svg opens as layers
# (retroui/svgimport) and is saved again by File > Save.

var
  svgSave: tuple[pick: bool; path: string]          ## File > Export > SVG: the file asked for

proc startSvgDrawing() =
  ## File > New SVG Drawing: an empty drawing, transparent, that is saved
  ## as an SVG.
  let d = newUntitled(1024, 768, 0'u32, 72, cmRGB, "Drawing-" & $(untitled + 1))
  d.format = "svg"
  addDoc(d)
  status = "A drawing: its shapes, pen paths and type stay vectors; File > Save writes an SVG"

var svgOutlines = false      ## (the SVG being exported: its type as outlines)

proc startSvgExport(outlines = false) =
  let d = cur()
  if d == nil: return
  svgOutlines = outlines
  let base = if d.path.len > 0: d.path.splitFile.dir / d.path.splitFile.name
             else: picturesDir() / (if d.name.len > 0: d.name else: "Untitled")
  svgSave = (true, base & ".svg")

proc svgDialogs() =
  if filePicker(svgSave.pick, svgSave.path, fmSave, ["*.svg"], "Export SVG"):
    let d = cur()
    if d != nil:
      var p = svgSave.path
      if p.splitFile.ext.toLowerAscii != ".svg": p.add ".svg"
      try:
        writeFile(p, d.svgOf(outlines = svgOutlines))
        let lost = d.svgLosses
        let own = d.svgOwn
        status = "Saved " & p.extractFilename & ": shapes as paths, type as " &
                 (if svgOutlines: "outlines" else: "text") &
                 (if own.len > 0: "; for Retro Photo alone (other programs do not show them): " & own.join(", ")
                  else: "") &
                 (if lost.len > 0: "; not kept: " & lost.join(", ") else: "")
      except IOError, OSError:
        status = "Could not save " & p.extractFilename
