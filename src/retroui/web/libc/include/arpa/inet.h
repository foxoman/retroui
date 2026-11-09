#ifndef _RL_ARPA_INET_H
#define _RL_ARPA_INET_H
#include <netinet/in.h>
RL_BEGIN
in_addr_t inet_addr(const char *s);
int inet_aton(const char *s, struct in_addr *a);
char *inet_ntoa(struct in_addr a);
int inet_pton(int af, const char *restrict s, void *restrict d);
const char *inet_ntop(int af, const void *restrict s, char *restrict d, socklen_t n);
RL_END
#endif
