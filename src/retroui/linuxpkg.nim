## Linux packages of an app, made here with nothing else installed: a
## Debian package (.deb: Debian, Ubuntu, Mint), an RPM (Fedora, openSUSE,
## RHEL), an Arch PKGBUILD, and a .tar.gz with `install.sh`, which puts the
## app in the user's own folders -- no administrator, so the app's updates
## (`retroui/update`) can replace it -- and takes it away again
## (`sh install.sh --uninstall`). `retrokit linux` makes them all.
##
## The packages put the program at /usr/bin/<id>, its menu entry at
## /usr/share/applications/<id>.desktop and its icon at
## /usr/share/icons/hicolor/256x256/apps/<id>.png; install.sh the same under
## ~/.local.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, times]
import codec, sha2

type
  LinuxApp* = object
    ## What the packages say of the app.
    id*: string             ## its command and package name: "retrofiles"
    name*: string           ## shown in menus: "Retro Files"
    version*: string        ## "3.3" (digits and dots)
    summary*: string        ## one line
    description*: string    ## more lines (optional)
    maintainer*: string     ## "Name <mail@example.com>"
    license*: string        ## "MIT"
    url*: string            ## its home page (optional)
    categories*: string     ## the menu's: "Utility;"
    depends*: seq[string]   ## Debian packages it needs ("libwebkit2gtk-4.1-0")
    arch*: string           ## "x86_64" or "aarch64" ("": this machine's)
    program*: string        ## the program's file (or an AppImage)
    icon*: string           ## a PNG, 256 pixels square at best ("": none)

  PkgFile = tuple[path: string; mode: int; data: string]
    ## (a file of a package: where it goes, without the first "/")

proc archOf(a: LinuxApp): string =
  if a.arch.len > 0: a.arch
  elif hostCPU == "arm64": "aarch64"
  else: "x86_64"

proc debArch(a: LinuxApp): string =
  case a.archOf
  of "aarch64": "arm64"
  of "x86_64": "amd64"
  else: a.archOf

proc desktopEntry*(a: LinuxApp; exec: string): string =
  ## The menu entry (`exec`: the command it starts).
  "[Desktop Entry]\nType=Application\nName=" & a.name & "\nComment=" & a.summary &
    "\nExec=" & exec & " %F\nIcon=" & a.id & "\nTerminal=false\nCategories=" &
    (if a.categories.len > 0: a.categories else: "Utility;") & "\nStartupWMClass=" & a.id & "\n"

proc filesOf(a: LinuxApp): seq[PkgFile] =
  result.add ("usr/bin/" & a.id, 0o755, readFile(a.program))
  result.add ("usr/share/applications/" & a.id & ".desktop", 0o644, a.desktopEntry(a.id))
  if a.icon.len > 0:
    result.add ("usr/share/icons/hicolor/256x256/apps/" & a.id & ".png", 0o644, readFile(a.icon))

# ---- tar, gzip, ar --------------------------------------------------------------------------

proc octal(v: int64; width: int): string =
  ## (a tar header's number: octal digits, then NUL)
  result = toOct(v, width - 1) & "\0"

proc tarEntry(name: string; mode: int; data: string; dir = false; mtime: int64): string =
  var h = newString(512)
  for i in 0 ..< h.len: h[i] = '\0'
  proc put(at: int; s: string) =
    for i, c in s: h[at + i] = c
  put(0, name[0 ..< min(name.len, 99)])
  put(100, octal(mode, 8))
  put(108, octal(0, 8))
  put(116, octal(0, 8))
  put(124, octal(if dir: 0 else: data.len, 12))
  put(136, octal(mtime, 12))
  put(148, "        ")
  h[156] = (if dir: '5' else: '0')
  put(257, "ustar\0" & "00")
  put(265, "root")
  put(297, "root")
  var sum = 0
  for c in h: sum += ord(c)
  put(148, toOct(sum, 6) & "\0 ")
  result = h
  if not dir:
    result.add data
    let pad = (512 - data.len mod 512) mod 512
    result.add repeat('\0', pad)

proc tarOf(files: openArray[PkgFile]; dirs: openArray[string] = []; mtime: int64): string =
  ## A tar ("./" names) of `dirs` (made first) and `files`.
  for d in dirs: result.add tarEntry("./" & d & "/", 0o755, "", dir = true, mtime = mtime)
  for f in files: result.add tarEntry("./" & f.path, f.mode, f.data, mtime = mtime)
  result.add repeat('\0', 1024)

proc gzipOf*(data: string; mtime: int64 = 0): string =
  ## `data` gzipped.
  result = "\x1f\x8b\x08\x00" & char(mtime and 255) & char((mtime shr 8) and 255) &
           char((mtime shr 16) and 255) & char((mtime shr 24) and 255) & "\x00\x03"
  let d = deflateLevel(data.toOpenArrayByte(0, data.high), 9)
  for b in d: result.add char(b)
  let c = crc32(data.toOpenArrayByte(0, data.high))
  for k in 0 .. 3: result.add char((c shr (8 * k)) and 255)
  let n = uint32(data.len and 0xFFFFFFFF)
  for k in 0 .. 3: result.add char((n shr (8 * k)) and 255)

proc arMember(name, data: string; mtime: int64): string =
  result = alignLeft(name, 16) & alignLeft($mtime, 12) & alignLeft("0", 6) & alignLeft("0", 6) &
           alignLeft("100644", 8) & alignLeft($data.len, 10) & "`\n" & data
  if data.len mod 2 == 1: result.add '\n'

proc dirsOf(files: openArray[PkgFile]): seq[string] =
  ## (every folder the files are in, the outer ones first)
  for f in files:
    var d = f.path.parentDir
    var chain: seq[string]
    while d.len > 0 and d != "." and d != "/":
      chain.insert(d, 0)
      d = d.parentDir
    for c in chain:
      if c notin result: result.add c

# ---- the packages ---------------------------------------------------------------------------

proc debOf*(a: LinuxApp; mtime = getTime().toUnix): string =
  ## The Debian package (.deb).
  let files = a.filesOf
  var size = 0
  for f in files: size += f.data.len
  var control = "Package: " & a.id & "\nVersion: " & a.version & "\nArchitecture: " & a.debArch &
    "\nMaintainer: " & (if a.maintainer.len > 0: a.maintainer else: a.name & " <nobody@localhost>") &
    "\nInstalled-Size: " & $((size + 1023) div 1024) & "\nSection: misc\nPriority: optional\n"
  if a.depends.len > 0: control.add "Depends: " & a.depends.join(", ") & "\n"
  if a.url.len > 0: control.add "Homepage: " & a.url & "\n"
  control.add "Description: " & a.summary & "\n"
  for line in a.description.splitLines:
    control.add(if line.strip.len == 0: " .\n" else: " " & line & "\n")
  let ctl = tarOf([("control", 0o644, control)], mtime = mtime)
  let data = tarOf(files, dirsOf(files), mtime)
  "!<arch>\n" & arMember("debian-binary", "2.0\n", mtime) &
    arMember("control.tar.gz", gzipOf(ctl, mtime), mtime) &
    arMember("data.tar.gz", gzipOf(data, mtime), mtime)

# (the RPM: a lead, a signature header, a header, then the files as a
# gzipped cpio)

type
  RpmTag = tuple[tag, kind: int; data: string; count: int]

const
  RpmInt16 = 3
  RpmInt32 = 4
  RpmString = 6
  RpmBin = 7
  RpmStrings = 8
  RpmI18n = 9

proc be32(v: int64): string =
  for k in countdown(3, 0): result.add char((v shr (8 * k)) and 255)
proc be16(v: int): string = char((v shr 8) and 255) & char(v and 255)

proc tagStr(tag: int; s: string; kind = RpmString): RpmTag = (tag, kind, s & "\0", 1)
proc tagStrs(tag: int; s: openArray[string]): RpmTag =
  var d = ""
  for x in s: d.add x & "\0"
  (tag, RpmStrings, d, s.len)
proc tagInts(tag: int; v: openArray[int64]): RpmTag =
  var d = ""
  for x in v: d.add be32(x)
  (tag, RpmInt32, d, v.len)
proc tagShorts(tag: int; v: openArray[int]): RpmTag =
  var d = ""
  for x in v: d.add be16(x)
  (tag, RpmInt16, d, v.len)

proc rpmHeader(tags: seq[RpmTag]; region: int): string =
  ## A header: its region's entry first (`region`: 62 the signature's, 63
  ## the main one's), then the tags in order; each value aligned to its size.
  var store = ""
  var index = ""
  let all = tags.len + 1
  for t in tags:
    let align = case t.kind
                of RpmInt16: 2
                of RpmInt32: 4
                else: 1
    while store.len mod align != 0: store.add '\0'
    index.add be32(t.tag) & be32(t.kind) & be32(store.len) & be32(t.count)
    store.add t.data
  # (the region's trailer: the region tag, BIN, minus the index's size, 16)
  let trailerAt = store.len
  store.add be32(region) & be32(RpmBin) & be32(-(all * 16)) & be32(16)
  index = be32(region) & be32(RpmBin) & be32(trailerAt) & be32(16) & index
  "\x8e\xad\xe8\x01\x00\x00\x00\x00" & be32(all) & be32(store.len) & index & store

proc cpioEntry(name: string; mode, ino: int; data: string; mtime: int64): string =
  proc h8(v: int64): string = toHex(v, 8)
  let nm = name & "\0"
  result = "070701" & h8(ino) & h8(mode) & h8(0) & h8(0) & h8(1) & h8(mtime) & h8(data.len) &
           h8(0) & h8(0) & h8(0) & h8(0) & h8(nm.len) & h8(0) & nm
  while result.len mod 4 != 0: result.add '\0'
  result.add data
  while result.len mod 4 != 0: result.add '\0'

proc rpmOf*(a: LinuxApp; mtime = getTime().toUnix): string =
  ## The RPM package (.rpm).
  let files = a.filesOf
  var cpio = ""
  for i, f in files: cpio.add cpioEntry("./" & f.path, 0o100000 or f.mode, i + 1, f.data, mtime)
  cpio.add cpioEntry("TRAILER!!!", 0, 0, "", 0)
  let payload = gzipOf(cpio, mtime)
  var dirs, bases: seq[string]
  var dirIndex, sizes, mtimes, inodes, flags, devices: seq[int64]
  var modes, rdevs: seq[int]
  var digests, links, users, groups, langs: seq[string]
  var total = 0
  for i, f in files:
    let d = "/" & f.path.parentDir & "/"
    if d notin dirs: dirs.add d
    dirIndex.add int64(dirs.find(d))
    bases.add f.path.extractFilename
    sizes.add f.data.len
    total += f.data.len
    modes.add(0o100000 or f.mode)
    rdevs.add 0
    mtimes.add mtime
    digests.add sha256(f.data).toHex.toLowerAscii
    links.add ""
    flags.add 0
    users.add "root"
    groups.add "root"
    inodes.add int64(i + 1)
    devices.add 1
    langs.add ""
  let main = rpmHeader(@[
    tagStr(1000, a.id), tagStr(1001, a.version), tagStr(1002, "1"),
    tagStr(1004, a.summary, RpmI18n),
    tagStr(1005, if a.description.len > 0: a.description else: a.summary, RpmI18n),
    tagInts(1006, [mtime]), tagStr(1007, "localhost"), tagInts(1009, [int64(total)]),
    tagStr(1014, if a.license.len > 0: a.license else: "Proprietary"),
    tagStr(1016, "Applications/Productivity", RpmI18n),
    tagStr(1020, a.url), tagStr(1021, "linux"), tagStr(1022, a.archOf),
    tagInts(1028, sizes), tagShorts(1030, modes), tagShorts(1033, rdevs), tagInts(1034, mtimes),
    tagStrs(1035, digests), tagStrs(1036, links), tagInts(1037, flags),
    tagStrs(1039, users), tagStrs(1040, groups),
    tagStrs(1047, [a.id]), tagInts(1112, [int64(8)]), tagStrs(1113, [a.version & "-1"]),
    tagStr(1064, "4.16.0"), tagInts(1095, devices),
    tagInts(1096, inodes), tagStrs(1097, langs),
    tagInts(1116, dirIndex), tagStrs(1117, bases), tagStrs(1118, dirs),
    tagStr(1124, "cpio"), tagStr(1125, "gzip"), tagStr(1126, "9"),
    tagInts(5011, [int64(8)]),
    tagStrs(5092, [sha256(payload).toHex.toLowerAscii]), tagInts(5093, [int64(8)])], 63)
  var sig = rpmHeader(@[
    tagInts(1000, [int64(main.len + payload.len)]),
    tagStr(273, sha256(main).toHex.toLowerAscii),
    tagInts(1007, [int64(cpio.len)])], 62)
  while sig.len mod 8 != 0: sig.add '\0'
  var lead = "\xed\xab\xee\xdb\x03\x00" & be16(0) & be16(1)
  let nameField = a.id & "-" & a.version & "-1"
  lead.add nameField[0 ..< min(65, nameField.len)]
  lead.add repeat('\0', 66 - min(65, nameField.len))
  lead.add be16(1) & be16(5) & repeat('\0', 16)
  lead & sig & main & payload

proc installScript*(a: LinuxApp): string =
  ## install.sh: the app in the user's own folders (no administrator);
  ## `--uninstall` takes it away (the app's data stays).
  let icon = if a.icon.len > 0: a.id & ".png" else: ""
  "#!/bin/sh\n# " & a.name & " " & a.version & ": installed for this user, no administrator needed.\n" &
    "#   sh install.sh               install (or update)\n" &
    "#   sh install.sh --uninstall   take it away (its data stays)\nset -e\n" &
    "here=$(cd \"$(dirname \"$0\")\" && pwd)\n" &
    "bin=\"$HOME/.local/bin\"; apps=\"${XDG_DATA_HOME:-$HOME/.local/share}/applications\"\n" &
    "icons=\"${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps\"\n" &
    "if [ \"${1:-}\" = \"--uninstall\" ]; then\n" &
    "  rm -f \"$bin/" & a.id & "\" \"$apps/" & a.id & ".desktop\" \"$icons/" & a.id & ".png\"\n" &
    "  echo \"" & a.name & " is uninstalled.\"; exit 0\nfi\n" &
    "mkdir -p \"$bin\" \"$apps\" \"$icons\"\n" &
    "cp \"$here/" & a.id & "\" \"$bin/" & a.id & ".new\" && chmod 755 \"$bin/" & a.id & ".new\" && " &
      "mv \"$bin/" & a.id & ".new\" \"$bin/" & a.id & "\"\n" &
    (if icon.len > 0: "cp \"$here/" & icon & "\" \"$icons/" & icon & "\"\n" else: "") &
    "sed \"s|^Exec=" & a.id & "|Exec=$bin/" & a.id & "|\" \"$here/" & a.id & ".desktop\" > \"$apps/" &
      a.id & ".desktop\"\n" &
    "command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database \"$apps\" 2>/dev/null || true\n" &
    "echo \"" & a.name & " " & a.version & " is installed: $bin/" & a.id & " (and in the menu).\"\n"

proc tarballOf*(a: LinuxApp; mtime = getTime().toUnix): string =
  ## <id>-<version>-<arch>.tar.gz: the program, its icon and menu entry, and
  ## install.sh, in a folder of their own.
  let top = a.id & "-" & a.version
  var files: seq[PkgFile] = @[(top & "/" & a.id, 0o755, readFile(a.program)),
    (top & "/" & a.id & ".desktop", 0o644, a.desktopEntry(a.id)),
    (top & "/install.sh", 0o755, a.installScript)]
  if a.icon.len > 0: files.add (top & "/" & a.id & ".png", 0o644, readFile(a.icon))
  gzipOf(tarOf(files, [top], mtime), mtime)

proc pkgbuildOf*(a: LinuxApp; tarball, tarballSha256: string): string =
  ## Arch's PKGBUILD, from the .tar.gz (its file name, its SHA-256).
  "# " & a.name & ": makepkg -si\npkgname=" & a.id & "\npkgver=" & a.version & "\npkgrel=1\n" &
    "pkgdesc=\"" & a.summary.replace("\"", "'") & "\"\narch=('" & a.archOf & "')\n" &
    "url=\"" & a.url & "\"\nlicense=('" & (if a.license.len > 0: a.license else: "custom") & "')\n" &
    "source=(\"" & tarball & "\")\nsha256sums=('" & tarballSha256 & "')\n\n" &
    "package() {\n  cd \"$srcdir/" & a.id & "-" & a.version & "\"\n" &
    "  install -Dm755 " & a.id & " \"$pkgdir/usr/bin/" & a.id & "\"\n" &
    "  install -Dm644 " & a.id & ".desktop \"$pkgdir/usr/share/applications/" & a.id & ".desktop\"\n" &
    (if a.icon.len > 0: "  install -Dm644 " & a.id & ".png \"$pkgdir/usr/share/icons/hicolor/256x256/apps/" &
                        a.id & ".png\"\n" else: "") & "}\n"

proc makeLinuxPackages*(a: LinuxApp; outDir: string): seq[string] =
  ## Every package of `a` in `outDir`: the .deb, the .rpm, the .tar.gz with
  ## install.sh, and the PKGBUILD. Their paths.
  createDir(outDir)
  let base = a.id & "-" & a.version
  let deb = outDir / (a.id & "_" & a.version & "_" & a.debArch & ".deb")
  writeFile(deb, a.debOf)
  let rpm = outDir / (base & "-1." & a.archOf & ".rpm")
  writeFile(rpm, a.rpmOf)
  let tgzName = base & "-" & a.archOf & ".tar.gz"
  let tgzData = a.tarballOf
  writeFile(outDir / tgzName, tgzData)
  let pkb = outDir / "PKGBUILD"
  writeFile(pkb, a.pkgbuildOf(tgzName, sha256(tgzData).toHex.toLowerAscii))
  @[deb, rpm, outDir / tgzName, pkb]
