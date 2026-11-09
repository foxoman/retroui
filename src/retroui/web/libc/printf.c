/* printf and its family. Numbers with a point are written from their exact
   decimal value -- a double is an integer times a power of two, which is
   an integer of a few hundred digits times a power of ten -- rounded half
   to even at the digit asked for, as glibc and musl do. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <errno.h>

typedef struct {
  char *buf;           /* where it goes (sn*printf) */
  size_t cap, len;     /* (len: what would have been written) */
  FILE *f;             /* ... or this file */
} Out;

size_t __rl_fwrite_raw(const void *p, size_t n, FILE *f);

static void put(Out *o, const char *s, size_t n) {
  if (o->f) { __rl_fwrite_raw(s, n, o->f); o->len += n; return; }
  for (size_t i = 0; i < n; i++, o->len++)
    if (o->cap && o->len < o->cap - 1) o->buf[o->len] = s[i];
}

static void pad(Out *o, char c, int n) {
  char b[32];
  memset(b, c, sizeof b);
  while (n > 0) { int k = n < 32 ? n : 32; put(o, b, (size_t)k); n -= k; }
}

/* ---- exact decimal digits of a double ---- */

#define LIMBS 120     /* base 1e9: 1080 digits, more than any double needs */

typedef struct { uint32_t d[LIMBS]; int n; } Big;

static void bigMul(Big *b, uint32_t m) {
  uint64_t carry = 0;
  for (int i = 0; i < b->n; i++) {
    uint64_t t = (uint64_t)b->d[i] * m + carry;
    b->d[i] = (uint32_t)(t % 1000000000u);
    carry = t / 1000000000u;
  }
  while (carry && b->n < LIMBS) { b->d[b->n++] = (uint32_t)(carry % 1000000000u); carry /= 1000000000u; }
}

/* `v` (finite, > 0) as its decimal digits (no leading zeros) and where the
   point goes: value = 0.DIGITS * 10^point. */
static int exactDigits(double v, char *out, int *point) {
  int e2;
  double fr = frexp(v, &e2);                  /* v = fr * 2^e2, fr in [0.5, 1) */
  uint64_t m = (uint64_t)ldexp(fr, 53);
  int e = e2 - 53;                            /* v = m * 2^e */
  while (m && !(m & 1)) { m >>= 1; e++; }
  Big b;
  b.n = 0;
  b.d[b.n++] = (uint32_t)(m % 1000000000u);
  if (m / 1000000000u) b.d[b.n++] = (uint32_t)((m / 1000000000u) % 1000000000u);
  if (m / 1000000000000000000ull) b.d[b.n++] = (uint32_t)(m / 1000000000000000000ull);
  int shift = 0;                              /* value = b / 10^shift */
  if (e > 0) {
    for (int i = e; i > 0; i -= 29) bigMul(&b, 1u << (i < 29 ? i : 29));
  } else if (e < 0) {
    for (int i = -e; i > 0; i -= 13) {
      int k = i < 13 ? i : 13;
      uint32_t p = 1;
      for (int j = 0; j < k; j++) p *= 5;
      bigMul(&b, p);
    }
    shift = -e;
  }
  /* the limbs as digits */
  int len = 0;
  char tmp[16];
  for (int i = b.n - 1; i >= 0; i--) {
    uint32_t x = b.d[i];
    if (i == b.n - 1) {
      int k = 0;
      do { tmp[k++] = (char)('0' + x % 10); x /= 10; } while (x);
      while (k) out[len++] = tmp[--k];
    } else {
      for (int k = 8; k >= 0; k--) { out[len + k] = (char)('0' + x % 10); x /= 10; }
      len += 9;
    }
  }
  out[len] = 0;
  *point = len - shift;
  return len;
}

/* Rounds `d` (len digits) to `keep` digits, half to even; true when it
   carried into a new first digit ("999" -> "1000"). */
static int roundDigits(char *d, int len, int keep) {
  if (keep >= len) return 0;
  if (keep < 0) { d[0] = 0; return 0; }
  int up;
  char next = d[keep];
  if (next > '5') up = 1;
  else if (next < '5') up = 0;
  else {
    up = 0;
    for (int i = keep + 1; i < len; i++) if (d[i] != '0') { up = 1; break; }
    if (!up) up = keep > 0 ? ((d[keep - 1] - '0') & 1) : 0;   /* a tie: to even */
  }
  d[keep] = 0;
  if (!up) return 0;
  int i = keep - 1;
  while (i >= 0 && d[i] == '9') d[i--] = '0';
  if (i >= 0) { d[i]++; return 0; }
  /* all nines: a one in front */
  memmove(d + 1, d, (size_t)keep + 1);
  d[0] = '1';
  d[keep + 1] = 0;
  return 1;
}

static void fmtFloat(Out *o, double v, char conv, int prec, int width, int left, int plus,
                     int space, int alt, int zero) {
  char sign = 0;
  if (signbit(v)) { sign = '-'; v = -v; }
  else if (plus) sign = '+';
  else if (space) sign = ' ';
  int upper = conv == 'E' || conv == 'F' || conv == 'G' || conv == 'A';
  char body[1400];
  int bl = 0;
  if (isnan(v) || isinf(v)) {
    const char *t = isnan(v) ? (upper ? "NAN" : "nan") : (upper ? "INF" : "inf");
    strcpy(body, t);
    bl = 3;
    zero = 0;
  } else {
    if (prec < 0) prec = 6;
    if (prec > 1000) prec = 1000;
    static char d[1400];
    int point = 1, len = 1;
    if (v == 0) { d[0] = '0'; d[1] = 0; point = 1; len = 1; }
    else len = exactDigits(v, d, &point);
    char c = (char)(conv | 32);
    int useE = c == 'e';
    int strip = 0;
    if (c == 'g') {
      int p = prec ? prec : 1;
      /* the exponent %e would have, after rounding to p digits */
      char t[1400];
      memcpy(t, d, (size_t)len + 1);
      int x = point - 1;
      if (v != 0 && roundDigits(t, len, p)) x++;
      if (v == 0) x = 0;
      if (p > x && x >= -4) { prec = p - 1 - x; useE = 0; }
      else { prec = p - 1; useE = 1; }
      strip = !alt;
    }
    if (useE) {
      int x = point - 1;
      if (v != 0 && roundDigits(d, len, prec + 1)) x++;
      int dl = (int)strlen(d);
      body[bl++] = d[0];
      int fracN = prec;
      if (fracN > 0 || alt) body[bl++] = '.';
      for (int i = 1; i <= fracN; i++) body[bl++] = i < dl ? d[i] : '0';
      if (strip) {
        while (bl > 0 && body[bl - 1] == '0') bl--;
        if (bl > 0 && body[bl - 1] == '.') bl--;
      }
      body[bl++] = upper ? 'E' : 'e';
      if (v == 0) x = 0;
      body[bl++] = x < 0 ? '-' : '+';
      int ax = x < 0 ? -x : x;
      if (ax >= 100) body[bl++] = (char)('0' + ax / 100);
      body[bl++] = (char)('0' + ax / 10 % 10);
      body[bl++] = (char)('0' + ax % 10);
    } else {
      /* digits up to `prec` after the point */
      int keep = point + prec;
      if (v != 0) {
        if (keep < 0) { d[0] = 0; len = 0; point = 0; }
        else if (roundDigits(d, len, keep)) point++;
      }
      int dl = (int)strlen(d);
      if (point <= 0) body[bl++] = '0';
      else for (int i = 0; i < point; i++) body[bl++] = i < dl ? d[i] : '0';
      if (prec > 0 || alt) body[bl++] = '.';
      for (int i = 0; i < prec; i++) {
        int at = point + i;
        body[bl++] = (at >= 0 && at < dl) ? d[at] : '0';
      }
      if (strip && prec > 0) {
        while (bl > 0 && body[bl - 1] == '0') bl--;
        if (bl > 0 && body[bl - 1] == '.') bl--;
      }
    }
  }
  int total = bl + (sign ? 1 : 0);
  if (!left && !zero) pad(o, ' ', width - total);
  if (sign) put(o, &sign, 1);
  if (!left && zero) pad(o, '0', width - total);
  put(o, body, (size_t)bl);
  if (left) pad(o, ' ', width - total);
}

static void fmtHexFloat(Out *o, double v, int upper, int prec) {
  (void)prec;
  if (signbit(v)) { put(o, "-", 1); v = -v; }
  if (v == 0) { put(o, upper ? "0X0P+0" : "0x0p+0", 6); return; }
  int e;
  double f = frexp(v, &e);        /* [0.5, 1) */
  f *= 2; e--;
  char b[64];
  int n = 0;
  b[n++] = '0'; b[n++] = upper ? 'X' : 'x';
  b[n++] = '1';
  f -= 1;
  if (f > 0) {
    b[n++] = '.';
    while (f > 0 && n < 40) {
      f *= 16;
      int dg = (int)f;
      f -= dg;
      b[n++] = (char)(dg < 10 ? '0' + dg : (upper ? 'A' : 'a') + dg - 10);
    }
  }
  n += snprintf(b + n, sizeof b - (size_t)n, upper ? "P%+d" : "p%+d", e);
  put(o, b, (size_t)n);
}

static int format(Out *o, const char *fmt, va_list ap) {
  for (const char *p = fmt; *p; p++) {
    if (*p != '%') {
      const char *q = p;
      while (*q && *q != '%') q++;
      put(o, p, (size_t)(q - p));
      p = q - 1;
      continue;
    }
    p++;
    if (*p == '%') { put(o, "%", 1); continue; }
    int left = 0, plus = 0, space = 0, alt = 0, zero = 0;
    for (;; p++) {
      if (*p == '-') left = 1;
      else if (*p == '+') plus = 1;
      else if (*p == ' ') space = 1;
      else if (*p == '#') alt = 1;
      else if (*p == '0') zero = 1;
      else if (*p == '\'') {}
      else break;
    }
    int width = 0;
    if (*p == '*') { width = va_arg(ap, int); if (width < 0) { left = 1; width = -width; } p++; }
    else while (*p >= '0' && *p <= '9') width = width * 10 + (*p++ - '0');
    int prec = -1;
    if (*p == '.') {
      p++;
      prec = 0;
      if (*p == '*') { prec = va_arg(ap, int); p++; }
      else while (*p >= '0' && *p <= '9') prec = prec * 10 + (*p++ - '0');
    }
    int lng = 0;     /* 1 l, 2 ll, -1 h, -2 hh, 3 z/t/j, 4 L */
    for (;; p++) {
      if (*p == 'l') lng = lng == 1 ? 2 : 1;
      else if (*p == 'h') lng = lng == -1 ? -2 : -1;
      else if (*p == 'z' || *p == 't') lng = 3;
      else if (*p == 'j' || *p == 'q') lng = 2;
      else if (*p == 'L') lng = 4;
      else break;
    }
    char c = *p;
    if (!c) break;
    char num[72];
    int nl = 0;
    char sign = 0;
    const char *prefix = "";
    switch (c) {
    case 'd': case 'i': case 'u': case 'o': case 'x': case 'X': case 'b': {
      unsigned long long u;
      if (c == 'd' || c == 'i') {
        long long s;
        if (lng == 2) s = va_arg(ap, long long);
        else if (lng == 1) s = va_arg(ap, long);
        else if (lng == 3) s = (long long)va_arg(ap, ssize_t);
        else s = va_arg(ap, int);
        if (lng == -1) s = (short)s;
        if (lng == -2) s = (signed char)s;
        if (s < 0) { sign = '-'; u = 0ull - (unsigned long long)s; }
        else { u = (unsigned long long)s; if (plus) sign = '+'; else if (space) sign = ' '; }
      } else {
        if (lng == 2) u = va_arg(ap, unsigned long long);
        else if (lng == 1) u = va_arg(ap, unsigned long);
        else if (lng == 3) u = va_arg(ap, size_t);
        else u = va_arg(ap, unsigned int);
        if (lng == -1) u = (unsigned short)u;
        if (lng == -2) u = (unsigned char)u;
      }
      unsigned base = (c == 'o') ? 8 : (c == 'x' || c == 'X') ? 16 : c == 'b' ? 2 : 10;
      const char *dg = c == 'X' ? "0123456789ABCDEF" : "0123456789abcdef";
      char t[72];
      int tl = 0;
      while (u) { t[tl++] = dg[u % base]; u /= base; }
      if (prec < 0 && tl == 0) t[tl++] = '0';
      while (tl < prec) t[tl++] = '0';
      if (alt && c == 'o' && (tl == 0 || t[tl - 1] != '0')) t[tl++] = '0';
      if (alt && (c == 'x' || c == 'X') && !(tl == 1 && t[0] == '0') && tl) prefix = c == 'x' ? "0x" : "0X";
      while (tl) num[nl++] = t[--tl];
      if (prec >= 0) zero = 0;
      int total = nl + (sign ? 1 : 0) + (int)strlen(prefix);
      if (!left && !zero) pad(o, ' ', width - total);
      if (sign) put(o, &sign, 1);
      put(o, prefix, strlen(prefix));
      if (!left && zero) pad(o, '0', width - total);
      put(o, num, (size_t)nl);
      if (left) pad(o, ' ', width - total);
      break;
    }
    case 'p': {
      uintptr_t u = (uintptr_t)va_arg(ap, void *);
      char t[24];
      int tl = 0;
      do { t[tl++] = "0123456789abcdef"[u % 16]; u /= 16; } while (u);
      num[nl++] = '0'; num[nl++] = 'x';
      while (tl) num[nl++] = t[--tl];
      if (!left) pad(o, ' ', width - nl);
      put(o, num, (size_t)nl);
      if (left) pad(o, ' ', width - nl);
      break;
    }
    case 'c': {
      char ch = (char)va_arg(ap, int);
      if (!left) pad(o, ' ', width - 1);
      put(o, &ch, 1);
      if (left) pad(o, ' ', width - 1);
      break;
    }
    case 's': {
      const char *s = va_arg(ap, const char *);
      if (!s) s = "(null)";
      size_t n = prec >= 0 ? strnlen(s, (size_t)prec) : strlen(s);
      if (!left) pad(o, ' ', width - (int)n);
      put(o, s, n);
      if (left) pad(o, ' ', width - (int)n);
      break;
    }
    case 'f': case 'F': case 'e': case 'E': case 'g': case 'G': {
      double v = va_arg(ap, double);   /* (no long double here: %Lf takes a double) */
      fmtFloat(o, v, c, prec, width, left, plus, space, alt, zero);
      break;
    }
    case 'a': case 'A': {
      double v = va_arg(ap, double);   /* (no long double here: %Lf takes a double) */
      fmtHexFloat(o, v, c == 'A', prec);
      break;
    }
    case 'n': {
      int *np = va_arg(ap, int *);
      if (np) *np = (int)o->len;
      break;
    }
    default:
      put(o, p - 1, 2);
    }
  }
  return (int)o->len;
}

int vsnprintf(char *restrict s, size_t n, const char *restrict fmt, va_list ap) {
  Out o = { s, n, 0, 0 };
  va_list aq;
  va_copy(aq, ap);
  int r = format(&o, fmt, aq);
  va_end(aq);
  if (n) s[o.len < n ? o.len : n - 1] = 0;
  return r;
}

int snprintf(char *restrict s, size_t n, const char *restrict fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int r = vsnprintf(s, n, fmt, ap);
  va_end(ap);
  return r;
}

int vsprintf(char *restrict s, const char *restrict fmt, va_list ap) {
  return vsnprintf(s, (size_t)0x7fffffff, fmt, ap);
}

int sprintf(char *restrict s, const char *restrict fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int r = vsprintf(s, fmt, ap);
  va_end(ap);
  return r;
}

int vfprintf(FILE *restrict f, const char *restrict fmt, va_list ap) {
  Out o = { 0, 0, 0, f };
  va_list aq;
  va_copy(aq, ap);
  int r = format(&o, fmt, aq);
  va_end(aq);
  return r;
}

int fprintf(FILE *restrict f, const char *restrict fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int r = vfprintf(f, fmt, ap);
  va_end(ap);
  return r;
}

int vprintf(const char *restrict fmt, va_list ap) { return vfprintf(stdout, fmt, ap); }

int printf(const char *restrict fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int r = vfprintf(stdout, fmt, ap);
  va_end(ap);
  return r;
}

int dprintf(int fd, const char *restrict fmt, ...) {
  char b[1024];
  va_list ap;
  va_start(ap, fmt);
  int r = vsnprintf(b, sizeof b, fmt, ap);
  va_end(ap);
  extern long write(int, const void *, unsigned long);
  write(fd, b, (unsigned long)(r < (int)sizeof b ? r : (int)sizeof b - 1));
  return r;
}

/* sscanf: what C code reading numbers needs (%d %u %x %ld %lld %f %lf %s %c %[) */
int sscanf(const char *restrict s, const char *restrict fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int n = 0;
  const char *p = s;
  for (const char *f = fmt; *f; f++) {
    if (*f == ' ' || *f == '\t' || *f == '\n') { while (*p == ' ' || *p == '\t' || *p == '\n') p++; continue; }
    if (*f != '%') { if (*p != *f) break; p++; continue; }
    f++;
    int skip = 0;
    if (*f == '*') { skip = 1; f++; }
    int width = 0;
    while (*f >= '0' && *f <= '9') width = width * 10 + (*f++ - '0');
    int lng = 0;
    while (*f == 'l' || *f == 'h' || *f == 'z' || *f == 'L') { if (*f == 'l') lng++; f++; }
    char c = *f;
    if (c == '%') { if (*p != '%') break; p++; continue; }
    if (c != 'c' && c != '[') while (*p == ' ' || *p == '\t' || *p == '\n') p++;
    char *e;
    if (c == 'd' || c == 'i' || c == 'u' || c == 'x' || c == 'X' || c == 'o') {
      int base = c == 'x' || c == 'X' ? 16 : c == 'o' ? 8 : c == 'i' ? 0 : 10;
      long long v = strtoll(p, &e, base);
      if (e == p) break;
      p = e;
      if (!skip) {
        if (lng >= 2) *va_arg(ap, long long *) = v;
        else if (lng == 1) *va_arg(ap, long *) = (long)v;
        else *va_arg(ap, int *) = (int)v;
        n++;
      }
    } else if (c == 'f' || c == 'e' || c == 'g' || c == 'E' || c == 'G') {
      double v = strtod(p, &e);
      if (e == p) break;
      p = e;
      if (!skip) {
        if (lng >= 1) *va_arg(ap, double *) = v;
        else *va_arg(ap, float *) = (float)v;
        n++;
      }
    } else if (c == 's') {
      char *out = skip ? 0 : va_arg(ap, char *);
      int k = 0;
      while (*p && *p != ' ' && *p != '\t' && *p != '\n' && (!width || k < width)) {
        if (out) out[k] = *p;
        k++; p++;
      }
      if (!k) break;
      if (out) { out[k] = 0; n++; }
    } else if (c == 'c') {
      char *out = skip ? 0 : va_arg(ap, char *);
      int w = width ? width : 1;
      for (int k = 0; k < w; k++) { if (!*p) goto done; if (out) out[k] = *p; p++; }
      if (out) n++;
    } else if (c == '[') {
      f++;
      int neg = 0;
      if (*f == '^') { neg = 1; f++; }
      const char *set = f;
      while (*f && (*f != ']' || f == set)) f++;
      size_t setLen = (size_t)(f - set);
      char *out = skip ? 0 : va_arg(ap, char *);
      int k = 0;
      while (*p && (!width || k < width)) {
        int in = memchr(set, *p, setLen) != 0;
        if (in == neg) break;
        if (out) out[k] = *p;
        k++; p++;
      }
      if (!k) break;
      if (out) { out[k] = 0; n++; }
    } else if (c == 'n') {
      if (!skip) *va_arg(ap, int *) = (int)(p - s);
    } else break;
  }
done:
  va_end(ap);
  return n;
}
