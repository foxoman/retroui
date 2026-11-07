/*  cocoa_backend.m – Cocoa/AppKit backend for NimEdit.
 *
 *  Exposes a flat C API that cocoa_driver.nim imports.
 *  Uses Core Graphics for drawing, Core Text for fonts,
 *  NSView subclass for events.
 *
 *  Compile:  included automatically via {.compile.} in cocoa_driver.nim
 *  Link:     -framework Cocoa -framework CoreText -framework CoreGraphics -framework QuartzCore
 */

#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>

/* ---- Event queue (ring buffer) ---------------------------------------- */

enum {
  NE_NONE = 0,
  NE_KEY_DOWN, NE_KEY_UP, NE_TEXT_INPUT,
  NE_MOUSE_DOWN, NE_MOUSE_UP, NE_MOUSE_MOVE, NE_MOUSE_WHEEL,
  NE_WINDOW_RESIZE, NE_WINDOW_CLOSE,
  NE_WINDOW_FOCUS_GAINED, NE_WINDOW_FOCUS_LOST,
  NE_QUIT,
  NE_FILE_DROP,       /* files dropped on the window: cocoa_dropPath */
  NE_TEXT_EDIT        /* what an input method composes changed: cocoa_markedText */
};

enum {
  NE_MOD_SHIFT = 1,
  NE_MOD_CTRL  = 2,
  NE_MOD_ALT   = 4,
  NE_MOD_GUI   = 8
};

enum {
  NE_MB_LEFT   = 0,
  NE_MB_RIGHT  = 1,
  NE_MB_MIDDLE = 2
};

typedef struct {
  int kind;
  int key;            /* NimEdit KeyCode ordinal */
  int mods;           /* bitmask of NE_MOD_* */
  char text[4];       /* UTF-8 codepoint for NE_TEXT_INPUT */
  int x, y;
  int xrel, yrel;
  int button;         /* NE_MB_* */
  int buttons;        /* bitmask: 1=left, 2=right, 4=middle */
  int clicks;
  int pen;            /* 0: a mouse; 1: a tablet's pen; 2: the pen's eraser end */
  float pressure;     /* the pen's, 0 .. 1 */
  float tiltX, tiltY; /* the pen's lean, -1 .. 1 each (NSEvent.tilt) */
  float rotation;     /* the pen's turn, degrees (NSEvent.rotation) */
} NEEvent;

/* What an input method composes now (cocoa_markedText). */
static char markedUTF8[1024];
static int markedCaret = 0;

const char *cocoa_markedText(int *caret) {
  *caret = markedCaret;
  return markedUTF8;
}

#define EVENT_QUEUE_SIZE 256
static NEEvent eventQueue[EVENT_QUEUE_SIZE];
static int eqHead = 0, eqTail = 0;

static int pushEvent(NEEvent ev) {
  int next = (eqHead + 1) % EVENT_QUEUE_SIZE;
  if (next == eqTail) return 0;  /* queue full, drop */
  eventQueue[eqHead] = ev;
  eqHead = next;
  return 1;
}

int cocoa_pollEvent(NEEvent *out) {
  /* Pump the run loop briefly so Cocoa delivers events */
  @autoreleasepool {
    NSEvent *ev;
    while ((ev = [NSApp nextEventMatchingMask:NSEventMaskAny
                                    untilDate:nil
                                       inMode:NSDefaultRunLoopMode
                                      dequeue:YES]) != nil) {
      [NSApp sendEvent:ev];
      [NSApp updateWindows];
    }
  }
  if (eqTail == eqHead) {
    out->kind = NE_NONE;
    return 0;
  }
  *out = eventQueue[eqTail];
  eqTail = (eqTail + 1) % EVENT_QUEUE_SIZE;
  return 1;
}

int cocoa_waitEvent(NEEvent *out, int timeoutMs) {
  NSDate *deadline = (timeoutMs < 0)
    ? [NSDate distantFuture]
    : [NSDate dateWithTimeIntervalSinceNow:timeoutMs / 1000.0];

  /* Loop until we have an event in our queue or the deadline passes.
     nextEventMatchingMask may return internal Cocoa events that don't
     produce NEEvents -- we must keep waiting in that case. */
  while (eqTail == eqHead) {
    @autoreleasepool {
      NSEvent *ev = [NSApp nextEventMatchingMask:NSEventMaskAny
                                       untilDate:deadline
                                          inMode:NSDefaultRunLoopMode
                                         dequeue:YES];
      if (ev) {
        [NSApp sendEvent:ev];
        [NSApp updateWindows];
        /* drain remaining without blocking */
        while ((ev = [NSApp nextEventMatchingMask:NSEventMaskAny
                                        untilDate:nil
                                           inMode:NSDefaultRunLoopMode
                                          dequeue:YES]) != nil) {
          [NSApp sendEvent:ev];
          [NSApp updateWindows];
        }
      } else {
        /* nextEvent returned nil -- timeout expired */
        break;
      }
    }
  }

  if (eqTail == eqHead) {
    out->kind = NE_NONE;
    return 0;
  }
  *out = eventQueue[eqTail];
  eqTail = (eqTail + 1) % EVENT_QUEUE_SIZE;
  return 1;
}

/* ---- Modifier helpers ------------------------------------------------- */

static int translateModifiers(NSEventModifierFlags flags) {
  int m = 0;
  if (flags & NSEventModifierFlagShift)   m |= NE_MOD_SHIFT;
  if (flags & NSEventModifierFlagControl) m |= NE_MOD_CTRL;
  if (flags & NSEventModifierFlagOption)  m |= NE_MOD_ALT;
  if (flags & NSEventModifierFlagCommand) m |= NE_MOD_GUI;
  return m;
}

int cocoa_getModState(void) {
  NSEventModifierFlags flags = [NSEvent modifierFlags];
  return translateModifiers(flags);
}

/* ---- Key translation -------------------------------------------------- */

/* Returns NimEdit KeyCode ordinal.  Must match input.nim KeyCode enum. */
static int translateKeyCode(unsigned short kc) {
  switch (kc) {
    case 0x00: return 1;   /* keyA */
    case 0x0B: return 2;   /* keyB */
    case 0x08: return 3;   /* keyC */
    case 0x02: return 4;   /* keyD */
    case 0x0E: return 5;   /* keyE */
    case 0x03: return 6;   /* keyF */
    case 0x05: return 7;   /* keyG */
    case 0x04: return 8;   /* keyH */
    case 0x22: return 9;   /* keyI */
    case 0x26: return 10;  /* keyJ */
    case 0x28: return 11;  /* keyK */
    case 0x25: return 12;  /* keyL */
    case 0x2E: return 13;  /* keyM */
    case 0x2D: return 14;  /* keyN */
    case 0x1F: return 15;  /* keyO */
    case 0x23: return 16;  /* keyP */
    case 0x0C: return 17;  /* keyQ */
    case 0x0F: return 18;  /* keyR */
    case 0x01: return 19;  /* keyS */
    case 0x11: return 20;  /* keyT */
    case 0x20: return 21;  /* keyU */
    case 0x09: return 22;  /* keyV */
    case 0x0D: return 23;  /* keyW */
    case 0x07: return 24;  /* keyX */
    case 0x10: return 25;  /* keyY */
    case 0x06: return 26;  /* keyZ */
    case 0x12: return 28;  /* key1 -- note: key0 = 27, key1 = 28 .. key9 = 36 */
    case 0x13: return 29;  /* key2 */
    case 0x14: return 30;  /* key3 */
    case 0x15: return 31;  /* key4 */
    case 0x17: return 32;  /* key5 */
    case 0x16: return 33;  /* key6 */
    case 0x1A: return 34;  /* key7 */
    case 0x1C: return 35;  /* key8 */
    case 0x19: return 36;  /* key9 */
    case 0x1D: return 27;  /* key0 */
    case 0x7A: return 37;  /* keyF1 */
    case 0x78: return 38;  /* keyF2 */
    case 0x63: return 39;  /* keyF3 */
    case 0x76: return 40;  /* keyF4 */
    case 0x60: return 41;  /* keyF5 */
    case 0x61: return 42;  /* keyF6 */
    case 0x62: return 43;  /* keyF7 */
    case 0x64: return 44;  /* keyF8 */
    case 0x65: return 45;  /* keyF9 */
    case 0x6D: return 46;  /* keyF10 */
    case 0x67: return 47;  /* keyF11 */
    case 0x6F: return 48;  /* keyF12 */
    case 0x24: return 49;  /* keyEnter */
    case 0x4C: return 49;  /* keyEnter: the keypad's */
    case 0x52: return 27;  /* the keypad's 0 .. 9: key0 .. key9 */
    case 0x53: return 28;
    case 0x54: return 29;
    case 0x55: return 30;
    case 0x56: return 31;
    case 0x57: return 32;
    case 0x58: return 33;
    case 0x59: return 34;
    case 0x5B: return 35;
    case 0x5C: return 36;
    case 0x41: return 66;  /* keyPeriod: the keypad's decimal */
    case 0x45: return 70;  /* keyPlus: the keypad's */
    case 0x4E: return 68;  /* keyMinus: the keypad's */
    case 0x4B: return 67;  /* keySlash: the keypad's divide */
    case 0x51: return 69;  /* keyEqual: the keypad's */
    case 0x31: return 50;  /* keySpace */
    case 0x35: return 51;  /* keyEsc */
    case 0x30: return 52;  /* keyTab */
    case 0x33: return 53;  /* keyBackspace */
    case 0x75: return 54;  /* keyDelete */
    case 0x72: return 55;  /* keyInsert (Help key on Mac) */
    case 0x7B: return 56;  /* keyLeft */
    case 0x7C: return 57;  /* keyRight */
    case 0x7E: return 58;  /* keyUp */
    case 0x7D: return 59;  /* keyDown */
    case 0x74: return 60;  /* keyPageUp */
    case 0x79: return 61;  /* keyPageDown */
    case 0x73: return 62;  /* keyHome */
    case 0x77: return 63;  /* keyEnd */
    case 0x39: return 64;  /* keyCapslock */
    case 0x2B: return 65;  /* keyComma */
    case 0x2F: return 66;  /* keyPeriod */
    case 0x2C: return 67;  /* keySlash */
    case 0x1B: return 68;  /* keyMinus */
    case 0x18: return 69;  /* keyEqual */
    default:   return 0;   /* keyNone */
  }
}

static int translateKeyEvent(NSEvent *event) {
  /* A keyCode is a physical position on the keyboard and the layout decides
     what that position types. The table above is ANSI, so on a German
     keyboard it gets Y and Z backwards -- 0x06 types 'y' there and 0x10 types
     'z' -- which puts undo on the key labelled Y and redo on the one labelled
     Z. Punctuation moves too: '-' is 0x2C and '+' is 0x1E, so Cmd+plus and
     Cmd+minus land on neither.

     So anything that produces a character is identified by the character the
     current layout actually gives, and only the keys that produce none
     (arrows, F-keys, Home/End, ...) stay a lookup by position.
     charactersIgnoringModifiers drops every modifier but Shift, so Ctrl+Z
     still reports a plain "z" rather than a control code. */
  NSString *chars = [event charactersIgnoringModifiers];
  if (chars.length == 1) {
    unichar c = [chars characterAtIndex:0];
    if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    if (c >= 'a' && c <= 'z') return 1 + (c - 'a');           /* keyA..keyZ */
    if (c == '0') return 27;                                  /* key0 */
    if (c >= '1' && c <= '9') return 28 + (c - '1');          /* key1..key9 */
    switch (c) {
      case ',': return 65;  /* keyComma */
      case '.': return 66;  /* keyPeriod */
      case '/': return 67;  /* keySlash */
      case '-': return 68;  /* keyMinus */
      case '=': return 69;  /* keyEqual */
      case '+': return 70;  /* keyPlus */
    }
    /* Shifted digits ('!' for 1) and everything else fall through to the
       position, which is what the apps that bind digits expect. */
  }
  return translateKeyCode(event.keyCode);
}

/* ---- Font management -------------------------------------------------- */

/* A slot is 40 bytes, and one logical font size now costs up to four of them
   -- regular, bold, italic and bold italic -- so an editor that lets every
   panel be zoomed separately gets through the old 64 quickly. */
#define MAX_FONTS 256

typedef struct {
  CTFontRef font;
  int ascent, descent, lineHeight;
} FontSlot;

static FontSlot fonts[MAX_FONTS];
static int fontCount = 0;

int cocoa_openFont(const char *path, int size, int bold, int italic,
                   int *outAscent, int *outDescent, int *outLineHeight) {
  /* Take a slot that cocoa_closeFont freed before growing the table. Without
     the reuse this is append-only and MAX_FONTS is a lifetime budget, not a
     concurrent one: focim keeps one font per logical size and closes and
     reopens the whole cache every time the window moves to a display of
     another density, so a few drags between monitors would exhaust the table
     and openFont would start handing back 0 -- i.e. no text at all. */
  int idx = -1;
  for (int i = 0; i < fontCount; i++)
    if (!fonts[i].font) { idx = i; break; }
  if (idx < 0 && fontCount >= MAX_FONTS) return 0;

  CTFontRef ctFont = NULL;

  if (path[0] == '\0') {
    /* Empty path = platform default font, and every other driver reads that
       as "monospaced" (Consolas on Windows, fontconfig's `monospace` on X11).
       kCTFontUIFontSystem would hand back San Francisco, which is
       proportional -- so ask for the fixed-pitch UI font instead; it resolves
       to Menlo. Do NOT reach for "SF Mono" by name: CTFontCreateWithName
       falls back to Helvetica without an error when a name is unknown, and SF
       Mono is not name-accessible on a stock system. */
    ctFont = CTFontCreateUIFontForLanguage(kCTFontUIFontUserFixedPitch,
                                           (CGFloat)size, NULL);
  } else {
    /* Create font from file path */
    CFStringRef cfPath = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
    if (cfPath) {
      CFURLRef url = CFURLCreateWithFileSystemPath(NULL, cfPath, kCFURLPOSIXPathStyle, false);
      if (url) {
        CGDataProviderRef provider = CGDataProviderCreateWithURL(url);
        if (provider) {
          CGFontRef cgFont = CGFontCreateWithDataProvider(provider);
          if (cgFont) {
            ctFont = CTFontCreateWithGraphicsFont(cgFont, (CGFloat)size, NULL, NULL);
            CGFontRelease(cgFont);
          }
          CGDataProviderRelease(provider);
        }
        CFRelease(url);
      }
      CFRelease(cfPath);
    }
  }

  if (!ctFont) return 0;

  if (bold || italic) {
    /* Ask the family for the face, rather than emboldening or shearing the
       regular one: Menlo has real Bold, Italic and Bold Italic faces, and
       they keep the advance width of the regular face, so a monospaced grid
       stays a grid. A family without the face returns NULL here -- then the
       upright font stands in, which is what the styled text falls back to
       anyway. */
    CTFontSymbolicTraits traits = 0;
    if (bold) traits |= kCTFontTraitBold;
    if (italic) traits |= kCTFontTraitItalic;
    CTFontRef styled = CTFontCreateCopyWithSymbolicTraits(ctFont, 0.0, NULL,
                                                          traits, traits);
    if (styled) {
      CFRelease(ctFont);
      ctFont = styled;
    }
  }

  if (idx < 0) idx = fontCount++;  /* fontCount stays the high-water mark, so
                                      the `idx < fontCount` guards below hold */
  fonts[idx].font = ctFont;
  fonts[idx].ascent = (int)ceil(CTFontGetAscent(ctFont));
  fonts[idx].descent = (int)ceil(CTFontGetDescent(ctFont));
  fonts[idx].lineHeight = fonts[idx].ascent + fonts[idx].descent +
                          (int)ceil(CTFontGetLeading(ctFont));
  /* Ensure lineHeight is at least ascent + descent */
  if (fonts[idx].lineHeight < fonts[idx].ascent + fonts[idx].descent)
    fonts[idx].lineHeight = fonts[idx].ascent + fonts[idx].descent;

  *outAscent = fonts[idx].ascent;
  *outDescent = fonts[idx].descent;
  *outLineHeight = fonts[idx].lineHeight;
  return idx + 1;  /* 1-based handle */
}

void cocoa_closeFont(int handle) {
  int idx = handle - 1;
  if (idx >= 0 && idx < fontCount && fonts[idx].font) {
    CFRelease(fonts[idx].font);
    fonts[idx].font = NULL;
  }
}

void cocoa_getFontMetrics(int handle, int *asc, int *desc, int *lh) {
  int idx = handle - 1;
  if (idx >= 0 && idx < fontCount && fonts[idx].font) {
    *asc = fonts[idx].ascent;
    *desc = fonts[idx].descent;
    *lh = fonts[idx].lineHeight;
  } else {
    *asc = *desc = *lh = 0;
  }
}

/* Measure text width/height using Core Text */
void cocoa_measureText(int handle, const char *text, int *outW, int *outH) {
  int idx = handle - 1;
  *outW = 0; *outH = 0;
  if (idx < 0 || idx >= fontCount || !fonts[idx].font || !text || !text[0]) return;

  CFStringRef str = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
  if (!str) return;

  CFStringRef keys[] = { kCTFontAttributeName };
  CFTypeRef vals[] = { fonts[idx].font };
  CFDictionaryRef attrs = CFDictionaryCreate(NULL,
    (const void **)keys, (const void **)vals, 1,
    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

  CFAttributedStringRef attrStr = CFAttributedStringCreate(NULL, str, attrs);
  CTLineRef line = CTLineCreateWithAttributedString(attrStr);

  CGRect bounds = CTLineGetImageBounds(line, NULL);
  double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
  *outW = (int)ceil(width);
  *outH = fonts[idx].lineHeight;

  CFRelease(line);
  CFRelease(attrStr);
  CFRelease(attrs);
  CFRelease(str);
}

/* Draw text into `pixels` (w * h premultiplied 0xAARRGGBB, zeroed by the
   caller) instead of the window: the run as Core Text lays it out, its line
   placed the way cocoa_drawText places it. */
void cocoa_renderText(int handle, const char *text, int w, int h,
                      int r, int g, int b, int a, uint32_t *pixels) {
  int idx = handle - 1;
  if (idx < 0 || idx >= fontCount || !fonts[idx].font || !text || !text[0]) return;
  if (w <= 0 || h <= 0 || !pixels) return;

  CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  /* Premultiplied ARGB in a little-endian 32-bit word: the bytes are B, G,
     R, A, which is what a uint32_t 0xAARRGGBB is on every Mac. */
  CGContextRef ctx = CGBitmapContextCreate(pixels, w, h, 8, w * 4, space,
    kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
  CGColorSpaceRelease(space);
  if (!ctx) return;

  CFStringRef str = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
  if (!str) { CGContextRelease(ctx); return; }
  CGColorRef color = CGColorCreateSRGB(r/255.0, g/255.0, b/255.0, a/255.0);
  CFStringRef keys[] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
  CFTypeRef vals[] = { fonts[idx].font, color };
  CFDictionaryRef attrs = CFDictionaryCreate(NULL,
    (const void **)keys, (const void **)vals, 2,
    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFAttributedStringRef attrStr = CFAttributedStringCreate(NULL, str, attrs);
  CTLineRef line = CTLineCreateWithAttributedString(attrStr);

  /* A bitmap context is bottom-up already, and its first row in memory is
     the top one, so the baseline is measured from the bottom as in
     cocoa_drawText after its un-flip. */
  int lh = fonts[idx].lineHeight;
  CGFloat baseline = fonts[idx].descent +
                     (lh - fonts[idx].ascent - fonts[idx].descent) * 0.5;
  if (baseline < fonts[idx].descent) baseline = fonts[idx].descent;
  CGContextSetTextPosition(ctx, 0, baseline + (h - lh));
  CTLineDraw(line, ctx);
  CGContextFlush(ctx);

  CFRelease(line);
  CFRelease(attrStr);
  CFRelease(attrs);
  CGColorRelease(color);
  CFRelease(str);
  CGContextRelease(ctx);
}

/* ---- Backing bitmap context ------------------------------------------- */

static CGContextRef backingCtx = NULL;
static int backingW = 0, backingH = 0;
static CGFloat backingScale = 1.0;
/* Clip rect stack (simple, max 32 deep) */
#define MAX_CLIP_STACK 32
static CGRect clipStack[MAX_CLIP_STACK];
static int clipTop = 0;

static void ensureBacking(int w, int h, CGFloat scale) {
  if (w <= 0 || h <= 0 || scale <= 0) return;
  if (backingCtx && backingW == w && backingH == h && backingScale == scale) return;

  int pw = (int)(w * scale);
  int ph = (int)(h * scale);
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef next = CGBitmapContextCreate(NULL, pw, ph, 8, pw * 4,
    cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
  CGColorSpaceRelease(cs);
  if (!next) return;

  /* Drawing APIs use point coordinates, with their origin at the top left. */
  CGContextScaleCTM(next, scale, scale);
  CGContextTranslateCTM(next, 0, h);
  CGContextScaleCTM(next, 1.0, -1.0);
  CGContextSetShouldAntialias(next, true);
  CGContextSetShouldSmoothFonts(next, true);

  if (backingCtx) {
    /* Cocoa's live-resize loop can block the application's event pump.
       Retain the last frame at its original point size until the application
       redraws. A newly allocated blank bitmap makes the content disappear. */
    CGImageRef previous = CGBitmapContextCreateImage(backingCtx);
    if (previous) {
      CGContextSaveGState(next);
      CGContextTranslateCTM(next, 0, backingH);
      CGContextScaleCTM(next, 1.0, -1.0);
      CGContextSetInterpolationQuality(next, kCGInterpolationNone);
      CGContextDrawImage(next, CGRectMake(0, 0, backingW, backingH), previous);
      CGContextRestoreGState(next);
      CGImageRelease(previous);
    }
    CGContextRelease(backingCtx);
  }
  backingCtx = next;
  backingW = w;
  backingH = h;
  backingScale = scale;
}

/* A persistent native compositor, separate from Siwin's transient pixel buffer. */
int cocoa_prepareSiwinSurface(int pw, int ph, double scale) {
  if (pw <= 0 || ph <= 0 || scale <= 0) return 0;
  ensureBacking((int)lround(pw / scale), (int)lround(ph / scale), scale);
  return backingCtx != NULL;
}

int cocoa_presentSiwinSurface(void *pixels, int pw, int ph) {
  if (!backingCtx || !pixels || pw <= 0 || ph <= 0) return 0;
  CGContextFlush(backingCtx);
  const unsigned char *source = CGBitmapContextGetData(backingCtx);
  size_t stride = CGBitmapContextGetBytesPerRow(backingCtx);
  size_t width = CGBitmapContextGetWidth(backingCtx);
  size_t height = CGBitmapContextGetHeight(backingCtx);
  unsigned char *destination = pixels;
  for (int y = 0; y < ph; ++y)
    for (int x = 0; x < pw; ++x) {
      uint32_t p = (x < width && y < height)
        ? ((const uint32_t *)(source + (size_t)y * stride))[x] : 0;
      size_t offset = ((size_t)y * pw + x) * 4;
      destination[offset] = (p >> 16) & 255;
      destination[offset + 1] = (p >> 8) & 255;
      destination[offset + 2] = p & 255;
      destination[offset + 3] = p >> 24;
    }
  return 1;
}

void cocoa_detachSurface(void) {
  if (backingCtx) CGContextRelease(backingCtx);
  backingCtx = NULL;
  backingW = backingH = 0;
}

/* ---- Drawing primitives ----------------------------------------------- */

/* What changed since the last refresh, in points: only that is drawn on
   the window again (a caret's blink is a few pixels, not the window). */
static CGRect dirtyPts;
static int dirtyAll = 0;
static void markDirty(CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
  if (w <= 0 || h <= 0) return;
  CGRect r = CGRectMake(x, y, w, h);
  dirtyPts = CGRectIsEmpty(dirtyPts) ? r : CGRectUnion(dirtyPts, r);
}

void cocoa_fillRect(int x, int y, int w, int h, int r, int g, int b, int a) {
  markDirty(x, y, w, h);
  if (!backingCtx) return;
  CGContextSetRGBFillColor(backingCtx, r/255.0, g/255.0, b/255.0, a/255.0);
  CGContextFillRect(backingCtx, CGRectMake(x, y, w, h));
}

void cocoa_drawLine(int x1, int y1, int x2, int y2, int r, int g, int b, int a) {
  dirtyAll = 1;
  if (!backingCtx) return;
  CGContextSetRGBStrokeColor(backingCtx, r/255.0, g/255.0, b/255.0, a/255.0);
  CGContextSetLineWidth(backingCtx, 1.0);
  CGContextBeginPath(backingCtx);
  CGContextMoveToPoint(backingCtx, x1 + 0.5, y1 + 0.5);
  CGContextAddLineToPoint(backingCtx, x2 + 0.5, y2 + 0.5);
  CGContextStrokePath(backingCtx);
}

void cocoa_drawPoint(int x, int y, int r, int g, int b, int a) {
  markDirty(x, y, 1, 1);
  if (!backingCtx) return;
  CGContextSetRGBFillColor(backingCtx, r/255.0, g/255.0, b/255.0, a/255.0);
  CGContextFillRect(backingCtx, CGRectMake(x, y, 1, 1));
}

void cocoa_drawText(int fontHandle, int x, int y, const char *text,
                    int fgR, int fgG, int fgB, int fgA,
                    int bgR, int bgG, int bgB, int bgA,
                    int *outW, int *outH) {
  *outW = 0; *outH = 0;
  dirtyAll = 1;
  int idx = fontHandle - 1;
  if (idx < 0 || idx >= fontCount || !fonts[idx].font || !backingCtx) return;
  if (!text || !text[0]) return;

  CTFontRef ctFont = fonts[idx].font;
  int lh = fonts[idx].lineHeight;
  int asc = fonts[idx].ascent;

  /* Measure first for background fill */
  CFStringRef str = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
  if (!str) return;

  CGColorRef fgColor = CGColorCreateSRGB(fgR/255.0, fgG/255.0, fgB/255.0, fgA/255.0);

  CFStringRef keys[] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
  CFTypeRef vals[] = { ctFont, fgColor };
  CFDictionaryRef attrs = CFDictionaryCreate(NULL,
    (const void **)keys, (const void **)vals, 2,
    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

  CFAttributedStringRef attrStr = CFAttributedStringCreate(NULL, str, attrs);
  CTLineRef line = CTLineCreateWithAttributedString(attrStr);

  double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
  int tw = (int)ceil(width);

  /* Fill background */
  CGContextSetRGBFillColor(backingCtx, bgR/255.0, bgG/255.0, bgB/255.0, bgA/255.0);
  CGContextFillRect(backingCtx, CGRectMake(x, y, tw, lh));

  /* Draw text.
   * Core Text draws bottom-up. Our context is flipped to top-down.
   * We need to locally un-flip for Core Text rendering. */
  CGContextSaveGState(backingCtx);
  /* Move to the text baseline position:
   * In our flipped coords, y is top of the line, baseline is at y + ascent.
   * We un-flip around the line center. */
  CGContextTranslateCTM(backingCtx, 0, y + lh);
  CGContextScaleCTM(backingCtx, 1.0, -1.0);
  /* Now in un-flipped local coords, baseline is at (x, descent) from bottom */
  CGFloat baseline = fonts[idx].descent + (lh - asc - fonts[idx].descent) * 0.5;
  if (baseline < fonts[idx].descent) baseline = fonts[idx].descent;
  CGContextSetTextPosition(backingCtx, x, baseline);
  CTLineDraw(line, backingCtx);
  CGContextRestoreGState(backingCtx);

  *outW = tw;
  *outH = lh;

  CFRelease(line);
  CFRelease(attrStr);
  CFRelease(attrs);
  CGColorRelease(fgColor);
  CFRelease(str);
}

/* ---- Image management ------------------------------------------------- */

#define MAX_IMAGES 128

static CGImageRef imageSlots[MAX_IMAGES];
static int imageCount = 0;

int cocoa_loadImage(const char *path) {
  if (!path || path[0] == '\0') return 0;

  CFStringRef cfPath = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
  if (!cfPath) return 0;
  CFURLRef url = CFURLCreateWithFileSystemPath(NULL, cfPath, kCFURLPOSIXPathStyle, false);
  CFRelease(cfPath);
  if (!url) return 0;

  CGImageSourceRef source = CGImageSourceCreateWithURL(url, NULL);
  CFRelease(url);
  if (!source) return 0;

  CGImageRef cgImage = CGImageSourceCreateImageAtIndex(source, 0, NULL);
  CFRelease(source);
  if (!cgImage) return 0;

  /* Take a slot cocoa_freeImage emptied before growing the table, the way
     cocoa_openFont does. Without it a document that opens and closes the
     same picture often runs a fixed table out. */
  int idx = -1;
  for (int i = 0; i < imageCount; i++) {
    if (!imageSlots[i]) { idx = i; break; }
  }
  if (idx < 0) {
    if (imageCount >= MAX_IMAGES) { CGImageRelease(cgImage); return 0; }
    idx = imageCount++;
  }
  imageSlots[idx] = cgImage;
  return idx + 1; /* 1-based handle */
}

void cocoa_freeImage(int handle) {
  int idx = handle - 1;
  if (idx < 0 || idx >= imageCount || !imageSlots[idx]) return;
  CGImageRelease(imageSlots[idx]);
  imageSlots[idx] = NULL;
}

void cocoa_imageSize(int handle, int *outW, int *outH) {
  if (outW) *outW = 0;
  if (outH) *outH = 0;
  int idx = handle - 1;
  if (idx < 0 || idx >= imageCount || !imageSlots[idx]) return;
  if (outW) *outW = (int)CGImageGetWidth(imageSlots[idx]);
  if (outH) *outH = (int)CGImageGetHeight(imageSlots[idx]);
}

/* Finished pixels: host-order RGB (format 0) or premultiplied ARGB (format 1).
   blitRGBA clips only; drawRGBA maps the whole image into its destination. */
static int drawRGBA(const uint32_t *pixels, int w, int h,
                    int dstX, int dstY, int dstW, int dstH, int scaleImage, int format) {
  if (!backingCtx || !pixels || w <= 0 || h <= 0 || dstW <= 0 || dstH <= 0)
    return 0;

  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  if (!cs) return 0;
  CGDataProviderRef prov =
    CGDataProviderCreateWithData(NULL, pixels, (size_t)w * (size_t)h * 4, NULL);
  if (!prov) { CGColorSpaceRelease(cs); return 0; }

  /* Interpret the pixel words in host byte order; only alpha mode reads A. */
  CGImageRef img = CGImageCreate(
    (size_t)w, (size_t)h, 8, 32, (size_t)w * 4, cs,
    kCGBitmapByteOrder32Host | (format == 1 ? kCGImageAlphaPremultipliedFirst : kCGImageAlphaNoneSkipFirst),
    prov, NULL, false, kCGRenderingIntentDefault);
  CGDataProviderRelease(prov);
  CGColorSpaceRelease(cs);
  if (!img) return 0;

  int cw = scaleImage ? dstW : (w < dstW ? w : dstW);
  int ch = scaleImage ? dstH : (h < dstH ? h : dstH);
  markDirty(dstX, dstY, cw, ch);
  int drawW = scaleImage ? dstW : w;
  int drawH = scaleImage ? dstH : h;

  CGContextSaveGState(backingCtx);
  CGContextSetBlendMode(backingCtx, kCGBlendModeNormal);
  CGContextClipToRect(backingCtx, CGRectMake(dstX, dstY, cw, ch));
  /* The view is flipped and a CGImage is bottom-up, so the destination is
     flipped back around itself before the picture goes down in it. */
  CGContextTranslateCTM(backingCtx, dstX, dstY + drawH);
  CGContextScaleCTM(backingCtx, 1.0, -1.0);
  if (scaleImage) CGContextSetInterpolationQuality(backingCtx, kCGInterpolationNone);
  CGContextDrawImage(backingCtx, CGRectMake(0, 0, drawW, drawH), img);
  CGContextRestoreGState(backingCtx);

  CGImageRelease(img);
  return 1;
}

int cocoa_blitRGBA(const uint32_t *pixels, int w, int h,
                   int dstX, int dstY, int dstW, int dstH, int format) {
  return drawRGBA(pixels, w, h, dstX, dstY, dstW, dstH, 0, format);
}

int cocoa_drawRGBA(const uint32_t *pixels, int w, int h,
                   int dstX, int dstY, int dstW, int dstH, int format) {
  return drawRGBA(pixels, w, h, dstX, dstY, dstW, dstH, 1, format);
}

void cocoa_drawImage(int handle, int srcX, int srcY, int srcW, int srcH,
                     int dstX, int dstY, int dstW, int dstH) {
  markDirty(dstX, dstY, dstW, dstH);
  int idx = handle - 1;
  if (idx < 0 || idx >= imageCount || !imageSlots[idx] || !backingCtx) return;

  CGImageRef img = imageSlots[idx];
  size_t imgW = CGImageGetWidth(img);
  size_t imgH = CGImageGetHeight(img);

  CGRect srcRect = CGRectMake(srcX, srcY, srcW, srcH);
  CGRect dstRect = CGRectMake(dstX, dstY, dstW, dstH);

  CGContextSaveGState(backingCtx);
  /* Clip to destination rect */
  CGContextClipToRect(backingCtx, dstRect);
  /* Scale and translate so the source rect maps to the destination rect */
  CGFloat scaleX = dstW / (CGFloat)srcW;
  CGFloat scaleY = dstH / (CGFloat)srcH;
  CGContextTranslateCTM(backingCtx, dstX - srcX * scaleX, dstY - srcY * scaleY);
  CGContextScaleCTM(backingCtx, scaleX, scaleY);
  /* Flip Y because CGImage is bottom-up and our view is flipped */
  CGContextTranslateCTM(backingCtx, 0, imgH);
  CGContextScaleCTM(backingCtx, 1.0, -1.0);
  CGContextDrawImage(backingCtx, CGRectMake(0, 0, imgW, imgH), img);
  CGContextRestoreGState(backingCtx);
}

void cocoa_setClipRect(int x, int y, int w, int h) {
  if (!backingCtx) return;
  CGContextRestoreGState(backingCtx);
  CGContextSaveGState(backingCtx);
  CGContextClipToRect(backingCtx, CGRectMake(x, y, w, h));
}

void cocoa_saveState(void) {
  if (!backingCtx) return;
  CGContextSaveGState(backingCtx);
}

void cocoa_restoreState(void) {
  if (!backingCtx) return;
  CGContextRestoreGState(backingCtx);
}

/* ---- Clipboard -------------------------------------------------------- */

const char *cocoa_getClipboardText(void) {
  @autoreleasepool {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSString *s = [pb stringForType:NSPasteboardTypeString];
    if (!s) return "";
    /* Return a C string that persists until next call */
    static char *buf = NULL;
    free(buf);
    const char *utf8 = [s UTF8String];
    buf = strdup(utf8);
    return buf;
  }
}

void cocoa_putClipboardText(const char *text) {
  @autoreleasepool {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:[NSString stringWithUTF8String:text]
          forType:NSPasteboardTypeString];
  }
}

/* ---- Timing ----------------------------------------------------------- */

static uint64_t startTime = 0;
static mach_timebase_info_data_t timebaseInfo;

uint32_t cocoa_getTicks(void) {
  uint64_t elapsed = mach_absolute_time() - startTime;
  uint64_t nanos = elapsed * timebaseInfo.numer / timebaseInfo.denom;
  return (uint32_t)(nanos / 1000000);
}

void cocoa_delay(uint32_t ms) {
  [NSThread sleepForTimeInterval:ms / 1000.0];
}

/* ---- A graphics tablet's pen ------------------------------------------ */

static int penEraser = 0;   /* the end of the pen near the tablet is its eraser */

static void notePenProximity(NSEvent *event) {
  /* Only a proximity event says which end of the pen came near. */
  penEraser = [event isEnteringProximity] &&
              [event pointingDeviceType] == NSPointingDeviceTypeEraser;
}

static void withPen(NEEvent *e, NSEvent *event) {
  /* a mouse event a tablet's pen made: how the pen is held */
  NSEventSubtype sub = [event subtype];
  if (sub == NSEventSubtypeTabletProximity) notePenProximity(event);
  if (sub != NSEventSubtypeTabletPoint) return;
  NSPoint tilt = [event tilt];
  e->pen = penEraser ? 2 : 1;
  e->pressure = [event pressure];
  e->tiltX = (float)tilt.x;
  e->tiltY = (float)tilt.y;
  e->rotation = [event rotation];
}

/* ---- NSView subclass -------------------------------------------------- */

/* The left button's last press: a window drag (the app's own title bar)
   starts from it. */
static NSEvent *lastMouseDown = nil;
/* ... and its last drag since: a drag of files out of the window starts
   from that. */
static NSEvent *lastMouseDragged = nil;

/* The left button pressed with Control: a right click, as everywhere on a
   Mac (its release is the right button's too). */
static int controlClick = 0;

/* Where the caret of the text being typed is (the view's points): an input
   method composes there (cocoa_setTextCaret). */
static NSRect textCaret = {{0, 0}, {1, 16}};

/* Each drop of files' paths, in the order of their NE_FILE_DROP events. */
static NSMutableArray *drops = nil;

/* The pointer as it leaves the window: nothing in it is under the pointer. */
static void pushOutside(NSEventModifierFlags flags) {
  NEEvent e = {0};
  e.kind = NE_MOUSE_MOVE;
  e.x = -100000;   /* (OutsideWindow) */
  e.y = -100000;
  e.mods = translateModifiers(flags);
  pushEvent(e);
}

@interface NimEditView : NSView <NSTextInputClient, NSDraggingDestination>
@property (nonatomic) BOOL hasMarkedText;
@property (nonatomic) NSUInteger markedLength;
- (void)releasedAt:(NSPoint)p flags:(NSEventModifierFlags)flags others:(NSUInteger)others;
@end

@implementation NimEditView {
  NSTrackingArea *_trackingArea;
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)canBecomeKeyView { return YES; }
- (BOOL)isFlipped { return YES; }

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_trackingArea) [self removeTrackingArea:_trackingArea];
  _trackingArea = [[NSTrackingArea alloc]
    initWithRect:self.bounds
         options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                 NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
           owner:self
        userInfo:nil];
  [self addTrackingArea:_trackingArea];
}

- (void)drawRect:(NSRect)dirtyRect {
  if (!backingCtx) return;
  CGContextRef viewCtx = [[NSGraphicsContext currentContext] CGContext];
  CGImageRef img = CGBitmapContextCreateImage(backingCtx);
  if (img) {
    NSRect bounds = self.bounds;
    /* Flip for drawing since view is flipped but CGImage is bottom-up */
    CGContextSaveGState(viewCtx);
    CGContextTranslateCTM(viewCtx, 0, bounds.size.height);
    CGContextScaleCTM(viewCtx, 1.0, -1.0);
    CGContextDrawImage(viewCtx, CGRectMake(0, 0, bounds.size.width, bounds.size.height), img);
    CGContextRestoreGState(viewCtx);
    CGImageRelease(img);
  }
}

/* ---- Keyboard events ---- */

- (void)keyDown:(NSEvent *)event {
  /* While an input method composes (marked text) every key is its own:
     Return takes what was composed, Backspace and the arrows edit it there,
     Esc drops it -- none of them is the app's. */
  if (self.hasMarkedText) {
    [self interpretKeyEvents:@[event]];
    return;
  }
  NEEvent e = {0};
  e.kind = NE_KEY_DOWN;
  e.key = translateKeyEvent(event);
  e.mods = translateModifiers(event.modifierFlags);
  pushEvent(e);

  /* Only feed to interpretKeyEvents when the key can produce text input.
     Skip for Ctrl/Cmd combos and special keys (arrows, backspace, etc.)
     — the app handles those via evKeyDown already. */
  int m = e.mods;
  if ((m & (NE_MOD_CTRL | NE_MOD_GUI)) == 0 && e.key == 0) {
    [self interpretKeyEvents:@[event]];
  } else if ((m & (NE_MOD_CTRL | NE_MOD_GUI)) == 0) {
    /* Known key but no modifier — still try for text (e.g. space, comma).
       But skip keys that are purely control keys. */
    unsigned short kc = event.keyCode;
    switch (kc) {
      case 0x33: /* backspace */
      case 0x75: /* delete */
      case 0x35: /* escape */
      case 0x30: /* tab */
      case 0x24: /* return */
      case 0x4C: /* the keypad's enter */
      case 0x7B: case 0x7C: case 0x7E: case 0x7D: /* arrows */
      case 0x74: case 0x79: case 0x73: case 0x77: /* pgup/pgdn/home/end */
      case 0x72: /* insert/help */
      case 0x7A: case 0x78: case 0x63: case 0x76: /* F1-F4 */
      case 0x60: case 0x61: case 0x62: case 0x64: /* F5-F8 */
      case 0x65: case 0x6D: case 0x67: case 0x6F: /* F9-F12 */
        break;
      default:
        [self interpretKeyEvents:@[event]];
        break;
    }
  }
}

/* Suppress the system beep for unhandled key combos */
- (void)doCommandBySelector:(SEL)selector {
  /* intentionally empty — swallows the NSBeep that interpretKeyEvents
     would otherwise trigger for keys without a binding */
}

/* Cmd+W is the app's key (Ctrl+W, which may close a tab), not the menu's
   Close: the window closes when nothing in the app takes it. */
- (BOOL)performKeyEquivalent:(NSEvent *)event {
  NSEventModifierFlags f = event.modifierFlags &
    (NSEventModifierFlagShift | NSEventModifierFlagControl |
     NSEventModifierFlagOption | NSEventModifierFlagCommand);
  if (event.type == NSEventTypeKeyDown && f == NSEventModifierFlagCommand &&
      [[event charactersIgnoringModifiers] isEqualToString:@"w"]) {
    [self keyDown:event];
    return YES;
  }
  return [super performKeyEquivalent:event];
}

- (void)keyUp:(NSEvent *)event {
  NEEvent e = {0};
  e.kind = NE_KEY_UP;
  e.key = translateKeyEvent(event);
  e.mods = translateModifiers(event.modifierFlags);
  pushEvent(e);
}

- (void)flagsChanged:(NSEvent *)event {
  /* Ignore standalone modifier key events */
}

/* ---- Mouse events ---- */

- (void)mouseDown:(NSEvent *)event {
  NSEventModifierFlags flags = event.modifierFlags;
  if ((flags & NSEventModifierFlagControl) && !(flags & NSEventModifierFlagCommand)) {
    /* Control + click: the right button's, without the Control */
    controlClick = 1;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NEEvent e = {0};
    e.kind = NE_MOUSE_DOWN;
    e.button = NE_MB_RIGHT;
    e.x = (int)p.x;
    e.y = (int)p.y;
    e.clicks = (int)event.clickCount;
    e.mods = translateModifiers(flags & ~NSEventModifierFlagControl);
    withPen(&e, event);
    pushEvent(e);
    return;
  }
  controlClick = 0;
  lastMouseDown = event;
  lastMouseDragged = nil;
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  NEEvent e = {0};
  e.kind = NE_MOUSE_DOWN;
  e.button = NE_MB_LEFT;
  e.x = (int)p.x;
  e.y = (int)p.y;
  e.clicks = (int)event.clickCount;
  e.mods = translateModifiers(event.modifierFlags);
  withPen(&e, event);
  pushEvent(e);
}

- (void)mouseUp:(NSEvent *)event {
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  NEEvent e = {0};
  e.kind = NE_MOUSE_UP;
  e.button = controlClick ? NE_MB_RIGHT : NE_MB_LEFT;
  e.x = (int)p.x;
  e.y = (int)p.y;
  e.mods = translateModifiers(controlClick ? event.modifierFlags & ~NSEventModifierFlagControl
                                           : event.modifierFlags);
  controlClick = 0;
  withPen(&e, event);
  pushEvent(e);
  [self releasedAt:p flags:event.modifierFlags others:~1];
}

/* Let go outside the window, no other button down: the pointer is not over
   it any more (mouseExited: came while the button was held). */
- (void)releasedAt:(NSPoint)p flags:(NSEventModifierFlags)flags others:(NSUInteger)others {
  if (!NSPointInRect(p, self.bounds) && ([NSEvent pressedMouseButtons] & others) == 0)
    pushOutside(flags);
}

- (void)mouseExited:(NSEvent *)event {
  /* (with a button down a drag goes on outside: the release tells) */
  if ([NSEvent pressedMouseButtons] == 0) pushOutside(event.modifierFlags);
}

- (void)rightMouseDown:(NSEvent *)event {
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  NEEvent e = {0};
  e.kind = NE_MOUSE_DOWN;
  e.button = NE_MB_RIGHT;
  e.x = (int)p.x;
  e.y = (int)p.y;
  e.clicks = (int)event.clickCount;
  e.mods = translateModifiers(event.modifierFlags);
  withPen(&e, event);
  pushEvent(e);
}

- (void)rightMouseUp:(NSEvent *)event {
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  NEEvent e = {0};
  e.kind = NE_MOUSE_UP;
  e.button = NE_MB_RIGHT;
  e.x = (int)p.x;
  e.y = (int)p.y;
  e.mods = translateModifiers(event.modifierFlags);
  withPen(&e, event);
  pushEvent(e);
  [self releasedAt:p flags:event.modifierFlags others:~2];
}

- (void)otherMouseDown:(NSEvent *)event {
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  NEEvent e = {0};
  e.kind = NE_MOUSE_DOWN;
  e.button = event.buttonNumber == 3 ? 3 : event.buttonNumber == 4 ? 4 : NE_MB_MIDDLE;
  e.x = (int)p.x;
  e.y = (int)p.y;
  e.clicks = (int)event.clickCount;
  e.mods = translateModifiers(event.modifierFlags);
  withPen(&e, event);
  pushEvent(e);
}

- (void)otherMouseUp:(NSEvent *)event {
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  NEEvent e = {0};
  e.kind = NE_MOUSE_UP;
  e.button = event.buttonNumber == 3 ? 3 : event.buttonNumber == 4 ? 4 : NE_MB_MIDDLE;
  e.x = (int)p.x;
  e.y = (int)p.y;
  e.mods = translateModifiers(event.modifierFlags);
  withPen(&e, event);
  pushEvent(e);
}

static int currentButtons(NSEvent *event) {
  NSUInteger pressed = [NSEvent pressedMouseButtons];
  int b = 0;
  if (pressed & (1 << 0)) b |= 1;  /* left */
  if (pressed & (1 << 1)) b |= 2;  /* right */
  if (pressed & (1 << 2)) b |= 4;  /* middle */
  return b;
}

- (void)mouseMoved:(NSEvent *)event {
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  NEEvent e = {0};
  e.kind = NE_MOUSE_MOVE;
  e.x = (int)p.x;
  e.y = (int)p.y;
  e.xrel = (int)event.deltaX;
  e.yrel = (int)event.deltaY;
  e.buttons = currentButtons(event);
  e.mods = translateModifiers(event.modifierFlags);
  withPen(&e, event);
  pushEvent(e);
}

- (void)mouseDragged:(NSEvent *)event {
  lastMouseDragged = event;
  [self mouseMoved:event];
}

- (void)rightMouseDragged:(NSEvent *)event {
  [self mouseMoved:event];
}

- (void)otherMouseDragged:(NSEvent *)event {
  [self mouseMoved:event];
}

- (void)scrollWheel:(NSEvent *)event {
  /* Whole notches, what is left of one kept for the next (a slow turn, a
     slow swipe). A touch pad gives points: 48 to a notch -- three lines,
     what a wheel's notch scrolls -- so the page goes about as far as the
     fingers, as on Windows; a wheel gives lines (fractions of one when
     turned slowly): one to a notch. The system makes Shift + the wheel
     sideways itself. Right is > 0, as on the other systems: AppKit's
     deltaX is > 0 to the left. */
  static double accumX = 0, accumY = 0;
  static int precise = -1;
  int nowPrecise = event.hasPreciseScrollingDeltas ? 1 : 0;
  if (nowPrecise != precise) { accumX = 0; accumY = 0; precise = nowPrecise; }
  double unit = nowPrecise ? 48.0 : 1.0;
  double dx = event.scrollingDeltaX / unit, dy = event.scrollingDeltaY / unit;
  if (dx * accumX < 0) accumX = 0;   /* (the other way now) */
  if (dy * accumY < 0) accumY = 0;
  accumX += dx;
  accumY += dy;
  int nx = (int)accumX, ny = (int)accumY;
  accumX -= nx;
  accumY -= ny;
  if (nx == 0 && ny == 0) return;
  NEEvent e = {0};
  e.kind = NE_MOUSE_WHEEL;
  e.x = -nx;
  e.y = ny;
  e.mods = translateModifiers(event.modifierFlags);
  pushEvent(e);
}

/* ---- Files dropped from the Finder ---- */

static NSDictionary *fileUrlsOnly(void) {
  return @{NSPasteboardURLReadingFileURLsOnlyKey: @YES};
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
  /* (the window's own files dragged out come back: not taken) */
  if ([sender draggingSource] != nil) return NSDragOperationNone;
  return [[sender draggingPasteboard] canReadObjectForClasses:@[[NSURL class]]
                                                      options:fileUrlsOnly()]
    ? NSDragOperationCopy : NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
  return [self draggingEntered:sender];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  if ([sender draggingSource] != nil) return NO;
  NSArray *urls = [[sender draggingPasteboard] readObjectsForClasses:@[[NSURL class]]
                                                             options:fileUrlsOnly()];
  NSMutableArray *paths = [NSMutableArray array];
  for (NSURL *u in urls)
    if ([u isFileURL] && [u path]) [paths addObject:[u path]];
  if ([paths count] == 0) return NO;
  if (!drops) drops = [NSMutableArray array];
  [drops addObject:paths];
  NSPoint p = [self convertPoint:[sender draggingLocation] fromView:nil];
  NEEvent e = {0};
  e.kind = NE_FILE_DROP;
  e.x = (int)p.x;
  e.y = (int)p.y;
  e.mods = translateModifiers([NSEvent modifierFlags]);
  if (!pushEvent(e)) [drops removeLastObject];
  return YES;
}

/* ---- NSTextInputClient (for text input / IME) ---- */

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
  /* (what an input method composed is taken: nothing is marked now) */
  self.hasMarkedText = NO;
  self.markedLength = 0;
  markedUTF8[0] = 0;
  markedCaret = 0;
  NSString *s = ([string isKindOfClass:[NSAttributedString class]])
    ? [string string] : string;
  const char *utf8 = [s UTF8String];
  if (!utf8) return;

  /* Send each character as a separate text input event */
  NSUInteger len = strlen(utf8);
  NSUInteger i = 0;
  while (i < len) {
    NEEvent e = {0};
    e.kind = NE_TEXT_INPUT;
    /* Copy one UTF-8 codepoint (1-4 bytes) */
    unsigned char c = (unsigned char)utf8[i];
    int cpLen = 1;
    if (c >= 0xC0) cpLen = 2;
    if (c >= 0xE0) cpLen = 3;
    if (c >= 0xF0) cpLen = 4;
    for (int j = 0; j < cpLen && j < 4 && (i + j) < len; j++)
      e.text[j] = utf8[i + j];
    pushEvent(e);
    i += cpLen;
  }
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange
      replacementRange:(NSRange)replacementRange {
  NSString *s = [string isKindOfClass:[NSAttributedString class]] ? [string string] : string;
  NSUInteger n = [s length];
  self.markedLength = n;
  self.hasMarkedText = n > 0;
  /* (the app draws it in the text box: its text and caret, in UTF-8) */
  const char *u = [s UTF8String];
  snprintf(markedUTF8, sizeof markedUTF8, "%s", u ? u : "");
  NSUInteger at = selectedRange.location <= n ? selectedRange.location : n;
  const char *b = [[s substringToIndex:at] UTF8String];
  markedCaret = b ? (int)strlen(b) : 0;
  NEEvent e = {0};
  e.kind = NE_TEXT_EDIT;
  pushEvent(e);
}

- (void)unmarkText {
  self.hasMarkedText = NO;
  self.markedLength = 0;
  markedUTF8[0] = 0;
  markedCaret = 0;
  NEEvent e = {0};
  e.kind = NE_TEXT_EDIT;
  pushEvent(e);
}
- (BOOL)hasMarkedText { return _hasMarkedText; }
- (NSRange)markedRange {
  return _hasMarkedText ? NSMakeRange(0, self.markedLength) : NSMakeRange(NSNotFound, 0);
}
- (NSRange)selectedRange { return NSMakeRange(_hasMarkedText ? self.markedLength : 0, 0); }
- (NSRect)firstRectForCharacterRange:(NSRange)range
                         actualRange:(NSRangePointer)actual {
  /* The caret the app told (cocoa_setTextCaret), on the screen: the input
     method's candidates go under it. */
  if (actual) *actual = range;
  NSRect inWindow = [self convertRect:textCaret toView:nil];
  return [[self window] convertRectToScreen:inWindow];
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point { return NSNotFound; }
- (NSArray *)validAttributesForMarkedText { return @[]; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range
                                                actualRange:(NSRangePointer)actual {
  return nil;
}

@end

/* ---- Window delegate -------------------------------------------------- */

static int appItemChosen = 0;   /* the app's item in the menu bar was picked */

void cocoa_setMaximized(int on);
int cocoa_isMaximized(void);

/* The app's name: its bundle's (Info.plist), else the program's. */
static NSString *appName(void) {
  NSBundle *b = [NSBundle mainBundle];
  for (NSString *key in @[@"CFBundleDisplayName", @"CFBundleName"]) {
    id n = [b objectForInfoDictionaryKey:key];
    if ([n isKindOfClass:[NSString class]] && [n length] > 0) return n;
  }
  NSString *n = [[NSProcessInfo processInfo] processName];
  return n ? n : @"";
}

/* ---- the window's place, kept between runs ($RETRO_WINDOW_STATE) ----
   A program started again and again while it is worked on (`retrokit run
   --watch`) opens its window where the last run left it, as uirelays'
   services.nim has it: one line, "x y w h aw ah" -- the window's inside on
   the screen, from the top left of the first screen, in points, and the
   size the app asked for then (a size the app asks for that is not that one
   is a change to its code, and wins over the size the user gave). */

static int askedW = 0, askedH = 0;     /* the inside's size the app asked for */

static CGFloat screensTop(void) {
  NSArray *screens = [NSScreen screens];
  return [screens count] > 0 ? NSMaxY([[screens objectAtIndex:0] frame]) : 0;
}

static void notePlace(NSWindow *w) {
  const char *path = getenv("RETRO_WINDOW_STATE");
  if (!path || !*path || !w || [w isMiniaturized] || cocoa_isMaximized()) return;
  NSRect c = [w contentRectForFrameRect:[w frame]];
  FILE *f = fopen(path, "w");
  if (!f) return;
  fprintf(f, "%d %d %d %d %d %d\n", (int)c.origin.x, (int)(screensTop() - NSMaxY(c)),
          (int)c.size.width, (int)c.size.height, askedW, askedH);
  fclose(f);
}

static BOOL keptPlace(BOOL sizable, NSRect *r) {
  /* (`r`, the inside asked for, moved -- and sized -- where the last run left it) */
  const char *path = getenv("RETRO_WINDOW_STATE");
  if (!path || !*path) return NO;
  FILE *f = fopen(path, "r");
  if (!f) return NO;
  int x, y, w, h, aw, ah;
  int n = fscanf(f, "%d %d %d %d %d %d", &x, &y, &w, &h, &aw, &ah);
  fclose(f);
  if (n != 6) return NO;
  if (sizable && aw == askedW && ah == askedH && w > 0 && h > 0) {
    r->size.width = w;
    r->size.height = h;
  }
  r->origin.x = x;
  r->origin.y = screensTop() - y - r->size.height;
  return YES;
}

@interface NimEditWindowDelegate : NSObject <NSWindowDelegate>
@end

@implementation NimEditWindowDelegate

- (BOOL)windowShouldClose:(NSWindow *)sender {
  NEEvent e = {0};
  e.kind = NE_WINDOW_CLOSE;
  pushEvent(e);
  return NO;  /* let the app decide */
}

- (void)windowDidResize:(NSNotification *)n {
  NSWindow *w = n.object;
  NSRect frame = [[w contentView] frame];
  CGFloat scale = [w backingScaleFactor];
  ensureBacking((int)frame.size.width, (int)frame.size.height, scale);
  [[w contentView] setNeedsDisplay:YES];

  NEEvent e = {0};
  e.kind = NE_WINDOW_RESIZE;
  e.x = (int)frame.size.width;
  e.y = (int)frame.size.height;
  pushEvent(e);
  notePlace(w);
}

- (void)windowDidMove:(NSNotification *)n {
  notePlace(n.object);
}

- (void)windowDidChangeBackingProperties:(NSNotification *)n {
  /* A screen-density change can leave the point dimensions unchanged. */
  [self windowDidResize:n];
}

- (void)windowDidBecomeKey:(NSNotification *)n {
  NEEvent e = {0};
  e.kind = NE_WINDOW_FOCUS_GAINED;
  pushEvent(e);
}

- (void)windowDidResignKey:(NSNotification *)n {
  NEEvent e = {0};
  e.kind = NE_WINDOW_FOCUS_LOST;
  pushEvent(e);
}

- (void)requestQuit:(id)sender {
  /* The app menu's Quit item lands here instead of on NSApp's terminate:,
     which would kill the process from inside the menu's own event handling --
     the app would never see the keystroke and never get to run its shutdown
     path. Queueing NE_QUIT lets Cmd+Q reach the app like every other Cmd
     combination, and matches what windowShouldClose: above already does for
     the close button. */
  NEEvent e = {0};
  e.kind = NE_QUIT;
  pushEvent(e);
}

- (void)minimizeWindow:(id)sender {
  /* (a window without the system's frame has no button for it: done here) */
  [[NSApp mainWindow] miniaturize:nil];
}

- (void)zoomWindow:(id)sender {
  cocoa_setMaximized(!cocoa_isMaximized());
}

- (void)closeWindow:(id)sender {
  /* Close, as the close button: the app decides */
  NEEvent e = {0};
  e.kind = NE_WINDOW_CLOSE;
  pushEvent(e);
}

- (void)chooseAppItem:(id)sender {
  /* The app's item in the Window menu: told once (cocoa_menuItemChosen),
     and an event of nothing wakes the app to ask. */
  appItemChosen = 1;
  NEEvent e = {0};
  e.kind = NE_NONE;
  pushEvent(e);
}

@end

/* ---- A window without the system's frame ------------------------------ */
/* An app that draws its own title bar and borders gets a borderless window,
   still resizable and miniaturizable. Such a window does not take the
   keyboard unless it says it can: NimEditWindow says so (a titled one could
   anyway). */

@interface NimEditWindow : NSWindow
@end

@implementation NimEditWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

static int systemFrame = 1;          /* the system draws the frame */
static int resizable = 1;            /* the user may size the window */
static NSRect unzoomedFrame;         /* where a borderless window was before
                                        it was maximized */

static NSUInteger styleFor(int framed) {
  NSUInteger style = framed ? (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                               NSWindowStyleMaskMiniaturizable)
                            : (NSWindowStyleMaskBorderless | NSWindowStyleMaskMiniaturizable);
  return resizable ? (style | NSWindowStyleMaskResizable) : style;
}

/* ---- Window management ------------------------------------------------ */

static NSWindow *mainWindow = nil;
static NimEditView *mainView = nil;
static NimEditWindowDelegate *winDelegate = nil;

/* ---- The app's item in the menu bar ----------------------------------- */
/* uirelays' `menuItem`: an item of the app's in a Window menu of the menu
   bar, which is there whatever the window's frame -- so it is how the user
   gets from either frame to the other. Asked for before the window, it is
   added with the menu bar. */

static NSString *appItemLabel = nil;   /* "" or nil: no item */
static int appItemChecked = 0;
static NSMenuItem *appItem = nil;      /* the item, once in the menu bar */
static NSMenuItem *appItemLine = nil;  /* ... and the line over it */
static NSMenu *windowMenu = nil;       /* the menu bar's Window menu */

static void syncAppItem(void) {
  if (!windowMenu) return;             /* (made with the window) */
  if (appItemLabel.length == 0) {
    if (appItem) {
      [windowMenu removeItem:appItem];
      [windowMenu removeItem:appItemLine];
    }
    appItem = nil;
    appItemLine = nil;
    return;
  }
  if (!appItem) {
    appItemLine = [NSMenuItem separatorItem];
    [windowMenu addItem:appItemLine];
    appItem = [[NSMenuItem alloc] initWithTitle:appItemLabel
                                         action:@selector(chooseAppItem:)
                                  keyEquivalent:@""];
    [appItem setTarget:winDelegate];
    [windowMenu addItem:appItem];
  }
  [appItem setTitle:appItemLabel];
  [appItem setState:appItemChecked ? NSControlStateValueOn : NSControlStateValueOff];
}

static NSMenuItem *menuItem(NSMenu *menu, NSString *title, SEL action, NSString *key,
                            NSEventModifierFlags mods, id target) {
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
  if (key.length > 0) [item setKeyEquivalentModifierMask:mods];
  if (target) [item setTarget:target];
  [menu addItem:item];
  return item;
}

static void makeMenuBar(void) {
  /* The menus every Mac app has: the app's (Hide, Hide Others, Show All,
     Quit, by the app's name) and the Window menu (Minimize, Zoom, Close;
     the windows; the app's own item) */
  NSString *name = appName();
  NSMenu *menubar = [[NSMenu alloc] init];
  NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
  [menubar addItem:appMenuItem];
  NSMenu *appMenu = [[NSMenu alloc] initWithTitle:name];
  NSEventModifierFlags cmd = NSEventModifierFlagCommand;
  menuItem(appMenu, [@"Hide " stringByAppendingString:name], @selector(hide:), @"h", cmd, NSApp);
  menuItem(appMenu, @"Hide Others", @selector(hideOtherApplications:), @"h",
           cmd | NSEventModifierFlagOption, NSApp);
  menuItem(appMenu, @"Show All", @selector(unhideAllApplications:), @"", 0, NSApp);
  [appMenu addItem:[NSMenuItem separatorItem]];
  menuItem(appMenu, [@"Quit " stringByAppendingString:name], @selector(requestQuit:), @"q",
           cmd, winDelegate);
  [appMenuItem setSubmenu:appMenu];
  windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
  menuItem(windowMenu, @"Minimize", @selector(minimizeWindow:), @"m", cmd, winDelegate);
  menuItem(windowMenu, @"Zoom", @selector(zoomWindow:), @"", 0, winDelegate);
  [windowMenu addItem:[NSMenuItem separatorItem]];
  /* (Cmd+W itself is the app's key first: the view's performKeyEquivalent:) */
  menuItem(windowMenu, @"Close", @selector(closeWindow:), @"w", cmd, winDelegate);
  NSMenuItem *windowMenuItem = [[NSMenuItem alloc] initWithTitle:@"Window" action:nil
                                                   keyEquivalent:@""];
  [windowMenuItem setSubmenu:windowMenu];
  [menubar addItem:windowMenuItem];
  [NSApp setMainMenu:menubar];
  [NSApp setWindowsMenu:windowMenu];
  /* (the app's item, asked for before the window) */
  syncAppItem();
}

void cocoa_setMenuItem(const char *label, int checked) {
  @autoreleasepool {
    /* (Windows' "&" before the access key left out; "&&" is an "&") */
    NSString *text = label ? [NSString stringWithUTF8String:label] : nil;
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < text.length; i++) {
      unichar c = [text characterAtIndex:i];
      if (c == '&') {
        if (i + 1 < text.length && [text characterAtIndex:i + 1] == '&') {
          [s appendString:@"&"];
          i++;
        }
        continue;
      }
      [s appendFormat:@"%C", c];
    }
    appItemLabel = [s copy];
    appItemChecked = checked ? 1 : 0;
    syncAppItem();
  }
}

int cocoa_menuItemChosen(void) {
  int chosen = appItemChosen;
  appItemChosen = 0;
  return chosen;
}

void cocoa_createWindow(int w, int h, int *outW, int *outH,
                        int *outScaleX, int *outScaleY) {
  @autoreleasepool {
    /* Initialize timing */
    mach_timebase_info(&timebaseInfo);
    startTime = mach_absolute_time();

    /* Set up NSApplication */
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    /* The delegate is created up front: the Quit menu item below targets it. */
    winDelegate = [[NimEditWindowDelegate alloc] init];

    makeMenuBar();

    /* Create window. A negative dimension is MaxWindowWidth/MaxWindowHeight:
       take the screen's visibleFrame, which is the screen minus the menu bar
       and the Dock -- every bit of space a window is allowed to have. This is
       not fullscreen: the window keeps its title bar, the menu bar stays
       visible and the window stays out of a Space of its own. A window that
       maxes out in one direction is placed at that edge of the visible area
       and keeps its requested size in the other. */
    NSUInteger style = styleFor(systemFrame);
    /* initWithContentRect: wants the CONTENT rect, so the visible frame has
       to have the title bar taken off it -- handing it over as-is would make
       the window taller than the space it is supposed to fit in. */
    NSRect visible = [[NSScreen mainScreen] visibleFrame];
    NSRect maxContent = [NSWindow contentRectForFrameRect:visible styleMask:style];
    NSRect rect = NSMakeRect(100, 100, w, h);
    /* (where the last run left it, $RETRO_WINDOW_STATE: see notePlace) */
    if (w >= 0 && h >= 0) {
      askedW = w;
      askedH = h;
      keptPlace(resizable != 0, &rect);
    }
    if (w < 0) {
      rect.size.width = maxContent.size.width;
      rect.origin.x = maxContent.origin.x;
    }
    if (h < 0) {
      rect.size.height = maxContent.size.height;
      rect.origin.y = maxContent.origin.y;
    }
    mainWindow = [[NimEditWindow alloc] initWithContentRect:rect
                                             styleMask:style
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    /* (the app's name until the app gives the window its title) */
    [mainWindow setTitle:appName()];
    [mainWindow setAcceptsMouseMovedEvents:YES];

    /* Create view */
    mainView = [[NimEditView alloc] initWithFrame:rect];
    [mainWindow setContentView:mainView];
    [mainWindow makeFirstResponder:mainView];
    /* Files dragged from the Finder are taken (NE_FILE_DROP) */
    [mainView registerForDraggedTypes:@[NSPasteboardTypeFileURL]];

    /* Window delegate (already allocated above for the Quit menu item) */
    [mainWindow setDelegate:winDelegate];

    /* A tablet tells which end of its pen came near in proximity events of
       their own, which no view method is sure to see: watch them here. */
    static id penProximityMonitor = nil;
    if (!penProximityMonitor) {
      penProximityMonitor =
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskTabletProximity
                                              handler:^NSEvent *(NSEvent *ev) {
          notePenProximity(ev);
          return ev;
        }];
    }

    /* Show */
    [mainWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    /* Finish launch so events flow */
    [NSApp finishLaunching];

    /* Set up backing bitmap */
    CGFloat scale = [mainWindow backingScaleFactor];
    NSRect contentFrame = [mainView frame];
    ensureBacking((int)contentFrame.size.width, (int)contentFrame.size.height, scale);

    *outW = (int)contentFrame.size.width;
    *outH = (int)contentFrame.size.height;
    *outScaleX = (int)scale;
    *outScaleY = (int)scale;
  }
}

/* backingScaleFactor is a whole number of pixels per point on every Mac
   (1 or 2), so an int loses nothing here. */
void cocoa_getWindowLayout(int *outW, int *outH, int *outScaleX, int *outScaleY) {
  @autoreleasepool {
    if (!mainWindow || !mainView) {
      *outW = 0;
      *outH = 0;
      *outScaleX = 1;
      *outScaleY = 1;
      return;
    }
    NSRect contentFrame = [mainView frame];
    CGFloat scale = [mainWindow backingScaleFactor];
    *outW = (int)contentFrame.size.width;
    *outH = (int)contentFrame.size.height;
    *outScaleX = (int)scale;
    *outScaleY = (int)scale;
  }
}

void cocoa_refresh(void) {
  @autoreleasepool {
    if (dirtyAll || CGRectIsEmpty(dirtyPts)) [mainView setNeedsDisplay:YES];
    else [mainView setNeedsDisplayInRect:NSRectFromCGRect(dirtyPts)];
    dirtyPts = CGRectNull;
    dirtyAll = 0;
    [mainView displayIfNeeded];
  }
}

void cocoa_setWindowTitle(const char *title) {
  @autoreleasepool {
    NSString *t = [NSString stringWithUTF8String:title];
    if (t) [mainWindow setTitle:t];
  }
}

/* The paths of the oldest drop of files not read yet (cocoa_dropDone then
   goes on to the next): their number, and each in UTF-8. */
int cocoa_dropCount(void) {
  return [drops count] > 0 ? (int)[[drops objectAtIndex:0] count] : 0;
}

const char *cocoa_dropPath(int i) {
  static char path[4096];
  @autoreleasepool {
    path[0] = 0;
    NSArray *paths = [drops count] > 0 ? [drops objectAtIndex:0] : nil;
    if (i >= 0 && i < (int)[paths count]) {
      const char *p = [[paths objectAtIndex:i] UTF8String];
      if (p) strlcpy(path, p, sizeof path);
    }
  }
  return path;
}

void cocoa_dropDone(void) {
  if ([drops count] > 0) [drops removeObjectAtIndex:0];
}

/* Where the caret of the text being typed is (the view's points): an input
   method's candidates go there. */
void cocoa_setTextCaret(int x, int y, int w, int h) {
  @autoreleasepool {
    NSRect r = NSMakeRect(x, y, w > 0 ? w : 1, h > 0 ? h : 1);
    if (NSEqualRects(r, textCaret)) return;
    textCaret = r;
    [[mainView inputContext] invalidateCharacterCoordinates];
  }
}

/* ---- The window's frame ------------------------------------------------ */
/* The app's own title bar moves the window with the press it got
   (performWindowDragWithEvent:); its border sizes it here, the window
   following the mouse until the button is let go, and a control menu's Move
   and Size go by the arrow keys here. Maximized, a borderless window fills
   the screen without the menu bar and the Dock. */

static void noteContentSize(void) {
  /* (the content's new size: the backing and the app follow it) */
  NSRect frame = [[mainWindow contentView] frame];
  CGFloat scale = [mainWindow backingScaleFactor];
  ensureBacking((int)frame.size.width, (int)frame.size.height, scale);
  [[mainWindow contentView] setNeedsDisplay:YES];
  NEEvent e = {0};
  e.kind = NE_WINDOW_RESIZE;
  e.x = (int)frame.size.width;
  e.y = (int)frame.size.height;
  pushEvent(e);
}

int cocoa_setSystemFrame(int on) {
  @autoreleasepool {
    systemFrame = on ? 1 : 0;
    if (mainWindow) {
      NSRect frame = [mainWindow frame];
      [mainWindow setStyleMask:styleFor(systemFrame)];
      [mainWindow setFrame:frame display:YES];
      [mainWindow makeFirstResponder:mainView];
      noteContentSize();
    }
    return 1;
  }
}

int cocoa_setResizable(int on) {
  /* (no sizing edges, the zoom button grayed: the window keeps its size) */
  @autoreleasepool {
    resizable = on ? 1 : 0;
    if (mainWindow) {
      NSRect frame = [mainWindow frame];
      [mainWindow setStyleMask:styleFor(systemFrame)];
      [mainWindow setFrame:frame display:YES];
      [[mainWindow standardWindowButton:NSWindowZoomButton] setEnabled:resizable ? YES : NO];
      [mainWindow makeFirstResponder:mainView];
    }
    return 1;
  }
}

static void releaseLeft(void) {
  /* (the system took the button's release: it is reported here) */
  NSPoint p = [mainWindow mouseLocationOutsideOfEventStream];
  NSPoint v = [mainView convertPoint:p fromView:nil];
  NEEvent e = {0};
  e.kind = NE_MOUSE_UP;
  e.button = NE_MB_LEFT;
  e.x = (int)v.x;
  e.y = (int)v.y;
  pushEvent(e);
}

/* `part`: 1 the title bar, 2..5 left, right, top, bottom, 6..9 top left,
   top right, bottom left, bottom right (uirelays' WindowPart). */
static NSRect placedFrame(NSRect start, int part, CGFloat dx, CGFloat dy) {
  /* (the window moved -- the title bar -- or the part's edges, by dx, dy in
     the screen's points, whose y goes up) */
  if (part == 1) return NSOffsetRect(start, dx, dy);
  int left = part == 2 || part == 6 || part == 8;
  int right = part == 3 || part == 7 || part == 9;
  int top = part == 4 || part == 6 || part == 7;
  int bottom = part == 5 || part == 8 || part == 9;
  NSSize least = [mainWindow minSize];
  CGFloat minW = MAX(least.width, 100), minH = MAX(least.height, 60);
  NSRect f = start;
  if (right) f.size.width = MAX(minW, start.size.width + dx);
  if (left) {
    f.size.width = MAX(minW, start.size.width - dx);
    f.origin.x = start.origin.x + start.size.width - f.size.width;
  }
  if (top) f.size.height = MAX(minH, start.size.height + dy);
  if (bottom) {
    f.size.height = MAX(minH, start.size.height - dy);
    f.origin.y = start.origin.y + start.size.height - f.size.height;
  }
  return f;
}

static int keyMoveSize(int part) {
  /* A control menu's Move or Size, as Windows does them: the arrow keys
     move the window (or the part's edges) 10 points a press; Return, Enter
     or a click keep it there, Esc puts it back. */
  NSRect start = [mainWindow frame];
  CGFloat dx = 0, dy = 0;
  for (;;) {
    NSEvent *ev = [NSApp nextEventMatchingMask:(NSEventMaskKeyDown |
                                                NSEventMaskLeftMouseDown |
                                                NSEventMaskRightMouseDown)
                                     untilDate:[NSDate distantFuture]
                                        inMode:NSEventTrackingRunLoopMode
                                       dequeue:YES];
    if (!ev || ev.type != NSEventTypeKeyDown) break;            /* a click */
    unsigned short kc = ev.keyCode;
    if (kc == 0x35) {                                           /* Esc */
      [mainWindow setFrame:start display:YES];
      break;
    }
    if (kc == 0x24 || kc == 0x4C) break;                        /* Return, Enter */
    if (kc == 0x7B) dx -= 10;                                   /* the arrows */
    else if (kc == 0x7C) dx += 10;
    else if (kc == 0x7E) dy += 10;
    else if (kc == 0x7D) dy -= 10;
    else continue;
    [mainWindow setFrame:placedFrame(start, part, dx, dy) display:YES];
  }
  return 1;
}

int cocoa_dragWindow(int part, int keyboard) {
  @autoreleasepool {
    if (!mainWindow || part < 1 || part > 9) return 0;
    if (keyboard) return keyMoveSize(part);
    if (([NSEvent pressedMouseButtons] & 1) == 0) return 0;   /* let go already */
    if (part == 1) {
      if (!lastMouseDown ||
          ![mainWindow respondsToSelector:@selector(performWindowDragWithEvent:)])
        return 0;
      [mainWindow performWindowDragWithEvent:lastMouseDown];
      releaseLeft();
      return 1;
    }
    NSRect start = [mainWindow frame];
    NSPoint p0 = [NSEvent mouseLocation];
    for (;;) {
      NSEvent *ev = [NSApp nextEventMatchingMask:(NSEventMaskLeftMouseDragged |
                                                  NSEventMaskLeftMouseUp)
                                       untilDate:[NSDate distantFuture]
                                          inMode:NSEventTrackingRunLoopMode
                                         dequeue:YES];
      if (!ev || ev.type == NSEventTypeLeftMouseUp) break;
      NSPoint p = [NSEvent mouseLocation];
      [mainWindow setFrame:placedFrame(start, part, p.x - p0.x, p.y - p0.y) display:YES];
    }
    releaseLeft();
    return 1;
  }
}

/* ---- Files dragged out of the window ---------------------------------- */
/* The system's dragging session with the files' URLs (what Finder, Mail and
   browsers take), begun from the left button's last drag; the events run
   here until it ends, so the call returns then, as on the other systems.
   The window takes no drop of its own files (nothing within the app). A
   session cannot be ended from here, so one that comes back over the window
   goes on to its end there. */

@interface NimFileDragSource : NSObject <NSDraggingSource>
@property (nonatomic) BOOL ended;
@property (nonatomic) BOOL allowMove;
@property (nonatomic) NSDragOperation operation;
@end

@implementation NimFileDragSource
- (NSDragOperation)draggingSession:(NSDraggingSession *)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
  if (context == NSDraggingContextWithinApplication) return NSDragOperationNone;
  return self.allowMove ? (NSDragOperationCopy | NSDragOperationMove)
                        : NSDragOperationCopy;
}
- (void)draggingSession:(NSDraggingSession *)session
           endedAtPoint:(NSPoint)screenPoint
              operation:(NSDragOperation)operation {
  self.operation = operation;
  self.ended = YES;
}
@end

static void dropInputSince(int from) {
  /* (keys and clicks that came during the drag were the drag's) */
  int w = from;
  for (int r = from; r != eqHead; r = (r + 1) % EVENT_QUEUE_SIZE) {
    int k = eventQueue[r].kind;
    if (k >= NE_KEY_DOWN && k <= NE_MOUSE_WHEEL) continue;
    eventQueue[w] = eventQueue[r];
    w = (w + 1) % EVENT_QUEUE_SIZE;
  }
  eqHead = w;
}

/* 0: no drag; 1: cancelled; 2: copied; 3: moved */
int cocoa_dragFilesOut(const char **paths, int n, int move) {
  @autoreleasepool {
    if (!mainWindow || !mainView || n <= 0) return 0;
    if (([NSEvent pressedMouseButtons] & 1) == 0) return 0;   /* let go already */
    NSEvent *from = lastMouseDragged ? lastMouseDragged : lastMouseDown;
    if (!from || [from window] != mainWindow) return 0;
    NSPoint at = [mainView convertPoint:[from locationInWindow] fromView:nil];
    NSMutableArray *items = [NSMutableArray array];
    for (int i = 0; i < n; i++) {
      NSString *path = [NSString stringWithUTF8String:paths[i]];
      if (!path) continue;
      NSURL *url = [NSURL fileURLWithPath:path];
      NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:url];
      NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:path];
      [item setDraggingFrame:NSMakeRect(at.x - 16 + 6 * i, at.y - 16 + 6 * i, 32, 32)
                    contents:icon];
      [items addObject:item];
    }
    if ([items count] == 0) return 0;
    NimFileDragSource *source = [[NimFileDragSource alloc] init];
    source.allowMove = move != 0;
    int head0 = eqHead;
    NSDraggingSession *session =
      [mainView beginDraggingSessionWithItems:items event:from source:source];
    if (!session) return 0;
    session.animatesToStartingPositionsOnCancelOrFail = YES;
    while (!source.ended) {
      @autoreleasepool {
        NSEvent *ev = [NSApp nextEventMatchingMask:NSEventMaskAny
                                         untilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]
                                            inMode:NSDefaultRunLoopMode
                                           dequeue:YES];
        if (ev) [NSApp sendEvent:ev];
      }
    }
    dropInputSince(head0);
    lastMouseDragged = nil;
    releaseLeft();
    NSDragOperation op = source.operation;
    if (op & NSDragOperationMove) return 3;
    if (op & (NSDragOperationCopy | NSDragOperationGeneric | NSDragOperationLink)) return 2;
    return 1;
  }
}

static int fillsScreen(void) {
  NSScreen *s = [mainWindow screen];
  if (!s) s = [NSScreen mainScreen];
  return NSEqualRects([mainWindow frame], [s visibleFrame]) ? 1 : 0;
}

void cocoa_setMaximized(int on) {
  @autoreleasepool {
    if (!mainWindow) return;
    if (systemFrame) {
      if ((on != 0) != ([mainWindow isZoomed] != NO)) [mainWindow zoom:nil];
      return;
    }
    NSScreen *s = [mainWindow screen];
    if (!s) s = [NSScreen mainScreen];
    if (on && !fillsScreen()) {
      unzoomedFrame = [mainWindow frame];
      [mainWindow setFrame:[s visibleFrame] display:YES];
    } else if (!on && fillsScreen()) {
      /* (back where it was; never anywhere else -- it opened maximized, or
         was maximized with the system's frame: three quarters of the
         screen, in the middle) */
      NSRect v = [s visibleFrame];
      NSRect back = NSIsEmptyRect(unzoomedFrame)
        ? NSInsetRect(v, v.size.width / 8, v.size.height / 8) : unzoomedFrame;
      [mainWindow setFrame:back display:YES];
    }
  }
}

int cocoa_isMaximized(void) {
  @autoreleasepool {
    if (!mainWindow) return 0;
    if (systemFrame) return [mainWindow isZoomed] ? 1 : 0;
    return fillsScreen();
  }
}

int cocoa_isActive(void) {
  return (mainWindow && [mainWindow isKeyWindow]) ? 1 : 0;
}

int cocoa_minimize(void) {
  @autoreleasepool {
    if (!mainWindow) return 0;
    [mainWindow miniaturize:nil];
    return 1;
  }
}

static NSCursor *systemCursor(NSString *name, NSCursor *instead) {
  /* One of AppKit's own pointers that it does not make public (what Safari
     shows for these), when this macOS has it; else `instead`. */
  SEL sel = NSSelectorFromString(name);
  if ([NSCursor respondsToSelector:sel]) {
    NSCursor *(*get)(id, SEL) = (NSCursor *(*)(id, SEL))[NSCursor methodForSelector:sel];
    NSCursor *c = get ? get([NSCursor class], sel) : nil;
    if ([c isKindOfClass:[NSCursor class]]) return c;
  }
  return instead;
}

void cocoa_setCursor(int kind) {
  @autoreleasepool {
    NSCursor *cur;
    switch (kind) {
      case 2:  cur = [NSCursor IBeamCursor]; break;       /* curIbeam */
      case 3:  cur = systemCursor(@"busyButClickableCursor",
                                  systemCursor(@"_waitCursor", [NSCursor arrowCursor]));
               break;                                      /* curWait */
      case 4:  cur = [NSCursor crosshairCursor]; break;    /* curCrosshair */
      case 5:  cur = [NSCursor pointingHandCursor]; break; /* curHand */
      case 6:  cur = [NSCursor resizeUpDownCursor]; break; /* curSizeNS */
      case 7:  cur = [NSCursor resizeLeftRightCursor]; break; /* curSizeWE */
      case 8:  cur = systemCursor(@"_windowResizeNorthWestSouthEastCursor",
                                  [NSCursor crosshairCursor]);
               break;                                      /* curSizeNWSE */
      case 9:  cur = systemCursor(@"_windowResizeNorthEastSouthWestCursor",
                                  [NSCursor crosshairCursor]);
               break;                                      /* curSizeNESW */
      case 10: cur = systemCursor(@"_moveCursor", [NSCursor openHandCursor]);
               break;                                      /* curMove */
      default: cur = [NSCursor arrowCursor]; break;
    }
    [cur set];
  }
}

void cocoa_startTextInput(void) {
  /* NSTextInputClient is always active on our view */
}

void cocoa_shutdown(void) {
  NEEvent e = {0};
  e.kind = NE_QUIT;
  pushEvent(e);
}

/* ---- screen readers: NSAccessibility (VoiceOver) ----------------------
   The program's tree (cocoa_accessUpdate) becomes accessibility elements,
   one a node, kept by id from frame to frame; the view is their container.
   What VoiceOver asks (press, a value, the focus) goes to the program
   (cocoa_accessRequest, in Nim) and wakes its loop. */

typedef struct {
  unsigned int nodeId;
  int parent, role;
  unsigned int states;
  int x, y, w, h;
  double lo, hi, now, step;
  int caret, selA, selB, pos, count, level;
  const char *name, *value, *help, *key;
} NEAccessNode;

/* (the program's: what a screen reader asked; that one listens) */
extern void cocoa_accessRequest(int action, unsigned int nodeId, const char *text, double num);
extern void cocoa_accessListen(void);

enum { AX_FOCUSABLE = 1 << 0, AX_FOCUSED = 1 << 1, AX_DISABLED = 1 << 2, AX_CHECKED = 1 << 3,
       AX_MIXED = 1 << 4, AX_SELECTED = 1 << 5, AX_EXPANDABLE = 1 << 6, AX_EXPANDED = 1 << 7,
       AX_READONLY = 1 << 8, AX_DEFAULT = 1 << 9, AX_PRESSED = 1 << 10, AX_MULTILINE = 1 << 11,
       AX_PROTECTED = 1 << 12, AX_MODAL = 1 << 13 };
enum { AXR_WINDOW, AXR_PANE, AXR_GROUP, AXR_LABEL, AXR_BUTTON, AXR_TOGGLE, AXR_CHECK, AXR_RADIO,
       AXR_FIELD, AXR_AREA, AXR_PASSWORD, AXR_COMBO, AXR_LIST, AXR_LISTITEM, AXR_SLIDER, AXR_SPIN,
       AXR_PROGRESS, AXR_SCROLLBAR, AXR_MENUBAR, AXR_MENU, AXR_MENUITEM, AXR_TOOLBAR, AXR_STATUS,
       AXR_TABLIST, AXR_TAB, AXR_TREE, AXR_TREEITEM, AXR_TABLE, AXR_ROW, AXR_CELL, AXR_COLHEADER,
       AXR_DIALOG, AXR_LINK, AXR_IMAGE, AXR_HEADING, AXR_SEPARATOR, AXR_TOOLTIP, AXR_ALERT };
enum { AXA_PRESS, AXA_FOCUS, AXA_SETVALUE, AXA_INCREMENT, AXA_DECREMENT };

static void axWake(void) {
  /* (the program's loop, maybe waiting for an event, goes on) */
  NEEvent e = {0};
  e.kind = NE_NONE;
  pushEvent(e);
  NSEvent *ev = [NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
                              modifierFlags:0 timestamp:0 windowNumber:0 context:nil
                                    subtype:0 data1:0 data2:0];
  [NSApp postEvent:ev atStart:NO];
}

@interface RetroAXElement : NSAccessibilityElement
@property unsigned int nodeId;
@property int axRole;
@property unsigned int axStates;
@property (copy) NSString *axName, *axValue, *axHelp;
@property double lo, hi, now, step;
@property NSRect local;
@property (strong) NSMutableArray *kids;
@end

static NSMutableDictionary *axById = nil;   /* NSNumber (id) -> RetroAXElement */
static NSMutableArray *axTop = nil;          /* the window's children */
static RetroAXElement *axFocus = nil;
static BOOL axListening = NO;

static NSString *axString(const char *s) {
  NSString *t = s ? [NSString stringWithUTF8String:s] : nil;
  return t ? t : @"";
}

@implementation RetroAXElement
- (NSRect)accessibilityFrame {
  if (!mainView || !mainWindow) return NSZeroRect;
  NSRect inWindow = [mainView convertRect:self.local toView:nil];
  return [mainWindow convertRectToScreen:inWindow];
}
- (NSAccessibilityRole)accessibilityRole {
  switch (self.axRole) {
    case AXR_BUTTON: return NSAccessibilityButtonRole;
    case AXR_TOGGLE: return NSAccessibilityCheckBoxRole;
    case AXR_CHECK: return NSAccessibilityCheckBoxRole;
    case AXR_RADIO: case AXR_TAB: return NSAccessibilityRadioButtonRole;
    case AXR_FIELD: case AXR_PASSWORD: return NSAccessibilityTextFieldRole;
    case AXR_AREA: return NSAccessibilityTextAreaRole;
    case AXR_COMBO: return NSAccessibilityPopUpButtonRole;
    case AXR_LIST: return NSAccessibilityListRole;
    case AXR_LISTITEM: case AXR_LABEL: case AXR_HEADING: case AXR_STATUS: return NSAccessibilityStaticTextRole;
    case AXR_SLIDER: return NSAccessibilitySliderRole;
    case AXR_SPIN: return NSAccessibilityIncrementorRole;
    case AXR_PROGRESS: return NSAccessibilityProgressIndicatorRole;
    case AXR_SCROLLBAR: return NSAccessibilityScrollBarRole;
    case AXR_MENUBAR: return NSAccessibilityMenuBarRole;
    case AXR_MENU: return NSAccessibilityMenuRole;
    case AXR_MENUITEM: return NSAccessibilityMenuItemRole;
    case AXR_TOOLBAR: return NSAccessibilityToolbarRole;
    case AXR_TABLIST: return NSAccessibilityTabGroupRole;
    case AXR_TREE: return NSAccessibilityOutlineRole;
    case AXR_TREEITEM: case AXR_ROW: return NSAccessibilityRowRole;
    case AXR_TABLE: return NSAccessibilityTableRole;
    case AXR_CELL: return NSAccessibilityCellRole;
    case AXR_COLHEADER: return NSAccessibilityButtonRole;
    case AXR_LINK: return NSAccessibilityLinkRole;
    case AXR_IMAGE: return NSAccessibilityImageRole;
    case AXR_SEPARATOR: return NSAccessibilitySplitterRole;
    default: return NSAccessibilityGroupRole;
  }
}
- (NSAccessibilitySubrole)accessibilitySubrole {
  if (self.axRole == AXR_PASSWORD) return NSAccessibilitySecureTextFieldSubrole;
  if (self.axRole == AXR_TOGGLE) return NSAccessibilityToggleSubrole;
  if (self.axRole == AXR_TAB) return NSAccessibilityTabButtonSubrole;
  if (self.axRole == AXR_DIALOG) return NSAccessibilityDialogSubrole;
  return nil;
}
- (NSString *)accessibilityLabel { return self.axName; }
- (NSString *)accessibilityTitle {
  /* (a button's, a check box's, a menu item's title is its name) */
  switch (self.axRole) {
    case AXR_BUTTON: case AXR_TOGGLE: case AXR_CHECK: case AXR_RADIO: case AXR_TAB:
    case AXR_MENUITEM: case AXR_MENU: case AXR_LINK: return self.axName;
    default: return nil;
  }
}
- (NSString *)accessibilityHelp { return self.axHelp.length > 0 ? self.axHelp : nil; }
- (id)accessibilityValue {
  switch (self.axRole) {
    case AXR_FIELD: case AXR_AREA: case AXR_COMBO: return self.axValue;
    case AXR_PASSWORD: return @"";
    case AXR_LABEL: case AXR_HEADING: case AXR_STATUS: case AXR_LISTITEM: return self.axName;
    case AXR_CHECK: case AXR_TOGGLE: case AXR_RADIO: case AXR_TAB:
      return @((self.axStates & (AX_CHECKED | AX_PRESSED | AX_SELECTED)) ? 1 : 0);
    case AXR_SLIDER: case AXR_SPIN: case AXR_PROGRESS: case AXR_SCROLLBAR: return @(self.now);
    default: return nil;
  }
}
- (id)accessibilityMinValue { return @(self.lo); }
- (id)accessibilityMaxValue { return @(self.hi); }
- (BOOL)isAccessibilityElement { return self.axRole != AXR_PANE; }
- (BOOL)isAccessibilityEnabled { return (self.axStates & AX_DISABLED) == 0; }
- (BOOL)isAccessibilityFocused { return (self.axStates & AX_FOCUSED) != 0; }
- (BOOL)isAccessibilitySelected { return (self.axStates & AX_SELECTED) != 0; }
- (BOOL)isAccessibilityExpanded { return (self.axStates & AX_EXPANDED) != 0; }
- (NSArray *)accessibilityChildren { return self.kids; }
- (BOOL)accessibilityPerformPress {
  cocoa_accessRequest(AXA_PRESS, self.nodeId, NULL, 0);
  axWake();
  return YES;
}
- (BOOL)accessibilityPerformIncrement {
  cocoa_accessRequest(AXA_INCREMENT, self.nodeId, NULL, 0);
  axWake();
  return YES;
}
- (BOOL)accessibilityPerformDecrement {
  cocoa_accessRequest(AXA_DECREMENT, self.nodeId, NULL, 0);
  axWake();
  return YES;
}
- (BOOL)accessibilityPerformShowMenu { return NO; }
- (void)setAccessibilityValue:(id)value {
  if ([value isKindOfClass:[NSString class]]) {
    cocoa_accessRequest(AXA_SETVALUE, self.nodeId, [value UTF8String], [value doubleValue]);
  } else if ([value isKindOfClass:[NSNumber class]]) {
    cocoa_accessRequest(AXA_SETVALUE, self.nodeId, [[value stringValue] UTF8String], [value doubleValue]);
  } else return;
  axWake();
}
- (void)setAccessibilityFocused:(BOOL)focused {
  if (!focused) return;
  cocoa_accessRequest(AXA_FOCUS, self.nodeId, NULL, 0);
  axWake();
}
@end

@implementation NimEditView (RetroAccess)
- (BOOL)isAccessibilityElement { return NO; }
- (NSArray *)accessibilityChildren {
  if (!axListening) {
    /* (someone reads the window: the program builds its tree from now on) */
    axListening = YES;
    cocoa_accessListen();
    axWake();
  }
  return axTop ? axTop : @[];
}
- (id)accessibilityFocusedUIElement {
  if (!axListening) {
    axListening = YES;
    cocoa_accessListen();
    axWake();
  }
  return axFocus ? axFocus : self;
}
- (id)accessibilityHitTest:(NSPoint)point {
  RetroAXElement *hit = nil;
  for (RetroAXElement *e in [axById allValues]) {
    if (NSPointInRect(point, [e accessibilityFrame]) &&
        (!hit || e.local.size.width * e.local.size.height < hit.local.size.width * hit.local.size.height))
      hit = e;
  }
  return hit ? hit : self;
}
@end

void cocoa_accessUpdate(const NEAccessNode *nodes, int n, int focus) {
  @autoreleasepool {
    if (!axById) axById = [NSMutableDictionary new];
    NSMutableDictionary *next = [NSMutableDictionary dictionaryWithCapacity:n];
    NSMutableArray *els = [NSMutableArray arrayWithCapacity:n];
    BOOL structure = NO;
    RetroAXElement *oldFocus = axFocus;
    NSMutableArray *changedValue = [NSMutableArray new];
    NSMutableArray *changedTitle = [NSMutableArray new];
    for (int i = 0; i < n; i++) {
      const NEAccessNode *a = &nodes[i];
      NSNumber *key = @(a->nodeId);
      RetroAXElement *e = axById[key];
      if (!e) {
        e = [RetroAXElement new];
        structure = YES;
      } else {
        NSString *v = axString(a->value);
        if (![e.axValue isEqualToString:v] || e.now != a->now ||
            (e.axStates & (AX_CHECKED | AX_SELECTED | AX_EXPANDED)) !=
            (a->states & (AX_CHECKED | AX_SELECTED | AX_EXPANDED))) [changedValue addObject:e];
        if (![e.axName isEqualToString:axString(a->name)]) [changedTitle addObject:e];
      }
      e.nodeId = a->nodeId;
      e.axRole = a->role;
      e.axStates = a->states;
      e.axName = axString(a->name);
      e.axValue = axString(a->value);
      e.axHelp = axString(a->help);
      e.lo = a->lo;
      e.hi = a->hi;
      e.now = a->now;
      e.step = a->step;
      e.local = NSMakeRect(a->x, a->y, a->w, a->h);
      e.kids = [NSMutableArray new];
      next[key] = e;
      [els addObject:e];
    }
    if (next.count != axById.count) structure = YES;
    NSMutableArray *top = [NSMutableArray new];
    for (int i = 1; i < n; i++) {
      int p = nodes[i].parent;
      RetroAXElement *e = els[i];
      if (p <= 0 || p >= n) {
        [top addObject:e];
        [e setAccessibilityParent:mainView];
      } else {
        RetroAXElement *pe = els[p];
        [pe.kids addObject:e];
        [e setAccessibilityParent:pe];
      }
    }
    axTop = top;
    axById = next;
    axFocus = (focus > 0 && focus < n) ? els[focus] : nil;
    if (structure && mainView) NSAccessibilityPostNotification(mainView, NSAccessibilityLayoutChangedNotification);
    for (RetroAXElement *e in changedTitle) NSAccessibilityPostNotification(e, NSAccessibilityTitleChangedNotification);
    for (RetroAXElement *e in changedValue) NSAccessibilityPostNotification(e, NSAccessibilityValueChangedNotification);
    if (axFocus && axFocus != oldFocus)
      NSAccessibilityPostNotification(axFocus, NSAccessibilityFocusedUIElementChangedNotification);
  }
}
