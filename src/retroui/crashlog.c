/* A crash of the app's own code written down (Android apps): the signal,
 * the address, and the code addresses on the way there, each as a library
 * and an offset in it -- into the app's fault log, which the next start
 * shows (retroui's "stopped" screen). Android's runtime keeps its own
 * signals first (Java's null checks, its stack checks): only what it does
 * not handle reaches here, and after the note the signal goes on to the
 * handler that was there before (the system's crash report).
 *
 * Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net */

#define _GNU_SOURCE
#include <signal.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdint.h>
#include <ucontext.h>

static char logPath[1024];
static struct sigaction before[32];
static const int caught[] = { SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT };
static volatile sig_atomic_t inside = 0;

static void put(int fd, const char *s) { if (s) (void)!write(fd, s, strlen(s)); }

static void putHex(int fd, uintptr_t v) {
  char b[2 + 2 * sizeof v + 1];
  int n = sizeof b - 1;
  b[n] = 0;
  do { b[--n] = "0123456789abcdef"[v & 15]; v >>= 4; } while (v && n > 2);
  b[--n] = 'x'; b[--n] = '0';
  put(fd, b + n);
}

static void putDec(int fd, long v) {
  char b[24];
  int n = sizeof b - 1;
  b[n] = 0;
  int neg = v < 0;
  unsigned long u = neg ? -(unsigned long)v : (unsigned long)v;
  do { b[--n] = (char)('0' + u % 10); u /= 10; } while (u && n > 1);
  if (neg) b[--n] = '-';
  put(fd, b + n);
}

static const char *nameOf(int sig) {
  switch (sig) {
    case SIGSEGV: return "SIGSEGV: memory that is not the program's";
    case SIGBUS: return "SIGBUS: memory that cannot be reached";
    case SIGFPE: return "SIGFPE: arithmetic (a division by zero)";
    case SIGILL: return "SIGILL: an instruction this processor does not have";
    case SIGABRT: return "SIGABRT: the program was aborted";
    default: return "a signal";
  }
}

static void frame(int fd, int i, uintptr_t pc) {
  put(fd, "  #"); if (i < 10) put(fd, "0"); putDec(fd, i); put(fd, " "); putHex(fd, pc);
  Dl_info info;
  if (pc && dladdr((void *)pc, &info) && info.dli_fname) {
    const char *f = strrchr(info.dli_fname, '/');
    put(fd, " "); put(fd, f ? f + 1 : info.dli_fname);
    put(fd, "+"); putHex(fd, pc - (uintptr_t)info.dli_fbase);
    if (info.dli_sname) {
      put(fd, " ("); put(fd, info.dli_sname);
      put(fd, "+"); putHex(fd, pc - (uintptr_t)info.dli_saddr); put(fd, ")");
    }
  }
  put(fd, "\n");
}

static void caughtSignal(int sig, siginfo_t *si, void *ctx) {
  if (!inside && logPath[0]) {
    inside = 1;
    int fd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd >= 0) {
      put(fd, "--- the app stopped\n");
      put(fd, nameOf(sig)); put(fd, " (signal "); putDec(fd, sig); put(fd, ")");
      if (sig != SIGABRT) { put(fd, " at address "); putHex(fd, (uintptr_t)si->si_addr); }
      put(fd, "\n");
      ucontext_t *uc = (ucontext_t *)ctx;
      uintptr_t pc = 0, lr = 0, fp = 0, sp = 0;
#if defined(__aarch64__)
      pc = uc->uc_mcontext.pc; lr = uc->uc_mcontext.regs[30];
      fp = uc->uc_mcontext.regs[29]; sp = uc->uc_mcontext.sp;
#elif defined(__x86_64__)
      pc = uc->uc_mcontext.gregs[REG_RIP]; fp = uc->uc_mcontext.gregs[REG_RBP];
      sp = uc->uc_mcontext.gregs[REG_RSP];
#elif defined(__arm__)
      pc = uc->uc_mcontext.arm_pc; lr = uc->uc_mcontext.arm_lr; fp = uc->uc_mcontext.arm_fp;
      sp = uc->uc_mcontext.arm_sp;
#elif defined(__i386__)
      pc = uc->uc_mcontext.gregs[REG_EIP]; fp = uc->uc_mcontext.gregs[REG_EBP];
      sp = uc->uc_mcontext.gregs[REG_ESP];
#endif
      int n = 0;
      frame(fd, n++, pc);
      if (lr) frame(fd, n++, lr);
      /* (the frame pointers' chain, while it looks like one: on the stack,
       * aligned, going up) */
      while (n < 32 && fp && (fp & (sizeof(void *) - 1)) == 0 && fp >= sp && fp - sp < (1u << 20)) {
        uintptr_t next = ((uintptr_t *)fp)[0];
        uintptr_t ret = ((uintptr_t *)fp)[1];
        if (!ret) break;
        frame(fd, n++, ret);
        if (next <= fp) break;
        fp = next;
      }
      close(fd);
    }
  }
  /* on to the handler that was there (the system's report), as if never here */
  sigaction(sig, &before[sig], NULL);
  if (sig == SIGABRT) raise(sig);
}

void retro_crash_log(const char *path) {
  size_t n = strlen(path);
  if (n >= sizeof logPath) return;
  memcpy(logPath, path, n + 1);
  for (size_t i = 0; i < sizeof caught / sizeof caught[0]; i++) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = caughtSignal;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    sigaction(caught[i], &sa, &before[caught[i]]);
  }
}
