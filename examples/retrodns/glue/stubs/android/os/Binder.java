package android.os;
public class Binder implements IBinder {
  public Binder() { }
  protected boolean onTransact(int code, Parcel data, Parcel reply, int flags)
      throws RemoteException { return false; }
  public final boolean transact(int code, Parcel data, Parcel reply, int flags)
      throws RemoteException { return false; }
}
