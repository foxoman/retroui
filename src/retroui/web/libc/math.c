/* The math library: what WebAssembly does itself (square roots, floor,
   ceil, truncation, min, max, copysign -- one instruction each) here, and
   the rest from the browser's Math, which is as exact as glibc's. The
   float versions round the double ones. */

#include <math.h>
#include <stdint.h>
#include <string.h>

#define JS1(n) RL_IMPORT(m_##n) double js_##n(double);
#define JS2(n) RL_IMPORT(m_##n) double js_##n(double, double);
JS1(sin) JS1(cos) JS1(tan) JS1(asin) JS1(acos) JS1(atan) JS1(sinh) JS1(cosh) JS1(tanh)
JS1(asinh) JS1(acosh) JS1(atanh) JS1(exp) JS1(expm1) JS1(log) JS1(log2) JS1(log10)
JS1(log1p) JS1(cbrt)
JS2(atan2) JS2(pow) JS2(fmod) JS2(hypot)

#define WRAP1(n) double n(double x) { return js_##n(x); } \
  float n##f(float x) { return (float)js_##n(x); }
#define WRAP2(n) double n(double x, double y) { return js_##n(x, y); } \
  float n##f(float x, float y) { return (float)js_##n(x, y); }
WRAP1(sin) WRAP1(cos) WRAP1(tan) WRAP1(asin) WRAP1(acos) WRAP1(atan) WRAP1(sinh) WRAP1(cosh)
WRAP1(tanh) WRAP1(asinh) WRAP1(acosh) WRAP1(atanh) WRAP1(exp) WRAP1(expm1) WRAP1(log)
WRAP1(log2) WRAP1(log10) WRAP1(log1p) WRAP1(cbrt)
WRAP2(atan2) WRAP2(pow) WRAP2(fmod) WRAP2(hypot)

double exp2(double x) { return js_pow(2.0, x); }
float exp2f(float x) { return (float)js_pow(2.0, x); }

#define BUILTIN1(n, b) double n(double x) { return __builtin_##b(x); } \
  float n##f(float x) { return __builtin_##b##f(x); }
BUILTIN1(sqrt, sqrt) BUILTIN1(fabs, fabs) BUILTIN1(floor, floor) BUILTIN1(ceil, ceil)
BUILTIN1(trunc, trunc) BUILTIN1(rint, rint) BUILTIN1(nearbyint, nearbyint)

double round(double x) {
  /* half away from zero (WebAssembly's nearest is half to even) */
  double t = __builtin_trunc(x);
  if (__builtin_fabs(x - t) >= 0.5) t += x < 0 ? -1.0 : 1.0;
  return t;
}
float roundf(float x) {
  float t = __builtin_truncf(x);
  if (__builtin_fabsf(x - t) >= 0.5f) t += x < 0 ? -1.0f : 1.0f;
  return t;
}
long lround(double x) { return (long)round(x); }
long lroundf(float x) { return (long)roundf(x); }
long long llround(double x) { return (long long)round(x); }
long lrint(double x) { return (long)__builtin_rint(x); }
long long llrint(double x) { return (long long)__builtin_rint(x); }

double fmin(double x, double y) { return isnan(x) ? y : isnan(y) ? x : x < y ? x : y; }
float fminf(float x, float y) { return (float)fmin(x, y); }
double fmax(double x, double y) { return isnan(x) ? y : isnan(y) ? x : x > y ? x : y; }
float fmaxf(float x, float y) { return (float)fmax(x, y); }
double fdim(double x, double y) { return x > y ? x - y : 0; }
float fdimf(float x, float y) { return x > y ? x - y : 0; }
double copysign(double x, double y) { return __builtin_copysign(x, y); }
float copysignf(float x, float y) { return __builtin_copysignf(x, y); }
double fma(double x, double y, double z) { return x * y + z; }
float fmaf(float x, float y, float z) { return x * y + z; }

double remainder(double x, double y) { return x - __builtin_rint(x / y) * y; }
float remainderf(float x, float y) { return (float)remainder(x, y); }

typedef union { double d; uint64_t u; } Bits;

double frexp(double x, int *e) {
  Bits b = { x };
  int ex = (int)(b.u >> 52 & 0x7ff);
  if (!ex) {
    if (x == 0) { *e = 0; return x; }
    x = frexp(x * 0x1p64, e);       /* (subnormal) */
    *e -= 64;
    return x;
  }
  if (ex == 0x7ff) { *e = 0; return x; }
  *e = ex - 1022;
  b.u = (b.u & 0x800fffffffffffffull) | 0x3fe0000000000000ull;
  return b.d;
}

float frexpf(float x, int *e) { return (float)frexp(x, e); }

double ldexp(double x, int e) {
  /* in steps that each stay a normal double */
  if (e > 1023) { x *= 0x1p1023; e -= 1023; if (e > 1023) { x *= 0x1p1023; e -= 1023; if (e > 1023) e = 1023; } }
  else if (e < -1022) { x *= 0x1p-969; e += 969; if (e < -1022) { x *= 0x1p-969; e += 969; if (e < -1022) e = -1022; } }
  Bits b = { 0 };
  b.u = (uint64_t)(0x3ff + e) << 52;
  return x * b.d;
}

float ldexpf(float x, int e) { return (float)ldexp(x, e); }
double scalbn(double x, int e) { return ldexp(x, e); }
float scalbnf(float x, int e) { return (float)ldexp(x, e); }

double modf(double x, double *ip) {
  double t = __builtin_trunc(x);
  *ip = t;
  return isinf(x) ? copysign(0.0, x) : x - t;
}

float modff(float x, float *ip) { double i; double r = modf(x, &i); *ip = (float)i; return (float)r; }

int ilogb(double x) { int e; if (x == 0) return -2147483647 - 1; frexp(x, &e); return e - 1; }
double logb(double x) { return (double)ilogb(x); }
float logbf(float x) { return (float)ilogb(x); }

double nextafter(double x, double y) {
  if (isnan(x) || isnan(y)) return x + y;
  if (x == y) return y;
  Bits b = { x };
  if (x == 0) { b.u = 1; return y > 0 ? b.d : -b.d; }
  if ((x < y) == (x > 0)) b.u++; else b.u--;
  return b.d;
}
float nextafterf(float x, float y) { return (float)nextafter(x, y); }

double nan(const char *s) { (void)s; return __builtin_nan(""); }

/* the error function (Abramowitz and Stegun 7.1.26 refined: a few ulps) */
double erf(double x) {
  double t = 1.0 / (1.0 + 0.5 * fabs(x));
  double y = 1 - t * js_exp(-x * x - 1.26551223 + t * (1.00002368 + t * (0.37409196 + t * (0.09678418 +
             t * (-0.18628806 + t * (0.27886807 + t * (-1.13520398 + t * (1.48851587 +
             t * (-0.82215223 + t * 0.17087277)))))))));
  return x >= 0 ? y : -y;
}
float erff(float x) { return (float)erf(x); }
double erfc(double x) { return 1 - erf(x); }
float erfcf(float x) { return (float)erfc(x); }

/* the gamma function (Lanczos, g = 7) */
static const double lanczos[] = { 0.99999999999980993, 676.5203681218851, -1259.1392167224028,
  771.32342877765313, -176.61502916214059, 12.507343278686905, -0.13857109526572012,
  9.9843695780195716e-6, 1.5056327351493116e-7 };

double tgamma(double x) {
  if (x < 0.5) return M_PI / (js_sin(M_PI * x) * tgamma(1 - x));
  x -= 1;
  double a = lanczos[0], t = x + 7.5;
  for (int i = 1; i < 9; i++) a += lanczos[i] / (x + i);
  return sqrt(2 * M_PI) * js_pow(t, x + 0.5) * js_exp(-t) * a;
}
float tgammaf(float x) { return (float)tgamma(x); }
double lgamma(double x) { return js_log(fabs(tgamma(x))); }
float lgammaf(float x) { return (float)lgamma(x); }
