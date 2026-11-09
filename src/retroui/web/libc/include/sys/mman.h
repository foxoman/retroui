#ifndef _RL_SYS_MMAN_H
#define _RL_SYS_MMAN_H
#include "../_rl.h"
#include <sys/types.h>
RL_BEGIN
#define PROT_NONE 0
#define PROT_READ 1
#define PROT_WRITE 2
#define PROT_EXEC 4
#define MAP_SHARED 0x01
#define MAP_PRIVATE 0x02
#define MAP_FIXED 0x10
#define MAP_ANONYMOUS 0x20
#define MAP_ANON MAP_ANONYMOUS
#define MAP_NORESERVE 0x4000
#define MAP_POPULATE 0x8000
#define MAP_FAILED ((void *)-1)
#define MADV_NORMAL 0
#define MADV_DONTNEED 4
#define MS_ASYNC 1
#define MS_SYNC 4
#define MFD_CLOEXEC 1
void *mmap(void *a, size_t n, int prot, int flags, int fd, off_t o);
int munmap(void *a, size_t n);
int mprotect(void *a, size_t n, int prot);
int madvise(void *a, size_t n, int adv);
int msync(void *a, size_t n, int f);
int mlock(const void *a, size_t n);
int munlock(const void *a, size_t n);
int memfd_create(const char *n, unsigned f);
int shm_open(const char *n, int f, mode_t m);
int shm_unlink(const char *n);
RL_END
#endif
