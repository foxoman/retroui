#> shot("08-translate--step3")
#> setUiLanguage("en")
import retroui

setUiLanguage("ar", @[("{n} message|{n} messages",
                      "لا رسائل|رسالة واحدة|رسالتان|{n} رسائل|{n} رسالة|{n} رسالة")])

app "Inbox", 260, 150:
  for n in [0, 1, 2, 7, 25]:
    label trn(n, "{n} message", "{n} messages")   # each number its form
