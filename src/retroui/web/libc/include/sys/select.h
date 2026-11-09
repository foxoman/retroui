#ifndef _RL_SYS_SELECT_H
#define _RL_SYS_SELECT_H
#include "../_rl.h"
#include <sys/time.h>
RL_BEGIN
#define FD_SETSIZE 1024
typedef struct { unsigned long fds_bits[FD_SETSIZE / (8 * sizeof(long))]; } fd_set;
#define FD_ZERO(s) __builtin_memset((s), 0, sizeof(fd_set))
#define FD_SET(d, s) ((s)->fds_bits[(d) / (8 * sizeof(long))] |= 1ul << ((d) % (8 * sizeof(long))))
#define FD_CLR(d, s) ((s)->fds_bits[(d) / (8 * sizeof(long))] &= ~(1ul << ((d) % (8 * sizeof(long)))))
#define FD_ISSET(d, s) (((s)->fds_bits[(d) / (8 * sizeof(long))] >> ((d) % (8 * sizeof(long)))) & 1)
int select(int n, fd_set *restrict r, fd_set *restrict w, fd_set *restrict e, struct timeval *restrict t);
RL_END
#endif
