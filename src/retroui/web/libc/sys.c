/* What reaches outside the module goes through retro.js: files (a file
   system of its own in the page, its folders kept in the browser's
   storage), the console, clocks, the time zone, randomness, the end of the
   program. Paths are made absolute here (the current folder is this
   side's), so the page sees only whole paths. */

#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/mman.h>
#include <poll.h>
#include <signal.h>
#include <dlfcn.h>
#include <pthread.h>
#include <locale.h>
#include <limits.h>
#include <stdio.h>
#include <wchar.h>

int errno;

/* ---- the page's side ---- */

RL_IMPORT(rl_open) int rl_open(const char *path, int flags, int mode);
RL_IMPORT(rl_close) int rl_close(int fd);
RL_IMPORT(rl_read) int rl_read(int fd, void *p, size_t n);
RL_IMPORT(rl_write) int rl_write(int fd, const void *p, size_t n);
RL_IMPORT(rl_seek) double rl_seek(int fd, double off, int whence);
RL_IMPORT(rl_stat) int rl_stat(const char *path, void *buf);
RL_IMPORT(rl_fstat) int rl_fstat(int fd, void *buf);
RL_IMPORT(rl_mkdir) int rl_mkdir(const char *path);
RL_IMPORT(rl_rmdir) int rl_rmdir(const char *path);
RL_IMPORT(rl_unlink) int rl_unlink(const char *path);
RL_IMPORT(rl_rename) int rl_rename(const char *a, const char *b);
RL_IMPORT(rl_truncate) int rl_truncate(int fd, double size);
RL_IMPORT(rl_utime) int rl_utime(const char *path, double ms);
RL_IMPORT(rl_listdir) int rl_listdir(const char *path, char *buf, int cap);
RL_IMPORT(rl_now) double rl_now(int clock);
RL_IMPORT(rl_tzoffset) int rl_tzoffset(double ms);
RL_IMPORT(rl_random) void rl_random(void *p, size_t n);
RL_IMPORT(rl_exit) _Noreturn void rl_exit(int code);
RL_IMPORT(rl_abort) _Noreturn void rl_abort(const char *why);
RL_IMPORT(rl_env) int rl_env(char *buf, int cap);

typedef struct {
  unsigned mode, nlink;
  double size, mtime, ino;
} RlStat;

static int ret(int r) {
  if (r < 0) { errno = -r; return -1; }
  return r;
}

/* ---- paths ---- */

static char cwd[PATH_MAX] = "/";

static int absPath(const char *p, char *out) {
  /* `p` against the current folder, `.` and `..` worked out */
  if (!p) { errno = EFAULT; return -1; }
  char tmp[PATH_MAX * 2];
  if (p[0] == '/') strlcpy(tmp, p, sizeof tmp);
  else {
    strlcpy(tmp, cwd, sizeof tmp);
    if (strlen(tmp) + strlen(p) + 2 >= sizeof tmp) { errno = ENAMETOOLONG; return -1; }
    strcat(tmp, "/");
    strcat(tmp, p);
  }
  char *parts[512];
  int n = 0;
  char *save = 0;
  for (char *s = strtok_r(tmp, "/", &save); s; s = strtok_r(0, "/", &save)) {
    if (!strcmp(s, ".")) continue;
    if (!strcmp(s, "..")) { if (n) n--; continue; }
    if (n < 512) parts[n++] = s;
  }
  size_t len = 0;
  out[0] = 0;
  for (int i = 0; i < n; i++) {
    size_t k = strlen(parts[i]);
    if (len + k + 2 >= PATH_MAX) { errno = ENAMETOOLONG; return -1; }
    out[len++] = '/';
    memcpy(out + len, parts[i], k);
    len += k;
  }
  if (!len) out[len++] = '/';
  out[len] = 0;
  return 0;
}

char *getcwd(char *b, size_t n) {
  size_t k = strlen(cwd);
  if (!b) { b = malloc(k + 1); n = k + 1; if (!b) return 0; }
  if (k + 1 > n) { errno = ERANGE; return 0; }
  memcpy(b, cwd, k + 1);
  return b;
}

static void fillStat(const RlStat *r, struct stat *s) {
  memset(s, 0, sizeof *s);
  s->st_mode = r->mode;
  s->st_nlink = r->nlink ? r->nlink : 1;
  s->st_size = (off_t)r->size;
  s->st_ino = (ino_t)r->ino;
  s->st_dev = 1;
  s->st_blksize = 4096;
  s->st_blocks = (s->st_size + 511) / 512;
  long long ms = (long long)r->mtime;
  s->st_mtim.tv_sec = ms / 1000;
  s->st_mtim.tv_nsec = (long)(ms % 1000) * 1000000;
  s->st_atim = s->st_mtim;
  s->st_ctim = s->st_mtim;
  s->st_uid = 1000;
  s->st_gid = 1000;
}

int stat(const char *restrict p, struct stat *restrict s) {
  char a[PATH_MAX];
  if (absPath(p, a)) return -1;
  RlStat r;
  if (ret(rl_stat(a, &r)) < 0) return -1;
  fillStat(&r, s);
  return 0;
}

int lstat(const char *restrict p, struct stat *restrict s) { return stat(p, s); }

int fstatat(int d, const char *restrict p, struct stat *restrict s, int f) {
  (void)d; (void)f;
  return stat(p, s);
}

int fstat(int fd, struct stat *s) {
  RlStat r;
  if (fd >= 0 && fd <= 2) {
    memset(s, 0, sizeof *s);
    s->st_mode = S_IFCHR | 0600;
    return 0;
  }
  if (ret(rl_fstat(fd, &r)) < 0) return -1;
  fillStat(&r, s);
  return 0;
}

int access(const char *p, int m) {
  (void)m;
  struct stat s;
  return stat(p, &s);
}

int faccessat(int d, const char *p, int m, int f) { (void)d; (void)f; return access(p, m); }

int chdir(const char *p) {
  char a[PATH_MAX];
  if (absPath(p, a)) return -1;
  struct stat s;
  if (stat(a, &s)) return -1;
  if (!S_ISDIR(s.st_mode)) { errno = ENOTDIR; return -1; }
  strlcpy(cwd, a, sizeof cwd);
  return 0;
}

int fchdir(int fd) { (void)fd; errno = ENOSYS; return -1; }

int open(const char *p, int f, ...) {
  char a[PATH_MAX];
  if (absPath(p, a)) return -1;
  return ret(rl_open(a, f, 0644));
}

int openat(int d, const char *p, int f, ...) { (void)d; return open(p, f); }
int creat(const char *p, mode_t m) { (void)m; return open(p, O_WRONLY | O_CREAT | O_TRUNC); }
int close(int fd) { return fd <= 2 ? 0 : ret(rl_close(fd)); }
ssize_t read(int fd, void *b, size_t n) { return ret(rl_read(fd, b, n)); }
ssize_t write(int fd, const void *b, size_t n) { return ret(rl_write(fd, b, n)); }

off_t lseek(int fd, off_t o, int w) {
  double r = rl_seek(fd, (double)o, w);
  if (r < 0) { errno = (int)-r; return -1; }
  return (off_t)r;
}

ssize_t pread(int fd, void *b, size_t n, off_t o) {
  off_t at = lseek(fd, 0, SEEK_CUR);
  if (at < 0 || lseek(fd, o, SEEK_SET) < 0) return -1;
  ssize_t r = read(fd, b, n);
  lseek(fd, at, SEEK_SET);
  return r;
}

ssize_t pwrite(int fd, const void *b, size_t n, off_t o) {
  off_t at = lseek(fd, 0, SEEK_CUR);
  if (at < 0 || lseek(fd, o, SEEK_SET) < 0) return -1;
  ssize_t r = write(fd, b, n);
  lseek(fd, at, SEEK_SET);
  return r;
}

int ftruncate(int fd, off_t n) { return ret(rl_truncate(fd, (double)n)); }

int truncate(const char *p, off_t n) {
  int fd = open(p, O_WRONLY);
  if (fd < 0) return -1;
  int r = ftruncate(fd, n);
  close(fd);
  return r;
}

int fsync(int fd) { (void)fd; return 0; }
int fdatasync(int fd) { (void)fd; return 0; }

int fcntl(int fd, int cmd, ...) {
  (void)fd;
  switch (cmd) {
  case F_GETFD: return FD_CLOEXEC;
  case F_GETFL: return O_RDWR;
  case F_SETFD: case F_SETFL: case F_SETLK: case F_SETLKW: return 0;
  default: errno = EINVAL; return -1;
  }
}

int mkdir(const char *p, mode_t m) {
  (void)m;
  char a[PATH_MAX];
  if (absPath(p, a)) return -1;
  return ret(rl_mkdir(a));
}

int mkdirat(int d, const char *p, mode_t m) { (void)d; return mkdir(p, m); }

int rmdir(const char *p) {
  char a[PATH_MAX];
  if (absPath(p, a)) return -1;
  return ret(rl_rmdir(a));
}

int unlink(const char *p) {
  char a[PATH_MAX];
  if (absPath(p, a)) return -1;
  return ret(rl_unlink(a));
}

int remove(const char *p) {
  struct stat s;
  if (stat(p, &s)) return -1;
  return S_ISDIR(s.st_mode) ? rmdir(p) : unlink(p);
}

int rename(const char *x, const char *y) {
  char a[PATH_MAX], b[PATH_MAX];
  if (absPath(x, a) || absPath(y, b)) return -1;
  return ret(rl_rename(a, b));
}

int utimensat(int d, const char *p, const struct timespec t[2], int f) {
  (void)d; (void)f;
  char a[PATH_MAX];
  if (absPath(p, a)) return -1;
  double ms = t ? (double)t[1].tv_sec * 1000 + t[1].tv_nsec / 1e6 : rl_now(0);
  return ret(rl_utime(a, ms));
}

int utimes(const char *p, const struct timeval t[2]) {
  char a[PATH_MAX];
  if (absPath(p, a)) return -1;
  double ms = t ? (double)t[1].tv_sec * 1000 + t[1].tv_usec / 1e3 : rl_now(0);
  return ret(rl_utime(a, ms));
}

int futimens(int fd, const struct timespec t[2]) { (void)fd; (void)t; return 0; }
int chmod(const char *p, mode_t m) { (void)m; return access(p, 0); }
int fchmod(int fd, mode_t m) { (void)fd; (void)m; return 0; }
int chown(const char *p, uid_t u, gid_t g) { (void)u; (void)g; return access(p, 0); }
int lchown(const char *p, uid_t u, gid_t g) { (void)u; (void)g; return access(p, 0); }
int fchown(int fd, uid_t u, gid_t g) { (void)fd; (void)u; (void)g; return 0; }
mode_t umask(mode_t m) { (void)m; return 022; }
int mkfifo(const char *p, mode_t m) { (void)p; (void)m; errno = ENOSYS; return -1; }
int link(const char *a, const char *b) { (void)a; (void)b; errno = ENOSYS; return -1; }
int symlink(const char *a, const char *b) { (void)a; (void)b; errno = ENOSYS; return -1; }
ssize_t readlink(const char *restrict p, char *restrict b, size_t n) { (void)p; (void)b; (void)n; errno = EINVAL; return -1; }

char *realpath(const char *restrict p, char *restrict out) {
  char a[PATH_MAX];
  if (absPath(p, a)) return 0;
  struct stat s;
  if (stat(a, &s)) return 0;
  if (!out) return strdup(a);
  strcpy(out, a);
  return out;
}

/* ---- folders ---- */

struct _RlDir {
  char *names;          /* [type][name]\0 ... */
  int len, at;
  struct dirent ent;
};

DIR *opendir(const char *p) {
  char a[PATH_MAX];
  if (absPath(p, a)) return 0;
  int cap = 4096;
  char *buf = malloc((size_t)cap);
  if (!buf) return 0;
  int n = rl_listdir(a, buf, cap);
  if (n > cap) {
    free(buf);
    cap = n;
    buf = malloc((size_t)cap);
    if (!buf) return 0;
    n = rl_listdir(a, buf, cap);
  }
  if (n < 0) { free(buf); errno = -n; return 0; }
  DIR *d = calloc(1, sizeof *d);
  if (!d) { free(buf); return 0; }
  d->names = buf;
  d->len = n;
  return d;
}

struct dirent *readdir(DIR *d) {
  if (!d || d->at >= d->len) return 0;
  unsigned char type = (unsigned char)d->names[d->at++];
  const char *name = d->names + d->at;
  size_t k = strlen(name);
  d->at += (int)k + 1;
  d->ent.d_type = type;
  d->ent.d_ino = (ino_t)d->at;
  d->ent.d_reclen = sizeof d->ent;
  strlcpy(d->ent.d_name, name, sizeof d->ent.d_name);
  return &d->ent;
}

int readdir_r(DIR *restrict d, struct dirent *restrict e, struct dirent **restrict r) {
  struct dirent *x = readdir(d);
  if (x) { *e = *x; *r = e; } else *r = 0;
  return 0;
}

int closedir(DIR *d) {
  if (!d) return -1;
  free(d->names);
  free(d);
  return 0;
}

void rewinddir(DIR *d) { if (d) d->at = 0; }
int dirfd(DIR *d) { (void)d; return -1; }
DIR *fdopendir(int fd) { (void)fd; errno = ENOSYS; return 0; }

/* ---- temporary files ---- */

static void randomName(char *t) {
  size_t n = strlen(t);
  unsigned char r[6];
  rl_random(r, sizeof r);
  for (int i = 0; i < 6 && n >= 6; i++)
    t[n - 6 + i] = "abcdefghijklmnopqrstuvwxyz0123456789"[r[i] % 36];
}

int mkstemp(char *t) {
  for (int tries = 0; tries < 100; tries++) {
    randomName(t);
    int fd = open(t, O_RDWR | O_CREAT | O_EXCL);
    if (fd >= 0 || errno != EEXIST) return fd;
  }
  return -1;
}

char *mkdtemp(char *t) {
  for (int tries = 0; tries < 100; tries++) {
    randomName(t);
    if (!mkdir(t, 0700)) return t;
    if (errno != EEXIST) return 0;
  }
  return 0;
}

char *mktemp(char *t) { randomName(t); return t; }

/* ---- time ---- */

int clock_gettime(clockid_t c, struct timespec *ts) {
  double ms = rl_now(c == CLOCK_REALTIME ? 0 : 1);
  double s = ms / 1000.0;
  ts->tv_sec = (time_t)s;
  ts->tv_nsec = (long)((ms - (double)ts->tv_sec * 1000.0) * 1e6);
  if (ts->tv_nsec < 0) ts->tv_nsec = 0;
  if (ts->tv_nsec > 999999999) ts->tv_nsec = 999999999;
  return 0;
}

int clock_getres(clockid_t c, struct timespec *ts) {
  (void)c;
  if (ts) { ts->tv_sec = 0; ts->tv_nsec = 1000; }
  return 0;
}

int clock_settime(clockid_t c, const struct timespec *ts) { (void)c; (void)ts; errno = EPERM; return -1; }

int gettimeofday(struct timeval *restrict tv, void *restrict tz) {
  (void)tz;
  double ms = rl_now(0);
  tv->tv_sec = (time_t)(ms / 1000.0);
  tv->tv_usec = (suseconds_t)((ms - (double)tv->tv_sec * 1000.0) * 1000.0);
  return 0;
}

int settimeofday(const struct timeval *tv, const struct timezone *tz) { (void)tv; (void)tz; errno = EPERM; return -1; }

time_t time(time_t *t) {
  time_t r = (time_t)(rl_now(0) / 1000.0);
  if (t) *t = r;
  return r;
}

clock_t clock(void) { return (clock_t)(rl_now(1) * 1000.0); }
double difftime(time_t a, time_t b) { return (double)(a - b); }

/* (no sleeping in a browser's thread: a wait is the page's frame) */
int nanosleep(const struct timespec *a, struct timespec *b) { (void)a; if (b) { b->tv_sec = 0; b->tv_nsec = 0; } return 0; }
int clock_nanosleep(clockid_t c, int f, const struct timespec *a, struct timespec *b) { (void)c; (void)f; return nanosleep(a, b); }
unsigned sleep(unsigned s) { (void)s; return 0; }
int usleep(useconds_t u) { (void)u; return 0; }

long timezone;
int daylight;
static char tzStd[] = "UTC", tzDst[] = "UTC";
char *tzname[2] = { tzStd, tzDst };

void tzset(void) {
  timezone = (long)rl_tzoffset(rl_now(0)) * 60;
  daylight = 0;
}

static long long daysFromCivil(long long y, unsigned m, unsigned d) {
  y -= m <= 2;
  long long era = (y >= 0 ? y : y - 399) / 400;
  unsigned yoe = (unsigned)(y - era * 400);
  unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
  unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + (long long)doe - 719468;
}

static void civilFromDays(long long z, int *y, int *m, int *d) {
  z += 719468;
  long long era = (z >= 0 ? z : z - 146096) / 146097;
  unsigned doe = (unsigned)(z - era * 146097);
  unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  long long yy = (long long)yoe + era * 400;
  unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  unsigned mp = (5 * doy + 2) / 153;
  *d = (int)(doy - (153 * mp + 2) / 5 + 1);
  *m = (int)(mp < 10 ? mp + 3 : mp - 9);
  *y = (int)(yy + (*m <= 2));
}

struct tm *gmtime_r(const time_t *restrict t, struct tm *restrict r) {
  long long s = *t;
  long long days = s >= 0 ? s / 86400 : -((-s + 86399) / 86400);
  long long rem = s - days * 86400;
  int y, m, d;
  civilFromDays(days, &y, &m, &d);
  r->tm_year = y - 1900;
  r->tm_mon = m - 1;
  r->tm_mday = d;
  r->tm_hour = (int)(rem / 3600);
  r->tm_min = (int)(rem / 60 % 60);
  r->tm_sec = (int)(rem % 60);
  r->tm_wday = (int)((days % 7 + 11) % 7);       /* 1970-01-01 was a Thursday */
  r->tm_yday = (int)(days - daysFromCivil(y, 1, 1));
  r->tm_isdst = 0;
  r->tm_gmtoff = 0;
  r->tm_zone = "UTC";
  return r;
}

struct tm *gmtime(const time_t *t) { static struct tm r; return gmtime_r(t, &r); }

struct tm *localtime_r(const time_t *restrict t, struct tm *restrict r) {
  long off = -(long)rl_tzoffset((double)*t * 1000.0) * 60;    /* seconds east */
  time_t l = *t + off;
  gmtime_r(&l, r);
  r->tm_gmtoff = off;
  r->tm_zone = "LOCAL";
  return r;
}

struct tm *localtime(const time_t *t) { static struct tm r; return localtime_r(t, &r); }

static time_t fromTm(struct tm *tm) {
  long long y = tm->tm_year + 1900LL;
  long long mon = tm->tm_mon;
  y += mon / 12;
  mon %= 12;
  if (mon < 0) { mon += 12; y--; }
  long long days = daysFromCivil(y, (unsigned)mon + 1, 1) + tm->tm_mday - 1;
  return (time_t)(days * 86400 + tm->tm_hour * 3600LL + tm->tm_min * 60LL + tm->tm_sec);
}

time_t timegm(struct tm *tm) {
  time_t t = fromTm(tm);
  gmtime_r(&t, tm);
  return t;
}

time_t mktime(struct tm *tm) {
  time_t guess = fromTm(tm);
  long off = -(long)rl_tzoffset((double)guess * 1000.0) * 60;
  time_t t = guess - off;
  localtime_r(&t, tm);
  return t;
}

static const char *const wdays[] = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
static const char *const months[] = { "January", "February", "March", "April", "May", "June", "July",
                                      "August", "September", "October", "November", "December" };

size_t strftime(char *restrict s, size_t n, const char *restrict f, const struct tm *restrict tm) {
  size_t k = 0;
  char b[64];
  for (; *f; f++) {
    const char *add = b;
    b[0] = 0;
    if (*f != '%') { b[0] = *f; b[1] = 0; }
    else {
      f++;
      switch (*f) {
      case 'Y': snprintf(b, sizeof b, "%d", tm->tm_year + 1900); break;
      case 'y': snprintf(b, sizeof b, "%02d", (tm->tm_year + 1900) % 100); break;
      case 'm': snprintf(b, sizeof b, "%02d", tm->tm_mon + 1); break;
      case 'd': snprintf(b, sizeof b, "%02d", tm->tm_mday); break;
      case 'e': snprintf(b, sizeof b, "%2d", tm->tm_mday); break;
      case 'H': snprintf(b, sizeof b, "%02d", tm->tm_hour); break;
      case 'I': snprintf(b, sizeof b, "%02d", tm->tm_hour % 12 ? tm->tm_hour % 12 : 12); break;
      case 'M': snprintf(b, sizeof b, "%02d", tm->tm_min); break;
      case 'S': snprintf(b, sizeof b, "%02d", tm->tm_sec); break;
      case 'p': add = tm->tm_hour < 12 ? "AM" : "PM"; break;
      case 'j': snprintf(b, sizeof b, "%03d", tm->tm_yday + 1); break;
      case 'a': snprintf(b, 4, "%s", wdays[tm->tm_wday % 7]); break;
      case 'A': add = wdays[tm->tm_wday % 7]; break;
      case 'b': case 'h': snprintf(b, 4, "%s", months[tm->tm_mon % 12]); break;
      case 'B': add = months[tm->tm_mon % 12]; break;
      case 'w': snprintf(b, sizeof b, "%d", tm->tm_wday); break;
      case 'u': snprintf(b, sizeof b, "%d", tm->tm_wday ? tm->tm_wday : 7); break;
      case 'z': { long o = tm->tm_gmtoff; snprintf(b, sizeof b, "%c%02ld%02ld", o < 0 ? '-' : '+', labs(o) / 3600, labs(o) / 60 % 60); break; }
      case 'Z': add = tm->tm_zone ? tm->tm_zone : "UTC"; break;
      case 'F': snprintf(b, sizeof b, "%d-%02d-%02d", tm->tm_year + 1900, tm->tm_mon + 1, tm->tm_mday); break;
      case 'T': snprintf(b, sizeof b, "%02d:%02d:%02d", tm->tm_hour, tm->tm_min, tm->tm_sec); break;
      case 'R': snprintf(b, sizeof b, "%02d:%02d", tm->tm_hour, tm->tm_min); break;
      case 'D': snprintf(b, sizeof b, "%02d/%02d/%02d", tm->tm_mon + 1, tm->tm_mday, (tm->tm_year + 1900) % 100); break;
      case 'c': snprintf(b, sizeof b, "%.3s %.3s %2d %02d:%02d:%02d %d", wdays[tm->tm_wday % 7], months[tm->tm_mon % 12],
                         tm->tm_mday, tm->tm_hour, tm->tm_min, tm->tm_sec, tm->tm_year + 1900); break;
      case 'x': snprintf(b, sizeof b, "%02d/%02d/%02d", tm->tm_mon + 1, tm->tm_mday, (tm->tm_year + 1900) % 100); break;
      case 'X': snprintf(b, sizeof b, "%02d:%02d:%02d", tm->tm_hour, tm->tm_min, tm->tm_sec); break;
      case 's': { struct tm c = *tm; snprintf(b, sizeof b, "%lld", (long long)timegm(&c) - tm->tm_gmtoff); break; }
      case 'n': add = "\n"; break;
      case 't': add = "\t"; break;
      case '%': add = "%"; break;
      default: b[0] = '%'; b[1] = *f; b[2] = 0;
      }
    }
    size_t l = strlen(add);
    if (k + l >= n) return 0;
    memcpy(s + k, add, l);
    k += l;
  }
  if (k >= n) return 0;
  s[k] = 0;
  return k;
}

char *asctime(const struct tm *tm) {
  static char b[32];
  strftime(b, sizeof b, "%a %b %e %H:%M:%S %Y\n", tm);
  return b;
}

char *ctime(const time_t *t) { return asctime(localtime(t)); }
char *strptime(const char *restrict s, const char *restrict f, struct tm *restrict tm) { (void)s; (void)f; (void)tm; return 0; }

/* ---- the environment ---- */

char **environ;
static char *envBlock;

static void loadEnv(void) {
  if (environ) return;
  int need = rl_env(0, 0);
  envBlock = malloc((size_t)need + 2);
  int n = envBlock ? rl_env(envBlock, need + 2) : 0;
  int count = 0;
  for (int i = 0; i < n; i += (int)strlen(envBlock + i) + 1) count++;
  environ = calloc((size_t)count + 1, sizeof(char *));
  int k = 0;
  for (int i = 0; i < n && k < count; i += (int)strlen(envBlock + i) + 1) environ[k++] = strdup(envBlock + i);
}

char *getenv(const char *name) {
  loadEnv();
  size_t l = strlen(name);
  for (char **e = environ; e && *e; e++)
    if (!strncmp(*e, name, l) && (*e)[l] == '=') return *e + l + 1;
  return 0;
}

int setenv(const char *name, const char *value, int overwrite) {
  loadEnv();
  if (!name || !*name || strchr(name, '=')) { errno = EINVAL; return -1; }
  size_t l = strlen(name);
  int n = 0;
  for (char **e = environ; *e; e++, n++)
    if (!strncmp(*e, name, l) && (*e)[l] == '=') {
      if (!overwrite) return 0;
      char *s = malloc(l + strlen(value) + 2);
      if (!s) return -1;
      sprintf(s, "%s=%s", name, value);
      free(*e);
      *e = s;
      return 0;
    }
  char **ne = realloc(environ, (size_t)(n + 2) * sizeof(char *));
  if (!ne) return -1;
  environ = ne;
  char *s = malloc(l + strlen(value) + 2);
  if (!s) return -1;
  sprintf(s, "%s=%s", name, value);
  environ[n] = s;
  environ[n + 1] = 0;
  return 0;
}

int unsetenv(const char *name) {
  loadEnv();
  size_t l = strlen(name);
  for (char **e = environ; *e; e++)
    if (!strncmp(*e, name, l) && (*e)[l] == '=') {
      free(*e);
      char **q = e;
      do { q[0] = q[1]; q++; } while (*q);
      return 0;
    }
  return 0;
}

int putenv(char *s) {
  char *eq = strchr(s, '=');
  if (!eq) return unsetenv(s);
  char name[256];
  size_t l = (size_t)(eq - s) < sizeof name - 1 ? (size_t)(eq - s) : sizeof name - 1;
  memcpy(name, s, l);
  name[l] = 0;
  return setenv(name, eq + 1, 1);
}

int clearenv(void) {
  loadEnv();
  for (char **e = environ; *e; e++) free(*e);
  environ[0] = 0;
  return 0;
}

/* ---- the end ---- */

static void (*atexitFns[32])(void);
static int atexitCount;

int atexit(void (*f)(void)) {
  if (atexitCount >= 32) return -1;
  atexitFns[atexitCount++] = f;
  return 0;
}

void __rl_stdio_flush(void);

_Noreturn void exit(int code) {
  while (atexitCount) atexitFns[--atexitCount]();
  __rl_stdio_flush();
  rl_exit(code);
}

_Noreturn void _Exit(int code) { rl_exit(code); }
_Noreturn void _exit(int code) { rl_exit(code); }

_Noreturn void abort(void) {
  __rl_stdio_flush();
  rl_abort("abort()");
}

_Noreturn void __rl_assert_fail(const char *e, const char *f, int l) {
  char b[512];
  snprintf(b, sizeof b, "%s:%d: assertion failed: %s", f, l, e);
  rl_abort(b);
}

/* ---- randomness ---- */

int getentropy(void *b, size_t n) { rl_random(b, n); return 0; }

static unsigned long long randState = 0x853c49e6748fea9bull;

int rand(void) {
  randState = randState * 6364136223846793005ull + 1442695040888963407ull;
  return (int)(randState >> 33);
}

void srand(unsigned s) { randState = s * 2654435761ull + 1; }
long random(void) { return rand(); }
void srandom(unsigned s) { srand(s); }

/* ---- what a browser does not have ---- */

pid_t getpid(void) { return 1; }
pid_t getppid(void) { return 0; }
pid_t fork(void) { errno = ENOSYS; return -1; }
pid_t vfork(void) { errno = ENOSYS; return -1; }
pid_t setsid(void) { return 1; }
int setpgid(pid_t p, pid_t g) { (void)p; (void)g; return 0; }
pid_t getpgrp(void) { return 1; }
uid_t getuid(void) { return 1000; }
uid_t geteuid(void) { return 1000; }
gid_t getgid(void) { return 1000; }
gid_t getegid(void) { return 1000; }
int setuid(uid_t u) { (void)u; return 0; }
int setgid(gid_t g) { (void)g; return 0; }
int execv(const char *p, char *const a[]) { (void)p; (void)a; errno = ENOSYS; return -1; }
int execve(const char *p, char *const a[], char *const e[]) { (void)p; (void)a; (void)e; errno = ENOSYS; return -1; }
int execvp(const char *p, char *const a[]) { (void)p; (void)a; errno = ENOSYS; return -1; }
int system(const char *cmd) { (void)cmd; return -1; }
int isatty(int fd) { (void)fd; return 0; }
char *ttyname(int fd) { (void)fd; return 0; }
int dup(int fd) { (void)fd; errno = ENOSYS; return -1; }
int dup2(int a, int b) { (void)a; (void)b; errno = ENOSYS; return -1; }
int pipe(int fds[2]) { (void)fds; errno = ENOSYS; return -1; }
int pipe2(int fds[2], int f) { (void)fds; (void)f; errno = ENOSYS; return -1; }
unsigned alarm(unsigned s) { (void)s; return 0; }
int nice(int n) { (void)n; return 0; }
int gethostname(char *n, size_t l) { strlcpy(n, "browser", l); return 0; }
char *getlogin(void) { return (char *)"web"; }
int getlogin_r(char *b, size_t n) { strlcpy(b, "web", n); return 0; }
int getpagesize(void) { return 65536; }
int getloadavg(double *l, int n) { for (int i = 0; i < n; i++) l[i] = 0; return n; }

long sysconf(int n) {
  switch (n) {
  case _SC_PAGESIZE: return 65536;
  case _SC_NPROCESSORS_CONF: case _SC_NPROCESSORS_ONLN: return 1;
  case _SC_CLK_TCK: return 100;
  case _SC_OPEN_MAX: return 1024;
  case _SC_PHYS_PAGES: return 32768;           /* (2 GB of 64 KB pages) */
  case _SC_HOST_NAME_MAX: return 64;
  case _SC_GETPW_R_SIZE_MAX: return 1024;
  default: errno = EINVAL; return -1;
  }
}

long pathconf(const char *p, int n) { (void)p; return n == _PC_NAME_MAX ? 255 : 4096; }
long fpathconf(int fd, int n) { (void)fd; return n == _PC_NAME_MAX ? 255 : 4096; }

void *mmap(void *a, size_t n, int prot, int flags, int fd, off_t o) {
  (void)a; (void)prot;
  if (!(flags & MAP_ANONYMOUS)) {
    /* a file: read into memory (what is written there stays there) */
    void *p = malloc(n);
    if (!p) return MAP_FAILED;
    memset(p, 0, n);
    if (pread(fd, p, n, o) < 0) { free(p); return MAP_FAILED; }
    return p;
  }
  void *p = aligned_alloc(65536 <= n ? 64 : 16, n);
  if (!p) { errno = ENOMEM; return MAP_FAILED; }
  memset(p, 0, n);
  return p;
}

int munmap(void *a, size_t n) { (void)n; free(a); return 0; }
int mprotect(void *a, size_t n, int prot) { (void)a; (void)n; (void)prot; return 0; }
int madvise(void *a, size_t n, int adv) { (void)a; (void)n; (void)adv; return 0; }
int msync(void *a, size_t n, int f) { (void)a; (void)n; (void)f; return 0; }
int mlock(const void *a, size_t n) { (void)a; (void)n; return 0; }
int munlock(const void *a, size_t n) { (void)a; (void)n; return 0; }
int memfd_create(const char *n, unsigned f) { (void)n; (void)f; errno = ENOSYS; return -1; }
int shm_open(const char *n, int f, mode_t m) { (void)n; (void)f; (void)m; errno = ENOSYS; return -1; }
int shm_unlink(const char *n) { (void)n; errno = ENOSYS; return -1; }

int poll(struct pollfd *f, nfds_t n, int timeout) {
  (void)timeout;
  for (nfds_t i = 0; i < n; i++) f[i].revents = 0;
  return 0;
}

sighandler_t signal(int s, sighandler_t h) { (void)s; (void)h; return SIG_DFL; }
int raise(int s) { if (s == SIGABRT) abort(); return 0; }
int kill(pid_t p, int s) { (void)p; (void)s; errno = EPERM; return -1; }
int sigaction(int s, const struct sigaction *restrict a, struct sigaction *restrict o) {
  (void)s; (void)a;
  if (o) memset(o, 0, sizeof *o);
  return 0;
}
int sigemptyset(sigset_t *s) { *s = 0; return 0; }
int sigfillset(sigset_t *s) { *s = ~0ull; return 0; }
int sigaddset(sigset_t *s, int n) { *s |= 1ull << (n & 63); return 0; }
int sigdelset(sigset_t *s, int n) { *s &= ~(1ull << (n & 63)); return 0; }
int sigismember(const sigset_t *s, int n) { return (int)((*s >> (n & 63)) & 1); }
int sigprocmask(int h, const sigset_t *restrict s, sigset_t *restrict o) { (void)h; (void)s; if (o) *o = 0; return 0; }
int pthread_sigmask(int h, const sigset_t *restrict s, sigset_t *restrict o) { return sigprocmask(h, s, o); }
int sigaltstack(const stack_t *restrict s, stack_t *restrict o) { (void)s; if (o) memset(o, 0, sizeof *o); return 0; }
int sigwait(const sigset_t *restrict s, int *restrict n) { (void)s; (void)n; errno = ENOSYS; return -1; }

void *dlopen(const char *p, int f) { (void)p; (void)f; return 0; }
void *dlsym(void *restrict h, const char *restrict n) { (void)h; (void)n; return 0; }
int dlclose(void *h) { (void)h; return 0; }
char *dlerror(void) { return (char *)"no shared libraries in a browser"; }

char *setlocale(int c, const char *l) { (void)c; (void)l; return (char *)"C.UTF-8"; }
static struct lconv cLocale = { ".", "", "", "", "", "", "", "", "", "" };
struct lconv *localeconv(void) { return &cLocale; }

/* ---- threads: one ---- */

int pthread_create(pthread_t *restrict t, const pthread_attr_t *restrict a, void *(*f)(void *), void *restrict arg) {
  (void)t; (void)a; (void)f; (void)arg;
  return EAGAIN;
}
int pthread_join(pthread_t t, void **r) { (void)t; if (r) *r = 0; return 0; }
int pthread_detach(pthread_t t) { (void)t; return 0; }
_Noreturn void pthread_exit(void *r) { (void)r; exit(0); }
pthread_t pthread_self(void) { return 1; }
int pthread_equal(pthread_t a, pthread_t b) { return a == b; }
int pthread_cancel(pthread_t t) { (void)t; return 0; }
int pthread_kill(pthread_t t, int s) { (void)t; (void)s; return 0; }
int pthread_setcancelstate(int s, int *o) { (void)s; if (o) *o = 0; return 0; }
int pthread_attr_init(pthread_attr_t *a) { a->stacksize = 65536; a->detach = 0; return 0; }
int pthread_attr_destroy(pthread_attr_t *a) { (void)a; return 0; }
int pthread_attr_setstacksize(pthread_attr_t *a, size_t n) { a->stacksize = n; return 0; }
int pthread_attr_getstacksize(const pthread_attr_t *restrict a, size_t *restrict n) { *n = a->stacksize; return 0; }
int pthread_attr_setdetachstate(pthread_attr_t *a, int s) { a->detach = s; return 0; }
int pthread_getattr_np(pthread_t t, pthread_attr_t *a) { (void)t; return pthread_attr_init(a); }
int pthread_attr_getstack(const pthread_attr_t *restrict a, void **restrict p, size_t *restrict n) { (void)a; *p = 0; *n = 0; return 0; }
int pthread_setname_np(pthread_t t, const char *n) { (void)t; (void)n; return 0; }
int pthread_setaffinity_np(pthread_t t, size_t n, const void *s) { (void)t; (void)n; (void)s; return 0; }
int pthread_mutex_init(pthread_mutex_t *restrict m, const pthread_mutexattr_t *restrict a) { m->kind = a ? a->kind : 0; m->locked = 0; return 0; }
int pthread_mutex_destroy(pthread_mutex_t *m) { (void)m; return 0; }
int pthread_mutex_lock(pthread_mutex_t *m) { m->locked++; return 0; }
int pthread_mutex_trylock(pthread_mutex_t *m) {
  if (m->locked && m->kind != PTHREAD_MUTEX_RECURSIVE) return EBUSY;
  m->locked++;
  return 0;
}
int pthread_mutex_unlock(pthread_mutex_t *m) { if (m->locked) m->locked--; return 0; }
int pthread_mutexattr_init(pthread_mutexattr_t *a) { a->kind = 0; return 0; }
int pthread_mutexattr_destroy(pthread_mutexattr_t *a) { (void)a; return 0; }
int pthread_mutexattr_settype(pthread_mutexattr_t *a, int t) { a->kind = t; return 0; }
int pthread_cond_init(pthread_cond_t *restrict c, const pthread_condattr_t *restrict a) { (void)a; c->waiters = 0; return 0; }
int pthread_cond_destroy(pthread_cond_t *c) { (void)c; return 0; }
/* (nobody else could signal it: a wait would be forever, so it returns) */
int pthread_cond_wait(pthread_cond_t *restrict c, pthread_mutex_t *restrict m) { (void)c; (void)m; return 0; }
int pthread_cond_timedwait(pthread_cond_t *restrict c, pthread_mutex_t *restrict m, const struct timespec *restrict t) { (void)c; (void)m; (void)t; return ETIMEDOUT; }
int pthread_cond_signal(pthread_cond_t *c) { (void)c; return 0; }
int pthread_cond_broadcast(pthread_cond_t *c) { (void)c; return 0; }
int pthread_condattr_init(pthread_condattr_t *a) { a->clock = 0; return 0; }
int pthread_condattr_destroy(pthread_condattr_t *a) { (void)a; return 0; }
int pthread_condattr_setclock(pthread_condattr_t *a, clockid_t c) { a->clock = c; return 0; }

static const void *keyValues[128];
static unsigned keyCount;
int pthread_key_create(pthread_key_t *k, void (*d)(void *)) {
  (void)d;
  if (keyCount >= 128) return EAGAIN;
  *k = keyCount++;
  return 0;
}
int pthread_key_delete(pthread_key_t k) { (void)k; return 0; }
void *pthread_getspecific(pthread_key_t k) { return k < 128 ? (void *)keyValues[k] : 0; }
int pthread_setspecific(pthread_key_t k, const void *v) { if (k >= 128) return EINVAL; keyValues[k] = v; return 0; }
int pthread_once(pthread_once_t *o, void (*f)(void)) { if (!*o) { *o = 1; f(); } return 0; }
int pthread_rwlock_init(pthread_rwlock_t *restrict l, const pthread_rwlockattr_t *restrict a) { (void)a; l->readers = l->writer = 0; return 0; }
int pthread_rwlock_destroy(pthread_rwlock_t *l) { (void)l; return 0; }
int pthread_rwlock_rdlock(pthread_rwlock_t *l) { l->readers++; return 0; }
int pthread_rwlock_wrlock(pthread_rwlock_t *l) { l->writer = 1; return 0; }
int pthread_rwlock_unlock(pthread_rwlock_t *l) { if (l->writer) l->writer = 0; else if (l->readers) l->readers--; return 0; }
int sched_yield(void) { return 0; }
int sched_getcpu(void) { return 0; }

/* ---- sorting ---- */

static void swapBytes(unsigned char *a, unsigned char *b, size_t w) {
  while (w--) { unsigned char t = *a; *a++ = *b; *b++ = t; }
}

static void sortRange(unsigned char *base, size_t n, size_t w, int (*cmp)(const void *, const void *)) {
  while (n > 12) {
    /* the middle of three as the pivot, moved to the end */
    unsigned char *a = base, *m = base + (n / 2) * w, *z = base + (n - 1) * w;
    if (cmp(m, a) < 0) swapBytes(m, a, w);
    if (cmp(z, m) < 0) { swapBytes(z, m, w); if (cmp(m, a) < 0) swapBytes(m, a, w); }
    swapBytes(m, z - w, w);
    unsigned char *pivot = z - w;
    size_t i = 0, j = n - 2;
    for (;;) {
      while (cmp(base + (++i) * w, pivot) < 0) {}
      while (j > 0 && cmp(base + (--j) * w, pivot) > 0) {}
      if (i >= j) break;
      swapBytes(base + i * w, base + j * w, w);
    }
    swapBytes(base + i * w, pivot, w);
    /* the smaller side by recursion, the larger by the loop */
    if (i < n - i - 1) { sortRange(base, i, w, cmp); base += (i + 1) * w; n -= i + 1; }
    else { sortRange(base + (i + 1) * w, n - i - 1, w, cmp); n = i; }
  }
  for (size_t i = 1; i < n; i++)
    for (size_t j = i; j > 0 && cmp(base + (j - 1) * w, base + j * w) > 0; j--)
      swapBytes(base + (j - 1) * w, base + j * w, w);
}

void qsort(void *b, size_t n, size_t w, int (*cmp)(const void *, const void *)) {
  if (n > 1 && w) sortRange(b, n, w, cmp);
}

void *bsearch(const void *k, const void *b, size_t n, size_t w, int (*cmp)(const void *, const void *)) {
  const unsigned char *base = b;
  while (n) {
    size_t h = n / 2;
    const unsigned char *m = base + h * w;
    int c = cmp(k, m);
    if (!c) return (void *)m;
    if (c > 0) { base = m + w; n -= h + 1; } else n = h;
  }
  return 0;
}

/* ---- wide characters (UTF-8) ---- */

size_t wcslen(const wchar_t *s) { size_t n = 0; while (s[n]) n++; return n; }
int mbsinit(const mbstate_t *st) { return !st || !st->count; }
int mblen(const char *s, size_t n) {
  if (!s || !n) return 0;
  unsigned char c = (unsigned char)*s;
  if (!c) return 0;
  int k = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
  return (size_t)k <= n ? k : -1;
}
size_t mbrtowc(wchar_t *restrict w, const char *restrict s, size_t n, mbstate_t *restrict st) {
  (void)st;
  if (!s) return 0;
  int k = mblen(s, n);
  if (k <= 0) { if (w) *w = 0; return k == 0 ? 0 : (size_t)-1; }
  const unsigned char *p = (const unsigned char *)s;
  wchar_t c = k == 1 ? p[0] : k == 2 ? ((p[0] & 31) << 6) | (p[1] & 63)
    : k == 3 ? ((p[0] & 15) << 12) | ((p[1] & 63) << 6) | (p[2] & 63)
    : ((p[0] & 7) << 18) | ((p[1] & 63) << 12) | ((p[2] & 63) << 6) | (p[3] & 63);
  if (w) *w = c;
  return (size_t)k;
}
size_t wcrtomb(char *restrict s, wchar_t w, mbstate_t *restrict st) {
  (void)st;
  unsigned c = (unsigned)w;
  if (!s) return 1;
  if (c < 0x80) { s[0] = (char)c; return 1; }
  if (c < 0x800) { s[0] = (char)(0xC0 | (c >> 6)); s[1] = (char)(0x80 | (c & 63)); return 2; }
  if (c < 0x10000) { s[0] = (char)(0xE0 | (c >> 12)); s[1] = (char)(0x80 | ((c >> 6) & 63)); s[2] = (char)(0x80 | (c & 63)); return 3; }
  s[0] = (char)(0xF0 | (c >> 18)); s[1] = (char)(0x80 | ((c >> 12) & 63));
  s[2] = (char)(0x80 | ((c >> 6) & 63)); s[3] = (char)(0x80 | (c & 63));
  return 4;
}
