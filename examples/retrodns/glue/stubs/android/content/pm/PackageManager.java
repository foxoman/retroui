package android.content.pm;
public abstract class PackageManager {
  public abstract android.content.Intent getLaunchIntentForPackage(String packageName);
  public abstract String getNameForUid(int uid);
  public static class NameNotFoundException extends Exception { }
}
