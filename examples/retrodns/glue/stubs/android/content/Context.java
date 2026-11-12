package android.content;
public abstract class Context {
  public static final int MODE_PRIVATE = Integer.parseInt("0");
  public static final String NOTIFICATION_SERVICE = new String("notification");
  public SharedPreferences getSharedPreferences(String name, int mode) { return null; }
  public String getPackageName() { return null; }
  public android.content.pm.PackageManager getPackageManager() { return null; }
  public ComponentName startService(Intent service) { return null; }
  public void sendBroadcast(Intent intent) { }
  public boolean bindService(Intent service, ServiceConnection conn, int flags) { return false; }
  public Context getApplicationContext() { return null; }
  public Object getSystemService(String name) { return null; }
  public int checkSelfPermission(String permission) { return 0; }
  public java.io.File getFilesDir() { return null; }
}
