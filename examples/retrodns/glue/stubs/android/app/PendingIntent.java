package android.app;
public final class PendingIntent {
  public static final int FLAG_IMMUTABLE = Integer.parseInt("67108864");
  public static final int FLAG_UPDATE_CURRENT = Integer.parseInt("134217728");
  public static PendingIntent getActivity(android.content.Context context, int requestCode,
                                          android.content.Intent intent, int flags) { return null; }
  public static PendingIntent getBroadcast(android.content.Context context, int requestCode,
                                           android.content.Intent intent, int flags) { return null; }
}
