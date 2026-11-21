# (included by photo.nim) Text frames as the layout program has them. A text box picked with
# the Move tool shows its in port (top left) and out port (bottom right): empty, a triangle when
# it is threaded there, a red plus in the out port when its text is overset. A click on the out
# port loads the text: a click on another box then threads it (its own words added to the
# story's end), a click or a drag where there is none makes a box there that takes it -- on
# another page of a book too (turn to it in Pages first). A click on a port that is threaded,
# then on the box at the other end of the thread (or a double-click on the port), breaks it:
# the boxes after it empty, the text overset in the box before. Esc lets the loaded text go.
# A threaded box picked shows the thread's lines (View > Show > Text Threads). Type > Text
# Frame Options: columns, their gutter, and Auto-Size -- the box as big as its text, from the
# reference point picked -- live.

var
  tl: tuple[loaded: bool; dw: DocWin; doc: Doc; page, uid, mode: int; pressing: bool; x0, y0, x1, y1: float]
    ## (the loaded text: its box -- `uid`, on `page` of a book, else in `doc` -- and what a click
    ## does: 0 thread, 1 the out port of a threaded box (its thread broken at the next box), 2 the
    ## in port of one (broken at the box before))
  tfDlg: tuple[open: bool; layer: Layer; cols: int; gutter: float32; auto, refPt: int;
               inset: array[4, float32]; vjust: int; balance: bool; rule: ColumnRule]
    ## (lengths in the document's pixels, shown in the rulers' unit)
  tfApplied = ""
  tfPending = false
  tlOverset: tuple[layer: Layer; ver, dver: int; overset: bool]   ## (the picked box's overset, as last laid out)

proc isFrame(L: Layer): bool =
  ## (a box of type the ports are for)
  L != nil and L.isText and L.text.boxW > 0 and L.text.boxH > 0 and L.text.path.len == 0 and
    not L.text.vertical and L.fromMaster == 0 and L.fromSpan == 0

proc frameScreen(dw: DocWin; L: Layer): Rect =
  let d = dw.doc
  let t = L.text
  let (x0, y0) = dw.view.toScreen(d, t.x.float, t.y.float)
  let (x1, y1) = dw.view.toScreen(d, float(t.x + t.boxW), float(t.y + t.boxH))
  rect(x0, y0, max(1, x1 - x0), max(1, y1 - y0))

proc inPort(dw: DocWin; L: Layer): Rect =
  let r = dw.frameScreen(L)
  let s = dp(9)
  rect(r.x - s div 2, r.y + min(dp(14), r.h div 3) - s div 2, s, s)

proc outPort(dw: DocWin; L: Layer): Rect =
  let r = dw.frameScreen(L)
  let s = dp(9)
  rect(r.x + r.w - s div 2 - 1, r.y + r.h - min(dp(14), r.h div 3) - s div 2, s, s)

proc frameAt(d: Doc; x, y: float): Layer =
  ## (the top box of type where the point is)
  for i in countdown(d.layers.high, 0):
    let L = d.layers[i]
    if not L.visible or not L.isFrame or L.locked: continue
    let t = L.text
    if x >= t.x and y >= t.y and x < t.x + t.boxW and y < t.y + t.boxH: return L

proc tlBook(): BookWin =
  if tl.dw != nil: bookOf(tl.dw) else: nil

proc tlSource(): Layer =
  ## (the box the loaded text is from; nil: gone)
  let bw = tlBook()
  if bw != nil:
    if tl.page < 0 or tl.page >= bw.book.pages.len: return nil
    return bw.book.doc(tl.page).layerOfUid(tl.uid)
  if tl.doc == nil: return nil
  tl.doc.layerOfUid(tl.uid)

proc nextOf(dw: DocWin; S: Layer): tuple[page: int; layer: Layer] =
  ## (the box `S` goes on into: on this page, or -- a book -- another)
  let d = dw.doc
  let N = d.followerOf(S)
  if N != nil: return (-1, N)
  let bw = bookOf(dw)
  if bw != nil and S.flowOut and bw.master == 0: return bw.book.follower(bw.page, S)
  (-1, nil)

proc threadEscape(): bool =
  ## (Esc: the loaded text let go)
  if not tl.loaded: return false
  tl.loaded = false
  tl.pressing = false
  status = "The loaded text let go"
  true

proc breakThread(dw: DocWin; M: Layer; page: int) =
  ## (the thread into `M` -- on this page, or `page` of the book -- broken)
  let d = dw.doc
  let bw = bookOf(dw)
  if M.flowPage != 0 and bw != nil:
    let at = if page >= 0: page else: bw.page
    bw.book.unlinkPages(at, M, keepText = false)
    if at != bw.page: bw.book.park([bw.page])
    d.markAll()
  else:
    d.beginStep("Break Thread")
    d.touchLayers()
    for L in d.layers:
      if L.isText: d.touch(L, d.bounds)
    d.unthreadText(M)
    d.endStep()
  status = tr("Thread broken: \"") & M.name & tr("\" takes nothing now; the text is overset in the box before it")

proc threadInto(dw: DocWin; S: Layer; M: Layer) =
  ## (the loaded text threaded into `M` of the page shown)
  let d = dw.doc
  let bw = bookOf(dw)
  let crossPage = bw != nil and tl.page >= 0 and tl.page != bw.page
  if crossPage:
    if bw.book.threadPages(tl.page, S, bw.page, M):
      bw.book.park([bw.page])
      d.markAll()
      status = tr("The text of page ") & bw.book.label(tl.page) & tr(" goes on into \"") & M.name & "\""
    else: status = "That box cannot take it: it takes text from another box already, or the story begins there."
    return
  if not d.canThread(S, M):
    status = "That box cannot take it: it takes text from another box already, or comes before this one in the thread."
    return
  d.beginStep("Thread Text")
  d.touchLayers()
  for L in d.layers:
    if L.isText: d.touch(L, d.bounds)
  if d.threadText(S, M):
    d.endStep()
    status = "\"" & S.name & tr("\" goes on into \"") & M.name & "\""
  else:
    d.cancelStep()
    status = "That box has text of its own and the story begins on another page: thread it there."

proc newFrameFor(dw: DocWin; S: Layer; x0, y0, x1, y1: float) =
  ## (a new box where the loaded text was clicked or dragged, threaded)
  let d = dw.doc
  var r = (min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1))
  if r[2] - r[0] < 8 or r[3] - r[1] < 8:
    # a click: as wide as the column there, down to the margin (a book); else as big as the box
    # it comes from
    let bw = bookOf(dw)
    if bw != nil and bw.master == 0:
      let b = bw.book
      let m = b.marginBox(bw.page)
      let n = max(1, b.setup.columns)
      let cw = (m.w - b.setup.gutter * (n - 1)) / n
      var c = int((x0 - m.x.float) / max(1.0, cw + b.setup.gutter.float))
      c = clamp(c, 0, n - 1)
      let cx = m.x.float + c.float * (cw + b.setup.gutter.float)
      let top = clamp(y0, m.y.float, float(m.y + m.h) - 24)
      r = (cx, top, cx + cw, float(m.y + m.h))
    else:
      r = (x0, y0, x0 + S.text.boxW.float, y0 + S.text.boxH.float)
  var t = S.text
  t.spans = @[TextSpan(text: "", style: (if S.text.spans.len > 0: S.text.spans[0].style else: defaultStyle()))]
  t.x = float32(r[0])
  t.y = float32(r[1])
  t.boxW = float32(r[2] - r[0])
  t.boxH = float32(r[3] - r[1])
  t.notes = @[]
  t.autoSize = asOff
  t.fit = false
  t.warp = TextWarp()
  let bw = bookOf(dw)
  let crossPage = bw != nil and tl.page >= 0 and tl.page != bw.page
  if crossPage:
    let M = d.addTextLayer(t)
    M.name = "Text (continued)"
    dw.threadInto(S, M)
    return
  d.beginStep("Thread Text")
  d.touchLayers()
  for L in d.layers:
    if L.isText: d.touch(L, d.bounds)
  let M = d.addTextLayer(t)
  M.name = S.name & " (continued)"
  if d.threadText(S, M):
    d.endStep()
    status = "\"" & S.name & tr("\" goes on into the new box")
  else: d.cancelStep()

proc threadPress(dw: DocWin; ev: PhotoEvent): bool =
  ## (the ports, and the loaded text: what the mouse does with them; true when it took it)
  let d = dw.doc
  if tl.loaded:
    if tool != tMove or (tlBook() == nil and tl.dw != dw) or (tlBook() != nil and tl.dw != dw):
      tl.loaded = false
      return false
    if tl.pressing:
      tl.x1 = ev.x
      tl.y1 = ev.y
      if ev.released or not ui.mouseDown:
        tl.pressing = false
        tl.loaded = false
        let S = tlSource()
        if S != nil: dw.newFrameFor(S, tl.x0, tl.y0, tl.x1, tl.y1)
      return true
    if not ev.pressed: return false
    if ev.right:
      discard threadEscape()
      return true
    let S = tlSource()
    if S == nil:
      tl.loaded = false
      return true
    let bw = bookOf(dw)
    let samePage = bw == nil or tl.page == bw.page
    # (its own port again: a double-click there breaks the thread -- or lets the text go)
    if samePage and S in d.layers and (mouseIn(dw.outPort(S)) or mouseIn(dw.inPort(S))):
      tl.loaded = false
      if tl.mode == 1:
        let (k, N) = dw.nextOf(S)
        if N != nil: dw.breakThread(N, k)
      elif tl.mode == 2: dw.breakThread(S, -1)
      else: status = "The loaded text let go"
      return true
    let M = d.frameAt(ev.x, ev.y)
    case tl.mode
    of 1:
      # (the box it goes on into: on its page, or -- turned to another page of the book -- there)
      let (k, N) = if samePage: dw.nextOf(S) else: bw.book.follower(tl.page, S)
      if M != nil and N != nil and (M == N or (M == S and samePage)):
        tl.loaded = false
        dw.breakThread(N, k)
        return true
    of 2:
      if M != nil and samePage and (M == S or M.uid == S.flowFrom):
        tl.loaded = false
        dw.breakThread(S, -1)
        return true
      if M != nil:
        status = "Click the box before it (or this one) to break the thread; Esc lets it go"
        return true
    else: discard
    if M != nil:
      tl.loaded = false
      if M == S: status = "The loaded text let go"
      else: dw.threadInto(S, M)
      return true
    # (where there is no box: one made -- dragged, or as the column there)
    tl.pressing = true
    tl.x0 = ev.x
    tl.y0 = ev.y
    tl.x1 = ev.x
    tl.y1 = ev.y
    return true
  # the ports of the picked box
  if tool != tMove or te.on or ev.right or not ev.pressed or dw.view.angle != 0: return false
  let L = d.current
  if not L.isFrame or not L.visible: return false
  let bw = bookOf(dw)
  let page = if bw != nil and bw.master == 0: bw.page else: -1
  if mouseIn(dw.outPort(L)):
    let (k, N) = dw.nextOf(L)
    if ev.clicks >= 2 and N != nil:
      dw.breakThread(N, k)
      return true
    tl = (true, dw, d, page, uidOf(L), (if N != nil: 1 else: 0), false, ev.x, ev.y, ev.x, ev.y)
    status = if N != nil: tr("Click \"") & N.name & tr("\" (or this port again) to break the thread -- or another box to ") &
                          tr("thread it in between; Esc lets it go")
             else: tr("Text loaded: click a box to thread it, or click (drag) where there is none for a new one; ") &
                   tr("in a book, turn to another page first to go on there. Esc lets it go")
    return true
  if mouseIn(dw.inPort(L)):
    if L.flowFrom == 0:
      status = "This box begins its story: nothing comes into it"
      return true
    if ev.clicks >= 2:
      dw.breakThread(L, -1)
      return true
    tl = (true, dw, d, page, uidOf(L), 2, false, ev.x, ev.y, ev.x, ev.y)
    status = "Click the box before it (or this port again) to break the thread; Esc lets it go"
    return true
  false

proc drawPort(r: Rect; threaded, overset: bool) =
  fill(r, color(255, 255, 255))
  box(r, color(0, 90, 220))
  if overset:
    let c = color(220, 0, 0)
    hline(r.x + 2, r.y + r.h div 2, r.w - 4, c)
    vline(r.x + r.w div 2, r.y + 2, r.h - 4, c)
  elif threaded:
    let c = color(0, 90, 220)
    for k in 0 .. (r.h - 4) div 2:
      vline(r.x + 2 + k, r.y + 2 + k, r.h - 4 - k * 2, c)

proc threadOverlay(dw: DocWin; ev: PhotoEvent) =
  ## The picked box's ports, its thread's lines, the loaded text's pointer.
  let d = dw.doc
  if dw.view.angle != 0: return
  let L = d.current
  if tool == tMove and not te.on and L.isFrame and L.visible:
    let (_, N) = dw.nextOf(L)
    # (overset or not: laid out again only when the text or the page changed)
    if tlOverset.layer != L or tlOverset.ver != L.ver or tlOverset.dver != d.ver:
      tlOverset = (L, L.ver, d.ver, layoutText(d.effectiveText(L)).overflow >= 0)
    let overset = tlOverset.overset
    box(dw.frameScreen(L), color(0, 90, 220))         # (its edges, as the layout program shows a frame picked)
    dw.inPort(L).drawPort(L.flowFrom != 0, false)
    dw.outPort(L).drawPort(N != nil or L.flowOut, overset and N == nil and not L.flowOut)
    if ev.over and mouseIn(dw.outPort(L)):
      ui.tip = if N != nil or L.flowOut: "Out port: threaded on -- click, then the next box, to break it"
               elif overset: "Out port: the text is overset -- click, then a box (or where there is none)"
               else: "Out port: click, then a box, to thread the text on into it"
    elif ev.over and mouseIn(dw.inPort(L)):
      ui.tip = if L.flowFrom != 0: "In port: threaded from another box -- click, then that box, to break it"
               else: "In port: the story begins here"
    # the thread's lines: from each box's out port to the next one's in port, on this page
    if showThreads and (L.flowFrom != 0 or N != nil):
      var B = d.storyHead(L)
      if B != L and B.visible: box(dw.frameScreen(B), color(120, 160, 230))
      var n = 0
      while n < 64:
        inc n
        let C = d.followerOf(B)
        if C == nil: break
        let a = dw.outPort(B)
        let b = dw.inPort(C)
        let col = color(0, 90, 220)
        line(a.x + a.w div 2, a.y + a.h div 2, b.x + b.w div 2, b.y + b.h div 2, col)
        line(a.x + a.w div 2, a.y + a.h div 2 + 1, b.x + b.w div 2, b.y + b.h div 2 + 1, col)
        if C != L and C.visible: box(dw.frameScreen(C), color(120, 160, 230))
        B = C
  if not tl.loaded or tl.dw != dw: return
  # the loaded text's pointer: a page of lines, a chain over a box it can go into (broken for
  # the end of a thread), the box being dragged
  if tl.pressing:
    let (a, b) = dw.view.toScreen(d, min(tl.x0, tl.x1), min(tl.y0, tl.y1))
    let (c, e) = dw.view.toScreen(d, max(tl.x0, tl.x1), max(tl.y0, tl.y1))
    box(rect(a, b, max(1, c - a), max(1, e - b)), color(0, 90, 220))
  if not ev.over: return
  let mx = ui.mx + dp(10)
  let my = ui.my + dp(10)
  let ic = rect(mx, my, dp(12), dp(14))
  fill(ic, color(255, 255, 255))
  box(ic, color(0, 0, 0))
  for k in 0 .. 2: hline(ic.x + dp(2), ic.y + dp(3) + k * dp(3), ic.w - dp(4), color(0, 0, 0))
  let M = d.frameAt(ev.x, ev.y)
  let S = tlSource()
  if M != nil and S != nil:
    let (_, N) = if tl.page < 0 or bookOf(dw) == nil or tl.page == bookOf(dw).page: dw.nextOf(S) else: (-1, nil)
    let breaks = (tl.mode == 1 and (M == N or M == S)) or (tl.mode == 2 and (M == S or M.uid == S.flowFrom))
    box(dw.frameScreen(M), if breaks: color(220, 0, 0) else: color(0, 90, 220), 2)
    let cx = ic.x + ic.w + dp(2)
    let cy = ic.y + dp(3)
    let c = if breaks: color(220, 0, 0) else: color(0, 90, 220)
    box(rect(cx, cy, dp(7), dp(5)), c)
    box(rect(cx + (if breaks: dp(9) else: dp(5)), cy + dp(3), dp(7), dp(5)), c)
    ui.tip = if breaks: tr("Click: the thread is broken here") elif M == S: "" else: tr("Click: the text goes on into \"") & M.name & "\""
  else:
    ui.tip = if tl.mode == 2: "Click the box before it to break the thread" else: "Click or drag: a new box that takes the text"
  ui.cursor = curArrow

# ---- Text Frame Options ---------------------------------------------------------------------------------

proc startTextFrameOptions() =
  let d = cur()
  if te.on: commitType()
  let L = if d != nil: d.current else: nil
  if d == nil or not L.isFrame:
    status = "Text Frame Options: pick a box of type (drag one with the Type tool)."
    return
  let ins = L.text.inset
  tfDlg = (true, L, max(1, L.text.columns), (if L.text.gutter > 0: L.text.gutter else: 12'f32),
           ord(L.text.autoSize), L.text.autoRef, ins, ord(L.text.vjust), L.text.balance, L.text.colRule)
  tfApplied = $(tfDlg.cols, tfDlg.gutter, tfDlg.auto, tfDlg.refPt, tfDlg.inset, tfDlg.vjust, tfDlg.balance,
                tfDlg.rule)
  tfPending = true
  d.beginStep("Text Frame Options")
  d.touchLayers()
  d.touch(L, d.bounds)

proc textFrameCommand(name: string): bool =
  result = true
  case name
  of "Text Frame Options...": startTextFrameOptions()
  of "Show Text Threads": showThreads = not showThreads
  else: result = false

proc textFrameDialog() =
  let d = cur()
  if not tfDlg.open:
    if tfPending:
      # (closed from outside: as Cancel)
      tfPending = false
      if d != nil and d.stepOpen:
        d.cancelStep()
        d.markAll()
    return
  if d == nil or tfDlg.layer notin d.layers:
    tfDlg.open = false
    return
  var ok, cancel = false
  dialog(tfDlg.open, "Text Frame Options", 450):
    row([130, 90, -1]):
      label "Columns:"
      spin(tfDlg.cols, 1, 12, w = dp(80))
      discard
    row([130, 90, -1]):
      label "Gutter:"
      discard d.lengthField(tfDlg.gutter, dp(80), 0, 4000)
      label unitShort()
    row([130, -1]):
      label ""
      checkbox("Balance Columns", tfDlg.balance)
    # (Column Rules: lines down the gutters)
    row([130, -1]):
      label ""
      checkbox("Column Rules", tfDlg.rule.on, enabled = tfDlg.cols > 1)
    if tfDlg.rule.on and tfDlg.cols > 1:
      row([130, 90, -1]):
        label "Rule weight:"
        discard d.lengthField(tfDlg.rule.width, dp(80), 0, 400)
        var c = if tfDlg.rule.color != 0: tfDlg.rule.color else: 0xFF000000'u32
        if colorWell(c, "colrule", dp(40)): tfDlg.rule.color = c or 0xFF000000'u32
      row([130, 90, 40, 90, -1]):
        label "Rule: from top"
        discard d.lengthField(tfDlg.rule.top, dp(80), 0, 20000)
        label "foot"
        discard d.lengthField(tfDlg.rule.bottom, dp(80), 0, 20000)
        label unitShort()
      row([130, -1]):
        label ""
        checkbox("Dashed", tfDlg.rule.dashed)
        checkbox("The box's height", tfDlg.rule.frameHeight)
    # (Inset Spacing: room kept inside the box's sides)
    row([130, 90, 40, 90, -1]):
      label "Inset: top"
      discard d.lengthField(tfDlg.inset[0], dp(80), 0, 4000)
      label "left"
      discard d.lengthField(tfDlg.inset[3], dp(80), 0, 4000)
      label unitShort()
    row([130, 90, 40, 90, -1]):
      label "bottom"
      discard d.lengthField(tfDlg.inset[2], dp(80), 0, 4000)
      label "right"
      discard d.lengthField(tfDlg.inset[1], dp(80), 0, 4000)
      label unitShort()
    row([130, -1]):
      label "Vertical Justification:"
      var vn: seq[string]
      for v in VertJust: vn.add tr($v)
      combo(vn, tfDlg.vjust, w = dp(120))
    row([130, -1]):
      label "Auto-Size:"
      var names: seq[string]
      for a in TextAutoSize: names.add tr($a)
      combo(names, tfDlg.auto, w = dp(250))
    if tfDlg.auto != 0:
      row([130, -1]):
        label "Reference point:"
        # (the nine points of the box, as the layout program's proxy: the one that stays)
        let s = dp(14)
        let g = dp(6)
        let r = place(3 * s + 2 * g, 3 * s + 2 * g)
        for k in 0 .. 8:
          let cell = rect(r.x + (k mod 3) * (s + g), r.y + (k div 3) * (s + g), s, s)
          let on = k == tfDlg.refPt
          fill(cell, if on: ui.theme.text else: ui.theme.window)
          box(cell, ui.theme.text)
          if mouseIn(cell) and ui.pressed: tfDlg.refPt = k
      paragraph(case TextAutoSize(tfDlg.auto)
                of asHeight: "The box as tall as its text: taller as it grows, shorter as it shrinks."
                of asWidth: "The box as wide as its longest line: lines break only where they end."
                of asBoth: "The box as wide as its longest line and as tall as its lines."
                of asProportional: "The box as small as holds its text, in the shape it has."
                else: "", color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): cancel = true
  let L = tfDlg.layer
  let key = $(tfDlg.cols, tfDlg.gutter, tfDlg.auto, tfDlg.refPt, tfDlg.inset, tfDlg.vjust, tfDlg.balance,
              tfDlg.rule)
  if key != tfApplied and not cancel:
    tfApplied = key
    var t = L.text
    t.columns = tfDlg.cols
    t.gutter = max(0.01'f32, tfDlg.gutter)
    t.autoSize = TextAutoSize(tfDlg.auto)
    t.autoRef = tfDlg.refPt
    for q in 0 .. 3: t.inset[q] = tfDlg.inset[q]
    t.vjust = VertJust(clamp(tfDlg.vjust, 0, ord(high(VertJust))))
    t.balance = tfDlg.balance
    t.colRule = tfDlg.rule
    d.setText(L, t)
  if ok:
    tfDlg.open = false
    tfPending = false
    if d.stepOpen: d.endStep()
  elif cancel:
    tfDlg.open = false
    tfPending = false
    if d.stepOpen:
      d.cancelStep()
      d.markAll()
