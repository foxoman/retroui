# (included by photo.nim) Edit > Fade: the last filter, adjustment, stroke or fill made
# weaker (its opacity) or mixed another way (a blend mode) with the layer as it was before it --
# live while the box is open; OK keeps it as a step of its own, Cancel takes it back. The
# engine is `fadeLast` (retroui/photo). Layer > Layer Style > Scale Effects: a style's sizes
# and distances made bigger or smaller, live (`scaleEffects`, retroui/photostyles).

var fadeBox: tuple[open: bool; d: Doc; what: string; opacity, mode: int; shown: string; made: bool]

proc startFade() =
  let d = cur()
  if d == nil or not d.canUndo:
    status = tr("Fade: nothing to fade")
    return
  if te.on: commitType()
  let what = d.undoName
  if what.startsWith("Fade "):
    status = tr("Fade: fade the step before it instead (undo the fade first)")
    return
  fadeBox = (true, d, what, 100, 0, "", false)

proc fadeUndo() =
  ## (the fade tried taken back: Cancel, or the box closed from outside)
  let d = fadeBox.d
  if fadeBox.made and d != nil and d.undoName.startsWith("Fade "):
    d.undo()
    d.dropRedo()
  fadeBox.made = false

proc fadeDialog() =
  if not fadeBox.open:
    if fadeBox.made: fadeUndo()
    return
  let d = fadeBox.d
  if d != cur() or d == nil:
    fadeBox.open = false
    fadeBox.made = false
    return
  var ok, cancel = false
  dialog(fadeBox.open, tr("Fade ") & tr(fadeBox.what), 380):
    row([90, -1, 60]):
      label "Opacity:"
      discard slider(fadeBox.opacity, 0, 100, ticks = 0)
      discard spin(fadeBox.opacity, 0, 100, w = dp(56))
    var names: seq[string]
    for m in LayerModes: names.add tr($m)
    row([90, -1]):
      label "Mode:"
      discard combo(names, fadeBox.mode, w = dp(180))
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): cancel = true
  if not fadeBox.open and not ok: cancel = true          # (closed by its X: as Cancel)
  # (live: the fade made again as the settings change)
  let key = $fadeBox.opacity & "/" & $fadeBox.mode
  if not cancel and key != fadeBox.shown:
    fadeBox.shown = key
    if fadeBox.made and d.undoName.startsWith("Fade "):
      d.undo()
      fadeBox.made = false
    if d.fadeLast(fadeBox.opacity, LayerModes[clamp(fadeBox.mode, 0, LayerModes.high)],
                  "Fade " & fadeBox.what):
      fadeBox.made = true
    else:
      status = tr("Fade: the last step changed no pixels of this layer")
      fadeBox.open = false
      return
  if ok:
    fadeBox.open = false
    fadeBox.made = false
    status = tr("Faded: ") & tr(fadeBox.what)
  elif cancel:
    fadeBox.open = false
    fadeUndo()

# ---- Scale Effects ------------------------------------------------------------------------------------------

var scaleFxBox: tuple[open: bool; d: Doc; L: Layer; was: LayerFx; pct: int; shown: int]

proc startScaleEffects() =
  let d = cur()
  if d == nil or not d.current.hasStyle:
    status = tr("Scale Effects: the layer has no style")
    return
  let L = d.current
  scaleFxBox = (true, d, L, L.fx, 100, 100)
  d.beginStep("Scale Effects")
  d.touchLayers()

proc scaleEffectsDialog() =
  if not scaleFxBox.open:
    if scaleFxBox.d != nil:
      let d = scaleFxBox.d
      scaleFxBox.d = nil
      if d.stepOpen: d.cancelStep()            # (closed from outside: as Cancel)
    return
  let d = scaleFxBox.d
  let L = scaleFxBox.L
  if d != cur() or L notin d.layers:
    scaleFxBox.open = false
    return
  var ok, cancel = false
  dialog(scaleFxBox.open, "Scale Layer Effects", 360):
    row([70, -1, 60]):
      label "Scale:"
      discard slider(scaleFxBox.pct, 1, 1000, ticks = 0)
      discard spin(scaleFxBox.pct, 1, 1000, w = dp(58))
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): cancel = true
  if scaleFxBox.pct != scaleFxBox.shown:
    scaleFxBox.shown = scaleFxBox.pct
    var fx = scaleFxBox.was
    fx.scaleEffects(scaleFxBox.pct.float)
    L.fx = fx
    d.markAll()
  if ok:
    scaleFxBox.open = false
    scaleFxBox.d = nil
    if d.stepOpen: d.endStep()
  elif cancel:
    scaleFxBox.open = false
    scaleFxBox.d = nil
    L.fx = scaleFxBox.was
    if d.stepOpen: d.cancelStep()
    d.markAll()
