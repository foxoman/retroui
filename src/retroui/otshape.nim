## OpenType shaping in plain Nim: a run of text in one face becomes the
## glyphs to draw, with their advances and offsets, as the font's GSUB,
## GPOS and GDEF tables say -- ligatures, contextual and stylistic forms,
## kerning, cursive joining and marks over letters. Arabic gets its
## joining forms (isol, init, medi, fina) as HarfBuzz gives them; Latin
## and the other scripts that need no reordering get the default features.
##
## ```nim
## let face = parseFace(readFile("FreeSerif.ttf"))
## var cps: seq[int]
## for r in "بِسْمِ اللَّهِ".runes: cps.add int(r)
## for g in face.shape(cps, rtl = true, script = "arab"):
##   echo g.gid, " from character ", g.cluster, " advance ", g.xAdv
## echo face.featureTags                     # @["calt", "ccmp", "curs", ...]
## echo face.featureName("ss01")             # the font's own name for it
## let swash = face.shape(cps, true, "arab", features = [("ss01", true)])
## let heavy = face.variation([("wght", 700.0)]).shape(cps, true)  # variable fonts
## ```
##
## The result is what HarfBuzz's `hb_shape` gives for the same font, text,
## direction, script and features with the "characters" cluster level:
## glyphs in the order they are drawn (a right-to-left run reversed), each
## with the index of the first input character it came from, positions in
## font units. A font without GSUB and GPOS gets its nominal glyphs and its
## legacy `kern` pairs (split between the two glyphs as HarfBuzz does).
## A face made by `variation` shapes at its axis values: feature
## variations pick their lookups, GPOS variation deltas move kerning and
## anchors.
##
## Not done: the shapers HarfBuzz has for Indic, Khmer, Myanmar, Thai, Lao,
## Hangul, Hebrew and the Universal Shaping Engine scripts (those runs get
## the default features only); Syriac `stch`; the Arabic presentation-form
## fallback and the mark placement HarfBuzz guesses for fonts without GSUB
## or GPOS; vertical text.

import std/[tables, algorithm, base64, strutils, math]
import ttf

type
  ShapedGlyph* = object
    ## One glyph of shaped text.
    gid*: int          ## glyph id
    cluster*: int      ## index (into the input) of the first code point it came from
    xAdv*, yAdv*: int  ## advance, font units, after GPOS
    xOff*, yOff*: int  ## where it is drawn from the pen, font units

  Feature* = tuple[tag: string; on: bool]
    ## A feature turned on or off: ("liga", false), ("ss01", true), ("salt", true)...

# ---- Unicode data ---------------------------------------------------------------------
#
# Made from the Unicode 17 character database (UnicodeData.txt,
# DerivedNormalizationProps.txt, BidiMirroring.txt, ArabicShaping.txt) by a
# small Nim program: runs and pairs as base64 varints, read once.

const
  # 2641 runs of general category: varint((start - previous start) shl 4 or class)
  gcData =
    "AIcEEDwQbBBCoAEsMCGgAzoQGhGgAxwQHBCXBBAcUBocERAcFhwaHCsqERAqGxEQGzAR/AIR/AMRqjlBygHhAVpxGhEakwKB" &
    "DloRKCFAERhKIRAROBEYEcgCEbwKEbwRE1Uh6BQR6AQRIGGQBSEsOBPQBRMQEyATIBM4YbgDQUAotgFsMCwQLCOwARYQMbMF" &
    "0gKgAUEjEbAMERN2HBNhIywTQSKhATwhEOgBFhETEeMDuAMhkwuxARjiAaEBkwSRASwQMRgjHCHjAkETkQETMRNYIPgBEZMD" &
    "OCAYEbgBUYoDEXYoU5EBowWGAxOEBBHjBhQTERQzhAFDFCETcaMBICKgARGDAhQoEYgBISgh6AIReBEYMUgjERQzSCQoJCMR" &
    "GIQBGEEoETMoIqEBLCtsIRATGCMkGBFoQSgh6AIReBEoESgRKCMYFDMoQygjODMYcUgRGHKjASEzEBijASQYEZgBETgR6AIR" &
    "eBEoEVgjERQzWBMkGBQjGCEY8QEjKCKgARwYcRNoExQoEYgBISgh6AIReBEoEVgjERQTFBNIJCgkIxhTRBhBKBEzKCKsAREb" &
    "aKMBERgRaDE4EUgxKBEYESgxKDE4McgBRCMUKDQ4FDMYIRhkGOIBqwE8iAFTFDMRiAEROBH4AhGIAiMREzRIEzgTSHMoETgR" &
    "KCEjKCKoAXAbfBETFCARiAEROBH4AhGoARFYIxEUExRYExQoFCModChROBEjKCKoAREkGMMBJCGYARE4EZMFIRQzSBQ4FDMR" &
    "HBhBNBtxMygiqwGcARFoExQoEagCMYgDEZgBERgheDMYRDM4ExgUiAFiqAEkIBjBAYMGESN4TBFzgAESoAEo0QQoERgRWBGI" &
    "AxEYEaMBESORARghWBEYE3gSqAEhSIEEHDD8ARAcMyxiqwGsARMcExwTEEQhiAERyARD5AETUBMhU7gBE8gEHIMBHGgcIFxA" &
    "KNEEtAUjRBNkEyQjIRKgAWFkIyFDMRQxJHEzQdMBFCMkYxEUEqQBMxwh6AQRGFEYIbAFEdgpEUgheBEYEUghmAURSCGYBBFI" &
    "IXgRGBFIIfgBEZgHEUghuAgjMJsByAIxjAKoAWHoCiFoIBHMTRARlwIRoAMoMbAJOzGIAXGjAjQYkQGzAiQQKJEBowIowQHY" &
    "ARE4EyjBAcMGJBN0gwEUI7ABMRA8ERMYIqgBa6gBYLMBNhMSqAFhmAtxUyGjBBEYUegIoQH4AxM0QyQ4RCMUYzhMGDAioQHo" &
    "AyFYsQHIBUGoA2KrARg8oQTzAiQjGCAh1AYTFBN4ExQTFCOEAWOoASMSqAFiqAFgcRBoI+UBE6gG8wFEEfMFFBNUExRTFCGI" &
    "ARAioAF8owGcAZABMyQR5AMTRCMkEzEioQHDBRQTJDMUEzQogAFBxASDAYQBIygwUqgBMTKhAcAEIbgBUbgFITCIAYMBMBPU" &
    "ARNxQxFjESQTIRhRgxiBCOgiIWgh6AQhaCGIAREYERgRGBH4AyHYBhF6ERoxOBF6MUghaBox2gE4ITgReigXtgFQpgNXEMwC" &
    "ENwBEMcBFlgWqwERGCtsMCEbrAEwIZwC2ASzAdUBQxUzyAH8ASEcQRwhrAERHDFcYRwRHBEcEUwRvAEhTFFcQRwbsQYrXChM" &
    "gC9M0AMs+B/sArgB2wLMB+sJ7AKATesB7AOQBizwA6wBsDLsAvAHTIAELOguLKER3BxhQzEoUEsQIegEERhRGCGIB3EQGOMB" &
    "EfgCkQF4EXgReBF4EXgReBF4EXgTgATxBRCMBCDIASBIzAOoAxyYC8wB6BqsA4cCEDwRKxCsASDMARuTAUQgEVwrMSAcKBHo" &
    "CiMqITARoAsRSFG4BRHoCxwrTKEBjAToBJwBEYwC+AMbrAHrA4wBG/wBiwSsAfsE/AGBKIy4BoEI2NEVPPgGkQHgBSHQITGC" &
    "AqEBKMEC8wUVMBOgARHzAyHrCKMBIGiKAfECmgEh+gwhuApBGOEBkwIRMxFDEfQCIyQcQxg7bEhhwAZIhAEhpAaDAiiAASKo" &
    "AWOhAmAxEBEjEqEBwwOAASHzArQBKLABEdgDMzQR8wUUI0QjJDDYARESqAFAIVMRogGhAVgRkwVkIyQjKJEBMxGDARQYIqgB" &
    "IEH8AjEUExQRowYREzEjIVMhExEYgQMwIbQBEyQgITQTGKEBaCFoIWiRAXgReBG6BRHqASEoIbQOIxQjFCAUExgiqAFhyPQK" &
    "wQH4AkGYBkCJgAKBoAboLSGoDeEEeMEBWFETEawBEdgBEVgRGBEoESgRyg2cAoECsC0sgQKMCCHsBogBgQTMAUOAAqgBY4AC" &
    "uAQQ7AEQHDgQHBAoQVgR+BAmGBA8EGwQQqABLDAhoAM6EBoRoAMcEBwQcZgLMWghaCFoITg8Ohw4HHimATwoIcgBEagDEbgC" &
    "ESgR+AEh6AGhBLgPUDhL2AU8mwGcB5sCLDgc2AE8GPwF0wUYoRDYAzGYBvMBG7gDQYsESJEBywIRiwEYUeMEWFHoAxARyARB" &
    "gAEbWKEF6BMiqAFhyARByARBiAWBAcgGsAERuAER+AEReBEoEbgBEfgBEXgRKDHIBsEB+CaRAegCoQGIAYEDaBGoBRHoAYEI" &
    "aCEYEcgFESgxGCH4AhAbgQH8Aitx+AOLAZgBgQa4AhEoW1HrAmgwEagDUBGoA+EEiAdLISuIAivhBRM4EyhTQUgROBHYAyM4" &
    "QxuYAXCYAXHbAyAR2wM4gQSMARHDAyhLUHiRAegGMHHoAiuBAbgCW4EBqAJwSMsBeIEKmAnxBrgG0QG4BnthwwRIggGoAWKh" &
    "AcgDM1AR+AKMASiLGvgDEagFEyAYISiBAmgaI1AcgQHoAhOBAtsDoQEYgQHjArsBQFjhAqMCQEjhBNsCeMEC+AKUARMUEdMG" &
    "8AF4S8ICowERIyEYkwE0EdQFM0QjICYQQximARghmANyqAFjMcMEVBOIARKgAUEUIRiBAbMEECEYkwEkEYQGM5QBIUBDQBQT" &
    "EqEBEBEQOBvIArEBqAIRlAMzNCMUEyBjESMY4Qd4ERgRSBH4ARGgARhh8wUUM4gBUqgBYyQoEYgBISgh6AIReBEoEVgTIRQj" &
    "FEgkKCQ4IRhkGFFUKCN4M1ixAagBERghGBHoBBEUM2gUGCQYFEgUIxQTERMRECgQKIMBKNED1AYzhAEjNBMRQFKgASgQExE4" &
    "4QOEBjNkExRDJBMhIBEYggGoAeEU9AUzSCRDJBMg8QJDKKEEhAYzhAEjFBMgMRiyAagBYNgBsQKzBRQTFCNkExEQGGKoAWLI" &
    "AsEDuAMjFBMUI0QTWEKrASA8EXiRF8QFM5QBEyAYwQyCCKsBmAHBAYgBIRghiAERKBGEA2gUKCMkExEUERQTEDiSAagB4QiI" &
    "ASH0BDNIIyRDERARFBixAxOhAYMFZBETQIMBGIEBE2QjMeMF1AETIDEQWNEBmAlwoQEY0woUEzQTFBiBC5AEGOIBqAFhmAER" &
    "1AQTeBNkExEQWKIBqwG4AjAh6AMj6AIUE3QTJBMokQl4ESgR4wRoMxgTKBNxExiCAagBYWgRKBGEBFgTKBQjFBMRGHKoAWHI" &
    "BUKoAWMRGOEdswIkIChzIRQR2AERpAQjWDQjFBMQ0gGjARjRChj7AdwC2APQARGoc+sMgA5bsQHIGMsB+CaRoQKQDCjRAYaG" &
    "AYMCEWP4AaEBuPMDUfhIkdcG4wPEATMyqAHh2AGYR3H4AxKoAUAh+AkSqAFh6AMjUBihAYMGcFxBQBwYogGoARt4EdgCUbgC" &
    "gTbQBTKoAeEYiwjwAkhRmAMhmAPBBbgJQxEU+AZzQdgBgQggERMYtAEhKziRAbibB8EEqATxC7gO0QGocuEBuAbRwwdIEXgR" &
    "KBGYJZEBGNEDOCEY4QFYccgxwaACuA1R2AExmAFxqAEsEyAWSMzrA4IerAE4PMg2bPgCHDiMAZgEI+gFI/gCnAHIDswH6B6s" &
    "AfMELMQHIzw0ZoMBjAEjfOMDTMMSPBikATyDASwkHIQEKOsHyALLAcgCzAH4CpsBmAPxENgKEfgIESghGCEoIUgRyAERGBF4" &
    "EZgIEUghiAEReBHIAxFIEVgRGDF4EdgqEZwDEZwDEfwDEZwDEfwDEZwDEfwDEZwDEfwDEZwDEYgBIqwGg0D8BkOsBoMBHOMB" &
    "HCBY8wFYE/gBjArYA7F8qBDhAXjhBrMGeBOYAiN4EygTWFHoB5MEGIEO2AUzcXgiqAFBHBiBKOMDGJECwwVCqAFcGIE6wwNC" &
    "qAHhGuMDIRKoAUAYgRj4AxEzESMRcyFTGIEBKIEceBFIESgR+AER2BgrkwF4kQXDCHEYQqgBQCibYrwHGzwbSMsJ3AUb+AGh" &
    "GEgRuAMRKBEYIRgRqAERSBEYERhhGEEYERgRGBE4ESgRGCEYERgRGBEYERgRKBEYIUgReBFIEUgRGBGoARGYAlE4EVgRmALM" &
    "BijsIcgFTMgMzAH4ASz4ARz4ARzYBKsB3AGoFPwG2APcAcgFTJgBfCjsAWisE7ofXKhbLJgCPNgBPMgbTMgBTMgDTIgHjAGo" &
    "AWyIBYwB6AMsyAFMKOwBmAH8BIgrjAHoASzYATz4CBwYPKgCHNgBPMgBXLgSHMILrAEY0YABiNwpgQT4owQR6NEFIZimB/EB" &
    "6E2htALoQ6G8AbjpBFGopQjh8CaIiAuW+IAFGOYDiAyDEIgeicI/6P8/Kej/Pw=="
  # 422 runs of combining class: varint(first - previous last), varint(count - 1), class
  cccData =
    "gAYU5gEA6AED3AEA6AEA2AEE3AEBygED3AEBygEK3AEEAQED3AEH5gEA8AEA5gEC3AEC5gEB3AIC5gED3AEA5gEA6AEB3AEA" &
    "5gEA6QEB6gEA6QEB6gEA6QEM5pQCBOaKAgDcAQPmAQDcAQLmAQDeAQDcAQXmAQXcAQHmAQDcAQHmAQDeAQDkAQDmAQAKAQAL" &
    "AQAMAQANAQAOAQAPAQAQAQARAQASAQETAQAUAQAVAQAWAgAXAgAYAQAZAgDmAQDcAgASAQAKAQAVRwfmAQAeAQAfAQAgMQAb" &
    "AQAcAQAdAQAeAQAfAQAgAQAhAQAiAQHmAQHcAQTmAQDcAQHmAQDcEQAjZgbmAwPmAQDcAQDmAwHmAgDcAQHmAQDcJAAkHwDm" &
    "AQDcAQHmAQDcAQHmAQLcAQDmAQHcAQDmAQDcAQLmAQDcAQDmAQDcAQDmAQDcAQDmAQDcAQHmoQEG5gEA3AEA5goA3BkD5gII" &
    "5gIC5gIE5iwC3DwB5gEC3AED5isE5gEE3AEN5gIA3AEB5gEA3AEB5gEA3AEC5gEC3AEAGwEAHAEAHQEC5gEA3AEB5gEB3AEE" &
    "5j0ABxEACQQA5gEA3AEB5mgABxEACTEA5j4ABxEACW8ABxEACW8ABxEACYABAAlvAAcRAAkIAFQBAFtmAAcRAAluAQkRAAl9" &
    "AAluAWcBAAkOA2ttAXYBAAkOA3pNAdwcANwCANwCANg4AIEBAIICAIQGA4IDAIICAeYBAAkCAeY/ANxxAAcCAQlTANzQBQLm" &
    "tQcBCR8ACZ4BAAkLAObMAQDkkAEA3gEA5gEA3NwBAOYBANxIAAkVB+YDANwxBOYBBdwBAeYBANwCAdwBAeYBAdwBBOYBANwB" &
    "EeYBANwBB+YBANwBA+YBAOoBAeYBAdwBAOZEAAcQAAknAOYBANwBBuY3AQk7AAcMAQlEAAeZAQLmAgABAQTcAQHmAQPcAQDm" &
    "AgYBBQDcBwDmBAHmxwEB5gEA3AEG5gEA3AEB5gEA6gEA1gEA3AEAygEk5gEA6AEB5AEA3AEA2gEA5gEA6QEA3AEA5gEA3NEF" &
    "AeYBAQEBA+YBAgEBAeYFAOYEAQEBAOYBANwBAOYBAQEBA9wBAOb/FwLmjgEACWEf5qsEANoBAOQBAOgBAN4BAeBqAQjV6wEA" &
    "5gUJ5iEB5lEB5pUCAAkmAAmYAQAJHBHmOgLcJgAJYAAHDQAJ8AEA5gIB5gEA3AMB5gYB5gIA5jUACfcBAAmxngEAGoIGBuYB" &
    "BtwBAebOBwDc4wEA3JYBBOaTDQDcAgDmKQDmAQABAQDcBQAJpgEA5gEA3L4EA+ZCBOa+AgHmHwDmAQHcAQHmIQLcAQDmAQDc" &
    "AQDmAQDcAQLmAQHcAgLcRwHcAQLmAQDcAQDmAQPcMgDmAQDcAQDmAQDcwQEACSoACQ8ACToACQEAB0YC5jEBCT8AB00ACQoA" &
    "B2sACQEAB7MBAAcBAAlRAQcRAAkZBuYEBOZaAglyAAkEAAcYAOZkAAkBAAf8AQAJAQAHfwAJdwAJAQAHdAAJjgIACQEAB4MC" &
    "AQkFAAedAQAJVAAJEwAJUgAJpgMACYMCAAcCAQlSAAmqAwEJ7YMBAAnBEwQBPAbmugkBBq2ZAQABiSkB3D0B2AECAQQA4gEE" &
    "2AkH3AME5gEB3B8D5pUBAuYMAtgJAQEDANghAdj/GgbmAhDmAwbmAgHmAgTmZQDmoQEG5vgCAOY+A+b9AwHoAQDcAQDm/wEA" &
    "5gEA3PQBAOYDAOYIAeYGAObbAwbcbgXmAQAH"
  # 2081 canonical decompositions: varint((c - previous c) shl 1 or composes), varint(a), varint(b)
  decompData =
    "gQNBgAYDQYEGA0GCBgNBgwYDQYgGA0GKBgVDpwYDRYAGA0WBBgNFggYDRYgGA0mABgNJgQYDSYIGA0mIBgVOgwYDT4AGA0+B" &
    "BgNPggYDT4MGA0+IBgdVgAYDVYEGA1WCBgNViAYDWYEGB2GABgNhgQYDYYIGA2GDBgNhiAYDYYoGBWOnBgNlgAYDZYEGA2WC" &
    "BgNliAYDaYAGA2mBBgNpggYDaYgGBW6DBgNvgAYDb4EGA2+CBgNvgwYDb4gGB3WABgN1gQYDdYIGA3WIBgN5gQYFeYgGA0GE" &
    "BgNhhAYDQYYGA2GGBgNBqAYDYagGA0OBBgNjgQYDQ4IGA2OCBgNDhwYDY4cGA0OMBgNjjAYDRIwGA2SMBgdFhAYDZYQGA0WG" &
    "BgNlhgYDRYcGA2WHBgNFqAYDZagGA0WMBgNljAYDR4IGA2eCBgNHhgYDZ4YGA0eHBgNnhwYDR6cGA2enBgNIggYDaIIGB0mD" &
    "BgNpgwYDSYQGA2mEBgNJhgYDaYYGA0moBgNpqAYDSYcGCUqCBgNqggYDS6cGA2unBgVMgQYDbIEGA0ynBgNspwYDTIwGA2yM" &
    "BgtOgQYDboEGA06nBgNupwYDTowGA26MBglPhAYDb4QGA0+GBgNvhgYDT4sGA2+LBgdSgQYDcoEGA1KnBgNypwYDUowGA3KM" &
    "BgNTgQYDc4EGA1OCBgNzggYDU6cGA3OnBgNTjAYDc4wGA1SnBgN0pwYDVIwGA3SMBgdVgwYDdYMGA1WEBgN1hAYDVYYGA3WG" &
    "BgNVigYDdYoGA1WLBgN1iwYDVagGA3WoBgNXggYDd4IGA1mCBgN5ggYDWYgGA1qBBgN6gQYDWocGA3qHBgNajAYDeowGRU+b" &
    "BgNvmwYdVZsGA3WbBjtBjAYDYYwGA0mMBgNpjAYDT4wGA2+MBgNVjAYDdYwGA9wBhAYD/AGEBgPcAYEGA/wBgQYD3AGMBgP8" &
    "AYwGA9wBgAYD/AGABgXEAYQGA+QBhAYDpgSEBgOnBIQGA8YBhAYD5gGEBgdHjAYDZ4wGA0uMBgNrjAYDT6gGA2+oBgPqA4QG" &
    "A+sDhAYDtwOMBgOSBYwGA2qMBglHgQYDZ4EGB06ABgNugAYDxQGBBgPlAYEGA8YBgQYD5gGBBgPYAYEGA/gBgQYDQY8GA2GP" &
    "BgNBkQYDYZEGA0WPBgNljwYDRZEGA2WRBgNJjwYDaY8GA0mRBgNpkQYDT48GA2+PBgNPkQYDb5EGA1KPBgNyjwYDUpEGA3KR" &
    "BgNVjwYDdY8GA1WRBgN1kQYDU6YGA3OmBgNUpgYDdKYGB0iMBgNojAYPQYcGA2GHBgNFpwYDZacGA9YBhAYD9gGEBgPVAYQG" &
    "A/UBhAYDT4cGA2+HBgOuBIQGA68EhAYDWYQGA3mEBpoEgAYAAoEGAASTBgACiAaBBmC5BQAUOwAPqAGBBgORB4EGArcBAAOV" &
    "B4EGA5cHgQYDmQeBBgWfB4EGBaUHgQYDqQeBBgPKB4EGNZkHiAYDpQeIBgOxB4EGA7UHgQYDtweBBgO5B4EGA8sHgQY1uQeI" &
    "BgPFB4gGA78HgQYDxQeBBgPJB4EGC9IHgQYD0geIBlmVCIAGA5UIiAYFkwiBBgmGCIgGC5oIgQYDmAiABgOjCIYGF5gIhgZB" &
    "uAiGBi+1CIAGA7UIiAYFswiBBgnWCIgGC7oIgQYDuAiABgPDCIYGMfQIjwYD9QiPBpUBlgiGBgO2CIYGHZAIhgYDsAiGBgOQ" &
    "CIgGA7AIiAYHlQiGBgO1CIYGB9gJiAYD2QmIBgOWCIgGA7YIiAYDlwiIBgO3CIgGB5gIhAYDuAiEBgOYCIgGA7gIiAYDngiI" &
    "BgO+CIgGB+gJiAYD6QmIBgOtCIgGA80IiAYDowiEBgPDCIQGA6MIiAYDwwiIBgOjCIsGA8MIiwYDpwiIBgPHCIgGB6sIiAYD" &
    "ywiIBtMEpwzTDAOnDNQMA8gM1AwDpwzVDAPKDNQMtQLVDdQMBcEN1Awj0g3UDK0JqBK8EhGwErwSB7MSvBJIlRK8EgKWErwS" &
    "ApcSvBICnBK8EgKhErwSAqISvBICqxK8EgKvErwS2QHHE74TA8cT1xMgoRO8EwKiE7wTBK8TvBOoAbIUvBQGuBS8FEaWFLwU" &
    "ApcUvBQCnBS8FAarFLwU1QPHFtYWB8cWvhYDxxbXFiChFrwWAqIWvBZvkhfXF23GF74XA8cXvhcDxhfXF/kBxhjWGPEBvxnV" &
    "GQ/GGdUZA8YZ1hkFxhnCGQPKGdUZ/wHGGr4aA8cavhoDxhrXGp0C2RvKGwXZG88bA9wbyhsD2RvfG8oFwh63HxTMHrcfCtEe" &
    "tx8K1h63HwrbHrcfGsAetR8U8R7yHgTxHvQeArIfgB8Esx+AHxLxHoAfJJIftx8UnB+3HwqhH7cfCqYftx8Kqx+3HxqQH7Uf" &
    "2wGlIK4gwSuFNrU2BYc2tTYFiTa1NgWLNrU2BY02tTYJkTa1NlO6NrU2Bbw2tTYHvja1NgO/NrU2BcI2tTb7CkGlBgNhpQYD" &
    "QocGA2KHBgNCowYDYqMGA0KxBgNisQYDxwGBBgPnAYEGA0SHBgNkhwYDRKMGA2SjBgNEsQYDZLEGA0SnBgNkpwYDRK0GA2St" &
    "BgOSAoAGA5MCgAYDkgKBBgOTAoEGA0WtBgNlrQYDRbAGA2WwBgOoBIYGA6kEhgYDRocGA2aHBgNHhAYDZ4QGA0iHBgNohwYD" &
    "SKMGA2ijBgNIiAYDaIgGA0inBgNopwYDSK4GA2iuBgNJsAYDabAGA88BgQYD7wGBBgNLgQYDa4EGA0ujBgNrowYDS7EGA2ux" &
    "BgNMowYDbKMGA7Y8hAYDtzyEBgNMsQYDbLEGA0ytBgNsrQYDTYEGA22BBgNNhwYDbYcGA02jBgNtowYDTocGA26HBgNOowYD" &
    "bqMGA06xBgNusQYDTq0GA26tBgPVAYEGA/UBgQYD1QGIBgP1AYgGA8wCgAYDzQKABgPMAoEGA80CgQYDUIEGA3CBBgNQhwYD" &
    "cIcGA1KHBgNyhwYDUqMGA3KjBgPaPIQGA9s8hAYDUrEGA3KxBgNThwYDc4cGA1OjBgNzowYD2gKHBgPbAocGA+AChwYD4QKH" &
    "BgPiPIcGA+M8hwYDVIcGA3SHBgNUowYDdKMGA1SxBgN0sQYDVK0GA3StBgNVpAYDdaQGA1WwBgN1sAYDVa0GA3WtBgPoAoEG" &
    "A+kCgQYD6gKIBgPrAogGA1aDBgN2gwYDVqMGA3ajBgNXgAYDd4AGA1eBBgN3gQYDV4gGA3eIBgNXhwYDd4cGA1ejBgN3owYD" &
    "WIcGA3iHBgNYiAYDeIgGA1mHBgN5hwYDWoIGA3qCBgNaowYDeqMGA1qxBgN6sQYDaLEGA3SIBgN3igYDeYoGBf8ChwYLQaMG" &
    "A2GjBgNBiQYDYYkGA8IBgQYD4gGBBgPCAYAGA+IBgAYDwgGJBgPiAYkGA8IBgwYD4gGDBgOgPYIGA6E9ggYDggKBBgODAoEG" &
    "A4ICgAYDgwKABgOCAokGA4MCiQYDggKDBgODAoMGA6A9hgYDoT2GBgNFowYDZaMGA0WJBgNliQYDRYMGA2WDBgPKAYEGA+oB" &
    "gQYDygGABgPqAYAGA8oBiQYD6gGJBgPKAYMGA+oBgwYDuD2CBgO5PYIGA0mJBgNpiQYDSaMGA2mjBgNPowYDb6MGA0+JBgNv" &
    "iQYD1AGBBgP0AYEGA9QBgAYD9AGABgPUAYkGA/QBiQYD1AGDBgP0AYMGA8w9ggYDzT2CBgOgA4EGA6EDgQYDoAOABgOhA4AG" &
    "A6ADiQYDoQOJBgOgA4MGA6EDgwYDoAOjBgOhA6MGA1WjBgN1owYDVYkGA3WJBgOvA4EGA7ADgQYDrwOABgOwA4AGA68DiQYD" &
    "sAOJBgOvA4MGA7ADgwYDrwOjBgOwA6MGA1mABgN5gAYDWaMGA3mjBgNZiQYDeYkGA1mDBgN5gwYPsQeTBgOxB5QGA4A+gAYD" &
    "gT6ABgOAPoEGA4E+gQYDgD7CBgOBPsIGA5EHkwYDkQeUBgOIPoAGA4k+gAYDiD6BBgOJPoEGA4g+wgYDiT7CBgO1B5MGA7UH" &
    "lAYDkD6ABgORPoAGA5A+gQYDkT6BBgeVB5MGA5UHlAYDmD6ABgOZPoAGA5g+gQYDmT6BBge3B5MGA7cHlAYDoD6ABgOhPoAG" &
    "A6A+gQYDoT6BBgOgPsIGA6E+wgYDlweTBgOXB5QGA6g+gAYDqT6ABgOoPoEGA6k+gQYDqD7CBgOpPsIGA7kHkwYDuQeUBgOw" &
    "PoAGA7E+gAYDsD6BBgOxPoEGA7A+wgYDsT7CBgOZB5MGA5kHlAYDuD6ABgO5PoAGA7g+gQYDuT6BBgO4PsIGA7k+wgYDvweT" &
    "BgO/B5QGA8A+gAYDwT6ABgPAPoEGA8E+gQYHnweTBgOfB5QGA8g+gAYDyT6ABgPIPoEGA8k+gQYHxQeTBgPFB5QGA9A+gAYD" &
    "0T6ABgPQPoEGA9E+gQYD0D7CBgPRPsIGBaUHlAYF2T6ABgXZPoEGBdk+wgYDyQeTBgPJB5QGA+A+gAYD4T6ABgPgPoEGA+E+" &
    "gQYD4D7CBgPhPsIGA6kHkwYDqQeUBgPoPoAGA+k+gAYD6D6BBgPpPoEGA+g+wgYD6T7CBgOxB4AGAqwHAAO1B4AGAq0HAAO3" &
    "B4AGAq4HAAO5B4AGAq8HAAO/B4AGAswHAAPFB4AGAs0HAAPJB4AGAs4HAAeAPsUGA4E+xQYDgj7FBgODPsUGA4Q+xQYDhT7F" &
    "BgOGPsUGA4c+xQYDiD7FBgOJPsUGA4o+xQYDiz7FBgOMPsUGA40+xQYDjj7FBgOPPsUGA6A+xQYDoT7FBgOiPsUGA6M+xQYD" &
    "pD7FBgOlPsUGA6Y+xQYDpz7FBgOoPsUGA6k+xQYDqj7FBgOrPsUGA6w+xQYDrT7FBgOuPsUGA68+xQYD4D7FBgPhPsUGA+I+" &
    "xQYD4z7FBgPkPsUGA+U+xQYD5j7FBgPnPsUGA+g+xQYD6T7FBgPqPsUGA+s+xQYD7D7FBgPtPsUGA+4+xQYD7z7FBgOxB4YG" &
    "A7EHhAYD8D7FBgOxB8UGA6wHxQYFsQfCBgO2P8UGA5EHhgYDkQeEBgORB4AGAoYHAAORB8UGBLkHAAeoAcIGA/Q+xQYDtwfF" &
    "BgOuB8UGBbcHwgYDxj/FBgOVB4AGAogHAAOXB4AGAokHAAOXB8UGA78/gAYDvz+BBgO/P8IGA7kHhgYDuQeEBgPKB4AGApAH" &
    "AAe5B8IGA8oHwgYDmQeGBgOZB4QGA5kHgAYCigcABf4/gAYD/j+BBgP+P8IGA8UHhgYDxQeEBgPLB4AGArAHAAPBB5MGA8EH" &
    "lAYDxQfCBgPLB8IGA6UHhgYDpQeEBgOlB4AGAo4HAAOhB5QGA6gBgAYChQcAAmAAB/w+xQYDyQfFBgPOB8UGBckHwgYD9j/F" &
    "BgOfB4AGAowHAAOpB4AGAo8HAAOpB8UGArQBAAaCQAACg0AAygSpBwAISwACxQEA3wGQQ7gGA5JDuAYnlEO4Bj/QQ7gGA9RD" &
    "uAYD0kO4BmuDRLgGC4hEuAYHi0S4BjGjRLgGBaVEuAY3vES4BgfDRLgGB8VEuAYFyES4Bi89uAYF4US4BhfNRLgGAzy4BgM+" &
    "uAYD5ES4BgPlRLgGB/JEuAYD80S4Bgf2RLgGA/dEuAYP+kS4BgP7RLgGB4JFuAYDg0W4BgeGRbgGA4dFuAZHokW4BgOoRbgG" &
    "A6lFuAYDq0W4BmP8RLgGA/1EuAYDkUW4BgOSRbgGD7JFuAYDs0W4BgO0RbgGA7VFuAZ4iGAAAolgAOQe3VW4BuEVy2CZYQXN" &
    "YJlhBc9gmWEF0WCZYQXTYJlhBdVgmWEF12CZYQXZYJlhBdtgmWEF3WCZYQXfYJlhBeFgmWEH5GCZYQXmYJlhBehgmWEP72CZ" &
    "YQPvYJphBfJgmWED8mCaYQX1YJlhA/VgmmEF+GCZYQP4YJphBftgmWED+2CaYS/GYJlhFZ1hmWEdq2GZYQWtYZlhBa9hmWEF" &
    "sWGZYQWzYZlhBbVhmWEFt2GZYQW5YZlhBbthmWEFvWGZYQW/YZlhBcFhmWEHxGGZYQXGYZlhBchhmWEPz2GZYQPPYZphBdJh" &
    "mWED0mGaYQXVYZlhA9VhmmEF2GGZYQPYYZphBdthmWED22GaYS+mYZlhB+9hmWED8GGZYQPxYZlhA/JhmWEJ/WGZYYSgBsiY" &
    "AgAC9M0BAALKnQIAAsiZAgAC0d0BAAKynAEAAuWnAQACnL8CAAKcvwIAAtGyAQAC0aMCAAKHqwEAAsiyAQAC9sMBAALp7AEA" &
    "AoX/AQACv4wCAAK6jwIAAviRAgACj6ECAAKC1AEAApvaAQAC2eEBAALe5wEAAr2IAgAC6qICAALxswIAAoKdAQAC9aYBAAKE" &
    "1gEAApvkAQACrYwCAAKevAIAAtC6AQAC698BAALNiwIAAuSSAgACycUBAALYgwIAAp+QAgACyr0BAAKXzgEAAuraAQAC/OUB" &
    "AALOoQIAAoafAQACt6MBAALepQEAAsTJAQAC09UBAAKQ5AEAAuftAQACgYACAAKGjAIAAtyMAgAC75sCAAKyrgIAAu+2AgAC" &
    "+rsCAAKM8QEAAv/yAQACoPsBAALJhwIAAoSmAgAC/7wCAALWlQIAAt+xAQAChL4BAALg+AEAAv6AAgAC4uQBAALK8QEAAsKZ" &
    "AgAC960CAALYsQEAAuK4AQACk9QBAALa2wEAAo/eAQACr/oBAAK3/AEAAsusAgAC0qUBAAKLgQIAAtyjAQACzKMBAAKc9AEA" &
    "Ar77AQAC8YcCAAL1rAIAAoCXAgACz8UBAAKC1AEAAv6VAgACuZwBAALntwEAApLAAQACh+cBAALw6gEAApemAQAC+/EBAAK/" &
    "nwEAAqm/AQACjZwBAALM2QEAAvjKAQACovoBAALDpwEAAt6wAQACge4BAALJiAIAAqqVAgACutcBAAKwnwIAAojZAQAC/sUB" &
    "AALlhQIAAqDHAQAC5eoBAAKunQEAAumiAQACyaMBAAKB0QEAAuf5AQAC74QCAALSlQIAAs+jAgAC9aUBAALCqAEAAvOyAQAC" &
    "7L0BAALFywEAAv7fAQACqvIBAAKtqwIAAuq0AgACl70CAALOvQIAApulAQACxs0BAAL31gEAAuKeAgAC9LwBAAKQwwEAAoDE" &
    "AQACmskBAAKj3gEAAsniAQACiekBAALK8wEAAvT7AQAC74ACAAKmngIAAu6JAgACo6ACAALKpgIAApekAQACo6UBAAK9qQEA" &
    "AsjhAQACwpECAAKqlQIAAsm9AQAC9b8BAAL7xgEAAq7XAQACvvgBAAL15gEAAuSdAQAC+a0BAALntwEAArq7AQACnMABAAKy" &
    "5wEAAunoAQACmv8BAALGgAIAArSkAgAC9q0CAALIrgIAApiwAgACi58BAAKu8wEAArSjAgACuK0CAALhwQEAAoadAQAC2qEB" &
    "AALutwEAAr+4AQACmcsBAAKC1AEAAs7jAQACwuwBAAL8iQIAAvygAgACjb8CAAKIzQEAAq6sAgACiaUBAAL7zgEAAvPPAQAC" &
    "wdoBAAKc3QEAAonoAQAC2eoBAALr8AEAApD6AQAC3rACAALtogEAAq7EAQAC+KwCAAKroAEAApm6AQAC6tsBAAKqngIAAou/" &
    "AQACxMIBAAKX0AEAAofnAQAChq0CAAKppAEAAo+oAQAC5bgBAAKTzAEAAs7OAQACqNEBAALl2QEAAoboAQAC4usBAAL5/gEA" &
    "As+RAgAC4ZECAALMowIAAuKtAgACv6YBAAK63QEAAp2oAQAC0OMBAAKY6QEAAvqLAgACo60CAALXuAIAAp+9AgACl88BAALL" &
    "2wEAAuiDAgACy/UBAAKg9gEAApL5AQACwOUBAAKZ4QEAAtiWAgACwJ0BAAK2hgIAArqkAQACh6QBAAKmvQEAAtPFAQAC1vkB" &
    "AAKFtwEAAp7aAQACtM0BAAK7ngIAAsyQAgACzawCAAKLkwIAAtO9AQACwKIBAALAqwEABtqwAQAE9MwBAAbeowEAAqrmAQAC" &
    "yu0BAAK88gEAAt7yAQAC5fIBAAKP8wEAAtauAgACvvkBAAK9/wEABJKMAgAE+JUCAAa4oAIAAv2hAgAI77ECAAL8sQIAAqiy" &
    "AgACtLsCAALeoQIAAretAgACrp8BAALnoQEAAs2iAQACyaUBAALkpQEAAtGmAQACnasBAAKGrAEAAuisAQACwLABAAKosQEA" &
    "AuS4AQAC7rgBAAKUwQEAAujCAQACjsMBAALywwEAAs/KAQAC4ssBAAKRzQEAAoXRAQAC99oBAAKa3AEAAqLeAQAC7uIBAAKr" &
    "5AEAAqLoAQACkfEBAAK+8gEAAsnyAQACyPIBAALQ8gEAAtbyAQAC3fIBAAKN8wEAAo7zAQACwPQBAAKB9QEAAsD3AQAC9PsB" &
    "AAKJ/AEAAsH8AQAC8v4BAAKFgAIAAu2DAgAC+YQCAAL5hAIAAteIAgACkJICAAKWkwIAAoGWAgACuZYCAALTmQIAAoiaAgAC" &
    "tp8CAAK4oAIAAuOtAgAC/68CAAK7sAIAAvXAAQAC7oUJAAKYhAIABqacAQACtaMBAALoogEAAoCfAQACxaIBAAKAowEAAsel" &
    "AQAC+qUBAAKdqwEAAtWqAQACmasBAALiqwEAAtqwAQACs7EBAALEsgEAAtSyAQAC4rQBAAKotgEAAtK9AQAC2b0BAALpvgEA" &
    "Aq2/AQAC2MEBAALOwgEAAojCAQACjsMBAALgwgEAAvLDAQACtMQBAALExwEAApzIAQAC0sgBAALWygEAAvTMAQACl84BAAKb" &
    "zgEAAtbOAQAC+dYBAAK61wEAAsHaAQAC290BAALL3QEAAqLeAQACnuABAALu4gEAAqfvAQACteQBAAKv5QEAAqrmAQAC8egB" &
    "AAKG6gEAArvqAQACnewBAAKf7AEAAsrtAQAC2+0BAAL07QEAAsruAQACwO4BAALM8QEAArH1AQACwPcBAAL7+AEAAtv6AQAC" &
    "9PsBAAK+/gEAAoWAAgAC0oYCAALvhwIAAvmOAgACwZICAAKGkwIAApaTAgACv5UCAAL4lQIAAsuVAgACgZYCAAL+lQIAAu2V" &
    "AgACuZYCAAKKlwIAAoiaAgACuJ4CAALyoAIAApmjAgAC9qQCAAL8rAIAAuOtAgAC1q4CAALbrwIAAv+vAgACi7ACAAK7sAIA" &
    "ApK2AgACnL8CAALK0AgAAsTQCAAC1ecIAAKddwACmIABAAK5gAEAAsmkCQAC0LkJAALT/QkAAsO+AgACjr8CAIgB2Qu0CwTy" &
    "C7cLFukLwQsC6QvCCwLJ9gPBCwLJ9gPCCwLQC7cLAtALuAsC0Au8CwLRC7wLAtILvAsC0wu8CwLUC7wLAtULvAsC1gu8CwTY" &
    "C7wLAtkLvAsC2gu8CwLbC7wLAtwLvAsE3gu8CwTgC7wLAuELvAsE4wu8CwLkC7wLBOYLvAsC5wu8CwLoC7wLAukLvAsC6gu8" &
    "CwLVC7kLAtELvwsC2wu/CwLkC78L9ynSiwSHBjfaiwSHBu0qmaEEuqEEBZuhBLqhBB+loQS6oQSHArGiBKeiBAOyogSnogS5" &
    "CMemBL6mBAPHpgTXpgRvgqcEyacEBYSnBLunBBOLpwTCpwQHkKcEyacEacKnBMKnBAXCpwS4pwQDwqcEyacE5wO5qQS6qQQD" &
    "uakEsKkEBbmpBL2pBPkDuKsEr6sEA7mrBK+rBPsNtbIEsLIE058CnsIFnsIFA57CBanCBQOewgWfwgUDqcIFn8IFA57CBaDC" &
    "BQOhwgWfwgUDosIFn8IFA6HCBaDCBYEx59oF59oFA+PaBefaBQPp2gXn2gXojwPXogflogcC2KIH5aIHAt+iB+6iBwLfogfv" &
    "ogcC36IH8KIHAt+iB/GiBwLfogfyogeuAbmjB+WiBwK6owflogcCu6MH7qIHAryjB+6iBwK7owfvogcCvKMH76IHgJkJvZwB" &
    "AAK4nAEAAsGcAQACooIIAALgngEAAq6fAQACu58BAAKCoAEAAvqgAQACmaEBAALnoQEAAs+hAQACnmkAArqMCAACzaIBAALU" &
    "ogEAAuSiAQAC96IBAAKciggAArlpAALnogEAAo2jAQACy4oIAAKXowEAAqSjAQACzJ0BAAKsowEAArWjAQAC36MKAAL1owEA" &
    "AoOkAQAC32kAArukAQACxqQBAALypAEAAvekAQAClWoAAselAQACyaUBAALkpQEAAvqlAQAChaYBAAKGpgEAApemAQACyaYB" &
    "AALRpgEAAtqmAQAC86YBAAL9pgEAAv+mAQAC/6YBAAL/pgEAAqyUCAAC8OABAALKpwEAAt+nAQAC45YIAALrpwEAAvGnAQAC" &
    "hqgBAAKeqQEAArioAQACyKgBAALoqAEAAqKpAQAC9qkBAAKQqgEAAtOqAQAC46oBAAKEqwEAAoSrAQACmasBAAKrqwEAArOr" &
    "AQACwqsBAAKWrgEAAoasAQACl64BAALRrAEAAvSsAQACh6QBAALusQEAAs6vAQAC9K8BAAKNsAEAAouvAQACsrABAAKxsAEA" &
    "AqyxAQAC5KkIAALysQEAAvexAQAChrIBAAKasgEAAqKyAQAC4rIBAAKorQgAAuqtCAAC7LMBAAKbtAEAAqe0AQAC2LMBAALm" &
    "tAEAAu5tAAL8bQACiLYBAAK+tgEAAr62AQACyLMIAALDtwEAAti3AQAC57cBAALztwEAApi2CAAC/7cBAAKGuAEAAtO+AQAC" &
    "orgBAAKBbwAC4LgBAALuuAEAAsC5AQACjbkBAALkuwgAAsO6AQAC5rsIAALuugEAAuu6AQAC/LoBAALhuwEAAuK7AQACr3AA" &
    "Av27AQACqLwBAAK9vAEAAum8AQAC4nAAAoPDCAAC/HAAArC9AQACs70BAAK2vQEAAsq9AQACkscKAAL+vQEAArHGCAACscYI" &
    "AAKBhAIAAqK+AQACor4BAALHcQACuOUIAALawwkAAuK+AQAC674BAALjcQACmr8BAALNvwEAAte/AQAC+b8BAAKBwQEAArpy" &
    "AAKccgAClMEBAALUzQgAAsfBAQACyMIBAALMwgEAAs7CAQACzMIBAAL6wgEAAo7DAQACssMBAAKkwwEAAq/DAQAC3sMBAALy" &
    "wwEAAvbDAQACkMQBAAKbxAEAAt3EAQACscUBAALUxQEAAtDGAQACjNYIAAK9xgEAAvzFAQAC6MYBAAKDxwEAAuTHAQAC8dcI" &
    "AAKiyAEAAsXHAQACqccBAAKudAAC6cgBAAL+yAEAAp3JAQAC98gBAALsdAACz8oBAALsygEAAorgCAAC48sBAAL4zQEAAsnM" &
    "AQACmXYAApHNAQACiHYAAuR1AAKSowEAApWjAQACgM4BAAKczQEAAq2BAgAC2YcBAAKXzgEAApvOAQACoc4BAALezgEAAtPO" &
    "AQACw+cIAALJdgAC+s8BAAKFzwEAAtLQAQAChdEBAALt6AgAAo7RAQACn9ABAAKU0gEAAp13AALC0gEAAqPTAQAC6tMBAAKo" &
    "1QEAAqPtCAAC29UBAAKYeAACodYBAAKn8QgAAtTWAQACzngAAvLWAQACn9cBAAK61wEAArvXAQACjfUIAAKLuggAAvr1CAAC" &
    "ztgBAAK8+QgAAr/ZAQACzdkBAALn2AEAApbaAQACvtoBAAL32gEAAsHaAQAC6doBAAL42gEAAoXbAQACnvoIAAK02gEAAq/c" &
    "AQAC7twBAAKzegACy90BAALH3QEAAtH9CAAC+dsBAALu3gEAAt7+CAACjv8IAALG3wEAArngAQACnuABAAKb4AEAApZ7AALK" &
    "4AEAAv3gAQAC9+ABAAKt4QEAAqWKCAACxeIBAALjhAkAApzjAQACq4cJAAKo5AEAArXkAQAC0OQBAAKIjAkAAoDlAQACleUB" &
    "AAK1jgkAApSQCQAC+uYBAAKL5wEAAqx9AAKl5wEAArh9AAK4fQACx+gBAALc6AEAAvHoAQAChekBAALK6QEAApt+AAKk6gEA" &
    "AraYCQACvuoBAAKSmQkAAvDqAQACn8MIAAKQ7AEAAqGfCQACuJ8JAALEoAkAAvx/AAKIgAEAAvTtAQAC86EJAALyoQkAApmi" &
    "CQACs6IJAAKe7gEAAp/uAQACn+4BAALK7gEAArmAAQACi+8BAALGgAEAApaBAQACnagJAALO8AEAAozxAQACzPEBAALjgQEA" &
    "AqasCQAC1vIBAAKarQkAAsWtCQACj/MBAALr8wEAAq+CAQACwPQBAALK9AEAAs/0AQAC/LIJAAKntQkAAqe1CQAC7vUBAAKC" &
    "hAEAAqu3CQACxvcBAALJ9wEAAqeEAQACgLkJAALS+QEAAqCFAQAC6PkBAALj+QEAAoD6AQAChr8JAALj+gEAAoGGAQACx/sB" &
    "AAKC/AEAAsX8AQACtIYBAAKoxAkAAsfECQAC2YYBAALZxQkAAvr+AQACvsYJAAKV/wEAAvr/AQAChYACAALayQkAAqPKCQAC" &
    "4IACAAKoywkAAvCAAgAC3+YIAALVhwEAArKBAgACg4ICAAKLiAEAAr6CAgACtbUBAAKnzwkAArXPCQACk+cIAAKc5wgAAoGE" &
    "AgAChIQCAAKenwIAAuuIAQACkYUCAAKLhQIAAp2FAgACs6UBAAKxhQIAArOFAgACvYUCAALmhQIAArzWCQAC5YUCAAKdhgIA" &
    "AuOGAgACrYcCAAKjhgIAAr2HAgAC54cCAALXiAIAAtOGAgACyocCAALMhwIAAtyHAgACttgJAALr2gkAAtXZCQACq4oBAALx" &
    "iQIAAvOJAgAClooCAALK5wkAAuSKAgACrN4JAALdigEAAuGKAQACsd8JAALS4QkAAuuKAQAC0IwCAALcjAIAAueMAgAC6YwC" &
    "AAKpjQIAAoiNAgACjo4CAALijQIAAvmOAgACqI4CAALrjgIAAoaPAgAC14sBAALhjwIAAoGQAgAC+YsBAALgkAIAAuOQAgAC" &
    "5+wJAALXkQIAAt6RAgACtYwBAAL6kQIAArtpAAKu8QkAAubyCQACvo0BAALHjQEAAqCVAgAC7ZUCAAKKlwIAAtWYAgACqPkJ" &
    "AAKrmQIAAsGZAgACm5oCAAL3mgIAAq/+CQAChJAIAALLmwIAArybAgAC8JsCAALekQgAAtSdAgACuJ4CAALSiwoAAu2LCgAC" &
    "lKECAALxoQIAApGiAgACro4KAAKbogIAArikAgAC16UCAALYpQIAAvykAgAC+acCAAKVqAIAAvqXCgACi6sCAAKVkwEAArer" &
    "AgAC95oKAALmkwEAAsOtAgACsrsBAAKjrgIAAsWiCgACmqQKAALulAEAAvaUAQAC4K8CAAKKqAoAArKVAQAClqkKAAKLsAIA" &
    "AouwAgACqbACAAK2qwoAAuKxAgACs5YBAAKpsgIAAqezAgACwrMCAAL+swIAAs6XAQACsLYKAAKStgIAAsC4AgAC/bkCAALO" &
    "mQEAAu2ZAQAC57oCAALOwQoAAviZAQAChcIKAAKOxAoAApHFCgACu70CAALWmgEAAvm9AgAC/r0CAAKFvgIAAo++AgAClr4C" &
    "AAK7vgIAAoDMCgA="
  # 428 Bidi_Mirroring_Glyph pairs: varint(c - previous c), varint(zigzag(mirror - c))
  mirrorData =
    "KAIBARMEAgMdBAIDHgQCAy4gEB//HAIBAQECAQHeDgIBAZ0TAgEBCwIBATcCAQEPAgEB+gIGAQYBBgEFAQUBBQjAHwq+JwGG" &
    "HgH0HQH8HQKUIxgCAQEGlAICDgcNBgIBAQECAQEPAgEBAQIBAQECAQEBAgEBAwIBAQECAQEBAgEBAQIBAQECAQEBAgEBAQIB" &
    "AQECAQEBAgEBAQIBAQECAQEBAgEBAQIBAQECAQEBAgEBBAIBAQECAQEGwBwKAgEBA/AgAvggAfQgAvQgBQIBAQECAQEBAgEB" &
    "AQIBAQHIFBECAQEBAgEBAZMCAwIBAQUCAQEBAgEBAQIBAQECAQEBAgEBAQIBAQECAQEBAgEBAQIBAQECAQEBAgEBAQIBAQMC" &
    "AQEBEAEQARACDgEOAw8BDwEPAQ0BDQoCAQEBAgEBHgIBAb4IAgEBAQIBAQECAQEBAgEBAQIBAQECAQEBAgEBTgIBAQECAQEC" &
    "AgEBAgQCAwgCAQEGxxQBAgEBBAIBAQECAQEBAgEBAQIBAQECAQEBAgEBAQIBAZQDAgEBAQIBAQECAQEBAgEBAQIBAQEGAQIB" &
    "AQEFAQIBAQECAQEBAgEBAQIBAQPzHQX7HQOFHgECAQEDAgEBAQIBAQECAQEBAgEBCb8cCAIBAQMCAQEKAgEBAQIBAQICAQED" &
    "AgEBAQIBAQ0CAQEMvx8DAgEBAwIBAS4CAQEBAgEBBgIBAQcCAQEnAgEBFAIBAQECAQEBAgEBAQIBAQECAQEBAgEBAQIBAQEC" &
    "AQEBAgEBAQIBAQECAQEBAgEBAQIBAQECAQEBAgEBAQIBAQECAQEBAgEBAQIBAQECAQEBAgEBBAIBAQECAQEBAgEBAQIBAQIC" &
    "AQEBAgEBAQIBAQECAQEBAgEBAQIBAQECAQEBAgEBAQIBAQECAQEBAgEBAQIBAQECAQEBAgEBAQIBAQECAQEBAgEBAQIBAQEC" &
    "AQEBAgEBCO8gBfMgAfcgAfMgBwIBAQGTIwkCAQEBAgEBhAK9J4QEAgEBAQIBAQQCAQECAgEBDwIBAQMCAQEBAgEBAQIBAQEC" &
    "AQEBAgEBLAIBAQECAQEBAgEBAQIBAawDAgEBAQIBAQECAQEBAgEBAQIBAQMCAQEBAgEBAQIBAQECAQG+nAMCAQEBAgEBAQIB" &
    "AQYCAQGjAQIBARMEAgMdBAIDHgQCAwICAQECAgEB"
  # 834 joining types (ArabicShaping.txt): varint((c - previous c) shl 3 or type)
  joiningData =
    "gGAICAgICBgYqwEICgoKCgsKCwoLCwsLCwoKCgoLCwsLCwsLCwsLCwsLCwsLCwsLCwsKCwujAgsSCgoICgoKCwsLCwsLCwsL" &
    "CwsLCwsLCwoKCgoKCgoKCgoKCgoKCgoKCgsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCgsLCgoKCgoK" &
    "CgoKCwoLCgsLCgoSQIoBClsLCxuGAQwTCwsNDQoKCgsLCwsKCwsLCwsLCwsLCgsNCwoLCw3yAQsLCwsLCwsLCwsLCgoKCwsL" &
    "CwsLCwsLCwsLCwsLCgoLCwsLCgsKCgsLCwoKCwsLCwsL2wQLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLC4MBsgQL" &
    "CwsLCwoKCwoLCwsLCwsLCwsLCgsKCgpDCAsLCwsICgsKCjIKCgoKCgoKCgoKCgoKCgoKCgoLCwsLCAgLCwsLCwoLCAh7CwsL" &
    "CwsLCwsLCgoKCAoLCwoKCwsLCwsLCgsLCwsLCwsLCwsLCwsLC9ABoPIBCxsgkwELCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsL" &
    "CwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLQAgICAgODgsL" &
    "CwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsTkHYLkAK4AwgICLv9EAsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsL" &
    "CwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsJCOukDAsLCwsKCAoICgoICAkKCgoKCgsLCwsJCwsLCwsKCwsLCggICjsLCwsKiwkK" &
    "CwoKCgsLCwoLCwoLCgoLCsIBCgoKCwsIiRULCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsKC/oZCwsTC8sGCwsK" &
    "CwsLCwsLCwsLCwsLCwsLCwsIYwsLCuMBCwsLCgoLCwsLCwsLCwsLCwv7AggLCwoKCggLCgoLCwoLCwgLCgoLCAgICAoLCZAP" &
    "gAGbgxsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsL" &
    "Rg=="

const
  # general categories (as the tables code them)
  gcLetter = 1'u8
  gcNd = 2'u8
  gcMn = 3'u8
  gcMc = 4'u8
  gcMe = 5'u8
  gcCf = 6'u8
  gcZs = 7'u8
  # joining types (also L 1, R 2, D 3, ALAPH 4, DALATH RISH 5: the state table's columns)
  jtU = 0'u8
  jtT = 6'u8
  jtX = 7'u8

var
  ucdReady = false
  gcBmp, cccBmp, joinBmp: seq[uint8]
  gcHi: seq[(int32, uint8)]
  cccHi: seq[(int32, int32, uint8)]
  joinHi: Table[int32, uint8]
  decomp: Table[int32, (int32, int32)]
  compose: Table[int64, int32]
  mirror: Table[int32, int32]

proc readVarints(s: string): seq[int] =
  let raw = decode(s)
  var i = 0
  while i < raw.len:
    var v = 0
    var sh = 0
    while true:
      let b = ord(raw[i])
      inc i
      v = v or ((b and 127) shl sh)
      sh += 7
      if b < 128: break
    result.add v

proc readRaw(s: string): string = decode(s)

proc initUcd() =
  if ucdReady: return
  ucdReady = true
  gcBmp = newSeq[uint8](0x10000)
  cccBmp = newSeq[uint8](0x10000)
  joinBmp = newSeq[uint8](0x10000)
  # general category
  let g = readVarints(gcData)
  var starts: seq[(int, uint8)]
  var at = 0
  for v in g:
    at += v shr 4
    starts.add (at, uint8(v and 15))
  for k, (s, c) in starts:
    let e = if k + 1 < starts.len: starts[k + 1][0] else: 0x110000
    if s < 0x10000:
      for cp in s ..< min(e, 0x10000): gcBmp[cp] = c
    if e > 0x10000: gcHi.add (int32(max(s, 0x10000)), c)
  # combining classes (varint, varint, raw byte)
  let raw = readRaw(cccData)
  var i = 0
  var last = 0
  proc rv(): int =
    var sh = 0
    while true:
      let b = ord(raw[i])
      inc i
      result = result or ((b and 127) shl sh)
      sh += 7
      if b < 128: break
  while i < raw.len:
    let first = last + rv()
    let stop = first + rv()
    let c = uint8(ord(raw[i]))
    inc i
    for cp in first .. stop:
      if cp < 0x10000: cccBmp[cp] = c
    if stop >= 0x10000: cccHi.add (int32(max(first, 0x10000)), int32(stop), c)
    last = stop
  # decompositions and compositions
  let d = readVarints(decompData)
  var c = 0
  var k = 0
  while k + 2 < d.len:
    c += d[k] shr 1
    let composes = (d[k] and 1) != 0
    decomp[int32(c)] = (int32(d[k + 1]), int32(d[k + 2]))
    if composes: compose[(int64(d[k + 1]) shl 21) or int64(d[k + 2])] = int32(c)
    k += 3
  # mirroring
  let m = readVarints(mirrorData)
  c = 0
  k = 0
  while k + 1 < m.len:
    c += m[k]
    let z = m[k + 1]
    let delta = if (z and 1) != 0: -((z + 1) shr 1) else: z shr 1
    mirror[int32(c)] = int32(c + delta)
    k += 2
  # joining types
  for x in joinBmp.mitems: x = jtX
  let j = readVarints(joiningData)
  c = 0
  for v in j:
    c += v shr 3
    if c < 0x10000: joinBmp[c] = uint8(v and 7)
    else: joinHi[int32(c)] = uint8(v and 7)

proc genCat(u: int): uint8 =
  if u < 0x10000: return gcBmp[u]
  var lo = 0
  var hi = gcHi.len - 1
  result = 8
  while lo <= hi:
    let mid = (lo + hi) div 2
    if gcHi[mid][0] <= u:
      result = gcHi[mid][1]
      lo = mid + 1
    else: hi = mid - 1

proc combiningClass(u: int): int =
  if u < 0x10000: return int(cccBmp[u])
  for r in cccHi:
    if u >= r[0] and u <= r[1]: return int(r[2])
  0

const modifiedCcc = block:
  var t: array[256, uint8]
  for i in 0 .. 255: t[i] = uint8(i)
  # Hebrew
  t[10] = 22; t[11] = 15; t[12] = 16; t[13] = 17; t[14] = 23; t[15] = 18; t[16] = 19
  t[17] = 20; t[18] = 21; t[19] = 14; t[20] = 24; t[21] = 12; t[22] = 25; t[23] = 13
  t[24] = 10; t[25] = 11; t[26] = 26
  # Arabic: shadda sorts before the vowel marks
  t[27] = 28; t[28] = 29; t[29] = 30; t[30] = 31; t[31] = 32; t[32] = 33; t[33] = 27
  t[34] = 34; t[35] = 35; t[36] = 36
  # Telugu, Thai, Lao, Tibetan
  t[84] = 4; t[91] = 5; t[103] = 3; t[107] = 107; t[118] = 118; t[122] = 122
  t[129] = 129; t[130] = 132; t[132] = 131
  t

proc modifiedClass(u: int): int =
  if u == 0x1A60 or u == 0x0FC6: return 254
  if u == 0x0F39: return 127
  int(modifiedCcc[combiningClass(u)])

proc isDefaultIgnorable(ch: int): bool =
  ## HarfBuzz's (narrower) Default_Ignorable_Code_Point.
  let plane = ch shr 16
  if plane == 0:
    case ch shr 8
    of 0x00: ch == 0x00AD
    of 0x03: ch == 0x034F
    of 0x06: ch == 0x061C
    of 0x17: ch in 0x17B4 .. 0x17B5
    of 0x18: ch in 0x180B .. 0x180F
    of 0x20: ch in 0x200B .. 0x200F or ch in 0x202A .. 0x202E or ch in 0x2060 .. 0x206F
    of 0xFE: ch in 0xFE00 .. 0xFE0F or ch == 0xFEFF
    of 0xFF: ch in 0xFFF0 .. 0xFFF8
    else: false
  elif plane == 1: ch in 0x1D173 .. 0x1D17A
  elif plane == 0xE: ch in 0xE0000 .. 0xE0FFF
  else: false

proc mirrorOf(u: int): int = int(mirror.getOrDefault(int32(u), int32(u)))

proc joiningOf(u: int; gc: uint8): uint8 =
  var t = if u < 0x10000: joinBmp[u] else: joinHi.getOrDefault(int32(u), jtX)
  if t == jtX:
    t = if gc == gcMn or gc == gcMe or gc == gcCf: jtT else: jtU
  t

const
  sBase = 0xAC00
  lBase = 0x1100
  vBase = 0x1161
  tBase = 0x11A7
  lCount = 19
  vCount = 21
  tCount = 28
  nCount = vCount * tCount
  sCount = lCount * nCount

proc decompose(ab: int; a, b: var int): bool =
  let si = ab - sBase
  if si >= 0 and si < sCount:
    if si mod tCount != 0:
      a = sBase + (si div tCount) * tCount
      b = tBase + si mod tCount
    else:
      a = lBase + si div nCount
      b = vBase + (si mod nCount) div tCount
    return true
  let r = decomp.getOrDefault(int32(ab), (-1'i32, 0'i32))
  if r[0] < 0: return false
  a = int(r[0])
  b = int(r[1])
  true

proc composePair(a, b: int; ab: var int): bool =
  if a >= sBase and a < sBase + sCount and b > tBase and b < tBase + tCount and
     (a - sBase) mod tCount == 0:
    ab = a + (b - tBase)
    return true
  if a >= lBase and a < lBase + lCount and b >= vBase and b < vBase + vCount:
    ab = sBase + ((a - lBase) * vCount + (b - vBase)) * tCount
    return true
  let r = compose.getOrDefault((int64(a) shl 21) or int64(b), -1'i32)
  if r < 0: return false
  ab = int(r)
  true

proc spaceFallback(u: int): int =
  ## How wide a space is when the font has no glyph for it (HarfBuzz's
  ## estimates): 1..16 an em divided by it, 17 4/18 em, 18 a space,
  ## 19 a figure, 20 a punctuation space, 21 narrow; 0 not a space.
  case u
  of 0x0020, 0x00A0: 18
  of 0x2000, 0x2002: 2
  of 0x2001, 0x2003, 0x3000: 1
  of 0x2004: 3
  of 0x2005: 4
  of 0x2006: 6
  of 0x2007: 19
  of 0x2008: 20
  of 0x2009: 5
  of 0x200A: 16
  of 0x202F: 21
  of 0x205F: 17
  else: 0

# ---- scripts and languages ------------------------------------------------------------

const rtlScripts = ["Arab", "Hebr", "Syrc", "Thaa", "Nkoo", "Samr", "Mand", "Mani", "Phlp",
                    "Avst", "Cprt", "Khar", "Phnx", "Lydi", "Sarb", "Prti", "Phli", "Orkh",
                    "Narb", "Nbat", "Palm", "Hatr", "Hung", "Adlm", "Rohg", "Sogo", "Sogd",
                    "Elym", "Chrs", "Yezi", "Ougr", "Mend", "Merc", "Mero", "Armi", "Osge"]

proc scriptOfChar(u: int): string =
  ## The script of a character, for the scripts this module tells apart
  ## ("" for common and inherited characters).
  if u in 0x0600 .. 0x06FF or u in 0x0750 .. 0x077F or u in 0x0870 .. 0x08FF or
     u in 0xFB50 .. 0xFDFF or u in 0xFE70 .. 0xFEFF or u in 0x10EC0 .. 0x10EFF or
     u in 0x1EE00 .. 0x1EEFF:
    if u in [0x060C, 0x061B, 0x061C, 0x061F, 0x0640, 0x06DD, 0x08E2, 0xFD3E, 0xFD3F] or
       u in 0x064B .. 0x0655 or u == 0x0670: return ""
    return "Arab"
  if u in 0x0590 .. 0x05FF or u in 0xFB1D .. 0xFB4F: return "Hebr"
  if u in 0x0700 .. 0x074F or u in 0x0860 .. 0x086F: return "Syrc"
  if u in 0x0780 .. 0x07BF: return "Thaa"
  if u in 0x07C0 .. 0x07FF: return "Nkoo"
  if u in 0x0370 .. 0x03FF or u in 0x1F00 .. 0x1FFF: return "Grek"
  if u in 0x0400 .. 0x052F or u in 0x2DE0 .. 0x2DFF or u in 0xA640 .. 0xA69F or
     u in 0x1C80 .. 0x1C8F: return "Cyrl"
  if u in 0x0041 .. 0x005A or u in 0x0061 .. 0x007A or u == 0xAA or u == 0xBA or
     u in 0x00C0 .. 0x024F and u notin [0xD7, 0xF7] or u in 0x1E00 .. 0x1EFF or
     u in 0x2C60 .. 0x2C7F or u in 0xA720 .. 0xA7FF or u in 0xFB00 .. 0xFB06 or
     u in 0xFF21 .. 0xFF3A or u in 0xFF41 .. 0xFF5A or u in 0x0250 .. 0x02AF:
    return "Latn"
  ""

type ScriptInfo = object
  iso: string              ## "Arab", "Latn"; "" common
  tags: seq[string]        ## OpenType script tags to look for, in order
  rtl: bool                ## written right to left
  arabic: bool             ## shaped by the Arabic shaper (Arabic, Syriac)

proc scriptInfo(script: string; cps: openArray[int]): ScriptInfo =
  var iso = script.strip
  if iso.len == 0:
    for u in cps:
      iso = scriptOfChar(u)
      if iso.len > 0: break
  elif iso.len >= 3:
    iso = toUpperAscii(iso[0]) & toLowerAscii(iso[1 .. ^1])
    if iso.len == 3: iso.add ' '
  if iso in ["Dflt", "Zyyy", "Zinh", "Zzzz", "Dflt "]: iso = ""
  if iso == "Lao ": iso = "Laoo"
  if iso == "Nko ": iso = "Nkoo"
  if iso == "Vai ": iso = "Vaii"
  if iso == "Yi  ": iso = "Yiii"
  if iso == "Kana": iso = "Hira"
  result.iso = iso
  if iso.len == 4:
    case iso
    of "Hira", "Hrkt": result.tags = @["kana"]
    of "Laoo": result.tags = @["lao "]
    of "Yiii": result.tags = @["yi  "]
    of "Nkoo": result.tags = @["nko "]
    of "Vaii": result.tags = @["vai "]
    else: result.tags = @[toLowerAscii(iso[0]) & iso[1 .. 3]]
  result.rtl = iso in rtlScripts
  result.arabic = iso in ["Arab", "Syrc"]

const langTags = {"ar": "ARA ", "fa": "FAR ", "ur": "URD ", "ks": "KSH ", "sd": "SND ",
                  "ms": "MLY ", "ku": "KUR ", "ckb": "KUR ", "ps": "PAS ", "ug": "UYG ",
                  "en": "ENG ", "de": "DEU ", "fr": "FRA ", "es": "ESP ", "it": "ITA ",
                  "pt": "PTG ", "nl": "NLD ", "tr": "TRK ", "az": "AZE ", "ca": "CAT ",
                  "ro": "ROM ", "mo": "MOL ", "la": "LAT ", "pl": "PLK ", "ru": "RUS ",
                  "sr": "SRB ", "mk": "MKD ", "bg": "BGR ", "uk": "UKR ", "el": "ELL ",
                  "he": "IWR ", "sv": "SVE ", "da": "DAN ", "nb": "NOR ", "no": "NOR ",
                  "fi": "FIN ", "hu": "HUN ", "cs": "CSY ", "sk": "SKY ", "hr": "HRV ",
                  "ja": "JAN ", "ko": "KOR ", "zh": "ZHS ", "vi": "VIT ", "id": "IND ",
                  "rhg": "RHG ", "mh": "MAH ", "nv": "NAV ", "crh": "CRT "}.toTable

proc langTag(lang: string): string =
  ## A language as an OpenType language system tag: a BCP 47 code ("ur",
  ## "fa-IR") or the tag itself ("URD ").
  let l = lang.strip
  if l.len == 0: return ""
  if l.len == 4 and l == toUpperAscii(l) or (lang.len == 4 and lang[3] == ' '):
    return lang
  let primary = toLowerAscii(l.split({'-', '_'})[0])
  if primary in langTags: return langTags[primary]
  var t = toUpperAscii(primary)
  while t.len < 4: t.add ' '
  t[0 .. 3]

# ---- reading the layout tables --------------------------------------------------------

type
  LookupInfo = object
    kind: int                 ## lookup type, extensions resolved
    props: int                ## lookup flag, mark filtering set shl 16
    subs: seq[int]            ## where the subtables are
    digest: seq[uint64]       ## the glyphs that can start it (nil: not made yet)

  LayoutTable = object
    at: int                   ## -1: the font has none
    scripts, features, lookups, variations: int
    looks: seq[LookupInfo]

  FeatureMap = object
    tag: string
    index: array[2, int]
    stage: array[2, int]
    shift: int
    mask, oneMask: uint32
    autoZwnj, autoZwj, random: bool
    needsFallback: bool

  LookupMap = object
    index: int
    mask: uint32
    autoZwnj, autoZwj, random: bool

  Pause = enum pNone, pStch, pArabicFallback   ## (HarfBuzz's pauses; stch and the fallback are not done)

  StageMap = object
    last: int
    pause: Pause

  Plan = ref object
    rtl: bool                  ## the direction it was made for
    arabicShaper: bool
    chosen: array[2, string]
    features: seq[FeatureMap]
    lookups: array[2, seq[LookupMap]]
    stages: array[2, seq[StageMap]]
    globalMask: uint32
    arabicMasks: array[8, uint32]
    rtlmMask, fracMask, numrMask, dnomMask, kernMask: uint32
    hasFrac: bool
    applyGpos, applyKern, zeroMarks, adjustMarks, fallbackClasses: bool

  Layout = ref object of RootObj
    d: ptr UncheckedArray[uint8]
    n: int
    t: array[2, LayoutTable]   ## GSUB, GPOS
    gdef: int
    glyphClass, markAttach, markSets, varStore: int
    plans: Table[string, Plan]
    numGlyphs: int
    hasKern: bool              ## a legacy kern table

template u8(L: Layout; i: int): int =
  (let j = i; if j >= 0 and j < L.n: int(L.d[j]) else: 0)

proc u16(L: Layout; i: int): int {.inline.} =
  if i >= 0 and i + 2 <= L.n: (int(L.d[i]) shl 8) or int(L.d[i + 1]) else: 0

proc i16(L: Layout; i: int): int {.inline.} =
  let v = L.u16(i)
  if v >= 0x8000: v - 0x10000 else: v

proc u32(L: Layout; i: int): int {.inline.} =
  (L.u16(i) shl 16) or L.u16(i + 2)

proc tag(L: Layout; i: int): string =
  result = newString(4)
  for k in 0 .. 3: result[k] = char(L.u8(i + k))

proc coverage(L: Layout; at, g: int): int =
  ## The coverage index of glyph `g` (-1 not covered).
  if at <= 0: return -1
  case L.u16(at)
  of 1:
    var lo = 0
    var hi = L.u16(at + 2) - 1
    while lo <= hi:
      let m = (lo + hi) shr 1
      let x = L.u16(at + 4 + 2 * m)
      if x < g: lo = m + 1
      elif x > g: hi = m - 1
      else: return m
    -1
  of 2:
    var lo = 0
    var hi = L.u16(at + 2) - 1
    while lo <= hi:
      let m = (lo + hi) shr 1
      let r = at + 4 + 6 * m
      if L.u16(r + 2) < g: lo = m + 1
      elif L.u16(r) > g: hi = m - 1
      else: return L.u16(r + 4) + g - L.u16(r)
    -1
  else: -1

proc classOf(L: Layout; at, g: int): int =
  ## The class glyph `g` has in a class definition (0 when none).
  if at <= 0: return 0
  case L.u16(at)
  of 1:
    let first = L.u16(at + 2)
    if g >= first and g < first + L.u16(at + 4): L.u16(at + 6 + 2 * (g - first)) else: 0
  of 2:
    var lo = 0
    var hi = L.u16(at + 2) - 1
    while lo <= hi:
      let m = (lo + hi) shr 1
      let r = at + 4 + 6 * m
      if L.u16(r + 2) < g: lo = m + 1
      elif L.u16(r) > g: hi = m - 1
      else: return L.u16(r + 4)
    0
  else: 0

proc addCoverage(L: Layout; at: int; bits: var seq[uint64]) =
  ## Puts the glyphs of a coverage table in a bit set.
  template put(g: int) =
    let x = g
    if x shr 6 < bits.len: bits[x shr 6] = bits[x shr 6] or (1'u64 shl (x and 63))
  if at <= 0: return
  case L.u16(at)
  of 1:
    for i in 0 ..< L.u16(at + 2): put(L.u16(at + 4 + 2 * i))
  of 2:
    for i in 0 ..< L.u16(at + 2):
      let r = at + 4 + 6 * i
      for g in L.u16(r) .. min(L.u16(r + 2), bits.len * 64 - 1): put(g)
  else: discard

proc firstCoverage(L: Layout; table, kind, at: int): int =
  ## The coverage of a subtable's first glyph (0: any glyph may start it).
  let fmt = L.u16(at)
  if table == 0:
    case kind
    of 1, 2, 3, 4, 8: return at + L.u16(at + 2)
    else: discard
  else:
    case kind
    of 1, 2, 3, 4, 5, 6: return at + L.u16(at + 2)
    else: discard
  # contexts (GSUB 5, 6; GPOS 7, 8)
  let chain = (table == 0 and kind == 6) or (table == 1 and kind == 8)
  case fmt
  of 1, 2: at + L.u16(at + 2)
  of 3:
    if not chain:
      at + L.u16(at + 6)
    else:
      let back = L.u16(at + 2)
      let p = at + 4 + 2 * back
      if L.u16(p) == 0: 0 else: at + L.u16(p + 2)
  else: 0

proc readTable(L: Layout; tag: string; f: Face): LayoutTable =
  let (at, size) = f.tableRange(tag)
  result.at = -1
  if at < 0 or at + 10 > L.n or L.u16(at) != 1: return
  let stop = min(L.n, at + size)       # (counts a damaged table gives stop here)
  result.at = at
  result.scripts = at + L.u16(at + 4)
  result.features = at + L.u16(at + 6)
  result.lookups = at + L.u16(at + 8)
  if L.u16(at + 2) >= 1 and L.u32(at + 10) != 0: result.variations = at + L.u32(at + 10)
  let table = if tag == "GSUB": 0 else: 1
  let ext = if table == 0: 7 else: 9
  let count = min(L.u16(result.lookups), max(0, (stop - result.lookups - 2) div 2))
  for i in 0 ..< count:
    let lk = result.lookups + L.u16(result.lookups + 2 + 2 * i)
    var info = LookupInfo(kind: L.u16(lk), props: L.u16(lk + 2))
    let n = min(L.u16(lk + 4), max(0, (stop - lk - 6) div 2))
    if (info.props and 0x10) != 0: info.props = info.props or (L.u16(lk + 6 + 2 * n) shl 16)
    for k in 0 ..< n:
      var s = lk + L.u16(lk + 6 + 2 * k)
      var kind = L.u16(lk)
      if kind == ext and L.u16(s) == 1:
        kind = L.u16(s + 2)
        s = s + L.u32(s + 4)
        if k == 0: info.kind = kind
      if kind != info.kind: continue     # (subtables must agree)
      info.subs.add s
    result.looks.add info

proc layout(f: Face): Layout =
  ## The face's layout tables, read once and kept with it.
  if f.shaper != nil and f.shaper of Layout: return Layout(f.shaper)
  let L = Layout(gdef: -1, numGlyphs: f.numGlyphs, hasKern: f.tableRange("kern").at >= 0)
  (L.d, L.n) = f.fontBytes
  L.t[0] = L.readTable("GSUB", f)
  L.t[1] = L.readTable("GPOS", f)
  let (g, _) = f.tableRange("GDEF")
  if g >= 0 and g + 12 <= L.n and L.u16(g) == 1:
    L.gdef = g
    if L.u16(g + 4) != 0: L.glyphClass = g + L.u16(g + 4)
    if L.u16(g + 10) != 0: L.markAttach = g + L.u16(g + 10)
    if L.u16(g + 2) >= 2 and L.u16(g + 12) != 0: L.markSets = g + L.u16(g + 12)
    if L.u16(g + 2) >= 3 and L.u32(g + 14) != 0: L.varStore = g + L.u32(g + 14)
  L.varStore = if L.varStore == 0: -1 else: L.varStore
  f.shaper = L
  L

proc digestOf(L: Layout; table, li: int): lent seq[uint64] =
  ## The glyphs that can start lookup `li` (a bit set).
  if L.t[table].looks[li].digest.len == 0:
    var bits = newSeq[uint64]((L.numGlyphs + 64) shr 6 + 1)
    let info = L.t[table].looks[li]
    for s in info.subs:
      let c = L.firstCoverage(table, info.kind, s)
      if c == 0:
        for x in bits.mitems: x = not 0'u64
        break
      L.addCoverage(c, bits)
    L.t[table].looks[li].digest = bits
  L.t[table].looks[li].digest

template inDigest(dg: seq[uint64]; g: int): bool =
  (let x = g; x shr 6 < dg.len and (dg[x shr 6] and (1'u64 shl (x and 63))) != 0)

proc glyphProps(L: Layout; g: int): int =
  ## GDEF's class of glyph `g` as HarfBuzz keeps it: base 2, ligature 4,
  ## mark 8 or its attachment class shl 8.
  if L.glyphClass <= 0: return 0
  case L.classOf(L.glyphClass, g)
  of 1: 2
  of 2: 4
  of 3: 8 or (L.classOf(L.markAttach, g) shl 8)
  else: 0

proc markSetCovers(L: Layout; set, g: int): bool =
  if L.markSets <= 0 or set >= L.u16(L.markSets + 2): return false
  L.coverage(L.markSets + L.u32(L.markSets + 4 + 4 * set), g) >= 0

# ---- script, language and feature lists ---------------------------------------------

proc findScript(L: Layout; t: LayoutTable; tags: seq[string]; chosen: var string): int =
  ## The script table to use (0 none), HarfBuzz's way: the script's own
  ## tags, then DFLT, dflt and latn.
  if t.at < 0: return 0
  let n = L.u16(t.scripts)
  proc find(tg: string): int =
    for i in 0 ..< n:
      if L.tag(t.scripts + 2 + 6 * i) == tg: return t.scripts + L.u16(t.scripts + 2 + 6 * i + 4)
    0
  for tg in tags:
    let s = find(tg)
    if s != 0:
      chosen = tg
      return s
  for tg in ["DFLT", "dflt", "latn"]:
    let s = find(tg)
    if s != 0:
      chosen = tg
      return s
  chosen = ""
  0

proc findLangSys(L: Layout; script: int; lang: string): int =
  ## The language system table (0 none): the language's, then 'dflt', then
  ## the script's default.
  if script == 0: return 0
  let n = L.u16(script + 2)
  for want in [lang, "dflt"]:
    if want.len == 0: continue
    for i in 0 ..< n:
      if L.tag(script + 4 + 6 * i) == want: return script + L.u16(script + 4 + 6 * i + 4)
  if L.u16(script) != 0: script + L.u16(script) else: 0

proc featureTagAt(L: Layout; t: LayoutTable; index: int): string =
  L.tag(t.features + 2 + 6 * index)

proc featureTableAt(L: Layout; t: LayoutTable; index, variation: int): int =
  ## The feature table of feature `index`, or its substitute in feature
  ## variation record `variation` (-1 none).
  if variation >= 0 and t.variations > 0:
    let rec = t.variations + 8 + 8 * variation
    let subst = t.variations + L.u32(rec + 4)
    if L.u32(rec + 4) != 0:
      let n = L.u16(subst + 4)
      for i in 0 ..< n:
        let r = subst + 6 + 6 * i
        if L.u16(r) == index: return subst + L.u32(r + 2)
  t.features + L.u16(t.features + 2 + 6 * index + 4)

proc conditionHolds(L: Layout; at: int; coords: openArray[int]): bool =
  case L.u16(at)
  of 1:
    let axis = L.u16(at + 2)
    let c = if axis < coords.len: coords[axis] else: 0
    L.i16(at + 4) <= c and c <= L.i16(at + 6)
  of 3, 4:                         # and, or
    let n = L.u8(at + 2)
    let isAnd = L.u16(at) == 3
    for i in 0 ..< n:
      let ok = L.conditionHolds(at + L.u32(at + 3 + 4 * i), coords)
      if isAnd and not ok: return false
      if not isAnd and ok: return true
    isAnd
  of 5: not L.conditionHolds(at + L.u32(at + 2), coords)
  else: false

proc variationIndex(L: Layout; t: LayoutTable; coords: openArray[int]): int =
  ## The feature variation record that applies at `coords` (-1 none).
  if t.variations <= 0: return -1
  let n = L.u32(t.variations + 4)
  for i in 0 ..< n:
    let rec = t.variations + 8 + 8 * i
    let cs = if L.u32(rec) != 0: t.variations + L.u32(rec) else: 0
    var ok = true
    if cs != 0:
      for k in 0 ..< L.u16(cs):
        if not L.conditionHolds(cs + L.u32(cs + 2 + 4 * k), coords):
          ok = false
          break
    if ok: return i
  -1

# ---- the shaping plan -------------------------------------------------------------------

const
  fGlobal = 1
  fHasFallback = 2
  fManualZwnj = 4
  fManualZwj = 8
  fGlobalSearch = 16
  fRandom = 32
  fGlobalManualJoiners = fGlobal or fManualZwnj or fManualZwj
  fGlobalHasFallback = fGlobal or fHasFallback
  maxValue = 255

type
  FeatureInfo = object
    tag: string
    seq, maxValue, flags, defaultValue: int
    stage: array[2, int]

  Builder = object
    features: seq[FeatureInfo]
    current: array[2, int]
    pauses: array[2, seq[(int, Pause)]]

proc add(b: var Builder; tag: string; flags = 0; value = 1) =
  b.features.add FeatureInfo(tag: tag, seq: b.features.len + 1, maxValue: value, flags: flags,
                             defaultValue: (if (flags and fGlobal) != 0: value else: 0),
                             stage: b.current)

proc enable(b: var Builder; tag: string; flags = 0; value = 1) = b.add(tag, flags or fGlobal, value)

proc pause(b: var Builder; table: int; p = pNone) =
  b.pauses[table].add (b.current[table], p)
  inc b.current[table]

proc hasFeatureIn(L: Layout; ls: int; t: LayoutTable; tag: string): bool =
  if ls == 0: return false
  for i in 0 ..< L.u16(ls + 4):
    if L.featureTagAt(t, L.u16(ls + 6 + 2 * i)) == tag: return true

proc makePlan(L: Layout; si: ScriptInfo; lang: string; rtl: bool;
              features: openArray[Feature]; coords: openArray[int]): Plan =
  let p = Plan(rtl: rtl)
  var scriptAt, langAt: array[2, int]
  for k in 0 .. 1:
    scriptAt[k] = L.findScript(L.t[k], si.tags, p.chosen[k])
    langAt[k] = L.findLangSys(scriptAt[k], lang)
  p.arabicShaper = si.arabic and (p.chosen[0] != "DFLT" or si.iso == "Arab")
  var b: Builder
  b.enable("rvrn")
  b.pause(0)
  if rtl:
    b.enable("rtla")
    b.add("rtlm")
  else:
    b.enable("ltra")
    b.enable("ltrm")
  b.add("frac")
  b.add("numr")
  b.add("dnom")
  b.enable("rand", fRandom, maxValue)
  b.enable("Harf")
  b.enable("HARF")
  if p.arabicShaper:
    b.enable("stch")
    b.pause(0, pStch)
    b.enable("ccmp", fManualZwj)
    b.enable("locl", fManualZwj)
    b.pause(0)
    for tg in ["isol", "fina", "fin2", "fin3", "medi", "med2", "init"]:
      let fallback = si.iso == "Arab" and tg[3] notin {'2', '3'}
      b.add(tg, fManualZwj or (if fallback: fHasFallback else: 0))
      b.pause(0)
    b.pause(0)
    b.enable("rlig", fManualZwj or fHasFallback)
    if si.iso == "Arab": b.pause(0, pArabicFallback)
    b.enable("calt", fManualZwj)
    if not (L.hasFeatureIn(langAt[0], L.t[0], "rclt") or L.hasFeatureIn(langAt[1], L.t[1], "rclt")):
      b.pause(0)
    b.enable("liga", fManualZwj)
    b.enable("clig", fManualZwj)
    b.enable("mset", fManualZwj)
  b.enable("Buzz")
  b.enable("BUZZ")
  for tg in ["abvm", "blwm", "ccmp", "locl"]: b.add(tg, fGlobal)
  b.add("mark", fGlobalManualJoiners)
  b.add("mkmk", fGlobalManualJoiners)
  b.add("rlig", fGlobal)
  for tg in ["calt", "clig", "curs", "dist"]: b.add(tg, fGlobal)
  b.add("kern", fGlobalHasFallback)
  b.add("liga", fGlobal)
  b.add("rclt", fGlobal)
  for f in features:
    var tg = f.tag
    while tg.len < 4: tg.add ' '
    b.add(tg[0 .. 3], fGlobal, ord(f.on))
  # compile: sort and merge the features
  b.features.sort(proc (x, y: FeatureInfo): int =
    result = cmp(x.tag, y.tag)
    if result == 0: result = cmp(x.seq, y.seq))
  var merged: seq[FeatureInfo]
  for fi in b.features:
    if merged.len > 0 and merged[^1].tag == fi.tag:
      var m = merged[^1]
      if (fi.flags and fGlobal) != 0:
        m.flags = m.flags or fGlobal
        m.maxValue = fi.maxValue
        m.defaultValue = fi.defaultValue
      else:
        if (m.flags and fGlobal) != 0: m.flags = m.flags xor fGlobal
        m.maxValue = max(m.maxValue, fi.maxValue)
      m.flags = m.flags or (fi.flags and fHasFallback)
      m.stage[0] = min(m.stage[0], fi.stage[0])
      m.stage[1] = min(m.stage[1], fi.stage[1])
      merged[^1] = m
    else: merged.add fi
  const globalShift = 31
  const globalBit = 1'u32 shl globalShift
  p.globalMask = globalBit
  var requiredIndex, requiredStage: array[2, int]
  var requiredTag: array[2, string]
  var featIndex: array[2, Table[string, int]]
  var varIdx: array[2, int]
  for k in 0 .. 1:
    requiredIndex[k] = -1
    varIdx[k] = L.variationIndex(L.t[k], coords)
    let ls = langAt[k]
    if ls != 0:
      let r = L.u16(ls + 2)
      if r != 0xFFFF:
        requiredIndex[k] = r
        requiredTag[k] = L.featureTagAt(L.t[k], r)
      for i in countdown(L.u16(ls + 4) - 1, 0):
        let fi = L.u16(ls + 6 + 2 * i)
        featIndex[k][L.featureTagAt(L.t[k], fi)] = fi
  var nextBit = 4
  for fi in merged:
    let bits = if (fi.flags and fGlobal) != 0 and fi.maxValue == 1: 0
               else: min(8, (block:
                 var x = fi.maxValue
                 var c = 0
                 while x > 0:
                   inc c
                   x = x shr 1
                 c))
    if fi.maxValue == 0 or nextBit + bits >= globalShift: continue
    var found = false
    var idx: array[2, int]
    for k in 0 .. 1:
      if requiredTag[k] == fi.tag: requiredStage[k] = fi.stage[k]
      if fi.tag in featIndex[k]:
        idx[k] = featIndex[k][fi.tag]
        found = true
      else: idx[k] = -1
    if not found and (fi.flags and fGlobalSearch) != 0:
      for k in 0 .. 1:
        if L.t[k].at < 0: continue
        for i in 0 ..< L.u16(L.t[k].features):
          if L.featureTagAt(L.t[k], i) == fi.tag:
            idx[k] = i
            found = true
            break
    if not found and (fi.flags and fHasFallback) == 0: continue
    var m = FeatureMap(tag: fi.tag, index: idx, stage: fi.stage,
                       autoZwnj: (fi.flags and fManualZwnj) == 0,
                       autoZwj: (fi.flags and fManualZwj) == 0,
                       random: (fi.flags and fRandom) != 0, needsFallback: not found)
    if (fi.flags and fGlobal) != 0 and fi.maxValue == 1:
      m.shift = globalShift
      m.mask = globalBit
    else:
      m.shift = nextBit
      m.mask = uint32((1 shl (nextBit + bits)) - (1 shl nextBit))
      nextBit += bits
      p.globalMask = p.globalMask or (uint32(fi.defaultValue shl m.shift) and m.mask)
    m.oneMask = (1'u32 shl m.shift) and m.mask
    p.features.add m
  b.pause(0)
  b.pause(1)
  for k in 0 .. 1:
    var si = 0
    for stage in 0 ..< b.current[k]:
      let start = p.lookups[k].len
      proc addLookups(index: int; mask: uint32; zwnj, zwj, random: bool) =
        if index < 0 or L.t[k].at < 0: return
        let ft = L.featureTableAt(L.t[k], index, varIdx[k])
        let count = L.u16(L.t[k].lookups)
        for i in 0 ..< L.u16(ft + 2):
          let li = L.u16(ft + 4 + 2 * i)
          if li < count:
            p.lookups[k].add LookupMap(index: li, mask: mask, autoZwnj: zwnj, autoZwj: zwj,
                                       random: random)
      if requiredIndex[k] >= 0 and requiredStage[k] == stage:
        addLookups(requiredIndex[k], globalBit, true, true, false)
      for m in p.features:
        if m.stage[k] == stage:
          addLookups(m.index[k], m.mask, m.autoZwnj, m.autoZwj, m.random)
      if start + 1 < p.lookups[k].len:
        var part = p.lookups[k][start .. ^1]
        part.sort(proc (x, y: LookupMap): int = cmp(x.index, y.index))
        p.lookups[k].setLen(start)
        for lm in part:
          if p.lookups[k].len > start and p.lookups[k][^1].index == lm.index:
            p.lookups[k][^1].mask = p.lookups[k][^1].mask or lm.mask
            p.lookups[k][^1].autoZwnj = p.lookups[k][^1].autoZwnj and lm.autoZwnj
            p.lookups[k][^1].autoZwj = p.lookups[k][^1].autoZwj and lm.autoZwj
          else: p.lookups[k].add lm
      if si < b.pauses[k].len and b.pauses[k][si][0] == stage:
        p.stages[k].add StageMap(last: p.lookups[k].len, pause: b.pauses[k][si][1])
        inc si
  # what the masks are
  proc oneMask(tag: string): uint32 =
    for m in p.features:
      if m.tag == tag: return m.oneMask
  proc mask(tag: string): uint32 =
    for m in p.features:
      if m.tag == tag: return m.mask
  proc foundAt(tag: string; k: int): bool =
    for m in p.features:
      if m.tag == tag: return m.index[k] >= 0
  p.fracMask = oneMask("frac")
  p.numrMask = oneMask("numr")
  p.dnomMask = oneMask("dnom")
  p.hasFrac = p.fracMask != 0 or (p.numrMask != 0 and p.dnomMask != 0)
  p.rtlmMask = oneMask("rtlm")
  p.kernMask = mask("kern")
  if p.arabicShaper:
    for i, tg in ["isol", "fina", "fin2", "fin3", "medi", "med2", "init"]:
      p.arabicMasks[i] = oneMask(tg)
  # who positions
  p.fallbackClasses = L.glyphClass <= 0
  let hasGposKern = foundAt("kern", 1)
  p.applyGpos = L.t[1].at >= 0
  p.applyKern = (not hasGposKern or not p.applyGpos) and L.hasKern
  p.zeroMarks = true
  p.adjustMarks = not p.applyGpos
  p

# ---- the glyph buffer -----------------------------------------------------------------

const
  # unicode props
  upIgnorable = 0x20'u16
  upHidden = 0x40'u16
  upContinuation = 0x80'u16
  upZwj = 0x100'u16
  upZwnj = 0x200'u16
  upVs = 0x400'u16
  # glyph props
  gpBase = 0x02'u16
  gpLigature = 0x04'u16
  gpMark = 0x08'u16
  gpSubstituted = 0x10'u16
  gpLigated = 0x20'u16
  gpMultiplied = 0x40'u16
  gpPreserve = gpSubstituted or gpLigated or gpMultiplied
  # lookup flags
  lfRightToLeft = 1
  lfIgnoreFlags = 0x0E
  lfIgnoreMarks = 8
  lfUseMarkSet = 0x10
  lfMarkAttach = 0xFF00
  # arabic actions
  aNone = 7'u8
  atMark = 1'u8
  atCursive = 2'u8

type
  GInfo = object
    cp: int32            ## the character, then the glyph
    cluster: int32
    mask: uint32
    uprops: uint16
    gprops: uint16
    lig: uint8
    action: uint8
    glyph: int32         ## the nominal glyph (while normalizing)

  GPos = object
    xa, ya, xo, yo: int32
    chain: int16
    atype: uint8

  Buf = ref object
    info, outBuf: seq[GInfo]
    pos: seq[GPos]
    len, idx, outLen: int
    haveOutput, separate: bool
    rtl: bool             ## the direction it is being shaped in
    serial: int
    random: uint32
    hasIgnorables, hasCgj, hasSpaceFallback, hasAttach, hasFracSlash: bool

template gc(x: GInfo): uint8 = uint8(x.uprops and 0x1F)
template isUnicodeMark(x: GInfo): bool = x.gc in {gcMn, gcMc, gcMe}
template infoCc(x: GInfo): int = (if x.isUnicodeMark: int(x.uprops shr 8) else: 0)
template isDefIgn(x: GInfo): bool =
  (x.uprops and upIgnorable) != 0 and (x.gprops and gpSubstituted) == 0
template isZwnj(x: GInfo): bool = x.gc == gcCf and (x.uprops and upZwnj) != 0
template isZwj(x: GInfo): bool = x.gc == gcCf and (x.uprops and upZwj) != 0
template isHidden(x: GInfo): bool = (x.uprops and upHidden) != 0
template isMark(x: GInfo): bool = (x.gprops and gpMark) != 0
template isLigature(x: GInfo): bool = (x.gprops and gpLigature) != 0
template isBaseGlyph(x: GInfo): bool = (x.gprops and gpBase) != 0
template multiplied(x: GInfo): bool = (x.gprops and gpMultiplied) != 0
template ligId(x: GInfo): int = int(x.lig shr 5)
template ligatedInternal(x: GInfo): bool = (x.lig and 0x10) != 0
template ligComp(x: GInfo): int = (if x.ligatedInternal: 0 else: int(x.lig and 0x0F))
template ligNumComps(x: GInfo): int =
  (if x.isLigature and x.ligatedInternal: int(x.lig and 0x0F) else: 1)
template numCompsInLigation(x: GInfo): int =
  (if x.multiplied and x.ligComp != 0: 0 else: x.ligNumComps)
template setLigForLigature(x: var GInfo; id, n: int) = x.lig = uint8((id shl 5) or 0x10 or (n and 0x0F))
template setLigForMark(x: var GInfo; id, comp: int) = x.lig = uint8((id shl 5) or (comp and 0x0F))

proc setUnicodeProps(b: Buf; x: var GInfo) =
  let u = int(x.cp)
  let g = genCat(u)
  var props = uint16(g)
  if u >= 0x80:
    if isDefaultIgnorable(u):
      b.hasIgnorables = true
      props = props or upIgnorable
      if u == 0x200C: props = props or upZwnj
      elif u == 0x200D: props = props or upZwj
      elif u in 0x180B .. 0x180D or u == 0x180F: props = props or upHidden
      elif u in 0xE0020 .. 0xE007F: props = props or upHidden
      elif u == 0x034F:
        b.hasCgj = true
        props = props or upHidden
    if g in {gcMn, gcMc, gcMe}:
      props = props or upContinuation or uint16(modifiedClass(u) shl 8)
  x.uprops = props

template cur(b: Buf): var GInfo = b.info[b.idx]

proc outAt(b: Buf; i: int): var GInfo =
  ## Glyph `i` of what is behind the cursor (the output when there is one).
  if b.haveOutput and b.separate: return b.outBuf[i]
  return b.info[i]

proc backtrackLen(b: Buf): int {.inline.} = (if b.haveOutput: b.outLen else: b.idx)
proc lookaheadLen(b: Buf): int {.inline.} = b.len - b.idx

proc clearOutput(b: Buf) =
  b.haveOutput = true
  b.separate = false
  b.outLen = 0

proc makeRoom(b: Buf; numIn, numOut: int) =
  if not b.separate and b.outLen + numOut > b.idx + numIn:
    if b.outBuf.len < b.len + 32: b.outBuf.setLen(b.len + 32)
    for i in 0 ..< b.outLen: b.outBuf[i] = b.info[i]
    b.separate = true
  if b.separate and b.outBuf.len < b.outLen + numOut + 1:
    b.outBuf.setLen(max(b.outLen + numOut + 1, 2 * b.outBuf.len))

proc putOut(b: Buf; x: GInfo) =
  if b.separate: b.outBuf[b.outLen] = x
  else: b.info[b.outLen] = x
  inc b.outLen

proc nextGlyph(b: Buf) =
  if b.haveOutput:
    if b.separate or b.outLen != b.idx:
      b.makeRoom(1, 1)
      b.putOut(b.info[b.idx])
    else: inc b.outLen
  inc b.idx

proc nextGlyphs(b: Buf; n: int) =
  if b.haveOutput and not b.separate and b.outLen == b.idx:
    b.outLen += n
    b.idx += n
  else:
    for _ in 0 ..< n: b.nextGlyph()

proc replaceGlyph(b: Buf; g: int) =
  b.makeRoom(1, 1)
  var x = b.info[b.idx]
  x.cp = int32(g)
  b.putOut(x)
  inc b.idx

proc outputGlyph(b: Buf; g: int) =
  b.makeRoom(0, 1)
  var x = if b.idx < b.len: b.info[b.idx] else: b.outAt(b.outLen - 1)
  x.cp = int32(g)
  b.putOut(x)

proc skipGlyph(b: Buf) = inc b.idx

proc sync(b: Buf) =
  if b.haveOutput:
    b.nextGlyphs(b.len - b.idx)
    if b.separate: swap(b.info, b.outBuf)
    b.len = b.outLen
  b.haveOutput = false
  b.separate = false
  b.outLen = 0
  b.idx = 0

proc shiftForward(b: Buf; count: int) =
  if b.info.len < b.len + count: b.info.setLen(b.len + count + 16)
  for i in countdown(b.len - 1, b.idx): b.info[i + count] = b.info[i]
  b.len += count
  b.idx += count

proc moveTo(b: Buf; i: int): bool =
  if not b.haveOutput:
    b.idx = i
    return true
  if b.outLen < i:
    let count = i - b.outLen
    b.makeRoom(count, count)
    for k in 0 ..< count: b.putOut(b.info[b.idx + k])
    b.idx += count
  elif b.outLen > i:
    let count = b.outLen - i
    if b.idx < count: b.shiftForward(count - b.idx)
    b.idx -= count
    b.outLen -= count
    if b.separate:
      for k in 0 ..< count: b.info[b.idx + k] = b.outBuf[b.outLen + k]
    else:
      if b.idx > b.outLen:
        for k in countdown(count - 1, 0): b.info[b.idx + k] = b.info[b.outLen + k]
  true

proc deleteGlyph(b: Buf) =
  ## Drops the glyph at the cursor (merging its cluster as HarfBuzz does).
  let cluster = b.info[b.idx].cluster
  if (b.idx + 1 < b.len and cluster == b.info[b.idx + 1].cluster) or
     (b.outLen > 0 and cluster == b.outAt(b.outLen - 1).cluster):
    discard
  elif b.outLen > 0:
    if cluster < b.outAt(b.outLen - 1).cluster:
      let old = b.outAt(b.outLen - 1).cluster
      var i = b.outLen
      while i > 0 and b.outAt(i - 1).cluster == old:
        b.outAt(i - 1).cluster = cluster
        dec i
  b.skipGlyph()

proc nextSerial(b: Buf): int =
  b.serial = (b.serial + 1) and 0xFF
  if b.serial == 0: b.serial = 1
  b.serial

proc allocLigId(b: Buf): int =
  result = b.nextSerial() and 7
  if result == 0: result = b.allocLigId()

# ---- applying lookups -----------------------------------------------------------------

type
  MatchKind = enum mkNone, mkGlyph, mkClass, mkCoverage
  Matcher = object
    props: int
    ignoreZwnj, ignoreZwj, ignoreHidden: bool
    mask: uint32
    kind: MatchKind
    arr: int              ## the values: glyph ids, classes or coverage offsets (uint16)
    classDef: int
    base: int             ## coverage offsets are from here
  Iter = object
    idx, k, stop: int
    m: Matcher
  MatchResult = enum mrMatch, mrNotMatch, mrSkip
  SkipResult = enum skNo, skYes, skMaybe

  Ctx = object
    L: Layout
    face: Face
    b: Buf
    table: int
    lookupMask: uint32
    lookupProps: int
    autoZwnj, autoZwj, random: bool
    nesting: int
    lastBase, lastBaseUntil: int
    matchPos: seq[int]
    iterInput, iterContext: Iter
    hasGlyphClasses: bool
    coords: seq[int]
    ops: int              ## what is left of the work budget (a damaged font stops here)
    maxLen: int           ## the buffer grows no longer than this

proc checkGlyphProperty(c: var Ctx; x: GInfo; props: int): bool =
  let gp = int(x.gprops)
  if (gp and props and lfIgnoreFlags) != 0: return false
  if (gp and int(gpMark)) != 0:
    if (props and lfUseMarkSet) != 0: return c.L.markSetCovers(props shr 16, int(x.cp))
    if (props and lfMarkAttach) != 0: return (props and lfMarkAttach) == (gp and lfMarkAttach)
  true

proc initIters(c: var Ctx) =
  c.iterInput.m = Matcher(props: c.lookupProps, ignoreZwnj: c.table == 1, ignoreZwj: c.autoZwj,
                          ignoreHidden: c.table == 1, mask: c.lookupMask)
  c.iterContext.m = Matcher(props: c.lookupProps, ignoreZwnj: c.table == 1 or c.autoZwnj,
                            ignoreZwj: true, ignoreHidden: c.table == 1, mask: 0xFFFFFFFF'u32)

proc setLookupProps(c: var Ctx; props: int) =
  var p = props
  if (p and lfUseMarkSet) != 0 and (c.L.markSets <= 0 or (p shr 16) >= c.L.u16(c.L.markSets + 2)):
    p = p and not lfUseMarkSet
  c.lookupProps = p
  c.initIters()

proc maySkip(c: var Ctx; m: Matcher; x: GInfo): SkipResult =
  if not c.checkGlyphProperty(x, m.props): return skYes
  if x.isDefIgn and (m.ignoreZwnj or not x.isZwnj) and (m.ignoreZwj or not x.isZwj) and
     (m.ignoreHidden or not x.isHidden):
    return skMaybe
  skNo

proc valueMatches(c: var Ctx; m: Matcher; k: int; x: GInfo): bool =
  let v = c.L.u16(m.arr + 2 * k)
  case m.kind
  of mkGlyph: int(x.cp) == v
  of mkClass: c.L.classOf(m.classDef, int(x.cp)) == v
  of mkCoverage: c.L.coverage(m.base + v, int(x.cp)) >= 0
  of mkNone: true

proc match(c: var Ctx; it: var Iter; x: GInfo): MatchResult =
  let skip = c.maySkip(it.m, x)
  if skip == skYes: return mrSkip
  var mm = 2                     # 0 no, 1 yes, 2 maybe
  if (x.mask and it.m.mask) == 0: mm = 0
  elif it.m.kind != mkNone: mm = ord(c.valueMatches(it.m, it.k, x))
  if mm == 1 or (mm == 2 and skip == skNo): return mrMatch
  if skip == skNo: return mrNotMatch
  mrSkip

proc next(c: var Ctx; it: var Iter): bool =
  while it.idx < it.stop - 1:
    inc it.idx
    case c.match(it, c.b.info[it.idx])
    of mrMatch:
      inc it.k
      return true
    of mrNotMatch: return false
    of mrSkip: discard
  false

proc prev(c: var Ctx; it: var Iter): bool =
  while it.idx > 0:
    dec it.idx
    case c.match(it, c.b.outAt(it.idx))
    of mrMatch:
      inc it.k
      return true
    of mrNotMatch: return false
    of mrSkip: discard
  false

proc setMatch(it: var Iter; kind: MatchKind; arr = 0; classDef = 0; base = 0) =
  it.m.kind = kind
  it.m.arr = arr
  it.m.classDef = classDef
  it.m.base = base
  it.k = 0

proc setGlyphClass(c: var Ctx; g: int; guess = 0'u16; ligature = false; component = false) =
  let b = c.b
  var props = b.cur.gprops or gpSubstituted
  if ligature:
    props = props or gpLigated
    props = props and not gpMultiplied
  if component: props = props or gpMultiplied
  if c.hasGlyphClasses: b.cur.gprops = (props and gpPreserve) or uint16(c.L.glyphProps(g))
  elif guess != 0: b.cur.gprops = (props and gpPreserve) or guess
  else: b.cur.gprops = props

proc replaceGlyph(c: var Ctx; g: int) =
  c.setGlyphClass(g)
  c.b.replaceGlyph(g)

proc applyLookupAt(c: var Ctx; li: int): bool
proc applySubtable(c: var Ctx; kind, at: int): bool

proc recurse(c: var Ctx; li: int): bool =
  if c.nesting <= 0 or li >= c.L.t[c.table].looks.len: return false
  dec c.ops
  if c.ops < 0: return false
  dec c.nesting
  let savedProps = c.lookupProps
  c.setLookupProps(c.L.t[c.table].looks[li].props)
  var saved: seq[int]
  swap(saved, c.matchPos)
  result = c.applyLookupAt(li)
  swap(saved, c.matchPos)
  c.setLookupProps(savedProps)
  inc c.nesting

# -- matching sequences (contexts and ligatures)

proc matchInput(c: var Ctx; count: int; kind: MatchKind; arr, classDef, base: int;
                endPos: var int; totalComps: ptr int = nil): bool =
  let b = c.b
  if c.matchPos.len < max(count, 1): c.matchPos.setLen(max(count, 8))
  if count == 1:
    endPos = b.idx + 1
    c.matchPos[0] = b.idx
    if totalComps != nil: totalComps[] = b.cur.ligNumComps
    return true
  if count > 64: return false
  var it = c.iterInput
  it.idx = b.idx
  it.stop = b.len
  it.setMatch(kind, arr, classDef, base)
  var total = 0
  let firstId = b.cur.ligId
  let firstComp = b.cur.ligComp
  var ligbase = 0                        # 0 not checked, 1 may not skip, 2 may skip
  for i in 1 ..< count:
    if not c.next(it):
      endPos = it.idx + 1
      c.iterInput = it
      return false
    c.matchPos[i] = it.idx
    let x = b.info[it.idx]
    let thisId = x.ligId
    let thisComp = x.ligComp
    if firstId != 0 and firstComp != 0:
      if firstId != thisId or firstComp != thisComp:
        if ligbase == 0:
          var found = false
          var j = b.outLen
          while j > 0 and b.outAt(j - 1).ligId == firstId:
            if b.outAt(j - 1).ligComp == 0:
              dec j
              found = true
              break
            dec j
          if found and c.maySkip(it.m, b.outAt(j)) == skYes: ligbase = 2
          else: ligbase = 1
        if ligbase == 1:
          c.iterInput = it
          return false
    else:
      if thisId != 0 and thisComp != 0 and thisId != firstId:
        c.iterInput = it
        return false
    total += x.numCompsInLigation
  endPos = it.idx + 1
  if totalComps != nil: totalComps[] = total + b.cur.ligNumComps
  c.matchPos[0] = b.idx
  c.iterInput = it
  true

proc ligateInput(c: var Ctx; count, matchEnd, ligGlyph, totalComps: int) =
  let b = c.b
  var isBaseLig = b.info[c.matchPos[0]].isBaseGlyph
  var isMarkLig = b.info[c.matchPos[0]].isMark
  for i in 1 ..< count:
    if not b.info[c.matchPos[i]].isMark:
      isBaseLig = false
      isMarkLig = false
      break
  let isLig = not isBaseLig and not isMarkLig
  let klass = if isLig: gpLigature else: 0'u16
  let ligId = if isLig: b.allocLigId() else: 0
  var lastLigId = b.cur.ligId
  var lastNumComps = b.cur.ligNumComps
  var compsSoFar = lastNumComps
  if isLig:
    b.cur.setLigForLigature(ligId, totalComps)
    if b.cur.gc == gcMn:
      b.cur.uprops = uint16(gcLetter) or (b.cur.uprops and (0xFF'u16 and not 0x1F'u16))
  c.setGlyphClass(ligGlyph, klass, ligature = true)
  b.replaceGlyph(ligGlyph)
  for i in 1 ..< count:
    while b.idx < c.matchPos[i]:
      if isLig:
        var thisComp = b.cur.ligComp
        if thisComp == 0: thisComp = lastNumComps
        let newComp = compsSoFar - lastNumComps + min(thisComp, lastNumComps)
        b.cur.setLigForMark(ligId, newComp)
      b.nextGlyph()
    lastLigId = b.cur.ligId
    lastNumComps = b.cur.numCompsInLigation
    compsSoFar += lastNumComps
    inc b.idx
  if not isMarkLig and lastLigId != 0:
    for i in b.idx ..< b.len:
      if lastLigId != b.info[i].ligId: break
      let thisComp = b.info[i].ligComp
      if thisComp == 0: break
      let newComp = compsSoFar - lastNumComps + min(thisComp, lastNumComps)
      b.info[i].setLigForMark(ligId, newComp)

proc matchBacktrack(c: var Ctx; count: int; kind: MatchKind; arr, classDef, base: int): bool =
  if count == 0: return true
  var it = c.iterContext
  it.idx = c.b.backtrackLen
  it.setMatch(kind, arr, classDef, base)
  for i in 0 ..< count:
    if not c.prev(it):
      c.iterContext = it
      return false
  c.iterContext = it
  true

proc matchLookahead(c: var Ctx; count: int; kind: MatchKind; arr, classDef, base: int;
                    start: int): bool =
  if count == 0: return true
  var it = c.iterContext
  it.idx = start - 1
  it.stop = c.b.len
  it.setMatch(kind, arr, classDef, base)
  for i in 0 ..< count:
    if not c.next(it):
      c.iterContext = it
      return false
  c.iterContext = it
  true

proc applyRecords(c: var Ctx; count0: int; records, lookupCount, matchEnd: int) =
  ## Applies a context's lookup records at the matched positions
  ## (HarfBuzz's apply_lookup).
  let b = c.b
  var count = count0
  let bl = b.backtrackLen
  var stop = bl + matchEnd - b.idx
  let delta0 = bl - b.idx
  for j in 0 ..< count: c.matchPos[j] += delta0
  for i in 0 ..< lookupCount:
    let r = records + 4 * i
    let idx = c.L.u16(r)
    if idx >= count: continue
    let origLen = b.backtrackLen + b.lookaheadLen
    if c.matchPos[idx] >= origLen: continue
    if not b.moveTo(c.matchPos[idx]): break
    if not c.recurse(c.L.u16(r + 2)): continue
    let newLen = b.backtrackLen + b.lookaheadLen
    var delta = newLen - origLen
    if delta == 0: continue
    stop += delta
    if stop < c.matchPos[idx]:
      delta += c.matchPos[idx] - stop
      stop = c.matchPos[idx]
    var next = idx + 1
    if delta > 0:
      if delta + count > 64: break
      if c.matchPos.len < count + delta: c.matchPos.setLen(count + delta)
    else:
      delta = max(delta, next - count)
      next -= delta
    # shift
    if delta > 0:
      for j in countdown(count - 1, next): c.matchPos[j + delta] = c.matchPos[j]
    elif delta < 0:
      for j in next ..< count: c.matchPos[j + delta] = c.matchPos[j]
    next += delta
    count += delta
    for j in idx + 1 ..< next: c.matchPos[j] = c.matchPos[j - 1] + 1
    while next < count:
      c.matchPos[next] += delta
      inc next
  discard b.moveTo(stop)

proc contextRule(c: var Ctx; inputCount: int; kind: MatchKind; inputArr, classDef, base: int;
                 lookupCount, records: int): bool =
  if inputCount > 64: return false
  var matchEnd = 0
  if c.matchInput(inputCount, kind, inputArr, classDef, base, matchEnd):
    c.applyRecords(inputCount, records, lookupCount, matchEnd)
    return true
  false

proc chainRule(c: var Ctx; backCount: int; backKind: MatchKind; backArr, backClass: int;
               inputCount: int; inKind: MatchKind; inArr, inClass: int;
               aheadCount: int; aheadKind: MatchKind; aheadArr, aheadClass: int;
               base, lookupCount, records: int): bool =
  if inputCount > 64: return false
  var matchEnd = 0
  if not c.matchInput(inputCount, inKind, inArr, inClass, base, matchEnd): return false
  if not c.matchLookahead(aheadCount, aheadKind, aheadArr, aheadClass, base, matchEnd): return false
  if not c.matchBacktrack(backCount, backKind, backArr, backClass, base): return false
  c.applyRecords(inputCount, records, lookupCount, matchEnd)
  true

proc applyContext(c: var Ctx; at: int): bool =
  let L = c.L
  let g = int(c.b.cur.cp)
  case L.u16(at)
  of 1:
    let i = L.coverage(at + L.u16(at + 2), g)
    if i < 0 or i >= L.u16(at + 4): return false
    let rs = at + L.u16(at + 6 + 2 * i)
    if L.u16(at + 6 + 2 * i) == 0: return false
    for r in 0 ..< L.u16(rs):
      let rule = rs + L.u16(rs + 2 + 2 * r)
      let n = L.u16(rule)
      let lc = L.u16(rule + 2)
      if c.contextRule(n, mkGlyph, rule + 4, 0, 0, lc, rule + 4 + 2 * max(n - 1, 0)): return true
    false
  of 2:
    if L.coverage(at + L.u16(at + 2), g) < 0: return false
    let cd = at + L.u16(at + 4)
    let cls = L.classOf(cd, g)
    if cls >= L.u16(at + 6) or L.u16(at + 8 + 2 * cls) == 0: return false
    let rs = at + L.u16(at + 8 + 2 * cls)
    for r in 0 ..< L.u16(rs):
      let rule = rs + L.u16(rs + 2 + 2 * r)
      let n = L.u16(rule)
      let lc = L.u16(rule + 2)
      if c.contextRule(n, mkClass, rule + 4, cd, 0, lc, rule + 4 + 2 * max(n - 1, 0)): return true
    false
  of 3:
    let n = L.u16(at + 2)
    let lc = L.u16(at + 4)
    if n == 0 or L.coverage(at + L.u16(at + 6), g) < 0: return false
    c.contextRule(n, mkCoverage, at + 8, 0, at, lc, at + 6 + 2 * n)
  else: false

proc applyChainContext(c: var Ctx; at: int): bool =
  let L = c.L
  let g = int(c.b.cur.cp)
  case L.u16(at)
  of 1, 2:
    let fmt = L.u16(at)
    if L.coverage(at + L.u16(at + 2), g) < 0: return false
    var backCd, inCd, aheadCd, setsAt, idx: int
    var kind = mkGlyph
    if fmt == 1:
      idx = L.coverage(at + L.u16(at + 2), g)
      setsAt = at + 4
    else:
      kind = mkClass
      backCd = at + L.u16(at + 4)
      inCd = at + L.u16(at + 6)
      aheadCd = at + L.u16(at + 8)
      if L.u16(at + 4) == 0: backCd = 0
      if L.u16(at + 8) == 0: aheadCd = 0
      idx = L.classOf(inCd, g)
      setsAt = at + 10
    if idx >= L.u16(setsAt) or L.u16(setsAt + 2 + 2 * idx) == 0: return false
    let rs = at + L.u16(setsAt + 2 + 2 * idx)
    for r in 0 ..< L.u16(rs):
      let rule = rs + L.u16(rs + 2 + 2 * r)
      let bc = L.u16(rule)
      let backArr = rule + 2
      let ic = L.u16(backArr + 2 * bc)
      let inArr = backArr + 2 * bc + 2
      let ac = L.u16(inArr + 2 * max(ic - 1, 0))
      let aheadArr = inArr + 2 * max(ic - 1, 0) + 2
      let lc = L.u16(aheadArr + 2 * ac)
      let records = aheadArr + 2 * ac + 2
      if c.chainRule(bc, kind, backArr, backCd, ic, kind, inArr, inCd, ac, kind, aheadArr, aheadCd,
                     0, lc, records):
        return true
    false
  of 3:
    let bc = L.u16(at + 2)
    let backArr = at + 4
    let ic = L.u16(backArr + 2 * bc)
    let inArr = backArr + 2 * bc + 2
    if ic == 0 or L.coverage(at + L.u16(inArr), g) < 0: return false
    let ac = L.u16(inArr + 2 * ic)
    let aheadArr = inArr + 2 * ic + 2
    let lc = L.u16(aheadArr + 2 * ac)
    let records = aheadArr + 2 * ac + 2
    c.chainRule(bc, mkCoverage, backArr, 0, ic, mkCoverage, inArr + 2, 0, ac, mkCoverage,
                aheadArr, 0, at, lc, records)
  else: false

# -- GSUB

proc applyGsub(c: var Ctx; kind, at: int): bool =
  let L = c.L
  let b = c.b
  let g = int(b.cur.cp)
  case kind
  of 1:
    let i = L.coverage(at + L.u16(at + 2), g)
    if i < 0: return false
    case L.u16(at)
    of 1: c.replaceGlyph((g + L.u16(at + 4)) and 0xFFFF)
    of 2:
      if i >= L.u16(at + 4): return false
      c.replaceGlyph(L.u16(at + 6 + 2 * i))
    else: return false
    true
  of 2:
    let i = L.coverage(at + L.u16(at + 2), g)
    if i < 0 or L.u16(at) != 1 or i >= L.u16(at + 4): return false
    let s = at + L.u16(at + 6 + 2 * i)
    let n = L.u16(s)
    if n == 1:
      c.replaceGlyph(L.u16(s + 2))
    elif n == 0:
      b.deleteGlyph()
    else:
      if b.len + n > c.maxLen: return false
      let klass = if b.cur.isLigature: gpBase else: 0'u16
      let lid = b.cur.ligId
      for k in 0 ..< n:
        if lid == 0: b.cur.setLigForMark(0, k)
        c.setGlyphClass(L.u16(s + 2 + 2 * k), klass, component = true)
        b.outputGlyph(L.u16(s + 2 + 2 * k))
      b.skipGlyph()
    true
  of 3:
    let i = L.coverage(at + L.u16(at + 2), g)
    if i < 0 or L.u16(at) != 1 or i >= L.u16(at + 4): return false
    let s = at + L.u16(at + 6 + 2 * i)
    let n = L.u16(s)
    if n == 0: return false
    var shift = 0
    while shift < 32 and (c.lookupMask and (1'u32 shl shift)) == 0: inc shift
    var alt = int((c.lookupMask and b.cur.mask) shr shift)
    if alt == maxValue and c.random:
      b.random = uint32((uint64(b.random) * 48271) mod 2147483647'u64)
      alt = int(b.random mod uint32(n)) + 1
    if alt > n or alt == 0: return false
    c.replaceGlyph(L.u16(s + 2 + 2 * (alt - 1)))
    true
  of 4:
    let i = L.coverage(at + L.u16(at + 2), g)
    if i < 0 or L.u16(at) != 1 or i >= L.u16(at + 4): return false
    let s = at + L.u16(at + 6 + 2 * i)
    for k in 0 ..< L.u16(s):
      let lig = s + L.u16(s + 2 + 2 * k)
      let lg = L.u16(lig)
      let n = L.u16(lig + 2)
      if n == 0: continue
      if n == 1:
        c.replaceGlyph(lg)
        return true
      if n > 64: continue
      var matchEnd = 0
      var total = 0
      if not c.matchInput(n, mkGlyph, lig + 4, 0, 0, matchEnd, addr total): continue
      c.ligateInput(n, matchEnd, lg, total)
      return true
    false
  of 5: c.applyContext(at)
  of 6: c.applyChainContext(at)
  of 8:
    if L.u16(at) != 1: return false
    let i = L.coverage(at + L.u16(at + 2), g)
    if i < 0 or c.nesting != 64: return false
    let bc = L.u16(at + 4)
    let backArr = at + 6
    let ac = L.u16(backArr + 2 * bc)
    let aheadArr = backArr + 2 * bc + 2
    let sc = L.u16(aheadArr + 2 * ac)
    let subs = aheadArr + 2 * ac + 2
    if i >= sc: return false
    if c.matchBacktrack(bc, mkCoverage, backArr, 0, at) and
       c.matchLookahead(ac, mkCoverage, aheadArr, 0, at, b.idx + 1):
      let ng = L.u16(subs + 2 * i)
      c.setGlyphClass(ng)
      b.cur.cp = int32(ng)
      return true
    false
  else: false

# -- GPOS

proc halfUp(x: float32): float64 {.inline.} =
  ## Rounds as HarfBuzz does: halves up (-2.5 to -2).
  floor(float64(x) + 0.5)

proc deviceDelta(c: var Ctx; at: int): float32 =
  ## A device table's delta: variation deltas only (hinting deltas are
  ## for pixel sizes, which shaping in font units has none of).
  if at <= 0 or c.coords.len == 0: return 0
  if c.L.u16(at + 4) != 0x8000: return 0
  c.face.varStoreDelta(c.L.varStore, c.L.u16(at), c.L.u16(at + 2))

proc valueLen(fmt: int): int =
  var x = fmt and 0xFF
  while x != 0:
    result += x and 1
    x = x shr 1

proc applyValue(c: var Ctx; fmt, base, values: int; p: var GPos) =
  let L = c.L
  var v = values
  if (fmt and 1) != 0: p.xo += int32(L.i16(v)); v += 2
  if (fmt and 2) != 0: p.yo += int32(L.i16(v)); v += 2
  if (fmt and 4) != 0: p.xa += int32(L.i16(v)); v += 2
  if (fmt and 8) != 0: v += 2
  if (fmt and 0xF0) == 0 or c.coords.len == 0: return
  template dev(): int = (let o = L.u16(v); if o == 0: 0 else: base + o)
  if (fmt and 0x10) != 0: p.xo += int32(halfUp(c.deviceDelta(dev()))); v += 2
  if (fmt and 0x20) != 0: p.yo += int32(halfUp(c.deviceDelta(dev()))); v += 2
  if (fmt and 0x40) != 0: p.xa += int32(halfUp(c.deviceDelta(dev()))); v += 2

proc anchor(c: var Ctx; at: int): (float32, float32) =
  let L = c.L
  var x = float32(L.i16(at + 2))
  var y = float32(L.i16(at + 4))
  if L.u16(at) == 3 and c.coords.len > 0:
    if L.u16(at + 6) != 0: x += c.deviceDelta(at + L.u16(at + 6))
    if L.u16(at + 8) != 0: y += c.deviceDelta(at + L.u16(at + 8))
  (x, y)

proc reverseCursiveMinorOffset(b: Buf; i, newParent: int; depth = 0) =
  if depth > 64: return
  let chain = int(b.pos[i].chain)
  let typ = b.pos[i].atype
  if chain == 0 or (typ and atCursive) == 0: return
  b.pos[i].chain = 0
  let j = i + chain
  if j < 0 or j >= b.len or j == newParent: return
  b.reverseCursiveMinorOffset(j, newParent, depth + 1)
  b.pos[j].yo = -b.pos[i].yo
  b.pos[j].chain = int16(-chain)
  b.pos[j].atype = typ

proc applyCursive(c: var Ctx; at: int): bool =
  let L = c.L
  let b = c.b
  let cov = at + L.u16(at + 2)
  let count = L.u16(at + 4)
  let ti = L.coverage(cov, int(b.cur.cp))
  if ti < 0 or ti >= count: return false
  let entry = L.u16(at + 6 + 4 * ti)
  if entry == 0: return false
  var it = c.iterInput
  it.idx = b.idx
  it.setMatch(mkNone)
  if not c.prev(it): return false
  let pi = L.coverage(cov, int(b.info[it.idx].cp))
  if pi < 0 or pi >= count: return false
  let exit = L.u16(at + 6 + 4 * pi + 2)
  if exit == 0: return false
  let i = it.idx
  let j = b.idx
  let (exitX, exitY) = c.anchor(at + exit)
  let (entryX, entryY) = c.anchor(at + entry)
  if not b.rtl:
    b.pos[i].xa = int32(halfUp(exitX)) + b.pos[i].xo
    let d = int32(halfUp(entryX)) + b.pos[j].xo
    b.pos[j].xa -= d
    b.pos[j].xo -= d
  else:
    let d = int32(halfUp(exitX)) + b.pos[i].xo
    b.pos[i].xa -= d
    b.pos[i].xo -= d
    b.pos[j].xa = int32(halfUp(entryX)) + b.pos[j].xo
  var child = i
  var parent = j
  var yOff = int32(halfUp(entryY - exitY))
  if (c.lookupProps and lfRightToLeft) == 0:
    swap(child, parent)
    yOff = -yOff
  b.reverseCursiveMinorOffset(child, parent)
  b.pos[child].chain = int16(parent - child)
  b.pos[child].atype = atCursive
  b.hasAttach = true
  b.pos[child].yo = yOff
  if b.pos[parent].chain == -b.pos[child].chain:
    b.pos[parent].chain = 0
    b.pos[parent].yo = 0
  inc b.idx
  true

proc crossOffset(b: Buf; at: int): int32 =
  var g = at
  result = b.pos[g].yo
  var count = 1
  while count < b.len and (b.pos[g].atype and atCursive) != 0:
    let chain = int(b.pos[g].chain)
    if chain == 0: break
    let parent = g + chain
    if parent < 0 or parent >= b.len: break
    g = parent
    result += b.pos[g].yo
    inc count

proc attachMark(c: var Ctx; markAnchor, baseAnchor, glyphPos: int): bool =
  let b = c.b
  let (mx, my) = c.anchor(markAnchor)
  let (bx, by) = c.anchor(baseAnchor)
  let cross = b.crossOffset(glyphPos)
  var p = addr b.pos[b.idx]
  p.chain = int16(glyphPos - b.idx)
  p.atype = atMark
  p.xo = int32(halfUp(bx - mx))
  p.yo = int32(halfUp(by - my)) + cross
  b.hasAttach = true
  inc b.idx
  true

proc markArrayApply(c: var Ctx; markArray, markIndex, matrix, row, classCount,
                    glyphPos: int): bool =
  let L = c.L
  let rec = markArray + 2 + 4 * markIndex
  let klass = L.u16(rec)
  let markAnchor = markArray + L.u16(rec + 2)
  let rows = L.u16(matrix)
  if row >= rows or klass >= classCount: return false
  let off = L.u16(matrix + 2 + 2 * (row * classCount + klass))
  if off == 0: return false
  c.attachMark(markAnchor, matrix + off, glyphPos)

proc acceptBase(b: Buf; idx: int): bool =
  let x = b.info[idx]
  not x.multiplied or x.ligComp == 0 or idx == 0 or b.info[idx - 1].isMark or
    not b.info[idx - 1].multiplied or x.ligId != b.info[idx - 1].ligId or
    x.ligComp != b.info[idx - 1].ligComp + 1

proc findBase(c: var Ctx; baseCov: int): bool =
  ## Looks back for the glyph a mark attaches to (HarfBuzz's last_base).
  let b = c.b
  var it = c.iterInput
  it.m.props = lfIgnoreMarks
  it.setMatch(mkNone)
  if c.lastBaseUntil > b.idx:
    c.lastBaseUntil = 0
    c.lastBase = -1
  var j = b.idx
  while j > c.lastBaseUntil:
    var m = c.match(it, b.info[j - 1])
    if m == mrMatch and not b.acceptBase(j - 1) and c.L.coverage(baseCov, int(b.info[j - 1].cp)) < 0:
      m = mrSkip
    if m == mrMatch:
      c.lastBase = j - 1
      break
    dec j
  c.lastBaseUntil = b.idx
  c.iterInput.m.props = lfIgnoreMarks
  c.lastBase >= 0

proc applyGpos(c: var Ctx; kind, at: int): bool =
  let L = c.L
  let b = c.b
  let g = int(b.cur.cp)
  case kind
  of 1:
    let i = L.coverage(at + L.u16(at + 2), g)
    if i < 0: return false
    let fmt = L.u16(at + 4)
    case L.u16(at)
    of 1: c.applyValue(fmt, at, at + 6, b.pos[b.idx])
    of 2:
      if i >= L.u16(at + 6): return false
      c.applyValue(fmt, at, at + 8 + 2 * valueLen(fmt) * i, b.pos[b.idx])
    else: return false
    inc b.idx
    true
  of 2:
    let i = L.coverage(at + L.u16(at + 2), g)
    if i < 0: return false
    var it = c.iterInput
    it.idx = b.idx
    it.stop = b.len
    it.setMatch(mkNone)
    if not c.next(it): return false
    let second = it.idx
    let f1 = L.u16(at + 4)
    let f2 = L.u16(at + 6)
    let len1 = valueLen(f1)
    let len2 = valueLen(f2)
    case L.u16(at)
    of 1:
      if i >= L.u16(at + 8): return false
      let ps = at + L.u16(at + 10 + 2 * i)
      let size = 2 + 2 * (len1 + len2)
      var lo = 0
      var hi = L.u16(ps) - 1
      let sg = int(b.info[second].cp)
      while lo <= hi:
        let m = (lo + hi) shr 1
        let r = ps + 2 + size * m
        let x = L.u16(r)
        if x < sg: lo = m + 1
        elif x > sg: hi = m - 1
        else:
          if len1 > 0: c.applyValue(f1, ps, r + 2, b.pos[b.idx])
          if len2 > 0: c.applyValue(f2, ps, r + 2 + 2 * len1, b.pos[second])
          b.idx = if len2 > 0: second + 1 else: second
          return true
      false
    of 2:
      let k1 = L.classOf(at + L.u16(at + 8), g)
      let k2 = L.classOf(at + L.u16(at + 10), int(b.info[second].cp))
      let c1 = L.u16(at + 12)
      let c2 = L.u16(at + 14)
      if k1 >= c1 or k2 >= c2: return false
      let v = at + 16 + 2 * (len1 + len2) * (k1 * c2 + k2)
      if len1 > 0: c.applyValue(f1, at, v, b.pos[b.idx])
      if len2 > 0: c.applyValue(f2, at, v + 2 * len1, b.pos[second])
      b.idx = if len2 > 0: second + 1 else: second
      true
    else: false
  of 3:
    if L.u16(at) != 1: return false
    c.applyCursive(at)
  of 4, 5:
    if L.u16(at) != 1: return false
    let mi = L.coverage(at + L.u16(at + 2), g)
    if mi < 0: return false
    let baseCov = at + L.u16(at + 4)
    if not c.findBase(baseCov): return false
    let idx = c.lastBase
    let bi = L.coverage(baseCov, int(b.info[idx].cp))
    if bi < 0: return false
    let classCount = L.u16(at + 6)
    let markArray = at + L.u16(at + 8)
    if mi >= L.u16(markArray): return false
    if kind == 4:
      return c.markArrayApply(markArray, mi, at + L.u16(at + 10), bi, classCount, idx)
    let ligArray = at + L.u16(at + 10)
    if bi >= L.u16(ligArray): return false
    let attach = ligArray + L.u16(ligArray + 2 + 2 * bi)
    let comps = L.u16(attach)
    if comps == 0: return false
    let ligId = b.info[idx].ligId
    let markId = b.cur.ligId
    let markComp = b.cur.ligComp
    let comp = if ligId != 0 and ligId == markId and markComp > 0: min(comps, markComp) - 1
               else: comps - 1
    c.markArrayApply(markArray, mi, attach, comp, classCount, idx)
  of 6:
    if L.u16(at) != 1: return false
    let mi = L.coverage(at + L.u16(at + 2), g)
    if mi < 0: return false
    var it = c.iterInput
    it.idx = b.idx
    it.m.props = c.lookupProps and not lfIgnoreFlags
    it.setMatch(mkNone)
    if not c.prev(it): return false
    let j = it.idx
    if not b.info[j].isMark: return false
    let id1 = b.cur.ligId
    let id2 = b.info[j].ligId
    let comp1 = b.cur.ligComp
    let comp2 = b.info[j].ligComp
    var good = false
    if id1 == id2:
      good = id1 == 0 or comp1 == comp2
    else:
      good = (id1 > 0 and comp1 == 0) or (id2 > 0 and comp2 == 0)
    if not good: return false
    let m2 = L.coverage(at + L.u16(at + 4), int(b.info[j].cp))
    if m2 < 0: return false
    let markArray = at + L.u16(at + 8)
    if mi >= L.u16(markArray): return false
    c.markArrayApply(markArray, mi, at + L.u16(at + 10), m2, L.u16(at + 6), j)
  of 7: c.applyContext(at)
  of 8: c.applyChainContext(at)
  else: false

proc applySubtable(c: var Ctx; kind, at: int): bool =
  if c.table == 0: c.applyGsub(kind, at) else: c.applyGpos(kind, at)

proc applyLookupAt(c: var Ctx; li: int): bool =
  dec c.ops
  if c.ops < 0: return false
  let info = addr c.L.t[c.table].looks[li]
  for s in info.subs:
    if c.applySubtable(info.kind, s): return true
  false

proc applyLookup(c: var Ctx; lm: LookupMap) =
  ## Runs one lookup over the whole buffer.
  let b = c.b
  let li = lm.index
  if b.len == 0 or lm.mask == 0 or li >= c.L.t[c.table].looks.len: return
  let info = addr c.L.t[c.table].looks[li]
  if info.subs.len == 0: return
  let dg = c.L.digestOf(c.table, li)
  var any = false
  for i in 0 ..< b.len:
    if dg.inDigest(int(b.info[i].cp)):
      any = true
      break
  if not any: return
  c.lookupMask = lm.mask
  c.lastBase = -1
  c.lastBaseUntil = 0
  c.autoZwj = lm.autoZwj
  c.autoZwnj = lm.autoZwnj
  c.random = lm.random
  c.setLookupProps(info.props)
  let reverse = c.table == 0 and info.kind == 8
  if not reverse:
    if c.table == 0: b.clearOutput()
    b.idx = 0
    while b.idx < b.len:
      var j = b.idx
      while j < b.len and not (dg.inDigest(int(b.info[j].cp)) and
                               (b.info[j].mask and c.lookupMask) != 0 and
                               c.checkGlyphProperty(b.info[j], c.lookupProps)):
        inc j
      if j > b.idx: b.nextGlyphs(j - b.idx)
      if b.idx >= b.len: break
      if not c.applyLookupAt(li): b.nextGlyph()
    if c.table == 0: b.sync()
  else:
    b.idx = b.len - 1
    while b.idx >= 0:
      let x = b.info[b.idx]
      if dg.inDigest(int(x.cp)) and (x.mask and c.lookupMask) != 0 and
         c.checkGlyphProperty(x, c.lookupProps):
        discard c.applyLookupAt(li)
      dec b.idx
    b.idx = 0

# ---- Arabic -----------------------------------------------------------------------------

const arabicStates: array[7, array[6, (uint8, uint8, uint8)]] = [
  # prev action, current action, next state; columns: U, L, R, D, ALAPH, DALATH RISH
  [(7'u8, 7'u8, 0'u8), (7, 0, 2), (7, 0, 1), (7, 0, 2), (7, 0, 1), (7, 0, 6)],
  [(7'u8, 7'u8, 0'u8), (7, 0, 2), (7, 0, 1), (7, 0, 2), (7, 2, 5), (7, 0, 6)],
  [(7'u8, 7'u8, 0'u8), (7, 0, 2), (6, 1, 1), (6, 1, 3), (6, 1, 4), (6, 1, 6)],
  [(7'u8, 7'u8, 0'u8), (7, 0, 2), (4, 1, 1), (4, 1, 3), (4, 1, 4), (4, 1, 6)],
  [(7'u8, 7'u8, 0'u8), (7, 0, 2), (5, 0, 1), (5, 0, 2), (5, 2, 5), (5, 0, 6)],
  [(7'u8, 7'u8, 0'u8), (7, 0, 2), (0, 0, 1), (0, 0, 2), (0, 2, 5), (0, 0, 6)],
  [(7'u8, 7'u8, 0'u8), (7, 0, 2), (7, 0, 1), (7, 0, 2), (7, 3, 5), (7, 0, 6)]]
  # actions: 0 isol, 1 fina, 2 fin2, 3 fin3, 4 medi, 5 med2, 6 init, 7 none

proc arabicJoining(b: Buf) =
  var prev = -1
  var state = 0
  for i in 0 ..< b.len:
    let t = joiningOf(int(b.info[i].cp), b.info[i].gc)
    if t == jtT:
      b.info[i].action = aNone
      continue
    let e = arabicStates[state][t]
    if e[0] != aNone and prev >= 0: b.info[prev].action = e[0]
    b.info[i].action = e[1]
    prev = i
    state = int(e[2])

proc reorderMarksArabic(b: Buf; start0, stop: int) =
  const mcm = [0x0654, 0x0655, 0x0658, 0x06DC, 0x06E3, 0x06E7, 0x06E8, 0x08CA, 0x08CB, 0x08CD,
               0x08CE, 0x08CF, 0x08D3, 0x08F3]
  var start = start0
  var i = start
  for cc in [220, 230]:
    while i < stop and b.info[i].infoCc < cc: inc i
    if i == stop: break
    if b.info[i].infoCc > cc: continue
    var j = i
    while j < stop and b.info[j].infoCc == cc and int(b.info[j].cp) in mcm: inc j
    if i == j: continue
    let tmp = b.info[i ..< j]
    for k in countdown(i - 1, start): b.info[k + j - i] = b.info[k]
    for k in 0 ..< tmp.len: b.info[start + k] = tmp[k]
    let newStart = start + j - i
    let newCc = if cc == 220: 25 else: 26
    while start < newStart:
      if b.info[start].isUnicodeMark:
        b.info[start].uprops = (b.info[start].uprops and 0xFF) or uint16(newCc shl 8)
      inc start
    i = j

# ---- the shaper ---------------------------------------------------------------------------

proc normalize(b: Buf; f: Face; arabic: bool) =
  ## HarfBuzz's normalizer ("composed diacritics"): decompose what the font
  ## lacks, sort the marks, compose again what the font has.
  proc glyph(u: int): int = f.glyphOf(u)
  proc outChar(b: Buf; u, g: int) =
    b.cur.glyph = int32(g)
    b.outputGlyph(u)
    var x = b.outAt(b.outLen - 1)
    x.cp = int32(u)
    b.setUnicodeProps(x)
    b.outAt(b.outLen - 1) = x
  proc nextChar(b: Buf; g: int) =
    b.cur.glyph = int32(g)
    b.nextGlyph()
  proc decomposeChar(b: Buf; shortest: bool; ab: int): int =
    var a, bb: int
    if not decompose(ab, a, bb): return 0
    let bg = if bb != 0: glyph(bb) else: 0
    if bb != 0 and bg == 0: return 0
    let ag = glyph(a)
    if shortest and ag != 0:
      b.outChar(a, ag)
      if bb != 0:
        b.outChar(bb, bg)
        return 2
      return 1
    let r = b.decomposeChar(shortest, a)
    if r > 0:
      if bb != 0:
        b.outChar(bb, bg)
        return r + 1
      return r
    if ag != 0:
      b.outChar(a, ag)
      if bb != 0:
        b.outChar(bb, bg)
        return 2
      return 1
    0
  proc decomposeCurrent(b: Buf; shortest: bool) =
    let u = int(b.cur.cp)
    var g = glyph(u)
    if shortest and g != 0:
      b.nextChar(g)
      return
    if b.decomposeChar(shortest, u) > 0:
      b.skipGlyph()
      return
    if not shortest and g != 0:
      b.nextChar(g)
      return
    if b.cur.gc == gcZs:
      let st = spaceFallback(u)
      let sg = glyph(0x20)
      if st != 0 and sg != 0:
        b.cur.uprops = (b.cur.uprops and 0xFF) or uint16(st shl 8)
        b.nextChar(sg)
        b.hasSpaceFallback = true
        return
    if u == 0x2011:
      let og = glyph(0x2010)
      if og != 0:
        b.nextChar(og)
        return
    b.nextChar(g)
  proc isVs(u: int): bool =
    u in 0xFE00 .. 0xFE0F or u in 0xE0100 .. 0xE01EF or u in 0x180B .. 0x180D or u == 0x180F
  b.clearOutput()
  b.idx = 0
  var allSimple = true
  let count = b.len
  while b.idx < count:
    var stop = b.idx + 1
    while stop < count and not b.info[stop].isUnicodeMark: inc stop
    if stop < count: dec stop
    while b.idx < stop: b.decomposeCurrent(true)
    if b.idx == count: break
    allSimple = false
    stop = b.idx + 1
    while stop < count and b.info[stop].isUnicodeMark: inc stop
    var hasVs = false
    for i in b.idx ..< stop:
      if isVs(int(b.info[i].cp)): hasVs = true
    if hasVs:
      while b.idx < stop - 1:
        if isVs(int(b.info[b.idx + 1].cp)):
          b.cur.glyph = int32(glyph(int(b.cur.cp)))
          b.nextGlyph()
          b.cur.uprops = (b.cur.uprops and 0xE0'u16) or uint16(gcCf) or upVs
          b.cur.glyph = int32(glyph(int(b.cur.cp)))
          b.nextGlyph()
          while b.idx < stop and isVs(int(b.cur.cp)):
            b.cur.glyph = int32(glyph(int(b.cur.cp)))
            b.nextGlyph()
        else:
          b.cur.glyph = int32(glyph(int(b.cur.cp)))
          b.nextGlyph()
      if b.idx < stop:
        b.cur.glyph = int32(glyph(int(b.cur.cp)))
        b.nextGlyph()
    else:
      while b.idx < stop: b.decomposeCurrent(false)
  b.sync()
  if not allSimple:
    # reorder marks by combining class
    var i = 0
    while i < b.len:
      if b.info[i].infoCc == 0:
        inc i
        continue
      var stop = i + 1
      while stop < b.len and b.info[stop].infoCc != 0: inc stop
      if stop - i <= 32:
        for k in i + 1 ..< stop:
          var j = k
          while j > i and b.info[j - 1].infoCc > b.info[k].infoCc: dec j
          if j != k:
            let t = b.info[k]
            for m in countdown(k - 1, j): b.info[m + 1] = b.info[m]
            b.info[j] = t
        if arabic: b.reorderMarksArabic(i, stop)
      i = stop
  if b.hasCgj:
    for i in 1 ..< b.len - 1:
      if b.info[i].cp == 0x034F and
         (b.info[i + 1].infoCc == 0 or b.info[i - 1].infoCc <= b.info[i + 1].infoCc):
        b.info[i].uprops = b.info[i].uprops and not upHidden
  if not allSimple:
    b.clearOutput()
    var starter = 0
    b.nextGlyph()
    while b.idx < b.len:
      let x = b.cur
      if x.isUnicodeMark:
        var composed: int
        if (starter == b.outLen - 1 or b.outAt(b.outLen - 1).infoCc < x.infoCc) and
           composePair(int(b.outAt(starter).cp), int(x.cp), composed):
          let g = glyph(composed)
          if g != 0:
            b.nextGlyph()
            dec b.outLen
            var s = b.outAt(starter)
            s.cp = int32(composed)
            s.glyph = int32(g)
            b.setUnicodeProps(s)
            b.outAt(starter) = s
            continue
      b.nextGlyph()
      if b.outAt(b.outLen - 1).infoCc == 0: starter = b.outLen - 1
    b.sync()

proc planKey(si: ScriptInfo; lang: string; rtl: bool; features: openArray[Feature];
             vi: array[2, int]): string =
  result = si.iso & "|" & lang & "|" & $rtl & "|" & $vi[0] & "," & $vi[1]
  for f in features: result.add "|" & f.tag & (if f.on: "+" else: "-")

proc shape*(f: Face; cps: openArray[int]; rtl: bool; script = ""; lang = "";
            features: openArray[Feature] = []): seq[ShapedGlyph] =
  ## Shapes one run of text: `cps` the code points in logical order, all
  ## in one direction (`rtl`) and one face. `script` is an ISO 15924 or
  ## OpenType script tag ("arab", "Latn"; "" guesses it from the text),
  ## `lang` a BCP 47 code or OpenType language tag ("ur", "URD "; "" the
  ## script's default), `features` turns features on or off on top of the
  ## script's defaults. The glyphs come in the order they are drawn, left
  ## to right (a right-to-left run reversed); each glyph is drawn at the pen
  ## plus (`xOff`, `yOff`), then the pen moves by `xAdv`. The face's parsed
  ## tables and plans are kept with it (one face is not shaped from two
  ## threads at once).
  initUcd()
  if cps.len == 0: return
  let L = f.layout
  let si = scriptInfo(script, cps)
  let lt = langTag(lang)
  let coords = f.varCoords
  let vi = [L.variationIndex(L.t[0], coords), L.variationIndex(L.t[1], coords)]
  let key = planKey(si, lt, rtl, features, vi)
  var p = L.plans.getOrDefault(key)
  if p == nil:
    p = L.makePlan(si, lt, rtl, features, coords)
    L.plans[key] = p
  let b = Buf(rtl: rtl, random: 1)
  b.len = cps.len
  b.info = newSeq[GInfo](cps.len)
  for i, u in cps:
    var x = GInfo(cp: int32(u), cluster: int32(i), mask: p.globalMask, action: aNone)
    b.setUnicodeProps(x)
    if u >= 0x80:
      if x.gc != gcLetter and x.gc != gcZs:
        if u == 0x200D: x.uprops = x.uprops or upContinuation
        elif u in 0xFF9E .. 0xFF9F or u in 0xE0020 .. 0xE007F: x.uprops = x.uprops or upContinuation
        elif u == 0x2044: b.hasFracSlash = true
    b.info[i] = x
  # the script's own direction (digits in an Arabic run are left to right)
  var native = si.rtl
  if native and not rtl:
    var number, letter = false
    for i in 0 ..< b.len:
      let g = b.info[i].gc
      if g == gcLetter:
        letter = true
        break
      if g == gcNd: number = true
    if number and not letter: native = false
  if si.iso.len > 0 and native != rtl:
    var groups: seq[seq[GInfo]]
    for i in 0 ..< b.len:
      if groups.len == 0 or (b.info[i].uprops and upContinuation) == 0: groups.add @[b.info[i]]
      else: groups[^1].add b.info[i]
    var k = 0
    for gi in countdown(groups.len - 1, 0):
      for x in groups[gi]:
        b.info[k] = x
        inc k
    b.rtl = not rtl
  # mirroring
  if rtl:
    for i in 0 ..< b.len:
      let u = int(b.info[i].cp)
      let m = mirrorOf(u)
      if m != u and f.glyphOf(m) != 0: b.info[i].cp = int32(m)
      else: b.info[i].mask = b.info[i].mask or p.rtlmMask
  b.normalize(f, p.arabicShaper)
  # masks: fractions, Arabic joining
  if b.hasFracSlash and p.hasFrac:
    let pre = if not b.rtl: p.numrMask or p.fracMask else: p.fracMask or p.dnomMask
    let post = if not b.rtl: p.fracMask or p.dnomMask else: p.numrMask or p.fracMask
    var i = 0
    while i < b.len:
      if b.info[i].cp == 0x2044:
        var s = i
        var e = i + 1
        while s > 0 and b.info[s - 1].gc == gcNd: dec s
        while e < b.len and b.info[e].gc == gcNd: inc e
        if s != i and e != i + 1:
          for j in s ..< i: b.info[j].mask = b.info[j].mask or pre
          b.info[i].mask = b.info[i].mask or p.fracMask
          for j in i + 1 ..< e: b.info[j].mask = b.info[j].mask or post
          i = e - 1
      inc i
  if p.arabicShaper:
    b.arabicJoining()
    for i in 0 ..< b.len:
      let a = b.info[i].action
      if a < 7: b.info[i].mask = b.info[i].mask or p.arabicMasks[a]
  for i in 0 ..< b.len:
    b.info[i].cp = b.info[i].glyph
  # GSUB
  for i in 0 ..< b.len:
    b.info[i].gprops = uint16(L.glyphProps(int(b.info[i].cp)))
    b.info[i].lig = 0
  if p.fallbackClasses:
    for i in 0 ..< b.len:
      b.info[i].gprops = if b.info[i].gc != gcMn or b.info[i].isDefIgn: gpBase else: gpMark
  var c = Ctx(L: L, face: f, b: b, nesting: 64, hasGlyphClasses: L.glyphClass > 0,
              coords: coords, lastBase: -1, maxLen: max(16384, 32 * cps.len),
              ops: max(16384, 64 * cps.len) * max(1, p.lookups[0].len + p.lookups[1].len))
  c.table = 0
  var li = 0
  for st in p.stages[0]:
    while li < st.last:
      c.applyLookup(p.lookups[0][li])
      inc li
  # positions
  b.pos = newSeq[GPos](b.len)
  for i in 0 ..< b.len:
    b.pos[i].xa = int32(f.advance(int(b.info[i].cp)))
  if b.hasSpaceFallback:
    for i in 0 ..< b.len:
      let x = b.info[i]
      if x.gc != gcZs or (x.gprops and gpLigated) != 0: continue
      let st = int(x.uprops shr 8)
      case st
      of 1 .. 16: b.pos[i].xa = int32((f.unitsPerEm + st div 2) div st)
      of 17: b.pos[i].xa = int32(f.unitsPerEm * 4 div 18)
      of 19:
        for d in '0' .. '9':
          let g = f.glyphOf(ord(d))
          if g != 0:
            b.pos[i].xa = int32(f.advance(g))
            break
      of 20:
        var g = f.glyphOf(ord('.'))
        if g == 0: g = f.glyphOf(ord(','))
        if g != 0: b.pos[i].xa = int32(f.advance(g))
      of 21: b.pos[i].xa = b.pos[i].xa div 2
      else: discard
  if p.applyGpos:
    c.table = 1
    c.b.haveOutput = false
    li = 0
    for st in p.stages[1]:
      while li < st.last:
        c.applyLookup(p.lookups[1][li])
        inc li
  elif p.applyKern and p.kernMask != 0:
    var it = Iter()
    c.table = 1
    c.lookupMask = p.kernMask
    c.lookupProps = lfIgnoreMarks
    c.autoZwj = true
    c.autoZwnj = true
    c.initIters()
    var idx = 0
    while idx < b.len:
      if (b.info[idx].mask and p.kernMask) == 0:
        inc idx
        continue
      it = c.iterInput
      it.idx = idx
      it.stop = b.len
      it.setMatch(mkNone)
      if not c.next(it):
        idx = it.idx + 1
        continue
      let j = it.idx
      let k = f.kerning(int(b.info[idx].cp), int(b.info[j].cp))
      if k != 0:
        let k1 = k shr 1
        let k2 = k - k1
        b.pos[idx].xa += int32(k1)
        b.pos[j].xa += int32(k2)
        b.pos[j].xo += int32(k2)
      idx = j
  if p.zeroMarks:
    let adjust = p.adjustMarks and not b.rtl
    for i in 0 ..< b.len:
      if b.info[i].isMark:
        if adjust:
          b.pos[i].xo -= b.pos[i].xa
          b.pos[i].yo -= b.pos[i].ya
        b.pos[i].xa = 0
        b.pos[i].ya = 0
  if b.hasIgnorables:
    for i in 0 ..< b.len:
      if b.info[i].isDefIgn:
        b.pos[i].xa = 0
        b.pos[i].ya = 0
        b.pos[i].xo = 0
  if b.hasAttach:
    proc propagate(b: Buf; i: int; depth: int) =
      let chain = int(b.pos[i].chain)
      let typ = b.pos[i].atype
      b.pos[i].chain = 0
      let j = i + chain
      if j < 0 or j >= b.len or depth <= 0: return
      if b.pos[j].chain != 0: b.propagate(j, depth - 1)
      if (typ and atCursive) != 0:
        b.pos[i].yo += b.pos[j].yo
      else:
        b.pos[i].xo += b.pos[j].xo
        if j < i:
          if not b.rtl:
            for k in j ..< i:
              b.pos[i].xo -= b.pos[k].xa
              b.pos[i].yo -= b.pos[k].ya
          else:
            for k in j + 1 .. i:
              b.pos[i].xo += b.pos[k].xa
              b.pos[i].yo += b.pos[k].ya
        else:
          if not b.rtl:
            for k in i ..< j:
              b.pos[i].xo += b.pos[k].xa
              b.pos[i].yo += b.pos[k].ya
          else:
            for k in i + 1 .. j:
              b.pos[i].xo -= b.pos[k].xa
              b.pos[i].yo -= b.pos[k].ya
    if not b.rtl:
      for i in 0 ..< b.len:
        if b.pos[i].chain != 0: b.propagate(i, 64)
    else:
      for i in countdown(b.len - 1, 0):
        if b.pos[i].chain != 0: b.propagate(i, 64)
  if b.rtl:
    b.info.setLen(b.len)
    b.info.reverse()
    b.pos.reverse()
  # what default ignorables become: an invisible space, or nothing
  if b.hasIgnorables:
    let space = f.glyphOf(0x20)
    if space != 0:
      for i in 0 ..< b.len:
        if b.info[i].isDefIgn: b.info[i].cp = int32(space)
    else:
      var j = 0
      for i in 0 ..< b.len:
        if b.info[i].isDefIgn:
          let cl = b.info[i].cluster
          if i + 1 < b.len and cl == b.info[i + 1].cluster: continue
          if j > 0 and cl < b.info[j - 1].cluster:
            let old = b.info[j - 1].cluster
            var k = j
            while k > 0 and b.info[k - 1].cluster == old:
              b.info[k - 1].cluster = cl
              dec k
          continue
        b.info[j] = b.info[i]
        b.pos[j] = b.pos[i]
        inc j
      b.len = j
  result = newSeq[ShapedGlyph](b.len)
  for i in 0 ..< b.len:
    result[i] = ShapedGlyph(gid: int(b.info[i].cp), cluster: int(b.info[i].cluster),
                            xAdv: int(b.pos[i].xa), yAdv: int(b.pos[i].ya),
                            xOff: int(b.pos[i].xo), yOff: int(b.pos[i].yo))

# ---- what a font offers -----------------------------------------------------------------

proc hasLayout*(f: Face): bool =
  ## The face has a GSUB or GPOS table.
  let L = f.layout
  L.t[0].at >= 0 or L.t[1].at >= 0

proc placesMark*(f: Face; g: int): bool =
  ## The face's GDEF calls glyph `g` a mark: the font places it with its
  ## own tables (a mark it does not name -- a letter added to a font
  ## without its tables -- is the shaper's to place).
  let L = f.layout
  L.glyphClass > 0 and L.classOf(L.glyphClass, g) == 3

proc featureTags*(f: Face): seq[string] =
  ## Every feature tag the face's GSUB and GPOS tables have, sorted.
  let L = f.layout
  for k in 0 .. 1:
    if L.t[k].at < 0: continue
    for i in 0 ..< L.u16(L.t[k].features):
      let t = L.featureTagAt(L.t[k], i)
      if t notin result: result.add t
  result.sort()

const featureNames = {
  "aalt": "Access All Alternates", "abvm": "Above-base Mark Positioning",
  "afrc": "Alternative Fractions", "c2pc": "Petite Capitals From Capitals",
  "c2sc": "Small Capitals From Capitals", "calt": "Contextual Alternates",
  "case": "Case-Sensitive Forms", "ccmp": "Glyph Composition / Decomposition",
  "clig": "Contextual Ligatures", "cpsp": "Capital Spacing", "cswh": "Contextual Swash",
  "curs": "Cursive Positioning", "dist": "Distances", "dlig": "Discretionary Ligatures",
  "dnom": "Denominators", "fin2": "Terminal Forms #2", "fin3": "Terminal Forms #3",
  "fina": "Terminal Forms", "frac": "Fractions", "hist": "Historical Forms",
  "hlig": "Historical Ligatures", "init": "Initial Forms", "isol": "Isolated Forms",
  "kern": "Kerning", "liga": "Standard Ligatures", "lnum": "Lining Figures",
  "locl": "Localized Forms", "mark": "Mark Positioning", "med2": "Medial Forms #2",
  "medi": "Medial Forms", "mkmk": "Mark to Mark Positioning", "mset": "Mark Positioning via Substitution",
  "nalt": "Alternate Annotation Forms", "numr": "Numerators", "onum": "Oldstyle Figures",
  "ordn": "Ordinals", "ornm": "Ornaments", "pcap": "Petite Capitals",
  "pnum": "Proportional Figures", "rand": "Randomize", "rclt": "Required Contextual Alternates",
  "rlig": "Required Ligatures", "rtla": "Right-to-left Alternates",
  "rtlm": "Right-to-left Mirrored Forms", "rvrn": "Required Variation Alternates",
  "salt": "Stylistic Alternates", "sinf": "Scientific Inferiors", "smcp": "Small Capitals",
  "ss01": "Stylistic Set 1", "stch": "Stretching Glyph Decomposition", "subs": "Subscript",
  "sups": "Superscript", "swsh": "Swash", "titl": "Titling", "tnum": "Tabular Figures",
  "unic": "Unicase", "zero": "Slashed Zero", "ltra": "Left-to-right Alternates",
  "ltrm": "Left-to-right Mirrored Forms", "size": "Optical Size", "vert": "Vertical Writing",
  "vkrn": "Vertical Kerning", "jalt": "Justification Alternates"}.toTable

proc featureName*(f: Face; tag: string): string =
  ## A feature's name for people: "Standard Ligatures", "Stylistic Set 3";
  ## for stylistic sets and character variants the font's own name for it
  ## when it gives one. The tag itself when it is not known.
  let L = f.layout
  if tag.len == 4 and (tag.startsWith("ss") or tag.startsWith("cv")) and
     tag[2] in Digits and tag[3] in Digits:
    for k in 0 .. 1:
      if L.t[k].at < 0: continue
      for i in 0 ..< L.u16(L.t[k].features):
        if L.featureTagAt(L.t[k], i) != tag: continue
        let ft = L.featureTableAt(L.t[k], i, -1)
        let params = L.u16(ft)
        if params != 0:
          let id = L.u16(ft + params + 2)
          if id >= 256:
            let s = f.fontName(id)
            if s.len > 0: return s
    let n = parseInt(tag[2 .. 3])
    return (if tag[0] == 's': "Stylistic Set " else: "Character Variant ") & $n
  featureNames.getOrDefault(tag, tag)
