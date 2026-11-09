#ifndef _RL_SYS_STATVFS_H
#define _RL_SYS_STATVFS_H
#include "../_rl.h"
#include <sys/types.h>
RL_BEGIN
struct statvfs { unsigned long f_bsize, f_frsize; fsblkcnt_t f_blocks, f_bfree, f_bavail;
  fsfilcnt_t f_files, f_ffree, f_favail; unsigned long f_fsid, f_flag, f_namemax; };
int statvfs(const char *restrict p, struct statvfs *restrict s);
int fstatvfs(int fd, struct statvfs *s);
RL_END
#endif
