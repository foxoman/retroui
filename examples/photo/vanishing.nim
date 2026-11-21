# Retro Atelier -- included by photo.nim
#
# Filter > Vanishing Point, as the usual: a plane drawn in perspective on
# the picture (four clicks: its corners), then what was copied (Edit >
# Copy) pasted onto it -- smaller as it goes back -- or its own texture
# cloned along it with the Stamp (Alt+click where to copy from).

var
  vpOpen = false
  vpLayer: Layer
  vpPts: seq[(float, float)]     ## the plane's corners (image pixels), as they are clicked
  vpTool = 0                     ## Create Plane, Edit Plane, Stamp, Paste
  vpBrush = 60                   ## the Stamp's diameter (image pixels where it is)
  vpHard = 50
  vpOpacity = 100
  vpPasteSize = 50               ## Paste: % of the plane's width
  vpSrc: tuple[set: bool; u, v: float]
  vpOffset: tuple[on: bool; du, dv: float]
  vpSmall: Img
  vpScale = 1.0
  vpBmp: Bitmap
  vpDirty = true
  vpGrab = -1                    ## Edit Plane: the corner dragged
  vpLastAt = 0

const vpTools = ["Create Plane", "Edit Plane", "Stamp", "Paste"]

proc startVanishingPoint() =
  let d = cur()
  if d == nil or d.current.group or d.current.px.len != d.w * d.h: return
  vpLayer = d.current
  vpPts.setLen(0)
  vpTool = 0
  vpSrc.set = false
  vpOffset.on = false
  vpDirty = true
  vpSmall = Img()
  d.beginStep("Vanishing Point")
  vpOpen = true

proc vpPlaneNow(): VpPlane =
  ## (the plane of the corners: clockwise)
  var q: Quad
  for k in 0 .. 3: q[k] = vpPts[k]
  # (counterclockwise on the screen: turned the other way)
  var area = 0.0
  for k in 0 .. 3:
    let (ax, ay) = q[k]
    let (bx, by) = q[(k + 1) mod 4]
    area += ax * by - bx * ay
  if area < 0: q = [q[0], q[3], q[2], q[1]]
  vpPlane(q)

proc vanishingPointDialog() =
  if not vpOpen: return
  let d = cur()
  if d == nil or d.current != vpLayer or vpLayer.px.len != d.w * d.h:
    vpOpen = false
    if d != nil and d.stepOpen: d.endStep()
    return
  let avail = int(ui.w.float / ui.k)
  let boxW = clamp(avail - 170 - 92 - 56, 200, 680)
  let boxH = boxW * 3 div 4
  if vpDirty or vpSmall.w == 0:
    let f = max(1.0, max(d.w / max(16, dp(boxW) * pxScale), d.h / max(16, dp(boxH) * pxScale)))
    vpSmall = smallCopy(vpLayer.px, d.w, d.bounds, int(ceil(max(d.w, d.h).float / f)))
    vpScale = d.w / max(1, vpSmall.w)
    vpBmp = newBitmap(vpSmall.w, vpSmall.h)
    for i in 0 ..< vpSmall.px.len: vpBmp.px[i] = blendPx(0xFFFFFFFF'u32, vpSmall.px[i], 255, bmNormal)
    vpBmp.changed()
    vpDirty = false
  var done = false
  var cancelled = false
  dialog(vpOpen, "Vanishing Point", boxW + 170 + 92 + 40):
    row([170, boxW + 6, 92]):
      col:
        label("Tools", bold = true)
        pushId("vptools")
        for k, n in vpTools: radio(n, vpTool, k)
        popId()
        space(dp(6))
        if vpTool == 2:
          label "Diameter:"
          row([-1, 40]):
            slider(vpBrush, 2, max(20, max(d.w, d.h) div 3), ticks = 0)
            label $vpBrush
          label "Hardness:"
          row([-1, 40]):
            slider(vpHard, 0, 100, ticks = 0)
            label $vpHard
          label "Opacity:"
          row([-1, 40]):
            slider(vpOpacity, 1, 100, ticks = 0)
            label $vpOpacity
          label((if vpSrc.set: "Drag to clone along the plane" else: "Alt+click where to copy from"),
                color = ui.theme.gray)
        elif vpTool == 3:
          label "Size:"
          row([-1, 40]):
            slider(vpPasteSize, 2, 100, ticks = 0)
            label $vpPasteSize & "%"
          label((if clip.px.len > 0: "Click on the plane to put what was copied there"
                 else: "Copy something first (Edit > Copy)"), color = ui.theme.gray)
        else:
          label((if vpPts.len < 4: tr("Click the plane's 4 corners (") & $vpPts.len & tr(" of 4)")
                 else: "Drag a corner to move it"), color = ui.theme.gray)
        if vpPts.len > 0 and button("Delete Plane", w = dp(110)):
          vpPts.setLen(0)
          vpTool = 0
      col:
        let (box, pic, hit, dragging) = pictureBox("vpbox", vpBmp, dp(boxW), dp(boxH))
        beginKeepSides(box)            # (the plane drawn over the picture as it is, right to left too)
        let k = pic.w.float / max(1, vpSmall.w).float / vpScale     # (screen pixels per image pixel)
        template scr(p: (float, float)): (int, int) {.redefine.} = (pic.x + int(p[0] * k), pic.y + int(p[1] * k))
        let (mxS, myS) = toPicture(pic, vpSmall.w, vpSmall.h, ui.mx, ui.my)
        let mx = mxS * vpScale
        let my = myS * vpScale
        pushClip(inset(box, 1))
        # the plane: its grid, its edges, its corners
        if vpPts.len == 4:
          let pl = vpPlaneNow()
          let good = pl.ok
          for (a, b) in pl.gridLines(8):
            let (ax, ay) = scr(a)
            let (bx, by) = scr(b)
            line(ax, ay, bx, by, if good: color(0, 120, 255) else: color(255, 0, 0))
          if vpTool == 3 and clip.px.len > 0 and mouseIn(box) and good and pl.inside(mx, my):
            # (where the paste would go)
            let (u, v) = pl.toPlane(mx, my)
            let wU = vpPasteSize / 100
            let hU = wU * clip.h.float / max(1, clip.w).float * pl.aspect
            let cs = [pl.toImage(u, v), pl.toImage(u + wU, v), pl.toImage(u + wU, v + hU), pl.toImage(u, v + hU)]
            for c in 0 .. 3:
              let (ax, ay) = scr(cs[c])
              let (bx, by) = scr(cs[(c + 1) mod 4])
              line(ax, ay, bx, by, color(255, 140, 0))
        for i in 0 ..< vpPts.len:
          let (sx, sy) = scr(vpPts[i])
          if i > 0:
            let (px2, py2) = scr(vpPts[i - 1])
            line(px2, py2, sx, sy, color(0, 0, 0))
          fill(rect(sx - dp(3), sy - dp(3), dp(7), dp(7)), color(255, 255, 255))
          box(rect(sx - dp(3), sy - dp(3), dp(7), dp(7)), color(0, 0, 0))
        if vpPts.len == 4:
          let (ax, ay) = scr(vpPts[3])
          let (bx, by) = scr(vpPts[0])
          line(ax, ay, bx, by, color(0, 0, 0))
        if vpTool == 2 and mouseIn(box):
          let rr = max(2, int(vpBrush.float / 2 * k))
          ellipseOnScreen(ui.mx - rr, ui.my - rr, ui.mx + rr, ui.my + rr, color(0, 0, 0))
        popClip()
        if mouseIn(box): ui.cursor = curCrosshair
        # the mouse
        let pressed = hit.down and ui.pressed
        case vpTool
        of 0:
          if pressed and vpPts.len < 4:
            vpPts.add (mx, my)
            if vpPts.len == 4: vpTool = 1
        of 1:
          if pressed:
            vpGrab = -1
            var best = (dp(10).float / k) ^ 2
            for i, p in vpPts:
              let dd = (p[0] - mx) ^ 2 + (p[1] - my) ^ 2
              if dd < best:
                best = dd
                vpGrab = i
          if dragging and vpGrab in 0 .. vpPts.high:
            vpPts[vpGrab] = (clamp(mx, 0, d.w.float), clamp(my, 0, d.h.float))
        of 2:
          if vpPts.len == 4:
            let pl = vpPlaneNow()
            if pressed and AltPressed in ui.mods and pl.inside(mx, my):
              let (u, v) = pl.toPlane(mx, my)
              vpSrc = (true, u, v)
              vpOffset.on = false
            elif dragging and vpSrc.set and AltPressed notin ui.mods and pl.ok and pl.inside(mx, my):
              let (u, v) = pl.toPlane(mx, my)
              if not vpOffset.on:
                vpOffset = (true, vpSrc.u - u, vpSrc.v - v)
              # (the brush as big as the plane is there: smaller as it goes back)
              let base = pl.localScale(vpSrc.u, vpSrc.v)
              let here = pl.localScale(u, v)
              let r = vpBrush.float / 2 * (if base > 0: here / base else: 1.0)
              d.vpClone(vpLayer, pl, (u + vpOffset.du, v + vpOffset.dv), (u, v), max(1.0, r), vpOpacity, vpHard)
              if ui.now - vpLastAt > 60:
                vpDirty = true
                vpLastAt = ui.now
            if ui.released: vpDirty = true
        of 3:
          if pressed and vpPts.len == 4 and clip.px.len > 0:
            let pl = vpPlaneNow()
            if pl.ok and pl.inside(mx, my):
              let (u, v) = pl.toPlane(mx, my)
              d.vpPaste(vpLayer, pl, Img(w: clip.w, h: clip.h, px: clip.px), (u, v), vpPasteSize / 100)
              vpDirty = true
        else: discard
        endKeepSides()
      col:
        if button("OK", isDefault = true, w = dp(86)): done = true
        if button("Cancel", w = dp(86)): cancelled = true
  if done or cancelled or not vpOpen:
    vpOpen = false
    if d.stepOpen:
      if done: d.endStep() else: d.cancelStep()
    d.markAll()
