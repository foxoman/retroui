package net.foxoman.retrodns;
import java.util.ArrayList;
public class VpnLogicTest {
  static void check(boolean ok, String what) { if (!ok) { System.out.println("FAIL " + what); System.exit(1); } }
  public static void main(String[] a) throws Exception {
    String cfg = "name=One\nmode=doh\ndoh=https://one.example/dns-query\nip=1.1.1.1\n---\nname=Two\nmode=dot\ndot=two.example\n---\n" +
                 "name=Bad\nmode=doh\ndoh=nope\n\nblock=ads.example.com\nblock=tracker.net.\nblock=!good.ads.example.com\nblock=\nblock=!\n";
    DnsVpn.Upstream u = DnsVpn.Upstream.parse(cfg);
    check(u.name.equals("One") && u.ip.equals("1.1.1.1") && u.doh.startsWith("https://one"), "the first server");
    ArrayList<DnsVpn.Upstream> all = DnsVpn.Upstream.all(cfg);
    check(all.size() == 2 && all.get(1).name.equals("Two") && all.get(1).mode.equals("dot"), "the ones to go on to (the unusable left out): " + all.size());
    DnsVpn.blockList(cfg);
    check(DnsVpn.isBlocked("ads.example.com") && DnsVpn.isBlocked("x.ads.example.com") && DnsVpn.isBlocked("TRACKER.net"), "blocked, and below it");
    check(!DnsVpn.isBlocked("good.ads.example.com") && !DnsVpn.isBlocked("a.good.ads.example.com"), "the exception wins, nearer");
    check(!DnsVpn.isBlocked("example.com") && !DnsVpn.isBlocked("notads.example.com"), "not its parents or neighbours");
    byte[] q = {0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 3, 'a','d','s', 7, 'e','x','a','m','p','l','e', 3, 'c','o','m', 0, 0, 1, 0, 1};
    check(DnsVpn.qname(q).equals("ads.example.com"), "the name asked: " + DnsVpn.qname(q));
    byte[] nx = DnsVpn.noSuchName(q);
    check(nx != null && (nx[2] & 0x80) != 0 && (nx[3] & 15) == 3 && nx[0] == 0x12 && nx.length == q.length, "no such name");
    check((DnsVpn.serverFailure(q)[3] & 15) == 2, "server failure still");
    check(DnsVpn.cutInHello(new javax.net.ssl.SSLException("Connection reset by peer")), "a reset in the hello: cut");
    check(DnsVpn.cutInHello(new java.net.SocketTimeoutException("Read timed out")), "a timeout: cut");
    check(!DnsVpn.cutInHello(new java.net.ConnectException("refused")), "refused: not cut");
    check(!DnsVpn.cutInHello(new javax.net.ssl.SSLHandshakeException("java.security.cert.CertPathValidatorException: Trust anchor for certification path not found.")), "a certificate: not cut");
    check(!DnsVpn.cutInHello(new java.io.IOException("the server answered HTTP 403")), "an HTTP answer: not cut");
    check(DnsVpn.reasonOf(new java.net.SocketTimeoutException("x")).contains("timed out"), "reason: timed out");
    check(DnsVpn.reasonOf(new javax.net.ssl.SSLException("Connection reset")).contains("block it by name"), "reason: cut");
    System.out.println("vpn logic ok");
  }
}
