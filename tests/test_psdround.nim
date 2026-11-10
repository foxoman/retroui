## Photoshop round trips of what stays editable (retroui/psd, retroui/photofiles):
## type layers (Latin and Arabic, point and box, styles mixed, warped) as
## Photoshop's type layers, Smart Objects (with Smart Filters, in
## perspective, one holding a document with layers) as placed layers with
## their files embedded, groups and masks -- to a .psd and back, and to a
## TIFF that keeps its layers (tag 37724) and back. Then files Photoshop
## wrote (tests/data/psd: samples from the tests of psd-tools and ag-psd,
## both MIT, and Pillow's tiff_adobe_deflate.tif) and one ag-psd wrote,
## read.
##
## The files written are left in the temporary folder ("retro_psdround")
## for other readers to look at (psd-tools, ag-psd).

import std/[unittest, os, strutils]
import retroui/[photo, psd, photofiles, textengine, photowarp, imageformats, imaging, gfx]

let outDir = getTempDir() / "retro_psdround"
createDir(outDir)
const dataDir = currentSourcePath().parentDir / "data" / "psd"

proc pattern(w, h: int): seq[uint32] =
  result = newSeq[uint32](w * h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      result[y * w + x] = 0xFF000000'u32 or uint32((x * 7) and 255) shl 16 or uint32((y * 13) and 255) shl 8 or
                          uint32(((x + y) * 5) and 255)

proc maxDiff(a, b: seq[uint32]): int =
  if a.len != b.len: return 999
  for i in 0 ..< a.len:
    for sh in [0, 8, 16, 24]:
      result = max(result, abs(int((a[i] shr sh) and 255) - int((b[i] shr sh) and 255)))

proc near(a, b: float32; tol = 1e-3): bool = abs(a - b) <= tol

proc sameStyle(a, b: CharStyle): bool =
  ## (what Photoshop's EngineData keeps of a character style)
  a.family == b.family and a.style == b.style and near(a.size, b.size) and a.color == b.color and
    a.tracking == b.tracking and a.noKerning == b.noKerning and near(a.leading, b.leading) and
    near(a.baselineShift, b.baselineShift) and near(a.hScale, b.hScale) and near(a.vScale, b.vScale) and
    a.fauxBold == b.fauxBold and a.fauxItalic == b.fauxItalic and a.allCaps == b.allCaps and
    a.smallCaps == b.smallCaps and a.underline == b.underline and a.strike == b.strike and a.script == b.script and
    a.digits == b.digits

proc sameText(a, b: TextData): bool =
  ## (what Photoshop's type layer keeps of a text)
  if a.spans.len != b.spans.len:
    echo "  spans: ", a.spans.len, " vs ", b.spans.len
    return false
  for k in 0 ..< a.spans.len:
    if a.spans[k].text != b.spans[k].text or not sameStyle(a.spans[k].style, b.spans[k].style):
      echo "  span ", k, ": ", a.spans[k], " vs ", b.spans[k]
      return false
  result = a.para.align == b.para.align and a.para.rtl == b.para.rtl and near(a.para.indentLeft, b.para.indentLeft) and
           near(a.para.indentRight, b.para.indentRight) and near(a.para.indentFirst, b.para.indentFirst) and
           near(a.para.spaceBefore, b.para.spaceBefore) and near(a.para.spaceAfter, b.para.spaceAfter) and
           a.x == b.x and a.y == b.y and a.boxW == b.boxW and a.boxH == b.boxH and a.warp == b.warp and
           a.vertical == b.vertical and a.antialias == b.antialias
  if not result: echo "  para/box: ", a.para, " ", b.para, " ", (a.x, a.y, a.boxW, a.boxH), " ", (b.x, b.y, b.boxW, b.boxH)

proc st(family, style: string; size: float32; color: uint32): CharStyle =
  result = defaultStyle()
  result.family = family
  result.style = style
  result.size = size
  result.color = color

proc named(d: Doc; name: string): Layer =
  for L in d.layers:
    if L.name == name: return L
  raise newException(KeyError, "no layer " & name)

proc rpdOf(d: Doc): string =
  let p = outDir / "inner.rpd"
  d.saveRpd(p)
  readFile(p)

# ---- the document --------------------------------------------------------------------------------------

proc makeDoc(): Doc =
  let d = newDoc(240, 160, 0xFFFFFFFF'u32, name = "round")
  # Latin point text: styles mixed, escaped characters, a character beyond
  # 16 bits, two paragraphs, warped
  var s1 = st("FreeSans", "Regular", 24, 0xFFCC0000'u32)
  s1.tracking = 50
  var s2 = st("FreeSans", "Bold", 30, 0xFF0033CC'u32)
  s2.fauxItalic = true
  s2.underline = true
  s2.baselineShift = 3
  s2.hScale = 1.25
  s2.leading = 40
  var s3 = st("FreeSerif", "Regular", 16.5, 0x80008000'u32)
  s3.allCaps = true
  s3.strike = true
  s3.noKerning = true
  s3.script = scSuper
  var t1 = TextData(spans: @[TextSpan(text: "Hello (", style: s1), TextSpan(text: "World\\", style: s2),
                             TextSpan(text: ")\nsecond \u{1F600} line", style: s3)],
                    x: 120, y: 40, antialias: true)
  t1.para.align = textCenter
  t1.warp = TextWarp(style: wsArc, bend: 30, hDistort: -10, vDistort: 5)
  discard d.addTextLayer(t1)
  # Arabic text in a box: right to left (from its letters), ( ) and the
  # letters whose UTF-16 has their bytes (U+0628, U+0629), Arabic-Indic
  # digits
  var a1 = st("FreeSerif", "Regular", 20, 0xFF006600'u32)
  var a2 = st("FreeSerif", "Bold", 18, 0xFF990099'u32)
  a2.digits = 1
  a2.fauxBold = true
  var t2 = TextData(spans: @[TextSpan(text: "مرحبا بالعالم (مدرسة)\n", style: a1),
                             TextSpan(text: "١٢٣ كتاب", style: a2)],
                    x: 10.5, y: 60, boxW: 150, boxH: 50, antialias: true)
  t2.para.align = textLeft
  t2.para.indentLeft = 4
  t2.para.indentRight = 6
  t2.para.indentFirst = 8
  t2.para.spaceBefore = 2
  t2.para.spaceAfter = 3
  discard d.addTextLayer(t2)
  # a group holding a layer with a mask
  let M = d.addLayer("Masked")
  for y in 100 ..< 150:
    for x in 160 ..< 230: M.px[y * d.w + x] = 0xFF2266AA'u32
  inc M.ver
  d.addLayerMask(mfRevealAll, d.layers.high)
  for y in 120 ..< 130:
    for x in 0 ..< d.w: M.mask.px[y * d.w + x] = 0xFF404040'u32
  discard d.groupLayers(@[d.layers.high], "Group")
  # a Smart Object in perspective, with Smart Filters
  let S = d.addLayer("Smart")
  let pic = pattern(40, 30)
  S.smart = SmartData(src: pic, w: 40, h: 30, quad: [(20.0, 70.0), (70.5, 72.0), (68.0, 110.0), (22.0, 105.25)],
                      name: "photo.png",
                      filters: @[SmartFilter(name: "Gaussian Blur", args: @[2.5], opacity: 80, mode: bmMultiply),
                                 SmartFilter(name: "Invert", off: true, text: "x")])
  S.px = renderSmart(S.smart, d.w, d.h)
  inc S.ver
  # a Smart Object holding a document with layers
  let sub = newDoc(16, 12, 0xFFFFFFFF'u32, name = "inner")
  let dot = sub.addLayer("Dot")
  for y in 3 ..< 9:
    for x in 4 ..< 12: dot.px[y * 16 + x] = 0xFFFF8800'u32
  inc dot.ver
  sub.markAll()
  let S2 = d.addLayer("Smart doc")
  S2.smart = SmartData(src: sub.flattened(), w: 16, h: 12, quad: quadOf(rect(180, 20, 32, 24)), name: "inner.rpd",
                       file: rpdOf(sub))
  S2.px = renderSmart(S2.smart, d.w, d.h)
  inc S2.ver
  d.markAll()
  d

suite "Photoshop documents: what stays editable":
  let d = makeDoc()
  let psdPath = outDir / "round.psd"
  d.savePsd(psdPath)
  let data = readFile(psdPath)
  let p = readPsd(data)

  test "type layers are Photoshop's (TySh with EngineData), their pixels too":
    var n = 0
    for P in p.layers:
      if P.textDesc != nil:
        inc n
        check P.textDesc["EngineData"] != nil and P.textDesc["EngineData"].kind == pkRaw
        check P.px.len == P.w * P.h and P.w > 0
        let e = parseEngineData(P.textDesc["EngineData"].raw)
        check e["EngineDict"]["Editor"]["Text"].text.endsWith("\r")
        var fonts: seq[string]
        for f in e["ResourceDict"]["FontSet"].items: fonts.add f["Name"].text
        check ("FreeSansBold" in fonts or "FreeSerifBold" in fonts) and "AdobeInvisFont" in fonts
    check n == 2

  test "type layers from EngineData alone (what Photoshop would leave)":
    var k = 0
    for P in p.layers:
      if P.textDesc == nil: continue
      let (ok, t) = textOfPsd(P, retro = false)
      check ok
      let orig = (if k == 0: d.layers[1] else: d.layers[2]).text
      check sameText(t, orig)
      inc k
    check k == 2

  test "type layers back exactly (with what Retro kept beside)":
    let back = docOfPsd(p, "back")
    check back.layers.len == d.layers.len
    check back.layers[1].isText and back.layers[1].text == d.layers[1].text
    check back.layers[2].isText and back.layers[2].text == d.layers[2].text
    check back.layers[2].text.plainText.contains("مدرسة")
    # its pixels are the ones written (drawn again only when edited)
    check back.layers[1].px == d.layers[1].px
    # edited, drawn again
    back.setText(back.layers[1], back.layers[1].text)
    check maxDiff(back.layers[1].px, d.layers[1].px) == 0

  test "Retro's own text features ride along (columns, path, Persian digits)":
    var t = d.layers[2].text
    t.columns = 2
    t.gutter = 9
    t.spans[1].style.digits = 2
    t.para.kashida = kaLong
    let e = newDoc(240, 160, 0xFFFFFFFF'u32)
    discard e.addTextLayer(t)
    let back = docOfPsd(readPsd(writePsd(psdOf(e))))
    check back.layers[1].text == t
    # changed in Photoshop (its EngineData not ours): Photoshop's wins
    var q = readPsd(writePsd(psdOf(e)))
    for P in q.layers.mitems:
      if P.textDesc != nil:
        var en = parseEngineData(P.textDesc["EngineData"].raw)
        en["EngineDict"]["Editor"]["Text"] = eText("changed\r")
        en["EngineDict"]["StyleRun"]["RunLengthArray"] = eList(eInt(8))
        en["EngineDict"]["StyleRun"]["RunArray"] = eList(en["EngineDict"]["StyleRun"]["RunArray"][0])
        en["EngineDict"]["ParagraphRun"]["RunLengthArray"] = eList(eInt(8))
        en["EngineDict"]["ParagraphRun"]["RunArray"] = eList(en["EngineDict"]["ParagraphRun"]["RunArray"][0])
        for it in P.textDesc.items.mitems:
          if it[0] == "EngineData": it[1] = PsdValue(kind: pkRaw, raw: engineDataText(en))
    let b2 = docOfPsd(q)
    check b2.layers[1].text.plainText == "changed" and b2.layers[1].text.columns == 0

  test "Smart Objects are placed layers, their files embedded once each":
    check p.linked.len == 2
    check p.linked[0].id != p.linked[1].id
    for f in p.linked:
      check f.id.len == 36 and f.id[8] == '-' and f.id[14] == '4'
    check p.linked[0].fileType == "png " and p.linked[0].name == "photo.png"
    check p.linked[1].fileType == "8BPB" and p.linked[1].name == "inner.psb"
    var placed = 0
    for P in p.layers:
      if P.placedId.len > 0:
        inc placed
        check P.smartDesc != nil and P.smartDesc["Idnt"].s == P.placedId
    check placed == 2
    # the PNG holds the picture as it is
    let b = decodePng(p.linked[0].data)
    check b.w == 40 and b.h == 30 and b.px == d.named("Smart").smart.src

  test "Smart Objects back: picture, corners, filters, name; a document with its layers":
    let back = docOfPsd(p, "back")
    let S = back.named("Smart").smart
    let O = d.named("Smart").smart
    check S != nil and S.src == O.src and S.w == O.w and S.h == O.h
    check S.quad == O.quad
    check S.filters == O.filters and S.name == O.name
    check back.named("Smart").px == d.named("Smart").px and back.named("Smart").depth == 1
    let S2 = back.named("Smart doc").smart
    require S2 != nil
    check S2.w == 16 and S2.h == 12 and S2.src == d.named("Smart doc").smart.src
    check S2.file.len > 0
    let ip = outDir / "inner-back.rpd"
    writeFile(ip, S2.file)
    let inner = loadRpd(ip)
    check inner.layers.len == 2 and inner.layers[1].name == "Dot"

  test "groups and masks come back":
    let back = docOfPsd(p, "back")
    var gi = -1
    for i, L in back.layers:
      if L.group and L.name == "Group": gi = i
    check gi > 0 and back.layers[gi].depth == 0
    let M = back.named("Masked")
    check M.depth == 1 and back.layers.find(M) < gi
    require M.mask != nil
    check (M.mask.px[125 * 240 + 5] and 255) == 0x40 and (M.mask.px[100 * 240 + 5] and 255) == 255
    var names: seq[string]
    for L in back.layers: names.add L.name
    var orig: seq[string]
    for L in d.layers: orig.add L.name
    check names == orig
    check maxDiff(back.flattened(), d.flattened()) <= 2

  test "written again: the same":
    let back = docOfPsd(p, "back")
    let again = readPsd(writePsd(psdOf(back)))
    var a, b: seq[string]
    for P in p.layers:
      if P.textDesc != nil: a.add P.textDesc["EngineData"].raw
    for P in again.layers:
      if P.textDesc != nil: b.add P.textDesc["EngineData"].raw
    check a == b
    check again.linked.len == 2 and again.linked[0].data == p.linked[0].data

suite "Multichannel":
  test "RGB's channels become cyan, magenta, yellow inks; one deleted takes its ink out":
    var d = newDoc(4, 2, 0xFF336699'u32)
    d.toMultichannel()
    check d.mode == cmMultichannel and d.spotBase == cmRGB
    check d.channelNames == @["Cyan", "Magenta", "Yellow"] and not d.hasComposite
    check d.layers[0].px[0] == 0xFF336699'u32                    # (it looks as it did)
    check d.channelGrayOf(d.layers[0].px[0], 1) == 0x66
    d.deleteSpot(0)                                               # (no cyan ink)
    check d.channelNames == @["Magenta", "Yellow"] and d.channelCount == 2
    check d.layers[0].px[0] == 0xFFFF6699'u32
    # editing one ink leaves the others (and the deleted one stays empty)
    d.showChannel(0)
    check d.keepChannels(0xFFFF6699'u32, 0xFF000000'u32) == 0xFFFF0099'u32
    d.showAllChannels()
    check d.keepChannels(0xFFFF6699'u32, 0xFF000000'u32) == 0xFFFF0000'u32
    # to a .psd (Photoshop's mode 7: the plates and their names) and back
    let data = writePsd(psdOf(d))
    let p = readPsd(data)
    check p.mode == pmMultichannel and p.spots.len == 2 and p.spotNames == @["Magenta", "Yellow"]
    check p.layers.len == 0
    let back = docOfPsd(p)
    check back.mode == cmMultichannel and back.channelNames == @["Magenta", "Yellow"]
    check back.spots[0].ch == 1 and back.spots[1].ch == 2
    check back.layers[0].px[0] == 0xFFFF6699'u32
    # its own file, too
    let f = getTempDir() / "retro_multichannel.rpd"
    saveRpd(d, f)
    let again = openPicture(f)
    check again.mode == cmMultichannel and again.channelNames == @["Magenta", "Yellow"]
    removeFile(f)

  test "CMYK's four inks; gray's one":
    var d = newDoc(2, 2, 0xFF336699'u32)
    d.toCMYK()
    d.toMultichannel()
    check d.channelNames == @["Cyan", "Magenta", "Yellow", "Black"] and d.spotBase == cmCMYK
    let before = d.layers[0].px[0]
    check not d.canDeleteSpot                                     # (its inks are the picture's)
    d.deleteSpot(3)
    check d.channelCount == 4 and d.layers[0].px[0] == before
    let back = docOfPsd(readPsd(writePsd(psdOf(d))))
    check back.mode == cmMultichannel and back.spotBase == cmCMYK and back.channelCount == 4
    check back.channelNames == @["Cyan", "Magenta", "Yellow", "Black"]
    check abs(rOf(back.layers[0].px[0]) - rOf(before)) <= 3 and abs(bOf(back.layers[0].px[0]) - bOf(before)) <= 3
    var g = newDoc(2, 2, 0xFF808080'u32)
    g.toGrayscale()
    g.toMultichannel()
    check g.channelNames == @["Black"] and g.spotBase == cmGray and g.channelCount == 1
    g.deleteSpot(0)                                               # (the last one stays)
    check g.channelCount == 1
    g.toRGB()
    check g.mode == cmRGB and g.hasComposite

suite "TIFF with layers (tag 37724)":
  let d = makeDoc()

  test "written with its layers; opened again with them":
    var o = defaultExport(efTiff)
    o.tiffLayers = true
    let path = outDir / "layers.tif"
    d.exportPicture(path, o)
    let data = readFile(path)
    check data[0 .. 1] == "MM"
    let src = tiffImageSource(data)
    check src.layers.startsWith(tiffBlockHead) and not src.littleEndian
    # the merged picture is there for everyone
    let flat = decodeTiff(data)
    check flat.w == d.w and maxDiff(flat.px, d.flattened()) <= 1
    let e = openPicture(path)
    check e.layers.len == d.layers.len
    check e.layers[1].text == d.layers[1].text and e.layers[2].text == d.layers[2].text
    require e.named("Smart").smart != nil and e.named("Smart doc").smart != nil
    check e.named("Smart").smart.filters == d.named("Smart").smart.filters
    check e.named("Smart").smart.src == d.named("Smart").smart.src
    check e.named("Smart").smart.quad == d.named("Smart").smart.quad
    check e.named("Smart doc").smart.file.len > 0
    var masked = false
    for L in e.layers:
      if L.name == "Masked" and L.mask != nil and L.depth == 1: masked = true
    check masked
    check maxDiff(e.flattened(), d.flattened()) <= 2

  test "without the option: as before (one layer)":
    let path = outDir / "flat.tif"
    d.exportPicture(path, defaultExport(efTiff))
    let data = readFile(path)
    check data[0 .. 1] == "II" and tiffImageSource(data).layers.len == 0
    check openPicture(path).layers.len == 1

  test "gray and CMYK TIFFs keep their layers too":
    for (mode, file, photometric) in [(cmGray, "gray.tif", 1), (cmCMYK, "cmyk.tif", 5)]:
      let g = makeDoc()
      g.mode = mode
      var o = defaultExport(efTiff)
      o.tiffLayers = true
      o.transparency = false
      let path = outDir / file
      g.exportPicture(path, o)
      check tiffImageSource(readFile(path)).photometric == photometric
      let e = openPicture(path)
      check e.layers.len == g.layers.len and e.layers[2].text == g.layers[2].text
      check e.named("Smart").smart != nil

suite "files Photoshop and others wrote":
  test "Photoshop: point text, three paragraphs":
    let back = docOfPsd(readPsd(readFile(dataDir / "ps-text-paragraphs.psd")))
    var T: Layer
    for L in back.layers:
      if L.isText: T = L
    check T != nil
    check T.text.plainText == "Line 1\nLine 2\nLine 3 and text"
    let s = T.text.spans[0].style
    check postScriptName(s.family, s.style) == "ArialMT"
    check near(s.size, 13) and s.color == 0xFF000000'u32 and T.text.para.align == textLeft
    check near(T.text.x, 83.8125) and near(T.text.y, 119.72266) and T.text.boxW == 0

  test "Photoshop: text in a box, its transform, auto leading, tracking, baseline shift":
    let back = docOfPsd(readPsd(readFile(dataDir / "ps-type-box.psd")))
    var T: Layer
    for L in back.layers:
      if L.isText: T = L
    check T != nil and T.text.plainText == "A"
    let t = T.text
    check near(t.boxW, 32) and near(t.boxH, 28.02122) and near(t.y, 4.97879) and near(t.x, 0)
    check t.para.align == textCenter
    let s = t.spans[0].style
    check near(s.size, 30) and s.tracking == 15 and near(s.baselineShift, -0.59346) and near(s.leading, 52.5)
    check s.color == 0xFFFF0000'u32

  test "Photoshop: runs of styles, fonts, warp":
    let back = docOfPsd(readPsd(readFile(dataDir / "ps-text-complex.psd")))
    var T: Layer
    for L in back.layers:
      if L.isText: T = L
    check T != nil and T.text.plainText == "Test text aaaa\nxxxxx\n\nOMG !"
    check T.text.warp.style == wsArc and T.text.warp.bend == 50
    check T.text.spans.len >= 5 and T.text.para.align == textCenter
    var fonts: seq[string]
    var underlined = false
    for sp in T.text.spans:
      fonts.add postScriptName(sp.style.family, sp.style.style)
      if sp.style.underline: underlined = true
    check "CourierNewPSMT" in fonts and "MyriadPro-Bold" in fonts and underlined
    check T.text.spans[0].style.noKerning and T.text.spans[0].style.color == 0xFFFF0000'u32

  test "Photoshop: justified text in a box":
    let back = docOfPsd(readPsd(readFile(dataDir / "ps-text-justify.psd")))
    var T: Layer
    for L in back.layers:
      if L.isText: T = L
    check T != nil and T.text.para.align == justifyRight and near(T.text.para.spaceAfter, 10)
    check near(T.text.boxW, 178) and near(T.text.boxH, 169) and near(T.text.x, 11) and near(T.text.y, 11)
    check T.text.plainText.startsWith("Do you think there is an argument")

  test "Photoshop: a Smart Object (its PNG embedded)":
    let p = readPsd(readFile(dataDir / "ps-smart-object.psd"))
    check p.linked.len == 1 and p.linked[0].name == "src.png"
    let back = docOfPsd(p)
    var S: SmartData
    for L in back.layers:
      if L.isSmart: S = L.smart
    check S != nil and S.w == 8 and S.h == 8 and S.name == "src.png"
    check S.quad == [(4.0, 4.0), (12.0, 4.0), (12.0, 12.0), (4.0, 12.0)]
    check S.src[0] == 0xFFC81E1E'u32 and S.src[27] == 0xFFC81E1E'u32    # (as psd-tools reads it: 200, 30, 30)

  test "ag-psd: Arabic type layer, a placed PNG":
    let p = readPsd(readFile(dataDir / "agpsd-arabic.psd"))
    let back = docOfPsd(p)
    var T: Layer
    var S: SmartData
    for L in back.layers:
      if L.isText: T = L
      if L.isSmart: S = L.smart
    check T != nil
    check T.text.plainText == "مرحبا (عالم)\nمدرسة ١٢٣"
    check T.text.spans.len == 3
    check T.text.spans[0].text == "مرحبا " and T.text.spans[0].style.style == "Bold" and
          T.text.spans[0].style.tracking == 20 and T.text.spans[0].style.color == 0xFFC80000'u32
    check T.text.spans[1].style.underline and near(T.text.spans[1].style.size, 12) and
          T.text.spans[1].style.color == 0xFF0000FF'u32
    check T.text.spans[2].text == "٣" and T.text.spans[2].style.color == 0xFF008000'u32
    check T.text.spans[0].style.family == "DejaVu Sans"
    # (Photoshop's paragraph left to right, aligned right: ours so)
    check T.text.para.align == textRight and T.text.para.rtl == 1
    check near(T.text.x, 110) and near(T.text.y, 25)
    check S != nil and S.w == 8 and S.h == 6 and S.name == "dots.png"
    check S.src[1] == 0xFF250BC8'u32                                   # (37, 11, 200)
    check S.quad == [(10.0, 35.0), (26.0, 35.0), (26.0, 47.0), (10.0, 47.0)]

  test "Photoshop: a TIFF in Intel order with its layers (little-endian, 'MIB8ryaL')":
    # (Pillow's test picture tiff_adobe_deflate.tif; its layers' pixels as
    # ImageMagick reads them: the same, all of them)
    let data = readFile(dataDir / "ps-layers-intel.tif")
    let src = tiffImageSource(data)
    check src.littleEndian and src.layers.startsWith(tiffBlockHead & "MIB8ryaL")
    let d = docOfLayeredTiff(data, "intel")
    require d != nil
    check d.w == 278 and d.h == 374 and d.layers.len == 2
    check d.layers[0].name == "Background" and d.layers[1].name == "Layer 1"
    check d.layers[0].px[0] == 0xFFFFFFFF'u32 and d.layers[1].px[0] == 0xFF000000'u32
    check d.layers[1].px[d.layers[1].px.len div 2] == 0xFFB0808C'u32
    check openPicture(dataDir / "ps-layers-intel.tif").layers.len == 2

  test "EngineData written as Photoshop writes it (Photoshop's own, read and written: the same bytes)":
    for f in ["ps-text-paragraphs.psd", "ps-type-box.psd", "ps-text-complex.psd", "ps-text-justify.psd"]:
      for P in readPsd(readFile(dataDir / f)).layers:
        if P.textDesc == nil: continue
        var raw = P.textDesc["EngineData"].raw
        while raw.len > 0 and raw[^1] == '\0': raw.setLen(raw.len - 1)
        check engineDataText(parseEngineData(raw)) == raw

echo "(written: ", outDir, ")"
