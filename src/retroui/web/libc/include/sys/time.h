#ifndef _RL_SYS_TIME_H
#define _RL_SYS_TIME_H
#include <time.h>
RL_BEGIN
struct timeval { time_t tv_sec; suseconds_t tv_usec; };
struct timezone { int tz_minuteswest, tz_dsttime; };
struct itimerval { struct timeval it_interval, it_value; };
int gettimeofday(struct timeval *restrict tv, void *restrict tz);
int settimeofday(const struct timeval *tv, const struct timezone *tz);
int utimes(const char *p, const struct timeval t[2]);
RL_END
#endif
