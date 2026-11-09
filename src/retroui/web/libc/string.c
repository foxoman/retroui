/* The string and memory functions. memcpy, memmove and memset use the
   bulk memory instructions when the compiler may (-mbulk-memory); the
   rest are plain loops. */

#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <ctype.h>

void *memcpy(void *restrict d, const void *restrict s, size_t n) {
#if defined(__wasm_bulk_memory__)
  __builtin_memcpy(d, s, n);
  return d;
#else
  unsigned char *dd = d;
  const unsigned char *ss = s;
  while (n--) *dd++ = *ss++;
  return d;
#endif
}

void *memmove(void *d, const void *s, size_t n) {
#if defined(__wasm_bulk_memory__)
  __builtin_memmove(d, s, n);
  return d;
#else
  unsigned char *dd = d;
  const unsigned char *ss = s;
  if (dd == ss || !n) return d;
  if (dd < ss) { while (n--) *dd++ = *ss++; }
  else { dd += n; ss += n; while (n--) *--dd = *--ss; }
  return d;
#endif
}

void *memset(void *d, int c, size_t n) {
#if defined(__wasm_bulk_memory__)
  __builtin_memset(d, c, n);
  return d;
#else
  unsigned char *dd = d;
  while (n--) *dd++ = (unsigned char)c;
  return d;
#endif
}

int memcmp(const void *a, const void *b, size_t n) {
  const unsigned char *x = a, *y = b;
  for (; n; n--, x++, y++) if (*x != *y) return *x - *y;
  return 0;
}

void *memchr(const void *s, int c, size_t n) {
  const unsigned char *p = s;
  for (; n; n--, p++) if (*p == (unsigned char)c) return (void *)p;
  return 0;
}

void *memrchr(const void *s, int c, size_t n) {
  const unsigned char *p = (const unsigned char *)s + n;
  while (n--) if (*--p == (unsigned char)c) return (void *)p;
  return 0;
}

void *memmem(const void *h, size_t hn, const void *nd, size_t nn) {
  if (!nn) return (void *)h;
  const unsigned char *a = h, *b = nd;
  for (size_t i = 0; i + nn <= hn; i++)
    if (a[i] == b[0] && !memcmp(a + i, b, nn)) return (void *)(a + i);
  return 0;
}

size_t strlen(const char *s) {
  const char *p = s;
  while (*p) p++;
  return (size_t)(p - s);
}

size_t strnlen(const char *s, size_t n) {
  size_t i = 0;
  while (i < n && s[i]) i++;
  return i;
}

char *strcpy(char *restrict d, const char *restrict s) {
  char *r = d;
  while ((*d++ = *s++)) {}
  return r;
}

char *strncpy(char *restrict d, const char *restrict s, size_t n) {
  size_t i = 0;
  for (; i < n && s[i]; i++) d[i] = s[i];
  for (; i < n; i++) d[i] = 0;
  return d;
}

size_t strlcpy(char *d, const char *s, size_t n) {
  size_t l = strlen(s);
  if (n) {
    size_t c = l < n - 1 ? l : n - 1;
    memcpy(d, s, c);
    d[c] = 0;
  }
  return l;
}

char *strcat(char *restrict d, const char *restrict s) {
  strcpy(d + strlen(d), s);
  return d;
}

char *strncat(char *restrict d, const char *restrict s, size_t n) {
  char *e = d + strlen(d);
  while (n-- && *s) *e++ = *s++;
  *e = 0;
  return d;
}

int strcmp(const char *a, const char *b) {
  while (*a && *a == *b) { a++; b++; }
  return (unsigned char)*a - (unsigned char)*b;
}

int strncmp(const char *a, const char *b, size_t n) {
  for (; n; n--, a++, b++) {
    if (*a != *b) return (unsigned char)*a - (unsigned char)*b;
    if (!*a) return 0;
  }
  return 0;
}

int strcoll(const char *a, const char *b) { return strcmp(a, b); }

int strcasecmp(const char *a, const char *b) {
  while (*a && tolower((unsigned char)*a) == tolower((unsigned char)*b)) { a++; b++; }
  return tolower((unsigned char)*a) - tolower((unsigned char)*b);
}

int strncasecmp(const char *a, const char *b, size_t n) {
  for (; n; n--, a++, b++) {
    int x = tolower((unsigned char)*a), y = tolower((unsigned char)*b);
    if (x != y) return x - y;
    if (!x) return 0;
  }
  return 0;
}

char *strchr(const char *s, int c) {
  for (;; s++) {
    if (*s == (char)c) return (char *)s;
    if (!*s) return 0;
  }
}

char *strrchr(const char *s, int c) {
  const char *r = 0;
  for (;; s++) {
    if (*s == (char)c) r = s;
    if (!*s) return (char *)r;
  }
}

char *strstr(const char *h, const char *n) {
  size_t nn = strlen(n);
  if (!nn) return (char *)h;
  for (; *h; h++) if (*h == *n && !strncmp(h, n, nn)) return (char *)h;
  return 0;
}

size_t strspn(const char *s, const char *a) {
  size_t i = 0;
  while (s[i] && strchr(a, s[i])) i++;
  return i;
}

size_t strcspn(const char *s, const char *r) {
  size_t i = 0;
  while (s[i] && !strchr(r, s[i])) i++;
  return i;
}

char *strpbrk(const char *s, const char *a) {
  s += strcspn(s, a);
  return *s ? (char *)s : 0;
}

char *strtok_r(char *restrict s, const char *restrict d, char **restrict p) {
  if (!s) s = *p;
  if (!s) return 0;
  s += strspn(s, d);
  if (!*s) { *p = 0; return 0; }
  char *e = s + strcspn(s, d);
  if (*e) { *e = 0; *p = e + 1; } else *p = 0;
  return s;
}

char *strtok(char *restrict s, const char *restrict d) {
  static char *p;
  return strtok_r(s, d, &p);
}

char *strdup(const char *s) {
  size_t n = strlen(s) + 1;
  char *r = malloc(n);
  if (r) memcpy(r, s, n);
  return r;
}

char *strndup(const char *s, size_t n) {
  n = strnlen(s, n);
  char *r = malloc(n + 1);
  if (r) { memcpy(r, s, n); r[n] = 0; }
  return r;
}

static const char *errText(int e) {
  switch (e) {
  case 0: return "Success";
  case EPERM: return "Operation not permitted";
  case ENOENT: return "No such file or directory";
  case EINTR: return "Interrupted";
  case EIO: return "I/O error";
  case EBADF: return "Bad file descriptor";
  case EAGAIN: return "Resource temporarily unavailable";
  case ENOMEM: return "Out of memory";
  case EACCES: return "Permission denied";
  case EEXIST: return "File exists";
  case ENOTDIR: return "Not a directory";
  case EISDIR: return "Is a directory";
  case EINVAL: return "Invalid argument";
  case EMFILE: return "Too many open files";
  case ENOSPC: return "No space left on device";
  case ESPIPE: return "Illegal seek";
  case EROFS: return "Read-only file system";
  case EPIPE: return "Broken pipe";
  case ERANGE: return "Result out of range";
  case ENAMETOOLONG: return "File name too long";
  case ENOSYS: return "Not available in a browser";
  case ENOTEMPTY: return "Directory not empty";
  case ENOTSUP: return "Not supported";
  case EAFNOSUPPORT: return "No sockets in a browser";
  case ECONNREFUSED: return "Connection refused";
  case ETIMEDOUT: return "Timed out";
  default: return "Error";
  }
}

char *strerror(int e) { return (char *)errText(e); }

int strerror_r(int e, char *buf, size_t n) {
  strlcpy(buf, errText(e), n);
  return 0;
}

char *strsignal(int sig) { (void)sig; return (char *)"Signal"; }
