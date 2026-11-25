## Export for Screens: the artboards, the objects picked (assets) or the whole document, each
## as files at several scales (1x, 2x, 3x...: type and shapes drawn again at each, sharp) and
## in several formats (PNG, JPEG, WebP; SVG and PDF once, as vectors), named with a prefix and
## a suffix for each scale, in a folder for each scale or format when asked.
##
## ```nim
## var o = defaultScreenExport()
## o.formats = {sfPng, sfSvg}
## let files = d.exportForScreens(d.assetItems(d.pickedLayers), o, "/tmp/out")
## ```
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, math]
import gfx, pdf, photo, photofiles, photosvg, photopdf, photocc

type
  ScreenFormat* = enum
    ## A format Export for Screens writes.
    sfPng = "PNG", sfJpeg = "JPEG", sfWebp = "WebP", sfSvg = "SVG", sfPdf = "PDF"

  ScreenItem* = object
    ## One thing to export: its name, the layers it shows, the box it is cut to.
    name*: string
    layers*: seq[Layer]
    box*: Rect
    paper*: uint32              ## an artboard's color under it (alpha 0: none)

  ScreenExport* = object
    ## How Export for Screens writes the files.
    scales*: seq[tuple[scale: float; suffix: string]]  ## each scale and what its files' names end in
    formats*: set[ScreenFormat]
    prefix*: string             ## put before every name
    folderPerScale*: bool       ## a folder for each scale ("1x", "2x"...)
    folderPerFormat*: bool      ## a folder for each format ("png", "svg"...)
    quality*: int               ## JPEG and WebP, 1..100

proc defaultScreenExport*(): ScreenExport =
  ## 1x, 2x ("@2x") and 3x ("@3x") as PNG.
  ScreenExport(scales: @[(1.0, ""), (2.0, "@2x"), (3.0, "@3x")], formats: {sfPng}, quality: 85)

proc safeName(s: string): string =
  result = ""          # (a value at once: see tools/writecheck.py)
  for c in s:
    result.add(if c in {'/', '\\', ':', '*', '?', '"', '<', '>', '|'}: '_' else: c)
  result = result.strip
  if result.len == 0: result = "Untitled"

proc boxOfLayers(d: Doc; ls: seq[Layer]): Rect =
  for L in ls:
    if L.group or not L.visible: continue
    let b = d.objectBox(L)
    let r = if b.ok: rect(int(floor(b.x0)), int(floor(b.y0)), int(ceil(b.x1)) - int(floor(b.x0)),
                          int(ceil(b.y1)) - int(floor(b.y0)))
            else: d.contentBounds(L)
    if r.w > 0 and r.h > 0: result = if result.w > 0: union(result, r) else: r

proc assetItems*(d: Doc; idxs: seq[int]): seq[ScreenItem] =
  ## The layers `idxs` (a group: with all in it), each an item cut to what it shows.
  for (lo, hi) in d.blocksOf(idxs):
    var ls: seq[Layer]
    for j in lo .. hi: ls.add d.layers[j]
    let b = d.boxOfLayers(ls)
    if b.w > 0 and b.h > 0: result.add ScreenItem(name: d.layers[hi].name, layers: ls, box: b)

proc artboardItems*(d: Doc; which: seq[int] = @[]): seq[ScreenItem] =
  ## The artboards (`which`: those, by their number; none: all), each what is on it -- the artwork
  ## over its paper -- cut to it.
  for i in 0 ..< d.boards.len:
    if which.len > 0 and i notin which: continue
    let bd = d.boards[i]
    let box = d.clip(bd.r)
    if box.w <= 0 or box.h <= 0: continue
    var ls: seq[Layer]
    for L in d.layers:
      if L.group: continue
      let c = d.contentBounds(L)
      if L.adjust.kind.len > 0 or (c.w > 0 and c.intersects(box)): ls.add L
    result.add ScreenItem(name: bd.name, layers: ls, box: box, paper: bd.color)

proc artboardList*(d: Doc; range: string): seq[int] =
  ## The artboards (0-based) a range names, in their order, each once: "" or "all" every one;
  ## "3", "2-5", "7-" (to the last), "-4" (from the first), commas or spaces between; by their
  ## place in the order, from 1. What is past the last is left out.
  let n = d.boards.len
  var want = newSeq[bool](n)
  let r = range.strip.toLowerAscii
  if r.len == 0 or r == "all":
    for i in 0 ..< n: want[i] = true
  else:
    for part0 in r.replace(" ", ",").split(','):
      let part = part0.strip
      if part.len == 0: continue
      var a, z: int
      try:
        let dash = part.find('-')
        if dash < 0:
          a = parseInt(part)
          z = a
        else:
          a = if dash == 0: 1 else: parseInt(part[0 ..< dash].strip)
          z = if dash == part.high: n else: parseInt(part[dash + 1 .. ^1].strip)
      except ValueError: continue
      if a > z: swap(a, z)
      for i in max(1, a) .. min(n, z): want[i - 1] = true
  for i in 0 ..< n:
    if want[i]: result.add i

proc artboardSheets*(d: Doc; which: seq[int] = @[]; spreads = false): seq[seq[int]] =
  ## The sheets the artboards print and export as (`which`: those; none: all): each alone, or with
  ## `spreads` those of each spread (`boardSpreads`: with `boardFacing` the first alone, then two
  ## by two) that are asked for, together, the left one first.
  let all = which.len == 0
  if spreads:
    for sp in d.boardSpreads:
      var sheet: seq[int]
      for i in sp:
        if all or i in which: sheet.add i
      if sheet.len > 0: result.add sheet
  else:
    for i in 0 ..< d.boards.len:
      if all or i in which: result.add @[i]

proc documentItem*(d: Doc): ScreenItem =
  ## The whole document.
  ScreenItem(name: d.name, layers: d.layers, box: d.bounds)

proc itemDoc*(d: Doc; it: ScreenItem; scale = 1.0): Doc =
  ## A document of the item alone, its box's size times `scale` (type and shapes drawn again
  ## at it): copies of its layers, the groups left out -- what is in them kept, in order.
  let w = max(1, it.box.w)
  let h = max(1, it.box.h)
  result = newDoc(w, h, (if (it.paper shr 24) > 0: it.paper or 0xFF000000'u32 else: 0'u32), d.dpi, it.name)
  for k, b in d.boards:
    if b.r == it.box:
      # (an artboard: `<#>` on it its number, `<##>` how many there are -- as on the canvas)
      result.pageLabel = d.boardLabel(k)
      result.pageTotal = $d.boards.len
      break
  var copies: seq[Layer]
  for L in it.layers:
    if L.group or not L.visible or L.adjust.kind.len > 0: continue
    let C = layerFor(L, d.w, d.h, w, h, -it.box.x, -it.box.y)
    C.depth = 0
    copies.add C
  discard result.placeLayers(copies, above = 0)
  # (the empty layer a new document starts with: gone, when there is more)
  if result.layers.len > 1 and not result.layers[0].isText and not result.layers[0].isShape:
    var empty = true
    for p in result.layers[0].px:
      if p != 0:
        empty = false
        break
    if empty: result.layers.delete(0)
  if abs(scale - 1) > 1e-6:
    result.imageSize(max(1, int(round(w.float * scale))), max(1, int(round(h.float * scale))))
  result.modified = false

proc saveArtboardsPdf*(d: Doc; path: string; o: PdfOptions; which: seq[int] = @[]; spreads = false): int =
  ## The artboards as a PDF (`which`: those; none: all), each a page of its own size -- what is
  ## on it, over its paper, its type and shapes as `o` says --, or with `spreads` each spread a
  ## page (`artboardSheets`), its pages side by side, each showing only on its side of the spine;
  ## how many pages. Raises `IOError` when it cannot be written.
  let pdf = newPressPdf(o, if o.title.len > 0: o.title else: d.name)
  for sheet in d.artboardSheets(which, spreads):
    var docs: seq[Doc]
    for it in d.artboardItems(sheet): docs.add d.itemDoc(it)
    if docs.len == 0: continue
    pdf.addSpreadPage(docs, o)
    inc result
  pdf.save(path)

proc exportForScreens*(d: Doc; items: seq[ScreenItem]; o: ScreenExport; dir: string): seq[string] =
  ## Each item written in `dir` at each scale and in each format `o` says; the files written.
  ## SVG and PDF once each (vectors: at any size), with no scale's suffix. Raises `IOError`
  ## when a file cannot be written.
  for it in items:
    let base = o.prefix & safeName(it.name)
    proc target(sub, file: string): string =
      let folder = if sub.len > 0: dir / sub else: dir
      createDir(folder)
      folder / file
    for (scale, suffix) in o.scales:
      let raster = o.formats * {sfPng, sfJpeg, sfWebp}
      if raster.len == 0: break
      let sd = d.itemDoc(it, scale)
      let scaleDir = if o.folderPerScale: (if scale == floor(scale): $int(scale) & "x" else: $scale & "x") else: ""
      for f in raster:
        let (fmt, ext) = case f
                         of sfJpeg: (efJpeg, ".jpg")
                         of sfWebp: (efWebp, ".webp")
                         else: (efPng, ".png")
        var eo = defaultExport(fmt)
        eo.quality = clamp(o.quality, 1, 100)
        var sub = scaleDir
        if o.folderPerFormat: sub = (if sub.len > 0: sub & "/" else: "") & toLowerAscii($f)
        let p = target(sub, base & suffix & ext)
        sd.exportPicture(p, eo)
        result.add p
    if sfSvg in o.formats or sfPdf in o.formats:
      let vd = d.itemDoc(it, 1.0)
      if sfSvg in o.formats:
        let p = target(if o.folderPerFormat: "svg" else: "", base & ".svg")
        writeFile(p, vd.svgOf())
        result.add p
      if sfPdf in o.formats:
        let p = target(if o.folderPerFormat: "pdf" else: "", base & ".pdf")
        vd.savePdf(p, pdfPreset(ppWeb))
        result.add p
