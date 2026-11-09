#ifndef _RL_LOCALE_H
#define _RL_LOCALE_H
#include "_rl.h"
RL_BEGIN
#define LC_CTYPE 0
#define LC_NUMERIC 1
#define LC_TIME 2
#define LC_COLLATE 3
#define LC_MONETARY 4
#define LC_MESSAGES 5
#define LC_ALL 6
struct lconv { char *decimal_point, *thousands_sep, *grouping, *int_curr_symbol, *currency_symbol,
  *mon_decimal_point, *mon_thousands_sep, *mon_grouping, *positive_sign, *negative_sign; };
char *setlocale(int c, const char *l);
struct lconv *localeconv(void);
RL_END
#endif
