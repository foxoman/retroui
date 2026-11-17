package org.retro;

import android.app.Activity;
import android.content.Context;
import android.view.textservice.SentenceSuggestionsInfo;
import android.view.textservice.SpellCheckerSession;
import android.view.textservice.SuggestionsInfo;
import android.view.textservice.TextInfo;
import android.view.textservice.TextServicesManager;
import java.util.Locale;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** The phone's spell checker (its keyboard's: Gboard's, Samsung's...) for retro's spell module
 *  (src/retroui/spell.nim). The native side calls, from the app's thread:
 *  "spell.available" -> "1" when the device has one; "spell.check" words (tab-separated), a
 *  language tag -> a "1" (right) or "0" (wrong) for each; "spell.suggest" a word, a language ->
 *  its suggestions, tab-separated; "spell.language" -> the phone's language. The session is made
 *  on the UI thread, whose looper its answers come on: each request waited for, two seconds at
 *  most (then the words count as right). */
public class RetroSpell {
  private static SpellCheckerSession session;
  private static String sessionLang = null;
  private static CountDownLatch latch;
  private static SentenceSuggestionsInfo[] answer;

  private static final SpellCheckerSession.SpellCheckerSessionListener listener =
      new SpellCheckerSession.SpellCheckerSessionListener() {
        public void onGetSuggestions(SuggestionsInfo[] results) { }
        public void onGetSentenceSuggestions(SentenceSuggestionsInfo[] results) {
          answer = results;
          CountDownLatch l = latch;
          if (l != null) l.countDown();
        }
      };

  private static TextServicesManager manager(Activity a) {
    return (TextServicesManager) a.getSystemService(Context.TEXT_SERVICES_MANAGER_SERVICE);
  }

  /** (the session for `lang`: made on the UI thread the first time, or when the language changes) */
  private static SpellCheckerSession sessionFor(final Activity a, final String lang) throws Exception {
    if (session != null && lang.equals(sessionLang)) return session;
    final SpellCheckerSession old = session;
    final SpellCheckerSession[] made = new SpellCheckerSession[1];
    final CountDownLatch done = new CountDownLatch(1);
    a.runOnUiThread(new Runnable() {
      public void run() {
        try {
          if (old != null) old.close();
          TextServicesManager tsm = manager(a);
          if (tsm != null) {
            Locale loc = lang.length() > 0 ? Locale.forLanguageTag(lang) : Locale.getDefault();
            made[0] = tsm.newSpellCheckerSession(null, loc, listener, false);
          }
        } catch (Throwable t) { }
        done.countDown();
      }
    });
    done.await(2, TimeUnit.SECONDS);
    session = made[0];
    sessionLang = lang;
    return session;
  }

  /** (each word's answer: the pieces of it the checker found, as many as it gave) */
  private static synchronized SentenceSuggestionsInfo[] ask(final Activity a, String lang, String[] words,
                                                            final int limit) throws Exception {
    final SpellCheckerSession s = sessionFor(a, lang);
    if (s == null) return null;
    final TextInfo[] infos = new TextInfo[words.length];
    for (int i = 0; i < words.length; i++) infos[i] = new TextInfo(words[i], 0, i);
    latch = new CountDownLatch(1);
    answer = null;
    a.runOnUiThread(new Runnable() {
      public void run() {
        try { s.getSentenceSuggestions(infos, limit); } catch (Throwable t) { latch.countDown(); }
      }
    });
    if (!latch.await(2, TimeUnit.SECONDS)) return null;
    return answer;
  }

  private static boolean typo(SentenceSuggestionsInfo r) {
    if (r == null) return false;
    for (int k = 0; k < r.getSuggestionsCount(); k++) {
      SuggestionsInfo si = r.getSuggestionsInfoAt(k);
      if (si == null) continue;
      int at = si.getSuggestionsAttributes();
      if ((at & SuggestionsInfo.RESULT_ATTR_LOOKS_LIKE_TYPO) != 0 &&
          (at & SuggestionsInfo.RESULT_ATTR_IN_THE_DICTIONARY) == 0) return true;
    }
    return false;
  }

  public static String call(final Activity a, String what, final String[] args) throws Exception {
    if (what.equals("available")) {
      TextServicesManager tsm = manager(a);
      if (tsm == null) return "0";
      return sessionFor(a, "") != null ? "1" : "0";
    }
    if (what.equals("language")) return Locale.getDefault().toLanguageTag();
    if (what.equals("check")) {
      String[] words = args.length > 0 ? args[0].split("\u0001", -1) : new String[0];
      String lang = args.length > 1 ? args[1] : "";
      StringBuilder b = new StringBuilder();
      SentenceSuggestionsInfo[] r = words.length > 0 ? ask(a, lang, words, 0) : null;
      for (int i = 0; i < words.length; i++) {
        SentenceSuggestionsInfo ri = r != null && i < r.length ? r[i] : null;
        b.append(typo(ri) ? '0' : '1');
      }
      return b.toString();
    }
    if (what.equals("suggest")) {
      if (args.length < 1 || args[0].length() == 0) return "";
      String lang = args.length > 1 ? args[1] : "";
      SentenceSuggestionsInfo[] r = ask(a, lang, new String[] { args[0] }, 6);
      StringBuilder b = new StringBuilder();
      if (r != null && r.length > 0 && r[0] != null) {
        for (int k = 0; k < r[0].getSuggestionsCount(); k++) {
          SuggestionsInfo si = r[0].getSuggestionsInfoAt(k);
          if (si == null) continue;
          for (int j = 0; j < si.getSuggestionsCount(); j++) {
            if (b.length() > 0) b.append('\t');
            b.append(si.getSuggestionAt(j));
          }
        }
      }
      return b.toString();
    }
    return null;
  }
}
