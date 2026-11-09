#ifndef _RL_SYS_SOCKET_H
#define _RL_SYS_SOCKET_H
/* (no sockets in a browser: they say EAFNOSUPPORT; the toolkit fetches
   through the page instead) */
#include "../_rl.h"
#include <sys/types.h>
#include <sys/uio.h>
RL_BEGIN
typedef unsigned socklen_t;
typedef unsigned short sa_family_t;
struct sockaddr { sa_family_t sa_family; char sa_data[14]; };
struct sockaddr_storage { sa_family_t ss_family; char __ss_pad[126]; };
struct msghdr { void *msg_name; socklen_t msg_namelen; struct iovec *msg_iov; int msg_iovlen;
                void *msg_control; socklen_t msg_controllen; int msg_flags; };
struct cmsghdr { socklen_t cmsg_len; int cmsg_level, cmsg_type; };
struct linger { int l_onoff, l_linger; };
#define CMSG_ALIGN(n) (((n) + sizeof(size_t) - 1) & ~(sizeof(size_t) - 1))
#define CMSG_DATA(c) ((unsigned char *)((struct cmsghdr *)(c) + 1))
#define CMSG_FIRSTHDR(m) ((size_t)(m)->msg_controllen >= sizeof(struct cmsghdr) ? (struct cmsghdr *)(m)->msg_control : (struct cmsghdr *)0)
#define CMSG_NXTHDR(m, c) ((struct cmsghdr *)0)
#define CMSG_SPACE(n) (CMSG_ALIGN(n) + CMSG_ALIGN(sizeof(struct cmsghdr)))
#define CMSG_LEN(n) (CMSG_ALIGN(sizeof(struct cmsghdr)) + (n))
#define AF_UNSPEC 0
#define AF_UNIX 1
#define AF_LOCAL 1
#define AF_INET 2
#define AF_INET6 10
#define PF_UNSPEC AF_UNSPEC
#define PF_UNIX AF_UNIX
#define PF_INET AF_INET
#define PF_INET6 AF_INET6
#define SOCK_STREAM 1
#define SOCK_DGRAM 2
#define SOCK_RAW 3
#define SOCK_SEQPACKET 5
#define SOCK_NONBLOCK 04000
#define SOCK_CLOEXEC 02000000
#define SOL_SOCKET 1
#define SO_DEBUG 1
#define SO_REUSEADDR 2
#define SO_TYPE 3
#define SO_ERROR 4
#define SO_DONTROUTE 5
#define SO_BROADCAST 6
#define SO_SNDBUF 7
#define SO_RCVBUF 8
#define SO_KEEPALIVE 9
#define SO_OOBINLINE 10
#define SO_LINGER 13
#define SO_REUSEPORT 15
#define SO_RCVLOWAT 18
#define SO_SNDLOWAT 19
#define SO_RCVTIMEO 20
#define SO_SNDTIMEO 21
#define SO_ACCEPTCONN 30
#define SOMAXCONN 128
#define SCM_RIGHTS 1
#define MSG_OOB 1
#define MSG_PEEK 2
#define MSG_DONTROUTE 4
#define MSG_CTRUNC 8
#define MSG_TRUNC 0x20
#define MSG_DONTWAIT 0x40
#define MSG_EOR 0x80
#define MSG_WAITALL 0x100
#define MSG_NOSIGNAL 0x4000
#define SHUT_RD 0
#define SHUT_WR 1
#define SHUT_RDWR 2
int socket(int d, int t, int p);
int socketpair(int d, int t, int p, int s[2]);
int bind(int s, const struct sockaddr *a, socklen_t l);
int listen(int s, int n);
int accept(int s, struct sockaddr *restrict a, socklen_t *restrict l);
int accept4(int s, struct sockaddr *restrict a, socklen_t *restrict l, int f);
int connect(int s, const struct sockaddr *a, socklen_t l);
int shutdown(int s, int h);
ssize_t send(int s, const void *b, size_t n, int f);
ssize_t recv(int s, void *b, size_t n, int f);
ssize_t sendto(int s, const void *b, size_t n, int f, const struct sockaddr *a, socklen_t l);
ssize_t recvfrom(int s, void *restrict b, size_t n, int f, struct sockaddr *restrict a, socklen_t *restrict l);
ssize_t sendmsg(int s, const struct msghdr *m, int f);
ssize_t recvmsg(int s, struct msghdr *m, int f);
int getsockopt(int s, int lv, int n, void *restrict v, socklen_t *restrict l);
int setsockopt(int s, int lv, int n, const void *v, socklen_t l);
int getsockname(int s, struct sockaddr *restrict a, socklen_t *restrict l);
int getpeername(int s, struct sockaddr *restrict a, socklen_t *restrict l);
RL_END
#endif
