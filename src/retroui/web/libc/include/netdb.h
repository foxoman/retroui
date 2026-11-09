#ifndef _RL_NETDB_H
#define _RL_NETDB_H
#include <netinet/in.h>
RL_BEGIN
struct addrinfo { int ai_flags, ai_family, ai_socktype, ai_protocol; socklen_t ai_addrlen;
  struct sockaddr *ai_addr; char *ai_canonname; struct addrinfo *ai_next; };
struct hostent { char *h_name; char **h_aliases; int h_addrtype, h_length; char **h_addr_list; };
struct servent { char *s_name; char **s_aliases; int s_port; char *s_proto; };
struct protoent { char *p_name; char **p_aliases; int p_proto; };
#define h_addr h_addr_list[0]
#define AI_PASSIVE 0x01
#define AI_CANONNAME 0x02
#define AI_NUMERICHOST 0x04
#define AI_V4MAPPED 0x08
#define AI_ALL 0x10
#define AI_ADDRCONFIG 0x20
#define AI_NUMERICSERV 0x400
#define NI_NUMERICHOST 0x01
#define NI_NUMERICSERV 0x02
#define NI_NOFQDN 0x04
#define NI_NAMEREQD 0x08
#define NI_DGRAM 0x10
#define NI_MAXHOST 255
#define NI_MAXSERV 32
#define EAI_AGAIN -3
#define EAI_FAIL -4
#define EAI_FAMILY -6
#define EAI_MEMORY -10
#define EAI_NONAME -2
#define EAI_SERVICE -8
#define EAI_SOCKTYPE -7
#define EAI_SYSTEM -11
int getaddrinfo(const char *restrict h, const char *restrict s, const struct addrinfo *restrict hint, struct addrinfo **restrict r);
void freeaddrinfo(struct addrinfo *a);
const char *gai_strerror(int e);
int getnameinfo(const struct sockaddr *restrict a, socklen_t l, char *restrict h, socklen_t hl, char *restrict s, socklen_t sl, int f);
struct hostent *gethostbyname(const char *n);
struct hostent *gethostbyaddr(const void *a, socklen_t l, int t);
struct servent *getservbyname(const char *n, const char *p);
struct servent *getservbyport(int port, const char *p);
struct protoent *getprotobyname(const char *n);
RL_END
#endif
