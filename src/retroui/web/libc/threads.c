/* Threads in a browser (built with them: -matomics, a shared memory): a
   thread is a Web Worker of the page running this same program on the
   same memory (retro.js starts it: rl_thread_spawn), with its own stack
   and its own thread-local storage. Locks are futexes: WebAssembly's
   atomic wait and notify. The page's own thread may not wait (browsers
   refuse it), so there a lock spins until it is free -- keep what the page's
   thread waits for short; a worker sleeps. */

typedef struct RlThread {
  void *(*fn)(void *);   /* (retro.js knows this layout: done at 12, detached at 16) */
  void *arg;
  void *result;
  int done;              /* (atomic) 2 once its worker left it (retro.js sets it) */
  int detached;          /* (atomic) 1: nobody joins it; 2: it ended (whoever comes second frees it) */
  void *stack;
  void *tls;
} RlThread;
_Static_assert(__builtin_offsetof(RlThread, done) == 12 && __builtin_offsetof(RlThread, detached) == 16,
               "retro.js finds done and detached at 12 and 16");

RL_IMPORT(rl_thread_spawn) int rl_thread_spawn(RlThread *t, void *stackTop, void *tls);
RL_IMPORT(rl_thread_exit) void rl_thread_exit(void);
RL_IMPORT(rl_thread_serve) void rl_thread_serve(void);

static _Thread_local RlThread *rlSelf;
static _Thread_local int rlWorker;      /* 1: a worker (it may wait); 0: the page's thread */

static void rlFreeThread(RlThread *t) {
  free(t->stack);
  free(t->tls);
  free(t);
}

/* (retro.js) a thread's start, on its worker, its stack and TLS set up;
   when it returns (or pthread_exit threw), retro.js marks it done */
__attribute__((export_name("retro_thread_entry"))) void retro_thread_entry(RlThread *t) {
  rlSelf = t;
  rlWorker = 1;
  t->result = t->fn(t->arg);
}

/* (retro.js, on the page's thread) a detached thread that ended: freed --
   not by its worker, which still stood on the stack */
__attribute__((export_name("retro_thread_reap"))) void retro_thread_reap(RlThread *t) {
  rlFreeThread(t);
}

static long long rlNowNs(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/* waits while *p == v (at most ns nanoseconds, < 0: no limit); 1 when the time ran out */
static int rlWait(int *p, int v, long long ns) {
  if (rlWorker) {
    int r = __builtin_wasm_memory_atomic_wait32(p, v, ns < 0 ? -1 : ns);
    return r == 2;
  }
  /* (the page's thread: it spins, and meanwhile does what the threads ask
     of the page -- their files, their output -- so a thread that holds
     the lock and waits for the page ends) */
  long long until = ns < 0 ? -1 : rlNowNs() + ns;
  unsigned spins = 0;
  while (__atomic_load_n(p, __ATOMIC_SEQ_CST) == v) {
    if ((++spins & 255) == 0) {
      rl_thread_serve();
      if (until >= 0 && rlNowNs() >= until) return 1;
    }
  }
  return 0;
}

int rl_sleep_ns(long long ns) {
  if (ns <= 0) return 0;
  if (rlWorker) {
    int never = 0;
    __builtin_wasm_memory_atomic_wait32(&never, 0, ns);
  }
  /* (the page's thread: it does not sleep -- the page would freeze) */
  return 0;
}

int pthread_create(pthread_t *restrict thr, const pthread_attr_t *restrict a, void *(*f)(void *), void *restrict arg) {
  size_t ss = a && a->stacksize >= 65536 ? a->stacksize : 262144;
  RlThread *t = calloc(1, sizeof *t);
  if (!t) return EAGAIN;
  t->fn = f;
  t->arg = arg;
  t->detached = a && a->detach == PTHREAD_CREATE_DETACHED;
  t->stack = malloc(ss);
  size_t tlsAlign = __builtin_wasm_tls_align(), tlsSize = __builtin_wasm_tls_size();
  t->tls = calloc(1, tlsSize + tlsAlign + 16);   /* (its zeroed part: zero) */
  if (!t->stack || !t->tls) { rlFreeThread(t); return EAGAIN; }
  void *tls = (void *)(((uintptr_t)t->tls + tlsAlign - 1) & ~(uintptr_t)(tlsAlign - 1));
  void *top = (void *)(((uintptr_t)t->stack + ss) & ~(uintptr_t)15);
  if (rl_thread_spawn(t, top, tls) != 0) { rlFreeThread(t); return EAGAIN; }
  *thr = (pthread_t)t;
  return 0;
}

int pthread_join(pthread_t th, void **r) {
  RlThread *t = (RlThread *)th;
  if (!t || th == 1) return EINVAL;
  int d;
  while ((d = __atomic_load_n(&t->done, __ATOMIC_SEQ_CST)) != 2) rlWait(&t->done, d, -1);
  if (r) *r = t->result;
  rlFreeThread(t);
  return 0;
}

int pthread_detach(pthread_t th) {
  RlThread *t = (RlThread *)th;
  if (!t || th == 1) return EINVAL;
  if (__atomic_exchange_n(&t->detached, 1, __ATOMIC_SEQ_CST) == 2) rlFreeThread(t);
  return 0;
}

_Noreturn void pthread_exit(void *r) {
  if (!rlSelf) exit(0);
  rlSelf->result = r;
  rl_thread_exit();             /* (throws: the worker leaves the thread) */
  for (;;) {}
}

pthread_t pthread_self(void) { return rlSelf ? (pthread_t)rlSelf : 1; }
int pthread_equal(pthread_t a, pthread_t b) { return a == b; }
int pthread_cancel(pthread_t t) { (void)t; return ENOSYS; }
int pthread_kill(pthread_t t, int s) { (void)t; (void)s; return 0; }
int pthread_setcancelstate(int s, int *o) { (void)s; if (o) *o = 0; return 0; }
int pthread_attr_init(pthread_attr_t *a) { a->stacksize = 262144; a->detach = 0; return 0; }
int pthread_attr_destroy(pthread_attr_t *a) { (void)a; return 0; }
int pthread_attr_setstacksize(pthread_attr_t *a, size_t n) { a->stacksize = n; return 0; }
int pthread_attr_getstacksize(const pthread_attr_t *restrict a, size_t *restrict n) { *n = a->stacksize; return 0; }
int pthread_attr_setdetachstate(pthread_attr_t *a, int s) { a->detach = s; return 0; }
int pthread_getattr_np(pthread_t t, pthread_attr_t *a) { (void)t; return pthread_attr_init(a); }
int pthread_attr_getstack(const pthread_attr_t *restrict a, void **restrict p, size_t *restrict n) { (void)a; *p = 0; *n = 0; return 0; }
int pthread_setname_np(pthread_t t, const char *n) { (void)t; (void)n; return 0; }
int pthread_setaffinity_np(pthread_t t, size_t n, const void *s) { (void)t; (void)n; (void)s; return 0; }

/* ---- mutexes: 0 free, 1 taken, 2 taken and someone waits ---- */

int pthread_mutex_init(pthread_mutex_t *restrict m, const pthread_mutexattr_t *restrict a) {
  m->kind = a ? a->kind : 0;
  m->locked = 0;
  m->owner = 0;
  m->count = 0;
  return 0;
}
int pthread_mutex_destroy(pthread_mutex_t *m) { (void)m; return 0; }

int pthread_mutex_lock(pthread_mutex_t *m) {
  pthread_t me = pthread_self();
  if (m->kind == PTHREAD_MUTEX_RECURSIVE && __atomic_load_n(&m->owner, __ATOMIC_SEQ_CST) == me) {
    m->count++;
    return 0;
  }
  int c = 0;
  if (!__atomic_compare_exchange_n(&m->locked, &c, 1, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) {
    if (c != 2) c = __atomic_exchange_n(&m->locked, 2, __ATOMIC_SEQ_CST);
    while (c != 0) {
      rlWait(&m->locked, 2, -1);
      c = __atomic_exchange_n(&m->locked, 2, __ATOMIC_SEQ_CST);
    }
  }
  __atomic_store_n(&m->owner, me, __ATOMIC_SEQ_CST);
  m->count = 1;
  return 0;
}

int pthread_mutex_trylock(pthread_mutex_t *m) {
  pthread_t me = pthread_self();
  if (m->kind == PTHREAD_MUTEX_RECURSIVE && __atomic_load_n(&m->owner, __ATOMIC_SEQ_CST) == me) {
    m->count++;
    return 0;
  }
  int c = 0;
  if (!__atomic_compare_exchange_n(&m->locked, &c, 1, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) return EBUSY;
  __atomic_store_n(&m->owner, me, __ATOMIC_SEQ_CST);
  m->count = 1;
  return 0;
}

int pthread_mutex_unlock(pthread_mutex_t *m) {
  if (m->kind == PTHREAD_MUTEX_RECURSIVE && m->count > 1) {
    m->count--;
    return 0;
  }
  m->count = 0;
  __atomic_store_n(&m->owner, 0, __ATOMIC_SEQ_CST);
  if (__atomic_exchange_n(&m->locked, 0, __ATOMIC_SEQ_CST) == 2)
    __builtin_wasm_memory_atomic_notify(&m->locked, 1);
  return 0;
}

int pthread_mutexattr_init(pthread_mutexattr_t *a) { a->kind = 0; return 0; }
int pthread_mutexattr_destroy(pthread_mutexattr_t *a) { (void)a; return 0; }
int pthread_mutexattr_settype(pthread_mutexattr_t *a, int t) { a->kind = t; return 0; }

/* ---- conditions: a sequence number waited on ---- */

int pthread_cond_init(pthread_cond_t *restrict c, const pthread_condattr_t *restrict a) {
  c->seq = 0;
  c->clock = a ? a->clock : CLOCK_REALTIME;
  return 0;
}
int pthread_cond_destroy(pthread_cond_t *c) { (void)c; return 0; }

static int rlCondWait(pthread_cond_t *c, pthread_mutex_t *m, long long ns) {
  int s = __atomic_load_n(&c->seq, __ATOMIC_SEQ_CST);
  int saved = m->count;
  m->count = 1;
  pthread_mutex_unlock(m);
  int timedOut = rlWait(&c->seq, s, ns);
  pthread_mutex_lock(m);
  m->count = saved;
  return timedOut ? ETIMEDOUT : 0;
}

int pthread_cond_wait(pthread_cond_t *restrict c, pthread_mutex_t *restrict m) {
  return rlCondWait(c, m, -1);
}

int pthread_cond_timedwait(pthread_cond_t *restrict c, pthread_mutex_t *restrict m, const struct timespec *restrict t) {
  struct timespec now;
  clock_gettime(c->clock, &now);
  long long ns = ((long long)t->tv_sec - now.tv_sec) * 1000000000LL + (t->tv_nsec - now.tv_nsec);
  if (ns <= 0) return ETIMEDOUT;
  return rlCondWait(c, m, ns);
}

int pthread_cond_signal(pthread_cond_t *c) {
  __atomic_fetch_add(&c->seq, 1, __ATOMIC_SEQ_CST);
  __builtin_wasm_memory_atomic_notify(&c->seq, 1);
  return 0;
}

int pthread_cond_broadcast(pthread_cond_t *c) {
  __atomic_fetch_add(&c->seq, 1, __ATOMIC_SEQ_CST);
  __builtin_wasm_memory_atomic_notify(&c->seq, (unsigned)-1);
  return 0;
}

int pthread_condattr_init(pthread_condattr_t *a) { a->clock = CLOCK_REALTIME; return 0; }
int pthread_condattr_destroy(pthread_condattr_t *a) { (void)a; return 0; }
int pthread_condattr_setclock(pthread_condattr_t *a, clockid_t c) { a->clock = c; return 0; }

/* ---- keys (each thread its values), once, read-write locks (one lock) ---- */

static _Thread_local const void *keyValues[128];
static int keyCount;
int pthread_key_create(pthread_key_t *k, void (*d)(void *)) {
  (void)d;
  int n = __atomic_fetch_add(&keyCount, 1, __ATOMIC_SEQ_CST);
  if (n >= 128) return EAGAIN;
  *k = (pthread_key_t)n;
  return 0;
}
int pthread_key_delete(pthread_key_t k) { (void)k; return 0; }
void *pthread_getspecific(pthread_key_t k) { return k < 128 ? (void *)keyValues[k] : 0; }
int pthread_setspecific(pthread_key_t k, const void *v) { if (k >= 128) return EINVAL; keyValues[k] = v; return 0; }

int pthread_once(pthread_once_t *o, void (*f)(void)) {
  int c = 0;
  if (__atomic_compare_exchange_n(o, &c, 1, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) {
    f();
    __atomic_store_n(o, 2, __ATOMIC_SEQ_CST);
    __builtin_wasm_memory_atomic_notify(o, (unsigned)-1);
  } else {
    while (__atomic_load_n(o, __ATOMIC_SEQ_CST) != 2) rlWait(o, 1, -1);
  }
  return 0;
}

int pthread_rwlock_init(pthread_rwlock_t *restrict l, const pthread_rwlockattr_t *restrict a) {
  (void)a;
  l->readers = l->writer = 0;
  return pthread_mutex_init(&l->m, 0);
}
int pthread_rwlock_destroy(pthread_rwlock_t *l) { (void)l; return 0; }
int pthread_rwlock_rdlock(pthread_rwlock_t *l) { return pthread_mutex_lock(&l->m); }
int pthread_rwlock_wrlock(pthread_rwlock_t *l) { return pthread_mutex_lock(&l->m); }
int pthread_rwlock_unlock(pthread_rwlock_t *l) { return pthread_mutex_unlock(&l->m); }
