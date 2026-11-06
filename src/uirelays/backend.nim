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

elif defined(linux) or defined(freebsd) or defined(openbsd) or defined(netbsd) or
     defined(dragonfly):
  import drivers/x11_driver
  proc initBackend*() = initX11Driver()

else:
  import drivers/sdl3_driver
  proc initBackend*() = initSdl3Driver()
