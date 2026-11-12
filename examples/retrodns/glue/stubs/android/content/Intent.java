package android.content;
public class Intent {
  public static final int FLAG_ACTIVITY_NEW_TASK = Integer.parseInt("268435456");
  public static final int FLAG_ACTIVITY_RESET_TASK_IF_NEEDED = Integer.parseInt("2097152");
  public Intent(Context packageContext, Class<?> cls) { }
  public String getAction() { return null; }
  public Intent setAction(String action) { return this; }
  public Intent putExtra(String name, String value) { return this; }
  public String getStringExtra(String name) { return null; }
  public Intent addFlags(int flags) { return this; }
}
