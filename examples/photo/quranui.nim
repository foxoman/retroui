# (included by photo.nim) Type > Quran: the Quran's text (`retroui/quran`) from a Tanzil text file
# the user gives -- or downloads from Tanzil once into Retro Atelier's own folder -- looked up by
# sura and ayah or searched (Arabic matched as written either way), a passage put into the text
# being typed (or a new text box), each ayah's number in ornate brackets or after the end-of-ayah
# sign; a text typed by hand checked against it, the first place it differs selected.

var
  qr: tuple[open, loaded, tried: bool; q: Quran; sura, first, last: int; find: string;
            hits: seq[tuple[sura, aya: int]]; hit: int; note: string; ends: AyahEnds]
  qrJob: Job[string]
  qrPick = false
  qrPath = ""

proc quranFolder(): string = dataDir(AppData) / "Quran"

proc qrShort(s: string; n: int): string =
  ## (the first `n` letters of `s`, "..." after when there is more)
  var k = 0
  for r in s.runes:
    if k >= n:
      result.add " ..."
      return
    result.add r.toUTF8
    inc k

proc quranLoad(path: string): bool =
  try:
    qr.q = loadQuran(path)
    qr.loaded = true
    qr.note = $qr.q.ayat.len & tr(" ayat in ") & $qr.q.suras & tr(" suras, from ") & path.extractFilename
    true
  except CatchableError:
    qr.note = tr("Not a Quran text (a Tanzil file: a line sura|aya|text an ayah): ") & getCurrentExceptionMsg()
    false

proc startQuran() =
  qr.open = true
  if qr.sura == 0: (qr.sura, qr.first, qr.last) = (1, 1, 7)
  if not qr.loaded and not qr.tried:
    qr.tried = true
    let p = quranFolder() / quranFile
    if fileExists(p): discard quranLoad(p)

proc quranInsert() =
  let txt = qr.q.passage(qr.sura, qr.first, qr.last, qr.ends)
  if txt.len == 0:
    qr.note = tr("No such ayat in the text")
    return
  if te.on:
    insertTyped(txt)
    status = tr("Inserted: ") & suraName(qr.sura) & " " & $qr.first & "-" & $qr.last
  else:
    let d = cur()
    if d == nil:
      qr.note = tr("Open a picture or a book first")
      return
    var st = defaultStyle()
    st.size = max(12'f32, d.h.float32 / 40)
    var t = newText(txt, st, d.w.float32 * 0.1, d.h.float32 * 0.1)
    t.boxW = d.w.float32 * 0.8
    t.boxH = d.h.float32 * 0.8
    t.para.align = justifyRight
    d.stepOnce("Quran", proc () =
      let L = d.addTextLayer(t)
      L.name = suraName(qr.sura) & " " & $qr.first & "-" & $qr.last)
    status = tr("A text box with ") & suraName(qr.sura) & " " & $qr.first & "-" & $qr.last

proc quranCheck() =
  ## (the text being typed -- its selection, else all of it -- or the text layer picked, checked
  ## against the ayat chosen; the first place it differs selected)
  let d = cur()
  var L: Layer = nil
  var a0, b0 = 0
  if te.on:
    L = te.layer
    let (a, b) = selRange()
    (a0, b0) = if a < b: (a, b) else: (0, L.text.runeLen)
  elif d != nil and d.current != nil and d.current.isText:
    L = d.current
    (a0, b0) = (0, L.text.runeLen)
  if L == nil:
    qr.note = tr("Check: pick the text typed by hand first (or select it with the Type tool)")
    return
  let typed = L.text.textSlice(a0, b0)
  let diffs = qr.q.checkTyped(typed, qr.sura, qr.first, qr.last)
  if diffs.len == 0:
    qr.note = tr("The same as the text: ") & suraName(qr.sura) & " " & $qr.first & "-" & $qr.last
    return
  qr.note = $diffs.len & tr(" places differ from the text -- the first one is selected")
  if te.on and te.layer == L:
    te.anchor = a0 + diffs[0].a
    te.caret = a0 + max(diffs[0].b, diffs[0].a)

proc quranDialog() =
  if qrJob != nil and qrJob.done:
    let err = qrJob.value
    qrJob = nil
    if err.len == 0:
      # (not a Tanzil text -- a page in its place --: not kept, to be tried again)
      if not quranLoad(quranFolder() / quranFile):
        try: removeFile(quranFolder() / quranFile) except OSError: discard
    else: qr.note = tr("Could not download it: ") & err & tr(" -- download it at tanzil.net/download and open it here")
  if qrPick:
    if filePicker(qrPick, qrPath, fmOpen, ["*.txt"], "Open a Quran Text"):
      if quranLoad(qrPath):
        # (kept: opened again next time)
        try:
          createDir(quranFolder())
          copyFile(qrPath, quranFolder() / quranFile)
        except CatchableError: discard
  if not qr.open: return
  var doInsert, doCheck = false
  dialog(qr.open, "Quran", 560):
    if not qr.loaded:
      paragraph(tr("The Quran's text comes from Tanzil (tanzil.net), as it is: download it once, or " &
                   "open a Tanzil text file you have (Uthmani or simple, \"Text (with aya numbers)\")."),
                color = ui.theme.gray)
      row:
        if button("Download from Tanzil", w = dp(170), enabled = qrJob == nil):
          let dest = quranFolder() / quranFile
          qr.note = tr("Downloading...")
          qrJob = job(proc (c: JobCtl): string {.gcsafe.} = downloadFile(quranUrl, dest))
        if button("Open a Quran Text...", w = dp(170)):
          qrPath = getHomeDir()
          qrPick = true
    else:
      var names: seq[string]
      for s in 1 .. 114: names.add $s & ". " & suraName(s)
      row([72, 200, 50, 70, 30, 70]):
        label "Sura:"
        var k = qr.sura - 1
        if combo(names, k, w = dp(192)):
          qr.sura = k + 1
          qr.first = 1
          qr.last = min(qr.q.ayatIn(qr.sura), 10)
        label "Ayat:"
        var f = qr.first
        if spin(f, 1, max(1, qr.q.ayatIn(qr.sura)), w = dp(66)): qr.first = f
        label "to", literal = false
        var l = qr.last
        if spin(l, 1, max(1, qr.q.ayatIn(qr.sura)), w = dp(66)): qr.last = l
      qr.last = max(qr.last, qr.first)
      row([72, -1]):
        label "Each ayah:"
        var e = ord(qr.ends)
        # (the English label's brackets the other way round: a left-to-right line shows them so)
        if combo([tr("Its number in ornate brackets ﴾١﴿"), tr("The end-of-ayah sign ۝١ (a Quran font)"),
                  tr("No number")], e, w = dp(300)):
          qr.ends = AyahEnds(e)
      let shown = qr.q.passage(qr.sura, qr.first, min(qr.last, qr.first + 2), qr.ends)
      paragraph(qrShort(shown, 260))
      row([72, -1, 80]):
        label "Search:"
        discard edit(qr.find, w = dp(300))
        if button("Find", w = dp(76)):
          qr.hits = qr.q.search(qr.find)
          qr.hit = 0
          qr.note = $qr.hits.len & tr(" ayat")
      if qr.hits.len > 0:
        var rows: seq[string]
        for (s, a) in qr.hits:
          let t = qr.q.ayah(s, a)
          rows.add suraName(s) & " " & $a & ": " & qrShort(t, 70)
        if listbox(rows, qr.hit, rows = 5):
          (qr.sura, qr.first, qr.last) = (qr.hits[qr.hit].sura, qr.hits[qr.hit].aya, qr.hits[qr.hit].aya)
    if qr.note.len > 0: label(qr.note, color = ui.theme.gray, literal = true)
    row:
      if qr.loaded:
        if button("Check Typed Text", w = dp(150)): doCheck = true
        if button("Insert", isDefault = true, w = dp(90)): doInsert = true
      spring()
      if button("Close", w = dp(80)): qr.open = false
  if doInsert: quranInsert()
  if doCheck: quranCheck()
