package net.foxoman.retrodns;

import android.app.Activity;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.drawable.Icon;
import android.net.VpnService;
import android.os.Binder;
import android.os.Build;
import android.os.Debug;
import android.os.IBinder;
import android.os.Looper;
import android.os.Parcel;
import android.os.ParcelFileDescriptor;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructPollfd;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InterruptedIOException;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URL;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;

/** Retro DNS's VPN: it stays on the device and carries DNS only.
 *
 *  The tunnel has one address of its own for DNS, and only that address is
 *  routed into it. Every query that comes in goes to the server the user
 *  chose, encrypted -- DNS over HTTPS or DNS over TLS -- and the answer goes
 *  back through the tunnel. Nothing else passes through the
 *  VPN, and no query is written down: only counts.
 *
 *  The app itself is left out of the VPN, so its own connections (the
 *  queries it forwards, its tests) go out on the network as before.
 *
 *  It runs in a process of its own (":vpn", glue/manifest.txt): Java only,
 *  small, and the one that stays while the VPN is on. The app's window, with
 *  its graphics and its Nim code, can then go when the user leaves it.
 *  While the VPN is on, a notification says so, with Open and Disconnect.
 *
 *  The app's Nim code calls the static methods by reflection
 *  (retroui/native), in the app's own process: connect, disconnect, status,
 *  prepared. They reach the VPN's process with intents, a broadcast
 *  (VpnStop) and a Binder that answers status. retroapk puts these classes
 *  (glue/classes.dex) and their manifest entries (glue/manifest.txt) in the
 *  APK or bundle: --java:examples/retrodns/glue. */
public final class DnsVpn extends VpnService implements Runnable {
  static final String PREFS = "retrodns.vpn";          // the VPN process's
  static final String UI_PREFS = "retrodns.ui";        // the app process's
  static final String STOP = "net.foxoman.retrodns.STOP";
  static final String CONFIG = "config";
  static final String ERROR_FILE = "vpn-error";       // why it last failed to start
  static final String TUN_ADDRESS = "10.111.222.1";
  static final String DNS_ADDRESS = "10.111.222.53";   // what the apps ask
  static final String CHANNEL = "vpn";
  static final int NOTICE = 1;
  static final int ASK = 0x5d01;                       // (the consent dialog's request)
  static final int ASK_NOTICES = 0x5d02;               // (the notification permission's)
  static final int STATUS = 1;                         // (the Binder's one call)

  // ---- the VPN's process: what status() reports ----
  static volatile DnsVpn current;
  static volatile int state;            // 0 off, 1 starting, 2 on, 3 failed
  static volatile String error = "";
  static volatile String serverName = "";
  static volatile String modeLabel = "";
  static volatile String lastFailure = "";
  static final AtomicLong answered = new AtomicLong();
  static final AtomicLong failed = new AtomicLong();
  static final AtomicLong msTotal = new AtomicLong();
  static long pssKb, pssAt;

  private volatile Upstream upstream;
  private volatile ParcelFileDescriptor tun;
  private volatile boolean stopping;
  private Thread reader;
  private ThreadPoolExecutor workers;
  private final Object writeLock = new Object();
  private Notification.Builder notice;
  private long noticeAt, noticeCount = -1;

  // ---- the app's process: how it sees the VPN's ----
  static volatile int consent;          // 0 not asked, 1 asking
  static volatile String uiError = "";
  static volatile long startAt, stopAt;
  static volatile String lastName = "";
  static volatile IBinder remote;
  static boolean bound, waited;

  // ---- the server: where queries go, and how ----

  static final class Upstream {
    String name = "";
    String mode = "doh";                  // doh, dot
    String doh = "";                      // https://host/dns-query
    String dot = "";                      // host name for port 853

    /** "key=value" lines: name, mode, doh, dot. */
    static Upstream parse(String text) {
      Upstream u = new Upstream();
      if (text == null) return u;
      for (String line : text.split("\n")) {
        int eq = line.indexOf('=');
        if (eq <= 0) continue;
        String k = line.substring(0, eq).trim();
        String v = line.substring(eq + 1).trim();
        if (k.equals("name")) u.name = v;
        else if (k.equals("mode")) u.mode = v;
        else if (k.equals("doh")) {
          int t = v.indexOf('{');                  // (a template's {?dns})
          u.doh = t >= 0 ? v.substring(0, t) : v;
        }
        else if (k.equals("dot")) u.dot = v;
      }
      return u;
    }

    /** "" when it can be used, else why not. */
    String problem() {
      if (mode.equals("doh"))
        return doh.startsWith("https://") ? "" : "no DNS over HTTPS address (https://...)";
      if (mode.equals("dot")) return dot.length() > 0 ? "" : "no DNS over TLS host";
      return "no encrypted DNS (DNS over HTTPS or TLS)";
    }

    String label() { return mode.equals("dot") ? "DNS over TLS" : "DNS over HTTPS"; }
  }

  /** The answer to `q` (a DNS message) from the server `u` names. */
  static byte[] resolve(Upstream u, byte[] q) throws IOException {
    return u.mode.equals("dot") ? viaTls(u.dot, q) : viaHttps(u.doh, q);
  }

  static byte[] viaHttps(String url, byte[] q) throws IOException {
    HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
    c.setConnectTimeout(5000);
    c.setReadTimeout(5000);
    c.setDoOutput(true);
    c.setRequestMethod("POST");
    c.setRequestProperty("Content-Type", "application/dns-message");
    c.setRequestProperty("Accept", "application/dns-message");
    c.setFixedLengthStreamingMode(q.length);
    OutputStream out = c.getOutputStream();
    out.write(q);
    out.close();
    int code = c.getResponseCode();
    if (code != 200) {
      c.disconnect();
      throw new IOException("the server answered HTTP " + code);
    }
    InputStream in = c.getInputStream();
    ByteArrayOutputStream b = new ByteArrayOutputStream();
    byte[] buf = new byte[4096];
    int n;
    while ((n = in.read(buf)) > 0) b.write(buf, 0, n);
    in.close();          // (the connection stays open for the next query)
    byte[] r = b.toByteArray();
    if (r.length < 12) throw new IOException("a short answer");
    return r;
  }

  // DNS over TLS: a few open connections a server, used again
  static final HashMap<String, ArrayDeque<SSLSocket>> tlsPool =
      new HashMap<String, ArrayDeque<SSLSocket>>();

  static SSLSocket tlsOpen(String host) throws IOException {
    synchronized (tlsPool) {
      ArrayDeque<SSLSocket> d = tlsPool.get(host);
      while (d != null && !d.isEmpty()) {
        SSLSocket s = d.pollFirst();
        if (!s.isClosed()) return s;
      }
    }
    Socket raw = new Socket();
    raw.connect(new InetSocketAddress(host, 853), 5000);
    SSLSocketFactory f = (SSLSocketFactory) SSLSocketFactory.getDefault();
    SSLSocket s = (SSLSocket) f.createSocket(raw, host, 853, true);
    s.setSoTimeout(5000);
    s.startHandshake();
    if (!HttpsURLConnection.getDefaultHostnameVerifier().verify(host, s.getSession())) {
      s.close();
      throw new IOException("the server's certificate is not for " + host);
    }
    return s;
  }

  static void tlsKeep(String host, SSLSocket s) {
    synchronized (tlsPool) {
      ArrayDeque<SSLSocket> d = tlsPool.get(host);
      if (d == null) {
        d = new ArrayDeque<SSLSocket>();
        tlsPool.put(host, d);
      }
      if (d.size() < 4) {
        d.addLast(s);
        return;
      }
    }
    try { s.close(); } catch (IOException e) { }
  }

  static void tlsForget(String host) {
    ArrayList<SSLSocket> old = new ArrayList<SSLSocket>();
    synchronized (tlsPool) {
      if (host == null) {
        for (ArrayDeque<SSLSocket> d : tlsPool.values()) old.addAll(d);
        tlsPool.clear();
      } else {
        ArrayDeque<SSLSocket> d = tlsPool.remove(host);
        if (d != null) old.addAll(d);
      }
    }
    for (SSLSocket s : old) {
      try { s.close(); } catch (IOException e) { }
    }
  }

  static byte[] viaTls(String host, byte[] q) throws IOException {
    IOException last = null;
    for (int attempt = 0; attempt < 2; attempt++) {
      SSLSocket s = tlsOpen(host);
      try {
        byte[] r = exchange(s.getInputStream(), s.getOutputStream(), q);
        tlsKeep(host, s);
        return r;
      } catch (IOException e) {
        // (a kept connection the server closed meanwhile: a new one)
        last = e;
        try { s.close(); } catch (IOException x) { }
        tlsForget(host);
      }
    }
    throw last;
  }

  /** One query over a stream (TCP, TLS): two bytes of length, then the message. */
  static byte[] exchange(InputStream in, OutputStream out, byte[] q) throws IOException {
    byte[] m = new byte[q.length + 2];
    m[0] = (byte) (q.length >> 8);
    m[1] = (byte) q.length;
    System.arraycopy(q, 0, m, 2, q.length);
    out.write(m);
    out.flush();
    byte[] len = readFully(in, 2);
    byte[] r = readFully(in, ((len[0] & 255) << 8) | (len[1] & 255));
    if (r.length < 12 || r[0] != q[0] || r[1] != q[1])
      throw new IOException("an answer to another query");
    return r;
  }

  static byte[] readFully(InputStream in, int n) throws IOException {
    byte[] b = new byte[n];
    int got = 0;
    while (got < n) {
      int k = in.read(b, got, n - got);
      if (k < 0) throw new IOException("the server closed the connection");
      got += k;
    }
    return b;
  }

  /** "Server failure" for `q`: the app asking hears at once, and tries again. */
  static byte[] serverFailure(byte[] q) {
    if (q.length < 12) return null;
    int i = 12;
    while (i < q.length && q[i] != 0) {
      int l = q[i] & 255;
      if (l >= 0xc0) return null;
      i += l + 1;
    }
    i += 5;                                  // the 0, the type, the class
    if (i > q.length) return null;
    byte[] r = Arrays.copyOf(q, i);
    r[2] = (byte) (0x80 | (q[2] & 0x79));    // an answer; the opcode and RD kept
    r[3] = (byte) 0x82;                      // recursion available, SERVFAIL
    r[4] = 0; r[5] = 1;
    for (int k = 6; k < 12; k++) r[k] = 0;
    return r;
  }

  // ---- the tunnel ----

  static int u16(byte[] b, int i) { return ((b[i] & 255) << 8) | (b[i + 1] & 255); }

  static int checksum(byte[] b, int off, int len, long start) {
    long sum = start;
    int i = off, end = off + len;
    for (; i + 1 < end; i += 2) sum += ((b[i] & 255) << 8) | (b[i + 1] & 255);
    if (i < end) sum += (b[i] & 255) << 8;
    while ((sum >> 16) != 0) sum = (sum & 0xffff) + (sum >> 16);
    return (int) (~sum & 0xffff);
  }

  /** An IPv4 UDP packet from `src`:`sport` to `dst`:`dport` carrying `data`. */
  static byte[] udp4(byte[] src, int sport, byte[] dst, int dport, byte[] data) {
    int total = 28 + data.length;
    int ulen = 8 + data.length;
    byte[] p = new byte[total];
    p[0] = 0x45;
    p[2] = (byte) (total >> 8); p[3] = (byte) total;
    p[6] = 0x40;                             // don't fragment
    p[8] = 64;                               // time to live
    p[9] = 17;                               // UDP
    System.arraycopy(src, 0, p, 12, 4);
    System.arraycopy(dst, 0, p, 16, 4);
    int h = checksum(p, 0, 20, 0);
    p[10] = (byte) (h >> 8); p[11] = (byte) h;
    p[20] = (byte) (sport >> 8); p[21] = (byte) sport;
    p[22] = (byte) (dport >> 8); p[23] = (byte) dport;
    p[24] = (byte) (ulen >> 8); p[25] = (byte) ulen;
    System.arraycopy(data, 0, p, 28, data.length);
    long pseudo = u16(src, 0) + u16(src, 2) + u16(dst, 0) + u16(dst, 2) + 17 + ulen;
    int c = checksum(p, 20, ulen, pseudo);
    if (c == 0) c = 0xffff;
    p[26] = (byte) (c >> 8); p[27] = (byte) c;
    return p;
  }

  // ---- the VPN's process ----

  @Override
  public int onStartCommand(Intent intent, int flags, int startId) {
    if (intent != null && STOP.equals(intent.getAction())) {
      end();
      return START_NOT_STICKY;
    }
    // the app's Connect brings the server; Android's always-on VPN or a
    // restart: the server chosen last
    SharedPreferences p = getSharedPreferences(PREFS, MODE_PRIVATE);
    String config = intent != null ? intent.getStringExtra(CONFIG) : null;
    if (config != null) p.edit().putString(CONFIG, config).apply();
    else config = p.getString(CONFIG, "");
    Upstream u = Upstream.parse(config);
    String why = u.problem();
    if (why.length() > 0) {
      fail(why);
      stopSelf();
      return START_NOT_STICKY;
    }
    if (tun != null && !stopping) {
      // another server while connected: the tunnel stays, the queries go there
      use(u);
      tlsForget(null);
      showNotice();
      return START_STICKY;
    }
    begin(u);
    return START_STICKY;
  }

  @Override
  public IBinder onBind(Intent intent) {
    if (intent != null && SERVICE_INTERFACE.equals(intent.getAction())) return super.onBind(intent);
    return new Binder() {                     // the app asking how it goes
      @Override
      protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) {
        if (code != STATUS) return false;
        reply.writeString(localStatus());
        return true;
      }
    };
  }

  private void use(Upstream u) {
    upstream = u;
    serverName = u.name;
    modeLabel = u.label();
    answered.set(0);
    failed.set(0);
    msTotal.set(0);
    lastFailure = "";
    noticeCount = -1;
  }

  private void begin(Upstream u) {
    state = 1;
    error = "";
    use(u);
    Builder b = new Builder();
    b.setSession(u.name.length() > 0 ? u.name : "DNS");
    b.addAddress(TUN_ADDRESS, 24);
    b.addDnsServer(DNS_ADDRESS);
    b.addRoute(DNS_ADDRESS, 32);             // DNS only: nothing else is routed here
    b.setMtu(1500);
    b.allowFamily(OsConstants.AF_INET6);     // (IPv6 goes on as before, not blocked)
    try {
      b.addDisallowedApplication(getPackageName());   // the app's own queries go out
    } catch (PackageManager.NameNotFoundException e) { }
    if (Build.VERSION.SDK_INT >= 29) b.setMetered(false);   // as metered as the network under it
    PendingIntent open = openApp(this);
    if (open != null) b.setConfigureIntent(open);
    ParcelFileDescriptor t;
    try {
      t = b.establish();
    } catch (Throwable e) {
      fail("the VPN could not start: " + e);
      stopSelf();
      return;
    }
    if (t == null) {
      fail("Android has not allowed the VPN: connect again from the app");
      stopSelf();
      return;
    }
    tun = t;
    stopping = false;
    // up to 6 lookups at a time; no thread at all while nothing is asked
    workers = new ThreadPoolExecutor(6, 6, 20, TimeUnit.SECONDS,
                                     new LinkedBlockingQueue<Runnable>(256));
    workers.allowCoreThreadTimeOut(true);
    reader = new Thread(this, "retrodns-tunnel");
    reader.start();
    current = this;
    state = 2;
    new File(getFilesDir(), ERROR_FILE).delete();
    showNotice();
  }

  private void fail(String why) {
    error = why;
    state = 3;
    if (current == this) current = null;
    try {
      FileOutputStream o = new FileOutputStream(new File(getFilesDir(), ERROR_FILE));
      o.write(clean(why).getBytes("UTF-8"));
      o.close();
    } catch (IOException e) { }
  }

  /** Off, from the app, the notification or Settings. */
  void end() {
    shutdown();
    state = 0;
    error = "";
    stopSelf();
  }

  /** Closes the tunnel (DNS goes back to the network's own). */
  private void shutdown() {
    stopping = true;
    hideNotice();
    ThreadPoolExecutor w = workers;
    workers = null;
    if (w != null) w.shutdownNow();
    ParcelFileDescriptor t = tun;
    tun = null;
    if (t != null) {
      try { t.close(); } catch (IOException e) { }
    }
    Thread r = reader;
    reader = null;
    if (r != null && r != Thread.currentThread()) {
      try { r.join(1500); } catch (InterruptedException e) { }
    }
    if (current == this) current = null;
    tlsForget(null);
  }

  @Override
  public void onRevoke() {
    // another VPN took over, or the user turned this one off in Settings
    shutdown();
    state = 0;
    error = "The VPN was turned off in Android's settings, or another VPN started";
    stopSelf();
  }

  @Override
  public void onDestroy() {
    shutdown();
    if (state != 3) state = 0;
    super.onDestroy();
  }

  /** The tunnel's reader: each DNS query to a worker, the rest dropped. */
  public void run() {
    ParcelFileDescriptor t = tun;
    if (t == null) return;
    FileDescriptor fd = t.getFileDescriptor();
    StructPollfd pfd = new StructPollfd();
    pfd.fd = fd;
    pfd.events = (short) OsConstants.POLLIN;
    StructPollfd[] fds = { pfd };
    byte[] buf = new byte[32767];
    while (!stopping) {
      try {
        tickNotice();
        pfd.revents = 0;
        if (Os.poll(fds, 2000) <= 0) continue;
        if ((pfd.revents & OsConstants.POLLIN) == 0) {
          if ((pfd.revents & (OsConstants.POLLERR | OsConstants.POLLHUP | OsConstants.POLLNVAL)) != 0) break;
          continue;
        }
        int n = Os.read(fd, buf, 0, buf.length);
        if (n > 0) packet(buf, n);
      } catch (ErrnoException e) {
        if (e.errno == OsConstants.EINTR || e.errno == OsConstants.EAGAIN) continue;
        break;
      } catch (InterruptedIOException e) {
        if (stopping) break;
      } catch (Throwable e) {
        // (one odd packet does not end the tunnel)
      }
    }
  }

  private void packet(byte[] p, int n) {
    if (n < 28 || ((p[0] >> 4) & 15) != 4) return;           // IPv4
    int ihl = (p[0] & 15) * 4;
    if (ihl < 20 || n < ihl + 8 || (p[9] & 255) != 17) return; // UDP
    if ((p[6] & 0x20) != 0 || (((p[6] & 0x1f) << 8) | (p[7] & 255)) != 0) return; // a fragment
    if (u16(p, ihl + 2) != 53) return;
    int len = Math.min(u16(p, ihl + 4) - 8, n - ihl - 8);
    if (len < 12) return;
    final byte[] q = Arrays.copyOfRange(p, ihl + 8, ihl + 8 + len);
    final byte[] client = Arrays.copyOfRange(p, 12, 16);
    final byte[] us = Arrays.copyOfRange(p, 16, 20);
    final int clientPort = u16(p, ihl);
    final Upstream u = upstream;
    ThreadPoolExecutor w = workers;
    if (u == null || w == null) return;
    try {
      w.execute(new Runnable() {
        public void run() { answer(u, q, client, clientPort, us); }
      });
    } catch (RejectedExecutionException e) { }
  }

  private void answer(Upstream u, byte[] q, byte[] client, int clientPort, byte[] us) {
    long t0 = System.nanoTime();
    byte[] r;
    try {
      r = resolve(u, q);
      answered.incrementAndGet();
      msTotal.addAndGet((System.nanoTime() - t0) / 1000000);
    } catch (Throwable e) {
      failed.incrementAndGet();
      lastFailure = String.valueOf(e.getMessage());
      r = serverFailure(q);
      if (r == null) return;
    }
    ParcelFileDescriptor t = tun;
    if (stopping || t == null) return;
    byte[] pkt = udp4(us, 53, client, clientPort, r);
    synchronized (writeLock) {
      try { Os.write(t.getFileDescriptor(), pkt, 0, pkt.length); } catch (Throwable e) { }
    }
  }

  // ---- the notification ----

  /** Opens the app (from the notification, and Android's VPN settings). */
  static PendingIntent openApp(Context c) {
    Intent i = c.getPackageManager().getLaunchIntentForPackage(c.getPackageName());
    if (i == null) return null;
    i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
    return PendingIntent.getActivity(c, 0, i, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
  }

  /** A small globe, white, as Android wants a notification's icon. */
  static Icon globe() {
    Bitmap b = Bitmap.createBitmap(72, 72, Bitmap.Config.ARGB_8888);
    Canvas c = new Canvas(b);
    Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
    p.setStyle(Paint.Style.STROKE);
    p.setStrokeWidth(6);
    p.setColor(0xffffffff);
    c.drawCircle(36, 36, 31, p);
    c.drawOval(22, 5, 50, 67, p);
    c.drawLine(5, 36, 67, 36, p);
    p.setStrokeWidth(4);
    c.drawLine(11, 21, 61, 21, p);
    c.drawLine(11, 51, 61, 51, p);
    return Icon.createWithBitmap(b);
  }

  @SuppressWarnings("deprecation")
  private void showNotice() {
    try {
      NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
      if (nm == null) return;
      if (notice == null) {
        Notification.Builder n;
        if (Build.VERSION.SDK_INT >= 26) {
          NotificationChannel ch = new NotificationChannel(CHANNEL, "VPN", NotificationManager.IMPORTANCE_LOW);
          ch.setDescription("Shown while Retro DNS's VPN carries your DNS lookups");
          ch.setShowBadge(false);
          nm.createNotificationChannel(ch);
          n = new Notification.Builder(this, CHANNEL);
        } else {
          n = new Notification.Builder(this);
          n.setPriority(Notification.PRIORITY_LOW);
        }
        Icon icon = globe();
        PendingIntent open = openApp(this);
        PendingIntent off = PendingIntent.getBroadcast(this, 1, new Intent(this, VpnStop.class),
            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        n.setSmallIcon(icon).setOngoing(true).setOnlyAlertOnce(true).setShowWhen(false)
         .setCategory(Notification.CATEGORY_SERVICE).setVisibility(Notification.VISIBILITY_PUBLIC);
        if (open != null) {
          n.setContentIntent(open);
          n.addAction(new Notification.Action.Builder(icon, "Open", open).build());
        }
        n.addAction(new Notification.Action.Builder(icon, "Disconnect", off).build());
        notice = n;
      }
      long count = answered.get() + failed.get();
      String text = modeLabel + (count == 1 ? " · 1 lookup" : " · " + count + " lookups");
      if (failed.get() > 0) text += ", " + failed.get() + " failed";
      notice.setContentTitle("VPN on: " + serverName).setContentText(text);
      nm.notify(NOTICE, notice.build());
      noticeAt = System.currentTimeMillis();
      noticeCount = count;
    } catch (Throwable e) {
      // (no notification -- notifications turned off: the VPN still works)
    }
  }

  /** The count on the notification, at most every 10 seconds. */
  private void tickNotice() {
    if (System.currentTimeMillis() - noticeAt < 10000) return;
    if (answered.get() + failed.get() == noticeCount) return;
    showNotice();
  }

  private void hideNotice() {
    try {
      NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
      if (nm != null) nm.cancel(NOTICE);
    } catch (Throwable e) { }
    notice = null;
  }

  /** state, server, mode, answered, failed, average ms (-1 none yet), error,
   *  last failure, this process's memory (kB): tab separated. */
  static String localStatus() {
    long a = answered.get();
    long avg = a > 0 ? msTotal.get() / a : -1;
    long now = System.currentTimeMillis();
    if (now - pssAt > 10000) {
      pssAt = now;
      pssKb = Debug.getPss();
    }
    return state + "\t" + clean(serverName) + "\t" + clean(modeLabel) + "\t" + a + "\t" +
        failed.get() + "\t" + avg + "\t" + clean(error) + "\t" + clean(lastFailure) + "\t" + pssKb;
  }

  // ---- the app's process: for Nim (vpn.nim), by reflection ----

  /** Starts the VPN with `config` ("key=value" lines), or moves it to that
   *  server: "starting", "asking" (Android shows its consent dialog first:
   *  call again when the app is back) or "error\t<why>". */
  public static String connect(Context c, String config) {
    Upstream u = Upstream.parse(config);
    String why = u.problem();
    if (why.length() > 0) {
      uiError = why;
      return "error\t" + why;
    }
    uiError = "";
    lastName = u.name;
    bind(c);
    Intent ask = VpnService.prepare(c);
    if (ask != null) {
      if (!(c instanceof Activity)) return "error\tcannot ask without the app on screen";
      consent = 1;
      try {
        ((Activity) c).startActivityForResult(ask, ASK);
      } catch (Throwable e) {
        consent = 0;
        uiError = e.toString();
        return "error\t" + e;
      }
      return "asking";
    }
    consent = 0;
    askNotices(c);
    new File(c.getFilesDir(), ERROR_FILE).delete();
    try {
      c.startService(new Intent(c, DnsVpn.class).putExtra(CONFIG, config));
    } catch (Throwable e) {
      uiError = e.toString();
      return "error\t" + e;
    }
    startAt = System.currentTimeMillis();
    stopAt = 0;
    return "starting";
  }

  /** Android 13+: may the app show the VPN's notification? Asked once. */
  static void askNotices(Context c) {
    if (Build.VERSION.SDK_INT < 33 || !(c instanceof Activity)) return;
    String perm = "android.permission.POST_NOTIFICATIONS";
    if (c.checkSelfPermission(perm) == 0) return;
    SharedPreferences p = c.getSharedPreferences(UI_PREFS, MODE_PRIVATE);
    if (p.getBoolean("askedNotices", false)) return;
    p.edit().putBoolean("askedNotices", true).apply();
    try {
      ((Activity) c).requestPermissions(new String[] { perm }, ASK_NOTICES);
    } catch (Throwable e) { }
  }

  /** Closes the VPN: DNS goes back to the network's own. */
  public static void disconnect(Context c) {
    consent = 0;
    uiError = "";
    startAt = 0;
    stopAt = System.currentTimeMillis();
    new File(c.getFilesDir(), ERROR_FILE).delete();
    try { c.sendBroadcast(new Intent(c, VpnStop.class)); } catch (Throwable e) { }
  }

  /** Android has allowed this app's VPN (no dialog on connect). */
  public static boolean prepared(Context c) { return VpnService.prepare(c) == null; }

  /** state, server, mode, answered, failed, average ms (-1 none yet),
   *  consent, error, last failure, the VPN process's memory (kB): tab
   *  separated. */
  public static String status(Context c) {
    bind(c);
    String s = askVpn();
    String[] f = s != null ? s.split("\t", -1) : null;
    if (f == null || f.length < 9) {
      // (no VPN process: off -- or it failed, and said why before it went)
      f = new String[] { "0", lastName, "", "0", "0", "-1", "", "", "0" };
      String why = readError(c);
      if (why.length() > 0) {
        f[0] = "3";
        f[6] = why;
      }
    }
    int st = 0;
    try { st = Integer.parseInt(f[0]); } catch (NumberFormatException e) { }
    long now = System.currentTimeMillis();
    if (st == 0 && now - startAt < 8000) {      // asked to start: on its way
      st = 1;
      f[1] = lastName;
    }
    if (st == 2 && now - stopAt < 3000) st = 0; // asked to stop: going
    String err = uiError.length() > 0 ? uiError : f[6];
    return st + "\t" + f[1] + "\t" + f[2] + "\t" + f[3] + "\t" + f[4] + "\t" + f[5] + "\t" +
        consent + "\t" + clean(err) + "\t" + f[7] + "\t" + f[8];
  }

  static final ServiceConnection link = new ServiceConnection() {
    public void onServiceConnected(ComponentName name, IBinder service) { remote = service; }
    public void onServiceDisconnected(ComponentName name) { remote = null; }
  };

  /** Keeps a line to the VPN's process while it runs (and from when it
   *  starts): it is not started for this, nor kept for this. */
  static synchronized void bind(Context c) {
    if (!bound) {
      Context app = c.getApplicationContext();
      if (app == null) app = c;
      try { bound = app.bindService(new Intent(app, DnsVpn.class), link, 0); } catch (Throwable e) { }
    }
    // the first time, a moment for the answer (not on Android's own thread)
    if (bound && !waited && Looper.myLooper() != Looper.getMainLooper()) {
      waited = true;
      for (int i = 0; i < 6 && remote == null; i++) {
        try { Thread.sleep(50); } catch (InterruptedException e) { break; }
      }
    }
  }

  static String askVpn() {
    IBinder b = remote;
    if (b == null) return null;
    Parcel d = Parcel.obtain(), r = Parcel.obtain();
    try {
      return b.transact(STATUS, d, r, 0) ? r.readString() : null;
    } catch (Throwable e) {
      remote = null;                          // (its process ended)
      return null;
    } finally {
      d.recycle();
      r.recycle();
    }
  }

  static String readError(Context c) {
    File f = new File(c.getFilesDir(), ERROR_FILE);
    if (!f.exists()) return "";
    try {
      FileInputStream in = new FileInputStream(f);
      byte[] b = new byte[2048];
      int n = in.read(b);
      in.close();
      return n > 0 ? new String(b, 0, n, "UTF-8") : "";
    } catch (IOException e) {
      return "";
    }
  }

  static String clean(String s) {
    return s == null ? "" : s.replace('\t', ' ').replace('\n', ' ');
  }
}
