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
| hello | 2.1 MB | 28 ms | 8.7 MB | 8.8 MB | 1 ms |
| gallery | 6.3 MB | 45 ms | 13.7 MB | 15.6 MB | 0 ms |
| filemanager | 4.5 MB | 28 ms | 14.4 MB | 14.9 MB | 0 ms |
| photo | 14.8 MB | 37 ms | 22.6 MB | 23.0 MB | 0 ms |
| retroboard | 4.0 MB | 32 ms | 19.0 MB | 20.0 MB | 0 ms |
| mail | 8.4 MB | 41 ms | 18.0 MB | 18.6 MB | 5 ms |
| navigator | 4.4 MB | 173 ms | 158.7 MB | 181.4 MB | 5 ms |
| retrodns | 2.4 MB | 41 ms | 14.1 MB | 14.7 MB | 3 ms |
| podcast | 3.4 MB | 35 ms | 12.0 MB | 19.8 MB | 0 ms |
| grow | 2.3 MB | 31 ms | 10.7 MB | 13.7 MB | 1 ms |
| taskman | 2.5 MB | 22 ms | 11.8 MB | 13.3 MB | 3 ms |
| sevenguis | 2.3 MB | 33 ms | 10.8 MB | 11.3 MB | 0 ms |

Memory at rest is the resident memory 6 seconds after the start (3 seconds
untouched); most in use, the peak while the smoke run worked it. Retro
Navigator's numbers are mostly the system's web engine (WebKitGTK here),
which runs beside the app.
