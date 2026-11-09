#ifndef _RL_STDLIB_H
#define _RL_STDLIB_H
#include "_rl.h"
RL_BEGIN
#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1
#define RAND_MAX 0x7fffffff
#define MB_CUR_MAX 4
typedef struct { int quot, rem; } div_t;
typedef struct { long quot, rem; } ldiv_t;
typedef struct { long long quot, rem; } lldiv_t;
void *malloc(size_t n);
void *calloc(size_t n, size_t m);
void *realloc(void *p, size_t n);
void *aligned_alloc(size_t a, size_t n);
int posix_memalign(void **p, size_t a, size_t n);
void free(void *p);
_Noreturn void abort(void);
_Noreturn void exit(int code);
_Noreturn void _Exit(int code);
int atexit(void (*f)(void));
char *getenv(const char *name);
int setenv(const char *name, const char *value, int overwrite);
int unsetenv(const char *name);
int putenv(char *s);
int clearenv(void);
int atoi(const char *s);
long atol(const char *s);
long long atoll(const char *s);
double atof(const char *s);
long strtol(const char *restrict s, char **restrict e, int base);
unsigned long strtoul(const char *restrict s, char **restrict e, int base);
long long strtoll(const char *restrict s, char **restrict e, int base);
unsigned long long strtoull(const char *restrict s, char **restrict e, int base);
double strtod(const char *restrict s, char **restrict e);
float strtof(const char *restrict s, char **restrict e);
int abs(int x);
long labs(long x);
long long llabs(long long x);
div_t div(int a, int b);
ldiv_t ldiv(long a, long b);
lldiv_t lldiv(long long a, long long b);
int rand(void);
void srand(unsigned s);
long random(void);
void srandom(unsigned s);
void qsort(void *b, size_t n, size_t w, int (*cmp)(const void *, const void *));
void *bsearch(const void *k, const void *b, size_t n, size_t w, int (*cmp)(const void *, const void *));
int system(const char *cmd);
char *realpath(const char *restrict p, char *restrict out);
int mkstemp(char *t);
char *mkdtemp(char *t);
char *mktemp(char *t);
int mblen(const char *s, size_t n);
int getloadavg(double *l, int n);
RL_END
#endif
