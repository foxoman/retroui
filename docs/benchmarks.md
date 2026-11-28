# Benchmarks

What an app made with Retro Nim UI costs, measured by `tools/bench.py`
(its scenes are in `tools/bench.nim`). Medians of 3 runs, the scenes
taking turns. Run it on your own machine for your own numbers.

| | |
|---|---|
| Machine | Intel(R) Xeon(R) Processor @ 2.10GHz, 2 cores |
| System | Linux 6.18.44-fc-v880 |
| Compiler | Nim Compiler Version 2.4.2 [Linux: amd64], `-d:release -d:useMalloc -d:strip` |
| Drawn on | Xvfb (no graphics card: drawn by the processor) |

## At rest

A number and three buttons, 5 seconds after its first frame, nothing happening.

| | |
|---|---|
| The program (stripped) | 3.8 MB |
| Start to the first frame on screen | 74 ms |
| Memory at rest (resident) | 12.0 MB |
| Processor at rest | 0.01% of a core |

## Busy

600 frames, each asked for 16 ms after the last, as a 60 Hz screen would.

| Scene | Processor a frame | Frames a second | Slowest frames (99th percentile) | Most memory |
|---|---|---|---|---|
| A list: 100,000 rows of three texts, scrolled 8 pixels a frame | 0.51 ms | 61.7 | 17.1 ms | 12.3 MB |
| A dashboard: 600 cells, each its own color and a number changing every frame | 0.81 ms | 62.1 | 17.0 ms | 12.0 MB |
| A document: 40 paragraphs (20,000 letters) wrapped to a new width every frame | 0.94 ms | 61.9 | 17.1 ms | 14.1 MB |
| Type: 24 lines, each in another of 48 sizes and four faces every frame | 1.15 ms | 61.8 | 17.0 ms | 18.0 MB |
| A phone: a settings page in the Gloss look, a pixel lower every frame | 0.58 ms | 61.9 | 17.0 ms | 12.5 MB |

The processor's time is the whole process's (every thread). The frame rate
stops at the 62 frames a second the scenes ask for (one each 16 ms); the
slowest frames are the time between frames as each starts.

## Where a frame's time goes

The same scenes with the frame profiler on (`--profile`, `retroui/frameprof`):
a frame's time in its parts, averages of the last 120 frames, ms.

| Scene | A frame | The app's code | Finishing the frame | On the screen | of it, the CPU drawing | the CPU sending |
|---|---|---|---|---|---|---|
| A list | 0.790 | 0.068 | 0.003 | 0.694 | 0.329 | 0.030 |
| A dashboard | 0.981 | 0.109 | 0.003 | 0.849 | 0.470 | 0.030 |
| A document | 1.121 | 0.451 | 0.008 | 0.614 | 0.300 | 0.021 |
| Type | 1.185 | 0.019 | 0.004 | 1.141 | 0.654 | 0.032 |

## The Glass look and the terminal

Drawn by the processor at 1600 x 1000 (2 threads), medians of 3 runs of
`tests/bench_glass.nim` -- a window of tabs, groups, cards, fields,
lists, buttons and a grid -- and of a terminal of 195 x 65 cells in 256
colors, bold, underlined and with backgrounds, in 0.73.1 and 0.74.0.

| | 0.73.1 | 0.74.0 |
|---|---|---|
| The 3.1 look, every pixel redrawn | 1.7 ms | 1.8 ms |
| The Glass look, every pixel redrawn | 5.1 ms | 3.3 ms |
| The Glass look (dark), every pixel redrawn | 4.9 ms | 3.3 ms |
| The terminal, every pixel redrawn | 3.8 ms | 2.1 ms |
| The terminal, a line written to it | 3.9 ms | 1.7 ms |
| The terminal, a frame with nothing new (built, not drawn) | 1.1 ms | 0.3 ms |

0.74's Glass look draws more than 0.73's -- faces shaded from top to
foot, every field, group and tab page a rounded card -- and takes less:
its rounded shapes are drawn by spans (`rasterRound`). Drawn as any
shape, as 0.73 drew them, the same window took 13 to 18 ms. The
terminal's rows are drawn by runs (`textCells`), not a cell at a time.

The four looks in 0.75.0, the same window every pixel redrawn, medians of
3 runs on one machine:

| Look | Light | Dark |
|---|---|---|
| 3.1 (Classic) | 1.5 ms | |
| Glass | 2.4 ms | 2.5 ms |
| Matte | 2.3 ms | 2.2 ms |
| Gloss | 2.7 ms | 2.4 ms |

Matte draws flat faces and costs less than Glass; Gloss adds a shine on
every face and its lit bars.

## The apps

The kit's own apps, built for release (`-d:release -d:strip -d:lto`,
`--opt:size` for all but Retro Atelier and Retro Mail), measured by
`sh tools/appbench.sh` on the same machine: each started in a home of its
own on Xvfb, left alone, then clicked, typed and scrolled through for 16
seconds by the kit's smoke run (`RETRO_SMOKE`).

| App | Program (stripped) | First frame | Memory at rest | Most memory in use | Processor at rest (3 s) |
|---|---|---|---|---|---|
| hello | 3.6 MB | 16 ms | 10.0 MB | 10.1 MB | 2 ms |
| gallery | 8.1 MB | 25 ms | 16.3 MB | 17.4 MB | 0 ms |
| filemanager | 7.4 MB | 21 ms | 17.3 MB | 18.3 MB | 0 ms |
| photo | 26.7 MB | 46 ms | 32.7 MB | 34.2 MB | 0 ms |
| retroboard | 6.5 MB | 45 ms | 21.2 MB | 23.7 MB | 1 ms |
| mail | 11.2 MB | 23 ms | 22.2 MB | 22.8 MB | 4 ms |
| navigator | 6.3 MB | 354 ms | 158.5 MB | 179.3 MB | 7 ms |
| retrodns | 4.1 MB | 63 ms | 16.7 MB | 17.3 MB | 3 ms |
| podcast | 4.8 MB | 25 ms | 14.3 MB | 22.6 MB | 0 ms |
| grow | 3.7 MB | 24 ms | 11.9 MB | 15.7 MB | 2 ms |
| taskman | 3.9 MB | 16 ms | 14.1 MB | 17.4 MB | 4 ms |
| sevenguis | 3.8 MB | 24 ms | 12.8 MB | 13.6 MB | 0 ms |

Memory at rest is the resident memory 6 seconds after the start (3 seconds
untouched); most in use, the peak while the smoke run worked it. Measured
in 0.81.0, the apps in Suhar App: its eight files are about 0.8 MB of each
program. Retro Navigator's numbers are mostly the system's web engine
(WebKitGTK here), which runs beside the app: without it the app alone is
24 MB at rest. The first frames move by
10 to 70 ms from one run to the next here (hello took 87 ms in its first
run, the machine's first, and 16 ms in the next).
