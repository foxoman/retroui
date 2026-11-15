# (included by photo.nim) The Type tool as today's editors have it: type
# layers edited on the canvas -- a click for a line of text, a box dragged
# for a paragraph, a click on the work path for text along it -- with the
# caret, a selection, the keys, the styles of the Character and Paragraph
# palettes. The text stays editable: a click on it with the Type tool
# edits it again.

var
  typeStyle = CharStyle(family: defaultFamily, style: "Regular", size: 48, color: 0xFF000000'u32,
                        hScale: 1, vScale: 1)
    ## the Character palette's settings for the next text
  typePara: ParaStyle               ## ... the Paragraph palette's
  typeAA = true
  te: tuple[on: bool; dw: DocWin; layer: Layer; caret, anchor: int; style: CharStyle; isNew: bool;
            autoName: bool; focusId: Id; selecting: bool; blink: int; grab: int;
            grabFrom: (float, float); box0: (float32, float32, float32, float32)]
    ## the text being edited (`grab`: the box's corner being dragged, 4 the
    ## whole text, -1 none)
  teLayout: tuple[ver: int; layer: Layer; l: TextLayout]
  textMove: tuple[on: bool; orig: TextData]   ## the Move tool on a type layer
  rasterAsk: tuple[open: bool; then: string]  ## "rasterize the type first?"

proc typeLayout(): TextLayout =
  ## The layout of the text being edited (made again when it changed).
  let L = te.layer
  if teLayout.layer != L or teLayout.ver != L.ver:
    # (as it is drawn: its lines keep out of what has Text Wrap)
    teLayout = (L.ver, L, layoutText(if L.flowFrom == 0 and te.dw != nil: te.dw.doc.effectiveText(L) else: L.text))
  teLayout.l

proc selRange(): (int, int) = (min(te.caret, te.anchor), max(te.caret, te.anchor))

proc typingStyle(): CharStyle =
  ## What new text looks like: the Character palette's settings, in the
  ## foreground color.
  result = typeStyle
  result.color = fg

proc textBounds(L: Layer; slack: float): tuple[x0, y0, x1, y1: float] =
  ## Where a type layer's text is (its box, for text in a box), with room
  ## around.
  let t = L.text
  if t.boxW > 0 and not t.onPath:
    return (t.x.float - slack, t.y.float - slack, (t.x + t.boxW).float + slack, (t.y + t.boxH).float + slack)
  let l = layoutText(t)
  let b = t.drawnBounds(l)
  (b.x0.float - slack, b.y0.float - slack, b.x1.float + slack, b.y1.float + slack)

proc hitsText(L: Layer; x, y, slack: float): bool =
  let b = L.textBounds(slack)
  x >= b.x0 and y >= b.y0 and x <= b.x1 and y <= b.y1

proc startTypeEdit(dw: DocWin; L: Layer; isNew: bool; caret: int) =
  ## The text of `L` taken to be edited (an undo step until it is done).
  let d = dw.doc
  if not isNew:
    d.beginStep("Edit Type Layer")
    d.touchLayers()
  let n = L.text.runeLen
  # (a page's number is shown as it is written while it is typed in: <#>)
  d.rawText = uidOf(L)
  if "<#" in L.text.plainText: d.drawText(L)
  te = (true, dw, L, clamp(caret, 0, n), clamp(caret, 0, n), L.text.styleAt(max(0, caret - 1)), isNew,
        isNew or L.name == L.text.layerName, ui.focus, false, ui.now, -1, (0.0, 0.0),
        (0'f32, 0'f32, 0'f32, 0'f32))
  status = "Type; Ctrl+Enter or another tool ends it, Esc takes it back"

var typeMaskMode* = false    ## the Type Mask tool: what is typed becomes a selection
var typeBackToMove* = false  ## the text was taken to be edited by a double-click with the
                             ## Move tool: when it is done, the Move tool again
var typeVertical* = false    ## the Vertical Type tools: new text runs down

proc commitType() =
  ## The text edited is done (one undo step); an empty new one is dropped.
  if not te.on: return
  te.on = false
  let d = te.dw.doc
  let L = te.layer
  d.rawText = 0
  defer:
    if L in d.layers and "<#" in L.text.plainText: d.drawText(L)     # (its page number shown again)
  if not d.stepOpen:
    status = ""
    return
  if L.text.plainText.strip.len == 0 and (te.isNew or L notin d.layers):
    d.cancelStep()
  elif typeMaskMode and te.isNew and L in d.layers:
    # the Type Mask tool: the letters made a selection (the layer goes), to
    # fill, to mask a picture with (Layer > Layer Mask > Reveal Selection)
    var m = newSeq[uint8](d.w * d.h)
    if L.px.len == m.len:
      for k, v in L.px: m[k] = uint8(v shr 24)
    let i = d.layers.find(L)
    d.touchSel()
    d.touchLayers()
    if i >= 0:
      d.cur = i
      d.deleteLayer()
    d.setSelection(m, soReplace)
    d.markAll()
    d.endStep()
    status = "The letters are selected (Type Mask): Layer > Layer Mask > Reveal Selection puts a picture in them"
    return
  else:
    if te.autoName: L.name = L.text.layerName
    d.endStep()
  status = ""

proc cancelType() =
  ## The text as it was before it was edited (a new one dropped).
  if not te.on: return
  te.on = false
  let d = te.dw.doc
  d.rawText = 0
  if d.stepOpen: d.cancelStep()
  if te.layer in d.layers and "<#" in te.layer.text.plainText: d.drawText(te.layer)
  status = ""

proc editText(change: proc (t: var TextData)) =
  ## The text being edited changed (and drawn again).
  let d = te.dw.doc
  var t = te.layer.text
  change(t)
  if t.spans.len == 0: t.spans.add TextSpan(text: "", style: te.style)
  d.setText(te.layer, t)
  let n = t.runeLen
  te.caret = clamp(te.caret, 0, n)
  te.anchor = clamp(te.anchor, 0, n)
  te.blink = ui.now

proc insertTyped(s: string) =
  ## `s` typed at the caret (over the selection), in the typing style.
  var clean = ""
  for c in s:
    if c == '\r': continue
    clean.add c
  if clean.len == 0: return
  let (a, b) = selRange()
  if '"' in clean or '\'' in clean:
    # (Use Smart Quotes: curly, by the letter before)
    let before = if a > 0 and te.layer != nil: te.layer.text.textSlice(a - 1, a) else: ""
    clean = smartQuote(clean, before)
  let st = te.style
  editText(proc (t: var TextData) =
    t.deleteText(a, b)
    t.insertText(a, clean, st))
  te.caret = a + clean.runeCount
  te.anchor = te.caret

proc deleteSel(): bool =
  let (a, b) = selRange()
  if a == b: return false
  editText(proc (t: var TextData) = t.deleteText(a, b))
  te.caret = a
  te.anchor = a
  true

proc selectedText(): string =
  let (a, b) = selRange()
  te.layer.text.textSlice(a, b)

proc restyleSel(change: proc (s: var CharStyle)) =
  ## The selection's style changed -- or, with none, what is typed next.
  let (a, b) = selRange()
  change(te.style)
  if a == b: return
  editText(proc (t: var TextData) = t.restyle(a, b, change))

proc newTextAt(dw: DocWin; t: TextData) =
  ## A new type layer, edited at once.
  let d = dw.doc
  d.beginStep("Type Tool")
  d.touchLayers()
  d.editMask = false
  var t2 = t
  t2.para = typePara
  t2.antialias = typeAA
  t2.vertical = typeVertical and t2.boxW <= 0 and not t2.onPath
  if t2.spans.len == 0: t2.spans.add TextSpan(text: "", style: typingStyle())
  let L = d.addTextLayer(t2)
  L.name = "Text"
  startTypeEdit(dw, L, true, 0)
  te.style = typingStyle()

proc nearestPathPoint(d: Doc; x, y, radius: float): tuple[ok: bool; pts: seq[(float32, float32)]; at: float32] =
  ## The work path near `x`, `y`: its line (as points) and how far along
  ## it the nearest point is.
  if d.curPath < 0 or d.curPath >= d.paths.len: return
  var best = radius
  for poly in d.paths[d.curPath].flatten(16):
    if poly.len < 2: continue
    var along = 0.0
    var pts: seq[(float32, float32)]
    for p in poly: pts.add (float32(p[0]), float32(p[1]))
    for i in 1 ..< poly.len:
      let (ax, ay) = poly[i - 1]
      let (bx, by) = poly[i]
      let l = hypot(bx - ax, by - ay)
      let u = if l > 0: clamp(((x - ax) * (bx - ax) + (y - ay) * (by - ay)) / (l * l), 0.0, 1.0) else: 0.0
      let dd = hypot(ax + (bx - ax) * u - x, ay + (by - ay) * u - y)
      if dd <= best:
        best = dd
        result = (true, pts, float32(along + u * l))
      along += l

proc needPixels(d: Doc; then = ""): bool =
  ## Whether the layer painted on is pixels; if it is type, the question
  ## to rasterize it is asked (then `then` is run) and false.
  if d == nil or d.quickMask or d.editMask: return true
  let L = d.current
  if L.group:
    status = "\"" & L.name & "\" is a group: pick one of its layers."
    return false
  if L.locked:
    status = "\"" & L.name & "\" is locked (Layer > Unlock Layer)."
    return false
  if L.lockPixels:
    status = "\"" & L.name & "\" has its pixels locked (the brush lock in Layers)."
    return false
  if not L.isText and not L.isShape and not L.isSmart: return true
  if L.isSmart and not L.isText and not L.isShape and smartOk(then): return true
  rasterAsk = (true, then)
  false

# ---- the mouse ------------------------------------------------------------------------------------------

proc typePress(dw: DocWin; ev: PhotoEvent) =
  ## The Type tool pressed on a document.
  let d = dw.doc
  let slack = dp(6).float / dw.view.scaleOf
  if te.on and te.dw == dw and te.layer in d.layers:
    let L = te.layer
    let t = L.text
    # the corners of its box: sized
    if t.boxW > 0 and not t.onPath:
      let corners = [(t.x, t.y), (t.x + t.boxW, t.y), (t.x + t.boxW, t.y + t.boxH), (t.x, t.y + t.boxH)]
      for k, (cx, cy) in corners:
        let (sx, sy) = dw.view.toScreen(d, cx.float, cy.float)
        if abs(sx - ui.mx) <= dp(6) and abs(sy - ui.my) <= dp(6):
          te.grab = k
          te.grabFrom = (ev.x, ev.y)
          te.box0 = (t.x, t.y, t.boxW, t.boxH)
          return
    if L.hitsText(ev.x, ev.y, slack):
      let l = typeLayout()
      let i = t.charAtDrawn(l, ev.x.float32, ev.y.float32)
      if ev.clicks >= 3:
        te.anchor = 0
        te.caret = t.runeLen
      elif ev.clicks == 2:
        te.anchor = t.wordLeft(min(t.runeLen, i + 1))
        te.caret = t.wordRight(i)
        if te.caret <= te.anchor: te.caret = min(t.runeLen, te.anchor + 1)
      else:
        te.caret = i
        if not ev.shift: te.anchor = i
        te.selecting = true
      te.blink = ui.now
      te.style = t.styleAt(max(0, te.caret - 1))
      return
    # outside it: done (the next click makes new text)
    commitType()
    drag.on = false
    return
  if te.on: commitType()
  # a type layer there: edited again
  for i in countdown(d.layers.high, 0):
    let L = d.layers[i]
    if L.visible and L.isText and L.hitsText(ev.x, ev.y, slack * 0.5):
      d.cur = i
      d.editMask = false
      inc d.ver
      let l = layoutText(L.text)
      startTypeEdit(dw, L, false, L.text.charAtDrawn(l, ev.x.float32, ev.y.float32))
      te.selecting = true
      drag.on = false
      return
  # the work path there: text along it
  let p = d.nearestPathPoint(ev.x, ev.y, dp(6).float / dw.view.scaleOf)
  if p.ok:
    var t = newText("", typingStyle())
    t.path = p.pts
    t.pathOffset = p.at
    newTextAt(dw, t)
    drag.on = false
    return
  # else a click (a line of text) or a box dragged (a paragraph): when let go

proc typeDrag(dw: DocWin; ev: PhotoEvent) =
  ## The mouse dragged with the Type tool.
  if not te.on or te.dw != dw: return
  let d = dw.doc
  if te.grab >= 0:
    let dx = float32(ev.x - te.grabFrom[0])
    let dy = float32(ev.y - te.grabFrom[1])
    var (x, y, w, h) = te.box0
    case te.grab
    of 0: x += dx; y += dy; w -= dx; h -= dy
    of 1: y += dy; w += dx; h -= dy
    of 2: w += dx; h += dy
    else: x += dx; w -= dx; h += dy
    if w >= 8 and h >= 8:
      editText(proc (t: var TextData) =
        t.x = x; t.y = y; t.boxW = w; t.boxH = h)
    return
  if te.selecting:
    let l = typeLayout()
    let i = te.layer.text.charAtDrawn(l, ev.x.float32, ev.y.float32)
    if i != te.caret:
      te.caret = i
      te.blink = ui.now
      inc d.ver

proc typeRelease(dw: DocWin; ev: PhotoEvent) =
  ## The Type tool let go: new text where it was pressed (a box when it was
  ## dragged).
  if te.on:
    te.selecting = false
    te.grab = -1
    return
  let d = dw.doc
  let sx = abs(drag.x1 - drag.x0) * dw.view.scaleOf
  let sy = abs(drag.y1 - drag.y0) * dw.view.scaleOf
  if sx >= dp(8).float and sy >= dp(8).float:
    var t = newText("", typingStyle(), float32(min(drag.x0, drag.x1)), float32(min(drag.y0, drag.y1)))
    t.boxW = float32(abs(drag.x1 - drag.x0))
    t.boxH = float32(abs(drag.y1 - drag.y0))
    newTextAt(dw, t)
  else:
    newTextAt(dw, newText("", typingStyle(), float32(drag.x0), float32(drag.y0)))
  inc d.ver

# ---- the keys ---------------------------------------------------------------------------------------------

proc typeKeys() =
  ## The keys while text is edited (they all go to it).
  if not te.on: return
  let d = te.dw.doc
  # (the keys only when no box of a palette has them)
  if ui.focus != te.focusId and ui.focus != 0: return
  let ctrl = CtrlPressed in ui.mods
  let shift = ShiftPressed in ui.mods
  let alt = AltPressed in ui.mods
  let t = te.layer.text
  let n = t.runeLen
  template moveTo(i: int) =
    te.caret = clamp(i, 0, n)
    if not shift: te.anchor = te.caret
    te.blink = ui.now
    te.style = te.layer.text.styleAt(max(0, te.caret - 1))
    inc d.ver
  if not ui.keyUsed:
    ui.keyUsed = true
    let (a, b) = selRange()
    let l = typeLayout()
    case ui.key
    of KeyEsc: cancelType()
    of KeyEnter:
      if ctrl: commitType()
      else: insertTyped("\n")
    of KeyLeft, KeyRight:
      # (in a right-to-left line the arrows go the way the eye does: Left
      # is on through the text, Right back)
      let li = if te.caret < l.caretLine.len: l.caretLine[te.caret] else: -1
      let rtlLine = li >= 0 and li < l.lines.len and l.lines[li].rtl
      let forward = (ui.key == KeyRight) != rtlLine
      if not shift and a != b: moveTo(if forward: b else: a)
      elif forward: moveTo(if ctrl: t.wordRight(te.caret) else: te.caret + 1)
      else: moveTo(if ctrl: t.wordLeft(te.caret) else: te.caret - 1)
    of KeyUp: moveTo(l.lineMove(te.caret, -1))
    of KeyDown: moveTo(l.lineMove(te.caret, 1))
    of KeyHome: moveTo(if ctrl: 0 else: l.lineStart(te.caret))
    of KeyEnd: moveTo(if ctrl: n else: l.lineEnd(te.caret, n))
    of KeyBackspace:
      if not deleteSel() and te.caret > 0:
        let from0 = if ctrl: t.wordLeft(te.caret) else: te.caret - 1
        let c0 = te.caret
        editText(proc (t: var TextData) = t.deleteText(from0, c0))
        te.caret = from0
        te.anchor = from0
    of KeyDelete:
      if not deleteSel() and te.caret < n:
        let to = if ctrl: t.wordRight(te.caret) else: te.caret + 1
        let c0 = te.caret
        editText(proc (t: var TextData) = t.deleteText(c0, to))
    of KeyA:
      if ctrl:
        te.anchor = 0
        te.caret = n
        inc d.ver
      else: ui.keyUsed = false
    of KeyC, KeyX:
      if ctrl:
        if a != b: putClipboardText(selectedText())
        if ui.key == KeyX: discard deleteSel()
      else: ui.keyUsed = false
    of KeyV:
      if ctrl: insertTyped(getClipboardText())
      else: ui.keyUsed = false
    of KeyB, KeyI, KeyU, KeyK, KeyH:
      if ctrl and shift:
        let k = ui.key
        restyleSel(proc (s: var CharStyle) =
          case k
          of KeyB: s.fauxBold = not s.fauxBold
          of KeyI: s.fauxItalic = not s.fauxItalic
          of KeyU: s.underline = not s.underline
          of KeyK: s.allCaps = not s.allCaps
          else: s.smallCaps = not s.smallCaps)
      else: ui.keyUsed = false
    of KeyPeriod, KeyComma:
      if ctrl and shift:
        let up = ui.key == KeyPeriod
        restyleSel(proc (s: var CharStyle) =
          s.size = clamp(s.size + (if up: 2'f32 else: -2'f32), 1, 2000))
      else: ui.keyUsed = false
    of KeyL, KeyR:
      if ctrl and shift:
        let al = if ui.key == KeyL: textLeft else: textRight
        editText(proc (t: var TextData) = t.para.align = al)
      else: ui.keyUsed = false
    else:
      ui.keyUsed = ctrl or alt
  if ui.typed.len > 0 and te.on and not ctrl:
    insertTyped(ui.typed)
    ui.typed = ""

proc typeWatch() =
  ## Each frame: the text being edited is done when its layer, its image or
  ## the tool is no longer it; its step is opened again if something ended
  ## it.
  if not te.on:
    if typeBackToMove:
      # (edited from the Move tool by a double-click: back to it)
      typeBackToMove = false
      if tool == tType: tool = tMove
    return
  let d = te.dw.doc
  if tool != tType or te.dw notin docs or not te.dw.win.open or active != te.dw or
     te.layer notin d.layers or d.current != te.layer or d.quickMask:
    commitType()
    return
  if not d.stepOpen:
    d.beginStep("Edit Type Layer")
    d.touchLayers()
    te.isNew = false

# ---- drawn over the canvas ---------------------------------------------------------------------------------

proc typeOverlay(dw: DocWin) =
  ## The text's box, the caret and the selection.
  if not te.on or te.dw != dw: return
  let d = dw.doc
  let v = dw.view
  let L = te.layer
  if L notin d.layers: return
  let t = L.text
  let l = typeLayout()
  template scr(x, y: float32): (float, float) =
    (let p = v.toScreen(d, x.float, y.float); (p[0].float, p[1].float))
  # the box (text in a box), or a line under the text (a line of it)
  if t.boxW > 0 and not t.onPath:
    let (a, b) = v.toScreen(d, t.x.float, t.y.float)
    let (c, e) = v.toScreen(d, (t.x + t.boxW).float, (t.y + t.boxH).float)
    dashedRect(rect(a, b, max(1, c - a), max(1, e - b)), 0)
    for (hx, hy) in [(a, b), (c, b), (c, e), (a, e)]:
      fill(rect(hx - 3, hy - 3, 7, 7), color(255, 255, 255))
      box(rect(hx - 3, hy - 3, 7, 7), color(0, 0, 0))
  elif not t.onPath and not t.warped:
    for ln in l.lines:
      if t.vertical:
        # (vertical type: the line beside the letters, as they run down)
        let (ax, ay) = t.placePoint(l, ln.x0, ln.baseline)
        let (bx, by) = t.placePoint(l, max(ln.x1, ln.x0 + 1), ln.baseline)
        let (a, b) = v.toScreen(d, ax.float, ay.float)
        let (_, e) = v.toScreen(d, bx.float, by.float)
        vline(a - 1, b, max(1, e - b), color(80, 80, 255))
      else:
        let (a, b) = v.toScreen(d, ln.x0.float, ln.baseline.float)
        let (c, _) = v.toScreen(d, max(ln.x1, ln.x0 + 1).float, ln.baseline.float)
        hline(a, b + 1, max(1, c - a), color(80, 80, 255))
  # the selection: each line's part of it
  let (sa, sb) = selRange()
  if sa != sb:
    for li, ln in l.lines:
      var x0 = 1e9'f32
      var x1 = -1e9'f32
      for k in max(sa, ln.first) .. min(sb, ln.last):
        if k > l.caretX.high or l.caretLine[k] != li: continue
        x0 = min(x0, l.caretX[k])
        x1 = max(x1, l.caretX[k])
      if x1 <= x0: continue
      let top = ln.baseline - ln.ascent
      let bot = ln.baseline + ln.descent
      var poly: seq[(float, float)]
      let steps = if t.warped or t.onPath: 8 elif t.vertical: 1 else: 1
      for k in 0 .. steps:
        let (px, py) = t.placePoint(l, x0 + (x1 - x0) * k.float32 / steps.float32, top)
        poly.add scr(px, py)
      for k in countdown(steps, 0):
        let (px, py) = t.placePoint(l, x0 + (x1 - x0) * k.float32 / steps.float32, bot)
        poly.add scr(px, py)
      polygon(poly, color(40, 90, 255, 110))
  # the caret, blinking
  if sa == sb and (ui.now - te.blink) mod 1000 < 600:
    let c = t.caretLine(l, te.caret)
    let (a, b) = scr(c.x0, c.y0)
    let (e, f) = scr(c.x1, c.y1)
    thickLine(a, b, e, f, max(1.0, dp(2).float / 2), color(0, 0, 0))
  wakeIn(250)
