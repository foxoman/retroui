#ifndef _RL_MALLOC_H
#define _RL_MALLOC_H
#include <stdlib.h>
RL_BEGIN
size_t malloc_usable_size(void *p);
int malloc_trim(size_t pad);
int mallopt(int p, int v);
#define M_TRIM_THRESHOLD -1
#define M_MMAP_THRESHOLD -3
#define M_ARENA_MAX -8
RL_END
#endif
