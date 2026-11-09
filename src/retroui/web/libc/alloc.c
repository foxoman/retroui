/* malloc and friends: one heap from __heap_base up, grown a page at a
   time (memory.grow). Chunks carry their size and a bit for whether the
   one before is free; a free chunk also keeps its size at its end, so
   neighbours join when freed. Free chunks wait in bins by size: 64 small
   ones (16 bytes apart, up to 1 KB), then one for each power of two. A
   request takes the smallest chunk that fits from the first bin that has
   one, the rest split off; the last chunk of the heap grows into new
   pages. Everything is 16-byte aligned. */

#include <stdlib.h>
#include <string.h>
#include <errno.h>

extern unsigned char __heap_base;

#define ALIGN 16u
#define HDR 16u                        /* (a chunk's header: payload stays aligned) */
#define MIN_CHUNK 32u
#define FLAG_USED 1u
#define FLAG_PREV_FREE 2u
#define NBINS 96

typedef struct Chunk {
  size_t size;                         /* the whole chunk's bytes, flags in the low bits */
  size_t pad[3];
  struct Chunk *next, *prev;           /* (free chunks only: their bin) */
} Chunk;

static unsigned char *heapStart, *heapTop, *heapEnd;
static Chunk *bins[NBINS];
static size_t heapUsed;

static inline size_t csize(Chunk *c) { return c->size & ~(size_t)15; }
static inline Chunk *nextOf(Chunk *c) { return (Chunk *)((unsigned char *)c + csize(c)); }
static inline size_t *footOf(Chunk *c) { return (size_t *)((unsigned char *)c + csize(c)) - 1; }

static int binOf(size_t n) {
  if (n <= 1024) return (int)(n >> 4) - 2 < 0 ? 0 : (int)(n >> 4) - 2;
  int b = 62;
  size_t s = 2048;
  while (s < n && b < NBINS - 1) { s <<= 1; b++; }
  return b;
}

static void unbin(Chunk *c) {
  int b = binOf(csize(c));
  if (c->prev) c->prev->next = c->next; else bins[b] = c->next;
  if (c->next) c->next->prev = c->prev;
}

static void bin(Chunk *c) {
  int b = binOf(csize(c));
  c->prev = 0;
  c->next = bins[b];
  if (bins[b]) bins[b]->prev = c;
  bins[b] = c;
}

static void markFree(Chunk *c) {
  c->size &= ~(size_t)FLAG_USED;
  *footOf(c) = csize(c);
  if ((unsigned char *)nextOf(c) < heapTop) nextOf(c)->size |= FLAG_PREV_FREE;
}

static int grow(size_t need) {
  if (!heapStart) {
    heapStart = (unsigned char *)(((size_t)&__heap_base + ALIGN - 1) & ~(size_t)(ALIGN - 1));
    heapTop = heapStart;
    heapEnd = (unsigned char *)(__builtin_wasm_memory_size(0) * 65536);
  }
  while ((size_t)(heapEnd - heapTop) < need) {
    size_t pages = (need - (size_t)(heapEnd - heapTop) + 65535) / 65536;
    if (pages < 16) pages = 16;                       /* (a megabyte at a time) */
    if (__builtin_wasm_memory_grow(0, pages) == (size_t)-1) {
      pages = (need - (size_t)(heapEnd - heapTop) + 65535) / 65536;
      if (__builtin_wasm_memory_grow(0, pages) == (size_t)-1) return 0;
    }
    heapEnd += pages * 65536;
  }
  return 1;
}

static Chunk *fromTop(size_t n) {
  /* (the heap's last chunk is never free -- a freed one goes back to the
     top -- so the new one's neighbour is in use) */
  if (!grow(n)) return 0;
  Chunk *c = (Chunk *)heapTop;
  c->size = n | FLAG_USED;
  heapTop += n;
  return c;
}

static void split(Chunk *c, size_t n) {
  size_t have = csize(c);
  if (have - n < MIN_CHUNK) return;
  size_t keepFlags = c->size & FLAG_PREV_FREE;
  c->size = n | FLAG_USED | keepFlags;
  Chunk *r = nextOf(c);
  r->size = (have - n) | FLAG_USED;
  if ((unsigned char *)nextOf(r) < heapTop) nextOf(r)->size &= ~(size_t)FLAG_PREV_FREE;
  heapUsed += csize(r);                  /* (free takes it off again) */
  free((unsigned char *)r + HDR);
}

void *malloc(size_t want) {
  if (want > (size_t)0x7fff0000) { errno = ENOMEM; return 0; }
  size_t n = (want + HDR + ALIGN - 1) & ~(size_t)(ALIGN - 1);
  if (n < MIN_CHUNK) n = MIN_CHUNK;
  for (int b = binOf(n); b < NBINS; b++) {
    Chunk *best = 0;
    int looked = 0;
    for (Chunk *c = bins[b]; c && looked < 32; c = c->next, looked++) {
      if (csize(c) >= n && (!best || csize(c) < csize(best))) {
        best = c;
        if (csize(c) == n) break;
      }
    }
    if (best) {
      unbin(best);
      best->size |= FLAG_USED;
      if ((unsigned char *)nextOf(best) < heapTop) nextOf(best)->size &= ~(size_t)FLAG_PREV_FREE;
      split(best, n);
      heapUsed += csize(best);
      return (unsigned char *)best + HDR;
    }
  }
  Chunk *c = fromTop(n);
  if (!c) { errno = ENOMEM; return 0; }
  heapUsed += n;
  return (unsigned char *)c + HDR;
}

void free(void *p) {
  if (!p) return;
  Chunk *c = (Chunk *)((unsigned char *)p - HDR);
  heapUsed -= csize(c);
  /* joined with a free chunk before it */
  if (c->size & FLAG_PREV_FREE) {
    size_t prevSize = *((size_t *)c - 1);
    Chunk *pc = (Chunk *)((unsigned char *)c - prevSize);
    unbin(pc);
    pc->size = (prevSize + csize(c)) | (pc->size & FLAG_PREV_FREE);
    c = pc;
  }
  /* ... and one after it */
  Chunk *nx = nextOf(c);
  if ((unsigned char *)nx < heapTop && !(nx->size & FLAG_USED)) {
    unbin(nx);
    c->size = (csize(c) + csize(nx)) | (c->size & FLAG_PREV_FREE);
  }
  /* the heap's last chunk: back to the top */
  if ((unsigned char *)nextOf(c) >= heapTop) {
    heapTop = (unsigned char *)c;
    return;
  }
  markFree(c);
  bin(c);
}

void *calloc(size_t n, size_t m) {
  if (m && n > (size_t)-1 / m) { errno = ENOMEM; return 0; }
  void *p = malloc(n * m);
  if (p) memset(p, 0, n * m);
  return p;
}

size_t malloc_usable_size(void *p) {
  return p ? csize((Chunk *)((unsigned char *)p - HDR)) - HDR : 0;
}

void *realloc(void *p, size_t want) {
  if (!p) return malloc(want);
  if (!want) { free(p); return 0; }
  Chunk *c = (Chunk *)((unsigned char *)p - HDR);
  size_t n = (want + HDR + ALIGN - 1) & ~(size_t)(ALIGN - 1);
  if (n < MIN_CHUNK) n = MIN_CHUNK;
  size_t have = csize(c);
  if (n <= have) {
    heapUsed -= have;
    split(c, n);
    heapUsed += csize(c);
    return p;
  }
  /* the last chunk: grown in place */
  if ((unsigned char *)nextOf(c) == heapTop) {
    if (!grow(n - have)) { errno = ENOMEM; return 0; }
    heapTop += n - have;
    heapUsed += n - have;
    c->size = n | FLAG_USED | (c->size & FLAG_PREV_FREE);
    return p;
  }
  /* a free chunk after it that is big enough: taken in */
  Chunk *nx = nextOf(c);
  if (!(nx->size & FLAG_USED) && have + csize(nx) >= n) {
    unbin(nx);
    heapUsed -= have;
    c->size = (have + csize(nx)) | FLAG_USED | (c->size & FLAG_PREV_FREE);
    if ((unsigned char *)nextOf(c) < heapTop) nextOf(c)->size &= ~(size_t)FLAG_PREV_FREE;
    split(c, n);
    heapUsed += csize(c);
    return p;
  }
  void *q = malloc(want);
  if (!q) return 0;
  memcpy(q, p, have - HDR);
  free(p);
  return q;
}

void *aligned_alloc(size_t a, size_t n) {
  if (a <= ALIGN) return malloc(n);
  /* (over-allocated; the chunk header just before the payload is a copy
     that free() can follow) */
  unsigned char *raw = malloc(n + a + HDR + MIN_CHUNK);
  if (!raw) return 0;
  size_t addr = ((size_t)raw + MIN_CHUNK + a - 1) & ~(a - 1);
  Chunk *c = (Chunk *)(raw - HDR);
  size_t lead = addr - (size_t)raw;
  /* the lead is split off as a chunk of its own and freed */
  size_t total = csize(c);
  Chunk *d = (Chunk *)(addr - HDR);
  size_t flags = c->size & FLAG_PREV_FREE;
  c->size = lead | FLAG_USED | flags;
  d->size = (total - lead) | FLAG_USED;
  free(raw);
  return (void *)addr;
}

int posix_memalign(void **p, size_t a, size_t n) {
  *p = aligned_alloc(a, n);
  return *p ? 0 : ENOMEM;
}

int malloc_trim(size_t pad) { (void)pad; return 0; }

size_t __rl_heap_used(void) { return heapUsed; }
size_t __rl_heap_size(void) { return (size_t)(heapEnd - heapStart); }
int mallopt(int p, int v) { (void)p; (void)v; return 1; }
