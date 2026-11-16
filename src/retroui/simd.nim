## The photo engine's hottest loops four lanes at a time: the layers mixed (Normal and the
## separable blend modes over opaque pixels), a gaussian blur's passes, a picture resampled.
## In C (`simdkern.h`) with the compilers' own vectors, so one code is SSE2 or AVX on x86, NEON
## on ARM, SIMD128 in a web page built with `-msimd128`, and lane by lane where there is none.
## What `retroui/photo` and `retroui/photofx` call; `-d:retroNoSimd` keeps the plain loops.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/os

const kernels = currentSourcePath().parentDir / "simdkern.h"

const simdOn* = not defined(retroNoSimd)
  ## The kernels are used (else the plain Nim loops)

proc mixOpaque*(dst, src: ptr UncheckedArray[uint32]; x, xb: int; op: int; lut: ptr UncheckedArray[uint8]): int
  {.importc: "rui_mix_opaque", header: kernels, cdecl.}
  ## `src` over the opaque pixels of `dst`, `x` ..< `xb`, `op` (0..255) of it times its alpha,
  ## mixed by `lut` (a separable mode's table; nil Normal); the first pixel it left for the
  ## caller -- `dst` not opaque there and `src` showing -- or `xb`.

proc maddU16*(acc: ptr UncheckedArray[uint32]; buf: ptr UncheckedArray[uint16]; n: int; kw: uint32)
  {.importc: "rui_madd_u16", header: kernels, cdecl.}
  ## `acc[t] += kw * buf[t]` for `t` < `n`.

proc blurAcross*(pre: ptr UncheckedArray[float32]; w: int; k: ptr UncheckedArray[float32]; kr: int;
                 o: ptr UncheckedArray[uint16]) {.importc: "rui_blur_across", header: kernels, cdecl.}
  ## A row blurred across: `pre` four floats a pixel (premultiplied), `k` 2 `kr` + 1 weights.

proc resampleRows*(sp: ptr UncheckedArray[uint32]; w, nw, y0, y1, taps: int; yi: ptr UncheckedArray[int32];
                   yw: ptr UncheckedArray[float32]; xi: ptr UncheckedArray[int32]; xw: ptr UncheckedArray[float32];
                   o: ptr UncheckedArray[uint32]; ring: ptr UncheckedArray[float32]; ringRow: ptr UncheckedArray[cint];
                   rn: int) {.importc: "rui_resample_rows", header: kernels, cdecl.}
  ## Rows `y0` ..< `y1` of a resampled picture, across then down (`ring`: room for `rn` rows of
  ## `nw` pixels, four floats each; `ringRow`: `rn` of them).

proc boxAcross*(row: ptr UncheckedArray[uint32]; w, r: int; mid: ptr UncheckedArray[uint16])
  {.importc: "rui_box_across", header: kernels, cdecl.}
  ## A box blur across a row (`2 r + 1`), four 16-bit means a pixel into `mid`.

proc boxDown*(mid: ptr UncheckedArray[uint16]; w, h, x0, x1, r: int; o: ptr UncheckedArray[uint32];
              acc: ptr UncheckedArray[uint32]) {.importc: "rui_box_down", header: kernels, cdecl.}
  ## ... and down the columns `x0` ..< `x1`, into the picture `o`.
