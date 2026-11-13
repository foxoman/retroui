#> shot("f-words")
#> setUiLanguage("en")
import retroui

setUiLanguage("ar", @[("Files", "الملفات"),
                     ("{n} file|{n} files", "لا ملفات|ملف واحد|ملفان|{n} ملفات|{n} ملفًا|{n} ملف")])

app "Files", 260, 160:
  label "Files", bold = true                 # looked up: الملفات
  for n in [1, 2, 5, 11]:
    label trn(n, "{n} file", "{n} files")    # the form the number takes
