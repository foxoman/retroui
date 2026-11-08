## Wayland's wire protocol, the client's side, without libwayland: the
## socket (`$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`, or the one a launcher
## handed over in `WAYLAND_SOCKET`), requests written as the protocol has
## them (object, opcode and size, then the arguments, each a multiple of
## four bytes; file descriptors beside them), and events read back the
## same way, for the driver to take apart (`WlMsg`).
##
## Object ids: the client's from 2 up, an id given back by the server's
## `wl_display.delete_id` used again. Nothing here knows any interface but
## `wl_display`'s two events the driver forwards.

import std/[posix, os, strutils, dynlib]

type
  WlConn* = ref object
    fd*: cint                    ## the socket (-1: closed)
    outb: string                 ## requests not sent yet
    outFds: seq[cint]            ## ... and the descriptors they carry
    inb: string                  ## bytes read, not taken apart yet
    inFds: seq[cint]             ## descriptors that came, not taken yet
    nextId: uint32
    freeIds: seq[uint32]
    failed*: bool                ## the socket broke (or the server said no)
    error*: string

  WlMsg* = object
    ## An event: what it is for and which; its arguments read in order.
    obj*: uint32
    op*: int
    body*: string
    pos: int
    conn: WlConn

  WlArgKind = enum akU, akI, akS, akA, akFd, akFixed
  WlArg* = object
    case kind: WlArgKind
    of akU, akI: n: uint32
    of akS, akA: s: string
    of akFd: fd: cint
    of akFixed: f: int32

proc wu*(x: uint32 | int | uint): WlArg = WlArg(kind: akU, n: uint32(x))
  ## An unsigned argument, an object (0: none) or a new id.
proc wi*(x: int32 | int): WlArg = WlArg(kind: akI, n: cast[uint32](int32(x)))
  ## A signed one.
proc wfixed*(x: float): WlArg = WlArg(kind: akFixed, f: int32(x * 256.0))
  ## A fixed-point number (24.8).
proc ws*(s: string): WlArg = WlArg(kind: akS, s: s)
  ## A string.
proc wa*(s: string): WlArg = WlArg(kind: akA, s: s)
  ## An array (its bytes).
proc wfd*(fd: cint): WlArg = WlArg(kind: akFd, fd: fd)
  ## A file descriptor (sent; the caller still closes its own).

const MSG_DONTWAIT = 0x40.cint
const MSG_CMSG_CLOEXEC = 0x40000000.cint

proc socketPath(): string =
  let display = getEnv("WAYLAND_DISPLAY", "wayland-0")
  if display.isAbsolute: return display
  let dir = getEnv("XDG_RUNTIME_DIR")
  if dir.len == 0: return ""
  dir / display

proc wlConnect*(): WlConn =
  ## The compositor's socket; nil when there is none.
  let handed = getEnv("WAYLAND_SOCKET")
  if handed.len > 0:
    try:
      let fd = cint(parseInt(handed))
      delEnv("WAYLAND_SOCKET")
      discard fcntl(fd, F_SETFD, FD_CLOEXEC)
      return WlConn(fd: fd, nextId: 2)
    except ValueError: discard
  let path = socketPath()
  if path.len == 0 or path.len >= 108: return nil
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  if fd.cint < 0: return nil
  discard fcntl(fd.cint, F_SETFD, FD_CLOEXEC)
  var sa: Sockaddr_un
  sa.sun_family = TSa_Family(AF_UNIX)
  for i, ch in path: sa.sun_path[i] = ch
  let len = SockLen(sizeof(sa.sun_family) + path.len + 1)
  if connect(fd, cast[ptr SockAddr](addr sa), len) != 0:
    discard posix.close(fd)
    return nil
  WlConn(fd: fd.cint, nextId: 2)

proc newId*(c: WlConn): uint32 =
  ## An id for a new object of the client's.
  if c.freeIds.len > 0: return c.freeIds.pop()
  result = c.nextId
  inc c.nextId

proc idDeleted*(c: WlConn; id: uint32) =
  ## The server is done with `id` (`wl_display.delete_id`): it may be used
  ## again.
  if id >= 2 and id < 0xFF000000'u32 and id notin c.freeIds: c.freeIds.add id

proc put32(s: var string; v: uint32) {.inline.} =
  let at = s.len
  s.setLen(at + 4)
  copyMem(addr s[at], unsafeAddr v, 4)

proc putBytes(s: var string; b: string; withNul: bool) =
  let n = b.len + (if withNul: 1 else: 0)
  s.put32(uint32(n))
  let at = s.len
  let padded = (n + 3) and not 3
  s.setLen(at + padded)
  if b.len > 0: copyMem(addr s[at], unsafeAddr b[0], b.len)
  for i in at + b.len ..< at + padded: s[i] = '\0'

proc send*(c: WlConn; obj: uint32; op: int; args: varargs[WlArg]) =
  ## A request to object `obj`, kept until `flush`.
  if c == nil or c.failed: return
  let at = c.outb.len
  c.outb.put32(obj)
  c.outb.put32(0)
  for a in args:
    case a.kind
    of akU, akI: c.outb.put32(a.n)
    of akFixed: c.outb.put32(cast[uint32](a.f))
    of akS: c.outb.putBytes(a.s, true)
    of akA: c.outb.putBytes(a.s, false)
    of akFd: c.outFds.add a.fd
  let size = uint32(c.outb.len - at)
  let word = (size shl 16) or uint32(op and 0xFFFF)
  copyMem(addr c.outb[at + 4], unsafeAddr word, 4)

proc fail(c: WlConn; why: string) =
  if not c.failed:
    c.failed = true
    c.error = why

proc flush*(c: WlConn): bool =
  ## Every request kept, sent (waiting while the socket is full).
  if c == nil or c.failed: return false
  var sent = 0
  while sent < c.outb.len:
    var iov = IOVec(iov_base: addr c.outb[sent], iov_len: csize_t(c.outb.len - sent))
    var msg: Tmsghdr
    msg.msg_iov = addr iov
    msg.msg_iovlen = 1
    var ctl: array[256, byte]
    var nfds = 0
    if c.outFds.len > 0:
      nfds = min(c.outFds.len, 28)            # (what libwayland sends at once at most)
      let space = CMSG_SPACE(csize_t(nfds * sizeof(cint)))
      msg.msg_control = addr ctl[0]
      msg.msg_controllen = space
      let cm = CMSG_FIRSTHDR(addr msg)
      cm.cmsg_level = SOL_SOCKET
      cm.cmsg_type = SCM_RIGHTS
      cm.cmsg_len = CMSG_LEN(csize_t(nfds * sizeof(cint)))
      copyMem(CMSG_DATA(cm), addr c.outFds[0], nfds * sizeof(cint))
    let n = sendmsg(SocketHandle(c.fd), addr msg, MSG_NOSIGNAL)
    if n < 0:
      let e = errno
      if e == EINTR: continue
      if e == EAGAIN or e == EWOULDBLOCK:
        var p = TPollfd(fd: c.fd, events: POLLOUT)
        discard poll(addr p, 1, 1000)
        continue
      c.fail("the compositor's socket: " & $strerror(e))
      return false
    if nfds > 0: c.outFds = c.outFds[nfds .. ^1]
    sent += n
  c.outb.setLen 0
  true

proc readSome*(c: WlConn; waitMs: int): bool =
  ## What the socket has, waiting up to `waitMs` (-1: as long as it takes)
  ## for something; false when nothing came (or the socket broke).
  if c == nil or c.failed: return false
  if waitMs != 0:
    var p = TPollfd(fd: c.fd, events: POLLIN)
    let r = poll(addr p, 1, cint(waitMs))
    if r <= 0: return false
  var buf: array[16384, byte]
  var iov = IOVec(iov_base: addr buf[0], iov_len: csize_t(buf.len))
  var ctl: array[512, byte]
  var msg: Tmsghdr
  msg.msg_iov = addr iov
  msg.msg_iovlen = 1
  msg.msg_control = addr ctl[0]
  msg.msg_controllen = csize_t(ctl.len)
  let n = recvmsg(SocketHandle(c.fd), addr msg, MSG_DONTWAIT or MSG_CMSG_CLOEXEC)
  if n < 0:
    let e = errno
    if e == EAGAIN or e == EWOULDBLOCK or e == EINTR: return false
    c.fail("the compositor's socket: " & $strerror(e))
    return false
  if n == 0:
    c.fail("the compositor closed the connection")
    return false
  var cm = CMSG_FIRSTHDR(addr msg)
  while cm != nil:
    if cm.cmsg_level == SOL_SOCKET and cm.cmsg_type == SCM_RIGHTS:
      let count = (int(cm.cmsg_len) - int(CMSG_LEN(0))) div sizeof(cint)
      let fds = cast[ptr UncheckedArray[cint]](CMSG_DATA(cm))
      for i in 0 ..< count: c.inFds.add fds[i]
    cm = CMSG_NXTHDR(addr msg, cm)
  let at = c.inb.len
  c.inb.setLen(at + n)
  copyMem(addr c.inb[at], addr buf[0], n)
  true

proc next*(c: WlConn; m: var WlMsg): bool =
  ## The next whole event read, if there is one.
  if c == nil or c.inb.len < 8: return false
  var obj, word: uint32
  copyMem(addr obj, addr c.inb[0], 4)
  copyMem(addr word, addr c.inb[4], 4)
  let size = int(word shr 16)
  if size < 8:
    c.fail("a message of the compositor's makes no sense")
    return false
  if c.inb.len < size: return false
  m = WlMsg(obj: obj, op: int(word and 0xFFFF), body: c.inb[8 ..< size], conn: c)
  c.inb = c.inb[size .. ^1]
  true

proc u32*(m: var WlMsg): uint32 =
  ## The next argument, unsigned (an object, an enum, a serial).
  if m.pos + 4 <= m.body.len:
    copyMem(addr result, addr m.body[m.pos], 4)
  m.pos += 4

proc i32*(m: var WlMsg): int32 = cast[int32](m.u32)
  ## ... signed.

proc fixed*(m: var WlMsg): float = float(m.i32) / 256.0
  ## ... fixed-point.

proc str*(m: var WlMsg): string =
  ## ... a string ("" for none).
  let n = int(m.u32)
  if n > 0 and m.pos + n <= m.body.len:
    result = m.body[m.pos ..< m.pos + n - 1]
  m.pos += (n + 3) and not 3

proc arr*(m: var WlMsg): string =
  ## ... an array, as its bytes.
  let n = int(m.u32)
  if n > 0 and m.pos + n <= m.body.len:
    result = m.body[m.pos ..< m.pos + n]
  m.pos += (n + 3) and not 3

proc fd*(m: var WlMsg): cint =
  ## ... a file descriptor (the caller's to close); -1 when none came.
  if m.conn.inFds.len == 0: return -1
  result = m.conn.inFds[0]
  m.conn.inFds.delete(0)

proc close*(c: WlConn) =
  if c == nil: return
  if c.fd >= 0: discard posix.close(c.fd)
  for fd in c.inFds: discard posix.close(fd)
  c.inFds.setLen 0
  c.fd = -1
  c.failed = true

var memfdCreate: proc (name: cstring; flags: cuint): cint {.cdecl, gcsafe.}
var memfdTried = false

proc memFile*(size: int): cint =
  ## A file of `size` bytes in memory, to share (memfd; else an unlinked
  ## file in XDG_RUNTIME_DIR); -1 when there can be none.
  if not memfdTried:
    memfdTried = true
    let self = loadLib()
    if self != nil: memfdCreate = cast[typeof(memfdCreate)](self.symAddr("memfd_create"))
  result = -1
  if memfdCreate != nil: result = memfdCreate("uirelays-shm", 1)     # MFD_CLOEXEC
  if result < 0:
    let dir = getEnv("XDG_RUNTIME_DIR", getTempDir())
    var tmpl = dir / "uirelays-shm-XXXXXX"
    result = mkstemp(cstring(tmpl))
    if result >= 0:
      discard unlink(cstring(tmpl))
      discard fcntl(result, F_SETFD, FD_CLOEXEC)
  if result < 0: return
  if ftruncate(result, Off(size)) != 0:
    discard posix.close(result)
    return -1
