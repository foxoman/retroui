# Benchmarks

What an app made with Retro Nim UI costs, measured by `tools/bench.py`
(its scenes are in `tools/bench.nim`). Medians of 5 runs, the scenes
taking turns. Run it on your own machine for your own numbers.

| | |
|---|---|
| Machine | Intel(R) Xeon(R) Processor @ 2.10GHz, 2 cores |
| System | Linux 6.18.44-fc-v726 |
| Compiler | Nim Compiler Version 2.4.2 [Linux: amd64], `-d:release -d:useMalloc -d:strip` |
| Drawn on | Xvfb (no graphics card: drawn by the processor) |

## At rest

A number and three buttons, 5 seconds after its first frame, nothing happening.

| | |
|---|---|
| The program (stripped) | 3.4 MB |
| Start to the first frame on screen | 61 ms |
| Memory at rest (resident) | 11.3 MB |
| Processor at rest | 0.01% of a core |

## Busy

600 frames, each asked for 16 ms after the last, as a 60 Hz screen would.

| Scene | Processor a frame | Frames a second | Slowest frames (99th percentile) | Most memory |
|---|---|---|---|---|
| A list: 100,000 rows of three texts, scrolled 8 pixels a frame | 0.69 ms | 61.8 | 17.2 ms | 11.6 MB |
| A dashboard: 600 cells, each its own color and a number changing every frame | 1.05 ms | 61.8 | 17.1 ms | 11.5 MB |
| A document: 40 paragraphs (20,000 letters) wrapped to a new width every frame | 2.15 ms | 61.8 | 17.2 ms | 13.7 MB |
| Type: 24 lines, each in another of 48 sizes and four faces every frame | 1.45 ms | 61.9 | 17.1 ms | 17.5 MB |

The processor's time is the whole process's (every thread). The frame rate
stops at the 62 frames a second the scenes ask for (one each 16 ms); the
slowest frames are the time between frames as each starts.

## Where a frame's time goes

The same scenes with the frame profiler on (`--profile`, `retroui/frameprof`):
a frame's time in its parts, averages of the last 120 frames, ms.

| Scene | A frame | The app's code | Finishing the frame | On the screen | of it, the CPU drawing | the CPU sending |
|---|---|---|---|---|---|---|
| A list | 0.820 | 0.083 | 0.004 | 0.715 | 0.398 | 0.026 |
| A dashboard | 1.220 | 0.156 | 0.003 | 1.036 | 0.630 | 0.025 |
| A document | 2.351 | 1.508 | 0.010 | 0.791 | 0.429 | 0.022 |
| Type | 1.511 | 0.017 | 0.003 | 1.465 | 0.892 | 0.027 |

## The apps

The kit's own apps, built for release (`-d:release -d:strip -d:lto`,
`--opt:size` for all but Retro Atelier and Retro Mail), measured by
`sh tools/appbench.sh` on the same machine: each started in a home of its
own on Xvfb, left alone, then clicked, typed and scrolled through for 16
seconds by the kit's smoke run (`RETRO_SMOKE`).

| App | Program (stripped) | First frame | Memory at rest | Most memory in use | Processor at rest (3 s) |
|---|---|---|---|---|---|
| hello | 2.0 MB | 34 ms | 8.6 MB | 8.6 MB | 1 ms |
| gallery | 6.3 MB | 69 ms | 13.6 MB | 14.3 MB | 0 ms |
| filemanager | 5.3 MB | 38 ms | 15.3 MB | 18.1 MB | 0 ms |
| photo | 14.7 MB | 47 ms | 23.5 MB | 23.8 MB | 0 ms |
| retroboard | 3.9 MB | 47 ms | 18.5 MB | 19.5 MB | 1 ms |
| mail | 8.3 MB | 49 ms | 18.2 MB | 18.7 MB | 5 ms |
| navigator | 4.3 MB | 223 ms | 159.4 MB | 181.8 MB | 7 ms |
| retrodns | 2.3 MB | 69 ms | 13.8 MB | 14.4 MB | 4 ms |
| podcast | 3.3 MB | 55 ms | 12.1 MB | 19.8 MB | 0 ms |
| grow | 2.2 MB | 38 ms | 10.3 MB | 13.3 MB | 2 ms |
| taskman | 2.4 MB | 39 ms | 12.0 MB | 13.5 MB | 3 ms |
| sevenguis | 2.2 MB | 53 ms | 10.6 MB | 11.0 MB | 0 ms |

Memory at rest is the resident memory 6 seconds after the start (3 seconds
untouched); most in use, the peak while the smoke run worked it. Retro
Navigator's numbers are mostly the system's web engine (WebKitGTK here),
which runs beside the app. The first frames move by 10 to 25 ms from one
run to the next here (Gallery took 69 ms in this run, 43 in the next).
