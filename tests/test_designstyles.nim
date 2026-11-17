## Tests of Styles (retroui/designstyles): a palette and a font pair on a whole design, the
## colors by their lightness, big type in the heading font; font pairs of the fonts there are.

import retroui/[photo, photoshapes, textengine, designstyles]

block styles:
  doAssert builtInStyles().len >= 12
  let d = newDoc(400, 300, 0xFFFFFFFF'u32)
  discard d.addShapeLayer(ShapeData(path: rectPath(0, 0, 400, 60), fill: solidPaint(0xFF101010'u32)), "band")
  discard d.addShapeLayer(ShapeData(path: rectPath(20, 100, 200, 200), fill: solidPaint(0xFFAAAAAA'u32)), "box")
  var big = defaultStyle()
  big.size = 40
  big.color = 0xFF333333'u32
  discard d.addTextLayer(newText("Grand Opening", big, 20, 50))
  var small = defaultStyle()
  small.size = 14
  small.color = 0xFF555555'u32
  discard d.addTextLayer(newText("Friday at nine", small, 20, 260))
  discard d.addTextLayer(newText("Saturday too", small, 20, 280))
  let frame = d.addShapeLayer(ShapeData(path: rectPath(220, 100, 380, 200), fill: solidPaint(0xFFC8C8C8'u32)),
                              "Frame 1")
  frame.attrs.placeholder = 1
  doAssert d.headingSize > 14 and d.headingSize < 40
  let s = DesignStyle(name: "Test", colors: @[0xFF000080'u32, 0xFF008000'u32, 0xFFFFFF00'u32, 0xFFFFFFFF'u32],
                      heading: "FreeSerif", body: "FreeMono")
  let n = d.applyStyle(s)
  doAssert n >= 5
  doAssert d.layers[1].shape.fill.color == 0xFF000080'u32         # (the darkest: the darkest)
  doAssert d.layers[2].shape.fill.color != 0xFFAAAAAA'u32
  doAssert d.layers[3].text.spans[0].style.family == "FreeSerif"
  doAssert d.layers[4].text.spans[0].style.family == "FreeMono"
  doAssert d.layers[0].px[0] == 0xFFFFFFFF'u32                     # (the background: the lightest)
  doAssert frame.shape.fill.color == 0xFFC8C8C8'u32                # (a photo goes there: left as it is)
  # the colors kept, only the fonts
  let before = d.layers[1].shape.fill.color
  discard d.applyStyle(builtInStyles()[0], colors = false)
  doAssert d.layers[1].shape.fill.color == before

block pairs:
  let p = fontPairs(["Lato", "Playfair Display", "FreeSans", "FreeSerif", "Arial"])
  doAssert p[0] == ("Playfair Display", "Lato")
  doAssert ("FreeSerif", "FreeSans") in p
  doAssert fontPairs([]) == @[("FreeSerif", "FreeSans")]
  doAssert paletteMap([0xFF000000'u32, 0xFFFFFFFF'u32], [0xFF0000FF'u32, 0xFFFF0000'u32]) ==
           @[0xFF0000FF'u32, 0xFFFF0000'u32]

echo "design styles ok"
