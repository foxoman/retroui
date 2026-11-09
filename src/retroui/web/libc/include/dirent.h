#ifndef _RL_DIRENT_H
#define _RL_DIRENT_H
#include "_rl.h"
#include <sys/types.h>
RL_BEGIN
#define DT_UNKNOWN 0
#define DT_FIFO 1
#define DT_CHR 2
#define DT_DIR 4
#define DT_BLK 6
#define DT_REG 8
#define DT_LNK 10
#define DT_SOCK 12
typedef struct _RlDir DIR;
struct dirent {
  ino_t d_ino;
  off_t d_off;
  unsigned short d_reclen;
  unsigned char d_type;
  char d_name[256];
};
DIR *opendir(const char *p);
DIR *fdopendir(int fd);
struct dirent *readdir(DIR *d);
int readdir_r(DIR *restrict d, struct dirent *restrict e, struct dirent **restrict r);
int closedir(DIR *d);
void rewinddir(DIR *d);
int dirfd(DIR *d);
RL_END
#endif
