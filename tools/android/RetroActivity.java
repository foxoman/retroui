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
import android.view.View;
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

  /** One entry point for the native side: `name` and tab-separated `arg`
   *  in, UTF-8 text out (null: failed). */
  public byte[] uirelaysCall(String name, String arg) {
    try {
      // (pictures go as bytes, not text)
      if (name.equals("camera.frame")) return RetroCamera.frameBytes();
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
    if (name.equals("installed")) {
      try {
        getPackageManager().getPackageInfo(a[0], 0);
        return "1";
      } catch (PackageManager.NameNotFoundException e) {
        return "0";
      }
    }
    if (name.equals("treeAsk")) {          // authority, document id to start in
      final Intent i = new Intent("android.intent.action.OPEN_DOCUMENT_TREE");
      if (a.length >= 2 && Build.VERSION.SDK_INT >= 26)
        i.putExtra("android.provider.extra.INITIAL_URI",
                   DocumentsContract.buildDocumentUri(a[0], a[1]));
      runOnUiThread(new Runnable() {
        public void run() {
          try { startActivityForResult(i, PICK_TREE); } catch (Throwable t) { }
        }
      });
      return "";
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
    // (a page's file picker)
    if (RetroWeb.onResult(request, result, data)) return;
    if (request == PICK_TREE) {
      if (result == RESULT_OK && data != null && data.getData() != null) {
        try {
          getContentResolver().takePersistableUriPermission(data.getData(),
              Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        } catch (Throwable t) { }
      }
      return;
    }
    super.onActivityResult(request, result, data);
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

  /** The native side has nativeCompose and nativeKey (set by it). */
  static volatile boolean inputNatives = false;
  public static void haveInputNatives() { inputNatives = true; }
}
