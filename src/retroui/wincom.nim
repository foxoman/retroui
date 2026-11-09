## Windows' COM from Nim, for the kit's own modules (Media Foundation,
## the camera, the media keys): GUIDs written as text, a COM object's
## methods called by their place in its table, objects started and let
## go, BSTRs and HSTRINGs, and objects of the kit's own that Windows calls
## back. Nothing here is linked but ole32 and oleaut32, which every Windows
## has; the rest is loaded where it is used.
##
## .. code-block:: nim
##   var f: Com
##   if coCreate(guid"cacaf262-9370-4615-a13b-9f5539da4c0a",
##               guid"ec5ec8a9-c395-4314-9c77-54d7a935ff70", f):
##     discard f.call(17, proc (this: Com; ...): HRESULT {.stdcall.})(f, ...)
##     f.release()
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

when defined(windows):
  import std/[strutils, widestrs, dynlib]

  type
    HRESULT* = int32
      ## A COM call's answer: 0 (S_OK) and other numbers >= 0 succeeded.
    Guid* {.bycopy.} = object
      ## A COM GUID.
      d1*: uint32
      d2*, d3*: uint16
      d4*: array[8, uint8]
    Com* = ptr object
      ## A COM object: a pointer to its table of methods.
      vtbl*: ptr UncheckedArray[pointer]

  proc parseGuid*(s: string): Guid =
    ## "6fddc324-4e03-4bfe-b185-3d77768dc90f" (braces may be there) as a GUID.
    let h = s.strip(chars = {'{', '}', ' '}).replace("-", "")
    doAssert h.len == 32, "a GUID has 32 hex digits: " & s
    result.d1 = uint32(parseHexInt(h[0 ..< 8]))
    result.d2 = uint16(parseHexInt(h[8 ..< 12]))
    result.d3 = uint16(parseHexInt(h[12 ..< 16]))
    for i in 0 ..< 8: result.d4[i] = uint8(parseHexInt(h[16 + i * 2 ..< 18 + i * 2]))

  template guid*(s: static string): Guid =
    ## A GUID written as text, made when the program is compiled.
    const g = parseGuid(s)
    g

  proc `==`*(a, b: Guid): bool =
    a.d1 == b.d1 and a.d2 == b.d2 and a.d3 == b.d3 and a.d4 == b.d4

  proc succeeded*(h: HRESULT): bool {.inline.} = h >= 0
    ## The call worked.

  template call*(o: Com; slot: int; T: typedesc): untyped =
    ## The method in `slot` of `o` (0, 1, 2: IUnknown's), as a proc of type
    ## `T`, whose first parameter is the object.
    cast[T](o.vtbl[slot])

  proc addRef*(o: Com) =
    ## One more holder of `o`.
    if o != nil: discard o.call(1, proc (this: Com): uint32 {.stdcall, gcsafe.})(o)

  proc release*(o: Com) =
    ## Lets `o` go (nil: nothing).
    if o != nil: discard o.call(2, proc (this: Com): uint32 {.stdcall, gcsafe.})(o)

  proc queryInterface*(o: Com; iid: Guid; r: var Com): bool =
    ## `o` as the interface `iid` (`r`, to be released).
    r = nil
    if o == nil: return false
    var g = iid
    succeeded(o.call(0, proc (this: Com; iid: ptr Guid; r: ptr Com): HRESULT {.stdcall, gcsafe.})(
      o, addr g, addr r)) and r != nil

  proc CoInitializeEx(reserved: pointer; coInit: uint32): HRESULT
    {.stdcall, dynlib: "ole32", importc.}
  proc CoCreateInstance(clsid: ptr Guid; outer: pointer; ctx: uint32; iid: ptr Guid;
                        o: ptr Com): HRESULT {.stdcall, dynlib: "ole32", importc.}
  proc CoTaskMemFree(p: pointer) {.stdcall, dynlib: "ole32", importc.}
  proc SysAllocString(s: WideCString): pointer {.stdcall, dynlib: "oleaut32", importc.}
  proc SysFreeString(s: pointer) {.stdcall, dynlib: "oleaut32", importc.}

  var comReady {.threadvar.}: bool

  proc coInit*() =
    ## COM ready on this thread (apartment threaded, as the window's; once).
    if not comReady:
      comReady = true
      discard CoInitializeEx(nil, 2)

  proc coCreate*(clsid, iid: Guid; o: var Com): bool =
    ## A new object of class `clsid` as interface `iid` (in this process).
    coInit()
    var c = clsid
    var i = iid
    o = nil
    succeeded(CoCreateInstance(addr c, nil, 1, addr i, addr o)) and o != nil

  proc taskFree*(p: pointer) = CoTaskMemFree(p)
    ## Frees what COM gave with CoTaskMemAlloc.

  proc bstr*(s: string): pointer =
    ## `s` as a BSTR (to be freed with `freeBstr`).
    SysAllocString(newWideCString(s))

  proc freeBstr*(b: pointer) =
    ## Frees a BSTR (nil: nothing).
    if b != nil: SysFreeString(b)

  proc wideOf*(p: pointer): string =
    ## The text of a UTF-16 string COM gave ("" for nil); not freed.
    if p == nil: "" else: $cast[WideCString](p)

  # ---- WinRT: classes by name, HSTRINGs ------------------------------------------------------------

  var
    winrtState = 0
    roInit: proc (kind: int32): HRESULT {.stdcall, gcsafe.}
    roFactory: proc (cls: pointer; iid: ptr Guid; f: ptr Com): HRESULT {.stdcall, gcsafe.}
    hsCreate: proc (s: WideCString; n: uint32; h: ptr pointer): HRESULT {.stdcall, gcsafe.}
    hsDelete: proc (h: pointer): HRESULT {.stdcall, gcsafe.}
    hsBuffer: proc (h: pointer; n: ptr uint32): WideCString {.stdcall, gcsafe.}

  proc winrtAvailable*(): bool =
    ## Windows' runtime (Windows 8 and later) is there, loaded.
    if winrtState == 0:
      winrtState = -1
      let core = loadLib("combase.dll")
      if core != nil:
        roInit = cast[typeof(roInit)](core.symAddr("RoInitialize"))
        roFactory = cast[typeof(roFactory)](core.symAddr("RoGetActivationFactory"))
        hsCreate = cast[typeof(hsCreate)](core.symAddr("WindowsCreateString"))
        hsDelete = cast[typeof(hsDelete)](core.symAddr("WindowsDeleteString"))
        hsBuffer = cast[typeof(hsBuffer)](core.symAddr("WindowsGetStringRawBuffer"))
        if roInit != nil and roFactory != nil and hsCreate != nil and hsDelete != nil and
           hsBuffer != nil:
          winrtState = 1
    winrtState == 1

  proc hstring*(s: string): pointer =
    ## `s` as an HSTRING (to be freed with `freeHstring`; nil: "").
    if not winrtAvailable() or s.len == 0: return nil
    let w = newWideCString(s)
    discard hsCreate(w, uint32(w.len), addr result)

  proc freeHstring*(h: pointer) =
    ## Frees an HSTRING (nil: nothing).
    if h != nil and winrtAvailable(): discard hsDelete(h)

  proc hstringText*(h: pointer): string =
    ## The text of an HSTRING.
    if h == nil or not winrtAvailable(): return ""
    var n: uint32
    let p = hsBuffer(h, addr n)
    if p == nil: "" else: $p

  proc winrtFactory*(className: string; iid: Guid; f: var Com): bool =
    ## The activation factory (or statics) of WinRT class `className`, as
    ## interface `iid`.
    f = nil
    if not winrtAvailable(): return false
    coInit()
    let name = hstring(className)
    var i = iid
    result = succeeded(roFactory(name, addr i, addr f)) and f != nil
    freeHstring(name)

  # ---- objects of the kit's own that Windows calls -------------------------------------------------

  type
    Callback* = object
      ## A COM object made here: IUnknown and one method of the kit's
      ## (`Invoke`-like: the object, then two pointer-sized values), with a
      ## number to tell its uses apart and a pointer for the user. Made with
      ## `newCallback`; Windows holds it with AddRef and Release; freed when
      ## the last holder lets go.
      vtbl*: ptr array[4, pointer]
      refs*: int
      kind*: int
      user*: pointer
      iids*: array[3, Guid]   ## the interfaces it answers to (with IUnknown)
      handler*: proc (c: ptr Callback; a, b: pointer): HRESULT {.nimcall, gcsafe.}

  proc cbQuery(this: ptr Callback; iid: ptr Guid; obj: ptr pointer): HRESULT {.stdcall.} =
    const unknown = guid"00000000-0000-0000-C000-000000000046"
    const agile = guid"94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90"     # IAgileObject
    var ok = iid[] == unknown or iid[] == agile
    for g in this.iids:
      if g.d1 != 0 and iid[] == g: ok = true
    if not ok:
      obj[] = nil
      return cast[HRESULT](0x80004002'u32)              # E_NOINTERFACE
    obj[] = this
    discard atomicInc(this.refs)
    0

  proc cbAddRef(this: ptr Callback): uint32 {.stdcall.} =
    uint32(atomicInc(this.refs))

  proc cbRelease(this: ptr Callback): uint32 {.stdcall.} =
    let n = atomicDec(this.refs)
    if n <= 0: deallocShared(this)
    uint32(max(0, n))

  proc cbInvoke(this: ptr Callback; a, b: pointer): HRESULT {.stdcall.} =
    if this.handler == nil: 0 else: this.handler(this, a, b)

  var cbVtbl = [cast[pointer](cbQuery), cast[pointer](cbAddRef), cast[pointer](cbRelease),
                cast[pointer](cbInvoke)]

  proc newCallback*(kind: int; user: pointer;
                    handler: proc (c: ptr Callback; a, b: pointer): HRESULT {.nimcall, gcsafe.};
                    iids: openArray[Guid] = []): ptr Callback =
    ## A COM object whose fourth method calls `handler` (from any thread:
    ## keep it to plain values). One holder (released by whoever is given
    ## it, or with `release`).
    result = cast[ptr Callback](allocShared0(sizeof(Callback)))
    result.vtbl = addr cbVtbl
    result.refs = 1
    result.kind = kind
    result.user = user
    result.handler = handler
    for i, g in iids:
      if i < result.iids.len: result.iids[i] = g
