## retroui/native: the Java bridge's messages (against a fake Java side that
## answers as tools/android/RetroNative.java does), shared libraries, and
## the same-everywhere calls on the computer the test runs on.

import std/[strutils, posix]
import retroui/native
import retroui/uirelays/services

# ---- a fake Java side -----------------------------------------------------------------------------

proc unescape(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      inc i
      result.add(case s[i]
                 of 't': '\t'
                 of 'n': '\n'
                 of 'r': '\r'
                 of '0': '\0'
                 else: s[i])
    else: result.add s[i]
    inc i

var
  log: seq[tuple[name: string; fields: seq[string]]]
  kept: seq[int]
  nextId = 1
  javaThere = true

systemRelays.call = proc (name, arg: string): string {.gcsafe, nimcall.} =
  {.cast(gcsafe).}:
    if not javaThere: return "\0"
    var fields: seq[string]
    for f in arg.split('\t'): fields.add unescape(f)
    log.add (name, fields)
    case name
    of "native.ping": "s1"
    of "native.count": "s" & $kept.len
    of "native.release":
      for f in fields:
        if f.len > 0: kept.delete(kept.find(parseInt(f)))
      "n"
    of "native.new":
      kept.add nextId
      inc nextId
      "h" & $(nextId - 1)
    of "native.static":
      case fields[1]
      of "MODEL": "sPixel 9"
      of "MANUFACTURER": "sGoogle"
      of "RELEASE": "s15"
      of "SDK_INT": "s35"
      of "echo": "s" & fields[3][1 .. ^1]            # (the first argument's text)
      of "makeText":
        kept.add nextId
        inc nextId
        "h" & $(nextId - 1)
      else: "eNoSuchMethodException: " & fields[0] & "." & fields[1]
    of "native.method":
      if fields[2].contains('h'):
        kept.add nextId
        inc nextId
        "h" & $(nextId - 1)
      else: "n"
    else: "\0"

proc last(): seq[string] = log[^1].fields

# ---- the bridge ---------------------------------------------------------------------------------

block bridge:
  doAssert javaAvailable()
  doAssert javaStatic("android.os.Build", "MODEL") == "Pixel 9" and javaError() == ""
  doAssert log[^1].name == "native.static" and last()[0 .. 2] == @["android.os.Build", "MODEL", ""]
  # every kind of argument, typed by its first letter
  discard javaStatic("x.Y", "m", "text", 7, jlong(8), 2.5, jfloat(1.5), true, jnull, jactivity())
  doAssert last()[3 .. ^1] == @["stext", "i7", "l8", "d2.5", "f1.5", "b1", "n", "a"], $last()
  when sizeof(int) == 8:
    discard javaStatic("x.Y", "m", 1 shl 40, false, int32(-3))
    doAssert last()[3 .. ^1] == @["i1099511627776", "b0", "i-3"]
  else:
    discard javaStatic("x.Y", "m", 1 shl 30, false, int32(-3))
    doAssert last()[3 .. ^1] == @["i1073741824", "b0", "i-3"]
  # any string travels as it is: tabs, newlines, backslashes, NUL, Unicode
  let tricky = "a\tb\nc\r\\d \0e ä ع 😀 \\t"
  doAssert javaStatic("x.Y", "echo", tricky) == tricky
  doAssert javaStatic("x.Y", "echo", "") == ""
  # errors: "" and the reason
  doAssert javaStatic("x.Y", "nothing") == "" and "NoSuchMethod" in javaError()
  doAssert javaStatic("android.os.Build", "MODEL") == "Pixel 9" and javaError() == ""
  # objects: kept on the Java side, passed back, released
  let o = javaNew("android.content.Intent", "android.settings.SETTINGS")
  doAssert not o.isNil and javaKept() == 1
  discard javaCall(o, "setAction", "x")
  doAssert last()[0] == "o" & $int(o) and last()[1] == "setAction"
  let p = javaCallObj(o, "clone")
  doAssert not p.isNil and p != o and javaKept() == 2
  discard javaActivity("startActivity", o)
  doAssert last()[0] == "a" and last()[3] == "o" & $int(o)
  javaRelease(o, p, JObject(0))
  doAssert javaKept() == 0
  # a null object is not sent
  let before = log.len
  doAssert javaCall(JObject(0), "x") == "" and javaError().len > 0 and log.len == before
  # the UI thread
  onUiThread:
    discard javaActivity("getWindow")
  doAssert last()[2] == "u"
  discard javaActivity("getWindow")
  doAssert last()[2] == "", "only inside onUiThread"
  # ready-made
  doAssert deviceModel() == "Google Pixel 9"
  doAssert androidVersion() == ("15", 35)
  doAssert showAndroidToast("Saved")
  doAssert log[^2].fields[1] == "show" or log[^3].fields[1] == "makeText"
  doAssert javaKept() == 0, "the toast was released"

# ---- shared libraries -----------------------------------------------------------------------------

block libraries:
  let libc = nativeLib("no-such-lib.so", "libc.so.6", "libc.so")
  doAssert libc != nil, "the first that loads"
  let strlen = nativeProc[proc (s: cstring): csize_t {.cdecl.}](libc, "strlen")
  doAssert strlen != nil and strlen("hello") == 5
  let pid = nativeProc[proc (): cint {.cdecl.}](libc, "getpid")
  doAssert pid() == getpid()
  doAssert nativeProc[proc () {.cdecl.}](libc, "no_such_function") == nil
  doAssert nativeProc[proc () {.cdecl.}](nil, "strlen") == nil
  doAssert nativeLib("no-such-lib.so") == nil

# ---- the same on every system ---------------------------------------------------------------------

block everywhere:
  javaThere = false                # (a desktop: no Java side)
  doAssert deviceName().len > 0
  doAssert osVersion().len > 0
  let b = batteryLevel()
  doAssert b == -1 or b in 0 .. 100
  discard systemDarkMode()
  discard systemDarkMode()         # (the second from its cache)
  beepSystem()                     # (no display here: nothing, no crash)
  discard userName()
  doAssert not vibrate(10) or inTermux()
  doAssert termuxApi("no-such-thing") == ""
  doAssert termuxApi("bad; rm -rf /") == "", "only plain command names"
  doAssert not keepScreenOn(true) or defined(windows)
  doAssert deviceModel() == "" and androidVersion() == ("", 0)

echo "native tests passed"
