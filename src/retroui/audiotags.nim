## What a music file says about itself: its title, artist, album, track and disc, year, genre,
## its cover, its length and sound, how loud to play it (ReplayGain) -- read from the file
## alone, in Nim, nothing to install: MP3 (ID3v2.2, 2.3, 2.4 and ID3v1; its length from the
## Xing, Info or VBRI header, else its bit rate), FLAC (Vorbis comments, its picture, STREAMINFO),
## M4A / MP4 / AAC / ALAC (iTunes' items, the cover, mvhd), Ogg Vorbis and Opus (comments, a
## picture in METADATA_BLOCK_PICTURE, the last page's position) and WAV (RIFF INFO). Only the
## start and the end of a file are read (an M4A's `moov` wherever it is): a library of
## thousands is read in seconds.
##
## .. code-block:: nim
##   let t = readAudioTags("Music/01 Intro.flac")
##   echo t.artist, " - ", t.title, " (", t.durationMs div 1000, " s)"
##   if t.picture.len > 0: cover = decodeImage(t.picture)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, os, base64]
import std/unicode except strip

type
  AudioTags* = object
    ## What `readAudioTags` read ("" and 0 where the file does not say).
    format*: string              ## "MP3", "FLAC", "M4A", "Ogg Vorbis", "Opus", "WAV" ("" not one)
    title*, artist*, album*, albumArtist*: string
    genre*, year*, composer*, comment*, lyrics*: string
    track*, trackTotal*, disc*, discTotal*: int
    durationMs*: int             ## how long it plays (0: not known)
    sampleRate*, channels*: int
    bitrateKbps*: int            ## its average bit rate
    hasGain*: bool               ## it has ReplayGain's track gain
    gainDb*, albumGainDb*: float ## ReplayGain's gains (dB: -6.5 plays 6.5 dB softer)
    picture*: string             ## its cover's bytes, JPEG or PNG ("" none, or not asked for)
    pictureMime*: string         ## "image/jpeg", "image/png"

  Source = object
    ## (the file, or bytes in memory: what is read is only what is asked for)
    data: string
    f: File
    open: bool
    size: int64

const Genres = [
  "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz",
  "Metal", "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno",
  "Industrial", "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno",
  "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical", "Instrumental",
  "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise", "Alternative Rock", "Bass", "Soul",
  "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic",
  "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream",
  "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk", "Jungle",
  "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes", "Trailer",
  "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll",
  "Hard Rock"]
  ## (ID3v1's numbered genres)

const
  MaxPicture = 16 * 1024 * 1024  ## (a cover larger than this is not kept)
  MaxTag = 64 * 1024 * 1024      ## (nor a tag larger than this read)

# ---- reading ----------------------------------------------------------------------------------------

proc readAt(s: var Source; off: int64; n: int): string =
  ## (up to `n` bytes at `off`: fewer at the end, "" past it)
  if off < 0 or n <= 0 or off >= s.size: return ""
  let m = int(min(int64(n), s.size - off))
  if s.open:
    result = newString(m)
    s.f.setFilePos(off)
    let got = s.f.readBuffer(addr result[0], m)
    result.setLen(max(0, got))
  else:
    result = s.data[int(off) ..< int(off) + m]

proc u8(s: string; i: int): int = (if i >= 0 and i < s.len: ord(s[i]) else: 0)
proc be16(s: string; i: int): int = (u8(s, i) shl 8) or u8(s, i + 1)
proc be24(s: string; i: int): int = (u8(s, i) shl 16) or (u8(s, i + 1) shl 8) or u8(s, i + 2)
proc be32(s: string; i: int): int64 =
  (int64(u8(s, i)) shl 24) or (int64(u8(s, i + 1)) shl 16) or (int64(u8(s, i + 2)) shl 8) or
    int64(u8(s, i + 3))
proc be64(s: string; i: int): int64 = (be32(s, i) shl 32) or be32(s, i + 4)
proc le16(s: string; i: int): int = u8(s, i) or (u8(s, i + 1) shl 8)
proc le32(s: string; i: int): int64 =
  int64(u8(s, i)) or (int64(u8(s, i + 1)) shl 8) or (int64(u8(s, i + 2)) shl 16) or
    (int64(u8(s, i + 3)) shl 24)
proc le64(s: string; i: int): int64 = le32(s, i) or (le32(s, i + 4) shl 32)
proc syncsafe(s: string; i: int): int =
  ((u8(s, i) and 0x7F) shl 21) or ((u8(s, i + 1) and 0x7F) shl 14) or
    ((u8(s, i + 2) and 0x7F) shl 7) or (u8(s, i + 3) and 0x7F)

proc part(s: string; a, b: int): string =
  ## (s[a ..< b], cut to what there is)
  let a2 = clamp(a, 0, s.len)
  let b2 = clamp(b, a2, s.len)
  s[a2 ..< b2]

proc small(x: int64): int =
  ## (a length or a count read from the file as an int: -1 when it is below 0, at most 2^31 - 1 --
  ## a 32-bit program's too)
  if x < 0: -1 elif x > int64(high(int32)): int(high(int32)) else: int(x)

proc msOf(units: float; perSecond: float): int =
  ## (`units` of a second's `perSecond` in milliseconds: 0 .. a few weeks, whatever the file says)
  if perSecond <= 0 or units <= 0: 0 else: int(min(units * 1000 / perSecond, 2e9))

proc kbpsOf(bytes: int64; ms: int): int =
  if ms <= 0 or bytes <= 0: 0 else: int(min(float(bytes) * 8 / float(ms), 1e9))

proc cleanText(t: string): string =
  ## (a tag's text: no NULs at its end, no control characters, valid UTF-8, trimmed)
  var r = t
  while r.len > 0 and r[^1] == '\0': r.setLen(r.len - 1)
  for c in r.mitems:
    if c in {'\0' .. '\31'} and c notin {'\n', '\t'}: c = ' '
  if validateUtf8(r) >= 0:
    # (Latin-1 bytes as their letters)
    var u = ""
    for c in r: u.add Rune(ord(c)).toUTF8
    r = u
  r.strip

proc latin1(s: string): string =
  for c in s: result.add Rune(ord(c)).toUTF8

proc utf16(s: string; bigEndian: bool): string =
  var be = bigEndian
  var i = 0
  if s.len >= 2:
    if u8(s, 0) == 0xFF and u8(s, 1) == 0xFE: (be = false; i = 2)
    elif u8(s, 0) == 0xFE and u8(s, 1) == 0xFF: (be = true; i = 2)
  while i + 1 < s.len:
    var c = if be: be16(s, i) else: le16(s, i)
    i += 2
    if c == 0: break
    if c >= 0xD800 and c < 0xDC00 and i + 1 < s.len:
      let d = if be: be16(s, i) else: le16(s, i)
      if d >= 0xDC00 and d < 0xE000:
        c = 0x10000 + ((c - 0xD800) shl 10) + (d - 0xDC00)
        i += 2
    if c >= 0xD800 and c < 0xE000: c = 0xFFFD
    result.add Rune(c).toUTF8

proc decodeText(enc: int; s: string): string =
  ## (ID3's text in its encoding: 0 Latin-1, 1 UTF-16 with a BOM, 2 UTF-16BE, 3 UTF-8)
  case enc
  of 1: utf16(s, false)
  of 2: utf16(s, true)
  of 3: s
  else: latin1(s)

proc splitTerm(enc: int; s: string; at: int): (string, int) =
  ## (the text up to its terminator -- one NUL, or two in UTF-16 -- and where after it)
  if enc in {1, 2}:
    var i = at
    while i + 1 < s.len:
      if s[i] == '\0' and s[i + 1] == '\0': return (s.part(at, i), i + 2)
      i += 2
    (s.part(at, s.len), s.len)
  else:
    let e = s.find('\0', at)
    if e < 0: (s.part(at, s.len), s.len) else: (s.part(at, e), e + 1)

proc numPair(s: string): (int, int) =
  ## ("3/12" -> 3, 12)
  let p = s.strip.split('/')
  var a, b = 0
  if p.len > 0:
    try: a = parseInt(p[0].strip) except ValueError: discard
  if p.len > 1:
    try: b = parseInt(p[1].strip) except ValueError: discard
  (a, b)

proc gainOf(s: string): (bool, float) =
  ## ("-6.50 dB" -> -6.5)
  var t = s.strip.toLowerAscii
  if t.endsWith("db"): t = t[0 ..< ^2].strip
  try: (true, parseFloat(t)) except ValueError: (false, 0.0)

proc genreName(s: string): string =
  ## (ID3's "(13)", "13" or "(13)Pop": its name)
  var t = s.strip
  if t.len >= 3 and t[0] == '(':
    let e = t.find(')')
    if e > 1:
      let n = t[1 ..< e]
      let rest = t[e + 1 .. ^1].strip
      if rest.len > 0: return rest
      t = n
  if t.len > 0 and t.len <= 3 and t.allCharsInSet(Digits):
    let n = parseInt(t)
    if n < Genres.len: return Genres[n]
  t

proc setField(t: var AudioTags; key, value: string) =
  ## (a Vorbis comment's or a freeform item's field)
  let v = cleanText(value)
  if v.len == 0: return
  case key.toUpperAscii
  of "TITLE": (if t.title.len == 0: t.title = v)
  of "ARTIST": (if t.artist.len == 0: t.artist = v)
  of "ALBUM": (if t.album.len == 0: t.album = v)
  of "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST": (if t.albumArtist.len == 0: t.albumArtist = v)
  of "GENRE": (if t.genre.len == 0: t.genre = v)
  of "DATE", "YEAR": (if t.year.len == 0: t.year = v)
  of "COMPOSER": (if t.composer.len == 0: t.composer = v)
  of "COMMENT", "DESCRIPTION": (if t.comment.len == 0: t.comment = v)
  of "LYRICS", "UNSYNCEDLYRICS": (if t.lyrics.len == 0: t.lyrics = v)
  of "TRACKNUMBER":
    let (a, b) = numPair(v)
    t.track = a
    if b > 0: t.trackTotal = b
  of "TRACKTOTAL", "TOTALTRACKS":
    t.trackTotal = numPair(v)[0]
  of "DISCNUMBER":
    let (a, b) = numPair(v)
    t.disc = a
    if b > 0: t.discTotal = b
  of "DISCTOTAL", "TOTALDISCS":
    t.discTotal = numPair(v)[0]
  of "REPLAYGAIN_TRACK_GAIN":
    let (ok, g) = gainOf(v)
    if ok: (t.hasGain = true; t.gainDb = g)
  of "REPLAYGAIN_ALBUM_GAIN":
    let (ok, g) = gainOf(v)
    if ok: t.albumGainDb = g
  else: discard

proc pictureBlock(t: var AudioTags; b: string; want: bool) =
  ## (FLAC's PICTURE block -- an Ogg file's METADATA_BLOCK_PICTURE too: type, MIME, description,
  ## sizes, the bytes; a front cover wins over any other)
  if not want or b.len < 32: return
  let kind = be32(b, 0)
  let ml = small(be32(b, 4))
  if ml < 0 or ml > b.len - 8: return
  let mime = b.part(8, 8 + ml)
  var i = 8 + ml
  let dl = small(be32(b, i))
  if dl < 0 or dl > b.len - i - 4: return
  i += 4 + dl + 16
  let n = small(be32(b, i))
  if n <= 0 or n > MaxPicture or n > b.len - i - 4: return
  if t.picture.len == 0 or kind == 3:
    t.picture = b.part(i + 4, i + 4 + n)
    t.pictureMime = mime.toLowerAscii

proc vorbisComment(t: var AudioTags; s: string; at: int; want: bool) =
  ## (a Vorbis comment block -- FLAC's, Ogg's: its vendor, then KEY=value fields, little-endian
  ## lengths)
  var i = at
  let vl = le32(s, i)
  if vl < 0 or vl > s.len: return
  i += 4 + small(vl)
  let n = le32(s, i)
  i += 4
  var k = 0'i64
  while k < n and i + 4 <= s.len:
    let l = le32(s, i)
    i += 4
    if l < 0 or l > int64(s.len - i): break
    let f = s.part(i, i + small(l))
    i += small(l)
    inc k
    let e = f.find('=')
    if e <= 0: continue
    let key = f[0 ..< e].toUpperAscii
    if key == "METADATA_BLOCK_PICTURE":
      if want:
        try: pictureBlock(t, decode(f[e + 1 .. ^1]), want) except CatchableError: discard
    else: setField(t, key, f[e + 1 .. ^1])

# ---- MP3: ID3v2, ID3v1, its frames' header ----------------------------------------------------------

proc id3v2(t: var AudioTags; s: var Source; want: bool): int64 =
  ## (the ID3v2 tag at the start: read into `t`; how long it is -- 0 when there is none)
  let h = s.readAt(0, 10)
  if h.len < 10 or not h.startsWith("ID3"): return 0
  let ver = u8(h, 3)
  let flags = u8(h, 5)
  let size = syncsafe(h, 6)
  result = 10 + int64(size) + (if (flags and 0x10) != 0: 10 else: 0)
  if ver < 2 or ver > 4 or size <= 0 or size > MaxTag: return
  var d = s.readAt(10, size)
  if ver <= 3 and (flags and 0x80) != 0:
    # (the whole tag unsynchronised: FF 00 back to FF)
    d = d.replace("\xFF\x00", "\xFF")
  var i = 0
  if (flags and 0x40) != 0 and ver >= 3:
    let el = if ver == 4: syncsafe(d, 0) else: small(be32(d, 0)) + 4
    if el > 0 and el < d.len: i = el
  let idLen = if ver == 2: 3 else: 4
  let hdLen = if ver == 2: 6 else: 10
  while i + hdLen <= d.len:
    let id = d.part(i, i + idLen)
    if id[0] == '\0': break
    let fl = if ver == 2: be24(d, i + 3) elif ver == 4: syncsafe(d, i + 4) else: small(be32(d, i + 4))
    let fflags = if ver >= 3: be16(d, i + 8) else: 0
    i += hdLen
    if fl <= 0 or fl > d.len - i: break
    var f = d.part(i, i + fl)
    i += fl
    if ver == 4:
      var skip = 0
      if (fflags and 0x0040) != 0: skip = 1          # (a group id)
      if (fflags and 0x0001) != 0: skip += 4         # (its length again)
      if (fflags and 0x0002) != 0: f = f.part(skip, f.len).replace("\xFF\x00", "\xFF")
      elif skip > 0: f = f.part(skip, f.len)
      if (fflags and 0x000C) != 0: continue          # (compressed or encrypted: not read)
    elif ver == 3 and (fflags and 0x00C0) != 0: continue
    if f.len < 1: continue
    let enc = u8(f, 0)
    template text(): string =
      # (several values -- ID3v2.4 -- one after another, each ended by a NUL: "; " between them)
      var v = decodeText(enc, f.part(1, f.len))
      while v.len > 0 and v[^1] == '\0': v.setLen(v.len - 1)
      cleanText(v.replace("\0", "; "))
    case id
    of "TIT2", "TT2": (if t.title.len == 0: t.title = text())
    of "TPE1", "TP1": (if t.artist.len == 0: t.artist = text())
    of "TALB", "TAL": (if t.album.len == 0: t.album = text())
    of "TPE2", "TP2": (if t.albumArtist.len == 0: t.albumArtist = text())
    of "TCON", "TCO": (if t.genre.len == 0: t.genre = genreName(text()))
    of "TYER", "TYE", "TDRC", "TDOR": (if t.year.len == 0: t.year = text())
    of "TCOM", "TCM": (if t.composer.len == 0: t.composer = text())
    of "TRCK", "TRK":
      let (a, b) = numPair(text())
      t.track = a
      t.trackTotal = b
    of "TPOS", "TPA":
      let (a, b) = numPair(text())
      t.disc = a
      t.discTotal = b
    of "TLEN", "TLE":
      if t.durationMs == 0:
        try: t.durationMs = parseInt(text()) except ValueError: discard
    of "TXXX", "TXX":
      let (k, at) = splitTerm(enc, f, 1)
      setField(t, cleanText(decodeText(enc, k)), decodeText(enc, f.part(at, f.len)))
    of "COMM", "COM", "USLT", "ULT":
      if f.len > 4:
        let (_, at) = splitTerm(enc, f, 4)
        let v = cleanText(decodeText(enc, f.part(at, f.len)))
        if id in ["COMM", "COM"]: (if t.comment.len == 0: t.comment = v)
        elif t.lyrics.len == 0: t.lyrics = v
    of "APIC", "PIC":
      if not want: continue
      var j = 1
      var mime: string
      if id == "PIC":
        mime = "image/" & f.part(1, 4).toLowerAscii.replace("jpg", "jpeg")
        j = 4
      else:
        let e = f.find('\0', 1)
        if e < 0: continue
        mime = f.part(1, e).toLowerAscii
        if '/' notin mime: mime = "image/" & mime.replace("jpg", "jpeg")
        j = e + 1
      let kind = u8(f, j)
      let (_, at) = splitTerm(enc, f, j + 1)
      let pic = f.part(at, f.len)
      if pic.len > 0 and pic.len <= MaxPicture and (t.picture.len == 0 or kind == 3):
        t.picture = pic
        t.pictureMime = if mime == "image/": "image/jpeg" else: mime
    else: discard

proc id3v1(t: var AudioTags; s: var Source) =
  ## (the 128 bytes at the end: what ID3v2 did not say)
  if s.size < 128: return
  let d = s.readAt(s.size - 128, 128)
  if not d.startsWith("TAG"): return
  template field(a, b: int): string = cleanText(latin1(d.part(a, b).split('\0')[0]))
  if t.title.len == 0: t.title = field(3, 33)
  if t.artist.len == 0: t.artist = field(33, 63)
  if t.album.len == 0: t.album = field(63, 93)
  if t.year.len == 0: t.year = field(93, 97)
  if t.track == 0 and u8(d, 125) == 0 and u8(d, 126) != 0: t.track = u8(d, 126)
  if t.genre.len == 0 and u8(d, 127) < Genres.len: t.genre = Genres[u8(d, 127)]

const
  Mp3Rates = [[11025, 12000, 8000], [0, 0, 0], [22050, 24000, 16000], [44100, 48000, 32000]]
  Mp3Kbps = [
    # (MPEG-1 layer I, II, III; MPEG-2/2.5 layer I, II/III)
    [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448, 0],
    [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 0],
    [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0],
    [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256, 0],
    [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0]]

proc mp3Sound(t: var AudioTags; s: var Source; start: int64) =
  ## (its first frame: the rate, the channels, the bit rate; the Xing, Info or VBRI header's
  ## frame count, its length -- else the length from the bit rate)
  let d = s.readAt(start, 64 * 1024)
  var i = 0
  while i + 4 <= d.len:
    if u8(d, i) == 0xFF and (u8(d, i + 1) and 0xE0) == 0xE0:
      let v = (u8(d, i + 1) shr 3) and 3          # 0 2.5, 2 2, 3 1
      let layer = (u8(d, i + 1) shr 1) and 3       # 1 III, 2 II, 3 I
      let bi = u8(d, i + 2) shr 4
      let ri = (u8(d, i + 2) shr 2) and 3
      if v != 1 and layer != 0 and bi != 0 and bi != 15 and ri != 3:
        let rate = Mp3Rates[v][ri]
        let table = if v == 3: 3 - layer else: (if layer == 3: 3 else: 4)
        let kbps = Mp3Kbps[table][bi]
        let mode = u8(d, i + 3) shr 6
        let spf = if layer == 3: 384 elif layer == 2 or v == 3: 1152 else: 576
        t.sampleRate = rate
        t.channels = if mode == 3: 1 else: 2
        t.bitrateKbps = kbps
        # (Xing / Info after the side information; VBRI 32 bytes in)
        let side = if v == 3: (if mode == 3: 17 else: 32) else: (if mode == 3: 9 else: 17)
        let x = i + 4 + side
        var frames = 0'i64
        if d.part(x, x + 4) in ["Xing", "Info"] and (u8(d, x + 7) and 1) != 0:
          frames = be32(d, x + 8)
        elif d.part(i + 36, i + 40) == "VBRI":
          frames = be32(d, i + 36 + 14)
        if frames > 0 and rate > 0:
          t.durationMs = msOf(float(frames) * float(spf), float(rate))
          let bytes = s.size - start
          t.bitrateKbps = kbpsOf(bytes, t.durationMs)
        elif kbps > 0 and t.durationMs == 0:
          t.durationMs = msOf(float(s.size - start) * 8 / 1000, float(kbps))
        return
    inc i

# ---- FLAC -------------------------------------------------------------------------------------------

proc flac(t: var AudioTags; s: var Source; start: int64; want: bool) =
  var p = start + 4
  for _ in 0 ..< 1000:
    let h = s.readAt(p, 4)
    if h.len < 4: break
    let last = (u8(h, 0) and 0x80) != 0
    let kind = u8(h, 0) and 0x7F
    let n = be24(h, 1)
    p += 4
    case kind
    of 0:
      let b = s.readAt(p, n)
      if b.len >= 18:
        t.sampleRate = (u8(b, 10) shl 12) or (u8(b, 11) shl 4) or (u8(b, 12) shr 4)
        t.channels = ((u8(b, 12) shr 1) and 7) + 1
        let total = (int64(u8(b, 13) and 0x0F) shl 32) or be32(b, 14)
        t.durationMs = msOf(float(total), float(t.sampleRate))
    of 4: vorbisComment(t, s.readAt(p, n), 0, want)
    of 6: (if want: pictureBlock(t, s.readAt(p, n), want))
    else: discard
    p += n
    if last: break
  t.bitrateKbps = kbpsOf(s.size - p, t.durationMs)

# ---- Ogg: Vorbis and Opus ---------------------------------------------------------------------------

proc oggPackets(s: var Source; start: int64; count: int): seq[string] =
  ## (the first `count` packets of its first stream, put back together across pages)
  var p = start
  var cur = ""
  var pages = 0
  while result.len < count and pages < 64:
    let h = s.readAt(p, 27)
    if h.len < 27 or not h.startsWith("OggS"): break
    let segs = u8(h, 26)
    let table = s.readAt(p + 27, segs)
    var body = 0
    for c in table: body += ord(c)
    let data = s.readAt(p + 27 + segs, body)
    var at = 0
    for c in table:
      let l = ord(c)
      cur.add data.part(at, at + l)
      at += l
      if cur.len > MaxTag: return
      if l < 255:
        result.add cur
        cur = ""
        if result.len >= count: break
    p += 27 + int64(segs) + int64(body)
    inc pages

proc oggLastGranule(s: var Source): int64 =
  ## (the position of the last page: the length in samples)
  let n = int(min(s.size, 64 * 1024))
  let d = s.readAt(s.size - n, n)
  let at = d.rfind("OggS")
  if at >= 0 and at + 14 <= d.len: le64(d, at + 6) else: 0

proc ogg(t: var AudioTags; s: var Source; start: int64; want: bool) =
  let ps = oggPackets(s, start, 2)
  if ps.len == 0: return
  let id = ps[0]
  var rate = 0
  var preSkip = 0
  var opus = false
  if id.startsWith("\x01vorbis") and id.len >= 16:
    t.format = "Ogg Vorbis"
    t.channels = u8(id, 11)
    rate = small(le32(id, 12))
    t.sampleRate = rate
  elif id.startsWith("OpusHead") and id.len >= 16:
    t.format = "Opus"
    opus = true
    t.channels = u8(id, 9)
    preSkip = le16(id, 10)
    t.sampleRate = 48000                               # (Opus plays at 48 kHz, its positions too)
    rate = 48000
  else: return
  if ps.len > 1:
    let c = ps[1]
    if c.startsWith("\x03vorbis"): vorbisComment(t, c, 7, want)
    elif c.startsWith("OpusTags"): vorbisComment(t, c, 8, want)
  let g = oggLastGranule(s)
  if g > preSkip: t.durationMs = msOf(float(g) - float(preSkip), float(rate))
  t.bitrateKbps = kbpsOf(s.size, t.durationMs)
  discard opus

# ---- MP4 / M4A ----------------------------------------------------------------------------------------

proc mp4Item(t: var AudioTags; name, data: string; want: bool) =
  ## (one of iTunes' items: its `data` atom's payload after its type and locale)
  if data.len < 8: return
  let kind = int(be32(data, 0) and 0xFFFFFF)
  let v = data.part(8, data.len)
  template txt(): string = cleanText(v)
  case name
  of "\xA9nam": t.title = txt()
  of "\xA9ART": t.artist = txt()
  of "aART": t.albumArtist = txt()
  of "\xA9alb": t.album = txt()
  of "\xA9gen": t.genre = txt()
  of "gnre":
    let n = be16(v, 0)
    if n > 0 and n - 1 < Genres.len and t.genre.len == 0: t.genre = Genres[n - 1]
  of "\xA9day": t.year = txt()
  of "\xA9wrt": t.composer = txt()
  of "\xA9cmt": t.comment = txt()
  of "\xA9lyr": t.lyrics = txt()
  of "trkn":
    t.track = be16(v, 2)
    t.trackTotal = be16(v, 4)
  of "disk":
    t.disc = be16(v, 2)
    t.discTotal = be16(v, 4)
  of "covr":
    if want and v.len > 0 and v.len <= MaxPicture and t.picture.len == 0:
      t.picture = v
      t.pictureMime = if kind == 14 or v.startsWith("\x89PNG"): "image/png" else: "image/jpeg"
  else: discard

proc mp4Atoms(t: var AudioTags; s: var Source; a, b: int64; path: string; want: bool; depth = 0) =
  ## (the atoms from `a` to `b`: into moov, udta, meta, ilst; the length from mvhd)
  if depth > 8: return
  var p = a
  var guard = 0
  while p + 8 <= b and guard < 4096:
    inc guard
    let h = s.readAt(p, 16)
    if h.len < 8: break
    var size = be32(h, 0)
    let kind = h.part(4, 8)
    var hl = 8'i64
    if size == 1:
      size = be64(h, 8)
      hl = 16
    elif size == 0: size = b - p
    if size < hl or size > b - p: break
    let body = p + hl
    let bodyLen = size - hl
    case kind
    of "moov", "udta", "ilst", "trak", "mdia", "minf", "stbl":
      mp4Atoms(t, s, body, p + size, path & "/" & kind, want, depth + 1)
    of "meta":
      # (a full box: its version and flags first)
      mp4Atoms(t, s, body + 4, p + size, path & "/meta", want, depth + 1)
    of "mvhd":
      let d = s.readAt(body, 32)
      let v = u8(d, 0)
      let (scale, dur) = if v == 1: (be32(d, 20), be64(d, 24)) else: (be32(d, 12), be32(d, 16))
      if t.durationMs == 0: t.durationMs = msOf(float(dur), float(scale))
    of "stsd":
      # (the sound's own entry -- mp4a, alac, Opus, fLaC, ac-3: its channels and rate; a
      # video's entry is not one)
      let d = s.readAt(body, 48)
      let entry = d.part(12, 16)
      if t.channels == 0 and entry in ["mp4a", "alac", "Opus", "fLaC", "ac-3", "ec-3", "samr"]:
        t.channels = be16(d, 8 + 24)
        t.sampleRate = small(be32(d, 8 + 32) shr 16)
    else:
      if path.endsWith("/ilst") and bodyLen <= MaxTag:
        # (an item: a `data` atom in it -- or for "----", mean, name and data)
        if not want and kind == "covr":
          p += size
          continue
        let item = s.readAt(body, int(bodyLen))
        var q = 0
        var freeName = ""
        while q + 8 <= item.len:
          let l = small(be32(item, q))
          if l < 8 or l > item.len - q: break
          let k = item.part(q + 4, q + 8)
          if k == "data":
            if kind == "----": setField(t, freeName, cleanText(item.part(q + 16, q + l)))
            else: mp4Item(t, kind, item.part(q + 8, q + l), want)
          elif k == "name": freeName = item.part(q + 12, q + l)
          q += l
    p += size

proc mp4(t: var AudioTags; s: var Source; want: bool) =
  t.format = "M4A"
  mp4Atoms(t, s, 0, s.size, "", want)
  t.bitrateKbps = kbpsOf(s.size, t.durationMs)

# ---- WAV --------------------------------------------------------------------------------------------

proc wav(t: var AudioTags; s: var Source) =
  t.format = "WAV"
  var p = 12'i64
  var byteRate = 0'i64
  for _ in 0 ..< 256:
    let h = s.readAt(p, 8)
    if h.len < 8: break
    let id = h.part(0, 4)
    let n = le32(h, 4)
    if n < 0: break
    case id
    of "fmt ":
      let f = s.readAt(p + 8, 16)
      t.channels = le16(f, 2)
      t.sampleRate = small(le32(f, 4))
      byteRate = le32(f, 8)
      t.bitrateKbps = small(byteRate * 8 div 1000)
    of "data":
      t.durationMs = msOf(float(min(n, s.size - p - 8)), float(byteRate))
    of "LIST":
      let d = s.readAt(p + 8, int(min(n, int64(MaxTag))))
      if d.startsWith("INFO"):
        var q = 4
        while q + 8 <= d.len:
          let k = d.part(q, q + 4)
          let l = small(le32(d, q + 4))
          if l < 0 or l > d.len - q - 8: break
          let v = cleanText(d.part(q + 8, q + 8 + l))
          case k
          of "INAM": t.title = v
          of "IART": t.artist = v
          of "IPRD": t.album = v
          of "ICRD": t.year = v
          of "IGNR": t.genre = v
          of "ICMT": t.comment = v
          of "ITRK", "IPRT": t.track = numPair(v)[0]
          else: discard
          q += 8 + l + (l and 1)
    else: discard
    p += 8 + n + (n and 1)

# ---- the file -----------------------------------------------------------------------------------------

proc readTags(s: var Source; picture: bool): AudioTags =
  if s.size < 4: return
  let head = s.readAt(0, 12)
  if head.startsWith("RIFF") and head.part(8, 12) == "WAVE":
    wav(result, s)
    return
  if head.part(4, 8) == "ftyp":
    mp4(result, s, picture)
    return
  # (an ID3v2 tag may come before anything: FLAC's and Ogg's too, sometimes)
  let start = id3v2(result, s, picture)
  let after = s.readAt(start, 4)
  if after == "fLaC":
    result.format = "FLAC"
    flac(result, s, start, picture)
  elif after == "OggS":
    ogg(result, s, start, picture)
  elif start > 0 or (u8(head, 0) == 0xFF and (u8(head, 1) and 0xE0) == 0xE0) or s.size >= 128:
    mp3Sound(result, s, start)
    if result.sampleRate > 0 or start > 0:
      result.format = "MP3"
      id3v1(result, s)

proc readAudioTags*(path: string; picture = true): AudioTags =
  ## What the music file at `path` says about itself (`AudioTags`; its `format` "" when it is not
  ## one this reads, or cannot be read). `picture` false: its cover not read (a library's first
  ## pass is quicker). Any thread may call it.
  var s = Source()
  if not open(s.f, path, fmRead): return
  s.open = true
  try:
    s.size = getFileSize(s.f)
    result = readTags(s, picture)
  except IOError, OSError, ValueError:
    discard
  finally:
    close(s.f)

proc readAudioTagsFrom*(data: string; picture = true): AudioTags =
  ## `readAudioTags` of a file's bytes in memory.
  var s = Source(data: data, size: data.len)
  try: result = readTags(s, picture)
  except ValueError: discard

proc isAudioFile*(path: string): bool =
  ## The file's name says it is music `readAudioTags` reads: .mp3, .flac, .m4a, .mp4, .aac, .alac,
  ## .ogg, .oga, .opus, .wav.
  path.splitFile.ext.toLowerAscii in [".mp3", ".flac", ".m4a", ".m4b", ".mp4", ".aac", ".alac",
                                      ".ogg", ".oga", ".opus", ".wav"]
