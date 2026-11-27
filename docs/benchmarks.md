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
