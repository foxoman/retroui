#ifndef _RL_LIMITS_H
#define _RL_LIMITS_H
#include_next <limits.h>
#ifndef PATH_MAX
#define PATH_MAX 4096
#endif
#ifndef NAME_MAX
#define NAME_MAX 255
#endif
#ifndef IOV_MAX
#define IOV_MAX 1024
#endif
#ifndef SSIZE_MAX
#define SSIZE_MAX LONG_MAX
#endif
#ifndef PIPE_BUF
#define PIPE_BUF 4096
#endif
#endif
