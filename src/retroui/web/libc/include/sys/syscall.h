#ifndef _RL_SYS_SYSCALL_H
#define _RL_SYS_SYSCALL_H
#include "../_rl.h"
RL_BEGIN
#define SYS_gettid 186
#define SYS_getrandom 318
#define __NR_gettid SYS_gettid
#define __NR_getrandom SYS_getrandom
long syscall(long n, ...);
RL_END
#endif
