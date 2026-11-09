#ifndef _RL_NET_IF_H
#define _RL_NET_IF_H
#include "../_rl.h"
#define IF_NAMESIZE 16
RL_BEGIN
unsigned if_nametoindex(const char *n);
char *if_indextoname(unsigned i, char *n);
RL_END
#endif
