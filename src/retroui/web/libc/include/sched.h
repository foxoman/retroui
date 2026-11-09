#ifndef _RL_SCHED_H
#define _RL_SCHED_H
#include "_rl.h"
RL_BEGIN
struct sched_param { int sched_priority; };
typedef struct { unsigned long long bits[16]; } cpu_set_t;
#define CPU_ZERO(s) __builtin_memset((s), 0, sizeof(cpu_set_t))
#define CPU_SET(i, s) ((s)->bits[(i) / 64] |= 1ull << ((i) % 64))
#define CPU_ISSET(i, s) (((s)->bits[(i) / 64] >> ((i) % 64)) & 1)
#define SCHED_OTHER 0
int sched_yield(void);
int sched_getcpu(void);
RL_END
#endif
