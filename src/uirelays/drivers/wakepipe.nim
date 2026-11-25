## A pipe for `interruptWaitEvent` in the drivers that wait in `poll()`
## (Wayland, the screen driver): its read end sits among the descriptors
## they wait on, and a byte written from any thread ends the wait. Never
## closed: a late writer must not hit a descriptor used again.

import std/posix

var
  wakeRead* = cint(-1)    ## the end `poll()` watches (-1: none could be made)
  wakeWrite = cint(-1)

proc openWakePipe*() =
  ## Makes the pipe (once); without one, a wait is not cut short.
  if wakeRead >= 0: return
  var fds: array[2, cint]
  if pipe(fds) != 0: return
  for fd in fds:
    discard fcntl(fd, F_SETFL, O_NONBLOCK)
    discard fcntl(fd, F_SETFD, FD_CLOEXEC)
  wakeRead = fds[0]
  wakeWrite = fds[1]

proc drainWakePipe*() =
  ## Reads what was written, so the next wait waits again.
  if wakeRead < 0: return
  var buf: array[64, char]
  while read(wakeRead, addr buf[0], buf.len) > 0: discard

proc pokeWakePipe*() {.gcsafe.} =
  ## Ends a wait on the pipe, from any thread (a full pipe: already awake).
  if wakeWrite >= 0:
    var b = 'w'
    discard write(wakeWrite, addr b, 1)
