## Retro Photo 3 -- an image editor in the manner of the paint programs of
## 1994: a toolbox and floating, tabbed palettes (Brushes and Options;
## Picker, Swatches and Scratch; Layers, Channels and Paths; Info;
## Commands) over document windows; layers with blend modes, selections
## with marching ants, Quick Mask, channels, paths, twenty-one tools,
## filters and color adjustments with previews, and many undos. Made with
## Retro Nim UI, its engine in `retroui/photo`.
##
##   nim c -r -d:release examples/photo.nim [picture...]
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, math, tables, times, algorithm, json, hashes, cpuinfo, sets, sequtils]
import retroui
import retroui/lang_ar as kitArabic
import retroui/rscript except parseJson, toJson
import photo/lang_ar as photoLang
import retroui/[photo, photopaint, photofx, photoartistic, photohdr, otshape, ttf, photosvg, photovp, photodevelop, photosmart, photowarp, photostyles, photowidgets, photoneural,
              photopresets, photocc, phototemplates, photoquick, photogpu, qrcode, systemimage, assetstore,
              svgimport, morepictures, edgetrace,
              photofiles, photosave, photoshapes, photomerge, photopdf, photoimport, pdfread, googlefonts, photovector, iccprofile, icclut, abr, rawphoto, imageformats, filterfactory,
              photobrushes, adobefiles,
              imaging, report, canvas2d, markdown, textengine, textwidgets, parallel, files]
{.push warning[UnusedImport]: off.}
import retroui/photodeep   # (imported for what it sets up: filters, flattening and gradients at 16 and 32 bits)
{.pop.}

const
  AppName = "Retro Photo"
  AppVersion = "4.9.11"
const filesWhy = AppName & " opens and saves your pictures (the Pictures and DCIM folders). " &
                 "Without the access it keeps them in its own folder."

# ---- tools ---------------------------------------------------------------------------------------

type
  Tool = enum
    tMarquee = "Marquee", tLasso = "Lasso", tMove = "Move", tWand = "Magic Wand",
    tHand = "Hand", tZoom = "Zoom", tCrop = "Crop", tType = "Type",
    tBucket = "Paint Bucket", tGradient = "Gradient", tShape = "Shape", tEyedropper = "Eyedropper",
    tEraser = "Eraser", tPencil = "Pencil", tAirbrush = "Airbrush", tBrush = "Paintbrush",
    tStamp = "Rubber Stamp", tSmudge = "Smudge", tBlur = "Blur/Sharpen", tDodge = "Dodge/Burn/Sponge",
    tPen = "Pen", tHeal = "Healing", tRedEye = "Red Eye"

  ToolOpts = object
    mode: int                  ## index into PaintModes
    opacity: int               ## 1..100 (pressure, exposure)
    fade: int
    fadeToBg: bool
    wet, autoErase, finger: bool
    tip: BrushTip              ## the brush (Brushes palette, Brush Settings)
    preset: string             ## the preset it came from ("" changed since)
    sizeByPressure, opacityByPressure: bool
    dyn: BrushDynamics         ## Brush Dynamics

const
  toolKeys: array[Tool, char] = ['M', 'L', 'V', 'W', 'H', 'Z', 'C', 'T', 'K', 'G', 'N', 'I',
                                 'E', 'Y', 'A', 'B', 'S', 'U', 'R', 'O', 'P', 'J', 'J']
  toolHints: array[Tool, string] = [
    "Drag to select (then Shift: square, Alt: from the middle); Shift adds, Alt takes away; drag inside moves the outline",
    "Drag to select freehand; Alt+click for straight sides; Shift adds, Alt takes away",
    "Click anything to pick its layer (Auto-Select), drag to move it; the arrow keys nudge it",
    "Click to select similar colors that touch; Shift adds, Alt takes away",
    "Drag to scroll the image; double-click the tool to fit it on the screen",
    "Click to zoom in, Alt+click to zoom out, drag a box to zoom to it; double-click the tool for 1:1",
    "Drag the area to keep, then click in it (or press Enter) to crop",
    "Click to type, drag a box for a paragraph, click the work path to type along it; click text to edit it",
    "Click to fill similar colors that touch with the foreground color",
    "Drag to set where the gradient begins and ends",
    "Drag to draw a shape (Shift: a square, a circle, lines at 45 degrees; Alt: from its middle)",
    "Click to take the foreground color, Alt+click the background",
    "Drag to erase to the background color (or to transparent on a layer)",
    "Drag to draw hard-edged lines; Shift+click for a straight line",
    "Drag to spray paint; hold to build it up",
    "Drag to paint; Shift+click for a straight line",
    "Alt+click to set the source, then drag to paint with a copy of it",
    "Drag to smudge the paint",
    "Drag to blur (Alt: sharpen)",
    "Drag to lighten, darken or change the saturation",
    "Click to add corner points, drag for curves; click the first point to close",
    "Paint over a spot to heal it (Spot Healing); Alt+click a source, then paint (Healing Brush); " &
      "drag a selection to the texture to take (Patch)",
    "Click a red pupil, or drag a box around the eye"]
  toolIcons: array[Tool, string] = [pxMarqueeRect, pxLasso, pxMoveTool, pxMagicWand, pxHandTool,
                                    pxZoomTool, pxCrop, pxTypeTool, pxBucket, pxGradient, pxRectShape,
                                    pxEyedropper, pxEraser, pxPencil, pxAirbrush, pxBrush, pxStamp,
                                    pxSmudge, pxBlur, pxDodge, pxPen, pxSpotHeal, pxRedEye]
  paintTools = {tEraser, tPencil, tAirbrush, tBrush, tStamp, tSmudge, tBlur, tDodge}
  brushTools = paintTools + {tHeal}    ## (the tools with a brush of their own)
  black = 0xFF000000'u32
  white = 0xFFFFFFFF'u32

type
  DocWin = ref object
    doc: Doc
    win: MdiWindow
    view: PhotoView
    lastPaint: (float, float)      ## where the last stroke ended (Shift+click lines)
    hasLastPaint: bool
    placed: bool                   ## given its place in the area (once the area is known)
    floating: bool                 ## in a window of its own (else a tab of the documents' window)
    recovery: string               ## its recovery copy ("" none yet)
    sessionFile: string            ## its copy kept for the next start (the session; "" none)
    sessionVer: int                ## (the document's `ver` when that copy was written)
    autoVer: int                   ## (the document's `ver` when it was last kept aside)

  Drag = object
    ## What the mouse is doing on a document.
    on: bool
    dw: DocWin
    tool: Tool
    x0, y0, x1, y1: float          ## image coordinates
    stroke: Stroke
    lift: Lift
    pts: seq[(float, float)]       ## the lasso
    op: SelOp
    moving: bool                   ## dragging the selection's pixels
    lastTick: int
    sx, sy: int                    ## the mouse on the screen (the hand)
    smx, smy: float                ## where the smoothed stroke has got to
    board: int                     ## the Artboard tool: the artboard moved (-1: one drawn)
    selMove: bool                  ## a selection tool dragged inside the selection: its outline moves
    sel0: seq[uint8]               ## ... the outline as it was
    selStepped: bool               ## ... moved (an undo step begun)
    center: bool                   ## the Marquee: drawn from its middle (Alt)

var
  docs: seq[DocWin]
  active: DocWin
  untitled = 0
  tool = tMove                     ## (the first tool: the Move tool, picking what is clicked)
  fg = black
  bg = white
  opts: array[Tool, ToolOpts]
  presets: seq[BrushPreset]      ## the Brushes palette's (kept in Brushes.json)
  userGradients: seq[GradientPreset]   ## gradients loaded (.grd)
  userPatterns: seq[PatternPreset]     ## patterns loaded (.pat)
  # tool options
  brushSmoothing = 0             ## % (the stroke follows the mouse more calmly)
  symmetry = 0                   ## Off, Vertical, Horizontal, Dual Axis, Radial, Mandala
  symAxes = 6
  marqueeShape = 0               ## rectangle, ellipse, single row, single column
  marqueeStyle = 0               ## normal, constrained aspect ratio, fixed size
  marqueeW = 64
  marqueeH = 64
  marqueeFeather = 0
  marqueeAA = true
  lassoFeather = 0
  lassoAA = true
  lassoMode = 0                  ## freehand, polygonal (clicked corners), magnetic (along edges)
  magWidth = 10                  ## the Magnetic Lasso: how far from the mouse it looks for an edge (px),
  magContrast = 10               ## ... how weak an edge it still follows (%),
  magFrequency = 57              ## ... how often it puts a point down by itself (0..100)
  magLive: tuple[key: string; pts: seq[(float, float)]]   ## (its side to the mouse now)
  editToolbarOpen = false        ## Edit > Toolbar (Customize Toolbar)
  wandTol = 32
  wandAA = true
  wandMerged = false
  wandContig = true              ## the Magic Wand's Contiguous
  springing = false              ## a tool held for a moment (Space, Ctrl, Alt)
  shapeDlg: tuple[on: bool; dw: DocWin; x, y: float; w, h: int; center: bool] = (false, nil, 0.0, 0.0, 100, 100, false)
  toningDlg: tuple[on: bool; bits, meth: int; exposure, gamma, detail: float]   ## HDR Toning (from 32 bits)
  previewDlg: tuple[on: bool; exposure, gamma: float]    ## View > 32-bit Preview Options
  notes: seq[tuple[d: Doc; x, y: float; text: string]]   ## the Note tool's notes
  noteDlg: tuple[on: bool; idx: int; text: string]       ## ... the one being written
  counts: seq[tuple[d: Doc; x, y: float]]                ## the Count tool's marks, numbered in order
  slices: seq[tuple[d: Doc; r: Rect]]                    ## the Slice tool's slices
  sliceSel = -1                                          ## ... the one picked (Slice Select)
  sliceGrab: tuple[on: bool; r0: Rect]                   ## ... dragged
    ## Create Rectangle (a click with a shape tool): where, how big
  springBase = tBrush            ## ... the one chosen, back when they are let go
  bucketContig = true            ## the Paint Bucket's Contiguous
  bucketAll = false              ## ... All Layers
  bucketTol = 32
  bucketAA = true
  bucketPattern = 0              ## 0 foreground, 1 pattern
  gradStyle = 0
  gradPreset = 0                 ## the gradient tool's gradient: a preset (-1: `gradCustom`)
  gradCustom: seq[GradientStop]
  gradReverse = false
  gradKind = 0
  gradMid = 50
  gradOffset = 0
  gradDither = true
  lineWidth = 1
  lineAA = true
  lineStart = leNone             ## the Line tool: what its line has at its start, its end
  lineEnd = leNone
  lineEndW = 400                 ## ... how wide and long those are, % of the line's weight
  lineEndL = 400
  # the shape tools
  shapeKind = 0                  ## Rectangle, Rounded Rectangle, Ellipse, Polygon, Line, Custom Shape
  shapeMode = 0                  ## Shape layer, Path, Pixels
  shapeOp = 0                    ## New layer, Combine, Subtract, Intersect, Exclude (on a shape layer)
  shapeRadius = 10
  polySides = 5
  starPoints = 5                 ## the Star tool's points
  starIndent = 50                ## ... how far in its inner corners go, %
  spiralTurns = 3                ## the Spiral tool's turns
  spiralDecay = 80               ## ... each turn this % of the one outside
  polyStar = false
  polyIndent = 50
  polySmooth = false
  customShape = 0
  shapeFillKind = 1              ## No Color, Solid Color, Gradient
  shapeFill = 0xFF3A6EA5'u32
  shapeFill2 = 0xFFFFFFFF'u32
  shapeStrokeKind = 0            ## No Color, Solid Color
  shapeStroke = 0xFF000000'u32
  shapeStrokeW = 3
  shapeAlign = 0                 ## Inside, Center, Outside
  shapeDash = 0                  ## Solid, Dashed, Dotted
  dropperSize = 0                ## point, 3 by 3, 5 by 5
  eraserMode = 0
  eraseToSaved = false
  snapshot: tuple[doc: Doc; layer: Layer; px: seq[uint32]]   ## Edit > Take Snapshot
  savedCache: tuple[path: string; time: float; w, h: int; px: seq[uint32]]
  blurMode = 0                   ## blur, sharpen
  healMode = 0                   ## spot healing brush, healing brush, patch, remove, content-aware move
  moveKind = 0                   ## the Move tool (0) or the Artboard tool (1)
  spotKind = 0                   ## the Spot Healing Brush's Type: Content-Aware, Create Texture, Proximity Match
  patchContentAware = 0          ## the Patch: Normal (0), Content-Aware (1)
  patchDest = false              ## ... Destination (else Source)
  patchTransparent = false
  patchStructure = 4             ## ... Content-Aware: Structure 1..7, Color 0..10
  patchColor = 0
  camExtend = false              ## Content-Aware Move: Extend (the original stays)
  cropStraighten = false         ## the crop tool draws a line to make level
  redEyeDarken = 50
  dodgeMode = 0                  ## dodge, burn, sponge
  dodgeTone = 1                  ## shadows, midtones, highlights
  spongeMode = 0                 ## desaturate, saturate
  stampMode = 0
  stampTool = 0                  ## the rubber stamp, the history brush
  brushTool = 0                  ## the paintbrush, the mixer brush, the color replacement, the adjustment brush
  adjBrushKind = 0               ## the Adjustment Brush's adjustment (`adjBrushPresets`)
  adjBrushAmount = 40            ## ... how much (-100..100)
  adjBrushSub = false            ## ... takes the adjustment away (Alt: the other way)
  crMode = 2                     ## the Color Replacement tool's mode: Hue, Saturation, Color, Luminosity
  crTol = 30                     ## ... Tolerance, %
  crSampling = 0                 ## ... Continuous, Once, Background Swatch
  crLimits = 1                   ## ... Discontiguous, Contiguous, Find Edges
  mixWet = 50                    ## the mixer brush: wet %, load %, mix %
  mixLoad = 50
  mixRatio = 50
  wandMode = 0                   ## the magic wand, quick selection, object selection
  quickSize = 40                 ## the quick selection's brush (image pixels; the selection brush's too)
  selBrushHard = 80              ## the Selection Brush's hardness (0..100)
  selBrushSub = false            ## ... takes away (Alt: the other way)
  selBrushOverlay = true         ## ... shows what is not selected in red while it is the tool
  stampSrc: tuple[set: bool; x, y: float; doc: Doc]
  dropKind = 0                   ## the Eyedropper's group: Eyedropper, Color Sampler, Ruler
  eraseKind = 0                  ## the Eraser's group: Eraser, Magic Eraser, Background Eraser
  cropKind = 0                   ## the Crop group's: Crop, Perspective Crop
  handKind = 0                   ## the Hand group's: Hand, Rotate View
  penEraserFrom = -1             ## the tool before a pen was turned over to its eraser end (-1: none)
  startScriptDone = false        ## RETRO_PHOTO_SCRIPT run
  startScriptAt = 0              ## ... when
  artStyle = 0                   ## the Art History Brush: its strokes (`ArtStyle`)
  artArea = 50                   ## ... the area they are scattered over (pixels)
  artTolerance = 0               ## ... painted only where the layer differs from the source so much
  artSeed = 2463534242'u32       ## ... (its random numbers)
  artSrc: seq[uint32]            ## ... the state it paints from, while a drag lasts
  rotateAll = false              ## Rotate View: every document's view turned together
  bgEraseTol = 50                ## the Background Eraser: Tolerance, %
  bgEraseSampling = 0            ## ... Continuous, Once, Background Swatch
  bgEraseLimits = 1              ## ... Discontiguous, Contiguous, Find Edges
  bgEraseProtect = false         ## ... Protect Foreground Color
  freeCurveFit = 2               ## the Freeform Pen's Curve Fit, pixels
  curvCorners: seq[bool]         ## the Curvature Pen: which points of the subpath drawn are corners
  magicTol = 32                  ## the Magic Eraser's Tolerance
  magicContig = true             ## ... Contiguous
  samplers: seq[tuple[d: Doc; x, y: int]]   ## the Color Sampler's points (four an image)
  ruler: tuple[on: bool; d: Doc; x0, y0, x1, y1: float]   ## the Ruler's line
  docsRight = 0                  ## where the palettes begin (the documents' room ends)
  tabWin = MdiWindow(title: "Documents", open: true, flush: true, docked: true)
    ## the tabbed documents: all the room between the toolbar and the panels
  tabCur: DocWin                 ## the tab shown
  showNext: DocWin               ## to the front once the windows are all drawn (a mode changed)
  showNextAt: int                ## ... from this frame on
  tabStripAt: Rect               ## where the tabs were last drawn (a window dropped there docks)
  tabMenuDoc: DocWin             ## the tab right-clicked (its menu)
  placedFor: (int, int)          ## the size of the area the palettes were placed in
  stampPicking = false           ## the next click sets the stamp's source (no Alt on a touch screen)
  touchSelMode = 0               ## new, add, subtract, intersect (the selection tools on a touch screen)
  pattern: seq[uint32]
  patternW, patternH: int
  clip: Clip
  hasClip = false
  drag: Drag
  pendingCrop: tuple[on: bool; dw: DocWin; r: Rect; persp: bool; q: Quad]
  cropFill = 0                   ## the room the Crop tool adds past the image: Background, Content-Aware
  frameEllipse = false           ## the Frame tool draws ellipses (else rectangles)
    ## the crop box waiting (the Perspective Crop: its four corners)
  cropGrab: tuple[on: bool; part: int; x, y: float; r0: Rect; q0: Quad; moved: bool]
    ## a handle of the crop box held (0..3 corners, 4..7 sides, 8 inside)
  penDrag: tuple[on: bool; s, i, part: int]    ## the point or handle being dragged
  penMode = 1                    ## the Paths palette's tool: arrow, pen, add, delete, convert,
                                 ## path selection
  spEdit: tuple[on: bool; layer: Layer; path: Path]   ## a shape layer's path being edited
  pathSel = -1                   ## the subpath picked with the Path Selection tool
  penLast: (float, float)
  penEnded = false               ## Esc ended the path being drawn: the next click starts another
  penChanged = false
  status = ""
  # palettes
  toolbox = MdiWindow(title: "Tools", palette: true, open: true, fixed: true, bare: true)
    ## the toolbar: down the left edge, its header as the docked panels' (navy, ◂◂ ▸▸)
    ## (as the usual: moved, never closed)
  histTab = 1                    ## Navigator, History, Actions, Histogram
  propTab = 0                    ## Properties, Adjustments
  libTab = 0                     ## Styles, Shapes, Tool Presets
  compTab = 0                    ## Layer Comps, Clone Source
  lastXf: tuple[set: bool; r: Rect; quad: Quad]   ## the last transform (Edit > Transform > Again)
  # guides, the grid, snapping (View)
  snapOn = true
  snapGuides = true
  snapGrid = false
  snapBounds = true
  brushTab = 0
  colorTab = 0
  layerTab = 0
  palettesHidden = false
  palettesPlaced = false
  workspaceTried = false         ## (the last run's palettes tried, at the start)
  optionsBarOn = true            ## the tool's options in a strip under the menu bar
  pickerSliders = 0              ## RGB, HSB, grayscale
  swatches: seq[uint32]
  scratch: Doc
  scratchBmp: Bitmap
  scratchVer = -1
  # info
  info: tuple[x, y: float; c: uint32; inside: bool; w, h: float; angle, dist: float; sized: bool]
  screenMode = 0
  quitAsked = false
  quitConfirm = false            ## "Quit Retro Photo?" (documents are open)
  wasPaused = false
  sessionPending = true          ## (at the start) the last session's documents to open again
  splashUntil = 0
  splashStart = 0                  ## (when the splash came up: its bar runs from there)

# ---- the panels: docked down the right as the usual (photo/dockpanels draws them) ------------------------

const panelList = [
  ("color", "Color", pxColorPanel), ("swatches", "Swatches", pxSwatches), ("gradients", "Gradients", pxGradient),
  ("patterns", "Patterns", pxPatterns), ("scratch", "Scratch", pxScratch),
  ("properties", "Properties", pxProperties), ("adjustments", "Adjustments", pxAdjustLayer),
  ("libraries", "Libraries", pxLibraries),
  ("layers", "Layers", pxLayers), ("channels", "Channels", pxChannels), ("paths", "Paths", pxPen),
  ("history", "History", pxHistory), ("navigator", "Navigator", pxNavigator), ("actions", "Actions", pxActions),
  ("histogram", "Histogram", pxHistogram),
  ("brushes", "Brushes", pxBrush), ("brushsettings", "Brush Settings", pxBrushSettings),
  ("options", "Tool Options", pxSettings),
  ("character", "Character", pxCharacter), ("paragraph", "Paragraph", pxParagraph), ("glyphs", "Glyphs", pxGlyphs),
  ("charstyles", "Character Styles", pxCharStyle), ("parastyles", "Paragraph Styles", pxParaStyle),
  ("opentype", "OpenType", pxOpenType),
  ("info", "Info", pxInfo), ("commands", "Commands", pxCommands),
  ("styles", "Styles", pxLayerStyle), ("shapes", "Shapes", pxCustomShape), ("toolpresets", "Tool Presets", pxToolPresets),
  ("layercomps", "Layer Comps", pxLayerComps), ("clonesource", "Clone Source", pxStamp),
  ("quickactions", "Quick Actions", pxQuickActions), ("colorthemes", "Color Themes", pxColorThemes)]
  ## (each panel: its key, its title, its icon in a column collapsed to icons)

var dock = newDock()             ## the panels down the right (Window shows and hides them)

proc pdef(key: string): DockPanel =
  for (k, t, ic) in panelList:
    if k == key: return dockPanel(k, t, ic)
  dockPanel(key, key)

proc defaultDock() =
  ## The panels as the usual Essentials workspace has them: Color, Properties and
  ## Layers open down the right; the rest as icons beside them.
  dock = newDock()
  template grp(col: int; share: int; ks: openArray[string]) =
    var ps: seq[DockPanel]
    for k in ks: ps.add pdef(k)
    discard dock.addGroup(col, ps, share)
  discard dock.addColumn()
  grp(0, 26, ["color", "swatches", "gradients", "patterns"])
  grp(0, 30, ["properties", "adjustments", "libraries"])
  grp(0, 44, ["layers", "channels", "paths"])
  discard dock.addColumn(iconic = true)
  grp(1, 100, ["history", "navigator", "actions", "histogram"])
  grp(1, 100, ["brushes", "brushsettings", "options"])
  grp(1, 100, ["character", "paragraph", "glyphs"])
  grp(1, 100, ["charstyles", "parastyles", "opentype"])
  grp(1, 100, ["info"])
  grp(1, 100, ["styles", "shapes", "toolpresets"])
  grp(1, 100, ["layercomps", "clonesource"])
  grp(1, 100, ["quickactions", "colorthemes"])
  for k in ["scratch", "commands"]: dock.closed.add (pdef(k), 0, 0)

defaultDock()

# (Adjustment Presets: the built-in ones and the user's, kept in the app's folder)
var
  myPresets: seq[AdjPreset]
  presetThumbs: tuple[key: string; pics: seq[Bitmap]]
  presetCat = 0                  ## the Adjustments panel's kind: All, the kinds, My Presets
  adjSaveDlg: tuple[open: bool; name: string]
  presetBatch: tuple[open: bool; preset: int; src, dst: string; format: int; running: bool; done, total: int;
                     files: seq[string]; err: string]
let builtinAdj = builtinPresets()

proc presetsFile(): string = dataDir(AppName) / "Presets" / "Adjustment Presets.radj"

proc loadMyPresets() =
  try: myPresets = loadPresetFile(presetsFile())
  except CatchableError: myPresets = @[]

proc saveMyPresets() =
  try:
    createDir(presetsFile().parentDir)
    if myPresets.len > 0: savePresetFile(presetsFile(), myPresets)
    elif fileExists(presetsFile()): removeFile(presetsFile())
  except CatchableError: discard

proc allPresets(): seq[AdjPreset] = builtinAdj & myPresets
  ## Every adjustment preset: the built-in ones, then the user's.

proc adjPresetDialogs()

var ccDlg: tuple[cleanup, harmonize: bool; cEmpty, cHidden, cGroups, cRename: bool;
                 hIntensity, hShadow, hBright, hSat: int] =
  (false, false, true, false, true, true, 70, 50, 0, 0)
  ## (Layer Cleanup and Harmonize: their dialogs)

proc ccDialogs()
proc exportArtboards(d: Doc)
proc exportSlices(d: Doc)
proc slicesFromGuides(d: Doc)

proc panelShown(key: string): bool = not palettesHidden and dock.panelShown(key)
  ## The panel can be seen now.

proc showPanel(key: string) =
  ## Brings a panel up (Window, a button that asks for it).
  palettesHidden = false
  dock.showPanel(key, pdef(key))

proc togglePanel(key: string) =
  ## Window's panels: shown, closed; closed, shown.
  if panelShown(key): dock.closePanel(key)
  else: showPanel(key)

type AppPrefs = object
  ## What Preferences sets (the toolkit's look and `viewPrefs` aside).
  interp: int                  ## Image Size's resampling: nearest, bilinear, bicubic, Lanczos
  zoomResizes: bool            ## zooming sizes the window to the image
  zoomCenter: bool             ## the Zoom tool brings the clicked point to the middle
  resetOnQuit: bool            ## Preferences back to the defaults at the next start
  docTabs: bool                ## the documents as tabs (the default); off: windows of their own (MDI)
  optionsBar: bool
  history: int                 ## undo steps kept
  autosave: int                ## minutes between recovery saves (0: never)
  bgSave: bool                 ## big documents saved in the background
  recent: int                  ## files in File › Open Recent
  lowerExt: bool               ## file extensions in lower case
  psdComposite: bool           ## PSD: the merged picture too (Maximize Compatibility)
  memory: int                  ## percent of the device's memory Retro Photo may use
  threads: int                 ## 0: one a core
  gpu: int                     ## drawing: 0 automatic, 1 the GPU, 2 the CPU
  scratch: string              ## the scratch disk's folder ("": the default)
  paintCursor: int             ## standard, precise, normal brush tip, full size brush tip
  crosshair: bool              ## a cross in the brush tip
  otherCursor: int             ## standard, precise
  printRes, screenRes: int     ## pixels per inch of new documents for print and screen
  smartQuotes: bool
  workingSpace: int            ## the profile of new documents: none, then the built-in ones
  embedProfile: bool           ## the profile in exported files
  keySet: int                  ## the shortcuts: the usual (0) or Retro Photo 1994's (1)
  toolCols: int                ## the toolbar: 0 as fits, 1 one column, 2 two
  toolHidden: string           ## the toolbar's groups taken off (under "..."), by name
  taskBar: bool                ## the Contextual Task Bar under the image
  legacyXf: bool               ## Use Legacy Free Transform: Shift keeps the proportions
  session: bool                ## the documents open at the end opened again at the next start
  language: int                ## the interface: 0 English, 1 Arabic (right to left)
  legacyNew: bool              ## File > New: the 1994 dialog (not today's, with presets and templates)

const DefaultPrefs = AppPrefs(interp: 2, zoomResizes: false, zoomCenter: false, docTabs: true,
                              optionsBar: true, history: 100, autosave: 10, bgSave: true, recent: 10,
                              lowerExt: true, psdComposite: true, memory: 70, threads: 0,
                              paintCursor: 2, crosshair: false, otherCursor: 1,
                              printRes: 300, screenRes: 72, smartQuotes: true, workingSpace: 1,
                              embedProfile: true, toolCols: 2, taskBar: true, session: true)

var prefs = DefaultPrefs        ## Preferences (photo/prefs)

const
  modernKeys = [
    # File
    ("Ctrl+N", "New..."), ("Ctrl+O", "Open..."), ("Ctrl+W", "Close"), ("Ctrl+Alt+W", "Close All"),
    ("Ctrl+S", "Save"), ("Ctrl+Shift+S", "Save As..."), ("Ctrl+Alt+S", "Save a Copy..."),
    ("Ctrl+Alt+Shift+W", "Export As..."), ("Ctrl+P", "Print..."), ("Ctrl+Q", "Exit"),
    ("Ctrl+K", "General..."), ("Ctrl+Alt+Shift+K", "Keyboard Shortcuts..."),
    # Edit
    ("Ctrl+Z", "Undo"), ("Ctrl+Shift+Z", "Redo"), ("Ctrl+X", "Cut"), ("Ctrl+C", "Copy"), ("Ctrl+Shift+C", "Copy Merged"),
    ("Ctrl+Shift+K", "Color Settings..."),
    ("Ctrl+V", "Paste"), ("Ctrl+Shift+Alt+V", "Paste Into"), ("Shift+F5", "Fill..."),
    ("Shift+Backspace", "Fill..."), ("Ctrl+T", "Free Transform"), ("Ctrl+Shift+T", "Transform Again"),
    ("Ctrl+F", "Search..."), ("Ctrl+Alt+Z", "Toggle Last State"), ("Ctrl+Alt+P", "Close Others"),
    ("F12", "Revert"), ("Ctrl+Alt+Shift+I", "File Info..."),
    # Image
    ("Ctrl+L", "Levels..."), ("Ctrl+M", "Curves..."), ("Ctrl+U", "Hue/Saturation..."),
    ("Ctrl+B", "Color Balance..."), ("Ctrl+Alt+Shift+B", "Black & White..."), ("Ctrl+I", "Invert"),
    ("Ctrl+Shift+U", "Desaturate"), ("Ctrl+Shift+L", "Auto Tone"), ("Ctrl+Alt+Shift+L", "Auto Contrast"),
    ("Ctrl+Shift+B", "Auto Color"), ("Ctrl+Alt+I", "Image Size..."), ("Ctrl+Alt+C", "Canvas Size..."),
    # Layer
    ("Ctrl+Shift+N", "New Layer..."), ("Ctrl+J", "Layer via Copy"), ("Ctrl+Shift+J", "Layer via Cut"),
    ("Ctrl+G", "Group Layers"), ("Ctrl+Shift+G", "Ungroup Layers"), ("Ctrl+Alt+G", "Toggle Clipping Mask"),
    ("Ctrl+E", "Merge Down"), ("Ctrl+Shift+E", "Merge Visible"), ("Ctrl+/", "Lock Layer"),
    ("Ctrl+Shift+]", "Bring to Front"), ("Ctrl+]", "Bring Forward"), ("Ctrl+[", "Send Backward"),
    ("Ctrl+Shift+[", "Send to Back"), ("Ctrl+,", "Hide Layers"), ("Ctrl+Alt+A", "All Layers"),
    ("Alt+]", "Select Layer Above"), ("Alt+[", "Select Layer Below"),
    ("Ctrl+Alt+Shift+E", "Stamp Visible"), ("Alt+Backspace", "Fill with Foreground Color"),
    ("Ctrl+Backspace", "Fill with Background Color"), ("Ctrl+Shift+D", "Reselect"),
    # Select
    ("Ctrl+A", "All"), ("Ctrl+D", "None"), ("Ctrl+Shift+I", "Inverse"), ("Shift+F6", "Feather..."),
    ("Ctrl+Alt+R", "Select and Mask..."),
    # Filter
    ("Ctrl+Alt+F", "Last Filter"), ("Ctrl+Shift+A", "Develop..."), ("Ctrl+Shift+X", "Liquify..."),
    ("Ctrl+Shift+R", "Lens Correction..."),
    # View
    ("Ctrl+Y", "CMYK Preview"), ("Ctrl+Shift+Y", "Gamut Warning"), ("Ctrl+Plus", "Zoom In"),
    ("Ctrl+Equal", "Zoom In"), ("Ctrl+Minus", "Zoom Out"), ("Ctrl+0", "Fit on Screen"), ("Ctrl+1", "Actual Pixels"),
    ("Ctrl+Alt+0", "Actual Pixels"), ("Ctrl+H", "Hide Edges"), ("Ctrl+R", "Show Rulers"), ("Ctrl+;", "Show Guides"),
    ("Ctrl+'", "Show Grid"), ("Ctrl+Shift+;", "Snap"), ("Ctrl+Alt+;", "Lock Guides"),
    # Window, Help
    ("F6", "Picker"), ("F7", "Layers"), ("F8", "Info"), ("Alt+F9", "Actions"), ("F1", "Contents")]
    ## the usual shortcuts (Windows; Cmd for Ctrl on a Mac)
  retroKeys = [
    ("Ctrl+N", "New..."), ("Ctrl+O", "Open..."), ("Ctrl+W", "Close"), ("Ctrl+S", "Save"),
    ("Ctrl+P", "Print..."), ("Ctrl+K", "General..."), ("Ctrl+Q", "Exit"), ("Ctrl+Alt+Shift+K", "Keyboard Shortcuts..."),
    ("Ctrl+Z", "Undo"), ("Ctrl+Shift+Z", "Redo"), ("Ctrl+X", "Cut"), ("Ctrl+C", "Copy"),
    ("Ctrl+V", "Paste"), ("Shift+Backspace", "Fill..."),
    ("Ctrl+I", "Invert"), ("Ctrl+T", "Threshold..."), ("Ctrl+L", "Levels..."),
    ("Ctrl+M", "Curves..."), ("Ctrl+B", "Brightness/Contrast..."), ("Ctrl+Y", "Color Balance..."),
    ("Ctrl+U", "Hue/Saturation..."), ("Ctrl+Shift+L", "Auto Tone"),
    ("Ctrl+Alt+Shift+L", "Auto Contrast"), ("Ctrl+Shift+B", "Auto Color"),
    ("Ctrl+Alt+Shift+B", "Black & White..."), ("Ctrl+Shift+A", "Develop..."),
    ("Ctrl+Shift+X", "Liquify..."), ("Ctrl+Shift+R", "Lens Correction..."), ("Ctrl+Alt+V", "Vanishing Point..."),
    ("Ctrl+Shift+U", "Desaturate"), ("Ctrl+F", "Last Filter"),
    ("Ctrl+A", "All"), ("Ctrl+D", "None"), ("Ctrl+Shift+I", "Inverse"),
    ("Ctrl+Shift+D", "Feather..."), ("Ctrl+G", "Group Layers"), ("Ctrl+H", "Hide Edges"),
    ("Ctrl+Shift+G", "Ungroup Layers"), ("Ctrl+Shift+]", "Bring to Front"),
    ("Ctrl+]", "Bring Forward"), ("Ctrl+[", "Send Backward"), ("Ctrl+Shift+[", "Send to Back"),
    ("Ctrl+/", "Lock Layer"), ("Ctrl+E", "Merge Down"), ("Ctrl+Shift+E", "Merge Visible"),
    ("Ctrl+Alt+R", "Select and Mask..."), ("Ctrl+;", "Show Guides"), ("Ctrl+'", "Show Grid"),
    ("Ctrl+Shift+;", "Snap"), ("Ctrl+Alt+;", "Lock Guides"), ("Ctrl+Alt+Z", "Step Backward"),
    ("Ctrl+Shift+Alt+Z", "Step Forward"), ("Ctrl+Shift+N", "New Layer..."),
    ("Ctrl+J", "Layer via Copy"), ("Ctrl+Shift+J", "Layer via Cut"),
    ("Shift+F5", "Cascade"), ("Shift+F4", "Tile"), ("Ctrl+R", "Show Rulers"),
    ("Ctrl+Plus", "Zoom In"), ("Ctrl+Equal", "Zoom In"), ("Ctrl+Minus", "Zoom Out"),
    ("Ctrl+0", "Fit on Screen"), ("Ctrl+Alt+0", "Actual Pixels"), ("F1", "Contents"),
    ("Ctrl+Alt+Shift+W", "Export As..."), ("Ctrl+Alt+G", "Toggle Clipping Mask"),
    ("Ctrl+Alt+Y", "CMYK Preview"), ("Ctrl+Shift+Y", "Gamut Warning")]
    ## Retro Photo 1994's (1994's, where it had them)

var
  keymap: Keymap                 ## the shortcuts in use (Edit > Keyboard Shortcuts)
  mappedCmds: HashSet[string]    ## (the commands the keymap has)

proc applyKeySet() =
  keymap.defaults.setLen(0)
  for (k, c) in (if prefs.keySet == 1: @retroKeys else: @modernKeys): keymap.defaults.add (k, c)
  mappedCmds.clear()
  for c in keymap.commandsOf: mappedCmds.incl c

applyKeySet()

proc smartQuote(s: string; before: string): string =
  ## Typed quotes made curly (Type: Use Smart Quotes): opening after a
  ## space or at the start, closing (or an apostrophe) after a letter.
  if not prefs.smartQuotes: return s
  var prev = if before.len > 0: before[^1] else: ' '
  for c in s:
    case c
    of '"':
      result.add (if prev in {' ', '\t', '\n', '(', '[', '{'} or ord(prev) == 0: "“" else: "”")
    of '\'':
      result.add (if prev in {' ', '\t', '\n', '(', '[', '{'} or ord(prev) == 0: "‘" else: "’")
    else: result.add c
    prev = c

proc typeFirst() =
  ## The dialog being opened: its first box takes the keys -- with a
  ## keyboard; on a touch screen the on-screen one would cover half of it,
  ## so it comes up only when a box is tapped.
  if not ui.touch: focusFirstText(inDialog = true)

proc initSwatches() =
  for c in [0xFF0000, 0xFFFF00, 0x00FF00, 0x00FFFF, 0x0000FF, 0xFF00FF,
            0xFF8080, 0xFFFF80, 0x80FF80, 0x80FFFF, 0x8080FF, 0xFF80FF,
            0x800000, 0x808000, 0x008000, 0x008080, 0x000080, 0x800080,
            0xFF8000, 0x80FF00, 0x00FF80, 0x0080FF, 0x8000FF, 0xFF0080,
            0x804000, 0x408000, 0x004080, 0x400080, 0xC08040, 0x40C080]:
    swatches.add 0xFF000000'u32 or uint32(c)
  for k in 0 .. 11:
    let v = 255 - k * 255 div 11
    swatches.add argb(255, v, v, v)

proc initOpts() =
  for t in Tool:
    opts[t] = ToolOpts(mode: 0, opacity: 100, tip: hardTip(13), preset: "Hard Round")
  opts[tAirbrush].opacity = 50
  opts[tAirbrush].tip = softTip(45)
  opts[tSmudge].opacity = 50
  opts[tBlur].opacity = 50
  opts[tDodge].opacity = 50
  opts[tPencil].tip = hardTip(1)
  opts[tEraser].tip = softTip(17)
  opts[tStamp].tip = softTip(13)
  opts[tBrush].tip = softTip(21)
  opts[tHeal].tip = softTip(27)
  for t in [tAirbrush, tEraser, tStamp, tBrush, tHeal]: opts[t].preset = "Soft Round"
  opts[tPencil].preset = ""

proc modeNames(): seq[string] =
  for m in PaintModes: result.add $m

proc layerModeNames(): seq[string] =
  for m in LayerModes: result.add $m

# ---- documents ----------------------------------------------------------------------------------------

proc title(dw: DocWin): string =
  let d = dw.doc
  let m = case d.mode
          of cmRGB: "RGB"
          of cmGray: "Gray"
          of cmIndexed: "Index"
          of cmBitmap: "Bitmap"
          of cmCMYK: "CMYK"
          of cmLab: "Lab"
          of cmDuotone: "Duotone"
          of cmMultichannel: "Multichannel"
  var t = d.name & " (" & (if d.quickMask: "Quick Mask, " else: "") &
          (if d.proof and d.mode != cmCMYK: "Proof, " else: "") &
          (if d.layers.len > 1: d.layer.name & ", " else: "") & m & "/" & $(if d.depth in [16, 32]: d.depth else: 8) & ", " &
          zoomText(dw.view.zoom) & ")"
  if d.modified: t.add " *"
  t

proc tabArea(): Rect =
  ## Where the tabbed documents go in the area: all the room between the
  ## toolbar and the panels, top to bottom, as the usual (all of the
  ## area in the full screen modes).
  let a = mdiAreaRect("ws")
  if screenMode > 0: return rect(0, 0, a.w, a.h)
  let left = if toolbox.open and not palettesHidden: toolbox.r.x + toolbox.r.w + dp(2) else: 0
  let right = if palettesHidden or docsRight <= 0: a.w else: docsRight - dp(2)
  rect(left, 0, max(dp(200), right - left), max(dp(120), a.h))

proc placeWindow(dw: DocWin) =
  ## A new window: as big as the image (at a ratio that fits), cascaded; a
  ## new tab: the image at a ratio that fits the tabs' window.
  let a = mdiAreaRect("ws")
  if a.w <= 0: return               # (the area is not drawn yet: at the next frame)
  dw.placed = true
  if not dw.floating:
    let t = tabArea()
    let z = min(1, fitZoom(dw.doc, (t.w - SbW - dp(8)) * pxScale, (t.h - SbW - CtrlH - dp(12)) * pxScale))
    dw.view = initPhotoView()
    dw.view.zoom = z
    dw.view.fitWanted = false
    return
  let n = max(0, docs.find(dw))
  let (fw, fh) = mdiWindowSize(SbW, SbW)         # (the frame, the title, the scroll bars)
  let right = if docsRight > 0: docsRight else: a.w - dp(250)
  let roomW = max(dp(200), right - dp(84) - dp(4) - (n mod 6) * dp(24) - fw)
  let roomH = max(dp(160), a.h - dp(16) - (n mod 6) * dp(24) - fh)
  let z = min(1, fitZoom(dw.doc, roomW * pxScale, roomH * pxScale))   # (no bigger than 1:1)
  let k = if z >= 1: z.float else: 1 / (-z).float
  let iw = int(dw.doc.w.float * k / pxScale.float)
  let ih = int(dw.doc.h.float * k / pxScale.float)
  let (ww, wh) = mdiWindowSize(iw + SbW + 2, ih + SbW + 2)
  dw.win.r = rect(dp(84) + (n mod 6) * dp(24), dp(8) + (n mod 6) * dp(24),
                  max(dp(220), ww), max(dp(160), wh))
  dw.view = initPhotoView()
  dw.view.zoom = z
  dw.view.fitWanted = false

proc fitWindow(dw: DocWin) =
  ## After the image changed size (Crop, Image Size...): the window fits it
  ## again where it is, at a ratio that fits the area.
  let a = mdiAreaRect("ws")
  if a.w <= 0 or dw.win.maximized or not dw.floating:
    dw.view.fitWanted = true
    return
  let (fw, fh) = mdiWindowSize(SbW, SbW)
  let right = if docsRight > 0: docsRight else: a.w - dp(250)
  let roomW = max(dp(200), right - dw.win.r.x - dp(4) - fw)
  let roomH = max(dp(160), a.h - dw.win.r.y - dp(4) - fh)
  let z = min(1, fitZoom(dw.doc, roomW * pxScale, roomH * pxScale))   # (no bigger than 1:1)
  let k = if z >= 1: z.float else: 1 / (-z).float
  let iw = int(dw.doc.w.float * k / pxScale.float)
  let ih = int(dw.doc.h.float * k / pxScale.float)
  let (ww, wh) = mdiWindowSize(iw + SbW + 2, ih + SbW + 2)
  dw.win.r.w = max(dp(220), ww)
  dw.win.r.h = max(dp(160), wh)
  dw.view.zoom = z
  dw.view.offX = 0
  dw.view.offY = 0
  dw.view.fitWanted = false

proc addDoc(d: Doc) =
  let dw = DocWin(doc: d, win: MdiWindow(title: d.name, open: true, flush: true, grip: true),
                  floating: not prefs.docTabs)
  docs.add dw
  dw.placeWindow()
  active = dw
  if not dw.floating:
    tabCur = dw
    mdiActivate(tabWin, "ws")
  else:
    mdiActivate(dw.win, "ws")      # (a new window comes to the front)

proc keepDocMode() =
  ## Every document as the workspace has them: all tabs, or (MDI) all
  ## windows of their own -- one reopened by the session, made another
  ## way, comes to the same.
  for dw in docs:
    if dw.floating == prefs.docTabs:
      dw.floating = not prefs.docTabs
      dw.win.maximized = false
      dw.placed = false
      if dw == active and prefs.docTabs: tabCur = dw

proc floatDoc(dw: DocWin; atMouse = false) =
  ## A tab in a window of its own (Window › Arrange › Float in Window, or
  ## a tab dragged off the strip).
  if dw.floating: return
  dw.floating = true
  dw.placeWindow()
  if atMouse:
    let a = mdiAreaRect("ws")
    dw.win.r.x = clamp(ui.mx - a.x - dw.win.r.w div 3, 0, max(0, a.w - dp(80)))
    dw.win.r.y = clamp(ui.my - a.y - dp(10), 0, max(0, a.h - dp(40)))
  active = dw
  mdiActivate(dw.win, "ws")

proc dockDoc(dw: DocWin) =
  ## A floating window made a tab (Consolidate All to Tabs, or dropped on
  ## the tabs).
  if not dw.floating: return
  dw.floating = false
  dw.win.maximized = false
  dw.placeWindow()
  tabCur = dw
  active = dw
  mdiActivate(tabWin, "ws")

proc showDoc(dw: DocWin) =
  ## `dw` in front: its tab chosen, or its window raised.
  active = dw
  if dw.floating: mdiActivate(dw.win, "ws")
  else:
    tabCur = dw
    mdiActivate(tabWin, "ws")

proc savePrefs()

proc setDocMode(tabs: bool) =
  ## The workspace's documents: tabs (the default, as the usual), or each
  ## in a window of its own (MDI, as in 1994). Kept in the preferences.
  if prefs.docTabs == tabs: return
  prefs.docTabs = tabs
  let was = active
  for dw in docs:
    if tabs: dw.dockDoc() else: dw.floatDoc()
  if was != nil and was in docs:
    was.showDoc()
    showNext = was                 # (again when the new windows have their places)
    showNextAt = ui.frameNo + 2
  savePrefs()

proc newUntitled(w, h: int; contents: uint32; dpi = 72.0; mode = cmRGB; name = ""; depth = 8): Doc =
  ## A new image in color mode `mode` (Bitmap, Grayscale, RGB, CMYK, Lab).
  inc untitled
  result = newDoc(w, h, contents, dpi, if name.len > 0: name else: "Untitled-" & $untitled)
  case mode
  of cmGray: result.toGrayscale()
  of cmBitmap:
    result.toGrayscale()
    result.toBitmapMode(dither = false)
  of cmCMYK: result.toCMYK()
  of cmLab: result.toLab()
  else: discard
  result.mode = mode
  if depth == 16: result.setDepth(16)
  result.modified = false
  result.clearHistory()

proc cur(): Doc = (if active != nil: active.doc else: nil)

# (in photo/dialogs)
proc startCameraRaw(raw: RawImage)

# (in photo/prefs)
proc afterZoom(dw: DocWin; x, y: float; byTool: bool)

# (in photo/recovery)
proc writeSession()

# (in photo/pspanels)
proc layerCompDialog()

# (in photo/neural)
proc neuralDialog()
proc startNeural()

# (in photo/pdfexport)
proc pdfDialogs()
proc startPdfOptions(docs: seq[Doc]; path: string)
proc startPdfPresentation()
proc importDialogs()
proc startPdfImport(path: string)
proc startEpsOptions(dw: DocWin; path: string)

# (in photo/fontget)
proc getFontsDialog()
proc startGetFonts()

# (in photo/pscc)
proc pathValueDialog()

# (in photo/brushpanel)
proc brushDragOn(dw: DocWin; ev: PhotoEvent): bool

var hud: tuple[on: bool; x, y: int; h, s, v: float; zone: int; touch: bool]
  ## the color picker on the canvas (as the usual HUD)

proc hudPickerOn(dw: DocWin; ev: PhotoEvent): bool =
  ## Alt+Shift + the right button held on the image with a painting tool (a
  ## long press on a touch screen): a square of shades and a strip of hues
  ## where it was pressed; moving picks the foreground color; letting go
  ## keeps it (true while it is shown).
  if tool notin brushTools + {tBucket, tGradient, tShape, tType}: return false
  if not hud.on:
    if ev.over and ev.right and ((AltPressed in ui.mods and ShiftPressed in ui.mods) or
                                 (fingers() and ui.mods == {} and not drag.on)):
      let c = toHsb(fg)
      hud = (true, ui.mx, ui.my, c.h, c.s, c.b, 0, fingers())
      return true
    return false
  if not ui.rmouseDown and not ui.mouseDown and not ui.rpressed:
    hud.on = false
    status = "Foreground color picked on the canvas"
    return false
  let (sq, st) = hudPickerRects(hud.x, hud.y, dw.view.view)
  if hudPick(sq, st, ui.mx, ui.my, hud.h, hud.s, hud.v, hud.zone):
    fg = fromHsb(hud.h, hud.s, hud.v)
  drawHudPicker(sq, st, hud.h, hud.s, hud.v)
  ui.cursor = curCrosshair
  ui.redraw = true
  true

# (in photo/presetfiles)
type PresetFor = enum
  pfAny = "Presets", pfSwatches = "Swatches", pfCurves = "Curves", pfLevels = "Levels",
  pfGradients = "Gradients", pfPatterns = "Patterns", pfAdjust = "Adjustment Presets"
proc startPresetFile(f: PresetFor; save = false; replace = false)

# (in photo/smartobj)
proc renderSmartLayer(d: Doc; L: Layer)
proc smartOk(name: string): bool
proc addSmartFilter(d: Doc; name: string; vals: seq[float]): bool
proc saveSmartChild(dw: DocWin): bool
proc editSmartFilter(d: Doc; L: Layer; k: int)
proc placeSmart(d: Doc; path: string)
proc modeOn(dw: DocWin): bool
proc modeMouse(dw: DocWin; ev: PhotoEvent)
proc modeOverlay(dw: DocWin)
proc modeFinish(ok: bool)

# (in photo/gradients)
proc startFillLayer(kind: ShapePaintKind; L: Layer = nil)
proc startGradientEditor(target: int; stops: seq[GradientStop])
proc gradientPresets(): seq[tuple[name: string; stops: seq[GradientStop]]]
proc toolStops(): seq[GradientStop]

proc dropRecovery(dw: DocWin)

proc closeDoc(dw: DocWin) =
  dw.dropRecovery()
  let i = docs.find(dw)
  if i >= 0: docs.delete(i)
  if tabCur == dw:
    # (the tab beside it, as is usual)
    tabCur = nil
    for k in countdown(min(i, docs.len) - 1, 0):
      if not docs[k].floating:
        tabCur = docs[k]
        break
    if tabCur == nil:
      for o in docs:
        if not o.floating:
          tabCur = o
          break
  if active == dw: active = (if tabCur != nil: tabCur elif docs.len > 0: docs[^1] else: nil)
  if docs.len == 0: releaseGpuComposite()   # (the layers' textures let go)

# ---- colors -------------------------------------------------------------------------------------------

var histSource: tuple[snap: bool; idx: int]   ## what the History Brush paints from (a snapshot or a state)

proc historySourcePixels(d: Doc; L: Layer): seq[uint32] =
  ## The History Brush's source for layer `L`: the snapshot, or the state,
  ## marked in the History palette (empty: it was not there).
  if histSource.snap: d.snapshotPixels(L, histSource.idx)
  else: d.statePixels(L, histSource.idx)

proc savedPixels(d: Doc; fromFile: bool): seq[uint32] =
  ## What the image goes back to: the snapshot (of this layer) or the
  ## state marked in the History palette, or the file as last saved (when
  ## it is the image's size).
  if not fromFile:
    return d.historySourcePixels(d.layer)
  if d.path.len == 0 or not fileExists(d.path): return
  let t = try: getLastModificationTime(d.path).toUnixFloat except OSError: 0.0
  if savedCache.path != d.path or savedCache.time != t:
    try:
      let o = openPicture(d.path)
      savedCache = (d.path, t, o.w, o.h, o.flattened())
    except CatchableError:
      savedCache = (d.path, t, 0, 0, @[])
  if savedCache.w == d.w and savedCache.h == d.h: savedCache.px else: @[]

proc grayOf(c: uint32): uint32 =
  ## A color as the gray of its lightness (painted on a mask).
  let l = uint32((int((c shr 16) and 255) * 77 + int((c shr 8) and 255) * 150 + int(c and 255) * 29) shr 8)
  (c and 0xFF000000'u32) or (l * 0x010101'u32)

proc onMask(d: Doc): bool =
  ## Painting goes on a mask (a layer mask, the Quick Mask): in grays.
  d != nil and (d.editMask or d.quickMask)

proc paintOpts(t: Tool; d: Doc): PaintOpts =
  let o = opts[t]
  let fg = if d.onMask: grayOf(fg) else: fg
  let bg = if d.onMask: grayOf(bg) else: bg
  result = PaintOpts(color: fg, bg: bg, opacity: o.opacity, mode: PaintModes[clamp(o.mode, 0, PaintModes.high)],
                     fade: o.fade, fadeToBg: o.fadeToBg, wet: o.wet, autoErase: o.autoErase,
                     finger: o.finger, pattern: pattern, pw: patternW, ph: patternH,
                     sizeByPressure: o.sizeByPressure, opacityByPressure: o.opacityByPressure, dyn: o.dyn,
                     blockSize: max(4, int(16 / (if active != nil: active.view.scaleOf else: 1.0))))
  result.tool = case t
                of tBrush: (if brushTool == 1: tkMixer else: tkBrush)
                of tEraser: tkEraser
                of tPencil: tkPencil
                of tAirbrush: tkAirbrush
                of tStamp: tkStamp
                of tSmudge: tkSmudge
                of tBlur: (if blurMode == 0: tkBlur else: tkSharpen)
                of tDodge: [tkDodge, tkBurn, tkSponge][dodgeMode]
                else: tkBrush
  result.dyn.symmetry = SymmetryKind(clamp(symmetry, 0, ord(SymmetryKind.high)))
  result.dyn.axes = symAxes
  result.wetness = mixWet
  result.load = mixLoad
  result.mixRatio = mixRatio
  # the texture (the pattern's grain) and the dual brush
  let dy = o.dyn
  if dy.textureOn and pattern.len > 0 and patternW > 0:
    result.tw = patternW
    result.th = patternH
    result.texture = newSeq[uint8](pattern.len)
    for i, p in pattern: result.texture[i] = uint8(lumaOf(p))
    result.textureDepth = if dy.textureDepth <= 0: 100 else: dy.textureDepth
    result.textureScale = dy.textureScale
    result.textureInvert = dy.textureInvert
  if dy.dualBrush > 0 and dy.dualBrush <= presets.len:
    result.dual = presets[dy.dualBrush - 1].tip
    result.dualScatter = dy.dualScatter
  result.eraseMode = EraserMode(eraserMode)
  if t == tBrush and brushTool == 2:
    result.colorReplace = true
    result.mode = [bmHue, bmSaturation, bmColor, bmLuminosity][clamp(crMode, 0, 3)]
    result.bgTolerance = crTol
    result.bgSampling = crSampling
    result.bgLimits = crLimits
  if t == tEraser and eraseKind == 2:
    result.bgErase = true
    result.eraseMode = emPaintbrush
    result.bgTolerance = bgEraseTol
    result.bgSampling = bgEraseSampling
    result.bgLimits = bgEraseLimits
    result.bgProtectFg = bgEraseProtect
  result.tone = ToneRange(dodgeTone)
  result.saturate = spongeMode == 1
  result.stamp = StampMode(stampMode)
  if stampSrc.set:
    result.srcX = stampSrc.x
    result.srcY = stampSrc.y
  if t == tStamp and stampTool >= 1:
    # the History Brush: back to the state (or snapshot) marked in the History palette
    result.stamp = smFromSnapshot
    result.saved = d.historySourcePixels(d.layer)
    if result.saved.len == 0:
      status = "The layer was not there then (History palette: mark another state)"
  elif t == tStamp and StampMode(stampMode) in {smFromSnapshot, smFromSaved}:
    result.saved = d.savedPixels(StampMode(stampMode) == smFromSaved)
    if result.saved.len == 0:
      status = if StampMode(stampMode) == smFromSaved: "The file as saved is not there (or not this size)"
               else: "The layer was not in the snapshot (History palette)"
  if t == tEraser and eraseToSaved:
    result.eraseToSaved = true
    result.saved = d.savedPixels(true)
    if result.saved.len == 0: status = "The file as saved is not there (or not this size)"

proc tipFor(t: Tool): BrushTip = opts[t].tip

# ---- the selection, drawn while dragging ------------------------------------------------------------

proc selOpFor(ev: PhotoEvent): SelOp =
  if not (ev.shift or ev.alt or ev.ctrl) and touchSelMode > 0: return SelOp(touchSelMode)
  if ev.shift and ev.alt: soIntersect
  elif ev.shift: soAdd
  elif ev.alt or ev.ctrl: soSubtract
  else: soReplace

proc constrained(x0, y0, x1, y1: float; square: bool): (float, float) =
  var dx = x1 - x0
  var dy = y1 - y0
  if square:
    let m = max(abs(dx), abs(dy))
    dx = (if dx < 0: -m else: m)
    dy = (if dy < 0: -m else: m)
  if marqueeStyle == 1 and marqueeW > 0 and marqueeH > 0:
    let k = max(abs(dx) / marqueeW.float, abs(dy) / marqueeH.float)
    dx = (if dx < 0: -1.0 else: 1.0) * k * marqueeW.float
    dy = (if dy < 0: -1.0 else: 1.0) * k * marqueeH.float
  (x0 + dx, y0 + dy)

proc marqueeBox(): (float, float, float, float) =
  var (x0, y0, x1, y1) = (drag.x0, drag.y0, drag.x1, drag.y1)
  if drag.center and marqueeStyle != 2:
    # (Alt: from the middle out)
    (x0, y0) = (2 * drag.x0 - drag.x1, 2 * drag.y0 - drag.y1)
  if marqueeStyle == 2:
    (x0, y0) = (x1, y1)
    x1 = x0 + marqueeW.float
    y1 = y0 + marqueeH.float
  (min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1))

proc finishSelection(d: Doc; m: var seq[uint8]; feather: int; name: string) =
  if feather > 0: blurMask(m, d.w, d.h, feather.float)
  d.beginStep(name)
  d.touchSel()
  d.setSelection(m, drag.op)
  if d.hasSelection and d.selectionEmpty: d.selectNone()
  d.endStep()

# ---- the Adjustment Brush: an adjustment painted where it is wanted -----------------------------------

const adjBrushPresets = ["Brightness", "Contrast", "Exposure", "Saturation", "Vibrance", "Warmth",
                         "Clarity", "Dehaze", "Black & White", "Invert"]
  ## (the Adjustment Brush's adjustments, as the usual: each an adjustment
  ## layer whose mask is what is painted)

proc adjBrushAdjustment(k, amount: int): Adjustment =
  ## The adjustment preset `k` makes at `amount` (-100..100); its `data`
  ## names it, so the next strokes go on the same layer.
  let a = clamp(amount, -100, 100).float
  let name = adjBrushPresets[clamp(k, 0, adjBrushPresets.high)]
  result = case name
    of "Brightness": Adjustment(kind: "Brightness/Contrast", args: @[a * 1.5, 0.0])
    of "Contrast": Adjustment(kind: "Brightness/Contrast", args: @[0.0, a])
    of "Exposure": Adjustment(kind: "Exposure", args: @[a / 50, 0.0, 1.0])
    of "Saturation":
      var args = newSeq[float](22)
      args[2] = a                               # (the master's saturation)
      Adjustment(kind: "Hue/Saturation", args: args)
    of "Vibrance": Adjustment(kind: "Vibrance", args: @[a, 0.0])
    of "Warmth": Adjustment(kind: "Color Balance", args: @[0.0, 0.0, 0.0, a * 0.5, 0.0, -a * 0.5, 0.0, 0.0, 0.0, 1.0])
    of "Clarity": Adjustment(kind: "Clarity", args: @[a])
    of "Dehaze": Adjustment(kind: "Dehaze", args: @[a])
    of "Black & White": Adjustment(kind: "Black & White")
    else: Adjustment(kind: "Invert")
  result.data = "brush:" & name

proc adjBrushLayer(d: Doc): bool =
  ## (the current layer is the Adjustment Brush's, of the adjustment chosen)
  let L = d.current
  L.adjust.kind.len > 0 and L.adjust.data == "brush:" & adjBrushPresets[clamp(adjBrushKind, 0, adjBrushPresets.high)]

proc adjBrushPress(dw: DocWin; ev: PhotoEvent) =
  ## The Adjustment Brush pressed: on its adjustment layer (a new one -- its
  ## mask black, nothing changed yet -- unless the current layer is it), a
  ## stroke in white (Alt or Subtract: black) on the mask.
  let d = dw.doc
  d.beginStep("Adjustment Brush")
  if not d.adjBrushLayer:
    let L = d.newAdjustmentLayer(adjBrushAdjustment(adjBrushKind, adjBrushAmount),
                                 adjBrushPresets[clamp(adjBrushKind, 0, adjBrushPresets.high)] & " (brush)")
    for i in 0 ..< L.px.len: L.px[i] = grayPx(0)
    inc L.ver
    d.markAll()
  d.editMask = false
  var o = paintOpts(tBrush, d)
  o.tool = tkBrush
  o.mode = bmNormal
  o.colorReplace = false
  o.color = if adjBrushSub != ev.alt: grayPx(0) else: grayPx(255)
  drag.stroke = d.beginStroke(o, tipFor(tBrush), ev.x, ev.y, ui.pressure)
  drag.stroke.penPose(ui.tilt, ui.azimuth, ui.twist)
  drag.stroke.startStroke()
  dw.lastPaint = (ev.x, ev.y)
  dw.hasLastPaint = true
  drag.smx = ev.x
  drag.smy = ev.y
  status = "Adjustment Brush: " & adjBrushPresets[clamp(adjBrushKind, 0, adjBrushPresets.high)] &
           " painted (Alt: taken away); its layer's mask is what was painted"

proc adjBrushChanged() =
  ## (the amount or the adjustment changed: the Adjustment Brush's layer, if it
  ## is the current one, follows)
  let d = cur()
  if d == nil or not d.adjBrushLayer: return
  d.beginStep("Adjustment Brush")
  d.setAdjustment(d.current, adjBrushAdjustment(adjBrushKind, adjBrushAmount))
  d.endStep()

# ---- Content-Aware Tracing: the picture's edges made paths -----------------------------------------------

var
  traceDetail = 50                 ## Content-Aware Tracing: how many edges (1..100: the faint ones too)
  traceMode = 1                    ## ... the path: Detailed, Normal, Simplified (fewer points)
  traceMap: tuple[d: Doc; key: int; m: EdgeMap]   ## (the edges of the picture as it looks)
  traceHover = -1                  ## (the edge under the pointer)
  traceLast: tuple[d: Doc; x, y: float; on: bool] ## (where the last stretch traced ended: Shift+click goes on)

proc traceKey(d: Doc): int =
  ## (changes when the picture's pixels change, not with its paths)
  # (wrapping: a picture of many layers goes past any int)
  template u(x: untyped): uint64 = cast[uint64](int64(x))
  var h = u(d.layers.len) * 1_000_003'u64 + u(traceDetail) * 7919'u64 + u(d.w) * 31'u64 + u(d.h)
  for L in d.layers:
    h = h * 31'u64 + u(L.ver) + u(ord(L.visible)) * 17'u64 + u(L.opacity) * 3'u64
  int(h and uint64(high(int)))

proc traceEdges(d: Doc): EdgeMap =
  ## The edges of the picture as it looks (found once while it is unchanged).
  let k = d.traceKey
  if traceMap.m == nil or traceMap.d != d or traceMap.key != k:
    beginBusy("Finding the edges")
    try:
      d.updateComposite()
      let b = newBitmap(d.w, d.h)
      let src = d.compPtr
      for i in 0 ..< b.px.len: b.px[i] = src[i]
      traceMap = (d, k, newEdgeMap(b, traceDetail))
    finally: endBusy()
  traceMap.m

proc traceRadius(dw: DocWin): float =
  ## (how near the pointer an edge is taken: a few screen pixels)
  float(if finger(): dp(16) else: dp(8)) * pxScale.float / max(1e-6, dw.view.scaleOf)

proc tracePress(dw: DocWin; ev: PhotoEvent) =
  ## A click with Content-Aware Tracing: the edge lit up becomes a subpath
  ## of the work path; Shift+click: the stretch of that edge from where the
  ## last one ended to the click (the path goes on along it).
  let d = dw.doc
  let m = d.traceEdges()
  let i = m.chainAt(ev.x, ev.y, dw.traceRadius)
  if i < 0:
    status = "No edge here: point at an edge of the picture (it lights up), then click"
    return
  var pts: seq[(float, float)]
  var closed = false
  if ev.shift and traceLast.on and traceLast.d == d:
    pts = m.chainPart(i, traceLast.x, traceLast.y, ev.x, ev.y)
  else:
    pts = m.chainPoints(i)
    closed = m.chainClosed(i)
  if pts.len < 2: return
  let sub = fitPath(pts, [1.0, 2.0, 4.0][clamp(traceMode, 0, 2)], closed, cornerAngle = 70)
  if sub.pts.len < 2: return
  d.beginStep("Content-Aware Tracing")
  d.touchPaths()
  if d.curPath < 0 or d.curPath >= d.paths.len:
    d.paths.add Path(name: "Work Path")
    d.curPath = d.paths.high
  d.paths[d.curPath].subs.add sub
  inc d.ver
  d.endStep()
  traceLast = (d, pts[^1][0], pts[^1][1], true)
  status = "Traced: " & $sub.pts.len & " points (Shift+click on along an edge; the Paths panel has it)"

proc traceOverlay(dw: DocWin; ev: PhotoEvent) =
  ## The edge under the pointer, lit up (blue, edged in white).
  let d = dw.doc
  if not ev.over or ui.mouseDown:
    traceHover = -1
    return
  let m = d.traceEdges()
  traceHover = m.chainAt(ev.x, ev.y, dw.traceRadius)
  if traceHover < 0: return
  let pts = m.chainPoints(traceHover)
  let v = dw.view
  # (every few points: a long edge drawn quickly)
  let stepN = max(1, pts.len div 600)
  var prev = v.toScreen(d, pts[0][0], pts[0][1])
  var k = stepN
  while k <= pts.high + stepN - 1:
    let p = pts[min(k, pts.high)]
    let cur = v.toScreen(d, p[0], p[1])
    thickLine(prev[0].float, prev[1].float, cur[0].float, cur[1].float, float(dp(4)), color(255, 255, 255))
    prev = cur
    k += stepN
  prev = v.toScreen(d, pts[0][0], pts[0][1])
  k = stepN
  while k <= pts.high + stepN - 1:
    let p = pts[min(k, pts.high)]
    let cur = v.toScreen(d, p[0], p[1])
    thickLine(prev[0].float, prev[1].float, cur[0].float, cur[1].float, float(dp(2)), color(0, 120, 255))
    prev = cur
    k += stepN

proc selBrushStamp(d: Doc; cx, cy: float; sub: bool) =
  ## The Selection Brush's dab at `cx`, `cy`: painted into the selection
  ## (soft at its edge, by its hardness) -- or, `sub`, taken out of it.
  if not d.hasSelection: return
  let r = max(0.5, quickSize.float / 2)
  let inner = r * clamp(selBrushHard, 0, 100).float / 100
  for yy in max(0, int(cy - r)) .. min(d.h - 1, int(cy + r)):
    for xx in max(0, int(cx - r)) .. min(d.w - 1, int(cx + r)):
      let dist = hypot(xx.float + 0.5 - cx, yy.float + 0.5 - cy)
      if dist > r: continue
      let a = if dist <= inner: 255 else: int(255 * (r - dist) / max(1e-6, r - inner))
      let k = yy * d.w + xx
      if sub: d.sel[k] = uint8(int(d.sel[k]) * (255 - a) div 255)
      elif a > int(d.sel[k]): d.sel[k] = uint8(a)
  inc d.selVer

proc finishPolyLasso(ok: bool)
proc polyLassoClick(dw: DocWin; ev: PhotoEvent; op: SelOp)
proc polyLassoOverlay(dw: DocWin; ev: PhotoEvent)
proc polyLassoOn(dw: DocWin): bool

proc inImage(d: Doc; ev: PhotoEvent): bool =
  ## (the pointer is on the image itself, not the gray round it)
  ev.x >= 0 and ev.y >= 0 and ev.x < d.w.float and ev.y < d.h.float

# ---- the tools at work ------------------------------------------------------------------------------

const shapeNames = ["Rectangle", "Rounded Rectangle", "Ellipse", "Polygon", "Line", "Custom Shape", "Star",
                    "Spiral", "Triangle"]

proc toolName(t: Tool): string =
  case t
  of tShape: shapeNames[clamp(shapeKind, 0, 8)]
  of tMarquee: ["Rectangular Marquee", "Elliptical Marquee", "Single Row", "Single Column"][marqueeShape]
  of tLasso: ["Lasso", "Polygonal Lasso", "Magnetic Lasso"][clamp(lassoMode, 0, 2)]
  of tBlur: ["Blur", "Sharpen"][blurMode]
  of tDodge: ["Dodge", "Burn", "Sponge"][dodgeMode]
  of tHeal: ["Spot Healing Brush", "Healing Brush", "Patch", "Remove Tool", "Content-Aware Move"][healMode]
  of tStamp: ["Rubber Stamp", "History Brush", "Art History Brush"][clamp(stampTool, 0, 2)]
  of tBrush: ["Paintbrush", "Mixer Brush", "Color Replacement", "Adjustment Brush"][clamp(brushTool, 0, 3)]
  of tWand: ["Magic Wand", "Quick Selection", "Object Selection", "Selection Brush"][clamp(wandMode, 0, 3)]
  of tEyedropper: ["Eyedropper", "Color Sampler", "Ruler", "Note", "Count"][clamp(dropKind, 0, 4)]
  of tEraser: ["Eraser", "Magic Eraser", "Background Eraser"][clamp(eraseKind, 0, 2)]
  of tCrop: ["Crop", "Perspective Crop", "Frame", "Slice", "Slice Select"][clamp(cropKind, 0, 4)]
  of tMove: ["Move", "Artboard"][clamp(moveKind, 0, 1)]
  of tHand: ["Hand", "Rotate View"][clamp(handKind, 0, 1)]
  of tPen: ["Direct Selection", "Pen", "Add Anchor Point", "Delete Anchor Point", "Convert Point",
            "Path Selection", "Freeform Pen", "Curvature Pen", "Content-Aware Tracing"][clamp(penMode, 0, 8)]
  else: $t

proc toolGlyph(t: Tool): string =
  case t
  of tShape: [pxRectShape, pxRoundRectShape, pxEllipseShape, pxPolygonShape, pxLineTool,
              pxCustomShape, pxStarShape, pxSpiral, pxPolygonShape][clamp(shapeKind, 0, 8)]
  of tMarquee: (if marqueeShape == 1: pxMarqueeEllipse else: pxMarqueeRect)
  of tBlur: (if blurMode == 1: pxSharpen else: pxBlur)
  of tDodge: [pxDodge, pxBurn, pxSponge][dodgeMode]
  of tHeal: [pxSpotHeal, pxHeal, pxPatch, pxRemoveTool, pxContentMove][healMode]
  of tStamp: [pxStamp, pxHistoryBrush, pxArtHistory][clamp(stampTool, 0, 2)]
  of tHand: (if handKind == 1: pxRotateView else: pxHandTool)
  of tBrush: [pxBrush, pxMixerBrush, pxColorReplace, pxAdjustBrush][clamp(brushTool, 0, 3)]
  of tWand: [pxMagicWand, pxQuickSelect, pxObjectSelect, pxSelectionBrush][clamp(wandMode, 0, 3)]
  of tEraser: [pxEraser, pxMagicWand, pxBgEraser][clamp(eraseKind, 0, 2)]
  of tCrop: [pxCrop, pxPerspCrop, pxMarqueeRect, pxSlice, pxSlice][clamp(cropKind, 0, 4)]
  of tEyedropper: [pxEyedropper, pxSelect, pxGuides, pxNote, pxCount][clamp(dropKind, 0, 4)]
  of tMove: (if moveKind == 1: pxNew else: pxMoveTool)
  of tPen: [pxPathArrow, pxPen, pxPenAdd, pxPenRemove, pxConvertPoint, pxPathSelect, pxFreeformPen,
            pxCurvaturePen, pxContentTrace][clamp(penMode, 0, 8)]
  else: toolIcons[t]

proc slicesOf(d: Doc): seq[Rect] =
  ## (the image's slices, in the order they were made)
  for sl in slices:
    if sl.d == d: result.add sl.r

include photo/typetool

# ---- the shape tools ------------------------------------------------------------------------------------

var shapeMove: tuple[on: bool; orig: ShapeData; dx, dy: float]   ## the Move tool on a shape layer

proc shapeBox(ev: PhotoEvent): (float, float, float, float) =
  ## The box dragged: square with Shift, from its middle with Alt.
  var (x0, y0, x1, y1) = (drag.x0, drag.y0, drag.x1, drag.y1)
  if ev.shift:
    let s = max(abs(x1 - x0), abs(y1 - y0))
    x1 = x0 + (if x1 >= x0: s else: -s)
    y1 = y0 + (if y1 >= y0: s else: -s)
  if ev.alt:
    x0 = 2 * drag.x0 - x1
    y0 = 2 * drag.y0 - y1
  (x0, y0, x1, y1)

proc lineColor(): uint32 =
  ## (the Line tool's color: the stroke's, else the fill's)
  (if shapeStrokeKind == 1: shapeStroke elif shapeFillKind > 0: shapeFill else: fg) or 0xFF000000'u32

proc lineShape(x0, y0, x1, y1: float): ShapeData =
  ## The Line tool's line: a stroke along two points (open: its ends can be
  ## dragged, its arrowheads follow), with the ends of its options.
  var sp = SubPath()
  for (x, y) in [(x0, y0), (x1, y1)]: sp.pts.add PathPoint(p: (x, y), inH: (x, y), outH: (x, y))
  result.path.subs.add sp
  result.fill = ShapePaint(kind: spNone, color: shapeFill, color2: shapeFill2, opacity: 100)
  result.stroke = solidPaint(lineColor())
  result.strokeWidth = max(1, lineWidth).float
  result.align = saCenter
  result.cap = if shapeDash == 2: lcRound else: lcButt
  result.join = ljMiter
  result.dashes = case shapeDash
                  of 1: @[4.0, 2.0]
                  of 2: @[0.01, 2.0]
                  else: @[]
  result.kind = "Line"
  result.startEnd = lineStart
  result.endEnd = lineEnd
  result.endW = lineEndW / 100
  result.endL = lineEndL / 100

proc isLine(L: Layer): bool =
  ## (a shape layer that is a line: one open subpath -- its ends can be dragged)
  L != nil and L.isShape and L.shape.path.subs.len == 1 and not L.shape.path.subs[0].closed and
    L.shape.path.subs[0].pts.len >= 2

var lineGrab: tuple[on: bool; i: int]   ## the Move tool: a line's end held (its point's index)

proc lineEndAt(dw: DocWin; L: Layer; mx, my: int): int =
  ## (the end of line layer `L` under the mouse: its point's index; -1 none)
  if not L.isLine: return -1
  let sp = L.shape.path.subs[0]
  let reach = dp(8)
  result = -1
  var best = reach * reach + 1
  for i in [0, sp.pts.high]:
    let (sx, sy) = dw.view.toScreen(dw.doc, sp.pts[i].p[0], sp.pts[i].p[1])
    let e = (sx - mx) * (sx - mx) + (sy - my) * (sy - my)
    if e < best:
      best = e
      result = i

proc lineDragEnd(ev: PhotoEvent): (float, float) =
  ## (where the line dragged goes to: Shift, at a multiple of 45 degrees)
  var (x1, y1) = (drag.x1, drag.y1)
  if ev.shift:
    let a = round(arctan2(y1 - drag.y0, x1 - drag.x0) / (PI / 4)) * (PI / 4)
    let l = sqrt((x1 - drag.x0) ^ 2 + (y1 - drag.y0) ^ 2)
    x1 = drag.x0 + cos(a) * l
    y1 = drag.y0 + sin(a) * l
  (x1, y1)

proc shapePath(ev: PhotoEvent): Path =
  ## The outline the shape tool draws for the drag so far.
  if shapeKind == 4:
    let (x1, y1) = lineDragEnd(ev)
    if hypot(x1 - drag.x0, y1 - drag.y0) < 1: return
    return lineShape(drag.x0, drag.y0, x1, y1).path
  let (x0, y0, x1, y1) = shapeBox(ev)
  case shapeKind
  of 0: rectPath(x0, y0, x1, y1)
  of 1: rectPath(x0, y0, x1, y1, shapeRadius.float)
  of 2: ellipsePath(x0, y0, x1, y1)
  of 3:
    if ev.alt or true:
      # (a polygon grows from its middle: the drag is its radius)
      let r = hypot(drag.x1 - drag.x0, drag.y1 - drag.y0)
      polygonPath(drag.x0 - r, drag.y0 - r, drag.x0 + r, drag.y0 + r, polySides, polyStar, polyIndent, polySmooth)
    else: Path()
  of 6:
    # (a star grows from its middle, as Illustrator's)
    let r = hypot(drag.x1 - drag.x0, drag.y1 - drag.y0)
    starPath(drag.x0 - r, drag.y0 - r, drag.x0 + r, drag.y0 + r, max(3, starPoints), starIndent,
             if polySmooth: 50 else: 0)
  of 7:
    let r = hypot(drag.x1 - drag.x0, drag.y1 - drag.y0)
    spiralPath(drag.x0 - r, drag.y0 - r, drag.x0 + r, drag.y0 + r, spiralTurns.float, spiralDecay)
  of 8:
    # (the Triangle tool: its point at the top middle of the box)
    var sp = SubPath(closed: true)
    for (x, y) in [((x0 + x1) / 2, y0), (x1, y1), (x0, y1)]:
      sp.pts.add PathPoint(p: (x, y), inH: (x, y), outH: (x, y))
    Path(subs: @[sp])
  else: customPath(customShape, x0, y0, x1, y1)

proc shapeSettings(): ShapeData =
  ## A new shape's paint and stroke, from the tool's options.
  result.fill = case shapeFillKind
                of 0: ShapePaint(kind: spNone, color: shapeFill, color2: shapeFill2, angle: 90, opacity: 100)
                of 2: gradientPaint(shapeFill, shapeFill2, 0)
                else: solidPaint(shapeFill)
  result.stroke = if shapeStrokeKind == 1: solidPaint(shapeStroke)
                  else: ShapePaint(kind: spNone, color: shapeStroke, color2: shapeStroke, opacity: 100)
  result.strokeWidth = shapeStrokeW.float
  result.align = StrokeAlign(clamp(shapeAlign, 0, 2))
  result.cap = if shapeDash == 2: lcRound else: lcButt
  result.join = ljMiter
  result.dashes = case shapeDash
                  of 1: @[4.0, 2.0]
                  of 2: @[0.01, 2.0]
                  else: @[]
  result.kind = shapeNames[clamp(shapeKind, 0, 8)]
  if shapeKind == 1: result.radius = shapeRadius.float

proc finishShape(dw: DocWin; ev: PhotoEvent) =
  ## The shape dragged made: a shape layer (or added to the one there),
  ## a path, or pixels.
  let d = dw.doc
  var p = shapePath(ev)
  if p.subs.len == 0: return
  let name = shapeNames[clamp(shapeKind, 0, 8)]
  if shapeKind == 4 and shapeMode != 1:
    # the Line tool: a line layer (its ends and arrowheads kept: dragged, they
    # follow), or its pixels
    let (x1, y1) = lineDragEnd(ev)
    let s = lineShape(drag.x0, drag.y0, x1, y1)
    d.beginStep(name)
    if shapeMode == 2:
      var px = newSeq[uint32](d.w * d.h)
      discard renderShape(s, px, d.w, d.h)
      var m = newSeq[uint8](d.w * d.h)
      for i in 0 ..< px.len: m[i] = uint8(px[i] shr 24)
      d.paintMask(m, lineColor(), opts[tShape].opacity, PaintModes[clamp(opts[tShape].mode, 0, PaintModes.high)])
    else:
      d.touchLayers()
      d.editMask = false
      discard d.addShapeLayer(s, name = "")
    d.endStep()
    return
  case shapeMode
  of 1:
    # a path: added to the work path
    d.beginStep(name)
    d.touchPaths()
    if d.curPath < 0 or d.curPath >= d.paths.len:
      d.paths.add Path(name: "Work Path")
      d.curPath = d.paths.high
    for s in p.subs:
      var t = s
      t.op = poAdd
      t.joined = false
      d.paths[d.curPath].subs.add t
    d.endStep()
    inc d.ver
  of 2:
    # pixels, in the foreground color
    d.beginStep(name)
    let m = shapeMask(p, d.w, d.h)
    d.paintMask(m, fg, opts[tShape].opacity, PaintModes[clamp(opts[tShape].mode, 0, PaintModes.high)])
    d.endStep()
  else:
    let L = d.current
    if shapeOp > 0 and L.isShape and not d.quickMask:
      # added to the shape layer there
      var s = L.shape
      s.path.combine(p, PathOp(shapeOp - 1))
      if s.kind != name: s.kind = ""
      d.beginStep(name)
      d.touchLayers()
      d.setShape(L, s)
      d.endStep()
    else:
      var s = shapeSettings()
      s.path = p
      if shapeKind == 4 and s.fill.kind == spNone and s.stroke.kind == spNone:
        s.fill = solidPaint(shapeFill)
      if shapeKind == 7:
        # (a spiral is a line: stroked, not filled)
        s.fill = ShapePaint(kind: spNone)
        s.stroke = solidPaint(if shapeStrokeKind == 1: shapeStroke else: shapeFill)
        s.strokeWidth = max(2.0, s.strokeWidth)
        s.align = saCenter
      d.beginStep(name)
      d.touchLayers()
      d.editMask = false
      discard d.addShapeLayer(s, name = "")
      d.endStep()

# ---- Effects: Scale, Skew, Perspective, Distort, Free Rotate, with handles -------------------------------

type XfKind = enum xkScale = "Scale", xkSkew = "Skew", xkPerspective = "Perspective",
                   xkDistort = "Distort", xkRotate = "Rotate"

var xf: tuple[on: bool; dw: DocWin; kind: XfKind; layer: Layer; r: Rect; orig: seq[uint32];
              mask: seq[uint8]; hadSel: bool; quad, quad0: Quad; grab: int; start: (float, float);
              vacated: uint32; shape0: ShapeData; base: seq[uint32]]
  ## (pixels: `orig` the pixels taken up from `r`, `base` the layer without
  ## them; shown live while the corners move, put down by `finishTransform`)
var xfSmart: SmartData           ## a Smart Object being transformed: as it was (its corners move)
var xfText: tuple[on: bool; t: TextData]   ## a type layer being transformed: its text as it was

const XfBlue = color(20, 115, 230)  ## the transform box's lines and handles (the usual blue)

var
  objectFinder = true              ## the Object Selection tool shows the thing under the mouse
  finderSeg: tuple[d: Doc; ver: int; s: Segments]
  finderShown: tuple[d: Doc; ver, k: int; b: Bitmap]

proc findSegments(d: Doc): Segments =
  ## The image in regions (Object Finder), made again when it changed.
  if finderSeg.d != d or finderSeg.ver != d.ver or finderSeg.s.w == 0:
    d.updateComposite()
    finderSeg = (d, d.ver, segment(Img(w: d.w, h: d.h, px: d.compCopy)))
  finderSeg.s

var
  underMenu: tuple[dw: DocWin; idx: seq[int]]   ## (the Move tool's right click: the layers there)
  moveAutoSelect = true            ## the Move tool picks the layer clicked (Auto-Select)
  moveShowControls = true          ## ... and shows the box and handles of the current one
  moveAutoGroup = false            ## ... picks the outermost group of the layer clicked (Auto-Select: Group)
  textBoxCaches: Table[pointer, tuple[fp: Hash; r: Rect]]   # (type layers' boxes, while their text is the same)
  hoverBox: tuple[x, y: int; r: Rect]

proc layerBox(d: Doc; L: Layer): Rect =
  ## Where a layer has something: its text's box, its shape's, a Smart
  ## Object's corners, else its pixels (kept while it does not change).
  if L == nil or L.group or L.adjust.kind.len > 0: return
  if L.isText:
    # (the whole of its text, off the image too: a type layer moved off it is
    # still there -- its box shows round it, to be dragged back)
    # (kept while the text is the same: its words, place, sizes -- not by the
    # layer's address alone, which a new layer may have again)
    let t = d.effectiveText(L)
    var h: Hash = hash(t.plainText) !& hash(t.x) !& hash(t.y) !& hash(t.boxW) !& hash(t.boxH) !&
                  hash(t.spans.len) !& hash(t.vertical) !& hash(t.path.len) !& hash(L.ver)
    for sp in t.spans: h = h !& hash(sp.style.size) !& hash(sp.style.family) !& hash(sp.style.hScale)
    let fp = !$h
    let key = cast[pointer](L)
    let c = textBoxCaches.getOrDefault(key, (Hash(0), rect(0, 0, 0, 0)))
    if c.fp == fp and c.r.w > 0: return c.r
    let fb = t.drawnBounds(layoutText(t))
    var r = rect(int(floor(fb.x0)), int(floor(fb.y0)), int(ceil(fb.x1 - floor(fb.x0))),
                 int(ceil(fb.y1 - floor(fb.y0))))
    if t.boxW > 0 and not t.onPath:
      r = rect(int(floor(t.x)), int(floor(t.y)), max(1, int(ceil(t.boxW))), max(1, int(ceil(t.boxH))))
    if r.w <= 0 or r.h <= 0:
      let b = L.textBounds
      if b.w > 0: r = b
    if r.w > 0 and r.h > 0:
      if textBoxCaches.len > 400: textBoxCaches.clear()
      textBoxCaches[key] = (fp, r)
      return r
  if L.isShape and L.shape.path.subs.len > 0:
    var b = pathBounds(L.shape.path)
    if L.isLine:
      # (a line: as wide as its stroke and its ends -- a level one has room to grab)
      let e = shapeReach(L.shape)
      b = (b[0] - e, b[1] - e, b[2] + e, b[3] + e)
    return rect(int(floor(b[0])), int(floor(b[1])), max(1, int(ceil(b[2] - floor(b[0])))),
                max(1, int(ceil(b[3] - floor(b[1])))))
  if L.isSmart:
    var x0, y0 = 1e18
    var x1, y1 = -1e18
    for (x, y) in L.smart.quad:
      x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
    return rect(int(floor(x0)), int(floor(y0)), max(1, int(ceil(x1 - floor(x0)))), max(1, int(ceil(y1 - floor(y0)))))
  # (kept on the layer: by its address, a new layer given a deleted one's
  # address had the old one's box)
  if L.boxVer == L.ver + 1: return L.box
  result = d.contentBounds(L)
  L.box = result
  L.boxVer = L.ver + 1

proc shownAt(d: Doc; L: Layer; px, py: int): bool =
  ## (a layer's pixel shows: some of it, as far as its mask lets it)
  if L.px.len != d.w * d.h: return false
  let k = py * d.w + px
  var a = int(L.px[k] shr 24)
  if a <= 8: return false
  if L.mask != nil and not L.maskOff and L.mask.px.len == L.px.len:
    a = a * int(L.mask.px[k] and 255) div 255
  a > 8

proc inHiddenGroup(d: Doc; i: int): bool =
  var g = d.parentOf(i)
  while g >= 0:
    if not d.layers[g].visible or d.layers[g].opacity == 0: return true
    g = d.parentOf(g)

proc hitsAt(d: Doc; L: Layer; px, py, r: int): bool =
  ## (a layer shows at a pixel, or within `r` of it)
  if L.isText:
    # (type: its box -- between the letters too; a document just opened
    # has not drawn it yet: then the box its pixels make)
    var b = L.textBounds
    if b.w <= 0: b = d.layerBox(L)
    return b.w > 0 and rect(b.x - r, b.y - r, b.w + 2 * r, b.h + 2 * r).contains(point(px, py))
  if d.shownAt(L, px, py): return true
  if r <= 0: return false
  # (near it: the nearest pixels first, outward)
  for rr in 1 .. r:
    for dy in -rr .. rr:
      for dx in [-rr, rr]:
        let (qx, qy) = (px + dx, py + dy)
        if qx >= 0 and qy >= 0 and qx < d.w and qy < d.h and d.shownAt(L, qx, qy): return true
    for dx in -rr + 1 .. rr - 1:
      for dy in [-rr, rr]:
        let (qx, qy) = (px + dx, py + dy)
        if qx >= 0 and qy >= 0 and qx < d.w and qy < d.h and d.shownAt(L, qx, qy): return true

proc layersUnder(d: Doc; x, y: int; radius = 0): seq[int] =
  ## Every layer that shows something at image pixel `x`, `y`, the top one
  ## first (the Move tool's right click lists them).
  if x < 0 or y < 0 or x >= d.w or y >= d.h: return
  for i in countdown(d.layers.high, 0):
    let L = d.layers[i]
    if not L.visible or L.group or L.opacity == 0: continue
    if d.inHiddenGroup(i): continue
    if L.adjust.kind.len > 0: continue
    if L.background or d.hitsAt(L, x, y, radius): result.add i

proc layerAt(d: Doc; x, y: int; radius = 0): int =
  ## The top layer that shows something at image pixel `x`, `y` -- or within
  ## `radius` pixels of it (a thin line, a finger) -- for Auto-Select; -1
  ## none. What shows: its pixels (type: its box) as far as its mask lets
  ## them, in a clipping mask only where the layer under it shows; not in a
  ## hidden group, not at 0 % opacity.
  if x < 0 or y < 0 or x >= d.w or y >= d.h: return -1
  # (smart about what is clicked: a thing on the page -- type, a shape, a
  # picture -- before a layer as big as the page; of those, one that covers
  # what is under it before a texture laid over all, as grain or light)
  var best = -1
  var bestTier = 4
  for i in countdown(d.layers.high, 0):
    let L = d.layers[i]
    if not L.visible or L.group or L.adjust.kind.len > 0 or L.opacity == 0: continue
    if d.inHiddenGroup(i): continue
    if not d.hitsAt(L, x, y, radius): continue
    if L.clipped:
      # (shown only where the base of its clipping mask is)
      var b = i - 1
      while b >= 0 and d.layers[b].clipped: dec b
      if b >= 0 and not d.shownAt(d.layers[b], x, y): continue
    let box = d.layerBox(L)
    let whole = L.background or box.w * box.h >= d.w * d.h * 9 div 10
    let tier = if not whole: 1
               elif L.mode == bmNormal and L.opacity >= 50 and L.fill >= 50: 2
               else: 3
    if tier < bestTier:
      best = i
      bestTier = tier
      if tier == 1: break
  best

proc autoPicked(d: Doc; i: int): int =
  ## (Auto-Select: the layer clicked -- or, set to Group, the outermost group
  ## it is in)
  result = i
  if not moveAutoGroup or i < 0: return
  var p = d.parentOf(i)
  while p >= 0:
    result = p
    p = d.parentOf(p)

proc blockBox(d: Doc; i: int): Rect =
  ## (a layer's box -- a group's: of all in it)
  if i < 0 or i >= d.layers.len: return rect(0, 0, 0, 0)
  if not d.layers[i].group: return d.layerBox(d.layers[i])
  result = rect(0, 0, 0, 0)
  for j in d.blockStart(i) ..< i:
    if d.layers[j].group: continue
    let r = d.layerBox(d.layers[j])
    if r.w > 0 and r.h > 0: result = if result.w > 0: union(result, r) else: r

proc pickRadius(dw: DocWin): int =
  ## (how near a click must be to a layer's pixels to pick it: a few screen
  ## pixels -- a finger's width on a touch screen -- in image pixels)
  int(round(float(if finger(): dp(10) else: dp(4)) * pxScale.float / max(1e-6, dw.view.scaleOf)))

proc handlePoints(q: Quad): array[8, (float, float)] =
  ## The handles of a transform box: the corners, then the middles of the
  ## top, right, bottom and left sides.
  for k in 0 .. 3: result[k] = q[k]
  for k in 0 .. 3:
    let a = q[k]
    let b = q[(k + 1) mod 4]
    result[4 + k] = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)

proc inQuad(q: Quad; x, y: float): bool

proc segDist(px, py, ax, ay, bx, by: float): float =
  ## (how far a point is from a line between two points)
  let dx = bx - ax
  let dy = by - ay
  let l2 = dx * dx + dy * dy
  let t = if l2 <= 1e-9: 0.0 else: clamp(((px - ax) * dx + (py - ay) * dy) / l2, 0.0, 1.0)
  hypot(px - (ax + t * dx), py - (ay + t * dy))

proc handleReach(): int =
  ## (how near the mouse must be to a handle of a transform box to take it:
  ## more than the handle -- a finger's width on a touch screen)
  if finger(): dp(16) else: dp(8)

proc boxHit(dw: DocWin; q: Quad; mx, my: int; edges = true): int =
  ## What of a transform box is under the mouse: a corner (0..3), the
  ## inside (4), the room just outside a corner, where it turns (5), a
  ## side (6 top, 7 right, 8 bottom, 9 left: its middle handle, or anywhere
  ## along it); -1 none.
  let d = dw.doc
  let v = dw.view
  let hp = handlePoints(q)
  let near = handleReach()
  # (the nearest handle in reach: two of a small box are both in reach)
  var best = -1
  var bestD = high(int)
  for k in 0 .. (if edges: 7 else: 3):
    let (sx, sy) = v.toScreen(d, hp[k][0], hp[k][1])
    let dd = max(abs(sx - mx), abs(sy - my))
    if dd <= near and dd < bestD:
      bestD = dd
      best = if k < 4: k else: k + 2
  if best >= 0: return best
  if edges:
    # (a side anywhere along it: that side's handle)
    for k in 0 .. 3:
      let (ax, ay) = v.toScreen(d, q[k][0], q[k][1])
      let (bx, by) = v.toScreen(d, q[(k + 1) mod 4][0], q[(k + 1) mod 4][1])
      if segDist(mx.float, my.float, ax.float, ay.float, bx.float, by.float) <= float(near div 2 + 1):
        return 6 + k
  let (ix, iy) = v.toImage(d, mx, my)
  if inQuad(q, ix, iy): return 4
  for k in 0 .. 3:
    let (sx, sy) = v.toScreen(d, hp[k][0], hp[k][1])
    if abs(sx - mx) <= dp(24) and abs(sy - my) <= dp(24): return 5
  -1

proc boxCursor(dw: DocWin; q: Quad; h: int) =
  ## The pointer for what of the box is under it, as today's editors have it: the
  ## arrows along the way a handle sizes (slanted at a corner, turned with a
  ## turned box), four arrows inside (it moves), the cross outside a corner
  ## (it turns: a curved arrow drawn beside it, `rotateBadge`).
  if h < 0: return
  let d = dw.doc
  let v = dw.view
  case h
  of 4: ui.cursor = curMove
  of 5: ui.cursor = curCrosshair
  else:
    # (from the box's middle to the handle, on the screen)
    let hp = handlePoints(q)
    var cx, cy = 0.0
    for k in 0 .. 3:
      cx += q[k][0] / 4
      cy += q[k][1] / 4
    let k = if h < 4: h else: h - 2
    let (sx, sy) = v.toScreen(d, hp[k][0], hp[k][1])
    let (mx, my) = v.toScreen(d, cx, cy)
    let dx = float(sx - mx)
    let dy = float(sy - my)
    let a = (arctan2(dy, dx) * 180 / PI + 360.0) mod 180.0   # (0..180: the line's slope)
    ui.cursor = if a < 22.5 or a >= 157.5: curSizeWE
                elif a < 67.5: curSizeNWSE
                elif a < 112.5: curSizeNS
                else: curSizeNESW

const boxCursors = {curSizeNS, curSizeWE, curSizeNWSE, curSizeNESW, curMove, curCrosshair}
  ## (the pointers `boxCursor` gives)

proc rotateBadge(x, y: int) =
  ## A curved arrow beside the pointer: here a drag turns the box.
  let r = float(dp(6))
  let cx = float(x + dp(16))
  let cy = float(y + dp(16))
  for pass in 0 .. 1:
    let c = if pass == 0: color(255, 255, 255) else: color(0, 0, 0)
    let w = if pass == 0: float(dp(3)) else: max(1.0, float(dp(1)))
    var px = cx + r * cos(PI * 0.15)
    var py = cy - r * sin(PI * 0.15)
    for i in 1 .. 12:
      let t = PI * 0.15 + PI * 1.2 * i.float / 12
      let nx = cx + r * cos(t)
      let ny = cy - r * sin(t)
      thickLine(px, py, nx, ny, w, c)
      px = nx
      py = ny
    # (the arrow's head, at the end)
    let hx = px
    let hy = py
    thickLine(hx, hy, hx + float(dp(4)), hy - float(dp(1)), w, c)
    thickLine(hx, hy, hx + float(dp(1)), hy - float(dp(4)), w, c)

proc drawBox(dw: DocWin; q: Quad; handles = true; edges = true; hot = -1) =
  ## the usual transform box: a thin blue line, white handles edged in
  ## blue. `hot`, what the mouse is over (`boxHit`), lights up: a handle
  ## filled blue and larger, a side drawn thicker, the whole outline thicker
  ## from inside (it moves), a curved arrow by the pointer (it turns).
  let d = dw.doc
  let v = dw.view
  var pts: array[4, (int, int)]
  for k in 0 .. 3: pts[k] = v.toScreen(d, q[k][0], q[k][1])
  for k in 0 .. 3:
    let (a, b) = pts[k]
    let (c, e) = pts[(k + 1) mod 4]
    if hot == 4 or hot == 6 + k:
      thickLine(a.float, b.float, c.float, e.float, float(max(2, dp(2))), XfBlue)
    else:
      line(a, b, c, e, XfBlue)
  if hot == 5: rotateBadge(ui.mx, ui.my)
  if not handles: return
  let hs = if finger(): dp(5) else: dp(3)
  let hp = handlePoints(q)
  for k in 0 .. (if edges: 7 else: 3):
    let (hx, hy) = v.toScreen(d, hp[k][0], hp[k][1])
    let on = (k < 4 and hot == k) or (k >= 4 and hot == k + 2)
    let s = if on: hs + dp(1) else: hs
    let r = rect(hx - s, hy - s, 2 * s + 1, 2 * s + 1)
    fill(r, if on: XfBlue else: color(255, 255, 255))
    box(r, if on: color(255, 255, 255) else: XfBlue)
    if on: box(inset(r, -1), XfBlue)

proc xfApply() =
  let d = xf.dw.doc
  if xfText.on:
    # (type: the letters as much bigger as the box, wider if it is wider)
    var x0, y0 = 1e18
    var x1, y1 = -1e18
    for (x, y) in xf.quad:
      x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
    let sx = (x1 - x0) / max(1.0, xf.r.w.float)
    let sy = (y1 - y0) / max(1.0, xf.r.h.float)
    var t = xfText.t
    for sp in t.spans.mitems:
      sp.style.size = max(1'f32, sp.style.size * float32(sy))
      let hs = if sp.style.hScale <= 0: 1'f32 else: sp.style.hScale
      sp.style.hScale = hs * float32(sx / max(0.01, sy))
      if sp.style.leading > 0: sp.style.leading *= float32(sy)
    let f = quadMap(xf.r, [(x0, y0), (x1, y0), (x1, y1), (x0, y1)])
    let (nx, ny) = f(t.x.float, t.y.float)
    t.x = float32(nx)
    t.y = float32(ny)
    if t.boxW > 0:
      t.boxW *= float32(sx)
      t.boxH *= float32(sy)
    xf.layer.text = t
    d.drawText(xf.layer)
    d.markAll()
    return
  if xfSmart != nil:
    # (a Smart Object: its corners carried along, drawn again from what it holds)
    let f = quadMap(xf.r, xf.quad)
    var q: Quad
    for k in 0 .. 3: q[k] = f(xfSmart.quad[k][0], xfSmart.quad[k][1])
    xf.layer.smart = xfSmart.withQuad(q)
    d.renderSmartLayer(xf.layer)
    return
  if xf.shape0.path.subs.len > 0:
    # (a shape layer: its outline goes, drawn again sharp)
    var s = xf.shape0
    s.path.mapPoints(quadMap(xf.r, xf.quad))
    d.setShape(xf.layer, s)
    return
  if d.live.len > 0 and d.live[0].kind == lkWarp:
    # (live: only the view is made again; `finishTransform` puts it down)
    d.live[0].quad = xf.quad
    d.liveChanged()

proc putDownTransform() =
  ## (the pixels transformed live: warped into the layer at full size, once)
  let d = xf.dw.doc
  if d.live.len == 0 or d.live[0].kind != lkWarp: return
  d.endLive()
  beginBusy("Transforming")
  try:
    let L = xf.layer
    var res: seq[uint32]
    if xf.hadSel:
      res = move(xf.base)
      d.warpOnto(res, xf.orig, xf.r, xf.quad)
    else:
      res = d.vacatedCopy(L.px, xf.r, xf.vacated)
      d.warpOnto(res, cast[ptr UncheckedArray[uint32]](addr L.px[xf.r.y * d.w + xf.r.x]), d.w, xf.r, xf.quad)
    discard d.touchWhole(L)          # (the pixels as they were: to the step, not copied)
    L.px = move(res)
    inc L.ver
    if xf.hadSel:
      d.sel = d.warpedMask(xf.mask, xf.r, xf.quad)
      inc d.selVer
  finally: endBusy()
  d.markAll()

proc startTransform(kind: XfKind) =
  let dw = active
  if dw == nil: return
  let d = dw.doc
  let L = d.layer
  if L.isShape and not d.hasSelection:
    let b = pathBounds(L.shape.path)
    let r = rect(int(floor(b[0])), int(floor(b[1])), max(1, int(ceil(b[2] - floor(b[0])))),
                 max(1, int(ceil(b[3] - floor(b[1])))))
    d.beginStep($kind)
    d.touchLayers()
    xf = (true, dw, kind, L, r, newSeq[uint32](), newSeq[uint8](), false, quadOf(r), quadOf(r), -1, (0.0, 0.0),
          0'u32, L.shape, newSeq[uint32]())
    status = $kind & ": drag the corners; Enter or a double-click inside to finish, Esc to cancel"
    return
  xfSmart = nil
  xfText.on = false
  if L.isText and not d.hasSelection and kind in {xkScale, xkRotate}:
    # (a type layer: its letters' size and its place change; it stays text)
    let r = d.layerBox(L)
    if r.w <= 0 or r.h <= 0: return
    d.beginStep($kind)
    d.touch(L, d.bounds)
    d.touchLayers()
    xfText = (true, L.text)
    xf = (true, dw, xkScale, L, r, newSeq[uint32](), newSeq[uint8](), false, quadOf(r), quadOf(r), -1, (0.0, 0.0),
          0'u32, ShapeData(), newSeq[uint32]())
    status = "Type: drag the handles to size it (it stays text); Enter to finish, Esc to cancel"
    return
  if L.isSmart and not d.hasSelection:
    var x0, y0 = 1e18
    var x1, y1 = -1e18
    for (x, y) in L.smart.quad:
      x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
    let r = rect(int(floor(x0)), int(floor(y0)), max(1, int(ceil(x1 - floor(x0)))), max(1, int(ceil(y1 - floor(y0)))))
    d.beginStep($kind)
    d.touch(L, d.bounds)
    d.touchLayers()
    xfSmart = L.smart
    xf = (true, dw, kind, L, r, newSeq[uint32](), newSeq[uint8](), false, quadOf(r), quadOf(r), -1, (0.0, 0.0),
          0'u32, ShapeData(), newSeq[uint32]())
    status = $kind & " (a Smart Object: without loss): drag the corners; Enter to finish, Esc to cancel"
    return
  # (the selection's box; without one, where the layer has something, as
  # the usual Free Transform)
  var r = d.clip(d.selBounds)
  if not d.hasSelection and not d.quickMask and not d.editMask:
    let c = d.layerBox(L)
    if c.w > 0 and c.h > 0: r = c
  if r.w <= 0 or r.h <= 0: return
  if L.px.len != d.w * d.h: return
  d.beginStep($kind)
  d.touchSel()
  let vacated = if L.background or L.lockAlpha: bg or 0xFF000000'u32 else: 0'u32
  # (shown live while the corners move: the layer is not changed -- nor
  # copied -- until it is put down, warped once at full size; a selection's
  # pixels are taken up first, all of it is read where it is)
  if d.hasSelection:
    var (part, base) = d.liftForWarp(L.px, r, d.sel, vacated)
    xf = (true, dw, kind, L, r, move(part), d.sel, true, quadOf(r), quadOf(r), -1, (0.0, 0.0),
          vacated, ShapeData(), move(base))
    d.setLive(@[LivePart(layer: L, kind: lkWarp, base: cast[ptr UncheckedArray[uint32]](addr xf.base[0]),
                         src: cast[ptr UncheckedArray[uint32]](addr xf.orig[0]), srcR: r, quad: xf.quad)])
  else:
    xf = (true, dw, kind, L, r, newSeq[uint32](), newSeq[uint8](), false, quadOf(r), quadOf(r), -1, (0.0, 0.0),
          vacated, ShapeData(), newSeq[uint32]())
    d.setLive(@[LivePart(layer: L, kind: lkWarp, src: cast[ptr UncheckedArray[uint32]](addr L.px[r.y * d.w + r.x]),
                         srcStride: d.w, srcR: r, quad: xf.quad, hole: true, baseFill: vacated)])
  d.liveSel = (0, 0, true)
  status = $kind & ": drag the corners; Enter or a double-click inside to finish, Esc to cancel"

proc finishTransform(ok: bool) =
  if not xf.on: return
  let d = xf.dw.doc
  if ok:
    if xf.quad != quadOf(xf.r): lastXf = (true, xf.r, xf.quad)
    putDownTransform()
    xf.on = false
    d.endStep()
  else:
    d.endLive()
    xf.on = false
    d.cancelStep()
  xf.orig = @[]
  xf.mask = @[]
  xf.base = @[]
  xfSmart = nil
  xfText.on = false
  status = ""

proc inQuad(q: Quad; x, y: float): bool =
  ## Inside the four corners (crossings of a ray).
  var c = false
  for k in 0 .. 3:
    let (ax, ay) = q[k]
    let (bx, by) = q[(k + 1) mod 4]
    if (ay > y) != (by > y) and x < (bx - ax) * (y - ay) / (by - ay) + ax: c = not c
  c

proc transformMouse(dw: DocWin; ev: PhotoEvent) =
  ## The handles take the mouse while a transform is on.
  let d = dw.doc
  let v = dw.view
  let edges = xf.kind == xkScale
  if not ev.down and ev.over: dw.boxCursor(xf.quad, dw.boxHit(xf.quad, ui.mx, ui.my, edges))
  elif ev.down and xf.grab >= 0: dw.boxCursor(xf.quad, xf.grab)
  if ev.pressed:
    xf.grab = dw.boxHit(xf.quad, ui.mx, ui.my, edges)
    if xf.grab == 4 and ev.clicks >= 2:
      finishTransform(true)
      return
    if xf.grab == 5 and xfText.on: xf.grab = -1   # (type does not turn: it stays text)
    if xf.grab < 0 and xf.kind == xkRotate: xf.grab = 5
    if xf.grab < 0:
      # (a click away from the box: done, as is usual)
      finishTransform(true)
      return
    xf.start = (ev.x, ev.y)
    xf.quad0 = xf.quad
    return
  if xf.grab < 0 or not ev.down: 
    if ev.released or not ui.mouseDown: xf.grab = -1
    return
  let dx = ev.x - xf.start[0]
  let dy = ev.y - xf.start[1]
  var q = xf.quad0
  let k = xf.grab
  if k == 4:
    for c in 0 .. 3: q[c] = (q[c][0] + dx, q[c][1] + dy)
  elif k in 6 .. 9 and ev.ctrl and xf.kind == xkScale and not xfText.on:
    # (Ctrl+Shift on a side's middle, as usual: the side slides along
    # itself -- a skew)
    let s = k - 6
    let a = q[s]
    let b = q[(s + 1) mod 4]
    let l = max(1e-6, sqrt((b[0] - a[0]) ^ 2 + (b[1] - a[1]) ^ 2))
    let t = (dx * (b[0] - a[0]) + dy * (b[1] - a[1])) / l
    let ux = (b[0] - a[0]) / l
    let uy = (b[1] - a[1]) / l
    q[s] = (a[0] + ux * t, a[1] + uy * t)
    q[(s + 1) mod 4] = (b[0] + ux * t, b[1] + uy * t)
  elif k in 6 .. 9:
    # a side's middle: that side out or in, along its normal (Alt: the
    # other side the other way too)
    let s = k - 6
    let a = q[s]
    let b = q[(s + 1) mod 4]
    let ex = b[0] - a[0]
    let ey = b[1] - a[1]
    let l = max(1e-6, sqrt(ex * ex + ey * ey))
    var nx = ey / l
    var ny = -ex / l
    # (outward: away from the middle)
    var cx, cy = 0.0
    for c in 0 .. 3:
      cx += q[c][0] / 4
      cy += q[c][1] / 4
    if (a[0] + b[0]) / 2 - cx < 0 and nx > 0 or (a[0] + b[0]) / 2 - cx > 0 and nx < 0 or
       (a[1] + b[1]) / 2 - cy < 0 and ny > 0 or (a[1] + b[1]) / 2 - cy > 0 and ny < 0:
      nx = -nx
      ny = -ny
    let dd = dx * nx + dy * ny
    q[s] = (q[s][0] + nx * dd, q[s][1] + ny * dd)
    q[(s + 1) mod 4] = (q[(s + 1) mod 4][0] + nx * dd, q[(s + 1) mod 4][1] + ny * dd)
    if ev.alt:
      let o = (s + 2) mod 4
      q[o] = (q[o][0] - nx * dd, q[o][1] - ny * dd)
      q[(o + 1) mod 4] = (q[(o + 1) mod 4][0] - nx * dd, q[(o + 1) mod 4][1] - ny * dd)
  elif xf.kind == xkRotate or k == 5:
    # around the middle, by the angle the mouse went round it
    var cx, cy = 0.0
    for c in 0 .. 3:
      cx += q[c][0] / 4
      cy += q[c][1] / 4
    var a = arctan2(ev.y - cy, ev.x - cx) - arctan2(xf.start[1] - cy, xf.start[0] - cx)
    if ev.shift: a = round(a / (PI / 12)) * (PI / 12)
    for c in 0 .. 3:
      let (x, y) = (q[c][0] - cx, q[c][1] - cy)
      q[c] = (cx + x * cos(a) - y * sin(a), cy + x * sin(a) + y * cos(a))
  else:
    # the corner across the rectangle, and the two beside it
    let opp = (k + 2) mod 4
    let hMate = [1, 0, 3, 2][k]                # beside it on the same top or bottom edge
    let vMate = [3, 2, 1, 0][k]                # beside it on the same left or right edge
    # (Free Transform as today's editors have it since 2019: a corner keeps the
    # proportions unless Shift is held -- Use Legacy Free Transform, or the
    # 1994 keys, the other way round; Ctrl moves the corner alone,
    # Ctrl+Alt+Shift in perspective)
    let kind = if xf.kind == xkScale and ev.ctrl and not xfText.on:
                 (if ev.alt and ev.shift: xkPerspective else: xkDistort)
               else: xf.kind
    let keepRatio = if prefs.keySet == 0 and not prefs.legacyXf and xf.shape0.path.subs.len == 0: not ev.shift
                    else: ev.shift
    case kind
    of xkScale:
      var nx = q[k][0] + dx
      var ny = q[k][1] + dy
      if keepRatio:
        # the same proportions
        let w0 = q[k][0] - q[opp][0]
        let h0 = q[k][1] - q[opp][1]
        if abs(w0) > 0.1 and abs(h0) > 0.1:
          let f = max((nx - q[opp][0]) / w0, (ny - q[opp][1]) / h0)
          nx = q[opp][0] + w0 * f
          ny = q[opp][1] + h0 * f
      q[k] = (nx, ny)
      q[hMate] = (q[hMate][0], ny)
      q[vMate] = (nx, q[vMate][1])
      if ev.alt and not ev.ctrl:
        # (Alt: from the middle -- the corner across moves the other way)
        let ddx = nx - xf.quad0[k][0]
        let ddy = ny - xf.quad0[k][1]
        q[opp] = (xf.quad0[opp][0] - ddx, xf.quad0[opp][1] - ddy)
        q[hMate] = (q[opp][0], ny)
        q[vMate] = (nx, q[opp][1])
    of xkSkew:
      # along one edge: the corner and the one beside it on that edge
      if abs(dx) >= abs(dy):
        q[k] = (q[k][0] + dx, q[k][1]); q[hMate] = (q[hMate][0] + dx, q[hMate][1])
      else:
        q[k] = (q[k][0], q[k][1] + dy); q[vMate] = (q[vMate][0], q[vMate][1] + dy)
    of xkPerspective:
      # the corner one way, the one beside it the other way
      if abs(dx) >= abs(dy):
        q[k] = (q[k][0] + dx, q[k][1]); q[hMate] = (q[hMate][0] - dx, q[hMate][1])
      else:
        q[k] = (q[k][0], q[k][1] + dy); q[vMate] = (q[vMate][0], q[vMate][1] - dy)
    else:
      q[k] = (q[k][0] + dx, q[k][1] + dy)
  if quadIsFine(q) and q != xf.quad:
    xf.quad = q
    xfApply()

proc transformOverlay(dw: DocWin) =
  pushClip(dw.view.view)
  let edges = xf.kind == xkScale
  # (what the mouse is over lights up; while dragged, what it holds)
  let hot = if ui.mouseDown: xf.grab
            elif mouseIn(dw.view.view): dw.boxHit(xf.quad, ui.mx, ui.my, edges)
            else: -1
  dw.drawBox(xf.quad, edges = edges, hot = hot)
  popClip()

# ---- Smart Guides: what is moved lines up with the rest -----------------------------------------------

type
  GuideMark = tuple[v, a, b: float]    ## a line at `v` (x down, or y across) of a thing from `a` to `b`

var
  smartGuidesOn = true             ## View > Show > Smart Guides
  sg: tuple[on: bool; d: Doc; box: (float, float, float, float); xs, ys: seq[GuideMark];
            boxes: seq[Rect]; hitX, hitY: seq[GuideMark]; dx, dy: float]
    ## (a move under way: the box of what moves at its start, the edges and
    ## middles of the rest -- the other layers, the image, the guides -- and
    ## the ones it lines up with now)

proc smartBegin(dw: DocWin) =
  ## (a move starts: what it may line up with)
  let d = dw.doc
  sg = (true, d, (0.0, 0.0, 0.0, 0.0), @[], @[], @[], @[], @[], 0.0, 0.0)
  var moving: seq[int]
  for k in d.movedLayers:
    for j in d.blockStart(k) .. k: moving.add j
  var box = rect(0, 0, 0, 0)
  if d.hasSelection: box = d.clip(d.selBounds)
  else:
    for i in moving:
      let L = d.layers[i]
      if L.group: continue
      let r = d.layerBox(L)
      if r.w > 0 and r.h > 0: box = if box.w > 0: union(box, r) else: r
  if box.w <= 0 or box.h <= 0:
    sg.on = false
    return
  sg.box = (box.x.float, box.y.float, float(box.x + box.w), float(box.y + box.h))
  template add(r: Rect) =
    let (x0, y0, x1, y1) = (r.x.float, r.y.float, float(r.x + r.w), float(r.y + r.h))
    for v in [x0, (x0 + x1) / 2, x1]: sg.xs.add (v, y0, y1)
    for v in [y0, (y0 + y1) / 2, y1]: sg.ys.add (v, x0, x1)
  add(rect(0, 0, d.w, d.h))
  for i, L in d.layers:
    if i in moving or L.group or not L.visible or L.background: continue
    if d.hasSelection and i == d.cur: continue
    let r = d.layerBox(L)
    if r.w <= 0 or r.h <= 0 or (r.w >= d.w and r.h >= d.h): continue
    add(r)
    sg.boxes.add r
  for g in d.guides:
    if g.vertical: sg.xs.add (g.pos, 0.0, d.h.float)
    else: sg.ys.add (g.pos, 0.0, d.w.float)

proc smartSnap(dw: DocWin; dx, dy: var float; lockX = false; lockY = false) =
  ## (a move: `dx`, `dy` taken to the nearest edge or middle of the rest in
  ## reach -- a few screen pixels -- and the lines it meets kept to be drawn)
  sg.hitX.setLen(0)
  sg.hitY.setLen(0)
  if not sg.on: return
  let reach = dp(5).float * pxScale.float / max(1e-6, dw.view.scaleOf)
  let (x0, y0, x1, y1) = sg.box
  let snapping = smartGuidesOn and snapOn and CtrlPressed notin ui.mods   # (Ctrl held: free)
  if snapping:
    var best = reach
    var adj = 0.0
    var found = false
    if not lockX:
      for m in [x0, (x0 + x1) / 2, x1]:
        for t in sg.xs:
          let dd = abs(t.v - (m + dx))
          if dd <= best:
            best = dd
            adj = t.v - (m + dx)
            found = true
      if found: dx += adj
    best = reach
    adj = 0.0
    found = false
    if not lockY:
      for m in [y0, (y0 + y1) / 2, y1]:
        for t in sg.ys:
          let dd = abs(t.v - (m + dy))
          if dd <= best:
            best = dd
            adj = t.v - (m + dy)
            found = true
      if found: dy += adj
  sg.dx = dx
  sg.dy = dy
  if not smartGuidesOn: return
  for m in [x0, (x0 + x1) / 2, x1]:
    for t in sg.xs:
      if abs(t.v - (m + dx)) < 0.5: sg.hitX.add t
  for m in [y0, (y0 + y1) / 2, y1]:
    for t in sg.ys:
      if abs(t.v - (m + dy)) < 0.5: sg.hitY.add t

const SmartPink = color(255, 0, 200)   ## (the usual Smart Guides: magenta)

proc pinkLabel(x, y: int; s: string) =
  ## (a number on a pink tag, as the usual distances)
  let st = style(size = 0.85)
  let w = textWidth(s, st) + dp(8)
  let h = lineHeight(st) + dp(2)
  let r = rect(x - w div 2, y - h div 2, w, h)
  fill(r, SmartPink)
  text(r.x + dp(4), r.y + dp(1), s, color(255, 255, 255), st)

proc smartDraw(dw: DocWin) =
  ## The Smart Guides of a move: the lines it meets (magenta), the room to
  ## the nearest thing on each side, and how far it has gone (dX, dY).
  if not sg.on or sg.d != dw.doc or not smartGuidesOn: return
  let d = dw.doc
  let v = dw.view
  let (bx0, by0, bx1, by1) = (sg.box[0] + sg.dx, sg.box[1] + sg.dy, sg.box[2] + sg.dx, sg.box[3] + sg.dy)
  pushClip(v.view)
  for t in sg.hitX:
    let (sx, sa) = v.toScreen(d, t.v, min(t.a, by0))
    let (_, sb) = v.toScreen(d, t.v, max(t.b, by1))
    vline(sx, sa, sb - sa + 1, SmartPink)
  for t in sg.hitY:
    let (sa, sy) = v.toScreen(d, min(t.a, bx0), t.v)
    let (sb, _) = v.toScreen(d, max(t.b, bx1), t.v)
    hline(sa, sy, sb - sa + 1, SmartPink)
  # the room to the nearest thing beside it (left or right), and above or under
  var gapX = (d: high(int), a: 0.0, b: 0.0, y: 0.0)
  var gapY = (d: high(int), a: 0.0, b: 0.0, x: 0.0)
  for r in sg.boxes:
    let (rx0, ry0, rx1, ry1) = (r.x.float, r.y.float, float(r.x + r.w), float(r.y + r.h))
    if ry1 > by0 and ry0 < by1:                 # (side by side)
      let my = (max(ry0, by0) + min(ry1, by1)) / 2
      if rx1 <= bx0 and int(bx0 - rx1) < gapX.d: gapX = (int(bx0 - rx1), rx1, bx0, my)
      if rx0 >= bx1 and int(rx0 - bx1) < gapX.d: gapX = (int(rx0 - bx1), bx1, rx0, my)
    if rx1 > bx0 and rx0 < bx1:                 # (one over the other)
      let mx = (max(rx0, bx0) + min(rx1, bx1)) / 2
      if ry1 <= by0 and int(by0 - ry1) < gapY.d: gapY = (int(by0 - ry1), ry1, by0, mx)
      if ry0 >= by1 and int(ry0 - by1) < gapY.d: gapY = (int(ry0 - by1), by1, ry0, mx)
  if gapX.d != high(int) and gapX.d > 0:
    let (a, y) = v.toScreen(d, gapX.a, gapX.y)
    let (b, _) = v.toScreen(d, gapX.b, gapX.y)
    hline(min(a, b), y, abs(b - a) + 1, SmartPink)
    vline(a, y - dp(3), dp(7), SmartPink)
    vline(b, y - dp(3), dp(7), SmartPink)
    pinkLabel((a + b) div 2, y - dp(9), $gapX.d)
  if gapY.d != high(int) and gapY.d > 0:
    let (x, a) = v.toScreen(d, gapY.x, gapY.a)
    let (_, b) = v.toScreen(d, gapY.x, gapY.b)
    vline(x, min(a, b), abs(b - a) + 1, SmartPink)
    hline(x - dp(3), a, dp(7), SmartPink)
    hline(x - dp(3), b, dp(7), SmartPink)
    pinkLabel(x + dp(14) + textWidth($gapY.d) div 2, (a + b) div 2, $gapY.d)
  popClip()
  # how far it has gone, by the pointer (as the usual "Show Transformation Values")
  let st = style(size = 0.85)
  let l1 = "ΔX: " & $int(round(sg.dx)) & " px"
  let l2 = "ΔY: " & $int(round(sg.dy)) & " px"
  let w = max(textWidth(l1, st), textWidth(l2, st)) + dp(10)
  let h = 2 * lineHeight(st) + dp(6)
  let r = rect(ui.mx + dp(18), ui.my + dp(18), w, h)
  fill(r, color(60, 60, 60))
  box(r, color(30, 30, 30))
  text(r.x + dp(5), r.y + dp(3), l1, color(255, 255, 255), st)
  text(r.x + dp(5), r.y + dp(3) + lineHeight(st), l2, color(255, 255, 255), st)

proc beginLift(dw: DocWin) =
  let d = dw.doc
  d.beginStep("Move")
  drag.lift = d.beginMove(bg)
  drag.moving = true

proc magicErase(d: Doc; x, y: int) =
  ## The Magic Eraser: the pixels like the one clicked (within its
  ## Tolerance; touching it, or all of them) made transparent on the
  ## current layer -- the Background becomes a layer first, as is usual.
  if x < 0 or y < 0 or x >= d.w or y >= d.h: return
  var L = d.current
  if L.group or L.locked or L.isText or L.isShape or L.px.len != d.w * d.h: return
  d.beginStep("Magic Eraser")
  if L.background:
    d.touchLayers()
    d.layerFromBackground()
    L = d.current
  let m = d.regionMask(x, y, magicTol, false, magicContig, true)
  var res = L.px
  let hasSel = d.hasSelection
  for i in 0 ..< min(m.len, res.len):
    var k = int(m[i])
    if hasSel: k = k * int(d.sel[i]) div 255
    if k > 0:
      let p = res[i]
      let a = int(p shr 24) * (255 - k) div 255
      res[i] = (p and 0x00FFFFFF'u32) or (uint32(a) shl 24)
  if not d.touchWhole(L): d.touch(L, d.bounds)   # (the pixels as they were: to the step)
  L.px = move(res)
  inc L.ver
  d.markAll()
  d.endStep()

proc rulerAngle(): float =
  ## The Ruler's line: degrees from the horizontal (counterclockwise, as
  ## the Info palette has it).
  radToDeg(arctan2(ruler.y0 - ruler.y1, ruler.x1 - ruler.x0))

proc cropName(): string = (if pendingCrop.persp: "Perspective Crop" else: "Crop")

proc applyPendingCrop(pd: Doc) =
  ## (the box waiting on the Crop tool: the image cut to it -- or, the
  ## Perspective Crop's, what is inside its corners made a rectangle)
  let r = pendingCrop.r
  if pendingCrop.persp: pd.perspectiveCrop(pendingCrop.q, bg)
  elif r.x < 0 or r.y < 0 or r.x + r.w > pd.w or r.y + r.h > pd.h:
    if cropFill == 1:
      beginBusy("Content-Aware Expand")
      try: pd.contentAwareExpand(r, int(epochTime() * 1000) mod 9973 + 1)
      finally: endBusy()
    else:
      pd.canvasSizeAt(max(pd.w, r.x + r.w) - min(0, r.x), max(pd.h, r.y + r.h) - min(0, r.y),
                      -min(0, r.x), -min(0, r.y), bg)
      pd.crop(rect(r.x - min(0, r.x), r.y - min(0, r.y), r.w, r.h))
  else: pd.crop(r)

proc commitCropNow() =
  ## The crop box waiting: cropped to (Enter, the Commit button).
  let dw = pendingCrop.dw
  if not pendingCrop.on or dw == nil or dw notin docs: return
  let d = dw.doc
  d.snapStep(cropName())
  try:
    d.applyPendingCrop()
    d.endStep()
  except ValueError:
    d.cancelStep()
    status = "The image would be too big"
  pendingCrop.on = false
  cropGrab.on = false
  dw.fitWindow()
  if status != "The image would be too big": status = ""

proc insideQuad(q: Quad; x, y: float): bool =
  var inside = false
  for i in 0 .. 3:
    let a = q[i]
    let b = q[(i + 1) mod 4]
    if (a[1] > y) != (b[1] > y) and x < (b[0] - a[0]) * (y - a[1]) / (b[1] - a[1] + 1e-12) + a[0]:
      inside = not inside
  inside

proc cropHandleAt(dw: DocWin; x, y: float): int =
  ## (the part of the crop box waiting under the mouse: 0..3 its corners,
  ## 4..7 its sides' middles -- top, right, bottom, left --, 8 inside, -1 none)
  if not pendingCrop.on or pendingCrop.dw != dw: return -1
  let d = dw.doc
  let rad = dp(7).float * pxScale.float / dw.view.scaleOf
  var pts: seq[(float, float)]
  if pendingCrop.persp:
    for c in pendingCrop.q: pts.add c
  else:
    let r = pendingCrop.r
    let (x0, y0, x1, y1) = (r.x.float, r.y.float, (r.x + r.w).float, (r.y + r.h).float)
    pts = @[(x0, y0), (x1, y0), (x1, y1), (x0, y1), ((x0 + x1) / 2, y0), (x1, (y0 + y1) / 2),
            ((x0 + x1) / 2, y1), (x0, (y0 + y1) / 2)]
  for k, (px, py) in pts:
    if abs(px - x) <= rad and abs(py - y) <= rad: return k
  let q = if pendingCrop.persp: pendingCrop.q else: quadOf(pendingCrop.r)
  if insideQuad(q, x, y): return 8
  discard d
  -1

var pressWas: tuple[steps: int; crop: typeof(pendingCrop); ruler: typeof(ruler);
                   slices: typeof(slices); typing, shapeDlg: bool]
  ## (as things were when the mouse went down: Esc puts them back)

proc pressOn(dw: DocWin; ev: PhotoEvent) =
  ## The mouse went down on a document.
  let d = dw.doc
  active = dw
  sg.on = false
  # outside the image (the gray round it): the tools wait for the pointer to
  # come onto it -- the Hand and the Zoom work anywhere, and what is already
  # under way still takes it (a box's handles, the crop's, a lasso's corners)
  if not d.inImage(ev):
    var takes = tool in {tHand, tZoom} or springing or dw.polyLassoOn
    if tool == tCrop and pendingCrop.on and pendingCrop.dw == dw: takes = true
    if tool == tMove and d.current.isLine and dw.lineEndAt(d.current, ui.mx, ui.my) >= 0: takes = true
    if tool == tMove and moveShowControls and not d.current.background and not d.editMask and not d.quickMask:
      let r = if d.hasSelection: d.clip(d.selBounds) else: d.layerBox(d.current)
      if r.w > 0 and r.h > 0:
        let h = dw.boxHit(quadOf(r), ui.mx, ui.my)
        if h >= 0: takes = true      # (a handle, or inside: it moves -- back onto the image)
    if tool == tMove and not takes and not d.editMask and not d.quickMask:
      # (type, a shape, a Smart Object moved off the image: still there -- a
      # press on its box picks it and drags it back)
      for i in countdown(d.layers.high, 0):
        let L = d.layers[i]
        if not L.visible or L.group or not (L.isText or L.isShape or L.isSmart): continue
        if d.layerBox(L).contains(point(int(floor(ev.x)), int(floor(ev.y)))):
          if i != d.cur:
            d.clearPicks()
            d.cur = i
            inc d.ver
          takes = true
          break
    if not takes:
      if te.on: commitType()            # (a click away from the text: it is done)
      drag = Drag()
      return
  drag = Drag(on: true, dw: dw, tool: tool, x0: ev.x, y0: ev.y, x1: ev.x, y1: ev.y, op: selOpFor(ev),
              lastTick: ui.now)
  pressWas = (d.stepsMade, pendingCrop, ruler, slices, te.on, shapeDlg.on)
  let xi = int(floor(ev.x))
  let yi = int(floor(ev.y))
  drag.sx = ui.mx
  drag.sy = ui.my
  if tool == tHand and handKind == 1 and not springing:
    drag.x0 = dw.view.angle          # (Rotate View: the angle it starts from)
    if ui.clicks >= 2:
      dw.view.angle = 0              # (double-click: straight again)
      if rotateAll:
        for o in docs: o.view.angle = 0
  let insideSel = d.hasSelection and xi >= 0 and yi >= 0 and xi < d.w and yi < d.h and
                  d.sel[yi * d.w + xi] >= 128
  # (type: rasterized first, when asked)
  if (tool in paintTools + {tBucket, tGradient, tHeal, tRedEye} or (tool == tShape and shapeMode == 2) or
      (tool in {tMarquee, tLasso, tWand} and insideSel and touchSelMode == 0 and
       ev.ctrl and not (ev.shift or ev.alt)) or (tool == tMove and d.hasSelection)) and
     not (tool in {tStamp, tHeal} and (ev.alt or stampPicking)) and
     not (tool == tBrush and brushTool == 3) and not d.needPixels():
    drag.on = false
    return
  if tool in {tMarquee, tLasso, tWand} and insideSel and touchSelMode == 0 and
     ev.ctrl and not (ev.shift or ev.alt):
    # Ctrl+drag inside the selection: its pixels move (the Move tool's way)
    dw.beginLift()
    return
  if insideSel and touchSelMode == 0 and not (ev.shift or ev.alt or ev.ctrl) and
     (tool == tMarquee or (tool == tLasso and lassoMode == 0) or (tool == tWand and wandMode notin {1, 3})):
    # inside the selection: its outline moves, the pixels stay (the usual);
    # a click there: Deselect (the Magic Wand: selects again)
    drag.selMove = true
    drag.sel0 = d.sel
    return
  if tool == tEraser and eraseKind == 1:
    # the Magic Eraser: the color clicked (and those like it) made transparent
    d.magicErase(xi, yi)
    drag.on = false
    return
  if tool == tCrop and cropKind == 2:
    # the Frame tool: a box drawn (released: a frame there)
    return
  if tool == tCrop and cropKind == 3:
    # the Slice tool: a box drawn (released: a slice there)
    return
  if tool == tCrop and cropKind == 4:
    # Slice Select: the slice clicked picked (and dragged to move it)
    sliceSel = -1
    for k in countdown(slices.high, 0):
      if slices[k].d == d and slices[k].r.contains(point(xi, yi)):
        sliceSel = k
        break
    if sliceSel >= 0: sliceGrab = (true, slices[sliceSel].r)
    else: drag.on = false
    return
  if tool == tEyedropper and dropKind in {3, 4}:
    # the Note tool (a note at the click; a click on one opens it, Alt+click
    # takes it away) and the Count tool (a number at each click)
    let near = (10.0 * pxScale.float / dw.view.scaleOf) ^ 2
    if dropKind == 3:
      var at = -1
      for k, n in notes:
        if n.d == d and (n.x - ev.x) ^ 2 + (n.y - ev.y) ^ 2 <= near * 2: at = k
      if ev.alt:
        if at >= 0: notes.delete(at)
      elif at >= 0: noteDlg = (true, at, notes[at].text)
      else:
        notes.add (d, ev.x, ev.y, "")
        noteDlg = (true, notes.high, "")
    else:
      var at = -1
      for k, c in counts:
        if c.d == d and (c.x - ev.x) ^ 2 + (c.y - ev.y) ^ 2 <= near: at = k
      if ev.alt:
        if at >= 0: counts.delete(at)
      elif at < 0: counts.add (d, ev.x, ev.y)
      var n = 0
      for c in counts:
        if c.d == d: inc n
      status = "Count: " & $n
    drag.on = false
    return
  if tool == tMove and moveKind == 1:
    # the Artboard tool: an artboard (or its name over it) dragged moves it;
    # elsewhere a box drawn is a new one
    let lh = (FontH + dp(4)).float / dw.view.scaleOf
    var hitBoard = d.artboardAt(xi, yi)
    if hitBoard < 0:
      for i in d.artboards:
        let b = d.layers[i].board
        if ev.x >= b.x.float and ev.x < (b.x + b.w).float and ev.y >= b.y.float - lh and ev.y < b.y.float:
          hitBoard = i
    drag.board = hitBoard
    if hitBoard >= 0:
      d.cur = hitBoard
      inc d.ver
      status = "Drag to move \"" & d.layers[hitBoard].name & "\" with all on it"
    return
  case tool
  of tMove:
    # (the current line's end: dragged, the line follows -- its arrowheads
    # with it; before Auto-Select picks what is under it)
    if moveKind == 0 and not d.hasSelection and not d.editMask and not d.quickMask and
       d.current.isLine and not d.current.locked:
      let k = dw.lineEndAt(d.current, ui.mx, ui.my)
      if k >= 0:
        d.beginStep("Line")
        d.touchLayers()
        lineGrab = (true, k)
        return
    # a double-click on text: edited where it was clicked -- the Type tool,
    # the caret at that letter; done (Ctrl+Enter, Esc, a click outside), the
    # Move tool again (as today's editors have it)
    if ev.clicks >= 2 and not ev.alt and moveKind == 0 and not d.editMask and not d.quickMask:
      let slack = dp(4).float / max(1e-6, dw.view.scaleOf)
      var hit = -1
      if d.current.visible and d.current.isText and d.current.hitsText(ev.x, ev.y, slack): hit = d.cur
      else:
        for i in countdown(d.layers.high, 0):
          let L = d.layers[i]
          if L.visible and L.isText and L.hitsText(ev.x, ev.y, slack):
            hit = i
            break
      if hit >= 0 and not d.layers[hit].locked:
        let L = d.layers[hit]
        if d.cur != hit:
          d.clearPicks()
          d.cur = hit
          inc d.ver
        d.editMask = false
        tool = tType
        typeMaskMode = false
        typeVertical = L.text.vertical
        typeBackToMove = true
        let l = layoutText(L.text)
        startTypeEdit(dw, L, false, L.text.charAtDrawn(l, ev.x.float32, ev.y.float32))
        status = "Editing the text (double-click with the Move tool): Ctrl+Enter, Esc or a click " &
                 "outside ends it -- then the Move tool again"
        drag.on = false
        return
    # (a handle of the current layer's box -- its corners, its sides, the
    # turning zone just outside them: the transform, at once; before
    # Auto-Select, which would pick the layer under the pointer there)
    if moveShowControls and not d.current.background and not d.editMask and not ev.alt and
       not d.quickMask and not d.current.isLine and
       not ((d.current.locked or d.current.lockPosition) and d.movedLayers.len == 1):
      let r = if d.hasSelection: d.clip(d.selBounds) else: d.layerBox(d.current)
      if r.w > 0 and r.h > 0:
        let h = dw.boxHit(quadOf(r), ui.mx, ui.my)
        if h >= 0 and h != 4:
          drag.on = false
          startTransform(xkScale)
          if xf.on:
            dw.transformMouse(ev)
          return
    var justPicked = false
    if (moveAutoSelect != (ev.ctrl and not springing)) and not ev.alt:
      # (Auto-Select: the top layer with something where it was clicked --
      # Ctrl+click when it is off, as the usual; Shift+click: picked with
      # the one picked before, they move together)
      let i = d.autoPicked(d.layerAt(xi, yi, dw.pickRadius))
      if i >= 0 and i != d.cur and ev.shift:
        d.current.picked = true
        d.layers[i].picked = true
        d.cur = i
        inc d.ver
        justPicked = true
        status = "Picked " & d.layers[i].name & " with the others: they move together"
      elif i >= 0 and i != d.cur:
        d.clearPicks()
        d.cur = i
        d.editMask = false
        inc d.ver
        justPicked = true
        status = "Picked the layer " & d.layers[i].name & " (Auto-Select: what you click is picked)"
    if not d.hasSelection and not d.editMask and not d.quickMask and
       (d.current.locked or d.current.lockPosition) and d.movedLayers.len == 1:
      status = "\"" & d.current.name & "\" is locked in place (the lock of Position in Layers)."
      drag.on = false
      return
    if ev.alt and not d.editMask and not d.quickMask and not d.current.background:
      # Alt: a copy moves (of the selection; else of the layer), the original stays
      if d.hasSelection:
        d.beginStep("Duplicate and Move")
        drag.lift = d.beginMove(bg, copy = true)
        drag.moving = true
        return
      d.beginStep("Duplicate Layer")
      d.touchLayers()
      discard d.duplicateLayer()
      d.endStep()
    let L = d.current
    if L.isText and not d.hasSelection and not d.editMask and not d.quickMask:
      # a type layer: its text moves (and stays text)
      d.beginStep("Move")
      d.touchLayers()
      textMove = (true, L.text)
    elif L.isShape and not d.hasSelection and not d.editMask and not d.quickMask:
      # a shape layer: its outline moves (and stays a shape)
      d.beginStep("Move")
      d.touchLayers()
      shapeMove = (true, L.shape, 0.0, 0.0)
    else:
      dw.beginLift()
  of tLasso:
    if lassoMode in {1, 2}:
      # (Polygonal and Magnetic Lasso: clicks, not a drag)
      polyLassoClick(dw, ev, drag.op)
      drag.on = false
      return
    drag.pts = @[(ev.x, ev.y)]
  of tWand:
    case wandMode
    of 1:
      # Quick Selection: the brush's path, then the selection grown from it
      drag.pts = @[(ev.x, ev.y)]
      if drag.op == soReplace and d.hasSelection and not ev.alt: drag.op = soAdd
    of 2:
      discard                       # (Object Selection: a box is dragged)
    of 3:
      # the Selection Brush: painted into the selection as it goes (Alt: the other way)
      d.beginStep("Selection Brush")
      d.touchSel()
      if not d.hasSelection: d.sel = newSeq[uint8](d.w * d.h)
      drag.pts = @[(ev.x, ev.y)]
      d.selBrushStamp(ev.x, ev.y, selBrushSub != ev.alt)
    else:
      var m = d.regionMask(xi, yi, wandTol, wandMerged, wandContig, wandAA)
      finishSelection(d, m, 0, "Magic Wand")
      drag.on = false
  of tHand:
    discard
  of tZoom:
    discard                         # (let go: a click zooms a step, a box zooms to it)
  of tEyedropper:
    case dropKind
    of 1:
      # the Color Sampler: a point read in the options bar (four an image);
      # Alt+click takes the nearest away
      var near = -1
      var best = (12.0 / dw.view.scaleOf) ^ 2
      for k, sp in samplers:
        if sp.d == d:
          let e = (sp.x.float + 0.5 - ev.x) ^ 2 + (sp.y.float + 0.5 - ev.y) ^ 2
          if e < best:
            best = e
            near = k
      if ev.alt:
        if near >= 0: samplers.delete(near)
      elif near < 0 and xi >= 0 and yi >= 0 and xi < d.w and yi < d.h:
        var n = 0
        for sp in samplers:
          if sp.d == d: inc n
        if n < 4: samplers.add (d, xi, yi)
        else: status = "Four color samplers an image: Alt+click one to take it away"
      drag.on = false
    of 2:
      # the Ruler: a line dragged; its angle and length in the options bar
      ruler = (true, d, ev.x, ev.y, ev.x, ev.y)
    else:
      let c = d.sampleAt(xi, yi, [1, 3, 5][dropperSize])
      if aOf(c) > 0:
        if ev.alt: bg = c or 0xFF000000'u32 else: fg = c or 0xFF000000'u32
  of tBucket:
    d.beginStep("Paint Bucket")
    d.bucketFill(xi, yi, paintOpts(tBucket, d), bucketTol, bucketAA, bucketPattern == 1 and pattern.len > 0,
                 bucketContig, bucketAll)
    d.endStep()
    drag.on = false
  of tType:
    typePress(dw, ev)
  of tCrop:
    # the box waiting: its corners and sides pulled, moved from inside (a
    # click inside without moving it crops); outside it, a new box
    let part = dw.cropHandleAt(ev.x, ev.y)
    if part >= 0:
      cropGrab = (true, part, ev.x, ev.y, pendingCrop.r, pendingCrop.q, false)
      return
    pendingCrop.on = false
  of tPen:
    if penMode == 8:
      # Content-Aware Tracing: the edge under the pointer becomes a path
      dw.tracePress(ev)
      drag.on = false
      return
    # the tools of the Paths palette, on the work path (the arrows: or on
    # the shape layer's outline)
    let radius = dp(5).float * pxScale.float / dw.view.scaleOf
    d.beginStep(["Path Arrow", "Pen", "Add Point", "Delete Point", "Convert Point", "Path Selection",
                 "Freeform Pen", "Curvature Pen"][clamp(penMode, 0, 7)])
    d.touchPaths()
    penDrag = (false, -1, -1, 0)
    penChanged = false
    penLast = (ev.x, ev.y)
    var has = d.curPath >= 0 and d.curPath < d.paths.len
    spEdit.on = false
    if not has and penMode in {0, 5} and d.current.isShape and not d.current.isFill:
      d.touchLayers()
      spEdit = (true, d.current, d.current.shape.path)
    template target(): untyped =
      (if spEdit.on: spEdit.path else: d.paths[d.curPath])
    case penMode
    of 0:
      if has or spEdit.on:
        let h = target().hitPoint(ev.x, ev.y, radius)
        if h.sub >= 0: penDrag = (true, h.sub, h.i, h.part)
    of 5:
      # Path Selection: the subpath under the mouse (inside it, or on its
      # line), dragged whole; Alt: a copy of it
      pathSel = -1
      if has or spEdit.on:
        let p = target()
        for si in countdown(p.subs.high, 0):
          var one = Path(subs: @[p.subs[si]])
          one.subs[0].op = poAdd
          var hit = false
          for poly in one.flatten(12):
            # inside (by the crossings of a ray), or near the line
            var inside = false
            for i in 0 ..< poly.len:
              let a = poly[i]
              let b = poly[(i + 1) mod poly.len]
              if (a[1] > ev.y) != (b[1] > ev.y) and
                 ev.x < (b[0] - a[0]) * (ev.y - a[1]) / (b[1] - a[1] + 1e-12) + a[0]:
                inside = not inside
            if inside and p.subs[si].closed: hit = true
          if not hit and one.nearestSegment(ev.x, ev.y, radius).sub >= 0: hit = true
          if hit:
            pathSel = si
            break
        if pathSel >= 0:
          if ev.alt:
            if spEdit.on: spEdit.path.subs.add spEdit.path.subs[pathSel]
            else: d.paths[d.curPath].subs.add d.paths[d.curPath].subs[pathSel]
            pathSel = target().subs.high
            penChanged = true
          penDrag = (true, pathSel, -1, 9)
      inc d.ver
    of 2:
      if has:
        let h = d.paths[d.curPath].nearestSegment(ev.x, ev.y, radius)
        if h.sub >= 0:
          d.paths[d.curPath].addPoint(h)
          penDrag = (true, h.sub, h.i + 1, 0)
          penChanged = true
    of 3:
      if has:
        let h = d.paths[d.curPath].hitPoint(ev.x, ev.y, radius, handles = false)
        if h.sub >= 0:
          d.paths[d.curPath].deletePoint(h.sub, h.i)
          penChanged = true
    of 4:
      if has:
        let h = d.paths[d.curPath].hitPoint(ev.x, ev.y, radius, handles = false)
        if h.sub >= 0:
          let q = d.paths[d.curPath].subs[h.sub].pts[h.i]
          if q.inH != q.p or q.outH != q.p:
            d.paths[d.curPath].convertPoint(h.sub, h.i)
            penChanged = true
          else:
            penDrag = (true, h.sub, h.i, 3)
    of 6:
      # the Freeform Pen: the line drawn becomes the path (when the mouse comes up)
      drag.pts = @[(ev.x, ev.y)]
      penChanged = true
    of 7:
      # the Curvature Pen: each click a point the curve goes smoothly
      # through; a point of it dragged (Alt+click: a corner, or smooth again);
      # the first point clicked closes it
      if not has:
        d.paths.add Path(name: "Work Path")
        d.curPath = d.paths.high
      var p = addr d.paths[d.curPath]
      if p.subs.len == 0 or p.subs[^1].closed or penEnded:
        p.subs.add SubPath()
        curvCorners = @[]
        penEnded = false
      let sp = addr p.subs[^1]
      curvCorners.setLen(sp.pts.len)
      penChanged = true
      for i, q in sp.pts:
        let (sx, sy) = dw.view.toScreen(d, q.p[0], q.p[1])
        if abs(sx - ui.mx) <= dp(5) and abs(sy - ui.my) <= dp(5):
          if ev.alt:
            curvCorners[i] = not curvCorners[i]
          elif i == 0 and sp.pts.len >= 3:
            sp.closed = true
          else:
            penDrag = (true, p.subs.high, i, 7)
          sp[].smoothThrough(curvCorners)
          inc d.ver
          return
      sp.pts.add PathPoint(p: (ev.x, ev.y), inH: (ev.x, ev.y), outH: (ev.x, ev.y))
      curvCorners.add false
      sp[].smoothThrough(curvCorners)
      penDrag = (true, p.subs.high, sp.pts.high, 7)
    else:
      # the pen: a point of the work path (a new one when there is none)
      if not has:
        d.paths.add Path(name: "Work Path")
        d.curPath = d.paths.high
      var p = addr d.paths[d.curPath]
      if p.subs.len == 0 or p.subs[^1].closed or penEnded:
        p.subs.add SubPath()
        penEnded = false
      let sp = addr p.subs[^1]
      penChanged = true
      if sp.pts.len >= 3:
        let (sx, sy) = dw.view.toScreen(d, sp.pts[0].p[0], sp.pts[0].p[1])
        if abs(sx - ui.mx) <= dp(5) and abs(sy - ui.my) <= dp(5):
          sp.closed = true
          inc d.ver
          return
      sp.pts.add PathPoint(p: (ev.x, ev.y), inH: (ev.x, ev.y), outH: (ev.x, ev.y))
      penDrag = (true, p.subs.high, sp.pts.high, 3)
    inc d.ver
  of tHeal:
    case healMode
    of 0, 3:
      # Spot Healing, Remove: the stroke shows where; healed when it ends
      var o = paintOpts(tHeal, d)
      o.tool = tkBrush
      o.color = if healMode == 3: 0xFFFF40C0'u32 else: 0xFF404040'u32
      o.opacity = 55
      o.mode = bmNormal
      o.fade = 0
      d.beginStep(if healMode == 3: "Remove Tool" else: "Spot Healing Brush")
      drag.stroke = d.beginStroke(o, tipFor(tHeal), ev.x, ev.y)
      drag.stroke.startStroke()
    of 1:
      # the Healing Brush: a copy (as the Rubber Stamp), then made to fit
      if ev.alt or stampPicking:
        stampPicking = false
        stampSrc = (true, ev.x, ev.y, d)
        resetStampAlignment()
        status = "Source set"
        drag.on = false
        return
      if not stampSrc.set:
        status = "Alt+click first to set where the copy comes from"
        drag.on = false
        return
      var o = paintOpts(tStamp, d)
      o.tool = tkStamp
      o.stamp = smCloneAligned
      o.opacity = 100
      o.mode = bmNormal
      d.beginStep("Healing Brush")
      drag.stroke = d.beginStroke(o, tipFor(tHeal), ev.x, ev.y)
      drag.stroke.startStroke()
    else:
      # the Patch: drag the selection to the texture to take; outside it,
      # draw one (as the lasso)
      if not insideSel:
        drag.tool = tLasso
        drag.pts = @[(ev.x, ev.y)]
  of tRedEye:
    discard
  of tStamp:
    if stampTool == 2:
      # the Art History Brush: quick strokes in the colors of the state marked
      artSrc = d.historySourcePixels(d.layer)
      if artSrc.len == 0:
        status = "The layer was not there then (History palette: mark another state)"
        drag.on = false
        return
      d.beginStep("Art History Brush")
      d.artHistoryDabs(artSrc, ev.x, ev.y, tipFor(tool).diameter.float, ArtStyle(clamp(artStyle, 0, 9)),
                       artArea.float, artTolerance, opts[tool].opacity, artSeed, PaintModes[opts[tool].mode])
      drag.smx = ev.x
      drag.smy = ev.y
      return
    if stampTool == 0 and (ev.alt or stampPicking):
      stampPicking = false
      stampSrc = (true, ev.x, ev.y, d)
      resetStampAlignment()
      status = "Source set"
      drag.on = false
      return
    if stampTool == 0 and not stampSrc.set and StampMode(stampMode) in {smCloneAligned, smClone, smImpressionist}:
      status = "Alt+click first to set where the copy comes from"
      drag.on = false
      return
    d.beginStep(toolName(tool))
    drag.stroke = d.beginStroke(paintOpts(tool, d), tipFor(tool), ev.x, ev.y, ui.pressure)
    drag.stroke.penPose(ui.tilt, ui.azimuth, ui.twist)
    drag.stroke.startStroke()
  of paintTools - {tStamp}:
    if tool == tBrush and brushTool == 3:
      dw.adjBrushPress(ev)
      return
    if tool == tEraser and eraseKind == 2 and d.current.background and not d.onMask:
      # (the Background Eraser rubs out to transparency: the Background becomes a layer)
      d.beginStep("Layer from Background")
      d.touchLayers()
      d.layerFromBackground()
      d.endStep()
    var o = paintOpts(tool, d)
    if tool == tBlur and ev.alt:
      o.tool = if o.tool == tkBlur: tkSharpen else: tkBlur
    if tool == tDodge and ev.alt and o.tool in {tkDodge, tkBurn}:
      o.tool = if o.tool == tkDodge: tkBurn else: tkDodge      # (Alt: the other, as the usual)
    d.beginStep(toolName(tool))
    if ev.shift and dw.hasLastPaint:
      drag.stroke = d.beginStroke(o, tipFor(tool), dw.lastPaint[0], dw.lastPaint[1], ui.pressure)
      drag.stroke.penPose(ui.tilt, ui.azimuth, ui.twist)
      drag.stroke.strokeTo(ev.x, ev.y, ui.pressure)
    else:
      drag.stroke = d.beginStroke(o, tipFor(tool), ev.x, ev.y, ui.pressure)
      drag.stroke.penPose(ui.tilt, ui.azimuth, ui.twist)
      drag.stroke.startStroke()
    dw.lastPaint = (ev.x, ev.y)
    dw.hasLastPaint = true
    drag.smx = ev.x
    drag.smy = ev.y
  else: discard

proc dragOn(ev: PhotoEvent) =
  let dw = drag.dw
  let d = dw.doc
  var (x, y) = (ev.x, ev.y)
  if drag.tool == tMarquee and marqueeShape < 2 and not drag.selMove:
    # Shift: a square (a circle), Alt: from the middle -- held after the
    # drag began (held before: they add, take away); Fixed Ratio
    let square = ev.shift and drag.op notin {soAdd, soIntersect}
    drag.center = ev.alt and drag.op notin {soSubtract, soIntersect}
    (x, y) = constrained(drag.x0, drag.y0, x, y, square)
  elif drag.tool == tGradient and ev.shift:
    # (Shift: at 45 degrees)
    let a = round(arctan2(y - drag.y0, x - drag.x0) / (PI / 4)) * (PI / 4)
    let l = hypot(x - drag.x0, y - drag.y0)
    x = drag.x0 + l * cos(a)
    y = drag.y0 + l * sin(a)
  drag.x1 = x
  drag.y1 = y
  if lineGrab.on and d.current.isLine:
    # a line's end where the mouse is (Shift: at 45 degrees from the other end)
    let L = d.current
    var s = L.shape
    let i = clamp(lineGrab.i, 0, s.path.subs[0].pts.high)
    let other = s.path.subs[0].pts[if i == 0: s.path.subs[0].pts.high else: 0].p
    var (px, py) = (x, y)
    if ev.shift:
      let a = round(arctan2(py - other[1], px - other[0]) / (PI / 4)) * (PI / 4)
      let l = hypot(px - other[0], py - other[1])
      px = other[0] + l * cos(a)
      py = other[1] + l * sin(a)
    let q = s.path.subs[0].pts[i]
    let (dx, dy) = (px - q.p[0], py - q.p[1])
    s.path.subs[0].pts[i] = PathPoint(p: (px, py), inH: (q.inH[0] + dx, q.inH[1] + dy),
                                      outH: (q.outH[0] + dx, q.outH[1] + dy))
    d.setShape(L, s)
    inc d.ver
    return
  if sliceGrab.on and sliceSel in 0 .. slices.high:
    let r0 = sliceGrab.r0
    slices[sliceSel].r = rect(clamp(r0.x + int(round(x - drag.x0)), 0, max(0, d.w - r0.w)),
                              clamp(r0.y + int(round(y - drag.y0)), 0, max(0, d.h - r0.h)), r0.w, r0.h)
    return
  if drag.selMove:
    var dx = int(round(x - drag.x0))
    var dy = int(round(y - drag.y0))
    if ev.shift:
      if abs(dx) > abs(dy): dy = 0 else: dx = 0
    if (dx != 0 or dy != 0) and not drag.selStepped:
      d.beginStep("Move Selection")
      d.touchSel()
      drag.selStepped = true
    if drag.selStepped: d.moveSelection(drag.sel0, dx, dy)
    return
  if cropGrab.on and pendingCrop.on:
    let dx = x - cropGrab.x
    let dy = y - cropGrab.y
    if abs(dx) + abs(dy) > 0.5 * pxScale.float / dw.view.scaleOf: cropGrab.moved = true
    if not cropGrab.moved: return
    # (the corners kept near the image: a box far outside it would make a huge one)
    template keepNear(px, py: float): (float, float) =
      (clamp(px, -d.w.float, 2 * d.w.float), clamp(py, -d.h.float, 2 * d.h.float))
    if pendingCrop.persp:
      var q = cropGrab.q0
      if cropGrab.part == 8:
        for c in q.mitems: c = keepNear(c[0] + dx, c[1] + dy)
      elif cropGrab.part in 0 .. 3:
        q[cropGrab.part] = keepNear(cropGrab.q0[cropGrab.part][0] + dx, cropGrab.q0[cropGrab.part][1] + dy)
      if quadIsFine(q): pendingCrop.q = q
    else:
      let r0 = cropGrab.r0
      var (x0, y0, x1, y1) = (r0.x.float, r0.y.float, (r0.x + r0.w).float, (r0.y + r0.h).float)
      case cropGrab.part
      of 0: (x0, y0) = (x0 + dx, y0 + dy)
      of 1: (x1, y0) = (x1 + dx, y0 + dy)
      of 2: (x1, y1) = (x1 + dx, y1 + dy)
      of 3: (x0, y1) = (x0 + dx, y1 + dy)
      of 4: y0 += dy
      of 5: x1 += dx
      of 6: y1 += dy
      of 7: x0 += dx
      else:
        # (moved whole, kept on the image)
        let mx = clamp(dx, -x0, d.w.float - x1)
        let my = clamp(dy, -y0, d.h.float - y1)
        (x0, y0, x1, y1) = (x0 + mx, y0 + my, x1 + mx, y1 + my)
      if ev.shift and cropGrab.part in 0 .. 3 and r0.w > 0 and r0.h > 0:
        # (Shift: the box keeps its proportions)
        let ratio = r0.w / r0.h
        let w = abs(x1 - x0)
        let h = w / ratio
        if cropGrab.part in {0, 1}: y0 = y1 - h else: y1 = y0 + h
      # (the handles go past the image: the canvas grows -- filled with the
      # background color, or made up by Content-Aware)
      let nx0 = clamp(min(x0, x1), -d.w.float, d.w.float)
      let ny0 = clamp(min(y0, y1), -d.h.float, d.h.float)
      let nx1 = clamp(max(x0, x1), 0.0, 2 * d.w.float)
      let ny1 = clamp(max(y0, y1), 0.0, 2 * d.h.float)
      let r = rect(int(round(nx0)), int(round(ny0)), int(round(nx1 - nx0)), int(round(ny1 - ny0)))
      if r.w >= 1 and r.h >= 1: pendingCrop.r = r
    return
  if drag.tool == tEyedropper and dropKind == 2 and ruler.d == d:
    if ev.shift:
      # (Shift: at 45 degrees)
      let a = round(arctan2(y - ruler.y0, x - ruler.x0) / (PI / 4)) * (PI / 4)
      let l = sqrt((x - ruler.x0) ^ 2 + (y - ruler.y0) ^ 2)
      x = ruler.x0 + l * cos(a)
      y = ruler.y0 + l * sin(a)
    ruler.x1 = x
    ruler.y1 = y
    return
  if drag.moving or textMove.on or shapeMove.on:
    # (Smart Guides: lined up with the rest as it goes -- Ctrl held: free)
    if drag.tool == tMove and (not sg.on or sg.d != d): drag.dw.smartBegin()
  if drag.moving:
    var fx = x - drag.x0
    var fy = y - drag.y0
    if ev.shift:
      if abs(fx) > abs(fy): fy = 0 else: fx = 0
    if drag.tool == tMove: drag.dw.smartSnap(fx, fy, ev.shift and fx == 0, ev.shift and fy == 0)
    let dx = int(round(fx))
    let dy = int(round(fy))
    if dx != drag.lift.dx or dy != drag.lift.dy: d.moveTo(drag.lift, dx, dy)
    return
  if textMove.on:
    var fx = x - drag.x0
    var fy = y - drag.y0
    if ev.shift:
      if abs(fx) > abs(fy): fy = 0 else: fx = 0
    drag.dw.smartSnap(fx, fy, ev.shift and fx == 0, ev.shift and fy == 0)
    let dx = float32(round(fx))
    let dy = float32(round(fy))
    let moved = textMove.orig.moved(dx, dy)
    if moved != d.current.text and d.current.isText: d.setText(d.current, moved)
    return
  if shapeMove.on:
    var fx = x - drag.x0
    var fy = y - drag.y0
    if ev.shift:
      if abs(fx) > abs(fy): fy = 0 else: fx = 0
    drag.dw.smartSnap(fx, fy, ev.shift and fx == 0, ev.shift and fy == 0)
    let dx = round(fx)
    let dy = round(fy)
    if (dx, dy) != (shapeMove.dx, shapeMove.dy) and d.current.isShape:
      shapeMove.dx = dx
      shapeMove.dy = dy
      var s = shapeMove.orig
      s.path.mapPoints(proc (px, py: float): (float, float) = (px + dx, py + dy))
      d.setShape(d.current, s)
    return
  case drag.tool
  of tLasso:
    if drag.pts.len == 0 or abs(drag.pts[^1][0] - x) + abs(drag.pts[^1][1] - y) >= 0.75:
      drag.pts.add (x, y)
  of tWand:
    if wandMode == 3 and drag.pts.len > 0:
      # (the Selection Brush: dabs along the way, a few to its width)
      let (lx, ly) = drag.pts[^1]
      let step = max(1.0, quickSize.float / 6)
      let dist = hypot(x - lx, y - ly)
      if dist >= step:
        let n = int(dist / step)
        for k in 1 .. n:
          let t = k.float / n.float
          d.selBrushStamp(lx + (x - lx) * t, ly + (y - ly) * t, selBrushSub != ev.alt)
        drag.pts.add (x, y)
    if wandMode == 1 and (drag.pts.len == 0 or hypot(drag.pts[^1][0] - x, drag.pts[^1][1] - y) >= 2):
      drag.pts.add (x, y)
  of tHand:
    if handKind == 1 and not springing:
      # Rotate View: turned as the mouse goes round the view's middle (Shift: by 15 degrees)
      let vr = dw.view.view
      let cx = vr.x.float + vr.w.float / 2
      let cy = vr.y.float + vr.h.float / 2
      let a0 = arctan2(drag.sy.float - cy, drag.sx.float - cx)
      let a1 = arctan2(ui.my.float - cy, ui.mx.float - cx)
      var ang = drag.x0 + radToDeg(a1 - a0)
      ang = ang - 360 * floor((ang + 180) / 360)
      if ev.shift: ang = round(ang / 15) * 15
      if abs(ang) < 0.5: ang = 0
      dw.view.angle = ang
      if rotateAll:
        for o in docs: o.view.angle = ang
    else:
      dw.view.scrollBy(d, drag.sx - ui.mx, drag.sy - ui.my)
      drag.sx = ui.mx
      drag.sy = ui.my
  of tEyedropper:
    let c = d.sampleAt(int(floor(x)), int(floor(y)), [1, 3, 5][dropperSize])
    if aOf(c) > 0:
      if ev.alt: bg = c or 0xFF000000'u32 else: fg = c or 0xFF000000'u32
  of tType:
    typeDrag(dw, ev)
  of paintTools:
    if drag.tool == tStamp and stampTool == 2:
      # (the Art History Brush: more strokes each half its size the mouse goes)
      let sz = max(2.0, tipFor(tool).diameter.float)
      if hypot(x - drag.smx, y - drag.smy) >= sz / 2:
        d.artHistoryDabs(artSrc, x, y, sz, ArtStyle(clamp(artStyle, 0, 9)), artArea.float, artTolerance,
                         opts[tool].opacity, artSeed, PaintModes[opts[tool].mode])
        drag.smx = x
        drag.smy = y
      return
    if drag.stroke.dabs >= 0:
      if brushSmoothing > 0 and tool notin {tStamp}:
        # (smoothing: the stroke goes part of the way to the mouse)
        let k = 1 - brushSmoothing / 100 * 0.92
        drag.smx += (x - drag.smx) * k
        drag.smy += (y - drag.smy) * k
        drag.stroke.penPose(ui.tilt, ui.azimuth, ui.twist)
        drag.stroke.strokeTo(drag.smx, drag.smy, ui.pressure)
      else:
        drag.stroke.penPose(ui.tilt, ui.azimuth, ui.twist)
        drag.stroke.strokeTo(x, y, ui.pressure)
      dw.lastPaint = (x, y)
      dw.hasLastPaint = true
  of tHeal:
    if healMode in {0, 1, 3} and drag.stroke.dabs >= 0: drag.stroke.strokeTo(x, y)
  of tPen:
    if penMode == 6:
      if drag.pts.len == 0 or hypot(x - drag.pts[^1][0], y - drag.pts[^1][1]) >= 0.5: drag.pts.add (x, y)
      return
    let tp = if spEdit.on: addr spEdit.path
             elif d.curPath >= 0 and d.curPath < d.paths.len: addr d.paths[d.curPath]
             else: nil
    if penDrag.on and penDrag.part == 7 and tp != nil and penDrag.s < tp.subs.len and
       penDrag.i < tp.subs[penDrag.s].pts.len:
      # (the Curvature Pen's point moved: the curve follows)
      tp.subs[penDrag.s].pts[penDrag.i].p = (x, y)
      tp.subs[penDrag.s].smoothThrough(curvCorners)
      penChanged = true
      inc d.ver
      return
    if penDrag.on and penDrag.part == 9 and tp != nil and penDrag.s < tp.subs.len:
      # a whole subpath moved
      let dx = x - penLast[0]
      let dy = y - penLast[1]
      for q in tp.subs[penDrag.s].pts.mitems:
        q.p = (q.p[0] + dx, q.p[1] + dy)
        q.inH = (q.inH[0] + dx, q.inH[1] + dy)
        q.outH = (q.outH[0] + dx, q.outH[1] + dy)
      penLast = (x, y)
      penChanged = true
      if spEdit.on and spEdit.layer.isShape:
        var sh = spEdit.layer.shape
        sh.path = spEdit.path
        d.setShape(spEdit.layer, sh)
      inc d.ver
    elif penDrag.on and tp != nil and
       penDrag.s < tp.subs.len and penDrag.i >= 0 and penDrag.i < tp.subs[penDrag.s].pts.len:
      let q = addr tp.subs[penDrag.s].pts[penDrag.i]
      case penDrag.part
      of 0:
        # the point, with its handles
        let dx = x - penLast[0]
        let dy = y - penLast[1]
        q.p = (q.p[0] + dx, q.p[1] + dy)
        q.inH = (q.inH[0] + dx, q.inH[1] + dy)
        q.outH = (q.outH[0] + dx, q.outH[1] + dy)
      of 1:
        let smooth = q.outH != q.p
        q.inH = (x, y)
        if smooth: q.outH = (2 * q.p[0] - x, 2 * q.p[1] - y)
      of 2:
        let smooth = q.inH != q.p
        q.outH = (x, y)
        if smooth: q.inH = (2 * q.p[0] - x, 2 * q.p[1] - y)
      else:
        # pulling the handles out of a point (the pen, Convert Point)
        q.outH = (x, y)
        q.inH = (2 * q.p[0] - x, 2 * q.p[1] - y)
      penLast = (x, y)
      penChanged = true
      if spEdit.on and spEdit.layer.isShape:
        var sh = spEdit.layer.shape
        sh.path = spEdit.path
        sh.kind = ""                       # (its points moved: a path now, not a rectangle)
        d.setShape(spEdit.layer, sh)
      inc d.ver
  else: discard

proc releaseOn(ev: PhotoEvent) =
  let dw = drag.dw
  let d = dw.doc
  sg.on = false                    # (the Smart Guides of a move: gone with it)
  if drag.selMove:
    if drag.selStepped: d.endStep()
    elif drag.tool == tWand and wandMode == 0:
      # (a click inside: the Magic Wand selects again)
      let xi = int(floor(drag.x0))
      let yi = int(floor(drag.y0))
      if xi >= 0 and yi >= 0 and xi < d.w and yi < d.h:
        drag.op = soReplace
        var m = d.regionMask(xi, yi, wandTol, wandMerged, wandContig, wandAA)
        finishSelection(d, m, 0, "Magic Wand")
    else:
      d.beginStep("Deselect")
      d.touchSel()
      d.selectNone()
      d.endStep()
    drag = Drag()
    return
  if cropGrab.on:
    let clicked = cropGrab.part == 8 and not cropGrab.moved
    cropGrab.on = false
    drag = Drag()
    if clicked: commitCropNow()      # (a click inside the box: cropped)
    return
  if drag.moving:
    d.endMove(drag.lift)
    d.endStep()
    drag = Drag()
    return
  if lineGrab.on:
    lineGrab.on = false
    d.endStep()
    drag = Drag()
    return
  if textMove.on or shapeMove.on:
    textMove.on = false
    shapeMove.on = false
    d.endStep()
    drag = Drag()
    return
  if sliceGrab.on:
    sliceGrab.on = false
    drag = Drag()
    return
  if drag.tool == tCrop and cropKind == 3:
    let r = d.clip(rect(int(round(min(drag.x0, drag.x1))), int(round(min(drag.y0, drag.y1))),
                        int(round(abs(drag.x1 - drag.x0))), int(round(abs(drag.y1 - drag.y0)))))
    if r.w >= 2 and r.h >= 2:
      slices.add (d, r)
      sliceSel = slices.high
      var n = 0
      for sl in slices:
        if sl.d == d: inc n
      status = "Slice " & $n & ": File > Export > Slices to Files saves each"
    drag = Drag()
    return
  if drag.tool == tCrop and cropKind == 2:
    var (x0, y0, x1, y1) = (min(drag.x0, drag.x1), min(drag.y0, drag.y1), max(drag.x0, drag.x1), max(drag.y0, drag.y1))
    if ev.shift:
      let side = max(x1 - x0, y1 - y0)
      (x1, y1) = (x0 + side, y0 + side)
    if x1 - x0 >= 4 and y1 - y0 >= 4:
      var n = 1
      for L in d.layers:
        if L.name.startsWith("Frame "): inc n
      var sd = ShapeData(fill: solidPaint(0xFFC8C8C8'u32), stroke: solidPaint(0xFF808080'u32), strokeWidth: 1,
                         kind: if frameEllipse: "Ellipse" else: "Rectangle")
      sd.path = if frameEllipse: ellipsePath(x0, y0, x1, y1) else: rectPath(x0, y0, x1, y1)
      d.beginStep("New Frame")
      d.touchLayers()
      discard d.addShapeLayer(sd, "Frame " & $n)
      d.endStep()
      status = "A frame: Layer > Place Into... (or Place Embedded) puts a picture inside it"
    drag = Drag()
    return
  if drag.tool == tMove and moveKind == 1:
    let dx = int(round(drag.x1 - drag.x0))
    let dy = int(round(drag.y1 - drag.y0))
    if drag.board >= 0 and drag.board < d.layers.len:
      if abs(dx) + abs(dy) >= 1:
        d.beginStep("Move Artboard")
        d.moveArtboard(drag.board, dx, dy)
        d.endStep()
    else:
      let r = d.clip(rect(int(round(min(drag.x0, drag.x1))), int(round(min(drag.y0, drag.y1))),
                          int(round(abs(drag.x1 - drag.x0))), int(round(abs(drag.y1 - drag.y0)))))
      if r.w >= 8 and r.h >= 8:
        d.beginStep("New Artboard")
        let G = d.addArtboard(r)
        d.endStep()
        if G != nil: status = "\"" & G.name & "\": what is put in its group shows only on it"
    drag = Drag()
    return
  case drag.tool
  of tZoom:
    let (a, b) = dw.view.toScreen(d, drag.x0, drag.y0)
    let (c, e) = dw.view.toScreen(d, drag.x1, drag.y1)
    if not ev.alt and abs(c - a) >= dp(8) and abs(e - b) >= dp(8):
      # (a box dragged: zoomed to show it all)
      dw.view.zoomToRect(d, drag.x0, drag.y0, drag.x1, drag.y1)
      dw.afterZoom((drag.x0 + drag.x1) / 2, (drag.y0 + drag.y1) / 2, true)
    else:
      if ev.alt: dw.view.zoomOut(d, drag.x0, drag.y0) else: dw.view.zoomIn(d, drag.x0, drag.y0)
      dw.afterZoom(drag.x0, drag.y0, true)
  of tType:
    typeRelease(dw, ev)
  of tMarquee:
    let (x0, y0, x1, y1) = marqueeBox()
    let tiny = abs(drag.x1 - drag.x0) < 1 and abs(drag.y1 - drag.y0) < 1 and marqueeStyle != 2
    if marqueeShape >= 2:
      var m = newSeq[uint8](d.w * d.h)
      let yi = clamp(int(floor(drag.y1)), 0, d.h - 1)
      let xi = clamp(int(floor(drag.x1)), 0, d.w - 1)
      if marqueeShape == 2:
        for x in 0 ..< d.w: m[yi * d.w + x] = 255
      else:
        for y in 0 ..< d.h: m[y * d.w + xi] = 255
      finishSelection(d, m, 0, "Marquee")
    elif tiny:
      if drag.op == soReplace and d.hasSelection:
        d.beginStep("Select None")
        d.touchSel()
        d.selectNone()
        d.endStep()
    else:
      var m = if marqueeShape == 0:
                d.rectMask(rect(int(round(x0)), int(round(y0)), int(round(x1)) - int(round(x0)),
                                int(round(y1)) - int(round(y0))))
              else: d.ellipseMask(x0, y0, x1, y1, marqueeAA)
      finishSelection(d, m, marqueeFeather, "Marquee")
  of tWand:
    if wandMode == 3:
      # (the Selection Brush: what was painted is the selection now)
      if d.hasSelection and d.selectionEmpty: d.selectNone()
      if d.stepOpen: d.endStep()
    elif wandMode == 1 and drag.pts.len > 0:
      # the brush's path: seeds; the area round it, where the selection may grow
      var seeds = newSeq[uint8](d.w * d.h)
      let rad = max(1.0, quickSize / 2)
      var x0 = d.w.float
      var y0 = d.h.float
      var x1, y1 = 0.0
      for (px, py) in drag.pts:
        x0 = min(x0, px); y0 = min(y0, py); x1 = max(x1, px); y1 = max(y1, py)
        for yy in max(0, int(py - rad)) .. min(d.h - 1, int(py + rad)):
          for xx in max(0, int(px - rad)) .. min(d.w - 1, int(px + rad)):
            if hypot(xx.float - px, yy.float - py) <= rad: seeds[yy * d.w + xx] = 255
      let grow = rad * 5
      let area = rect(int(x0 - grow), int(y0 - grow), int(x1 - x0 + 2 * grow), int(y1 - y0 + 2 * grow))
      beginBusy("Quick Selection")
      try:
        var m = d.quickSelect(seeds, area, wandMerged)
        for i in 0 ..< m.len: m[i] = max(m[i], seeds[i])
        if ev.alt: drag.op = soSubtract
        finishSelection(d, m, 0, "Quick Selection")
      finally: endBusy()
    elif wandMode == 2:
      let bx0 = int(min(drag.x0, drag.x1))
      let by0 = int(min(drag.y0, drag.y1))
      let bw = int(abs(drag.x1 - drag.x0))
      let bh = int(abs(drag.y1 - drag.y0))
      if bw < 6 and bh < 6 and objectFinder:
        # Object Finder: a click on the thing shown -- it is selected
        let segs = d.findSegments()
        let k = segs.regionAt(drag.x1, drag.y1)
        if k >= 0:
          beginBusy("Object Selection")
          try:
            d.updateComposite()
            let src = if wandMerged: Img(w: d.w, h: d.h, px: d.compCopy) else: Img(w: d.w, h: d.h, px: d.layer.px)
            var m = findObject(src, segs, k)
            finishSelection(d, m, 0, "Object Selection")
          finally: endBusy()
      elif bw >= 6 and bh >= 6:
        beginBusy("Object Selection")
        try:
          var m = d.objectSelect(rect(bx0, by0, bw, bh), wandMerged)
          finishSelection(d, m, 0, "Object Selection")
        finally: endBusy()
  of tLasso:
    if drag.pts.len >= 3:
      var m = d.polygonMask(drag.pts, lassoAA)
      finishSelection(d, m, lassoFeather, "Lasso")
    elif drag.op == soReplace and d.hasSelection:
      d.beginStep("Select None")
      d.touchSel()
      d.selectNone()
      d.endStep()
  of tCrop:
    if cropStraighten:
      # the line drawn made level (or upright): the image turned and cut to what it fills
      let dx = drag.x1 - drag.x0
      let dy = drag.y1 - drag.y0
      if hypot(dx, dy) >= 4:
        var deg = radToDeg(arctan2(dy, dx))
        while deg > 45: deg -= 90
        while deg < -45: deg += 90
        if abs(deg) >= 0.05:
          try:
            d.snapStep("Straighten")
            d.straighten(-deg, bg)
            d.endStep()
            dw.fitWindow()
          except ValueError:
            d.cancelStep()
            status = "The image would be too big"
        cropStraighten = false
      drag = Drag()
      return
    let (x0, y0) = (min(drag.x0, drag.x1), min(drag.y0, drag.y1))
    let (x1, y1) = (max(drag.x0, drag.x1), max(drag.y0, drag.y1))
    let r = d.clip(rect(int(round(x0)), int(round(y0)), int(round(x1 - x0)), int(round(y1 - y0))))
    if r.w >= 2 and r.h >= 2:
      pendingCrop = (true, dw, r, cropKind == 1, quadOf(r))
      status = if cropKind == 1: "Drag the corners onto lines that should be straight; Enter to crop, Esc to cancel"
               else: "Drag the handles to change the box; click inside it (or press Enter) to crop; Esc to cancel"
  of tGradient:
    if abs(drag.x1 - drag.x0) + abs(drag.y1 - drag.y0) >= 1:
      d.beginStep("Gradient")
      var stops = toolStops()
      if d.onMask:
        # (on a mask: the gradient in grays -- black hides, white shows)
        for st in stops.mitems: st.color = grayOf(st.color)
      d.gradientFill(drag.x0, drag.y0, drag.x1, drag.y1, paintOpts(tGradient, d), stops,
                     GradientKind(clamp(gradKind, 0, 4)), gradReverse, gradDither, gradOffset)
      d.endStep()
  of tShape:
    if abs(drag.x1 - drag.x0) + abs(drag.y1 - drag.y0) >= 0.5:
      dw.finishShape(ev)
    elif shapeKind notin {4} and shapeMode != 1:
      # (a click: the size typed -- the usual Create Rectangle)
      shapeDlg = (true, dw, drag.x0, drag.y0, max(1, shapeDlg.w), max(1, shapeDlg.h), shapeDlg.center)
  of paintTools:
    if drag.tool == tStamp and stampTool == 2:
      artSrc = @[]
      d.endStep()
      drag = Drag()
      return
    if brushSmoothing > 0 and tool notin {tStamp} and drag.stroke.dabs > 0:
      drag.stroke.strokeTo(drag.x1, drag.y1)      # (it catches up at the end)
    drag.stroke.endStroke()
    d.endStep()
  of tHeal:
    case healMode
    of 0:
      status = "Healing..."
      drag.stroke.spotHeal(int(epochTime() * 1000) mod 9973 + 1, SpotHealKind(clamp(spotKind, 0, 2)))
      drag.stroke.endStroke()
      d.endStep()
      status = ""
    of 1:
      drag.stroke.healStroke()
      drag.stroke.endStroke()
      d.endStep()
    of 3:
      beginBusy("Remove Tool")
      try:
        drag.stroke.removeStroke()
        drag.stroke.endStroke()
      finally: endBusy()
      d.endStep()
    else:
      let dx = int(round(drag.x1 - drag.x0))
      let dy = int(round(drag.y1 - drag.y0))
      if d.hasSelection and abs(dx) + abs(dy) >= 1:
        if healMode == 4:
          beginBusy("Content-Aware Move")
          try:
            d.beginStep(if camExtend: "Content-Aware Extend" else: "Content-Aware Move")
            d.contentAwareMove(dx, dy, camExtend)
            d.endStep()
          finally: endBusy()
        else:
          d.beginStep("Patch")
          d.patch(dx, dy, destination = patchDest, transparent = patchTransparent,
                  contentAware = patchContentAware == 1, structure = patchStructure, color = patchColor)
          d.endStep()
  of tRedEye:
    let bw = abs(drag.x1 - drag.x0)
    let bh = abs(drag.y1 - drag.y0)
    let (cx, cy, rad) = if max(bw, bh) < 4: (drag.x0, drag.y0, max(8, min(d.w, d.h) div 30))
                        else: ((drag.x0 + drag.x1) / 2, (drag.y0 + drag.y1) / 2, max(4, int(max(bw, bh) / 2)))
    d.beginStep("Red Eye")
    d.redEye(int(cx), int(cy), rad, redEyeDarken)
    d.endStep()
  of tPen:
    if penMode == 6:
      # (the Freeform Pen's line: fitted with curves, a path of its own -- closed
      # when it ends where it began)
      if drag.pts.len >= 2:
        if d.curPath < 0 or d.curPath >= d.paths.len:
          d.paths.add Path(name: "Work Path")
          d.curPath = d.paths.high
        let (sx0, sy0) = dw.view.toScreen(d, drag.pts[0][0], drag.pts[0][1])
        let (sx1, sy1) = dw.view.toScreen(d, drag.pts[^1][0], drag.pts[^1][1])
        let closed = drag.pts.len > 4 and abs(sx0 - sx1) <= dp(6) and abs(sy0 - sy1) <= dp(6)
        let sub = fitPath(drag.pts, freeCurveFit.float, closed)
        if sub.pts.len >= 2:
          d.paths[d.curPath].subs.add sub
          inc d.ver
        else: penChanged = false
      else: penChanged = false
    penDrag.on = false
    spEdit.on = false
    if penChanged: d.endStep() else: d.cancelStep()
  else: discard
  drag = Drag()

# ---- drawing over the canvas ------------------------------------------------------------------------

var selOverlay: tuple[d: Doc; ver, step: int; b: Bitmap]
  ## (the Selection Brush's overlay: what is not selected, in red -- at most
  ## 1600 pixels across, made again when the selection changes)

proc drawSelOverlay(dw: DocWin) =
  let d = dw.doc
  if not d.hasSelection: return
  let step = max(1, (max(d.w, d.h) + 1599) div 1600)
  if selOverlay.d != d or selOverlay.ver != d.selVer or selOverlay.step != step or selOverlay.b == nil:
    let w = (d.w + step - 1) div step
    let h = (d.h + step - 1) div step
    let b = newBitmap(w, h)
    for y in 0 ..< h:
      let row = min(d.h - 1, y * step) * d.w
      for x in 0 ..< w:
        let a = 255 - int(d.sel[row + min(d.w - 1, x * step)])
        b.px[y * w + x] = (uint32(a * 128 div 255) shl 24) or 0x00FF0000'u32
    b.changed()
    selOverlay = (d, d.selVer, step, b)
  let (ax, ay) = dw.view.toScreen(d, 0, 0)
  let (bx, by) = dw.view.toScreen(d, d.w.float, d.h.float)
  drawBitmap(rect(ax, ay, bx - ax, by - ay), selOverlay.b)

proc overlays(dw: DocWin; ev: PhotoEvent) =
  ## The rubber bands, the crop box, the path, the brush's size.
  let d = dw.doc
  let v = dw.view
  pushClip(v.view)
  polyLassoOverlay(dw, ev)
  if tool == tWand and wandMode == 3 and selBrushOverlay: dw.drawSelOverlay()
  if tool == tPen and penMode == 8: dw.traceOverlay(ev)
  # the slices (numbered, the one picked brighter), a new one's box
  block:
    var n = 0
    let st = style(size = 0.85)
    for k, sl in slices:
      if sl.d != d: continue
      inc n
      let (a, b) = v.toScreen(d, sl.r.x.float, sl.r.y.float)
      let (c, e) = v.toScreen(d, (sl.r.x + sl.r.w).float, (sl.r.y + sl.r.h).float)
      let col = if k == sliceSel and tool == tCrop and cropKind in {3, 4}: color(255, 160, 0) else: color(0, 120, 255)
      box(rect(a, b, max(1, c - a), max(1, e - b)), col)
      let tag = $n
      let tw = textWidth(tag, st) + dp(6)
      fill(rect(a + 1, b + 1, tw, lineHeight(st) + 2), col)
      text(a + 1 + dp(3), b + 2, tag, color(255, 255, 255), st)
    if drag.on and drag.dw == dw and tool == tCrop and cropKind == 3:
      let (x0, y0) = v.toScreen(d, min(drag.x0, drag.x1), min(drag.y0, drag.y1))
      let (x1, y1) = v.toScreen(d, max(drag.x0, drag.x1), max(drag.y0, drag.y1))
      box(rect(x0, y0, max(1, x1 - x0), max(1, y1 - y0)), color(0, 120, 255))
  # the notes (a folded yellow page each) and the counts (a number by a dot)
  block:
    let ns = dp(12)
    for nt in notes:
      if nt.d != d: continue
      let (a, b) = v.toScreen(d, nt.x, nt.y)
      let r = rect(a - ns div 2, b - ns div 2, ns, ns)
      fill(r, color(255, 236, 120))
      box(r, color(0, 0, 0))
      fill(rect(r.x + r.w - dp(4), r.y, dp(4), dp(4)), color(200, 170, 40))
      for k in 1 .. 2: hline(r.x + dp(2), r.y + k * dp(4), r.w - dp(5), color(120, 100, 40))
      if ev.over and mouseIn(r) and nt.text.len > 0: ui.tip = nt.text
    var n = 0
    let st = style(bold = true, size = 0.85)
    for c in counts:
      if c.d != d: continue
      inc n
      let (a, b) = v.toScreen(d, c.x, c.y)
      fill(rect(a - dp(2), b - dp(2), dp(4), dp(4)), color(0, 160, 255))
      text(a + dp(4) + 1, b - dp(4) + 1, $n, color(0, 0, 0), st)
      text(a + dp(4), b - dp(4), $n, color(0, 200, 255), st)
  # the Frame tool's box being drawn
  if drag.on and drag.dw == dw and tool == tCrop and cropKind == 2:
    let (x0, y0) = v.toScreen(d, min(drag.x0, drag.x1), min(drag.y0, drag.y1))
    let (x1, y1) = v.toScreen(d, max(drag.x0, drag.x1), max(drag.y0, drag.y1))
    if frameEllipse: ellipseOnScreen(x0, y0, x1, y1, ui.theme.select)
    else:
      let sr = rect(x0, y0, max(1, x1 - x0), max(1, y1 - y0))
      box(sr, ui.theme.select)
  # the artboards: each one's name over its top left, its edge; the one
  # dragged with the Artboard tool, where it goes; a new one's box
  let boards = d.artboards
  if boards.len > 0 or (tool == tMove and moveKind == 1):
    let st = style(size = 0.9)
    for i in boards:
      let L = d.layers[i]
      let b = L.board
      var (dx, dy) = (0.0, 0.0)
      if drag.on and drag.dw == dw and tool == tMove and moveKind == 1 and drag.board == i:
        (dx, dy) = (drag.x1 - drag.x0, drag.y1 - drag.y0)
      let (x0, y0) = v.toScreen(d, b.x.float + dx, b.y.float + dy)
      let (x1, y1) = v.toScreen(d, (b.x + b.w).float + dx, (b.y + b.h).float + dy)
      let sr = rect(int(x0), int(y0), max(1, int(x1 - x0)), max(1, int(y1 - y0)))
      box(sr, if i == d.cur: ui.theme.select else: ui.theme.shadow)
      text(sr.x, sr.y - lineHeight(st) - dp(2), L.name, if i == d.cur: ui.theme.select else: ui.theme.text, st)
    if drag.on and drag.dw == dw and tool == tMove and moveKind == 1 and drag.board < 0:
      let (x0, y0) = v.toScreen(d, min(drag.x0, drag.x1), min(drag.y0, drag.y1))
      let (x1, y1) = v.toScreen(d, max(drag.x0, drag.x1), max(drag.y0, drag.y1))
      let sr = rect(int(x0), int(y0), max(1, int(x1 - x0)), max(1, int(y1 - y0)))
      box(sr, ui.theme.select)
      box(inset(sr, 1), ui.theme.window)
  # the Color Sampler's points, numbered; the Ruler's line
  var n = 0
  for sp in samplers:
    if sp.d != d: continue
    inc n
    let (sx, sy) = v.toScreen(d, sp.x.float + 0.5, sp.y.float + 0.5)
    let r = dp(5)
    for (c, o) in [(color(255, 255, 255), 1), (color(0, 0, 0), 0)]:
      hline(sx - r + o, sy + o, 2 * r + 1, c)
      vline(sx + o, sy - r + o, 2 * r + 1, c)
    text(sx + dp(4), sy + dp(2), $n, color(0, 0, 0), style(bold = true, size = 0.85))
  if ruler.on and ruler.d == d:
    let (ax, ay) = v.toScreen(d, ruler.x0, ruler.y0)
    let (bx, by) = v.toScreen(d, ruler.x1, ruler.y1)
    line(ax + 1, ay + 1, bx + 1, by + 1, color(255, 255, 255))
    line(ax, ay, bx, by, color(0, 0, 0))
    for (px, py) in [(ax, ay), (bx, by)]:
      hline(px - dp(4), py, dp(9), color(0, 0, 0))
      vline(px, py - dp(4), dp(9), color(0, 0, 0))
  if tool == tWand and wandMode == 2 and objectFinder and ev.over and not drag.on and info.inside:
    # Object Finder: the thing under the mouse shown in blue
    let segs = d.findSegments()
    let k = segs.regionAt(ev.x, ev.y)
    if k >= 0:
      if finderShown.k != k or finderShown.d != d or finderShown.ver != finderSeg.ver or finderShown.b == nil:
        let b = newBitmap(segs.w, segs.h)
        for i in 0 ..< segs.id.len:
          if segs.id[i] == k: b.px[i] = 0x701473E6'u32
        b.changed()
        finderShown = (d, finderSeg.ver, k, b)
      let (ax, ay) = v.toScreen(d, 0, 0)
      let (bx, by) = v.toScreen(d, d.w.float, d.h.float)
      drawBitmap(rect(ax, ay, bx - ax, by - ay), finderShown.b)
  if drag.on and drag.dw == dw and ui.mouseDown and (drag.moving or textMove.on or shapeMove.on):
    dw.smartDraw()
  if tool == tMove and not (drag.on and drag.dw == dw and drag.moving) and not xf.on:
    # the usual Move tool: the layer under the mouse outlined (Auto-Select),
    # the current one's box and handles (Show Transform Controls)
    if moveAutoSelect and ev.over and not ui.mouseDown:
      let (ix, iy) = (int(floor(ev.x)), int(floor(ev.y)))
      if (ix, iy) != (hoverBox.x, hoverBox.y):
        let i = d.autoPicked(d.layerAt(ix, iy, dw.pickRadius))
        hoverBox = (ix, iy, if i >= 0 and i != d.cur: d.blockBox(i) else: rect(0, 0, 0, 0))
      if hoverBox.r.w > 0: dw.drawBox(quadOf(hoverBox.r), handles = false)
    if d.current.isLine and not d.hasSelection and not d.editMask and not d.quickMask:
      # a line: a handle at each end (dragged: the line follows)
      let sp = d.current.shape.path.subs[0]
      let hot = if ev.over and not ui.mouseDown: dw.lineEndAt(d.current, ui.mx, ui.my) else: -1
      for i in [0, sp.pts.high]:
        let (sx, sy) = v.toScreen(d, sp.pts[i].p[0], sp.pts[i].p[1])
        let hs = dp(4)
        let r = rect(sx - hs, sy - hs, 2 * hs + 1, 2 * hs + 1)
        fill(r, if hot == i or (lineGrab.on and lineGrab.i == i): color(0, 120, 215) else: color(255, 255, 255))
        box(r, color(0, 120, 215))
      if hot >= 0: ui.cursor = curCrosshair
    elif moveShowControls and not d.current.background and not d.editMask and not d.quickMask:
      let r = if d.hasSelection: d.clip(d.selBounds) else: d.layerBox(d.current)
      if r.w > 0 and r.h > 0:
        let h = if ev.over and not ui.mouseDown: dw.boxHit(quadOf(r), ui.mx, ui.my) else: -1
        dw.drawBox(quadOf(r), hot = h)
        if h >= 0: dw.boxCursor(quadOf(r), h)
  if drag.on and drag.dw == dw and not drag.moving and not drag.selMove:
    case drag.tool
    of tZoom:
      let (a, b) = v.toScreen(d, drag.x0, drag.y0)
      let (c, e) = v.toScreen(d, drag.x1, drag.y1)
      if abs(c - a) >= dp(8) and abs(e - b) >= dp(8):
        dashedRect(rect(min(a, c), min(b, e), abs(c - a), abs(e - b)), ui.now div 100)
    of tMarquee:
      if marqueeShape < 2:
        let (x0, y0, x1, y1) = marqueeBox()
        let (a, b) = v.toScreen(d, x0, y0)
        let (c, e) = v.toScreen(d, x1, y1)
        if marqueeShape == 0: dashedRect(rect(a, b, max(1, c - a), max(1, e - b)), ui.now div 100)
        else:
          ellipseOnScreen(a + 1, b + 1, c + 1, e + 1, color(255, 255, 255))
          ellipseOnScreen(a, b, c, e, color(0, 0, 0))
    of tLasso:
      for i in 1 ..< drag.pts.len:
        let (a, b) = v.toScreen(d, drag.pts[i - 1][0], drag.pts[i - 1][1])
        let (c, e) = v.toScreen(d, drag.pts[i][0], drag.pts[i][1])
        dashedLine(a, b, c, e)
    of tWand:
      if wandMode == 1:
        # (the brush's path: its outline at each place it went)
        let rs = max(2, int(quickSize / 2 * v.scaleOf / pxScale.float))
        var last = (-99999, -99999)
        for (px, py) in drag.pts:
          let (a, b) = v.toScreen(d, px, py)
          if abs(a - last[0]) + abs(b - last[1]) < max(3, rs div 2): continue
          last = (a, b)
          ellipseOnScreen(a - rs, b - rs, a + rs, b + rs, color(0, 0, 0))
      elif wandMode == 2:
        let (a, b) = v.toScreen(d, drag.x0, drag.y0)
        let (c, e) = v.toScreen(d, drag.x1, drag.y1)
        dashedRect(rect(min(a, c), min(b, e), max(1, abs(c - a)), max(1, abs(e - b))), ui.now div 100)
        wakeIn(120)
    of tShape:
      var p = shapePath(ev)
      if shapeKind == 4 and p.subs.len > 0:
        # (the line's arrowheads too)
        let (x1, y1) = lineDragEnd(ev)
        p.subs.add endsPath(lineShape(drag.x0, drag.y0, x1, y1)).subs
      for poly in p.flatten(12):
        for i in 0 ..< poly.len:
          let q0 = poly[i]
          let q1 = poly[(i + 1) mod poly.len]
          if i == poly.high and shapeKind == 4 and false: continue
          let (a, b) = v.toScreen(d, q0[0], q0[1])
          let (c, e) = v.toScreen(d, q1[0], q1[1])
          dashedLine(a, b, c, e)
    of tPen:
      if penMode == 6:
        for i in 1 ..< drag.pts.len:
          let (a, b) = v.toScreen(d, drag.pts[i - 1][0], drag.pts[i - 1][1])
          let (c, e) = v.toScreen(d, drag.pts[i][0], drag.pts[i][1])
          line(a, b, c, e, color(0, 0, 0))
    of tCrop, tGradient, tRedEye:
      let (a, b) = v.toScreen(d, drag.x0, drag.y0)
      let (c, e) = v.toScreen(d, drag.x1, drag.y1)
      if drag.tool in {tCrop, tRedEye} and not (drag.tool == tCrop and cropStraighten):
        dashedRect(rect(min(a, c), min(b, e), max(1, abs(c - a)), max(1, abs(e - b))))
      else: dashedLine(a, b, c, e)
    of tHeal:
      if healMode in {2, 4} and d.hasSelection:
        # the patch: where its texture will come from
        let sb = d.selBounds
        let dx = drag.x1 - drag.x0
        let dy = drag.y1 - drag.y0
        let (a, b) = v.toScreen(d, sb.x.float + dx, sb.y.float + dy)
        let (c, e) = v.toScreen(d, (sb.x + sb.w).float + dx, (sb.y + sb.h).float + dy)
        dashedRect(rect(a, b, max(1, c - a), max(1, e - b)), ui.now div 100)
        wakeIn(120)
    else: discard
  if pendingCrop.on and pendingCrop.dw == dw:
    # the crop box: the grid of thirds in it (the Perspective Crop's in its
    # perspective), its handles; what is cut away shaded
    let q = if pendingCrop.persp: pendingCrop.q else: quadOf(pendingCrop.r)
    var sc: array[4, (int, int)]
    for k in 0 .. 3: sc[k] = v.toScreen(d, q[k][0], q[k][1])
    if not pendingCrop.persp:
      let (a, b) = sc[0]
      let (c, e) = sc[2]
      let ir = v.view
      for band in [rect(ir.x, ir.y, ir.w, b - ir.y), rect(ir.x, e, ir.w, ir.y + ir.h - e),
                   rect(ir.x, b, a - ir.x, e - b), rect(c, b, ir.x + ir.w - c, e - b)]:
        if band.w > 0 and band.h > 0: fill(band, color(0, 0, 0, 110))
    let m = squareToQuad(q)
    proc at(u, w: float): (int, int) =
      let z = m[6] * u + m[7] * w + m[8]
      let k = if abs(z) < 1e-12: 1e12 else: 1 / z
      v.toScreen(d, (m[0] * u + m[1] * w + m[2]) * k, (m[3] * u + m[4] * w + m[5]) * k)
    let gridN = if pendingCrop.persp: 6 else: 3
    for g in 1 ..< gridN:
      let t = g / gridN
      let (a1, b1) = at(t, 0)
      let (a2, b2) = at(t, 1)
      line(a1, b1, a2, b2, color(160, 160, 160))
      let (c1, e1) = at(0, t)
      let (c2, e2) = at(1, t)
      line(c1, e1, c2, e2, color(160, 160, 160))
    for k in 0 .. 3:
      let (a1, b1) = sc[k]
      let (a2, b2) = sc[(k + 1) mod 4]
      dashedLine(a1, b1, a2, b2)
    var handles = @sc
    if not pendingCrop.persp:
      for k in 0 .. 3:
        let (a1, b1) = sc[k]
        let (a2, b2) = sc[(k + 1) mod 4]
        handles.add ((a1 + a2) div 2, (b1 + b2) div 2)
    let hs = dp(3)
    for (hx, hy) in handles:
      fill(rect(hx - hs, hy - hs, 2 * hs + 1, 2 * hs + 1), color(255, 255, 255))
      box(rect(hx - hs, hy - hs, 2 * hs + 1, 2 * hs + 1), color(0, 0, 0))
    wakeIn(120)
  # the work path (the Path tools: or the shape layer's outline)
  let shownPath = if d.curPath >= 0 and d.curPath < d.paths.len: d.paths[d.curPath]
                  elif tool == tPen and penMode in {0, 5} and d.current.isShape and not d.current.isFill:
                    d.current.shape.path
                  else: Path()
  if shownPath.subs.len > 0:
    for poly in shownPath.flatten(12):
      for i in 1 ..< poly.len:
        let (a, b) = v.toScreen(d, poly[i - 1][0], poly[i - 1][1])
        let (c, e) = v.toScreen(d, poly[i][0], poly[i][1])
        line(a, b, c, e, color(0, 0, 0))
    if tool == tPen:
      for si, sp in shownPath.subs:
        for q in sp.pts:
          if penMode == 5:
            # (Path Selection: the points of the picked subpath filled black)
            let (a, b) = v.toScreen(d, q.p[0], q.p[1])
            fill(rect(a - 2, b - 2, 5, 5), if si == pathSel: color(0, 0, 0) else: color(255, 255, 255))
            box(rect(a - 2, b - 2, 5, 5), color(0, 0, 0))
            continue
          let (a, b) = v.toScreen(d, q.p[0], q.p[1])
          fill(rect(a - 2, b - 2, 5, 5), color(255, 255, 255))
          box(rect(a - 2, b - 2, 5, 5), color(0, 0, 0))
          if q.outH != q.p:
            let (c, e) = v.toScreen(d, q.outH[0], q.outH[1])
            let (f, g) = v.toScreen(d, q.inH[0], q.inH[1])
            line(f, g, c, e, color(0, 0, 160))
            fill(rect(c - 1, e - 1, 3, 3), color(0, 0, 160))
            fill(rect(f - 1, g - 1, 3, 3), color(0, 0, 160))
  typeOverlay(dw)
  # the symmetry's axes
  if symmetry > 0 and tool in {tBrush, tPencil, tAirbrush, tEraser, tBlur, tDodge}:
    let cx = d.w / 2
    let cy = d.h / 2
    let rr = hypot(d.w.float, d.h.float)
    var angles: seq[float]
    case symmetry
    of 1: angles = @[PI / 2]
    of 2: angles = @[0.0]
    of 3: angles = @[0.0, PI / 2]
    else:
      for k in 0 ..< clamp(symAxes, 2, 16): angles.add k.float * PI / clamp(symAxes, 2, 16).float + PI / 2
    for a in angles:
      let (x0, y0) = v.toScreen(d, cx - cos(a) * rr, cy - sin(a) * rr)
      let (x1, y1) = v.toScreen(d, cx + cos(a) * rr, cy + sin(a) * rr)
      dashedLine(x0, y0, x1, y1)
  # the brush's size under the mouse (on the image only)
  if ev.over and d.inImage(ev) and (tool in paintTools or (tool == tHeal and healMode in {0, 1, 3}) or
                  (tool == tWand and wandMode in {1, 3})) and not drag.moving:
    # (Preferences › Cursors: the brush tip -- normal: where it paints at
    # least half; full size: all of it -- and a cross in it)
    if prefs.paintCursor >= 2:
      let t = tipFor(tool)
      var r = if tool == tWand: quickSize / 2 else: t.diameter.float / 2
      if prefs.paintCursor == 2 and tool != tWand and t.custom.len == 0:
        r *= 0.5 + clamp(t.hardness, 0, 100).float / 200
      let (a, b) = v.toScreen(d, ev.x - r, ev.y - r)
      let (c, e) = v.toScreen(d, ev.x + r, ev.y + r)
      if c - a >= 5:
        ellipseOnScreen(a + 1, b + 1, c + 1, e + 1, color(255, 255, 255))
        ellipseOnScreen(a, b, c, e, color(0, 0, 0))
      if prefs.crosshair or c - a < 5 or (tool == tEraser and eraseKind == 2) or (tool == tBrush and brushTool == 2):
        # (the Background Eraser: always its cross -- the color under it is the one rubbed out)
        let (cx, cy) = v.toScreen(d, ev.x, ev.y)
        let k = dp(4)
        hline(cx - k, cy + 1, 2 * k + 1, color(255, 255, 255))
        vline(cx + 1, cy - k, 2 * k + 1, color(255, 255, 255))
        hline(cx - k, cy, 2 * k + 1, color(0, 0, 0))
        vline(cx, cy - k, 2 * k + 1, color(0, 0, 0))
  popClip()

proc cursorFor(ev: PhotoEvent) =
  ## The pointer over the image (Preferences › Cursors: standard or precise).
  if not ev.over: return
  let paints = tool in paintTools or tool == tHeal
  ui.cursor = case tool
              of tHand: curHand
              of tType: curIbeam
              of tMove: (if ui.cursor in boxCursors: ui.cursor else: curArrow)   # (the box's, `boxCursor`)
              else:
                if paints: (if prefs.paintCursor == 0: curArrow else: curCrosshair)
                elif prefs.otherCursor == 0: curArrow
                else: curCrosshair

proc snapped(dw: DocWin; ev: PhotoEvent): PhotoEvent =
  ## The mouse snapped to the guides, the grid, the image's edges (View >
  ## Snap) for the tools that draw boxes and lines.
  result = ev
  if not snapOn or tool notin {tMarquee, tCrop, tShape, tGradient, tType, tPen} or
     (tool == tMarquee and marqueeShape >= 2): return
  let d = dw.doc
  let tol = dp(6).float * pxScale.float / dw.view.scaleOf
  let grid = if snapGrid and dw.view.showGrid: dw.view.gridCell(dw.doc) else: 0.0
  let g = snapGuides and dw.view.showGuides
  result.x = d.snapCoord(ev.x, true, tol, grid, g, snapBounds)
  result.y = d.snapCoord(ev.y, false, tol, grid, g, snapBounds)

# (the panels of photo/pspanels and the commands of photo/pscc, used before them)
proc adjustmentsBody()
proc histogramBody()
proc gradientsBody()
proc patternsBody()
proc glyphsBody()
proc psMenus()
proc psCommand(name: string): bool
proc runCommand(name: string)
proc dailyCommand(name: string): bool
proc assetsCommand(name: string): bool
proc assetsDialog()
proc dailyDialogs()
proc beforeAfter(dw: DocWin; ev: PhotoEvent): bool
proc searchDialog()
proc taskBarPress(dw: DocWin)
proc straightenByRuler()
proc taskBarDraw(dw: DocWin)

proc docStatus(dw: DocWin)

proc docBody(dw: DocWin) =
  let d = dw.doc
  dw.view.allowGuideGrab = tool == tMove and not drag.on
  dw.taskBarPress()                # (its buttons before the image takes the mouse)
  # (the status under the image, left of its scroll bar: as today's editors)
  let stW = clamp(available() * 55 div 100, dp(170), dp(560))
  var ev = photoView(d, dw.view, key = $cast[uint](dw), statusW = stW)
  beginKeepSides(dw.view.keepRect)     # (what is drawn over the image: as it is, right to left too)
  defer: endKeepSides()
  dw.docStatus()
  if dw.beforeAfter(ev):
    dw.win.title = dw.title()
    return
  if ev.guideMoved: inc d.ver
  ev = dw.snapped(ev)
  if ev.over:
    info.x = ev.x
    info.y = ev.y
    info.inside = ev.x >= 0 and ev.y >= 0 and ev.x < d.w.float and ev.y < d.h.float
    if info.inside: info.c = d.pixelAt(int(ev.x), int(ev.y))
  if xf.on and xf.dw == dw:
    dw.transformMouse(ev)
    dw.transformOverlay()
    # (the pointer the box asked for -- a handle's arrows, four arrows inside,
    # the cross where it turns -- else an arrow)
    if ev.over and ui.cursor notin boxCursors: ui.cursor = curArrow
    dw.win.title = dw.title()
    dw.taskBarDraw()
    return
  if dw.modeOn:
    dw.modeMouse(ev)
    dw.modeOverlay()
    if ev.over: ui.cursor = curArrow
    dw.win.title = dw.title()
    return
  if dw.hudPickerOn(ev):
    # (Alt+Shift + the right button -- a long press on a touch screen: the
    # color picker on the canvas)
    dw.win.title = dw.title()
    return
  if dw.brushDragOn(ev):
    # (Alt + the right button: the brush's size and hardness)
    dw.win.title = dw.title()
    return
  # the Move tool's right click: the layers under the pointer, to pick one (as the usual)
  if tool == tMove and ev.right and ev.over and not drag.on and AltPressed notin ui.mods:
    let xi = int(floor(ev.x))
    let yi = int(floor(ev.y))
    underMenu = (dw, d.layersUnder(xi, yi, dw.pickRadius))
    openPopupMenu("canvas:layers", ui.mx, ui.my)
  if underMenu.dw == dw:
    popupMenu("canvas:layers"):
      if underMenu.idx.len == 0: discard menuItem("(no layer here)", enabled = false)
      for i in underMenu.idx:
        if i >= d.layers.len: continue
        let L = d.layers[i]
        # (its name as it is: an "&" in it not a mnemonic)
        if menuItem(L.name.replace("&", "&&"), checked = i == d.cur):
          d.clearPicks()
          d.cur = i
          d.editMask = false
          inc d.ver
          status = "Picked the layer " & L.name
      menuSeparator()
      # (several picked -- Shift+click on the image, Ctrl+click in Layers -- into a group of their own)
      if menuItem(if d.pickedLayers.len > 1: "&Group Layers" else: "&Group Layer", "Ctrl+G",
                  enabled = not d.current.background):
        runCommand("Group Layers")
      if menuItem("&Ungroup Layers", "Ctrl+Shift+G", enabled = d.current.group): runCommand("Ungroup Layers")
      menuSeparator()
      if menuItem("Free &Transform", "Ctrl+T", enabled = not d.current.background): runCommand("Free Transform")
      if menuItem("&Duplicate Layer"): runCommand("Duplicate Layer")
      if menuItem("De&lete Layer", enabled = d.layers.len > 1): runCommand("Delete Layer")
      if menuItem("&Blending Options...", enabled = not d.current.background): runCommand("Blending Options...")
  if ev.pressed:
    if xf.on: finishTransform(true)            # (a click in another image)
    beginBusy(toolName(tool))
    try: dw.pressOn(ev)
    finally: endBusy()
  elif drag.on and drag.dw == dw:
    if ev.down: dragOn(ev)
    if ev.released or not ui.mouseDown:
      beginBusy(toolName(drag.tool))
      try: releaseOn(ev)
      finally: endBusy()
  if drag.on and drag.dw == dw and drag.tool == tAirbrush and ui.mouseDown and not drag.moving:
    if ui.now - drag.lastTick >= 60:
      drag.stroke.strokeTick()
      drag.lastTick = ui.now
    wakeIn(60)
  if drag.on and drag.dw == dw:
    info.sized = true
    info.w = abs(drag.x1 - drag.x0)
    info.h = abs(drag.y1 - drag.y0)
    info.dist = sqrt(info.w * info.w + info.h * info.h)
    info.angle = radToDeg(arctan2(drag.y0 - drag.y1, drag.x1 - drag.x0))
  else: info.sized = false
  if te.on and te.dw == dw and (ui.focus == te.focusId or ui.focus == 0):
    ui.takesText = true             # (the keyboard on a tablet)
    ui.takesEnter = true
  dw.overlays(ev)
  cursorFor(ev)
  # (off the image: an arrow -- the tools wait -- but for the Hand, the Zoom,
  # what is being dragged, a box's handles)
  if ev.over and not d.inImage(ev) and tool notin {tHand, tZoom} and not drag.on and
     ui.cursor notin boxCursors and not springing:
    ui.cursor = curArrow
  if ev.over and tool in {tMarquee, tLasso, tWand} and dw.doc.hasSelection and
     not (ev.shift or ev.alt) and touchSelMode == 0:
    # (inside the selection: an arrow -- a drag moves the outline)
    let xi = int(floor(ev.x))
    let yi = int(floor(ev.y))
    if (drag.on and drag.selMove) or (xi >= 0 and yi >= 0 and xi < dw.doc.w and yi < dw.doc.h and
                                       dw.doc.sel[yi * dw.doc.w + xi] >= 128):
      ui.cursor = curArrow
  dw.taskBarDraw()
  # (the title follows the document)
  dw.win.title = dw.title()

# ---- the toolbox -------------------------------------------------------------------------------------

var
  reselect: tuple[d: Doc; sel: seq[uint8]]   ## the selection Select > None took away (Reselect)
  spaceHeld = false              ## Space is down (the Hand while it is)

proc springTool() =
  ## the usual keys held for a moment: Space the Hand (with Ctrl, the
  ## Zoom; with Alt, zooming out), Ctrl the Move tool, Alt the Eyedropper
  ## with the painting tools; let go, the tool chosen before. Not in the
  ## middle of a drag, a transform or typing.
  if ui.keyUp == KeySpace or not canInput(): spaceHeld = false
  if drag.on or te.on or xf.on or ui.rmouseDown: return
  let base = if springing: springBase else: tool
  let ctrl = CtrlPressed in ui.mods
  let alt = AltPressed in ui.mods
  var want = base
  if spaceHeld:
    want = if ctrl or alt: tZoom else: tHand
  elif ctrl and not alt and prefs.keySet == 0 and
       base notin {tHand, tZoom, tMove, tType, tPen, tCrop, tEyedropper, tStamp, tHeal}:
    want = tMove
  elif alt and not ctrl and base in {tBrush, tPencil, tAirbrush, tBucket, tGradient}:
    want = tEyedropper
  if want != base:
    if not springing:
      springBase = tool
      springing = true
    tool = want
  elif springing:
    tool = springBase
    springing = false

proc spaceKeyHeld() =
  ## (at the end of a frame) Space that nothing else took: the Hand.
  if ui.key == KeySpace and not ui.keyUsed and canInput() and not ui.takesText and not te.on:
    spaceHeld = true
    ui.keyUsed = true

proc selectTool(t: Tool) =
  springing = false
  if tool != t:
    pendingCrop.on = false
    finishPolyLasso(false)
    if te.on: commitType()
  tool = t
  brushTab = brushTab   # (the Options tab follows)
  status = ""

var showFgPicker, showBgPicker = false
proc startQuickMaskOptions()
var fgPicker, bgPicker: ColorPickerState

include photo/toolbar
include photo/brushpanel
include photo/palettes
include photo/typepalettes
include photo/textstyles
include photo/svgexport
include photo/gradients
include photo/actions
include photo/dialogs
include photo/newdoc
include photo/recovery
include photo/presetfiles
include photo/prefs
include photo/pro
include photo/combine
include photo/smartobj
include photo/menus
include photo/scripting
include photo/vanishing
include photo/daily
include photo/pscc
include photo/pspanels
include photo/assets
include photo/neural
include photo/pdfexport
include photo/fontget
include photo/optionsbar
include photo/dockpanels
include photo/ccfeatures

# ---- the window -----------------------------------------------------------------------------------

proc placePalettes() =
  ## The toolbar at the top left (the panels are in the dock).
  let a = mdiAreaRect("ws")
  let (tw, th2) = toolboxSize()
  toolbox.r = rect(0, 0, tw, th2)
  palettesPlaced = true
  placedFor = (a.w, a.h)

type StatusInfo = enum
  ## What the status bar shows beside the zoom (the usual list).
  siSizes = "Document Sizes", siProfile = "Document Profile", siDims = "Document Dimensions",
  siScale = "Measurement Scale", siScratch = "Scratch Sizes", siEfficiency = "Efficiency",
  siTiming = "Timing", siTool = "Current Tool", siSave = "Save Progress",
  siSmart = "Smart Objects", siLayers = "Layer Count"

var
  statusInfo = siSizes
  zoomField = ""

proc zoomFromPercent(p: float): int =
  ## The zoom nearest a typed percentage (the ratios the views draw at).
  if p >= 100: return clamp(int(round(p / 100)), 1, 16)
  var best = 1
  var bestErr = Inf
  for z in zoomSteps:
    if z >= 1: continue
    let e = abs(ln(100 / (-z).float) - ln(max(0.1, p)))
    if e < bestErr:
      bestErr = e
      best = z
  if abs(ln(100.0) - ln(max(0.1, p))) < bestErr: 1 else: best

proc statusInfoText(d: Doc): string =
  let mb = proc (b: int64): string = formatFloat(b.float / (1024 * 1024), ffDecimal, 1) & "M"
  case statusInfo
  of siSizes:
    let (flat, layered) = d.docSizes()
    "Doc: " & sizeText(flat) & "/" & sizeText(layered)
  of siProfile:
    (if d.mode == cmGray: (if d.icc.len > 0: d.profileName else: "Untagged Gray")
     elif d.icc.len > 0: d.profileName else: "Untagged RGB") & (if d.depth == 16: " (16bpc)" else: " (8bpc)")
  of siDims:
    inUnits(d.w.float, viewPrefs.rulerUnit, d.dpi, d.w) & " x " & inUnits(d.h.float, viewPrefs.rulerUnit, d.dpi, d.h) &
      " (" & $int(round(d.dpi)) & " ppi)"
  of siScale: "1 pixel = 1.0000 pixels"
  of siScratch:
    let budget = physicalMemory() * int64(clamp(prefs.memory, 20, 90)) div 100
    "Scratch: " & mb(int64(memoryUsed())) & "/" & mb(budget)
  of siEfficiency: "Efficiency: " & $int(round(d.historyInMemory * 100)) & "%"
  of siTiming:
    if lastBusy.label.len > 0: lastBusy.label & ": " & formatFloat(lastBusy.ms / 1000, ffDecimal, 2) & " s"
    else: "Timing: -"
  of siTool: $tool
  of siSave: (if saving(): "Saving " & savingPath().extractFilename & "..." else: "Save: idle")
  of siSmart:
    var n = 0
    for L in d.layers:
      if L.smart != nil: inc n
    "Smart Objects: " & $n
  of siLayers:
    var n = 0
    for L in d.layers:
      if not L.group: inc n
    "Layers: " & $n

var zoomFieldOf: pointer        ## (the window whose zoom box is being typed in)

proc docStatus(dw: DocWin) =
  ## A document's status, under it at the left of its scroll bar (as
  ## today's editors): its zoom (type one, Enter), what the arrow chose to
  ## show (Document Sizes...), and -- the window in front -- the tool's hint
  ## or the last message.
  let r = dw.view.statusRect
  if r.w <= 0: return
  let d = dw.doc
  pushClip(r)
  pushFrame(rect(r.x + dp(2), r.y + 1, r.w - dp(2), r.h - 1))
  row:
    let zid = idOf(zoomField, "edit")
    if dw == active:
      if ui.focus != zid or zoomFieldOf != cast[pointer](dw): zoomField = zoomPercent(dw.view.zoom)
      zoomFieldOf = cast[pointer](dw)
      edit(zoomField, w = dp(56))
      if ui.focus == zid and keyHit(KeyEnter):
        try:
          let p = parseFloat(zoomField.strip(chars = {'%', ' '}))
          if p > 0: dw.view.setZoom(d, zoomFromPercent(p))
        except ValueError: discard
        ui.focus = 0
      tooltip("The zoom: type a percentage and press Enter")
    else:
      let zr = place(dp(56), EditH)
      text(zr.x + dp(4), zr.y + (zr.h - FontH) div 2, zoomPercent(dw.view.zoom), ui.theme.text)
    statusSep()
    let info = statusInfoText(d)
    let iw = min(max(dp(90), textWidth(info) + dp(8)), max(dp(60), available() - dp(20)))
    let ir = place(iw, EditH)
    text(ir.x + dp(2), ir.y + (ir.h - FontH) div 2, ellipsize(info, ir.w - dp(4)), ui.theme.text)
    let ar = place(dp(14), EditH)
    let ah = interact(idOf("statusinfo" & $cast[uint](dw)), ar, focusable = false)
    arrow(ar.x + ar.w div 2, ar.y + ar.h div 2, dRight, if ah.showsHover: ui.theme.select else: ui.theme.text, dp(4))
    if ah.clicked: openPopupMenu("statusinfo", ar.x, ar.y)
    tooltip("What the status shows")
    if dw == active and available() > dp(40):
      statusSep()
      let hint = if status.len > 0: status
                 elif tool == tHand and handKind == 1:
                   "Drag round the middle to turn the view (Shift: by 15 degrees); double-click: straight again"
                 elif tool == tWand and wandMode == 3:
                   "Paint what to select; Alt takes away; [ ] the size, Shift+[ ] the hardness"
                 elif tool == tBrush and brushTool == 3:
                   "Paint the adjustment where it is wanted (a layer of its own, its mask what is painted); Alt takes it away"
                 elif tool == tPen and penMode == 8:
                   "Point at an edge: it lights up; click: a path along it; Shift+click: on along an edge to there"
                 elif tool == tMove and (d.current.isText or d.current.isShape) and
                      not d.layerBox(d.current).intersects(d.bounds):
                   "\"" & d.current.name & "\" is off the image: drag its box (round it, on the gray) back, " &
                   "or set its X and Y in Properties"
                 elif tool == tMove:
                   "Click to pick (Auto-Select), drag to move: Smart Guides line it up (Ctrl: free); double-click type " &
                   "to edit it; right-click: the layers there"
                 else: toolHints[tool]
      let hr = place(0, EditH, fill = true)
      text(hr.x + dp(4), hr.y + (hr.h - FontH) div 2, ellipsize(hint, hr.w - dp(6)),
           if status.len > 0: ui.theme.text else: ui.theme.gray)
      ui.lastRect = hr
      tooltip(hint)
  discard popFrame()
  popClip()
  popupMenu("statusinfo"):
    for si in StatusInfo:
      if menuItem($si, checked = si == statusInfo): statusInfo = si

proc frame() =
  springTool()
  typeWatch()
  captionBar()
  if screenMode != 2: menus()       # (Full Screen: no menu bar; F brings it back)
  optionsBar()
  # (the workspace: the gray of the time; in a dark theme, dark -- OLED: black)
  # (the workspace: the panels' gray, as everywhere; in a dark theme, dark -- OLED: black)
  if beginMdi(-1, "ws", (if themeIsDark(ui.theme): mixColor(ui.theme.window, ui.theme.light, 0.22)
                         else: ui.theme.face), edgeToEdge = true):
    # (again when the area changes: the window sized, a tablet turned, the
    # system bars shown or hidden)
    let a = mdiAreaRect("ws")
    if not palettesPlaced and not workspaceTried and a.w > 0:
      workspaceTried = true          # (the palettes where they were last time)
      if loadWorkspace():
        palettesPlaced = true
        placedFor = (a.w, a.h)
    if not palettesPlaced or (a.w > 0 and (a.w, a.h) != placedFor): placePalettes()
    docsRight = if palettesHidden: a.w else: a.w - dock.width
    keepDocMode()
    if showNext != nil and ui.frameNo >= showNextAt:
      if showNext in docs: showNext.showDoc()
      showNext = nil
    for dw in docs:
      if not dw.placed: dw.placeWindow()
    # the tabbed documents: all the room between the toolbar and the panels
    var tabbed: seq[DocWin]
    for dw in docs:
      if dw.win.open and not dw.floating: tabbed.add dw
    if tabbed.len > 0:
      if tabCur notin tabbed: tabCur = (if active in tabbed: active else: tabbed[^1])
      tabWin.r = tabArea()
      mdiWindow(tabWin):
        var titles: seq[string]
        for dw in tabbed: titles.add dw.title()
        var sel = tabbed.find(tabCur)
        let ev = tabStrip(titles, sel, addButton = false, look = tlPalette)
        tabStripAt = ui.lastRect
        space(-Gap)                    # (the picture right under its tab)
        if ev.selected and sel in 0 .. tabbed.high:
          tabCur = tabbed[sel]
          active = tabCur
          mdiActivate(tabWin, "ws")
        if ev.closed >= 0: tabbed[ev.closed].win.open = false
        if ev.moved.a >= 0:
          # (a tab dragged along the strip: the documents in that order)
          let ia = docs.find(tabbed[ev.moved.a])
          let ib = docs.find(tabbed[ev.moved.b])
          if ia >= 0 and ib >= 0: swap(docs[ia], docs[ib])
        if ev.menu >= 0:
          tabMenuDoc = tabbed[ev.menu]
          openPopupMenu("doctab", ui.mx, ui.my)
        popupMenu("doctab"):
          if menuItem("&Close"): tabMenuDoc.win.open = false
          if menuItem("Close &Others"):
            for o in tabbed:
              if o != tabMenuDoc: o.win.open = false
          if menuItem("Close &All"):
            for o in tabbed: o.win.open = false
          menuSeparator()
          if menuItem("&New Window for " & tabMenuDoc.doc.name.replace("&", "&&")):
            # (another view of the same image: another tab)
            let n = DocWin(doc: tabMenuDoc.doc, win: MdiWindow(title: tabMenuDoc.doc.name, open: true, flush: true,
                                                                  grip: true))
            docs.add n
            n.placeWindow()
            n.showDoc()
          if menuItem("&Windows of Their Own (MDI)"): setDocMode(false)
        if tabCur != nil and not tabCur.floating:
          tabCur.docBody()
      if mdiIsActive(tabWin, "ws") and tabCur != nil: active = tabCur
    else: tabStripAt = rect(0, 0, 0, 0)
    for dw in docs:
      if not dw.win.open or not dw.floating: continue
      mdiWindow(dw.win):
        dw.docBody()
    for dw in docs:
      if not dw.win.open:
        if dw.doc.modified and not closeAsk.on:
          closeAsk = (true, dw)
          dw.win.open = true
        elif not dw.doc.modified:
          closeDoc(dw)
          break
    if xf.on and xf.dw notin docs: xf.on = false      # (its image was closed)
    for dw in docs:
      if dw.floating and mdiIsActive(dw.win, "ws"): active = dw
    if not palettesHidden:
      # (the toolbar as big as what it holds: one column or two, the groups shown)
      let (tbw, tbh) = toolboxSize()
      toolbox.r.w = tbw
      toolbox.r.h = tbh
      mdiWindow(toolbox): toolboxBody()
      let dev = dockPanels(dock, "ws", panelBody, panelMenu)
      if dev.picked.len > 0: panelPicked(dev.picked)
    endMdi()
  dialogs()
  keys()
  spaceKeyHeld()

proc setup() =
  autoFocus = false              # (the keys go to the image, not to a palette's box)
  # the scratch disk: old undo steps of big images go there (left over ones
  # from before cleared away)
  try:
    scratchDir = dataDir("Retro Photo") / "scratch"
    createDir(scratchDir)
    # (walkDir: Android before 9 has no glob)
    for kind, f in walkDir(scratchDir):
      let n = f.extractFilename
      if kind == pcFile and n.startsWith("undo-") and n.endsWith(".raw"):
        try: removeFile(f) except CatchableError: discard
  except CatchableError: scratchDir = ""
  defaultScratch = scratchDir
  imaging.maxPicturePixels = maxPixels
  enableGpuComposite()                 # (layers mixed on the GPU when it is quicker there; the CPU else)
  openAnimations = false               # (no timeline here: an animated GIF, WebP opens as its first picture)
  # (the thumbnails of slow files kept on disk: the Open dialog, the Assets
  # window; and when the device runs short of memory, what is only kept to
  # be quick let go)
  useThumbCache(thumbCacheFolder(AppName), 64 * 1024 * 1024)
  onMemoryPressure(proc (level: MemoryPressure) =
    if level == mpCritical:
      for dw in docs: dw.doc.purgeCaches()
      trimMemory())
  loadPrefs()
  setThreadCount(prefs.threads)
  addDocumentPreviews()          # (.rpd and .psd pictures in the Open dialog's preview)
  # (thumbnails -- the Open dialog, recent files, the Assets window -- of the
  # kinds the system may not read: raw photos, SVG, JPEG XL, WebP, TIFF...;
  # after the documents' own readers, which come first)
  addMorePictures()
  addFontDir(dataDir(AppName) / "Fonts")   # (fonts got from Google Fonts)
  findRecovery()
  loadPresets()
  loadMyPresets()
  ensureBooksLoaded()
  initOpts()
  initSwatches()
  initFilters()
  initPlugins()
  scratch = newDoc(200, 64, white)

proc saveWatch() =
  ## A save in the background: over?
  if not saving(): return
  let r = saveFinished()
  if not r.done:
    wakeIn(100)
    return
  if recoverySaving.len > 0 and r.path == recoverySaving:
    # (a recovery copy: quietly)
    recoverySaving = ""
    if r.error.len > 0: status = "Could not keep a recovery copy: " & r.error
    return
  if r.error.len > 0:
    status = "Could not save " & r.path.extractFilename & ": " & r.error
    if bgSave.doc != nil and not bgSave.copy: bgSave.doc.modified = true
  else:
    status = "Saved " & r.path.extractFilename
    if bgSave.doc != nil and not bgSave.copy:
      for dw in docs:
        if dw.doc == bgSave.doc: dw.dropRecovery()
  bgSave = (nil, false)

proc faultReport() =
  ## The faults of the last run (it stopped, or something went wrong in
  ## it), told once at the next start, and Help > Report a Problem: the
  ## toolkit's box (copy the report, or send it by email).
  if ui.now >= splashUntil: problemBox("Retro Photo", AppVersion)

proc photoFrame() =
  ## One frame of the program (the tests run it too). Long work shows a box
  ## with an animation; Cancel (or Esc) stops it, and what it had changed
  ## is taken back.
  saveWatch()
  autosaveTick()
  if sessionPending and mdiAreaRect("ws").w > 0 and ui.now >= splashUntil: restoreSession()
  strokesMade = 0                # (the brushes' strokes: a few a frame)
  var open: seq[Doc]
  for dw in docs:
    if dw.doc.stepOpen: open.add dw.doc
  beginBusy("", cancel = true)
  let mark = layoutMark()
  try:
    frame()
  except BusyCancelled:
    for dw in docs:
      dw.doc.endLive()
      if dw.doc.stepOpen and dw.doc notin open: dw.doc.cancelStep()
    drag = Drag()
    textMove.on = false
    shapeMove.on = false
    status = "Cancelled"
    ui.redraw = true
  except Exception as e:
    # (a fault of the program: written in its fault log, the frame put back
    # -- it goes on rather than closing with the work in it)
    layoutRestore(mark)
    noteFault("Retro Photo " & AppVersion, e.msg & "\n" & e.getStackTrace())
    drag = Drag()
    status = "Something went wrong (" & e.msg & ") -- kept in the fault log: Help > Report a Problem"
    ui.redraw = true
  finally:
    endBusy(cancel = true)
  # (a change shown live that nothing is making any more: the image as it is)
  for dw in docs:
    let d = dw.doc
    if d.live.len > 0 and not (drag.on and drag.dw == dw and drag.moving) and not (xf.on and xf.dw == dw) and
       not (adjOpen and adjDoc == d) and not (liveSlider == d and ui.mouseDown):
      d.endLive()
      if liveSlider == d: liveSlider = nil
  splash()
  faultReport()
  # (a pen turned over: its eraser end erases, as the usual; turned back,
  # the tool it was)
  if ui.pen and not drag.on:
    if ui.eraser and tool != tEraser and penEraserFrom < 0:
      penEraserFrom = ord(tool)
      tool = tEraser
    elif not ui.eraser and penEraserFrom >= 0:
      tool = Tool(penEraserFrom)
      penEraserFrom = -1
  guarded("Scripts"):
    scriptDialogs()
    svgDialogs()
    vanishingPointDialog()
    # (a script to run once the program is up: RETRO_PHOTO_SCRIPT, as
    # editors run one given on its command line)
    if not startScriptDone and docs.len > 0 and ui.now >= splashUntil:
      let sp = getEnv("RETRO_PHOTO_SCRIPT")
      if sp.len == 0 or not fileExists(sp): startScriptDone = true
      elif startScriptAt == 0:
        startScriptAt = ui.now + 1500       # (once the window is up and drawing)
        wakeIn(1600)
      elif ui.now >= startScriptAt:
        startScriptDone = true
        runScriptFile(sp)
      else: wakeIn(max(10, startScriptAt - ui.now))
  if closeRequested():
    # (the window's close box, the phone's Back, Alt+F4: never straight away
    # while documents are open -- asked first)
    cancelClose()
    if docs.len == 0 and not saving(): quitApp()
    elif not quitAsked: quitConfirm = true
  if ui.paused and not wasPaused:
    # (the phone put the program away: it may be closed to free memory --
    # the session kept now, as it is)
    writeSession()
  wasPaused = ui.paused

proc main() =
  setup()
  const iconPng = staticRead("assets/photo-icon.png")
  windowIcon = windowIconFromPng(iconPng)   # (the taskbar's picture)
  reportedVersion = AppVersion
  startApp(AppName & " " & AppVersion, 1280, 800)
  autoFocus = false             # (the keys are the picture's until a palette's control is clicked)
  restoreAppearance(loadSettings(AppName))      # (the look chosen in Preferences)
  let splashMs = (try: parseInt(getEnv("RETRO_PHOTO_SPLASH", "1800")) except ValueError: 1800)
  var first = true
  for a in appArguments(): openFile(a)                         # (none in a phone's app)
  # (a picture to start with: $RETRO_PHOTO_OPEN)
  let atStart = getEnv("RETRO_PHOTO_OPEN")
  if atStart.len > 0:
    try: addDoc(openPicture(atStart))
    except CatchableError: status = "Could not open " & atStart
  while beginFrame():
    if stoppedFrame(): (endFrame(); continue)
    if first:
      splashUntil = ui.now + splashMs
      splashStart = ui.now
      first = false
    # (the type tool's fonts looked for on a thread once the window shows)
    if framesShown() > 0: scanFontsSoon()
    photoFrame()
    endFrame()
  if saving(): discard waitForSave()
  writeSession()                 # (the documents open: open again next time)
  clearRecovery()                # (a good end: this run's copies go)
  saveWorkspace()                # (the palettes where they were, next time)
  stopApp()

when not declared(photoUnderTest): main()
