package org.retro;

import android.app.Activity;
import android.app.Notification;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.media.MediaMetadata;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.os.Build;
import java.lang.reflect.Constructor;
import java.util.ArrayList;

/** The system's media controls for retro's mediasession module
 *  (src/retroui/mediasession.nim), reached as "session.set", "session.end"
 *  and "session.keys" through RetroActivity.uirelaysCall: a MediaSession
 *  (the lock screen, the quick settings' player, headsets, Bluetooth) with
 *  a media notification, its buttons sent back to the app as lines of
 *  "play", "pause", "toggle", "stop", "next", "previous", "seek\tMS". */
public final class RetroSession {
  private RetroSession() { }

  static MediaSession session;
  static BroadcastReceiver receiver;
  static final ArrayList<String> keys = new ArrayList<String>();
  static final int NOTE_ID = 0x5e55;
  static final String CHANNEL = "retro.media";

  static void add(String k) {
    synchronized (keys) { keys.add(k); }
  }

  public static String call(final Activity a, String what, final String[] args) throws Exception {
    if (what.equals("set")) {
      a.runOnUiThread(new Runnable() {
        public void run() {
          try { set(a, args); } catch (Throwable t) { }
        }
      });
      return "1";
    }
    if (what.equals("end")) {
      a.runOnUiThread(new Runnable() {
        public void run() {
          try { end(a); } catch (Throwable t) { }
        }
      });
      return "1";
    }
    if (what.equals("keys")) {
      synchronized (keys) {
        if (keys.isEmpty()) return "";
        StringBuilder b = new StringBuilder();
        for (String k : keys) b.append(k).append('\n');
        keys.clear();
        return b.toString();
      }
    }
    return null;
  }

  static PendingIntent button(Activity a, String key, int code) {
    Intent i = new Intent(a.getPackageName() + ".RETRO_MEDIA").setPackage(a.getPackageName());
    i.putExtra("key", key);
    int flags = 0x08000000 | 0x04000000;          // FLAG_UPDATE_CURRENT | FLAG_IMMUTABLE
    return PendingIntent.getBroadcast(a, code, i, flags);
  }

  static void start(final Activity a) {
    session = new MediaSession(a, "retro");
    session.setCallback(new MediaSession.Callback() {
      public void onPlay() { add("play"); }
      public void onPause() { add("pause"); }
      public void onStop() { add("stop"); }
      public void onSkipToNext() { add("next"); }
      public void onSkipToPrevious() { add("previous"); }
      public void onSeekTo(long ms) { add("seek\t" + ms); }
    });
    session.setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS | MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS);
    receiver = new BroadcastReceiver() {
      public void onReceive(Context c, Intent i) {
        String k = i.getStringExtra("key");
        if (k != null) add(k);
      }
    };
    IntentFilter f = new IntentFilter(a.getPackageName() + ".RETRO_MEDIA");
    if (Build.VERSION.SDK_INT >= 33) {
      try {
        // registerReceiver(receiver, filter, RECEIVER_NOT_EXPORTED)
        Context.class.getMethod("registerReceiver", BroadcastReceiver.class, IntentFilter.class, int.class)
            .invoke(a, receiver, f, 4);
      } catch (Throwable t) { a.registerReceiver(receiver, f); }
    } else a.registerReceiver(receiver, f);
    if (Build.VERSION.SDK_INT >= 26) {
      try {
        // (a channel for it: NotificationChannel by reflection, API 26)
        Class<?> ch = Class.forName("android.app.NotificationChannel");
        Object channel = ch.getConstructor(String.class, CharSequence.class, int.class)
            .newInstance(CHANNEL, "Media", 2);   // IMPORTANCE_LOW: no sound
        NotificationManager nm = (NotificationManager) a.getSystemService(Context.NOTIFICATION_SERVICE);
        NotificationManager.class.getMethod("createNotificationChannel", ch).invoke(nm, channel);
      } catch (Throwable t) { }
    }
  }

  static void set(Activity a, String[] s) {
    // title, artist, album, art, playing, position, duration, next, previous, seek
    if (session == null) start(a);
    String title = s[0], artist = s[1], album = s[2], art = s[3];
    boolean playing = s[4].equals("1");
    long pos = Long.parseLong(s[5]), dur = Long.parseLong(s[6]);
    boolean next = s[7].equals("1"), prev = s[8].equals("1"), seek = s[9].equals("1");
    MediaMetadata.Builder m = new MediaMetadata.Builder()
        .putString(MediaMetadata.METADATA_KEY_TITLE, title)
        .putString(MediaMetadata.METADATA_KEY_ARTIST, artist)
        .putString(MediaMetadata.METADATA_KEY_ALBUM, album)
        .putLong(MediaMetadata.METADATA_KEY_DURATION, dur);
    Bitmap pic = null;
    if (art.length() > 0) {
      try { pic = BitmapFactory.decodeFile(art); } catch (Throwable t) { }
      if (pic != null) m.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, pic);
    }
    session.setMetadata(m.build());
    long actions = PlaybackState.ACTION_PLAY | PlaybackState.ACTION_PAUSE |
        PlaybackState.ACTION_PLAY_PAUSE | PlaybackState.ACTION_STOP;
    if (next) actions |= PlaybackState.ACTION_SKIP_TO_NEXT;
    if (prev) actions |= PlaybackState.ACTION_SKIP_TO_PREVIOUS;
    if (seek) actions |= PlaybackState.ACTION_SEEK_TO;
    session.setPlaybackState(new PlaybackState.Builder()
        .setActions(actions)
        .setState(playing ? PlaybackState.STATE_PLAYING : PlaybackState.STATE_PAUSED, pos,
                  playing ? 1f : 0f)
        .build());
    session.setActive(true);
    // the notification with the buttons (older Androids show these; newer
    // ones make their player from the session itself)
    Notification.Builder b;
    if (Build.VERSION.SDK_INT >= 26) {
      try {
        Constructor<Notification.Builder> c =
            Notification.Builder.class.getConstructor(Context.class, String.class);
        b = c.newInstance(a, CHANNEL);
      } catch (Throwable t) { b = new Notification.Builder(a); }
    } else b = new Notification.Builder(a);
    b.setSmallIcon(a.getApplicationInfo().icon)
     .setContentTitle(title)
     .setContentText(artist)
     .setOngoing(playing)
     .setShowWhen(false)
     .setVisibility(Notification.VISIBILITY_PUBLIC);
    if (pic != null) b.setLargeIcon(pic);
    Intent open = a.getPackageManager().getLaunchIntentForPackage(a.getPackageName());
    if (open != null) b.setContentIntent(PendingIntent.getActivity(a, 1, open, 0x04000000));
    int n = 0;
    int[] compact = new int[3];
    if (prev) {
      b.addAction(new Notification.Action(android.R.drawable.ic_media_previous, "Previous",
                                          button(a, "previous", 10)));
      compact[n] = n; n++;
    }
    b.addAction(new Notification.Action(
        playing ? android.R.drawable.ic_media_pause : android.R.drawable.ic_media_play,
        playing ? "Pause" : "Play", button(a, "toggle", 11)));
    compact[n] = n; n++;
    if (next) {
      b.addAction(new Notification.Action(android.R.drawable.ic_media_next, "Next",
                                          button(a, "next", 12)));
      compact[n] = n; n++;
    }
    int[] shown = new int[n];
    System.arraycopy(compact, 0, shown, 0, n);
    b.setStyle(new Notification.MediaStyle().setMediaSession(session.getSessionToken())
                                            .setShowActionsInCompactView(shown));
    NotificationManager nm = (NotificationManager) a.getSystemService(Context.NOTIFICATION_SERVICE);
    try { nm.notify(NOTE_ID, b.build()); } catch (Throwable t) { }
  }

  static void end(Activity a) {
    NotificationManager nm = (NotificationManager) a.getSystemService(Context.NOTIFICATION_SERVICE);
    try { nm.cancel(NOTE_ID); } catch (Throwable t) { }
    if (session != null) {
      session.setActive(false);
      session.release();
      session = null;
    }
    if (receiver != null) {
      try { a.unregisterReceiver(receiver); } catch (Throwable t) { }
      receiver = null;
    }
  }
}
