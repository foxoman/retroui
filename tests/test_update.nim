## retroui/update: Ed25519 as RFC 8032 has it, signing and checking, a
## changed byte refused, versions compared, and an update found, checked
## and downloaded from a small server here (Python's http.server).

import std/[os, osproc, strutils, json, base64]
import retroui/[update, sha2]

proc unhex(h: string): string =
  for i in countup(0, h.high, 2): result.add char(parseHexInt(h[i .. i + 1]))

block rfc8032:
  # (test 1 of RFC 8032: the empty message)
  let seed = encode(unhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"))
  let public = publicKeyOf(seed)
  doAssert public == encode(unhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"))
  let sig = signUpdate("", seed)
  doAssert sig == encode(unhex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"))
  doAssert verifyUpdate("", sig, public)

block signing:
  let (secret, public) = newUpdateKeys()
  doAssert publicKeyOf(secret) == public
  let text = "{\"version\": \"2.0.0\"}"
  let sig = signUpdate(text, secret)
  doAssert verifyUpdate(text, sig, public)
  doAssert not verifyUpdate(text & " ", sig, public)              # a byte more
  var other = text
  other[3] = 'V'
  doAssert not verifyUpdate(other, sig, public)                   # a byte changed
  doAssert not verifyUpdate(text, sig, newUpdateKeys().public)    # another key
  doAssert not verifyUpdate(text, "not base64!", public)
  doAssert not verifyUpdate(text, encode("short"), public)

block versions:
  doAssert newerVersion("1.10.0", "1.9.2")
  doAssert newerVersion("2.0", "1.99.99")
  doAssert not newerVersion("1.2.0", "1.2.0")
  doAssert newerVersion("1.2.1", "1.2")
  doAssert newerVersion("v1.3.0", "1.2.9")
  doAssert newerVersion("1.0.0", "1.0.0-beta.2")
  doAssert not newerVersion("1.0.0-beta.2", "1.0.0")
  doAssert newerVersion("1.0.0-beta.3", "1.0.0-beta.2")
  doAssert updatePlatform().startsWith(when defined(wasm): "web" else: "linux-")

block fromAServer:
  if defined(wasm) or findExe("python3").len == 0:
    echo "(no python3: the server part skipped)"
  else:
    let dir = getTempDir() / "retro-update-test"
    removeDir(dir)
    createDir(dir)
    let (secret, public) = newUpdateKeys()
    let payload = "the new version\n" & "x".repeat(5000)
    writeFile(dir / "Notes-2.0.0.AppImage", payload)
    let port = 8791
    let plat = updatePlatform()
    var j = %*{"version": "2.0.0", "notes": "Faster.",
               "files": {plat: {"url": "http://127.0.0.1:" & $port & "/Notes-2.0.0.AppImage",
                                "size": payload.len, "sha256": sha256(payload).toHex.toLowerAscii}}}
    let text = j.pretty
    writeFile(dir / "update.json", text)
    writeFile(dir / "update.json.sig", signUpdate(text, secret))
    let server = startProcess("python3", args = ["-m", "http.server", $port, "--bind", "127.0.0.1"],
                              workingDir = dir, options = {poUsePath, poStdErrToStdOut})
    try:
      sleep(800)
      let url = "http://127.0.0.1:" & $port & "/update.json"
      var u = checkForUpdate(url, public, "1.4.0")
      doAssert u.error == "" and u.available and u.version == "2.0.0" and u.notes == "Faster.", $u
      doAssert not checkForUpdate(url, public, "2.0.0").available         # (this one is the newest)
      doAssert not checkForUpdate(url, public, "1.0", platform = "nowhere-z80").available
      let wrong = checkForUpdate(url, newUpdateKeys().public, "1.4.0")
      doAssert not wrong.available and "signature" in wrong.error, wrong.error
      let got = downloadUpdate(u, dir / "down")
      doAssert readFile(got) == payload
      # (the file on the server changed: refused)
      writeFile(dir / "Notes-2.0.0.AppImage", payload.replace("new", "bad"))
      var refused = false
      try: discard downloadUpdate(u, dir / "down2")
      except UpdateError: refused = true
      doAssert refused
      doAssert not fileExists(dir / "down2" / "Notes-2.0.0.AppImage")
      # (update.json changed after it was signed: refused)
      writeFile(dir / "update.json", text.replace("Faster.", "Slower."))
      doAssert "signature" in checkForUpdate(url, public, "1.4.0").error
    finally:
      server.terminate()
      discard server.waitForExit()
      server.close()
      removeDir(dir)

block pieces:
  # a file cut where its bytes say: a change in one place leaves the pieces
  # after it as they were, so an update fetches little more than the change
  var r = 12345'u32
  proc rnd(n: int): string =
    for _ in 0 ..< n:
      r = r * 1103515245'u32 + 12345'u32
      result.add char((r shr 16) and 255)
  let old = rnd(900_000)
  let newer = old[0 ..< 300_000] & rnd(5000) & old[300_000 .. ^1]   # (5 KB put in)
  let cs = chunksOf(newer)
  var total = 0
  for c in cs:
    total += c.size
    doAssert c.size <= 256 * 1024 and c.hash.len == 32
  doAssert total == newer.len and cs.len >= 4, $cs.len
  doAssert chunksOf(newer) == cs, "the same cuts every time"
  var asked: seq[(int, int)]
  let made = assembleUpdate(cs, [old], proc (first, last: int): string =
    asked.add (first, last)
    newer[first .. last])
  doAssert made.data == newer
  doAssert made.fetched < 200_000 and asked.len == 1, $made.fetched & " " & $asked
  # with nothing to start from: all of it, in one request
  asked.setLen(0)
  let all = assembleUpdate(cs, [], proc (first, last: int): string =
    asked.add (first, last)
    newer[first .. last])
  doAssert all.data == newer and all.fetched == newer.len and asked == @[(0, newer.len - 1)]
  # a part that is not what was asked: refused
  try:
    discard assembleUpdate(cs, [], proc (first, last: int): string = "short")
    doAssert false
  except UpdateError: discard

echo "update tests passed"
