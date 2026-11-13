## retroui/system on this computer (Linux): what answers, what says false,
## the autostart entry made and taken away, the answers of a web page and
## of phones read right.

import std/[os, strutils, times]
import retroui/system {.all.}
import retroui/native
import retroui/admin
import retroui/[files, imaging, desktop, gfx, install, linuxpkg]
import retroui/native {.all.}

block jsonAndPlaces:
  doAssert jsonText("a \"b\"\n\\c\t\x01") == "\"a \\\"b\\\"\\n\\\\c\\t\""
  let p = parsePlace("ok 23.588 58.3829 35")
  doAssert p.state == psOk and abs(p.lat - 23.588) < 1e-9 and abs(p.lon - 58.3829) < 1e-9 and p.accuracy == 35
  doAssert parsePlace("waiting").state == psWaiting
  doAssert parsePlace("asked").state == psWaiting
  doAssert parsePlace("denied").state == psDenied
  doAssert parsePlace("none").state == psNone
  doAssert parsePlace("ok 1").state == psNone            # (cut short)
  doAssert parsePlace("ok x y z").state == psNone
  doAssert parsePlace("\0").state == psNone

block appIds:
  doAssert appId("Retro Mail") == "retro-mail"
  doAssert appId("  --HR Book 2!! ") == "hr-book-2"
  doAssert appId("مرحبا").len > 0                      # (no letters it can use: "app")

block startWithTheComputer:
  let home = getTempDir() / "retro-system-test"
  removeDir(home)
  createDir(home)
  putEnv("XDG_CONFIG_HOME", home)
  doAssert not openAtLogin("Retro Test")
  doAssert setOpenAtLogin(true, "Retro Test", "/opt/retro test/app")
  doAssert openAtLogin("Retro Test")
  let entry = readFile(home / "autostart" / "retro-test.desktop")
  doAssert "Exec=\"/opt/retro test/app\"" in entry and "Name=Retro Test" in entry, entry
  doAssert setOpenAtLogin(false, "Retro Test")
  doAssert not openAtLogin("Retro Test")
  doAssert setOpenAtLogin(false, "Retro Test")            # (not there: still fine)
  removeDir(home)

block whatALinuxDesktopSays:
  doAssert not share()                                    # nothing to share
  doAssert not share(text = "hello")                      # no share sheet on a Linux desktop
  doAssert not haptic(hSuccess)
  if not inTermux():
    doAssert location().state == psNone
  stopLocation()
  doAssert not requestAttention()                         # (no window: nobody to flash)
  doAssert not speak("   ")
  let lang = systemLanguage()
  doAssert lang.len >= 2 and '_' notin lang and '.' notin lang, lang
  putEnv("LC_ALL", "C.UTF-8")
  doAssert systemLanguage().len >= 2, "C.UTF-8 names no language: " & systemLanguage()
  putEnv("LC_ALL", "ar_OM.UTF-8")
  doAssert systemLanguage() == "ar-OM", systemLanguage()
  delEnv("LC_ALL")
  let b = battery()
  doAssert b.level in -1 .. 100
  doAssert not revealFile("/nonexistent/retro/file")
  let d = deviceInfo()
  doAssert d.name.len > 0 and d.system.len > 0 and d.platform == "linux" and d.cpus >= 1
  doAssert not d.mobile
  discard online()

block speech:
  # (only where a voice is installed: espeak-ng or speech-dispatcher)
  if findExe("espeak-ng").len > 0 or findExe("espeak").len > 0 or findExe("spd-say").len > 0:
    doAssert speak("Retro", rate = 2.0)
    let t0 = epochTime()
    while speaking() and epochTime() - t0 < 10: sleep(20)
    stopSpeaking()
    doAssert not speaking()
  else:
    doAssert not speak("Retro")

block runAsAdministrator:
  # (the words given to sh, to Windows and to AppleScript, quoted as each wants)
  doAssert posixCommand("/bin/sh", ["-c", "echo 'hi' $HOME"]) == "/bin/sh -c 'echo '\\''hi'\\'' $HOME'"
  doAssert posixCommand("nmcli", ["device", "x=1,2"]) == "nmcli device x=1,2"
  doAssert windowsArgs(["-NoProfile", "a b", "q\"x", "end\\", "x y\\"]) ==
    "-NoProfile \"a b\" \"q\\\"x\" end\\ \"x y\\\\\""
  doAssert windowsArgs([""]) == "\"\""
  doAssert appleScriptText("a \"b\" \\c") == "\"a \\\"b\\\" \\\\c\""
  # (here: pkexec, when there is one, asks; with none it fails at once and says why)
  if not canRunAsAdmin():
    var r = runAsAdmin("t", "true")
    for _ in 0 ..< 500:
      if r.state != adWaiting: break
      sleep 10
      r = runAsAdmin("t", "true")
    doAssert r.state == adFailed and "pkexec" in r.output, $r

block systemSettings:
  # GNOME's answers read; here, whatever this machine has
  let g = prefsOfGnome("false\n1.25\ntrue\n")
  doAssert g.reduceMotion and g.highContrast and abs(g.textScale - 1.25) < 1e-9
  let d = prefsOfGnome("true\n9\n")
  doAssert not d.reduceMotion and not d.highContrast and d.textScale == 3.0, "a scale kept sane"
  doAssert prefsOfGnome("").textScale == 1.0
  let p = systemPrefs()
  doAssert p.textScale >= 0.5 and p.textScale <= 3.0
  discard metered()
  # (no sleep between: not woken)
  discard systemWoke()
  doAssert not systemWoke()

block folderWatched:
  let dir = getTempDir() / "retro-watch-test"
  removeDir(dir)
  createDir(dir / "sub")
  writeFile(dir / "a.txt", "a")
  writeFile(dir / "sub" / "b.txt", "b")
  let w = watchFolder(dir, recursive = true, everyMs = 100)
  doAssert w.changes().len == 0, "the first look: where it starts"
  writeFile(dir / "c.txt", "c")
  writeFile(dir / "a.txt", "a longer")
  removeFile(dir / "sub" / "b.txt")
  doAssert w.changes().len == 0, "not looked again yet"
  sleep 150
  let ch = w.changes()
  doAssert ch.len == 3, $ch
  doAssert FileChange(kind: fcChanged, path: dir / "a.txt") in ch, $ch
  doAssert FileChange(kind: fcCreated, path: dir / "c.txt") in ch, $ch
  doAssert FileChange(kind: fcRemoved, path: dir / "sub" / "b.txt") in ch, $ch
  sleep 150
  doAssert w.changes().len == 0, "nothing since"
  let flat = watchFolder(dir, everyMs = 100)
  discard flat.changes()
  writeFile(dir / "sub" / "d.txt", "d")
  sleep 150
  doAssert flat.changes().len == 0, "not the folders in it"
  removeDir(dir)

block noDriver:
  # (no window here: no clipboard pictures, no desktop's shortcuts)
  doAssert not copyPicture(newBitmap(2, 2, 0xFF00FF00'u32))
  doAssert pastePicture() == nil
  doAssert not globalHotkey("Ctrl+Alt+F12") and not globalHotkeyTaken("Ctrl+Alt+F12")
  releaseGlobalHotkey("Ctrl+Alt+F12")

block installedForTheUser:
  # (in a home of its own: the program, its menu entry and icon; then gone)
  let home = getTempDir() / "retro-install-test"
  removeDir(home)
  createDir(home)
  let oldHome = getEnv("HOME")
  let oldData = getEnv("XDG_DATA_HOME")
  putEnv("HOME", home)
  delEnv("XDG_DATA_HOME")
  let me = InstallInfo(id: "retrotest", name: "Retro Test", version: "1.0", publisher: "Me",
                       iconPng: "\x89PNG fake")
  doAssert not installedForUser(me) and not runningInstalled(me)
  let path = installForUser(me)
  doAssert path == home / ".local" / "bin" / "retrotest" and fileExists(path)
  doAssert fpUserExec in getFilePermissions(path)
  let entry = readFile(home / ".local" / "share" / "applications" / "retrotest.desktop")
  doAssert "Exec=" & path & " %F" in entry and "Name=Retro Test" in entry, entry
  doAssert readFile(home / ".local/share/icons/hicolor/256x256/apps/retrotest.png") == "\x89PNG fake"
  doAssert installedForUser(me) and not runningInstalled(me)
  discard installForUser(me)                       # (again: over it)
  uninstallForUser(me)
  doAssert not installedForUser(me) and
           not fileExists(home / ".local" / "share" / "applications" / "retrotest.desktop")
  putEnv("HOME", oldHome)
  if oldData.len > 0: putEnv("XDG_DATA_HOME", oldData)
  removeDir(home)

block linuxPackages:
  # a .deb (ar, then gzipped tars), an RPM (its lead, headers, payload),
  # the .tar.gz with install.sh, the PKGBUILD
  let dir = getTempDir() / "retro-pkg-test"
  removeDir(dir)
  let a = LinuxApp(id: "retrotest", name: "Retro Test", version: "1.2", summary: "A test",
                   program: getAppFilename(), license: "MIT")
  let made = makeLinuxPackages(a, dir)
  doAssert made.len == 4
  let deb = readFile(made[0])
  doAssert deb.startsWith("!<arch>\ndebian-binary   ") and "control.tar.gz" in deb and "data.tar.gz" in deb
  let rpm = readFile(made[1])
  doAssert rpm.startsWith("\xed\xab\xee\xdb\x03\x00") and rpm[96 ..< 99] == "\x8e\xad\xe8"
  doAssert readFile(made[2]).startsWith("\x1f\x8b")
  let pkb = readFile(made[3])
  doAssert "pkgname=retrotest" in pkb and "pkgver=1.2" in pkb and "sha256sums=('" in pkb
  doAssert "--uninstall" in installScript(a) and "Exec=retrotest %F" in desktopEntry(a, "retrotest")
  removeDir(dir)

echo "system tests passed"
