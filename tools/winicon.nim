## The Windows icon and version of a program, made from a PNG, ready to link:
##
##   nim c -r tools/winicon.nim icon.png "Retro Files" 3.2 build/files-res.o
##
## writes a .ico (16, 24, 32, 48, 64 and 256 pixels, each a PNG), a .rc
## (the icon as resource 1 -- what the window and the taskbar show, see the
## WinAPI driver -- and the file's version, product and company), and runs
## windres (x86_64-w64-mingw32-windres from Linux or macOS, windres on
## Windows) to make the object file passed to the linker:
##
##   nim c -d:mingw --cpu:amd64 --app:gui --passL:build/files-res.o files.nim
##
## Given an .rc to write instead of an object (build/files.rc), it writes
## the .ico and the .rc alone: zig's clang compiles an .rc given to it as it
## links (`--passL:build/files.rc`), no MinGW needed.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, osproc, strutils]
import retroui/[gfx, imaging, core]

proc le16(v: int): string = char(v and 255) & char((v shr 8) and 255)
proc le32(v: int): string = le16(v and 0xFFFF) & le16((v shr 16) and 0xFFFF)

proc main() =
  if paramCount() < 4:
    quit "usage: winicon icon.png \"Name\" version out-res.o"
  let png = paramStr(1)
  let name = paramStr(2)
  let version = paramStr(3)
  let outObj = paramStr(4)
  let src = decodePng(readFile(png))
  if src == nil or src.w <= 0: quit "winicon: cannot read " & png
  # the icon: PNG images in an ICO (Windows Vista and later read them)
  let sizes = [16, 24, 32, 48, 64, 256]
  var pngs: seq[string]
  for s in sizes:
    let b = thumbnail(src, s, s)
    # (square: the picture centered on a transparent square)
    let sq = newBitmap(s, s)
    let ox = (s - b.w) div 2
    let oy = (s - b.h) div 2
    for y in 0 ..< b.h:
      for x in 0 ..< b.w: sq.px[(y + oy) * s + x + ox] = b.px[y * b.w + x]
    pngs.add encodePng(sq, level = 9)
  var ico = le16(0) & le16(1) & le16(sizes.len)
  var at = 6 + 16 * sizes.len
  for i, s in sizes:
    ico.add char(if s >= 256: 0 else: s) & char(if s >= 256: 0 else: s) & char(0) & char(0)
    ico.add le16(1) & le16(32) & le32(pngs[i].len) & le32(at)
    at += pngs[i].len
  for p in pngs: ico.add p
  let dir = outObj.parentDir
  if dir.len > 0: createDir(dir)
  let base = outObj.changeFileExt("")
  writeFile(base & ".ico", ico)
  # the version: "3.2" -> 3,2,0,0
  var nums = version.split('.')
  while nums.len < 4: nums.add "0"
  let commas = nums[0 .. 3].join(",")
  writeFile(base & ".rc", "1 ICON \"" & base.extractFilename & ".ico\"\n" &
    "1 VERSIONINFO\nFILEVERSION " & commas & "\nPRODUCTVERSION " & commas & "\nBEGIN\n" &
    "  BLOCK \"StringFileInfo\"\n  BEGIN\n    BLOCK \"040904B0\"\n    BEGIN\n" &
    "      VALUE \"FileDescription\", \"" & name & "\"\n" &
    "      VALUE \"ProductName\", \"" & name & "\"\n" &
    "      VALUE \"FileVersion\", \"" & version & "\"\n" &
    "      VALUE \"ProductVersion\", \"" & version & "\"\n" &
    "      VALUE \"CompanyName\", \"" & RetroDeveloper & " " & RetroHandle & " (" & RetroWebsite & ")\"\n" &
    "      VALUE \"LegalCopyright\", \"Copyright (c) 2026 " & RetroDeveloper & "\"\n" &
    "    END\n  END\n  BLOCK \"VarFileInfo\"\n  BEGIN\n    VALUE \"Translation\", 0x409, 1200\n  END\nEND\n")
  if outObj.endsWith(".rc"):
    echo "wrote ", base & ".rc"
    return
  var tool = findExe("x86_64-w64-mingw32-windres")
  if tool.len == 0: tool = findExe("windres")
  if tool.len == 0: quit "winicon: windres not found (MinGW)"
  let code = execCmd(quoteShellCommand([tool, "-O", "coff", "-i", base & ".rc", "-o", outObj]) &
                     " --include-dir " & quoteShell(dir))
  if code != 0: quit "winicon: windres failed"
  echo "wrote ", outObj

main()
