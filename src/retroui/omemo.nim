## OMEMO: end-to-end encryption for `retroui/xmpp`'s messages, as
## Conversations, Monal, Gajim, Dino and Siskin do it -- OMEMO 0.3
## ("eu.siacs.conversations.axolotl", the one every one of them speaks),
## the Signal protocol underneath: each device has its own keys; a
## message is locked once with a new key, and that key is locked for each
## device of the one you write to (and your own other devices) through a
## session with it -- X3DH to begin it from the keys the device published,
## then the double ratchet, a new key for every message. The server sees
## who writes to whom, and when; never the words.
##
## The keys of this device, its sessions and the devices seen are kept in
## one file (`omemoOpen`), readable by you alone. Trust is "blind trust
## before verification", as Conversations does it: a contact's devices are
## trusted as they come until you verify one of theirs (compare the
## fingerprints, `omemoFingerprint`, side by side); after that only the
## verified ones get your messages.
##
## .. code-block:: nim
##   import retroui, retroui/[xmpp, omemo]
##   let o = omemoOpen(dataDir("chat"), "me@yax.im")
##   xmppStart("me@yax.im", "my password")
##   app "Chat", 400, 300:
##     for e in xmppEvents():
##       if o.omemoHandle(e): continue          # (its own answers)
##       if e.kind == xeOnline: o.omemoStart()
##       if e.kind == xeMessage and isEncrypted(e):
##         let (ok, text, _) = o.omemoDecrypt(e)
##         if ok: echo e.jid, ": ", text
##     if button("Hello"): discard o.omemoSend("friend@xmpp.jp", "Hello!")
##     for n in o.omemoNotes(): echo n       # (sent, could not send, devices)
##     if xmppRunning(): wakeIn(250)
##
## The cryptography is OpenSSL's (libcrypto 1.1.1 or later, loaded when it
## is first needed; `omemoAvailable` says whether it is there): X25519,
## Ed25519, AES-256-CBC, AES-128-GCM; SHA-256 and HMAC are Retro Nim UI's.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, base64, json, tables, os, times, xmlparser, xmltree, dynlib, sysrand, algorithm, random, sequtils]
from std/openssl import DLLUtilName
import sha2, xmpp
from codec import unbase64

const
  Ns* = "eu.siacs.conversations.axolotl"
    ## OMEMO 0.3's namespace
  NodeList = Ns & ".devicelist"
  NodeBundle = Ns & ".bundles:"
  PreKeys = 100                ## one-time keys published (the spec's at least 20)
  Fallback* = "I sent you an OMEMO encrypted message but your client doesn't seem to support that. " &
              "Find more information on https://conversations.im/omemo"
    ## the body that apps without OMEMO show
  MaxSkip = 2000               ## message keys kept for messages that come late, per chain
  MaxChains = 5                ## the other side's chains kept
  MaxOldStates = 5             ## earlier sessions with a device kept (its messages in flight)

# ---- libcrypto, loaded when first needed --------------------------------------------------------

type
  Pk = pointer
  NewRawKey = proc (typ: cint; e: pointer; key: ptr byte; keylen: csize_t): Pk {.cdecl, gcsafe.}
  GetRawKey = proc (p: Pk; key: ptr byte; len: ptr csize_t): cint {.cdecl, gcsafe.}
  PkFree = proc (p: Pk) {.cdecl, gcsafe.}
  CtxNew = proc (p: Pk; e: pointer): pointer {.cdecl, gcsafe.}
  CtxFree = proc (c: pointer) {.cdecl, gcsafe.}
  CtxInit = proc (c: pointer): cint {.cdecl, gcsafe.}
  CtxPeer = proc (c: pointer; peer: Pk): cint {.cdecl, gcsafe.}
  Derive = proc (c: pointer; key: ptr byte; len: ptr csize_t): cint {.cdecl, gcsafe.}
  MdNew = proc (): pointer {.cdecl, gcsafe.}
  MdFree = proc (c: pointer) {.cdecl, gcsafe.}
  SignInit = proc (c: pointer; pctx: pointer; md: pointer; e: pointer; p: Pk): cint {.cdecl, gcsafe.}
  SignIt = proc (c: pointer; sig: ptr byte; siglen: ptr csize_t; tbs: ptr byte; tbslen: csize_t): cint {.cdecl, gcsafe.}
  VerifyIt = proc (c: pointer; sig: ptr byte; siglen: csize_t; tbs: ptr byte; tbslen: csize_t): cint {.cdecl, gcsafe.}
  CipherNew = proc (): pointer {.cdecl, gcsafe.}
  CipherFree = proc (c: pointer) {.cdecl, gcsafe.}
  CipherInit = proc (c: pointer; cipher: pointer; impl: pointer; key: ptr byte; iv: ptr byte): cint {.cdecl, gcsafe.}
  CipherUpdate = proc (c: pointer; outp: ptr byte; outl: ptr cint; inp: ptr byte; inl: cint): cint {.cdecl, gcsafe.}
  CipherFinal = proc (c: pointer; outp: ptr byte; outl: ptr cint): cint {.cdecl, gcsafe.}
  CipherCtrl = proc (c: pointer; typ, arg: cint; p: pointer): cint {.cdecl, gcsafe.}
  CipherKind = proc (): pointer {.cdecl, gcsafe.}
  DigestIt = proc (data: pointer; count: csize_t; md: ptr byte; size: ptr cuint; typ: pointer; impl: pointer): cint {.cdecl, gcsafe.}

var
  cryptoLib: LibHandle
  cryptoTried = false
  pkNewPriv, pkNewPub: NewRawKey
  pkGetPub: GetRawKey
  pkFree: PkFree
  ctxNew: CtxNew
  ctxFree: CtxFree
  deriveInit: CtxInit
  derivePeer: CtxPeer
  derive: Derive
  mdNew: MdNew
  mdFree: MdFree
  signInit, verifyInit: SignInit
  signIt: SignIt
  verifyIt: VerifyIt
  cipherNew: CipherNew
  cipherFree: CipherFree
  encInit, decInit: CipherInit
  encUpdate, decUpdate: CipherUpdate
  encFinal, decFinal: CipherFinal
  cipherCtrl: CipherCtrl
  aes256cbc, aes128gcm, aes256gcm, sha512md: CipherKind
  digest: DigestIt

const
  KindX25519 = 1034.cint
  KindEd25519 = 1087.cint
  GcmSetIvLen = 0x9.cint
  GcmGetTag = 0x10.cint
  GcmSetTag = 0x11.cint

proc omemoAvailable*(): bool =
  ## Whether OpenSSL's libcrypto (1.1.1 or later) is here: OMEMO needs it.
  if cryptoTried: return cryptoLib != nil
  cryptoTried = true
  cryptoLib = loadLibPattern(DLLUtilName)
  if cryptoLib == nil: return false
  template get(v, name: untyped) =
    v = cast[typeof(v)](cryptoLib.symAddr(name))
    if v == nil:
      cryptoLib = nil
      return false
  get(pkNewPriv, "EVP_PKEY_new_raw_private_key")
  get(pkNewPub, "EVP_PKEY_new_raw_public_key")
  get(pkGetPub, "EVP_PKEY_get_raw_public_key")
  get(pkFree, "EVP_PKEY_free")
  get(ctxNew, "EVP_PKEY_CTX_new")
  get(ctxFree, "EVP_PKEY_CTX_free")
  get(deriveInit, "EVP_PKEY_derive_init")
  get(derivePeer, "EVP_PKEY_derive_set_peer")
  get(derive, "EVP_PKEY_derive")
  get(mdNew, "EVP_MD_CTX_new")
  get(mdFree, "EVP_MD_CTX_free")
  get(signInit, "EVP_DigestSignInit")
  get(verifyInit, "EVP_DigestVerifyInit")
  get(signIt, "EVP_DigestSign")
  get(verifyIt, "EVP_DigestVerify")
  get(cipherNew, "EVP_CIPHER_CTX_new")
  get(cipherFree, "EVP_CIPHER_CTX_free")
  get(encInit, "EVP_EncryptInit_ex")
  get(decInit, "EVP_DecryptInit_ex")
  get(encUpdate, "EVP_EncryptUpdate")
  get(decUpdate, "EVP_DecryptUpdate")
  get(encFinal, "EVP_EncryptFinal_ex")
  get(decFinal, "EVP_DecryptFinal_ex")
  get(cipherCtrl, "EVP_CIPHER_CTX_ctrl")
  get(aes256cbc, "EVP_aes_256_cbc")
  get(aes128gcm, "EVP_aes_128_gcm")
  get(aes256gcm, "EVP_aes_256_gcm")
  get(sha512md, "EVP_sha512")
  get(digest, "EVP_Digest")
  true

proc need() =
  if not omemoAvailable(): raise newException(IOError, "OMEMO needs OpenSSL's libcrypto (1.1.1 or later)")

template bp(s: string): ptr byte = (if s.len > 0: cast[ptr byte](unsafeAddr s[0]) else: nil)

proc randomBytes*(n: int): string =
  ## `n` bytes from the system's random source.
  let b = urandom(n)
  if b.len != n: raise newException(IOError, "no random bytes from the system")
  result = newString(n)
  for i in 0 ..< n: result[i] = char(b[i])

proc sha512(data: string): string =
  need()
  var o = newString(64)          # (a local: see aesGcmOpen)
  var n: cuint = 64
  if digest(bp(data), csize_t(data.len), bp(o), addr n, sha512md(), nil) != 1:
    raise newException(IOError, "SHA-512 failed")
  result = move o

proc rawPub(p: Pk): string =
  var o = newString(32)          # (a local: see aesGcmOpen)
  var n = csize_t(32)
  if pkGetPub(p, bp(o), addr n) != 1 or n != 32: raise newException(IOError, "no public key")
  result = move o

proc x25519Pub*(priv: string): string =
  ## The X25519 public key of a 32-byte private key.
  need()
  let p = pkNewPriv(KindX25519, nil, bp(priv), 32)
  if p == nil: raise newException(IOError, "bad private key")
  defer: pkFree(p)
  rawPub(p)

proc x25519*(priv, pub: string): string =
  ## The shared secret of our private key and their public key (32 bytes).
  need()
  if pub.len != 32 or priv.len != 32: raise newException(ValueError, "a key is not 32 bytes")
  let a = pkNewPriv(KindX25519, nil, bp(priv), 32)
  let b = pkNewPub(KindX25519, nil, bp(pub), 32)
  defer:
    if a != nil: pkFree(a)
    if b != nil: pkFree(b)
  if a == nil or b == nil: raise newException(ValueError, "bad key")
  let c = ctxNew(a, nil)
  defer: ctxFree(c)
  var o = newString(32)          # (a local: see aesGcmOpen)
  var n = csize_t(32)
  if deriveInit(c) != 1 or derivePeer(c, b) != 1 or derive(c, bp(o), addr n) != 1 or n != 32:
    raise newException(ValueError, "the key agreement failed")
  var zero = true
  for ch in o:
    if ch != '\0': zero = false
  if zero: raise newException(ValueError, "a weak key")
  result = move o

proc ed25519Pub*(seed: string): string =
  ## The Ed25519 public key of a 32-byte seed.
  need()
  let p = pkNewPriv(KindEd25519, nil, bp(seed), 32)
  if p == nil: raise newException(IOError, "bad seed")
  defer: pkFree(p)
  rawPub(p)

proc ed25519Sign*(seed, msg: string): string =
  need()
  let p = pkNewPriv(KindEd25519, nil, bp(seed), 32)
  if p == nil: raise newException(IOError, "bad seed")
  defer: pkFree(p)
  let c = mdNew()
  defer: mdFree(c)
  var o = newString(64)          # (a local: see aesGcmOpen)
  var n = csize_t(64)
  if signInit(c, nil, nil, nil, p) != 1 or signIt(c, bp(o), addr n, bp(msg), csize_t(msg.len)) != 1:
    raise newException(IOError, "signing failed")
  result = move o

proc ed25519Verify*(pub, msg, sig: string): bool =
  need()
  if pub.len != 32 or sig.len != 64: return false
  let p = pkNewPub(KindEd25519, nil, bp(pub), 32)
  if p == nil: return false
  defer: pkFree(p)
  let c = mdNew()
  defer: mdFree(c)
  verifyInit(c, nil, nil, nil, p) == 1 and verifyIt(c, bp(sig), 64, bp(msg), csize_t(msg.len)) == 1

proc aesCbc(encrypt: bool; key, iv, data: string): string =
  ## AES-256-CBC with PKCS#7 padding (raises when the padding is wrong).
  need()
  let c = cipherNew()
  defer: cipherFree(c)
  var o = newString(data.len + 32)   # (a local: see aesGcmOpen)
  var n, m: cint
  let ok = if encrypt:
             encInit(c, aes256cbc(), nil, bp(key), bp(iv)) == 1 and
             encUpdate(c, bp(o), addr n, bp(data), cint(data.len)) == 1 and
             encFinal(c, cast[ptr byte](addr o[n]), addr m) == 1
           else:
             decInit(c, aes256cbc(), nil, bp(key), bp(iv)) == 1 and
             decUpdate(c, bp(o), addr n, bp(data), cint(data.len)) == 1 and
             decFinal(c, cast[ptr byte](addr o[n]), addr m) == 1
  if not ok: raise newException(ValueError, "AES-CBC failed")
  o.setLen(n + m)
  result = move o

proc gcmOf(key: string): pointer =
  if key.len == 32: aes256gcm() elif key.len == 16: aes128gcm()
  else: raise newException(ValueError, "an AES key is 16 or 32 bytes")

proc aesGcmSeal*(key, iv, plain: string): (string, string) =
  ## AES-GCM (128 or 256 by the key's size): the ciphertext and its 16-byte tag.
  need()
  let c = cipherNew()
  defer: cipherFree(c)
  var outp = newString(plain.len + 16)
  var n, m: cint
  var tag = newString(16)
  if encInit(c, gcmOf(key), nil, nil, nil) != 1 or cipherCtrl(c, GcmSetIvLen, cint(iv.len), nil) != 1 or
     encInit(c, nil, nil, bp(key), bp(iv)) != 1 or
     encUpdate(c, bp(outp), addr n, bp(plain), cint(plain.len)) != 1 or
     encFinal(c, cast[ptr byte](addr outp[n]), addr m) != 1 or
     cipherCtrl(c, GcmGetTag, 16, addr tag[0]) != 1:
    raise newException(ValueError, "AES-GCM failed")
  outp.setLen(n + m)
  (outp, tag)

proc aesGcmOpen*(key, iv, data, tag: string): string =
  ## AES-GCM opened (raises when the tag does not match).
  need()
  let c = cipherNew()
  defer: cipherFree(c)
  # (opened into a local, `result` given at the end: what a proc filled
  # before it raised is never freed by Nim 2.2 -- docs/nim-bugs.md, 2)
  var o = newString(data.len + 16)
  var n, m: cint
  var t = tag
  if decInit(c, gcmOf(key), nil, nil, nil) != 1 or cipherCtrl(c, GcmSetIvLen, cint(iv.len), nil) != 1 or
     decInit(c, nil, nil, bp(key), bp(iv)) != 1 or
     decUpdate(c, bp(o), addr n, bp(data), cint(data.len)) != 1 or
     cipherCtrl(c, GcmSetTag, cint(t.len), addr t[0]) != 1 or
     decFinal(c, cast[ptr byte](addr o[n]), addr m) != 1:
    raise newException(ValueError, "the message was changed, or the key is wrong")
  o.setLen(n + m)
  result = move o

proc hmac(key, data: string): string = hmacSha256(key, data).toBinary

proc hkdf*(ikm, salt, info: string; n: int): string =
  ## HKDF with SHA-256 (RFC 5869); an empty salt is 32 zero bytes.
  let prk = hmac(if salt.len > 0: salt else: repeat('\0', 32), ikm)
  var t = ""
  var i = 1
  while result.len < n:
    t = hmac(prk, t & info & char(i))
    result.add t
    inc i
  result.setLen(n)

# ---- files, as the apps send them in an encrypted talk (XEP-0454: aesgcm://) ----------------------

proc encryptFile*(data: string): (string, string) =
  ## A file locked for sending: what to upload (AES-256-GCM, its tag at the
  ## end) and the secret that goes after "#" in its aesgcm:// address (the
  ## IV and the key in hex), which goes inside the encrypted message.
  let key = randomBytes(32)
  let iv = randomBytes(12)
  let (ct, tag) = aesGcmSeal(key, iv, data)
  var secret = ""
  for c in iv & key: secret.add toHex(ord(c), 2).toLowerAscii
  (ct & tag, secret)

proc aesgcmUrl*(url, secret: string): string =
  ## The address to send for a file locked with `encryptFile` and uploaded
  ## at `url` (https://...): aesgcm://..., the secret after "#".
  let k = url.find("://")
  "aesgcm://" & (if k >= 0: url[k + 3 .. ^1] else: url) & "#" & secret

proc isAesgcm*(url: string): bool = url.toLowerAscii.startsWith("aesgcm://")
  ## An encrypted file's address.

proc fetchUrlOf*(url: string): string =
  ## Where to download an aesgcm:// file from (https://, no secret).
  var u = url
  let h = u.find('#')
  if h >= 0: u = u[0 ..< h]
  if u.isAesgcm: "https://" & u[9 .. ^1] else: u

proc decryptFile*(url, data: string): string =
  ## A file downloaded from an aesgcm:// address, opened with the secret in
  ## it (raises when it was changed or the secret is not right).
  let h = url.find('#')
  if h < 0: raise newException(ValueError, "the address has no key")
  let secret = url[h + 1 .. ^1]
  if secret.len notin [88, 96] or data.len < 16: raise newException(ValueError, "not an encrypted file's address")
  var raw = ""
  for i in countup(0, secret.len - 1, 2): raw.add char(parseHexInt(secret[i .. i + 1]))
  let ivLen = raw.len - 32
  aesGcmOpen(raw[ivLen .. ^1], raw[0 ..< ivLen], data[0 ..< ^16], data[^16 .. ^1])

# ---- XEdDSA: the identity key is X25519's, its signatures Ed25519's ------------------------------

type Gf = array[16, int64]

proc car(o: var Gf) =
  for i in 0 ..< 16:
    o[i] += 1'i64 shl 16
    let c = ashr(o[i], 16)
    if i < 15: o[i + 1] += c - 1
    else: o[0] += 38 * (c - 1)
    o[i] -= c shl 16

proc gfMul(a, b: Gf): Gf =
  var t: array[31, int64]
  for i in 0 ..< 16:
    for j in 0 ..< 16: t[i + j] += a[i] * b[j]
  for i in 0 ..< 15: t[i] += 38 * t[i + 16]
  for i in 0 ..< 16: result[i] = t[i]
  car(result)
  car(result)

proc gfInv(a: Gf): Gf =
  result = a
  for k in countdown(253, 0):
    result = gfMul(result, result)
    if k != 2 and k != 4: result = gfMul(result, a)

proc unpack(n: string): Gf =
  for i in 0 ..< 16: result[i] = int64(byte(n[2 * i])) + (int64(byte(n[2 * i + 1])) shl 8)
  result[15] = result[15] and 0x7fff

proc pack(n: Gf): string =
  var t = n
  car(t); car(t); car(t)
  var m: Gf
  for _ in 0 ..< 2:
    m[0] = t[0] - 0xffed
    for i in 1 ..< 15:
      m[i] = t[i] - 0xffff - (ashr(m[i - 1], 16) and 1)
      m[i - 1] = m[i - 1] and 0xffff
    m[15] = t[15] - 0x7fff - (ashr(m[14], 16) and 1)
    let b = ashr(m[15], 16) and 1
    m[14] = m[14] and 0xffff
    if b == 0: t = m          # (t - p was not negative: the reduced one)
  result = newString(32)
  for i in 0 ..< 16:
    result[2 * i] = char(t[i] and 0xff)
    result[2 * i + 1] = char(ashr(t[i], 8) and 0xff)

proc montToEd*(u: string): string =
  ## The Edwards y (Ed25519's public key, its sign bit clear) of the
  ## Montgomery u (X25519's public key): y = (u - 1) / (u + 1).
  let x = unpack(u)
  var one: Gf
  one[0] = 1
  var a, b: Gf
  for i in 0 ..< 16:
    a[i] = x[i] - one[i]
    b[i] = x[i] + one[i]
  pack(gfMul(a, gfInv(b)))

type Identity* = object
  ## This device's identity: an Ed25519 seed; its X25519 key is the same
  ## scalar (what is published), its signatures Ed25519's with the sign bit
  ## of the Edwards key in the signature's last bit (XEdDSA's way).
  seed*: string
  priv*, pub*: string          ## X25519
  edPub*: string

proc identityOf*(seed: string): Identity =
  result.seed = seed
  var h = sha512(seed)
  h.setLen(32)
  h[0] = char(byte(h[0]) and 248)
  h[31] = char((byte(h[31]) and 127) or 64)
  result.priv = h
  result.pub = x25519Pub(h)
  result.edPub = ed25519Pub(seed)

proc xedSign*(id: Identity; msg: string): string =
  result = ed25519Sign(id.seed, msg)
  result[63] = char(byte(result[63]) or (byte(id.edPub[31]) and 0x80))

proc xedVerify*(pub, msg, sig: string): bool =
  ## A signature made with the identity whose X25519 public key is `pub`.
  if pub.len != 32 or sig.len != 64: return false
  var ed = montToEd(pub)
  ed[31] = char((byte(ed[31]) and 0x7f) or (byte(sig[63]) and 0x80))
  var s = sig
  s[63] = char(byte(s[63]) and 0x7f)
  ed25519Verify(ed, msg, s)

# ---- keys and the protobuf of Signal's messages ---------------------------------------------------

type KeyPair* = object
  priv*, pub*: string

proc newKeyPair*(): KeyPair =
  var p = randomBytes(32)
  p[0] = char(byte(p[0]) and 248)
  p[31] = char((byte(p[31]) and 127) or 64)
  KeyPair(priv: p, pub: x25519Pub(p))

proc djb(pub: string): string = "\x05" & pub
  ## (a public key as Signal writes it: type 5, then its 32 bytes)

proc undjb(s: string): string =
  if s.len == 33 and s[0] == '\x05': s[1 .. ^1]
  elif s.len == 32: s
  else: raise newException(ValueError, "not a Curve25519 key")

proc pbVarint(s: var string; v: uint64) =
  var x = v
  while x >= 0x80:
    s.add char(byte(x and 0x7f) or 0x80)
    x = x shr 7
  s.add char(x)

proc pbInt(s: var string; field: int; v: int) =
  s.pbVarint(uint64(field shl 3))
  s.pbVarint(uint64(v))

proc pbBytes(s: var string; field: int; b: string) =
  s.pbVarint(uint64((field shl 3) or 2))
  s.pbVarint(uint64(b.len))
  s.add b

proc pbFields(b: string): Table[int, string] =
  ## The fields of a message: varints as their decimal text, bytes as they are.
  var i = 0
  proc varint(): uint64 =
    var shift = 0
    while true:
      if i >= b.len or shift > 63: raise newException(ValueError, "a broken message")
      let c = byte(b[i])
      inc i
      result = result or (uint64(c and 0x7f) shl shift)
      if c < 0x80: break
      shift += 7
  while i < b.len:
    let key = varint()
    let field = int(key shr 3)
    case key and 7
    of 0: result[field] = $varint()
    of 2:
      let n = int(varint())
      if n < 0 or i + n > b.len: raise newException(ValueError, "a broken message")
      result[field] = b[i ..< i + n]
      i += n
    of 5: i += 4
    of 1: i += 8
    else: raise newException(ValueError, "a broken message")

proc pbNum(f: Table[int, string]; field: int; default = -1): int =
  if f.hasKey(field):
    try: parseInt(f[field]) except ValueError: default
  else: default

# ---- the double ratchet (libsignal's, version 3) --------------------------------------------------

type
  Chain = object
    ratchet: string                  ## their ratchet key (receiving chains)
    key: string
    index: int
    skipped: seq[(int, string)]      ## counter -> message keys (80 bytes) of messages not come yet

  Session = object
    rootKey: string
    localIdentity, remoteIdentity: string
    sender: KeyPair
    sendChain: Chain
    previousCounter: int
    receivers: seq[Chain]
    pending: bool                    ## a PreKey message until they answer
    pendingPreKey, pendingSigned: int
    pendingBase: string
    localReg, remoteReg: int
    aliceBase: string                ## the base key that began it (a PreKey message twice: one session)

  SessionRecord = object
    current: Session
    has: bool
    old: seq[Session]

proc messageKeys(chainKey: string): string =
  ## A chain key's message keys: 32 for AES, 32 for the MAC, 16 the IV.
  hkdf(hmac(chainKey, "\x01"), "", "WhisperMessageKeys", 80)

proc nextChain(c: var Chain) =
  c.key = hmac(c.key, "\x02")
  inc c.index

proc rootStep(rootKey, theirs: string; ours: KeyPair): (string, string) =
  let d = hkdf(x25519(ours.priv, theirs), rootKey, "WhisperRatchet", 64)
  (d[0 ..< 32], d[32 ..< 64])

const Version = '\x33'               ## (3 << 4 | 3: Signal's version 3)

proc whisperMac(macKey, senderId, receiverId, body: string): string =
  hmac(macKey, djb(senderId) & djb(receiverId) & body)[0 ..< 8]

proc sameBytes(a, b: string): bool =
  ## (compared in the same time whatever differs: nothing to learn from how long it took)
  if a.len != b.len: return false
  var d = 0'u8
  for i in 0 ..< a.len: d = d or (byte(a[i]) xor byte(b[i]))
  d == 0

proc encryptIn(s: var Session; plain: string): (string, bool) =
  ## `plain` locked in the session: the message (a PreKey one until they
  ## have answered) and whether it is one.
  let mk = messageKeys(s.sendChain.key)
  let body = aesCbc(true, mk[0 ..< 32], mk[64 ..< 80], plain)
  var pb = ""
  pb.pbBytes(1, djb(s.sender.pub))
  pb.pbInt(2, s.sendChain.index)
  pb.pbInt(3, s.previousCounter)
  pb.pbBytes(4, body)
  let msg = Version & pb
  var whisper = msg & whisperMac(mk[32 ..< 64], s.localIdentity, s.remoteIdentity, msg)
  s.sendChain.nextChain()
  if s.pending:
    var pk = ""
    pk.pbInt(5, s.localReg)
    if s.pendingPreKey >= 0: pk.pbInt(1, s.pendingPreKey)
    pk.pbInt(6, s.pendingSigned)
    pk.pbBytes(2, djb(s.pendingBase))
    pk.pbBytes(3, djb(s.localIdentity))
    pk.pbBytes(4, whisper)
    return (Version & pk, true)
  (whisper, false)

proc decryptIn(s: var Session; data: string): string =
  ## A (Whisper) message opened in the session (raises when it is not one of
  ## it); the session moves on.
  if data.len < 10 or data[0] != Version: raise newException(ValueError, "not a message of version 3")
  let msg = data[0 ..< ^8]
  let f = pbFields(msg[1 .. ^1])
  if not f.hasKey(1) or not f.hasKey(4): raise newException(ValueError, "a broken message")
  let theirs = undjb(f[1])
  let counter = f.pbNum(2, 0)
  # (their new ratchet key: the root steps twice, a new key of ours)
  var k = -1
  for i, c in s.receivers:
    if c.ratchet == theirs: k = i
  var work = s
  if k < 0:
    let (root1, recvKey) = rootStep(work.rootKey, theirs, work.sender)
    let ours = newKeyPair()
    let (root2, sendKey) = rootStep(root1, theirs, ours)
    work.rootKey = root2
    work.receivers.add Chain(ratchet: theirs, key: recvKey)
    if work.receivers.len > MaxChains: work.receivers.delete(0)
    work.previousCounter = max(work.sendChain.index - 1, 0)
    work.sender = ours
    work.sendChain = Chain(key: sendKey)
    k = work.receivers.high
  var chain = work.receivers[k]
  var mk = ""
  if chain.index > counter:
    for j, (n, keys) in chain.skipped:
      if n == counter:
        mk = keys
        chain.skipped.delete(j)
        break
    if mk.len == 0: raise newException(ValueError, "this message came before (or its key is gone)")
  else:
    if counter - chain.index > MaxSkip: raise newException(ValueError, "too many messages missing")
    while chain.index < counter:
      chain.skipped.add (chain.index, messageKeys(chain.key))
      if chain.skipped.len > MaxSkip: chain.skipped.delete(0)
      chain.nextChain()
    mk = messageKeys(chain.key)
    chain.nextChain()
  if not sameBytes(whisperMac(mk[32 ..< 64], work.remoteIdentity, work.localIdentity, msg), data[^8 .. ^1]):
    raise newException(ValueError, "the message's MAC is wrong")
  result = aesCbc(false, mk[0 ..< 32], mk[64 ..< 80], f[4])
  work.receivers[k] = chain
  work.pending = false
  s = work

proc initAlice(ours: Identity; theirIdentity, theirSigned, theirPreKey: string; base: KeyPair): Session =
  ## The session begun by us, from their published keys.
  var secret = repeat('\xff', 32)
  secret.add x25519(ours.priv, theirSigned)
  secret.add x25519(base.priv, theirIdentity)
  secret.add x25519(base.priv, theirSigned)
  if theirPreKey.len > 0: secret.add x25519(base.priv, theirPreKey)
  let d = hkdf(secret, "", "WhisperText", 64)
  let sender = newKeyPair()
  let (root, sendKey) = rootStep(d[0 ..< 32], theirSigned, sender)
  result = Session(rootKey: root, localIdentity: ours.pub, remoteIdentity: theirIdentity, sender: sender,
                   sendChain: Chain(key: sendKey), receivers: @[Chain(ratchet: theirSigned, key: d[32 ..< 64])])

proc initBob(ours: Identity; signed: KeyPair; preKey: string; theirIdentity, theirBase: string): Session =
  ## The session they began, from our keys they used.
  var secret = repeat('\xff', 32)
  secret.add x25519(signed.priv, theirIdentity)
  secret.add x25519(ours.priv, theirBase)
  secret.add x25519(signed.priv, theirBase)
  if preKey.len > 0: secret.add x25519(preKey, theirBase)
  let d = hkdf(secret, "", "WhisperText", 64)
  Session(rootKey: d[0 ..< 32], localIdentity: ours.pub, remoteIdentity: theirIdentity, sender: signed,
          sendChain: Chain(key: d[32 ..< 64]))

# ---- the store: this device's keys, the sessions, the devices of others ---------------------------

type
  Trust* = enum
    tUndecided    ## blindly trusted (until one of theirs is verified)
    tVerified     ## you compared the fingerprints
    tDistrusted   ## you said no

  Device* = object
    ## Someone's device, as this one knows it.
    id*: int
    identity*: string          ## its identity key (32 bytes; "" not seen yet)
    trust*: Trust
    active*: bool              ## in their published list now

  Bundle = object
    identity, signed, signature: string
    signedId: int
    preKeys: seq[(int, string)]

  Pending = object
    id, to, xml: string        ## a message waiting for the keys of the devices it goes to
    since: float

  OmemoNoteKind* = enum
    onSent       ## `id` went, encrypted
    onFailed     ## `id` could not go encrypted: `text` why (nothing was sent)
    onDevices    ## `jid`'s devices are known (or changed)
    onError      ## something to tell (`text`)

  OmemoNote* = object
    kind*: OmemoNoteKind
    id*, jid*, text*: string

  OmemoStore* = ref object
    ## This device's OMEMO: open it with `omemoOpen`.
    path: string
    account*: string           ## the bare address it is for
    deviceId*: int
    identity: Identity
    signed: KeyPair
    signedId: int
    signedSig: string
    signedAt: float            ## when the signed key was made (a new one each month)
    oldSigned: KeyPair         ## the one before it, kept a month for messages begun with it
    oldSignedId: int
    preKeys: Table[int, KeyPair]
    nextPreKey: int
    registration: int
    sessions: Table[string, SessionRecord]   ## "jid/device"
    devices*: Table[string, seq[Device]]     ## bare address -> its devices
    listAsked: Table[string, float]          ## when a list was asked for (or came)
    bundles: Table[string, Bundle]           ## fetched, not used yet
    asking: Table[string, string]            ## a request's id -> what it is ("list jid", "bundle jid/dev"...)
    waiting: seq[Pending]
    notes: seq[OmemoNote]
    started: bool
    republish: bool

proc key(jid: string; dev: int): string = jid & "/" & $dev

proc b64(s: string): string = encode(s)
proc unb64(s: string): string =
  try: unbase64(s)
  except CatchableError: ""

proc chainJson(c: Chain): JsonNode =
  var sk = newJArray()
  for (n, k) in c.skipped: sk.add %*[n, b64(k)]
  %*{"r": b64(c.ratchet), "k": b64(c.key), "i": c.index, "s": sk}

proc chainOf(j: JsonNode): Chain =
  result = Chain(ratchet: unb64(j{"r"}.getStr), key: unb64(j{"k"}.getStr), index: j{"i"}.getInt)
  for p in j{"s"}.getElems: result.skipped.add (p[0].getInt, unb64(p[1].getStr))

proc sessionJson(s: Session): JsonNode =
  var rs = newJArray()
  for c in s.receivers: rs.add chainJson(c)
  %*{"root": b64(s.rootKey), "li": b64(s.localIdentity), "ri": b64(s.remoteIdentity),
     "sp": b64(s.sender.priv), "sP": b64(s.sender.pub), "send": chainJson(s.sendChain),
     "prev": s.previousCounter, "recv": rs, "pending": s.pending, "ppk": s.pendingPreKey,
     "pspk": s.pendingSigned, "pbase": b64(s.pendingBase), "lreg": s.localReg, "rreg": s.remoteReg,
     "abase": b64(s.aliceBase)}

proc sessionOf(j: JsonNode): Session =
  result = Session(rootKey: unb64(j{"root"}.getStr), localIdentity: unb64(j{"li"}.getStr),
                   remoteIdentity: unb64(j{"ri"}.getStr),
                   sender: KeyPair(priv: unb64(j{"sp"}.getStr), pub: unb64(j{"sP"}.getStr)),
                   sendChain: chainOf(j{"send"}), previousCounter: j{"prev"}.getInt,
                   pending: j{"pending"}.getBool, pendingPreKey: j{"ppk"}.getInt(-1),
                   pendingSigned: j{"pspk"}.getInt, pendingBase: unb64(j{"pbase"}.getStr),
                   localReg: j{"lreg"}.getInt, remoteReg: j{"rreg"}.getInt, aliceBase: unb64(j{"abase"}.getStr))
  for c in j{"recv"}.getElems: result.receivers.add chainOf(c)

proc save*(o: OmemoStore) =
  ## Writes the store (it is written after each change by itself).
  var pks = newJObject()
  for id, kp in o.preKeys: pks[$id] = %*[b64(kp.priv), b64(kp.pub)]
  var ss = newJObject()
  for k, r in o.sessions:
    if not r.has: continue
    var old = newJArray()
    for s in r.old: old.add sessionJson(s)
    ss[k] = %*{"cur": sessionJson(r.current), "old": old}
  var ds = newJObject()
  for jid, list in o.devices:
    var a = newJArray()
    for d in list: a.add %*{"id": d.id, "ik": b64(d.identity), "t": ord(d.trust), "on": d.active}
    ds[jid] = a
  let j = %*{"version": 1, "account": o.account, "device": o.deviceId, "seed": b64(o.identity.seed),
             "spk": [o.signedId, b64(o.signed.priv), b64(o.signed.pub), b64(o.signedSig)],
             "spkAt": o.signedAt, "oldSpk": [o.oldSignedId, b64(o.oldSigned.priv), b64(o.oldSigned.pub)],
             "prekeys": pks, "next": o.nextPreKey, "reg": o.registration, "sessions": ss, "devices": ds}
  let tmp = o.path & ".new"
  writeFile(tmp, $j)
  try: setFilePermissions(tmp, {fpUserRead, fpUserWrite}) except CatchableError: discard
  moveFile(tmp, o.path)

proc newSigned(o: OmemoStore) =
  if o.signed.priv.len > 0:
    o.oldSigned = o.signed
    o.oldSignedId = o.signedId
  o.signed = newKeyPair()
  inc o.signedId
  o.signedSig = xedSign(o.identity, djb(o.signed.pub))
  o.signedAt = epochTime()

proc fillPreKeys(o: OmemoStore) =
  while o.preKeys.len < PreKeys:
    inc o.nextPreKey
    o.preKeys[o.nextPreKey] = newKeyPair()

proc omemoOpen*(dir, account: string): OmemoStore =
  ## This device's OMEMO for `account`: its keys, from `dir` (made the first
  ## time: a device id, an identity, a signed key and 100 one-time keys).
  need()
  createDir(dir)
  let bare = bareJid(account).toLowerAscii
  result = OmemoStore(account: bare, path: dir / "omemo-" & bare.replace("/", "_") & ".json")
  if fileExists(result.path):
    let j = parseJson(readFile(result.path))
    result.deviceId = j{"device"}.getInt
    result.identity = identityOf(unb64(j{"seed"}.getStr))
    let spk = j{"spk"}
    result.signedId = spk[0].getInt
    result.signed = KeyPair(priv: unb64(spk[1].getStr), pub: unb64(spk[2].getStr))
    result.signedSig = unb64(spk[3].getStr)
    result.signedAt = j{"spkAt"}.getFloat(epochTime())
    let old = j{"oldSpk"}
    if old != nil and old.len == 3:
      result.oldSignedId = old[0].getInt
      result.oldSigned = KeyPair(priv: unb64(old[1].getStr), pub: unb64(old[2].getStr))
    for id, p in j{"prekeys"}.pairs:
      result.preKeys[parseInt(id)] = KeyPair(priv: unb64(p[0].getStr), pub: unb64(p[1].getStr))
    result.nextPreKey = j{"next"}.getInt
    result.registration = j{"reg"}.getInt
    for k, r in j{"sessions"}.pairs:
      var rec = SessionRecord(has: true, current: sessionOf(r{"cur"}))
      for s in r{"old"}.getElems: rec.old.add sessionOf(s)
      result.sessions[k] = rec
    for jid, a in j{"devices"}.pairs:
      var list: seq[Device]
      for d in a.getElems:
        list.add Device(id: d{"id"}.getInt, identity: unb64(d{"ik"}.getStr),
                        trust: Trust(clamp(d{"t"}.getInt, 0, 2)), active: d{"on"}.getBool(true))
      result.devices[jid] = list
  else:
    var r = initRand()
    result.deviceId = r.rand(1 .. 0x7fffffff)
    result.registration = r.rand(1 .. 16380)
    result.identity = identityOf(randomBytes(32))
    result.newSigned()
    result.fillPreKeys()
    result.save()

proc hexGroups(k: string): string =
  for i, c in k:
    if i > 0 and i mod 4 == 0: result.add ' '
    result.add toHex(ord(c), 2).toLowerAscii

proc omemoFingerprint*(o: OmemoStore): string =
  ## This device's fingerprint, as the other apps show it (32 bytes in hex,
  ## in groups of eight digits).
  hexGroups(o.identity.pub)

proc fingerprint*(d: Device): string =
  ## A device's fingerprint ("" until its key was seen).
  if d.identity.len == 32: hexGroups(d.identity) else: ""

proc omemoDevices*(o: OmemoStore; jid: string): seq[Device] =
  ## The devices of `jid` (bare) this one knows, the ones in their list now first.
  result = o.devices.getOrDefault(bareJid(jid).toLowerAscii)
  result.sort(proc (a, b: Device): int = cmp(b.active, a.active))

proc omemoTrust*(o: OmemoStore; jid: string; device: int; trust: Trust) =
  ## You verified `jid`'s device (compared its fingerprint), or will not
  ## write to it, or left it undecided.
  let b = bareJid(jid).toLowerAscii
  if o.devices.hasKey(b):
    for d in o.devices[b].mitems:
      if d.id == device: d.trust = trust
    o.save()

proc deviceOf(o: OmemoStore; jid: string; dev: int): ptr Device =
  if not o.devices.hasKey(jid): o.devices[jid] = @[]
  for d in o.devices[jid].mitems:
    if d.id == dev: return addr d
  o.devices[jid].add Device(id: dev, active: false)
  addr o.devices[jid][^1]

proc noteIdentity(o: OmemoStore; jid: string; dev: int; identity: string): bool =
  ## The identity key seen for a device: kept the first time; another one
  ## later is a device to doubt (false: not trusted now).
  let d = o.deviceOf(jid, dev)
  if d.identity.len == 0:
    d.identity = identity
    true
  elif d.identity != identity:
    d.identity = identity
    d.trust = tDistrusted
    o.notes.add OmemoNote(kind: onError, jid: jid,
                          text: "A device of " & jid & " has a new key: it is not trusted until you check it.")
    false
  else: d.trust != tDistrusted

proc targets(o: OmemoStore; jid: string): seq[int] =
  ## The devices of `jid` a message goes to: the ones in their list not
  ## refused; once one of theirs is verified, the verified ones only.
  let list = o.devices.getOrDefault(jid)
  var verified = false
  for d in list:
    if d.trust == tVerified and d.active: verified = true
  for d in list:
    if not d.active or d.trust == tDistrusted: continue
    if jid == o.account and d.id == o.deviceId: continue
    if verified and d.trust != tVerified: continue
    result.add d.id

# ---- what goes to the server: the lists, the bundles ----------------------------------------------

proc publishOptions(): string =
  "<publish-options><x xmlns='jabber:x:data' type='submit'><field var='FORM_TYPE' type='hidden'>" &
  "<value>http://jabber.org/protocol/pubsub#publish-options</value></field>" &
  "<field var='pubsub#access_model'><value>open</value></field></x></publish-options>"

proc ask(o: OmemoStore; what, xml: string): string =
  ## An iq whose answer comes back whole (its id starts "q-").
  result = "q-" & newId()
  o.asking[result] = what
  xmppSend(xml.replace("{id}", result))

proc publishBundle(o: OmemoStore) =
  var x = "<iq type='set' id='{id}'><pubsub xmlns='http://jabber.org/protocol/pubsub'><publish node='" &
          NodeBundle & $o.deviceId & "'><item id='current'><bundle xmlns='" & Ns & "'>" &
          "<signedPreKeyPublic signedPreKeyId='" & $o.signedId & "'>" & b64(djb(o.signed.pub)) &
          "</signedPreKeyPublic><signedPreKeySignature>" & b64(o.signedSig) & "</signedPreKeySignature>" &
          "<identityKey>" & b64(djb(o.identity.pub)) & "</identityKey><prekeys>"
  var ids: seq[int]
  for id in o.preKeys.keys: ids.add id
  ids.sort()
  for id in ids: x &= "<preKeyPublic preKeyId='" & $id & "'>" & b64(djb(o.preKeys[id].pub)) & "</preKeyPublic>"
  x &= "</prekeys></bundle></item></publish>" & publishOptions() & "</pubsub></iq>"
  discard o.ask("publish bundle", x)

proc publishList(o: OmemoStore) =
  var x = "<iq type='set' id='{id}'><pubsub xmlns='http://jabber.org/protocol/pubsub'><publish node='" &
          NodeList & "'><item id='current'><list xmlns='" & Ns & "'>"
  for d in o.devices.getOrDefault(o.account):
    if d.active: x &= "<device id='" & $d.id & "'/>"
  x &= "</list></item></publish>" & publishOptions() & "</pubsub></iq>"
  discard o.ask("publish list", x)

proc askList(o: OmemoStore; jid: string) =
  o.listAsked[jid] = epochTime()
  discard o.ask("list " & jid, "<iq type='get' id='{id}'" & (if jid == o.account: "" else: " to='" & jid & "'") &
                "><pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='" & NodeList & "'/></pubsub></iq>")

proc askBundle(o: OmemoStore; jid: string; dev: int) =
  for what in o.asking.values:
    if what == "bundle " & key(jid, dev): return
  discard o.ask("bundle " & key(jid, dev), "<iq type='get' id='{id}' to='" & jid & "'>" &
                "<pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='" & NodeBundle & $dev &
                "' max_items='1'/></pubsub></iq>")

proc omemoStart*(o: OmemoStore) =
  ## After xeOnline: this device put in your list of devices (the list read
  ## first, so your other devices stay in it) and its keys published (a new
  ## signed key when the one there is a month old).
  if epochTime() - o.signedAt > 30 * 86400.0:
    o.newSigned()
    o.save()
  o.started = true
  o.asking.clear()
  o.askList(o.account)

proc omemoRefresh*(o: OmemoStore; jid: string; force = false) =
  ## Asks for `jid`'s devices (again, when the list is older than ten
  ## minutes or `force`); onDevices says when they are known.
  let b = bareJid(jid).toLowerAscii
  if force or epochTime() - o.listAsked.getOrDefault(b, 0.0) > 600: o.askList(b)

proc omemoKnows*(o: OmemoStore; jid: string): bool =
  ## `jid` has devices with OMEMO (as far as this one knows).
  for d in o.devices.getOrDefault(bareJid(jid).toLowerAscii):
    if d.active: return true

proc listOf(n: XmlNode): seq[int] =
  for l in n.findAll("list"):
    if l.attr("xmlns") == Ns:
      for d in l.findAll("device"):
        try: result.add parseInt(d.attr("id")) except ValueError: discard

proc takeList(o: OmemoStore; jid: string; ids: seq[int]) =
  discard o.deviceOf(jid, 0)       # (the entry, even with no device)
  o.devices[jid].keepItIf(it.id != 0)
  for d in o.devices[jid].mitems: d.active = d.id in ids
  for id in ids:
    if id > 0: o.deviceOf(jid, id).active = true
  if jid == o.account and o.started:
    var mine = false
    for id in ids:
      if id == o.deviceId: mine = true
    o.deviceOf(jid, o.deviceId).active = true
    o.deviceOf(jid, o.deviceId).identity = o.identity.pub
    o.deviceOf(jid, o.deviceId).trust = tVerified
    if not mine: o.publishList()
  o.save()
  o.notes.add OmemoNote(kind: onDevices, jid: jid)

proc bundleOf(n: XmlNode): (bool, Bundle) =
  var b: Bundle
  for bn in n.findAll("bundle"):
    if bn.attr("xmlns") != Ns: continue
    let spk = bn.child("signedPreKeyPublic")
    if spk == nil or bn.child("signedPreKeySignature") == nil or bn.child("identityKey") == nil: continue
    try:
      b.signed = undjb(unb64(spk.innerText))
      b.signedId = parseInt(spk.attr("signedPreKeyId"))
      b.signature = unb64(bn.child("signedPreKeySignature").innerText)
      b.identity = undjb(unb64(bn.child("identityKey").innerText))
      let pks = bn.child("prekeys")
      if pks != nil:
        for p in pks.findAll("preKeyPublic"):
          try: b.preKeys.add (parseInt(p.attr("preKeyId")), undjb(unb64(p.innerText)))
          except ValueError: discard
      return (true, b)
    except ValueError: discard
  (false, b)

# ---- sending -------------------------------------------------------------------------------------

proc startSession(o: OmemoStore; jid: string; dev: int; b: Bundle): bool =
  ## A session begun from a device's published keys (their signature
  ## checked first; a one-time key of theirs chosen by chance).
  if not xedVerify(b.identity, djb(b.signed), b.signature):
    o.notes.add OmemoNote(kind: onError, jid: jid, text: "A device of " & jid & " published keys that are not signed right.")
    return false
  if not o.noteIdentity(jid, dev, b.identity): return false
  let base = newKeyPair()
  var pk = ""
  var pkId = -1
  if b.preKeys.len > 0:
    var r = initRand()
    let (id, k) = b.preKeys[r.rand(b.preKeys.high)]
    pk = k
    pkId = id
  var s = initAlice(o.identity, b.identity, b.signed, pk, base)
  s.pending = true
  s.pendingPreKey = pkId
  s.pendingSigned = b.signedId
  s.pendingBase = base.pub
  s.localReg = o.registration
  s.aliceBase = base.pub
  var rec = o.sessions.getOrDefault(key(jid, dev))
  if rec.has:
    rec.old.insert(rec.current, 0)
    if rec.old.len > MaxOldStates: rec.old.setLen(MaxOldStates)
  rec.current = s
  rec.has = true
  o.sessions[key(jid, dev)] = rec
  true

proc readyFor(o: OmemoStore; jid: string): (bool, seq[(string, int)]) =
  ## Whether every device a message to `jid` goes to has a session (or its
  ## keys are here to begin one); the ones still to fetch.
  var all = true
  for (who, devs) in [(jid, o.targets(jid)), (o.account, o.targets(o.account))]:
    for dev in devs:
      let k = key(who, dev)
      if o.sessions.hasKey(k) and o.sessions[k].has: continue
      if o.bundles.hasKey(k): continue
      all = false
      result[1].add (who, dev)
  result[0] = all

proc encryptFor(o: OmemoStore; jid, body: string): string =
  ## The <encrypted> element of `body` for every device of `jid` and your
  ## own others ("" none could be).
  let key16 = randomBytes(16)
  let iv = randomBytes(12)
  let (ct, tag) = aesGcmSeal(key16, iv, body)
  var keys = ""
  var count = 0
  for (who, devs) in [(jid, o.targets(jid)), (o.account, o.targets(o.account))]:
    for dev in devs:
      let k = key(who, dev)
      if not (o.sessions.hasKey(k) and o.sessions[k].has) and o.bundles.hasKey(k):
        let b = o.bundles[k]
        o.bundles.del k
        if not o.startSession(who, dev, b): continue
      if not (o.sessions.hasKey(k) and o.sessions[k].has): continue
      try:
        var rec = o.sessions[k]
        let (data, pre) = rec.current.encryptIn(key16 & tag)
        o.sessions[k] = rec
        keys &= "<key rid='" & $dev & "'" & (if pre: " prekey='true'" else: "") & ">" & b64(data) & "</key>"
        if who == jid: inc count
      except CatchableError: discard
  if count == 0: return ""
  o.save()
  "<encrypted xmlns='" & Ns & "'><header sid='" & $o.deviceId & "'>" & keys & "<iv>" & b64(iv) &
  "</iv></header><payload>" & b64(ct) & "</payload></encrypted>"

proc stanzaFor(o: OmemoStore; p: Pending): string =
  let enc = o.encryptFor(p.to, p.xml)
  if enc.len == 0: return ""
  "<message to='" & xmltree.escape(p.to) & "' type='chat' id='" & p.id & "'>" & enc &
  "<encryption xmlns='urn:xmpp:eme:0' namespace='" & Ns & "' name='OMEMO'/>" &
  "<body>" & xmltree.escape(Fallback) & "</body><store xmlns='urn:xmpp:hints'/>" &
  "<request xmlns='urn:xmpp:receipts'/><active xmlns='http://jabber.org/protocol/chatstates'/></message>"

proc flush(o: OmemoStore) =
  ## The messages waiting: sent once their keys are here (or after 15
  ## seconds with the devices that are ready, or not at all).
  var keep: seq[Pending]
  var listing: seq[string]
  for what in o.asking.values:
    if what.startsWith("list "): listing.add what[5 .. ^1]
  for p in o.waiting:
    if (p.to in listing or o.account in listing) and epochTime() - p.since <= 15:
      keep.add p                   # (their devices, or yours, still being asked for)
      continue
    let (ready, missing) = o.readyFor(p.to)
    let late = epochTime() - p.since > 15
    if not ready and not late:
      for (who, dev) in missing: o.askBundle(who, dev)
      keep.add p
      continue
    let x = o.stanzaFor(p)
    if x.len > 0:
      xmppSend(x)
      o.notes.add OmemoNote(kind: onSent, id: p.id, jid: p.to)
    else:
      o.notes.add OmemoNote(kind: onFailed, id: p.id, jid: p.to,
                            text: (if o.targets(p.to).len == 0: p.to & " has no device this one may write to"
                                   else: "no device of " & p.to & " could be reached"))
  o.waiting = keep

proc omemoSend*(o: OmemoStore; to, body: string): string =
  ## `body` to `to`, encrypted for each of their devices and your other
  ## ones; its id. It goes when their keys are here (fetched first when
  ## needed): onSent, or onFailed (then nothing went).
  result = newId()
  let jid = bareJid(to).toLowerAscii
  o.waiting.add Pending(id: result, to: jid, xml: body, since: epochTime())
  if o.devices.hasKey(jid) and epochTime() - o.listAsked.getOrDefault(jid, 0.0) < 600: o.flush()
  else: o.askList(jid)

proc omemoNotes*(o: OmemoStore): seq[OmemoNote] =
  ## What happened since the last call (call it every frame).
  if o.waiting.len > 0: o.flush()
  if o.republish:
    o.republish = false
    o.publishBundle()
  result = move o.notes
  o.notes = @[]

# ---- receiving -----------------------------------------------------------------------------------

proc isEncrypted*(e: XmppEvent): bool =
  ## A message (xeMessage, xeArchived) locked with OMEMO 0.3.
  e.raw.len > 0 and Ns in e.raw

proc preKeyMessage(o: OmemoStore; jid: string; dev: int; data: string): string =
  ## A PreKey message: the session they began, then its message.
  if data.len < 2 or data[0] != Version: raise newException(ValueError, "not a message of version 3")
  let f = pbFields(data[1 .. ^1])
  if not f.hasKey(2) or not f.hasKey(3) or not f.hasKey(4): raise newException(ValueError, "a broken message")
  let base = undjb(f[2])
  let theirId = undjb(f[3])
  let k = key(jid, dev)
  var rec = o.sessions.getOrDefault(k)
  # (the same PreKey message again, or one of a session already begun by it)
  if rec.has:
    if rec.current.aliceBase == base:
      result = rec.current.decryptIn(f[4])
      o.sessions[k] = rec
      return
    for i in 0 ..< rec.old.len:
      if rec.old[i].aliceBase == base:
        result = rec.old[i].decryptIn(f[4])
        o.sessions[k] = rec
        return
  if not o.noteIdentity(jid, dev, theirId): raise newException(ValueError, "that device is not trusted")
  let signedId = f.pbNum(6)
  let signed = if signedId == o.signedId: o.signed
               elif signedId == o.oldSignedId and o.oldSigned.priv.len > 0: o.oldSigned
               else: raise newException(ValueError, "it used a key this device no longer has")
  let pkId = f.pbNum(1)
  var pk = ""
  if pkId >= 0:
    if not o.preKeys.hasKey(pkId): raise newException(ValueError, "it used a one-time key already used")
    pk = o.preKeys[pkId].priv
  var s = initBob(o.identity, signed, pk, theirId, base)
  s.localReg = o.registration
  s.remoteReg = f.pbNum(5, 0)
  s.aliceBase = base
  result = s.decryptIn(f[4])
  if rec.has:
    rec.old.insert(rec.current, 0)
    if rec.old.len > MaxOldStates: rec.old.setLen(MaxOldStates)
  rec.current = s
  rec.has = true
  o.sessions[k] = rec
  if pkId >= 0:
    # (a one-time key is used once: a new one in its place)
    o.preKeys.del pkId
    o.fillPreKeys()
    o.republish = true

proc whisperMessage(o: OmemoStore; jid: string; dev: int; data: string): string =
  let k = key(jid, dev)
  if not o.sessions.hasKey(k) or not o.sessions[k].has:
    raise newException(ValueError, "no session with that device (it may have been made on another install)")
  var rec = o.sessions[k]
  try:
    result = rec.current.decryptIn(data)
  except ValueError as e:
    var done = false
    for i in 0 ..< rec.old.len:
      try:
        result = rec.old[i].decryptIn(data)
        done = true
        break
      except ValueError: discard
    if not done: raise e
  o.sessions[k] = rec

proc omemoDecrypt*(o: OmemoStore; e: XmppEvent): (bool, string, string) =
  ## The words of an encrypted message (`isEncrypted(e)`): (true, the
  ## words, "") or (false, "", why). A message with no words (one that
  ## only moves the session on) gives (true, "", "").
  let jid = (if e.kind == xeArchived and e.mine: o.account
             elif e.carbon: o.account else: bareJid(e.jid).toLowerAscii)
  try:
    let m = parseXml(e.raw)
    var enc: XmlNode = nil
    for x in m.findAll("encrypted"):
      if x.attr("xmlns") == Ns: enc = x
    if enc == nil: return (false, "", "not an OMEMO message")
    let h = enc.child("header")
    if h == nil: return (false, "", "a broken message")
    let sid = parseInt(h.attr("sid"))
    var keyEl: XmlNode = nil
    for k in h.findAll("key"):
      if k.attr("rid") == $o.deviceId: keyEl = k
    if keyEl == nil: return (false, "", "it was not encrypted for this device")
    let data = unb64(keyEl.innerText)
    let pre = keyEl.attr("prekey") in ["true", "1"]
    let sender = if e.kind == xeArchived and e.mine: o.account
                 elif e.carbon and e.kind == xeMessage: o.account
                 else: jid
    let keyTag = if pre: o.preKeyMessage(sender, sid, data) else: o.whisperMessage(sender, sid, data)
    o.save()
    let payload = enc.child("payload")
    if payload == nil: return (true, "", "")
    let iv = unb64(h.child("iv").innerText)
    var ct = unb64(payload.innerText)
    var aes, tag: string
    if keyTag.len >= 32:
      aes = keyTag[0 ..< 16]
      tag = keyTag[16 ..< 32]
    elif keyTag.len == 16 and ct.len >= 16:
      # (older apps: the tag at the payload's end)
      aes = keyTag
      tag = ct[^16 .. ^1]
      ct.setLen(ct.len - 16)
    else: return (false, "", "a broken key")
    (true, aesGcmOpen(aes, iv, ct, tag), "")
  except CatchableError as x:
    (false, "", x.msg)

proc omemoHandle*(o: OmemoStore; e: XmppEvent): bool =
  ## Takes OMEMO's own answers (lists, bundles, what was published, a
  ## list that changed): true when `e` was one (the app need not look at it).
  case e.kind
  of xeStanza:
    let n = try: parseXml(e.text) except CatchableError: nil
    if n == nil: return false
    if n.tag == "message":
      # (a list that changed: the server tells who follows it)
      for ev in n.findAll("items"):
        if ev.attr("node") == NodeList:
          let sender = bareJid(n.attr("from")).toLowerAscii
          o.takeList(if sender.len > 0: sender else: o.account, listOf(ev))
          o.flush()
          return true
      return false
    let what = o.asking.getOrDefault(e.id)
    if what.len == 0: return false
    o.asking.del e.id
    let failed = n.attr("type") == "error"
    if what.startsWith("list "):
      let jid = what[5 .. ^1]
      o.takeList(jid, if failed: @[] else: listOf(n))
      if jid == o.account and o.started:
        o.publishBundle()
      o.flush()
    elif what.startsWith("bundle "):
      let k = what[7 .. ^1]
      let slash = k.rfind('/')
      let (ok, b) = bundleOf(n)
      if not failed and ok: o.bundles[k] = b
      elif slash > 0:
        # (no keys published for it: a device gone; not waited for again)
        try: o.deviceOf(k[0 ..< slash], parseInt(k[slash + 1 .. ^1])).active = false
        except ValueError: discard
      o.flush()
    elif what.startsWith("publish") and failed:
      o.notes.add OmemoNote(kind: onError, text: "Your server did not take this device's keys (" & what & ").")
    true
  of xeError:
    if o.asking.hasKey(e.id):
      # (the same as an error answer)
      let what = o.asking[e.id]
      o.asking.del e.id
      if what.startsWith("list "):
        o.takeList(what[5 .. ^1], @[])
        if what[5 .. ^1] == o.account and o.started: o.publishBundle()
        o.flush()
      elif what.startsWith("bundle "): o.flush()
      return true
    false
  else: false
