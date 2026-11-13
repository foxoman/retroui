## The app installs itself for the user alone -- no administrator, no
## installer to make -- and takes itself away again:
##
## - Windows: the program in %LOCALAPPDATA%\Programs\<name>, a Start menu
##   entry, and an entry in Settings > Apps that uninstalls it.
## - Linux: the program (or the AppImage) in ~/.local/bin, its menu entry and
##   its icon.
## - macOS: the app in ~/Applications.
##
## There it is the user's own file, so the app's updates (`retroui/update`)
## replace it with no question. `installFlags` makes the program its own
## installer: `MyApp.exe --install`, `MyApp.exe --uninstall` (what Settings
## runs).
##
## .. code-block:: nim
##   import retroui, retroui/install
##   const me = InstallInfo(id: "notes", name: "Notes", version: "1.2",
##                          publisher: "Me", iconPng: staticRead("notes.png"))
##   if installFlags(me): quit 0              # (--install or --uninstall: done)
##   app "Notes", 600, 400:
##     if not runningInstalled(me) and button("&Install for Me"):
##       discard installForUser(me)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/os
from core import appArguments
when defined(windows):
  import std/[widestrs, osproc]
when defined(macosx):
  import std/strutils

type
  InstallInfo* = object
    ## What the system is told of the app.
    id*: string           ## its file and command name: "notes"
    name*: string         ## shown in menus and Settings: "Notes"
    version*: string      ## "1.2"
    publisher*: string    ## who made it (Settings > Apps)
    iconPng*: string      ## its icon (a PNG's bytes) for Linux's menu
    categories*: string   ## Linux's menu: "Utility;" (default)

  InstallError* = object of CatchableError

proc runningFile(): string =
  ## (the program running: the AppImage it is in, the .app it is in)
  let image = getEnv("APPIMAGE")
  if image.len > 0: return image
  result = getAppFilename()
  when defined(macosx):
    let i = result.find(".app/Contents/MacOS/")
    if i > 0: result = result[0 ..< i + 4]

proc installedPath*(i: InstallInfo): string =
  ## Where the app goes when it is installed for the user.
  when defined(windows):
    getEnv("LOCALAPPDATA", getHomeDir() / "AppData" / "Local") / "Programs" / i.name /
      (i.id & ".exe")
  elif defined(macosx):
    getHomeDir() / "Applications" / (i.name & ".app")
  else:
    getHomeDir() / ".local" / "bin" / i.id

proc installedForUser*(i: InstallInfo): bool =
  ## The app is installed for the user (`installForUser`).
  when defined(macosx): dirExists(i.installedPath) else: fileExists(i.installedPath)

proc runningInstalled*(i: InstallInfo): bool =
  ## The program running is the one installed for the user.
  try: sameFile(runningFile(), i.installedPath) except OSError: false

when defined(windows):
  type
    Guid = object
      d1: uint32
      d2, d3: uint16
      d4: array[8, uint8]
    Com = ptr object
      vtbl: ptr UncheckedArray[pointer]
  proc CoInitializeEx(r: pointer; mode: uint32): int32 {.stdcall, dynlib: "ole32", importc.}
  proc CoCreateInstance(clsid: ptr Guid; outer: pointer; ctx: uint32; iid: ptr Guid;
                        obj: ptr Com): int32 {.stdcall, dynlib: "ole32", importc.}
  proc RegCreateKeyExW(key: uint; sub: WideCString; reserved: uint32; class: pointer;
                       options, sam: uint32; sec: pointer; res: ptr uint; disp: ptr uint32): int32
    {.stdcall, dynlib: "advapi32", importc.}
  proc RegSetValueExW(key: uint; name: WideCString; reserved, kind: uint32; data: pointer;
                      size: uint32): int32 {.stdcall, dynlib: "advapi32", importc.}
  proc RegCloseKey(key: uint): int32 {.stdcall, dynlib: "advapi32", importc.}
  proc RegDeleteTreeW(key: uint; sub: WideCString): int32 {.stdcall, dynlib: "advapi32", importc.}

  const HKCU = 0x80000001'u
  proc uninstallKey(i: InstallInfo): string =
    "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\" & i.id

  proc call[T](o: Com; slot: int): T = cast[T](o.vtbl[slot])

  proc makeShortcut(lnk, target, description: string): bool =
    ## (a Start menu entry: IShellLinkW, saved through IPersistFile)
    discard CoInitializeEx(nil, 2)
    var clsid = Guid(d1: 0x00021401'u32, d2: 0, d3: 0,
                     d4: [0xC0'u8, 0, 0, 0, 0, 0, 0, 0x46])
    var iidLink = Guid(d1: 0x000214F9'u32, d2: 0, d3: 0,
                       d4: [0xC0'u8, 0, 0, 0, 0, 0, 0, 0x46])
    var iidFile = Guid(d1: 0x0000010B'u32, d2: 0, d3: 0,
                       d4: [0xC0'u8, 0, 0, 0, 0, 0, 0, 0x46])
    var link: Com
    if CoCreateInstance(addr clsid, nil, 1, addr iidLink, addr link) != 0 or link == nil:
      return false
    type SetStr = proc (this: Com; s: WideCString): int32 {.stdcall.}
    discard link.call[:SetStr](20)(link, newWideCString(target))                # SetPath
    discard link.call[:SetStr](9)(link, newWideCString(target.parentDir))       # SetWorkingDirectory
    discard link.call[:SetStr](7)(link, newWideCString(description))            # SetDescription
    var file: Com
    if link.call[:proc (this: Com; iid: ptr Guid; o: ptr Com): int32 {.stdcall.}](0)(
         link, addr iidFile, addr file) == 0 and file != nil:
      result = file.call[:proc (this: Com; name: WideCString; remember: int32): int32 {.stdcall.}](6)(
        file, newWideCString(lnk), 1) == 0
      discard file.call[:proc (this: Com): uint32 {.stdcall.}](2)(file)
    discard link.call[:proc (this: Com): uint32 {.stdcall.}](2)(link)

  proc setString(key: uint; name, value: string) =
    let wo = newWideCString(value)
    let w: WideCString = wo                     # (wo keeps it alive)
    discard RegSetValueExW(key, newWideCString(name), 0, 1, cast[pointer](w),   # REG_SZ
                           uint32((wo.len + 1) * 2))

  proc setDword(key: uint; name: string; value: uint32) =
    var v = value
    discard RegSetValueExW(key, newWideCString(name), 0, 4, addr v, 4)          # REG_DWORD

  proc startMenuLink(i: InstallInfo): string =
    getEnv("APPDATA") / "Microsoft" / "Windows" / "Start Menu" / "Programs" / (i.name & ".lnk")

proc linuxDesktopFile(i: InstallInfo): string =
  getEnv("XDG_DATA_HOME", getHomeDir() / ".local" / "share") / "applications" / (i.id & ".desktop")
proc linuxIconFile(i: InstallInfo): string =
  getEnv("XDG_DATA_HOME", getHomeDir() / ".local" / "share") / "icons" / "hicolor" / "256x256" /
    "apps" / (i.id & ".png")

proc installForUser*(i: InstallInfo): string =
  ## Copies the program running to the user's own programs (over an older
  ## one), with its menu entry; where it went. Raises `InstallError`.
  when defined(wasm) or defined(android) or defined(ios):
    raise newException(InstallError, "a phone or a page installs apps by itself")
  else:
    let src = runningFile()
    let dest = i.installedPath
    try:
      createDir(dest.parentDir)
      when defined(macosx):
        if src.endsWith(".app"):
          if not (dirExists(dest) and sameFile(src, dest)):
            if dirExists(dest): removeDir(dest)
            copyDirWithPermissions(src, dest)
        else:
          raise newException(InstallError, "not an .app: " & src)
      else:
        if not (fileExists(dest) and sameFile(src, dest)):
          # (beside it first, then over it in one step: a running copy is not cut)
          let next = dest & ".new"
          copyFileWithPermissions(src, next)
          when defined(windows):
            if fileExists(dest):
              let old = dest & ".old"
              if fileExists(old): removeFile(old)
              moveFile(dest, old)
          else:
            setFilePermissions(next, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead,
                                      fpGroupExec, fpOthersRead, fpOthersExec})
          moveFile(next, dest)
      when defined(windows):
        discard makeShortcut(i.startMenuLink, dest, i.name)
        var key: uint
        if RegCreateKeyExW(HKCU, newWideCString(i.uninstallKey), 0, nil, 0, 0x20006, nil,
                           addr key, nil) == 0:
          setString(key, "DisplayName", i.name)
          setString(key, "DisplayVersion", i.version)
          setString(key, "Publisher", i.publisher)
          setString(key, "DisplayIcon", dest & ",0")
          setString(key, "InstallLocation", dest.parentDir)
          setString(key, "UninstallString", "\"" & dest & "\" --uninstall")
          setString(key, "QuietUninstallString", "\"" & dest & "\" --uninstall")
          setDword(key, "NoModify", 1)
          setDword(key, "NoRepair", 1)
          setDword(key, "EstimatedSize", uint32(getFileSize(dest) div 1024))
          discard RegCloseKey(key)
      elif not defined(macosx):
        createDir(i.linuxDesktopFile.parentDir)
        writeFile(i.linuxDesktopFile, "[Desktop Entry]\nType=Application\nName=" & i.name &
          "\nExec=" & dest & " %F\nIcon=" & i.id & "\nTerminal=false\nCategories=" &
          (if i.categories.len > 0: i.categories else: "Utility;") & "\nStartupWMClass=" & i.id & "\n")
        if i.iconPng.len > 0:
          createDir(i.linuxIconFile.parentDir)
          writeFile(i.linuxIconFile, i.iconPng)
      dest
    except OSError, IOError:
      raise newException(InstallError, "not installed: " & getCurrentExceptionMsg())

proc uninstallForUser*(i: InstallInfo) =
  ## Takes the app installed for the user away (its menu entry too); the
  ## app's data stays. A program running from there goes once it has ended
  ## (Windows).
  when defined(wasm) or defined(android) or defined(ios): discard
  else:
    let dest = i.installedPath
    when defined(windows):
      try: removeFile(i.startMenuLink) except OSError: discard
      discard RegDeleteTreeW(HKCU, newWideCString(i.uninstallKey))
      # (the program may be the one running: its folder goes when it ends)
      try:
        # (one command line, as cmd reads it: the folder's name quoted once)
        discard startProcess("cmd.exe /c ping -n 3 127.0.0.1 >nul & rmdir /s /q \"" &
                             dest.parentDir & "\"", options = {poEvalCommand, poDaemon})
      except OSError: discard
    elif defined(macosx):
      try: removeDir(dest) except OSError: discard
    else:
      for f in [dest, i.linuxDesktopFile, i.linuxIconFile]:
        try: removeFile(f) except OSError: discard

proc installFlags*(i: InstallInfo): bool =
  ## The program's own `--install` and `--uninstall` (Settings > Apps runs
  ## the second): done, and said; true when one was given (the app ends).
  for a in appArguments():
    case a
    of "--install":
      try: echo i.name, " is installed: ", installForUser(i)
      except InstallError as e: echo e.msg
      return true
    of "--uninstall":
      uninstallForUser(i)
      echo i.name, " is uninstalled."
      return true
    else: discard
