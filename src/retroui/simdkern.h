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
typedef uint8_t rui_b4 __attribute__((vector_size(4)));
/* a pixel's four bytes (b, g, r, a in memory) as four floats */
static inline rui_f4 rui_px4(uint32_t p) {
  rui_b4 b;
  memcpy(&b, &p, 4);
  return __builtin_convertvector(b, rui_f4);
}
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

/* `src` over the opaque pixels of `dst`, x .. xb-1: each `op` (0..255) of it times its own
 * alpha, mixed by `lut` (a separable blend mode's table, [under*256 + over]; NULL Normal) --
 * what overOpaque gives. Stops at the first pixel whose `dst` is not opaque and `src` shows
 * there (the caller mixes that one): its index, or xb. */
static inline int rui_mix_opaque(uint32_t* dst, const uint32_t* src, int x, int xb, uint32_t op,
                                 const uint8_t* lut) {
#if RUI_VEC
  const rui_u4 k255 = {255, 255, 255, 255}, kdiv = {0x8081, 0x8081, 0x8081, 0x8081};
  const rui_u4 kopq = {0xFF000000u, 0xFF000000u, 0xFF000000u, 0xFF000000u};
  const rui_u4 vop = {op, op, op, op}, m8 = {255, 255, 255, 255};
  while (x + 4 <= xb) {
    rui_u4 d, s;
    memcpy(&d, dst + x, 16);
    memcpy(&s, src + x, 16);
    if ((d[0] & d[1] & d[2] & d[3]) < 0xFF000000u) break;   /* (one under is not opaque) */
    if (lut) {
      /* (the mode's mix of each channel: looked up, then mixed as Normal) */
      uint32_t t[4];
      for (int i = 0; i < 4; i++) {
        uint32_t dd = d[i], ss = s[i];
        t[i] = (ss & 0xFF000000u) | ((uint32_t)lut[((dd >> 16) & 255) << 8 | ((ss >> 16) & 255)] << 16) |
               ((uint32_t)lut[((dd >> 8) & 255) << 8 | ((ss >> 8) & 255)] << 8) |
               (uint32_t)lut[(dd & 255) << 8 | (ss & 255)];
      }
      memcpy(&s, t, 16);
    }
    rui_u4 ea = ((vop * (s >> 24)) * kdiv) >> 23;
    rui_u4 ia = k255 - ea;
    rui_u4 r = (((((s >> 16) & m8) * ea + ((d >> 16) & m8) * ia) * kdiv) >> 23) << 16;
    rui_u4 g = (((((s >> 8) & m8) * ea + ((d >> 8) & m8) * ia) * kdiv) >> 23) << 8;
    rui_u4 b = ((((s & m8) * ea + (d & m8) * ia) * kdiv) >> 23);
    rui_u4 o = kopq | r | g | b;
    memcpy(dst + x, &o, 16);
    x += 4;
  }
#endif
  for (; x < xb; x++) {
    uint32_t s = src[x];
    uint32_t sa = s >> 24;
    if (sa == 0) continue;
    uint32_t d = dst[x];
    if ((d >> 24) != 255) return x;
    uint32_t ea = RUI_DIV255(op * sa);
    if (ea > 0) dst[x] = rui_over1(d, s, ea, lut);
  }
  return xb;
}

/* acc[t] += kw * buf[t], t < n (a blur's pass down its rows, in whole numbers: the compiler
 * makes this loop its vectors by itself) */
static inline void rui_madd_u16(uint32_t* acc, const uint16_t* buf, int n, uint32_t kw) {
  for (int t = 0; t < n; t++) acc[t] += kw * buf[t];
}

/* A row of a gaussian blur across: `pre` the row's pixels premultiplied (b, g, r, a as floats,
 * four a pixel), `k` the kernel (2*kr+1 weights, summing to 1), written to `out` as 16-bit
 * (8 bits of fraction, rounded). */
static inline void rui_blur_across(const float* pre, int w, const float* k, int kr, uint16_t* out) {
  for (int x = 0; x < w; x++) {
#if RUI_VEC
    rui_f4 acc = {0, 0, 0, 0};
    if (x >= kr && x + kr < w) {
      const float* q = pre + (x - kr) * 4;
      for (int i = 0; i <= 2 * kr; i++) {
        rui_f4 p;
        memcpy(&p, q + i * 4, 16);
        acc += p * k[i];
      }
    } else {
      for (int i = -kr; i <= kr; i++) {
        int xx = x + i < 0 ? 0 : (x + i >= w ? w - 1 : x + i);
        rui_f4 p;
        memcpy(&p, pre + xx * 4, 16);
        acc += p * k[i + kr];
      }
    }
    for (int c = 0; c < 4; c++) out[x * 4 + c] = (uint16_t)(acc[c] * 256.0f + 0.5f);
#else
    float a0 = 0, a1 = 0, a2 = 0, a3 = 0;
    for (int i = -kr; i <= kr; i++) {
      int xx = x + i < 0 ? 0 : (x + i >= w ? w - 1 : x + i);
      const float* p = pre + xx * 4;
      float kw = k[i + kr];
      a0 += p[0] * kw; a1 += p[1] * kw; a2 += p[2] * kw; a3 += p[3] * kw;
    }
    out[x * 4] = (uint16_t)(a0 * 256.0f + 0.5f); out[x * 4 + 1] = (uint16_t)(a1 * 256.0f + 0.5f);
    out[x * 4 + 2] = (uint16_t)(a2 * 256.0f + 0.5f); out[x * 4 + 3] = (uint16_t)(a3 * 256.0f + 0.5f);
#endif
  }
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

#ifdef RUI_POP
#pragma GCC diagnostic pop
#undef RUI_POP
#endif

#endif
