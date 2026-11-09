## Layers mixed on the GPU: a document's composite (`updateComposite`)
## worked out by the GPU, when frames are drawn with it and the part to make
## again is big, to the same pixels as the CPU makes.
##
## Each layer (and mask) is a texture -- in tiles no bigger than the GPU
## takes -- kept between composites and sent again only where it changed
## (its `ver`, the document's changes since). The part to make is drawn
## into textures a tile at a time, one pass for each step of the CPU's
## composite (`compositeInto`: the layers, their masks, the groups, the
## clipping masks, the adjustment layers' tables), each pass the CPU's
## integer arithmetic exactly (32-bit floats holding whole numbers) -- the
## modes that mix channels alone through the CPU's own table of them --
## and read back into `comp`: whatever reads the composite reads it as
## always. The pixels the GPU cannot be sure of are marked and done again
## on the CPU, those alone: Darker / Lighter Color where both colors are
## equally light, and Hue / Saturation / Color / Luminosity where a value
## falls (within the GPU's rounding) on a half -- the CPU's choice there is
## its 64-bit rounding. So the pixels are the CPU's, exactly.
##
## Not done here (the CPU does them, unchanged): layer styles, Blend If,
## Dissolve (and Behind / Clear), Clarity and Grain at the top level, 16-
## and 32-bit documents, a GPU without 32-bit floats in its fragment shaders
## or that fails a first check against the CPU, a document too big for
## `gpuCompositeBudget`.
##
## .. code-block:: nim
##   import retroui/photogpu
##   enableGpuComposite()        # once: `updateComposite` asks the GPU first
##
## Off with `enableGpuComposite(false)`, `gpuCompositeOn = false`, the
## environment's `RETRO_GPU_COMPOSITE=0`, or frames drawn on the CPU
## (`setGpuMode(gmCpu)`). It times itself against the CPU and keeps to the
## CPU where the GPU is slower (`gpuCompositeGuard`).

import std/[tables, monotimes, times, os, hashes, math, algorithm]
import gfx, glapi, photo
import uirelays/screen

const
  SepSet = {bmMultiply, bmScreen, bmOverlay, bmSoftLight, bmHardLight, bmDarken, bmLighten,
            bmDifference, bmColorBurn, bmLinearBurn, bmColorDodge, bmLinearDodge, bmVividLight,
            bmLinearLight, bmPinLight, bmHardMix, bmExclusion, bmSubtract, bmDivide}
    ## (the modes of channels alone: the CPU's `SepModes`)
  NonSepSet = {bmHue, bmSaturation, bmColor, bmLuminosity, bmDarkerColor, bmLighterColor}
  UnsureModes = NonSepSet
    ## (modes whose pixels the GPU may not be sure of: done again on the CPU)
  BadModes = {bmDissolve, bmBehind, bmClear}
  LutSide = 33                               # (photo's `LutN`)

var
  nearHalf = 0.0003                          # (how near a half (0..255) a color mode's value is made
                                             # again on the CPU: some 3 times the GPU's error)
  gpuCompositeOn* = true
    ## Layers may be mixed on the GPU (with `enableGpuComposite`).
  gpuCompositeMinPixels* = 2_000_000
    ## The smallest part (pixels) `updateComposite` makes on the GPU: a
    ## smaller one is quicker on the CPU (sending it costs more).
  gpuCompositeTile* = 2048
    ## The side of the tiles layers are sent and mixed in (at most the
    ## GPU's longest texture).
  gpuCompositeBudget* = (when defined(android) or defined(ios): 384 else: 1024) * 1024 * 1024
    ## The GPU memory (bytes) the layers' textures may take: a document
    ## needing more is mixed on the CPU.

type
  GpuCompositeStats* = object
    ## What the GPU composite did (for tests, a settings page).
    gpu*: int             ## composites made on the GPU
    cpu*: int             ## ... on the CPU (in the hook: the guard chose it)
    declined*: int        ## ... left to the CPU (a feature not done here, no GPU...)
    uploadedPixels*: int  ## pixels sent to the GPU
    fixedPixels*: int     ## pixels made again on the CPU (Darker / Lighter Color ties)
    passes*: int          ## passes drawn
    lastReason*: string   ## why the last one was declined

var gpuCompositeStats*: GpuCompositeStats
  ## What the GPU composite has done since the program started.

proc dbg(msg: string) =
  if getEnv("RETRO_GPU_DEBUG") == "1": stderr.writeLine("[gpu composite] " & msg)

# ---- which is quicker: the GPU or the CPU ------------------------------------------------------------

const
  GuardBuckets = 8
  GuardMinSamples = 2

type
  GuardSide = object
    n: int
    rate: float               # seconds per pixel per step (an average)

  CompositeGuard* = object
    ## Which of the GPU and the CPU mixes layers quicker here, from how long
    ## each took for parts of about the same size (2 MP, 4 MP, 8 MP...):
    ## each tried first, then the quicker one used, the other tried again now
    ## and then -- less often while it stays slower.
    gpu, cpu: array[GuardBuckets, GuardSide]
    since, every: array[GuardBuckets, int]
    verdict: array[GuardBuckets, int]     # 0 none yet, 1 the GPU quicker, 2 the CPU

var gpuCompositeGuard*: CompositeGuard
  ## The hook's guard (see `CompositeGuard`).

proc bucketOf(pixels: int): int =
  var p = max(1, pixels) shr 20
  while p > 1 and result < GuardBuckets - 1:
    p = p shr 1
    inc result

proc gpuQuicker*(g: CompositeGuard; pixels: int): int =
  ## What is known for a part of `pixels`: 1 the GPU is quicker, 2 the CPU,
  ## 0 not known yet (this size or the nearest one timed both ways).
  let b = bucketOf(pixels)
  for dist in 0 ..< GuardBuckets:
    for bb in [b - dist, b + dist]:
      if bb < 0 or bb >= GuardBuckets: continue
      if g.gpu[bb].n >= GuardMinSamples and g.cpu[bb].n >= GuardMinSamples:
        return (if g.gpu[bb].rate <= g.cpu[bb].rate: 1 else: 2)
  0

proc useGpu*(g: var CompositeGuard; pixels, steps: int): bool =
  ## Whether to mix this part (`pixels`, `steps` layers) on the GPU: each
  ## way timed first, then the quicker, the other tried again every 16, 32...
  ## up to 512 times.
  let b = bucketOf(pixels)
  let v = g.gpuQuicker(pixels)
  if v == 0:
    # (nothing known: the GPU tried, then the CPU)
    return g.gpu[b].n < GuardMinSamples
  if v != g.verdict[b]:
    g.verdict[b] = v
    g.since[b] = 0
    g.every[b] = 16
  inc g.since[b]
  if g.since[b] >= g.every[b]:
    g.since[b] = 0
    g.every[b] = min(g.every[b] * 2, 512)
    return v != 1                          # (the slower one, again)
  v == 1

proc record*(g: var CompositeGuard; gpu: bool; pixels, steps: int; seconds: float) =
  ## How long mixing `pixels` pixels of `steps` layers took on the GPU or the
  ## CPU.
  let b = bucketOf(pixels)
  let r = seconds / (float(max(1, pixels)) * float(max(1, steps)))
  template upd(s: var GuardSide) =
    s.rate = if s.n == 0: r else: s.rate * 0.6 + r * 0.4
    inc s.n
  if gpu: upd(g.gpu[b]) else: upd(g.cpu[b])

# ---- the CPU's arithmetic, as tables ----------------------------------------------------------------------

proc sepBlend(m: BlendMode; cb, cs: int): int =
  ## (photo's: the modes of channels alone)
  case m
  of bmMultiply: cb * cs div 255
  of bmScreen: cb + cs - cb * cs div 255
  of bmOverlay:
    if cb < 128: 2 * cb * cs div 255 else: 255 - 2 * (255 - cb) * (255 - cs) div 255
  of bmHardLight:
    if cs < 128: 2 * cb * cs div 255 else: 255 - 2 * (255 - cb) * (255 - cs) div 255
  of bmSoftLight:
    let b = cb / 255
    let s = cs / 255
    let d = if b <= 0.25: ((16 * b - 12) * b + 4) * b else: sqrt(b)
    let r = if s <= 0.5: b - (1 - 2 * s) * b * (1 - b) else: b + (2 * s - 1) * (d - b)
    int(round(r * 255))
  of bmDarken: min(cb, cs)
  of bmLighten: max(cb, cs)
  of bmDifference: abs(cb - cs)
  of bmColorBurn:
    if cb >= 255: 255 elif cs <= 0: 0 else: 255 - min(255, (255 - cb) * 255 div cs)
  of bmColorDodge:
    if cb <= 0: 0 elif cs >= 255: 255 else: min(255, cb * 255 div (255 - cs))
  of bmLinearBurn: max(0, cb + cs - 255)
  of bmLinearDodge: min(255, cb + cs)
  of bmVividLight:
    if cs < 128:
      let s2 = 2 * cs
      if cb >= 255: 255 elif s2 <= 0: 0 else: 255 - min(255, (255 - cb) * 255 div s2)
    else:
      let s2 = 2 * (cs - 128)
      if cb <= 0: 0 elif s2 >= 255: 255 else: min(255, cb * 255 div (255 - s2))
  of bmLinearLight: clamp(cb + 2 * cs - 255, 0, 255)
  of bmPinLight:
    if cs < 128: min(cb, 2 * cs) else: max(cb, 2 * (cs - 128))
  of bmHardMix: (if cb + cs >= 255: 255 else: 0)
  of bmExclusion: cb + cs - 2 * cb * cs div 255
  of bmSubtract: max(0, cb - cs)
  of bmDivide:
    if cs <= 0: (if cb > 0: 255 else: 0) else: min(255, cb * 255 div cs)
  else: cs

proc channelTables(lut: seq[uint32]): seq[uint8] =
  ## (photo's: an adjustment's table as three of 256 when each channel
  ## follows its own alone -- the same numbers as read between the colors)
  const n = LutSide - 1
  if lut.len != LutSide * LutSide * LutSide: return
  template at(i, j, k: int): uint32 = lut[(i * LutSide + j) * LutSide + k]
  for i in 0 ..< LutSide:
    for j in 0 ..< LutSide:
      for k in 0 ..< LutSide:
        let v = at(i, j, k)
        if ((v xor at(i, 0, 0)) and 0xFF0000'u32) != 0 or ((v xor at(0, j, 0)) and 0xFF00'u32) != 0 or
           ((v xor at(0, 0, k)) and 0xFF'u32) != 0: return
  result = newSeq[uint8](768)
  for c in 0 .. 2:
    let sh = 16 - 8 * c
    template f(i: int): int =
      int((at((if c == 0: i else: 0), (if c == 1: i else: 0), (if c == 2: i else: 0)) shr sh) and 255)
    for x in 0 .. 255:
      let xi = x * n div 255
      let xf = x * n - xi * 255
      let x1 = min(xi + 1, n)
      # (in 64 bits: 255^4 is past what a 32-bit int holds)
      result[c * 256 + x] = uint8((int64(f(xi)) * (255 - xf) * 65025 + int64(f(x1)) * xf * 65025 +
                                   255 * 255 * 255 div 2) div (255 * 255 * 255))

# ---- the shaders ------------------------------------------------------------------------------------------
#
# Every value a whole number 0..255 in a 32-bit float; a division as the
# CPU's `div` (rounded down, corrected by the remainder: exact). A pixel
# 0xAARRGGBB is sent as it is in memory -- B, G, R, A -- so `.bgra` reads
# it, and written back so (plus a quarter: kept whether the GPU rounds or
# cuts).

const VertexSrc = """
attribute vec2 aPos;
uniform vec2 uView;
varying vec2 vPix;
void main() {
  vPix = (aPos * 0.5 + 0.5) * uView;
  gl_Position = vec4(aPos, 0.0, 1.0);
}
"""

const FragmentSrc = """
varying vec2 vPix;
uniform vec2 uAccSize;
uniform vec2 uTileOrg;
uniform vec2 uTileInv;
uniform float uOp;
uniform float uFast;
uniform float uMaskLo;
uniform float uBaseMaskLo;
uniform float uBaseLut;
uniform sampler2D uAcc;
uniform sampler2D uSrc;
uniform sampler2D uMask;
uniform sampler2D uBase;
uniform sampler2D uBaseMask;
uniform sampler2D uCov;
uniform sampler2D uSep;
uniform sampler2D uLut;
vec2 P;
bool gTie;
float gAmp;

vec4 px4(vec4 t) { return floor(t.bgra * 255.0 + 0.5); }
vec4 accAt(sampler2D t) { return px4(texture2D(t, (P + 0.5) / uAccSize)); }
vec4 tileAt(sampler2D t) { return px4(texture2D(t, (P + uTileOrg + 0.5) * uTileInv)); }
float idiv(float n, float d) {
  float q = floor(n / d);
  float r = n - q * d;
  return q + step(d, r) - (1.0 - step(0.0, r));
}
vec3 idiv3(vec3 n, float d) {
  vec3 q = floor(n / d);
  vec3 r = n - q * d;
  return q + step(vec3(d), r) - (vec3(1.0) - step(vec3(0.0), r));
}
float d255(float n) { return idiv(n, 255.0); }

#if HAS_MASK
float maskVal() {
  float v = tileAt(uMask).r;
  return uMaskLo + d255(v * (255.0 - uMaskLo));
}
#endif

#if CLIP == 1
float clipAmt(float a) {
  vec4 b = tileAt(uBase);
  float ba = b.a;
  if (uBaseLut > 0.5) ba = d255(b.r * ba);
#if BASE_MASK
  float bv = tileAt(uBaseMask).r;
  ba = d255(ba * (uBaseMaskLo + d255(bv * (255.0 - uBaseMaskLo))));
#endif
  return d255(a * ba);
}
#elif CLIP == 2
float clipAmt(float a) { return d255(a * accAt(uCov).r); }
#else
float clipAmt(float a) { return a; }
#endif

#if SEPM
float sep1(float cb, float cs) {
  return floor(texture2D(uSep, vec2((cs + 0.5) / 256.0, (cb + 0.5) / 256.0)).a * 255.0 + 0.5);
}
vec3 mixMode(vec3 b, vec3 s) { return vec3(sep1(b.r, s.r), sep1(b.g, s.g), sep1(b.b, s.b)); }
#elif NONSEPM
// (in 0..255, as the CPU's in 0..1; the lightness of whole numbers exact)
float lumK(vec3 c) { return dot(c, vec3(30.0, 59.0, 11.0)) * 0.01; }
vec3 clipColor(vec3 c) {
  float l = lumK(c);
  float n = min(c.r, min(c.g, c.b));
  float x = max(c.r, max(c.g, c.b));
  // (how much the rounding before is made bigger here: kept for NEAR_HALF)
  if (n < 0.0) {
    gAmp = max(gAmp, (x - n) / (l - n));
    c = vec3(l) + (c - vec3(l)) * l / (l - n);
  }
  if (x > 255.0) {
    gAmp = max(gAmp, 2.0);
    c = vec3(l) + (c - vec3(l)) * (255.0 - l) / (x - l);
  }
  return c;
}
vec3 setLum(vec3 c, float l) { return clipColor(c + vec3(l - lumK(c))); }
float satF(vec3 c) { return max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b)); }
vec3 setSat(vec3 c, float s) {
  float mx = max(c.r, max(c.g, c.b));
  float mn = min(c.r, min(c.g, c.b));
  if (mx > mn) return (c - vec3(mn)) * s / (mx - mn);
  return vec3(0.0);
}
vec3 mixMode(vec3 b, vec3 s) {
#if MODE == M_DARKER || MODE == M_LIGHTER
  float ks = dot(s, vec3(30.0, 59.0, 11.0));
  float kb = dot(b, vec3(30.0, 59.0, 11.0));
  // (as light: which the CPU takes is its rounding's -- done again there)
  if (ks == kb && any(notEqual(s, b))) gTie = true;
#if MODE == M_DARKER
  return ks < kb ? s : b;
#else
  return ks > kb ? s : b;
#endif
#else
  vec3 r;
#if MODE == M_HUE
  r = setLum(setSat(s, satF(b)), lumK(b));
#elif MODE == M_SAT
  r = setLum(setSat(b, satF(s)), lumK(b));
#elif MODE == M_COLOR
  r = setLum(s, lumK(b));
#else
  r = setLum(b, lumK(s));
#endif
  // (a value this close to a half: the CPU's 64-bit rounding may go the
  // other way -- done again there)
  if (any(lessThan(abs(fract(r) - vec3(0.5)), vec3(NEAR_HALF * (1.0 + gAmp))))) gTie = true;
  return clamp(floor(r + vec3(0.5)), 0.0, 255.0);
#endif
}
#endif

vec4 blendPx(vec4 d, vec4 s, float alpha) {
  float sa = d255(s.a * alpha);
  if (sa <= 0.0) return d;
  float da = d.a;
#if MODE == M_NORMAL
  if (sa >= 255.0) return vec4(s.rgb, 255.0);
#else
  if (sa >= 255.0 && da == 0.0) return vec4(s.rgb, 255.0);
#endif
  if (da == 0.0) return vec4(s.rgb, sa);
#if MODE == M_NORMAL
  vec3 c = s.rgb;
#else
  vec3 c = idiv3(s.rgb * (255.0 - da) + mixMode(d.rgb, s.rgb) * da, 255.0);
#endif
  float wd = d255(da * (255.0 - sa));
  float oa = sa + wd;
  return vec4(clamp(idiv3(c * sa + d.rgb * wd, oa), 0.0, 255.0), oa);
}

vec4 overOpaque(vec4 d, vec4 s, float ea) {
#if SEPM
  vec3 sc = mixMode(d.rgb, s.rgb);
#else
  vec3 sc = s.rgb;
#endif
  return vec4(idiv3(sc * ea + d.rgb * (255.0 - ea), 255.0), 255.0);
}

vec4 lerpPx(vec4 a, vec4 b, float t) {
  if (t >= 255.0) return b;
  if (t <= 0.0) return a;
  float aa = a.a * (255.0 - t);
  float ba = b.a * t;
  float al = aa + ba;
  if (al == 0.0) return vec4(0.0);
  vec3 c = idiv3(a.rgb * aa + b.rgb * ba + floor(al * 0.5), al);
  return vec4(c, idiv(al + 127.0, 255.0));
}

#if KIND == K_ADJ
#if LUT3
vec3 lutAt(float i, float j, float k) {
  return floor(texture2D(uLut, vec2((j * 33.0 + k + 0.5) / 1089.0, (i + 0.5) / 33.0)).bgr * 255.0 + 0.5);
}
vec3 lutApply(vec3 p) {
  vec3 q = p * 32.0;
  vec3 qi = idiv3(q, 255.0);
  vec3 f = q - qi * 255.0;
  vec3 q1 = min(qi + vec3(1.0), vec3(32.0));
  vec3 v000 = lutAt(qi.r, qi.g, qi.b);
  vec3 v001 = lutAt(qi.r, qi.g, q1.b);
  vec3 v010 = lutAt(qi.r, q1.g, qi.b);
  vec3 v011 = lutAt(qi.r, q1.g, q1.b);
  vec3 v100 = lutAt(q1.r, qi.g, qi.b);
  vec3 v101 = lutAt(q1.r, qi.g, q1.b);
  vec3 v110 = lutAt(q1.r, q1.g, qi.b);
  vec3 v111 = lutAt(q1.r, q1.g, q1.b);
  vec3 c00 = v000 * (255.0 - f.b) + v001 * f.b;
  vec3 c01 = v010 * (255.0 - f.b) + v011 * f.b;
  vec3 c10 = v100 * (255.0 - f.b) + v101 * f.b;
  vec3 c11 = v110 * (255.0 - f.b) + v111 * f.b;
  vec3 c0 = c00 * (255.0 - f.g) + c01 * f.g;
  vec3 c1 = c10 * (255.0 - f.g) + c11 * f.g;
  // (c0 (255 - rf) + c1 rf + 8290687) div 16581375: past 2^24, so guessed,
  // then the remainder worked out in pieces of 4096 and the guess put right
  float rf = f.r;
  vec3 dd = c1 - c0;
  vec3 est = floor((255.0 * c0 + rf * dd + 8290687.0) / 16581375.0);
  vec3 c0h = floor(c0 * 0.000244140625);
  vec3 c0l = c0 - c0h * 4096.0;
  vec3 dh = floor(dd * 0.000244140625);
  vec3 dl = dd - dh * 4096.0;
  vec3 hi = 255.0 * c0h + rf * dh + vec3(2024.0) - est * 4048.0;
  vec3 lo = 255.0 * c0l + rf * dl + vec3(383.0) - est * 767.0;
  vec3 cy = floor(lo * 0.000244140625);
  hi += cy;
  lo -= cy * 4096.0;
  vec3 neg = vec3(1.0) - step(vec3(0.0), hi);
  vec3 over = step(vec3(4049.0), hi) +
              step(vec3(4048.0), hi) * (vec3(1.0) - step(vec3(4049.0), hi)) * step(vec3(767.0), lo);
  return est - neg + over;
}
#else
vec3 lutApply(vec3 p) {
  float r = floor(texture2D(uLut, vec2((p.r + 0.5) / 256.0, 0.5)).b * 255.0 + 0.5);
  float g = floor(texture2D(uLut, vec2((p.g + 0.5) / 256.0, 0.5)).g * 255.0 + 0.5);
  float b = floor(texture2D(uLut, vec2((p.b + 0.5) / 256.0, 0.5)).r * 255.0 + 0.5);
  return vec3(r, g, b);
}
#endif
#endif

#if KIND == K_LAYER || KIND == K_COVER_LAYER
float layerAmt() {
  float a = uOp;
#if HAS_MASK
  a = d255(a * maskVal());
  if (a <= 0.0) return 0.0;
#endif
  return clipAmt(a);
}
#endif

vec4 compute() {
#if KIND == K_LAYER
  vec4 d0 = accAt(uAcc);
  vec4 s = tileAt(uSrc);
  if (s.a == 0.0) return d0;
  if (uFast > 0.5 && s.a == 255.0) return s;
  float a = layerAmt();
  if (a <= 0.0) return d0;
#if QUICK
  if (d0.a == 255.0) {
    float ea = d255(a * s.a);
    return ea > 0.0 ? overOpaque(d0, s, ea) : d0;
  }
#endif
  return blendPx(d0, s, a);
#elif KIND == K_COVER_LAYER
  float cv = accAt(uAcc).r;
  vec4 s = tileAt(uSrc);
  float amt = 0.0;
  if (s.a > 0.0) {
    if (uFast > 0.5 && s.a == 255.0) amt = 255.0;
    else {
      float a = layerAmt();
      if (a > 0.0) amt = d255(a * s.a);
    }
  }
  return vec4(cv + d255(amt * (255.0 - cv)));
#elif KIND == K_ADJ
  vec4 under = accAt(uAcc);
  if (under.a == 0.0) return under;
  vec4 mk = tileAt(uSrc);
  float amt = clipAmt(d255(d255(mk.r * mk.a) * uOp));
#if HAS_MASK
  amt = d255(amt * maskVal());
#endif
  if (amt <= 0.0) return under;
  vec3 v = lutApply(under.rgb);
#if MODE == M_NORMAL
  if (amt >= 255.0) return vec4(v, under.a);
  vec3 dv = (v - under.rgb) * amt + vec3(127.0);
  return vec4(under.rgb + sign(dv) * idiv3(abs(dv), 255.0), under.a);
#elif QUICK
  return vec4(overOpaque(vec4(under.rgb, 255.0), vec4(v, 255.0), min(amt, 255.0)).rgb, under.a);
#else
  return vec4(blendPx(vec4(under.rgb, 255.0), vec4(v, 255.0), amt).rgb, under.a);
#endif
#elif KIND == K_POPISO || KIND == K_COVER_POP || KIND == K_COVPOP
  vec4 s = accAt(uSrc);
  float a = uOp;
#if HAS_MASK
  a = d255(a * maskVal());
#endif
  float ea = d255(a * s.a);
#if KIND == K_COVPOP
  return vec4(ea);
#elif KIND == K_COVER_POP
  float cv = accAt(uAcc).r;
  return vec4(cv + d255(ea * (255.0 - cv)));
#else
  vec4 o0 = accAt(uAcc);
  if (ea <= 0.0) return o0;
#if QUICK
  if (o0.a == 255.0) return overOpaque(o0, s, ea);
#endif
  return blendPx(o0, s, a);
#endif
#elif KIND == K_LERP || KIND == K_COVSCALE
  float t = uOp;
#if HAS_MASK
  t = d255(t * maskVal());
#endif
#if KIND == K_LERP
  return lerpPx(accAt(uSrc), accAt(uAcc), t);
#else
  return vec4(d255(accAt(uAcc).r * t));
#endif
#else
  return tileAt(uSrc);
#endif
}

void main() {
  P = floor(vPix);
  gTie = false;
  gAmp = 0.0;
  vec4 r = compute();
#if FLAGS
  if (!gTie) discard;
  gl_FragColor = vec4(1.0);
#else
  gl_FragColor = (r.bgra + 0.25) / 255.0;
#endif
}
"""

type
  PassKind = enum
    pkNone, pkLayer, pkCoverLayer, pkAdj, pkPopIso, pkCoverPop, pkCovPop, pkLerp, pkCovScale, pkCopy

  Prog = object
    id: GLuint
    uView, uAccSize, uTileOrg, uTileInv, uOp, uFast, uMaskLo, uBaseMaskLo, uBaseLut: GLint

  PassSpec = object
    ## (one pass: its program's switches and its inputs)
    kind: PassKind
    mode: BlendMode
    mask: bool
    clip: int                  # 0 none, 1 a layer, 2 a group (its cover)
    baseMask: bool
    lut3: bool
    flags: bool
    tex: array[8, GLuint]      # acc, src, mask, base, base mask, cover, mode table, adjustment table
    op, fast, maskLo, baseMaskLo, baseLut: float32

const
  UAcc = 0
  USrc = 1
  UMask = 2
  UBase = 3
  UBaseMask = 4
  UCov = 5
  USep = 6
  ULut = 7

# ---- what is kept on the GPU ---------------------------------------------------------------------------

type
  TileTex = object
    tex: GLuint
    ver, docVer: int
    doc, pxp: pointer          # (the document and pixels it was sent from)

  LayerTex = object
    layer: Layer               # (held: its key stays this layer)
    w, h, ts, gx, gy: int
    tiles: seq[TileTex]
    fkey: string               # (a feathered mask) what it was made from
    used: int
    usedAt: MonoTime

  LutTex = object
    tex: GLuint
    lut3: bool
    used: int

var
  progs: Table[int, Prog]
  progBad: Table[int, bool]
  quadVbo: GLuint
  sepTex: array[BlendMode, GLuint]
  texCache: Table[(pointer, bool), LayerTex]
  lutCache: Table[Hash, LutTex]
  poolTex, poolFbo: seq[GLuint]
  poolRefs: seq[int]
  poolFree: seq[int]
  poolW, poolH: int
  bound: array[8, GLuint]      # (what each unit has, to keep a pass's target off them)
  epochSeen = -1
  genSeen = -1
  broken = false               # (this context: the GPU failed, or mixes wrongly)
  failures = 0                 # (... failed so many times in a row)
  tested = false
  compiledNow = false
  stamp = 0                    # (composites made: for what was used last)
  lastSweep: MonoTime          # (when what was not used for a while was last given back)
  poolUsedAt: MonoTime
  scratch: seq[uint32]
  readBuf: seq[uint32]
  # the tile being made
  curW, curH: int
  curOrgX, curOrgY: int
  curInvX, curInvY: float32

proc forgetAll() =
  ## Everything on the GPU forgotten (not given back: its context is gone).
  progs.clear()
  progBad.clear()
  quadVbo = 0
  for m in BlendMode: sepTex[m] = 0
  texCache.clear()
  lutCache.clear()
  poolTex.setLen(0)
  poolFbo.setLen(0)
  poolRefs.setLen(0)
  poolFree.setLen(0)
  poolW = 0
  poolH = 0
  for b in bound.mitems: b = 0

proc delTex(t: GLuint) =
  if t != 0:
    var id = t
    gpuGl().deleteTextures(1, addr id)

proc freeEntry(e: var LayerTex) =
  for t in e.tiles: delTex(t.tex)
  e.tiles.setLen(0)

proc freePool() =
  let gl = gpuGl()
  for i in 0 ..< poolTex.len:
    var f = poolFbo[i]
    if f != 0: gl.deleteFramebuffers(1, addr f)
    delTex(poolTex[i])
  poolTex.setLen(0)
  poolFbo.setLen(0)
  poolRefs.setLen(0)
  poolFree.setLen(0)
  poolW = 0
  poolH = 0

proc releaseGpuComposite*() =
  ## Gives back all the GPU holds for mixing layers (the layers' textures
  ## too: sent again when next needed) -- when memory is short, a document
  ## closed. Nothing happens off the GPU's thread.
  if gpuFiltersReady() and gpuEpoch() == epochSeen:
    let gl = gpuGl()
    for e in texCache.mvalues: freeEntry(e)
    for e in lutCache.values: delTex(e.tex)
    for m in BlendMode: delTex(sepTex[m])
    freePool()
    for p in progs.values: gl.deleteProgram(p.id)
    if quadVbo != 0: gl.deleteBuffers(1, addr quadVbo)
  forgetAll()

proc sweep() =
  ## (every 5 seconds at most) The textures of layers not used for a minute
  ## given back -- and the layers let go: a closed document's are not kept.
  let now = getMonoTime()
  if (now - lastSweep).inSeconds < 5: return
  lastSweep = now
  if (texCache.len == 0 and poolTex.len == 0) or not gpuFiltersReady() or gpuEpoch() != epochSeen: return
  var gone: seq[(pointer, bool)]
  for k, e in texCache:
    if (now - e.usedAt).inSeconds >= 60: gone.add k
  for k in gone:
    freeEntry(texCache[k])
    texCache.del k
  if poolTex.len > 0 and (now - poolUsedAt).inSeconds >= 60: freePool()

proc tileBytes(e: LayerTex): int =
  for i, t in e.tiles:
    if t.tex != 0:
      let tx = i mod e.gx
      let ty = i div e.gx
      result += min(e.ts, e.w - tx * e.ts) * min(e.ts, e.h - ty * e.ts) * 4

proc cachedBytes(): int =
  for e in texCache.values: result += tileBytes(e)
  result += poolTex.len * poolW * poolH * 4

# ---- programs --------------------------------------------------------------------------------------

proc progKey(s: PassSpec): int =
  ord(s.kind) or (ord(s.mode) shl 4) or (ord(s.mask) shl 9) or (s.clip shl 10) or
    (ord(s.baseMask) shl 12) or (ord(s.lut3) shl 13) or (ord(s.flags) shl 14)

proc defines(s: PassSpec): string =
  template d(name: string; v: int) = result.add "#define " & name & " " & $v & "\n"
  d("K_LAYER", ord(pkLayer)); d("K_COVER_LAYER", ord(pkCoverLayer)); d("K_ADJ", ord(pkAdj))
  d("K_POPISO", ord(pkPopIso)); d("K_COVER_POP", ord(pkCoverPop)); d("K_COVPOP", ord(pkCovPop))
  d("K_LERP", ord(pkLerp)); d("K_COVSCALE", ord(pkCovScale)); d("K_COPY", ord(pkCopy))
  d("M_NORMAL", ord(bmNormal)); d("M_HUE", ord(bmHue)); d("M_SAT", ord(bmSaturation))
  d("M_COLOR", ord(bmColor)); d("M_LUM", ord(bmLuminosity)); d("M_DARKER", ord(bmDarkerColor))
  d("M_LIGHTER", ord(bmLighterColor))
  d("KIND", ord(s.kind))
  d("MODE", ord(s.mode))
  d("QUICK", ord(s.mode == bmNormal or s.mode in SepSet))
  d("SEPM", ord(s.mode in SepSet))
  d("NONSEPM", ord(s.mode in NonSepSet))
  d("HAS_MASK", ord(s.mask))
  d("CLIP", s.clip)
  d("BASE_MASK", ord(s.baseMask))
  d("LUT3", ord(s.lut3))
  d("FLAGS", ord(s.flags))
  result.add "#define NEAR_HALF " & $nearHalf & "\n"

proc getProg(s: PassSpec): Prog =
  let k = progKey(s)
  progs.withValue(k, p):
    return p[]
  if progBad.hasKey(k): return Prog()
  let gl = gpuGl()
  let id = gpuCompileProgram(VertexSrc, defines(s) & FragmentSrc, ["aPos"], needHigh = true)
  compiledNow = true
  if id == 0:
    dbg("a program failed: " & $s.kind & " " & $s.mode)
    progBad[k] = true
    return Prog()
  template loc(n: string): GLint = gl.getUniformLocation(id, cstring(n))
  result = Prog(id: id, uView: loc("uView"), uAccSize: loc("uAccSize"), uTileOrg: loc("uTileOrg"),
                uTileInv: loc("uTileInv"), uOp: loc("uOp"), uFast: loc("uFast"), uMaskLo: loc("uMaskLo"),
                uBaseMaskLo: loc("uBaseMaskLo"), uBaseLut: loc("uBaseLut"))
  gl.useProgram(id)
  for (n, u) in [("uAcc", UAcc), ("uSrc", USrc), ("uMask", UMask), ("uBase", UBase),
                 ("uBaseMask", UBaseMask), ("uCov", UCov), ("uSep", USep), ("uLut", ULut)]:
    let l = loc(n)
    if l >= 0: gl.uniform1i(l, GLint(u))
  progs[k] = result

# ---- textures ----------------------------------------------------------------------------------------------

proc newTex(w, h: int; fmt: GLenum; data: pointer): GLuint =
  let gl = gpuGl()
  gl.genTextures(1, addr result)
  gl.activeTexture(GL_TEXTURE0)
  gl.bindTexture(GL_TEXTURE_2D, result)
  bound[0] = result
  gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
  gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
  gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
  gl.texParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
  gl.pixelStorei(GL_UNPACK_ALIGNMENT, (if fmt == GL_ALPHA: 1 else: 4))
  gl.texImage2D(GL_TEXTURE_2D, 0, GLint(fmt), GLsizei(w), GLsizei(h), 0, fmt, GL_UNSIGNED_BYTE, data)

proc sepTexture(m: BlendMode): GLuint =
  ## The CPU's table of mode `m` (under x 256 + over), as the GPU reads it.
  if sepTex[m] != 0: return sepTex[m]
  var t = newSeq[uint8](65536)
  for cb in 0 .. 255:
    for cs in 0 .. 255: t[cb * 256 + cs] = uint8(clamp(sepBlend(m, cb, cs), 0, 255))
  sepTex[m] = newTex(256, 256, GL_ALPHA, addr t[0])
  sepTex[m]

proc lutTexture(lut: ptr seq[uint32]): LutTex =
  ## An adjustment layer's table on the GPU: three of 256 when each channel
  ## follows its own, else all 33 x 33 x 33 colors.
  let h = hash(lut[])
  lutCache.withValue(h, e):
    e.used = stamp
    return e[]
  let t1 = channelTables(lut[])
  if t1.len == 768:
    var px = newSeq[uint32](256)
    for x in 0 .. 255:
      px[x] = 0xFF000000'u32 or (uint32(t1[x]) shl 16) or (uint32(t1[256 + x]) shl 8) or uint32(t1[512 + x])
    result = LutTex(tex: newTex(256, 1, GL_RGBA, addr px[0]), lut3: false, used: stamp)
  else:
    var px = lut[]
    result = LutTex(tex: newTex(LutSide * LutSide, LutSide, GL_RGBA, addr px[0]), lut3: true, used: stamp)
  if lutCache.len > 48:
    var old: seq[Hash]
    for k, e in lutCache:
      if stamp - e.used > 8: old.add k
    for k in old:
      delTex(lutCache[k].tex)
      lutCache.del k
  lutCache[h] = result

proc tileRectOf(e: LayerTex; i: int): Rect =
  let tx = i mod e.gx
  let ty = i div e.gx
  rect(tx * e.ts, ty * e.ts, min(e.ts, e.w - tx * e.ts), min(e.ts, e.h - ty * e.ts))

proc entryFor(L: Layer; feathered: bool; d: Doc; ts: int): ptr LayerTex =
  ## The textures of layer `L` (its pixels; `feathered`: its mask as
  ## feathered), made anew when it is another or the document another size.
  result = addr texCache.mgetOrPut((cast[pointer](L), feathered), LayerTex())
  if result.layer != L or result.w != d.w or result.h != d.h or result.ts != ts:
    freeEntry(result[])
    let gx = (d.w + ts - 1) div ts
    let gy = (d.h + ts - 1) div ts
    result[] = LayerTex(layer: L, w: d.w, h: d.h, ts: ts, gx: gx, gy: gy, tiles: newSeq[TileTex](gx * gy))
  result.used = stamp
  result.usedAt = getMonoTime()

proc sendRect(t: var TileTex; tr: Rect; src: ptr UncheckedArray[uint32]; w: int; r: Rect) =
  ## Rectangle `r` (image pixels, in tile `tr`) of the pixels `src` (`w`
  ## wide) sent to the tile's texture (all of it made when `r` is `tr`).
  let gl = gpuGl()
  scratch.setLen(r.w * r.h)
  for y in 0 ..< r.h:
    copyMem(addr scratch[y * r.w], addr src[(r.y + y) * w + r.x], r.w * 4)
  if t.tex == 0 or r == tr:
    if t.tex == 0:
      t.tex = newTex(tr.w, tr.h, GL_RGBA, addr scratch[0])
    else:
      gl.activeTexture(GL_TEXTURE0)
      gl.bindTexture(GL_TEXTURE_2D, t.tex)
      bound[0] = t.tex
      gl.pixelStorei(GL_UNPACK_ALIGNMENT, 4)
      gl.texImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA), GLsizei(tr.w), GLsizei(tr.h), 0, GL_RGBA,
                    GL_UNSIGNED_BYTE, addr scratch[0])
  else:
    gl.activeTexture(GL_TEXTURE0)
    gl.bindTexture(GL_TEXTURE_2D, t.tex)
    bound[0] = t.tex
    gl.pixelStorei(GL_UNPACK_ALIGNMENT, 4)
    gl.texSubImage2D(GL_TEXTURE_2D, 0, GLint(r.x - tr.x), GLint(r.y - tr.y), GLsizei(r.w), GLsizei(r.h),
                     GL_RGBA, GL_UNSIGNED_BYTE, addr scratch[0])
  gpuCompositeStats.uploadedPixels += r.w * r.h

proc syncTile(e: ptr LayerTex; i: int; L: Layer; d: Doc): GLuint =
  ## Tile `i` of layer `L`'s texture brought up to date: sent whole when new
  ## (or its pixels another buffer, or from another document), else -- when
  ## the layer changed (`ver`) -- what changed in the document since.
  let tr = e[].tileRectOf(i)
  let t = addr e.tiles[i]
  let src = cast[ptr UncheckedArray[uint32]](unsafeAddr L.px[0])
  let pxp = cast[pointer](src)
  if t.tex == 0 or t.doc != cast[pointer](d) or t.pxp != pxp:
    sendRect(t[], tr, src, d.w, tr)
  elif t.ver != L.ver:
    let r = intersect(d.changedSince(t.docVer), tr)
    if r.w > 0 and r.h > 0: sendRect(t[], tr, src, d.w, r)
  t.ver = L.ver
  t.docVer = d.ver
  t.doc = cast[pointer](d)
  t.pxp = pxp
  t.tex

proc syncFeathered(e: ptr LayerTex; owner, m: Layer; d: Doc): bool =
  ## A feathered mask (as photo's `maskOf` makes it, but for its density:
  ## the shader's) on the GPU, all its tiles, made again when it changed.
  let key = $m.ver & "/" & $cast[int](m) & "/" & $owner.maskFeather & "/" & $m.px.len & "/" &
            $cast[int](unsafeAddr m.px[0])
  var whole = e.fkey == key
  for t in e.tiles:
    if t.tex == 0: whole = false
  if whole: return true
  var g = newSeqUninit[uint8](m.px.len)
  for i in 0 ..< m.px.len: g[i] = uint8((m.px[i] shr 16) and 255)
  blurMask(g, d.w, d.h, owner.maskFeather)
  var gray = newSeqUninit[uint32](g.len)
  for i in 0 ..< g.len:
    let v = uint32(g[i])
    gray[i] = 0xFF000000'u32 or (v shl 16) or (v shl 8) or v
  let src = cast[ptr UncheckedArray[uint32]](addr gray[0])
  for i in 0 ..< e.tiles.len:
    let tr = e[].tileRectOf(i)
    sendRect(e.tiles[i], tr, src, d.w, tr)
  e.fkey = key
  true

# ---- the composite, planned as the CPU's (photo's `compositeItems`) ---------------------------------------

type
  GKind = enum gkLayer, gkPush, gkPop

  GItem = object
    kind: GKind
    src: Layer                 # (a layer) its pixels
    maskL: Layer               # its mask (or its group's), nil none
    maskOwner: Layer           # ... whose it is (feathering)
    feather: bool
    maskLo: int                # (the mask's density: 0 all of it)
    lut: ptr seq[uint32]
    filt: bool
    op, fill: int
    mode: BlendMode
    base: int
    isolated: bool
    level: int
    cov: bool
    pair: int

  Plan = object
    items: seq[GItem]
    maxDepth: int
    why: string                # not done on the GPU: why ("" done)

proc setMask(it: var GItem; L: Layer; d: Doc): bool =
  ## (as photo's `maskOf`; false: a mask the GPU cannot take)
  let m = L.mask
  if m == nil or L.maskOff or m.px.len != L.px.len or m.px.len == 0: return true
  if m.px.len != d.w * d.h: return false
  it.maskL = m
  it.maskOwner = L
  it.feather = L.maskFeather > 0.05
  it.maskLo = (100 - L.maskDensity) * 255 div 100
  true

proc planOf(d: Doc): Plan =
  ## The steps of the composite as the CPU takes them, or why they cannot
  ## be taken on the GPU.
  if d.depth != 8:
    result.why = $d.depth & "-bit"
    return
  let layers = d.layers
  var items: seq[GItem]
  let parents = parentsOf(layers)
  type Level = object
    g: int
    shown: bool
    push: int
  var open: seq[Level]
  var base = -1
  var baseShown = false
  var first = true
  var hidden = 0
  var maxDepth = 0
  var why = ""
  proc isShown(L: Layer): bool = L.visible and L.opacity > 0
  template beginGroup(gi: int) =
    let G = layers[gi]
    let sh = hidden == 0 and isShown(G)
    open.add Level(g: gi, shown: sh)
    if sh:
      items.add GItem(kind: gkPush, isolated: not G.passThrough, level: open.len, base: -1)
      open[^1].push = items.high
      maxDepth = max(maxDepth, open.len)
    else: inc hidden
    base = -1
    baseShown = false
    first = true
  template endGroup() =
    let lv = open.pop()
    let G = layers[lv.g]
    base = -1
    if lv.shown:
      var it = GItem(kind: gkPop, isolated: not G.passThrough, op: G.opacity * 255 div 100,
                     mode: G.mode, base: -1, level: open.len + 1, pair: lv.push)
      if not it.setMask(G, d): why = "a group's mask of another size"
      if it.isolated and G.mode in BadModes: why = "a group in " & $G.mode
      items.add it
      base = items.high
    else: dec hidden
    baseShown = lv.shown
    first = false
  for i, L in layers:
    var chain: seq[int]
    var par = parents[i]
    while par >= 0:
      chain.add par
      par = parents[par]
    chain.reverse()
    if L.group: chain.add i
    var k = 0
    while k < open.len and k < chain.len and open[k].g == chain[k]: inc k
    while open.len > k: endGroup()
    for j in k ..< chain.len: beginGroup(chain[j])
    if L.group:
      endGroup()
      continue
    if hidden > 0: continue
    let shown = isShown(L) and L.px.len == d.w * d.h
    if L.clipped and not first:
      if not baseShown: continue
    else:
      baseShown = shown
      base = -1
    first = false
    if not shown: continue
    var lut: ptr seq[uint32] = nil
    let filt = L.adjust.kind in AreaAdjustKinds
    if L.adjust.kind.len > 0 and not filt:
      lut = lutOf(L)
      if lut == nil: continue
    var it = GItem(kind: gkLayer, src: L, lut: lut, filt: filt, op: L.opacity * 255 div 100,
                   fill: L.fill * 255 div 100, mode: L.mode)
    if not it.setMask(L, d): why = "a mask of another size"
    if L.clipped and base >= 0:
      it.base = base
      if items[base].kind == gkPop:
        items[base].cov = true
        items[items[base].pair].cov = true
    else:
      it.base = -1
      base = items.len
    if L.blendIf.isOn: why = "Blend If"
    if lut == nil and not filt:
      if L.mode in BadModes: why = $L.mode
      if L.hasFx and layerFxRender != nil: why = "a layer style"
    elif lut != nil and L.mode in BadModes: why = $L.mode
    if filt and open.len == 0: why = L.adjust.kind
    items.add it
  while open.len > 0: endGroup()
  # (masks and filters: none hidden in a step not shown)
  result = Plan(items: items, maxDepth: maxDepth, why: why)

proc gpuCompositeSupport*(d: Doc): string =
  ## Why `d`'s composite is not made on the GPU -- a feature it does not
  ## do -- or "" when it can be.
  planOf(d).why

# ---- the passes -------------------------------------------------------------------------------------------

proc acquire(): int =
  ## A texture of the tile's size to draw into (its framebuffer bound).
  let gl = gpuGl()
  if poolFree.len > 0:
    result = poolFree.pop()
    poolRefs[result] = 1
    return
  let t = newTex(poolW, poolH, GL_RGBA, nil)
  var f: GLuint
  gl.genFramebuffers(1, addr f)
  gl.bindFramebuffer(GL_FRAMEBUFFER, f)
  gl.framebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t, 0)
  if gl.checkFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE:
    gl.deleteFramebuffers(1, addr f)
    delTex(t)
    return -1
  poolTex.add t
  poolFbo.add f
  poolRefs.add 1
  poolTex.high

proc retain(s: int) =
  if s >= 0: inc poolRefs[s]

proc release(s: int) =
  if s >= 0:
    dec poolRefs[s]
    if poolRefs[s] == 0: poolFree.add s

proc texOf(s: int): GLuint = (if s >= 0: poolTex[s] else: 0)

proc cleared(): int =
  ## A new texture, all transparent.
  result = acquire()
  if result < 0: return
  let gl = gpuGl()
  gl.bindFramebuffer(GL_FRAMEBUFFER, poolFbo[result])
  gl.clearColor(0, 0, 0, 0)
  gl.clear(GL_COLOR_BUFFER_BIT)

proc draw(s: PassSpec; target: int): bool =
  ## One pass into `target`.
  let p = getProg(s)
  if p.id == 0 or target < 0: return false
  let gl = gpuGl()
  let tt = poolTex[target]
  # (the target on no unit: no loop from it to itself)
  for u in 0 ..< 8:
    if bound[u] == tt and s.tex[u] != tt:
      gl.activeTexture(GL_TEXTURE0 + uint32(u))
      gl.bindTexture(GL_TEXTURE_2D, 0)
      bound[u] = 0
  for u in 0 ..< 8:
    let t = s.tex[u]
    if t != 0 and bound[u] != t:
      gl.activeTexture(GL_TEXTURE0 + uint32(u))
      gl.bindTexture(GL_TEXTURE_2D, t)
      bound[u] = t
  gl.bindFramebuffer(GL_FRAMEBUFFER, poolFbo[target])
  gl.viewport(0, 0, GLsizei(curW), GLsizei(curH))
  gl.useProgram(p.id)
  if p.uView >= 0: gl.uniform2f(p.uView, GLf32(curW), GLf32(curH))
  if p.uAccSize >= 0: gl.uniform2f(p.uAccSize, GLf32(poolW), GLf32(poolH))
  if p.uTileOrg >= 0: gl.uniform2f(p.uTileOrg, GLf32(curOrgX), GLf32(curOrgY))
  if p.uTileInv >= 0: gl.uniform2f(p.uTileInv, curInvX, curInvY)
  if p.uOp >= 0: gl.uniform1f(p.uOp, s.op)
  if p.uFast >= 0: gl.uniform1f(p.uFast, s.fast)
  if p.uMaskLo >= 0: gl.uniform1f(p.uMaskLo, s.maskLo)
  if p.uBaseMaskLo >= 0: gl.uniform1f(p.uBaseMaskLo, s.baseMaskLo)
  if p.uBaseLut >= 0: gl.uniform1f(p.uBaseLut, s.baseLut)
  gl.drawArrays(GL_TRIANGLES, 0, 6)
  inc gpuCompositeStats.passes
  true

proc fixPixels(d: Doc; c: Rect; flags: seq[uint32]) =
  ## The pixels of part `c` the GPU could not be sure of (`flags`, `c.w`
  ## wide) made again by the CPU: those of each row alone.
  var xs: seq[int32]
  var o: seq[uint32]
  for y in 0 ..< c.h:
    xs.setLen(0)
    for x in 0 ..< c.w:
      if (flags[y * c.w + x] and 0xFF'u32) != 0: xs.add int32(c.x + x)
    if xs.len == 0: continue
    let iy = c.y + y
    if d.live.len == 0 and xs.len * 2 < c.w:
      d.compositeSampled(xs, @[int32(iy)], o)
      for i, x in xs: d.comp[iy * d.w + int(x)] = o[i]
    else:
      d.compositeInto(d.comp, rect(int(xs[0]), iy, int(xs[^1] - xs[0]) + 1, 1), d.layers)
    gpuCompositeStats.fixedPixels += xs.len

proc runTile(d: Doc; plan: Plan; c: Rect; tx, ty, ts: int): bool =
  ## Part `c` (in tile `tx`, `ty`) made on the GPU and read back into `comp`.
  let gl = gpuGl()
  let items = plan.items
  let n = items.len
  let tr = rect(tx * ts, ty * ts, min(ts, d.w - tx * ts), min(ts, d.h - ty * ts))
  curW = c.w
  curH = c.h
  curOrgX = c.x - tr.x
  curOrgY = c.y - tr.y
  curInvX = GLf32(1.0 / float(tr.w))
  curInvY = GLf32(1.0 / float(tr.h))
  # the layers' and masks' textures for this tile, brought up to date
  var srcTex = newSeq[GLuint](n)
  var maskTex = newSeq[GLuint](n)
  var lutTex = newSeq[LutTex](n)
  for k in 0 ..< n:
    let it = items[k]
    if it.kind == gkLayer:
      let e = entryFor(it.src, false, d, ts)
      srcTex[k] = syncTile(e, ty * e.gx + tx, it.src, d)
      if it.lut != nil: lutTex[k] = lutTexture(it.lut)
    if it.maskL != nil:
      if it.feather:
        let e = entryFor(it.maskOwner, true, d, ts)
        if not syncFeathered(e, it.maskOwner, it.maskL, d): return false
        maskTex[k] = e.tiles[ty * e.gx + tx].tex
      else:
        let e = entryFor(it.maskL, false, d, ts)
        maskTex[k] = syncTile(e, ty * e.gx + tx, it.maskL, d)
  # the steps, as the CPU's `mixLayers` takes them along a row
  let depthN = plan.maxDepth
  var phys = @[cleared()]                   # (the levels' pixels so far: a group mixed on
  if phys[0] < 0: return false              # its own has its own, one mixing through not)
  var accOf = newSeq[int](depthN + 1)
  var saved = newSeq[int](depthN + 1)
  var covs = newSeq[int](depthN + 1)
  var covOn = newSeq[bool](depthN + 1)
  for l in 0 .. depthN:
    saved[l] = -1
    covs[l] = -1
  var lvl = 0
  var covers = 0
  var bare = true
  var flagSlot = -1
  var ok = true
  template setSlot(dst: var int; s: int) =
    release(dst)
    dst = s
  template fresh(): int =
    block:
      let s = acquire()
      if s < 0: ok = false
      s
  proc spec(kind: PassKind; it: GItem; k: int): PassSpec =
    result = PassSpec(kind: kind, mode: bmNormal, op: float32(it.op))
    if it.maskL != nil:
      result.mask = true
      result.tex[UMask] = maskTex[k]
      result.maskLo = float32(it.maskLo)
  template withClip(s: var PassSpec; it: GItem) =
    let bk = it.base
    if bk >= 0:
      if items[bk].kind == gkPop:
        s.clip = 2
        s.tex[UCov] = texOf(covs[items[bk].level])
      else:
        s.clip = 1
        s.tex[UBase] = srcTex[bk]
        if items[bk].lut != nil: s.baseLut = 1
        if items[bk].maskL != nil:
          s.baseMask = true
          s.tex[UBaseMask] = maskTex[bk]
          s.baseMaskLo = float32(items[bk].maskLo)
  template withMode(s: var PassSpec; m: BlendMode) =
    s.mode = m
    if m in SepSet: s.tex[USep] = sepTexture(m)
  template flagPass(s: PassSpec) =
    if s.mode in UnsureModes:
      if flagSlot < 0:
        flagSlot = cleared()
        if flagSlot < 0: ok = false
      if ok:
        var f = s
        f.flags = true
        if not draw(f, flagSlot): ok = false
  for k in 0 ..< n:
    if not ok: break
    let it = items[k]
    case it.kind
    of gkPush:
      let outer = accOf[lvl]
      inc lvl
      if it.isolated:
        let s = cleared()
        if s < 0:
          ok = false
          break
        phys.add s
        accOf[lvl] = phys.high
        covOn[lvl] = false
      else:
        retain(phys[outer])
        setSlot(saved[lvl], phys[outer])
        accOf[lvl] = outer
        covOn[lvl] = it.cov
        if it.cov:
          let s = cleared()
          if s < 0:
            ok = false
            break
          setSlot(covs[lvl], s)
          inc covers
    of gkPop:
      let gl0 = lvl
      let inner = accOf[gl0]
      if covOn[gl0]:
        covOn[gl0] = false
        dec covers
      dec lvl
      if lvl == 0: bare = false
      let outer = accOf[lvl]
      if it.isolated:
        var s = spec(pkPopIso, it, k)
        s.tex[USrc] = poolTex[phys[inner]]
        if it.cov:
          var cs = s
          cs.kind = pkCovPop
          let t = fresh()
          if ok and draw(cs, t): setSlot(covs[gl0], t) else: ok = false
        if covers > 0:
          for l in 1 .. lvl:
            if covOn[l] and ok:
              var cs = s
              cs.kind = pkCoverPop
              cs.tex[UAcc] = poolTex[covs[l]]
              let t = fresh()
              if ok and draw(cs, t): setSlot(covs[l], t) else: ok = false
        s.withMode(it.mode)
        s.tex[UAcc] = poolTex[phys[outer]]
        s.flagPass()
        let t = fresh()
        if ok and draw(s, t): setSlot(phys[outer], t) else: ok = false
        if inner != phys.high: ok = false   # (cannot be: the groups mixed on their own nest)
        release(phys[inner])
        phys.setLen(phys.len - 1)
      else:
        if it.op < 255 or it.maskL != nil:
          var s = spec(pkLerp, it, k)
          s.tex[USrc] = texOf(saved[gl0])
          s.tex[UAcc] = poolTex[phys[outer]]
          let t = fresh()
          if ok and draw(s, t): setSlot(phys[outer], t) else: ok = false
          if it.cov and ok:
            var cs = spec(pkCovScale, it, k)
            cs.tex[UAcc] = texOf(covs[gl0])
            let t2 = fresh()
            if ok and draw(cs, t2): setSlot(covs[gl0], t2) else: ok = false
        setSlot(saved[gl0], -1)
    of gkLayer:
      if it.filt: continue                  # (in a group: not done)
      let p = accOf[lvl]
      let op = it.op * it.fill div 255
      if it.lut != nil:
        var s = spec(pkAdj, it, k)
        s.op = float32(op)
        s.lut3 = lutTex[k].lut3
        s.tex[ULut] = lutTex[k].tex
        s.tex[USrc] = srcTex[k]
        s.tex[UAcc] = poolTex[phys[p]]
        s.withClip(it)
        s.withMode(it.mode)
        s.flagPass()
        let t = fresh()
        if ok and draw(s, t): setSlot(phys[p], t) else: ok = false
        continue
      let fast = it.mode == bmNormal and op == 255 and it.maskL == nil and it.base < 0
      if fast and bare and lvl == 0:
        # (the first layer as it is: its pixels, transparent ones too)
        var s = PassSpec(kind: pkCopy, mode: bmNormal)
        s.tex[USrc] = srcTex[k]
        let t = fresh()
        if ok and draw(s, t): setSlot(phys[p], t) else: ok = false
        bare = false
        continue
      if lvl == 0: bare = false
      var s = spec(pkLayer, it, k)
      s.op = float32(op)
      s.fast = float32(ord(fast))
      s.tex[USrc] = srcTex[k]
      s.withClip(it)
      if covers > 0:
        for l in 1 .. lvl:
          if covOn[l] and ok:
            var cs = s
            cs.kind = pkCoverLayer
            cs.tex[UAcc] = poolTex[covs[l]]
            let t = fresh()
            if ok and draw(cs, t): setSlot(covs[l], t) else: ok = false
      s.withMode(it.mode)
      s.tex[UAcc] = poolTex[phys[p]]
      s.flagPass()
      let t = fresh()
      if ok and draw(s, t): setSlot(phys[p], t) else: ok = false
  if ok and lvl != 0: ok = false
  if ok:
    # read back into the composite
    readBuf.setLen(c.w * c.h)
    gl.bindFramebuffer(GL_FRAMEBUFFER, poolFbo[phys[0]])
    gl.pixelStorei(GL_PACK_ALIGNMENT, 4)
    gl.readPixels(0, 0, GLsizei(c.w), GLsizei(c.h), GL_RGBA, GL_UNSIGNED_BYTE, addr readBuf[0])
    if gl.getError() != GL_NO_ERROR: ok = false
    else:
      for y in 0 ..< c.h:
        copyMem(addr d.comp[(c.y + y) * d.w + c.x], addr readBuf[y * c.w], c.w * 4)
      if flagSlot >= 0:
        gl.bindFramebuffer(GL_FRAMEBUFFER, poolFbo[flagSlot])
        gl.readPixels(0, 0, GLsizei(c.w), GLsizei(c.h), GL_RGBA, GL_UNSIGNED_BYTE, addr readBuf[0])
        if gl.getError() != GL_NO_ERROR: ok = false
        else: fixPixels(d, c, readBuf)
  for s in phys: release(s)
  for l in 0 .. depthN:
    release(saved[l])
    release(covs[l])
  release(flagSlot)
  ok

proc runGpu(d: Doc; c: Rect; plan: Plan): bool =
  ## `comp` in `c` (inside the image) made on the GPU; false when it could
  ## not be (the GPU's memory, an error): the CPU makes it then.
  let gl = gpuGl()
  let ts = max(64, min(gpuCompositeTile, gpuMaxTextureSize()))
  inc stamp
  # (the tiles' textures this takes, and the room for them)
  let pw = min(ts, d.w)
  let ph = min(ts, d.h)
  var need = (4 + 3 * plan.maxDepth) * pw * ph * 4
  var have = 0
  var needed: Table[(pointer, bool), bool]
  let tx0 = c.x div ts
  let tx1 = (c.x + c.w - 1) div ts
  let ty0 = c.y div ts
  let ty1 = (c.y + c.h - 1) div ts
  proc tilesBytes(): int =
    for ty in ty0 .. ty1:
      for tx in tx0 .. tx1:
        result += min(ts, d.w - tx * ts) * min(ts, d.h - ty * ts) * 4
  let perLayer = tilesBytes()
  for it in plan.items:
    if it.kind == gkLayer and not needed.hasKey((cast[pointer](it.src), false)):
      needed[(cast[pointer](it.src), false)] = true
      need += perLayer
    if it.maskL != nil:
      let k = if it.feather: (cast[pointer](it.maskOwner), true) else: (cast[pointer](it.maskL), false)
      if not needed.hasKey(k):
        needed[k] = true
        need += (if it.feather: d.w * d.h * 4 else: perLayer)
  if need > gpuCompositeBudget:
    gpuCompositeStats.lastReason = "too big for the GPU's memory budget"
    return false
  # (what is not needed now given back, the oldest first, as far as the room asks)
  have = cachedBytes()
  if poolW != pw or poolH != ph:
    freePool()
    poolW = pw
    poolH = ph
  if have + need > gpuCompositeBudget or texCache.len > 0:
    var old: seq[(int, (pointer, bool))]
    for k, e in texCache:
      if not needed.hasKey(k): old.add (e.used, k)
    old.sort(proc (a, b: (int, (pointer, bool))): int = cmp(a[0], b[0]))
    for (u, k) in old:
      if have + need <= gpuCompositeBudget and stamp - u < 64: break
      let b = tileBytes(texCache[k])
      freeEntry(texCache[k])
      texCache.del k
      have -= b
  poolUsedAt = getMonoTime()
  let oldFb = gpuBeginOffscreen()
  result = true
  for i in 0 ..< 16:                                # (errors from before: not ours)
    if gl.getError() == GL_NO_ERROR: break
  try:
    for u in 0 ..< 8:                               # (none of ours left bound)
      gl.activeTexture(GL_TEXTURE0 + uint32(u))
      gl.bindTexture(GL_TEXTURE_2D, 0)
      bound[u] = 0
    if quadVbo == 0: gl.genBuffers(1, addr quadVbo)
    var quadV = [-1'f32, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]
    gl.bindBuffer(GL_ARRAY_BUFFER, quadVbo)
    gl.bufferData(GL_ARRAY_BUFFER, sizeof(quadV), addr quadV[0], GL_STREAM_DRAW)
    gl.vertexAttribPointer(0, 2, GL_FLOAT, 0, 8, nil)
    gl.enableVertexAttribArray(0)
    for ty in ty0 .. ty1:
      for tx in tx0 .. tx1:
        let part = intersect(c, rect(tx * ts, ty * ts, ts, ts))
        if part.w <= 0 or part.h <= 0: continue
        if not runTile(d, plan, part, tx, ty, ts):
          result = false
          break
      if not result: break
    if result and gl.getError() != GL_NO_ERROR: result = false
  finally:
    gpuEndOffscreen(oldFb)
    bound[0] = 0xFFFFFFFF'u32                       # (units 0 and 1: the frame's again)
    bound[1] = 0xFFFFFFFF'u32
  if not result:
    gpuCompositeStats.lastReason = "the GPU failed"
    dbg("failed: back to the CPU")
    inc failures
    if failures >= 3:
      dbg("failed three times: not used again (until a new context)")
      broken = true
      releaseGpuComposite()
      epochSeen = gpuEpoch()
      genSeen = if gpuRelays.gpuGeneration != nil: gpuRelays.gpuGeneration() else: 0
  else: failures = 0

# ---- a first check, and the hook ---------------------------------------------------------------------------

proc checkDoc(): Doc =
  ## (a small image of most of what is done here: the GPU must make it as
  ## the CPU does)
  const w = 37
  const h = 29
  let d = newDoc(w, h, 0xFF808080'u32)
  let bg = d.layers[0]
  for y in 0 ..< h:
    for x in 0 ..< w:
      bg.px[y * w + x] = argb(255, x * 7 mod 256, y * 9 mod 256, (x * y * 3) mod 256)
  proc pixLayer(name: string; mode: BlendMode; op: int; seed: int; depth = 0): Layer =
    result = d.newLayer(name)
    result.mode = mode
    result.opacity = op
    result.depth = depth
    for i in 0 ..< w * h:
      let v = int(hash2(i, seed))
      result.px[i] = argb([0, 90, 200, 255][v and 3], (v shr 2) and 255, (v shr 10) and 255, (v shr 18) and 255)
  proc maskOf(seed: int): Layer =
    result = d.newLayer("mask")
    for i in 0 ..< w * h:
      let v = int(hash2(i, seed) and 255)
      result.px[i] = argb(255, v, v, v)
  var L = pixLayer("a", bmNormal, 70, 1)
  L.mask = maskOf(2)
  L.fill = 80
  d.layers.add L
  d.layers.add pixLayer("b", bmMultiply, 100, 3)
  d.layers.add pixLayer("c", bmOverlay, 60, 4)
  L = pixLayer("d", bmColorDodge, 90, 5)
  L.clipped = true
  d.layers.add L
  d.layers.add pixLayer("e", bmHue, 80, 6)
  d.layers.add pixLayer("f", bmColor, 100, 7)
  d.layers.add pixLayer("g", bmLighterColor, 100, 8)
  if adjustmentLut != nil:
    let A = d.newLayer("adjust")
    for i in 0 ..< w * h: A.px[i] = argb(255, (i * 5) and 255, 0, 0)
    A.adjust = Adjustment(kind: "Hue/Saturation", args: @[0.0, 40, 20, 0])
    A.opacity = 80
    d.layers.add A
  # a group mixing through (its cover kept: a layer clipped to it), one mixed on its own
  d.layers.add pixLayer("h", bmScreen, 100, 9, 1)
  var G = Layer(name: "pass", group: true, passThrough: true, opacity: 70, visible: true, mode: bmNormal,
                px: newSeq[uint32](w * h))
  G.mask = maskOf(10)
  d.layers.add G
  L = pixLayer("i", bmNormal, 100, 11)
  L.clipped = true
  d.layers.add L
  d.layers.add pixLayer("j", bmDifference, 100, 12, 1)
  d.layers.add pixLayer("k", bmNormal, 50, 13, 1)
  G = Layer(name: "iso", group: true, opacity: 80, visible: true, mode: bmSoftLight, px: newSeq[uint32](w * h))
  d.layers.add G
  d.markAll()
  d

proc selfCheck(): bool =
  ## The GPU's composite of `checkDoc` against the CPU's: within 1.
  let d = checkDoc()
  let plan = planOf(d)
  if plan.why.len > 0: return true
  var cpu = newSeq[uint32](d.w * d.h)
  d.compositeInto(cpu, d.bounds, d.layers)
  d.comp = newSeq[uint32](d.w * d.h)
  if not runGpu(d, d.bounds, plan):
    dbg("the first check could not run")
    return false
  var worst = 0
  for i in 0 ..< cpu.len:
    for sh in [0, 8, 16, 24]:
      worst = max(worst, abs(int((cpu[i] shr sh) and 255) - int((d.comp[i] shr sh) and 255)))
  dbg("first check: worst " & $worst)
  # (its layers let go: not kept on the GPU)
  for L in d.layers:
    for k in [(cast[pointer](L), false), (cast[pointer](L), true), (cast[pointer](L.mask), false)]:
      if texCache.hasKey(k):
        freeEntry(texCache[k])
        texCache.del k
  worst <= 1

proc gpuCompositeReady*(): bool =
  ## Layers can be mixed on the GPU now: frames drawn with it, on its
  ## thread, its context the one checked (a first composite against the
  ## CPU's, once a context).
  if not gpuCompositeOn or not gpuFiltersReady(): return false
  if gpuRelays.gpuReady != nil and not gpuRelays.gpuReady(): return false
  let gen = if gpuRelays.gpuGeneration != nil: gpuRelays.gpuGeneration() else: 0
  if gpuEpoch() != epochSeen or gen != genSeen:
    forgetAll()
    epochSeen = gpuEpoch()
    genSeen = gen
    broken = false
    tested = false
    failures = 0
  if broken: return false
  if not tested:
    tested = true
    var units: GLint
    gpuGl().getIntegerv(GL_MAX_TEXTURE_IMAGE_UNITS, addr units)
    if units < 8 or gpuMaxTextureSize() < LutSide * LutSide:
      dbg("too few texture units, or too small textures")
      broken = true
    elif not selfCheck():
      dbg("the GPU does not mix as the CPU: not used")
      broken = true
      releaseGpuComposite()
      epochSeen = gpuEpoch()
      genSeen = gen
  not broken

proc gpuComposite*(d: Doc; r: Rect): bool =
  ## Makes `d.comp` in `r` on the GPU now (whatever its size; `comp` must be
  ## there, as big as the image): false when it is not done -- the GPU not
  ## ready, a feature not done there (`gpuCompositeSupport`) -- and the CPU
  ## must make it.
  let c = intersect(r, d.bounds)
  if c.w <= 0 or c.h <= 0: return true
  if d.comp.len != d.w * d.h: return false
  if not gpuCompositeReady():
    gpuCompositeStats.lastReason = "no GPU"
    return false
  let plan = planOf(d)
  if plan.why.len > 0:
    gpuCompositeStats.lastReason = plan.why
    return false
  if not runGpu(d, c, plan): return false
  inc gpuCompositeStats.gpu
  true

proc compositeHook(d: Doc; r: Rect): bool {.nimcall.} =
  ## (`photo.gpuCompositeHook`) A big part made on the GPU, or on the CPU
  ## when the guard finds the CPU quicker -- each timed.
  if not gpuCompositeOn or getEnv("RETRO_GPU_COMPOSITE") == "0": return false
  sweep()
  let c = intersect(r, d.bounds)
  let px = c.w * c.h
  if px < gpuCompositeMinPixels or d.comp.len != d.w * d.h: return false
  if not gpuCompositeReady(): return false
  let plan = planOf(d)
  if plan.why.len > 0:
    inc gpuCompositeStats.declined
    gpuCompositeStats.lastReason = plan.why
    return false
  let steps = plan.items.len + 1
  let t0 = getMonoTime()
  if not gpuCompositeGuard.useGpu(px, steps):
    d.compositeInto(d.comp, c, d.layers)
    gpuCompositeGuard.record(false, px, steps, (getMonoTime() - t0).inNanoseconds.float / 1e9)
    inc gpuCompositeStats.cpu
    return true
  compiledNow = false
  if not runGpu(d, c, plan):
    inc gpuCompositeStats.declined
    return false
  inc gpuCompositeStats.gpu
  # (not counted when it made programs: that is once)
  if not compiledNow:
    gpuCompositeGuard.record(true, px, steps, (getMonoTime() - t0).inNanoseconds.float / 1e9)
  true

proc enableGpuComposite*(on = true) =
  ## Lets `updateComposite` mix big parts on the GPU (when frames are drawn
  ## with it), or not.
  gpuCompositeHook = if on: compositeHook else: nil
