package android.service.quicksettings;
public final class Tile {
  public static final int STATE_INACTIVE = Integer.parseInt("1");
  public static final int STATE_ACTIVE = Integer.parseInt("2");
  public void setState(int state) { }
  public void setLabel(CharSequence label) { }
  public void setIcon(android.graphics.drawable.Icon icon) { }
  public void updateTile() { }
}
