# (included by photo.nim) Actions: what is done to an image, recorded as
# steps and played back (the Actions palette, File > Automate > Batch).
# This part: the steps, recording them, keeping them; the palette, playing
# and Batch are in pro.nim.

type
  ActKind = enum
    acCommand = "command"        ## a menu command that needs nothing more ("Invert")
    acFilter = "filter"          ## a filter with its settings
    acAdjust = "adjust"          ## an adjustment (Image > Adjust) with its settings
    acAdjustLayer = "adjlayer"   ## a new adjustment layer
    acImageSize = "imagesize"    ## width, height, resampling, resolution, noise
    acFitImage = "fitimage"      ## width, height, don't enlarge (0/1)
    acCanvasSize = "canvassize"  ## width, height, anchor x, anchor y
    acRotate = "rotate"          ## degrees (clockwise)
    acSelect = "select"          ## Feather, Expand...: the number
    acFill = "fill"              ## what (as the Fill dialog), opacity, mode
    acLayerProps = "layerprops"  ## the current layer's mode and opacity
    acNewLayer = "newlayer"      ## a new empty layer (named)
    acStop = "stop"              ## stops playing, with a message

  ActStep = object
    kind: ActKind
    name: string                 ## the command, filter, adjustment, message...
    vals: seq[float]
    data: string                 ## (an adjustment's text settings)
    on: bool                     ## played (its check in the palette)

  Action = object
    name: string
    steps: seq[ActStep]
    open: bool                   ## its steps shown in the palette

const recordableCommands = [
  "Invert", "Equalize", "Desaturate", "Auto Tone", "Auto Levels", "Auto Contrast", "Auto Color",
  "Flatten Image", "Merge Down", "Merge Visible", "Merge Group", "All", "None", "Inverse", "Select All",
  "Grayscale", "RGB Color", "CMYK Color", "Lab Color", "Horizontal", "Vertical", "Flip Layer Horizontal",
  "Flip Layer Vertical", "180°", "90° CW", "90° CCW", "Duplicate Layer", "Delete Layer", "Layer via Copy",
  "Layer via Cut", "Group Layers", "Ungroup Layers", "Crop", "Clear", "Erase Image", "Content-Aware Fill",
  "Subject", "Sky", "Grow", "Similar", "Copy", "Copy Merged", "Paste", "Paste Into", "Cut", "Bring to Front",
  "Bring Forward", "Send Backward", "Send to Back", "Rasterize Layer Style", "New Snapshot", "Lock Layer",
  "Unlock Layer", "Create Clipping Mask", "Release Clipping Mask", "Save Selection", "Load Selection",
  "Trim"]
  ## (the commands an action takes as they are: the ones with a dialog are
  ## taken when it is OK'd, with what was set in it)

var
  actions: seq[Action]
  actionsLoaded = false
  actSel = 0                     ## the action picked in the palette
  actStepSel = -1                ## its step picked (-1: the action itself)
  recording = false              ## steps done go into the action picked
  playing = false                ## an action is being played (nothing is recorded)

proc commandTitle(name: string): string =
  ## A command as a step reads in the palette.
  case name
  of "Horizontal": "Flip Canvas Horizontal"
  of "Vertical": "Flip Canvas Vertical"
  of "180°", "90° CW", "90° CCW": "Rotate Canvas " & name
  of "All", "Select All": "Select All"
  of "None": "Deselect"
  of "Inverse": "Select Inverse"
  of "Subject": "Select Subject"
  of "Sky": "Select Sky"
  of "Grayscale", "RGB Color", "CMYK Color", "Lab Color": "Convert Mode: " & name
  of "Auto Levels": "Auto Tone"
  else: name

proc fmtNum(v: float): string =
  if abs(v - round(v)) < 1e-6: $int(round(v)) else: formatFloat(v, ffDecimal, 1)

proc esc(s: string): string =
  for c in s:
    case c
    of '%': result.add "%25"
    of '|': result.add "%7C"
    of '\n': result.add "%0A"
    of '\r': result.add "%0D"
    of '\t': result.add "%09"
    else: result.add c

proc unesc(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len:
      try:
        result.add chr(parseHexInt(s[i + 1 .. i + 2]))
        i += 3
        continue
      except ValueError: discard
    result.add s[i]
    inc i

proc actionsText(acts: openArray[Action]): string =
  ## The actions as text (kept in the settings; a .actions file).
  result = "Retro Atelier actions 1\n"
  for a in acts:
    result.add "action|" & esc(a.name) & "\n"
    for s in a.steps:
      var vals: seq[string]
      for v in s.vals: vals.add $v
      result.add "step|" & $s.kind & "|" & (if s.on: "1" else: "0") & "|" & esc(s.name) & "|" &
                 vals.join(",") & "|" & esc(s.data) & "\n"

proc parseActions(text: string): seq[Action] =
  for line in text.splitLines:
    let f = line.split('|')
    if f.len >= 2 and f[0] == "action":
      result.add Action(name: unesc(f[1]))
    elif f.len >= 6 and f[0] == "step" and result.len > 0:
      var s = ActStep(on: f[2] != "0", name: unesc(f[3]), data: unesc(f[5]))
      var known = false
      for k in ActKind:
        if $k == f[1]:
          s.kind = k
          known = true
      if not known: continue
      for v in f[4].split(','):
        if v.len > 0:
          try: s.vals.add parseFloat(v)
          except ValueError: discard
      result[^1].steps.add s

proc defaultActions(): seq[Action] =
  ## The actions there are at first.
  proc cmd(n: string): ActStep = ActStep(kind: acCommand, name: n, on: true)
  proc flt(n: string; v: seq[float]): ActStep = ActStep(kind: acFilter, name: n, vals: v, on: true)
  result.add Action(name: "Auto Fix", steps: @[cmd("Auto Tone"), cmd("Auto Color")])
  result.add Action(name: "Sepia Toning (layer)", steps: @[
    cmd("Duplicate Layer"), cmd("Desaturate"),
    ActStep(kind: acAdjust, name: "Hue/Saturation", vals: @[1.0, 35, 25, 0], on: true)])
  result.add Action(name: "Soft Glow", steps: @[
    cmd("Duplicate Layer"), flt("Gaussian Blur", @[12.0]),
    ActStep(kind: acLayerProps, name: "Screen", vals: @[float(LayerModes.find(bmScreen)), 50], on: true)])
  result.add Action(name: "Black and White, Contrasty", steps: @[cmd("Desaturate"), cmd("Auto Contrast")])
  result.add Action(name: "For the Web (1200 pixels)", steps: @[
    cmd("Flatten Image"), cmd("RGB Color"),
    ActStep(kind: acFitImage, name: "Fit Image", vals: @[1200.0, 1200, 1], on: true),
    flt("Unsharp Mask", @[60.0, 0.6, 2])])
  result.add Action(name: "Flip and Turn", steps: @[cmd("Horizontal"), cmd("90° CW")])

proc saveActions() =
  var st = loadSettings(AppData)
  st["actions"] = actionsText(actions)
  discard saveSettings(AppData, st)

proc loadActions() =
  actionsLoaded = true
  let st = loadSettings(AppData)
  if st.hasKey("actions"): actions = parseActions(st["actions"])
  else: actions = defaultActions()
  actSel = clamp(actSel, 0, max(0, actions.high))

proc record(s: ActStep) =
  ## Step `s` was done: into the action being recorded.
  if not recording or playing or actSel notin 0 .. actions.high: return
  var st = s
  st.on = true
  actions[actSel].steps.add st
  actions[actSel].open = true
  actStepSel = actions[actSel].steps.high
  saveActions()

proc recordCommand(name: string) =
  if recording and not playing and name in recordableCommands:
    record(ActStep(kind: acCommand, name: name))
