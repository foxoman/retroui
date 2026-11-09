## (included by mediasession) Windows 8 and later: the System Media
## Transport Controls of the app's window (the media flyout by the volume,
## the lock screen, the keyboard's media keys), reached through Windows'
## runtime: nothing linked. The buttons are pressed on a thread of
## Windows'; they wait in a small ring for the app's next frame.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import wincom
import uirelays/drivers/winapi_driver

const
  IidInterop = guid"ddb0472d-c911-4a1f-86d9-dc3d71a95f5a"   # ISystemMediaTransportControlsInterop
  IidSmtc = guid"99fa3ff4-1742-42a6-902e-087d41f965ec"      # ISystemMediaTransportControls
  # TypedEventHandler<SystemMediaTransportControls, ...ButtonPressedEventArgs>
  IidButtonHandler = guid"0557e996-7b23-5bae-aa81-ea0d671143a4"
  StatusStopped = 2'i32
  StatusPlaying = 3'i32
  StatusPaused = 4'i32

var
  smtc: Com
  smtcTried = false
  ring: array[64, int]           ## (pressed buttons + 1, written by Windows' threads)
  ringIn, ringOut: int

proc onButton(c: ptr Callback; sender, args: pointer): HRESULT {.nimcall, gcsafe.} =
  ## ButtonPressed, on a thread of Windows'.
  if args == nil: return 0
  var b: int32 = -1
  discard cast[Com](args).call(6, proc (this: Com; b: ptr int32): HRESULT {.stdcall, gcsafe.})(
    cast[Com](args), addr b)                                   # get_Button
  if b >= 0:
    {.cast(gcsafe).}:
      let at = atomicInc(ringIn) - 1
      ring[at and 63] = int(b) + 1
  0

proc smtcSet(slot: int; on: bool) =
  discard smtc.call(slot, proc (this: Com; v: int32): HRESULT {.stdcall, gcsafe.})(
    smtc, int32(ord(on)))

proc ready(): bool =
  if smtc != nil: return true
  if smtcTried: return false
  smtcTried = true
  let hwnd = winWindow()
  if hwnd == nil: return false
  var interop: Com
  if not winrtFactory("Windows.Media.SystemMediaTransportControls", IidInterop, interop):
    return false
  var iid = IidSmtc
  discard interop.call(6, proc (this: Com; w: pointer; iid: ptr Guid; r: ptr Com): HRESULT {.stdcall, gcsafe.})(
    interop, hwnd, addr iid, addr smtc)                         # GetForWindow
  interop.release()
  if smtc == nil: return false
  smtcSet(11, true)                                            # IsEnabled
  smtcSet(13, true)                                            # IsPlayEnabled
  smtcSet(17, true)                                            # IsPauseEnabled
  smtcSet(15, true)                                            # IsStopEnabled
  let h = newCallback(0, nil, onButton, [IidButtonHandler])
  var token: int64
  discard smtc.call(32, proc (this: Com; h: pointer; t: ptr int64): HRESULT {.stdcall, gcsafe.})(
    smtc, h, addr token)                                       # add_ButtonPressed
  release(cast[Com](h))
  true

proc putText(o: Com; slot: int; s: string) =
  let h = hstring(s)
  discard o.call(slot, proc (this: Com; v: pointer): HRESULT {.stdcall, gcsafe.})(o, h)
  freeHstring(h)

proc tell(old: NowPlaying; first: bool) =
  if not ready(): return
  smtcSet(27, current.canNext)                                 # IsNextEnabled
  smtcSet(25, current.canPrevious)                             # IsPreviousEnabled
  discard smtc.call(7, proc (this: Com; s: int32): HRESULT {.stdcall, gcsafe.})(
    smtc, if current.playing: StatusPlaying else: StatusPaused)  # put_PlaybackStatus
  var du: Com
  discard smtc.call(8, proc (this: Com; r: ptr Com): HRESULT {.stdcall, gcsafe.})(smtc, addr du)
  if du == nil: return
  discard du.call(7, proc (this: Com; t: int32): HRESULT {.stdcall, gcsafe.})(
    du, if current.video: 2 else: 1)                           # put_Type: video, music
  var props: Com
  if current.video:
    discard du.call(13, proc (this: Com; r: ptr Com): HRESULT {.stdcall, gcsafe.})(du, addr props)
    if props != nil:
      props.putText(7, current.title)                          # put_Title
      props.putText(9, current.artist)                         # put_Subtitle
  else:
    discard du.call(12, proc (this: Com; r: ptr Com): HRESULT {.stdcall, gcsafe.})(du, addr props)
    if props != nil:
      props.putText(7, current.title)                          # put_Title
      props.putText(9, current.album)                          # put_AlbumArtist
      props.putText(11, current.artist)                        # put_Artist
  props.release()
  discard du.call(17, proc (this: Com): HRESULT {.stdcall, gcsafe.})(du)   # Update
  du.release()

proc untell() =
  if smtc == nil: return
  discard smtc.call(7, proc (this: Com; s: int32): HRESULT {.stdcall, gcsafe.})(smtc, StatusStopped)

proc pump() =
  while ringOut < atomicLoadN(addr ringIn, ATOMIC_ACQUIRE):
    let b = ring[ringOut and 63] - 1
    inc ringOut
    case b
    of 0: press(mkPlay)
    of 1: press(mkPause)
    of 2: press(mkStop)
    of 6: press(mkNext)
    of 7: press(mkPrevious)
    else: discard
