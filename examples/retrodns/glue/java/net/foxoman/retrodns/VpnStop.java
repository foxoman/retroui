package net.foxoman.retrodns;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Disconnect, from the notification or the app: runs in the VPN's process
 *  (glue/manifest.txt), where the VPN is. */
public final class VpnStop extends BroadcastReceiver {
  @Override
  public void onReceive(Context context, Intent intent) {
    DnsVpn v = DnsVpn.current;
    if (v != null) v.end();
    else DnsVpn.state = 0;
  }
}
