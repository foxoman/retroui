/* A fake Android for testing the NativeActivity driver on a Linux desktop:
 * the NDK calls android_glue.c makes (looper, input queue, window, config,
 * activity, log) and a JNI that answers nothing. main() plays the system:
 * it creates the activity, gives it a window, taps, presses keys, takes
 * the window away and back, and presses Back.
 *
 * Needs the NDK's android/*.h and jni.h (see run.sh). Not part of the
 * library; only for its tests. */

#include <android/native_activity.h>
#include <android/looper.h>
#include <android/input.h>
#include <android/keycodes.h>
#include <android/native_window.h>
#include <android/configuration.h>
#include <android/log.h>
#include <jni.h>
#include <pthread.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <time.h>
#include <stddef.h>

static int realErr = 2;
static volatile int sawClick, sawText, sawPause, finished, kbShown, kbHidden;
static volatile int sawArabic, clicks2, lastHandled = -1;
static volatile int sawCompose, sawKey;
static volatile int lastClicks;
static volatile int starts;
static ANativeActivity *volatile finishedAct;

/* ---- log -------------------------------------------------------------- */

int __android_log_write(int prio, const char *tag, const char *text) {
  (void)prio;
  dprintf(realErr, "[%s] %s\n", tag, text);
  if (strstr(text, "clicked 1")) sawClick = 1;
  if (strstr(text, "typed hi")) sawText = 1;
  if (strstr(text, "paused")) sawPause = 1;
  if (strstr(text, "arabic ok")) sawArabic = 1;
  if (strstr(text, "composing ok")) sawCompose = 1;
  if (strstr(text, "key ok")) sawKey = 1;
  if (strstr(text, "clicked 2")) clicks2 = 1;
  if (strstr(text, "the app starts")) starts++;
  return 1;
}

int __android_log_print(int prio, const char *tag, const char *fmt, ...) {
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof buf, fmt, ap);
  va_end(ap);
  return __android_log_write(prio, tag, buf);
}

/* ---- looper ------------------------------------------------------------- */

struct ALooper { int fds[4], idents[4], n; };
static __thread struct ALooper *threadLooper;

ALooper *ALooper_prepare(int opts) {
  (void)opts;
  if (!threadLooper) threadLooper = calloc(1, sizeof(struct ALooper));
  return threadLooper;
}

int ALooper_addFd(ALooper *l, int fd, int ident, int events, ALooper_callbackFunc cb,
                  void *data) {
  (void)events; (void)cb; (void)data;
  for (int i = 0; i < l->n; i++)
    if (l->fds[i] == fd) { l->idents[i] = ident; return 1; }
  l->fds[l->n] = fd;
  l->idents[l->n++] = ident;
  return 1;
}

int ALooper_removeFd(ALooper *l, int fd) {
  for (int i = 0; i < l->n; i++)
    if (l->fds[i] == fd) {
      l->fds[i] = l->fds[l->n - 1];
      l->idents[i] = l->idents[l->n - 1];
      l->n--;
      return 1;
    }
  return 0;
}

int ALooper_pollOnce(int timeoutMillis, int *outFd, int *outEvents, void **outData) {
  (void)outFd; (void)outEvents; (void)outData;
  struct ALooper *l = threadLooper;
  struct pollfd p[4];
  for (int i = 0; i < l->n; i++) { p[i].fd = l->fds[i]; p[i].events = POLLIN; }
  int r = poll(p, l->n, timeoutMillis);
  if (r < 0) return ALOOPER_POLL_ERROR;
  if (r == 0) return ALOOPER_POLL_TIMEOUT;
  for (int i = 0; i < l->n; i++)
    if (p[i].revents & POLLIN) return l->idents[i];
  return ALOOPER_POLL_TIMEOUT;
}

/* ---- input ---------------------------------------------------------------- */

struct AInputEvent {
  int type, source, action, keyCode, meta;
  float x, y;
};

struct AInputQueue { int rd, wr; ALooper *looper; };

static AInputQueue *newQueue(void) {
  AInputQueue *q = calloc(1, sizeof *q);
  int fds[2];
  if (pipe(fds) != 0) abort();
  q->rd = fds[0];
  q->wr = fds[1];
  fcntl(q->rd, F_SETFL, O_NONBLOCK);
  return q;
}

static void send(AInputQueue *q, struct AInputEvent e) {
  AInputEvent *p = malloc(sizeof *p);
  *p = e;
  if (write(q->wr, &p, sizeof p) != sizeof p) abort();
}

void AInputQueue_attachLooper(AInputQueue *q, ALooper *l, int ident,
                              ALooper_callbackFunc cb, void *data) {
  q->looper = l;
  ALooper_addFd(l, q->rd, ident, ALOOPER_EVENT_INPUT, cb, data);
}

void AInputQueue_detachLooper(AInputQueue *q) {
  if (q->looper) ALooper_removeFd(q->looper, q->rd);
  q->looper = NULL;
}

int32_t AInputQueue_getEvent(AInputQueue *q, AInputEvent **out) {
  AInputEvent *p;
  if (read(q->rd, &p, sizeof p) != sizeof p) return -11;
  *out = p;
  return 0;
}

int32_t AInputQueue_preDispatchEvent(AInputQueue *q, AInputEvent *e) {
  (void)q; (void)e;
  return 0;
}

void AInputQueue_finishEvent(AInputQueue *q, AInputEvent *e, int handled) {
  (void)q;
  lastHandled = handled;
  free(e);
}

int32_t AInputEvent_getType(const AInputEvent *e) { return e->type; }
int32_t AInputEvent_getSource(const AInputEvent *e) { return e->source; }
int32_t AMotionEvent_getAction(const AInputEvent *e) { return e->action; }
float AMotionEvent_getX(const AInputEvent *e, size_t i) { (void)i; return e->x; }
float AMotionEvent_getY(const AInputEvent *e, size_t i) { (void)i; return e->y; }
size_t AMotionEvent_getPointerCount(const AInputEvent *e) { (void)e; return 1; }
int32_t AMotionEvent_getPointerId(const AInputEvent *e, size_t i) { (void)e; return (int32_t)i; }
int32_t AMotionEvent_getButtonState(const AInputEvent *e) { (void)e; return 0; }
/* (the modifier keys held with a click or a wheel: those the event has) */
int32_t AMotionEvent_getMetaState(const AInputEvent *e) { return e->meta; }
float AMotionEvent_getAxisValue(const AInputEvent *e, int32_t a, size_t i) {
  (void)e; (void)a; (void)i; return 1;
}
int64_t AMotionEvent_getEventTime(const AInputEvent *e) {
  (void)e;
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
/* (no main of Nim's here: the command line a desktop driver may ask for) */
int cmdCount = 0;
char **cmdLine = 0;

int32_t AMotionEvent_getFlags(const AInputEvent *e) { (void)e; return 0; }
int32_t AMotionEvent_getToolType(const AInputEvent *e, size_t i) { (void)e; (void)i; return 1; /* finger */ }
float AMotionEvent_getPressure(const AInputEvent *e, size_t i) { (void)e; (void)i; return 1; }
int32_t AInputEvent_getDeviceId(const AInputEvent *e) { (void)e; return 1; }
int32_t AKeyEvent_getScanCode(const AInputEvent *e) { (void)e; return 0; }
int32_t AKeyEvent_getFlags(const AInputEvent *e) { (void)e; return 0; }
int32_t AKeyEvent_getKeyCode(const AInputEvent *e) { return e->keyCode; }
int32_t AKeyEvent_getAction(const AInputEvent *e) { return e->action; }
int32_t AKeyEvent_getMetaState(const AInputEvent *e) { return e->meta; }
int64_t AKeyEvent_getDownTime(const AInputEvent *e) { (void)e; return 0; }
int64_t AKeyEvent_getEventTime(const AInputEvent *e) { (void)e; return 0; }
int32_t AKeyEvent_getRepeatCount(const AInputEvent *e) { (void)e; return 0; }

/* ---- window ------------------------------------------------------------------ */

struct ANativeWindow { int w, h, posts, locked, format; uint32_t *px; };

int32_t ANativeWindow_setBuffersGeometry(ANativeWindow *w, int32_t a, int32_t b, int32_t f) {
  (void)a; (void)b;
  w->format = f;
  return 0;
}
int32_t ANativeWindow_getWidth(ANativeWindow *w) { return w->w; }
int32_t ANativeWindow_getHeight(ANativeWindow *w) { return w->h; }

int32_t ANativeWindow_lock(ANativeWindow *w, ANativeWindow_Buffer *b, ARect *dirty) {
  if (w->locked) { dprintf(realErr, "FAIL: locked twice\n"); _exit(1); }
  w->locked = 1;
  b->width = w->w; b->height = w->h; b->stride = w->w + 16;
  b->format = w->format; b->bits = w->px;
  /* like a real surface after a swap: sometimes everything is dirty */
  if (w->posts % 3 == 2 && dirty) { dirty->left = 0; dirty->top = 0;
    dirty->right = w->w; dirty->bottom = w->h; }
  return 0;
}

int32_t ANativeWindow_unlockAndPost(ANativeWindow *w) {
  w->locked = 0;
  w->posts++;
  return 0;
}

/* ---- configuration and activity ---------------------------------------------------- */

struct AConfiguration { int density; };
AConfiguration *AConfiguration_new(void) { return calloc(1, sizeof(AConfiguration)); }
void AConfiguration_fromAssetManager(AConfiguration *c, AAssetManager *m) {
  (void)m; c->density = 320;
}
int32_t AConfiguration_getDensity(AConfiguration *c) { return c->density; }

void ANativeActivity_finish(ANativeActivity *a) { finishedAct = a; finished = 1; }
void ANativeActivity_showSoftInput(ANativeActivity *a, uint32_t f) { (void)a; (void)f; kbShown++; }
void ANativeActivity_hideSoftInput(ANativeActivity *a, uint32_t f) { (void)a; (void)f; kbHidden++; }

/* ---- a JNI that has no Java behind it ------------------------------------------------- */

static void *nothing(void) { return NULL; }
static int dummyClass;
static void *objectClass(void) { return &dummyClass; }
static JNINativeMethod natives[16];
static int nativeCount;
/* (the glue registers its natives in groups: each group added) */
static jint registerNatives(JNIEnv *env, jclass c, const JNINativeMethod *m, jint n) {
  (void)env; (void)c;
  for (int i = 0; i < n && nativeCount < 16; i++) natives[nativeCount++] = m[i];
  return 0;
}
/* a Java string here is { length, UTF-16 units } */
struct FakeString { jsize len; const jchar *chars; };
static jsize stringLength(JNIEnv *env, jstring s) { (void)env; return ((struct FakeString *)s)->len; }
static const jchar *stringChars(JNIEnv *env, jstring s, jboolean *copy) {
  (void)env; if (copy) *copy = 0; return ((struct FakeString *)s)->chars;
}
static void releaseChars(JNIEnv *env, jstring s, const jchar *c) { (void)env; (void)s; (void)c; }
/* RetroActivity's methods the glue looks up: only systemBars here */
#define BARS_METHOD ((jmethodID)0x51)
static volatile int barsCalls;
static volatile uint32_t barsTop, barsBottom;
static jmethodID methodId(JNIEnv *env, jclass c, const char *name, const char *sig) {
  (void)env; (void)c; (void)sig;
  return strcmp(name, "systemBars") == 0 ? BARS_METHOD : NULL;
}
static void callVoid(JNIEnv *env, jobject o, jmethodID m, ...) {
  (void)env; (void)o;
  if (m != BARS_METHOD) return;
  va_list ap;
  va_start(ap, m);
  barsTop = (uint32_t)va_arg(ap, jint);
  barsBottom = (uint32_t)va_arg(ap, jint);
  va_end(ap);
  barsCalls++;
}
static void *nativeNamed(const char *name) {
  for (int i = 0; i < nativeCount; i++)
    if (strcmp(natives[i].name, name) == 0) return natives[i].fnPtr;
  return NULL;
}
static jint attach(JavaVM *vm, JNIEnv **env, void *args);
static jint detach(JavaVM *vm) { (void)vm; return 0; }
static void *envTable[300];
static const struct JNINativeInterface *envPtr;
static struct JNIInvokeInterface vmTable;
static const struct JNIInvokeInterface *vmPtr = &vmTable;
static jint attach(JavaVM *vm, JNIEnv **env, void *args) {
  (void)vm; (void)args;
  *env = (JNIEnv *)&envPtr;
  return 0;
}

/* ---- the test ------------------------------------------------------------------------- */

extern void ANativeActivity_onCreate(ANativeActivity *, void *, size_t);

static void ms(int n) { struct timespec t = { n / 1000, (n % 1000) * 1000000L }; nanosleep(&t, NULL); }

static void check(int ok, const char *what) {
  dprintf(realErr, "%s: %s\n", ok ? "ok  " : "FAIL", what);
  if (!ok) _exit(1);
}

static void tap(AInputQueue *q, float x, float y) {
  send(q, (struct AInputEvent){ AINPUT_EVENT_TYPE_MOTION, AINPUT_SOURCE_TOUCHSCREEN,
                                AMOTION_EVENT_ACTION_DOWN, 0, 0, x, y });
  ms(60);
  send(q, (struct AInputEvent){ AINPUT_EVENT_TYPE_MOTION, AINPUT_SOURCE_TOUCHSCREEN,
                                AMOTION_EVENT_ACTION_UP, 0, 0, x, y });
  ms(150);
}

static void key(AInputQueue *q, int code) {
  send(q, (struct AInputEvent){ AINPUT_EVENT_TYPE_KEY, AINPUT_SOURCE_KEYBOARD,
                                AKEY_EVENT_ACTION_DOWN, code, 0, 0, 0 });
  send(q, (struct AInputEvent){ AINPUT_EVENT_TYPE_KEY, AINPUT_SOURCE_KEYBOARD,
                                AKEY_EVENT_ACTION_UP, code, 0, 0, 0 });
  ms(100);
}

int main(void) {
  realErr = dup(2);
  for (int i = 0; i < 300; i++) envTable[i] = (void *)nothing;
#define SLOT(f) (offsetof(struct JNINativeInterface, f) / sizeof(void *))
  envTable[SLOT(GetObjectClass)] = (void *)objectClass;
  envTable[SLOT(RegisterNatives)] = (void *)registerNatives;
  envTable[SLOT(GetStringLength)] = (void *)stringLength;
  envTable[SLOT(GetStringChars)] = (void *)stringChars;
  envTable[SLOT(ReleaseStringChars)] = (void *)releaseChars;
  envTable[SLOT(GetMethodID)] = (void *)methodId;
  envTable[SLOT(CallVoidMethod)] = (void *)callVoid;
  setenv("RETRO_CAPTION", "1", 1);   /* the title bar, as on a phone */
  envPtr = (const struct JNINativeInterface *)envTable;
  memset(&vmTable, 0, sizeof vmTable);
  vmTable.AttachCurrentThread = attach;
  vmTable.DetachCurrentThread = detach;

  ANativeActivityCallbacks cb;
  memset(&cb, 0, sizeof cb);
  ANativeActivity act;
  memset(&act, 0, sizeof act);
  act.callbacks = &cb;
  act.vm = (JavaVM *)&vmPtr;
  act.env = (JNIEnv *)&envPtr;
  act.internalDataPath = "/tmp/retro-mock-data";
  act.sdkVersion = 34;

  ANativeActivity_onCreate(&act, NULL, 0);
  check(cb.onNativeWindowCreated && cb.onInputQueueCreated && cb.onDestroy,
        "the activity's callbacks are set");

  AInputQueue *q = newQueue();
  cb.onInputQueueCreated(&act, q);
  ANativeWindow win = { 600, 800, 0, 0, 0, NULL };
  win.px = calloc((size_t)(win.w + 16) * win.h, 4);
  cb.onNativeWindowCreated(&act, &win);
  ARect content = { 0, 50, 600, 800 };    /* a 50 pixel status bar */
  cb.onContentRectChanged(&act, &content);
  cb.onWindowFocusChanged(&act, 1);
  ms(400);
  check(win.posts > 0, "frames reach the window");
  uint32_t bg = win.px[(size_t)700 * (win.w + 16) + 590];
  check(bg == 0xFFFFFFFFu, "the window is white (Windows 3.1 background)");
  check(win.format == WINDOW_FORMAT_RGBX_8888, "the window takes RGBX pixels");
  /* the button: 2x zoom (320 dpi), under the status bar and the title bar */
  /* (the face: gray at the button's left, beside its label, somewhere
   * below the title bar -- 33 pixels tall at 2x) */
  int face = 0;
  for (int yy = 50 + 66; yy < 50 + 66 + 120 && !face; yy++)
    face = win.px[(size_t)yy * (win.w + 16) + 2 * 12] == 0xFFC0C0C0u;
  check(face, "the button face is drawn below the title bar");
  check(win.px[(size_t)10 * (win.w + 16) + 300] == 0xFF800000u,
        "navy under the status bar (the title bar's color)");
  check(barsCalls > 0 && barsTop == 0x000080 && barsBottom == 0xFFFFFF,
        "the status bar is told it is over navy, the navigation bar over white");

  tap(q, 2 * 20, 50 + 64 + 2 * 20);
  check(sawClick, "a tap on the button clicks it");

  tap(q, 2 * 20, 50 + 64 + 2 * (8 + 32 + 8 + 10));    /* the edit field */
  check(kbShown > 0, "an edit field with the focus shows the soft keyboard");
  key(q, AKEYCODE_MOVE_END);
  key(q, AKEYCODE_DEL);
  key(q, AKEYCODE_DEL);
  key(q, AKEYCODE_DEL);
  check(sawText, "Backspace on the keyboard edits the field");
  check(nativeNamed("nativeText") && nativeNamed("nativeInsets"),
        "the Java activity's native methods are registered");
  check(nativeNamed("nativeAccess") && nativeNamed("nativeCompose") && nativeNamed("nativeKey"),
        "the screen reader's and the keyboard's natives are registered");
  {                                             /* Gboard sends Arabic as text */
    static const jchar salam[] = { 0x0633, 0x0644, 0x0627, 0x0645 };
    struct FakeString fs = { 4, salam };
    void (*text)(JNIEnv *, jclass, jstring) =
      (void (*)(JNIEnv *, jclass, jstring))nativeNamed("nativeText");
    text((JNIEnv *)&envPtr, NULL, (jstring)&fs);
    ms(200);
    check(sawArabic, "text from the Java side reaches the focused field");
  }
  {                                             /* the keyboard composes (RetroInput) */
    static const jchar ka[] = { 0x0643, 0x062A };
    struct FakeString fs = { 2, ka };
    void (*compose)(JNIEnv *, jclass, jstring, jint) =
      (void (*)(JNIEnv *, jclass, jstring, jint))nativeNamed("nativeCompose");
    compose((JNIEnv *)&envPtr, NULL, (jstring)&fs, 2);
    ms(200);
    check(sawCompose, "what the keyboard composes reaches the focused field");
    compose((JNIEnv *)&envPtr, NULL, NULL, 0);
    void (*keyOf)(JNIEnv *, jclass, jint, jboolean) =
      (void (*)(JNIEnv *, jclass, jint, jboolean))nativeNamed("nativeKey");
    keyOf((JNIEnv *)&envPtr, NULL, AKEYCODE_DEL, 1);
    keyOf((JNIEnv *)&envPtr, NULL, AKEYCODE_DEL, 0);
    ms(200);
    check(sawKey, "the keyboard's Delete, sent as a key, edits the field");
  }
  /* a cancelled touch (a system gesture) does not click */
  send(q, (struct AInputEvent){ AINPUT_EVENT_TYPE_MOTION, AINPUT_SOURCE_TOUCHSCREEN,
                                AMOTION_EVENT_ACTION_DOWN, 0, 0, 2 * 20, 50 + 64 + 2 * 20 });
  ms(60);
  send(q, (struct AInputEvent){ AINPUT_EVENT_TYPE_MOTION, AINPUT_SOURCE_TOUCHSCREEN,
                                AMOTION_EVENT_ACTION_CANCEL, 0, 0, 2 * 20, 50 + 64 + 2 * 20 });
  ms(150);
  check(!clicks2, "a cancelled touch does not click the button");
  key(q, AKEYCODE_VOLUME_UP);
  check(lastHandled == 0, "volume keys go on to the system");
  key(q, AKEYCODE_MEDIA_NEXT);
  check(lastHandled == 0, "media keys go on to the music app");
  tap(q, 2 * 20, 50 + 64 + 2 * 20);                   /* the button again */
  check(kbHidden > 0, "leaving the field hides the keyboard");

  int before = win.posts;
  cb.onNativeWindowDestroyed(&act, &win);
  ms(150);
  check(sawPause, "losing the window pauses the app");
  win.w = 800; win.h = 600;                      /* turned to landscape */
  cb.onNativeWindowCreated(&act, &win);
  ms(300);
  check(win.posts > before, "a new window gets a new frame");
  check(win.px[(size_t)590 * (win.w + 16) + 790] == 0xFFFFFFFFu,
        "the frame fills the turned window");

  {                                             /* insets from the Java side */
    void (*insets)(JNIEnv *, jclass, jint, jint, jint, jint) =
      (void (*)(JNIEnv *, jclass, jint, jint, jint, jint))nativeNamed("nativeInsets");
    insets((JNIEnv *)&envPtr, NULL, 100, 0, 0, 0);
    ms(300);
    /* (the first gray at the left -- the title bar's menu box -- is below
     * the 100 pixels of the bar now, not at 50 + 12 as before) */
    int first = -1;
    for (int yy = 0; yy < 400 && first < 0; yy++)
      if (win.px[(size_t)yy * (win.w + 16) + 2 * 12] == 0xFFC0C0C0u) first = yy;
    check(first >= 100, "the system bar insets move the content down");
  }
  /* one more activity while the app runs (made beside it, or in its place):
   * the app goes on in it, the first one finished */
  ANativeActivityCallbacks cb2;
  memset(&cb2, 0, sizeof cb2);
  ANativeActivity act2 = act;
  act2.callbacks = &cb2;
  finishedAct = NULL;
  finished = 0;
  ANativeActivity_onCreate(&act2, NULL, 0);
  check(cb2.onDestroy && cb2.onNativeWindowCreated, "a second activity while the app runs takes the app");
  check(finishedAct == &act, "... the first one is finished");
  check(starts == 1, "... and the app's start does not run again");
  ms(200);
  sawPause = 0;
  cb.onNativeWindowDestroyed(&act, &win);        /* (the old one's window going: not the app's) */
  cb.onWindowFocusChanged(&act, 0);
  ms(200);
  check(!sawPause, "the old activity's callbacks are let go");
  AInputQueue *q2 = newQueue();
  cb2.onInputQueueCreated(&act2, q2);
  ANativeWindow win2 = { 600, 800, 0, 0, 0, NULL };
  win2.px = calloc((size_t)(win2.w + 16) * win2.h, 4);
  cb2.onNativeWindowCreated(&act2, &win2);
  cb2.onWindowFocusChanged(&act2, 1);
  ms(600);
  check(win2.posts > 0, "the app draws in the new activity's window");
  cb.onDestroy(&act);                            /* (the old one's end: the process goes on) */
  check(1, "the old activity's end leaves the process to the app");
  int p = win2.posts;
  cb2.onNativeWindowRedrawNeeded(&act2, &win2);
  ms(300);
  check(win2.posts > p, "the app goes on drawing");
  finished = 0;
  key(q2, AKEYCODE_BACK);
  ms(300);
  check(finished && finishedAct == &act2, "Back closes the app, which finishes its activity");
  {                                             /* a new activity before the old one's end */
    ANativeActivityCallbacks cb3;
    memset(&cb3, 0, sizeof cb3);
    ANativeActivity act3 = act;
    act3.callbacks = &cb3;
    ANativeActivity_onCreate(&act3, NULL, 0);
    check(cb3.onDestroy && cb3.onNativeWindowCreated, "an activity after the app ended takes it");
    cb2.onDestroy(&act2);                        /* (the old one's: the process is the new one's) */
    check(1, "the old activity's end leaves the process to the new one");
    AInputQueue *q3 = newQueue();
    cb3.onInputQueueCreated(&act3, q3);
    ANativeWindow win3 = { 600, 800, 0, 0, 0, NULL };
    win3.px = calloc((size_t)(win3.w + 16) * win3.h, 4);
    cb3.onNativeWindowCreated(&act3, &win3);
    cb3.onWindowFocusChanged(&act3, 1);
    ms(600);
    check(starts == 2, "the app starts again in the same process");
    check(win3.posts > 0, "... and draws in the new activity's window");
    finished = 0;
    key(q3, AKEYCODE_BACK);
    ms(300);
    check(finished && finishedAct == &act3, "Back closes it again");
    dprintf(realErr, "android mock tests passed\n");
    cb3.onDestroy(&act3);                        /* ends the process */
  }
  return 1;
}
