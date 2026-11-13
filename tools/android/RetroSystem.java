package org.retro;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.net.ConnectivityManager;
import android.net.NetworkInfo;
import android.os.Bundle;
import android.os.Looper;
import android.speech.tts.TextToSpeech;
import android.view.View;
import java.util.Locale;

/** The system's features that need Java of their own (retroui/system):
 *  speech, the place, sharing text, a tap felt, the network. Called from
 *  Nim through RetroNative (javaStatic "org.retro.RetroSystem"). */
public class RetroSystem {
  // ---- speech ----
  private static TextToSpeech tts;
  private static boolean ttsReady;
  private static String ttsWaiting;
  private static String ttsLang = "";
  private static float ttsRate = 1f;

  public static String speak(final Activity a, final String text, final String lang, final double rate) {
    ttsLang = lang == null ? "" : lang;
    ttsRate = (float) rate;
    if (tts == null) {
      ttsWaiting = text;
      tts = new TextToSpeech(a.getApplicationContext(), new TextToSpeech.OnInitListener() {
        public void onInit(int status) {
          ttsReady = status == TextToSpeech.SUCCESS;
          if (ttsReady && ttsWaiting != null) { say(ttsWaiting); ttsWaiting = null; }
        }
      });
      return "1";
    }
    if (!ttsReady) { ttsWaiting = text; return "1"; }
    return say(text) ? "1" : "0";
  }

  private static boolean say(String text) {
    if (ttsLang.length() > 0) tts.setLanguage(Locale.forLanguageTag(ttsLang));
    tts.setSpeechRate(ttsRate);
    return tts.speak(text, TextToSpeech.QUEUE_ADD, null, "retro") == TextToSpeech.SUCCESS;
  }

  public static String stopSpeaking() {
    if (tts != null) tts.stop();
    ttsWaiting = null;
    return "1";
  }

  public static String speaking() {
    return (tts != null && (tts.isSpeaking() || ttsWaiting != null)) ? "1" : "0";
  }

  // ---- the place ----
  private static volatile String place = "";
  private static LocationListener listener;

  /** "waiting", "ok LAT LON ACCURACY", "denied" or "none"; asks for the
   *  permission once (the APK needs --permission:ACCESS_FINE_LOCATION or
   *  ACCESS_COARSE_LOCATION). */
  public static String location(final Activity a, final boolean fine) {
    final String perm = fine ? "android.permission.ACCESS_FINE_LOCATION" : "android.permission.ACCESS_COARSE_LOCATION";
    if (android.os.Build.VERSION.SDK_INT >= 23 &&
        a.checkSelfPermission(perm) != PackageManager.PERMISSION_GRANTED) {
      if (place.equals("asked")) return "waiting";
      if (place.equals("denied")) return "denied";
      place = "asked";
      a.runOnUiThread(new Runnable() { public void run() {
        a.requestPermissions(new String[] { perm }, 7311);
      }});
      return "waiting";
    }
    if (listener == null) {
      final LocationManager lm = (LocationManager) a.getSystemService(Context.LOCATION_SERVICE);
      if (lm == null) return "none";
      listener = new LocationListener() {
        public void onLocationChanged(Location l) {
          place = "ok " + l.getLatitude() + " " + l.getLongitude() + " " + Math.round(l.getAccuracy());
        }
        public void onStatusChanged(String p, int s, Bundle b) {}
        public void onProviderEnabled(String p) {}
        public void onProviderDisabled(String p) {}
      };
      try {
        for (String prov : new String[] { "network", "gps", "passive" }) {
          if (!lm.getAllProviders().contains(prov)) continue;
          if (prov.equals("gps") && !fine) continue;
          Location last = lm.getLastKnownLocation(prov);
          if (last != null && place.indexOf("ok ") != 0) listener.onLocationChanged(last);
          lm.requestLocationUpdates(prov, 5000, 10, listener, Looper.getMainLooper());
        }
      } catch (SecurityException e) {
        place = "denied";
      }
      if (place.equals("asked") || place.length() == 0) place = "waiting";
    }
    return place.length() == 0 || place.equals("asked") ? "waiting" : place;
  }

  public static String stopLocation(Activity a) {
    if (listener != null) {
      LocationManager lm = (LocationManager) a.getSystemService(Context.LOCATION_SERVICE);
      if (lm != null) lm.removeUpdates(listener);
      listener = null;
    }
    if (place.indexOf("ok ") != 0) place = "";
    return "1";
  }

  /** The user's answer to the place's permission (RetroActivity passes it on). */
  public static void permissionAnswer(int code, boolean granted) {
    if (code == 7311) place = granted ? "" : "denied";
  }

  // ---- sharing ----
  public static String shareText(final Activity a, final String title, final String text) {
    a.runOnUiThread(new Runnable() { public void run() {
      Intent i = new Intent(Intent.ACTION_SEND);
      i.setType("text/plain");
      i.putExtra(Intent.EXTRA_TEXT, text);
      if (title.length() > 0) i.putExtra(Intent.EXTRA_SUBJECT, title);
      a.startActivity(Intent.createChooser(i, title.length() > 0 ? title : null));
    }});
    return "1";
  }

  // ---- a tap felt ----
  /** 0 a tap, 1 a heavier one, 2 success, 3 warning, 4 error, 5 a selection. */
  public static String haptic(final Activity a, final int kind) {
    a.runOnUiThread(new Runnable() { public void run() {
      View v = a.getWindow().getDecorView();
      int c;
      switch (kind) {
        case 1: c = 0; break;                                        // LONG_PRESS
        case 2: c = android.os.Build.VERSION.SDK_INT >= 30 ? 16 : 1; break;  // CONFIRM
        case 3: case 4: c = android.os.Build.VERSION.SDK_INT >= 30 ? 17 : 0; break;  // REJECT
        case 5: c = 4; break;                                        // CLOCK_TICK
        default: c = 1;                                              // VIRTUAL_KEY
      }
      v.performHapticFeedback(c, 2);   // FLAG_IGNORE_GLOBAL_SETTING
    }});
    return "1";
  }

  // ---- the network, the language ----
  public static String online(Activity a) {
    ConnectivityManager cm = (ConnectivityManager) a.getSystemService(Context.CONNECTIVITY_SERVICE);
    if (cm == null) return "1";
    try {
      NetworkInfo n = cm.getActiveNetworkInfo();
      return n != null && n.isConnected() ? "1" : "0";
    } catch (SecurityException e) {
      return "1";
    }
  }

  /** The network costs by what is used (mobile data, a hotspot): "1". */
  public static String metered(Activity a) {
    ConnectivityManager cm = (ConnectivityManager) a.getSystemService(Context.CONNECTIVITY_SERVICE);
    if (cm == null) return "0";
    try { return cm.isActiveNetworkMetered() ? "1" : "0"; }
    catch (SecurityException e) { return "0"; }
  }

  /** Less movement, high contrast, the text's scale: "1 0 1.15". */
  public static String prefs(Activity a) {
    float anim = 1f;
    int contrast = 0;
    try { anim = android.provider.Settings.Global.getFloat(a.getContentResolver(), "animator_duration_scale", 1f); }
    catch (Throwable t) { }
    try { contrast = android.provider.Settings.Secure.getInt(a.getContentResolver(), "high_text_contrast_enabled", 0); }
    catch (Throwable t) { }
    float scale = a.getResources().getConfiguration().fontScale;
    return (anim == 0f ? "1" : "0") + " " + (contrast != 0 ? "1" : "0") + " " + scale;
  }

  public static String language() {
    return Locale.getDefault().toLanguageTag();
  }
}
