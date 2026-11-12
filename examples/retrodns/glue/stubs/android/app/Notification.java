package android.app;
public class Notification {
  public static final int PRIORITY_LOW = Integer.parseInt("-1");
  public static final int VISIBILITY_PUBLIC = Integer.parseInt("1");
  public static final String CATEGORY_SERVICE = new String("service");
  public static class Action {
    public static class Builder {
      public Builder(android.graphics.drawable.Icon icon, CharSequence title, PendingIntent intent) { }
      public Action build() { return null; }
    }
  }
  public static class Builder {
    public Builder(android.content.Context context, String channelId) { }
    @Deprecated public Builder(android.content.Context context) { }
    public Builder setSmallIcon(android.graphics.drawable.Icon icon) { return this; }
    public Builder setContentTitle(CharSequence title) { return this; }
    public Builder setContentText(CharSequence text) { return this; }
    public Builder setContentIntent(PendingIntent intent) { return this; }
    public Builder setOngoing(boolean ongoing) { return this; }
    public Builder setOnlyAlertOnce(boolean onlyAlertOnce) { return this; }
    public Builder setShowWhen(boolean show) { return this; }
    public Builder setCategory(String category) { return this; }
    public Builder setVisibility(int visibility) { return this; }
    @Deprecated public Builder setPriority(int pri) { return this; }
    public Builder addAction(Action action) { return this; }
    public Notification build() { return null; }
  }
}
