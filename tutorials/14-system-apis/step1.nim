#> build-only
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
