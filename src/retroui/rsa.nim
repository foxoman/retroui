## RSA in plain Nim -- what signing an Android package needs, without
## OpenSSL: a 2048-bit key made (`newRsaKey`), read and written as PEM
## (`readRsaKey`, `pem`: PKCS #8, as `openssl req -newkey` makes them, or
## PKCS #1), PKCS #1 v1.5 signatures with SHA-256 (`sign`, `verify`), the
## public key's DER (`publicKeyDer`) and a self-signed X.509 certificate
## (`selfSignedCert`).
##
## .. code-block:: nim
##   let key = newRsaKey()
##   writeFile("key.pem", key.pem)
##   writeFile("cert.der", key.selfSignedCert("CN=my app"))
##   let sig = key.sign(data)
##
## The arithmetic is simple (schoolbook multiplication, Knuth's division):
## a key takes a fraction of a second to make, a signature a few
## milliseconds. Keys are made from the system's random numbers
## (`std/sysrand`).

import std/[sysrand, base64, strutils, times, bitops]
from codec import unbase64

type
  Big = seq[uint32]            # little-endian limbs, no zero limbs at the top (0: empty)

  RsaKey* = object
    ## A private key (and its public part `n`, `e`).
    n*, e*, d*, p*, q*, dp*, dq*, qinv*: seq[byte]   ## big-endian numbers

  RsaError* = object of CatchableError
    ## A key that cannot be read or used (a damaged PEM or DER, a number of
    ## the wrong size).

# ---- numbers -------------------------------------------------------------------------------

proc norm(a: var Big) =
  while a.len > 0 and a[^1] == 0: a.setLen(a.len - 1)

proc fromBytes(b: openArray[byte]): Big =
  result = newSeq[uint32]((b.len + 3) div 4)
  for i in 0 ..< b.len:
    let k = b.len - 1 - i              # (the i-th byte from the end)
    result[i div 4] = result[i div 4] or (uint32(b[k]) shl (8 * (i mod 4)))
  norm(result)

proc toBytes(a: Big; len = 0): seq[byte] =
  ## Big-endian, at least `len` bytes (no leading zeros otherwise).
  var n = a.len * 4
  var out0 = newSeq[byte](n)
  for i in 0 ..< n:
    out0[n - 1 - i] = byte((a[i div 4] shr (8 * (i mod 4))) and 0xFF)
  var s = 0
  while s < out0.len - 1 and out0[s] == 0: inc s
  if a.len == 0: out0 = @[0'u8] else: out0 = out0[s .. ^1]
  if out0.len < len:
    result = newSeq[byte](len - out0.len) & out0
  else: result = out0

proc small(v: uint64): Big =
  result = @[uint32(v and 0xFFFFFFFF'u64), uint32(v shr 32)]
  norm(result)

proc cmpB(a, b: Big): int =
  if a.len != b.len: return cmp(a.len, b.len)
  for i in countdown(a.high, 0):
    if a[i] != b[i]: return (if a[i] < b[i]: -1 else: 1)
  0

proc addB(a, b: Big): Big =
  let n = max(a.len, b.len)
  result = newSeq[uint32](n + 1)
  var c = 0'u64
  for i in 0 ..< n:
    let s = uint64(if i < a.len: a[i] else: 0) + uint64(if i < b.len: b[i] else: 0) + c
    result[i] = uint32(s and 0xFFFFFFFF'u64)
    c = s shr 32
  result[n] = uint32(c)
  norm(result)

proc subB(a, b: Big): Big =
  ## `a - b` (`a` >= `b`).
  result = newSeq[uint32](a.len)
  var borrow = 0'i64
  for i in 0 ..< a.len:
    var t = int64(a[i]) - (if i < b.len: int64(b[i]) else: 0) - borrow
    if t < 0:
      t += 0x1_0000_0000'i64
      borrow = 1
    else: borrow = 0
    result[i] = uint32(t)
  norm(result)

proc mulB(a, b: Big): Big =
  if a.len == 0 or b.len == 0: return @[]
  result = newSeq[uint32](a.len + b.len)
  for i in 0 ..< a.len:
    var c = 0'u64
    let ai = uint64(a[i])
    for j in 0 ..< b.len:
      let t = ai * uint64(b[j]) + uint64(result[i + j]) + c
      result[i + j] = uint32(t and 0xFFFFFFFF'u64)
      c = t shr 32
    result[i + b.len] = uint32(c)
  norm(result)

proc divmodB(u0, v0: Big): (Big, Big) =
  ## Quotient and remainder (Knuth's algorithm D, as Hacker's Delight has it).
  var u = u0
  var v = v0
  norm(u)
  norm(v)
  if v.len == 0: raise newException(RsaError, "division by zero")
  if cmpB(u, v) < 0: return (@[], u)
  if v.len == 1:
    var q = newSeq[uint32](u.len)
    var r = 0'u64
    let d = uint64(v[0])
    for i in countdown(u.high, 0):
      let cur = (r shl 32) or uint64(u[i])
      q[i] = uint32(cur div d)
      r = cur mod d
    norm(q)
    return (q, small(r))
  let n = v.len
  let m = u.len - n
  let s = countLeadingZeroBits(v[^1])
  var vn = newSeq[uint32](n)
  var un = newSeq[uint32](u.len + 1)
  for i in countdown(n - 1, 1):
    vn[i] = if s == 0: v[i] else: (v[i] shl s) or (v[i - 1] shr (32 - s))
  vn[0] = v[0] shl s
  un[u.len] = if s == 0: 0'u32 else: u[^1] shr (32 - s)
  for i in countdown(u.len - 1, 1):
    un[i] = if s == 0: u[i] else: (u[i] shl s) or (u[i - 1] shr (32 - s))
  un[0] = u[0] shl s
  var q = newSeq[uint32](m + 1)
  const b = 0x1_0000_0000'u64
  for j in countdown(m, 0):
    let num = (uint64(un[j + n]) shl 32) or uint64(un[j + n - 1])
    var qhat = num div uint64(vn[n - 1])
    var rhat = num - qhat * uint64(vn[n - 1])
    while qhat >= b or qhat * uint64(vn[n - 2]) > ((rhat shl 32) or uint64(un[j + n - 2])):
      dec qhat
      rhat += uint64(vn[n - 1])
      if rhat >= b: break
    var k = 0'i64
    for i in 0 ..< n:
      let p = qhat * uint64(vn[i])
      let t = int64(un[i + j]) - k - int64(p and 0xFFFFFFFF'u64)
      un[i + j] = uint32(cast[uint64](t) and 0xFFFFFFFF'u64)
      k = int64(p shr 32) - ashr(t, 32)
    let t = int64(un[j + n]) - k
    un[j + n] = uint32(cast[uint64](t) and 0xFFFFFFFF'u64)
    if t < 0:
      dec qhat
      var c = 0'u64
      for i in 0 ..< n:
        let s2 = uint64(un[i + j]) + uint64(vn[i]) + c
        un[i + j] = uint32(s2 and 0xFFFFFFFF'u64)
        c = s2 shr 32
      un[j + n] = un[j + n] + uint32(c)
    q[j] = uint32(qhat)
  var r = newSeq[uint32](n)
  for i in 0 ..< n:
    r[i] = if s == 0: un[i] else: (un[i] shr s) or (un[i + 1] shl (32 - s))
  norm(q)
  norm(r)
  (q, r)

proc modB(a, m: Big): Big = divmodB(a, m)[1]

proc bitLen(a: Big): int =
  if a.len == 0: 0 else: a.high * 32 + (32 - countLeadingZeroBits(a[^1]))

proc bitAt(a: Big; i: int): bool = ((a[i div 32] shr (i mod 32)) and 1) != 0

proc powmod(base, e, m: Big): Big =
  ## `base` ^ `e` mod `m` (left to right, a square and a multiply a bit).
  result = small(1)
  let b = modB(base, m)
  for i in countdown(bitLen(e) - 1, 0):
    result = modB(mulB(result, result), m)
    if bitAt(e, i): result = modB(mulB(result, b), m)

proc smallMod(a: Big; d: uint32): uint32 =
  var r = 0'u64
  for i in countdown(a.high, 0): r = ((r shl 32) or uint64(a[i])) mod uint64(d)
  uint32(r)

# ---- primes, keys --------------------------------------------------------------------------

const smallPrimes = block:
  var ps: seq[uint32]
  var n = 3'u32
  while ps.len < 400:
    var isP = true
    for p in ps:
      if p * p > n: break
      if n mod p == 0:
        isP = false
        break
    if isP: ps.add n
    n += 2
  ps

proc randomBig(bits: int): Big =
  var b = newSeq[byte](bits div 8)
  if not urandom(b): raise newException(RsaError, "no random numbers")
  fromBytes(b)

proc probablyPrime(n: Big; rounds = 8): bool =
  ## Miller-Rabin with random bases (after the small primes).
  for p in smallPrimes:
    if smallMod(n, p) == 0: return cmpB(n, small(p)) == 0
  let one = small(1)
  let nm1 = subB(n, one)
  var d = nm1
  var r = 0
  while d.len > 0 and (d[0] and 1) == 0:
    # d >>= 1
    for i in 0 ..< d.len:
      d[i] = (d[i] shr 1) or (if i + 1 < d.len: d[i + 1] shl 31 else: 0'u32)
    norm(d)
    inc r
  for _ in 0 ..< rounds:
    var a = modB(randomBig(bitLen(n) + 64), subB(n, small(3)))
    a = addB(a, small(2))                                    # 2 .. n - 2
    var x = powmod(a, d, n)
    if cmpB(x, one) == 0 or cmpB(x, nm1) == 0: continue
    var witness = true
    for _ in 1 ..< r:
      x = modB(mulB(x, x), n)
      if cmpB(x, nm1) == 0:
        witness = false
        break
    if witness: return false
  true

proc randomPrime(bits: int; e: uint32): Big =
  ## A prime of exactly `bits` bits (its top two set: two of them make a
  ## number of twice the bits), `p - 1` prime to `e`.
  while true:
    var c = randomBig(bits)
    c.setLen(bits div 32)
    c[^1] = c[^1] or 0xC0000000'u32
    c[0] = c[0] or 1
    if smallMod(c, e) == 1: continue          # (gcd(e, p - 1) must be 1)
    if probablyPrime(c): return c

proc invSmall(a, m: int64): int64 =
  ## The inverse of `a` mod `m` (Euclid, small numbers).
  var (t, newT, r, newR) = (0'i64, 1'i64, m, a mod m)
  while newR != 0:
    let q = r div newR
    (t, newT) = (newT, t - q * newT)
    (r, newR) = (newR, r - q * newR)
  if t < 0: t += m
  t

proc newRsaKey*(bits = 2048; e = 65537'u32): RsaKey =
  ## A new key (`bits` its modulus' size).
  let eb = small(e)
  while true:
    let p = randomPrime(bits div 2, e)
    let q = randomPrime(bits div 2, e)
    if cmpB(p, q) == 0: continue
    let n = mulB(p, q)
    if bitLen(n) != bits: continue
    let one = small(1)
    let pm1 = subB(p, one)
    let qm1 = subB(q, one)
    let phi = mulB(pm1, qm1)
    # d: (1 + k phi) / e, k such that e divides it (e is small)
    let pe = int64(smallMod(phi, e))
    if pe == 0: continue
    let k = (int64(e) - invSmall(pe, int64(e))) mod int64(e)
    let (d, rem) = divmodB(addB(one, mulB(phi, small(uint64(k)))), eb)
    if rem.len != 0: continue
    let (pp, qq) = if cmpB(p, q) > 0: (p, q) else: (q, p)
    result = RsaKey(n: toBytes(n), e: toBytes(eb), d: toBytes(d), p: toBytes(pp), q: toBytes(qq),
                    dp: toBytes(modB(d, subB(pp, one))), dq: toBytes(modB(d, subB(qq, one))),
                    qinv: toBytes(powmod(qq, subB(pp, small(2)), pp)))
    return

# ---- SHA-256 --------------------------------------------------------------------------------

const K256 = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32, 0x3956c25b'u32, 0x59f111f1'u32,
  0x923f82a4'u32, 0xab1c5ed5'u32, 0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32, 0xe49b69c1'u32, 0xefbe4786'u32,
  0x0fc19dc6'u32, 0x240ca1cc'u32, 0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32, 0xc6e00bf3'u32, 0xd5a79147'u32,
  0x06ca6351'u32, 0x14292967'u32, 0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32, 0xa2bfe8a1'u32, 0xa81a664b'u32,
  0xc24b8b70'u32, 0xc76c51a3'u32, 0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32, 0x391c0cb3'u32, 0x4ed8aa4a'u32,
  0x5b9cca4f'u32, 0x682e6ff3'u32, 0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

proc sha256*(data: openArray[byte]): array[32, byte] =
  ## The SHA-256 digest of `data`.
  var h = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32, 0x510e527f'u32,
           0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  var tail: seq[byte]
  let full = data.len div 64 * 64
  for i in full ..< data.len: tail.add data[i]
  let bits = uint64(data.len) * 8
  tail.add 0x80
  while tail.len mod 64 != 56: tail.add 0
  for i in countdown(7, 0): tail.add byte((bits shr (8 * i)) and 0xFF)
  template rotr(x: uint32; n: int): uint32 = (x shr n) or (x shl (32 - n))
  var w: array[64, uint32]
  proc blockAt(h: var array[8, uint32]; w: var array[64, uint32]; get: proc (i: int): byte) =
    for i in 0 .. 15:
      w[i] = (uint32(get(4 * i)) shl 24) or (uint32(get(4 * i + 1)) shl 16) or
             (uint32(get(4 * i + 2)) shl 8) or uint32(get(4 * i + 3))
    for i in 16 .. 63:
      let s0 = rotr(w[i - 15], 7) xor rotr(w[i - 15], 18) xor (w[i - 15] shr 3)
      let s1 = rotr(w[i - 2], 17) xor rotr(w[i - 2], 19) xor (w[i - 2] shr 10)
      w[i] = w[i - 16] + s0 + w[i - 7] + s1
    var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
    for i in 0 .. 63:
      let S1 = rotr(e, 6) xor rotr(e, 11) xor rotr(e, 25)
      let ch = (e and f) xor ((not e) and g)
      let t1 = hh + S1 + ch + K256[i] + w[i]
      let S0 = rotr(a, 2) xor rotr(a, 13) xor rotr(a, 22)
      let maj = (a and b) xor (a and c) xor (b and c)
      let t2 = S0 + maj
      hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh
  let dp = if data.len > 0: cast[ptr UncheckedArray[byte]](unsafeAddr data[0]) else: nil
  var blk = 0
  while blk < full:
    let base = blk
    blockAt(h, w, proc (i: int): byte = dp[base + i])
    blk += 64
  var t = 0
  while t < tail.len:
    let base = t
    blockAt(h, w, proc (i: int): byte = tail[base + i])
    t += 64
  for i in 0 .. 7:
    for k in 0 .. 3: result[4 * i + k] = byte((h[i] shr (24 - 8 * k)) and 0xFF)

# ---- signatures ----------------------------------------------------------------------------

const sha256Prefix = [0x30'u8, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04,
                      0x02, 0x01, 0x05, 0x00, 0x04, 0x20]
  ## (DigestInfo: SHA-256)

proc sign*(k: RsaKey; data: openArray[byte]): seq[byte] =
  ## The PKCS #1 v1.5 signature (SHA-256) of `data` -- what
  ## `openssl dgst -sha256 -sign` makes.
  let nb = k.n.len
  let h = sha256(data)
  var em = newSeq[byte](nb)
  em[0] = 0
  em[1] = 1
  let tLen = sha256Prefix.len + 32
  if nb < tLen + 11: raise newException(RsaError, "the key is too small")
  for i in 2 ..< nb - tLen - 1: em[i] = 0xFF
  em[nb - tLen - 1] = 0
  for i, b in sha256Prefix: em[nb - tLen + i] = b
  for i in 0 ..< 32: em[nb - 32 + i] = h[i]
  let m = fromBytes(em)
  # (by the Chinese remainder: two half-size powers)
  let p = fromBytes(k.p)
  let q = fromBytes(k.q)
  var s: Big
  if p.len > 0 and q.len > 0 and k.dp.len > 0 and k.dq.len > 0 and k.qinv.len > 0:
    let m1 = powmod(m, fromBytes(k.dp), p)
    let m2 = powmod(m, fromBytes(k.dq), q)
    let m2p = modB(m2, p)
    let diff = if cmpB(m1, m2p) >= 0: subB(m1, m2p) else: subB(addB(m1, p), m2p)
    let hh = modB(mulB(fromBytes(k.qinv), diff), p)
    s = addB(m2, mulB(hh, q))
  else:
    s = powmod(m, fromBytes(k.d), fromBytes(k.n))
  toBytes(s, nb)

proc verify*(n, e: openArray[byte]; data, sig: openArray[byte]): bool =
  ## Whether `sig` is the PKCS #1 v1.5 SHA-256 signature of `data` by the
  ## key whose public part is `n`, `e`.
  let nn = fromBytes(n)
  let em = toBytes(powmod(fromBytes(sig), fromBytes(e), nn), n.len)
  let h = sha256(data)
  let tLen = sha256Prefix.len + 32
  if em.len != n.len or em[0] != 0 or em[1] != 1 or em[n.len - tLen - 1] != 0: return false
  for i in 2 ..< n.len - tLen - 1:
    if em[i] != 0xFF: return false
  for i, b in sha256Prefix:
    if em[n.len - tLen + i] != b: return false
  for i in 0 ..< 32:
    if em[n.len - 32 + i] != h[i]: return false
  true

# ---- DER ------------------------------------------------------------------------------------

proc derLen(n: int): seq[byte] =
  if n < 0x80: return @[byte(n)]
  var b: seq[byte]
  var v = n
  while v > 0:
    b.insert byte(v and 0xFF)
    v = v shr 8
  @[byte(0x80 or b.len)] & b

proc tlv(tag: byte; content: openArray[byte]): seq[byte] =
  result = @[tag] & derLen(content.len)
  result.add content

proc derSeq(parts: varargs[seq[byte]]): seq[byte] =
  var c: seq[byte]
  for p in parts: c.add p
  tlv(0x30, c)

proc derSet(parts: varargs[seq[byte]]): seq[byte] =
  var c: seq[byte]
  for p in parts: c.add p
  tlv(0x31, c)

proc derInt(be: openArray[byte]): seq[byte] =
  var v = @be
  while v.len > 1 and v[0] == 0 and (v[1] and 0x80) == 0: v.delete(0)
  if v.len == 0: v = @[0'u8]
  if (v[0] and 0x80) != 0: v.insert(0'u8)
  tlv(0x02, v)

proc derSmallInt(v: int): seq[byte] = derInt(toBytes(small(uint64(v))))

proc derOid(s: string): seq[byte] =
  let parts = s.split('.')
  var c = @[byte(parseInt(parts[0]) * 40 + parseInt(parts[1]))]
  for p in parts[2 .. ^1]:
    var v = parseInt(p)
    var b = @[byte(v and 0x7F)]
    v = v shr 7
    while v > 0:
      b.insert byte(0x80 or (v and 0x7F))
      v = v shr 7
    c.add b
  tlv(0x06, c)

proc derNull(): seq[byte] = @[0x05'u8, 0x00]

proc derBits(content: openArray[byte]): seq[byte] = tlv(0x03, @[0'u8] & @content)

proc derOctets(content: openArray[byte]): seq[byte] = tlv(0x04, content)

proc derUtf8(s: string): seq[byte] = tlv(0x0C, cast[seq[byte]](s))

proc derTime(t: DateTime): seq[byte] =
  ## (UTCTime before 2050, GeneralizedTime after: as X.509 wants)
  if t.year < 2050: tlv(0x17, cast[seq[byte]](t.format("yyMMddHHmmss") & "Z"))
  else: tlv(0x18, cast[seq[byte]](t.format("yyyyMMddHHmmss") & "Z"))

const
  oidRsa = "1.2.840.113549.1.1.1"
  oidSha256Rsa = "1.2.840.113549.1.1.11"

proc publicKeyDer*(k: RsaKey): seq[byte] =
  ## The public key as a SubjectPublicKeyInfo (what `openssl pkey -pubout
  ## -outform DER` writes).
  derSeq(derSeq(derOid(oidRsa), derNull()), derBits(derSeq(derInt(k.n), derInt(k.e))))

proc pkcs1Der(k: RsaKey): seq[byte] =
  derSeq(derSmallInt(0), derInt(k.n), derInt(k.e), derInt(k.d), derInt(k.p), derInt(k.q),
         derInt(k.dp), derInt(k.dq), derInt(k.qinv))

proc pkcs8Der*(k: RsaKey): seq[byte] =
  ## The private key as PKCS #8 DER (what apksigner's `--key` reads).
  derSeq(derSmallInt(0), derSeq(derOid(oidRsa), derNull()), derOctets(pkcs1Der(k)))

proc pem*(k: RsaKey): string =
  ## The private key as PEM (PKCS #8: "BEGIN PRIVATE KEY", as OpenSSL writes
  ## it today).
  let b = encode(cast[string](pkcs8Der(k)))
  result = "-----BEGIN PRIVATE KEY-----\n"
  var i = 0
  while i < b.len:
    result.add b[i ..< min(b.len, i + 64)] & "\n"
    i += 64
  result.add "-----END PRIVATE KEY-----\n"

proc nameDer(subject: string): seq[byte] =
  ## ("CN=retro debug, O=retro" -> a Name: written last part first, as
  ## X.509 keeps it, so that it reads back as given)
  var sets: seq[seq[byte]]
  for part in subject.split(','):
    let kv = part.strip.split('=', 1)
    if kv.len != 2: continue
    let oid = case kv[0].strip.toUpperAscii
              of "CN": "2.5.4.3"
              of "O": "2.5.4.10"
              of "OU": "2.5.4.11"
              of "C": "2.5.4.6"
              of "L": "2.5.4.7"
              of "ST", "S": "2.5.4.8"
              of "E": "1.2.840.113549.1.9.1"
              else: ""
    if oid.len == 0: continue
    let v = kv[1].strip
    let value = if oid in ["2.5.4.6", "1.2.840.113549.1.9.1"]: tlv(if oid == "2.5.4.6": 0x13 else: 0x16, v.toOpenArrayByte(0, v.len - 1))
                else: derUtf8(v)
    sets.insert derSet(derSeq(derOid(oid), value))
  var c: seq[byte]
  for s in sets: c.add s
  tlv(0x30, c)

proc selfSignedCert*(k: RsaKey; subject = "CN=retro debug, O=retro"; years = 30;
                     codeSigning = false): seq[byte] =
  ## A self-signed X.509 certificate (DER) of the key: what an APK carries.
  ## `codeSigning`: marked for signing code only (what Windows wants of an
  ## MSIX's or a program's certificate).
  var serial = newSeq[byte](8)
  if not urandom(serial): raise newException(RsaError, "no random numbers")
  serial[0] = serial[0] and 0x7F
  let now = now().utc
  var parts = @[tlv(0xA0, derSmallInt(2)), derInt(serial), derSeq(derOid(oidSha256Rsa), derNull()),
                nameDer(subject), derSeq(derTime(now), derTime(now + years.years)),
                nameDer(subject), publicKeyDer(k)]
  if codeSigning:
    let critical = @[0x01'u8, 0x01, 0xFF]
    let exts = derSeq(
      derSeq(derOid("2.5.29.15"), critical, derOctets(@[0x03'u8, 0x02, 0x07, 0x80])),  # digital signature
      derSeq(derOid("2.5.29.37"), derOctets(derSeq(derOid("1.3.6.1.5.5.7.3.3")))),       # code signing
      derSeq(derOid("2.5.29.19"), derOctets(derSeq())))                                  # not an authority
    parts.add tlv(0xA3, exts)
  let tbs = derSeq(parts)
  derSeq(tbs, derSeq(derOid(oidSha256Rsa), derNull()), derBits(k.sign(tbs)))

# ---- reading keys --------------------------------------------------------------------------

proc readTlv(b: openArray[byte]; at: var int): tuple[tag: byte; a, z: int] =
  ## (one element: its tag and where its content is; `at` moved past it)
  if at + 2 > b.len: raise newException(RsaError, "the key is damaged")
  let tag = b[at]
  var len = int(b[at + 1])
  var p = at + 2
  if (len and 0x80) != 0:
    let n = len and 0x7F
    if n == 0 or n > 4 or p + n > b.len: raise newException(RsaError, "the key is damaged")
    len = 0
    for i in 0 ..< n: len = (len shl 8) or int(b[p + i])
    p += n
  if p + len > b.len: raise newException(RsaError, "the key is damaged")
  at = p + len
  (tag, p, p + len)

proc readPkcs1(b: openArray[byte]): RsaKey =
  var at = 0
  let s = readTlv(b, at)
  if s.tag != 0x30: raise newException(RsaError, "not an RSA key")
  var p = s.a
  var nums: seq[seq[byte]]
  while p < s.z and nums.len < 9:
    let e = readTlv(b, p)
    if e.tag != 0x02: raise newException(RsaError, "not an RSA key")
    var v = b[e.a ..< e.z]
    while v.len > 1 and v[0] == 0: v.delete(0)
    nums.add v
  if nums.len < 9: raise newException(RsaError, "not an RSA key")
  RsaKey(n: nums[1], e: nums[2], d: nums[3], p: nums[4], q: nums[5], dp: nums[6], dq: nums[7], qinv: nums[8])

proc readRsaKey*(pemText: string): RsaKey =
  ## A private key from PEM: PKCS #8 ("BEGIN PRIVATE KEY") or PKCS #1
  ## ("BEGIN RSA PRIVATE KEY"), unencrypted. Raises `RsaError`.
  var body = ""
  var inside = false
  var pkcs1 = false
  for line in pemText.splitLines:
    let l = line.strip
    if l.startsWith("-----BEGIN"):
      inside = true
      pkcs1 = "RSA PRIVATE KEY" in l
      if "ENCRYPTED" in l: raise newException(RsaError, "the key is encrypted (a password): not supported")
      continue
    if l.startsWith("-----END"): break
    if inside: body.add l
  if body.len == 0: raise newException(RsaError, "no key in the file")
  let der = try: cast[seq[byte]](unbase64(body))
            except ValueError: raise newException(RsaError, "the key's PEM is damaged")
  if pkcs1: return readPkcs1(der)
  # PKCS #8: version, the algorithm, an OCTET STRING with the PKCS #1 key
  var at = 0
  let s = readTlv(der, at)
  if s.tag != 0x30: raise newException(RsaError, "not a private key")
  var p = s.a
  discard readTlv(der, p)                 # (version)
  discard readTlv(der, p)                 # (algorithm)
  let o = readTlv(der, p)
  if o.tag != 0x04: raise newException(RsaError, "not an RSA key")
  readPkcs1(der[o.a ..< o.z])
