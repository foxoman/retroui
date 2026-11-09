#ifndef _RL_PTHREAD_H
#define _RL_PTHREAD_H
/* Threads in a browser: built with them (`retrokit web --threads`), a
   thread is a Web Worker on the same memory, and the locks are futexes
   (WebAssembly's atomic wait and notify; the page's own thread may not
   wait, so it spins). Built without them, there is one thread: the locks
   are free to take and pthread_create says EAGAIN. */
#include "_rl.h"
#include <sys/types.h>
#include <time.h>
#include <sched.h>
RL_BEGIN
/* (the types are in <sys/types.h>, as Linux has them) */
#define PTHREAD_MUTEX_INITIALIZER {0, 0, 0, 0}
#define PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP {1, 0, 0, 0}
#define PTHREAD_COND_INITIALIZER {0, 0}
#define PTHREAD_RWLOCK_INITIALIZER {{0, 0, 0, 0}, 0, 0}
#define PTHREAD_ONCE_INIT 0
#define PTHREAD_MUTEX_NORMAL 0
#define PTHREAD_MUTEX_RECURSIVE 1
#define PTHREAD_MUTEX_ERRORCHECK 2
#define PTHREAD_MUTEX_DEFAULT 0
#define PTHREAD_CREATE_JOINABLE 0
#define PTHREAD_CREATE_DETACHED 1
#define PTHREAD_CANCEL_ENABLE 0
#define PTHREAD_CANCEL_DISABLE 1
#define PTHREAD_PROCESS_PRIVATE 0
#define PTHREAD_PROCESS_SHARED 1
#define PTHREAD_STACK_MIN 2048
int pthread_create(pthread_t *restrict t, const pthread_attr_t *restrict a, void *(*f)(void *), void *restrict arg);
int pthread_join(pthread_t t, void **r);
int pthread_detach(pthread_t t);
_Noreturn void pthread_exit(void *r);
pthread_t pthread_self(void);
int pthread_equal(pthread_t a, pthread_t b);
int pthread_cancel(pthread_t t);
int pthread_kill(pthread_t t, int s);
int pthread_setcancelstate(int s, int *o);
int pthread_attr_init(pthread_attr_t *a);
int pthread_attr_destroy(pthread_attr_t *a);
int pthread_attr_setstacksize(pthread_attr_t *a, size_t n);
int pthread_attr_getstacksize(const pthread_attr_t *restrict a, size_t *restrict n);
int pthread_attr_setdetachstate(pthread_attr_t *a, int s);
int pthread_mutex_init(pthread_mutex_t *restrict m, const pthread_mutexattr_t *restrict a);
int pthread_mutex_destroy(pthread_mutex_t *m);
int pthread_mutex_lock(pthread_mutex_t *m);
int pthread_mutex_trylock(pthread_mutex_t *m);
int pthread_mutex_unlock(pthread_mutex_t *m);
int pthread_mutexattr_init(pthread_mutexattr_t *a);
int pthread_mutexattr_destroy(pthread_mutexattr_t *a);
int pthread_mutexattr_settype(pthread_mutexattr_t *a, int t);
int pthread_cond_init(pthread_cond_t *restrict c, const pthread_condattr_t *restrict a);
int pthread_cond_destroy(pthread_cond_t *c);
int pthread_cond_wait(pthread_cond_t *restrict c, pthread_mutex_t *restrict m);
int pthread_cond_timedwait(pthread_cond_t *restrict c, pthread_mutex_t *restrict m, const struct timespec *restrict t);
int pthread_cond_signal(pthread_cond_t *c);
int pthread_cond_broadcast(pthread_cond_t *c);
int pthread_condattr_init(pthread_condattr_t *a);
int pthread_condattr_destroy(pthread_condattr_t *a);
int pthread_condattr_setclock(pthread_condattr_t *a, clockid_t c);
int pthread_key_create(pthread_key_t *k, void (*d)(void *));
int pthread_key_delete(pthread_key_t k);
void *pthread_getspecific(pthread_key_t k);
int pthread_setspecific(pthread_key_t k, const void *v);
int pthread_once(pthread_once_t *o, void (*f)(void));
int pthread_rwlock_init(pthread_rwlock_t *restrict l, const pthread_rwlockattr_t *restrict a);
int pthread_rwlock_destroy(pthread_rwlock_t *l);
int pthread_rwlock_rdlock(pthread_rwlock_t *l);
int pthread_rwlock_wrlock(pthread_rwlock_t *l);
int pthread_rwlock_unlock(pthread_rwlock_t *l);
int pthread_setname_np(pthread_t t, const char *n);
int pthread_getattr_np(pthread_t t, pthread_attr_t *a);
int pthread_attr_getstack(const pthread_attr_t *restrict a, void **restrict p, size_t *restrict n);
int pthread_setaffinity_np(pthread_t t, size_t n, const void *s);
RL_END
#endif
