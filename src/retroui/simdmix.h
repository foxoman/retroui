/* Retro Nim UI: the layers' mixing kernels (retroui/simd), RUI_N pixels at a time. Included by
 * simdkern.h twice -- four lanes, and eight in a function built for AVX2 -- with RUI_N, RUI_SFX
 * (the names' ending) and RUI_ATTR (the function's target) set. No guard: one copy each time.
 *
 * Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net */

/* (a block of RUI_N pixels: `src` mixed over `dst`, each by its amount `a` (0..255, before its
 * own alpha) and the mode's table `lut` -- `dst` all opaque) */
#if RUI_VEC
#define RUI_MIXBLOCK(V, d, s, a, lut, dst, x) do {                                              \
    const V k255_ = zero_ + 255u, kdiv_ = zero_ + 0x8081u, m8_ = zero_ + 255u;                    \
    V s_ = (s);                                                                                  \
    if (lut) {                                                                                   \
      for (int i_ = 0; i_ < RUI_N; i_++) {                                                       \
        uint32_t dd_ = (d)[i_], ss_ = s_[i_];                                                    \
        s_[i_] = (ss_ & 0xFF000000u) | ((uint32_t)lut[((dd_ >> 16) & 255) << 8 | ((ss_ >> 16) & 255)] << 16) | \
                 ((uint32_t)lut[((dd_ >> 8) & 255) << 8 | ((ss_ >> 8) & 255)] << 8) |           \
                 (uint32_t)lut[(dd_ & 255) << 8 | (ss_ & 255)];                                  \
      }                                                                                          \
    }                                                                                            \
    V ea_ = (((a) * (s_ >> 24)) * kdiv_) >> 23;                                                   \
    V ia_ = k255_ - ea_;                                                                         \
    V r_ = (((((s_ >> 16) & m8_) * ea_ + (((d) >> 16) & m8_) * ia_) * kdiv_) >> 23) << 16;       \
    V g_ = (((((s_ >> 8) & m8_) * ea_ + (((d) >> 8) & m8_) * ia_) * kdiv_) >> 23) << 8;          \
    V b_ = ((((s_ & m8_) * ea_ + ((d) & m8_) * ia_) * kdiv_) >> 23);                              \
    V o_ = (zero_ + 0xFF000000u) | r_ | g_ | b_;                                                 \
    memcpy((dst) + (x), &o_, RUI_N * 4);                                                         \
  } while (0)
#endif

RUI_ATTR static inline int RUI_CAT(rui_mix_opaque, RUI_SFX)(uint32_t* dst, const uint32_t* src, int x, int xb,
                                                     uint32_t op, const uint8_t* lut) {
#if RUI_VEC
  typedef uint32_t V __attribute__((vector_size(RUI_N * 4)));
  const V zero_ = {0};
  const V vop = zero_ + op;
  for (;;) {
    while (x + RUI_N <= xb) {
      V d, s;
      memcpy(&d, dst + x, RUI_N * 4);
      memcpy(&s, src + x, RUI_N * 4);
      uint32_t all = 0xFFFFFFFFu;
      for (int i = 0; i < RUI_N; i++) all &= d[i];
      if (all < 0xFF000000u) break;   /* (one under is not opaque: this block one by one) */
      RUI_MIXBLOCK(V, d, s, vop, lut, dst, x);
      x += RUI_N;
    }
    int e = x + RUI_N <= xb ? x + RUI_N : xb;
    for (; x < e; x++) {
      uint32_t s = src[x];
      uint32_t sa = s >> 24;
      if (sa == 0) continue;
      uint32_t d = dst[x];
      if ((d >> 24) != 255) return x;
      uint32_t ea = RUI_DIV255(op * sa);
      if (ea > 0) dst[x] = rui_over1(d, s, ea, lut);
    }
    if (x >= xb) return xb;
  }
#else
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
#endif
}

RUI_ATTR static inline int RUI_CAT(rui_mix_opt, RUI_SFX)(uint32_t* dst, const uint32_t* src, int x, int xb,
                                                  uint32_t op, const uint8_t* lut, const rui_mixopt* o) {
#if RUI_VEC
  typedef uint32_t V __attribute__((vector_size(RUI_N * 4)));
  const V zero_ = {0};
  const V vop = zero_ + op, kdiv = zero_ + 0x8081u, m8 = zero_ + 255u;
  for (;;) {
    while (x + RUI_N <= xb) {
      V d, s;
      memcpy(&d, dst + x, RUI_N * 4);
      memcpy(&s, src + x, RUI_N * 4);
      uint32_t all = 0xFFFFFFFFu;
      for (int i = 0; i < RUI_N; i++) all &= d[i];
      if (all < 0xFF000000u) break;
      V a = vop;
      if (o->mask) {
        V m;
        memcpy(&m, o->mask + x, RUI_N * 4);
        a = ((a * ((m >> 16) & m8)) * kdiv) >> 23;
      }
      if (o->cover) {
        V cv;
        memcpy(&cv, o->cover + x, RUI_N * 4);
        a = ((a * cv) * kdiv) >> 23;
      } else if (o->base) {
        V b;
        memcpy(&b, o->base + x, RUI_N * 4);
        V ba = b >> 24;
        if (o->blut) ba = ((((b >> 16) & m8) * ba) * kdiv) >> 23;
        if (o->bmask) {
          V bm;
          memcpy(&bm, o->bmask + x, RUI_N * 4);
          ba = ((ba * ((bm >> 16) & m8)) * kdiv) >> 23;
        }
        a = ((a * ba) * kdiv) >> 23;
      }
      if (o->bif) {
        V t, u;
        for (int i = 0; i < RUI_N; i++) {
          t[i] = o->thisT[rui_chan(s[i], o->ch)];
          u[i] = o->underT[rui_chan(d[i], o->ch)];
        }
        a = ((((((a * t) * kdiv) >> 23) * u) * kdiv) >> 23);
      }
      RUI_MIXBLOCK(V, d, s, a, lut, dst, x);
      x += RUI_N;
    }
    int e = x + RUI_N <= xb ? x + RUI_N : xb;
    for (; x < e; x++) {
      uint32_t s = src[x];
      uint32_t sa = s >> 24;
      if (sa == 0) continue;
      uint32_t d = dst[x];
      uint32_t a = rui_amt1(o, x, op, s, d);
      if (a == 0) continue;
      if ((d >> 24) != 255) return x;
      uint32_t ea = RUI_DIV255(a * sa);
      if (ea > 0) dst[x] = rui_over1(d, s, ea, lut);
    }
    if (x >= xb) return xb;
  }
#else
  for (; x < xb; x++) {
    uint32_t s = src[x];
    uint32_t sa = s >> 24;
    if (sa == 0) continue;
    uint32_t d = dst[x];
    uint32_t a = rui_amt1(o, x, op, s, d);
    if (a == 0) continue;
    if ((d >> 24) != 255) return x;
    uint32_t ea = RUI_DIV255(a * sa);
    if (ea > 0) dst[x] = rui_over1(d, s, ea, lut);
  }
  return xb;
#endif
}

/* acc[t] += kw * buf[t], t < n (a blur's pass down its rows: the compiler makes the loop its
 * vectors by itself, as wide as the function's target) */
RUI_ATTR static inline void RUI_CAT(rui_madd_u16, RUI_SFX)(uint32_t* acc, const uint16_t* buf, int n, uint32_t kw) {
  for (int t = 0; t < n; t++) acc[t] += kw * buf[t];
}

/* A row of a gaussian blur across (see rui_blur_across): with eight lanes two pixels a step,
 * each lane the same sums as with four -- the same numbers. */
RUI_ATTR static inline void RUI_CAT(rui_blur_across, RUI_SFX)(const float* pre, int w, const float* k, int kr,
                                                      uint16_t* out) {
#if RUI_VEC
  typedef float F __attribute__((vector_size(RUI_N * 4)));
  typedef float F4 __attribute__((vector_size(16)));
  int x = 0;
  for (; x < w; ) {
    if (RUI_N == 8 && x >= kr && x + 1 + kr < w) {
      /* (x and x + 1 at once: pixels x - kr + i and x + 1 - kr + i lie side by side) */
      F acc = {0};
      const float* q = pre + (x - kr) * 4;
      for (int i = 0; i <= 2 * kr; i++) {
        F p;
        memcpy(&p, q + i * 4, RUI_N * 4);
        acc += p * k[i];
      }
      for (int c = 0; c < 8; c++) out[x * 4 + c] = (uint16_t)(acc[c] * 256.0f + 0.5f);
      x += 2;
      continue;
    }
    F4 acc = {0, 0, 0, 0};
    if (x >= kr && x + kr < w) {
      const float* q = pre + (x - kr) * 4;
      for (int i = 0; i <= 2 * kr; i++) {
        F4 p;
        memcpy(&p, q + i * 4, 16);
        acc += p * k[i];
      }
    } else {
      for (int i = -kr; i <= kr; i++) {
        int xx = x + i < 0 ? 0 : (x + i >= w ? w - 1 : x + i);
        F4 p;
        memcpy(&p, pre + xx * 4, 16);
        acc += p * k[i + kr];
      }
    }
    for (int c = 0; c < 4; c++) out[x * 4 + c] = (uint16_t)(acc[c] * 256.0f + 0.5f);
    x++;
  }
#else
  for (int x = 0; x < w; x++) {
    float a0 = 0, a1 = 0, a2 = 0, a3 = 0;
    for (int i = -kr; i <= kr; i++) {
      int xx = x + i < 0 ? 0 : (x + i >= w ? w - 1 : x + i);
      const float* p = pre + xx * 4;
      float kw = k[i + kr];
      a0 += p[0] * kw; a1 += p[1] * kw; a2 += p[2] * kw; a3 += p[3] * kw;
    }
    out[x * 4] = (uint16_t)(a0 * 256.0f + 0.5f); out[x * 4 + 1] = (uint16_t)(a1 * 256.0f + 0.5f);
    out[x * 4 + 2] = (uint16_t)(a2 * 256.0f + 0.5f); out[x * 4 + 3] = (uint16_t)(a3 * 256.0f + 0.5f);
  }
#endif
}

#ifdef RUI_MIXBLOCK
#undef RUI_MIXBLOCK
#endif
