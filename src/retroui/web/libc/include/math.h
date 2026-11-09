#ifndef _RL_MATH_H
#define _RL_MATH_H
#include "_rl.h"
RL_BEGIN
#define M_PI 3.14159265358979323846
#define M_PI_2 1.57079632679489661923
#define M_PI_4 0.78539816339744830962
#define M_E 2.7182818284590452354
#define M_LN2 0.69314718055994530942
#define M_LN10 2.30258509299404568402
#define M_SQRT2 1.41421356237309504880
#define M_SQRT1_2 0.70710678118654752440
#define M_1_PI 0.31830988618379067154
#define M_2_PI 0.63661977236758134308
#define M_LOG2E 1.4426950408889634074
#define M_LOG10E 0.43429448190325182765
#define HUGE_VAL __builtin_huge_val()
#define HUGE_VALF __builtin_huge_valf()
#define INFINITY __builtin_inff()
#define NAN __builtin_nanf("")
#define FP_NAN 0
#define FP_INFINITE 1
#define FP_ZERO 2
#define FP_SUBNORMAL 3
#define FP_NORMAL 4
#define isnan(x) __builtin_isnan(x)
#define isinf(x) __builtin_isinf(x)
#define isfinite(x) __builtin_isfinite(x)
#define isnormal(x) __builtin_isnormal(x)
#define signbit(x) __builtin_signbit(x)
#define fpclassify(x) __builtin_fpclassify(FP_NAN, FP_INFINITE, FP_NORMAL, FP_SUBNORMAL, FP_ZERO, x)
#define RL_MATH1(n) double n(double x); float n##f(float x);
#define RL_MATH2(n) double n(double x, double y); float n##f(float x, float y);
RL_MATH1(sin) RL_MATH1(cos) RL_MATH1(tan) RL_MATH1(asin) RL_MATH1(acos) RL_MATH1(atan)
RL_MATH1(sinh) RL_MATH1(cosh) RL_MATH1(tanh) RL_MATH1(asinh) RL_MATH1(acosh) RL_MATH1(atanh)
RL_MATH1(exp) RL_MATH1(exp2) RL_MATH1(expm1) RL_MATH1(log) RL_MATH1(log2) RL_MATH1(log10)
RL_MATH1(log1p) RL_MATH1(sqrt) RL_MATH1(cbrt) RL_MATH1(fabs) RL_MATH1(floor) RL_MATH1(ceil)
RL_MATH1(trunc) RL_MATH1(round) RL_MATH1(rint) RL_MATH1(nearbyint) RL_MATH1(erf) RL_MATH1(erfc)
RL_MATH1(tgamma) RL_MATH1(lgamma) RL_MATH1(logb)
RL_MATH2(atan2) RL_MATH2(pow) RL_MATH2(fmod) RL_MATH2(hypot) RL_MATH2(fmin) RL_MATH2(fmax)
RL_MATH2(copysign) RL_MATH2(remainder) RL_MATH2(nextafter) RL_MATH2(fdim)
double fma(double x, double y, double z); float fmaf(float x, float y, float z);
double ldexp(double x, int e); float ldexpf(float x, int e);
double scalbn(double x, int e); float scalbnf(float x, int e);
double frexp(double x, int *e); float frexpf(float x, int *e);
double modf(double x, double *i); float modff(float x, float *i);
long lround(double x); long lroundf(float x); long long llround(double x);
long lrint(double x); long long llrint(double x);
int ilogb(double x);
double nan(const char *s);
RL_END
#endif
