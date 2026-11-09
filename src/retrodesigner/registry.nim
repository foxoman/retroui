## Retro Designer's registry: every control, its parameters and a call that
## draws it; the layout templates' begin and end; the enums' values, the
## string constants; the Widget Box (the guide's examples).
##
## MADE BY tools/gendesigner.py -- DO NOT EDIT: run it again instead.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/tables
import retroui
import retroui/[textwidgets, richedit, qrcode, pdfview, tilemap, gltf, capture, mediasession]
import values

{.push warning[Deprecated]: off, warning[UnusedImport]: off, hint[XDeclaredButNotUsed]: off.}

type
  ParamKind* = enum
    kNone = "", kStr = "str", kInt = "int", kFloat = "float", kBool = "bool",
    kStrs = "strs", kInts = "ints", kFloats = "floats", kColor = "color", kRect = "rect",
    kEnum = "enum", kSet = "set", kVStr = "vstr", kVInt = "vint", kVFloat = "vfloat",
    kVBool = "vbool", kVStrs = "vstrs", kVInts = "vints"
  Param* = object
    name*, typ*, default*: string   ## its type and default as the source has them
    kind*: ParamKind                ## how the designer gives it (kNone: it cannot)
  Overload* = object
    params*: seq[Param]
    returns*: string
    call*: proc (a: var Args): Value {.nimcall.}   ## nil: the designer cannot call it
  Control* = object
    name*, module*, doc*: string
    overloads*: seq[Overload]
  Block* = object
    ## A template with a body (row, group, tabs, menu...): `run` uses the
    ## template itself, its body (or bodies: a split's two sides) the
    ## designer's own drawing of what the file has there.
    name*, module*, doc*: string
    params*: seq[Param]
    bodies*: int
    run*: proc (a: var Args; bodies: seq[proc () {.closure.}]) {.nimcall.}
  Example* = object
    ## One of the guide's examples: what the Widget Box offers.
    name*, title*, about*, part*: string
    w*, h*: int
    code*, decls*: string           ## what it inserts: the controls, and the variables
    imports*: seq[string]           ## the modules it needs besides `retroui`

var
  controls*: Table[string, Control]
  blocks*: Table[string, seq[Block]]
  enumValues*: Table[string, seq[string]]  ## an enum's values, by the enum's name
  stringConsts*: Table[string, string]     ## pxOpen, nfSave...: their text
  intConsts*: Table[string, int]
  widgetBox*: seq[Example]


# ---- enums ----

proc enum_Align(name: string; d: Align): Align =
  case name
  of "alLeft": Align.alLeft
  of "alCenter": Align.alCenter
  of "alRight": Align.alRight
  else: d
proc set_Align(names: seq[string]; d: set[Align]): set[Align] =
  if names.len == 0: return d
  for n in names: result.incl enum_Align(n, Align.low)

proc enum_BannerKind(name: string; d: BannerKind): BannerKind =
  case name
  of "bkInfo": BannerKind.bkInfo
  of "bkSuccess": BannerKind.bkSuccess
  of "bkWarning": BannerKind.bkWarning
  of "bkError": BannerKind.bkError
  else: d
proc set_BannerKind(names: seq[string]; d: set[BannerKind]): set[BannerKind] =
  if names.len == 0: return d
  for n in names: result.incl enum_BannerKind(n, BannerKind.low)

proc enum_ButtonLook(name: string; d: ButtonLook): ButtonLook =
  case name
  of "blDefault": ButtonLook.blDefault
  of "blIconOnly": ButtonLook.blIconOnly
  of "blTextOnly": ButtonLook.blTextOnly
  of "blTextBelow": ButtonLook.blTextBelow
  of "blTextBeside": ButtonLook.blTextBeside
  else: d
proc set_ButtonLook(names: seq[string]; d: set[ButtonLook]): set[ButtonLook] =
  if names.len == 0: return d
  for n in names: result.incl enum_ButtonLook(n, ButtonLook.low)

proc enum_CameraFacing(name: string; d: CameraFacing): CameraFacing =
  case name
  of "cfAny": CameraFacing.cfAny
  of "cfBack": CameraFacing.cfBack
  of "cfFront": CameraFacing.cfFront
  of "cfExternal": CameraFacing.cfExternal
  else: d
proc set_CameraFacing(names: seq[string]; d: set[CameraFacing]): set[CameraFacing] =
  if names.len == 0: return d
  for n in names: result.incl enum_CameraFacing(n, CameraFacing.low)

proc enum_CellKind(name: string; d: CellKind): CellKind =
  case name
  of "ckText": CellKind.ckText
  of "ckNumber": CellKind.ckNumber
  of "ckCheck": CellKind.ckCheck
  of "ckColor": CellKind.ckColor
  of "ckProgress": CellKind.ckProgress
  of "ckChoice": CellKind.ckChoice
  of "ckButton": CellKind.ckButton
  of "ckLink": CellKind.ckLink
  of "ckIcon": CellKind.ckIcon
  of "ckCustom": CellKind.ckCustom
  else: d
proc set_CellKind(names: seq[string]; d: set[CellKind]): set[CellKind] =
  if names.len == 0: return d
  for n in names: result.incl enum_CellKind(n, CellKind.low)

proc enum_ChartKind(name: string; d: ChartKind): ChartKind =
  case name
  of "chBar": ChartKind.chBar
  of "chBarH": ChartKind.chBarH
  of "chStacked": ChartKind.chStacked
  of "chStacked100": ChartKind.chStacked100
  of "chLine": ChartKind.chLine
  of "chArea": ChartKind.chArea
  of "chStackedArea": ChartKind.chStackedArea
  of "chCombo": ChartKind.chCombo
  of "chPie": ChartKind.chPie
  of "chDonut": ChartKind.chDonut
  of "chScatter": ChartKind.chScatter
  of "chBubble": ChartKind.chBubble
  of "chWaterfall": ChartKind.chWaterfall
  of "chFunnel": ChartKind.chFunnel
  of "chGauge": ChartKind.chGauge
  of "chCandle": ChartKind.chCandle
  of "chHistogram": ChartKind.chHistogram
  of "chHeatmap": ChartKind.chHeatmap
  of "chRadar": ChartKind.chRadar
  of "chTreemap": ChartKind.chTreemap
  of "chBullet": ChartKind.chBullet
  else: d
proc set_ChartKind(names: seq[string]; d: set[ChartKind]): set[ChartKind] =
  if names.len == 0: return d
  for n in names: result.incl enum_ChartKind(n, ChartKind.low)

proc enum_FileView(name: string; d: FileView): FileView =
  case name
  of "fvDetails": FileView.fvDetails
  of "fvIcons": FileView.fvIcons
  of "fvTiles": FileView.fvTiles
  of "fvSmallIcons": FileView.fvSmallIcons
  of "fvColumns": FileView.fvColumns
  else: d
proc set_FileView(names: seq[string]; d: set[FileView]): set[FileView] =
  if names.len == 0: return d
  for n in names: result.incl enum_FileView(n, FileView.low)

proc enum_HeaderSide(name: string; d: HeaderSide): HeaderSide =
  case name
  of "hsLeft": HeaderSide.hsLeft
  of "hsCenter": HeaderSide.hsCenter
  of "hsRight": HeaderSide.hsRight
  else: d
proc set_HeaderSide(names: seq[string]; d: set[HeaderSide]): set[HeaderSide] =
  if names.len == 0: return d
  for n in names: result.incl enum_HeaderSide(n, HeaderSide.low)

proc enum_KeyCode(name: string; d: KeyCode): KeyCode =
  case name
  of "KeyNone": KeyCode.KeyNone
  of "KeyA": KeyCode.KeyA
  of "KeyB": KeyCode.KeyB
  of "KeyC": KeyCode.KeyC
  of "KeyD": KeyCode.KeyD
  of "KeyE": KeyCode.KeyE
  of "KeyF": KeyCode.KeyF
  of "KeyG": KeyCode.KeyG
  of "KeyH": KeyCode.KeyH
  of "KeyI": KeyCode.KeyI
  of "KeyJ": KeyCode.KeyJ
  of "KeyK": KeyCode.KeyK
  of "KeyL": KeyCode.KeyL
  of "KeyM": KeyCode.KeyM
  of "KeyN": KeyCode.KeyN
  of "KeyO": KeyCode.KeyO
  of "KeyP": KeyCode.KeyP
  of "KeyQ": KeyCode.KeyQ
  of "KeyR": KeyCode.KeyR
  of "KeyS": KeyCode.KeyS
  of "KeyT": KeyCode.KeyT
  of "KeyU": KeyCode.KeyU
  of "KeyV": KeyCode.KeyV
  of "KeyW": KeyCode.KeyW
  of "KeyX": KeyCode.KeyX
  of "KeyY": KeyCode.KeyY
  of "KeyZ": KeyCode.KeyZ
  of "Key0": KeyCode.Key0
  of "Key1": KeyCode.Key1
  of "Key2": KeyCode.Key2
  of "Key3": KeyCode.Key3
  of "Key4": KeyCode.Key4
  of "Key5": KeyCode.Key5
  of "Key6": KeyCode.Key6
  of "Key7": KeyCode.Key7
  of "Key8": KeyCode.Key8
  of "Key9": KeyCode.Key9
  of "KeyF1": KeyCode.KeyF1
  of "KeyF2": KeyCode.KeyF2
  of "KeyF3": KeyCode.KeyF3
  of "KeyF4": KeyCode.KeyF4
  of "KeyF5": KeyCode.KeyF5
  of "KeyF6": KeyCode.KeyF6
  of "KeyF7": KeyCode.KeyF7
  of "KeyF8": KeyCode.KeyF8
  of "KeyF9": KeyCode.KeyF9
  of "KeyF10": KeyCode.KeyF10
  of "KeyF11": KeyCode.KeyF11
  of "KeyF12": KeyCode.KeyF12
  of "KeyEnter": KeyCode.KeyEnter
  of "KeySpace": KeyCode.KeySpace
  of "KeyEsc": KeyCode.KeyEsc
  of "KeyTab": KeyCode.KeyTab
  of "KeyBackspace": KeyCode.KeyBackspace
  of "KeyDelete": KeyCode.KeyDelete
  of "KeyInsert": KeyCode.KeyInsert
  of "KeyLeft": KeyCode.KeyLeft
  of "KeyRight": KeyCode.KeyRight
  of "KeyUp": KeyCode.KeyUp
  of "KeyDown": KeyCode.KeyDown
  of "KeyPageUp": KeyCode.KeyPageUp
  of "KeyPageDown": KeyCode.KeyPageDown
  of "KeyHome": KeyCode.KeyHome
  of "KeyEnd": KeyCode.KeyEnd
  of "KeyCapslock": KeyCode.KeyCapslock
  of "KeyComma": KeyCode.KeyComma
  of "KeyPeriod": KeyCode.KeyPeriod
  of "KeySlash": KeyCode.KeySlash
  of "KeyMinus": KeyCode.KeyMinus
  of "KeyEqual": KeyCode.KeyEqual
  of "KeyPlus": KeyCode.KeyPlus
  of "KeyLeftBracket": KeyCode.KeyLeftBracket
  of "KeyRightBracket": KeyCode.KeyRightBracket
  of "KeySemicolon": KeyCode.KeySemicolon
  of "KeyQuote": KeyCode.KeyQuote
  of "KeyBackslash": KeyCode.KeyBackslash
  of "KeyBackquote": KeyCode.KeyBackquote
  of "KeyMenu": KeyCode.KeyMenu
  else: d
proc set_KeyCode(names: seq[string]; d: set[KeyCode]): set[KeyCode] =
  if names.len == 0: return d
  for n in names: result.incl enum_KeyCode(n, KeyCode.low)

proc enum_Modifier(name: string; d: Modifier): Modifier =
  case name
  of "ShiftPressed": Modifier.ShiftPressed
  of "CtrlPressed": Modifier.CtrlPressed
  of "AltPressed": Modifier.AltPressed
  of "GuiPressed": Modifier.GuiPressed
  else: d
proc set_Modifier(names: seq[string]; d: set[Modifier]): set[Modifier] =
  if names.len == 0: return d
  for n in names: result.incl enum_Modifier(n, Modifier.low)

proc enum_MsgIcon(name: string; d: MsgIcon): MsgIcon =
  case name
  of "miNone": MsgIcon.miNone
  of "miInfo": MsgIcon.miInfo
  of "miQuestion": MsgIcon.miQuestion
  of "miWarning": MsgIcon.miWarning
  of "miStop": MsgIcon.miStop
  else: d
proc set_MsgIcon(names: seq[string]; d: set[MsgIcon]): set[MsgIcon] =
  if names.len == 0: return d
  for n in names: result.incl enum_MsgIcon(n, MsgIcon.low)

proc enum_RangePreset(name: string; d: RangePreset): RangePreset =
  case name
  of "rpCustom": RangePreset.rpCustom
  of "rpToday": RangePreset.rpToday
  of "rpYesterday": RangePreset.rpYesterday
  of "rpThisWeek": RangePreset.rpThisWeek
  of "rpLastWeek": RangePreset.rpLastWeek
  of "rpThisMonth": RangePreset.rpThisMonth
  of "rpLastMonth": RangePreset.rpLastMonth
  of "rpThisQuarter": RangePreset.rpThisQuarter
  of "rpLastQuarter": RangePreset.rpLastQuarter
  of "rpThisYear": RangePreset.rpThisYear
  of "rpLastYear": RangePreset.rpLastYear
  of "rpLast7": RangePreset.rpLast7
  of "rpLast30": RangePreset.rpLast30
  of "rpLast90": RangePreset.rpLast90
  else: d
proc set_RangePreset(names: seq[string]; d: set[RangePreset]): set[RangePreset] =
  if names.len == 0: return d
  for n in names: result.incl enum_RangePreset(n, RangePreset.low)

proc enum_TabLook(name: string; d: TabLook): TabLook =
  case name
  of "tlDocument": TabLook.tlDocument
  of "tlPalette": TabLook.tlPalette
  else: d
proc set_TabLook(names: seq[string]; d: set[TabLook]): set[TabLook] =
  if names.len == 0: return d
  for n in names: result.incl enum_TabLook(n, TabLook.low)

proc enum_UiSound(name: string; d: UiSound): UiSound =
  case name
  of "usClick": UiSound.usClick
  of "usNotify": UiSound.usNotify
  of "usSuccess": UiSound.usSuccess
  of "usWarning": UiSound.usWarning
  of "usError": UiSound.usError
  else: d
proc set_UiSound(names: seq[string]; d: set[UiSound]): set[UiSound] =
  if names.len == 0: return d
  for n in names: result.incl enum_UiSound(n, UiSound.low)

proc enum_Waveform(name: string; d: Waveform): Waveform =
  case name
  of "wSine": Waveform.wSine
  of "wSquare": Waveform.wSquare
  of "wTriangle": Waveform.wTriangle
  of "wSaw": Waveform.wSaw
  else: d
proc set_Waveform(names: seq[string]; d: set[Waveform]): set[Waveform] =
  if names.len == 0: return d
  for n in names: result.incl enum_Waveform(n, Waveform.low)

proc enum_WebPermission(name: string; d: WebPermission): WebPermission =
  case name
  of "wpCamera": WebPermission.wpCamera
  of "wpMicrophone": WebPermission.wpMicrophone
  of "wpLocation": WebPermission.wpLocation
  of "wpNotifications": WebPermission.wpNotifications
  else: d
proc set_WebPermission(names: seq[string]; d: set[WebPermission]): set[WebPermission] =
  if names.len == 0: return d
  for n in names: result.incl enum_WebPermission(n, WebPermission.low)

# ---- the calls ----

proc c0_tooltip(a: var Args): Value =
  tooltip(text = a.argStr(0, ""))
  Value()
proc c1_label(a: var Args): Value =
  label(s = a.argStr(0, ""), bold = a.argBool(1, false), color = a.argColor(2, Color()), enabled = a.argBool(3, true), literal = a.argBool(4, false))
  Value()
proc c2_paragraph(a: var Args): Value =
  paragraph(s = a.argStr(0, ""), w = a.argInt(1, 0), color = a.argColor(2, Color()))
  Value()
proc c3_separator(a: var Args): Value =
  separator()
  Value()
proc c5_canvas(a: var Args): Value =
  toValue(canvas(w = a.argInt(0, 0), h = a.argInt(1, 0)))
proc c6_button(a: var Args): Value =
  toValue(button(label = a.argStr(0, ""), isDefault = a.argBool(1, false), enabled = a.argBool(2, true), w = a.argInt(3, 0)))
proc c7_buttonAt(a: var Args): Value =
  toValue(buttonAt(key = a.argStr(0, ""), r = a.argRect(1, Rect()), label = a.argStr(2, ""), enabled = a.argBool(4, true), down = a.argBool(5, false)))
proc c8_checkbox(a: var Args): Value =
  toValue(checkbox(label = a.argStr(0, ""), v = a.vbool(1), enabled = a.argBool(2, true)))
proc c9_radio(a: var Args): Value =
  toValue(radio(label = a.argStr(0, ""), v = a.vint(1), value = a.argInt(2, 0), enabled = a.argBool(3, true)))
proc c10_openPopupMenu(a: var Args): Value =
  openPopupMenu(key = a.argStr(0, ""), x = a.argInt(1, 0), y = a.argInt(2, 0))
  Value()
proc c11_menuItem(a: var Args): Value =
  toValue(menuItem(label = a.argStr(0, ""), shortcut = a.argStr(1, ""), checked = a.argBool(2, false), enabled = a.argBool(3, true)))
proc c12_menuSeparator(a: var Args): Value =
  menuSeparator()
  Value()
proc c13_editAt(a: var Args): Value =
  toValue(editAt(id = Id(a.argInt(0, 0)), s = a.vstr(1), r = a.argRect(2, Rect()), multi = a.argBool(3, false), pass = a.argBool(4, false), enabled = a.argBool(5, false), right = a.argBool(7, false), frameless = a.argBool(8, false), wrap = a.argBool(9, false), readOnly = a.argBool(10, false)))
proc c14_edit(a: var Args): Value =
  toValue(edit(s = a.vstr(0), w = a.argInt(1, 0), password = a.argBool(2, false), enabled = a.argBool(3, true), readOnly = a.argBool(4, false)))
proc c15_editArea(a: var Args): Value =
  toValue(editArea(s = a.vstr(0), lines = a.argInt(1, 6), w = a.argInt(2, 0), enabled = a.argBool(3, true), wrap = a.argBool(4, true), readOnly = a.argBool(5, false)))
proc c16_listbox(a: var Args): Value =
  toValue(listbox(items = a.argStrs(0, @[]), sel = a.vint(1), rows = a.argInt(2, 6), w = a.argInt(3, 0), tabs = a.argInts(4, @[]), enabled = a.argBool(5, true)))
proc c17_combo(a: var Args): Value =
  toValue(combo(items = a.argStrs(0, @[]), sel = a.vint(1), w = a.argInt(2, 0), enabled = a.argBool(3, true)))
proc c18_slider(a: var Args): Value =
  toValue(slider(v = a.vint(0), lo = a.argInt(1, 0), hi = a.argInt(2, 0), w = a.argInt(3, 0), ticks = a.argInt(4, 10), enabled = a.argBool(5, true)))
proc c19_progress(a: var Args): Value =
  progress(value = a.argFloat(0, 0.0), w = a.argInt(1, 0), showText = a.argBool(2, true))
  Value()
proc c20_spin(a: var Args): Value =
  toValue(spin(v = a.vint(0), lo = a.argInt(1, 0), hi = a.argInt(2, 0), w = a.argInt(3, 80), step = a.argInt(4, 1), enabled = a.argBool(5, true)))
proc c21_popupSlider(a: var Args): Value =
  toValue(popupSlider(v = a.vint(0), lo = a.argInt(1, 0), hi = a.argInt(2, 0), w = a.argInt(3, 0), unit = a.argStr(4, "%"), enabled = a.argBool(5, true)))
proc c22_setTabLook(a: var Args): Value =
  setTabLook(look = enum_TabLook(a.argIdent(0), TabLook.low))
  Value()
proc c23_tabStrip(a: var Args): Value =
  toValue(tabStrip(labels = a.argStrs(0, @[]), sel = a.vint(1), glyphs = a.argStrs(2, @[]), closable = a.argBool(3, true), addButton = a.argBool(4, true), dropKind = a.argStr(5, ""), enabled = a.argBool(6, true)))
proc c24_revealInPanel(a: var Args): Value =
  revealInPanel(r = a.argRect(0, Rect()), glide = a.argBool(1, true))
  Value()
proc c25_showMenu(a: var Args): Value =
  toValue(showMenu(path = a.argStrs(0, @[])))
proc c27_popupMenuOpen(a: var Args): Value =
  toValue(popupMenuOpen(key = a.argStr(0, "")))
proc c28_setToolbarLook(a: var Args): Value =
  setToolbarLook(look = enum_ButtonLook(a.argIdent(0), ButtonLook.low))
  Value()
proc c30_toolButton(a: var Args): Value =
  toValue(toolButton(caption = a.argStr(0, ""), tip = a.argStr(1, ""), down = a.argBool(2, false), bold = a.argBool(3, false), enabled = a.argBool(4, true), size = a.argFloat(5, 1.0)))
proc c31_glyphPic(a: var Args): Value =
  toValue(glyphPic(glyph = a.argStr(0, ""), size = a.argFloat(1, 1.25)))
proc c35_button(a: var Args): Value =
  toValue(button(label = a.argStr(0, ""), glyph = a.argStr(1, ""), look = enum_ButtonLook(a.argIdent(2), ButtonLook.blTextBeside), isDefault = a.argBool(3, false), enabled = a.argBool(4, true), w = a.argInt(5, 0), h = a.argInt(6, 0)))
proc c36_barButton(a: var Args): Value =
  toValue(barButton(glyph = a.argStr(0, ""), label = a.argStr(1, ""), tip = a.argStr(2, ""), down = a.argBool(3, false), enabled = a.argBool(4, true), look = enum_ButtonLook(a.argIdent(5), ButtonLook.blDefault)))
proc c37_buttonAt(a: var Args): Value =
  toValue(buttonAt(key = a.argStr(0, ""), r = a.argRect(1, Rect()), label = a.argStr(2, ""), glyph = a.argStr(3, ""), look = enum_ButtonLook(a.argIdent(4), ButtonLook.blTextBeside), enabled = a.argBool(5, true), down = a.argBool(6, false)))
proc c38_toolSeparator(a: var Args): Value =
  toolSeparator()
  Value()
proc c39_statusbar(a: var Args): Value =
  statusbar(parts = a.argStrs(0, @[]))
  Value()
proc c40_statusSep(a: var Args): Value =
  statusSep()
  Value()
proc c41_msgIcon(a: var Args): Value =
  msgIcon(kind = enum_MsgIcon(a.argIdent(0), MsgIcon.low))
  Value()
proc c42_captionBar(a: var Args): Value =
  captionBar()
  Value()
proc c48_column(a: var Args): Value =
  toValue(column(title = a.argStr(0, ""), width = a.argInt(1, 100), align = enum_Align(a.argIdent(2), Align.alLeft), editable = a.argBool(3, false), kind = enum_CellKind(a.argIdent(4), CellKind.ckText), choices = a.argStrs(5, @[])))
proc c49_numberColumn(a: var Args): Value =
  toValue(numberColumn(title = a.argStr(0, ""), width = a.argInt(1, 90), editable = a.argBool(2, false)))
proc c50_checkColumn(a: var Args): Value =
  toValue(checkColumn(title = a.argStr(0, ""), width = a.argInt(1, 40), editable = a.argBool(2, true)))
proc c51_colorColumn(a: var Args): Value =
  toValue(colorColumn(title = a.argStr(0, ""), width = a.argInt(1, 34)))
proc c52_progressColumn(a: var Args): Value =
  toValue(progressColumn(title = a.argStr(0, ""), width = a.argInt(1, 100)))
proc c53_choiceColumn(a: var Args): Value =
  toValue(choiceColumn(title = a.argStr(0, ""), choices = a.argStrs(1, @[]), width = a.argInt(2, 120), editable = a.argBool(3, true)))
proc c54_buttonColumn(a: var Args): Value =
  toValue(buttonColumn(title = a.argStr(0, ""), width = a.argInt(1, 80)))
proc c55_linkColumn(a: var Args): Value =
  toValue(linkColumn(title = a.argStr(0, ""), width = a.argInt(1, 100)))
proc c56_iconColumn(a: var Args): Value =
  toValue(iconColumn(title = a.argStr(0, ""), width = a.argInt(1, 28)))
proc c58_cellStyle(a: var Args): Value =
  toValue(cellStyle(fg = a.argColor(0, Color()), bg = a.argColor(1, Color()), bold = a.argBool(2, false)))
proc c59_isChecked(a: var Args): Value =
  toValue(isChecked(s = a.argStr(0, "")))
proc c60_namedColor(a: var Args): Value =
  toValue(namedColor(s = a.argStr(0, "")))
proc c61_gridEdit(a: var Args): Value =
  gridEdit(row = a.argInt(0, 0), col = a.argInt(1, 0), selectTo = a.argInt(2, -1))
  Value()
proc c66_leaf(a: var Args): Value =
  toValue(leaf(label = a.argStr(0, ""), icon = a.argBool(1, true), id = a.argStr(3, "")))
proc c67_treeClicked(a: var Args): Value =
  toValue(treeClicked())
proc c69_breadcrumb(a: var Args): Value =
  toValue(breadcrumb(parts = a.argStrs(0, @[]), w = a.argInt(1, 0), enabled = a.argBool(2, true)))
proc c71_progressBox(a: var Args): Value =
  toValue(progressBox(open = a.vbool(0), title = a.argStr(1, ""), message = a.argStr(2, ""), value = a.argFloat(3, 0.0), detail = a.argStr(4, ""), canCancel = a.argBool(5, true)))
proc c72_splitBar(a: var Args): Value =
  toValue(splitBar())
proc c73_paneBeside(a: var Args): Value =
  toValue(paneBeside(paneW = a.argInt(0, 0), minMain = a.argInt(1, 320)))
proc c75_numberEdit(a: var Args): Value =
  toValue(numberEdit(v = a.vfloat(0), decimals = a.argInt(1, 2), w = a.argInt(2, 110), thousands = a.argBool(5, true), enabled = a.argBool(6, true)))
proc c76_intEdit(a: var Args): Value =
  toValue(intEdit(v = a.vint(0), w = a.argInt(1, 80), thousands = a.argBool(4, false), enabled = a.argBool(5, true)))
proc c77_comboEdit(a: var Args): Value =
  toValue(comboEdit(text = a.vstr(0), items = a.argStrs(1, @[]), w = a.argInt(2, 0), enabled = a.argBool(3, true)))
proc c78_link(a: var Args): Value =
  toValue(link(caption = a.argStr(0, ""), enabled = a.argBool(1, true)))
proc c79_buttonRow(a: var Args): Value =
  toValue(buttonRow(labels = a.argStrs(0, @[])))
proc c80_icon(a: var Args): Value =
  toValue(icon(glyph = a.argStr(0, ""), color = a.argColor(1, Color()), size = a.argFloat(2, 1.0)))
proc c81_iconLabel(a: var Args): Value =
  iconLabel(glyph = a.argStr(0, ""), s = a.argStr(1, ""), color = a.argColor(2, Color()), iconColor = a.argColor(3, Color()), bold = a.argBool(4, false))
  Value()
proc c82_heading(a: var Args): Value =
  heading(s = a.argStr(0, ""), level = a.argInt(1, 1), color = a.argColor(2, Color()))
  Value()
proc c84_searchBox(a: var Args): Value =
  toValue(searchBox(s = a.vstr(0), placeholder = a.argStr(1, "Search"), w = a.argInt(2, 0), enabled = a.argBool(3, true)))
proc c85_switchSize(a: var Args): Value =
  toValue(switchSize())
proc c87_toggle(a: var Args): Value =
  toValue(toggle(label = a.argStr(0, ""), v = a.vbool(1), enabled = a.argBool(2, true)))
proc c88_segmented(a: var Args): Value =
  toValue(segmented(options = a.argStrs(0, @[]), sel = a.vint(1), w = a.argInt(2, 0), enabled = a.argBool(3, true)))
proc c89_chips(a: var Args): Value =
  toValue(chips(items = a.argStrs(0, @[]), closable = a.argBool(2, false), enabled = a.argBool(3, true)))
proc c90_badge(a: var Args): Value =
  badge(s = a.argStr(0, ""), bg = a.argColor(1, color(200, 0, 0)), fg = a.argColor(2, color(255, 255, 255)))
  Value()
proc c91_rating(a: var Args): Value =
  toValue(rating(v = a.vint(0), stars = a.argInt(1, 5), enabled = a.argBool(2, true)))
proc c92_spinner(a: var Args): Value =
  spinner(size = a.argInt(0, 0), color = a.argColor(1, Color()))
  Value()
proc c93_dismissToast(a: var Args): Value =
  dismissToast()
  Value()
proc c94_toastShown(a: var Args): Value =
  toValue(toastShown())
proc c95_toastArea(a: var Args): Value =
  toValue(toastArea())
proc c97_openColorDialog(a: var Args): Value =
  openColorDialog(key = a.argStr(0, ""), c = a.argColor(1, Color()), title = a.argStr(2, "Color"))
  Value()
proc c100_timePicker(a: var Args): Value =
  toValue(timePicker(h = a.vint(0), m = a.vint(1), enabled = a.argBool(2, true)))
proc c102_emptyState(a: var Args): Value =
  emptyState(glyph = a.argStr(0, ""), msg = a.argStr(1, ""), h = a.argInt(2, -1), detail = a.argStr(3, ""))
  Value()
proc c103_busyState(a: var Args): Value =
  busyState(msg = a.argStr(0, ""), h = a.argInt(1, -1))
  Value()
proc c105_settingToggle(a: var Args): Value =
  toValue(settingToggle(title = a.argStr(0, ""), v = a.vbool(1), detail = a.argStr(2, ""), enabled = a.argBool(3, true)))
proc c106_settingChoice(a: var Args): Value =
  toValue(settingChoice(title = a.argStr(0, ""), options = a.argStrs(1, @[]), v = a.vint(2), detail = a.argStr(3, ""), enabled = a.argBool(4, true)))
proc c107_settingCombo(a: var Args): Value =
  toValue(settingCombo(title = a.argStr(0, ""), options = a.argStrs(1, @[]), v = a.vint(2), detail = a.argStr(3, ""), enabled = a.argBool(4, true)))
proc c108_settingSlider(a: var Args): Value =
  toValue(settingSlider(title = a.argStr(0, ""), v = a.vint(1), lo = a.argInt(2, 0), hi = a.argInt(3, 0), detail = a.argStr(4, ""), suffix = a.argStr(5, ""), enabled = a.argBool(6, true)))
proc c109_settingButtons(a: var Args): Value =
  toValue(settingButtons(title = a.argStr(0, ""), buttons = a.argStrs(1, @[]), detail = a.argStr(2, ""), enabled = a.argBool(3, true)))
proc c110_settingLink(a: var Args): Value =
  toValue(settingLink(title = a.argStr(0, ""), detail = a.argStr(1, ""), enabled = a.argBool(3, true)))
proc c111_appearanceSettings(a: var Args): Value =
  toValue(appearanceSettings())
proc c112_initialsOf(a: var Args): Value =
  toValue(initialsOf(name = a.argStr(0, "")))
proc c113_avatar(a: var Args): Value =
  toValue(avatar(name = a.argStr(0, ""), size = a.argInt(1, 0), color = a.argColor(2, Color())))
proc c114_stepper(a: var Args): Value =
  toValue(stepper(steps = a.argStrs(0, @[]), current = a.argInt(1, 0), enabled = a.argBool(2, true)))
proc c115_banner(a: var Args): Value =
  toValue(banner(msg = a.argStr(0, ""), kind = enum_BannerKind(a.argIdent(1), BannerKind.bkInfo), actions = a.argStrs(2, @[]), closable = a.argBool(3, true)))
proc c116_pager(a: var Args): Value =
  toValue(pager(page = a.vint(0), pages = a.argInt(1, 0), enabled = a.argBool(2, true)))
proc c118_fab(a: var Args): Value =
  toValue(fab(glyph = a.argStr(0, ""), tip = a.argStr(1, ""), color = a.argColor(2, Color())))
proc c119_sparkline(a: var Args): Value =
  sparkline(values = a.argFloats(0, @[]), w = a.argInt(1, 0), h = a.argInt(2, 0), color = a.argColor(3, Color()), fillUnder = a.argBool(4, true))
  Value()
proc c120_progressRing(a: var Args): Value =
  progressRing(value = a.argFloat(0, 0.0), size = a.argInt(1, 0), color = a.argColor(2, Color()), showText = a.argBool(3, true))
  Value()
proc c121_usageBar(a: var Args): Value =
  usageBar(used = int64(a.argInt(0, 0)), total = int64(a.argInt(1, 0)), w = a.argInt(2, 0), h = a.argInt(3, 0))
  Value()
proc c122_rangeSlider(a: var Args): Value =
  toValue(rangeSlider(lo = a.vint(0), hi = a.vint(1), minV = a.argInt(2, 0), maxV = a.argInt(3, 0), w = a.argInt(4, 0), ticks = a.argInt(5, 10), enabled = a.argBool(6, true)))
proc c123_menuButton(a: var Args): Value =
  toValue(menuButton(label = a.argStr(0, ""), items = a.argStrs(1, @[]), w = a.argInt(2, 0), enabled = a.argBool(3, true)))
proc c124_splitButton(a: var Args): Value =
  toValue(splitButton(label = a.argStr(0, ""), items = a.argStrs(1, @[]), w = a.argInt(2, 0), enabled = a.argBool(3, true)))
proc c125_tagInput(a: var Args): Value =
  toValue(tagInput(tags = a.vstrs(0), text = a.vstr(1), w = a.argInt(2, 0), enabled = a.argBool(3, true), placeholder = a.argStr(4, "Add a tag")))
proc c126_autocomplete(a: var Args): Value =
  toValue(autocomplete(s = a.vstr(0), choices = a.argStrs(1, @[]), w = a.argInt(2, 0), rows = a.argInt(3, 6), enabled = a.argBool(4, true)))
proc c127_knob(a: var Args): Value =
  toValue(knob(v = a.vint(0), lo = a.argInt(1, 0), hi = a.argInt(2, 0), size = a.argInt(3, 0), label = a.argStr(4, ""), enabled = a.argBool(5, true)))
proc c128_led(a: var Args): Value =
  led(on = a.argBool(0, false), label = a.argStr(1, ""), c = a.argColor(2, Color()))
  Value()
proc c129_accordionHeader(a: var Args): Value =
  toValue(accordionHeader(title = a.argStr(0, ""), index = a.argInt(1, 0), open = a.vint(2)))
proc c131_pill(a: var Args): Value =
  pill(text = a.argStr(0, ""), c = a.argColor(1, Color()))
  Value()
proc c132_showSnackbar(a: var Args): Value =
  showSnackbar(msg = a.argStr(0, ""), action = a.argStr(1, "Undo"), ms = a.argInt(2, 8000))
  Value()
proc c133_snackbar(a: var Args): Value =
  toValue(snackbar())
proc c134_maskFormat(a: var Args): Value =
  toValue(maskFormat(value = a.argStr(0, ""), mask = a.argStr(1, "")))
proc c135_maskFull(a: var Args): Value =
  toValue(maskFull(value = a.argStr(0, ""), mask = a.argStr(1, "")))
proc c136_maskRaw(a: var Args): Value =
  toValue(maskRaw(text = a.argStr(0, ""), mask = a.argStr(1, "")))
proc c137_maskedEdit(a: var Args): Value =
  toValue(maskedEdit(value = a.vstr(0), mask = a.argStr(1, ""), w = a.argInt(2, 0), enabled = a.argBool(3, true)))
proc c138_recordNav(a: var Args): Value =
  toValue(recordNav(pos = a.vint(0), count = a.argInt(1, 0), dirty = a.argBool(2, false), canAdd = a.argBool(3, true), canDelete = a.argBool(4, true), key = a.argStr(5, "")))
proc c139_dualList(a: var Args): Value =
  toValue(dualList(available = a.vstrs(0), chosen = a.vstrs(1), rows = a.argInt(2, 8), sortAvailable = a.argBool(4, true), key = a.argStr(5, "")))
proc c140_presetRange(a: var Args): Value =
  toValue(presetRange(p = enum_RangePreset(a.argIdent(0), RangePreset.low)))
proc c142_textProp(a: var Args): Value =
  toValue(textProp(name = a.argStr(0, ""), value = a.argStr(1, ""), category = a.argStr(2, ""), help = a.argStr(3, "")))
proc c143_numberProp(a: var Args): Value =
  toValue(numberProp(name = a.argStr(0, ""), value = a.argFloat(1, 0.0), decimals = a.argInt(2, 2), category = a.argStr(3, ""), help = a.argStr(4, "")))
proc c144_intProp(a: var Args): Value =
  toValue(intProp(name = a.argStr(0, ""), value = a.argInt(1, 0), category = a.argStr(2, ""), help = a.argStr(3, "")))
proc c145_boolProp(a: var Args): Value =
  toValue(boolProp(name = a.argStr(0, ""), value = a.argBool(1, false), category = a.argStr(2, ""), help = a.argStr(3, "")))
proc c146_choiceProp(a: var Args): Value =
  toValue(choiceProp(name = a.argStr(0, ""), choices = a.argStrs(1, @[]), chosen = a.argInt(2, 0), category = a.argStr(3, ""), help = a.argStr(4, "")))
proc c147_colorProp(a: var Args): Value =
  toValue(colorProp(name = a.argStr(0, ""), value = a.argColor(1, Color()), category = a.argStr(2, ""), help = a.argStr(3, "")))
proc c149_infoProp(a: var Args): Value =
  toValue(infoProp(name = a.argStr(0, ""), value = a.argStr(1, ""), category = a.argStr(2, ""), help = a.argStr(3, "")))
proc c153_stepDone(a: var Args): Value =
  stepDone(ok = a.argBool(0, false))
  Value()
proc c154_paletteTabs(a: var Args): Value =
  toValue(paletteTabs(labels = a.argStrs(0, @[]), sel = a.vint(1), menu = a.argBool(2, true)))
proc c155_mdiCascade(a: var Args): Value =
  mdiCascade(key = a.argStr(0, ""))
  Value()
proc c156_mdiTile(a: var Args): Value =
  mdiTile(key = a.argStr(0, ""))
  Value()
proc c158_mdiWindowMenu(a: var Args): Value =
  mdiWindowMenu(key = a.argStr(0, ""))
  Value()
proc c159_findIn(a: var Args): Value =
  toValue(findIn(text = a.argStr(0, ""), what = a.argStr(1, ""), start = a.argInt(2, 0), matchCase = a.argBool(3, false), wholeWord = a.argBool(4, false), backwards = a.argBool(5, false), wrap = a.argBool(6, true)))
proc c160_replaceAllIn(a: var Args): Value =
  toValue(replaceAllIn(text = a.vstr(0), what = a.argStr(1, ""), with = a.argStr(2, ""), matchCase = a.argBool(3, false), wholeWord = a.argBool(4, false)))
proc c162_hotkeyText(a: var Args): Value =
  toValue(hotkeyText(key = enum_KeyCode(a.argIdent(0), KeyCode.low), mods = set_Modifier(a.argNames(1), {})))
proc c163_parseHotkey(a: var Args): Value =
  toValue(parseHotkey(s = a.argStr(0, "")))
proc c164_hotkeyPressed(a: var Args): Value =
  toValue(hotkeyPressed(s = a.argStr(0, "")))
proc c165_hotkeyEdit(a: var Args): Value =
  toValue(hotkeyEdit(keys = a.vstr(0), w = a.argInt(1, 0), enabled = a.argBool(2, true)))
proc c168_splashBox(a: var Args): Value =
  splashBox(app = a.argStr(0, ""), version = a.argStr(1, ""), tagline = a.argStr(2, ""), lines = a.argStrs(3, @[]), iconPng = a.argStr(6, ""), glyph = a.argStr(7, ""), progress = a.argFloat(8, -1.0), note = a.argStr(9, "Starting..."), width = a.argInt(10, 460))
  Value()
proc c169_aboutBox(a: var Args): Value =
  aboutBox(open = a.vbool(0), app = a.argStr(1, ""), version = a.argStr(2, ""), lines = a.argStrs(3, @[]), glyph = a.argStr(4, ""), width = a.argInt(5, 460), tagline = a.argStr(6, ""), whatsNew = a.argStrs(7, @[]), credits = a.argStrs(8, @[]), iconPng = a.argStr(10, ""), url = a.argStr(11, ""))
  Value()
proc c170_reportProblem(a: var Args): Value =
  reportProblem(text = a.argStr(0, ""))
  Value()
proc c171_problemBox(a: var Args): Value =
  problemBox(app = a.argStr(0, ""), version = a.argStr(1, ""))
  Value()
proc c175_fontSample(a: var Args): Value =
  toValue(fontSample(family = a.argStr(0, ""), style = a.argStr(1, ""), text = a.argStr(2, ""), h = a.argInt(3, 0)))
proc c176_fontCombo(a: var Args): Value =
  toValue(fontCombo(family = a.vstr(0), w = a.argInt(1, 0), enabled = a.argBool(2, true)))
proc c177_fontStyleCombo(a: var Args): Value =
  toValue(fontStyleCombo(family = a.argStr(0, ""), style = a.vstr(1), w = a.argInt(2, 0), enabled = a.argBool(3, true)))
proc c179_pictureBox(a: var Args): Value =
  pictureBox(path = a.argStr(0, ""), w = a.argInt(1, 0), h = a.argInt(2, 0), frame = a.argBool(4, true))
  Value()
proc c183_driveBar(a: var Args): Value =
  toValue(driveBar(current = a.argStr(0, ""), favorites = a.argStrs(1, @[]), key = a.argStr(3, "")))
proc c184_folderTree(a: var Args): Value =
  toValue(folderTree(selected = a.vstr(0), favorites = a.argStrs(1, @[]), showHidden = a.argBool(2, false), rows = a.argInt(3, -1), padding = a.argInt(5, 0)))
proc c185_pathBar(a: var Args): Value =
  toValue(pathBar(path = a.argStr(0, ""), key = a.argStr(1, ""), editNow = a.argBool(2, false), w = a.argInt(3, 0)))
proc c190_storageDialog(a: var Args): Value =
  storageDialog()
  Value()
proc c192_placesView(a: var Args): Value =
  toValue(placesView(favorites = a.argStrs(0, @[]), height = a.argInt(1, -1), key = a.argStr(2, "")))
proc c194_series(a: var Args): Value =
  toValue(series(name = a.argStr(0, ""), values = a.argFloats(1, @[]), color = a.argColor(2, Color())))
proc c195_lineSeries(a: var Args): Value =
  toValue(lineSeries(name = a.argStr(0, ""), values = a.argFloats(1, @[]), color = a.argColor(2, Color())))
proc c196_xySeries(a: var Args): Value =
  toValue(xySeries(name = a.argStr(0, ""), xs = a.argFloats(1, @[]), ys = a.argFloats(2, @[]), sizes = a.argFloats(3, @[]), color = a.argColor(4, Color())))
proc c197_ohlcSeries(a: var Args): Value =
  toValue(ohlcSeries(name = a.argStr(0, ""), opens = a.argFloats(1, @[]), highs = a.argFloats(2, @[]), lows = a.argFloats(3, @[]), closes = a.argFloats(4, @[]), color = a.argColor(5, Color())))
proc c198_parseCsv(a: var Args): Value =
  toValue(parseCsv(text = a.argStr(0, ""), header = a.argBool(2, true)))
proc c199_readCsv(a: var Args): Value =
  toValue(readCsv(path = a.argStr(0, ""), header = a.argBool(2, true)))
proc c200_csvField(a: var Args): Value =
  toValue(csvField(s = a.argStr(0, "")))
proc c201_csvLine(a: var Args): Value =
  toValue(csvLine(cells = a.argStrs(0, @[])))
proc c204_exportPng(a: var Args): Value =
  exportPng(r = a.argRect(0, Rect()), path = a.argStr(1, ""))
  Value()
proc c207_gauge(a: var Args): Value =
  toValue(gauge(title = a.argStr(0, ""), value = a.argFloat(1, 0.0), lo = a.argFloat(2, 0.0), height = a.argInt(6, 0), w = a.argInt(7, 0)))
proc c210_barChart(a: var Args): Value =
  barChart(values = a.argFloats(0, @[]), labels = a.argStrs(1, @[]), title = a.argStr(2, ""), w = a.argInt(3, 0), h = a.argInt(4, 170))
  Value()
proc c212_pieChart(a: var Args): Value =
  pieChart(values = a.argFloats(0, @[]), labels = a.argStrs(1, @[]), title = a.argStr(2, ""), w = a.argInt(3, 0), h = a.argInt(4, 170))
  Value()
proc c216_kpiTile(a: var Args): Value =
  toValue(kpiTile(label = a.argStr(0, ""), value = a.argStr(1, ""), deltaNote = a.argStr(3, ""), lowerIsBetter = a.argBool(4, false), trend = a.argFloats(5, @[]), color = a.argColor(7, Color()), w = a.argInt(8, 0)))
proc c217_statCard(a: var Args): Value =
  toValue(statCard(glyph = a.argStr(0, ""), label = a.argStr(1, ""), value = a.argStr(2, ""), detail = a.argStr(3, ""), color = a.argColor(4, Color()), w = a.argInt(5, 0)))
proc c219_countryName(a: var Args): Value =
  toValue(countryName(code = a.argStr(0, "")))
proc c220_countryCode(a: var Args): Value =
  toValue(countryCode(name = a.argStr(0, ""), alpha3 = a.argBool(1, true)))
proc c221_latLonOf(a: var Args): Value =
  toValue(latLonOf(code = a.argStr(0, "")))
proc c222_cityMarker(a: var Args): Value =
  toValue(cityMarker(name = a.argStr(0, ""), label = a.argStr(1, "\x00"), size = a.argFloat(2, 0.0), color = a.argColor(3, Color()), info = a.argStr(4, "")))
proc c229_box(a: var Args): Value =
  toValue(box(w = a.argFloat(0, 0.0), h = a.argFloat(1, 0.0), d = a.argFloat(2, 0.0), color = a.argColor(3, color(0, 0, 160)), name = a.argStr(4, "box")))
proc c230_sphere(a: var Args): Value =
  toValue(sphere(radius = a.argFloat(0, 0.0), color = a.argColor(1, color(0, 0, 160)), segments = a.argInt(2, 24), rings = a.argInt(3, 16), name = a.argStr(4, "sphere")))
proc c231_cylinder(a: var Args): Value =
  toValue(cylinder(radius = a.argFloat(0, 0.0), height = a.argFloat(1, 0.0), color = a.argColor(2, color(0, 0, 160)), segments = a.argInt(3, 24), name = a.argStr(4, "cylinder")))
proc c232_cone(a: var Args): Value =
  toValue(cone(radius = a.argFloat(0, 0.0), height = a.argFloat(1, 0.0), color = a.argColor(2, color(0, 0, 160)), segments = a.argInt(3, 24), name = a.argStr(4, "cone")))
proc c233_plane(a: var Args): Value =
  toValue(plane(w = a.argFloat(0, 0.0), d = a.argFloat(1, 0.0), color = a.argColor(2, color(192, 192, 192)), name = a.argStr(3, "plane")))
proc c236_newNode(a: var Args): Value =
  toValue(newNode(name = a.argStr(0, ""), parent = a.argInt(1, -1)))
proc c251_loadModel(a: var Args): Value =
  toValue(loadModel(path = a.argStr(0, "")))
proc c253_camera3(a: var Args): Value =
  toValue(camera3(yaw = a.argFloat(0, 35.0), pitch = a.argFloat(1, 25.0), distance = a.argFloat(2, 6.0), fov = a.argFloat(4, 40.0)))
proc c257_view3dOnGpu(a: var Args): Value =
  toValue(view3dOnGpu(key = a.argStr(0, "")))
proc c258_view3dPicture(a: var Args): Value =
  toValue(view3dPicture(key = a.argStr(0, "")))
proc c260_htmlToMarkdown(a: var Args): Value =
  toValue(htmlToMarkdown(html = a.argStr(0, "")))
proc c261_htmlView(a: var Args): Value =
  toValue(htmlView(html = a.argStr(0, ""), baseDir = a.argStr(1, ""), height = a.argInt(2, -1), key = a.argStr(3, ""), padding = a.argInt(5, -1)))
proc c262_htmlView(a: var Args): Value =
  toValue(htmlView(html = a.argStr(0, ""), zoom = a.vfloat(1), baseDir = a.argStr(2, ""), height = a.argInt(3, -1), key = a.argStr(4, ""), padding = a.argInt(6, -1)))
proc c263_htmlBlock(a: var Args): Value =
  toValue(htmlBlock(html = a.argStr(0, ""), baseDir = a.argStr(1, ""), w = a.argInt(2, 0), zoom = a.argFloat(4, 1.0)))
proc c264_webPermit(a: var Args): Value =
  webPermit(key = a.argStr(0, ""), allowed = set_WebPermission(a.argNames(1), {}))
  Value()
proc c265_webPrint(a: var Args): Value =
  webPrint(key = a.argStr(0, ""))
  Value()
proc c266_webAppFolder(a: var Args): Value =
  webAppFolder(folder = a.argStr(0, ""))
  Value()
proc c267_webAppUrl(a: var Args): Value =
  toValue(webAppUrl(path = a.argStr(0, "index.html")))
proc c268_webView(a: var Args): Value =
  toValue(webView(url = a.argStr(0, ""), height = a.argInt(1, -1), key = a.argStr(2, "")))
proc c269_mdPlainText(a: var Args): Value =
  toValue(mdPlainText(md = a.argStr(0, "")))
proc c270_markdown(a: var Args): Value =
  toValue(markdown(md = a.argStr(0, ""), baseDir = a.argStr(1, ""), w = a.argInt(2, 0)))
proc c271_markdownView(a: var Args): Value =
  toValue(markdownView(md = a.argStr(0, ""), height = a.argInt(1, -1), w = a.argInt(2, 0), baseDir = a.argStr(3, ""), key = a.argStr(4, "")))
proc c276_richFromHtml(a: var Args): Value =
  toValue(richFromHtml(html = a.argStr(0, "")))
proc c280_playSound(a: var Args): Value =
  toValue(playSound(path = a.argStr(0, ""), volume = a.argFloat(1, 1.0), loop = a.argBool(2, false)))
proc c281_tone(a: var Args): Value =
  toValue(tone(hz = a.argFloat(0, 0.0), ms = a.argInt(1, 0), volume = a.argFloat(2, 0.5), wave = enum_Waveform(a.argIdent(3), Waveform.wSine)))
proc c282_uiSound(a: var Args): Value =
  uiSound(kind = enum_UiSound(a.argIdent(0), UiSound.low), volume = a.argFloat(1, 1.0))
  Value()
proc c284_videoView(a: var Args): Value =
  toValue(videoView(path = a.argStr(0, ""), height = a.argInt(1, -1), w = a.argInt(2, 0), autoplay = a.argBool(3, false), controls = a.argBool(4, true), key = a.argStr(5, ""), audio = a.argBool(6, false)))
proc c285_audioView(a: var Args): Value =
  toValue(audioView(path = a.argStr(0, ""), height = a.argInt(1, -1), autoplay = a.argBool(2, false), key = a.argStr(3, "")))
proc c288_newCanvas2D(a: var Args): Value =
  toValue(newCanvas2D(w = a.argInt(0, 0), h = a.argInt(1, 0), pixelRatio = a.argFloat(2, 1.0)))
proc c289_newReport(a: var Args): Value =
  toValue(newReport(title = a.argStr(0, ""), author = a.argStr(1, "")))
proc c292_newTable(a: var Args): Value =
  toValue(newTable(headers = a.argStrs(0, @[]), widths = a.argFloats(1, @[]), grid = a.argBool(3, false), zebra = a.argBool(4, true)))
proc c298_printPdf(a: var Args): Value =
  toValue(printPdf(path = a.argStr(0, ""), jobName = a.argStr(1, ""), printer = a.argStr(2, ""), pages = a.argInt(3, 0)))
proc c300_reportFromHtml(a: var Args): Value =
  toValue(reportFromHtml(html = a.argStr(0, ""), baseDir = a.argStr(1, ""), title = a.argStr(2, "")))
proc c302_reportViewPage(a: var Args): Value =
  toValue(reportViewPage(key = a.argStr(0, "")))
proc c303_pdfPreview(a: var Args): Value =
  toValue(pdfPreview(path = a.argStr(0, ""), maxW = a.argInt(1, 512), maxH = a.argInt(2, 512)))
proc c304_openPdfView(a: var Args): Value =
  toValue(openPdfView(path = a.argStr(0, "")))
proc c306_osmTiles(a: var Args): Value =
  toValue(osmTiles())
proc c307_openTopoMap(a: var Args): Value =
  toValue(openTopoMap())
proc c308_cartoTiles(a: var Args): Value =
  toValue(cartoTiles(style = a.argStr(0, "light_all")))
proc c309_googleTiles(a: var Args): Value =
  toValue(googleTiles(key = a.argStr(0, ""), mapType = a.argStr(1, "roadmap"), language = a.argStr(2, "en-US"), region = a.argStr(3, "US")))
proc c310_azureTiles(a: var Args): Value =
  toValue(azureTiles(key = a.argStr(0, ""), tileset = a.argStr(1, "microsoft.base.road"), language = a.argStr(2, "")))
proc c311_mapboxTiles(a: var Args): Value =
  toValue(mapboxTiles(token = a.argStr(0, ""), style = a.argStr(1, "mapbox/streets-v12")))
proc c312_mapboxVector(a: var Args): Value =
  toValue(mapboxVector(token = a.argStr(0, "")))
proc c313_hereTiles(a: var Args): Value =
  toValue(hereTiles(key = a.argStr(0, ""), style = a.argStr(1, "explore.day")))
proc c314_mapTilerTiles(a: var Args): Value =
  toValue(mapTilerTiles(key = a.argStr(0, ""), map = a.argStr(1, "streets-v2")))
proc c315_mapTilerVector(a: var Args): Value =
  toValue(mapTilerVector(key = a.argStr(0, "")))
proc c316_protomapsVector(a: var Args): Value =
  toValue(protomapsVector(key = a.argStr(0, "")))
proc c317_esriTiles(a: var Args): Value =
  toValue(esriTiles(service = a.argStr(0, "World_Street_Map"), token = a.argStr(1, "")))
proc c318_tomTomTiles(a: var Args): Value =
  toValue(tomTomTiles(key = a.argStr(0, ""), layer = a.argStr(1, "basic"), style = a.argStr(2, "main")))
proc c319_stadiaTiles(a: var Args): Value =
  toValue(stadiaTiles(key = a.argStr(0, ""), style = a.argStr(1, "alidade_smooth")))
proc c320_amapTiles(a: var Args): Value =
  toValue(amapTiles(satellite = a.argBool(0, false), language = a.argStr(1, "zh_cn")))
proc c321_tencentTiles(a: var Args): Value =
  toValue(tencentTiles())
proc c322_tiandituTiles(a: var Args): Value =
  toValue(tiandituTiles(key = a.argStr(0, ""), layer = a.argStr(1, "vec")))
proc c323_pmtilesSource(a: var Args): Value =
  toValue(pmtilesSource(path = a.argStr(0, ""), attribution = a.argStr(2, "© OpenStreetMap contributors")))
proc c324_mbtilesSource(a: var Args): Value =
  toValue(mbtilesSource(path = a.argStr(0, ""), attribution = a.argStr(2, "© OpenStreetMap contributors")))
proc c325_folderSource(a: var Args): Value =
  toValue(folderSource(dir = a.argStr(0, ""), ext = a.argStr(1, "png"), maxZoom = a.argInt(2, 18), attribution = a.argStr(3, "")))
proc c326_tileJsonSource(a: var Args): Value =
  toValue(tileJsonSource(url = a.argStr(0, "")))
proc c327_mapKitPage(a: var Args): Value =
  toValue(mapKitPage(token = a.argStr(0, ""), lat = a.argFloat(1, 0.0), lon = a.argFloat(2, 0.0), zoomMeters = a.argFloat(3, 5000.0)))
proc c328_googleMapsPage(a: var Args): Value =
  toValue(googleMapsPage(key = a.argStr(0, ""), lat = a.argFloat(1, 0.0), lon = a.argFloat(2, 0.0), zoom = a.argInt(3, 12)))
proc c329_quadkey(a: var Args): Value =
  toValue(quadkey(z = a.argInt(0, 0), x = a.argInt(1, 0), y = a.argInt(2, 0)))
proc c331_loadingTiles(a: var Args): Value =
  toValue(loadingTiles())
proc c332_clearTileCache(a: var Args): Value =
  clearTileCache(disk = a.argBool(0, false))
  Value()
proc c339_tilesIn(a: var Args): Value =
  toValue(tilesIn(south = a.argFloat(0, 0.0), west = a.argFloat(1, 0.0), north = a.argFloat(2, 0.0), east = a.argFloat(3, 0.0), minZoom = a.argInt(4, 0), maxZoom = a.argInt(5, 0)))
proc c342_geoJsonShapes(a: var Args): Value =
  toValue(geoJsonShapes(text = a.argStr(0, ""), color = a.argColor(1, Color()), fill = a.argColor(2, Color())))
proc c343_cameras(a: var Args): Value =
  toValue(cameras())
proc c344_cameraView(a: var Args): Value =
  toValue(cameraView(key = a.argStr(0, ""), camera = a.argStr(1, ""), facing = enum_CameraFacing(a.argIdent(2), CameraFacing.cfAny), height = a.argInt(3, -1), w = a.argInt(4, 0), mirror = a.argBool(5, false)))
proc c345_cameraPhoto(a: var Args): Value =
  cameraPhoto(key = a.argStr(0, ""), path = a.argStr(1, ""))
  Value()
proc c346_cameraFrame(a: var Args): Value =
  toValue(cameraFrame(key = a.argStr(0, "")))
proc c347_cameraRecord(a: var Args): Value =
  toValue(cameraRecord(key = a.argStr(0, ""), path = a.argStr(1, "")))
proc c348_cameraStop(a: var Args): Value =
  cameraStop(key = a.argStr(0, ""))
  Value()
proc c349_cameraClose(a: var Args): Value =
  cameraClose(key = a.argStr(0, ""))
  Value()
proc c350_recordSound(a: var Args): Value =
  toValue(recordSound(path = a.argStr(0, "")))
proc c351_stopRecordingSound(a: var Args): Value =
  toValue(stopRecordingSound())
proc c352_recordingSound(a: var Args): Value =
  toValue(recordingSound())
proc c353_soundLevel(a: var Args): Value =
  toValue(soundLevel())
proc c354_mediaSessionBusName(a: var Args): Value =
  toValue(mediaSessionBusName())
proc c356_mediaKeys(a: var Args): Value =
  toValue(mediaKeys())
proc c357_space(a: var Args): Value =
  space(px = a.argInt(0, Gap))
  Value()
proc c358_spring(a: var Args): Value =
  spring()
  Value()
proc c359_fontSample(a: var Args): Value =
  toValue(fontSample(family = a.argStr(0, ""), style = a.argStr(1, ""), text = a.argStr(2, ""), h = a.argInt(3, 0)))
proc c360_fontCombo(a: var Args): Value =
  toValue(fontCombo(family = a.vstr(0), w = a.argInt(1, 0), enabled = a.argBool(2, true)))
proc c361_fontStyleCombo(a: var Args): Value =
  toValue(fontStyleCombo(family = a.argStr(0, ""), style = a.vstr(1), w = a.argInt(2, 0), enabled = a.argBool(3, true)))
proc c366_richFromHtml(a: var Args): Value =
  toValue(richFromHtml(html = a.argStr(0, "")))
proc c369_pdfPreview(a: var Args): Value =
  toValue(pdfPreview(path = a.argStr(0, ""), maxW = a.argInt(1, 512), maxH = a.argInt(2, 512)))
proc c370_openPdfView(a: var Args): Value =
  toValue(openPdfView(path = a.argStr(0, "")))
proc c372_osmTiles(a: var Args): Value =
  toValue(osmTiles())
proc c373_openTopoMap(a: var Args): Value =
  toValue(openTopoMap())
proc c374_cartoTiles(a: var Args): Value =
  toValue(cartoTiles(style = a.argStr(0, "light_all")))
proc c375_googleTiles(a: var Args): Value =
  toValue(googleTiles(key = a.argStr(0, ""), mapType = a.argStr(1, "roadmap"), language = a.argStr(2, "en-US"), region = a.argStr(3, "US")))
proc c376_azureTiles(a: var Args): Value =
  toValue(azureTiles(key = a.argStr(0, ""), tileset = a.argStr(1, "microsoft.base.road"), language = a.argStr(2, "")))
proc c377_mapboxTiles(a: var Args): Value =
  toValue(mapboxTiles(token = a.argStr(0, ""), style = a.argStr(1, "mapbox/streets-v12")))
proc c378_mapboxVector(a: var Args): Value =
  toValue(mapboxVector(token = a.argStr(0, "")))
proc c379_hereTiles(a: var Args): Value =
  toValue(hereTiles(key = a.argStr(0, ""), style = a.argStr(1, "explore.day")))
proc c380_mapTilerTiles(a: var Args): Value =
  toValue(mapTilerTiles(key = a.argStr(0, ""), map = a.argStr(1, "streets-v2")))
proc c381_mapTilerVector(a: var Args): Value =
  toValue(mapTilerVector(key = a.argStr(0, "")))
proc c382_protomapsVector(a: var Args): Value =
  toValue(protomapsVector(key = a.argStr(0, "")))
proc c383_esriTiles(a: var Args): Value =
  toValue(esriTiles(service = a.argStr(0, "World_Street_Map"), token = a.argStr(1, "")))
proc c384_tomTomTiles(a: var Args): Value =
  toValue(tomTomTiles(key = a.argStr(0, ""), layer = a.argStr(1, "basic"), style = a.argStr(2, "main")))
proc c385_stadiaTiles(a: var Args): Value =
  toValue(stadiaTiles(key = a.argStr(0, ""), style = a.argStr(1, "alidade_smooth")))
proc c386_amapTiles(a: var Args): Value =
  toValue(amapTiles(satellite = a.argBool(0, false), language = a.argStr(1, "zh_cn")))
proc c387_tencentTiles(a: var Args): Value =
  toValue(tencentTiles())
proc c388_tiandituTiles(a: var Args): Value =
  toValue(tiandituTiles(key = a.argStr(0, ""), layer = a.argStr(1, "vec")))
proc c389_pmtilesSource(a: var Args): Value =
  toValue(pmtilesSource(path = a.argStr(0, ""), attribution = a.argStr(2, "© OpenStreetMap contributors")))
proc c390_mbtilesSource(a: var Args): Value =
  toValue(mbtilesSource(path = a.argStr(0, ""), attribution = a.argStr(2, "© OpenStreetMap contributors")))
proc c391_folderSource(a: var Args): Value =
  toValue(folderSource(dir = a.argStr(0, ""), ext = a.argStr(1, "png"), maxZoom = a.argInt(2, 18), attribution = a.argStr(3, "")))
proc c392_tileJsonSource(a: var Args): Value =
  toValue(tileJsonSource(url = a.argStr(0, "")))
proc c393_mapKitPage(a: var Args): Value =
  toValue(mapKitPage(token = a.argStr(0, ""), lat = a.argFloat(1, 0.0), lon = a.argFloat(2, 0.0), zoomMeters = a.argFloat(3, 5000.0)))
proc c394_googleMapsPage(a: var Args): Value =
  toValue(googleMapsPage(key = a.argStr(0, ""), lat = a.argFloat(1, 0.0), lon = a.argFloat(2, 0.0), zoom = a.argInt(3, 12)))
proc c395_quadkey(a: var Args): Value =
  toValue(quadkey(z = a.argInt(0, 0), x = a.argInt(1, 0), y = a.argInt(2, 0)))
proc c397_loadingTiles(a: var Args): Value =
  toValue(loadingTiles())
proc c398_clearTileCache(a: var Args): Value =
  clearTileCache(disk = a.argBool(0, false))
  Value()
proc c405_tilesIn(a: var Args): Value =
  toValue(tilesIn(south = a.argFloat(0, 0.0), west = a.argFloat(1, 0.0), north = a.argFloat(2, 0.0), east = a.argFloat(3, 0.0), minZoom = a.argInt(4, 0), maxZoom = a.argInt(5, 0)))
proc c408_geoJsonShapes(a: var Args): Value =
  toValue(geoJsonShapes(text = a.argStr(0, ""), color = a.argColor(1, Color()), fill = a.argColor(2, Color())))
proc c409_readGltf(a: var Args): Value =
  toValue(readGltf(json = a.argStr(0, ""), bin = a.argStr(1, ""), baseDir = a.argStr(2, "")))
proc c410_readGlb(a: var Args): Value =
  toValue(readGlb(data = a.argStr(0, ""), baseDir = a.argStr(1, "")))
proc c411_loadGltf(a: var Args): Value =
  toValue(loadGltf(path = a.argStr(0, "")))
proc c412_blendToGlb(a: var Args): Value =
  toValue(blendToGlb(blend = a.argStr(0, ""), glb = a.argStr(1, "")))
proc c413_loadModel3(a: var Args): Value =
  toValue(loadModel3(path = a.argStr(0, "")))
proc c415_cameras(a: var Args): Value =
  toValue(cameras())
proc c416_cameraView(a: var Args): Value =
  toValue(cameraView(key = a.argStr(0, ""), camera = a.argStr(1, ""), facing = enum_CameraFacing(a.argIdent(2), CameraFacing.cfAny), height = a.argInt(3, -1), w = a.argInt(4, 0), mirror = a.argBool(5, false)))
proc c417_cameraPhoto(a: var Args): Value =
  cameraPhoto(key = a.argStr(0, ""), path = a.argStr(1, ""))
  Value()
proc c418_cameraFrame(a: var Args): Value =
  toValue(cameraFrame(key = a.argStr(0, "")))
proc c419_cameraRecord(a: var Args): Value =
  toValue(cameraRecord(key = a.argStr(0, ""), path = a.argStr(1, "")))
proc c420_cameraStop(a: var Args): Value =
  cameraStop(key = a.argStr(0, ""))
  Value()
proc c421_cameraClose(a: var Args): Value =
  cameraClose(key = a.argStr(0, ""))
  Value()
proc c422_recordSound(a: var Args): Value =
  toValue(recordSound(path = a.argStr(0, "")))
proc c423_stopRecordingSound(a: var Args): Value =
  toValue(stopRecordingSound())
proc c424_recordingSound(a: var Args): Value =
  toValue(recordingSound())
proc c425_soundLevel(a: var Args): Value =
  toValue(soundLevel())
proc c426_mediaSessionBusName(a: var Args): Value =
  toValue(mediaSessionBusName())
proc c428_mediaKeys(a: var Args): Value =
  toValue(mediaKeys())

# ---- the blocks ----

proc b0_group(a: var Args; bodies: seq[proc () {.closure.}]) =
  group(title = a.argStr(0, "")):
    bodies[0]()
proc b1_tabs(a: var Args; bodies: seq[proc () {.closure.}]) =
  tabs(sel = a.vint(0), labels = a.argStrs(1, @[])):
    bodies[0]()
proc b2_tabs(a: var Args; bodies: seq[proc () {.closure.}]) =
  tabs(sel = a.vint(0), labels = a.argStrs(1, @[]), sameHeight = a.argBool(2, false)):
    bodies[0]()
proc b3_scrollPanel(a: var Args; bodies: seq[proc () {.closure.}]) =
  scrollPanel(height = a.argInt(0, 0)):
    bodies[0]()
proc b4_panel(a: var Args; bodies: seq[proc () {.closure.}]) =
  panel():
    bodies[0]()
proc b5_panel(a: var Args; bodies: seq[proc () {.closure.}]) =
  panel(height = a.argInt(0, 0)):
    bodies[0]()
proc b6_pane(a: var Args; bodies: seq[proc () {.closure.}]) =
  pane(height = a.argInt(0, 0)):
    bodies[0]()
proc b7_menubar(a: var Args; bodies: seq[proc () {.closure.}]) =
  menubar():
    bodies[0]()
proc b8_menu(a: var Args; bodies: seq[proc () {.closure.}]) =
  menu(title = a.argStr(0, "")):
    bodies[0]()
proc b9_submenu(a: var Args; bodies: seq[proc () {.closure.}]) =
  submenu(label = a.argStr(0, "")):
    bodies[0]()
proc b10_contextMenu(a: var Args; bodies: seq[proc () {.closure.}]) =
  contextMenu():
    bodies[0]()
proc b11_popupMenu(a: var Args; bodies: seq[proc () {.closure.}]) =
  popupMenu(key = a.argStr(0, "")):
    bodies[0]()
proc b12_toolbar(a: var Args; bodies: seq[proc () {.closure.}]) =
  toolbar():
    bodies[0]()
proc b13_statusRow(a: var Args; bodies: seq[proc () {.closure.}]) =
  statusRow():
    bodies[0]()
proc b14_dialog(a: var Args; bodies: seq[proc () {.closure.}]) =
  dialog(open = a.vbool(0), title = a.argStr(1, ""), width = a.argInt(2, 0)):
    bodies[0]()
proc b15_window(a: var Args; bodies: seq[proc () {.closure.}]) =
  window(open = a.vbool(0), title = a.argStr(1, ""), w = a.argInt(2, 0), h = a.argInt(3, 0)):
    bodies[0]()
proc b16_tree(a: var Args; bodies: seq[proc () {.closure.}]) =
  tree(sel = a.vstr(0), rows = a.argInt(1, 0)):
    bodies[0]()
proc b17_branch(a: var Args; bodies: seq[proc () {.closure.}]) =
  branch(label = a.argStr(0, ""), expanded = a.vbool(1)):
    bodies[0]()
proc b19_split(a: var Args; bodies: seq[proc () {.closure.}]) =
  split(pos = a.vint(0), height = a.argInt(1, 0), left = (bodies[0]()), right = (bodies[1]()))
proc b20_vsplit(a: var Args; bodies: seq[proc () {.closure.}]) =
  vsplit(pos = a.vint(0), height = a.argInt(1, 0), upper = (bodies[0]()), lower = (bodies[1]()))
proc b21_sidePane(a: var Args; bodies: seq[proc () {.closure.}]) =
  sidePane(show = a.argBool(0, false), paneW = a.vint(1), paneH = a.vint(2), main = (bodies[0]()), pane = (bodies[1]()))
proc b22_field(a: var Args; bodies: seq[proc () {.closure.}]) =
  field(caption = a.argStr(0, "")):
    bodies[0]()
proc b23_form(a: var Args; bodies: seq[proc () {.closure.}]) =
  form(labelWidth = a.argInt(0, 0)):
    bodies[0]()
proc b24_expander(a: var Args; bodies: seq[proc () {.closure.}]) =
  expander(label = a.argStr(0, ""), open = a.vbool(1)):
    bodies[0]()
proc b25_card(a: var Args; bodies: seq[proc () {.closure.}]) =
  card(title = a.argStr(0, "")):
    bodies[0]()
proc b26_wizard(a: var Args; bodies: seq[proc () {.closure.}]) =
  discard wizard(open = a.vbool(0), title = a.argStr(1, ""), step = a.vint(2), steps = a.argStrs(3, @[]), width = a.argInt(4, 0)):
    bodies[0]()
proc b27_mdiArea(a: var Args; bodies: seq[proc () {.closure.}]) =
  mdiArea(height = a.argInt(0, 0)):
    bodies[0]()
proc b28_mdiArea(a: var Args; bodies: seq[proc () {.closure.}]) =
  mdiArea(height = a.argInt(0, 0), key = a.argStr(1, "")):
    bodies[0]()
proc b30_kpiRow(a: var Args; bodies: seq[proc () {.closure.}]) =
  kpiRow(minW = a.argInt(0, 0)):
    bodies[0]()
proc b31_kpiRow(a: var Args; bodies: seq[proc () {.closure.}]) =
  kpiRow():
    bodies[0]()
proc b32_canvas2d(a: var Args; bodies: seq[proc () {.closure.}]) =
  canvas2d(ctx = ctx, w = a.argInt(1, 0), h = a.argInt(2, 0)):
    bodies[0]()
proc b34_withId(a: var Args; bodies: seq[proc () {.closure.}]) =
  withId(key = a.argStr(0, "")):
    bodies[0]()
proc b35_row(a: var Args; bodies: seq[proc () {.closure.}]) =
  row():
    bodies[0]()
proc b36_row(a: var Args; bodies: seq[proc () {.closure.}]) =
  row(widths = a.argInts(0, @[])):
    bodies[0]()
proc b37_rowPx(a: var Args; bodies: seq[proc () {.closure.}]) =
  rowPx(widths = a.argInts(0, @[])):
    bodies[0]()
proc b38_col(a: var Args; bodies: seq[proc () {.closure.}]) =
  col():
    bodies[0]()
proc b39_col(a: var Args; bodies: seq[proc () {.closure.}]) =
  col(width = a.argInt(0, 0)):
    bodies[0]()
proc b40_adaptive(a: var Args; bodies: seq[proc () {.closure.}]) =
  adaptive(minW = a.argInt(0, 0)):
    bodies[0]()

proc initRegistry*() =
  ## Fills the tables (once, when the designer starts).
  if controls.len > 0: return
  controls.mgetOrPut("tooltip", Control(name: "tooltip", module: "widgets", doc: "Show text when the mouse rests on the widget drawn last (never after a finger was lifted there).")).overloads.add Overload(params: @[Param(name: "text", typ: "string", default: "", kind: kStr)], returns: "", call: c0_tooltip)
  controls.mgetOrPut("label", Control(name: "label", module: "widgets", doc: "Static text; 'n' starts a new line, '&' underlines the next letter (Alt + that letter moves the focus to the control after the label, as in a 3.1 dialog). Wider than the room it is in (a narrow dialog, a phone), it wraps, as a 3.1 static text does. In another language (setUiLanguage) the whole text is looked up before it wraps. literal: shown as it is -- a file's name: not translated, its '&' kept")).overloads.add Overload(params: @[Param(name: "s", typ: "string", default: "", kind: kStr), Param(name: "bold", typ: "bool", default: "false", kind: kBool), Param(name: "color", typ: "Color", default: "Color()", kind: kColor), Param(name: "enabled", typ: "bool", default: "true", kind: kBool), Param(name: "literal", typ: "bool", default: "false", kind: kBool)], returns: "", call: c1_label)
  controls.mgetOrPut("paragraph", Control(name: "paragraph", module: "widgets", doc: "Word-wrapped text as wide as the space it is in (or w).")).overloads.add Overload(params: @[Param(name: "s", typ: "string", default: "", kind: kStr), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "color", typ: "Color", default: "Color()", kind: kColor)], returns: "", call: c2_paragraph)
  controls.mgetOrPut("separator", Control(name: "separator", module: "widgets", doc: "A horizontal etched line.")).overloads.add Overload(params: @[], returns: "", call: c3_separator)
  controls.mgetOrPut("image", Control(name: "image", module: "widgets", doc: "A picture at its own size.")).overloads.add Overload(params: @[Param(name: "ic", typ: "Icon", default: "", kind: kNone)], returns: "", call: nil)
  controls.mgetOrPut("canvas", Control(name: "canvas", module: "widgets", doc: "Room for your own drawing: draw into the returned rectangle with fill, box, hline, vline, text and image.")).overloads.add Overload(params: @[Param(name: "w", typ: "int", default: "", kind: kInt), Param(name: "h", typ: "int", default: "", kind: kInt)], returns: "Rect", call: c5_canvas)
  controls.mgetOrPut("button", Control(name: "button", module: "widgets", doc: "A push button; true when clicked. isDefault = Enter clicks it.")).overloads.add Overload(params: @[Param(name: "label", typ: "string", default: "", kind: kStr), Param(name: "isDefault", typ: "bool", default: "false", kind: kBool), Param(name: "enabled", typ: "bool", default: "true", kind: kBool), Param(name: "w", typ: "int", default: "0", kind: kInt)], returns: "bool", call: c6_button)
  controls.mgetOrPut("buttonAt", Control(name: "buttonAt", module: "widgets", doc: "A push button at r (for bars and overlays laid out by hand); true when clicked. down draws it held in (a toggle that is on).")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "r", typ: "Rect", default: "", kind: kRect), Param(name: "label", typ: "string", default: "", kind: kStr), Param(name: "st", typ: "", default: "TextStyle()", kind: kNone), Param(name: "enabled", typ: "bool", default: "true", kind: kBool), Param(name: "down", typ: "bool", default: "false", kind: kBool)], returns: "bool", call: c7_buttonAt)
  controls.mgetOrPut("checkbox", Control(name: "checkbox", module: "widgets", doc: "A check box bound to v; true when toggled.")).overloads.add Overload(params: @[Param(name: "label", typ: "string", default: "", kind: kStr), Param(name: "v", typ: "var bool", default: "", kind: kVBool), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c8_checkbox)
  controls.mgetOrPut("radio", Control(name: "radio", module: "widgets", doc: "One option of a group: selected when v == value; true when chosen. The options sharing v are a group: the arrow keys move the choice (and the focus) between them, as in 3.1.")).overloads.add Overload(params: @[Param(name: "label", typ: "string", default: "", kind: kStr), Param(name: "v", typ: "var int", default: "", kind: kVInt), Param(name: "value", typ: "int", default: "", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c9_radio)
  controls.mgetOrPut("openPopupMenu", Control(name: "openPopupMenu", module: "widgets", doc: "Opens the menu key with its top left at x, y (under a button that drops it down); draw it with popupMenu(key).")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "x", typ: "int", default: "", kind: kInt), Param(name: "y", typ: "int", default: "", kind: kInt)], returns: "", call: c10_openPopupMenu)
  controls.mgetOrPut("menuItem", Control(name: "menuItem", module: "widgets", doc: "An item of the open menu; true when chosen.")).overloads.add Overload(params: @[Param(name: "label", typ: "string", default: "", kind: kStr), Param(name: "shortcut", typ: "string", default: "\"\"", kind: kStr), Param(name: "checked", typ: "bool", default: "false", kind: kBool), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c11_menuItem)
  controls.mgetOrPut("menuSeparator", Control(name: "menuSeparator", module: "widgets", doc: "A line between groups of menu items.")).overloads.add Overload(params: @[], returns: "", call: c12_menuSeparator)
  controls.mgetOrPut("editAt", Control(name: "editAt", module: "widgets", doc: "A text box at r (for widgets made of one: spin, number fields...). allowed limits the characters typed, right aligns the text right, frameless leaves out the border (the widget around draws one), wrap (several lines) wraps long lines at the words, readOnly: the text is selected, copied and scrolled through, not changed. Its menu (a right click, a long press): Cut, Copy, Paste, Delete, Select all. ")).overloads.add Overload(params: @[Param(name: "id", typ: "Id", default: "", kind: kInt), Param(name: "s", typ: "var string", default: "", kind: kVStr), Param(name: "r", typ: "Rect", default: "", kind: kRect), Param(name: "multi", typ: "bool", default: "", kind: kBool), Param(name: "pass", typ: "bool", default: "", kind: kBool), Param(name: "enabled", typ: "bool", default: "", kind: kBool), Param(name: "allowed", typ: "set[char]", default: "{}", kind: kNone), Param(name: "right", typ: "bool", default: "false", kind: kBool), Param(name: "frameless", typ: "bool", default: "false", kind: kBool), Param(name: "wrap", typ: "bool", default: "false", kind: kBool), Param(name: "readOnly", typ: "bool", default: "false", kind: kBool)], returns: "bool", call: c13_editAt)
  controls.mgetOrPut("edit", Control(name: "edit", module: "widgets", doc: "A one-line text box bound to s; true when the text changed. readOnly: selected and copied, not changed.")).overloads.add Overload(params: @[Param(name: "s", typ: "var string", default: "", kind: kVStr), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "password", typ: "bool", default: "false", kind: kBool), Param(name: "enabled", typ: "bool", default: "true", kind: kBool), Param(name: "readOnly", typ: "bool", default: "false", kind: kBool)], returns: "bool", call: c14_edit)
  controls.mgetOrPut("editArea", Control(name: "editArea", module: "widgets", doc: "A multi-line text box with a scroll bar. lines < 0 fills the height left in the window. Long lines wrap at the words (wrap false: they scroll sideways). readOnly: the text can be selected, copied and scrolled through, not changed (a log, a message's source).")).overloads.add Overload(params: @[Param(name: "s", typ: "var string", default: "", kind: kVStr), Param(name: "lines", typ: "int", default: "6", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool), Param(name: "wrap", typ: "bool", default: "true", kind: kBool), Param(name: "readOnly", typ: "bool", default: "false", kind: kBool)], returns: "bool", call: c15_editArea)
  controls.mgetOrPut("listbox", Control(name: "listbox", module: "widgets", doc: "A list bound to the selected index sel; true when it changed. Items may hold 't' columns aligned on tabs (pixels at 100%: they grow with the UI's size).")).overloads.add Overload(params: @[Param(name: "items", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "sel", typ: "var int", default: "", kind: kVInt), Param(name: "rows", typ: "int", default: "6", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "tabs", typ: "openArray[int]", default: "[]", kind: kInts), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c16_listbox)
  controls.mgetOrPut("combo", Control(name: "combo", module: "widgets", doc: "A drop-down list bound to the selected index sel; preview draws its items in the list (a font's name in the font).")).overloads.add Overload(params: @[Param(name: "items", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "sel", typ: "var int", default: "", kind: kVInt), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool), Param(name: "preview", typ: "ItemPreview", default: "nil", kind: kNone)], returns: "bool", call: c17_combo)
  controls.mgetOrPut("slider", Control(name: "slider", module: "widgets", doc: "A track bar bound to v in lo..hi; arrows, PgUp/PgDn, Home/End. On touch screens the thumb is large enough for a finger.")).overloads.add Overload(params: @[Param(name: "v", typ: "var int", default: "", kind: kVInt), Param(name: "lo", typ: "int", default: "", kind: kInt), Param(name: "hi", typ: "int", default: "", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "ticks", typ: "int", default: "10", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c18_slider)
  controls.mgetOrPut("progress", Control(name: "progress", module: "widgets", doc: "A progress bar, value from 0.0 to 1.0, with the percentage.")).overloads.add Overload(params: @[Param(name: "value", typ: "float", default: "", kind: kFloat), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "showText", typ: "bool", default: "true", kind: kBool)], returns: "", call: c19_progress)
  controls.mgetOrPut("spin", Control(name: "spin", module: "widgets", doc: "A number box with up and down arrows bound to v in lo..hi: type a number, click or hold the arrows, or with the focus Up / Down (step), Page Up / Page Down (ten steps) and the wheel.")).overloads.add Overload(params: @[Param(name: "v", typ: "var int", default: "", kind: kVInt), Param(name: "lo", typ: "int", default: "", kind: kInt), Param(name: "hi", typ: "int", default: "", kind: kInt), Param(name: "w", typ: "int", default: "80", kind: kInt), Param(name: "step", typ: "int", default: "1", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c20_spin)
  controls.mgetOrPut("popupSlider", Control(name: "popupSlider", module: "widgets", doc: "A number box with a slider that drops down from its arrow, as a tool's options bar has for Opacity, Flow or Tolerance: type the number; or press the arrow and drag (letting go closes it); or click the arrow, then click or drag on the slider (Enter, Esc or a click outside close it). Up / Down and the wheel step it when it has the focus.")).overloads.add Overload(params: @[Param(name: "v", typ: "var int", default: "", kind: kVInt), Param(name: "lo", typ: "int", default: "", kind: kInt), Param(name: "hi", typ: "int", default: "", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "unit", typ: "string", default: "\"%\"", kind: kStr), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c21_popupSlider)
  controls.mgetOrPut("setTabLook", Control(name: "setTabLook", module: "widgets", doc: "Every tabs and tabStrip from now on in this look.")).overloads.add Overload(params: @[Param(name: "look", typ: "TabLook", default: "", kind: kEnum)], returns: "", call: c22_setTabLook)
  controls.mgetOrPut("tabStrip", Control(name: "tabStrip", module: "widgets", doc: "Document tabs (a browser's, a file manager's): a strip of tabs with an x to close each and a + to add one; the page is yours to draw under it. Tabs shrink when there are many, and scroll when they still do not fit (arrow buttons, the wheel, a finger). With dropKind, a drag of that kind resting on a tab selects it, and dropping on it is reported. Keys: Ctrl+Tab / Ctrl+Shift+Tab anywhere; Left, Righ")).overloads.add Overload(params: @[Param(name: "labels", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "sel", typ: "var int", default: "", kind: kVInt), Param(name: "glyphs", typ: "openArray[string]", default: "[]", kind: kStrs), Param(name: "closable", typ: "bool", default: "true", kind: kBool), Param(name: "addButton", typ: "bool", default: "true", kind: kBool), Param(name: "dropKind", typ: "string", default: "\"\"", kind: kStr), Param(name: "enabled", typ: "bool", default: "true", kind: kBool), Param(name: "look", typ: "", default: "tabLook", kind: kNone)], returns: "TabStripEvent", call: c23_tabStrip)
  controls.mgetOrPut("revealInPanel", Control(name: "revealInPanel", module: "widgets", doc: "Inside a panel (or pane): scrolls it so that r (drawn this frame) comes to its top, or as near as it can: a message picked in a conversation, a heading jumped to. glide false: at once.")).overloads.add Overload(params: @[Param(name: "r", typ: "Rect", default: "", kind: kRect), Param(name: "glide", typ: "bool", default: "true", kind: kBool)], returns: "", call: c24_revealInPanel)
  controls.mgetOrPut("showMenu", Control(name: "showMenu", module: "widgets", doc: "Opens the menu bar's menu path[0] -- and in it the submenu path[1] -- as if it had been clicked, for the menu bar drawn next: a designer showing the menu whose items are being set, a tour of an app. The titles are written as in menu and submenu; hideMenu puts back what was open.")).overloads.add Overload(params: @[Param(name: "path", typ: "openArray[string]", default: "", kind: kStrs)], returns: "MenuShown", call: c25_showMenu)
  controls.mgetOrPut("hideMenu", Control(name: "hideMenu", module: "widgets", doc: "What was open before showMenu open again.")).overloads.add Overload(params: @[Param(name: "s", typ: "MenuShown", default: "", kind: kNone)], returns: "", call: nil)
  controls.mgetOrPut("popupMenuOpen", Control(name: "popupMenuOpen", module: "widgets", doc: "The menu key is open.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr)], returns: "bool", call: c27_popupMenuOpen)
  controls.mgetOrPut("setToolbarLook", Control(name: "setToolbarLook", module: "widgets", doc: "Every tool bar's buttons from now on (blDefault: icon only).")).overloads.add Overload(params: @[Param(name: "look", typ: "ButtonLook", default: "", kind: kEnum)], returns: "", call: c28_setToolbarLook)
  controls.mgetOrPut("toolButton", Control(name: "toolButton", module: "widgets", doc: "A tool bar button with a 16x16 icon. down shows it pressed in.")).overloads.add Overload(params: @[Param(name: "ic", typ: "Icon", default: "", kind: kNone), Param(name: "tip", typ: "string", default: "\"\"", kind: kStr), Param(name: "down", typ: "bool", default: "false", kind: kBool), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: nil)
  controls.mgetOrPut("toolButton", Control(name: "toolButton", module: "widgets", doc: "A tool bar button showing a short text, or an icon of the icon font (toolButton(nfCopy, \"Copy\", size = 1.3)).")).overloads.add Overload(params: @[Param(name: "caption", typ: "string", default: "", kind: kStr), Param(name: "tip", typ: "string", default: "\"\"", kind: kStr), Param(name: "down", typ: "bool", default: "false", kind: kBool), Param(name: "bold", typ: "bool", default: "false", kind: kBool), Param(name: "enabled", typ: "bool", default: "true", kind: kBool), Param(name: "size", typ: "float", default: "1.0", kind: kFloat)], returns: "bool", call: c30_toolButton)
  controls.mgetOrPut("glyphPic", Control(name: "glyphPic", module: "widgets", doc: "An icon-font glyph as a button's picture (glyphPic(nfCopy)).")).overloads.add Overload(params: @[Param(name: "glyph", typ: "string", default: "", kind: kStr), Param(name: "size", typ: "float", default: "1.25", kind: kFloat)], returns: "ButtonPic", call: c31_glyphPic)
  controls.mgetOrPut("button", Control(name: "button", module: "widgets", doc: "A push button with a picture: icon only (the label its tooltip), text only, the text below the icon, or beside it. True when clicked.")).overloads.add Overload(params: @[Param(name: "label", typ: "string", default: "", kind: kStr), Param(name: "pic", typ: "ButtonPic", default: "", kind: kNone), Param(name: "look", typ: "ButtonLook", default: "blTextBeside", kind: kEnum), Param(name: "isDefault", typ: "bool", default: "false", kind: kBool), Param(name: "enabled", typ: "bool", default: "true", kind: kBool), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "h", typ: "int", default: "0", kind: kInt)], returns: "bool", call: nil)
  controls.mgetOrPut("barButton", Control(name: "barButton", module: "widgets", doc: "A tool bar button with a picture and a label, shown as the bar's look (toolbarLook, Explorer's \"Text Labels\") or as look says.")).overloads.add Overload(params: @[Param(name: "pic", typ: "ButtonPic", default: "", kind: kNone), Param(name: "label", typ: "string", default: "", kind: kStr), Param(name: "tip", typ: "string", default: "\"\"", kind: kStr), Param(name: "down", typ: "bool", default: "false", kind: kBool), Param(name: "enabled", typ: "bool", default: "true", kind: kBool), Param(name: "look", typ: "ButtonLook", default: "blDefault", kind: kEnum)], returns: "bool", call: nil)
  controls.mgetOrPut("buttonAt", Control(name: "buttonAt", module: "widgets", doc: "buttonAt with a picture, the look way.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "r", typ: "Rect", default: "", kind: kRect), Param(name: "label", typ: "string", default: "", kind: kStr), Param(name: "pic", typ: "ButtonPic", default: "", kind: kNone), Param(name: "look", typ: "ButtonLook", default: "blTextBeside", kind: kEnum), Param(name: "enabled", typ: "bool", default: "true", kind: kBool), Param(name: "down", typ: "bool", default: "false", kind: kBool)], returns: "bool", call: nil)
  controls.mgetOrPut("button", Control(name: "button", module: "widgets", doc: "button with a glyph of the icon font as its picture (pxSave, nfCopy...).")).overloads.add Overload(params: @[Param(name: "label", typ: "string", default: "", kind: kStr), Param(name: "glyph", typ: "string", default: "", kind: kStr), Param(name: "look", typ: "ButtonLook", default: "blTextBeside", kind: kEnum), Param(name: "isDefault", typ: "bool", default: "false", kind: kBool), Param(name: "enabled", typ: "bool", default: "true", kind: kBool), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "h", typ: "int", default: "0", kind: kInt)], returns: "bool", call: c35_button)
  controls.mgetOrPut("barButton", Control(name: "barButton", module: "widgets", doc: "barButton with a glyph of the icon font as its picture.")).overloads.add Overload(params: @[Param(name: "glyph", typ: "string", default: "", kind: kStr), Param(name: "label", typ: "string", default: "", kind: kStr), Param(name: "tip", typ: "string", default: "\"\"", kind: kStr), Param(name: "down", typ: "bool", default: "false", kind: kBool), Param(name: "enabled", typ: "bool", default: "true", kind: kBool), Param(name: "look", typ: "ButtonLook", default: "blDefault", kind: kEnum)], returns: "bool", call: c36_barButton)
  controls.mgetOrPut("buttonAt", Control(name: "buttonAt", module: "widgets", doc: "buttonAt with a glyph of the icon font as its picture.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "r", typ: "Rect", default: "", kind: kRect), Param(name: "label", typ: "string", default: "", kind: kStr), Param(name: "glyph", typ: "string", default: "", kind: kStr), Param(name: "look", typ: "ButtonLook", default: "blTextBeside", kind: kEnum), Param(name: "enabled", typ: "bool", default: "true", kind: kBool), Param(name: "down", typ: "bool", default: "false", kind: kBool)], returns: "bool", call: c37_buttonAt)
  controls.mgetOrPut("toolSeparator", Control(name: "toolSeparator", module: "widgets", doc: "A gap between groups of tool buttons.")).overloads.add Overload(params: @[], returns: "", call: c38_toolSeparator)
  controls.mgetOrPut("statusbar", Control(name: "statusbar", module: "widgets", doc: "The status bar at the bottom of the window: the first part takes the spare room. Content above it can fill down to it (rows = -1).")).overloads.add Overload(params: @[Param(name: "parts", typ: "varargs[string]", default: "", kind: kStrs)], returns: "", call: c39_statusbar)
  controls.mgetOrPut("statusSep", Control(name: "statusSep", module: "widgets", doc: "The etched line between two parts of a status bar.")).overloads.add Overload(params: @[], returns: "", call: c40_statusSep)
  controls.mgetOrPut("msgIcon", Control(name: "msgIcon", module: "widgets", doc: "A 32x32 message box icon (at 100%: it grows with the UI's size).")).overloads.add Overload(params: @[Param(name: "kind", typ: "MsgIcon", default: "", kind: kEnum)], returns: "", call: c41_msgIcon)
  controls.mgetOrPut("captionBar", Control(name: "captionBar", module: "widgets", doc: "The window's 3.1 title bar where the app draws it. Phones and tablets: the system does not draw one there -- navy from the top of the screen (under the status bar, whose icons turn white over it), the control-menu box (zoom, minimize, close; also Alt+Space), the title, and the minimize button. Desktops with the 3.1 frame on (setClassicFrame): the title bar of a Windows 3.1 window, its control-menu")).overloads.add Overload(params: @[], returns: "", call: c42_captionBar)
  controls.mgetOrPut("`&lt;`", Control(name: "`&lt;`", module: "business", doc: "a is before b.")).overloads.add Overload(params: @[Param(name: "a", typ: "Date", default: "", kind: kNone), Param(name: "b", typ: "Date", default: "", kind: kNone)], returns: "bool", call: nil)
  controls.mgetOrPut("`&lt;=`", Control(name: "`&lt;=`", module: "business", doc: "a is before b or the same day.")).overloads.add Overload(params: @[Param(name: "a", typ: "Date", default: "", kind: kNone), Param(name: "b", typ: "Date", default: "", kind: kNone)], returns: "bool", call: nil)
  controls.mgetOrPut("`$`", Control(name: "`$`", module: "business", doc: "The date as dateStyle writes it (\"\" when it is not valid).")).overloads.add Overload(params: @[Param(name: "d", typ: "Date", default: "", kind: kNone)], returns: "string", call: nil)
  controls.mgetOrPut("calendar", Control(name: "calendar", module: "business", doc: "A month calendar bound to d: click or tap a day; the arrows move a day or a week, Page Up / Page Down a month, Home / End the first / last day; the wheel and the < > buttons show other months.")).overloads.add Overload(params: @[Param(name: "d", typ: "var Date", default: "", kind: kNone), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: nil)
  controls.mgetOrPut("datePicker", Control(name: "datePicker", module: "business", doc: "A date field (typed in dateStyle) with a drop-down calendar (its button, Alt+Down or F4). With the focus, Up / Down move a day and Page Up / Page Down a month.")).overloads.add Overload(params: @[Param(name: "d", typ: "var Date", default: "", kind: kNone), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: nil)
  controls.mgetOrPut("column", Control(name: "column", module: "business", doc: "A column of text (or of kind); the others below are short cuts.")).overloads.add Overload(params: @[Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "width", typ: "int", default: "100", kind: kInt), Param(name: "align", typ: "Align", default: "alLeft", kind: kEnum), Param(name: "editable", typ: "bool", default: "false", kind: kBool), Param(name: "kind", typ: "CellKind", default: "ckText", kind: kEnum), Param(name: "choices", typ: "openArray[string]", default: "[]", kind: kStrs)], returns: "Column", call: c48_column)
  controls.mgetOrPut("numberColumn", Control(name: "numberColumn", module: "business", doc: "Numbers, right aligned.")).overloads.add Overload(params: @[Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "width", typ: "int", default: "90", kind: kInt), Param(name: "editable", typ: "bool", default: "false", kind: kBool)], returns: "Column", call: c49_numberColumn)
  controls.mgetOrPut("checkColumn", Control(name: "checkColumn", module: "business", doc: "Check boxes; a click flips them.")).overloads.add Overload(params: @[Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "width", typ: "int", default: "40", kind: kInt), Param(name: "editable", typ: "bool", default: "true", kind: kBool)], returns: "Column", call: c50_checkColumn)
  controls.mgetOrPut("colorColumn", Control(name: "colorColumn", module: "business", doc: "Blocks of color (status lights).")).overloads.add Overload(params: @[Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "width", typ: "int", default: "34", kind: kInt)], returns: "Column", call: c51_colorColumn)
  controls.mgetOrPut("progressColumn", Control(name: "progressColumn", module: "business", doc: "Progress bars (\"0.62\" or \"62%\").")).overloads.add Overload(params: @[Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "width", typ: "int", default: "100", kind: kInt)], returns: "Column", call: c52_progressColumn)
  controls.mgetOrPut("choiceColumn", Control(name: "choiceColumn", module: "business", doc: "Text picked from choices in a drop-down list.")).overloads.add Overload(params: @[Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "choices", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "width", typ: "int", default: "120", kind: kInt), Param(name: "editable", typ: "bool", default: "true", kind: kBool)], returns: "Column", call: c53_choiceColumn)
  controls.mgetOrPut("buttonColumn", Control(name: "buttonColumn", module: "business", doc: "Push buttons showing the text; a click is clicked.")).overloads.add Overload(params: @[Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "width", typ: "int", default: "80", kind: kInt)], returns: "Column", call: c54_buttonColumn)
  controls.mgetOrPut("linkColumn", Control(name: "linkColumn", module: "business", doc: "Links (blue underlined text); a click is clicked.")).overloads.add Overload(params: @[Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "width", typ: "int", default: "100", kind: kInt)], returns: "Column", call: c55_linkColumn)
  controls.mgetOrPut("iconColumn", Control(name: "iconColumn", module: "business", doc: "Icons: the text is a pixel icon (\"Sheet\", \"pxSheet\" or pxSheet itself) or an icon-font glyph.")).overloads.add Overload(params: @[Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "width", typ: "int", default: "28", kind: kInt)], returns: "Column", call: c56_iconColumn)
  controls.mgetOrPut("customColumn", Control(name: "customColumn", module: "business", doc: "Cells drawn by paint (a sparkline, a rating, a gauge...).")).overloads.add Overload(params: @[Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "width", typ: "int", default: "", kind: kInt), Param(name: "paint", typ: "proc (row: int; r: Rect; selected: bool)", default: "", kind: kNone)], returns: "Column", call: nil)
  controls.mgetOrPut("cellStyle", Control(name: "cellStyle", module: "business", doc: "A cell's look for grid's style (a color left out is the grid's).")).overloads.add Overload(params: @[Param(name: "fg", typ: "Color", default: "Color()", kind: kColor), Param(name: "bg", typ: "Color", default: "Color()", kind: kColor), Param(name: "bold", typ: "bool", default: "false", kind: kBool)], returns: "CellStyle", call: c58_cellStyle)
  controls.mgetOrPut("isChecked", Control(name: "isChecked", module: "business", doc: "How a check box cell reads its text.")).overloads.add Overload(params: @[Param(name: "s", typ: "string", default: "", kind: kStr)], returns: "bool", call: c59_isChecked)
  controls.mgetOrPut("namedColor", Control(name: "namedColor", module: "business", doc: "\"#RRGGBB\", \"#RGB\" or a 3.1 palette name (\"green\", \"red\", \"navy\", \"orange\"...); alpha 0 when it is none.")).overloads.add Overload(params: @[Param(name: "s", typ: "string", default: "", kind: kStr)], returns: "Color", call: c60_namedColor)
  controls.mgetOrPut("gridEdit", Control(name: "gridEdit", module: "business", doc: "Open the editor on cell row, col of the next grid drawn (a \"Rename\" command, say). selectTo: select only the text before it (a file name without its extension); -1 selects all.")).overloads.add Overload(params: @[Param(name: "row", typ: "int", default: "", kind: kInt), Param(name: "col", typ: "int", default: "", kind: kInt), Param(name: "selectTo", typ: "int", default: "-1", kind: kInt)], returns: "", call: c61_gridEdit)
  controls.mgetOrPut("grid", Control(name: "grid", module: "business", doc: "A table of rows rows; cell(row, col) gives the text of the cells on screen (so a million rows cost what the visible ones cost). Click a header to sort, drag its edge to resize; arrows, Enter, F2 to edit an editable cell (or just type). height is in rows (-1 fills). sortColumn, sortDescending: the order the rows are in, for the arrow in the header (else the grid remembers the last header click). ic")).overloads.add Overload(params: @[Param(name: "cols", typ: "var seq[Column]", default: "", kind: kNone), Param(name: "rows", typ: "int", default: "", kind: kInt), Param(name: "cell", typ: "proc (row, col: int): string", default: "", kind: kNone), Param(name: "sel", typ: "var int", default: "", kind: kVInt), Param(name: "height", typ: "int", default: "10", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "sortColumn", typ: "int", default: "-1", kind: kInt), Param(name: "sortDescending", typ: "bool", default: "false", kind: kBool), Param(name: "enabled", typ: "bool", default: "true", kind: kBool), Param(name: "icon", typ: "proc (row: int): Icon", default: "nil", kind: kNone), Param(name: "typeToEdit", typ: "bool", default: "true", kind: kBool), Param(name: "tapActivates", typ: "bool", default: "false", kind: kBool), Param(name: "style", typ: "proc (row, col: int): CellStyle", default: "nil", kind: kNone), Param(name: "rowHeaders", typ: "bool", default: "false", kind: kBool), Param(name: "footer", typ: "proc (col: int): string", default: "nil", kind: kNone)], returns: "GridEvent", call: nil)
  controls.mgetOrPut("grid", Control(name: "grid", module: "business", doc: "A grid where many rows can be selected: marked[row]; sel is the row with the focus. Ctrl+click toggles a row, Shift+click selects a range, Ctrl+A all, dragging from below the rows draws a selection rectangle; checkboxes adds a check box to every row. On a touch screen, once a row is marked (long press, or its check box), taps mark more rows. dragRows: dragging a row reports dragStarted (call start")).overloads.add Overload(params: @[Param(name: "cols", typ: "var seq[Column]", default: "", kind: kNone), Param(name: "rows", typ: "int", default: "", kind: kInt), Param(name: "cell", typ: "proc (row, col: int): string", default: "", kind: kNone), Param(name: "sel", typ: "var int", default: "", kind: kVInt), Param(name: "marked", typ: "var seq[bool]", default: "", kind: kNone), Param(name: "height", typ: "int", default: "10", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "sortColumn", typ: "int", default: "-1", kind: kInt), Param(name: "sortDescending", typ: "bool", default: "false", kind: kBool), Param(name: "enabled", typ: "bool", default: "true", kind: kBool), Param(name: "icon", typ: "proc (row: int): Icon", default: "nil", kind: kNone), Param(name: "typeToEdit", typ: "bool", default: "true", kind: kBool), Param(name: "tapActivates", typ: "bool", default: "false", kind: kBool), Param(name: "checkboxes", typ: "bool", default: "false", kind: kBool), Param(name: "dragRows", typ: "bool", default: "false", kind: kBool), Param(name: "dropOk", typ: "proc (row: int): bool", default: "nil", kind: kNone), Param(name: "style", typ: "proc (row, col: int): CellStyle", default: "nil", kind: kNone), Param(name: "rowHeaders", typ: "bool", default: "false", kind: kBool), Param(name: "footer", typ: "proc (col: int): string", default: "nil", kind: kNone)], returns: "GridEvent", call: nil)
  controls.mgetOrPut("grid", Control(name: "grid", module: "business", doc: "A table showing data (rows of cells).")).overloads.add Overload(params: @[Param(name: "cols", typ: "var seq[Column]", default: "", kind: kNone), Param(name: "data", typ: "seq[seq[string]]", default: "", kind: kNone), Param(name: "sel", typ: "var int", default: "", kind: kVInt), Param(name: "height", typ: "int", default: "10", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "sortColumn", typ: "int", default: "-1", kind: kInt), Param(name: "sortDescending", typ: "bool", default: "false", kind: kBool), Param(name: "enabled", typ: "bool", default: "true", kind: kBool), Param(name: "style", typ: "proc (row, col: int): CellStyle", default: "nil", kind: kNone), Param(name: "rowHeaders", typ: "bool", default: "false", kind: kBool), Param(name: "footer", typ: "proc (col: int): string", default: "nil", kind: kNone)], returns: "GridEvent", call: nil)
  controls.mgetOrPut("sortRows", Control(name: "sortRows", module: "business", doc: "Sort table rows by column col: as numbers when every cell is one (thousands separators allowed), else alphabetically ignoring case.")).overloads.add Overload(params: @[Param(name: "data", typ: "var seq[seq[string]]", default: "", kind: kNone), Param(name: "col", typ: "int", default: "", kind: kInt), Param(name: "descending", typ: "bool", default: "false", kind: kBool)], returns: "", call: nil)
  controls.mgetOrPut("leaf", Control(name: "leaf", module: "business", doc: "A node without children; true when it was clicked.")).overloads.add Overload(params: @[Param(name: "label", typ: "string", default: "", kind: kStr), Param(name: "icon", typ: "bool", default: "true", kind: kBool), Param(name: "pic", typ: "", default: "Icon()", kind: kNone), Param(name: "id", typ: "string", default: "\"\"", kind: kStr)], returns: "bool", call: c66_leaf)
  controls.mgetOrPut("treeClicked", Control(name: "treeClicked", module: "business", doc: "Inside or right after a tree: the node clicked this frame (\"\" if none).")).overloads.add Overload(params: @[], returns: "string", call: c67_treeClicked)
  controls.mgetOrPut("iconView", Control(name: "iconView", module: "business", doc: "Items as large pictures with their names under them, in rows (the \"Large icons\" view of a file manager); with detail as tiles: the picture at the left, the name and a line or two of detail(i) beside it. picture(i, r) draws item i into r (an icon, a thumbnail with drawBitmap). With oneLine, small tiles of one line each: the picture and the name beside it (\"Small icons\"). Selection, keys, touch, sel")).overloads.add Overload(params: @[Param(name: "count", typ: "int", default: "", kind: kInt), Param(name: "label", typ: "proc (i: int): string", default: "", kind: kNone), Param(name: "picture", typ: "proc (i: int; r: Rect)", default: "", kind: kNone), Param(name: "sel", typ: "var int", default: "", kind: kVInt), Param(name: "marked", typ: "var seq[bool]", default: "", kind: kNone), Param(name: "tile", typ: "int", default: "0", kind: kInt), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "tapActivates", typ: "bool", default: "false", kind: kBool), Param(name: "checkboxes", typ: "bool", default: "false", kind: kBool), Param(name: "enabled", typ: "bool", default: "true", kind: kBool), Param(name: "picSize", typ: "int", default: "0", kind: kInt), Param(name: "detail", typ: "proc (i: int): string", default: "nil", kind: kNone), Param(name: "dragItems", typ: "bool", default: "false", kind: kBool), Param(name: "dropOk", typ: "proc (i: int): bool", default: "nil", kind: kNone), Param(name: "oneLine", typ: "bool", default: "false", kind: kBool)], returns: "GridEvent", call: nil)
  controls.mgetOrPut("breadcrumb", Control(name: "breadcrumb", module: "business", doc: "The parts of a path as buttons in a row (\"C: > Users > me\"); returns the index of the part clicked, -1 if none. Parts that do not fit are folded into a \"<<\" button at the start.")).overloads.add Overload(params: @[Param(name: "parts", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "int", call: c69_breadcrumb)
  controls.mgetOrPut("imageView", Control(name: "imageView", module: "business", doc: "A picture to look at: fitted into the view while zoom is 0, else zoom screen pixels per picture pixel (1.0: actual size). The wheel (and + / - / 0 with the focus) zooms, a double click or double tap goes between fitted and actual size, dragging (a finger, the arrow keys) moves it.")).overloads.add Overload(params: @[Param(name: "b", typ: "Bitmap", default: "", kind: kNone), Param(name: "zoom", typ: "var float", default: "", kind: kVFloat), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt)], returns: "", call: nil)
  controls.mgetOrPut("progressBox", Control(name: "progressBox", module: "business", doc: "A modal box with a progress bar while open; true (once) when the user cancels (Cancel or Esc).")).overloads.add Overload(params: @[Param(name: "open", typ: "var bool", default: "", kind: kVBool), Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "message", typ: "string", default: "", kind: kStr), Param(name: "value", typ: "float", default: "", kind: kFloat), Param(name: "detail", typ: "string", default: "\"\"", kind: kStr), Param(name: "canCancel", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c71_progressBox)
  controls.mgetOrPut("splitBar", Control(name: "splitBar", module: "business", doc: "The thickness of the bar of split and vsplit.")).overloads.add Overload(params: @[], returns: "int", call: c72_splitBar)
  controls.mgetOrPut("paneBeside", Control(name: "paneBeside", module: "business", doc: "A pane paneW logical pixels wide fits beside content that needs minMain (not on phones held upright).")).overloads.add Overload(params: @[Param(name: "paneW", typ: "int", default: "", kind: kInt), Param(name: "minMain", typ: "int", default: "320", kind: kInt)], returns: "bool", call: c73_paneBeside)
  controls.mgetOrPut("checkList", Control(name: "checkList", module: "business", doc: "A list with a check box on each item: a click, a tap or Space flips the item; Up, Down, Page Up, Page Down, Home, End move.")).overloads.add Overload(params: @[Param(name: "items", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "checked", typ: "var seq[bool]", default: "", kind: kNone), Param(name: "rows", typ: "int", default: "6", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: nil)
  controls.mgetOrPut("numberEdit", Control(name: "numberEdit", module: "business", doc: "A right-aligned number field; shows decimals places (0 to 12) and thousands separators when it does not have the focus. Only numbers from lo to hi are taken (true when v changed). Clicking or tabbing into it selects the number, so typing replaces it.")).overloads.add Overload(params: @[Param(name: "v", typ: "var float", default: "", kind: kVFloat), Param(name: "decimals", typ: "int", default: "2", kind: kInt), Param(name: "w", typ: "int", default: "110", kind: kInt), Param(name: "lo", typ: "", default: "NegInf", kind: kNone), Param(name: "hi", typ: "", default: "Inf", kind: kNone), Param(name: "thousands", typ: "bool", default: "true", kind: kBool), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c75_numberEdit)
  controls.mgetOrPut("intEdit", Control(name: "intEdit", module: "business", doc: "A right-aligned whole-number field. Only whole numbers from lo to hi are taken (true when v changed); clicking or tabbing into it selects the number, so typing replaces it.")).overloads.add Overload(params: @[Param(name: "v", typ: "var int", default: "", kind: kVInt), Param(name: "w", typ: "int", default: "80", kind: kInt), Param(name: "lo", typ: "", default: "low(int)", kind: kNone), Param(name: "hi", typ: "", default: "high(int)", kind: kNone), Param(name: "thousands", typ: "bool", default: "false", kind: kBool), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c76_intEdit)
  controls.mgetOrPut("comboEdit", Control(name: "comboEdit", module: "business", doc: "A text field that suggests matching items as you type (or lists them all from its button). Up/Down, Enter, Esc work in the list; none is picked until Down (or the mouse) points at one, so Enter on its own keeps what was typed.")).overloads.add Overload(params: @[Param(name: "text", typ: "var string", default: "", kind: kVStr), Param(name: "items", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c77_comboEdit)
  controls.mgetOrPut("link", Control(name: "link", module: "business", doc: "Underlined clickable text; true when clicked (or Enter/Space).")).overloads.add Overload(params: @[Param(name: "caption", typ: "string", default: "", kind: kStr), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c78_link)
  controls.mgetOrPut("buttonRow", Control(name: "buttonRow", module: "business", doc: "Buttons right-aligned in a row (the first is the default); returns which was clicked (1-based), 0 if none.")).overloads.add Overload(params: @[Param(name: "labels", typ: "openArray[string]", default: "", kind: kStrs)], returns: "int", call: c79_buttonRow)
  controls.mgetOrPut("icon", Control(name: "icon", module: "extras", doc: "An icon of the icon font (nfStar...) as a widget, size times the text size; returns where it is.")).overloads.add Overload(params: @[Param(name: "glyph", typ: "string", default: "", kind: kStr), Param(name: "color", typ: "Color", default: "Color()", kind: kColor), Param(name: "size", typ: "float", default: "1.0", kind: kFloat)], returns: "Rect", call: c80_icon)
  controls.mgetOrPut("iconLabel", Control(name: "iconLabel", module: "extras", doc: "An icon followed by a label: iconLabel(nfFolder, \"Documents\").")).overloads.add Overload(params: @[Param(name: "glyph", typ: "string", default: "", kind: kStr), Param(name: "s", typ: "string", default: "", kind: kStr), Param(name: "color", typ: "Color", default: "Color()", kind: kColor), Param(name: "iconColor", typ: "Color", default: "Color()", kind: kColor), Param(name: "bold", typ: "bool", default: "false", kind: kBool)], returns: "", call: c81_iconLabel)
  controls.mgetOrPut("heading", Control(name: "heading", module: "extras", doc: "A title in large bold text (level 1 largest .. 4).")).overloads.add Overload(params: @[Param(name: "s", typ: "string", default: "", kind: kStr), Param(name: "level", typ: "int", default: "1", kind: kInt), Param(name: "color", typ: "Color", default: "Color()", kind: kColor)], returns: "", call: c82_heading)
  controls.mgetOrPut("styledText", Control(name: "styledText", module: "extras", doc: "One line of text in any style (style(italic = true, size = 1.2)).")).overloads.add Overload(params: @[Param(name: "s", typ: "string", default: "", kind: kStr), Param(name: "st", typ: "TextStyle", default: "", kind: kNone), Param(name: "color", typ: "Color", default: "Color()", kind: kColor)], returns: "", call: nil)
  controls.mgetOrPut("searchBox", Control(name: "searchBox", module: "extras", doc: "A text box with a magnifier and a clear button; true when the text changed. Esc clears it.")).overloads.add Overload(params: @[Param(name: "s", typ: "var string", default: "", kind: kVStr), Param(name: "placeholder", typ: "string", default: "\"Search\"", kind: kStr), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c84_searchBox)
  controls.mgetOrPut("switchSize", Control(name: "switchSize", module: "extras", doc: "The size of a switch's slot (bigger on touch screens).")).overloads.add Overload(params: @[], returns: "tuple[w, h: int]", call: c85_switchSize)
  controls.mgetOrPut("switchAt", Control(name: "switchAt", module: "extras", doc: "The behavior of a slide switch at track (hit: the interaction of the widget it is part of, which may be bigger): a click or a tap flips it, the thumb can be slid with the mouse or a finger, Space flips it, Left / Right turn it off / on. Draws it; true when it changed.")).overloads.add Overload(params: @[Param(name: "id", typ: "Id", default: "", kind: kInt), Param(name: "track", typ: "Rect", default: "", kind: kRect), Param(name: "v", typ: "var bool", default: "", kind: kVBool), Param(name: "hit", typ: "var Hit", default: "", kind: kNone), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: nil)
  controls.mgetOrPut("toggle", Control(name: "toggle", module: "extras", doc: "An on/off slide switch with a label; true when flipped. Click, tap or slide it; Space, Left and Right with the focus; Alt + its letter.")).overloads.add Overload(params: @[Param(name: "label", typ: "string", default: "", kind: kStr), Param(name: "v", typ: "var bool", default: "", kind: kVBool), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c87_toggle)
  controls.mgetOrPut("segmented", Control(name: "segmented", module: "extras", doc: "Buttons joined in a row, one of them pressed in: a choice of a few. A click or a tap picks one; Left, Right, Home and End move the choice; Alt + a letter picks that one.")).overloads.add Overload(params: @[Param(name: "options", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "sel", typ: "var int", default: "", kind: kVInt), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c88_segmented)
  controls.mgetOrPut("chips", Control(name: "chips", module: "extras", doc: "Rounded tags in a row that wraps: filters, labels, recipients. One stop for Tab: Left / Right move between them, Space or Enter clicks one, Delete closes it (closable).")).overloads.add Overload(params: @[Param(name: "items", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "selected", typ: "openArray[bool]", default: "[]", kind: kNone), Param(name: "closable", typ: "bool", default: "false", kind: kBool), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "ChipEvent", call: c89_chips)
  controls.mgetOrPut("badge", Control(name: "badge", module: "extras", doc: "A small rounded count or status label (\"3\", \"NEW\").")).overloads.add Overload(params: @[Param(name: "s", typ: "string", default: "", kind: kStr), Param(name: "bg", typ: "Color", default: "color(200, 0, 0)", kind: kColor), Param(name: "fg", typ: "Color", default: "color(255, 255, 255)", kind: kColor)], returns: "", call: c90_badge)
  controls.mgetOrPut("rating", Control(name: "rating", module: "extras", doc: "Stars to click or tap, 0..stars; clicking the current one clears it. With the focus: Left / Right one star less / more, Home none, End all.")).overloads.add Overload(params: @[Param(name: "v", typ: "var int", default: "", kind: kVInt), Param(name: "stars", typ: "int", default: "5", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c91_rating)
  controls.mgetOrPut("spinner", Control(name: "spinner", module: "extras", doc: "A busy indicator: dots going round (animates by itself).")).overloads.add Overload(params: @[Param(name: "size", typ: "int", default: "0", kind: kInt), Param(name: "color", typ: "Color", default: "Color()", kind: kColor)], returns: "", call: c92_spinner)
  controls.mgetOrPut("dismissToast", Control(name: "dismissToast", module: "extras", doc: "Closes the balloon (toast) now.")).overloads.add Overload(params: @[], returns: "", call: c93_dismissToast)
  controls.mgetOrPut("toastShown", Control(name: "toastShown", module: "extras", doc: "A balloon (toast) is on screen.")).overloads.add Overload(params: @[], returns: "bool", call: c94_toastShown)
  controls.mgetOrPut("toastArea", Control(name: "toastArea", module: "extras", doc: "Where the balloon was drawn last (empty before the first one).")).overloads.add Overload(params: @[], returns: "Rect", call: c95_toastArea)
  controls.mgetOrPut("colorPicker", Control(name: "colorPicker", module: "extras", doc: "The 48 basic colors of the 3.1 color dialog to pick from (a click, a tap, or the arrow keys with the focus), a preview and a \"#RRGGBB\" box to type any color in. True when c changed.")).overloads.add Overload(params: @[Param(name: "c", typ: "var Color", default: "", kind: kNone), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: nil)
  controls.mgetOrPut("openColorDialog", Control(name: "openColorDialog", module: "extras", doc: "Opens the Color dialog for key at color c; colorDialogResult(key) gives the color chosen (colorWell does both).")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "c", typ: "Color", default: "", kind: kColor), Param(name: "title", typ: "string", default: "\"Color\"", kind: kStr)], returns: "", call: c97_openColorDialog)
  controls.mgetOrPut("colorDialogResult", Control(name: "colorDialogResult", module: "extras", doc: "True once, after OK in the Color dialog opened for key: c is set.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "c", typ: "var Color", default: "", kind: kNone)], returns: "bool", call: nil)
  controls.mgetOrPut("colorWell", Control(name: "colorWell", module: "extras", doc: "A swatch of c in a sunken frame: a click (Enter, Space) opens the Color dialog -- the basic and custom colors, the spectrum, Hue / Sat / Lum, Red / Green / Blue, \"#RRGGBB\" -- and OK sets c (true then). Use one wherever a color is chosen; key tells the wells apart.")).overloads.add Overload(params: @[Param(name: "c", typ: "var Color", default: "", kind: kNone), Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "title", typ: "string", default: "\"Color\"", kind: kStr), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: nil)
  controls.mgetOrPut("timePicker", Control(name: "timePicker", module: "extras", doc: "Hours (0..23) and minutes as two spin boxes.")).overloads.add Overload(params: @[Param(name: "h", typ: "var int", default: "", kind: kVInt), Param(name: "m", typ: "var int", default: "", kind: kVInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c100_timePicker)
  controls.mgetOrPut("lineView", Control(name: "lineView", module: "extras", doc: "A fast read-only view of count lines (only the visible ones are asked for): logs, big text files, hex dumps. A click (or the arrows) selects a line, Shift or a mouse drag extends, Ctrl+A all, Ctrl+C copies them. The wheel scrolls (Shift + the wheel sideways), a finger drags. wrap is off: long lines scroll sideways.")).overloads.add Overload(params: @[Param(name: "count", typ: "int", default: "", kind: kInt), Param(name: "line", typ: "proc (i: int): string", default: "", kind: kNone), Param(name: "sel", typ: "var int", default: "", kind: kVInt), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "mono", typ: "bool", default: "true", kind: kBool), Param(name: "numbers", typ: "bool", default: "false", kind: kBool), Param(name: "wrap", typ: "bool", default: "false", kind: kBool)], returns: "LineViewEvent", call: nil)
  controls.mgetOrPut("emptyState", Control(name: "emptyState", module: "extras", doc: "A framed area with a large glyph and a message (\"This folder is empty\", \"No results\"); h -1: the room left.")).overloads.add Overload(params: @[Param(name: "glyph", typ: "string", default: "", kind: kStr), Param(name: "msg", typ: "string", default: "", kind: kStr), Param(name: "h", typ: "int", default: "-1", kind: kInt), Param(name: "detail", typ: "string", default: "\"\"", kind: kStr)], returns: "", call: c102_emptyState)
  controls.mgetOrPut("busyState", Control(name: "busyState", module: "extras", doc: "A framed area with busy dots and a message (\"Loading...\").")).overloads.add Overload(params: @[Param(name: "msg", typ: "string", default: "", kind: kStr), Param(name: "h", typ: "int", default: "-1", kind: kInt)], returns: "", call: c103_busyState)
  controls.mgetOrPut("factList", Control(name: "factList", module: "extras", doc: "Label / value lines as a widget: factList({\"Size\": \"4.5 KB\", \"Modified\": \"today\"}); long values wrap under themselves.")).overloads.add Overload(params: @[Param(name: "facts", typ: "openArray[(string, string)]", default: "", kind: kNone), Param(name: "w", typ: "int", default: "0", kind: kInt)], returns: "", call: nil)
  controls.mgetOrPut("settingToggle", Control(name: "settingToggle", module: "extras", doc: "A settings row: a title, a line or two of detail, and a switch at the right; a click anywhere on the row flips it. True when it changed.")).overloads.add Overload(params: @[Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "v", typ: "var bool", default: "", kind: kVBool), Param(name: "detail", typ: "string", default: "\"\"", kind: kStr), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c105_settingToggle)
  controls.mgetOrPut("settingChoice", Control(name: "settingChoice", module: "extras", doc: "A settings row with a choice of a few (segmented buttons), under the title when the row is narrow.")).overloads.add Overload(params: @[Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "options", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "v", typ: "var int", default: "", kind: kVInt), Param(name: "detail", typ: "string", default: "\"\"", kind: kStr), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c106_settingChoice)
  controls.mgetOrPut("settingCombo", Control(name: "settingCombo", module: "extras", doc: "A settings row with a drop-down list at the right (a choice of many).")).overloads.add Overload(params: @[Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "options", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "v", typ: "var int", default: "", kind: kVInt), Param(name: "detail", typ: "string", default: "\"\"", kind: kStr), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c107_settingCombo)
  controls.mgetOrPut("settingSlider", Control(name: "settingSlider", module: "extras", doc: "A settings row with a slider and its value (\"120%\").")).overloads.add Overload(params: @[Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "v", typ: "var int", default: "", kind: kVInt), Param(name: "lo", typ: "int", default: "", kind: kInt), Param(name: "hi", typ: "int", default: "", kind: kInt), Param(name: "detail", typ: "string", default: "\"\"", kind: kStr), Param(name: "suffix", typ: "string", default: "\"\"", kind: kStr), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c108_settingSlider)
  controls.mgetOrPut("settingButtons", Control(name: "settingButtons", module: "extras", doc: "A settings row with buttons ([\"Smaller\", \"Normal\", \"Larger\"]); which was clicked (1-based), 0 if none.")).overloads.add Overload(params: @[Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "buttons", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "detail", typ: "string", default: "\"\"", kind: kStr), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "int", call: c109_settingButtons)
  controls.mgetOrPut("settingLink", Control(name: "settingLink", module: "extras", doc: "A settings row that leads somewhere (another page, a dialog): true when clicked.")).overloads.add Overload(params: @[Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "detail", typ: "string", default: "\"\"", kind: kStr), Param(name: "glyph", typ: "", default: "nfChevronRight", kind: kNone), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c110_settingLink)
  controls.mgetOrPut("appearanceSettings", Control(name: "appearanceSettings", module: "extras", doc: "Settings rows for how every app looks: the color scheme, the size of everything, the size of the text, the size of controls (for a mouse or fingers), the window's frame (on desktops: the system's or Windows 3.1's) and the font. True when something changed (store them with storeAppearance; app's look keeps them by itself).")).overloads.add Overload(params: @[], returns: "bool", call: c111_appearanceSettings)
  controls.mgetOrPut("initialsOf", Control(name: "initialsOf", module: "extras", doc: "\"Sultan Al-Said\" -> \"SA\" (the first letters of the first two words).")).overloads.add Overload(params: @[Param(name: "name", typ: "string", default: "", kind: kStr)], returns: "string", call: c112_initialsOf)
  controls.mgetOrPut("avatar", Control(name: "avatar", module: "extras", doc: "A round badge with someone's initials, in a color of their own (from the name); true when clicked.")).overloads.add Overload(params: @[Param(name: "name", typ: "string", default: "", kind: kStr), Param(name: "size", typ: "int", default: "0", kind: kInt), Param(name: "color", typ: "Color", default: "Color()", kind: kColor)], returns: "bool", call: c113_avatar)
  controls.mgetOrPut("stepper", Control(name: "stepper", module: "extras", doc: "The steps of a task (a wizard, a checkout) as numbered circles joined by a line: done ones ticked, the current one highlighted. Returns the step clicked (only steps already done can be), -1 if none.")).overloads.add Overload(params: @[Param(name: "steps", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "current", typ: "int", default: "", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "int", call: c114_stepper)
  controls.mgetOrPut("banner", Control(name: "banner", module: "extras", doc: "A colored strip with an icon, a message and buttons (\"Update\", \"Undo\"): the button clicked (1-based), 0 when closed with its x, -1 if none.")).overloads.add Overload(params: @[Param(name: "msg", typ: "string", default: "", kind: kStr), Param(name: "kind", typ: "BannerKind", default: "bkInfo", kind: kEnum), Param(name: "actions", typ: "openArray[string]", default: "[]", kind: kStrs), Param(name: "closable", typ: "bool", default: "true", kind: kBool)], returns: "int", call: c115_banner)
  controls.mgetOrPut("pager", Control(name: "pager", module: "extras", doc: "Page buttons: \"< 1 ... 4 5 6 ... 20 >\"; page is 0-based. True when it changed.")).overloads.add Overload(params: @[Param(name: "page", typ: "var int", default: "", kind: kVInt), Param(name: "pages", typ: "int", default: "", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c116_pager)
  controls.mgetOrPut("bottomNav", Control(name: "bottomNav", module: "extras", doc: "The navigation bar of a phone app at the bottom of the window: a glyph and a label per place ([(nfHome, \"Home\"), (nfSearch, \"Search\")]). Call it before the content (like statusbar). True when sel changed.")).overloads.add Overload(params: @[Param(name: "items", typ: "openArray[(string, string)]", default: "", kind: kNone), Param(name: "sel", typ: "var int", default: "", kind: kVInt)], returns: "bool", call: nil)
  controls.mgetOrPut("fab", Control(name: "fab", module: "extras", doc: "The round \"floating action button\" at the bottom right, over the content (the main action of a screen: new message, add item). Call it after the status or navigation bar and before the content.")).overloads.add Overload(params: @[Param(name: "glyph", typ: "string", default: "", kind: kStr), Param(name: "tip", typ: "string", default: "\"\"", kind: kStr), Param(name: "color", typ: "Color", default: "Color()", kind: kColor)], returns: "bool", call: c118_fab)
  controls.mgetOrPut("sparkline", Control(name: "sparkline", module: "extras", doc: "A tiny line chart without axes, for a trend next to a number.")).overloads.add Overload(params: @[Param(name: "values", typ: "openArray[float]", default: "", kind: kFloats), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "h", typ: "int", default: "0", kind: kInt), Param(name: "color", typ: "Color", default: "Color()", kind: kColor), Param(name: "fillUnder", typ: "bool", default: "true", kind: kBool)], returns: "", call: c119_sparkline)
  controls.mgetOrPut("progressRing", Control(name: "progressRing", module: "extras", doc: "A round progress indicator, value from 0.0 to 1.0.")).overloads.add Overload(params: @[Param(name: "value", typ: "float", default: "", kind: kFloat), Param(name: "size", typ: "int", default: "0", kind: kInt), Param(name: "color", typ: "Color", default: "Color()", kind: kColor), Param(name: "showText", typ: "bool", default: "true", kind: kBool)], returns: "", call: c120_progressRing)
  controls.mgetOrPut("usageBar", Control(name: "usageBar", module: "extras", doc: "How full something is (a drive): a bar, red when over 90%.")).overloads.add Overload(params: @[Param(name: "used", typ: "int64", default: "", kind: kInt), Param(name: "total", typ: "int64", default: "", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "h", typ: "int", default: "0", kind: kInt)], returns: "", call: c121_usageBar)
  controls.mgetOrPut("rangeSlider", Control(name: "rangeSlider", module: "morecontrols", doc: "A track bar with two thumbs, lo and hi (minV <= lo <= hi <= maxV): drag either (the nearer is taken), or the band between them to move both. Keys: arrows move the focused end (Tab... the left first; Shift+arrows the right). True when either changed.")).overloads.add Overload(params: @[Param(name: "lo", typ: "var int", default: "", kind: kVInt), Param(name: "hi", typ: "var int", default: "", kind: kVInt), Param(name: "minV", typ: "int", default: "", kind: kInt), Param(name: "maxV", typ: "int", default: "", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "ticks", typ: "int", default: "10", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c122_rangeSlider)
  controls.mgetOrPut("menuButton", Control(name: "menuButton", module: "morecontrols", doc: "A button with an arrow that drops a menu of items: the index chosen, or -1. (\"-\" in items is a separator.)")).overloads.add Overload(params: @[Param(name: "label", typ: "string", default: "", kind: kStr), Param(name: "items", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "int", call: c123_menuButton)
  controls.mgetOrPut("splitButton", Control(name: "splitButton", module: "morecontrols", doc: "A button whose left part does its default (clicked) and whose arrow part drops a menu of the other ways (chose: the index, else -1).")).overloads.add Overload(params: @[Param(name: "label", typ: "string", default: "", kind: kStr), Param(name: "items", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "tuple[clicked: bool, chose: int]", call: c124_splitButton)
  controls.mgetOrPut("tagInput", Control(name: "tagInput", module: "morecontrols", doc: "Tags as chips (each with its ×) and a box to type the next: Enter, a comma or Tab adds it, Backspace in the empty box takes the last off. True when the tags changed.")).overloads.add Overload(params: @[Param(name: "tags", typ: "var seq[string]", default: "", kind: kVStrs), Param(name: "text", typ: "var string", default: "", kind: kVStr), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool), Param(name: "placeholder", typ: "string", default: "\"Add a tag\"", kind: kStr)], returns: "bool", call: c125_tagInput)
  controls.mgetOrPut("autocomplete", Control(name: "autocomplete", module: "morecontrols", doc: "A text box whose list of choices that begin with (or hold) what is typed drops under it: Down and Up pick, Enter or Tab or a click takes one, Esc closes it. True when the text changed.")).overloads.add Overload(params: @[Param(name: "s", typ: "var string", default: "", kind: kVStr), Param(name: "choices", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "rows", typ: "int", default: "6", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c126_autocomplete)
  controls.mgetOrPut("knob", Control(name: "knob", module: "morecontrols", doc: "A round knob (a volume, a pan): drag up or right to turn it up, the wheel and the arrow keys too; its value under it.")).overloads.add Overload(params: @[Param(name: "v", typ: "var int", default: "", kind: kVInt), Param(name: "lo", typ: "int", default: "", kind: kInt), Param(name: "hi", typ: "int", default: "", kind: kInt), Param(name: "size", typ: "int", default: "0", kind: kInt), Param(name: "label", typ: "string", default: "\"\"", kind: kStr), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c127_knob)
  controls.mgetOrPut("led", Control(name: "led", module: "morecontrols", doc: "A small light: lit (in c, green when not given) or dark, with a label.")).overloads.add Overload(params: @[Param(name: "on", typ: "bool", default: "", kind: kBool), Param(name: "label", typ: "string", default: "\"\"", kind: kStr), Param(name: "c", typ: "Color", default: "Color()", kind: kColor)], returns: "", call: c128_led)
  controls.mgetOrPut("accordionHeader", Control(name: "accordionHeader", module: "morecontrols", doc: "One header of an accordion (sections of which one is open at a time): true when section index is the open one -- draw its contents then. A click opens it (or closes it when it was open: open -1).for i, t in [\"General\", \"Advanced\"]: if accordionHeader(t, i, openSection): label \"...\"")).overloads.add Overload(params: @[Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "index", typ: "int", default: "", kind: kInt), Param(name: "open", typ: "var int", default: "", kind: kVInt)], returns: "bool", call: c129_accordionHeader)
  controls.mgetOrPut("timeline", Control(name: "timeline", module: "morecontrols", doc: "Events down a line: their time, a dot (the current one filled), the title and a line of detail.")).overloads.add Overload(params: @[Param(name: "items", typ: "openArray[tuple[time, title, detail: string]]", default: "", kind: kNone), Param(name: "current", typ: "int", default: "-1", kind: kInt)], returns: "", call: nil)
  controls.mgetOrPut("pill", Control(name: "pill", module: "morecontrols", doc: "A short word in a colored, rounded tag (\"Paid\", \"Overdue\", \"New\").")).overloads.add Overload(params: @[Param(name: "text", typ: "string", default: "", kind: kStr), Param(name: "c", typ: "Color", default: "Color()", kind: kColor)], returns: "", call: c131_pill)
  controls.mgetOrPut("showSnackbar", Control(name: "showSnackbar", module: "morecontrols", doc: "Shows a bar at the bottom of the window saying what was just done (\"3 messages deleted\") with one action (action, \"\" none) for ms milliseconds: the Undo of today's apps. snackbar draws it and says when the action was clicked.")).overloads.add Overload(params: @[Param(name: "msg", typ: "string", default: "", kind: kStr), Param(name: "action", typ: "string", default: "\"Undo\"", kind: kStr), Param(name: "ms", typ: "int", default: "8000", kind: kInt)], returns: "", call: c132_showSnackbar)
  controls.mgetOrPut("snackbar", Control(name: "snackbar", module: "morecontrols", doc: "Draws the bar showSnackbar asked for (call it once a frame, after the window's content); true the frame its action is clicked (or Ctrl+Z pressed and no text box took it), which also takes the bar away.")).overloads.add Overload(params: @[], returns: "bool", call: c133_snackbar)
  controls.mgetOrPut("maskFormat", Control(name: "maskFormat", module: "records", doc: "value (the characters typed) laid into mask: maskFormat(\"96891234567\", \"+### #### ####\") is \"+968 9123 4567\"; slots not typed yet show blank. Mask characters: # or 9 a digit, A a letter, U a letter made upper case, L lower case, X a letter or digit, * any; \\ takes the next one as it is; the rest is shown as it is.")).overloads.add Overload(params: @[Param(name: "value", typ: "string", default: "", kind: kStr), Param(name: "mask", typ: "string", default: "", kind: kStr), Param(name: "blank", typ: "", default: "'_'", kind: kNone)], returns: "string", call: c134_maskFormat)
  controls.mgetOrPut("maskFull", Control(name: "maskFull", module: "records", doc: "Every slot of mask is typed, each with what it takes.")).overloads.add Overload(params: @[Param(name: "value", typ: "string", default: "", kind: kStr), Param(name: "mask", typ: "string", default: "", kind: kStr)], returns: "bool", call: c135_maskFull)
  controls.mgetOrPut("maskRaw", Control(name: "maskRaw", module: "records", doc: "The characters typed, from a text laid out like mask (or typed loosely: what does not fit the next slot is skipped).")).overloads.add Overload(params: @[Param(name: "text", typ: "string", default: "", kind: kStr), Param(name: "mask", typ: "string", default: "", kind: kStr)], returns: "string", call: c136_maskRaw)
  controls.mgetOrPut("maskedEdit", Control(name: "maskedEdit", module: "records", doc: "A field typed into mask (see maskFormat): the literals are there already, the caret jumps over them, only what a slot takes goes in (Arabic-Indic digits become digits). value holds the characters typed, without the literals (maskFormat shows them, maskFull tells when it is complete). Left, Right, Home, End, Backspace, Delete, Ctrl+C / Ctrl+V. True when value changed.")).overloads.add Overload(params: @[Param(name: "value", typ: "var string", default: "", kind: kVStr), Param(name: "mask", typ: "string", default: "", kind: kStr), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c137_maskedEdit)
  controls.mgetOrPut("recordNav", Control(name: "recordNav", module: "records", doc: "The navigator of a form over records: first, previous, \"Record 3 of 20\" (type a number to go there), next, last, then New, Delete, Save and Cancel (Save and Cancel while the record is dirty). pos is the record shown (0-based); the moves change it. Ctrl+Home / Ctrl+End, Ctrl+PageUp / Ctrl+PageDown move too. On phones it is shorter.")).overloads.add Overload(params: @[Param(name: "pos", typ: "var int", default: "", kind: kVInt), Param(name: "count", typ: "int", default: "", kind: kInt), Param(name: "dirty", typ: "bool", default: "false", kind: kBool), Param(name: "canAdd", typ: "bool", default: "true", kind: kBool), Param(name: "canDelete", typ: "bool", default: "true", kind: kBool), Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "RecordAction", call: c138_recordNav)
  controls.mgetOrPut("dualList", Control(name: "dualList", module: "records", doc: "Two lists and the buttons between them: > moves the item picked on the left to the right, >> all of them, < and << back; a double click (or Enter) moves an item across. Up / Down buttons order the chosen ones. On phones the lists are stacked. True when the lists changed.")).overloads.add Overload(params: @[Param(name: "available", typ: "var seq[string]", default: "", kind: kVStrs), Param(name: "chosen", typ: "var seq[string]", default: "", kind: kVStrs), Param(name: "rows", typ: "int", default: "8", kind: kInt), Param(name: "titles", typ: "", default: "(\"&Available:\", \"&Chosen:\")", kind: kNone), Param(name: "sortAvailable", typ: "bool", default: "true", kind: kBool), Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "bool", call: c139_dualList)
  controls.mgetOrPut("presetRange", Control(name: "presetRange", module: "records", doc: "The first and last day of the period p around day (weeks start on firstWeekday).")).overloads.add Overload(params: @[Param(name: "p", typ: "RangePreset", default: "", kind: kEnum), Param(name: "day", typ: "", default: "today()", kind: kNone)], returns: "tuple[a, b: Date]", call: c140_presetRange)
  controls.mgetOrPut("dateRange", Control(name: "dateRange", module: "records", doc: "From and to dates (each with its drop-down calendar) and, with presets, a list of periods (Today, This month, Last year...) that sets both; it shows the period the dates make, else \"Custom\". The \"to\" date is never before the \"from\" one. True when they changed.")).overloads.add Overload(params: @[Param(name: "a", typ: "var Date", default: "", kind: kNone), Param(name: "b", typ: "var Date", default: "", kind: kNone), Param(name: "presets", typ: "bool", default: "true", kind: kBool), Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "bool", call: nil)
  controls.mgetOrPut("textProp", Control(name: "textProp", module: "records", doc: "A line of text to edit.")).overloads.add Overload(params: @[Param(name: "name", typ: "string", default: "", kind: kStr), Param(name: "value", typ: "string", default: "", kind: kStr), Param(name: "category", typ: "string", default: "\"\"", kind: kStr), Param(name: "help", typ: "string", default: "\"\"", kind: kStr)], returns: "Prop", call: c142_textProp)
  controls.mgetOrPut("numberProp", Control(name: "numberProp", module: "records", doc: "A number to edit, shown with decimals places.")).overloads.add Overload(params: @[Param(name: "name", typ: "string", default: "", kind: kStr), Param(name: "value", typ: "float", default: "", kind: kFloat), Param(name: "decimals", typ: "int", default: "2", kind: kInt), Param(name: "category", typ: "string", default: "\"\"", kind: kStr), Param(name: "help", typ: "string", default: "\"\"", kind: kStr)], returns: "Prop", call: c143_numberProp)
  controls.mgetOrPut("intProp", Control(name: "intProp", module: "records", doc: "A whole number to edit.")).overloads.add Overload(params: @[Param(name: "name", typ: "string", default: "", kind: kStr), Param(name: "value", typ: "int", default: "", kind: kInt), Param(name: "category", typ: "string", default: "\"\"", kind: kStr), Param(name: "help", typ: "string", default: "\"\"", kind: kStr)], returns: "Prop", call: c144_intProp)
  controls.mgetOrPut("boolProp", Control(name: "boolProp", module: "records", doc: "A check box.")).overloads.add Overload(params: @[Param(name: "name", typ: "string", default: "", kind: kStr), Param(name: "value", typ: "bool", default: "", kind: kBool), Param(name: "category", typ: "string", default: "\"\"", kind: kStr), Param(name: "help", typ: "string", default: "\"\"", kind: kStr)], returns: "Prop", call: c145_boolProp)
  controls.mgetOrPut("choiceProp", Control(name: "choiceProp", module: "records", doc: "One of choices (chosen is the index of the one chosen).")).overloads.add Overload(params: @[Param(name: "name", typ: "string", default: "", kind: kStr), Param(name: "choices", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "chosen", typ: "int", default: "0", kind: kInt), Param(name: "category", typ: "string", default: "\"\"", kind: kStr), Param(name: "help", typ: "string", default: "\"\"", kind: kStr)], returns: "Prop", call: c146_choiceProp)
  controls.mgetOrPut("colorProp", Control(name: "colorProp", module: "records", doc: "A color to pick.")).overloads.add Overload(params: @[Param(name: "name", typ: "string", default: "", kind: kStr), Param(name: "value", typ: "Color", default: "", kind: kColor), Param(name: "category", typ: "string", default: "\"\"", kind: kStr), Param(name: "help", typ: "string", default: "\"\"", kind: kStr)], returns: "Prop", call: c147_colorProp)
  controls.mgetOrPut("dateProp", Control(name: "dateProp", module: "records", doc: "A date to pick.")).overloads.add Overload(params: @[Param(name: "name", typ: "string", default: "", kind: kStr), Param(name: "value", typ: "Date", default: "", kind: kNone), Param(name: "category", typ: "string", default: "\"\"", kind: kStr), Param(name: "help", typ: "string", default: "\"\"", kind: kStr)], returns: "Prop", call: nil)
  controls.mgetOrPut("infoProp", Control(name: "infoProp", module: "records", doc: "Text shown, not edited.")).overloads.add Overload(params: @[Param(name: "name", typ: "string", default: "", kind: kStr), Param(name: "value", typ: "string", default: "", kind: kStr), Param(name: "category", typ: "string", default: "\"\"", kind: kStr), Param(name: "help", typ: "string", default: "\"\"", kind: kStr)], returns: "Prop", call: c149_infoProp)
  controls.mgetOrPut("valueText", Control(name: "valueText", module: "records", doc: "A property's value as the grid shows it.")).overloads.add Overload(params: @[Param(name: "p", typ: "Prop", default: "", kind: kEnum)], returns: "string", call: nil)
  controls.mgetOrPut("propertyGrid", Control(name: "propertyGrid", module: "records", doc: "Properties as names and values in two columns, by category (a category folds away with its [-] box), the chosen one edited in place: text and numbers typed, Yes / No flipped with a click or Space, choices dropped down (or flipped through with a double click), colors typed as #RRGGBB or picked, dates with their calendar. The help line under it tells what the chosen property is. Up / Down move, Ente")).overloads.add Overload(params: @[Param(name: "props", typ: "var seq[Prop]", default: "", kind: kNone), Param(name: "sel", typ: "var int", default: "", kind: kVInt), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "help", typ: "bool", default: "true", kind: kBool), Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "int", call: nil)
  controls.mgetOrPut("treeGrid", Control(name: "treeGrid", module: "records", doc: "A tree whose rows have columns (accounts with their balances, parts with their quantities): rows with deeper rows after them open and close with their [+] box, a double click, Right / Left or Space; Up, Down, Page Up, Page Down, Home, End move; Enter (or a double click on a row without children) activates. Drag a header's edge to resize its column. height in rows (-1 fills). Parents are bold.")).overloads.add Overload(params: @[Param(name: "cols", typ: "var seq[Column]", default: "", kind: kNone), Param(name: "rows", typ: "var seq[TreeRow]", default: "", kind: kNone), Param(name: "sel", typ: "var int", default: "", kind: kVInt), Param(name: "height", typ: "int", default: "10", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "boldParents", typ: "bool", default: "true", kind: kBool)], returns: "TreeGridEvent", call: nil)
  controls.mgetOrPut("stepDone", Control(name: "stepDone", module: "records", doc: "In a wizard's page: Next (or Finish) is enabled only when ok (what this page asks is filled in).")).overloads.add Overload(params: @[Param(name: "ok", typ: "bool", default: "", kind: kBool)], returns: "", call: c153_stepDone)
  controls.mgetOrPut("paletteTabs", Control(name: "paletteTabs", module: "desktop", doc: "The tabs of a palette that holds several (Brushes and Options, Layers, Channels and Paths...): the one shown joined to the palette, the others behind it; with menu, the little arrow at the right that opens the palette's menu (menu reported). (The docked panels' look: paletteTabFace.)")).overloads.add Overload(params: @[Param(name: "labels", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "sel", typ: "var int", default: "", kind: kVInt), Param(name: "menu", typ: "bool", default: "true", kind: kBool)], returns: "tuple[changed, menu: bool]", call: c154_paletteTabs)
  controls.mgetOrPut("mdiCascade", Control(name: "mdiCascade", module: "desktop", doc: "Overlaps the windows of the area, each a title bar lower.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "", call: c155_mdiCascade)
  controls.mgetOrPut("mdiTile", Control(name: "mdiTile", module: "desktop", doc: "Lays the windows of the area side by side.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "", call: c156_mdiTile)
  controls.mgetOrPut("mdiActivate", Control(name: "mdiActivate", module: "desktop", doc: "Brings w to the front (restored when it was minimized).")).overloads.add Overload(params: @[Param(name: "w", typ: "var MdiWindow", default: "", kind: kNone), Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "", call: nil)
  controls.mgetOrPut("mdiWindowMenu", Control(name: "mdiWindowMenu", module: "desktop", doc: "The items of a 3.1 Window menu (inside menu \"&Window\":): Cascade, Tile, then the windows, the active one checked.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "", call: c158_mdiWindowMenu)
  controls.mgetOrPut("findIn", Control(name: "findIn", module: "desktop", doc: "Where what is in text from start on (backwards: before it); it goes round the end when wrap. -1 when it is not there.")).overloads.add Overload(params: @[Param(name: "text", typ: "string", default: "", kind: kStr), Param(name: "what", typ: "string", default: "", kind: kStr), Param(name: "start", typ: "int", default: "", kind: kInt), Param(name: "matchCase", typ: "bool", default: "false", kind: kBool), Param(name: "wholeWord", typ: "bool", default: "false", kind: kBool), Param(name: "backwards", typ: "bool", default: "false", kind: kBool), Param(name: "wrap", typ: "bool", default: "true", kind: kBool)], returns: "int", call: c159_findIn)
  controls.mgetOrPut("replaceAllIn", Control(name: "replaceAllIn", module: "desktop", doc: "Replaces every match; returns how many.")).overloads.add Overload(params: @[Param(name: "text", typ: "var string", default: "", kind: kVStr), Param(name: "what", typ: "string", default: "", kind: kStr), Param(name: "with", typ: "string", default: "", kind: kStr), Param(name: "matchCase", typ: "bool", default: "false", kind: kBool), Param(name: "wholeWord", typ: "bool", default: "false", kind: kBool)], returns: "int", call: c160_replaceAllIn)
  controls.mgetOrPut("findBar", Control(name: "findBar", module: "desktop", doc: "A bar to find (and replace) text in: Enter or F3 finds the next match, Shift+Enter or Shift+F3 the previous one, Esc closes it. With replacing, a second line replaces the match or all of them. The app does the finding (findIn, replaceAllIn) on its text.")).overloads.add Overload(params: @[Param(name: "f", typ: "var FindState", default: "", kind: kNone), Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "FindEvent", call: nil)
  controls.mgetOrPut("hotkeyText", Control(name: "hotkeyText", module: "desktop", doc: "\"Ctrl+Shift+S\" for Ctrl + Shift + S; on a Mac \"Cmd+Shift+S\" -- Cmd is reported as Ctrl there, the Control key as the Gui key (\"Control+\"), Option as Alt (\"Option+\") -- elsewhere the Gui key is \"Win+\".")).overloads.add Overload(params: @[Param(name: "key", typ: "KeyCode", default: "", kind: kEnum), Param(name: "mods", typ: "set[Modifier]", default: "", kind: kSet)], returns: "string", call: c162_hotkeyText)
  controls.mgetOrPut("parseHotkey", Control(name: "parseHotkey", module: "desktop", doc: "\"Ctrl+Shift+S\" -> (KeyS, {CtrlPressed, ShiftPressed}); KeyNone when it is not a shortcut. \"Cmd\" is Ctrl on every system (the key shortcuts are made with: Cmd on a Mac, Ctrl elsewhere), so a shortcut kept on one is the same on the others; \"Control\" is a Mac's Control key there (the Gui key), Ctrl elsewhere.")).overloads.add Overload(params: @[Param(name: "s", typ: "string", default: "", kind: kStr)], returns: "tuple[key: KeyCode, mods: set[Modifier]]", call: c163_parseHotkey)
  controls.mgetOrPut("hotkeyPressed", Control(name: "hotkeyPressed", module: "desktop", doc: "The shortcut s (\"Ctrl+S\") was pressed this frame (and not used yet); uses it. On a Mac \"Ctrl+S\" is Cmd+S, as s written either way.")).overloads.add Overload(params: @[Param(name: "s", typ: "string", default: "", kind: kStr)], returns: "bool", call: c164_hotkeyPressed)
  controls.mgetOrPut("hotkeyEdit", Control(name: "hotkeyEdit", module: "desktop", doc: "A box that takes the next key pressed, with its Ctrl, Alt and Shift, as a shortcut (\"Ctrl+Shift+S\"); Backspace or Delete alone clears it, Tab and Esc leave it. True when it changed.")).overloads.add Overload(params: @[Param(name: "keys", typ: "var string", default: "", kind: kVStr), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c165_hotkeyEdit)
  controls.mgetOrPut("keymapPressed", Control(name: "keymapPressed", module: "desktop", doc: "The command whose shortcut was pressed this frame (\"\" none); the key is used.")).overloads.add Overload(params: @[Param(name: "km", typ: "Keymap", default: "", kind: kNone)], returns: "string", call: nil)
  controls.mgetOrPut("keymapEditor", Control(name: "keymapEditor", module: "desktop", doc: "Rows to change the shortcuts: the commands (with theirs), the one chosen's box -- press the keys -- and Use Default. True when one changed.")).overloads.add Overload(params: @[Param(name: "km", typ: "var Keymap", default: "", kind: kNone), Param(name: "commands", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "height", typ: "int", default: "260", kind: kInt)], returns: "bool", call: nil)
  controls.mgetOrPut("splashBox", Control(name: "splashBox", module: "desktop", doc: "The box a program shows while it starts, as the About box looks: a picture (art, else the blue of a 1994 Setup screen) with the icon, the name large and the version over it, a rainbow under it; then tagline, lines, a 3.1 progress bar of blocks (progress 0 .. 1; none when less than 0) and note. Drawn over everything, in the middle of the window.")).overloads.add Overload(params: @[Param(name: "app", typ: "string", default: "", kind: kStr), Param(name: "version", typ: "string", default: "\"\"", kind: kStr), Param(name: "tagline", typ: "string", default: "\"\"", kind: kStr), Param(name: "lines", typ: "openArray[string]", default: "[]", kind: kStrs), Param(name: "art", typ: "Bitmap", default: "nil", kind: kNone), Param(name: "icon", typ: "Bitmap", default: "nil", kind: kNone), Param(name: "iconPng", typ: "string", default: "\"\"", kind: kStr), Param(name: "glyph", typ: "string", default: "\"\"", kind: kStr), Param(name: "progress", typ: "float", default: "-1.0", kind: kFloat), Param(name: "note", typ: "string", default: "\"Starting...\"", kind: kStr), Param(name: "width", typ: "int", default: "460", kind: kInt)], returns: "", call: c168_splashBox)
  controls.mgetOrPut("aboutBox", Control(name: "aboutBox", module: "desktop", doc: "The About dialog: a banner in the blue of a 1994 Setup screen with the program's icon (icon, or a PNG's bytes in iconPng, else glyph), its name, version and tagline; then pages (tabs as the docked panels'): About -- lines (what it is, copyright, licence; each wraps) and what it runs on; What's New -- whatsNew, a line each; Credits -- credits. Copy Info puts the facts on the clipboard; OK closes it")).overloads.add Overload(params: @[Param(name: "open", typ: "var bool", default: "", kind: kVBool), Param(name: "app", typ: "string", default: "", kind: kStr), Param(name: "version", typ: "string", default: "\"\"", kind: kStr), Param(name: "lines", typ: "openArray[string]", default: "[]", kind: kStrs), Param(name: "glyph", typ: "string", default: "\"\"", kind: kStr), Param(name: "width", typ: "int", default: "460", kind: kInt), Param(name: "tagline", typ: "string", default: "\"\"", kind: kStr), Param(name: "whatsNew", typ: "openArray[string]", default: "[]", kind: kStrs), Param(name: "credits", typ: "openArray[string]", default: "[]", kind: kStrs), Param(name: "icon", typ: "Bitmap", default: "nil", kind: kNone), Param(name: "iconPng", typ: "string", default: "\"\"", kind: kStr), Param(name: "url", typ: "string", default: "\"\"", kind: kStr)], returns: "", call: c169_aboutBox)
  controls.mgetOrPut("reportProblem", Control(name: "reportProblem", module: "desktop", doc: "Opens the \"Report a Problem\" box (Help > Report a Problem; draw it with problemBox): text, else what the fault log holds (takeFaults), for the user to add what they were doing, then copy or send.")).overloads.add Overload(params: @[Param(name: "text", typ: "string", default: "\"\"", kind: kStr)], returns: "", call: c170_reportProblem)
  controls.mgetOrPut("problemBox", Control(name: "problemBox", module: "desktop", doc: "Call it every frame: the \"Report a Problem\" box when it is open -- and, the first time, opened by itself when the last run left faults (the program stopped, or guarded caught one). Copy puts the report on the clipboard; Send by Email writes it to the developer.")).overloads.add Overload(params: @[Param(name: "app", typ: "string", default: "", kind: kStr), Param(name: "version", typ: "string", default: "\"\"", kind: kStr)], returns: "", call: c171_problemBox)
  controls.mgetOrPut("customizeToolbar", Control(name: "customizeToolbar", module: "toolcustom", doc: "The Customize Toolbar dialog while open. True when it changed the bar (keys, in order) or the look of its labels (look).")).overloads.add Overload(params: @[Param(name: "open", typ: "var bool", default: "", kind: kVBool), Param(name: "keys", typ: "var seq[string]", default: "", kind: kVStrs), Param(name: "available", typ: "openArray[ToolChoice]", default: "", kind: kNone), Param(name: "defaults", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "look", typ: "var ButtonLook", default: "", kind: kNone), Param(name: "title", typ: "string", default: "\"Customize Toolbar\"", kind: kStr)], returns: "bool", call: nil)
  controls.mgetOrPut("panelHeader", Control(name: "panelHeader", module: "dock", doc: "The strip at the top of a docked column or a toolbar, as today's Photoshop has it, in the title bar's color (navy in 3.1) with a double arrow pointing dir (white): true when the arrows are clicked (a column collapsed to icons or opened, a toolbar one column or two).")).overloads.add Overload(params: @[Param(name: "r", typ: "Rect", default: "", kind: kRect), Param(name: "id", typ: "Id", default: "", kind: kInt), Param(name: "dir", typ: "Dir", default: "", kind: kEnum), Param(name: "tip", typ: "string", default: "\"\"", kind: kStr), Param(name: "side", typ: "HeaderSide", default: "hsRight", kind: kEnum)], returns: "bool", call: nil)
  controls.mgetOrPut("dockPanels", Control(name: "dockPanels", module: "dock", doc: "Draws the dock down the right of the mdiArea named area (call it inside, after the documents' windows), its floating palettes, and what a drag of a panel shows. body(key) draws a panel (in a column laid out as a palette's: place, row, the widgets); menu(key) its menu's items (menuItem...), Close and Close Tab Group after them. left says where the documents' room ends.")).overloads.add Overload(params: @[Param(name: "d", typ: "Dock", default: "", kind: kNone), Param(name: "area", typ: "string", default: "\"\"", kind: kStr), Param(name: "body", typ: "proc (key: string)", default: "", kind: kNone), Param(name: "menu", typ: "proc (key: string)", default: "nil", kind: kNone)], returns: "DockEvent", call: nil)
  controls.mgetOrPut("fontSample", Control(name: "fontSample", module: "textwidgets", doc: "text in a font, h screen pixels tall (kept: drawn once).")).overloads.add Overload(params: @[Param(name: "family", typ: "string", default: "", kind: kStr), Param(name: "style", typ: "string", default: "", kind: kStr), Param(name: "text", typ: "string", default: "", kind: kStr), Param(name: "h", typ: "int", default: "", kind: kInt), Param(name: "color", typ: "", default: "0xFF000000'u32", kind: kNone)], returns: "Bitmap", call: c175_fontSample)
  controls.mgetOrPut("fontCombo", Control(name: "fontCombo", module: "textwidgets", doc: "A drop-down list of the font families (the system's and the built-in ones), each shown in its own letters.")).overloads.add Overload(params: @[Param(name: "family", typ: "var string", default: "", kind: kVStr), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c176_fontCombo)
  controls.mgetOrPut("fontStyleCombo", Control(name: "fontStyleCombo", module: "textwidgets", doc: "The styles of family (\"Regular\", \"Bold\"...), each in its letters.")).overloads.add Overload(params: @[Param(name: "family", typ: "string", default: "", kind: kStr), Param(name: "style", typ: "var string", default: "", kind: kVStr), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c177_fontStyleCombo)
  controls.mgetOrPut("fileIcon", Control(name: "fileIcon", module: "filewidgets", doc: "fileGlyph as an icon size logical pixels square.")).overloads.add Overload(params: @[Param(name: "f", typ: "FileItem", default: "", kind: kNone), Param(name: "size", typ: "int", default: "16", kind: kInt)], returns: "Icon", call: nil)
  controls.mgetOrPut("pictureBox", Control(name: "pictureBox", module: "filewidgets", doc: "A picture as a widget, w x h (0: the room there is): busy dots while it is decoded, an icon if it cannot be.")).overloads.add Overload(params: @[Param(name: "path", typ: "string", default: "", kind: kStr), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "h", typ: "int", default: "0", kind: kInt), Param(name: "stamp", typ: "", default: "0'i64", kind: kNone), Param(name: "frame", typ: "bool", default: "true", kind: kBool)], returns: "", call: c179_pictureBox)
  controls.mgetOrPut("filePreview", Control(name: "filePreview", module: "filewidgets", doc: "The details pane of m: the item the mouse rests on (followHover), else what is selected, else the folder (see the filePreview of items for what it shows; buttons: Open / Share / Properties; height: -1 the rest of the column).")).overloads.add Overload(params: @[Param(name: "m", typ: "FolderModel", default: "", kind: kNone), Param(name: "buttons", typ: "bool", default: "true", kind: kBool), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "followHover", typ: "bool", default: "true", kind: kBool)], returns: "PreviewEvent", call: nil)
  controls.mgetOrPut("fileList", Control(name: "fileList", module: "filewidgets", doc: "The items of m as rows with columns (fvDetails), large icons (fvIcons, iconSize design pixels; pictures as thumbnails decoded in the background) or tiles. Click, Ctrl+click, Shift+click, a selection rectangle, arrows, type-ahead and (on phones) check boxes select; double click, Enter or (with tapActivates) a tap activates; headers sort; F2 or a slow second click edits a name. With dragDrop, the se")).overloads.add Overload(params: @[Param(name: "m", typ: "FolderModel", default: "", kind: kNone), Param(name: "view", typ: "FileView", default: "fvDetails", kind: kEnum), Param(name: "thumbnails", typ: "bool", default: "true", kind: kBool), Param(name: "bigIcons", typ: "bool", default: "true", kind: kBool), Param(name: "tapActivates", typ: "bool", default: "false", kind: kBool), Param(name: "checkboxes", typ: "bool", default: "false", kind: kBool), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "iconSize", typ: "int", default: "0", kind: kInt), Param(name: "dragDrop", typ: "bool", default: "true", kind: kBool)], returns: "FileListEvent", call: nil)
  controls.mgetOrPut("filePreview", Control(name: "filePreview", module: "filewidgets", doc: "The details pane: for one item its picture (decoded in the background) or the start of its text, its size (a folder's is measured as you look), dates and kind, and Open / Share / Properties; for several items their count and size; for none the folder and folderStats. Tall, the picture is above the details; wide (under a list on a phone), at their left.")).overloads.add Overload(params: @[Param(name: "items", typ: "openArray[FileItem]", default: "", kind: kNone), Param(name: "folder", typ: "string", default: "\"\"", kind: kStr), Param(name: "folderStats", typ: "", default: "(files: 0, folders: 0, bytes: 0'i64)", kind: kNone), Param(name: "buttons", typ: "bool", default: "true", kind: kBool), Param(name: "height", typ: "int", default: "-1", kind: kInt)], returns: "PreviewEvent", call: nil)
  controls.mgetOrPut("driveBar", Control(name: "driveBar", module: "filewidgets", doc: "The drive bar of the 1990s file managers, for today's places: a strip of small buttons (home, documents, downloads, the disks and cards, the favorites, the extra ones such as the trash), the one holding current framed. A click goes there; files dropped on one go there. It scrolls (the wheel, a finger) when it does not fit.")).overloads.add Overload(params: @[Param(name: "current", typ: "string", default: "", kind: kStr), Param(name: "favorites", typ: "openArray[string]", default: "[]", kind: kStrs), Param(name: "extra", typ: "openArray[tuple[label, glyph, id: string]]", default: "[]", kind: kNone), Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "DriveBarEvent", call: c183_driveBar)
  controls.mgetOrPut("folderTree", Control(name: "folderTree", module: "filewidgets", doc: "The places of the device (home, documents, storage, drives...) and favorites, each opening into its folders (read when opened). Files can be dragged onto its folders (a closed one opens when a drag rests on it). picked when the user picked a folder: selected. extra nodes come first ((\"This device\", nfDesktop, \"::device\")); picking one sets selected to its id. padding: room inside its frame.")).overloads.add Overload(params: @[Param(name: "selected", typ: "var string", default: "", kind: kVStr), Param(name: "favorites", typ: "openArray[string]", default: "[]", kind: kStrs), Param(name: "showHidden", typ: "bool", default: "false", kind: kBool), Param(name: "rows", typ: "int", default: "-1", kind: kInt), Param(name: "extra", typ: "openArray[tuple[label, glyph, id: string]]", default: "[]", kind: kNone), Param(name: "padding", typ: "int", default: "0", kind: kInt)], returns: "FolderTreeEvent", call: c184_folderTree)
  controls.mgetOrPut("pathBar", Control(name: "pathBar", module: "filewidgets", doc: "The folder path as a row of its folders, as in Windows Explorer: click one to go there, click the arrow after it for a menu of the folders in it, \"<<\" for the folders that do not fit, drop files on one to move them there (ev.go / ev.drop); a click on the empty part, or editNow (F4, Alt+D, Ctrl+L), turns it into a box to type a path in, with the folders that match suggested. key tells several apart")).overloads.add Overload(params: @[Param(name: "path", typ: "string", default: "", kind: kStr), Param(name: "key", typ: "string", default: "\"\"", kind: kStr), Param(name: "editNow", typ: "bool", default: "false", kind: kBool), Param(name: "w", typ: "int", default: "0", kind: kInt)], returns: "PathBarEvent", call: c185_pathBar)
  controls.mgetOrPut("textFileView", Control(name: "textFileView", module: "filewidgets", doc: "The lines of a TextFile (any size): its lines are counted a few milliseconds a frame while the first ones are shown already.")).overloads.add Overload(params: @[Param(name: "t", typ: "TextFile", default: "", kind: kNone), Param(name: "sel", typ: "var int", default: "", kind: kVInt), Param(name: "numbers", typ: "bool", default: "true", kind: kBool), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt)], returns: "LineViewEvent", call: nil)
  controls.mgetOrPut("hexFileView", Control(name: "hexFileView", module: "filewidgets", doc: "Any file as hex dump lines (read as they are shown).")).overloads.add Overload(params: @[Param(name: "h", typ: "HexFile", default: "", kind: kNone), Param(name: "sel", typ: "var int", default: "", kind: kVInt), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt)], returns: "LineViewEvent", call: nil)
  controls.mgetOrPut("runJobDialog", Control(name: "runJobDialog", module: "filewidgets", doc: "Runs job a slice a frame with a progress box (Cancel stops it) and, when a name is taken, asks \"Replace / Keep both / Skip\" (for all the others too if wanted). True once the job is over (done or cancelled).")).overloads.add Overload(params: @[Param(name: "job", typ: "FileJob", default: "", kind: kNone), Param(name: "title", typ: "string", default: "", kind: kStr)], returns: "bool", call: nil)
  controls.mgetOrPut("propertiesDialog", Control(name: "propertiesDialog", module: "filewidgets", doc: "The properties of items while open: location, size (folders are measured while it is open), what they contain, dates, permissions, where a link goes. True the frame it closes.")).overloads.add Overload(params: @[Param(name: "open", typ: "var bool", default: "", kind: kVBool), Param(name: "items", typ: "openArray[FileItem]", default: "", kind: kNone)], returns: "bool", call: nil)
  controls.mgetOrPut("storageDialog", Control(name: "storageDialog", module: "filewidgets", doc: "The dialog of askStorage (draw it every frame, with the others).")).overloads.add Overload(params: @[], returns: "", call: c190_storageDialog)
  controls.mgetOrPut("filePicker", Control(name: "filePicker", module: "filewidgets", doc: "A modern Open / Save dialog while open (the whole screen on a phone): places, a path bar, the folder as a list (listed in the background, folders first, natural order), and for saving a name. True once, with path set, when the user picks a file. patterns limits the files shown ([\"*.png\", \"*.jpg\"]). fmFolder picks a folder instead: only folders are shown, and Choose takes the one selected (or the o")).overloads.add Overload(params: @[Param(name: "open", typ: "var bool", default: "", kind: kVBool), Param(name: "path", typ: "var string", default: "", kind: kVStr), Param(name: "mode", typ: "FileMode", default: "fmOpen", kind: kEnum), Param(name: "patterns", typ: "openArray[string]", default: "[]", kind: kStrs), Param(name: "title", typ: "string", default: "\"\"", kind: kStr), Param(name: "preview", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: nil)
  controls.mgetOrPut("placesView", Control(name: "placesView", module: "filewidgets", doc: "\"This device\": the places (home, documents, storage, drives) and the favorites as tiles with how full their disks are; the folder clicked, \"\" if none.")).overloads.add Overload(params: @[Param(name: "favorites", typ: "openArray[string]", default: "[]", kind: kStrs), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "string", call: c192_placesView)
  controls.mgetOrPut("trashList", Control(name: "trashList", module: "filewidgets", doc: "The trash: its items (name, where they were, when deleted, size) with Restore, Delete forever and Empty the trash. Files dropped on it go to the trash (reported in changed).")).overloads.add Overload(params: @[Param(name: "t", typ: "TrashList", default: "", kind: kNone), Param(name: "height", typ: "int", default: "-1", kind: kInt)], returns: "TrashEvent", call: nil)
  controls.mgetOrPut("series", Control(name: "series", module: "charts", doc: "A series of values, one per label.")).overloads.add Overload(params: @[Param(name: "name", typ: "string", default: "", kind: kStr), Param(name: "values", typ: "openArray[float]", default: "", kind: kFloats), Param(name: "color", typ: "Color", default: "Color()", kind: kColor)], returns: "Series", call: c194_series)
  controls.mgetOrPut("lineSeries", Control(name: "lineSeries", module: "charts", doc: "A series a combo chart draws as a line on its right axis.")).overloads.add Overload(params: @[Param(name: "name", typ: "string", default: "", kind: kStr), Param(name: "values", typ: "openArray[float]", default: "", kind: kFloats), Param(name: "color", typ: "Color", default: "Color()", kind: kColor)], returns: "Series", call: c195_lineSeries)
  controls.mgetOrPut("xySeries", Control(name: "xySeries", module: "charts", doc: "Points for scatter and bubble charts.")).overloads.add Overload(params: @[Param(name: "name", typ: "string", default: "", kind: kStr), Param(name: "xs", typ: "openArray[float]", default: "", kind: kFloats), Param(name: "ys", typ: "openArray[float]", default: "", kind: kFloats), Param(name: "sizes", typ: "openArray[float]", default: "[]", kind: kFloats), Param(name: "color", typ: "Color", default: "Color()", kind: kColor)], returns: "Series", call: c196_xySeries)
  controls.mgetOrPut("ohlcSeries", Control(name: "ohlcSeries", module: "charts", doc: "Prices for candlesticks.")).overloads.add Overload(params: @[Param(name: "name", typ: "string", default: "", kind: kStr), Param(name: "opens", typ: "openArray[float]", default: "", kind: kFloats), Param(name: "highs", typ: "openArray[float]", default: "", kind: kFloats), Param(name: "lows", typ: "openArray[float]", default: "", kind: kFloats), Param(name: "closes", typ: "openArray[float]", default: "", kind: kFloats), Param(name: "color", typ: "Color", default: "Color()", kind: kColor)], returns: "Series", call: c197_ohlcSeries)
  controls.mgetOrPut("parseCsv", Control(name: "parseCsv", module: "charts", doc: "Reads CSV text: fields separated by sep ('\\0': ,, ; or tab, whichever the first line has most of), quoted fields with \"\" and line breaks in them, CRLF or LF lines, a byte-order mark. The first row is the header (header false, or a first row of numbers only: the columns are named \"Column 1\"...). Huge inputs are cut short.")).overloads.add Overload(params: @[Param(name: "text", typ: "string", default: "", kind: kStr), Param(name: "sep", typ: "", default: "'\\x00'", kind: kNone), Param(name: "header", typ: "bool", default: "true", kind: kBool)], returns: "DataTable", call: c198_parseCsv)
  controls.mgetOrPut("readCsv", Control(name: "readCsv", module: "charts", doc: "The CSV file path as a table (see parseCsv); error tells why when it cannot be read (it never raises).")).overloads.add Overload(params: @[Param(name: "path", typ: "string", default: "", kind: kStr), Param(name: "sep", typ: "", default: "'\\x00'", kind: kNone), Param(name: "header", typ: "bool", default: "true", kind: kBool)], returns: "DataTable", call: c199_readCsv)
  controls.mgetOrPut("csvField", Control(name: "csvField", module: "charts", doc: "s as one CSV field: in quotes (its \" doubled) when it has sep, a quote, a line break or spaces at either end; as it is otherwise.")).overloads.add Overload(params: @[Param(name: "s", typ: "string", default: "", kind: kStr), Param(name: "sep", typ: "", default: "','", kind: kNone)], returns: "string", call: c200_csvField)
  controls.mgetOrPut("csvLine", Control(name: "csvLine", module: "charts", doc: "One CSV line (no line break at its end) of cells, each quoted as csvField says.")).overloads.add Overload(params: @[Param(name: "cells", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "sep", typ: "", default: "','", kind: kNone)], returns: "string", call: c201_csvLine)
  controls.mgetOrPut("toCsv", Control(name: "toCsv", module: "charts", doc: "The table as CSV text: the headers first (header false: without them), then each row; CRLF line ends, which every spreadsheet reads. parseCsv reads it back to the same table.")).overloads.add Overload(params: @[Param(name: "t", typ: "DataTable", default: "", kind: kNone), Param(name: "sep", typ: "", default: "','", kind: kNone), Param(name: "header", typ: "bool", default: "true", kind: kBool)], returns: "string", call: nil)
  controls.mgetOrPut("writeCsv", Control(name: "writeCsv", module: "charts", doc: "Saves the table to the CSV file path (see toCsv); false when it cannot be written (it never raises).")).overloads.add Overload(params: @[Param(name: "path", typ: "string", default: "", kind: kStr), Param(name: "t", typ: "DataTable", default: "", kind: kNone), Param(name: "sep", typ: "", default: "','", kind: kNone), Param(name: "header", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: nil)
  controls.mgetOrPut("exportPng", Control(name: "exportPng", module: "charts", doc: "Saves the part r of the window -- a chart: ui.lastRect right after it -- as the PNG file path, as it is drawn on the next frame (without tooltips); exportResult tells when it is written.")).overloads.add Overload(params: @[Param(name: "r", typ: "Rect", default: "", kind: kRect), Param(name: "path", typ: "string", default: "", kind: kStr)], returns: "", call: c204_exportPng)
  controls.mgetOrPut("chart", Control(name: "chart", module: "charts", doc: "A chart of series over labels, with everything a reader expects: round axis numbers, a legend (click an entry to hide that series), a tooltip (the mouse, a tap, or Left / Right once the chart has the focus), click events. height in pixels (0: a good height for the screen, -1: the room left); opts for the rest (its title is title).")).overloads.add Overload(params: @[Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "kind", typ: "ChartKind", default: "", kind: kEnum), Param(name: "labels", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "series", typ: "openArray[Series]", default: "", kind: kNone), Param(name: "height", typ: "int", default: "0", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "opts", typ: "", default: "ChartOpts()", kind: kNone)], returns: "ChartEvent", call: nil)
  controls.mgetOrPut("chart", Control(name: "chart", module: "charts", doc: "chart with every option in opts.")).overloads.add Overload(params: @[Param(name: "kind", typ: "ChartKind", default: "", kind: kEnum), Param(name: "labels", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "series", typ: "openArray[Series]", default: "", kind: kNone), Param(name: "opts", typ: "ChartOpts", default: "", kind: kNone), Param(name: "height", typ: "int", default: "0", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt)], returns: "ChartEvent", call: nil)
  controls.mgetOrPut("gauge", Control(name: "gauge", module: "charts", doc: "A dial showing value (with a target mark) from lo to hi.")).overloads.add Overload(params: @[Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "value", typ: "float", default: "", kind: kFloat), Param(name: "lo", typ: "float", default: "0.0", kind: kFloat), Param(name: "hi", typ: "", default: "NaN", kind: kNone), Param(name: "target", typ: "", default: "NaN", kind: kNone), Param(name: "format", typ: "", default: "NumFormat()", kind: kNone), Param(name: "height", typ: "int", default: "0", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt)], returns: "ChartEvent", call: c207_gauge)
  controls.mgetOrPut("tableSeries", Control(name: "tableSeries", module: "charts", doc: "The columns cols of a table as the series kind takes: one series per column for most kinds; x, y (and size) for scatter and bubbles; open, high, low, close for candlesticks; values and targets for bullets.")).overloads.add Overload(params: @[Param(name: "t", typ: "DataTable", default: "", kind: kNone), Param(name: "kind", typ: "ChartKind", default: "", kind: kEnum), Param(name: "cols", typ: "openArray[int]", default: "", kind: kInts)], returns: "seq[Series]", call: nil)
  controls.mgetOrPut("chart", Control(name: "chart", module: "charts", doc: "A chart of a table's columns: the labels from labelCol, the values from valueCols (see tableSeries): chart(\"Sales\", chBar, readCsv(\"sales.csv\"), \"Month\", [\"2025\", \"2026\"]).")).overloads.add Overload(params: @[Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "kind", typ: "ChartKind", default: "", kind: kEnum), Param(name: "t", typ: "DataTable", default: "", kind: kNone), Param(name: "labelCol", typ: "string", default: "", kind: kStr), Param(name: "valueCols", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "height", typ: "int", default: "0", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "opts", typ: "", default: "ChartOpts()", kind: kNone)], returns: "ChartEvent", call: nil)
  controls.mgetOrPut("barChart", Control(name: "barChart", module: "charts", doc: "Vertical bars, one per value, with a labeled axis (see chart for more).")).overloads.add Overload(params: @[Param(name: "values", typ: "openArray[float]", default: "", kind: kFloats), Param(name: "labels", typ: "openArray[string]", default: "[]", kind: kStrs), Param(name: "title", typ: "string", default: "\"\"", kind: kStr), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "h", typ: "int", default: "170", kind: kInt), Param(name: "colors", typ: "openArray[Color]", default: "[]", kind: kNone)], returns: "", call: c210_barChart)
  controls.mgetOrPut("lineChart", Control(name: "lineChart", module: "charts", doc: "One line per series over the same x points (see chart for more).")).overloads.add Overload(params: @[Param(name: "series", typ: "openArray[seq[float]]", default: "", kind: kNone), Param(name: "labels", typ: "openArray[string]", default: "[]", kind: kStrs), Param(name: "names", typ: "openArray[string]", default: "[]", kind: kStrs), Param(name: "title", typ: "string", default: "\"\"", kind: kStr), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "h", typ: "int", default: "170", kind: kInt)], returns: "", call: nil)
  controls.mgetOrPut("pieChart", Control(name: "pieChart", module: "charts", doc: "Slices of a circle, with a legend of shares (see chart for more).")).overloads.add Overload(params: @[Param(name: "values", typ: "openArray[float]", default: "", kind: kFloats), Param(name: "labels", typ: "openArray[string]", default: "[]", kind: kStrs), Param(name: "title", typ: "string", default: "\"\"", kind: kStr), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "h", typ: "int", default: "170", kind: kInt)], returns: "", call: c212_pieChart)
  controls.mgetOrPut("kanbanBoard", Control(name: "kanbanBoard", module: "planning", doc: "A board of lanes side by side, each a list of cards, for work that moves through stages (To do, Doing, Done). Drag a card to another place or lane (a finger: hold it, then move); Ctrl + the arrows move the chosen card too. The arrows choose, Enter or a double click opens (opened), \"+ Add card\" (or Insert) asks for a new card (added). Lanes over their limit show their count in red. Lanes scroll on ")).overloads.add Overload(params: @[Param(name: "lanes", typ: "var seq[KanbanLane]", default: "", kind: kNone), Param(name: "sel", typ: "var KanbanPos", default: "", kind: kNone), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "KanbanEvent", call: nil)
  controls.mgetOrPut("ganttView", Control(name: "ganttView", module: "planning", doc: "Tasks on a time line: their names at the left (deeper ones indented under the task they are part of, which shows as a summary bar and folds with its [-] box), their bars at the right with how much is done, the deps as arrows, milestones as diamonds, today as a red line, the weekend days (0 Sunday .. 6 Saturday) shaded. Drag a bar to move it, its ends to change its dates (whole days; a finger: hold")).overloads.add Overload(params: @[Param(name: "tasks", typ: "var seq[GanttTask]", default: "", kind: kNone), Param(name: "sel", typ: "var int", default: "", kind: kVInt), Param(name: "scale", typ: "var GanttScale", default: "", kind: kNone), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "listW", typ: "int", default: "0", kind: kInt), Param(name: "weekend", typ: "openArray[int]", default: "[0, 6]", kind: kInts), Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "GanttEvent", call: nil)
  controls.mgetOrPut("agendaView", Control(name: "agendaView", module: "planning", doc: "Appointments by month (a grid of weeks with the entries of each day, \"+3 more\" when they do not fit), by week (seven days of hours, the all-day ones on top) or by day; day is the day in focus. Previous, Next and Today (also Page Up, Page Down, Home) move through time, the arrows move the day. A click on an entry opens it (opened), on an empty day or time asks for a new one (added); drag an entry t")).overloads.add Overload(params: @[Param(name: "items", typ: "var seq[Appointment]", default: "", kind: kNone), Param(name: "day", typ: "var Date", default: "", kind: kNone), Param(name: "mode", typ: "var AgendaMode", default: "", kind: kNone), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "AgendaEvent", call: nil)
  controls.mgetOrPut("kpiTile", Control(name: "kpiTile", module: "planning", doc: "A number of a dashboard: what it is, the value (big), how it moved (delta a fraction: 0.125 shows \"▲ 12.5 %\", green when that is good, red when it is not -- costs and complaints are better lower: lowerIsBetter), with a deltaNote (\"vs last month\"), the trend drawn small and how much of a target is reached (0..1). w: its width (0: the room there is; see kpiRow). True when clicked (or Enter), to show")).overloads.add Overload(params: @[Param(name: "label", typ: "string", default: "", kind: kStr), Param(name: "value", typ: "string", default: "", kind: kStr), Param(name: "delta", typ: "", default: "NaN", kind: kNone), Param(name: "deltaNote", typ: "string", default: "\"\"", kind: kStr), Param(name: "lowerIsBetter", typ: "bool", default: "false", kind: kBool), Param(name: "trend", typ: "openArray[float]", default: "[]", kind: kFloats), Param(name: "target", typ: "", default: "NaN", kind: kNone), Param(name: "color", typ: "Color", default: "Color()", kind: kColor), Param(name: "w", typ: "int", default: "0", kind: kInt)], returns: "bool", call: c216_kpiTile)
  controls.mgetOrPut("statCard", Control(name: "statCard", module: "planning", doc: "A tile with an icon (a pixel icon or an icon-font glyph) beside a label, a value and a line of detail (\"12 new today\"). True when clicked.")).overloads.add Overload(params: @[Param(name: "glyph", typ: "string", default: "", kind: kStr), Param(name: "label", typ: "string", default: "", kind: kStr), Param(name: "value", typ: "string", default: "", kind: kStr), Param(name: "detail", typ: "string", default: "\"\"", kind: kStr), Param(name: "color", typ: "Color", default: "Color()", kind: kColor), Param(name: "w", typ: "int", default: "0", kind: kInt)], returns: "bool", call: c217_statCard)
  controls.mgetOrPut("orgChart", Control(name: "orgChart", module: "planning", doc: "Who reports to whom: each node a box (name, title) under the one in its parent, joined by lines; a box with ones under it folds with the [-] box at its foot. Click to choose, double-click (or Enter) to open; Up goes to the one above, Down to the first under, Left and Right to the ones beside; Space folds. Bigger than its room, it scrolls (the bars, the wheel -- Shift for sideways --, a finger). he")).overloads.add Overload(params: @[Param(name: "nodes", typ: "var seq[OrgNode]", default: "", kind: kNone), Param(name: "sel", typ: "var int", default: "", kind: kVInt), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "OrgEvent", call: nil)
  controls.mgetOrPut("countryName", Control(name: "countryName", module: "mapview", doc: "The name of the country with this code (or other name); \"\" if none.")).overloads.add Overload(params: @[Param(name: "code", typ: "string", default: "", kind: kStr)], returns: "string", call: c219_countryName)
  controls.mgetOrPut("countryCode", Control(name: "countryCode", module: "mapview", doc: "The ISO code of the country called name (alpha-3, or alpha-2).")).overloads.add Overload(params: @[Param(name: "name", typ: "string", default: "", kind: kStr), Param(name: "alpha3", typ: "bool", default: "true", kind: kBool)], returns: "string", call: c220_countryCode)
  controls.mgetOrPut("latLonOf", Control(name: "latLonOf", module: "mapview", doc: "A point well inside the country (for its label or a marker); (0, 0) when there is no such country.")).overloads.add Overload(params: @[Param(name: "code", typ: "string", default: "", kind: kStr)], returns: "tuple[lat, lon: float]", call: c221_latLonOf)
  controls.mgetOrPut("cityMarker", Control(name: "cityMarker", module: "mapview", doc: "A marker at one of the cities the map knows (else at a country of that name or code), labeled with its name unless label is given.")).overloads.add Overload(params: @[Param(name: "name", typ: "string", default: "", kind: kStr), Param(name: "label", typ: "string", default: "\"\\x00\"", kind: kStr), Param(name: "size", typ: "float", default: "0.0", kind: kFloat), Param(name: "color", typ: "Color", default: "Color()", kind: kColor), Param(name: "info", typ: "string", default: "\"\"", kind: kStr)], returns: "MapMarker", call: c222_cityMarker)
  controls.mgetOrPut("resetView", Control(name: "resetView", module: "mapview", doc: "The whole world.")).overloads.add Overload(params: @[Param(name: "m", typ: "var MapState", default: "", kind: kNone)], returns: "", call: nil)
  controls.mgetOrPut("zoomTo", Control(name: "zoomTo", module: "mapview", doc: "Centers the view on a place at a zoom (1: the whole world).")).overloads.add Overload(params: @[Param(name: "m", typ: "var MapState", default: "", kind: kNone), Param(name: "lat", typ: "float", default: "", kind: kFloat), Param(name: "lon", typ: "float", default: "", kind: kFloat), Param(name: "zoom", typ: "float", default: "", kind: kFloat)], returns: "", call: nil)
  controls.mgetOrPut("fitTo", Control(name: "fitTo", module: "mapview", doc: "Zooms the view onto these countries (codes or names). Before the map was first drawn, it happens when it is.")).overloads.add Overload(params: @[Param(name: "m", typ: "var MapState", default: "", kind: kNone), Param(name: "codes", typ: "openArray[string]", default: "", kind: kStrs)], returns: "", call: nil)
  controls.mgetOrPut("mapView", Control(name: "mapView", module: "mapview", doc: "The world map, height pixels high (-1: the room left), as wide as the space it is in. values color the countries (ISO alpha-2 or alpha-3 codes, or names) from lowColor to highColor, with a legend; markers and routes are drawn over it. Drag to move it, the wheel, a double click, + / - (with the focus) or its buttons zoom; arrows move it and Home shows the whole world. The country and marker under t")).overloads.add Overload(params: @[Param(name: "m", typ: "var MapState", default: "", kind: kNone), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "values", typ: "openArray[(string, float)]", default: "[]", kind: kNone), Param(name: "markers", typ: "openArray[MapMarker]", default: "[]", kind: kNone), Param(name: "routes", typ: "openArray[MapRoute]", default: "[]", kind: kNone), Param(name: "legend", typ: "bool", default: "true", kind: kBool), Param(name: "legendTitle", typ: "string", default: "\"\"", kind: kStr), Param(name: "countryLabels", typ: "bool", default: "true", kind: kBool), Param(name: "markerLabels", typ: "bool", default: "true", kind: kBool), Param(name: "valueText", typ: "proc (v: float): string", default: "nil", kind: kNone), Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "MapEvent", call: nil)
  controls.mgetOrPut("`*`", Control(name: "`*`", module: "view3d", doc: "b, then a.")).overloads.add Overload(params: @[Param(name: "a", typ: "Quat", default: "", kind: kNone), Param(name: "b", typ: "Quat", default: "", kind: kNone)], returns: "Quat", call: nil)
  controls.mgetOrPut("`*`", Control(name: "`*`", module: "view3d", doc: "b, then a.")).overloads.add Overload(params: @[Param(name: "a", typ: "Mat4", default: "", kind: kNone), Param(name: "b", typ: "Mat4", default: "", kind: kNone)], returns: "Mat4", call: nil)
  controls.mgetOrPut("box", Control(name: "box", module: "view3d", doc: "A box w wide (x), h high (y) and d deep (z), centered.")).overloads.add Overload(params: @[Param(name: "w", typ: "float", default: "", kind: kFloat), Param(name: "h", typ: "float", default: "", kind: kFloat), Param(name: "d", typ: "float", default: "", kind: kFloat), Param(name: "color", typ: "Color", default: "color(0, 0, 160)", kind: kColor), Param(name: "name", typ: "string", default: "\"box\"", kind: kStr)], returns: "Mesh3", call: c229_box)
  controls.mgetOrPut("sphere", Control(name: "sphere", module: "view3d", doc: "A sphere, shaded smoothly.")).overloads.add Overload(params: @[Param(name: "radius", typ: "float", default: "", kind: kFloat), Param(name: "color", typ: "Color", default: "color(0, 0, 160)", kind: kColor), Param(name: "segments", typ: "int", default: "24", kind: kInt), Param(name: "rings", typ: "int", default: "16", kind: kInt), Param(name: "name", typ: "string", default: "\"sphere\"", kind: kStr)], returns: "Mesh3", call: c230_sphere)
  controls.mgetOrPut("cylinder", Control(name: "cylinder", module: "view3d", doc: "A cylinder standing on the y axis, centered.")).overloads.add Overload(params: @[Param(name: "radius", typ: "float", default: "", kind: kFloat), Param(name: "height", typ: "float", default: "", kind: kFloat), Param(name: "color", typ: "Color", default: "color(0, 0, 160)", kind: kColor), Param(name: "segments", typ: "int", default: "24", kind: kInt), Param(name: "name", typ: "string", default: "\"cylinder\"", kind: kStr)], returns: "Mesh3", call: c231_cylinder)
  controls.mgetOrPut("cone", Control(name: "cone", module: "view3d", doc: "A cone pointing up the y axis, centered.")).overloads.add Overload(params: @[Param(name: "radius", typ: "float", default: "", kind: kFloat), Param(name: "height", typ: "float", default: "", kind: kFloat), Param(name: "color", typ: "Color", default: "color(0, 0, 160)", kind: kColor), Param(name: "segments", typ: "int", default: "24", kind: kInt), Param(name: "name", typ: "string", default: "\"cone\"", kind: kStr)], returns: "Mesh3", call: c232_cone)
  controls.mgetOrPut("plane", Control(name: "plane", module: "view3d", doc: "A flat rectangle in the x-z plane (seen from both sides).")).overloads.add Overload(params: @[Param(name: "w", typ: "float", default: "", kind: kFloat), Param(name: "d", typ: "float", default: "", kind: kFloat), Param(name: "color", typ: "Color", default: "color(192, 192, 192)", kind: kColor), Param(name: "name", typ: "string", default: "\"plane\"", kind: kStr)], returns: "Mesh3", call: c233_plane)
  controls.mgetOrPut("addGrid", Control(name: "addGrid", module: "view3d", doc: "A square grid of lines in the x-z plane, size across.")).overloads.add Overload(params: @[Param(name: "scene", typ: "var Scene3", default: "", kind: kNone), Param(name: "size", typ: "float", default: "10.0", kind: kFloat), Param(name: "divisions", typ: "int", default: "10", kind: kInt), Param(name: "y", typ: "float", default: "0.0", kind: kFloat), Param(name: "color", typ: "Color", default: "color(160, 160, 160)", kind: kColor)], returns: "", call: nil)
  controls.mgetOrPut("addAxes", Control(name: "addAxes", module: "view3d", doc: "The x (red), y (green) and z (blue) axes from the origin.")).overloads.add Overload(params: @[Param(name: "scene", typ: "var Scene3", default: "", kind: kNone), Param(name: "length", typ: "float", default: "1.0", kind: kFloat)], returns: "", call: nil)
  controls.mgetOrPut("newNode", Control(name: "newNode", module: "view3d", doc: "A part with nothing in it yet, in its place (add it with addNode).")).overloads.add Overload(params: @[Param(name: "name", typ: "string", default: "\"\"", kind: kStr), Param(name: "parent", typ: "int", default: "-1", kind: kInt)], returns: "Node3", call: c236_newNode)
  controls.mgetOrPut("addNode", Control(name: "addNode", module: "view3d", doc: "Puts n in the scene (under its parent); its index.")).overloads.add Overload(params: @[Param(name: "scene", typ: "var Scene3", default: "", kind: kNone), Param(name: "n", typ: "Node3", default: "", kind: kNone)], returns: "int", call: nil)
  controls.mgetOrPut("findNode", Control(name: "findNode", module: "view3d", doc: "The node called name (-1: none); the first of that name.")).overloads.add Overload(params: @[Param(name: "scene", typ: "Scene3", default: "", kind: kNone), Param(name: "name", typ: "string", default: "", kind: kStr)], returns: "int", call: nil)
  controls.mgetOrPut("nodeNames", Control(name: "nodeNames", module: "view3d", doc: "The names of the model's parts (to find what to move: \"Wheel_FL\"...).")).overloads.add Overload(params: @[Param(name: "scene", typ: "Scene3", default: "", kind: kNone)], returns: "seq[string]", call: nil)
  controls.mgetOrPut("setVisible", Control(name: "setVisible", module: "view3d", doc: "Shows or hides a part (with what is in it: a door, the hood, a wheel).")).overloads.add Overload(params: @[Param(name: "scene", typ: "var Scene3", default: "", kind: kNone), Param(name: "node", typ: "string", default: "", kind: kStr), Param(name: "visible", typ: "bool", default: "", kind: kBool)], returns: "", call: nil)
  controls.mgetOrPut("tint", Control(name: "tint", module: "view3d", doc: "A part (and what is in it) in color c (alpha 0: its own colors again) -- the body of the car in the customer's choice.")).overloads.add Overload(params: @[Param(name: "scene", typ: "var Scene3", default: "", kind: kNone), Param(name: "node", typ: "string", default: "", kind: kStr), Param(name: "c", typ: "Color", default: "", kind: kColor)], returns: "", call: nil)
  controls.mgetOrPut("turnNode", Control(name: "turnNode", module: "view3d", doc: "Turns a part about axis (in its parent's directions) by degrees more (a wheel rolling, a door opening).")).overloads.add Overload(params: @[Param(name: "scene", typ: "var Scene3", default: "", kind: kNone), Param(name: "node", typ: "string", default: "", kind: kStr), Param(name: "axis", typ: "Vec3", default: "", kind: kNone), Param(name: "degrees", typ: "float", default: "", kind: kFloat)], returns: "", call: nil)
  controls.mgetOrPut("moveNode", Control(name: "moveNode", module: "view3d", doc: "Moves a part by by (in its parent's directions).")).overloads.add Overload(params: @[Param(name: "scene", typ: "var Scene3", default: "", kind: kNone), Param(name: "node", typ: "string", default: "", kind: kStr), Param(name: "by", typ: "Vec3", default: "", kind: kNone)], returns: "", call: nil)
  controls.mgetOrPut("recolor", Control(name: "recolor", module: "view3d", doc: "A material's color (by its name: \"CarPaint\") changed for every part that has it.")).overloads.add Overload(params: @[Param(name: "scene", typ: "var Scene3", default: "", kind: kNone), Param(name: "material", typ: "string", default: "", kind: kStr), Param(name: "c", typ: "Color", default: "", kind: kColor)], returns: "", call: nil)
  controls.mgetOrPut("animationNames", Control(name: "animationNames", module: "view3d", doc: "The model's clips (\"DoorOpen\", \"WheelsTurn\"...).")).overloads.add Overload(params: @[Param(name: "scene", typ: "Scene3", default: "", kind: kNone)], returns: "seq[string]", call: nil)
  controls.mgetOrPut("seekAnimation", Control(name: "seekAnimation", module: "view3d", doc: "The model as clip name has it at seconds (a slider scrubbing it).")).overloads.add Overload(params: @[Param(name: "scene", typ: "var Scene3", default: "", kind: kNone), Param(name: "name", typ: "string", default: "", kind: kStr), Param(name: "seconds", typ: "float", default: "", kind: kFloat)], returns: "", call: nil)
  controls.mgetOrPut("play", Control(name: "play", module: "view3d", doc: "Plays clip name (\"\" the first) from its start, over and over with loop; animate moves it on each frame.")).overloads.add Overload(params: @[Param(name: "scene", typ: "var Scene3", default: "", kind: kNone), Param(name: "name", typ: "string", default: "\"\"", kind: kStr), Param(name: "loop", typ: "bool", default: "true", kind: kBool), Param(name: "speed", typ: "float", default: "1.0", kind: kFloat)], returns: "", call: nil)
  controls.mgetOrPut("stop", Control(name: "stop", module: "view3d", doc: "Stops clip name (every clip: \"\") where it is.")).overloads.add Overload(params: @[Param(name: "scene", typ: "var Scene3", default: "", kind: kNone), Param(name: "name", typ: "string", default: "\"\"", kind: kStr)], returns: "", call: nil)
  controls.mgetOrPut("isPlaying", Control(name: "isPlaying", module: "view3d", doc: "Clip name (any: \"\") is playing.")).overloads.add Overload(params: @[Param(name: "scene", typ: "Scene3", default: "", kind: kNone), Param(name: "name", typ: "string", default: "\"\"", kind: kStr)], returns: "bool", call: nil)
  controls.mgetOrPut("animate", Control(name: "animate", module: "view3d", doc: "Moves the clips playing on by seconds (the time since the last frame); true while one plays (keep the frames coming: wakeIn).")).overloads.add Overload(params: @[Param(name: "scene", typ: "var Scene3", default: "", kind: kNone), Param(name: "seconds", typ: "float", default: "", kind: kFloat)], returns: "bool", call: nil)
  controls.mgetOrPut("loadModel", Control(name: "loadModel", module: "view3d", doc: "An OBJ or STL file (by its extension), centered at the origin and scaled to 2 units across. Raises ValueError or IOError.")).overloads.add Overload(params: @[Param(name: "path", typ: "string", default: "", kind: kStr)], returns: "Mesh3", call: c251_loadModel)
  controls.mgetOrPut("bars3d", Control(name: "bars3d", module: "view3d", doc: "A 3D bar chart: values[row][col] stand as bars on a floor, a row of bars per series (front to back), one color per row (colors, else the kit's), labels along the sides and, with showValues, on the bars. Negative values go down. Pair it with fitView.")).overloads.add Overload(params: @[Param(name: "values", typ: "openArray[seq[float]]", default: "", kind: kNone), Param(name: "rowLabels", typ: "openArray[string]", default: "[]", kind: kStrs), Param(name: "colLabels", typ: "openArray[string]", default: "[]", kind: kStrs), Param(name: "colors", typ: "openArray[Color]", default: "[]", kind: kNone), Param(name: "showValues", typ: "bool", default: "false", kind: kBool)], returns: "Scene3", call: nil)
  controls.mgetOrPut("camera3", Control(name: "camera3", module: "view3d", doc: "A camera looking at target (see Camera3); resetView comes back to it.")).overloads.add Overload(params: @[Param(name: "yaw", typ: "float", default: "35.0", kind: kFloat), Param(name: "pitch", typ: "float", default: "25.0", kind: kFloat), Param(name: "distance", typ: "float", default: "6.0", kind: kFloat), Param(name: "target", typ: "", default: "vec3(0, 0, 0)", kind: kNone), Param(name: "fov", typ: "float", default: "40.0", kind: kFloat)], returns: "Camera3", call: c253_camera3)
  controls.mgetOrPut("resetView", Control(name: "resetView", module: "view3d", doc: "Back to where camera3 or fitView put it.")).overloads.add Overload(params: @[Param(name: "cam", typ: "var Camera3", default: "", kind: kNone)], returns: "", call: nil)
  controls.mgetOrPut("fitView", Control(name: "fitView", module: "view3d", doc: "Aims the camera at the middle of the scene, far enough to see all of it; Home (and the home button) come back to this view.")).overloads.add Overload(params: @[Param(name: "scene", typ: "Scene3", default: "", kind: kNone), Param(name: "cam", typ: "var Camera3", default: "", kind: kNone)], returns: "", call: nil)
  controls.mgetOrPut("render3d", Control(name: "render3d", module: "view3d", doc: "The scene seen by cam, w x h pixels (to save with encodePng), on background (else the scene's). Labels are not in it.")).overloads.add Overload(params: @[Param(name: "scene", typ: "Scene3", default: "", kind: kNone), Param(name: "cam", typ: "Camera3", default: "", kind: kNone), Param(name: "w", typ: "int", default: "", kind: kInt), Param(name: "h", typ: "int", default: "", kind: kInt), Param(name: "background", typ: "Color", default: "Color()", kind: kColor)], returns: "Bitmap", call: nil)
  controls.mgetOrPut("view3dOnGpu", Control(name: "view3dOnGpu", module: "view3d", doc: "The 3D view key's last picture was drawn by the GPU.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "bool", call: c257_view3dOnGpu)
  controls.mgetOrPut("view3dPicture", Control(name: "view3dPicture", module: "view3d", doc: "The last picture the 3D view key showed (device pixels), drawn by the CPU or by the GPU (read back from it): a screenshot of the model. Nil before it was shown. Call it in a frame (after the view).")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "Bitmap", call: c258_view3dPicture)
  controls.mgetOrPut("view3d", Control(name: "view3d", module: "view3d", doc: "The scene seen by cam, height pixels high (-1: the room left). Drag to turn it, Shift or Ctrl + drag (or a finger held a moment, then moved) to move it, the wheel to zoom; with the focus: arrows turn,/ - zoom, Home goes back to the first view. controls: zoom and home buttons in the corner (handy for fingers). A click reports the mesh under it (picked), the mouse resting over one hovered.")).overloads.add Overload(params: @[Param(name: "scene", typ: "var Scene3", default: "", kind: kNone), Param(name: "cam", typ: "var Camera3", default: "", kind: kNone), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "key", typ: "string", default: "\"\"", kind: kStr), Param(name: "controls", typ: "bool", default: "true", kind: kBool)], returns: "View3DEvent", call: nil)
  controls.mgetOrPut("htmlToMarkdown", Control(name: "htmlToMarkdown", module: "htmlview", doc: "html as Markdown the kit draws (inline styles kept as the few HTML tags markdown understands). Scripts, styles, frames and forms are left out.")).overloads.add Overload(params: @[Param(name: "html", typ: "string", default: "", kind: kStr)], returns: "string", call: c260_htmlToMarkdown)
  controls.mgetOrPut("htmlView", Control(name: "htmlView", module: "htmlview", doc: "HTML in a framed view that scrolls (wheel, finger, scroll bar, arrows, Page keys, Space, Home, End). Returns the link clicked (links to \"#a-name\" scroll there themselves) and the one under the pointer. Text is selected with the mouse (a double click: a word), Ctrl+C copies it (or all of it), Ctrl+A selects all. Pictures: data: ones from the page, others from images or files in baseDir; those it ha")).overloads.add Overload(params: @[Param(name: "html", typ: "string", default: "", kind: kStr), Param(name: "baseDir", typ: "string", default: "\"\"", kind: kStr), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "key", typ: "string", default: "\"\"", kind: kStr), Param(name: "images", typ: "HtmlImageSource", default: "nil", kind: kNone), Param(name: "padding", typ: "int", default: "-1", kind: kInt), Param(name: "zoom", typ: "ptr float", default: "nil", kind: kNone)], returns: "HtmlEvent", call: c261_htmlView)
  controls.mgetOrPut("htmlView", Control(name: "htmlView", module: "htmlview", doc: "htmlView that zooms, its zoom in zoom (the app's to keep): htmlView(body, settings.mailZoom, key = \"mail\").")).overloads.add Overload(params: @[Param(name: "html", typ: "string", default: "", kind: kStr), Param(name: "zoom", typ: "var float", default: "", kind: kVFloat), Param(name: "baseDir", typ: "string", default: "\"\"", kind: kStr), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "key", typ: "string", default: "\"\"", kind: kStr), Param(name: "images", typ: "HtmlImageSource", default: "nil", kind: kNone), Param(name: "padding", typ: "int", default: "-1", kind: kInt)], returns: "HtmlEvent", call: c262_htmlView)
  controls.mgetOrPut("htmlBlock", Control(name: "htmlBlock", module: "htmlview", doc: "HTML flowing in the layout at its natural height (in a page that scrolls, a card, a dialog). Pictures as in htmlView; zoom as there (1.0 normal, 0.5 .. 3.0), set by the app.")).overloads.add Overload(params: @[Param(name: "html", typ: "string", default: "", kind: kStr), Param(name: "baseDir", typ: "string", default: "\"\"", kind: kStr), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "images", typ: "HtmlImageSource", default: "nil", kind: kNone), Param(name: "zoom", typ: "float", default: "1.0", kind: kFloat)], returns: "HtmlEvent", call: c263_htmlBlock)
  controls.mgetOrPut("webPermit", Control(name: "webPermit", module: "htmlview", doc: "What the page of the webView with key may use when it asks: the camera, the microphone, the location, notifications (none by default). What it asks for and is not allowed comes in WebEvent.asked; the app may allow it then and reload the page. The system's engine (the app needs the system's permission too: an Android app --permission:CAMERA...).")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "allowed", typ: "set[WebPermission]", default: "", kind: kSet)], returns: "", call: c264_webPermit)
  controls.mgetOrPut("webPrint", Control(name: "webPrint", module: "htmlview", doc: "Prints the page of the webView with key: the system's print dialog (the system's engine; the kit's own prints nothing here -- retroui/report prints documents).")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr)], returns: "", call: c265_webPrint)
  controls.mgetOrPut("webAppFolder", Control(name: "webAppFolder", module: "htmlview", doc: "The folder of the app's own web pages (its scripts, styles, pictures), served to pages at webAppUrl: an address of their own, so they may fetch each other as a site's files do (a file:// page may not).")).overloads.add Overload(params: @[Param(name: "folder", typ: "string", default: "", kind: kStr)], returns: "", call: c266_webAppFolder)
  controls.mgetOrPut("webAppUrl", Control(name: "webAppUrl", module: "htmlview", doc: "The address of the file path of the app's folder (webAppFolder): \"app://local/PATH\" (on Windows \"https://app.local/PATH\").webAppFolder(getAppDir() / \"web\") webView(webAppUrl(\"index.html\"), key = \"ui\", engine = weSystem)")).overloads.add Overload(params: @[Param(name: "path", typ: "string", default: "\"index.html\"", kind: kStr)], returns: "string", call: c267_webAppUrl)
  controls.mgetOrPut("webView", Control(name: "webView", module: "htmlview", doc: "A web page in the window, height pixels high (-1: the room left). url is \"https://...\", a \"file://\" address or a path, or \"html:\" and the HTML itself; giving another address shows that page. engine chooses who shows it (webEngine, $RETRO_WEB: the kit's own on desktops, the system's in an Android app). The system's engine (weSystem; the default in an Android app) is the browser the system has -- An")).overloads.add Overload(params: @[Param(name: "url", typ: "string", default: "", kind: kStr), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "key", typ: "string", default: "\"\"", kind: kStr), Param(name: "engine", typ: "", default: "webEngine", kind: kNone)], returns: "WebEvent", call: c268_webView)
  controls.mgetOrPut("mdPlainText", Control(name: "mdPlainText", module: "markdown", doc: "Markdown as it is read out: the words, without its marks (#, **, backticks, a link's address).")).overloads.add Overload(params: @[Param(name: "md", typ: "string", default: "", kind: kStr)], returns: "string", call: c269_mdPlainText)
  controls.mgetOrPut("markdown", Control(name: "markdown", module: "markdown", doc: "Markdown flowing in the layout at its natural height (in a page that scrolls, a card, a dialog). See markdownView for a framed, scrolling view.")).overloads.add Overload(params: @[Param(name: "md", typ: "string", default: "", kind: kStr), Param(name: "baseDir", typ: "string", default: "\"\"", kind: kStr), Param(name: "w", typ: "int", default: "0", kind: kInt)], returns: "MdEvent", call: c270_markdown)
  controls.mgetOrPut("markdownView", Control(name: "markdownView", module: "markdown", doc: "Markdown in a framed view that scrolls (wheel, finger, scroll bar, arrows and Page keys). Returns the link or task box clicked; links to \"#a-heading\" scroll there themselves. Pictures load from baseDir. key tells views apart (each keeps where it is scrolled to). Arabic (Hebrew...) reads right to left: a paragraph, a list item or a quote whose first words are Arabic has its bullet, number or bar at")).overloads.add Overload(params: @[Param(name: "md", typ: "string", default: "", kind: kStr), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "baseDir", typ: "string", default: "\"\"", kind: kStr), Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "MdEvent", call: c271_markdownView)
  controls.mgetOrPut("`&lt;`", Control(name: "`&lt;`", module: "richedit", doc: "a comes before b.")).overloads.add Overload(params: @[Param(name: "a", typ: "RichPos", default: "", kind: kNone), Param(name: "b", typ: "RichPos", default: "", kind: kNone)], returns: "bool", call: nil)
  controls.mgetOrPut("`&lt;=`", Control(name: "`&lt;=`", module: "richedit", doc: "a comes before b or is b.")).overloads.add Overload(params: @[Param(name: "a", typ: "RichPos", default: "", kind: kNone), Param(name: "b", typ: "RichPos", default: "", kind: kNone)], returns: "bool", call: nil)
  controls.mgetOrPut("richEdit", Control(name: "richEdit", module: "richedit", doc: "The rich text editor, height pixels high (-1: the height left in the window), bound to d: true when its text (or its formatting) changed this frame. placeholder shows while it is empty; key tells editors of the same document apart. Its menu (a right click, a long press): Undo, Cut, Copy, Paste, Link, Select all. In a right-to-left interface each paragraph keeps its own direction (Arabic at the rig")).overloads.add Overload(params: @[Param(name: "d", typ: "var RichDoc", default: "", kind: kNone), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "key", typ: "string", default: "\"\"", kind: kStr), Param(name: "placeholder", typ: "string", default: "\"\"", kind: kStr), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: nil)
  controls.mgetOrPut("richToolbar", Control(name: "richToolbar", module: "richedit", doc: "A row of formatting buttons for d's editor: bold, italic, underline, strikethrough, monospace, the text color and size, bullets, numbers, a quote, indents, alignment, a link (asked for in a small dialog) and plain text again; pressed for what the caret has. compact (phones): the most used ones, the rest in a \"more\" menu.")).overloads.add Overload(params: @[Param(name: "d", typ: "var RichDoc", default: "", kind: kNone), Param(name: "compact", typ: "bool", default: "false", kind: kBool)], returns: "", call: nil)
  controls.mgetOrPut("richFromHtml", Control(name: "richFromHtml", module: "richedit", doc: "A document from a mail's HTML: paragraphs (p, div, br), bold, italic, underline, strike, font and span styles (color, size, weight, family), links, lists (nested), quotes, headings, preformatted text; anything else gives its text, scripts and styles nothing. Never raises.")).overloads.add Overload(params: @[Param(name: "html", typ: "string", default: "", kind: kStr)], returns: "RichDoc", call: c276_richFromHtml)
  controls.mgetOrPut("`==`", Control(name: "`==`", module: "media", doc: "The same sound.")).overloads.add Overload(params: @[Param(name: "a", typ: "SoundId", default: "", kind: kNone), Param(name: "b", typ: "SoundId", default: "", kind: kNone)], returns: "bool", call: nil)
  controls.mgetOrPut("`$`", Control(name: "`$`", module: "media", doc: "The sound's number as text.")).overloads.add Overload(params: @[Param(name: "a", typ: "SoundId", default: "", kind: kNone)], returns: "string", call: nil)
  controls.mgetOrPut("playSound", Control(name: "playSound", module: "media", doc: "Plays s (made by decodeWav, makeTone...) over whatever else plays, at volume (1 as recorded), again and again with loop (until stopSound). NoSound when it cannot be played.")).overloads.add Overload(params: @[Param(name: "s", typ: "Sound", default: "", kind: kNone), Param(name: "volume", typ: "float", default: "1.0", kind: kFloat), Param(name: "loop", typ: "bool", default: "false", kind: kBool)], returns: "SoundId", call: nil)
  controls.mgetOrPut("playSound", Control(name: "playSound", module: "media", doc: "Plays the sound file path: WAV everywhere; MP3, OGG, AAC, FLAC and others where the system plays them (see the table above). NoSound when the file is missing or cannot be played here.")).overloads.add Overload(params: @[Param(name: "path", typ: "string", default: "", kind: kStr), Param(name: "volume", typ: "float", default: "1.0", kind: kFloat), Param(name: "loop", typ: "bool", default: "false", kind: kBool)], returns: "SoundId", call: c280_playSound)
  controls.mgetOrPut("tone", Control(name: "tone", module: "media", doc: "Plays a tone of hz hertz for ms milliseconds.")).overloads.add Overload(params: @[Param(name: "hz", typ: "float", default: "", kind: kFloat), Param(name: "ms", typ: "int", default: "", kind: kInt), Param(name: "volume", typ: "float", default: "0.5", kind: kFloat), Param(name: "wave", typ: "Waveform", default: "wSine", kind: kEnum)], returns: "SoundId", call: c281_tone)
  controls.mgetOrPut("uiSound", Control(name: "uiSound", module: "media", doc: "A short sound for the moments apps have them: a click, a new message, something done, a warning, an error. Made here, no files.")).overloads.add Overload(params: @[Param(name: "kind", typ: "UiSound", default: "", kind: kEnum), Param(name: "volume", typ: "float", default: "1.0", kind: kFloat)], returns: "", call: c282_uiSound)
  controls.mgetOrPut("animation", Control(name: "animation", module: "media", doc: "Plays the frames of loadGif round and round, each for its delay; the first frame's size (or height with its proportions kept, or w). It wakes the app only when the next frame is due. paused holds the frame shown. Returns where it is.")).overloads.add Overload(params: @[Param(name: "frames", typ: "openArray[GifFrame]", default: "", kind: kNone), Param(name: "height", typ: "int", default: "0", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "paused", typ: "bool", default: "false", kind: kBool), Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "Rect", call: nil)
  controls.mgetOrPut("videoView", Control(name: "videoView", module: "media", doc: "A video in the window, with play / pause, a position bar and the time under it (controls); Space plays and pauses, Left / Right go back and on 5 seconds, Home to the start, when it has the focus; a click on the picture plays and pauses. path is a file or a web address (http, https; HLS where the system plays it). The system's own player plays it and the kit draws its pictures in the window (under ")).overloads.add Overload(params: @[Param(name: "path", typ: "string", default: "", kind: kStr), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "autoplay", typ: "bool", default: "false", kind: kBool), Param(name: "controls", typ: "bool", default: "true", kind: kBool), Param(name: "key", typ: "string", default: "\"\"", kind: kStr), Param(name: "audio", typ: "bool", default: "false", kind: kBool)], returns: "VideoEvent", call: c284_videoView)
  controls.mgetOrPut("audioView", Control(name: "audioView", module: "media", doc: "A sound file to play: a panel with a note and its name, play / pause, a position bar and the time under it (MP3, OGG, FLAC, WAV... where the system plays them: Android; GStreamer on Linux; elsewhere it plays from the start with playSound, without the position). closeVideo stops it.")).overloads.add Overload(params: @[Param(name: "path", typ: "string", default: "", kind: kStr), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "autoplay", typ: "bool", default: "false", kind: kBool), Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "VideoEvent", call: c285_audioView)
  controls.mgetOrPut("`[]`", Control(name: "`[]`", module: "qrcode", doc: "The module in column x, row y is dark (outside the code: light).")).overloads.add Overload(params: @[Param(name: "q", typ: "QrCode", default: "", kind: kNone), Param(name: "x", typ: "int", default: "", kind: kInt), Param(name: "y", typ: "int", default: "", kind: kInt)], returns: "bool", call: nil)
  controls.mgetOrPut("qrBitmap", Control(name: "qrBitmap", module: "qrcode", doc: "The code as a picture: scale pixels a module, border modules of quiet zone (light) around it (4 is what the standard asks).")).overloads.add Overload(params: @[Param(name: "q", typ: "QrCode", default: "", kind: kNone), Param(name: "scale", typ: "int", default: "4", kind: kInt), Param(name: "border", typ: "int", default: "4", kind: kInt), Param(name: "dark", typ: "Color", default: "color(0, 0, 0)", kind: kColor), Param(name: "light", typ: "Color", default: "color(255, 255, 255)", kind: kColor)], returns: "Bitmap", call: nil)
  controls.mgetOrPut("newCanvas2D", Control(name: "newCanvas2D", module: "canvas2d", doc: "A canvas of w x h (logical pixels) without a window: draw on it, then take toBitmap, getImageData or savePng. pixelRatio: backing pixels per logical pixel (2 for a sharper picture). Sizes are capped at 8192 pixels a side.")).overloads.add Overload(params: @[Param(name: "w", typ: "int", default: "", kind: kInt), Param(name: "h", typ: "int", default: "", kind: kInt), Param(name: "pixelRatio", typ: "float", default: "1.0", kind: kFloat)], returns: "Canvas2D", call: c288_newCanvas2D)
  controls.mgetOrPut("newReport", Control(name: "newReport", module: "report", doc: "An empty document with 2 cm margins and 10 pt text.")).overloads.add Overload(params: @[Param(name: "title", typ: "string", default: "\"\"", kind: kStr), Param(name: "author", typ: "string", default: "\"\"", kind: kStr), Param(name: "page", typ: "", default: "A4", kind: kNone)], returns: "Report", call: c289_newReport)
  controls.mgetOrPut("header", Control(name: "header", module: "report", doc: "The text at the top of every page, at the left, middle and right. {page}, {pages}, {title} and {date} are filled in.")).overloads.add Overload(params: @[Param(name: "r", typ: "Report", default: "", kind: kNone), Param(name: "left", typ: "string", default: "\"\"", kind: kStr), Param(name: "center", typ: "string", default: "\"\"", kind: kStr), Param(name: "right", typ: "string", default: "\"\"", kind: kStr)], returns: "", call: nil)
  controls.mgetOrPut("footer", Control(name: "footer", module: "report", doc: "The text at the bottom of every page (see header): doc.footer(\"\", \"Page {page} of {pages}\", \"\").")).overloads.add Overload(params: @[Param(name: "r", typ: "Report", default: "", kind: kNone), Param(name: "left", typ: "string", default: "\"\"", kind: kStr), Param(name: "center", typ: "string", default: "\"\"", kind: kStr), Param(name: "right", typ: "string", default: "\"\"", kind: kStr)], returns: "", call: nil)
  controls.mgetOrPut("newTable", Control(name: "newTable", module: "report", doc: "A table with a header row of headers (repeated on every page; none when empty). widths: > 0 points, < 0 shares ([-3.0, -1, -1]: the first column three times as wide), aligns per column.")).overloads.add Overload(params: @[Param(name: "headers", typ: "openArray[string]", default: "[]", kind: kStrs), Param(name: "widths", typ: "openArray[float]", default: "[]", kind: kFloats), Param(name: "aligns", typ: "openArray[Align]", default: "[]", kind: kNone), Param(name: "grid", typ: "bool", default: "false", kind: kBool), Param(name: "zebra", typ: "bool", default: "true", kind: kBool)], returns: "ReportTable", call: c292_newTable)
  controls.mgetOrPut("addRow", Control(name: "addRow", module: "report", doc: "A row of plain cells.")).overloads.add Overload(params: @[Param(name: "t", typ: "var ReportTable", default: "", kind: kNone), Param(name: "cells", typ: "openArray[string]", default: "", kind: kStrs)], returns: "", call: nil)
  controls.mgetOrPut("addRow", Control(name: "addRow", module: "report", doc: "A row of cells made with cell.")).overloads.add Overload(params: @[Param(name: "t", typ: "var ReportTable", default: "", kind: kNone), Param(name: "cells", typ: "openArray[Cell]", default: "", kind: kNone)], returns: "", call: nil)
  controls.mgetOrPut("addTotals", Control(name: "addTotals", module: "report", doc: "A totals row: bold, with a line above it.")).overloads.add Overload(params: @[Param(name: "t", typ: "var ReportTable", default: "", kind: kNone), Param(name: "cells", typ: "openArray[string]", default: "", kind: kStrs)], returns: "", call: nil)
  controls.mgetOrPut("savePdf", Control(name: "savePdf", module: "report", doc: "Writes the document as a PDF file -- first to a temporary file next to it, then moved into place, so a reader never sees half a file. Raises IOError (or OSError) when it cannot.")).overloads.add Overload(params: @[Param(name: "r", typ: "Report", default: "", kind: kNone), Param(name: "path", typ: "string", default: "", kind: kStr)], returns: "", call: nil)
  controls.mgetOrPut("savePng", Control(name: "savePng", module: "report", doc: "Writes page index (from 0) as a PNG picture at dpi.")).overloads.add Overload(params: @[Param(name: "r", typ: "Report", default: "", kind: kNone), Param(name: "index", typ: "int", default: "", kind: kInt), Param(name: "path", typ: "string", default: "", kind: kStr), Param(name: "dpi", typ: "float", default: "150.0", kind: kFloat)], returns: "bool", call: nil)
  controls.mgetOrPut("printPdf", Control(name: "printPdf", module: "report", doc: "Sends the PDF file path to a printer, and says what happened (or why it could not) in message:Linux, the BSDs, macOS: through CUPS (lp) to printer, or the default one; it fails cleanly when no printer is set up. Windows: to the app that prints PDF files (the \"print\" verb), so a PDF reader must be installed (Acrobat Reader, SumatraPDF, Foxit...). Android: the system's print dialog (its printers, Sa")).overloads.add Overload(params: @[Param(name: "path", typ: "string", default: "", kind: kStr), Param(name: "jobName", typ: "string", default: "\"\"", kind: kStr), Param(name: "printer", typ: "string", default: "\"\"", kind: kStr), Param(name: "pages", typ: "int", default: "0", kind: kInt)], returns: "tuple[ok: bool, message: string]", call: c298_printPdf)
  controls.mgetOrPut("printReport", Control(name: "printReport", module: "report", doc: "Prints the document (see printPdf for each system): it is written as a PDF file in a temporary folder first.")).overloads.add Overload(params: @[Param(name: "r", typ: "Report", default: "", kind: kNone), Param(name: "jobName", typ: "string", default: "\"\"", kind: kStr), Param(name: "printer", typ: "string", default: "\"\"", kind: kStr)], returns: "tuple[ok: bool, message: string]", call: nil)
  controls.mgetOrPut("reportFromHtml", Control(name: "reportFromHtml", module: "report", doc: "A document from HTML -- typically a filled-in template (reportFromHtml(renderTemplate(tpl, data))). It reads:h1-h4 (titles), p, div, br, hr, pre, blockquote, ul / ol / li b / strong, i / em, u, code / tt / kbd, small, a href (links), span and font with style=\"color: #c00; font-weight: bold; font-style: italic; font-size: 14px\" table (border=\"1\": lines around every cell), thead / tbody / tfoot (tot")).overloads.add Overload(params: @[Param(name: "html", typ: "string", default: "", kind: kStr), Param(name: "baseDir", typ: "string", default: "\"\"", kind: kStr), Param(name: "title", typ: "string", default: "\"\"", kind: kStr)], returns: "Report", call: c300_reportFromHtml)
  controls.mgetOrPut("reportView", Control(name: "reportView", module: "report", doc: "The pages of r on a gray desk, one under the other, with page buttons and a zoom list above them (fit the width, the whole page, 50% to 200%; 100% is the paper's real size on a 96 dpi screen). The wheel and the standard scroll bars move through the pages (Shift + the wheel sideways, Ctrl + the wheel zooms); a finger or a mouse drag moves them; with the keyboard focus: arrows, Page Up / Page Down, ")).overloads.add Overload(params: @[Param(name: "r", typ: "Report", default: "", kind: kNone), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "ReportViewEvent", call: nil)
  controls.mgetOrPut("reportViewPage", Control(name: "reportViewPage", module: "report", doc: "The page the reportView with key shows (from 0).")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "int", call: c302_reportViewPage)
  controls.mgetOrPut("pdfPreview", Control(name: "pdfPreview", module: "pdfview", doc: "The first page of a PDF (or an .ai) drawn to fit maxW x maxH; nil when it is not one.")).overloads.add Overload(params: @[Param(name: "path", typ: "string", default: "", kind: kStr), Param(name: "maxW", typ: "int", default: "512", kind: kInt), Param(name: "maxH", typ: "int", default: "512", kind: kInt)], returns: "Bitmap", call: c303_pdfPreview)
  controls.mgetOrPut("openPdfView", Control(name: "openPdfView", module: "pdfview", doc: "Opens the PDF path to read (its pages are drawn when shown). Raises PdfError when it is not one or is damaged past reading, IOError when it cannot be read.")).overloads.add Overload(params: @[Param(name: "path", typ: "string", default: "", kind: kStr)], returns: "PdfView", call: c304_openPdfView)
  controls.mgetOrPut("pdfView", Control(name: "pdfView", module: "pdfview", doc: "The pages of v one under another on a gray ground, each drawn at the size it is shown (while it is being drawn, the one drawn before, or a blank page). The wheel and the scroll bars (a finger) move along; Ctrl + the wheel zooms; a double click (a double tap) goes between as wide as the view and twice that. With the focus: Page Up / Down, Space, Home, End, the arrows, + / - / 0 (as wide as the view")).overloads.add Overload(params: @[Param(name: "v", typ: "PdfView", default: "", kind: kNone), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt)], returns: "PdfViewEvent", call: nil)
  controls.mgetOrPut("osmTiles", Control(name: "osmTiles", module: "tilemap", doc: "OpenStreetMap's own map (its servers are for light use; your app's name goes with each request: tileAgent).")).overloads.add Overload(params: @[], returns: "TileSource", call: c306_osmTiles)
  controls.mgetOrPut("openTopoMap", Control(name: "openTopoMap", module: "tilemap", doc: "OpenTopoMap: heights, contour lines, paths (to zoom 17).")).overloads.add Overload(params: @[], returns: "TileSource", call: c307_openTopoMap)
  controls.mgetOrPut("cartoTiles", Control(name: "cartoTiles", module: "tilemap", doc: "CARTO's basemaps: \"light_all\" (Positron), \"dark_all\" (Dark Matter), \"rastertiles/voyager\" (Voyager); their _nolabels and _only_labels.")).overloads.add Overload(params: @[Param(name: "style", typ: "string", default: "\"light_all\"", kind: kStr)], returns: "TileSource", call: c308_cartoTiles)
  controls.mgetOrPut("googleTiles", Control(name: "googleTiles", module: "tilemap", doc: "Google's Map Tiles API (2D tiles): mapType \"roadmap\", \"satellite\" or \"terrain\"; a key with the Map Tiles API enabled.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "mapType", typ: "string", default: "\"roadmap\"", kind: kStr), Param(name: "language", typ: "string", default: "\"en-US\"", kind: kStr), Param(name: "region", typ: "string", default: "\"US\"", kind: kStr)], returns: "TileSource", call: c309_googleTiles)
  controls.mgetOrPut("azureTiles", Control(name: "azureTiles", module: "tilemap", doc: "Azure Maps (Render, Get Map Tile): \"microsoft.base.road\", \"microsoft.base.darkgrey\", \"microsoft.imagery\", \"microsoft.base.hybrid.road\"...")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "tileset", typ: "string", default: "\"microsoft.base.road\"", kind: kStr), Param(name: "language", typ: "string", default: "\"\"", kind: kStr)], returns: "TileSource", call: c310_azureTiles)
  controls.mgetOrPut("mapboxTiles", Control(name: "mapboxTiles", module: "tilemap", doc: "Mapbox's styles as pictures: \"mapbox/streets-v12\", \"mapbox/outdoors-v12\", \"mapbox/light-v11\", \"mapbox/dark-v11\", \"mapbox/satellite-streets-v12\" or a style of your own (\"you/abc123\").")).overloads.add Overload(params: @[Param(name: "token", typ: "string", default: "", kind: kStr), Param(name: "style", typ: "string", default: "\"mapbox/streets-v12\"", kind: kStr)], returns: "TileSource", call: c311_mapboxTiles)
  controls.mgetOrPut("mapboxVector", Control(name: "mapboxVector", module: "tilemap", doc: "Mapbox Streets v8 as vector tiles, drawn by the kit in style.")).overloads.add Overload(params: @[Param(name: "token", typ: "string", default: "", kind: kStr), Param(name: "style", typ: "", default: "classicStyle()", kind: kNone)], returns: "TileSource", call: c312_mapboxVector)
  controls.mgetOrPut("hereTiles", Control(name: "hereTiles", module: "tilemap", doc: "HERE's Raster Tile API: \"explore.day\", \"explore.night\", \"lite.day\", \"satellite.day\", \"explore.satellite.day\", \"logistics.day\"...")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "style", typ: "string", default: "\"explore.day\"", kind: kStr)], returns: "TileSource", call: c313_hereTiles)
  controls.mgetOrPut("mapTilerTiles", Control(name: "mapTilerTiles", module: "tilemap", doc: "MapTiler's maps as pictures: \"streets-v2\", \"outdoor-v2\", \"basic-v2\", \"bright-v2\", \"satellite\", \"topo-v2\", \"dataviz\"...")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "map", typ: "string", default: "\"streets-v2\"", kind: kStr)], returns: "TileSource", call: c314_mapTilerTiles)
  controls.mgetOrPut("mapTilerVector", Control(name: "mapTilerVector", module: "tilemap", doc: "MapTiler's vector tiles (OpenMapTiles), drawn by the kit in style.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "style", typ: "", default: "classicStyle()", kind: kNone)], returns: "TileSource", call: c315_mapTilerVector)
  controls.mgetOrPut("protomapsVector", Control(name: "protomapsVector", module: "tilemap", doc: "Protomaps' basemap (its API; or a .pmtiles file of it: pmtilesSource).")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "style", typ: "", default: "classicStyle()", kind: kNone)], returns: "TileSource", call: c316_protomapsVector)
  controls.mgetOrPut("esriTiles", Control(name: "esriTiles", module: "tilemap", doc: "Esri's (ArcGIS) basemaps: \"World_Street_Map\", \"World_Imagery\", \"World_Topo_Map\", \"World_Terrain_Base\"...; with a token of your ArcGIS account, through its basemap service.")).overloads.add Overload(params: @[Param(name: "service", typ: "string", default: "\"World_Street_Map\"", kind: kStr), Param(name: "token", typ: "string", default: "\"\"", kind: kStr)], returns: "TileSource", call: c317_esriTiles)
  controls.mgetOrPut("tomTomTiles", Control(name: "tomTomTiles", module: "tilemap", doc: "TomTom's Map Display API: layer \"basic\", \"hybrid\" or \"labels\", style \"main\" or \"night\".")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "layer", typ: "string", default: "\"basic\"", kind: kStr), Param(name: "style", typ: "string", default: "\"main\"", kind: kStr)], returns: "TileSource", call: c318_tomTomTiles)
  controls.mgetOrPut("stadiaTiles", Control(name: "stadiaTiles", module: "tilemap", doc: "Stadia Maps: \"alidade_smooth\", \"alidade_smooth_dark\", \"outdoors\", \"osm_bright\", \"stamen_toner\", \"stamen_terrain\" (a key, or your app's web address registered with them).")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "\"\"", kind: kStr), Param(name: "style", typ: "string", default: "\"alidade_smooth\"", kind: kStr)], returns: "TileSource", call: c319_stadiaTiles)
  controls.mgetOrPut("amapTiles", Control(name: "amapTiles", module: "tilemap", doc: "AMap (Gaode) of China: its streets, or satellite pictures; GCJ-02.")).overloads.add Overload(params: @[Param(name: "satellite", typ: "bool", default: "false", kind: kBool), Param(name: "language", typ: "string", default: "\"zh_cn\"", kind: kStr)], returns: "TileSource", call: c320_amapTiles)
  controls.mgetOrPut("tencentTiles", Control(name: "tencentTiles", module: "tilemap", doc: "Tencent's map of China; GCJ-02.")).overloads.add Overload(params: @[], returns: "TileSource", call: c321_tencentTiles)
  controls.mgetOrPut("tiandituTiles", Control(name: "tiandituTiles", module: "tilemap", doc: "Tianditu, China's national map (CGCS2000, as GPS): layer \"vec\" (streets), \"img\" (satellite), \"ter\" (terrain); their names over them are the \"cva\", \"cia\", \"cta\" layers.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "layer", typ: "string", default: "\"vec\"", kind: kStr)], returns: "TileSource", call: c322_tiandituTiles)
  controls.mgetOrPut("pmtilesSource", Control(name: "pmtilesSource", module: "tilemap", doc: "A PMTiles archive (a file, or its web address: read in pieces), raster or vector as it holds.")).overloads.add Overload(params: @[Param(name: "path", typ: "string", default: "", kind: kStr), Param(name: "style", typ: "", default: "classicStyle()", kind: kNone), Param(name: "attribution", typ: "string", default: "\"© OpenStreetMap contributors\"", kind: kStr)], returns: "TileSource", call: c323_pmtilesSource)
  controls.mgetOrPut("mbtilesSource", Control(name: "mbtilesSource", module: "tilemap", doc: "An MBTiles file, raster or vector as it holds.")).overloads.add Overload(params: @[Param(name: "path", typ: "string", default: "", kind: kStr), Param(name: "style", typ: "", default: "classicStyle()", kind: kNone), Param(name: "attribution", typ: "string", default: "\"© OpenStreetMap contributors\"", kind: kStr)], returns: "TileSource", call: c324_mbtilesSource)
  controls.mgetOrPut("folderSource", Control(name: "folderSource", module: "tilemap", doc: "Tiles in folders of your own: dir/z/x/y.ext (what a tile tool writes; \"pbf\" for vector tiles).")).overloads.add Overload(params: @[Param(name: "dir", typ: "string", default: "", kind: kStr), Param(name: "ext", typ: "string", default: "\"png\"", kind: kStr), Param(name: "maxZoom", typ: "int", default: "18", kind: kInt), Param(name: "attribution", typ: "string", default: "\"\"", kind: kStr)], returns: "TileSource", call: c325_folderSource)
  controls.mgetOrPut("tileJsonSource", Control(name: "tileJsonSource", module: "tilemap", doc: "A TileJSON's tiles (OpenFreeMap: \"https://tiles.openfreemap.org/planet\"; a tile server's). Waits for it.")).overloads.add Overload(params: @[Param(name: "url", typ: "string", default: "", kind: kStr), Param(name: "style", typ: "", default: "classicStyle()", kind: kNone)], returns: "TileSource", call: c326_tileJsonSource)
  controls.mgetOrPut("mapKitPage", Control(name: "mapKitPage", module: "tilemap", doc: "A page with Apple's map (MapKit JS) for webView: token a MapKit JS token of your Apple developer account; the map around lat, lon, zoomMeters across.")).overloads.add Overload(params: @[Param(name: "token", typ: "string", default: "", kind: kStr), Param(name: "lat", typ: "float", default: "", kind: kFloat), Param(name: "lon", typ: "float", default: "", kind: kFloat), Param(name: "zoomMeters", typ: "float", default: "5000.0", kind: kFloat)], returns: "string", call: c327_mapKitPage)
  controls.mgetOrPut("googleMapsPage", Control(name: "googleMapsPage", module: "tilemap", doc: "A page with Google's own JavaScript map for webView (a key with the Maps JavaScript API enabled).")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "lat", typ: "float", default: "", kind: kFloat), Param(name: "lon", typ: "float", default: "", kind: kFloat), Param(name: "zoom", typ: "int", default: "12", kind: kInt)], returns: "string", call: c328_googleMapsPage)
  controls.mgetOrPut("quadkey", Control(name: "quadkey", module: "tilemap", doc: "A tile's quadkey (Bing's and Azure's numbering).")).overloads.add Overload(params: @[Param(name: "z", typ: "int", default: "", kind: kInt), Param(name: "x", typ: "int", default: "", kind: kInt), Param(name: "y", typ: "int", default: "", kind: kInt)], returns: "string", call: c329_quadkey)
  controls.mgetOrPut("tileUrl", Control(name: "tileUrl", module: "tilemap", doc: "The address of tile z/x/y of s (dense: the one with twice the pixels).")).overloads.add Overload(params: @[Param(name: "s", typ: "TileSource", default: "", kind: kNone), Param(name: "z", typ: "int", default: "", kind: kInt), Param(name: "x", typ: "int", default: "", kind: kInt), Param(name: "y", typ: "int", default: "", kind: kInt), Param(name: "dense", typ: "bool", default: "false", kind: kBool)], returns: "string", call: nil)
  controls.mgetOrPut("loadingTiles", Control(name: "loadingTiles", module: "tilemap", doc: "Tiles asked for and not yet come.")).overloads.add Overload(params: @[], returns: "int", call: c331_loadingTiles)
  controls.mgetOrPut("clearTileCache", Control(name: "clearTileCache", module: "tilemap", doc: "Forgets the tiles kept in memory (and on the disk with disk).")).overloads.add Overload(params: @[Param(name: "disk", typ: "bool", default: "false", kind: kBool)], returns: "", call: c332_clearTileCache)
  controls.mgetOrPut("fitBounds", Control(name: "fitBounds", module: "tilemap", doc: "Shows the area from south, west to north, east (degrees) as large as the map shows it (done when it is next drawn).")).overloads.add Overload(params: @[Param(name: "m", typ: "var TileMapState", default: "", kind: kNone), Param(name: "south", typ: "float", default: "", kind: kFloat), Param(name: "west", typ: "float", default: "", kind: kFloat), Param(name: "north", typ: "float", default: "", kind: kFloat), Param(name: "east", typ: "float", default: "", kind: kFloat)], returns: "", call: nil)
  controls.mgetOrPut("fitPoints", Control(name: "fitPoints", module: "tilemap", doc: "Shows all of points (a route, the markers).")).overloads.add Overload(params: @[Param(name: "m", typ: "var TileMapState", default: "", kind: kNone), Param(name: "points", typ: "openArray[LatLon]", default: "", kind: kNone)], returns: "", call: nil)
  controls.mgetOrPut("centerOn", Control(name: "centerOn", module: "tilemap", doc: "Moves the view to lat, lon (and zoom when given).")).overloads.add Overload(params: @[Param(name: "m", typ: "var TileMapState", default: "", kind: kNone), Param(name: "lat", typ: "float", default: "", kind: kFloat), Param(name: "lon", typ: "float", default: "", kind: kFloat), Param(name: "zoom", typ: "float", default: "-1.0", kind: kFloat)], returns: "", call: nil)
  controls.mgetOrPut("metersPerPixel", Control(name: "metersPerPixel", module: "tilemap", doc: "How many meters a design pixel covers at the middle of the view.")).overloads.add Overload(params: @[Param(name: "m", typ: "TileMapState", default: "", kind: kNone)], returns: "float", call: nil)
  controls.mgetOrPut("tileMap", Control(name: "tileMap", module: "tilemap", doc: "The map of src, height pixels high (-1: the room left), as wide as the space it is in; overlays drawn over it (labels, sea marks, rain), shapes and markers over them. Drag to move it; the wheel, a double click, two fingers, + / - (with the focus) or its buttons zoom; arrows move it. clicked reports a click or a tap and where.")).overloads.add Overload(params: @[Param(name: "m", typ: "var TileMapState", default: "", kind: kNone), Param(name: "src", typ: "TileSource", default: "", kind: kNone), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "markers", typ: "openArray[MapMarker]", default: "[]", kind: kNone), Param(name: "shapes", typ: "openArray[MapShape]", default: "[]", kind: kNone), Param(name: "overlays", typ: "openArray[TileSource]", default: "[]", kind: kNone), Param(name: "showScale", typ: "bool", default: "true", kind: kBool), Param(name: "showZoom", typ: "bool", default: "true", kind: kBool), Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "TileMapEvent", call: nil)
  controls.mgetOrPut("mapPointOf", Control(name: "mapPointOf", module: "tilemap", doc: "Where p is drawn in the last tileMap of m (logical pixels).")).overloads.add Overload(params: @[Param(name: "m", typ: "TileMapState", default: "", kind: kNone), Param(name: "src", typ: "TileSource", default: "", kind: kNone), Param(name: "p", typ: "LatLon", default: "", kind: kNone)], returns: "tuple[x, y: int]", call: nil)
  controls.mgetOrPut("tilesIn", Control(name: "tilesIn", module: "tilemap", doc: "How many tiles an area has from minZoom to maxZoom.")).overloads.add Overload(params: @[Param(name: "south", typ: "float", default: "", kind: kFloat), Param(name: "west", typ: "float", default: "", kind: kFloat), Param(name: "north", typ: "float", default: "", kind: kFloat), Param(name: "east", typ: "float", default: "", kind: kFloat), Param(name: "minZoom", typ: "int", default: "", kind: kInt), Param(name: "maxZoom", typ: "int", default: "", kind: kInt)], returns: "int", call: c339_tilesIn)
  controls.mgetOrPut("keepArea", Control(name: "keepArea", module: "tilemap", doc: "Fetches an area's tiles into the disk cache, for a map that works without the network (a car, a kiosk); \"\" when it was asked, else why not. OpenStreetMap's own servers do not allow it (their rule): take a service that does, or a .pmtiles file of the area.")).overloads.add Overload(params: @[Param(name: "src", typ: "TileSource", default: "", kind: kNone), Param(name: "south", typ: "float", default: "", kind: kFloat), Param(name: "west", typ: "float", default: "", kind: kFloat), Param(name: "north", typ: "float", default: "", kind: kFloat), Param(name: "east", typ: "float", default: "", kind: kFloat), Param(name: "minZoom", typ: "int", default: "", kind: kInt), Param(name: "maxZoom", typ: "int", default: "", kind: kInt)], returns: "string", call: nil)
  controls.mgetOrPut("routeShape", Control(name: "routeShape", module: "tilemap", doc: "A route found by geo.route as a line on the map.")).overloads.add Overload(params: @[Param(name: "r", typ: "Route", default: "", kind: kNone), Param(name: "color", typ: "Color", default: "Color()", kind: kColor), Param(name: "width", typ: "float", default: "5.0", kind: kFloat), Param(name: "label", typ: "string", default: "\"\"", kind: kStr)], returns: "MapShape", call: nil)
  controls.mgetOrPut("geoJsonShapes", Control(name: "geoJsonShapes", module: "tilemap", doc: "The lines and areas of a GeoJSON text as shapes, its points as markers.")).overloads.add Overload(params: @[Param(name: "text", typ: "string", default: "", kind: kStr), Param(name: "color", typ: "Color", default: "Color()", kind: kColor), Param(name: "fill", typ: "Color", default: "Color()", kind: kColor)], returns: "tuple[shapes: seq[MapShape], markers: seq[MapMarker]]", call: c342_geoJsonShapes)
  controls.mgetOrPut("cameras", Control(name: "cameras", module: "capture", doc: "The cameras the system has.")).overloads.add Overload(params: @[], returns: "seq[CameraInfo]", call: c343_cameras)
  controls.mgetOrPut("cameraView", Control(name: "cameraView", module: "capture", doc: "The camera's live picture, as large as fits, height pixels high (-1: the room left). camera: one of cameras() (\"\"): the first, or one that looks facing). mirror: shown as in a mirror (a front camera). The camera is on while the view is drawn, and off once it is not.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "\"\"", kind: kStr), Param(name: "camera", typ: "string", default: "\"\"", kind: kStr), Param(name: "facing", typ: "CameraFacing", default: "cfAny", kind: kEnum), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "mirror", typ: "bool", default: "false", kind: kBool)], returns: "CameraEvent", call: c344_cameraView)
  controls.mgetOrPut("cameraPhoto", Control(name: "cameraPhoto", module: "capture", doc: "Saves the camera's next picture to path (JPEG; PNG by its extension); CameraEvent.photo says when it is there.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "\"\"", kind: kStr), Param(name: "path", typ: "string", default: "", kind: kStr)], returns: "", call: c345_cameraPhoto)
  controls.mgetOrPut("cameraFrame", Control(name: "cameraFrame", module: "capture", doc: "The camera's latest picture (nil: none yet), to read it: a barcode, a face. Not to be changed.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "Bitmap", call: c346_cameraFrame)
  controls.mgetOrPut("cameraRecord", Control(name: "cameraRecord", module: "capture", doc: "Records the camera into the video path (MP4, H.264, 30 pictures a second, by retroui/media's writer) until cameraStop; false when the camera shows nothing yet or no writer is there.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "\"\"", kind: kStr), Param(name: "path", typ: "string", default: "", kind: kStr)], returns: "bool", call: c347_cameraRecord)
  controls.mgetOrPut("cameraStop", Control(name: "cameraStop", module: "capture", doc: "Ends the recording cameraRecord started; CameraEvent.saved says when the video is written.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "", call: c348_cameraStop)
  controls.mgetOrPut("cameraClose", Control(name: "cameraClose", module: "capture", doc: "Lets the camera go now (it goes by itself once its view is not drawn).")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "", call: c349_cameraClose)
  controls.mgetOrPut("recordSound", Control(name: "recordSound", module: "capture", doc: "Records the microphone into path until stopRecordingSound: a WAV file (16-bit, 44.1 kHz, mono) on Linux and Windows; on Android, iOS and macOS the system's recorder writes it (AAC in an .m4a by its extension, else WAV). False when there is no microphone (or the user said no).")).overloads.add Overload(params: @[Param(name: "path", typ: "string", default: "", kind: kStr)], returns: "bool", call: c350_recordSound)
  controls.mgetOrPut("stopRecordingSound", Control(name: "stopRecordingSound", module: "capture", doc: "Ends the recording recordSound started and writes it; how long it is in milliseconds (0: not known, -1: it could not be written).")).overloads.add Overload(params: @[], returns: "int", call: c351_stopRecordingSound)
  controls.mgetOrPut("recordingSound", Control(name: "recordingSound", module: "capture", doc: "The microphone records.")).overloads.add Overload(params: @[], returns: "bool", call: c352_recordingSound)
  controls.mgetOrPut("soundLevel", Control(name: "soundLevel", module: "capture", doc: "How loud the microphone is now, 0..1 (a meter; 0 when not recording).")).overloads.add Overload(params: @[], returns: "float", call: c353_soundLevel)
  controls.mgetOrPut("mediaSessionBusName", Control(name: "mediaSessionBusName", module: "mediasession", doc: "The bus name the app's controls have on D-Bus (\"\" before setNowPlaying): playerctl -p NAME, tests.")).overloads.add Overload(params: @[], returns: "string", call: c354_mediaSessionBusName)
  controls.mgetOrPut("setNowPlaying", Control(name: "setNowPlaying", module: "mediasession", doc: "What the app plays, for the system's media controls; the controls' presses come in mediaKeys. Call it when it changes, or every frame: the system is told only what changed (a position that keeps time with the playing is not news).")).overloads.add Overload(params: @[Param(name: "np", typ: "NowPlaying", default: "", kind: kNone)], returns: "", call: nil)
  controls.mgetOrPut("mediaKeys", Control(name: "mediaKeys", module: "mediasession", doc: "What the system's media controls asked since the last frame (the lock screen, the media keys of a keyboard or a headset, the desktop's media applet). Empty (and nothing made) when nothing was pressed.")).overloads.add Overload(params: @[], returns: "seq[MediaKeyEvent]", call: c356_mediaKeys)
  controls.mgetOrPut("space", Control(name: "space", module: "core", doc: "Empty space: down in a column, right in a row.")).overloads.add Overload(params: @[Param(name: "px", typ: "int", default: "Gap", kind: kInt)], returns: "", call: c357_space)
  controls.mgetOrPut("spring", Control(name: "spring", module: "core", doc: "In a row: the widgets after it go to the row's right end.")).overloads.add Overload(params: @[], returns: "", call: c358_spring)
  controls.mgetOrPut("fontSample", Control(name: "fontSample", module: "textwidgets", doc: "text in a font, h screen pixels tall (kept: drawn once).")).overloads.add Overload(params: @[Param(name: "family", typ: "string", default: "", kind: kStr), Param(name: "style", typ: "string", default: "", kind: kStr), Param(name: "text", typ: "string", default: "", kind: kStr), Param(name: "h", typ: "int", default: "", kind: kInt), Param(name: "color", typ: "", default: "0xFF000000'u32", kind: kNone)], returns: "Bitmap", call: c359_fontSample)
  controls.mgetOrPut("fontCombo", Control(name: "fontCombo", module: "textwidgets", doc: "A drop-down list of the font families (the system's and the built-in ones), each shown in its own letters.")).overloads.add Overload(params: @[Param(name: "family", typ: "var string", default: "", kind: kVStr), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c360_fontCombo)
  controls.mgetOrPut("fontStyleCombo", Control(name: "fontStyleCombo", module: "textwidgets", doc: "The styles of family (\"Regular\", \"Bold\"...), each in its letters.")).overloads.add Overload(params: @[Param(name: "family", typ: "string", default: "", kind: kStr), Param(name: "style", typ: "var string", default: "", kind: kVStr), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: c361_fontStyleCombo)
  controls.mgetOrPut("`&lt;`", Control(name: "`&lt;`", module: "richedit", doc: "a comes before b.")).overloads.add Overload(params: @[Param(name: "a", typ: "RichPos", default: "", kind: kNone), Param(name: "b", typ: "RichPos", default: "", kind: kNone)], returns: "bool", call: nil)
  controls.mgetOrPut("`&lt;=`", Control(name: "`&lt;=`", module: "richedit", doc: "a comes before b or is b.")).overloads.add Overload(params: @[Param(name: "a", typ: "RichPos", default: "", kind: kNone), Param(name: "b", typ: "RichPos", default: "", kind: kNone)], returns: "bool", call: nil)
  controls.mgetOrPut("richEdit", Control(name: "richEdit", module: "richedit", doc: "The rich text editor, height pixels high (-1: the height left in the window), bound to d: true when its text (or its formatting) changed this frame. placeholder shows while it is empty; key tells editors of the same document apart. Its menu (a right click, a long press): Undo, Cut, Copy, Paste, Link, Select all. In a right-to-left interface each paragraph keeps its own direction (Arabic at the rig")).overloads.add Overload(params: @[Param(name: "d", typ: "var RichDoc", default: "", kind: kNone), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "key", typ: "string", default: "\"\"", kind: kStr), Param(name: "placeholder", typ: "string", default: "\"\"", kind: kStr), Param(name: "enabled", typ: "bool", default: "true", kind: kBool)], returns: "bool", call: nil)
  controls.mgetOrPut("richToolbar", Control(name: "richToolbar", module: "richedit", doc: "A row of formatting buttons for d's editor: bold, italic, underline, strikethrough, monospace, the text color and size, bullets, numbers, a quote, indents, alignment, a link (asked for in a small dialog) and plain text again; pressed for what the caret has. compact (phones): the most used ones, the rest in a \"more\" menu.")).overloads.add Overload(params: @[Param(name: "d", typ: "var RichDoc", default: "", kind: kNone), Param(name: "compact", typ: "bool", default: "false", kind: kBool)], returns: "", call: nil)
  controls.mgetOrPut("richFromHtml", Control(name: "richFromHtml", module: "richedit", doc: "A document from a mail's HTML: paragraphs (p, div, br), bold, italic, underline, strike, font and span styles (color, size, weight, family), links, lists (nested), quotes, headings, preformatted text; anything else gives its text, scripts and styles nothing. Never raises.")).overloads.add Overload(params: @[Param(name: "html", typ: "string", default: "", kind: kStr)], returns: "RichDoc", call: c366_richFromHtml)
  controls.mgetOrPut("`[]`", Control(name: "`[]`", module: "qrcode", doc: "The module in column x, row y is dark (outside the code: light).")).overloads.add Overload(params: @[Param(name: "q", typ: "QrCode", default: "", kind: kNone), Param(name: "x", typ: "int", default: "", kind: kInt), Param(name: "y", typ: "int", default: "", kind: kInt)], returns: "bool", call: nil)
  controls.mgetOrPut("qrBitmap", Control(name: "qrBitmap", module: "qrcode", doc: "The code as a picture: scale pixels a module, border modules of quiet zone (light) around it (4 is what the standard asks).")).overloads.add Overload(params: @[Param(name: "q", typ: "QrCode", default: "", kind: kNone), Param(name: "scale", typ: "int", default: "4", kind: kInt), Param(name: "border", typ: "int", default: "4", kind: kInt), Param(name: "dark", typ: "Color", default: "color(0, 0, 0)", kind: kColor), Param(name: "light", typ: "Color", default: "color(255, 255, 255)", kind: kColor)], returns: "Bitmap", call: nil)
  controls.mgetOrPut("pdfPreview", Control(name: "pdfPreview", module: "pdfview", doc: "The first page of a PDF (or an .ai) drawn to fit maxW x maxH; nil when it is not one.")).overloads.add Overload(params: @[Param(name: "path", typ: "string", default: "", kind: kStr), Param(name: "maxW", typ: "int", default: "512", kind: kInt), Param(name: "maxH", typ: "int", default: "512", kind: kInt)], returns: "Bitmap", call: c369_pdfPreview)
  controls.mgetOrPut("openPdfView", Control(name: "openPdfView", module: "pdfview", doc: "Opens the PDF path to read (its pages are drawn when shown). Raises PdfError when it is not one or is damaged past reading, IOError when it cannot be read.")).overloads.add Overload(params: @[Param(name: "path", typ: "string", default: "", kind: kStr)], returns: "PdfView", call: c370_openPdfView)
  controls.mgetOrPut("pdfView", Control(name: "pdfView", module: "pdfview", doc: "The pages of v one under another on a gray ground, each drawn at the size it is shown (while it is being drawn, the one drawn before, or a blank page). The wheel and the scroll bars (a finger) move along; Ctrl + the wheel zooms; a double click (a double tap) goes between as wide as the view and twice that. With the focus: Page Up / Down, Space, Home, End, the arrows, + / - / 0 (as wide as the view")).overloads.add Overload(params: @[Param(name: "v", typ: "PdfView", default: "", kind: kNone), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt)], returns: "PdfViewEvent", call: nil)
  controls.mgetOrPut("osmTiles", Control(name: "osmTiles", module: "tilemap", doc: "OpenStreetMap's own map (its servers are for light use; your app's name goes with each request: tileAgent).")).overloads.add Overload(params: @[], returns: "TileSource", call: c372_osmTiles)
  controls.mgetOrPut("openTopoMap", Control(name: "openTopoMap", module: "tilemap", doc: "OpenTopoMap: heights, contour lines, paths (to zoom 17).")).overloads.add Overload(params: @[], returns: "TileSource", call: c373_openTopoMap)
  controls.mgetOrPut("cartoTiles", Control(name: "cartoTiles", module: "tilemap", doc: "CARTO's basemaps: \"light_all\" (Positron), \"dark_all\" (Dark Matter), \"rastertiles/voyager\" (Voyager); their _nolabels and _only_labels.")).overloads.add Overload(params: @[Param(name: "style", typ: "string", default: "\"light_all\"", kind: kStr)], returns: "TileSource", call: c374_cartoTiles)
  controls.mgetOrPut("googleTiles", Control(name: "googleTiles", module: "tilemap", doc: "Google's Map Tiles API (2D tiles): mapType \"roadmap\", \"satellite\" or \"terrain\"; a key with the Map Tiles API enabled.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "mapType", typ: "string", default: "\"roadmap\"", kind: kStr), Param(name: "language", typ: "string", default: "\"en-US\"", kind: kStr), Param(name: "region", typ: "string", default: "\"US\"", kind: kStr)], returns: "TileSource", call: c375_googleTiles)
  controls.mgetOrPut("azureTiles", Control(name: "azureTiles", module: "tilemap", doc: "Azure Maps (Render, Get Map Tile): \"microsoft.base.road\", \"microsoft.base.darkgrey\", \"microsoft.imagery\", \"microsoft.base.hybrid.road\"...")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "tileset", typ: "string", default: "\"microsoft.base.road\"", kind: kStr), Param(name: "language", typ: "string", default: "\"\"", kind: kStr)], returns: "TileSource", call: c376_azureTiles)
  controls.mgetOrPut("mapboxTiles", Control(name: "mapboxTiles", module: "tilemap", doc: "Mapbox's styles as pictures: \"mapbox/streets-v12\", \"mapbox/outdoors-v12\", \"mapbox/light-v11\", \"mapbox/dark-v11\", \"mapbox/satellite-streets-v12\" or a style of your own (\"you/abc123\").")).overloads.add Overload(params: @[Param(name: "token", typ: "string", default: "", kind: kStr), Param(name: "style", typ: "string", default: "\"mapbox/streets-v12\"", kind: kStr)], returns: "TileSource", call: c377_mapboxTiles)
  controls.mgetOrPut("mapboxVector", Control(name: "mapboxVector", module: "tilemap", doc: "Mapbox Streets v8 as vector tiles, drawn by the kit in style.")).overloads.add Overload(params: @[Param(name: "token", typ: "string", default: "", kind: kStr), Param(name: "style", typ: "", default: "classicStyle()", kind: kNone)], returns: "TileSource", call: c378_mapboxVector)
  controls.mgetOrPut("hereTiles", Control(name: "hereTiles", module: "tilemap", doc: "HERE's Raster Tile API: \"explore.day\", \"explore.night\", \"lite.day\", \"satellite.day\", \"explore.satellite.day\", \"logistics.day\"...")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "style", typ: "string", default: "\"explore.day\"", kind: kStr)], returns: "TileSource", call: c379_hereTiles)
  controls.mgetOrPut("mapTilerTiles", Control(name: "mapTilerTiles", module: "tilemap", doc: "MapTiler's maps as pictures: \"streets-v2\", \"outdoor-v2\", \"basic-v2\", \"bright-v2\", \"satellite\", \"topo-v2\", \"dataviz\"...")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "map", typ: "string", default: "\"streets-v2\"", kind: kStr)], returns: "TileSource", call: c380_mapTilerTiles)
  controls.mgetOrPut("mapTilerVector", Control(name: "mapTilerVector", module: "tilemap", doc: "MapTiler's vector tiles (OpenMapTiles), drawn by the kit in style.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "style", typ: "", default: "classicStyle()", kind: kNone)], returns: "TileSource", call: c381_mapTilerVector)
  controls.mgetOrPut("protomapsVector", Control(name: "protomapsVector", module: "tilemap", doc: "Protomaps' basemap (its API; or a .pmtiles file of it: pmtilesSource).")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "style", typ: "", default: "classicStyle()", kind: kNone)], returns: "TileSource", call: c382_protomapsVector)
  controls.mgetOrPut("esriTiles", Control(name: "esriTiles", module: "tilemap", doc: "Esri's (ArcGIS) basemaps: \"World_Street_Map\", \"World_Imagery\", \"World_Topo_Map\", \"World_Terrain_Base\"...; with a token of your ArcGIS account, through its basemap service.")).overloads.add Overload(params: @[Param(name: "service", typ: "string", default: "\"World_Street_Map\"", kind: kStr), Param(name: "token", typ: "string", default: "\"\"", kind: kStr)], returns: "TileSource", call: c383_esriTiles)
  controls.mgetOrPut("tomTomTiles", Control(name: "tomTomTiles", module: "tilemap", doc: "TomTom's Map Display API: layer \"basic\", \"hybrid\" or \"labels\", style \"main\" or \"night\".")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "layer", typ: "string", default: "\"basic\"", kind: kStr), Param(name: "style", typ: "string", default: "\"main\"", kind: kStr)], returns: "TileSource", call: c384_tomTomTiles)
  controls.mgetOrPut("stadiaTiles", Control(name: "stadiaTiles", module: "tilemap", doc: "Stadia Maps: \"alidade_smooth\", \"alidade_smooth_dark\", \"outdoors\", \"osm_bright\", \"stamen_toner\", \"stamen_terrain\" (a key, or your app's web address registered with them).")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "\"\"", kind: kStr), Param(name: "style", typ: "string", default: "\"alidade_smooth\"", kind: kStr)], returns: "TileSource", call: c385_stadiaTiles)
  controls.mgetOrPut("amapTiles", Control(name: "amapTiles", module: "tilemap", doc: "AMap (Gaode) of China: its streets, or satellite pictures; GCJ-02.")).overloads.add Overload(params: @[Param(name: "satellite", typ: "bool", default: "false", kind: kBool), Param(name: "language", typ: "string", default: "\"zh_cn\"", kind: kStr)], returns: "TileSource", call: c386_amapTiles)
  controls.mgetOrPut("tencentTiles", Control(name: "tencentTiles", module: "tilemap", doc: "Tencent's map of China; GCJ-02.")).overloads.add Overload(params: @[], returns: "TileSource", call: c387_tencentTiles)
  controls.mgetOrPut("tiandituTiles", Control(name: "tiandituTiles", module: "tilemap", doc: "Tianditu, China's national map (CGCS2000, as GPS): layer \"vec\" (streets), \"img\" (satellite), \"ter\" (terrain); their names over them are the \"cva\", \"cia\", \"cta\" layers.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "layer", typ: "string", default: "\"vec\"", kind: kStr)], returns: "TileSource", call: c388_tiandituTiles)
  controls.mgetOrPut("pmtilesSource", Control(name: "pmtilesSource", module: "tilemap", doc: "A PMTiles archive (a file, or its web address: read in pieces), raster or vector as it holds.")).overloads.add Overload(params: @[Param(name: "path", typ: "string", default: "", kind: kStr), Param(name: "style", typ: "", default: "classicStyle()", kind: kNone), Param(name: "attribution", typ: "string", default: "\"© OpenStreetMap contributors\"", kind: kStr)], returns: "TileSource", call: c389_pmtilesSource)
  controls.mgetOrPut("mbtilesSource", Control(name: "mbtilesSource", module: "tilemap", doc: "An MBTiles file, raster or vector as it holds.")).overloads.add Overload(params: @[Param(name: "path", typ: "string", default: "", kind: kStr), Param(name: "style", typ: "", default: "classicStyle()", kind: kNone), Param(name: "attribution", typ: "string", default: "\"© OpenStreetMap contributors\"", kind: kStr)], returns: "TileSource", call: c390_mbtilesSource)
  controls.mgetOrPut("folderSource", Control(name: "folderSource", module: "tilemap", doc: "Tiles in folders of your own: dir/z/x/y.ext (what a tile tool writes; \"pbf\" for vector tiles).")).overloads.add Overload(params: @[Param(name: "dir", typ: "string", default: "", kind: kStr), Param(name: "ext", typ: "string", default: "\"png\"", kind: kStr), Param(name: "maxZoom", typ: "int", default: "18", kind: kInt), Param(name: "attribution", typ: "string", default: "\"\"", kind: kStr)], returns: "TileSource", call: c391_folderSource)
  controls.mgetOrPut("tileJsonSource", Control(name: "tileJsonSource", module: "tilemap", doc: "A TileJSON's tiles (OpenFreeMap: \"https://tiles.openfreemap.org/planet\"; a tile server's). Waits for it.")).overloads.add Overload(params: @[Param(name: "url", typ: "string", default: "", kind: kStr), Param(name: "style", typ: "", default: "classicStyle()", kind: kNone)], returns: "TileSource", call: c392_tileJsonSource)
  controls.mgetOrPut("mapKitPage", Control(name: "mapKitPage", module: "tilemap", doc: "A page with Apple's map (MapKit JS) for webView: token a MapKit JS token of your Apple developer account; the map around lat, lon, zoomMeters across.")).overloads.add Overload(params: @[Param(name: "token", typ: "string", default: "", kind: kStr), Param(name: "lat", typ: "float", default: "", kind: kFloat), Param(name: "lon", typ: "float", default: "", kind: kFloat), Param(name: "zoomMeters", typ: "float", default: "5000.0", kind: kFloat)], returns: "string", call: c393_mapKitPage)
  controls.mgetOrPut("googleMapsPage", Control(name: "googleMapsPage", module: "tilemap", doc: "A page with Google's own JavaScript map for webView (a key with the Maps JavaScript API enabled).")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "", kind: kStr), Param(name: "lat", typ: "float", default: "", kind: kFloat), Param(name: "lon", typ: "float", default: "", kind: kFloat), Param(name: "zoom", typ: "int", default: "12", kind: kInt)], returns: "string", call: c394_googleMapsPage)
  controls.mgetOrPut("quadkey", Control(name: "quadkey", module: "tilemap", doc: "A tile's quadkey (Bing's and Azure's numbering).")).overloads.add Overload(params: @[Param(name: "z", typ: "int", default: "", kind: kInt), Param(name: "x", typ: "int", default: "", kind: kInt), Param(name: "y", typ: "int", default: "", kind: kInt)], returns: "string", call: c395_quadkey)
  controls.mgetOrPut("tileUrl", Control(name: "tileUrl", module: "tilemap", doc: "The address of tile z/x/y of s (dense: the one with twice the pixels).")).overloads.add Overload(params: @[Param(name: "s", typ: "TileSource", default: "", kind: kNone), Param(name: "z", typ: "int", default: "", kind: kInt), Param(name: "x", typ: "int", default: "", kind: kInt), Param(name: "y", typ: "int", default: "", kind: kInt), Param(name: "dense", typ: "bool", default: "false", kind: kBool)], returns: "string", call: nil)
  controls.mgetOrPut("loadingTiles", Control(name: "loadingTiles", module: "tilemap", doc: "Tiles asked for and not yet come.")).overloads.add Overload(params: @[], returns: "int", call: c397_loadingTiles)
  controls.mgetOrPut("clearTileCache", Control(name: "clearTileCache", module: "tilemap", doc: "Forgets the tiles kept in memory (and on the disk with disk).")).overloads.add Overload(params: @[Param(name: "disk", typ: "bool", default: "false", kind: kBool)], returns: "", call: c398_clearTileCache)
  controls.mgetOrPut("fitBounds", Control(name: "fitBounds", module: "tilemap", doc: "Shows the area from south, west to north, east (degrees) as large as the map shows it (done when it is next drawn).")).overloads.add Overload(params: @[Param(name: "m", typ: "var TileMapState", default: "", kind: kNone), Param(name: "south", typ: "float", default: "", kind: kFloat), Param(name: "west", typ: "float", default: "", kind: kFloat), Param(name: "north", typ: "float", default: "", kind: kFloat), Param(name: "east", typ: "float", default: "", kind: kFloat)], returns: "", call: nil)
  controls.mgetOrPut("fitPoints", Control(name: "fitPoints", module: "tilemap", doc: "Shows all of points (a route, the markers).")).overloads.add Overload(params: @[Param(name: "m", typ: "var TileMapState", default: "", kind: kNone), Param(name: "points", typ: "openArray[LatLon]", default: "", kind: kNone)], returns: "", call: nil)
  controls.mgetOrPut("centerOn", Control(name: "centerOn", module: "tilemap", doc: "Moves the view to lat, lon (and zoom when given).")).overloads.add Overload(params: @[Param(name: "m", typ: "var TileMapState", default: "", kind: kNone), Param(name: "lat", typ: "float", default: "", kind: kFloat), Param(name: "lon", typ: "float", default: "", kind: kFloat), Param(name: "zoom", typ: "float", default: "-1.0", kind: kFloat)], returns: "", call: nil)
  controls.mgetOrPut("metersPerPixel", Control(name: "metersPerPixel", module: "tilemap", doc: "How many meters a design pixel covers at the middle of the view.")).overloads.add Overload(params: @[Param(name: "m", typ: "TileMapState", default: "", kind: kNone)], returns: "float", call: nil)
  controls.mgetOrPut("tileMap", Control(name: "tileMap", module: "tilemap", doc: "The map of src, height pixels high (-1: the room left), as wide as the space it is in; overlays drawn over it (labels, sea marks, rain), shapes and markers over them. Drag to move it; the wheel, a double click, two fingers, + / - (with the focus) or its buttons zoom; arrows move it. clicked reports a click or a tap and where.")).overloads.add Overload(params: @[Param(name: "m", typ: "var TileMapState", default: "", kind: kNone), Param(name: "src", typ: "TileSource", default: "", kind: kNone), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "markers", typ: "openArray[MapMarker]", default: "[]", kind: kNone), Param(name: "shapes", typ: "openArray[MapShape]", default: "[]", kind: kNone), Param(name: "overlays", typ: "openArray[TileSource]", default: "[]", kind: kNone), Param(name: "showScale", typ: "bool", default: "true", kind: kBool), Param(name: "showZoom", typ: "bool", default: "true", kind: kBool), Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "TileMapEvent", call: nil)
  controls.mgetOrPut("mapPointOf", Control(name: "mapPointOf", module: "tilemap", doc: "Where p is drawn in the last tileMap of m (logical pixels).")).overloads.add Overload(params: @[Param(name: "m", typ: "TileMapState", default: "", kind: kNone), Param(name: "src", typ: "TileSource", default: "", kind: kNone), Param(name: "p", typ: "LatLon", default: "", kind: kNone)], returns: "tuple[x, y: int]", call: nil)
  controls.mgetOrPut("tilesIn", Control(name: "tilesIn", module: "tilemap", doc: "How many tiles an area has from minZoom to maxZoom.")).overloads.add Overload(params: @[Param(name: "south", typ: "float", default: "", kind: kFloat), Param(name: "west", typ: "float", default: "", kind: kFloat), Param(name: "north", typ: "float", default: "", kind: kFloat), Param(name: "east", typ: "float", default: "", kind: kFloat), Param(name: "minZoom", typ: "int", default: "", kind: kInt), Param(name: "maxZoom", typ: "int", default: "", kind: kInt)], returns: "int", call: c405_tilesIn)
  controls.mgetOrPut("keepArea", Control(name: "keepArea", module: "tilemap", doc: "Fetches an area's tiles into the disk cache, for a map that works without the network (a car, a kiosk); \"\" when it was asked, else why not. OpenStreetMap's own servers do not allow it (their rule): take a service that does, or a .pmtiles file of the area.")).overloads.add Overload(params: @[Param(name: "src", typ: "TileSource", default: "", kind: kNone), Param(name: "south", typ: "float", default: "", kind: kFloat), Param(name: "west", typ: "float", default: "", kind: kFloat), Param(name: "north", typ: "float", default: "", kind: kFloat), Param(name: "east", typ: "float", default: "", kind: kFloat), Param(name: "minZoom", typ: "int", default: "", kind: kInt), Param(name: "maxZoom", typ: "int", default: "", kind: kInt)], returns: "string", call: nil)
  controls.mgetOrPut("routeShape", Control(name: "routeShape", module: "tilemap", doc: "A route found by geo.route as a line on the map.")).overloads.add Overload(params: @[Param(name: "r", typ: "Route", default: "", kind: kNone), Param(name: "color", typ: "Color", default: "Color()", kind: kColor), Param(name: "width", typ: "float", default: "5.0", kind: kFloat), Param(name: "label", typ: "string", default: "\"\"", kind: kStr)], returns: "MapShape", call: nil)
  controls.mgetOrPut("geoJsonShapes", Control(name: "geoJsonShapes", module: "tilemap", doc: "The lines and areas of a GeoJSON text as shapes, its points as markers.")).overloads.add Overload(params: @[Param(name: "text", typ: "string", default: "", kind: kStr), Param(name: "color", typ: "Color", default: "Color()", kind: kColor), Param(name: "fill", typ: "Color", default: "Color()", kind: kColor)], returns: "tuple[shapes: seq[MapShape], markers: seq[MapMarker]]", call: c408_geoJsonShapes)
  controls.mgetOrPut("readGltf", Control(name: "readGltf", module: "gltf", doc: "A model from glTF's JSON text, its binary chunk (.glb) and the folder its files are in; GltfError when it cannot be read.")).overloads.add Overload(params: @[Param(name: "json", typ: "string", default: "", kind: kStr), Param(name: "bin", typ: "string", default: "\"\"", kind: kStr), Param(name: "baseDir", typ: "string", default: "\"\"", kind: kStr)], returns: "Scene3", call: c409_readGltf)
  controls.mgetOrPut("readGlb", Control(name: "readGlb", module: "gltf", doc: "A model from the bytes of a .glb file.")).overloads.add Overload(params: @[Param(name: "data", typ: "string", default: "", kind: kStr), Param(name: "baseDir", typ: "string", default: "\"\"", kind: kStr)], returns: "Scene3", call: c410_readGlb)
  controls.mgetOrPut("loadGltf", Control(name: "loadGltf", module: "gltf", doc: "The model in path (.glb or .gltf); GltfError when it cannot be read, IOError when the file cannot.")).overloads.add Overload(params: @[Param(name: "path", typ: "string", default: "", kind: kStr)], returns: "Scene3", call: c411_loadGltf)
  controls.mgetOrPut("blendToGlb", Control(name: "blendToGlb", module: "gltf", doc: "Turns a .blend into a .glb with Blender (in the background, its clips with it); the .glb's path, \"\" when Blender is not there or could not. glb \"\": beside the .blend, made again only when the .blend is newer.")).overloads.add Overload(params: @[Param(name: "blend", typ: "string", default: "", kind: kStr), Param(name: "glb", typ: "string", default: "\"\"", kind: kStr)], returns: "string", call: c412_blendToGlb)
  controls.mgetOrPut("loadModel3", Control(name: "loadModel3", module: "gltf", doc: "Any model as a scene: .glb, .gltf, .blend (through Blender), and .obj, .stl (one mesh, centered, 2 units across).")).overloads.add Overload(params: @[Param(name: "path", typ: "string", default: "", kind: kStr)], returns: "Scene3", call: c413_loadModel3)
  controls.mgetOrPut("toGlb", Control(name: "toGlb", module: "gltf", doc: "The scene as a .glb: its meshes, their materials' colors (no pictures), its nodes and clips.")).overloads.add Overload(params: @[Param(name: "scene", typ: "Scene3", default: "", kind: kNone)], returns: "string", call: nil)
  controls.mgetOrPut("cameras", Control(name: "cameras", module: "capture", doc: "The cameras the system has.")).overloads.add Overload(params: @[], returns: "seq[CameraInfo]", call: c415_cameras)
  controls.mgetOrPut("cameraView", Control(name: "cameraView", module: "capture", doc: "The camera's live picture, as large as fits, height pixels high (-1: the room left). camera: one of cameras() (\"\"): the first, or one that looks facing). mirror: shown as in a mirror (a front camera). The camera is on while the view is drawn, and off once it is not.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "\"\"", kind: kStr), Param(name: "camera", typ: "string", default: "\"\"", kind: kStr), Param(name: "facing", typ: "CameraFacing", default: "cfAny", kind: kEnum), Param(name: "height", typ: "int", default: "-1", kind: kInt), Param(name: "w", typ: "int", default: "0", kind: kInt), Param(name: "mirror", typ: "bool", default: "false", kind: kBool)], returns: "CameraEvent", call: c416_cameraView)
  controls.mgetOrPut("cameraPhoto", Control(name: "cameraPhoto", module: "capture", doc: "Saves the camera's next picture to path (JPEG; PNG by its extension); CameraEvent.photo says when it is there.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "\"\"", kind: kStr), Param(name: "path", typ: "string", default: "", kind: kStr)], returns: "", call: c417_cameraPhoto)
  controls.mgetOrPut("cameraFrame", Control(name: "cameraFrame", module: "capture", doc: "The camera's latest picture (nil: none yet), to read it: a barcode, a face. Not to be changed.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "Bitmap", call: c418_cameraFrame)
  controls.mgetOrPut("cameraRecord", Control(name: "cameraRecord", module: "capture", doc: "Records the camera into the video path (MP4, H.264, 30 pictures a second, by retroui/media's writer) until cameraStop; false when the camera shows nothing yet or no writer is there.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "\"\"", kind: kStr), Param(name: "path", typ: "string", default: "", kind: kStr)], returns: "bool", call: c419_cameraRecord)
  controls.mgetOrPut("cameraStop", Control(name: "cameraStop", module: "capture", doc: "Ends the recording cameraRecord started; CameraEvent.saved says when the video is written.")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "", call: c420_cameraStop)
  controls.mgetOrPut("cameraClose", Control(name: "cameraClose", module: "capture", doc: "Lets the camera go now (it goes by itself once its view is not drawn).")).overloads.add Overload(params: @[Param(name: "key", typ: "string", default: "\"\"", kind: kStr)], returns: "", call: c421_cameraClose)
  controls.mgetOrPut("recordSound", Control(name: "recordSound", module: "capture", doc: "Records the microphone into path until stopRecordingSound: a WAV file (16-bit, 44.1 kHz, mono) on Linux and Windows; on Android, iOS and macOS the system's recorder writes it (AAC in an .m4a by its extension, else WAV). False when there is no microphone (or the user said no).")).overloads.add Overload(params: @[Param(name: "path", typ: "string", default: "", kind: kStr)], returns: "bool", call: c422_recordSound)
  controls.mgetOrPut("stopRecordingSound", Control(name: "stopRecordingSound", module: "capture", doc: "Ends the recording recordSound started and writes it; how long it is in milliseconds (0: not known, -1: it could not be written).")).overloads.add Overload(params: @[], returns: "int", call: c423_stopRecordingSound)
  controls.mgetOrPut("recordingSound", Control(name: "recordingSound", module: "capture", doc: "The microphone records.")).overloads.add Overload(params: @[], returns: "bool", call: c424_recordingSound)
  controls.mgetOrPut("soundLevel", Control(name: "soundLevel", module: "capture", doc: "How loud the microphone is now, 0..1 (a meter; 0 when not recording).")).overloads.add Overload(params: @[], returns: "float", call: c425_soundLevel)
  controls.mgetOrPut("mediaSessionBusName", Control(name: "mediaSessionBusName", module: "mediasession", doc: "The bus name the app's controls have on D-Bus (\"\" before setNowPlaying): playerctl -p NAME, tests.")).overloads.add Overload(params: @[], returns: "string", call: c426_mediaSessionBusName)
  controls.mgetOrPut("setNowPlaying", Control(name: "setNowPlaying", module: "mediasession", doc: "What the app plays, for the system's media controls; the controls' presses come in mediaKeys. Call it when it changes, or every frame: the system is told only what changed (a position that keeps time with the playing is not news).")).overloads.add Overload(params: @[Param(name: "np", typ: "NowPlaying", default: "", kind: kNone)], returns: "", call: nil)
  controls.mgetOrPut("mediaKeys", Control(name: "mediaKeys", module: "mediasession", doc: "What the system's media controls asked since the last frame (the lock screen, the media keys of a keyboard or a headset, the desktop's media applet). Empty (and nothing made) when nothing was pressed.")).overloads.add Overload(params: @[], returns: "seq[MediaKeyEvent]", call: c428_mediaKeys)
  blocks.mgetOrPut("group", @[]).add Block(name: "group", module: "widgets", doc: "A group box: a frame with a title around body.", params: @[Param(name: "title", typ: "string", default: "", kind: kStr)], bodies: 1, run: b0_group)
  blocks.mgetOrPut("tabs", @[]).add Block(name: "tabs", module: "widgets", doc: "Tabs bound to sel; draw the page for sel in body.", params: @[Param(name: "sel", typ: "var int", default: "", kind: kVInt), Param(name: "labels", typ: "openArray[string]", default: "", kind: kStrs)], bodies: 1, run: b1_tabs)
  blocks.mgetOrPut("tabs", @[]).add Block(name: "tabs", module: "widgets", doc: "Tabs whose page keeps the height of the tallest one shown so far (property sheets, settings dialogs).", params: @[Param(name: "sel", typ: "var int", default: "", kind: kVInt), Param(name: "labels", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "sameHeight", typ: "bool", default: "", kind: kBool)], bodies: 1, run: b2_tabs)
  blocks.mgetOrPut("scrollPanel", @[]).add Block(name: "scrollPanel", module: "widgets", doc: "A framed area of height pixels whose content scrolls (-1: down to the bottom).", params: @[Param(name: "height", typ: "int", default: "", kind: kInt)], bodies: 1, run: b3_scrollPanel)
  blocks.mgetOrPut("panel", @[]).add Block(name: "panel", module: "widgets", doc: "A framed white area down to the bottom, its content Pad in from every edge, scrolling (with a scroll bar) only when it is taller: the page of an app beside a tree or a list, as in File Manager.", params: @[], bodies: 1, run: b4_panel)
  blocks.mgetOrPut("panel", @[]).add Block(name: "panel", module: "widgets", doc: "panel height pixels high.", params: @[Param(name: "height", typ: "int", default: "", kind: kInt)], bodies: 1, run: b5_panel)
  blocks.mgetOrPut("pane", @[]).add Block(name: "pane", module: "widgets", doc: "An area height pixels high on the dialog's face (no frame) whose content scrolls when it is taller: the pages of a dialog that keeps its size (Preferences).", params: @[Param(name: "height", typ: "int", default: "", kind: kInt)], bodies: 1, run: b6_pane)
  blocks.mgetOrPut("menubar", @[]).add Block(name: "menubar", module: "widgets", doc: "The menu bar at the top of the window; call it first.", params: @[], bodies: 1, run: b7_menubar)
  blocks.mgetOrPut("menu", @[]).add Block(name: "menu", module: "widgets", doc: "A menu of the menu bar; body (its items) runs only while it is open.", params: @[Param(name: "title", typ: "string", default: "", kind: kStr)], bodies: 1, run: b8_menu)
  blocks.mgetOrPut("submenu", @[]).add Block(name: "submenu", module: "widgets", doc: "An item that opens a menu of its own (one level deep).", params: @[Param(name: "label", typ: "string", default: "", kind: kStr)], bodies: 1, run: b9_submenu)
  blocks.mgetOrPut("contextMenu", @[]).add Block(name: "contextMenu", module: "widgets", doc: "A menu that a right click (a long press on a touch screen) on the widget drawn last opens.", params: @[], bodies: 1, run: b10_contextMenu)
  blocks.mgetOrPut("popupMenu", @[]).add Block(name: "popupMenu", module: "widgets", doc: "The menu opened with openPopupMenu(key, x, y): menuItems in body; it closes when one is chosen, on Esc or a click outside.", params: @[Param(name: "key", typ: "string", default: "", kind: kStr)], bodies: 1, run: b11_popupMenu)
  blocks.mgetOrPut("toolbar", @[]).add Block(name: "toolbar", module: "widgets", doc: "A bar of tool buttons below the menu bar.", params: @[], bodies: 1, run: b12_toolbar)
  blocks.mgetOrPut("statusRow", @[]).add Block(name: "statusRow", module: "widgets", doc: "A status bar with controls in it (an editable zoom field, a menu arrow, texts), laid out by body -- usually one row. Separate the parts with statusSep. (statusbar is the one of texts only.)", params: @[], bodies: 1, run: b13_statusRow)
  blocks.mgetOrPut("dialog", @[]).add Block(name: "dialog", module: "widgets", doc: "A modal dialog, width pixels wide, shown while open is true. Esc and the control-menu box close it; drag it by its title. Work that takes a while in it (its OK) is named by its title in the box that comes up.", params: @[Param(name: "open", typ: "var bool", default: "", kind: kVBool), Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "width", typ: "int", default: "", kind: kInt)], bodies: 1, run: b14_dialog)
  blocks.mgetOrPut("window", @[]).add Block(name: "window", module: "widgets", doc: "A window of the system's own besides the app's, w x h design pixels when it opens, shown while open is true: a tool palette, a second view for another monitor, a preview. It is laid out and drawn as the app's window is (menus, dialogs, tool bars in it are its own), at the place in the frame the app draws it; its close button sets open to false; it closes when it is no longer drawn. Where the syste", params: @[Param(name: "open", typ: "var bool", default: "", kind: kVBool), Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "w", typ: "int", default: "", kind: kInt), Param(name: "h", typ: "int", default: "", kind: kInt)], bodies: 1, run: b15_window)
  blocks.mgetOrPut("tree", @[]).add Block(name: "tree", module: "business", doc: "A tree view; sel is the path (\"Parent/Child\") of the selected node. Inside, branch and leaf make the nodes.", params: @[Param(name: "sel", typ: "var string", default: "", kind: kVStr), Param(name: "rows", typ: "int", default: "", kind: kInt)], bodies: 1, run: b16_tree)
  blocks.mgetOrPut("branch", @[]).add Block(name: "branch", module: "business", doc: "A node with children, shown in body while expanded.", params: @[Param(name: "label", typ: "string", default: "", kind: kStr), Param(name: "expanded", typ: "var bool", default: "", kind: kVBool)], bodies: 1, run: b17_branch)
  blocks.mgetOrPut("split", @[]).add Block(name: "split", module: "business", doc: "Two panes side by side; drag the bar between them (pos is its x).split(listW, 300): listbox items, sel, rows = -1 do: editArea text, lines = -1", params: @[Param(name: "pos", typ: "var int", default: "", kind: kVInt), Param(name: "height", typ: "int", default: "", kind: kInt)], bodies: 2, run: b19_split)
  blocks.mgetOrPut("vsplit", @[]).add Block(name: "vsplit", module: "business", doc: "Two panes above each other; drag the bar between them.", params: @[Param(name: "pos", typ: "var int", default: "", kind: kVInt), Param(name: "height", typ: "int", default: "", kind: kInt)], bodies: 2, run: b20_vsplit)
  blocks.mgetOrPut("sidePane", @[]).add Block(name: "sidePane", module: "business", doc: "main with a pane beside it (paneW wide, in design pixels) when there is room, else under it (paneH tall): the details pane of an explorer, the inspector of an editor. Dragging the bar between them changes paneW or paneH (keep them in the app's settings).sidePane(showDetails, detailsW, detailsH): listbox items, sel, rows = -1 do: factList(details(items[sel]))", params: @[Param(name: "show", typ: "bool", default: "", kind: kBool), Param(name: "paneW", typ: "var int", default: "", kind: kVInt), Param(name: "paneH", typ: "var int", default: "", kind: kVInt)], bodies: 2, run: b21_sidePane)
  blocks.mgetOrPut("field", @[]).add Block(name: "field", module: "business", doc: "A form row: caption in a label column, then the control(s). In a narrow space (a phone) the caption goes above the control instead.", params: @[Param(name: "caption", typ: "string", default: "", kind: kStr)], bodies: 1, run: b22_field)
  blocks.mgetOrPut("form", @[]).add Block(name: "form", module: "business", doc: "field rows with a label column labelWidth design pixels wide, or, with 0, as wide as the widest caption.", params: @[Param(name: "labelWidth", typ: "int", default: "", kind: kInt)], bodies: 1, run: b23_form)
  blocks.mgetOrPut("expander", @[]).add Block(name: "expander", module: "extras", doc: "A section that opens and closes (click its header, or Left/Right).", params: @[Param(name: "label", typ: "string", default: "", kind: kStr), Param(name: "open", typ: "var bool", default: "", kind: kVBool)], bodies: 1, run: b24_expander)
  blocks.mgetOrPut("card", @[]).add Block(name: "card", module: "extras", doc: "A panel drawn as a 3.1 group box (its title set into the top line); in an adaptive row, cards make a dashboard that reflows from one column (phone) to several.adaptive(260): card \"Sales\": label \"12,400\" card \"Orders\": label \"318\"", params: @[Param(name: "title", typ: "string", default: "", kind: kStr)], bodies: 1, run: b25_card)
  blocks.mgetOrPut("wizard", @[]).add Block(name: "wizard", module: "records", doc: "A dialog of steps (their names at the left, Back, Next >, Finish and Cancel at the bottom); body draws the page of step (a case step). Call stepDone(false) in a page whose fields are not filled in yet. Returns what was pressed: waFinish (then open is false), waCancel (also Esc), waNext, waBack (step already moved).", params: @[Param(name: "open", typ: "var bool", default: "", kind: kVBool), Param(name: "title", typ: "string", default: "", kind: kStr), Param(name: "step", typ: "var int", default: "", kind: kVInt), Param(name: "steps", typ: "openArray[string]", default: "", kind: kStrs), Param(name: "width", typ: "int", default: "", kind: kInt)], bodies: 1, run: b26_wizard)
  blocks.mgetOrPut("mdiArea", @[]).add Block(name: "mdiArea", module: "desktop", doc: "A workspace for mdiWindows: mdiArea(-1): mdiWindow(w1): ....", params: @[Param(name: "height", typ: "int", default: "", kind: kInt)], bodies: 1, run: b27_mdiArea)
  blocks.mgetOrPut("mdiArea", @[]).add Block(name: "mdiArea", module: "desktop", doc: "An area with its own windows when there are several (key names it for mdiCascade, mdiTile and mdiWindowMenu).", params: @[Param(name: "height", typ: "int", default: "", kind: kInt), Param(name: "key", typ: "string", default: "", kind: kStr)], bodies: 1, run: b28_mdiArea)
  blocks.mgetOrPut("kpiRow", @[]).add Block(name: "kpiRow", module: "planning", doc: "Tiles side by side, as many as fit (each at least minW design pixels wide), wrapping onto more lines on phones.", params: @[Param(name: "minW", typ: "int", default: "", kind: kInt)], bodies: 1, run: b30_kpiRow)
  blocks.mgetOrPut("kpiRow", @[]).add Block(name: "kpiRow", module: "planning", doc: "Tiles side by side, as many as fit, wrapping onto more lines on phones.", params: @[], bodies: 1, run: b31_kpiRow)
  blocks.mgetOrPut("canvas2d", @[]).add Block(name: "canvas2d", module: "canvas2d", doc: "A canvas w x h (logical pixels; w <= 0: the room's width) in the layout, its context named ctx in body:canvas2d(ctx, 300, 200): ctx.fillStyle = \"navy\" ctx.fillRect(10, 10, 100, 50) if ctx.input.clicked: echo \"clicked at \", ctx.input.x, \", \", ctx.input.y", params: @[Param(name: "ctx", typ: "untyped", default: "", kind: kNone), Param(name: "w", typ: "int", default: "", kind: kInt), Param(name: "h", typ: "int", default: "", kind: kInt)], bodies: 1, run: b32_canvas2d)
  blocks.mgetOrPut("withId", @[]).add Block(name: "withId", module: "core", doc: "Give the widgets in body their own id scope (e.g. per list row).", params: @[Param(name: "key", typ: "typed", default: "", kind: kStr)], bodies: 1, run: b34_withId)
  blocks.mgetOrPut("row", @[]).add Block(name: "row", module: "core", doc: "Widgets side by side, each at its natural width (wrapping when full).", params: @[], bodies: 1, run: b35_row)
  blocks.mgetOrPut("row", @[]).add Block(name: "row", module: "core", doc: "Widgets side by side in columns: a width > 0 is fixed, -1 shares the rest, 0 is the widget's own width. More widgets than widths wrap. The widths are design pixels, scaled as everything is: write row([80, -1]), not row([dp(80), -1]) (that scales twice: the columns too wide on a tablet or a phone); widths measured on the screen (a text's width) go to rowPx.", params: @[Param(name: "widths", typ: "openArray[int]", default: "", kind: kInts)], bodies: 1, run: b36_row)
  blocks.mgetOrPut("rowPx", @[]).add Block(name: "rowPx", module: "core", doc: "row with widths in logical pixels, as they are (measured on the screen: textWidth, dp): not scaled again.", params: @[Param(name: "widths", typ: "openArray[int]", default: "", kind: kInts)], bodies: 1, run: b37_rowPx)
  blocks.mgetOrPut("col", @[]).add Block(name: "col", module: "core", doc: "Widgets stacked top to bottom (a column inside a row).", params: @[], bodies: 1, run: b38_col)
  blocks.mgetOrPut("col", @[]).add Block(name: "col", module: "core", doc: "A column width design pixels wide.", params: @[Param(name: "width", typ: "int", default: "", kind: kInt)], bodies: 1, run: b39_col)
  blocks.mgetOrPut("adaptive", @[]).add Block(name: "adaptive", module: "core", doc: "As many equal columns as fit, each at least minW design pixels wide; the widgets (groups, cards) of body flow through them and wrap. One column on a phone, three on a desktop -- with the same code.", params: @[Param(name: "minW", typ: "int", default: "", kind: kInt)], bodies: 1, run: b40_adaptive)
  enumValues["Align"] = @["alLeft", "alCenter", "alRight"]
  enumValues["BannerKind"] = @["bkInfo", "bkSuccess", "bkWarning", "bkError"]
  enumValues["ButtonLook"] = @["blDefault", "blIconOnly", "blTextOnly", "blTextBelow", "blTextBeside"]
  enumValues["CameraFacing"] = @["cfAny", "cfBack", "cfFront", "cfExternal"]
  enumValues["CellKind"] = @["ckText", "ckNumber", "ckCheck", "ckColor", "ckProgress", "ckChoice", "ckButton", "ckLink", "ckIcon", "ckCustom"]
  enumValues["ChartKind"] = @["chBar", "chBarH", "chStacked", "chStacked100", "chLine", "chArea", "chStackedArea", "chCombo", "chPie", "chDonut", "chScatter", "chBubble", "chWaterfall", "chFunnel", "chGauge", "chCandle", "chHistogram", "chHeatmap", "chRadar", "chTreemap", "chBullet"]
  enumValues["FileView"] = @["fvDetails", "fvIcons", "fvTiles", "fvSmallIcons", "fvColumns"]
  enumValues["HeaderSide"] = @["hsLeft", "hsCenter", "hsRight"]
  enumValues["KeyCode"] = @["KeyNone", "KeyA", "KeyB", "KeyC", "KeyD", "KeyE", "KeyF", "KeyG", "KeyH", "KeyI", "KeyJ", "KeyK", "KeyL", "KeyM", "KeyN", "KeyO", "KeyP", "KeyQ", "KeyR", "KeyS", "KeyT", "KeyU", "KeyV", "KeyW", "KeyX", "KeyY", "KeyZ", "Key0", "Key1", "Key2", "Key3", "Key4", "Key5", "Key6", "Key7", "Key8", "Key9", "KeyF1", "KeyF2", "KeyF3", "KeyF4", "KeyF5", "KeyF6", "KeyF7", "KeyF8", "KeyF9", "KeyF10", "KeyF11", "KeyF12", "KeyEnter", "KeySpace", "KeyEsc", "KeyTab", "KeyBackspace", "KeyDelete", "KeyInsert", "KeyLeft", "KeyRight", "KeyUp", "KeyDown", "KeyPageUp", "KeyPageDown", "KeyHome", "KeyEnd", "KeyCapslock", "KeyComma", "KeyPeriod", "KeySlash", "KeyMinus", "KeyEqual", "KeyPlus", "KeyLeftBracket", "KeyRightBracket", "KeySemicolon", "KeyQuote", "KeyBackslash", "KeyBackquote", "KeyMenu"]
  enumValues["Modifier"] = @["ShiftPressed", "CtrlPressed", "AltPressed", "GuiPressed"]
  enumValues["MsgIcon"] = @["miNone", "miInfo", "miQuestion", "miWarning", "miStop"]
  enumValues["RangePreset"] = @["rpCustom", "rpToday", "rpYesterday", "rpThisWeek", "rpLastWeek", "rpThisMonth", "rpLastMonth", "rpThisQuarter", "rpLastQuarter", "rpThisYear", "rpLastYear", "rpLast7", "rpLast30", "rpLast90"]
  enumValues["TabLook"] = @["tlDocument", "tlPalette"]
  enumValues["UiSound"] = @["usClick", "usNotify", "usSuccess", "usWarning", "usError"]
  enumValues["Waveform"] = @["wSine", "wSquare", "wTriangle", "wSaw"]
  enumValues["WebPermission"] = @["wpCamera", "wpMicrophone", "wpLocation", "wpNotifications"]
  stringConsts["RetroCredit"] = RetroCredit
  stringConsts["RetroDeveloper"] = RetroDeveloper
  stringConsts["RetroEmail"] = RetroEmail
  stringConsts["RetroFontCredit"] = RetroFontCredit
  stringConsts["RetroHandle"] = RetroHandle
  stringConsts["RetroVersion"] = RetroVersion
  stringConsts["RetroWebsite"] = RetroWebsite
  stringConsts["TagClose"] = TagClose
  stringConsts["TagOpen"] = TagOpen
  stringConsts["appFontKey"] = appFontKey
  stringConsts["nfAlert"] = nfAlert
  stringConsts["nfAlertCircle"] = nfAlertCircle
  stringConsts["nfAlignCenter"] = nfAlignCenter
  stringConsts["nfAlignJustify"] = nfAlignJustify
  stringConsts["nfAlignLeft"] = nfAlignLeft
  stringConsts["nfAlignRight"] = nfAlignRight
  stringConsts["nfAndroid"] = nfAndroid
  stringConsts["nfAngleDoubleLeft"] = nfAngleDoubleLeft
  stringConsts["nfAngleDoubleRight"] = nfAngleDoubleRight
  stringConsts["nfApple"] = nfApple
  stringConsts["nfApplication"] = nfApplication
  stringConsts["nfArchive"] = nfArchive
  stringConsts["nfAreaChart"] = nfAreaChart
  stringConsts["nfArrowDown"] = nfArrowDown
  stringConsts["nfArrowLeft"] = nfArrowLeft
  stringConsts["nfArrowRight"] = nfArrowRight
  stringConsts["nfArrowUp"] = nfArrowUp
  stringConsts["nfAt"] = nfAt
  stringConsts["nfBackward"] = nfBackward
  stringConsts["nfBan"] = nfBan
  stringConsts["nfBarChart"] = nfBarChart
  stringConsts["nfBars"] = nfBars
  stringConsts["nfBattery"] = nfBattery
  stringConsts["nfBell"] = nfBell
  stringConsts["nfBellSlash"] = nfBellSlash
  stringConsts["nfBluetooth"] = nfBluetooth
  stringConsts["nfBold"] = nfBold
  stringConsts["nfBolt"] = nfBolt
  stringConsts["nfBook"] = nfBook
  stringConsts["nfBookmark"] = nfBookmark
  stringConsts["nfBox"] = nfBox
  stringConsts["nfBriefcase"] = nfBriefcase
  stringConsts["nfBug"] = nfBug
  stringConsts["nfBuilding"] = nfBuilding
  stringConsts["nfC"] = nfC
  stringConsts["nfCalendar"] = nfCalendar
  stringConsts["nfCalendarCheck"] = nfCalendarCheck
  stringConsts["nfCamera"] = nfCamera
  stringConsts["nfCancel"] = nfCancel
  stringConsts["nfCaretDown"] = nfCaretDown
  stringConsts["nfCaretLeft"] = nfCaretLeft
  stringConsts["nfCaretRight"] = nfCaretRight
  stringConsts["nfCaretUp"] = nfCaretUp
  stringConsts["nfCellphone"] = nfCellphone
  stringConsts["nfCheck"] = nfCheck
  stringConsts["nfCheckCircle"] = nfCheckCircle
  stringConsts["nfCheckSquare"] = nfCheckSquare
  stringConsts["nfCheckboxBlank"] = nfCheckboxBlank
  stringConsts["nfCheckboxMarked"] = nfCheckboxMarked
  stringConsts["nfCheckboxMultiple"] = nfCheckboxMultiple
  stringConsts["nfChevronDown"] = nfChevronDown
  stringConsts["nfChevronLeft"] = nfChevronLeft
  stringConsts["nfChevronRight"] = nfChevronRight
  stringConsts["nfChevronUp"] = nfChevronUp
  stringConsts["nfCircle"] = nfCircle
  stringConsts["nfCircleNotch"] = nfCircleNotch
  stringConsts["nfCircleO"] = nfCircleO
  stringConsts["nfClipboard"] = nfClipboard
  stringConsts["nfClock"] = nfClock
  stringConsts["nfCloseCircle"] = nfCloseCircle
  stringConsts["nfCloud"] = nfCloud
  stringConsts["nfCloudDownload"] = nfCloudDownload
  stringConsts["nfCloudUpload"] = nfCloudUpload
  stringConsts["nfCode"] = nfCode
  stringConsts["nfCog"] = nfCog
  stringConsts["nfCogs"] = nfCogs
  stringConsts["nfColumns"] = nfColumns
  stringConsts["nfComment"] = nfComment
  stringConsts["nfComments"] = nfComments
  stringConsts["nfCompass"] = nfCompass
  stringConsts["nfCompress"] = nfCompress
  stringConsts["nfConsole"] = nfConsole
  stringConsts["nfContentSave"] = nfContentSave
  stringConsts["nfCopy"] = nfCopy
  stringConsts["nfCpp"] = nfCpp
  stringConsts["nfCreditCard"] = nfCreditCard
  stringConsts["nfCrop"] = nfCrop
  stringConsts["nfCss"] = nfCss
  stringConsts["nfCube"] = nfCube
  stringConsts["nfCubes"] = nfCubes
  stringConsts["nfCut"] = nfCut
  stringConsts["nfDatabase"] = nfDatabase
  stringConsts["nfDesktop"] = nfDesktop
  stringConsts["nfDockLeft"] = nfDockLeft
  stringConsts["nfDotCircle"] = nfDotCircle
  stringConsts["nfDotsGrid"] = nfDotsGrid
  stringConsts["nfDownload"] = nfDownload
  stringConsts["nfEdit"] = nfEdit
  stringConsts["nfEllipsisH"] = nfEllipsisH
  stringConsts["nfEllipsisV"] = nfEllipsisV
  stringConsts["nfEnvelope"] = nfEnvelope
  stringConsts["nfEraser"] = nfEraser
  stringConsts["nfExclamation"] = nfExclamation
  stringConsts["nfExpand"] = nfExpand
  stringConsts["nfExternalLink"] = nfExternalLink
  stringConsts["nfEye"] = nfEye
  stringConsts["nfEyeSlash"] = nfEyeSlash
  stringConsts["nfFile"] = nfFile
  stringConsts["nfFileAudio"] = nfFileAudio
  stringConsts["nfFileCode"] = nfFileCode
  stringConsts["nfFileCog"] = nfFileCog
  stringConsts["nfFileCsv"] = nfFileCsv
  stringConsts["nfFileDocument"] = nfFileDocument
  stringConsts["nfFileExcel"] = nfFileExcel
  stringConsts["nfFileExport"] = nfFileExport
  stringConsts["nfFileFind"] = nfFileFind
  stringConsts["nfFileHidden"] = nfFileHidden
  stringConsts["nfFileImage"] = nfFileImage
  stringConsts["nfFileImport"] = nfFileImport
  stringConsts["nfFileMove"] = nfFileMove
  stringConsts["nfFilePdf"] = nfFilePdf
  stringConsts["nfFilePowerpoint"] = nfFilePowerpoint
  stringConsts["nfFileQuestion"] = nfFileQuestion
  stringConsts["nfFileRestore"] = nfFileRestore
  stringConsts["nfFileText"] = nfFileText
  stringConsts["nfFileTree"] = nfFileTree
  stringConsts["nfFileVideo"] = nfFileVideo
  stringConsts["nfFileWord"] = nfFileWord
  stringConsts["nfFileZip"] = nfFileZip
  stringConsts["nfFiles"] = nfFiles
  stringConsts["nfFilm"] = nfFilm
  stringConsts["nfFilter"] = nfFilter
  stringConsts["nfFire"] = nfFire
  stringConsts["nfFlag"] = nfFlag
  stringConsts["nfFolder"] = nfFolder
  stringConsts["nfFolderCog"] = nfFolderCog
  stringConsts["nfFolderDownload"] = nfFolderDownload
  stringConsts["nfFolderHome"] = nfFolderHome
  stringConsts["nfFolderImage"] = nfFolderImage
  stringConsts["nfFolderLock"] = nfFolderLock
  stringConsts["nfFolderMove"] = nfFolderMove
  stringConsts["nfFolderMusic"] = nfFolderMusic
  stringConsts["nfFolderNetwork"] = nfFolderNetwork
  stringConsts["nfFolderOpen"] = nfFolderOpen
  stringConsts["nfFolderPlus"] = nfFolderPlus
  stringConsts["nfFolderSearch"] = nfFolderSearch
  stringConsts["nfFolderStar"] = nfFolderStar
  stringConsts["nfFolderUpload"] = nfFolderUpload
  stringConsts["nfFolderZip"] = nfFolderZip
  stringConsts["nfFont"] = nfFont
  stringConsts["nfFontFile"] = nfFontFile
  stringConsts["nfFormatSize"] = nfFormatSize
  stringConsts["nfForward"] = nfForward
  stringConsts["nfGift"] = nfGift
  stringConsts["nfGit"] = nfGit
  stringConsts["nfGithub"] = nfGithub
  stringConsts["nfGlobe"] = nfGlobe
  stringConsts["nfGo"] = nfGo
  stringConsts["nfGraduation"] = nfGraduation
  stringConsts["nfGrip"] = nfGrip
  stringConsts["nfHarddisk"] = nfHarddisk
  stringConsts["nfHashtag"] = nfHashtag
  stringConsts["nfHdd"] = nfHdd
  stringConsts["nfHeader"] = nfHeader
  stringConsts["nfHeart"] = nfHeart
  stringConsts["nfHeartO"] = nfHeartO
  stringConsts["nfHelpCircle"] = nfHelpCircle
  stringConsts["nfHex"] = nfHex
  stringConsts["nfHistory"] = nfHistory
  stringConsts["nfHome"] = nfHome
  stringConsts["nfHourglass"] = nfHourglass
  stringConsts["nfHtml"] = nfHtml
  stringConsts["nfImage"] = nfImage
  stringConsts["nfImageMultiple"] = nfImageMultiple
  stringConsts["nfInbox"] = nfInbox
  stringConsts["nfIndent"] = nfIndent
  stringConsts["nfInfo"] = nfInfo
  stringConsts["nfInfoOutline"] = nfInfoOutline
  stringConsts["nfItalic"] = nfItalic
  stringConsts["nfJava"] = nfJava
  stringConsts["nfJavascript"] = nfJavascript
  stringConsts["nfJson"] = nfJson
  stringConsts["nfKey"] = nfKey
  stringConsts["nfKeyboard"] = nfKeyboard
  stringConsts["nfLanguage"] = nfLanguage
  stringConsts["nfLaptop"] = nfLaptop
  stringConsts["nfLeaf"] = nfLeaf
  stringConsts["nfLetterCase"] = nfLetterCase
  stringConsts["nfLevelUp"] = nfLevelUp
  stringConsts["nfLightbulb"] = nfLightbulb
  stringConsts["nfLineChart"] = nfLineChart
  stringConsts["nfLink"] = nfLink
  stringConsts["nfLinux"] = nfLinux
  stringConsts["nfList"] = nfList
  stringConsts["nfListOl"] = nfListOl
  stringConsts["nfListUl"] = nfListUl
  stringConsts["nfLoading"] = nfLoading
  stringConsts["nfLock"] = nfLock
  stringConsts["nfMagic"] = nfMagic
  stringConsts["nfMap"] = nfMap
  stringConsts["nfMapMarker"] = nfMapMarker
  stringConsts["nfMarkdown"] = nfMarkdown
  stringConsts["nfMicrochip"] = nfMicrochip
  stringConsts["nfMicrophone"] = nfMicrophone
  stringConsts["nfMinus"] = nfMinus
  stringConsts["nfMinusCircle"] = nfMinusCircle
  stringConsts["nfMobile"] = nfMobile
  stringConsts["nfMoney"] = nfMoney
  stringConsts["nfMoon"] = nfMoon
  stringConsts["nfMovie"] = nfMovie
  stringConsts["nfMusic"] = nfMusic
  stringConsts["nfMusicBox"] = nfMusicBox
  stringConsts["nfMusicNote"] = nfMusicNote
  stringConsts["nfNewspaper"] = nfNewspaper
  stringConsts["nfNim"] = nfNim
  stringConsts["nfOutdent"] = nfOutdent
  stringConsts["nfPackage"] = nfPackage
  stringConsts["nfPaintBrush"] = nfPaintBrush
  stringConsts["nfPalette"] = nfPalette
  stringConsts["nfPaperclip"] = nfPaperclip
  stringConsts["nfPaste"] = nfPaste
  stringConsts["nfPause"] = nfPause
  stringConsts["nfPencil"] = nfPencil
  stringConsts["nfPhone"] = nfPhone
  stringConsts["nfPieChart"] = nfPieChart
  stringConsts["nfPin"] = nfPin
  stringConsts["nfPlay"] = nfPlay
  stringConsts["nfPlug"] = nfPlug
  stringConsts["nfPlus"] = nfPlus
  stringConsts["nfPlusCircle"] = nfPlusCircle
  stringConsts["nfPower"] = nfPower
  stringConsts["nfPrint"] = nfPrint
  stringConsts["nfPython"] = nfPython
  stringConsts["nfQuestion"] = nfQuestion
  stringConsts["nfQuote"] = nfQuote
  stringConsts["nfRadioBlank"] = nfRadioBlank
  stringConsts["nfRadioMarked"] = nfRadioMarked
  stringConsts["nfRandom"] = nfRandom
  stringConsts["nfRecycle"] = nfRecycle
  stringConsts["nfRedo"] = nfRedo
  stringConsts["nfRefresh"] = nfRefresh
  stringConsts["nfRenameBox"] = nfRenameBox
  stringConsts["nfRetweet"] = nfRetweet
  stringConsts["nfRocket"] = nfRocket
  stringConsts["nfRust"] = nfRust
  stringConsts["nfSave"] = nfSave
  stringConsts["nfSdCard"] = nfSdCard
  stringConsts["nfSdCardAlt"] = nfSdCardAlt
  stringConsts["nfSearch"] = nfSearch
  stringConsts["nfSearchMinus"] = nfSearchMinus
  stringConsts["nfSearchPlus"] = nfSearchPlus
  stringConsts["nfSelectAll"] = nfSelectAll
  stringConsts["nfSelection"] = nfSelection
  stringConsts["nfSend"] = nfSend
  stringConsts["nfServer"] = nfServer
  stringConsts["nfShare"] = nfShare
  stringConsts["nfShareSquare"] = nfShareSquare
  stringConsts["nfShell"] = nfShell
  stringConsts["nfShield"] = nfShield
  stringConsts["nfShoppingCart"] = nfShoppingCart
  stringConsts["nfSignIn"] = nfSignIn
  stringConsts["nfSignOut"] = nfSignOut
  stringConsts["nfSitemap"] = nfSitemap
  stringConsts["nfSliders"] = nfSliders
  stringConsts["nfSort"] = nfSort
  stringConsts["nfSortAlpha"] = nfSortAlpha
  stringConsts["nfSortAsc"] = nfSortAsc
  stringConsts["nfSortDesc"] = nfSortDesc
  stringConsts["nfSpinner"] = nfSpinner
  stringConsts["nfSplitVertical"] = nfSplitVertical
  stringConsts["nfSquare"] = nfSquare
  stringConsts["nfStar"] = nfStar
  stringConsts["nfStarO"] = nfStarO
  stringConsts["nfStepBackward"] = nfStepBackward
  stringConsts["nfStepForward"] = nfStepForward
  stringConsts["nfStop"] = nfStop
  stringConsts["nfStrikethrough"] = nfStrikethrough
  stringConsts["nfSun"] = nfSun
  stringConsts["nfSwapVertical"] = nfSwapVertical
  stringConsts["nfSync"] = nfSync
  stringConsts["nfTable"] = nfTable
  stringConsts["nfTablet"] = nfTablet
  stringConsts["nfTag"] = nfTag
  stringConsts["nfTags"] = nfTags
  stringConsts["nfTerminal"] = nfTerminal
  stringConsts["nfTextBox"] = nfTextBox
  stringConsts["nfTextSearch"] = nfTextSearch
  stringConsts["nfTh"] = nfTh
  stringConsts["nfThLarge"] = nfThLarge
  stringConsts["nfThList"] = nfThList
  stringConsts["nfThemeLightDark"] = nfThemeLightDark
  stringConsts["nfThumbsDown"] = nfThumbsDown
  stringConsts["nfThumbsUp"] = nfThumbsUp
  stringConsts["nfThumbtack"] = nfThumbtack
  stringConsts["nfTimes"] = nfTimes
  stringConsts["nfTimesCircle"] = nfTimesCircle
  stringConsts["nfToggleOff"] = nfToggleOff
  stringConsts["nfToggleOn"] = nfToggleOn
  stringConsts["nfToggleSwitch"] = nfToggleSwitch
  stringConsts["nfToggleSwitchOff"] = nfToggleSwitchOff
  stringConsts["nfTranslate"] = nfTranslate
  stringConsts["nfTrash"] = nfTrash
  stringConsts["nfTrashCan"] = nfTrashCan
  stringConsts["nfTrophy"] = nfTrophy
  stringConsts["nfUnderline"] = nfUnderline
  stringConsts["nfUndo"] = nfUndo
  stringConsts["nfUnlink"] = nfUnlink
  stringConsts["nfUnlock"] = nfUnlock
  stringConsts["nfUpload"] = nfUpload
  stringConsts["nfUsb"] = nfUsb
  stringConsts["nfUser"] = nfUser
  stringConsts["nfUserPlus"] = nfUserPlus
  stringConsts["nfUsers"] = nfUsers
  stringConsts["nfVideo"] = nfVideo
  stringConsts["nfViewGrid"] = nfViewGrid
  stringConsts["nfViewList"] = nfViewList
  stringConsts["nfViewModule"] = nfViewModule
  stringConsts["nfVolumeOff"] = nfVolumeOff
  stringConsts["nfVolumeUp"] = nfVolumeUp
  stringConsts["nfWarning"] = nfWarning
  stringConsts["nfWifi"] = nfWifi
  stringConsts["nfWindowClose"] = nfWindowClose
  stringConsts["nfWindowMaximize"] = nfWindowMaximize
  stringConsts["nfWindowMinimize"] = nfWindowMinimize
  stringConsts["nfWindowRestore"] = nfWindowRestore
  stringConsts["nfWindows"] = nfWindows
  stringConsts["nfWrench"] = nfWrench
  stringConsts["nfXml"] = nfXml
  stringConsts["nfYaml"] = nfYaml
  stringConsts["pxActions"] = pxActions
  stringConsts["pxAdd"] = pxAdd
  stringConsts["pxAdjustBrush"] = pxAdjustBrush
  stringConsts["pxAdjustLayer"] = pxAdjustLayer
  stringConsts["pxAirbrush"] = pxAirbrush
  stringConsts["pxAlignCenter"] = pxAlignCenter
  stringConsts["pxAlignEdgeBottom"] = pxAlignEdgeBottom
  stringConsts["pxAlignEdgeHCenter"] = pxAlignEdgeHCenter
  stringConsts["pxAlignEdgeLeft"] = pxAlignEdgeLeft
  stringConsts["pxAlignEdgeRight"] = pxAlignEdgeRight
  stringConsts["pxAlignEdgeTop"] = pxAlignEdgeTop
  stringConsts["pxAlignEdgeVCenter"] = pxAlignEdgeVCenter
  stringConsts["pxAlignLeft"] = pxAlignLeft
  stringConsts["pxAlignRight"] = pxAlignRight
  stringConsts["pxAllCaps"] = pxAllCaps
  stringConsts["pxApp"] = pxApp
  stringConsts["pxArchive"] = pxArchive
  stringConsts["pxArtHistory"] = pxArtHistory
  stringConsts["pxAudio"] = pxAudio
  stringConsts["pxBack"] = pxBack
  stringConsts["pxBell"] = pxBell
  stringConsts["pxBgEraser"] = pxBgEraser
  stringConsts["pxBlur"] = pxBlur
  stringConsts["pxBrush"] = pxBrush
  stringConsts["pxBrushSettings"] = pxBrushSettings
  stringConsts["pxBucket"] = pxBucket
  stringConsts["pxBurn"] = pxBurn
  stringConsts["pxCalculator"] = pxCalculator
  stringConsts["pxCalendar"] = pxCalendar
  stringConsts["pxCamera"] = pxCamera
  stringConsts["pxChannels"] = pxChannels
  stringConsts["pxCharStyle"] = pxCharStyle
  stringConsts["pxCharacter"] = pxCharacter
  stringConsts["pxChart"] = pxChart
  stringConsts["pxCheck"] = pxCheck
  stringConsts["pxClipLayer"] = pxClipLayer
  stringConsts["pxClock"] = pxClock
  stringConsts["pxCode"] = pxCode
  stringConsts["pxColorPanel"] = pxColorPanel
  stringConsts["pxColorReplace"] = pxColorReplace
  stringConsts["pxColorThemes"] = pxColorThemes
  stringConsts["pxColumns"] = pxColumns
  stringConsts["pxCommands"] = pxCommands
  stringConsts["pxComputer"] = pxComputer
  stringConsts["pxContentMove"] = pxContentMove
  stringConsts["pxContentTrace"] = pxContentTrace
  stringConsts["pxConvertPoint"] = pxConvertPoint
  stringConsts["pxCopy"] = pxCopy
  stringConsts["pxCount"] = pxCount
  stringConsts["pxCrop"] = pxCrop
  stringConsts["pxCube"] = pxCube
  stringConsts["pxCurvaturePen"] = pxCurvaturePen
  stringConsts["pxCustomShape"] = pxCustomShape
  stringConsts["pxCut"] = pxCut
  stringConsts["pxData"] = pxData
  stringConsts["pxDatabase"] = pxDatabase
  stringConsts["pxDelete"] = pxDelete
  stringConsts["pxDesktop"] = pxDesktop
  stringConsts["pxDetails"] = pxDetails
  stringConsts["pxDocument"] = pxDocument
  stringConsts["pxDocuments"] = pxDocuments
  stringConsts["pxDodge"] = pxDodge
  stringConsts["pxDownloads"] = pxDownloads
  stringConsts["pxDrive"] = pxDrive
  stringConsts["pxEllipseShape"] = pxEllipseShape
  stringConsts["pxEraser"] = pxEraser
  stringConsts["pxError"] = pxError
  stringConsts["pxEye"] = pxEye
  stringConsts["pxEyedropper"] = pxEyedropper
  stringConsts["pxFauxBold"] = pxFauxBold
  stringConsts["pxFauxItalic"] = pxFauxItalic
  stringConsts["pxFile"] = pxFile
  stringConsts["pxFillLayer"] = pxFillLayer
  stringConsts["pxFilter"] = pxFilter
  stringConsts["pxFit"] = pxFit
  stringConsts["pxFolder"] = pxFolder
  stringConsts["pxFolderOpen"] = pxFolderOpen
  stringConsts["pxFolderPlus"] = pxFolderPlus
  stringConsts["pxFolderStar"] = pxFolderStar
  stringConsts["pxFolderUp"] = pxFolderUp
  stringConsts["pxFont"] = pxFont
  stringConsts["pxForward"] = pxForward
  stringConsts["pxFreeformPen"] = pxFreeformPen
  stringConsts["pxGantt"] = pxGantt
  stringConsts["pxGauge"] = pxGauge
  stringConsts["pxGlobe"] = pxGlobe
  stringConsts["pxGlyphs"] = pxGlyphs
  stringConsts["pxGradAngle"] = pxGradAngle
  stringConsts["pxGradDiamond"] = pxGradDiamond
  stringConsts["pxGradLinear"] = pxGradLinear
  stringConsts["pxGradRadial"] = pxGradRadial
  stringConsts["pxGradReflected"] = pxGradReflected
  stringConsts["pxGradient"] = pxGradient
  stringConsts["pxGrid"] = pxGrid
  stringConsts["pxGuides"] = pxGuides
  stringConsts["pxHandTool"] = pxHandTool
  stringConsts["pxHeal"] = pxHeal
  stringConsts["pxHelp"] = pxHelp
  stringConsts["pxHistogram"] = pxHistogram
  stringConsts["pxHistory"] = pxHistory
  stringConsts["pxHistoryBrush"] = pxHistoryBrush
  stringConsts["pxHome"] = pxHome
  stringConsts["pxHourglass"] = pxHourglass
  stringConsts["pxHourglass2"] = pxHourglass2
  stringConsts["pxIcons"] = pxIcons
  stringConsts["pxImage"] = pxImage
  stringConsts["pxInbox"] = pxInbox
  stringConsts["pxInfo"] = pxInfo
  stringConsts["pxJustifyAll"] = pxJustifyAll
  stringConsts["pxJustifyCenter"] = pxJustifyCenter
  stringConsts["pxJustifyLeft"] = pxJustifyLeft
  stringConsts["pxJustifyRight"] = pxJustifyRight
  stringConsts["pxKanban"] = pxKanban
  stringConsts["pxKey"] = pxKey
  stringConsts["pxLanguage"] = pxLanguage
  stringConsts["pxLasso"] = pxLasso
  stringConsts["pxLayerComps"] = pxLayerComps
  stringConsts["pxLayerMask"] = pxLayerMask
  stringConsts["pxLayerStyle"] = pxLayerStyle
  stringConsts["pxLayers"] = pxLayers
  stringConsts["pxLibraries"] = pxLibraries
  stringConsts["pxLineTool"] = pxLineTool
  stringConsts["pxLock"] = pxLock
  stringConsts["pxMagicWand"] = pxMagicWand
  stringConsts["pxMail"] = pxMail
  stringConsts["pxMap"] = pxMap
  stringConsts["pxMarkdown"] = pxMarkdown
  stringConsts["pxMarqueeColumn"] = pxMarqueeColumn
  stringConsts["pxMarqueeEllipse"] = pxMarqueeEllipse
  stringConsts["pxMarqueeRect"] = pxMarqueeRect
  stringConsts["pxMarqueeRow"] = pxMarqueeRow
  stringConsts["pxMixerBrush"] = pxMixerBrush
  stringConsts["pxMoreTools"] = pxMoreTools
  stringConsts["pxMoveTool"] = pxMoveTool
  stringConsts["pxMusic"] = pxMusic
  stringConsts["pxNavigator"] = pxNavigator
  stringConsts["pxNew"] = pxNew
  stringConsts["pxNote"] = pxNote
  stringConsts["pxObjectSelect"] = pxObjectSelect
  stringConsts["pxOpen"] = pxOpen
  stringConsts["pxOpenType"] = pxOpenType
  stringConsts["pxOpenWith"] = pxOpenWith
  stringConsts["pxOrgChart"] = pxOrgChart
  stringConsts["pxPaint"] = pxPaint
  stringConsts["pxParaStyle"] = pxParaStyle
  stringConsts["pxParagraph"] = pxParagraph
  stringConsts["pxPaste"] = pxPaste
  stringConsts["pxPatch"] = pxPatch
  stringConsts["pxPathArrow"] = pxPathArrow
  stringConsts["pxPathSelect"] = pxPathSelect
  stringConsts["pxPatternStamp"] = pxPatternStamp
  stringConsts["pxPatterns"] = pxPatterns
  stringConsts["pxPause"] = pxPause
  stringConsts["pxPdf"] = pxPdf
  stringConsts["pxPen"] = pxPen
  stringConsts["pxPenAdd"] = pxPenAdd
  stringConsts["pxPenRemove"] = pxPenRemove
  stringConsts["pxPencil"] = pxPencil
  stringConsts["pxPerspCrop"] = pxPerspCrop
  stringConsts["pxPhone"] = pxPhone
  stringConsts["pxPictures"] = pxPictures
  stringConsts["pxPieChart"] = pxPieChart
  stringConsts["pxPin"] = pxPin
  stringConsts["pxPlay"] = pxPlay
  stringConsts["pxPlugin"] = pxPlugin
  stringConsts["pxPolyLasso"] = pxPolyLasso
  stringConsts["pxPolygonShape"] = pxPolygonShape
  stringConsts["pxPreview"] = pxPreview
  stringConsts["pxPrint"] = pxPrint
  stringConsts["pxProofColors"] = pxProofColors
  stringConsts["pxProperties"] = pxProperties
  stringConsts["pxPuppetWarp"] = pxPuppetWarp
  stringConsts["pxQuestion"] = pxQuestion
  stringConsts["pxQuickActions"] = pxQuickActions
  stringConsts["pxQuickMask"] = pxQuickMask
  stringConsts["pxQuickSelect"] = pxQuickSelect
  stringConsts["pxRecord"] = pxRecord
  stringConsts["pxRectShape"] = pxRectShape
  stringConsts["pxRedEye"] = pxRedEye
  stringConsts["pxRedo"] = pxRedo
  stringConsts["pxRefresh"] = pxRefresh
  stringConsts["pxRemove"] = pxRemove
  stringConsts["pxRemoveTool"] = pxRemoveTool
  stringConsts["pxRename"] = pxRename
  stringConsts["pxReport"] = pxReport
  stringConsts["pxRotateView"] = pxRotateView
  stringConsts["pxRoundRectShape"] = pxRoundRectShape
  stringConsts["pxSave"] = pxSave
  stringConsts["pxScratch"] = pxScratch
  stringConsts["pxScreenFull"] = pxScreenFull
  stringConsts["pxScreenFullMenu"] = pxScreenFullMenu
  stringConsts["pxScreenWindow"] = pxScreenWindow
  stringConsts["pxScript"] = pxScript
  stringConsts["pxScriptEdit"] = pxScriptEdit
  stringConsts["pxSdCard"] = pxSdCard
  stringConsts["pxSearch"] = pxSearch
  stringConsts["pxSelAdd"] = pxSelAdd
  stringConsts["pxSelIntersect"] = pxSelIntersect
  stringConsts["pxSelNew"] = pxSelNew
  stringConsts["pxSelSubtract"] = pxSelSubtract
  stringConsts["pxSelect"] = pxSelect
  stringConsts["pxSelectionBrush"] = pxSelectionBrush
  stringConsts["pxSettings"] = pxSettings
  stringConsts["pxShapeLayer"] = pxShapeLayer
  stringConsts["pxShare"] = pxShare
  stringConsts["pxSharpen"] = pxSharpen
  stringConsts["pxSheet"] = pxSheet
  stringConsts["pxSky"] = pxSky
  stringConsts["pxSlice"] = pxSlice
  stringConsts["pxSlides"] = pxSlides
  stringConsts["pxSmallCaps"] = pxSmallCaps
  stringConsts["pxSmartObject"] = pxSmartObject
  stringConsts["pxSmudge"] = pxSmudge
  stringConsts["pxSnapshot"] = pxSnapshot
  stringConsts["pxSort"] = pxSort
  stringConsts["pxSpeaker"] = pxSpeaker
  stringConsts["pxSpiral"] = pxSpiral
  stringConsts["pxSponge"] = pxSponge
  stringConsts["pxSpotHeal"] = pxSpotHeal
  stringConsts["pxStamp"] = pxStamp
  stringConsts["pxStandardMode"] = pxStandardMode
  stringConsts["pxStar"] = pxStar
  stringConsts["pxStarShape"] = pxStarShape
  stringConsts["pxStop"] = pxStop
  stringConsts["pxStrikethrough"] = pxStrikethrough
  stringConsts["pxSubscript"] = pxSubscript
  stringConsts["pxSuperscript"] = pxSuperscript
  stringConsts["pxSwatches"] = pxSwatches
  stringConsts["pxSymmetry"] = pxSymmetry
  stringConsts["pxTerminal"] = pxTerminal
  stringConsts["pxText"] = pxText
  stringConsts["pxTiles"] = pxTiles
  stringConsts["pxTimeline"] = pxTimeline
  stringConsts["pxToolPresets"] = pxToolPresets
  stringConsts["pxTrash"] = pxTrash
  stringConsts["pxTrashFull"] = pxTrashFull
  stringConsts["pxTree"] = pxTree
  stringConsts["pxTwoPanes"] = pxTwoPanes
  stringConsts["pxTypeMask"] = pxTypeMask
  stringConsts["pxTypePath"] = pxTypePath
  stringConsts["pxTypeTool"] = pxTypeTool
  stringConsts["pxUnderline"] = pxUnderline
  stringConsts["pxUndo"] = pxUndo
  stringConsts["pxUp"] = pxUp
  stringConsts["pxUser"] = pxUser
  stringConsts["pxVideo"] = pxVideo
  stringConsts["pxVideos"] = pxVideos
  stringConsts["pxWarning"] = pxWarning
  stringConsts["pxWarp"] = pxWarp
  stringConsts["pxWarpText"] = pxWarpText
  stringConsts["pxWeb"] = pxWeb
  stringConsts["pxWindow"] = pxWindow
  stringConsts["pxZoomIn"] = pxZoomIn
  stringConsts["pxZoomOut"] = pxZoomOut
  stringConsts["pxZoomTool"] = pxZoomTool
  stringConsts["toolSeparatorKey"] = toolSeparatorKey
  intConsts["LayerBase"] = int(LayerBase)
  intConsts["LayerDialog"] = int(LayerDialog)
  intConsts["LayerPopup"] = int(LayerPopup)
  intConsts["LayerTip"] = int(LayerTip)
  intConsts["MaxGifFrames"] = int(MaxGifFrames)
  intConsts["MaxGifPixels"] = int(MaxGifPixels)
  intConsts["MaxGifSide"] = int(MaxGifSide)
  intConsts["MaxLayers"] = int(MaxLayers)
  intConsts["MaxModelBytes"] = int(MaxModelBytes)
  intConsts["MaxPoints"] = int(MaxPoints)
  intConsts["MaxTriangles"] = int(MaxTriangles)
  intConsts["MaxWavBytes"] = int(MaxWavBytes)
  intConsts["NoSound"] = int(NoSound)
  intConsts["OutRate"] = int(OutRate)
  intConsts["thumbMaxSide"] = int(thumbMaxSide)
  widgetBox.add Example(name: "rows", title: "Rows and columns", about: "`row` puts controls side by side at their own widths; when the row is full they wrap. `col` makes a column inside a row.", part: "Layout", w: 360, h: 110, code: "row:\n  button \"One\"\n  button \"Two\"\n  button \"Three\"\nrow:\n  col:\n    label \"A column\"\n    checkbox(\"in a row\", colA)\n  col:\n    label \"Another one\"\n    checkbox(\"beside it\", colB)", decls: "var colA = true\nvar colB = false", imports: @[])
  widgetBox.add Example(name: "rowwidths", title: "Widths in a row", about: "`row([widths])` gives each control its width: a number is fixed, -1 shares the room left, -2 takes two shares, 0 is the control's own width.", part: "Layout", w: 380, h: 100, code: "row([80, -1]):\n  label \"Name:\"\n  edit firstName\nrow([80, -1, -2]):\n  label \"Shares:\"\n  edit firstName\n  edit lastName\nrow([80, 0, -1]):\n  label \"Own width:\"\n  button \"Browse...\"\n  edit docPath", decls: "var firstName = \"Sultan\"\nvar lastName = \"Al Isaiee\"\nvar docPath = \"Documents/Budget.csv\"", imports: @[])
  widgetBox.add Example(name: "spring", title: "spring and space", about: "`spring()` pushes what comes after it to the row's right end: the place for OK and Cancel. `space(px)` leaves room, down in a column or right in a row.", part: "Layout", w: 380, h: 90, code: "row:\n  label \"Total: 120.000\"\n  spring()\n  button(\"OK\", isDefault = true)\n  button \"Cancel\"\nspace(12)\nrow:\n  button \"Left\"\n  space(40)\n  button \"After a space\"", decls: "", imports: @[])
  widgetBox.add Example(name: "group", title: "Groups, cards and separators", about: "A group box frames controls that belong together, as a 3.1 dialog does. A card is a raised panel with a title: the tiles of a dashboard. `separator` draws an etched line.", part: "Layout", w: 380, h: 130, code: "row([-1, -1]):\n  group(\"Group box\"):\n    label \"In a 3.1 group box\"\n  card(\"Card\"):\n    label \"A raised panel\"\nseparator()\nlabel \"Under a separator\"", decls: "", imports: @[])
  widgetBox.add Example(name: "form", title: "Forms and fields", about: "`form` lines up labels and their controls in two columns (0: the labels as wide as the longest). On a phone the label goes above its control.", part: "Layout", w: 340, h: 120, code: "form 0:\n  field \"&Customer:\": edit customer\n  field \"&Amount:\": numberEdit invoiceAmount\n  field \"\": checkbox(\"&Paid\", paid)", decls: "var customer = \"Al Noor Trading\"\nvar invoiceAmount = 1234.5\nvar paid = true", imports: @[])
  widgetBox.add Example(name: "adaptive", title: "adaptive, and the window's size", about: "`adaptive(minW)` makes as many equal columns as fit, each at least `minW` wide, and its cards flow through them. Three columns on a desktop, one on a phone, from the same code. `isCompact`, `sizeClass` and `responsive` tell the code how much room there is.", part: "Layout", w: 520, h: 130, code: "adaptive(140):\n  card(\"Sales\"): label \"OMR 1,240\"\n  card(\"Stock\"): label \"312 items\"\n  card(\"Orders\"): label \"18 open\"", decls: "", imports: @[])
  widgetBox.add Example(name: "scroll", title: "Scrolling: scrollPanel, panel, pane", about: "The window's page scrolls by itself. `scrollPanel(height)` scrolls a part of it, in a frame; `panel` is a framed white page down to the bottom (a page beside a tree, as in File Manager); `pane` scrolls on the dialog's face. `withId` gives the rows drawn by a loop ids of their own.", part: "Layout", w: 340, h: 140, code: "label \"Twenty rows in 100 pixels:\"\nscrollPanel 100:\n  for i in 0 ..< scrollChecks.len:\n    withId(i):\n      checkbox(\"Item \" & $(i + 1), scrollChecks[i])", decls: "var scrollChecks = newSeq[bool](20)", imports: @[])
  widgetBox.add Example(name: "tabs", title: "Tabs", about: "Pages of a dialog. `sel` is the page shown; Ctrl+Tab and the arrows move between them. `sameHeight` keeps the pages one height, so the dialog does not jump.", part: "Layout", w: 340, h: 110, code: "tabs(tabSel, [\"&General\", \"&Look\", \"&Advanced\"], sameHeight = true):\n  label(\"The page of tab \" & $(tabSel + 1))", decls: "var tabSel = 0", imports: @[])
  widgetBox.add Example(name: "split", title: "Splitters: split, vsplit", about: "Two panes with a bar between them to drag: side by side (`split`) or one above the other (`vsplit`). `pos` is where the bar is; keep it in your settings.", part: "Layout", w: 360, h: 110, code: "split(split1, 100):\n  listbox(splitFruits, splitFruit, rows = -1)\ndo:\n  paragraph(\"Drag the bar between the panes.\")", decls: "var split1 = 140\nvar splitFruits = @[\"Apple\", \"Banana\", \"Cherry\", \"Dates\", \"Figs\", \"Grapes\"]\nvar splitFruit = 1", imports: @["std/strutils"])
  widgetBox.add Example(name: "sidepane", title: "sidePane", about: "Content with a details pane beside it when there is room, and under it on a phone held upright: the details pane of an explorer, the inspector of an editor.", part: "Layout", w: 400, h: 110, code: "sidePane(true, paneW, paneH):\n  listbox(paneFruits, paneFruit, rows = -1)\ndo:\n  factList({\"Name\": paneFruits[paneFruit], \"Kind\": \"Fruit\"})", decls: "var paneW = 150\nvar paneH = 100\nvar paneFruits = @[\"Apple\", \"Banana\", \"Cherry\", \"Dates\"]\nvar paneFruit = 0", imports: @[])
  widgetBox.add Example(name: "label", title: "label, paragraph, heading", about: "Static text. A `&` before a letter underlines it, and Alt with that letter moves the focus to the control after the label.", part: "Text", w: 360, h: 120, code: "heading(\"Quarterly report\", 2)\nlabel \"&Name: (a label with a mnemonic)\"\nparagraph(\"A paragraph wraps to the room it has, as 3.1's static text did.\")", decls: "", imports: @[])
  widgetBox.add Example(name: "styledtext", title: "styledText, link, badge", about: "Text in a style of its own (bold, italic, mono, underlined, larger), a link that is true when clicked, and a small count in a colored badge.", part: "Text", w: 360, h: 90, code: "styledText(\"Bold, italic and mono\", style(bold = true))\nstyledText(\"Italic, underlined\", style(italic = true, underline = true))\nrow:\n  if link(\"Open the website\"): discard\n  badge(\"3\")\n  badge(\"NEW\", color(0, 128, 0))", decls: "", imports: @[])
  widgetBox.add Example(name: "icons", title: "icon, iconLabel, image", about: "The 109 pixel icons of the 3.1 manner (`px...`) and the Nerd Fonts symbols (`nf...`) are text: `icon` draws one, `iconLabel` one with a label. `image` draws an `Icon` at its size.", part: "Text", w: 360, h: 110, code: "row:\n  for g in [pxFolder, pxComputer, pxTrashFull, pxWarning, pxPrint, pxSave]: icon(g, size = 2.0)\niconLabel(pxDocuments, \"Documents\")\niconLabel(nfGithub, \"Nerd Fonts icons too\", iconColor = color(0, 0, 128))\nimage(glyphIcon(nfFolderOpen, color(222, 170, 40), 32))", decls: "", imports: @[])
  widgetBox.add Example(name: "tooltip", title: "tooltip", about: "A tip for the control drawn last, shown when the mouse rests on it. Fingers have no hover, so a touch screen shows none.", part: "Text", w: 320, h: 80, code: "if button(\"&Save\"): discard\ntooltip \"Save the document (Ctrl+S)\"", decls: "", imports: @[])
  widgetBox.add Example(name: "button", title: "button", about: "A push button: true in the frame it is clicked. `isDefault` gives it the 3.1 default ring, and Enter clicks it.", part: "Buttons", w: 300, h: 60, code: "row:\n  if button(\"&OK\", isDefault = true): inc okClicks\n  button(\"Cancel\")", decls: "var okClicks = 0", imports: @[])
  widgetBox.add Example(name: "picbuttons", title: "Buttons with a picture", about: "A button with an icon shows it four ways: the text beside it, below it, the icon only (the text becomes its tooltip), or the text only. `glyphPic` makes a Nerd Fonts symbol the picture.", part: "Buttons", w: 420, h: 80, code: "row:\n  button(\"Open\", pxOpen, blTextBeside)\n  button(\"Print\", pxPrint, blTextBelow)\n  button(\"Save\", glyphPic(nfContentSave), blIconOnly)\n  button(\"Text only\", pxSave, blTextOnly)", decls: "", imports: @[])
  widgetBox.add Example(name: "segmented", title: "segmented", about: "A row of joined buttons of which one is down: Day, Week, Month.", part: "Buttons", w: 300, h: 60, code: "segmented([\"Day\", \"Week\", \"Month\"], view2)", decls: "var view2 = 1", imports: @[])
  widgetBox.add Example(name: "menubutton", title: "menuButton, splitButton", about: "A button that drops a menu (`menuButton`: the index chosen, else -1), and a button with two parts (`splitButton`): the left one does the usual thing, the arrow offers the others.", part: "Buttons", w: 340, h: 140, code: "row:\n  let pick = menuButton(\"&Export\", [\"PNG\", \"JPEG\", \"-\", \"PDF\"])\n  if pick >= 0: discard\n  let sb = splitButton(\"&Save\", [\"Save As...\", \"Save a Copy...\"])\n  if sb.clicked: discard", decls: "", imports: @[])
  widgetBox.add Example(name: "buttonrow", title: "buttonRow", about: "The buttons at the foot of a dialog, right-aligned, the first the default: the number clicked (from 1), else 0.", part: "Buttons", w: 340, h: 60, code: "case buttonRow([\"OK\", \"Cancel\", \"Help\"])\nof 1: discard\nof 2: discard\nelse: discard", decls: "", imports: @[])
  widgetBox.add Example(name: "buttonat", title: "buttonAt", about: "A button at a place of your own: over a picture, on a bar you lay out yourself. `down` draws it held in.", part: "Buttons", w: 300, h: 90, code: "let r = canvas(220, 60)\nfill(r, color(0, 96, 128))\nif buttonAt(\"zoom-in\", rect(r.x + 8, r.y + 8, 30, 24), \"+\"): inc mapZoom\nif buttonAt(\"zoom-out\", rect(r.x + 42, r.y + 8, 30, 24), \"-\"): dec mapZoom\ndiscard buttonAt(\"layers\", rect(r.x + 76, r.y + 8, 30, 24), \"\", pxPictures, blIconOnly, down = true)", decls: "var mapZoom = 3", imports: @[])
  widgetBox.add Example(name: "checkbox", title: "checkbox", about: "A yes or no, bound to a `bool`: the 3.1 box with its X. True when it flips.", part: "Choices", w: 300, h: 70, code: "checkbox(\"&Auto save\", autoSave)\ncheckbox(\"Keep &backups\", backups)", decls: "var autoSave = true\nvar backups = false", imports: @[])
  widgetBox.add Example(name: "radio", title: "radio", about: "One of several: each radio button sets the `int` to its value when clicked.", part: "Choices", w: 300, h: 90, code: "radio(\"&Small\", size, 0)\nradio(\"&Medium\", size, 1)\nradio(\"&Large\", size, 2)", decls: "var size = 1", imports: @[])
  widgetBox.add Example(name: "toggle", title: "toggle (a switch)", about: "An on/off switch in the manner of 3.1's slide switches. Click, tap or slide it; Space, Left and Right with the focus. `switchAt` is its behavior at a place of your own.", part: "Choices", w: 300, h: 60, code: "toggle(\"&Wi-Fi\", wifi)", decls: "var wifi = true", imports: @[])
  widgetBox.add Example(name: "chips", title: "chips", about: "Words to turn on and off (filters), each with its x when `closable`: `ev.clicked` and `ev.closed` say which.", part: "Choices", w: 340, h: 60, code: "let ev = chips(tags, tagOn, closable = true)\nif ev.clicked >= 0: tagOn[ev.clicked] = not tagOn[ev.clicked]", decls: "var tags = @[\"nim\", \"retro\", \"ui\"]\nvar tagOn = @[true, false, false]", imports: @[])
  widgetBox.add Example(name: "taginput", title: "tagInput", about: "Tags as chips and a box to type the next one: Enter, a comma or Tab adds it, Backspace in the empty box takes the last one off.", part: "Choices", w: 340, h: 60, code: "tagInput(tagList, tagText)", decls: "var tagList = @[\"invoice\", \"paid\"]\nvar tagText = \"\"", imports: @[])
  widgetBox.add Example(name: "rating", title: "rating", about: "Stars, one to five: click one, or use the arrows.", part: "Choices", w: 300, h: 60, code: "rating(stars)", decls: "var stars = 3", imports: @[])
  widgetBox.add Example(name: "edit", title: "edit", about: "A one-line text box bound to a `string`: true when the text changed. `password` hides it, `readOnly` lets it be selected and copied only.", part: "Text input", w: 320, h: 90, code: "form 0:\n  field \"&Name:\": edit(name)\n  field \"&Password:\": edit(secret, password = true)", decls: "var name = \"Sultan\"\nvar secret = \"hunter2\"", imports: @[])
  widgetBox.add Example(name: "editarea", title: "editArea", about: "Text of several lines, `lines` high (-1: down to the bottom), with its scroll bars.", part: "Text input", w: 320, h: 110, code: "editArea(notes, lines = 4)", decls: "var notes = \"Line one\\nLine two\\nLine three\"", imports: @[])
  widgetBox.add Example(name: "searchbox", title: "searchBox", about: "A box with a magnifier, its hint while empty, and an x that clears it.", part: "Text input", w: 320, h: 60, code: "searchBox(query, \"Search invoices\")", decls: "var query = \"invoices\"", imports: @[])
  widgetBox.add Example(name: "autocomplete", title: "autocomplete", about: "A text box whose choices that match drop under it as you type: Down and Up pick, Enter or a click takes one.", part: "Text input", w: 320, h: 170, code: "autocomplete(acCity, [\"Muscat\", \"Muttrah\", \"Sohar\", \"Salalah\", \"Nizwa\", \"Sur\"], w = 200)", decls: "var acCity = \"\"", imports: @[])
  widgetBox.add Example(name: "maskededit", title: "maskedEdit", about: "Typing into a mask: `#` a digit, `A` a letter, `U` an upper-case letter, `X` a letter or digit, `*` anything. `maskRaw` gives what was typed without the mask.", part: "Text input", w: 320, h: 60, code: "row:\n  label \"&Phone:\"\n  maskedEdit(phone, \"+### #### ####\")", decls: "var phone = \"96891234\"", imports: @[])
  widgetBox.add Example(name: "comboedit", title: "comboEdit", about: "A text box with a list beside it: type anything, or drop the list (Alt+Down, F4, the arrow) and pick. It suggests what begins with what is typed.", part: "Text input", w: 320, h: 170, code: "comboEdit(city, [\"Berlin\", \"Bern\", \"Beirut\", \"Muscat\", \"Sohar\"], w = 180)", decls: "var city = \"Ber\"", imports: @[])
  widgetBox.add Example(name: "hotkeyedit", title: "hotkeyEdit", about: "A box that takes the next key pressed, with Ctrl, Alt and Shift, as a shortcut (\"Ctrl+Shift+S\"). `hotkeyPressed` tells when that shortcut is pressed.", part: "Text input", w: 320, h: 60, code: "row:\n  label \"&Save as:\"\n  hotkeyEdit(hotkey)", decls: "var hotkey = \"Ctrl+Shift+S\"", imports: @[])
  widgetBox.add Example(name: "numbers", title: "spin, intEdit, numberEdit", about: "Numbers to type: `spin` with its arrows (the wheel and Up/Down too), `intEdit` whole numbers, `numberEdit` decimals with `lo`, `hi` and `decimals`.", part: "Numbers, dates, colors", w: 340, h: 100, code: "form 0:\n  field \"&Copies:\": spin(copies, 1, 99)\n  field \"&Quantity:\": intEdit(qty)\n  field \"&Amount:\": numberEdit(amount)", decls: "var copies = 2\nvar qty = 12\nvar amount = 1234.5", imports: @[])
  widgetBox.add Example(name: "slider", title: "slider, progress", about: "A track bar for a value between two ends, and a 3.1 progress bar (0.0 to 1.0).", part: "Numbers, dates, colors", w: 340, h: 80, code: "slider(volume, 0, 100)\nprogress(0.62)", decls: "var volume = 40", imports: @[])
  widgetBox.add Example(name: "rangeslider", title: "rangeSlider", about: "A track bar with two thumbs: a range from `lo` to `hi`. Drag either, or the band between them to move both.", part: "Numbers, dates, colors", w: 340, h: 60, code: "rangeSlider(priceLo, priceHi, 0, 500)", decls: "var priceLo = 120\nvar priceHi = 380", imports: @[])
  widgetBox.add Example(name: "popupslider", title: "popupSlider", about: "A number box with a slider that drops from its arrow, as a tool's options bar has for Opacity: type the number, or press the arrow and drag.", part: "Numbers, dates, colors", w: 280, h: 110, code: "row:\n  label \"Opacity:\"\n  popupSlider(opacity, 0, 100, w = 60)", decls: "var opacity = 80", imports: @[])
  widgetBox.add Example(name: "knob", title: "knob", about: "A round knob (a volume, a balance): drag up or right to turn it up; the wheel and the arrows too. Its value shows under it.", part: "Numbers, dates, colors", w: 200, h: 110, code: "row:\n  knob(knobVolume, 0, 100, size = 56, label = \"Vol\")\n  knob(knobBass, 0, 100, size = 56, label = \"Bass\")", decls: "var knobVolume = 65\nvar knobBass = 30", imports: @[])
  widgetBox.add Example(name: "datepicker", title: "datePicker", about: "A date field with a calendar that drops down (Alt+Down or F4). Type the date, or pick it.", part: "Numbers, dates, colors", w: 320, h: 230, code: "datePicker(day)", decls: "var day = date(2026, 10, 27)", imports: @[])
  widgetBox.add Example(name: "calendar", title: "calendar", about: "A month to pick a day from: the arrows move the day, Page Up and Page Down the month.", part: "Numbers, dates, colors", w: 300, h: 210, code: "calendar(calDay)", decls: "var calDay = date(2026, 10, 27)", imports: @[])
  widgetBox.add Example(name: "daterange", title: "dateRange, presetRange", about: "From and to, with the ranges people ask for most (This month, Last year...) in a list.", part: "Numbers, dates, colors", w: 460, h: 60, code: "dateRange(fromDay, toDay)", decls: "var fromDay = date(2026, 10, 1)\nvar toDay = date(2026, 10, 31)", imports: @[])
  widgetBox.add Example(name: "timepicker", title: "timePicker", about: "Hours and minutes, each with its spin arrows.", part: "Numbers, dates, colors", w: 300, h: 60, code: "timePicker(hh, mm)", decls: "var hh = 9\nvar mm = 30", imports: @[])
  widgetBox.add Example(name: "colorpicker", title: "colorPicker", about: "The 48 basic colors of the 3.1 Color dialog, a preview and a box for \"#RRGGBB\".", part: "Numbers, dates, colors", w: 320, h: 180, code: "colorPicker(pick)", decls: "var pick = color(0, 128, 128)", imports: @[])
  widgetBox.add Example(name: "colorwell", title: "colorWell and the Color dialog", about: "A swatch of a color: a click opens the Color dialog -- the basic and custom colors, the spectrum, Hue, Sat, Lum, Red, Green, Blue and \"#RRGGBB\". OK sets the color. The pictures show the dialog after a click.", part: "Numbers, dates, colors", w: 560, h: 400, code: "row:\n  label \"Color:\"\n  colorWell(wellColor, \"label-color\", w = 60)", decls: "var wellColor = color(30, 120, 200)", imports: @[])
  widgetBox.add Example(name: "listbox", title: "listbox", about: "A list to pick one item from: `sel` is its index. `rows` is its height in items (-1: down to the bottom).", part: "Lists and data", w: 260, h: 130, code: "listbox(fruits, fruit, rows = 5)", decls: "var fruits = @[\"Apple\", \"Banana\", \"Cherry\", \"Dates\", \"Figs\", \"Grapes\"]\nvar fruit = 1", imports: @[])
  widgetBox.add Example(name: "combo", title: "combo", about: "A drop-down list: one item shown, the list under it when it is opened (a click, Alt+Down, F4). Typing a letter picks the next item that begins with it.", part: "Lists and data", w: 260, h: 190, code: "combo(comboFruits, fruitCombo, w = 160)", decls: "var comboFruits = @[\"Apple\", \"Banana\", \"Cherry\", \"Dates\", \"Figs\", \"Grapes\"]\nvar fruitCombo = 2", imports: @[])
  widgetBox.add Example(name: "checklist", title: "checkList", about: "A list whose items each have a check box.", part: "Lists and data", w: 260, h: 110, code: "checkList([\"Cash\", \"Bank\", \"Cards\", \"Vouchers\"], checks, rows = 4)", decls: "var checks = @[true, false, true, false]", imports: @[])
  widgetBox.add Example(name: "fontcombo", title: "fontCombo, fontStyleCombo", about: "Drop-down lists of the font families (the built-in ones and the system's) and of a family's styles, each shown in its own letters. From `retroui/textwidgets`.", part: "Lists and data", w: 300, h: 260, code: "row:\n  fontCombo(fontFamily, w = 160)\n  fontStyleCombo(fontFamily, fontStyle, w = 100)", decls: "var fontFamily = \"FreeSerif\"\nvar fontStyle = \"Bold\"", imports: @["retroui/textwidgets"])
  widgetBox.add Example(name: "grid", title: "grid", about: "Rows and columns, the rows from a `seq` or from a proc (so a million cost what twenty do). Click a header to sort, drag its edge to size it; F2 or typing edits an `editable` cell.", part: "Lists and data", w: 300, h: 120, code: "grid(cols, @[@[\"Paper\", \"10\", \"4.50\"], @[\"Ink\", \"2\", \"21.00\"], @[\"Pens\", \"40\", \"0.80\"]],\n     gridSel, height = 4)", decls: "var cols = @[column(\"Item\", 130), numberColumn(\"Qty\", 50), numberColumn(\"Price\", 70)]\nvar gridSel = 1", imports: @[])
  widgetBox.add Example(name: "datagrid", title: "grid with cell kinds", about: "The columns of a business screen: numbers, check boxes, status colors, drop-down choices, buttons, bars, links, icons and cells you draw. `style` colors a cell, `rowHeaders` adds the record indicator, `footer` a totals row.", part: "Lists and data", w: 600, h: 150, code: "grid(orderCols, orders.len, proc (r, c: int): string = orders[r][c], orderSel,\n     height = 3, rowHeaders = true,\n     style = proc (r, c: int): CellStyle =\n       (if c == 1 and r == 0: cellStyle(fg = color(200, 0, 0), bold = true) else: CellStyle()),\n     footer = proc (c: int): string =\n       (if c == 0: \"Total\" elif c == 1: \"175.955\" else: \"\"))", decls: "var orderCols = @[column(\"Order\", 120), numberColumn(\"Amount\", 70), colorColumn(\"DA\", 30),\n                  colorColumn(\"PD\", 30), checkColumn(\"S\", 28),\n                  choiceColumn(\"Store\", [\"Engineering\", \"Kitchen\", \"Cafeteria\"], 100),\n                  buttonColumn(\"\", 56)]\nvar orders = @[@[\"Pool glass door\", \"70.000\", \"green\", \"green\", \"1\", \"Engineering\", \"Open\"],\n               @[\"Stewarding\", \"51.800\", \"green\", \"blue\", \"0\", \"Kitchen\", \"Open\"],\n               @[\"Bread for canteen\", \"54.155\", \"orange\", \"green\", \"0\", \"Cafeteria\", \"Open\"]]\nvar orderSel = 0", imports: @[])
  widgetBox.add Example(name: "tree", title: "tree, branch, leaf", about: "A tree view: `sel` is the path of the node picked (\"My computer/Documents\"). A `branch` shows its children while its `bool` is true, so they can be read only when it is opened.", part: "Lists and data", w: 260, h: 150, code: "tree(treeSel, 7):\n  branch(\"My computer\", treeOpen):\n    leaf(\"Documents\")\n    branch(\"Pictures\", treeOpen2):\n      leaf(\"Holidays\")\n    leaf(\"Music\")", decls: "var treeSel = \"My computer/Documents\"\nvar treeOpen = true\nvar treeOpen2 = false", imports: @[])
  widgetBox.add Example(name: "treegrid", title: "treeGrid", about: "A tree with columns: a chart of accounts, a bill of materials.", part: "Lists and data", w: 300, h: 130, code: "treeGrid(accCols, accRows, accSel, height = 4)", decls: "var accCols = @[column(\"Account\", 170), numberColumn(\"Balance\", 90)]\nvar accRows = @[TreeRow(level: 0, cells: @[\"Assets\", \"15,000.00\"], open: true),\n                TreeRow(level: 1, cells: @[\"Cash\", \"5,000.00\"]),\n                TreeRow(level: 1, cells: @[\"Bank\", \"10,000.00\"]),\n                TreeRow(level: 0, cells: @[\"Liabilities\", \"4,000.00\"])]\nvar accSel = 1", imports: @[])
  widgetBox.add Example(name: "iconview", title: "iconView", about: "Items as large pictures with their names under them (the Large icons view), as tiles with a detail line, or as small icons. You draw each picture.", part: "Lists and data", w: 360, h: 150, code: "iconView(6, proc (i: int): string = [\"Reports\", \"Budget\", \"Photos\", \"Music\", \"Notes\", \"Setup\"][i],\n         proc (i: int; r: Rect) =\n           let g = [pxFolder, pxSheet, pxPictures, pxMusic, pxText, pxApp][i]\n           image(r.x + (r.w - 32) div 2, r.y + (r.h - 32) div 2, glyphIcon(g, ui.theme.text, 32)),\n         iconSel, iconMarked, height = 130)", decls: "var iconSel = 0\nvar iconMarked: seq[bool]", imports: @[])
  widgetBox.add Example(name: "lineview", title: "lineView", about: "Lines of text from a proc, any number of them: a log, a huge file. Only the lines in view are asked for.", part: "Lists and data", w: 340, h: 110, code: "lineView(100000, proc (i: int): string = \"2026-10-27 10:\" & $(i mod 60) & \" request \" & $i & \" ok\",\n         logSel, height = 100, numbers = true)", decls: "var logSel = 3", imports: @[])
  widgetBox.add Example(name: "duallist", title: "dualList", about: "Two lists to move items between (the buttons, a double click, Enter), and to order the chosen ones.", part: "Lists and data", w: 640, h: 200, code: "dualList(avail, chosen, rows = 5)", decls: "var avail = @[\"Cash\", \"Bank\", \"Sales\"]\nvar chosen = @[\"Rent\", \"Salaries\"]", imports: @[])
  widgetBox.add Example(name: "propertygrid", title: "propertyGrid", about: "Properties by category: text, numbers, yes/no, choices, colors and dates, with a help line for the one picked.", part: "Lists and data", w: 320, h: 250, code: "propertyGrid(props, propSel, height = 220)", decls: "var props = @[textProp(\"Name\", \"Main store\", \"General\", \"What the store is called\"),\n              boolProp(\"Active\", true, \"General\"),\n              choiceProp(\"Region\", [\"North\", \"South\", \"East\"], 1, \"General\"),\n              numberProp(\"Budget\", 1500.5, 2, \"Money\"),\n              colorProp(\"Label\", color(0, 128, 0), \"Look\")]\nvar propSel = 0", imports: @[])
  widgetBox.add Example(name: "imageview", title: "imageView", about: "A picture to look at: fitted while `zoom` is 0, else that many screen pixels per picture pixel. The wheel zooms, a double click goes between fitted and actual size, a drag moves it.", part: "Lists and data", w: 340, h: 200, code: "imageView(beach, picZoom, height = 180)", decls: "var beach = loadPicture(getHomeDir() / \"Pictures\" / \"Beach.png\")\nvar picZoom = 0.0", imports: @["std/os"])
  widgetBox.add Example(name: "status", title: "progressRing, spinner, sparkline, usageBar", about: "A ring of progress, a busy spinner, a small line of numbers, and a bar of how full something is.", part: "Progress and status", w: 360, h: 100, code: "row:\n  progressRing(0.62)\n  spinner()\n  col:\n    sparkline([3.0, 5, 4, 7, 6, 9, 8, 11], w = 140, h = 30)\n    usageBar(62, 100, w = 140)", decls: "", imports: @[])
  widgetBox.add Example(name: "banner", title: "banner", about: "A message across the page, with its buttons (the index clicked, or 0 for its x).", part: "Progress and status", w: 420, h: 90, code: "discard banner(\"A new version is ready.\", bkInfo, [\"Update\"])\ndiscard banner(\"Low on storage: 300 MB left.\", bkWarning, closable = false)", decls: "", imports: @[])
  widgetBox.add Example(name: "toast", title: "toast", about: "A balloon in the style of Windows 95 and 98: pale yellow, with its tail, an icon and a title. It goes away by itself. The pictures show it after the button was clicked.", part: "Progress and status", w: 420, h: 150, code: "if button(\"&Save\"):\n  toast(\"Saved \\\"Budget.csv\\\" to Documents.\", glyph = pxCheck, title = \"Ledger\")", decls: "", imports: @[])
  widgetBox.add Example(name: "snackbar", title: "showSnackbar, snackbar", about: "A bar at the bottom that says what was just done, with one action: the Undo of today's apps. `showSnackbar` asks for it; `snackbar()`, once a frame, draws it and is true when its action is clicked.", part: "Progress and status", w: 420, h: 120, code: "if button(\"&Delete 3 messages\"):\n  showSnackbar(\"3 messages deleted\")\nif snackbar(): discard", decls: "", imports: @[])
  widgetBox.add Example(name: "ledpill", title: "led, pill", about: "A small light, lit or dark, with its label; and a word in a colored tag (\"Paid\", \"Overdue\").", part: "Progress and status", w: 300, h: 70, code: "row:\n  led(true, \"Online\")\n  led(false, \"Syncing\", color(255, 160, 0))\n  pill(\"Paid\", color(0, 140, 0))\n  pill(\"Overdue\", color(200, 0, 0))", decls: "", imports: @[])
  widgetBox.add Example(name: "timeline", title: "timeline", about: "Events down a line: the time, a dot (the current one filled), a title and a line of detail.", part: "Progress and status", w: 320, h: 140, code: "timeline([(\"09:00\", \"Order placed\", \"Al Noor Trading\"), (\"11:30\", \"Packed\", \"\"),\n          (\"14:10\", \"Shipped\", \"by courier\")], current = 1)", decls: "", imports: @[])
  widgetBox.add Example(name: "emptystate", title: "emptyState, busyState", about: "What a list shows when it has nothing (an icon, a line, what to do), and while it is loading.", part: "Progress and status", w: 360, h: 110, code: "row([-1, -1]):\n  emptyState(pxInbox, \"No messages\", 100)\n  busyState(\"Loading...\", 100)", decls: "", imports: @[])
  widgetBox.add Example(name: "statusbar", title: "statusbar", about: "The bar at the bottom of the window, of texts: the first takes the spare room. Content above it can fill down to it (`rows = -1`).", part: "Progress and status", w: 420, h: 60, code: "statusbar(\"Ready\", \"NUM\", \"12:30\")", decls: "", imports: @[])
  widgetBox.add Example(name: "statusrow", title: "statusRow, statusSep", about: "A status bar with controls in it (a zoom field, a menu arrow, texts), its parts parted by `statusSep`.", part: "Progress and status", w: 420, h: 60, code: "statusRow:\n  row:\n    label \"Page 3 of 12\"\n    statusSep()\n    label \"Zoom:\"\n    spin(zoomPct, 10, 400, w = 70)", decls: "var zoomPct = 100", imports: @[])
  widgetBox.add Example(name: "expander", title: "expander", about: "A header that folds away what most people do not need.", part: "Containers", w: 300, h: 90, code: "expander(\"Advanced settings\", more):\n  label \"Hidden until it is opened\"", decls: "var more = true", imports: @[])
  widgetBox.add Example(name: "accordion", title: "accordionHeader", about: "Sections of which one is open at a time: true for the open one, so draw its content then.", part: "Containers", w: 300, h: 130, code: "for i, t in [\"General\", \"Advanced\", \"About\"]:\n  if accordionHeader(t, i, openSection):\n    label(\"The \" & t & \" section\")", decls: "var openSection = 0", imports: @[])
  widgetBox.add Example(name: "tabstrip", title: "tabStrip (document tabs)", about: "The tabs of open documents, each with its icon and its x, and a + for a new one; tabs can be dragged to order them.", part: "Containers", w: 400, h: 60, code: "discard tabStrip(docTabs, docTab, [pxText, pxMarkdown, pxSheet])", decls: "var docTab = 0\nvar docTabs = @[\"Report.txt\", \"Notes.md\", \"Budget.csv\"]", imports: @[])
  widgetBox.add Example(name: "menu", title: "menubar, menu, menuItem, submenu", about: "The window's menu bar: `menuItem` is true when chosen, with its shortcut, a check mark or disabled. Alt, F10 and the letters work as in 3.1.", part: "Menus and bars", w: 320, h: 180, code: "menubar:\n  menu \"&File\":\n    discard menuItem(\"&New\", \"Ctrl+N\")\n    discard menuItem(\"&Open...\", \"Ctrl+O\")\n    menuSeparator()\n    discard menuItem(\"&Save\", \"Ctrl+S\", enabled = false)\n    discard menuItem(\"&Word wrap\", checked = true)\n  menu \"&Edit\":\n    discard menuItem(\"&Undo\", \"Ctrl+Z\")", decls: "", imports: @[])
  widgetBox.add Example(name: "contextmenu", title: "contextMenu", about: "A menu for the control drawn last, opened by a right click, a long press or the menu key. The pictures show it open.", part: "Menus and bars", w: 320, h: 150, code: "label \"Right click here, or hold a finger on it\"\ncontextMenu:\n  discard menuItem(\"&Copy\", \"Ctrl+C\")\n  discard menuItem(\"&Paste\", \"Ctrl+V\")\n  menuSeparator()\n  discard menuItem(\"P&roperties\")", decls: "", imports: @[])
  widgetBox.add Example(name: "popupmenu", title: "popupMenu, openPopupMenu", about: "A menu dropped where you say: under a button, at the mouse. `openPopupMenu(key, x, y)` opens it, `popupMenu(key)` draws its items.", part: "Menus and bars", w: 300, h: 140, code: "if button(\"&Sort by\"):\n  openPopupMenu(\"sort\", ui.lastRect.x, ui.lastRect.y + ui.lastRect.h)\npopupMenu(\"sort\"):\n  if menuItem(\"&Name\", checked = sortBy == 0): sortBy = 0\n  if menuItem(\"&Date\", checked = sortBy == 1): sortBy = 1\n  if menuItem(\"&Size\", checked = sortBy == 2): sortBy = 2", decls: "var sortBy = 0", imports: @["std/algorithm"])
  widgetBox.add Example(name: "breadcrumb", title: "breadcrumb", about: "Where the user is, each part a link back: the index clicked, else -1.", part: "Menus and bars", w: 380, h: 60, code: "breadcrumb([\"C:\", \"Users\", \"Foxoman\", \"Documents\"])", decls: "", imports: @[])
  widgetBox.add Example(name: "pager", title: "pager, stepper", about: "Pages to go through (|< < 3 of 12 > >|), and the steps of a task (Cart, Address, Payment) with the one reached.", part: "Menus and bars", w: 380, h: 100, code: "pager(page, 12)\ndiscard stepper([\"Cart\", \"Address\", \"Payment\"], stepAt)", decls: "var page = 3\nvar stepAt = 1", imports: @[])
  widgetBox.add Example(name: "recordnav", title: "recordNav", about: "The record navigator of a form: first, previous, \"3 of 20\", next, last, New, Delete and Save (`raNew`, `raSave`...).", part: "Menus and bars", w: 640, h: 60, code: "discard recordNav(recPos, 20, dirty = true)", decls: "var recPos = 2", imports: @[])
  widgetBox.add Example(name: "findbar", title: "findBar, findIn, replaceAllIn", about: "A bar to find and replace text in: Enter or F3 the next match, Shift+F3 the one before, Esc closes it. The app does the finding with `findIn` and `replaceAllIn`.", part: "Menus and bars", w: 760, h: 80, code: "discard findBar(findState)", decls: "var findState = FindState(open: true, what: \"cat\", replacing: true)", imports: @[])
  widgetBox.add Example(name: "msgbox", title: "msgBox", about: "A message with its icon and buttons: the button clicked (from 1) in the frame it closes, else 0.", part: "Dialogs", w: 400, h: 170, code: "discard msgBox(msgOpen, \"Retro Files\", \"Delete \\\"Budget.csv\\\" for good?\\nThis cannot be undone.\",\n               [\"&Delete\", \"Cancel\"], miWarning)", decls: "var msgOpen = true", imports: @[])
  widgetBox.add Example(name: "inputbox", title: "inputBox", about: "A question with a text box: true once, when OK is clicked.", part: "Dialogs", w: 400, h: 160, code: "discard inputBox(inputOpen, \"Save as\", \"&File name:\", inputText)", decls: "var inputOpen = true\nvar inputText = \"Untitled\"", imports: @[])
  widgetBox.add Example(name: "dialog", title: "dialog", about: "A dialog of your own: any controls in its body. Esc closes it.", part: "Dialogs", w: 400, h: 180, code: "dialog(dlgOpen, \"Page setup\", 300):\n  form 0:\n    field \"&Copies:\": spin(dlgCopies, 1, 99)\n    field \"\": checkbox(\"&Collate\", collate)\n  row:\n    spring()\n    if button(\"OK\", isDefault = true): dlgOpen = false\n    if button(\"Cancel\"): dlgOpen = false", decls: "var dlgOpen = true\nvar dlgCopies = 2\nvar collate = true", imports: @[])
  widgetBox.add Example(name: "progressbox", title: "progressBox", about: "A modal box with a progress bar while work goes on: true once when the user cancels.", part: "Dialogs", w: 420, h: 170, code: "if progressBox(copying, \"Copying\", \"Copying 12 files to Backup...\", 0.45,\n               detail = \"Budget 2026.csv\"):\n  discard", decls: "var copying = true", imports: @[])
  widgetBox.add Example(name: "wizard", title: "wizard, stepDone", about: "A dialog of steps with Back, Next and Finish. `stepDone(false)` keeps Next disabled until the step is filled in.", part: "Dialogs", w: 700, h: 260, code: "discard wizard(wizOpen, \"New company\", wizStep, [\"Name\", \"Address\", \"Bank\", \"Done\"], 480):\n  label \"&Street:\"\n  edit street", decls: "var wizOpen = true\nvar wizStep = 1\nvar street = \"Al Khuwair Street\"", imports: @[])
  widgetBox.add Example(name: "aboutbox", title: "aboutBox", about: "The About dialog: a banner in the blue of a 1994 Setup screen with the icon, name and version; pages About, What's New and Credits; Copy Info for a report of a fault.", part: "Dialogs", w: 500, h: 400, code: "aboutBox(aboutOpen, \"Ledger\", \"2.0\", [\"(c) 2026 Foxoman. Small business accounts.\"],\n         glyph = pxSheet, tagline = \"Small business accounts\",\n         whatsNew = [\"Invoices in PDF\", \"Bank files read\"], credits = [RetroFontCredit])", decls: "var aboutOpen = true", imports: @[])
  widgetBox.add Example(name: "splashbox", title: "splashBox", about: "The box a program shows while it starts, as the About box looks, with a progress bar of blocks.", part: "Dialogs", w: 560, h: 380, code: "splashBox(\"Ledger\", \"2.0\", \"Small business accounts\", glyph = pxSheet, progress = 0.4,\n          note = \"Reading the accounts...\")", decls: "", imports: @[])
  widgetBox.add Example(name: "problembox", title: "problemBox, reportProblem", about: "Report a Problem: the fault log (or your text) for the user to add what they were doing, then Copy or Send by Email. `problemBox` every frame also opens it by itself after a run that ended in a fault.", part: "Dialogs", w: 520, h: 360, code: "if button(\"&Report a Problem...\"):\n  reportProblem(\"The total was wrong after the bank file was read.\")\nproblemBox(\"Ledger\", \"2.0\")", decls: "", imports: @[])
  widgetBox.add Example(name: "filedialog", title: "fileDialog (3.1)", about: "The Windows 3.1 Open and Save As dialog: the file name with its list, the folders, the drives and the file types. True once, with `path` set.", part: "Dialogs", w: 520, h: 380, code: "if fileDialog(openOld, oldPath, fmOpen, [\"Text files (*.txt)\", \"All Files (*.*)\"]):\n  discard", decls: "var openOld = true\nvar oldPath = getHomeDir() / \"Documents\"", imports: @["std/os"])
  widgetBox.add Example(name: "toolbar", title: "toolbar, toolButton, toolSeparator", about: "A tool bar of small buttons; those that do not fit go into a \"more\" menu. `down` shows a button held in.", part: "App parts", w: 360, h: 70, code: "toolbar:\n  toolButton(pxNew, \"New\")\n  toolButton(pxOpen, \"Open\")\n  toolButton(pxSave, \"Save\")\n  toolSeparator()\n  toolButton(pxCut, \"Cut\")\n  toolButton(pxCopy, \"Copy\")\n  toolButton(pxPaste, \"Paste\", down = true)", decls: "", imports: @[])
  widgetBox.add Example(name: "window", title: "window", about: "A window of the system's own beside the app's: a tool palette, a second view for another monitor, a preview. It is laid out and drawn as the app's window is, with its own menus and dialogs, at the place in the frame the app draws it; its close button sets the `bool` to false, and it closes when it is no longer drawn. X11, Wayland, Windows and macOS open real windows; on phones, in the browser and on a screen without a desktop it is a dialog over the app.", part: "App parts", w: 380, h: 120, code: "if button(\"&Tools...\"): toolsOpen = true\nwindow(toolsOpen, \"Tools\", 240, 160):\n  checkbox(\"&Bold\", bold)", decls: "var toolsOpen = true\nvar bold = false", imports: @[])
  widgetBox.add Example(name: "barbutton", title: "barButton, setToolbarLook", about: "Tool bar buttons with a picture and a label, shown as the bar's look says: icons only, or the text below or beside them (Explorer's \"Text Labels\"). An app can offer it as a setting.", part: "App parts", w: 380, h: 80, code: "setToolbarLook(blTextBelow)\ntoolbar:\n  if barButton(pxBack, \"Back\"): discard\n  if barButton(pxForward, \"Forward\"): discard\n  toolSeparator()\n  if barButton(pxCopy, \"Copy\", tip = \"Copy (Ctrl+C)\"): discard\n  if barButton(pxDelete, \"Delete\"): discard", decls: "", imports: @[])
  widgetBox.add Example(name: "customizetoolbar", title: "customizeToolbar", about: "The Customize Toolbar dialog of Windows 95: the buttons the bar can have, the ones it has, their order, and how labels show. The app keeps the bar as a list of keys (`toolKeys`, `toolKeysText`).", part: "App parts", w: 620, h: 420, code: "if customizeToolbar(customizing, barKeys, toolChoices, [\"new\", \"open\", \"-\", \"print\"], barLook):\n  discard", decls: "var customizing = true\nvar barKeys = @[\"new\", \"open\", \"-\", \"print\"]\nvar barLook = blTextBelow\nlet toolChoices = [ToolChoice(key: \"new\", label: \"New\", glyph: pxNew),\n                   ToolChoice(key: \"open\", label: \"Open\", glyph: pxOpen),\n                   ToolChoice(key: \"save\", label: \"Save\", glyph: pxSave),\n                   ToolChoice(key: \"print\", label: \"Print\", glyph: pxPrint),\n                   ToolChoice(key: \"mail\", label: \"Mail\", glyph: pxMail)]", imports: @[])
  widgetBox.add Example(name: "mdi", title: "mdiArea, mdiWindow, mdiWindowMenu", about: "Windows in the window, as in Program Manager: the 3.1 frame, moved by their title bars, sized by their edges, minimized to icons, maximized, Ctrl+F6 to the next. Keep each `MdiWindow` in a global. `mdiWindowMenu` fills a Window menu: Cascade, Tile and the windows.", part: "App parts", w: 380, h: 240, code: "mdiArea(-1):\n  mdiWindow(mdi1):\n    label \"Cash   5,000\"\n    label \"Bank  10,000\"\n  mdiWindow(mdi2):\n    label \"Invoice 42\"\n  mdiWindow(mdi3):\n    label \"Notes\"", decls: "var mdi1 = MdiWindow(title: \"Accounts\", r: rect(8, 8, 200, 110), open: true)\nvar mdi2 = MdiWindow(title: \"Invoices\", r: rect(120, 50, 200, 110), open: true)\nvar mdi3 = MdiWindow(title: \"Notes\", open: true, minimized: true)", imports: @[])
  widgetBox.add Example(name: "dock", title: "dockPanels: docked panels", about: "Panels as today's Photoshop docks them, drawn as 1994 drew its palettes: columns of tabbed groups down the right of an `mdiArea`, a column folded to icons, panels dragged between groups or out into floating palettes. The `Dock` keeps where they are (`toJson`, `loadDock`).", part: "App parts", w: 620, h: 300, code: "mdiArea(-1, \"work\"):\n  mdiWindow(docWin):\n    label \"The document\"\n  discard dockPanels(docDock, \"work\", proc (key: string) =\n    case key\n    of \"props\":\n      label \"Opacity:\"\n      slider(dockOpacity, 0, 100)\n    of \"layers\":\n      for i, n in [\"Text\", \"Shapes\", \"Background\"]:\n        checkbox(n, layerOn[i])\n    else: label(\"The \" & key & \" panel\"))", decls: "var docDock = block:\n  var dk = newDock()\n  discard dk.addColumn()\n  discard dk.addGroup(0, [dockPanel(\"props\", \"Properties\", nfSliders),\n                          dockPanel(\"info\", \"Info\", nfInfo)], share = 45)\n  discard dk.addGroup(0, [dockPanel(\"layers\", \"Layers\", nfImageMultiple)], share = 55)\n  discard dk.addColumn(iconic = true)\n  discard dk.addGroup(1, [dockPanel(\"history\", \"History\", nfHistory),\n                          dockPanel(\"swatches\", \"Swatches\", nfPalette)])\n  dk\nvar docWin = MdiWindow(title: \"Untitled-1\", r: rect(10, 10, 220, 150), open: true)\nvar dockOpacity = 80\nvar layerOn = [true, true, false]", imports: @["retroui/system"])
  widgetBox.add Example(name: "palettetabs", title: "paletteTabs", about: "The tabs of a palette that holds several (Layers, Channels, Paths): the one shown joined to the palette, the others behind it, and the arrow of the palette's menu.", part: "App parts", w: 320, h: 70, code: "discard paletteTabs([\"Layers\", \"Channels\", \"Paths\"], palTab)", decls: "var palTab = 0", imports: @[])
  widgetBox.add Example(name: "keymap", title: "keymapEditor, keymapPressed", about: "Shortcuts the user picks: a `Keymap` holds the app's defaults and the user's changes; `keymapEditor` lets them change them; `keymapPressed` says which command's keys were pressed.", part: "App parts", w: 380, h: 230, code: "keymapEditor(keys, [\"New\", \"Open\", \"Save\", \"Save As\", \"Print\"], height = 120)\ncase keymapPressed(keys)\nof \"Save\": discard\nelse: discard", decls: "var keys = Keymap(defaults: @[(\"Ctrl+N\", \"New\"), (\"Ctrl+O\", \"Open\"), (\"Ctrl+S\", \"Save\"),\n                              (\"Ctrl+P\", \"Print\")])", imports: @[])
  widgetBox.add Example(name: "settings", title: "settingToggle, settingChoice, settingSlider, settingCombo, settingButtons, settingLink", about: "The rows of a settings page, as a phone's or the 3.1 Control Panel's: a title, a line under it and its control at the right.", part: "App parts", w: 420, h: 260, code: "settingToggle(\"Notifications\", setOn, \"For new messages\")\ndiscard settingChoice(\"Sync\", [\"Hourly\", \"Daily\", \"Never\"], setChoice)\ndiscard settingSlider(\"Brightness\", setLevel, 0, 100, suffix = \"%\")\ndiscard settingCombo(\"Color scheme\", [\"Classic\", \"Ocean\", \"Desert\"], setCombo)\ndiscard settingButtons(\"Cache\", [\"Clear\"], \"12 MB\")", decls: "var setOn = true\nvar setChoice = 1\nvar setLevel = 60\nvar setCombo = 0", imports: @[])
  widgetBox.add Example(name: "appearance", title: "appearanceSettings", about: "The look of every app in a few rows: the color scheme, the size of everything, the size of the text, controls for a mouse or fingers, the window's frame and the font. `app`'s `look` keeps the user's choice by itself.", part: "App parts", w: 460, h: 560, code: "appearanceSettings()", decls: "", imports: @[])
  widgetBox.add Example(name: "avatar", title: "avatar, factList", about: "A person's initials in a colored circle (true when clicked), and facts as name and value lines.", part: "App parts", w: 360, h: 100, code: "row:\n  avatar(\"Sultan Al-Said\")\n  avatar(\"Maryam Ali\")\n  col:\n    factList({\"Orders\": \"10\", \"Best month\": \"May\"})", decls: "", imports: @[])
  widgetBox.add Example(name: "bottomnav", title: "bottomNav, fab", about: "The parts of a phone app: the navigation bar at the bottom and the round floating button.", part: "App parts", w: 360, h: 160, code: "label \"Content\"\ndiscard bottomNav([(pxHome, \"Home\"), (pxSearch, \"Search\"), (pxUser, \"Me\")], nav)\ndiscard fab(nfPlus, \"New\")", decls: "var nav = 0", imports: @[])
  widgetBox.add Example(name: "captionbar", title: "captionBar", about: "The window's 3.1 title bar where the app draws it: on phones and tablets, and on desktops with the 3.1 frame. `app` calls it every frame, so an app has nothing to do. See [The window's frame](#the-windows-frame).", part: "App parts", w: 360, h: 60, code: "captionBar()", decls: "", imports: @[])
  widgetBox.add Example(name: "filelist", title: "fileList", about: "The items of a `FolderModel` as rows with columns (`fvDetails`), large icons (`fvIcons`, pictures as thumbnails) or tiles. Selecting, sorting, renaming (F2), type-ahead and drag and drop come with it.", part: "Files", w: 640, h: 200, code: "let ev = fileList(folder, fvDetails, height = 180)\nif ev.activated:\n  if ev.item.isDir: folder.open(ev.item.path)\n  else: discard openFile(ev.item.path)", decls: "var folder = newFolderModel(getHomeDir() / \"Documents\")", imports: @["std/os"])
  widgetBox.add Example(name: "fileicons", title: "fileList: large icons", about: "The same list as icons; pictures show as thumbnails, decoded in the background.", part: "Files", w: 480, h: 200, code: "discard fileList(pics, fvIcons, height = 180)", decls: "var pics = newFolderModel(getHomeDir() / \"Pictures\")", imports: @["std/os"])
  widgetBox.add Example(name: "foldertree", title: "folderTree", about: "The places of the device (home, documents, drives) and your favorites, each opening into its folders. Files can be dragged onto them.", part: "Files", w: 280, h: 220, code: "let ev = folderTree(treeFolder, [getHomeDir() / \"Documents\" / \"Invoices\"], rows = 10)\nif ev.picked: discard", decls: "var treeFolder = getHomeDir() / \"Documents\"", imports: @["std/os"])
  widgetBox.add Example(name: "placesview", title: "placesView", about: "\"This device\": the places and your favorites as tiles with how full their disks are. The folder clicked, else \"\".", part: "Files", w: 480, h: 260, code: "let f = placesView([getHomeDir() / \"Documents\" / \"Invoices\"])\nif f.len > 0: discard", decls: "", imports: @["std/os"])
  widgetBox.add Example(name: "filepreview", title: "filePreview", about: "The details pane: the file the mouse rests on, else the one selected, else the folder -- its picture or the start of its text, its size and dates, Open, Share and Properties.", part: "Files", w: 300, h: 400, code: "discard filePreview(preview)", decls: "var preview = newFolderModel(getHomeDir() / \"Pictures\")\npreview.selectAfterLoad([getHomeDir() / \"Pictures\" / \"Beach.png\"])", imports: @["std/os"])
  widgetBox.add Example(name: "pathbar", title: "pathBar", about: "The folder as a row of its folders, as in Explorer: click one to go there, the arrow after it for its folders; a click on the empty part turns it into a box to type a path.", part: "Files", w: 480, h: 50, code: "discard pathBar(\"/home/sultan/Documents/Reports/2026\")", decls: "", imports: @[])
  widgetBox.add Example(name: "drivebar", title: "driveBar", about: "The drive buttons of File Manager: the places, and your favorites.", part: "Files", w: 480, h: 50, code: "discard driveBar(getHomeDir(), [getHomeDir() / \"Documents\"])", decls: "", imports: @["std/os"])
  widgetBox.add Example(name: "filepicker", title: "filePicker", about: "A modern Open and Save dialog (the whole screen on a phone): places, a path bar, the folder, a preview of the file, and for saving a name. `patterns` limits the files shown; `fmFolder` picks a folder.", part: "Files", w: 780, h: 540, code: "if filePicker(pickOpen, picked, fmOpen, [\"*.png\", \"*.jpg\"]):\n  discard", decls: "var pickOpen = true\nvar picked = getHomeDir() / \"Pictures\"", imports: @["std/os"])
  widgetBox.add Example(name: "trashlist", title: "trashList", about: "The system's trash: what was deleted, from where and when, with Restore, Delete forever and Empty the trash.", part: "Files", w: 680, h: 200, code: "let te = trashList(trashBin, height = 180)\nif te.changed: discard", decls: "var trashBin = block:\n  var t = newTrashList()\n  t.reload()\n  t", imports: @[])
  widgetBox.add Example(name: "properties", title: "propertiesDialog", about: "The properties of files and folders: where they are, their size (folders are measured while it is open), dates, permissions.", part: "Files", w: 460, h: 380, code: "propertiesDialog(propsOpen, budget)", decls: "var propsOpen = true\nlet budget = listFolder(getHomeDir() / \"Documents\").filterIt(it.name == \"Budget 2026.csv\")", imports: @["std/os", "std/sequtils"])
  widgetBox.add Example(name: "runjob", title: "runJobDialog", about: "Runs a copy, move, delete or zip job a slice a frame with a progress box, and asks Replace, Keep both or Skip when a name is taken (as in the pictures).", part: "Files", w: 480, h: 240, code: "if copyJob != nil and runJobDialog(copyJob, \"Copying\"):\n  copyJob = nil", decls: "var copyJob = newJob(jkCopy, [getHomeDir() / \"Documents\" / \"Letter.txt\"],\n                     getHomeDir() / \"Documents\" / \"Projects\")", imports: @["std/os"])
  widgetBox.add Example(name: "textfileview", title: "textFileView, hexFileView", about: "A text file of any size, its lines counted a few milliseconds a frame while the first are shown; and any file as hex, read as it is shown.", part: "Files", w: 500, h: 260, code: "textFileView(letter, lineSel, height = 110)\nhexFileView(letterHex, hexSel, height = 110)", decls: "var letter = openTextFile(getHomeDir() / \"Documents\" / \"Letter.txt\")\nvar letterHex = openHexFile(getHomeDir() / \"Documents\" / \"Letter.txt\")\nvar lineSel = 0\nvar hexSel = 0", imports: @["std/os"])
  widgetBox.add Example(name: "picturebox", title: "pictureBox", about: "A picture file as a control: busy dots while it is decoded, an icon if it cannot be.", part: "Files", w: 340, h: 130, code: "row:\n  pictureBox(getHomeDir() / \"Pictures\" / \"Beach.png\", w = 140, h = 100)\n  pictureBox(getHomeDir() / \"Pictures\" / \"Sunset.png\", w = 140, h = 100)", decls: "", imports: @["std/os"])
  widgetBox.add Example(name: "storagedialog", title: "storageDialog", about: "On Android, the dialog that asks the user to let the app reach the shared storage (`askStorage`). Draw it every frame with the other dialogs; elsewhere it draws nothing.", part: "Files", w: 300, h: 60, code: "storageDialog()", decls: "", imports: @[])
  widgetBox.add Example(name: "chart", title: "chart", about: "A chart of series over labels. `ev.clicked` and `ev.index` tell which bar, point or slice was clicked (or picked with Enter).", part: "Charts", w: 440, h: 240, code: "chart(\"Sales by month\", chBar, chMonths,\n      [series(\"2025\", [120.0, 150, 90, 180, 210, 250]),\n       series(\"2026\", [140.0, 170, 130, 190, 240, 280])], height = 220)", decls: "var chMonths = [\"Jan\", \"Feb\", \"Mar\", \"Apr\", \"May\", \"Jun\"]", imports: @[])
  widgetBox.add Example(name: "chartcombo", title: "A combo chart", about: "Bars, and a line on a second axis with its own number format. `ChartOpts` sets the titles, axis names, legend, data labels, ranges, bands and colors.", part: "Charts", w: 440, h: 240, code: "chart(chCombo, chMonths,\n      [series(\"Revenue\", [120.0, 150, 90, 180, 210, 250]),\n       lineSeries(\"Margin\", [0.21, 0.25, 0.18, 0.27, 0.3, 0.33])],\n      ChartOpts(title: \"Revenue and margin\", format: NumFormat(prefix: \"$\", suffix: \"K\"),\n                format2: NumFormat(percent: true), dataLabels: false), height = 220)", decls: "var chMonths = [\"Jan\", \"Feb\", \"Mar\", \"Apr\", \"May\", \"Jun\"]", imports: @[])
  widgetBox.add Example(name: "simplecharts", title: "barChart, lineChart, pieChart", about: "The quick ones: a list of numbers as bars, lines or slices, in one call.", part: "Charts", w: 620, h: 200, code: "row([-1, -1, -1]):\n  barChart([12.0, 18, 9, 22], [\"Q1\", \"Q2\", \"Q3\", \"Q4\"], title = \"Orders\")\n  lineChart([@[3.0, 5, 4, 7, 6], @[2.0, 3, 5, 4, 6]], [\"M\", \"T\", \"W\", \"T\", \"F\"],\n            [\"Sohar\", \"Muscat\"], title = \"Guests\")\n  pieChart([45.0, 30, 25], [\"Rooms\", \"Food\", \"Spa\"], title = \"Revenue\")", decls: "var\n  W = 360", imports: @[])
  widgetBox.add Example(name: "kanban", title: "kanbanBoard", about: "Lanes of cards: drag a card to another lane (a finger: hold, then move), or Ctrl and the arrows; Enter opens it. A lane can have a work limit.", part: "Planning and dashboards", w: 640, h: 260, code: "kanbanBoard(kanbanLanes, kanbanSel)", decls: "var kanbanLanes = @[\n  KanbanLane(title: \"To do\", cards: @[\n    KanbanCard(title: \"Price list\", detail: \"For the new menu\", tag: color(219, 68, 55),\n               who: \"Sultan Al-Said\", due: date(2026, 10, 30)),\n    KanbanCard(title: \"Staff rota\", who: \"Amal Z\")]),\n  KanbanLane(title: \"Doing\", limit: 2, cards: @[\n    KanbanCard(title: \"Pool repair\", detail: \"Pump and filter\", tag: color(66, 133, 244))]),\n  KanbanLane(title: \"Done\", cards: @[KanbanCard(title: \"Fire drill\")])]\nvar kanbanSel: KanbanPos = (0, 0)", imports: @[])
  widgetBox.add Example(name: "gantt", title: "ganttView", about: "Tasks on a day, week or month scale, with weekends and today marked, parts that fold and links between tasks. Drag a bar to move it, its ends to change its dates.", part: "Planning and dashboards", w: 680, h: 200, code: "ganttView(ganttTasks, taskSel, ganttScale)", decls: "var ganttTasks = @[\n  GanttTask(name: \"Opening\", start: date(2026, 10, 20), finish: date(2026, 11, 12)),\n  GanttTask(name: \"Kitchen\", start: date(2026, 10, 20), finish: date(2026, 10, 28),\n            progress: 0.7, level: 1, color: color(219, 68, 55)),\n  GanttTask(name: \"Rooms\", start: date(2026, 10, 25), finish: date(2026, 11, 4),\n            progress: 0.3, level: 1, deps: @[1]),\n  GanttTask(name: \"Soft opening\", start: date(2026, 11, 10), finish: date(2026, 11, 10),\n            level: 1, milestone: true, deps: @[2])]\nvar taskSel = 1\nvar ganttScale = gsDay", imports: @[])
  widgetBox.add Example(name: "agenda", title: "agendaView", about: "Appointments by month, week or day; drag one to move it, its edge to make it longer.", part: "Planning and dashboards", w: 600, h: 330, code: "agendaView(agendaItems, agendaDay, agendaMode)", decls: "var agendaItems = @[\n  Appointment(title: \"Audit\", day: date(2026, 10, 27), start: 9 * 60, finish: 11 * 60),\n  Appointment(title: \"Holiday\", day: date(2026, 10, 29), allDay: true, color: color(15, 157, 88)),\n  Appointment(title: \"Review\", day: date(2026, 10, 28), start: 14 * 60, finish: 15 * 60 + 30)]\nvar agendaDay = date(2026, 10, 27)\nvar agendaMode = amMonth", imports: @[])
  widgetBox.add Example(name: "orgchart", title: "orgChart", about: "Who reports to whom, as boxes and lines; branches fold.", part: "Planning and dashboards", w: 560, h: 240, code: "orgChart(orgStaff, orgSel)", decls: "var orgStaff = @[\n  OrgNode(name: \"Amal Al-Harthy\", title: \"General manager\", parent: -1),\n  OrgNode(name: \"Badr Al-Kindi\", title: \"Rooms\", parent: 0, color: color(66, 133, 244)),\n  OrgNode(name: \"Dana Al-Said\", title: \"Food & beverage\", parent: 0, color: color(219, 68, 55)),\n  OrgNode(name: \"Eid Saleh\", title: \"Front office\", parent: 1),\n  OrgNode(name: \"Huda Nasser\", title: \"Restaurant\", parent: 2)]\nvar orgSel = 0", imports: @[])
  widgetBox.add Example(name: "mapview", title: "mapView", about: "A world map with values by country (colored), markers and routes; it pans, zooms (the wheel, a pinch) and says which country is under the mouse. The map is built in: no tiles, no network.", part: "Maps and 3D", w: 600, h: 320, code: "mapView(worldMap, height = 300,\n        values = [(\"OM\", 120.0), (\"AE\", 340.0), (\"SA\", 510.0), (\"IN\", 800.0),\n                  (\"GB\", 380.0), (\"US\", 950.0)],\n        markers = [cityMarker(\"Muscat\", size = 6), cityMarker(\"London\")],\n        routes = [MapRoute(fromLat: 23.59, fromLon: 58.41, toLat: 51.51, toLon: -0.13)],\n        legendTitle = \"Sales\")", decls: "var worldMap = MapState()", imports: @[])
  widgetBox.add Example(name: "view3d", title: "view3d", about: "A 3D view of meshes and models (OBJ, STL): boxes, spheres, cylinders, cones and planes, a grid and axes. Drag to turn it, the wheel to zoom.", part: "Maps and 3D", w: 380, h: 260, code: "view3d(modelScene, modelCam, height = 240)", decls: "var\n  modelCam = camera3()\nvar\n  modelScene = Scene3()", imports: @[])
  widgetBox.add Example(name: "bars3d", title: "bars3d", about: "A 3D bar chart, shown in a `view3d`.", part: "Maps and 3D", w: 380, h: 260, code: "view3d(barsScene, barsCam, height = 240)", decls: "var\n  barsCam = camera3(yaw = 30, pitch = 28)\nvar\n  barsScene = bars3d(@[@[12.0, 18, 9, 22], @[8.0, 14, 16, 11]], [\"North\", \"South\"],\n                [\"Q1\", \"Q2\", \"Q3\", \"Q4\"], showValues = true)", imports: @[])
  widgetBox.add Example(name: "htmlview", title: "htmlView, htmlBlock", about: "HTML: headings, paragraphs, bold, colors, tables, lists, pictures and links (reported when clicked). `htmlBlock` is the same without its own scroll bar, as a part of a page.", part: "HTML, Markdown and rich text", w: 420, h: 230, code: "htmlView(\"<h3>Sales <u>report</u></h3><p>Up <b>12%</b>, costs \" &\n         \"<span style=\\\"color:#c00\\\">down</span>, <mark>new store</mark> open.</p>\" &\n         \"<table><tr><th>Month</th><th align=right>Sales</th></tr>\" &\n         \"<tr><td>August</td><td align=right>1,020</td></tr>\" &\n         \"<tr><td>September</td><td align=right>980</td></tr></table>\" &\n         \"<ul><li>North<li>South</ul>\", height = 210)", decls: "", imports: @["std/strutils"])
  widgetBox.add Example(name: "webview", title: "webView, webRun, webPost", about: "A web page in the window. With the system's engine (`engine = weSystem`; the default in an Android app) the page is the system's browser placed over the widget: scripts, forms, video, its own Back and Forward. Its scripts talk to the app: `retro.post(text)` in the page comes in `messages`, `webPost` sends a `retro` event to the page, `webRun` runs a script and its answer comes in `results`. `webAllow` keeps it to the hosts you trust, `webZoom` sizes it. The picture is the kit's own engine (the system's view is drawn by the system, not here).", part: "HTML, Markdown and rich text", w: 420, h: 220, code: "let ev = webView(\"html:<title>Order 1042</title><h3>Order 1042</h3>\" &\n                 \"<p>Ready to <b>ship</b> on Sunday.</p><ul><li>12 chairs<li>2 tables</ul>\",\n                 height = 150, key = \"order\", engine = weSystem)\nrow([70, 70, -1]):\n  if button(\"&Back\", enabled = ev.canGoBack): webGoBack(\"order\")\n  if button(\"&Ask\"): webRun(\"order\", \"document.title\")\n  label ev.title                # (an answer of webRun: ev.results)", decls: "", imports: @[])
  widgetBox.add Example(name: "markdownview", title: "markdownView, markdown", about: "Markdown: headings, emphasis, code, lists, task lists (a click ticks them: `toggleTask`), tables, quotes and links -- right to left where they are in Arabic. Screen readers read its words (`mdPlainText`).", part: "HTML, Markdown and rich text", w: 420, h: 230, code: "markdownView(\"# Notes\\n\\nSome **bold**, *italic* and `code`.\\n\\n\" &\n             \"- [x] Invoices sent\\n- [ ] Stock count\\n\\n\" &\n             \"| Item | Qty |\\n|---|--:|\\n| Paper | 10 |\\n| Ink | 2 |\\n\", height = 210)", decls: "", imports: @[])
  widgetBox.add Example(name: "richedit", title: "richEdit, richToolbar", about: "A rich text editor (bold, italic, colors, sizes, lists, quotes, links, alignment) with its tool bar; it reads and writes HTML (`richFromHtml`, `toHtml`) and checks spelling where the system can. From `retroui/richedit`.", part: "HTML, Markdown and rich text", w: 640, h: 280, code: "richToolbar(letterDoc)\nrichEdit(letterDoc, height = 180)", decls: "var letterDoc = richFromHtml(\"<p>Dear <b>Maryam</b>,</p><p>The new <i>price list</i> is \" &\n                             \"<span style=\\\"color:#c00000\\\">ready</span>:</p>\" &\n                             \"<ul><li>Rooms</li><li>Food</li></ul><p>Sultan</p>\")", imports: @["retroui/richedit"])
  widgetBox.add Example(name: "canvas", title: "canvas: your own drawing", about: "Room for your own drawing: draw into the rectangle it returns with `fill`, `box`, `line`, `text`, `image`, `drawBitmap`, and the smooth `disc`, `ring`, `roundRect`, `polygon`, `thickLine`, `pieSlice`.", part: "Canvas and reports", w: 320, h: 140, code: "let r = canvas(280, 110)\nfill(r, color(255, 255, 240))\nbox(r, ui.theme.frame)\nroundRect(rect(r.x + 12, r.y + 12, 100, 40), 8, color(0, 0, 128))\ntext(r.x + 26, r.y + 24, \"Drawn\", color(255, 255, 255), true)\ndisc(float(r.x + 180), float(r.y + 55), 30, color(200, 0, 0))\nline(r.x + 12, r.y + 90, r.x + 268, r.y + 70, color(0, 128, 0))", decls: "", imports: @[])
  widgetBox.add Example(name: "canvas2d", title: "canvas2d (the HTML5 Canvas 2D API)", about: "The whole HTML5 Canvas 2D API in Nim: paths, curves, gradients, patterns, shadows, text, pictures, transforms and compositing, as on the web. `newCanvas2D` draws off screen (`toBitmap`, `savePng`).", part: "Canvas and reports", w: 380, h: 230, code: "canvas2d(ctx, 360, 210):\n  let sky = ctx.createLinearGradient(0, 0, 0, 210)\n  sky.addColorStop(0, \"#000080\")\n  sky.addColorStop(1, \"#1084d0\")\n  ctx.fillStyle = sky\n  ctx.fillRect(0, 0, 360, 210)\n  ctx.fillStyle = \"#2e7d32\"\n  ctx.beginPath()\n  ctx.moveTo(0, 210)\n  ctx.bezierCurveTo(110, 100, 220, 220, 360, 130)\n  ctx.lineTo(360, 210)\n  ctx.closePath()\n  ctx.fill()\n  ctx.shadowColor = \"rgba(0, 0, 0, 0.5)\"\n  ctx.shadowBlur = 8\n  ctx.shadowOffsetX = 4\n  ctx.shadowOffsetY = 4\n  ctx.fillStyle = \"gold\"\n  ctx.beginPath()\n  ctx.arc(270, 60, 34, 0, 2 * PI)\n  ctx.fill()\n  ctx.shadowColor = \"transparent\"\n  ctx.font = \"bold 20px sans-serif\"\n  ctx.fillStyle = \"white\"\n  ctx.fillText(\"Retro canvas\", 16, 34)", decls: "", imports: @["std/math"])
  widgetBox.add Example(name: "reportview", title: "reportView (an HTML template: PDF, printing)", about: "Reports, invoices and lists laid out on pages, from an HTML template and data or from Nim code; shown on a gray desk with page buttons and zoom, saved as PDF or PNG, or printed.", part: "Canvas and reports", w: 520, h: 380, code: "reportView(shotReport, height = 360)", decls: "var name = \"World\"\nconst shotTemplate = \"\"\"\n<header><span>Gulf Print House</span><span>Quote {{number}}</span></header>\n<footer><span></span><span>Page {page} of {pages}</span></footer>\n<h1>Quote {{number}}</h1><p>For <b>{{customer}}</b>:</p>\n<table><thead><tr><th width=\"60%\">Item</th><th align=\"right\">Qty</th><th align=\"right\">Amount</th></tr></thead>\n<tbody>{{#lines}}<tr><td>{{name}}</td><td>{{qty}}</td><td>{{amount|n3}}</td></tr>{{/lines}}</tbody>\n<tfoot><tr><td colspan=\"2\" align=\"right\">Total (OMR)</td><td>{{total|n3}}</td></tr></tfoot></table>\"\"\"\nlet shotReport = reportFromHtml(renderTemplate(shotTemplate, %*{\"number\": \"Q-118\",\n  \"customer\": \"Al Noor Trading\", \"total\": 268.5,\n  \"lines\": [{\"name\": \"Business cards\", \"qty\": 2, \"amount\": 25.0},\n            {\"name\": \"Letterheads\", \"qty\": 3, \"amount\": 76.5},\n            {\"name\": \"Roll-up banner\", \"qty\": 1, \"amount\": 167.0}]}))", imports: @["std/strutils", "std/json"])
  widgetBox.add Example(name: "pdfview", title: "pdfView", about: "A PDF file's pages one under another, each drawn at the size it is shown; the wheel, the scroll bars and a finger move along, Ctrl and the wheel zoom. Call `addPdfPreviews()` once at the start: it teaches the toolkit to draw PDF pages (and the file controls to show them). `pdfPreview` gives a file's first page as a picture. From `retroui/pdfview`.", part: "Canvas and reports", w: 440, h: 320, code: "pdfView(quotePdf, height = 300)", decls: "addPdfPreviews()\nvar quotePdf = openPdfView(getHomeDir() / \"Documents\" / \"Quote Q-118.pdf\")", imports: @["retroui/pdfview", "std/os"])
  widgetBox.add Example(name: "qrcode", title: "QR codes", about: "`qrEncode` makes the QR code of a text, `qrBitmap` its picture, to draw with `drawBitmap` (or put in a report). From `retroui/qrcode`.", part: "Canvas and reports", w: 240, h: 160, code: "drawBitmap(canvas(qr.w, qr.h), qr)\nlabel \"www.foxoman.net\"", decls: "let qr = qrBitmap(qrEncode(\"https://www.foxoman.net\"), scale = 4)", imports: @["retroui/qrcode"])
  widgetBox.add Example(name: "animation", title: "animation (animated GIFs)", about: "The frames of `loadGif` played round and round, each for its delay. The app wakes only when the next frame is due.", part: "Sound and video", w: 300, h: 70, code: "row:\n  animation(gifFrames, height = 48)\n  label \"An animated GIF\"", decls: "let gifFrames = loadGif(readFile(\"examples/assets/pattern.gif\"))", imports: @[])
  widgetBox.add Example(name: "videoview", title: "videoView", about: "A video with play, pause, a position bar and the time: a file or a web address (HLS where the system plays it), played by the system's own player and drawn by the kit in the window -- Media Foundation on Windows, AVFoundation on macOS and iOS, GStreamer on Linux, Android's VideoView. Space plays and pauses.", part: "Sound and video", w: 420, h: 280, code: "videoView(movie, height = 260)", decls: "let movie = getHomeDir() / \"Videos\" / \"Harbour.avi\"", imports: @["std/os"])
  widgetBox.add Example(name: "cameraview", title: "cameraView", about: "The camera's live picture in the window, drawn by the kit under its menus and dialogs, through the system's own API (Video4Linux, Media Foundation, AVFoundation, Camera2; getUserMedia in a web page): photos, videos of it, and sound recorded from the microphone.", part: "Sound and video", w: 420, h: 300, code: "let cam = cameraView(height = 240)\nrow:\n  if button(\"&Photo\"): cameraPhoto(\"\", \"photo.jpg\")\n  if button(if cam.recording: \"&Stop\" else: \"&Record\"):\n    if cam.recording: cameraStop() else: cameraRecord(\"\", \"clip.mp4\")", decls: "var\n  clip = \"\"", imports: @["retroui/capture"])
  widgetBox.add Example(name: "nowplaying", title: "setNowPlaying, mediaKeys", about: "What the app plays, shown where the system shows it -- the lock screen, the notification shade, the taskbar's media flyout, the menu bar's Now Playing, the desktop's media applet, the browser's media hub -- and what the user presses there and on media keys, handed to the app (MPRIS, the System Media Transport Controls, MPNowPlayingInfoCenter, a MediaSession, the browser's Media Session). Call it every frame: the system is told only what changed.", part: "Sound and video", w: 420, h: 80, code: "setNowPlaying(NowPlaying(title: \"Morning bell\", artist: \"Retro\", playing: true,\n                         positionMs: 12_000, durationMs: 95_000, canNext: true))\nfor k in mediaKeys():\n  if k.key == mkPlayPause: discard", decls: "", imports: @["retroui/mediasession"])
  widgetBox.add Example(name: "audioview", title: "audioView", about: "A sound file to play: its name, play and pause, a position bar and the time (MP3, OGG, FLAC, WAV where the system plays them).", part: "Sound and video", w: 420, h: 140, code: "audioView(song, height = 120)", decls: "let song = getHomeDir() / \"Music\" / \"Morning bell.ogg\"", imports: @["std/os"])
  widgetBox.add Example(name: "notify", title: "notify, share, haptic", about: "Tell the user outside the window (`notify`: the system's notification; `setBadge`: the count on the app's icon), offer something to other apps (`share`: a share sheet, a share menu, Web Share), a tap felt (`haptic`), a buzz (`vibrate`). False where the system has none: the example falls back to a toast and the clipboard.", part: "The system's features", w: 420, h: 70, code: "row:\n  if button(\"&Notify\"):\n    if not notify(\"Order 1042\", \"Ready at the counter\", tag = \"orders\"):\n      toast(\"Order 1042 is ready\")\n  if button(\"&Share\"):\n    if not share(text = \"Order 1042\", url = \"https://example.com/o/1042\"):\n      putClipboardText(\"https://example.com/o/1042\")\n  if button(\"&Tap\"): haptic(hSuccess)\n  if button(\"&Attention\"): requestAttention()", decls: "", imports: @["retroui/system"])
  widgetBox.add Example(name: "location", title: "location, speak", about: "Where the device is (`location`: `psWaiting` until the first fix, the user asked the first time; `stopLocation` when done) and words said aloud with the system's voice (`speak`, `stopSpeaking`, `speaking`).", part: "The system's features", w: 420, h: 90, code: "row:\n  if button(\"&Where am I?\"): sysPlace = true\n  if button(\"S&peak\"): speak(\"Your order is ready\")\n  if button(\"Sto&p\"): stopSpeaking()\nif sysPlace:\n  let p = location()\n  label(case p.state\n        of psOk: \"At \" & $p.lat & \", \" & $p.lon\n        of psWaiting: \"Looking...\"\n        of psDenied: \"The place was not allowed.\"\n        of psNone: \"No place on this device.\")", decls: "var sysPlace = false", imports: @["retroui/system"])
  widgetBox.add Example(name: "deviceinfo", title: "deviceInfo, setOpenAtLogin", about: "The device in one call (`deviceInfo`: its name, system, language, battery, dark look, network, cores), the app started with the computer (`setOpenAtLogin`: Windows' Run key, a launch agent, an autostart entry), `online`, `systemLanguage`, `battery`, `revealFile`.", part: "The system's features", w: 420, h: 160, code: "let d = deviceInfo()\nfactList({\"Device\": d.name, \"System\": d.system, \"Language\": d.language,\n          \"Network\": (if d.online: \"connected\" else: \"offline\")})\nvar atLogin = openAtLogin(\"Shop\")\nif toggle(\"Start with the &computer\", atLogin): setOpenAtLogin(atLogin, \"Shop\")", decls: "", imports: @["retroui/system"])
  widgetBox.add Example(name: "secrets", title: "saveSecret, loadSecret", about: "Small secrets -- a sign-in's tokens, an API's key -- kept where other users and programs cannot read them: DPAPI on Windows, the keychain on macOS, the desktop's keyring on Linux, a sealed file on phones, WebCrypto in a web page.", part: "The system's features", w: 420, h: 70, code: "row:\n  if button(\"&Keep the key\"): sysSaid = $saveSecret(\"Shop\", \"api key\", \"k-1042\")\n  if button(\"&Read it\"): sysSaid = loadSecret(\"Shop\", \"api key\")\n  if button(\"&Forget it\"): deleteSecret(\"Shop\", \"api key\")\nlabel sysSaid", decls: "var sysSaid = \"\"", imports: @["retroui/secrets"])
  widgetBox.add Example(name: "updates", title: "checkForUpdate, downloadUpdate, installUpdate", about: "Updates inside the app: the update file you publish, its signature checked (Ed25519) with the public key built into the app, the file for this system downloaded and its SHA-256 checked, then installed (`restartApp`). `retrokit update-key` makes the key, `retrokit update-sign update.json` signs each release. It waits for the network: on a thread of its own, or at a moment the app may wait.", part: "The system's features", w: 420, h: 70, code: "if button(\"Check for &updates\"):\n  let u = checkForUpdate(\"https://example.com/shop/update.json\", \"01VFThQl2gEEkWYqnvsvw+bbRTD59hQ2SAdg6kBwDjU=\", \"1.2.0\")\n  if u.available:\n    let file = downloadUpdate(u)\n    if installUpdate(file): restartApp()\n  else: updateSaid = if u.error.len > 0: u.error else: \"This is the newest.\"\nlabel updateSaid", decls: "var updateSaid = \"\"", imports: @["retroui/update"])

{.pop.}
