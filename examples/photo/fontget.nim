# Retro Atelier -- included by photo.nim
#
# Type > Get Google Fonts: free fonts fetched into Retro Atelier's own folder
# (Arabic ones first), or any Google Fonts family by its name; offered in
# the font lists at once.

var gf: tuple[open: bool; search: string; cat: int; sel: int; name: string; msg: string; ok: bool]

const gfCats = ["All", "Arabic", "Sans Serif", "Serif", "Display", "Handwriting", "Monospace"]

proc fontsFolder(): string = dataDir(AppData) / "Fonts"

proc startGetFonts() =
  gf.open = true
  gf.msg = ""

proc getFontsNow(family: string) =
  ## (downloads it -- the whole files, checked -- then the font lists offer it)
  let fam = family.strip
  if fam.len == 0: return
  var arabic = false
  for f in googleFontList:
    if f.family.toLowerAscii == fam.toLowerAscii: arabic = f.arabic
  let low = fam.toLowerAscii
  if "arabic" in low or "kufi" in low or "naskh" in low: arabic = true
  beginBusy("Downloading " & fam)
  var r: tuple[files: int; error: string]
  try: r = installGoogleFont(fam, fontsFolder(), needArabic = arabic)
  finally: endBusy()
  if r.error.len > 0:
    gf.msg = r.error
    gf.ok = false
    return
  addFontDir(fontsFolder())
  scanFonts(force = true)
  # (the family by the name its files give -- "Noto Kufi Arabic", not the one typed)
  var named = fam
  for f in fontFamilies():
    if f.toLowerAscii == low or f.toLowerAscii.replace(" ", "") == low.replace(" ", ""): named = f
  let problem = fontProblem(named)
  if problem.len > 0:
    gf.msg = named & " came but cannot be used: " & problem
    gf.ok = false
  else:
    gf.msg = named & ": " & $r.files & (if r.files == 1: " style" else: " styles") &
             " installed -- in the font list now"
    gf.ok = true
  status = gf.msg

proc getFontsDialog() =
  if not gf.open: return
  dialog(gf.open, "Get Google Fonts", 460):
    paragraph("Free fonts from Google Fonts (open licenses), fetched once onto this device.",
              color = ui.theme.gray)
    row([-1, 130]):
      edit gf.search
      discard combo(gfCats, gf.cat, w = dp(130))
    var shown: seq[GoogleFont]
    let q = gf.search.strip.toLowerAscii
    for f in googleFontList:
      if gf.cat > 0 and f.category != gfCats[gf.cat] and not (gf.cat == 1 and f.arabic): continue
      if q.len > 0 and q notin f.family.toLowerAscii: continue
      shown.add f
    var names: seq[string]
    let dir = fontsFolder()
    for f in shown:
      names.add (if isInstalled(dir, f.family): "[installed] " else: "") & f.family & "  -- " & f.category &
                (if f.arabic and f.category != "Arabic": ", Arabic" else: "")
    gf.sel = clamp(gf.sel, -1, names.high)
    listbox(names, gf.sel, rows = 10)
    row:
      if button("Download", isDefault = true, w = dp(90), enabled = gf.sel in 0 .. shown.high):
        getFontsNow(shown[gf.sel].family)
      label("or any family:", color = ui.theme.gray)
    row:
      # (the box as wide as leaves the Get button room)
      edit(gf.name, w = max(dp(80), available() - dp(64) - Gap))
      if button("Get", w = dp(64), enabled = gf.name.strip.len > 0): getFontsNow(gf.name)
      tooltip("Download the family typed in the box (its exact name on fonts.google.com)")
    if gf.msg.len > 0:
      label(gf.msg, color = if gf.ok: ui.theme.text else: color(176, 0, 0))
    row:
      spring()
      if button("Close", w = dp(80)): gf.open = false
