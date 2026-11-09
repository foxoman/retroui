#ifndef _RL_SIGNAL_H
#define _RL_SIGNAL_H
#include "_rl.h"
#include <sys/types.h>
#include <time.h>
RL_BEGIN
typedef int sig_atomic_t;
typedef unsigned long long sigset_t;
typedef void (*sighandler_t)(int);
#define SIG_DFL ((sighandler_t)0)
#define SIG_IGN ((sighandler_t)1)
#define SIG_ERR ((sighandler_t)-1)
#define SIGHUP 1
#define SIGINT 2
#define SIGQUIT 3
#define SIGILL 4
#define SIGTRAP 5
#define SIGABRT 6
#define SIGBUS 7
#define SIGFPE 8
#define SIGKILL 9
#define SIGUSR1 10
#define SIGSEGV 11
#define SIGUSR2 12
#define SIGPIPE 13
#define SIGALRM 14
#define SIGTERM 15
#define SIGCHLD 17
#define SIGCONT 18
#define SIGSTOP 19
#define SIGTSTP 20
#define SIGTTIN 21
#define SIGTTOU 22
#define SIGWINCH 28
#define SIGSYS 31
#define NSIG 65
#define SA_RESTART 0x10000000
#define SA_SIGINFO 4
#define SA_NOCLDSTOP 1
#define SA_ONSTACK 0x08000000
#define SA_RESETHAND 0x80000000
#define SA_NODEFER 0x40000000
#define SIG_BLOCK 0
#define SIG_UNBLOCK 1
#define SIG_SETMASK 2
#define SS_DISABLE 2
#define MINSIGSTKSZ 2048
#define SIGSTKSZ 8192
typedef struct { int si_signo, si_errno, si_code; pid_t si_pid; uid_t si_uid; void *si_addr; int si_status; } siginfo_t;
struct sigaction {
  union { sighandler_t sa_handler; void (*sa_sigaction)(int, siginfo_t *, void *); };
  sigset_t sa_mask;
  int sa_flags;
  void (*sa_restorer)(void);
};
typedef struct { void *ss_sp; int ss_flags; size_t ss_size; } stack_t;
sighandler_t signal(int s, sighandler_t h);
int raise(int s);
int kill(pid_t p, int s);
int sigaction(int s, const struct sigaction *restrict a, struct sigaction *restrict o);
int sigemptyset(sigset_t *s);
int sigfillset(sigset_t *s);
int sigaddset(sigset_t *s, int n);
int sigdelset(sigset_t *s, int n);
int sigismember(const sigset_t *s, int n);
int sigprocmask(int h, const sigset_t *restrict s, sigset_t *restrict o);
int pthread_sigmask(int h, const sigset_t *restrict s, sigset_t *restrict o);
int sigaltstack(const stack_t *restrict s, stack_t *restrict o);
int sigwait(const sigset_t *restrict s, int *restrict n);
RL_END
#endif
