## A program run without a window: its frames drawn into memory, no input
## but what it is given -- for the command line (a batch of files changed
## and saved), a server, a script, and tests.
##
## - `useHeadless`: the drivers that draw into memory and wait for nothing
##   (call it before `startApp`).
## - `headlessPixels`, `headlessShot`: what the last frame drew.
## - `headlessInput`: an event given to the program, as a person would.
##
## .. code-block:: nim
##   import retroui, retroui/headless
##   useHeadless(1280, 800)
##   startApp("Batch", 1280, 800)
##   for i in 0 ..< 3:
##     discard beginFrame()
##     myFrame()
##     endFrame()
##   stopApp()
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import uirelays/[coords, screen, input]
import gfx

var
  headlessPixels*: seq[uint32]   ## the window that is not there: what was drawn last
  headlessW, headlessH: int
  headlessQueue: seq[Event]
  headlessTicks = 1000
  headlessClip = ""

proc useHeadless*(w = 1280; h = 800) =
  ## The program's window kept in memory, `w` x `h`: nothing shown, no input but
  ## `headlessInput`, its clock moving on a frame (16 ms) each time it is asked.
  headlessW = max(1, w)
  headlessH = max(1, h)
  headlessPixels = newSeq[uint32](headlessW * headlessH)
  windowRelays.createWindow = proc (l: var ScreenLayout; icon: pointer; iconLen: int) =
    l.width = headlessW; l.height = headlessH; l.scaleX = 1; l.scaleY = 1; l.uiScale = 100
  windowRelays.getWindowLayout = proc (): ScreenLayout =
    ScreenLayout(width: headlessW, height: headlessH, scaleX: 1, scaleY: 1, uiScale: 100)
  windowRelays.refresh = proc () = discard
  windowRelays.setWindowTitle = proc (t: string) = discard
  windowRelays.setCursor = proc (c: CursorKind) = discard
  drawRelays.blitRGBA = proc (p: ptr UncheckedArray[uint32]; w, h: int; dst: Rect; f: RGBAFormat): bool =
    for y in 0 ..< h:
      let ty = dst.y + y
      if ty < 0 or ty >= headlessH: continue
      for x in 0 ..< w:
        let tx = dst.x + x
        if tx >= 0 and tx < headlessW: headlessPixels[ty * headlessW + tx] = p[y * w + x]
    true
  inputRelays.pollEvent = proc (e: var Event; fl: set[InputFlag]): bool =
    if headlessQueue.len == 0: return false
    e = headlessQueue[0]
    headlessQueue.delete(0)
    true
  inputRelays.waitEvent = proc (e: var Event; t: int; fl: set[InputFlag]): bool =
    headlessTicks += max(1, min(t, 16))
    inputRelays.pollEvent(e, fl)
  inputRelays.getTicks = proc (): int =
    headlessTicks += 1
    headlessTicks
  inputRelays.shutdown = proc () = discard
  clipboardRelays.getText = proc (): string = headlessClip
  clipboardRelays.putText = proc (t: string) = headlessClip = t
  # (no system fonts: the built-in ones draw everything)
  fontRelays.openFont = proc (path: string; size: int; style: FontStyles; metrics: var FontMetrics): Font = Font(0)
  fontRelays.closeFont = proc (f: Font) = discard
  fontRelays.getFontMetrics = proc (f: Font): FontMetrics = FontMetrics()
  fontRelays.measureText = proc (f: Font; text: string): TextExtent = TextExtent()
  fontRelays.drawText = proc (f: Font; x, y: int; text: string; fg, bg: Color): TextExtent = TextExtent()
  fontRelays.drawMeasuredText = nil

proc headlessInput*(e: Event) =
  ## `e` given to the program (it gets it in its next frame).
  headlessQueue.add e

proc headlessShot*(): Bitmap =
  ## What the last frame drew, as a picture.
  result = newBitmap(headlessW, headlessH)
  for i in 0 ..< headlessPixels.len: result.px[i] = headlessPixels[i] or 0xFF000000'u32
