## Platform-independent input: the events a driver delivers (keys, typed
## text, the mouse, touches, pens, gestures, dropped files, window changes)
## and the relays that deliver them, the clipboard and the clock. A driver
## fills `inputRelays` and `clipboardRelays`; an app calls `pollEvent`,
## `waitEvent`, `getClipboardText`...
##
## ```nim
## var e: Event
## while pollEvent(e):
##   if e.kind == KeyDownEvent and e.key == KeyEsc: quit()
## ```

type
  KeyCode* = enum
    ## A key, the same on every keyboard layout (Ctrl+C is `KeyC` with
    ## `CtrlPressed`, whatever the layout types).
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
    ShiftPressed,
    CtrlPressed,    ## Ctrl -- on macOS and iOS Command, the key shortcuts are
                    ## made with there, so an app's Ctrl+C is Cmd+C there
    AltPressed,     ## Alt (Option on macOS; AltGr is not Alt and not Ctrl)
    GuiPressed      ## the Windows or Super key -- on macOS Control

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
    x*, y*: int            ## mouse position, scroll delta, or new window size.
                           ## MouseWheelEvent: whole notches, `y` > 0 away from
                           ## the user (up), `x` > 0 to the right (a tilted
                           ## wheel, a touchpad; Shift + the wheel stays `y`
                           ## where the system leaves it so). A move to
                           ## `OutsideWindow`, `OutsideWindow`: the pointer left
                           ## the window (no button down)
    scaleX*, scaleY*: int  ## WindowMetricsEvent: device pixels per coordinate
                           ## unit, as in `ScreenLayout`
    uiScale*: int          ## WindowMetricsEvent: percent to enlarge the UI by,
                           ## as in `ScreenLayout`. A change here means the
                           ## window moved to a display of another density.
    button*: MouseButton   ## MouseDownEvent/MouseUpEvent: which button
    clicks*: int           ## number of consecutive clicks of this button
                           ## (double-click = 2), as near in time and place as
                           ## the system's double click wants them
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
    preciseLines*: int     ## MouseWheelEvent: lines to scroll, from a driver
                           ## that tracks fine-grained (touchpad) scrolling;
                           ## 0 = derive from `y` notches (see `wheelLines`)

  ClipboardRelays* = object
    ## The system clipboard's text (UTF-8), filled by the driver.
    getText*: proc (): string {.nimcall.}       ## the text on the clipboard ("" none)
    putText*: proc (text: string) {.nimcall.}   ## puts `text` on the clipboard

  InputRelays* = object
    ## Where events and time come from, filled by the driver.
    pollEvent*: proc (e: var Event; flags: set[InputFlag]): bool {.nimcall.}
      ## the next waiting event, if there is one (false: none)
    waitEvent*: proc (e: var Event; timeoutMs: int;
                      flags: set[InputFlag]): bool {.nimcall.}
      ## the next event, waiting up to `timeoutMs` (-1: as long as it takes)
    getTicks*: proc (): int {.nimcall.}          ## milliseconds since some start (monotonic)
    sleep*: proc (ms: int) {.nimcall.}           ## waits `ms` milliseconds
    shutdown*: proc () {.nimcall.}               ## closes the window and the driver

const OutsideWindow* = -100_000
  ## Where a MouseMoveEvent puts the pointer that left the window, so that
  ## nothing in it is under the pointer any more (hover and tool tips end).

var clipboardRelays* = ClipboardRelays(
  ## The clipboard's relays (nothing until a driver fills them).
  getText: proc (): string = "",
  putText: proc (text: string) = discard)

var inputRelays* = InputRelays(
  ## The input relays (no events until a driver fills them).
  pollEvent: proc (e: var Event; flags: set[InputFlag]): bool = false,
  waitEvent: proc (e: var Event; timeoutMs: int;
                   flags: set[InputFlag]): bool = false,
  getTicks: proc (): int = 0,
  sleep: proc (ms: int) = discard,
  shutdown: proc () = discard)

proc pollEvent*(e: var Event; flags: set[InputFlag] = {}): bool =
  ## The next waiting event into `e`; false when there is none.
  ## `WantTextInput` in `flags` shows the soft keyboard / turns on the IME.
  inputRelays.pollEvent(e, flags)
proc waitEvent*(e: var Event; timeoutMs: int = -1;
                flags: set[InputFlag] = {}): bool =
  ## Waits for the next event (at most `timeoutMs`, -1 for ever); false when
  ## none came in time.
  inputRelays.waitEvent(e, timeoutMs, flags)
proc getClipboardText*(): string = clipboardRelays.getText()
  ## The text on the system clipboard ("" when there is none).
proc putClipboardText*(text: string) = clipboardRelays.putText(text)
  ## Puts `text` on the system clipboard.
proc getTicks*(): int = inputRelays.getTicks()
  ## Milliseconds from a fixed start; never goes back.
proc sleep*(ms: int) = inputRelays.sleep(ms)
  ## Waits `ms` milliseconds.
proc shutdown*() = inputRelays.shutdown()
  ## Closes the window and the driver.

proc wheelLines*(e: Event): int =
  ## How many lines a MouseWheelEvent scrolls (positive = up): the driver's
  ## precise count when it gives one, else 3 a wheel notch.
  if e.preciseLines != 0: e.preciseLines else: e.y * 3
