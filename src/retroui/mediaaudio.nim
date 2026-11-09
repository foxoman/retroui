## Sound for `retroui/media`: WAV files decoded here (PCM 8/16/24/32-bit and
## float, any channels and rate), tones made here, mixed on a worker
## thread and sent to the system's own audio output, loaded when the first
## sound plays: PulseAudio or ALSA on Linux (Termux with PulseAudio too),
## waveOut on Windows, AudioQueue on macOS and iOS. Nothing to install;
## without a sound device everything goes on quietly. Apps use it through
## `retroui/media` (`playSound`); use it directly to make or change sounds:
##
## ```nim
## let beep = makeTone(880, 200)                  # 880 Hz for 200 ms
## let two = joinSounds([beep, makeTone(660, 200)])
## writeFile("beep.wav", encodeWav(two))
## echo decodeWav(readFile("beep.wav")).duration  # seconds
## ```

import std/[locks, math, hashes]
import uirelays/target   # (androidApp: an APK, not a program in Termux)
when not (androidApp or defined(windows)):
  import std/dynlib
when compileOption("threads"):
  import std/typedthreads

type
  Pcm = object
    ## Samples shared by the UI thread and the mixer (counted by hand).
    refs: int
    rate, channels, frames: int
    data: ptr UncheckedArray[int16]
  PcmHandle = object
    p: ptr Pcm
  SoundObj = object
    h: PcmHandle
    cacheFile*: string           ## (written once where the platform plays files)
  Sound* = ref SoundObj
    ## Decoded sound: its samples, ready to play any number of times.
  Waveform* = enum
    ## The shape of a `makeTone`.
    wSine, wSquare, wTriangle, wSaw

const
  MaxWavBytes* = 256 shl 20      ## bigger WAV files are refused
  MaxSoundFrames* = 48000 * 60 * 30  ## 30 minutes at 48 kHz
  OutRate* = 44100               ## what the mixer sends to the device
  OutChannels = 2

proc release(p: ptr Pcm) =
  if p != nil and atomicDec(p.refs) == 0:
    if p.data != nil: deallocShared(p.data)
    deallocShared(p)

when defined(gcDestructors):
  proc `=destroy`(h: PcmHandle) = release(h.p)
else:      # (--mm:refc, an editor's check among them: its hooks take `var`)
  proc `=destroy`(h: var PcmHandle) = release(h.p)
proc `=copy`(a: var PcmHandle; b: PcmHandle) {.error.}

template pcm(s: Sound): ptr Pcm = s.h.p

proc newPcm(rate, channels, frames: int): ptr Pcm =
  result = cast[ptr Pcm](allocShared0(sizeof(Pcm)))
  result.refs = 1
  result.rate = rate
  result.channels = channels
  result.frames = frames
  if frames * channels > 0:
    result.data = cast[ptr UncheckedArray[int16]](allocShared0(frames * channels * 2))

proc newSound(rate, channels, frames: int): Sound =
  Sound(h: PcmHandle(p: newPcm(rate, channels, frames)))

proc rate*(s: Sound): int = (if s == nil or s.pcm == nil: 0 else: s.pcm.rate)
  ## Samples a second, per channel.
proc channels*(s: Sound): int = (if s == nil or s.pcm == nil: 0 else: s.pcm.channels)
  ## 1 (mono) or 2 (stereo; files with more are mixed down to two).
proc frames*(s: Sound): int = (if s == nil or s.pcm == nil: 0 else: s.pcm.frames)
  ## How many samples each channel has.
proc duration*(s: Sound): float =
  ## How long it plays, in seconds.
  if s.rate == 0: 0.0 else: s.frames / s.rate

proc sample*(s: Sound; frame, channel: int): int =
  ## One 16-bit sample (for tests and for drawing a wave); 0 out of range.
  if s == nil or s.pcm == nil or frame < 0 or frame >= s.frames or
     channel < 0 or channel >= s.channels: return 0
  int(s.pcm.data[frame * s.channels + channel])

proc pcmHash*(s: Sound): Hash =
  ## A hash of the samples (to name a copy of the sound on disk).
  var h: Hash = hash(s.rate) !& hash(s.channels)
  if s.pcm != nil and s.pcm.data != nil:
    let n = s.frames * s.channels
    var i = 0
    while i < n:
      h = h !& int(s.pcm.data[i])
      i += max(1, n div 4096)
  !$h

# ---- WAV files --------------------------------------------------------------------------------------

proc le16(d: string; i: int): int = int(d[i].uint8) or (int(d[i + 1].uint8) shl 8)
proc le32u(d: string; i: int): uint32 =
  uint32(d[i].uint8) or (uint32(d[i + 1].uint8) shl 8) or
    (uint32(d[i + 2].uint8) shl 16) or (uint32(d[i + 3].uint8) shl 24)
proc le32(d: string; i: int): int =
  ## (a size: one past what an `int` holds is as good as the most it holds)
  let v = le32u(d, i)
  when sizeof(int) == 8: int(v)
  else: (if v > 0x7FFFFFFF'u32: high(int) else: int(v))

proc decodeWav*(data: string): Sound =
  ## The sound in the WAV file `data`: PCM of 8, 16, 24 or 32 bits, or
  ## float of 32 or 64 bits, any number of channels (more than two are
  ## mixed down to stereo), any rate. Raises `ValueError` when it is not a
  ## WAV file it can read (or bigger than `MaxWavBytes`).
  if data.len > MaxWavBytes: raise newException(ValueError, "WAV: too big")
  if data.len < 12 or data[0 .. 3] != "RIFF" or data[8 .. 11] != "WAVE":
    raise newException(ValueError, "not a WAV file")
  var fmtTag, chans, rate, bits, blockAlign = 0
  var haveFmt = false
  var dataAt, dataLen = -1
  var i = 12
  while i + 8 <= data.len:
    let id = data[i ..< i + 4]
    let n = le32(data, i + 4)
    if n < 0: break
    let body = i + 8
    if id == "fmt ":
      if n < 16 or body + 16 > data.len: raise newException(ValueError, "WAV: bad format")
      fmtTag = le16(data, body)
      chans = le16(data, body + 2)
      rate = le32(data, body + 4)
      blockAlign = le16(data, body + 12)
      bits = le16(data, body + 14)
      if fmtTag == 0xFFFE and n >= 26 and body + 26 <= data.len:
        fmtTag = le16(data, body + 24)       # the format of WAVE_FORMAT_EXTENSIBLE
      haveFmt = true
    elif id == "data":
      dataAt = body
      dataLen = min(n, data.len - body)      # (files cut short: what is there)
      if haveFmt: break
    if n > data.len: break
    i = body + n + (n and 1)
  if not haveFmt or dataAt < 0: raise newException(ValueError, "WAV: no format or no data")
  if chans < 1 or chans > 32 or rate < 1000 or rate > 768000:
    raise newException(ValueError, "WAV: unsupported channels or rate")
  let bytesPer = bits div 8
  let ok = (fmtTag == 1 and bits in [8, 16, 24, 32]) or (fmtTag == 3 and bits in [32, 64])
  if not ok: raise newException(ValueError, "WAV: unsupported sample format")
  if blockAlign != 0 and blockAlign < bytesPer * chans:
    raise newException(ValueError, "WAV: bad block size")
  let stride = max(blockAlign, bytesPer * chans)
  let frames = min(dataLen div stride, MaxSoundFrames)
  let outCh = min(chans, 2)
  result = newSound(rate, outCh, frames)
  let dst = result.pcm.data
  template sampleAt(p: int): int =
    ## A sample as 16 bits (whole-number formats exactly, floats rounded).
    case bits
    of 8: (int(data[p].uint8) - 128) shl 8
    of 16: int(cast[int16](uint16(le16(data, p))))
    of 24: int(cast[int16]((uint16(data[p + 1].uint8)) or (uint16(data[p + 2].uint8) shl 8)))
    of 32:
      if fmtTag == 3:
        let f = float(cast[float32](le32u(data, p)))
        if f != f: 0 else: int(clamp(f * 32767, -32768, 32767))
      else: int(cast[int32](le32u(data, p)) shr 16)
    else:
      var u = 0'u64
      for k in 0 .. 7: u = u or (uint64(data[p + k].uint8) shl (8 * k))
      let f = cast[float64](u)
      if f != f: 0 else: int(clamp(f * 32767, -32768, 32767))
  for f in 0 ..< frames:
    let base = dataAt + f * stride
    if chans <= 2:
      for c in 0 ..< chans:
        dst[f * outCh + c] = int16(sampleAt(base + c * bytesPer))
    else:
      # more channels: even ones left, odd ones right, averaged
      var l, r = 0
      var nl, nr = 0
      for c in 0 ..< chans:
        let v = sampleAt(base + c * bytesPer)
        if c mod 2 == 0:
          l += v
          inc nl
        else:
          r += v
          inc nr
      dst[f * 2] = int16(l div max(1, nl))
      dst[f * 2 + 1] = int16(r div max(1, nr))

proc encodeWav*(s: Sound): string =
  ## `s` as the bytes of a 16-bit PCM WAV file.
  let n = s.frames * s.channels * 2
  result = newStringOfCap(44 + n)
  proc put32(r: var string; v: int) =
    for k in 0 .. 3: r.add char((v shr (8 * k)) and 255)
  proc put16(r: var string; v: int) =
    for k in 0 .. 1: r.add char((v shr (8 * k)) and 255)
  result.add "RIFF"
  result.put32(36 + n)
  result.add "WAVEfmt "
  result.put32(16)
  result.put16(1)
  result.put16(s.channels)
  result.put32(s.rate)
  result.put32(s.rate * s.channels * 2)
  result.put16(s.channels * 2)
  result.put16(16)
  result.add "data"
  result.put32(n)
  if n > 0:
    let start = result.len
    result.setLen(start + n)
    copyMem(addr result[start], s.pcm.data, n)

# ---- tones --------------------------------------------------------------------------------------------

proc makeTone*(hz: float; ms: int; volume = 0.5; wave = wSine;
               fadeMs = 8): Sound =
  ## A tone of `hz` hertz, `ms` milliseconds long (mono, 44.1 kHz), its
  ## start and end faded over `fadeMs` so it does not click.
  let frames = clamp(ms, 0, 60_000) * 44100 div 1000
  result = newSound(44100, 1, frames)
  let fade = max(1, fadeMs * 44100 div 1000)
  let v = clamp(volume, 0.0, 1.0)
  let f = if hz > 0 and hz < 22050: hz else: 0.0
  for i in 0 ..< frames:
    let t = f * float(i) / 44100
    let ph = t - floor(t)
    var x = case wave
            of wSine: sin(2 * PI * t)
            of wSquare: (if ph < 0.5: 0.8 else: -0.8)
            of wTriangle: 4 * abs(ph - 0.5) - 1
            of wSaw: 2 * ph - 1
    let env = min(1.0, min(float(i) / float(fade), float(frames - 1 - i) / float(fade)))
    x = x * v * max(0.0, env)
    result.pcm.data[i] = int16(clamp(x * 32767, -32768, 32767))

proc joinSounds*(parts: openArray[Sound]): Sound =
  ## The sounds one after another (same rate and channels as the first;
  ## others are skipped).
  if parts.len == 0: return newSound(44100, 1, 0)
  let r = parts[0].rate
  let c = parts[0].channels
  var total = 0
  for p in parts:
    if p.rate == r and p.channels == c: total += p.frames
  result = newSound(r, c, total)
  var at = 0
  for p in parts:
    if p.rate == r and p.channels == c and p.frames > 0:
      copyMem(addr result.pcm.data[at * c], p.pcm.data, p.frames * c * 2)
      at += p.frames

# ---- the mixer --------------------------------------------------------------------------------------

type Voice = object
  id: int
  pcm: ptr Pcm
  pos, step: float64
  vol: float32
  loop: bool

var
  mixLock: Lock
  mixCond: Cond
  voices: seq[Voice]           # guarded by mixLock
  nextVoice = 1
  masterVol = 1.0'f32
  mixerStarted = false
  deviceName = ""              # what opened ("" none yet, "none" none there)

initLock(mixLock)
initCond(mixCond)

proc mixInto(dst: ptr UncheckedArray[int16]; n: int) {.gcsafe.} =
  ## Mixes `n` samples (n / 2 stereo frames) into `dst`, in pieces, without
  ## allocating (an audio thread of the system may call it).
  const Chunk = 512
  var acc: array[Chunk * OutChannels, float32]
  var done = 0
  while done < n:
    let frames = min(Chunk, (n - done) div OutChannels)
    if frames <= 0: break
    for i in 0 ..< frames * OutChannels: acc[i] = 0
    {.cast(gcsafe).}:
      withLock mixLock:
        var k = 0
        while k < voices.len:
          let v = addr voices[k]
          let p = v.pcm
          var ended = p == nil or p.frames == 0
          if not ended:
            let ch = p.channels
            let g = v.vol * masterVol / 32768'f32
            for f in 0 ..< frames:
              var i = int(v.pos)
              if i >= p.frames:
                if v.loop:
                  v.pos -= float64(p.frames) * floor(v.pos / float64(p.frames))
                  i = int(v.pos)
                else:
                  ended = true
                  break
              let t = float32(v.pos - float64(i))
              let j = if i + 1 < p.frames: i + 1 elif v.loop: 0 else: i
              if ch == 1:
                let a = (float32(p.data[i]) * (1 - t) + float32(p.data[j]) * t) * g
                acc[f * 2] += a
                acc[f * 2 + 1] += a
              else:
                acc[f * 2] += (float32(p.data[i * 2]) * (1 - t) + float32(p.data[j * 2]) * t) * g
                acc[f * 2 + 1] += (float32(p.data[i * 2 + 1]) * (1 - t) +
                                   float32(p.data[j * 2 + 1]) * t) * g
              v.pos += v.step
          if ended:
            release(voices[k].pcm)
            voices.delete(k)
          else: inc k
    for i in 0 ..< frames * OutChannels:
      var x = acc[i]
      # softly above full scale, instead of clipping hard
      if x > 0.75'f32: x = 0.75'f32 + 0.25'f32 * tanh((x - 0.75'f32) * 4)
      elif x < -0.75'f32: x = -0.75'f32 - 0.25'f32 * tanh((-x - 0.75'f32) * 4)
      dst[done + i] = int16(clamp(x * 32767, -32768, 32767))
    done += frames * OutChannels
  for i in done ..< n: dst[i] = 0

proc mixTo*(buf: var openArray[int16]) {.gcsafe.} =
  ## Mixes the next samples of every sound playing into `buf` (stereo,
  ## interleaved, `OutRate` hertz) and moves them on; sounds that ended
  ## are dropped. The audio thread calls it; an app with its own audio
  ## output can call it instead.
  if buf.len > 0: mixInto(cast[ptr UncheckedArray[int16]](addr buf[0]), buf.len)

proc playingCount(): int =
  {.cast(gcsafe).}:
    withLock mixLock: result = voices.len

# ---- the system's audio output -------------------------------------------------------------------

type AudioOut = object
  name: string
  handle: pointer
  write: proc (o: var AudioOut; buf: var seq[int16]): bool {.nimcall, gcsafe.}
  close: proc (o: var AudioOut) {.nimcall, gcsafe.}

when defined(linux) and not androidApp:
  type
    PaSampleSpec = object
      format: cint
      rate: uint32
      channels: uint8
    PaNew = proc (server, name: cstring; dir: cint; dev, stream: cstring;
                  ss: ptr PaSampleSpec; map, attr: pointer; err: ptr cint): pointer {.cdecl, gcsafe.}
    PaWrite = proc (s: pointer; data: pointer; bytes: csize_t; err: ptr cint): cint {.cdecl, gcsafe.}
    PaFree = proc (s: pointer) {.cdecl, gcsafe.}
    SndOpen = proc (pcm: ptr pointer; name: cstring; stream, mode: cint): cint {.cdecl, gcsafe.}
    SndSet = proc (pcm: pointer; format, access: cint; channels, rate: cuint;
                   soft: cint; latency: cuint): cint {.cdecl, gcsafe.}
    SndWrite = proc (pcm: pointer; buf: pointer; frames: culong): clong {.cdecl, gcsafe.}
    SndRecover = proc (pcm: pointer; err, silent: cint): cint {.cdecl, gcsafe.}
    SndClose = proc (pcm: pointer): cint {.cdecl, gcsafe.}
    SndErr = proc (file: cstring; line: cint; fn: cstring; err: cint; fmt: cstring) {.cdecl.}
    SndSetErr = proc (h: SndErr): cint {.cdecl, gcsafe.}
  var
    paWrite: PaWrite
    paFree, paDrain: PaFree
    sndWrite: SndWrite
    sndRecover: SndRecover
    sndClose, sndDrain: SndClose

  proc openPulse(o: var AudioOut): bool =
    let lib = loadLib("libpulse-simple.so.0")
    if lib == nil: return false
    let pnew = cast[PaNew](lib.symAddr("pa_simple_new"))
    paWrite = cast[PaWrite](lib.symAddr("pa_simple_write"))
    paFree = cast[PaFree](lib.symAddr("pa_simple_free"))
    paDrain = cast[PaFree](lib.symAddr("pa_simple_drain"))
    if pnew == nil or paWrite == nil or paFree == nil: return false
    var ss = PaSampleSpec(format: 3, rate: OutRate.uint32, channels: OutChannels.uint8)  # S16LE
    var err: cint
    let s = pnew(nil, "retro", 1, nil, "sound", addr ss, nil, nil, addr err)
    if s == nil: return false
    o = AudioOut(name: "pulse", handle: s,
      write: proc (o: var AudioOut; buf: var seq[int16]): bool {.nimcall, gcsafe.} =
        var e: cint
        {.cast(gcsafe).}:
          paWrite(o.handle, addr buf[0], csize_t(buf.len * 2), addr e) >= 0,
      close: proc (o: var AudioOut) {.nimcall, gcsafe.} =
        {.cast(gcsafe).}:
          if paDrain != nil: paDrain(o.handle)
          paFree(o.handle))
    true

  proc openAlsa(o: var AudioOut): bool =
    let lib = loadLib("libasound.so.2")
    if lib == nil: return false
    let sopen = cast[SndOpen](lib.symAddr("snd_pcm_open"))
    let sset = cast[SndSet](lib.symAddr("snd_pcm_set_params"))
    sndWrite = cast[SndWrite](lib.symAddr("snd_pcm_writei"))
    sndRecover = cast[SndRecover](lib.symAddr("snd_pcm_recover"))
    sndClose = cast[SndClose](lib.symAddr("snd_pcm_close"))
    sndDrain = cast[SndClose](lib.symAddr("snd_pcm_drain"))
    if sopen == nil or sset == nil or sndWrite == nil or sndClose == nil: return false
    # (ALSA prints its errors itself: not here, where no device is normal)
    let seterr = cast[SndSetErr](lib.symAddr("snd_lib_error_set_handler"))
    if seterr != nil:
      discard seterr(proc (file: cstring; line: cint; fn: cstring; err: cint;
                           fmt: cstring) {.cdecl.} = discard)
    var pcm: pointer
    if sopen(addr pcm, "default", 0, 0) < 0 or pcm == nil: return false
    # S16_LE, interleaved, 0.1 s of latency
    if sset(pcm, 2, 3, OutChannels.cuint, OutRate.cuint, 1, 100_000) < 0:
      discard sndClose(pcm)
      return false
    o = AudioOut(name: "alsa", handle: pcm,
      write: proc (o: var AudioOut; buf: var seq[int16]): bool {.nimcall, gcsafe.} =
        {.cast(gcsafe).}:
          var n = sndWrite(o.handle, addr buf[0], culong(buf.len div OutChannels))
          if n < 0 and sndRecover != nil:
            if sndRecover(o.handle, cint(n), 1) >= 0:
              n = sndWrite(o.handle, addr buf[0], culong(buf.len div OutChannels))
          n >= 0,
      close: proc (o: var AudioOut) {.nimcall, gcsafe.} =
        {.cast(gcsafe).}:
          if sndDrain != nil: discard sndDrain(o.handle)
          discard sndClose(o.handle))
    true

  proc openOutput(o: var AudioOut): bool =
    openPulse(o) or openAlsa(o)

elif defined(windows):
  type
    WaveFormatEx {.pure.} = object
      wFormatTag, nChannels: uint16
      nSamplesPerSec, nAvgBytesPerSec: uint32
      nBlockAlign, wBitsPerSample, cbSize: uint16
    WaveHdr = object
      lpData: pointer
      dwBufferLength, dwBytesRecorded: uint32
      dwUser: uint
      dwFlags, dwLoops: uint32
      lpNext: pointer
      reserved: uint
  proc waveOutOpen(h: ptr pointer; dev: uint32; fmt: ptr WaveFormatEx; cb, inst: uint;
                   flags: uint32): uint32 {.stdcall, dynlib: "winmm", importc.}
  proc waveOutPrepareHeader(h: pointer; hdr: ptr WaveHdr; size: uint32): uint32 {.stdcall, dynlib: "winmm", importc.}
  proc waveOutUnprepareHeader(h: pointer; hdr: ptr WaveHdr; size: uint32): uint32 {.stdcall, dynlib: "winmm", importc.}
  proc waveOutWrite(h: pointer; hdr: ptr WaveHdr; size: uint32): uint32 {.stdcall, dynlib: "winmm", importc.}
  proc waveOutReset(h: pointer): uint32 {.stdcall, dynlib: "winmm", importc.}
  proc waveOutClose(h: pointer): uint32 {.stdcall, dynlib: "winmm", importc.}
  proc sleepMs(ms: uint32) {.stdcall, dynlib: "kernel32", importc: "Sleep".}
  const NBuf = 4
  type WaveRing = object
    hdrs: array[NBuf, WaveHdr]
    bufs: array[NBuf, seq[int16]]
    at: int
  var ring: ptr WaveRing

  proc openOutput(o: var AudioOut): bool =
    var fmt = WaveFormatEx(wFormatTag: 1, nChannels: OutChannels.uint16,
                           nSamplesPerSec: OutRate.uint32,
                           nAvgBytesPerSec: uint32(OutRate * OutChannels * 2),
                           nBlockAlign: uint16(OutChannels * 2), wBitsPerSample: 16)
    var h: pointer
    if waveOutOpen(addr h, 0xFFFFFFFF'u32, addr fmt, 0, 0, 0) != 0 or h == nil: return false
    ring = cast[ptr WaveRing](allocShared0(sizeof(WaveRing)))
    o = AudioOut(name: "waveout", handle: h,
      write: proc (o: var AudioOut; buf: var seq[int16]): bool {.nimcall, gcsafe.} =
        {.cast(gcsafe).}:
          let r = ring
          let hd = addr r.hdrs[r.at]
          # wait for this buffer to come back from the device
          if hd.dwFlags != 0:
            var waited = 0
            while (hd.dwFlags and 1) == 0 and waited < 2000:
              sleepMs(2)
              waited += 2
            discard waveOutUnprepareHeader(o.handle, hd, uint32(sizeof(WaveHdr)))
          r.bufs[r.at] = buf
          hd[] = WaveHdr(lpData: addr r.bufs[r.at][0], dwBufferLength: uint32(buf.len * 2))
          if waveOutPrepareHeader(o.handle, hd, uint32(sizeof(WaveHdr))) != 0: return false
          if waveOutWrite(o.handle, hd, uint32(sizeof(WaveHdr))) != 0: return false
          r.at = (r.at + 1) mod NBuf
          true,
      close: proc (o: var AudioOut) {.nimcall, gcsafe.} =
        {.cast(gcsafe).}:
          sleepMs(150)
          discard waveOutReset(o.handle)
          for k in 0 ..< NBuf:
            if ring.hdrs[k].dwFlags != 0:
              discard waveOutUnprepareHeader(o.handle, addr ring.hdrs[k], uint32(sizeof(WaveHdr)))
          discard waveOutClose(o.handle)
          for k in 0 ..< NBuf: ring.bufs[k] = @[]
          deallocShared(ring)
          ring = nil)
    true

elif defined(macosx) or defined(ios):
  # AudioQueue (AudioToolbox, loaded at run time): its own thread asks for
  # the next buffer and the mixer fills it.
  type
    AsbD = object
      mSampleRate: float64
      mFormatID, mFormatFlags, mBytesPerPacket, mFramesPerPacket,
        mBytesPerFrame, mChannelsPerFrame, mBitsPerChannel, mReserved: uint32
    AqBuffer = object
      mAudioDataBytesCapacity: uint32
      mAudioData: pointer
      mAudioDataByteSize: uint32
      mUserData: pointer
      mPacketDescriptionCapacity: uint32
      mPacketDescriptions: pointer
      mPacketDescriptionCount: uint32
    AqCallback = proc (user, queue: pointer; buf: ptr AqBuffer) {.cdecl, gcsafe.}
    AqNew = proc (fmt: ptr AsbD; cb: AqCallback; user: pointer; loop, mode: pointer;
                  flags: uint32; queue: ptr pointer): int32 {.cdecl, gcsafe.}
    AqAlloc = proc (q: pointer; bytes: uint32; buf: ptr ptr AqBuffer): int32 {.cdecl, gcsafe.}
    AqEnqueue = proc (q: pointer; buf: ptr AqBuffer; n: uint32; d: pointer): int32 {.cdecl, gcsafe.}
    AqStart = proc (q: pointer; t: pointer): int32 {.cdecl, gcsafe.}
  var aqEnqueue: AqEnqueue

  proc fill(user, queue: pointer; buf: ptr AqBuffer) {.cdecl, gcsafe.} =
    let n = int(buf.mAudioDataBytesCapacity) div 2
    mixInto(cast[ptr UncheckedArray[int16]](buf.mAudioData), n)
    buf.mAudioDataByteSize = uint32(n * 2)
    {.cast(gcsafe).}: discard aqEnqueue(queue, buf, 0, nil)

  proc openOutput(o: var AudioOut): bool =
    let lib = loadLib("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")
    if lib == nil: return false
    let aqNew = cast[AqNew](lib.symAddr("AudioQueueNewOutput"))
    let aqAlloc = cast[AqAlloc](lib.symAddr("AudioQueueAllocateBuffer"))
    aqEnqueue = cast[AqEnqueue](lib.symAddr("AudioQueueEnqueueBuffer"))
    let aqStart = cast[AqStart](lib.symAddr("AudioQueueStart"))
    if aqNew == nil or aqAlloc == nil or aqEnqueue == nil or aqStart == nil: return false
    var fmt = AsbD(mSampleRate: OutRate.float64, mFormatID: 0x6c70636d'u32,  # 'lpcm'
                   mFormatFlags: 4 or 8, mBytesPerPacket: OutChannels * 2,
                   mFramesPerPacket: 1, mBytesPerFrame: OutChannels * 2,
                   mChannelsPerFrame: OutChannels, mBitsPerChannel: 16)
    var q: pointer
    if aqNew(addr fmt, fill, nil, nil, nil, 0, addr q) != 0 or q == nil: return false
    for k in 0 .. 2:
      var b: ptr AqBuffer
      if aqAlloc(q, 4096 * 2, addr b) != 0 or b == nil: return false
      fill(nil, q, b)
    if aqStart(q, nil) != 0: return false
    # the queue pulls by itself: the mixer thread only keeps it alive
    o = AudioOut(name: "audioqueue", handle: q,
      write: proc (o: var AudioOut; buf: var seq[int16]): bool {.nimcall, gcsafe.} = false,
      close: proc (o: var AudioOut) {.nimcall, gcsafe.} = discard)
    true

else:
  proc openOutput(o: var AudioOut): bool = false

when defined(wasm):
  # (a browser page: its Web Audio asks for the samples, `retro_audio`)
  proc rwAudioStart(rate, channels: cint) {.importc: "rw_audio_start", cdecl.}

  proc webAudioFill(dst: ptr UncheckedArray[int16]; n: cint) {.exportc: "retro_audio", cdecl.} =
    ## (the page's: `n` samples, stereo, to play next)
    mixInto(dst, n)

proc mixerLoop() {.thread.} =
  ## Waits for sounds; while there are some, mixes and writes them to the
  ## device (opened then, closed after a second and a half of silence).
  var o: AudioOut
  var buf = newSeq[int16](1024 * OutChannels)
  while true:
    {.cast(gcsafe).}:
      acquire(mixLock)
      while voices.len == 0: wait(mixCond, mixLock)
      release(mixLock)
    var opened = false
    {.cast(gcsafe).}:
      opened = openOutput(o)
      deviceName = if opened: o.name else: "none"
    if not opened:
      # no sound device: what was asked is dropped, quietly
      {.cast(gcsafe).}:
        withLock mixLock:
          for v in voices: release(v.pcm)
          voices.setLen(0)
      continue
    if o.name == "audioqueue":
      return                     # (it pulls the sound by itself from now on)
    var quiet = 0
    while quiet < OutRate * 3 div 2:
      mixTo(buf)
      if not o.write(o, buf): break
      if playingCount() == 0: quiet += buf.len div OutChannels else: quiet = 0
    o.close(o)

when compileOption("threads"):
  var mixer: Thread[void]

proc startMixer() =
  if not mixerStarted:
    mixerStarted = true
    when defined(wasm):
      rwAudioStart(OutRate, OutChannels)
      deviceName = "webaudio"
    elif compileOption("threads"):
      createThread(mixer, mixerLoop)
    else:
      deviceName = "none"

proc mixSound*(s: Sound; volume = 1.0; loop = false; start = true): int {.gcsafe.} =
  ## Puts `s` in the mixer; its voice number (0 when `s` is empty). With
  ## `start` false the output is not opened (tests, apps that call `mixTo`).
  if s == nil or s.pcm == nil or s.frames == 0: return 0
  discard atomicInc(s.pcm.refs)
  {.cast(gcsafe).}:
    withLock mixLock:
      result = nextVoice
      inc nextVoice
      voices.add Voice(id: result, pcm: s.pcm, pos: 0, step: s.rate / OutRate,
                       vol: float32(clamp(volume, 0.0, 4.0)), loop: loop)
    if start:
      startMixer()
      signal(mixCond)

proc unmix*(id: int) =
  ## Stops the voice `id`.
  withLock mixLock:
    for k in countdown(voices.high, 0):
      if voices[k].id == id:
        release(voices[k].pcm)
        voices.delete(k)

proc unmixAll*() =
  ## Stops every voice.
  withLock mixLock:
    for v in voices: release(v.pcm)
    voices.setLen(0)

proc mixing*(id: int): bool =
  ## The voice `id` is still playing.
  withLock mixLock:
    for v in voices:
      if v.id == id: return true

proc setMixVolume*(id: int; volume: float) =
  ## The volume of the voice `id` (0..4; 1 is as recorded).
  withLock mixLock:
    for v in voices.mitems:
      if v.id == id: v.vol = float32(clamp(volume, 0.0, 4.0))

proc setMasterVolume*(volume: float) =
  ## The volume of every sound together (0..1; 1 is as recorded).
  withLock mixLock: masterVol = float32(clamp(volume, 0.0, 1.0))

proc audioOutputName*(): string =
  ## Which output played the last sound: "pulse", "alsa", "waveout",
  ## "audioqueue", "none" (no sound device), "" (nothing played yet).
  {.cast(gcsafe).}: deviceName
