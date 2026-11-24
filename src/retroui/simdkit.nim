## The kit's own hot loops several pixels at a time -- the screen's drawing (fills, glyphs
## mixed in, pictures copied, widened and mixed), JPEG's inverse DCT and colors, PNG's row
## filters, pictures made smaller -- in C (`simdkit.h`) with the compilers' own vectors: SSE2
## on x86-64 (AVX2 where it pays, picked as the program runs), NEON on ARM, SIMD128 in a web
## page, lane by lane where there is none. Each gives the very values of its plain loop
## (`tests/test_simdkit.nim` holds them side by side). `-d:retroNoSimd` keeps the plain loops
## (in the modules that call these). What `retroui/gfx`, `retroui/jpeg`, `retroui/imaging` and
## `retroui/codec` call; `retroui/simd` has the photo engine's.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

from std/strutils import rfind

const kitKernels = currentSourcePath().substr(0, currentSourcePath().rfind({'/', '\\'})) & "simdkit.h"
  ## (cut from the source's own path: `os.parentDir` and `/` turn its "/" into "\" when
  ## Windows is the target, and a compiler on Linux building for Windows finds no such file)

const kitSimd* = not defined(retroNoSimd)
  ## The kernels are used (else the plain Nim loops)

proc fill32*(d: ptr uint32; n: int; c: uint32) {.importc: "ruk_fill32", header: kitKernels, cdecl.}
  ## `n` pixels from `d` made `c`.

proc blendMaskRow*(fp: ptr uint32; m: ptr uint8; n: int; col: uint32; lut: ptr uint8)
  {.importc: "ruk_blend_mask", header: kitKernels, cdecl.}
  ## A glyph's row: `n` pixels of `fp` mixed with `col` by the coverages `m` (through `lut`,
  ## when not nil), as the screen's `blend` does it.

proc blendConstRow*(fp: ptr uint32; n: int; col: uint32; a: uint32)
  {.importc: "ruk_blend_const", header: kitKernels, cdecl.}
  ## `n` pixels of `fp` mixed with `col` by one coverage `a` (a see-through color's span): the
  ## values of `blendMaskRow` with every coverage `a`.

proc overRow*(fp, sp: ptr uint32; n: int) {.importc: "ruk_over_row", header: kitKernels, cdecl.}
  ## A picture's row over the screen's, by each of its pixels' alpha (255 copied, 0 left).

proc widenRow*(dst, src: ptr uint32; n: int; k: cint) {.importc: "ruk_widen_row", header: kitKernels, cdecl.}
  ## `n` pixels each repeated `k` times (the alpha byte dropped).

proc gatherOpaque*(dst, src: ptr uint32; xs: ptr int32; n: int): int
  {.importc: "ruk_gather_opaque", header: kitKernels, cdecl.}
  ## `dst[i] = src[xs[i]]` from the first while `xs[i] >= 0` and the pixel is opaque: how many
  ## (a zoomed view's row; the caller does the one it stopped at).

proc firstAlpha*(p: ptr uint32; n: int): int {.importc: "ruk_first_alpha", header: kitKernels, cdecl.}
  ## The first of `n` pixels from `p` with some alpha (`n`: none).

proc lastAlpha*(p: ptr uint32; n: int): int {.importc: "ruk_last_alpha", header: kitKernels, cdecl.}
  ## The last of `n` pixels from `p` with some alpha (-1: none).

proc idctBlock*(blk: ptr int32; outp: ptr uint8; stride: int): cint
  {.importc: "ruk_idct", header: kitKernels, cdecl.}
  ## JPEG's inverse DCT of a block (dequantized, natural order) into 8 rows of 8 bytes `stride`
  ## apart, in 32-bit lanes: the bytes of jpeg.nim's 64-bit loop; 0 (nothing written) for a
  ## block whose numbers could pass 32 bits, left to that loop.

proc yccRow*(o: ptr uint32; y, cb, cr: ptr uint8; n: int) {.importc: "ruk_ycc", header: kitKernels, cdecl.}
  ## `n` pixels from rows of Y, Cb and Cr: JPEG's YCbCr to opaque RGB, as jpeg.nim does it.

proc fancyRow*(o, near, far: ptr uint8; vw, w: int; vs: cint)
  {.importc: "ruk_fancy2", header: kitKernels, cdecl.}
  ## A JPEG color plane at half the width made full: `w` bytes from `vw` samples of the nearest
  ## row (and, `vs` 2, the next nearest), as libjpeg's "fancy" upsampling (jpeg.nim's).

proc pngFilterSums*(cp, up: ptr uint8; n: int; ch: cint; sums: ptr int64)
  {.importc: "ruk_png_sums", header: kitKernels, cdecl.}
  ## PNG's five row filters weighed at once: `sums[k]` the sum of the sizes of a row's `n` bytes
  ## (`ch` a pixel, `up` the row above) filtered with filter `k`, each byte taken as signed.

proc pngFilterRow*(o, cp, up: ptr uint8; n: int; ch, kind: cint)
  {.importc: "ruk_png_filter", header: kitKernels, cdecl.}
  ## A row's `n` bytes filtered with PNG filter `kind` (0 None .. 4 Paeth) into `o`.

proc adlerUpdate*(adler: uint32; p: ptr uint8; n: int): uint32
  {.importc: "ruk_adler32", header: kitKernels, cdecl.}
  ## The Adler-32 check after `n` more bytes from `p` (start 1), sixteen at a time.

proc yuyvRow*(o: ptr uint32; s: ptr uint8; pairs: int)
  {.importc: "ruk_yuyv_row", header: kitKernels, cdecl.}
  ## A webcam's YUYV row (`pairs` pairs of pixels) as opaque RGB: BT.601, limited range.

proc lumaRow*(o: ptr uint8; px: ptr uint32; n: int; cr, cg, cb: int32)
  {.importc: "ruk_luma_row", header: kitKernels, cdecl.}
  ## A video frame's luma bytes of `n` pixels: `(cr R + cg G + cb B + 32768) shr 16 + 16`, kept
  ## in 16 .. 235.

proc kitHasAvx2*(): cint {.importc: "ruk_has_avx2", header: kitKernels, cdecl.}
  ## 1 when the processor has AVX2 and the kernels use it.

proc kitForceAvx2*(on: cint) {.importc: "ruk_force_avx2", header: kitKernels, cdecl.}
  ## For a test: 0 the narrower kernels, 1 the AVX2 ones (where the processor has it), -1 as it
  ## says.
