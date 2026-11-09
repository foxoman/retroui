/* What the toolkit's and Nim's library code may call that a browser has
   no way to do: it says so (ENOSYS, EAFNOSUPPORT) instead of doing it. */

#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <iconv.h>
#include <pthread.h>
#include <sys/select.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/utsname.h>
#include <sys/statvfs.h>
#include <spawn.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <net/if.h>
#include <termios.h>
#include <pwd.h>
#include <grp.h>
#include <sys/stat.h>
#include <stdint.h>

RL_IMPORT(rl_random) void rl_random(void *p, size_t n);

long syscall(long n, ...) {
  if (n == SYS_gettid) return (long)pthread_self();
  if (n == SYS_getrandom) {
    /* (Nim's std/sysrand asks this way: the browser's crypto.getRandomValues) */
    va_list a;
    va_start(a, n);
    void *buf = va_arg(a, void *);
    size_t len = va_arg(a, size_t);
    va_end(a);
    rl_random(buf, len);
    return (long)len;
  }
  errno = ENOSYS;
  return -1;
}

int select(int n, fd_set *restrict r, fd_set *restrict w, fd_set *restrict e, struct timeval *restrict t) {
  (void)n; (void)t;
  if (r) FD_ZERO(r);
  if (w) FD_ZERO(w);
  if (e) FD_ZERO(e);
  return 0;
}

ssize_t readv(int fd, const struct iovec *v, int n) {
  ssize_t total = 0;
  for (int i = 0; i < n; i++) {
    ssize_t k = read(fd, v[i].iov_base, v[i].iov_len);
    if (k < 0) return total ? total : -1;
    total += k;
    if ((size_t)k < v[i].iov_len) break;
  }
  return total;
}

ssize_t writev(int fd, const struct iovec *v, int n) {
  ssize_t total = 0;
  for (int i = 0; i < n; i++) {
    ssize_t k = write(fd, v[i].iov_base, v[i].iov_len);
    if (k < 0) return total ? total : -1;
    total += k;
  }
  return total;
}

pid_t wait(int *s) { (void)s; errno = ECHILD; return -1; }
pid_t waitpid(pid_t p, int *s, int o) { (void)p; (void)s; (void)o; errno = ECHILD; return -1; }

int posix_spawn(pid_t *restrict p, const char *restrict path, const posix_spawn_file_actions_t *a,
                const posix_spawnattr_t *restrict at, char *const argv[restrict], char *const envp[restrict]) {
  (void)p; (void)path; (void)a; (void)at; (void)argv; (void)envp;
  return ENOSYS;
}
int posix_spawnp(pid_t *restrict p, const char *restrict path, const posix_spawn_file_actions_t *a,
                 const posix_spawnattr_t *restrict at, char *const argv[restrict], char *const envp[restrict]) {
  return posix_spawn(p, path, a, at, argv, envp);
}
int posix_spawnattr_init(posix_spawnattr_t *a) { a->flags = 0; return 0; }
int posix_spawnattr_destroy(posix_spawnattr_t *a) { (void)a; return 0; }
int posix_spawnattr_setflags(posix_spawnattr_t *a, short f) { a->flags = f; return 0; }
int posix_spawnattr_setpgroup(posix_spawnattr_t *a, pid_t g) { (void)a; (void)g; return 0; }
int posix_spawnattr_setsigmask(posix_spawnattr_t *restrict a, const sigset_t *restrict m) { (void)a; (void)m; return 0; }
int posix_spawn_file_actions_init(posix_spawn_file_actions_t *a) { a->n = 0; return 0; }
int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *a) { (void)a; return 0; }
int posix_spawn_file_actions_addclose(posix_spawn_file_actions_t *a, int fd) { (void)a; (void)fd; return 0; }
int posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *a, int fd, int nfd) { (void)a; (void)fd; (void)nfd; return 0; }

#define NOSOCK { errno = EAFNOSUPPORT; return -1; }
int socket(int d, int t, int p) { (void)d; (void)t; (void)p; NOSOCK }
int socketpair(int d, int t, int p, int s[2]) { (void)d; (void)t; (void)p; (void)s; NOSOCK }
int bind(int s, const struct sockaddr *a, socklen_t l) { (void)s; (void)a; (void)l; NOSOCK }
int listen(int s, int n) { (void)s; (void)n; NOSOCK }
int accept(int s, struct sockaddr *restrict a, socklen_t *restrict l) { (void)s; (void)a; (void)l; NOSOCK }
int accept4(int s, struct sockaddr *restrict a, socklen_t *restrict l, int f) { (void)s; (void)a; (void)l; (void)f; NOSOCK }
int connect(int s, const struct sockaddr *a, socklen_t l) { (void)s; (void)a; (void)l; NOSOCK }
int shutdown(int s, int h) { (void)s; (void)h; NOSOCK }
ssize_t send(int s, const void *b, size_t n, int f) { (void)s; (void)b; (void)n; (void)f; NOSOCK }
ssize_t recv(int s, void *b, size_t n, int f) { (void)s; (void)b; (void)n; (void)f; NOSOCK }
ssize_t sendto(int s, const void *b, size_t n, int f, const struct sockaddr *a, socklen_t l) { (void)s; (void)b; (void)n; (void)f; (void)a; (void)l; NOSOCK }
ssize_t recvfrom(int s, void *restrict b, size_t n, int f, struct sockaddr *restrict a, socklen_t *restrict l) { (void)s; (void)b; (void)n; (void)f; (void)a; (void)l; NOSOCK }
ssize_t sendmsg(int s, const struct msghdr *m, int f) { (void)s; (void)m; (void)f; NOSOCK }
ssize_t recvmsg(int s, struct msghdr *m, int f) { (void)s; (void)m; (void)f; NOSOCK }
int getsockopt(int s, int lv, int n, void *restrict v, socklen_t *restrict l) { (void)s; (void)lv; (void)n; (void)v; (void)l; NOSOCK }
int setsockopt(int s, int lv, int n, const void *v, socklen_t l) { (void)s; (void)lv; (void)n; (void)v; (void)l; NOSOCK }
int getsockname(int s, struct sockaddr *restrict a, socklen_t *restrict l) { (void)s; (void)a; (void)l; NOSOCK }
int getpeername(int s, struct sockaddr *restrict a, socklen_t *restrict l) { (void)s; (void)a; (void)l; NOSOCK }

const struct in6_addr in6addr_any = { { { 0 } } };
const struct in6_addr in6addr_loopback = { { { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } } };
uint16_t htons(uint16_t x) { return (uint16_t)((x << 8) | (x >> 8)); }
uint16_t ntohs(uint16_t x) { return htons(x); }
uint32_t htonl(uint32_t x) { return __builtin_bswap32(x); }
uint32_t ntohl(uint32_t x) { return __builtin_bswap32(x); }

int inet_aton(const char *s, struct in_addr *a) {
  unsigned b[4];
  int n = 0;
  const char *p = s;
  for (; n < 4; n++) {
    char *e;
    unsigned long v = strtoul(p, &e, 10);
    if (e == p || v > 255) return 0;
    b[n] = (unsigned)v;
    p = e;
    if (n < 3) { if (*p != '.') return 0; p++; }
  }
  if (*p) return 0;
  a->s_addr = htonl((b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]);
  return 1;
}

in_addr_t inet_addr(const char *s) { struct in_addr a; return inet_aton(s, &a) ? a.s_addr : INADDR_NONE; }

char *inet_ntoa(struct in_addr a) {
  static char b[16];
  uint32_t x = ntohl(a.s_addr);
  snprintf(b, sizeof b, "%u.%u.%u.%u", x >> 24, (x >> 16) & 255, (x >> 8) & 255, x & 255);
  return b;
}

int inet_pton(int af, const char *restrict s, void *restrict d) {
  if (af == AF_INET) return inet_aton(s, d);
  errno = EAFNOSUPPORT;
  return -1;
}

const char *inet_ntop(int af, const void *restrict s, char *restrict d, socklen_t n) {
  if (af == AF_INET) {
    struct in_addr a;
    memcpy(&a, s, 4);
    strlcpy(d, inet_ntoa(a), n);
    return d;
  }
  errno = EAFNOSUPPORT;
  return 0;
}

int getaddrinfo(const char *restrict h, const char *restrict s, const struct addrinfo *restrict hint, struct addrinfo **restrict r) {
  (void)h; (void)s; (void)hint;
  *r = 0;
  return EAI_FAIL;
}
void freeaddrinfo(struct addrinfo *a) { (void)a; }
const char *gai_strerror(int e) { (void)e; return "no name lookups in a browser"; }
int getnameinfo(const struct sockaddr *restrict a, socklen_t l, char *restrict h, socklen_t hl, char *restrict s, socklen_t sl, int f) {
  (void)a; (void)l; (void)h; (void)hl; (void)s; (void)sl; (void)f;
  return EAI_FAIL;
}
struct hostent *gethostbyname(const char *n) { (void)n; return 0; }
struct hostent *gethostbyaddr(const void *a, socklen_t l, int t) { (void)a; (void)l; (void)t; return 0; }
struct servent *getservbyname(const char *n, const char *p) { (void)n; (void)p; return 0; }
struct servent *getservbyport(int port, const char *p) { (void)port; (void)p; return 0; }
struct protoent *getprotobyname(const char *n) { (void)n; return 0; }
unsigned if_nametoindex(const char *n) { (void)n; return 0; }
char *if_indextoname(unsigned i, char *n) { (void)i; (void)n; return 0; }

int ioctl(int fd, unsigned long req, ...) { (void)fd; (void)req; errno = ENOTTY; return -1; }
int tcgetattr(int fd, struct termios *t) { (void)fd; (void)t; errno = ENOTTY; return -1; }
int tcsetattr(int fd, int a, const struct termios *t) { (void)fd; (void)a; (void)t; errno = ENOTTY; return -1; }

int getrlimit(int r, struct rlimit *l) { (void)r; l->rlim_cur = l->rlim_max = RLIM_INFINITY; return 0; }
int setrlimit(int r, const struct rlimit *l) { (void)r; (void)l; return 0; }
int getrusage(int w, struct rusage *u) { (void)w; memset(u, 0, sizeof *u); return 0; }
int getpriority(int w, id_t i) { (void)w; (void)i; return 0; }
int setpriority(int w, id_t i, int p) { (void)w; (void)i; (void)p; return 0; }

int uname(struct utsname *u) {
  memset(u, 0, sizeof *u);
  strcpy(u->sysname, "Browser");
  strcpy(u->nodename, "browser");
  strcpy(u->release, "1");
  strcpy(u->version, "1");
  strcpy(u->machine, "wasm32");
  return 0;
}

int statvfs(const char *restrict p, struct statvfs *restrict s) {
  (void)p;
  memset(s, 0, sizeof *s);
  s->f_bsize = s->f_frsize = 4096;
  s->f_blocks = 262144;        /* (a gigabyte: what browsers give a site, roughly) */
  s->f_bfree = s->f_bavail = 131072;
  s->f_namemax = 255;
  return 0;
}
int fstatvfs(int fd, struct statvfs *s) { (void)fd; return statvfs("/", s); }

static struct passwd webUser = { (char *)"web", (char *)"x", 1000, 1000, (char *)"Web", (char *)"/home/web", (char *)"/bin/sh" };
struct passwd *getpwuid(uid_t u) { (void)u; return &webUser; }
struct passwd *getpwnam(const char *n) { (void)n; return &webUser; }
int getpwuid_r(uid_t u, struct passwd *p, char *b, size_t n, struct passwd **r) { (void)u; (void)b; (void)n; *p = webUser; *r = p; return 0; }
int getpwnam_r(const char *nm, struct passwd *p, char *b, size_t n, struct passwd **r) { (void)nm; (void)b; (void)n; *p = webUser; *r = p; return 0; }
static struct group webGroup = { (char *)"web", (char *)"x", 1000, 0 };
struct group *getgrgid(gid_t g) { (void)g; return &webGroup; }
struct group *getgrnam(const char *n) { (void)n; return &webGroup; }

int posix_fadvise(int fd, off_t o, off_t n, int a) { (void)fd; (void)o; (void)n; (void)a; return 0; }
int posix_fallocate(int fd, off_t o, off_t n) {
  struct stat s;
  if (fstat(fd, &s)) return errno;
  if (s.st_size < o + n && ftruncate(fd, o + n)) return errno;
  return 0;
}

/* (what the compiler calls for 128-bit products: the low 128 bits) */
typedef struct { uint64_t lo, hi; } U128;

static U128 mul64(uint64_t a, uint64_t b) {
  uint64_t a0 = (uint32_t)a, a1 = a >> 32, b0 = (uint32_t)b, b1 = b >> 32;
  uint64_t p00 = a0 * b0, p01 = a0 * b1, p10 = a1 * b0, p11 = a1 * b1;
  uint64_t mid = (p00 >> 32) + (uint32_t)p01 + (uint32_t)p10;
  U128 r;
  r.lo = (mid << 32) | (uint32_t)p00;
  r.hi = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
  return r;
}

__int128 __multi3(__int128 a, __int128 b) {
  uint64_t al = (uint64_t)a, ah = (uint64_t)((unsigned __int128)a >> 64);
  uint64_t bl = (uint64_t)b, bh = (uint64_t)((unsigned __int128)b >> 64);
  U128 r = mul64(al, bl);
  r.hi += al * bh + ah * bl;
  return (__int128)(((unsigned __int128)r.hi << 64) | r.lo);
}

/* ---- character sets (iconv): to UTF-8 by the browser's TextDecoder; from
   UTF-8 to Latin-1 and ASCII here. A conversion is done whole: when the
   output does not fit it says E2BIG and takes nothing (the caller grows it
   and asks again, as Nim's std/encodings does). ---- */

RL_IMPORT(rl_charset) int rl_charset(const char *name);
RL_IMPORT(rl_decode) int rl_decode(const char *from, const char *in, int inLen, char *out, int outCap);

typedef struct { char from[40]; int kind; } RlIconv;   /* kind 0: to UTF-8 (the browser); 1: Latin-1; 2: ASCII */

static int sameName(const char *a, const char *b) {
  for (;; a++, b++) {
    while (*a == '-' || *a == '_') a++;
    while (*b == '-' || *b == '_') b++;
    int x = *a >= 'A' && *a <= 'Z' ? *a + 32 : *a, y = *b >= 'A' && *b <= 'Z' ? *b + 32 : *b;
    if (x != y) return 0;
    if (!x) return 1;
  }
}

iconv_t iconv_open(const char *to, const char *from) {
  RlIconv *c = calloc(1, sizeof *c);
  if (!c) { errno = ENOMEM; return (iconv_t)-1; }
  size_t n = strlen(from);
  if (n >= sizeof c->from) { free(c); errno = EINVAL; return (iconv_t)-1; }
  memcpy(c->from, from, n + 1);
  if (sameName(to, "UTF8")) {
    if (!rl_charset(from)) { free(c); errno = EINVAL; return (iconv_t)-1; }
    c->kind = 0;
  } else if (sameName(from, "UTF8") && (sameName(to, "ISO88591") || sameName(to, "LATIN1"))) c->kind = 1;
  else if (sameName(from, "UTF8") && (sameName(to, "ASCII") || sameName(to, "USASCII"))) c->kind = 2;
  else { free(c); errno = EINVAL; return (iconv_t)-1; }
  return c;
}

size_t iconv(iconv_t cd, char **restrict in, size_t *restrict inLeft, char **restrict out, size_t *restrict outLeft) {
  RlIconv *c = cd;
  if (!in || !*in || !inLeft) return 0;            /* (a flush: nothing kept) */
  if (c->kind == 0) {
    int r = rl_decode(c->from, *in, (int)*inLeft, *out, (int)*outLeft);
    if (r < 0) { errno = E2BIG; return (size_t)-1; }
    *in += *inLeft;
    *inLeft = 0;
    *out += r;
    *outLeft -= (size_t)r;
    return 0;
  }
  /* UTF-8 to one byte a character: what does not fit is '?' */
  const unsigned char *s = (const unsigned char *)*in, *e = s + *inLeft;
  size_t need = 0;
  for (const unsigned char *p = s; p < e; p++) if ((*p & 0xC0) != 0x80) need++;
  if (need > *outLeft) { errno = E2BIG; return (size_t)-1; }
  size_t odd = 0;
  unsigned char *o = (unsigned char *)*out;
  while (s < e) {
    unsigned cp = *s++;
    if (cp >= 0xC0) {
      int more = cp >= 0xF0 ? 3 : cp >= 0xE0 ? 2 : 1;
      cp &= 0x3F >> more;
      while (more-- && s < e && (*s & 0xC0) == 0x80) cp = (cp << 6) | (*s++ & 0x3F);
    }
    unsigned lim = c->kind == 1 ? 0xFF : 0x7F;
    if (cp > lim) { cp = '?'; odd++; }
    *o++ = (unsigned char)cp;
  }
  *outLeft -= (size_t)((char *)o - *out);
  *out = (char *)o;
  *in += *inLeft;
  *inLeft = 0;
  return odd;
}

int iconv_close(iconv_t cd) { free(cd); return 0; }

int *__errno_location(void) { return &errno; }

