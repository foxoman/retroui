#ifndef _RL_FCNTL_H
#define _RL_FCNTL_H
#include "_rl.h"
#include <sys/types.h>
RL_BEGIN
#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR 2
#define O_ACCMODE 3
#define O_CREAT 0100
#define O_EXCL 0200
#define O_NOCTTY 0400
#define O_TRUNC 01000
#define O_APPEND 02000
#define O_NONBLOCK 04000
#define O_DSYNC 010000
#define O_SYNC 04010000
#define O_DIRECTORY 0200000
#define O_NOFOLLOW 0400000
#define O_CLOEXEC 02000000
#define O_CLOFORK 0
#define O_LARGEFILE 0
#define O_NDELAY O_NONBLOCK
#define F_DUPFD 0
#define F_GETFD 1
#define F_SETFD 2
#define F_GETFL 3
#define F_SETFL 4
#define F_GETLK 5
#define F_SETLK 6
#define F_SETLKW 7
#define F_DUPFD_CLOEXEC 1030
#define FD_CLOEXEC 1
#define F_RDLCK 0
#define F_WRLCK 1
#define F_UNLCK 2
#define AT_FDCWD (-100)
#define AT_SYMLINK_NOFOLLOW 0x100
#define AT_REMOVEDIR 0x200
#define AT_SYMLINK_FOLLOW 0x400
#define POSIX_FADV_NORMAL 0
#define POSIX_FADV_SEQUENTIAL 2
#define POSIX_FADV_DONTNEED 4
struct flock { short l_type, l_whence; off_t l_start, l_len; pid_t l_pid; };
int open(const char *p, int f, ...);
int openat(int d, const char *p, int f, ...);
int creat(const char *p, mode_t m);
int fcntl(int fd, int cmd, ...);
int posix_fadvise(int fd, off_t o, off_t n, int a);
int posix_fallocate(int fd, off_t o, off_t n);
RL_END
#endif
