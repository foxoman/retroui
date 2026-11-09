## The system's own APIs from Nim (retroui/native): what this device is, the
## battery, dark mode, a beep, a buzz -- and on each system a call made
## straight to its API: Java on Android, Objective-C on macOS and iOS, Win32
## and COM on Windows, any C library on Linux.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import retroui, retroui/native
import retroui/uirelays/target
when not androidApp:
  import std/strutils                     # (Termux:API's answer)

var
  screenOn = false
  progressValue = 30
  answer = ""
  dark = systemDarkMode()

app "Native APIs", 520, 420:
  heading "This device"
  form 0:
    field "Device:": label deviceName()
    field "System:": label osVersion()
    field "User:": label(if userName().len > 0: userName() else: "-")
    field "Battery:":
      let b = batteryLevel()
      label(if b < 0: "unknown" else: $b & "%")
    field "Dark mode:": label(if dark: "on" else: "off")
  row:
    if button("&Beep"): beepSystem()
    if button("&Vibrate"): answer = if vibrate(80): "Buzzed." else: "Nothing buzzes here."
    if toggle("&Keep the screen on", screenOn):
      answer = if keepScreenOn(screenOn): "Done." else: "Not on this system."
    if button("&Settings"): discard openSettings("display")
  separator()
  heading("Straight to the system", 3)
  when defined(android):
    if button("Package name (Java)"): answer = javaActivity("getPackageName")
    if button("Android toast"): showAndroidToast("Hello from Nim")
    if button("Build.MODEL"): answer = javaStatic("android.os.Build", "MODEL")
  elif defined(macosx) or defined(ios):
    if button("Host name (Objective-C)"):
      let info = objcSend(ObjcId, objcClass("NSProcessInfo"), "processInfo")
      answer = toNim(objcSend(ObjcId, info, "hostName"))
  elif defined(windows):
    if button("Documents folder (Win32)"): answer = windowsDocumentsFolder()
    row:
      label "Taskbar progress (COM):"
      if slider(progressValue, 0, 100, w = 160):
        taskbarProgress(progressValue / 100)
  else:
    if button("getpid (libc)"):
      let libc = nativeLib("libc.so.6", "libc.so", "libc.so.7")
      let getpid = nativeProc[proc (): cint {.cdecl.}](libc, "getpid")
      answer = if getpid != nil: "Process " & $getpid() else: "No libc?"
    if inTermux() and button("Battery (Termux:API)"):
      answer = termuxApi("battery-status").strip
  paragraph answer
