#ifndef _RL_DLFCN_H
#define _RL_DLFCN_H
#include "_rl.h"
RL_BEGIN
#define RTLD_LAZY 1
#define RTLD_NOW 2
#define RTLD_GLOBAL 0x100
#define RTLD_LOCAL 0
#define RTLD_DEFAULT ((void *)0)
#define RTLD_NEXT ((void *)-1)
void *dlopen(const char *p, int f);
void *dlsym(void *restrict h, const char *restrict n);
int dlclose(void *h);
char *dlerror(void);
RL_END
#endif
