/* Numbers from text: strtol and its kin, and strtod -- exact for the
   numbers written with up to 19 significant digits and a moderate
   exponent (every price, quantity and coordinate), within an ulp
   beyond. */

#include <stdlib.h>
#include <errno.h>
#include <ctype.h>
#include <limits.h>
#include <stdint.h>
#include <inttypes.h>
#include <math.h>

static unsigned long long parseUnsigned(const char *s, char **end, int base, int *neg, int *overflow) {
  const char *p = s;
  while (isspace((unsigned char)*p)) p++;
  *neg = 0;
  if (*p == '+' || *p == '-') { *neg = *p == '-'; p++; }
  if ((base == 0 || base == 16) && p[0] == '0' && (p[1] | 32) == 'x' && isxdigit((unsigned char)p[2])) {
    p += 2;
    base = 16;
  } else if (base == 0 && p[0] == '0') base = 8;
  else if (base == 0) base = 10;
  unsigned long long v = 0;
  int any = 0;
  *overflow = 0;
  for (;; p++) {
    int d;
    if (isdigit((unsigned char)*p)) d = *p - '0';
    else if (isalpha((unsigned char)*p)) d = (*p | 32) - 'a' + 10;
    else break;
    if (d >= base) break;
    any = 1;
    if (v > (ULLONG_MAX - (unsigned)d) / (unsigned)base) *overflow = 1;
    else v = v * (unsigned)base + (unsigned)d;
  }
  if (end) *end = (char *)(any ? p : s);
  return v;
}

long long strtoll(const char *restrict s, char **restrict e, int base) {
  int neg, ov;
  unsigned long long v = parseUnsigned(s, e, base, &neg, &ov);
  if (ov || (!neg && v > (unsigned long long)LLONG_MAX) || (neg && v > (unsigned long long)LLONG_MAX + 1)) {
    errno = ERANGE;
    return neg ? LLONG_MIN : LLONG_MAX;
  }
  return neg ? (long long)(0 - v) : (long long)v;
}

unsigned long long strtoull(const char *restrict s, char **restrict e, int base) {
  int neg, ov;
  unsigned long long v = parseUnsigned(s, e, base, &neg, &ov);
  if (ov) { errno = ERANGE; return ULLONG_MAX; }
  return neg ? 0 - v : v;
}

long strtol(const char *restrict s, char **restrict e, int base) {
  long long v = strtoll(s, e, base);
  if (v > LONG_MAX) { errno = ERANGE; return LONG_MAX; }
  if (v < LONG_MIN) { errno = ERANGE; return LONG_MIN; }
  return (long)v;
}

unsigned long strtoul(const char *restrict s, char **restrict e, int base) {
  unsigned long long v = strtoull(s, e, base);
  if (v > ULONG_MAX && v < (0ull - (unsigned long long)ULONG_MAX)) { errno = ERANGE; return ULONG_MAX; }
  return (unsigned long)v;
}

intmax_t strtoimax(const char *restrict s, char **restrict e, int b) { return strtoll(s, e, b); }
uintmax_t strtoumax(const char *restrict s, char **restrict e, int b) { return strtoull(s, e, b); }
int atoi(const char *s) { return (int)strtol(s, 0, 10); }
long atol(const char *s) { return strtol(s, 0, 10); }
long long atoll(const char *s) { return strtoll(s, 0, 10); }

static const double exact10[] = {
  1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15,
  1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22 };

static double pow10i(int e) {
  /* 10^e by squaring (an ulp or two for large e) */
  double r = 1.0, b = 10.0;
  int n = e < 0 ? -e : e;
  while (n) { if (n & 1) r *= b; b *= b; n >>= 1; }
  return e < 0 ? 1.0 / r : r;
}

double strtod(const char *restrict s, char **restrict end) {
  const char *p = s;
  while (isspace((unsigned char)*p)) p++;
  int neg = 0;
  if (*p == '+' || *p == '-') { neg = *p == '-'; p++; }
  /* inf, nan */
  if ((p[0] | 32) == 'i' && (p[1] | 32) == 'n' && (p[2] | 32) == 'f') {
    p += 3;
    if ((p[0] | 32) == 'i' && (p[1] | 32) == 'n' && (p[2] | 32) == 'i' && (p[3] | 32) == 't' &&
        (p[4] | 32) == 'y') p += 5;
    if (end) *end = (char *)p;
    return neg ? -INFINITY : INFINITY;
  }
  if ((p[0] | 32) == 'n' && (p[1] | 32) == 'a' && (p[2] | 32) == 'n') {
    p += 3;
    if (*p == '(') { const char *q = p; while (*q && *q != ')') q++; if (*q == ')') p = q + 1; }
    if (end) *end = (char *)p;
    return NAN;
  }
  /* hexadecimal: exact */
  if (p[0] == '0' && (p[1] | 32) == 'x') {
    const char *q = p + 2;
    double v = 0;
    int any = 0, exp = 0;
    for (; isxdigit((unsigned char)*q); q++, any = 1)
      v = v * 16 + (isdigit((unsigned char)*q) ? *q - '0' : (*q | 32) - 'a' + 10);
    if (*q == '.') {
      q++;
      for (; isxdigit((unsigned char)*q); q++, any = 1) {
        v = v * 16 + (isdigit((unsigned char)*q) ? *q - '0' : (*q | 32) - 'a' + 10);
        exp -= 4;
      }
    }
    if (!any) { if (end) *end = (char *)s; return 0; }
    if ((*q | 32) == 'p') {
      char *e2;
      long pe = strtol(q + 1, &e2, 10);
      if (e2 != q + 1) { exp += (int)pe; q = e2; }
    }
    if (end) *end = (char *)q;
    v = ldexp(v, exp);
    return neg ? -v : v;
  }
  unsigned long long mant = 0;
  int digits = 0, dropped = 0, any = 0, exp10 = 0;
  for (; isdigit((unsigned char)*p); p++, any = 1) {
    if (digits < 19) { if (mant || *p != '0') { mant = mant * 10 + (unsigned)(*p - '0'); digits += mant != 0; } }
    else dropped++;
  }
  exp10 += dropped;
  if (*p == '.') {
    p++;
    for (; isdigit((unsigned char)*p); p++, any = 1) {
      if (digits < 19) {
        mant = mant * 10 + (unsigned)(*p - '0');
        if (mant) digits++;
        exp10--;
      }
    }
  }
  if (!any) { if (end) *end = (char *)s; return 0; }
  if ((*p | 32) == 'e') {
    const char *q = p + 1;
    int eneg = 0;
    if (*q == '+' || *q == '-') { eneg = *q == '-'; q++; }
    if (isdigit((unsigned char)*q)) {
      int e = 0;
      for (; isdigit((unsigned char)*q); q++) if (e < 100000) e = e * 10 + (*q - '0');
      exp10 += eneg ? -e : e;
      p = q;
    }
  }
  if (end) *end = (char *)p;
  double v;
  if (mant == 0) v = 0;
  else if (mant < (1ull << 53) && exp10 >= -22 && exp10 <= 22) {
    /* both exact: one rounding, the right one */
    v = exp10 >= 0 ? (double)mant * exact10[exp10] : (double)mant / exact10[-exp10];
  } else if (exp10 < -340) {
    v = 0;
    errno = ERANGE;
  } else if (exp10 > 310) {
    v = INFINITY;
    errno = ERANGE;
  } else {
    /* in two steps where the power alone would leave the doubles */
    v = (double)mant;
    if (exp10 < -300) { v *= 1e-300; exp10 += 300; }
    v = exp10 >= 0 ? v * pow10i(exp10) : v / pow10i(-exp10);
    if (isinf(v) || v == 0) errno = ERANGE;
  }
  return neg ? -v : v;
}

float strtof(const char *restrict s, char **restrict e) { return (float)strtod(s, e); }
double atof(const char *s) { return strtod(s, 0); }

int abs(int x) { return x < 0 ? -x : x; }
long labs(long x) { return x < 0 ? -x : x; }
long long llabs(long long x) { return x < 0 ? -x : x; }
div_t div(int a, int b) { div_t r = { a / b, a % b }; return r; }
ldiv_t ldiv(long a, long b) { ldiv_t r = { a / b, a % b }; return r; }
lldiv_t lldiv(long long a, long long b) { lldiv_t r = { a / b, a % b }; return r; }
