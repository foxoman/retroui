package org.retro;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.pm.PackageManager;
import android.graphics.ImageFormat;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.Image;
import android.media.ImageReader;
import android.media.MediaRecorder;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Size;
import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.util.Arrays;

/** The camera and the microphone for retro's capture module
 *  (src/retroui/capture.nim), reached as "camera.what" through
 *  RetroActivity.uirelaysCall. The camera (Camera2) sends its pictures to
 *  an ImageReader; the newest one's planes are kept, and "camera.frame"
 *  gives it as 8 bytes of size and then RGBA pixels, which the kit draws.
 *  The microphone records with AudioRecord into a WAV file, or with
 *  MediaRecorder into an .m4a (AAC). The app asks for the permissions the
 *  first time (the APK needs --permission:CAMERA, RECORD_AUDIO). */
public final class RetroCamera {
  private RetroCamera() { }

  static CameraDevice device;
  static CameraCaptureSession session;
  static ImageReader reader;
  static HandlerThread thread;
  static Handler handler;
  static volatile String error = "";
  static final Object lock = new Object();
  static byte[] yPlane, uPlane, vPlane;
  static int width, height, yRow, uvRow, uvPixel;
  static boolean fresh;

  public static String call(final Activity a, String what, final String[] args) throws Exception {
    if (what.equals("list")) return list(a);
    if (what.equals("open")) return open(a, args[0], args.length > 1 ? args[1] : "any");
    if (what.equals("state")) return error;
    if (what.equals("frame")) return null;           // (binary: frameBytes)
    if (what.equals("close")) { close(); return "1"; }
    if (what.equals("recStart")) return recStart(a, args[0]);
    if (what.equals("recStop")) return recStop();
    if (what.equals("recLevel")) return Float.toString(level);
    if (what.equals("recording")) return recording ? "1" : "0";
    return null;
  }

  /** "camera.frame": the newest picture as bytes (RetroActivity hands
   *  byte[] answers over as they are). */
  public static byte[] frameBytes() {
    synchronized (lock) {
      if (!fresh || yPlane == null) return new byte[0];
      fresh = false;
      int w = width, h = height;
      byte[] out = new byte[8 + w * h * 4];
      out[0] = (byte) w; out[1] = (byte) (w >> 8); out[2] = (byte) (w >> 16); out[3] = (byte) (w >> 24);
      out[4] = (byte) h; out[5] = (byte) (h >> 8); out[6] = (byte) (h >> 16); out[7] = (byte) (h >> 24);
      int o = 8;
      for (int y = 0; y < h; y++) {
        int yr = y * yRow, cr = (y >> 1) * uvRow;
        for (int x = 0; x < w; x++) {
          int Y = (yPlane[yr + x] & 255) - 16;
          int ci = cr + (x >> 1) * uvPixel;
          int U = (uPlane[ci] & 255) - 128, V = (vPlane[ci] & 255) - 128;
          int c = 298 * Math.max(0, Y);
          int r = (c + 409 * V + 128) >> 8, g = (c - 100 * U - 208 * V + 128) >> 8,
              b = (c + 516 * U + 128) >> 8;
          out[o++] = (byte) Math.max(0, Math.min(255, b));
          out[o++] = (byte) Math.max(0, Math.min(255, g));
          out[o++] = (byte) Math.max(0, Math.min(255, r));
          out[o++] = (byte) 255;
        }
      }
      return out;
    }
  }

  static String facingName(Integer f) {
    if (f == null) return "external";
    if (f == CameraCharacteristics.LENS_FACING_FRONT) return "front";
    if (f == CameraCharacteristics.LENS_FACING_BACK) return "back";
    return "external";
  }

  static String list(Activity a) throws Exception {
    CameraManager m = (CameraManager) a.getSystemService(Context.CAMERA_SERVICE);
    StringBuilder b = new StringBuilder();
    for (String id : m.getCameraIdList()) {
      String f = facingName(m.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING));
      b.append(id).append('\t').append("Camera " + id + " (" + f + ")").append('\t').append(f).append('\n');
    }
    return b.toString();
  }

  static String open(final Activity a, String id, String facing) throws Exception {
    if (a.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
      a.requestPermissions(new String[] { Manifest.permission.CAMERA }, 4243);
      error = "The app may use the camera once you allow it.";
      return "perm";
    }
    close();
    final CameraManager m = (CameraManager) a.getSystemService(Context.CAMERA_SERVICE);
    String pick = null;
    for (String c : m.getCameraIdList()) {
      String f = facingName(m.getCameraCharacteristics(c).get(CameraCharacteristics.LENS_FACING));
      if (c.equals(id) || (id.length() == 0 && (facing.equals("any") || facing.equals(f)) && pick == null))
        pick = c;
    }
    if (pick == null) { error = "There is no camera."; return "0"; }
    StreamConfigurationMap map = m.getCameraCharacteristics(pick)
        .get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
    Size best = new Size(640, 480);
    if (map != null) {
      Size[] sizes = map.getOutputSizes(ImageFormat.YUV_420_888);
      int bestScore = Integer.MAX_VALUE;
      for (Size s : sizes) {
        int score = Math.abs(s.getWidth() - 640) + Math.abs(s.getHeight() - 480);
        if (score < bestScore) { bestScore = score; best = s; }
      }
    }
    thread = new HandlerThread("retro-camera");
    thread.start();
    handler = new Handler(thread.getLooper());
    reader = ImageReader.newInstance(best.getWidth(), best.getHeight(), ImageFormat.YUV_420_888, 3);
    reader.setOnImageAvailableListener(new ImageReader.OnImageAvailableListener() {
      public void onImageAvailable(ImageReader r) {
        Image im = null;
        try {
          im = r.acquireLatestImage();
          if (im == null) return;
          Image.Plane[] p = im.getPlanes();
          synchronized (lock) {
            width = im.getWidth(); height = im.getHeight();
            yRow = p[0].getRowStride(); uvRow = p[1].getRowStride(); uvPixel = p[1].getPixelStride();
            yPlane = copy(p[0].getBuffer(), yPlane);
            uPlane = copy(p[1].getBuffer(), uPlane);
            vPlane = copy(p[2].getBuffer(), vPlane);
            fresh = true;
          }
        } catch (Throwable t) {
        } finally {
          if (im != null) im.close();
        }
      }
    }, handler);
    error = "";
    m.openCamera(pick, new CameraDevice.StateCallback() {
      public void onOpened(CameraDevice d) {
        device = d;
        try {
          d.createCaptureSession(Arrays.asList(reader.getSurface()), new CameraCaptureSession.StateCallback() {
            public void onConfigured(CameraCaptureSession s) {
              session = s;
              try {
                CaptureRequest.Builder rb = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
                rb.addTarget(reader.getSurface());
                s.setRepeatingRequest(rb.build(), null, handler);
              } catch (Throwable t) { error = "The camera does not start."; }
            }
            public void onConfigureFailed(CameraCaptureSession s) { error = "The camera does not start."; }
          }, handler);
        } catch (Throwable t) { error = "The camera does not start."; }
      }
      public void onDisconnected(CameraDevice d) { d.close(); device = null; }
      public void onError(CameraDevice d, int e) {
        d.close();
        device = null;
        error = "The camera cannot be used (another app may have it).";
      }
    }, handler);
    return "1";
  }

  static byte[] copy(ByteBuffer b, byte[] into) {
    b.rewind();
    int n = b.remaining();
    if (into == null || into.length != n) into = new byte[n];
    b.get(into);
    return into;
  }

  static void close() {
    try { if (session != null) session.close(); } catch (Throwable t) { }
    try { if (device != null) device.close(); } catch (Throwable t) { }
    try { if (reader != null) reader.close(); } catch (Throwable t) { }
    if (thread != null) thread.quitSafely();
    session = null; device = null; reader = null; thread = null; handler = null;
    synchronized (lock) { yPlane = null; fresh = false; }
  }

  // ---- the microphone --------------------------------------------------------------------------

  static AudioRecord audio;
  static MediaRecorder media;
  static Thread audioThread;
  static volatile boolean recording;
  static volatile float level;
  static String recPath;
  static long recBytes, recStart;

  static String recStart(Activity a, final String path) throws Exception {
    if (a.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
      a.requestPermissions(new String[] { Manifest.permission.RECORD_AUDIO }, 4244);
      return "perm";
    }
    if (recording) return "0";
    recPath = path;
    recStart = System.currentTimeMillis();
    String l = path.toLowerCase();
    if (l.endsWith(".m4a") || l.endsWith(".aac") || l.endsWith(".mp4")) {
      media = new MediaRecorder();
      media.setAudioSource(MediaRecorder.AudioSource.MIC);
      media.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);
      media.setAudioEncoder(MediaRecorder.AudioEncoder.AAC);
      media.setAudioSamplingRate(44100);
      media.setAudioEncodingBitRate(96000);
      media.setOutputFile(path);
      media.prepare();
      media.start();
      recording = true;
      return "1";
    }
    final int rate = 44100;
    int min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
    audio = new AudioRecord(MediaRecorder.AudioSource.MIC, rate, AudioFormat.CHANNEL_IN_MONO,
                            AudioFormat.ENCODING_PCM_16BIT, Math.max(min, 8192));
    if (audio.getState() != AudioRecord.STATE_INITIALIZED) { audio.release(); audio = null; return "0"; }
    final RandomAccessFile f = new RandomAccessFile(path, "rw");
    f.setLength(0);
    f.write(new byte[44]);                       // (the header, written at the end)
    recBytes = 0;
    recording = true;
    audio.startRecording();
    audioThread = new Thread(new Runnable() {
      public void run() {
        short[] buf = new short[2048];
        byte[] bytes = new byte[4096];
        try {
          while (recording) {
            int n = audio.read(buf, 0, buf.length);
            if (n <= 0) continue;
            int peak = 0;
            for (int i = 0; i < n; i++) {
              peak = Math.max(peak, Math.abs((int) buf[i]));
              bytes[i * 2] = (byte) buf[i];
              bytes[i * 2 + 1] = (byte) (buf[i] >> 8);
            }
            level = peak / 32768f;
            f.write(bytes, 0, n * 2);
            recBytes += n * 2;
          }
          f.seek(0);
          f.write(wavHeader(rate, 1, (int) recBytes));
          f.close();
        } catch (Throwable t) { }
      }
    });
    audioThread.start();
    return "1";
  }

  static byte[] wavHeader(int rate, int ch, int bytes) {
    ByteBuffer b = ByteBuffer.allocate(44).order(java.nio.ByteOrder.LITTLE_ENDIAN);
    b.put("RIFF".getBytes()).putInt(36 + bytes).put("WAVEfmt ".getBytes()).putInt(16)
     .putShort((short) 1).putShort((short) ch).putInt(rate).putInt(rate * ch * 2)
     .putShort((short) (ch * 2)).putShort((short) 16).put("data".getBytes()).putInt(bytes);
    return b.array();
  }

  static String recStop() {
    if (!recording) return "0";
    recording = false;
    long ms = System.currentTimeMillis() - recStart;
    if (media != null) {
      try { media.stop(); } catch (Throwable t) { ms = -1; }
      media.release();
      media = null;
    }
    if (audio != null) {
      try { audioThread.join(2000); } catch (Throwable t) { }
      try { audio.stop(); } catch (Throwable t) { }
      audio.release();
      audio = null;
    }
    level = 0;
    return Long.toString(ms);
  }
}
