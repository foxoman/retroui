# Retro Atelier -- included by photo.nim
#
# Type > Get Google Fonts: free fonts fetched into Retro Atelier's own folder
# (Arabic ones first), or any Google Fonts family by its name; offered in
# the font lists at once. The download runs on a worker (retroui/jobs): the
# window keeps drawing, the box shows how far it is, Cancel stops it.

var
  gf: tuple[open: bool; search: string; cat: int; sel: int; name: string; msg: string; ok: bool]
  gfJob: Job[tuple[files: int; error: string]]
  gfFam = ""                           ## (the family being fetched)
  gfGot = 0                            ## (how many downloads ended: the list's "[installed]" again)
  gfList: tuple[key: string; shown: seq[GoogleFont]; names: seq[string]]

const gfCats = ["All", "Arabic", "Sans Serif", "Serif", "Display", "Handwriting", "Monospace"]

proc fontsFolder(): string = dataDir(AppData) / "Fonts"

var catalog: seq[GoogleFont]
proc fontCatalog(): seq[GoogleFont] =
  ## (all of Google Fonts' families, read once)
  if catalog.len == 0: catalog = googleFontCatalog()
  catalog

proc startGetFonts() =
  gf.open = true
  gf.msg = ""

proc gotFont(fam: string) =
  ## (the download ended: the fonts it brought put in the lists, or why not)
  inc gfGot
  let low = fam.toLowerAscii
  if gfJob.failed:
    gf.msg = gfJob.error
    gf.ok = false
  elif not gfJob.done or gfJob.value.error == "stopped":
    gf.msg = tr("Stopped: nothing of ") & fam & tr(" kept")
    gf.ok = false
  elif gfJob.value.error.len > 0:
    gf.msg = gfJob.value.error
    gf.ok = false
  else:
    addFontDir(fontsFolder())
    scanFonts(force = true)
    # (the family by the name its files give -- "Noto Kufi Arabic", not the one typed)
    var named = fam
    for f in fontFamilies():
      if f.toLowerAscii == low or f.toLowerAscii.replace(" ", "") == low.replace(" ", ""): named = f
    let problem = fontProblem(named)
    if problem.len > 0:
      gf.msg = named & tr(" came but cannot be used: ") & problem
      gf.ok = false
    else:
      let n = gfJob.value.files
      gf.msg = named & ": " & $n & (if n == 1: tr(" style") else: tr(" styles")) &
               tr(" installed -- in the font list now")
      gf.ok = true
  status = gf.msg

proc getFontsNow(family: string) =
  ## (fetched on a worker -- the whole files, checked -- then the font lists offer it)
  let fam = family.strip
  if fam.len == 0 or gfJob.running: return
  var arabic = false
  for f in fontCatalog():
    if f.family.toLowerAscii == fam.toLowerAscii: arabic = f.arabic
  let low = fam.toLowerAscii
  if "arabic" in low or "kufi" in low or "naskh" in low: arabic = true
  let dir = fontsFolder()
  gfFam = fam
  gf.msg = ""
  gfJob = job(proc (c: JobCtl): tuple[files: int; error: string] {.gcsafe.} =
                # (ttf's forward-declared procs read as not GC-safe; the parse touches no global)
                {.cast(gcsafe).}:
                  installGoogleFont(fam, dir, needArabic = arabic, hooks = FontFetchHooks(
                    progress: proc (step, steps: int; what: string) {.gcsafe.} =
                      c.progress(min(0.98, step / max(1, steps))),
                    stop: proc (): bool {.gcsafe.} = c.cancelled)),
              onDone = proc () = gotFont(fam))
  status = tr("Downloading ") & fam & "..."

proc getFontsDialog() =
  if not gf.open: return
  dialog(gf.open, "Get Google Fonts", 460):
    paragraph("Every family of Google Fonts, the Arabic ones first: open licenses, fetched once onto " &
              "this device.", color = ui.theme.gray)
    row([-1, 130]):
      edit gf.search
      discard combo(gfCats, gf.cat, w = dp(130))
    let q = gf.search.strip.toLowerAscii
    let key = q & "|" & $gf.cat & "|" & $gfGot
    if gfList.key != key or gfList.names.len == 0:
      # (made again when the search, the kind or what is installed changed: not every frame,
      # the whole of Google Fonts and a look in the folder for each)
      gfList.key = key
      gfList.shown.setLen(0)
      gfList.names.setLen(0)
      let dir = fontsFolder()
      var there: seq[string]
      for kind, d in walkDir(dir):
        if kind == pcDir: there.add d.extractFilename
      for f in fontCatalog():
        if gf.cat > 0 and f.category != gfCats[gf.cat] and not (gf.cat == 1 and f.arabic): continue
        if q.len > 0 and q notin f.family.toLowerAscii: continue
        gfList.shown.add f
        let got = f.family.replace(" ", "") in there and isInstalled(dir, f.family)
        gfList.names.add (if got: "[installed] " else: "") & f.family & "  -- " & f.category &
                         (if f.arabic and f.category != "Arabic": ", Arabic" else: "")
    template shown: untyped = gfList.shown        # (not copied every frame)
    template names: untyped = gfList.names
    gf.sel = clamp(gf.sel, -1, names.high)
    listbox(names, gf.sel, rows = 10)
    let busyNow = gfJob.running
    row:
      if button("Download", isDefault = true, w = dp(90), enabled = gf.sel in 0 .. shown.high and not busyNow):
        getFontsNow(shown[gf.sel].family)
      label("or any family:", color = ui.theme.gray)
    row:
      # (the box as wide as leaves the Get button room)
      edit(gf.name, w = max(dp(80), available() - dp(64) - Gap))
      if button("Get", w = dp(64), enabled = gf.name.strip.len > 0 and not busyNow): getFontsNow(gf.name)
      tooltip("Download the family typed in the box (its exact name on fonts.google.com)")
    if busyNow:
      # (how far it is: the window keeps working meanwhile)
      label(tr("Downloading ") & gfFam & "...")
      row([-1, 80]):
        progress(gfJob.progress)
        if button("Cancel", w = dp(80)):
          gfJob.cancel()
          gf.msg = tr("Stopping...")
      wakeIn(100)
    if gf.msg.len > 0:
      label(gf.msg, color = if gf.ok: ui.theme.text else: color(176, 0, 0))
    row:
      spring()
      if button("Close", w = dp(80)): gf.open = false
