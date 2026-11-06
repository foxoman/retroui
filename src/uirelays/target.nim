## What the program is built as, beyond the OS: an Android app, or a
## program with Android's libc run from a shell.
##
## Nim builds for Android (`--os:android`) both an app -- an APK's
## NativeActivity library (`--app:lib`), whose window, files, clipboard and
## the rest come from the activity -- and an ordinary program run from a
## shell such as Termux, whose window is an X server's (Termux:X11, a VNC
## server) and whose files are the shell's, as on Linux. `androidApp` tells
## them apart; `defined(android)` alone is true for both (and `defined(linux)`
## is true for both, as Android is Linux).
##
## ```nim
## import uirelays/target
## when androidApp: echo "in an APK"
## elif defined(android): echo "a program in Termux: X11, files as on Linux"
## ```

const
  androidApp* = defined(android) and appType == "lib"
    ## An Android app: the NativeActivity driver, the activity's services.
  androidShell* = defined(android) and not androidApp
    ## A program built and run in Termux (or another shell on Android):
    ## the X11 driver, files and services as on Linux.
