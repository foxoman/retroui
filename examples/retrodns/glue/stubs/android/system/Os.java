package android.system;
public final class Os {
  public static int poll(StructPollfd[] fds, int timeoutMs) throws ErrnoException { return 0; }
  public static int read(java.io.FileDescriptor fd, byte[] bytes, int byteOffset, int byteCount)
      throws ErrnoException, java.io.InterruptedIOException { return 0; }
  public static int write(java.io.FileDescriptor fd, byte[] bytes, int byteOffset, int byteCount)
      throws ErrnoException, java.io.InterruptedIOException { return 0; }
}
