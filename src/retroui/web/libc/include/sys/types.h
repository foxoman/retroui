#ifndef _RL_SYS_TYPES_H
#define _RL_SYS_TYPES_H
#include "../_rl.h"
typedef long ssize_t;
typedef long long off_t;
typedef long long off64_t;
typedef int pid_t;
typedef unsigned int uid_t;
typedef unsigned int gid_t;
typedef unsigned int mode_t;
typedef unsigned long long dev_t;
typedef unsigned long long ino_t;
typedef unsigned long nlink_t;
typedef long blksize_t;
typedef long long blkcnt_t;
typedef long long time_t;
typedef long suseconds_t;
typedef unsigned int useconds_t;
typedef int clockid_t;
typedef unsigned long fsblkcnt_t;
typedef unsigned long fsfilcnt_t;
typedef int id_t;
typedef int key_t;
typedef char *caddr_t;
typedef unsigned char u_char;
typedef unsigned short u_short;
typedef unsigned int u_int;
typedef unsigned long u_long;
/* threads' types (<pthread.h> has what uses them) */
typedef unsigned long pthread_t;
typedef struct { int kind, locked; unsigned long owner; int count; } pthread_mutex_t;
typedef struct { int kind; } pthread_mutexattr_t;
typedef struct { int seq, clock; } pthread_cond_t;
typedef struct { int clock; } pthread_condattr_t;
typedef struct { size_t stacksize; int detach; } pthread_attr_t;
typedef unsigned pthread_key_t;
typedef int pthread_once_t;
typedef struct { pthread_mutex_t m; int readers, writer; } pthread_rwlock_t;
typedef struct { int kind; } pthread_rwlockattr_t;
typedef struct { int count; } pthread_barrier_t;
typedef struct { int pshared; } pthread_barrierattr_t;
typedef int pthread_spinlock_t;
#endif
