## Accessibility: what a window shows, as a tree of controls a screen reader
## reads (Orca, NVDA, Narrator, VoiceOver, TalkBack), and what it asks back.
##
## A program that draws its own controls fills the tree after each frame
## (`accessUpdate`); the driver hands it to the system's accessibility
## service and puts what the screen reader asks for (press this button, put
## this text in that box) into `accessRequests`, waking the program. The
## tree is wanted only while a screen reader listens: `accessListening`
## says so, and a program builds nothing otherwise.
##
## Every relay is optional: a driver without them has no screen reader
## support, and costs nothing.

type
  AccessRole* = enum
    ## What a node is, as screen readers name them.
    arWindow,          ## the window (the tree's root)
    arPane,            ## a part of the window: a panel, a scrolling area
    arGroup,           ## a group box, its controls inside
    arLabel,           ## text that only shows
    arButton,          ## a push button, a tool bar button
    arToggleButton,    ## a button that stays pressed in
    arCheckBox,
    arRadioButton,
    arTextField,       ## a one-line text box
    arTextArea,        ## a text box of several lines
    arPasswordField,
    arComboBox,        ## a drop-down list
    arList,
    arListItem,
    arSlider,
    arSpinButton,      ## a number box with arrows
    arProgressBar,
    arScrollBar,
    arMenuBar,
    arMenu,
    arMenuItem,
    arToolBar,
    arStatusBar,
    arTabList,
    arTab,
    arTree,
    arTreeItem,
    arTable,           ## a grid of rows and columns
    arRow,
    arCell,
    arColumnHeader,
    arDialog,
    arLink,
    arImage,
    arHeading,
    arSeparator,
    arToolTip,
    arAlert            ## a message the user should hear at once

  AccessState* = enum
    asFocusable,       ## takes the keyboard focus
    asFocused,
    asDisabled,
    asChecked,
    asMixed,           ## a check box neither on nor off
    asSelected,
    asExpandable,
    asExpanded,
    asReadOnly,
    asDefault,         ## the button Enter presses
    asPressed,         ## a toggle button pressed in
    asMultiLine,
    asProtected,       ## a password: its text is not read out
    asModal            ## a dialog the rest waits for

  AccessAction* = enum
    ## What a screen reader asks a node to do.
    aaPress,           ## click it (a button, a check box, a menu item, a list item)
    aaFocus,           ## give it the keyboard focus
    aaSetValue,        ## put `text` (or `num`) into it
    aaIncrement,       ## a step up (a slider, a spin box)
    aaDecrement,
    aaExpand,          ## open it (a drop-down, a tree item)
    aaCollapse,
    aaShowMenu,        ## its context menu
    aaScrollIntoView,
    aaSetCaret         ## the caret of its text at `num` (characters)

  AccessNode* = object
    ## One control (or part of the window) as screen readers see it.
    id*: uint32                ## the same from frame to frame while it is shown
    parent*: int32             ## the parent's index in the tree; -1: the root
    role*: AccessRole
    name*: string              ## what it is called (a button's label, the label before a text box)
    value*: string             ## what it holds (a text box's text, a slider's value as text)
    help*: string              ## more about it (its tooltip)
    states*: set[AccessState]
    x*, y*, w*, h*: int        ## where it is, in the window's pixels (as the driver's events)
    lo*, hi*, now*, step*: float  ## a slider's, a spin box's, a progress bar's range and value
    caret*, selA*, selB*: int  ## a text's caret and selection, in characters
    pos*, count*: int          ## an item's place in its list (1-based) and how many there are
    level*: int                ## a tree item's depth (1: at the top)
    key*: string               ## its keyboard shortcut ("Alt+F", "Ctrl+S")

  AccessRequest* = object
    ## What a screen reader asked, for the next frame to do.
    action*: AccessAction
    id*: uint32
    text*: string
    num*: float

  AccessRelays* = object
    start*: proc (): bool {.nimcall.}
      ## Look for screen readers (once, when the window is there): true when
      ## the system has an accessibility service the driver talks to.
    update*: proc (nodes: openArray[AccessNode]; focus: int) {.nimcall.}
      ## The tree after a frame that changed it; `focus` the focused node's
      ## index (-1: none). The driver tells the screen reader what changed.
    announce*: proc (text: string) {.nimcall.}
      ## Say `text` now (a message shown for a moment, an alert).

var accessRelays*: AccessRelays
  ## Filled by the drivers that talk to the system's accessibility service.

var accessListening*: bool
  ## A screen reader is listening (set by the driver): build the tree.

var accessRequests*: seq[AccessRequest]
  ## What screen readers asked since the last frame (the driver adds, the
  ## program takes them at the start of its next frame).

proc accessStart*(): bool =
  ## The driver looks for screen readers; false when it has no support.
  if accessRelays.start != nil: accessRelays.start() else: false

proc accessUpdate*(nodes: openArray[AccessNode]; focus: int) =
  ## The tree, after a frame that changed it, to the screen reader.
  if accessRelays.update != nil: accessRelays.update(nodes, focus)

proc accessAnnounce*(text: string) =
  ## Says `text` (where the system can) -- a message shown for a moment.
  if accessRelays.announce != nil and text.len > 0: accessRelays.announce(text)

proc roleName*(r: AccessRole): string =
  ## The role in words ("push button"), as screen readers say them.
  case r
  of arWindow: "frame"
  of arPane: "panel"
  of arGroup: "grouping"
  of arLabel: "label"
  of arButton: "push button"
  of arToggleButton: "toggle button"
  of arCheckBox: "check box"
  of arRadioButton: "radio button"
  of arTextField: "entry"
  of arTextArea: "text"
  of arPasswordField: "password text"
  of arComboBox: "combo box"
  of arList: "list"
  of arListItem: "list item"
  of arSlider: "slider"
  of arSpinButton: "spin button"
  of arProgressBar: "progress bar"
  of arScrollBar: "scroll bar"
  of arMenuBar: "menu bar"
  of arMenu: "menu"
  of arMenuItem: "menu item"
  of arToolBar: "tool bar"
  of arStatusBar: "status bar"
  of arTabList: "page tab list"
  of arTab: "page tab"
  of arTree: "tree"
  of arTreeItem: "tree item"
  of arTable: "table"
  of arRow: "table row"
  of arCell: "table cell"
  of arColumnHeader: "column header"
  of arDialog: "dialog"
  of arLink: "link"
  of arImage: "image"
  of arHeading: "heading"
  of arSeparator: "separator"
  of arToolTip: "tool tip"
  of arAlert: "alert"

proc childrenOf*(nodes: openArray[AccessNode]; i: int): seq[int] =
  ## The indexes of node `i`'s children, in order (-1: the root's).
  for k in 0 ..< nodes.len:
    if nodes[k].parent == int32(i) and k != i: result.add k

proc indexOfId*(nodes: openArray[AccessNode]; id: uint32): int =
  ## The index of the node with `id`, -1 when there is none.
  for k in 0 ..< nodes.len:
    if nodes[k].id == id: return k
  -1
