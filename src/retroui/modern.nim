## The newer parts of phones' and desktops' interfaces, in every look: a page's large title that
## gives way to the bar's as it scrolls, gray placeholders while content loads, an item lifted
## out of the page with its menu under it (a long press), a page growing out of the card that
## opened it.
##
## ```nim
## discard navBar("Library")                    # (its title shows once the large one has gone)
## beginPanel(-1, "lib", plain = true)
## largeTitle "Library"
## if loading: skeletonRows(6)
## else:
##   for a in albums:
##     let hit = tableRow(a.name)
##     case liftMenu(ui.lastRect, a.name, ["Play", "Add to Queue", "Delete"], destructive = 2)
##     of 0: play(a)
##     else: discard
## endPanel()
## ```
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[tables, math]
import uirelays/input
import gfx, core, widgets

template th: untyped = ui.theme
const black = color(0, 0, 0)
const white = color(255, 255, 255)
proc onDark(): bool {.inline.} = (int(th.window.r) * 77 + int(th.window.g) * 151 + int(th.window.b) * 28) shr 8 < 128

# ---- the large title ----------------------------------------------------------------------------

var largeSeen*: tuple[title: string; frame: int; shown: bool]
  ## (the large title drawn last: its words, the frame, whether it was out from under the bars --
  ## `navBar` leaves its own title out while it is)

proc largeTitle*(title: string; subtitle = "") =
  ## A page's title in large bold letters at the top of its content, as phones' pages have it
  ## (`subtitle`: a gray line under it -- a count, a date). It scrolls with the content; once it
  ## has gone up under the bars, the `navBar` of the same title shows its title, small, in its
  ## middle -- until then it leaves it out, the large one saying it. Put it first in the page's
  ## panel.
  let st = style(bold = true, size = 2.0)
  let sst = style(size = 1.0)
  let h = lineHeight(st) + (if subtitle.len > 0: lineHeight(sst) else: 0) + dp(6)
  let r = place(0, h, fill = true)
  let tx = r.x + (if glassLook(): dp(6) else: 0)
  text(tx, r.y + dp(2), tr(title), th.text, st)
  if subtitle.len > 0: text(tx, r.y + dp(2) + lineHeight(st), tr(subtitle), th.gray, sst)
  # (out from under the bars when its words' middle is below their foot)
  let barsFoot = if glassBand.frame >= ui.frameNo - 1: glassBand.r.y + glassBand.r.h else: ui.barY
  let shown = r.y + lineHeight(st) div 2 > barsFoot and clipRect().contains(point(r.x + 1, r.y + lineHeight(st) div 2))
  if largeSeen.title != title or largeSeen.shown != shown: ui.redraw = true
  largeSeen = (title, ui.frameNo, shown)
  if accessOn: accessNode(arHeading, title, r = r)

proc largeTitleShown*(title: string): bool =
  ## The `largeTitle` of these words is on the screen, out from under the bars (last frame): the
  ## bar's own title is left out meanwhile (`navBar` does it by itself).
  largeSeen.title == title and largeSeen.frame >= ui.frameNo - 1 and largeSeen.shown

# ---- placeholders while content loads -----------------------------------------------------------

proc skeletonFace(r: Rect; radius: float) =
  ## (a gray placeholder; a band of light sweeping across it, unless motion is reduced)
  let base = mixColor(th.window, th.text, if onDark(): 0.14 else: 0.09)
  roundRect(r, radius, base)
  if not smoothScrolling or r.w <= 0: return
  let period = 1400
  let t = float(ui.now mod period) / float(period)
  let bw = max(dp(40), ui.w div 4)
  let x = ui.winX - bw + int(float(ui.w + 2 * bw) * t)
  pushClip(r)
  for k in 0 ..< bw:
    let a = int(46.0 * sin(PI * float(k) / float(bw)))
    if a > 0 and x + k >= r.x and x + k < r.x + r.w:
      vline(x + k, r.y, r.h, withAlpha(th.window, a))
  popClip()
  wakeInShown(r, 33)

proc skeletonBlock*(w, h: int; round = false) =
  ## A gray placeholder `w` x `h` where content is still coming (0 `w`: the row's width), a light
  ## sweeping over it: a picture, a paragraph, a button. `round`: a circle (a face).
  let r = place(w, h, fill = w <= 0)
  skeletonFace(r, if round: float(min(r.w, r.h)) / 2 else: float(dp(6)))
  if accessOn: accessNode(arProgressBar, tr("Loading"), r = r)

proc skeletonRows*(count: int; lines = 2; picture = true) =
  ## `count` placeholder rows while a list loads -- a square for its picture (`picture`) and
  ## `lines` gray bars of words, the last shorter --, where the rows will be: the page has its
  ## shape at once, and nothing jumps when they come. Show it only while the content is late
  ## (not for what comes at once), and the real rows in its place.
  for i in 0 ..< count:
    let rowH = max(dp(44), lines * (FontH + dp(6)) + dp(12))
    let r = place(0, rowH, fill = true)
    var x = r.x + dp(8)
    if picture:
      let d = rowH - dp(14)
      skeletonFace(rect(x, r.y + dp(7), d, d), float(dp(8)))
      x += d + dp(12)
    let room = r.x + r.w - dp(8) - x
    let lh = FontH - dp(2)
    let top = r.y + (rowH - lines * (lh + dp(6)) + dp(6)) div 2
    for l in 0 ..< lines:
      let w = if l == lines - 1 and lines > 1: room * (55 + (i * 13) mod 30) div 100 else: room * (80 + (i * 7) mod 20) div 100
      skeletonFace(rect(x, top + l * (lh + dp(6)), w, lh), float(lh) / 2)
  if accessOn: accessNode(arProgressBar, tr("Loading"), r = rect(0, 0, 0, 0))

# ---- an item lifted with its menu ---------------------------------------------------------------

var lifting: tuple[key: string; r: Rect; at: int; hi: int]   # (the item lifted, where, since when)

proc liftMenu*(r: Rect; key: string; actions: openArray[string]; destructive = -1): int =
  ## A menu for the item drawn at `r` (call it after the item; `key` tells the items apart): a
  ## finger held on it -- or a right click -- lifts it out of the page, a little bigger, with its
  ## shadow, the rest dimmed and blurred behind it, and its actions in a card of glass under it
  ## (over it, near the foot of the screen); the `destructive` one in red. Returns the action
  ## tapped, once (the menu closing); -1 meanwhile, or when a tap beside it closed it. The same
  ## actions as the item's swipe ones, first, as the guide asks.
  result = -1
  if lifting.key.len == 0 and canInput() and r.contains(point(ui.mx, ui.my)) and
     clipRect().contains(point(ui.mx, ui.my)):
    if (ui.touch and longPressed() and ui.mouseDown) or ui.rpressed:
      lifting = (key, intersect(r, clipRect()), ui.now, -1)
      ui.redraw = true
      if ui.rpressed: ui.rpressed = false
  if lifting.key != key: return
  # (modal while it is up, as a dialog: the page under it takes nothing)
  let lid = idOf("liftmenu:" & key)
  let wasDialog = ui.curDialog
  ui.curDialog = lid
  ui.dialogTopNow = lid
  pushLayer(LayerDialog)
  defer:
    popLayer()
    ui.curDialog = wasDialog
  let t = if smoothScrolling: clamp(float(ui.now - lifting.at) / 180.0, 0.0, 1.0) else: 1.0
  if t < 1: wakeIn(16)
  let e = 1 - (1 - t) * (1 - t)
  let lr = lifting.r
  let grow = int(float(dp(6)) * e)
  let item = rect(lr.x - grow, lr.y - grow, lr.w + 2 * grow, lr.h + 2 * grow)
  # (the page round it dimmed and blurred; the item itself as it is, lifted)
  let top0 = if ui.winY == 0: ui.captionH else: ui.winY     # (under the kit's own title bar)
  let room = rect(ui.winX, top0, ui.w, ui.h - top0)
  let dim = withAlpha(black, int(90.0 * e))
  for part in [rect(room.x, room.y, room.w, item.y - room.y),
               rect(room.x, item.y + item.h, room.w, room.y + room.h - item.y - item.h),
               rect(room.x, item.y, item.x - room.x, item.h),
               rect(item.x + item.w, item.y, room.x + room.w - item.x - item.w, item.h)]:
    if part.w > 0 and part.h > 0:
      if not glassSolid: backdropBlur(part, max(1, int(float(dp(6)) * e)), dim, 0)
      else: fill(part, dim)
  softShadow(item, float(dp(12)), max(1, int(10.0 * e)))
  roundFrame(item, float(dp(12)), 1, withAlpha(white, 120))
  # (its actions in a card under it, or over it when there is no room under)
  let rowH = if fingers(): dp(44) else: CtrlH + dp(8)
  let mw = min(max(dp(220), item.w div 2), room.w - 2 * dp(12))
  let mh = actions.len * rowH
  var my = item.y + item.h + dp(10)
  if my + mh > room.y + room.h - dp(12): my = max(room.y + dp(12), item.y - dp(10) - mh)
  let mx = clamp(item.x, room.x + dp(12), room.x + room.w - mw - dp(12))
  let mr = rect(mx, my + int(float(dp(10)) * (1 - e)), mw, mh)
  if glassFx(): glassSurface(mr, float(dp(14)), th.field, lift = 8)
  elif not frostedFace(mr, th.window, float(dp(10))):
    softShadow(mr, float(dp(10)), 6)
    roundRect(mr, float(dp(10)), th.window)
  for i, a in actions:
    let ar = rect(mr.x, mr.y + i * rowH, mr.w, rowH)
    let id = idOf("liftmenu:" & key & ":" & $i)
    let hit = interact(id, ar, focusable = false)
    if hit.down or hit.hover and canHover(): roundRect(inset(ar, dp(3)), float(dp(8)), withAlpha(th.text, 18))
    if i > 0: hline(ar.x + dp(12), ar.y, ar.w - dp(24), withAlpha(th.text, 28))
    text(ar.x + dp(16), ar.y + (rowH - FontH) div 2, tr(a), if i == destructive: color(225, 45, 40) else: th.text)
    if accessOn: accessNode(arMenuItem, a, id = id, r = ar)
    if hit.clicked:
      result = i
      lifting = ("", Rect(), 0, -1)
      ui.redraw = true
  # (a tap beside it, Esc, Back: closed)
  if result < 0 and lifting.key.len > 0 and canInput():
    if ui.pressed and not mr.contains(point(ui.mx, ui.my)) and ui.now - lifting.at > 250:
      lifting = ("", Rect(), 0, -1)
      ui.redraw = true
      discard takePress()
    elif keyHit(KeyEsc):
      lifting = ("", Rect(), 0, -1)

proc liftedItem*(): string = lifting.key
  ## The `key` of the item lifted with its menu now ("" none).

# ---- a page growing out of its card -------------------------------------------------------------

var growSeen: Table[string, tuple[frame, at: int]]
var growStack: seq[tuple[mark: int; key: string; src: Rect; layer: int]]

proc beginGrow*(key: string; src: Rect) =
  ## Starts what grows out of `src` (see `growing`).
  growStack.add (cmdMark(), key, src, layer())

proc endGrow*() =
  ## Ends a `beginGrow`: what was drawn since shows only inside a box growing from the card to
  ## the whole window over a quarter of a second, the first frames it is drawn.
  if growStack.len == 0: return
  let g = growStack.pop()
  let seen = growSeen.getOrDefault(g.key, (-10, 0))
  let at = if seen.frame < ui.frameNo - 1: ui.now else: seen.at
  growSeen[g.key] = (ui.frameNo, at)
  if growSeen.len > 32: growSeen.clear()
  if not smoothScrolling or layer() != g.layer or g.src.w <= 0: return
  let t = float(ui.now - at) / 260.0
  if t >= 1: return
  let e = 1 - (1 - t) * (1 - t) * (1 - t)
  let full = rect(ui.winX, ui.winY, ui.w, ui.h - ui.winY)
  template mixI(a, b: int): int = a + int(float(b - a) * e)
  let r = rect(mixI(g.src.x, full.x), mixI(g.src.y, full.y), mixI(g.src.w, full.w), mixI(g.src.h, full.h))
  clipSpan(g.mark, cmdMark(), r)
  wakeIn(16)

template growing*(key: string; src: Rect; body: untyped) =
  ## A page (or a panel) that grows out of the card that opened it, `src` -- the card's
  ## `ui.lastRect` kept when it was tapped -- to the whole window as it first shows, as a phone's
  ## album opens out of its cover. `key` tells pages apart (the album's id). Draw the page in
  ## `body` as always; with motion reduced it is simply there.
  beginGrow(key, src)
  try:
    body
  finally:
    endGrow()
