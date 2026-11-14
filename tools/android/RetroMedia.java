package org.retro;

import android.app.Activity;
import android.graphics.Bitmap;
import android.media.Image;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.media.MediaMetadataRetriever;
import android.media.MediaMuxer;
import android.media.MediaPlayer;
import android.os.Build;
import java.io.File;
import java.io.FileOutputStream;
import java.io.RandomAccessFile;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.FileChannel;
import java.util.ArrayList;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.VideoView;
import java.util.HashMap;
import java.util.concurrent.ConcurrentHashMap;

/** Sound and video for retro's media module (src/retro/media.nim): the
 *  native side calls "media.what" with tab-separated arguments, and the
 *  activity hands them here (RetroActivity.uirelaysCall: "part.what" goes to
 *  RetroPart.call). Sounds are MediaPlayers (any format Android plays);
 *  videos are VideoViews laid over the app's window where the kit draws
 *  the video's place, shown and hidden as the kit asks. Pictures of videos
 *  come from a MediaMetadataRetriever kept open for the file last asked
 *  about; videos are written by MediaCodec (H.264) and MediaMuxer (MP4). */
public class RetroMedia {
  static final HashMap<String, MediaPlayer> sounds = new HashMap<String, MediaPlayer>();
  static final ConcurrentHashMap<String, Video> videos = new ConcurrentHashMap<String, Video>();
  static FrameLayout layer;

  static class Video {
    VideoView view;
    String path;
    volatile boolean playing, ended;
    volatile int pos, dur;
  }

  /** A sound of audioView: a MediaPlayer of its own, no view -- it plays on
   *  with the app in the background (RetroPlayback keeps the app alive). */
  static class Audio {
    MediaPlayer p;
    String path;
    volatile boolean playing, ended, prepared, startWhenReady, closed;
    volatile int pos, dur, seekWhenReady = -1;
    volatile String error = "";
    float rate = 1f;
  }

  /** What went wrong, in words, for the kit to show under the player. */
  static String why(int what, int extra) {
    switch (extra) {
      case MediaPlayer.MEDIA_ERROR_IO:
        return "The sound could not be read (the network, or the server said no).";
      case MediaPlayer.MEDIA_ERROR_MALFORMED: return "The sound is damaged.";
      case MediaPlayer.MEDIA_ERROR_UNSUPPORTED: return "Android does not play this kind of sound.";
      case MediaPlayer.MEDIA_ERROR_TIMED_OUT: return "The server took too long to answer.";
    }
    if (what == MediaPlayer.MEDIA_ERROR_SERVER_DIED) return "Android's player stopped; press Play again.";
    return "Android could not play this sound (" + what + ", " + extra + ").";
  }

  static void failed(Activity a, Audio x, String error) {
    x.error = error.replace('\t', ' ').replace('\n', ' ');
    x.playing = false;
    x.startWhenReady = false;
    anyPlaying(a);
  }

  /** Gives x's player its sound and has it get ready. A web address where
   *  plain http is not allowed has its redirects followed first (off this
   *  thread), with http asked for as https: the player would stop at an
   *  http hop. */
  static void open(final Activity a, final Audio x) {
    final String path = x.path;
    boolean web = path.startsWith("http://") || path.startsWith("https://");
    if (!web || RetroNet.cleartextAllowed(null)) { prepare(a, x, path); return; }
    new Thread(new Runnable() { public void run() {
      prepare(a, x, RetroNet.finalAddress(path, "RetroApp", 15000));
    }}).start();
  }

  static void prepare(Activity a, Audio x, String src) {
    synchronized (x) {
      if (x.closed) return;
      try {
        x.p.setDataSource(src);
        x.p.prepareAsync();
      } catch (Throwable t) {
        String m = t.getMessage();
        failed(a, x, "The sound could not be opened" + (m != null && m.length() > 0 ? ": " + m : "."));
      }
    }
  }
  static final ConcurrentHashMap<String, Audio> audios = new ConcurrentHashMap<String, Audio>();

  static void anyPlaying(Activity a) {
    boolean on = false;
    for (Audio x : audios.values()) if (x.playing) on = true;
    if (on) RetroPlayback.start(a); else RetroPlayback.stop(a);
  }

  static void applyRate(Audio x) {
    // (setPlaybackParams starts a paused player: only while it plays)
    if (x.p == null || !x.prepared || !x.playing) return;
    try { x.p.setPlaybackParams(x.p.getPlaybackParams().setSpeed(x.rate)); } catch (Throwable t) { }
  }

  static String audio(final Activity a, final String what, final String[] args) {
    final String key = args[0];
    final Audio known = audios.get(key);
    if (what.equals("State")) {
      if (known == null) return "0\t0\t0\t0";
      try {
        if (known.prepared) {
          known.pos = known.p.getCurrentPosition();
          int d = known.p.getDuration();
          if (d > 0) known.dur = d;
        }
      } catch (Throwable t) { }
      return (known.playing ? "1" : "0") + "\t" + known.pos + "\t" + known.dur + "\t" +
             (known.ended ? "1" : "0") + "\t" + known.error;
    }
    if (what.equals("Show")) {
      String path = args[5];
      if (known != null && path.equals(known.path)) return "1";
      if (known != null) {
        synchronized (known) {
          known.closed = true;
          try { known.p.release(); } catch (Throwable t) { }
        }
        audios.remove(key);
      }
      final Audio x = new Audio();
      x.path = path;
      x.p = new MediaPlayer();
      x.startWhenReady = args.length > 6 && args[6].equals("1");
      try {
        x.p.setOnPreparedListener(new MediaPlayer.OnPreparedListener() {
          public void onPrepared(MediaPlayer mp) {
            x.prepared = true;
            x.dur = Math.max(0, mp.getDuration());
            if (x.seekWhenReady >= 0) { mp.seekTo(x.seekWhenReady); x.seekWhenReady = -1; }
            if (x.startWhenReady) { mp.start(); x.playing = true; applyRate(x); anyPlaying(a); }
          }
        });
        x.p.setOnCompletionListener(new MediaPlayer.OnCompletionListener() {
          public void onCompletion(MediaPlayer mp) { x.ended = true; x.playing = false; anyPlaying(a); }
        });
        x.p.setOnErrorListener(new MediaPlayer.OnErrorListener() {
          public boolean onError(MediaPlayer mp, int w, int e) { failed(a, x, why(w, e)); return true; }
        });
      } catch (Throwable t) {
        try { x.p.release(); } catch (Throwable u) { }
        return null;
      }
      audios.put(key, x);
      if (x.startWhenReady) x.playing = true;
      open(a, x);
      return "1";
    }
    if (known == null) return "1";
    try {
      if (what.equals("Play")) {
        known.ended = false;
        known.playing = true;
        if (known.error.length() > 0) {
          // (it failed: Play tries again, from the start of getting ready)
          known.error = "";
          known.prepared = false;
          known.startWhenReady = true;
          if (known.pos > 0) known.seekWhenReady = known.pos;
          synchronized (known) { known.p.reset(); }
          open(a, known);
        } else if (known.prepared) { known.p.start(); applyRate(known); }
        else known.startWhenReady = true;
      } else if (what.equals("Pause")) {
        known.playing = false;
        known.startWhenReady = false;
        if (known.prepared) known.p.pause();
      } else if (what.equals("Seek")) {
        int ms = Integer.parseInt(args[1]);
        known.ended = false;
        if (known.prepared) known.p.seekTo(ms); else known.seekWhenReady = ms;
        known.pos = ms;
      } else if (what.equals("Rate")) {
        known.rate = Float.parseFloat(args[1]);
        applyRate(known);
      } else if (what.equals("Close")) {
        known.playing = false;
        audios.remove(key);
        synchronized (known) {
          known.closed = true;
          known.p.release();
        }
      }
    } catch (Throwable t) { }
    anyPlaying(a);
    return "1";
  }

  public static String call(final Activity a, String what, final String[] args) throws Exception {
    if (what.equals("play")) return play(args);
    if (what.equals("stop")) {
      MediaPlayer p;
      synchronized (sounds) { p = sounds.remove(args[0]); }
      if (p != null) {
        try { p.stop(); } catch (Throwable t) { }
        p.release();
      }
      return "1";
    }
    if (what.equals("playing")) {
      synchronized (sounds) {
        MediaPlayer p = sounds.get(args[0]);
        if (p == null) return "0";
        try { return p.isPlaying() ? "1" : "0"; } catch (Throwable t) { return "0"; }
      }
    }
    if (what.equals("volume")) {
      synchronized (sounds) {
        MediaPlayer p = sounds.get(args[0]);
        float v = clamp(Float.parseFloat(args[1]));
        if (p != null) p.setVolume(v, v);
      }
      return "1";
    }
    if (what.equals("frame")) return frame(args);
    if (what.equals("frameAt")) return frameAt(args);
    if (what.equals("duration")) return duration(args);
    if (what.equals("frameRaw")) return frameRaw(args);
    if (what.equals("frameClose")) { closeKept(); return "1"; }
    if (what.equals("info")) return info(args);
    if (what.equals("encAvailable")) return avcEncoders().isEmpty() ? "0" : "1";
    if (what.equals("encBegin")) return encBegin(args);
    if (what.equals("encFrame")) return encFrame(args);
    if (what.equals("encEnd")) return encEnd(args);
    if (what.equals("decode")) return decode(args);
    if (what.startsWith("video")) return video(a, what.substring(5), args);
    return null;
  }

  /** A picture of a video (a tenth of the way in), no larger than args[2]
   *  pixels, written to args[1] as a JPEG: the file lists' pictures of
   *  videos. Any thread may ask. */
  static String frame(String[] args) {
    MediaMetadataRetriever r = new MediaMetadataRetriever();
    try {
      r.setDataSource(args[0]);
      long dur = 0;
      try { dur = Long.parseLong(r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)); }
      catch (Throwable t) { }
      Bitmap b = r.getFrameAtTime(Math.min(dur * 100, 3000000L), MediaMetadataRetriever.OPTION_CLOSEST_SYNC);
      if (b == null) b = r.getFrameAtTime();
      if (b == null) return "0";
      int max = Integer.parseInt(args[2]);
      int w = b.getWidth(), h = b.getHeight();
      if (w > max || h > max) {
        float k = Math.min(max / (float) w, max / (float) h);
        Bitmap s = Bitmap.createScaledBitmap(b, Math.max(1, (int) (w * k)), Math.max(1, (int) (h * k)), true);
        b.recycle();
        b = s;
      }
      FileOutputStream o = new FileOutputStream(args[1]);
      b.compress(Bitmap.CompressFormat.JPEG, 85, o);
      o.close();
      b.recycle();
      return "1";
    } catch (Throwable t) {
      return "0";
    } finally {
      try { r.release(); } catch (Throwable t) { }
    }
  }

  /** A picture Android reads and the kit does not (HEIC, HEIF, AVIF: the
   *  system's decoders) written to args[1] as a PNG. "1" done, "0" not. */
  static String decode(String[] args) {
    try {
      android.graphics.BitmapFactory.Options o = new android.graphics.BitmapFactory.Options();
      o.inPreferredConfig = Bitmap.Config.ARGB_8888;
      Bitmap b = android.graphics.BitmapFactory.decodeFile(args[0], o);
      if (b == null) return "0";
      FileOutputStream out = new FileOutputStream(args[1]);
      b.compress(Bitmap.CompressFormat.PNG, 100, out);
      out.close();
      b.recycle();
      return "1";
    } catch (Throwable t) {
      return "0";
    }
  }

  /** How long a video is, milliseconds ("" when it cannot be read). */
  static String duration(String[] args) {
    MediaMetadataRetriever r = new MediaMetadataRetriever();
    try {
      r.setDataSource(args[0]);
      String d = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION);
      return d == null ? "" : d;
    } catch (Throwable t) {
      return "";
    } finally {
      try { r.release(); } catch (Throwable t) { }
    }
  }

  /** The video's picture at args[2] milliseconds, no larger than args[3]
   *  pixels, written to args[1] as a PNG (Import > Video Frames to Layers). */
  static String frameAt(String[] args) {
    MediaMetadataRetriever r = new MediaMetadataRetriever();
    try {
      r.setDataSource(args[0]);
      long us = Long.parseLong(args[2]) * 1000L;
      Bitmap b = r.getFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST);
      if (b == null) b = r.getFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST_SYNC);
      if (b == null) return "0";
      int max = Integer.parseInt(args[3]);
      int w = b.getWidth(), h = b.getHeight();
      if (max > 0 && (w > max || h > max)) {
        float k = Math.min(max / (float) w, max / (float) h);
        Bitmap s = Bitmap.createScaledBitmap(b, Math.max(1, (int) (w * k)), Math.max(1, (int) (h * k)), true);
        b.recycle();
        b = s;
      }
      FileOutputStream o = new FileOutputStream(args[1]);
      b.compress(Bitmap.CompressFormat.PNG, 100, o);
      o.close();
      b.recycle();
      return "1";
    } catch (Throwable t) {
      return "0";
    } finally {
      try { r.release(); } catch (Throwable t) { }
    }
  }

  // ---- pictures of videos, one at a time ---------------------------------------------------------
  // A retriever kept open for the file last asked about (scrubbing asks again and again); each
  // picture handed over raw: w * h ints, 0xAARRGGBB, little-endian (B G R A bytes).

  static MediaMetadataRetriever kept;
  static String keptPath;
  static long keptStamp;
  static int keptW, keptH;
  static float keptFps;
  static long keptDurUs;
  static int[] pxBuf;
  static ByteBuffer rawBuf;
  static boolean looked;
  static Method frameParams, scaledParams, scaled27;
  static Object argbParams;

  static synchronized MediaMetadataRetriever retriever(String path) throws Exception {
    File f = new File(path);
    long stamp = f.lastModified() * 31 + f.length();
    if (kept != null && path.equals(keptPath) && stamp == keptStamp) return kept;
    closeKept();
    MediaMetadataRetriever r = new MediaMetadataRetriever();
    try {
      r.setDataSource(path);
    } catch (Throwable t) {
      r.release();
      throw new Exception(t.toString());
    }
    int[] wh = shownSize(r);
    keptW = wh[0];
    keptH = wh[1];
    keptDurUs = parseLong(r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)) * 1000L;
    keptFps = frameRate(path, r);
    kept = r;
    keptPath = path;
    keptStamp = stamp;
    return r;
  }

  static synchronized void closeKept() {
    if (kept != null) try { kept.release(); } catch (Throwable t) { }
    kept = null;
    keptPath = null;
    pxBuf = null;
    rawBuf = null;
  }

  static long parseLong(String s) {
    try { return s == null ? 0 : Long.parseLong(s.trim()); } catch (Throwable t) { return 0; }
  }

  /** The picture's size as shown (turned by the file's rotation). */
  static int[] shownSize(MediaMetadataRetriever r) {
    int w = (int) parseLong(r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH));
    int h = (int) parseLong(r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT));
    int rot = (int) parseLong(r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION));
    if (rot % 180 != 0) return new int[] { h, w };
    return new int[] { w, h };
  }

  /** Pictures a second: the track's frame rate, else measured from its first samples' times. */
  static float frameRate(String path, MediaMetadataRetriever r) {
    MediaExtractor ex = new MediaExtractor();
    try {
      ex.setDataSource(path);
      for (int i = 0; i < ex.getTrackCount(); i++) {
        MediaFormat f = ex.getTrackFormat(i);
        String mime = f.getString(MediaFormat.KEY_MIME);
        if (mime == null || !mime.startsWith("video/")) continue;
        if (f.containsKey(MediaFormat.KEY_FRAME_RATE)) {
          float fps = 0;
          try { fps = f.getInteger(MediaFormat.KEY_FRAME_RATE); }
          catch (Throwable t) { try { fps = f.getFloat(MediaFormat.KEY_FRAME_RATE); } catch (Throwable u) { } }
          if (fps > 0 && fps < 1000) return fps;
        }
        // the samples' times (in decoding order: sorted here)
        ex.selectTrack(i);
        long[] ts = new long[40];
        int n = 0;
        while (n < ts.length && ex.getSampleTime() >= 0) {
          ts[n++] = ex.getSampleTime();
          ex.advance();
        }
        java.util.Arrays.sort(ts, 0, n);
        if (n >= 2 && ts[n - 1] > ts[0]) return (n - 1) * 1e6f / (ts[n - 1] - ts[0]);
        return 0;
      }
    } catch (Throwable t) {
    } finally {
      ex.release();
    }
    return 0;
  }

  static void lookForMethods() {
    if (looked) return;
    looked = true;
    try {
      if (Build.VERSION.SDK_INT >= 28) {
        // MediaMetadataRetriever.BitmapParams: ARGB_8888 pictures (older systems give RGB_565)
        Class<?> bp = Class.forName("android.media.MediaMetadataRetriever$BitmapParams");
        Object p = bp.newInstance();
        bp.getMethod("setPreferredConfig", Bitmap.Config.class).invoke(p, Bitmap.Config.ARGB_8888);
        frameParams = MediaMetadataRetriever.class.getMethod("getFrameAtTime", long.class, int.class, bp);
        scaledParams = MediaMetadataRetriever.class.getMethod("getScaledFrameAtTime", long.class, int.class,
                                                              int.class, int.class, bp);
        argbParams = p;
      } else if (Build.VERSION.SDK_INT >= 27) {
        scaled27 = MediaMetadataRetriever.class.getMethod("getScaledFrameAtTime", long.class, int.class,
                                                          int.class, int.class);
      }
    } catch (Throwable t) {
      frameParams = scaledParams = scaled27 = null;
    }
  }

  /** The picture at `us` no larger than `max` (0: as it is): decoded at that size where the system
   *  can (Android 8.1+). */
  static Bitmap grab(MediaMetadataRetriever r, long us, int max, int option) {
    lookForMethods();
    boolean smaller = max > 0 && (keptW > max || keptH > max);
    try {
      if (smaller && scaledParams != null) return (Bitmap) scaledParams.invoke(r, us, option, max, max, argbParams);
      if (!smaller && frameParams != null) return (Bitmap) frameParams.invoke(r, us, option, argbParams);
      if (smaller && scaled27 != null) return (Bitmap) scaled27.invoke(r, us, option, max, max);
    } catch (Throwable t) { }
    return r.getFrameAtTime(us, option);
  }

  /** The picture shown at args[2] ms (the last one beginning at or before it), no larger than
   *  args[3] pixels, written raw to args[1]: "1\tw\th", or "0". */
  static synchronized String frameRaw(String[] args) {
    try {
      MediaMetadataRetriever r = retriever(args[0]);
      long us = Long.parseLong(args[2]) * 1000L;
      int max = Integer.parseInt(args[3]);
      // OPTION_CLOSEST gives the picture nearest the time: asked for a quarter of a picture after
      // the start of the one shown then (the frame rate known), and not past the last one
      if (keptFps > 0) {
        double step = 1e6 / keptFps;
        if (keptDurUs > 0) us = Math.min(us, keptDurUs - (long) (step / 2));
        us = (long) (Math.floor(Math.max(0, us) / step + 1e-6) * step + step / 4);
      } else if (keptDurUs > 0) us = Math.min(us, keptDurUs - 1000);
      us = Math.max(0, us);
      Bitmap b = grab(r, us, max, MediaMetadataRetriever.OPTION_CLOSEST);
      if (b == null) b = grab(r, us, max, MediaMetadataRetriever.OPTION_CLOSEST_SYNC);
      if (b == null) return "0";
      int w = b.getWidth(), h = b.getHeight();
      if (max > 0 && (w > max || h > max)) {
        float k = Math.min(max / (float) w, max / (float) h);
        Bitmap s = Bitmap.createScaledBitmap(b, Math.max(1, Math.round(w * k)), Math.max(1, Math.round(h * k)), true);
        b.recycle();
        b = s;
        w = b.getWidth();
        h = b.getHeight();
      }
      writeRaw(b, args[1]);
      b.recycle();
      return "1\t" + w + "\t" + h;
    } catch (Throwable t) {
      closeKept();
      return "0";
    }
  }

  static void writeRaw(Bitmap b, String path) throws Exception {
    int w = b.getWidth(), h = b.getHeight(), n = w * h;
    if (pxBuf == null || pxBuf.length < n) pxBuf = new int[n];
    b.getPixels(pxBuf, 0, w, 0, 0, w, h);          // ARGB, whatever the bitmap's own format
    if (rawBuf == null || rawBuf.capacity() < n * 4)
      rawBuf = ByteBuffer.allocateDirect(n * 4).order(ByteOrder.LITTLE_ENDIAN);
    rawBuf.clear();
    rawBuf.asIntBuffer().put(pxBuf, 0, n);
    rawBuf.limit(n * 4);
    FileOutputStream o = new FileOutputStream(path);
    try {
      FileChannel ch = o.getChannel();
      while (rawBuf.hasRemaining()) ch.write(rawBuf);
    } finally {
      o.close();
    }
  }

  /** "width \t height \t duration ms \t frames a second \t frames" (as shown), "" when unreadable. */
  static String info(String[] args) {
    MediaMetadataRetriever r = new MediaMetadataRetriever();
    try {
      r.setDataSource(args[0]);
      int[] wh = shownSize(r);
      long dur = parseLong(r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION));
      long frames = parseLong(r.extractMetadata(32));     // METADATA_KEY_VIDEO_FRAME_COUNT (API 28)
      float fps = frameRate(args[0], r);
      if (wh[0] <= 0 && dur <= 0) return "";
      return wh[0] + "\t" + wh[1] + "\t" + dur + "\t" + fps + "\t" + frames;
    } catch (Throwable t) {
      return "";
    } finally {
      try { r.release(); } catch (Throwable t) { }
    }
  }

  // ---- writing videos: MediaCodec (H.264) into MediaMuxer (MP4) -------------------------------------
  // encBegin: id, path, width, height, fps, bit rate (0: chosen), "709" or "601" (the colours the
  //   pictures are in) -> "1\twidth\theight\tencoder" (the size as the encoder takes it), "0\twhy"
  // encFrame: id, file of one picture (YUV 4:2:0 planar, width x height), time in us -> "1", "0\twhy"
  // encEnd: id, "1" to throw it away -> "1", "0\twhy"
  // The pictures go in through the codec's Image (any YUV 4:2:0 layout it has: planar, semi-planar,
  // its strides) or, where it gives none, its buffer laid out as its colour format says.

  static final ConcurrentHashMap<String, Enc> encs = new ConcurrentHashMap<String, Enc>();
  static final int FLEXIBLE = MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible;
  static final int PLANAR = 19;           // COLOR_FormatYUV420Planar (I420)
  static final int PACKED_PLANAR = 20;    // COLOR_FormatYUV420PackedPlanar
  static final int SEMIPLANAR = 21;       // COLOR_FormatYUV420SemiPlanar (NV12)
  static final long WAIT_MS = 10000;

  static class Enc {
    MediaCodec codec;
    MediaMuxer muxer;
    String path, name;
    int w, h, track = -1, colorFormat, stride, slice;
    boolean planarBuffer, started, eos;
    int written;
    long lastPts;
    byte[] frame;
    final MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
  }

  static String why(Throwable t) {
    String m = t.getMessage();
    if (m == null || m.length() == 0) m = t.getClass().getSimpleName();
    return m.replace('\t', ' ').replace('\n', ' ');
  }

  static ArrayList<MediaCodecInfo> avcEncoders() {
    ArrayList<MediaCodecInfo> r = new ArrayList<MediaCodecInfo>();
    try {
      for (MediaCodecInfo i : new MediaCodecList(MediaCodecList.REGULAR_CODECS).getCodecInfos()) {
        if (!i.isEncoder()) continue;
        for (String t : i.getSupportedTypes())
          if (t.equalsIgnoreCase(MediaFormat.MIMETYPE_VIDEO_AVC)) { r.add(i); break; }
      }
    } catch (Throwable t) { }
    return r;
  }

  static String encBegin(String[] a) {
    String id = a[0], path = a[1];
    int w = Integer.parseInt(a[2]), h = Integer.parseInt(a[3]);
    float fps = Float.parseFloat(a[4]);
    int bitrate = Integer.parseInt(a[5]);
    boolean bt709 = a.length > 6 && a[6].equals("709");
    if (bitrate <= 0) bitrate = (int) Math.max(300000, Math.min(2.0e9, w * (double) h * Math.max(1, fps) * 0.12));
    String err = "This device has no H.264 encoder.";
    for (MediaCodecInfo ci : avcEncoders()) {
      MediaCodecInfo.CodecCapabilities caps;
      try { caps = ci.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC); } catch (Throwable t) { continue; }
      // the colour format: flexible YUV 4:2:0 (Image input) where it can, else planar or semi-planar
      int cf = 0;
      for (int c : caps.colorFormats) if (c == FLEXIBLE) cf = c;
      if (cf == 0) for (int c : caps.colorFormats) if (c == SEMIPLANAR) cf = c;
      if (cf == 0) for (int c : caps.colorFormats) if (c == PLANAR) cf = c;
      if (cf == 0) { err = ci.getName() + " takes no YUV 4:2:0 pictures."; continue; }
      int aw = w, ah = h, br = bitrate;
      MediaCodecInfo.VideoCapabilities vc = caps.getVideoCapabilities();
      if (vc != null) {
        int wa = Math.max(1, vc.getWidthAlignment()), ha = Math.max(1, vc.getHeightAlignment());
        aw = (w + wa - 1) / wa * wa;
        ah = (h + ha - 1) / ha * ha;
        if (!vc.isSizeSupported(aw, ah)) { err = "The H.264 encoder cannot take " + w + " x " + h + " pictures."; continue; }
        try { br = Math.max(vc.getBitrateRange().getLower(), Math.min(vc.getBitrateRange().getUpper(), br)); }
        catch (Throwable t) { }
      }
      MediaFormat f = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, aw, ah);
      f.setInteger(MediaFormat.KEY_COLOR_FORMAT, cf);
      f.setInteger(MediaFormat.KEY_BIT_RATE, br);
      f.setInteger(MediaFormat.KEY_FRAME_RATE, Math.max(1, Math.round(fps)));
      f.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);
      // (MediaFormat.KEY_COLOR_STANDARD, _RANGE, _TRANSFER: Android 7)
      f.setInteger("color-standard", bt709 ? 1 : 4);      // BT709 : BT601_NTSC
      f.setInteger("color-range", 2);                     // limited
      f.setInteger("color-transfer", 3);                  // SDR video
      MediaCodec c = null;
      try {
        c = MediaCodec.createByCodecName(ci.getName());
        c.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
        c.start();
      } catch (Throwable t) {
        if (c != null) try { c.release(); } catch (Throwable u) { }
        err = ci.getName() + ": " + why(t);
        continue;
      }
      Enc e = new Enc();
      e.codec = c;
      e.name = ci.getName();
      e.path = path;
      e.w = aw;
      e.h = ah;
      e.colorFormat = cf;
      e.frame = new byte[aw * ah * 3 / 2];
      e.stride = aw;
      e.slice = ah;
      e.planarBuffer = cf == PLANAR;
      try {
        // the buffer's layout, for when the codec gives no Image
        MediaFormat in = c.getInputFormat();
        if (in.containsKey("stride")) e.stride = Math.max(aw, in.getInteger("stride"));
        if (in.containsKey("slice-height")) e.slice = Math.max(ah, in.getInteger("slice-height"));
        if (cf == FLEXIBLE && in.containsKey(MediaFormat.KEY_COLOR_FORMAT)) {
          int real = in.getInteger(MediaFormat.KEY_COLOR_FORMAT);
          e.planarBuffer = real == PLANAR || real == PACKED_PLANAR;
        }
      } catch (Throwable t) { }
      try {
        new File(path).delete();
        e.muxer = new MediaMuxer(path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
      } catch (Throwable t) {
        try { c.stop(); } catch (Throwable u) { }
        try { c.release(); } catch (Throwable u) { }
        return "0\tThe video file cannot be written: " + why(t);
      }
      encs.put(id, e);
      return "1\t" + aw + "\t" + ah + "\t" + ci.getName();
    }
    return "0\t" + err.replace('\t', ' ');
  }

  /** Takes what the encoder has made into the file; with `end`, until its end of stream. */
  static void drain(Enc e, boolean end) throws Exception {
    long until = System.currentTimeMillis() + WAIT_MS;
    while (true) {
      int oi = e.codec.dequeueOutputBuffer(e.info, end ? 10000 : 0);
      if (oi == MediaCodec.INFO_TRY_AGAIN_LATER) {
        if (!end) return;
        if (System.currentTimeMillis() > until) throw new Exception("The encoder did not finish the video.");
        continue;
      }
      if (oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
        // once, before the first picture: the format (with SPS and PPS) starts the muxer
        if (e.started) throw new Exception("The encoder changed its format midway.");
        e.track = e.muxer.addTrack(e.codec.getOutputFormat());
        e.muxer.start();
        e.started = true;
        continue;
      }
      if (oi < 0) continue;                                // (INFO_OUTPUT_BUFFERS_CHANGED: not used)
      ByteBuffer out = e.codec.getOutputBuffer(oi);
      boolean config = (e.info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0;
      if (!config && e.info.size > 0 && out != null) {
        if (!e.started) {
          e.codec.releaseOutputBuffer(oi, false);
          throw new Exception("The encoder gave a picture before its format.");
        }
        out.position(e.info.offset);
        out.limit(e.info.offset + e.info.size);
        e.muxer.writeSampleData(e.track, out, e.info);
        e.written++;
      }
      e.codec.releaseOutputBuffer(oi, false);
      if ((e.info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
        e.eos = true;
        return;
      }
      until = System.currentTimeMillis() + WAIT_MS;
    }
  }

  /** An input buffer, taking what the encoder made meanwhile (it may wait for that). */
  static int inputIndex(Enc e) throws Exception {
    long until = System.currentTimeMillis() + WAIT_MS;
    while (true) {
      int ii = e.codec.dequeueInputBuffer(10000);
      if (ii >= 0) return ii;
      drain(e, false);
      if (System.currentTimeMillis() > until) throw new Exception("The encoder takes no more pictures.");
    }
  }

  static void copyPlane(Image.Plane pl, byte[] src, int off, int pw, int ph) {
    ByteBuffer b = pl.getBuffer();
    int rs = pl.getRowStride(), ps = pl.getPixelStride(), base = b.position();
    if (ps == 1) {
      for (int y = 0; y < ph; y++) {
        b.position(base + y * rs);
        b.put(src, off + y * pw, pw);
      }
    } else {
      for (int y = 0; y < ph; y++) {
        int row = base + y * rs, s = off + y * pw;
        for (int x = 0; x < pw; x++) b.put(row + x * ps, src[s + x]);
      }
    }
  }

  static int fillBuffer(ByteBuffer b, Enc e) throws Exception {
    int w = e.w, h = e.h, st = e.stride, sh = e.slice, cw = w / 2, ch = h / 2;
    int uv = st * sh;
    int size = e.planarBuffer ? uv + 2 * (st / 2) * (sh / 2) : uv + st * (sh / 2);
    if (size > b.capacity()) throw new Exception("The encoder's buffer is too small.");
    b.clear();
    for (int y = 0; y < h; y++) {
      b.position(y * st);
      b.put(e.frame, y * w, w);
    }
    int u = w * h, v = u + cw * ch;
    if (e.planarBuffer) {
      for (int y = 0; y < ch; y++) {
        b.position(uv + y * (st / 2));
        b.put(e.frame, u + y * cw, cw);
        b.position(uv + (st / 2) * (sh / 2) + y * (st / 2));
        b.put(e.frame, v + y * cw, cw);
      }
    } else {
      byte[] row = new byte[cw * 2];
      for (int y = 0; y < ch; y++) {
        for (int x = 0; x < cw; x++) {
          row[2 * x] = e.frame[u + y * cw + x];
          row[2 * x + 1] = e.frame[v + y * cw + x];
        }
        b.position(uv + y * st);
        b.put(row, 0, cw * 2);
      }
    }
    b.position(0);
    b.limit(size);
    return size;
  }

  static String encFrame(String[] a) {
    Enc e = encs.get(a[0]);
    if (e == null) return "0\tThe video was not begun.";
    synchronized (e) {
      try {
        RandomAccessFile f = new RandomAccessFile(a[1], "r");
        try { f.readFully(e.frame); } finally { f.close(); }
        long pts = Long.parseLong(a[2]);
        int ii = inputIndex(e);
        Image img = null;
        try { img = e.codec.getInputImage(ii); } catch (Throwable t) { img = null; }
        int size;
        if (img != null) {
          if (img.getWidth() < e.w || img.getHeight() < e.h || img.getPlanes().length < 3)
            throw new Exception("The encoder's picture is not " + e.w + " x " + e.h + " YUV.");
          Image.Plane[] p = img.getPlanes();
          int cw = e.w / 2, ch = e.h / 2;
          copyPlane(p[0], e.frame, 0, e.w, e.h);
          copyPlane(p[1], e.frame, e.w * e.h, cw, ch);
          copyPlane(p[2], e.frame, e.w * e.h + cw * ch, cw, ch);
          size = e.w * e.h * 3 / 2;
        } else {
          ByteBuffer b = e.codec.getInputBuffer(ii);
          if (b == null) throw new Exception("The encoder gave no buffer.");
          size = fillBuffer(b, e);
        }
        e.codec.queueInputBuffer(ii, 0, size, pts, 0);
        e.lastPts = pts;
        drain(e, false);
        return "1";
      } catch (Throwable t) {
        return "0\t" + why(t);
      }
    }
  }

  static String encEnd(String[] a) {
    Enc e = encs.remove(a[0]);
    if (e == null) return "0\tThe video was not begun.";
    boolean abort = a.length > 1 && a[1].equals("1");
    synchronized (e) {
      String err = null;
      try {
        if (!abort) {
          int ii = inputIndex(e);
          e.codec.queueInputBuffer(ii, 0, 0, e.lastPts, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
          drain(e, true);
        }
      } catch (Throwable t) {
        err = why(t);
      }
      try { e.codec.stop(); } catch (Throwable t) { }
      try { e.codec.release(); } catch (Throwable t) { }
      try {
        if (e.started) e.muxer.stop();
      } catch (Throwable t) {
        if (err == null) err = "The video could not be finished: " + why(t);
      }
      try { e.muxer.release(); } catch (Throwable t) { }
      if (err == null && !abort && e.written == 0) err = "The encoder made no pictures.";
      if (abort || err != null) new File(e.path).delete();
      return err == null ? "1" : "0\t" + err;
    }
  }

  static float clamp(float v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

  static String play(String[] args) throws Exception {
    final String id = args[0];
    float vol = clamp(Float.parseFloat(args[2]));
    final MediaPlayer p = new MediaPlayer();
    try {
      p.setDataSource(args[1]);
      p.setVolume(vol, vol);
      p.setLooping(args[3].equals("1"));
      p.setOnCompletionListener(new MediaPlayer.OnCompletionListener() {
        public void onCompletion(MediaPlayer mp) {
          synchronized (sounds) { if (sounds.get(id) == mp) sounds.remove(id); }
          mp.release();
        }
      });
      p.prepare();
      p.start();
    } catch (Throwable t) {
      p.release();
      return null;
    }
    synchronized (sounds) { sounds.put(id, p); }
    return "1";
  }

  static String video(final Activity a, final String what, final String[] args) {
    final String key = args[0];
    // (a sound: its own player, no view)
    if (audios.containsKey(key) || (what.equals("Show") && args.length > 7 && args[7].equals("a")))
      return audio(a, what, args);
    final Video known = videos.get(key);
    if (what.equals("State")) {
      if (known == null) return "0\t0\t0\t0";
      a.runOnUiThread(new Runnable() { public void run() {   // for the next ask
        try {
          known.playing = known.view.isPlaying();
          known.pos = known.view.getCurrentPosition();
          int d = known.view.getDuration();
          if (d > 0) known.dur = d;
        } catch (Throwable t) { }
      }});
      return (known.playing ? "1" : "0") + "\t" + known.pos + "\t" + known.dur + "\t" +
             (known.ended ? "1" : "0");
    }
    a.runOnUiThread(new Runnable() { public void run() {
      try {
        Video v = videos.get(key);
        if (what.equals("Show")) {
          int x = Integer.parseInt(args[1]), y = Integer.parseInt(args[2]);
          int w = Integer.parseInt(args[3]), h = Integer.parseInt(args[4]);
          String path = args[5];
          if (layer == null) {
            layer = new FrameLayout(a);
            a.addContentView(layer, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
          }
          if (v == null || !path.equals(v.path)) {
            if (v != null) {
              v.view.stopPlayback();
              layer.removeView(v.view);
            }
            final Video nv = new Video();
            nv.path = path;
            nv.view = new VideoView(a);
            // its picture goes above the window the kit draws in
            nv.view.setZOrderMediaOverlay(true);
            nv.view.setOnCompletionListener(new MediaPlayer.OnCompletionListener() {
              public void onCompletion(MediaPlayer mp) { nv.ended = true; nv.playing = false; }
            });
            nv.view.setOnPreparedListener(new MediaPlayer.OnPreparedListener() {
              public void onPrepared(MediaPlayer mp) { nv.dur = mp.getDuration(); }
            });
            nv.view.setVideoPath(path);
            layer.addView(nv.view);
            videos.put(key, nv);
            v = nv;
            if (args.length > 6 && args[6].equals("1")) {
              v.view.start();
              v.playing = true;
            }
          }
          FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(w, h);
          lp.leftMargin = x;
          lp.topMargin = y;
          lp.gravity = Gravity.TOP | Gravity.LEFT;
          v.view.setLayoutParams(lp);
          v.view.setVisibility(View.VISIBLE);
        } else if (v != null) {
          if (what.equals("Hide")) {
            if (v.view.isPlaying()) v.view.pause();
            v.playing = false;
            v.view.setVisibility(View.GONE);
          } else if (what.equals("Play")) {
            v.ended = false;
            v.view.start();
            v.playing = true;
          } else if (what.equals("Pause")) {
            v.view.pause();
            v.playing = false;
          } else if (what.equals("Seek")) {
            v.view.seekTo(Integer.parseInt(args[1]));
            v.ended = false;
          } else if (what.equals("Rate")) {
            // (a VideoView keeps its MediaPlayer: not reached; videos play at 1)
          } else if (what.equals("Close")) {
            v.view.stopPlayback();
            if (layer != null) layer.removeView(v.view);
            videos.remove(key);
          }
        }
      } catch (Throwable t) { }
    }});
    return "1";
  }
}
