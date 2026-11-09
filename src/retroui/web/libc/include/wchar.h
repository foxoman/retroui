#ifndef _RL_WCHAR_H
#define _RL_WCHAR_H
#include "_rl.h"
RL_BEGIN
typedef unsigned int wint_t;
typedef struct { unsigned count, wc; } mbstate_t;
#define WEOF 0xffffffffu
size_t wcslen(const wchar_t *s);
size_t mbrtowc(wchar_t *restrict w, const char *restrict s, size_t n, mbstate_t *restrict st);
size_t wcrtomb(char *restrict s, wchar_t w, mbstate_t *restrict st);
int mbsinit(const mbstate_t *st);
RL_END
#endif
