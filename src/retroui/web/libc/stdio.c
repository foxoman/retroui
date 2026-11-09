/* FILE over the descriptors of sys.c: a buffer for reading ahead and one
   for writing (the console's lines go out at each new line). */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

struct _RlFile {
  int fd;
  int flags;           /* O_RDONLY / O_WRONLY / O_RDWR, O_APPEND */
  int eof, err;
  int writing;         /* the buffer holds what is to be written */
  int lineBuf;         /* written out at each new line */
  int ungot;           /* -1: none */
  unsigned char *buf;
  size_t cap, pos, len;
  int own;             /* (opened here: closed and freed by fclose) */
};

static unsigned char outBuf[2][1024];
static FILE files[3] = {
  { 0, O_RDONLY, 0, 0, 0, 0, -1, 0, 0, 0, 0, 0 },
  { 1, O_WRONLY, 0, 0, 0, 1, -1, outBuf[0], 1024, 0, 0, 0 },
  { 2, O_WRONLY, 0, 0, 0, 1, -1, outBuf[1], 1024, 0, 0, 0 },
};
FILE *const stdin = &files[0];
FILE *const stdout = &files[1];
FILE *const stderr = &files[2];

#define MAXOPEN 256
static FILE *openFiles[MAXOPEN];

static int flushOut(FILE *f) {
  if (!f->writing || !f->len) { f->writing = 0; return 0; }
  size_t at = 0;
  while (at < f->len) {
    ssize_t n = write(f->fd, f->buf + at, f->len - at);
    if (n <= 0) { f->err = 1; f->len = 0; f->writing = 0; return EOF; }
    at += (size_t)n;
  }
  f->len = 0;
  f->writing = 0;
  return 0;
}

static void dropReadAhead(FILE *f) {
  /* (what was read ahead and not taken: the file's place goes back) */
  if (!f->writing && f->pos < f->len) lseek(f->fd, -(off_t)(f->len - f->pos), SEEK_CUR);
  f->pos = f->len = 0;
  f->ungot = -1;
}

void __rl_stdio_flush(void) {
  fflush(stdout);
  fflush(stderr);
  for (int i = 0; i < MAXOPEN; i++) if (openFiles[i]) fflush(openFiles[i]);
}

static int modeFlags(const char *m) {
  int f;
  switch (m[0]) {
  case 'r': f = O_RDONLY; break;
  case 'w': f = O_WRONLY | O_CREAT | O_TRUNC; break;
  case 'a': f = O_WRONLY | O_CREAT | O_APPEND; break;
  default: return -1;
  }
  for (const char *p = m + 1; *p; p++) {
    if (*p == '+') f = (f & ~O_ACCMODE) | O_RDWR;
    else if (*p == 'x') f |= O_EXCL;
  }
  return f;
}

static FILE *newFile(int fd, int flags) {
  FILE *f = calloc(1, sizeof *f);
  if (!f) return 0;
  f->fd = fd;
  f->flags = flags;
  f->ungot = -1;
  f->own = 1;
  f->cap = 16384;
  f->buf = malloc(f->cap);
  if (!f->buf) { free(f); return 0; }
  for (int i = 0; i < MAXOPEN; i++) {
    FILE *none = 0;           /* (a slot taken atomically: threads open files too) */
    if (__atomic_compare_exchange_n(&openFiles[i], &none, f, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) break;
  }
  return f;
}

FILE *fopen(const char *restrict p, const char *restrict m) {
  int fl = modeFlags(m);
  if (fl < 0) { errno = EINVAL; return 0; }
  int fd = open(p, fl);
  if (fd < 0) return 0;
  FILE *f = newFile(fd, fl);
  if (!f) close(fd);
  return f;
}

FILE *fdopen(int fd, const char *m) {
  int fl = modeFlags(m);
  if (fl < 0) { errno = EINVAL; return 0; }
  return newFile(fd, fl);
}

FILE *freopen(const char *restrict p, const char *restrict m, FILE *restrict f) {
  (void)p; (void)m; (void)f;
  errno = ENOSYS;
  return 0;
}

int fclose(FILE *f) {
  if (!f) return EOF;
  int r = fflush(f);
  if (!f->own) return r;
  for (int i = 0; i < MAXOPEN; i++) {
    FILE *was = f;
    if (__atomic_compare_exchange_n(&openFiles[i], &was, (FILE *)0, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) break;
  }
  if (close(f->fd)) r = EOF;
  free(f->buf);
  free(f);
  return r;
}

int fflush(FILE *f) {
  if (!f) { __rl_stdio_flush(); return 0; }
  if (f->writing) return flushOut(f);
  return 0;
}

size_t __rl_fwrite_raw(const void *p, size_t n, FILE *f) {
  if ((f->flags & O_ACCMODE) == O_RDONLY) { f->err = 1; errno = EBADF; return 0; }
  if (!f->writing) { dropReadAhead(f); f->writing = 1; f->len = 0; }
  const unsigned char *s = p;
  size_t done = 0;
  while (done < n) {
    if (f->len == f->cap && flushOut(f)) return done;
    f->writing = 1;
    size_t k = f->cap - f->len;
    if (k > n - done) k = n - done;
    memcpy(f->buf + f->len, s + done, k);
    f->len += k;
    done += k;
  }
  if (f->lineBuf && memchr(s, '\n', n)) flushOut(f);
  return done;
}

size_t fwrite(const void *restrict p, size_t s, size_t n, FILE *restrict f) {
  if (!s || !n) return 0;
  return __rl_fwrite_raw(p, s * n, f) / s;
}

static int fill(FILE *f) {
  if (f->writing && flushOut(f)) return 0;
  if (!f->buf) {
    f->cap = 4096;
    f->buf = malloc(f->cap);
    if (!f->buf) return 0;
  }
  ssize_t n = read(f->fd, f->buf, f->cap);
  if (n <= 0) { if (n < 0) f->err = 1; else f->eof = 1; f->pos = f->len = 0; return 0; }
  f->pos = 0;
  f->len = (size_t)n;
  return 1;
}

size_t fread(void *restrict p, size_t s, size_t n, FILE *restrict f) {
  if (!s || !n) return 0;
  if (f->writing && flushOut(f)) return 0;
  unsigned char *d = p;
  size_t want = s * n, got = 0;
  if (f->ungot >= 0 && want) { d[got++] = (unsigned char)f->ungot; f->ungot = -1; }
  while (got < want) {
    if (f->pos < f->len) {
      size_t k = f->len - f->pos;
      if (k > want - got) k = want - got;
      memcpy(d + got, f->buf + f->pos, k);
      f->pos += k;
      got += k;
    } else if (want - got >= 16384) {
      /* (a big read goes straight into the caller's memory) */
      ssize_t r = read(f->fd, d + got, want - got);
      if (r <= 0) { if (r < 0) f->err = 1; else f->eof = 1; break; }
      got += (size_t)r;
    } else if (!fill(f)) break;
  }
  return got / s;
}

int fgetc(FILE *f) {
  if (f->ungot >= 0) { int c = f->ungot; f->ungot = -1; return c; }
  if (f->pos >= f->len && !fill(f)) return EOF;
  return f->buf[f->pos++];
}

int getc(FILE *f) { return fgetc(f); }
int getc_unlocked(FILE *f) { return fgetc(f); }
int getchar(void) { return fgetc(stdin); }
int ungetc(int c, FILE *f) { if (c == EOF) return EOF; f->ungot = c & 255; f->eof = 0; return c; }

char *fgets(char *restrict s, int n, FILE *restrict f) {
  if (n <= 0) return 0;
  int i = 0;
  while (i < n - 1) {
    int c = fgetc(f);
    if (c == EOF) break;
    s[i++] = (char)c;
    if (c == '\n') break;
  }
  if (!i) return 0;
  s[i] = 0;
  return s;
}

ssize_t getdelim(char **restrict l, size_t *restrict n, int d, FILE *restrict f) {
  size_t i = 0;
  for (;;) {
    int c = fgetc(f);
    if (c == EOF) break;
    if (!*l || i + 2 > *n) {
      size_t nn = *n ? *n * 2 : 128;
      char *b = realloc(*l, nn);
      if (!b) return -1;
      *l = b;
      *n = nn;
    }
    (*l)[i++] = (char)c;
    if (c == d) break;
  }
  if (!i) return -1;
  (*l)[i] = 0;
  return (ssize_t)i;
}

ssize_t getline(char **restrict l, size_t *restrict n, FILE *restrict f) { return getdelim(l, n, '\n', f); }

int fputc(int c, FILE *f) {
  unsigned char b = (unsigned char)c;
  return __rl_fwrite_raw(&b, 1, f) == 1 ? c : EOF;
}

int putc(int c, FILE *f) { return fputc(c, f); }
int putc_unlocked(int c, FILE *f) { return fputc(c, f); }
int putchar(int c) { return fputc(c, stdout); }
int fputs(const char *restrict s, FILE *restrict f) { size_t n = strlen(s); return __rl_fwrite_raw(s, n, f) == n ? 0 : EOF; }
int puts(const char *s) { return fputs(s, stdout) == EOF || fputc('\n', stdout) == EOF ? EOF : 0; }

int fseeko(FILE *f, off_t off, int whence) {
  if (f->writing && flushOut(f)) return -1;
  if (whence == SEEK_CUR && !f->writing) off -= (off_t)(f->len - f->pos) + (f->ungot >= 0);
  f->pos = f->len = 0;
  f->ungot = -1;
  f->eof = 0;
  return lseek(f->fd, off, whence) < 0 ? -1 : 0;
}

int fseek(FILE *f, long off, int whence) { return fseeko(f, off, whence); }

off_t ftello(FILE *f) {
  off_t at = lseek(f->fd, 0, SEEK_CUR);
  if (at < 0) return -1;
  if (f->writing) return at + (off_t)f->len;
  return at - (off_t)(f->len - f->pos) - (f->ungot >= 0);
}

long ftell(FILE *f) { return (long)ftello(f); }
void rewind(FILE *f) { fseeko(f, 0, SEEK_SET); f->err = 0; }
int fgetpos(FILE *restrict f, fpos_t *restrict p) { off_t o = ftello(f); if (o < 0) return -1; *p = o; return 0; }
int fsetpos(FILE *f, const fpos_t *p) { return fseeko(f, *p, SEEK_SET); }
int feof(FILE *f) { return f->eof; }
int ferror(FILE *f) { return f->err; }
void clearerr(FILE *f) { f->eof = f->err = 0; }
int fileno(FILE *f) { return f->fd; }
int setvbuf(FILE *restrict f, char *restrict b, int mode, size_t n) { (void)b; (void)n; f->lineBuf = mode == _IOLBF || mode == _IONBF; return 0; }
void setbuf(FILE *restrict f, char *restrict b) { (void)f; (void)b; }
void flockfile(FILE *f) { (void)f; }
void funlockfile(FILE *f) { (void)f; }

void perror(const char *s) {
  if (s && *s) { fputs(s, stderr); fputs(": ", stderr); }
  fputs(strerror(errno), stderr);
  fputc('\n', stderr);
}

FILE *tmpfile(void) {
  char t[] = "/tmp/tmpXXXXXX";
  int fd = mkstemp(t);
  if (fd < 0) return 0;
  unlink(t);
  return fdopen(fd, "w+");
}

char *tmpnam(char *s) {
  static char b[32];
  char *t = s ? s : b;
  strcpy(t, "/tmp/tmpXXXXXX");
  return mktemp(t);
}

FILE *popen(const char *cmd, const char *mode) { (void)cmd; (void)mode; errno = ENOSYS; return 0; }
int pclose(FILE *f) { (void)f; return -1; }
