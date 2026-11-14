package org.retro;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.res.Resources;
import android.view.View;
import android.widget.RemoteViews;

/** The app's widget on the home screen (an APK made with retroapk
 *  --widget): its icon, a title, a line or two and at most two buttons,
 *  set by the app (retroui/system's homeWidget) and kept in a file, so the
 *  launcher shows it again while the app is closed. A tap on it opens the
 *  app; a button opens it with "widget\t<button>" (RetroActivity's
 *  notification actions). */
public class RetroWidget extends AppWidgetProvider {
  static final String File = "retro-widget";

  @Override public void onUpdate(Context c, AppWidgetManager m, int[] ids) { show(c); }

  /** What the widget shows: buttons apart by \u0001. False when the app
   *  has no widget (not made with --widget). */
  public static boolean set(Context c, String title, String text, String buttons) {
    try {
      java.io.FileOutputStream o = c.openFileOutput(File, 0);
      o.write((title + "\n" + text.replace('\n', ' ') + "\n" + buttons).getBytes("UTF-8"));
      o.close();
    } catch (Throwable t) { }
    return show(c);
  }

  static String[] read(Context c) {
    String[] r = { "", "", "" };
    try {
      java.io.FileInputStream in = c.openFileInput(File);
      byte[] b = new byte[(int) Math.min(in.getChannel().size(), 65536)];
      int n = 0;
      while (n < b.length) {
        int k = in.read(b, n, b.length - n);
        if (k < 0) break;
        n += k;
      }
      in.close();
      String[] p = new String(b, 0, n, "UTF-8").split("\n", 3);
      for (int i = 0; i < p.length && i < 3; i++) r[i] = p[i];
    } catch (Throwable t) { }
    return r;
  }

  static boolean show(Context c) {
    try {
      Resources r = c.getResources();
      String pkg = c.getPackageName();
      int layout = r.getIdentifier("retro_widget", "layout", pkg);
      if (layout == 0) return false;
      AppWidgetManager m = AppWidgetManager.getInstance(c);
      int[] ids = m.getAppWidgetIds(new ComponentName(c, RetroWidget.class));
      if (ids == null || ids.length == 0) return true;
      String[] s = read(c);
      String title = s[0].length() > 0 ? s[0]
          : String.valueOf(c.getApplicationInfo().loadLabel(c.getPackageManager()));
      RemoteViews v = new RemoteViews(pkg, layout);
      v.setTextViewText(r.getIdentifier("title", "id", pkg), title);
      int text = r.getIdentifier("text", "id", pkg);
      v.setTextViewText(text, s[1]);
      v.setViewVisibility(text, s[1].length() > 0 ? View.VISIBLE : View.GONE);
      Intent launch = c.getPackageManager().getLaunchIntentForPackage(pkg);
      if (launch != null) {
        v.setOnClickPendingIntent(r.getIdentifier("box", "id", pkg),
            PendingIntent.getActivity(c, 0, launch, 0x04000000 | 0x08000000));
      }
      String[] bs = s[2].length() > 0 ? s[2].split("\u0001") : new String[0];
      for (int k = 0; k < 2; k++) {
        int b = r.getIdentifier("button" + (k + 1), "id", pkg);
        if (k < bs.length && bs[k].length() > 0 && launch != null) {
          v.setViewVisibility(b, View.VISIBLE);
          v.setTextViewText(b, bs[k]);
          Intent it = new Intent(launch);
          it.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
          it.putExtra(RetroActivity.ActionExtra, "widget\t" + bs[k]);
          v.setOnClickPendingIntent(b, PendingIntent.getActivity(c,
              ("widget\t" + bs[k]).hashCode() & 0x7fffffff, it, 0x04000000 | 0x08000000));
        } else {
          v.setViewVisibility(b, View.GONE);
        }
      }
      m.updateAppWidget(ids, v);
      return true;
    } catch (Throwable t) {
      return false;
    }
  }
}
