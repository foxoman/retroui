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
