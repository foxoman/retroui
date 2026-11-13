## The app's icon where the system keeps icons of running programs, with a
## tip and a menu, as Qt's QSystemTrayIcon: the notification area on
## Windows, the status area on Linux (StatusNotifierItem: KDE, XFCE, Cinnamon,
## GNOME with the AppIndicator extension), the menu bar on macOS.
##
## .. code-block:: nim
##   import retroui, retroui/tray
##   const iconPng = staticRead("icon.png")
##   app "Timer", 300, 120:
##     let t = trayIcon(iconPng, "Timer: 4 minutes left", ["&Show", "&Pause", "-", "E&xit"])
##     if t.clicked: showWindow()
##     case t.picked
##     of 0: showWindow()
##     of 1: paused = not paused
##     of 3: quitApp()
##     else: discard
##
## Call it every frame while the icon should be there; a frame without it
## takes it away. "-" in `menu` is a separator. `trayIconShown` says
## whether this system showed it (no status area: false). Phones and web
## pages have none (false, no events).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/locks
import core

type
  TrayEvent* = object
    ## What the user did with the icon since the last frame.
    clicked*: bool          ## the icon was clicked (the left button)
    picked*: int            ## the menu's item chosen (its index; -1: none)

var
  trayLock: Lock
  pendingClick = false      # guarded by trayLock
  pendingPick = -1          # guarded by trayLock
  trayShown = false
  trayWanted = -1           # (the frame the icon was last asked in)
  trayHooked = false
  curPng, curTip: string
  curMenu: seq[string]
initLock trayLock

proc noteClick() {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock trayLock: pendingClick = true

proc notePick(i: int) {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock trayLock: pendingPick = i

proc plainItem(s: string): string =
  ## (a menu item's text as the systems take it: "&&" an "&", a lone "&"
  ## left out -- Windows keeps its own: it underlines the letter)
  var i = 0
  while i < s.len:
    if s[i] == '&':
      if i + 1 < s.len and s[i + 1] == '&':
        result.add '&'
        inc i
    else: result.add s[i]
    inc i

# ---- Windows: Shell_NotifyIcon, from a thread and a window of its own ---------------------------

when defined(windows):
  import std/widestrs
  import imaging
  import uirelays/drivers/winapi_driver

  type
    WinGuid = object
      d1: uint32
      d2, d3: uint16
      d4: array[8, uint8]
    NotifyIconData = object
      cbSize: uint32
      hWnd: pointer
      uID, uFlags, uCallbackMessage: uint32
      hIcon: pointer
      szTip: array[128, uint16]
      dwState, dwStateMask: uint32
      szInfo: array[256, uint16]
      uVersion: uint32
      szInfoTitle: array[64, uint16]
      dwInfoFlags: uint32
      guidItem: WinGuid
      hBalloonIcon: pointer
    WndProc = proc (h: pointer; msg: uint32; wp: uint; lp: int): int {.stdcall.}
    WndClassEx = object
      cbSize, style: uint32
      lpfnWndProc: WndProc
      cbClsExtra, cbWndExtra: int32
      hInstance, hIcon, hCursor, hbrBackground: pointer
      lpszMenuName, lpszClassName: pointer
      hIconSm: pointer
    WinMsg = object
      hwnd: pointer
      message: uint32
      wParam: uint
      lParam: int
      time: uint32
      x, y: int32
      priv: uint32
    WinPoint = object
      x, y: int32
    IconInfo = object
      fIcon: int32
      xHotspot, yHotspot: uint32
      hbmMask, hbmColor: pointer
    BitmapInfoHeader = object
      biSize: uint32
      biWidth, biHeight: int32
      biPlanes, biBitCount: uint16
      biCompression, biSizeImage: uint32
      biXPelsPerMeter, biYPelsPerMeter: int32
      biClrUsed, biClrImportant: uint32

  proc Shell_NotifyIconW(msg: uint32; data: ptr NotifyIconData): int32 {.stdcall, dynlib: "shell32", importc.}
  proc RegisterClassExW(wc: ptr WndClassEx): uint16 {.stdcall, dynlib: "user32", importc.}
  proc CreateWindowExW(ex: uint32; cls, name: pointer; style: uint32; x, y, w, h: int32;
                       parent, menu, inst, param: pointer): pointer {.stdcall, dynlib: "user32", importc.}
  proc DefWindowProcW(h: pointer; msg: uint32; wp: uint; lp: int): int {.stdcall, dynlib: "user32", importc.}
  proc GetMessageW(m: ptr WinMsg; h: pointer; lo, hi: uint32): int32 {.stdcall, dynlib: "user32", importc.}
  proc TranslateMessage(m: ptr WinMsg): int32 {.stdcall, dynlib: "user32", importc.}
  proc DispatchMessageW(m: ptr WinMsg): int {.stdcall, dynlib: "user32", importc.}
  proc PostMessageW(h: pointer; msg: uint32; wp: uint; lp: int): int32 {.stdcall, dynlib: "user32", importc.}
  proc GetModuleHandleW(name: pointer): pointer {.stdcall, dynlib: "kernel32", importc.}
  proc CreatePopupMenu(): pointer {.stdcall, dynlib: "user32", importc.}
  proc AppendMenuW(m: pointer; flags: uint32; id: uint; text: pointer): int32 {.stdcall, dynlib: "user32", importc.}
  proc TrackPopupMenu(m: pointer; flags: uint32; x, y, r: int32; h: pointer; rc: pointer): int32 {.stdcall, dynlib: "user32", importc.}
  proc DestroyMenu(m: pointer): int32 {.stdcall, dynlib: "user32", importc.}
  proc GetCursorPos(p: ptr WinPoint): int32 {.stdcall, dynlib: "user32", importc.}
  proc SetForegroundWindow(h: pointer): int32 {.stdcall, dynlib: "user32", importc.}
  proc CreateIconIndirect(ii: ptr IconInfo): pointer {.stdcall, dynlib: "user32", importc.}
  proc DestroyIcon(h: pointer): int32 {.stdcall, dynlib: "user32", importc.}
  proc CreateBitmap(w, h: int32; planes, bits: uint32; data: pointer): pointer {.stdcall, dynlib: "gdi32", importc.}
  proc CreateDIBSection(dc: pointer; bi: ptr BitmapInfoHeader; usage: uint32; bits: ptr pointer;
                        sec: pointer; off: uint32): pointer {.stdcall, dynlib: "gdi32", importc.}
  proc DeleteObject(o: pointer): int32 {.stdcall, dynlib: "gdi32", importc.}

  const
    WmApp = 0x8000'u32
    WmTrayIcon = WmApp + 7      # the icon's events
    WmTrayUpdate = WmApp + 8    # the app changed the icon, its tip or its menu
    WmTrayGone = WmApp + 9      # the app took it away
    WmLButtonUp = 0x0202'u32
    WmRButtonUp = 0x0205'u32
    WmContextMenu = 0x007B'u32
    NimAdd = 0'u32
    NimModify = 1'u32
    NimDelete = 2'u32
    NifMessage = 1'u32
    NifIcon = 2'u32
    NifTip = 4'u32

  var
    winThread: Thread[void]
    winWnd: pointer             # (the tray thread's window; guarded by trayLock)
    winStarted = false
    winIcon: pointer            # (the tray thread's)
    winAdded = false            # (the tray thread's)
    shared: tuple[png, tip: string; menu: seq[string]]   # guarded by trayLock

  proc iconOfPng(png: string): pointer =
    ## (an HICON of the PNG, 32 x 32, its alpha kept)
    let b = try: decodePng(png) except CatchableError: nil
    if b == nil or b.w <= 0: return nil
    let n = 32
    var bi = BitmapInfoHeader(biSize: uint32(sizeof(BitmapInfoHeader)), biWidth: int32(n),
                              biHeight: int32(-n), biPlanes: 1, biBitCount: 32)
    var bits: pointer
    let color = CreateDIBSection(nil, addr bi, 0, addr bits, nil, 0)
    if color == nil or bits == nil: return nil
    let px = cast[ptr UncheckedArray[uint32]](bits)
    for y in 0 ..< n:
      for x in 0 ..< n:
        let p = b.px[(y * b.h div n) * b.w + (x * b.w div n)]
        let a = p shr 24
        # (premultiplied, as Windows draws icons with alpha)
        let r = ((p shr 16) and 0xFF) * a div 255
        let g = ((p shr 8) and 0xFF) * a div 255
        let bl = (p and 0xFF) * a div 255
        px[y * n + x] = (a shl 24) or (r shl 16) or (g shl 8) or bl
    var mask = newSeq[uint8](n * n div 8)
    let maskBm = CreateBitmap(int32(n), int32(n), 1, 1, addr mask[0])
    var ii = IconInfo(fIcon: 1, hbmMask: maskBm, hbmColor: color)
    result = CreateIconIndirect(addr ii)
    discard DeleteObject(maskBm)
    discard DeleteObject(color)

  proc putWide[N: static int](dst: var array[N, uint16]; s: string) =
    let w = newWideCString(s)
    var n = 0
    while n < N - 1 and cast[uint16](w[n]) != 0: inc n
    for i in 0 ..< n: dst[i] = cast[uint16](w[i])
    dst[n] = 0

  proc winUpdate(h: pointer) =
    ## (the tray thread: the icon added or brought up to date)
    var png, tip: string
    {.cast(gcsafe).}:
      withLock trayLock:
        png = shared.png
        tip = shared.tip
    let ic = iconOfPng(png)
    var d = NotifyIconData(cbSize: uint32(sizeof(NotifyIconData)), hWnd: h, uID: 7,
                           uFlags: NifMessage or NifIcon or NifTip, uCallbackMessage: WmTrayIcon,
                           hIcon: ic)
    d.szTip.putWide(tip)
    if winAdded: discard Shell_NotifyIconW(NimModify, addr d)
    else: winAdded = Shell_NotifyIconW(NimAdd, addr d) != 0
    if winIcon != nil: discard DestroyIcon(winIcon)
    winIcon = ic

  proc winRemove(h: pointer) =
    if winAdded:
      var d = NotifyIconData(cbSize: uint32(sizeof(NotifyIconData)), hWnd: h, uID: 7)
      discard Shell_NotifyIconW(NimDelete, addr d)
      winAdded = false

  proc wake() =
    ## (the app's loop woken: a frame takes the event)
    let app = winWindow()
    if app != nil: discard PostMessageW(app, 0, 0, 0)           # WM_NULL

  proc winMenu(h: pointer) =
    ## (the menu at the pointer; the item chosen noted)
    var items: seq[string]
    {.cast(gcsafe).}:
      withLock trayLock: items = shared.menu
    if items.len == 0: return
    let m = CreatePopupMenu()
    for i, it in items:
      if it == "-": discard AppendMenuW(m, 0x800, 0, nil)      # MF_SEPARATOR
      else:
        let w = newWideCString(it)
        discard AppendMenuW(m, 0, uint(i + 1), addr w[0])
    var p: WinPoint
    discard GetCursorPos(addr p)
    discard SetForegroundWindow(h)            # (else the menu stays when clicked away)
    let got = TrackPopupMenu(m, 0x0100 or 0x0002, p.x, p.y, 0, h, nil)   # TPM_RETURNCMD, TPM_RIGHTBUTTON
    discard PostMessageW(h, 0, 0, 0)
    discard DestroyMenu(m)
    if got > 0:
      notePick(got - 1)
      wake()

  proc winProc(h: pointer; msg: uint32; wp: uint; lp: int): int {.stdcall.} =
    case msg
    of WmTrayIcon:
      let ev = uint32(lp and 0xFFFF)
      if ev == WmLButtonUp:
        noteClick()
        wake()
      elif ev == WmRButtonUp or ev == WmContextMenu:
        winMenu(h)
      0
    of WmTrayUpdate:
      winUpdate(h)
      0
    of WmTrayGone:
      winRemove(h)
      0
    else: DefWindowProcW(h, msg, wp, lp)

  proc winLoop() {.thread.} =
    {.cast(gcsafe).}:
      let cls = newWideCString("RetroTrayIcon")
      var wc = WndClassEx(cbSize: uint32(sizeof(WndClassEx)), lpfnWndProc: winProc,
                          hInstance: GetModuleHandleW(nil), lpszClassName: addr cls[0])
      discard RegisterClassExW(addr wc)
      let h = CreateWindowExW(0, addr cls[0], addr cls[0], 0, 0, 0, 0, 0,
                              cast[pointer](-3), nil, wc.hInstance, nil)     # HWND_MESSAGE
      withLock trayLock: winWnd = h
      if h == nil: return
      winUpdate(h)
      var m: WinMsg
      while GetMessageW(addr m, nil, 0, 0) > 0:
        discard TranslateMessage(addr m)
        discard DispatchMessageW(addr m)
      winRemove(h)

  proc backendShow(png, tip: string; menu: seq[string]): bool =
    {.cast(gcsafe).}:
      withLock trayLock:
        shared = (png, tip, menu)
    if not winStarted:
      winStarted = true
      createThread(winThread, winLoop)
      return true
    var h: pointer
    withLock trayLock: h = winWnd
    if h != nil: discard PostMessageW(h, WmTrayUpdate, 0, 0)
    true

  proc backendHide() =
    var h: pointer
    withLock trayLock: h = winWnd
    if h != nil: discard PostMessageW(h, WmTrayGone, 0, 0)

# ---- Linux and BSD: StatusNotifierItem over D-Bus, with its menu (dbusmenu) ----------------------

elif (defined(linux) or defined(bsd)) and not defined(android) and not defined(wasm):
  import std/[os, strutils]
  import imaging
  import uirelays/[dbus, input]

  const
    ItemPath = "/StatusNotifierItem"
    MenuPath = "/MenuBar"
    ItemIface = "org.kde.StatusNotifierItem"
    MenuIface = "com.canonical.dbusmenu"
    PropsIface = "org.freedesktop.DBus.Properties"

  var
    bus: DBusConn
    busName = ""
    registered = false
    revision = 1'u32
    hooked = false

  proc pixmap(w: var DBusWriter; png: string) =
    ## (an a(iiay): the icon in ARGB, network order, at 22 and 32 pixels)
    let b = try: decodePng(png) except CatchableError: nil
    let a = w.beginArray(8)
    if b != nil and b.w > 0:
      for n in [22, 32]:
        w.struct()
        w.i32(int32(n))
        w.i32(int32(n))
        w.u32(uint32(n * n * 4))
        for y in 0 ..< n:
          for x in 0 ..< n:
            let p = b.px[(y * b.h div n) * b.w + (x * b.w div n)]
            w.u8(uint8(p shr 24)); w.u8(uint8(p shr 16)); w.u8(uint8(p shr 8)); w.u8(uint8(p))
    w.endArray(a)

  proc itemProp(w: var DBusWriter; name: string): bool =
    ## (a property of the item, as a variant; false: none of that name)
    case name
    of "Category": w.variantStr("ApplicationStatus")
    of "Id": w.variantStr(getAppFilename().extractFilename)
    of "Title": w.variantStr(curTip)
    of "Status": w.variantStr("Active")
    of "WindowId": w.variantInt(0)
    of "IconName": w.variantStr("")
    of "IconPixmap":
      w.sig("a(iiay)")
      w.pixmap(curPng)
    of "ToolTip":
      w.sig("(sa(iiay)ss)")
      w.struct()
      w.str("")
      let a = w.beginArray(8)
      w.endArray(a)
      w.str(curTip)
      w.str("")
    of "ItemIsMenu": w.variantBool(false)
    of "Menu":
      w.sig("o")
      w.str(MenuPath)
    else: return false
    true

  proc menuItem(w: var DBusWriter; id: int; label: string; separator: bool; children: seq[string]) =
    ## (a (ia{sv}av) of dbusmenu: an item, its properties, its children)
    w.struct()
    w.i32(int32(id))
    let props = w.beginArray(8)
    if id == 0:
      w.struct(); w.str("children-display"); w.variantStr("submenu")
    elif separator:
      w.struct(); w.str("type"); w.variantStr("separator")
    else:
      w.struct(); w.str("label"); w.variantStr(label.replace("&&", "\1").replace("&", "_").replace("\1", "&"))
    w.endArray(props)
    let kids = w.beginArray(1)
    for i, c in children:
      w.sig("(ia{sv}av)")
      w.menuItem(i + 1, c, c == "-", @[])
    w.endArray(kids)

  proc handle(m: DBusMsg): bool =
    ## (a call to the item or its menu answered; true: the app wants a frame)
    if m.kind != dkMethodCall: return false
    var r = m.reader()
    var w: DBusWriter
    case m.iface & "." & m.member
    of PropsIface & ".Get":
      let iface = r.str()
      let name = r.str()
      if iface == ItemIface and w.itemProp(name): bus.reply(m, "v", w.buf)
      elif iface == MenuIface and name == "Version": (w.variantU32(3); bus.reply(m, "v", w.buf))
      elif iface == MenuIface and name == "Status": (w.variantStr("normal"); bus.reply(m, "v", w.buf))
      elif iface == MenuIface and name == "TextDirection": (w.variantStr("ltr"); bus.reply(m, "v", w.buf))
      else: bus.replyError(m, "org.freedesktop.DBus.Error.UnknownProperty", name)
    of PropsIface & ".GetAll":
      let iface = r.str()
      let a = w.beginArray(8)
      if iface == ItemIface:
        for name in ["Category", "Id", "Title", "Status", "WindowId", "IconName", "IconPixmap",
                     "ToolTip", "ItemIsMenu", "Menu"]:
          w.struct()
          w.str(name)
          discard w.itemProp(name)
      elif iface == MenuIface:
        w.struct(); w.str("Version"); w.variantU32(3)
        w.struct(); w.str("Status"); w.variantStr("normal")
      w.endArray(a)
      bus.reply(m, "a{sv}", w.buf)
    of ItemIface & ".Activate", ItemIface & ".SecondaryActivate":
      bus.reply(m)
      noteClick()
      return true
    of ItemIface & ".ContextMenu", ItemIface & ".Scroll":
      bus.reply(m)
    of MenuIface & ".GetLayout":
      w.u32(revision)
      w.menuItem(0, "", false, curMenu)
      bus.reply(m, "u(ia{sv}av)", w.buf)
    of MenuIface & ".GetGroupProperties":
      let a = w.beginArray(8)
      w.endArray(a)
      bus.reply(m, "a(ia{sv})", w.buf)
    of MenuIface & ".AboutToShow":
      w.boolean(false)
      bus.reply(m, "b", w.buf)
    of MenuIface & ".AboutToShowGroup":
      let a = w.beginArray(4)
      w.endArray(a)
      let b = w.beginArray(4)
      w.endArray(b)
      bus.reply(m, "aiai", w.buf)
    of MenuIface & ".Event":
      let id = r.i32()
      let ev = r.str()
      bus.reply(m)
      if ev == "clicked" and id > 0:
        notePick(int(id) - 1)
        return true
    of MenuIface & ".EventGroup":
      let a = w.beginArray(4)
      w.endArray(a)
      bus.reply(m, "ai", w.buf)
    of "org.freedesktop.DBus.Introspectable.Introspect":
      w.str("<node><interface name=\"" & ItemIface & "\"/><interface name=\"" & MenuIface & "\"/></node>")
      bus.reply(m, "s", w.buf)
    else:
      if m.dest.len > 0: bus.replyError(m, "org.freedesktop.DBus.Error.UnknownMethod", m.member)
    false

  proc busFds(): seq[cint] {.nimcall, gcsafe.} =
    {.cast(gcsafe).}:
      if bus != nil and bus.fd >= 0: result.add bus.fd

  proc busReady(): bool {.nimcall, gcsafe.} =
    {.cast(gcsafe).}:
      if bus == nil: return false
      for m in bus.receive():
        if handle(m): result = true

  proc register(): bool =
    if bus == nil:
      bus = sessionBus()
      if bus == nil: return false
      busName = "org.kde.StatusNotifierItem-" & $getCurrentProcessId() & "-1"
      var w: DBusWriter
      w.str(busName)
      w.u32(4)                         # DBUS_NAME_FLAG_DO_NOT_QUEUE
      discard bus.callWait("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                           "RequestName", "su", w.buf)
      if not hooked:
        hooked = true
        addWaitSource(busFds, busReady)
    var w: DBusWriter
    w.str(busName)
    let ok = bus.callWait("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
                          "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem", "s", w.buf)
    ok.kind == dkMethodReturn

  proc backendShow(png, tip: string; menu: seq[string]): bool =
    let first = not registered
    let menuChanged = menu != curMenu
    curPng = png
    curTip = tip
    curMenu = menu
    if first:
      registered = register()
      return registered
    if bus == nil: return false
    bus.signal(ItemPath, ItemIface, "NewIcon")
    bus.signal(ItemPath, ItemIface, "NewToolTip")
    bus.signal(ItemPath, ItemIface, "NewTitle")
    if menuChanged:
      inc revision
      var w: DBusWriter
      w.u32(revision)
      w.i32(0)
      bus.signal(MenuPath, MenuIface, "LayoutUpdated", "ui", w.buf)
    true

  proc backendHide() =
    if bus != nil:
      bus.close()
      bus = nil
    registered = false

  proc backendPoll() =
    ## (the calls waiting answered now too: the drivers that do not wait
    ## on `waitSources` -- and a frame the app runs for its own reasons)
    discard busReady()

# ---- macOS: an NSStatusItem in the menu bar, its menu an NSMenu ---------------------------------

elif defined(macosx):
  import native

  proc objc_allocateClassPair(super: pointer; name: cstring; extra: int): pointer {.importc, cdecl.}
  proc objc_registerClassPair(cls: pointer) {.importc, cdecl.}
  proc class_addMethod(cls, name, imp: pointer; types: cstring): bool {.importc, cdecl.}

  var
    item: ObjcId
    target: ObjcId
    lastMenu: seq[string]
    lastPng: string

  proc onClick(self, cmd, sender: ObjcId) {.cdecl.} =
    noteClick()

  proc onPick(self, cmd, sender: ObjcId) {.cdecl.} =
    notePick(objcSend(int, sender, "tag"))

  proc targetObj(): ObjcId =
    if target != nil: return target
    var cls = objcClass("RetroTrayTarget")
    if cls == nil:
      cls = objc_allocateClassPair(objcClass("NSObject"), "RetroTrayTarget", 0)
      discard class_addMethod(cls, sel("clicked:"), cast[pointer](onClick), "v@:@")
      discard class_addMethod(cls, sel("picked:"), cast[pointer](onPick), "v@:@")
      objc_registerClassPair(cls)
    target = objcSend(ObjcId, objcSend(ObjcId, cls, "alloc"), "init")
    target

  proc backendShow(png, tip: string; menu: seq[string]): bool =
    autoreleasePool:
      if item == nil:
        let bar = objcSend(ObjcId, objcClass("NSStatusBar"), "systemStatusBar")
        item = objcSend(ObjcId, bar, "statusItemWithLength:", -1.0)      # NSVariableStatusItemLength
        if item == nil: return false
        discard objcSend(ObjcId, item, "retain")
      let button = objcSend(ObjcId, item, "button")
      if png != lastPng and button != nil:
        lastPng = png
        let data = objcSend(ObjcId, objcClass("NSData"), "dataWithBytes:length:",
                            cast[pointer](unsafeAddr png[0]), png.len)
        let img = objcSend(ObjcId, objcSend(ObjcId, objcClass("NSImage"), "alloc"),
                           "initWithData:", data)
        if img != nil:
          objcSend(void, img, "setSize:", 18.0, 18.0)
          objcSend(void, button, "setImage:", img)
      if button != nil:
        objcSend(void, button, "setToolTip:", nsString(tip))
      if menu != lastMenu:
        lastMenu = menu
        if menu.len == 0:
          objcSend(void, item, "setMenu:", ObjcId(nil))
          if button != nil:
            objcSend(void, button, "setTarget:", targetObj())
            objcSend(void, button, "setAction:", sel("clicked:"))
        else:
          let m = objcSend(ObjcId, objcSend(ObjcId, objcClass("NSMenu"), "alloc"), "init")
          for i, it in menu:
            if it == "-":
              objcSend(void, m, "addItem:", objcSend(ObjcId, objcClass("NSMenuItem"), "separatorItem"))
            else:
              let mi = objcSend(ObjcId, objcSend(ObjcId, objcClass("NSMenuItem"), "alloc"),
                                "initWithTitle:action:keyEquivalent:", nsString(plainItem(it)),
                                sel("picked:"), nsString(""))
              objcSend(void, mi, "setTarget:", targetObj())
              objcSend(void, mi, "setTag:", i)
              objcSend(void, m, "addItem:", mi)
          objcSend(void, item, "setMenu:", m)
    true

  proc backendHide() =
    if item != nil:
      let bar = objcSend(ObjcId, objcClass("NSStatusBar"), "systemStatusBar")
      objcSend(void, bar, "removeStatusItem:", item)
      objcSend(void, item, "release")
      item = nil
      lastMenu = @[]
      lastPng = ""

else:
  proc backendShow(png, tip: string; menu: seq[string]): bool = false
  proc backendHide() = discard

when not ((defined(linux) or defined(bsd)) and not defined(android) and not defined(wasm)):
  proc backendPoll() = discard

# ---- every system ----------------------------------------------------------------------------

proc trayFrameHook() {.nimcall.} =
  ## (a frame after one without `trayIcon`: the icon taken away)
  if trayShown and trayWanted < ui.frameNo - 1:
    trayShown = false
    backendHide()

proc trayIcon*(png: string; tip: string; menu: openArray[string] = []): TrayEvent =
  ## The app's icon (a PNG's bytes) in the system's tray with `tip` and the
  ## items of `menu` ("-": a separator); what the user did with it since the
  ## last frame. See the module's notes.
  result.picked = -1
  trayWanted = ui.frameNo
  if not trayHooked:
    trayHooked = true
    beginFrameHooks.add trayFrameHook
  let items = @menu
  if not trayShown or png != curPng or tip != curTip or items != curMenu:
    trayShown = backendShow(png, tip, items) or trayShown
    curPng = png
    curTip = tip
    curMenu = items
  backendPoll()
  withLock trayLock:
    result.clicked = pendingClick
    result.picked = pendingPick
    pendingClick = false
    pendingPick = -1
  if result.clicked or result.picked >= 0: ui.redraw = true

proc trayIconShown*(): bool = trayShown
  ## The icon is in the system's tray now (false: this system has none, or
  ## no host on Linux took it).

proc removeTrayIcon*() =
  ## Takes the icon away now (as a frame without `trayIcon` does).
  if trayShown:
    trayShown = false
    backendHide()
