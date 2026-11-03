# WinAPI (GDI) backend driver. Sets all hooks from core/input and core/screen.
# Uses a double-buffered GDI approach: draw to an off-screen bitmap,
# BitBlt to window on refresh.

import ../coords, ../input, ../screen, ../services
import penaxes
import std/[widestrs, strutils, os]

{.passL: "-lgdi32 -luser32 -lkernel32".}

# ---- Win32 type definitions ----

type
  UINT = uint32
  DWORD = uint32
  LONG = int32
  BOOL = int32
  BYTE = uint8
  WORD = uint16
  WPARAM = uint
  LPARAM = int
  LRESULT = int
  ATOM = WORD
  HANDLE = pointer
  HWND = HANDLE
  HDC = HANDLE
  HINSTANCE = HANDLE
  HBRUSH = HANDLE
  HBITMAP = HANDLE
  HFONT = HANDLE
  HCURSOR = HANDLE
  HICON = HANDLE
  HGDIOBJ = HANDLE
  HMENU = HANDLE
  HRGN = HANDLE
  HGLOBAL = HANDLE
  COLORREF = DWORD

  WNDCLASSEXW {.pure.} = object
    cbSize: UINT
    style: UINT
    lpfnWndProc: proc (hwnd: HWND; msg: UINT; wp: WPARAM; lp: LPARAM): LRESULT {.stdcall.}
    cbClsExtra: int32
    cbWndExtra: int32
    hInstance: HINSTANCE
    hIcon: HICON
    hCursor: HCURSOR
    hbrBackground: HBRUSH
    lpszMenuName: ptr uint16
    lpszClassName: ptr uint16
    hIconSm: HICON

  MSG {.pure.} = object
    hwnd: HWND
    message: UINT
    wParam: WPARAM
    lParam: LPARAM
    time: DWORD
    x: LONG
    y: LONG

  WINAPIPOINT {.pure.} = object
    x, y: LONG

  WINAPIRECT {.pure.} = object
    left, top, right, bottom: LONG

  BITMAPINFOHEADER {.pure.} = object
    biSize: DWORD
    biWidth: LONG
    biHeight: LONG
    biPlanes: uint16
    biBitCount: uint16
    biCompression: DWORD
    biSizeImage: DWORD
    biXPelsPerMeter: LONG
    biYPelsPerMeter: LONG
    biClrUsed: DWORD
    biClrImportant: DWORD

  BITMAPINFO {.pure.} = object
    ## The colour table after the header is what a palettised bitmap needs and
    ## a 32-bit `BI_RGB` one does not, so the one entry here is only there to
    ## make the struct the shape the API expects.
    bmiHeader: BITMAPINFOHEADER
    bmiColors: array[1, DWORD]

  PAINTSTRUCT {.pure.} = object
    hdc: HDC
    fErase: BOOL
    rcPaint: WINAPIRECT
    fRestore: BOOL
    fIncUpdate: BOOL
    rgbReserved: array[32, BYTE]

  TEXTMETRICW {.pure.} = object
    tmHeight: LONG
    tmAscent: LONG
    tmDescent: LONG
    tmInternalLeading: LONG
    tmExternalLeading: LONG
    tmAveCharWidth: LONG
    tmMaxCharWidth: LONG
    tmWeight: LONG
    tmOverhang: LONG
    tmDigitizedAspectX: LONG
    tmDigitizedAspectY: LONG
    tmFirstChar: uint16
    tmLastChar: uint16
    tmDefaultChar: uint16
    tmBreakChar: uint16
    tmItalic: BYTE
    tmUnderlined: BYTE
    tmStruckOut: BYTE
    tmPitchAndFamily: BYTE
    tmCharSet: BYTE

  SIZE {.pure.} = object
    cx, cy: LONG

  POINTER_INFO {.pure.} = object
    ## Windows 8 and later: what a pointer (here a pen) reports with each message.
    pointerType: DWORD
    pointerId: UINT
    frameId: UINT
    pointerFlags: UINT
    sourceDevice: HANDLE
    hwndTarget: HWND
    ptPixelLocation: WINAPIPOINT
    ptHimetricLocation: WINAPIPOINT
    ptPixelLocationRaw: WINAPIPOINT
    ptHimetricLocationRaw: WINAPIPOINT
    dwTime: DWORD
    historyCount: UINT
    inputData: int32
    dwKeyStates: DWORD
    performanceCount: uint64
    buttonChangeType: int32

  POINTER_PEN_INFO {.pure.} = object
    pointerInfo: POINTER_INFO
    penFlags: UINT
    penMask: UINT
    pressure: UINT
    rotation: UINT
    tiltX: int32
    tiltY: int32

# ---- Win32 constants ----

const
  CS_HREDRAW = 0x0002'u32
  CS_VREDRAW = 0x0001'u32
  WS_OVERLAPPEDWINDOW = 0x00CF0000'u32
  WS_VISIBLE = 0x10000000'u32

  WM_DESTROY = 0x0002'u32
  WM_SIZE = 0x0005'u32
  WM_PAINT = 0x000F'u32
  WM_CLOSE = 0x0010'u32
  WM_QUIT = 0x0012'u32
  WM_ERASEBKGND = 0x0014'u32
  WM_KEYDOWN = 0x0100'u32
  WM_KEYUP = 0x0101'u32
  WM_CHAR = 0x0102'u32
  WM_SYSKEYDOWN = 0x0104'u32
  WM_SYSKEYUP = 0x0105'u32
  WM_SYSCHAR = 0x0106'u32
  WM_MOUSEMOVE = 0x0200'u32
  WM_LBUTTONDOWN = 0x0201'u32
  WM_LBUTTONUP = 0x0202'u32
  WM_RBUTTONDOWN = 0x0204'u32
  WM_RBUTTONUP = 0x0205'u32
  WM_MBUTTONDOWN = 0x0207'u32
  WM_XBUTTONDOWN = 0x020B'u32
  WM_XBUTTONUP = 0x020C'u32
  WM_MBUTTONUP = 0x0208'u32
  WM_MOUSEWHEEL = 0x020A'u32
  WM_SETFOCUS = 0x0007'u32
  WM_KILLFOCUS = 0x0008'u32
  WM_DPICHANGED = 0x02E0'u32
  WM_POINTERUPDATE = 0x0245'u32
  WM_POINTERDOWN = 0x0246'u32
  WM_POINTERUP = 0x0247'u32
  PT_PEN = 3'u32
  POINTER_FLAG_INCONTACT = 0x4'u32
  POINTER_FLAG_SECONDBUTTON = 0x20'u32

  PM_REMOVE = 0x0001'u32
  INFINITE = 0xFFFFFFFF'u32

  MK_LBUTTON = 0x0001'u32
  MK_RBUTTON = 0x0002'u32
  MK_MBUTTON = 0x0010'u32

  SW_SHOW = 5'i32
  SW_MAXIMIZE = 3'i32
  TRANSPARENT = 1
  OPAQUE = 2

  SRCCOPY = 0x00CC0020'u32
  BI_RGB = 0'u32          ## uncompressed, and for 32 bits a pixel that is
                          ## one `0x00RRGGBB` word each -- what `blitRGBA` has
  DIB_RGB_COLORS = 0'u32

  IDC_ARROW = cast[ptr uint16](32512)
  IDC_IBEAM = cast[ptr uint16](32513)
  IDC_WAIT = cast[ptr uint16](32514)
  IDC_CROSS = cast[ptr uint16](32515)
  IDC_HAND = cast[ptr uint16](32649)
  IDC_SIZENS = cast[ptr uint16](32645)
  IDC_SIZEWE = cast[ptr uint16](32644)
  IDC_SIZENWSE = cast[ptr uint16](32642)
  IDC_SIZENESW = cast[ptr uint16](32643)
  IDC_SIZEALL = cast[ptr uint16](32646)

  VK_BACK = 0x08'u32
  VK_TAB = 0x09'u32
  VK_RETURN = 0x0D'u32
  VK_ESCAPE = 0x1B'u32
  VK_SPACE = 0x20'u32
  VK_DELETE = 0x2E'u32
  VK_INSERT = 0x2D'u32
  VK_LEFT = 0x25'u32
  VK_UP = 0x26'u32
  VK_RIGHT = 0x27'u32
  VK_DOWN = 0x28'u32
  VK_PRIOR = 0x21'u32  # Page Up
  VK_NEXT = 0x22'u32   # Page Down
  VK_HOME = 0x24'u32
  VK_END = 0x23'u32
  VK_CAPITAL = 0x14'u32
  VK_F1 = 0x70'u32
  VK_F12 = 0x7B'u32
  VK_OEM_PLUS = 0xBB'u32
  VK_OEM_COMMA = 0xBC'u32
  VK_OEM_MINUS = 0xBD'u32
  VK_OEM_PERIOD = 0xBE'u32
  VK_OEM_2 = 0xBF'u32
  VK_SHIFT = 0x10'u32
  VK_CONTROL = 0x11'u32
  VK_MENU = 0x12'u32   # Alt

  FW_NORMAL = 400'i32
  DEFAULT_CHARSET = 1'u8
  OUT_TT_PRECIS = 4'u32
  CLIP_DEFAULT_PRECIS = 0'u32
  CLEARTYPE_QUALITY = 5'u32
  FF_DONTCARE = 0'u32
  DEFAULT_PITCH = 0'u32

  CF_UNICODETEXT = 13'u32
  GMEM_MOVEABLE = 0x0002'u32

  WAIT_TIMEOUT = 258'u32
  QS_ALLINPUT = 0x04FF'u32

  # a window without Windows' frame (the app draws its own)
  WS_POPUP = 0x80000000'u32
  WS_THICKFRAME = 0x00040000'u32
  WS_SYSMENU = 0x00080000'u32
  WS_MINIMIZEBOX = 0x00020000'u32
  WS_MAXIMIZEBOX = 0x00010000'u32
  WS_MINIMIZE = 0x20000000'u32
  WS_MAXIMIZE = 0x01000000'u32
  WS_FRAMELESS = WS_POPUP or WS_THICKFRAME or WS_SYSMENU or WS_MINIMIZEBOX or
                 WS_MAXIMIZEBOX
    ## Sized by its edges, snapped, minimized and maximized like any other
    ## window (and kept on the taskbar), with no part of it Windows draws:
    ## WM_NCCALCSIZE gives it all to the app.
  WM_GETMINMAXINFO = 0x0024'u32
  WM_NCCALCSIZE = 0x0083'u32
  WM_NCACTIVATE = 0x0086'u32
  WM_NCLBUTTONDOWN = 0x00A1'u32
  WM_SETCURSOR = 0x0020'u32
  WM_DROPFILES = 0x0233'u32
  HTCLIENT = 1'u
  WM_SYSCOMMAND = 0x0112'u32
  SC_SIZE = 0xF000'u32
  SC_MOVE = 0xF010'u32
  HTCAPTION = 2'u
  HTLEFT = 10'u
  HTRIGHT = 11'u
  HTTOP = 12'u
  HTTOPLEFT = 13'u
  HTTOPRIGHT = 14'u
  HTBOTTOM = 15'u
  HTBOTTOMLEFT = 16'u
  HTBOTTOMRIGHT = 17'u
  SW_MINIMIZE = 6'i32
  SW_RESTORE = 9'i32
  VK_LBUTTON = 0x01'i32
  GWL_STYLE = -16'i32
  SWP_NOSIZE = 0x0001'u32
  SWP_NOMOVE = 0x0002'u32
  SWP_NOZORDER = 0x0004'u32
  SWP_NOACTIVATE = 0x0010'u32
  SWP_FRAMECHANGED = 0x0020'u32
  SWP_NOOWNERZORDER = 0x0200'u32
  MONITOR_DEFAULTTONEAREST = 2'u32

type
  MONITORINFO {.pure.} = object
    cbSize: DWORD
    rcMonitor: WINAPIRECT
    rcWork: WINAPIRECT
    dwFlags: DWORD

  MINMAXINFO {.pure.} = object
    ptReserved, ptMaxSize, ptMaxPosition, ptMinTrackSize, ptMaxTrackSize: WINAPIPOINT

  NCCALCSIZE_PARAMS {.pure.} = object
    rgrc: array[3, WINAPIRECT]
    lppos: pointer

# ---- Win32 API imports ----

proc GetModuleHandleW(lpModuleName: ptr uint16): HINSTANCE
  {.stdcall, dynlib: "kernel32", importc.}
proc GetLastError(): DWORD
  {.stdcall, dynlib: "kernel32", importc.}
proc GetTickCount(): DWORD
  {.stdcall, dynlib: "kernel32", importc.}
proc Sleep(dwMilliseconds: DWORD)
  {.stdcall, dynlib: "kernel32", importc.}
proc GlobalAlloc(uFlags: UINT; dwBytes: uint): HGLOBAL
  {.stdcall, dynlib: "kernel32", importc.}
proc GlobalLock(hMem: HGLOBAL): pointer
  {.stdcall, dynlib: "kernel32", importc.}
proc GlobalUnlock(hMem: HGLOBAL): BOOL
  {.stdcall, dynlib: "kernel32", importc.}
proc GlobalSize(hMem: HGLOBAL): uint
  {.stdcall, dynlib: "kernel32", importc.}

proc RegisterClassExW(lpwcx: ptr WNDCLASSEXW): ATOM
  {.stdcall, dynlib: "user32", importc.}
proc CreateWindowExW(dwExStyle: DWORD; lpClassName, lpWindowName: ptr uint16;
  dwStyle: DWORD; x, y, nWidth, nHeight: int32;
  hWndParent: HWND; hMenu: HMENU; hInstance: HINSTANCE;
  lpParam: pointer): HWND
  {.stdcall, dynlib: "user32", importc.}
proc ShowWindow(hWnd: HWND; nCmdShow: int32): BOOL
  {.stdcall, dynlib: "user32", importc.}
proc AdjustWindowRectEx(lpRect: pointer; dwStyle: DWORD; bMenu: BOOL; dwExStyle: DWORD): BOOL
  {.stdcall, dynlib: "user32", importc.}
proc SystemParametersInfoW(uiAction, uiParam: UINT; pvParam: pointer; fWinIni: UINT): BOOL
  {.stdcall, dynlib: "user32", importc.}
proc RegGetValueW(hkey: pointer; subKey, value: ptr uint16; flags: DWORD; typ: ptr DWORD;
                  data: pointer; size: ptr DWORD): int32
  {.stdcall, dynlib: "advapi32", importc.}
proc UpdateWindow(hWnd: HWND): BOOL
  {.stdcall, dynlib: "user32", importc.}
proc DestroyWindow(hWnd: HWND): BOOL
  {.stdcall, dynlib: "user32", importc.}
proc PostQuitMessage(nExitCode: int32)
  {.stdcall, dynlib: "user32", importc.}
proc DefWindowProcW(hWnd: HWND; msg: UINT; wParam: WPARAM; lParam: LPARAM): LRESULT
  {.stdcall, dynlib: "user32", importc.}
proc PeekMessageW(lpMsg: ptr MSG; hWnd: HWND; wMsgFilterMin, wMsgFilterMax: UINT;
  wRemoveMsg: UINT): BOOL
  {.stdcall, dynlib: "user32", importc.}
proc TranslateMessage(lpMsg: ptr MSG): BOOL
  {.stdcall, dynlib: "user32", importc.}
proc DispatchMessageW(lpMsg: ptr MSG): LRESULT
  {.stdcall, dynlib: "user32", importc.}
proc GetClientRect(hWnd: HWND; lpRect: ptr WINAPIRECT): BOOL
  {.stdcall, dynlib: "user32", importc.}
proc InvalidateRect(hWnd: HWND; lpRect: ptr WINAPIRECT; bErase: BOOL): BOOL
  {.stdcall, dynlib: "user32", importc.}
proc BeginPaint(hWnd: HWND; lpPaint: ptr PAINTSTRUCT): HDC
  {.stdcall, dynlib: "user32", importc.}
proc EndPaint(hWnd: HWND; lpPaint: ptr PAINTSTRUCT): BOOL
  {.stdcall, dynlib: "user32", importc.}
proc GetDC(hWnd: HWND): HDC
  {.stdcall, dynlib: "user32", importc.}
proc ReleaseDC(hWnd: HWND; hDC: HDC): int32
  {.stdcall, dynlib: "user32", importc.}
proc SetWindowTextW(hWnd: HWND; lpString: ptr uint16): BOOL
  {.stdcall, dynlib: "user32", importc.}
proc LoadCursorW(hInstance: HINSTANCE; lpCursorName: ptr uint16): HCURSOR
  {.stdcall, dynlib: "user32", importc.}
proc LoadIconW(hInstance: HINSTANCE; lpIconName: ptr uint16): HICON
  {.stdcall, dynlib: "user32", importc.}
proc SetCursorWin(hCursor: HCURSOR): HCURSOR
  {.stdcall, dynlib: "user32", importc: "SetCursor".}
proc GetKeyState(nVirtKey: int32): int16
  {.stdcall, dynlib: "user32", importc.}
proc SetCapture(hWnd: HWND): HWND
  {.stdcall, dynlib: "user32", importc.}
proc ReleaseCapture(): BOOL
  {.stdcall, dynlib: "user32", importc.}
proc OpenClipboard(hWndNewOwner: HWND): BOOL
  {.stdcall, dynlib: "user32", importc.}
proc CloseClipboard(): BOOL
  {.stdcall, dynlib: "user32", importc.}
proc EmptyClipboard(): BOOL
  {.stdcall, dynlib: "user32", importc.}
proc GetClipboardData(uFormat: UINT): HANDLE
  {.stdcall, dynlib: "user32", importc.}
proc SetClipboardData(uFormat: UINT; hMem: HANDLE): HANDLE
  {.stdcall, dynlib: "user32", importc.}
proc MsgWaitForMultipleObjects(nCount: DWORD; pHandles: pointer;
  fWaitAll: BOOL; dwMilliseconds: DWORD; dwWakeMask: DWORD): DWORD
  {.stdcall, dynlib: "user32", importc.}

proc CreateCompatibleDC(hdc: HDC): HDC
  {.stdcall, dynlib: "gdi32", importc.}
proc CreateCompatibleBitmap(hdc: HDC; cx, cy: int32): HBITMAP
  {.stdcall, dynlib: "gdi32", importc.}
proc SelectObject(hdc: HDC; h: HGDIOBJ): HGDIOBJ
  {.stdcall, dynlib: "gdi32", importc.}
proc DeleteObject(ho: HGDIOBJ): BOOL
  {.stdcall, dynlib: "gdi32", importc.}
proc DeleteDC(hdc: HDC): BOOL
  {.stdcall, dynlib: "gdi32", importc.}
proc BitBlt(hdc: HDC; x, y, cx, cy: int32; hdcSrc: HDC;
  x1, y1: int32; rop: DWORD): BOOL
  {.stdcall, dynlib: "gdi32", importc.}
proc SetBkMode(hdc: HDC; mode: int32): int32
  {.stdcall, dynlib: "gdi32", importc.}
proc SetBkColor(hdc: HDC; color: COLORREF): COLORREF
  {.stdcall, dynlib: "gdi32", importc.}
proc SetTextColor(hdc: HDC; color: COLORREF): COLORREF
  {.stdcall, dynlib: "gdi32", importc.}
proc TextOutW(hdc: HDC; x, y: int32; lpString: ptr uint16; c: int32): BOOL
  {.stdcall, dynlib: "gdi32", importc.}
proc GdiFlush(): BOOL
  {.stdcall, dynlib: "gdi32", importc.}
proc GetTextExtentPoint32W(hdc: HDC; lpString: ptr uint16; c: int32;
  lpSize: ptr SIZE): BOOL
  {.stdcall, dynlib: "gdi32", importc.}
proc GetTextMetricsW(hdc: HDC; lptm: ptr TEXTMETRICW): BOOL
  {.stdcall, dynlib: "gdi32", importc.}
proc CreateFontW(cHeight, cWidth, cEscapement, cOrientation, cWeight: int32;
  bItalic, bUnderline, bStrikeOut: DWORD;
  iCharSet: DWORD; iOutPrecision, iClipPrecision, iQuality: DWORD;
  iPitchAndFamily: DWORD; pszFaceName: ptr uint16): HFONT
  {.stdcall, dynlib: "gdi32", importc.}
proc CreateSolidBrush(color: COLORREF): HBRUSH
  {.stdcall, dynlib: "gdi32", importc.}
proc FillRectGdi(hDC: HDC; lprc: ptr WINAPIRECT; hbr: HBRUSH): int32
  {.stdcall, dynlib: "user32", importc: "FillRect".}
proc MoveToEx(hdc: HDC; x, y: int32; lppt: ptr WINAPIPOINT): BOOL
  {.stdcall, dynlib: "gdi32", importc.}
proc LineTo(hdc: HDC; x, y: int32): BOOL
  {.stdcall, dynlib: "gdi32", importc.}
proc CreatePen(iStyle, cWidth: int32; color: COLORREF): HGDIOBJ
  {.stdcall, dynlib: "gdi32", importc.}
proc SetPixel(hdc: HDC; x, y: int32; color: COLORREF): COLORREF
  {.stdcall, dynlib: "gdi32", importc.}
proc StretchDIBits(hdc: HDC; xDest, yDest, destW, destH: int32;
  xSrc, ySrc, srcW, srcH: int32; lpBits: pointer; lpbmi: pointer;
  iUsage: uint32; rop: DWORD): int32
  {.stdcall, dynlib: "gdi32", importc.}
proc SaveDC(hdc: HDC): int32
  {.stdcall, dynlib: "gdi32", importc.}
type BlendFunction {.bycopy.} = object
  operation, flags, alpha, format: uint8

proc AlphaBlend(dst: HDC; x, y, w, h: int32; src: HDC;
                sx, sy, sw, sh: int32; blend: BlendFunction): BOOL
  {.stdcall, dynlib: "msimg32", importc.}
proc CreateDIBSection(dc: HDC; info: ptr BITMAPINFO; usage: UINT;
                      bits: ptr pointer; section: HANDLE; offset: DWORD): HBITMAP
  {.stdcall, dynlib: "gdi32", importc.}
proc RestoreDC(hdc: HDC; nSavedDC: int32): BOOL
  {.stdcall, dynlib: "gdi32", importc.}
proc IntersectClipRect(hdc: HDC; left, top, right, bottom: int32): int32
  {.stdcall, dynlib: "gdi32", importc.}
proc SelectClipRgn(hdc: HDC; hrgn: HRGN): int32
  {.stdcall, dynlib: "gdi32", importc.}
proc CreateRectRgn(x1, y1, x2, y2: int32): HRGN
  {.stdcall, dynlib: "gdi32", importc.}
proc AddFontResourceExW(name: ptr uint16; fl: DWORD; res: pointer): int32
  {.stdcall, dynlib: "gdi32", importc.}
proc RemoveFontResourceExW(name: ptr uint16; fl: DWORD; res: pointer): BOOL
  {.stdcall, dynlib: "gdi32", importc.}

proc SendMessageW(hWnd: HWND; msg: UINT; wParam: WPARAM; lParam: LPARAM): LRESULT
  {.stdcall, dynlib: "user32", importc.}
proc DragAcceptFiles(hWnd: HWND; accept: BOOL)
  {.stdcall, dynlib: "shell32", importc.}
proc DragQueryFileW(drop: HANDLE; i: UINT; file: ptr uint16; n: UINT): UINT
  {.stdcall, dynlib: "shell32", importc.}
proc DragQueryPoint(drop: HANDLE; pt: ptr WINAPIPOINT): BOOL
  {.stdcall, dynlib: "shell32", importc.}
proc DragFinish(drop: HANDLE)
  {.stdcall, dynlib: "shell32", importc.}
proc GetCursorPos(lpPoint: ptr WINAPIPOINT): BOOL
  {.stdcall, dynlib: "user32", importc.}
proc IsZoomed(hWnd: HWND): BOOL
  {.stdcall, dynlib: "user32", importc.}
proc GetActiveWindow(): HWND
  {.stdcall, dynlib: "user32", importc.}
proc MonitorFromWindow(hWnd: HWND; flags: DWORD): HANDLE
  {.stdcall, dynlib: "user32", importc.}
proc GetMonitorInfoW(monitor: HANDLE; info: ptr MONITORINFO): BOOL
  {.stdcall, dynlib: "user32", importc.}
proc SetWindowPos(hWnd, after: HWND; x, y, cx, cy: int32; flags: UINT): BOOL
  {.stdcall, dynlib: "user32", importc.}
when sizeof(int) == 8:
  proc GetWindowLongPtrW(hWnd: HWND; index: int32): int
    {.stdcall, dynlib: "user32", importc.}
  proc SetWindowLongPtrW(hWnd: HWND; index: int32; value: int): int
    {.stdcall, dynlib: "user32", importc.}
else:
  proc GetWindowLongPtrW(hWnd: HWND; index: int32): int
    {.stdcall, dynlib: "user32", importc: "GetWindowLongW".}
  proc SetWindowLongPtrW(hWnd: HWND; index: int32; value: int): int
    {.stdcall, dynlib: "user32", importc: "SetWindowLongW".}

# ---- Helpers ----

proc rgb(c: screen.Color): COLORREF {.inline.} =
  COLORREF(c.r.uint32 or (c.g.uint32 shl 8) or (c.b.uint32 shl 16))

proc loWord(lp: LPARAM): int {.inline.} = int(lp and 0xFFFF)
proc hiWord(lp: LPARAM): int {.inline.} = int((lp shr 16) and 0xFFFF)
proc xParam(lp: LPARAM): int {.inline.} =
  ## The signed x of a mouse message: negative left of the window while
  ## the mouse is captured.
  cast[int16](uint16(lp and 0xFFFF)).int
proc yParam(lp: LPARAM): int {.inline.} =
  cast[int16](uint16((lp shr 16) and 0xFFFF)).int

proc signedHiWord(wp: WPARAM): int {.inline.} =
  ## For WM_MOUSEWHEEL: wParam high word is signed
  cast[int16](uint16((wp shr 16) and 0xFFFF)).int

# ---- Font handle management ----

type
  FontSlot = object
    hFont: HFONT
    metrics: FontMetrics
    faceName: string
    size: int
    registeredPath: string

var fonts: seq[FontSlot]

proc getFontHandle(f: screen.Font): HFONT {.inline.} =
  let idx = f.int - 1
  if idx >= 0 and idx < fonts.len: fonts[idx].hFont
  else: nil

# ---- Driver state ----

var
  gHwnd: HWND
  gHinstance: HINSTANCE
  gBackDC: HDC        # off-screen DC for double buffering
  gBackBmp: HBITMAP   # off-screen bitmap
  gOldBmp: HGDIOBJ    # original bitmap selected into gBackDC
  gWidth, gHeight: int32
  gQuitFlag: bool
  gSavedClipRgn: HRGN
  gUiScale: int = 100

# Event queue: WndProc pushes events, pollEvent/waitEvent consumes them
var eventQueue: seq[input.Event]

# ---- OpenGL (WGL): desktop OpenGL 2.1 on the window ----

type
  PIXELFORMATDESCRIPTOR {.pure.} = object
    nSize, nVersion: uint16
    dwFlags: DWORD
    iPixelType, cColorBits, cRedBits, cRedShift, cGreenBits, cGreenShift,
      cBlueBits, cBlueShift, cAlphaBits, cAlphaShift, cAccumBits, cAccumRedBits,
      cAccumGreenBits, cAccumBlueBits, cAccumAlphaBits, cDepthBits, cStencilBits,
      cAuxBuffers, iLayerType, bReserved: uint8
    dwLayerMask, dwVisibleMask, dwDamageMask: DWORD

proc ChoosePixelFormat(hdc: HDC; pfd: ptr PIXELFORMATDESCRIPTOR): int32
  {.stdcall, dynlib: "gdi32", importc.}
proc SetPixelFormat(hdc: HDC; fmt: int32; pfd: ptr PIXELFORMATDESCRIPTOR): int32
  {.stdcall, dynlib: "gdi32", importc.}
proc SwapBuffers(hdc: HDC): int32
  {.stdcall, dynlib: "gdi32", importc.}
proc LoadLibraryA(name: cstring): pointer
  {.stdcall, dynlib: "kernel32", importc.}
proc GetProcAddress(m: pointer; name: cstring): pointer
  {.stdcall, dynlib: "kernel32", importc.}

var
  gGlLib: pointer               # opengl32.dll
  gGlDC: HDC
  gGlRC: pointer
  gGpu: bool                    # the window is drawn with OpenGL
  wglCreateContextP: proc (hdc: HDC): pointer {.stdcall.}
  wglMakeCurrentP: proc (hdc: HDC; rc: pointer): int32 {.stdcall.}
  wglDeleteContextP: proc (rc: pointer): int32 {.stdcall.}
  wglGetProcAddressP: proc (name: cstring): pointer {.stdcall.}

proc winGpuProc(name: cstring): pointer =
  ## OpenGL 1.1 from opengl32.dll; what came after it from the driver.
  if gGlLib == nil: return nil
  result = GetProcAddress(gGlLib, name)
  if result == nil and wglGetProcAddressP != nil:
    result = wglGetProcAddressP(name)
    # Some drivers answer 1, 2, 3 or -1 for "none".
    if cast[int](result) in [-1, 0, 1, 2, 3]: result = nil

proc winStartGpu(): bool =
  if gHwnd == nil: return false
  if gGlLib == nil:
    gGlLib = LoadLibraryA("opengl32.dll")
    if gGlLib == nil: return false
    wglCreateContextP = cast[typeof(wglCreateContextP)](GetProcAddress(gGlLib, "wglCreateContext"))
    wglMakeCurrentP = cast[typeof(wglMakeCurrentP)](GetProcAddress(gGlLib, "wglMakeCurrent"))
    wglDeleteContextP = cast[typeof(wglDeleteContextP)](GetProcAddress(gGlLib, "wglDeleteContext"))
    wglGetProcAddressP = cast[typeof(wglGetProcAddressP)](
      GetProcAddress(gGlLib, "wglGetProcAddress"))
  if wglCreateContextP == nil or wglMakeCurrentP == nil or wglDeleteContextP == nil: return false
  gGlDC = GetDC(gHwnd)
  if gGlDC == nil: return false
  var pfd = PIXELFORMATDESCRIPTOR(nSize: uint16(sizeof(PIXELFORMATDESCRIPTOR)), nVersion: 1,
    dwFlags: DWORD(0x04 or 0x20 or 0x01),        # PFD_DRAW_TO_WINDOW, SUPPORT_OPENGL, DOUBLEBUFFER
    iPixelType: 0, cColorBits: 24)
  let fmt = ChoosePixelFormat(gGlDC, addr pfd)
  if fmt == 0 or SetPixelFormat(gGlDC, fmt, addr pfd) == 0: return false
  gGlRC = wglCreateContextP(gGlDC)
  if gGlRC == nil: return false
  if wglMakeCurrentP(gGlDC, gGlRC) == 0:
    discard wglDeleteContextP(gGlRC)
    gGlRC = nil
    return false
  # No shaders: OpenGL 1.1 only, which is all Windows itself offers.
  if winGpuProc("glCreateShader") == nil:
    discard wglMakeCurrentP(nil, nil)
    discard wglDeleteContextP(gGlRC)
    gGlRC = nil
    return false
  let swapInterval = cast[proc (n: int32): int32 {.stdcall.}](winGpuProc("wglSwapIntervalEXT"))
  if swapInterval != nil: discard swapInterval(1)
  gGpu = true
  true

proc winStopGpu() =
  if gGlRC != nil:
    discard wglMakeCurrentP(nil, nil)
    discard wglDeleteContextP(gGlRC)
  gGlRC = nil
  gGpu = false
  if gHwnd != nil: discard InvalidateRect(gHwnd, nil, 0)

proc pushEvent(e: input.Event) =
  eventQueue.add e

# ---- Display density ----

const LOGPIXELSX = 88.int32

proc GetDeviceCaps(hdc: HDC; index: int32): int32
  {.stdcall, dynlib: "gdi32", importc.}

proc uiScaleFromDpi(dpi: int): int {.inline.} =
  ## 96 dpi is Windows' 100%; the usual steps are 120, 144 and 192 dpi, which
  ## come out as exactly 125, 150 and 200 percent.
  if dpi <= 0: 100 else: max(100, dpi * 100 div 96)

proc currentUiScale(): int =
  ## The process is per-monitor DPI aware, so window coordinates are physical
  ## pixels and nothing on the way to the screen scales the drawing -- the
  ## monitor's DPI has to land in `uiScale`.
  if gHwnd != nil:
    try:
      proc GetDpiForWindow(hwnd: HWND): UINT
        {.stdcall, dynlib: "user32", importc.}
      return uiScaleFromDpi(GetDpiForWindow(gHwnd).int)
    except: discard
  # Before Windows 10 1607 there is only the one system-wide DPI.
  let dc = GetDC(nil)
  if dc != nil:
    let dpi = GetDeviceCaps(dc, LOGPIXELSX).int
    discard ReleaseDC(nil, dc)
    return uiScaleFromDpi(dpi)
  result = 100

# ---- Back-buffer management ----

proc recreateBackBuffer() =
  let screenDC = GetDC(gHwnd)
  let newBmp = CreateCompatibleBitmap(screenDC, gWidth, gHeight)
  if gBackDC == nil:
    gBackDC = CreateCompatibleDC(screenDC)
  if gBackBmp != nil:
    discard SelectObject(gBackDC, cast[HGDIOBJ](newBmp))
    discard DeleteObject(cast[HGDIOBJ](gBackBmp))
  else:
    gOldBmp = SelectObject(gBackDC, cast[HGDIOBJ](newBmp))
  gBackBmp = newBmp
  # Clear to opaque black -- CreateCompatibleBitmap inits to all zeros which
  # DWM interprets as fully transparent on 32-bit displays.
  var rc = WINAPIRECT(left: 0, top: 0, right: gWidth, bottom: gHeight)
  let blackBrush = CreateSolidBrush(0x00000000'u32)
  discard FillRectGdi(gBackDC, addr rc, blackBrush)
  discard DeleteObject(cast[HGDIOBJ](blackBrush))
  discard ReleaseDC(gHwnd, screenDC)

# ---- WndProc ----

proc translateVK(vk: WPARAM): input.KeyCode =
  let vk = vk.uint32
  if vk >= ord('A').uint32 and vk <= ord('Z').uint32:
    return input.KeyCode(ord(KeyA) + (vk.int - ord('A')))
  if vk >= ord('0').uint32 and vk <= ord('9').uint32:
    return input.KeyCode(ord(Key0) + (vk.int - ord('0')))
  if vk >= VK_F1 and vk <= VK_F12:
    return input.KeyCode(ord(KeyF1) + (vk.int - VK_F1.int))
  case vk
  of VK_RETURN: KeyEnter
  of VK_SPACE: KeySpace
  of VK_ESCAPE: KeyEsc
  of VK_TAB: KeyTab
  of VK_BACK: KeyBackspace
  of VK_DELETE: KeyDelete
  of VK_INSERT: KeyInsert
  of VK_LEFT: KeyLeft
  of VK_RIGHT: KeyRight
  of VK_UP: KeyUp
  of VK_DOWN: KeyDown
  of VK_PRIOR: KeyPageUp
  of VK_NEXT: KeyPageDown
  of VK_HOME: KeyHome
  of VK_END: KeyEnd
  of VK_CAPITAL: KeyCapslock
  of 0x5D'u32: KeyMenu                  # VK_APPS
  of VK_OEM_COMMA: KeyComma
  of VK_OEM_PERIOD: KeyPeriod
  of VK_OEM_2: KeySlash
  of VK_OEM_MINUS: KeyMinus
  of 0xDB'u32: KeyLeftBracket
  of 0xDD'u32: KeyRightBracket
  of 0xBA'u32: KeySemicolon
  of 0xDE'u32: KeyQuote
  of 0xDC'u32: KeyBackslash
  of 0xC0'u32: KeyBackquote
  of VK_OEM_PLUS: KeyEqual
  else: KeyNone

proc getModifiers(): set[Modifier] =
  if GetKeyState(VK_SHIFT.int32) < 0: result.incl ShiftPressed
  if GetKeyState(VK_CONTROL.int32) < 0: result.incl CtrlPressed
  if GetKeyState(VK_MENU.int32) < 0: result.incl AltPressed

var gHighSurrogate: uint16
var lastClickTime: DWORD
var lastClickX, lastClickY: int
var clickCount: int

proc pumpMessages() =
  ## Drain Win32 message queue. Must be called frequently to prevent
  ## the "Not Responding" ghost window (Windows triggers it after ~5s
  ## of not processing sent messages).
  var msg: MSG
  while PeekMessageW(addr msg, nil, 0, 0, PM_REMOVE) != 0:
    discard TranslateMessage(addr msg)
    discard DispatchMessageW(addr msg)
    if msg.message == WM_QUIT:
      pushEvent(input.Event(kind: QuitEvent))

# ---- Pens (WM_POINTER, Windows 8 on) ----
#
# A pen's messages are made into events here, with its pressure, lean, turn
# and eraser end. Anything else that points -- the mouse, a finger, a touch
# pad -- is left to DefWindowProc, which turns it into the mouse messages
# above exactly as before (EnableMouseInPointer is not called). A pen whose
# messages are handled here gets no mouse messages made from them. The
# functions are looked up at run time: Windows 7 sends no WM_POINTER at all.

type
  GetPointerTypeProc = proc (id: UINT; kind: ptr DWORD): BOOL {.stdcall.}
  GetPointerPenInfoProc = proc (id: UINT; info: ptr POINTER_PEN_INFO): BOOL {.stdcall.}

proc ScreenToClient(hWnd: HWND; lpPoint: ptr WINAPIPOINT): BOOL
  {.stdcall, dynlib: "user32", importc.}

var
  gPointerApi = 0     ## 0: not looked up yet; 1: there; -1: not there
  gGetPointerType: GetPointerTypeProc
  gGetPointerPenInfo: GetPointerPenInfoProc
  gPenButton = LeftButton   ## what the pen's tip pressed (right: with the side button down)

proc penClicks(x, y: int): int =
  ## The click count, kept with the mouse's: a double tap is a double click.
  let now = GetTickCount()
  if now - lastClickTime < 500 and abs(x - lastClickX) < 4 and abs(y - lastClickY) < 4:
    inc clickCount
  else:
    clickCount = 1
  lastClickTime = now
  lastClickX = x
  lastClickY = y
  clickCount

proc penMessage(hwnd: HWND; msg: UINT; wp: WPARAM): bool =
  ## A WM_POINTER message of a pen as an event; false when it is not a pen's
  ## (or cannot be read), and DefWindowProc is to have it.
  if gPointerApi == 0:
    let u = LoadLibraryA("user32.dll")
    if u != nil:
      gGetPointerType = cast[GetPointerTypeProc](GetProcAddress(u, "GetPointerType"))
      gGetPointerPenInfo = cast[GetPointerPenInfoProc](GetProcAddress(u, "GetPointerPenInfo"))
    gPointerApi = if gGetPointerType != nil and gGetPointerPenInfo != nil: 1 else: -1
  if gPointerApi < 0: return false
  let id = UINT(wp and 0xFFFF)          # GET_POINTERID_WPARAM
  var kind: DWORD = 0
  if gGetPointerType(id, addr kind) == 0 or kind != PT_PEN: return false
  var info: POINTER_PEN_INFO
  if gGetPointerPenInfo(id, addr info) == 0: return false
  var pt = info.pointerInfo.ptPixelLocation
  discard ScreenToClient(hwnd, addr pt)
  let flags = info.pointerInfo.pointerFlags
  var e = input.Event(hasMods: true, x: pt.x.int, y: pt.y.int, mods: getModifiers())
  penFromWindows(e, info.pressure, info.rotation, info.tiltX, info.tiltY,
                 info.penFlags, info.penMask, (flags and POINTER_FLAG_INCONTACT) != 0)
  case msg
  of WM_POINTERDOWN:
    # The tip touches: a left click, or a right one with the side button
    # held, as Windows' own mouse messages for a pen have it.
    gPenButton = if (flags and POINTER_FLAG_SECONDBUTTON) != 0 or
                    (info.penFlags and PenFlagBarrel) != 0: RightButton
                 else: LeftButton
    e.kind = MouseDownEvent
    e.button = gPenButton
    e.clicks = penClicks(e.x, e.y)
  of WM_POINTERUP:
    e.kind = MouseUpEvent
    e.button = gPenButton
  else:
    e.kind = MouseMoveEvent
  pushEvent(e)
  true

# ---- A window without Windows' frame ----
#
# An app that draws its own title bar and borders (`setSystemFrame(false)`)
# gets a WS_POPUP window that is still WS_THICKFRAME and WS_SYSMENU and has
# the minimize and maximize boxes: Windows sizes it, snaps it (Aero Snap,
# Win+arrows), minimizes and maximizes it and keeps its taskbar button as for
# any other window. WM_NCCALCSIZE makes all of it the client area, so nothing
# of Windows' frame shows. The app moves and sizes it with `dragWindow`, which
# hands the press on to DefWindowProc as one on a title bar or an edge
# (WM_NCLBUTTONDOWN) -- Windows' own loop then does the rest, as for a frame
# of its own.

var gSystemFrame = true   ## Windows draws the frame (else the app does)
var gCursor: HCURSOR      ## the pointer the app asked for (nil: the class's)

proc workArea(hwnd: HWND): tuple[monitor, work: WINAPIRECT] =
  ## The monitor the window is on, and that monitor without the taskbar.
  var mi = MONITORINFO(cbSize: DWORD(sizeof(MONITORINFO)))
  if GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), addr mi) != 0:
    result = (mi.rcMonitor, mi.rcWork)
  else:
    discard SystemParametersInfoW(0x0030, 0, addr result.work, 0)   # SPI_GETWORKAREA
    result.monitor = result.work

proc styleWord(style: uint32): int {.inline.} = cast[int](uint(style))

proc wndProc(hwnd: HWND; msg: UINT; wp: WPARAM; lp: LPARAM): LRESULT {.stdcall.} =
  # Capture gHwnd from the first message -- WM_SIZE etc. arrive
  # during CreateWindowExW, *before* it returns and assigns gHwnd.
  if gHwnd == nil and hwnd != nil:
    gHwnd = hwnd
  case msg
  of WM_DESTROY:
    PostQuitMessage(0)
    pushEvent(input.Event(kind: QuitEvent))
    return 0

  of WM_CLOSE:
    pushEvent(input.Event(kind: WindowCloseEvent))
    return 0  # don't call DestroyWindow yet; let the app decide

  of WM_ERASEBKGND:
    return 1  # we handle erasing via double buffer

  of WM_NCCALCSIZE:
    if not gSystemFrame:
      # All of the window is the app's: the client area is the window's
      # rectangle as proposed (the first of NCCALCSIZE_PARAMS, or -- when the
      # window is made -- the RECT itself). Maximized, Windows makes a window
      # larger than its monitor by the frame it would have: that is cut off.
      if IsZoomed(hwnd) != 0:
        let r = if wp != 0: addr cast[ptr NCCALCSIZE_PARAMS](lp).rgrc[0]
                else: cast[ptr WINAPIRECT](lp)
        let w = workArea(hwnd).work
        r.left = max(r.left, w.left)
        r.top = max(r.top, w.top)
        r.right = min(r.right, w.right)
        r.bottom = min(r.bottom, w.bottom)
      return 0

  of WM_GETMINMAXINFO:
    if not gSystemFrame:
      # A window without a caption is maximized over the whole monitor,
      # taskbar and all: this one stops at the taskbar, as others do.
      let (mon, work) = workArea(hwnd)
      let mmi = cast[ptr MINMAXINFO](lp)
      mmi.ptMaxPosition = WINAPIPOINT(x: work.left - mon.left, y: work.top - mon.top)
      mmi.ptMaxSize = WINAPIPOINT(x: work.right - work.left, y: work.bottom - work.top)
      return 0

  of WM_DROPFILES:
    # Files dropped from Explorer: their paths, and where.
    let drop = cast[HANDLE](wp)
    var e = input.Event(kind: FileDropEvent, hasMods: true, mods: getModifiers())
    let n = DragQueryFileW(drop, 0xFFFFFFFF'u32, nil, 0)
    for i in 0'u32 ..< n:
      let len = DragQueryFileW(drop, i, nil, 0)
      if len == 0: continue
      var buf = newSeq[uint16](len.int + 1)
      discard DragQueryFileW(drop, i, addr buf[0], len + 1)
      var w = newWideCString("", len.int)
      copyMem(addr w[0], addr buf[0], len.int * 2)
      e.files.add $w
    var pt: WINAPIPOINT
    discard DragQueryPoint(drop, addr pt)
    DragFinish(drop)
    e.x = pt.x.int
    e.y = pt.y.int
    if e.files.len > 0: pushEvent(e)
    return 0

  of WM_SETCURSOR:
    # Over the app's part of the window the pointer is the one it asked for
    # (an I-beam, the sizing arrows of a frame it draws); DefWindowProc
    # would put the class's arrow back at every move.
    if (lp and 0xFFFF) == HTCLIENT.int and gCursor != nil:
      discard SetCursorWin(gCursor)
      return 1

  of WM_NCACTIVATE:
    # (no frame of Windows' to show in the active or the inactive colors)
    if not gSystemFrame: return DefWindowProcW(hwnd, msg, wp, -1)

  of WM_SIZE:
    let newW = loWord(lp).int32
    let newH = hiWord(lp).int32
    if newW > 0 and newH > 0 and (newW != gWidth or newH != gHeight):
      gWidth = newW
      gHeight = newH
      recreateBackBuffer()
      var e = input.Event(kind: WindowMetricsEvent)
      e.x = gWidth
      e.y = gHeight
      e.scaleX = 1
      e.scaleY = 1
      e.uiScale = gUiScale
      pushEvent(e)
    return 0

  of WM_DPICHANGED:
    # Dragged to a monitor of another density. The window keeps its pixel size
    # -- so it stays physically the same -- and the app enlarges its own
    # drawing by the new `uiScale`.
    gUiScale = currentUiScale()
    var e = input.Event(kind: WindowMetricsEvent)
    e.x = gWidth
    e.y = gHeight
    e.scaleX = 1
    e.scaleY = 1
    e.uiScale = gUiScale
    pushEvent(e)
    return 0

  of WM_PAINT:
    var ps: PAINTSTRUCT
    let hdc = BeginPaint(hwnd, addr ps)
    if gGpu:
      # Drawn with OpenGL: the app draws the window again.
      pushEvent(input.Event(kind: AppResumeEvent))
    elif gBackDC != nil:
      discard BitBlt(hdc, 0, 0, gWidth, gHeight, gBackDC, 0, 0, SRCCOPY)
    discard EndPaint(hwnd, addr ps)
    return 0

  of WM_KEYDOWN, WM_SYSKEYDOWN:
    # Alt+key and F10 arrive as WM_SYSKEYDOWN. They are passed on like any
    # key (an app's menus and Alt shortcuts want them); only Alt+F4 still
    # goes to Windows, which closes the window.
    var e = input.Event(kind: KeyDownEvent)
    e.key = translateVK(wp)
    e.mods = getModifiers()
    pushEvent(e)
    if msg == WM_SYSKEYDOWN and wp.uint32 == 0x73'u32: discard
    else: return 0

  of WM_KEYUP, WM_SYSKEYUP:
    var e = input.Event(kind: KeyUpEvent)
    e.key = translateVK(wp)
    e.mods = getModifiers()
    pushEvent(e)
    if msg == WM_SYSKEYUP and wp.uint32 == 0x73'u32: discard
    else: return 0

  of WM_SYSCHAR:
    # Swallowed: DefWindowProc would beep for an Alt+letter with no menu.
    return 0

  of WM_CHAR:
    # wp is a UTF-16 code unit; a character beyond the BMP comes as two.
    let ch = wp.uint16
    if ch >= 0xD800'u16 and ch <= 0xDBFF'u16:
      gHighSurrogate = ch
      return 0
    var codepoint = ch.uint32
    if ch >= 0xDC00'u16 and ch <= 0xDFFF'u16:
      if gHighSurrogate == 0: return 0
      codepoint = 0x10000'u32 + ((gHighSurrogate.uint32 - 0xD800) shl 10) +
                  (ch.uint32 - 0xDC00)
      gHighSurrogate = 0
    if codepoint >= 32 and codepoint != 127:
      var e = input.Event(kind: TextInputEvent)
      if codepoint < 0x80:
        e.text[0] = chr(codepoint)
      elif codepoint < 0x800:
        e.text[0] = chr(0xC0 or (codepoint shr 6))
        e.text[1] = chr(0x80 or (codepoint and 0x3F))
      elif codepoint < 0x10000:
        e.text[0] = chr(0xE0 or (codepoint shr 12))
        e.text[1] = chr(0x80 or ((codepoint shr 6) and 0x3F))
        e.text[2] = chr(0x80 or (codepoint and 0x3F))
      else:
        e.text[0] = chr(0xF0 or (codepoint shr 18))
        e.text[1] = chr(0x80 or ((codepoint shr 12) and 0x3F))
        e.text[2] = chr(0x80 or ((codepoint shr 6) and 0x3F))
        e.text[3] = chr(0x80 or (codepoint and 0x3F))
      pushEvent(e)
    return 0

  of WM_SETFOCUS:
    pushEvent(input.Event(kind: WindowFocusGainedEvent))
    return 0

  of WM_KILLFOCUS:
    pushEvent(input.Event(kind: WindowFocusLostEvent))
    return 0

  of WM_XBUTTONDOWN, WM_XBUTTONUP:
    # the side buttons: back (X1) and forward (X2)
    var e = input.Event(kind: if msg == WM_XBUTTONDOWN: MouseDownEvent else: MouseUpEvent,
                        hasMods: true)
    e.x = xParam(lp)
    e.y = yParam(lp)
    e.mods = getModifiers()
    e.button = if ((wp.uint shr 16) and 0xFFFF) == 1: BackButton else: ForwardButton
    e.clicks = 1
    pushEvent(e)
    return 1

  of WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN:
    var e = input.Event(kind: MouseDownEvent, hasMods: true)
    e.x = xParam(lp)
    e.y = yParam(lp)
    e.mods = getModifiers()
    # Keep receiving the mouse while a button is down, so a drag that ends
    # outside the window still ends.
    discard SetCapture(hwnd)
    case msg
    of WM_LBUTTONDOWN: e.button = LeftButton
    of WM_RBUTTONDOWN: e.button = RightButton
    else: e.button = MiddleButton
    # Track click count for double/triple click
    let now = GetTickCount()
    if now - lastClickTime < 500 and
       abs(e.x - lastClickX) < 4 and abs(e.y - lastClickY) < 4:
      inc clickCount
    else:
      clickCount = 1
    lastClickTime = now
    lastClickX = e.x
    lastClickY = e.y
    e.clicks = clickCount
    pushEvent(e)
    return 0

  of WM_LBUTTONUP, WM_RBUTTONUP, WM_MBUTTONUP:
    var e = input.Event(kind: MouseUpEvent, hasMods: true)
    e.mods = getModifiers()
    e.x = xParam(lp)
    e.y = yParam(lp)
    discard ReleaseCapture()
    case msg
    of WM_LBUTTONUP: e.button = LeftButton
    of WM_RBUTTONUP: e.button = RightButton
    else: e.button = MiddleButton
    pushEvent(e)
    return 0

  of WM_MOUSEMOVE:
    var e = input.Event(kind: MouseMoveEvent, hasMods: true)
    e.x = xParam(lp)
    e.y = yParam(lp)
    e.mods = getModifiers()
    pushEvent(e)
    return 0

  of WM_MOUSEWHEEL:
    var e = input.Event(kind: MouseWheelEvent, hasMods: true)
    e.mods = getModifiers()
    let delta = signedHiWord(wp)
    e.y = delta div 120  # standard wheel delta
    var pt = WINAPIPOINT(x: loWord(lp).LONG, y: hiWord(lp).LONG)
    # wheel coords are screen-relative; could ScreenToClient but
    # Nimedit only uses e.y for scroll direction
    pushEvent(e)
    return 0

  of WM_POINTERDOWN, WM_POINTERUPDATE, WM_POINTERUP:
    # a pen: its events with how it is held (see "Pens"); anything else goes
    # on to DefWindowProc and comes back as mouse messages
    if penMessage(hwnd, msg, wp): return 0

  else:
    discard

  return DefWindowProcW(hwnd, msg, wp, lp)

# ---- Screen hook implementations ----

var pointerBase = -1      # the user's pointer size (CursorBaseSize), read once

proc winPointerHeight(): int =
  ## The pointer's height on this display: Settings > Accessibility > Mouse
  ## pointer's size (32 at the smallest, up to 256), at the display's scale.
  if pointerBase < 0:
    pointerBase = 32
    let key = newWideCString("Control Panel\\Cursors")
    let name = newWideCString("CursorBaseSize")
    var v: DWORD
    var size = DWORD(sizeof(DWORD))
    # HKEY_CURRENT_USER, sign-extended; 0x10 is RRF_RT_REG_DWORD
    let hkcu = cast[pointer](int(cast[int32](0x80000001'u32)))
    if RegGetValueW(hkcu, cast[ptr uint16](key[0].addr),
                    cast[ptr uint16](name[0].addr), 0x00000010, nil,
                    addr v, addr size) == 0 and
       v >= 16 and v <= 512:
      pointerBase = int(v)
  pointerBase * max(100, gUiScale) div 100

proc winCreateWindow(layout: var ScreenLayout; icon: pointer; iconLen: int) =
  # Seed the scale before there is a window: `CreateWindowExW` and `ShowWindow`
  # below both send WM_SIZE synchronously, and the event that lands in the
  # queue carries `gUiScale` with it. Left at the 100 default, that event
  # reaches the app one frame later and tells it the display is a 96 dpi one,
  # undoing the real scale this proc goes on to report.
  gUiScale = currentUiScale()
  gHinstance = GetModuleHandleW(nil)
  let className = newWideCString("NimEditWinAPI")

  var wc: WNDCLASSEXW
  wc.cbSize = UINT(sizeof(WNDCLASSEXW))
  wc.style = CS_HREDRAW or CS_VREDRAW
  wc.lpfnWndProc = wndProc
  wc.hInstance = gHinstance
  # Resource ID 1 is the app icon when the binary was linked with a `.res`
  # -- `1 ICON "app.ico"` in the `.rc` the application compiled. Nil is fine
  # when no such resource was linked.
  wc.hIcon = LoadIconW(gHinstance, cast[ptr uint16](1))
  wc.hIconSm = LoadIconW(gHinstance, cast[ptr uint16](1))
  wc.hCursor = LoadCursorW(nil, IDC_ARROW)
  wc.lpszClassName = cast[ptr uint16](className[0].addr)

  discard RegisterClassExW(addr wc)

  let title = newWideCString("NimEdit")
  # The size asked for is the inside of the window (what the app draws on),
  # in pixels of a 100% screen: grown by the display's scale, then by the
  # title bar and the borders Windows adds around it -- else the app's own
  # content does not fit and scrolls.
  var outerW = 0x80000000'i32                    # CW_USEDEFAULT
  var outerH = 0x80000000'i32
  var x = 0x80000000'i32
  var y = 0x80000000'i32
  var work: WINAPIRECT
  let hasWork = SystemParametersInfoW(0x0030, 0, addr work, 0) != 0   # SPI_GETWORKAREA
  if layout.width >= 0 and layout.height >= 0:
    var rc = WINAPIRECT(left: 0, top: 0,
                        right: int32(layout.width * gUiScale div 100),
                        bottom: int32(layout.height * gUiScale div 100))
    # (without Windows' frame the window is all inside)
    if gSystemFrame: discard AdjustWindowRectEx(addr rc, WS_OVERLAPPEDWINDOW, 0, 0)
    outerW = rc.right - rc.left
    outerH = rc.bottom - rc.top
    # No bigger than the desktop without the taskbar.
    if hasWork:
      outerW = min(outerW, work.right - work.left)
      outerH = min(outerH, work.bottom - work.top)
      if not gSystemFrame:
        # CW_USEDEFAULT places only windows with a caption: this one is
        # put in the middle of the desktop.
        x = work.left + (work.right - work.left - outerW) div 2
        y = work.top + (work.bottom - work.top - outerH) div 2
  elif not gSystemFrame and hasWork:
    # (maximized below; restored, three quarters of the desktop, in the
    # middle -- about what CW_USEDEFAULT gives a window with a caption)
    outerW = (work.right - work.left) * 3 div 4
    outerH = (work.bottom - work.top) * 3 div 4
    x = work.left + (work.right - work.left - outerW) div 2
    y = work.top + (work.bottom - work.top - outerH) div 2
  gHwnd = CreateWindowExW(
    0,
    cast[ptr uint16](className[0].addr),
    cast[ptr uint16](title[0].addr),
    (if gSystemFrame: WS_OVERLAPPEDWINDOW else: WS_FRAMELESS) or WS_VISIBLE,
    x, y, outerW, outerH,
    nil, nil, gHinstance, nil)

  if gHwnd == nil:
    quit("CreateWindowExW failed")

  # Files dropped from Explorer come as WM_DROPFILES.
  DragAcceptFiles(gHwnd, 1)

  # A negative dimension is MaxWindowWidth/MaxWindowHeight. SW_MAXIMIZE is the
  # shell's own idea of how large a window may be, so it stops at the taskbar
  # instead of covering it -- this is not a fullscreen window. GetClientRect
  # below then reports whatever size that worked out to.
  let maximized = layout.width < 0 or layout.height < 0
  discard ShowWindow(gHwnd, if maximized: SW_MAXIMIZE else: SW_SHOW)
  discard UpdateWindow(gHwnd)

  var rc: WINAPIRECT
  discard GetClientRect(gHwnd, addr rc)
  gWidth = rc.right - rc.left
  gHeight = rc.bottom - rc.top
  layout.width = gWidth
  layout.height = gHeight
  layout.scaleX = 1
  layout.scaleY = 1
  gUiScale = currentUiScale()
  layout.uiScale = gUiScale
  # The seed above is the system DPI, which is not this window's on a desktop
  # of mixed density -- only now can `GetDpiForWindow` be asked. Anything the
  # messages during creation already queued gets the same answer this call
  # hands back, so that no event ever contradicts it.
  for e in eventQueue.mitems:
    if e.kind == WindowMetricsEvent: e.uiScale = gUiScale

  recreateBackBuffer()

proc winGetWindowLayout(): ScreenLayout =
  gUiScale = currentUiScale()
  ScreenLayout(width: gWidth.int, height: gHeight.int,
               scaleX: 1, scaleY: 1, uiScale: gUiScale)

proc winRefresh() =
  discard InvalidateRect(gHwnd, nil, 0)
  discard UpdateWindow(gHwnd)

proc winSaveState() =
  # Save current clip region
  gSavedClipRgn = CreateRectRgn(0, 0, 0, 0)
  # GetClipRgn not easily available; we just reset to full on restore
  discard

proc winRestoreState() =
  # Restore by removing clip region
  if gBackDC != nil:
    discard SelectClipRgn(gBackDC, nil)
  if gSavedClipRgn != nil:
    discard DeleteObject(cast[HGDIOBJ](gSavedClipRgn))
    gSavedClipRgn = nil

proc winSetClipRect(r: coords.Rect) =
  if gBackDC != nil:
    # Reset clip region first, then set new one
    discard SelectClipRgn(gBackDC, nil)
    discard IntersectClipRect(gBackDC,
      r.x.int32, r.y.int32, (r.x + r.w).int32, (r.y + r.h).int32)

proc winPutRGBA(pixels: ptr UncheckedArray[uint32]; w, h: int;
                dst: coords.Rect; scaleImage: bool; format: RGBAFormat): bool =
  ## This driver decodes no pictures, so it fills in none of the image
  ## relays. What it can do is take finished pixels from whoever does.
  if gBackDC == nil or pixels == nil: return false
  if w <= 0 or h <= 0 or dst.w <= 0 or dst.h <= 0: return false
  var bmi = BITMAPINFO()
  bmi.bmiHeader.biSize = DWORD(sizeof(BITMAPINFOHEADER))
  bmi.bmiHeader.biWidth = w.LONG
  # Negative, which is how a DIB says its rows run top to bottom. They are
  # handed over that way and a DIB is bottom-up unless told otherwise, so
  # without the sign the picture arrives upside down.
  bmi.bmiHeader.biHeight = LONG(-h)
  bmi.bmiHeader.biPlanes = 1
  bmi.bmiHeader.biBitCount = 32
  bmi.bmiHeader.biCompression = BI_RGB
  if format == RGBAFormat.argbPremultiplied:
    let dc = CreateCompatibleDC(gBackDC)
    if dc == nil: return false
    defer: discard DeleteDC(dc)
    var data: pointer
    let bitmap = CreateDIBSection(dc, addr bmi, DIB_RGB_COLORS, addr data, nil, 0)
    if bitmap == nil: return false
    defer: discard DeleteObject(cast[HGDIOBJ](bitmap))
    copyMem(data, pixels, w * h * 4)
    let previous = SelectObject(dc, cast[HGDIOBJ](bitmap))
    defer: discard SelectObject(dc, previous)
    let drawW = if scaleImage: dst.w else: min(w, dst.w)
    let drawH = if scaleImage: dst.h else: min(h, dst.h)
    return AlphaBlend(gBackDC, dst.x.int32, dst.y.int32, drawW.int32, drawH.int32,
      dc, 0, 0, (if scaleImage: w else: drawW).int32,
      (if scaleImage: h else: drawH).int32, BlendFunction(alpha: 255, format: 1)) != 0
  # Blits clip a source-sized rectangle. Image draws map the full source
  # into the logical destination, using the same top-down DIB data.
  let drawW = if scaleImage: dst.w else: w
  let drawH = if scaleImage: dst.h else: h
  let clipW = if scaleImage: dst.w else: min(w, dst.w)
  let clipH = if scaleImage: dst.h else: min(h, dst.h)
  let saved = SaveDC(gBackDC)
  discard IntersectClipRect(gBackDC, dst.x.int32, dst.y.int32,
    int32(dst.x + clipW), int32(dst.y + clipH))
  discard StretchDIBits(gBackDC,
    dst.x.int32, dst.y.int32, drawW.int32, drawH.int32,
    0, 0, w.int32, h.int32,
    cast[pointer](pixels), addr bmi, DIB_RGB_COLORS, SRCCOPY)
  if saved != 0:
    discard RestoreDC(gBackDC, saved)
  result = true

proc winBlitRGBA(pixels: ptr UncheckedArray[uint32]; w, h: int;
                 dst: coords.Rect; format: RGBAFormat): bool =
  winPutRGBA(pixels, w, h, dst, false, format)

proc winDrawRGBA(pixels: ptr UncheckedArray[uint32]; w, h: int;
                 dst: coords.Rect; format: RGBAFormat): bool =
  winPutRGBA(pixels, w, h, dst, true, format)

type FaceInfo = object
  family: string     ## the name GDI selects the face by; "" if unknown
  weight: int
  italic: bool

proc readFaceInfo(path: string; faceIndex: int): FaceInfo =
  ## The GDI family name (`name` ID 1), weight and slant (`OS/2`) of the
  ## selected face in a TrueType/OpenType file or collection.
  var data: string
  try: data = readFile(path)
  except IOError, OSError: return
  proc u16(at: int): int =
    if at + 2 > data.len: 0
    else: (data[at].ord shl 8) or data[at+1].ord
  proc u32(at: int): int = (u16(at) shl 16) or u16(at + 2)
  var face = 0
  if data.len >= 16 and data[0 ..< 4] == "ttcf":
    if faceIndex < 0 or faceIndex >= u32(8): return
    face = u32(12 + faceIndex * 4)
  elif faceIndex != 0:
    return
  var nameAt, os2At = -1
  for i in 0 ..< u16(face + 4):
    let rec = face + 12 + i * 16
    if rec + 16 > data.len: break
    case data[rec ..< rec + 4]
    of "name": nameAt = u32(rec + 8)
    of "OS/2": os2At = u32(rec + 8)
    else: discard
  if os2At >= 0:
    result.weight = u16(os2At + 4)
    result.italic = (u16(os2At + 62) and 1) != 0
  if nameAt < 0: return
  let strings = nameAt + u16(nameAt + 4)
  var best = -1
  for i in 0 ..< u16(nameAt + 2):
    let rec = nameAt + 6 + i * 12
    # Windows Unicode BMP; the US English record is the one GDI matches.
    if u16(rec) == 3 and u16(rec + 2) == 1 and u16(rec + 6) == 1:
      if best < 0 or u16(rec + 4) == 0x409: best = rec
  if best < 0: return
  let start = strings + u16(best + 10)
  var w = newSeq[Utf16Char](u16(best + 8) div 2)
  for i in 0 ..< w.len: w[i] = Utf16Char(u16(start + 2 * i))
  w.add Utf16Char(0)
  result.family = $cast[WideCString](addr w[0])

proc winOpenFontFace(path: string; faceIndex, size: int; style: FontStyles;
                     metrics: var FontMetrics): screen.Font =
  # Ensure the font file is available as a private resource (needed for
  # fonts outside C:\Windows\Fonts, harmless for system-installed ones).
  let wpath = newWideCString(path)
  let FR_PRIVATE = 0x10'u32
  let info = readFaceInfo(path, faceIndex)
  if faceIndex < 0 or (faceIndex != 0 and info.family.len == 0):
    return screen.Font(0)
  let registered = path.len > 0 and
    AddFontResourceExW(cast[ptr uint16](wpath[0].addr), FR_PRIVATE, nil) > 0
  var keepRegistration = false
  defer:
    if registered and not keepRegistration:
      discard RemoveFontResourceExW(cast[ptr uint16](wpath[0].addr), FR_PRIVATE, nil)

  # Asked for outright, or -- for a path that names one face of a family --
  # read from the file, or detected from the filename.
  let lpath = path.toLowerAscii()
  let isBold = FontStyle.bold in style or
               (info.weight == 0 and "bold" in lpath)
  let isItalic = FontStyle.italics in style or info.italic or
                 (info.family.len == 0 and
                  ("italic" in lpath or "oblique" in lpath))
  let weight = if isBold: 700'i32
               elif info.weight > 0: info.weight.int32
               else: FW_NORMAL
  let italic = if isItalic: 1'u32 else: 0'u32
  let FIXED_PITCH = 1'u32

  # Map known font filenames to their GDI face names.
  # Consolas is the safe default -- ships since Vista with excellent
  # ClearType hinting.
  var faceName = "Consolas"
  let baseName = path.extractFilename.toLowerAscii
  if info.family.len > 0:
    faceName = info.family
  elif "dejavu" in baseName and "mono" in baseName:
    faceName = "DejaVu Sans Mono"
  elif "dejavu" in baseName:
    faceName = "DejaVu Sans"
  elif "consola" in baseName:
    faceName = "Consolas"
  elif "courier" in baseName:
    faceName = "Courier New"
  elif "arial" in baseName:
    faceName = "Arial"
  elif "segoe" in baseName:
    faceName = "Segoe UI"
  elif "cascadia" in baseName:
    if "mono" in baseName: faceName = "Cascadia Mono"
    else: faceName = "Cascadia Code"
  elif "hack" in baseName:
    faceName = "Hack"
  elif "fira" in baseName and "code" in baseName:
    faceName = "Fira Code"
  elif "roboto" in baseName and "mono" in baseName:
    faceName = "Roboto Mono"
  elif "source" in baseName and "code" in baseName:
    faceName = "Source Code Pro"
  elif "jetbrains" in baseName:
    faceName = "JetBrains Mono"
  else:
    # Unknown font -- use the filename stem as face name
    var stem = path.extractFilename
    let dot = stem.rfind('.')
    if dot >= 0: stem = stem[0 ..< dot]
    for suffix in ["-BoldOblique", "-BoldItalic", "-Bold", "-Oblique",
                   "-Italic", "-Regular"]:
      if stem.endsWith(suffix):
        stem = stem[0 ..< stem.len - suffix.len]
        break
    faceName = stem

  let wface = newWideCString(faceName)
  let hf = CreateFontW(
    -size.int32,          # negative = character height in pixels
    0, 0, 0,              # width, escapement, orientation
    weight,
    italic, 0, 0,         # italic, underline, strikeout
    DEFAULT_CHARSET.DWORD,
    OUT_TT_PRECIS,
    CLIP_DEFAULT_PRECIS,
    CLEARTYPE_QUALITY,
    FIXED_PITCH or FF_DONTCARE,
    cast[ptr uint16](wface[0].addr)
  )

  if hf == nil:
    return screen.Font(0)

  # Get font metrics
  let dc = CreateCompatibleDC(nil)
  if dc == nil:
    discard DeleteObject(cast[HGDIOBJ](hf))
    return screen.Font(0)
  defer: discard DeleteDC(dc)
  let oldFont = SelectObject(dc, cast[HGDIOBJ](hf))
  var tm: TEXTMETRICW
  discard GetTextMetricsW(dc, addr tm)
  discard SelectObject(dc, oldFont)

  metrics.ascent = tm.tmAscent.int
  metrics.descent = tm.tmDescent.int
  metrics.lineHeight = tm.tmHeight.int + tm.tmExternalLeading.int

  let slot = FontSlot(hFont: hf, metrics: metrics, faceName: path, size: size,
    registeredPath: (if registered: path else: ""))
  keepRegistration = registered
  for i in 0 ..< fonts.len:
    if fonts[i].hFont == nil:
      fonts[i] = slot
      return screen.Font(i + 1)
  fonts.add slot
  result = screen.Font(fonts.len)

proc winOpenFont(path: string; size: int; style: FontStyles;
                 metrics: var FontMetrics): screen.Font =
  winOpenFontFace(path, 0, size, style, metrics)

proc winCloseFont(f: screen.Font) =
  let idx = f.int - 1
  if idx >= 0 and idx < fonts.len and fonts[idx].hFont != nil:
    discard DeleteObject(cast[HGDIOBJ](fonts[idx].hFont))
    fonts[idx].hFont = nil
    if fonts[idx].registeredPath.len > 0:
      let path = newWideCString(fonts[idx].registeredPath)
      discard RemoveFontResourceExW(cast[ptr uint16](path[0].addr), 0x10, nil)
      fonts[idx].registeredPath.setLen(0)

proc winMeasureText(f: screen.Font; text: string): TextExtent =
  let hf = getFontHandle(f)
  if hf == nil or text.len == 0: return
  let dc = CreateCompatibleDC(nil)
  if dc == nil: return
  defer: discard DeleteDC(dc)
  let oldFont = SelectObject(dc, cast[HGDIOBJ](hf))
  let wtext = newWideCString(text)
  var sz: SIZE
  discard GetTextExtentPoint32W(dc, cast[ptr uint16](wtext[0].addr),
    wtext.len.int32, addr sz)
  discard SelectObject(dc, oldFont)
  result = TextExtent(w: sz.cx.int, h: sz.cy.int)

proc winDrawText(f: screen.Font; x, y: int; text: string;
                 fg, bg: screen.Color): TextExtent =
  let hf = getFontHandle(f)
  if hf == nil or text.len == 0: return
  let oldFont = SelectObject(gBackDC, cast[HGDIOBJ](hf))
  discard SetBkMode(gBackDC, OPAQUE)
  discard SetBkColor(gBackDC, rgb(bg))
  discard SetTextColor(gBackDC, rgb(fg))
  let wtext = newWideCString(text)
  let wlen = wtext.len.int32
  discard TextOutW(gBackDC, x.int32, y.int32,
    cast[ptr uint16](wtext[0].addr), wlen)
  var sz: SIZE
  discard GetTextExtentPoint32W(gBackDC, cast[ptr uint16](wtext[0].addr),
    wlen, addr sz)
  discard SelectObject(gBackDC, oldFont)
  result = TextExtent(w: sz.cx.int, h: sz.cy.int)

proc winRenderText(f: screen.Font; text: string; fg: screen.Color;
                   pixels: var seq[uint32]): TextExtent =
  pixels.setLen 0
  let hf = getFontHandle(f)
  if hf == nil or text.len == 0: return
  let dc = CreateCompatibleDC(nil)
  if dc == nil: return
  defer: discard DeleteDC(dc)
  let oldFont = SelectObject(dc, cast[HGDIOBJ](hf))
  defer: discard SelectObject(dc, oldFont)
  let wtext = newWideCString(text)
  let wlen = wtext.len.int32
  var sz: SIZE
  discard GetTextExtentPoint32W(dc, cast[ptr uint16](wtext[0].addr), wlen, addr sz)
  if sz.cx <= 0 or sz.cy <= 0: return
  var bmi = BITMAPINFO()
  bmi.bmiHeader.biSize = DWORD(sizeof(BITMAPINFOHEADER))
  bmi.bmiHeader.biWidth = sz.cx
  bmi.bmiHeader.biHeight = -sz.cy # top to bottom, as the pixels are handed out
  bmi.bmiHeader.biPlanes = 1
  bmi.bmiHeader.biBitCount = 32
  bmi.bmiHeader.biCompression = BI_RGB
  var data: pointer
  let bitmap = CreateDIBSection(dc, addr bmi, DIB_RGB_COLORS, addr data, nil, 0)
  if bitmap == nil: return
  defer: discard DeleteObject(cast[HGDIOBJ](bitmap))
  let oldBmp = SelectObject(dc, cast[HGDIOBJ](bitmap))
  defer: discard SelectObject(dc, oldBmp)
  # White on the black a new DIB starts as: what GDI writes is coverage, and
  # coverage times `fg` is the premultiplied pixel. ClearType coverage differs
  # per channel; its mean is the plain antialiased value.
  discard SetBkMode(dc, TRANSPARENT)
  discard SetTextColor(dc, rgb(screen.Color(r: 255, g: 255, b: 255, a: 255)))
  discard TextOutW(dc, 0, 0, cast[ptr uint16](wtext[0].addr), wlen)
  discard GdiFlush()
  let n = sz.cx.int * sz.cy.int
  let src = cast[ptr UncheckedArray[uint32]](data)
  pixels.setLen n
  for i in 0 ..< n:
    let p = src[i]
    let coverage = (((p shr 16) and 0xFF) + ((p shr 8) and 0xFF) + (p and 0xFF)) div 3
    let a = coverage * fg.a.uint32 div 255
    pixels[i] = (a shl 24) or ((fg.r.uint32 * a div 255) shl 16) or
                ((fg.g.uint32 * a div 255) shl 8) or (fg.b.uint32 * a div 255)
  result = TextExtent(w: sz.cx.int, h: sz.cy.int)

proc winGetFontMetrics(f: screen.Font): FontMetrics =
  let idx = f.int - 1
  if idx >= 0 and idx < fonts.len: fonts[idx].metrics
  else: screen.FontMetrics()

proc winFillRect(r: coords.Rect; color: screen.Color) =
  if r.w <= 0 or r.h <= 0 or color.a == 0: return
  if color.a < 255:
    let a = color.a.uint32
    var pixel = (a shl 24) or
      (((color.r.uint32 * a + 127) div 255) shl 16) or
      (((color.g.uint32 * a + 127) div 255) shl 8) or
      ((color.b.uint32 * a + 127) div 255)
    if not winDrawRGBA(cast[ptr UncheckedArray[uint32]](addr pixel),
        1, 1, r, RGBAFormat.argbPremultiplied):
      raise newException(ValueError, "Cannot blend a native GDI rectangle")
    return
  let brush = CreateSolidBrush(rgb(color))
  var wr = WINAPIRECT(
    left: r.x.int32, top: r.y.int32,
    right: (r.x + r.w).int32, bottom: (r.y + r.h).int32)
  discard FillRectGdi(gBackDC, addr wr, brush)
  discard DeleteObject(cast[HGDIOBJ](brush))

proc winDrawLine(x1, y1, x2, y2: int; color: screen.Color) =
  let pen = CreatePen(0, 1, rgb(color)) # PS_SOLID = 0
  let oldPen = SelectObject(gBackDC, pen)
  discard MoveToEx(gBackDC, x1.int32, y1.int32, nil)
  discard LineTo(gBackDC, x2.int32, y2.int32)
  discard SelectObject(gBackDC, oldPen)
  discard DeleteObject(pen)

proc winDrawPoint(x, y: int; color: screen.Color) =
  discard SetPixel(gBackDC, x.int32, y.int32, rgb(color))

proc winSetCursor(c: CursorKind) =
  let id = case c
    of curDefault, curArrow: IDC_ARROW
    of curIbeam: IDC_IBEAM
    of curWait: IDC_WAIT
    of curCrosshair: IDC_CROSS
    of curHand: IDC_HAND
    of curSizeNS: IDC_SIZENS
    of curSizeWE: IDC_SIZEWE
    of curSizeNWSE: IDC_SIZENWSE
    of curSizeNESW: IDC_SIZENESW
    of curMove: IDC_SIZEALL
  let cur = LoadCursorW(nil, id)
  gCursor = cur
  discard SetCursorWin(cur)

proc winSetWindowTitle(title: string) =
  if gHwnd != nil:
    let wtitle = newWideCString(title)
    discard SetWindowTextW(gHwnd, cast[ptr uint16](wtitle[0].addr))

# ---- Frame hook implementations ----

proc winSetSystemFrame(on: bool): bool =
  if on != gSystemFrame:
    gSystemFrame = on
    if gHwnd != nil:
      # The style changes and the frame is worked out again (WM_NCCALCSIZE);
      # the window stays where it is, as large as it was.
      let keep = uint32(GetWindowLongPtrW(gHwnd, GWL_STYLE) and 0xFFFFFFFF) and
                 (WS_VISIBLE or WS_MINIMIZE or WS_MAXIMIZE)
      discard SetWindowLongPtrW(gHwnd, GWL_STYLE,
        styleWord(keep or (if on: WS_OVERLAPPEDWINDOW else: WS_FRAMELESS)))
      discard SetWindowPos(gHwnd, nil, 0, 0, 0, 0,
        SWP_FRAMECHANGED or SWP_NOMOVE or SWP_NOSIZE or SWP_NOZORDER or
        SWP_NOACTIVATE or SWP_NOOWNERZORDER)
  true

proc winDragWindow(part: WindowPart; keyboard: bool): bool =
  if gHwnd == nil or part == wpClient: return false
  if keyboard:
    # A control menu's Move or Size: Windows' own loop, with the arrow keys.
    discard SendMessageW(gHwnd, WM_SYSCOMMAND,
                         WPARAM(if part == wpCaption: SC_MOVE else: SC_SIZE), 0)
    return true
  # Let go already (the release waits in the queue): nothing to drag.
  if GetKeyState(VK_LBUTTON) >= 0: return false
  let ht = case part
    of wpLeft: HTLEFT
    of wpRight: HTRIGHT
    of wpTop: HTTOP
    of wpBottom: HTBOTTOM
    of wpTopLeft: HTTOPLEFT
    of wpTopRight: HTTOPRIGHT
    of wpBottomLeft: HTBOTTOMLEFT
    of wpBottomRight: HTBOTTOMRIGHT
    else: HTCAPTION
  var pt: WINAPIPOINT
  discard GetCursorPos(addr pt)
  discard ReleaseCapture()
  # A press on a title bar or an edge of Windows' own: DefWindowProc runs the
  # move or the sizing (with Aero Snap) until the button is let go...
  discard SendMessageW(gHwnd, WM_NCLBUTTONDOWN, WPARAM(ht),
    LPARAM((pt.x.int and 0xFFFF) or ((pt.y.int and 0xFFFF) shl 16)))
  # ... and takes the release with it, so it is reported here.
  discard GetCursorPos(addr pt)
  discard ScreenToClient(gHwnd, addr pt)
  pushEvent(input.Event(kind: MouseUpEvent, hasMods: true, mods: getModifiers(),
                        x: pt.x.int, y: pt.y.int, button: LeftButton))
  true

proc winSetMaximized(on: bool) =
  if gHwnd != nil: discard ShowWindow(gHwnd, if on: SW_MAXIMIZE else: SW_RESTORE)

proc winMaximized(): bool = gHwnd != nil and IsZoomed(gHwnd) != 0

proc winActive(): bool = gHwnd != nil and GetActiveWindow() == gHwnd

proc winMinimize(): bool =
  if gHwnd == nil: return false
  discard ShowWindow(gHwnd, SW_MINIMIZE)
  true

# ---- Files dragged out of the window (OLE) ----
#
# `dragOut` hands the files to OLE's DoDragDrop, which runs the drag until
# the button is let go: a data object that offers them as CF_HDROP
# (DROPFILES and the paths in UTF-16) -- what Explorer, Outlook and browsers
# take -- and as the shell's "Shell IDList Array" (what Explorer's own drags
# carry, and all some shells take), and a drop source that says when it ends
# (the release: drop; Esc: cancel) and leaves the pointers to Windows. Both
# are COM objects written out
# here, a table of procs and a count of references, one of each: there is one
# drag at a time, and what the data object hands out is a copy each time.
# OLE is started on this thread, the window's, at the first drag. The window
# takes no drop of its own files meanwhile (DragAcceptFiles off).

type
  HRESULT = int32
  GUID {.pure.} = object
    d1: uint32
    d2, d3: uint16
    d4: array[8, uint8]
  FORMATETC {.pure.} = object
    cfFormat: uint16
    ptd: pointer
    dwAspect: DWORD
    lindex: LONG
    tymed: DWORD
  STGMEDIUM {.pure.} = object
    tymed: DWORD
    hGlobal: HGLOBAL
    pUnkForRelease: pointer

  ComObject {.pure.} = object
    vtbl: pointer
    refs: int32

  DataObjectVtbl {.pure.} = object
    queryInterface: proc (this: ptr ComObject; riid: ptr GUID; ppv: ptr pointer): HRESULT {.stdcall.}
    addRef: proc (this: ptr ComObject): uint32 {.stdcall.}
    release: proc (this: ptr ComObject): uint32 {.stdcall.}
    getData: proc (this: ptr ComObject; fmt: ptr FORMATETC; medium: ptr STGMEDIUM): HRESULT {.stdcall.}
    getDataHere: proc (this: ptr ComObject; fmt: ptr FORMATETC; medium: ptr STGMEDIUM): HRESULT {.stdcall.}
    queryGetData: proc (this: ptr ComObject; fmt: ptr FORMATETC): HRESULT {.stdcall.}
    getCanonicalFormatEtc: proc (this: ptr ComObject; fmtIn, fmtOut: ptr FORMATETC): HRESULT {.stdcall.}
    setData: proc (this: ptr ComObject; fmt: ptr FORMATETC; medium: ptr STGMEDIUM;
                   release: BOOL): HRESULT {.stdcall.}
    enumFormatEtc: proc (this: ptr ComObject; direction: DWORD; enumOut: ptr pointer): HRESULT {.stdcall.}
    dAdvise: proc (this: ptr ComObject; fmt: ptr FORMATETC; advf: DWORD; sink: pointer;
                   conn: ptr DWORD): HRESULT {.stdcall.}
    dUnadvise: proc (this: ptr ComObject; conn: DWORD): HRESULT {.stdcall.}
    enumDAdvise: proc (this: ptr ComObject; enumOut: ptr pointer): HRESULT {.stdcall.}

  DropSourceVtbl {.pure.} = object
    queryInterface: proc (this: ptr ComObject; riid: ptr GUID; ppv: ptr pointer): HRESULT {.stdcall.}
    addRef: proc (this: ptr ComObject): uint32 {.stdcall.}
    release: proc (this: ptr ComObject): uint32 {.stdcall.}
    queryContinueDrag: proc (this: ptr ComObject; escape: BOOL; keys: DWORD): HRESULT {.stdcall.}
    giveFeedback: proc (this: ptr ComObject; effect: DWORD): HRESULT {.stdcall.}

const
  S_OK = 0'i32
  S_FALSE = 1'i32
  E_NOINTERFACE = cast[int32](0x80004002'u32)
  E_NOTIMPL = cast[int32](0x80004001'u32)
  DV_E_FORMATETC = cast[int32](0x80040064'u32)
  OLE_E_ADVISENOTSUPPORTED = cast[int32](0x80040003'u32)
  DRAGDROP_S_DROP = 0x00040100'i32
  DRAGDROP_S_CANCEL = 0x00040101'i32
  DRAGDROP_S_USEDEFAULTCURSORS = 0x00040102'i32
  DROPEFFECT_COPY = 1'u32
  DROPEFFECT_MOVE = 2'u32
  DROPEFFECT_LINK = 4'u32
  CF_HDROP = 15'u16
  TYMED_HGLOBAL = 1'u32
  DVASPECT_CONTENT = 1'u32
  DATADIR_GET = 1'u32
  GA_ROOT = 2'u32
  IID_IUnknown = GUID(d1: 0x00000000'u32, d2: 0, d3: 0,
                      d4: [0xC0'u8, 0, 0, 0, 0, 0, 0, 0x46])
  IID_IDataObject = GUID(d1: 0x0000010E'u32, d2: 0, d3: 0,
                         d4: [0xC0'u8, 0, 0, 0, 0, 0, 0, 0x46])
  IID_IDropSource = GUID(d1: 0x00000121'u32, d2: 0, d3: 0,
                         d4: [0xC0'u8, 0, 0, 0, 0, 0, 0, 0x46])

proc OleInitialize(reserved: pointer): HRESULT
  {.stdcall, dynlib: "ole32", importc.}
proc DoDragDrop(dataObj, dropSource: pointer; okEffects: DWORD;
                effect: ptr DWORD): HRESULT
  {.stdcall, dynlib: "ole32", importc.}
proc ReleaseStgMedium(medium: ptr STGMEDIUM)
  {.stdcall, dynlib: "ole32", importc.}
proc SHCreateStdEnumFmtEtc(n: UINT; fmts: ptr FORMATETC; enumOut: ptr pointer): HRESULT
  {.stdcall, dynlib: "shell32", importc.}
proc RegisterClipboardFormatW(name: WideCString): UINT
  {.stdcall, dynlib: "user32", importc.}
proc WindowFromPoint(pt: WINAPIPOINT): HWND
  {.stdcall, dynlib: "user32", importc.}
proc GetAncestor(hWnd: HWND; flags: UINT): HWND
  {.stdcall, dynlib: "user32", importc.}
proc ILCreateFromPathW(path: WideCString): pointer
  {.stdcall, dynlib: "shell32", importc.}
proc ILGetSize(idl: pointer): UINT
  {.stdcall, dynlib: "shell32", importc.}
proc ILFree(idl: pointer)
  {.stdcall, dynlib: "shell32", importc.}
proc ILFindLastID(idl: pointer): pointer
  {.stdcall, dynlib: "shell32", importc.}
proc GetAsyncKeyState(vKey: int32): int16
  {.stdcall, dynlib: "user32", importc.}

var
  gOle = 0                  ## OLE on this thread: 0 not tried, 1 started, -1 cannot
  cfPerformed, cfLogicalPerformed: UINT   ## what a target says it did
  cfShellIdList: UINT       ## "Shell IDList Array"
  gOutData: array[2, string] ## the files of the drag: CF_HDROP's block, the IDList Array
  gOutBack: bool            ## the drag ends when the pointer comes back in
  gOutCameBack: bool        ## ... and it did
  gOutDid: DWORD            ## the target did this ("Performed DropEffect")
  gOutDidLogically: DWORD   ## ... in effect: a move done as a copy and a delete
                            ## (Explorer's moves on one disk: DoDragDrop says none)
  gDataObject, gDropSource: ComObject

proc sameGuid(a: ptr GUID; b: GUID): bool =
  a.d1 == b.d1 and a.d2 == b.d2 and a.d3 == b.d3 and a.d4 == b.d4

proc comAddRef(this: ptr ComObject): uint32 {.stdcall.} =
  inc this.refs
  uint32(this.refs)

proc comRelease(this: ptr ComObject): uint32 {.stdcall.} =
  # (static: nothing to free when it comes to none)
  if this.refs > 0: dec this.refs
  uint32(this.refs)

proc dataQueryInterface(this: ptr ComObject; riid: ptr GUID; ppv: ptr pointer): HRESULT {.stdcall.} =
  if sameGuid(riid, IID_IUnknown) or sameGuid(riid, IID_IDataObject):
    ppv[] = this
    discard comAddRef(this)
    return S_OK
  ppv[] = nil
  E_NOINTERFACE

proc shellIdListOf(paths: seq[string]): string =
  ## The files as the shell names them ("Shell IDList Array", CIDA): their
  ## count, where each item list starts, their folder's item list and each
  ## file's within it -- or, files of several folders, the desktop's (empty)
  ## and each file's full one. Empty when the shell knows none.
  proc bytes(idl: pointer): string =
    result = newString(ILGetSize(idl).int)       # (with its closing 0)
    if result.len > 0: copyMem(addr result[0], idl, result.len)
  var folder = paths[0].parentDir
  for p in paths:
    if p.parentDir != folder: folder = ""
  let folderIdl = if folder.len > 0: ILCreateFromPathW(newWideCString(folder)) else: nil
  var items: seq[string]
  for p in paths:
    let idl = ILCreateFromPathW(newWideCString(p))
    if idl != nil:
      items.add bytes(if folderIdl != nil: ILFindLastID(idl) else: idl)
      ILFree(idl)
  if items.len == 0 or items.len != paths.len:
    if folderIdl != nil: ILFree(folderIdl)
    return ""
  proc put32(s: var string; at: int; v: int) =
    for i in 0 .. 3: s[at + i] = char((v shr (8 * i)) and 0xFF)
  result = newString(4 * (items.len + 2))
  result.put32(0, items.len)
  result.put32(4, result.len)
  if folderIdl != nil:
    result.add bytes(folderIdl)
    ILFree(folderIdl)
  else:
    result.add "\0\0"                            # (the desktop)
  for i, s in items:
    result.put32(4 * (i + 2), result.len)
    result.add s

proc offered(fmt: ptr FORMATETC): int =
  ## Which of the drag's forms `fmt` asks for (-1: none).
  if (fmt.tymed and TYMED_HGLOBAL) == 0 or fmt.dwAspect != DVASPECT_CONTENT: return -1
  if fmt.cfFormat == CF_HDROP: 0
  elif fmt.cfFormat.UINT == cfShellIdList and cfShellIdList != 0 and gOutData[1].len > 0: 1
  else: -1

proc dataGetData(this: ptr ComObject; fmt: ptr FORMATETC; medium: ptr STGMEDIUM): HRESULT {.stdcall.} =
  # A copy of the files' block each time: the taker frees it.
  let k = offered(fmt)
  if k < 0 or gOutData[k].len == 0: return DV_E_FORMATETC
  let h = GlobalAlloc(GMEM_MOVEABLE, gOutData[k].len.uint)
  if h == nil: return cast[int32](0x8007000E'u32)          # E_OUTOFMEMORY
  let p = GlobalLock(h)
  copyMem(p, addr gOutData[k][0], gOutData[k].len)
  discard GlobalUnlock(h)
  medium.tymed = TYMED_HGLOBAL
  medium.hGlobal = h
  medium.pUnkForRelease = nil
  S_OK

proc dataGetDataHere(this: ptr ComObject; fmt: ptr FORMATETC; medium: ptr STGMEDIUM): HRESULT {.stdcall.} =
  E_NOTIMPL

proc dataQueryGetData(this: ptr ComObject; fmt: ptr FORMATETC): HRESULT {.stdcall.} =
  if offered(fmt) >= 0: S_OK else: DV_E_FORMATETC

proc dataCanonical(this: ptr ComObject; fmtIn, fmtOut: ptr FORMATETC): HRESULT {.stdcall.} =
  fmtOut.ptd = nil
  E_NOTIMPL

proc dataSetData(this: ptr ComObject; fmt: ptr FORMATETC; medium: ptr STGMEDIUM;
                 release: BOOL): HRESULT {.stdcall.} =
  # Only what the target says it did is kept; the rest (Explorer's drag
  # images and descriptions) is not wanted.
  if fmt.cfFormat.UINT notin [cfPerformed, cfLogicalPerformed] or
     medium.tymed != TYMED_HGLOBAL or medium.hGlobal == nil:
    return E_NOTIMPL
  let p = cast[ptr DWORD](GlobalLock(medium.hGlobal))
  if p != nil:
    if fmt.cfFormat.UINT == cfPerformed: gOutDid = p[] else: gOutDidLogically = p[]
    discard GlobalUnlock(medium.hGlobal)
  if release != 0: ReleaseStgMedium(medium)
  S_OK

proc dataEnumFormatEtc(this: ptr ComObject; direction: DWORD; enumOut: ptr pointer): HRESULT {.stdcall.} =
  if direction != DATADIR_GET:
    enumOut[] = nil
    return E_NOTIMPL
  var fmts = [FORMATETC(cfFormat: CF_HDROP, dwAspect: DVASPECT_CONTENT, lindex: -1,
                        tymed: TYMED_HGLOBAL),
              FORMATETC(cfFormat: uint16(cfShellIdList), dwAspect: DVASPECT_CONTENT,
                        lindex: -1, tymed: TYMED_HGLOBAL)]
  SHCreateStdEnumFmtEtc(if gOutData[1].len > 0 and cfShellIdList != 0: 2 else: 1,
                        addr fmts[0], enumOut)

proc dataDAdvise(this: ptr ComObject; fmt: ptr FORMATETC; advf: DWORD; sink: pointer;
                 conn: ptr DWORD): HRESULT {.stdcall.} =
  OLE_E_ADVISENOTSUPPORTED

proc dataDUnadvise(this: ptr ComObject; conn: DWORD): HRESULT {.stdcall.} =
  OLE_E_ADVISENOTSUPPORTED

proc dataEnumDAdvise(this: ptr ComObject; enumOut: ptr pointer): HRESULT {.stdcall.} =
  enumOut[] = nil
  OLE_E_ADVISENOTSUPPORTED

proc sourceQueryInterface(this: ptr ComObject; riid: ptr GUID; ppv: ptr pointer): HRESULT {.stdcall.} =
  if sameGuid(riid, IID_IUnknown) or sameGuid(riid, IID_IDropSource):
    ppv[] = this
    discard comAddRef(this)
    return S_OK
  ppv[] = nil
  E_NOINTERFACE

proc pointerBackInside(): bool =
  ## The pointer is over the window's own part again, a little way in.
  var pt: WINAPIPOINT
  if gHwnd == nil or GetCursorPos(addr pt) == 0: return false
  let w = WindowFromPoint(pt)
  if w == nil or GetAncestor(w, GA_ROOT) != gHwnd: return false
  discard ScreenToClient(gHwnd, addr pt)
  const m = 4
  pt.x >= m and pt.y >= m and pt.x < gWidth - m and pt.y < gHeight - m

proc sourceQueryContinueDrag(this: ptr ComObject; escape: BOOL; keys: DWORD): HRESULT {.stdcall.} =
  # (Esc: OLE sees it when the keyboard is this thread's; the key itself is
  # asked too, wherever the keyboard went)
  if escape != 0 or GetAsyncKeyState(VK_ESCAPE.int32) < 0: return DRAGDROP_S_CANCEL
  if (keys and MK_LBUTTON) == 0: return DRAGDROP_S_DROP
  if gOutBack and pointerBackInside():
    gOutCameBack = true
    return DRAGDROP_S_CANCEL
  S_OK

proc sourceGiveFeedback(this: ptr ComObject; effect: DWORD): HRESULT {.stdcall.} =
  DRAGDROP_S_USEDEFAULTCURSORS

var
  dataObjectVtbl = DataObjectVtbl(
    queryInterface: dataQueryInterface, addRef: comAddRef, release: comRelease,
    getData: dataGetData, getDataHere: dataGetDataHere, queryGetData: dataQueryGetData,
    getCanonicalFormatEtc: dataCanonical, setData: dataSetData,
    enumFormatEtc: dataEnumFormatEtc, dAdvise: dataDAdvise, dUnadvise: dataDUnadvise,
    enumDAdvise: dataEnumDAdvise)
  dropSourceVtbl = DropSourceVtbl(
    queryInterface: sourceQueryInterface, addRef: comAddRef, release: comRelease,
    queryContinueDrag: sourceQueryContinueDrag, giveFeedback: sourceGiveFeedback)

proc winDragFilesOut(paths: seq[string]; move, backInside: bool): DragOutResult =
  if gHwnd == nil or paths.len == 0: return drNone
  if GetKeyState(VK_LBUTTON) >= 0: return drNone          # (let go already)
  if gOle == 0:
    let hr = OleInitialize(nil)
    gOle = if hr == S_OK or hr == S_FALSE: 1 else: -1
    cfPerformed = RegisterClipboardFormatW(newWideCString("Performed DropEffect"))
    cfLogicalPerformed = RegisterClipboardFormatW(newWideCString("Logical Performed DropEffect"))
    cfShellIdList = RegisterClipboardFormatW(newWideCString("Shell IDList Array"))
  if gOle < 0: return drNone
  gOutData = [hdropOfFiles(paths), shellIdListOf(paths)]
  gOutBack = backInside
  gOutCameBack = false
  gOutDid = 0
  gOutDidLogically = 0
  gDataObject = ComObject(vtbl: addr dataObjectVtbl, refs: 1)
  gDropSource = ComObject(vtbl: addr dropSourceVtbl, refs: 1)
  let queued = eventQueue.len
  DragAcceptFiles(gHwnd, 0)
  var effect: DWORD = 0
  let hr = DoDragDrop(addr gDataObject, addr gDropSource,
                      DROPEFFECT_COPY or (if move: DROPEFFECT_MOVE else: 0), addr effect)
  DragAcceptFiles(gHwnd, 1)
  # Keys and clicks that came meanwhile were the drag's.
  var kept: seq[input.Event]
  for i in queued ..< eventQueue.len:
    if eventQueue[i].kind notin {KeyDownEvent, KeyUpEvent, TextInputEvent, MouseDownEvent,
                                 MouseUpEvent, MouseMoveEvent, MouseWheelEvent}:
      kept.add eventQueue[i]
  eventQueue.setLen(queued)
  eventQueue.add kept
  result =
    if hr == DRAGDROP_S_DROP:
      if (effect and DROPEFFECT_MOVE) != 0 or gOutDidLogically == DROPEFFECT_MOVE or
         gOutDid == DROPEFFECT_MOVE: drMoved
      elif (effect and (DROPEFFECT_COPY or DROPEFFECT_LINK)) != 0: drCopied
      else: drCancelled
    elif hr == DRAGDROP_S_CANCEL:
      if gOutCameBack: drBack else: drCancelled
    else: drNone
  # Let go, the release was the drag's: it is reported here. Still down (Esc,
  # back over the window): the window takes the mouse again for its release.
  var pt: WINAPIPOINT
  discard GetCursorPos(addr pt)
  discard ScreenToClient(gHwnd, addr pt)
  if GetKeyState(VK_LBUTTON) < 0:
    discard SetCapture(gHwnd)
    pushEvent(input.Event(kind: MouseMoveEvent, hasMods: true, mods: getModifiers(),
                          x: pt.x.int, y: pt.y.int))
  else:
    pushEvent(input.Event(kind: MouseUpEvent, hasMods: true, mods: getModifiers(),
                          x: pt.x.int, y: pt.y.int, button: LeftButton))

# ---- Input hook implementations ----

proc winPollEvent(e: var input.Event; flags: set[InputFlag]): bool =
  pumpMessages()
  if eventQueue.len > 0:
    e = eventQueue[0]
    eventQueue.delete(0)
    return true
  return false

proc winWaitEvent(e: var input.Event; timeoutMs: int;
                  flags: set[InputFlag]): bool =
  # Check already-queued events first
  if eventQueue.len > 0:
    e = eventQueue[0]
    eventQueue.delete(0)
    return true
  # Drain any pending Win32 messages before blocking
  if winPollEvent(e, flags):
    return true
  # Pump messages in a loop with short sleeps, like SDL does internally.
  # A single MWFMO(INFINITE) would block the thread entirely, causing
  # Windows to show the "Not Responding" ghost window after ~5 seconds
  # which then intercepts all user input -- deadlock.
  let deadline = if timeoutMs < 0: uint32.high
                 else: GetTickCount() + timeoutMs.uint32
  while true:
    let now = GetTickCount()
    if now >= deadline: return false
    let remaining = if timeoutMs < 0: 100'u32
                    else: min(deadline - now, 100'u32)
    let res = MsgWaitForMultipleObjects(0, nil, 0, remaining, QS_ALLINPUT)
    if res != WAIT_TIMEOUT:
      if winPollEvent(e, flags): return true
    elif timeoutMs >= 0:
      # Finite timeout: check if expired
      if GetTickCount() >= deadline: return false

proc winGetClipboardText(): string =
  if OpenClipboard(gHwnd) == 0: return ""
  let hData = GetClipboardData(CF_UNICODETEXT)
  if hData != nil:
    let p = cast[ptr UncheckedArray[uint16]](GlobalLock(cast[HGLOBAL](hData)))
    if p != nil:
      var wlen = 0
      while p[wlen] != 0: inc wlen
      var ws = newWideCString("", wlen)
      copyMem(addr ws[0], p, wlen * 2)
      result = $ws
      discard GlobalUnlock(cast[HGLOBAL](hData))
  discard CloseClipboard()

proc winPutClipboardText(text: string) =
  if OpenClipboard(gHwnd) == 0: return
  discard EmptyClipboard()
  let ws = newWideCString(text)
  let bytes = (ws.len + 1) * 2
  let hMem = GlobalAlloc(GMEM_MOVEABLE, bytes.uint)
  if hMem != nil:
    let p = GlobalLock(hMem)
    if p != nil:
      copyMem(p, addr ws[0], bytes)
      discard GlobalUnlock(hMem)
      discard SetClipboardData(CF_UNICODETEXT, cast[HANDLE](hMem))
  discard CloseClipboard()

proc winGetTicks(): int = GetTickCount().int
proc winDelay(ms: int) =
  let msU = ms.DWORD
  let deadline = GetTickCount() + msU
  while true:
    let now = GetTickCount()
    if now >= deadline: break
    let remaining = min(deadline - now, msU)
    discard MsgWaitForMultipleObjects(0, nil, 0, remaining, QS_ALLINPUT)
    pumpMessages()
proc winQuitRequest() =
  gQuitFlag = true
  if gHwnd != nil:
    discard DestroyWindow(gHwnd)

# ---- Init ----

proc setDpiAware() =
  # Try the modern API first (Windows 10 1703+), fall back to older ones.
  # Without this, Windows bitmap-scales the window on high-DPI displays,
  # causing blurry/pixelated rendering.
  type DPI_AWARENESS_CONTEXT = HANDLE
  try:
    proc SetProcessDpiAwarenessContext(value: DPI_AWARENESS_CONTEXT): BOOL
      {.stdcall, dynlib: "user32", importc.}
    let DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = cast[DPI_AWARENESS_CONTEXT](-4)
    if SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) != 0:
      return
  except: discard
  try:
    proc SetProcessDPIAware(): BOOL
      {.stdcall, dynlib: "user32", importc.}
    discard SetProcessDPIAware()
  except: discard

proc winapiFontRelays*(): FontRelays =
  ## A font provider independent of the installed window/drawing relays.
  FontRelays(
    openFont: winOpenFont, openFontFace: winOpenFontFace, closeFont: winCloseFont,
    getFontMetrics: winGetFontMetrics, measureText: winMeasureText,
    drawText: winDrawText, renderText: winRenderText)

proc initWinapiFontRelays*() =
  ## Installs only the Win32 font provider.
  fontRelays = winapiFontRelays()

proc initWinapiDriver*() =
  gpuRelays = GpuRelays(
    startGpu: winStartGpu, stopGpu: winStopGpu,
    swapGpu: proc (): bool = gGpu and SwapBuffers(gGlDC) != 0,
    gpuProc: winGpuProc,
    gpuIsEs: proc (): bool = false,
    gpuGeneration: proc (): int = 0,
    gpuReady: proc (): bool = gGpu)
  setDpiAware()
  windowRelays = WindowRelays(
    createWindow: winCreateWindow, getWindowLayout: winGetWindowLayout,
    refresh: winRefresh,
    saveState: winSaveState, restoreState: winRestoreState,
    setClipRect: winSetClipRect, setCursor: winSetCursor,
    pointerHeight: winPointerHeight,
    setWindowTitle: winSetWindowTitle)
  frameRelays = FrameRelays(
    setSystemFrame: winSetSystemFrame, dragWindow: winDragWindow,
    setMaximized: winSetMaximized, maximized: winMaximized, active: winActive)
  systemRelays.minimize = winMinimize
  fileDragRelays = FileDragRelays(dragOut: winDragFilesOut)
  initWinapiFontRelays()
  drawRelays = DrawRelays(
    fillRect: winFillRect, drawLine: winDrawLine, drawPoint: winDrawPoint,
    blitRGBA: winBlitRGBA, drawRGBA: winDrawRGBA)
  inputRelays = InputRelays(
    pollEvent: winPollEvent, waitEvent: winWaitEvent,
    getTicks: winGetTicks, sleep: winDelay,
    shutdown: winQuitRequest)
  clipboardRelays = ClipboardRelays(
    getText: winGetClipboardText, putText: winPutClipboardText)

var siwinSurfaceOwned = false

proc detachSiwinSurface*() =
  if siwinSurfaceOwned and gBackDC != nil:
    discard SelectObject(gBackDC, gOldBmp)
    discard DeleteObject(cast[HGDIOBJ](gBackBmp))
    discard DeleteDC(gBackDC)
  gBackDC = nil
  gBackBmp = nil
  gOldBmp = nil
  gWidth = 0
  gHeight = 0
  siwinSurfaceOwned = false

proc attachSiwinSurface*(dc: pointer; width, height: int) =
  ## Own a persistent GDI compositor, independent of Siwin's replaceable DIB.
  if dc == nil or width <= 0 or height <= 0: return
  if siwinSurfaceOwned and gWidth == width.int32 and gHeight == height.int32: return
  let nextDC = CreateCompatibleDC(cast[HDC](dc))
  if nextDC == nil: raise newException(ValueError, "Cannot create the GDI compositor")
  let nextBitmap = CreateCompatibleBitmap(cast[HDC](dc), width.int32, height.int32)
  if nextBitmap == nil:
    discard DeleteDC(nextDC)
    raise newException(ValueError, "Cannot create the GDI backing bitmap")
  let previous = SelectObject(nextDC, cast[HGDIOBJ](nextBitmap))
  var area = WINAPIRECT(left: 0, top: 0, right: width.int32, bottom: height.int32)
  let brush = CreateSolidBrush(0)
  discard FillRectGdi(nextDC, addr area, brush)
  discard DeleteObject(cast[HGDIOBJ](brush))
  if siwinSurfaceOwned:
    discard BitBlt(nextDC, 0, 0, min(width.int32, gWidth), min(height.int32, gHeight),
      gBackDC, 0, 0, SRCCOPY)
    detachSiwinSurface()
  gBackDC = nextDC
  gBackBmp = nextBitmap
  gOldBmp = previous
  gWidth = width.int32
  gHeight = height.int32
  siwinSurfaceOwned = true

proc presentSiwinSurface*(dc: pointer): bool =
  gBackDC != nil and dc != nil and BitBlt(cast[HDC](dc), 0, 0, gWidth, gHeight,
    gBackDC, 0, 0, SRCCOPY) != 0
