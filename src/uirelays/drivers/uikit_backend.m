/* uikit_backend.m -- the iOS side of the uirelays phone driver.
 *
 * main() starts UIKit; once it has launched, the app's own main loop runs
 * (NimMain) on the main thread and pumps the run loop while it waits for
 * input, the way SDL does on iOS. A view shows the app's pixels as its
 * layer's image, takes touches and keys (UIKeyInput brings up the
 * keyboard), and CoreText draws text the built-in font lacks.
 *
 * Offers the same uirelays_* functions as android_glue.c (see surface_driver).
 * Built with -fobjc-arc. Needs iOS 14 (UILaunchScreen in Info.plist). */

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

extern void NimMain(void);

enum {
  UR_NONE, UR_MOVE, UR_DOWN, UR_UP, UR_WHEEL, UR_KEYDOWN, UR_KEYUP,
  UR_TEXT, UR_RESIZE, UR_METRICS, UR_FOCUS, UR_UNFOCUS, UR_PAUSE,
  UR_RESUME, UR_QUIT
};

typedef struct {
  int32_t kind, x, y, button, clicks, key, meta;
  char text[8];
  float pressure, tilt, azimuth, twist;   /* a pen's (pressure < 0: not a pen) */
} UrEvent;

/* meta bits as on Android, so the Nim side reads both the same way */
enum { META_SHIFT = 0x1, META_ALT = 0x2, META_CTRL = 0x1000, META_GUI = 0x10000 };
/* key codes that are not HID usages: soft keyboard Return and Backspace */
enum { HID_RETURN = 40, HID_BACKSPACE = 42 };

#define QN 512
static UrEvent q[QN];
static int qHead, qLen;

static float gPen[4] = {-1, 0, 0, 0};   /* the Apple Pencil now: pressure, tilt, azimuth, twist */

static UrEvent *push(int kind) {
  if (qLen == QN) { qHead = (qHead + 1) % QN; qLen--; }
  UrEvent *e = &q[(qHead + qLen) % QN];
  qLen++;
  memset(e, 0, sizeof *e);
  e->kind = kind;
  e->pressure = gPen[0]; e->tilt = gPen[1]; e->azimuth = gPen[2]; e->twist = gPen[3];
  return e;
}

static int pop(UrEvent *out) {
  if (!qLen) return 0;
  *out = q[qHead];
  qHead = (qHead + 1) % QN;
  qLen--;
  return 1;
}

static int gTouchMeta;   /* the keyboard's modifiers with the touch now (META_*) */

static void pushMove(int x, int y) {
  if (qLen) {
    UrEvent *l = &q[(qHead + qLen - 1) % QN];
    if (l->kind == UR_MOVE) {
      l->x = x; l->y = y; l->meta = gTouchMeta;
      l->pressure = gPen[0]; l->tilt = gPen[1]; l->azimuth = gPen[2]; l->twist = gPen[3];
      return;
    }
  }
  UrEvent *e = push(UR_MOVE);
  e->x = x; e->y = y; e->meta = gTouchMeta;
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

/* ---- state -------------------------------------------------------------- */

@class UrView;
static UrView *gView;
static UIWindow *gWindow;
static CGFloat gScale = 1;
static int winW, winH;
static struct { int top, left, bottom, right; } safe;
static uint32_t *framePx;
static int shW, shH, dirty;
static CGContextRef frameCtx;
static CGColorSpaceRef rgb;
static struct { int x, y, w, h; } clip, clipStack[8];
static int clipDepth;
static int launched, finishing;
static int wantText, reshow;       /* a field wants the keyboard; a new tap */
static int kbInset;                /* pixels the on-screen keyboard covers */
static int lightBackground = 1;    /* for the status bar's text color */
static UIView *noKeyboard;         /* inputView while no field wants text */
@class UrViewController;
static UrViewController *gController;

static void ensureShadow(void) {
  if (framePx && shW == winW && shH == winH) return;
  if (frameCtx) CGContextRelease(frameCtx);
  free(framePx);
  shW = winW > 0 ? winW : 1;
  shH = winH > 0 ? winH : 1;
  framePx = (uint32_t *)calloc((size_t)shW * shH, 4);
  if (!rgb) rgb = CGColorSpaceCreateDeviceRGB();
  /* 0x00RRGGBB words, little-endian: what the app draws */
  frameCtx = CGBitmapContextCreate(framePx, shW, shH, 8, (size_t)shW * 4, rgb,
      kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
  dirty = 1;
}

/* ---- the view ------------------------------------------------------------- */

@interface UrView : UIView <UIKeyInput>
@end

@implementation UrView {
  UITouch *tracked;
}

- (instancetype)initWithFrame:(CGRect)f {
  self = [super initWithFrame:f];
  self.multipleTouchEnabled = NO;
  self.layer.magnificationFilter = kCAFilterNearest;
  self.layer.contentsGravity = kCAGravityResize;
  self.backgroundColor = UIColor.whiteColor;
  /* no shortcut bar over the app on iPads */
  self.inputAssistantItem.leadingBarButtonGroups = @[];
  self.inputAssistantItem.trailingBarButtonGroups = @[];
  NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
  [nc addObserver:self selector:@selector(keyboardChanged:)
             name:UIKeyboardWillChangeFrameNotification object:nil];
  [nc addObserver:self selector:@selector(keyboardChanged:)
             name:UIKeyboardWillHideNotification object:nil];
  return self;
}

- (void)keyboardChanged:(NSNotification *)n {
  int inset = 0;
  if (![n.name isEqualToString:UIKeyboardWillHideNotification]) {
    CGRect k = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect mine = [self convertRect:self.bounds toView:nil];
    CGFloat overlap = CGRectGetMaxY(mine) - CGRectGetMinY(k);
    if (CGRectGetWidth(k) > 0 && overlap > 0) inset = (int)(overlap * gScale + 0.5);
  }
  if (inset != kbInset) {
    kbInset = inset;
    [self updateMetrics];
  }
}

/* The view stays first responder, so hardware keys always arrive; the
 * on-screen keyboard comes and goes with its inputView. */
- (UIView *)inputView { return wantText ? nil : noKeyboard; }

- (void)updateMetrics {
  gScale = self.window ? self.window.screen.scale : UIScreen.mainScreen.scale;
  self.layer.contentsScale = gScale;
  CGSize s = self.bounds.size;
  winW = (int)(s.width * gScale + 0.5);
  winH = (int)(s.height * gScale + 0.5);
  UIEdgeInsets in = self.safeAreaInsets;
  safe.top = (int)(in.top * gScale + 0.5);
  safe.left = (int)(in.left * gScale + 0.5);
  safe.bottom = (int)(in.bottom * gScale + 0.5);
  safe.right = (int)(in.right * gScale + 0.5);
  /* iOS does not shrink the view for the keyboard: keep clear of it here */
  if (kbInset > safe.bottom) safe.bottom = kbInset;
  UrEvent *e = push(UR_RESIZE);
  e->x = winW; e->y = winH;
}

- (void)layoutSubviews { [super layoutSubviews]; [self updateMetrics]; }
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; [self updateMetrics]; }

- (CGPoint)pixelOf:(UITouch *)t {
  /* An Apple Pencil: how hard, how far it leans and which way, kept for
   * the events that follow. */
  if (@available(iOS 9.1, *)) {
    if (t.type == UITouchTypePencil) {
      gPen[0] = t.maximumPossibleForce > 0 ? (float)(t.force / t.maximumPossibleForce) : 1.0f;
      gPen[1] = (float)(M_PI_2 - t.altitudeAngle);
      gPen[2] = (float)[t azimuthAngleInView:self];
      gPen[3] = 0;
    } else {
      gPen[0] = -1; gPen[1] = 0; gPen[2] = 0; gPen[3] = 0;
    }
  }
  CGPoint p = [t locationInView:self];
  return CGPointMake(p.x * gScale, p.y * gScale);
}

static int metaOf(UIKeyModifierFlags f);

/* The modifiers of a hardware keyboard held with a touch (iOS 13.4 on). */
static int touchMeta(UIEvent *event) {
  gTouchMeta = 0;
  if (@available(iOS 13.4, *)) gTouchMeta = metaOf(event.modifierFlags);
  return gTouchMeta;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  if (tracked) return;
  tracked = touches.anyObject;
  reshow = 1;
  CGPoint p = [self pixelOf:tracked];
  int meta = touchMeta(event);
  pushMove((int)p.x, (int)p.y);
  UrEvent *e = push(UR_DOWN);
  e->x = (int)p.x; e->y = (int)p.y; e->clicks = (int)tracked.tapCount;
  e->meta = meta;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  if (!tracked || ![touches containsObject:tracked]) return;
  CGPoint p = [self pixelOf:tracked];
  touchMeta(event);
  pushMove((int)p.x, (int)p.y);
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  if (!tracked || ![touches containsObject:tracked]) return;
  CGPoint p = [self pixelOf:tracked];
  int meta = touchMeta(event);
  pushMove((int)p.x, (int)p.y);
  UrEvent *e = push(UR_UP);
  e->x = (int)p.x; e->y = (int)p.y;
  e->meta = meta;
  tracked = nil;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  /* the system took the touch (Control Center, a call): let go far away,
   * so the widget under the finger is not clicked */
  if (!tracked || ![touches containsObject:tracked]) return;
  UrEvent *e = push(UR_UP);
  e->x = -100000; e->y = -100000;
  tracked = nil;
}

/* UIKeyInput: the soft keyboard (and typing on a hardware one) */
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)hasText { return YES; }
- (UITextAutocorrectionType)autocorrectionType { return UITextAutocorrectionTypeNo; }
- (UITextAutocapitalizationType)autocapitalizationType {
  return UITextAutocapitalizationTypeNone;
}
- (UITextSpellCheckingType)spellCheckingType { return UITextSpellCheckingTypeNo; }

static void keyPress(int code, int meta) {
  UrEvent *d = push(UR_KEYDOWN);
  d->key = code; d->meta = meta;
  UrEvent *u = push(UR_KEYUP);
  u->key = code; u->meta = meta;
}

- (void)insertText:(NSString *)text {
  NSUInteger n = text.length;
  NSUInteger i = 0;
  while (i < n) {
    uint32_t c = [text characterAtIndex:i++];
    if (c >= 0xD800 && c < 0xDC00 && i < n) {
      uint32_t lo = [text characterAtIndex:i];
      if (lo >= 0xDC00 && lo < 0xE000) { c = 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00); i++; }
    }
    if (c == '\n' || c == '\r') { keyPress(HID_RETURN, 0); continue; }
    push(UR_KEYDOWN);              /* a key press opens the way for text */
    UrEvent *t = push(UR_TEXT);
    utf8Of(c, t->text);
  }
}

- (void)deleteBackward { keyPress(HID_BACKSPACE, 0); }

/* Cmd+V (and the edit menu) paste through UIKit, so iOS does not ask
 * "Allow Paste?" each time: the paste arrives as typed text. */
- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
  if (action == @selector(paste:)) return wantText && UIPasteboard.generalPasteboard.hasStrings;
  return [super canPerformAction:action withSender:sender];
}

- (void)paste:(id)sender {
  NSString *s = UIPasteboard.generalPasteboard.string;
  if (s.length) [self insertText:s];
}

/* Hardware keyboards: keys that edit text go through UIKeyInput while the
 * keyboard is up; the others (arrows, Esc, shortcuts...) come here. */
static int metaOf(UIKeyModifierFlags f) {
  int m = 0;
  if (f & UIKeyModifierShift) m |= META_SHIFT;
  if (f & UIKeyModifierAlternate) m |= META_ALT;
  if (f & (UIKeyModifierControl | UIKeyModifierCommand)) m |= META_CTRL;  /* Cmd+C copies */
  return m;
}

static BOOL typesText(long usage) {
  return (usage >= 4 && usage <= 39) || (usage >= 44 && usage <= 56) ||
         usage == HID_RETURN || usage == HID_BACKSPACE || usage == 43 /* Tab */;
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
  BOOL passOn = NO;
  if (@available(iOS 13.4, *)) {
    for (UIPress *p in presses) {
      UIKey *k = p.key;
      if (!k) { passOn = YES; continue; }
      int meta = metaOf(k.modifierFlags);
      long usage = (long)k.keyCode;
      /* (Option types too: @, { and the rest on many layouts) */
      if (wantText && typesText(usage) && !(meta & META_CTRL)
          && usage != 43) {
        passOn = YES;               /* UIKit calls insertText / deleteBackward */
        continue;
      }
      if (wantText && usage == 25 /* V */ && (k.modifierFlags & UIKeyModifierCommand)) {
        passOn = YES;               /* UIKit calls paste: */
        continue;
      }
      UrEvent *e = push(UR_KEYDOWN);
      e->key = (int)usage; e->meta = meta;
    }
  } else passOn = YES;
  if (passOn) [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
  if (@available(iOS 13.4, *)) {
    for (UIPress *p in presses) {
      if (!p.key) continue;
      UrEvent *e = push(UR_KEYUP);
      e->key = (int)p.key.keyCode; e->meta = metaOf(p.key.modifierFlags);
    }
  }
  [super pressesEnded:presses withEvent:event];
}

@end

/* ---- view controller and app delegate -------------------------------------------- */

@interface UrViewController : UIViewController
@end

@implementation UrViewController
- (void)loadView {
  noKeyboard = [[UIView alloc] initWithFrame:CGRectZero];
  gView = [[UrView alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.view = gView;
  gController = self;
}
- (BOOL)prefersStatusBarHidden { return NO; }
- (UIStatusBarStyle)preferredStatusBarStyle {
  /* the app's own background is under the status bar, not the system's */
  if (@available(iOS 13.0, *))
    return lightBackground ? UIStatusBarStyleDarkContent : UIStatusBarStyleLightContent;
  return lightBackground ? UIStatusBarStyleDefault : UIStatusBarStyleLightContent;
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
  return UIInterfaceOrientationMaskAll;
}
- (BOOL)prefersHomeIndicatorAutoHidden { return NO; }
@end

@interface UrAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation UrAppDelegate

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  gWindow = self.window;
  self.window.rootViewController = [[UrViewController alloc] init];
  [self.window makeKeyAndVisible];
  /* The app runs after this returns, inside the run loop it pumps. */
  [self performSelector:@selector(runApp) withObject:nil afterDelay:0];
  return YES;
}

- (void)runApp {
  launched = 1;
  [gView becomeFirstResponder];     /* for hardware keys; no keyboard yet */
  [gView updateMetrics];
  NimMain();
  exit(0);    /* the app's window was closed */
}

- (void)applicationDidEnterBackground:(UIApplication *)app { push(UR_PAUSE); }
- (void)applicationWillEnterForeground:(UIApplication *)app {
  push(UR_RESUME);
  dirty = 1;
}
- (void)applicationDidBecomeActive:(UIApplication *)app { push(UR_FOCUS); }
- (void)applicationWillResignActive:(UIApplication *)app { push(UR_UNFOCUS); }
- (void)applicationWillTerminate:(UIApplication *)app { push(UR_QUIT); }

@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([UrAppDelegate class]));
  }
}

/* ---- the uirelays_* API ------------------------------------------------------------------- */

int64_t uirelays_ticks(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

int uirelays_wait(UrEvent *out, int timeoutMs) {
  @autoreleasepool {
    if (pop(out)) return 1;
    int64_t deadline = timeoutMs < 0 ? -1 : uirelays_ticks() + timeoutMs;
    for (;;) {
      double wait = 1.0;
      if (deadline >= 0) {
        int64_t left = deadline - uirelays_ticks();
        wait = left > 0 ? left / 1000.0 : 0;
      }
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, wait, true);
      if (pop(out)) return 1;
      if (deadline >= 0 && uirelays_ticks() >= deadline) return 0;
    }
  }
}

void uirelays_wait_window(void) {
  /* the view exists once UIKit has launched; it is sized in layoutSubviews */
  while (!gView || winW == 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
}

void uirelays_layout(int *w, int *h, int *density, int *top, int *left, int *bottom,
                int *right) {
  *w = winW; *h = winH;
  *density = (int)(160 * gScale);   /* 2x screens: 200%, 3x: 300% */
  *top = safe.top; *left = safe.left; *bottom = safe.bottom; *right = safe.right;
}

int uirelays_blit(const uint32_t *p, int w, int h, int dx, int dy) {
  ensureShadow();
  int x0 = dx < 0 ? 0 : dx, x1 = dx + w > shW ? shW : dx + w;
  int y0 = dy < 0 ? 0 : dy, y1 = dy + h > shH ? shH : dy + h;
  if (x0 >= x1 || y0 >= y1) return 1;
  for (int y = y0; y < y1; y++)
    memcpy(framePx + (size_t)y * shW + x0, p + (size_t)(y - dy) * w + (x0 - dx),
           (size_t)(x1 - x0) * 4);
  dirty = 1;
  return 1;
}

/* Fill a rectangle of the frame, inside the clip, with a 0xAARRGGBB
 * color; one that is not opaque is blended over what is there. */
void uirelays_fill(int x, int y, int w, int h, uint32_t c) {
  ensureShadow();
  uint32_t a = c >> 24;
  if (a == 0 || w <= 0 || h <= 0) return;
  int x0 = x, y0 = y, x1 = x + w, y1 = y + h;
  if (clip.w > 0 && clip.h > 0) {
    if (x0 < clip.x) x0 = clip.x;
    if (y0 < clip.y) y0 = clip.y;
    if (x1 > clip.x + clip.w) x1 = clip.x + clip.w;
    if (y1 > clip.y + clip.h) y1 = clip.y + clip.h;
  }
  if (x0 < 0) x0 = 0;
  if (y0 < 0) y0 = 0;
  if (x1 > shW) x1 = shW;
  if (y1 > shH) y1 = shH;
  if (x0 >= x1 || y0 >= y1) return;
  for (int yy = y0; yy < y1; yy++) {
    uint32_t *dst = framePx + (size_t)yy * shW;
    for (int xx = x0; xx < x1; xx++) {
      if (a == 255) { dst[xx] = c & 0xFFFFFF; continue; }
      uint32_t d = dst[xx], r = 0;
      for (int s = 0; s <= 16; s += 8) {
        uint32_t cs = (c >> s) & 0xFF, ds = (d >> s) & 0xFF;
        r |= ((cs * a + ds * (255 - a) + 127) / 255) << s;
      }
      dst[xx] = r;
    }
  }
  dirty = 1;
}

void uirelays_refresh(void) {
  if (!dirty || !frameCtx || !gView) return;
  /* the color under the status bar decides its text color */
  uint32_t c = framePx[0];
  int light = ((c >> 16 & 0xFF) * 3 + (c >> 8 & 0xFF) * 6 + (c & 0xFF)) > 1280;
  if (light != lightBackground) {
    lightBackground = light;
    [gController setNeedsStatusBarAppearanceUpdate];
  }
  @autoreleasepool {
    CGImageRef img = CGBitmapContextCreateImage(frameCtx);   /* copy on write */
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    gView.layer.contents = (__bridge id)img;
    [CATransaction commit];
    CGImageRelease(img);
  }
  dirty = 0;
}

void uirelays_clip(int x, int y, int w, int h) { clip.x = x; clip.y = y; clip.w = w; clip.h = h; }
void uirelays_save(void) { if (clipDepth < 8) clipStack[clipDepth++] = clip; }
void uirelays_restore(void) { if (clipDepth > 0) clip = clipStack[--clipDepth]; }

static CTLineRef makeLine(const char *s, int n, int size, uint32_t fg) {
  CFStringRef str = CFStringCreateWithBytes(NULL, (const UInt8 *)s, n,
                                            kCFStringEncodingUTF8, false);
  if (!str) return NULL;
  CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem,
                                                 size * 10.0 / 13.0, NULL);
  CGFloat comp[4] = { ((fg >> 16) & 0xFF) / 255.0, ((fg >> 8) & 0xFF) / 255.0,
                      (fg & 0xFF) / 255.0, 1.0 };
  if (!rgb) rgb = CGColorSpaceCreateDeviceRGB();
  CGColorRef color = CGColorCreate(rgb, comp);
  const void *keys[] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
  const void *vals[] = { font, color };
  CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, vals, 2,
      &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFAttributedStringRef as = CFAttributedStringCreate(NULL, str, attrs);
  CTLineRef line = CTLineCreateWithAttributedString(as);
  CFRelease(as); CFRelease(attrs); CGColorRelease(color); CFRelease(font); CFRelease(str);
  return line;
}

static int textWidthImpl(const char *s, int n, int size) {
  CTLineRef line = makeLine(s, n, size, 0);
  if (!line) return 0;
  double w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
  CFRelease(line);
  return (int)(w + 0.99);
}

/* CoreText shapes and orders Arabic and every other script. */
static int textDrawImpl(const char *s, int n, int size, int x, int y, uint32_t fg, uint32_t bg) {
  ensureShadow();
  CTLineRef line = makeLine(s, n, size, fg);
  if (!line) return 0;
  int w = (int)(CTLineGetTypographicBounds(line, NULL, NULL, NULL) + 0.99);
  int cx0 = clip.w > 0 ? clip.x : 0, cy0 = clip.h > 0 ? clip.y : 0;
  int cx1 = clip.w > 0 ? clip.x + clip.w : shW, cy1 = clip.h > 0 ? clip.y + clip.h : shH;
  if (x > cx0) cx0 = x;
  if (y > cy0) cy0 = y;
  if (x + w < cx1) cx1 = x + w;
  if (y + size < cy1) cy1 = y + size;
  if (cx0 < 0) cx0 = 0;
  if (cy0 < 0) cy0 = 0;
  if (cx1 > shW) cx1 = shW;
  if (cy1 > shH) cy1 = shH;
  if (cx0 < cx1 && cy0 < cy1) {
    int cw = cx1 - cx0, ch = cy1 - cy0;
    CGContextRef ctx = CGBitmapContextCreate(framePx + (size_t)cy0 * shW + cx0, cw, ch, 8,
        (size_t)shW * 4, rgb, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    if (ctx) {
      CGContextSetRGBFillColor(ctx, ((bg >> 16) & 0xFF) / 255.0, ((bg >> 8) & 0xFF) / 255.0,
                               (bg & 0xFF) / 255.0, 1);
      CGContextFillRect(ctx, CGRectMake(0, 0, cw, ch));
      /* CoreGraphics counts rows from the bottom */
      double baseline = (y - cy0) + size * 11.0 / 13.0;
      CGContextSetTextPosition(ctx, x - cx0, ch - baseline);
      CTLineDraw(line, ctx);
      CGContextRelease(ctx);
      dirty = 1;
    }
  }
  CFRelease(line);
  return w;
}

static char *clipboardGetImpl(int *len) {
  NSString *s = UIPasteboard.generalPasteboard.string;
  *len = 0;
  if (!s) return NULL;
  const char *u = s.UTF8String;
  size_t n = strlen(u);
  char *r = (char *)malloc(n + 1);
  memcpy(r, u, n + 1);
  *len = (int)n;
  return r;
}

static void clipboardPutImpl(const char *s, int n) {
  NSString *str = [[NSString alloc] initWithBytes:s length:n encoding:NSUTF8StringEncoding];
  if (str) UIPasteboard.generalPasteboard.string = str;
}

static int openUrlImpl(const char *s, int n) {
  NSString *str = [[NSString alloc] initWithBytes:s length:n encoding:NSUTF8StringEncoding];
  NSURL *url = str ? [NSURL URLWithString:str] : nil;
  if (!url) return 0;
  [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
  return 1;
}

static const char *dataDirImpl(void) {
  static char path[1024];
  NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                      NSUserDomainMask, YES);
  NSString *d = dirs.firstObject ?: NSTemporaryDirectory();
  [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES
                                           attributes:nil error:nil];
  strncpy(path, d.fileSystemRepresentation, sizeof path - 1);
  return path;
}

void uirelays_keyboard(int show) {
  if (!gView) return;
  @autoreleasepool {
    /* asked again after each tap while a field wants text: the user may
     * have hidden the keyboard with its own key */
    int tapped = reshow;
    int again = show && reshow;
    reshow = 0;
    if (show == wantText && !again) {
      /* a view put inside this one (a web view) keeps the keys it was
       * given until this view is touched */
      if (!gView.isFirstResponder && !show && (tapped || gView.subviews.count == 0))
        [gView becomeFirstResponder];
      return;
    }
    wantText = show;
    if (gView.isFirstResponder) [gView reloadInputViews];
    else [gView becomeFirstResponder];
  }
}

void uirelays_finish(void) {
  /* iOS apps do not quit themselves; the app's loop ends, runApp exits. */
  finishing = 1;
}

/* ---- files and pictures ------------------------------------------------------ */

int uirelays_minimize(void) { return 0; }        /* iOS apps cannot */
int uirelays_has_storage(void) { return 1; }     /* the app's own sandbox */
void uirelays_ask_storage(void) {}

static int openFileImpl(const char *path, int n, int mode) {
  NSString *p = [[NSString alloc] initWithBytes:path length:n encoding:NSUTF8StringEncoding];
  if (!p || !gController) return 0;
  NSURL *url = [NSURL fileURLWithPath:p];
  /* iOS has no "open in the default app": both open and share use the
   * share sheet, which offers the apps that take this kind of file */
  UIActivityViewController *vc =
    [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
  vc.popoverPresentationController.sourceView = gView;
  vc.popoverPresentationController.sourceRect = CGRectMake(gView.bounds.size.width / 2,
                                                           gView.bounds.size.height / 2, 1, 1);
  [gController presentViewController:vc animated:YES completion:nil];
  (void)mode;
  return 1;
}

int uirelays_open_file(const char *path, int n, int mode) {
  @autoreleasepool { return openFileImpl(path, n, mode); }
}

static uint32_t *decodeImageImpl(const char *path, int n, int maxW, int maxH,
                                 int *w, int *h) {
  *w = *h = 0;
  NSString *p = [[NSString alloc] initWithBytes:path length:n encoding:NSUTF8StringEncoding];
  UIImage *img = p ? [UIImage imageWithContentsOfFile:p] : nil;
  if (!img || img.size.width <= 0 || img.size.height <= 0) return NULL;
  CGFloat sw = img.size.width * img.scale, sh = img.size.height * img.scale;
  CGFloat k = MIN(1.0, MIN(maxW / sw, maxH / sh));
  int tw = MAX(1, (int)(sw * k)), th = MAX(1, (int)(sh * k));
  uint32_t *px = (uint32_t *)calloc((size_t)tw * th, 4);
  if (!px) return NULL;
  if (!rgb) rgb = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(px, tw, th, 8, (size_t)tw * 4, rgb,
      kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
  if (!ctx) { free(px); return NULL; }
  UIGraphicsPushContext(ctx);
  CGContextTranslateCTM(ctx, 0, th);       /* UIKit draws top down */
  CGContextScaleCTM(ctx, 1, -1);
  [img drawInRect:CGRectMake(0, 0, tw, th)];   /* applies the photo's orientation */
  UIGraphicsPopContext();
  CGContextRelease(ctx);
  for (size_t i = 0; i < (size_t)tw * th; i++) {   /* un-premultiply */
    uint32_t c = px[i], a = c >> 24;
    if (a != 0 && a != 255) {
      uint32_t r = MIN(255u, ((c >> 16) & 255) * 255 / a);
      uint32_t g2 = MIN(255u, ((c >> 8) & 255) * 255 / a);
      uint32_t b2 = MIN(255u, (c & 255) * 255 / a);
      px[i] = (a << 24) | (r << 16) | (g2 << 8) | b2;
    }
  }
  *w = tw;
  *h = th;
  return px;
}

uint32_t *uirelays_decode_image(const char *path, int n, int maxW, int maxH, int *w, int *h) {
  @autoreleasepool { return decodeImageImpl(path, n, maxW, maxH, w, h); }
}

/* Nim calls these outside any autorelease pool of UIKit's: give each one */

int uirelays_text_width(const char *s, int n, int size) {
  @autoreleasepool { return textWidthImpl(s, n, size); }
}

int uirelays_text_draw(const char *s, int n, int size, int x, int y, uint32_t fg, uint32_t bg) {
  @autoreleasepool { return textDrawImpl(s, n, size, x, y, fg, bg); }
}

char *uirelays_clipboard_get(int *len) {
  @autoreleasepool { return clipboardGetImpl(len); }
}

void uirelays_clipboard_put(const char *s, int n) {
  @autoreleasepool { clipboardPutImpl(s, n); }
}

int uirelays_open_url(const char *s, int n) {
  @autoreleasepool { return openUrlImpl(s, n); }
}

const char *uirelays_data_dir(void) {
  @autoreleasepool { return dataDirImpl(); }
}

/* ---- screen readers: UIAccessibility (VoiceOver) ----------------------
   The program's tree (uirelays_access_update) as accessibility elements of
   the view; what VoiceOver asks (activate, a step, a value) is queued for
   the program's loop (uirelays_access_take). */

typedef struct {
  unsigned int nodeId;
  int parent, role;
  unsigned int states;
  int x, y, w, h;
  double lo, hi, now, step;
  int caret, selA, selB, pos, count, level;
  const char *name, *value, *help, *key;
} UrAccessNode;

enum { UAX_FOCUSED = 1 << 1, UAX_DISABLED = 1 << 2, UAX_CHECKED = 1 << 3, UAX_SELECTED = 1 << 5,
       UAX_PRESSED = 1 << 10 };
enum { UAXR_WINDOW, UAXR_PANE, UAXR_GROUP, UAXR_LABEL, UAXR_BUTTON, UAXR_TOGGLE, UAXR_CHECK,
       UAXR_RADIO, UAXR_FIELD, UAXR_AREA, UAXR_PASSWORD, UAXR_COMBO, UAXR_LIST, UAXR_LISTITEM,
       UAXR_SLIDER, UAXR_SPIN, UAXR_PROGRESS, UAXR_SCROLLBAR, UAXR_MENUBAR, UAXR_MENU,
       UAXR_MENUITEM, UAXR_TOOLBAR, UAXR_STATUS, UAXR_TABLIST, UAXR_TAB, UAXR_TREE, UAXR_TREEITEM,
       UAXR_TABLE, UAXR_ROW, UAXR_CELL, UAXR_COLHEADER, UAXR_DIALOG, UAXR_LINK, UAXR_IMAGE,
       UAXR_HEADING };

typedef struct { int action; unsigned int nodeId; double num; char *text; } UrAccessAsk;
static UrAccessAsk uaxAsks[64];
static int uaxAskN = 0;
static int uaxListening = -1;          /* -1: not told yet */

static void uaxAsk(int action, unsigned int nodeId, NSString *text, double num) {
  if (uaxAskN >= 64) return;
  UrAccessAsk a = { action, nodeId, num, text ? strdup([text UTF8String]) : NULL };
  uaxAsks[uaxAskN++] = a;
  push(UR_NONE);                       /* (the program's loop goes on) */
}

int uirelays_access_take(int *action, unsigned int *nodeId, double *num, char **text) {
  int on = UIAccessibilityIsVoiceOverRunning() ? 1 : 0;
  if (on != uaxListening) {
    /* (VoiceOver came or went: the program builds its tree or not) */
    uaxListening = on;
    *action = on ? -1 : -2;
    *nodeId = 0;
    *num = 0;
    *text = NULL;
    return 1;
  }
  if (uaxAskN == 0) return 0;
  *action = uaxAsks[0].action;
  *nodeId = uaxAsks[0].nodeId;
  *num = uaxAsks[0].num;
  *text = uaxAsks[0].text;
  memmove(&uaxAsks[0], &uaxAsks[1], sizeof(UrAccessAsk) * (size_t)(uaxAskN - 1));
  uaxAskN--;
  return 1;
}

@interface UrAXElement : UIAccessibilityElement
@property unsigned int nodeId;
@property int axRole;
@property unsigned int axStates;
@property CGRect local;
@property double now;
@end

@implementation UrAXElement
- (CGRect)accessibilityFrame {
  return gView ? UIAccessibilityConvertFrameToScreenCoordinates(self.local, gView) : CGRectZero;
}
- (BOOL)accessibilityActivate {
  uaxAsk(0, self.nodeId, nil, 0);
  return YES;
}
- (void)accessibilityIncrement { uaxAsk(3, self.nodeId, nil, 0); }
- (void)accessibilityDecrement { uaxAsk(4, self.nodeId, nil, 0); }
@end

static NSMutableDictionary *uaxById = nil;
static NSArray *uaxEls = nil;

@implementation UrView (UrAccess)
- (BOOL)isAccessibilityElement { return NO; }
- (NSArray *)accessibilityElements { return uaxEls ? uaxEls : @[]; }
@end

void uirelays_access_update(const UrAccessNode *nodes, int n, int focus) {
  @autoreleasepool {
    if (!uaxById) uaxById = [NSMutableDictionary new];
    NSMutableDictionary *next = [NSMutableDictionary dictionaryWithCapacity:n];
    NSMutableArray *els = [NSMutableArray arrayWithCapacity:n];
    BOOL shape = NO;
    UrAXElement *focused = nil;
    for (int i = 1; i < n; i++) {
      const UrAccessNode *a = &nodes[i];
      if (a->role == UAXR_PANE || a->role == UAXR_GROUP || a->role == UAXR_MENUBAR ||
          a->role == UAXR_TOOLBAR || a->role == UAXR_TABLIST || a->role == UAXR_LIST) continue;
      NSNumber *key = @(a->nodeId);
      UrAXElement *e = uaxById[key];
      if (!e) {
        e = [[UrAXElement alloc] initWithAccessibilityContainer:gView];
        shape = YES;
      }
      e.nodeId = a->nodeId;
      e.axRole = a->role;
      e.axStates = a->states;
      /* (points: the program's units are the view's) */
      e.local = CGRectMake(a->x, a->y, a->w, a->h);
      e.now = a->now;
      NSString *name = a->name ? [NSString stringWithUTF8String:a->name] : @"";
      NSString *value = a->value ? [NSString stringWithUTF8String:a->value] : @"";
      e.accessibilityLabel = name;
      UIAccessibilityTraits t = UIAccessibilityTraitNone;
      switch (a->role) {
        case UAXR_BUTTON: case UAXR_TOGGLE: case UAXR_CHECK: case UAXR_RADIO: case UAXR_TAB:
        case UAXR_MENUITEM: case UAXR_MENU: case UAXR_COMBO: case UAXR_LISTITEM:
          t |= UIAccessibilityTraitButton; break;
        case UAXR_LINK: t |= UIAccessibilityTraitLink; break;
        case UAXR_IMAGE: t |= UIAccessibilityTraitImage; break;
        case UAXR_HEADING: t |= UIAccessibilityTraitHeader; break;
        case UAXR_SLIDER: case UAXR_SPIN: t |= UIAccessibilityTraitAdjustable; break;
        case UAXR_LABEL: case UAXR_STATUS: t |= UIAccessibilityTraitStaticText; break;
        default: break;
      }
      if (a->states & (UAX_SELECTED | UAX_CHECKED | UAX_PRESSED)) t |= UIAccessibilityTraitSelected;
      if (a->states & UAX_DISABLED) t |= UIAccessibilityTraitNotEnabled;
      e.accessibilityTraits = t;
      if (a->role == UAXR_FIELD || a->role == UAXR_AREA || a->role == UAXR_COMBO ||
          a->role == UAXR_SLIDER || a->role == UAXR_SPIN || a->role == UAXR_PROGRESS)
        e.accessibilityValue = value;
      else if (a->role == UAXR_CHECK || a->role == UAXR_TOGGLE)
        e.accessibilityValue = (a->states & (UAX_CHECKED | UAX_PRESSED)) ? @"1" : @"0";
      else e.accessibilityValue = nil;
      e.accessibilityHint = a->help && a->help[0] ? [NSString stringWithUTF8String:a->help] : nil;
      next[key] = e;
      [els addObject:e];
      if (i == focus) focused = e;
    }
    if (next.count != uaxById.count) shape = YES;
    uaxById = next;
    uaxEls = els;
    if (shape) UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, focused);
  }
}
