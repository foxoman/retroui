/* android_glue.c -- the Android side of the uirelays NativeActivity driver.
 *
 * Android starts a NativeActivity, which loads libmain.so and calls
 * ANativeActivity_onCreate on the UI thread. We start the app on a thread
 * of its own -- it runs NimMain(), so the app's ordinary main loop -- and
 * turn the activity's callbacks and input into a queue of simple events the
 * Nim driver reads. Pixels go into a shadow buffer and from there into the
 * window with ANativeWindow_lock. Java services (clipboard, text with the
 * system font, opening links, key characters) are reached over JNI.
 *
 * The activity can be a plain NativeActivity, or a small subclass of it
 * (android/UiRelaysActivity.java) for what C cannot reach: text without key
 * codes from the soft keyboard (Arabic, emoji), showing the keyboard, and
 * the insets of the system bars and the keyboard. Its native methods are
 * registered here; the methods it lacks are simply not used.
 *
 * A job of the system (the app's JobService) may start the process without
 * an activity, for the app's background check: see "the background check"
 * below.
 */

#include <android/native_activity.h>
#include <android/looper.h>
#include <android/input.h>
#include <android/keycodes.h>
#include <android/native_window.h>
#include <android/configuration.h>
#include <android/log.h>
#include <jni.h>
#include <math.h>
#include <pthread.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <time.h>
#include <dlfcn.h>

#define TAG "uirelays"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

extern void NimMain(void);

/* Events for the Nim side; keep in sync with android_driver.nim. */
enum {
  UR_NONE, UR_MOVE, UR_DOWN, UR_UP, UR_WHEEL, UR_KEYDOWN, UR_KEYUP,
  UR_TEXT, UR_RESIZE, UR_METRICS, UR_FOCUS, UR_UNFOCUS, UR_PAUSE,
  UR_RESUME, UR_QUIT, UR_GESTURE
  /* UR_GESTURE: two fingers -- x, y their middle, button the phase (0
   * begun, 1 moved, 2 ended), pressure the scale since the last one, tilt
   * and azimuth how far the middle moved */
};

typedef struct {
  int32_t kind, x, y, button, clicks, key, meta;
  char text[8];
  float pressure, tilt, azimuth, twist;   /* a pen's (pressure < 0: not a pen) */
} UrEvent;

enum {
  CMD_INPUT = 1, CMD_WINDOW, CMD_RESIZE, CMD_RECT, CMD_FOCUS, CMD_UNFOCUS,
  CMD_CONFIG, CMD_DESTROY, CMD_START, CMD_STOP, CMD_TEXT
};

#define QN 512
#define LOOPER_ID_CMD 1
#define LOOPER_ID_INPUT 2

static struct {
  ANativeActivity *activity;
  JNIEnv *env;                       /* of the app thread */
  pthread_t appThread;
  pthread_mutex_t mu;
  pthread_cond_t cond;
  int msgread, msgwrite;
  ALooper *looper;
  AInputQueue *queue, *pendingQueue;
  ANativeWindow *window, *pendingWindow;
  ARect rect, pendingRect;
  AConfiguration *config;
  int running, finished, destroyRequested;
  int density, winW, winH;
  /* events for Nim */
  UrEvent q[QN];
  int qHead, qLen;
  /* pixels */
  uint32_t *shadow;
  int shW, shH, dirty0, dirty1;
  struct { int x, y, w, h; } clip, clipStack[8];
  int clipDepth;
  /* gestures */
  int64_t lastDownT;
  int lastDownX, lastDownY, clicks, pointerId, downButton;
  int lastDownButton;      /* (clicks are counted for one button at a time) */
  float wheelX, wheelY;    /* the wheel's turns not a notch yet (a touch pad's) */
  /* two fingers: their ids, their last middle and distance; a gesture over,
   * the finger left waits to be lifted (no new press) */
  int g2, g2a, g2b, g2wait;
  float g2x, g2y, g2d;
  int keyboardShown, reshow;
  /* from the Java side (UI thread), under mu */
  int insets[4], haveInsets;
  char *inbox;
  size_t inboxLen;
  /* JNI: cached classes and methods (global references) */
  jclass keyEventCls, paintCls, canvasCls, bitmapCls, clipDataCls,
         intentCls, uriCls;
  jmethodID keyEventInit, getUnicodeChar, keyboardMethod;
  /* UiRelaysActivity's services */
  jmethodID barsMethod, minimizeMethod, hasStorageMethod, askStorageMethod,
            openFileMethod, decodeImageMethod, callMethod;
  uint32_t barTop, barBottom;
  int barsKnown;
  jobject clipMgr, bitmapConfig;
  jmethodID getPrimaryClip, setPrimaryClip, getItemCount, getItemAt,
            coerceToText, toString, newPlainText;
  jmethodID paintInit, setTextSize, setColor, measureText, getAscent;
  jmethodID createBitmap, canvasInit, drawColor, drawText, getPixels,
            recycle;
  jmethodID intentInit, addFlags, uriParse, startActivity;
  jobject paint;                     /* reused Paint */
  int paintSize;
} g;

/* ---- the background check -------------------------------------------------
 * A job of the system (the app's JobService) may start this process with no
 * activity: the app's start (NimMain) then runs on a thread of its own, the
 * host, until the app registers its check (onBackgroundCheck) or asks for its
 * window, and waits there; the check runs on the job's thread. NimMain runs
 * once a process: an activity created later makes the host its app thread,
 * which goes on from where it waited. With the activity there first, the job
 * only runs the check, beside the app. Outside `g`, which every activity
 * clears. */

enum { BG_NONE, BG_STARTING, BG_PARKED, BG_APP, BG_ENDED };

static struct {
  pthread_mutex_t mu;
  pthread_cond_t cond;
  int nim;                 /* NimMain: 0 not run, 1 by the activity's thread, 2 by the host */
  int state;               /* the host's: BG_* */
  int appWanted;           /* an activity came: the host becomes its app thread */
  JavaVM *vm;
  JNIEnv *hostEnv;
  jclass cls;              /* the job's class */
  jmethodID call;          /* its static uirelaysCall: the Java parts without an activity */
  char dataDir[1024];      /* the app's files folder (the activity's internalDataPath) */
} bg = { PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER };

static __thread int bgIsHost;      /* this thread is the host */

/* The app's: runs its background check once, 1 when it ran (absent when the
 * app has none) */
extern int uirelays_background_check(void) __attribute__((weak));

/* 0x00RRGGBB -> the window's bytes R, G, B, X (0xFFBBGGRR) and back */
static inline uint32_t toWindow(uint32_t c) {
  return 0xFF000000u | ((c & 0xFF) << 16) | (c & 0xFF00) | ((c >> 16) & 0xFF);
}
static inline uint32_t fromWindow(uint32_t c) {
  return ((c & 0xFF) << 16) | (c & 0xFF00) | ((c >> 16) & 0xFF);
}

static int64_t nowMs(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

/* ---- the event queue (app thread only) --------------------------------- */

static UrEvent *push(int kind) {
  if (g.qLen == QN) { g.qHead = (g.qHead + 1) % QN; g.qLen--; }
  UrEvent *e = &g.q[(g.qHead + g.qLen) % QN];
  g.qLen++;
  memset(e, 0, sizeof *e);
  e->kind = kind;
  return e;
}

static UrEvent *lastQueued(void) {
  return g.qLen ? &g.q[(g.qHead + g.qLen - 1) % QN] : NULL;
}

static int pop(UrEvent *out) {
  if (!g.qLen) return 0;
  *out = g.q[g.qHead];
  g.qHead = (g.qHead + 1) % QN;
  g.qLen--;
  return 1;
}

static int g_mouse;          /* the pointer of the event being read is a mouse */
static int g_meta;           /* ... and the keyboard's modifiers with it (AMETA_*) */

/* An event's `meta`: the modifiers held, and 0x100 for a mouse or a pen
   (no AMETA_ bit is 0x100). */
static int pointerMeta(void) { return (g_meta & ~0x100) | (g_mouse ? 0x100 : 0); }

/* The pen of the event being read: pressure, tilt, azimuth, twist. */
static float g_pen[4] = {-1, 0, 0, 0};

static void penOf(AInputEvent *ev, size_t i) {
  /* a stylus (or its eraser end): how hard, how far it leans and which way */
  int tool = AMotionEvent_getToolType(ev, i);
  if (tool == AMOTION_EVENT_TOOL_TYPE_STYLUS || tool == AMOTION_EVENT_TOOL_TYPE_ERASER) {
    g_pen[0] = AMotionEvent_getPressure(ev, i);
    if (g_pen[0] < 0) g_pen[0] = 0;
    g_pen[1] = AMotionEvent_getAxisValue(ev, AMOTION_EVENT_AXIS_TILT, i);
    /* Android: 0 when the pen points up the screen, + to the right. */
    g_pen[2] = AMotionEvent_getAxisValue(ev, AMOTION_EVENT_AXIS_ORIENTATION, i) - 1.5707963f;
    g_pen[3] = tool == AMOTION_EVENT_TOOL_TYPE_ERASER ? -1 : 0;
  } else {
    g_pen[0] = -1; g_pen[1] = 0; g_pen[2] = 0; g_pen[3] = 0;
  }
}

static void withPen(UrEvent *e) {
  e->pressure = g_pen[0]; e->tilt = g_pen[1]; e->azimuth = g_pen[2]; e->twist = g_pen[3];
}

static void pushMove(int x, int y) {
  UrEvent *l = lastQueued();
  if (l && l->kind == UR_MOVE) {
    l->x = x; l->y = y; l->meta = pointerMeta();
    withPen(l);
    return;
  }
  UrEvent *e = push(UR_MOVE);
  e->x = x; e->y = y;
  e->meta = pointerMeta();
  withPen(e);
}

static void pushResize(void) {
  UrEvent *l = lastQueued();
  if (l && l->kind == UR_RESIZE) return;
  UrEvent *e = push(UR_RESIZE);
  e->x = g.winW; e->y = g.winH;
}

/* ---- JNI helpers --------------------------------------------------------- */

static int jniFailed(JNIEnv *env) {
  if ((*env)->ExceptionCheck(env)) {
    (*env)->ExceptionDescribe(env);
    (*env)->ExceptionClear(env);
    return 1;
  }
  return 0;
}

static jclass globalClass(JNIEnv *env, const char *name) {
  jclass c = (*env)->FindClass(env, name);
  if (!c || jniFailed(env)) { LOGE("class %s not found", name); return NULL; }
  jclass gc = (jclass)(*env)->NewGlobalRef(env, c);
  (*env)->DeleteLocalRef(env, c);
  return gc;
}

/* UTF-8 <-> Java strings (UTF-16, so emoji and Arabic survive intact). */
static jstring newString(JNIEnv *env, const char *s, int n) {
  jchar *u = (jchar *)malloc(sizeof(jchar) * (n + 1) * 2);
  int k = 0, i = 0;
  while (i < n) {
    uint32_t c = (unsigned char)s[i];
    int len = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
    if (i + len > n) break;
    if (len == 2) c = ((c & 0x1F) << 6) | (s[i+1] & 0x3F);
    else if (len == 3) c = ((c & 0x0F) << 12) | ((s[i+1] & 0x3F) << 6) | (s[i+2] & 0x3F);
    else if (len == 4) c = ((c & 0x07) << 18) | ((s[i+1] & 0x3F) << 12) |
                           ((s[i+2] & 0x3F) << 6) | (s[i+3] & 0x3F);
    i += len;
    if (c >= 0x10000) {
      c -= 0x10000;
      u[k++] = (jchar)(0xD800 + (c >> 10));
      u[k++] = (jchar)(0xDC00 + (c & 0x3FF));
    } else u[k++] = (jchar)c;
  }
  jstring r = (*env)->NewString(env, u, k);
  free(u);
  return r;
}

static int utf8Of(uint32_t c, char *out) {
  if (c < 0x80) { out[0] = (char)c; return 1; }
  if (c < 0x800) { out[0] = 0xC0 | (c >> 6); out[1] = 0x80 | (c & 0x3F); return 2; }
  if (c < 0x10000) {
    out[0] = 0xE0 | (c >> 12); out[1] = 0x80 | ((c >> 6) & 0x3F);
    out[2] = 0x80 | (c & 0x3F); return 3;
  }
  out[0] = 0xF0 | (c >> 18); out[1] = 0x80 | ((c >> 12) & 0x3F);
  out[2] = 0x80 | ((c >> 6) & 0x3F); out[3] = 0x80 | (c & 0x3F); return 4;
}

/* A Java string as malloc'ed UTF-8. */
static char *utf8String(JNIEnv *env, jstring s, int *outLen) {
  int n = (*env)->GetStringLength(env, s);
  const jchar *u = (*env)->GetStringChars(env, s, NULL);
  char *r = (char *)malloc(n * 4 + 1);
  int k = 0;
  for (int i = 0; i < n; i++) {
    uint32_t c = u[i];
    if (c >= 0xD800 && c < 0xDC00 && i + 1 < n && u[i+1] >= 0xDC00 && u[i+1] < 0xE000) {
      c = 0x10000 + ((c - 0xD800) << 10) + (u[i+1] - 0xDC00);
      i++;
    }
    k += utf8Of(c, r + k);
  }
  r[k] = 0;
  (*env)->ReleaseStringChars(env, s, u);
  *outLen = k;
  return r;
}

static void initJni(JNIEnv *env, jobject activity) {
  g.keyEventCls = globalClass(env, "android/view/KeyEvent");
  if (g.keyEventCls) {
    /* the 10-argument form keeps the device, so its keyboard layout is used */
    g.keyEventInit = (*env)->GetMethodID(env, g.keyEventCls, "<init>", "(JJIIIIIIII)V");
    g.getUnicodeChar = (*env)->GetMethodID(env, g.keyEventCls, "getUnicodeChar", "(I)I");
  }
  jclass objCls = (*env)->FindClass(env, "java/lang/Object");
  g.toString = (*env)->GetMethodID(env, objCls, "toString", "()Ljava/lang/String;");
  (*env)->DeleteLocalRef(env, objCls);
  /* clipboard: the manager is made here, on the UI thread, which has a Looper */
  jclass actCls = (*env)->GetObjectClass(env, activity);
  jmethodID getSvc = (*env)->GetMethodID(env, actCls, "getSystemService",
                                         "(Ljava/lang/String;)Ljava/lang/Object;");
  g.startActivity = (*env)->GetMethodID(env, actCls, "startActivity",
                                        "(Landroid/content/Intent;)V");
  jstring name = (*env)->NewStringUTF(env, "clipboard");
  jobject cm = (*env)->CallObjectMethod(env, activity, getSvc, name);
  (*env)->DeleteLocalRef(env, name);
  if (!jniFailed(env) && cm) {
    g.clipMgr = (*env)->NewGlobalRef(env, cm);
    jclass cmCls = (*env)->GetObjectClass(env, cm);
    g.getPrimaryClip = (*env)->GetMethodID(env, cmCls, "getPrimaryClip",
                                           "()Landroid/content/ClipData;");
    g.setPrimaryClip = (*env)->GetMethodID(env, cmCls, "setPrimaryClip",
                                           "(Landroid/content/ClipData;)V");
    (*env)->DeleteLocalRef(env, cmCls);
    (*env)->DeleteLocalRef(env, cm);
  }
  (*env)->DeleteLocalRef(env, actCls);
  g.clipDataCls = globalClass(env, "android/content/ClipData");
  if (g.clipDataCls) {
    g.getItemCount = (*env)->GetMethodID(env, g.clipDataCls, "getItemCount", "()I");
    g.getItemAt = (*env)->GetMethodID(env, g.clipDataCls, "getItemAt",
                                      "(I)Landroid/content/ClipData$Item;");
    g.newPlainText = (*env)->GetStaticMethodID(env, g.clipDataCls, "newPlainText",
      "(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Landroid/content/ClipData;");
    jclass itemCls = (*env)->FindClass(env, "android/content/ClipData$Item");
    g.coerceToText = (*env)->GetMethodID(env, itemCls, "coerceToText",
      "(Landroid/content/Context;)Ljava/lang/CharSequence;");
    (*env)->DeleteLocalRef(env, itemCls);
  }
  /* text with the system font: Paint, Canvas, Bitmap */
  g.paintCls = globalClass(env, "android/graphics/Paint");
  g.canvasCls = globalClass(env, "android/graphics/Canvas");
  g.bitmapCls = globalClass(env, "android/graphics/Bitmap");
  if (g.paintCls && g.canvasCls && g.bitmapCls) {
    g.paintInit = (*env)->GetMethodID(env, g.paintCls, "<init>", "(I)V");
    g.setTextSize = (*env)->GetMethodID(env, g.paintCls, "setTextSize", "(F)V");
    g.setColor = (*env)->GetMethodID(env, g.paintCls, "setColor", "(I)V");
    g.measureText = (*env)->GetMethodID(env, g.paintCls, "measureText",
                                        "(Ljava/lang/String;)F");
    g.getAscent = (*env)->GetMethodID(env, g.paintCls, "ascent", "()F");
    g.canvasInit = (*env)->GetMethodID(env, g.canvasCls, "<init>",
                                       "(Landroid/graphics/Bitmap;)V");
    g.drawColor = (*env)->GetMethodID(env, g.canvasCls, "drawColor", "(I)V");
    g.drawText = (*env)->GetMethodID(env, g.canvasCls, "drawText",
                                     "(Ljava/lang/String;FFLandroid/graphics/Paint;)V");
    g.createBitmap = (*env)->GetStaticMethodID(env, g.bitmapCls, "createBitmap",
      "(IILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;");
    g.getPixels = (*env)->GetMethodID(env, g.bitmapCls, "getPixels", "([IIIIIII)V");
    g.recycle = (*env)->GetMethodID(env, g.bitmapCls, "recycle", "()V");
    jclass cfgCls = (*env)->FindClass(env, "android/graphics/Bitmap$Config");
    jfieldID f = (*env)->GetStaticFieldID(env, cfgCls, "ARGB_8888",
                                          "Landroid/graphics/Bitmap$Config;");
    jobject cfg = (*env)->GetStaticObjectField(env, cfgCls, f);
    g.bitmapConfig = (*env)->NewGlobalRef(env, cfg);
    (*env)->DeleteLocalRef(env, cfg);
    (*env)->DeleteLocalRef(env, cfgCls);
  }
  /* links */
  g.intentCls = globalClass(env, "android/content/Intent");
  g.uriCls = globalClass(env, "android/net/Uri");
  if (g.intentCls && g.uriCls) {
    g.intentInit = (*env)->GetMethodID(env, g.intentCls, "<init>",
                                       "(Ljava/lang/String;Landroid/net/Uri;)V");
    g.addFlags = (*env)->GetMethodID(env, g.intentCls, "addFlags",
                                     "(I)Landroid/content/Intent;");
    g.uriParse = (*env)->GetStaticMethodID(env, g.uriCls, "parse",
                                           "(Ljava/lang/String;)Landroid/net/Uri;");
  }
  jniFailed(env);
}

/* The character a key press types, from KeyEvent.getUnicodeChar. */
static int unicodeChar(AInputEvent *ev) {
  JNIEnv *env = g.env;
  if (!env || !g.keyEventInit) return 0;
  (*env)->PushLocalFrame(env, 4);
  jobject ke = (*env)->NewObject(env, g.keyEventCls, g.keyEventInit,
                                 (jlong)(AKeyEvent_getDownTime(ev) / 1000000),
                                 (jlong)(AKeyEvent_getEventTime(ev) / 1000000),
                                 (jint)AKeyEvent_getAction(ev),
                                 (jint)AKeyEvent_getKeyCode(ev),
                                 (jint)AKeyEvent_getRepeatCount(ev),
                                 (jint)AKeyEvent_getMetaState(ev),
                                 (jint)AInputEvent_getDeviceId(ev),
                                 (jint)AKeyEvent_getScanCode(ev),
                                 (jint)AKeyEvent_getFlags(ev),
                                 (jint)AInputEvent_getSource(ev));
  int c = 0;
  if (ke && !jniFailed(env))
    c = (*env)->CallIntMethod(env, ke, g.getUnicodeChar,
                              (jint)AKeyEvent_getMetaState(ev));
  jniFailed(env);
  (*env)->PopLocalFrame(env, NULL);
  return c;
}


/* Text from the Java side (a soft keyboard's characters without key codes):
 * a key press, then a text event per character. App thread. */
static void takeInbox(void) {
  pthread_mutex_lock(&g.mu);
  char *u = g.inbox;
  size_t n = g.inboxLen;
  g.inbox = NULL;
  g.inboxLen = 0;
  pthread_mutex_unlock(&g.mu);
  if (!u) return;
  push(UR_KEYDOWN);
  for (size_t i = 0; i < n;) {
    unsigned char c = (unsigned char)u[i];
    size_t len = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
    if (i + len > n) break;
    UrEvent *t = push(UR_TEXT);
    memcpy(t->text, u + i, len);
    i += len;
  }
  free(u);
}

static void writeCmd(int8_t cmd);

/* UiRelaysActivity.nativeText, on the UI thread */
static void JNICALL nativeText(JNIEnv *env, jclass cls, jstring s) {
  (void)cls;
  if (!s) return;
  int n = 0;
  char *u = utf8String(env, s, &n);
  pthread_mutex_lock(&g.mu);
  char *grown = (char *)realloc(g.inbox, g.inboxLen + (size_t)n + 1);
  if (grown) {
    memcpy(grown + g.inboxLen, u, (size_t)n);
    g.inbox = grown;
    g.inboxLen += (size_t)n;
  }
  pthread_mutex_unlock(&g.mu);
  free(u);
  writeCmd(CMD_TEXT);
}

/* UiRelaysActivity.nativeInsets, on the UI thread: system bars + keyboard */
static void JNICALL nativeInsets(JNIEnv *env, jclass cls, jint top, jint left,
                                 jint bottom, jint right) {
  (void)env; (void)cls;
  pthread_mutex_lock(&g.mu);
  g.insets[0] = top; g.insets[1] = left; g.insets[2] = bottom; g.insets[3] = right;
  g.haveInsets = 1;
  pthread_mutex_unlock(&g.mu);
  writeCmd(CMD_RECT);
}

static void registerNatives(JNIEnv *env, jobject activity) {
  jclass cls = (*env)->GetObjectClass(env, activity);
  if (!cls) return;
  JNINativeMethod m[] = {
    { "nativeText", "(Ljava/lang/String;)V", (void *)nativeText },
    { "nativeInsets", "(IIII)V", (void *)nativeInsets },
  };
  if ((*env)->RegisterNatives(env, cls, m, 2) != 0) jniFailed(env);   /* plain NativeActivity */
  g.keyboardMethod = (*env)->GetMethodID(env, cls, "keyboard", "(Z)V");
  if (!g.keyboardMethod) jniFailed(env);
  struct { jmethodID *m; const char *name, *sig; } ms[] = {
    { &g.barsMethod, "systemBars", "(II)V" },
    { &g.minimizeMethod, "minimize", "()V" },
    { &g.hasStorageMethod, "hasStorage", "()Z" },
    { &g.askStorageMethod, "askStorage", "()V" },
    { &g.openFileMethod, "openFile", "(Ljava/lang/String;I)Z" },
    { &g.decodeImageMethod, "decodeImage", "(Ljava/lang/String;II)[I" },
    { &g.callMethod, "uirelaysCall", "(Ljava/lang/String;Ljava/lang/String;)[B" },
  };
  for (size_t i = 0; i < sizeof ms / sizeof ms[0]; i++) {
    *ms[i].m = (*env)->GetMethodID(env, cls, ms[i].name, ms[i].sig);
    if (!*ms[i].m) jniFailed(env);       /* a plain NativeActivity */
  }
  (*env)->DeleteLocalRef(env, cls);
}

/* ---- services for the Nim side ------------------------------------------- */

char *uirelays_clipboard_get(int *len) {
  JNIEnv *env = g.env;
  *len = 0;
  if (!env || !g.clipMgr || !g.getPrimaryClip) return NULL;
  char *r = NULL;
  (*env)->PushLocalFrame(env, 8);
  jobject clip = (*env)->CallObjectMethod(env, g.clipMgr, g.getPrimaryClip);
  if (!jniFailed(env) && clip &&
      (*env)->CallIntMethod(env, clip, g.getItemCount) > 0) {
    jobject item = (*env)->CallObjectMethod(env, clip, g.getItemAt, 0);
    if (!jniFailed(env) && item) {
      jobject cs = (*env)->CallObjectMethod(env, item, g.coerceToText,
                                            g.activity->clazz);
      if (!jniFailed(env) && cs) {
        jstring s = (jstring)(*env)->CallObjectMethod(env, cs, g.toString);
        if (!jniFailed(env) && s) r = utf8String(env, s, len);
      }
    }
  }
  jniFailed(env);
  (*env)->PopLocalFrame(env, NULL);
  return r;
}

void uirelays_clipboard_put(const char *s, int n) {
  JNIEnv *env = g.env;
  if (!env || !g.clipMgr || !g.newPlainText) return;
  (*env)->PushLocalFrame(env, 8);
  jstring label = (*env)->NewStringUTF(env, "text");
  jstring text = newString(env, s, n);
  jobject clip = (*env)->CallStaticObjectMethod(env, g.clipDataCls, g.newPlainText,
                                                label, text);
  if (!jniFailed(env) && clip)
    (*env)->CallVoidMethod(env, g.clipMgr, g.setPrimaryClip, clip);
  jniFailed(env);
  (*env)->PopLocalFrame(env, NULL);
}

int uirelays_open_url(const char *s, int n) {
  JNIEnv *env = g.env;
  if (!env || !g.intentInit || !g.startActivity) return 0;
  int ok = 0;
  (*env)->PushLocalFrame(env, 8);
  jstring us = newString(env, s, n);
  jobject uri = (*env)->CallStaticObjectMethod(env, g.uriCls, g.uriParse, us);
  if (!jniFailed(env) && uri) {
    jstring action = (*env)->NewStringUTF(env, "android.intent.action.VIEW");
    jobject intent = (*env)->NewObject(env, g.intentCls, g.intentInit, action, uri);
    if (!jniFailed(env) && intent) {
      (*env)->CallObjectMethod(env, intent, g.addFlags, (jint)0x10000000);
      (*env)->CallVoidMethod(env, g.activity->clazz, g.startActivity, intent);
      ok = !jniFailed(env);   /* ActivityNotFoundException: nothing opens it */
    }
  }
  jniFailed(env);
  (*env)->PopLocalFrame(env, NULL);
  return ok;
}

const char *uirelays_data_dir(void) {
  if (g.activity && g.activity->internalDataPath) return g.activity->internalDataPath;
  return bg.dataDir;     /* a background check's process: the job told it */
}

int uirelays_sdk(void) { return g.activity ? g.activity->sdkVersion : 0; }

void uirelays_keyboard(int show) {
  /* asked again after every touch while a field wants text: the user may
   * have closed the keyboard (Back, its own key) without the app knowing */
  int again = show && g.reshow;
  g.reshow = 0;
  if (!g.activity || (show == g.keyboardShown && !again)) return;
  g.keyboardShown = show;
  if (g.keyboardMethod && g.env) {         /* UiRelaysActivity.keyboard */
    (*g.env)->CallVoidMethod(g.env, g.activity->clazz, g.keyboardMethod,
                             (jboolean)(show != 0));
    if (!jniFailed(g.env)) return;
  }
  if (show) ANativeActivity_showSoftInput(g.activity, 0);
  else ANativeActivity_hideSoftInput(g.activity, 0);
}

/* ---- UiRelaysActivity's services (app thread) ------------------------------- */

int uirelays_minimize(void) {
  if (!g.env || !g.minimizeMethod) return 0;
  (*g.env)->CallVoidMethod(g.env, g.activity->clazz, g.minimizeMethod);
  return !jniFailed(g.env);
}

int uirelays_has_storage(void) {
  if (!g.env || !g.hasStorageMethod) return 1;   /* nothing to ask then */
  jboolean b = (*g.env)->CallBooleanMethod(g.env, g.activity->clazz, g.hasStorageMethod);
  return jniFailed(g.env) ? 0 : b != 0;
}

void uirelays_ask_storage(void) {
  if (!g.env || !g.askStorageMethod) return;
  (*g.env)->CallVoidMethod(g.env, g.activity->clazz, g.askStorageMethod);
  jniFailed(g.env);
}

/* mode 0: open in its app, 1: choose the app, 2: share */
int uirelays_open_file(const char *path, int n, int mode) {
  JNIEnv *env = g.env;
  if (!env || !g.openFileMethod) return 0;
  (*env)->PushLocalFrame(env, 4);
  jstring js = newString(env, path, n);
  jboolean ok = (*env)->CallBooleanMethod(env, g.activity->clazz, g.openFileMethod,
                                         js, (jint)mode);
  if (jniFailed(env)) ok = 0;
  (*env)->PopLocalFrame(env, NULL);
  return ok != 0;
}

/* A photo through BitmapFactory, upright: malloc'ed 0xAARRGGBB pixels. */
/* The JNI environment of the calling thread: worker threads (pictures
 * decoded in the background) are attached on their first call and stay
 * attached; they live as long as the app. Without an activity (a
 * background check), the job's Java VM. */
static JNIEnv *threadEnv(void) {
  if (g.env && pthread_equal(pthread_self(), g.appThread)) return g.env;
  ANativeActivity *a = g.activity;
  JavaVM *vm = a && a->vm ? a->vm : bg.vm;
  if (!vm) return NULL;
  JNIEnv *env = NULL;
  jint r = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6);
  if (r == JNI_EDETACHED &&
      (*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK) return NULL;
  return env;
}

uint32_t *uirelays_decode_image(const char *path, int n, int maxW, int maxH,
                           int *w, int *h) {
  JNIEnv *env = threadEnv();
  *w = *h = 0;
  if (!env || !g.decodeImageMethod || !g.activity) return NULL;
  uint32_t *px = NULL;
  (*env)->PushLocalFrame(env, 4);
  jstring js = newString(env, path, n);
  jintArray arr = (jintArray)(*env)->CallObjectMethod(env, g.activity->clazz,
      g.decodeImageMethod, js, (jint)maxW, (jint)maxH);
  if (!jniFailed(env) && arr) {
    jsize len = (*env)->GetArrayLength(env, arr);
    if (len >= 2) {
      jint head[2];
      (*env)->GetIntArrayRegion(env, arr, 0, 2, head);
      if (head[0] > 0 && head[1] > 0 && (jlong)head[0] * head[1] == (jlong)len - 2) {
        px = (uint32_t *)malloc((size_t)(len - 2) * 4);
        if (px) {
          (*env)->GetIntArrayRegion(env, arr, 2, len - 2, (jint *)px);
          *w = head[0];
          *h = head[1];
        }
      }
    }
  }
  jniFailed(env);
  (*env)->PopLocalFrame(env, NULL);
  return px;
}

/* A call into the activity's uirelaysCall (documents of other apps, ...):
 * malloc'ed UTF-8 text in *len bytes, NULL when it failed. Any thread. */
char *uirelays_call(const char *name, int nn, const char *arg, int na, int *len) {
  JNIEnv *env = threadEnv();
  *len = 0;
  /* no activity (a background check), or one not set up yet:
   * the job class's static uirelaysCall */
  int viaJob = bg.cls && bg.call && (!g.activity || !g.callMethod);
  if (!env || (!viaJob && (!g.callMethod || !g.activity))) return NULL;
  char *out = NULL;
  (*env)->PushLocalFrame(env, 4);
  jstring jn = newString(env, name, nn);
  jstring ja = newString(env, arg, na);
  jbyteArray r = viaJob
      ? (jbyteArray)(*env)->CallStaticObjectMethod(env, bg.cls, bg.call, jn, ja)
      : (jbyteArray)(*env)->CallObjectMethod(env, g.activity->clazz, g.callMethod, jn, ja);
  if (!jniFailed(env) && r) {
    jsize n = (*env)->GetArrayLength(env, r);
    out = (char *)malloc((size_t)n + 1);
    if (out) {
      (*env)->GetByteArrayRegion(env, r, 0, n, (jbyte *)out);
      out[n] = 0;
      *len = n;
    }
  }
  jniFailed(env);
  (*env)->PopLocalFrame(env, NULL);
  return out;
}

/* The status and navigation bars take the colors drawn under them. */
static void syncSystemBars(void) {
  if (!g.shadow || !g.env || !g.barsMethod || g.shH < 2) return;
  int top = g.haveInsets ? g.insets[0] : g.rect.top;
  int bottom = g.haveInsets ? g.insets[2] : (g.winH - g.rect.bottom);
  int yt = top > 0 ? top / 2 : 0;
  int yb = bottom > 0 ? g.shH - 1 - bottom / 2 : g.shH - 1;
  if (yb < 0) yb = 0;
  if (yt >= g.shH) yt = g.shH - 1;
  if (yb >= g.shH) yb = g.shH - 1;
  uint32_t t = fromWindow(g.shadow[(size_t)yt * g.shW + g.shW / 2]);
  uint32_t b = fromWindow(g.shadow[(size_t)yb * g.shW + g.shW / 2]);
  if (g.barsKnown && t == g.barTop && b == g.barBottom) return;
  g.barsKnown = 1;
  g.barTop = t;
  g.barBottom = b;
  (*g.env)->CallVoidMethod(g.env, g.activity->clazz, g.barsMethod, (jint)t, (jint)b);
  jniFailed(g.env);
}

void uirelays_finish(void) {
  if (g.activity && !g.destroyRequested) ANativeActivity_finish(g.activity);
}

void uirelays_layout(int *w, int *h, int *density, int *top, int *left,
                int *bottom, int *right) {
  pthread_mutex_lock(&g.mu);
  *w = g.winW;
  *h = g.winH;
  *density = g.density > 0 ? g.density : 160;
  ARect r = g.rect;
  int have = g.haveInsets;
  int in[4] = { g.insets[0], g.insets[1], g.insets[2], g.insets[3] };
  pthread_mutex_unlock(&g.mu);
  if (have) {                    /* from UiRelaysActivity: bars and keyboard */
    *top = in[0]; *left = in[1]; *bottom = in[2]; *right = in[3];
  } else if (r.right > r.left && r.bottom > r.top) {
    *top = r.top; *left = r.left;
    *bottom = g.winH - r.bottom; *right = g.winW - r.right;
    if (*bottom < 0) *bottom = 0;
    if (*right < 0) *right = 0;
  } else {
    *top = *left = *bottom = *right = 0;
  }
}

int64_t uirelays_ticks(void) { return nowMs(); }

/* ---- pixels ---------------------------------------------------------------- */

static void ensureShadow(void) {
  if (g.shW == g.winW && g.shH == g.winH && g.shadow) return;
  free(g.shadow);
  g.shW = g.winW > 0 ? g.winW : 1;
  g.shH = g.winH > 0 ? g.winH : 1;
  g.shadow = (uint32_t *)calloc((size_t)g.shW * g.shH, 4);
  g.dirty0 = 0;
  g.dirty1 = g.shH;
}

static void markDirty(int y0, int y1) {
  if (y0 < 0) y0 = 0;
  if (y1 > g.shH) y1 = g.shH;
  if (y0 >= y1) return;
  if (g.dirty0 >= g.dirty1) { g.dirty0 = y0; g.dirty1 = y1; return; }
  if (y0 < g.dirty0) g.dirty0 = y0;
  if (y1 > g.dirty1) g.dirty1 = y1;
}

/* Copy w*h pixels (0x00RRGGBB) to (dx, dy) of the frame, which is kept in
 * the window's format: putting it on the screen is then a plain copy. */
int uirelays_blit(const uint32_t *p, int w, int h, int dx, int dy) {
  ensureShadow();
  int x0 = dx < 0 ? 0 : dx, x1 = dx + w > g.shW ? g.shW : dx + w;
  int y0 = dy < 0 ? 0 : dy, y1 = dy + h > g.shH ? g.shH : dy + h;
  if (x0 >= x1 || y0 >= y1) return 1;
  for (int y = y0; y < y1; y++) {
    uint32_t *dst = g.shadow + (size_t)y * g.shW + x0;
    const uint32_t *src = p + (size_t)(y - dy) * w + (x0 - dx);
    for (int x = 0; x < x1 - x0; x++) dst[x] = toWindow(src[x]);
  }
  markDirty(y0, y1);
  return 1;
}

/* Fill a rectangle of the frame, inside the clip, with a 0xAARRGGBB
 * color; one that is not opaque is blended over what is there. */
void uirelays_fill(int x, int y, int w, int h, uint32_t c) {
  ensureShadow();
  uint32_t a = c >> 24;
  if (a == 0 || w <= 0 || h <= 0) return;
  int x0 = x, y0 = y, x1 = x + w, y1 = y + h;
  if (g.clip.w > 0 && g.clip.h > 0) {
    if (x0 < g.clip.x) x0 = g.clip.x;
    if (y0 < g.clip.y) y0 = g.clip.y;
    if (x1 > g.clip.x + g.clip.w) x1 = g.clip.x + g.clip.w;
    if (y1 > g.clip.y + g.clip.h) y1 = g.clip.y + g.clip.h;
  }
  if (x0 < 0) x0 = 0;
  if (y0 < 0) y0 = 0;
  if (x1 > g.shW) x1 = g.shW;
  if (y1 > g.shH) y1 = g.shH;
  if (x0 >= x1 || y0 >= y1) return;
  uint32_t solid = toWindow(c & 0xFFFFFF);
  for (int yy = y0; yy < y1; yy++) {
    uint32_t *dst = g.shadow + (size_t)yy * g.shW;
    for (int xx = x0; xx < x1; xx++) {
      if (a == 255) { dst[xx] = solid; continue; }
      uint32_t d = fromWindow(dst[xx]), r = 0;
      for (int s = 0; s <= 16; s += 8) {
        uint32_t cs = (c >> s) & 0xFF, ds = (d >> s) & 0xFF;
        r |= ((cs * a + ds * (255 - a) + 127) / 255) << s;
      }
      dst[xx] = toWindow(r);
    }
  }
  markDirty(y0, y1);
}

/* Put the changed rows of the frame on the screen. */
void uirelays_refresh(void) {
  /* g.window changes only on this (the app) thread: no lock, so a slow
   * buffer swap never stalls the UI thread */
  ANativeWindow *win = g.window;
  if (!win || !g.shadow || g.dirty0 >= g.dirty1) return;
  ANativeWindow_Buffer buf;
  ARect dirty = { 0, g.dirty0, g.shW, g.dirty1 };
  if (ANativeWindow_lock(win, &buf, &dirty) == 0) {
    /* the system may ask for more than we changed: copy all it wants */
    int top = dirty.top < 0 ? 0 : dirty.top;
    int bottom = dirty.bottom > buf.height ? buf.height : dirty.bottom;
    int w = buf.width < g.shW ? buf.width : g.shW;
    for (int y = top; y < bottom; y++) {
      uint32_t *dst = (uint32_t *)buf.bits + (size_t)y * buf.stride;
      if (y >= g.shH) { memset(dst, 0x80, (size_t)buf.width * 4); continue; }
      memcpy(dst, g.shadow + (size_t)y * g.shW, (size_t)w * 4);
      if (buf.width > w) memset(dst + w, 0x80, (size_t)(buf.width - w) * 4);
    }
    ANativeWindow_unlockAndPost(win);
    g.dirty0 = g.dirty1 = 0;
  }
  syncSystemBars();
}

void uirelays_clip(int x, int y, int w, int h) {
  g.clip.x = x; g.clip.y = y; g.clip.w = w; g.clip.h = h;
}
void uirelays_save(void) { if (g.clipDepth < 8) g.clipStack[g.clipDepth++] = g.clip; }
void uirelays_restore(void) { if (g.clipDepth > 0) g.clip = g.clipStack[--g.clipDepth]; }

static void usePaint(JNIEnv *env, int size) {
  if (!g.paint) {
    jobject p = (*env)->NewObject(env, g.paintCls, g.paintInit, (jint)1 /* ANTI_ALIAS */);
    if (jniFailed(env) || !p) return;
    g.paint = (*env)->NewGlobalRef(env, p);
    (*env)->DeleteLocalRef(env, p);
    g.paintSize = 0;
  }
  if (g.paintSize != size) {
    (*env)->CallVoidMethod(env, g.paint, g.setTextSize, (jfloat)(size * 10 / 13.0f));
    g.paintSize = size;
  }
}

/* Width in pixels of UTF-8 text in the system font, `size` pixels a line. */
int uirelays_text_width(const char *s, int n, int size) {
  JNIEnv *env = g.env;
  if (!env || !g.paintInit || n <= 0) return 0;
  (*env)->PushLocalFrame(env, 4);
  usePaint(env, size);
  int w = 0;
  if (g.paint) {
    jstring js = newString(env, s, n);
    w = (int)((*env)->CallFloatMethod(env, g.paint, g.measureText, js) + 0.99f);
  }
  jniFailed(env);
  (*env)->PopLocalFrame(env, NULL);
  return w;
}

/* Draw text with the system font -- Android shapes and orders Arabic and
 * other scripts -- on `bg` at (x, y) of the frame, inside the clip. */
int uirelays_text_draw(const char *s, int n, int size, int x, int y, uint32_t fg,
                  uint32_t bg) {
  JNIEnv *env = g.env;
  if (!env || !g.paintInit || !g.bitmapConfig || n <= 0) return 0;
  ensureShadow();
  int w = uirelays_text_width(s, n, size);
  int h = size;
  if (w <= 0) return 0;
  int cx0 = g.clip.w > 0 ? g.clip.x : 0, cy0 = g.clip.h > 0 ? g.clip.y : 0;
  int cx1 = g.clip.w > 0 ? g.clip.x + g.clip.w : g.shW;
  int cy1 = g.clip.h > 0 ? g.clip.y + g.clip.h : g.shH;
  if (cx0 < 0) cx0 = 0;
  if (cy0 < 0) cy0 = 0;
  if (cx1 > g.shW) cx1 = g.shW;
  if (cy1 > g.shH) cy1 = g.shH;
  if (x >= cx1 || y >= cy1 || x + w <= cx0 || y + h <= cy0) return w;
  (*env)->PushLocalFrame(env, 8);
  usePaint(env, size);
  jobject bmp = (*env)->CallStaticObjectMethod(env, g.bitmapCls, g.createBitmap,
                                               (jint)w, (jint)h, g.bitmapConfig);
  if (!jniFailed(env) && bmp) {
    jobject canvas = (*env)->NewObject(env, g.canvasCls, g.canvasInit, bmp);
    if (!jniFailed(env) && canvas) {
      (*env)->CallVoidMethod(env, canvas, g.drawColor, (jint)(0xFF000000u | bg));
      (*env)->CallVoidMethod(env, g.paint, g.setColor, (jint)(0xFF000000u | fg));
      jstring js = newString(env, s, n);
      (*env)->CallVoidMethod(env, canvas, g.drawText, js, 0.0f,
                             (jfloat)(size * 11 / 13.0f), g.paint);
      jintArray arr = (*env)->NewIntArray(env, w * h);
      if (!jniFailed(env) && arr) {
        (*env)->CallVoidMethod(env, bmp, g.getPixels, arr, 0, w, 0, 0, w, h);
        if (!jniFailed(env)) {
          jint *px = (*env)->GetIntArrayElements(env, arr, NULL);
          for (int j = 0; j < h; j++) {
            int yy = y + j;
            if (yy < cy0 || yy >= cy1) continue;
            for (int i = 0; i < w; i++) {
              int xx = x + i;
              if (xx < cx0 || xx >= cx1) continue;
              g.shadow[(size_t)yy * g.shW + xx] = toWindow((uint32_t)px[j * w + i] & 0xFFFFFF);
            }
          }
          (*env)->ReleaseIntArrayElements(env, arr, px, JNI_ABORT);
          markDirty(y, y + h);
        }
      }
    }
    (*env)->CallVoidMethod(env, bmp, g.recycle);
  }
  jniFailed(env);
  (*env)->PopLocalFrame(env, NULL);
  return w;
}

/* The run as `uirelays_text_draw` draws it, on transparency instead of the
 * frame (renderText: the toolkit blends it into its frame itself, under
 * what is drawn over it, or puts it on the GPU): w x h premultiplied ARGB
 * pixels in `*out` (malloc'd: the caller frees them); returns the width,
 * 0 for none. */
int uirelays_text_render(const char *s, int n, int size, uint32_t fg, uint32_t **out, int *outH) {
  JNIEnv *env = g.env;
  *out = NULL;
  *outH = 0;
  if (!env || !g.paintInit || !g.bitmapConfig || n <= 0) return 0;
  int w = uirelays_text_width(s, n, size);
  int h = size;
  if (w <= 0 || h <= 0) return 0;
  int done = 0;
  (*env)->PushLocalFrame(env, 8);
  usePaint(env, size);
  jobject bmp = (*env)->CallStaticObjectMethod(env, g.bitmapCls, g.createBitmap,
                                               (jint)w, (jint)h, g.bitmapConfig);
  if (!jniFailed(env) && bmp) {
    jobject canvas = (*env)->NewObject(env, g.canvasCls, g.canvasInit, bmp);
    if (!jniFailed(env) && canvas) {
      (*env)->CallVoidMethod(env, g.paint, g.setColor, (jint)(0xFF000000u | fg));
      jstring js = newString(env, s, n);
      (*env)->CallVoidMethod(env, canvas, g.drawText, js, 0.0f,
                             (jfloat)(size * 11 / 13.0f), g.paint);
      jintArray arr = (*env)->NewIntArray(env, w * h);
      if (!jniFailed(env) && arr) {
        (*env)->CallVoidMethod(env, bmp, g.getPixels, arr, 0, w, 0, 0, w, h);
        if (!jniFailed(env)) {
          uint32_t *p = (uint32_t *)malloc((size_t)w * h * 4);
          jint *px = (*env)->GetIntArrayElements(env, arr, NULL);
          if (p && px) {
            /* getPixels gives them unpremultiplied. */
            for (int i = 0; i < w * h; i++) {
              uint32_t v = (uint32_t)px[i];
              uint32_t a = v >> 24;
              uint32_t r = ((v >> 16) & 255) * a / 255;
              uint32_t gg = ((v >> 8) & 255) * a / 255;
              uint32_t b = (v & 255) * a / 255;
              p[i] = (a << 24) | (r << 16) | (gg << 8) | b;
            }
            *out = p;
            *outH = h;
            done = 1;
          } else if (p) free(p);
          if (px) (*env)->ReleaseIntArrayElements(env, arr, px, JNI_ABORT);
        }
      }
    }
    (*env)->CallVoidMethod(env, bmp, g.recycle);
  }
  jniFailed(env);
  (*env)->PopLocalFrame(env, NULL);
  return done ? w : 0;
}

/* ---- commands from the UI thread, run on the app thread ---------------------- */

static void readDensity(void) {
  if (!g.config) g.config = AConfiguration_new();
  AConfiguration_fromAssetManager(g.config, g.activity->assetManager);
  int d = AConfiguration_getDensity(g.config);
  g.density = (d <= 0 || d == ACONFIGURATION_DENSITY_ANY ||
               d == ACONFIGURATION_DENSITY_NONE) ? 160 : d;
}


/* ---- OpenGL ES (EGL) ------------------------------------------------------
 * When the app draws with the GPU: an EGL context on the window instead of
 * ANativeWindow_lock. libEGL and libGLESv2 are opened at run time (no NDK
 * headers, nothing linked); the surface follows the window as it comes and
 * goes, and a context the system lost is made again (the app then draws
 * everything anew). */

typedef void *EGLDisplay_, *EGLConfig_, *EGLContext_, *EGLSurface_;
typedef int32_t EGLint_;
typedef unsigned int EGLBoolean_;

#define R_EGL_NONE 0x3038
#define R_EGL_SURFACE_TYPE 0x3033
#define R_EGL_WINDOW_BIT 0x0004
#define R_EGL_RENDERABLE_TYPE 0x3040
#define R_EGL_OPENGL_ES2_BIT 0x0004
#define R_EGL_RED_SIZE 0x3024
#define R_EGL_GREEN_SIZE 0x3023
#define R_EGL_BLUE_SIZE 0x3022
#define R_EGL_ALPHA_SIZE 0x3021
#define R_EGL_DEPTH_SIZE 0x3025
#define R_EGL_NATIVE_VISUAL_ID 0x302E
#define R_EGL_CONTEXT_CLIENT_VERSION 0x3098
#define R_EGL_CONTEXT_LOST 0x300E

static struct {
  void *lib, *gles;
  EGLDisplay_ dpy;
  EGLConfig_ cfg;
  EGLContext_ ctx;
  EGLSurface_ surf;
  int on, gen;
  EGLDisplay_ (*GetDisplay)(void *);
  EGLBoolean_ (*Initialize)(EGLDisplay_, EGLint_ *, EGLint_ *);
  EGLBoolean_ (*ChooseConfig)(EGLDisplay_, const EGLint_ *, EGLConfig_ *, EGLint_, EGLint_ *);
  EGLBoolean_ (*GetConfigAttrib)(EGLDisplay_, EGLConfig_, EGLint_, EGLint_ *);
  EGLContext_ (*CreateContext)(EGLDisplay_, EGLConfig_, EGLContext_, const EGLint_ *);
  EGLSurface_ (*CreateWindowSurface)(EGLDisplay_, EGLConfig_, void *, const EGLint_ *);
  EGLBoolean_ (*MakeCurrent)(EGLDisplay_, EGLSurface_, EGLSurface_, EGLContext_);
  EGLBoolean_ (*SwapBuffers)(EGLDisplay_, EGLSurface_);
  EGLBoolean_ (*SwapInterval)(EGLDisplay_, EGLint_);
  EGLBoolean_ (*DestroySurface)(EGLDisplay_, EGLSurface_);
  EGLBoolean_ (*DestroyContext)(EGLDisplay_, EGLContext_);
  EGLBoolean_ (*Terminate)(EGLDisplay_);
  EGLint_ (*GetError)(void);
  void *(*GetProcAddress)(const char *);
} gl;

static int glLoad(void) {
  if (gl.lib) return 1;
  gl.lib = dlopen("libEGL.so", RTLD_NOW | RTLD_LOCAL);
  if (!gl.lib) return 0;
#define SYM(f, n) if (!(*(void **)&gl.f = dlsym(gl.lib, n))) return 0
  SYM(GetDisplay, "eglGetDisplay"); SYM(Initialize, "eglInitialize");
  SYM(ChooseConfig, "eglChooseConfig"); SYM(GetConfigAttrib, "eglGetConfigAttrib");
  SYM(CreateContext, "eglCreateContext"); SYM(CreateWindowSurface, "eglCreateWindowSurface");
  SYM(MakeCurrent, "eglMakeCurrent"); SYM(SwapBuffers, "eglSwapBuffers");
  SYM(SwapInterval, "eglSwapInterval"); SYM(DestroySurface, "eglDestroySurface");
  SYM(DestroyContext, "eglDestroyContext"); SYM(Terminate, "eglTerminate");
  SYM(GetError, "eglGetError"); SYM(GetProcAddress, "eglGetProcAddress");
#undef SYM
  gl.gles = dlopen("libGLESv2.so", RTLD_NOW | RTLD_LOCAL);
  return 1;
}

static int glContext(void) {
  const EGLint_ ca[] = { R_EGL_CONTEXT_CLIENT_VERSION, 2, R_EGL_NONE };
  gl.ctx = gl.CreateContext(gl.dpy, gl.cfg, 0, ca);
  if (!gl.ctx) return 0;
  gl.gen++;
  return 1;
}

static void glSurfaceDrop(void) {
  if (!gl.dpy) return;
  gl.MakeCurrent(gl.dpy, 0, 0, 0);
  if (gl.surf) gl.DestroySurface(gl.dpy, gl.surf);
  gl.surf = 0;
}

/* A surface on the window, the context current on it. */
static int glSurfaceMake(void) {
  if (!g.window || !gl.ctx) return 0;
  EGLint_ vid = 0;
  gl.GetConfigAttrib(gl.dpy, gl.cfg, R_EGL_NATIVE_VISUAL_ID, &vid);
  ANativeWindow_setBuffersGeometry(g.window, 0, 0, vid);
  gl.surf = gl.CreateWindowSurface(gl.dpy, gl.cfg, g.window, 0);
  if (!gl.surf) return 0;
  if (!gl.MakeCurrent(gl.dpy, gl.surf, gl.surf, gl.ctx)) {
    if (gl.GetError() != R_EGL_CONTEXT_LOST) { glSurfaceDrop(); return 0; }
    /* the context was lost while away: a new one */
    gl.DestroyContext(gl.dpy, gl.ctx);
    if (!glContext() || !gl.MakeCurrent(gl.dpy, gl.surf, gl.surf, gl.ctx)) {
      glSurfaceDrop();
      return 0;
    }
  }
  gl.SwapInterval(gl.dpy, 1);
  return 1;
}

int uirelays_gl_start(void) {
  if (gl.on) return 1;
  if (!glLoad()) return 0;
  gl.dpy = gl.GetDisplay(0);
  EGLint_ ma, mi;
  if (!gl.dpy || !gl.Initialize(gl.dpy, &ma, &mi)) { gl.dpy = 0; return 0; }
  const EGLint_ at[] = { R_EGL_SURFACE_TYPE, R_EGL_WINDOW_BIT,
                         R_EGL_RENDERABLE_TYPE, R_EGL_OPENGL_ES2_BIT,
                         R_EGL_RED_SIZE, 8, R_EGL_GREEN_SIZE, 8, R_EGL_BLUE_SIZE, 8,
                         R_EGL_DEPTH_SIZE, 0, R_EGL_NONE };
  EGLint_ n = 0;
  if (!gl.ChooseConfig(gl.dpy, at, &gl.cfg, 1, &n) || n < 1 || !glContext()) {
    gl.Terminate(gl.dpy);
    gl.dpy = 0;
    return 0;
  }
  if (g.window && !glSurfaceMake()) {
    gl.DestroyContext(gl.dpy, gl.ctx);
    gl.ctx = 0;
    gl.Terminate(gl.dpy);
    gl.dpy = 0;
    return 0;
  }
  gl.on = 1;
  /* The CPU's copy of the screen is not needed while the GPU draws. */
  free(g.shadow);
  g.shadow = 0;
  g.shW = g.shH = 0;
  return 1;
}

void uirelays_gl_stop(void) {
  if (!gl.on) return;
  glSurfaceDrop();
  if (gl.ctx) gl.DestroyContext(gl.dpy, gl.ctx);
  gl.ctx = 0;
  gl.Terminate(gl.dpy);
  gl.dpy = 0;
  gl.on = 0;
  if (g.window) ANativeWindow_setBuffersGeometry(g.window, 0, 0, WINDOW_FORMAT_RGBX_8888);
  ensureShadow();
  markDirty(0, g.shH);
}

int uirelays_gl_ready(void) { return gl.on && gl.surf != 0; }
int uirelays_gl_gen(void) { return gl.gen; }

void *uirelays_gl_proc(const char *name) {
  void *p = gl.GetProcAddress ? gl.GetProcAddress(name) : 0;
  if (!p && gl.gles) p = dlsym(gl.gles, name);
  return p;
}

/* The frame drawn shown. 0: drawing with the GPU cannot go on. */
int uirelays_gl_swap(void) {
  if (!gl.on) return 0;
  if (!gl.surf) return 1;            /* no window now: nothing to show */
  if (!gl.SwapBuffers(gl.dpy, gl.surf)) {
    EGLint_ e = gl.GetError();
    if (e != R_EGL_CONTEXT_LOST) return 0;
    glSurfaceDrop();
    gl.DestroyContext(gl.dpy, gl.ctx);
    if (!glContext() || !glSurfaceMake()) return 0;
    push(UR_RESUME);              /* everything is drawn again */
  }
  syncSystemBars();
  return 1;
}

static void processCmd(int cmd) {
  switch (cmd) {
  case CMD_INPUT:
    pthread_mutex_lock(&g.mu);
    if (g.queue) AInputQueue_detachLooper(g.queue);
    g.queue = g.pendingQueue;
    if (g.queue)
      AInputQueue_attachLooper(g.queue, g.looper, LOOPER_ID_INPUT, NULL, NULL);
    pthread_cond_broadcast(&g.cond);
    pthread_mutex_unlock(&g.mu);
    break;
  case CMD_WINDOW:
    pthread_mutex_lock(&g.mu);
    if (gl.on) glSurfaceDrop();     /* off the old window before it goes */
    g.window = g.pendingWindow;
    if (g.window) {
      ANativeWindow_setBuffersGeometry(g.window, 0, 0, WINDOW_FORMAT_RGBX_8888);
      g.winW = ANativeWindow_getWidth(g.window);
      g.winH = ANativeWindow_getHeight(g.window);
      if (gl.on) glSurfaceMake();
    }
    pthread_cond_broadcast(&g.cond);
    pthread_mutex_unlock(&g.mu);
    if (g.window) {
      if (!gl.on) ensureShadow();
      markDirty(0, g.shH);
      pushResize();
      push(UR_RESUME);
    } else {
      g.keyboardShown = 0;
      push(UR_PAUSE);
    }
    break;
  case CMD_RESIZE:
    pthread_mutex_lock(&g.mu);
    if (g.window) {
      g.winW = ANativeWindow_getWidth(g.window);
      g.winH = ANativeWindow_getHeight(g.window);
    }
    pthread_mutex_unlock(&g.mu);
    if (!gl.on) ensureShadow();
    markDirty(0, g.shH);
    pushResize();
    break;
  case CMD_RECT:
    pthread_mutex_lock(&g.mu);
    g.rect = g.pendingRect;
    pthread_mutex_unlock(&g.mu);
    pushResize();
    break;
  case CMD_FOCUS: push(UR_FOCUS); break;
  case CMD_UNFOCUS:
    g.keyboardShown = 0;
    push(UR_UNFOCUS);
    break;
  case CMD_TEXT: takeInbox(); break;
  case CMD_CONFIG: {
    int old = g.density;
    readDensity();
    if (old != g.density) {
      UrEvent *e = push(UR_METRICS);
      e->x = g.winW; e->y = g.winH;
    }
    break;
  }
  case CMD_STOP: break;
  case CMD_START: break;
  case CMD_DESTROY:
    g.destroyRequested = 1;
    push(UR_QUIT);
    break;
  }
}

/* ---- input ------------------------------------------------------------------- */

static int pointerIndex(AInputEvent *ev) {
  size_t n = AMotionEvent_getPointerCount(ev);
  for (size_t i = 0; i < n; i++)
    if (AMotionEvent_getPointerId(ev, i) == g.pointerId) return (int)i;
  return -1;
}

/* Two fingers: where their middle is and how far apart they are. */
static int twoFingers(AInputEvent *ev, float *cx, float *cy, float *d) {
  size_t n = AMotionEvent_getPointerCount(ev);
  int ia = -1, ib = -1;
  for (size_t i = 0; i < n; i++) {
    int id = AMotionEvent_getPointerId(ev, i);
    if (id == g.g2a) ia = (int)i;
    if (id == g.g2b) ib = (int)i;
  }
  if (ia < 0 || ib < 0) return 0;
  float ax = AMotionEvent_getX(ev, ia), ay = AMotionEvent_getY(ev, ia);
  float bx = AMotionEvent_getX(ev, ib), by = AMotionEvent_getY(ev, ib);
  *cx = (ax + bx) / 2;
  *cy = (ay + by) / 2;
  float dx = ax - bx, dy = ay - by;
  *d = sqrtf(dx * dx + dy * dy);
  return 1;
}

static void pushGesture(int phase, float cx, float cy, float scale, float dx, float dy) {
  UrEvent *e = push(UR_GESTURE);
  e->x = (int)cx; e->y = (int)cy; e->button = phase;
  e->pressure = scale; e->tilt = dx; e->azimuth = dy;
}

static void endGesture(void) {
  if (!g.g2) return;
  pushGesture(2, g.g2x, g.g2y, 1, 0, 0);
  g.g2 = 0;
  g.g2wait = 1;
}

static int translate(AInputEvent *ev) {
  int type = AInputEvent_getType(ev);
  if (type == AINPUT_EVENT_TYPE_MOTION) {
    int action = AMotionEvent_getAction(ev);
    int a = action & AMOTION_EVENT_ACTION_MASK;
    int src = AInputEvent_getSource(ev);
    int tool = AMotionEvent_getToolType(ev, 0);
    /* a mouse, a touchpad or a pen: hovers, clicks, no drag-to-scroll */
    g_mouse = tool == AMOTION_EVENT_TOOL_TYPE_MOUSE ||
              tool == AMOTION_EVENT_TOOL_TYPE_STYLUS ||
              (src & AINPUT_SOURCE_MOUSE) == AINPUT_SOURCE_MOUSE;
    /* the modifiers held with it: a Ctrl let go is let go for the wheel too */
    g_meta = AMotionEvent_getMetaState(ev);
    /* two fingers on the screen (not a mouse, not a pen): a gesture -- the
     * first one's press let go far away, so nothing is clicked */
    if (a == AMOTION_EVENT_ACTION_POINTER_DOWN && !g_mouse && !g.g2 &&
        AMotionEvent_getPointerCount(ev) == 2) {
      if (g.pointerId >= 0) {
        pushMove(-100000, -100000);
        UrEvent *u = push(UR_UP);
        u->x = -100000; u->y = -100000;
        g.pointerId = -1;
      }
      g.g2a = AMotionEvent_getPointerId(ev, 0);
      g.g2b = AMotionEvent_getPointerId(ev, 1);
      float cx, cy, d;
      if (twoFingers(ev, &cx, &cy, &d)) {
        g.g2 = 1;
        g.g2x = cx; g.g2y = cy; g.g2d = d > 1 ? d : 1;
        pushGesture(0, cx, cy, 1, 0, 0);
      }
      return 1;
    }
    if (g.g2) {
      if (a == AMOTION_EVENT_ACTION_MOVE) {
        float cx, cy, d;
        if (twoFingers(ev, &cx, &cy, &d)) {
          if (d < 1) d = 1;
          UrEvent *l = lastQueued();
          float scale = d / g.g2d, dx = cx - g.g2x, dy = cy - g.g2y;
          if (l && l->kind == UR_GESTURE && l->button == 1) {
            /* Moves not read yet become one: their changes multiplied and added. */
            l->x = (int)cx; l->y = (int)cy;
            l->pressure *= scale; l->tilt += dx; l->azimuth += dy;
          } else pushGesture(1, cx, cy, scale, dx, dy);
          g.g2x = cx; g.g2y = cy; g.g2d = d;
        }
        return 1;
      }
      if (a == AMOTION_EVENT_ACTION_POINTER_UP || a == AMOTION_EVENT_ACTION_UP ||
          a == AMOTION_EVENT_ACTION_CANCEL) {
        endGesture();
        if (a != AMOTION_EVENT_ACTION_POINTER_UP) g.g2wait = 0;
        return 1;
      }
      if (a == AMOTION_EVENT_ACTION_POINTER_DOWN) return 1;   /* a third finger */
    }
    if (g.g2wait) {
      /* After a gesture the finger left is not a press, until all are up. */
      if (a == AMOTION_EVENT_ACTION_UP || a == AMOTION_EVENT_ACTION_CANCEL) g.g2wait = 0;
      if (a != AMOTION_EVENT_ACTION_DOWN) return 1;
      g.g2wait = 0;
    }
    switch (a) {
    case AMOTION_EVENT_ACTION_DOWN: {
      g.pointerId = AMotionEvent_getPointerId(ev, 0);
      penOf(ev, 0);
      int x = (int)AMotionEvent_getX(ev, 0), y = (int)AMotionEvent_getY(ev, 0);
      int64_t t = AMotionEvent_getEventTime(ev) / 1000000;   /* when it happened */
      g.reshow = 1;
      int slop = g.density * 24 / 160;
      g.downButton = 0;
      if ((src & AINPUT_SOURCE_MOUSE) == AINPUT_SOURCE_MOUSE &&
          (AMotionEvent_getButtonState(ev) & AMOTION_EVENT_BUTTON_SECONDARY))
        g.downButton = 1;
      if (g.downButton == g.lastDownButton && t - g.lastDownT < 400 &&
          abs(x - g.lastDownX) < slop && abs(y - g.lastDownY) < slop) g.clicks++;
      else g.clicks = 1;
      g.lastDownT = t; g.lastDownX = x; g.lastDownY = y;
      g.lastDownButton = g.downButton;
      pushMove(x, y);
      UrEvent *e = push(UR_DOWN);
      e->x = x; e->y = y; e->button = g.downButton; e->clicks = g.clicks;
      e->meta = pointerMeta();
      withPen(e);
      return 1;
    }
    case AMOTION_EVENT_ACTION_HOVER_EXIT:       /* the mouse left the window */
      pushMove(-100000, -100000);
      return 1;
    case AMOTION_EVENT_ACTION_MOVE:
    case AMOTION_EVENT_ACTION_HOVER_ENTER:
    case AMOTION_EVENT_ACTION_HOVER_MOVE: {
      int i = a == AMOTION_EVENT_ACTION_MOVE ? pointerIndex(ev) : 0;
      if (i >= 0) {
        penOf(ev, i);
        pushMove((int)AMotionEvent_getX(ev, i), (int)AMotionEvent_getY(ev, i));
      }
      return 1;
    }
    case AMOTION_EVENT_ACTION_POINTER_UP: {
      int i = (action & AMOTION_EVENT_ACTION_POINTER_INDEX_MASK) >>
              AMOTION_EVENT_ACTION_POINTER_INDEX_SHIFT;
      if (AMotionEvent_getPointerId(ev, i) != g.pointerId) return 1;
    } /* our finger left: an up */
    /* fall through */
    case AMOTION_EVENT_ACTION_UP:
    case AMOTION_EVENT_ACTION_CANCEL: {
      if (g.pointerId < 0) return 1;
      /* cancelled (a system gesture took the touch, FLAG_CANCELED on 13+):
       * let go far away, so nothing under the finger is clicked */
      int cancelled = a == AMOTION_EVENT_ACTION_CANCEL ||
                      (AMotionEvent_getFlags(ev) & 0x20) != 0;
      int i = pointerIndex(ev);
      if (i < 0) i = 0;
      int x = cancelled ? -100000 : (int)AMotionEvent_getX(ev, i);
      int y = cancelled ? -100000 : (int)AMotionEvent_getY(ev, i);
      if (!cancelled) pushMove(x, y);
      UrEvent *e = push(UR_UP);
      e->x = x; e->y = y; e->button = g.downButton;
      e->meta = pointerMeta();
      g.pointerId = -1;
      return 1;
    }
    case AMOTION_EVENT_ACTION_SCROLL: {
      /* A wheel's notch is 1; a touch pad sends fractions of one, which are
       * kept until they make one (as long as they go the same way). Up and
       * right are > 0, as ours. */
      float v = AMotionEvent_getAxisValue(ev, AMOTION_EVENT_AXIS_VSCROLL, 0);
      float h = AMotionEvent_getAxisValue(ev, AMOTION_EVENT_AXIS_HSCROLL, 0);
      if (v * g.wheelY < 0) g.wheelY = 0;
      if (h * g.wheelX < 0) g.wheelX = 0;
      g.wheelY += v;
      g.wheelX += h;
      int ny = (int)g.wheelY, nx = (int)g.wheelX;
      g.wheelY -= ny;
      g.wheelX -= nx;
      if (nx == 0 && ny == 0) return 1;
      UrEvent *e = push(UR_WHEEL);
      e->x = nx; e->y = ny;
      e->meta = pointerMeta();
      return 1;
    }
    default:
      return 1;
    }
  }
  if (type == AINPUT_EVENT_TYPE_KEY) {
    int code = AKeyEvent_getKeyCode(ev);
    int action = AKeyEvent_getAction(ev);
    int meta = AKeyEvent_getMetaState(ev);
    switch (code) {        /* keys for the system and for other apps */
    case AKEYCODE_VOLUME_UP: case AKEYCODE_VOLUME_DOWN: case AKEYCODE_VOLUME_MUTE:
    case AKEYCODE_HOME: case AKEYCODE_POWER: case AKEYCODE_CAMERA:
    case AKEYCODE_APP_SWITCH: case AKEYCODE_HEADSETHOOK: case AKEYCODE_MUTE:
    case AKEYCODE_MEDIA_PLAY_PAUSE: case AKEYCODE_MEDIA_STOP: case AKEYCODE_MEDIA_NEXT:
    case AKEYCODE_MEDIA_PREVIOUS: case AKEYCODE_MEDIA_REWIND:
    case AKEYCODE_MEDIA_FAST_FORWARD: case AKEYCODE_MEDIA_PLAY: case AKEYCODE_MEDIA_PAUSE:
    case AKEYCODE_MEDIA_RECORD: case AKEYCODE_MEDIA_EJECT: case AKEYCODE_SEARCH:
    case AKEYCODE_NOTIFICATION: case AKEYCODE_BRIGHTNESS_DOWN: case AKEYCODE_BRIGHTNESS_UP:
    case AKEYCODE_SLEEP: case AKEYCODE_WAKEUP: case AKEYCODE_ASSIST: case AKEYCODE_VOICE_ASSIST:
    case AKEYCODE_CALL: case AKEYCODE_ENDCALL:
      return 0;
    }
    if (action == AKEY_EVENT_ACTION_MULTIPLE) {
      /* text without key codes: UiRelaysActivity reads its characters */
      return 0;
    }
    if (!(meta & 0x200000)) {          /* AMETA_NUM_LOCK_ON */
      /* Num Lock off: the keypad's keys are the arrows, Home, End... they
       * are marked with (as on the other systems) */
      switch (code) {
      case AKEYCODE_NUMPAD_7: code = AKEYCODE_MOVE_HOME; break;
      case AKEYCODE_NUMPAD_8: code = AKEYCODE_DPAD_UP; break;
      case AKEYCODE_NUMPAD_9: code = AKEYCODE_PAGE_UP; break;
      case AKEYCODE_NUMPAD_4: code = AKEYCODE_DPAD_LEFT; break;
      case AKEYCODE_NUMPAD_6: code = AKEYCODE_DPAD_RIGHT; break;
      case AKEYCODE_NUMPAD_1: code = AKEYCODE_MOVE_END; break;
      case AKEYCODE_NUMPAD_2: code = AKEYCODE_DPAD_DOWN; break;
      case AKEYCODE_NUMPAD_3: code = AKEYCODE_PAGE_DOWN; break;
      case AKEYCODE_NUMPAD_0: code = AKEYCODE_INSERT; break;
      case AKEYCODE_NUMPAD_DOT: code = AKEYCODE_FORWARD_DEL; break;
      }
    }
    if (action == AKEY_EVENT_ACTION_DOWN) {
      UrEvent *e = push(UR_KEYDOWN);
      e->key = code; e->meta = meta;
      /* Ctrl, Meta and the left Alt make shortcuts; AltGr (right Alt) types */
      int shortcut = (meta & (AMETA_CTRL_ON | AMETA_META_ON)) ||
                     ((meta & AMETA_ALT_LEFT_ON) && !(meta & AMETA_ALT_RIGHT_ON));
      if (!shortcut) {
        int c = unicodeChar(ev);
        if (c >= 32 && c != 127 && !(c & 0x80000000)) {
          e->meta &= ~(AMETA_ALT_ON | AMETA_ALT_RIGHT_ON | AMETA_ALT_LEFT_ON);
          UrEvent *t = push(UR_TEXT);
          utf8Of((uint32_t)c, t->text);
        }
      }
    } else if (action == AKEY_EVENT_ACTION_UP) {
      UrEvent *e = push(UR_KEYUP);
      e->key = code; e->meta = meta;
    }
    return 1;
  }
  return 0;
}

static void processInput(void) {
  AInputEvent *ev = NULL;
  while (g.queue && AInputQueue_getEvent(g.queue, &ev) >= 0) {
    if (AInputQueue_preDispatchEvent(g.queue, ev)) continue;  /* the IME has it */
    int handled = translate(ev);
    AInputQueue_finishEvent(g.queue, ev, handled);
  }
}

/* The next event, waiting up to `timeoutMs` (-1: for ever). */
int uirelays_wait(UrEvent *out, int timeoutMs) {
  int64_t deadline = timeoutMs < 0 ? -1 : nowMs() + timeoutMs;
  for (;;) {
    if (pop(out)) return 1;
    int t = -1;
    if (deadline >= 0) {
      int64_t left = deadline - nowMs();
      t = left < 0 ? 0 : (int)left;
    }
    int ident = ALooper_pollOnce(t, NULL, NULL, NULL);
    if (ident == LOOPER_ID_CMD) {
      int8_t cmd;
      if (read(g.msgread, &cmd, 1) == 1) processCmd(cmd);
    } else if (ident == LOOPER_ID_INPUT) {
      processInput();
    } else if (ident == ALOOPER_POLL_TIMEOUT || ident == ALOOPER_POLL_ERROR) {
      return pop(out);
    }
    if (deadline >= 0 && nowMs() >= deadline) return pop(out);
  }
}

static void bgPark(void);

/* Wait until the activity has a window (the app's createWindow). */
void uirelays_wait_window(void) {
  /* started for a background check, with no activity: the host waits for
   * one (the user opening the app), then goes on as its app thread */
  if (bgIsHost && bg.state != BG_APP) bgPark();
  /* commands and input are handled; their events stay queued, in order */
  while (!g.window && !g.destroyRequested) {
    int ident = ALooper_pollOnce(1000, NULL, NULL, NULL);
    if (ident == LOOPER_ID_CMD) {
      int8_t cmd;
      if (read(g.msgread, &cmd, 1) == 1) processCmd(cmd);
    } else if (ident == LOOPER_ID_INPUT) {
      processInput();
    }
  }
}

/* ---- the app thread ----------------------------------------------------------- */

/* This thread becomes the app's: the activity's commands come to its looper. */
static void appStart(JNIEnv *env) {
  g.env = env;
  g.appThread = pthread_self();
  g.looper = ALooper_prepare(ALOOPER_PREPARE_ALLOW_NON_CALLBACKS);
  ALooper_addFd(g.looper, g.msgread, LOOPER_ID_CMD, ALOOPER_EVENT_INPUT, NULL, NULL);
  readDensity();
  pthread_mutex_lock(&g.mu);
  g.running = 1;
  pthread_cond_broadcast(&g.cond);
  pthread_mutex_unlock(&g.mu);
}

/* The app ended (its window closed): the activity finishes. */
static void appEnd(void) {
  pthread_mutex_lock(&g.mu);
  if (g.queue) AInputQueue_detachLooper(g.queue);
  g.queue = NULL;
  g.window = NULL;
  g.finished = 1;
  pthread_cond_broadcast(&g.cond);
  pthread_mutex_unlock(&g.mu);
  if (!g.destroyRequested) ANativeActivity_finish(g.activity);
}

static void *appThread(void *arg) {
  (void)arg;
  JavaVM *vm = g.activity->vm;
  JNIEnv *env = NULL;
  (*vm)->AttachCurrentThread(vm, &env, NULL);
  appStart(env);
  NimMain();          /* the app: runs until its window closes */
  appEnd();
  (*vm)->DetachCurrentThread(vm);
  return NULL;
}

/* ---- stdout and stderr to logcat ------------------------------------------------ */

static int logPipe[2];

static void *logThread(void *arg) {
  (void)arg;
  char buf[2048];
  size_t have = 0;
  ssize_t n;
  while ((n = read(logPipe[0], buf + have, sizeof buf - 1 - have)) > 0) {
    have += (size_t)n;
    size_t start = 0;
    for (size_t i = 0; i < have; i++) {      /* one log line per text line */
      if (buf[i] == '\n') {
        buf[i] = 0;
        if (i > start) __android_log_write(ANDROID_LOG_INFO, TAG, buf + start);
        start = i + 1;
      }
    }
    if (start == 0 && have == sizeof buf - 1) {   /* a very long line */
      buf[have] = 0;
      __android_log_write(ANDROID_LOG_INFO, TAG, buf);
      start = have;
    }
    memmove(buf, buf + start, have - start);
    have -= start;
  }
  return NULL;
}

static void logToLogcat(void) {
  static int started = 0;
  if (started || pipe(logPipe) != 0) return;
  started = 1;
  setvbuf(stdout, NULL, _IOLBF, 0);
  setvbuf(stderr, NULL, _IONBF, 0);
  dup2(logPipe[1], 1);
  dup2(logPipe[1], 2);
  pthread_t t;
  pthread_create(&t, NULL, logThread, NULL);
  pthread_detach(t);
}

/* ---- the background check: the host and the job's call ---------------------------- */

/* (the host) The app's start is as far as it goes without a window: tell the
 * job, and wait for an activity -- then this thread is the app's and the
 * start goes on. */
static void bgPark(void) {
  pthread_mutex_lock(&bg.mu);
  bg.state = BG_PARKED;
  pthread_cond_broadcast(&bg.cond);
  while (!bg.appWanted) pthread_cond_wait(&bg.cond, &bg.mu);
  bg.state = BG_APP;
  pthread_mutex_unlock(&bg.mu);
  appStart(bg.hostEnv);
}

/* The app registered its background check: a host started for a check waits
 * there (for an activity); the app's own start goes on. */
void uirelays_bg_registered(void) {
  if (bgIsHost && bg.state != BG_APP) bgPark();
}

/* This thread runs the app's start with no window, for a background check. */
int uirelays_bg_headless(void) {
  return bgIsHost && bg.state != BG_APP;
}

static void *bgHost(void *arg) {
  (void)arg;
  JNIEnv *env = NULL;
  if ((*bg.vm)->AttachCurrentThread(bg.vm, &env, NULL) != JNI_OK) env = NULL;
  bgIsHost = 1;
  bg.hostEnv = env;
  NimMain();          /* the app's start: it waits in bgPark */
  pthread_mutex_lock(&bg.mu);
  int wasApp = bg.state == BG_APP;
  bg.state = BG_ENDED;
  pthread_cond_broadcast(&bg.cond);
  pthread_mutex_unlock(&bg.mu);
  if (wasApp) appEnd();
  (*bg.vm)->DetachCurrentThread(bg.vm);
  return NULL;
}

/* The app's start has run in this process -- by the activity's thread, or
 * by the host started here, which is waited for until it registered the
 * check or asked for its window. bg.mu held. */
static void bgStartApp(void) {
  if (bg.nim == 0) {
    bg.nim = 2;
    bg.state = BG_STARTING;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&attr, 8 << 20);   /* as the app's thread */
    pthread_t t;
    if (pthread_create(&t, &attr, bgHost, NULL) != 0) {
      LOGE("background check: no thread for the app");
      bg.state = BG_ENDED;
    }
    pthread_attr_destroy(&attr);
  }
  if (bg.nim == 2)
    while (bg.state == BG_STARTING) pthread_cond_wait(&bg.cond, &bg.mu);
}

/* The job's native method calls this, on the job's thread, with its class
 * (whose static `byte[] uirelaysCall(String, String)` stands in for the
 * activity's) and the app's files folder: the app's check, run here (the
 * app started first when this process has not); 1 when it ran. */
__attribute__((visibility("default")))
jint uirelays_bg_native_check(JNIEnv *env, jclass cls, jstring dataDir) {
  pthread_mutex_lock(&bg.mu);
  logToLogcat();
  if (!bg.vm) (*env)->GetJavaVM(env, &bg.vm);
  if (!bg.cls && cls) {
    bg.call = (*env)->GetStaticMethodID(env, cls, "uirelaysCall",
                                        "(Ljava/lang/String;Ljava/lang/String;)[B");
    if (bg.call) bg.cls = (jclass)(*env)->NewGlobalRef(env, cls);
    else jniFailed(env);
  }
  if (dataDir && !bg.dataDir[0]) {
    int n = 0;
    char *s = utf8String(env, dataDir, &n);
    if (n > 0 && (size_t)n < sizeof bg.dataDir) memcpy(bg.dataDir, s, (size_t)n + 1);
    free(s);
  }
  bgStartApp();
  pthread_mutex_unlock(&bg.mu);
  if (!uirelays_background_check) {
    LOGE("background check: the app registers none");
    return 0;
  }
  return uirelays_background_check();
}

/* ---- activity callbacks (UI thread) --------------------------------------------- */

static void writeCmd(int8_t cmd) {
  if (write(g.msgwrite, &cmd, 1) != 1) LOGE("command pipe: %d", cmd);
}

static void onInputQueueCreated(ANativeActivity *a, AInputQueue *q) {
  (void)a;
  pthread_mutex_lock(&g.mu);
  g.pendingQueue = q;
  writeCmd(CMD_INPUT);
  while (g.queue != g.pendingQueue && !g.finished) pthread_cond_wait(&g.cond, &g.mu);
  pthread_mutex_unlock(&g.mu);
}

static void onInputQueueDestroyed(ANativeActivity *a, AInputQueue *q) {
  (void)q;
  onInputQueueCreated(a, NULL);
}

static void onNativeWindowCreated(ANativeActivity *a, ANativeWindow *w) {
  (void)a;
  pthread_mutex_lock(&g.mu);
  g.pendingWindow = w;
  writeCmd(CMD_WINDOW);
  while (g.window != g.pendingWindow && !g.finished) pthread_cond_wait(&g.cond, &g.mu);
  pthread_mutex_unlock(&g.mu);
}

static void onNativeWindowDestroyed(ANativeActivity *a, ANativeWindow *w) {
  (void)w;
  onNativeWindowCreated(a, NULL);
}

static void onNativeWindowResized(ANativeActivity *a, ANativeWindow *w) {
  (void)a; (void)w;
  writeCmd(CMD_RESIZE);
}

static void onNativeWindowRedrawNeeded(ANativeActivity *a, ANativeWindow *w) {
  (void)a; (void)w;
  writeCmd(CMD_RESIZE);
}

static void onContentRectChanged(ANativeActivity *a, const ARect *r) {
  (void)a;
  pthread_mutex_lock(&g.mu);
  g.pendingRect = *r;
  pthread_mutex_unlock(&g.mu);
  writeCmd(CMD_RECT);
}

static void onWindowFocusChanged(ANativeActivity *a, int focused) {
  (void)a;
  writeCmd(focused ? CMD_FOCUS : CMD_UNFOCUS);
}

static void onConfigurationChanged(ANativeActivity *a) {
  (void)a;
  writeCmd(CMD_CONFIG);
}

static void onStart(ANativeActivity *a) { (void)a; writeCmd(CMD_START); }
static void onStop(ANativeActivity *a) { (void)a; writeCmd(CMD_STOP); }

static void onDestroy(ANativeActivity *a) {
  (void)a;
  writeCmd(CMD_DESTROY);
  /* Give the app a moment to finish (it gets a QuitEvent); then end the
   * process, so the next start runs NimMain in a fresh one. */
  struct timespec until;
  clock_gettime(CLOCK_REALTIME, &until);
  until.tv_sec += 3;
  pthread_mutex_lock(&g.mu);
  while (!g.finished)
    if (pthread_cond_timedwait(&g.cond, &g.mu, &until) != 0) break;
  int done = g.finished;
  pthread_mutex_unlock(&g.mu);
  (void)done;
  fflush(NULL);
  _exit(0);      /* no destructors while other threads still run */
}

__attribute__((visibility("default")))
void ANativeActivity_onCreate(ANativeActivity *activity, void *savedState,
                              size_t savedStateSize) {
  (void)savedState; (void)savedStateSize;
  /* The app's start may have run in this process already, with no window,
   * for a background check: its thread (the host) becomes the app's, as
   * NimMain runs once a process. It is waited for until it waits itself. */
  pthread_mutex_lock(&bg.mu);
  logToLogcat();
  int hosted = bg.nim == 2;
  if (hosted) {
    while (bg.state == BG_STARTING) pthread_cond_wait(&bg.cond, &bg.mu);
    /* (a start that ended without asking for a window runs again) */
    if (bg.state == BG_ENDED) hosted = 0;
  }
  if (!hosted) bg.nim = 1;
  pthread_mutex_unlock(&bg.mu);
  if (g.activity) {    /* a second activity in this process: not supported */
    LOGE("uirelays: the activity was created twice");
  }
  memset(&g, 0, sizeof g);
  g.activity = activity;
  g.pointerId = -1;
  activity->callbacks->onDestroy = onDestroy;
  activity->callbacks->onStart = onStart;
  activity->callbacks->onStop = onStop;
  activity->callbacks->onConfigurationChanged = onConfigurationChanged;
  activity->callbacks->onWindowFocusChanged = onWindowFocusChanged;
  activity->callbacks->onNativeWindowCreated = onNativeWindowCreated;
  activity->callbacks->onNativeWindowDestroyed = onNativeWindowDestroyed;
  activity->callbacks->onNativeWindowResized = onNativeWindowResized;
  activity->callbacks->onNativeWindowRedrawNeeded = onNativeWindowRedrawNeeded;
  activity->callbacks->onContentRectChanged = onContentRectChanged;
  activity->callbacks->onInputQueueCreated = onInputQueueCreated;
  activity->callbacks->onInputQueueDestroyed = onInputQueueDestroyed;
  pthread_mutex_init(&g.mu, NULL);
  pthread_cond_init(&g.cond, NULL);
  int fds[2];
  if (pipe(fds) != 0) { LOGE("pipe failed"); return; }
  g.msgread = fds[0];
  g.msgwrite = fds[1];
  initJni(activity->env, activity->clazz);
  registerNatives(activity->env, activity->clazz);
  if (hosted) {                 /* the host goes on as the app's thread */
    pthread_mutex_lock(&bg.mu);
    bg.appWanted = 1;
    pthread_cond_broadcast(&bg.cond);
    pthread_mutex_unlock(&bg.mu);
  } else {
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&attr, 8 << 20);   /* Nim likes a real stack */
    pthread_t t;
    pthread_create(&t, &attr, appThread, NULL);
  }
  pthread_mutex_lock(&g.mu);
  while (!g.running) pthread_cond_wait(&g.cond, &g.mu);
  pthread_mutex_unlock(&g.mu);
}
