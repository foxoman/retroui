# (included by photo.nim) File > Export > Export for Screens: the artboards, the objects picked
# (assets) or the whole document, each written at the scales checked -- with each scale's
# suffix -- and in the formats checked, in a folder of their own for each scale or format when
# asked. The engine is `retroui/screenexport`.

var
  scrDlg: tuple[open, pick: bool; what: int; dir, prefix: string; quality: int; perScale, perFormat: bool;
                scaleOn: array[6, bool]; suffix: array[6, string]; fmt: array[ScreenFormat, bool]] =
    (false, false, 0, "", "", 85, false, false, [false, true, false, true, true, false],
     ["@0.5x", "", "@1.5x", "@2x", "@3x", "@4x"], [true, false, false, false, false])

const scrScales = [0.5, 1.0, 1.5, 2.0, 3.0, 4.0]

proc startScreenExport() =
  let d = cur()
  if d == nil: return
  scrDlg.open = true
  scrDlg.what = if d.artboards.len > 0: 0 elif d.pickedLayers.len > 0 or not d.current.background: 1 else: 2
  if scrDlg.dir.len == 0:
    scrDlg.dir = (if d.path.len > 0: d.path.parentDir else: picturesDir()) / (d.name & " for screens")

proc runScreenExport(d: Doc) =
  var o = defaultScreenExport()
  o.scales.setLen(0)
  for k, on in scrDlg.scaleOn:
    if on: o.scales.add (scrScales[k], scrDlg.suffix[k])
  o.formats = {}
  for f in ScreenFormat:
    if scrDlg.fmt[f]: o.formats.incl f
  o.prefix = scrDlg.prefix
  o.folderPerScale = scrDlg.perScale
  o.folderPerFormat = scrDlg.perFormat
  o.quality = scrDlg.quality
  var idxs = d.pickedLayers
  if idxs.len == 0 and not d.current.background: idxs = @[d.cur]
  let items = case scrDlg.what
              of 0: d.artboardItems()
              of 1: d.assetItems(idxs)
              else: @[d.documentItem]
  if items.len == 0:
    status = "Export for Screens: nothing to export -- no artboards, or nothing picked"
    return
  if o.formats.len == 0 or (o.scales.len == 0 and o.formats * {sfSvg, sfPdf} == {}):
    status = "Export for Screens: check a scale and a format"
    return
  try:
    beginBusy("Export for Screens")
    var files: seq[string]
    try: files = d.exportForScreens(items, o, scrDlg.dir)
    finally: endBusy()
    status = tr("Export for Screens: ") & $files.len & tr(" files in ") & scrDlg.dir
  except CatchableError: status = tr("Export for Screens: ") & getCurrentExceptionMsg()

proc screenExportDialog() =
  if scrDlg.open:
    let d = cur()
    if d == nil:
      scrDlg.open = false
      return
    var go = false
    dialog(scrDlg.open, "Export for Screens", 480):
      group("Export"):
        row:
          radio("Artboards", scrDlg.what, 0, enabled = d.artboards.len > 0)
          radio("Objects Picked", scrDlg.what, 1)
          radio("Whole Document", scrDlg.what, 2)
      group("Scales"):
        for k in 0 ..< scrScales.len:
          row([90, 50, -1]):
            discard checkbox(($scrScales[k]).replace(".0", "") & "x", scrDlg.scaleOn[k])
            label "Suffix:"
            edit(scrDlg.suffix[k], w = dp(110))
      group("Formats"):
        row:
          for f in ScreenFormat: discard checkbox($f, scrDlg.fmt[f])
        if scrDlg.fmt[sfJpeg] or scrDlg.fmt[sfWebp]:
          row:
            label "Quality:"
            spin(scrDlg.quality, 1, 100, w = dp(60))
        label("SVG and PDF are written once each, as vectors.", color = ui.theme.gray)
      group("Files"):
        row([-1, 90]):
          label(ellipsize(scrDlg.dir, available()))
          if button("Choose...", w = dp(86)):
            proc pickDir() = scrDlg.pick = true
            if storageFor(pickDir): pickDir()
        row:
          label "Prefix:"
          edit(scrDlg.prefix, w = dp(160))
        checkbox("A folder for each scale (1x, 2x...)", scrDlg.perScale)
        checkbox("A folder for each format (png, svg...)", scrDlg.perFormat)
      row:
        spring()
        if button("Export", isDefault = true, w = dp(90)): go = true
        if button("Cancel", w = dp(80)): scrDlg.open = false
    if go:
      scrDlg.open = false
      runScreenExport(d)
  if filePicker(scrDlg.pick, scrDlg.dir, fmFolder, [], "Export for Screens: Folder"): discard
