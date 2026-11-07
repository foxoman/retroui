## A small D-Bus client over a Unix socket: enough for a program to talk to
## the session bus and the accessibility bus (AT-SPI) without libdbus --
## nothing to link, nothing to install.
##
## Messages are made with `DBusWriter` and read with `DBusReader`, in
## D-Bus's own encoding (alignment, arrays, structs, variants); a
## connection authenticates as the user (EXTERNAL), says Hello, and then
## sends and receives messages. Reading never blocks: `receive` takes what
## the socket has (call it when its `fd` is readable); `callWait` waits
## for one reply, keeping what else came.

import std/[posix, strutils, os, monotimes, times]

type
  DBusKind* = enum
    dkInvalid, dkMethodCall, dkMethodReturn, dkError, dkSignal

  DBusMsg* = object
    ## A message: its header and its body (still encoded: read it with a
    ## `DBusReader`).
    kind*: DBusKind
    flags*: uint8
    serial*, replySerial*: uint32
    path*, iface*, member*, errorName*, dest*, sender*, sig*: string
    body*: string
    big*: bool                 ## the body is big-endian

  DBusConn* = ref object
    ## A connection to a bus.
    fd*: cint                  ## the socket (-1: closed)
    serial: uint32
    inbuf: string
    queue*: seq[DBusMsg]       ## messages that came while `callWait` waited
    uniqueName*: string        ## the bus's name for this connection (":1.42")

  DBusWriter* = object
    ## Encodes values, little-endian, aligned as D-Bus wants.
    buf*: string

  DBusReader* = object
    ## Decodes the values of a message's body, in order.
    data*: string
    pos*: int
    big*: bool
    bad*: bool                 ## it ran past its end or met a type it cannot read

const
  NoReplyExpected* = 0x1'u8

# ---- writing ---------------------------------------------------------------------

proc pad*(w: var DBusWriter; n: int) =
  ## Zero bytes up to a multiple of `n`.
  while w.buf.len mod n != 0: w.buf.add '\0'

proc u8*(w: var DBusWriter; v: uint8) = w.buf.add char(v)

proc u32*(w: var DBusWriter; v: uint32) =
  w.pad(4)
  for k in 0 .. 3: w.buf.add char((v shr (8 * k)) and 0xFF)

proc i32*(w: var DBusWriter; v: int32) = w.u32(cast[uint32](v))

proc boolean*(w: var DBusWriter; v: bool) = w.u32(if v: 1 else: 0)

proc u64*(w: var DBusWriter; v: uint64) =
  w.pad(8)
  for k in 0 .. 7: w.buf.add char((v shr (8 * k)) and 0xFF)

proc f64*(w: var DBusWriter; v: float) = w.u64(cast[uint64](v))

proc str*(w: var DBusWriter; s: string) =
  ## A string (also an object path: `o`).
  w.u32(uint32(s.len))
  w.buf.add s
  w.buf.add '\0'

proc sig*(w: var DBusWriter; s: string) =
  ## A signature (`g`).
  w.u8(uint8(s.len))
  w.buf.add s
  w.buf.add '\0'

proc beginArray*(w: var DBusWriter; elemAlign: int): tuple[at, start: int] =
  ## An array's length (filled in by `endArray`), its elements aligned to
  ## `elemAlign` (8 for structs and dict entries).
  w.pad(4)
  result.at = w.buf.len
  w.u32(0)
  w.pad(elemAlign)
  result.start = w.buf.len

proc endArray*(w: var DBusWriter; a: tuple[at, start: int]) =
  let n = uint32(w.buf.len - a.start)
  for k in 0 .. 3: w.buf[a.at + k] = char((n shr (8 * k)) and 0xFF)

proc struct*(w: var DBusWriter) =
  ## A struct or a dict entry starts (aligned to 8).
  w.pad(8)

proc variantStr*(w: var DBusWriter; s: string) =
  w.sig("s")
  w.str(s)

proc variantInt*(w: var DBusWriter; v: int32) =
  w.sig("i")
  w.i32(v)

proc variantU32*(w: var DBusWriter; v: uint32) =
  w.sig("u")
  w.u32(v)

proc variantBool*(w: var DBusWriter; v: bool) =
  w.sig("b")
  w.boolean(v)

proc variantF64*(w: var DBusWriter; v: float) =
  w.sig("d")
  w.f64(v)

proc objRef*(w: var DBusWriter; bus, path: string) =
  ## A `(so)`: a bus name and an object path (AT-SPI's reference).
  w.struct()
  w.str(bus)
  w.str(path)

# ---- reading ---------------------------------------------------------------------

proc align*(r: var DBusReader; n: int) =
  while r.pos mod n != 0: inc r.pos

proc u8*(r: var DBusReader): uint8 =
  if r.pos >= r.data.len:
    r.bad = true
    return 0
  result = uint8(r.data[r.pos])
  inc r.pos

proc u32*(r: var DBusReader): uint32 =
  r.align(4)
  if r.pos + 4 > r.data.len:
    r.bad = true
    return 0
  for k in 0 .. 3:
    let b = uint32(uint8(r.data[r.pos + k]))
    result = result or (if r.big: b shl (8 * (3 - k)) else: b shl (8 * k))
  r.pos += 4

proc i32*(r: var DBusReader): int32 = cast[int32](r.u32())

proc boolean*(r: var DBusReader): bool = r.u32() != 0

proc u64*(r: var DBusReader): uint64 =
  r.align(8)
  if r.pos + 8 > r.data.len:
    r.bad = true
    return 0
  for k in 0 .. 7:
    let b = uint64(uint8(r.data[r.pos + k]))
    result = result or (if r.big: b shl (8 * (7 - k)) else: b shl (8 * k))
  r.pos += 8

proc f64*(r: var DBusReader): float = cast[float](r.u64())

proc str*(r: var DBusReader): string =
  let n = int(r.u32())
  if n < 0 or r.pos + n + 1 > r.data.len:
    r.bad = true
    return ""
  result = r.data[r.pos ..< r.pos + n]
  r.pos += n + 1

proc sig*(r: var DBusReader): string =
  let n = int(r.u8())
  if r.pos + n + 1 > r.data.len:
    r.bad = true
    return ""
  result = r.data[r.pos ..< r.pos + n]
  r.pos += n + 1

proc oneType(s: string; i: int): int =
  ## The end of the single complete type at `s[i]`.
  if i >= s.len: return i
  case s[i]
  of 'a': oneType(s, i + 1)
  of '(':
    var j = i + 1
    while j < s.len and s[j] != ')': j = oneType(s, j)
    j + 1
  of '{':
    var j = i + 1
    while j < s.len and s[j] != '}': j = oneType(s, j)
    j + 1
  else: i + 1

proc alignOf(c: char): int =
  case c
  of 'y', 'g', 'v': 1
  of 'n', 'q': 2
  of 'x', 't', 'd', '(', '{': 8
  else: 4

proc skip*(r: var DBusReader; t: string) =
  ## Reads past one value of the single complete type `t`.
  if t.len == 0 or r.bad: return
  case t[0]
  of 'y': discard r.u8()
  of 'b', 'i', 'u', 'h': discard r.u32()
  of 'n', 'q':
    r.align(2)
    r.pos += 2
  of 'x', 't', 'd': discard r.u64()
  of 's', 'o': discard r.str()
  of 'g': discard r.sig()
  of 'v':
    let s = r.sig()
    r.skip(s)
  of 'a':
    let n = int(r.u32())
    r.align(alignOf(if t.len > 1: t[1] else: 'y'))
    if n < 0 or r.pos + n > r.data.len:
      r.bad = true
      return
    r.pos += n
  of '(', '{':
    r.align(8)
    var j = 1
    while j < t.len - 1 and not r.bad:
      let e = oneType(t, j)
      r.skip(t[j ..< e])
      j = e
  else: r.bad = true

proc variant*(r: var DBusReader): tuple[sig: string; num: float; text: string; ok: bool] =
  ## A variant holding a number or a string (else skipped: `ok` false).
  let s = r.sig()
  result.sig = s
  result.ok = true
  case s
  of "d": result.num = r.f64()
  of "i": result.num = float(r.i32())
  of "u": result.num = float(r.u32())
  of "x": result.num = float(cast[int64](r.u64()))
  of "t": result.num = float(r.u64())
  of "b": result.num = (if r.boolean(): 1.0 else: 0.0)
  of "s", "o":
    result.text = r.str()
  else:
    r.skip(s)
    result.ok = false

proc reader*(m: DBusMsg): DBusReader =
  ## A reader of `m`'s body.
  DBusReader(data: m.body, big: m.big)

# ---- messages --------------------------------------------------------------------

proc encode(c: DBusConn; m: DBusMsg): string =
  var w: DBusWriter
  w.buf.add 'l'
  w.u8(uint8(ord(m.kind)))
  w.u8(m.flags)
  w.u8(1)
  w.u32(uint32(m.body.len))
  w.u32(m.serial)
  let a = w.beginArray(8)
  template field(code: uint8; t: string; body: untyped) =
    w.struct()
    w.u8(code)
    w.sig(t)
    body
  if m.path.len > 0: field(1, "o"): w.str(m.path)
  if m.iface.len > 0: field(2, "s"): w.str(m.iface)
  if m.member.len > 0: field(3, "s"): w.str(m.member)
  if m.errorName.len > 0: field(4, "s"): w.str(m.errorName)
  if m.replySerial != 0: field(5, "u"): w.u32(m.replySerial)
  if m.dest.len > 0: field(6, "s"): w.str(m.dest)
  if m.sig.len > 0: field(8, "g"): w.sig(m.sig)
  w.endArray(a)
  w.pad(8)
  w.buf.add m.body
  w.buf

proc decode(data: string; m: var DBusMsg): int =
  ## The length of the message at the start of `data` (0: not all there
  ## yet, -1: not a message), `m` filled.
  if data.len < 16: return 0
  let big = data[0] == 'B'
  if not big and data[0] != 'l': return -1
  var r = DBusReader(data: data, pos: 4, big: big)
  let bodyLen = int(r.u32())
  let serial = r.u32()
  let fieldsLen = int(r.u32())
  if bodyLen < 0 or fieldsLen < 0 or bodyLen > 128 shl 20 or fieldsLen > 1 shl 20: return -1
  var headEnd = 16 + fieldsLen
  while headEnd mod 8 != 0: inc headEnd
  if data.len < headEnd + bodyLen: return 0
  m = DBusMsg(kind: DBusKind(min(4, int(uint8(data[1])))), flags: uint8(data[2]),
              serial: serial, big: big)
  r.data = data[0 ..< 16 + fieldsLen]
  while r.pos < r.data.len and not r.bad:
    r.align(8)
    if r.pos >= r.data.len: break
    let code = r.u8()
    let t = r.sig()
    case code
    of 1: m.path = r.str()
    of 2: m.iface = r.str()
    of 3: m.member = r.str()
    of 4: m.errorName = r.str()
    of 5: m.replySerial = r.u32()
    of 6: m.dest = r.str()
    of 7: m.sender = r.str()
    of 8: m.sig = r.sig()
    else: r.skip(t)
  m.body = data[headEnd ..< headEnd + bodyLen]
  headEnd + bodyLen

# ---- the connection ----------------------------------------------------------------

proc close*(c: DBusConn) =
  if c != nil and c.fd >= 0:
    discard posix.close(c.fd)
    c.fd = -1

proc writeAll(c: DBusConn; s: string): bool =
  var at = 0
  while at < s.len:
    let n = posix.send(SocketHandle(c.fd), unsafeAddr s[at], s.len - at, MSG_NOSIGNAL)
    if n < 0:
      if errno == EINTR: continue
      if errno == EAGAIN or errno == EWOULDBLOCK:
        var p = TPollfd(fd: c.fd, events: POLLOUT)
        discard poll(addr p, 1, 1000)
        continue
      c.close()
      return false
    at += n
  true

proc readSome(c: DBusConn; waitMs: int): bool =
  ## What the socket has into `inbuf` (waiting up to `waitMs` for it);
  ## false when the connection is gone.
  if c.fd < 0: return false
  var p = TPollfd(fd: c.fd, events: POLLIN)
  if poll(addr p, 1, cint(waitMs)) <= 0: return true
  var buf: array[16384, char]
  let n = posix.recv(SocketHandle(c.fd), addr buf[0], buf.len, 0)
  if n == 0 or (n < 0 and errno notin [EINTR, EAGAIN, EWOULDBLOCK]):
    c.close()
    return false
  if n > 0:
    let old = c.inbuf.len
    c.inbuf.setLen(old + n)
    copyMem(addr c.inbuf[old], addr buf[0], n)
  true

proc takeMessages(c: DBusConn; into: var seq[DBusMsg]) =
  while true:
    var m: DBusMsg
    let n = decode(c.inbuf, m)
    if n < 0:
      c.close()
      return
    if n == 0: return
    c.inbuf = c.inbuf[n .. ^1]
    into.add m

proc receive*(c: DBusConn): seq[DBusMsg] =
  ## The messages that came (without waiting), the ones `callWait` kept
  ## first.
  result = move c.queue
  c.queue = @[]
  if c.fd < 0: return
  while true:
    let before = c.inbuf.len
    if not c.readSome(0): break
    if c.inbuf.len == before: break
  c.takeMessages(result)

proc send*(c: DBusConn; m: var DBusMsg): uint32 {.discardable.} =
  ## Sends `m` (its serial given here) and returns the serial.
  if c.fd < 0: return 0
  inc c.serial
  m.serial = c.serial
  if not c.writeAll(c.encode(m)): return 0
  c.serial

proc call*(c: DBusConn; dest, path, iface, member: string; sig = "";
           body = ""; noReply = false): uint32 {.discardable.} =
  ## Calls a method; the reply comes as a message with this serial as its
  ## `replySerial`.
  var m = DBusMsg(kind: dkMethodCall, dest: dest, path: path, iface: iface,
                  member: member, sig: sig, body: body,
                  flags: if noReply: NoReplyExpected else: 0)
  c.send(m)

proc callWait*(c: DBusConn; dest, path, iface, member: string; sig = "";
               body = ""; timeoutMs = 2000): DBusMsg =
  ## Calls a method and waits for its reply (or error); other messages
  ## that come meanwhile are kept for `receive`. `kind` dkInvalid: no reply.
  let serial = c.call(dest, path, iface, member, sig, body)
  if serial == 0: return
  let t0 = getMonoTime()
  while c.fd >= 0:
    var got: seq[DBusMsg]
    c.takeMessages(got)
    for m in got:
      if m.replySerial == serial and m.kind in {dkMethodReturn, dkError}:
        result = m
      else: c.queue.add m
    if result.kind != dkInvalid: return
    let left = timeoutMs - int((getMonoTime() - t0).inMilliseconds)
    if left <= 0: return
    if not c.readSome(min(left, 100)): return

proc reply*(c: DBusConn; to: DBusMsg; sig = ""; body = "") =
  ## Answers method call `to` (unless it asked for no answer).
  if (to.flags and NoReplyExpected) != 0: return
  var m = DBusMsg(kind: dkMethodReturn, replySerial: to.serial, dest: to.sender,
                  sig: sig, body: body)
  c.send(m)

proc replyError*(c: DBusConn; to: DBusMsg; name, text: string) =
  ## Answers method call `to` with an error.
  if (to.flags and NoReplyExpected) != 0: return
  var w: DBusWriter
  w.str(text)
  var m = DBusMsg(kind: dkError, replySerial: to.serial, dest: to.sender,
                  errorName: name, sig: "s", body: w.buf)
  c.send(m)

proc signal*(c: DBusConn; path, iface, member: string; sig = ""; body = "") =
  ## Sends a signal.
  var m = DBusMsg(kind: dkSignal, path: path, iface: iface, member: member,
                  sig: sig, body: body)
  c.send(m)

proc parseAddress(address: string): tuple[path: string; abstract: bool] =
  ## The first Unix socket of a D-Bus address ("unix:path=/run/user/1000/bus",
  ## "unix:abstract=/tmp/dbus-x,guid=...").
  for transport in address.split(';'):
    if not transport.startsWith("unix:"): continue
    for kv in transport[5 .. ^1].split(','):
      let eq = kv.find('=')
      if eq < 0: continue
      let k = kv[0 ..< eq]
      var v = kv[eq + 1 .. ^1]
      # (values may escape bytes as %XX)
      var dec = ""
      var i = 0
      while i < v.len:
        if v[i] == '%' and i + 2 < v.len:
          try:
            dec.add char(parseHexInt(v[i + 1 .. i + 2]))
            i += 3
            continue
          except ValueError: discard
        dec.add v[i]
        inc i
      if k == "path": return (dec, false)
      if k == "abstract": return (dec, true)

proc connectBus*(address: string; timeoutMs = 2000): DBusConn =
  ## A connection to the bus at `address`, authenticated and named (Hello);
  ## nil when that cannot be had.
  let (path, abstract) = parseAddress(address)
  if path.len == 0 or path.len > 100: return nil
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  if fd.cint < 0: return nil
  # (not passed on to the programs this one starts)
  discard fcntl(fd.cint, F_SETFD, FD_CLOEXEC)
  var sa: Sockaddr_un
  sa.sun_family = TSa_Family(AF_UNIX)
  var at = 0
  if abstract:
    sa.sun_path[0] = '\0'
    at = 1
  for i, ch in path: sa.sun_path[at + i] = ch
  let len = SockLen(sizeof(sa.sun_family) + at + path.len + (if abstract: 0 else: 1))
  if connect(fd, cast[ptr SockAddr](addr sa), len) != 0:
    discard posix.close(fd)
    return nil
  result = DBusConn(fd: fd.cint)
  # authenticate as this user (its uid in hex digits of its decimal form)
  let uid = $getuid()
  var hex = ""
  for ch in uid: hex.add toHex(ord(ch), 2).toLowerAscii
  if not result.writeAll("\0AUTH EXTERNAL " & hex & "\r\n"):
    return nil
  let t0 = getMonoTime()
  while "\r\n" notin result.inbuf:
    let left = timeoutMs - int((getMonoTime() - t0).inMilliseconds)
    if left <= 0 or not result.readSome(min(left, 100)):
      result.close()
      return nil
  if not result.inbuf.startsWith("OK"):
    result.close()
    return nil
  result.inbuf = result.inbuf[result.inbuf.find("\r\n") + 2 .. ^1]
  if not result.writeAll("BEGIN\r\n"):
    return nil
  let hello = result.callWait("org.freedesktop.DBus", "/org/freedesktop/DBus",
                              "org.freedesktop.DBus", "Hello", timeoutMs = timeoutMs)
  if hello.kind != dkMethodReturn:
    result.close()
    return nil
  var r = hello.reader()
  result.uniqueName = r.str()
  # (from now on reads never wait)
  discard fcntl(result.fd, F_SETFL, fcntl(result.fd, F_GETFL) or O_NONBLOCK)

proc sessionBus*(): DBusConn =
  ## The user's session bus ($DBUS_SESSION_BUS_ADDRESS, else
  ## $XDG_RUNTIME_DIR/bus); nil when there is none.
  var a = getEnv("DBUS_SESSION_BUS_ADDRESS")
  if a.len == 0:
    let rt = getEnv("XDG_RUNTIME_DIR")
    if rt.len > 0 and fileExists(rt / "bus"): a = "unix:path=" & rt / "bus"
  if a.len == 0: return nil
  connectBus(a)
