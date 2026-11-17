/* Retro Nim UI: the photo engine's hottest loops, four lanes at a time
 * (retroui/simd). Written once with the compilers' own vectors -- GCC's and
 * Clang's vector_size -- so the same code is SSE2/AVX on x86, NEON on ARM
 * and SIMD128 in a web page (when built with -msimd128), and lane by lane
 * where there is none. Each kernel gives exactly what the plain Nim loop it
 * stands for gives, but for the float ones, which round as floats do.
 *
 * Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net */
#ifndef RETRO_SIMDKERN_H
#define RETRO_SIMDKERN_H
#include <stdint.h>
#include <string.h>

#if defined(__GNUC__) || defined(__clang__)
#define RUI_VEC 1
#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wpsabi"   /* (32-bit x86 without SSE: the vectors in pairs of registers, inline) */
#define RUI_POP 1
#endif
typedef uint32_t rui_u4 __attribute__((vector_size(16)));
typedef float rui_f4 __attribute__((vector_size(16)));
#else
#define RUI_VEC 0
#endif

#if RUI_VEC
typedef int32_t rui_i4v __attribute__((vector_size(16)));
typedef uint8_t rui_b16 __attribute__((vector_size(16)));
typedef uint16_t rui_h8 __attribute__((vector_size(16)));
#if defined(__clang__) || __GNUC__ >= 12
#define RUI_SHUF(T, a, b, ...) __builtin_shufflevector(a, b, __VA_ARGS__)
#else
#define RUI_SHUF(T, a, b, ...) __builtin_shuffle(a, b, (T){__VA_ARGS__})
#endif
/* a pixel's four bytes (b, g, r, a in memory) as four whole numbers: two interleavings with
 * zeros (punpcklbw, punpcklwd on x86; a byte at a time would be a dozen instructions) */
static inline rui_u4 rui_bytes4(uint32_t p) {
  rui_u4 v = {p, 0, 0, 0};
  rui_b16 b = (rui_b16)v, z = {0};
  rui_h8 h = (rui_h8)RUI_SHUF(rui_b16, b, z, 0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23);
  rui_h8 hz = {0};
  return (rui_u4)RUI_SHUF(rui_h8, h, hz, 0, 8, 1, 9, 2, 10, 3, 11);
}
/* ... as four floats */
static inline rui_f4 rui_px4(uint32_t p) { return __builtin_convertvector((rui_i4v)rui_bytes4(p), rui_f4); }
#endif

static inline uint32_t rui_c255(int v) { return v < 0 ? 0u : (v > 255 ? 255u : (uint32_t)v); }

/* x / 255 for 0 <= x <= 65535, exactly: (x * 0x8081) >> 23 */
#define RUI_DIV255(x) (((x) * 0x8081u) >> 23)

static inline uint32_t rui_over1(uint32_t d, uint32_t s, uint32_t ea, const uint8_t* lut) {
  uint32_t ia = 255 - ea;
  uint32_t dr = (d >> 16) & 255, dg = (d >> 8) & 255, db = d & 255;
  uint32_t sr = (s >> 16) & 255, sg = (s >> 8) & 255, sb = s & 255;
  if (lut) { sr = lut[dr << 8 | sr]; sg = lut[dg << 8 | sg]; sb = lut[db << 8 | sb]; }
  return 0xFF000000u | (RUI_DIV255(sr * ea + dr * ia) << 16) | (RUI_DIV255(sg * ea + dg * ia) << 8) |
         RUI_DIV255(sb * ea + db * ia);
}

/* What a layer's pixel is mixed by besides its opacity (retroui/photo's clipAmt and Blend If):
 * each pointer indexed by the document's column, NULL when it has none. */
typedef struct {
  const uint32_t* mask;      /* its layer mask (gray: the red byte) */
  const uint32_t* cover;     /* clipped to a group: how much the group covers (0..255 a pixel) */
  const uint32_t* base;      /* clipped to a layer: that layer's pixels (its alpha) ... */
  const uint32_t* bmask;     /* ... and its mask */
  int blut;                  /* ... an adjustment layer: its alpha times its mask's red */
  int bif, ch;               /* Blend If, by channel `ch` (0 gray, 1 red, 2 green, 3 blue) */
  const uint8_t* thisT;      /* ... how much each value of this layer lets it show (256) */
  const uint8_t* underT;     /* ... and each value of what is under it */
} rui_mixopt;

static inline uint32_t rui_chan(uint32_t p, int ch) {
  switch (ch) {
  case 1: return (p >> 16) & 255;
  case 2: return (p >> 8) & 255;
  case 3: return p & 255;
  default: return (((p >> 16) & 255) * 77 + ((p >> 8) & 255) * 151 + (p & 255) * 28) >> 8;
  }
}

/* (one pixel's amount, 0..255, as the plain loop works it out: each step rounded down) */
static inline uint32_t rui_amt1(const rui_mixopt* o, int x, uint32_t op, uint32_t s, uint32_t d) {
  uint32_t a = op;
  if (o->mask) a = RUI_DIV255(a * ((o->mask[x] >> 16) & 255));
  if (o->cover) a = RUI_DIV255(a * o->cover[x]);
  else if (o->base) {
    uint32_t b = o->base[x], ba = b >> 24;
    if (o->blut) ba = RUI_DIV255(((b >> 16) & 255) * ba);
    if (o->bmask) ba = RUI_DIV255(ba * ((o->bmask[x] >> 16) & 255));
    a = RUI_DIV255(a * ba);
  }
  if (o->bif) a = RUI_DIV255(RUI_DIV255(a * o->thisT[rui_chan(s, o->ch)]) * o->underT[rui_chan(d, o->ch)]);
  return a;
}

#define RUI_CAT2(a, b) a##b
#define RUI_CAT(a, b) RUI_CAT2(a, b)

/* (the mixing kernels, four pixels at a time -- and eight with AVX2 where the processor has
 * it: simdmix.h is the same code for both) */
#define RUI_N 4
#define RUI_SFX _4
#define RUI_ATTR
#include "simdmix.h"
#undef RUI_N
#undef RUI_SFX
#undef RUI_ATTR

#if RUI_VEC && (defined(__x86_64__) || defined(__i386__)) && !defined(RUI_NO_AVX2)
#include <cpuid.h>
#define RUI_AVX2 1
#define RUI_N 8
#define RUI_SFX _8
#define RUI_ATTR __attribute__((target("avx2")))
#include "simdmix.h"
#undef RUI_N
#undef RUI_SFX
#undef RUI_ATTR
/* Whether the processor (and the system: its registers saved) has AVX2 -- asked once;
 * `rui_force_avx2` (0 or 1) settles it for a test. */
static volatile int rui_avx2_state = -1;
static inline int rui_has_avx2(void) {
  int v = rui_avx2_state;
  if (v >= 0) return v;
  unsigned a = 0, b = 0, c = 0, d = 0;
  v = 0;
  if (__get_cpuid(1, &a, &b, &c, &d) && (c & (1u << 27)) && (c & (1u << 28))) {
    unsigned lo, hi;
    __asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
    (void)hi;
    if ((lo & 6) == 6 && __get_cpuid_count(7, 0, &a, &b, &c, &d) && (b & (1u << 5))) v = 1;
  }
  rui_avx2_state = v;
  return v;
}
#else
#define RUI_AVX2 0
static inline int rui_has_avx2(void) { return 0; }
#endif

static inline void rui_force_avx2(int on) {
#if RUI_AVX2
  rui_avx2_state = on < 0 ? -1 : on;
#else
  (void)on;
#endif
}

/* `src` over the opaque pixels of `dst`, x .. xb-1: each `op` (0..255) of it times its own
 * alpha, mixed by `lut` (a separable blend mode's table, [under*256 + over]; NULL Normal) --
 * what overOpaque gives. Stops at the first pixel whose `dst` is not opaque and `src` shows
 * there (the caller mixes that one): its index, or xb. */
static inline int rui_mix_opaque(uint32_t* dst, const uint32_t* src, int x, int xb, uint32_t op,
                                 const uint8_t* lut) {
#if RUI_AVX2
  if (rui_has_avx2()) return rui_mix_opaque_8(dst, src, x, xb, op, lut);
#endif
  return rui_mix_opaque_4(dst, src, x, xb, op, lut);
}

/* ... and with a mask, clipped, by Blend If (`o`): each pixel's amount as `rui_amt1`. */
static inline int rui_mix_opt(uint32_t* dst, const uint32_t* src, int x, int xb, uint32_t op,
                              const uint8_t* lut, const rui_mixopt* o) {
#if RUI_AVX2
  if (rui_has_avx2()) return rui_mix_opt_8(dst, src, x, xb, op, lut, o);
#endif
  return rui_mix_opt_4(dst, src, x, xb, op, lut, o);
}

/* acc[t] += kw * buf[t], t < n (a blur's pass down its rows, in whole numbers) */
static inline void rui_madd_u16(uint32_t* acc, const uint16_t* buf, int n, uint32_t kw) {
#if RUI_AVX2
  if (rui_has_avx2()) { rui_madd_u16_8(acc, buf, n, kw); return; }
#endif
  rui_madd_u16_4(acc, buf, n, kw);
}

/* A row of a gaussian blur across: `pre` the row's pixels premultiplied (b, g, r, a as floats,
 * four a pixel), `k` the kernel (2*kr+1 weights, summing to 1), written to `out` as 16-bit
 * (8 bits of fraction, rounded). */
static inline void rui_blur_across(const float* pre, int w, const float* k, int kr, uint16_t* out) {
#if RUI_AVX2
  if (rui_has_avx2()) { rui_blur_across_8(pre, w, k, kr, out); return; }
#endif
  rui_blur_across_4(pre, w, k, kr, out);
}

/* A row of pixels as a gaussian blur takes them: four floats a pixel, alpha then red, green and
 * blue premultiplied ((c * a + 127) / 255, rounded down) -- photofx's loop. */
static inline void rui_pre_row(const uint32_t* src, int w, float* pre) {
#if RUI_VEC
  const rui_u4 k127 = {127, 127, 127, 0}, keepA = {0, 0, 0, 0xFFFFFFFFu};
  for (int x = 0; x < w; x++) {
    uint32_t p = src[x];
    rui_u4 v = rui_bytes4(p);                     /* b, g, r, a */
    rui_u4 a = (rui_u4){0, 0, 0, 0} + (p >> 24);
    rui_u4 m = (((v * a + k127) * 0x8081u) >> 23) & ~keepA;
    m |= v & keepA;                               /* (the alpha as it is) */
    rui_u4 o = RUI_SHUF(rui_u4, m, m, 3, 2, 1, 0); /* a, r, g, b */
    rui_f4 f = __builtin_convertvector((rui_i4v)o, rui_f4);
    memcpy(pre + x * 4, &f, 16);
  }
#else
  for (int x = 0; x < w; x++) {
    uint32_t p = src[x], a = p >> 24;
    pre[x * 4] = (float)a;
    pre[x * 4 + 1] = (float)RUI_DIV255(((p >> 16) & 255) * a + 127);
    pre[x * 4 + 2] = (float)RUI_DIV255(((p >> 8) & 255) * a + 127);
    pre[x * 4 + 3] = (float)RUI_DIV255((p & 255) * a + 127);
  }
#endif
}

/* Rows y0 .. y1-1 of a picture resampled, the two ways one after the other: each source row
 * needed resampled across once (premultiplied floats, kept in `ring`: room for `rn` rows of `nw`
 * pixels), then the new rows each the `taps` rows round it weighed -- for bicubic 8 weighings a
 * pixel instead of 16. `yi`, `yw`: each new row's taps; `xi`, `xw`: each new column's. */
static inline void rui_resample_rows(const uint32_t* sp, int w, int nw, int y0, int y1, int taps,
                                     const int32_t* yi, const float* yw, const int32_t* xi, const float* xw,
                                     uint32_t* out, float* ring, int* ringRow, int rn) {
  for (int k = 0; k < rn; k++) ringRow[k] = -1;
  int next = 0;
  for (int y = y0; y < y1; y++) {
    const float* rowsF[8];
    for (int j = 0; j < taps; j++) {
      int sy = yi[y * taps + j];
      int slot = -1;
      for (int k = 0; k < rn; k++) if (ringRow[k] == sy) { slot = k; break; }
      if (slot < 0) {
        /* (a source row across, into the slot used longest ago -- not one this row needs) */
        for (;;) {
          slot = next;
          next = (next + 1) % rn;
          int busy = 0;
          for (int jj = 0; jj < j; jj++) if (rowsF[jj] == ring + (size_t)slot * nw * 4) busy = 1;
          if (!busy) break;
        }
        ringRow[slot] = sy;
        float* hr = ring + (size_t)slot * nw * 4;
        const uint32_t* src = sp + (size_t)sy * w;
        for (int x = 0; x < nw; x++) {
#if RUI_VEC
          rui_f4 acc = {0, 0, 0, 0};
          for (int i = 0; i < taps; i++) {
            uint32_t p = src[xi[x * taps + i]];
            rui_f4 v = rui_px4(p);
            float a = v[3];
            v *= a;
            v[3] = a;
            acc += v * xw[x * taps + i];
          }
          memcpy(hr + x * 4, &acc, 16);
#else
          float a0 = 0, a1 = 0, a2 = 0, a3 = 0;
          for (int i = 0; i < taps; i++) {
            uint32_t p = src[xi[x * taps + i]];
            float a = (float)(p >> 24), wt = xw[x * taps + i];
            a0 += (float)(p & 255) * a * wt; a1 += (float)((p >> 8) & 255) * a * wt;
            a2 += (float)((p >> 16) & 255) * a * wt; a3 += a * wt;
          }
          hr[x * 4] = a0; hr[x * 4 + 1] = a1; hr[x * 4 + 2] = a2; hr[x * 4 + 3] = a3;
#endif
        }
      }
      rowsF[j] = ring + (size_t)slot * nw * 4;
    }
    uint32_t* o = out + (size_t)y * nw;
    for (int x = 0; x < nw; x++) {
#if RUI_VEC
      rui_f4 acc = {0, 0, 0, 0};
      for (int j = 0; j < taps; j++) {
        rui_f4 v;
        memcpy(&v, rowsF[j] + x * 4, 16);
        acc += v * yw[y * taps + j];
      }
      float a = acc[3], b0 = acc[0], g0 = acc[1], r0 = acc[2];
#else
      float a = 0, b0 = 0, g0 = 0, r0 = 0;
      for (int j = 0; j < taps; j++) {
        const float* v = rowsF[j] + x * 4;
        float wy = yw[y * taps + j];
        b0 += v[0] * wy; g0 += v[1] * wy; r0 += v[2] * wy; a += v[3] * wy;
      }
#endif
      if (a <= 0.001f) { o[x] = 0; continue; }
      float ia = 1.0f / a;
      int aa = (int)(a + 0.5f), r = (int)(r0 * ia + 0.5f), g = (int)(g0 * ia + 0.5f), b = (int)(b0 * ia + 0.5f);
      o[x] = (rui_c255(aa) << 24) | (rui_c255(r) << 16) | (rui_c255(g) << 8) | rui_c255(b);
    }
  }
}

/* A box blur's pass across a row: each pixel's mean over 2r+1 (the edges repeated), the colors
 * weighed by their alpha, into `mid` four 16-bit numbers a pixel (b, g, r premultiplied and a,
 * times 256) -- running sums in whole numbers, any radius the same cost. */
static inline void rui_box_across(const uint32_t* row, int w, int r, uint16_t* mid) {
  const float n = (float)(2 * r + 1);
  const float sc = 256.0f / (255.0f * n), sa = 256.0f / n;
#define RUI_AT(x) row[(x) < 0 ? 0 : ((x) >= w ? w - 1 : (x))]
#if RUI_VEC
  typedef int32_t rui_i4 __attribute__((vector_size(16)));
  rui_i4 acc = {0, 0, 0, 0};
#define RUI_PRE(p) ({ uint32_t _p = (p); int32_t _a = (int32_t)(_p >> 24); \
    rui_i4 _v = {(int32_t)(_p & 255) * _a, (int32_t)((_p >> 8) & 255) * _a, (int32_t)((_p >> 16) & 255) * _a, _a}; _v; })
  for (int k = -r; k <= r; k++) acc += RUI_PRE(RUI_AT(k));
  const rui_f4 scale = {sc, sc, sc, sa};
  for (int x = 0; x < w; x++) {
    rui_f4 f = __builtin_convertvector(acc, rui_f4) * scale;
    for (int c = 0; c < 4; c++) mid[x * 4 + c] = (uint16_t)(f[c] + 0.5f);
    acc += RUI_PRE(RUI_AT(x + r + 1)) - RUI_PRE(RUI_AT(x - r));
  }
#undef RUI_PRE
#else
  int64_t a0 = 0, a1 = 0, a2 = 0, a3 = 0;
  for (int k = -r; k <= r; k++) {
    uint32_t p = RUI_AT(k); int64_t a = p >> 24;
    a0 += (p & 255) * a; a1 += ((p >> 8) & 255) * a; a2 += ((p >> 16) & 255) * a; a3 += a;
  }
  for (int x = 0; x < w; x++) {
    mid[x * 4] = (uint16_t)(a0 * sc + 0.5f); mid[x * 4 + 1] = (uint16_t)(a1 * sc + 0.5f);
    mid[x * 4 + 2] = (uint16_t)(a2 * sc + 0.5f); mid[x * 4 + 3] = (uint16_t)(a3 * sa + 0.5f);
    uint32_t p = RUI_AT(x + r + 1), q = RUI_AT(x - r);
    int64_t pa = p >> 24, qa = q >> 24;
    a0 += (int64_t)(p & 255) * pa - (int64_t)(q & 255) * qa;
    a1 += (int64_t)((p >> 8) & 255) * pa - (int64_t)((q >> 8) & 255) * qa;
    a2 += (int64_t)((p >> 16) & 255) * pa - (int64_t)((q >> 16) & 255) * qa;
    a3 += pa - qa;
  }
#endif
#undef RUI_AT
}

/* A box blur's pass down columns x0 .. x1-1 of `mid` (as `rui_box_across` left it), into the
 * picture `out` (`w` wide, `h` tall); `acc` room for (x1 - x0) * 4 sums. */
static inline void rui_box_down(const uint16_t* mid, int w, int h, int x0, int x1, int r, uint32_t* out,
                                uint32_t* acc) {
  const int m = x1 - x0;
  const float n = (float)(2 * r + 1);
  memset(acc, 0, (size_t)m * 16);
  for (int k = -r; k <= r; k++) {
    const uint16_t* row = mid + ((size_t)(k < 0 ? 0 : (k >= h ? h - 1 : k)) * w + x0) * 4;
    for (int t = 0; t < m * 4; t++) acc[t] += row[t];
  }
  for (int y = 0; y < h; y++) {
    uint32_t* o = out + (size_t)y * w + x0;
    for (int k = 0; k < m; k++) {
      uint32_t a = acc[k * 4 + 3];
      if (a == 0) { o[k] = 0; continue; }
      float fa = (float)a, ia = 255.0f / fa;
      uint32_t oa = (uint32_t)(fa / (n * 256.0f) + 0.5f);
      uint32_t cb = (uint32_t)(acc[k * 4] * ia + 0.5f), cg = (uint32_t)(acc[k * 4 + 1] * ia + 0.5f),
               cr = (uint32_t)(acc[k * 4 + 2] * ia + 0.5f);
      o[k] = (rui_c255((int)oa) << 24) | (rui_c255((int)cr) << 16) | (rui_c255((int)cg) << 8) | rui_c255((int)cb);
    }
    int ya = y - r, yb = y + r + 1;
    const uint16_t* sub = mid + ((size_t)(ya < 0 ? 0 : ya) * w + x0) * 4;
    const uint16_t* add = mid + ((size_t)(yb >= h ? h - 1 : yb) * w + x0) * 4;
    for (int t = 0; t < m * 4; t++) acc[t] += (uint32_t)add[t] - (uint32_t)sub[t];
  }
}

/* A color through a table of N x N x N colors (red, green, blue the indexes), read between
 * them -- retroui/photo's lutAt (an adjustment layer's table: red, green and blue, the alpha
 * kept) and retroui/photoinks' lookup (the proof's table: its four bytes), the four channels
 * side by side; the same whole numbers as theirs. */
#if RUI_VEC
typedef double rui_d4 __attribute__((vector_size(32)));
#endif

static inline uint32_t rui_lut3_adj(const uint32_t* lut, int N, uint32_t p) {
  const uint32_t n = (uint32_t)N - 1;
  uint32_t r = ((p >> 16) & 255) * n, g = ((p >> 8) & 255) * n, b = (p & 255) * n;
  uint32_t ri = RUI_DIV255(r), gi = RUI_DIV255(g), bi = RUI_DIV255(b);
  uint32_t rf = r - ri * 255, gf = g - gi * 255, bf = b - bi * 255;
  uint32_t r1 = ri + 1 < n ? ri + 1 : n, g1 = gi + 1 < n ? gi + 1 : n, b1 = bi + 1 < n ? bi + 1 : n;
#define RUI_AT(i, j, k) lut[((size_t)(i) * N + (j)) * N + (k)]
#if RUI_VEC
  /* (in floats: every product and sum below 2^24 is a whole number in one exactly -- x86's
   * four-lane whole-number multiply is SSE4's, a float's is everyone's) */
#define RUI_F(i, j, k) __builtin_convertvector((rui_i4v)rui_bytes4(RUI_AT(i, j, k)), rui_f4)
  const float fb = (float)bf, fb1 = (float)(255 - bf), fg = (float)gf, fg1 = (float)(255 - gf);
  rui_f4 c00 = RUI_F(ri, gi, bi) * fb1 + RUI_F(ri, gi, b1) * fb;
  rui_f4 c01 = RUI_F(ri, g1, bi) * fb1 + RUI_F(ri, g1, b1) * fb;
  rui_f4 c10 = RUI_F(r1, gi, bi) * fb1 + RUI_F(r1, gi, b1) * fb;
  rui_f4 c11 = RUI_F(r1, g1, bi) * fb1 + RUI_F(r1, g1, b1) * fb;
#undef RUI_F
  rui_f4 c0 = c00 * fg1 + c01 * fg, c1 = c10 * fg1 + c11 * fg;
  /* (then in doubles: up to 4,236,541,312, exactly) */
  rui_d4 num = __builtin_convertvector(c0, rui_d4) * (double)(255 - rf) +
               __builtin_convertvector(c1, rui_d4) * (double)rf + 8290687.0;
  rui_i4v o = __builtin_convertvector(num / 16581375.0, rui_i4v);
  return (p & 0xFF000000u) | ((uint32_t)o[2] << 16) | ((uint32_t)o[1] << 8) | (uint32_t)o[0];
#else
  uint32_t out = p & 0xFF000000u;
  for (int c = 0; c < 3; c++) {
    int sh = 16 - 8 * c;
#define RUI_V(i, j, k) ((RUI_AT(i, j, k) >> sh) & 255)
    uint64_t c00 = RUI_V(ri, gi, bi) * (255 - bf) + RUI_V(ri, gi, b1) * bf;
    uint64_t c01 = RUI_V(ri, g1, bi) * (255 - bf) + RUI_V(ri, g1, b1) * bf;
    uint64_t c10 = RUI_V(r1, gi, bi) * (255 - bf) + RUI_V(r1, gi, b1) * bf;
    uint64_t c11 = RUI_V(r1, g1, bi) * (255 - bf) + RUI_V(r1, g1, b1) * bf;
#undef RUI_V
    uint64_t c0 = c00 * (255 - gf) + c01 * gf, c1 = c10 * (255 - gf) + c11 * gf;
    out |= (uint32_t)((c0 * (255 - rf) + c1 * rf + 8290687u) / 16581375u) << sh;
  }
  return out;
#endif
#undef RUI_AT
}

static inline uint32_t rui_lut3_ink(const uint32_t* t, int N, uint32_t p) {
  const uint32_t n = (uint32_t)N - 1;
  uint32_t r = ((p >> 16) & 255) * n, g = ((p >> 8) & 255) * n, b = (p & 255) * n;
  uint32_t ri = RUI_DIV255(r), gi = RUI_DIV255(g), bi = RUI_DIV255(b);
  if (ri > n - 1) ri = n - 1;
  if (gi > n - 1) gi = n - 1;
  if (bi > n - 1) bi = n - 1;
  uint32_t rf = r - ri * 255, gf = g - gi * 255, bf = b - bi * 255;
  size_t i000 = ((size_t)ri * N + gi) * N + bi, NN = (size_t)N * N;
#if RUI_VEC
  /* (in floats, every number a whole one below 2^24: exact; each division rounded down after) */
#define RUI_F(i) __builtin_convertvector((rui_i4v)rui_bytes4(t[i]), rui_f4)
  const float fb = (float)bf, fb1 = (float)(255 - bf), fg = (float)gf, fg1 = (float)(255 - gf);
  rui_f4 c00 = RUI_F(i000) * fb1 + RUI_F(i000 + 1) * fb;
  rui_f4 c01 = RUI_F(i000 + N) * fb1 + RUI_F(i000 + N + 1) * fb;
  rui_f4 c10 = RUI_F(i000 + NN) * fb1 + RUI_F(i000 + NN + 1) * fb;
  rui_f4 c11 = RUI_F(i000 + NN + N) * fb1 + RUI_F(i000 + NN + N + 1) * fb;
#undef RUI_F
  rui_f4 c0 = c00 * fg1 + c01 * fg, c1 = c10 * fg1 + c11 * fg;
  rui_f4 q0 = __builtin_convertvector(__builtin_convertvector(c0 / 255.0f, rui_i4v), rui_f4);
  rui_f4 q1 = __builtin_convertvector(__builtin_convertvector(c1 / 255.0f, rui_i4v), rui_f4);
  rui_f4 num = q0 * (float)(255 - rf) + q1 * (float)rf + 32385.0f;
  rui_f4 q = __builtin_convertvector(__builtin_convertvector(num / 255.0f, rui_i4v), rui_f4);
  rui_u4 c = (rui_u4)__builtin_convertvector(q / 255.0f, rui_i4v);
  return ((c[3] > 255 ? 255 : c[3]) << 24) | ((c[2] > 255 ? 255 : c[2]) << 16) |
         ((c[1] > 255 ? 255 : c[1]) << 8) | (c[0] > 255 ? 255 : c[0]);
#else
  uint32_t out = 0;
  for (int sh = 24; sh >= 0; sh -= 8) {
#define RUI_V(i) ((t[i] >> sh) & 255)
    uint32_t c00 = RUI_V(i000) * (255 - bf) + RUI_V(i000 + 1) * bf;
    uint32_t c01 = RUI_V(i000 + N) * (255 - bf) + RUI_V(i000 + N + 1) * bf;
    uint32_t c10 = RUI_V(i000 + NN) * (255 - bf) + RUI_V(i000 + NN + 1) * bf;
    uint32_t c11 = RUI_V(i000 + NN + N) * (255 - bf) + RUI_V(i000 + NN + N + 1) * bf;
#undef RUI_V
    uint32_t c0 = c00 * (255 - gf) + c01 * gf, c1 = c10 * (255 - gf) + c11 * gf;
    uint32_t c = (c0 / 255 * (255 - rf) + c1 / 255 * rf + 255 * 127) / (255 * 255);
    out |= (c > 255 ? 255 : c) << sh;
  }
  return out;
#endif
}

#ifdef RUI_POP
#pragma GCC diagnostic pop
#undef RUI_POP
#endif

#endif
