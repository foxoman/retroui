package org.uirelays;

import android.app.NativeActivity;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.view.KeyEvent;
import android.view.View;
import android.view.Window;
import android.view.WindowInsets;
import android.view.inputmethod.InputMethodManager;
import java.lang.reflect.Method;

/** An activity for the uirelays Android driver (android_glue.c): Android's
 *  NativeActivity plus what C cannot do there -- receive text that has no
 *  key code (Arabic, emoji, voice typing from the soft keyboard), show and
 *  hide the keyboard, learn the insets of the system bars and the keyboard,
 *  color the system bars, go to the background and ask for access to the
 *  shared storage.
 *
 *  Optional: with a plain android.app.NativeActivity the driver still runs.
 *  Copy it into your app (change the package as you like) and name it in
 *  the manifest instead of NativeActivity. The glue registers the native
 *  methods and calls the public ones; any it does not find are not used.
 *  An app can add `public byte[] uirelaysCall(String name, String arg)` for
 *  `systemCall` (UTF-8 text out, null when it failed), and
 *  `openFile(String, int)` and `decodeImage(String, int, int)` for the
 *  `systemRelays` of the same names. */
public class UiRelaysActivity extends NativeActivity {
  static native void nativeText(String text);
  static native void nativeInsets(int top, int left, int bottom, int right);

  @Override
  protected void onCreate(Bundle state) {
    super.onCreate(state);
    getWindow().getDecorView().setOnApplyWindowInsetsListener(
        new View.OnApplyWindowInsetsListener() {
          public WindowInsets onApplyWindowInsets(View v, WindowInsets in) {
            try {
              nativeInsets(in.getSystemWindowInsetTop(), in.getSystemWindowInsetLeft(),
                           in.getSystemWindowInsetBottom(), in.getSystemWindowInsetRight());
            } catch (UnsatisfiedLinkError e) {
              // a libmain.so without the glue: the content rect is used
            }
            return v.onApplyWindowInsets(in);
          }
        });
  }

  @Override
  public boolean dispatchKeyEvent(KeyEvent e) {
    // The native side passes on what it cannot read: text without key codes.
    if (e.getAction() == KeyEvent.ACTION_MULTIPLE
        && e.getKeyCode() == KeyEvent.KEYCODE_UNKNOWN) {
      String s = e.getCharacters();
      if (s != null) {
        try {
          nativeText(s);
          return true;
        } catch (UnsatisfiedLinkError err) {
          // fall through
        }
      }
    }
    return super.dispatchKeyEvent(e);
  }

  /** Show or hide the soft keyboard; called by native code on its thread. */
  public void keyboard(final boolean show) {
    runOnUiThread(new Runnable() {
      public void run() {
        InputMethodManager imm =
            (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
        if (imm == null) return;
        View v = getWindow().getDecorView();
        if (show) imm.showSoftInput(v, 0);
        else imm.hideSoftInputFromWindow(v.getWindowToken(), 0);
      }
    });
  }

  /** The colors the app draws under the status and navigation bars (RGB):
   *  their icons turn dark or light to stay visible. */
  public void systemBars(final int top, final int bottom) {
    runOnUiThread(new Runnable() {
      public void run() {
        Window w = getWindow();
        View d = w.getDecorView();
        boolean lightTop = luma(top) > 150;
        boolean lightBottom = luma(bottom) > 150;
        int f = d.getSystemUiVisibility();
        f = lightTop ? (f | 0x2000) : (f & ~0x2000);          // LIGHT_STATUS_BAR
        if (Build.VERSION.SDK_INT >= 26)
          f = lightBottom ? (f | 0x10) : (f & ~0x10);         // LIGHT_NAVIGATION_BAR
        d.setSystemUiVisibility(f);
        if (Build.VERSION.SDK_INT >= 30) {
          try {                                               // WindowInsetsController
            Object c = View.class.getMethod("getWindowInsetsController").invoke(d);
            Method m = c.getClass().getMethod("setSystemBarsAppearance", int.class, int.class);
            m.invoke(c, (lightTop ? 8 : 0) | (lightBottom ? 16 : 0), 8 | 16);
          } catch (Throwable t) {
            // the legacy flags above do it
          }
        }
        if (Build.VERSION.SDK_INT < 35) {
          w.clearFlags(0x04000000 | 0x08000000);              // TRANSLUCENT_*
          w.addFlags(0x80000000);                             // DRAWS_SYSTEM_BAR_BACKGROUNDS
          w.setStatusBarColor(top | 0xFF000000);
          w.setNavigationBarColor(bottom | 0xFF000000);
        }
      }
    });
  }

  private static int luma(int c) {
    return (((c >> 16) & 255) * 3 + ((c >> 8) & 255) * 6 + (c & 255)) / 10;
  }

  /** Send the app to the background. */
  public void minimize() {
    runOnUiThread(new Runnable() {
      public void run() { moveTaskToBack(true); }
    });
  }

  /** May the app read and write the shared storage (all files)? */
  public boolean hasStorage() {
    if (Build.VERSION.SDK_INT >= 30) {
      try {
        return (Boolean) Environment.class.getMethod("isExternalStorageManager").invoke(null);
      } catch (Throwable t) {
        return false;
      }
    }
    if (Build.VERSION.SDK_INT >= 23)
      return checkSelfPermission("android.permission.WRITE_EXTERNAL_STORAGE") == 0;
    return true;
  }

  /** Ask for that: the "All files access" settings page, or the
   *  permission dialog before Android 11. */
  public void askStorage() {
    runOnUiThread(new Runnable() {
      public void run() {
        if (Build.VERSION.SDK_INT >= 30) {
          try {
            startActivity(new Intent("android.settings.MANAGE_APP_ALL_FILES_ACCESS_PERMISSION",
                                     Uri.parse("package:" + getPackageName())));
          } catch (Throwable t) {
            try {
              startActivity(new Intent("android.settings.MANAGE_ALL_FILES_ACCESS_PERMISSION"));
            } catch (Throwable t2) {
              // no such page on this device
            }
          }
        } else if (Build.VERSION.SDK_INT >= 23) {
          requestPermissions(new String[] {"android.permission.READ_EXTERNAL_STORAGE",
                                           "android.permission.WRITE_EXTERNAL_STORAGE"}, 1);
        }
      }
    });
  }
}
