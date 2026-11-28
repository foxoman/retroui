package org.retro;

import android.app.Activity;
import android.content.Context;
import android.graphics.Rect;
import android.os.Build;
import android.os.Bundle;
import android.view.View;
import android.view.ViewParent;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityManager;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityNodeProvider;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;

/** Screen readers (TalkBack): the app's tree of controls, drawn by the app
 *  itself, as virtual views of the window. The native side sends the tree
 *  after each frame that changed it ("access.update"); what TalkBack asks
 *  (click, focus, set text, a step up or down) goes back through
 *  RetroActivity.nativeAccess. */
public class RetroAccess {
  static final class Node {
    int id, parent, role, states, x, y, w, h, pos, count, caret;
    double lo, hi, now, step;
    String name, value, help;
  }

  // (roles and states as the native side numbers them: uirelays/access.nim)
  static final int R_WINDOW = 0, R_PANE = 1, R_GROUP = 2, R_LABEL = 3, R_BUTTON = 4,
      R_TOGGLE = 5, R_CHECK = 6, R_RADIO = 7, R_FIELD = 8, R_AREA = 9, R_PASSWORD = 10,
      R_COMBO = 11, R_LIST = 12, R_LISTITEM = 13, R_SLIDER = 14, R_SPIN = 15,
      R_PROGRESS = 16, R_SCROLLBAR = 17, R_MENUBAR = 18, R_MENU = 19, R_MENUITEM = 20,
      R_TOOLBAR = 21, R_STATUS = 22, R_TABLIST = 23, R_TAB = 24, R_LINK = 32,
      R_IMAGE = 33, R_HEADING = 34;
  static final int S_FOCUSABLE = 1, S_FOCUSED = 2, S_DISABLED = 4, S_CHECKED = 8,
      S_SELECTED = 32, S_EXPANDABLE = 64, S_EXPANDED = 128, S_READONLY = 256,
      S_PRESSED = 1024, S_MULTILINE = 2048, S_PROTECTED = 4096;
  static final int A_PRESS = 0, A_FOCUS = 1, A_SET = 2, A_UP = 3, A_DOWN = 4;

  static volatile Node[] nodes = new Node[0];
  static volatile int focus = -1;
  static int accessFocus = Integer.MIN_VALUE;   // the node TalkBack reads (its virtual id)
  static View host;
  static Provider provider;
  static boolean watching;

  public static String call(final Activity a, String what, String[] args) throws Exception {
    if (what.equals("enabled")) {
      AccessibilityManager am = (AccessibilityManager) a.getSystemService(Context.ACCESSIBILITY_SERVICE);
      watch(a, am);
      return am != null && am.isEnabled() && am.isTouchExplorationEnabled() ? "1" : "0";
    }
    if (what.equals("update")) {
      final Node[] ns = parse(args[0]);
      final int f = args.length > 1 ? Integer.parseInt(args[1]) : -1;
      a.runOnUiThread(new Runnable() {
        public void run() { update(a, ns, f); }
      });
      return "1";
    }
    return null;
  }

  static void watch(Activity a, AccessibilityManager am) {
    if (watching || am == null) return;
    watching = true;
    // (TalkBack turned on or off later: the native side builds the tree or not)
    am.addAccessibilityStateChangeListener(new AccessibilityManager.AccessibilityStateChangeListener() {
      public void onAccessibilityStateChanged(boolean on) {
        try { RetroActivity.nativeAccess(on ? -1 : -2, 0, null, 0); } catch (Throwable t) { }
      }
    });
  }

  static Node[] parse(String s) {
    ArrayList<Node> out = new ArrayList<Node>();
    for (String rec : s.split("\u001e")) {
      if (rec.length() == 0) continue;
      String[] f = rec.split("\u001f", -1);
      if (f.length < 18) continue;
      Node n = new Node();
      n.id = (int) Long.parseLong(f[0]);
      n.parent = Integer.parseInt(f[1]);
      n.role = Integer.parseInt(f[2]);
      n.states = Integer.parseInt(f[3]);
      n.x = Integer.parseInt(f[4]);
      n.y = Integer.parseInt(f[5]);
      n.w = Integer.parseInt(f[6]);
      n.h = Integer.parseInt(f[7]);
      n.lo = Double.parseDouble(f[8]);
      n.hi = Double.parseDouble(f[9]);
      n.now = Double.parseDouble(f[10]);
      n.step = Double.parseDouble(f[11]);
      n.pos = Integer.parseInt(f[12]);
      n.count = Integer.parseInt(f[13]);
      n.caret = Integer.parseInt(f[14]);
      n.name = f[15];
      n.value = f[16];
      n.help = f[17];
      out.add(n);
    }
    return out.toArray(new Node[0]);
  }

  static int indexOf(int vid) {
    Node[] ns = nodes;
    for (int i = 0; i < ns.length; i++) if (ns[i].id == vid) return i;
    return -1;
  }

  static void update(Activity a, Node[] ns, int f) {
    if (host == null) {
      host = a.getWindow().getDecorView();
      provider = new Provider();
      host.setAccessibilityDelegate(new View.AccessibilityDelegate() {
        public AccessibilityNodeProvider getAccessibilityNodeProvider(View v) { return provider; }
      });
      host.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_YES);
    }
    Node[] old = nodes;
    int oldFocus = focus >= 0 && focus < old.length ? old[focus].id : 0;
    nodes = ns;
    focus = f;
    // what changed, told
    boolean shape = old.length != ns.length;
    for (int i = 0; !shape && i < ns.length; i++)
      if (old[i].id != ns[i].id || old[i].parent != ns[i].parent) shape = true;
    if (shape) send(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED, View.NO_ID);
    HashMap<Integer, Node> was = new HashMap<Integer, Node>();
    for (Node n : old) was.put(n.id, n);
    for (Node n : ns) {
      Node o = was.get(n.id);
      if (o == null) continue;
      if (!o.value.equals(n.value) && n.role != R_PASSWORD) send(AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED, n.id);
      else if (o.now != n.now || o.states != n.states || !o.name.equals(n.name))
        send(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED, n.id);
    }
    int nowFocus = f >= 0 && f < ns.length ? ns[f].id : 0;
    if (nowFocus != oldFocus && nowFocus != 0) send(AccessibilityEvent.TYPE_VIEW_FOCUSED, nowFocus);
  }

  static void send(int type, int vid) {
    if (host == null) return;
    ViewParent p = host.getParent();
    AccessibilityEvent e = AccessibilityEvent.obtain(type);
    e.setPackageName(host.getContext().getPackageName());
    if (vid == View.NO_ID) e.setSource(host);
    else {
      e.setSource(host, vid);
      int i = indexOf(vid);
      if (i >= 0) {
        Node n = nodes[i];
        e.setClassName(className(n.role));
        e.getText().add(textOf(n));
        if (n.role == R_PASSWORD) e.setPassword(true);
        if (type == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED && Build.VERSION.SDK_INT >= 19)
          e.setContentChangeTypes(AccessibilityEvent.CONTENT_CHANGE_TYPE_SUBTREE);
      }
    }
    if (p != null) p.requestSendAccessibilityEvent(host, e);
  }

  static String className(int role) {
    switch (role) {
      case R_BUTTON: case R_MENUITEM: case R_MENU: return "android.widget.Button";
      case R_TOGGLE: return "android.widget.ToggleButton";
      case R_CHECK: return "android.widget.CheckBox";
      case R_RADIO: case R_TAB: return "android.widget.RadioButton";
      case R_FIELD: case R_AREA: case R_PASSWORD: return "android.widget.EditText";
      case R_COMBO: return "android.widget.Spinner";
      case R_LIST: return "android.widget.ListView";
      case R_SLIDER: return "android.widget.SeekBar";
      case R_SPIN: return "android.widget.NumberPicker";
      case R_PROGRESS: return "android.widget.ProgressBar";
      case R_IMAGE: return "android.widget.ImageView";
      case R_TOOLBAR: case R_MENUBAR: case R_GROUP: case R_PANE: case R_TABLIST:
        return "android.view.ViewGroup";
      default: return "android.widget.TextView";
    }
  }

  static String textOf(Node n) {
    switch (n.role) {
      case R_FIELD: case R_AREA: return n.value;
      case R_PASSWORD: return "";
      case R_COMBO: return n.value.length() > 0 ? n.value : n.name;
      default: return n.name;
    }
  }

  static final class Provider extends AccessibilityNodeProvider {
    @Override
    public AccessibilityNodeInfo createAccessibilityNodeInfo(int vid) {
      Node[] ns = nodes;
      if (vid == View.NO_ID) {
        AccessibilityNodeInfo info = AccessibilityNodeInfo.obtain(host);
        host.onInitializeAccessibilityNodeInfo(info);
        for (int k = 1; k < ns.length; k++)
          if (ns[k].parent <= 0) info.addChild(host, ns[k].id);
        return info;
      }
      int i = indexOf(vid);
      if (i < 0) return null;
      Node n = ns[i];
      AccessibilityNodeInfo info = AccessibilityNodeInfo.obtain(host, vid);
      info.setPackageName(host.getContext().getPackageName());
      info.setClassName(className(n.role));
      if (n.parent > 0 && n.parent < ns.length) info.setParent(host, ns[n.parent].id);
      else info.setParent(host);
      for (int k = 1; k < ns.length; k++)
        if (ns[k].parent == i && k != i) info.addChild(host, ns[k].id);
      String t = textOf(n);
      if (n.role == R_FIELD || n.role == R_AREA || n.role == R_PASSWORD) {
        info.setText(t);
        info.setEditable((n.states & S_READONLY) == 0);
        info.setContentDescription(n.name);
        info.setPassword(n.role == R_PASSWORD);
        info.setMultiLine((n.states & S_MULTILINE) != 0);
        if (Build.VERSION.SDK_INT >= 21 && (n.states & S_READONLY) == 0)
          info.addAction(AccessibilityNodeInfo.ACTION_SET_TEXT);
      } else if (n.role == R_COMBO) {
        info.setText(t);
        info.setContentDescription(n.name.length() > 0 ? n.name + ", " + n.value : n.value);
      } else {
        info.setText(t);
      }
      int[] loc = new int[2];
      host.getLocationOnScreen(loc);
      Rect r = new Rect(n.x, n.y, n.x + n.w, n.y + n.h);
      r.offset(RetroActivity.surfaceX, RetroActivity.surfaceY);   // (the picture's place in the window)
      info.setBoundsInParent(r);
      Rect sr = new Rect(r);
      sr.offset(loc[0], loc[1]);
      info.setBoundsInScreen(sr);
      info.setVisibleToUser(true);
      info.setEnabled((n.states & S_DISABLED) == 0);
      info.setFocusable((n.states & S_FOCUSABLE) != 0);
      info.setFocused((n.states & S_FOCUSED) != 0);
      info.setSelected((n.states & S_SELECTED) != 0);
      boolean checkable = n.role == R_CHECK || n.role == R_RADIO || n.role == R_TOGGLE;
      info.setCheckable(checkable);
      info.setChecked((n.states & (S_CHECKED | S_PRESSED)) != 0);
      boolean clickable = n.role == R_BUTTON || n.role == R_TOGGLE || checkable || n.role == R_COMBO ||
          n.role == R_LISTITEM || n.role == R_MENUITEM || n.role == R_MENU || n.role == R_TAB || n.role == R_LINK;
      info.setClickable(clickable);
      if (clickable) info.addAction(AccessibilityNodeInfo.ACTION_CLICK);
      if ((n.states & S_FOCUSABLE) != 0) info.addAction(AccessibilityNodeInfo.ACTION_FOCUS);
      info.setAccessibilityFocused(vid == accessFocus);
      info.addAction(vid == accessFocus ? AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS
                                        : AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS);
      if (n.role == R_SLIDER || n.role == R_SPIN || n.role == R_PROGRESS) {
        if (Build.VERSION.SDK_INT >= 19)
          info.setRangeInfo(AccessibilityNodeInfo.RangeInfo.obtain(
              AccessibilityNodeInfo.RangeInfo.RANGE_TYPE_FLOAT, (float) n.lo, (float) n.hi, (float) n.now));
        if (n.role != R_PROGRESS) {
          info.addAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD);
          info.addAction(AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD);
        }
      }
      return info;
    }

    @Override
    public boolean performAction(int vid, int action, Bundle args) {
      if (vid == View.NO_ID) return host.performAccessibilityAction(action, args);
      if (indexOf(vid) < 0) return false;
      int ask = -1;
      String text = null;
      switch (action) {
        case AccessibilityNodeInfo.ACTION_CLICK: ask = A_PRESS; break;
        case AccessibilityNodeInfo.ACTION_FOCUS: ask = A_FOCUS; break;
        case AccessibilityNodeInfo.ACTION_SCROLL_FORWARD: ask = A_UP; break;
        case AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD: ask = A_DOWN; break;
        case AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS:
          accessFocus = vid;
          send(AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUSED, vid);
          return true;
        case AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS:
          if (accessFocus == vid) accessFocus = Integer.MIN_VALUE;
          send(AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUS_CLEARED, vid);
          return true;
        default:
          if (Build.VERSION.SDK_INT >= 21 && action == AccessibilityNodeInfo.ACTION_SET_TEXT && args != null) {
            CharSequence cs = args.getCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE);
            text = cs == null ? "" : cs.toString();
            ask = A_SET;
          }
      }
      if (ask < 0) return false;
      try { RetroActivity.nativeAccess(ask, vid, text, 0); } catch (Throwable t) { return false; }
      return true;
    }

    @Override
    public AccessibilityNodeInfo findFocus(int kind) {
      if (kind == AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)
        return accessFocus == Integer.MIN_VALUE ? null : createAccessibilityNodeInfo(accessFocus);
      Node[] ns = nodes;
      int f = focus;
      return f > 0 && f < ns.length ? createAccessibilityNodeInfo(ns[f].id) : null;
    }
  }
}
