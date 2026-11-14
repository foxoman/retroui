# Lesson 14: The system's own APIs

**Level:** advanced · **Time:** 30 minutes · **You learn:** to call Win32, Objective-C and Java when the kit has no call for something

```nim
import retroui                   # (it brings retroui/native: objcSend, javaStatic...)

# Each system's own API, called from Nim where the kit has no call for it.
proc systemHello(): string =
  when defined(windows):
    # Win32: a function of a DLL, declared and called
    proc GetTickCount64(): uint64 {.stdcall, dynlib: "kernel32", importc.}
    "Windows, up " & $(GetTickCount64() div 60_000) & " minutes"
  elif defined(macosx) or defined(ios):
    # Objective-C: a message to a class, through the runtime
    let info = objcSend(ObjcId, objcClass("NSProcessInfo"), "processInfo")
    "Apple, " & toNim(objcSend(ObjcId, info, "operatingSystemVersionString"))
  elif defined(android):
    # Java: a static method, by reflection (an APK's Java is there)
    "Android " & javaStatic("android.os.Build$VERSION", "RELEASE")
  else:
    "Linux or another Unix"

app "System", 360, 80:
  label systemHello()
```

- **Windows:** declare the DLL's function (`{.stdcall, dynlib: "kernel32", importc.}`) and call it. COM interfaces are vtables of such functions (see `src/retroui/notify_os.nim`).
- **macOS and iOS:** `objcSend(R, object, "selector:", args)` sends a message through the Objective-C runtime; `objcClass`, `nsString`, `toNim`, `autoreleasePool` (on threads of your own) are in `retroui/native`, which `import retroui` brings. A class of your own (a delegate, a target) is made with `objc_allocateClassPair` and `class_addMethod` (see `src/retroui/tray.nim`).
- **Android:** `javaStatic`, `javaNew`, `javaCall` reach Java by reflection; an app's own Java (a service, a VPN) goes in with `retroapk --java:DIR` (see `examples/retrodns/glue`).
- **Linux:** D-Bus with `retroui/uirelays/dbus` (`sessionBus`, `callWait`, `reply`, `signal`) -- notifications, the media applet and the tray are made with it.

Before you write one, look in `retroui/system`: notifications, sharing, the place, speech, haptics, the battery and more are there already, the same calls on every system ([docs/system.md](../../docs/system.md)).

## What you learned

- `dynlib` and `importc`; `objcSend`; `javaStatic`; D-Bus.

## Try it

Show the computer's name on each system: `GetComputerNameW`, `NSHost`'s `localizedName`, `android.os.Build.MODEL`, `/etc/hostname`.
