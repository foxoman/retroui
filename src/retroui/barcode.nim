## Barcodes, the lines of a shop's goods, a parcel's, a ticket's: EAN-13 (and UPC-A, its North
## American twin), EAN-8, Code 128 and Code 39 -- made (`barcodeModules`, `barcodeBitmap`) and
## read from a picture (`barcodeRead`), a camera's or a scan's, the code across it or turned a
## quarter, upside down too. With `qrRead` (retroui/qrcode) a scanner reads what a phone's does;
## `scannerView` (retroui/capture) does both from the camera.
##
## ```nim
## let pic = barcodeBitmap(bcEan13, "4006381333931")
## for r in barcodeRead(pic): echo r.kind, " ", r.text
## ```
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils]
import gfx

type
  BarcodeKind* = enum
    ## The kinds of barcode made and read.
    bcEan13,      ## 13 digits, its last the check (books, goods everywhere but North America)
    bcUpcA,       ## 12 digits (North America's goods): EAN-13 with a 0 before
    bcEan8,       ## 8 digits (small packets)
    bcCode128,    ## any text of the first 128 characters (parcels, tickets)
    bcCode39      ## digits, capitals, space and -.$/+% (labels, older systems)

  BarcodeRead* = object
    ## A barcode read from a picture (`barcodeRead`).
    kind*: BarcodeKind
    text*: string
    row*: int         ## the row of the picture it was read along (in its turn)
    turned*: int      ## how far the picture was turned to read it: 0, 90, 180, 270

const
  eanL = ["3211", "2221", "2122", "1411", "1132", "1231", "1114", "1312", "1213", "3112"]
  eanFirst = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG", "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL"]
  c128 = ["212222", "222122", "222221", "121223", "121322", "131222", "122213", "122312", "132212", "221213",
          "221312", "231212", "112232", "122132", "122231", "113222", "123122", "123221", "223211", "221132",
          "221231", "213212", "223112", "312131", "311222", "321122", "321221", "312212", "322112", "322211",
          "212123", "212321", "232121", "111323", "131123", "131321", "112313", "132113", "132311", "211313",
          "231113", "231311", "112133", "112331", "132131", "113123", "113321", "133121", "313121", "211331",
          "231131", "213113", "213311", "213131", "311123", "311321", "331121", "312113", "312311", "332111",
          "314111", "221411", "431111", "111224", "111422", "121124", "121421", "141122", "141221", "112214",
          "112412", "122114", "122411", "142112", "142211", "241211", "221114", "413111", "241112", "134111",
          "111242", "121142", "121241", "114212", "124112", "124211", "411212", "421112", "421211", "212141",
          "214121", "412121", "111143", "111341", "131141", "114113", "114311", "411113", "411311", "113141",
          "114131", "311141", "411131", "211412", "211214", "211232"]
  c128Stop = "2331112"
  c39Chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-. *$/+%"
  c39 = [0x034, 0x121, 0x061, 0x160, 0x031, 0x130, 0x070, 0x025, 0x124, 0x064,
         0x109, 0x049, 0x148, 0x019, 0x118, 0x058, 0x00D, 0x10C, 0x04C, 0x01C,
         0x103, 0x043, 0x142, 0x013, 0x112, 0x052, 0x007, 0x106, 0x046, 0x016,
         0x181, 0x0C1, 0x1C0, 0x091, 0x190, 0x0D0, 0x085, 0x184, 0x0C4, 0x094,
         0x0A8, 0x0A2, 0x08A, 0x02A]

proc eanCheck(digits: string): int =
  ## (the check digit of the digits before it)
  var s = 0
  for i, c in digits:
    let d = ord(c) - ord('0')
    s += (if (digits.len - i) mod 2 == 1: 3 * d else: d)
  (10 - s mod 10) mod 10

proc runsTo(runs: string; dark: var seq[bool]; startDark = true) =
  var d = startDark
  for c in runs:
    for i in 0 ..< ord(c) - ord('0'): dark.add d
    d = not d

proc barcodeModules*(kind: BarcodeKind; text: string): seq[bool] =
  ## The modules of the barcode of `text` (true: a bar), quiet zones not included; empty when
  ## `text` can't be written so. EAN and UPC take their digits without the check (it is added) or
  ## with it (it is checked).
  case kind
  of bcEan13, bcUpcA, bcEan8:
    var t = text.strip
    if kind == bcUpcA: t = "0" & t
    let n = if kind == bcEan8: 8 else: 13
    for c in t:
      if c notin Digits: return
    if t.len == n - 1: t.add char(ord('0') + eanCheck(t))
    if t.len != n or eanCheck(t[0 ..< n - 1]) != ord(t[^1]) - ord('0'): return
    runsTo("111", result)
    let half = if n == 13: 6 else: 4
    let left = if n == 13: t[1 .. 6] else: t[0 .. 3]
    let right = if n == 13: t[7 .. 12] else: t[4 .. 7]
    for i, c in left:
      let d = ord(c) - ord('0')
      var w = eanL[d]
      if n == 13 and eanFirst[ord(t[0]) - ord('0')][i] == 'G':
        w = w[3] & w[2] & w[1] & w[0]
      runsTo(w, result, startDark = false)
    runsTo("11111", result, startDark = false)
    for c in right: runsTo(eanL[ord(c) - ord('0')], result)
    runsTo("111", result)
    discard half
  of bcCode128:
    # (code set C for runs of four digits or more, B for the rest; a control character by
    # the shift to set A)
    for c in text:
      if ord(c) > 127: return
    proc digitsAt(j: int): int =
      var k = j
      while k < text.len and text[k] in Digits: inc k
      k - j
    var vals: seq[int]
    var i = 0
    var inC = false
    if text.len >= 2 and digitsAt(0) == text.len and text.len mod 2 == 0:
      vals.add 105
      inC = true
    else: vals.add 104
    while i < text.len:
      if inC:
        vals.add (ord(text[i]) - ord('0')) * 10 + ord(text[i + 1]) - ord('0')
        i += 2
        if i < text.len and digitsAt(i) < 2:
          vals.add 100                   # (back to set B)
          inC = false
        continue
      let run = digitsAt(i)
      if run >= 4:
        if run mod 2 == 1:
          vals.add ord(text[i]) - 32     # (an odd run: its first digit in B)
          inc i
        vals.add 99                      # (to set C)
        inC = true
        continue
      let c = text[i]
      if ord(c) < 32:
        vals.add 98                      # (shift: one character of set A)
        vals.add ord(c) + 64
      else: vals.add ord(c) - 32
      inc i
    var sum = vals[0]
    for k in 1 ..< vals.len: sum += k * vals[k]
    vals.add sum mod 103
    for v in vals: runsTo(c128[v], result)
    runsTo(c128Stop, result)
  of bcCode39:
    let t = "*" & text.toUpperAscii & "*"
    for k, c in t:
      let i = c39Chars.find(c)
      if i < 0 or (c == '*' and k != 0 and k != t.high): return
      let bits = c39[i]
      for e in 0 ..< 9:
        let wide = ((bits shr (8 - e)) and 1) == 1
        for m in 0 ..< (if wide: 3 else: 1): result.add e mod 2 == 0
      if k < t.high: result.add false        # (the gap between characters)

proc barcodeBitmap*(kind: BarcodeKind; text: string; module = 3; height = 80; quiet = 10;
                    dark = color(0, 0, 0); light = color(255, 255, 255)): Bitmap =
  ## A picture of the barcode of `text`, `module` pixels a module, `height` high, `quiet` modules
  ## of light either side (nil when `text` can't be written so).
  let m = barcodeModules(kind, text)
  if m.len == 0: return nil
  let w = (m.len + 2 * quiet) * module
  result = newBitmap(w, height, 0xFF000000'u32 or (uint32(light.r) shl 16) or (uint32(light.g) shl 8) or light.b)
  let d = 0xFF000000'u32 or (uint32(dark.r) shl 16) or (uint32(dark.g) shl 8) or dark.b
  for i, b in m:
    if b:
      for y in 0 ..< height:
        for k in 0 ..< module: result.px[y * w + (quiet + i) * module + k] = d

# ---- reading ------------------------------------------------------------------------------------

proc match(runs: openArray[int]; at: int; pattern: string; unit: float): float =
  ## (how far the runs at `at` are from the widths of `pattern`, in modules: 0 a perfect fit)
  for k, c in pattern:
    result += abs(runs[at + k].float / unit - float(ord(c) - ord('0')))

proc unitOf(runs: openArray[int]; at, count, modules: int): float =
  var s = 0
  for k in 0 ..< count: s += runs[at + k]
  s / modules

proc readEan(runs: seq[int]; firstDark: bool; res: var seq[(BarcodeKind, string)]) =
  ## (EAN-13 / UPC-A / EAN-8 along a row's runs: a start guard of three runs, digits of four runs,
  ## the middle guard of five, the end guard)
  let start = if firstDark: 0 else: 1
  for n in [13, 8]:
    let half = if n == 13: 6 else: 4
    let total = 3 + 4 * half + 5 + 4 * half + 3
    var s = start
    while s + total <= runs.len:
      let unit = unitOf(runs, s, total, (if n == 13: 95 else: 67))
      if unit >= 1.0 and match(runs, s, "111", unit) < 1.2 and
         (s == 0 or runs[s - 1].float >= unit * 4):
        var digits = ""
        var parity = ""
        var ok = true
        var at = s + 3
        for i in 0 ..< 2 * half:
          if i == half:
            if match(runs, at, "11111", unit) > 1.6: (ok = false; break)
            at += 5
          let u = unitOf(runs, at, 4, 7)
          var best = 9.0
          var bd = -1
          var bp = 'L'
          for d in 0 .. 9:
            let l = match(runs, at, eanL[d], u)
            if l < best: (best = l; bd = d; bp = 'L')
            if i < half and n == 13:
              let g = eanL[d]
              let gl = match(runs, at, g[3] & g[2] & g[1] & g[0], u)
              if gl < best: (best = gl; bd = d; bp = 'G')
          if best > 1.5 or bd < 0: (ok = false; break)
          digits.add char(ord('0') + bd)
          if i < half: parity.add bp
          at += 4
        if ok and match(runs, at, "111", unit) < 1.2:
          var text = digits
          if n == 13:
            let f = eanFirst.find(parity)
            if f < 0: ok = false
            else: text = char(ord('0') + f) & digits
          if ok and eanCheck(text[0 ..< text.high]) == ord(text[^1]) - ord('0'):
            if n == 13 and text[0] == '0': res.add (bcUpcA, text[1 .. ^1])
            elif n == 13: res.add (bcEan13, text)
            else: res.add (bcEan8, text)
            return
      s += 2

proc readCode128(runs: seq[int]; firstDark: bool; res: var seq[(BarcodeKind, string)]) =
  let start = if firstDark: 0 else: 1
  var s = start
  while s + 6 + 6 + 7 <= runs.len:
    let unit = unitOf(runs, s, 6, 11)
    var sv = -1
    for v in 103 .. 105:
      if match(runs, s, c128[v], unit) < 1.0: sv = v
    if sv < 0 or (s > 0 and runs[s - 1].float < unit * 5):
      s += 2
      continue
    var vals = @[sv]
    var at = s + 6
    var ok = false
    while at + 6 <= runs.len:
      if at + 7 <= runs.len and match(runs, at, c128Stop, unitOf(runs, at, 7, 13)) < 1.2:
        ok = true
        break
      let u = unitOf(runs, at, 6, 11)
      var best = 9.0
      var bv = -1
      for v in 0 .. 102:
        let d = match(runs, at, c128[v], u)
        if d < best: (best = d; bv = v)
      if best > 1.5: break
      vals.add bv
      at += 6
    if ok and vals.len >= 3:
      var sum = vals[0]
      for k in 1 ..< vals.high: sum += k * vals[k]
      if sum mod 103 == vals[^1]:
        var text = ""
        var cset = vals[0] - 102          # 1 A, 2 B, 3 C
        var shift = false
        for k in 1 ..< vals.high:
          let v = vals[k]
          let cs = if shift: (if cset == 1: 2 else: 1) else: cset
          shift = false
          if cs == 3:
            if v < 100: text.add align($v, 2, '0')
            elif v == 100: cset = 2
            elif v == 101: cset = 1
            continue
          case v
          of 98: shift = true
          of 99: cset = 3
          of 100: (if cs == 1: cset = 2)
          of 101: (if cs == 2: cset = 1)
          of 102, 96, 97: discard        # (FNC1..3)
          else:
            if cs == 2: text.add char(v + 32)
            else: text.add(if v < 64: char(v + 32) else: char(v - 64))
        res.add (bcCode128, text)
        return
    s += 2

proc readCode39(runs: seq[int]; firstDark: bool; res: var seq[(BarcodeKind, string)]) =
  let start = if firstDark: 0 else: 1
  proc charAt(runs: seq[int]; at: int): int =
    ## (the character of the nine runs at `at`: its three widest are its wide ones)
    if at + 9 > runs.len: return -1
    var idx = @[0, 1, 2, 3, 4, 5, 6, 7, 8]
    for i in 1 ..< 9:
      var j = i
      while j > 0 and runs[at + idx[j]] > runs[at + idx[j - 1]]:
        swap(idx[j], idx[j - 1])
        dec j
    let narrowMax = runs[at + idx[3]]
    let wideMin = runs[at + idx[2]]
    if wideMin.float < narrowMax.float * 1.5: return -1
    var bits = 0
    for e in 0 ..< 9:
      if runs[at + e] >= wideMin: bits = bits or (1 shl (8 - e))
    c39.find(bits)
  var s = start
  while s + 9 <= runs.len:
    if charAt(runs, s) == c39Chars.find('*') and (s == 0 or runs[s - 1] >= runs[s] * 5):
      var text = ""
      var at = s + 10
      var ok = false
      while at + 9 <= runs.len:
        let c = charAt(runs, at)
        if c < 0: break
        if c39Chars[c] == '*':
          ok = text.len > 0
          break
        text.add c39Chars[c]
        at += 10
      if ok:
        res.add (bcCode39, text)
        return
    s += 2

proc readRow(dark: seq[bool]; res: var seq[(BarcodeKind, string)]) =
  if dark.len < 20: return
  var runs: seq[int]
  var cur = dark[0]
  var n = 0
  for d in dark:
    if d == cur: inc n
    else:
      runs.add n
      cur = d
      n = 1
  runs.add n
  let firstDark = dark[0]
  let before = res.len
  readEan(runs, firstDark, res)
  if res.len == before: readCode128(runs, firstDark, res)
  if res.len == before: readCode39(runs, firstDark, res)

proc barcodeRead*(b: Bitmap; kinds: set[BarcodeKind] = {BarcodeKind.low .. BarcodeKind.high}): seq[BarcodeRead] =
  ## The barcodes in the picture `b` read: across it or down it (it is turned a quarter for
  ## those), either way round -- rows through its middle tried until one reads. Each found once.
  if b == nil or b.w < 20 or b.h < 4: return
  var luma = newSeq[uint8](b.w * b.h)
  for i, p in b.px:
    luma[i] = uint8((int((p shr 16) and 255) * 77 + int((p shr 8) and 255) * 151 + int(p and 255) * 28) shr 8)
  for turned in [0, 90]:
    let (w, h) = if turned == 0: (b.w, b.h) else: (b.h, b.w)
    template lum(x, y: int): uint8 =
      (if turned == 0: luma[y * b.w + x] else: luma[x * b.w + (b.w - 1 - y)])
    let rows = min(h, 24)
    for k in 0 ..< rows:
      # (rows from the middle out)
      let off = (k + 1) div 2 * (if k mod 2 == 0: 1 else: -1)
      let y = clamp(h div 2 + off * max(1, h div (rows + 1)), 0, h - 1)
      var lo, hi: int
      lo = 255
      for x in 0 ..< w:
        lo = min(lo, int(lum(x, y)))
        hi = max(hi, int(lum(x, y)))
      if hi - lo < 40: continue
      let mid = (lo + hi) div 2
      var dark = newSeq[bool](w)
      for x in 0 ..< w: dark[x] = int(lum(x, y)) < mid
      var found: seq[(BarcodeKind, string)]
      readRow(dark, found)
      if found.len == 0:
        # (upside down: the row the other way)
        var rev = newSeq[bool](w)
        for x in 0 ..< w: rev[x] = dark[w - 1 - x]
        readRow(rev, found)
        for (kind, text) in found:
          var seen = false
          for r in result:
            if r.text == text and r.kind == kind: seen = true
          if not seen and kind in kinds:
            result.add BarcodeRead(kind: kind, text: text, row: y, turned: turned + 180)
        continue
      for (kind, text) in found:
        var seen = false
        for r in result:
          if r.text == text and r.kind == kind: seen = true
        if not seen and kind in kinds:
          result.add BarcodeRead(kind: kind, text: text, row: y, turned: turned)
    if result.len > 0: return
