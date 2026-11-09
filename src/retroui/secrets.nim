## Small secrets -- sign-in tokens, an API's key -- kept where other users
## and other programs cannot read them, each under the app's name and a
## name of its own:
##
## - **Windows:** DPAPI (CryptProtectData): only this user, on this
##   computer, can open them; the sealed bytes are in the app's data folder.
## - **macOS:** the login keychain (through /usr/bin/security), as generic
##   passwords of the service "retro.<app>".
## - **Linux, BSD:** the desktop's keyring through secret-tool (libsecret)
##   when it is installed and works; else a file in the app's data folder,
##   encrypted (XChaCha20-Poly1305, see `retroui/vault`) with a random key
##   kept in a file only this user may read.
## - **Android:** the app's private folder, encrypted the same way.
##
## .. code-block:: nim
##   if not saveSecret("Retro Mail", "account 1", $(%tokens)): echo "not saved"
##   let saved = loadSecret("Retro Mail", "account 1")    # "" when none
##   deleteSecret("Retro Mail", "account 1")
##
## The files are in `dataDir(app) / "Secrets"`. For tests,
## `RETRO_SECRETS_DIR` in the environment keeps them in that folder
## instead (a folder for each app), as files also where a keyring or the
## keychain is there.
##
## Safe on any thread.

import std/[os, strutils, locks]
import uirelays/target   # (androidApp: an APK, not a program in Termux)
import uirelays/services, sha2
when defined(windows):
  import std/widestrs
else:
  import std/[posix, sysrand]
  import vault
  when not androidApp and not defined(ios):
    import std/[osproc, streams]

var secretsLock: Lock
initLock(secretsLock)

proc folderOf(app: string; make = false): string =
  ## The app's folder of secrets (with `make`, made when missing: only for
  ## this user).
  let over = getEnv("RETRO_SECRETS_DIR")
  if over.len > 0:
    result = over / app
  else:
    {.cast(gcsafe).}:
      result = services.dataDir(app) / "Secrets"
  if make and not dirExists(result):
    try:
      createDir(result)
      when not defined(windows):
        setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})
    except OSError: discard

proc fileOf(app, name: string; make = false): string =
  ## The file of the secret `name`: its name with letters, digits and
  ## `-_.` kept, the rest as %XX (a long one cut, with its hash after).
  const hex = "0123456789ABCDEF"
  var n = ""
  for i, c in name:
    if c in {'A'..'Z', 'a'..'z', '0'..'9', '-', '_'} or (c == '.' and i > 0): n.add c
    else:
      n.add '%'
      n.add hex[ord(c) shr 4]
      n.add hex[ord(c) and 15]
  if n.len > 120: n = n[0 ..< 80] & "-" & sha256Hex(name)[0 ..< 32]
  folderOf(app, make) / n & ".secret"

proc replaceFile(path, data: string): bool =
  ## Writes `path` whole or not at all (through a new file only this user
  ## may read, moved into place).
  let tmp = path & ".new"
  try: removeFile(tmp) except OSError: discard
  when defined(windows):
    try: writeFile(tmp, data)
    except IOError: return false
  else:
    let fd = posix.open(tmp.cstring, O_WRONLY or O_CREAT or O_EXCL, Mode(0o600))
    if fd < 0: return false
    var at = 0
    while at < data.len:
      let n = posix.write(fd, unsafeAddr data[at], data.len - at)
      if n <= 0: break
      at += n
    if posix.close(fd) != 0 or at < data.len:
      try: removeFile(tmp) except OSError: discard
      return false
  try:
    moveFile(tmp, path)
    true
  except OSError:
    try: removeFile(tmp) except OSError: discard
    false

proc readSmall(path: string): string =
  try: readFile(path) except IOError, OSError: ""

# ---- Windows: DPAPI ----------------------------------------------------------------------

when defined(windows):
  type DataBlob {.bycopy.} = object
    size: uint32
    data: pointer

  proc CryptProtectData(input: ptr DataBlob; descr: WideCString; entropy: ptr DataBlob;
                        reserved, prompt: pointer; flags: uint32; output: ptr DataBlob): int32 {.
                        stdcall, dynlib: "crypt32.dll", importc.}
  proc CryptUnprotectData(input: ptr DataBlob; descr: pointer; entropy: ptr DataBlob;
                          reserved, prompt: pointer; flags: uint32; output: ptr DataBlob): int32 {.
                          stdcall, dynlib: "crypt32.dll", importc.}
  proc LocalFree(p: pointer): pointer {.stdcall, dynlib: "kernel32.dll", importc.}

  const uiForbidden = 1'u32

  proc blobOf(s: string): DataBlob =
    DataBlob(size: uint32(s.len), data: (if s.len > 0: unsafeAddr s[0] else: nil))

  proc dpapi(data, entropy: string; protect: bool): tuple[ok: bool; data: string] =
    ## `data` sealed (or opened) for this user; the entropy ties it to its
    ## app and name.
    var input = blobOf(data)
    var extra = blobOf(entropy)
    var output: DataBlob
    let ok = if protect:
               CryptProtectData(addr input, newWideCString("retro"), addr extra, nil, nil,
                                uiForbidden, addr output)
             else:
               CryptUnprotectData(addr input, nil, addr extra, nil, nil, uiForbidden, addr output)
    if ok == 0: return (false, "")
    result.ok = true
    result.data = newString(int(output.size))
    if output.size > 0: copyMem(addr result.data[0], output.data, int(output.size))
    discard LocalFree(output.data)

# ---- the encrypted files (Linux, BSD, Android; where no keyring works) -----------------

when not defined(windows):
  proc keyOf(app: string): string =
    ## The app's 32 random bytes that encrypt its secrets, made the first
    ## time; "" when there is no way to keep them.
    let path = folderOf(app, make = true) / "key"
    result = readSmall(path)
    if result.len == 32: return
    var raw = newString(32)
    if not urandom(raw.toOpenArrayByte(0, 31)): result = ""; return
    if not replaceFile(path, raw): result = ""; return
    result = readSmall(path)
    if result.len != 32: result = ""

  proc sealFile(app, name, value: string): bool =
    let key = keyOf(app)
    if key.len != 32: return false
    try:
      let k = vaultKeyFromBytes(key.toOpenArrayByte(0, 31))
      # (the name inside too: a file moved under another name does not open)
      replaceFile(fileOf(app, name, make = true), k.seal(name & "\0" & value))
    except VaultError:
      false

  proc openFile(app, name: string): string =
    let data = readSmall(fileOf(app, name))
    if data.len == 0: return ""
    let key = readSmall(folderOf(app) / "key")
    if key.len != 32: return ""
    try:
      let plain = vaultKeyFromBytes(key.toOpenArrayByte(0, 31)).unseal(data)
      if plain.startsWith(name & "\0"): plain[name.len + 1 .. ^1] else: ""
    except VaultError:
      ""

# ---- macOS keychain, Linux keyring --------------------------------------------------------

when not defined(windows) and not androidApp and not defined(ios):
  var keyringBroken = false              # guarded by secretsLock: secret-tool failed

  proc toHexText(s: string): string =
    ## (the keychain and the keyring keep text: any bytes go as hex)
    for c in s: result.add toHex(ord(c), 2)

  proc fromHexText(s: string): string =
    let t = s.strip
    if t.len mod 2 != 0: return ""
    for i in countup(0, t.len - 2, 2):
      try: result.add char(parseHexInt(t[i .. i + 1]))
      except ValueError: result = ""; return

  proc run(tool: string; args: openArray[string]; input = ""): tuple[output: string; code: int] =
    ## Runs `tool` with `args` (`input` on its standard input) and waits;
    ## code -1 when it would not run or took over two minutes (a keyring
    ## that asks for its password waits for the user).
    try:
      let p = startProcess(tool, args = args, options = {poStdErrToStdOut})
      if input.len > 0: p.inputStream.write(input)
      p.inputStream.close()
      result.output = p.outputStream.readAll()
      result.code = p.waitForExit(120_000)
      p.close()
    except OSError, IOError:
      result = ("", -1)

  proc filesOnly(): bool = getEnv("RETRO_SECRETS_DIR").len > 0

  when defined(macosx):
    const security = "/usr/bin/security"

    proc keychainSave(app, name, value: string): bool =
      run(security, ["add-generic-password", "-U", "-a", name, "-s", "retro." & app,
                     "-l", app & ": " & name, "-w", toHexText(value)]).code == 0

    proc keychainLoad(app, name: string; found: var bool): string =
      let r = run(security, ["find-generic-password", "-a", name, "-s", "retro." & app, "-w"])
      found = r.code == 0
      if found: result = fromHexText(r.output)

    proc keychainDelete(app, name: string) =
      discard run(security, ["delete-generic-password", "-a", name, "-s", "retro." & app])

  else:
    proc secretTool(): string =
      ## The path of secret-tool when it is there and has not failed.
      withLock secretsLock:
        if keyringBroken: return ""
      findExe("secret-tool")

    proc keyringFailed() =
      withLock secretsLock: keyringBroken = true

    proc keyringSave(app, name, value: string): bool =
      let tool = secretTool()
      if tool.len == 0: return false
      let r = run(tool, ["store", "--label=" & app & ": " & name, "service", "retro." & app,
                         "account", name], toHexText(value))
      result = r.code == 0
      if not result: keyringFailed()

    proc keyringLoad(app, name: string; found: var bool): string =
      found = false
      let tool = secretTool()
      if tool.len == 0: return ""
      let r = run(tool, ["lookup", "service", "retro." & app, "account", name])
      if r.code == 0:
        found = true
        result = fromHexText(r.output)
      elif r.output.strip.len > 0:          # (not "none there": it did not work)
        keyringFailed()

    proc keyringDelete(app, name: string) =
      let tool = secretTool()
      if tool.len > 0: discard run(tool, ["clear", "service", "retro." & app, "account", name])

# ---- the API ------------------------------------------------------------------------------

proc saveSecret*(app, name, value: string): bool {.gcsafe.} =
  ## Keeps `value` as the secret `name` of `app` (replacing one of that
  ## name); false when it could not be kept.
  if app.len == 0 or name.len == 0: return false
  {.cast(gcsafe).}:
    when defined(windows):
      # (a byte before the value: DPAPI may refuse an empty one)
      let (ok, sealed) = dpapi("v" & value, "retro." & app & "\0" & name, true)
      if not ok: return false
      withLock secretsLock:
        result = replaceFile(fileOf(app, name, make = true), sealed)
    elif androidApp or defined(ios):
      withLock secretsLock:
        result = sealFile(app, name, value)
    else:
      if not filesOnly():
        when defined(macosx):
          if keychainSave(app, name, value):
            try: removeFile(fileOf(app, name)) except OSError: discard
            return true
        else:
          if keyringSave(app, name, value):
            try: removeFile(fileOf(app, name)) except OSError: discard
            return true
      withLock secretsLock:
        result = sealFile(app, name, value)

proc loadSecret*(app, name: string): string {.gcsafe.} =
  ## The secret `name` of `app`; "" when there is none (or it cannot be
  ## opened: another user's, another computer's).
  if app.len == 0 or name.len == 0: return ""
  {.cast(gcsafe).}:
    when defined(windows):
      var sealed: string
      withLock secretsLock:
        sealed = readSmall(fileOf(app, name))
      if sealed.len == 0: return ""
      let (ok, plain) = dpapi(sealed, "retro." & app & "\0" & name, false)
      if ok and plain.startsWith("v"): result = plain[1 .. ^1]
    elif androidApp or defined(ios):
      withLock secretsLock:
        result = openFile(app, name)
    else:
      if not filesOnly():
        var found = false
        when defined(macosx):
          result = keychainLoad(app, name, found)
        else:
          result = keyringLoad(app, name, found)
        if found: return
      withLock secretsLock:
        result = openFile(app, name)

proc deleteSecret*(app, name: string) {.gcsafe.} =
  ## Forgets the secret `name` of `app` (nothing happens when there is
  ## none).
  if app.len == 0 or name.len == 0: return
  {.cast(gcsafe).}:
    when not defined(windows) and not androidApp and not defined(ios):
      if not filesOnly():
        when defined(macosx): keychainDelete(app, name)
        else: keyringDelete(app, name)
    withLock secretsLock:
      try: removeFile(fileOf(app, name)) except OSError: discard
