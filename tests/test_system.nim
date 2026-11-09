## retroui/system on this computer (Linux): what answers, what says false,
## the autostart entry made and taken away, the answers of a web page and
## of phones read right.

import std/[os, strutils, times]
import retroui/system {.all.}
import retroui/native

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

echo "system tests passed"
