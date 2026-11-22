# (included by photo.nim) Recovery: every few minutes (Preferences > History
# & Saving), each document changed since is kept aside in Retro Atelier's own
# folder, written in the background; saved or closed, its copy goes. When
# the program did not end well (a crash, a phone that closed it to free
# memory), the next start offers the copies back.

var
  recoveryDir = ""
  lastAutosave = 0
  recoverySaving = ""            ## the recovery copy being written ("" none)
  recoverFound: seq[tuple[file, name, path: string]]
  recoverOpen = false
  recoverPicks: seq[bool]

proc recoveryFileOf(dw: DocWin): string =
  if dw.recovery.len == 0:
    dw.recovery = recoveryDir / ("doc-" & $getCurrentProcessId() & "-" & toHex(cast[uint](dw)) & ".rpd")
  dw.recovery

proc dropRecovery(dw: DocWin) =
  ## Its copy is not needed any more (saved, closed).
  if dw.recovery.len == 0: return
  for f in [dw.recovery, dw.recovery & ".txt"]:
    try: removeFile(f) except CatchableError: discard
  dw.recovery = ""
  dw.autoVer = -1

var lastParkLook = 0'i64

proc parkTick() =
  ## (each frame) What stood idle for a minute kept small (`parkLayer`): every layer of a
  ## document not shown -- a tab behind -- and the hidden layers of those shown, each
  ## unchanged since the last look; opened out again the moment it is read.
  if docs.len == 0: return
  if lastParkLook == 0:
    lastParkLook = ui.now
    for dw in docs: dw.parkVer = dw.doc.ver
  let wait = lastParkLook + 60_000 - ui.now
  if wait > 0:
    var any = false
    for dw in docs:
      if dw.doc.ver == dw.parkVer and not dw.doc.stepOpen:
        for L in dw.doc.layers:
          if canPark(L, dw.doc.w, dw.doc.h) and (not L.visible or (dw != active and not dw.floating)):
            any = true
            break
      if any: break
    if any: wakeIn(int(wait))
    return
  lastParkLook = ui.now
  var gave = 0
  for dw in docs:
    if dw.doc.ver == dw.parkVer and not dw.doc.stepOpen and not isBookWin(dw):
      gave += (if dw == active or dw.floating: dw.doc.parkHidden() else: dw.doc.parkAll())
    dw.parkVer = dw.doc.ver
  if gave > 0: trimMemory()

proc autosaveTick() =
  ## (each frame) A changed document's copy written when it is time; the
  ## next frame woken for then.
  if prefs.autosave <= 0 or recoveryDir.len == 0: return
  if lastAutosave == 0: lastAutosave = ui.now
  var due: DocWin
  for dw in docs:
    if dw.doc.modified and dw.doc.ver != dw.autoVer and not dw.doc.stepOpen and not isBookWin(dw):
      due = dw
      break
  if due == nil:
    lastAutosave = ui.now
    return
  let wait = lastAutosave + prefs.autosave * 60_000 - ui.now
  if wait > 0:
    wakeIn(wait)
    return
  if saving():
    wakeIn(1000)
    return
  try:
    createDir(recoveryDir)
    let f = due.recoveryFileOf
    writeFile(f & ".txt", due.doc.name & "\n" & due.doc.path & "\n")
    var job = prepareSave(due.doc, f, defaultExport(efRpd))
    startSave(move(job))
    recoverySaving = f
    due.autoVer = due.doc.ver
  except CatchableError:
    status = "Could not keep a recovery copy: " & getCurrentExceptionMsg()
    lastAutosave = ui.now
  wakeIn(200)                    # (the next one, if there is one)

proc findRecovery() =
  ## (at the start) Copies left by a run that did not end well.
  recoveryDir = dataDir(AppData) / "Recovery"
  recoverFound.setLen(0)
  if not dirExists(recoveryDir): return
  let mine = "doc-" & $getCurrentProcessId() & "-"
  for kind, f in walkDir(recoveryDir):
    if kind != pcFile or not (f.endsWith(".rpd") or f.endsWith(".rp3")) or
       f.extractFilename.startsWith(mine): continue
    var name = f.splitFile.name
    var path = ""
    try:
      let meta = readFile(f & ".txt").splitLines
      if meta.len > 0 and meta[0].len > 0: name = meta[0]
      if meta.len > 1: path = meta[1]
    except CatchableError: discard
    recoverFound.add (f, name, path)
  if recoverFound.len > 0:
    recoverPicks = newSeq[bool](recoverFound.len)
    for p in recoverPicks.mitems: p = true
    recoverOpen = true

proc clearRecovery() =
  ## (a good end) This run's copies go.
  if recoveryDir.len == 0 or not dirExists(recoveryDir): return
  let mine = "doc-" & $getCurrentProcessId() & "-"
  for kind, f in walkDir(recoveryDir):
    if kind == pcFile and f.extractFilename.startsWith(mine):
      try: removeFile(f) except CatchableError: discard

proc recoverDialog() =
  if not recoverOpen: return
  dialog(recoverOpen, "Recover Documents", 440):
    row([40, -1]):
      image(glyphIcon(pxWarning, ui.theme.text, dp(32)))
      paragraph(AppName & " did not close properly last time. These documents had changes that were " &
                "not saved; open them again?")
    for i, r in recoverFound:
      checkbox(r.name & (if r.path.len > 0: "  (" & r.path.extractFilename & ")" else: ""), recoverPicks[i])
    row:
      spring()
      if button("Recover", isDefault = true, w = dp(90)):
        for i, r in recoverFound:
          if not recoverPicks[i]: continue
          try:
            let d = openImage(r.file)
            d.name = r.name & " (recovered)"
            d.path = ""                       # (saved as the user says: Save As)
            d.format = ""
            d.modified = true
            addDoc(d)
          except CatchableError:
            status = "Could not recover " & r.name & ": " & getCurrentExceptionMsg()
        for r in recoverFound:
          for f in [r.file, r.file & ".txt"]:
            try: removeFile(f) except CatchableError: discard
        recoverFound.setLen(0)
        recoverOpen = false
      if button("Discard", w = dp(90)):
        for r in recoverFound:
          for f in [r.file, r.file & ".txt"]:
            try: removeFile(f) except CatchableError: discard
        recoverFound.setLen(0)
        recoverOpen = false

# ---- workspaces: where the palettes are, kept ---------------------------------------------------------

proc saveWorkspace(name = "last") =
  ## Where the toolbar is, the panels as they are docked, floating, closed:
  ## kept (Window > Workspace > Save Workspace; and at the end of each run).
  var st = loadSettings(AppData)
  let a = mdiAreaRect("ws")
  st["ws." & name & ".area"] = $a.w & "x" & $a.h
  st["ws." & name & ".tools"] = $toolbox.r.x & "," & $toolbox.r.y & "," & $ord(toolbox.open)
  st["ws." & name & ".dock"] = $dock.toJson
  st["ws." & name & ".optionsBar"] = $optionsBarOn
  st["ws." & name & ".toolHidden"] = prefs.toolHidden
  discard saveSettings(AppData, st)

proc loadWorkspace(name = "last"): bool =
  ## The panels as a workspace had them (false: none kept); the toolbar
  ## where it was when the window is as big as it was then.
  let st = loadSettings(AppData)
  let a = mdiAreaRect("ws")
  if a.w <= 0: return false
  let dj = st.getOrDefault("ws." & name & ".dock")
  if dj.len == 0: return false
  try:
    if not dock.loadDock(parseJson(dj)): return false
  except CatchableError: return false
  # (the panels' icons as they are now: a workspace kept before has older ones)
  for c in dock.columns:
    for g in c.groups:
      for p in g.panels.mitems: p.icon = pdef(p.key).icon
  for c in dock.closed.mitems: c.p.icon = pdef(c.p.key).icon
  # (panels made since: in the dock, a group of their own in the icons)
  let have = dock.keys
  var closedKeys: seq[string]
  for c in dock.closed: closedKeys.add c.p.key
  for (k, _, _) in panelList:
    if k notin have and k notin closedKeys: dock.closed.add (pdef(k), dock.columns.high, 99)
  if st.getOrDefault("ws." & name & ".area") == $a.w & "x" & $a.h:
    let v = st.getOrDefault("ws." & name & ".tools").split(',')
    if v.len == 3:
      try:
        # (the toolbar stays docked at the left edge: only shown or not)
        toolbox.open = v[2] == "1"
      except ValueError: discard
  optionsBarOn = st.getBool("ws." & name & ".optionsBar", optionsBarOn)
  if st.hasKey("ws." & name & ".toolHidden"): prefs.toolHidden = st.getOrDefault("ws." & name & ".toolHidden")
  true

# ---- studios: workspaces of your own, by name -- the panels and the toolbar's tools, shared as files ---

proc studioNames(): seq[string] =
  ## (the workspaces kept by name: Window > Workspace lists them)
  for n in loadSettings(AppData).getOrDefault("ws.studios").split('\t'):
    if n.len > 0: result.add n

proc keepStudio(name: string) =
  ## The panels and tools as they are now kept as the workspace `name` (a new one, or the one of
  ## that name again).
  saveWorkspace("studio:" & name)
  var st = loadSettings(AppData)
  var ns = studioNames()
  if name notin ns: ns.add name
  st["ws.studios"] = ns.join("\t")
  discard saveSettings(AppData, st)

proc dropStudio(name: string) =
  var st = loadSettings(AppData)
  var ns = studioNames()
  ns.keepItIf(it != name)
  st["ws.studios"] = ns.join("\t")
  for k in ["area", "tools", "dock", "optionsBar", "toolHidden"]: st.del("ws.studio:" & name & "." & k)
  discard saveSettings(AppData, st)

proc studioJson(name: string): JsonNode =
  ## (a workspace as a file's: its name, panels, toolbar)
  let st = loadSettings(AppData)
  result = %*{"retroAtelierWorkspace": 1, "name": name}
  for k in ["dock", "optionsBar", "toolHidden", "tools"]:
    let v = st.getOrDefault("ws.studio:" & name & "." & k)
    if v.len > 0: result[k] = (if k == "dock": parseJson(v) else: %v)

proc studioFromJson(j: JsonNode): string =
  ## A workspace file's workspace kept (its name; "" when it is not one).
  if j.kind != JObject or j{"retroAtelierWorkspace"}.getInt == 0: return ""
  let name = j{"name"}.getStr.strip
  if name.len == 0 or j{"dock"} == nil: return ""
  var st = loadSettings(AppData)
  st["ws.studio:" & name & ".dock"] = $j["dock"]
  for k in ["optionsBar", "toolHidden", "tools"]:
    if j{k} != nil: st["ws.studio:" & name & "." & k] = j[k].getStr
  var ns = studioNames()
  if name notin ns: ns.add name
  st["ws.studios"] = ns.join("\t")
  discard saveSettings(AppData, st)
  name

# ---- the session: the documents open at the end, open again at the next start ------------------------------

proc sessionDir(): string = dataDir(AppData) / "Session"

proc writeSession() =
  ## The documents open now kept for the next start (Preferences > File
  ## Handling > Reopen Documents at Start): a saved one by its file, one
  ## with changes (or never saved) by a copy of its own -- its changes
  ## kept. Written at the end and whenever the phone puts the program away
  ## (it may be closed then to free memory).
  if not prefs.session: return
  var st = loadSettings(AppData)
  for i in 0 ..< st.getInt("session.count", 0):
    for k in ["file", "path", "name", "format", "modified", "floating", "win", "zoom", "off"]:
      st.del("session." & $i & "." & k)
  let dir = sessionDir()
  var keep: seq[string]
  var n = 0
  for dw in docs:
    if isBookWin(dw): continue          # (a book is a file of its own: saved as one, not kept here)
    let d = dw.doc
    var file = ""
    if d.modified or d.path.len == 0 or not fileExists(d.path):
      if dw.sessionFile.len == 0 or dw.sessionVer != d.ver or not fileExists(dw.sessionFile):
        try:
          createDir(dir)
          let f = dir / ("doc-" & toHex(cast[uint](dw)) & ".rpd")
          d.saveRpd(f & ".part")
          moveFile(f & ".part", f)
          dw.sessionFile = f
          dw.sessionVer = d.ver
        except CatchableError:
          status = "Could not keep \"" & d.name & "\" for next time: " & getCurrentExceptionMsg()
          continue
      file = dw.sessionFile
      keep.add file
    let k = "session." & $n & "."
    st[k & "file"] = file
    st[k & "path"] = d.path
    st[k & "name"] = d.name
    st[k & "format"] = d.format
    st[k & "modified"] = $d.modified
    st[k & "floating"] = $dw.floating
    let r = dw.win.r
    st[k & "win"] = $r.x & "," & $r.y & "," & $r.w & "," & $r.h & "," & $ord(dw.win.maximized)
    st[k & "zoom"] = $dw.view.zoom
    st[k & "off"] = $dw.view.offX & "," & $dw.view.offY
    inc n
  st["session.count"] = $n
  st["session.active"] = $docs.find(active)
  discard saveSettings(AppData, st)
  # (copies no document needs any more)
  if dirExists(dir):
    for kind, f in walkDir(dir):
      if kind == pcFile and f notin keep:
        try: removeFile(f) except CatchableError: discard

proc restoreSession() =
  ## (the first frame) The documents open at the end of the last run open
  ## again where they were, their unsaved changes too.
  sessionPending = false
  # (the last run stopped and the user chose to start without what was
  # open: the pictures stay closed this once -- their copies are kept)
  if not prefs.session or startFresh(): return
  let st = loadSettings(AppData)
  let n = st.getInt("session.count", 0)
  var back: seq[DocWin]
  var activeAt = -1
  let want = st.getInt("session.active", -1)
  for i in 0 ..< n:
    let k = "session." & $i & "."
    let file = st.get(k & "file")
    let path = st.get(k & "path")
    if file.len == 0:
      # a saved document: opened from its file (not twice)
      if path.len == 0 or not fileExists(path): continue
      var already = false
      for o in docs:
        if o.doc.path == path: already = true
      if already: continue
      let before = docs.len
      openFile(path)
      if docs.len == before: continue
    else:
      if not fileExists(file): continue
      try:
        let d = loadRpd(file)
        d.path = path
        d.name = st.get(k & "name", d.name)
        d.format = st.get(k & "format")
        d.modified = st.getBool(k & "modified", true)
        addDoc(d)
        docs[^1].sessionFile = file
        docs[^1].sessionVer = d.ver
      except CatchableError:
        status = "Could not reopen \"" & st.get(k & "name") & "\": " & getCurrentExceptionMsg()
        continue
    let dw = docs[^1]
    # (a tab or a window as the workspace has them now: Window > Arrange)
    let wv = st.get(k & "win").split(',')
    if dw.floating and wv.len == 5:
      try:
        let a = mdiAreaRect("ws")
        let r = rect(parseInt(wv[0]), parseInt(wv[1]), parseInt(wv[2]), parseInt(wv[3]))
        if a.w <= 0 or (r.x < a.w - dp(40) and r.y < a.h - dp(20)):
          dw.win.r = r
          dw.win.maximized = wv[4] == "1"
          dw.placed = true
      except ValueError: discard
    try:
      dw.view.zoom = parseInt(st.get(k & "zoom", $dw.view.zoom))
      let o = st.get(k & "off").split(',')
      if o.len == 2:
        dw.view.offX = parseInt(o[0])
        dw.view.offY = parseInt(o[1])
      dw.view.fitWanted = false
    except ValueError: discard
    back.add dw
    if i == want: activeAt = back.high
  if back.len == 0: return
  let top = if activeAt >= 0: back[activeAt] else: back[^1]
  top.showDoc()
  status = "Reopened " & $back.len & (if back.len == 1: " document" else: " documents") & " from last time"
  # (the copies kept for a run that ended badly, of documents just reopened
  # with later changes: not offered again)
  var k = 0
  while k < recoverFound.len:
    let r = recoverFound[k]
    var same = false
    for dw in back:
      if (r.path.len > 0 and r.path == dw.doc.path) or (r.path.len == 0 and r.name == dw.doc.name): same = true
    if same:
      for f in [r.file, r.file & ".txt"]:
        try: removeFile(f) except CatchableError: discard
      recoverFound.delete(k)
      if k < recoverPicks.len: recoverPicks.delete(k)
    else: inc k
  if recoverFound.len == 0: recoverOpen = false
