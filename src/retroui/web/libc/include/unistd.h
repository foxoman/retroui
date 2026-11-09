#ifndef _RL_UNISTD_H
#define _RL_UNISTD_H
#include "_rl.h"
#include <sys/types.h>
RL_BEGIN
#define STDIN_FILENO 0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2
#define F_OK 0
#define X_OK 1
#define W_OK 2
#define R_OK 4
#ifndef SEEK_SET
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#endif
#define _SC_PAGESIZE 30
#define _SC_PAGE_SIZE 30
#define _SC_NPROCESSORS_CONF 83
#define _SC_NPROCESSORS_ONLN 84
#define _SC_CLK_TCK 2
#define _SC_OPEN_MAX 4
#define _SC_PHYS_PAGES 85
#define _SC_HOST_NAME_MAX 180
#define _SC_GETPW_R_SIZE_MAX 70
#define _PC_PATH_MAX 4
#define _PC_NAME_MAX 3
extern char **environ;
ssize_t read(int fd, void *b, size_t n);
ssize_t write(int fd, const void *b, size_t n);
ssize_t pread(int fd, void *b, size_t n, off_t o);
ssize_t pwrite(int fd, const void *b, size_t n, off_t o);
int close(int fd);
off_t lseek(int fd, off_t o, int w);
int unlink(const char *p);
int rmdir(const char *p);
int link(const char *a, const char *b);
int symlink(const char *a, const char *b);
ssize_t readlink(const char *restrict p, char *restrict b, size_t n);
int access(const char *p, int m);
int faccessat(int d, const char *p, int m, int f);
int chdir(const char *p);
int fchdir(int fd);
char *getcwd(char *b, size_t n);
int dup(int fd);
int dup2(int a, int b);
int pipe(int fds[2]);
int pipe2(int fds[2], int f);
int isatty(int fd);
int fsync(int fd);
int fdatasync(int fd);
int ftruncate(int fd, off_t n);
int truncate(const char *p, off_t n);
unsigned sleep(unsigned s);
int usleep(useconds_t u);
pid_t getpid(void);
pid_t getppid(void);
pid_t fork(void);
pid_t vfork(void);
pid_t setsid(void);
int setpgid(pid_t p, pid_t g);
pid_t getpgrp(void);
uid_t getuid(void);
uid_t geteuid(void);
gid_t getgid(void);
gid_t getegid(void);
int setuid(uid_t u);
int setgid(gid_t g);
int execv(const char *p, char *const a[]);
int execve(const char *p, char *const a[], char *const e[]);
int execvp(const char *p, char *const a[]);
_Noreturn void _exit(int code);
long sysconf(int n);
long pathconf(const char *p, int n);
long fpathconf(int fd, int n);
int gethostname(char *n, size_t l);
char *getlogin(void);
int getlogin_r(char *b, size_t n);
int chown(const char *p, uid_t u, gid_t g);
int lchown(const char *p, uid_t u, gid_t g);
int fchown(int fd, uid_t u, gid_t g);
int getpagesize(void);
int getentropy(void *b, size_t n);
char *ttyname(int fd);
unsigned alarm(unsigned s);
int nice(int n);
RL_END
#endif
