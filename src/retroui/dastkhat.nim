## Dastkhat, carried in the program: a sans serif for Arabic, Persian and Latin (from
## Vazirmatn, its Latin from Roboto) -- Arabic's kaf and yeh and Persian's own letters,
## Arabic-Indic and Persian digits, nine weights in one variable font (Thin 100 .. Black 900,
## each a style of the family: `fontStyles("Dastkhat")`). Version 1.210, the SIL Open Font
## License 1.1 (`fonts/dastkhat/OFL-Dastkhat.txt`; Roboto's Apache 2.0 notice in
## `NOTICES-Dastkhat.txt`); 160 KB packed, unpacked the first time it draws.
##
## .. code-block:: nim
##   carryDastkhat()
##   var st = defaultStyle()
##   st.family = DastkhatFamily
##   st.style = "SemiBold"
##
## Scripts it has not (Cyrillic, Greek, Hebrew, CJK, Indic) are drawn in the kit's fonts.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import textengine

const
  DastkhatFamily* = "Dastkhat"
    ## Its family's name.
  dastkhatData = staticRead("fonts/dastkhat/Dastkhat-Variable.ttf.z")

proc carryDastkhat*() =
  ## Offers Dastkhat in the font lists (again: nothing).
  addFontData(DastkhatFamily, "Regular", dastkhatData, packed = true, weight = 400)
