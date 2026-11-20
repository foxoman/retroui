## Downloading a file from the web, on every system, with nothing to
## install: Android through Java's own HTTP (the APK needs the INTERNET
## permission: `retroapk --permission:INTERNET`); desktops, Termux and the
## rest through curl (or wget), which they carry; iOS through NSURLSession
## (`retroui/http`). It waits until the file is there (for small files:
## fonts, lists); a busy box can show meanwhile.
##
## .. code-block:: nim
##   let err = downloadFile("https://example.com/a.ttf", dataDir("MyApp") / "a.ttf")
##   if err.len > 0: echo "could not: ", err

import std/os
when not (defined(ios) or defined(wasm)):
  import std/strutils
import uirelays/target   # (androidApp: an APK, not a program in Termux)
when androidApp:
  import uirelays/services
elif defined(wasm) or defined(ios):
  import http
else:
  import std/[osproc, streams]

const defaultAgent* = "curl/8.4.0"
  ## (a plain user agent: servers give such a client plain files)

proc downloadFile*(url, dest: string; userAgent = defaultAgent; timeoutSec = 60;
                   headers: openArray[(string, string)] = []; resume = false): string =
  ## Downloads `url` into the file `dest` (through `dest.part`, moved into
  ## place when whole), sending `headers` too ("Authorization", the key of
  ## an API). "" when it worked, else what went wrong. Any thread may call
  ## it (a job: `retroui/jobs`' `download`); `downloadedSoFar` says how far
  ## it is.
  ##
  ## `resume` (a big file: a model, a disk image): a `dest.part` there from
  ## before is gone on with, and kept when the download stops or is cut
  ## off; `stopDownload(dest)` stops it ("stopped"). `timeoutSec` 0: no
  ## limit on the whole, only on a minute with nothing coming.
  block:
    let part = dest & ".part"
    try: createDir(dest.parentDir) except OSError: discard
    try: removeFile(dest & ".stop") except OSError: discard
    when androidApp:
      # (the app's Java part, RetroNet: any thread may ask, any Android; it
      # writes `part` and moves it into place itself)
      if '\t' in url or '\t' in dest: return "bad address"
      var hs: seq[string]
      for (k, v) in headers:
        if '\t' notin k and '\t' notin v: hs.add k & ": " & v
      let ms = if timeoutSec > 0: timeoutSec * 1000 else: 60_000
      let r = systemCall("net.download", url & "\t" & dest & "\t" & userAgent.replace('\t', ' ') &
                         "\t" & $ms & "\t" & hs.join("\r") & (if resume: "\tr" else: ""))
      if r == "1": return ""
      if r.len > 1 and r[0] == 'e': return r[1 .. ^1]
      if r == "\0": return "downloading is not available (the app's Java part is older than this program)"
      return "the download failed"
    else:
      when defined(wasm) or defined(ios):
        # (a browser page: through the page, the site must allow it -- CORS;
        # iOS: NSURLSession)
        var hs = @headers
        if not defined(wasm): hs.add ("User-Agent", userAgent)
        let r = httpRequest("GET", url, hs, timeoutSec = timeoutSec)
        if r.status == 0: return r.error
        if r.status != 200: return "the server answered " & $r.status
        try: writeFile(part, r.body)
        except IOError as e: return e.msg
      else:
        var tool = findExe("curl")
        var args: seq[string]
        let curl = tool.len > 0
        if curl:
          args = @["-fsSL", "-A", userAgent]
          if timeoutSec > 0: args.add ["--max-time", $timeoutSec]
          else: args.add ["--speed-limit", "1", "--speed-time", "60"]
          if resume and fileExists(part): args.add ["-C", "-"]
          for (k, v) in headers: args.add ["-H", k & ": " & v]
          args.add ["-o", part, url]
        else:
          tool = findExe("wget")
          if tool.len == 0: return "neither curl nor wget is installed"
          args = @["-q", "-T", $(if timeoutSec > 0: timeoutSec else: 60), "-U", userAgent]
          if resume: args.add "-c"
          for (k, v) in headers: args.add "--header=" & k & ": " & v
          args.add ["-O", part, url]
        let stop = dest & ".stop"
        var outp = ""
        var code = -1
        try:
          let p = startProcess(tool, args = args, options = {poStdErrToStdOut})
          # (looked at a few times a second: a stop asked for ends it, the part kept)
          var stopped = false
          while p.peekExitCode() == -1:
            if fileExists(stop):
              p.terminate()
              discard p.waitForExit()
              stopped = true
              break
            sleep(200)
          if not stopped:
            code = p.waitForExit()
            outp = try: p.outputStream.readAll() except CatchableError: ""
          p.close()
          if stopped:
            if not resume:
              try: removeFile(part) except OSError: discard
            return "stopped"
        except OSError as e:
          outp = e.msg
        if code != 0:
          if not resume or (curl and code == 33):
            # (33: the server takes no range -- the part is of no use)
            try: removeFile(part) except OSError: discard
          return (if outp.strip.len > 0: outp.strip else: "the download failed (" & $code & ")")
      try:
        moveFile(part, dest)
      except OSError as e: return e.msg
      return ""

proc stopDownload*(dest: string) =
  ## Stops a download into `dest` that `downloadFile` is doing (on another thread): it ends
  ## within a second, answering "stopped" -- its part kept when it was asked to `resume`.
  try:
    createDir(dest.parentDir)
    writeFile(dest & ".stop", "")
  except CatchableError: discard

proc downloadedSoFar*(dest: string): int64 =
  ## How many bytes of a download into `dest` are there so far (its
  ## `dest.part` growing; 0 before it starts, and once it is whole): with
  ## the size a feed or a header gave, a download's progress.
  try: getFileSize(dest & ".part") except OSError: 0
