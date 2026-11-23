/* The kit's own hot loops, several pixels at a time: the screen's drawing (fills, a glyph's
   coverage mixed in, pictures copied and scaled and mixed), JPEG's inverse DCT and colors,
   PNG's row filters, pictures made smaller. With GCC's and Clang's own vectors: SSE2 on
   x86-64 (AVX2 where it pays, picked at run time), NEON on ARM, SIMD128 in a web page, lane by
   lane where there is none. Each gives the very values its plain loop gives (`retroui/simdkit`).

   Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net */
#ifndef RUK_SIMDKIT_H
#define RUK_SIMDKIT_H
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

typedef uint32_t ruk_u4 __attribute__((vector_size(16)));
typedef int32_t ruk_i4 __attribute__((vector_size(16)));
typedef uint16_t ruk_u8h __attribute__((vector_size(16)));
typedef uint8_t ruk_b16 __attribute__((vector_size(16)));
typedef int16_t ruk_s8 __attribute__((vector_size(16)));
typedef uint8_t ruk_b8 __attribute__((vector_size(8)));
#if defined(__SSE2__)
#include <emmintrin.h>
#endif

static inline ruk_u4 ruk_load4(const uint32_t* p) { ruk_u4 v; memcpy(&v, p, 16); return v; }
static inline void ruk_store4(uint32_t* p, ruk_u4 v) { memcpy(p, &v, 16); }
static inline ruk_i4 ruk_loadi4(const int32_t* p) { ruk_i4 v; memcpy(&v, p, 16); return v; }
static inline void ruk_storei4(int32_t* p, ruk_i4 v) { memcpy(p, &v, 16); }

/* ---- fills ------------------------------------------------------------------------------- */

static inline void ruk_fill32(uint32_t* d, intptr_t n, uint32_t c) {
  /* n pixels of color c */
  ruk_u4 v = {c, c, c, c};
  intptr_t i = 0;
  for (; i + 16 <= n; i += 16) {
    ruk_store4(d + i, v); ruk_store4(d + i + 4, v); ruk_store4(d + i + 8, v); ruk_store4(d + i + 12, v);
  }
  for (; i + 4 <= n; i += 4) ruk_store4(d + i, v);
  for (; i < n; i++) d[i] = c;
}

/* ---- mixing a color in by a coverage --------------------------------------------------- */

/* the screen's blend: c over q by a (0..255), red and blue in one multiply, green in another,
   rounded like v div 255 (gfx.nim's `blend`) */
static inline uint32_t ruk_blend1(uint32_t q, uint32_t c, uint32_t a) {
  uint32_t na = 255u - a;
  uint32_t rb = (c & 0xFF00FFu) * a + (q & 0xFF00FFu) * na + 0x800080u;
  rb = ((rb + ((rb >> 8) & 0xFF00FFu)) >> 8) & 0xFF00FFu;
  uint32_t gg = (c & 0xFF00u) * a + (q & 0xFF00u) * na + 0x8000u;
  gg = ((gg + ((gg >> 8) & 0xFF00u)) >> 8) & 0xFF00u;
  return rb | gg;
}

static inline ruk_u4 ruk_blend4(ruk_u4 q, ruk_u4 c, ruk_u4 a) {
  const ruk_u4 mrb = {0xFF00FFu, 0xFF00FFu, 0xFF00FFu, 0xFF00FFu};
  const ruk_u4 mg = {0xFF00u, 0xFF00u, 0xFF00u, 0xFF00u};
  ruk_u4 na = 255u - a;
  ruk_u4 rb = (c & mrb) * a + (q & mrb) * na + 0x800080u;
  rb = ((rb + ((rb >> 8) & mrb)) >> 8) & mrb;
  ruk_u4 gg = (c & mg) * a + (q & mg) * na + 0x8000u;
  gg = ((gg + ((gg >> 8) & mg)) >> 8) & mg;
  return rb | gg;
}

/* a glyph's row: each pixel of fp mixed with col by its coverage m[i] (0 left alone, 255 col),
   through lut when there is one (small text's). Four pixels at a time in 16-bit lanes, a lane
   for each channel: c a + q (255 - a) + 128 fits in one (65,153 at most), and SSE2 multiplies
   eight of those at once where it has no multiply of 32-bit lanes at all -- the 32-bit way,
   red and blue in one lane, is the last below for a compiler without vector conversions. The
   very values of ruk_blend1 (the alpha byte 0 where mixed, as there). */
static inline void ruk_blend_mask(uint32_t* fp, const uint8_t* m, intptr_t n, uint32_t col, const uint8_t* lut) {
  intptr_t i = 0;
  ruk_u4 cv = {col, col, col, col};
#if defined(__SSE2__)
  const __m128i z = _mm_setzero_si128();
  const __m128i cw = _mm_set1_epi32((int)col);
  const __m128i c16 = _mm_unpacklo_epi8(cw, z);                       /* B G R A, twice */
  const __m128i k255 = _mm_set1_epi16(255), k128 = _mm_set1_epi16(128);
  const __m128i rgb = _mm_set1_epi32(0xFFFFFF);
  for (; i + 4 <= n; i += 4) {
    uint32_t w;
    memcpy(&w, m + i, 4);
    if (w == 0) continue;
    uint32_t r0 = m[i], r1 = m[i + 1], r2 = m[i + 2], r3 = m[i + 3];
    uint32_t a0 = r0, a1 = r1, a2 = r2, a3 = r3;
    if (lut) { a0 = lut[r0]; a1 = lut[r1]; a2 = lut[r2]; a3 = lut[r3]; }
    else if (w == 0xFFFFFFFFu) { _mm_storeu_si128((__m128i*)(fp + i), cw); continue; }
    __m128i q = _mm_loadu_si128((const __m128i*)(fp + i));
    __m128i ql = _mm_unpacklo_epi8(q, z), qh = _mm_unpackhi_epi8(q, z);
    __m128i av = _mm_set_epi32((int)a3, (int)a2, (int)a1, (int)a0);
    __m128i a16 = _mm_packs_epi32(av, av);                             /* a0 a1 a2 a3 a0 a1 a2 a3 */
    __m128i al = _mm_unpacklo_epi16(a16, a16);                         /* a0 a0 a1 a1 a2 a2 a3 a3 */
    __m128i ah = _mm_unpackhi_epi32(al, al);                           /* a2 x4, a3 x4 */
    al = _mm_unpacklo_epi32(al, al);                                   /* a0 x4, a1 x4 */
    __m128i xl = _mm_add_epi16(_mm_add_epi16(_mm_mullo_epi16(c16, al),
                                             _mm_mullo_epi16(ql, _mm_sub_epi16(k255, al))), k128);
    __m128i xh = _mm_add_epi16(_mm_add_epi16(_mm_mullo_epi16(c16, ah),
                                             _mm_mullo_epi16(qh, _mm_sub_epi16(k255, ah))), k128);
    xl = _mm_srli_epi16(_mm_add_epi16(xl, _mm_srli_epi16(xl, 8)), 8);
    xh = _mm_srli_epi16(_mm_add_epi16(xh, _mm_srli_epi16(xh, 8)), 8);
    __m128i r = _mm_and_si128(_mm_packus_epi16(xl, xh), rgb);
    /* (where there is no coverage the pixel stays -- the table not asked; where it is full,
       the color itself) */
    __m128i raw = _mm_set_epi32((int)r3, (int)r2, (int)r1, (int)r0);
    __m128i none = _mm_cmpeq_epi32(raw, z);
    __m128i full = _mm_andnot_si128(none, _mm_cmpgt_epi32(av, _mm_set1_epi32(254)));
    r = _mm_or_si128(_mm_andnot_si128(_mm_or_si128(none, full), r),
                     _mm_or_si128(_mm_and_si128(none, q), _mm_and_si128(full, cw)));
    _mm_storeu_si128((__m128i*)(fp + i), r);
  }
#elif defined(__clang__) || (defined(__GNUC__) && __GNUC__ >= 9)
  ruk_b8 cb;
  memcpy(&cb, &cv, 8);
  const ruk_u8h c16 = __builtin_convertvector(cb, ruk_u8h);
  const ruk_u8h k255 = {255, 255, 255, 255, 255, 255, 255, 255};
  const ruk_u8h k128 = {128, 128, 128, 128, 128, 128, 128, 128};
  const ruk_u4 rgb = {0xFFFFFFu, 0xFFFFFFu, 0xFFFFFFu, 0xFFFFFFu};
  for (; i + 4 <= n; i += 4) {
    uint32_t w;
    memcpy(&w, m + i, 4);
    if (w == 0) continue;
    uint32_t r0 = m[i], r1 = m[i + 1], r2 = m[i + 2], r3 = m[i + 3];
    uint32_t a0 = r0, a1 = r1, a2 = r2, a3 = r3;
    if (lut) { a0 = lut[r0]; a1 = lut[r1]; a2 = lut[r2]; a3 = lut[r3]; }
    else if (w == 0xFFFFFFFFu) { ruk_store4(fp + i, cv); continue; }
    ruk_u4 q = ruk_load4(fp + i);
    ruk_b8 qlo, qhi;
    memcpy(&qlo, &q, 8);
    memcpy(&qhi, (const char*)&q + 8, 8);
    ruk_u8h ql = __builtin_convertvector(qlo, ruk_u8h), qh = __builtin_convertvector(qhi, ruk_u8h);
    ruk_u8h al = {a0, a0, a0, a0, a1, a1, a1, a1}, ah = {a2, a2, a2, a2, a3, a3, a3, a3};
    ruk_u8h xl = c16 * al + ql * (k255 - al) + k128;
    ruk_u8h xh = c16 * ah + qh * (k255 - ah) + k128;
    xl = (xl + (xl >> 8)) >> 8;
    xh = (xh + (xh >> 8)) >> 8;
    ruk_b8 rl = __builtin_convertvector(xl, ruk_b8), rh = __builtin_convertvector(xh, ruk_b8);
    ruk_u4 r;
    memcpy(&r, &rl, 8);
    memcpy((char*)&r + 8, &rh, 8);
    r &= rgb;
    ruk_u4 a = {a0, a1, a2, a3};
    ruk_u4 raw = {r0, r1, r2, r3};
    ruk_u4 zero = (ruk_u4)(raw == 0);
    ruk_u4 full = (ruk_u4)(a >= 255) & ~zero;
    r = (r & ~zero & ~full) | (q & zero) | (cv & full);
    ruk_store4(fp + i, r);
  }
#else
  for (; i + 4 <= n; i += 4) {
    uint32_t r0 = m[i], r1 = m[i + 1], r2 = m[i + 2], r3 = m[i + 3];
    if ((r0 | r1 | r2 | r3) == 0) continue;
    uint32_t a0 = r0, a1 = r1, a2 = r2, a3 = r3;
    if (lut) { a0 = lut[r0]; a1 = lut[r1]; a2 = lut[r2]; a3 = lut[r3]; }
    if (r0 && r1 && r2 && r3 && a0 >= 255 && a1 >= 255 && a2 >= 255 && a3 >= 255) {
      ruk_store4(fp + i, cv);
      continue;
    }
    ruk_u4 a = {a0, a1, a2, a3};
    ruk_u4 raw = {r0, r1, r2, r3};
    ruk_u4 q = ruk_load4(fp + i);
    ruk_u4 r = ruk_blend4(q, cv, a);
    /* (where there is no coverage the pixel stays -- the table not asked; where it is full,
       the color itself) */
    ruk_u4 zero = (ruk_u4)(raw == 0);
    ruk_u4 full = (ruk_u4)(a >= 255) & ~zero;
    r = (r & ~zero & ~full) | (q & zero) | (cv & full);
    ruk_store4(fp + i, r);
  }
#endif
  for (; i < n; i++) {
    uint32_t a = m[i];
    if (a == 0) continue;
    if (lut) a = lut[a];
    fp[i] = a >= 255 ? col : ruk_blend1(fp[i], col, a);
  }
}

/* a picture's row over the screen's: each source pixel's alpha mixes it in (255: copied, its
   alpha byte dropped; 0: left alone) */
static inline void ruk_over_row(uint32_t* fp, const uint32_t* sp, intptr_t n) {
  intptr_t i = 0;
  const ruk_u4 rgb = {0xFFFFFFu, 0xFFFFFFu, 0xFFFFFFu, 0xFFFFFFu};
  for (; i + 4 <= n; i += 4) {
    ruk_u4 p = ruk_load4(sp + i);
    ruk_u4 a = p >> 24;
    ruk_u4 full = (ruk_u4)(a == 255u);
    ruk_u4 none = (ruk_u4)(a == 0u);
    if (((full[0] & full[1]) & (full[2] & full[3])) != 0) { ruk_store4(fp + i, p & rgb); continue; }
    if (((none[0] & none[1]) & (none[2] & none[3])) != 0) continue;
    ruk_u4 q = ruk_load4(fp + i);
    ruk_u4 r = ruk_blend4(q, p, a);
    r = (r & ~full & ~none) | ((p & rgb) & full) | (q & none);
    ruk_store4(fp + i, r);
  }
  for (; i < n; i++) {
    uint32_t p = sp[i];
    uint32_t a = p >> 24;
    if (a == 255) fp[i] = p & 0xFFFFFFu;
    else if (a != 0) fp[i] = ruk_blend1(fp[i], p, a);
  }
}

/* a row of a picture drawn k times as wide (k = 2, 3, 4: each pixel repeated), its alpha byte
   dropped -- an opaque picture at the screen's scale */
static inline void ruk_widen_row(uint32_t* dst, const uint32_t* src, intptr_t n, int k) {
  intptr_t i = 0;
  if (k == 2) {
    for (; i + 4 <= n; i += 4) {
      ruk_u4 p = ruk_load4(src + i) & 0xFFFFFFu;
#if defined(__clang__) || (defined(__GNUC__) && __GNUC__ >= 12)
      ruk_u4 lo = __builtin_shufflevector(p, p, 0, 0, 1, 1);
      ruk_u4 hi = __builtin_shufflevector(p, p, 2, 2, 3, 3);
#else
      const ruk_i4 il = {0, 0, 1, 1}, ih = {2, 2, 3, 3};
      ruk_u4 lo = __builtin_shuffle(p, (ruk_u4)il), hi = __builtin_shuffle(p, (ruk_u4)ih);
#endif
      ruk_store4(dst + 2 * i, lo);
      ruk_store4(dst + 2 * i + 4, hi);
    }
  }
  for (; i < n; i++) {
    uint32_t p = src[i] & 0xFFFFFFu;
    for (int j = 0; j < k; j++) dst[i * k + j] = p;
  }
}

/* ---- AVX2 -------------------------------------------------------------------------------- */

static volatile int ruk_avx2_state = -1;
#if (defined(__x86_64__) || defined(__i386__)) && (defined(__GNUC__) || defined(__clang__))
#include <cpuid.h>
static inline int ruk_has_avx2(void) {
  int s = ruk_avx2_state;
  if (s >= 0) return s;
  unsigned a, b, c, d;
  s = 0;
  if (__get_cpuid(1, &a, &b, &c, &d) && (c & (1u << 27)) && (c & (1u << 28))) {
    unsigned lo, hi;
    __asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
    if ((lo & 6u) == 6u && __get_cpuid_max(0, 0) >= 7) {
      __cpuid_count(7, 0, a, b, c, d);
      s = (b & (1u << 5)) ? 1 : 0;
    }
  }
  ruk_avx2_state = s;
  return s;
}
#else
static inline int ruk_has_avx2(void) { return 0; }
#endif

static inline void ruk_force_avx2(int on) {
  if (on < 0) { ruk_avx2_state = -1; (void)ruk_has_avx2(); }
  else if (on == 0) ruk_avx2_state = 0;
  else { ruk_avx2_state = -1; if (ruk_has_avx2()) ruk_avx2_state = 1; }
}

/* ---- JPEG: the inverse DCT ------------------------------------------------------------------ */

/* jpeg.nim's IDCT (stb_image's, after the IJG's jidctint: 12-bit fixed point, columns then rows)
   with the eight columns, then the eight rows, side by side in 32-bit lanes. It gives the bytes
   of the 64-bit loop -- and is not used for a block whose numbers could pass 32 bits (a broken
   file's): every value inside is at most 13715 times the sum of the sizes of the numbers it is
   made from (worked out from the formula), so the sums of a column's coefficients and of a row
   of the first pass are held under what keeps that inside; 0 then, and jpeg.nim does it in 64. */
typedef int32_t ruk_i8 __attribute__((vector_size(32)));

#define RUK_IDCT_LIM1 156579 /* (2^31 - 1 - 512) / 13715 */
#define RUK_IDCT_LIM2 155351 /* (2^31 - 1 - 65536 - 128 * 2^17) / 13715 */

#define RUK_IDCT1D(s0, s1, s2, s3, s4, s5, s6, s7)                                         \
  ruk_i8 t0, t1, t2, t3, x0, x1, x2, x3;                                                    \
  {                                                                                         \
    ruk_i8 p2 = s2, p3 = s6;                                                                \
    ruk_i8 p1 = (p2 + p3) * 2217;                                                           \
    t2 = p1 + p3 * -7567;                                                                   \
    t3 = p1 + p2 * 3135;                                                                    \
    p2 = s0; p3 = s4;                                                                       \
    t0 = (p2 + p3) * 4096;                                                                  \
    t1 = (p2 - p3) * 4096;                                                                  \
    x0 = t0 + t3; x3 = t0 - t3; x1 = t1 + t2; x2 = t1 - t2;                                 \
    t0 = s7; t1 = s5; t2 = s3; t3 = s1;                                                     \
    p3 = t0 + t2;                                                                           \
    ruk_i8 p4 = t1 + t3;                                                                    \
    p1 = t0 + t3;                                                                           \
    p2 = t1 + t2;                                                                           \
    ruk_i8 p5 = (p3 + p4) * 4816;                                                           \
    t0 = t0 * 1223; t1 = t1 * 8410; t2 = t2 * 12586; t3 = t3 * 6149;                        \
    p1 = p5 + p1 * -3685;                                                                   \
    p2 = p5 + p2 * -10497;                                                                  \
    p3 = p3 * -8034;                                                                        \
    p4 = p4 * -1597;                                                                        \
    t3 += p1 + p4; t2 += p2 + p3; t1 += p2 + p4; t0 += p1 + p3;                             \
  }

/* (as macros: an eight-lane vector passed to a function is a different thing with AVX and
   without, which GCC notes) */
#define ruk_abs8(e) ({ ruk_i8 v_ = (e), s_ = v_ >> 31; (v_ ^ s_) - s_; })
#define ruk_max8(e) ({ ruk_i8 v_ = (e); int32_t m_ = v_[0];                                 \
                       for (int i_ = 1; i_ < 8; i_++) m_ = v_[i_] > m_ ? v_[i_] : m_; m_; })
#define ruk_byte8(e) ({ ruk_i8 v_ = (e); v_ &= ~(v_ >> 31); ruk_i8 b_ = (ruk_i8)(v_ > 255);  \
                        (v_ & ~b_) | (255 & b_); })

#define RUK_IDCT_BODY                                                                       \
  ruk_i8 r[8];                                                                              \
  for (int k = 0; k < 8; k++) memcpy(&r[k], blk + 8 * k, 32);                               \
  ruk_i8 l1 = ruk_abs8(r[0]);                                                               \
  for (int k = 1; k < 8; k++) l1 += ruk_abs8(r[k]);                                         \
  if (ruk_max8(l1) > RUK_IDCT_LIM1) return 0;                                               \
  int32_t v[64], vt[64];                                                                    \
  {                                                                                         \
    RUK_IDCT1D(r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7])                              \
    x0 += 512; x1 += 512; x2 += 512; x3 += 512;                                             \
    ruk_i8 o;                                                                               \
    o = (x0 + t3) >> 10; memcpy(v + 0, &o, 32);                                             \
    o = (x0 - t3) >> 10; memcpy(v + 56, &o, 32);                                            \
    o = (x1 + t2) >> 10; memcpy(v + 8, &o, 32);                                             \
    o = (x1 - t2) >> 10; memcpy(v + 48, &o, 32);                                            \
    o = (x2 + t1) >> 10; memcpy(v + 16, &o, 32);                                            \
    o = (x2 - t1) >> 10; memcpy(v + 40, &o, 32);                                            \
    o = (x3 + t0) >> 10; memcpy(v + 24, &o, 32);                                            \
    o = (x3 - t0) >> 10; memcpy(v + 32, &o, 32);                                            \
  }                                                                                         \
  for (int y = 0; y < 8; y++)                                                               \
    for (int x = 0; x < 8; x++) vt[x * 8 + y] = v[y * 8 + x];                               \
  ruk_i8 c[8];                                                                              \
  for (int k = 0; k < 8; k++) memcpy(&c[k], vt + 8 * k, 32);                                \
  l1 = ruk_abs8(c[0]);                                                                      \
  for (int k = 1; k < 8; k++) l1 += ruk_abs8(c[k]);                                         \
  if (ruk_max8(l1) > RUK_IDCT_LIM2) return 0;                                               \
  {                                                                                         \
    RUK_IDCT1D(c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7])                              \
    const int32_t bias = 65536 + (128 << 17);                                               \
    x0 += bias; x1 += bias; x2 += bias; x3 += bias;                                         \
    ruk_i8 o;                                                                               \
    o = ruk_byte8((x0 + t3) >> 17); memcpy(vt + 0, &o, 32);                                 \
    o = ruk_byte8((x0 - t3) >> 17); memcpy(vt + 56, &o, 32);                                \
    o = ruk_byte8((x1 + t2) >> 17); memcpy(vt + 8, &o, 32);                                 \
    o = ruk_byte8((x1 - t2) >> 17); memcpy(vt + 48, &o, 32);                                \
    o = ruk_byte8((x2 + t1) >> 17); memcpy(vt + 16, &o, 32);                                \
    o = ruk_byte8((x2 - t1) >> 17); memcpy(vt + 40, &o, 32);                                \
    o = ruk_byte8((x3 + t0) >> 17); memcpy(vt + 24, &o, 32);                                \
    o = ruk_byte8((x3 - t0) >> 17); memcpy(vt + 32, &o, 32);                                \
  }                                                                                         \
  for (int y = 0; y < 8; y++) {                                                             \
    uint8_t* d = out + y * stride;                                                          \
    for (int x = 0; x < 8; x++) d[x] = (uint8_t)vt[x * 8 + y];                              \
  }                                                                                         \
  return 1;

static inline int ruk_idct1(const int32_t* blk, uint8_t* out, intptr_t stride) { RUK_IDCT_BODY }
#if (defined(__x86_64__) || defined(__i386__)) && (defined(__GNUC__) || defined(__clang__))
__attribute__((target("avx2"))) static int ruk_idct2(const int32_t* blk, uint8_t* out, intptr_t stride) {
  RUK_IDCT_BODY
}
#endif
static inline int ruk_idct(const int32_t* blk, uint8_t* out, intptr_t stride) {
  /* a block's dequantized coefficients (natural order) -> its 8x8 bytes, `stride` apart; 0 when
     it is left to the 64-bit loop */
  int32_t any = 0;
  for (int i = 1; i < 64; i++) any |= blk[i];
  if (any == 0) {
    /* (only its average, as smooth parts are: one value, what the loop gives -- the columns
       4 * dc, each row's x 16384 * dc, (16384 * dc + 65536 + 128 * 2^17) >> 17) */
    int32_t b = ((blk[0] + 4) >> 3) + 128;
    uint8_t v = (uint8_t)(b < 0 ? 0 : b > 255 ? 255 : b);
    for (int y = 0; y < 8; y++) memset(out + y * stride, v, 8);
    return 1;
  }
#if (defined(__x86_64__) || defined(__i386__)) && (defined(__GNUC__) || defined(__clang__))
  /* (SSE2 has no 32-bit lane multiply: there the plain loop is as quick) */
  if (ruk_has_avx2()) return ruk_idct2(blk, out, stride);
  return 0;
#else
  return ruk_idct1(blk, out, stride);
#endif
}

/* ---- JPEG: colors ----------------------------------------------------------------------------- */

/* a row of YCbCr bytes -> opaque RGB pixels, as jpeg.nim's colorRow: in 16-bit fixed point,
   rounded, clamped */
#define RUK_YCC_BODY                                                                        \
  intptr_t i = 0;                                                                           \
  for (; i + 8 <= n; i += 8) {                                                              \
    ruk_i8 yy = {y[i], y[i + 1], y[i + 2], y[i + 3], y[i + 4], y[i + 5], y[i + 6], y[i + 7]}; \
    ruk_i8 cb = {cbp[i], cbp[i + 1], cbp[i + 2], cbp[i + 3], cbp[i + 4], cbp[i + 5], cbp[i + 6], cbp[i + 7]}; \
    ruk_i8 cr = {crp[i], crp[i + 1], crp[i + 2], crp[i + 3], crp[i + 4], crp[i + 5], crp[i + 6], crp[i + 7]}; \
    yy = (yy << 16) + 32768;                                                                \
    cb -= 128; cr -= 128;                                                                   \
    ruk_i8 r = ruk_byte8((yy + 91881 * cr) >> 16);                                          \
    ruk_i8 g = ruk_byte8((yy - 22554 * cb - 46802 * cr) >> 16);                             \
    ruk_i8 b = ruk_byte8((yy + 116130 * cb) >> 16);                                         \
    ruk_i8 p = (r << 16) | (g << 8) | b | (ruk_i8){-16777216, -16777216, -16777216, -16777216, \
                                                   -16777216, -16777216, -16777216, -16777216}; \
    memcpy(o + i, &p, 32);                                                                  \
  }                                                                                         \
  for (; i < n; i++) {                                                                      \
    int32_t yy = ((int32_t)y[i] << 16) + 32768, cb = cbp[i] - 128, cr = crp[i] - 128;       \
    int32_t r = (yy + 91881 * cr) >> 16, g = (yy - 22554 * cb - 46802 * cr) >> 16,         \
            b = (yy + 116130 * cb) >> 16;                                                   \
    r = r < 0 ? 0 : r > 255 ? 255 : r;                                                      \
    g = g < 0 ? 0 : g > 255 ? 255 : g;                                                      \
    b = b < 0 ? 0 : b > 255 ? 255 : b;                                                      \
    o[i] = 0xFF000000u | ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;            \
  }

static inline void ruk_ycc1(uint32_t* o, const uint8_t* y, const uint8_t* cbp, const uint8_t* crp, intptr_t n) {
  RUK_YCC_BODY
}
#if (defined(__x86_64__) || defined(__i386__)) && (defined(__GNUC__) || defined(__clang__))
__attribute__((target("avx2"))) static void ruk_ycc2(uint32_t* o, const uint8_t* y, const uint8_t* cbp,
                                                     const uint8_t* crp, intptr_t n) {
  RUK_YCC_BODY
}
#endif
static inline void ruk_ycc(uint32_t* o, const uint8_t* y, const uint8_t* cbp, const uint8_t* crp, intptr_t n) {
#if (defined(__x86_64__) || defined(__i386__)) && (defined(__GNUC__) || defined(__clang__))
  if (ruk_has_avx2()) { ruk_ycc2(o, y, cbp, crp, n); return; }
#endif
  ruk_ycc1(o, y, cbp, crp, n);
}

/* ---- JPEG: a color plane made full size ------------------------------------------------------ */

/* the "fancy" upsampling of libjpeg for a plane at half the width: t[i] = 3 * near[i] + far[i]
   (half the height too; 4 * near[i] when not), out[0] = (t[0] + 2) >> 2, then for i in 1 ..< vw
   out[2i - 1] = (3 t[i-1] + t[i] + 8) >> 4 and out[2i] = (3 t[i] + t[i-1] + 8) >> 4, and
   out[2 vw - 1] = (t[vw - 1] + 2) >> 2 -- those below w; eight pairs at a time in 16-bit lanes */
static inline ruk_u8h ruk_widen8(const uint8_t* p) {
#if defined(__clang__) || (defined(__GNUC__) && __GNUC__ >= 9)
  ruk_b8 b;
  memcpy(&b, p, 8);
  return __builtin_convertvector(b, ruk_u8h);
#else
  ruk_u8h v = {p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]};
  return v;
#endif
}

static inline void ruk_fancy2(uint8_t* out, const uint8_t* nr, const uint8_t* fr, intptr_t vw, intptr_t w, int vs) {
#define RUK_T(i) (vs == 2 ? 3 * (int)nr[i] + (int)fr[i] : 4 * (int)nr[i])
  if (w <= 0 || vw <= 0) return;
  int t1 = RUK_T(0);
  out[0] = (uint8_t)((t1 + 2) >> 2);
  intptr_t i = 1;
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
  /* (a 16-bit lane's low byte first: A | B << 8 is the pair in order) */
  for (; i + 8 <= vw && 2 * (i + 7) < w; i += 8) {
    ruk_u8h n0 = ruk_widen8(nr + i - 1), n1 = ruk_widen8(nr + i);
    ruk_u8h a0, a1;
    if (vs == 2) {
      a0 = 3 * n0 + ruk_widen8(fr + i - 1);
      a1 = 3 * n1 + ruk_widen8(fr + i);
    } else {
      a0 = 4 * n0;
      a1 = 4 * n1;
    }
    ruk_u8h lo = (3 * a0 + a1 + 8) >> 4;
    ruk_u8h hi = (3 * a1 + a0 + 8) >> 4;
    ruk_u8h pr = lo | (hi << 8);
    memcpy(out + 2 * i - 1, &pr, 16);
  }
  if (i > 1) t1 = RUK_T(i - 1);
#endif
  for (; i < vw; i++) {
    int t0 = t1;
    t1 = RUK_T(i);
    if (2 * i - 1 < w) out[2 * i - 1] = (uint8_t)((3 * t0 + t1 + 8) >> 4);
    if (2 * i < w) out[2 * i] = (uint8_t)((3 * t1 + t0 + 8) >> 4);
  }
  if (2 * vw - 1 < w) out[2 * vw - 1] = (uint8_t)((t1 + 2) >> 2);
#undef RUK_T
}

/* ---- PNG: the row filters ------------------------------------------------------------------- */

/* the five filters of a row (None, Sub, Up, Average, Paeth) of n bytes, `ch` a pixel, with the
   row above: x the byte, a the one a pixel to its left, b above, c above-left (0 off the edge) */
#define RUK_PAETH_S(a, b, c)                                                                \
  ({ int pa_ = abs((b) - (c)), pb_ = abs((a) - (c)), pc_ = abs((a) + (b) - 2 * (c));        \
     (pa_ <= pb_ && pa_ <= pc_) ? (a) : (pb_ <= pc_ ? (b) : (c)); })

static inline int ruk_png_one(int kind, int x, int a, int b, int c) {
  switch (kind) {
    case 0: return x;
    case 1: return x - a;
    case 2: return x - b;
    case 3: return x - ((a + b) >> 1);
    default: return x - RUK_PAETH_S(a, b, c);
  }
}

#define RUK_ABS16(v) ({ ruk_s8 v_ = (v), s_ = v_ >> 15; (v_ ^ s_) - s_; })
#define RUK_PAETH_V(a, b, c)                                                                \
  ({ ruk_s8 pa_ = RUK_ABS16((b) - (c)), pb_ = RUK_ABS16((a) - (c)),                         \
            pc_ = RUK_ABS16((a) + (b) - 2 * (c));                                           \
     ruk_s8 m1_ = (ruk_s8)(pa_ <= pb_) & (ruk_s8)(pa_ <= pc_), m2_ = (ruk_s8)(pb_ <= pc_);  \
     ((a) & m1_) | (~m1_ & (((b) & m2_) | ((c) & ~m2_))); })
/* (the size of a filtered byte as PNG encoders weigh it: f taken as signed) */
#define RUK_MAG16(f) ({ ruk_s8 d_ = (f) & 255, t_ = 256 - d_, k_ = (ruk_s8)(d_ < t_); (d_ & k_) | (t_ & ~k_); })

/* sums[k]: the sum of the sizes of the row's bytes filtered with filter k, all five at once */
static inline void ruk_png_sums(const uint8_t* cp, const uint8_t* up, intptr_t n, int ch, int64_t* sums) {
  for (int k = 0; k < 5; k++) sums[k] = 0;
  intptr_t i = 0;
  for (; i < n && i < ch; i++)
    for (int k = 0; k < 5; k++) {
      int f = ruk_png_one(k, cp[i], 0, up[i], 0) & 255;
      sums[k] += f < 128 ? f : 256 - f;
    }
  ruk_s8 acc[5] = {{0}, {0}, {0}, {0}, {0}};
  int pend = 0;
  for (; i + 8 <= n; i += 8) {
    ruk_s8 x = (ruk_s8)ruk_widen8(cp + i), a = (ruk_s8)ruk_widen8(cp + i - ch);
    ruk_s8 b = (ruk_s8)ruk_widen8(up + i), c = (ruk_s8)ruk_widen8(up + i - ch);
    acc[0] += RUK_MAG16(x);
    acc[1] += RUK_MAG16(x - a);
    acc[2] += RUK_MAG16(x - b);
    acc[3] += RUK_MAG16(x - ((a + b) >> 1));
    acc[4] += RUK_MAG16(x - RUK_PAETH_V(a, b, c));
    /* (a lane holds 128 at most a step: emptied before it could pass 16 bits) */
    if (++pend == 255) {
      for (int k = 0; k < 5; k++) {
        for (int j = 0; j < 8; j++) sums[k] += (uint16_t)acc[k][j];
        acc[k] = (ruk_s8){0};
      }
      pend = 0;
    }
  }
  for (int k = 0; k < 5; k++)
    for (int j = 0; j < 8; j++) sums[k] += (uint16_t)acc[k][j];
  for (; i < n; i++)
    for (int k = 0; k < 5; k++) {
      int f = ruk_png_one(k, cp[i], cp[i - ch], up[i], up[i - ch]) & 255;
      sums[k] += f < 128 ? f : 256 - f;
    }
}

/* the row filtered with filter `kind` into out */
static inline void ruk_png_filter(uint8_t* out, const uint8_t* cp, const uint8_t* up, intptr_t n, int ch, int kind) {
  intptr_t i = 0;
  if (kind == 0) { memcpy(out, cp, (size_t)n); return; }
  for (; i < n && i < ch; i++) out[i] = (uint8_t)ruk_png_one(kind, cp[i], 0, up[i], 0);
  for (; i + 8 <= n; i += 8) {
    ruk_s8 x = (ruk_s8)ruk_widen8(cp + i), a = (ruk_s8)ruk_widen8(cp + i - ch);
    ruk_s8 b = (ruk_s8)ruk_widen8(up + i), c = (ruk_s8)ruk_widen8(up + i - ch);
    ruk_s8 f;
    switch (kind) {
      case 1: f = x - a; break;
      case 2: f = x - b; break;
      case 3: f = x - ((a + b) >> 1); break;
      default: f = x - RUK_PAETH_V(a, b, c); break;
    }
    for (int j = 0; j < 8; j++) out[i + j] = (uint8_t)f[j];
  }
  for (; i < n; i++) out[i] = (uint8_t)ruk_png_one(kind, cp[i], cp[i - ch], up[i], up[i - ch]);
}

/* ---- zlib: the Adler-32 check ---------------------------------------------------------------- */

/* the check after n more bytes: 16 at a time, each lane holding its column's sum and the sum of
   those sums -- s2 then gets 16 m s1 + 16 (the sums of sums) + (16 - j) times column j's sum;
   the modulo every 5552 bytes, as zlib takes it */
typedef uint32_t ruk_u16w __attribute__((vector_size(64)));
static inline uint32_t ruk_adler32(uint32_t adler, const uint8_t* p, intptr_t n) {
  uint64_t s1 = adler & 0xFFFFu, s2 = adler >> 16;
  while (n > 0) {
    intptr_t blk = n < 5552 ? n : 5552;
    intptr_t m = blk / 16;
    n -= blk;
    if (m > 0) {
      ruk_u16w v1 = {0}, vp = {0};
      for (intptr_t k = 0; k < m; k++, p += 16) {
#if defined(__clang__) || (defined(__GNUC__) && __GNUC__ >= 9)
        ruk_b16 b;
        memcpy(&b, p, 16);
        ruk_u16w w = __builtin_convertvector(b, ruk_u16w);
#else
        ruk_u16w w = {p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7],
                      p[8], p[9], p[10], p[11], p[12], p[13], p[14], p[15]};
#endif
        vp += v1;
        v1 += w;
      }
      uint64_t sp = 0, sw = 0, sc = 0;
      for (int j = 0; j < 16; j++) {
        sp += vp[j];
        sc += v1[j];
        sw += (uint64_t)(16 - j) * v1[j];
      }
      s2 += 16u * (uint64_t)m * s1 + 16u * sp + sw;
      s1 += sc;
    }
    for (intptr_t i = 16 * m; i < blk; i++) {
      s1 += *p++;
      s2 += s1;
    }
    s1 %= 65521u;
    s2 %= 65521u;
  }
  return (uint32_t)((s2 << 16) | s1);
}

/* ---- camera and video frames ------------------------------------------------------------------ */

#define RUK_CLIP8(v) ({ ruk_i8 c_ = (v); c_ &= ~(c_ >> 31); ruk_i8 b_ = (ruk_i8)(c_ > 255); (c_ & ~b_) | (255 & b_); })

/* a webcam's YUYV (4:2:2) row -> opaque RGB: BT.601, limited range, as capture.nim's loop; `pairs`
   pairs of pixels (four bytes each) */
static inline void ruk_yuyv_row(uint32_t* o, const uint8_t* s, intptr_t pairs) {
  intptr_t k = 0;
  for (; k + 4 <= pairs; k += 4, s += 16, o += 8) {
    ruk_i8 yy = {s[0], s[2], s[4], s[6], s[8], s[10], s[12], s[14]};
    ruk_i8 u = {s[1], s[1], s[5], s[5], s[9], s[9], s[13], s[13]};
    ruk_i8 v = {s[3], s[3], s[7], s[7], s[11], s[11], s[15], s[15]};
    yy = (yy - 16) * 298;
    u -= 128;
    v -= 128;
    ruk_i8 r = RUK_CLIP8((yy + 409 * v + 128) >> 8);
    ruk_i8 g = RUK_CLIP8((yy + (-100 * u - 208 * v + 128)) >> 8);
    ruk_i8 b = RUK_CLIP8((yy + 516 * u + 128) >> 8);
    ruk_i8 p = (r << 16) | (g << 8) | b | (ruk_i8){-16777216, -16777216, -16777216, -16777216,
                                                   -16777216, -16777216, -16777216, -16777216};
    memcpy(o, &p, 32);
  }
  for (; k < pairs; k++, s += 4, o += 2) {
    int y0 = (s[0] - 16) * 298, u = s[1] - 128, y1 = (s[2] - 16) * 298, v = s[3] - 128;
    int r = 409 * v + 128, g = -100 * u - 208 * v + 128, b = 516 * u + 128;
#define RUK_C(x) ((uint32_t)((x) < 0 ? 0 : (x) > 255 ? 255 : (x)))
    o[0] = 0xFF000000u | RUK_C((y0 + r) >> 8) << 16 | RUK_C((y0 + g) >> 8) << 8 | RUK_C((y0 + b) >> 8);
    o[1] = 0xFF000000u | RUK_C((y1 + r) >> 8) << 16 | RUK_C((y1 + g) >> 8) << 8 | RUK_C((y1 + b) >> 8);
#undef RUK_C
  }
}

/* a row of pixels -> a video's luma bytes, limited range: (cr R + cg G + cb B + 32768) >> 16 + 16
   clamped to 16 .. 235, as media.nim's loop */
static inline void ruk_luma_row(uint8_t* o, const uint32_t* px, intptr_t n, int32_t cr, int32_t cg, int32_t cb) {
  intptr_t i = 0;
  for (; i + 8 <= n; i += 8) {
    ruk_i8 p;
    memcpy(&p, px + i, 32);
    ruk_i8 r = (p >> 16) & 255, g = (p >> 8) & 255, b = p & 255;
    ruk_i8 y = ((cr * r + cg * g + cb * b + 32768) >> 16) + 16;
    ruk_i8 lo = (ruk_i8)(y < 16), hi = (ruk_i8)(y > 235);
    y = (y & ~lo & ~hi) | (16 & lo) | (235 & hi);
    for (int j = 0; j < 8; j++) o[i + j] = (uint8_t)y[j];
  }
  for (; i < n; i++) {
    uint32_t p = px[i];
    int32_t y = ((cr * (int32_t)((p >> 16) & 255) + cg * (int32_t)((p >> 8) & 255) + cb * (int32_t)(p & 255) +
                  32768) >> 16) + 16;
    o[i] = (uint8_t)(y < 16 ? 16 : y > 235 ? 235 : y);
  }
}

/* ---- a picture read through a column table ------------------------------------------------ */

/* dst[i] = src[xs[i]] for i from 0 while xs[i] >= 0 and that pixel is opaque; how many were done
   (the caller does the one it stopped at its own way) -- a zoomed view's row */
#define RUK_GATHER_BODY                                                             \
  intptr_t i = 0;                                                                   \
  for (; i + 4 <= n; i += 4) {                                                      \
    int32_t a0 = xs[i], a1 = xs[i + 1], a2 = xs[i + 2], a3 = xs[i + 3];             \
    if ((a0 | a1 | a2 | a3) < 0) break;                                             \
    uint32_t p0 = src[a0], p1 = src[a1], p2 = src[a2], p3 = src[a3];                \
    if ((p0 & p1 & p2 & p3) < 0xFF000000u) break;                                   \
    dst[i] = p0; dst[i + 1] = p1; dst[i + 2] = p2; dst[i + 3] = p3;                 \
  }                                                                                 \
  for (; i < n; i++) {                                                              \
    int32_t a = xs[i];                                                              \
    if (a < 0) break;                                                               \
    uint32_t p = src[a];                                                            \
    if (p < 0xFF000000u) break;                                                     \
    dst[i] = p;                                                                     \
  }                                                                                 \
  return i;

static inline intptr_t ruk_gather_opaque1(uint32_t* dst, const uint32_t* src, const int32_t* xs, intptr_t n) {
  RUK_GATHER_BODY
}
#if (defined(__x86_64__) || defined(__i386__)) && (defined(__GNUC__) || defined(__clang__))
__attribute__((target("avx2"))) static intptr_t ruk_gather_opaque2(uint32_t* dst, const uint32_t* src,
                                                                  const int32_t* xs, intptr_t n) {
  RUK_GATHER_BODY
}
#endif
static inline intptr_t ruk_gather_opaque(uint32_t* dst, const uint32_t* src, const int32_t* xs, intptr_t n) {
#if (defined(__x86_64__) || defined(__i386__)) && (defined(__GNUC__) || defined(__clang__))
  if (ruk_has_avx2()) return ruk_gather_opaque2(dst, src, xs, n);
#endif
  return ruk_gather_opaque1(dst, src, xs, n);
}

/* ---- where a layer has something --------------------------------------------------------- */

/* The first pixel from p (of n) whose alpha is not 0, four at a time; n when none. */
static inline intptr_t ruk_first_alpha(const uint32_t* p, intptr_t n) {
  intptr_t i = 0;
  const ruk_u4 am = {0xFF000000u, 0xFF000000u, 0xFF000000u, 0xFF000000u};
  for (; i + 16 <= n; i += 16) {
    ruk_u4 v = (ruk_load4(p + i) | ruk_load4(p + i + 4) | ruk_load4(p + i + 8) | ruk_load4(p + i + 12)) & am;
    uint64_t t[2];
    memcpy(t, &v, 16);
    if (t[0] | t[1]) break;
  }
  for (; i < n; i++) if (p[i] >> 24) return i;
  return n;
}

/* The last pixel before p + n (of n) whose alpha is not 0, four at a time; -1 when none. */
static inline intptr_t ruk_last_alpha(const uint32_t* p, intptr_t n) {
  intptr_t i = n;
  const ruk_u4 am = {0xFF000000u, 0xFF000000u, 0xFF000000u, 0xFF000000u};
  for (; i - 16 >= 0; i -= 16) {
    const uint32_t* q = p + i - 16;
    ruk_u4 v = (ruk_load4(q) | ruk_load4(q + 4) | ruk_load4(q + 8) | ruk_load4(q + 12)) & am;
    uint64_t t[2];
    memcpy(t, &v, 16);
    if (t[0] | t[1]) break;
  }
  for (i = i - 1; i >= 0; i--) if (p[i] >> 24) return i;
  return -1;
}

#endif
