/* clang -fobjc-arc tests/cocoargbatest.m -o /tmp/uirelays-cocoargbatest
   -framework Cocoa -framework Carbon -framework CoreText -framework CoreGraphics -framework QuartzCore */
#include <assert.h>
#include "../src/uirelays/drivers/cocoa_backend.m"

int main(void) {
  @autoreleasepool {
    ensureBacking(2, 1, 2.0);
    uint32_t pixels[] = {
      0xff0000, 0x00ff00, 0x0000ff, 0xffffff,
      0x00ffff, 0xff00ff, 0xffff00, 0x000000
    };
    assert(cocoa_drawRGBA(pixels, 4, 2, 0, 0, 2, 1, 0));
    uint32_t *backing = CGBitmapContextGetData(backingCtx);
    /* Each independently colored source pixel survives on a 2x surface. */
    for (int i = 0; i < 8; ++i)
      assert((backing[i] & 0xffffff) == pixels[i]);

    /* Resizing keeps the old content at its original position and size. */
    ensureBacking(3, 2, 2.0);
    backing = CGBitmapContextGetData(backingCtx);
    assert(CGBitmapContextGetWidth(backingCtx) == 6);
    for (int y = 0; y < 2; ++y)
      for (int x = 0; x < 4; ++x)
        assert((backing[y*6+x] & 0xffffff) == pixels[y*4+x]);
    ensureBacking(2, 1, 2.0);
    backing = CGBitmapContextGetData(backingCtx);
    for (int i = 0; i < 8; ++i)
      assert((backing[i] & 0xffffff) == pixels[i]);

    uint32_t legacy[] = {0xff0000, 0x0000ff};
    assert(cocoa_blitRGBA(legacy, 2, 1, 0, 0, 2, 1, 0));
    backing = CGBitmapContextGetData(backingCtx);
    assert((backing[0] & 0xffffff) == 0xff0000);
    assert((backing[3] & 0xffffff) == 0x0000ff);

    /* Moving to a 1x monitor with the same point size reallocates the bitmap. */
    ensureBacking(2, 1, 1.0);
    assert(CGBitmapContextGetWidth(backingCtx) == 2);
    assert(CGBitmapContextGetHeight(backingCtx) == 1);
    /* Native source-over preserves transparent edges and premultiplied color. */
    cocoa_fillRect(0, 0, 2, 1, 0, 0, 255, 255);
    uint32_t alpha[] = {0x80800000, 0x00000000};
    assert(cocoa_drawRGBA(alpha, 2, 1, 0, 0, 2, 1, 1));
    backing = CGBitmapContextGetData(backingCtx);
    assert(backing[0] == 0xff80007f);
    assert(backing[1] == 0xff0000ff);
    assert(alpha[0] == 0x80800000 && alpha[1] == 0x00000000);
    cocoa_fillRect(0, 0, 2, 1, 0, 0, 255, 255);
    cocoa_fillRect(0, 0, 1, 1, 255, 0, 0, 128);
    assert(backing[0] == 0xff80007f && backing[1] == 0xff0000ff);
    cocoa_fillRect(0, 0, 1, 1, 0, 255, 0, 0);
    assert(backing[0] == 0xff80007f);

    /* A clipped blit keeps the original row stride, without scaling. */
    ensureBacking(2, 2, 1.0);
    cocoa_fillRect(0, 0, 2, 2, 0, 0, 255, 255);
    uint32_t rows[] = {0x80800000, 0xff00ff00, 0x80008000, 0xffffffff};
    assert(cocoa_blitRGBA(rows, 2, 2, 0, 0, 1, 2, 1));
    backing = CGBitmapContextGetData(backingCtx);
    assert(backing[0] == 0xff80007f && backing[1] == 0xff0000ff);
    assert(backing[2] == 0xff00807f && backing[3] == 0xff0000ff);

    /* Alpha and source resolution survive Retina destination scaling. */
    ensureBacking(2, 1, 2.0);
    cocoa_fillRect(0, 0, 2, 1, 0, 0, 255, 255);
    uint32_t retina[] = {0x80800000, 0x00000000, 0x80008000, 0xffffffff,
                         0x00000000, 0x80800000, 0xffffffff, 0x80008000};
    assert(cocoa_drawRGBA(retina, 4, 2, 0, 0, 2, 1, 1));
    backing = CGBitmapContextGetData(backingCtx);
    for (int i = 0; i < 8; ++i) {
      uint32_t inverse = 255 - (retina[i] >> 24);
      uint32_t expected = 0xff000000 | (retina[i] & 0xffffff) | inverse;
      assert(backing[i] == expected);
    }
    CGContextRelease(backingCtx);
    backingCtx = NULL;

    /* Siwin may replace its client buffer for every presentation. The native
       compositor owns independent pixels and can present into each new one. */
    assert(cocoa_prepareSiwinSurface(4, 2, 2.0));
    cocoa_fillRect(0, 0, 2, 1, 255, 0, 0, 255);
    uint32_t client[8] = {0};
    assert(cocoa_presentSiwinSurface(client, 4, 2));
    assert(client[0] == 0xff0000ff); /* RGBA bytes: red, opaque */
    memset(client, 0, sizeof(client));
    assert(cocoa_prepareSiwinSurface(4, 2, 2.0));
    assert(cocoa_presentSiwinSurface(client, 4, 2));
    for (int i = 0; i < 8; ++i) assert(client[i] == 0xff0000ff);
    assert(cocoa_prepareSiwinSurface(6, 4, 2.0));
    uint32_t larger[24] = {0};
    assert(cocoa_presentSiwinSurface(larger, 6, 4));
    assert(larger[0] == 0xff0000ff && larger[3] == 0xff0000ff);
    assert(larger[6] == 0xff0000ff && larger[9] == 0xff0000ff);
    cocoa_detachSurface();
    assert(!cocoa_presentSiwinSurface(client, 4, 2));
  }
  return 0;
}
