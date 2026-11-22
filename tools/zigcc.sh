#!/bin/sh
## zig's clang as a C compiler for another system. By default it is the
## compiler of the Linux AppImage builds, linking against an older glibc
## (2.31: Ubuntu 20.04, Debian 11, Fedora 32, RHEL 9 and later;
## $RETRO_GLIBC for another) than the one of the computer building, so the
## AppImage runs on the systems people have. $RETRO_ZIG_TARGET picks another
## system: x86_64-windows-gnu for a Windows program (MinGW's headers and
## libraries are zig's own; LLVM's optimizer, link-time optimization across
## the whole program; zig 0.15 -- 0.16 and 0.17 leave their own C library's
## names undefined when linking a Windows program so). It is $RETRO_ZIG (a
## zig program), else zig on the PATH, else Python's (pip install ziglang).
##
##   nim c --cc:clang --clang.exe:tools/zigcc.sh --clang.linkerexe:tools/zigcc.sh app.nim
##   RETRO_ZIG_TARGET=x86_64-windows-gnu nim c --os:windows ... (as above) app.nim
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

target="${RETRO_ZIG_TARGET:-x86_64-linux-gnu.${RETRO_GLIBC:-2.31}}"
if [ -n "${RETRO_ZIG:-}" ]; then
  exec "$RETRO_ZIG" cc -target "$target" "$@"
fi
if command -v zig >/dev/null 2>&1; then
  exec zig cc -target "$target" "$@"
fi
exec python3 -m ziglang cc -target "$target" "$@"
