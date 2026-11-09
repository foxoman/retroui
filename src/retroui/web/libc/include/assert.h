#ifndef _RL_ASSERT_H
#define _RL_ASSERT_H
#include "_rl.h"
RL_BEGIN
_Noreturn void __rl_assert_fail(const char *e, const char *f, int l);
RL_END
#ifdef NDEBUG
#define assert(x) ((void)0)
#else
#define assert(x) ((x) ? (void)0 : __rl_assert_fail(#x, __FILE__, __LINE__))
#endif
#define static_assert _Static_assert
#endif
