## AT-SPI: the accessibility service of Linux and the BSDs (Orca reads
## through it). A window's tree (`access`) is put on the accessibility bus:
## the program registers with AT-SPI's registry, answers what screen readers
## ask about each node (its role, name, states, place, text, value) and
## sends events when the focus, a name, a state or a text changes. What a
## screen reader asks the program to do (press, focus, put text) goes into
## `accessRequests`.
##
## Over the D-Bus client of `dbus` -- nothing linked. A driver calls
## `atspiStart` once its window is there, adds `atspiFds` to what it waits
## on, and calls `atspiProcess` when one is readable.

import std/[strutils, unicode, os]
import dbus, access

var
  atspiToolkit* = "uirelays"
    ## The toolkit's name screen readers are told.
  atspiAppName* = ""
    ## The program's name (else the window's title).
  atspiOrigin*: proc (): tuple[x, y: int] {.nimcall.}
    ## Where the window's content is on the screen (set by the driver).
  atspiWake*: proc () {.nimcall.}
    ## Wakes the program's loop: a screen reader asked for something.

var
  session, bus: DBusConn
  registered = false
  nodes: seq[AccessNode]
  focusAt = -1
  desktop: tuple[bus, path: string] = ("", "/org/a11y/atspi/null")
  appId = 0'i32
  activated = false             # the window's Activate told

const
  RootPath = "/org/a11y/atspi/accessible/root"
  BasePath = "/org/a11y/atspi/accessible/"
  NullPath = "/org/a11y/atspi/null"
  IfAccessible = "org.a11y.atspi.Accessible"
  IfComponent = "org.a11y.atspi.Component"
  IfAction = "org.a11y.atspi.Action"
  IfText = "org.a11y.atspi.Text"
  IfEditable = "org.a11y.atspi.EditableText"
  IfValue = "org.a11y.atspi.Value"
  IfApplication = "org.a11y.atspi.Application"
  IfProps = "org.freedesktop.DBus.Properties"
  EvObject = "org.a11y.atspi.Event.Object"

# ---- the tree ---------------------------------------------------------------------

const AppNode = -2      ## (the application object: the window's parent)

proc pathOf(i: int): string =
  if i == AppNode or i < 0 or i >= nodes.len: RootPath else: BasePath & $nodes[i].id

proc nodeAt(path: string): int =
  ## The node a path names: an index, `AppNode`, or -1 (gone).
  if path == RootPath: return AppNode
  if not path.startsWith(BasePath): return -1
  try:
    let id = uint32(parseBiggestUInt(path[BasePath.len .. ^1]))
    nodes.indexOfId(id)
  except ValueError: -1

proc kids(i: int): seq[int] =
  if i == AppNode: (if nodes.len > 0: @[0] else: @[])
  else: nodes.childrenOf(i)

proc parentOf(i: int): int =
  if i == AppNode: -3
  elif i == 0: AppNode
  else: int(nodes[i].parent)

proc roleNum(r: AccessRole): uint32 =
  case r
  of arWindow: 23
  of arPane: 39
  of arGroup: 99
  of arLabel: 29
  of arButton: 43
  of arToggleButton: 62
  of arCheckBox: 7
  of arRadioButton: 44
  of arTextField: 79
  of arTextArea: 61
  of arPasswordField: 40
  of arComboBox: 11
  of arList: 98
  of arListItem: 32
  of arSlider: 51
  of arSpinButton: 52
  of arProgressBar: 42
  of arScrollBar: 48
  of arMenuBar: 34
  of arMenu: 33
  of arMenuItem: 35
  of arToolBar: 63
  of arStatusBar: 54
  of arTabList: 38
  of arTab: 37
  of arTree: 65
  of arTreeItem: 91
  of arTable: 55
  of arRow: 90
  of arCell: 56
  of arColumnHeader: 10
  of arDialog: 16
  of arLink: 88
  of arImage: 27
  of arHeading: 83
  of arSeparator: 50
  of arToolTip: 64
  of arAlert: 2

proc stateBits(i: int): array[2, uint32] =
  var bits: set[0 .. 63]
  if i == AppNode:
    bits = {8, 24, 25, 30}
  else:
    let n = nodes[i]
    if asDisabled notin n.states: bits.incl {8, 24}          # enabled, sensitive
    bits.incl {25, 30}                                       # showing, visible
    if i == 0: bits.incl 1                                   # active
    if asFocusable in n.states: bits.incl 11
    if asFocused in n.states: bits.incl 12
    if asChecked in n.states: bits.incl 4
    if asMixed in n.states: bits.incl 32
    if n.role in {arCheckBox, arRadioButton, arToggleButton}: bits.incl 41  # checkable
    if n.role in {arListItem, arTab, arTreeItem, arRow, arCell}: bits.incl 22  # selectable
    if asSelected in n.states: bits.incl 23
    if asExpandable in n.states:
      bits.incl 9
      bits.incl(if asExpanded in n.states: 10 else: 5)
    if n.role in {arTextField, arTextArea, arPasswordField}:
      if asReadOnly in n.states: bits.incl 43 else: bits.incl 7
      bits.incl(if asMultiLine in n.states: 17 else: 26)
      bits.incl 38                                           # selectable text
    elif asReadOnly in n.states: bits.incl 43
    if asDefault in n.states: bits.incl 39
    if asPressed in n.states: bits.incl 20
    if asModal in n.states: bits.incl 16
    if n.role in {arSlider, arScrollBar, arProgressBar}: bits.incl 14   # horizontal
  for b in bits:
    result[b div 32] = result[b div 32] or (1'u32 shl (b mod 32))

proc hasText(i: int): bool =
  i >= 0 and nodes[i].role in {arTextField, arTextArea, arPasswordField, arLabel,
                               arStatusBar, arHeading, arSpinButton}

proc textOf(i: int): string =
  if i < 0: return ""
  if nodes[i].role in {arLabel, arStatusBar, arHeading}: nodes[i].name
  elif nodes[i].role == arPasswordField: ""
  else: nodes[i].value

proc hasValue(i: int): bool =
  i >= 0 and nodes[i].role in {arSlider, arSpinButton, arProgressBar, arScrollBar}

proc actionName(i: int): string =
  ## The node's one action ("" none).
  if i < 0: return ""
  case nodes[i].role
  of arButton, arToggleButton, arLink: "click"
  of arCheckBox, arRadioButton: "toggle"
  of arMenuItem, arMenu, arTab, arListItem, arTreeItem: "click"
  of arComboBox: "press"
  else: ""

proc interfacesOf(i: int): seq[string] =
  result = @[IfAccessible, IfComponent]
  if i == AppNode: return @[IfAccessible, IfApplication]
  if actionName(i).len > 0: result.add IfAction
  if hasText(i): result.add IfText
  if i >= 0 and nodes[i].role in {arTextField, arTextArea, arPasswordField} and
     asReadOnly notin nodes[i].states: result.add IfEditable
  if hasValue(i): result.add IfValue

proc extents(i: int; coord: uint32): tuple[x, y, w, h: int] =
  if i == AppNode or i < 0: return
  let n = nodes[i]
  result = (n.x, n.y, n.w, n.h)
  if coord == 0 and atspiOrigin != nil:          # (the screen's)
    let o = atspiOrigin()
    result.x += o.x
    result.y += o.y
  elif coord == 2:                                # (the parent's)
    let p = parentOf(i)
    if p >= 0:
      result.x -= nodes[p].x
      result.y -= nodes[p].y

# ---- answers ----------------------------------------------------------------------

proc refTo(w: var DBusWriter; i: int) =
  if i == -3: w.objRef(desktop.bus, desktop.path)
  elif i == -1: w.objRef("", NullPath)
  else: w.objRef(bus.uniqueName, pathOf(i))

proc ask(action: AccessAction; i: int; text = ""; num = 0.0) =
  if i < 0: return
  accessRequests.add AccessRequest(action: action, id: nodes[i].id, text: text, num: num)
  if atspiWake != nil: atspiWake()

proc runeOffsets(s: string; a, b: int): tuple[a, b: int] =
  ## Characters `a ..< b` of `s` as bytes (-1 for b: to the end).
  let n = s.runeLen
  var ca = clamp(a, 0, n)
  var cb = if b < 0: n else: clamp(b, ca, n)
  var i, k = 0
  result = (s.len, s.len)
  while i <= s.len:
    if k == ca: result.a = i
    if k == cb:
      result.b = i
      break
    if i == s.len: break
    i += max(1, runeLenAt(s, i))
    inc k

proc textSlice(s: string; a, b: int): string =
  let (x, y) = runeOffsets(s, a, b)
  s[x ..< y]

proc boundary(s: string; offset: int; kind: uint32): tuple[a, b: int] =
  ## The character, word, sentence or line (`kind`: AT-SPI's granularity:
  ## 0 char, 1 word, 2 sentence, 3 line, 4 paragraph) at `offset`.
  let rs = s.toRunes
  let n = rs.len
  let o = clamp(offset, 0, n)
  case kind
  of 0: (o, min(n, o + 1))
  of 1:
    var a = o
    while a > 0 and not rs[a - 1].isWhiteSpace: dec a
    var b = o
    while b < n and not rs[b].isWhiteSpace: inc b
    (a, b)
  else:
    # (a line: up to the new line; a text box of one line is all one)
    var a = o
    while a > 0 and rs[a - 1] != Rune('\n'): dec a
    var b = o
    while b < n and rs[b] != Rune('\n'): inc b
    if b < n: inc b
    (a, b)

proc getProperty(w: var DBusWriter; i: int; iface, name: string): bool =
  ## The property as a variant into `w`; false when there is none.
  result = true
  case iface
  of IfAccessible:
    case name
    of "Name":
      w.variantStr(if i == AppNode: atspiAppName elif i >= 0: nodes[i].name else: "")
    of "Description": w.variantStr(if i >= 0: nodes[i].help else: "")
    of "HelpText": w.variantStr(if i >= 0: nodes[i].help else: "")
    of "Parent":
      w.sig("(so)")
      w.refTo(parentOf(i))
    of "ChildCount": w.variantInt(int32(kids(i).len))
    of "Locale": w.variantStr(getEnv("LANG", "C").split('.')[0])
    of "AccessibleId": w.variantStr(if i >= 0: $nodes[i].id else: "")
    else: result = false
  of IfApplication:
    case name
    of "ToolkitName": w.variantStr(atspiToolkit)
    of "Version": w.variantStr("1.0")
    of "AtspiVersion": w.variantStr("2.1")
    of "Id": w.variantInt(appId)
    else: result = false
  of IfValue:
    if i < 0: return false
    case name
    of "MinimumValue": w.variantF64(nodes[i].lo)
    of "MaximumValue": w.variantF64(nodes[i].hi)
    of "MinimumIncrement": w.variantF64(nodes[i].step)
    of "CurrentValue": w.variantF64(nodes[i].now)
    of "Text": w.variantStr(nodes[i].value)
    else: result = false
  of IfText:
    case name
    of "CharacterCount": w.variantInt(int32(textOf(i).runeLen))
    of "CaretOffset": w.variantInt(int32(if i >= 0: nodes[i].caret else: 0))
    else: result = false
  of IfAction:
    if name == "NActions": w.variantInt(int32(if actionName(i).len > 0: 1 else: 0))
    else: result = false
  else: result = false

proc propNames(iface: string): seq[string] =
  case iface
  of IfAccessible: @["Name", "Description", "Parent", "ChildCount", "Locale", "AccessibleId"]
  of IfApplication: @["ToolkitName", "Version", "AtspiVersion", "Id"]
  of IfValue: @["MinimumValue", "MaximumValue", "MinimumIncrement", "CurrentValue", "Text"]
  of IfText: @["CharacterCount", "CaretOffset"]
  of IfAction: @["NActions"]
  else: @[]

proc handle(m: DBusMsg) =
  ## A method call on one of the program's objects.
  let i = nodeAt(m.path)
  var r = m.reader()
  var w: DBusWriter
  template answer(s: string) = bus.reply(m, s, w.buf)
  if m.member == "GetItems" and m.iface == "org.a11y.atspi.Cache":
    # (no cache of the whole tree: clients ask node by node)
    let a = w.beginArray(8)
    w.endArray(a)
    answer("a((so)(so)(so)iiassusau)")
    return
  if i == -1 and m.iface != "org.freedesktop.DBus.Peer":
    bus.replyError(m, "org.freedesktop.DBus.Error.UnknownObject", "gone")
    return
  case m.iface & "." & m.member
  of "org.freedesktop.DBus.Peer.Ping":
    answer("")
  of "org.freedesktop.DBus.Introspectable.Introspect":
    var x = "<node>"
    for f in interfacesOf(i): x.add "<interface name=\"" & f & "\"/>"
    x.add "</node>"
    w.str(x)
    answer("s")
  of IfProps & ".Get":
    let iface = r.str()
    let name = r.str()
    if w.getProperty(i, iface, name): answer("v")
    else: bus.replyError(m, "org.freedesktop.DBus.Error.UnknownProperty", name)
  of IfProps & ".GetAll":
    let iface = r.str()
    let a = w.beginArray(8)
    for name in propNames(iface):
      var e: DBusWriter
      e.buf = w.buf
      e.struct()
      e.str(name)
      if e.getProperty(i, iface, name): w.buf = e.buf
    w.endArray(a)
    answer("a{sv}")
  of IfProps & ".Set":
    let iface = r.str()
    let name = r.str()
    let v = r.variant()
    if iface == IfApplication and name == "Id": appId = int32(v.num)
    elif iface == IfValue and name == "CurrentValue" and i >= 0:
      let t = if v.num == float(int(v.num)): $int(v.num) else: $v.num
      ask(aaSetValue, i, t, v.num)
    answer("")
  of IfAccessible & ".GetChildAtIndex":
    let k = int(r.i32())
    let ks = kids(i)
    w.refTo(if k >= 0 and k < ks.len: ks[k] else: -1)
    answer("(so)")
  of IfAccessible & ".GetChildren":
    let a = w.beginArray(8)
    for k in kids(i): w.refTo(k)
    w.endArray(a)
    answer("a(so)")
  of IfAccessible & ".GetIndexInParent":
    let p = parentOf(i)
    w.i32(int32(if p == -3: 0 else: kids(p).find(i)))
    answer("i")
  of IfAccessible & ".GetRelationSet":
    let a = w.beginArray(8)
    w.endArray(a)
    answer("a(ua(so))")
  of IfAccessible & ".GetRole":
    w.u32(if i == AppNode: 75'u32 else: roleNum(nodes[i].role))
    answer("u")
  of IfAccessible & ".GetRoleName", IfAccessible & ".GetLocalizedRoleName":
    w.str(if i == AppNode: "application" else: roleName(nodes[i].role))
    answer("s")
  of IfAccessible & ".GetState":
    let b = stateBits(i)
    let a = w.beginArray(4)
    w.u32(b[0])
    w.u32(b[1])
    w.endArray(a)
    answer("au")
  of IfAccessible & ".GetAttributes":
    let a = w.beginArray(8)
    w.struct()
    w.str("toolkit")
    w.str(atspiToolkit)
    if i >= 0 and nodes[i].pos > 0:
      w.struct()
      w.str("posinset")
      w.str($nodes[i].pos)
      if nodes[i].count > 0:
        w.struct()
        w.str("setsize")
        w.str($nodes[i].count)
    if i >= 0 and nodes[i].level > 0:
      w.struct()
      w.str("level")
      w.str($nodes[i].level)
    if i >= 0 and nodes[i].key.len > 0:
      w.struct()
      w.str("keyshortcuts")
      w.str(nodes[i].key)
    w.endArray(a)
    answer("a{ss}")
  of IfAccessible & ".GetApplication":
    w.refTo(AppNode)
    answer("(so)")
  of IfAccessible & ".GetInterfaces":
    let a = w.beginArray(4)
    for f in interfacesOf(i): w.str(f)
    w.endArray(a)
    answer("as")
  of IfApplication & ".GetLocale":
    w.str(getEnv("LANG", "C").split('.')[0])
    answer("s")
  of IfComponent & ".GetExtents":
    let e = extents(i, r.u32())
    w.struct()
    w.i32(int32(e.x)); w.i32(int32(e.y)); w.i32(int32(e.w)); w.i32(int32(e.h))
    answer("(iiii)")
  of IfComponent & ".GetPosition":
    let e = extents(i, r.u32())
    w.i32(int32(e.x)); w.i32(int32(e.y))
    answer("ii")
  of IfComponent & ".GetSize":
    let e = extents(i, 1)
    w.i32(int32(e.w)); w.i32(int32(e.h))
    answer("ii")
  of IfComponent & ".Contains":
    let x = int(r.i32())
    let y = int(r.i32())
    let e = extents(i, r.u32())
    w.boolean(x >= e.x and y >= e.y and x < e.x + e.w and y < e.y + e.h)
    answer("b")
  of IfComponent & ".GetAccessibleAtPoint":
    let x = int(r.i32())
    let y = int(r.i32())
    let c = r.u32()
    var hit = -1
    for k in kids(i):
      let e = extents(k, c)
      if x >= e.x and y >= e.y and x < e.x + e.w and y < e.y + e.h: hit = k
    w.refTo(hit)
    answer("(so)")
  of IfComponent & ".GetLayer":
    w.u32(if i == 0: 7 else: 3)
    answer("u")
  of IfComponent & ".GetMDIZOrder":
    w.buf.add "\0\0"
    answer("n")
  of IfComponent & ".GrabFocus":
    ask(aaFocus, i)
    w.boolean(i >= 0)
    answer("b")
  of IfComponent & ".GetAlpha":
    w.f64(1.0)
    answer("d")
  of IfComponent & ".ScrollTo", IfComponent & ".ScrollToPoint":
    w.boolean(false)
    answer("b")
  of IfAction & ".GetActions":
    let a = w.beginArray(8)
    let n = actionName(i)
    if n.len > 0:
      w.struct()
      w.str(n)
      w.str("")
      w.str(if i >= 0: nodes[i].key else: "")
    w.endArray(a)
    answer("a(sss)")
  of IfAction & ".GetName", IfAction & ".GetLocalizedName":
    w.str(actionName(i))
    answer("s")
  of IfAction & ".GetDescription":
    w.str("")
    answer("s")
  of IfAction & ".GetKeyBinding":
    w.str(if i >= 0: nodes[i].key else: "")
    answer("s")
  of IfAction & ".DoAction":
    ask(aaPress, i)
    w.boolean(i >= 0)
    answer("b")
  of IfText & ".GetText":
    let a = int(r.i32())
    let b = int(r.i32())
    w.str(textSlice(textOf(i), a, b))
    answer("s")
  of IfText & ".GetCharacterAtOffset":
    let o = int(r.i32())
    let rs = textOf(i).toRunes
    w.i32(if o >= 0 and o < rs.len: int32(rs[o]) else: 0)
    answer("i")
  of IfText & ".GetStringAtOffset", IfText & ".GetTextAtOffset":
    let o = int(r.i32())
    var kind = r.u32()
    # (GetTextAtOffset's boundaries: 0 char, 1-2 word, 3-4 sentence, 5-6 line)
    if m.member == "GetTextAtOffset": kind = (if kind == 0: 0'u32 elif kind <= 2: 1'u32 elif kind <= 4: 2'u32 else: 3'u32)
    let s = textOf(i)
    let (a, b) = boundary(s, o, kind)
    w.str(textSlice(s, a, b))
    w.i32(int32(a))
    w.i32(int32(b))
    answer("sii")
  of IfText & ".GetTextBeforeOffset", IfText & ".GetTextAfterOffset":
    w.str("")
    w.i32(0)
    w.i32(0)
    answer("sii")
  of IfText & ".SetCaretOffset":
    ask(aaSetCaret, i, "", float(r.i32()))
    w.boolean(true)
    answer("b")
  of IfText & ".GetNSelections":
    w.i32(int32(if i >= 0 and nodes[i].selA != nodes[i].selB: 1 else: 0))
    answer("i")
  of IfText & ".GetSelection":
    w.i32(int32(if i >= 0: nodes[i].selA else: 0))
    w.i32(int32(if i >= 0: nodes[i].selB else: 0))
    answer("ii")
  of IfText & ".GetCharacterExtents", IfText & ".GetRangeExtents":
    discard r.i32()
    if m.member == "GetRangeExtents": discard r.i32()
    let e = extents(i, r.u32())
    w.i32(int32(e.x)); w.i32(int32(e.y)); w.i32(int32(e.w)); w.i32(int32(e.h))
    answer("iiii")
  of IfText & ".GetOffsetAtPoint":
    w.i32(-1)
    answer("i")
  of IfText & ".GetDefaultAttributes", IfText & ".GetDefaultAttributeSet":
    let a = w.beginArray(8)
    w.endArray(a)
    answer("a{ss}")
  of IfText & ".GetAttributeRun", IfText & ".GetAttributes":
    let o = int(r.i32())
    let a = w.beginArray(8)
    w.endArray(a)
    w.i32(int32(o))
    w.i32(int32(textOf(i).runeLen))
    answer("a{ss}ii")
  of IfEditable & ".SetTextContents":
    ask(aaSetValue, i, r.str())
    w.boolean(true)
    answer("b")
  of IfEditable & ".InsertText":
    let o = int(r.i32())
    let t = r.str()
    let s = textOf(i)
    let (x, _) = runeOffsets(s, o, o)
    ask(aaSetValue, i, s[0 ..< x] & t & s[x .. ^1])
    w.boolean(true)
    answer("b")
  of IfEditable & ".DeleteText":
    let a = int(r.i32())
    let b = int(r.i32())
    let s = textOf(i)
    let (x, y) = runeOffsets(s, a, b)
    ask(aaSetValue, i, s[0 ..< x] & s[y .. ^1])
    w.boolean(true)
    answer("b")
  else:
    bus.replyError(m, "org.freedesktop.DBus.Error.UnknownMethod",
                   m.iface & "." & m.member & " is not known")

# ---- events -----------------------------------------------------------------------

proc event(i: int; iface, member, detail: string; d1, d2: int; text = ""; isRef = -9) =
  ## An event of node `i` (AT-SPI's body: kind, two numbers, a variant, no
  ## properties).
  if bus == nil or bus.fd < 0 or not registered: return
  var w: DBusWriter
  w.str(detail)
  w.i32(int32(d1))
  w.i32(int32(d2))
  if isRef != -9:
    w.sig("(so)")
    w.refTo(isRef)
  elif text.len > 0:
    w.variantStr(text)
  else:
    w.variantInt(0)
  let a = w.beginArray(8)
  w.endArray(a)
  bus.signal(pathOf(i), iface, member, "siiva{sv}", w.buf)

proc stateEvent(i: int; name: string; on: bool) =
  event(i, EvObject, "StateChanged", name, ord(on), 0)

proc textChanged(i: int; old, now: string) =
  ## What changed in a text: the part taken out, the part put in.
  if old == now: return
  let o = old.toRunes
  let n = now.toRunes
  var p = 0
  while p < o.len and p < n.len and o[p] == n[p]: inc p
  var q = 0
  while q < o.len - p and q < n.len - p and o[o.len - 1 - q] == n[n.len - 1 - q]: inc q
  if o.len - p - q > 0:
    event(i, EvObject, "TextChanged", "delete", p, o.len - p - q, text = $o[p ..< o.len - q])
  if n.len - p - q > 0:
    event(i, EvObject, "TextChanged", "insert", p, n.len - p - q, text = $n[p ..< n.len - q])

proc atspiUpdate*(now: openArray[AccessNode]; focus: int) =
  ## The tree after a frame that changed it: what changed told as events.
  var old = move nodes
  let oldFocus = if focusAt >= 0 and focusAt < old.len: old[focusAt].id else: 0'u32
  nodes = @now
  focusAt = focus
  if not registered: return
  if not activated and nodes.len > 0:
    # (the window came up: screen readers read it and its focus)
    activated = true
    event(0, "org.a11y.atspi.Event.Window", "Activate", "", 0, 0, text = nodes[0].name)
  # (children gone and come, under the parents that stay)
  for k, n in old:
    if k > 0 and nodes.indexOfId(n.id) < 0:
      let p = if n.parent >= 0 and n.parent < old.len: nodes.indexOfId(old[n.parent].id) else: -1
      if p >= 0: event(p, EvObject, "ChildrenChanged", "remove", 0, 0)
  for k, n in nodes:
    let was = old.indexOfId(n.id)
    if was < 0:
      if k > 0 and n.parent >= 0:
        event(int(n.parent), EvObject, "ChildrenChanged", "add",
              kids(int(n.parent)).find(k), 0, isRef = k)
      continue
    let o = old[was]
    if o.name != n.name:
      event(k, EvObject, "PropertyChange", "accessible-name", 0, 0, text = n.name)
    for (st, name) in [(asChecked, "checked"), (asSelected, "selected"), (asExpanded, "expanded"),
                       (asPressed, "pressed"), (asMixed, "indeterminate")]:
      if (st in o.states) != (st in n.states): stateEvent(k, name, st in n.states)
    if (asDisabled in o.states) != (asDisabled in n.states):
      stateEvent(k, "enabled", asDisabled notin n.states)
      stateEvent(k, "sensitive", asDisabled notin n.states)
    if hasText(k):
      if o.value != n.value and n.role != arPasswordField: textChanged(k, o.value, n.value)
      if o.caret != n.caret:
        event(k, EvObject, "TextCaretMoved", "", n.caret, 0)
    if hasValue(k) and o.now != n.now:
      event(k, EvObject, "PropertyChange", "accessible-value", 0, 0)
  # (the focus last: a screen reader reads the control it moved to)
  let newFocus = if focusAt >= 0 and focusAt < nodes.len: nodes[focusAt].id else: 0'u32
  if newFocus != oldFocus:
    let was = nodes.indexOfId(oldFocus)
    if was >= 0: stateEvent(was, "focused", false)
    if focusAt >= 0: stateEvent(focusAt, "focused", true)

# ---- starting -----------------------------------------------------------------------

proc register() =
  ## Onto the accessibility bus, and into the registry's tree.
  if registered: return
  let addrMsg = session.callWait("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress")
  if addrMsg.kind != dkMethodReturn: return
  var r = addrMsg.reader()
  let a = r.str()
  if a.len == 0: return
  bus = connectBus(a)
  if bus == nil: return
  var w: DBusWriter
  w.objRef(bus.uniqueName, RootPath)
  let e = bus.callWait("org.a11y.atspi.Registry", RootPath, "org.a11y.atspi.Socket",
                       "Embed", "(so)", w.buf)
  if e.kind == dkMethodReturn:
    var er = e.reader()
    er.align(8)
    desktop.bus = er.str()
    desktop.path = er.str()
  registered = true
  accessListening = true
  if atspiWake != nil: atspiWake()

proc statusOn(): bool =
  ## Assistive tools are on in this session (org.a11y.Status).
  for prop in ["IsEnabled", "ScreenReaderEnabled"]:
    var w: DBusWriter
    w.str("org.a11y.Status")
    w.str(prop)
    let m = session.callWait("org.a11y.Bus", "/org/a11y/bus", IfProps, "Get", "ss", w.buf)
    if m.kind == dkMethodReturn:
      var r = m.reader()
      let v = r.variant()
      if v.ok and v.num != 0: return true

proc atspiStart*(): bool =
  ## Looks for AT-SPI (once): true when the session has it. The program
  ## registers at once when assistive tools are on (or $RETRO_ACCESS=1),
  ## else when they are turned on later.
  if session != nil: return true
  session = sessionBus()
  if session == nil: return false
  # (told when assistive tools are turned on)
  var w: DBusWriter
  w.str("type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path='/org/a11y/bus'")
  session.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
               "AddMatch", "s", w.buf, noReply = true)
  if getEnv("RETRO_ACCESS") == "1" or statusOn(): register()
  true

proc atspiFds*(): seq[cint] =
  ## The sockets to wait on (with the window's events).
  if session != nil and session.fd >= 0: result.add session.fd
  if bus != nil and bus.fd >= 0: result.add bus.fd

proc atspiProcess*() =
  ## What came on the buses: questions answered, requests queued.
  if session != nil:
    for m in session.receive():
      if m.kind == dkSignal and m.member == "PropertiesChanged" and not registered:
        if statusOn(): register()
  if bus != nil:
    for m in bus.receive():
      if m.kind == dkMethodCall: handle(m)
    if bus.fd < 0:
      # (the accessibility bus went away)
      registered = false
      accessListening = false
      bus = nil

proc atspiBusName*(): string =
  ## The program's name on the accessibility bus ("" until it registered):
  ## where screen readers find its objects.
  if registered and bus != nil: bus.uniqueName else: ""
