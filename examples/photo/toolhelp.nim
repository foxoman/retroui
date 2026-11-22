## Retro Atelier's tool help cards: resting on a tool in the toolbox shows a card -- what it
## does, its keys --, and F1 while it is up opens the tool's help (Affinity's help cards, with
## Learn More). Included by photo.nim.

const toolHelp = [
  ("Move Tool", "Moves the layer, the pixels selected or the objects picked; drag a handle to scale them.",
   "Shift: straight lines and in proportion. Alt+drag: a copy. Ctrl+click: the layer under the pointer."),
  ("Artboard Tool", "Draws an artboard, or moves and sizes the one picked.", "Shift: square. Alt+drag: a copy."),
  ("Gap Tool", "Changes the space between objects: drag the gap and the objects beside it follow.",
   "Shift: only the nearer object moves. Ctrl: the gap's size."),
  ("Content Collector Tool", "Collects objects to place again elsewhere, on another page.", ""),
  ("Content Placer Tool", "Places what the Content Collector collected, one at a time.", "Arrows: the next or the one before."),
  ("Rectangular Marquee Tool", "Selects a rectangle.",
   "Shift: square, or add to the selection. Alt: from the middle, or take away. Shift+Alt: what both have."),
  ("Elliptical Marquee Tool", "Selects an ellipse.",
   "Shift: a circle, or add. Alt: from the middle, or take away."),
  ("Single Row Marquee Tool", "Selects one row of pixels across the picture.", "Shift: add a row."),
  ("Single Column Marquee Tool", "Selects one column of pixels down the picture.", "Shift: add a column."),
  ("Lasso Tool", "Selects what is drawn round freehand.", "Alt: straight sides while held. Shift: add; Alt: take away."),
  ("Polygonal Lasso Tool", "Selects a shape of straight sides: click each corner, double-click to end.",
   "Shift: at 45° steps. Backspace: the last corner back. Esc: give up."),
  ("Magnetic Lasso Tool", "Selects along the edges it finds as the pointer goes round an object.",
   "Click: a point of your own. Backspace: the last point back."),
  ("Object Selection Tool", "Selects the object inside the box drawn round it.", "Shift: add; Alt: take away."),
  ("Quick Selection Tool", "Paints a selection that grows to the edges it finds.", "Alt: take away. [ and ]: its size."),
  ("Selection Brush Tool", "Paints the selection itself, as a mask is painted.", "Alt: take away. [ and ]: its size."),
  ("Magic Wand Tool", "Selects the pixels of the color clicked (as close as its Tolerance).",
   "Shift: add; Alt: take away. Contiguous off: the color everywhere."),
  ("Crop Tool", "Crops the picture to the box drawn; outside the box, drag to turn it.",
   "Shift: in proportion. Enter: crop. Esc: give up."),
  ("Perspective Crop Tool", "Crops a quadrilateral and makes it a rectangle (a page photographed at an angle).", "Enter: crop."),
  ("Slice Tool", "Cuts the picture into slices for the web.", "Shift: square."),
  ("Slice Select Tool", "Picks a slice to move, size or set its options.", "Double-click: its options."),
  ("Rectangle Frame Tool", "Draws a frame for a picture or text in a layout.", "Shift: square."),
  ("Ellipse Frame Tool", "Draws an elliptical frame.", "Shift: a circle."),
  ("Polygon Frame Tool", "Draws a polygonal frame.", "Arrows while drawing: more or fewer sides."),
  ("Eyedropper Tool", "Takes the color clicked as the foreground color.", "Alt: as the background color."),
  ("Color Sampler Tool", "Puts up to ten points whose colors Info shows.", "Alt+click: a point taken away."),
  ("Ruler Tool", "Measures a distance and an angle; Straighten Layer levels the line drawn.", "Shift: at 45° steps."),
  ("Note Tool", "Puts a note on the picture.", ""),
  ("Count Tool", "Counts what is clicked, numbered.", "Alt+click: a number taken away."),
  ("Dimension Tool", "Draws a dimension line that measures between two points.", "Shift: straight."),
  ("Spot Healing Brush Tool", "Paints over a blemish; the pixels round it fill it in.", "[ and ]: its size."),
  ("Remove Tool", "Paints over what should not be there; it is taken away, what was behind it made again.",
   "[ and ]: its size."),
  ("Healing Brush Tool", "Paints with pixels taken from elsewhere, blended into their place.",
   "Alt+click: where it takes from."),
  ("Patch Tool", "Draw round an area, then drag it to where its pixels should come from.", ""),
  ("Content-Aware Move Tool", "Moves what is selected; where it was is filled from round it.", ""),
  ("Red Eye Tool", "Takes the red out of an eye clicked.", ""),
  ("Brush Tool", "Paints with the foreground color and the brush chosen. On type or a shape the paint goes " &
   "on a new pixel layer.", "Shift+click: a straight line. Alt: the eyedropper. [ and ]: its size; Shift+[ ]: hardness."),
  ("Pencil Tool", "Paints hard-edged pixels.", "Shift+click: a straight line. Alt: the eyedropper."),
  ("Color Replacement Tool", "Paints over a color with the foreground color, keeping light and shade.", ""),
  ("Mixer Brush Tool", "Paints mixing its color with the colors already there, as wet paint.", "Alt: load the brush."),
  ("Adjustment Brush Tool", "Paints an adjustment (brightness, saturation...) where it goes.", ""),
  ("Mask Brush Tool", "Paints the layer's mask: black hides the layer, white shows it. A mask is made if " &
   "it has none; the pixels are not touched.", "Alt: the other color. [ and ]: its size."),
  ("Tone Brush Tool", "Lightens or darkens where it paints, on a Tone layer of its own: dodge and burn that " &
   "can be changed or taken away later.", "Alt: the other way. A low opacity builds up gently."),
  ("Airbrush Tool", "Sprays paint that builds up while the button is held.", "[ and ]: its size."),
  ("Clone Stamp Tool", "Paints a copy of the pixels taken from elsewhere.", "Alt+click: where it takes from."),
  ("Pattern Stamp Tool", "Paints with the pattern chosen.", ""),
  ("History Brush Tool", "Paints back the picture as it was at the History state marked.", ""),
  ("Art History Brush Tool", "Paints the marked History state again in loose strokes.", ""),
  ("Eraser Tool", "Erases to transparency (to the background color on the Background).",
   "Alt: erase to the History state."),
  ("Background Eraser Tool", "Erases the color under its middle as it goes, keeping the edges of the rest.", ""),
  ("Magic Eraser Tool", "Erases the pixels of the color clicked.", ""),
  ("Eraser Tool (Shapes)", "Erases parts of vector shapes.", "Alt: a box of what to erase."),
  ("Scissors Tool", "Cuts a path at the point clicked.", ""),
  ("Knife Tool", "Cuts shapes along the line drawn.", "Alt: a straight cut."),
  ("Gradient Tool", "Fills with a gradient along the line drawn.", "Shift: at 45° steps."),
  ("Paint Bucket Tool", "Fills the area of one color clicked with the foreground color.", "Shift: the background color."),
  ("Blur Tool", "Softens where it paints.", ""),
  ("Sharpen Tool", "Sharpens where it paints.", ""),
  ("Smudge Tool", "Smears the pixels as a finger in wet paint.", ""),
  ("Dodge Tool", "Lightens where it paints.", "Alt: darkens (the Burn Tool)."),
  ("Burn Tool", "Darkens where it paints.", "Alt: lightens (the Dodge Tool)."),
  ("Sponge Tool", "Takes color out where it paints, or adds it.", ""),
  ("Pen Tool", "Draws a path point by point: click for corners, drag for curves.",
   "Shift: at 45°. Alt on a point: a corner. Ctrl: the Direct Selection Tool."),
  ("Freeform Pen Tool", "Draws a path freehand.", "Alt: straight segments."),
  ("Curvature Pen Tool", "Draws smooth curves through the points clicked; double-click a point to make it a corner.", ""),
  ("Content-Aware Tracing Tool", "Draws a path along the edges found under the pointer.", ""),
  ("Add Anchor Point Tool", "Adds a point to a path where clicked.", ""),
  ("Delete Anchor Point Tool", "Takes a point off a path.", ""),
  ("Convert Point Tool", "Makes a smooth point a corner, or a corner smooth (drag).", ""),
  ("Horizontal Type Tool", "Click to type a line, or drag a box for a paragraph.", "Esc or Ctrl+Enter: done."),
  ("Vertical Type Tool", "Types in columns, top to bottom.", ""),
  ("Vertical Type Mask Tool", "Types a selection, top to bottom.", ""),
  ("Horizontal Type Mask Tool", "Types a selection in the letters' shape.", ""),
  ("Path Selection Tool", "Picks whole paths and shapes to move.", "Shift: add. Alt+drag: a copy."),
  ("Direct Selection Tool", "Picks points and handles of a path to move.", "Shift: add. Alt: the whole path."),
  ("Group Selection Tool", "Picks an object in a group, then its group with each click.", ""),
  ("Magic Wand Tool (Shapes)", "Picks the shapes with the same fill, stroke or opacity as the one clicked.", ""),
  ("Lasso Tool (Points)", "Picks the points of paths drawn round.", ""),
  ("Paintbrush Tool (Vector)", "Draws vector strokes freehand, with the brush chosen.", ""),
  ("Blob Brush Tool", "Paints filled vector shapes that merge as they touch.", ""),
  ("Smooth Tool", "Smooths a path where it is dragged along.", ""),
  ("Path Eraser Tool", "Erases parts of a path where dragged.", ""),
  ("Join Tool", "Joins the ends of paths dragged over.", ""),
  ("Width Tool", "Drag a stroke's edge to make it wider or narrower there.", "Alt: one side only."),
  ("Mesh Tool", "Adds points to a gradient mesh; give each its color.", ""),
  ("Perspective Selection Tool", "Moves objects on the perspective grid's planes.", ""),
  ("Shape Builder Tool", "Drag across overlapping shapes to merge them.", "Alt: take a part away."),
  ("Rectangle Tool", "Draws a rectangle (a shape layer, a path or pixels: the options bar).",
   "Shift: square. Alt: from the middle. Click: its size typed."),
  ("Rounded Rectangle Tool", "Draws a rectangle with round corners.", "Shift: square. Alt: from the middle."),
  ("Ellipse Tool", "Draws an ellipse.", "Shift: a circle. Alt: from the middle."),
  ("Triangle Tool", "Draws a triangle.", "Shift: equal sides."),
  ("Polygon Tool", "Draws a polygon of the sides chosen.", "Arrows while drawing: more or fewer sides."),
  ("Line Tool", "Draws a line, with arrowheads if asked.", "Shift: at 45°."),
  ("Star Tool", "Draws a star.", "Arrows while drawing: more or fewer points."),
  ("Spiral Tool", "Draws a spiral.", ""),
  ("Arc Tool", "Draws an arc.", ""),
  ("Rectangular Grid Tool", "Draws a grid of lines.", "Arrows while drawing: more or fewer rows and columns."),
  ("Polar Grid Tool", "Draws circles and spokes.", ""),
  ("Flare Tool", "Draws a lens flare as shapes.", ""),
  ("Custom Shape Tool", "Draws the shape chosen from Shapes.", "Shift: in proportion."),
  ("Hand Tool", "Drags the picture to see another part of it.", "Space: the Hand Tool for a while. Double-click: fit."),
  ("Rotate View Tool", "Turns the view (the picture is not changed).", "Shift: at 15° steps. Double-click: straight."),
  ("Zoom Tool", "Click to zoom in, or drag round what to see.", "Alt: zoom out. Double-click: 100%.")]

proc toolCard(name, key: string): string =
  ## (the help card of a tool: its name and key, what it does, its keys, F1 for more)
  result = tr(name) & (if key.len > 0: " (" & key & ")" else: "")
  for (n, does, keys) in toolHelp:
    if n == name:
      result.add "\n" & tr(does)
      if keys.len > 0: result.add "\n" & tr(keys)
      result.add "\n" & tr("F1: learn more")
      return

var toolHelpDlg: tuple[open: bool; name: string]

proc toolHelpNow(): bool =
  ## F1 while a tool's card is up: that tool's help (true: taken).
  let tip = tipShown()
  if tip.len == 0 or "\n" notin tip or not keyHit(KeyF1): return false
  let name = tip.split('\n')[0].split(" (")[0]
  for (n, _, _) in toolHelp:
    if tr(n) == name:
      toolHelpDlg = (true, n)
      ui.keyUsed = true
      return true

proc toolHelpDialog() =
  if not toolHelpDlg.open: return
  dialog(toolHelpDlg.open, toolHelpDlg.name, 460):
    for (n, does, keys) in toolHelp:
      if n != toolHelpDlg.name: continue
      paragraph(does)
      if keys.len > 0:
        group("Keys"):
          paragraph(keys)
      paragraph("Its settings are in the options bar above the picture (Window > Options); double-click " &
                "the tool for them.", color = ui.theme.gray)
    row:
      spring()
      if button("Help Contents", w = dp(110)):
        toolHelpDlg.open = false
        runCommand("Contents")
      if button("Close", isDefault = true, w = dp(80)): toolHelpDlg.open = false
