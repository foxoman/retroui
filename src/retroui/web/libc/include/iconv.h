#ifndef _RL_ICONV_H
#define _RL_ICONV_H
/* Character sets turned into UTF-8 by the browser (TextDecoder: every
   encoding the web knows), and UTF-8 into Latin-1 or ASCII here. */
#include "_rl.h"
RL_BEGIN
typedef void *iconv_t;
iconv_t iconv_open(const char *to, const char *from);
size_t iconv(iconv_t cd, char **restrict in, size_t *restrict inLeft, char **restrict out, size_t *restrict outLeft);
int iconv_close(iconv_t cd);
RL_END
#endif
