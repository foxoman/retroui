## Three Arabic type families carried in the program, each in Regular and Bold: Scheherazade
## New (SIL's naskh, for books: full tashkeel, Arabic for many languages -- Persian, Urdu,
## Pashto, Sindhi, Kurdish), Lateef (SIL's, after the Sindhi and Urdu naskh: Pashto, Urdu,
## Sindhi) and Markazi Text (a text face of Arabic and Latin, from Palestinian type).
## Each as published under the SIL Open Font License 1.1 (`fonts/arabic/OFL-*.txt`), packed:
## 640 KB in all, each unpacked the first time it draws.
##
## .. code-block:: nim
##   carryArabicFonts()
##   var st = defaultStyle()
##   st.family = "Scheherazade New"
##   st.style = "Bold"
##
## Fonts with SIL's Graphite tables only (Awami Nastaliq, Lateef GR) are not here: the kit
## shapes with OpenType.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import textengine

const
  ArabicFamilies* = ["Scheherazade New", "Lateef", "Markazi Text"]
    ## The families `carryArabicFonts` offers.
  arabicFaces = [
    ("Scheherazade New", "Regular", 400, staticRead("fonts/arabic/ScheherazadeNew-Regular.ttf.z")),
    ("Scheherazade New", "Bold", 700, staticRead("fonts/arabic/ScheherazadeNew-Bold.ttf.z")),
    ("Lateef", "Regular", 400, staticRead("fonts/arabic/Lateef-Regular.ttf.z")),
    ("Lateef", "Bold", 700, staticRead("fonts/arabic/Lateef-Bold.ttf.z")),
    ("Markazi Text", "Regular", 400, staticRead("fonts/arabic/MarkaziText-Regular.ttf.z")),
    ("Markazi Text", "Bold", 700, staticRead("fonts/arabic/MarkaziText-Bold.ttf.z"))]

proc carryArabicFonts*() =
  ## Offers the three families in the font lists (again: nothing).
  for (family, style, weight, data) in arabicFaces:
    addFontData(family, style, data, packed = true, weight = weight)
