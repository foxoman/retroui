## Automatic platform driver selection.
## Uses the native backend for each OS, with `-d:` overrides for
## cross-platform toolkits.
##
## Override flags (checked first):
##   --define:"features.uirelays.figDrawWindy" Force FigDraw + Windy backend
##   --define:"features.uirelays.siwin" Siwin windows with native drawing
##   --define:"features.uirelays.figDrawSiwin" Legacy alias for native Siwin
##   --define:"features.uirelays.figDrawSiwinGpu" Explicit legacy GPU adapter
##   -d:sdl3    Force SDL3 backend
##   -d:sdl2    Force SDL2 backend
##   -d:gtk4    Force GTK4 backend
##   -d:wasm    a browser page (WebAssembly, `retrokit web`)
##   -d:wayland Wayland only (no X11; without it, a Linux or BSD build has
##              both and picks one as it starts: `useWayland`)
##   -d:kiosk   the screen alone, no windowing system (DRM/KMS or the
##              framebuffer, evdev input); a Linux build has it too and
##              takes it as it starts: `useScreen`
##
## Android (`--os:android`) uses the NativeActivity driver for an app
## (`--app:lib`, an APK's library) and X11 for a program run from a shell
## (Termux, its window on Termux:X11); iOS (`-d:ios`) the UIKit driver.

import target

const NativeSiwin = defined(features.uirelays.siwin) or
  defined(features.uirelays.figDrawSiwin) or defined(figDrawSiwin)

when (defined(features.uirelays.figDrawWindy) or defined(figDrawWindy)) and
    (NativeSiwin or defined(features.uirelays.figDrawSiwinGpu)):
  {.error: "Windy and Siwin drivers are mutually exclusive".}
elif NativeSiwin and defined(features.uirelays.figDrawSiwinGpu):
  {.error: "Native and GPU Siwin drivers are mutually exclusive".}

elif defined(features.uirelays.figDrawWindy) or defined(figDrawWindy):
  import drivers/figdraw_windy_driver
  proc initBackend*() = initFigDrawWindyDriver()

elif defined(features.uirelays.figDrawSiwinGpu):
  import drivers/figdraw_siwin_driver
  proc initBackend*() = initFigDrawSiwinDriver()

elif NativeSiwin:
  import drivers/siwin_driver
  proc initBackend*() = initSiwinDriver()

elif defined(sdl3):
  import drivers/sdl3_driver
  proc initBackend*() = initSdl3Driver()

elif defined(sdl2):
  import drivers/sdl2_driver
  proc initBackend*() = initSdl2Driver()

elif defined(gtk4):
  import drivers/gtk4_driver
  proc initBackend*() = initGtk4Driver()

elif androidApp:
  import drivers/android_driver
  proc initBackend*() = initAndroidDriver()

elif defined(ios):
  import drivers/uikit_driver
  proc initBackend*() = initUIKitDriver()

elif defined(macosx):
  import drivers/cocoa_driver
  proc initBackend*() = initCocoaDriver()

elif defined(windows):
  import drivers/winapi_driver
  proc initBackend*() = initWinapiDriver()

elif defined(wasm):
  import drivers/web_driver
  proc initBackend*() = initWebDriver()

elif defined(wayland):
  import drivers/wayland_driver
  proc initBackend*() = initWaylandDriver()

elif defined(kiosk):
  import drivers/fb_driver
  proc initBackend*() = initFbDriver()

elif defined(linux) or defined(freebsd) or defined(openbsd) or defined(netbsd) or
     defined(dragonfly):
  import std/[os, strutils]
  import drivers/[x11_driver, wayland_driver]
  when defined(linux):
    import std/posix
    import drivers/fb_driver
  proc useScreen*(): bool =
    ## The screen itself, no windowing system (`fb_driver`):
    ## `RETRO_DRIVER=kms` (or `fb`); else the program started on a text
    ## console (a VT) with no X display and no Wayland session, and a
    ## screen is there.
    when defined(linux):
      case getEnv("RETRO_DRIVER").toLowerAscii
      of "kms", "drm", "fb", "fbdev", "kiosk", "screen": return true
      of "x11", "wayland": return false
      else: discard
      if getEnv("DISPLAY").len > 0 or getEnv("WAYLAND_DISPLAY").len > 0 or
         getEnv("WAYLAND_SOCKET").len > 0:
        return false
      let tty = ttyname(0)
      tty != nil and ($tty).startsWith("/dev/tty") and ($tty).len > 8 and
        ($tty)[8] in '0' .. '9' and fbAvailable()
    else:
      false
  proc useWayland*(): bool =
    ## The Wayland driver rather than X11: `RETRO_DRIVER=wayland` (or
    ## `x11`) says; else a Wayland session without an X display.
    case getEnv("RETRO_DRIVER").toLowerAscii
    of "wayland": true
    of "x11": false
    else:
      getEnv("DISPLAY").len == 0 and
        (getEnv("WAYLAND_DISPLAY").len > 0 or getEnv("WAYLAND_SOCKET").len > 0)
  proc initBackend*() =
    when defined(linux):
      if useScreen():
        initFbDriver()
        return
    if useWayland(): initWaylandDriver() else: initX11Driver()

else:
  import drivers/sdl3_driver
  proc initBackend*() = initSdl3Driver()
