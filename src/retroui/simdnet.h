/* An image model's hot loop (`retroui/nnet`): the matrix product that convolutions, linear
   layers and attention come down to, sixteen columns and four rows at a time, with GCC's and
   Clang's own vectors -- SSE2 on x86-64 (AVX2 with FMA picked at run time), NEON on ARM,
   SIMD128 in a web page, lane by lane where there is none.

   c[m x n] (+)= a[m x k] * b[k x n], each row of the three `ld` floats after the one before. The
   caller shares the columns among the cores (`ruk_net_gemm(.., j0, j1)`: columns j0 ..< j1); each
   takes k in blocks of 256, so the block of b it works on (256 x 16 floats, copied side by side)
   stays in the first cache while every row of a goes past it.

   Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net */
#ifndef RUK_SIMDNET_H
#define RUK_SIMDNET_H
#include "simdkit.h"

typedef float ruk_net_v4 __attribute__((vector_size(16)));
typedef float ruk_net_v8 __attribute__((vector_size(32)));
typedef int32_t ruk_net_i4 __attribute__((vector_size(16)));
typedef int32_t ruk_net_i8 __attribute__((vector_size(32)));

#if (defined(__x86_64__) || defined(__i386__)) && (defined(__GNUC__) || defined(__clang__))
#define RUK_NET_X86 1
#endif

#define RUK_NET_KB 256

/* Four rows of c, sixteen columns, k from t0 to t1, b's block packed (16 floats a row). The sums
   in vectors of the machine's own width, so they stay in its registers: two of eight floats a row
   with AVX2; four floats at a time elsewhere, the sixteen columns in two halves of eight. */
#define RUK_NET_ROWS4 const float* a0 = a; const float* a1 = a + lda; const float* a2 = a + 2 * lda; \
  const float* a3 = a + 3 * lda;

#define RUK_NET_TILE4_V8                                                                        \
  RUK_NET_ROWS4                                                                                 \
  ruk_net_v8 c00 = {0}, c01 = {0}, c10 = {0}, c11 = {0}, c20 = {0}, c21 = {0}, c30 = {0}, c31 = {0}; \
  for (intptr_t t = t0; t < t1; t++) {                                                          \
    ruk_net_v8 b0, b1; memcpy(&b0, b + t * 16, 32); memcpy(&b1, b + t * 16 + 8, 32);            \
    float x0 = a0[t], x1 = a1[t], x2 = a2[t], x3 = a3[t];                                       \
    c00 += x0 * b0; c01 += x0 * b1; c10 += x1 * b0; c11 += x1 * b1;                             \
    c20 += x2 * b0; c21 += x2 * b1; c30 += x3 * b0; c31 += x3 * b1;                             \
  }                                                                                             \
  RUK_NET_PUT8(c, c00, c01) RUK_NET_PUT8(c + ldc, c10, c11)                                     \
  RUK_NET_PUT8(c + 2 * ldc, c20, c21) RUK_NET_PUT8(c + 3 * ldc, c30, c31)

#define RUK_NET_PUT8(p, u, v) { ruk_net_v8 o0 = u, o1 = v;                                     \
  if (!ov) { ruk_net_v8 q0, q1; memcpy(&q0, (p), 32); memcpy(&q1, (p) + 8, 32); o0 += q0; o1 += q1; } \
  memcpy((p), &o0, 32); memcpy((p) + 8, &o1, 32); }

#define RUK_NET_TILE4_V4                                                                        \
  RUK_NET_ROWS4                                                                                 \
  for (int half = 0; half < 16; half += 8) {                                                    \
    ruk_net_v4 c00 = {0}, c01 = {0}, c10 = {0}, c11 = {0}, c20 = {0}, c21 = {0}, c30 = {0}, c31 = {0}; \
    for (intptr_t t = t0; t < t1; t++) {                                                        \
      ruk_net_v4 b0, b1; memcpy(&b0, b + t * 16 + half, 16); memcpy(&b1, b + t * 16 + half + 4, 16); \
      float x0 = a0[t], x1 = a1[t], x2 = a2[t], x3 = a3[t];                                     \
      c00 += x0 * b0; c01 += x0 * b1; c10 += x1 * b0; c11 += x1 * b1;                           \
      c20 += x2 * b0; c21 += x2 * b1; c30 += x3 * b0; c31 += x3 * b1;                           \
    }                                                                                           \
    RUK_NET_PUT4(c + half, c00, c01) RUK_NET_PUT4(c + ldc + half, c10, c11)                     \
    RUK_NET_PUT4(c + 2 * ldc + half, c20, c21) RUK_NET_PUT4(c + 3 * ldc + half, c30, c31)       \
  }

#define RUK_NET_PUT4(p, u, v) { ruk_net_v4 o0 = u, o1 = v;                                     \
  if (!ov) { ruk_net_v4 q0, q1; memcpy(&q0, (p), 16); memcpy(&q1, (p) + 4, 16); o0 += q0; o1 += q1; } \
  memcpy((p), &o0, 16); memcpy((p) + 4, &o1, 16); }

/* one row (the rows past the last four) */
#define RUK_NET_TILE1_V8                                                                        \
  ruk_net_v8 c0 = {0}, c1 = {0};                                                                \
  for (intptr_t t = t0; t < t1; t++) {                                                          \
    ruk_net_v8 b0, b1; memcpy(&b0, b + t * 16, 32); memcpy(&b1, b + t * 16 + 8, 32);            \
    c0 += a[t] * b0; c1 += a[t] * b1;                                                           \
  }                                                                                             \
  RUK_NET_PUT8(c, c0, c1)

#define RUK_NET_TILE1_V4                                                                        \
  ruk_net_v4 c0 = {0}, c1 = {0}, c2 = {0}, c3 = {0};                                            \
  for (intptr_t t = t0; t < t1; t++) {                                                          \
    ruk_net_v4 b0, b1, b2, b3; memcpy(&b0, b + t * 16, 16); memcpy(&b1, b + t * 16 + 4, 16);    \
    memcpy(&b2, b + t * 16 + 8, 16); memcpy(&b3, b + t * 16 + 12, 16);                          \
    c0 += a[t] * b0; c1 += a[t] * b1; c2 += a[t] * b2; c3 += a[t] * b3;                         \
  }                                                                                             \
  RUK_NET_PUT4(c, c0, c1) RUK_NET_PUT4(c + 8, c2, c3)

/* the whole of it for columns j0 ..< j1 (the last columns, fewer than sixteen, one by one): each
   block of b (k in 256s, sixteen columns) copied first into `pk` one row after another -- b's rows
   may be thousands of floats apart, which the cache cannot hold side by side */
#define RUK_NET_GEMM_BODY(TILE4, TILE1)                                                         \
  float pk[RUK_NET_KB * 16];                                                                    \
  intptr_t full = j0 + (j1 - j0) / 16 * 16;                                                     \
  for (intptr_t t0 = 0; t0 < k; t0 += RUK_NET_KB) {                                             \
    intptr_t t1 = t0 + RUK_NET_KB < k ? t0 + RUK_NET_KB : k;                                    \
    int ov = over && t0 == 0;          /* (the first block written over c, not added to it) */ \
    for (intptr_t j = j0; j < full; j += 16) {                                                  \
      for (intptr_t t = t0; t < t1; t++) memcpy(pk + (t - t0) * 16, b + t * ldb + j, 64);       \
      const float* pb = pk - t0 * 16;                                                           \
      intptr_t i = 0;                                                                           \
      for (; i + 4 <= m; i += 4) TILE4(a + i * lda, pb, c + i * ldc + j, lda, ldc, t0, t1, ov);  \
      for (; i < m; i++) TILE1(a + i * lda, pb, c + i * ldc + j, t0, t1, ov);                   \
    }                                                                                           \
    for (intptr_t i = 0; i < m; i++)                                                            \
      for (intptr_t j = full; j < j1; j++) {                                                    \
        float s = 0;                                                                            \
        for (intptr_t t = t0; t < t1; t++) s += a[i * lda + t] * b[t * ldb + j];                \
        c[i * ldc + j] = ov ? s : c[i * ldc + j] + s;                                           \
      }                                                                                         \
  }

static inline void ruk_net_tile4(const float* a, const float* b, float* c, intptr_t lda, intptr_t ldc,
                                 intptr_t t0, intptr_t t1, int ov) { RUK_NET_TILE4_V4 }
static inline void ruk_net_tile1(const float* a, const float* b, float* c, intptr_t t0, intptr_t t1, int ov) {
  RUK_NET_TILE1_V4
}
static void ruk_net_gemm1(const float* a, const float* b, float* c, intptr_t m, intptr_t k, intptr_t lda,
                          intptr_t ldb, intptr_t ldc, intptr_t j0, intptr_t j1, int over) {
  RUK_NET_GEMM_BODY(ruk_net_tile4, ruk_net_tile1)
}

#ifdef RUK_NET_X86
__attribute__((target("avx2,fma"))) static inline void ruk_net_tile4f(const float* a, const float* b, float* c,
    intptr_t lda, intptr_t ldc, intptr_t t0, intptr_t t1, int ov) { RUK_NET_TILE4_V8 }
__attribute__((target("avx2,fma"))) static inline void ruk_net_tile1f(const float* a, const float* b, float* c,
    intptr_t t0, intptr_t t1, int ov) { RUK_NET_TILE1_V8 }
__attribute__((target("avx2,fma"))) static void ruk_net_gemm2(const float* a, const float* b, float* c,
    intptr_t m, intptr_t k, intptr_t lda, intptr_t ldb, intptr_t ldc, intptr_t j0, intptr_t j1, int over) {
  RUK_NET_GEMM_BODY(ruk_net_tile4f, ruk_net_tile1f)
}
static volatile int ruk_fma_state = -1;
static inline int ruk_has_fma(void) {
  /* (AVX2 as `ruk_force_avx2` leaves it, and the processor's FMA) */
  if (!ruk_has_avx2()) return 0;
  if (ruk_fma_state < 0) {
    unsigned int ea, eb, ec, ed;
    ruk_fma_state = __get_cpuid(1, &ea, &eb, &ec, &ed) && (ec & (1u << 12)) ? 1 : 0;
  }
  return ruk_fma_state;
}
#endif

static inline void ruk_net_gemm(const float* a, const float* b, float* c, intptr_t m, intptr_t k,
                                intptr_t lda, intptr_t ldb, intptr_t ldc, intptr_t j0, intptr_t j1, int over) {
  /* (`over`: c is written, not added to -- what was there need not be 0) */
#ifdef RUK_NET_X86
  if (ruk_has_fma()) { ruk_net_gemm2(a, b, c, m, k, lda, ldb, ldc, j0, j1, over); return; }
#endif
  ruk_net_gemm1(a, b, c, m, k, lda, ldb, ldc, j0, j1, over);
}


/* ---- exp and erf, several at a time (softmax's, GELU's) --------------------------------------
   exp as Cephes' expf: e^x = 2^n e^r, |r| <= ln2 / 2, a polynomial for e^r (within two units in
   the last place of the float); erf as Abramowitz and Stegun's 7.1.26 (within 1.5e-7). */
#define RUK_NET_EXP_BODY(V, VI)                                                                 \
  V zero = {0};                                                                                 \
  V hi = zero + 88.3762626647949f, lo = zero - 88.3762626647949f;                               \
  VI over = x > hi, under = x < lo;            /* (C has no ?: of vectors: masks) */            \
  x = (V)((over & (VI)hi) | (~over & (VI)x)); x = (V)((under & (VI)lo) | (~under & (VI)x));     \
  V fx = x * 1.44269504088896341f + 0.5f;                                                       \
  V tf = __builtin_convertvector(__builtin_convertvector(fx, VI), V);                           \
  tf += __builtin_convertvector(tf > fx, V);                 /* (floor: -1 where it went up) */ \
  x -= tf * 0.693359375f; x -= tf * -2.12194440e-4f;                                            \
  V z = x * x;                                                                                  \
  V y = x * 1.9875691500e-4f + 1.3981999507e-3f;                                                \
  y = y * x + 8.3334519073e-3f; y = y * x + 4.1665795894e-2f;                                   \
  y = y * x + 1.6666665459e-1f; y = y * x + 5.0000001201e-1f;                                   \
  y = y * z + x + 1.0f;                                                                         \
  VI e = (__builtin_convertvector(tf, VI) + 127) << 23;                                         \
  V p; memcpy(&p, &e, sizeof(p));                                                               \
  return y * p;

static inline ruk_net_v4 ruk_net_exp4(ruk_net_v4 x) { RUK_NET_EXP_BODY(ruk_net_v4, ruk_net_i4) }

#define RUK_NET_SOFTMAX_BODY(V, EXP, L)                                                         \
  float top = x[0];                                                                             \
  for (intptr_t i = 1; i < n; i++) top = x[i] > top ? x[i] : top;                               \
  V sv = {0};                                                                                   \
  intptr_t i = 0;                                                                               \
  for (; i + L <= n; i += L) {                                                                  \
    V v; memcpy(&v, x + i, sizeof(V)); v = EXP(v - top); memcpy(x + i, &v, sizeof(V)); sv += v; \
  }                                                                                             \
  float sum = 0;                                                                                \
  for (int q = 0; q < L; q++) sum += sv[q];                                                     \
  for (; i < n; i++) { V v = {0}; v[0] = x[i] - top; v = EXP(v); x[i] = v[0]; sum += v[0]; }    \
  float k = 1.0f / sum;                                                                         \
  for (i = 0; i < n; i++) x[i] *= k;

#define RUK_NET_ERF_BODY(V, VI, EXP, L)                                                             \
  intptr_t i = 0;                                                                               \
  for (; i < n; i += L) {                                                                       \
    V v = {0};                                                                                  \
    intptr_t m = n - i < L ? n - i : L;                                                         \
    memcpy(&v, x + i, (size_t)m * 4);                                                           \
    V a = (V)((VI)v & 0x7fffffff);                                                              \
    V t = 1.0f / (1.0f + 0.3275911f * a);                                                       \
    V y = ((((1.061405429f * t - 1.453152027f) * t + 1.421413741f) * t - 0.284496736f) * t     \
           + 0.254829592f) * t;                                                                 \
    V r = 1.0f - y * EXP(-a * a);                                                               \
    r = (V)((VI)r ^ ((VI)v & (int32_t)0x80000000u));                                            \
    memcpy(x + i, &r, (size_t)m * 4);                                                           \
  }

static inline void ruk_net_softmax1(float* x, intptr_t n) { RUK_NET_SOFTMAX_BODY(ruk_net_v4, ruk_net_exp4, 4) }
static inline void ruk_net_erf1(float* x, intptr_t n) { RUK_NET_ERF_BODY(ruk_net_v4, ruk_net_i4, ruk_net_exp4, 4) }

#ifdef RUK_NET_X86
__attribute__((target("avx2,fma"))) static inline ruk_net_v8 ruk_net_exp8(ruk_net_v8 x) {
  RUK_NET_EXP_BODY(ruk_net_v8, ruk_net_i8)
}
__attribute__((target("avx2,fma"))) static void ruk_net_softmax2(float* x, intptr_t n) {
  RUK_NET_SOFTMAX_BODY(ruk_net_v8, ruk_net_exp8, 8)
}
__attribute__((target("avx2,fma"))) static void ruk_net_erf2(float* x, intptr_t n) {
  RUK_NET_ERF_BODY(ruk_net_v8, ruk_net_i8, ruk_net_exp8, 8)
}
#endif

static inline void ruk_net_softmax(float* x, intptr_t n) {
  /* a row in place: e^(x - its largest), over their sum */
#ifdef RUK_NET_X86
  if (ruk_has_fma()) { ruk_net_softmax2(x, n); return; }
#endif
  ruk_net_softmax1(x, n);
}
static inline void ruk_net_erf(float* x, intptr_t n) {
#ifdef RUK_NET_X86
  if (ruk_has_fma()) { ruk_net_erf2(x, n); return; }
#endif
  ruk_net_erf1(x, n);
}

#endif
