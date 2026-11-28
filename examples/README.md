# The examples

Every program in this folder is made with Retro Nim UI, from a five-line
form to full apps. Each one builds with one command from the repository's
folder (Nim 2 and a C compiler: the main README's
[Install](../README.md#install)):

```sh
nim c -r -d:release examples/NAME.nim
```

Most have a `nimble` task too (`nimble photo`, `nimble board`...), and the
apps build for Android with `retroapk examples/NAME.nim` (or `nimble
appapk` with `RETRO_APP=NAME`). Read them in this order to learn the kit:
hello, notepad, ledger, charts, invoice, then the apps.

| Example | What it is |
|---|---|
| [hello](#hello) | the first app: a name, a button |
| [gallery](#control-gallery) | every control, page by page |
| [notepad](#notepad) | the Notepad of Windows 3.1 |
| [ledger](#ledger) | a small business app: grids, forms, charts, CSV |
| [charts](#chart-viewer) | a CSV file as a chart |
| [invoice](#invoice) | an HTML template made into PDF pages |
| [native](#native) | the system's own APIs, called from Nim |
| [filemanager](#retro-files) | Retro Files, a file manager |
| [photo](#retro-photo) | Retro Atelier: pictures, drawings and pages |
| [magazine](#the-magazine) | three magazine pages made with Retro Atelier's engine |
| [retroboard](#retro-board) | Retro Board, a whiteboard |
| [mail](#retro-mail) | Retro Mail, for Microsoft 365, Outlook.com, Gmail, IMAP, POP3, JMAP and Exchange |
| [communicator](#retro-communicator) | Retro Communicator, chat on XMPP |
| [taskman](#retro-task-manager) | Retro Task Manager, what the computer is doing |
| [hrbook](#hr-book) | HR Book, a private book of a hotel group's staff |
| [sevenguis](#7guis) | the seven tasks of the 7GUIs benchmark, a tab each |
| [navigator](#retro-navigator) | Retro Navigator, a web browser in the manner of 1995's |
| [retrodns](#retro-dns) | Retro DNS, a DNS changer for phones and computers |
| [podcast](#retro-podcast) | Retro Podcast, a podcast player for every system and the web |
| [music](#retro-music) | Retro Music: your own music, YouTube Music, radio, Audius, the Internet Archive, your server and Spotify in one player |
| [tasks](#retro-tasks) | Retro Tasks, a whole phone app: tasks and notes ([lesson 17](../tutorials/17-whole-app/) builds it) |
| [grow](#grow) | Grow, a savings goal planner for phones, its years as 3D bars |
| [bmi](#bmi-studio) | BMI Studio, a window with a look of its own: the example of changing controls and making new ones |

The pictures of hello, the gallery (and its Forms & Code page), charts,
native, HR Book, the magazine, 7GUIs, Retro Navigator, Retro DNS, Retro
Podcast, Grow and BMI Studio are made by `sh tools/exampleshots.sh`;
the others are the main README's.

## Hello

![Hello: a name and two buttons](../docs/examples/hello.png)

`hello.nim` is the whole idea of the kit in sixteen lines: the window is
code that runs every frame, each widget is a call bound to your own
variable (`edit name`), and a button is an `if`. No callbacks, no widget
objects.

```sh
nim c -r examples/hello.nim
```

## Control Gallery

![The control gallery's first page](../docs/examples/gallery.png)

`gallery.nim` has every control of the kit, page by page: buttons and
check boxes, text boxes and the rich text editor, lists, trees and the
data grid, menus and tool bars, dialogs, charts, the calendar and the
Gantt chart, maps, the 3D view, the canvas, windows inside the window.
Open it to see what a control looks like and how it behaves -- with the
mouse, the keyboard alone, a screen reader -- before you use it; the guide, [docs/controls.md](../docs/controls.md), has each
one's code. View, This Page's Code (Ctrl+U) shows how the page in front
is made, from the gallery's own source, in a read-only `codeEdit` with
Copy.

![The Gallery's Forms & Code page: a form made from a Nim object, and a grid of them](../docs/examples/gallery-forms.png)

Its Forms & Code page shows the kit's newer parts: a form and a grid made
from a Nim type (`formOf`, `gridOf`), the Edit menu's Undo taking back the
form's changes (`UndoStack`), the code editor, pages over pages and a list
beside its details (`pageView`, `listDetail`), a sum counted on a worker
thread (`job`), a bar that glides (`animated`), the gallery's icon in
the system's tray (`trayIcon`), Motion (`retroui/motion`): two springs,
a note that comes and goes, rows the layout moves gliding, a square
dragged and thrown to a point, bars one after another and a bouncing ball
on a fixed time step, timed steps played forward and back, a box that
flies from a list into its own -- Graph (`retroui/forcegraph`): a topic map
and a mind map that lay themselves out, their nodes dragged -- Terminal
(`retroui/terminal`): your shell in a box, a Terminal menu in the menu bar while it is
shown, a find bar, a picture shown by kitty's graphics protocol -- Surfaces: frosted glass
over bands of color, a card that floats, a picture in a circle, their blur,
shadow and corners on sliders -- and Phone (`retroui/mobile`): a navigation bar, picker
wheels for a size, a day and a time, rows of mail with Archive and Delete behind them, a
number with - and +, page dots, an action sheet, a bottom sheet of filters and a popover,
round buttons, message bubbles, clocks by day and by night, app icons with a badge and the
textures drawn in code. The Jobs page shows one slow load shared by
two views (`retroui/queries`).

```sh
nimble gallery              # or: nim c -r examples/gallery.nim
nimble galleryapk           # an Android APK
```

## Notepad

![Notepad](../docs/notepad.png)

`notepad.nim` is the Notepad of Windows 3.1: open and save files, cut,
copy and paste, the time and date (F5), find (Ctrl+F, F3), print to a
PDF (Ctrl+P), a status bar, and "Save changes?" when you close it. A
small, complete app to start from.

```sh
nimble notepad              # or: nim c -r examples/notepad.nim
```

## Ledger

![Ledger: invoices in a grid beside a tree](../docs/ledger.png)

`ledger.nim` is a small business app -- invoices, customers, stock and
reports -- to show the business controls working together: a tree, a
splitter, a sortable grid you edit in place, a form dialog with a date
picker, number fields and auto-complete, charts, CSV import and export,
saved settings. On a phone's narrow screen the tree becomes tabs.

```sh
nimble ledger               # or: nim c -r examples/ledger.nim
retroapk examples/ledger.nim --install       # Android
```

## Chart Viewer

![Chart Viewer: a CSV table as a chart](../docs/examples/charts.png)

`charts.nim` opens a CSV file (or its sample table) and draws it: pick
the kind of chart and the columns, hover it for the numbers, save it as
a PNG. All the work is the kit's `retroui/charts`; the file only lays
it out.

```sh
nimble charts               # or: nim c -r -d:release examples/charts.nim [sales.csv]
```

## Invoice

![Invoice: the pages of an invoice beside its form](../docs/invoice.png)

`invoice.nim` makes a business document from an HTML template and some
data: `renderTemplate` fills the template, `reportFromHtml` lays it out
on A4 pages, shown page by page, saved as a PDF and printed. Change the
customer, the lines or the VAT at the left and the pages follow.

```sh
nimble invoice              # or: nim c -r -d:release examples/invoice.nim
```

## Native

![Native: what this device is, and calls to its own APIs](../docs/examples/native.png)

`native.nim` calls the system's own APIs from Nim (`retroui/native`):
what the device is, the battery, dark mode, a beep, a buzz -- and on
each system a call made straight to it: Java on Android, Objective-C on
macOS and iOS, Win32 and COM on Windows, any C library on Linux.

```sh
nim c -r examples/native.nim
```

## Retro Files

![Retro Files: a folder in details, the tree at the left](../docs/filemanager.png)

`filemanager.nim` is Retro Files, a full file manager in the style of
the Windows 3.1 File Manager with what Explorer has today: tabs, two
panes, an address bar, a folder tree, details, tiles, icons and a list
with picture thumbnails, a preview pane, drag and drop, copy and move in the
background with "Replace or keep both?", Paste Shortcut, the trash, undo,
zip, search -- by name, or by what the files say (Tools > Find > By
Meaning, read on the device by a model of its own) --, favorites, the disks
and how full they are, and viewers for
text, pictures, PDF, Markdown, web pages, fonts, 3D models, spreadsheets,
mail, zip and tar archives and Android packages (an .apk's icon, version
and permissions; Install on Android). It runs on phones and tablets too,
and takes files shared from other apps.

```sh
nimble files                # or: nim c -r -d:release examples/filemanager.nim
nimble apk                  # an Android APK
```

## Retro Atelier

5.19: Edit > AI Connector > Pictures takes **ComfyUI on your computer** (`retroui/comfyui`): its
address on your network -- from a phone or a tablet the computer's, with ComfyUI started with
`--listen` --, Find It (its checkpoints, and LaMa when comfyui-inpaint-nodes is there) and the
checkpoint; Generative Fill, Expand and Generate Image go through it, and **Generative Remove**
(Edit) takes out what is in the selection, on a new layer masked to it, one step to undo.

![Retro Atelier: a picture, its layers and the tools](../docs/photo.png)

`photo.nim` is Retro Atelier, a studio for pictures, drawings and pages
with the look of 1994 and the tools of today's: layers and groups with
blend modes, masks and styles, Smart Objects, selections, channels and
paths, the photo tools and seventy vector tools, books and magazines laid
out, over a hundred filters and the adjustments with previews, Neural Filters, Arabic type,
panoramas, raw photos, CMYK, Lab, duotones and Multichannel images, PDF
for print, and many undos. On a phone held upright the picture fills the
screen, the tools in rows under it and the panels sliding up; two fingers
zoom. Its engine is in `retroui/photo`.

New text is in **Dastkhat** (Arabic, Persian and Latin, nine weights,
carried in it: `retroui/dastkhat`); Preferences > Type > Your Font Folders
adds a folder of your own fonts on any system (`retroui/fontfolders`), and
Type > Get Google Fonts every family of Google Fonts, the Arabic ones
first. A Photoshop document says as it opens what it kept to change, what
became pixels and which of its fonts this device has not. Closing a
document with changes not saved asks, saves -- Save As waited for -- and
closes, one step after another (`retroui/flows`).

**The Assistant** (Window > Assistant, or Edit > Ask AI) is a
conversation with an AI service of your own (Edit > AI Connector: a local
Ollama or LM Studio, or a service online) that does what you ask with
Retro Atelier's tools -- type and shapes added, layers set, a selection
made, any menu command run -- asking before each change, and one step to
undo. **Generate Image**, **Generative Fill** (the selection made again as
you describe it, or filled from what is round it to take something away)
and **Generative Expand** (the canvas grown, what is new made to carry the
picture on) go through your image service, each on a new layer. The
service can be **this device's own model** (Edit > Models on This Device
downloads one; Edit > AI Connector > This device): the Assistant then
works offline and sends nothing anywhere. **Type > Shorten to Fit (AI)**
makes an overset box's text as short as fits. **Models trained for
pictures** come the same way: with U-2-Net on the device Select Subject
and Remove Background use it, with Depth Anything Depth Blur, Lens Blur
and Relight see the photo's own depth, and **Type > Text in Picture**
reads the text in a photo or a scan (English, Chinese, Arabic) -- to copy,
or added as type where it was.

**What today's photo, drawing and layout programs have** (5.16): **53
drawing tools** more -- Rotate, Reflect, Scale and Shear round a reference
point, Reshape, Free Transform, Puppet Warp; the liquify brushes (Warp,
Twirl, Pucker, Bloat, Scallop, Crystallize, Wrinkle), Mesh Warp and
Deform (bones); Blend; Live Paint Bucket and Selection; the eight Symbol
tools; nine Graph tools; Shaper (a rough shape drawn becomes a neat one);
Print Tiling, Page, Gradient Feather, Color Theme, Corner, Point
Transform, Contour, Vector Crop, Transparency, Fill, Area; Touch Type,
Area Type, Type on a Path and their vertical ones -- and the **Median
Brush**. Filter > **Shake Reduction** (the shake found by itself),
Adaptive Wide Angle, Bilateral Blur, Multi Band Sharpen, Texture Detail,
Ambient Occlusion, Glitch, Remove Background Gradient, Render > Flame,
Tree and Picture Frame; **Split Toning** and **Color Grading** adjustment
layers, Channel Inversion, Mixed Light Correction, Tone Compression,
Tone Stretch, **SDR to HDR**; Layer Mask > From Luminosity Range, From
Hue Range, Compound Mask. Path Operations: compound paths, anchor points
added and removed, Divide Objects Below, Split Into Grid, Clean Up,
Objects on Path, Pixel Perfect, Soft Mix, Object Mosaic, Trim Marks,
Step and Repeat, Convert Shape, perceptual gradients, Hatch Fill, the
artboards'; ten more live shapes. Type: letters turned one by one, **Type
on a Path's effects** (Rainbow, Skew, 3D Ribbon, Stair Step, Gravity),
Change Case, Smart Punctuation, Fit Headline, Auto Style, Quick Apply,
Sidenotes, Dynamic Text. The layout program's Create Guides, Adjust
Layout, **Alternate Layouts**, Insert HTML, Basic and Directional
Feather, Clipping Path, **Multi-State Objects**, Content-Aware Fit,
Stroke Styles, Flattener Preview, Articles, Window > **Accessibility
Check**, Merge Document and snippets. Files and photos: the
**Measurement Log**, Define Custom Shape, Transform Selection, Copy CSS
and SVG, Layer Based Slices, Manage Missing Fonts, Conditional Mode
Change, the scripts that tidy layers, Layer Comps to Files, Artboards to
PDF, **Color Lookup Tables** (.cube), Render Video, **Zoomify**, Save for
Web, Content Credentials, Generate > **Image Assets**, **Version
History**, Record Timelapse, the Script Events Manager, **droplets**,
Focus Merge, the **Astrophotography Stack**, 360 views edited flat and
put back, Decompose Layers, Layer to 3D, Select > People. Edit >
**Generative Edits** through your own AI service: Generate Background,
Generative Upscale, Style Transfer, Camera Angle, Rotate Object,
Recompose, Remove Ambient Effect, Smart Portrait, Makeup Transfer,
Landscape Mixer, Generative Recolor, Text to Pattern, Generative Shape
Fill, Rewrite, Turntable. All of it in Arabic too.

**From the Affinity apps** (5.15): Window > Workspace keeps **studios**
of your own (the panels, the toolbar's tools, the options bar) and
exports them to another computer; resting on a tool shows **a card** of
what it does and its keys (F1: its help); a brush stroke on type or a
shape goes on **a new pixel layer**; the Brush tool's **Mask Brush**
paints the layer's mask and its **Tone Brush** dodges and burns on a Tone
layer that can be taken away; **Hue Curves**; **live blends** whose
steps follow their ends; **Symbols** (Layer > Symbols: change one
instance and the others change the same); **Constraints** in Properties
for what is on an artboard, the Artboard tool sizing a board by its
handles; **Smooth Curvature (G2)**; a **Diffusion** freeform gradient;
Filter > Render > **Procedural Texture**; an **isometric** grid. Type >
**Fill with Placeholder Text** fills a box with Lorem Ipsum, Arabic, the
two in turn or your own words -- so many paragraphs, or as many as fill
it.

**Two more looks** (5.17.3): Preferences > Appearance > Look has Matte --
flat and sharp, a clear blue -- and Gloss -- glossy buttons, title and tool
bars lit from above, menus that open as popover lists, its blue parts in
the hue of the scheme you pick -- beside Classic and Glass, each with a
light and a dark scheme.

**Layout > Booklet** (5.17.3): a booklet's format (A5 or B5 saddle
stitch, an A4 sheet: New Booklet makes one), its grid in millimeters
(columns, gutter, the four margins; back to the format's values), a folio
and a running head where you say -- on the outside, the right of odd pages
and the left of even ones; not on the cover, the blank pages and the back
cover --, and its pages seen one at a time, in spreads, or on the
printer's sheets as they fold.

**Artboards as the drawing program has them** (5.17.2): pages of the
canvas, not layers -- the artwork lies anywhere and goes with the
artboard it is on. With the **Artboard tool** (in the Move tool's place,
V) drag a box where there is none for a new one; click one to pick it,
drag it to move it with its artwork (Move/Copy Artwork with Artboard in
the options bar), Alt+drag it for a copy with its artwork, drag its
eight handles to size it (Shift: in proportion; Alt: from its middle),
double-click it for **Artboard Options** (name, preset, size, place,
orientation, a center mark, cross hairs, video safe areas, its paper:
white, black, none or a color). The canvas grows round them as they are
made and moved, see-through round them as a pasteboard. The options bar
has a preset (Letter, A4, Phone, Web...), Portrait and Landscape, New,
Delete, the name, X, Y, W and H, Rearrange All and Export; **Window >
Artboards** lists them in their order (a click fits one in the window;
New, Duplicate, Delete, Move Up and Down, Delete Empty Artboards); Object
> Artboards has Convert to Artboards, Rearrange All Artboards (grid by
row or column, a row, a column, right to left, the spacing), Fit to
Artwork Bounds and Fit to Selected Art; View has Fit Artboard in Window,
Fit All in Window and Show > Artboards (Ctrl+Shift+H). File > New with
Artboards makes so many; Artboards to Files, Artboards to PDF (a page
each, its own size, type and shapes as vectors) and Export for Screens
write what is on each over its paper. Also in 5.17.2: a chart or a map
moved, scaled and turned as one thing; **Column Rules** down every gutter
or the ones ticked (solid, dashed, dotted, double, thick and thin;
tinted, offset, their gaps filled), a text box's gutter a pica when none
is given; the color picker's swatches and Color Libraries under its
field.

**Artboards as pages** (5.18.0): type on an artboard with `<#>` shows its
number and `<##>` how many there are, as on a book's pages -- numbered
from the panel's First page number, drawn again as artboards are made,
moved or deleted and as the type goes onto another one. **Facing Pages
(spreads)** (the panel, Layer > Artboards): the first alone, a right
page, then two by two, left and right; Rearrange All > Spreads lays them
so, each spread's pages touching. The **Artboards panel** has the picked
one's name, size, preset and which way round, and **Place**: at the right
or left of another, under or over it, touching (a spread) or 20 points
apart, its artwork with it; the Artboard tool's drag snaps to the others
(an edge on theirs, the gap, touching, their middles; Ctrl: free), a line
along the edges that meet. **Move Art Here** and Layer > Artboards > Move
to Artboard put the layers picked on another one, where they were on
theirs. **Page Numbers** puts a folio and a running head on each, on the
outside. **Save As > PDF** asks for artboards as pages, as spreads (each
spread one page) or the whole canvas, and which (all, this one, a range);
**File > Print** asks the same, and for a book its pages as pages or
spreads. Also in 5.18.0: an English paragraph in an Arabic text box keeps
to its column; the direction's **Auto** (each paragraph as its language
runs), which Fill with Placeholder Text sets; justified Arabic draws out a
few joins in a loose line, not almost every one; new type has Hyphenate
on; a gutter in pixels shows its size in millimeters.

**Diagrams and slides** (5.18.0): **Layout > Insert Diagram...** -- a
family tree, a dendrogram (a tree of dots), a timeline, a numbered list, a
note or a title, typed as a few lines with `|` between an item's two
languages (two spaces in: a level down; `*` highlighted, `~` dashed, `>`
its children one under another), with a preview, a theme (Parchment's
cream, ink and rust first) and each color, an Arabic and a Latin font,
Arabic first and Arabic-Indic digits. It is a group of shape and type
layers -- each box, line and word to change, sharp in a PDF -- and
**Layout > Edit Diagram...** opens it again. **File > New Carousel...**
makes slides as artboards (1080 x 1350, square, a story or wide), each
with an English and an Arabic header, a rule, a footer with both sources
and its page number in Arabic digits ("٣ / ٨"), a title page with its tree
of dots and a diagram on each slide to type over; Save As > PDF or Export
> Artboards to Files gives the slides. A document of many artboards saves
small: each layer only where it has pixels. **Type in points** (5.18.0),
as the photo program measures it: the Character and Paragraph panels, the
Type tool's bar and the dialogs show sizes, leading, shift, indents and
spacing in points at the document's resolution (12 pt: 12 pixels at 72
ppi, 67 at 400), new type starts at 12 pt; Preferences > Units & Rulers >
Type: Points, Pixels or Millimeters. In 5.18.1 the Move tool moves type, a
shape or a Smart Object whole while a selection is made, the selection left
where it is, as the photo program does.

**SVG** is one of its formats: an .svg opens as layers -- its shapes as
shape layers, its text as type you can type in (fonts, sizes, colours,
bold and italic runs, lines, text along a path, an outline, a gradient,
letters each in their place), its pictures as layers of pixels, its
groups as groups with their opacity and blending, its masks and clip
paths as layer masks, a drop shadow as the layer's Drop Shadow, a pattern
as a pattern fill, any other filter as pixels drawn the way the filter
draws -- File > New SVG Drawing starts one, and File > Save writes it
back (`retroui/svgimport`, `retroui/photosvg`). For a picture of it,
File > Export As (PNG, JPEG, WebP...); for print, File > Save as PDF,
where the shapes stay vectors and the type stays type, or File > Print;
for a program without your fonts, File > Export > SVG, Type as Outlines.
What an SVG has no word for -- a bevel, an inner shadow, an adjustment
layer, a blending mode CSS does not have -- is kept in the file for Retro
Photo, which opens it again as it was; other programs do not show it, and
the status bar says so.

**Layout** (5.0): File > New Book makes a document of pages -- single or
facing, bound on the left or on the right (Arabic), with margins and
columns. The Layout menu and the Pages panel turn, add, copy, move and
remove pages; master pages put a running head or a page number
(Layout > Page Numbers > Insert Page Number) on every page that has them;
a text box goes on onto the next page, and Autoflow adds the pages a long
text needs; Layout > Text Wrap makes text keep out of a layer -- round its
box, round its shape (its pixels, its edges, or a path you edit: Edit as
a Path), on both sides or one (a shape drawn with the Pen, at Opacity 0,
is a wrap of your own outline). Type, a shape or a placed picture dragged
past the spine goes on, on the facing page. A picture goes into a frame
with File > Place Into Frame (or a double-click on a template's frame),
other layers with Layer > Put Inside. The Gap tool (with the Move tool)
drags the space between frames -- they grow and shrink with it --, and the
Content Collector and Placer carry copies of objects to another page or
document. Layer > Live Effects > 3D and Materials extrudes, revolves or inflates a shape, lit
and shaded; the Dimension tool measures distances, angles and radii that follow
what they measure. The keys are the photo editor's (a tool's letter held for a
moment, Shift+Alt and a letter for a blend mode, Shift and a number for flow),
and Edit > Fade, Paste Outside, the Path and Spin blurs, Create Layers, Split and
Merge Channels and proofs for color blindness are there; so are Paste in Front
and in Back, Outline View, Corner Options on any shape, Release to Layers and
opacity masks; and for books, Print Booklet (saddle stitch or perfect bound,
with creep), Find Font, column rules, table stripes in a pattern and diagonal
cell lines, page color labels and Smart Text Reflow. A brush 512 pixels across or more
is painted behind its stroke: the stroke shows at once where the pen goes (drawn by
the GPU when it draws the window), the picture's pixels follow. It runs as a web page too
(`retrokit web photo.nim --memory:2048`): files dropped on it open, a big PSD in
seconds, nothing installed and nothing sent anywhere. A big PSD is held once while it
opens (5.16: a 40 MB file of five layers opens in 1.0 s at 340 MB at the most -- 2.1 s and
844 MB in 5.15 --, and keeps 46 MB less once open), which matters most in a web page, whose
memory never shrinks back. File > Export > Export for Screens writes artboards or objects at 1x, 2x, 3x...
as PNG, JPEG, WebP, SVG and PDF; DXF drawings and EPS files open as shapes.
Window > Timeline plays an animation's frames (an animated GIF,
WebP or PNG opens as them) and File > Export > Save Animation saves them. Type takes colour fonts and emoji; the layout dialogs' lengths
are in the rulers' unit. The book is one file (.rpb), and
File > Save as PDF writes all its pages, a range or its spreads, with the
type as type. Window > Workspace sets the panels and tools out for Photo,
Drawing or Layout. In Paragraph: a text box as a list, with bullets of
any shape or numbers in any style. In Character: the room between words and the tashkeel
(coloured, raised, hidden); Type > Word Shapes shows the other shapes a
font has for the word selected. Drop caps and a baseline grid (Document
Setup) set a page as a magazine is; boxes snap to a page's margins,
columns and grid. File > New Book and New Drawing (SVG) open with presets
and templates by kind. The engine is `retroui/photobook`.

**Vectors** (5.2): Image > Image Trace makes a picture shapes (presets,
a preview, Save as SVG); Filter > Sketch > Pencil Sketch draws it in
pencil; Type > Convert to Shape makes type shapes; Layer > Path
Operations > Make Blend puts the shapes between two, Shape Builder joins
and takes away where shapes overlap, Freeform Gradient puts colors at
points.

**Pages** (5.2): Type > Insert Table and Table Options (themes, header,
stripes, lines); Layout > Insert Chart and Insert Map (themes, every
part set; Edit Chart or Map); Character: a font for Arabic and one for
Latin; Layer > More Shapes (twenty that keep their settings) and Fitting
(a picture in a shape or in type); Layout > Photo Grid, Resize for,
Brand Kit, Recolor Design, Check Document, Export (PDF, JPEG or PNG,
pages or spreads, a range) and Save Book as IDML; Type > Text Effects.
`--run "Command"`, `--script file.rs` and `--list-commands` on the
command line.

**Tables as a layout program edits them** (5.13): the Type tool drags a
table's column edges (Shift: the table wider) and its rows' feet; Type >
Table inserts several rows or columns at once, deletes the table, selects
a cell, a row, a column or the table, splits a cell across or down, makes
rows or columns even and sorts the body by a column (numbers by their
value, Arabic as a dictionary has it); Table Options skips the header in
the first box and the footer in the last; Cell Options > Rows sets a
row's most height and keeps it with the next row or starts it in the next
box.

**Margins and padding** (5.13): Layout > Margins and Columns sets a page's
or a master's own margins and columns; Text Frame Options, in tabs, sets
columns of a fixed or a most width, the first baseline (cap height, x
height, leading, fixed) and Ignore Text Wrap; a frame's inset, a cell's and
a paragraph's shading and border take each side apart or all together
(the link beside them).

**Master pages' items, a page's own** (5.13): Ctrl+Shift+click on a master's
item on a page makes it that page's to change; Layout > Masters overrides
all of them, gives them back (Remove Local Overrides), detaches them or
hides them on the page, and on a master says which items its pages may
not make their own. A photo inside a frame goes across the spine with the
frame.

**Footnotes and the table of contents** (5.13): Footnotes restart their numbers
on each page, show the prefix and suffix where asked, take a reference as
big as the text, room between notes and a line set in, set off and in
dashes; Table of Contents keeps its settings by name (TOC Style), gives
each level a paragraph style's letters, puts the page number after the
entry, before it or nowhere, sorts the entries, takes text on hidden
layers, makes PDF bookmarks and replaces the table there is.

**Typesetting** (5.13): the Paragraph panel's Hyphenation (the shortest word,
the letters before and after a hyphen, hyphens in a row, the zone,
capitals, the last word, Balance Ragged Lines) and Paragraph Rules;
Justification's Auto Leading and Single Word Justification; Underline and
Strikethrough Options; OpenType's Figure Style, Positional Form and the
font's Stylistic Sets by its own names. Edit > Generate Vector draws
vector art from your words -- a subject, a scene, an icon, a pattern, in
the foreground and background colors if you like -- as shapes to change,
by your AI service or offline by a model on the device; the Assistant draws
it in the conversation too. Point text justified (Justify All)
makes its lines one width -- an Arabic title's shorter line lengthened with
kashidas as Insert Kashida lets.

**Arabic typesetting** (5.12), from Yaqout's manual: Type > Quran... --
the text downloaded once from Tanzil (or a Tanzil file opened), a sura's
ayat with their numbers in ornate brackets set into the text being typed
or as a new text box, searched as written either way, and a passage typed by hand
checked against it, the places it differs marked; Layout > Islamic
Pattern... (eight-pointed stars and crosses, six-pointed stars, octagons
with stars, a border of stars) as a shape over the page or the selection;
Type > Insert White Space, Insert Break Character, the next and previous
page numbers and Copyfit; Find/Change's "Arabic as written either way";
the Character panel's Move Tashkeel.

**Several layers at once** (5.7): picked as each kind of document's
program shows them -- a photo: one box with handles round all of them; a
drawing (SVG, AI, EPS): each object's outline in its layer's color, with
its anchor points, and one box; a page of a book: each frame's edge in its
layer's color, and one box. A box dragged with the Move tool picks the
layers it touches (from the gray round the image too, each outlined as the
box goes); Shift+click adds one and, on one picked, takes it out; on a
phone or a tablet a long press on a layer picks by taps until Done. Free
Transform and the box's handles change them all together (pixels warped,
shapes still shapes, type still type -- turned or in perspective, drawn
through its corners -- Smart Objects from what they hold; one Undo);
Delete, Duplicate, Opacity, Fill, the blend mode and the locks take them
all; Properties shows them together (W, H, X, Y, Align, Distribute).
Layer Options > Color (the drawing and layout programs' colors; a
drawing's or a layout's new group gets the next one; kept in PSD);
View > Show > Layer Edges; Hide Edges and Hide Frame Edges by the
document. File > Open on a phone starts in the folder used last (not
Recent, which lists no PSD, AI or IDML).

**Print, output and making** (5.6): View > Separations Preview (the
plates, each on or off, the ink at the pointer) and Overprint Preview;
Edit > Ink Manager and New Spot Ink (a shape's fill on a plate of its
own); Window > Attributes (overprint, nonprinting) and Layer > Object
Export Options (alt text, a decoration, a tag) for a tagged PDF; Window >
Buttons and Forms and Layout > Page Transitions for an interactive PDF;
File > Export > EPUB and Publish as Web Page; Layout > Flex Layout (a row
or a column of frames that keeps itself as one grows) and Tidy Up; Type >
Paragraph Shading and Borders, Insert Equation (TeX), Track Changes (who
typed and deleted what, accepted or rejected) and notes, Window >
Conditional Text; Select > Start Global Edit; Layer > Envelope Distort
(Warp, a mesh, the top object), Live Paint (the bucket fills where shapes
overlap), Intertwine; Window > Pattern Options; Filter > Render > Relight
(lights dragged on the image, no AI), Lighting Effects' light dragged on
the image too; Edit > Remove with Its Shadow; Image > Upscale; File >
Mockups; Window > Styles and Fonts; Layer > New > Layer by Lifting the
Subject; Layer > Make Photo Placeholder, every template's frames
placeholders (double-click: a photo in it) and ten new templates; Edit >
AI Connector and Ask AI (a service of your own, local or online, turns
words into Retro Atelier's commands, shown before they run);
Preferences: your own placeholder text, each layer's size in the Layers
panel. JPEGs open up to 1.6 times sooner and PNGs save 1.4 times sooner;
Liquify's preview is drawn by the GPU.

**What was still missing** (5.5): Paragraph's Drop Caps and Nested
Styles has Nested Line Styles; type attached to a perspective plane stays
type (Layer > Perspective > Release with Perspective lets it go); on a
phone, the phone's own spell checker; Window > Graphic Styles; Layer >
Live Effects > Stylize > Round Corners and Scribble; the Shape Builder
tool (drag across the parts of overlapping shapes, Alt+drag to take them
away); Layer > Path Operations > Replace Spine; the options bar's
Artboard Options (its name, size, place and paper); Layer > Gradient Feather; Smart
Guides for tangent and perpendicular lines; Recolor Design from another
open picture; Layer > Rename Layers by Content; Data Merge's Export a
File a Row; the Paragraph panel's Roman Hanging Punctuation and Optical
Margin Alignment; the Character panel's Language (words hyphenated in
French, German, Spanish, Italian, Portuguese and Dutch too);
Find/Change's Glyph and Object searches and its Query menu; Layout >
Masters > Master Options (Based on Master); Type > Text Variables >
Insert Date As (the Hijri date, the Arabic date); Check Document's
Arabic checks. Painting over many layers is six times sooner, the layers
mixed up to five times sooner, and idle layers are kept small.

**The three programs side by side** (5.4): Filter > Blur > Average, Box
Blur, Shape Blur, Smart Blur and Lens Blur, and the Filter Gallery's
Fresco, Neon Glow, Glass, Chalk & Charcoal, Glowing Edges and the rest;
the Light adjustment layer, Pattern Overlay, Layer > Matting, View >
Pattern Preview and Pixel Grid. The toolbar's Vector group holds the
drawing program's tools -- Group Selection, the Magic Wand and Lasso for
shapes, the Paintbrush with calligraphic and art brushes, the Blob
Brush, Smooth, Path Eraser, Join, Eraser, Scissors, Knife, Width, Arc,
the grids, Flare, Mesh, Perspective Selection; Window > Appearance gives
a shape more fills and strokes and live effects (Distort & Transform,
Warp, Repeat). The Paragraph panel sets the paragraphs the caret is in:
the composer, Justification, Keep Options, Span Columns, nested and GREP
styles; Text Frame Options balances columns, insets the text and
justifies it up and down; a paragraph style's double-click opens its
options (Next Style...); Window > Object Styles, Bookmarks and Links;
Edit > Spelling; Type > Text Variables and Hyperlinks &
Cross-References; File > Place Linked and Package.

**The layout program's ways** (5.3): Type > Insert Footnote and Insert
Endnote; Layout > Table of Contents and Index; Window > Tabs (stops on a
ruler, leaders, decimal tabs; Shift+Tab a Right Indent Tab); Type > Table
(Cell Options, rows and columns, Merge Cells; Table and Cell Styles; a
long table's header again in the next box); Paragraph > Hyphenate;
Layer > Anchor to Text; Edit > Find/Change (words or GREP patterns) and
Type > Story Editor; Layout > Data Merge. Text that does not fit its box
is overset; Type > Text Frame Options sizes a box to its text
(Auto-Size); a box picked with the Move tool shows its in and out ports --
click the out port, then another box (or where there is none), and the
text goes on there; a threaded port, then the box at the other end,
breaks it. View > Perspective Grid: the Shape tools draw on the plane
picked in its widget, Layer > Perspective > Attach to Active Plane lays a
shape or a painted layer on it. Path Operations > Apply Brush to Path
(Art, Pattern, Scatter) and Gradient Mesh; Character > Ligatures and Type
> OpenType. `--headless` runs it without a window (`--shot OUT.png`: a
picture of the window).

On Android and iOS, Open and Save As are the phone's own file picker.

```sh
nimble photo                # or: nim c -r -d:release examples/photo.nim [picture...]
nimble photoapk             # an Android APK
```

## The magazine

![Three A4 magazine pages made with Retro Atelier's engine](../docs/examples/magazine.png)

`magazine.nim` has no window: it makes three A4 magazine pages with
Retro Atelier's engine, tool by tool, as the app's tools would -- gradients,
clouds and a lens flare, shape and type layers (Arabic set right to
left), layer styles, masks, a Smart Object, adjustment layers, a Neural
Filter -- and saves them as Retro Atelier documents (each layer still
editable in the app), PNG pictures and a PDF.

```sh
nimble magazine             # build/magazine: .rpd, .png, .pdf
```

## The book

`examples/book.nim` makes a small book with the kit's layout engine alone
(`retroui/photobook`), no window: in Arabic, bound on the right, facing
pages; a title page with margins of its own and the master's items
hidden on it, its title's two lines made one width with kashidas (point
text justified); master pages with a running head, a paragraph rule
under it and the page number at the outer edge in Arabic-Indic digits; a
story in two columns that goes on through as many pages as it needs,
keeps out of a picture, round its shape, and has footnotes numbered again
on each page; a table at the end, sorted by a column of numbers; the
tashkeel of the title in a colour of its own. It writes
the book (.rpb: open it in Retro Atelier), a PDF with the type as type, and
its spreads as pictures.

```sh
nimble book                 # build/book: book.rpb, book.pdf, spread-01.png...
```

## Retro Board

![Retro Board: notes, shapes, arrows and a frame](../docs/board.png)

`retroboard.nim` is Retro Board, an endless whiteboard in the manner of
tldraw: ink with pen pressure, the highlighter and the laser pointer,
nineteen shapes with labels, arrows that hold on to shapes, text, sticky
notes, frames and pictures; select, move, turn, snap, group, align;
pages, pinch to zoom, autosave, a dark mode; PNG, SVG and PDF export;
**presenting** the frames as slides (View > Present the Frames, F5), and
pictures dropped from other programs. Zoomed out on thousands of shapes it
draws those too small to read in brief, and keeps moving. Arrange > Tidy
Up by Arrows lays out the shapes arrows join (a mind map dropped in a
heap, a diagram grown crooked) as a graph that settles -- each pushes the
others away and keeps out of their room, each arrow pulls its shapes to a
length -- and they glide there, one step to undo (`linkedLayout`,
`retroui/forcelayout`). File > Draw from Words asks an AI service of your
own -- or a model on the device, nothing sent (File > AI Connector) -- for
vector art from your words, and puts it on the board as a picture: the
kit's Generate Vector dialog (`retroui/aivector`), as Retro Atelier has it.

```sh
nimble board                # or: nim c -r -d:release examples/retroboard.nim
nimble boardapk             # an Android APK
```

## Retro Mail

![Retro Mail: All Inboxes in threads, the conversation in the preview pane](../docs/mail.png)

1.5: on a phone or a tablet in the Glass, Matte or Gloss look (`mail/ui_touch.nim`) it is a phone's
mail -- Gloss drawn as phones had it in 2012, a phone starting in Gloss: Mailboxes (All Inboxes,
each account's inbox with its unread in a capsule, Flagged, Unread; your accounts and Add Account;
Calendar, People, To Do, Notes; Settings), an account's folders, a folder's messages on white (the
unread ones' blue dot, Focused and Other, a search, pulled down: checked; Edit or a finger held:
several chosen, then Mark, Move or Trash), one message with "3 of 9" and its arrows on the bar,
its sender and who it went to as names in capsules, its toolbar -- Flag or Mark (Flag, Mark as
Unread), Move, Trash, Reply (Reply, Reply All, Forward), New Message --, writing with Cancel and
Send on the bar, To, Cc and Bcc, Subject, Insert Photo or Video, the signature; Settings in groups
as a phone's (the accounts, New Mail, Reading, Writing, Kept Safe, Appearance, More Options, About
Retro Mail), each kept as it is changed. On a tablet the
mailboxes and the list stay down the left and the message is beside them; Calendar, People, To Do
and Notes take the whole width. tests/test_mailtouch.nim
works it on a phone and a tablet and draws every page in every look.

`mail.nim` is Retro Mail, Outlook Express 4 to look at, with what the
new Outlook does: Microsoft 365, Outlook.com and Gmail signed in in the
browser (no password typed here), threads, Focused and Other, tags, pin,
snooze, offline search of everything kept, rich text writing,
signatures, send later, and the calendar, people, to do and notes beside
the mail -- and any other provider through IMAP (new mail told at once),
POP3, JMAP (Fastmail) or a company's own Exchange. Its mail is kept
encrypted on the device; who a message is from is checked (the provider's
checks, the DKIM signature verified here) and what is there to fool -- a
look-alike sender, a link that goes elsewhere than it says, tracking
pictures -- is told or taken out. The app registrations it signs in with
are made once by whoever builds it (`examples/mail/appids.nim`,
`docs/retromail.md`). View > Assistant opens a conversation with an AI
service of your own that finds and reads your mail when you ask -- by
meaning too, with an embedding model on the device -- and opens a reply or
a new message for you to read and send; Summarize and Translate use it
too. It can be this device's own model, which sends nothing anywhere.

```sh
nimble mail                 # or: nim c -r -d:release examples/mail.nim
nimble mailapk              # an Android APK
```

## Retro Communicator

![Retro Communicator: the friends list and a talk](../docs/communicator.png)

`communicator.nim` is Retro Communicator, an instant messenger in the
look of 1999 on XMPP (Jabber): the friends list with groups, who is
online and away, a window for each talk, chat rooms, away messages,
profiles with a picture, files and voice messages, OMEMO encryption, and
the history on your device and from your server's archive. An account on
any public server, made from inside the app where the server allows it;
no server of mine, no phone number. Its talks draw only the lines in
view (`visibleRows`), so a long one stays quick to type in.

```sh
nimble communicator         # or: nim c -r -d:release examples/communicator.nim
```

## Retro Task Manager

![Retro Task Manager: the processes](../docs/taskman.png)

`taskman.nim` is Retro Task Manager, what the computer is doing: every
program with its share of the processor, the memory and the disk (end
one, or it with all it started; give it another priority), graphs of the
processor, the memory, the disks and the network, the programs that
start with the system, the connections, and the last week. It reads the
system on a thread of its own and less often while nobody looks.

```sh
nimble taskman              # or: nim c -r -d:release examples/taskman.nim
nimble taskmanapk           # an Android APK
```

## HR Book

![HR Book: the staff of the demo book's hotels](../docs/examples/hrbook.png)

`hrbook.nim` is HR Book, every employee of a group of hotels in one
private book on a tablet: records, salaries and allowances, documents and
the dates they expire, groups, Excel sheets of any layout imported
smartly, letters and certificates from templates in English and Arabic,
charts and alerts, and encrypted backups. The data never leaves the
device: the app has no internet permission, and its file is sealed with
the PIN. The picture is its demo book of invented people
(`nim c -r tests/hrbook_demo.nim`, PIN 246810, with HOME pointed at a
folder of its own).

```sh
nimble hrbook               # or: nim c -r -d:release examples/hrbook.nim
```

## 7GUIs

![7GUIs: the spreadsheet, its sums and averages](../docs/examples/sevenguis.png)

`sevenguis.nim` is [7GUIs](https://eugenkiss.github.io/7guis/), the
benchmark that measures a GUI toolkit by seven small tasks, each made as
the tasks ask, in a tab of its own:

1. **Counter** -- a box and a button that counts.
2. **Temperature Converter** -- Celsius and Fahrenheit, each kept in step
   with the other as it is typed; what is not a number changes nothing.
3. **Flight Booker** -- a one-way or a return flight, two dates typed
   (DD.MM.YYYY), red while they are no date, and Book only when the
   dates allow it.
4. **Timer** -- a gauge of the time gone, a slider for how long, Reset;
   the time goes on in any tab.
5. **CRUD** -- names in a list, filtered by the surname's start; create,
   update, delete.
6. **Circle Drawer** -- a click makes a circle, a right click on one
   adjusts its diameter in a dialog; undo and redo.
7. **Cells** -- a spreadsheet of A..Z by 0..99 with formulas (`=B1*C1`,
   `=SUM(D1:D3)`, `AVG`, `MIN`, `MAX`, `COUNT`, `PROD`); a change reaches
   every cell that reads it, a cycle says `#CYCLE`. F2 edits a cell's
   formula, not its value.

As an app it has its own icon and a menu: the seven tasks (Ctrl+1 to
Ctrl+7), Appearance (its color scheme and sizes, kept) and About. It is
built with the released apps, for Linux, Windows, Android and macOS.

`tests/test_sevenguis.nim` uses it as a person would, by its controls'
names; the picture above was taken the same way (the driver, `RETRO_DRIVE`).

```sh
nimble sevenguis            # or: nim c -r -d:release examples/sevenguis.nim
RETRO_APP=sevenguis nimble appapk   # build/Retro7GUIs.apk
```

## Retro Navigator

![Retro Navigator: its welcome page, the tool bar, the Location box, the directory buttons](../docs/examples/navigator.png)

`navigator.nim` is a web browser in the manner of 1995's around the
system's own engine (`webView` with `weSystem`): WebView2 on Windows,
WebKit on macOS and iOS, WebKitGTK on Linux and BSD, Android's WebView.
So today's web works in it -- sign-ins, maps, video -- in a window of 1995:

- the tool bar with its labels (Back, Forward, Home, Reload, Open, Print,
  Picture, Find, Stop), the page's look as a switch (Modern, Classic,
  Plain) and, at its right, a logo of its own -- a planet in the night --
  with a comet going round it while a page loads (a click goes home);
- the **Location** box: an address goes there, a host gets `https://`, a
  file on the computer opens, and anything else is searched for with the
  search engine of General Preferences (DuckDuckGo, Google, Bing,
  Wikipedia); as it is typed in it suggests the pages visited (the last
  400 are kept) and the bookmarks;
- **page looks** (the switch, or View > Page Look): Modern, as the site
  made it; Classic, the site's layout and scripts in 1995's type on white
  paper, with 3.1 buttons and fields and no shadows, rounding or
  animation; Plain, the HTML alone -- none of the site's style sheets or
  scripts, its `<noscript>` shown, its pictures loaded -- the lightest and
  the quickest (`examples/navigator/look.nim`);
- the page's scroll bar is the window's own, drawn by the kit beside the
  page (`webScrollBars`): it follows the page and scrolls it; the boxes
  inside the page get Windows 3.1's, in the window's colors;
- the directory buttons: Welcome, What's New, Net Search, Net Directory,
  Handbook, Software;
- the status bar: what happens, the key (https) or a warning sign (http),
  how much is loaded, downloads, and the page's **zoom** (a slider, 50 to
  300 %; Ctrl and +, -, 0 too);
- **video full screen**: the page's video (or anything of it) fills the
  screen, the bars and the window's frame gone, Esc brings them back; Pop
  Out Video puts it in a window of its own where the engine has one; F11
  gives the page the whole screen with the menus kept;
- **screenshots** (Picture, Ctrl+Shift+S): the page's picture marked up
  with Retro Board's tools -- the pen, the highlighter, boxes, ovals,
  arrows and words, in its colors and sizes, undo and redo -- copied for
  any program, or saved as PNG or as a board (`examples/navigator/markup.nim`);
- **Bookmarks** (Add Bookmark, Ctrl+D; View Bookmarks to go to one or
  remove it), the **Go** menu with the pages of this session, find on the
  page (`window.find`), print, the document's source, larger and smaller
  pages, Back to its own pages too;
- its own pages, `about:welcome` and `about:handbook`, written in HTML and
  CSS (`examples/navigator/pages.nim`);
- **View > Summary**: the page's article summed up by an AI service of
  your own (Options > AI Connector) -- this device's own model too, which
  sends nothing anywhere;
- **tabs**, shown above the page while there are two or more, in Windows
  3.1's document style: New Tab (Ctrl+T), Close Tab (Ctrl+W), Reopen
  Closed Tab (Ctrl+Shift+T), Ctrl+Tab; a link with Ctrl or the middle
  button opens in a tab behind, a link for a new window in a new tab; a
  tab's menu (Duplicate, Close Other Tabs), and tabs dragged into order;
  **private tabs** (New Private Tab, Ctrl+Shift+N) kept out of the
  history, the session and the closed tabs;
- **History** (Ctrl+H: find, go to, remove, clear), **Downloads** (Ctrl+J:
  open, show in the folder, clear the finished) and **Reader** (Ctrl+Alt+R:
  the page's article alone, in large type);
- **the shield** (`examples/navigator/shield.nim`): the engine never
  fetches what comes from more than 250 ad and tracker sites and the ad
  addresses of sites that serve their pages too (`webBlockList`), nor the
  sites of a list the user imports (a hosts file, or an ad blocker's
  `||site^` lines); and a script in every page before the page's own
  (`webStartScript`) blocks what is left -- the page's requests to them,
  their scripts, frames and pictures, the usual ad boxes, YouTube's ads in
  its player -- with the number kept off the page in the status bar and
  Allow Ads on This Site; sites asked not to track (Global
  Privacy Control); links to `http://` taken to `https://` (not on the
  local network; type `http://` to go anyway);
- **faster**: a link of the site loaded ahead while the pointer rests on
  it, videos kept from playing by themselves (a setting), a tab behind
  paused at once where the engine can, and tabs not looked at for five
  minutes put to sleep to free their memory (on at first);
- **Clear Browsing Data** (Ctrl+Shift+Delete): the pages visited, and the
  cookies, cache and site data (`webClearData`);
- **Preferences** as Netscape had them, a tabbed dialog opened at its
  tab from the Options menu: General (the home page, the search engine),
  Appearance (the colors, the frame, the title bars' buttons), Security
  (the shield, the sites ads are allowed on), Network (the speed); and the
  tool bar, the Location box and the directory buttons shown or hidden,
  kept for the next start.

Where the system has no engine, it shows its own pages and opens the
others in the browser. `tests/test_navigator.nim` checks its places
(`examples/navigator/places.nim`), its history and suggestions, its shield
and block lists, and its looks.

```sh
nimble navigator            # or: nim c -r -d:release examples/navigator.nim
```

## Retro DNS

1.6: on a phone in the Glass, Matte or Gloss look it is a phone app -- a tab bar (DNS,
Servers, Favourites, More), a navigation bar, pages that slide in, rows in groups (the VPN's
switch, the server picked ticked, each server's info button for its page, its addresses copied
with a tap, Test All Servers and Pick the Fastest under the groups) --; on a tablet the
sections are a list down the left and the page of the one picked is beside it, each under its
own navigation bar. Its APK starts in Gloss, as phone apps were drawn in 2012 (Settings >
Appearance changes it). 1.8: the search bar right under the navigation bar, from one side of
the phone to the other; Servers and Favourites pulled down test every server again. 1.9: the
state at the top of DNS -- a badge, Protected or not, where the lookups go, with the VPN on its
lookups, their time and the names blocked -- and a big Connect or Disconnect; Encryption
(Automatic, HTTPS, TLS); Fastest from Here, numbered, and Use the Fastest; a server held: Connect,
Test, Favourite, Copy (`tableRow`'s `menu`); Activity (a tab of its own on Android): the names the
phone looked up, the newest first, one held to Block or Unblock, and what reached what as a graph;
Favourites' Edit (`editRow`: their order is the one the VPN goes on to); on a tablet the state and
Connect over the sections. tests/test_dnsapp.nim draws every page in every look, on a phone and a
tablet (the app built with -d:retrodnsTest: no frame loop of its own).

![Retro DNS: the servers, Cloudflare's details, and Use on This Computer](../docs/examples/retrodns.png)

`retrodns.nim` changes the DNS server a phone, a tablet or a computer
uses: 47 public resolvers -- fast, private, secure, ad-blocking, family,
unfiltered, regional -- each with what it is good for, speed tests (the
time to reach it, on two worker threads), favourites, and servers of your
own (CSV, imported and exported). Each system the way it allows:

- **Android:** a VPN that stays on the device and carries DNS only,
  encrypted (DNS over HTTPS or TLS), with a notification while it is on.
  Android starts a VPN only from a Java class its manifest declares, so
  the app brings it: `retrodns/glue/` holds the VPN service (`java/`),
  stand-ins for the Android classes it compiles against (`stubs/`: no
  android.jar), the manifest lines (`manifest.txt`) and the compiled
  `classes.dex`; `retroapk --java:examples/retrodns/glue` puts them in the
  APK or bundle. Nim calls the Java by reflection (`retroui/native`).
  A tile in the quick settings (`DnsTile.java`, in the VPN's process)
  turns it on and off with the server last used, and so does the kit's
  widget on the home screen (`--widget`, `homeWidget`); a graph shows
  each server's speed over its last 30 tests, and the lookups while the
  VPN is on -- and what the phone reached: each app joined to the sites it
  looked up in the last two minutes (their registrable domains), a graph
  that lays itself out (`graphView`). Android 10 and later say which app
  asked; before, the phone is one node. **When a network blocks
  encrypted DNS by the server's name**, the VPN finds its first packet --
  the TLS hello, with the name in it -- cut, and from then sends that hello
  in pieces of 40 bytes, so no piece holds the whole name (as GreenTunnel
  does), or -- where the server's certificate is for its address too
  (1.1.1.1, 8.8.8.8, 9.9.9.9) -- connects by address with no name at all
  (`SplitTls.java`; only Retro DNS's own queries). **VPN > Switch When a
  Server Stops Answering** (on at first): three failures in a row and it
  goes on to the next of your favourites, then the fastest the tests
  found, saying why ("it timed out", "the connection was cut as it said
  hello"); each failure says why in plain words. **VPN > Block List**:
  names answered "no such name" on the phone, sending nothing -- a name a
  line and its subdomains, `!name` an exception (as zapret's host lists
  have it), a hosts file's lines as they are: a hosts file without root.
  `glue/tests/check.sh` tests the Java on a computer (its lists, answers
  and reasons; the hello in pieces and with no name, against a TLS server
  of its own).
- **Windows, Linux, macOS:** Use on This Computer gives the computer the
  server's addresses as its administrator, the system asking first
  (`retroui/admin`: UAC, polkit, the password dialog): every adapter's
  servers on Windows, with DNS over HTTPS where Windows 11 has it;
  NetworkManager's connections on Linux, with DNS over TLS where
  systemd-resolved does it (else systemd-resolved alone); every network
  service on a Mac. Back to Automatic gives back the network's own. The
  scripts are made of checked addresses only (`retrodns/desktop.nim`).
- **macOS, iOS:** a server with encrypted DNS comes as a profile that
  Settings installs (and removes): DNS over HTTPS or TLS for every app.
- **A web page:** the servers and what they are good for.

```sh
nimble dns                                  # or: nim c -r -d:release examples/retrodns.nim
sh examples/retrodns/build.sh apk           # Android, its VPN in it
sh examples/retrodns/build.sh key           # a Google Play upload key, once
sh examples/retrodns/build.sh aab           # the bundle for Google Play
sh examples/retrodns/build.sh dex           # its Java compiled again (javac, d8 or dx)
```

`tests/test_retrodns.nim` checks its servers, the CSV, the VPN's
settings, the scripts and the profile.


## Retro Music

`music.nim` (with `music/api.nim`, `music/local.nim`, `music/sources.nim`,
`music/online.nim`, `music/tv.nim`, `music/appids.nim`, `music/screens.nim`)
plays your own music, the free music and TV of the world with nothing to set
up, your own music server, and Spotify; one plays at a time:

- **Your own music:** the songs on the phone (Android asks once: Allow
  Access to Music, `askMusicAccess`) or in the computer's Music folder --
  Settings > Music Folders adds others -- looked through on a worker thread,
  each file's tags and cover read by `retroui/audiotags` (MP3, FLAC, M4A,
  Ogg, Opus, WAV) and kept with how often it was played, when, and its
  stars. Library > On This Device: Songs (a search, Shuffle All), Albums (in
  Cover Flow when the phone is on its side, or on a big screen), Artists,
  Genres, Playlists -- yours, put in order with their grips, and lists made
  by themselves: Favorites (four stars and five), Most Played, Recently
  Added, Recently Played. A song's info button: Play Next, Add to Queue, Add
  to Playlist. Now Playing: the cover, the stars, where it is, the
  controls, Shuffle, Repeat (all, one), Up Next (put in order, taken out),
  the sleep timer (15 minutes to an hour, or the end of the song), the
  lyrics. It plays with `audioPlayer`, on in the background -- the lock
  screen's and the notification's controls and a headset's keys through
  `setNowPlaying` and `mediaKeys`. Settings > Sound: the equalizer (eighteen
  presets, or your own 10 bands on `vslider`s: Android's and GStreamer's),
  Level Songs (each song's ReplayGain: one loudness), the sleep timer.
- **YouTube Music, nothing to set up:** search its songs, albums and
  playlists -- through Piped's public servers, each tried in turn, then
  Invidious' (Settings > YouTube Music takes your own Piped server) -- and
  they play in YouTube's own player. Paste a playlist's or an album's link
  (Share > Copy link in YouTube Music) in Library and it stays there: no
  account, no Google Cloud project.
- **Radio:** the stations of Radio Browser's directory -- the top ones, by
  genre, by name; the info button keeps one in Your Stations (Home has them
  on a shelf). A station plays live in the app's own player.
- **Audius:** what trends, a search, and an artist's tracks and playlists
  by their handle (yours, if you have one). Free music its artists put
  there whole.
- **The Internet Archive:** live concerts (the Live Music Archive),
  netlabels, 78 RPM records, old-time radio; a recording's songs in order.
- **Your own server:** Navidrome, Airsonic, Gonic, Ampache or any server
  that speaks Subsonic -- its address, your name and password (kept with
  `retroui/secrets`; the password is never sent, a salted hash of it is):
  its newest albums, your playlists, random songs, a search. They play in
  the app's own player, as your own songs do.
- **Spotify:** make an app of your own at developer.spotify.com, with the
  Redirect URI `http://127.0.0.1/`, and give Retro Music its Client ID;
  Sign In opens Spotify's page in your browser (`retroui/oauth`, PKCE, the
  loopback address's port picked as it signs in). Search, your playlists, your liked songs and what you played
  lately come from Spotify's Web API. The music plays in your own Spotify
  apps and speakers -- Spotify Connect, which needs Premium -- and Retro
  Music is their remote: play a song or a playlist from one of its songs,
  pause, next, seek, and the device it plays on.
- **TV:** the free channels of the world, as Free-TV lists them
  (github.com/Free-TV/IPTV, fetched when TV is opened) -- by country, their
  logos, a search; a channel held stays in Your Channels. A channel plays in
  the app (`videoView`: the system's player), as the players of 2012 showed
  a film: Done and its name, the time it has played, the picture, a panel
  with the channel before, play or pause, the next; Full Screen turns the
  phone on its side and gives the picture the whole screen (`videoFullScreen`;
  a tap or Back: as it was). Left while it plays -- Done, the phone's Home -- its sound
  goes on in the app's own player: in the background, on the lock screen.
- **Music videos and artwork:** a video on the device (MP4, M4V, MOV, MKV, WebM -- an MP4
  of sound alone is a song) plays with its picture on Now Playing, from where its sound was;
  left, its sound goes on from there. A song with no cover gets artwork made from it: its
  album's two colors, waves of sound, a record's grooves or a meter's bars, its title and
  artist on it -- the same for all of an album's songs.
- **Your own YouTube playlists:** Sign In with Google -- one tap when the app
  is built with its own Google client (`RETRO_MUSIC_GOOGLE_ID` and
  `RETRO_MUSIC_GOOGLE_SECRET`, or Retro Mail's; its Google Cloud project has
  the YouTube Data API v3 on), else, under Advanced, a Desktop app client of
  your own Google Cloud project, yourself a test user -- and Library has your playlists (YouTube
  Music's are YouTube's) and Liked Music, Home a shelf of them. YouTube's
  songs play in the app, in YouTube's own player: on a phone on Now
  Playing, on a tablet under the places, the next song when one ends, with
  previous, play, pause, next and how far, and the lyrics timed. YouTube
  asks that its player be on the screen while it plays: away from it, it
  pauses, and goes on when it is shown again. A key alone (no sign-in)
  searches when Piped's and Invidious' servers don't answer. Save the ones
  you like.
- **Lyrics:** from LrcLib, timed: the line sung is in the highlight.
- **Search** looks through any of them -- YouTube Music, your own songs, the
  radio, Audius, the Archive, your server, Spotify -- a chip for each.
- **Now Playing**, for the app's own player, is the music players' of
  2012: a dark bar with the artist, the title and the album; the place in
  the queue, where the song is, Repeat and Shuffle over the cover; the cover
  as wide as the screen with the lyrics over its foot, the line sung lit; a
  tap on it, or the button at the bar's end, turns it to the queue's songs,
  numbered, the one playing marked, with the stars, the sleep timer, Add to
  Playlist and Up Next; the controls and the volume at the foot.

Settings > Spotify and Settings > YouTube Music > Advanced walk you through
it step by step, a button to each page (Spotify for Developers; Google Cloud's
project, its YouTube Data API v3, its audience, a new client, its
credentials): the Redirect URI copied with a tap, the Client IDs, the
secret and the key pasted, the key tried with a search and what a refusal
means said in a sentence (the API not on, the key's restrictions, the
day's searches used up). YouTube Music has no API of its own for apps: its
music is read with YouTube's. Home and Library pulled down are asked again.

On a phone, pages one over another with Back, a mini player at the foot, and
the places in a menu that slides out from the left (`sideMenu`, the button
at the navigation bar's start): Home, Search, Library; YouTube Music, Radio,
Audius, Internet Archive; My Server, Spotify; Settings. On a tablet or a
computer the same places down the left, with what plays and its controls,
the page beside them under its own navigation bar. It starts in the Gloss look (1.1); Settings >
Appearance changes it.

```sh
nimble music                # or: nim c -r -d:release examples/music.nim
RETRO_APP=music nimble appapk
```

## Retro Podcast

![Retro Podcast: a show followed, its episodes, the player at the bottom playing one, another queued](../docs/examples/podcast.png)

`podcast.nim` is a podcast player for Windows, macOS, Linux, Android, iOS
and web pages: shows found by name (Apple's podcast directory) or added by
their feed's address (RSS or Atom), lists brought from another app and
taken to one (OPML), episodes played at any speed from where they were
left, downloads for the road, a queue, a sleep timer, the system's media
controls (the lock screen, the notification, the media keys), and an icon
in the tray on a desktop (Settings). The sound plays on when another page
is shown, and with the app in the background: on Android with the
system's notification that it plays, on iOS with the app's background
audio. Unfollow, Mark Played and the queue's changes are undone from the
Edit menu. On Android a widget on the home screen shows what plays, with
Play or Pause and Ahead (`--widget`, `homeWidget`), and a feed's address
shared from another app is followed.

It is the kit's newer parts put together: `retroui/feeds` reads the feeds
and OPML, `retroui/jobs` reads them, asks the directory and downloads on
worker threads, `audioView` plays (`speed`, `seekVideo`, `playVideo`),
`pageView` and `listDetail` lay it out -- the shows beside their episodes
on a desktop, one over the other on a phone -- `UndoStack` keeps its
history and `retroui/tray` its icon. Its library (`podcast/library.nim`)
is JSON in the app's data folder.

```sh
nimble podcast                              # or: nim c -r -d:release examples/podcast.nim
RETRO_APP=podcast nimble appapk             # build/RetroPodcast.apk
retrokit web examples/podcast.nim           # a web page (see below)
```

In a web page the browser asks each feed's site whether the page may read
it (CORS), and most podcast hosts do not say yes: Settings has a proxy put
before each feed's address. The sounds themselves play without it.
`tests/test_podcast.nim` follows a feed file, plays, queues, undoes and
saves the library without a window.

## Retro Tasks

`tasks.nim` (with `tasks/model.nim`, its data without a window, and
`tasks/screens.nim`) is a whole phone app, and [lesson 17](../tutorials/17-whole-app/)
builds it step by step:

- **Tasks** in lists, each a `checkRow` -- its round check ticks it, the
  rest of the row opens it --; a new one typed at the top of its list; Edit
  puts them in order by their grips and deletes them (`editRow`). A task's
  page: its title, Done, Flagged, its list, its day (`dateWheels`) and time
  (`timeWheels`), Remind Me, its priority, its notes.
- **Lists made by themselves:** Today (due today, and late -- in red),
  Upcoming (a group a day), Flagged, Completed (Clear Completed).
- **Reminders:** a task due with Remind Me raises the phone's notification
  (`notify`), also while the app is closed (`onBackgroundCheck`,
  `scheduleBackgroundCheck(15)`); the app's icon counts what is due today
  (`setBadge`).
- **Notes** beside them, pinned ones first, their first line their title;
  **Search** through both; **Settings**: Show Completed, Reminders, Count on
  the Icon, Appearance.
- Kept in one JSON file in the app's folder, written two seconds after a
  change through a file of its own moved over the old one.

A tab bar and pages with a navigation bar on a phone (the phone's Back
goes back a page); on a tablet, a phone on its side or a computer the tab's
first page -- the lists, the notes -- down the left and the page chosen
beside it, under its own bar. It starts in the Gloss look.

```sh
nimble tasks                                # or: nim c -r -d:release examples/tasks.nim
RETRO_APP=tasks nimble appapk               # build/RetroTasks.apk
```

`tests/test_tasks.nim` checks its data and works it by taps.

## Grow

![Grow: the plan -- a goal, the amount, a slider of years, the growth -- and its result: the total counted up, a ring, the years as 3D bars under the goal's line, a gold coin over the last](../docs/examples/grow.png)

`grow.nim` is a phone app: a savings goal, how much each month, for how
many years, growing how much a year -- and then what it comes to. Two
pages (`pageView`, the phone's Back): the plan, its first look gliding as
the numbers change (`animated`) and its button at the foot, where the
thumb is (`spring()`); then the result, which counts up, fills a ring
(`progressRing`) and raises a 3D bar for each year one after another
(`easedSince`, each a little after the one before) under a camera that
sways round them, a gold coin turning over the last. The bars turn green
from the year the goal is reached; a tap on one says what it holds
(`picked`), a finger turns them; Share opens the phone's share sheet
(`share`), a goal reached is felt (`haptic`). The scene is made in code --
boxes, a cylinder, lines and labels, materials of a color (`material3`) --
and drawn on the GPU where frames are.

```sh
nimble grow                                 # or: nim c -r -d:release examples/grow.nim
RETRO_APP=grow nimble appapk                # build/Grow.apk (portrait)
```

`tests/test_grow.nim` checks the plan's numbers, the button at the
page's foot, and the result's timeline played to its end without a
window.

## BMI Studio

![BMI Studio three times: in its own gray and navy, in the kit's Mint and in the kit's Dusk](../docs/examples/bmi.png)

`bmi.nim` is a body mass index calculator, and the example of a window
with a look of its own. Nothing in it is a control made from scratch but
the banner: the title bar with the app's icon and a large title
(`captionIcon`, `captionAlign`, `captionStyle`), the panels with a title
strip (`group ..., glCaption`), the unit options in boxes (`radio(boxed =
true)`), the number boxes with large digits (`spin(h = ..., style =
...)`), the navy Calculate BMI (`button(accent = true, style = ...)`), the
dial in four bands (`gauge` with `Band`s), the classes under it
(`rangeBar`) and the tag with a tick (`pill`) are the kit's, by their
options. Its colours are a `Theme` of its own; View > Colours puts any of
the kit's 28 schemes on, and the bands, the tag and the accent button
follow, because they name no colours (`goodColor()`, `warnColor()`...).
The banner is drawn on a `canvas`. On a phone it is one column
(`isCompact()`).

[docs/customizing.md](../docs/customizing.md) goes through it part by
part: changing a control by its options, putting controls together,
drawing one yourself, and changing the kit.

```sh
nimble bmi                                  # or: nim c -r -d:release examples/bmi.nim
RETRO_THEME=Mint nimble bmi                 # in another scheme
RETRO_APP=bmi nimble appapk                 # build/BMIStudio.apk
```

`tests/test_bmi.nim` checks its numbers and runs its window without one.
