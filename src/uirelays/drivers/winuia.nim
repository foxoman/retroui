# (included by winapi_driver.nim) Screen readers on Windows: UI Automation.
#
# The window answers WM_GETOBJECT with a provider for its tree (`access`):
# one COM object per node, with the interfaces Narrator, NVDA and JAWS ask
# for -- the node itself, its place in the tree (fragment), and the patterns
# its role has (invoke, toggle, value, range, selection item, expand and
# collapse). Nodes are found by id in the latest tree, so a provider of a
# control that is gone answers "not available". What a screen reader asks
# for goes into `accessRequests`. uiautomationcore.dll and oleaut32.dll are
# loaded at run time: without them there is no screen reader support.

type
  UiaVariant {.pure.} = object
    ## (a VARIANT: its type, then its value)
    vt: uint16
    r1, r2, r3: uint16
    val: int64
    more: int64
  UiaRect {.pure.} = object
    left, top, width, height: float64
  UiaProv = object
    ## A node's provider: one vtable pointer for each interface (the order
    ## of `uiaIids`), so `this` of an interface is the slot of its vtable.
    vt: array[9, pointer]
    refs: int32
    id: uint32
    root: bool

const
  UiaSlots = 9
  UiaRootObjectId = -25
  ObjIdClient = -4
  VtEmpty = 0'u16
  VtI4 = 3'u16
  VtR8 = 5'u16
  VtBstr = 8'u16
  VtBool = 11'u16
  UiaENotAvailable = HRESULT(0x80040201'i32)
  uiaIids = [
    GUID(d1: 0xd6dd68d1'u32, d2: 0x86fd, d3: 0x4332, d4: [0x86'u8, 0x66, 0x9a, 0xbe, 0xde, 0xa2, 0xd2, 0x4c]),
    GUID(d1: 0xf7063da8'u32, d2: 0x8359, d3: 0x439c, d4: [0x92'u8, 0x97, 0xbb, 0xc5, 0x29, 0x9a, 0x7d, 0x87]),
    GUID(d1: 0x620ce2a5'u32, d2: 0xab8f, d3: 0x40a9, d4: [0x86'u8, 0xcb, 0xde, 0x3c, 0x75, 0x59, 0x9b, 0x58]),
    GUID(d1: 0x54fcb24b'u32, d2: 0xe18e, d3: 0x47a2, d4: [0xb4'u8, 0xd3, 0xec, 0xcb, 0xe7, 0x75, 0x99, 0xa2]),
    GUID(d1: 0x56d00bd0'u32, d2: 0xc4f4, d3: 0x433c, d4: [0xa8'u8, 0x36, 0x1a, 0x52, 0xa5, 0x7e, 0x08, 0x92]),
    GUID(d1: 0xc7935180'u32, d2: 0x6fb3, d3: 0x4201, d4: [0xb1'u8, 0x74, 0x7d, 0xf7, 0x3a, 0xdb, 0xf6, 0x4a]),
    GUID(d1: 0x36dc7aef'u32, d2: 0x33e6, d3: 0x4691, d4: [0xaf'u8, 0xe1, 0x2b, 0xe7, 0x27, 0x4b, 0x3d, 0x33]),
    GUID(d1: 0x2acad808'u32, d2: 0xb2d4, d3: 0x452d, d4: [0xa4'u8, 0x07, 0x91, 0xff, 0x1a, 0xd1, 0x67, 0xb2]),
    GUID(d1: 0xd847d3a5'u32, d2: 0xcab0, d3: 0x4a98, d4: [0x8c'u8, 0x32, 0xec, 0xb4, 0x5c, 0x59, 0xad, 0x24])]
  SlotSimple = 0
  SlotFragment = 1
  SlotRoot = 2
  SlotInvoke = 3
  SlotToggle = 4
  SlotValue = 5
  SlotRange = 6
  SlotSelItem = 7
  SlotExpand = 8

var
  uiaTree: seq[AccessNode]        ## the latest tree
  uiaFocus = -1
  uiaLoaded = 0                   ## 0 not tried, 1 loaded, -1 not there
  uiaReturn: proc (h: HWND; wp: WPARAM; lp: LPARAM; p: pointer): LRESULT {.stdcall.}
  uiaHost: proc (h: HWND; p: ptr pointer): HRESULT {.stdcall.}
  uiaRaiseEvent: proc (p: pointer; id: int32): HRESULT {.stdcall.}
  uiaRaiseProp: proc (p: pointer; id: int32; a, b: UiaVariant): HRESULT {.stdcall.}
  uiaRaiseStructure: proc (p: pointer; kind: int32; rid: ptr int32; n: int32): HRESULT {.stdcall.}
  uiaListening: proc (): BOOL {.stdcall.}
  sysAllocString: proc (s: WideCString): pointer {.stdcall.}
  safeArrayCreateVector: proc (vt: uint16; lo: int32; n: uint32): pointer {.stdcall.}
  safeArrayPutElement: proc (sa: pointer; idx: ptr int32; v: pointer): HRESULT {.stdcall.}
  uiaVtbls: array[UiaSlots, seq[pointer]]
  uiaComOn = false

proc uiaLoad(): bool =
  if uiaLoaded != 0: return uiaLoaded > 0
  uiaLoaded = -1
  let core = loadLib("uiautomationcore.dll")
  let ole = loadLib("oleaut32.dll")
  if core == nil or ole == nil: return false
  uiaReturn = cast[typeof(uiaReturn)](core.symAddr("UiaReturnRawElementProvider"))
  uiaHost = cast[typeof(uiaHost)](core.symAddr("UiaHostProviderFromHwnd"))
  uiaRaiseEvent = cast[typeof(uiaRaiseEvent)](core.symAddr("UiaRaiseAutomationEvent"))
  uiaRaiseProp = cast[typeof(uiaRaiseProp)](core.symAddr("UiaRaiseAutomationPropertyChangedEvent"))
  uiaRaiseStructure = cast[typeof(uiaRaiseStructure)](core.symAddr("UiaRaiseStructureChangedEvent"))
  uiaListening = cast[typeof(uiaListening)](core.symAddr("UiaClientsAreListening"))
  sysAllocString = cast[typeof(sysAllocString)](ole.symAddr("SysAllocString"))
  safeArrayCreateVector = cast[typeof(safeArrayCreateVector)](ole.symAddr("SafeArrayCreateVector"))
  safeArrayPutElement = cast[typeof(safeArrayPutElement)](ole.symAddr("SafeArrayPutElement"))
  if uiaReturn == nil or uiaHost == nil or sysAllocString == nil or
     safeArrayCreateVector == nil or safeArrayPutElement == nil: return false
  uiaLoaded = 1
  true

proc slotOf(this: pointer; slot: int): ptr UiaProv {.inline.} =
  cast[ptr UiaProv](cast[uint](this) - uint(slot * sizeof(pointer)))

proc nodeOf(p: ptr UiaProv): int =
  if p.root: (if uiaTree.len > 0: 0 else: -2)
  else: uiaTree.indexOfId(p.id)

proc newProv(i: int): pointer
proc provOf(i: int): pointer =
  ## A new provider of node `i` (a reference the caller owns), nil for -1.
  if i < 0: nil else: newProv(i)

proc uiaRequest(action: AccessAction; i: int; text = ""; num = 0.0) =
  if i < 0 or i >= uiaTree.len: return
  accessRequests.add AccessRequest(action: action, id: uiaTree[i].id, text: text, num: num)
  pushEvent(input.Event(kind: NoEvent))

proc bstr(s: string): pointer = sysAllocString(newWideCString(s))

proc setStr(v: ptr UiaVariant; s: string) =
  v.vt = VtBstr
  v.val = cast[int64](bstr(s))

proc setInt(v: ptr UiaVariant; n: int) =
  v.vt = VtI4
  v.val = int64(int32(n)) and 0xFFFFFFFF'i64

proc setBool(v: ptr UiaVariant; b: bool) =
  v.vt = VtBool
  v.val = if b: 0xFFFF'i64 else: 0

proc setNum(v: ptr UiaVariant; f: float) =
  v.vt = VtR8
  v.val = cast[int64](f)

proc controlType(r: AccessRole): int =
  case r
  of arWindow: 50032
  of arPane: 50033
  of arGroup: 50026
  of arLabel, arStatusBar: (if r == arStatusBar: 50017 else: 50020)
  of arButton, arToggleButton: 50000
  of arCheckBox: 50002
  of arRadioButton: 50013
  of arTextField, arTextArea, arPasswordField: 50004
  of arComboBox: 50003
  of arList: 50008
  of arListItem: 50007
  of arSlider: 50015
  of arSpinButton: 50016
  of arProgressBar: 50012
  of arScrollBar: 50014
  of arMenuBar: 50010
  of arMenu: 50009
  of arMenuItem: 50011
  of arToolBar: 50021
  of arTabList: 50018
  of arTab: 50019
  of arTree: 50023
  of arTreeItem: 50024
  of arTable: 50036
  of arRow: 50029
  of arCell: 50029
  of arColumnHeader: 50035
  of arDialog: 50032
  of arLink: 50005
  of arImage: 50006
  of arHeading: 50020
  of arSeparator: 50038
  of arToolTip: 50022
  of arAlert: 50020

proc hasPattern(i: int; slot: int): bool =
  if i < 0 or i >= uiaTree.len: return false
  let n = uiaTree[i]
  case slot
  of SlotInvoke: n.role in {arButton, arLink} or (n.role == arMenuItem and asExpandable notin n.states)
  of SlotToggle: n.role in {arCheckBox, arToggleButton}
  of SlotValue: n.role in {arTextField, arTextArea, arPasswordField, arComboBox}
  of SlotRange: n.role in {arSlider, arSpinButton, arProgressBar}
  of SlotSelItem: n.role in {arListItem, arTab, arRadioButton, arTreeItem}
  of SlotExpand: asExpandable in n.states
  else: false

proc screenRect(i: int): UiaRect =
  if i < 0 or i >= uiaTree.len: return
  var o = WINAPIPOINT(x: 0, y: 0)
  discard ClientToScreen(gHwnd, addr o)
  let n = uiaTree[i]
  UiaRect(left: float(o.x + n.x), top: float(o.y + n.y), width: float(n.w), height: float(n.h))

proc `==`(a, b: GUID): bool =
  a.d1 == b.d1 and a.d2 == b.d2 and a.d3 == b.d3 and a.d4 == b.d4

# ---- IUnknown, for every slot ----

template unknownProcs(slot: static int) =
  proc queryIface(this: pointer; riid: ptr GUID; ppv: ptr pointer): HRESULT {.stdcall.} =
    let p = slotOf(this, slot)
    if ppv == nil: return HRESULT(0x80004003'i32)
    ppv[] = nil
    var k = -1
    if riid[] == IID_IUnknown: k = SlotSimple
    else:
      for j in 0 ..< UiaSlots:
        if riid[] == uiaIids[j]: k = j
    if k < 0 or (k == SlotRoot and not p.root): return ENoInterface
    if k >= SlotInvoke and not hasPattern(nodeOf(p), k): return ENoInterface
    inc p.refs
    ppv[] = addr p.vt[k]
    0
  proc addRefIface(this: pointer): uint32 {.stdcall.} =
    let p = slotOf(this, slot)
    inc p.refs
    uint32(p.refs)
  proc releaseIface(this: pointer): uint32 {.stdcall.} =
    let p = slotOf(this, slot)
    dec p.refs
    result = uint32(max(0, p.refs))
    if p.refs <= 0: deallocShared(p)
  uiaVtbls[slot] = @[cast[pointer](queryIface), cast[pointer](addRefIface),
                     cast[pointer](releaseIface)]

proc uiaBuildVtables() =
  if uiaVtbls[0].len > 0: return
  block:
    unknownProcs(0)
  block:
    unknownProcs(1)
  block:
    unknownProcs(2)
  block:
    unknownProcs(3)
  block:
    unknownProcs(4)
  block:
    unknownProcs(5)
  block:
    unknownProcs(6)
  block:
    unknownProcs(7)
  block:
    unknownProcs(8)

  # IRawElementProviderSimple
  proc providerOptions(this: pointer; ret: ptr int32): HRESULT {.stdcall.} =
    ret[] = 0x1 or 0x20          # a server-side provider, called on the window's thread
    0
  proc patternProvider(this: pointer; pattern: int32; ret: ptr pointer): HRESULT {.stdcall.} =
    let p = slotOf(this, SlotSimple)
    ret[] = nil
    let slot = case pattern
      of 10000: SlotInvoke
      of 10015: SlotToggle
      of 10002: SlotValue
      of 10003: SlotRange
      of 10010: SlotSelItem
      of 10005: SlotExpand
      else: -1
    if slot >= 0 and hasPattern(nodeOf(p), slot):
      inc p.refs
      ret[] = addr p.vt[slot]
    0
  proc propertyValue(this: pointer; prop: int32; ret: ptr UiaVariant): HRESULT {.stdcall.} =
    let p = slotOf(this, SlotSimple)
    ret[] = UiaVariant(vt: VtEmpty)
    let i = nodeOf(p)
    if i == -1: return UiaENotAvailable
    if i < 0: return 0
    let n = uiaTree[i]
    case prop
    of 30003: ret.setInt(controlType(n.role))
    of 30005: (if n.name.len > 0: ret.setStr(n.name))
    of 30004: ret.setStr(roleName(n.role))
    of 30006: (if n.key.len > 0: ret.setStr(n.key))
    of 30008: ret.setBool(asFocused in n.states)
    of 30009: ret.setBool(asFocusable in n.states)
    of 30010: ret.setBool(asDisabled notin n.states)
    of 30011: ret.setStr($n.id)
    of 30013: (if n.help.len > 0: ret.setStr(n.help))
    of 30016: ret.setBool(true)
    of 30017: ret.setBool(n.role notin {arPane, arSeparator})
    of 30019: ret.setBool(n.role == arPasswordField)
    of 30022: ret.setBool(false)
    of 30024: ret.setStr("Win32")
    of 30174: ret.setBool(n.role == arDialog)
    of 30152: (if n.pos > 0: ret.setInt(n.pos))
    of 30153: (if n.count > 0: ret.setInt(n.count))
    of 30154: (if n.level > 0: ret.setInt(n.level))
    else: discard
    0
  proc hostProvider(this: pointer; ret: ptr pointer): HRESULT {.stdcall.} =
    let p = slotOf(this, SlotSimple)
    ret[] = nil
    if p.root: return uiaHost(gHwnd, ret)
    0
  uiaVtbls[SlotSimple].add [cast[pointer](providerOptions), cast[pointer](patternProvider),
                            cast[pointer](propertyValue), cast[pointer](hostProvider)]

  # IRawElementProviderFragment
  proc navigate(this: pointer; dir: int32; ret: ptr pointer): HRESULT {.stdcall.} =
    let p = slotOf(this, SlotFragment)
    ret[] = nil
    let i = nodeOf(p)
    if i == -1: return UiaENotAvailable
    if i < 0: return 0
    let parent = int(uiaTree[i].parent)
    var t = -1
    case dir
    of 0: t = if i == 0: -1 else: parent
    of 1, 2:
      if i != 0 and parent >= 0:
        let sib = uiaTree.childrenOf(parent)
        let k = sib.find(i)
        let j = if dir == 1: k + 1 else: k - 1
        if k >= 0 and j >= 0 and j < sib.len: t = sib[j]
    of 3, 4:
      let ks = uiaTree.childrenOf(i)
      if ks.len > 0: t = if dir == 3: ks[0] else: ks[^1]
    else: discard
    if t >= 0:
      let q = cast[ptr UiaProv](provOf(t))
      ret[] = addr q.vt[SlotFragment]
    0
  proc runtimeId(this: pointer; ret: ptr pointer): HRESULT {.stdcall.} =
    let p = slotOf(this, SlotFragment)
    ret[] = nil
    if p.root: return 0
    let sa = safeArrayCreateVector(VtI4, 0, 2)
    var k = 0'i32
    var v = 3'i32                       # UiaAppendRuntimeId
    discard safeArrayPutElement(sa, addr k, addr v)
    k = 1
    v = cast[int32](p.id)
    discard safeArrayPutElement(sa, addr k, addr v)
    ret[] = sa
    0
  proc boundingRect(this: pointer; ret: ptr UiaRect): HRESULT {.stdcall.} =
    let p = slotOf(this, SlotFragment)
    let i = nodeOf(p)
    if i == -1: return UiaENotAvailable
    ret[] = screenRect(i)
    0
  proc embeddedRoots(this: pointer; ret: ptr pointer): HRESULT {.stdcall.} =
    ret[] = nil
    0
  proc setFocusIface(this: pointer): HRESULT {.stdcall.} =
    uiaRequest(aaFocus, nodeOf(slotOf(this, SlotFragment)))
    0
  proc fragmentRoot(this: pointer; ret: ptr pointer): HRESULT {.stdcall.} =
    let q = cast[ptr UiaProv](newProv(-1))
    ret[] = addr q.vt[SlotRoot]
    0
  uiaVtbls[SlotFragment].add [cast[pointer](navigate), cast[pointer](runtimeId),
                              cast[pointer](boundingRect), cast[pointer](embeddedRoots),
                              cast[pointer](setFocusIface), cast[pointer](fragmentRoot)]

  # IRawElementProviderFragmentRoot
  proc fromPoint(this: pointer; x, y: float64; ret: ptr pointer): HRESULT {.stdcall.} =
    ret[] = nil
    var hit = -1
    for k in 0 ..< uiaTree.len:
      let r = screenRect(k)
      if x >= r.left and y >= r.top and x < r.left + r.width and y < r.top + r.height:
        hit = k                         # (the last one: the deepest, drawn over the rest)
    if hit >= 0:
      let q = cast[ptr UiaProv](provOf(hit))
      ret[] = addr q.vt[SlotFragment]
    0
  proc getFocusIface(this: pointer; ret: ptr pointer): HRESULT {.stdcall.} =
    ret[] = nil
    if uiaFocus > 0 and uiaFocus < uiaTree.len:
      let q = cast[ptr UiaProv](provOf(uiaFocus))
      ret[] = addr q.vt[SlotFragment]
    0
  uiaVtbls[SlotRoot].add [cast[pointer](fromPoint), cast[pointer](getFocusIface)]

  # the patterns
  proc invoke(this: pointer): HRESULT {.stdcall.} =
    uiaRequest(aaPress, nodeOf(slotOf(this, SlotInvoke)))
    0
  uiaVtbls[SlotInvoke].add cast[pointer](invoke)

  proc toggle(this: pointer): HRESULT {.stdcall.} =
    uiaRequest(aaPress, nodeOf(slotOf(this, SlotToggle)))
    0
  proc toggleState(this: pointer; ret: ptr int32): HRESULT {.stdcall.} =
    let i = nodeOf(slotOf(this, SlotToggle))
    ret[] = 0
    if i >= 0:
      if asMixed in uiaTree[i].states: ret[] = 2
      elif asChecked in uiaTree[i].states or asPressed in uiaTree[i].states: ret[] = 1
    0
  uiaVtbls[SlotToggle].add [cast[pointer](toggle), cast[pointer](toggleState)]

  proc setValue(this: pointer; v: WideCString): HRESULT {.stdcall.} =
    uiaRequest(aaSetValue, nodeOf(slotOf(this, SlotValue)), $v)
    0
  proc getValue(this: pointer; ret: ptr pointer): HRESULT {.stdcall.} =
    let i = nodeOf(slotOf(this, SlotValue))
    ret[] = bstr(if i >= 0 and uiaTree[i].role != arPasswordField: uiaTree[i].value else: "")
    0
  proc valueReadOnly(this: pointer; ret: ptr BOOL): HRESULT {.stdcall.} =
    let i = nodeOf(slotOf(this, SlotValue))
    ret[] = BOOL(ord(i < 0 or asReadOnly in uiaTree[i].states or uiaTree[i].role == arComboBox))
    0
  uiaVtbls[SlotValue].add [cast[pointer](setValue), cast[pointer](getValue),
                           cast[pointer](valueReadOnly)]

  proc rangeSet(this: pointer; v: float64): HRESULT {.stdcall.} =
    let t = if v == float(int(v)): $int(v) else: $v
    uiaRequest(aaSetValue, nodeOf(slotOf(this, SlotRange)), t, v)
    0
  template rangeGet(name, field: untyped) =
    proc name(this: pointer; ret: ptr float64): HRESULT {.stdcall.} =
      let i = nodeOf(slotOf(this, SlotRange))
      ret[] = if i >= 0: uiaTree[i].field else: 0.0
      0
  rangeGet(rangeValue, now)
  rangeGet(rangeMax, hi)
  rangeGet(rangeMin, lo)
  rangeGet(rangeStep, step)
  proc rangeReadOnly(this: pointer; ret: ptr BOOL): HRESULT {.stdcall.} =
    let i = nodeOf(slotOf(this, SlotRange))
    ret[] = BOOL(ord(i < 0 or uiaTree[i].role == arProgressBar))
    0
  proc rangeLarge(this: pointer; ret: ptr float64): HRESULT {.stdcall.} =
    let i = nodeOf(slotOf(this, SlotRange))
    ret[] = if i >= 0: max(uiaTree[i].step, (uiaTree[i].hi - uiaTree[i].lo) / 10) else: 0.0
    0
  uiaVtbls[SlotRange].add [cast[pointer](rangeSet), cast[pointer](rangeValue),
                           cast[pointer](rangeReadOnly), cast[pointer](rangeMax),
                           cast[pointer](rangeMin), cast[pointer](rangeLarge),
                           cast[pointer](rangeStep)]

  proc select(this: pointer): HRESULT {.stdcall.} =
    uiaRequest(aaPress, nodeOf(slotOf(this, SlotSelItem)))
    0
  proc unselect(this: pointer): HRESULT {.stdcall.} = 0
  proc isSelected(this: pointer; ret: ptr BOOL): HRESULT {.stdcall.} =
    let i = nodeOf(slotOf(this, SlotSelItem))
    ret[] = BOOL(ord(i >= 0 and (asSelected in uiaTree[i].states or asChecked in uiaTree[i].states)))
    0
  proc selContainer(this: pointer; ret: ptr pointer): HRESULT {.stdcall.} =
    let i = nodeOf(slotOf(this, SlotSelItem))
    ret[] = nil
    if i > 0:
      let q = cast[ptr UiaProv](provOf(int(uiaTree[i].parent)))
      if q != nil: ret[] = addr q.vt[SlotSimple]
    0
  uiaVtbls[SlotSelItem].add [cast[pointer](select), cast[pointer](select),
                             cast[pointer](unselect), cast[pointer](isSelected),
                             cast[pointer](selContainer)]

  proc expand(this: pointer): HRESULT {.stdcall.} =
    let i = nodeOf(slotOf(this, SlotExpand))
    if i >= 0 and asExpanded notin uiaTree[i].states: uiaRequest(aaPress, i)
    0
  proc collapse(this: pointer): HRESULT {.stdcall.} =
    let i = nodeOf(slotOf(this, SlotExpand))
    if i >= 0 and asExpanded in uiaTree[i].states: uiaRequest(aaPress, i)
    0
  proc expandState(this: pointer; ret: ptr int32): HRESULT {.stdcall.} =
    let i = nodeOf(slotOf(this, SlotExpand))
    ret[] = if i >= 0 and asExpanded in uiaTree[i].states: 1 else: 0
    0
  uiaVtbls[SlotExpand].add [cast[pointer](expand), cast[pointer](collapse),
                            cast[pointer](expandState)]

proc newProv(i: int): pointer =
  ## A provider of node `i` (-1: the window's root), its one reference the
  ## caller's.
  uiaBuildVtables()
  let p = cast[ptr UiaProv](allocShared0(sizeof(UiaProv)))
  for k in 0 ..< UiaSlots: p.vt[k] = addr uiaVtbls[k][0]
  p.refs = 1
  p.root = i <= 0
  p.id = if i > 0 and i < uiaTree.len: uiaTree[i].id else: 1'u32
  addr p.vt[SlotSimple]

proc releaseProv(p: pointer) =
  if p != nil:
    let r = cast[proc (this: pointer): uint32 {.stdcall.}](cast[ptr array[3, pointer]](cast[ptr pointer](p)[])[2])
    discard r(p)

proc uiaGetObject(hwnd: HWND; wp: WPARAM; lp: LPARAM; handled: var bool): LRESULT =
  ## WM_GETOBJECT: a screen reader asks for the window's tree.
  let id = cast[int32](lp)
  if id != UiaRootObjectId and id != ObjIdClient: return 0
  if not uiaLoad(): return 0
  if not uiaComOn:
    uiaComOn = true
    discard OleInitialize(nil)
  if not accessListening:
    # (a screen reader is there: the tree is built from the next frame on)
    accessListening = true
    pushEvent(input.Event(kind: NoEvent))
  let root = newProv(-1)
  result = uiaReturn(hwnd, wp, lp, root)
  releaseProv(root)
  handled = true

proc uiaUpdate(nodes: openArray[AccessNode]; focus: int) =
  ## The tree after a frame that changed it: the screen reader told what changed.
  let old = move uiaTree
  let oldFocus = if uiaFocus >= 0 and uiaFocus < old.len: old[uiaFocus].id else: 0'u32
  uiaTree = @nodes
  uiaFocus = focus
  if uiaLoaded <= 0: return
  if uiaListening != nil and uiaListening() == 0: return
  var sameShape = old.len == uiaTree.len
  if sameShape:
    for k in 0 ..< old.len:
      if old[k].id != uiaTree[k].id or old[k].parent != uiaTree[k].parent:
        sameShape = false
        break
  if not sameShape and uiaRaiseStructure != nil:
    let root = newProv(-1)
    discard uiaRaiseStructure(root, 2, nil, 0)     # (its children made anew)
    releaseProv(root)
  if uiaRaiseProp != nil:
    for k in 1 ..< uiaTree.len:
      let was = old.indexOfId(uiaTree[k].id)
      if was < 0: continue
      let o = old[was]
      let n = uiaTree[k]
      template changed(prop: int32; setA, setB: untyped) =
        let p = newProv(k)
        var a {.inject.}, b {.inject.}: UiaVariant
        setA
        setB
        discard uiaRaiseProp(p, prop, a, b)
        releaseProv(p)
      if o.name != n.name: changed(30005, addr(a).setStr(o.name), addr(b).setStr(n.name))
      if o.value != n.value and n.role notin {arPasswordField}:
        changed(30045, addr(a).setStr(o.value), addr(b).setStr(n.value))
      if o.now != n.now and n.role in {arSlider, arSpinButton, arProgressBar}:
        changed(30047, addr(a).setNum(o.now), addr(b).setNum(n.now))
      if (asChecked in o.states) != (asChecked in n.states) and n.role in {arCheckBox, arToggleButton}:
        changed(30086, addr(a).setInt(ord(asChecked in o.states)), addr(b).setInt(ord(asChecked in n.states)))
      if (asSelected in o.states) != (asSelected in n.states) or
         ((asChecked in o.states) != (asChecked in n.states) and n.role == arRadioButton):
        changed(30079, addr(a).setBool(not (asSelected in n.states or asChecked in n.states)),
                       addr(b).setBool(asSelected in n.states or asChecked in n.states))
      if (asExpanded in o.states) != (asExpanded in n.states):
        changed(30070, addr(a).setInt(ord(asExpanded in o.states)), addr(b).setInt(ord(asExpanded in n.states)))
  let newFocus = if uiaFocus >= 0 and uiaFocus < uiaTree.len: uiaTree[uiaFocus].id else: 0'u32
  if newFocus != oldFocus and uiaFocus > 0 and uiaRaiseEvent != nil:
    let p = newProv(uiaFocus)
    discard uiaRaiseEvent(p, 20005)
    releaseProv(p)

proc uiaStart(): bool =
  ## Screen readers come by WM_GETOBJECT: true when UI Automation is there.
  uiaLoad()

proc uiaRootProvider*(): pointer =
  ## The window's UI Automation provider (an IRawElementProviderSimple, one
  ## reference yours): for a program that hands its tree on itself, and for
  ## tests. nil when UI Automation is not there.
  if not uiaLoad(): return nil
  newProv(-1)
