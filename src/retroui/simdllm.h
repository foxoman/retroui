/* A language model's hot loops (`retroui/llm`): a row of weights times the input, sixteen weights
   at a time, with GCC's and Clang's own vectors -- SSE2 on x86-64 (AVX2 picked at run time), NEON
   on ARM, SIMD128 in a web page, lane by lane where there is none.

   The ternary kinds (-1, 0, 1 a weight) take the input as whole numbers (`ruk_quant8`: as BitNet
   b1.58 was taught, a scale for the vector and -127 .. 127), Q8_0 and Q4_0 too (a scale for each
   32, as llama.cpp does), so their sums are exact, and the same with every set of vectors; F16
   and F32 rows take it as floats.

   Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net */
#ifndef RUK_SIMDLLM_H
#define RUK_SIMDLLM_H
#include <math.h>
#include "simdkit.h"

typedef int8_t ruk_llm_i8 __attribute__((vector_size(16)));
typedef uint8_t ruk_llm_u8 __attribute__((vector_size(16)));
typedef int16_t ruk_llm_s16 __attribute__((vector_size(32)));
typedef int32_t ruk_llm_s32 __attribute__((vector_size(64)));
typedef uint16_t ruk_llm_h8 __attribute__((vector_size(16)));
typedef uint32_t ruk_llm_u32 __attribute__((vector_size(32)));
typedef float ruk_llm_f8 __attribute__((vector_size(32)));
typedef int8_t ruk_llm_c8 __attribute__((vector_size(8)));
typedef uint8_t ruk_llm_b8 __attribute__((vector_size(8)));
typedef int32_t ruk_llm_i32x8 __attribute__((vector_size(32)));
typedef float ruk_llm_f16 __attribute__((vector_size(64)));

#if (defined(__x86_64__) || defined(__i386__)) && (defined(__GNUC__) || defined(__clang__))
#define RUK_LLM_X86 1
#endif

/* (macros, not functions: a 32-byte vector handed between a function of no AVX and one of AVX2
   goes two ways -- in a register, in memory -- and a build without optimizing would call one;
   tools/warncheck.sh looks for any) */
#define ruk_llm_w16(p) ({ ruk_llm_u8 v_; memcpy(&v_, (p), 16); __builtin_convertvector(v_, ruk_llm_s16); })
#define ruk_llm_x16(p) ({ ruk_llm_i8 v_; memcpy(&v_, (p), 16); __builtin_convertvector(v_, ruk_llm_s16); })
static inline int32_t ruk_llm_hsum(const ruk_llm_s32* v) {
  int32_t s = 0;
  for (int i = 0; i < 16; i++) s += (*v)[i];
  return s;
}
static inline float ruk_llm_hsumf(const ruk_llm_f8* p) {
  ruk_llm_f8 v = *p;
  return ((v[0] + v[1]) + (v[2] + v[3])) + ((v[4] + v[5]) + (v[6] + v[7]));
}
static inline float ruk_llm_h2f(uint16_t h) {
  /* a half as a float: its bits moved into place, scaled by 2^112 (subnormals too) */
  uint32_t b = ((uint32_t)(h & 0x7FFFu)) << 13;
  float v; memcpy(&v, &b, 4);
  v *= 5.192296858534828e33f;
  memcpy(&b, &v, 4);
  b |= ((uint32_t)(h & 0x8000u)) << 16;
  memcpy(&v, &b, 4);
  return v;
}

/* The input as whole numbers: x * 127 / its largest, rounded half away from 0 (C's roundf);
   the scale back (largest / 127), 0 when it is all 0. */
static inline float ruk_quant8(const float* x, int8_t* q, intptr_t n) {
  float top = 0;
  for (intptr_t i = 0; i < n; i++) { float a = fabsf(x[i]); if (a > top) top = a; }
  if (top == 0) { memset(q, 0, (size_t)n); return 0; }
  float k = 127.0f / top;
  for (intptr_t i = 0; i < n; i++) {
    float v = roundf(x[i] * k);
    q[i] = (int8_t)(v > 127 ? 127 : v < -128 ? -128 : v);
  }
  return top / 127.0f;
}

/* ---- I2_S: bitnet.cpp's, as it packs it on x86 ---------------------------------------------
   128 weights a block in 32 bytes, byte i holding weights i, 32+i, 64+i, 96+i in its bits 7-6,
   5-4, 3-2, 1-0: codes 0, 1, 2 for -1, 0, 1. The codes times the input (the caller takes off the
   input's sum once: a code is its weight + 1). */
#define RUK_I2S_BODY                                                                        \
  ruk_llm_s32 acc = {0};                                                                    \
  for (intptr_t b = 0; b < cols / 128; b++) {                                               \
    const uint8_t* q = p + b * 32;                                                          \
    const int8_t* x = xq + b * 128;                                                         \
    ruk_llm_s16 s = {0};                                                                    \
    for (int i = 0; i < 32; i += 16) {                                                      \
      ruk_llm_s16 v = ruk_llm_w16(q + i);                                                   \
      s += (v >> 6) * ruk_llm_x16(x + i) + ((v >> 4) & 3) * ruk_llm_x16(x + 32 + i) +       \
           ((v >> 2) & 3) * ruk_llm_x16(x + 64 + i) + (v & 3) * ruk_llm_x16(x + 96 + i);    \
    }                                                                                       \
    acc += __builtin_convertvector(s, ruk_llm_s32);                                         \
  }                                                                                         \
  return ruk_llm_hsum(&acc);

static inline int32_t ruk_i2s_dot1(const uint8_t* p, const int8_t* xq, intptr_t cols) { RUK_I2S_BODY }
#ifdef RUK_LLM_X86
__attribute__((target("avx2"))) static int32_t ruk_i2s_dot2(const uint8_t* p, const int8_t* xq, intptr_t cols) {
  RUK_I2S_BODY
}
#endif
static inline int32_t ruk_i2s_dot(const uint8_t* p, const int8_t* xq, intptr_t cols) {
#ifdef RUK_LLM_X86
  if (ruk_has_avx2()) return ruk_i2s_dot2(p, xq, cols);
#endif
  return ruk_i2s_dot1(p, xq, cols);
}

/* ---- TQ2_0: ggml's --------------------------------------------------------------------------
   256 weights a block: 64 bytes, byte 32j+i holding weights 128j+32l+i in its bits 2l+1..2l
   (codes as I2_S's), then the block's scale, a half. bsum: the input's sum, block by block. */
#define RUK_TQ2_BODY                                                                        \
  float r = 0;                                                                              \
  for (intptr_t b = 0; b < cols / 256; b++) {                                               \
    const uint8_t* q = p + b * 66;                                                          \
    const int8_t* x = xq + b * 256;                                                         \
    ruk_llm_s16 s = {0};                                                                    \
    for (int j = 0; j < 2; j++)                                                             \
      for (int i = 0; i < 32; i += 16) {                                                    \
        ruk_llm_s16 v = ruk_llm_w16(q + j * 32 + i);                                        \
        const int8_t* xj = x + j * 128 + i;                                                 \
        s += (v & 3) * ruk_llm_x16(xj) + ((v >> 2) & 3) * ruk_llm_x16(xj + 32) +            \
             ((v >> 4) & 3) * ruk_llm_x16(xj + 64) + (v >> 6) * ruk_llm_x16(xj + 96);       \
      }                                                                                     \
    ruk_llm_s32 w = __builtin_convertvector(s, ruk_llm_s32);                                \
    int32_t t = ruk_llm_hsum(&w) - bsum[b];                                                 \
    r += ruk_llm_h2f((uint16_t)(q[64] | (q[65] << 8))) * (float)t;                          \
  }                                                                                         \
  return r;

static inline float ruk_tq2_dot1(const uint8_t* p, const int8_t* xq, const int32_t* bsum, intptr_t cols) {
  RUK_TQ2_BODY
}
#ifdef RUK_LLM_X86
__attribute__((target("avx2"))) static float ruk_tq2_dot2(const uint8_t* p, const int8_t* xq,
                                                         const int32_t* bsum, intptr_t cols) {
  RUK_TQ2_BODY
}
#endif
static inline float ruk_tq2_dot(const uint8_t* p, const int8_t* xq, const int32_t* bsum, intptr_t cols) {
#ifdef RUK_LLM_X86
  if (ruk_has_avx2()) return ruk_tq2_dot2(p, xq, bsum, cols);
#endif
  return ruk_tq2_dot1(p, xq, bsum, cols);
}

/* ---- TQ1_0: ggml's --------------------------------------------------------------------------
   256 weights a block: 48 bytes of five base-3 digits, 4 of four, then the scale. Digit n of a
   byte q: ((q * 3^n) mod 256 * 3) >> 8 -- 0, 1, 2, a code. Bytes 0..31 hold weights 32n+i,
   32..47 hold 160+16n+i, 48..51 hold 240+4n+i. */
#define RUK_TQ1_DIGITS(v, n) (((((v) * (n)) & 255) * 3) >> 8)
#define RUK_TQ1_BODY                                                                        \
  static const int16_t pw[5] = {1, 3, 9, 27, 81};                                           \
  float r = 0;                                                                              \
  for (intptr_t b = 0; b < cols / 256; b++) {                                               \
    const uint8_t* q = p + b * 54;                                                          \
    const int8_t* x = xq + b * 256;                                                         \
    ruk_llm_s16 s = {0};                                                                    \
    for (int i = 0; i < 32; i += 16) {                                                      \
      ruk_llm_s16 v = ruk_llm_w16(q + i);                                                   \
      for (int n = 0; n < 5; n++) s += RUK_TQ1_DIGITS(v, pw[n]) * ruk_llm_x16(x + n * 32 + i); \
    }                                                                                       \
    {                                                                                       \
      ruk_llm_s16 v = ruk_llm_w16(q + 32);                                                  \
      for (int n = 0; n < 5; n++) s += RUK_TQ1_DIGITS(v, pw[n]) * ruk_llm_x16(x + 160 + n * 16); \
    }                                                                                       \
    ruk_llm_s32 w = __builtin_convertvector(s, ruk_llm_s32);                                \
    int32_t t = ruk_llm_hsum(&w);                                                           \
    for (int n = 0; n < 4; n++)                                                             \
      for (int j = 0; j < 4; j++) t += RUK_TQ1_DIGITS((int)q[48 + j], pw[n]) * x[240 + n * 4 + j]; \
    t -= bsum[b];                                                                           \
    r += ruk_llm_h2f((uint16_t)(q[52] | (q[53] << 8))) * (float)t;                          \
  }                                                                                         \
  return r;

static inline float ruk_tq1_dot1(const uint8_t* p, const int8_t* xq, const int32_t* bsum, intptr_t cols) {
  RUK_TQ1_BODY
}
#ifdef RUK_LLM_X86
__attribute__((target("avx2"))) static float ruk_tq1_dot2(const uint8_t* p, const int8_t* xq,
                                                         const int32_t* bsum, intptr_t cols) {
  RUK_TQ1_BODY
}
#endif
static inline float ruk_tq1_dot(const uint8_t* p, const int8_t* xq, const int32_t* bsum, intptr_t cols) {
#ifdef RUK_LLM_X86
  if (ruk_has_avx2()) return ruk_tq1_dot2(p, xq, bsum, cols);
#endif
  return ruk_tq1_dot1(p, xq, bsum, cols);
}

/* ---- Q8_0 and Q4_0 rows, the input as whole numbers too -------------------------------------
   As llama.cpp does it: the input 32 at a time made whole numbers, each 32 with its own scale
   (xd: `ruk_quant8` a block at a time), the sums exact within a block. Q8_0: 32 weights a block,
   a half scale then 32 signed bytes; Q4_0: a half scale then 16 bytes, the low four bits weights
   0..15 and the high 16..31, each less 8. */
#define RUK_Q8I_BODY                                                                        \
  ruk_llm_f16 acc = {0};                                                                    \
  for (intptr_t b = 0; b < cols / 32; b++) {                                                \
    const uint8_t* q = p + b * 34;                                                          \
    const int8_t* x = xq + b * 32;                                                          \
    ruk_llm_s16 v0 = ruk_llm_x16((const int8_t*)q + 2) * ruk_llm_x16(x);                    \
    ruk_llm_s16 v1 = ruk_llm_x16((const int8_t*)q + 18) * ruk_llm_x16(x + 16);              \
    ruk_llm_s32 w = __builtin_convertvector(v0, ruk_llm_s32) + __builtin_convertvector(v1, ruk_llm_s32); \
    acc += __builtin_convertvector(w, ruk_llm_f16) * (ruk_llm_h2f((uint16_t)(q[0] | (q[1] << 8))) * xd[b]); \
  }                                                                                         \
  ruk_llm_f8 lo, hi; memcpy(&lo, &acc, 32); memcpy(&hi, (const char*)&acc + 32, 32);        \
  ruk_llm_f8 lh = lo + hi;                                                                  \
  return ruk_llm_hsumf(&lh);

static inline float ruk_q8i_dot1(const uint8_t* p, const int8_t* xq, const float* xd, intptr_t cols) {
  RUK_Q8I_BODY
}
#ifdef RUK_LLM_X86
__attribute__((target("avx2"))) static float ruk_q8i_dot2(const uint8_t* p, const int8_t* xq, const float* xd,
                                                          intptr_t cols) {
  RUK_Q8I_BODY
}
#endif
static inline float ruk_q8i_dot(const uint8_t* p, const int8_t* xq, const float* xd, intptr_t cols) {
#ifdef RUK_LLM_X86
  if (ruk_has_avx2()) return ruk_q8i_dot2(p, xq, xd, cols);
#endif
  return ruk_q8i_dot1(p, xq, xd, cols);
}

#define RUK_Q4I_BODY                                                                        \
  ruk_llm_f16 acc = {0};                                                                    \
  for (intptr_t b = 0; b < cols / 32; b++) {                                                \
    const uint8_t* q = p + b * 18;                                                          \
    const int8_t* x = xq + b * 32;                                                          \
    ruk_llm_s16 v = ruk_llm_w16(q + 2);                                                     \
    ruk_llm_s16 t = ((v & 15) - 8) * ruk_llm_x16(x) + ((v >> 4) - 8) * ruk_llm_x16(x + 16); \
    ruk_llm_s32 w = __builtin_convertvector(t, ruk_llm_s32);                                \
    acc += __builtin_convertvector(w, ruk_llm_f16) * (ruk_llm_h2f((uint16_t)(q[0] | (q[1] << 8))) * xd[b]); \
  }                                                                                         \
  ruk_llm_f8 lo, hi; memcpy(&lo, &acc, 32); memcpy(&hi, (const char*)&acc + 32, 32);        \
  ruk_llm_f8 lh = lo + hi;                                                                  \
  return ruk_llm_hsumf(&lh);

static inline float ruk_q4i_dot1(const uint8_t* p, const int8_t* xq, const float* xd, intptr_t cols) {
  RUK_Q4I_BODY
}
#ifdef RUK_LLM_X86
__attribute__((target("avx2"))) static float ruk_q4i_dot2(const uint8_t* p, const int8_t* xq, const float* xd,
                                                          intptr_t cols) {
  RUK_Q4I_BODY
}
#endif
static inline float ruk_q4i_dot(const uint8_t* p, const int8_t* xq, const float* xd, intptr_t cols) {
#ifdef RUK_LLM_X86
  if (ruk_has_avx2()) return ruk_q4i_dot2(p, xq, xd, cols);
#endif
  return ruk_q4i_dot1(p, xq, xd, cols);
}

/* ---- the input as floats: F16, F32, Q8_0, Q4_0 rows ------------------------------------------ */

#define RUK_F16_BODY                                                                        \
  ruk_llm_f8 a0 = {0}, a1 = {0};                                                            \
  const ruk_llm_u32 mag = {0x7FFFu, 0x7FFFu, 0x7FFFu, 0x7FFFu, 0x7FFFu, 0x7FFFu, 0x7FFFu, 0x7FFFu}; \
  const ruk_llm_u32 sgn = {0x8000u, 0x8000u, 0x8000u, 0x8000u, 0x8000u, 0x8000u, 0x8000u, 0x8000u}; \
  const float k = 5.192296858534828e33f;                                                    \
  intptr_t i = 0;                                                                           \
  for (; i + 16 <= n; i += 16) {                                                            \
    ruk_llm_h8 h0, h1; ruk_llm_f8 x0, x1;                                                   \
    memcpy(&h0, w + i, 16); memcpy(&h1, w + i + 8, 16);                                     \
    memcpy(&x0, x + i, 32); memcpy(&x1, x + i + 8, 32);                                     \
    ruk_llm_u32 u0 = __builtin_convertvector(h0, ruk_llm_u32);                              \
    ruk_llm_u32 u1 = __builtin_convertvector(h1, ruk_llm_u32);                              \
    ruk_llm_f8 f0 = (ruk_llm_f8)((u0 & mag) << 13) * k;                                     \
    ruk_llm_f8 f1 = (ruk_llm_f8)((u1 & mag) << 13) * k;                                     \
    f0 = (ruk_llm_f8)((ruk_llm_u32)f0 | ((u0 & sgn) << 16));                                \
    f1 = (ruk_llm_f8)((ruk_llm_u32)f1 | ((u1 & sgn) << 16));                                \
    a0 += f0 * x0; a1 += f1 * x1;                                                           \
  }                                                                                         \
  ruk_llm_f8 a01 = a0 + a1;                                                                 \
  float r = ruk_llm_hsumf(&a01);                                                         \
  for (; i < n; i++) r += ruk_llm_h2f(w[i]) * x[i];                                         \
  return r;

static inline float ruk_f16_dot1(const uint16_t* w, const float* x, intptr_t n) { RUK_F16_BODY }
#ifdef RUK_LLM_X86
__attribute__((target("avx2"))) static float ruk_f16_dot2(const uint16_t* w, const float* x, intptr_t n) {
  RUK_F16_BODY
}
#endif
#ifdef RUK_LLM_X86
#include <immintrin.h>
/* (with AVX2, F16C: the halves widened by the processor itself) */
__attribute__((target("avx2,f16c,fma"))) static float ruk_f16_dot3(const uint16_t* w, const float* x, intptr_t n) {
  __m256 a0 = _mm256_setzero_ps(), a1 = _mm256_setzero_ps();
  intptr_t i = 0;
  for (; i + 16 <= n; i += 16) {
    __m256 f0 = _mm256_cvtph_ps(_mm_loadu_si128((const __m128i*)(w + i)));
    __m256 f1 = _mm256_cvtph_ps(_mm_loadu_si128((const __m128i*)(w + i + 8)));
    a0 = _mm256_fmadd_ps(f0, _mm256_loadu_ps(x + i), a0);
    a1 = _mm256_fmadd_ps(f1, _mm256_loadu_ps(x + i + 8), a1);
  }
  ruk_llm_f8 v; __m256 s = _mm256_add_ps(a0, a1); memcpy(&v, &s, 32);
  float r = ruk_llm_hsumf(&v);
  for (; i < n; i++) r += ruk_llm_h2f(w[i]) * x[i];
  return r;
}
static volatile int ruk_f16c_state = -1;
static inline int ruk_has_f16c(void) {
  int s = ruk_f16c_state;
  if (s >= 0) return s;
  unsigned a, b, c, d;
  s = ruk_has_avx2() && __get_cpuid(1, &a, &b, &c, &d) && (c & (1u << 29)) && (c & (1u << 12)) ? 1 : 0;
  ruk_f16c_state = s;
  return s;
}
#endif
#if defined(__aarch64__) && (defined(__GNUC__) || defined(__clang__))
#include <arm_neon.h>
#endif
static inline float ruk_f16_dot(const uint16_t* w, const float* x, intptr_t n) {
#ifdef RUK_LLM_X86
  if (ruk_has_avx2()) return ruk_has_f16c() ? ruk_f16_dot3(w, x, n) : ruk_f16_dot2(w, x, n);
#elif defined(__aarch64__) && (defined(__GNUC__) || defined(__clang__))
  /* (64-bit ARM widens halves itself) */
  float32x4_t a0 = vdupq_n_f32(0), a1 = vdupq_n_f32(0), a2 = vdupq_n_f32(0), a3 = vdupq_n_f32(0);
  intptr_t i = 0;
  for (; i + 16 <= n; i += 16) {
    float16x8_t h0 = vreinterpretq_f16_u16(vld1q_u16(w + i));
    float16x8_t h1 = vreinterpretq_f16_u16(vld1q_u16(w + i + 8));
    a0 = vfmaq_f32(a0, vcvt_f32_f16(vget_low_f16(h0)), vld1q_f32(x + i));
    a1 = vfmaq_f32(a1, vcvt_high_f32_f16(h0), vld1q_f32(x + i + 4));
    a2 = vfmaq_f32(a2, vcvt_f32_f16(vget_low_f16(h1)), vld1q_f32(x + i + 8));
    a3 = vfmaq_f32(a3, vcvt_high_f32_f16(h1), vld1q_f32(x + i + 12));
  }
  float r = vaddvq_f32(vaddq_f32(vaddq_f32(a0, a1), vaddq_f32(a2, a3)));
  for (; i < n; i++) r += ruk_llm_h2f(w[i]) * x[i];
  return r;
#endif
  return ruk_f16_dot1(w, x, n);
}

#define RUK_F32_BODY                                                                        \
  ruk_llm_f8 a0 = {0}, a1 = {0};                                                            \
  intptr_t i = 0;                                                                           \
  for (; i + 16 <= n; i += 16) {                                                            \
    ruk_llm_f8 w0, w1, x0, x1;                                                              \
    memcpy(&w0, w + i, 32); memcpy(&w1, w + i + 8, 32);                                     \
    memcpy(&x0, x + i, 32); memcpy(&x1, x + i + 8, 32);                                     \
    a0 += w0 * x0; a1 += w1 * x1;                                                           \
  }                                                                                         \
  ruk_llm_f8 a01 = a0 + a1;                                                                 \
  float r = ruk_llm_hsumf(&a01);                                                         \
  for (; i < n; i++) r += w[i] * x[i];                                                      \
  return r;

static inline float ruk_f32_dot1(const float* w, const float* x, intptr_t n) { RUK_F32_BODY }
#ifdef RUK_LLM_X86
__attribute__((target("avx2"))) static float ruk_f32_dot2(const float* w, const float* x, intptr_t n) {
  RUK_F32_BODY
}
#endif
static inline float ruk_f32_dot(const float* w, const float* x, intptr_t n) {
#ifdef RUK_LLM_X86
  if (ruk_has_avx2()) return ruk_f32_dot2(w, x, n);
#endif
  return ruk_f32_dot1(w, x, n);
}

/* Q8_0: 32 weights a block, a half scale then 32 signed bytes. Q4_0: a half scale then 16 bytes,
   the low four bits weights 0..15, the high 16..31, each less 8. */
#define RUK_Q8_BODY                                                                         \
  ruk_llm_f16 acc = {0};                                                                    \
  for (intptr_t b = 0; b < cols / 32; b++) {                                                \
    const uint8_t* q = p + b * 34;                                                          \
    const float* xs = x + b * 32;                                                           \
    ruk_llm_f16 x0, x1; memcpy(&x0, xs, 64); memcpy(&x1, xs + 16, 64);                      \
    ruk_llm_f16 w0 = __builtin_convertvector(__builtin_convertvector(ruk_llm_x16((const int8_t*)q + 2), ruk_llm_s32), ruk_llm_f16); \
    ruk_llm_f16 w1 = __builtin_convertvector(__builtin_convertvector(ruk_llm_x16((const int8_t*)q + 18), ruk_llm_s32), ruk_llm_f16); \
    acc += (w0 * x0 + w1 * x1) * ruk_llm_h2f((uint16_t)(q[0] | (q[1] << 8)));             \
  }                                                                                         \
  ruk_llm_f8 lo, hi; memcpy(&lo, &acc, 32); memcpy(&hi, (const char*)&acc + 32, 32);        \
  ruk_llm_f8 lh = lo + hi;                                                                  \
  return ruk_llm_hsumf(&lh);

static inline float ruk_q8_dot1(const uint8_t* p, const float* x, intptr_t cols) { RUK_Q8_BODY }
#ifdef RUK_LLM_X86
__attribute__((target("avx2"))) static float ruk_q8_dot2(const uint8_t* p, const float* x, intptr_t cols) {
  RUK_Q8_BODY
}
#endif
static inline float ruk_q8_dot(const uint8_t* p, const float* x, intptr_t cols) {
#ifdef RUK_LLM_X86
  if (ruk_has_avx2()) return ruk_q8_dot2(p, x, cols);
#endif
  return ruk_q8_dot1(p, x, cols);
}

#define RUK_Q4_BODY                                                                         \
  ruk_llm_f16 acc = {0};                                                                    \
  for (intptr_t b = 0; b < cols / 32; b++) {                                                \
    const uint8_t* q = p + b * 18;                                                          \
    const float* xs = x + b * 32;                                                           \
    ruk_llm_f16 x0, x1; memcpy(&x0, xs, 64); memcpy(&x1, xs + 16, 64);                      \
    ruk_llm_s16 v = ruk_llm_w16(q + 2);                                                     \
    ruk_llm_f16 lo = __builtin_convertvector(__builtin_convertvector((v & 15) - 8, ruk_llm_s32), ruk_llm_f16); \
    ruk_llm_f16 hi = __builtin_convertvector(__builtin_convertvector((v >> 4) - 8, ruk_llm_s32), ruk_llm_f16); \
    acc += (lo * x0 + hi * x1) * ruk_llm_h2f((uint16_t)(q[0] | (q[1] << 8)));             \
  }                                                                                         \
  ruk_llm_f8 l8, h8; memcpy(&l8, &acc, 32); memcpy(&h8, (const char*)&acc + 32, 32);        \
  ruk_llm_f8 lh = l8 + h8;                                                                  \
  return ruk_llm_hsumf(&lh);

static inline float ruk_q4_dot1(const uint8_t* p, const float* x, intptr_t cols) { RUK_Q4_BODY }
#ifdef RUK_LLM_X86
__attribute__((target("avx2"))) static float ruk_q4_dot2(const uint8_t* p, const float* x, intptr_t cols) {
  RUK_Q4_BODY
}
#endif
static inline float ruk_q4_dot(const uint8_t* p, const float* x, intptr_t cols) {
#ifdef RUK_LLM_X86
  if (ruk_has_avx2()) return ruk_q4_dot2(p, x, cols);
#endif
  return ruk_q4_dot1(p, x, cols);
}

#endif
