#ifndef _RL_PWD_H
#define _RL_PWD_H
#include "_rl.h"
#include <sys/types.h>
RL_BEGIN
struct passwd { char *pw_name, *pw_passwd; uid_t pw_uid; gid_t pw_gid; char *pw_gecos, *pw_dir, *pw_shell; };
struct passwd *getpwuid(uid_t u);
struct passwd *getpwnam(const char *n);
int getpwuid_r(uid_t u, struct passwd *p, char *b, size_t n, struct passwd **r);
int getpwnam_r(const char *nm, struct passwd *p, char *b, size_t n, struct passwd **r);
RL_END
#endif
