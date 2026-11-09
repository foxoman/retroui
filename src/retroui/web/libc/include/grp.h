#ifndef _RL_GRP_H
#define _RL_GRP_H
#include "_rl.h"
#include <sys/types.h>
RL_BEGIN
struct group { char *gr_name, *gr_passwd; gid_t gr_gid; char **gr_mem; };
struct group *getgrgid(gid_t g);
struct group *getgrnam(const char *n);
RL_END
#endif
