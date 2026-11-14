## retroui/apkinfo: an APK made by Google's aapt2 read as Android reads it
## (its label and version from its resources, the densest icon); damaged
## and cut manifests and tables never stop the program.

import std/[os, random, strutils]
import retroui/[apkinfo, zip]

const apk = currentSourcePath().parentDir / "data" / "apk" / "notes.apk"

block aapt2:
  let a = readApk(apk)
  doAssert a.ok, a.error
  doAssert a.package == "net.example.notes", a.package
  doAssert a.label == "Example Notes", a.label            # (the default language's, not Arabic's)
  doAssert a.versionName == "2.3.1-beta" and a.versionCode == 1204, a.versionName & " " & $a.versionCode
  doAssert a.minSdk == 21 and a.targetSdk == 34
  doAssert a.permissions == @["android.permission.CAMERA", "android.permission.INTERNET"], $a.permissions
  doAssert a.activities == 2 and a.services == 1
  doAssert a.abis.len == 0
  # (the PNG of the densest screen, ahead of the adaptive icon's layer)
  doAssert a.icon.startsWith("\x89PNG")
  var want = ""
  for e in zipEntries(apk):
    if e.name == "res/mipmap-xxhdpi-v4/ic_launcher.png": want = readEntry(apk, e)
  doAssert a.icon == want

block notAnApk:
  let p = getTempDir() / "retro-apkinfo-not.apk"
  writeFile(p, "not a zip at all")
  let a = readApk(p)
  doAssert not a.ok and a.error.len > 0
  removeFile(p)
  doAssert not readApk(getTempDir() / "no such file.apk").ok

block damaged:
  var manifest, table = ""
  for e in zipEntries(apk):
    if e.name == "AndroidManifest.xml": manifest = readEntry(apk, e)
    if e.name == "resources.arsc": table = readEntry(apk, e)
  doAssert apkFrom(manifest, table).label == "Example Notes"
  var r = initRand(50)
  for i in 0 ..< 3000:
    var m = manifest
    var t = table
    for _ in 0 ..< r.rand(1 .. 8):
      if m.len > 0: m[r.rand(m.high)] = char(r.rand(255))
      if t.len > 0: t[r.rand(t.high)] = char(r.rand(255))
    discard apkFrom(m[0 ..< r.rand(m.len)], t, [], proc (n: string): string = manifest)
    discard apkFrom(m, t[0 ..< r.rand(t.len)])
  doAssert not apkFrom("", "").ok

echo "apkinfo tests passed"
