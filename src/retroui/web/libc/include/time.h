#ifndef _RL_TIME_H
#define _RL_TIME_H
#include "_rl.h"
#include <sys/types.h>
RL_BEGIN
#define CLOCKS_PER_SEC 1000000L
#define CLOCK_REALTIME 0
#define CLOCK_MONOTONIC 1
#define CLOCK_PROCESS_CPUTIME_ID 2
#define CLOCK_THREAD_CPUTIME_ID 3
#define CLOCK_MONOTONIC_RAW 4
#define CLOCK_BOOTTIME 7
#define TIMER_ABSTIME 1
typedef long clock_t;
struct timespec { time_t tv_sec; long tv_nsec; };
struct tm {
  int tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_yday, tm_isdst;
  long tm_gmtoff;
  const char *tm_zone;
};
extern long timezone;
extern int daylight;
extern char *tzname[2];
time_t time(time_t *t);
clock_t clock(void);
double difftime(time_t a, time_t b);
time_t mktime(struct tm *tm);
time_t timegm(struct tm *tm);
struct tm *gmtime(const time_t *t);
struct tm *gmtime_r(const time_t *restrict t, struct tm *restrict r);
struct tm *localtime(const time_t *t);
struct tm *localtime_r(const time_t *restrict t, struct tm *restrict r);
char *asctime(const struct tm *tm);
char *ctime(const time_t *t);
size_t strftime(char *restrict s, size_t n, const char *restrict f, const struct tm *restrict tm);
char *strptime(const char *restrict s, const char *restrict f, struct tm *restrict tm);
int clock_gettime(clockid_t c, struct timespec *ts);
int clock_getres(clockid_t c, struct timespec *ts);
int clock_settime(clockid_t c, const struct timespec *ts);
int nanosleep(const struct timespec *a, struct timespec *b);
int clock_nanosleep(clockid_t c, int flags, const struct timespec *a, struct timespec *b);
void tzset(void);
RL_END
#endif
