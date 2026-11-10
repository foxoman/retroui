## Style sheets for the HTML views: CSS read, matched and cascaded into one
## computed style per element.
##
## What it reads: `<style>` blocks (rules with type, `.class`, `#id`,
## attribute and `*` selectors, compound ones such as `td.x`, descendant
## and child combinators, selector lists; specificity and source order;
## `!important`), `style` attributes, the old presentational attributes
## (`bgcolor`, `color`, `width`, `height`, `align`, `valign`,
## `cellpadding`, `cellspacing`, `border`, `<font color size face>`,
## `nowrap`, `hspace`, `vspace`, `dir`...) and the defaults of the tags.
## What it leaves out: `@media`, `@font-face`, `@import` and the other
## at-rules, selectors with pseudo-classes or sibling combinators, and
## every property the layout does not use.
##
## The properties kept: display, color, background(-color), font-size,
## -weight, -style, -family (to spot monospace), text-decoration,
## text-align, vertical-align, margin, padding, border (per side: width,
## style, color), border-radius, width, min-/max-width, height,
## min-/max-height, line-height, white-space, text-transform, direction,
## visibility, opacity, overflow, float, clear, list-style-type,
## border-collapse, border-spacing, box-sizing, text-indent, mso-hide; and
## for flexible boxes and grids: display flex and grid, flex-direction,
## -wrap, -flow, flex, -grow, -shrink, -basis, justify-content,
## align-items, align-self, gap, row-gap, column-gap, order,
## grid-template-columns (pixels, percents, fr, repeat, minmax,
## auto-fill) and grid-column (span).
## Elements a mail hides (a newsletter's "preheader": display none,
## visibility hidden, opacity 0, max-height 0 with overflow hidden, a font
## of no size, mso-hide with any of these) are marked hidden.
##
## `htmllayout` uses it; an app needs it only to style a page of its own
## parsing:
##
## ```nim
## let doc = parseHtml("<style>p { color: red }</style><p>Hello</p>")
## let sheet = sheetOf(doc)
## var st = initialStyle()
## for n in doc.root.kids:
##   if n.tag == "p": st = cascade(n, initialStyle(), sheet)   # st.color: red
## ```

import std/[strutils, tables, algorithm, math]
import htmldom

# ---- colors ---------------------------------------------------------------------------------

const
  RoleLink* = 0x01000001'u32      ## a color the view picks from its theme: links
  RoleMark* = 0x01000002'u32      ## ... <mark>'s highlight
  RoleRule* = 0x01000003'u32      ## ... rules and the lines of tables with a border attribute
  RoleQuote* = 0x01000010'u32     ## ... a quote's bar (+ 0..3: how deep it is)
  RoleFaint* = 0x01000020'u32     ## ... the box of a picture that is not there
  RoleHeading* = 0x01000021'u32   ## ... a heading the page gives no color
  RoleCode* = 0x01000022'u32      ## ... code in the text, and
  RoleCodeBg* = 0x01000023'u32    ## ... its background

proc isRole*(c: uint32): bool {.inline.} = (c shr 24) == 1
  ## Whether `c` is one of the theme's colors (`RoleLink`...) rather than RGB.

const namedColors = {
  "aliceblue": 0xF0F8FF, "antiquewhite": 0xFAEBD7, "aqua": 0x00FFFF,
  "aquamarine": 0x7FFFD4, "azure": 0xF0FFFF, "beige": 0xF5F5DC, "bisque": 0xFFE4C4,
  "black": 0x000000, "blanchedalmond": 0xFFEBCD, "blue": 0x0000FF,
  "blueviolet": 0x8A2BE2, "brown": 0xA52A2A, "burlywood": 0xDEB887,
  "cadetblue": 0x5F9EA0, "chartreuse": 0x7FFF00, "chocolate": 0xD2691E,
  "coral": 0xFF7F50, "cornflowerblue": 0x6495ED, "cornsilk": 0xFFF8DC,
  "crimson": 0xDC143C, "cyan": 0x00FFFF, "darkblue": 0x00008B, "darkcyan": 0x008B8B,
  "darkgoldenrod": 0xB8860B, "darkgray": 0xA9A9A9, "darkgreen": 0x006400,
  "darkgrey": 0xA9A9A9, "darkkhaki": 0xBDB76B, "darkmagenta": 0x8B008B,
  "darkolivegreen": 0x556B2F, "darkorange": 0xFF8C00, "darkorchid": 0x9932CC,
  "darkred": 0x8B0000, "darksalmon": 0xE9967A, "darkseagreen": 0x8FBC8F,
  "darkslateblue": 0x483D8B, "darkslategray": 0x2F4F4F, "darkslategrey": 0x2F4F4F,
  "darkturquoise": 0x00CED1, "darkviolet": 0x9400D3, "deeppink": 0xFF1493,
  "deepskyblue": 0x00BFFF, "dimgray": 0x696969, "dimgrey": 0x696969,
  "dodgerblue": 0x1E90FF, "firebrick": 0xB22222, "floralwhite": 0xFFFAF0,
  "forestgreen": 0x228B22, "fuchsia": 0xFF00FF, "gainsboro": 0xDCDCDC,
  "ghostwhite": 0xF8F8FF, "gold": 0xFFD700, "goldenrod": 0xDAA520, "gray": 0x808080,
  "grey": 0x808080, "green": 0x008000, "greenyellow": 0xADFF2F, "honeydew": 0xF0FFF0,
  "hotpink": 0xFF69B4, "indianred": 0xCD5C5C, "indigo": 0x4B0082, "ivory": 0xFFFFF0,
  "khaki": 0xF0E68C, "lavender": 0xE6E6FA, "lavenderblush": 0xFFF0F5,
  "lawngreen": 0x7CFC00, "lemonchiffon": 0xFFFACD, "lightblue": 0xADD8E6,
  "lightcoral": 0xF08080, "lightcyan": 0xE0FFFF, "lightgoldenrodyellow": 0xFAFAD2,
  "lightgray": 0xD3D3D3, "lightgreen": 0x90EE90, "lightgrey": 0xD3D3D3,
  "lightpink": 0xFFB6C1, "lightsalmon": 0xFFA07A, "lightseagreen": 0x20B2AA,
  "lightskyblue": 0x87CEFA, "lightslategray": 0x778899, "lightslategrey": 0x778899,
  "lightsteelblue": 0xB0C4DE, "lightyellow": 0xFFFFE0, "lime": 0x00FF00,
  "limegreen": 0x32CD32, "linen": 0xFAF0E6, "magenta": 0xFF00FF, "maroon": 0x800000,
  "mediumaquamarine": 0x66CDAA, "mediumblue": 0x0000CD, "mediumorchid": 0xBA55D3,
  "mediumpurple": 0x9370DB, "mediumseagreen": 0x3CB371, "mediumslateblue": 0x7B68EE,
  "mediumspringgreen": 0x00FA9A, "mediumturquoise": 0x48D1CC,
  "mediumvioletred": 0xC71585, "midnightblue": 0x191970, "mintcream": 0xF5FFFA,
  "mistyrose": 0xFFE4E1, "moccasin": 0xFFE4B5, "navajowhite": 0xFFDEAD,
  "navy": 0x000080, "oldlace": 0xFDF5E6, "olive": 0x808000, "olivedrab": 0x6B8E23,
  "orange": 0xFFA500, "orangered": 0xFF4500, "orchid": 0xDA70D6,
  "palegoldenrod": 0xEEE8AA, "palegreen": 0x98FB98, "paleturquoise": 0xAFEEEE,
  "palevioletred": 0xDB7093, "papayawhip": 0xFFEFD5, "peachpuff": 0xFFDAB9,
  "peru": 0xCD853F, "pink": 0xFFC0CB, "plum": 0xDDA0DD, "powderblue": 0xB0E0E6,
  "purple": 0x800080, "rebeccapurple": 0x663399, "red": 0xFF0000,
  "rosybrown": 0xBC8F8F, "royalblue": 0x4169E1, "saddlebrown": 0x8B4513,
  "salmon": 0xFA8072, "sandybrown": 0xF4A460, "seagreen": 0x2E8B57,
  "seashell": 0xFFF5EE, "sienna": 0xA0522D, "silver": 0xC0C0C0, "skyblue": 0x87CEEB,
  "slateblue": 0x6A5ACD, "slategray": 0x708090, "slategrey": 0x708090,
  "snow": 0xFFFAFA, "springgreen": 0x00FF7F, "steelblue": 0x4682B4, "tan": 0xD2B48C,
  "teal": 0x008080, "thistle": 0xD8BFD8, "tomato": 0xFF6347, "turquoise": 0x40E0D0,
  "violet": 0xEE82EE, "wheat": 0xF5DEB3, "white": 0xFFFFFF, "whitesmoke": 0xF5F5F5,
  "yellow": 0xFFFF00, "yellowgreen": 0x9ACD32,
  # the system colors old pages name
  "windowtext": 0x000000, "window": 0xFFFFFF, "buttonface": 0xC0C0C0,
  "buttontext": 0x000000, "graytext": 0x808080, "highlight": 0x000080,
  "highlighttext": 0xFFFFFF, "canvas": 0xFFFFFF, "canvastext": 0x000000}.toTable

proc hexVal(c: char): int {.inline.} =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: -1

proc blendWhite(r, g, b: int; a: float): uint32 =
  ## A see-through color as it shows on white (pages are drawn on white).
  let k = clamp(a, 0.0, 1.0)
  let f = proc (v: int): uint32 = uint32(clamp(int(round(float(v) * k + 255 * (1 - k))), 0, 255))
  0xFF000000'u32 or (f(r) shl 16) or (f(g) shl 8) or f(b)

proc rgb(r, g, b: int): uint32 {.inline.} =
  0xFF000000'u32 or (uint32(clamp(r, 0, 255)) shl 16) or (uint32(clamp(g, 0, 255)) shl 8) or
    uint32(clamp(b, 0, 255))

proc numPart(p: string; full: float): float =
  ## A number of a color function: "128", "50%", ".5".
  let t = p.strip
  try:
    if t.endsWith("%"): parseFloat(t[0 ..< ^1]) * full / 100
    else: parseFloat(t)
  except ValueError: 0

proc hslRgb(h, s, l: float): (int, int, int) =
  let hh = ((h mod 360) + 360) mod 360 / 360
  let q = if l < 0.5: l * (1 + s) else: l + s - l * s
  let p = 2 * l - q
  proc hue(t0: float): float =
    var t = t0
    if t < 0: t += 1
    if t > 1: t -= 1
    if t < 1/6: p + (q - p) * 6 * t
    elif t < 1/2: q
    elif t < 2/3: p + (q - p) * (2/3 - t) * 6
    else: p
  (int(round(hue(hh + 1/3) * 255)), int(round(hue(hh) * 255)), int(round(hue(hh - 1/3) * 255)))

proc parseColor*(v: string; ok: var bool): uint32 =
  ## A CSS color ("#rgb", "#rrggbb", "#rrggbbaa", "rgb()", "rgba()",
  ## "hsl()", a name): 0xFFRRGGBB, or 0 for "transparent". `ok` false when
  ## it is not a color. Colors that are partly see-through are taken as
  ## they would show on white.
  ok = true
  let t = v.strip.toLowerAscii
  if t.len == 0:
    ok = false
    return
  if t[0] == '#':
    var h = t[1 .. ^1]
    for c in h:
      if hexVal(c) < 0:
        ok = false
        return
    case h.len
    of 3, 4:
      let r = hexVal(h[0]) * 17
      let g = hexVal(h[1]) * 17
      let b = hexVal(h[2]) * 17
      if h.len == 4: return blendWhite(r, g, b, hexVal(h[3]) / 15)
      return rgb(r, g, b)
    of 6, 8:
      let r = hexVal(h[0]) * 16 + hexVal(h[1])
      let g = hexVal(h[2]) * 16 + hexVal(h[3])
      let b = hexVal(h[4]) * 16 + hexVal(h[5])
      if h.len == 8:
        let a = hexVal(h[6]) * 16 + hexVal(h[7])
        if a == 0: return 0
        return blendWhite(r, g, b, a / 255)
      return rgb(r, g, b)
    else:
      ok = false
      return
  if t.startsWith("rgb") or t.startsWith("hsl"):
    let a = t.find('(')
    let b = t.rfind(')')
    if a < 0:
      ok = false
      return
    let inner = if b > a: t[a + 1 ..< b] else: t[a + 1 .. ^1]
    var parts = inner.replace("/", " ").replace(",", " ").splitWhitespace
    if parts.len < 3:
      ok = false
      return
    let alpha = if parts.len >= 4: numPart(parts[3], 1) else: 1.0
    if alpha <= 0.02: return 0
    var r, g, bl: int
    if t.startsWith("rgb"):
      r = int(round(numPart(parts[0], 255)))
      g = int(round(numPart(parts[1], 255)))
      bl = int(round(numPart(parts[2], 255)))
    else:
      var hue = 0.0
      try: hue = parseFloat(parts[0].strip(chars = {'d', 'e', 'g', 'r', 'a', 'n', 't', 'u'}))
      except ValueError: discard
      (r, g, bl) = hslRgb(hue, numPart(parts[1], 1) / (if parts[1].endsWith("%"): 1 else: 100),
                          numPart(parts[2], 1) / (if parts[2].endsWith("%"): 1 else: 100))
    if alpha < 0.99: return blendWhite(r, g, bl, alpha)
    return rgb(r, g, bl)
  if t == "transparent": return 0
  let c = namedColors.getOrDefault(t, -1)
  if c >= 0: return 0xFF000000'u32 or uint32(c)
  # an old page's "color=ff0000" (no '#')
  if t.len == 6:
    var allHex = true
    for ch in t:
      if hexVal(ch) < 0: allHex = false
    if allHex:
      return rgb(hexVal(t[0]) * 16 + hexVal(t[1]), hexVal(t[2]) * 16 + hexVal(t[3]),
                 hexVal(t[4]) * 16 + hexVal(t[5]))
  ok = false

proc colorOf*(v: string): uint32 =
  ## `parseColor`, 0 when it is not a color.
  var ok: bool
  parseColor(v, ok)

# ---- lengths --------------------------------------------------------------------------------

type
  LenKind* = enum
    ## What a `Len` is.
    lkAuto, lkPx, lkPct, lkNone
  Len* = object
    ## A length as the cascade leaves it: CSS pixels, a percentage, auto or none.
    k*: LenKind                ## auto, pixels, percent, none
    v*: float32                ## how many

const
  AutoLen* = Len(k: lkAuto)      ## `auto`
  NoneLen* = Len(k: lkNone)      ## `none` (max-width, max-height)

proc px*(v: float): Len {.inline.} = Len(k: lkPx, v: float32(v))
  ## A length in CSS pixels.

proc parseLen*(v: string; fontPx, rootPx: float; ok: var bool): Len =
  ## A CSS length ("12px", "1.5em", "50%", "10pt", "auto", "0"); a number
  ## alone is pixels (as old pages write them).
  ok = true
  let t = v.strip
  if t.len == 0:
    ok = false
    return AutoLen
  if t == "auto": return AutoLen
  if t == "none": return NoneLen
  if t.startsWith("calc(") or t.startsWith("min(") or t.startsWith("max(") or
     t.startsWith("clamp("):
    # (a sum: its first term, near enough)
    let inner = t[t.find('(') + 1 .. ^1].strip(chars = {')', ' '})
    var first = ""
    for c in inner:
      if c in {' ', ','}: break
      first.add c
    return parseLen(first, fontPx, rootPx, ok)
  var i = 0
  if i < t.len and t[i] in {'+', '-'}: inc i
  while i < t.len and t[i] in {'0'..'9', '.'}: inc i
  if i == 0 or (i == 1 and t[0] in {'+', '-', '.'}):
    ok = false
    return AutoLen
  var n = 0.0
  try: n = parseFloat(t[0 ..< i])
  except ValueError:
    ok = false
    return AutoLen
  if n != n or abs(n) > 1e6: n = 0                 # (NaN, absurd)
  let unit = t[i .. ^1].strip
  case unit
  of "", "px": px(n)
  of "%": Len(k: lkPct, v: float32(n))
  of "pt": px(n * 4 / 3)
  of "pc": px(n * 16)
  of "in": px(n * 96)
  of "cm": px(n * 96 / 2.54)
  of "mm": px(n * 96 / 25.4)
  of "q": px(n * 96 / 101.6)
  of "em": px(n * fontPx)
  of "rem": px(n * rootPx)
  of "ex", "ch": px(n * fontPx / 2)
  of "vw", "vmin", "vmax": Len(k: lkPct, v: float32(n))
  of "vh": px(n * 6)
  else:
    ok = false
    AutoLen

proc lenOf(v: string; fontPx, rootPx: float): Len =
  var ok: bool
  parseLen(v, fontPx, rootPx, ok)

proc attrLen*(v: string): Len =
  ## A presentational attribute's length: "600", "100%", "600px"; auto
  ## when it is none.
  let t = v.strip
  var i = 0
  while i < t.len and t[i] in {'0'..'9', '.'}: inc i
  if i == 0: return AutoLen
  var n = 0.0
  try: n = parseFloat(t[0 ..< i])
  except ValueError: return AutoLen
  n = min(n, 100_000)
  if i < t.len and t[i] == '%': Len(k: lkPct, v: float32(n)) else: px(n)

# ---- declarations ---------------------------------------------------------------------------

type
  Prop* = enum
    ## The properties read.
    pUnknown, pDisplay, pColor, pBackground, pBackgroundColor, pFontSize, pFontWeight,
    pFontStyle, pFontFamily, pFont, pTextDecoration, pTextAlign, pVerticalAlign,
    pPadding, pPaddingTop, pPaddingRight, pPaddingBottom, pPaddingLeft,
    pMargin, pMarginTop, pMarginRight, pMarginBottom, pMarginLeft,
    pBorder, pBorderTop, pBorderRight, pBorderBottom, pBorderLeft,
    pBorderWidth, pBorderStyle, pBorderColor,
    pBorderTopWidth, pBorderRightWidth, pBorderBottomWidth, pBorderLeftWidth,
    pBorderTopStyle, pBorderRightStyle, pBorderBottomStyle, pBorderLeftStyle,
    pBorderTopColor, pBorderRightColor, pBorderBottomColor, pBorderLeftColor,
    pBorderRadius, pWidth, pMinWidth, pMaxWidth, pHeight, pMinHeight, pMaxHeight,
    pLineHeight, pWhiteSpace, pTextTransform, pDirection, pVisibility, pOpacity,
    pOverflow, pMsoHide, pListStyleType, pListStyle, pFloat, pClear, pBorderCollapse,
    pBorderSpacing, pBoxSizing, pTextIndent, pPaddingInlineStart, pMarginInlineStart,
    pFlexDirection, pFlexWrap, pFlexFlow, pFlex, pFlexGrow, pFlexShrink, pFlexBasis,
    pJustifyContent, pAlignItems, pAlignSelf, pGap, pRowGap, pColumnGap, pOrder,
    pGridTemplateColumns, pGridColumn, pGridTemplateRows, pGridTemplateAreas, pGridArea,
    pGridRow, pGridRowStart, pGridRowEnd, pGridColumnStart, pGridColumnEnd,
    pPosition, pTop, pRight, pBottom, pLeft, pInset

  Decl* = object
    ## A declaration: a property and its value (lower case, trimmed).
    prop*: Prop                ## which property
    val*: string               ## its value
    important*: bool           ## `!important`

const propNames = {
  "display": pDisplay, "color": pColor, "background": pBackground,
  "background-color": pBackgroundColor, "font-size": pFontSize,
  "font-weight": pFontWeight, "font-style": pFontStyle, "font-family": pFontFamily,
  "font": pFont, "text-decoration": pTextDecoration,
  "text-decoration-line": pTextDecoration, "text-align": pTextAlign,
  "vertical-align": pVerticalAlign, "padding": pPadding, "padding-top": pPaddingTop,
  "padding-right": pPaddingRight, "padding-bottom": pPaddingBottom,
  "padding-left": pPaddingLeft, "margin": pMargin, "margin-top": pMarginTop,
  "margin-right": pMarginRight, "margin-bottom": pMarginBottom,
  "margin-left": pMarginLeft, "border": pBorder, "border-top": pBorderTop,
  "border-right": pBorderRight, "border-bottom": pBorderBottom,
  "border-left": pBorderLeft, "border-width": pBorderWidth,
  "border-style": pBorderStyle, "border-color": pBorderColor,
  "border-top-width": pBorderTopWidth, "border-right-width": pBorderRightWidth,
  "border-bottom-width": pBorderBottomWidth, "border-left-width": pBorderLeftWidth,
  "border-top-style": pBorderTopStyle, "border-right-style": pBorderRightStyle,
  "border-bottom-style": pBorderBottomStyle, "border-left-style": pBorderLeftStyle,
  "border-top-color": pBorderTopColor, "border-right-color": pBorderRightColor,
  "border-bottom-color": pBorderBottomColor, "border-left-color": pBorderLeftColor,
  "border-radius": pBorderRadius, "width": pWidth, "min-width": pMinWidth,
  "max-width": pMaxWidth, "height": pHeight, "min-height": pMinHeight,
  "max-height": pMaxHeight, "line-height": pLineHeight, "white-space": pWhiteSpace,
  "text-transform": pTextTransform, "direction": pDirection,
  "visibility": pVisibility, "opacity": pOpacity, "overflow": pOverflow,
  "overflow-y": pOverflow, "mso-hide": pMsoHide, "list-style-type": pListStyleType,
  "list-style": pListStyle, "float": pFloat, "clear": pClear,
  "border-collapse": pBorderCollapse, "border-spacing": pBorderSpacing,
  "box-sizing": pBoxSizing, "text-indent": pTextIndent,
  "padding-inline-start": pPaddingInlineStart,
  "margin-inline-start": pMarginInlineStart,
  "flex-direction": pFlexDirection, "flex-wrap": pFlexWrap, "flex-flow": pFlexFlow,
  "flex": pFlex, "flex-grow": pFlexGrow, "flex-shrink": pFlexShrink, "flex-basis": pFlexBasis,
  "justify-content": pJustifyContent, "align-items": pAlignItems, "align-self": pAlignSelf,
  "gap": pGap, "grid-gap": pGap, "row-gap": pRowGap, "grid-row-gap": pRowGap,
  "column-gap": pColumnGap, "grid-column-gap": pColumnGap, "order": pOrder,
  "grid-template-columns": pGridTemplateColumns, "grid-column": pGridColumn,
  "grid-template-rows": pGridTemplateRows, "grid-template-areas": pGridTemplateAreas,
  "grid-area": pGridArea, "grid-row": pGridRow, "grid-row-start": pGridRowStart,
  "grid-row-end": pGridRowEnd, "grid-column-start": pGridColumnStart,
  "grid-column-end": pGridColumnEnd, "position": pPosition, "top": pTop, "right": pRight,
  "bottom": pBottom, "left": pLeft, "inset": pInset,
  "-webkit-flex-direction": pFlexDirection, "-webkit-flex-wrap": pFlexWrap,
  "-webkit-flex": pFlex, "-webkit-justify-content": pJustifyContent,
  "-webkit-align-items": pAlignItems}.toTable

proc stripComments(s: string): string =
  if "/*" notin s: return s
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if i + 1 < s.len and s[i] == '/' and s[i + 1] == '*':
      let e = s.find("*/", i + 2)
      if e < 0: break
      i = e + 2
      result.add ' '
    else:
      result.add s[i]
      inc i

proc parseDecls*(s: string): seq[Decl] =
  ## The declarations of a `style` attribute or a rule's block ("a: b;
  ## c: d !important"). Properties the views do not use are left out.
  let t = stripComments(s)
  var i = 0
  while i < t.len:
    # one declaration: up to a ';' outside brackets and quotes
    var depth = 0
    var q = '\0'
    let start = i
    while i < t.len:
      let c = t[i]
      if q != '\0':
        if c == q: q = '\0'
      elif c in {'"', '\''}: q = c
      elif c == '(': inc depth
      elif c == ')': depth = max(0, depth - 1)
      elif c == ';' and depth == 0: break
      inc i
    let d = t[start ..< i]
    inc i
    let colon = d.find(':')
    if colon <= 0: continue
    let name = d[0 ..< colon].strip.toLowerAscii
    let p = propNames.getOrDefault(name, pUnknown)
    if p == pUnknown: continue
    var v = d[colon + 1 .. ^1].strip.toLowerAscii
    var imp = false
    let bang = v.rfind('!')
    if bang >= 0 and v[bang + 1 .. ^1].strip == "important":
      imp = true
      v = v[0 ..< bang].strip
    if v.len == 0 or v.len > 2000: continue
    result.add Decl(prop: p, val: v, important: imp)
    if result.len > 400: break

var inlineCache: Table[string, seq[Decl]]

proc inlineDecls*(style: string): ptr seq[Decl] =
  ## `parseDecls` of a `style` attribute, kept (newsletters repeat the same
  ## few hundred times). Valid until the next call.
  if style notin inlineCache:
    if inlineCache.len > 8000: inlineCache.clear()
    inlineCache[style] = parseDecls(style)
  addr inlineCache[style]

# ---- selectors and style sheets ---------------------------------------------------------------

type
  AttrOp = enum aoHas, aoEq, aoContains, aoPrefix, aoSuffix, aoWord, aoDash
  AttrSel = object
    name: string
    op: AttrOp
    val: string
  Compound = object
    tag: string                ## "" any
    id: string
    classes: seq[string]
    attrs: seq[AttrSel]
  Selector = object
    parts: seq[Compound]       ## the subject first, then its ancestors
    combs: seq[char]           ## between parts[i] and parts[i+1]: ' ' or '>'
    spec: int
  Rule = object
    sel: Selector
    decls: int                 ## index in `blocks`
    order: int
  StyleSheet* = object
    ## The rules of a page's `<style>` blocks, indexed by what their subject
    ## names (as browsers do: an element is tested only against rules that
    ## can be about it).
    rules: seq[Rule]
    blocks: seq[seq[Decl]]
    byId, byClass, byTag: Table[string, seq[int]]
    any: seq[int]

const MaxRules = 20_000

proc readIdent(s: string; i: var int): string =
  ## A name (with "\:"-style escapes, as utility-class mails write them).
  while i < s.len:
    let c = s[i]
    if c == '\\' and i + 1 < s.len:
      result.add s[i + 1]
      i += 2
    elif c.isAlphaNumeric or c in {'-', '_'} or ord(c) >= 0x80:
      result.add c
      inc i
    else: break

proc parseSelector(src: string; sel: var Selector): bool =
  ## One selector of a list; false when it uses what is not supported
  ## (pseudo-classes, sibling combinators...).
  let s = src.strip
  if s.len == 0 or s.len > 400: return false
  var parts: seq[Compound]
  var combs: seq[char]
  var cur = Compound()
  var have = false
  var pendingComb = '\0'
  var i = 0
  var ids, cls, tags = 0
  template endCompound() =
    if have:
      if parts.len > 0: combs.add(if pendingComb == '\0': ' ' else: pendingComb)
      parts.add cur
      cur = Compound()
      have = false
      pendingComb = '\0'
  while i < s.len:
    let c = s[i]
    case c
    of ' ', '\t', '\n', '\r', '\f':
      endCompound()
      inc i
    of '>':
      endCompound()
      if parts.len == 0: return false
      pendingComb = '>'
      inc i
    of '+', '~': return false
    of '*':
      have = true
      inc i
    of '.':
      inc i
      let n = readIdent(s, i)
      if n.len == 0: return false
      cur.classes.add n
      inc cls
      have = true
    of '#':
      inc i
      let n = readIdent(s, i)
      if n.len == 0: return false
      cur.id = n
      inc ids
      have = true
    of '[':
      let e = s.find(']', i)
      if e < 0: return false
      let body = s[i + 1 ..< e]
      i = e + 1
      var a = AttrSel()
      var opAt = -1
      for k, ch in body:
        if ch == '=':
          opAt = k
          break
      if opAt < 0:
        a.name = body.strip.toLowerAscii
        a.op = aoHas
      else:
        var nameEnd = opAt
        if opAt > 0 and body[opAt - 1] in {'*', '^', '$', '~', '|'}:
          nameEnd = opAt - 1
          a.op = case body[opAt - 1]
                 of '*': aoContains
                 of '^': aoPrefix
                 of '$': aoSuffix
                 of '~': aoWord
                 else: aoDash
        else: a.op = aoEq
        a.name = body[0 ..< nameEnd].strip.toLowerAscii
        var v = body[opAt + 1 .. ^1].strip
        if v.endsWith(" i") or v.endsWith(" s"): v = v[0 ..< ^2].strip
        if v.len >= 2 and v[0] in {'"', '\''} and v[^1] == v[0]: v = v[1 ..< ^1]
        a.val = v
      if a.name.len == 0: return false
      cur.attrs.add a
      inc cls
      have = true
    of ':':
      # :link and :visited are links; other pseudo-classes are left out
      inc i
      if i < s.len and s[i] == ':': return false
      let n = readIdent(s, i).toLowerAscii
      if n notin ["link", "visited", "any-link"]: return false
      cur.attrs.add AttrSel(name: "href", op: aoHas)
      inc cls
      have = true
    else:
      if c.isAlphaAscii or c == '\\' or c == '_' or ord(c) >= 0x80:
        let n = readIdent(s, i)
        if n.len == 0: return false
        cur.tag = n.toLowerAscii
        inc tags
        have = true
      else: return false
  endCompound()
  if parts.len == 0 or pendingComb != '\0': return false
  # (right to left: the subject first)
  sel.parts = @[]
  sel.combs = @[]
  for k in countdown(parts.high, 0): sel.parts.add parts[k]
  for k in countdown(combs.high, 0): sel.combs.add combs[k]
  sel.spec = ids * 10_000 + cls * 100 + tags
  true

proc skipBlock(s: string; i: var int) =
  ## From a '{' past its matching '}'.
  var depth = 0
  var q = '\0'
  while i < s.len:
    let c = s[i]
    if q != '\0':
      if c == q: q = '\0'
    elif c in {'"', '\''}: q = c
    elif c == '{': inc depth
    elif c == '}':
      dec depth
      if depth <= 0:
        inc i
        return
    inc i

proc addRule(sh: var StyleSheet; sel: Selector; blk: int) =
  let idx = sh.rules.len
  sh.rules.add Rule(sel: sel, decls: blk, order: idx)
  let subj = sel.parts[0]
  if subj.id.len > 0: sh.byId.mgetOrPut(subj.id, @[]).add idx
  elif subj.classes.len > 0: sh.byClass.mgetOrPut(subj.classes[0], @[]).add idx
  elif subj.tag.len > 0: sh.byTag.mgetOrPut(subj.tag, @[]).add idx
  else: sh.any.add idx

proc addSheet*(sh: var StyleSheet; css: string) =
  ## The rules of one style sheet added (at-rules left out).
  let s = stripComments(css)
  var i = 0
  while i < s.len and sh.rules.len < MaxRules:
    while i < s.len and s[i] in {' ', '\t', '\n', '\r', '\f', ';'}: inc i
    if i >= s.len: break
    if s.continuesWith("<!--", i):
      i += 4
      continue
    if s.continuesWith("-->", i):
      i += 3
      continue
    if s[i] == '@':
      # an at-rule: its block, or up to its ';'
      var j = i
      while j < s.len and s[j] notin {'{', ';'}: inc j
      if j < s.len and s[j] == '{':
        i = j
        skipBlock(s, i)
      else: i = j + 1
      continue
    if s[i] == '}':
      inc i
      continue
    let open = s.find('{', i)
    if open < 0: break
    let selText = s[i ..< open]
    var j = open
    skipBlock(s, j)
    let body = s[open + 1 ..< max(open + 1, j - 1)]
    i = j
    let decls = parseDecls(body)
    if decls.len == 0: continue
    var blk = -1
    for part in selText.split(','):
      var sel: Selector
      if parseSelector(part, sel):
        if blk < 0:
          blk = sh.blocks.len
          sh.blocks.add decls
        sh.addRule(sel, blk)

proc compoundMatches(c: Compound; n: HNode): bool =
  if c.tag.len > 0 and c.tag != n.tag: return false
  if c.id.len > 0 and c.id != n.id: return false
  for k in c.classes:
    if k notin n.classes: return false
  for a in c.attrs:
    if not n.hasAttr(a.name): return false
    if a.op == aoHas: continue
    let v = n.attr(a.name)
    let ok = case a.op
      of aoEq: v == a.val
      of aoContains: a.val.len > 0 and a.val in v
      of aoPrefix: a.val.len > 0 and v.startsWith(a.val)
      of aoSuffix: a.val.len > 0 and v.endsWith(a.val)
      of aoWord: a.val in v.splitWhitespace
      of aoDash: v == a.val or v.startsWith(a.val & "-")
      of aoHas: true
    if not ok: return false
  true

proc isElement(n: HNode): bool {.inline.} =
  n != nil and n.tag.len > 0 and n.tag[0] != '#'

var matchBudget = 0

proc matchesFrom(sel: Selector; k: int; n: HNode): bool =
  ## `sel.parts[k]` matched `n`: whether the rest matches its ancestors.
  if k >= sel.parts.high: return true
  dec matchBudget
  if matchBudget < 0: return false
  var p = n.parent
  if sel.combs[k] == '>':
    if not isElement(p): return false
    return compoundMatches(sel.parts[k + 1], p) and matchesFrom(sel, k + 1, p)
  while isElement(p):
    if compoundMatches(sel.parts[k + 1], p) and matchesFrom(sel, k + 1, p): return true
    if matchBudget < 0: return false
    p = p.parent
  false

proc matching*(sh: StyleSheet; n: HNode; into: var seq[tuple[spec, order, blk: int]]) =
  ## The rules that apply to `n`, in cascade order (weakest first).
  into.setLen(0)
  if sh.rules.len == 0: return
  template test(lst: seq[int]) =
    for r in lst:
      let rule = sh.rules[r]
      if compoundMatches(rule.sel.parts[0], n):
        matchBudget = 2000
        if matchesFrom(rule.sel, 0, n):
          var dup = false
          for e in into:
            if e.order == rule.order: dup = true
          if not dup: into.add (rule.sel.spec, rule.order, rule.decls)
  if n.id.len > 0 and sh.byId.hasKey(n.id): test(sh.byId[n.id])
  for c in n.classes:
    if sh.byClass.hasKey(c): test(sh.byClass[c])
  if sh.byTag.hasKey(n.tag): test(sh.byTag[n.tag])
  test(sh.any)
  if into.len > 1:
    into.sort(proc (a, b: tuple[spec, order, blk: int]): int =
      if a.spec != b.spec: cmp(a.spec, b.spec) else: cmp(a.order, b.order))

proc declsOf*(sh: StyleSheet; blk: int): lent seq[Decl] = sh.blocks[blk]
  ## The declarations of a rule found by `matching`.

proc ruleCount*(sh: StyleSheet): int = sh.rules.len
  ## How many rules the sheet has (one per selector of a list).

# ---- the computed style -----------------------------------------------------------------------

type
  Display* = enum
    ## How an element is laid out.
    dsInline, dsBlock, dsInlineBlock, dsListItem, dsTable, dsInlineTable, dsRowGroup,
    dsRow, dsCell, dsCaption, dsColumn, dsColumnGroup, dsNone
  TextAlign* = enum
    ## Where lines go (start: left, or right in a right-to-left paragraph).
    taStart, taLeft, taRight, taCenter, taEnd
  VAlign* = enum
    ## Where a picture sits in its line, a cell's content in its cell.
    vaBaseline, vaMiddle, vaTop, vaBottom, vaSub, vaSuper, vaTextTop, vaTextBottom
  WhiteSpace* = enum
    ## White space collapsed or kept, lines wrapped or not.
    wsNormal, wsNowrap, wsPre, wsPreLine
  Transform* = enum
    ## Letters made capitals or small.
    ttNone, ttUpper, ttLower, ttCapitalize
  ListStyle* = enum
    ## A list item's marker.
    lsDisc, lsCircle, lsSquare, lsDecimal, lsLowerAlpha, lsUpperAlpha, lsLowerRoman,
    lsUpperRoman, lsNone
  Dir* = enum
    ## The direction of the text (auto: from its first letter).
    dirAuto, dirLtr, dirRtl
  LineH* = enum
    ## How a line height is given.
    lhNormal, lhFactor, lhPx
  BoxFlow* = enum
    ## How a box lays out its children: one under another (and lines of
    ## words), in a row or a column of flexible boxes, in a grid.
    bfNormal, bfFlex, bfGrid
  FlexJustify* = enum
    ## justify-content: where a flexible row's boxes go when they leave room.
    fjStart, fjEnd, fjCenter, fjBetween, fjAround, fjEvenly
  FlexAlign* = enum
    ## align-items, align-self: where a box sits across its row (stretched to
    ## the row's height, at its top or bottom, in its middle); auto: as its
    ## container says.
    faAuto, faStretch, faStart, faEnd, faCenter
  GridTrackKind* = enum
    ## A grid column's width: pixels, a percentage, a share (fr) of what is
    ## left, as wide as its content (auto: a share too), or as many columns
    ## of at least `v` pixels as fit (auto-fill, auto-fit).
    gtPx, gtPct, gtFr, gtAuto, gtFill
  GridTrack* = object
    ## A column of a grid (grid-template-columns), or a row
    ## (grid-template-rows: its pixels; the others as tall as their content).
    k*: GridTrackKind
    v*: float32
  Position* = enum
    ## position: in the flow (static); moved from its place by top, left...
    ## (relative; sticky is drawn so); out of the flow, placed in the box
    ## that is positioned around it (absolute), or in the page (fixed).
    psStatic, psRelative, psAbsolute, psFixed

  CStyle* = object
    ## An element's computed style (lengths in CSS pixels).
    display*: Display          ## how it is laid out
    # inherited
    color*: uint32             ## 0: the theme's text color
    linkColor*: uint32         ## <body link=...>
    fontPx*: float32           ## its text's size
    bold*, italic*, mono*: bool    ## its text's look
    serif*: bool                   ## a serif family (FreeSerif)
    underline*, strike*: bool      ## ... lines through or under it
    align*: TextAlign          ## text-align
    alignBlocks*: bool         ## (an align attribute, <center>: blocks with a width follow it)
    lhKind*: LineH             ## its line height: normal, a factor, pixels
    lhVal*: float32            ## ... the factor or the pixels
    white*: WhiteSpace         ## white space
    transform*: Transform      ## capitals
    dir*: Dir                  ## direction (and the `dir` attribute)
    invisible*: bool           ## visibility: hidden (takes room, not drawn)
    listStyle*: ListStyle      ## list-style-type: its items' markers
    listDepth*: int16          ## lists around it
    quoteDepth*: int16         ## quotes around it
    collapse*: bool            ## border-collapse: collapse
    spacing*: float32          ## border-spacing
    # not inherited
    bg*: uint32                ## its background (0 none)
    radius*: float32           ## border-radius
    margin*: array[4, Len]     ## top, right, bottom, left
    padding*: array[4, Len]    ## top, right, bottom, left
    bw*: array[4, float32]     ## border widths (0: none)
    bs*: array[4, uint8]       ## border styles: 0 none, 1 solid, 2 dashed/dotted, 3 inset, 4 outset
    bc*: array[4, uint32]      ## border colors (0: the text color)
    width*, minW*, maxW*, height*, minH*, maxH*: Len   ## its size, as given
    valign*: VAlign            ## vertical-align (and `valign`)
    floatSide*: int8           ## 0 none, 1 left, 2 right
    clear*: int8               ## 1 left, 2 right, 3 both
    hidden*: bool              ## left out (a preheader...)
    overflowHidden*: bool      ## overflow hidden
    borderBox*: bool           ## box-sizing: border-box
    textIndent*: float32       ## text-indent: the first line's
    explicitColor*: bool       ## the element's own color was given (links keep it)
    flow*: BoxFlow                ## display: flex or grid -- its children laid out so
    column*: bool              ## flex-direction: column
    reverse*: bool             ## ... row-reverse, column-reverse
    wrap*: bool                ## flex-wrap: wrap
    justify*: FlexJustify          ## justify-content
    alignItems*: FlexAlign         ## align-items (its children's place across a row)
    alignSelf*: FlexAlign          ## align-self (its own; auto: its container's)
    gapRow*, gapCol*: Len      ## row-gap, column-gap (gap)
    grow*, shrink*: float32    ## flex-grow, flex-shrink
    basis*: Len                ## flex-basis (auto: its width, else its content's)
    order*: int16              ## order (in a flexible row or a grid)
    tracks*: seq[GridTrack]        ## grid-template-columns
    colSpan*: int16            ## grid-column: how many columns it takes (0: one)
    rowTracks*: seq[GridTrack]     ## grid-template-rows
    areas*: seq[seq[string]]       ## grid-template-areas: each row's names ("." none)
    areaName*: string          ## grid-area: the named area it goes in
    colStart*, colEnd*, rowStart*, rowEnd*: int16
      ## grid-column, grid-row: its lines (1 the first, -1 the last; 0 auto)
    rowSpan*: int16            ## grid-row: how many rows it takes (0: one)
    position*: Position        ## position
    inset*: array[4, Len]      ## top, right, bottom, left (auto: not given)

const RootPx* = 12.0
  ## The CSS pixels of the root's font: the UI's text size.

proc initialStyle*(): CStyle =
  ## The root's style before the page's.
  result.fontPx = RootPx
  result.spacing = 0
  result.shrink = 1
  result.alignItems = faStretch
  result.gapRow = px(0)
  result.gapCol = px(0)
  result.maxW = NoneLen
  result.maxH = NoneLen
  for k in 0 .. 3:
    result.margin[k] = px(0)
    result.padding[k] = px(0)
    result.bw[k] = 3        # (medium: shown when a style is given alone)

proc inheritFrom*(p: CStyle): CStyle =
  ## A child's style before its own rules: what is inherited, the rest initial.
  result = initialStyle()
  result.color = p.color
  result.linkColor = p.linkColor
  result.fontPx = p.fontPx
  result.bold = p.bold
  result.italic = p.italic
  result.mono = p.mono
  result.serif = p.serif
  result.underline = p.underline
  result.strike = p.strike
  result.align = p.align
  result.alignBlocks = p.alignBlocks
  result.lhKind = p.lhKind
  result.lhVal = p.lhVal
  result.white = p.white
  result.transform = p.transform
  result.dir = p.dir
  result.invisible = p.invisible
  result.listStyle = p.listStyle
  result.listDepth = p.listDepth
  result.quoteDepth = p.quoteDepth
  result.collapse = p.collapse
  result.spacing = p.spacing
  result.display = dsInline

# ---- applying declarations ---------------------------------------------------------------------

const fontKeywords = {"xx-small": 9.0, "x-small": 10.0, "small": 13.0, "medium": 16.0,
                      "large": 18.0, "x-large": 24.0, "xx-large": 32.0,
                      "xxx-large": 48.0}.toTable

proc fontSizeOf(v: string; parentPx: float): float =
  ## -1 when it is not a size.
  if v in fontKeywords: return fontKeywords[v]
  case v
  of "smaller": return parentPx / 1.2
  of "larger": return parentPx * 1.2
  of "inherit": return parentPx
  of "initial": return RootPx
  else: discard
  var ok: bool
  let l = parseLen(v, parentPx, RootPx, ok)
  if not ok: return -1
  case l.k
  of lkPx: max(0.0, float(l.v))
  of lkPct: parentPx * float(l.v) / 100
  else: -1

const monoNames = ["monospace", "courier", "courier new", "consolas", "monaco", "menlo",
                   "lucida console", "source code pro", "dejavu sans mono", "andale mono",
                   "liberation mono", "ubuntu mono", "sfmono-regular", "sf mono",
                   "fira code", "fira mono", "roboto mono", "cascadia code", "cascadia mono",
                   "jetbrains mono", "noto mono", "noto sans mono", "fixedsys", "terminal",
                   "lucida sans typewriter", "ocr a extended", "pt mono", "inconsolata"]

proc isMonoFamily(v: string): bool =
  ## The first family named is a monospaced one.
  let first = v.split(',')[0].strip.strip(chars = {'"', '\''}).strip
  first in monoNames

const serifNames = ["serif", "ui-serif", "times", "times new roman", "georgia", "garamond", "palatino",
                    "palatino linotype", "book antiqua", "cambria", "constantia", "baskerville", "didot",
                    "bodoni", "freeserif", "liberation serif", "dejavu serif", "noto serif", "tinos",
                    "nimbus roman", "century schoolbook", "charter", "bitstream charter", "iowan old style",
                    "minion pro", "pt serif", "source serif pro", "merriweather", "lora", "amiri",
                    "traditional arabic", "simplified arabic", "noto naskh arabic", "sakkal majalla"]

proc isSerifFamily(v: string): bool =
  ## The first family named is a serif one.
  let first = v.split(',')[0].strip.strip(chars = {'"', '\''}).strip
  first in serifNames

proc borderStyleOf(v: string): int =
  ## 0 none, 1 solid, 2 dashed, 3 inset, 4 outset; -1 not a style.
  case v
  of "none", "hidden": 0
  of "solid", "double", "groove", "ridge": 1
  of "dashed", "dotted": 2
  of "inset": 3
  of "outset": 4
  else: -1

proc widthWord(v: string): float =
  case v
  of "thin": 1
  of "medium": 3
  of "thick": 5
  else: -1

proc splitValue(v: string): seq[string] =
  ## A value's parts, white space between them (not inside brackets).
  var depth = 0
  var cur = ""
  for c in v:
    if c == '(': inc depth
    elif c == ')': depth = max(0, depth - 1)
    if c in {' ', '\t', '\n', '\r'} and depth == 0:
      if cur.len > 0:
        result.add cur
        cur = ""
    else: cur.add c
  if cur.len > 0: result.add cur

proc applyBorderSide(st: var CStyle; side: int; v: string; fontPx: float) =
  ## "1px solid #ccc" (any order) on one side.
  if v == "none" or v == "0":
    st.bs[side] = 0
    return
  for t in splitValue(v):
    let bsv = borderStyleOf(t)
    if bsv >= 0:
      st.bs[side] = uint8(bsv)
      continue
    let ww = widthWord(t)
    if ww >= 0:
      st.bw[side] = ww
      continue
    var ok: bool
    let c = parseColor(t, ok)
    if ok:
      st.bc[side] = c
      continue
    let l = parseLen(t, fontPx, RootPx, ok)
    if ok and l.k == lkPx: st.bw[side] = max(0'f32, l.v)

proc fourOf(v: string): array[4, string] =
  ## The 1-4 values of a shorthand, as top, right, bottom, left.
  let p = splitValue(v)
  case p.len
  of 0: ["", "", "", ""]
  of 1: [p[0], p[0], p[0], p[0]]
  of 2: [p[0], p[1], p[0], p[1]]
  of 3: [p[0], p[1], p[2], p[1]]
  else: [p[0], p[1], p[2], p[3]]

proc tracksOf(v: string; fontPx: float): seq[GridTrack] =
  ## grid-template-columns: "200px 1fr", "repeat(3, 1fr)", "1fr 2fr",
  ## "repeat(auto-fill, minmax(180px, 1fr))", "25% auto".
  proc one(w: string): GridTrack =
    let w = w.strip
    if w.endsWith("fr"):
      try: return GridTrack(k: gtFr, v: max(0'f32, float32(parseFloat(w[0 ..< ^2]))))
      except ValueError: return GridTrack(k: gtFr, v: 1)
    if w.startsWith("minmax(") and w.endsWith(")"):
      let ab = w[7 ..< ^1].split(',')
      if ab.len == 2:
        let hi = one(ab[1])
        return (if hi.k in {gtFr, gtAuto}: GridTrack(k: gtFr, v: max(1'f32, hi.v)) else: one(ab[0]))
    if w in ["auto", "min-content", "max-content"] or w.startsWith("fit-content"): return GridTrack(k: gtAuto, v: 1)
    var ok: bool
    let l = parseLen(w, fontPx, RootPx, ok)
    if ok and l.k == lkPx: return GridTrack(k: gtPx, v: l.v)
    if ok and l.k == lkPct: return GridTrack(k: gtPct, v: l.v)
    GridTrack(k: gtFr, v: 1)
  # (the top-level words, a function's commas kept inside it)
  var words: seq[string]
  var depth = 0
  var cur = ""
  for ch in v:
    if ch == '(': inc depth
    elif ch == ')': dec depth
    if ch == ' ' and depth == 0:
      if cur.len > 0: words.add cur
      cur = ""
    else: cur.add ch
  if cur.len > 0: words.add cur
  for w in words:
    if w.startsWith("[") : continue                   # (a line's name)
    if w.startsWith("repeat(") and w.endsWith(")"):
      let inner = w[7 ..< ^1]
      let comma = inner.find(',')
      if comma < 0: continue
      let count = inner[0 ..< comma].strip
      let what = inner[comma + 1 .. ^1].strip
      if count in ["auto-fill", "auto-fit"]:
        # (as many columns as fit, each at least its minmax's least)
        var least = 0'f32
        if what.startsWith("minmax(") and what.endsWith(")"):
          let ab = what[7 ..< ^1].split(',')
          var ok: bool
          let l = parseLen(ab[0].strip, fontPx, RootPx, ok)
          if ok and l.k == lkPx: least = l.v
        else:
          let t = one(what)
          if t.k == gtPx: least = t.v
        result.add GridTrack(k: gtFill, v: max(1'f32, least))
        continue
      var n = 1
      try: n = clamp(parseInt(count), 1, 100) except ValueError: discard
      var parts: seq[string]
      depth = 0
      cur = ""
      for ch in what:
        if ch == '(': inc depth
        elif ch == ')': dec depth
        if ch == ' ' and depth == 0:
          if cur.len > 0: parts.add cur
          cur = ""
        else: cur.add ch
      if cur.len > 0: parts.add cur
      for _ in 0 ..< n:
        for p in parts: result.add one(p)
    else: result.add one(w)
    if result.len > 100: break

proc gridLines(v: string; start, stop, span: var int16) =
  ## (grid-column, grid-row: "2", "1 / 3", "1 / -1", "span 2", "2 / span 3")
  proc num(w: string): int =
    try: clamp(parseInt(w.strip), -1000, 1000) except ValueError: 0
  proc spanOf(w: string): int =
    try: clamp(parseInt(w.strip[4 .. ^1].strip), 1, 1000) except ValueError: 1
  let parts = v.split('/')
  let a = parts[0].strip
  if a.startsWith("span"): span = int16(spanOf(a))
  elif a != "auto": start = int16(num(a))
  if parts.len > 1:
    let b = parts[1].strip
    if b.startsWith("span"): span = int16(spanOf(b))
    elif b != "auto":
      stop = int16(num(b))
      # (as wide as the lines say, for a grid that only counts spans)
      if start > 0 and stop > start: span = stop - start
      elif stop < 0: span = 1000

proc areasOf(v: string): seq[seq[string]] =
  ## (grid-template-areas: "head head" "side main": each string a row)
  var i = 0
  while i < v.len:
    let q = v[i]
    if q in {'"', '\''}:
      let e = v.find(q, i + 1)
      if e < 0: break
      let row = v[i + 1 ..< e].splitWhitespace
      if row.len > 0: result.add row
      i = e + 1
    else: inc i

proc applyDecl*(st: var CStyle; d: Decl; parent: CStyle) =
  ## One declaration on a style (font-size comes first: see `cascade`).
  let v = d.val
  let fpx = float(st.fontPx)
  template lenv(x: string): Len = lenOf(x, fpx, RootPx)
  case d.prop
  of pDisplay:
    st.flow = case v
      of "flex", "inline-flex", "-webkit-box", "-webkit-flex", "-webkit-inline-box": bfFlex
      of "grid", "inline-grid": bfGrid
      else: bfNormal
    st.display = case v
      of "none": dsNone
      of "block", "flex", "grid", "flow-root", "run-in", "-webkit-box", "-webkit-flex": dsBlock
      of "inline-block", "inline-flex", "inline-grid", "-webkit-inline-box": dsInlineBlock
      of "list-item": dsListItem
      of "table": dsTable
      of "inline-table": dsInlineTable
      of "table-row-group", "table-header-group", "table-footer-group": dsRowGroup
      of "table-row": dsRow
      of "table-cell": dsCell
      of "table-caption": dsCaption
      of "table-column": dsColumn
      of "table-column-group": dsColumnGroup
      of "inline", "contents": dsInline
      else: st.display
  of pColor:
    if v == "inherit":
      st.color = parent.color
    else:
      var ok: bool
      let c = parseColor(v, ok)
      if ok:
        if c == 0: st.invisible = true      # (transparent text)
        else:
          st.color = c
          st.explicitColor = true
  of pBackgroundColor:
    var ok: bool
    let c = parseColor(v, ok)
    if ok: st.bg = c
  of pBackground:
    if v == "none": st.bg = 0
    for t in splitValue(v):
      var ok: bool
      let c = parseColor(t, ok)
      if ok: st.bg = c
  of pFontSize: discard            # (first, in `cascade`)
  of pFontWeight:
    case v
    of "bold", "bolder": st.bold = true
    of "normal", "lighter": st.bold = false
    else:
      try: st.bold = parseInt(v) >= 600
      except ValueError: discard
  of pFontStyle: st.italic = v in ["italic", "oblique"]
  of pFontFamily:
    st.mono = isMonoFamily(v)
    st.serif = isSerifFamily(v)
  of pFont:
    # [style] [variant] [weight] size[/line-height] family
    let parts = splitValue(v)
    var k = 0
    while k < parts.len:
      let t = parts[k]
      if t in ["italic", "oblique"]: st.italic = true
      elif t in ["bold", "bolder"] or (t.len == 3 and t[0] in {'6'..'9'} and t[1 .. 2] == "00"):
        st.bold = true
      elif t in ["normal", "small-caps", "lighter"] or (t.len == 3 and t[1 .. 2] == "00"): discard
      else: break
      inc k
    if k < parts.len:
      let sz = parts[k]
      let slash = sz.find('/')
      if slash > 0:
        let lh = sz[slash + 1 .. ^1]
        try:
          let f = parseFloat(lh)
          st.lhKind = lhFactor
          st.lhVal = f
        except ValueError:
          let l = lenv(lh)
          if l.k == lkPx: (st.lhKind, st.lhVal) = (lhPx, l.v)
          elif l.k == lkPct: (st.lhKind, st.lhVal) = (lhFactor, l.v / 100)
      if k + 1 < parts.len:
        st.mono = isMonoFamily(parts[k + 1 .. ^1].join(" "))
        st.serif = isSerifFamily(parts[k + 1 .. ^1].join(" "))
  of pTextDecoration:
    if "none" in v:
      st.underline = false
      st.strike = false
    if "underline" in v: st.underline = true
    if "line-through" in v: st.strike = true
  of pTextAlign:
    st.alignBlocks = false
    st.align = case v
      of "left": taLeft
      of "right": taRight
      of "center": taCenter
      of "-webkit-center", "-moz-center":
        st.alignBlocks = true
        taCenter
      of "end": taEnd
      of "start", "justify", "initial": taStart
      else: st.align
  of pVerticalAlign:
    st.valign = case v
      of "middle", "-webkit-baseline-middle": vaMiddle
      of "top": vaTop
      of "bottom": vaBottom
      of "sub": vaSub
      of "super": vaSuper
      of "text-top": vaTextTop
      of "text-bottom": vaTextBottom
      else: vaBaseline
  of pPadding:
    let f = fourOf(v)
    for k in 0 .. 3:
      let l = lenv(f[k])
      if l.k in {lkPx, lkPct}: st.padding[k] = Len(k: l.k, v: max(0'f32, l.v))
  of pPaddingTop, pPaddingRight, pPaddingBottom, pPaddingLeft:
    let l = lenv(v)
    if l.k in {lkPx, lkPct}:
      st.padding[ord(d.prop) - ord(pPaddingTop)] = Len(k: l.k, v: max(0'f32, l.v))
  of pPaddingInlineStart:
    let l = lenv(v)
    if l.k in {lkPx, lkPct}: st.padding[if st.dir == dirRtl: 1 else: 3] = l
  of pMargin:
    let f = fourOf(v)
    for k in 0 .. 3:
      var ok: bool
      let l = parseLen(f[k], fpx, RootPx, ok)
      if ok: st.margin[k] = l
  of pMarginTop, pMarginRight, pMarginBottom, pMarginLeft:
    var ok: bool
    let l = parseLen(v, fpx, RootPx, ok)
    if ok: st.margin[ord(d.prop) - ord(pMarginTop)] = l
  of pMarginInlineStart:
    var ok: bool
    let l = parseLen(v, fpx, RootPx, ok)
    if ok: st.margin[if st.dir == dirRtl: 1 else: 3] = l
  of pBorder:
    for k in 0 .. 3:
      st.bw[k] = 3
      st.bc[k] = 0
      applyBorderSide(st, k, v, fpx)
  of pBorderTop, pBorderRight, pBorderBottom, pBorderLeft:
    let k = ord(d.prop) - ord(pBorderTop)
    st.bw[k] = 3
    st.bc[k] = 0
    applyBorderSide(st, k, v, fpx)
  of pBorderWidth:
    let f = fourOf(v)
    for k in 0 .. 3:
      let ww = widthWord(f[k])
      if ww >= 0: st.bw[k] = ww
      else:
        let l = lenv(f[k])
        if l.k == lkPx: st.bw[k] = max(0'f32, l.v)
  of pBorderStyle:
    let f = fourOf(v)
    for k in 0 .. 3:
      let s = borderStyleOf(f[k])
      if s >= 0: st.bs[k] = uint8(s)
  of pBorderColor:
    let f = fourOf(v)
    for k in 0 .. 3:
      var ok: bool
      let c = parseColor(f[k], ok)
      if ok: st.bc[k] = c
  of pBorderTopWidth, pBorderRightWidth, pBorderBottomWidth, pBorderLeftWidth:
    let k = ord(d.prop) - ord(pBorderTopWidth)
    let ww = widthWord(v)
    if ww >= 0: st.bw[k] = ww
    else:
      let l = lenv(v)
      if l.k == lkPx: st.bw[k] = max(0'f32, l.v)
  of pBorderTopStyle, pBorderRightStyle, pBorderBottomStyle, pBorderLeftStyle:
    let s = borderStyleOf(v)
    if s >= 0: st.bs[ord(d.prop) - ord(pBorderTopStyle)] = uint8(s)
  of pBorderTopColor, pBorderRightColor, pBorderBottomColor, pBorderLeftColor:
    var ok: bool
    let c = parseColor(v, ok)
    if ok: st.bc[ord(d.prop) - ord(pBorderTopColor)] = c
  of pBorderRadius:
    let l = lenv(splitValue(v.split('/')[0])[0])
    if l.k == lkPx: st.radius = max(0'f32, l.v)
  of pWidth: st.width = lenv(v)
  of pMinWidth: st.minW = lenv(v)
  of pMaxWidth: st.maxW = lenv(v)
  of pHeight: st.height = lenv(v)
  of pMinHeight: st.minH = lenv(v)
  of pMaxHeight: st.maxH = lenv(v)
  of pLineHeight:
    if v == "normal": st.lhKind = lhNormal
    elif v == "inherit": (st.lhKind, st.lhVal) = (parent.lhKind, parent.lhVal)
    else:
      var allNum = v.len > 0
      for c in v:
        if c notin {'0'..'9', '.'}: allNum = false
      if allNum:
        try: (st.lhKind, st.lhVal) = (lhFactor, float32(parseFloat(v)))
        except ValueError: discard
      else:
        let l = lenv(v)
        if l.k == lkPx: (st.lhKind, st.lhVal) = (lhPx, l.v)
        elif l.k == lkPct: (st.lhKind, st.lhVal) = (lhPx, l.v * st.fontPx / 100)
  of pWhiteSpace:
    st.white = case v
      of "nowrap": wsNowrap
      of "pre", "pre-wrap", "break-spaces": wsPre
      of "pre-line": wsPreLine
      of "normal": wsNormal
      else: st.white
  of pTextTransform:
    st.transform = case v
      of "uppercase": ttUpper
      of "lowercase": ttLower
      of "capitalize": ttCapitalize
      else: ttNone
  of pDirection:
    if v == "rtl": st.dir = dirRtl
    elif v == "ltr": st.dir = dirLtr
  of pVisibility:
    st.invisible = v in ["hidden", "collapse"]
  of pOpacity:
    try:
      var t = v
      var f = 1.0
      if t.endsWith("%"): f = parseFloat(t[0 ..< ^1]) / 100
      else: f = parseFloat(t)
      if f <= 0.01: st.hidden = true
    except ValueError: discard
  of pOverflow: st.overflowHidden = v in ["hidden", "clip"]
  of pMsoHide: discard          # (in `finish`)
  of pListStyleType, pListStyle:
    for t in splitValue(v):
      case t
      of "disc": st.listStyle = lsDisc
      of "circle": st.listStyle = lsCircle
      of "square": st.listStyle = lsSquare
      of "decimal", "decimal-leading-zero": st.listStyle = lsDecimal
      of "lower-alpha", "lower-latin": st.listStyle = lsLowerAlpha
      of "upper-alpha", "upper-latin": st.listStyle = lsUpperAlpha
      of "lower-roman": st.listStyle = lsLowerRoman
      of "upper-roman": st.listStyle = lsUpperRoman
      of "none": st.listStyle = lsNone
      else: discard
  of pFloat:
    st.floatSide = case v
      of "left": 1
      of "right": 2
      else: 0
  of pClear:
    st.clear = case v
      of "left": 1
      of "right": 2
      of "both": 3
      else: 0
  of pBorderCollapse: st.collapse = v == "collapse"
  of pBorderSpacing:
    let l = lenv(splitValue(v)[0])
    if l.k == lkPx: st.spacing = max(0'f32, l.v)
  of pBoxSizing: st.borderBox = v == "border-box"
  of pTextIndent:
    let l = lenv(v)
    if l.k == lkPx: st.textIndent = l.v
  of pFlexDirection:
    st.column = v.startsWith("column")
    st.reverse = v.endsWith("-reverse")
  of pFlexWrap: st.wrap = v.startsWith("wrap")
  of pFlexFlow:
    for w in splitValue(v):
      if w.startsWith("row") or w.startsWith("column"):
        st.column = w.startsWith("column")
        st.reverse = w.endsWith("-reverse")
      elif w.startsWith("wrap") or w == "nowrap": st.wrap = w.startsWith("wrap")
  of pFlex:
    # (none, auto, a grow, a grow and a shrink, a grow and a basis, all three)
    case v
    of "none": (st.grow, st.shrink, st.basis) = (0'f32, 0'f32, Len(k: lkAuto))
    of "auto": (st.grow, st.shrink, st.basis) = (1'f32, 1'f32, Len(k: lkAuto))
    of "initial": (st.grow, st.shrink, st.basis) = (0'f32, 1'f32, Len(k: lkAuto))
    else:
      var nums: seq[float32]
      var basis = px(0)
      for w in splitValue(v):
        try: nums.add float32(parseFloat(w))
        except ValueError:
          let l = lenv(w)
          if l.k in {lkPx, lkPct} or w in ["auto", "content"]: basis = l
      if nums.len > 0: st.grow = max(0'f32, nums[0])
      st.shrink = if nums.len > 1: max(0'f32, nums[1]) else: 1
      st.basis = basis
  of pFlexGrow:
    try: st.grow = max(0'f32, float32(parseFloat(v))) except ValueError: discard
  of pFlexShrink:
    try: st.shrink = max(0'f32, float32(parseFloat(v))) except ValueError: discard
  of pFlexBasis: st.basis = lenv(v)
  of pJustifyContent:
    st.justify = case v
      of "flex-end", "end", "right": fjEnd
      of "center": fjCenter
      of "space-between": fjBetween
      of "space-around": fjAround
      of "space-evenly": fjEvenly
      else: fjStart
  of pAlignItems, pAlignSelf:
    let a = case v
      of "flex-start", "start", "self-start", "baseline", "first baseline": faStart
      of "flex-end", "end", "self-end": faEnd
      of "center": faCenter
      of "auto": faAuto
      else: faStretch
    if d.prop == pAlignItems: st.alignItems = (if a == faAuto: faStretch else: a)
    else: st.alignSelf = a
  of pGap:
    let w = splitValue(v)
    if w.len > 0:
      st.gapRow = lenv(w[0])
      st.gapCol = if w.len > 1: lenv(w[1]) else: st.gapRow
  of pRowGap: st.gapRow = lenv(v)
  of pColumnGap: st.gapCol = lenv(v)
  of pOrder:
    try: st.order = int16(clamp(parseInt(v), -1000, 1000)) except ValueError: discard
  of pGridTemplateColumns: st.tracks = tracksOf(v, fpx)
  of pGridColumn: gridLines(v, st.colStart, st.colEnd, st.colSpan)
  of pGridColumnStart: gridLines(v, st.colStart, st.colEnd, st.colSpan)
  of pGridColumnEnd:
    var a: int16
    gridLines(v, a, a, st.colSpan)
    if not v.startsWith("span"): st.colEnd = a
  of pGridRow: gridLines(v, st.rowStart, st.rowEnd, st.rowSpan)
  of pGridRowStart: gridLines(v, st.rowStart, st.rowEnd, st.rowSpan)
  of pGridRowEnd:
    var a: int16
    gridLines(v, a, a, st.rowSpan)
    if not v.startsWith("span"): st.rowEnd = a
  of pGridTemplateRows: st.rowTracks = tracksOf(v, fpx)
  of pGridTemplateAreas: st.areas = (if v == "none": @[] else: areasOf(v))
  of pGridArea:
    # (a name, or its lines: row start / column start / row end / column end)
    let parts = v.split('/')
    if parts.len == 1 and v.len > 0 and v[0] in {'a'..'z', '_', '-'} and not v.startsWith("span") and
       v != "auto":
      st.areaName = v
    else:
      if parts.len > 0: gridLines(parts[0], st.rowStart, st.rowEnd, st.rowSpan)
      if parts.len > 1: gridLines(parts[1], st.colStart, st.colEnd, st.colSpan)
      if parts.len > 2: gridLines(parts[0] & " / " & parts[2], st.rowStart, st.rowEnd, st.rowSpan)
      if parts.len > 3: gridLines(parts[1] & " / " & parts[3], st.colStart, st.colEnd, st.colSpan)
  of pPosition:
    st.position = case v
      of "relative", "sticky", "-webkit-sticky": psRelative
      of "absolute": psAbsolute
      of "fixed": psFixed
      else: psStatic
  of pTop: st.inset[0] = lenv(v)
  of pRight: st.inset[1] = lenv(v)
  of pBottom: st.inset[2] = lenv(v)
  of pLeft: st.inset[3] = lenv(v)
  of pInset:
    let w = splitValue(v)
    if w.len > 0:
      let t = lenv(w[0])
      let r = if w.len > 1: lenv(w[1]) else: t
      let b = if w.len > 2: lenv(w[2]) else: t
      let l = if w.len > 3: lenv(w[3]) else: r
      st.inset = [t, r, b, l]
  of pUnknown: discard

# ---- the tags' own styles and their attributes -------------------------------------------------

const
  blockTags = ["html", "body", "div", "p", "section", "article", "header", "footer",
               "main", "nav", "aside", "figure", "figcaption", "address", "center",
               "details", "summary", "hgroup", "h1", "h2", "h3", "h4", "h5", "h6",
               "ul", "ol", "dl", "dt", "dd", "blockquote", "pre", "hr", "menu", "dir",
               "fieldset", "legend", "noscript", "search", "listing", "xmp", "plaintext",
               "form", "dialog"]
  noneTags = ["head", "script", "style", "title", "meta", "link", "template", "base",
              "param", "source", "track", "area", "map", "datalist", "noembed",
              "noframes", "iframe", "object", "embed", "svg", "math", "canvas", "video",
              "audio", "select", "option", "optgroup", "button", "textarea", "label",
              "output", "progress", "meter", "frameset", "frame", "applet", "picture",
              "xml", "basefont", "bgsound", "keygen", "dialog", "form", "rp"]
  headingEm = [2.0, 1.5, 1.17, 1.0, 0.83, 0.67]
  headingMargin = [0.67, 0.83, 1.0, 1.33, 1.67, 2.33]

proc fontAttrPx(v: string; parentPx: float): float =
  ## <font size="1".."7", "+1", "-2">: CSS pixels.
  const sizes = [10.0, 13.0, 16.0, 18.0, 24.0, 32.0, 48.0]
  let t = v.strip
  if t.len == 0: return -1
  var n = 0
  try:
    if t[0] in {'+', '-'}: n = 3 + parseInt(t)
    else: n = parseInt(t)
  except ValueError: return -1
  sizes[clamp(n, 1, 7) - 1]

proc tableOf(n: HNode): HNode =
  ## The table a cell (or row) is in.
  var p = n.parent
  var k = 0
  while p != nil and k < 4:
    if p.tag == "table": return p
    p = p.parent
    inc k

proc tagDefaults(n: HNode; st: var CStyle; parent: CStyle) =
  ## What the tag itself asks (a browser's own style sheet, as mail clients
  ## have it).
  let t = n.tag
  let fpx = float(st.fontPx)
  if t in blockTags: st.display = dsBlock
  if t in noneTags: st.display = dsNone
  case t
  of "body":
    st.margin = [px(0), px(0), px(0), px(0)]
  of "p", "dl", "pre", "listing", "xmp", "plaintext", "figure":
    st.margin[0] = px(fpx)
    st.margin[2] = px(fpx)
    if t in ["pre", "listing", "xmp", "plaintext"]:
      st.white = wsPre
      st.mono = true
  of "h1", "h2", "h3", "h4", "h5", "h6":
    let lvl = ord(t[1]) - ord('1')
    st.fontPx = float32(parent.fontPx * headingEm[lvl])
    st.bold = true
    if parent.color == 0: st.color = RoleHeading
    st.margin[0] = px(st.fontPx * headingMargin[lvl] / headingEm[lvl] * 0.75)
    st.margin[2] = st.margin[0]
  of "ul", "ol", "menu", "dir":
    if parent.listDepth == 0:
      st.margin[0] = px(fpx)
      st.margin[2] = px(fpx)
    st.padding[if st.dir == dirRtl: 1 else: 3] = px(36)
    st.listDepth = parent.listDepth + 1
    st.listStyle = if t == "ol": lsDecimal
                   elif parent.listDepth == 0: lsDisc
                   elif parent.listDepth == 1: lsCircle
                   else: lsSquare
  of "li": st.display = dsListItem
  of "dd": st.margin[if st.dir == dirRtl: 1 else: 3] = px(36)
  of "blockquote":
    st.quoteDepth = parent.quoteDepth + 1
    st.margin[0] = px(fpx * 0.6)
    st.margin[2] = px(fpx * 0.6)
    let side = if st.dir == dirRtl: 1 else: 3
    st.margin[side] = px(3)
    st.padding[side] = px(10)
    st.bw[side] = 2
    st.bs[side] = 1
    st.bc[side] = RoleQuote + uint32(min(3, st.quoteDepth - 1))
  of "hr":
    st.margin[0] = px(fpx * 0.5)
    st.margin[2] = px(fpx * 0.5)
    for k in 0 .. 3:
      st.bw[k] = 1
      st.bs[k] = 1
      st.bc[k] = RoleRule
  of "center":
    st.align = taCenter
    st.alignBlocks = true
  of "b", "strong": st.bold = true
  of "i", "em", "cite", "var", "dfn", "address": st.italic = true
  of "u", "ins": st.underline = true
  of "s", "strike", "del": st.strike = true
  of "code", "kbd", "samp", "tt":
    st.mono = true
    if n.parent == nil or n.parent.tag notin ["pre", "listing", "xmp"]:
      if parent.color == 0: st.color = RoleCode
      st.bg = RoleCodeBg
  of "small": st.fontPx = float32(parent.fontPx / 1.2)
  of "big": st.fontPx = float32(parent.fontPx * 1.2)
  of "sub", "sup":
    st.fontPx = float32(parent.fontPx * 0.83)
    st.valign = if t == "sub": vaSub else: vaSuper
  of "mark": st.bg = RoleMark
  of "a":
    if n.hasAttr("href"):
      st.color = if parent.linkColor != 0: parent.linkColor else: RoleLink
      st.underline = true
  of "table":
    st.display = dsTable
    st.collapse = false
    st.spacing = 2
    st.align = parent.align
  of "caption":
    st.display = dsCaption
    st.align = taCenter
  of "thead", "tbody", "tfoot":
    st.display = dsRowGroup
    st.valign = vaMiddle
  of "tr":
    st.display = dsRow
    st.valign = if parent.display == dsRowGroup: parent.valign else: vaMiddle
  of "td", "th":
    st.display = dsCell
    st.valign = parent.valign
    if parent.display notin {dsRow, dsRowGroup}: st.valign = vaMiddle
    if t == "th":
      st.bold = true
      st.align = taCenter
    let tb = tableOf(n)
    var pad = 1.0
    if tb != nil:
      let cp = tb.attr("cellpadding")
      if cp.len > 0:
        let l = attrLen(cp)
        if l.k == lkPx: pad = l.v
      let b = tb.attr("border")
      if b.len > 0 and attrLen(b).v > 0:
        for k in 0 .. 3:
          st.bw[k] = 1
          st.bs[k] = 3
          st.bc[k] = RoleRule
    for k in 0 .. 3: st.padding[k] = px(pad)
  of "col": st.display = dsColumn
  of "colgroup": st.display = dsColumnGroup
  of "img": st.display = dsInline
  of "q":
    discard
  of "summary", "dt", "legend": st.bold = t != "dt"
  else: discard

proc alignOf(v: string): TextAlign =
  case v.strip.toLowerAscii
  of "left": taLeft
  of "right": taRight
  of "center", "middle": taCenter
  else: taStart

proc presentational(n: HNode; st: var CStyle; parent: CStyle) =
  ## The old attributes: below every rule of the page (specificity 0).
  let t = n.tag
  for (k, v) in n.attrs:
    case k
    of "bgcolor":
      if t in ["body", "table", "tr", "td", "th", "thead", "tbody", "tfoot", "div", "font"]:
        var ok: bool
        let c = parseColor(v, ok)
        if ok: st.bg = c
    of "color":
      if t in ["font", "hr", "basefont"]:
        var ok: bool
        let c = parseColor(v, ok)
        if ok and c != 0:
          if t == "hr":
            for s in 0 .. 3: st.bc[s] = c
            st.bg = c
          else:
            st.color = c
            st.explicitColor = true
    of "text":
      if t == "body":
        var ok: bool
        let c = parseColor(v, ok)
        if ok and c != 0: st.color = c
    of "link":
      if t == "body":
        var ok: bool
        let c = parseColor(v, ok)
        if ok and c != 0: st.linkColor = c
    of "size":
      if t == "font":
        let f = fontAttrPx(v, parent.fontPx)
        if f > 0: st.fontPx = float32(f)
      elif t == "hr":
        let l = attrLen(v)
        if l.k == lkPx and l.v > 1: st.height = px(l.v - 2)
    of "face":
      if t == "font":
        st.mono = isMonoFamily(v.toLowerAscii)
        st.serif = isSerifFamily(v.toLowerAscii)
    of "width":
      if t in ["table", "td", "th", "img", "col", "colgroup", "hr", "pre", "div", "p"]:
        let l = attrLen(v)
        if l.k != lkAuto and (t != "pre"): st.width = l
    of "height":
      if t in ["table", "td", "th", "tr", "img"]:
        let l = attrLen(v)
        if l.k == lkPx: st.height = l
    of "align":
      let a = v.strip.toLowerAscii
      case t
      of "table":
        if a == "left": st.floatSide = 1
        elif a == "right": st.floatSide = 2
        elif a == "center":
          st.margin[1] = AutoLen
          st.margin[3] = AutoLen
      of "img", "object", "embed", "iframe":
        case a
        of "left": st.floatSide = 1
        of "right": st.floatSide = 2
        of "middle", "absmiddle", "center": st.valign = vaMiddle
        of "top", "texttop": st.valign = vaTop
        of "bottom", "absbottom", "baseline": st.valign = vaBaseline
        else: discard
      of "hr":
        if a == "left": st.margin[1] = AutoLen
        elif a == "right": st.margin[3] = AutoLen
        else:
          st.margin[1] = AutoLen
          st.margin[3] = AutoLen
      of "caption": st.align = alignOf(a)
      else:
        if t in ["div", "p", "h1", "h2", "h3", "h4", "h5", "h6", "td", "th", "tr",
                 "tbody", "thead", "tfoot", "center", "section", "header", "footer"]:
          let al = alignOf(a)
          if a == "justify": st.align = taStart
          elif al != taStart:
            st.align = al
            st.alignBlocks = true
    of "valign":
      st.valign = case v.strip.toLowerAscii
        of "top": vaTop
        of "bottom": vaBottom
        of "middle", "center": vaMiddle
        of "baseline": vaBaseline
        else: st.valign
    of "cellspacing":
      if t == "table":
        let l = attrLen(v)
        if l.k == lkPx: st.spacing = l.v
    of "border":
      if t == "table":
        let l = attrLen(v)
        if l.k == lkPx:
          for s in 0 .. 3:
            st.bw[s] = l.v
            st.bs[s] = if l.v > 0: 4 else: 0
            st.bc[s] = RoleRule
      elif t == "img":
        let l = attrLen(v)
        if l.k == lkPx:
          for s in 0 .. 3:
            st.bw[s] = l.v
            st.bs[s] = if l.v > 0: 1 else: 0
    of "nowrap":
      if t in ["td", "th"]: st.white = wsNowrap
    of "hspace":
      if t == "img":
        let l = attrLen(v)
        if l.k == lkPx:
          st.margin[1] = l
          st.margin[3] = l
    of "vspace":
      if t == "img":
        let l = attrLen(v)
        if l.k == lkPx:
          st.margin[0] = l
          st.margin[2] = l
    of "dir":
      case v.strip.toLowerAscii
      of "rtl": st.dir = dirRtl
      of "ltr": st.dir = dirLtr
      else: discard
    of "hidden":
      st.display = dsNone
    of "type":
      if t in ["ul", "ol", "li"]:
        st.listStyle = case v.strip
          of "1": lsDecimal
          of "a": lsLowerAlpha
          of "A": lsUpperAlpha
          of "i": lsLowerRoman
          of "I": lsUpperRoman
          of "disc": lsDisc
          of "circle": lsCircle
          of "square": lsSquare
          of "none": lsNone
          else: st.listStyle
    else: discard
  if t == "a" and st.color == RoleLink and parent.linkColor != 0: st.color = parent.linkColor

proc lowSaturation(c: uint32): bool =
  let r = int((c shr 16) and 255)
  let g = int((c shr 8) and 255)
  let b = int(c and 255)
  max(r, max(g, b)) - min(r, min(g, b)) < 40

proc finish(n: HNode; st: var CStyle; msoHide: bool) =
  ## What follows from the rest: borders of no style, hidden elements,
  ## quote bars in the colors of their depth.
  for k in 0 .. 3:
    if st.bs[k] == 0: st.bw[k] = 0
    if st.bw[k] > 0 and st.bw[k] < 1: st.bw[k] = 1
    st.bw[k] = min(st.bw[k], 200)
  if st.display == dsNone: st.hidden = true
  let zeroH = (st.maxH.k == lkPx and st.maxH.v <= 0.5) or
              (st.height.k == lkPx and st.height.v <= 0.5 and n.tag notin ["td", "th", "tr", "hr", "img"])
  let zeroW = (st.maxW.k == lkPx and st.maxW.v <= 0.5) or
              (st.width.k == lkPx and st.width.v <= 0.5 and n.tag notin ["td", "th", "img", "col"])
  if st.overflowHidden and (zeroH or zeroW): st.hidden = true
  if msoHide and (st.fontPx <= 2 or (st.lhKind == lhPx and st.lhVal <= 2) or zeroH or zeroW or
                  st.overflowHidden or st.invisible):
    st.hidden = true
  # a mail's quote bar: in the color of its depth when the page's is a gray
  if n.tag == "blockquote":
    for side in [1, 3]:
      if st.bw[side] > 0 and not isRole(st.bc[side]) and
         (st.bc[side] == 0 or lowSaturation(st.bc[side])):
        st.bc[side] = RoleQuote + uint32(min(3, st.quoteDepth - 1))
        st.bw[side] = max(st.bw[side], 2)

var declBuf: seq[ptr Decl]
var ruleBuf: seq[tuple[spec, order, blk: int]]

proc cascade*(n: HNode; parent: CStyle; sh: StyleSheet): CStyle =
  ## The computed style of element `n`: inherited, the tag's own, its old
  ## attributes, the page's rules by specificity, its `style` attribute,
  ## then the `!important` ones.
  result = inheritFrom(parent)
  # (the direction first: lists and quotes indent at their start)
  let dirAttr = n.attr("dir").toLowerAscii
  if dirAttr == "rtl": result.dir = dirRtl
  elif dirAttr == "ltr": result.dir = dirLtr
  tagDefaults(n, result, parent)
  presentational(n, result, parent)
  sh.matching(n, ruleBuf)
  declBuf.setLen(0)
  let style = n.attr("style")
  let inl = if style.len > 0: inlineDecls(style) else: nil
  for imp in [false, true]:
    for r in ruleBuf:
      let blk = unsafeAddr sh.blocks[r.blk]
      for k in 0 ..< blk[].len:
        if blk[][k].important == imp: declBuf.add unsafeAddr blk[][k]
    if inl != nil:
      for k in 0 ..< inl[].len:
        if inl[][k].important == imp: declBuf.add unsafeAddr inl[][k]
  if declBuf.len == 0:
    finish(n, result, false)
    return
  # font-size first: the other lengths in em follow it
  for d in declBuf:
    if d.prop == pFontSize:
      let f = fontSizeOf(d.val, parent.fontPx)
      if f >= 0: result.fontPx = float32(min(f, 400))
    elif d.prop == pFont:
      for t in splitValue(d.val):
        let sz = t.split('/')[0]
        if sz.len > 0 and (sz[0] in {'0'..'9', '.'} or sz in fontKeywords):
          let f = fontSizeOf(sz, parent.fontPx)
          if f >= 0:
            result.fontPx = float32(min(f, 400))
            break
    elif d.prop == pDirection:
      if d.val == "rtl": result.dir = dirRtl
      elif d.val == "ltr": result.dir = dirLtr
  var msoHide = false
  for d in declBuf:
    if d.prop == pMsoHide: msoHide = d.val == "all"
    else: applyDecl(result, d[], parent)
  finish(n, result, msoHide)

proc sheetOf*(doc: HtmlDoc): StyleSheet =
  ## The rules of all the page's style sheets.
  for s in doc.styles: result.addSheet(s)
