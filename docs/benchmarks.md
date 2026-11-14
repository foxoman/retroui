# Benchmarks

What an app made with Retro Nim UI costs, measured by `tools/bench.py`
(its scenes are in `tools/bench.nim`). Medians of 5 runs, the scenes
taking turns. Run it on your own machine for your own numbers.

| | |
|---|---|
| Machine | Intel(R) Xeon(R) Processor @ 2.10GHz, 2 cores |
| System | Linux 6.18.44-fc-v445 |
| Compiler | Nim Compiler Version 2.2.6 [Linux: amd64], `-d:release -d:useMalloc -d:strip` |
| Drawn on | Xvfb (no graphics card: drawn by the processor) |

## At rest

A number and three buttons, 5 seconds after its first frame, nothing happening.

| | |
|---|---|
| The program (stripped) | 3.0 MB |
| Start to the first frame on screen | 57 ms |
| Memory at rest (resident) | 11.1 MB |
| Processor at rest | 0.01% of a core |

## Busy

600 frames, each asked for 16 ms after the last, as a 60 Hz screen would.

| Scene | Processor a frame | Frames a second | Slowest frames (99th percentile) | Most memory |
|---|---|---|---|---|
| A list: 100,000 rows of three texts, scrolled 8 pixels a frame | 0.67 ms | 61.8 | 17.2 ms | 11.5 MB |
| A dashboard: 600 cells, each its own color and a number changing every frame | 0.95 ms | 61.8 | 17.1 ms | 11.4 MB |
| A document: 40 paragraphs (20,000 letters) wrapped to a new width every frame | 2.29 ms | 61.8 | 17.3 ms | 13.4 MB |

The processor's time is the whole process's (every thread). The frame rate
stops at the 62 frames a second the scenes ask for (one each 16 ms); the
slowest frames are the time between frames as each starts.

## The apps

The kit's own apps, built for release (`-d:release -d:strip -d:lto`,
`--opt:size` for all but Retro Photo and Retro Mail), measured by
`sh tools/appbench.sh` on the same machine: each started in a home of its
own on Xvfb, left alone, then clicked, typed and scrolled through for 16
seconds by the kit's smoke run (`RETRO_SMOKE`).

| App | Program (stripped) | First frame | Memory at rest | Most memory in use | Processor at rest (3 s) |
|---|---|---|---|---|---|
| hello | 2.0 MB | 29 ms | 8.4 MB | 8.4 MB | 1 ms |
| gallery | 6.2 MB | 53 ms | 13.3 MB | 20.0 MB | 0 ms |
| filemanager | 4.4 MB | 33 ms | 14.1 MB | 14.5 MB | 0 ms |
| photo | 14.7 MB | 51 ms | 21.7 MB | 22.0 MB | 0 ms |
| retroboard | 3.9 MB | 54 ms | 18.6 MB | 19.6 MB | 1 ms |
| mail | 8.3 MB | 49 ms | 17.5 MB | 18.0 MB | 5 ms |
| navigator | 4.2 MB | 246 ms | 158.7 MB | 181.4 MB | 7 ms |
| retrodns | 2.3 MB | 46 ms | 13.7 MB | 14.3 MB | 4 ms |
| podcast | 3.3 MB | 54 ms | 12.0 MB | 19.8 MB | 0 ms |
| grow | 2.2 MB | 43 ms | 10.3 MB | 13.2 MB | 2 ms |
| taskman | 2.4 MB | 44 ms | 11.6 MB | 13.1 MB | 3 ms |
| sevenguis | 2.2 MB | 40 ms | 10.4 MB | 10.9 MB | 0 ms |

Memory at rest is the resident memory 6 seconds after the start (3 seconds
untouched); most in use, the peak while the smoke run worked it. Retro
Navigator's numbers are mostly the system's web engine (WebKitGTK here),
which runs beside the app.
