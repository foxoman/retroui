## A book (or one document) as IDML -- the open, documented package the
## usual page layout program saves and opens for exchange: its pages in
## spreads (facing or not, bound either way), its master pages, its text
## boxes with their stories (fonts, sizes, colors, tracking, leading,
## alignment, indents, direction; Arabic and Latin each in its font; page
## numbers as the program's own), its shapes as rectangles, ovals and
## polygons with their fill and stroke, its pictures as linked PNG files
## beside it. `saveBookIdml`, `saveDocIdml`.
##
## What it has no word for is drawn to pixels (layer styles, blend modes:
## the layer as a picture) or kept simpler: a table goes as text with tabs
## between its cells, text that flows on from box to box as a story each.

import std/[strutils, os, tables, hashes]
import gfx, imaging, jpeg, photo, photobook, photoshapes, textengine, zip

type
  IdmlOut = object
    stories: seq[(string, string)]          ## (id, XML)
    colors: OrderedTable[uint32, string]    ## ARGB -> its Self
    fonts: OrderedTable[string, seq[string]] ## family -> its styles
    links: seq[(string, string)]            ## (file name, PNG bytes)
    linksDir: string
    next: int

proc x(s: string): string =
  ## (XML's text)
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '"': result.add "&quot;"
    else:
      if ord(c) < 0x20 and c notin {'\t', '\n'}: discard
      else: result.add c

proc f(v: float): string =
  ## (a number as IDML writes it)
  if abs(v) < 1e-9: return "0"
  result = formatFloat(v, ffDecimal, 4)
  result.trimZeros()
  if result.endsWith("."): result.setLen(result.len - 1)

proc uid(o: var IdmlOut; prefix = "u"): string =
  inc o.next
  prefix & toHex(o.next + 0x100, 4).toLowerAscii

proc colorRef(o: var IdmlOut; c: uint32): string =
  ## (a color's swatch: "Color/Black" for black, the paper for white, else one of its own)
  let rgb = c and 0xFFFFFF'u32
  if rgb == 0: return "Color/Black"
  if rgb == 0xFFFFFF'u32: return "Color/Paper"
  if rgb notin o.colors:
    let r = (rgb shr 16) and 255
    let g = (rgb shr 8) and 255
    let b = rgb and 255
    o.colors[rgb] = "Color/R=" & $r & " G=" & $g & " B=" & $b
  o.colors[rgb]

proc fontRef(o: var IdmlOut; family, style: string) =
  let fam = if family.len > 0: family else: "FreeSans"
  let st = if style.len > 0: style else: "Regular"
  if fam notin o.fonts: o.fonts[fam] = @[]
  if st notin o.fonts[fam]: o.fonts[fam].add st

proc alignOf(a: TextAlign; rtl: bool): string =
  case a
  of textLeft: (if rtl: "RightAlign" else: "LeftAlign")
  of textCenter: "CenterAlign"
  of textRight: (if rtl: "LeftAlign" else: "RightAlign")
  of justifyLeft: (if rtl: "RightJustified" else: "LeftJustified")
  of justifyCenter: "CenterJustified"
  of justifyRight: (if rtl: "LeftJustified" else: "RightJustified")
  of justifyAll: "FullyJustified"

proc storyOf(o: var IdmlOut; t0: TextData; k: float; master: bool): string =
  ## (a text's story: its paragraphs, each run in its look; on a master, "<#>" the page number)
  let t = scriptFontsApplied(t0)
  let id = o.uid("s")
  var rtl = t.para.rtl == 2
  if t.para.rtl == 0:
    block strong:
      for sp in t.spans:
        for c in sp.text:
          if ord(c) in [0xD8, 0xD9, 0xDA, 0xDB]:
            rtl = true
            break strong
          if c in {'A' .. 'Z', 'a' .. 'z'}: break strong
  let p = t.para
  var body = "<ParagraphStyleRange AppliedParagraphStyle=\"ParagraphStyle/$ID/NormalParagraphStyle\" Justification=\"" &
             alignOf(p.align, rtl) & "\" LeftIndent=\"" & f(p.indentLeft * k) & "\" RightIndent=\"" &
             f(p.indentRight * k) & "\" FirstLineIndent=\"" & f(p.indentFirst * k) & "\" SpaceBefore=\"" &
             f(p.spaceBefore * k) & "\" SpaceAfter=\"" & f(p.spaceAfter * k) & "\"" &
             (if rtl: " ParagraphDirection=\"RightToLeftDirection\" Composer=\"$ID/HL Composer Optyca\"" else: "") &
             (if p.dropLines >= 2: " DropCapLines=\"" & $p.dropLines & "\" DropCapCharacters=\"" &
                                   $max(1, p.dropChars) & "\"" else: "") & ">\n"
  for sp in t.spans:
    let st = sp.style
    let fam = if st.family.len > 0: st.family else: "FreeSans"
    let sty = if st.style.len > 0: st.style elif st.fauxBold: "Bold" else: "Regular"
    o.fontRef(fam, sty)
    body.add "<CharacterStyleRange AppliedCharacterStyle=\"CharacterStyle/$ID/[No character style]\" FontStyle=\"" &
             x(sty) & "\" PointSize=\"" & f(max(0.1, st.size * k)) & "\" FillColor=\"" & o.colorRef(st.color) & "\"" &
             (if st.tracking != 0: " Tracking=\"" & $st.tracking & "\"" else: "") &
             (if st.baselineShift != 0: " BaselineShift=\"" & f(st.baselineShift * k) & "\"" else: "") &
             (if st.underline: " Underline=\"true\"" else: "") & (if st.strike: " StrikeThru=\"true\"" else: "") &
             (if st.hScale > 0 and st.hScale != 1: " HorizontalScale=\"" & f(st.hScale * 100) & "\"" else: "") &
             (if st.vScale > 0 and st.vScale != 1: " VerticalScale=\"" & f(st.vScale * 100) & "\"" else: "") &
             (if st.allCaps: " Capitalization=\"AllCaps\"" elif st.smallCaps: " Capitalization=\"SmallCaps\"" else: "") &
             ">\n<Properties><AppliedFont type=\"string\">" & x(fam) & "</AppliedFont>" &
             (if st.leading > 0: "<Leading type=\"unit\">" & f(st.leading * k) & "</Leading>" else: "") &
             "</Properties>\n"
    # its text: paragraphs apart (<Br/>), the page number the program's own on a master
    var piece = ""
    proc flush(body: var string; piece: var string) =
      if piece.len > 0:
        body.add "<Content>" & x(piece) & "</Content>\n"
        piece = ""
    var i = 0
    let s = sp.text
    while i < s.len:
      if s[i] == '\n':
        flush(body, piece)
        body.add "<Br/>\n"
        inc i
      elif master and s.continuesWith("<##>", i):
        flush(body, piece)
        body.add "<Content><?ACE 18?></Content>\n"
        i += 4
      elif master and s.continuesWith("<#>", i):
        flush(body, piece)
        body.add "<Content><?ACE 18?></Content>\n"
        i += 3
      else:
        piece.add s[i]
        inc i
    flush(body, piece)
    body.add "</CharacterStyleRange>\n"
  body.add "</ParagraphStyleRange>\n"
  o.stories.add (id, "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" &
    "<idPkg:Story xmlns:idPkg=\"http://ns.adobe.com/AdobeInDesign/idml/1.0/packaging\" DOMVersion=\"8.0\">\n" &
    "<Story Self=\"" & id & "\" AppliedTOCStyle=\"n\" TrackChanges=\"false\" StoryTitle=\"$ID/\" " &
    "AppliedNamedGrid=\"n\">\n<StoryPreference OpticalMarginAlignment=\"false\" OpticalMarginSize=\"12\" " &
    "FrameType=\"TextFrameType\" StoryOrientation=\"Horizontal\" StoryDirection=\"" &
    (if rtl: "RightToLeftDirection" else: "LeftToRightDirection") & "\"/>\n" & body & "</Story>\n</idPkg:Story>\n")
  id

proc geometry(pts: seq[tuple[a, l, r: (float, float)]]; closed = true): string =
  result = "<Properties><PathGeometry><GeometryPathType PathOpen=\"" & (if closed: "false" else: "true") &
           "\"><PathPointArray>\n"
  for p in pts:
    result.add "<PathPointType Anchor=\"" & f(p.a[0]) & " " & f(p.a[1]) & "\" LeftDirection=\"" & f(p.l[0]) & " " &
               f(p.l[1]) & "\" RightDirection=\"" & f(p.r[0]) & " " & f(p.r[1]) & "\"/>\n"
  result.add "</PathPointArray></GeometryPathType></PathGeometry></Properties>\n"

proc boxGeometry(x0, y0, x1, y1: float): string =
  geometry(@[((x0, y0), (x0, y0), (x0, y0)), ((x0, y1), (x0, y1), (x0, y1)), ((x1, y1), (x1, y1), (x1, y1)),
             ((x1, y0), (x1, y0), (x1, y0))])

proc itemsOf(o: var IdmlOut; d: Doc; ox, oy, k: float; master: bool; name: string): string =
  ## (a page's layers as the spread's items: from `ox`, `oy` points, `k` points a pixel)
  template P(px, py: float): (float, float) = (ox + px * k, oy + py * k)
  for n, L in d.layers:
    if not L.visible or L.group or L.adjust.kind.len > 0: continue
    if not master and (L.fromMaster != 0 or L.fromSpan != 0): continue
    let plain = L.mode == bmNormal and not L.hasStyle and not L.clipped and (L.mask == nil or L.maskOff)
    let op = if L.opacity < 100: "<TransparencySetting><BlendingSetting Opacity=\"" & $L.opacity &
                                 "\"/></TransparencySetting>\n" else: ""
    if L.isText and plain:
      let t = if master: L.text else: d.effectiveText(L)    # (a master's page number as its mark)
      let lay = layoutText(t)
      var (x0, y0, x1, y1) = (t.x.float, t.y.float, float(t.x + t.boxW), float(t.y + t.boxH))
      if t.boxW <= 0 or t.boxH <= 0:
        # (point text: a frame round where its letters are)
        x0 = lay.x0.float - 2
        y0 = lay.y0.float - 2
        x1 = lay.x1.float + 6
        y1 = lay.y1.float + 4
      var tt = t
      if tt.table.on:
        tt.table = TableStyle()          # (a table as text: tabs between its cells)
      let sid = o.storyOf(tt, k, master)
      let (a, b) = (P(x0, y0), P(x1, y1))
      result.add "<TextFrame Self=\"" & o.uid("t") & "\" ParentStory=\"" & sid & "\" PreviousTextFrame=\"n\" " &
                 "NextTextFrame=\"n\" ContentType=\"TextType\" Name=\"" & x(L.name) & "\" ItemTransform=\"1 0 0 1 0 0\">\n" &
                 boxGeometry(a[0], a[1], b[0], b[1]) & op &
                 "<TextFramePreference TextColumnCount=\"" & $max(1, t.columns) & "\" TextColumnGutter=\"" &
                 f((if t.gutter > 0: t.gutter else: 12'f32) * k) & "\" VerticalJustification=\"TopAlign\"/>\n" &
                 "</TextFrame>\n"
    elif L.isShape and plain and L.shape.fill.kind in {spNone, spColor, spGradient}:
      let s = L.shape
      var geo = ""
      var subs = 0
      for sp in s.path.subs:
        if sp.pts.len < 2: continue
        inc subs
        var pts: seq[tuple[a, l, r: (float, float)]]
        for q in sp.pts: pts.add (P(q.p[0], q.p[1]), P(q.inH[0], q.inH[1]), P(q.outH[0], q.outH[1]))
        geo.add (if subs == 1: "" else: "") & "<GeometryPathType PathOpen=\"" & (if sp.closed: "false" else: "true") &
                "\"><PathPointArray>\n"
        for p in pts:
          geo.add "<PathPointType Anchor=\"" & f(p.a[0]) & " " & f(p.a[1]) & "\" LeftDirection=\"" & f(p.l[0]) & " " &
                  f(p.l[1]) & "\" RightDirection=\"" & f(p.r[0]) & " " & f(p.r[1]) & "\"/>\n"
        geo.add "</PathPointArray></GeometryPathType>\n"
      if subs == 0: continue
      let fill = if s.fill.kind == spColor: o.colorRef(s.fill.color)
                 elif s.fill.kind == spGradient: o.colorRef(s.fill.color) else: "Swatch/None"
      let stroke = if s.stroke.kind == spColor and s.strokeWidth > 0: o.colorRef(s.stroke.color) else: "Swatch/None"
      let tag = if s.kind == "Ellipse": "Oval" elif s.kind == "Rectangle": "Rectangle" else: "Polygon"
      result.add "<" & tag & " Self=\"" & o.uid("p") & "\" ContentType=\"Unassigned\" Name=\"" & x(L.name) &
                 "\" FillColor=\"" & fill & "\" StrokeColor=\"" & stroke & "\" StrokeWeight=\"" &
                 f(s.strokeWidth * k) & "\" ItemTransform=\"1 0 0 1 0 0\">\n" &
                 "<Properties><PathGeometry>" & geo & "</PathGeometry></Properties>\n" & op & "</" & tag & ">\n"
    else:
      # (anything else -- pixels, a Smart Object, what has a style or a mode -- as a picture of it)
      let box = d.layerBox(L).intersect(d.bounds)
      if box.w <= 0 or box.h <= 0: continue
      var pic = newBitmap(box.w, box.h)
      var op = op
      if plain and L.px.len == d.w * d.h:
        # (its own pixels, as they are: its opacity the frame's)
        for y in 0 ..< box.h:
          copyMem(addr pic.px[y * box.w], addr L.px[(box.y + y) * d.w + box.x], box.w * 4)
        # (one color all over -- a page's paper, a flat band: a frame filled with it, no picture)
        let c0 = pic.px[0]
        var flat = (c0 shr 24) == 255
        if flat:
          for c in pic.px:
            if c != c0:
              flat = false
              break
        if flat:
          if L.background and (c0 and 0xFFFFFF'u32) == 0xFFFFFF'u32: continue    # (white paper: the page's own)
          let (a, b) = (P(box.x.float, box.y.float), P(float(box.x + box.w), float(box.y + box.h)))
          result.add "<Rectangle Self=\"" & o.uid("r") & "\" ContentType=\"Unassigned\" Name=\"" & x(L.name) &
                     "\" FillColor=\"" & o.colorRef(c0) & "\" StrokeColor=\"Swatch/None\" ItemTransform=\"1 0 0 1 0 0\">\n" &
                     boxGeometry(a[0], a[1], b[0], b[1]) & op & "</Rectangle>\n"
          continue
      else:
        # (with its mode, style, mask or clipping: how it looks, alone -- its opacity in it)
        op = ""
        var shown: seq[bool]
        for M in d.layers: shown.add M.visible
        for j, M in d.layers: M.visible = j == n or (M.group and j > n)
        try:
          d.markAll()
          let full = d.toBitmap(0'u32)
          for y in 0 ..< box.h:
            copyMem(addr pic.px[y * box.w], addr full.px[(box.y + y) * d.w + box.x], box.w * 4)
        finally:
          for j, M in d.layers: M.visible = shown[j]
          d.markAll()
      let file = name & "-" & $o.links.len & ".png"
      o.links.add (file, encodePng(pic, dpi = int(d.dpi + 0.5)))
      let (a, b) = (P(box.x.float, box.y.float), P(float(box.x + box.w), float(box.y + box.h)))
      let sx = (b[0] - a[0]) / box.w.float
      let sy = (b[1] - a[1]) / box.h.float
      let uri = "file:" & (o.linksDir / file).replace('\\', '/')
      result.add "<Rectangle Self=\"" & o.uid("r") & "\" ContentType=\"GraphicType\" Name=\"" & x(L.name) &
                 "\" FillColor=\"Swatch/None\" StrokeColor=\"Swatch/None\" ItemTransform=\"1 0 0 1 0 0\">\n" &
                 boxGeometry(a[0], a[1], b[0], b[1]) & op &
                 "<Image Self=\"" & o.uid("i") & "\" ItemTransform=\"" & f(sx) & " 0 0 " & f(sy) & " " & f(a[0]) & " " &
                 f(a[1]) & "\">\n<Properties><Profile type=\"string\">$ID/None</Profile><GraphicBounds Left=\"0\" " &
                 "Top=\"0\" Right=\"" & $box.w & "\" Bottom=\"" & $box.h & "\"/></Properties>\n" &
                 "<Link Self=\"" & o.uid("l") & "\" LinkResourceURI=\"" & x(uri) & "\" StoredState=\"Normal\"/>\n" &
                 "</Image>\n</Rectangle>\n"

proc resources(o: var IdmlOut; pageW, pageH: float; pages: int; facing, rtl: bool; margins: array[4, float];
               cols: int; gutter: float): seq[(string, string)] =
  const head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
  const ns = "xmlns:idPkg=\"http://ns.adobe.com/AdobeInDesign/idml/1.0/packaging\" DOMVersion=\"8.0\""
  var g = head & "<idPkg:Graphic " & ns & ">\n" &
    "<Color Self=\"Color/Black\" Model=\"Process\" Space=\"CMYK\" ColorValue=\"0 0 0 100\" ColorOverride=\"Specialblack\" " &
    "AlternateSpace=\"NoAlternateColor\" AlternateColorValue=\"\" Name=\"Black\" ColorEditable=\"false\" " &
    "ColorRemovable=\"false\" Visible=\"true\" SwatchCreatorID=\"7937\"/>\n" &
    "<Color Self=\"Color/Paper\" Model=\"Process\" Space=\"CMYK\" ColorValue=\"0 0 0 0\" ColorOverride=\"Specialpaper\" " &
    "AlternateSpace=\"NoAlternateColor\" AlternateColorValue=\"\" Name=\"Paper\" ColorEditable=\"true\" " &
    "ColorRemovable=\"false\" Visible=\"true\" SwatchCreatorID=\"7937\"/>\n" &
    "<Color Self=\"Color/Registration\" Model=\"Registration\" Space=\"CMYK\" ColorValue=\"100 100 100 100\" " &
    "ColorOverride=\"Specialregistration\" AlternateSpace=\"NoAlternateColor\" AlternateColorValue=\"\" " &
    "Name=\"Registration\" ColorEditable=\"false\" ColorRemovable=\"false\" Visible=\"true\" SwatchCreatorID=\"7937\"/>\n"
  for rgb, self in o.colors:
    g.add "<Color Self=\"" & self & "\" Model=\"Process\" Space=\"RGB\" ColorValue=\"" & $((rgb shr 16) and 255) & " " &
          $((rgb shr 8) and 255) & " " & $(rgb and 255) & "\" ColorOverride=\"Normal\" AlternateSpace=\"NoAlternateColor\" " &
          "AlternateColorValue=\"\" Name=\"" & self[6 .. ^1] & "\" ColorEditable=\"true\" ColorRemovable=\"true\" " &
          "Visible=\"true\" SwatchCreatorID=\"7937\"/>\n"
  g.add "<Swatch Self=\"Swatch/None\" Name=\"None\" ColorEditable=\"false\" ColorRemovable=\"false\" Visible=\"true\" " &
        "SwatchCreatorID=\"7937\"/>\n" &
        "<StrokeStyle Self=\"StrokeStyle/$ID/Solid\" Name=\"$ID/Solid\"/>\n</idPkg:Graphic>\n"
  var fo = head & "<idPkg:Fonts " & ns & ">\n"
  for fam, styles in o.fonts:
    fo.add "<FontFamily Self=\"di" & toHex(hash(fam).int and 0xFFFFFF, 6).toLowerAscii & "\" Name=\"" & x(fam) & "\">\n"
    for st in styles:
      fo.add "<Font Self=\"di" & toHex(hash(fam & st).int and 0xFFFFFF, 6).toLowerAscii & "\" FontFamily=\"" & x(fam) &
             "\" Name=\"" & x(fam & " " & st) & "\" PostScriptName=\"" & x(fam.replace(" ", "") & "-" &
             st.replace(" ", "")) & "\" Status=\"Installed\" FontStyleName=\"" & x(st) & "\" FontType=\"OpenTypeTT\" " &
             "WritingScript=\"0\" FullName=\"" & x(fam & " " & st) & "\" FullNameNative=\"" & x(fam & " " & st) &
             "\" FontStyleNameNative=\"" & x(st) & "\" PlatformName=\"$ID/\" Version=\"1.0\"/>\n"
    fo.add "</FontFamily>\n"
  fo.add "</idPkg:Fonts>\n"
  let st = head & "<idPkg:Styles " & ns & ">\n" &
    "<RootCharacterStyleGroup Self=\"u79\">\n<CharacterStyle Self=\"CharacterStyle/$ID/[No character style]\" " &
    "Imported=\"false\" Name=\"$ID/[No character style]\"/>\n</RootCharacterStyleGroup>\n" &
    "<RootParagraphStyleGroup Self=\"u78\">\n<ParagraphStyle Self=\"ParagraphStyle/$ID/[No paragraph style]\" " &
    "Name=\"$ID/[No paragraph style]\" Imported=\"false\" PointSize=\"12\"/>\n" &
    "<ParagraphStyle Self=\"ParagraphStyle/$ID/NormalParagraphStyle\" Name=\"$ID/NormalParagraphStyle\" " &
    "Imported=\"false\" NextStyle=\"ParagraphStyle/$ID/NormalParagraphStyle\">\n<Properties>" &
    "<BasedOn type=\"object\">ParagraphStyle/$ID/[No paragraph style]</BasedOn></Properties>\n</ParagraphStyle>\n" &
    "</RootParagraphStyleGroup>\n<RootCellStyleGroup Self=\"u8e\">\n<CellStyle Self=\"CellStyle/$ID/[None]\" " &
    "Name=\"$ID/[None]\"/>\n</RootCellStyleGroup>\n<RootTableStyleGroup Self=\"u90\">\n" &
    "<TableStyle Self=\"TableStyle/$ID/[No table style]\" Name=\"$ID/[No table style]\"/>\n" &
    "<TableStyle Self=\"TableStyle/$ID/[Basic Table]\" Name=\"$ID/[Basic Table]\"/>\n</RootTableStyleGroup>\n" &
    "<RootObjectStyleGroup Self=\"u98\">\n<ObjectStyle Self=\"ObjectStyle/$ID/[None]\" Name=\"$ID/[None]\"/>\n" &
    "<ObjectStyle Self=\"ObjectStyle/$ID/[Normal Graphics Frame]\" Name=\"$ID/[Normal Graphics Frame]\"/>\n" &
    "<ObjectStyle Self=\"ObjectStyle/$ID/[Normal Text Frame]\" Name=\"$ID/[Normal Text Frame]\"/>\n" &
    "</RootObjectStyleGroup>\n</idPkg:Styles>\n"
  let pr = head & "<idPkg:Preferences " & ns & ">\n" &
    "<DocumentPreference PageHeight=\"" & f(pageH) & "\" PageWidth=\"" & f(pageW) & "\" PagesPerDocument=\"" & $pages &
    "\" FacingPages=\"" & $facing & "\" DocumentBleedTopOffset=\"0\" DocumentBleedBottomOffset=\"0\" " &
    "DocumentBleedInsideOrLeftOffset=\"0\" DocumentBleedOutsideOrRightOffset=\"0\" PageBinding=\"" &
    (if rtl: "RightToLeft" else: "LeftToRight") & "\" ColumnDirection=\"Horizontal\" Intent=\"PrintIntent\"/>\n" &
    "<MarginPreference ColumnCount=\"" & $max(1, cols) & "\" ColumnGutter=\"" & f(gutter) & "\" Top=\"" & f(margins[0]) &
    "\" Bottom=\"" & f(margins[1]) & "\" Left=\"" & f(margins[2]) & "\" Right=\"" & f(margins[3]) &
    "\" ColumnDirection=\"Horizontal\" ColumnsPositions=\"0 " & f(pageW - margins[2] - margins[3]) & "\"/>\n" &
    "<ViewPreference HorizontalMeasurementUnits=\"Millimeters\" VerticalMeasurementUnits=\"Millimeters\"/>\n" &
    "</idPkg:Preferences>\n"
  @[("Resources/Graphic.xml", g), ("Resources/Fonts.xml", fo), ("Resources/Styles.xml", st),
    ("Resources/Preferences.xml", pr)]

proc package(o: var IdmlOut; spreads, masters: seq[(string, string)]; res: seq[(string, string)];
             pages: int; firstPage: string): string =
  const head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
  const ns = "xmlns:idPkg=\"http://ns.adobe.com/AdobeInDesign/idml/1.0/packaging\" DOMVersion=\"8.0\""
  var storyList = ""
  for (id, _) in o.stories: storyList.add (if storyList.len > 0: " " else: "") & id
  var dm = head & "<?aid style=\"50\" type=\"document\" readerVersion=\"6.0\" featureSet=\"257\" product=\"8.0(370)\" ?>\n" &
           "<Document " & ns & " Self=\"d\" StoryList=\"" & storyList & "\" ZeroPoint=\"0 0\" ActiveLayer=\"ub\" " &
           "CMYKProfile=\"Coated FOGRA39 (ISO 12647-2:2004)\" RGBProfile=\"sRGB IEC61966-2.1\" " &
           "SolidColorIntent=\"UseColorSettings\" AfterBlendingIntent=\"UseColorSettings\" " &
           "DefaultImageIntent=\"UseColorSettings\" RGBPolicy=\"PreserveEmbeddedProfiles\" " &
           "CMYKPolicy=\"CombinationOfPreserveAndSafeCmyk\" AccurateLABSpots=\"false\">\n"
  for (path, _) in res:
    let tag = path.splitFile.name
    dm.add "<idPkg:" & tag & " src=\"" & path & "\"/>\n"
  dm.add "<Layer Self=\"ub\" Name=\"Layer 1\" Visible=\"true\" Locked=\"false\" IgnoreWrap=\"false\" ShowGuides=\"true\" " &
         "LockGuides=\"false\" UI=\"true\" Expendable=\"true\" Printable=\"true\"><Properties><LayerColor type=\"enumeration\">" &
         "LightBlue</LayerColor></Properties></Layer>\n"
  for (path, _) in masters: dm.add "<idPkg:MasterSpread src=\"" & path & "\"/>\n"
  for (path, _) in spreads: dm.add "<idPkg:Spread src=\"" & path & "\"/>\n"
  dm.add "<Section Self=\"usec\" Length=\"" & $pages & "\" Name=\"\" ContinueNumbering=\"true\" IncludeSectionPrefix=\"false\" " &
         "PageNumberStyle=\"Arabic\" PageStart=\"" & firstPage & "\" SectionPrefix=\"\"/>\n" &
         "<idPkg:BackingStory src=\"XML/BackingStory.xml\"/>\n"
  for (id, _) in o.stories: dm.add "<idPkg:Story src=\"Stories/Story_" & id & ".xml\"/>\n"
  dm.add "</Document>\n"
  var z = newZipWriter()
  z.addFile("mimetype", "application/vnd.adobe.indesign-idml-package", compress = false)
  z.addFile("designmap.xml", dm)
  z.addFile("META-INF/container.xml", head & "<container version=\"1.0\" " &
            "xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\">\n<rootfiles>\n" &
            "<rootfile full-path=\"designmap.xml\" media-type=\"text/xml\"/>\n</rootfiles>\n</container>\n")
  for (path, data) in res: z.addFile(path, data)
  for (path, data) in masters: z.addFile(path, data)
  for (path, data) in spreads: z.addFile(path, data)
  for (id, data) in o.stories: z.addFile("Stories/Story_" & id & ".xml", data)
  z.addFile("XML/BackingStory.xml", head & "<idPkg:BackingStory " & ns & ">\n<XmlStory Self=\"ui\" " &
            "AppliedTOCStyle=\"n\" TrackChanges=\"false\" StoryTitle=\"$ID/\" AppliedNamedGrid=\"n\">\n" &
            "<ParagraphStyleRange AppliedParagraphStyle=\"ParagraphStyle/$ID/NormalParagraphStyle\">\n" &
            "<CharacterStyleRange AppliedCharacterStyle=\"CharacterStyle/$ID/[No character style]\"/>\n" &
            "</ParagraphStyleRange>\n</XmlStory>\n</idPkg:BackingStory>\n")
  z.addFile("XML/Tags.xml", head & "<idPkg:Tags " & ns & ">\n<XMLTag Self=\"XMLTag/Root\" Name=\"Root\">\n" &
            "<Properties><TagColor type=\"enumeration\">LightBlue</TagColor></Properties>\n</XMLTag>\n</idPkg:Tags>\n")
  z.finish()

proc spreadXml(self, items, pagesXml: string; pageCount: int; master: bool; name = "A"): string =
  const head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
  const ns = "xmlns:idPkg=\"http://ns.adobe.com/AdobeInDesign/idml/1.0/packaging\" DOMVersion=\"8.0\""
  if master:
    head & "<idPkg:MasterSpread " & ns & ">\n<MasterSpread Self=\"" & self & "\" ItemTransform=\"1 0 0 1 0 0\" " &
      "Name=\"" & x(name) & "-Master\" NamePrefix=\"" & x(name) & "\" BaseName=\"Master\" ShowMasterItems=\"true\" " &
      "PageCount=\"" & $pageCount & "\" OverriddenPageItemProps=\"\">\n" & pagesXml & items &
      "</MasterSpread>\n</idPkg:MasterSpread>\n"
  else:
    head & "<idPkg:Spread " & ns & ">\n<Spread Self=\"" & self & "\" PageTransitionType=\"None\" " &
      "PageTransitionDirection=\"NotApplicable\" PageTransitionDuration=\"Medium\" ShowMasterItems=\"true\" " &
      "PageCount=\"" & $pageCount & "\" BindingLocation=\"" & $(if pageCount > 1: 1 else: 0) & "\" " &
      "AllowPageShuffle=\"true\" ItemTransform=\"1 0 0 1 0 0\" FlattenerOverride=\"Default\">\n" & pagesXml & items &
      "</Spread>\n</idPkg:Spread>\n"

proc pageXml(self, name, master: string; w, h, tx, ty: float; margins: array[4, float]; cols: int;
             gutter: float): string =
  "<Page Self=\"" & self & "\" AppliedTrapPreset=\"TrapPreset/$ID/kDefaultTrapStyleName\" Name=\"" & x(name) &
    "\" AppliedMaster=\"" & master & "\" OverrideList=\"\" TabOrder=\"\" GridStartingPoint=\"TopOutside\" " &
    "UseMasterGrid=\"true\" GeometricBounds=\"0 0 " & f(h) & " " & f(w) & "\" ItemTransform=\"1 0 0 1 " & f(tx) & " " &
    f(ty) & "\" MasterPageTransform=\"1 0 0 1 0 0\">\n<MarginPreference ColumnCount=\"" & $max(1, cols) &
    "\" ColumnGutter=\"" & f(gutter) & "\" Top=\"" & f(margins[0]) & "\" Bottom=\"" & f(margins[1]) & "\" Left=\"" &
    f(margins[2]) & "\" Right=\"" & f(margins[3]) & "\" ColumnDirection=\"Horizontal\" ColumnsPositions=\"0 " &
    f(w - margins[2] - margins[3]) & "\"/>\n</Page>\n"

proc saveBookIdml*(b: Book; path: string; keep: openArray[int] = []) =
  ## The book as IDML at `path`, its pictures as PNG files in a folder
  ## beside it ("name-links"). The pages opened for it are parked again,
  ## but for those at `keep`. Raises `IOError` when it cannot be written.
  b.reflow(keep)
  var o = IdmlOut(linksDir: path.changeFileExt("").absolutePath & "-links")
  let s = b.setup
  let k = 72 / max(1.0, s.dpi)
  let pw = s.w.float * k
  let ph = s.h.float * k
  let rtl = s.binding == bindRight
  let mL = b.marginBox(psLeft)
  let mR = b.marginBox(psRight)
  proc marginsOf(m: Rect): array[4, float] =
    [m.y.float * k, float(s.h - m.y - m.h) * k, m.x.float * k, float(s.w - m.x - m.w) * k]
  let gut = s.gutter.float * k
  # masters
  var masters: seq[(string, string)]
  var masterSelf = initTable[int, string]()
  for m in b.masters:
    let self = o.uid("m")
    masterSelf[m.id] = self
    var items, pagesXml = ""
    let sides = if s.facing: @[psLeft, psRight] else: @[psSingle]
    for j, side in sides:
      let tx = if s.facing: (if j == 0: -pw else: 0.0) else: 0.0
      let ty = -ph / 2
      let md = b.masterDoc(m, side)
      pagesXml.add pageXml(o.uid("mp"), m.name, "n", pw, ph, tx, ty, marginsOf(if side == psLeft: mL else: mR),
                           s.columns, gut)
      items.add o.itemsOf(md, tx, ty, k, master = true, name = path.splitFile.name & "-master-" & m.name)
    masters.add ("MasterSpreads/MasterSpread_" & self & ".xml",
                 spreadXml(self, items, pagesXml, sides.len, master = true, name = m.name))
  # the pages, spread by spread
  var spreads: seq[(string, string)]
  var firstPage = ""
  var done = newSeq[bool](b.pages.len)
  for i in 0 ..< b.pages.len:
    if done[i]: continue
    let sheet = b.spreadOf(i)
    var items, pagesXml = ""
    let self = o.uid("sp")
    for j, pi in sheet:
      done[pi] = true
      let was = b.isOpen(pi)
      let d = b.doc(pi)
      let side = b.sideOf(pi)
      let tx = if sheet.len == 2: (if j == 0: -pw else: 0.0) elif side == psLeft: -pw else: 0.0
      let ty = -ph / 2
      let pself = o.uid("pg")
      if firstPage.len == 0: firstPage = pself
      let ms = if b.pages[pi].master != 0 and b.pages[pi].master in masterSelf: masterSelf[b.pages[pi].master] else: "n"
      pagesXml.add pageXml(pself, b.label(pi), ms, pw, ph, tx, ty, marginsOf(if side == psLeft: mL else: mR),
                           s.columns, gut)
      items.add o.itemsOf(d, tx, ty, k, master = false, name = path.splitFile.name & "-p" & $(pi + 1))
      if not was and pi notin keep: b.park(keep)
    spreads.add ("Spreads/Spread_" & self & ".xml", spreadXml(self, items, pagesXml, sheet.len, master = false))
  let res = o.resources(pw, ph, b.pages.len, s.facing, rtl, marginsOf(mR), s.columns, gut)
  let data = o.package(spreads, masters, res, b.pages.len, firstPage)
  if o.links.len > 0:
    createDir(o.linksDir)
    for (file, png) in o.links: writeFile(o.linksDir / file, png)
  writeFile(path, data)

proc saveDocIdml*(d: Doc; path: string) =
  ## One document as a one-page IDML, its pictures as PNG files beside it.
  var o = IdmlOut(linksDir: path.changeFileExt("").absolutePath & "-links")
  let k = 72 / max(1.0, d.dpi)
  let pw = d.w.float * k
  let ph = d.h.float * k
  let first = o.uid("pg")
  let self = o.uid("sp")
  let items = o.itemsOf(d, 0, -ph / 2, k, master = false, name = path.splitFile.name)
  let spread = spreadXml(self, items, pageXml(first, "1", "n", pw, ph, 0, -ph / 2, [0.0, 0, 0, 0], 1, 12), 1,
                         master = false)
  let res = o.resources(pw, ph, 1, false, false, [0.0, 0, 0, 0], 1, 12)
  let data = o.package(@[("Spreads/Spread_" & self & ".xml", spread)], @[], res, 1, first)
  if o.links.len > 0:
    createDir(o.linksDir)
    for (file, png) in o.links: writeFile(o.linksDir / file, png)
  writeFile(path, data)

# ---- reading IDML -------------------------------------------------------------------------------------------

import std/[xmlparser, xmltree, strtabs]

type IdmlError* = object of IOError
  ## `readIdml`: not an IDML package, or one damaged past reading

proc nums(s: string): seq[float] =
  for w in s.splitWhitespace:
    try: result.add parseFloat(w) except ValueError: result.add 0

proc applyT(m: seq[float]; p: (float, float)): (float, float) =
  if m.len < 6: return p
  (m[0] * p[0] + m[2] * p[1] + m[4], m[1] * p[0] + m[3] * p[1] + m[5])

proc mul(a, b: seq[float]): seq[float] =
  ## (`a` then `b`, as IDML's ItemTransforms nest)
  if a.len < 6: return b
  if b.len < 6: return a
  @[a[0] * b[0] + a[1] * b[2], a[0] * b[1] + a[1] * b[3], a[2] * b[0] + a[3] * b[2], a[2] * b[1] + a[3] * b[3],
    a[4] * b[0] + a[5] * b[2] + b[4], a[4] * b[1] + a[5] * b[3] + b[5]]

proc childrenNamed(n: XmlNode; tag: string): seq[XmlNode] =
  if n == nil or n.kind != xnElement: return
  for c in n:
    if c.kind == xnElement and c.tag == tag: result.add c

proc findAll(n: XmlNode; tag: string; into: var seq[XmlNode]) =
  if n == nil or n.kind != xnElement: return
  for c in n:
    if c.kind == xnElement:
      if c.tag == tag: into.add c
      findAll(c, tag, into)

proc attr(n: XmlNode; k: string): string =
  if n == nil or n.kind != xnElement or n.attrs == nil: "" else: n.attrs.getOrDefault(k)

proc pathOf(n: XmlNode; m: seq[float]): seq[seq[tuple[a, l, r: (float, float)]]] =
  ## (an item's outlines, in the spread's points)
  var gps: seq[XmlNode]
  findAll(n, "GeometryPathType", gps)
  for g in gps:
    var sub: seq[tuple[a, l, r: (float, float)]]
    var pps: seq[XmlNode]
    findAll(g, "PathPointType", pps)
    for p in pps:
      let a = nums(p.attr("Anchor"))
      let l = nums(p.attr("LeftDirection"))
      let r = nums(p.attr("RightDirection"))
      if a.len < 2: continue
      let la = if l.len >= 2: (l[0], l[1]) else: (a[0], a[1])
      let ra = if r.len >= 2: (r[0], r[1]) else: (a[0], a[1])
      sub.add (applyT(m, (a[0], a[1])), applyT(m, la), applyT(m, ra))
    if sub.len > 0: result.add sub

proc readIdml*(file: string; dpi = 150.0): Book =
  ## An IDML package as a book: its pages (spreads, facing or not, bound
  ## either way), each text frame a text box with its story's runs (fonts,
  ## sizes, colors, paragraphs), each rectangle, oval and polygon a shape
  ## with its fill and stroke, each linked picture found where its link
  ## says (or beside the package) a layer of its own. Master pages, tables
  ## and effects are not read. Raises `IdmlError`.
  var entries: seq[ZipEntry]
  try: entries = zipEntries(file)
  except CatchableError: raise newException(IdmlError, "not an IDML package")
  var files = initTable[string, ZipEntry]()
  for e in entries: files[e.name] = e
  proc get(name: string): XmlNode =
    if name notin files: return nil
    try: parseXml(readEntry(file, files[name]))
    except CatchableError: nil
  let dm = get("designmap.xml")
  if dm == nil: raise newException(IdmlError, "not an IDML package (no designmap.xml)")
  # colors
  var colors = initTable[string, uint32]()
  colors["Color/Black"] = 0xFF000000'u32
  colors["Color/Paper"] = 0xFFFFFFFF'u32
  let gr = get("Resources/Graphic.xml")
  var cs: seq[XmlNode]
  findAll(gr, "Color", cs)
  for c in cs:
    let v = nums(c.attr("ColorValue"))
    let sp = c.attr("Space")
    var argb = 0xFF000000'u32
    if sp == "RGB" and v.len >= 3:
      argb = 0xFF000000'u32 or (uint32(clamp(v[0], 0, 255)) shl 16) or (uint32(clamp(v[1], 0, 255)) shl 8) or
             uint32(clamp(v[2], 0, 255))
    elif sp == "CMYK" and v.len >= 4:
      let (cc, mm, yy, kk) = (v[0] / 100, v[1] / 100, v[2] / 100, v[3] / 100)
      argb = 0xFF000000'u32 or (uint32(255 * (1 - cc) * (1 - kk)) shl 16) or (uint32(255 * (1 - mm) * (1 - kk)) shl 8) or
             uint32(255 * (1 - yy) * (1 - kk))
    elif sp == "LAB" and v.len >= 1:
      let g = uint32(clamp(v[0] / 100 * 255, 0, 255))
      argb = 0xFF000000'u32 or (g shl 16) or (g shl 8) or g
    colors[c.attr("Self")] = argb
  proc colorOf(s: string; d = 0'u32): uint32 = colors.getOrDefault(s, d)
  # the page's size and binding
  let pr = get("Resources/Preferences.xml")
  var dps: seq[XmlNode]
  findAll(pr, "DocumentPreference", dps)
  var pw = 595.0
  var ph = 842.0
  var facing = true
  var rtl = false
  if dps.len > 0:
    try:
      pw = parseFloat(dps[0].attr("PageWidth"))
      ph = parseFloat(dps[0].attr("PageHeight"))
    except ValueError: discard
    facing = dps[0].attr("FacingPages") != "false"
    rtl = dps[0].attr("PageBinding") == "RightToLeft"
  let k = dpi / 72                       # (pixels a point)
  var s = bookSetup(pw * 25.4 / 72, ph * 25.4 / 72, dpi = dpi, facing = facing,
                    binding = (if rtl: bindRight else: bindLeft))
  # stories
  var stories = initTable[string, XmlNode]()
  for name in files.keys:
    if name.startsWith("Stories/") and name.endsWith(".xml"):
      let st = get(name)
      var ss: seq[XmlNode]
      findAll(st, "Story", ss)
      if st != nil and st.tag == "Story": ss.add st
      for x in ss: stories[x.attr("Self")] = x
  proc textOf(id: string; at: (float, float); w, h: float): TextData =
    result = TextData(x: float32(at[0]), y: float32(at[1]), boxW: float32(w), boxH: float32(h), antialias: true)
    if id notin stories: return
    var psrs: seq[XmlNode]
    findAll(stories[id], "ParagraphStyleRange", psrs)
    for pi, psr in psrs:
      if pi == 0:
        case psr.attr("Justification")
        of "CenterAlign": result.para.align = textCenter
        of "RightAlign": result.para.align = textRight
        of "LeftJustified": result.para.align = justifyLeft
        of "RightJustified": result.para.align = justifyRight
        of "CenterJustified": result.para.align = justifyCenter
        of "FullyJustified": result.para.align = justifyAll
        else: discard
        if psr.attr("ParagraphDirection") == "RightToLeftDirection": result.para.rtl = 2
      elif result.spans.len > 0: result.spans[^1].text.add "\n"
      for csr in psr.childrenNamed("CharacterStyleRange"):
        var st = defaultStyle()
        try:
          if csr.attr("PointSize").len > 0: st.size = float32(parseFloat(csr.attr("PointSize")) * k)
        except ValueError: discard
        st.color = colorOf(csr.attr("FillColor"), 0xFF000000'u32)
        var fam = ""
        for pp in csr.childrenNamed("Properties"):
          for af in pp.childrenNamed("AppliedFont"): fam = af.innerText
          for ld in pp.childrenNamed("Leading"):
            try: st.leading = float32(parseFloat(ld.innerText) * k) except ValueError: discard
        if fam.len > 0 and fam in fontFamilies(): st.family = fam
        let fsn = csr.attr("FontStyle")
        if fsn.len > 0:
          if st.family.len > 0 and fsn in fontStyles(st.family): st.style = fsn
          elif "Bold" in fsn: st.fauxBold = true
        try:
          if csr.attr("Tracking").len > 0: st.tracking = parseInt(csr.attr("Tracking"))
        except ValueError: discard
        st.underline = csr.attr("Underline") == "true"
        st.strike = csr.attr("StrikeThru") == "true"
        var txt = ""
        for c in csr:
          if c.kind != xnElement: continue
          if c.tag == "Content": txt.add c.innerText
          elif c.tag == "Br": txt.add "\n"
        if txt.len > 0: result.spans.add TextSpan(text: txt, style: st)
  # spreads: their pages in order, each page's items
  var pagesOut: seq[tuple[items: seq[XmlNode]; m: seq[seq[float]]; page: seq[float]]]
  for sp in dm.childrenNamed("idPkg:Spread"):
    let sx = get(sp.attr("src"))
    var spreadNodes: seq[XmlNode]
    findAll(sx, "Spread", spreadNodes)
    if sx != nil and sx.tag == "Spread": spreadNodes.add sx
    for spread in spreadNodes:
      let smat = nums(spread.attr("ItemTransform"))
      let pages = spread.childrenNamed("Page")
      var pageMats: seq[seq[float]]
      for p in pages: pageMats.add mul(nums(p.attr("ItemTransform")), smat)
      var items: seq[seq[XmlNode]]
      for _ in pages: items.add @[]
      var mats: seq[seq[seq[float]]]
      for _ in pages: mats.add @[]
      for it in spread:
        if it.kind != xnElement or it.tag notin ["TextFrame", "Rectangle", "Oval", "Polygon", "GraphicLine", "Group"]:
          continue
        let m = mul(nums(it.attr("ItemTransform")), smat)
        # (the page the item's middle is over)
        let paths = pathOf(it, m)
        var cx, cy = 0.0
        var n = 0
        for sub in paths:
          for p in sub:
            cx += p.a[0]
            cy += p.a[1]
            inc n
        if n == 0: continue
        cx /= n.float
        cy /= n.float
        var best = 0
        for pi, pm in pageMats:
          if pm.len >= 6 and cx >= pm[4] and cx <= pm[4] + pw: best = pi
        if best < items.len:
          items[best].add it
          mats[best].add m
      for pi, p in pages:
        pagesOut.add (items[pi], mats[pi], pageMats[pi])
  if pagesOut.len == 0: raise newException(IdmlError, "the package has no pages")
  result = newBook(s, pages = pagesOut.len, name = file.splitFile.name)
  let b = result
  for i, pg in pagesOut:
    let d = b.doc(i)
    let ox = if pg.page.len >= 6: pg.page[4] else: 0.0
    let oy = if pg.page.len >= 6: pg.page[5] else: 0.0
    proc px(p: (float, float)): (float, float) = ((p[0] - ox) * k, (p[1] - oy) * k)
    for j, it in pg.items:
      let paths = pathOf(it, pg.m[j])
      var x0, y0 = Inf
      var x1, y1 = -Inf
      var path: Path
      for sub in paths:
        var spth = SubPath(closed: true)
        for p in sub:
          let a = px(p.a)
          x0 = min(x0, a[0]); y0 = min(y0, a[1]); x1 = max(x1, a[0]); y1 = max(y1, a[1])
          spth.pts.add PathPoint(p: a, inH: px(p.l), outH: px(p.r))
        path.subs.add spth
      if x1 <= x0 or y1 <= y0: continue
      case it.tag
      of "TextFrame":
        let t = textOf(it.attr("ParentStory"), (x0, y0), x1 - x0, y1 - y0)
        if t.spans.len > 0:
          let L = d.addTextLayer(t)
          if it.attr("Name").len > 0 and it.attr("Name") != "$ID/": L.name = it.attr("Name")
      else:
        # a picture in it: its link, where it says or beside the package
        var imgs: seq[XmlNode]
        findAll(it, "Image", imgs)
        findAll(it, "PDF", imgs)
        var placed = false
        for im in imgs:
          var links: seq[XmlNode]
          findAll(im, "Link", links)
          for l in links:
            var f = l.attr("LinkResourceURI")
            if f.startsWith("file:"): f = f[5 .. ^1]
            while f.startsWith("//"): f = f[1 .. ^1]
            f = f.replace("%20", " ")
            let near = file.parentDir / f.extractFilename
            let found = if fileExists(f): f elif fileExists(near): near else: ""
            if found.len == 0: continue
            try:
              let data = readFile(found)
              let pic = if data.startsWith("\x89PNG"): decodePng(data)
                        elif data.startsWith("\xFF\xD8"): decodeJpeg(data)
                        elif data.startsWith("BM"): decodeBmp(data)
                        else: nil
              if pic == nil or pic.w <= 0: continue
              let L = d.addLayer(found.splitFile.name)
              let bw = int(x1 - x0)
              let bh = int(y1 - y0)
              let kk = max(bw / pic.w, bh / pic.h)
              let w = int(pic.w.float * kk)
              let h = int(pic.h.float * kk)
              let sx0 = int(x0) + (bw - w) div 2
              let sy0 = int(y0) + (bh - h) div 2
              for yy in max(0, int(y0)) ..< min(d.h, int(y1)):
                for xx in max(0, int(x0)) ..< min(d.w, int(x1)):
                  let u = (xx - sx0) * pic.w div max(1, w)
                  let v = (yy - sy0) * pic.h div max(1, h)
                  if u >= 0 and v >= 0 and u < pic.w and v < pic.h: L.px[yy * d.w + xx] = pic.px[v * pic.w + u]
              inc L.ver
              placed = true
            except CatchableError: discard
        if not placed:
          let fill = it.attr("FillColor")
          let stroke = it.attr("StrokeColor")
          var sw = 0.0
          try:
            if it.attr("StrokeWeight").len > 0: sw = parseFloat(it.attr("StrokeWeight")) * k
          except ValueError: discard
          let hasFill = fill.len > 0 and fill != "Swatch/None"
          let hasStroke = stroke.len > 0 and stroke != "Swatch/None" and sw > 0
          if not hasFill and not hasStroke: continue
          var sd = ShapeData(path: path,
                             fill: (if hasFill: ShapePaint(kind: spColor, color: colorOf(fill, 0xFF000000'u32))
                                    else: ShapePaint()),
                             stroke: (if hasStroke: ShapePaint(kind: spColor, color: colorOf(stroke, 0xFF000000'u32))
                                      else: ShapePaint()),
                             strokeWidth: (if hasStroke: sw else: 0.0), align: saCenter,
                             kind: (if it.tag == "Oval": "Ellipse" elif it.tag == "Rectangle": "Rectangle" else: ""))
          if it.tag == "GraphicLine":
            for sub in sd.path.subs.mitems: sub.closed = false
          discard d.addShapeLayer(sd, if it.attr("Name").len > 0 and it.attr("Name") != "$ID/": it.attr("Name") else: "")
    d.markAll()
    b.park()
  b.modified = false
