package android.app;
public abstract class Service extends android.content.Context {
  public static final int START_STICKY = Integer.parseInt("1");
  public static final int START_NOT_STICKY = Integer.parseInt("2");
  public int onStartCommand(android.content.Intent intent, int flags, int startId) { return 0; }
  public android.os.IBinder onBind(android.content.Intent intent) { return null; }
  public void onDestroy() { }
  public final void stopSelf() { }
}
