#!/usr/bin/env python3
"""The kit measured (Linux): tools/bench.nim built for release, stripped, each
scene run 5 times (taking turns), the medians written to docs/benchmarks.md.

    python3 tools/bench.py            (from the repository's root)
    python3 tools/bench.py --runs 3   (fewer runs)

On the screen there is ($DISPLAY), else on Xvfb (software drawing: what a
machine with no graphics card does). Developed by Sultan Al Isaiee @foxoman
-- www.foxoman.net -- sultan@foxoman.net
"""
import json, os, platform, statistics, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "build", "bench")
SCENES = ["rest", "list", "dashboard", "document"]


def main():
    runs = 5
    if "--runs" in sys.argv:
        runs = int(sys.argv[sys.argv.index("--runs") + 1])
    os.makedirs(OUT, exist_ok=True)
    exe = os.path.join(OUT, "bench")
    subprocess.run(["nim", "c", "--hints:off", "-d:release", "-d:useMalloc", "-d:strip",
                    "-o:" + exe, "tools/bench.nim"], cwd=ROOT, check=True)
    env = dict(os.environ)
    xvfb = None
    if not env.get("DISPLAY"):
        env["DISPLAY"] = ":93"
        xvfb = subprocess.Popen(["Xvfb", ":93", "-screen", "0", "1280x800x24"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1.5)
    results = {s: [] for s in SCENES}
    try:
        for _ in range(runs):
            for s in SCENES:
                e = dict(env, RETRO_BENCH=s, RETRO_BENCH_OUT="")
                p = subprocess.run([exe], env=e, capture_output=True, text=True, timeout=90)
                line = [l for l in p.stdout.splitlines() if l.startswith("{")]
                if line:
                    results[s].append(json.loads(line[-1]))
    finally:
        if xvfb:
            xvfb.terminate()

    def med(scene, key, scale=1.0):
        v = [r[key] for r in results[scene] if key in r]
        return statistics.median(v) * scale if v else float("nan")

    size = os.path.getsize(exe) / 1e6
    cpu = "?"
    try:
        for l in open("/proc/cpuinfo"):
            if l.startswith("model name"):
                cpu = l.split(":", 1)[1].strip()
                break
    except OSError:
        pass
    nim = subprocess.run(["nim", "-v"], capture_output=True, text=True).stdout.splitlines()[0]
    shown = "the screen ($DISPLAY)" if not xvfb else "Xvfb (no graphics card: drawn by the processor)"
    rest = "rest"
    lines = [
        "# Benchmarks",
        "",
        "What an app made with Retro Nim UI costs, measured by `tools/bench.py`",
        "(its scenes are in `tools/bench.nim`). Medians of %d runs, the scenes" % runs,
        "taking turns. Run it on your own machine for your own numbers.",
        "",
        "| | |",
        "|---|---|",
        "| Machine | %s, %d cores |" % (cpu, os.cpu_count()),
        "| System | %s %s |" % (platform.system(), platform.release()),
        "| Compiler | %s, `-d:release -d:useMalloc -d:strip` |" % nim,
        "| Drawn on | %s |" % shown,
        "",
        "## At rest",
        "",
        "A number and three buttons, 5 seconds after its first frame, nothing happening.",
        "",
        "| | |",
        "|---|---|",
        "| The program (stripped) | %.1f MB |" % size,
        "| Start to the first frame on screen | %.0f ms |" % med(rest, "startupMs"),
        "| Memory at rest (resident) | %.1f MB |" % med(rest, "restKb", 1 / 1024),
        "| Processor at rest | %.2f%% of a core |" % med(rest, "restCpuPct"),
        "",
        "## Busy",
        "",
        "600 frames, each asked for 16 ms after the last, as a 60 Hz screen would.",
        "",
        "| Scene | Processor a frame | Frames a second | Slowest frames (99th percentile) | Most memory |",
        "|---|---|---|---|---|",
    ]
    names = {"list": "A list: 100,000 rows of three texts, scrolled 8 pixels a frame",
             "dashboard": "A dashboard: 600 cells, each its own color and a number changing every frame",
             "document": "A document: 40 paragraphs (20,000 letters) wrapped to a new width every frame"}
    for s in ["list", "dashboard", "document"]:
        lines.append("| %s | %.2f ms | %.1f | %.1f ms | %.1f MB |" % (
            names[s], med(s, "cpuMsPerFrame"), med(s, "fps"), med(s, "p99Ms"),
            med(s, "peakKb", 1 / 1024)))
    lines += ["",
              "The processor's time is the whole process's (every thread). The frame rate",
              "stops at the 62 frames a second the scenes ask for (one each 16 ms); the",
              "slowest frames are the time between frames as each starts.",
              ""]
    path = os.path.join(ROOT, "docs", "benchmarks.md")
    open(path, "w").write("\n".join(lines))
    print("\n".join(lines))
    print("written:", path)


if __name__ == "__main__":
    main()
