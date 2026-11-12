package android.net;
public class VpnService extends android.app.Service {
  public static final String SERVICE_INTERFACE = new String("android.net.VpnService");
  public android.os.IBinder onBind(android.content.Intent intent) { return null; }
  public static android.content.Intent prepare(android.content.Context context) { return null; }
  public boolean protect(java.net.DatagramSocket socket) { return true; }
  public void onRevoke() { }
  public class Builder {
    public Builder() { }
    public Builder setSession(String session) { return this; }
    public Builder addAddress(String address, int prefixLength) { return this; }
    public Builder addDnsServer(String address) { return this; }
    public Builder addRoute(String address, int prefixLength) { return this; }
    public Builder setMtu(int mtu) { return this; }
    public Builder allowFamily(int family) { return this; }
    public Builder addDisallowedApplication(String packageName)
        throws android.content.pm.PackageManager.NameNotFoundException { return this; }
    public Builder setMetered(boolean isMetered) { return this; }
    public Builder setConfigureIntent(android.app.PendingIntent intent) { return this; }
    public android.os.ParcelFileDescriptor establish() { return null; }
  }
}
