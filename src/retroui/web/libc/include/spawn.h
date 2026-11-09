#ifndef _RL_SPAWN_H
#define _RL_SPAWN_H
#include "_rl.h"
#include <sys/types.h>
#include <signal.h>
RL_BEGIN
typedef struct { int flags; } posix_spawnattr_t;
typedef struct { int n; } posix_spawn_file_actions_t;
#define POSIX_SPAWN_RESETIDS 1
#define POSIX_SPAWN_SETPGROUP 2
#define POSIX_SPAWN_SETSIGDEF 4
#define POSIX_SPAWN_SETSIGMASK 8
#define POSIX_SPAWN_USEVFORK 64
int posix_spawn(pid_t *restrict p, const char *restrict path, const posix_spawn_file_actions_t *a,
                const posix_spawnattr_t *restrict at, char *const argv[restrict], char *const envp[restrict]);
int posix_spawnp(pid_t *restrict p, const char *restrict path, const posix_spawn_file_actions_t *a,
                 const posix_spawnattr_t *restrict at, char *const argv[restrict], char *const envp[restrict]);
int posix_spawnattr_init(posix_spawnattr_t *a);
int posix_spawnattr_destroy(posix_spawnattr_t *a);
int posix_spawnattr_setflags(posix_spawnattr_t *a, short f);
int posix_spawnattr_setpgroup(posix_spawnattr_t *a, pid_t g);
int posix_spawnattr_setsigmask(posix_spawnattr_t *restrict a, const sigset_t *restrict m);
int posix_spawn_file_actions_init(posix_spawn_file_actions_t *a);
int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *a);
int posix_spawn_file_actions_addclose(posix_spawn_file_actions_t *a, int fd);
int posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *a, int fd, int nfd);
RL_END
#endif
