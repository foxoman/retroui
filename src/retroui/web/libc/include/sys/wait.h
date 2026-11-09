#ifndef _RL_SYS_WAIT_H
#define _RL_SYS_WAIT_H
#include "../_rl.h"
#include <sys/types.h>
RL_BEGIN
#define WNOHANG 1
#define WUNTRACED 2
#define WEXITSTATUS(s) (((s) & 0xff00) >> 8)
#define WTERMSIG(s) ((s) & 0x7f)
#define WIFEXITED(s) (!WTERMSIG(s))
#define WIFSIGNALED(s) (((s) & 0xffff) - 1u < 0xffu)
#define WIFSTOPPED(s) ((short)((((s) & 0xffff) * 0x10001u) >> 8) > 0x7f00)
pid_t wait(int *s);
pid_t waitpid(pid_t p, int *s, int o);
RL_END
#endif
