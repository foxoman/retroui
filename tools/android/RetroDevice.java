package org.retro;

import android.app.Activity;
import android.app.KeyguardManager;
import android.content.ClipData;
import android.content.ClipDescription;
import android.content.Context;
import android.content.Intent;
import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.net.Uri;
import android.os.Build;
import android.view.DragEvent;
import android.view.View;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;

/** The device's features of retroui/device that need Java: the links the app is opened with,
 *  the screen lock asked (fingerprint, face or PIN), the motion sensors, picture in picture,
 *  drag and drop with other apps, and purchases through the Play Billing library the app brings
 *  (--java with its classes; reached by reflection, so the kit builds without it). Called from
 *  Nim through RetroNative (javaStatic "org.retro.RetroDevice"). */
public class RetroDevice {
  // ---- links ----
  static final java.util.ArrayList<String> links = new java.util.ArrayList<String>();

  /** (RetroActivity: an intent came -- its link kept when it is a VIEW of one) */
  static void takeLink(Intent i) {
    if (i == null || !Intent.ACTION_VIEW.equals(i.getAction())) return;
    String d = i.getDataString();
    if (d == null) return;
    // (a file opened is sharedIn's: content: and file: are not links)
    if (d.startsWith("content:") || d.startsWith("file:")) return;
    synchronized (links) { links.add(d); }
  }

  public static String takeLink() {
    synchronized (links) { return links.isEmpty() ? "" : links.remove(0); }
  }

  // ---- the screen lock ----
  static final int ASK_LOCK = 0x5e7;
  static volatile int lockResult = 0;   // 0 none, 1 asking, 2 ok, 3 failed or cancelled, 4 none set

  public static String askLock(final Activity a, final String title, final String reason) {
    final KeyguardManager km = (KeyguardManager) a.getSystemService(Context.KEYGUARD_SERVICE);
    if (km == null || !km.isKeyguardSecure()) { lockResult = 4; return "0"; }
    lockResult = 1;
    a.runOnUiThread(new Runnable() { public void run() {
      try {
        Intent i = km.createConfirmDeviceCredentialIntent(title, reason);
        if (i == null) { lockResult = 4; return; }
        a.startActivityForResult(i, ASK_LOCK);
      } catch (Throwable t) { lockResult = 3; }
    }});
    return "1";
  }

  public static String lockResult() { return Integer.toString(lockResult); }

  public static String lockAvailable(Activity a) {
    KeyguardManager km = (KeyguardManager) a.getSystemService(Context.KEYGUARD_SERVICE);
    return km != null && km.isKeyguardSecure() ? "1" : "0";
  }

  /** (RetroActivity's onActivityResult: true when it was the screen lock's) */
  static boolean onResult(int request, int result) {
    if (request != ASK_LOCK) return false;
    lockResult = result == Activity.RESULT_OK ? 2 : 3;
    return true;
  }

  // ---- motion ----
  static SensorManager sm;
  static final float[] gravity = new float[3];
  static final float[] accel = new float[3];
  static volatile long shakeAt = 0;
  static long lastJolt = 0;
  static int jolts = 0;
  static final SensorEventListener listener = new SensorEventListener() {
    public void onSensorChanged(SensorEvent e) {
      if (e.sensor.getType() == Sensor.TYPE_ACCELEROMETER) {
        synchronized (gravity) {
          for (int k = 0; k < 3; k++) {
            gravity[k] = 0.9f * gravity[k] + 0.1f * e.values[k];
            accel[k] = e.values[k] - gravity[k];
          }
        }
        // (a shake: three hard jolts within a second)
        float f = (float) Math.sqrt(accel[0] * accel[0] + accel[1] * accel[1] + accel[2] * accel[2]);
        long now = System.currentTimeMillis();
        if (f > 12f) {
          if (now - lastJolt > 1000) jolts = 0;
          lastJolt = now;
          if (++jolts >= 3) { shakeAt = now; jolts = 0; }
        }
      }
    }
    public void onAccuracyChanged(Sensor s, int a) { }
  };

  public static String startMotion(Activity a) {
    if (sm == null) sm = (SensorManager) a.getSystemService(Context.SENSOR_SERVICE);
    if (sm == null) return "0";
    Sensor s = sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER);
    if (s == null) return "0";
    sm.registerListener(listener, s, SensorManager.SENSOR_DELAY_GAME);
    return "1";
  }

  public static String stopMotion() {
    if (sm != null) sm.unregisterListener(listener);
    return "1";
  }

  /** "gx gy gz ax ay az shakeAt": the pull of gravity, the jolt, the last shake */
  public static String motion() {
    synchronized (gravity) {
      return gravity[0] + " " + gravity[1] + " " + gravity[2] + " " + accel[0] + " " + accel[1] + " " +
             accel[2] + " " + shakeAt;
    }
  }

  // ---- picture in picture ----
  public static String enterPip(final Activity a) {
    if (Build.VERSION.SDK_INT < 24) return "0";
    a.runOnUiThread(new Runnable() { public void run() {
      try { Activity.class.getMethod("enterPictureInPictureMode").invoke(a); } catch (Throwable t) { }
    }});
    return "1";
  }

  public static String inPip(Activity a) {
    if (Build.VERSION.SDK_INT < 24) return "0";
    try { return ((Boolean) Activity.class.getMethod("isInPictureInPictureMode").invoke(a)) ? "1" : "0"; }
    catch (Throwable t) { return "0"; }
  }

  // ---- drag and drop with other apps ----
  static final java.util.ArrayList<String> drops = new java.util.ArrayList<String>();
  static volatile int dropX, dropY;

  /** (RetroActivity: what other apps drop on the app's picture -- files copied in, text) */
  static void listenDrops(final RetroActivity a, View v) {
    v.setOnDragListener(new View.OnDragListener() {
      public boolean onDrag(View view, DragEvent e) {
        switch (e.getAction()) {
          case DragEvent.ACTION_DRAG_STARTED:
            return true;
          case DragEvent.ACTION_DROP:
            final ClipData c = e.getClipData();
            if (c == null) return false;
            dropX = (int) e.getX();
            dropY = (int) e.getY();
            try { Activity.class.getMethod("requestDragAndDropPermissions", DragEvent.class).invoke(a, e); }
            catch (Throwable t) { }
            new Thread(new Runnable() { public void run() {
              StringBuilder b = new StringBuilder();
              for (int k = 0; k < c.getItemCount(); k++) {
                ClipData.Item it = c.getItemAt(k);
                String line = null;
                if (it.getUri() != null) {
                  String p = a.copyIn(it.getUri(), "dropped");
                  if (p != null) line = "f" + p;
                } else if (it.getText() != null) line = "t" + it.getText().toString().replace('\n', '\u0001');
                if (line == null) continue;
                if (b.length() > 0) b.append('\n');
                b.append(line);
              }
              if (b.length() > 0) synchronized (drops) { drops.add(b.toString()); }
            }}).start();
            return true;
          default:
            return true;
        }
      }
    });
  }

  /** "x y\nf/path\nttext...": one drop, or "" */
  public static String takeDrop() {
    synchronized (drops) {
      if (drops.isEmpty()) return "";
      return dropX + " " + dropY + "\n" + drops.remove(0);
    }
  }

  /** Drags `paths` (files of the app, handed out by RetroFiles) or `text` to other apps (another
   *  app beside it, split screen): from the picture, where the finger is. */
  public static String dragOut(final RetroActivity a, final String paths, final String text) {
    if (Build.VERSION.SDK_INT < 24 || a.surface == null) return "0";
    a.runOnUiThread(new Runnable() { public void run() {
      try {
        ClipData clip = null;
        if (paths != null && paths.length() > 0) {
          for (String p : paths.split("\n")) {
            Uri u = new Uri.Builder().scheme("content").authority(a.getPackageName() + ".files").path(p).build();
            if (clip == null) clip = ClipData.newUri(a.getContentResolver(), new java.io.File(p).getName(), u);
            else clip.addItem(new ClipData.Item(u));
          }
        } else if (text != null) clip = ClipData.newPlainText("text", text);
        if (clip == null) return;
        int flags = 0x100 | 0x1;     // DRAG_FLAG_GLOBAL, DRAG_FLAG_GLOBAL_URI_READ
        View.class.getMethod("startDragAndDrop", ClipData.class, View.DragShadowBuilder.class, Object.class, int.class)
            .invoke(a.surface, clip, new View.DragShadowBuilder(a.surface) {
              public void onProvideShadowMetrics(android.graphics.Point size, android.graphics.Point touch) {
                size.set(96, 96);
                touch.set(48, 48);
              }
              public void onDrawShadow(android.graphics.Canvas c) {
                android.graphics.Paint p = new android.graphics.Paint();
                p.setColor(0xC0FFFFFF);
                c.drawRoundRect(new android.graphics.RectF(0, 0, 96, 96), 18, 18, p);
                p.setColor(0xFF2F6FE0);
                c.drawRoundRect(new android.graphics.RectF(28, 20, 68, 76), 6, 6, p);
              }
            }, null, flags);
      } catch (Throwable t) { }
    }});
    return "1";
  }

  // ---- purchases (the app's own Play Billing library, by reflection) ----
  static Object billing;                      // com.android.billingclient.api.BillingClient
  static volatile int billingState = 0;       // 0 none, 1 connecting, 2 ready, 3 not there
  static final java.util.ArrayList<String> billingEvents = new java.util.ArrayList<String>();
  static final java.util.HashMap<String, Object> products = new java.util.HashMap<String, Object>();

  static Class<?> bc(String n) throws ClassNotFoundException {
    return Class.forName("com.android.billingclient.api." + n);
  }

  static void event(String s) { synchronized (billingEvents) { billingEvents.add(s); } }

  static String purchaseLine(Object p) throws Exception {
    // "p" token \t state \t products (comma) \t order id
    java.util.List<?> ids = (java.util.List<?>) p.getClass().getMethod("getProducts").invoke(p);
    StringBuilder b = new StringBuilder();
    for (Object o : ids) { if (b.length() > 0) b.append(','); b.append(o); }
    return "p" + p.getClass().getMethod("getPurchaseToken").invoke(p) + "\t" +
           p.getClass().getMethod("getPurchaseState").invoke(p) + "\t" + b + "\t" +
           p.getClass().getMethod("getOrderId").invoke(p);
  }

  public static String billingStart(final Activity a) {
    if (billing != null) return Integer.toString(billingState);
    try {
      final Class<?> listener = bc("PurchasesUpdatedListener");
      Object updated = Proxy.newProxyInstance(listener.getClassLoader(), new Class<?>[] { listener },
        new InvocationHandler() {
          public Object invoke(Object proxy, Method m, Object[] args) throws Throwable {
            if (m.getName().equals("onPurchasesUpdated")) {
              int code = (Integer) args[0].getClass().getMethod("getResponseCode").invoke(args[0]);
              if (code == 0 && args[1] != null)
                for (Object p : (java.util.List<?>) args[1]) event(purchaseLine(p));
              else event("e" + code);
            }
            return null;
          }
        });
      Object builder = bc("BillingClient").getMethod("newBuilder", Context.class).invoke(null, a);
      builder = builder.getClass().getMethod("setListener", listener).invoke(builder, updated);
      try { builder = builder.getClass().getMethod("enablePendingPurchases").invoke(builder); }
      catch (NoSuchMethodException e) { }
      billing = builder.getClass().getMethod("build").invoke(builder);
      final Class<?> stateL = bc("BillingClientStateListener");
      Object st = Proxy.newProxyInstance(stateL.getClassLoader(), new Class<?>[] { stateL },
        new InvocationHandler() {
          public Object invoke(Object proxy, Method m, Object[] args) throws Throwable {
            if (m.getName().equals("onBillingSetupFinished")) {
              int code = (Integer) args[0].getClass().getMethod("getResponseCode").invoke(args[0]);
              billingState = code == 0 ? 2 : 3;
            } else if (m.getName().equals("onBillingServiceDisconnected")) billingState = 0;
            return null;
          }
        });
      billingState = 1;
      billing.getClass().getMethod("startConnection", stateL).invoke(billing, st);
    } catch (Throwable t) { billingState = 3; billing = null; }
    return Integer.toString(billingState);
  }

  /** Asks for the products `ids` (comma separated) of `type` ("inapp", "subs"): their lines come as
   *  events "i" id \t title \t price \t description. */
  public static String billingProducts(final String ids, final String type) {
    if (billing == null || billingState != 2) return "0";
    try {
      Class<?> prodC = bc("QueryProductDetailsParams$Product");
      java.util.ArrayList<Object> list = new java.util.ArrayList<Object>();
      for (String id : ids.split(",")) {
        Object pb = prodC.getMethod("newBuilder").invoke(null);
        pb = pb.getClass().getMethod("setProductId", String.class).invoke(pb, id.trim());
        pb = pb.getClass().getMethod("setProductType", String.class).invoke(pb, type);
        list.add(pb.getClass().getMethod("build").invoke(pb));
      }
      Object qb = bc("QueryProductDetailsParams").getMethod("newBuilder").invoke(null);
      qb = qb.getClass().getMethod("setProductList", java.util.List.class).invoke(qb, list);
      Object params = qb.getClass().getMethod("build").invoke(qb);
      final Class<?> respL = bc("ProductDetailsResponseListener");
      Object l = Proxy.newProxyInstance(respL.getClassLoader(), new Class<?>[] { respL },
        new InvocationHandler() {
          public Object invoke(Object proxy, Method m, Object[] args) throws Throwable {
            if (!m.getName().equals("onProductDetailsResponse")) return null;
            Object details = args[1];
            java.util.List<?> got = details instanceof java.util.List ? (java.util.List<?>) details
                : (java.util.List<?>) details.getClass().getMethod("getProductDetailsList").invoke(details);
            for (Object d : got) {
              String id = (String) d.getClass().getMethod("getProductId").invoke(d);
              synchronized (products) { products.put(id, d); }
              String price = "";
              try {
                Object o = d.getClass().getMethod("getOneTimePurchaseOfferDetails").invoke(d);
                if (o != null) price = (String) o.getClass().getMethod("getFormattedPrice").invoke(o);
              } catch (Throwable t) { }
              event("i" + id + "\t" + d.getClass().getMethod("getTitle").invoke(d) + "\t" + price + "\t" +
                    d.getClass().getMethod("getDescription").invoke(d));
            }
            return null;
          }
        });
      billing.getClass().getMethod("queryProductDetailsAsync", params.getClass(), respL).invoke(billing, params, l);
      return "1";
    } catch (Throwable t) { return "0"; }
  }

  /** Opens the system's sheet to buy the product `id` (asked with billingProducts first). */
  public static String billingBuy(final Activity a, final String id) {
    final Object d;
    synchronized (products) { d = products.get(id); }
    if (billing == null || d == null) return "0";
    a.runOnUiThread(new Runnable() { public void run() {
      try {
        Class<?> pp = bc("BillingFlowParams$ProductDetailsParams");
        Object b = pp.getMethod("newBuilder").invoke(null);
        b = b.getClass().getMethod("setProductDetails", bc("ProductDetails")).invoke(b, d);
        try {
          java.util.List<?> offers = (java.util.List<?>) d.getClass().getMethod("getSubscriptionOfferDetails").invoke(d);
          if (offers != null && !offers.isEmpty()) {
            Object tok = offers.get(0).getClass().getMethod("getOfferToken").invoke(offers.get(0));
            b = b.getClass().getMethod("setOfferToken", String.class).invoke(b, tok);
          }
        } catch (Throwable t) { }
        Object pdp = b.getClass().getMethod("build").invoke(b);
        java.util.ArrayList<Object> list = new java.util.ArrayList<Object>();
        list.add(pdp);
        Object fb = bc("BillingFlowParams").getMethod("newBuilder").invoke(null);
        fb = fb.getClass().getMethod("setProductDetailsParamsList", java.util.List.class).invoke(fb, list);
        Object params = fb.getClass().getMethod("build").invoke(fb);
        billing.getClass().getMethod("launchBillingFlow", Activity.class, params.getClass()).invoke(billing, a, params);
      } catch (Throwable t) { event("e-1"); }
    }});
    return "1";
  }

  /** Says a purchase was given (its `token`): consumed -- bought again later -- or acknowledged. */
  public static String billingFinish(final String token, final boolean consume) {
    if (billing == null) return "0";
    try {
      String kind = consume ? "Consume" : "AcknowledgePurchase";
      Object b = bc(kind + "Params").getMethod("newBuilder").invoke(null);
      b = b.getClass().getMethod("setPurchaseToken", String.class).invoke(b, token);
      Object params = b.getClass().getMethod("build").invoke(b);
      final Class<?> l = bc(consume ? "ConsumeResponseListener" : "AcknowledgePurchaseResponseListener");
      Object proxy = Proxy.newProxyInstance(l.getClassLoader(), new Class<?>[] { l },
        new InvocationHandler() { public Object invoke(Object p, Method m, Object[] a) { return null; } });
      billing.getClass().getMethod(consume ? "consumeAsync" : "acknowledgePurchase", params.getClass(), l)
          .invoke(billing, params, proxy);
      return "1";
    } catch (Throwable t) { return "0"; }
  }

  /** The purchases the user has (bought before, on another phone): events "p"... as they come. */
  public static String billingOwned(final String type) {
    if (billing == null || billingState != 2) return "0";
    try {
      Object b = bc("QueryPurchasesParams").getMethod("newBuilder").invoke(null);
      b = b.getClass().getMethod("setProductType", String.class).invoke(b, type);
      Object params = b.getClass().getMethod("build").invoke(b);
      final Class<?> l = bc("PurchasesResponseListener");
      Object proxy = Proxy.newProxyInstance(l.getClassLoader(), new Class<?>[] { l },
        new InvocationHandler() {
          public Object invoke(Object p, Method m, Object[] args) throws Throwable {
            if (m.getName().equals("onQueryPurchasesResponse") && args[1] != null)
              for (Object o : (java.util.List<?>) args[1]) event(purchaseLine(o));
            return null;
          }
        });
      billing.getClass().getMethod("queryPurchasesAsync", params.getClass(), l).invoke(billing, params, proxy);
      return "1";
    } catch (Throwable t) { return "0"; }
  }

  public static String billingState() { return Integer.toString(billingState); }

  public static String billingEvent() {
    synchronized (billingEvents) { return billingEvents.isEmpty() ? "" : billingEvents.remove(0); }
  }
}
