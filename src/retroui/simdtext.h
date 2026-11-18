/* Text sixteen bytes at a time, for mail (retroui/mime): the run of plain
   ASCII at the start of some bytes (UTF-8 checked, 8-bit charsets made
   UTF-8, at a glance where most of a message is ASCII), the next of a few
   bytes that matter (quoted-printable's "=", the line ends), and base64
   decoded sixteen letters at a time. With GCC's and Clang's own vectors:
   SSE2 on x86-64, NEON on ARM, SIMD128 in a web page, lane by lane where
   there is none. Each gives the very bytes of its plain loop
   (tests/test_mimefast.nim holds them side by side).

   Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net */
#ifndef RUT_SIMDTEXT_H
#define RUT_SIMDTEXT_H
#include <stdint.h>
#include <string.h>

typedef uint8_t rut_b16 __attribute__((vector_size(16)));
typedef int8_t rut_m16 __attribute__((vector_size(16)));
typedef uint32_t rut_u4 __attribute__((vector_size(16)));

static inline rut_b16 rut_load(const uint8_t* p) { rut_b16 v; memcpy(&v, p, 16); return v; }

static inline int rut_any(rut_m16 m) {
  /* (any lane set) */
  uint64_t a[2];
  memcpy(a, &m, 16);
  return (a[0] | a[1]) != 0;
}

static inline int rut_first(rut_m16 m) {
  /* (the first lane set: 0..15; 16 none) */
  uint64_t a[2];
  memcpy(a, &m, 16);
  if (a[0]) return __builtin_ctzll(a[0]) >> 3;
  if (a[1]) return 8 + (__builtin_ctzll(a[1]) >> 3);
  return 16;
}

/* How many bytes from p are ASCII (below 0x80) before the first that is not. */
static inline intptr_t rut_ascii_run(const uint8_t* p, intptr_t n) {
  intptr_t i = 0;
  const rut_b16 hi = {0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80};
  for (; i + 64 <= n; i += 64) {
    rut_b16 a = rut_load(p + i) | rut_load(p + i + 16) | rut_load(p + i + 32) | rut_load(p + i + 48);
    if (rut_any((rut_m16)(a & hi))) break;
  }
  for (; i + 16 <= n; i += 16) {
    rut_m16 m = (rut_m16)((rut_load(p + i) & hi) != 0);
    if (rut_any(m)) return i + rut_first(m);
  }
  for (; i < n; i++) if (p[i] & 0x80) return i;
  return n;
}

/* The first byte from p that is a, b or c (n: none). */
static inline intptr_t rut_find3(const uint8_t* p, intptr_t n, uint8_t a, uint8_t b, uint8_t c) {
  intptr_t i = 0;
  for (; i + 16 <= n; i += 16) {
    rut_b16 v = rut_load(p + i);
    rut_m16 m = (rut_m16)((v == a) | (v == b) | (v == c));
    if (rut_any(m)) return i + rut_first(m);
  }
  for (; i < n; i++) if (p[i] == a || p[i] == b || p[i] == c) return i;
  return n;
}

/* Base64 (either alphabet: + / or - _) from `in`, sixteen letters at a time
   while all sixteen are letters of it (no "=", no line end): how many were
   decoded (a multiple of 16), their 12-byte groups written to `out`. */
static inline intptr_t rut_b64_decode16(const uint8_t* in, intptr_t n, uint8_t* out) {
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
  intptr_t i = 0;
  uint8_t* o = out;
  for (; i + 16 <= n; i += 16) {
    rut_b16 v = rut_load(in + i);
    rut_m16 up = (rut_m16)((v >= 'A') & (v <= 'Z'));
    rut_m16 lo = (rut_m16)((v >= 'a') & (v <= 'z'));
    rut_m16 dg = (rut_m16)((v >= '0') & (v <= '9'));
    rut_m16 pl = (rut_m16)((v == '+') | (v == '-'));
    rut_m16 sl = (rut_m16)((v == '/') | (v == '_'));
    rut_m16 ok = up | lo | dg | pl | sl;
    if (rut_any(~ok)) break;
    rut_b16 val = ((rut_b16)up & (rut_b16)(v - 65)) | ((rut_b16)lo & (rut_b16)(v - 71)) |
                  ((rut_b16)dg & (rut_b16)(v + 4)) | ((rut_b16)pl & 62) | ((rut_b16)sl & 63);
    rut_u4 w = (rut_u4)val;
    rut_u4 x = ((w & 0x3Fu) << 18) | (((w >> 8) & 0x3Fu) << 12) | (((w >> 16) & 0x3Fu) << 6) |
               ((w >> 24) & 0x3Fu);
    uint32_t xs[4];
    memcpy(xs, &x, 16);
    for (int k = 0; k < 4; k++) {
      o[0] = (uint8_t)(xs[k] >> 16);
      o[1] = (uint8_t)(xs[k] >> 8);
      o[2] = (uint8_t)xs[k];
      o += 3;
    }
  }
  return i;
#else
  (void)in; (void)n; (void)out;
  return 0;
#endif
}

#endif
