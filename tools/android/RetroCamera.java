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
import android.hardware.camera2.params.MeteringRectangle;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.graphics.Rect;
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
 *  gives it as 8 bytes of size and then RGBA pixels, which the kit draws,
 *  turned upright for the screen. A photo is a JPEG at the sensor's full
 *  size, from a second reader ("camera.photo", then "camera.photoDone");
 *  "camera.set" changes the zoom, the flash, the point focused on and the
 *  exposure, "camera.caps" says which the camera has.
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
  // the camera open: what it has, and what the app set
  static CameraCharacteristics chars;
  static boolean front;
  static int sensorTurn, screenTurn;            // (degrees)
  static ImageReader still;                     // (JPEG, the full size)
  static volatile String stillPath = "", stillDone = "";
  static float zoom = 1f, zoomMin = 1f, zoomMax = 1f;
  static boolean zoomRatio;                     // (Android 11+: CONTROL_ZOOM_RATIO, the lenses too)
  static String flash = "off";
  static float focusX = -1, focusY = -1;
  static int exposure;                          // (steps of CONTROL_AE_COMPENSATION_STEP)

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
    if (what.equals("caps")) return caps();
    if (what.equals("set")) return set(args[0], args.length > 1 ? args[1] : "");
    if (what.equals("photo")) return photo(a, args[0]);
    if (what.equals("photoDone")) {
      String d = stillDone;
      if (d.length() > 0) stillDone = "";
      return d;
    }
    return null;
  }

  /** The screen's turn (degrees): the pictures are turned to stand up on it. */
  static void screen(Activity a) {
    try {
      int r = a.getWindowManager().getDefaultDisplay().getRotation();
      screenTurn = r * 90;                      // (ROTATION_0..270 are 0..3)
    } catch (Throwable t) { }
  }

  /** How far (clockwise) the sensor's picture turns to stand up on the
   *  screen (the front camera's before it is shown as in a mirror). */
  static int turn() {
    return front ? (sensorTurn + screenTurn) % 360 : (sensorTurn - screenTurn + 360) % 360;
  }

  // ---- what the camera has, and what is set ------------------------------------------------------

  @SuppressWarnings("unchecked")
  static <T> T charOf(String field) {
    // (a key newer than the API the Java is built for, by its name)
    try {
      Object k = CameraCharacteristics.class.getField(field).get(null);
      return (T) chars.get((CameraCharacteristics.Key<T>) k);
    } catch (Throwable t) { return null; }
  }

  /** "camera.caps": zoomMin zoomMax flash(0/1) focus(0/1) evMin evMax
   *  evStep photoW photoH, apart by tabs ("" with no camera open). */
  static String caps() {
    CameraCharacteristics c = chars;
    if (c == null) return "";
    Boolean fl = c.get(CameraCharacteristics.FLASH_INFO_AVAILABLE);
    Integer af = c.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AF);
    android.util.Range<Integer> ev = c.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE);
    android.util.Rational step = c.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP);
    float st = step != null ? step.floatValue() : 0f;
    int sw = still != null ? still.getWidth() : 0, sh = still != null ? still.getHeight() : 0;
    if (turn() % 180 == 90) { int t = sw; sw = sh; sh = t; }
    return zoomMin + "\t" + zoomMax + "\t" + (fl != null && fl ? 1 : 0) + "\t" +
        (af != null && af > 0 ? 1 : 0) + "\t" +
        (ev != null ? ev.getLower() * st : 0f) + "\t" + (ev != null ? ev.getUpper() * st : 0f) +
        "\t" + st + "\t" + sw + "\t" + sh;
  }

  /** "camera.set": zoom (a factor), flash (off, auto, on, torch), focus
   *  ("x y" in the picture, 0..1; "" for automatic) or exposure (EV). */
  static String set(String what, String v) {
    try {
      if (what.equals("zoom")) zoom = Math.max(zoomMin, Math.min(zoomMax, Float.parseFloat(v)));
      else if (what.equals("flash")) flash = v;
      else if (what.equals("focus")) {
        String[] p = v.trim().split(" ");
        if (p.length == 2) { focusX = Float.parseFloat(p[0]); focusY = Float.parseFloat(p[1]); }
        else { focusX = -1; focusY = -1; }
      } else if (what.equals("exposure")) {
        android.util.Rational step = chars == null ? null
            : chars.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP);
        float st = step != null ? step.floatValue() : 0f;
        exposure = st > 0 ? Math.round(Float.parseFloat(v) / st) : 0;
      } else return "0";
    } catch (Throwable t) { return "0"; }
    repeat(what.equals("focus"));
    return "1";
  }

  /** The point focused on (0..1 in the picture as "camera.frame" gives
   *  it: upright, not as in a mirror) as the sensor's region, in `area`
   *  (what the picture shows of the sensor): turned back, a tenth wide. */
  static MeteringRectangle region(Rect active) {
    float x = focusX, y = focusY;
    int t = turn();
    float sx, sy;
    if (t == 90) { sx = y; sy = 1 - x; }
    else if (t == 180) { sx = 1 - x; sy = 1 - y; }
    else if (t == 270) { sx = 1 - y; sy = x; }
    else { sx = x; sy = y; }
    int w = active.width() / 10, h = active.height() / 10;
    int cx = active.left + (int) (sx * active.width()), cy = active.top + (int) (sy * active.height());
    int l = Math.max(active.left, Math.min(active.right - w, cx - w / 2));
    int tp = Math.max(active.top, Math.min(active.bottom - h, cy - h / 2));
    return new MeteringRectangle(l, tp, w, h, MeteringRectangle.METERING_WEIGHT_MAX - 1);
  }

  /** The zoom, the flash, the focus and the exposure on a request. */
  @SuppressWarnings("unchecked")
  static void apply(CaptureRequest.Builder rb) {
    CameraCharacteristics c = chars;
    if (c == null) return;
    rb.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO);
    Rect active = c.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE);
    if (zoomRatio) {
      // (Android 11+: the regions below are then of the zoomed view)
      try {
        Object k = CaptureRequest.class.getField("CONTROL_ZOOM_RATIO").get(null);
        rb.set((CaptureRequest.Key<Float>) k, zoom);
      } catch (Throwable t) { }
    } else if (active != null && zoom > 1.001f) {
      int w = (int) (active.width() / zoom), h = (int) (active.height() / zoom);
      int l = active.left + (active.width() - w) / 2, tp = active.top + (active.height() - h) / 2;
      active = new Rect(l, tp, l + w, tp + h);  // (the regions: in what is shown)
      rb.set(CaptureRequest.SCALER_CROP_REGION, active);
    }
    Boolean fl = c.get(CameraCharacteristics.FLASH_INFO_AVAILABLE);
    boolean hasFlash = fl != null && fl;
    int ae = CaptureRequest.CONTROL_AE_MODE_ON;
    int fm = CaptureRequest.FLASH_MODE_OFF;
    if (hasFlash && flash.equals("auto")) ae = CaptureRequest.CONTROL_AE_MODE_ON_AUTO_FLASH;
    else if (hasFlash && flash.equals("on")) ae = CaptureRequest.CONTROL_AE_MODE_ON_ALWAYS_FLASH;
    else if (hasFlash && flash.equals("torch")) fm = CaptureRequest.FLASH_MODE_TORCH;
    rb.set(CaptureRequest.CONTROL_AE_MODE, ae);
    rb.set(CaptureRequest.FLASH_MODE, fm);
    rb.set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, exposure);
    Integer afRegions = c.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AF);
    if (focusX >= 0 && active != null && afRegions != null && afRegions > 0) {
      rb.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_AUTO);
      rb.set(CaptureRequest.CONTROL_AF_REGIONS, new MeteringRectangle[] { region(active) });
      Integer aeRegions = c.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AE);
      if (aeRegions != null && aeRegions > 0)
        rb.set(CaptureRequest.CONTROL_AE_REGIONS, new MeteringRectangle[] { region(active) });
    } else {
      int[] modes = c.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES);
      boolean cont = false;
      if (modes != null)
        for (int md : modes) if (md == CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE) cont = true;
      if (cont) rb.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE);
    }
  }

  /** The preview again, as set; `focusNow`: focused on the point once. */
  static void repeat(boolean focusNow) {
    CameraCaptureSession s = session;
    CameraDevice d = device;
    if (s == null || d == null || reader == null) return;
    try {
      CaptureRequest.Builder rb = d.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
      rb.addTarget(reader.getSurface());
      apply(rb);
      s.setRepeatingRequest(rb.build(), null, handler);
      if (focusNow && focusX >= 0) {
        rb.set(CaptureRequest.CONTROL_AF_TRIGGER, CaptureRequest.CONTROL_AF_TRIGGER_START);
        s.capture(rb.build(), null, handler);
      }
    } catch (Throwable t) { }
  }

  /** "camera.photo": a JPEG of `path` at the full size; "camera.photoDone"
   *  gives the path once it is written ("\t" and why, when it failed). */
  static String photo(Activity a, String path) {
    CameraCaptureSession s = session;
    CameraDevice d = device;
    if (s == null || d == null || still == null) return "0";
    screen(a);
    try {
      stillPath = path;
      stillDone = "";
      CaptureRequest.Builder rb = d.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE);
      rb.addTarget(still.getSurface());
      apply(rb);
      rb.set(CaptureRequest.JPEG_ORIENTATION, turn());
      rb.set(CaptureRequest.JPEG_QUALITY, (byte) 92);
      s.capture(rb.build(), null, handler);
      return "1";
    } catch (Throwable t) {
      stillPath = "";
      return "0";
    }
  }

  /** "camera.frame": the newest picture as bytes (RetroActivity hands
   *  byte[] answers over as they are), turned to stand up on the screen. */
  public static byte[] frameBytes(Activity a) {
    screen(a);
    synchronized (lock) {
      if (!fresh || yPlane == null) return new byte[0];
      fresh = false;
      int w = width, h = height;
      int t = turn();
      int ow = t % 180 == 90 ? h : w, oh = t % 180 == 90 ? w : h;
      byte[] out = new byte[8 + w * h * 4];
      out[0] = (byte) ow; out[1] = (byte) (ow >> 8); out[2] = (byte) (ow >> 16); out[3] = (byte) (ow >> 24);
      out[4] = (byte) oh; out[5] = (byte) (oh >> 8); out[6] = (byte) (oh >> 16); out[7] = (byte) (oh >> 24);
      for (int y = 0; y < h; y++) {
        int yr = y * yRow, cr = (y >> 1) * uvRow;
        for (int x = 0; x < w; x++) {
          int Y = (yPlane[yr + x] & 255) - 16;
          int ci = cr + (x >> 1) * uvPixel;
          int U = (uPlane[ci] & 255) - 128, V = (vPlane[ci] & 255) - 128;
          int c = 298 * Math.max(0, Y);
          int r = (c + 409 * V + 128) >> 8, g = (c - 100 * U - 208 * V + 128) >> 8,
              b = (c + 516 * U + 128) >> 8;
          // (where the pixel goes once turned clockwise by t)
          int ox, oy;
          if (t == 90) { ox = h - 1 - y; oy = x; }
          else if (t == 180) { ox = w - 1 - x; oy = h - 1 - y; }
          else if (t == 270) { ox = y; oy = w - 1 - x; }
          else { ox = x; oy = y; }
          int o = 8 + (oy * ow + ox) * 4;
          out[o] = (byte) Math.max(0, Math.min(255, b));
          out[o + 1] = (byte) Math.max(0, Math.min(255, g));
          out[o + 2] = (byte) Math.max(0, Math.min(255, r));
          out[o + 3] = (byte) 255;
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
      CameraCharacteristics c = m.getCameraCharacteristics(id);
      String f = facingName(c.get(CameraCharacteristics.LENS_FACING));
      // (its lens: the focal length tells a wide one from a tele one)
      float[] fl = c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS);
      String lens = fl != null && fl.length > 0 ? ", " + Math.round(fl[0] * 10) / 10f + " mm" : "";
      b.append(id).append('\t').append("Camera " + id + " (" + f + lens + ")").append('\t')
       .append(f).append('\n');
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
    chars = m.getCameraCharacteristics(pick);
    front = "front".equals(facingName(chars.get(CameraCharacteristics.LENS_FACING)));
    Integer so = chars.get(CameraCharacteristics.SENSOR_ORIENTATION);
    sensorTurn = so != null ? so : 0;
    screen(a);
    zoom = 1f; zoomMin = 1f; zoomMax = 1f; zoomRatio = false;
    flash = "off"; focusX = -1; focusY = -1; exposure = 0;
    android.util.Range<Float> zr = charOf("CONTROL_ZOOM_RATIO_RANGE");
    if (zr != null) {
      zoomRatio = true;
      zoomMin = zr.getLower(); zoomMax = zr.getUpper();
    } else {
      Float dz = chars.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM);
      if (dz != null) zoomMax = dz;
    }
    StreamConfigurationMap map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
    Size best = new Size(640, 480);
    Size big = null;
    if (map != null) {
      Size[] sizes = map.getOutputSizes(ImageFormat.YUV_420_888);
      int bestScore = Integer.MAX_VALUE;
      for (Size s : sizes) {
        int score = Math.abs(s.getWidth() - 640) + Math.abs(s.getHeight() - 480);
        if (score < bestScore) { bestScore = score; best = s; }
      }
      // the photos: the largest JPEG of the preview's shape (4:3 or 16:9)
      Size[] jpegs = map.getOutputSizes(ImageFormat.JPEG);
      if (jpegs != null) {
        float shape = (float) best.getWidth() / best.getHeight();
        Size largest = null;
        for (Size s : jpegs) {
          long px = (long) s.getWidth() * s.getHeight();
          if (largest == null || px > (long) largest.getWidth() * largest.getHeight()) largest = s;
          boolean same = Math.abs((float) s.getWidth() / s.getHeight() - shape) < 0.05f;
          if (same && (big == null || px > (long) big.getWidth() * big.getHeight())) big = s;
        }
        if (big == null) big = largest;
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
    if (big != null) {
      still = ImageReader.newInstance(big.getWidth(), big.getHeight(), ImageFormat.JPEG, 2);
      still.setOnImageAvailableListener(new ImageReader.OnImageAvailableListener() {
        public void onImageAvailable(ImageReader r) {
          Image im = null;
          String path = stillPath;
          try {
            im = r.acquireNextImage();
            if (im == null) return;
            ByteBuffer b = im.getPlanes()[0].getBuffer();
            byte[] jpeg = new byte[b.remaining()];
            b.get(jpeg);
            if (path.length() > 0) {
              java.io.FileOutputStream o = new java.io.FileOutputStream(path);
              o.write(jpeg);
              o.close();
              stillDone = path;
            }
          } catch (Throwable t) {
            stillDone = "\tThe photo could not be saved: " + t.getMessage();
          } finally {
            stillPath = "";
            if (im != null) im.close();
          }
        }
      }, handler);
    }
    error = "";
    m.openCamera(pick, new CameraDevice.StateCallback() {
      public void onOpened(CameraDevice d) {
        device = d;
        try {
          java.util.List<android.view.Surface> outs = still != null
              ? Arrays.asList(reader.getSurface(), still.getSurface())
              : Arrays.asList(reader.getSurface());
          d.createCaptureSession(outs, new CameraCaptureSession.StateCallback() {
            public void onConfigured(CameraCaptureSession s) {
              session = s;
              try {
                CaptureRequest.Builder rb = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
                rb.addTarget(reader.getSurface());
                apply(rb);
                s.setRepeatingRequest(rb.build(), null, handler);
              } catch (Throwable t) { error = "The camera does not start."; }
            }
            public void onConfigureFailed(CameraCaptureSession s) {
              if (still != null) {
                // (the preview and full-size photos at once refused: the
                // preview alone, a photo taken of it)
                try { still.close(); } catch (Throwable t) { }
                still = null;
                try {
                  device.createCaptureSession(Arrays.asList(reader.getSurface()), this, handler);
                  return;
                } catch (Throwable t) { }
              }
              error = "The camera does not start.";
            }
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
    try { if (still != null) still.close(); } catch (Throwable t) { }
    if (thread != null) thread.quitSafely();
    session = null; device = null; reader = null; still = null; thread = null; handler = null;
    chars = null; stillPath = "";
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
