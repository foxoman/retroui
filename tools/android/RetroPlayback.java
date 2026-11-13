package org.retro;

import android.app.Activity;
import android.app.Notification;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.ComponentName;
import android.os.Build;
import android.os.IBinder;

/** Keeps an app that plays a sound (retroui/media's audioView) running in
 *  the background: a foreground service of the media playback kind, its
 *  notification the media session's (RetroSession: same id, so the
 *  session's buttons show on it once the app sets them). Started when a
 *  sound starts, stopped when none plays. retroapk declares it (and its
 *  permissions) for apps whose code uses audioView. */
public class RetroPlayback extends Service {
  static boolean on;

  static boolean declared(Context c) {
    try {
      c.getPackageManager().getServiceInfo(new ComponentName(c, RetroPlayback.class), 0);
      return true;
    } catch (Throwable t) { return false; }
  }

  static void start(Activity a) {
    if (on || !declared(a)) return;
    on = true;
    try {
      Intent i = new Intent(a, RetroPlayback.class);
      if (Build.VERSION.SDK_INT >= 26)
        Context.class.getMethod("startForegroundService", Intent.class).invoke(a, i);
      else a.startService(i);
    } catch (Throwable t) { on = false; }
  }

  static void stop(Activity a) {
    if (!on) return;
    on = false;
    try { a.stopService(new Intent(a, RetroPlayback.class)); } catch (Throwable t) { }
  }

  @Override public int onStartCommand(Intent intent, int flags, int startId) {
    try {
      Notification n = note(this);
      if (Build.VERSION.SDK_INT >= 29) {
        // FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
        Service.class.getMethod("startForeground", int.class, Notification.class, int.class)
            .invoke(this, RetroSession.NOTE_ID, n, 2);
      } else startForeground(RetroSession.NOTE_ID, n);
    } catch (Throwable t) {
      on = false;
      stopSelf();
    }
    return START_NOT_STICKY;
  }

  /** (a notification for the service until the media session posts its own) */
  static Notification note(Context c) throws Exception {
    Notification.Builder b;
    if (Build.VERSION.SDK_INT >= 26) {
      NotificationManager nm = (NotificationManager) c.getSystemService(Context.NOTIFICATION_SERVICE);
      Class<?> ch = Class.forName("android.app.NotificationChannel");
      Object channel = ch.getConstructor(String.class, CharSequence.class, int.class)
          .newInstance(RetroSession.CHANNEL, "Media", 2);        // IMPORTANCE_LOW
      NotificationManager.class.getMethod("createNotificationChannel", ch).invoke(nm, channel);
      b = (Notification.Builder)
          Notification.Builder.class.getConstructor(Context.class, String.class)
          .newInstance(c, RetroSession.CHANNEL);
    } else b = new Notification.Builder(c);
    CharSequence label = c.getApplicationInfo().loadLabel(c.getPackageManager());
    b.setContentTitle(label).setContentText("Playing")
     .setSmallIcon(c.getApplicationInfo().icon).setOngoing(true);
    Intent open = c.getPackageManager().getLaunchIntentForPackage(c.getPackageName());
    if (open != null)
      b.setContentIntent(PendingIntent.getActivity(c, 0, open, 0x04000000));   // FLAG_IMMUTABLE
    return b.build();
  }

  @Override public void onDestroy() {
    on = false;
    super.onDestroy();
  }

  @Override public IBinder onBind(Intent intent) { return null; }
}
