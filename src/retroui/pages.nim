## Pages one over another, as phones go through an app (Qt's StackView,
## Flutter's Navigator, SwiftUI's NavigationStack): a page opens over the
## one before and Back goes back to it -- the phone's Back button, Esc,
## Alt+Left, or `pageHeader`'s Back -- each new page sliding in. And a list
## beside the details of what is picked in it (`listDetail`): side by side
## where there is room, one at a time on a phone.
##
## .. code-block:: nim
##   var nav = initPages("inbox")
##   var picked = -1
##
##   app "Mail", 400, 500:
##     pageView(nav):                     # the page on top, in the room left
##       case nav.page
##       of "inbox":
##         pageHeader(nav, "Inbox")
##         if button("Open the first"): picked = 0; nav.push("message")
##       of "message":
##         pageHeader(nav, "Message")        # with Back
##         label "Message " & $picked
##
## Pages are names (strings), so `case nav.page` reads as the app's map.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import gfx, core, widgets, desktop, pixelicons

type PageStack* = object
  ## The pages open, the first the home page, the last the one shown.
  pages*: seq[string]
  slide: int                  # (1: one opened, from the right; -1: one closed)
  t0: int

const SlideMs = 220

proc initPages*(home: string): PageStack =
  ## A stack with its home page alone.
  PageStack(pages: @[home])

proc page*(p: PageStack): string =
  ## The page shown ("" when none).
  if p.pages.len > 0: p.pages[^1] else: ""

proc atHome*(p: PageStack): bool = p.pages.len <= 1
  ## Only the home page is open: Back has nowhere to go.

proc push*(p: var PageStack; name: string) =
  ## Opens page `name` over the one shown (it slides in from the right).
  p.pages.add name
  p.slide = 1
  p.t0 = ui.now
  ui.redraw = true

proc pop*(p: var PageStack): bool {.discardable.} =
  ## Back to the page before (it slides in from the left); false at home.
  if p.pages.len <= 1: return false
  p.pages.setLen(p.pages.len - 1)
  p.slide = -1
  p.t0 = ui.now
  ui.redraw = true
  true

proc goHome*(p: var PageStack) =
  ## Back to the home page, the others closed.
  if p.pages.len > 1:
    p.pages.setLen(1)
    p.slide = -1
    p.t0 = ui.now
    ui.redraw = true

proc pageOffset*(p: var PageStack; width: int): int =
  ## (how far the page shown is from its place now, sliding in: 0 once it
  ## is there, or at once when the user asked for less movement)
  if p.slide == 0 or not smoothScrolling: return 0
  let d = ui.now - p.t0
  if d >= SlideMs:
    p.slide = 0
    return 0
  wakeIn(16)
  let t = 1.0 - d / SlideMs
  let left = t * t * t                      # (fast, then slowing)
  if p.slide > 0: int(width.float * left) else: -int(width.float * 0.3 * left)

proc pageBackKeys*(p: var PageStack) =
  ## (Back: the phone's button, Esc, Alt+Left -- one page back)
  if p.atHome: return
  if backPressed():
    cancelClose()
    p.pop()
  elif canInput() and not ui.keyUsed and ui.popup == 0 and ui.dialogTop == 0 and
       (keyHit(KeyEsc) or hotkeyPressed("Alt+Left")):
    ui.keyUsed = true
    p.pop()

template pageView*(p: var PageStack; height: int; body: untyped) =
  ## The page on top, drawn by `body` (`case p.page`) in `height` pixels
  ## (-1: the room left), sliding in when it changed; Back goes back a
  ## page. A page longer than that scrolls in a `scrollPanel` of its own.
  block:
    let pr = place(0, (if height < 0: remainingH() else: height), fill = true)
    let dx = pageOffset(p, pr.w)
    pushClip(pr)
    beginClipped()                          # (sliding in, it never makes the window scroll)
    pushFrame(rect(pr.x + dx, pr.y, pr.w, pr.h))
    body
    discard popFrame()
    endClipped()
    popClip()
    pageBackKeys(p)

template pageView*(p: var PageStack; body: untyped) =
  ## The page on top in the room left (see the other `pageView`).
  pageView(p, -1, body)

proc pageHeader*(p: var PageStack; title: string) =
  ## The page's title, bold, with a Back button before it when there is a
  ## page to go back to.
  row:
    if not p.atHome:
      if button(tr("&Back"), pxBack): p.pop()
    label title, bold = true

template listDetail*(showDetail: var bool; listW: int; list, detail: untyped) =
  ## A list beside the details of what is picked in it: side by side,
  ## the list `listW` wide, where the window has room (`sizeClass` medium
  ## or wide); on a phone the list alone, then the details over it while
  ## `showDetail` is true, with a Back (and the phone's Back) that brings
  ## the list back.
  if sizeClass() == scCompact:
    if showDetail:
      row:
        if button(tr("&Back"), pxBack): showDetail = false
      detail
      if backPressed():
        cancelClose()
        showDetail = false
    else:
      list
  else:
    row([listW, -1]):
      col:
        list
      col:
        detail
