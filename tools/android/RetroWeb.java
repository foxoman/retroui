package org.retro;

import android.app.Activity;
import android.app.Application;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.PixelFormat;
import android.net.Uri;
import android.os.Bundle;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.app.DownloadManager;
import android.content.Context;
import android.graphics.Canvas;
import android.os.Environment;
import android.print.PrintManager;
import android.webkit.GeolocationPermissions;
import android.webkit.JavascriptInterface;
import android.webkit.MimeTypeMap;
import android.webkit.PermissionRequest;
import android.webkit.URLUtil;
import android.webkit.ValueCallback;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import java.util.ArrayList;
import java.util.HashMap;

/** Web pages: the system's WebView over a part of the window (webView in
 *  src/retroui/htmlview.nim), reached as "web.show", "web.hide",
 *  "web.close", "web.back", "web.forward", "web.reload", "web.stop",
 *  "web.run", "web.allow", "web.zoom" and "web.info" through
 *  RetroActivity.uirelaysCall. The page's scripts post to the app with
 *  retro.post(text); what they post comes with "web.info".
 *
 *  NativeActivity reads the window's input itself: a WebView inside the
 *  window would never get a touch. So each page lives in a small panel
 *  window of its own over the activity, placed where the app draws it
 *  (window pixels). The panel takes the keyboard only once it is touched
 *  (the app's own text boxes keep theirs until then) and gives it back on a
 *  touch outside it. Back goes back in the page; with no page before, the
 *  app is told (web.info) and the keyboard goes back to it. */
public final class RetroWeb {
  private RetroWeb() { }

  static final class Web {
    Activity act;
    WebView view;
    Root root;
    WindowManager.LayoutParams lp;
    boolean added;
    String loaded = "";
    volatile String url = "", title = "";
    volatile int progress = 100;
    volatile boolean canBack, canForward, backOut;
    volatile String[] hosts = new String[0];
    volatile String permit = "";       // what the page may use: "camera,microphone,location"
    final ArrayList<String> notes = new ArrayList<String>();   // "m" text, "b" address,
                                       // "p" a permission refused, "d" a download
    final ArrayList<long[]> downloads = new ArrayList<long[]>();   // DownloadManager ids
    final ArrayList<String> downloadUrls = new ArrayList<String>();
  }

  /** The app's own pages (web.appFolder): served at
   *  https://appassets.androidplatform.net/app/PATH, an address of their own. */
  static volatile String appFolder = "";
  static final String APP_PREFIX = "https://appassets.androidplatform.net/app/";

  static WebResourceResponse appFile(String url) {
    if (appFolder.length() == 0 || !url.startsWith(APP_PREFIX)) return null;
    String p = Uri.parse(url).getPath();
    if (p == null) return null;
    p = p.substring("/app/".length() - 1);
    while (p.startsWith("/")) p = p.substring(1);
    if (p.length() == 0) p = "index.html";
    if (p.contains("..")) return null;
    File f = new File(appFolder, p);
    if (f.isDirectory()) f = new File(f, "index.html");
    if (!f.isFile()) return new WebResourceResponse("text/plain", "utf-8", 404, "Not found",
        null, new java.io.ByteArrayInputStream(new byte[0]));
    String ext = MimeTypeMap.getFileExtensionFromUrl(f.getName());
    String mime = ext == null ? null : MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext.toLowerCase());
    if (mime == null) mime = f.getName().endsWith(".js") ? "text/javascript" : "application/octet-stream";
    try {
      return new WebResourceResponse(mime, "utf-8", new FileInputStream(f));
    } catch (Throwable t) { return null; }
  }

  static boolean permitted(Web w, String what) {
    for (String p : w.permit.split(",")) if (p.trim().equals(what)) return true;
    return false;
  }

  static void refused(Web w, String what) {
    synchronized (w.notes) { w.notes.add("p" + what); }
  }

  /** <input type=file>: the system's picker, its answer from the activity. */
  static ValueCallback<Uri[]> pickCallback;
  static final int PICK_FILES = 4245;

  public static boolean onResult(int request, int result, Intent data) {
    if (request != PICK_FILES || pickCallback == null) return false;
    Uri[] uris = null;
    if (result == Activity.RESULT_OK && data != null) {
      if (data.getClipData() != null) {
        int n = data.getClipData().getItemCount();
        uris = new Uri[n];
        for (int i = 0; i < n; i++) uris[i] = data.getClipData().getItemAt(i).getUri();
      } else if (data.getData() != null) uris = new Uri[] { data.getData() };
    }
    pickCallback.onReceiveValue(uris);
    pickCallback = null;
    return true;
  }

  /** retro.post(text) in the page's scripts. */
  static final class Bridge {
    final Web web;
    Bridge(Web w) { web = w; }
    @JavascriptInterface
    public void post(String m) {
      synchronized (web.notes) { web.notes.add("m" + (m == null ? "" : m)); }
    }
  }

  /** May the page open `url` (its host one of the allowed, or under one)? */
  static boolean allowed(Web w, String url) {
    String[] hs = w.hosts;
    if (hs.length == 0) return true;
    String host;
    try { host = Uri.parse(url).getHost(); } catch (Throwable t) { host = null; }
    if (host == null) return true;
    host = host.toLowerCase();
    for (String h : hs) {
      String x = h.trim().toLowerCase();
      if (x.length() > 0 && (host.equals(x) || host.endsWith("." + x))) return true;
    }
    return false;
  }

  static final HashMap<String, Web> webs = new HashMap<String, Web>();
  static boolean watching;

  static final class Root extends FrameLayout {
    final Web web;
    Root(Activity a, Web w) { super(a); web = w; }

    @Override
    public boolean dispatchTouchEvent(MotionEvent e) {
      if (e.getActionMasked() == MotionEvent.ACTION_OUTSIDE) {
        focusable(web, false);
        return false;
      }
      if (e.getActionMasked() == MotionEvent.ACTION_DOWN) focusable(web, true);
      return super.dispatchTouchEvent(e);
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent e) {
      if (e.getKeyCode() == KeyEvent.KEYCODE_BACK) {
        if (e.getAction() == KeyEvent.ACTION_UP) {
          if (web.view.canGoBack()) web.view.goBack();
          else {
            web.backOut = true;
            focusable(web, false);
          }
        }
        return true;
      }
      return super.dispatchKeyEvent(e);
    }
  }

  static void focusable(Web w, boolean on) {
    if (w.lp == null) return;
    int f = w.lp.flags;
    int nf = on ? (f & ~WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE)
                : (f | WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE);
    if (nf == f) return;
    w.lp.flags = nf;
    if (w.added) {
      try { w.act.getWindowManager().updateViewLayout(w.root, w.lp); } catch (Throwable t) { }
    }
  }

  /** Pages pause with the activity and go with it. */
  static void watch(final Activity a) {
    if (watching) return;
    watching = true;
    a.getApplication().registerActivityLifecycleCallbacks(
        new Application.ActivityLifecycleCallbacks() {
          public void onActivityPaused(Activity x) {
            for (Web w : all(x)) {
              try { w.view.onPause(); } catch (Throwable t) { }
            }
          }
          public void onActivityResumed(Activity x) {
            for (Web w : all(x)) {
              try { if (w.added) w.view.onResume(); } catch (Throwable t) { }
            }
          }
          public void onActivityDestroyed(Activity x) {
            for (Web w : all(x)) {
              try {
                remove(w);
                w.view.destroy();
              } catch (Throwable t) { }
            }
            synchronized (webs) { webs.values().removeAll(all(x)); }
          }
          public void onActivityCreated(Activity x, Bundle b) { }
          public void onActivityStarted(Activity x) { }
          public void onActivityStopped(Activity x) { }
          public void onActivitySaveInstanceState(Activity x, Bundle b) { }
        });
  }

  static java.util.ArrayList<Web> all(Activity a) {
    java.util.ArrayList<Web> r = new java.util.ArrayList<Web>();
    synchronized (webs) {
      for (Web w : webs.values()) if (w.act == a) r.add(w);
    }
    return r;
  }

  /** The page with `key`, made the first time (on the UI thread). */
  static Web webOf(final Activity a, String key) {
    Web w;
    synchronized (webs) { w = webs.get(key); }
    if (w != null) return w;
    watch(a);
    final Web nw = new Web();
    nw.act = a;
    WebView v = new WebView(a);
    WebSettings s = v.getSettings();
    s.setJavaScriptEnabled(true);
    s.setDomStorageEnabled(true);
    s.setBuiltInZoomControls(true);
    s.setDisplayZoomControls(false);
    s.setUseWideViewPort(true);
    s.setLoadWithOverviewMode(true);
    s.setAllowFileAccess(false);
    s.setAllowFileAccessFromFileURLs(false);
    s.setAllowUniversalAccessFromFileURLs(false);
    v.setWebViewClient(new WebViewClient() {
      @Override
      public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest r) {
        return appFile(r.getUrl().toString());
      }
      @Override
      public boolean shouldOverrideUrlLoading(WebView view, String url) {
        String l = url.toLowerCase();
        if (url.startsWith(APP_PREFIX)) return false;
        if (l.startsWith("http:") || l.startsWith("https:")) {
          if (allowed(nw, url)) return false;
          synchronized (nw.notes) { nw.notes.add("b" + url); }   // the app is told
          return true;
        }
        if (l.startsWith("file:") || l.startsWith("about:") || l.startsWith("data:")) return false;
        try {                       // mail, phone, maps, stores: their apps
          Intent i = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
          i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
          a.startActivity(i);
        } catch (Throwable t) { }
        return true;
      }
      @Override
      public void onPageStarted(WebView view, String url, Bitmap icon) {
        nw.url = url == null ? "" : url;
        nw.progress = 0;
      }
      @Override
      public void onPageFinished(WebView view, String url) {
        nw.url = url == null ? "" : url;
        nw.progress = 100;
        nw.canBack = view.canGoBack();
        nw.canForward = view.canGoForward();
      }
      @Override
      public void doUpdateVisitedHistory(WebView view, String url, boolean reload) {
        nw.url = url == null ? "" : url;
        nw.canBack = view.canGoBack();
        nw.canForward = view.canGoForward();
      }
    });
    v.setWebChromeClient(new WebChromeClient() {
      @Override
      public void onProgressChanged(WebView view, int p) { nw.progress = p; }
      @Override
      public void onReceivedTitle(WebView view, String t) { nw.title = t == null ? "" : t; }
      @Override
      public void onPermissionRequest(final PermissionRequest r) {
        // only what the app allowed (webPermit) -- and has itself
        ArrayList<String> grant = new ArrayList<String>();
        for (String res : r.getResources()) {
          String what = res.equals(PermissionRequest.RESOURCE_VIDEO_CAPTURE) ? "camera"
                      : res.equals(PermissionRequest.RESOURCE_AUDIO_CAPTURE) ? "microphone" : "";
          String sys = what.equals("camera") ? android.Manifest.permission.CAMERA
                     : what.equals("microphone") ? android.Manifest.permission.RECORD_AUDIO : null;
          if (what.length() > 0 && permitted(nw, what)) {
            if (a.checkSelfPermission(sys) == android.content.pm.PackageManager.PERMISSION_GRANTED)
              grant.add(res);
            else a.requestPermissions(new String[] { sys }, 4246);
          } else if (what.length() > 0) refused(nw, what);
        }
        if (grant.isEmpty()) r.deny();
        else r.grant(grant.toArray(new String[0]));
      }
      @Override
      public void onGeolocationPermissionsShowPrompt(String origin, GeolocationPermissions.Callback cb) {
        boolean ok = permitted(nw, "location");
        if (!ok) refused(nw, "location");
        cb.invoke(origin, ok, false);
      }
      @Override
      public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> cb, FileChooserParams p) {
        if (pickCallback != null) pickCallback.onReceiveValue(null);
        pickCallback = cb;
        try {
          a.startActivityForResult(p.createIntent(), PICK_FILES);
          return true;
        } catch (Throwable t) {
          pickCallback = null;
          return false;
        }
      }
    });
    // downloads: the system's download manager, into Downloads (the app told)
    v.setDownloadListener(new android.webkit.DownloadListener() {
      public void onDownloadStart(String url, String agent, String disposition, String mime, long length) {
        try {
          String name = URLUtil.guessFileName(url, disposition, mime);
          DownloadManager.Request r = new DownloadManager.Request(Uri.parse(url));
          r.setMimeType(mime);
          r.addRequestHeader("User-Agent", agent);
          r.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED);
          r.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, name);
          DownloadManager dm = (DownloadManager) a.getSystemService(Context.DOWNLOAD_SERVICE);
          long id = dm.enqueue(r);
          synchronized (nw.notes) {
            nw.downloads.add(new long[] { id });
            nw.downloadUrls.add(url);
          }
        } catch (Throwable t) {
          synchronized (nw.notes) { nw.notes.add("d" + url + "\u0003\u00030\u0003-1"); }
        }
      }
    });
    v.addJavascriptInterface(new Bridge(nw), "retro");
    nw.view = v;
    nw.root = new Root(a, nw);
    nw.root.addView(v, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                                                    ViewGroup.LayoutParams.MATCH_PARENT));
    WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
        WindowManager.LayoutParams.TYPE_APPLICATION_PANEL,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
            | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
            | WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH,
        PixelFormat.OPAQUE);
    lp.gravity = Gravity.TOP | Gravity.LEFT;
    nw.lp = lp;
    synchronized (webs) { webs.put(key, nw); }
    return nw;
  }

  static void load(Web w, String url) {
    w.loaded = url;
    w.view.getSettings().setAllowFileAccess(url.startsWith("file:") || url.startsWith("/"));
    if (url.startsWith("html:"))
      w.view.loadDataWithBaseURL(null, url.substring(5), "text/html", "utf-8", null);
    else if (url.startsWith("/")) w.view.loadUrl("file://" + url);
    else w.view.loadUrl(url);
  }

  static void remove(Web w) {
    if (!w.added) return;
    try { w.act.getWindowManager().removeViewImmediate(w.root); } catch (Throwable t) { }
    w.added = false;
  }

  /** show (key, x, y, w, h, url), hide, close, back, forward, reload, stop
   *  (key), run (key, script), allow (key, hosts...), zoom (key, percent) and
   *  info (key: url, title, progress, can go back, Back pressed with no page
   *  before, can go forward, then the notes: "m" text or "b" address, each
   *  ending with \2) -- from the native thread. */
  public static String call(final Activity act, String what, String[] a) {
    final String key = a.length > 0 ? a[0] : "";
    if (what.equals("show")) {
      if (a.length < 6) return null;
      final int x = Integer.parseInt(a[1]), y = Integer.parseInt(a[2]);
      final int w = Math.max(1, Integer.parseInt(a[3])), h = Math.max(1, Integer.parseInt(a[4]));
      StringBuilder u = new StringBuilder(a[5]);
      for (int i = 6; i < a.length; i++) u.append('\t').append(a[i]);
      final String url = u.toString();
      act.runOnUiThread(new Runnable() {
        public void run() {
          try {
            Web wb = webOf(act, key);
            wb.lp.x = x;
            wb.lp.y = y;
            wb.lp.width = w;
            wb.lp.height = h;
            if (wb.lp.token == null) wb.lp.token = act.getWindow().getDecorView().getWindowToken();
            if (wb.lp.token == null) return;       // not on screen yet: the next show
            if (!wb.added) {
              act.getWindowManager().addView(wb.root, wb.lp);
              wb.added = true;
              wb.view.onResume();
            } else act.getWindowManager().updateViewLayout(wb.root, wb.lp);
            if (!url.equals(wb.loaded)) load(wb, url);
          } catch (Throwable t) { }
        }
      });
      return "";
    }
    final Web wb;
    synchronized (webs) { wb = webs.get(key); }
    if (what.equals("info")) {
      if (wb == null) return null;
      boolean out = wb.backOut;
      wb.backOut = false;
      StringBuilder notes = new StringBuilder();
      synchronized (wb.notes) {
        for (String n : wb.notes) notes.append(n).append('\u0002');
        wb.notes.clear();
        // the downloads: url, file, progress, done (1) or failed (-1)
        if (!wb.downloads.isEmpty()) {
          DownloadManager dm = (DownloadManager) act.getSystemService(Context.DOWNLOAD_SERVICE);
          for (int i = wb.downloads.size() - 1; i >= 0; i--) {
            long id = wb.downloads.get(i)[0];
            android.database.Cursor c = null;
            try {
              c = dm.query(new DownloadManager.Query().setFilterById(id));
              if (c != null && c.moveToFirst()) {
                int st = c.getInt(c.getColumnIndex(DownloadManager.COLUMN_STATUS));
                long got = c.getLong(c.getColumnIndex(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR));
                long all = c.getLong(c.getColumnIndex(DownloadManager.COLUMN_TOTAL_SIZE_BYTES));
                String file = c.getString(c.getColumnIndex(DownloadManager.COLUMN_LOCAL_URI));
                if (file != null && file.startsWith("file://")) file = Uri.parse(file).getPath();
                String end = st == DownloadManager.STATUS_SUCCESSFUL ? "1"
                           : st == DownloadManager.STATUS_FAILED ? "-1" : "0";
                int pct = all > 0 ? (int) (got * 100 / all) : 0;
                notes.append("d").append(wb.downloadUrls.get(i)).append('\u0003')
                     .append(file == null ? "" : file).append('\u0003').append(pct).append('\u0003')
                     .append(end).append('\u0002');
                if (!end.equals("0")) { wb.downloads.remove(i); wb.downloadUrls.remove(i); }
              }
            } catch (Throwable t) {
            } finally { if (c != null) c.close(); }
          }
        }
      }
      return wb.url + "\t" + wb.title.replace('\t', ' ') + "\t" + wb.progress + "\t"
          + (wb.canBack ? "1" : "0") + "\t" + (out ? "1" : "0") + "\t"
          + (wb.canForward ? "1" : "0") + "\t" + notes;
    }
    if (what.equals("appFolder")) {
      appFolder = key;
      return "1";
    }
    if (wb == null) return what.equals("back") ? "0" : "";
    if (what.equals("permit")) {
      wb.permit = a.length > 1 ? a[1] : "";
      return "1";
    }
    if (what.equals("snap")) {
      // a picture of the page as it is now, into a PNG (the UI thread draws it)
      if (a.length < 2 || !wb.added) return "0";
      final String path = a[1];
      final boolean[] ok = new boolean[1];
      final CountDownLatch done = new CountDownLatch(1);
      act.runOnUiThread(new Runnable() {
        public void run() {
          try {
            int w = wb.view.getWidth(), h = wb.view.getHeight();
            if (w > 0 && h > 0) {
              Bitmap b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
              wb.view.draw(new Canvas(b));
              FileOutputStream o = new FileOutputStream(path);
              b.compress(Bitmap.CompressFormat.PNG, 100, o);
              o.close();
              b.recycle();
              ok[0] = true;
            }
          } catch (Throwable t) {
          } finally { done.countDown(); }
        }
      });
      try { done.await(2, TimeUnit.SECONDS); } catch (Throwable t) { }
      return ok[0] ? "1" : "0";
    }
    if (what.equals("print")) {
      act.runOnUiThread(new Runnable() {
        public void run() {
          try {
            PrintManager pm = (PrintManager) act.getSystemService(Context.PRINT_SERVICE);
            String name = wb.title.length() > 0 ? wb.title : "Page";
            pm.print(name, wb.view.createPrintDocumentAdapter(name), null);
          } catch (Throwable t) { }
        }
      });
      return "1";
    }
    if (what.equals("back")) {
      if (!wb.canBack) return "0";
      act.runOnUiThread(new Runnable() {
        public void run() { if (wb.view.canGoBack()) wb.view.goBack(); }
      });
      return "1";
    }
    if (what.equals("forward")) {
      if (!wb.canForward) return "0";
      act.runOnUiThread(new Runnable() {
        public void run() { if (wb.view.canGoForward()) wb.view.goForward(); }
      });
      return "1";
    }
    if (what.equals("allow")) {
      String[] hs = new String[Math.max(0, a.length - 1)];
      for (int i = 1; i < a.length; i++) hs[i - 1] = a[i];
      wb.hosts = hs;
      return "";
    }
    if (what.equals("run") || what.equals("zoom") || what.equals("stop")) {
      StringBuilder j = new StringBuilder(a.length > 1 ? a[1] : "");
      for (int i = 2; i < a.length; i++) j.append('\t').append(a[i]);
      final String arg = j.toString();
      final String op = what;
      act.runOnUiThread(new Runnable() {
        public void run() {
          try {
            if (op.equals("run")) wb.view.evaluateJavascript(arg, null);
            else if (op.equals("stop")) wb.view.stopLoading();
            else wb.view.getSettings().setTextZoom(Math.max(50, Math.min(300, Integer.parseInt(arg.trim()))));
          } catch (Throwable t) { }
        }
      });
      return "";
    }
    if (what.equals("hide") || what.equals("close") || what.equals("reload")) {
      final boolean close = what.equals("close");
      final boolean reload = what.equals("reload");
      act.runOnUiThread(new Runnable() {
        public void run() {
          try {
            if (reload) { wb.view.reload(); return; }
            remove(wb);
            if (close) {
              synchronized (webs) { webs.remove(key); }
              wb.view.destroy();
            } else wb.view.onPause();
          } catch (Throwable t) { }
        }
      });
      return "";
    }
    return null;
  }
}
