package org.retro;

import android.app.Activity;
import android.content.Context;
import android.text.InputType;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;

/** The keyboard's way in: a view of no size that takes the keyboard's input
 *  connection, so a keyboard works as with any text box -- suggestions,
 *  swipe typing, voice typing, what it composes (shown by the app in its
 *  text box, RetroActivity.nativeCompose) and what it settles on
 *  (RetroActivity.nativeText). Its keys (delete, Enter) go to the app as
 *  keys (RetroActivity.nativeKey). */
public class RetroInput extends View {
  String composing = "";
  static int kind, enter;     // the keyboard the field wants, its Enter key (setKind)

  RetroInput(Context c) {
    super(c);
    setFocusable(true);
    setFocusableInTouchMode(true);
  }

  @Override
  public boolean onCheckIsTextEditor() { return true; }

  @Override
  public InputConnection onCreateInputConnection(EditorInfo out) {
    switch (kind) {
      case 1: out.inputType = InputType.TYPE_CLASS_NUMBER; break;
      case 2: out.inputType = InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_DECIMAL
                              | InputType.TYPE_NUMBER_FLAG_SIGNED; break;
      case 3: out.inputType = InputType.TYPE_CLASS_PHONE; break;
      case 4: out.inputType = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS; break;
      case 5: out.inputType = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI; break;
      case 6: out.inputType = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD; break;
      default: out.inputType = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_AUTO_CORRECT;
    }
    int action;
    switch (enter) {
      case 1: action = EditorInfo.IME_ACTION_NEXT; break;
      case 2: action = EditorInfo.IME_ACTION_DONE; break;
      case 3: action = EditorInfo.IME_ACTION_SEARCH; break;
      case 4: action = EditorInfo.IME_ACTION_GO; break;
      default: action = EditorInfo.IME_ACTION_NONE;
    }
    out.imeOptions = EditorInfo.IME_FLAG_NO_FULLSCREEN | EditorInfo.IME_FLAG_NO_EXTRACT_UI | action;
    if (kind == 6) out.imeOptions |= 0x1000000;   // IME_FLAG_NO_PERSONALIZED_LEARNING
    return new Connection(this);
  }

  /** The keyboard the field wants now: shown so from now on (on the UI thread). */
  static void setKind(Activity a, int k, int e) {
    if (k == kind && e == enter) return;
    kind = k;
    enter = e;
    if (view == null || !view.hasFocus()) return;
    InputMethodManager imm = (InputMethodManager) a.getSystemService(Context.INPUT_METHOD_SERVICE);
    if (imm != null) imm.restartInput(view);
  }

  final class Connection extends BaseInputConnection {
    Connection(View v) { super(v, false); }

    @Override
    public boolean commitText(CharSequence text, int cursor) {
      composing = "";
      try {
        RetroActivity.nativeCompose("", 0);
        if (text != null && text.length() > 0) RetroActivity.nativeText(text.toString());
      } catch (Throwable t) { return false; }
      return true;
    }

    @Override
    public boolean setComposingText(CharSequence text, int cursor) {
      composing = text == null ? "" : text.toString();
      try { RetroActivity.nativeCompose(composing, composing.length()); } catch (Throwable t) { return false; }
      return true;
    }

    @Override
    public boolean finishComposingText() {
      // (what it composed is settled as it is)
      String s = composing;
      composing = "";
      try {
        RetroActivity.nativeCompose("", 0);
        if (s.length() > 0) RetroActivity.nativeText(s);
      } catch (Throwable t) { return false; }
      return true;
    }

    @Override
    public boolean deleteSurroundingText(int before, int after) {
      try {
        for (int i = 0; i < before; i++) {
          RetroActivity.nativeKey(KeyEvent.KEYCODE_DEL, true);
          RetroActivity.nativeKey(KeyEvent.KEYCODE_DEL, false);
        }
        for (int i = 0; i < after; i++) {
          RetroActivity.nativeKey(KeyEvent.KEYCODE_FORWARD_DEL, true);
          RetroActivity.nativeKey(KeyEvent.KEYCODE_FORWARD_DEL, false);
        }
      } catch (Throwable t) { return false; }
      return true;
    }

    @Override
    public boolean sendKeyEvent(KeyEvent e) {
      if (e.getAction() != KeyEvent.ACTION_DOWN && e.getAction() != KeyEvent.ACTION_UP) return false;
      try { RetroActivity.nativeKey(e.getKeyCode(), e.getAction() == KeyEvent.ACTION_DOWN); }
      catch (Throwable t) { return false; }
      return true;
    }

    /** The keyboard's action key (Next, Done, Search, Go): Next as Tab -- the next field --,
     *  the others as Enter. */
    @Override
    public boolean performEditorAction(int action) {
      int code = action == EditorInfo.IME_ACTION_NEXT ? KeyEvent.KEYCODE_TAB : KeyEvent.KEYCODE_ENTER;
      try {
        RetroActivity.nativeKey(code, true);
        RetroActivity.nativeKey(code, false);
      } catch (Throwable t) { return false; }
      return true;
    }

    @Override
    public CharSequence getTextBeforeCursor(int n, int flags) { return ""; }

    @Override
    public CharSequence getTextAfterCursor(int n, int flags) { return ""; }
  }

  static RetroInput view;

  /** Show or hide the keyboard (on the UI thread). */
  static void show(Activity a, boolean on) {
    InputMethodManager imm = (InputMethodManager) a.getSystemService(Context.INPUT_METHOD_SERVICE);
    if (imm == null) return;
    if (view == null) {
      view = new RetroInput(a);
      a.addContentView(view, new ViewGroup.LayoutParams(1, 1));
    }
    if (on) {
      view.requestFocus();
      imm.restartInput(view);
      imm.showSoftInput(view, 0);
    } else {
      if (view.composing.length() > 0) {
        // (what was being composed stays: settled)
        String s = view.composing;
        view.composing = "";
        try {
          RetroActivity.nativeCompose("", 0);
          RetroActivity.nativeText(s);
        } catch (Throwable t) { }
      }
      imm.hideSoftInputFromWindow(view.getWindowToken(), 0);
      view.clearFocus();
    }
  }
}
