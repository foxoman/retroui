/* An SQLite VFS that keeps a database encrypted on disk (retroui/db's
** openDb with a key): every page of the database file and of its WAL is
** sealed with XChaCha20-Poly1305 (Monocypher) -- a fresh nonce each time it
** is written, the page's place in the file bound in, so a page changed,
** cut or moved on disk is found when it is read. The nonce (24 bytes) and
** the tag (16) live in the last 40 bytes of each 4096-byte page, which the
** database keeps free for them (SQLite's "reserved bytes"); SQLite sees
** them as zeros, which is what its WAL checksums are worked out over.
**
** What the file holds, page by page:   [ 4056 sealed bytes | nonce | tag ]
** The WAL: its 32-byte header and each frame's 24-byte header as SQLite
** writes them (page numbers, salts, checksums -- nothing of the data), each
** frame's page sealed as above.
**
** Other files SQLite may make -- a rollback journal, temporary files for a
** big sort -- are encrypted too, with XChaCha20 alone (a key of their own,
** made from the database's; a temporary file's is random and forgotten).
**
** Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net
*/
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include "vendor/sqlite/sqlite3.h"
#include "vendor/monocypher.h"

#define RC_PAGE 4096
#define RC_RESERVE 40
#define RC_DATA (RC_PAGE - RC_RESERVE)
#define RC_WAL_HDR 32
#define RC_FRAME_HDR 24
#define RC_FRAME (RC_FRAME_HDR + RC_PAGE)

enum { RC_PLAIN = 0, RC_DB = 1, RC_WAL = 2, RC_STREAM = 3 };

typedef struct RcVfs {
  sqlite3_vfs base;
  sqlite3_vfs *root;
  uint8_t key[32];         /* the database's and its WAL's */
  uint8_t streamKey[32];   /* a rollback journal's */
  uint8_t prefix[16];      /* nonces: these 16 random bytes, then a count */
  uint64_t count;
  sqlite3_mutex *mu;
  char name[64];
} RcVfs;

typedef struct RcFile {
  sqlite3_file base;
  sqlite3_file *real;
  RcVfs *vfs;
  int kind;
  uint8_t streamKey[32];
  uint8_t streamNonce[24];
  sqlite3_int64 lastFrameHdr;   /* the WAL: where the last frame header was written, */
  uint32_t lastPgno;            /* ... and the page it is for */
  uint8_t buf[RC_PAGE];
  uint8_t out[RC_PAGE];
} RcFile;

/* ---- the crypto ------------------------------------------------------------------- */

static void rc_nonce(RcVfs *v, uint8_t nonce[24]) {
  uint64_t n;
  sqlite3_mutex_enter(v->mu);
  n = ++v->count;
  sqlite3_mutex_leave(v->mu);
  memcpy(nonce, v->prefix, 16);
  for (int i = 0; i < 8; i++) nonce[16 + i] = (uint8_t)(n >> (8 * i));
}

static void rc_ad(uint8_t ad[9], int kind, sqlite3_int64 at) {
  ad[0] = (uint8_t)kind;
  for (int i = 0; i < 8; i++) ad[1 + i] = (uint8_t)((uint64_t)at >> (8 * i));
}

static void rc_seal(RcFile *p, const uint8_t *plain, uint8_t *sealed, sqlite3_int64 at) {
  uint8_t ad[9];
  uint8_t *nonce = sealed + RC_DATA;
  uint8_t *mac = sealed + RC_DATA + 24;
  rc_nonce(p->vfs, nonce);
  rc_ad(ad, p->kind, at);
  crypto_aead_lock(sealed, mac, p->vfs->key, nonce, ad, sizeof ad, plain, RC_DATA);
}

/* 0: opened; 1: all zeros (never written: zeros); -1: does not open */
static int rc_open(RcFile *p, const uint8_t *sealed, uint8_t *plain, sqlite3_int64 at) {
  uint8_t ad[9];
  int zero = 1;
  for (int i = 0; i < RC_PAGE; i++) if (sealed[i]) { zero = 0; break; }
  if (zero) { memset(plain, 0, RC_PAGE); return 1; }
  rc_ad(ad, p->kind, at);
  if (crypto_aead_unlock(plain, sealed + RC_DATA + 24, p->vfs->key, sealed + RC_DATA, ad, sizeof ad,
                         sealed, RC_DATA) != 0) {
    memset(plain, 0, RC_PAGE);
    return -1;
  }
  memset(plain + RC_DATA, 0, RC_RESERVE);
  return 0;
}

static void rc_stream(RcFile *p, uint8_t *buf, int n, sqlite3_int64 off) {
  /* XChaCha20 at any offset: the keystream's 64-byte blocks counted from 0 */
  uint8_t ks[64];
  while (n > 0) {
    uint64_t blk = (uint64_t)off / 64;
    int skip = (int)((uint64_t)off % 64);
    if (skip == 0 && n >= 64) {
      int whole = n / 64 * 64;
      crypto_chacha20_x(buf, buf, (size_t)whole, p->streamKey, p->streamNonce, blk);
      buf += whole; n -= whole; off += whole;
      continue;
    }
    int take = 64 - skip;
    if (take > n) take = n;
    memset(ks, 0, sizeof ks);
    crypto_chacha20_x(ks, ks, 64, p->streamKey, p->streamNonce, blk);
    for (int i = 0; i < take; i++) buf[i] ^= ks[skip + i];
    buf += take; n -= take; off += take;
  }
  crypto_wipe(ks, sizeof ks);
}

/* ---- where the sealed pages are ---------------------------------------------------- */

/* The region of the file `off` is in: its start, its length, sealed or not. */
static void rc_region(int kind, sqlite3_int64 off, sqlite3_int64 *start, int *len, int *sealed) {
  if (kind == RC_DB) {
    *start = off / RC_PAGE * RC_PAGE; *len = RC_PAGE; *sealed = 1;
    return;
  }
  if (off < RC_WAL_HDR) { *start = 0; *len = RC_WAL_HDR; *sealed = 0; return; }
  sqlite3_int64 f = (off - RC_WAL_HDR) / RC_FRAME;
  sqlite3_int64 fs = RC_WAL_HDR + f * RC_FRAME;
  if (off < fs + RC_FRAME_HDR) { *start = fs; *len = RC_FRAME_HDR; *sealed = 0; }
  else { *start = fs + RC_FRAME_HDR; *len = RC_PAGE; *sealed = 1; }
}

static int rc_checkHeader(const uint8_t *page1) {
  /* the database's first page: 4096-byte pages, 40 of them kept free */
  if (memcmp(page1, "SQLite format 3", 16) != 0) return 1;     /* (not yet a database) */
  return page1[16] == 0x10 && page1[17] == 0x00 && page1[20] == RC_RESERVE;
}

/* ---- the file's methods ------------------------------------------------------------ */

static int rcClose(sqlite3_file *f) {
  RcFile *p = (RcFile *)f;
  int rc = p->real->pMethods ? p->real->pMethods->xClose(p->real) : SQLITE_OK;
  crypto_wipe(p->buf, sizeof p->buf);
  crypto_wipe(p->out, sizeof p->out);
  crypto_wipe(p->streamKey, sizeof p->streamKey);
  return rc;
}

static int rcReadPage(RcFile *p, sqlite3_int64 start, uint8_t *plain, int *short_) {
  int rc = p->real->pMethods->xRead(p->real, p->out, RC_PAGE, start);
  if (rc == SQLITE_IOERR_SHORT_READ) {
    /* (past the end, or a page cut off by a crash: nothing there) */
    *short_ = 1;
    memset(plain, 0, RC_PAGE);
    return SQLITE_OK;
  }
  if (rc != SQLITE_OK) return rc;
  int o = rc_open(p, p->out, plain, start);
  if (o < 0) {
    /* a WAL frame that does not open is one a crash cut off: its checksum
    ** will not match, and SQLite stops reading the WAL there */
    if (p->kind == RC_WAL) return SQLITE_OK;
    return SQLITE_IOERR_DATA;
  }
  if (p->kind == RC_DB && start == 0 && o == 0 && !rc_checkHeader(plain)) return SQLITE_IOERR_DATA;
  return SQLITE_OK;
}

static int rcRead(sqlite3_file *f, void *out, int amt, sqlite3_int64 off) {
  RcFile *p = (RcFile *)f;
  if (p->kind == RC_PLAIN) return p->real->pMethods->xRead(p->real, out, amt, off);
  if (p->kind == RC_STREAM) {
    int rc = p->real->pMethods->xRead(p->real, out, amt, off);
    if (rc == SQLITE_OK || rc == SQLITE_IOERR_SHORT_READ) rc_stream(p, (uint8_t *)out, amt, off);
    if (rc == SQLITE_IOERR_SHORT_READ) {
      /* (SQLite wants zeros past the end, not keystream) */
      sqlite3_int64 size = 0;
      p->real->pMethods->xFileSize(p->real, &size);
      if (size < off + amt) {
        sqlite3_int64 from = size > off ? size - off : 0;
        memset((uint8_t *)out + from, 0, (size_t)(amt - from));
      }
    }
    return rc;
  }
  uint8_t *dst = (uint8_t *)out;
  int short_ = 0;
  while (amt > 0) {
    sqlite3_int64 start; int len, sealed;
    rc_region(p->kind, off, &start, &len, &sealed);
    int skip = (int)(off - start);
    int take = len - skip;
    if (take > amt) take = amt;
    if (sealed) {
      int rc = rcReadPage(p, start, p->buf, &short_);
      if (rc != SQLITE_OK) return rc;
      memcpy(dst, p->buf + skip, (size_t)take);
    } else {
      int rc = p->real->pMethods->xRead(p->real, dst, take, off);
      if (rc == SQLITE_IOERR_SHORT_READ) short_ = 1;
      else if (rc != SQLITE_OK) return rc;
    }
    dst += take; off += take; amt -= take;
  }
  return short_ ? SQLITE_IOERR_SHORT_READ : SQLITE_OK;
}

static int rcWrite(sqlite3_file *f, const void *in, int amt, sqlite3_int64 off) {
  RcFile *p = (RcFile *)f;
  if (p->kind == RC_PLAIN) return p->real->pMethods->xWrite(p->real, in, amt, off);
  const uint8_t *src = (const uint8_t *)in;
  if (p->kind == RC_STREAM) {
    while (amt > 0) {
      int take = amt > RC_PAGE ? RC_PAGE : amt;
      memcpy(p->out, src, (size_t)take);
      rc_stream(p, p->out, take, off);
      int rc = p->real->pMethods->xWrite(p->real, p->out, take, off);
      if (rc != SQLITE_OK) return rc;
      src += take; off += take; amt -= take;
    }
    return SQLITE_OK;
  }
  while (amt > 0) {
    sqlite3_int64 start; int len, sealed;
    rc_region(p->kind, off, &start, &len, &sealed);
    int skip = (int)(off - start);
    int take = len - skip;
    if (take > amt) take = amt;
    if (sealed) {
      if (skip == 0 && take == RC_PAGE) memcpy(p->buf, src, RC_PAGE);
      else {
        /* (part of a page: the rest as it is) */
        int short_ = 0;
        int rc = rcReadPage(p, start, p->buf, &short_);
        if (rc != SQLITE_OK && rc != SQLITE_IOERR_DATA) return rc;
        if (rc == SQLITE_IOERR_DATA) memset(p->buf, 0, RC_PAGE);
        memcpy(p->buf + skip, src, (size_t)take);
      }
      /* never what would not fit: data in the bytes kept for the nonce and tag
      ** would be lost (a database not made with them kept free) */
      int bad = 0;
      if (p->kind == RC_DB && start == 0) bad = !rc_checkHeader(p->buf);
      if (p->kind == RC_WAL && p->lastPgno == 1 && p->lastFrameHdr == start - RC_FRAME_HDR)
        bad = !rc_checkHeader(p->buf);
      if (bad) return SQLITE_IOERR_WRITE;
      for (int i = RC_DATA; i < RC_PAGE; i++) if (p->buf[i]) { bad = 1; break; }
      if (bad) return SQLITE_IOERR_WRITE;
      rc_seal(p, p->buf, p->out, start);
      int rc = p->real->pMethods->xWrite(p->real, p->out, RC_PAGE, start);
      if (rc != SQLITE_OK) return rc;
    } else {
      if (p->kind == RC_WAL) {
        if (start == 0 && skip <= 8 && skip + take >= 12) {
          /* the WAL header: its page size must be ours */
          const uint8_t *ps = src + (8 - skip);
          uint32_t sz = ((uint32_t)ps[0] << 24) | ((uint32_t)ps[1] << 16) | ((uint32_t)ps[2] << 8) | ps[3];
          if (sz != RC_PAGE) return SQLITE_IOERR_WRITE;
        }
        if (start > 0 && skip == 0 && take >= 4) {
          p->lastFrameHdr = start;
          p->lastPgno = ((uint32_t)src[0] << 24) | ((uint32_t)src[1] << 16) | ((uint32_t)src[2] << 8) | src[3];
        }
      }
      int rc = p->real->pMethods->xWrite(p->real, src, take, off);
      if (rc != SQLITE_OK) return rc;
    }
    src += take; off += take; amt -= take;
  }
  return SQLITE_OK;
}

static int rcTruncate(sqlite3_file *f, sqlite3_int64 size) {
  RcFile *p = (RcFile *)f;
  return p->real->pMethods->xTruncate(p->real, size);
}
static int rcSync(sqlite3_file *f, int flags) {
  RcFile *p = (RcFile *)f;
  return p->real->pMethods->xSync(p->real, flags);
}
static int rcFileSize(sqlite3_file *f, sqlite3_int64 *size) {
  RcFile *p = (RcFile *)f;
  return p->real->pMethods->xFileSize(p->real, size);
}
static int rcLock(sqlite3_file *f, int lock) {
  RcFile *p = (RcFile *)f;
  return p->real->pMethods->xLock(p->real, lock);
}
static int rcUnlock(sqlite3_file *f, int lock) {
  RcFile *p = (RcFile *)f;
  return p->real->pMethods->xUnlock(p->real, lock);
}
static int rcCheckReservedLock(sqlite3_file *f, int *out) {
  RcFile *p = (RcFile *)f;
  return p->real->pMethods->xCheckReservedLock(p->real, out);
}
static int rcFileControl(sqlite3_file *f, int op, void *arg) {
  RcFile *p = (RcFile *)f;
  if (op == SQLITE_FCNTL_MMAP_SIZE) {
    /* (no memory-mapped reading: SQLite would see the sealed bytes) */
    *(sqlite3_int64 *)arg = 0;
    return SQLITE_OK;
  }
  int rc = p->real->pMethods->xFileControl(p->real, op, arg);
  if (rc == SQLITE_OK && op == SQLITE_FCNTL_VFSNAME && arg) {
    char *old = *(char **)arg;
    *(char **)arg = sqlite3_mprintf("retrocrypt/%z", old);
  }
  return rc;
}
static int rcSectorSize(sqlite3_file *f) {
  RcFile *p = (RcFile *)f;
  return p->real->pMethods->xSectorSize(p->real);
}
static int rcDeviceCharacteristics(sqlite3_file *f) {
  RcFile *p = (RcFile *)f;
  int c = p->real->pMethods->xDeviceCharacteristics(p->real);
  /* (whole pages read and written; no atomic batches past this layer) */
  c &= ~(SQLITE_IOCAP_SUBPAGE_READ | SQLITE_IOCAP_BATCH_ATOMIC);
  if (p->kind == RC_WAL) c |= SQLITE_IOCAP_POWERSAFE_OVERWRITE;
  return c;
}
static int rcShmMap(sqlite3_file *f, int pg, int pgsz, int extend, void volatile **pp) {
  RcFile *p = (RcFile *)f;
  return p->real->pMethods->xShmMap(p->real, pg, pgsz, extend, pp);
}
static int rcShmLock(sqlite3_file *f, int offset, int n, int flags) {
  RcFile *p = (RcFile *)f;
  return p->real->pMethods->xShmLock(p->real, offset, n, flags);
}
static void rcShmBarrier(sqlite3_file *f) {
  RcFile *p = (RcFile *)f;
  p->real->pMethods->xShmBarrier(p->real);
}
static int rcShmUnmap(sqlite3_file *f, int del) {
  RcFile *p = (RcFile *)f;
  return p->real->pMethods->xShmUnmap(p->real, del);
}

static const sqlite3_io_methods rcMethods = {
  2, rcClose, rcRead, rcWrite, rcTruncate, rcSync, rcFileSize, rcLock, rcUnlock,
  rcCheckReservedLock, rcFileControl, rcSectorSize, rcDeviceCharacteristics,
  rcShmMap, rcShmLock, rcShmBarrier, rcShmUnmap, 0, 0
};

/* ---- the VFS ---------------------------------------------------------------------- */

static int rcOpen(sqlite3_vfs *vfs, sqlite3_filename name, sqlite3_file *f, int flags, int *outFlags) {
  RcVfs *v = (RcVfs *)vfs;
  RcFile *p = (RcFile *)f;
  memset(p, 0, sizeof *p);
  p->vfs = v;
  p->real = (sqlite3_file *)&p[1];
  if (flags & SQLITE_OPEN_MAIN_DB) p->kind = RC_DB;
  else if (flags & SQLITE_OPEN_WAL) p->kind = RC_WAL;
  else {
    p->kind = RC_STREAM;
    if (flags & (SQLITE_OPEN_MAIN_JOURNAL | SQLITE_OPEN_SUPER_JOURNAL)) {
      /* (a journal outlives a crash: its key is the database's, made another) */
      memcpy(p->streamKey, v->streamKey, 32);
      memset(p->streamNonce, 0, 24);
      memcpy(p->streamNonce, (flags & SQLITE_OPEN_MAIN_JOURNAL) ? "main-journal" : "super-journal",
             (flags & SQLITE_OPEN_MAIN_JOURNAL) ? 12 : 13);
    } else {
      sqlite3_randomness(32, p->streamKey);
      sqlite3_randomness(24, p->streamNonce);
    }
  }
  int rc = v->root->xOpen(v->root, name, p->real, flags, outFlags);
  if (rc == SQLITE_OK && p->real->pMethods) p->base.pMethods = &rcMethods;
  else p->base.pMethods = 0;
  return rc;
}

static int rcDelete(sqlite3_vfs *vfs, const char *name, int sync) {
  RcVfs *v = (RcVfs *)vfs; return v->root->xDelete(v->root, name, sync);
}
static int rcAccess(sqlite3_vfs *vfs, const char *name, int flags, int *out) {
  RcVfs *v = (RcVfs *)vfs; return v->root->xAccess(v->root, name, flags, out);
}
static int rcFullPathname(sqlite3_vfs *vfs, const char *name, int n, char *out) {
  RcVfs *v = (RcVfs *)vfs; return v->root->xFullPathname(v->root, name, n, out);
}
static void *rcDlOpen(sqlite3_vfs *vfs, const char *name) {
  RcVfs *v = (RcVfs *)vfs; return v->root->xDlOpen ? v->root->xDlOpen(v->root, name) : 0;
}
static void rcDlError(sqlite3_vfs *vfs, int n, char *msg) {
  RcVfs *v = (RcVfs *)vfs; if (v->root->xDlError) v->root->xDlError(v->root, n, msg);
}
static void (*rcDlSym(sqlite3_vfs *vfs, void *h, const char *sym))(void) {
  RcVfs *v = (RcVfs *)vfs; return v->root->xDlSym ? v->root->xDlSym(v->root, h, sym) : 0;
}
static void rcDlClose(sqlite3_vfs *vfs, void *h) {
  RcVfs *v = (RcVfs *)vfs; if (v->root->xDlClose) v->root->xDlClose(v->root, h);
}
static int rcRandomness(sqlite3_vfs *vfs, int n, char *out) {
  RcVfs *v = (RcVfs *)vfs; return v->root->xRandomness(v->root, n, out);
}
static int rcSleep(sqlite3_vfs *vfs, int us) {
  RcVfs *v = (RcVfs *)vfs; return v->root->xSleep(v->root, us);
}
static int rcCurrentTime(sqlite3_vfs *vfs, double *t) {
  RcVfs *v = (RcVfs *)vfs; return v->root->xCurrentTime(v->root, t);
}
static int rcGetLastError(sqlite3_vfs *vfs, int n, char *msg) {
  RcVfs *v = (RcVfs *)vfs; return v->root->xGetLastError ? v->root->xGetLastError(v->root, n, msg) : 0;
}
static int rcCurrentTimeInt64(sqlite3_vfs *vfs, sqlite3_int64 *t) {
  RcVfs *v = (RcVfs *)vfs;
  if (v->root->iVersion >= 2 && v->root->xCurrentTimeInt64) return v->root->xCurrentTimeInt64(v->root, t);
  double d; int rc = v->root->xCurrentTime(v->root, &d); *t = (sqlite3_int64)(d * 86400000.0); return rc;
}

/* Registers (once per key) a VFS that keeps databases sealed with `key`;
** its name is written to `name` (at least 64 bytes). 0: done. */
int retro_cryptvfs_register(const unsigned char key[32], char *name) {
  static sqlite3_mutex *regMu = 0;
  if (sqlite3_initialize() != SQLITE_OK) return 1;
  sqlite3_mutex *m = sqlite3_mutex_alloc(SQLITE_MUTEX_STATIC_VFS1);
  sqlite3_mutex_enter(m);
  (void)regMu;
  /* the same key again: the same VFS (its name made from the key's hash) */
  uint8_t id[8];
  crypto_blake2b_keyed(id, sizeof id, key, 32, (const uint8_t *)"retrocrypt-name", 15);
  char nm[64];
  strcpy(nm, "retrocrypt-");
  for (int i = 0; i < 8; i++) {
    static const char hex[] = "0123456789abcdef";
    nm[11 + 2 * i] = hex[id[i] >> 4];
    nm[12 + 2 * i] = hex[id[i] & 15];
  }
  nm[27] = 0;
  if (sqlite3_vfs_find(nm)) {
    strcpy(name, nm);
    sqlite3_mutex_leave(m);
    return 0;
  }
  sqlite3_vfs *root = sqlite3_vfs_find(0);
  RcVfs *v = (RcVfs *)sqlite3_malloc(sizeof *v);
  if (!v || !root) { sqlite3_mutex_leave(m); return 1; }
  memset(v, 0, sizeof *v);
  v->root = root;
  memcpy(v->key, key, 32);
  crypto_blake2b_keyed(v->streamKey, 32, key, 32, (const uint8_t *)"retrocrypt-journal", 18);
  sqlite3_randomness(16, v->prefix);
  v->mu = sqlite3_mutex_alloc(SQLITE_MUTEX_FAST);
  strcpy(v->name, nm);
  v->base.iVersion = 2;
  v->base.szOsFile = (int)sizeof(RcFile) + root->szOsFile;
  v->base.mxPathname = root->mxPathname;
  v->base.zName = v->name;
  v->base.pAppData = 0;
  v->base.xOpen = rcOpen;
  v->base.xDelete = rcDelete;
  v->base.xAccess = rcAccess;
  v->base.xFullPathname = rcFullPathname;
  v->base.xDlOpen = rcDlOpen;
  v->base.xDlError = rcDlError;
  v->base.xDlSym = rcDlSym;
  v->base.xDlClose = rcDlClose;
  v->base.xRandomness = rcRandomness;
  v->base.xSleep = rcSleep;
  v->base.xCurrentTime = rcCurrentTime;
  v->base.xGetLastError = rcGetLastError;
  v->base.xCurrentTimeInt64 = rcCurrentTimeInt64;
  int rc = sqlite3_vfs_register(&v->base, 0);
  if (rc == SQLITE_OK) strcpy(name, nm);
  sqlite3_mutex_leave(m);
  return rc;
}

/* The name of the VFS databases are opened with when no other is named. */
const char *retro_cryptvfs_root(void) {
  sqlite3_vfs *v;
  if (sqlite3_initialize() != SQLITE_OK) return "";
  v = sqlite3_vfs_find(0);
  return v ? v->zName : "";
}
