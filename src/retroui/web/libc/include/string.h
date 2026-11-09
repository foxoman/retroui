#ifndef _RL_STRING_H
#define _RL_STRING_H
#include "_rl.h"
RL_BEGIN
void *memcpy(void *restrict d, const void *restrict s, size_t n);
void *memmove(void *d, const void *s, size_t n);
void *memset(void *d, int c, size_t n);
int memcmp(const void *a, const void *b, size_t n);
void *memchr(const void *s, int c, size_t n);
void *memrchr(const void *s, int c, size_t n);
void *memmem(const void *h, size_t hn, const void *n, size_t nn);
size_t strlen(const char *s);
size_t strnlen(const char *s, size_t n);
char *strcpy(char *restrict d, const char *restrict s);
char *strncpy(char *restrict d, const char *restrict s, size_t n);
char *strcat(char *restrict d, const char *restrict s);
char *strncat(char *restrict d, const char *restrict s, size_t n);
int strcmp(const char *a, const char *b);
int strncmp(const char *a, const char *b, size_t n);
int strcoll(const char *a, const char *b);
char *strchr(const char *s, int c);
char *strrchr(const char *s, int c);
char *strstr(const char *h, const char *n);
size_t strspn(const char *s, const char *a);
size_t strcspn(const char *s, const char *r);
char *strpbrk(const char *s, const char *a);
char *strtok(char *restrict s, const char *restrict d);
char *strtok_r(char *restrict s, const char *restrict d, char **restrict p);
char *strdup(const char *s);
char *strndup(const char *s, size_t n);
char *strerror(int e);
int strerror_r(int e, char *buf, size_t n);
size_t strlcpy(char *d, const char *s, size_t n);
int strcasecmp(const char *a, const char *b);
int strncasecmp(const char *a, const char *b, size_t n);
char *strsignal(int sig);
RL_END
#endif
