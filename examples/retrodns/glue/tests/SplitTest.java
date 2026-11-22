package net.foxoman.retrodns;
import java.net.URL;
public class SplitTest {
  public static void main(String[] a) throws Exception {
    SplitTls.verifier = (h, ss) -> true;      // (the JDK's default verifier says no to all: the engine checks)
    byte[] q = {0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7, 'e','x','a','m','p','l','e', 3, 'c','o','m', 0, 0, 1, 0, 1};
    SplitTls t = SplitTls.open("localhost", "", Integer.parseInt(a[0]), true);
    byte[] r = t.doh(new URL("https://localhost:" + a[0] + "/dns-query"), q);
    byte[] r2 = t.doh(new URL("https://localhost:" + a[0] + "/dns-query"), q);   // the connection kept
    System.out.println("doh answer " + r.length + " " + r2.length + " id " + (r[0] == 0x12 && r[1] == 0x34) + " qr " + ((r[2] & 0x80) != 0));
    t.close();
    SplitTls d = SplitTls.open("localhost", "127.0.0.1", Integer.parseInt(a[1]), true);   // by address, no name
    byte[] r3 = d.dot(q);
    System.out.println("dot by address answer " + r3.length + " id " + (r3[0] == 0x12));
    d.close();
    SplitTls w = SplitTls.open("localhost", "", Integer.parseInt(a[1]), false);   // not split
    System.out.println("dot whole answer " + w.dot(q).length);
    w.close();
  }
}
