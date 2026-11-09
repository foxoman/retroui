## Downloading a file from the web, on every system, with nothing to
## install: Android through Java's own HTTP (the APK needs the INTERNET
## permission: `retroapk --permission:INTERNET`); desktops, Termux and the
## rest through curl (or wget), which they carry. It waits until the file
## is there (for small files: fonts, lists); a busy box can show meanwhile.
##
## .. code-block:: nim
##   let err = downloadFile("https://example.com/a.ttf", dataDir("MyApp") / "a.ttf")
##   if err.len > 0: echo "could not: ", err

when not defined(ios):                     # (no downloads on iOS yet)
  import std/os
when not (defined(ios) or defined(wasm)):
  import std/strutils
import uirelays/target   # (androidApp: an APK, not a program in Termux)
when androidApp:
  import native
elif defined(wasm):
  import http
elif not defined(ios):
  import std/osproc

const defaultAgent* = "curl/8.4.0"
  ## (a plain user agent: servers give such a client plain files)

proc downloadFile*(url, dest: string; userAgent = defaultAgent; timeoutSec = 60;
                   headers: openArray[(string, string)] = []): string =
  ## Downloads `url` into the file `dest` (through `dest.part`, moved into
  ## place when whole), sending `headers` too ("Authorization", the key of
  ## an API). "" when it worked, else what went wrong.
  when defined(ios):
    "downloading is not done on iOS yet"
  else:
    let part = dest & ".part"
    try: createDir(dest.parentDir) except OSError: discard
    when androidApp:
      if not javaAvailable(): return "Java is not reachable"
      let sdk = androidVersion().sdk
      if sdk > 0 and sdk < 29: return "downloading needs Android 10 or newer"
      let u = javaNew("java.net.URL", url)
      if u.isNil: return "bad address: " & javaError()
      let conn = javaCallObj(u, "openConnection")
      if conn.isNil:
        javaRelease(u)
        return javaError()
      discard javaCall(conn, "setRequestProperty", "User-Agent", userAgent)
      for (k, v) in headers: discard javaCall(conn, "setRequestProperty", k, v)
      discard javaCall(conn, "setConnectTimeout", timeoutSec * 1000)
      discard javaCall(conn, "setReadTimeout", timeoutSec * 1000)
      let code = try: parseInt(javaCall(conn, "getResponseCode")) except ValueError: -1
      if code != 200:
        javaRelease(conn, u)
        return (if code < 0: "no connection (" & javaError() & ")" else: "the server answered " & $code)
      let ins = javaCallObj(conn, "getInputStream")
      let outs = javaNew("java.io.FileOutputStream", part)
      if ins.isNil or outs.isNil:
        javaRelease(conn, u, ins, outs)
        return javaError()
      discard javaStatic("android.os.FileUtils", "copy", ins, outs)
      let err = javaError()
      discard javaCall(outs, "close")
      discard javaCall(ins, "close")
      javaRelease(conn, u, ins, outs)
      if not fileExists(part) or getFileSize(part) == 0: return "nothing came (" & err & ")"
    elif defined(wasm):
      # (a browser page: through the page, the site must allow it -- CORS)
      var hs = @headers
      let r = httpRequest("GET", url, hs, timeoutSec = timeoutSec)
      if r.status == 0: return r.error
      if r.status != 200: return "the server answered " & $r.status
      try: writeFile(part, r.body)
      except IOError as e: return e.msg
    else:
      var tool = findExe("curl")
      var cmd: string
      if tool.len > 0:
        cmd = quoteShell(tool) & " -fsSL --max-time " & $timeoutSec & " -A " & quoteShell(userAgent)
        for (k, v) in headers: cmd.add " -H " & quoteShell(k & ": " & v)
        cmd.add " -o " & quoteShell(part) & " " & quoteShell(url)
      else:
        tool = findExe("wget")
        if tool.len == 0: return "neither curl nor wget is installed"
        cmd = quoteShell(tool) & " -q -T " & $timeoutSec & " -U " & quoteShell(userAgent)
        for (k, v) in headers: cmd.add " --header=" & quoteShell(k & ": " & v)
        cmd.add " -O " & quoteShell(part) & " " & quoteShell(url)
      let (outp, code) = try: execCmdEx(cmd) except OSError as e: (e.msg, -1)
      if code != 0:
        try: removeFile(part) except OSError: discard
        return (if outp.strip.len > 0: outp.strip else: "the download failed (" & $code & ")")
    try:
      moveFile(part, dest)
    except OSError as e: return e.msg
    ""
