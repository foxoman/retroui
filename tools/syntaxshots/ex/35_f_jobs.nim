#> clickMark(0)
#> for i in 0 ..< 300:
#>   frames(1)
#>   os.sleep(5)
#> shot("f-jobs")
import retroui
import retroui/jobs

var primes: Job[int]

app "Job", 300, 120:
  if button("&Count the primes"):
    primes = job(proc (c: JobCtl): int =     # runs on a worker thread
      for n in 2 ..< 200_000:
        if n mod 4096 == 0: c.progress(n / 200_000)
        var d = 2
        while d * d <= n and n mod d != 0: inc d
        if d * d > n: inc result)
  mark "count"
  if primes != nil:                          # read between frames, like a click
    progress(primes.progress)
    if primes.done: label $primes.value & " primes below 200,000"
