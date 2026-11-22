package net.foxoman.retrodns;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URL;
import java.nio.ByteBuffer;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLEngine;
import javax.net.ssl.SSLEngineResult;
import javax.net.ssl.SSLException;

/** A TLS connection to a DNS server that gets past a network reading the
 *  server's name: its first packet -- the TLS hello, with the name in it --
 *  sent in small pieces, so no one piece holds the whole name (as
 *  GreenTunnel splits it); or, where the server's certificate is for its
 *  address too (1.1.1.1, 8.8.8.8, 9.9.9.9), no name sent at all.
 *
 *  Only Retro DNS's own queries go this way, and only when the usual
 *  connection was cut while it said hello (DnsVpn.resolve). The TLS itself
 *  is the system's (an SSLEngine): the certificate is checked as always.
 *
 *  Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net */
final class SplitTls {
  static final int PIECE = 40;           // bytes in each piece of the hello
  /** The certificate's name checked once more after the handshake (Android's own check; the
   *  engine checks it during the handshake too). */
  static javax.net.ssl.HostnameVerifier verifier = HttpsURLConnection.getDefaultHostnameVerifier();
  final Socket raw;
  final SSLEngine eng;
  final InputStream in;
  final OutputStream out;
  ByteBuffer netIn, netOut, appIn;
  boolean first = true;
  final boolean split;

  private SplitTls(Socket raw, SSLEngine eng, boolean split) throws IOException {
    this.raw = raw;
    this.eng = eng;
    this.split = split;
    in = raw.getInputStream();
    out = raw.getOutputStream();
    int pkt = eng.getSession().getPacketBufferSize();
    int app = eng.getSession().getApplicationBufferSize();
    netIn = ByteBuffer.allocate(pkt * 2);
    netOut = ByteBuffer.allocate(pkt * 2);
    appIn = ByteBuffer.allocate(app * 2);
  }

  /** A TLS connection to `host` (`port`): at `ip` with no name sent when `ip`
   *  is given (the certificate checked for the address), else by name; its
   *  hello in pieces when `split`. */
  static SplitTls open(String host, String ip, int port, boolean split) throws IOException {
    boolean byIp = ip != null && ip.length() > 0;
    String peer = byIp ? ip : host;
    Socket raw = new Socket();
    raw.setTcpNoDelay(true);
    raw.connect(new InetSocketAddress(peer, port), 5000);
    raw.setSoTimeout(5000);
    SSLEngine e;
    try {
      e = SSLContext.getDefault().createSSLEngine(peer, port);   // (an address: no name in the hello)
    } catch (Exception x) {
      raw.close();
      throw new IOException("TLS is not available: " + x);
    }
    e.setUseClientMode(true);
    // (the certificate checked for the name -- or the address -- during the handshake)
    javax.net.ssl.SSLParameters sp = e.getSSLParameters();
    sp.setEndpointIdentificationAlgorithm("HTTPS");
    e.setSSLParameters(sp);
    SplitTls t = new SplitTls(raw, e, split);
    try {
      t.handshake();
      if (!verifier.verify(peer, e.getSession()))
        throw new SSLException("the server's certificate is not for " + peer);
    } catch (IOException x) {
      t.close();
      throw x;
    }
    return t;
  }

  private void send(ByteBuffer b) throws IOException {
    byte[] a = new byte[b.remaining()];
    b.get(a);
    if (first && split && a.length > PIECE) {
      // the hello in pieces, each its own packet (no delay merges them)
      for (int i = 0; i < a.length; i += PIECE) {
        out.write(a, i, Math.min(PIECE, a.length - i));
        out.flush();
        try { Thread.sleep(1); } catch (InterruptedException x) { }
      }
    } else {
      out.write(a);
      out.flush();
    }
    first = false;
  }

  private void fill() throws IOException {
    if (!netIn.hasRemaining()) {
      ByteBuffer bigger = ByteBuffer.allocate(netIn.capacity() * 2);
      netIn.flip();
      bigger.put(netIn);
      netIn = bigger;
    }
    int n = in.read(netIn.array(), netIn.arrayOffset() + netIn.position(), netIn.remaining());
    if (n < 0) throw new SSLException("the server closed the connection");
    netIn.position(netIn.position() + n);
  }

  private void handshake() throws IOException {
    eng.beginHandshake();
    SSLEngineResult.HandshakeStatus hs = eng.getHandshakeStatus();
    ByteBuffer none = ByteBuffer.allocate(0);
    while (hs != SSLEngineResult.HandshakeStatus.FINISHED &&
           hs != SSLEngineResult.HandshakeStatus.NOT_HANDSHAKING) {
      switch (hs) {
        case NEED_WRAP: {
          netOut.clear();
          SSLEngineResult r = eng.wrap(none, netOut);
          netOut.flip();
          if (netOut.hasRemaining()) send(netOut);
          hs = r.getHandshakeStatus();
          break;
        }
        case NEED_TASK: {
          Runnable task;
          while ((task = eng.getDelegatedTask()) != null) task.run();
          hs = eng.getHandshakeStatus();
          break;
        }
        default: {                                     // NEED_UNWRAP (and _AGAIN)
          netIn.flip();
          SSLEngineResult r = eng.unwrap(netIn, appIn);
          netIn.compact();
          if (r.getStatus() == SSLEngineResult.Status.BUFFER_UNDERFLOW) fill();
          else if (r.getStatus() == SSLEngineResult.Status.CLOSED)
            throw new SSLException("the server closed the connection");
          hs = r.getHandshakeStatus();
          break;
        }
      }
    }
  }

  void write(byte[] data) throws IOException {
    ByteBuffer src = ByteBuffer.wrap(data);
    while (src.hasRemaining()) {
      netOut.clear();
      SSLEngineResult r = eng.wrap(src, netOut);
      if (r.getStatus() != SSLEngineResult.Status.OK) throw new SSLException("TLS: " + r.getStatus());
      netOut.flip();
      send(netOut);
    }
  }

  /** `n` bytes of what the server sent. */
  byte[] read(int n) throws IOException {
    byte[] b = new byte[n];
    int got = 0;
    while (got < n) {
      appIn.flip();
      int k = Math.min(appIn.remaining(), n - got);
      appIn.get(b, got, k);
      appIn.compact();
      got += k;
      if (got >= n) break;
      netIn.flip();
      SSLEngineResult r = eng.unwrap(netIn, appIn);
      netIn.compact();
      if (r.getStatus() == SSLEngineResult.Status.BUFFER_UNDERFLOW) fill();
      else if (r.getStatus() == SSLEngineResult.Status.CLOSED)
        throw new SSLException("the server closed the connection");
      else if (r.getStatus() == SSLEngineResult.Status.BUFFER_OVERFLOW) {
        ByteBuffer bigger = ByteBuffer.allocate(appIn.capacity() * 2);
        appIn.flip();
        bigger.put(appIn);
        appIn = bigger;
      }
    }
    return b;
  }

  /** A line of the server's HTTP answer (its CR LF taken off). */
  String line() throws IOException {
    ByteArrayOutputStream b = new ByteArrayOutputStream();
    while (true) {
      byte c = read(1)[0];
      if (c == '\n') break;
      if (c != '\r') b.write(c);
      if (b.size() > 8192) throw new IOException("an answer line too long");
    }
    return b.toString("ISO-8859-1");
  }

  /** One DNS over TLS query: two bytes of length, the message; the answer. */
  byte[] dot(byte[] q) throws IOException {
    byte[] m = new byte[q.length + 2];
    m[0] = (byte) (q.length >> 8);
    m[1] = (byte) q.length;
    System.arraycopy(q, 0, m, 2, q.length);
    write(m);
    byte[] len = read(2);
    byte[] r = read(((len[0] & 255) << 8) | (len[1] & 255));
    if (r.length < 12 || r[0] != q[0] || r[1] != q[1]) throw new IOException("an answer to another query");
    return r;
  }

  /** One DNS over HTTPS query (HTTP/1.1 POST, the connection kept): the answer. */
  byte[] doh(URL url, byte[] q) throws IOException {
    String path = url.getFile().length() > 0 ? url.getFile() : "/dns-query";
    String head = "POST " + path + " HTTP/1.1\r\nHost: " + url.getHost() +
        "\r\nContent-Type: application/dns-message\r\nAccept: application/dns-message\r\n" +
        "Content-Length: " + q.length + "\r\nConnection: keep-alive\r\n\r\n";
    byte[] h = head.getBytes("ISO-8859-1");
    byte[] all = new byte[h.length + q.length];
    System.arraycopy(h, 0, all, 0, h.length);
    System.arraycopy(q, 0, all, h.length, q.length);
    write(all);
    String status = line();
    String[] st = status.split(" ");
    int code = st.length > 1 ? Integer.parseInt(st[1].trim()) : 0;
    int length = -1;
    boolean chunked = false;
    for (String l = line(); l.length() > 0; l = line()) {
      String low = l.toLowerCase();
      if (low.startsWith("content-length:")) length = Integer.parseInt(l.substring(15).trim());
      else if (low.startsWith("transfer-encoding:") && low.contains("chunked")) chunked = true;
    }
    byte[] body;
    if (chunked) {
      ByteArrayOutputStream b = new ByteArrayOutputStream();
      while (true) {
        String size = line();
        int semi = size.indexOf(';');
        int n = Integer.parseInt((semi >= 0 ? size.substring(0, semi) : size).trim(), 16);
        if (n == 0) {
          line();
          break;
        }
        b.write(read(n));
        line();
      }
      body = b.toByteArray();
    } else if (length >= 0) body = read(length);
    else throw new IOException("an answer of no length");
    if (code != 200) throw new IOException("the server answered HTTP " + code);
    if (body.length < 12) throw new IOException("a short answer");
    return body;
  }

  void close() {
    try { raw.close(); } catch (IOException e) { }
  }

  boolean closed() { return raw.isClosed(); }
}
