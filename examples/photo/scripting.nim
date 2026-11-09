# Retro Photo -- included by photo.nim
#
# Scripts (File > Scripts): Retro Script, a JavaScript like the usual own
# scripting, runs here -- the plug-ins of a phone, where the usual .8bf
# plug-ins cannot. A script sees `app` and the documents, their layers,
# the filters and the menu commands:
#
#   let d = app.activeDocument;
#   d.applyFilter("Gaussian Blur", 4);
#   d.activeLayer.opacity = 50;
#   for (const L of d.layers) print(L.name);
#
# File > Scripts > Script Editor writes and runs them; scripts kept in the
# Scripts folder are listed in the menu.

var
  scriptOpen = false             ## the Script Editor shown
  scriptSrc = ""                 ## ... what it holds
  scriptOut: seq[string]         ## ... what scripts printed (and their errors)
  scriptPick = false             ## Run Script...: picking a file
  scriptPath = ""
  scriptSavePick = false         ## the Script Editor's Save...
  scriptRunning = false

const scriptExamples = [
  ("Invert and blur", "// the current image inverted, then blurred\nlet d = app.activeDocument;\n" &
    "app.runCommand(\"Invert\");\nd.applyFilter(\"Gaussian Blur\", 3);\nprint(\"done: \" + d.name);\n"),
  ("Layers listed", "// each layer: its name, opacity, blend mode\nfor (const L of app.activeDocument.layers) {\n" &
    "  print(`${L.name}: ${L.opacity}% ${L.blendMode}${L.visible ? \"\" : \" (hidden)\"}`);\n}\n"),
  ("Frame of 5%", "// a white frame round the image, 5% of its size\nlet d = app.activeDocument;\n" &
    "let m = Math.round(Math.min(d.width, d.height) * 0.05);\n" &
    "d.resizeCanvas(d.width + 2 * m, d.height + 2 * m, \"#ffffff\");\nprint(`frame: ${m} px`);\n"),
  ("Fade the layers", "// each layer above the bottom at a lower opacity\nlet ls = app.activeDocument.layers;\n" &
    "ls.forEach((L, i) => { if (i > 0) L.opacity = Math.max(10, 100 - i * 20); });\n"),
  ("Title text", "// a line of text in the middle, in Arabic and English\nlet d = app.activeDocument;\n" &
    "d.addText(\"مرحبا Hello\", d.width / 2, d.height / 2, Math.round(d.height / 10), \"#ff3300\");\n")]

proc scriptsDir(): string = dataDir(AppName) / "Scripts"
  ## (the folder the Scripts menu lists)

proc scriptFiles(): seq[string] =
  try:
    for k, p in walkDir(scriptsDir()):
      if k in {pcFile, pcLinkToFile} and p.splitFile.ext.toLowerAscii in [".js", ".jsx", ".rscript"]:
        result.add p
  except OSError: discard
  result.sort()

proc colorArg(v: Value; dflt: uint32): uint32 =
  ## A color from a script: "#rrggbb", "rrggbb", or a number 0xRRGGBB.
  case v.kind
  of vkNum: 0xFF000000'u32 or (uint32(v.toInt) and 0xFFFFFF'u32)
  of vkStr:
    var s = v.toStr.strip
    if s.startsWith("#"): s = s[1 .. ^1]
    if s.len == 3: s = $s[0] & $s[0] & $s[1] & $s[1] & $s[2] & $s[2]
    try: 0xFF000000'u32 or (uint32(parseHexInt(s)) and 0xFFFFFF'u32)
    except ValueError: dflt
  else: dflt

proc hexOf(c: uint32): string = "#" & toHex(int(c and 0xFFFFFF), 6).toLowerAscii

proc scriptFail(msg: string) {.noreturn.} = raise newException(ValueError, msg)

proc arg(args: seq[Value]; i: int): Value = (if i < args.len: args[i] else: undefinedValue())

proc numArg(args: seq[Value]; i: int; dflt = 0.0): float =
  if i < args.len and args[i].kind == vkNum: args[i].toNum else: dflt

proc docStep(d: Doc; name: string; body: proc ()) =
  ## (a script's change of a document: one undo step, shown)
  d.beginStep(name)
  try: body()
  finally: d.endStep()
  d.markAll()

proc layerValue(d: Doc; L: Layer): Value
proc docValue(d: Doc): Value

proc layerValue(d: Doc; L: Layer): Value =
  ## (a layer as a script sees it)
  let get = proc (key: string): Value =
    case key
    of "name": toValue(L.name)
    of "opacity": toValue(L.opacity.float)
    of "fillOpacity": toValue(L.fill.float)
    of "visible": toValue(L.visible)
    of "blendMode": toValue($L.mode)
    of "kind": toValue(if L.group: "group" elif L.isText: "text" elif L.isShape: "shape"
                       elif L.adjust.kind.len > 0: "adjustment" elif L.isSmart: "smartObject" else: "pixel")
    of "text": toValue(if L.isText: L.text.plainText else: "")
    of "index": toValue(d.layers.find(L).float)
    of "isBackground": toValue(L.background)
    of "bounds":
      let b = d.layerBox(L)
      toValue(@[toValue(b.x.float), toValue(b.y.float), toValue(float(b.x + b.w)), toValue(float(b.y + b.h))])
    else: undefinedValue()
  let set = proc (key: string; v: Value): bool =
    case key
    of "name":
      d.layersChange("Rename Layer"): L.name = v.toStr
    of "opacity":
      d.layersChange("Opacity"): L.opacity = clamp(int(round(v.toNum)), 0, 100)
      d.markAll()
    of "fillOpacity":
      d.layersChange("Fill Opacity"): L.fill = clamp(int(round(v.toNum)), 0, 100)
      d.markAll()
    of "visible":
      d.layersChange("Show Layer"): L.visible = v.toBool
      d.markAll()
    of "blendMode":
      let name = v.toStr
      var found = false
      for m in BlendMode:
        if ($m).toLowerAscii == name.toLowerAscii:
          d.layersChange("Blend Mode"): L.mode = m
          found = true
      if not found: scriptFail("no blend mode \"" & name & "\"")
      d.markAll()
    of "text":
      if not L.isText: scriptFail("not a type layer")
      d.layersChange("Edit Type"):
        var t = L.text
        let st = t.styleAt(0)
        t.spans = @[TextSpan(text: v.toStr, style: st)]
        d.setText(L, t)
    else: return false
    true
  let call = proc (key: string; args: seq[Value]): Value =
    case key
    of "remove":
      let i = d.layers.find(L)
      if i >= 0:
        d.beginStep("Delete Layer")
        d.touchLayers()
        d.deleteLayer(i)
        d.endStep()
      undefinedValue()
    of "duplicate":
      let i = d.layers.find(L)
      var made: Layer
      d.beginStep("Duplicate Layer")
      d.touchLayers()
      made = d.duplicateLayer(i)
      d.endStep()
      if made == nil: nullValue() else: layerValue(d, made)
    of "moveBy":
      let dx = int(round(numArg(args, 0)))
      let dy = int(round(numArg(args, 1)))
      d.docStep("Move", proc () = d.shiftLayers(@[L], dx, dy))
      undefinedValue()
    of "select":
      let i = d.layers.find(L)
      if i >= 0: d.cur = i
      undefinedValue()
    else: scriptFail("a layer has no " & key & "()")
  hostObject(get, set, call, nil)

proc docValue(d: Doc): Value =
  ## (a document as a script sees it)
  let get = proc (key: string): Value =
    case key
    of "width": toValue(d.w.float)
    of "height": toValue(d.h.float)
    of "name": toValue(d.name)
    of "path": toValue(d.path)
    of "resolution": toValue(d.dpi)
    of "bits": toValue(d.depth.float)
    of "mode": toValue($d.mode)
    of "modified": toValue(d.modified)
    of "hasSelection": toValue(d.hasSelection)
    of "layers":
      var a: seq[Value]
      for L in d.layers: a.add layerValue(d, L)
      toValue(a)
    of "activeLayer": (if d.layers.len > 0: layerValue(d, d.current) else: nullValue())
    of "frames": toValue(d.frames.len.float)
    else: undefinedValue()
  let set = proc (key: string; v: Value): bool =
    case key
    of "bits":
      let b = int(v.toNum)
      if b notin [8, 16, 32]: scriptFail("bits: 8, 16 or 32")
      d.snapStep("Mode")
      if b == 32: d.toHdr() else: d.setDepth(b)
      d.endStep()
    of "resolution": d.dpi = max(1.0, v.toNum)
    of "name": d.name = v.toStr
    else: return false
    true
  let call = proc (key: string; args: seq[Value]): Value =
    result = undefinedValue()
    case key
    of "applyFilter":
      let name = arg(args, 0).toStr
      if not filters.hasKey(name): scriptFail("no filter \"" & name & "\" (its name as in the Filter menu)")
      var vals: seq[float]
      let ps = filters[name].params
      for i, p in ps: vals.add (if i + 1 < args.len and args[i + 1].kind == vkNum: args[i + 1].toNum else: p.val)
      let was = active
      for dw in docs:
        if dw.doc == d: active = dw
      runFilter(name, vals)
      if was != nil and was in docs: active = was
    of "applyLook":
      # (a color look -- "Teal and Orange", "Film"... -- over the layer)
      let name = arg(args, 0).toStr
      if name notin LookNames: scriptFail("no look \"" & name & "\" (" & LookNames.join(", ") & ")")
      d.beginStep(name)
      d.applyFilter(0, lookFn(name))
      d.endStep()
    of "resizeImage":
      let w = max(1, int(round(numArg(args, 0, d.w.float))))
      let h = if args.len > 1: max(1, int(round(numArg(args, 1)))) else: max(1, d.h * w div max(1, d.w))
      d.snapStep("Image Size")
      d.imageSize(w, h)
      d.endStep()
    of "resizeCanvas":
      let w = max(1, int(round(numArg(args, 0, d.w.float))))
      let h = max(1, int(round(numArg(args, 1, d.h.float))))
      let c = colorArg(arg(args, 2), bg)
      d.snapStep("Canvas Size")
      d.canvasSize(w, h, 1, 1, c)
      d.endStep()
    of "crop":
      let r = rect(int(numArg(args, 0)), int(numArg(args, 1)), int(numArg(args, 2, d.w.float)),
                   int(numArg(args, 3, d.h.float)))
      d.snapStep("Crop")
      d.crop(r)
      d.endStep()
    of "rotate":
      let deg = numArg(args, 0, 90)
      d.snapStep("Rotate")
      if abs(deg - round(deg / 90) * 90) < 1e-9: d.rotateImage(int(round(deg / 90)))
      else: d.rotateArbitrary(deg, bg)
      d.endStep()
    of "flip":
      let h = arg(args, 0).toStr.toLowerAscii != "vertical"
      d.snapStep("Flip")
      d.flipImage(h)
      d.endStep()
    of "flatten":
      d.snapStep("Flatten Image")
      d.flatten()
      d.endStep()
    of "selectAll":
      d.selectAll()
    of "deselect":
      d.selectNone()
    of "invertSelection":
      d.invertSelection()
    of "select", "selectEllipse":
      let x = numArg(args, 0)
      let y = numArg(args, 1)
      let w = numArg(args, 2, d.w.float)
      let h = numArg(args, 3, d.h.float)
      let m = if key == "select": d.rectMask(rect(int(x), int(y), int(w), int(h)))
              else: d.ellipseMask(x, y, x + w, y + h)
      d.setSelection(m)
    of "fill":
      let c = colorArg(arg(args, 0), fg)
      let op = int(numArg(args, 1, 100))
      d.docStep("Fill", proc () = d.fillSelection(c, op))
    of "newLayer":
      let name = if args.len > 0: arg(args, 0).toStr else: ""
      var made: Layer
      d.beginStep("New Layer")
      d.touchLayers()
      made = d.addLayer(name)
      d.endStep()
      result = layerValue(d, made); return
    of "addText":
      let s = arg(args, 0).toStr
      var st = typingStyle()
      st.size = float32(numArg(args, 3, st.size.float))
      st.color = colorArg(arg(args, 4), fg)
      var t = newText(s, st, float32(numArg(args, 1, d.w / 2)), float32(numArg(args, 2, d.h / 2)))
      t.para.align = textCenter
      var made: Layer
      d.beginStep("Type Tool")
      d.touchLayers()
      made = d.addTextLayer(t)
      made.name = s
      d.endStep()
      result = layerValue(d, made); return
    of "undo":
      d.undo()
    of "redo":
      d.redo()
    of "save":
      for dw in docs:
        if dw.doc == d: dw.save()
    of "saveAs", "exportAs":
      let p = arg(args, 0).toStr
      if p.len == 0: scriptFail(key & "(path)")
      let f = formatOf(p)
      if key == "saveAs" and f in {efRpd, efPsd}:
        if f == efRpd: d.saveRpd(p) else: d.savePsd(p)
      else:
        var o = defaultExport(f)
        if args.len > 1 and args[1].kind == vkNum: o.quality = clamp(args[1].toInt, 1, 100)
        d.exportPicture(p, o)
    of "close":
      for dw in docs:
        if dw.doc == d: dw.win.open = false
    else: scriptFail("a document has no " & key & "()")
  hostObject(get, set, call, nil)

proc makeScriptVm(): Vm =
  ## (an interpreter with the app in it)
  result = newVm(proc (s: string) = scriptOut.add s)
  let vm = result
  vm.defineFn("alert", proc (args: seq[Value]): Value =
    status = (if args.len > 0: args[0].toStr else: "")
    scriptOut.add "[alert] " & status
    undefinedValue())
  let appGet = proc (key: string): Value =
    case key
    of "version": toValue(AppVersion)
    of "name": toValue(AppName)
    of "activeDocument": (if cur() != nil: docValue(cur()) else: nullValue())
    of "documents":
      var a: seq[Value]
      for dw in docs: a.add docValue(dw.doc)
      toValue(a)
    of "foregroundColor": toValue(hexOf(fg))
    of "backgroundColor": toValue(hexOf(bg))
    of "filters":
      var a: seq[Value]
      for k in filters.keys: a.add toValue(k)
      toValue(a)
    of "language": toValue(if prefs.language == 1: "ar" else: "en")
    of "gpu": toValue(gpuDescription())
    of "gpuFilters": toValue(gpuFiltersReady())
    else: undefinedValue()
  let appSet = proc (key: string; v: Value): bool =
    case key
    of "foregroundColor": fg = colorArg(v, fg)
    of "backgroundColor": bg = colorArg(v, bg)
    else: result = false; return
    true
  let appCall = proc (key: string; args: seq[Value]): Value =
    case key
    of "runCommand", "menu":
      let name = arg(args, 0).toStr
      if name.len == 0: scriptFail("runCommand(name): a menu item's name")
      runCommand(name)
      undefinedValue()
    of "newDocument":
      let w = max(1, int(numArg(args, 0, 1024)))
      let h = max(1, int(numArg(args, 1, 768)))
      let d = newDoc(w, h, colorArg(arg(args, 3), 0xFFFFFFFF'u32),
                     name = (if args.len > 2: arg(args, 2).toStr else: "Untitled"))
      addDoc(d)
      docValue(d)
    of "open":
      let p = arg(args, 0).toStr
      openFile(p)
      if cur() != nil and cur().path == p: docValue(cur()) else: nullValue()
    else: scriptFail("app has no " & key & "()")
  vm.setGlobal("app", hostObject(appGet, appSet, appCall, nil))

proc runScript(src, name: string) =
  ## Runs a script (its output and its error in the Script Editor's log).
  if scriptRunning: return
  scriptRunning = true
  beginBusy("Running " & name)
  let vm = makeScriptVm()
  try:
    let s = compile(src, name)
    let v = vm.run(s)
    if v.kind notin {vkUndefined, vkNull}: scriptOut.add "= " & v.toStr
    scriptOut.add "-- " & name & " ran"
  except ScriptError as e:
    scriptOut.add "!! " & e.msg
    scriptOpen = true
  except BusyCancelled:
    vm.cancel()
    scriptOut.add "!! " & name & ": stopped"
  except CatchableError as e:
    scriptOut.add "!! " & name & ": " & e.msg
    scriptOpen = true
  finally:
    endBusy()
    scriptRunning = false
  while scriptOut.len > 400: scriptOut.delete(0)

proc runScriptFile(path: string) =
  try: runScript(readFile(path), path.extractFilename)
  except IOError, OSError:
    status = "Could not read " & path.extractFilename

proc scriptDialogs() =
  if filePicker(scriptPick, scriptPath, fmOpen, ["*.js", "*.jsx", "*.rscript"], "Run Script"):
    runScriptFile(scriptPath)
  if filePicker(scriptSavePick, scriptPath, fmSave, ["*.js"], "Save Script"):
    var p = scriptPath
    if p.splitFile.ext.len == 0: p.add ".js"
    try:
      writeFile(p, scriptSrc)
      status = "Saved " & p.extractFilename
    except IOError, OSError: status = "Could not save " & p.extractFilename
  if not scriptOpen: return
  if scriptSrc.len == 0: scriptSrc = scriptExamples[0][1]
  dialog(scriptOpen, "Script Editor", 620):
    row:
      label "Example:"
      var names: seq[string]
      for (n, _) in scriptExamples: names.add n
      var k = -1
      if combo(names, k, w = dp(180)) and k >= 0: scriptSrc = scriptExamples[k][1]
      spring()
      if button("Open...", w = dp(80)):
        scriptPath = scriptsDir() & "/"
        scriptPick = true
      if button("Save...", w = dp(80)):
        try: createDir(scriptsDir()) except OSError: discard
        scriptPath = scriptsDir() / "script.js"
        scriptSavePick = true
    editArea(scriptSrc, lines = 14)
    row:
      if button("Run", isDefault = true, w = dp(90)): runScript(scriptSrc, "script")
      if button("Clear", w = dp(70)): scriptOut.setLen(0)
      spring()
      label("app, app.activeDocument, its layers; print(), alert()", color = ui.theme.gray)
    let lh = ItemH * 6
    beginScroll(lh, "scriptout")
    for line in scriptOut:
      label(line, color = if line.startsWith("!!"): color(176, 0, 0) else: ui.theme.text)
    endScroll()
    paragraph("Filters by their names (\"Gaussian Blur\", \"Unsharp Mask\"...), menu commands with " &
              "app.runCommand(\"Invert\"); each change is a step in History. Scripts kept in the Scripts " &
              "folder are in File > Scripts.", color = ui.theme.gray)
