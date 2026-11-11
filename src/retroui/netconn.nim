## A connection to a server over TCP, encrypted with TLS -- for the
## protocols of lines (IMAP, SMTP, POP3, an IRC, a server of your own):
## open it encrypted from the start, or plain and encrypted later
## (STARTTLS), then write and read lines and bytes. A read waits at most
## the connection's timeout.
##
## Each system's own TLS does the work, so the certificates are checked
## against the system's own authorities, with nothing to install:
##
## - **Windows:** SChannel (the system's TLS, as its own programs use).
## - **macOS, iOS:** Secure Transport.
## - **Android app:** Java's TLS (tools/android/RetroNet.java); the APK
##   needs the INTERNET permission (`retroapk` adds it by itself).
## - **Linux, the BSDs, Termux:** OpenSSL (libssl 3 or 1.1), loaded the
##   first time a connection is encrypted -- not when the program starts:
##   a program without it runs, and says so when it needs it.
## - **Web pages:** no sockets (`netOpen` raises `NetError`).
##
## .. code-block:: nim
##   let c = netOpen("imap.example.com", 993, tls = true)
##   echo c.readLine()                     # "* OK IMAP ready"
##   c.write("a1 LOGOUT\r\n")
##   c.close()
##
##   let s = netOpen("smtp.example.com", 587)   # plain first
##   discard s.readLine()
##   s.write("EHLO me\r\n") ...
##   s.write("STARTTLS\r\n"); discard s.readLine()
##   s.startTls()                          # encrypted from here
##
## `insecure` takes any certificate (a server of your own, with one it
## signed itself): the connection is still encrypted, but nothing says
## who is at the other end.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils]
import uirelays/target   # (androidApp: an APK, not a program in Termux)
when androidApp:
  import std/base64
  import uirelays/services
elif not defined(wasm):
  import std/[net, nativesockets]
  when defined(windows):
    import std/[widestrs]
    from std/winlean import nil
  else:
    import std/posix
    when not (defined(macosx) or defined(ios)):
      import std/[os, dynlib]

when defined(windows) and not defined(wasm):
  type
    SecHandle = object
      lower, upper: uint
    SecBuffer = object
      cbBuffer, bufferType: uint32
      pvBuffer: pointer
    SecBufferDesc = object
      ulVersion, cBuffers: uint32
      pBuffers: ptr SecBuffer
    SchannelCred = object
      dwVersion, cCreds: uint32
      paCred, hRootStore: pointer
      cMappers: uint32
      aphMappers: pointer
      cSupportedAlgs: uint32
      palgSupportedAlgs: pointer
      grbitEnabledProtocols, dwMinimumCipherStrength, dwMaximumCipherStrength,
        dwSessionLifespan, dwFlags, dwCredFormat: uint32
    StreamSizes = object
      cbHeader, cbTrailer, cbMaximumMessage, cBuffers, cbBlockSize: uint32
    TimeStamp = object
      low, high: uint32

type
  NetError* = object of IOError
    ## The connection could not be made, or broke: the message says why.
  Security* = enum
    ## How a mail account's server encrypts (what the protocols' ports mean).
    secTls = "tls"            ## TLS from the start (IMAP 993, SMTP 465)
    secStartTls = "starttls"  ## plain first, then STARTTLS (IMAP 143, SMTP 587)
    secNone = "none"          ## not at all (a test server on this computer)

  NetConn* = ref object
    ## An open connection (`netOpen`).
    host*: string
    port*: int
    timeoutMs*: int          ## the longest a read or a write waits
    encrypted*: bool         ## TLS now
    insecure: bool
    buf: string              ## what was read and not taken yet
    pos: int
    closed: bool
    when androidApp:
      handle: string
    elif defined(wasm):
      discard
    else:
      sock: Socket
      when defined(windows):
        cred, ctx: SecHandle
        haveCtx: bool
        sizes: StreamSizes
        raw: string          ## encrypted bytes not decrypted yet
      elif defined(macosx) or defined(ios):
        st: pointer          ## the SSLContextRef
      else:
        ssl: pointer

proc fail(msg: string) {.noreturn.} = raise newException(NetError, msg)

# ---- Windows: SChannel ---------------------------------------------------------------------------

when defined(windows) and not defined(wasm):
  {.push stdcall, dynlib: "secur32.dll".}
  proc AcquireCredentialsHandleW(principal, package: WideCString; credentialUse: uint32;
                                 logonId, authData, getKeyFn, getKeyArg: pointer;
                                 cred: ptr SecHandle; expiry: ptr TimeStamp): int32 {.importc.}
  proc InitializeSecurityContextW(cred, ctx: ptr SecHandle; target: WideCString;
                                  req, reserved1, rep: uint32; input: ptr SecBufferDesc;
                                  reserved2: uint32; newCtx: ptr SecHandle;
                                  output: ptr SecBufferDesc; attrs: ptr uint32;
                                  expiry: ptr TimeStamp): int32 {.importc.}
  proc DeleteSecurityContext(ctx: ptr SecHandle): int32 {.importc.}
  proc FreeCredentialsHandle(cred: ptr SecHandle): int32 {.importc.}
  proc FreeContextBuffer(p: pointer): int32 {.importc.}
  proc QueryContextAttributesW(ctx: ptr SecHandle; attr: uint32; buf: pointer): int32 {.importc.}
  proc EncryptMessage(ctx: ptr SecHandle; qop: uint32; msg: ptr SecBufferDesc; seq: uint32): int32 {.importc.}
  proc DecryptMessage(ctx: ptr SecHandle; msg: ptr SecBufferDesc; seq: uint32; qop: ptr uint32): int32 {.importc.}
  {.pop.}

  const
    SecbufferEmpty = 0'u32
    SecbufferData = 1'u32
    SecbufferToken = 2'u32
    SecbufferExtra = 5'u32
    SecbufferStreamTrailer = 6'u32
    SecbufferStreamHeader = 7'u32
    SecbufferAlert = 17'u32
    IscFlags = 0x4'u32 or 0x8 or 0x10 or 0x100 or 0x4000 or 0x8000
      ## (replay and sequence detection, confidentiality, allocated output,
      ## extended errors, a stream)
    SecIContinueNeeded = 0x00090312'i32
    SecIIncompleteCredentials = 0x00090320'i32
    SecIContextExpired = 0x00090317'i32
    SecIRenegotiate = 0x00090321'i32
    SecEIncompleteMessage = cast[int32](0x80090318'u32)

  proc schannelWhy(code: int32): string =
    case cast[uint32](code)
    of 0x80090325'u32: "the server's certificate is not from an authority this computer trusts"
    of 0x80090322'u32: "the server's certificate is for another name"
    of 0x80090328'u32: "the server's certificate has expired"
    of 0x80090327'u32, 0x80090326'u32: "the server and this computer found no TLS they both speak"
    of 0x80090331'u32: "the server and this computer found no TLS they both speak (an old server?)"
    of 0x8009030E'u32: "TLS has no credentials"
    else: "TLS failed (0x" & toHex(cast[uint32](code), 8) & ")"

# ---- macOS, iOS: Secure Transport ---------------------------------------------------------------

when (defined(macosx) or defined(ios)) and not defined(wasm):
  {.passL: "-framework Security -framework CoreFoundation".}
  type
    SslReadFn = proc (conn: pointer; data: pointer; len: ptr csize_t): int32 {.cdecl.}
    SslWriteFn = proc (conn: pointer; data: pointer; len: ptr csize_t): int32 {.cdecl.}
  proc SSLCreateContext(alloc: pointer; side, kind: cint): pointer {.importc, cdecl.}
  proc SSLSetIOFuncs(ctx: pointer; r: SslReadFn; w: SslWriteFn): int32 {.importc, cdecl.}
  proc SSLSetConnection(ctx: pointer; conn: pointer): int32 {.importc, cdecl.}
  proc SSLSetPeerDomainName(ctx: pointer; name: cstring; len: csize_t): int32 {.importc, cdecl.}
  proc SSLSetSessionOption(ctx: pointer; option: cint; value: uint8): int32 {.importc, cdecl.}
  proc SSLHandshake(ctx: pointer): int32 {.importc, cdecl.}
  proc SSLWrite(ctx: pointer; data: pointer; len: csize_t; done: ptr csize_t): int32 {.importc, cdecl.}
  proc SSLRead(ctx: pointer; data: pointer; len: csize_t; done: ptr csize_t): int32 {.importc, cdecl.}
  proc SSLClose(ctx: pointer): int32 {.importc, cdecl.}
  proc CFRelease(p: pointer) {.importc, cdecl.}
  const
    errSSLWouldBlock = -9803'i32
    errSSLClosedGraceful = -9805'i32
    errSSLClosedAbort = -9806'i32
    errSSLClosedNoNotify = -9816'i32
    errSSLPeerAuthCompleted = -9841'i32
    errSSLXCertChainInvalid = -9807'i32
    errSSLBadCert = -9808'i32
    errSSLHostNameMismatch = -9843'i32
    errSSLCertExpired = -9814'i32

  proc stWhy(code: int32): string =
    case code
    of errSSLXCertChainInvalid, errSSLBadCert, -9812'i32:   # (-9812: unknown root)
      "the server's certificate is not from an authority this computer trusts"
    of errSSLHostNameMismatch: "the server's certificate is for another name"
    of errSSLCertExpired: "the server's certificate has expired"
    of errSSLClosedAbort, errSSLClosedNoNotify, errSSLClosedGraceful: "the server closed the connection"
    else: "TLS failed (" & $code & ")"

  proc stRead(conn: pointer; data: pointer; len: ptr csize_t): int32 {.cdecl.} =
    ## (Secure Transport asks for `len` bytes: as many as came, would-block
    ## for fewer -- the socket's own timeout ends a wait)
    let fd = cint(cast[int](conn))
    let want = int(len[])
    var got = 0
    while got < want:
      let n = posix.recv(SocketHandle(fd), cast[pointer](cast[uint](data) + uint(got)), want - got, 0)
      if n > 0: got += n
      elif n == 0:
        len[] = csize_t(got)
        return errSSLClosedNoNotify
      else:
        if errno == EINTR: continue
        len[] = csize_t(got)
        return errSSLWouldBlock
    len[] = csize_t(got)
    0

  proc stWrite(conn: pointer; data: pointer; len: ptr csize_t): int32 {.cdecl.} =
    let fd = cint(cast[int](conn))
    let want = int(len[])
    var put = 0
    while put < want:
      let n = posix.send(SocketHandle(fd), cast[pointer](cast[uint](data) + uint(put)), want - put, 0)
      if n > 0: put += n
      else:
        if n < 0 and errno == EINTR: continue
        len[] = csize_t(put)
        return (if n == 0: errSSLClosedNoNotify else: errSSLWouldBlock)
    len[] = csize_t(put)
    0

# ---- Linux, the BSDs, Termux: OpenSSL, loaded when needed -----------------------------------------

when not (defined(windows) or defined(macosx) or defined(ios) or defined(wasm) or androidApp):
  type
    Ossl = object
      ok: bool
      why: string
      initSsl: proc (opts: uint64; settings: pointer): cint {.cdecl, gcsafe.}
      clientMethod: proc (): pointer {.cdecl, gcsafe.}
      ctxNew: proc (m: pointer): pointer {.cdecl, gcsafe.}
      ctxFree: proc (c: pointer) {.cdecl, gcsafe.}
      defaultPaths: proc (c: pointer): cint {.cdecl, gcsafe.}
      loadLocations: proc (c: pointer; file, dir: cstring): cint {.cdecl, gcsafe.}
      setVerify: proc (c: pointer; mode: cint; cb: pointer) {.cdecl, gcsafe.}
      sslNew: proc (c: pointer): pointer {.cdecl, gcsafe.}
      sslFree: proc (s: pointer) {.cdecl, gcsafe.}
      setFd: proc (s: pointer; fd: cint): cint {.cdecl, gcsafe.}
      ctrl: proc (s: pointer; cmd: cint; larg: clong; parg: pointer): clong {.cdecl, gcsafe.}
      set1Host: proc (s: pointer; host: cstring): cint {.cdecl, gcsafe.}
      connect: proc (s: pointer): cint {.cdecl, gcsafe.}
      getError: proc (s: pointer; ret: cint): cint {.cdecl, gcsafe.}
      read: proc (s: pointer; buf: pointer; n: cint): cint {.cdecl, gcsafe.}
      write: proc (s: pointer; buf: pointer; n: cint): cint {.cdecl, gcsafe.}
      pending: proc (s: pointer): cint {.cdecl, gcsafe.}
      shutdown: proc (s: pointer): cint {.cdecl, gcsafe.}
      verifyResult: proc (s: pointer): clong {.cdecl, gcsafe.}
      verifyText: proc (code: clong): cstring {.cdecl, gcsafe.}
      errGet: proc (): culong {.cdecl, gcsafe.}
      errText: proc (e: culong; buf: cstring; n: csize_t) {.cdecl, gcsafe.}
      ctx, ctxInsecure: pointer

  var ossl: Ossl
  var osslTried = false

  proc caFile(): string =
    ## (Termux and some systems keep the authorities where OpenSSL's
    ## default does not look)
    for f in [getEnv("SSL_CERT_FILE"), getEnv("PREFIX") / "etc/tls/cert.pem",
              "/data/data/com.termux/files/usr/etc/tls/cert.pem",
              "/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt",
              "/etc/ssl/cert.pem", "/usr/local/share/certs/ca-root-nss.crt"]:
      if f.len > 0 and fileExists(f): return f
    ""

  proc loadOpenSsl(): bool =
    if osslTried: return ossl.ok
    osslTried = true
    var lib: LibHandle = nil
    for name in ["libssl.so.3", "libssl.so.1.1", "libssl.so",
                 getEnv("PREFIX") / "lib/libssl.so.3", getEnv("PREFIX") / "lib/libssl.so",
                 "libssl.so.111", "libssl.so.30"]:
      if name.len == 0 or name.startsWith("/lib"): continue
      lib = loadLib(name)
      if lib != nil: break
    if lib == nil:
      ossl.why = "TLS needs OpenSSL (libssl 3 or 1.1), and this system has none " &
                 "(on Termux: pkg install openssl)"
      return false
    template sym(field, name: untyped) =
      ossl.field = cast[typeof(ossl.field)](symAddr(lib, name))
    sym(initSsl, "OPENSSL_init_ssl")
    sym(clientMethod, "TLS_client_method")
    sym(ctxNew, "SSL_CTX_new")
    sym(ctxFree, "SSL_CTX_free")
    sym(defaultPaths, "SSL_CTX_set_default_verify_paths")
    sym(loadLocations, "SSL_CTX_load_verify_locations")
    sym(setVerify, "SSL_CTX_set_verify")
    sym(sslNew, "SSL_new")
    sym(sslFree, "SSL_free")
    sym(setFd, "SSL_set_fd")
    sym(ctrl, "SSL_ctrl")
    sym(set1Host, "SSL_set1_host")
    sym(connect, "SSL_connect")
    sym(getError, "SSL_get_error")
    sym(read, "SSL_read")
    sym(write, "SSL_write")
    sym(pending, "SSL_pending")
    sym(shutdown, "SSL_shutdown")
    sym(verifyResult, "SSL_get_verify_result")
    sym(verifyText, "X509_verify_cert_error_string")
    sym(errGet, "ERR_get_error")
    sym(errText, "ERR_error_string_n")
    if ossl.clientMethod == nil or ossl.ctxNew == nil or ossl.sslNew == nil or ossl.connect == nil or
       ossl.read == nil or ossl.write == nil or ossl.setFd == nil or ossl.getError == nil:
      ossl.why = "this OpenSSL is too old (1.1 or later is needed)"
      return false
    if ossl.initSsl != nil: discard ossl.initSsl(0, nil)
    for insecure in [false, true]:
      let c = ossl.ctxNew(ossl.clientMethod())
      if c == nil:
        ossl.why = "OpenSSL could not start"
        return false
      if not insecure:
        if ossl.defaultPaths != nil: discard ossl.defaultPaths(c)
        let f = caFile()
        if f.len > 0 and ossl.loadLocations != nil: discard ossl.loadLocations(c, f.cstring, nil)
        ossl.setVerify(c, 1, nil)                   # (SSL_VERIFY_PEER)
        ossl.ctx = c
      else:
        ossl.setVerify(c, 0, nil)
        ossl.ctxInsecure = c
    ossl.ok = true
    true

  proc osslWhy(): string =
    if ossl.errGet != nil and ossl.errText != nil:
      let e = ossl.errGet()
      if e != 0:
        var b = newString(256)
        ossl.errText(e, b.cstring, 256)
        return $b.cstring
    ""

# ---- opening ------------------------------------------------------------------------------------

proc tlsWhyNot*(): string =
  ## "" when TLS works here; else why not (no OpenSSL, a web page).
  when defined(wasm): "a web page has no connections of its own"
  elif androidApp or defined(windows) or defined(macosx) or defined(ios): ""
  else:
    {.cast(gcsafe).}:
      if loadOpenSsl(): "" else: ossl.why

when not (defined(wasm) or androidApp):
  proc setTimeouts(c: NetConn) =
    ## (every read and write on the socket waits at most the timeout)
    let fd = c.sock.getFd
    when defined(windows):
      var ms = int32(c.timeoutMs)
      discard winlean.setsockopt(winlean.SocketHandle(fd), winlean.SOL_SOCKET, 0x1006,  # SO_RCVTIMEO
                                 addr ms, sizeof(ms).SockLen)
      discard winlean.setsockopt(winlean.SocketHandle(fd), winlean.SOL_SOCKET, 0x1005,  # SO_SNDTIMEO
                                 addr ms, sizeof(ms).SockLen)
    else:
      var tv = Timeval(tv_sec: posix.Time(c.timeoutMs div 1000),
                       tv_usec: Suseconds((c.timeoutMs mod 1000) * 1000))
      discard posix.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, addr tv, sizeof(tv).SockLen)
      discard posix.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, addr tv, sizeof(tv).SockLen)

  proc sysSend(c: NetConn; p: pointer; n: int): int =
    when defined(windows): int(winlean.send(winlean.SocketHandle(c.sock.getFd), p, cint(n), 0))
    else: posix.send(c.sock.getFd, p, n, 0'i32)

  proc sysRecv(c: NetConn; p: pointer; n: int): int =
    when defined(windows): int(winlean.recv(winlean.SocketHandle(c.sock.getFd), p, cint(n), 0))
    else: posix.recv(c.sock.getFd, p, n, 0'i32)

  proc rawSend(c: NetConn; data: string) =
    if data.len == 0: return
    var at = 0
    while at < data.len:
      let n = c.sysSend(unsafeAddr data[at], data.len - at)
      if n <= 0:
        when not defined(windows):
          if n < 0 and errno == EINTR: continue
        fail("the connection to " & c.host & " broke (sending)")
      at += n

  proc rawRecv(c: NetConn; max = 16384): string =
    ## Some bytes (at least one); "" when the server closed it.
    result = newString(max)
    while true:
      let n = c.sysRecv(addr result[0], max)
      if n > 0:
        result.setLen(n)
        return
      if n == 0:
        result.setLen(0)
        return
      when not defined(windows):
        if errno == EINTR: continue
        if errno == EAGAIN or errno == EWOULDBLOCK:
          fail(c.host & " did not answer in " & $(c.timeoutMs div 1000) & " s")
      else:
        if winlean.wsaGetLastError() == 10060:          # WSAETIMEDOUT
          fail(c.host & " did not answer in " & $(c.timeoutMs div 1000) & " s")
      fail("the connection to " & c.host & " broke")

  proc dialTcp(c: NetConn) =
    ## (IPv4 first, then IPv6: a mail server has both or the first)
    var last = ""
    for dom in [AF_INET, AF_INET6]:
      var s = newSocket(dom, SOCK_STREAM, IPPROTO_TCP, buffered = false)
      try:
        s.connect(c.host, Port(c.port), timeout = c.timeoutMs)
        c.sock = s
        c.setTimeouts()
        # (a write to a connection the server closed must not end the
        # program: SIGPIPE ignored -- OpenSSL writes with write() -- and on
        # a Mac the socket told not to raise it)
        when defined(macosx) or defined(ios):
          var one: cint = 1
          discard posix.setsockopt(s.getFd, SOL_SOCKET, cint(0x1022), addr one, sizeof(one).SockLen)
        elif not defined(windows):
          discard posix.signal(SIGPIPE, SIG_IGN)
        return
      except CatchableError as e:
        last = e.msg
        try: s.close() except CatchableError: discard
    if "timed out" in last.toLowerAscii or "timeout" in last.toLowerAscii:
      fail(c.host & " did not answer (port " & $c.port & ")")
    fail("could not reach " & c.host & ":" & $c.port & (if last.len > 0: " (" & last & ")" else: ""))

proc handshake(c: NetConn)

proc startTls*(c: NetConn) =
  ## Encrypts the connection from here (after the protocol's STARTTLS was
  ## answered): the certificate is checked for `c.host`. Raises `NetError`.
  if c.encrypted: return
  if c.pos < c.buf.len:
    fail("the server sent more than its answer to STARTTLS")
  c.buf.setLen(0)
  c.pos = 0
  c.handshake()
  c.encrypted = true

proc handshake(c: NetConn) =
  ## (the system's TLS begins on the connection)
  when defined(wasm):
    fail("a web page has no connections of its own")
  elif androidApp:
    let r = systemCall("net.tls.start", [c.handle, c.host, (if c.insecure: "1" else: "0")].join("\t"))
    if r == "\0": fail("this app has no TLS (its Java part is missing)")
    if r.startsWith("e"): fail(r[1 .. ^1])
  elif defined(windows):
    var cred = SchannelCred(dwVersion: 4,                      # SCHANNEL_CRED_VERSION
                            dwFlags: 0x10'u32 or 0x400000'u32 or  # no default creds, strong crypto
                                     (if c.insecure: 0x8'u32 else: 0x20'u32))  # manual / auto validation
    var exp: TimeStamp
    var r = AcquireCredentialsHandleW(nil, newWideCString("Microsoft Unified Security Protocol Provider"),
                                      2, nil, addr cred, nil, nil, addr c.cred, addr exp)
    if r != 0: fail(schannelWhy(r))
    let target = newWideCString(c.host)
    var outBuf = SecBuffer(bufferType: SecbufferToken)
    var outDesc = SecBufferDesc(ulVersion: 0, cBuffers: 1, pBuffers: addr outBuf)
    var attrs: uint32
    r = InitializeSecurityContextW(addr c.cred, nil, target, IscFlags, 0, 0, nil, 0, addr c.ctx,
                                   addr outDesc, addr attrs, addr exp)
    if r != SecIContinueNeeded: fail(schannelWhy(r))
    c.haveCtx = true
    proc sendToken(c: NetConn; b: var SecBuffer) =
      if b.cbBuffer > 0 and b.pvBuffer != nil:
        var s = newString(int(b.cbBuffer))
        copyMem(addr s[0], b.pvBuffer, s.len)
        discard FreeContextBuffer(b.pvBuffer)
        b.pvBuffer = nil
        c.rawSend(s)
    sendToken(c, outBuf)
    var data = ""
    var need = true
    while true:
      if need:
        let more = c.rawRecv()
        if more.len == 0: fail(c.host & " closed the connection during TLS")
        data.add more
      var ins = [SecBuffer(cbBuffer: uint32(data.len), bufferType: SecbufferToken,
                           pvBuffer: (if data.len > 0: addr data[0] else: nil)),
                 SecBuffer(bufferType: SecbufferEmpty)]
      var inDesc = SecBufferDesc(ulVersion: 0, cBuffers: 2, pBuffers: addr ins[0])
      var outs = [SecBuffer(bufferType: SecbufferToken), SecBuffer(bufferType: SecbufferAlert)]
      outDesc = SecBufferDesc(ulVersion: 0, cBuffers: 2, pBuffers: addr outs[0])
      r = InitializeSecurityContextW(addr c.cred, addr c.ctx, target, IscFlags, 0, 0, addr inDesc, 0,
                                     nil, addr outDesc, addr attrs, addr exp)
      if r == SecEIncompleteMessage:
        need = true
        continue
      sendToken(c, outs[0])
      if outs[1].pvBuffer != nil: discard FreeContextBuffer(outs[1].pvBuffer)
      if r == 0 or r == SecIContinueNeeded or r == SecIIncompleteCredentials:
        if ins[1].bufferType == SecbufferExtra and ins[1].cbBuffer > 0:
          data = data[data.len - int(ins[1].cbBuffer) .. ^1]
          need = false
        else:
          data.setLen(0)
          need = true
        if r == 0: break
        continue
      fail(schannelWhy(r))
    c.raw = data                                       # (the start of the data, if any)
    r = QueryContextAttributesW(addr c.ctx, 4, addr c.sizes)   # SECPKG_ATTR_STREAM_SIZES
    if r != 0: fail(schannelWhy(r))
  elif defined(macosx) or defined(ios):
    let st = SSLCreateContext(nil, 1, 0)                 # (the client side, a stream)
    if st == nil: fail("TLS could not start")
    c.st = st
    discard SSLSetIOFuncs(st, stRead, stWrite)
    discard SSLSetConnection(st, cast[pointer](int(c.sock.getFd)))
    discard SSLSetPeerDomainName(st, c.host.cstring, csize_t(c.host.len))
    if c.insecure: discard SSLSetSessionOption(st, 0, 1)   # (break on server auth: not checked)
    while true:
      let r = SSLHandshake(st)
      if r == 0: break
      if r == errSSLPeerAuthCompleted and c.insecure: continue
      if r == errSSLWouldBlock:
        fail(c.host & " did not answer in " & $(c.timeoutMs div 1000) & " s")
      fail(stWhy(r))
  else:
    {.cast(gcsafe).}:
      if not loadOpenSsl(): fail(ossl.why)
      let s = ossl.sslNew(if c.insecure: ossl.ctxInsecure else: ossl.ctx)
      if s == nil: fail("OpenSSL could not start: " & osslWhy())
      c.ssl = s
      discard ossl.setFd(s, cint(c.sock.getFd))
      discard ossl.ctrl(s, 55, 0, c.host.cstring)        # (SNI: SSL_CTRL_SET_TLSEXT_HOSTNAME)
      if not c.insecure and ossl.set1Host != nil: discard ossl.set1Host(s, c.host.cstring)
      let r = ossl.connect(s)
      if r != 1:
        let v = if ossl.verifyResult != nil: ossl.verifyResult(s) else: 0
        if v != 0 and not c.insecure:
          let t = if ossl.verifyText != nil: $ossl.verifyText(v) else: "code " & $v
          fail("the server's certificate was not accepted: " & t)
        let e = ossl.getError(s, r)
        if e == 2 or e == 3:                              # (want read / write: the timeout)
          fail(c.host & " did not answer in " & $(c.timeoutMs div 1000) & " s")
        let why = osslWhy()
        fail("TLS failed" & (if why.len > 0: ": " & why else: ""))

proc close*(c: NetConn)

proc netOpen*(host: string; port: int; tls = false; timeoutSec = 30;
              insecure = false): NetConn =
  ## Connects to `host`:`port`, encrypted from the start when `tls`
  ## (else plain: `startTls` later). Raises `NetError` with why it could
  ## not (no answer, a certificate not trusted...).
  result = NetConn(host: host, port: port, timeoutMs: max(1000, timeoutSec * 1000),
                   insecure: insecure)
  when defined(wasm):
    fail("a web page has no connections of its own")
  elif androidApp:
    let r = systemCall("net.tls.open", [host, $port, (if tls: "1" else: "0"),
                                        (if insecure: "1" else: "0"), $result.timeoutMs].join("\t"))
    if r == "\0": fail("this app has no connections (its Java part is missing)")
    if r.startsWith("e"): fail(r[1 .. ^1])
    result.handle = r[1 .. ^1]
    result.encrypted = tls
  else:
    result.dialTcp()
    if tls:
      try: result.startTls()
      except NetError:
        result.close()            # (the TLS state too: OpenSSL's SSL was never freed)
        raise

proc openSecured*(host: string; port: int; security: Security; timeoutSec = 30;
                  insecure = false): NetConn =
  ## `netOpen` for a `Security`: `secTls` encrypted at once, the others
  ## plain (the protocol says STARTTLS, then `startTls`).
  netOpen(host, port, security == secTls, timeoutSec, insecure)

# ---- writing, reading ---------------------------------------------------------------------------

proc write*(c: NetConn; data: string) =
  ## Sends `data` (all of it). Raises `NetError` when the connection broke.
  if c.closed: fail("the connection is closed")
  if data.len == 0: return
  when defined(wasm):
    discard
  elif androidApp:
    let r = systemCall("net.tls.write", c.handle & "\t" & encode(data))
    if r != "1": fail(if r.startsWith("e"): r[1 .. ^1] else: "the connection broke (sending)")
  elif defined(windows):
    if not c.encrypted:
      c.rawSend(data)
      return
    var at = 0
    let most = max(1, int(c.sizes.cbMaximumMessage))
    while at < data.len:
      let n = min(most, data.len - at)
      var msg = newString(int(c.sizes.cbHeader) + n + int(c.sizes.cbTrailer))
      copyMem(addr msg[int(c.sizes.cbHeader)], unsafeAddr data[at], n)
      var bufs = [SecBuffer(cbBuffer: c.sizes.cbHeader, bufferType: SecbufferStreamHeader,
                            pvBuffer: addr msg[0]),
                  SecBuffer(cbBuffer: uint32(n), bufferType: SecbufferData,
                            pvBuffer: addr msg[int(c.sizes.cbHeader)]),
                  SecBuffer(cbBuffer: c.sizes.cbTrailer, bufferType: SecbufferStreamTrailer,
                            pvBuffer: addr msg[int(c.sizes.cbHeader) + n]),
                  SecBuffer(bufferType: SecbufferEmpty)]
      var desc = SecBufferDesc(ulVersion: 0, cBuffers: 4, pBuffers: addr bufs[0])
      let r = EncryptMessage(addr c.ctx, 0, addr desc, 0)
      if r != 0: fail(schannelWhy(r))
      msg.setLen(int(bufs[0].cbBuffer + bufs[1].cbBuffer + bufs[2].cbBuffer))
      c.rawSend(msg)
      at += n
  elif defined(macosx) or defined(ios):
    if not c.encrypted:
      c.rawSend(data)
      return
    var at = 0
    while at < data.len:
      var done: csize_t
      let r = SSLWrite(c.st, unsafeAddr data[at], csize_t(data.len - at), addr done)
      at += int(done)
      if r != 0 and r != errSSLWouldBlock: fail(stWhy(r))
      if r == errSSLWouldBlock and done == 0:
        fail(c.host & " did not take the data in " & $(c.timeoutMs div 1000) & " s")
  else:
    if not c.encrypted:
      c.rawSend(data)
      return
    {.cast(gcsafe).}:
      var at = 0
      while at < data.len:
        let r = ossl.write(c.ssl, unsafeAddr data[at], cint(min(data.len - at, 1 shl 20)))
        if r <= 0:
          let e = ossl.getError(c.ssl, r)
          if e == 2 or e == 3: fail(c.host & " did not take the data in " & $(c.timeoutMs div 1000) & " s")
          fail("the connection to " & c.host & " broke (sending)")
        at += r

proc fillSome(c: NetConn): bool =
  ## Reads what came into the buffer: false when the server closed it.
  if c.pos > 0 and c.pos >= c.buf.len:
    c.buf.setLen(0)
    c.pos = 0
  elif c.pos > 65536:
    c.buf = c.buf[c.pos .. ^1]
    c.pos = 0
  when defined(wasm):
    false
  elif androidApp:
    let r = systemCall("net.tls.read", c.handle & "\t65536")
    if r == "\0" or r.len == 0: fail("the connection broke")
    case r[0]
    of 'd':
      c.buf.add decode(r[1 .. ^1])
      true
    of 'c': false
    of 't': fail(c.host & " did not answer in " & $(c.timeoutMs div 1000) & " s")
    else: fail(r[1 .. ^1])
  elif defined(windows):
    if not c.encrypted:
      let s = c.rawRecv()
      c.buf.add s
      return s.len > 0
    while true:
      if c.raw.len > 0:
        var bufs = [SecBuffer(cbBuffer: uint32(c.raw.len), bufferType: SecbufferData,
                              pvBuffer: addr c.raw[0]),
                    SecBuffer(bufferType: SecbufferEmpty), SecBuffer(bufferType: SecbufferEmpty),
                    SecBuffer(bufferType: SecbufferEmpty)]
        var desc = SecBufferDesc(ulVersion: 0, cBuffers: 4, pBuffers: addr bufs[0])
        let r = DecryptMessage(addr c.ctx, addr desc, 0, nil)
        if r == 0 or r == SecIRenegotiate:
          var extra = ""
          var got = false
          for b in bufs:
            if b.bufferType == SecbufferData and b.cbBuffer > 0:
              let k = c.buf.len
              c.buf.setLen(k + int(b.cbBuffer))
              copyMem(addr c.buf[k], b.pvBuffer, int(b.cbBuffer))
              got = true
            elif b.bufferType == SecbufferExtra and b.cbBuffer > 0:
              extra = c.raw[c.raw.len - int(b.cbBuffer) .. ^1]
          c.raw = extra
          if r == SecIRenegotiate:
            # (TLS 1.3 after the handshake: a session ticket, given back to SChannel)
            var ins = [SecBuffer(cbBuffer: uint32(c.raw.len), bufferType: SecbufferToken,
                                 pvBuffer: (if c.raw.len > 0: addr c.raw[0] else: nil)),
                       SecBuffer(bufferType: SecbufferEmpty)]
            var inDesc = SecBufferDesc(ulVersion: 0, cBuffers: 2, pBuffers: addr ins[0])
            var outs = [SecBuffer(bufferType: SecbufferToken)]
            var outDesc = SecBufferDesc(ulVersion: 0, cBuffers: 1, pBuffers: addr outs[0])
            var attrs: uint32
            var exp: TimeStamp
            let target = newWideCString(c.host)
            discard InitializeSecurityContextW(addr c.cred, addr c.ctx, target, IscFlags, 0, 0,
                                               addr inDesc, 0, nil, addr outDesc, addr attrs, addr exp)
            if outs[0].cbBuffer > 0 and outs[0].pvBuffer != nil:
              var s = newString(int(outs[0].cbBuffer))
              copyMem(addr s[0], outs[0].pvBuffer, s.len)
              discard FreeContextBuffer(outs[0].pvBuffer)
              c.rawSend(s)
            if ins[1].bufferType == SecbufferExtra and ins[1].cbBuffer > 0:
              c.raw = c.raw[c.raw.len - int(ins[1].cbBuffer) .. ^1]
            else: c.raw.setLen(0)
          if got: return true
          if c.raw.len > 0: continue
        elif r == SecIContextExpired:
          return false
        elif r != SecEIncompleteMessage:
          fail(schannelWhy(r))
      let more = c.rawRecv()
      if more.len == 0: return false
      c.raw.add more
  elif defined(macosx) or defined(ios):
    if not c.encrypted:
      let s = c.rawRecv()
      c.buf.add s
      return s.len > 0
    var b = newString(16384)
    var done: csize_t
    let r = SSLRead(c.st, addr b[0], csize_t(b.len), addr done)
    if done > 0:
      b.setLen(int(done))
      c.buf.add b
      return true
    if r == errSSLClosedGraceful or r == errSSLClosedNoNotify: return false
    if r == errSSLWouldBlock: fail(c.host & " did not answer in " & $(c.timeoutMs div 1000) & " s")
    fail(stWhy(r))
  else:
    if not c.encrypted:
      let s = c.rawRecv()
      c.buf.add s
      return s.len > 0
    {.cast(gcsafe).}:
      var b = newString(16384)
      while true:
        let r = ossl.read(c.ssl, addr b[0], cint(b.len))
        if r > 0:
          b.setLen(r)
          c.buf.add b
          return true
        let e = ossl.getError(c.ssl, r)
        case e
        of 6: return false                                # (SSL_ERROR_ZERO_RETURN: closed)
        of 2, 3: fail(c.host & " did not answer in " & $(c.timeoutMs div 1000) & " s")
        of 5:                                             # (SSL_ERROR_SYSCALL)
          if errno == EINTR: continue
          if errno == EAGAIN or errno == EWOULDBLOCK:
            fail(c.host & " did not answer in " & $(c.timeoutMs div 1000) & " s")
          return false
        else:
          let why = osslWhy()
          fail("the connection to " & c.host & " broke" & (if why.len > 0: ": " & why else: ""))

proc readLine*(c: NetConn): string =
  ## The next line, without its CR LF. Raises `NetError` when the server
  ## closed the connection first, or did not answer in the timeout.
  while true:
    let nl = c.buf.find('\n', c.pos)
    if nl >= 0:
      result = c.buf[c.pos ..< nl]
      if result.len > 0 and result[^1] == '\r': result.setLen(result.len - 1)
      c.pos = nl + 1
      return
    if not c.fillSome():
      if c.pos < c.buf.len:
        result = c.buf[c.pos .. ^1]
        c.pos = c.buf.len
        return
      fail(c.host & " closed the connection")

proc readBytes*(c: NetConn; n: int): string =
  ## Exactly `n` bytes (an IMAP literal). Raises `NetError` as `readLine`.
  while c.buf.len - c.pos < n:
    if not c.fillSome(): fail(c.host & " closed the connection")
  result = c.buf[c.pos ..< c.pos + n]
  c.pos += n

proc close*(c: NetConn) =
  ## Ends the connection (politely, as TLS says).
  if c == nil or c.closed: return
  c.closed = true
  when defined(wasm):
    discard
  elif androidApp:
    discard systemCall("net.tls.close", c.handle)
  else:
    when defined(windows):
      if c.haveCtx:
        discard DeleteSecurityContext(addr c.ctx)
        discard FreeCredentialsHandle(addr c.cred)
    elif defined(macosx) or defined(ios):
      if c.st != nil:
        discard SSLClose(c.st)
        CFRelease(c.st)
        c.st = nil
    else:
      {.cast(gcsafe).}:
        if c.ssl != nil:
          discard ossl.shutdown(c.ssl)
          ossl.sslFree(c.ssl)
          c.ssl = nil
    try: c.sock.close() except CatchableError: discard
