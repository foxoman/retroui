## A scanner: the camera's picture with a guide in its middle, reading the QR codes and barcodes
## that come into it (retroui/qrcode's `qrRead`, retroui/barcode's `barcodeRead`) on a worker a
## few times a second, as a phone's camera app reads them -- what was read handed back once, a
## tap felt, the guide lit.
##
## ```nim
## let got = scannerView()
## if got.text.len > 0: openUrl(got.text)
## ```
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[tables]
import gfx, core, capture, qrcode, barcode, jobs, system

type ScanResult* = object
  ## A code read by `scannerView`.
  qr*: bool                ## a QR code (else a barcode of `kind`)
  kind*: BarcodeKind
  text*: string            ## what it says ("": nothing read this frame)

type ScanState = ref object
  work: Job[ScanResult]
  startedAt, lastAt, litAt: int
  last: string

var scans: Table[string, ScanState]

proc shrunk(b: Bitmap; most: int): Bitmap =
  ## (a copy at most `most` pixels across: quicker to read, and the camera's own frame let be)
  let k = max(1, (max(b.w, b.h) + most - 1) div most)
  result = newBitmap(b.w div k, b.h div k)
  for y in 0 ..< result.h:
    for x in 0 ..< result.w: result.px[y * result.w + x] = b.px[(y * k) * b.w + x * k]

proc readCodes(b: Bitmap; qr: bool; kinds: set[BarcodeKind]): ScanResult =
  if qr:
    let q = qrRead(b, most = 1)
    if q.len > 0: return ScanResult(qr: true, text: q[0].text)
  if kinds.len > 0:
    let r = barcodeRead(b, kinds)
    if r.len > 0: return ScanResult(kind: r[0].kind, text: r[0].text)

proc scannerView*(key = ""; height = -1; qr = true;
                  barcodes: set[BarcodeKind] = {BarcodeKind.low .. BarcodeKind.high};
                  facing = cfBack; every = 250): ScanResult =
  ## The camera's picture (`cameraView`), `height` pixels high (-1: the room left), a guide in its
  ## middle; its frames read every `every` ms on a worker for QR codes (`qr`) and the `barcodes`
  ## asked. Returns a code the frame it is read -- once: the same code again only after three
  ## seconds away --, with a tap felt (`haptic`) and the guide lit green a moment.
  let st = scans.mgetOrPut(key, ScanState())
  cameraView("scan:" & key, facing = facing, height = height)
  let r = ui.lastRect
  let f = cameraFrame("scan:" & key)
  if st.work != nil and st.work.done:
    let got = st.work.value
    st.work = nil
    if got.text.len > 0:
      if got.text != st.last or ui.now - st.lastAt > 3000:
        result = got
        haptic(hSuccess)
        st.litAt = ui.now
      st.last = got.text
      st.lastAt = ui.now
  if st.work == nil and f != nil and ui.now - st.startedAt >= every:
    st.startedAt = ui.now
    let pic = shrunk(f, 900)
    let wantQr = qr
    let kinds = barcodes
    st.work = job(proc (): ScanResult {.gcsafe.} = readCodes(pic, wantQr, kinds))
  wakeIn(every)
  # the guide: its corners, white -- green a moment after a code is read
  let side = min(r.w, r.h) * 3 div 5
  let g = rect(r.x + (r.w - side) div 2, r.y + (r.h - side) div 2, side, side)
  let lit = ui.now - st.litAt < 700
  let c = if lit: color(60, 220, 110) else: color(255, 255, 255)
  let k = max(dp(18), side div 6)
  let t = max(dp(3), 3)
  for (cx, cy, sx, sy) in [(g.x, g.y, 1, 1), (g.x + g.w, g.y, -1, 1), (g.x, g.y + g.h, 1, -1),
                           (g.x + g.w, g.y + g.h, -1, -1)]:
    fill(rect(min(cx, cx + sx * k), (if sy > 0: cy else: cy - t), k, t), c)
    fill(rect((if sx > 0: cx else: cx - t), min(cy, cy + sy * k), t, k), c)
  if lit: wakeIn(50)
