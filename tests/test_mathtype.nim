## Tests of equations in type (retroui/mathtype): TeX's math set -- scripts up and down,
## fractions over their bar, roots, big operators with limits, fences as tall as what they
## hold, Greek and operators -- and its outlines.

import retroui/mathtype

proc glyphOf(m: MathSet; cp: int): MathGlyph =
  for g in m.glyphs:
    if g.cp == cp: return g
  doAssert false, "no " & $cp

block scriptsAndItalic:
  let m = setMath("x^2 + y_1", size = 40)
  doAssert m.error == "", m.error
  let x = m.glyphOf(ord('x'))
  let two = m.glyphOf(ord('2'))
  let one = m.glyphOf(ord('1'))
  doAssert x.italic and not two.italic                       # (variables in italic, numbers upright)
  doAssert two.y < x.y - 10 and two.size < x.size            # (up, smaller)
  doAssert one.y > x.y + 4                                    # (down)
  doAssert m.glyphOf(ord('+')).x > two.x + 5                  # (room round the plus)
  doAssert m.mathPolys.len >= 5

block fractionAndRoot:
  let f = setMath("\\frac{a+b}{2}", size = 40)
  doAssert f.error == ""
  let a = f.glyphOf(ord('a'))
  let two = f.glyphOf(ord('2'))
  doAssert a.y < two.y - 25                                   # (the numerator over the denominator)
  doAssert f.polys.len == 1                                   # (its bar)
  let plain = setMath("a", size = 40)
  doAssert f.h > plain.h * 1.6
  let r = setMath("\\sqrt{b^2-4ac}", size = 40)
  doAssert r.error == "" and r.polys.len == 2                 # (the sign, the line over)
  doAssert r.glyphOf(0x2212).x > r.glyphOf(ord('b')).x        # (a minus sign, not a hyphen)
  let cube = setMath("\\sqrt[3]{x}", size = 40)
  doAssert cube.glyphOf(ord('3')).size < 30

block operatorsAndFences:
  let s = setMath("\\sum_{i=1}^{n} i^2", size = 40)
  doAssert s.error == ""
  let sigma = s.glyphOf(0x2211)
  let n = s.glyphOf(ord('n'))
  doAssert sigma.size > 50 and n.y < sigma.y - 30             # (big, its limit over it)
  let i1 = s.glyphOf(ord('1'))
  doAssert abs((i1.x + 8) - (sigma.x + 20)) < 25              # (under its middle)
  let lim = setMath("\\lim_{n \\to \\infty} \\frac{1}{n} = 0", size = 30)
  doAssert lim.error == "", lim.error
  doAssert lim.glyphOf(0x221E).y > lim.glyphOf(ord('l')).y   # (the limit under lim)
  let g = setMath("\\alpha + \\Omega \\le \\pi", size = 30)
  doAssert g.glyphOf(0x3B1).italic and not g.glyphOf(0x3A9).italic
  let fen = setMath("\\left( \\frac{1}{2} \\right)", size = 30)
  doAssert fen.error == ""
  let paren = fen.glyphOf(ord('('))
  doAssert paren.sy > 1.3                                     # (as tall as the fraction)
  let t = setMath("\\text{if } x > 0", size = 30)
  doAssert not t.glyphOf(ord('i')).italic and t.glyphOf(ord('x')).italic

block errors:
  doAssert setMath("\\frac{a}{b", size = 30).error.len > 0
  doAssert setMath("\\nosuch x", size = 30).error.len > 0
  doAssert setMath("x}", size = 30).error.len > 0
  doAssert setMath("", size = 30).glyphs.len == 0

echo "math type ok"
