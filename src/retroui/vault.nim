## Files only a password opens: authenticated encryption (XChaCha20 and
## Poly1305) with a key made from the password by Argon2id, from
## Monocypher (an audited C library, compiled in: no dependency).
##
## .. code-block:: nim
##   let key = newVaultKey("4712")              # (slow on purpose: ~0.2 s)
##   writeFile("data.vault", key.seal(secretText))
##   let back = vaultKeyFor(readFile("data.vault"), "4712").unseal(readFile("data.vault"))
##
## A sealed file starts with "RVAULT1", then the Argon2 settings, the salt,
## the nonce, the tag and the encrypted bytes. A wrong password or a changed
## byte anywhere raises `VaultError`; nothing half-decrypted comes out.

import std/[sysrand, strutils]

{.compile("vendor/monocypher.c", "-O2").}
{.compile("vendor/monocypher-ed25519.c", "-O2").}
  # (here once: the modules that sign and check with Ed25519 -- updates, mail
  # signatures -- import this one; compiled twice, a program would not link.
  # -O2 always: a debug build's C is otherwise unoptimized, and an encrypted
  # database (retroui/db) six times slower)

proc crypto_ed25519_key_pair*(secretKey: ptr array[64, byte]; publicKey: ptr array[32, byte];
                              seed: ptr array[32, byte]) {.importc, cdecl.}
  ## (Monocypher: a key pair from a 32-byte seed, which it wipes)
proc crypto_ed25519_sign*(sig: ptr array[64, byte]; secretKey: ptr array[64, byte];
                          msg: pointer; len: csize_t) {.importc, cdecl.}
  ## (Monocypher: an Ed25519 signature, RFC 8032)
proc crypto_ed25519_check*(sig: ptr array[64, byte]; publicKey: ptr array[32, byte];
                           msg: pointer; len: csize_t): cint {.importc, cdecl.}
  ## (Monocypher: 0 when `sig` is the key's signature of the message)

type
  VaultError* = object of CatchableError
    ## Not a sealed file, a wrong password, a damaged file, or no random
    ## numbers to be had.
  VaultKey* = object
    ## A key made from a password and a salt (keep it while the app runs,
    ## so saving does not ask Argon2 again).
    key: array[32, byte]
    salt: array[16, byte]
    blocks, passes: uint32
  Argon2Config {.bycopy.} = object
    algorithm, nb_blocks, nb_passes, nb_lanes: uint32
  Argon2Inputs {.bycopy.} = object
    pass, salt: ptr byte
    pass_size, salt_size: uint32
  Argon2Extras {.bycopy.} = object
    key, ad: ptr byte
    key_size, ad_size: uint32

proc crypto_argon2(hash: ptr byte; hashSize: uint32; work: pointer; config: Argon2Config;
                   inputs: Argon2Inputs; extras: Argon2Extras) {.importc, cdecl.}
proc crypto_aead_lock(cipher, mac, key, nonce, ad: ptr byte; adSize: csize_t;
                      plain: ptr byte; size: csize_t) {.importc, cdecl.}
proc crypto_aead_unlock(plain, mac, key, nonce, ad: ptr byte; adSize: csize_t;
                        cipher: ptr byte; size: csize_t): cint {.importc, cdecl.}
proc crypto_wipe(p: pointer; size: csize_t) {.importc, cdecl.}

const
  Magic = "RVAULT1"
  HeadLen = Magic.len + 8 + 16 + 24 + 16    ## magic, blocks, passes, salt, nonce, tag
  DefaultBlocks = 16384'u32                 ## 16 MB of memory for Argon2
  DefaultPasses = 3'u32

proc derive(password: string; salt: array[16, byte]; blocks, passes: uint32): array[32, byte] =
  if blocks < 8 or blocks > 1 shl 20 or passes < 1 or passes > 16:
    raise newException(VaultError, "the file's key settings are damaged")
  var work = newSeq[byte](int(blocks) * 1024)
  var pw = password
  let config = Argon2Config(algorithm: 2, nb_blocks: blocks, nb_passes: passes, nb_lanes: 1)
  let inputs = Argon2Inputs(pass: (if pw.len > 0: cast[ptr byte](addr pw[0]) else: nil),
                            salt: unsafeAddr salt[0], pass_size: uint32(pw.len),
                            salt_size: 16)
  crypto_argon2(addr result[0], 32, addr work[0], config, inputs, Argon2Extras())
  crypto_wipe(addr work[0], csize_t(work.len))

proc newVaultKey*(password: string; blocks = DefaultBlocks; passes = DefaultPasses): VaultKey =
  ## A new key from `password`, with a fresh random salt (for a new file,
  ## or a new password).
  if not urandom(result.salt): raise newException(VaultError, "no random numbers")
  result.blocks = blocks
  result.passes = passes
  result.key = derive(password, result.salt, blocks, passes)

proc isSealed*(data: string): bool =
  ## `data` is a sealed file (it starts as one).
  data.len >= HeadLen and data.startsWith(Magic)

proc rd32(s: string; i: int): uint32 =
  uint32(ord(s[i])) or (uint32(ord(s[i+1])) shl 8) or (uint32(ord(s[i+2])) shl 16) or
    (uint32(ord(s[i+3])) shl 24)

proc vaultKeyFor*(sealed, password: string): VaultKey =
  ## The key of the sealed `sealed` for `password` (its salt and settings
  ## are in it). A wrong password shows when unsealing.
  if not isSealed(sealed): raise newException(VaultError, "not a sealed file")
  var p = Magic.len
  result.blocks = rd32(sealed, p)
  result.passes = rd32(sealed, p + 4)
  p += 8
  for i in 0 ..< 16: result.salt[i] = byte(sealed[p + i])
  result.key = derive(password, result.salt, result.blocks, result.passes)

proc matches*(k: VaultKey; sealed: string): bool =
  ## `sealed` was made with this key's salt and settings (then `k` can
  ## open it without asking Argon2 again).
  if not isSealed(sealed): return false
  var p = Magic.len
  if rd32(sealed, p) != k.blocks or rd32(sealed, p + 4) != k.passes: return false
  p += 8
  for i in 0 ..< 16:
    if byte(sealed[p + i]) != k.salt[i]: return false
  true

proc seal*(k: VaultKey; plain: string): string =
  ## `plain` encrypted with `k` (a new random nonce every time).
  var nonce: array[24, byte]
  if not urandom(nonce): raise newException(VaultError, "no random numbers")
  result = newString(HeadLen + plain.len)
  for i, c in Magic: result[i] = c
  var p = Magic.len
  for i in 0 .. 3: result[p + i] = char((k.blocks shr (8 * i)) and 0xFF)
  for i in 0 .. 3: result[p + 4 + i] = char((k.passes shr (8 * i)) and 0xFF)
  p += 8
  for i in 0 ..< 16: result[p + i] = char(k.salt[i])
  p += 16
  for i in 0 ..< 24: result[p + i] = char(nonce[i])
  p += 24
  let macAt = p
  let dataAt = p + 16
  var key = k.key
  # the header (magic, settings, salt) is authenticated too
  var ad = result[0 ..< Magic.len + 8 + 16]
  crypto_aead_lock(cast[ptr byte](if plain.len > 0: addr result[dataAt] else: nil),
                   cast[ptr byte](addr result[macAt]), addr key[0], addr nonce[0],
                   cast[ptr byte](addr ad[0]), csize_t(ad.len),
                   cast[ptr byte](if plain.len > 0: unsafeAddr plain[0] else: nil),
                   csize_t(plain.len))
  crypto_wipe(addr key[0], 32)

proc unseal*(k: VaultKey; sealed: string): string =
  ## The plain text of `sealed`; `VaultError` when the key (the password)
  ## is wrong or the file was changed or cut.
  if not isSealed(sealed): raise newException(VaultError, "not a sealed file")
  let nonceAt = Magic.len + 8 + 16
  let macAt = nonceAt + 24
  let dataAt = macAt + 16
  let n = sealed.len - dataAt
  result = newString(n)
  var key = k.key
  var s = sealed
  var ad = s[0 ..< Magic.len + 8 + 16]
  let r = crypto_aead_unlock(cast[ptr byte](if n > 0: addr result[0] else: nil),
                             cast[ptr byte](addr s[macAt]), addr key[0],
                             cast[ptr byte](addr s[nonceAt]),
                             cast[ptr byte](addr ad[0]), csize_t(ad.len),
                             cast[ptr byte](if n > 0: addr s[dataAt] else: nil), csize_t(n))
  crypto_wipe(addr key[0], 32)
  if r != 0:
    result = ""
    raise newException(VaultError, "wrong password, or the file is damaged")

proc wipe*(k: var VaultKey) =
  ## Forget the key (when the app locks).
  crypto_wipe(addr k.key[0], 32)

proc vaultKeyFromBytes*(raw: openArray[byte]): VaultKey =
  ## A key of 32 random bytes kept elsewhere (in a file only the user may
  ## read: `retroui/secrets`), with no password and no Argon2. What it seals
  ## no password opens.
  if raw.len != 32: raise newException(VaultError, "a key is 32 bytes")
  for i in 0 ..< 32: result.key[i] = raw[i]
