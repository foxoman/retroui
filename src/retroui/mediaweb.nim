## (included by mediaplayer) In a browser page (`-d:wasm`): the page's own
## <video> plays the file or the address (`retro.js`: `rw_video_*`), and
## each new picture is copied into the player's `frame`, which the kit
## draws like any other -- so menus and dialogs go over a video as they do
## everywhere. A file of the app's own (in /app, /data...) is played from
## the page's memory (a blob); an address directly.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

proc rwVideoOpen(src: cstring; video: cint): cint {.importc: "rw_video_open", cdecl.}
proc rwVideoClose(id: cint) {.importc: "rw_video_close", cdecl.}
proc rwVideoPlay(id: cint; on: cint) {.importc: "rw_video_play", cdecl.}
proc rwVideoState(id: cint; out6: ptr array[6, int32]) {.importc: "rw_video_state", cdecl.}
proc rwVideoSeek(id: cint; ms: cint) {.importc: "rw_video_seek", cdecl.}
proc rwVideoVolume(id: cint; v: cdouble) {.importc: "rw_video_volume", cdecl.}
proc rwVideoRate(id: cint; v: cdouble) {.importc: "rw_video_rate", cdecl.}
proc rwVideoFrame(id: cint; px: pointer; w, h: cint): cint {.importc: "rw_video_frame", cdecl.}

type
  MediaPlayer* = ref object
    ## A file or an address playing in the page's <video>.
    id: cint
    frame*: Bitmap           ## the latest picture of a video (nil: none yet)
    ended*: bool             ## it played to the end
    failed*: bool            ## the browser could not play it
    video: bool
    state: array[6, int32]   ## (playing, ended, failed, position ms, duration ms, new frame)

proc playerAvailable*(): bool = true
  ## The system's player is there (a browser's).

proc openPlayer*(path: string; video: bool; audioSink = ""): MediaPlayer =
  ## `path` (a file or a web address) ready to play, paused at its start.
  let id = rwVideoOpen(cstring(path), cint(video and audioSink != "fakesink" or video))
  if id <= 0: return nil
  MediaPlayer(id: id, video: video)

proc refresh(p: MediaPlayer) =
  rwVideoState(p.id, addr p.state)
  p.ended = p.state[1] != 0
  p.failed = p.state[2] != 0

proc close*(p: MediaPlayer) =
  if p != nil and p.id > 0:
    rwVideoClose(p.id)
    p.id = 0

proc play*(p: MediaPlayer) =
  if p != nil and p.id > 0:
    p.ended = false
    rwVideoPlay(p.id, 1)

proc pause*(p: MediaPlayer) =
  if p != nil and p.id > 0: rwVideoPlay(p.id, 0)

proc playing*(p: MediaPlayer): bool =
  if p == nil or p.id <= 0: return false
  p.refresh()
  p.state[0] != 0

proc positionMs*(p: MediaPlayer): int =
  if p == nil or p.id <= 0: return 0
  p.refresh()
  p.state[3]

proc durationMs*(p: MediaPlayer): int =
  if p == nil or p.id <= 0: return 0
  p.refresh()
  p.state[4]

proc seekMs*(p: MediaPlayer; ms: int) =
  if p != nil and p.id > 0: rwVideoSeek(p.id, cint(ms))

proc setVolume*(p: MediaPlayer; v: float) =
  if p != nil and p.id > 0: rwVideoVolume(p.id, cdouble(v))

proc setRate*(p: MediaPlayer; rate: float) =
  ## The speed it plays at (0.5 .. 3; 1 as recorded); a voice keeps its pitch.
  if p != nil and p.id > 0: rwVideoRate(p.id, cdouble(clamp(rate, 0.25, 4.0)))

proc showFirstPicture*(p: MediaPlayer) = discard
  ## (the browser shows the first picture once it has it)

proc poll*(p: MediaPlayer): bool =
  ## A new picture came (in `frame`); `ended` and `failed` brought up to date.
  if p == nil or p.id <= 0: return false
  p.refresh()
  if not p.video or p.state[5] == 0: return false
  # (the page's picture size, at most 1280 pixels wide)
  let w = rwVideoFrame(p.id, nil, 0, 0)
  if w <= 0: return false
  let h = rwVideoFrame(p.id, nil, -1, 0)
  if h <= 0: return false
  if p.frame == nil or p.frame.w != w or p.frame.h != h: p.frame = newBitmap(w, h)
  if rwVideoFrame(p.id, addr p.frame.px[0], cint(w), cint(h)) <= 0: return false
  p.frame.opaque = true
  p.frame.changed()
  true
