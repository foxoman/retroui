package org.retro;

import android.app.NativeActivity;
import android.content.ClipData;
import android.content.ContentResolver;
import android.content.UriPermission;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Matrix;
import android.media.ExifInterface;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.view.KeyEvent;
import android.view.SurfaceView;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowInsets;
import android.view.inputmethod.InputMethodManager;
import android.webkit.MimeTypeMap;
import java.lang.reflect.Method;

/** The activity of a retro app: Android's NativeActivity plus what C
 *  cannot do there -- receive text that has no key code (Arabic, emoji,
 *  voice typing from the soft keyboard), show and hide the keyboard, learn
 *  the insets of the system bars and the keyboard, color the system bars,
 *  minimize, ask for access to all files, open and share files (through
 *  RetroFiles) and decode photos. The native methods are registered by
 *  android_glue.c; android_glue.c calls the public ones. */
public class RetroActivity extends NativeActivity {
  static native void nativeText(String text);
  static native void nativeInsets(int top, int left, int bottom, int right);
  /** What a screen reader asked of node `id` (RetroAccess); -1 one came, -2 it went. */
  static native void nativeAccess(int action, int id, String text, double num);
  /** What the keyboard composes now (RetroInput): the app shows it in its text box. */
  static native void nativeCompose(String text, int caret);
  /** A key of the keyboard's (delete, Enter) as a key: `down` pressed, else let go. */
  static native void nativeKey(int code, boolean down);
  /** Where the app's picture is in its window (a free window's title bar over it). */
  static native void nativeSurfaceAt(int x, int y);

  /** Where the app's picture is in the window: touches, the views laid over it (a web page, a
   *  video) and a screen reader's boxes are moved by it. 0, 0 filling the screen. */
  static volatile int surfaceX, surfaceY;

  @Override
  protected void onCreate(Bundle state) {
    // (before anything else -- the native library is loaded next: a crash
    // of the Java side written to the app's fault log, which the next start
    // shows; then the system's own report, as before)
    final java.io.File faults = new java.io.File(getFilesDir(), "faults.log");
    final Thread.UncaughtExceptionHandler before = Thread.getDefaultUncaughtExceptionHandler();
    Thread.setDefaultUncaughtExceptionHandler(new Thread.UncaughtExceptionHandler() {
      public void uncaughtException(Thread t, Throwable e) {
        try {
          java.io.StringWriter w = new java.io.StringWriter();
          e.printStackTrace(new java.io.PrintWriter(w));
          java.io.FileOutputStream o = new java.io.FileOutputStream(faults, true);
          o.write(("--- the app stopped\nJava, on the thread " + t.getName() + " (Android " +
                   Build.VERSION.RELEASE + ", " + Build.MANUFACTURER + " " + Build.MODEL + "):\n" +
                   w.toString()).getBytes("UTF-8"));
          o.close();
        } catch (Throwable ignored) { }
        if (before != null) before.uncaughtException(t, e);
      }
    });
    // (the RETRO_ settings given to the app's start, as a program on a
    // desktop gets them from its environment -- before the native library
    // reads them: adb shell am start -n PACKAGE/ACTIVITY --es RETRO_DRIVE 7000)
    try {
      Bundle extras = getIntent() != null ? getIntent().getExtras() : null;
      if (extras != null) {
        for (String k : extras.keySet()) {
          Object v = extras.get(k);
          if (k.startsWith("RETRO_") && v != null) android.system.Os.setenv(k, v.toString(), true);
        }
      }
    } catch (Throwable ignored) { }
    super.onCreate(state);
    pictureInView();
    takeShared(getIntent());
    takeAction(getIntent());
    RetroDevice.takeLink(getIntent());
    getWindow().getDecorView().setOnApplyWindowInsetsListener(
        new View.OnApplyWindowInsetsListener() {
          public WindowInsets onApplyWindowInsets(View v, WindowInsets in) {
            windowInsets[0] = in.getSystemWindowInsetTop();
            windowInsets[1] = in.getSystemWindowInsetLeft();
            windowInsets[2] = in.getSystemWindowInsetBottom();
            windowInsets[3] = in.getSystemWindowInsetRight();
            sendInsets();
            return v.onApplyWindowInsets(in);
          }
        });
  }

  /** The app's picture in a surface view in the window's own views, not the window's surface
   *  taken whole: the window's views are drawn too -- in a free or floating window (desktop
   *  windowing, a tablet's small window) the system's frame round it, its title bar and the
   *  edges it is sized by, as other apps have. Filling the screen it is as before: the picture
   *  under the status and navigation bars, the app told where they are. RETRO_WINDOW_SURFACE=1
   *  in the start's extras: the window's surface, as before. */
  private void pictureInView() {
    if ("1".equals(System.getenv("RETRO_WINDOW_SURFACE"))) return;
    try {
      SurfaceView sv = new SurfaceView(this);
      sv.getHolder().addCallback(this);            // (NativeActivity's: the surface to the app)
      getWindow().takeSurface(null);
      try {
        addContentView(sv, new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                                                      ViewGroup.LayoutParams.MATCH_PARENT));
      } catch (Throwable t) {
        getWindow().takeSurface(this);             // (as before)
        return;
      }
      surface = sv;
      RetroDevice.listenDrops(this, sv);        // (what other apps drop on it)
      // (its place in the window after every layout: a title bar over it, the bars beside it)
      sv.getViewTreeObserver().addOnGlobalLayoutListener(
          new android.view.ViewTreeObserver.OnGlobalLayoutListener() {
            public void onGlobalLayout() {
              underBars(!inMultiWindow());
              sendInsets();
            }
          });
    } catch (Throwable t) {
      return;
    }
    underBars(!inMultiWindow());
  }

  /** The surface view the app draws in (`pictureInView`); null: the window's surface. */
  SurfaceView surface;
  /** The system's bars and keyboard over the window, as it says them. */
  final int[] windowInsets = new int[4];
  private final int[] insetsSent = {-1, -1, -1, -1};

  /** (the bars and the keyboard over the app's picture -- the window's insets less what lies
   *  between the picture and the window's edges --, and the picture's place, to the app when
   *  they change) */
  void sendInsets() {
    int t = windowInsets[0], l = windowInsets[1], b = windowInsets[2], r = windowInsets[3];
    SurfaceView sv = surface;
    if (sv != null && sv.getWidth() > 0 && sv.getHeight() > 0) {
      int[] at = new int[2];
      sv.getLocationInWindow(at);
      View d = getWindow().getDecorView();
      t = Math.max(0, t - at[1]);
      l = Math.max(0, l - at[0]);
      b = Math.max(0, b - (d.getHeight() - at[1] - sv.getHeight()));
      r = Math.max(0, r - (d.getWidth() - at[0] - sv.getWidth()));
      if (at[0] != surfaceX || at[1] != surfaceY) {
        surfaceX = at[0];
        surfaceY = at[1];
        try {
          nativeSurfaceAt(at[0], at[1]);
        } catch (UnsatisfiedLinkError e) {
          // a libmain.so without it: the picture at the window's corner
        }
      }
    }
    if (t == insetsSent[0] && l == insetsSent[1] && b == insetsSent[2] && r == insetsSent[3]) return;
    insetsSent[0] = t; insetsSent[1] = l; insetsSent[2] = b; insetsSent[3] = r;
    try {
      nativeInsets(t, l, b, r);
    } catch (UnsatisfiedLinkError e) {
      // a libmain.so without the glue: the content rect is used
    }
  }

  private static Method multiWindow;
  private int underBarsNow = -1;

  /** (in split screen or a small window: Activity.isInMultiWindowMode, Android 7 on) */
  private boolean inMultiWindow() {
    if (Build.VERSION.SDK_INT < 24) return false;
    try {
      if (multiWindow == null) multiWindow = android.app.Activity.class.getMethod("isInMultiWindowMode");
      return (Boolean) multiWindow.invoke(this);
    } catch (Throwable t) {
      return false;
    }
  }

  /** The picture laid out under the status and navigation bars (filling the screen, as the
   *  window's surface was: the app colors them), or between them (split screen, a small
   *  window: the system's own there, as other apps have). */
  private void underBars(boolean on) {
    if (surface == null || underBarsNow == (on ? 1 : 0)) return;
    underBarsNow = on ? 1 : 0;
    try {
      View d = getWindow().getDecorView();
      int bits = 0x100 | 0x200 | 0x400;        // LAYOUT_STABLE, _HIDE_NAVIGATION, _FULLSCREEN
      int f = d.getSystemUiVisibility();
      d.setSystemUiVisibility(on ? (f | bits) : (f & ~bits));
    } catch (Throwable t) { }
  }

  @Override
  public void onConfigurationChanged(android.content.res.Configuration c) {
    super.onConfigurationChanged(c);
    underBars(!inMultiWindow());                 // (into split screen or a small window, or out)
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

  /** The colors the app draws under the status and navigation bars: their
   *  icons turn dark or light to stay visible. */
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

  static String mimeOf(String path) {
    int dot = path.lastIndexOf('.');
    String t = dot < 0 ? null : MimeTypeMap.getSingleton()
        .getMimeTypeFromExtension(path.substring(dot + 1).toLowerCase());
    return t != null ? t : "application/octet-stream";
  }

  /** Open a file in the app the system has for it (mode 0), choose the
   *  app (1) or share it (2). False when no app can take it. */
  public boolean openFile(String path, int mode) {
    try {
      // a document of another app (Termux's files): its own address, which
      // this app may pass on; else this app's provider for the file
      Uri doc = new java.io.File(path).canRead() ? null : docUriFor(path);
      Uri uri = doc != null ? doc : new Uri.Builder().scheme("content")
          .authority(getPackageName() + ".files").path(path).build();
      String mime = mimeOf(path);
      Intent i;
      if (mode == 2) {
        i = new Intent(Intent.ACTION_SEND);
        i.setType(mime);
        i.putExtra(Intent.EXTRA_STREAM, uri);
      } else {
        i = new Intent(Intent.ACTION_VIEW);
        i.setDataAndType(uri, mime);
      }
      i.setClipData(ClipData.newRawUri("", uri));
      i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
      Intent go = mode == 0 ? i : Intent.createChooser(i, mode == 2 ? "Share" : "Open with");
      go.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
      startActivity(go);
      return true;
    } catch (Throwable t) {
      return false;
    }
  }

  /** An app's package (.apk) to Android's installer: 0 the installer
   *  opened; 1 the system's "Install unknown apps" setting opened instead
   *  (this app is not allowed yet: allowed there, ask again); 2 this app
   *  may not install apps (built without REQUEST_INSTALL_PACKAGES); 3 it
   *  failed. */
  int installApk(String path) {
    try {
      if (Build.VERSION.SDK_INT >= 26) {
        boolean declared = false;
        String[] req = getPackageManager().getPackageInfo(getPackageName(),
            PackageManager.GET_PERMISSIONS).requestedPermissions;
        if (req != null)
          for (String r : req)
            if ("android.permission.REQUEST_INSTALL_PACKAGES".equals(r)) declared = true;
        if (!declared) return 2;
        // (API 26's: called by name, the dex is built against API 23)
        Object can = PackageManager.class.getMethod("canRequestPackageInstalls")
            .invoke(getPackageManager());
        if (!Boolean.TRUE.equals(can)) {
          Intent s = new Intent("android.settings.MANAGE_UNKNOWN_APP_SOURCES",
              Uri.parse("package:" + getPackageName()));
          s.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
          startActivity(s);
          return 1;
        }
      }
      // (a document of another app: its own address; else this app's provider)
      Uri doc = new java.io.File(path).canRead() ? null : docUriFor(path);
      Uri uri = doc != null ? doc : new Uri.Builder().scheme("content")
          .authority(getPackageName() + ".files").path(path).build();
      Intent i = new Intent(Intent.ACTION_VIEW);
      i.setDataAndType(uri, "application/vnd.android.package-archive");
      i.setClipData(ClipData.newRawUri("", uri));
      i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
      startActivity(i);
      return 0;
    } catch (Throwable t) {
      return 3;
    }
  }

  /** A photo (JPEG, PNG, WebP, HEIC...) about maxW x maxH or a little
   *  larger, upright: [width, height, ARGB pixels...]; null if it cannot. */
  public int[] decodeImage(String path, int maxW, int maxH) {
    try {
      // a document of another app (Termux's files): read through its provider
      Uri doc = new java.io.File(path).canRead() ? null : docUriFor(path);
      BitmapFactory.Options o = new BitmapFactory.Options();
      o.inJustDecodeBounds = true;
      if (doc != null) {
        java.io.InputStream in = getContentResolver().openInputStream(doc);
        try { BitmapFactory.decodeStream(in, null, o); } finally { in.close(); }
      } else BitmapFactory.decodeFile(path, o);
      if (o.outWidth <= 0 || o.outHeight <= 0) return null;
      int s = 1;
      // decode at the smallest power of two still at least the size asked
      while (o.outWidth / (s * 2) >= Math.min(maxW, maxH) &&
             o.outHeight / (s * 2) >= Math.min(maxW, maxH)) s *= 2;
      BitmapFactory.Options p = new BitmapFactory.Options();
      p.inSampleSize = s;
      p.inPreferredConfig = Bitmap.Config.ARGB_8888;
      Bitmap b;
      if (doc != null) {
        java.io.InputStream in = getContentResolver().openInputStream(doc);
        try { b = BitmapFactory.decodeStream(in, null, p); } finally { in.close(); }
      } else b = BitmapFactory.decodeFile(path, p);
      if (b == null) return null;
      int rot = 0;
      if (doc == null) try {
        int or = new ExifInterface(path).getAttributeInt("Orientation", 1);
        rot = or == 6 ? 90 : or == 3 ? 180 : or == 8 ? 270 : 0;
      } catch (Throwable t) {
        // no EXIF data
      }
      // turned, and scaled down to fit the size asked for, in one step
      int bw = b.getWidth(), bh = b.getHeight();
      int fw = rot == 90 || rot == 270 ? bh : bw;
      int fh = rot == 90 || rot == 270 ? bw : bh;
      float k = Math.min(1f, Math.min(maxW / (float) fw, maxH / (float) fh));
      if (rot != 0 || k < 1f) {
        Matrix m = new Matrix();
        if (k < 1f) m.postScale(k, k);
        if (rot != 0) m.postRotate(rot);
        Bitmap r = Bitmap.createBitmap(b, 0, 0, bw, bh, m, true);
        if (r != b) b.recycle();
        b = r;
      }
      int w = b.getWidth(), h = b.getHeight();
      int[] out = new int[2 + w * h];
      out[0] = w;
      out[1] = h;
      b.getPixels(out, 2, w, 0, 0, w, h);
      b.recycle();
      return out;
    } catch (Throwable t) {
      return null;                    // also out of memory
    }
  }

  // ---- documents of other apps (the Storage Access Framework) ------------
  //
  // Folders another app shares through its documents provider -- Termux's
  // home, above all -- once the user granted them: listed, read, written,
  // made, renamed and deleted by their document ids. Called through
  // uirelaysCall from any thread.

  static final int PICK_TREE = 4242;
  static final int PICK_OPEN = 4243;
  static final int PICK_SAVE = 4244;

  // The system's own file picker (retroui/systemfiles): what the user
  // picked to open -- copied into the cache, "path\turi" a line -- and
  // where to save ("" while the picker is up, "\u0001" when it was left).
  static String pickedOpen = "";
  static String pickedTree = "";        // (a folder picked for the app: its tree, its document id)
  static String pickedSave = "";

  /** A document copied into the cache's folder `sub` under its own name;
   *  its path (null: it could not be read). */
  String copyIn(Uri u, String sub) {
    try {
      String name = "document";
      try {
        Cursor c = getContentResolver().query(u, new String[]{android.provider.OpenableColumns.DISPLAY_NAME},
                                              null, null, null);
        if (c != null) {
          if (c.moveToFirst() && c.getString(0) != null) name = c.getString(0);
          c.close();
        }
      } catch (Throwable ignored) { }
      name = name.replace('/', '_').replace('\t', ' ').replace('\n', ' ');
      java.io.File dir = new java.io.File(getCacheDir(), sub);
      dir.mkdirs();
      java.io.File f = new java.io.File(dir, name);
      for (int k = 2; f.exists(); k++) {
        java.io.File d2 = new java.io.File(dir, String.valueOf(k));
        d2.mkdirs();
        f = new java.io.File(d2, name);
      }
      java.io.InputStream in = getContentResolver().openInputStream(u);
      if (in == null) return null;
      java.io.OutputStream out = new java.io.FileOutputStream(f);
      byte[] buf = new byte[65536];
      int n;
      while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
      out.close();
      in.close();
      return f.getAbsolutePath();
    } catch (Throwable t) {
      return null;
    }
  }

  /** The file at `path` written into the document `uri`. */
  boolean copyOut(String path, String uri) {
    try {
      java.io.OutputStream out = getContentResolver().openOutputStream(Uri.parse(uri), "wt");
      if (out == null) return false;
      java.io.InputStream in = new java.io.FileInputStream(path);
      byte[] buf = new byte[65536];
      int n;
      while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
      in.close();
      out.close();
      return true;
    } catch (Throwable t) {
      return false;
    }
  }

  void keepUri(Uri u, Intent data) {
    // (kept for as long as the app is installed, to write to when it can be)
    int rw = Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION;
    try { getContentResolver().takePersistableUriPermission(u, data.getFlags() & rw); }
    catch (Throwable t) { }
  }

  // What other apps shared with this one (their share sheet: an APK made
  // with retroapk --share-target): "t" and a text, "f" and a file copied
  // into the cache, taken by the native side with "sharedIn".
  static final java.util.ArrayList<String> shared = new java.util.ArrayList<String>();

  @Override protected void onNewIntent(Intent i) {
    super.onNewIntent(i);
    setIntent(i);
    takeShared(i);
    takeAction(i);
    RetroDevice.takeLink(i);
  }

  // A notification's button pressed (retroui/notify's actions): "tag\taction",
  // taken by the native side with "notifyActions"; the notification goes.
  static final java.util.ArrayList<String> notifyActions = new java.util.ArrayList<String>();
  static final String ActionExtra = "org.retro.notifyAction";

  void takeAction(Intent i) {
    if (i == null) return;
    String a = i.getStringExtra(ActionExtra);
    if (a == null) return;
    i.removeExtra(ActionExtra);
    synchronized (notifyActions) { notifyActions.add(a); }
    try {
      int tab = a.indexOf('\t');
      String tag = tab > 0 ? a.substring(0, tab) : null;
      ((android.app.NotificationManager) getSystemService(NOTIFICATION_SERVICE)).cancel(tag, 1);
    } catch (Throwable t) { }
  }

  /** Buttons on a notification being built (at most three, apart by
   *  \u0001): each opens the app with "tag\taction". Static: a background
   *  check posts notifications too, with no activity. */
  public static void addNotifyActions(Context c, android.app.Notification.Builder b,
                                      String tag, String actions) {
    try {
      Intent launch = c.getPackageManager().getLaunchIntentForPackage(c.getPackageName());
      if (launch == null) return;
      String[] as = actions.split("\u0001");
      for (int k = 0; k < as.length && k < 3; k++) {
        if (as[k].length() == 0) continue;
        Intent it = new Intent(launch);
        it.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        it.putExtra(ActionExtra, tag + "\t" + as[k]);
        int code = (tag + "\t" + as[k]).hashCode() & 0x7fffffff;
        android.app.PendingIntent pi = android.app.PendingIntent.getActivity(c, code, it,
            0x04000000 | 0x08000000);         // IMMUTABLE, UPDATE_CURRENT
        b.addAction(new android.app.Notification.Action(0, as[k], pi));
      }
    } catch (Throwable t) { }
  }

  void takeShared(Intent i) {
    if (i == null) return;
    String act = i.getAction();
    // ("Open with" in a file manager: VIEW or EDIT, its document in the data -- an APK made
    // with retroapk --opens)
    boolean opened = Intent.ACTION_VIEW.equals(act) || Intent.ACTION_EDIT.equals(act);
    if (!opened && !Intent.ACTION_SEND.equals(act) && !Intent.ACTION_SEND_MULTIPLE.equals(act)) return;
    try {
      java.util.ArrayList<String> got = new java.util.ArrayList<String>();
      CharSequence t = opened ? null : i.getCharSequenceExtra(Intent.EXTRA_TEXT);
      if (t != null && t.length() > 0) got.add("t" + t);
      java.util.ArrayList<Uri> uris = new java.util.ArrayList<Uri>();
      // (written back to when the other app let it be written)
      boolean writable = opened && (i.getFlags() & Intent.FLAG_GRANT_WRITE_URI_PERMISSION) != 0;
      if (opened) {
        if (i.getData() != null) uris.add(i.getData());
      } else if (Intent.ACTION_SEND_MULTIPLE.equals(act)) {
        java.util.ArrayList<Uri> l = i.getParcelableArrayListExtra(Intent.EXTRA_STREAM);
        if (l != null) uris.addAll(l);
      } else {
        Uri u = i.getParcelableExtra(Intent.EXTRA_STREAM);
        if (u != null) uris.add(u);
      }
      java.io.File dir = new java.io.File(getCacheDir(), "shared");
      dir.mkdirs();
      for (Uri u : uris) {
        String name = "shared";
        try {
          Cursor c = getContentResolver().query(u, new String[]{android.provider.OpenableColumns.DISPLAY_NAME},
                                                null, null, null);
          if (c != null) {
            if (c.moveToFirst() && c.getString(0) != null) name = c.getString(0);
            c.close();
          }
        } catch (Throwable ignored) { }
        name = name.replace('/', '_');
        java.io.File f = new java.io.File(dir, name);
        for (int k = 2; f.exists(); k++) f = new java.io.File(dir, k + "-" + name);
        java.io.InputStream in = getContentResolver().openInputStream(u);
        if (in == null) continue;
        java.io.OutputStream out = new java.io.FileOutputStream(f);
        byte[] buf = new byte[65536];
        int n;
        while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
        out.close();
        in.close();
        got.add("f" + f.getAbsolutePath() + (writable ? "\t" + u.toString() : ""));
      }
      synchronized (shared) { shared.addAll(got); }
    } catch (Throwable ignored) { }
    // (taken once: not again when the activity is made again)
    i.setAction(Intent.ACTION_MAIN);
  }

  /** One entry point for the native side: `name` and tab-separated `arg`
   *  in, UTF-8 text out (null: failed). */
  public byte[] uirelaysCall(String name, String arg) {
    try {
      // (pictures go as bytes, not text)
      if (name.equals("camera.frame")) return RetroCamera.frameBytes(this);
      String r = call(name, arg);
      return r == null ? null : r.getBytes("UTF-8");
    } catch (Throwable t) {
      return null;
    }
  }

  private String call(String name, String arg) throws Exception {
    String[] a = arg.split("\t", -1);
    ContentResolver cr = getContentResolver();
    // the other parts (media, printing...): "part.what" goes to the static
    // call(Activity, what, args) of the class RetroPart (tools/android/*.java)
    int dot = name.indexOf('.');
    if (dot > 0) {
      String part = name.substring(0, dot);
      Class<?> c = Class.forName("org.retro.Retro" +
          Character.toUpperCase(part.charAt(0)) + part.substring(1));
      Method m = c.getMethod("call", android.app.Activity.class, String.class, String[].class);
      return (String) m.invoke(null, this, name.substring(dot + 1), a);
    }
    if (name.equals("sharedIn")) {
      // (what came, taken: entries apart by \u0001)
      synchronized (shared) {
        StringBuilder b = new StringBuilder();
        for (String e : shared) {
          if (b.length() > 0) b.append('\u0001');
          b.append(e);
        }
        shared.clear();
        return b.toString();
      }
    }
    if (name.equals("installApk")) return String.valueOf(installApk(a[0]));
    if (name.equals("homeWidget"))
      return RetroWidget.set(this, a[0], a.length > 1 ? a[1] : "", a.length > 2 ? a[2] : "") ? "1" : "0";
    if (name.equals("notifyActions")) {
      synchronized (notifyActions) {
        StringBuilder b = new StringBuilder();
        for (String e : notifyActions) {
          if (b.length() > 0) b.append('\u0001');
          b.append(e);
        }
        notifyActions.clear();
        return b.toString();
      }
    }
    if (name.equals("installed")) {
      try {
        getPackageManager().getPackageInfo(a[0], 0);
        return "1";
      } catch (PackageManager.NameNotFoundException e) {
        return "0";
      }
    }
    if (name.equals("cacheDir")) return getCacheDir().getAbsolutePath();
    if (name.equals("pickOpen")) {         // "1" for several, then the MIME types wanted (none: any)
      final Intent i = new Intent("android.intent.action.OPEN_DOCUMENT");
      i.addCategory("android.intent.category.OPENABLE");
      i.setType("*/*");
      if (a.length > 0 && a[0].equals("1")) i.putExtra("android.intent.extra.ALLOW_MULTIPLE", true);
      java.util.ArrayList<String> types = new java.util.ArrayList<String>();
      for (int k = 1; k < a.length; k++) if (a[k].length() > 0) types.add(a[k]);
      if (types.size() == 1) i.setType(types.get(0));
      else if (types.size() > 1) i.putExtra("android.intent.extra.MIME_TYPES", types.toArray(new String[0]));
      // (in the folder last opened from -- else Downloads -- not Recent, which lists
      // only pictures and documents it knows: a PSD, an AI, an IDML are not there)
      if (Build.VERSION.SDK_INT >= 26) {
        Uri at = openFolder();
        if (at != null) i.putExtra("android.provider.extra.INITIAL_URI", at);
      }
      i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION |
                 0x00000040);              // FLAG_GRANT_PERSISTABLE_URI_PERMISSION
      synchronized (shared) { pickedOpen = ""; }
      runOnUiThread(new Runnable() {
        public void run() {
          try { startActivityForResult(i, PICK_OPEN); }
          catch (Throwable t) { synchronized (shared) { pickedOpen = "\u0001"; } }
        }
      });
      return "1";
    }
    if (name.equals("picked")) {           // what was picked, taken ("": not yet)
      synchronized (shared) {
        String r = pickedOpen;
        pickedOpen = "";
        return r;
      }
    }
    if (name.equals("pickSave")) {         // the name offered, its MIME type
      final Intent i = new Intent("android.intent.action.CREATE_DOCUMENT");
      i.addCategory("android.intent.category.OPENABLE");
      i.setType(a.length > 1 && a[1].length() > 0 ? a[1] : "application/octet-stream");
      i.putExtra("android.intent.extra.TITLE", a[0]);
      i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION | 0x00000040);
      synchronized (shared) { pickedSave = ""; }
      runOnUiThread(new Runnable() {
        public void run() {
          try { startActivityForResult(i, PICK_SAVE); }
          catch (Throwable t) { synchronized (shared) { pickedSave = "\u0001"; } }
        }
      });
      return "1";
    }
    if (name.equals("pickSaved")) {        // the document to write to, taken ("": not yet)
      synchronized (shared) {
        String r = pickedSave;
        pickedSave = "";
        return r;
      }
    }
    if (name.equals("uriWrite")) return copyOut(a[1], a[0]) ? "1" : "0";     // uri, the file
    if (name.equals("treeAsk")) {          // authority, document id to start in (none: anywhere)
      final Intent i = new Intent("android.intent.action.OPEN_DOCUMENT_TREE");
      if (a.length >= 2 && Build.VERSION.SDK_INT >= 26)
        i.putExtra("android.provider.extra.INITIAL_URI",
                   DocumentsContract.buildDocumentUri(a[0], a[1]));
      i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION | 0x00000040);
      synchronized (shared) { pickedTree = ""; }
      runOnUiThread(new Runnable() {
        public void run() {
          try { startActivityForResult(i, PICK_TREE); }
          catch (Throwable t) { synchronized (shared) { pickedTree = "\u0001"; } }
        }
      });
      return "";
    }
    if (name.equals("treePicked")) {       // the folder picked, taken ("": not yet; \u0001 none)
      synchronized (shared) {
        String r = pickedTree;
        pickedTree = "";
        return r;
      }
    }
    if (name.equals("trees")) {            // the folders granted: tree uri, its document id
      StringBuilder b = new StringBuilder();
      for (UriPermission p : cr.getPersistedUriPermissions()) {
        Uri u = p.getUri();
        if (!p.isReadPermission()) continue;
        try {
          b.append(u.toString()).append('\t')
           .append(DocumentsContract.getTreeDocumentId(u)).append('\n');
        } catch (Throwable t) { }
      }
      return b.toString();
    }
    Uri tree = Uri.parse(a[0]);
    if (name.equals("list")) {             // tree, folder's document id
      Uri kids = DocumentsContract.buildChildDocumentsUriUsingTree(tree, a[1]);
      Cursor c = cr.query(kids, new String[] {
          DocumentsContract.Document.COLUMN_DOCUMENT_ID,
          DocumentsContract.Document.COLUMN_DISPLAY_NAME,
          DocumentsContract.Document.COLUMN_MIME_TYPE,
          DocumentsContract.Document.COLUMN_SIZE,
          DocumentsContract.Document.COLUMN_LAST_MODIFIED,
          DocumentsContract.Document.COLUMN_FLAGS}, null, null, null);
      if (c == null) return null;
      StringBuilder b = new StringBuilder();
      try {
        while (c.moveToNext()) {
          b.append(c.getString(0)).append('\t').append(c.getString(1)).append('\t')
           .append(c.getString(2)).append('\t')
           .append(c.isNull(3) ? 0 : c.getLong(3)).append('\t')
           .append(c.isNull(4) ? 0 : c.getLong(4)).append('\t')
           .append(c.getInt(5)).append('\n');
        }
      } finally {
        c.close();
      }
      return b.toString();
    }
    Uri doc = DocumentsContract.buildDocumentUriUsingTree(tree, a[1]);
    if (name.equals("stat")) {             // tree, document id
      Cursor c = cr.query(doc, new String[] {
          DocumentsContract.Document.COLUMN_DISPLAY_NAME,
          DocumentsContract.Document.COLUMN_MIME_TYPE,
          DocumentsContract.Document.COLUMN_SIZE,
          DocumentsContract.Document.COLUMN_LAST_MODIFIED}, null, null, null);
      if (c == null) return null;
      try {
        if (!c.moveToFirst()) return null;
        return c.getString(0) + "\t" + c.getString(1) + "\t" +
               (c.isNull(2) ? 0 : c.getLong(2)) + "\t" + (c.isNull(3) ? 0 : c.getLong(3));
      } finally {
        c.close();
      }
    }
    if (name.equals("open")) {             // tree, document id, mode ("r", "w", "rw", "wt")
      ParcelFileDescriptor pfd = cr.openFileDescriptor(doc, a[2]);
      return pfd == null ? null : String.valueOf(pfd.detachFd());
    }
    if (name.equals("create")) {           // tree, folder's document id, mime type, name
      Uri u = DocumentsContract.createDocument(cr, doc, a[2], a[3]);
      return u == null ? null : DocumentsContract.getDocumentId(u);
    }
    if (name.equals("delete")) {
      return DocumentsContract.deleteDocument(cr, doc) ? "1" : null;
    }
    if (name.equals("rename")) {           // tree, document id, new name
      Uri u = DocumentsContract.renameDocument(cr, doc, a[2]);
      return u == null ? null : DocumentsContract.getDocumentId(u);
    }
    if (name.equals("move")) {             // tree, document id, old parent, new parent
      if (Build.VERSION.SDK_INT < 24) return null;
      Method m = DocumentsContract.class.getMethod("moveDocument",
          ContentResolver.class, Uri.class, Uri.class, Uri.class);
      Uri u = (Uri) m.invoke(null, cr, doc,
          DocumentsContract.buildDocumentUriUsingTree(tree, a[2]),
          DocumentsContract.buildDocumentUriUsingTree(tree, a[3]));
      return u == null ? null : DocumentsContract.getDocumentId(u);
    }
    return null;
  }

  /** The document address of `path` in a folder of another app this app
   *  was given (providers that name documents by paths), else null. */
  Uri docUriFor(String path) {
    for (UriPermission p : getContentResolver().getPersistedUriPermissions()) {
      Uri t = p.getUri();
      String base;
      try { base = DocumentsContract.getTreeDocumentId(t); } catch (Throwable e) { continue; }
      if (base != null && base.startsWith("/") &&
          (path.equals(base) || path.startsWith(base + "/")))
        return DocumentsContract.buildDocumentUriUsingTree(t, path);
    }
    return null;
  }

  @Override
  protected void onActivityResult(int request, int result, Intent data) {
    // (a page's file picker; the screen lock asked)
    if (RetroWeb.onResult(request, result, data)) return;
    if (RetroDevice.onResult(request, result)) return;
    if (request == PICK_TREE) {
      String r = "\u0001";
      if (result == RESULT_OK && data != null && data.getData() != null) {
        try {
          getContentResolver().takePersistableUriPermission(data.getData(),
              Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        } catch (Throwable t) { }
        try {
          r = data.getData().toString() + "\t" + DocumentsContract.getTreeDocumentId(data.getData());
        } catch (Throwable t) { }
      }
      synchronized (shared) { pickedTree = r; }
      return;
    }
    if (request == PICK_OPEN) {
      final java.util.ArrayList<Uri> uris = new java.util.ArrayList<Uri>();
      if (result == RESULT_OK && data != null) {
        if (data.getClipData() != null)
          for (int k = 0; k < data.getClipData().getItemCount(); k++) uris.add(data.getClipData().getItemAt(k).getUri());
        else if (data.getData() != null) uris.add(data.getData());
      }
      if (uris.isEmpty()) {
        synchronized (shared) { pickedOpen = "\u0001"; }
        return;
      }
      keepOpenFolder(uris.get(0));
      final Intent got = data;
      // (a big file takes its time: not on the thread that draws)
      new Thread(new Runnable() {
        public void run() {
          StringBuilder b = new StringBuilder();
          for (Uri u : uris) {
            if (u == null) continue;
            keepUri(u, got);
            String p = copyIn(u, "opened");
            if (p == null) continue;
            if (b.length() > 0) b.append('\n');
            b.append(p).append('\t').append(u.toString());
          }
          synchronized (shared) { pickedOpen = b.length() > 0 ? b.toString() : "\u0001"; }
        }
      }).start();
      return;
    }
    if (request == PICK_SAVE) {
      String r = "\u0001";
      if (result == RESULT_OK && data != null && data.getData() != null) {
        keepUri(data.getData(), data);
        keepOpenFolder(data.getData());
        r = data.getData().toString();
      }
      synchronized (shared) { pickedSave = r; }
      return;
    }
    super.onActivityResult(request, result, data);
  }

  static final String STORAGE_DOCS = "com.android.externalstorage.documents";

  Uri openFolder() {
    // (the folder of the file last opened or saved through the system's picker; else Downloads)
    String kept = getSharedPreferences("retro", MODE_PRIVATE).getString("openFolder", null);
    if (kept != null) return Uri.parse(kept);
    return DocumentsContract.buildDocumentUri(STORAGE_DOCS, "primary:Download");
  }

  void keepOpenFolder(Uri u) {
    // (a file of the device's storage: its folder, for the next Open)
    try {
      if (u == null || !STORAGE_DOCS.equals(u.getAuthority())) return;
      String id = DocumentsContract.getDocumentId(u);
      int slash = id.lastIndexOf('/');
      int colon = id.indexOf(':');
      String parent = slash > 0 ? id.substring(0, slash) : (colon >= 0 ? id.substring(0, colon + 1) : null);
      if (parent == null) return;
      getSharedPreferences("retro", MODE_PRIVATE).edit()
        .putString("openFolder", DocumentsContract.buildDocumentUri(STORAGE_DOCS, parent).toString()).apply();
    } catch (Throwable t) { }
  }

  @Override
  public void onRequestPermissionsResult(int request, String[] names, int[] answers) {
    // (the place's permission: retroui/system's location)
    RetroSystem.permissionAnswer(request, answers.length > 0 && answers[0] == 0);
    super.onRequestPermissionsResult(request, names, answers);
  }

  /** Show or hide the soft keyboard; called by native code on its thread.
   *  The keyboard works through RetroInput's input connection (suggestions,
   *  swipe and voice typing, what it composes); an app without the natives
   *  it needs falls back to the window's. */
  public void keyboard(final boolean show) {
    runOnUiThread(new Runnable() {
      public void run() {
        if (inputNatives) {
          RetroInput.show(RetroActivity.this, show);
          return;
        }
        InputMethodManager imm =
            (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
        if (imm == null) return;
        View v = getWindow().getDecorView();
        if (show) imm.showSoftInput(v, 0);
        else imm.hideSoftInputFromWindow(v.getWindowToken(), 0);
      }
    });
  }

  /** The keyboard the field with the focus wants (0 letters, 1 digits, 2 a decimal number,
   *  3 a phone number, 4 an email, 5 a web address, 6 a password) and what its Enter key says
   *  (0 Return, 1 Next, 2 Done, 3 Search, 4 Go); called by native code when it changes. */
  public void keyboardKind(final int kind, final int enter) {
    runOnUiThread(new Runnable() {
      public void run() { RetroInput.setKind(RetroActivity.this, kind, enter); }
    });
  }

  /** The native side has nativeCompose and nativeKey (set by it). */
  static volatile boolean inputNatives = false;
  public static void haveInputNatives() { inputNatives = true; }
}
