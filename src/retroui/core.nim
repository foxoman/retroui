## The heart of the toolkit: the context `ui` (window, input of the frame,
## focus, the widget under the mouse), widget ids and their memory
## (`state`), the layout (`place`, `row`, `col`, `adaptive`, `group`),
## layers (dialogs, popups), drag and drop, the color schemes, and the main
## loop (`startApp`, `beginFrame`, `endFrame`).
##
## Widgets are made of: `place` (a cell of the layout), `interact` (mouse,
## finger and focus), `state(id)` (what the widget keeps between frames) and
## the drawing procs of `gfx`. An app usually only needs `app` (in `retroui`)
## and the widgets.

import std/[tables, sets, os, math, strutils, monotimes, times]
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)
from std/algorithm import sort
import uirelays/target   # (androidApp: an APK, not a program in Termux)
import uirelays
import uirelays/services
import uirelays/access
export access
when (defined(linux) or defined(bsd)) and not defined(android):
  import uirelays/atspi           # (screen readers told the toolkit's and the app's name)
import gfx, busy
export busy

const RetroVersion* = "0.46.0"
  ## The toolkit's version (shown in About boxes' Credits).
const
  RetroDeveloper* = "Sultan Al Isaiee"
    ## Who made Retro Nim UI (and its apps): every About box says so.
  RetroHandle* = "@foxoman"           ## the developer's handle
  RetroWebsite* = "www.foxoman.net"   ## the developer's website (About boxes link it)
  RetroEmail* = "sultan@foxoman.net"  ## the developer's e-mail address
  RetroCredit* = "Developed by " & RetroDeveloper & " " & RetroHandle
    ## "Developed by Sultan Al Isaiee @foxoman"
  RetroFontCredit* = "Fonts: GNU FreeFont -- FreeSans, FreeSerif, FreeMono (GNU GPL v3 or later, " &
                     "with the font exception)."
    ## What an About box says of the text fonts the app carries.
  ## The version of Retro Nim UI.

export gfx
export KeyCode, Modifier, CursorKind
export DragOutResult, canDragFilesOut

type
  Id* = uint32
    ## A widget's identity (see `idOf`, `makeId`), stable from frame to frame.

  Theme* = object
    ## The colors everything is drawn in (`ui.theme`; see `builtinThemes`).
    window*, text*: Color        ## client area and its text
    face*, light*, shadow*: Color ## button face and its 3D edges
    frame*: Color                ## black outlines
    select*, selectText*: Color  ## highlight (menus, lists, title bars)
    gray*: Color                 ## disabled text
    field*, fieldText*: Color    ## edit and list background
    scroll*: Color               ## scroll bar track
    tip*, tipText*: Color        ## tooltips
    line*: Color                 ## group box and separator lines
    edge*: Color                 ## borders of fields, lists, tabs, menus
    link*: Color                 ## hyperlinks
    hover*: Color                ## rows under the mouse (alpha 0: derived)
    face2*: Color                ## the softer inner highlight of raised faces
                                 ## (alpha 0: between `face` and `light`)
    inactiveTitle*, inactiveTitleText*: Color
      ## title bars of windows that are not in front (alpha 0: `window`, `text`)

  Hit* = object
    ## What happened to a widget this frame (`interact`).
    hover*: bool           ## the pointer is over it (also a finger's, see `showsHover`)
    down*: bool            ## pressed and the pointer still over it
    clicked*: bool         ## released over it: a click or a tap
    focused*: bool         ## it has the keyboard focus

  WState* = object
    ## Per-widget memory kept between frames (caret, scroll, ...).
    caret*, anchor*: int          ## text: the caret and the other end of the selection
    scrollX*, scrollY*: int       ## how far its content is scrolled
    aux*, aux2*: int              ## anything else the widget keeps
    buf*: string                  ## text being typed (number fields, editors)
    lines*: seq[int32]            ## measured line heights (rows that wrap)
    seen: int                    ## last frame it was used

  Metrics* = object
    ## Sizes in logical pixels. Touch screens get bigger targets.
    pad*, gap*: int        ## window/group padding, space between widgets
    ctrlH*, editH*: int    ## push button and edit/combo heights
    itemH*, menuH*: int    ## list and menu item height, menu bar height
    sbW*: int              ## scroll bar thickness

  LayoutKind = enum lkCol, lkRow, lkGroup
  LFrame = object
    kind: LayoutKind
    x, y, w: int
    cx, cy: int
    lineH, rowH, bottom: int
    natMax, prevH: int             ## rows: tallest content now / last frame
    lineNo: int                    ## rows: which line (rows wrap)
    lineNat: array[32, int32]      ## ... the tallest content of each line
    prevLines: array[32, int32]    ## ... last frame (a copy: a row's frame takes no memory)
    prevN: int                     ## ... how many
    limitY: int                    ## bottom of a pane, for `remainingH`
    dy: int                        ## how far the page is scrolled (root's kids)
    reserve: int                   ## room its box needs below the content
    fixed: bool                    ## a bar's row: not in the scrolling page
    springX, tailPrev, tailNow: int ## rows: where `spring` jumped to; how
                                    ## wide what follows it is (last frame, now)
    id: Id
    widths: array[16, int]
    nw, idx: int
    zeroNow: int                   ## rows: how wide its own-width (0) columns
                                   ## are on the first line (they come off the
                                   ## room the shares (-n) take, next frame)
    title: string

const
  Classic* = Theme(
    window: color(255, 255, 255), text: color(0, 0, 0),
    face: color(192, 192, 192), light: color(255, 255, 255),
    shadow: color(128, 128, 128), frame: color(0, 0, 0),
    select: color(0, 0, 128), selectText: color(255, 255, 255),
    gray: color(128, 128, 128), field: color(255, 255, 255),
    fieldText: color(0, 0, 0), scroll: color(192, 192, 192),
    tip: color(255, 255, 225), tipText: color(0, 0, 0),
    line: color(128, 128, 128), edge: color(0, 0, 0), link: color(0, 0, 128),
    face2: color(223, 223, 223))
    ## Windows 3.1 out of the box: white windows, gray buttons, navy title
    ## bars, white title bars for the windows behind.
  Gray* = Theme(
    window: color(192, 192, 192), text: color(0, 0, 0),
    face: color(192, 192, 192), light: color(255, 255, 255),
    shadow: color(128, 128, 128), frame: color(0, 0, 0),
    select: color(0, 0, 128), selectText: color(255, 255, 255),
    gray: color(128, 128, 128), field: color(255, 255, 255),
    fieldText: color(0, 0, 0), scroll: color(224, 224, 224),
    tip: color(255, 255, 225), tipText: color(0, 0, 0),
    line: color(128, 128, 128), edge: color(0, 0, 0), link: color(0, 0, 255))
    ## The gray "3D" dialogs late 3.1 applications used.
  Dark* = Theme(
    window: color(32, 32, 32), text: color(232, 232, 232),
    face: color(69, 69, 69), light: color(119, 119, 119),
    shadow: color(26, 26, 26), frame: color(0, 0, 0),
    select: color(0, 128, 128), selectText: color(255, 255, 255),
    gray: color(122, 122, 122), field: color(17, 17, 17),
    fieldText: color(232, 232, 232), scroll: color(51, 51, 51),
    tip: color(74, 70, 48), tipText: color(232, 232, 232),
    line: color(138, 138, 138), edge: color(138, 138, 138),
    link: color(110, 170, 255))
    ## A dark color scheme in the same style.
  Ocean* = Theme(
    window: color(255, 255, 255), text: color(0, 0, 0),
    face: color(160, 208, 208), light: color(224, 255, 255),
    shadow: color(0, 128, 128), frame: color(0, 0, 0),
    select: color(0, 128, 128), selectText: color(255, 255, 255),
    gray: color(64, 128, 128), field: color(240, 255, 255),
    fieldText: color(0, 0, 0), scroll: color(128, 192, 192),
    tip: color(255, 255, 225), tipText: color(0, 0, 0),
    line: color(0, 128, 128), edge: color(0, 0, 0), link: color(0, 0, 255))
    ## Teal and sea green, as the color schemes of the early 1990s had.
  Desert* = Theme(
    window: color(255, 255, 232), text: color(0, 0, 0),
    face: color(208, 192, 152), light: color(248, 240, 216),
    shadow: color(128, 96, 48), frame: color(0, 0, 0),
    select: color(128, 64, 0), selectText: color(255, 255, 255),
    gray: color(128, 112, 80), field: color(255, 255, 240),
    fieldText: color(0, 0, 0), scroll: color(224, 208, 168),
    tip: color(255, 255, 225), tipText: color(0, 0, 0),
    line: color(128, 96, 48), edge: color(0, 0, 0), link: color(0, 0, 192))
    ## Sand and terracotta.
  Plum* = Theme(
    window: color(255, 248, 255), text: color(0, 0, 0),
    face: color(200, 184, 208), light: color(248, 240, 255),
    shadow: color(104, 72, 120), frame: color(0, 0, 0),
    select: color(128, 0, 128), selectText: color(255, 255, 255),
    gray: color(120, 104, 128), field: color(255, 255, 255),
    fieldText: color(0, 0, 0), scroll: color(224, 208, 232),
    tip: color(255, 255, 225), tipText: color(0, 0, 0),
    line: color(104, 72, 120), edge: color(0, 0, 0), link: color(0, 0, 255))
    ## Purple and lilac.
  HotDog* = Theme(
    window: color(255, 255, 0), text: color(0, 0, 0),
    face: color(255, 0, 0), light: color(255, 160, 160),
    shadow: color(128, 0, 0), frame: color(0, 0, 0),
    select: color(0, 0, 0), selectText: color(255, 255, 0),
    gray: color(128, 64, 0), field: color(255, 255, 255),
    fieldText: color(0, 0, 0), scroll: color(255, 128, 0),
    tip: color(255, 255, 255), tipText: color(0, 0, 0),
    line: color(0, 0, 0), edge: color(0, 0, 0), link: color(0, 0, 255))
    ## Red and yellow, loud on purpose -- every color picker of the time had
    ## one of these.
  Paper* = Theme(
    window: color(255, 255, 255), text: color(0, 0, 0),
    face: color(255, 255, 255), light: color(255, 255, 255),
    shadow: color(0, 0, 0), frame: color(0, 0, 0),
    select: color(0, 0, 0), selectText: color(255, 255, 255),
    gray: color(96, 96, 96), field: color(255, 255, 255),
    fieldText: color(0, 0, 0), scroll: color(255, 255, 255),
    tip: color(255, 255, 255), tipText: color(0, 0, 0),
    line: color(0, 0, 0), edge: color(0, 0, 0), link: color(0, 0, 0))
    ## Black on white only, as a monochrome LCD showed it (and e-paper).
  Oled* = Theme(
    window: color(0, 0, 0), text: color(214, 214, 214),
    face: color(0, 0, 0), light: color(72, 72, 72),
    shadow: color(0, 0, 0), frame: color(96, 96, 96),
    select: color(0, 72, 144), selectText: color(255, 255, 255),
    gray: color(110, 110, 110), field: color(0, 0, 0),
    fieldText: color(214, 214, 214), scroll: color(18, 18, 18),
    tip: color(28, 28, 20), tipText: color(214, 214, 214),
    line: color(88, 88, 88), edge: color(120, 120, 120),
    link: color(100, 160, 240))
    ## True black for OLED screens: their pixels are off where it is black
    ## (no glow, less power, nothing to burn in), bevels kept as faint lines.
  HighContrast* = Theme(
    window: color(0, 0, 0), text: color(255, 255, 255),
    face: color(0, 0, 0), light: color(255, 255, 255),
    shadow: color(128, 128, 128), frame: color(255, 255, 255),
    select: color(0, 255, 255), selectText: color(0, 0, 0),
    gray: color(0, 255, 0), field: color(0, 0, 0),
    fieldText: color(255, 255, 255), scroll: color(0, 0, 0),
    tip: color(0, 0, 0), tipText: color(255, 255, 0),
    line: color(255, 255, 255), edge: color(255, 255, 255),
    link: color(255, 255, 0))
    ## White on black with yellow links and cyan selection, green for what
    ## is off: for people who need every edge clear.
  HighContrastWhite* = Theme(
    window: color(255, 255, 255), text: color(0, 0, 0),
    face: color(255, 255, 255), light: color(255, 255, 255),
    shadow: color(0, 0, 0), frame: color(0, 0, 0),
    select: color(55, 0, 110), selectText: color(255, 255, 255),
    gray: color(96, 0, 0), field: color(255, 255, 255),
    fieldText: color(0, 0, 0), scroll: color(255, 255, 255),
    tip: color(255, 255, 255), tipText: color(0, 0, 0),
    line: color(0, 0, 0), edge: color(0, 0, 0), link: color(0, 0, 159))
    ## Black on white with a purple selection: the same clear edges, light.
  Midnight* = Theme(
    window: color(16, 20, 40), text: color(220, 226, 240),
    face: color(36, 44, 78), light: color(78, 92, 140),
    shadow: color(10, 12, 26), frame: color(0, 0, 0),
    select: color(64, 96, 200), selectText: color(255, 255, 255),
    gray: color(120, 130, 160), field: color(10, 12, 26),
    fieldText: color(220, 226, 240), scroll: color(28, 34, 60),
    tip: color(44, 52, 88), tipText: color(220, 226, 240),
    line: color(96, 106, 146), edge: color(96, 106, 146),
    link: color(120, 170, 255))
    ## A dark scheme in night blues.
  Emerald* = Theme(
    window: color(240, 255, 244), text: color(0, 0, 0),
    face: color(150, 200, 160), light: color(215, 245, 220),
    shadow: color(40, 100, 56), frame: color(0, 0, 0),
    select: color(0, 100, 40), selectText: color(255, 255, 255),
    gray: color(64, 104, 74), field: color(255, 255, 255),
    fieldText: color(0, 0, 0), scroll: color(190, 225, 195),
    tip: color(255, 255, 225), tipText: color(0, 0, 0),
    line: color(40, 100, 56), edge: color(0, 0, 0), link: color(0, 0, 192))
    ## Greens, from leaf to bottle.
  Rose* = Theme(
    window: color(255, 245, 247), text: color(0, 0, 0),
    face: color(224, 176, 188), light: color(255, 232, 238),
    shadow: color(140, 60, 84), frame: color(0, 0, 0),
    select: color(160, 24, 72), selectText: color(255, 255, 255),
    gray: color(120, 80, 92), field: color(255, 255, 255),
    fieldText: color(0, 0, 0), scroll: color(240, 208, 216),
    tip: color(255, 255, 225), tipText: color(0, 0, 0),
    line: color(140, 60, 84), edge: color(0, 0, 0), link: color(0, 0, 192))
    ## Pink and wine.
  Slate* = Theme(
    window: color(244, 246, 250), text: color(0, 0, 0),
    face: color(168, 180, 196), light: color(228, 234, 242),
    shadow: color(72, 84, 104), frame: color(0, 0, 0),
    select: color(40, 64, 112), selectText: color(255, 255, 255),
    gray: color(88, 96, 112), field: color(255, 255, 255),
    fieldText: color(0, 0, 0), scroll: color(204, 212, 224),
    tip: color(255, 255, 225), tipText: color(0, 0, 0),
    line: color(72, 84, 104), edge: color(0, 0, 0), link: color(0, 0, 192))
    ## Blue grays, quiet for long days.
  Mahogany* = Theme(
    window: color(255, 250, 240), text: color(0, 0, 0),
    face: color(196, 148, 124), light: color(236, 204, 186),
    shadow: color(96, 48, 32), frame: color(0, 0, 0),
    select: color(128, 32, 16), selectText: color(255, 255, 255),
    gray: color(100, 70, 56), field: color(255, 255, 255),
    fieldText: color(0, 0, 0), scroll: color(220, 190, 172),
    tip: color(255, 255, 225), tipText: color(0, 0, 0),
    line: color(96, 48, 32), edge: color(0, 0, 0), link: color(0, 0, 192))
    ## Polished wood and cream.
  Amber* = Theme(
    window: color(0, 0, 0), text: color(255, 176, 0),
    face: color(28, 19, 0), light: color(110, 74, 0),
    shadow: color(0, 0, 0), frame: color(160, 110, 0),
    select: color(255, 176, 0), selectText: color(0, 0, 0),
    gray: color(192, 130, 0), field: color(0, 0, 0),
    fieldText: color(255, 176, 0), scroll: color(18, 12, 0),
    tip: color(36, 24, 0), tipText: color(255, 176, 0),
    line: color(128, 88, 0), edge: color(160, 110, 0),
    link: color(255, 220, 120))
    ## An amber terminal of the 1980s: amber on black.
  GreenScreen* = Theme(
    window: color(0, 0, 0), text: color(64, 255, 64),
    face: color(0, 26, 0), light: color(0, 104, 0),
    shadow: color(0, 0, 0), frame: color(0, 150, 0),
    select: color(64, 255, 64), selectText: color(0, 0, 0),
    gray: color(0, 190, 0), field: color(0, 0, 0),
    fieldText: color(64, 255, 64), scroll: color(0, 16, 0),
    tip: color(0, 34, 0), tipText: color(64, 255, 64),
    line: color(0, 120, 0), edge: color(0, 150, 0),
    link: color(170, 255, 170))
    ## A green phosphor terminal: green on black.
  builtinThemes* = [(name: "Classic", theme: Classic), (name: "Gray", theme: Gray),
                    (name: "Dark", theme: Dark), (name: "OLED Black", theme: Oled),
                    (name: "Ocean", theme: Ocean),
                    (name: "Desert", theme: Desert), (name: "Plum", theme: Plum),
                    (name: "Hot Dog", theme: HotDog), (name: "Paper", theme: Paper),
                    (name: "High Contrast", theme: HighContrast),
                    (name: "High Contrast White", theme: HighContrastWhite),
                    (name: "Midnight", theme: Midnight), (name: "Emerald", theme: Emerald),
                    (name: "Rose", theme: Rose), (name: "Slate", theme: Slate),
                    (name: "Mahogany", theme: Mahogany), (name: "Amber", theme: Amber),
                    (name: "Green Screen", theme: GreenScreen)]
    ## The color schemes that come with the toolkit, by name (new ones go at
    ## the end: settings keep a scheme's number).

  DesktopMetrics* = Metrics(pad: 8, gap: 6, ctrlH: 24, editH: 21,
                            itemH: 17, menuH: 21, sbW: 17)
    ## The sizes of Windows 3.1 dialogs (at the default text size: a
    ## 15-pixel line; `fitMetrics` makes them from the text in use).
  TouchMetrics* = Metrics(pad: 8, gap: 8, ctrlH: 34, editH: 32,
                          itemH: 30, menuH: 32, sbW: 22)
    ## The same look with targets a finger can hit (an 18-pixel line).
  LayerBase* = 0         ## the window's content and its bars
  LayerDialog* = 1       ## dialogs (over the content)
  LayerPopup* = 2        ## menus, drop-down lists, calendars (over dialogs)
  LayerTip* = 3          ## tooltips, balloons, the dragged label (over all)

type
  DragInfo* = object
    ## What is being dragged (see `startDrag`).
    active*: bool                ## a drag is going on
    kind*: string                ## what it is ("files"...): targets take kinds they know
    items*: seq[string]          ## the payload (paths, ids...)
    label*: string               ## shown at the pointer
    glyph*: string               ## an icon-font glyph before the label
    source*: Id                  ## the widget it came from
    files*: proc (): seq[string] ## the files it is for other programs, made when it
                                 ## leaves the window (nil: it stays in the window)
    moveFiles*: bool             ## ... and they may move them instead of copying
  DropState* = enum
    ## Where a drag stands for a drop target (`dropTarget`).
    dsNone                       ## no drag of that kind is over the target
    dsOver                       ## it is over the target (draw it highlighted)
    dsDropped                    ## it was dropped on the target this frame

type ControlSizes* = enum
  ## How big the controls are: for a mouse or for fingers.
  csAuto = "Automatic"     ## finger-sized on phones; desktop-sized on tablets and desktops
  csDesktop = "Desktop"    ## Windows 3.1's sizes, for a mouse or a pen (also on tablets)
  csTouch = "Touch"        ## targets a finger can hit, everywhere

type Ctx* = object
  ## Everything the toolkit knows about the window and this frame: `ui`.
  ## Apps read a few fields (`w`, `h`, `touch`, `theme`, `mods`...);
  ## widgets use the rest.
  running*: bool                 ## false once the app is ending
  closeAsked, closeCancelled: bool
  frameNo*: int                  ## frames run so far
  w*, h*: int                    ## window size in logical pixels
  devW, devH, zoomWanted: int
  theme*: Theme                  ## the colors in use (set it to change them)
  m*: Metrics                    ## sizes; see `DesktopMetrics`
  metricsSet: bool
  touch*: bool                   ## a touch screen (phone, tablet): how input works
  sizes*: ControlSizes           ## how big controls are (see `setControlSizes`)
  roomy: bool                    ## a big screen: its shorter side 600 dp or more
  k*: float                      ## sizes are `k` times the 100% design
  density: float                 ## the screen's scale left after `zoom`
  uiScale: int                   ## the user's size, percent (100)
  textScale: int                 ## the user's text size, percent (100)
  baseEm: float                  ## text size at 100%
  paused*: bool                  ## mobile app in the background
  hidden*: bool                  ## desktop window minimized or covered all over:
                                 ## frames and timers go on, nothing is drawn
                                 ## (read less often, as nobody looks)
  safe*: tuple[top, left, bottom, right: int]
    ## margins a notch or system bars cover, in logical pixels (and the
    ## sizing border of the 3.1 frame, `setClassicFrame`)
  layoutSafe: tuple[top, left, bottom, right: int]   # ... the system's alone
  title*: string                 ## the window's title
  ownCaption*: bool              ## the app draws its own title bar (phones; the 3.1 frame)
  captionH*: int                 ## its height (0: none, the system's)
  ownFrame*: bool                ## desktops: the app draws the window's whole frame, as
                                 ## Windows 3.1 did (`setClassicFrame`)
  frameBorder*: int              ## ... its sizing border's width now (0 while maximized)
  pageY*: int                    ## how far the window's content is scrolled
  pageMax*: int                  ## ... at most
  pageOn*: bool                  ## the content is taller than the window
  pageView*: Rect                ## where the content shows (last frame)
  blockers*: seq[Rect]           ## parts covered by windows over what is drawn now
                                 ## (overlapping windows: `mdiWindow`)
  pageX*: int                    ## how far the content is scrolled sideways
  pageMaxX*: int                 ## ... at most (content wider than the window)
  contentRight: int              # the right end of the widest row this frame
  contentTop: int
  # input of this frame
  mx*, my*: int                  ## the mouse (or finger) in logical pixels
  mouseDown*: bool               ## the left button (or a finger) is down
  pressed*: bool                 ## ... went down this frame
  released*: bool                ## ... was let go this frame
  rpressed*: bool                ## a right click (or a long press, or the menu key) this frame
  rpressAgain: bool              ## (a right click that closed a menu: given again next frame)
  popupBefore: Id                ## (the popup open when the frame began)
  rmouseDown*: bool              ## the right button is held (a drag with it: Alt + right in Photoshop)
  pressUsed*: bool               ## a widget took this frame's press (`takePress`)
  mpressed*: bool                ## the middle button went down this frame
  navBack, navForward: bool      ## the mouse's side buttons this frame
  menuKey*: bool                 ## this frame's right click is the menu key's
  mouseMoved*: bool              ## the mouse moved this frame
  active31*: bool                ## the window has the keyboard focus
  clicks*: int                   ## 1 a click, 2 a double click... (this frame's press)
  wheel*: int                    ## wheel notches this frame (> 0: up / away);
                                 ## with Shift held, sideways (> 0: to the left)
  wheelX*: int                   ## sideways notches this frame (> 0: to the right)
                                 ## -- a tilted wheel, a touch pad, macOS's Shift +
                                 ## the wheel -- also in `wheel` as Shift + the
                                 ## wheel, the way Windows and X11 send that
  wheelUsed*: bool               ## a widget scrolled with them already
  doubleClick*: bool             ## a list/edit/grid got a double click
  doubleClickId*: Id             ## ... namely this one
  # touch gestures
  pressAt, pressX, pressY: int
  longFired, panning, backPending: bool
  lift, lifted: bool           # a held finger moved: a touch drag starts
  longX, longY: int
  byBack, byBackNow: bool        ## the close request came from Back
  hovering: bool                 ## a mouse (not a finger) is over the window
  fingerDown: bool               ## the press now is a finger's (drags scroll)
  dragsActive*: bool             ## the pressed widget wants drags itself
  panX*, panY*: int              ## pixels a finger dragged content this frame
  panFrom*: Point                ## where that drag began
  panUsed*: bool                 ## a widget scrolled with it already
  panOwner*: uint32              ## the scroller this gesture is with (0: none yet)
  panAlong*: int8                ## its axis, from its first move: 1 sideways, 2 up and down
  panHanded: bool                # the owner reached its end this frame: the rest to one around it
  panOwnerSeen: int              # the frame the owner was last drawn in
  key*: KeyCode                  ## the key pressed this frame (KeyNone: none)
  mods*: set[Modifier]           ## Ctrl, Alt, Shift held now
  keyUp*: KeyCode                ## the key let go this frame
  keyUsed*: bool                 ## a widget handled `key` already
  typed*: string                 ## the text typed this frame (UTF-8)
  mnemonic*: char                ## Alt + this letter was pressed ('\0': none)
  textOk: bool
  composing*: string             ## what the system's input method composes now (a
                                 ## text box with the focus shows it at its caret)
  composeCaret*: int             ## ... and the caret in it (bytes)
  now*: int                      ## the time of this frame, in milliseconds
  force: bool
  # interaction
  hot*: Id                       ## the widget under the mouse
  active*: Id                    ## the widget being pressed (or dragged)
  focus*: Id                     ## the widget with the keyboard focus
  prevHot: Id
  hoverSince: int
  lastId*: Id                    ## the widget drawn last (for `tooltip`, `contextMenu`...)
  lastRect*: Rect                ## ... and where it was
  focusRect*: Rect               ## where the focused widget was drawn
  seeRect: Rect                  # a screen reader asked to see this (its control's place)
  seeAt: int                     # ... in this frame
  focusMoved*: int               ## frame the keyboard last moved focus
  focusByKeys*: bool             ## the focus came from the keyboard (Tab, arrows), not a click
  tabOrder: seq[Id]
  stopsBefore: seq[Id]           # the last frame's stops of Tab
  stopArea: seq[Id]              # each stop's area (F6), beside `tabOrder`
  stopIndex: seq[int16]          # each stop's `tabIndex` (0: none), beside `tabOrder`
  nextTabIndex: int              # the next stop's (`tabIndex`)
  anyTabIndex: bool              # ... some stop has one this frame
  notFirst: seq[Id]              # stops the focus does not start at (a tool bar's)
  areaNow: Id                    # the area being drawn (0: the window's own)
  areaStack: seq[Id]
  menuFirst: Id                  # the menu bar's first menu, this frame (F6 reaches it)
  areaWanted: int                # F6 from an open menu: the first (1) or last (-1) area next
  focusSeen: bool                ## the focused widget answered this frame (a stop of Tab
                                 ## or not: a list that takes keys but no Tab)
  takesEnter*, prevTakesEnter*: bool  ## the focused widget uses Enter itself (no default button)
  takesText*, prevTakesText: bool     ## the focused widget takes typing (keyboard on phones)
  focusWanted: bool
  textFocusWanted*: bool         ## the next text box takes the focus (`focusFirstText`)
  textFocusInDialog*: bool       ## ... the next one in a dialog
  wakeAt*: int                   ## when to run a frame without input (see `wakeIn`)
  redrawNow*: bool               ## run another frame right away: read and set it as `ui.redraw`
  redrawCount, lastPresent: int
  inputOnly: bool                # this frame's redraw is only the one after an input
  spaceDown*: bool               ## Space is holding a button down
  # ids
  idStack: seq[uint32]
  occ: array[512, tuple[k, gen: uint32; n: uint16]]
  gen: uint32
  # layout
  frames: seq[LFrame]
  lastFault*: string             ## the last fault `guarded` caught ("": none since it was shown)
  rtl*: bool                     ## the interface mirrored, right to left (an Arabic one: `setUiLanguage`)
  pen*: bool                     ## the pointer is a pen (a stylus), and these say how it is held:
  pressure*: float               ## ... how hard it presses (0 .. 1; 1 for a mouse or a finger)
  pinch*: float                  ## two fingers this frame: how much nearer or further apart
                                 ## (1: not at all; 2: twice as far) -- zoom by it, round
  pinchX*, pinchY*: int          ## ... their middle
  panDX*, panDY*: float          ## ... how far their middle moved (logical pixels)
  gesturing*: bool               ## two fingers are down (a pinch or a two-finger drag)
  tilt*: float                   ## ... how far it leans (0 upright .. 1 lying flat)
  azimuth*: float                ## ... which way it leans (radians, 0 to the right, clockwise)
  twist*: float                  ## ... turned on its own axis (degrees, where the pen says)
  eraser*: bool                  ## ... its eraser end is down
  barY*: int                     ## where the content starts under the bars at the top
  bottom*: int                   ## where it ends above the bars at the bottom
  prevBottom*: int               ## ... last frame
  winX*, winY*: int              ## the window's top left: 0, 0, but a `windowBox`
                                 ## moves it to its box (its bars, dialogs, menus)
  inertDepth*: int               ## > 0 inside `inert`: what is drawn takes no input
  measuring*: bool               ## `placed` is kept (a designer asks where widgets went)
  placed*: Rect                  ## ... the cells laid out since it was cleared
  # layers
  inputLayer*: int               ## the layer that gets the input (the top one open)
  popup*: Id                     ## the open menu or drop-down (0: none)
  popupRect*, popupRectNow*, popupOwner*: Rect  ## where it is (last frame, now) and what opened it
  popupHi*: int                  ## its highlighted item
  menuOpen*: bool                ## the open popup belongs to the menu bar
  dialogTop*: Id                 ## the dialog on top (last frame; 0: none)
  dialogTopNow*: Id              ## ... this frame
  curDialog*: Id                 ## the dialog being drawn now
  focusBeforeDialog: Id
  tip*: string                   ## the tooltip of the widget under the mouse
  tipKey, prevTipKey: uint32
  cursor*: CursorKind            ## mouse pointer wanted this frame
  shownCursor: CursorKind
  popupRect2Now*: Rect           ## an open submenu
  popupOpened*: bool             ## a menu opened this frame after it was drawn (F10, Alt): kept
  altTapped*: bool               ## Alt pressed and let go alone: the menu bar, as on Windows
  altArmed: bool                 # (Alt is down, nothing else pressed since)
  overlay*, overlayNow*: Rect    ## a drop-down drawn by a widget itself
  overlayLayer*, overlayLayerNow*: int  ## ... the layer that widget is on
  overlayOwner*: bool            ## that widget is handling its drop-down
  drag*: DragInfo                ## what is being dragged
  dragDropping: bool             ## ... and it was let go this frame
  dragClaimed: bool              ## ... and a target took it
  dragOver: bool                 ## ... a target is under it this frame
  states: Table[Id, WState]

var ui*: Ctx
  ## The UI's state for this frame: the window's size (`ui.w`, `ui.h`), the
  ## pointer and keys (`ui.mx`, `ui.my`, `ui.key`, `ui.mods`), the theme,
  ## the time (`ui.now`)... Read it in an app; the kit writes it.

# ---- why a frame runs ---------------------------------------------------------------------------
#
# An app at rest runs no frames; one that does, the inspector (F12,
# RETRO_INSPECT) says why: the input it took, or where the frame before
# asked for it -- the line of its `ui.redraw = true` or of its `wakeIn`.
# Nothing is noted unless `whyFrames` (the inspector) is on.

type FrameSite* = tuple[file: string; line: int]
  ## A line of the program: where a frame was asked for.

var
  whyFrames*: bool
    ## Note who asks for frames (the inspector does): `frameCause`.
  redrawSite*: FrameSite             ## the last `ui.redraw = true` (while `whyFrames`)
  wakeSite*: FrameSite               ## the `wakeIn` that set the next timer (while `whyFrames`)
  frameEvents*: int                  ## the input events this frame took
  frameCause*: string                ## why this frame ran (while `whyFrames`)

template redraw*(u: Ctx): bool = u.redrawNow
  ## Another frame is wanted right away (something changed).

template `redraw=`*(u: var Ctx; v: bool) =
  ## Ask for another frame right away (`ui.redraw = true`), or not; while
  ## the inspector looks, where it was asked is noted (`redrawSite`).
  u.redrawNow = v
  if whyFrames and u.redrawNow:
    const at = instantiationInfo(-1)
    redrawSite = (at.filename, at.line)

ui.theme = Classic
ui.m = DesktopMetrics
ui.k = 1
ui.density = 1
ui.uiScale = 100
ui.textScale = 100

template Pad*: int = ui.m.pad
  ## Window and group padding (`Metrics.pad`).
template Gap*: int = ui.m.gap
  ## Space between widgets (`Metrics.gap`).
template CtrlH*: int = ui.m.ctrlH
  ## A push button's height (`Metrics.ctrlH`).
template EditH*: int = ui.m.editH
  ## An edit or combo box's height (`Metrics.editH`).
template ItemH*: int = ui.m.itemH
  ## A list or menu item's height (`Metrics.itemH`).
template MenuH*: int = ui.m.menuH
  ## The menu bar's height (`Metrics.menuH`).
template SbW*: int = ui.m.sbW
  ## A scroll bar's thickness (`Metrics.sbW`).

proc setMetrics*(m: Metrics) =
  ## Use your own sizes (bigger items, wider scroll bars...).
  ui.m = m
  ui.metricsSet = true

proc dp*(v: int): int =
  ## `v` design pixels in logical pixels: sizes follow the screen's density
  ## and the user's UI size (`setUiScale`). 1 stays 1.
  if v <= 1 and v >= -1: v
  else: int(round(float(v) * ui.k))

proc dpf*(v: float): float = v * ui.k
  ## `dp` for fractions: `v` design pixels in logical pixels, not rounded.

proc fingers*(): bool {.inline.} =
  ## Controls are finger-sized: on a phone (automatic sizes), or always
  ## (`csTouch`). A tablet has desktop sizes unless the user asks: the
  ## screen holds a desktop app's layout, and a finger still taps it.
  case ui.sizes
  of csTouch: true
  of csDesktop: false
  of csAuto: ui.touch and not ui.roomy

const
  DesktopTextEm* = 12.0
    ## The UI's text size at 100 % on desktops and tablets, logical pixels
    ## per em (a 15-pixel line).
  TouchTextEm* = 15.0
    ## The UI's text size at 100 % with finger-sized controls (phones).

proc fitMetrics() =
  ## Every size from the text size: a bigger font makes bigger controls.
  let em = (if ui.baseEm > 0: ui.baseEm
            elif fingers(): TouchTextEm else: DesktopTextEm) * ui.k * float(ui.textScale) / 100
  setTextSize(em)
  if ui.metricsSet: return
  let L = FontH
  ui.m =
    if fingers():
      Metrics(pad: dp(8), gap: dp(8), ctrlH: L + dp(16), editH: L + dp(14),
              itemH: L + dp(12), menuH: L + dp(14), sbW: dp(22))
    else:
      Metrics(pad: dp(8), gap: dp(6), ctrlH: L + dp(9), editH: L + dp(6),
              itemH: L + dp(2), menuH: L + dp(6), sbW: dp(17))

# ---- ids --------------------------------------------------------------------

proc fnv*(s: string; h = 2166136261'u32): uint32 =
  ## A 32-bit FNV-1a hash of `s` (widget ids are made from them).
  result = h
  for c in s:
    result = (result xor ord(c).uint32) * 16777619'u32

proc mixId*(a, b: uint32): uint32 {.inline.} =
  ## Two ids (or hashes) mixed into one.
  var h = (a xor (b + 0x9e3779b9'u32 + (a shl 6) + (a shr 2)))
  h = h xor (h shr 15)
  h * 0x2c1b3c6d'u32

proc makeId*(seed: uint32): Id =
  ## A widget id: `seed` within the current id scope, plus how many times
  ## the same seed was already used this frame (two "OK" buttons differ).
  var h = mixId(seed, if ui.idStack.len > 0: ui.idStack[^1] else: 0)
  var slot = int(h and 511)
  for _ in 0 ..< 512:
    if ui.occ[slot].gen != ui.gen:
      ui.occ[slot] = (h, ui.gen, 1'u16)
      break
    if ui.occ[slot].k == h:
      inc ui.occ[slot].n
      h = mixId(h, ui.occ[slot].n.uint32)
      break
    slot = (slot + 1) and 511
  result = if h == 0: 1 else: h

proc peekId*(seed: uint32): Id =
  ## The id `makeId(seed)` would give now, without taking it (the widget
  ## drawn next with this seed gets it).
  var h = mixId(seed, if ui.idStack.len > 0: ui.idStack[^1] else: 0)
  var slot = int(h and 511)
  for _ in 0 ..< 512:
    if ui.occ[slot].gen != ui.gen: break
    if ui.occ[slot].k == h:
      h = mixId(h, uint32(ui.occ[slot].n + 1))
      break
    slot = (slot + 1) and 511
  if h == 0: 1 else: h

proc idOf*(label: string): Id = makeId(fnv(label))
  ## Id of a widget by its label (the same label twice in a frame: two ids).
proc idOfLabel*(kind, label: string; more = ""): Id = makeId(fnv(more, fnv(label, fnv(kind))))
  ## `idOf(kind & label & more)` -- the same id -- without making that
  ## string: a widget whose id is its kind and label ("tool:", a tip) takes
  ## no memory for it every frame.
proc idOf*[T](v: var T; extra = ""): Id =
  ## Id of a widget bound to a variable: its address.
  let a = uint64(cast[uint](addr v))
  makeId(fnv(extra, mixId(uint32(a and 0xFFFFFFFF'u64), uint32(a shr 32))))

proc peekId*(label: string): Id =
  ## The id the first widget of `label` gets in the current id scope, with
  ## no use counted (each `idOf` counts one: the same label twice in a frame
  ## gives two ids). For code before or after the widget that asks about it:
  ## `if ui.focus == peekId("list"): ...`.
  let h = mixId(fnv(label), if ui.idStack.len > 0: ui.idStack[^1] else: 0)
  if h == 0: 1 else: h

proc peekId*[T](v: var T; extra = ""): Id =
  ## `peekId` of a widget bound to a variable (as `idOf(v, extra)` the first
  ## time in the frame).
  let a = uint64(cast[uint](addr v))
  let h = mixId(fnv(extra, mixId(uint32(a and 0xFFFFFFFF'u64), uint32(a shr 32))),
                if ui.idStack.len > 0: ui.idStack[^1] else: 0)
  if h == 0: 1 else: h

proc pushId*(key: string) =
  ## Widgets made until `popId` get ids of their own under `key` (rows of a
  ## list drawn with the same code; see `withId`).
  ui.idStack.add mixId(fnv(key), if ui.idStack.len > 0: ui.idStack[^1] else: 0)
proc pushId*(key: int) = pushId($key)
  ## `pushId` with a number (a row's index).
proc popId*() =
  ## Ends a `pushId`.
  if ui.idStack.len > 0: discard ui.idStack.pop()

template withId*(key: typed; body: untyped) =
  ## Give the widgets in `body` their own id scope (e.g. per list row).
  pushId(key)
  body
  popId()

proc state*(id: Id): var WState =
  ## The memory of widget `id`, created on first use. Memory of widgets
  ## that are gone is dropped after a while.
  ui.states.mgetOrPut(id, WState()).seen = ui.frameNo
  ui.states[id]

# ---- input routing -----------------------------------------------------------

proc canInput*(): bool =
  ## Whether widgets drawn now receive mouse and keyboard input: only the
  ## topmost layer (an open menu, else the top dialog, else the window) does.
  ui.inertDepth == 0 and layer() == ui.inputLayer and
    (ui.inputLayer != LayerDialog or ui.curDialog == ui.dialogTop)

proc blocked(p: Point): bool {.inline.} =
  for b in ui.blockers:
    if b.contains(p): return true

proc mouseIn*(r: Rect): bool =
  ## The mouse (or finger) is over `r`, inside the clip and not under a
  ## drop-down or another window. (`hover` also asks that the widget's
  ## layer takes input.)
  let p = point(ui.mx, ui.my)
  ui.inertDepth == 0 and r.contains(p) and clipRect().contains(p) and
    (ui.overlayOwner or layer() > ui.overlayLayer or ui.overlay.w == 0 or
     not ui.overlay.contains(p)) and
    (ui.blockers.len == 0 or layer() > 0 or not blocked(p))

proc hover*(r: Rect): bool = canInput() and mouseIn(r)
  ## The mouse is over `r` and its layer takes input (see `mouseIn`).

proc longPressed*(): bool = ui.longFired
  ## The press now (or the last one) was held long enough to become a right
  ## click (a menu): its release is not a click.

proc finger*(): bool = ui.fingerDown
  ## The press now (or the last one) is a finger's on a touch screen, not a
  ## mouse's: taps open, drags scroll, a long press is a right click.

proc keyboardWanted*(): bool = ui.prevTakesText
  ## The focused control takes typing: the window asks for the on-screen
  ## keyboard (a phone, a tablet), and lets it go when this turns false.

proc canHover*(): bool = ui.hovering or not ui.touch
  ## A mouse is over the window (hover effects make sense); false on a
  ## touch screen between touches.

proc showsHover*(h: Hit): bool {.inline.} = h.hover and canHover()
  ## Draw `h`'s widget lit up as "under the mouse": only with a mouse, so
  ## nothing stays lit where a finger was lifted.

proc hovered*(r: Rect): bool =
  ## The mouse rests over `r` (no button down): for hover highlights.
  canHover() and not ui.mouseDown and hover(r)

proc markDouble*(id: Id) =
  ## Widget `id` got a double click (or Enter) this frame.
  ui.doubleClick = true
  ui.doubleClickId = id

proc takePress*(): bool =
  ## The left button went down this frame and nobody took it yet.
  if ui.pressed and not ui.pressUsed:
    ui.pressUsed = true
    true
  else: false

proc panShare*(id: uint32; area: Rect; vx, hiX, vy, hiY: int): tuple[dx, dy: int] =
  ## The part of this frame's finger movement the scroller `id` takes: its
  ## `area`, at `vx` of 0 .. `hiX` and `vy` of 0 .. `hiY` (a `hi` of 0: it
  ## does not scroll that way). Scrollers inside one another share a swipe
  ## as Android's do -- the inner one is drawn, and asks, first:
  ##
  ## - a gesture goes along the axis of its first move; a scroller that
  ##   scrolls only the other way leaves it (a carousel, to the page);
  ## - a scroller at its end that way leaves it (a list at its top, swiped
  ##   down: the page around it moves);
  ## - the first one that takes a gesture keeps it until the finger lifts,
  ##   the way back too;
  ## - one that reaches its end in the middle of it hands the rest, and
  ##   the gesture from then on, to the nearest one around it that can move
  ##   that way -- never back inward.
  ##
  ## `scrollPan`, `scrollPan2`, `takePan` and `takePanX` go by it; a
  ## scroller of your own calls it with its id and moves by what it gives.
  if id != 0 and ui.panOwner == id: ui.panOwnerSeen = ui.frameNo
  if (ui.panX == 0 and ui.panY == 0) or ui.panUsed or not canInput() or
     not area.contains(ui.panFrom):
    return
  let sideways = ui.panAlong == 1
  let d = if sideways: ui.panX else: ui.panY
  let v = if sideways: vx else: vy
  let hi = if sideways: hiX else: hiY
  if hi <= 0 or d == 0: return
  let mine = ui.panOwner == id
  if ui.panOwner != 0 and not mine and not ui.panHanded: return   # (another's)
  let take = if d > 0: min(d, max(0, hi - v)) else: max(d, min(0, -v))
  if take == 0:
    if mine: ui.panHanded = true             # at its end: on to one around it
    return
  ui.panOwner = id
  ui.panOwnerSeen = ui.frameNo
  ui.panHanded = false
  if sideways:
    result.dx = take
    ui.panX = d - take
    if hiY > 0:
      result.dy = ui.panY
      ui.panY = 0
  else:
    result.dy = take
    ui.panY = d - take
    if hiX > 0:
      result.dx = ui.panX
      ui.panX = 0
  if take != d: ui.panHanded = true          # its end reached: the rest on
  else: ui.panUsed = true

proc panIdOf(r: Rect): uint32 =
  ## (an id for a scroller that has none of its own: its place)
  0x9A000000'u32 xor uint32((r.x * 7919 + r.y * 31 + r.w * 3 + r.h) and 0xFFFFFF)

proc takePanX*(r: Rect; id = Id(0)): int =
  ## Touch: the pixels a finger dragged sideways over `r` this frame (tab
  ## strips, carousels); 0 when there is nothing to take -- a gesture up
  ## or down is the page's (`panShare`).
  let k = if id != 0: uint32(id) else: panIdOf(r)
  panShare(k, r, 1 shl 29, 1 shl 30, 0, 0).dx         # (its range unknown: room both ways)

proc middleClicked*(r: Rect): bool =
  ## The middle mouse button went down over `r` this frame (open in a new
  ## tab, close a tab); uses the press.
  if ui.mpressed and canInput() and mouseIn(r):
    ui.mpressed = false
    true
  else: false

proc mouseBack*(): bool =
  ## The mouse's back side button (X1) was pressed this frame; uses it.
  result = ui.navBack and canInput()
  if result: ui.navBack = false

proc mouseForward*(): bool =
  ## The mouse's forward side button (X2) was pressed this frame; uses it.
  result = ui.navForward and canInput()
  if result: ui.navForward = false

proc takePan*(r: Rect; id = Id(0)): int =
  ## Touch: the pixels a finger dragged vertically over `r` this frame, for
  ## scrolling content; 0 when there is nothing to take -- a sideways
  ## gesture is left to what is around it (`panShare`).
  let k = if id != 0: uint32(id) else: panIdOf(r)
  panShare(k, r, 0, 0, 1 shl 29, 1 shl 30).dy         # (its range unknown: room both ways)

proc keyHit*(k: KeyCode): bool =
  ## `k` was pressed this frame and is not used yet; uses it.
  if ui.key == k and not ui.keyUsed and canInput():
    ui.keyUsed = true
    true
  else: false

proc wakeInFrom*(ms: int; file: string; line: int) =
  ## `wakeIn`, told where it was called (for the inspector).
  let t = ui.now + max(1, ms)
  if ui.wakeAt == 0 or t <= ui.wakeAt:
    ui.wakeAt = t
    if whyFrames: wakeSite = (file, line)

template wakeIn*(ms: int) =
  ## Run another frame after `ms` milliseconds even without input.
  const at = instantiationInfo(-1)
  wakeInFrom(ms, at.filename, at.line)

proc wakeInShown*(r: Rect; ms: int) =
  ## `wakeIn` for what changes by itself where it is drawn (an animation, a
  ## clock): only while `r` can be seen -- scrolled out of view or clipped
  ## away, it wakes nothing, and an app at rest takes no time.
  if intersects(r, clipRect()) and intersects(r, rect(0, 0, ui.w, ui.h)): wakeIn(ms)

# ---- smooth scrolling ------------------------------------------------------------
#
# Every widget that scrolls keeps its position in pixels and hands it to these
# procs: the wheel, the keys and the scroll bars' arrows make it glide to where
# it goes (an ease-out, notches that keep coming add up), a finger moves it
# exactly and a flick keeps it going, slowing down; the scroll bar's thumb and
# anything else that sets the position directly just jumps there. Only the
# scrollers that move are kept (a table by widget id), and frames are asked
# for only while something moves.

var autoFocus* = true
  ## With no widget focused, the first one that can take the focus takes
  ## it, as in a 3.1 dialog. False for programs whose keys go to a canvas
  ## (an image editor, a game): a palette's box then takes the focus only
  ## when clicked. (Dialogs always focus their first control.)

var smoothScrolling* = true
  ## The wheel, the keys and the scroll bars' arrows scroll with a short glide
  ## and a flicked finger keeps the content moving; false: every scroll jumps
  ## at once (`setSmoothScrolling`, "Smooth scrolling" in
  ## `appearanceSettings`).

proc setSmoothScrolling*(on: bool) =
  ## Turns gliding scrolls and flicks on or off (see `smoothScrolling`).
  smoothScrolling = on

type CaptionButtons* = enum
  ## The buttons at the right of the title bars the toolkit draws: the 3.1
  ## frame's (`setClassicFrame`), a dialog's, a window's in an `mdiArea`,
  ## the caption bar of a window besides the app's (`captionButtons`).
  cbWin95 = "win95"   ## minimize, maximize (restore) and close, _ □ X, as
                      ## Windows 95 has them (the default)
  cbWin31 = "win31"   ## Windows 3.1's: minimize and maximize as triangles,
                      ## no close button (the control-menu box closes)

var captionButtons* = cbWin95
  ## The title bars' buttons (`CaptionButtons`). Set it before `startApp`
  ## for the app's own default; the user's choice ("Title bar buttons" in
  ## `appearanceSettings`) is kept with the look (`storeAppearance`) and
  ## wins. A title bar the system draws keeps the system's buttons, and a
  ## phone's caption bar has no close button in either (Back closes).

type
  ScrollMode = enum smIdle, smGlide, smFling, smFinger
  ScrollAnim = object
    mode: ScrollMode
    pos, fromPos, target: float   ## pixels
    t0, lastT: int                ## when the glide began; the fling's last step
    vel: float                    ## a fling's speed, pixels per millisecond
    shown: int                    ## the position handed out last
    samples: array[8, tuple[t: int; d: float]]   ## a finger's last moves
    n: int

const
  GlideMs = 150                   ## how long a glide takes
  FlingTau = 325.0                ## a fling slows down by e every this many ms
  FlingMin = 0.05                 ## px/ms: slower than this, a flick stops
  StepMs = 16                     ## frames while something moves: ~60 a second, in
                                  ## step with most screens (13 ms beat against
                                  ## 60 Hz: every 4th shown frame moved twice)

var
  scrollAnims: Table[uint32, ScrollAnim]
  flingCaught: bool               ## the press now stopped a moving list

proc scrollCaught*(): bool = flingCaught
  ## The finger that went down last stopped a list that was still moving
  ## (its tap only stops it: it does not pick an item).

proc scrolling*(id: Id): bool = scrollAnims.hasKey(uint32(id))
  ## The scroller `id` is gliding, flying on after a flick or under a finger.

proc scrollTarget*(id: Id; v: int): int =
  ## Where the scroller `id` is going (`v` itself when it is not gliding).
  let k = uint32(id)
  if scrollAnims.hasKey(k) and scrollAnims[k].mode == smGlide:
    int(round(scrollAnims[k].target))
  else: v

proc scrollStop*(id: Id) =
  ## Stops whatever moves the scroller `id` (it stays where it is).
  scrollAnims.del(uint32(id))

proc scrollTo*(id: Id; v: var int; target, hi: int) =
  ## Moves the scroll position `v` (0 .. `hi` pixels) of the scroller `id` to
  ## `target`: a glide with `smoothScrolling` (`scrollTick` moves it on, each
  ## frame), else at once. For the keys, "show the selected row", the scroll
  ## bars' arrows.
  let t = clamp(target, 0, max(0, hi))
  let k = uint32(id)
  if not smoothScrolling:
    scrollAnims.del(k)
    v = t
    return
  var a = scrollAnims.getOrDefault(k)
  let moving = a.mode in {smGlide, smFling} and a.shown == v
  if not moving and t == v:
    scrollAnims.del(k)
    return
  a.fromPos = if moving: a.pos else: float(v)
  a.pos = a.fromPos
  a.target = float(t)
  # (a step into the glide at once: wheel notches that come every frame
  # would otherwise start it again at its beginning each time, and it would
  # not move until they stop)
  a.t0 = ui.now - StepMs
  a.mode = smGlide
  a.shown = v
  a.n = 0
  scrollAnims[k] = a
  wakeIn(StepMs)

proc scrollBy*(id: Id; v: var int; delta, hi: int) =
  ## `scrollTo` by `delta` pixels from where the scroller is going (glides
  ## that keep coming add up, as wheel notches do).
  scrollTo(id, v, scrollTarget(id, v) + delta, hi)

proc scrollShow*(id: Id; v: var int; a, b, viewLen, hi: int) =
  ## Glides the scroller `id` just far enough that the content from `a` to
  ## `b` (pixels) is in its view, `viewLen` long: the selected row, the
  ## caret.
  let goal = scrollTarget(id, v)
  if a < goal: scrollTo(id, v, a, hi)
  elif b > goal + viewLen: scrollTo(id, v, b - viewLen, hi)

var
  wheelOwner: array[bool, uint32] ## the scroller the wheel scrolled last (sideways: [true])
  wheelAt: array[bool, int]       ## when
  wheelX, wheelY: int             ## where the pointer was

const WheelLatchMs = 400          ## notches this close together stay with one scroller

proc wheelHeld(sideways: bool): bool =
  ## (the last notch that way a moment ago, the pointer where it was)
  wheelOwner[sideways] != 0 and ui.now - wheelAt[sideways] < WheelLatchMs and
    abs(ui.mx - wheelX) <= 12 and abs(ui.my - wheelY) <= 12

proc wheelLatched*(id: Id; sideways = false): bool =
  ## Another scroller took the wheel's last notch that way a moment ago, the
  ## pointer not moved since: the notches that keep coming are its, not
  ## this one's (as a browser does).
  wheelHeld(sideways) and wheelOwner[sideways] != uint32(id)

proc noteWheel*(id: Id; sideways = false) =
  ## The scroller `id` took this notch of the wheel (see `wheelLatched`).
  wheelOwner[sideways] = uint32(id)
  wheelAt[sideways] = ui.now
  wheelX = ui.mx
  wheelY = ui.my

proc scrollWheel*(id: Id; v: var int; hi: int; area: Rect; step: int;
                  sideways = false): bool {.discardable.} =
  ## The wheel over `area` scrolls `v` (0 .. `hi`) by `step` pixels a notch,
  ## gliding. `sideways`: the horizontal scroller, which takes Shift + the
  ## wheel. Content that cannot scroll, or is at its end that way, leaves
  ## the wheel to what is around it -- a list at its bottom, the page goes
  ## on -- but notches that keep coming stay with the scroller they began
  ## in (`wheelLatched`). True when it took the wheel.
  if ui.wheel == 0 or ui.wheelUsed or hi <= 0 or not canInput() or not mouseIn(area):
    return false
  if sideways != (ShiftPressed in ui.mods): return false
  if wheelLatched(id, sideways): return false
  let goal = scrollTarget(id, v)
  let atEnd = (ui.wheel > 0 and goal <= 0) or (ui.wheel < 0 and goal >= hi)
  if atEnd and not (wheelHeld(sideways) and wheelOwner[sideways] == uint32(id)):
    return false
  ui.wheelUsed = true
  noteWheel(id, sideways)
  scrollBy(id, v, -ui.wheel * step, hi)
  true

proc noteFinger(a: var ScrollAnim; d: float) =
  if a.n == a.samples.len:
    for i in 1 ..< a.samples.len: a.samples[i - 1] = a.samples[i]
    a.n = a.samples.len - 1
  a.samples[a.n] = (ui.now, d)
  inc a.n

proc fingerSpeed(a: ScrollAnim): float =
  ## px/ms of the finger's last 100 ms (0 when it stopped before lifting).
  if a.n == 0 or ui.now - a.samples[a.n - 1].t > 60: return 0
  var sum = 0.0
  var first = ui.now
  for i in 0 ..< a.n:
    if ui.now - a.samples[i].t <= 100:
      sum += a.samples[i].d
      first = min(first, a.samples[i].t)
  sum / float(max(16, ui.now - first + 16))

proc panAxis(id: Id; v: var int; hi: int; area: Rect; d: int) =
  let k = uint32(id)
  var a = scrollAnims.getOrDefault(k)
  if d != 0:
    if a.mode != smFinger:
      a = ScrollAnim(mode: smFinger)
    v = clamp(v + d, 0, max(0, hi))
    a.pos = float(v)
    a.shown = v
    a.noteFinger(float(d))
    scrollAnims[k] = a
  elif a.mode == smFinger and (ui.released or not ui.mouseDown):
    # lifted: a flick goes on
    let s = a.fingerSpeed()
    if smoothScrolling and abs(s) > FlingMin and hi > 0:
      a.mode = smFling
      a.vel = s
      a.lastT = ui.now
      a.pos = float(v)
      a.shown = v
      scrollAnims[k] = a
      wakeIn(StepMs)
    else:
      scrollAnims.del(k)

proc scrollPan2*(idY: Id; vy: var int; hiY: int; idX: Id; vx: var int; hiX: int;
                 area: Rect): bool {.discardable.} =
  ## `scrollPan` both ways: a finger dragging over `area` moves `vy` and `vx`.
  if canInput() and ui.pressed and mouseIn(area):
    # a finger that lands on content still flying stops it (and only that)
    var caught = false
    for k in [uint32(idY), uint32(idX)]:
      if scrollAnims.hasKey(k) and scrollAnims[k].mode == smFling:
        scrollAnims.del(k)
        caught = true
    if caught and finger(): flingCaught = true
  # (the share of the gesture this one takes: `panShare`)
  let owner = uint32(if idY != 0: idY else: idX)
  let (dx, dy) = panShare(owner, area, vx, hiX, vy, hiY)
  if hiY > 0 or scrolling(idY): panAxis(idY, vy, hiY, area, dy)
  if hiX > 0 or scrolling(idX): panAxis(idX, vx, hiX, area, dx)
  dy != 0 or dx != 0

proc scrollPan*(id: Id; v: var int; hi: int; area: Rect; sideways = false): bool {.discardable.} =
  ## A finger dragging over `area` moves `v` (0 .. `hi`) with it, pixel for
  ## pixel; let go while moving, it goes on and slows down (with
  ## `smoothScrolling`). A finger landing on it while it flies stops it.
  var none = 0
  if sideways: scrollPan2(Id(0), none, 0, id, v, hi, area)
  else: scrollPan2(id, v, hi, Id(0), none, 0, area)

proc scrollTick*(id: Id; v: var int; hi: int): bool {.discardable.} =
  ## Moves the glide or fling of scroller `id` on to this frame's place;
  ## call it once a frame, after the inputs (`scrollWheel`, `scrollPan`,
  ## `scrollTo`...). A `v` changed by something else meanwhile (the thumb,
  ## the app) stops the movement. True when `v` moved.
  let k = uint32(id)
  if not scrollAnims.hasKey(k): return false
  var a = scrollAnims[k]
  let top = float(max(0, hi))
  if a.mode == smFinger:
    if not ui.mouseDown and not ui.released: scrollAnims.del(k)
    return false
  if v != a.shown:                       # set from outside: that wins
    scrollAnims.del(k)
    return false
  var done = false
  case a.mode
  of smGlide:
    a.target = clamp(a.target, 0, top)
    let t = float(ui.now - a.t0) / float(GlideMs)
    if t >= 1:
      a.pos = a.target
      done = true
    else:
      let p = 1 - pow(1 - max(0.0, t), 3)
      a.pos = a.fromPos + (a.target - a.fromPos) * p
  of smFling:
    let dt = float(max(0, ui.now - a.lastT))
    a.lastT = ui.now
    let decay = exp(-dt / FlingTau)
    a.pos += a.vel * FlingTau * (1 - decay)
    a.vel *= decay
    if a.pos <= 0 or a.pos >= top:
      a.pos = clamp(a.pos, 0, top)
      done = true
    elif abs(a.vel) < FlingMin * 0.4: done = true
  else: done = true
  let nv = int(round(clamp(a.pos, 0, top)))
  result = nv != v
  v = nv
  if done:
    scrollAnims.del(k)
    ui.redraw = true                     # (scroll bars drawn before it catch up)
  else:
    a.shown = v
    scrollAnims[k] = a
    wakeIn(StepMs)

proc toLowerAscii(c: char): char =
  if c in {'A'..'Z'}: char(ord(c) + 32) else: c

proc mnemonicOf*(label: string): char =
  ## The letter after '&' in `label`, lower case ('\0' when there is none):
  ## "&File" -> 'f'.
  var i = 0
  while i < label.len - 1:
    if label[i] == '&':
      if label[i+1] != '&': return label[i+1].toLowerAscii
      inc i
    inc i
  '\0'

proc focusNext*() =
  ## The next widget that can take the keyboard focus takes it.
  ui.focusWanted = true
  ui.redraw = true

proc focusFirstText*(inDialog = false) =
  ## The next text box drawn (that can take input) takes the keyboard
  ## focus: call it when opening a dialog that asks for a PIN, a name...
  ## so the user can type at once (on a phone the keyboard comes up).
  ## `inDialog`: the next one in a dialog -- for a dialog opened now, whose
  ## boxes come after the window's own (a palette's) in the next frame.
  ui.textFocusWanted = true
  ui.textFocusInDialog = inDialog
  ui.redraw = true

proc heldFor*(): int =
  ## How long the mouse button (or finger) has been down, in milliseconds
  ## (0 when it is up): repeat buttons, press-and-hold.
  if ui.mouseDown: ui.now - ui.pressAt else: 0

proc wantSeen*(): Rect =
  ## What a view that scrolls should bring into sight this frame (`w` 0:
  ## nothing): the control Tab moved the focus to, or one a screen reader
  ## or the driver asked to see. The kit's scroll views use it; a view of
  ## your own that scrolls its content does too.
  if ui.seeAt == ui.frameNo and ui.seeRect.w > 0: ui.seeRect
  elif ui.frameNo - ui.focusMoved == 1: ui.focusRect
  else: Rect()

proc tabStops*(): seq[Id] =
  ## The controls Tab stops at so far this frame, in the order it goes
  ## (Retro Designer numbers them on the window being designed).
  ui.tabOrder

proc focusInControls*(): bool =
  ## A control Tab stops at has the keyboard (a text box, a list, a check
  ## box): Tab goes on to the next. Else -- nothing focused, or a drawing
  ## of the app's that took the keys (a canvas clicked) -- an app may give
  ## Tab a meaning of its own: Retro Photo and Retro Board hide their
  ## panels with it.
  ui.focus != 0 and (ui.focus in ui.tabOrder or ui.focus in ui.stopsBefore)

var inBarNow* = false
  ## (in a tool bar: its controls are stops of Tab the focus does not start at)

proc tabStop*(id: Id; r: Rect; first = true): bool {.discardable.} =
  ## Makes `id` a stop of Tab: for a widget that takes the keyboard but
  ## handles its clicks itself (a tab strip, a chip row). True when it has
  ## the focus. `first` false: a stop the focus does not start at, nor
  ## `focusNext` lands on (a tool bar's buttons: Tab reaches them, but a
  ## window opens with its list or its first box focused).
  if canInput():
    ui.tabOrder.add id
    ui.stopArea.add ui.areaNow
    ui.stopIndex.add int16(ui.nextTabIndex)
    ui.nextTabIndex = 0
    if not first or inBarNow: ui.notFirst.add id
    elif ui.focusWanted:
      ui.focusWanted = false
      ui.focus = id
  result = ui.focus == id
  if result: ui.focusRect = r

proc tabIndex*(n: int) =
  ## The next control's place in the order Tab goes, as HTML's tabindex:
  ## the controls given one come first, 1 before 2, then the others in the
  ## order they are drawn. For a window laid out in one order and read in
  ## another (a form in two columns read down each); Retro Designer writes
  ## them when its Tab order's numbers are dragged.
  ##
  ## .. code-block:: nim
  ##   row:
  ##     tabIndex 1
  ##     edit first      # (Tab: first, then last, then the city)
  ##     tabIndex 3
  ##     edit city
  ##   tabIndex 2
  ##   edit last
  ui.nextTabIndex = clamp(n, 0, 30000)
  if n > 0: ui.anyTabIndex = true

proc orderStops() =
  ## (the stops given a `tabIndex` first, by it; the others after, as drawn)
  if not ui.anyTabIndex or ui.tabOrder.len < 2: return
  var keys = newSeq[(int, int)](ui.tabOrder.len)
  for i in 0 ..< ui.tabOrder.len:
    let t = if i < ui.stopIndex.len: int(ui.stopIndex[i]) else: 0
    keys[i] = ((if t > 0: t else: high(int16).int + 1), i)
  keys.sort()
  let (ids, areas, idx) = (ui.tabOrder, ui.stopArea, ui.stopIndex)
  for k, (_, i) in keys:
    ui.tabOrder[k] = ids[i]
    if i < areas.len: ui.stopArea[k] = areas[i]
    if i < idx.len: ui.stopIndex[k] = idx[i]

# ---- areas: F6 and Shift+F6 go from one to the next ---------------------------

var areaLast: Table[Id, Id]
  ## (each area's stop that had the focus last: F6 comes back to it)

proc beginArea*(key: string) =
  ## Starts an area of the window that F6 and Shift+F6 go to: its stops of
  ## Tab are one place for them (a pane, a panel, a tool bar). The kit's
  ## tool bars, split panes, docked panels and MDI windows are areas
  ## already; `area` is for a part of your own layout. F6 comes back to the
  ## control of the area that had the focus last.
  ui.areaStack.add ui.areaNow
  ui.areaNow = makeId(fnv(key, fnv("area")))

proc beginArea*(id: Id) =
  ## `beginArea` by the id of the widget it is.
  ui.areaStack.add ui.areaNow
  ui.areaNow = Id(uint32(id) xor 0x4152_4541'u32)

proc endArea*() =
  ## Ends the area `beginArea` started.
  if ui.areaStack.len > 0: ui.areaNow = ui.areaStack.pop()
  else: ui.areaNow = 0

template area*(key: string; body: untyped) =
  ## An area F6 and Shift+F6 go to (see `beginArea`).
  beginArea(key)
  body
  endArea()

proc noteMenuBar*(first: Id) =
  ## (the kit's menu bar: its first menu, which F6 opens after the last area)
  ui.menuFirst = first

# ---- accessibility: the frame as a tree for screen readers ---------------------
#
# While a screen reader listens (the driver says so: `accessListening`), every
# widget adds itself to a tree as it is drawn -- its role, its name, its value,
# where it is -- and after the frame the tree goes to the screen reader when it
# changed. What the screen reader asks (press, focus, put this text) comes
# back through `accessRequests` and is done by the next frame, as if the user
# had clicked or typed. With no screen reader nothing of this runs.

var
  accessOn*: bool
    ## The frame builds the tree: a screen reader listens, or $RETRO_ACCESS=1.
  accessTree*: seq[AccessNode]
    ## This frame's tree so far (node 0 the window). See `accessNode`.
  accessFocusAt: int = -1          # the focused node's index
  accessSentHash: uint64           # the tree the screen reader has
  accessSentFocus: int = -1
  accessOpen: seq[int32]           # the containers open (groups, menus, dialogs)
  accessLabelText: string          # a label's text: the name of the control after it
  accessLabelUsed = true
  accessNameNext: string           # a name the app gave the next control
  accessNameElse: string           # its name when no label names it (a placeholder)
  accessSee: Id                    # a control a screen reader asked to see (scrolled to)
  accessPress*: Id                 ## a press asked for: `interact` clicks it
  accessPressed*: Id               ## the widget a screen reader pressed this frame
  accessSet*: tuple[id: Id; text: string; num: float; on: bool]
    ## a value asked for: the widget `id` takes it (`accessValueFor`)
  accessForced = getEnv("RETRO_ACCESS") == "1"
  accessStarted = false
  accessKeep*: bool
    ## Build the tree every frame and keep the last whole one in
    ## `accessLast` (the inspector, the driver), with or without a reader.
  accessLast*: seq[AccessNode]
    ## The last frame's whole tree, while `accessKeep`.

proc plainName*(s: string): string =
  ## A label as it is read: no '&' of a mnemonic, no tab, one line, no
  ## icon (the kit's icons are private-use letters, which a screen reader
  ## cannot say: "Notify", not "🔔 Notify").
  result = ""         # (a value at once: see tools/writecheck.py)
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '&':
      if i + 1 < s.len and s[i + 1] == '&':
        result.add '&'
        inc i
    elif c in {'\t', '\n', '\r'}:
      if result.len > 0 and result[^1] != ' ': result.add ' '
    elif c == '\xEE' or c == '\xEF' or c == '\xF3' or c == '\xF4':
      # (U+E000..U+F8FF, and planes 15 and 16: the icons; other letters of
      # those first bytes kept)
      let r = int(s.runeAt(i))
      let n = max(1, s.runeLenAt(i))
      if r in 0xE000 .. 0xF8FF or r >= 0xF0000:
        i += n
        continue
      result.add s[i ..< i + n]
      i += n
      continue
    else: result.add c
    inc i
  result = result.strip()

proc accessible*(): bool {.inline.} = accessOn
  ## A screen reader reads this frame (widgets of your own add themselves
  ## with `accessNode` then).

proc accessName*(name: string) =
  ## The name the next control is read by -- for a button with only an icon,
  ## a box with no label before it. (Labels name the control after them on
  ## their own.)
  if accessOn: accessNameNext = name

proc accessNameOr*(name: string) =
  ## The name the next control is read by when no label before it names it
  ## (a search box by its placeholder).
  if accessOn: accessNameElse = name

proc accessLabelFor*(text: string) =
  ## A label was drawn: the next control without a name of its own is named
  ## by it (a text box after "Name:").
  if accessOn:
    let t = plainName(text)
    if t.strip.len == 0: return        # (an icon alone, a space: no name)
    accessLabelText = t
    accessLabelUsed = false

proc deviceRect(r: Rect): Rect =
  ## (a widget's place in the window's pixels, mirrored back in a
  ## right-to-left interface)
  let x = if ui.rtl: ui.w - r.x - r.w else: r.x
  rect(x * zoom, r.y * zoom, r.w * zoom, r.h * zoom)

proc accessNode*(role: AccessRole; name = ""; value = ""; states: set[AccessState] = {};
                 id: Id = ui.lastId; r: Rect = ui.lastRect; help = ""): int {.discardable.} =
  ## Adds a node to this frame's tree under the container open now (the
  ## window, a group, a menu...), and returns its index; -1 when no screen
  ## reader listens. `id`, `r`: the widget's (the last one `interact` saw).
  ## A control without a `name` takes the label drawn just before it.
  if not accessOn: return -1
  var n = AccessNode(id: uint32(id), role: role, value: value, states: states, help: help)
  if '&' in name:
    let c = mnemonicOf(name)                     # (the letter underlined)
    if c in {'a'..'z', '0'..'9'}: n.letter = c
  n.parent = if accessOpen.len > 0: accessOpen[^1] else: 0'i32
  n.name = if accessNameNext.len > 0: accessNameNext
           elif name.len > 0: plainName(name)
           elif role notin {arLabel, arGroup, arPane, arWindow, arMenuBar, arToolBar,
                            arStatusBar, arSeparator} and not accessLabelUsed and
                accessLabelText.len > 0: accessLabelText
           elif role notin {arLabel, arGroup, arPane, arWindow}: accessNameElse
           else: ""
  accessNameNext.setLen(0)
  if role notin {arLabel, arGroup, arPane, arWindow}: accessNameElse.setLen(0)
  if role != arLabel: accessLabelUsed = true
  if n.id == 0:
    # (a node of no widget -- a label, a group: named by what it is and
    # where, which stays while the layout does)
    var h = 0x811C9DC5'u32
    template mixH(v: uint32) = h = (h xor v) * 0x01000193'u32
    mixH(uint32(ord(role)))
    for c in n.name: mixH(uint32(ord(c)))
    mixH(uint32(r.x and 0xFFFF)); mixH(uint32(r.y and 0xFFFF))
    n.id = h or 0x80000000'u32
  if accessSee != 0 and n.id == uint32(accessSee):
    ui.seeRect = r                         # (the page scrolls to it: `endPage`)
    ui.seeAt = ui.frameNo
    accessSee = 0
  let d = deviceRect(r)
  n.x = d.x
  n.y = d.y
  n.w = d.w
  n.h = d.h
  if id != 0 and id == ui.focus and role notin {arGroup, arPane, arWindow}:
    n.states.incl asFocused
    accessFocusAt = accessTree.len
  # (which nodes take the focus is known at the frame's end: the ones Tab
  # stops at, `accessFrameEnd`; a menu's items and a strip's tabs, which
  # the arrows move through, by what they are)
  if asFocused in n.states or role in {arTab, arMenuItem}: n.states.incl asFocusable
  accessTree.add n
  accessTree.high

template accessOff*(enabled: bool): set[AccessState] =
  ## A node's states: `{asDisabled}` when not `enabled`.
  (if enabled: {} else: {asDisabled})

proc accessRange*(i: int; lo, hi, now: float; step = 1.0) =
  ## Node `i`'s range and value (a slider, a spin box, a progress bar).
  if i < 0 or i >= accessTree.len: return
  accessTree[i].lo = lo
  accessTree[i].hi = hi
  accessTree[i].now = now
  accessTree[i].step = step

proc accessText*(i: int; caret, selA, selB: int) =
  ## Node `i`'s caret and selection (in characters).
  if i < 0 or i >= accessTree.len: return
  accessTree[i].caret = caret
  accessTree[i].selA = selA
  accessTree[i].selB = selB

proc accessItem*(i: int; pos, count: int; level = 0) =
  ## Node `i` is item `pos` (1-based) of `count` (`level`: a tree item's depth).
  if i < 0 or i >= accessTree.len: return
  accessTree[i].pos = pos
  accessTree[i].count = count
  accessTree[i].level = level

proc accessBegin*(role: AccessRole; name = ""; r: Rect = ui.lastRect; id: Id = 0;
                  states: set[AccessState] = {}; takesLabel = false): int {.discardable.} =
  ## Opens a container node (a group, a menu, a dialog, a list...): the
  ## nodes added until `accessEnd` go inside it. `takesLabel`: named by the
  ## label before it, as a control is (a list after "Files:"). Its index.
  if not accessOn: return -1
  let saved = accessLabelUsed
  # (a group, a tool bar that takes the label: named by it as a control is)
  let nm = if name.len == 0 and takesLabel and not accessLabelUsed and accessNameNext.len == 0:
             accessLabelText
           else: name
  result = accessNode(role, nm, "", states, id, r)
  if takesLabel: accessLabelUsed = true
  else: accessLabelUsed = saved
  accessOpen.add int32(result)

proc accessFocus*(i: int) =
  ## Node `i` is the one with the keyboard focus (an item of a focused list).
  if not accessOn or i < 0 or i >= accessTree.len: return
  if accessFocusAt >= 0 and accessFocusAt < accessTree.len:
    accessTree[accessFocusAt].states.excl asFocused
  accessTree[i].states.incl {asFocused, asFocusable}
  accessFocusAt = i

proc accessSubId*(id: Id; i: int): Id =
  ## The id of part `i` of widget `id` (an item of a list, a tab, a row):
  ## the same from frame to frame.
  Id((uint32(id) xor (uint32(i + 1) * 0x9E3779B1'u32)) or 1'u32)

proc accessEnd*() =
  ## Closes the container `accessBegin` opened.
  if accessOn and accessOpen.len > 0: accessOpen.setLen(accessOpen.len - 1)

proc accessEnd*(r: Rect) =
  ## Closes the container `accessBegin` opened, now that its place `r` is
  ## known (a group's height is when its last control is drawn).
  if not accessOn or accessOpen.len == 0: return
  let i = accessOpen[^1]
  if i >= 0 and i < accessTree.len:
    let d = deviceRect(r)
    accessTree[i].x = d.x
    accessTree[i].y = d.y
    accessTree[i].w = d.w
    accessTree[i].h = d.h
  accessOpen.setLen(accessOpen.len - 1)

proc accessValueFor*(id: Id): bool =
  ## A screen reader asked widget `id` to take a value (`accessSet`): true
  ## once, for the widget to take it.
  if accessSet.on and accessSet.id == id:
    accessSet.on = false
    return true

proc accessFrameStart() =
  ## (beginFrame: the screen reader's requests done, a new tree begun)
  if not accessStarted and ui.running:
    accessStarted = true
    discard accessStart()
  accessOn = accessListening or accessForced or accessKeep
  if not accessOn: return
  # (one press and one value a frame: the rest wait for the next)
  var later: seq[AccessRequest]
  for q in accessRequests:
    let id = Id(q.id)
    case q.action
    of aaPress, aaExpand, aaCollapse:
      if accessPress != 0:
        later.add q
        continue
      accessPress = id
      ui.redraw = true
    of aaFocus:
      # (as Tab moves it: the page scrolls to the control)
      ui.focus = id
      ui.focusMoved = ui.frameNo
      ui.focusByKeys = true
      ui.redraw = true
    of aaSetValue:
      if accessSet.on:
        later.add q
        continue
      accessSet = (id, q.text, q.num, true)
      ui.redraw = true
    of aaIncrement, aaDecrement:
      ui.focus = id
      ui.key = if q.action == aaIncrement: KeyUp else: KeyDown
      ui.keyUsed = false
    of aaShowMenu:
      ui.focus = id
      ui.menuKey = true
      ui.rpressed = true
      ui.redraw = true
    of aaScrollIntoView:
      accessSee = id
      ui.redraw = true
    of aaSetCaret: discard
  accessRequests = later
  if later.len > 0: ui.redraw = true
  accessPressed = 0
  accessTree.setLen(0)
  accessOpen.setLen(0)
  accessFocusAt = -1
  accessLabelUsed = true
  accessNameNext.setLen(0)
  accessNameElse.setLen(0)
  var root = AccessNode(id: 1, parent: -1, role: arWindow, name: ui.title)
  root.w = ui.w * zoom
  root.h = ui.h * zoom
  accessTree.add root

proc accessFrameEnd() =
  ## (endFrame: the tree to the screen reader when it changed)
  if not accessOn: return
  accessOpen.setLen(0)
  # the controls Tab stops at take the focus (a tool button, a chip row of
  # buttons, an app's drawing named for readers do not)
  if ui.tabOrder.len > 0:
    let stops = toHashSet(ui.tabOrder)
    for n in accessTree.mitems:
      if Id(n.id) in stops: n.states.incl asFocusable
  var h = 0xcbf29ce484222325'u64
  template mix(v: uint64) = h = (h xor v) * 0x100000001B3'u64
  for n in accessTree:
    mix(n.id.uint64); mix(n.parent.uint64); mix(ord(n.role).uint64)
    mix(cast[uint16](n.states).uint64)
    mix(n.x.uint64); mix(n.y.uint64); mix(n.w.uint64); mix(n.h.uint64)
    mix(cast[uint64](n.now)); mix(n.caret.uint64); mix(n.selA.uint64); mix(n.selB.uint64)
    for c in n.name: mix(ord(c).uint64)
    for c in n.value: mix(ord(c).uint64)
  if accessKeep: accessLast = accessTree
  if not (accessListening or accessForced): return
  if h != accessSentHash or accessFocusAt != accessSentFocus:
    accessSentHash = h
    accessSentFocus = accessFocusAt
    accessUpdate(accessTree, accessFocusAt)

proc interact*(id: Id; r: Rect; focusable = true; enabled = true): Hit =
  ## Mouse and focus handling shared by every clickable widget.
  ui.lastId = id
  ui.lastRect = r
  if not enabled:
    if ui.active == id: ui.active = 0
    return
  if accessPress != 0 and accessPress == id:
    # (a screen reader pressed it)
    accessPress = 0
    accessPressed = id
    if focusable: ui.focus = id
    result.focused = focusable
    result.clicked = true
    return
  if focusable and canInput():
    ui.tabOrder.add id
    ui.stopArea.add ui.areaNow
    ui.stopIndex.add int16(ui.nextTabIndex)
    ui.nextTabIndex = 0
    if inBarNow: ui.notFirst.add id
    elif ui.focusWanted:
      ui.focusWanted = false
      ui.focus = id
  if id == ui.focus and canInput(): ui.focusSeen = true
  result.focused = ui.focus == id
  if result.focused: ui.focusRect = r
  let over = hover(r)
  if over:
    ui.hot = id
    if takePress():
      ui.active = id
      ui.spaceDown = false
      if focusable:
        ui.focus = id
        ui.focusByKeys = false
        result.focused = true
  if ui.active == id and not ui.spaceDown:
    if ui.released:
      result.clicked = over
      ui.active = 0
    else:
      result.down = over and ui.mouseDown
  result.hover = over

# ---- drag and drop ------------------------------------------------------------

var
  outPaths: seq[string]        # the files of the drag in progress, for other programs
  outMade: bool                # ... made already (`DragInfo.files` asked)

proc startDrag*(kind: string; items: openArray[string]; label = ""; glyph = "";
                files: proc (): seq[string] = nil; moveFiles = false) =
  ## Starts dragging `items` (paths, ids...) of `kind`, while the mouse is
  ## down -- typically when a list reports `dragStarted`. Targets see it
  ## with `dropTarget`; letting go over none (or Esc) drops nothing.
  ##
  ## `files`: what it is for other programs, as files on disk -- messages as
  ## .eml files, pictures as PNGs, a file manager's own paths. Made only if
  ## the drag leaves the window, which then becomes the system's drag of
  ## them, to a file manager, a browser, a mail (`dragFilesOut`); brought
  ## back over the window, it is this drag again. `moveFiles`: they may be
  ## moved there instead of copied.
  ui.drag = DragInfo(active: true, kind: kind, items: @items,
                     label: if label.len > 0: label
                            elif items.len == 1: items[0] else: $items.len & " items",
                     glyph: glyph, source: ui.active, files: files,
                     moveFiles: moveFiles)
  outPaths.setLen(0)
  outMade = false
  ui.dragDropping = false
  ui.dragClaimed = false
  ui.active = 0
  ui.dragsActive = true
  ui.redraw = true

proc lifted*(): bool = ui.lift
  ## A finger held still on something, then moved, this frame: on a touch
  ## screen this starts a drag (the mouse just drags).

proc dragging*(kind = ""): bool =
  ## Something (of `kind`, "" any) is being dragged.
  ui.drag.active and (kind.len == 0 or ui.drag.kind == kind)

proc dragCopies*(): bool = CtrlPressed in ui.mods
  ## The drag copies instead of moving (Ctrl is held).

proc cancelDrag*() =
  ## Ends the drag in progress without dropping it anywhere.
  ui.drag = DragInfo()
  ui.redraw = true

# ---- files dropped from the system's file manager ----------------------------

var
  dropFiles: seq[string]       # the files dropped on the window this frame
  dropAt: Point                # ... where
  globalHits*: seq[int]        ## (the shortcuts from the whole desktop pressed
                               ## this frame: `globalHotkey`)

proc droppedFiles*(): seq[string] = dropFiles
  ## The files dropped on the window this frame from the system's file
  ## manager (Explorer, Finder, Nautilus...): their paths. Empty in every
  ## other frame.

proc dropPoint*(): Point = dropAt
  ## Where this frame's files were dropped (logical pixels, as `ui.mx`).

proc fileDropTarget*(r: Rect): seq[string] =
  ## The files dropped this frame inside `r` where nothing covers it (a
  ## dialog, a menu, another window): a place to drop attachments,
  ## pictures, documents. Empty in every other frame.
  if dropFiles.len == 0: return
  let p = dropAt
  if r.contains(p) and clipRect().contains(p) and canInput() and
     (ui.blockers.len == 0 or layer() > 0 or not blocked(p)):
    result = dropFiles

proc dropTarget*(r: Rect; kind = ""; enabled = true): DropState =
  ## Whether a drag of `kind` is over `r` (draw `r` highlighted) or was
  ## dropped on it this frame (take `ui.drag.items`). Only the first target
  ## under the pointer takes a drop.
  if not enabled or not dragging(kind) or ui.dragClaimed or not canInput(): return dsNone
  if not (r.contains(point(ui.mx, ui.my)) and clipRect().contains(point(ui.mx, ui.my))):
    return dsNone
  ui.dragOver = true
  if ui.dragDropping:
    ui.dragClaimed = true
    ui.redraw = true
    return dsDropped
  wakeIn(50)
  dsOver

proc dropHighlight*(r: Rect) =
  ## The look of a target a drag is over.
  box(r, ui.theme.select)
  box(inset(r, 1), ui.theme.select)

# ---- files dragged out of the window, to other programs ----------------------
#
# The system's drag runs while the button is down and returns when it is let
# go (the app's frame waits meanwhile; the window shows what it showed). Its
# release is reported afterwards, so the press clicks nothing.

var
  outArm: tuple[on: bool; r: Rect; x, y: int]   # a press in a `fileDragSource`
  outResult: DragOutResult     # how the last drag of files out ended

proc lastDragOut*(): DragOutResult = outResult
  ## How the last drag of files out of the window ended: `drCopied` or
  ## `drMoved` (another program took them), `drCancelled`, `drBack` (it came
  ## back into the window as the app's own drag), `drNone`.

proc systemDrag(paths: seq[string]; move, back: bool): DragOutResult =
  ## (the system's drag of `paths`, the press ended: what it began is no click)
  outArm.on = false
  ui.active = 0
  result = startFileDragOut(paths, move, back)
  outResult = result
  ui.redraw = true

proc dragFilesOut*(paths: seq[string]; move = false): bool {.discardable.} =
  ## Drags the files `paths` out of the window now, while the left button is
  ## down: to the system's file manager, a browser's upload box, a mail being
  ## written... The system's drag goes on until the button is let go (or
  ## Esc), and this returns then: true when another program took them
  ## (`lastDragOut` says whether it copied or moved them). The press is over:
  ## what it began clicks nothing; a drag of the toolkit's in progress ends.
  ## False with no paths, the button up, a finger's press, or where the
  ## platform cannot (`canDragFilesOut`: Windows, X11 and macOS can).
  if paths.len == 0 or not ui.mouseDown or ui.fingerDown or not canDragFilesOut():
    outResult = drNone
    return false
  if ui.drag.active: cancelDrag()
  systemDrag(paths, move, false) in {drCopied, drMoved}

proc fileDragSource*(r: Rect; paths: proc (): seq[string]; move = false): bool {.discardable.} =
  ## Makes `r` (an attachment, a file's icon) something to drag files out of
  ## the window from: a press inside it that moves a few pixels with the
  ## button down begins the system's drag of the files `paths` gives -- made
  ## only then (an attachment written to a temporary file). That press
  ## clicks nothing. True in the frame another program took them
  ## (`lastDragOut`: copied or moved). Nothing for a finger on a touch
  ## screen, or where the platform cannot (`canDragFilesOut`); call it every
  ## frame, after drawing what is in `r` (`ui.lastRect`).
  if not canDragFilesOut() or ui.fingerDown: return false
  if ui.pressed:
    if hover(r): outArm = (true, r, ui.mx, ui.my)
    return false
  if not outArm.on or outArm.r != r: return false
  if not ui.mouseDown or ui.released or ui.drag.active:
    outArm.on = false
    return false
  let d = max(3, dp(4))
  if abs(ui.mx - outArm.x) < d and abs(ui.my - outArm.y) < d: return false
  outArm.on = false
  let ps = paths()
  if ps.len == 0: return false
  dragFilesOut(ps, move)

proc dragLeftWindow() =
  ## (a drag of the toolkit's left the window with files for other
  ## programs: the system's drag of them from here; back over the window,
  ## the toolkit's goes on)
  if not outMade:
    outMade = true
    outPaths = ui.drag.files()
  if outPaths.len == 0:
    ui.drag.files = nil               # (none to give: it stays in the window)
    return
  case systemDrag(outPaths, ui.drag.moveFiles, true)
  of drBack: discard
  of drNone: ui.drag.files = nil      # (cannot: not tried again)
  else: cancelDrag()                  # taken by another program, or not

# ---- layout -----------------------------------------------------------------

proc top(): ptr LFrame {.inline.} = addr ui.frames[^1]

proc newline(f: ptr LFrame) =
  f.cx = f.x
  f.cy += f.lineH + Gap
  f.lineH = 0
  inc f.lineNo

var clippedDepth = 0
  ## Inside panes, panels and windows that clip their content: what they
  ## hold does not widen the window's page.

type LayoutMark* = object
  ## Where the layout was (`layoutMark`): what `layoutRestore` goes back to
  ## when drawing stopped half way.
  frames, clipped: int
  draw: DrawMark

proc layoutMark*(): LayoutMark =
  ## Where layout and drawing are now: `layoutRestore` goes back to it (a
  ## panel that failed half way leaves no open rows or clips behind).
  LayoutMark(frames: ui.frames.len, clipped: clippedDepth, draw: drawMark())

proc layoutRestore*(m: LayoutMark) =
  ## The frames, clips and layers begun since `m` let go (after a fault in
  ## what drew them).
  if ui.frames.len > m.frames: ui.frames.setLen(m.frames)
  clippedDepth = m.clipped
  drawRestore(m.draw)

# ---- faults --------------------------------------------------------------------------------------------

var faultPath = ""     ## (where faults are written: the app's data folder)
var faultFile: array[1024, char]
  ## (the same, where nothing frees it: a fault at the very end -- a signal
  ## while the program ends, its strings gone -- still finds the file,
  ## not a name made of what that memory holds by then)

proc setFaultPath(p: string) =
  faultPath = p
  faultFile[0] = '\0'
  if p.len < faultFile.len:
    for i in 0 ..< p.len: faultFile[i] = p[i]
    faultFile[p.len] = '\0'

when defined(posix) and not defined(wasm):
  # (what a signal handler may call: open, write, close)
  var
    oWrOnly {.importc: "O_WRONLY", header: "<fcntl.h>".}: cint
    oCreat {.importc: "O_CREAT", header: "<fcntl.h>".}: cint
    oAppend {.importc: "O_APPEND", header: "<fcntl.h>".}: cint
  proc cOpen(path: cstring; flags: cint): cint {.importc: "open", header: "<fcntl.h>", varargs.}
  proc cWrite(fd: cint; buf: pointer; n: csize_t): int {.importc: "write", header: "<unistd.h>".}
  proc cClose(fd: cint): cint {.importc: "close", header: "<unistd.h>".}

when androidApp:
  # (a crash of the native code written down too: Nim's own signal handler
  # is left out on Android, where the runtime uses the signals itself)
  {.compile: "crashlog.c".}
  proc retroCrashLog(path: cstring) {.importc: "retro_crash_log", cdecl.}

# ---- a stop right after the start ------------------------------------------------------------------
#
# A file in the app's data folder says it is starting ("start"; "again"
# after the "stopped" screen's Start); it goes once the app has run 20
# seconds or ended well. Found at the next start beside a fault: the app
# stopped within seconds -- "again": in a loop, what it brings back at its
# start the likely cause (desktop's "stopped" screen leaves it out then).

var
  startMark = ""               ## (the file)
  startMarkAt = -1             ## (when it was written, ui's time; -1: not counted yet)
  prevStartMark = ""           ## (what the last run's said, read at this start)

proc markStarting*(how = "start") =
  ## Writes that the app is starting (`how`: "start", or "again" after the
  ## "stopped" screen's Start); it goes after 20 seconds running.
  if startMark.len == 0: return
  try:
    createDir(startMark.parentDir)
    writeFile(startMark, how)
    startMarkAt = -1
  except IOError, OSError: discard

proc lastStartMark*(): string =
  ## What the last run's start left ("start", "again") when it stopped
  ## within 20 seconds of it; "" when it ran longer or ended well.
  prevStartMark

proc startMarkFrame() =
  ## (each frame: 20 seconds after the start, the mark goes)
  if startMark.len == 0: return
  if startMarkAt < 0: startMarkAt = ui.now
  elif ui.now - startMarkAt > 20_000:
    try: removeFile(startMark)
    except OSError: discard
    startMark = ""

proc writeFault(msg: string) {.tags: [WriteIOEffect], gcsafe, nimcall, raises: [].} =
  {.cast(gcsafe).}:
    try: stderr.write msg
    except CatchableError: discard
    if faultFile[0] != '\0':
      when defined(posix) and not defined(wasm):
        let fd = cOpen(cast[cstring](addr faultFile[0]), oWrOnly or oCreat or oAppend, cint(0o600))
        if fd >= 0:
          if msg.len > 0: discard cWrite(fd, unsafeAddr msg[0], csize_t(msg.len))
          discard cClose(fd)
      else:
        try:
          var f: File
          if open(f, $cast[cstring](addr faultFile[0]), fmAppend):
            f.write(msg)
            f.close()
        except CatchableError: discard

var lastNoted = ""

proc noteFault*(where, msg: string) =
  ## A fault written to the app's fault log (`takeFaults` reads it at the
  ## next start): `where` it came, what it said (the same one again, each
  ## frame: once).
  let m = "--- " & where & "\n" & msg & "\n"
  if m == lastNoted: return
  lastNoted = m
  writeFault(m)

proc peekFaults*(): string =
  ## What the fault log holds, left there ("" when nothing).
  if faultPath.len == 0 or not fileExists(faultPath): return ""
  try: result = readFile(faultPath)
  except CatchableError: discard

proc lastRunStopped*(): bool =
  ## The last run ended in a crash (an error nothing caught, a fault of the
  ## native code, Java's on Android): its report is in the fault log.
  let f = peekFaults()
  "unhandled exception" in f or "--- the app stopped" in f

proc takeFaults*(): string =
  ## What went wrong since the faults were last taken (the last run's end
  ## too, when the program stopped): "" when nothing. The log is emptied.
  result = ""         # (a value at once: see tools/writecheck.py)
  if faultPath.len == 0 or not fileExists(faultPath): return
  try:
    result = readFile(faultPath)
    removeFile(faultPath)
  except CatchableError: discard
  if result.len > 4000: result = "..." & result[^4000 .. ^1]

template guarded*(where: string; body: untyped) =
  ## `body`, and when it fails (an error, a fault of the program), the
  ## layout put back as it was, the fault logged -- the program goes on.
  ## True in `faulted` when it failed.
  let mark {.gensym.} = layoutMark()
  try:
    body
  except Exception as e:
    if e.name == "BusyCancelled": raise        # (Cancel in the busy box: not a fault)
    layoutRestore(mark)
    noteFault(where, e.msg & "\n" & e.getStackTrace())
    ui.lastFault = where & ": " & e.msg
    ui.redraw = true

proc beginClipped*() =
  ## Content from here to `endClipped` is clipped by its container (a
  ## split pane, a scroll panel, an MDI window): it never makes the window
  ## scroll sideways.
  inc clippedDepth

proc endClipped*() =
  ## Ends a `beginClipped`.
  if clippedDepth > 0: dec clippedDepth

proc beginCell*(w: int; fill = false): Rect =
  ## Reserve the next layout cell; its height is given later to `endCell`.
  let f = top()
  case f.kind
  of lkCol, lkGroup:
    let ww = if fill or w <= 0 or w > f.w: f.w else: w
    result = rect(f.x, f.cy, ww, 0)
  of lkRow:
    var ww = if w <= 0: 80 else: w
    if f.nw > 0:
      if f.idx > 0 and f.idx mod f.nw == 0: newline(f)
      let spec = f.widths[f.idx mod f.nw]
      if spec > 0: ww = spec
      elif f.idx < f.nw: f.zeroNow += ww
    elif fill:
      ww = max(20, f.x + f.w - f.cx)
    if f.springX >= 0:
      f.tailNow += ww + Gap            # after a spring: measured, not wrapped
    elif f.nw == 0 and f.cx > f.x and f.cx + ww > f.x + f.w: newline(f)
    result = rect(f.cx, f.cy, ww, 0)
    # a row of fixed widths wider than the window: the page scrolls sideways
    if layer() == 0 and not f.fixed and clippedDepth == 0 and
       f.cx + ww + ui.pageX > ui.contentRight:
      ui.contentRight = f.cx + ww + ui.pageX
    f.cx += ww + Gap
    inc f.idx

proc notePlaced*(r: Rect) =
  ## While `ui.measuring`: `r` added to `ui.placed` (what was drawn where:
  ## the cells, and the bars, menus and dialogs that are not cells).
  if not ui.measuring or r.w <= 0 or r.h <= 0: return
  if ui.placed.w == 0: ui.placed = r
  else:
    let x0 = min(ui.placed.x, r.x)
    let y0 = min(ui.placed.y, r.y)
    ui.placed = rect(x0, y0, max(ui.placed.x + ui.placed.w, r.x + r.w) - x0,
                     max(ui.placed.y + ui.placed.h, r.y + r.h) - y0)

proc endCell*(r: Rect; h: int; natural = -1) =
  ## Finish a cell `h` pixels high; `natural` is the height its content
  ## needs when that is less (groups grow to the height of their row).
  if ui.measuring: notePlaced(rect(r.x, r.y, max(1, r.w), max(1, h)))
  let f = top()
  case f.kind
  of lkCol, lkGroup:
    f.cy = r.y + h + Gap
    f.bottom = max(f.bottom, r.y + h)
  of lkRow:
    f.lineH = max(f.lineH, h)
    f.bottom = max(f.bottom, f.cy + f.lineH)
    f.natMax = max(f.natMax, if natural >= 0: natural else: h)
    let ln = min(f.lineNo, f.lineNat.high)
    f.lineNat[ln] = max(f.lineNat[ln], int32(if natural >= 0: natural else: h))

proc place*(w, h: int; fill = false): Rect =
  ## A cell for a leaf widget of natural size `w` x `h`. In a row, widgets
  ## lower than the row height are centered on it.
  result = beginCell(w, fill)
  result.h = h
  let f = top()
  if f.kind == lkRow and h < f.rowH:
    result.y += (f.rowH - h) div 2
    endCell(result, f.rowH)
  else:
    endCell(result, h)

proc cellRoom*(): int =
  ## The widest the next cell can be: a fixed width of the row it is in,
  ## else the whole width of the row or column (text wraps to it).
  if ui.frames.len == 0: return max(10, ui.w - ui.safe.left - ui.safe.right - 2 * Pad)
  let f = top()
  if f.kind == lkRow and f.nw > 0:
    let spec = f.widths[f.idx mod f.nw]
    if spec > 0: return spec
  f.w

proc available*(): int =
  ## Width left in the current line.
  if ui.frames.len == 0: return max(10, ui.w - ui.safe.left - ui.safe.right - 2 * Pad)
  let f = top()
  if f.kind == lkRow: f.x + f.w - f.cx else: f.w

proc remainingH*(): int =
  ## Height left in the current pane, or above the status bar (less the
  ## borders of the groups, tabs and cards around).
  var below = 0
  for i in countdown(ui.frames.high, 0):
    let f = addr ui.frames[i]
    if f.limitY > 0: return max(20, f.limitY - below - top().cy)
    below += f.reserve
  # (the status bar may come before the content or after it: then the
  # last frame's says where it is)
  max(ItemH * 4 + 2, min(ui.prevBottom, ui.bottom) - Pad - below - top().cy - top().dy)

type SizeClass* = enum
  ## How much room the window has, in design pixels of width (the classes
  ## Android and the web use): phones, tablets and small windows, desktops.
  scCompact,      ## under 600: one column, stacked
  scMedium,       ## 600 to 1023: two columns, side panels may fold
  scExpanded      ## 1024 and more: everything side by side

proc sizeClass*(): SizeClass =
  ## How much room the window has: phone, tablet, desktop.
  let w = float(ui.w) / max(0.1, ui.k)
  if w < 600: scCompact elif w < 1024: scMedium else: scExpanded

proc isCompact*(): bool = sizeClass() == scCompact
  ## A phone in portrait, or a narrow window.

proc responsive*[T](compact, medium, expanded: T): T =
  ## The value for the window's size class.
  case sizeClass()
  of scCompact: compact
  of scMedium: medium
  of scExpanded: expanded

proc columnsFor*(minW: int; maxCols = 6): int =
  ## How many columns at least `minW` design pixels wide fit in the space
  ## the layout is at.
  clamp((available() + Gap) div max(1, dp(minW) + Gap), 1, maxCols)

proc space*(px = Gap) =
  ## Empty space: down in a column, right in a row.
  let f = top()
  if f.kind == lkRow: f.cx += px else: f.cy += px

proc beginRowPx*(widths: openArray[int] = []; rowH = CtrlH; scaled = false) =
  ## `beginRow` with fixed widths in logical pixels (not scaled).
  let cell = beginCell(0, fill = true)
  var f = LFrame(kind: lkRow, x: cell.x, y: cell.y, w: cell.w, dy: top().dy,
                 cx: cell.x, cy: cell.y, rowH: rowH, bottom: cell.y,
                 id: makeId(0x526f77'u32), springX: -1)
  let st = addr state(f.id)
  f.prevH = st.aux
  f.prevN = min(st.lines.len, f.prevLines.len)
  for i in 0 ..< f.prevN: f.prevLines[i] = st.lines[i]
  f.tailPrev = st.aux2
  f.nw = min(widths.len, f.widths.len)
  var fixed = 0
  var shares = 0
  for i in 0 ..< f.nw:
    if widths[i] > 0: fixed += (if scaled: dp(widths[i]) else: widths[i])
    elif widths[i] < 0: shares += -widths[i]
  # (the widgets of their own width: as wide as last frame)
  let room = max(0, cell.w - fixed - Gap * (f.nw - 1) - st.caret)
  var given = 0
  var left = shares
  for i in 0 ..< f.nw:
    f.widths[i] =
      if widths[i] > 0: (if scaled: dp(widths[i]) else: widths[i])
      elif widths[i] < 0:
        # the last share takes what rounding left over
        let w = if left == -widths[i]: room - given
                else: room * -widths[i] div max(1, shares)
        given += w
        left -= -widths[i]
        max(20, w)
      else: 0
  ui.frames.add f

proc beginRow*(widths: openArray[int] = []; rowH = CtrlH) =
  ## Widgets side by side. `widths`: > 0 a fixed width (in design pixels,
  ## scaled like everything else), 0 the widget's own width, -n a share of
  ## the room left (-1 and -2: one third and two thirds). More widgets
  ## than widths wrap to new lines.
  beginRowPx(widths, rowH, scaled = true)

proc spring*() =
  ## In a row: the widgets after it go to the row's right end.
  let f = top()
  if f.kind != lkRow: return
  f.cx = max(f.cx, f.x + f.w - f.tailPrev)
  f.springX = f.cx

proc endRow*() =
  ## Ends a `beginRow`.
  let f = ui.frames.pop()
  if f.id != 0:
    if f.natMax != f.prevH:
      state(f.id).aux = f.natMax
      ui.redraw = true
    let n = min(f.lineNo + 1, f.lineNat.len)
    var same = f.prevN == n
    if same:
      for i in 0 ..< n:
        if f.prevLines[i] != f.lineNat[i]:
          same = false
          break
    if not same:
      let st = addr state(f.id)
      st.lines.setLen(n)
      for i in 0 ..< n: st.lines[i] = f.lineNat[i]
      ui.redraw = true
    let tail = if f.springX >= 0: max(0, f.tailNow - Gap) else: 0
    if tail != f.tailPrev:
      state(f.id).aux2 = tail
      ui.redraw = true
    if f.zeroNow != state(f.id).caret:
      state(f.id).caret = f.zeroNow
      ui.redraw = true
  endCell(rect(f.x, f.y, f.w, 0), max(f.bottom, f.cy + f.lineH) - f.y)

proc beginCol*(w = 0) =
  ## A column `w` design pixels wide (0: all the room there is).
  let cell = beginCell(dp(w), fill = w <= 0)
  ui.frames.add LFrame(kind: lkCol, x: cell.x, y: cell.y, w: cell.w, dy: top().dy,
                       cx: cell.x, cy: cell.y, bottom: cell.y)

proc endCol*() =
  ## Ends a `beginCol`.
  let f = ui.frames.pop()
  endCell(rect(f.x, f.y, f.w, 0), f.bottom - f.y)

template row*(body: untyped) =
  ## Widgets side by side, each at its natural width (wrapping when full).
  beginRow()
  body
  endRow()

template row*(widths: openArray[int]; body: untyped) =
  ## Widgets side by side in columns: a width > 0 is fixed, -1 shares the
  ## rest, 0 is the widget's own width. More widgets than widths wrap.
  ## The widths are design pixels, scaled as everything is: write
  ## `row([80, -1])`, not `row([dp(80), -1])` (that scales twice: the
  ## columns too wide on a tablet or a phone); widths measured on the
  ## screen (a text's width) go to `rowPx`.
  beginRow(widths)
  body
  endRow()

template rowPx*(widths: openArray[int]; body: untyped) =
  ## `row` with widths in logical pixels, as they are (measured on the
  ## screen: `textWidth`, `dp`): not scaled again.
  beginRowPx(widths)
  body
  endRow()

template col*(body: untyped) =
  ## Widgets stacked top to bottom (a column inside a row).
  beginCol()
  body
  endCol()

template col*(width: int; body: untyped) =
  ## A column `width` design pixels wide.
  beginCol(width)
  body
  endCol()

template adaptive*(minW: int; body: untyped) =
  ## As many equal columns as fit, each at least `minW` design pixels
  ## wide; the widgets (groups, cards) of `body` flow through them and wrap.
  ## One column on a phone, three on a desktop -- with the same code.
  block:
    let n = columnsFor(minW)
    var ws: array[16, int]
    for i in 0 ..< n: ws[i] = -1
    beginRow(ws.toOpenArray(0, n - 1))
    body
    endRow()

proc rowHeight*(): int =
  ## In a row: the height the tallest cell of the current line needed last
  ## frame (for panels that grow to line up with their neighbours), else 0.
  ## Call it right after `beginCell`.
  if ui.frames.len == 0 or top().kind != lkRow: return 0
  let f = top()
  if f.lineNo < f.prevN: int(f.prevLines[f.lineNo]) else: f.prevH

proc beginGroup*(title: string) =
  ## Starts a group box (see `group`).
  let cell = beginCell(0, fill = true)
  if accessOn: accessBegin(arGroup, title, rect(cell.x, cell.y, cell.w, FontH))
  let minH = rowHeight()
  ui.frames.add LFrame(kind: lkGroup, x: cell.x + 10, y: cell.y, dy: top().dy,
                       w: max(10, cell.w - 20), cx: cell.x + 10,
                       cy: cell.y + FontH + 6, bottom: cell.y + FontH + 2,
                       title: title, prevH: minH, reserve: 9,
                       widths: [cell.x, cell.w, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0])

proc pushRow*(r: Rect; rowH = CtrlH) =
  ## A row at an explicit rectangle (tool bars).
  ui.frames.add LFrame(kind: lkRow, x: r.x, y: r.y, w: r.w, cx: r.x,
                       cy: r.y, rowH: rowH, bottom: r.y, fixed: true)

proc barsBottom*(): int =
  ## Where the bars at the top of the window (caption, menu, tool bar) end:
  ## the window's content starts a margin under it.
  ui.contentTop - Pad

proc shiftContent*(dy: int) =
  ## Move the window's content down (a bar was added on top).
  ui.frames[0].cy += dy
  ui.frames[0].bottom += dy
  ui.contentTop += dy

proc pushFrame*(r: Rect; reserve = 0; inPage = false) =
  ## A column at an explicit rectangle (dialogs, popups, panes). A height
  ## (`r.h` > 0) is what `remainingH` hands out inside it. Panels drawn in
  ## the window's content (tabs, cards) pass `inPage`, and `reserve`: the
  ## room their border needs below what is inside.
  let dy = if inPage and ui.frames.len > 0: top().dy else: 0
  ui.frames.add LFrame(kind: lkCol, x: r.x, y: r.y, w: r.w, cx: r.x,
                       cy: r.y, bottom: r.y, dy: dy, reserve: reserve,
                       limitY: if r.h > 0: r.y + r.h else: 0)

proc popFrame*(): int =
  ## Pops a `pushFrame` column and returns the height its content used.
  let f = ui.frames.pop()
  f.bottom - f.y

proc frameBottom*(): int = top().bottom
  ## The lowest point the current column or row has reached.

proc layoutY*(): int = top().cy
  ## Where the current column's next cell starts (in a row: its line's top).

proc layoutWidth*(): int = top().w
  ## The current column's (or row's) width.

proc inColumn*(): bool = ui.frames.len > 0 and top().kind != lkRow
  ## The cells go down (a column, a panel, a group), not across a row.

proc skipDown*(px: int) =
  ## The current column goes down `px` as if cells `px` high were there,
  ## the gap after the last one counted (its bottom too, so a panel's
  ## scroll bar counts them): the room of rows not drawn (`visibleRows`).
  if px <= 0 or ui.frames.len == 0: return
  let f = top()
  if f.kind == lkRow: return
  f.cy += px
  f.bottom = max(f.bottom, f.cy - Gap)

# ---- a window in the window, controls without input --------------------------------------------

type WindowBoxState* = object
  ## What `beginWindowBox` put aside (for `endWindowBox`).
  w, h, bottom, prevBottom, barY, contentTop, contentRight, winX, winY: int
  safe: tuple[top, left, bottom, right: int]
  frames: seq[LFrame]
  screen: Rect

var boxFrames: seq[LFrame]       # (the box's columns: kept, so a box takes no memory)

proc beginWindowBox*(r: Rect): WindowBoxState =
  ## Starts laying out a window of its own at `r` (see `windowBox`).
  result = WindowBoxState(w: ui.w, h: ui.h, bottom: ui.bottom, prevBottom: ui.prevBottom,
                          barY: ui.barY, contentTop: ui.contentTop,
                          contentRight: ui.contentRight, winX: ui.winX, winY: ui.winY,
                          safe: ui.safe,
                          screen: screenClip())
  swap(result.frames, ui.frames)
  swap(ui.frames, boxFrames)
  ui.frames.setLen(0)
  ui.winX = r.x
  ui.winY = r.y
  ui.w = r.w
  ui.h = r.y + r.h
  ui.bottom = r.y + r.h
  ui.prevBottom = ui.bottom
  ui.barY = r.y
  ui.safe = (0, 0, 0, 0)
  let topY = r.y + Pad
  ui.contentTop = topY
  ui.contentRight = 0
  ui.frames.add LFrame(kind: lkCol, x: r.x + Pad, y: topY, w: max(10, r.w - 2 * Pad),
                       cx: r.x + Pad, cy: topY, bottom: topY)
  pushClip(r)
  setScreenClip(clipRect())      # (its pop-ups and bars stay in the box)

proc endWindowBox*(s: var WindowBoxState) =
  ## Ends a `beginWindowBox`: the window's own layout back.
  setScreenClip(s.screen)
  popClip()
  swap(ui.frames, boxFrames)
  swap(ui.frames, s.frames)
  ui.w = s.w
  ui.h = s.h
  ui.bottom = s.bottom
  ui.prevBottom = s.prevBottom
  ui.barY = s.barY
  ui.contentTop = s.contentTop
  ui.contentRight = s.contentRight
  ui.winX = s.winX
  ui.winY = s.winY
  ui.safe = s.safe

template windowBox*(r: Rect; body: untyped) =
  ## `body` laid out as a window of its own at `r`, inside this one: its
  ## menu bar, tool bars and status bar along `r`'s edges, its content in
  ## between, and `isCompact` and the size classes asking `r`'s width -- a
  ## preview of a window (a designer's form, a guide's picture). Pair it with
  ## `inert` when its controls should not take input.
  block:
    var wbState = beginWindowBox(r)
    try:
      body
    finally:
      endWindowBox(wbState)

type InertState* = object
  ## What `beginInert` put aside (for `endInert`).
  key: KeyCode
  mnemonic: char
  altTapped, keyUsed, byBackNow: bool
  typed: string
  dialogTopNow: Id
  popupRectNow, popupRect2Now, overlayNow: Rect
  overlayLayerNow: int

proc beginInert*(): InertState =
  ## Starts drawing without input (see `inert`).
  result = InertState(key: ui.key, mnemonic: ui.mnemonic, altTapped: ui.altTapped,
                      keyUsed: ui.keyUsed, byBackNow: ui.byBackNow,
                      dialogTopNow: ui.dialogTopNow, popupRectNow: ui.popupRectNow,
                      popupRect2Now: ui.popupRect2Now, overlayNow: ui.overlayNow,
                      overlayLayerNow: ui.overlayLayerNow)
  inc ui.inertDepth
  ui.key = KeyNone
  ui.mnemonic = '\0'
  ui.altTapped = false
  ui.keyUsed = true
  swap(result.typed, ui.typed)         # (what was typed put aside, not copied)

proc endInert*(s: var InertState) =
  ## Ends a `beginInert`: the keys back; what was drawn claimed nothing (a
  ## dialog in it is not the window's dialog, a menu not its menu).
  dec ui.inertDepth
  ui.key = s.key
  ui.mnemonic = s.mnemonic
  ui.altTapped = s.altTapped
  ui.keyUsed = s.keyUsed
  swap(ui.typed, s.typed)
  ui.byBackNow = s.byBackNow
  ui.dialogTopNow = s.dialogTopNow
  ui.popupRectNow = s.popupRectNow
  ui.popupRect2Now = s.popupRect2Now
  ui.overlayNow = s.overlayNow
  ui.overlayLayerNow = s.overlayLayerNow

template inert*(body: untyped) =
  ## `body` drawn without input: its controls are shown as they are but the
  ## mouse, fingers and keys do not reach them, and a dialog or menu in it
  ## does not take the window's input (a preview, a designer's form).
  block:
    var inertState = beginInert()
    try:
      body
    finally:
      endInert(inertState)



proc groupEnd*(): tuple[cell: Rect, title: string] =
  ## Ends a `beginGroup`: where the group box goes and its title (for
  ## `endGroup`, which draws it).
  let f = ui.frames.pop()
  let x = f.widths[0]
  let w = f.widths[1]
  let natural = f.bottom - f.y + 9
  let h = max(natural, f.prevH)
  result = (rect(x, f.y, w, h), f.title)
  endCell(result.cell, h, natural)

# ---- drawing helpers shared by widgets ---------------------------------------

var
  uiStrings: Table[string, string]   # (the words on screen in another language: `setUiLanguage`)
  uiLanguage = ""
  uiPseudo = false                   # (every text stretched and marked: "pseudo")

const pseudoLetters = [
  "\u00e5", "b", "\u00e7", "\u00f0", "\u00e9", "f", "\u011d", "\u0125", "\u00ee",
  "\u0135", "\u0137", "\u013c", "m", "\u00f1", "\u00f6", "\u00fe", "q", "\u0155",
  "\u0161", "\u0163", "\u00fb", "v", "\u0175", "x", "\u00fd", "\u017e"]
  ## (a..z, most with a mark on them: Latin-1's and Latin Extended-A's,
  ## which the interface's fonts have)

proc pseudoText*(s: string): string =
  ## `s` as the pseudo language shows it: its letters marked, a third
  ## longer, in brackets ("Save" -> "[Šåvé ··]"): a
  ## translation longer than English, and words left out of `tr`, found by
  ## looking. The "&" of a mnemonic stays before its letter.
  if s.len == 0 or (s[0] == '[' and s.endsWith("\u00b7]")): return s   # (made so already)
  result = "["
  var letters = 0
  for c in s:
    case c
    of 'a'..'z':
      result.add pseudoLetters[ord(c) - ord('a')]
      inc letters
    of 'A'..'Z':
      result.add pseudoLetters[ord(c) - ord('A')].toUpper
      inc letters
    else: result.add c
  if letters > 0:
    result.add ' '
    for _ in 0 ..< max(1, (letters + 2) div 3): result.add "\u00b7"
  result.add ']'

proc setUiLanguage*(lang: string; tables: varargs[seq[(string, string)]]) =
  ## The interface in another language: each label, button, menu, tab,
  ## title shown is looked up in `tables` (the English text, "&" taken out,
  ## and what it is in that language); right to left -- mirrored -- for
  ## Arabic, Persian, Hebrew, Urdu. "" or "en": English again. "pseudo":
  ## every text stretched and marked (`pseudoText`), to try a layout for
  ## the longer words of other languages and find the words not translated
  ## ($RETRO_LANG=pseudo does it as the app starts).
  uiStrings.clear()
  uiLanguage = lang
  uiPseudo = lang == "pseudo"
  if lang notin ["", "en", "pseudo"]:
    for t in tables:
      for (k, v) in t:
        if k.len > 0 and v.len > 0: uiStrings[k] = v
  ui.rtl = lang in ["ar", "fa", "he", "ur"]
  setRtlInterface(ui.rtl)     # (mixed lines read right to left, as the interface)
  ui.force = true

proc uiLanguageCode*(): string = uiLanguage
  ## The interface's language ("" English).

proc tr*(s: sink string): string =
  ## `s` in the interface's language (as it is when it has no translation).
  if uiPseudo: return pseudoText(s)
  if uiStrings.len == 0 or s.len == 0: return s     # (moved, not copied)
  uiStrings.getOrDefault(s, s)

proc mirroredX(x: int): int {.inline.} =
  ## (a point across the screen, right to left when the interface is)
  if ui.rtl: ui.w - 1 - x else: x

var caretTold: Rect      # (the caret the input method was told of last)

proc noteTextCaret*(r: Rect) =
  ## The caret of the text box that has the keyboard is at `r` (logical
  ## pixels; as high as its line): the system's input method (an IME:
  ## Chinese, Japanese, Korean...) shows what it composes, and its
  ## candidates, there. A text box calls it every frame it has the keyboard;
  ## the system is told when it moved.
  if r == caretTold: return
  caretTold = r
  let w = max(1, r.w)
  let x = if ui.rtl: mirroredX(r.x + w - 1) else: r.x
  setTextCaret(x * zoom, r.y * zoom, w * zoom, max(1, r.h) * zoom)

const macKeys = defined(macosx)
  ## (macOS and iOS: Cmd is the Ctrl of shortcuts -- the drivers report it so)

var optionLetters* = false
  ## On a Mac, Option + a letter picks the underlined letter of a menu or a
  ## control, as Alt does elsewhere (false, the default: it types, as Mac
  ## users expect -- @, braces, the bar, € on many layouts). The tests turn it on, so
  ## they press the same keys on every system.

proc modifierName*(m: Modifier): string =
  ## A modifier key's name as this system's keyboards have it: Ctrl, Alt,
  ## Shift, Win; on a Mac Cmd, Option, Shift, Control (Cmd is reported as
  ## Ctrl there, and Control as the Gui key).
  case m
  of ShiftPressed: "Shift"
  of CtrlPressed: (if macKeys: "Cmd" else: "Ctrl")
  of AltPressed: (if macKeys: "Option" else: "Alt")
  of GuiPressed: (if macKeys: "Control" else: "Win")

proc shortcutText*(s: string): string =
  ## A shortcut as written for the user ("Ctrl+S", "Ctrl+Shift+Z", "Alt+F4")
  ## in this system's words: on a Mac "Cmd+S", "Cmd+Shift+Z", "Cmd+W" (where
  ## Cmd does what Ctrl does elsewhere); elsewhere as it is. Menus show
  ## their items' shortcuts so.
  when macKeys:
    if s == "Alt+F4": return "Cmd+W"
    var i = 0
    while i < s.len:
      let start = i == 0 or s[i - 1] in {'+', ' ', '/', ',', '('}
      if start and s.continuesWith("Ctrl+", i):
        result.add "Cmd+"
        i += 5
      elif start and s.continuesWith("Alt+", i):
        result.add "Option+"
        i += 4
      else:
        result.add s[i]
        inc i
  else:
    s

var keepStack: seq[tuple[area: Rect; mx: int]]

proc beginKeepSides*(area: Rect) =
  ## In a right-to-left interface, what is drawn from here to
  ## `endKeepSides` keeps its left and right -- a picture and what is drawn
  ## over it, a text being edited -- only moved to where `area` is; the
  ## mouse is read the same way meanwhile. (Nothing changes left to right.)
  beginNoMirror(area)
  keepStack.add (area, ui.mx)
  if ui.rtl: ui.mx = 2 * area.x + area.w - 1 - ui.mx

proc endKeepSides*() =
  ## Ends `beginKeepSides`.
  endNoMirror()
  if keepStack.len > 0: ui.mx = keepStack.pop().mx

proc globalX*(x: int): int =
  ## A point read inside `beginKeepSides` as the rest of the frame reads it
  ## (a menu opened where it was clicked).
  result = x
  if ui.rtl:
    for k in countdown(keepStack.high, 0):
      let a = keepStack[k].area
      result = 2 * a.x + a.w - 1 - result

proc splitMnemonic*(label: string): tuple[text: string, at: int] =
  ## "&File" -> ("File", 0): the text to show and where to underline
  ## (another language's: its text, nothing underlined).
  result.at = -1
  if '&' notin label:
    result.text = label           # most labels: nothing to take out
  else:
    result.text = newStringOfCap(label.len)
    var i = 0
    while i < label.len:
      if label[i] == '&' and i + 1 < label.len:
        if label[i+1] != '&' and result.at < 0: result.at = result.text.len
        inc i
      result.text.add label[i]
      inc i
  if uiPseudo:
    result.text = pseudoText(result.text)
    result.at = -1
  elif uiStrings.len > 0:
    let t = uiStrings.getOrDefault(result.text, "")
    if t.len > 0:
      result.text = t
      result.at = -1

var
  mnText, mnPart: string
    ## (a label's text without its '&', and a piece of it, made in these:
    ## a label drawn every frame takes no memory)

proc stripMnemonic(label: string): int =
  ## `label` without its '&' into `mnText` (no translation looked up); the
  ## underlined letter's place (-1: none).
  result = -1
  mnText.setLen(0)
  var i = 0
  while i < label.len:
    if label[i] == '&' and i + 1 < label.len:
      if label[i+1] != '&' and result < 0: result = mnText.len
      inc i
    mnText.add label[i]
    inc i

proc labelWidth*(label: string; bold = false): int =
  ## The width of a label as `drawLabel` draws it (without its '&').
  if uiStrings.len == 0 and not uiPseudo:
    if '&' notin label: return textWidth(label, bold)   # (as it is: no copy)
    discard stripMnemonic(label)
    return textWidth(mnText, bold)
  textWidth(splitMnemonic(label).text, bold)

proc drawLabel*(x, y: int; label: string; c: Color; bold = false) =
  ## Text with its mnemonic letter underlined, the 3.1 way.
  if uiStrings.len == 0 and not uiPseudo and '&' notin label:
    text(x, y, label, c, bold)           # (nothing to take out or underline: no copy)
    return
  var at: int
  if uiStrings.len == 0 and not uiPseudo:
    at = stripMnemonic(label)
  else:
    let (s, a) = splitMnemonic(label)
    mnText.setLen(0)
    mnText.add s
    at = a
  text(x, y, mnText, c, bold)
  if at >= 0:
    mnPart.setLen(0)
    for k in 0 ..< at: mnPart.add mnText[k]
    let ux = x + textWidth(mnPart, bold)
    var r: Rune
    var i = at
    fastRuneAt(mnText, i, r)
    mnPart.setLen(0)
    for k in at ..< i: mnPart.add mnText[k]
    hline(ux, y + FontAscent + 1, textWidth(mnPart, bold), c)

# ---- the loop ---------------------------------------------------------------

var
  pending: Event
  hasPending: bool

var deferred: seq[Event]      # events that came while work went on (handled after it)

proc nextEvent(e: var Event; timeout: int): bool =
  if deferred.len > 0:
    e = deferred[0]
    deferred.delete(0)
    return true
  if hasPending:
    e = pending
    hasPending = false
    return true
  let flags = if ui.prevTakesText: {WantTextInput} else: {}
  if timeout == 0: pollEvent(e, flags) else: waitEvent(e, timeout, flags)

var layoutFont = uiFont()       # the font the metrics were made for

proc applyLayout(l: ScreenLayout) =
  unitPx = max(1, l.scaleX)
  # whole pixels only: 150% stays 1x on a desktop, a 1.5x tablet gets 2x
  # (the text is drawn at any size between, fitted to the pixels, so the
  # font does not change this)
  layoutFont = uiFont()
  zoom = if ui.zoomWanted > 0: ui.zoomWanted
         else: max(1, (l.uiScale + (if l.touch: 50 else: 49)) div 100)
  pxScale = zoom * unitPx
  ui.devW = l.width * unitPx
  ui.devH = l.height * unitPx
  ui.w = l.width div zoom
  ui.h = l.height div zoom
  template inset(v: int): int = (max(0, v) + zoom - 1) div zoom
  if inset(l.safeBottom) > ui.layoutSafe.bottom + dp(40) and ui.prevTakesText:
    # (the on-screen keyboard came up under a text box with the focus: the
    # views that scroll bring it into sight above the keyboard, as Tab does)
    ui.focusMoved = ui.frameNo
  ui.layoutSafe = (inset(l.safeTop), inset(l.safeLeft), inset(l.safeBottom),
                   inset(l.safeRight))
  # (and the 3.1 frame's border all round, worked out again by `beginFrame`)
  let fb = ui.frameBorder
  ui.safe = (ui.layoutSafe.top + fb, ui.layoutSafe.left + fb,
             ui.layoutSafe.bottom + fb, ui.layoutSafe.right + fb)
  ui.touch = l.touch or getEnv("RETRO_TOUCH") == "1"
  # (a tablet: its shorter side is 600 dp or more -- the size Android calls
  # sw600dp)
  ui.roomy = min(l.width, l.height) * 100 >= 600 * max(100, l.uiScale)
  # whole pixels keep lines sharp; what the rounding left out of the
  # screen's scale is made up by the sizes of text and controls
  ui.density = if ui.zoomWanted > 0: 1.0
               else: clamp(float(max(100, l.uiScale)) / float(zoom * 100), 0.75, 1.5)
  ui.k = ui.density * float(ui.uiScale) / 100
  fitMetrics()
  ui.force = true

proc sizesFromEnv*(): string =
  ## The control sizes asked for in the environment: "touch", "desktop" or
  ## "auto" from $RETRO_CONTROLS, "touch" for $RETRO_TOUCH=1, else "" (they
  ## win over the sizes the user kept, as $RETRO_SCALE does).
  case getEnv("RETRO_CONTROLS").toLowerAscii
  of "touch", "finger", "fingers": "Touch"
  of "desktop", "mouse": "Desktop"
  of "auto", "automatic": "Automatic"
  else: (if getEnv("RETRO_TOUCH") == "1": "Touch" else: "")

proc setControlSizes*(c: ControlSizes) =
  ## How big controls are: `csAuto` (finger-sized on phones, desktop-sized
  ## on tablets and desktops), `csDesktop` or `csTouch`. `appearanceSettings`
  ## lets the user choose; `storeAppearance` keeps it.
  if ui.sizes == c: return
  ui.sizes = c
  fitMetrics()
  ui.force = true

proc controlSizes*(): ControlSizes = ui.sizes
  ## How big controls are (see `setControlSizes`).

proc setZoom*(n: int) =
  ## Magnify the whole UI by `n` whole pixels (1..4); 0 follows the screen.
  ui.zoomWanted = clamp(n, 0, 4)
  applyLayout(getWindowLayout())

proc zoomLevel*(): int = zoom
  ## The current magnification.

var lookDirty = false

proc noteLookChanged*() =
  ## The look was changed by the user's hand (`appearanceSettings`, the
  ## sizes): `app`'s `look` keeps it (see `lookChanged`).
  lookDirty = true

proc lookChanged*(): bool =
  ## The look changed since the last call (`noteLookChanged`).
  result = lookDirty
  lookDirty = false

proc setUiScale*(percent: int) =
  ## The size of everything (text, controls, spacing), 50..300 percent of
  ## the normal size for the screen. Ctrl and +, - or 0 change it too.
  ## Cheap to call every frame: only a change lays out and draws again.
  let p = clamp(percent, 50, 300)
  if p == ui.uiScale and ui.k == ui.density * float(p) / 100: return
  if p != ui.uiScale: lookDirty = true
  ui.uiScale = p
  ui.k = ui.density * float(ui.uiScale) / 100
  fitMetrics()
  ui.force = true

proc uiScale*(): int = ui.uiScale
  ## The user's UI size in percent (see `setUiScale`).

proc scaleStep*(dir: int): int =
  ## The next UI size up (`dir` > 0) or down from the current one.
  const steps = [50, 67, 75, 80, 90, 100, 110, 125, 150, 175, 200, 250, 300]
  if dir > 0:
    for v in steps:
      if v > ui.uiScale: return v
    steps[^1]
  else:
    for i in countdown(steps.high, 0):
      if steps[i] < ui.uiScale: return steps[i]
    steps[0]

proc setTextScale*(percent: int) =
  ## The size of the text alone (controls grow with it), 50..300 percent.
  if clamp(percent, 50, 300) == ui.textScale: return
  lookDirty = true
  ui.textScale = clamp(percent, 50, 300)
  fitMetrics()
  ui.force = true

proc textScale*(): int = ui.textScale
  ## The user's text size in percent (see `setTextScale`).

proc setBaseTextSize*(em: float) =
  ## The text size at 100%, logical pixels per em (default `DesktopTextEm`,
  ## 12, on desktops and tablets; `TouchTextEm`, 15, on phones).
  if em == ui.baseEm: return
  ui.baseEm = em
  fitMetrics()
  ui.force = true

proc letterOf(k: KeyCode): char =
  if k in KeyA..KeyZ: char(ord('a') + ord(k) - ord(KeyA))
  elif k in Key0..Key9: char(ord('0') + ord(k) - ord(Key0))
  else: '\0'

proc penFrom(e: Event) {.inline.} =
  ## (how a pen is held, from a pointer event; a mouse or a finger: pressed
  ## all the way, upright)
  if e.pen:
    ui.pen = true
    ui.pressure = clamp(e.pressure.float, 0.0, 1.0)
    ui.tilt = clamp(e.tilt.float / (PI / 2), 0.0, 1.0)
    ui.azimuth = e.azimuth.float
    ui.eraser = e.twist < 0
    ui.twist = if e.twist < 0: 0.0 else: e.twist.float
  else:
    ui.pen = false
    ui.pressure = 1
    ui.tilt = 0
    ui.eraser = false

var wheelShift = false
  ## (Shift is held for this frame's sideways wheel only: `beginFrame`)
var dropKeyText* = false
  ## The text of this frame's key is not typed when it comes (a menu took
  ## the letter): set by the menus.

proc applyEvent(e: Event): bool =
  ## An event into `ui` (the window's whose frame runs); true when the frame
  ## starts with it -- a press, a key, a close -- and the events after it
  ## wait for the next.
  inc frameEvents
  case e.kind
  of MouseMoveEvent:
    if e.hasMods: ui.mods = e.mods
    ui.mx = mirroredX(e.x div zoom)
    ui.my = e.y div zoom
    penFrom(e)
    ui.mouseMoved = true
    # moving with no button down: a mouse or a pen, not a finger
    if not ui.mouseDown and (e.fromMouse or not ui.touch): ui.hovering = true
  of WindowFocusGainedEvent, WindowFocusLostEvent:
    ui.active31 = e.kind == WindowFocusGainedEvent
  of MouseWheelEvent:
    if e.hasMods: ui.mods = e.mods
    ui.wheel += e.y
    ui.wheelX += e.x
  of FileDropEvent:
    # (files from the system's file manager: this frame's drop)
    ui.mx = mirroredX(e.x div zoom)
    ui.my = e.y div zoom
    ui.mouseMoved = true
    dropFiles = e.files
    dropAt = point(ui.mx, ui.my)
    return true
  of GestureEvent:
    # (two fingers: pinched and moved -- the frame's changes together)
    ui.pinch *= max(0.01, e.scale.float)
    ui.panDX += e.dx.float / zoom.float
    ui.panDY += e.dy.float / zoom.float
    ui.pinchX = mirroredX(e.x div zoom)
    ui.pinchY = e.y div zoom
    ui.gesturing = e.phase != gsEnd
  of TextInputEvent:
    if dropKeyText: dropKeyText = false
    elif ui.textOk:
      for c in e.text:
        if c == '\0': break
        ui.typed.add c
    if ui.composing.len > 0:
      ui.composing.setLen(0)          # (settled: it came as text)
      ui.redraw = true
  of TextEditingEvent:
    ui.composing = e.composing
    ui.composeCaret = clamp(e.x, 0, ui.composing.len)
    ui.redraw = true
  of WindowResizeEvent, WindowMetricsEvent:
    var l = getWindowLayout()
    l.width = e.x
    l.height = e.y
    if e.kind == WindowMetricsEvent:
      l.scaleX = e.scaleX
      l.uiScale = e.uiScale
    applyLayout(l)
  of AppPauseEvent:
    ui.paused = true
  of AppResumeEvent:
    ui.paused = false
    ui.force = true
  of WindowHiddenEvent:
    ui.hidden = true
  of WindowShownEvent:
    ui.hidden = false
    ui.force = true
  of GlobalKeyEvent:
    globalHits.add e.x
    ui.redraw = true
  of QuitEvent, WindowCloseEvent:
    ui.closeAsked = true
    return true
  of MouseDownEvent:
    ui.altArmed = false
    if e.hasMods: ui.mods = e.mods
    ui.mx = mirroredX(e.x div zoom)
    ui.my = e.y div zoom
    penFrom(e)
    ui.mouseMoved = true
    ui.active31 = true
    ui.fingerDown = ui.touch and not e.fromMouse
    if e.fromMouse: ui.hovering = true
    if e.button == LeftButton:
      ui.mouseDown = true
      ui.pressed = true
      ui.clicks = e.clicks
      ui.pressAt = getTicks()
      ui.pressX = ui.mx
      ui.pressY = ui.my
      ui.longFired = false
      ui.panning = false
      ui.dragsActive = false
      ui.panFrom = point(ui.mx, ui.my)
    elif e.button == RightButton:
      ui.rpressed = true
      ui.rmouseDown = true
    elif e.button == MiddleButton:
      ui.mpressed = true
    elif e.button == BackButton:
      ui.navBack = true
    elif e.button == ForwardButton:
      ui.navForward = true
    return true
  of MouseUpEvent:
    if e.hasMods: ui.mods = e.mods
    ui.mx = mirroredX(e.x div zoom)
    ui.my = e.y div zoom
    penFrom(e)
    if e.button == LeftButton:
      ui.mouseDown = false
      ui.released = true
      # a finger lifted is no longer over anything
      if ui.touch and not e.fromMouse: ui.hovering = false
      return true
    elif e.button == RightButton:
      ui.rmouseDown = false
      return true
  of KeyDownEvent:
    dropKeyText = false
    ui.key = e.key
    ui.mods = e.mods
    let ctrl = CtrlPressed in e.mods
    let alt = AltPressed in e.mods
    if defined(macosx) and not optionLetters:
      # (a Mac types with Option -- @, {, [, |, € on many layouts -- and makes
      # no menu's letters with it: what Cmd, the Ctrl here, leaves is text)
      ui.textOk = not ctrl and GuiPressed notin e.mods
    else:
      # (Ctrl and Alt together are AltGr where a driver cannot tell them apart)
      ui.textOk = ctrl == alt and GuiPressed notin e.mods
      if alt and not ctrl: ui.mnemonic = letterOf(e.key)
      # (Alt down alone -- the key itself, no other one -- arms the menu bar)
      ui.altArmed = e.key == KeyNone and e.mods == {AltPressed}
    return true
  of KeyUpEvent:
    dropKeyText = false
    if e.hasMods: ui.mods = e.mods
    ui.keyUp = e.key
    if ui.altArmed and e.key == KeyNone and AltPressed notin e.mods:
      ui.altTapped = true            # (let go with nothing between: the menu bar)
    ui.altArmed = false
    return true
  else: discard
  false

proc routeToWindow(e: Event) {.nimcall.}

var idlePollers*: seq[proc (): bool {.nimcall.}]
  ## Asked every 50 ms while the app waits for input: true wakes it for a
  ## frame. For what comes from outside the system's input -- a line on a
  ## socket (the driver, `retroui/drive`) -- with no frame drawn for nothing
  ## while it waits.
var polledAwake: bool             # (this frame was woken by a poller)

proc feedEvent*(e: Event) =
  ## An event as if it came from the system: taken by the next frames, after
  ## those already waiting (the driver's clicks and keys, `retroui/drive`).
  deferred.add e

proc eventsWaiting*(): int = deferred.len
  ## The events fed (`feedEvent`) and not taken yet.

proc takeEvent(e: Event): bool =
  if e.window != 0:
    # (another window's: kept for its frame, which runs in this one)
    routeToWindow(e)
    return false
  applyEvent(e)

proc pump(waitMs: int) =
  var e: Event
  var t = waitMs
  polledAwake = false
  if idlePollers.len > 0 and t != 0:
    # (the wait in slices, the pollers asked between them; a driver that
    # does not wait -- a test's, a headless one -- is asked once, and so is
    # the last slice of a few ms)
    let until = if t < 0: -1 else: getTicks() + t
    while true:
      let slice = if until < 0: 50 else: min(50, until - getTicks())
      if slice <= 0: break
      let t0 = getMonoTime()
      if nextEvent(e, slice):
        if takeEvent(e): return
        break
      for p in idlePollers:
        if p(): polledAwake = true
      if polledAwake or slice < 4 or (getMonoTime() - t0).inMilliseconds < slice div 2: break
    t = 0
  while nextEvent(e, t):
    t = 0
    if takeEvent(e): break

# ---- long work: a box with an animation, the events kept read ---------------------------------------

var
  busyLastPump, busyLastDraw: int
  busyCancelRect: Rect

proc busyPump(boxShown: bool) =
  ## The system's events while work goes on: Esc or Cancel ask it to stop;
  ## the rest waits for the next frame -- a window sized, the app put away,
  ## and, until the box is up, keys, letters and clicks too (a page that
  ## reads a picture or two takes a moment: what is typed meanwhile is
  ## typed). Once the box shows, a key or a click is dropped (the window is
  ## busy, and says so).
  var e: Event
  while true:
    if hasPending:
      e = pending
      hasPending = false
    elif not pollEvent(e, {}): break
    case e.kind
    of KeyDownEvent:
      if e.key == KeyEsc: busyCancelAsked = true
      elif not boxShown: deferred.add e
    of MouseDownEvent:
      if busyCancelRect.contains(point(e.x div zoom, e.y div zoom)): busyCancelAsked = true
      elif not boxShown: deferred.add e
    of TextInputEvent, MouseWheelEvent:
      if not boxShown: deferred.add e
    of MouseMoveEvent:
      # (only where the pointer is now matters: one move kept)
      if not boxShown:
        if deferred.len > 0 and deferred[^1].kind == MouseMoveEvent: deferred[^1] = e
        else: deferred.add e
    of AppPauseEvent:
      ui.paused = true
      deferred.add e
    of AppResumeEvent:
      ui.paused = false
      deferred.add e
    of WindowHiddenEvent, WindowShownEvent:
      ui.hidden = e.kind == WindowHiddenEvent
      deferred.add e
    of QuitEvent, WindowCloseEvent:
      busyCancelAsked = true
      deferred.add e
    else: deferred.add e

var busyPicture*: Bitmap
  ## A picture the busy box shows above its bar while it is set (the file
  ## being opened, as it will look: seen while it loads); nil: none.

proc drawBusyBox(elapsed: int) =
  ## The box: what is being done, an hourglass, a bar going along (or
  ## filling), Cancel; `busyPicture` above them.
  let th = ui.theme
  let pic = busyPicture
  let picH = if pic != nil and pic.w > 0 and pic.h > 0: min(dp(180), ui.h div 3) else: 0
  let bw = min(ui.w - 16, dp(330))
  let bh = dp(112) + (if picH > 0: picH + dp(8) else: 0)
  let r = rect((ui.w - bw) div 2, (ui.h - bh) div 2, bw, bh)
  overlayNow(rect(r.x - 2, r.y - 2, r.w + 4, r.h + 4), proc () =
    fill(r, th.face)
    box(r, th.frame)
    box(inset(r, 1), th.light)
    var tb = rect(r.x + 2, r.y + 2, r.w - 4, FontH + dp(5))
    fill(tb, th.select)
    text(tb.x + dp(5), tb.y + (tb.h - FontH) div 2, (if ui.title.len > 0: ui.title else: "Working"),
         th.selectText, true)
    if picH > 0:
      # (the picture, fitted, in a sunken frame; what follows goes below it)
      let pr = rect(r.x + dp(10), tb.y + tb.h + dp(6), r.w - dp(20), picH)
      fill(pr, th.shadow)
      let k = min((pr.w - 4) / pic.w, (pr.h - 4) / pic.h)
      let w = max(1, int(pic.w.float * k))
      let h = max(1, int(pic.h.float * k))
      drawBitmap(rect(pr.x + (pr.w - w) div 2, pr.y + (pr.h - h) div 2, w, h), pic)
      box(pr, th.shadow)
      tb.y += picH + dp(8)
    let glyph = if (elapsed div 600) mod 2 == 0: "\u{10F04C}" else: "\u{10F04D}"
    image(r.x + dp(12), tb.y + tb.h + dp(10), glyphIcon(glyph, th.text, dp(32)))
    let tx = r.x + dp(54)
    var what = if busyLabel.len > 0: busyLabel else: "Working"
    if not what.endsWith("..."): what.add "..."
    text(tx, tb.y + tb.h + dp(8), what, th.text)
    text(tx, tb.y + tb.h + dp(8) + FontH, $(elapsed div 1000) & " s", th.shadow)
    # the bar: filled to what is done, or blocks going along
    let bar = rect(tx, tb.y + tb.h + dp(12) + 2 * FontH, r.x + r.w - dp(12) - tx, dp(14))
    fill(bar, th.window)
    box(bar, th.shadow)
    let inner = inset(bar, 2)
    let blk = dp(8)
    if busyFraction >= 0:
      let n = int(float(inner.w) * clamp(busyFraction, 0.0, 1.0)) div (blk + 2)
      for k in 0 ..< n: fill(rect(inner.x + k * (blk + 2), inner.y, blk, inner.h), th.select)
    else:
      let span = 5
      let total = inner.w div (blk + 2)
      let at = (elapsed div 90) mod max(1, total + span)
      for k in at - span .. at:
        if k >= 0 and k < total: fill(rect(inner.x + k * (blk + 2), inner.y, blk, inner.h), th.select)
    # Cancel
    if busyCancelDepth > 0:
      let cw = dp(76)
      let cb = rect(r.x + r.w - cw - dp(12), r.y + r.h - CtrlH - dp(8), cw, CtrlH)
      fill(cb, th.face)
      box(cb, th.frame)
      hline(cb.x + 1, cb.y + 1, cb.w - 2, th.light)
      vline(cb.x + 1, cb.y + 1, cb.h - 2, th.light)
      hline(cb.x + 1, cb.y + cb.h - 2, cb.w - 2, th.shadow)
      vline(cb.x + cb.w - 2, cb.y + 1, cb.h - 2, th.shadow)
      text(cb.x + (cb.w - textWidth("Cancel")) div 2, cb.y + (cb.h - FontH) div 2, "Cancel", th.text)
      text(r.x + dp(12), cb.y + (cb.h - FontH) div 2, "Esc stops it", th.shadow)
      busyCancelRect = cb
    else:
      busyCancelRect = rect(0, 0, 0, 0))

proc busyTickNow() =
  ## (`busyTick`: the events read now and then; the box drawn once the
  ## work has gone on a moment)
  let t = getTicks()
  if t - busyLastPump < 25: return
  busyLastPump = t
  # (the box is up once it was drawn in this frame's work)
  busyPump(boxShown = busyLastDraw > 0 and busyLastDraw >= ui.now)
  let since = t - ui.now
  if since < 250 or ui.paused or not ui.running: return
  if t - busyLastDraw < 90: return
  busyLastDraw = t
  drawBusyBox(since)

proc themeFromEnv*()
  ## `RETRO_THEME` (a built-in theme's name, "OLED Black", or its number)
  ## overrides the colors chosen: for tests and screenshots.

var windowIcon*: seq[uint32]
  ## The window's picture on a desktop (its taskbar button, its title bar),
  ## set before `startApp`: `windowIconFromPng` makes it from an app icon.
  ## Empty: the desktop's own.

const retroFrame* {.strdefine.} = "system"
  ## The window's frame on desktops, chosen when the app is built:
  ## `-d:retroFrame=classic` draws Windows 3.1's (`setClassicFrame`),
  ## "system" (the default) keeps the system's own. RETRO_FRAME=classic or
  ## system, when the app starts, wins over it.

type WindowFrame* = enum
  ## The frame a desktop app's window opens with (`app`'s `frame`).
  wfAsBuilt = "as built"   ## the one `-d:retroFrame` built in: the system's,
                           ## unless it says classic
  wfSystem = "system"      ## the system's own
  wfClassic = "classic"    ## Windows 3.1's, drawn by the app

const FrameDesignBorder = 5
  ## The 3.1 frame's sizing border at 100%: a black line, the gray band, a
  ## black line.

var
  frameWanted = retroFrame == "classic"   # (asked for; drawn when it can be)
  captionEnv = false                       # RETRO_CAPTION=1: the phones' title bar

var userFrameChoice* = true
  ## The user may choose the window's frame in every app -- the system's, or
  ## Windows 3.1's -- and the choice is kept for the app's next start
  ## (`appIdent`): with the 3.1 frame, in its control menu; with the
  ## system's, in its menu where it takes an item (Windows' system menu:
  ## the title bar's icon, Alt+Space; macOS: the menu bar's Window menu,
  ## checked while the 3.1 frame is on); and in `appearanceSettings` (on
  ## X11 and Wayland, whose window managers keep their menus to themselves,
  ## the way back to the 3.1 frame). False (set before `startApp`): the
  ## app's frame only.

var appIdent* = ""
  ## The app's name for what the toolkit keeps for it -- the frame the user
  ## chose, the log of faults, the GPU's start that failed -- set before
  ## `startApp` (the `app` template's `id`); "": the window's title without
  ## a version at its end.

var reportedVersion* = ""
  ## The app's version, for what is sent of a fault (the "stopped" screen,
  ## Report a Problem). Set it before `startApp`: `aboutBox` sets it too,
  ## but the "stopped" screen comes before any About box is drawn.

proc appArguments*(): seq[string] =
  ## The words after the program's name on its command line (a desktop's
  ## "open with", a file dropped on its icon, Termux): none in an Android or
  ## iOS app and in a web page, which have no command line -- there Nim's
  ## `paramCount` and `commandLineParams` raise. Use this in an app's code.
  when androidApp or defined(ios) or defined(wasm):
    result = @[]
  else:
    try: result = commandLineParams()
    except OSError: result = @[]

const frameMenuLabel = "Windows 3.1 &Frame"   ## (the item in the system's menu)

proc appBaseName(title: string): string =
  ## The app's name without its version ("Retro Mail 1.0.3": "Retro Mail").
  result = title
  let sp = result.rfind(' ')
  if sp > 0 and sp + 1 < result.len and result[sp + 1] in Digits: result = result[0 ..< sp]

proc keptFramePath(): string =
  if appIdent.len == 0: return ""
  try: dataDir(appIdent) / "window.ini" except CatchableError: ""

proc keptFrame*(): string =
  ## The frame the user chose for this app (`chooseClassicFrame`):
  ## "classic", "system", or "" (none chosen yet).
  let p = keptFramePath()
  if p.len == 0: return ""
  try:
    for line in readFile(p).splitLines:
      if line.startsWith("frame="): return line[6 .. ^1].strip
  except CatchableError: discard

proc canClassicFrame*(): bool =
  ## The 3.1 frame can be drawn here: a desktop whose windows can do without
  ## the system's frame -- Windows, macOS, X11 (Linux, the BSDs, Wayland
  ## desktops through XWayland), and the GTK 4, SDL and Siwin drivers
  ## (Wayland's own windows too) -- not the phones.
  not (androidApp or defined(ios)) and canDrawFrame()

proc showFrameMenuItem() =
  ## (the item in the system's menu, checked while the 3.1 frame is on)
  if userFrameChoice and canClassicFrame(): setFrameMenuItem(frameMenuLabel, ui.ownFrame)

proc setClassicFrame*(on: bool) =
  ## The window's frame as Windows 3.1 drew it (true): the sizing border and
  ## the title bar with its control-menu box and its minimize, maximize and
  ## close buttons (or 3.1's two: `captionButtons`), drawn by the app in a
  ## window without the system's frame -- or
  ## the system's own frame (false). Before `startApp` it is how the window
  ## opens, after it the window changes. Where it cannot be
  ## (`canClassicFrame`), the system's frame stays.
  frameWanted = on
  if not ui.running: return
  var now = false
  if on and canClassicFrame(): now = setSystemFrame(false)
  # (a window that cannot have the system's frame back keeps the 3.1 one)
  elif not on and ui.ownFrame: now = not setSystemFrame(true)
  if now != ui.ownFrame:
    ui.ownFrame = now
    ui.ownCaption = androidApp or defined(ios) or captionEnv or now
    ui.force = true
    showFrameMenuItem()

proc classicFrame*(): bool = ui.ownFrame
  ## The 3.1 frame is drawn now (`setClassicFrame`).

proc chooseClassicFrame*(on: bool) =
  ## The frame the user chose -- the 3.1 one (true) or the system's -- as
  ## `setClassicFrame` sets it, and kept for the app's next start (it then
  ## wins over the frame the app was built with). The control menu, the
  ## system's menu and `appearanceSettings` call it.
  setClassicFrame(on)
  if not userFrameChoice: return
  let p = keptFramePath()
  if p.len == 0: return
  try:
    createDir(p.parentDir)
    writeFile(p, "frame=" & (if on: "classic" else: "system") & "\n")
  except CatchableError: discard

proc classicFrameWanted*(): bool = frameWanted
  ## The 3.1 frame was asked for (by the build, RETRO_FRAME or
  ## `setClassicFrame`), drawn or not.

var resizableWanted = true

proc setResizable*(on: bool) =
  ## The user may size and maximize the window (true, the default) or not:
  ## the frame then has no sizing border to drag, no maximize button and no
  ## size grip, and the window keeps the size the app gave it -- the 3.1
  ## frame and the system's alike. `app`'s `resizable` option sets it.
  if on == resizableWanted and ui.running: return
  resizableWanted = on
  setWindowResizable(on)
  ui.force = true

proc resizable*(): bool = resizableWanted
  ## The user may size the window (`setResizable`).

proc sizeGrip*(): Rect =
  ## Where the 3.1 frame's size grip is -- the square the size of a scroll
  ## bar's width in the bottom right corner inside the frame (the bottom
  ## left, right to left), a handle for a finger as much as for the mouse --
  ## and empty where there is none: the system's frame, a window that keeps
  ## its size, a maximized one. The status bar and the window's scroll bars
  ## leave it its corner.
  if not ui.ownFrame or not resizableWanted or ui.frameBorder <= 0: return
  rect(ui.w - ui.frameBorder - SbW, ui.h - ui.frameBorder - SbW, SbW, SbW)

proc startApp*(title: string; w, h: int; theme = ui.theme; zoom = 0) =
  ## Open the window. `zoom` forces whole-pixel magnification (0 = the
  ## display's own scale).
  if appIdent.len == 0: appIdent = appBaseName(title)
  if getEnv("RETRO_LANG") == "pseudo": setUiLanguage("pseudo")
  ui.theme = theme
  ui.zoomWanted = zoom
  ui.active31 = true
  if zoom == 0:
    let env = getEnv("RETRO_ZOOM")
    if env.len == 1 and env[0] in {'1'..'4'}: ui.zoomWanted = ord(env[0]) - ord('0')
  var w = w
  var h = h
  let size = getEnv("RETRO_SIZE")            # e.g. 400x800, to try layouts
  if 'x' in size:
    try:
      w = parseInt(size.split('x')[0])
      h = parseInt(size.split('x')[1])
    except ValueError: discard
  let sc = getEnv("RETRO_SCALE")
  if sc.len > 0:
    try: ui.uiScale = clamp(parseInt(sc), 50, 300) except ValueError: discard
  # how big controls are: RETRO_CONTROLS (touch, desktop, auto); RETRO_TOUCH=1
  # is a finger, so finger-sized controls too, on a tablet or a desktop
  let asked = sizesFromEnv()
  if asked.len > 0: ui.sizes = parseEnum[ControlSizes](asked, ui.sizes)
  # the window's frame: the 3.1 one the app draws, or the system's -- as
  # built, as the user chose it last time, as RETRO_FRAME says
  if userFrameChoice:
    case keptFrame()
    of "classic": frameWanted = true
    of "system": frameWanted = false
    else: discard
  # (a window on a desktop the toolkit draws, `retrokit run --window`: the
  # 3.1 frame is what moves and sizes it there)
  if getEnv("RETRO_WINDOW") == "1": frameWanted = true
  case getEnv("RETRO_FRAME")
  of "classic": frameWanted = true
  of "system": frameWanted = false
  else: discard
  captionEnv = getEnv("RETRO_CAPTION") == "1"
  ui.ownFrame = frameWanted and canClassicFrame() and setSystemFrame(false)
  if not ui.ownFrame and canClassicFrame() and not setSystemFrame(true):
    # (a system whose windows have no frame of its own -- Wayland where the
    # compositor draws none, GNOME's: the 3.1 one, else the window could
    # not be moved, sized or closed)
    ui.ownFrame = setSystemFrame(false)
  if ui.ownFrame:
    # (the frame goes round the size asked for: the app's room stays as big)
    if w >= 0: w += 2 * FrameDesignBorder
    if h >= 0: h += 2 * FrameDesignBorder + MenuH + 1
  # (the system's menu offers the 3.1 frame where it takes an item)
  showFrameMenuItem()
  # (everything larger -- $RETRO_SCALE -- the window too, so it all still fits)
  if ui.uiScale != 100:
    if w > 0: w = w * ui.uiScale div 100
    if h > 0: h = h * ui.uiScale div 100
  let l = createWindow(w * max(1, ui.zoomWanted), h * max(1, ui.zoomWanted), icon = windowIcon)
  setWindowTitle(title)
  # (a file there while the GPU is started: a crash then is not repeated)
  # (the app's name without its version, as for the faults: an update does
  # not lose it)
  try: gpuGuardPath = dataDir(appIdent) / "gpu-starting"
  except CatchableError: discard
  # (what brings the program down written down, for the next start to tell)
  # (the app's name without its version: the log stays when it is updated)
  try: setFaultPath(dataDir(appIdent) / "faults.log")
  except CatchableError: discard
  # (the last run's start mark, then this one's)
  try:
    startMark = dataDir(appIdent) / "starting"
    prevStartMark = if fileExists(startMark): readFile(startMark).strip else: ""
  except CatchableError: startMark = ""
  markStarting()
  errorMessageWriter = writeFault
  when androidApp:
    if faultPath.len > 0: retroCrashLog(faultPath.cstring)
  case getEnv("RETRO_GPU").toLowerAscii
  of "0", "cpu": setGpuMode(gmCpu)
  of "1", "gpu": setGpuMode(gmGpu)
  of "auto": setGpuMode(gmAuto)
  else: discard
  themeFromEnv()
  ui.title = title
  when declared(atspiToolkit):
    atspiToolkit = "Retro Nim UI"
    atspiAppName = title
  ui.ownCaption = androidApp or defined(ios) or captionEnv or ui.ownFrame
  applyLayout(l)
  ui.running = true
  ui.prevBottom = ui.h
  markUiThread()
  busyHook = busyTickNow

var beginFrameHooks*: seq[proc () {.nimcall.}]
  ## Run in every `beginFrame` once the input is in (results of work done
  ## in the background are handed over here).

var endFrameHooks*: seq[proc () {.nimcall.}]
  ## Run at the start of every `endFrame` (toasts and other overlays).

var
  statT0: MonoTime
  statAvg: float                  # ms, smoothed
  statSum, statMax: float
  statN, statPresented: int
  statAt: MonoTime
  statsOn = getEnv("RETRO_STATS") == "1"
  statStart = getMonoTime()
  statFirst = false
  firstShownMs = -1               ## (when the first frame was shown, ms after the start)
  shownCount = 0                  ## (frames put on the screen so far)

proc framesShown*(): int = shownCount
  ## How many frames were put on the screen so far. What the first frame
  ## can do without -- a picture of a splash box, a list read, a cache
  ## filled -- waits for `framesShown() > 0`: the window shows something
  ## sooner.

proc noteFrame(presented: bool) =
  let ms = float((getMonoTime() - statT0).inMicroseconds) / 1000
  statAvg = if statAvg == 0: ms else: statAvg * 0.9 + ms * 0.1
  if presented:
    inc shownCount
    if firstShownMs < 0: firstShownMs = int((getMonoTime() - statStart).inMilliseconds)
  if not statsOn: return
  if ms >= 250:
    # (a frame long enough to feel: where the mouse was, the key, the
    # control with the focus when a reader's tree is kept -- RETRO_ACCESS=1)
    var foc = ""
    for n in accessTree:
      if asFocused in n.states: foc = ", the focus on " & ($n.role)[2 .. ^1] & " \"" & n.name & "\""
    stderr.writeLine "retroui: a frame of ", int(ms), " ms (the mouse at ", ui.mx, ",", ui.my,
      (if ui.key != KeyNone: ", key " & $ui.key else: ""), foc, ")"
  statSum += ms
  statMax = max(statMax, ms)
  inc statN
  if presented:
    inc statPresented
    if not statFirst:
      statFirst = true
      stderr.writeLine "retroui: first frame shown ",
        (getMonoTime() - statStart).inMilliseconds, " ms after start"
  let now = getMonoTime()
  if (now - statAt).inMilliseconds >= 2000:
    stderr.writeLine "retroui: ", statN, " frames, ", formatFloat(statSum / float(max(1, statN)),
      ffDecimal, 2), " ms average, ", formatFloat(statMax, ffDecimal, 2), " ms longest, ",
      statPresented, " shown"
    statSum = 0
    statMax = 0
    statN = 0
    statPresented = 0
    statAt = now

proc frameTime*(): float = statAvg
  ## How long the app's frames take to build and draw, in milliseconds
  ## (smoothed); RETRO_STATS=1 prints it every 2 seconds.

proc firstFrameMs*(): int = firstShownMs
  ## How long after the program started its first frame was shown, in
  ## milliseconds (-1: not yet).

# ---- a smoke run: the app started for real, left alone, then driven --------------------------------
#
# RETRO_SMOKE=12: the app runs as people start it -- its own window, the
# system's driver -- and the kit measures it: the first frame's time, then
# 3 seconds untouched (the frames run and the processor's time: an app at
# rest should do next to nothing), then clicks, keys, the wheel and typing
# until 12 seconds have passed. Then it ends: exit code 0, 1 when a fault
# was caught or logged, 2 when it was busy while untouched. A line is
# written to stderr and added to $RETRO_SMOKE_OUT (also when a click closed
# the app before its time). Run it in a home of its
# own: the clicks can delete what they reach (tests/smoke/run.sh does so).
# RETRO_SMOKE_SEED=n drives it another way (other clicks, other keys).

const
  smokeSettleMs = 4000            ## (the start: a splash, the first loads)
  smokeIdleMs = 3000              ## (left alone)
  smokeIdleFrames = 10            ## (most frames while left alone: a caret blinks 6 times in
                                  ## 3 s, a monitor's graph moves once a second -- a driver
                                  ## that draws twice for each, X11's before 0.36, is caught)
  smokeIdleCpu = 1.0              ## (most processor seconds while left alone: a third of one core)

proc smokeSeed(): uint32 =
  ## ($RETRO_SMOKE_SEED, else the run of always)
  let n = (try: parseUInt(getEnv("RETRO_SMOKE_SEED", "0")) except ValueError: 0'u)
  if n == 0: 0x9E3779B9'u32 else: uint32(n and 0xFFFF_FFFF'u)

var smoke = (secs: (try: parseInt(getEnv("RETRO_SMOKE", "0")) except ValueError: 0),
             start: getMonoTime(), idleFrom: MonoTime(), idleCpu0: 0.0,
             idleFrames: 0, idleShown: 0, idleCpu: 0.0, phase: 0, events: 0,
             seed: smokeSeed(), frames: 0, shown: -1, pressed: false)

proc smokeOn*(): bool = smoke.secs > 0
  ## A smoke run (RETRO_SMOKE) is going on.

when defined(windows):
  type SmokeFileTime = object
    lo, hi: uint32
  proc smokeProcessTimes(p: int; c, e, k, u: var SmokeFileTime): int32 {.
    importc: "GetProcessTimes", stdcall, dynlib: "kernel32".}
  proc smokeThisProcess(): int {.importc: "GetCurrentProcess", stdcall, dynlib: "kernel32".}

proc processSeconds(): float =
  ## (the processor's time this process has had, all its threads: on Windows
  ## from GetProcessTimes -- its C library's clock(), cpuTime's, is the time
  ## on the wall there)
  when defined(windows):
    var c, e, k, u: SmokeFileTime
    if smokeProcessTimes(smokeThisProcess(), c, e, k, u) == 0: return cpuTime()
    let ticks = (uint64(k.hi) shl 32 or uint64(k.lo)) + (uint64(u.hi) shl 32 or uint64(u.lo))
    float(ticks) / 1e7               # (100 ns each)
  else:
    cpuTime()

proc smokeRand(n: int): int =
  smoke.seed = smoke.seed xor (smoke.seed shl 13)
  smoke.seed = smoke.seed xor (smoke.seed shr 17)
  smoke.seed = smoke.seed xor (smoke.seed shl 5)
  int(smoke.seed mod uint32(max(1, n)))

proc smokeReport(closed = false): int =
  ## (the run's line, written; its exit code. `closed`: the app ended
  ## before the time was up -- a click reached its close box or Exit)
  if smoke.phase > 2: return 0
  smoke.phase = 3
  let faults = (if faultPath.len > 0 and fileExists(faultPath):
                  (try: readFile(faultPath) except IOError: "") else: "") & ui.lastFault
  let busy = smoke.idleFrames > smokeIdleFrames or smoke.idleCpu > smokeIdleCpu
  let line = (if ui.title.len > 0: ui.title else: "the app") & ": first frame " & $firstShownMs &
             " ms; untouched 3 s: " & $smoke.idleFrames & " frames (" & $smoke.idleShown & " shown), " &
             $int(smoke.idleCpu * 1000) & " ms of processor; " & $smoke.events & " events; " &
             (if faults.len > 0: "FAULT: " & faults.strip.splitLines[0] elif busy: "BUSY while untouched"
              elif closed: "ok (it closed itself: a click on Exit or its close box)"
              else: "ok")
  stderr.writeLine "smoke: ", line
  let outFile = getEnv("RETRO_SMOKE_OUT")
  if outFile.len > 0:
    try:
      var f: File
      if open(f, outFile, fmAppend):
        f.writeLine line
        f.close()
    except IOError, OSError: discard
  result = if faults.len > 0: 1 elif busy: 2 else: 0

proc smokeFinish() =
  quit(smokeReport())

proc smokeEvent(): Event =
  ## (something a person does: a move, a press or a let-go, the wheel, a key, a letter)
  let x = smokeRand(max(1, ui.w))
  let y = smokeRand(max(1, ui.h))
  if smoke.pressed:
    smoke.pressed = false
    return Event(kind: MouseUpEvent, x: ui.mx, y: ui.my, button: LeftButton)
  case smokeRand(10)
  of 0, 1: Event(kind: MouseMoveEvent, x: x, y: y)
  of 2, 3, 4:
    smoke.pressed = true
    Event(kind: MouseDownEvent, x: x, y: y, button: LeftButton, clicks: 1 + smokeRand(4) div 3)
  of 5: Event(kind: MouseWheelEvent, x: 0, y: smokeRand(7) - 3)
  of 6, 7:
    const keys = [KeyTab, KeyDown, KeyUp, KeyLeft, KeyRight, KeyEsc, KeySpace, KeyPageDown, KeyHome,
                  KeyEnd, KeyEnter, KeyEsc]
    Event(kind: KeyDownEvent, key: keys[smokeRand(keys.len)])
  else:
    var e = Event(kind: TextInputEvent)
    e.text[0] = char(ord('a') + smokeRand(26))
    e

proc smokeFrame() =
  ## (each frame of a smoke run: where it is, what it does now)
  if smoke.secs <= 0: return
  inc smoke.frames
  let ms = int((getMonoTime() - smoke.start).inMilliseconds)
  case smoke.phase
  of 0:
    if ms >= smokeSettleMs and firstShownMs >= 0:
      smoke.phase = 1
      smoke.idleFrom = getMonoTime()
      smoke.idleCpu0 = processSeconds()
      smoke.idleFrames = 0
      smoke.shown = -1                # (counted from the next frame: this one is shown yet)
      wakeIn(smokeIdleMs)             # (the measure's end: an app at rest wakes nothing itself)
    else:
      wakeIn(max(1, smokeSettleMs - ms))
  of 1:
    if smoke.shown < 0: smoke.shown = shownCount
    inc smoke.idleFrames
    let idle = int((getMonoTime() - smoke.idleFrom).inMilliseconds)
    if idle >= smokeIdleMs:
      smoke.idleCpu = processSeconds() - smoke.idleCpu0
      smoke.idleShown = shownCount - smoke.shown
      dec smoke.idleFrames            # (this frame is the measure's, not the app's)
      smoke.phase = 2
      wakeIn(15)
    else:
      wakeIn(smokeIdleMs - idle)
  else:
    if ms >= smoke.secs * 1000: smokeFinish()
    let e = smokeEvent()
    inc smoke.events
    if e.kind == KeyDownEvent:
      discard applyEvent(e)
      discard applyEvent(Event(kind: KeyUpEvent, key: e.key))
    else:
      discard applyEvent(e)
    wakeIn(15)

proc themeFromEnv*() =
  ## `RETRO_THEME` (a built-in theme's name, "OLED Black", or its number)
  ## overrides the colors chosen: for tests and screenshots.
  let t = getEnv("RETRO_THEME")
  if t.len == 0: return
  for i, b in builtinThemes:
    if cmpIgnoreCase(b.name, t) == 0 or $i == t:
      ui.theme = b.theme
      ui.force = true

type IconStyle* = enum
  ## How pixel icons are drawn: as they are (`isPixel`), as their line twins
  ## (`isLine`: Nerd Fonts symbols in the text's color), or line icons in a
  ## dark theme -- where black outlines would not show -- and pixels in a
  ## light one (`isAuto`, the default).
  isAuto, isPixel, isLine

var iconStyleSel = isAuto

proc setIconStyle*(s: IconStyle) =
  ## See `IconStyle`. `appearanceSettings` offers it; `storeAppearance` keeps it.
  if s != iconStyleSel:
    iconStyleSel = s
    ui.force = true

proc iconStyle*(): IconStyle = iconStyleSel
  ## The icon style chosen (see `setIconStyle`).

proc themeIsDark*(t: Theme): bool =
  ## Its windows and buttons dark (light text): Dark, OLED black.
  let l = (int(t.face.r) * 3 + int(t.face.g) * 6 + int(t.face.b)) div 10
  let w = (int(t.window.r) * 3 + int(t.window.g) * 6 + int(t.window.b)) div 10
  l < 100 and w < 100

proc applyIconStyle() =
  let on = case iconStyleSel
           of isAuto: themeIsDark(ui.theme)
           of isPixel: false
           of isLine: true
  setLineIcons(on, ui.theme.text)

proc frameReset() =
  ## (the input of the frame before forgotten)
  ui.pressed = false
  ui.released = false
  ui.rpressed = false
  ui.mpressed = false
  ui.navBack = false
  ui.navForward = false
  ui.menuKey = false
  ui.pressUsed = false
  ui.mouseMoved = false
  ui.wheel = 0
  ui.wheelX = 0
  if wheelShift:
    ui.mods.excl ShiftPressed
    wheelShift = false
  ui.pinch = 1
  ui.panDX = 0
  ui.panDY = 0
  ui.wheelUsed = false
  ui.doubleClick = false
  ui.key = KeyNone
  ui.keyUp = KeyNone
  ui.keyUsed = false
  ui.mnemonic = '\0'
  ui.altTapped = false
  ui.typed.setLen(0)
  dropFiles.setLen(0)
  globalHits.setLen(0)
  ui.closeCancelled = false

proc frameSetup(main: bool) =
  ## (the frame started, its input in: what the input means, the layout
  ## begun; `main`: the program's own window, else one besides it)
  # A sideways wheel (a tilted one, a touch pad's fingers, macOS's Shift +
  # the wheel) is Shift + the wheel, as Windows and X11 send that: what
  # scrolls sideways with Shift + the wheel scrolls with it, on every system
  if ui.wheelX != 0 and abs(ui.wheelX) >= abs(ui.wheel):
    ui.wheel = -ui.wheelX
    if ShiftPressed notin ui.mods:
      ui.mods.incl ShiftPressed
      wheelShift = true
  if ui.pressed: flingCaught = false      # (a new press: see `scrollCaught`)
  # (Alt+Space is the window's menu: the system's own with its frame -- a
  # title bar the app draws takes it in `captionBar`)
  if ui.key == KeySpace and AltPressed in ui.mods and not ui.ownCaption:
    ui.key = KeyNone
  # (the 3.1 frame picked in the menu of the system's -- which Alt+Space
  # opened, so that key is not the new frame's)
  if main and userFrameChoice and frameMenuItemChosen(): chooseClassicFrame(not ui.ownFrame)
  if uiFont() != layoutFont:
    layoutFont = uiFont()                  # the font changed: sizes follow it
    fitMetrics()
    ui.force = true
  if main: statT0 = getMonoTime()
  ui.now = getTicks()
  if main: accessFrameStart()
  mirrorW = if ui.rtl: ui.w else: 0
  # The menu key, or Shift+F10: a right click on the focused widget, so its
  # context menu opens there (lists put it on their current row)
  if (ui.key == KeyMenu or (ui.key == KeyF10 and ShiftPressed in ui.mods)) and
     ui.focus != 0 and ui.focusRect.w > 0:
    ui.key = KeyNone
    ui.menuKey = true
    ui.rpressed = true
    ui.mx = ui.focusRect.x + min(ui.focusRect.w div 2, dp(40))
    ui.my = ui.focusRect.y + min(ui.focusRect.h div 2, FontH)
  if ui.backPending:
    ui.backPending = false
    ui.closeAsked = true
    ui.byBackNow = ui.byBack
    ui.byBack = false
  else:
    ui.byBackNow = false
  # Touch: a finger that moves drags content (lists, text, panels) unless
  # the widget it pressed drags by itself (slider, scroll thumb); a finger
  # that rests half a second is a right click.
  ui.panX = 0
  ui.panY = 0
  ui.panUsed = false
  ui.panHanded = false
  if ui.pressed or not ui.mouseDown:
    ui.panOwner = 0                       # (a new gesture, or none: nobody's)
    ui.panAlong = 0
  elif ui.panOwner != 0 and ui.frameNo - ui.panOwnerSeen > 2:
    ui.panOwner = 0                       # (its scroller is no longer drawn)
  ui.lift = false
  if ui.fingerDown and ui.mouseDown and not ui.pressed:
    if not ui.panning and not ui.longFired and not ui.dragsActive and
       (abs(ui.my - ui.pressY) > 8 or abs(ui.mx - ui.pressX) > 8):
      ui.panning = true
      ui.active = 0
      ui.pressY = ui.panFrom.y
      ui.pressX = ui.panFrom.x
    if ui.panning:
      ui.panY = ui.pressY - ui.my
      ui.panX = ui.pressX - ui.mx
      ui.pressY = ui.my
      ui.pressX = ui.mx
      if ui.panAlong == 0 and (ui.panX != 0 or ui.panY != 0):
        ui.panAlong = if abs(ui.panX) > abs(ui.panY): 1 else: 2
    elif not ui.longFired and not ui.dragsActive:
      if ui.now - ui.pressAt >= 500:
        ui.longFired = true
        ui.rpressed = true
        ui.active = 0
        ui.longX = ui.mx
        ui.longY = ui.my
        ui.lifted = false
    elif ui.longFired and not ui.lifted and not ui.drag.active and
         (abs(ui.my - ui.longY) > dp(12) or abs(ui.mx - ui.longX) > dp(12)):
      # held, then moved: what was held is lifted to be dragged (its menu
      # closes); widgets that drag look at `lifted`
      ui.lifted = true
      ui.lift = true
      ui.popup = 0
      ui.menuOpen = false
  if ui.released:
    ui.panning = false
    ui.dragsActive = false
  inc ui.frameNo
  inc ui.gen
  ui.popupOpened = false
  ui.inputLayer =
    if ui.popup != 0: LayerPopup
    elif ui.dialogTop != 0: LayerDialog
    else: LayerBase
  swap(ui.tabOrder, ui.stopsBefore)        # (last frame's stops kept: `focusInControls`)
  ui.tabOrder.setLen(0)
  ui.stopArea.setLen(0)
  ui.stopIndex.setLen(0)
  ui.nextTabIndex = 0
  ui.anyTabIndex = false
  ui.notFirst.setLen(0)
  inBarNow = false
  ui.areaStack.setLen(0)
  ui.areaNow = 0
  ui.menuFirst = 0
  ui.focusSeen = false
  ui.hot = 0
  ui.dialogTopNow = 0
  ui.curDialog = 0
  ui.popupRectNow = rect(0, 0, 0, 0)
  ui.popupRect2Now = rect(0, 0, 0, 0)
  ui.overlay = ui.overlayNow
  ui.overlayLayer = ui.overlayLayerNow
  ui.overlayNow = rect(0, 0, 0, 0)
  ui.cursor = curArrow
  # a frame asked for (`wakeIn`) still comes when frames ran in between
  if ui.wakeAt <= ui.now: ui.wakeAt = 0
  # the 3.1 frame: its border is a margin all round (none while maximized),
  # its title bar and the line under it are over the bars; full screen, none
  let full = windowFullScreen()
  ui.frameBorder = if ui.ownFrame and not full and not windowMaximized(): dp(FrameDesignBorder) else: 0
  let fb = ui.frameBorder
  ui.safe = (ui.layoutSafe.top + fb, ui.layoutSafe.left + fb,
             ui.layoutSafe.bottom + fb, ui.layoutSafe.right + fb)
  ui.bottom = ui.h - ui.safe.bottom
  ui.captionH = if ui.ownFrame: (if full: 0 else: MenuH + 1)
                elif ui.ownCaption: (if fingers(): CtrlH else: MenuH)
                else: 0
  ui.barY = ui.safe.top + ui.captionH
  ui.takesEnter = false
  ui.takesText = false
  ui.tip.setLen(0)
  ui.idStack.setLen(0)
  ui.blockers.setLen(0)
  # (after the frame's state is reset: what the hooks ask for -- a wake-up,
  # a redraw -- stays)
  if main:
    for hook in beginFrameHooks: hook()
  # a press for a `fileDragSource` is this frame's or none; a drag of the
  # toolkit's that left the window with files for other programs is the
  # system's from here (`startDrag`'s `files`)
  if ui.pressed or not ui.mouseDown: outArm.on = false
  if ui.drag.active and ui.drag.files != nil and ui.mouseDown and not ui.released and
     ui.mouseMoved and not ui.fingerDown and
     (ui.mx < 0 or ui.my < 0 or ui.mx >= ui.w or ui.my >= ui.h) and canDragFilesOut():
    dragLeftWindow()
  # a drag ends when the button is let go (the targets look this frame)
  ui.dragOver = false
  if ui.drag.active and (ui.released or not ui.mouseDown):
    ui.dragDropping = true
  beginDraw(ui.w, ui.h, ui.theme.window)
  ui.frames.setLen(0)
  let left = ui.safe.left + Pad
  let topY = ui.safe.top + ui.captionH + Pad
  ui.contentTop = topY
  # content taller than the window scrolls (`pageY`) under the fixed bars
  let barW = if ui.pageOn: SbW else: 0           # (the standard bar, fingers too)
  let y0 = topY - ui.pageY
  ui.contentRight = 0
  clippedDepth = 0
  ui.frames.add LFrame(kind: lkCol, x: left - ui.pageX, y: y0, dy: ui.pageY,
                       w: max(10, ui.w - ui.safe.left - ui.safe.right - 2*Pad - barW),
                       cx: left - ui.pageX, cy: y0, bottom: y0)
  if ui.pageOn or ui.pageMaxX > 0: pushClip(ui.pageView)
  if ui.fingerDown and ui.mouseDown and not ui.longFired and not ui.panning and
     not ui.dragsActive:
    wakeIn(ui.pressAt + 501 - ui.now)

proc beginFrame*(): bool =
  ## Wait for input (or a timer) and start a frame. False once the app ends.
  if not ui.running: return false
  applyIconStyle()
  frameReset()
  let busy = (ui.redraw or ui.force) and not ui.paused
  let waitMs =
    if busy: 0
    elif ui.wakeAt > 0 and not ui.paused: max(1, ui.wakeAt - getTicks())
    else: -1
  ui.redraw = false
  frameEvents = 0
  pump(waitMs)
  if whyFrames:
    frameCause =
      if frameEvents > 0: $frameEvents & (if frameEvents == 1: " input event" else: " input events")
      elif busy and ui.force: "drawn anew (the window, the theme)"
      elif busy: "ui.redraw = true at " & redrawSite.file & ":" & $redrawSite.line
      elif polledAwake: "a poller (idlePollers): something came from outside"
      elif waitMs >= 0 and wakeSite.file.len > 0: "wakeIn at " & wakeSite.file & ":" & $wakeSite.line
      elif waitMs >= 0: "wakeIn (asked before the inspector was shown)"
      else: "the system (the window shown, sized or put back)"
    redrawSite = ("", 0)
  if ui.rpressAgain:
    # (a right click that closed an open menu: the next one opens where it was)
    ui.rpressAgain = false
    ui.rpressed = true
  ui.popupBefore = ui.popup
  frameSetup(true)
  if startMark.len > 0: startMarkFrame()
  if smoke.secs > 0: smokeFrame()
  true

proc frameWaitMs*(): int =
  ## How long until the next frame is wanted (0: at once; -1: only when
  ## something happens) -- what `beginFrame` waits for, for a loop that
  ## is not this one's: a browser page's (`webFrames`).
  if not ui.running: -2
  elif (ui.redraw or ui.force) and not ui.paused: 0
  elif ui.wakeAt > 0 and not ui.paused: max(1, ui.wakeAt - getTicks())
  else: -1

when defined(wasm):
  from uirelays/drivers/web_driver import webEventsWaiting
  var webFrame: proc () {.closure.}

  proc webFrames*(frame: proc () {.closure.}) =
    ## A browser page's loop: `frame` (`beginFrame` .. `endFrame`) is run
    ## by the page (`retro_frame`) when something happened or the last
    ## frame asked for another, not in a loop of the program's.
    webFrame = frame

  proc webFrameNow(): cint {.exportc: "retro_frame", cdecl.} =
    ## (the page's: one frame; when the next is wanted, `frameWaitMs`)
    ## -3: an error nobody caught ended it (as it ends a program anywhere:
    ## its message and where it came from on stderr, the page's console)
    if webFrame == nil: return -2
    try:
      webFrame()
    except CatchableError, Defect:
      let e = getCurrentException()
      stderr.writeLine e.getStackTrace() & "Error: unhandled exception: " & e.msg & " [" & $e.name & "]"
      webFrame = nil
      return -3
    result = cint(frameWaitMs())
    if result != -2 and webEventsWaiting(): result = 0

proc cancelClose*() =
  ## Keep running although the user asked to close the window.
  ui.closeCancelled = true

proc requestClose*() =
  ## Ask to close, as the window's close button does: the next frame's
  ## `closeRequested` is true, so the app can still ask "Save changes?".
  ui.backPending = true
  ui.redraw = true

proc setTitle*(title: string) =
  ## The window's title (the title bar on phones).
  if title != ui.title:
    ui.title = title
    setWindowTitle(title)
    ui.redraw = true

proc closeRequested*(): bool = ui.closeAsked
  ## The user asked to close the window this frame; call `cancelClose` to
  ## keep the app running (to ask "Save changes?", say).

proc backPressed*(): bool = ui.closeAsked and ui.byBackNow
  ## The close request of this frame is the phone's Back button (not a
  ## close button or an Exit command): apps that go back through screens
  ## or folders take it with `cancelClose` and go back.

proc quitApp*() = ui.running = false
  ## Ends the app: `beginFrame` is false from the next frame on.

proc appRunning*(): bool = ui.running
  ## The app has not ended (`quitApp`, its window closed).

proc themeIndex*(): int =
  ## Which of `builtinThemes` is in use (-1: a theme of the app's own).
  result = -1
  for i, t in builtinThemes:
    if t.theme == ui.theme: return i

proc invalidate*() =
  ## Redraw the whole window on the next frame, and run that frame now.
  ui.force = true

proc drawTip() =
  ui.tipKey = if ui.tip.len == 0: 0'u32
              else: fnv(ui.tip, uint32(ui.lastRect.x * 31 + ui.lastRect.y))
  if ui.tipKey != ui.prevTipKey:
    ui.prevTipKey = ui.tipKey
    ui.hoverSince = ui.now
  if ui.tip.len == 0 or ui.active != 0 or ui.mouseDown: return
  if ui.now - ui.hoverSince < 600:
    wakeIn(600 - (ui.now - ui.hoverSince))
    return
  pushLayer(LayerTip)
  let tipText = tr(ui.tip)
  let w = textWidth(tipText) + 8
  let tipH = FontH + 4
  var x, y: int
  if (androidApp or defined(ios) or ui.touch) and ui.my - tipH - dp(12) >= 0:
    # a tablet's or a phone's pointer (drawn by the system, big; or a
    # finger): the tip above it, where nothing covers it
    x = ui.mx - w div 2
    y = ui.my - tipH - dp(12)
  else:
    # a desktop's: under its arrow, as Windows puts it -- as far down as the
    # pointer is drawn (a bigger pointer, a scaled display: further)
    let ph = if windowRelays.pointerHeight != nil: windowRelays.pointerHeight() else: 0
    let under = if ph > 0: ph * 3 div 4 + 4 else: max(20, dp(22))
    x = ui.mx
    y = ui.my + (if androidApp or defined(ios) or ui.touch: dp(40) else: max(under, dp(22)))
    if y + tipH > ui.h: y = ui.my - tipH - dp(10)
  x = clamp(x, 0, max(0, ui.w - w))
  let r = rect(x, y, w, tipH)
  fill(r, ui.theme.tip)
  box(r, ui.theme.edge)
  text(x + 4, y + 2, tipText, ui.theme.tipText)
  popLayer()

var pageBar*, pageBarX*: proc (view: Rect; v: var int; hi: int): bool {.nimcall.}
  ## Draw the window's scroll bars (set by the widgets module).


proc endPage() =
  ## The window's content: taller than the window, it scrolls.
  if ui.frames.len == 0: return
  resetClip()
  let f = ui.frames[0]
  # wider than the window (rows of fixed widths): a scroll bar along the
  # bottom too
  let room = ui.w - ui.safe.right - Pad - (if ui.pageOn: SbW else: 0)
  let overX = ui.contentRight - room
  let wasX = ui.pageMaxX > 0
  ui.pageMaxX = if overX > 0 or (wasX and overX > -SbW and ui.pageX > 0): max(1, overX) else: 0
  let hbarH = if ui.pageMaxX > 0: SbW else: 0
  let view = rect(0, ui.barY, ui.w, max(0, ui.bottom - hbarH - ui.barY))
  let over = f.bottom + ui.pageY + Pad - (ui.bottom - hbarH)
  let was = ui.pageOn
  ui.pageOn = over > 0 or (was and over > -SbW and ui.pageY > 0)
  ui.pageMax = max(0, over)
  ui.pageView = view
  var y = ui.pageY
  var x = ui.pageX
  const pageIdY = Id(0x9a6e5c90'u32)
  const pageIdX = Id(0x9a6e5c91'u32)
  let hiY = if ui.pageOn: ui.pageMax else: 0
  if (ui.pageOn or ui.pageMaxX > 0) and ui.inputLayer == LayerBase and ui.popup == 0:
    let m = point(ui.mx, ui.my)
    if ui.wheel != 0 and not ui.wheelUsed and view.contains(m):
      # (the page is around everything: it takes what was left, latched or not)
      if ShiftPressed in ui.mods or not ui.pageOn:      # Shift + the wheel: sideways
        scrollBy(pageIdX, x, -ui.wheel * 3 * ItemH, ui.pageMaxX)
        noteWheel(pageIdX, true)
      else:
        scrollBy(pageIdY, y, -ui.wheel * 3 * ItemH, hiY)
        noteWheel(pageIdY)
      ui.wheelUsed = true
    # a finger drags the page both ways (and a flick goes on)
    scrollPan2(pageIdY, y, hiY, pageIdX, x, ui.pageMaxX, view)
    if not ui.keyUsed and not ui.prevTakesText:
      if ui.key == KeyPageDown: scrollBy(pageIdY, y, view.h - 2 * ItemH, hiY)
      elif ui.key == KeyPageUp: scrollBy(pageIdY, y, -(view.h - 2 * ItemH), hiY)
      elif ui.key == KeyHome and CtrlPressed in ui.mods: scrollTo(pageIdY, y, 0, hiY)
      elif ui.key == KeyEnd and CtrlPressed in ui.mods: scrollTo(pageIdY, y, ui.pageMax, hiY)
  scrollTick(pageIdY, y, hiY)
  scrollTick(pageIdX, x, ui.pageMaxX)
  if (ui.pageOn or ui.pageMaxX > 0) and ui.inputLayer == LayerBase and ui.popup == 0:
    let r = wantSeen()
    if r.w > 0:
      # (focused last frame, drawn now; or a screen reader asked to see it)
      if r.y < view.y: y -= view.y + Pad - r.y
      elif r.y + r.h > view.y + view.h: y += r.y + r.h + Pad - (view.y + view.h)
      if ui.pageMaxX > 0:                  # ... and sideways
        let right = ui.w - ui.safe.right - (if ui.pageOn: SbW else: 0)
        if r.x < ui.safe.left: x -= ui.safe.left + Pad - r.x
        elif r.x + r.w > right: x += r.x + r.w + Pad - right
  y = clamp(y, 0, ui.pageMax)
  x = clamp(x, 0, ui.pageMaxX)
  if ui.pageOn or ui.pageMaxX > 0:
    # the standard 3.1 scroll bars, on touch screens too (where a finger can
    # also drag the content itself)
    pushLayer(LayerBase)
    # (the frame's size grip keeps its corner: a bar that would reach it
    # stops short, as the two bars stop at the corner between them)
    let grip = sizeGrip()
    if ui.pageOn and pageBar != nil:
      var bar = rect(ui.w - ui.safe.right - SbW, view.y, SbW, view.h)
      if grip.h > 0 and ui.pageMaxX == 0 and bar.y + bar.h > grip.y:
        bar.h = max(0, grip.y - bar.y)
      discard pageBar(bar, y, ui.pageMax)
    if ui.pageMaxX > 0 and pageBarX != nil:
      var bar = rect(ui.safe.left, view.y + view.h,
                     ui.w - ui.safe.left - ui.safe.right - (if ui.pageOn: SbW - 1 else: 0), SbW)
      if grip.w > 0 and not ui.pageOn and bar.y + bar.h > grip.y and bar.x + bar.w > grip.x:
        bar.w = max(0, grip.x - bar.x)
      discard pageBarX(bar, x, ui.pageMaxX)
      if ui.pageOn:                        # the corner between the two bars
        fill(rect(bar.x + bar.w, bar.y, SbW - 1, SbW), ui.theme.face)
    popLayer()
  if y != ui.pageY or ui.pageOn != was or x != ui.pageX or (ui.pageMaxX > 0) != wasX:
    ui.pageY = y
    ui.pageX = x
    ui.redraw = true

proc drawDragGhost() =
  ## What is dragged, at the pointer: a glyph, a label, "+" when it copies.
  if not ui.drag.active: return
  if ui.key == KeyEsc and not ui.keyUsed:
    ui.keyUsed = true
    ui.drag = DragInfo()
    ui.redraw = true
    return
  pushLayer(LayerTip)
  let copy = CtrlPressed in ui.mods
  var s = ui.drag.label
  if ui.drag.glyph.len > 0: s = ui.drag.glyph & "  " & s
  if copy and ui.dragOver: s = "+ " & s
  let w = min(textWidth(s) + 16, max(40, ui.w div 2))
  let h = FontH + 8
  var x = ui.mx + 14
  var y = ui.my + 16
  if ui.fingerDown: y = max(0, ui.my - h - dp(28))   # above the finger, not under it
  if x + w > ui.w: x = max(0, ui.mx - w - 4)
  if y + h > ui.h: y = max(0, ui.my - h - 4)
  let r = rect(x, y, w, h)
  fill(rect(r.x + 2, r.y + 2, r.w, r.h), ui.theme.shadow)
  fill(r, if ui.dragOver: ui.theme.select else: ui.theme.face)
  box(r, ui.theme.frame)
  pushClip(inset(r, 2))
  text(r.x + 8, r.y + 4, s, if ui.dragOver: ui.theme.selectText else: ui.theme.text)
  popClip()
  popLayer()

proc areaKeys(at: int) =
  ## (F6 and Shift+F6: the next area's control, or the previous one's --
  ## its tool bars, panes, panels; the drawing of an app whose keys are its
  ## own when nothing is focused (`autoFocus` off); the menu bar's first
  ## menu after the last area. `at`: the focused stop's place in Tab's order.)
  if ui.areaWanted == 0 and
     (ui.key != KeyF6 or ui.keyUsed or ui.mods * {CtrlPressed, AltPressed, GuiPressed} != {} or
      ui.dialogTopNow != 0 or ui.inputLayer != LayerBase and not ui.menuOpen):
    return
  let back = if ui.areaWanted != 0: ui.areaWanted < 0 else: ShiftPressed in ui.mods
  if ui.menuOpen and ui.popup != 0:
    ui.keyUsed = true
    # (an open menu of the bar: closed, and the area after it next frame --
    # the menu's frame has no stops of the window)
    ui.popup = 0
    ui.menuOpen = false
    ui.areaWanted = if back: -1 else: 1
    ui.redraw = true
    return
  # the areas in the order Tab meets them; 1: the drawing (focus 0); 2: the menu bar
  const Canvas = Id(1)
  const Bar = Id(2)
  var areas: seq[Id]
  if not autoFocus: areas.add Canvas
  for a in ui.stopArea:
    if a notin areas: areas.add a
  if ui.menuFirst != 0: areas.add Bar
  if areas.len == 0 or areas.len < 2 and ui.areaWanted == 0:
    ui.areaWanted = 0
    return
  if ui.areaWanted == 0: ui.keyUsed = true
  let here = if ui.areaWanted > 0: areas.len - 1     # (from the menu bar: the first)
             elif ui.areaWanted < 0: (if ui.menuFirst != 0: areas.len - 1 else: 0)
             elif at >= 0: areas.find(ui.stopArea[at])
             elif not autoFocus: 0
             else: -1
  ui.areaWanted = 0
  let n = areas.len
  let next = if here < 0: (if back: n - 1 else: 0)
             elif back: (here + n - 1) mod n
             else: (here + 1) mod n
  let a = areas[next]
  ui.redraw = true
  if a == Bar:
    ui.popup = ui.menuFirst
    ui.menuOpen = true
    ui.popupHi = 0
    ui.popupOpened = true
  elif a == Canvas:
    ui.focus = 0
  else:
    var to = areaLast.getOrDefault(a)
    var found = false
    for i, s in ui.tabOrder:
      if ui.stopArea[i] == a and s == to: found = true
    if not found:
      for i, s in ui.tabOrder:
        if ui.stopArea[i] == a and s notin ui.notFirst:
          to = s
          found = true
          break
    if not found:
      to = ui.tabOrder[ui.stopArea.find(a)]
    ui.focus = to
    ui.focusMoved = ui.frameNo
    ui.focusByKeys = true
    ui.spaceDown = false

proc frameFinish(main: bool) =
  ## (the frame's end before it is shown: focus, popups, dialogs, the
  ## close asked; `main`: the program's own window)
  if main:
    for hook in endFrameHooks: hook()
  # What a key or a click changed late in the frame (after the widgets that
  # show it were drawn) appears on one more frame. (When nothing asked for
  # it -- a letter typed into a box, which shows it at once -- this frame is
  # shown at once, and the next one only if it differs.)
  ui.inputOnly = false
  if ui.keyUsed or ui.pressed or ui.released or ui.wheelUsed or ui.typed.len > 0 or
     dropFiles.len > 0:
    ui.inputOnly = not ui.redraw and main
    ui.redraw = true
  if ui.drag.active:
    if ui.dragDropping:
      ui.drag = DragInfo()
      ui.dragDropping = false
      ui.dragClaimed = false
      ui.redraw = true
    else:
      drawDragGhost()
  endPage()
  orderStops()
  # Tab and Shift+Tab move the focus through the widgets of the top layer.
  if ui.tabOrder.len > 0:
    var at = -1
    for i, id in ui.tabOrder:
      if id == ui.focus: at = i
    if ui.key == KeyTab and not ui.keyUsed:
      let n = ui.tabOrder.len
      let next = if at < 0: 0
                 elif ShiftPressed in ui.mods: (at + n - 1) mod n
                 else: (at + 1) mod n
      ui.focus = ui.tabOrder[next]
      ui.focusMoved = ui.frameNo
      ui.focusByKeys = true
      ui.spaceDown = false
      ui.redraw = true
    elif at < 0 and not ui.focusSeen and not ui.touch and
         (autoFocus or ui.dialogTopNow != 0) and ui.areaWanted == 0 and
         not (ui.key == KeyF6 and not ui.keyUsed):
      # (a touch screen focuses nothing on its own: a text box with the
      # focus would bring up the on-screen keyboard; a widget that has the
      # focus and answered without being a stop of Tab keeps it; the first
      # that is not a tool bar's)
      for s in ui.tabOrder:
        if s notin ui.notFirst:
          ui.focus = s
          ui.redraw = true
          break
    if at >= 0 and ui.stopArea[at] != 0 and ui.focus == ui.tabOrder[at] and
       areaLast.getOrDefault(ui.stopArea[at]) != ui.focus:
      areaLast[ui.stopArea[at]] = ui.focus
    areaKeys(at)
  elif ui.areaWanted != 0 or ui.key == KeyF6:
    areaKeys(-1)
  # A press outside an open popup closes it; a right click outside, too --
  # and is given again on the next frame, so the menu of what it is on opens
  # (one right click to another place, as a desktop's menus do).
  if ui.popup != 0:
    let p = point(ui.mx, ui.my)
    let outside = not ui.popupRectNow.contains(p) and not ui.popupRect2Now.contains(p)
    if (ui.popupRectNow.w == 0 and not ui.popupOpened) or
       (ui.pressed and not ui.pressUsed and outside) or
       (ui.rpressed and outside and ui.popupBefore == ui.popup and not ui.touch):
      # (not the right click that opened it, this frame)
      if ui.rpressed and outside and ui.popupBefore == ui.popup: ui.rpressAgain = true
      ui.popup = 0
      ui.menuOpen = false
      ui.redraw = true
  ui.popupRect = ui.popupRectNow
  # Dialogs: the focus goes into a new one and comes back when it closes.
  if ui.dialogTopNow != ui.dialogTop:
    if ui.dialogTop == 0: ui.focusBeforeDialog = ui.focus
    if ui.dialogTopNow == 0: ui.focus = ui.focusBeforeDialog
    else: ui.focus = 0
    ui.dialogTop = ui.dialogTopNow
    ui.redraw = true
  if ui.released or not ui.mouseDown and ui.active != 0 and not ui.spaceDown:
    ui.active = 0
  ui.prevHot = ui.hot
  # Ctrl with +, - and 0 (or the wheel) makes everything bigger or smaller
  if CtrlPressed in ui.mods and not ui.keyUsed:
    case ui.key
    of KeyEqual, KeyPlus: setUiScale(scaleStep(1))
    of KeyMinus: setUiScale(scaleStep(-1))
    of Key0: setUiScale(100)
    of KeyW:
      # (macOS: Cmd+W closes the window, as the menu bar's Close, when
      # nothing in it took the key -- a tab closes first)
      when defined(macosx) and not defined(ios):
        if ui.mods * {ShiftPressed, AltPressed, GuiPressed} == {}: requestClose()
    else: discard
  if ui.cursor != ui.shownCursor and not ui.touch:
    ui.shownCursor = ui.cursor
    setCursor(ui.cursor)
  drawTip()
  ui.prevTakesEnter = ui.takesEnter
  ui.prevTakesText = ui.takesText
  ui.prevBottom = ui.bottom
  if (ui.frameNo and 1023) == 0:
    var gone: seq[Id]
    for id, st in ui.states:
      if ui.frameNo - st.seen > 1024: gone.add id
    for id in gone: ui.states.del id
  # The back button of a phone (Esc) that nothing used asks to close, in
  # the next frame, where the app can still say no (`closeRequested`).
  # iPhones have no back button, and their apps do not close themselves.
  if ui.touch and ui.key == KeyEsc and not ui.keyUsed and not defined(ios):
    ui.backPending = true
    ui.byBack = true
    ui.redraw = true
  if ui.closeAsked and not ui.closeCancelled: ui.running = false
  ui.closeAsked = false
  if main: accessFrameEnd()

proc endFrame*() =
  ## Finish the frame: keyboard focus, popups, tooltips, then put it on
  ## screen (only if it changed).
  frameFinish(true)
  # Present -- unless another frame is due right away anyway (one that
  # shows what changed late in this one); the frame after an input that
  # nothing else asked to draw again is shown at once.
  if ui.redraw and ui.redrawCount < 3 and not ui.inputOnly:
    inc ui.redrawCount
    noteFrame(false)
    return
  if ui.inputOnly: ui.redrawCount = 0     # (the next frame comes: `redraw` kept)
  else:
    ui.redraw = false
    ui.redrawCount = 0
  # (events waiting: shown with the next frame -- not the one after an input,
  # which is shown now, the next event left for the frame it brings)
  if not hasPending and not ui.inputOnly:
    hasPending = pollEvent(pending,
      if ui.prevTakesText: {WantTextInput} else: {})
  if hasPending and not ui.inputOnly and ui.now - ui.lastPresent < 50:
    noteFrame(false)
    return
  if ui.paused or ui.hidden: return     # (nobody sees it: not drawn)
  if present(ui.devW, ui.devH, ui.force):
    ui.lastPresent = ui.now
  ui.force = false
  noteFrame(true)

var stopAppHooks*: seq[proc () {.nimcall.}]
  ## Run first in `stopApp`, while the window is still there: what a module
  ## must end before the app does (a thread of its own, windows of the
  ## system's inside the app's).

# ---- windows besides the program's own ----------------------------------------------------------
#
# A window of the system's of its own (`window` in `widgets`): its frame
# runs in the middle of the program's, at the place the app draws it, with
# a `ui` and a drawing of its own swapped in (nothing copied), the events
# the driver gave it, and its pixels sent to it (`windowsRelays.target`).
# The settings everybody shares (the theme, sizes, the scale) are the
# program's window's.

type
  KitWindow = ref object
    id: int                    ## the driver's number for it
    ctx: Ctx                   ## its `ui` (the program's while its frame runs)
    draw: FrameState           ## its drawing (the program's while its frame runs)
    events: seq[Event]         ## what came for it, waiting for its frame
    title: string
    seen: int                  ## the program's frame it was drawn in

var
  kitWindows: Table[string, KitWindow]
  curWindow: KitWindow
  windowsFailed = false
  windowHooked = false

proc windowsAvailable*(): bool =
  ## The system shows windows besides the program's own (X11, Wayland,
  ## Windows, macOS); elsewhere `window` is a dialog over the app.
  windowsRelays.openWindow != nil and windowsRelays.target != nil and not windowsFailed and
    not androidApp and not defined(ios)

proc routeToWindow(e: Event) =
  for _, w in kitWindows:
    if w.id == e.window:
      if e.kind == MouseMoveEvent and w.events.len > 0 and w.events[^1].kind == MouseMoveEvent:
        w.events[^1] = e
      else: w.events.add e
      ui.redraw = true
      return

proc shareSettings(dst: var Ctx; src: Ctx) =
  ## (what the windows share: the program's window's)
  dst.theme = src.theme
  dst.m = src.m
  dst.metricsSet = src.metricsSet
  dst.touch = src.touch
  dst.sizes = src.sizes
  dst.roomy = src.roomy
  dst.k = src.k
  dst.density = src.density
  dst.uiScale = src.uiScale
  dst.textScale = src.textScale
  dst.baseEm = src.baseEm
  dst.rtl = src.rtl
  dst.paused = src.paused

proc closeKitWindow(key: string) =
  let w = kitWindows.getOrDefault(key)
  if w == nil: return
  if windowsRelays.closeWindow != nil: windowsRelays.closeWindow(w.id)
  kitWindows.del key

proc windowsFrame() {.nimcall.} =
  ## Windows not drawn in the program's frame before close (their `window`
  ## was not reached: the app closed them by not drawing them).
  var gone: seq[string]
  for k, w in kitWindows:
    if w.seen < ui.frameNo - 1: gone.add k
  for k in gone: closeKitWindow(k)

proc windowsEnd() {.nimcall.} =
  var all: seq[string]
  for k in kitWindows.keys: all.add k
  for k in all: closeKitWindow(k)

proc beginWindow*(open: var bool; title: string; w, h: int; key = ""): bool =
  ## Starts the frame of a window besides the program's own (see `window`
  ## in `widgets`), `w` x `h` design pixels when it opens; true while it is
  ## `open` and the system has it. Its `ui` is the window's until
  ## `endWindow`.
  let k = if key.len > 0: key else: title
  if not open:
    closeKitWindow(k)
    return false
  if curWindow != nil or not windowsAvailable(): return false
  if not windowHooked:
    windowHooked = true
    beginFrameHooks.add windowsFrame
    stopAppHooks.add windowsEnd
  var win = kitWindows.getOrDefault(k)
  if win == nil:
    let id = windowsRelays.openWindow(title, dp(w) * zoom, dp(h) * zoom)
    if id == 0:
      windowsFailed = true
      return false
    win = KitWindow(id: id, title: title)
    win.ctx.running = true
    win.ctx.title = title
    win.ctx.w = dp(w)
    win.ctx.h = dp(h)
    win.ctx.devW = dp(w) * pxScale
    win.ctx.devH = dp(h) * pxScale
    win.ctx.force = true
    win.ctx.theme = ui.theme
    win.draw.extra = true
    kitWindows[k] = win
  elif title != win.title:
    win.title = title
    if windowsRelays.setTitle != nil: windowsRelays.setTitle(win.id, title)
  win.seen = ui.frameNo
  # its frame, in place of the program's
  windowsRelays.target(win.id)
  swap(ui, win.ctx)
  shareSettings(ui, win.ctx)
  swapFrameState(win.draw)
  curWindow = win
  # (a window the system draws no frame round: a title bar of its own)
  ui.ownCaption = windowsRelays.framed != nil and not windowsRelays.framed(win.id)
  frameReset()
  var used = 0
  for e in win.events:
    inc used
    case e.kind
    of WindowResizeEvent, WindowMetricsEvent:
      # (its own size: the scale is the program's window's)
      ui.devW = e.x * unitPx
      ui.devH = e.y * unitPx
      ui.w = e.x div zoom
      ui.h = e.y div zoom
      ui.force = true
    else:
      if applyEvent(e): break
  if used > 0: win.events = win.events[used .. ^1]
  if win.events.len > 0: ui.redraw = true
  frameSetup(false)
  true

proc endWindow*(): bool {.discardable.} =
  ## Ends the frame `beginWindow` started and shows it; true when the user
  ## closed the window (its close button) in it.
  let win = curWindow
  if win == nil: return false
  frameFinish(false)
  if present(ui.devW, ui.devH, ui.force): ui.lastPresent = ui.now
  ui.force = false
  result = not ui.running
  ui.running = true
  let again = ui.redraw
  let wake = ui.wakeAt
  ui.redraw = false
  swapFrameState(win.draw)
  swap(ui, win.ctx)
  windowsRelays.target(0)
  curWindow = nil
  # (what the window asked for -- another frame, a wake-up -- is the
  #  program's, whose frames run its)
  if again: ui.redraw = true
  if wake > 0 and (ui.wakeAt == 0 or wake < ui.wakeAt): ui.wakeAt = wake
  if result: closeKitWindow(block:
    var key = ""
    for k, w in kitWindows:
      if w == win: key = k
    key)

proc inWindow*(): bool = curWindow != nil
  ## A window besides the program's own is being drawn (between
  ## `beginWindow` and `endWindow`).


proc stopApp*() =
  ## Closes the window and ends the app (`app` calls it when its loop ends).
  if startMark.len > 0:
    try: removeFile(startMark)          # (ended well: no stop at the start)
    except OSError: discard
  if smoke.secs > 0:
    # (a smoke run's app closed by a click: its line still written, and a
    # fault or a busy rest still its exit code)
    let code = smokeReport(closed = true)
    if code != 0:
      for h in stopAppHooks: h()
      shutdown()
      quit(code)
  for h in stopAppHooks: h()
  shutdown()
