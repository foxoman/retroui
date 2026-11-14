package net.foxoman.retrodns;

import android.app.PendingIntent;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.net.VpnService;
import android.os.Build;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;
import java.io.File;
import java.io.FileInputStream;

/** The quick settings' tile: Retro DNS on and off with a tap, in the VPN's
 *  process (glue/manifest.txt), where the VPN's state is. On: the server
 *  the app last connected to (connect writes it down); when the app never
 *  connected, or Android's consent is still to give, the tap opens the app. */
public final class DnsTile extends TileService {
  static final String LAST = "last-config";

  @Override
  public void onStartListening() { show(); }

  @Override
  public void onClick() {
    if (DnsVpn.state == 1 || DnsVpn.state == 2) {
      DnsVpn v = DnsVpn.current;
      if (v != null) v.end();
      else DnsVpn.state = 0;
    } else {
      String config = read(new File(getFilesDir(), LAST));
      if (config.length() == 0 || VpnService.prepare(this) != null) {
        openApp();
        return;
      }
      try {
        startService(new Intent(this, DnsVpn.class).putExtra(DnsVpn.CONFIG, config));
        DnsVpn.state = 1;
      } catch (Throwable e) {
        openApp();
        return;
      }
    }
    show();
  }

  /** The app, the panel closed (Android 14 wants it as a PendingIntent). */
  void openApp() {
    Intent i = getPackageManager().getLaunchIntentForPackage(getPackageName());
    if (i == null) return;
    i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
    try {
      if (Build.VERSION.SDK_INT >= 34)
        startActivityAndCollapse(PendingIntent.getActivity(this, 0, i, PendingIntent.FLAG_IMMUTABLE));
      else startActivityAndCollapse(i);
    } catch (Throwable e) { }
  }

  void show() {
    Tile t = getQsTile();
    if (t == null) return;
    boolean on = DnsVpn.state == 1 || DnsVpn.state == 2;
    t.setState(on ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
    String name = DnsVpn.serverName;
    t.setLabel(on && name != null && name.length() > 0 ? name : "Retro DNS");
    t.setIcon(DnsVpn.globe());
    t.updateTile();
  }

  /** The tile drawn again (the VPN went on or off): Android asks it soon. */
  static void changed(Context c) {
    try { TileService.requestListeningState(c, new ComponentName(c, DnsTile.class)); }
    catch (Throwable e) { }
    widget(c);
  }

  /** The widget on the home screen (the kit's, retroapk --widget) as the
   *  app shows it: on and the server, or off; a button for the other.
   *  (By reflection: the kit's Java is not in the stubs.) */
  static void widget(Context c) {
    boolean on = DnsVpn.state == 1 || DnsVpn.state == 2;
    String name = DnsVpn.serverName;
    String text = on ? "On: " + (name != null && name.length() > 0 ? name : "a DNS server") : "Off";
    try {
      Class.forName("org.retro.RetroWidget")
          .getMethod("set", Context.class, String.class, String.class, String.class)
          .invoke(null, c, "Retro DNS", text, on ? "Turn off" : "Turn on");
    } catch (Throwable e) { }
  }

  static String read(File f) {
    try {
      FileInputStream in = new FileInputStream(f);
      byte[] b = new byte[(int) Math.min(f.length(), 65536)];
      int n = in.read(b);
      in.close();
      return n > 0 ? new String(b, 0, n, "UTF-8") : "";
    } catch (Throwable e) {
      return "";
    }
  }
}
