## Tests of `retroui/hangwatch`: the table of a program's procs read
## (tools/winsym.py writes it) and a place in the program named by it;
## where there is no watch (anything but 64-bit Windows) starting one does
## nothing. The watch itself -- a window that waits, its thread's procs in
## the fault log -- is tried with tests/hang_demo.nim as a Windows program
## (under Wine too: see the file).

import retroui/hangwatch

let t = procTable("1000 pre_c_init\n1a2b0 listFolder@files\n\nnot a line\n1a400 hasSubFolders@files\nzz bad\n" &
                  "200000 folderNode@filewidgets\n300000 \n")
doAssert t.len == 4 and t[1] == (0x1a2b0'u64, "listFolder@files")
doAssert procAt(t, 0x1a2b0) == "listFolder@files" and procAt(t, 0x1a3ff) == "listFolder@files"
doAssert procAt(t, 0x1a400) == "hasSubFolders@files" and procAt(t, 0x1000) == "pre_c_init"
doAssert procAt(t, 0xfff) == "" and procAt(t, 0x200010) == "folderNode@filewidgets"
doAssert procAt(t, 0x200000 + 0x100000) == ""            # (too far past the last: not in it)
doAssert procAt(@[], 5) == "" and procTable("").len == 0

when not HangWatched:
  startHangWatch(nil)
  hangStopping()
echo "hangwatch ok"
