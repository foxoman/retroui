# Platform-independent input events and relays.
# Part of the core stdlib abstraction.

type
  KeyCode* = enum
    KeyNone,
    KeyA, KeyB, KeyC, KeyD, KeyE, KeyF, KeyG, KeyH, KeyI, KeyJ,
    KeyK, KeyL, KeyM, KeyN, KeyO, KeyP, KeyQ, KeyR, KeyS, KeyT,
    KeyU, KeyV, KeyW, KeyX, KeyY, KeyZ,
    Key0, Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8, Key9,
    KeyF1, KeyF2, KeyF3, KeyF4, KeyF5, KeyF6,
    KeyF7, KeyF8, KeyF9, KeyF10, KeyF11, KeyF12,
    KeyEnter, KeySpace, KeyEsc, KeyTab,
    KeyBackspace, KeyDelete, KeyInsert,
    KeyLeft, KeyRight, KeyUp, KeyDown,
    KeyPageUp, KeyPageDown, KeyHome, KeyEnd,
    KeyCapslock, KeyComma, KeyPeriod, KeySlash,
    KeyMinus, KeyEqual, KeyPlus,
    KeyLeftBracket, KeyRightBracket, KeySemicolon, KeyQuote,
    KeyBackslash, KeyBackquote, KeyMenu

  EventKind* = enum
    NoEvent,
    KeyDownEvent, KeyUpEvent, TextInputEvent,
    MouseDownEvent, MouseUpEvent, MouseMoveEvent, MouseWheelEvent,
    WindowResizeEvent, WindowMetricsEvent, WindowCloseEvent,
    WindowFocusGainedEvent, WindowFocusLostEvent,
    QuitEvent,
    AppPauseEvent,   ## mobile: the app goes to the background; stop drawing
    AppResumeEvent,  ## mobile: the app is back; redraw everything
    GestureEvent,    ## touch: two fingers pinched (`scale`) or moved (`dx`,
                     ## `dy`) round their middle (`x`, `y`)
    FileDropEvent    ## files dragged from the system's file manager were
                     ## dropped on the window: their paths (`files`) and
                     ## where (`x`, `y`). A desktop driver takes drops
                     ## always; there is nothing to ask for.

  GesturePhase* = enum
    gsBegin,         ## a second finger came down; the first one's press is
                     ## released far outside the window, so nothing is clicked
    gsChange,        ## the fingers moved
    gsEnd            ## a finger was lifted

  Modifier* = enum
    ShiftPressed, CtrlPressed, AltPressed, GuiPressed

  MouseButton* = enum
    LeftButton, RightButton, MiddleButton,
    BackButton,     ## side button X1 (back)
    ForwardButton   ## side button X2 (forward)

  InputFlag* = enum
    WantTextInput   ## show on-screen keyboard / enable IME

  Event* = object
    kind*: EventKind
    key*: KeyCode
    mods*: set[Modifier]
    hasMods*: bool         ## `mods` is set for this event (some drivers set
                           ## it for keys only)
    text*: array[4, char]  ## TextInputEvent: one UTF-8 codepoint, no alloc
    x*, y*: int            ## mouse position, scroll delta, or new window size
    scaleX*, scaleY*: int  ## WindowMetricsEvent: device pixels per coordinate
                           ## unit, as in `ScreenLayout`
    uiScale*: int          ## WindowMetricsEvent: percent to enlarge the UI by,
                           ## as in `ScreenLayout`. A change here means the
                           ## window moved to a display of another density.
    button*: MouseButton   ## MouseDownEvent/MouseUpEvent: which button
    clicks*: int           ## number of consecutive clicks (double-click = 2)
    fromMouse*: bool       ## touch screens: the pointer is a mouse or a pen,
                           ## not a finger
    pen*: bool             ## the pointer is a pen (a stylus)
    pressure*: float32     ## pen: how hard it presses, 0..1
    tilt*: float32         ## pen: how far it leans from upright, radians
                           ## (0..pi/2)
    azimuth*: float32      ## pen: which way it leans, radians (0 = right,
                           ## clockwise)
    twist*: float32        ## pen: turn about its own axis, degrees (-1: the
                           ## eraser end is in use)
    scale*: float32        ## GestureEvent: finger distance over that of the
                           ## last event (1 = unchanged)
    dx*, dy*: float32      ## GestureEvent: how far their middle moved
    phase*: GesturePhase   ## GestureEvent: begun, changed or ended
    files*: seq[string]    ## FileDropEvent: the files' paths (UTF-8); empty,
                           ## and nothing allocated, for every other kind

  ClipboardRelays* = object
    getText*: proc (): string {.nimcall.}
    putText*: proc (text: string) {.nimcall.}

  InputRelays* = object
    pollEvent*: proc (e: var Event; flags: set[InputFlag]): bool {.nimcall.}
    waitEvent*: proc (e: var Event; timeoutMs: int;
                      flags: set[InputFlag]): bool {.nimcall.}
    getTicks*: proc (): int {.nimcall.}
    sleep*: proc (ms: int) {.nimcall.}
    shutdown*: proc () {.nimcall.}

var clipboardRelays* = ClipboardRelays(
  getText: proc (): string = "",
  putText: proc (text: string) = discard)

var inputRelays* = InputRelays(
  pollEvent: proc (e: var Event; flags: set[InputFlag]): bool = false,
  waitEvent: proc (e: var Event; timeoutMs: int;
                   flags: set[InputFlag]): bool = false,
  getTicks: proc (): int = 0,
  sleep: proc (ms: int) = discard,
  shutdown: proc () = discard)

proc pollEvent*(e: var Event; flags: set[InputFlag] = {}): bool =
  inputRelays.pollEvent(e, flags)
proc waitEvent*(e: var Event; timeoutMs: int = -1;
                flags: set[InputFlag] = {}): bool =
  inputRelays.waitEvent(e, timeoutMs, flags)
proc getClipboardText*(): string = clipboardRelays.getText()
proc putClipboardText*(text: string) = clipboardRelays.putText(text)
proc getTicks*(): int = inputRelays.getTicks()
proc sleep*(ms: int) = inputRelays.sleep(ms)
proc shutdown*() = inputRelays.shutdown()
