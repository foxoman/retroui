## -d:retroFonts: fewer faces built in (`nimble test` builds this with
## -d:retroFonts=ui too): the left-out faces drawn with FreeSans, or read
## from a folder of their files ($RETRO_FONTS).

import std/os
import retroui/typeset

doAssert faceBytes(fSans).len > 100_000
doAssert faceBytes(fSansBold).len > 50_000
when defined(retroFonts):
  if getEnv("RETRO_FONTS").len > 0:
    # (FreeMono's file in that folder: read from it)
    doAssert faceBytes(fMono).len > 200_000 and faceBytes(fMono) != faceBytes(fSans)
  else:
    # (FreeMono left out: FreeSans in its place)
    doAssert faceBytes(fMono) == faceBytes(fSans)
  doAssert faceBytes(fSerifBold) == faceBytes(fSansBold)
echo "fonts option tests passed"
