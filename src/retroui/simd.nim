## The photo engine's hottest loops four lanes at a time: the layers mixed (Normal and the
## separable blend modes over opaque pixels, with masks, clipped, by Blend If), a gaussian
## blur's passes, a picture resampled, a color through a table of colors (adjustment layers,
## proofs, profiles). In C (`simdkern.h`, `simdmix.h`) with the compilers' own vectors, so one
## code is SSE2 on x86, NEON on ARM, SIMD128 in a web page, and lane by lane where there is
## none; on x86 the mixing and the blur take eight lanes where the processor has AVX2 (asked
## once, at the first call). What `retroui/photo`, `retroui/photofx` and `retroui/photoinks`
## call; `-d:retroNoSimd` keeps the plain loops.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

from std/strutils import rfind

const kernels = currentSourcePath().substr(0, currentSourcePath().rfind({'/', '\\'})) & "simdkern.h"
  ## (cut from the source's own path: `os.parentDir` and `/` turn its "/" into "\" when
  ## Windows is the target, and a compiler on Linux building for Windows finds no such file)

const simdOn* = not defined(retroNoSimd)
  ## The kernels are used (else the plain Nim loops)

proc mixOpaque*(dst, src: ptr UncheckedArray[uint32]; x, xb: int; op: int; lut: ptr UncheckedArray[uint8]): int
  {.importc: "rui_mix_opaque", header: kernels, cdecl.}
  ## `src` over the opaque pixels of `dst`, `x` ..< `xb`, `op` (0..255) of it times its alpha,
  ## mixed by `lut` (a separable mode's table; nil Normal); the first pixel it left for the
  ## caller -- `dst` not opaque there and `src` showing -- or `xb`.

type
  MixOpt* {.importc: "rui_mixopt", header: kernels, bycopy.} = object
    ## What a layer's pixel is mixed by besides its opacity (`mixOpt`): each row indexed by
    ## the document's column, nil when it has none.
    mask*: ptr UncheckedArray[uint32]    ## its layer mask (gray: the red byte)
    cover*: ptr UncheckedArray[uint32]   ## clipped to a group: how much the group covers (0..255)
    base*: ptr UncheckedArray[uint32]    ## clipped to a layer: that layer's pixels (its alpha)
    bmask*: ptr UncheckedArray[uint32]   ## ... and its mask
    blut*: cint                          ## ... an adjustment layer (its red times its alpha)
    bif*: cint                           ## Blend If ...
    ch*: cint                            ## ... by this channel (0 gray, 1 red, 2 green, 3 blue)
    thisT*: ptr UncheckedArray[uint8]    ## ... how much each value of the layer lets it show
    underT*: ptr UncheckedArray[uint8]   ## ... and each value of what is under it

proc mixOpt*(dst, src: ptr UncheckedArray[uint32]; x, xb: int; op: int; lut: ptr UncheckedArray[uint8];
             o: ptr MixOpt): int {.importc: "rui_mix_opt", header: kernels, cdecl.}
  ## `mixOpaque`, each pixel's amount its opacity times what `o` gives it there -- as the plain
  ## loop works it out, each step rounded down.

proc lutAdj*(lut: ptr UncheckedArray[uint32]; n: int; p: uint32): uint32
  {.importc: "rui_lut3_adj", header: kernels, cdecl.}
  ## `p` through a table of `n` x `n` x `n` colors, read between them (red, green, blue; the
  ## alpha kept): an adjustment layer's.

proc lutInk*(t: ptr UncheckedArray[uint32]; n: int; p: uint32): uint32
  {.importc: "rui_lut3_ink", header: kernels, cdecl.}
  ## ... its four bytes (a proof's table, a profile's).

proc hasAvx2*(): cint {.importc: "rui_has_avx2", header: kernels, cdecl.}
  ## 1 when the processor has AVX2 and the kernels use it (x86; 0 elsewhere).

proc forceAvx2*(on: cint) {.importc: "rui_force_avx2", header: kernels, cdecl.}
  ## For a test: 0 the four-lane kernels, 1 the eight-lane ones (on a processor that has
  ## AVX2 only), -1 as the processor says.

proc maddU16*(acc: ptr UncheckedArray[uint32]; buf: ptr UncheckedArray[uint16]; n: int; kw: uint32)
  {.importc: "rui_madd_u16", header: kernels, cdecl.}
  ## `acc[t] += kw * buf[t]` for `t` < `n`.

proc preRow*(src: ptr UncheckedArray[uint32]; w: int; pre: ptr UncheckedArray[float32])
  {.importc: "rui_pre_row", header: kernels, cdecl.}
  ## A row as the blur takes it: alpha, then red, green, blue premultiplied (rounded down), as
  ## floats, four a pixel.

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
