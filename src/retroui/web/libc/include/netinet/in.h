#ifndef _RL_NETINET_IN_H
#define _RL_NETINET_IN_H
#include <sys/socket.h>
#include <stdint.h>
RL_BEGIN
typedef uint16_t in_port_t;
typedef uint32_t in_addr_t;
struct in_addr { in_addr_t s_addr; };
struct sockaddr_in { sa_family_t sin_family; in_port_t sin_port; struct in_addr sin_addr; unsigned char sin_zero[8]; };
struct in6_addr { union { uint8_t __s6_addr[16]; uint16_t __s6_addr16[8]; uint32_t __s6_addr32[4]; } __in6_union; };
#define s6_addr __in6_union.__s6_addr
struct sockaddr_in6 { sa_family_t sin6_family; in_port_t sin6_port; uint32_t sin6_flowinfo; struct in6_addr sin6_addr; uint32_t sin6_scope_id; };
struct ipv6_mreq { struct in6_addr ipv6mr_multiaddr; unsigned ipv6mr_interface; };
struct ip_mreq { struct in_addr imr_multiaddr, imr_interface; };
extern const struct in6_addr in6addr_any, in6addr_loopback;
#define INADDR_ANY ((in_addr_t)0)
#define INADDR_BROADCAST ((in_addr_t)0xffffffff)
#define INADDR_NONE ((in_addr_t)0xffffffff)
#define INADDR_LOOPBACK ((in_addr_t)0x7f000001)
#define INET_ADDRSTRLEN 16
#define INET6_ADDRSTRLEN 46
#define IPPROTO_IP 0
#define IPPROTO_ICMP 1
#define IPPROTO_TCP 6
#define IPPROTO_UDP 17
#define IPPROTO_IPV6 41
#define IPPROTO_RAW 255
#define IPV6_V6ONLY 26
#define IPV6_JOIN_GROUP 20
#define IPV6_LEAVE_GROUP 21
#define IP_ADD_MEMBERSHIP 35
#define IP_DROP_MEMBERSHIP 36
#define IP_MULTICAST_TTL 33
#define IP_TTL 2
uint16_t htons(uint16_t x);
uint16_t ntohs(uint16_t x);
uint32_t htonl(uint32_t x);
uint32_t ntohl(uint32_t x);
RL_END
#endif
