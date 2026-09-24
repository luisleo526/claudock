#!/usr/bin/env python3
"""Measure scrolling in the real Claudock app with synthetic demo profiles.

Builds the release app, launches `ClaudockApp --demo --demo-profiles N` with the
opt-in performance probe, and lets the probe's `scroll` scenario open the dashboard
Accounts list and then the Manage profiles sheet, scrolling each top -> bottom -> top
several times. Prints frame pacing, main-thread stalls, and view-body evaluations.

Demo mode only: no real profiles, Keychain items, shell files, or network requests.
The app window opens on screen for about a minute; the process is always stopped by
its PID. Frame pacing uses the display link when a display is awake, otherwise the
probe's 60 Hz main-run-loop timer (for example while the screen is locked).

    scripts/perf-scroll.py                      # build, one run, print a summary
    scripts/perf-scroll.py --runs 3 --out DIR   # best of three, keep logs and snapshots
    scripts/perf-scroll.py --compare before/summary.json after/summary.json
"""

import argparse
import json
import os
from pathlib import Path
import signal
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
PHASES = ["accounts-idle", "accounts-scroll", "manager-open", "manager-scroll"]
# Lower is better for every reported metric.
METRICS = ["p50_ms", "p95_ms", "p99_ms", "max_ms", "hitches", "over_50ms", "hitch_ms_per_s",
           "stall_max_ms", "stall_cpu_max_ms", "stalls_over_16_7ms", "stalls_over_50ms", "busy_ms_per_s", "cpu_ms_per_s"]


# Match scripts/build-app.sh: prefer a full Xcode toolchain when one is installed.
TOOLCHAIN = dict(os.environ)
if "DEVELOPER_DIR" not in TOOLCHAIN and Path("/Applications/Xcode.app/Contents/Developer").is_dir():
    TOOLCHAIN["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"


def binary_path(build):
    if build:
        subprocess.run(["xcrun", "swift", "build", "-c", "release", "--product", "ClaudockApp"], cwd=ROOT, env=TOOLCHAIN, check=True)
    bin_path = subprocess.run(["xcrun", "swift", "build", "-c", "release", "--show-bin-path"], cwd=ROOT, env=TOOLCHAIN,
                              check=True, capture_output=True, text=True).stdout.strip()
    return Path(bin_path) / "ClaudockApp"


def run_once(binary, directory, profiles, passes, speed, timeout, app_arguments):
    directory.mkdir(parents=True, exist_ok=True)
    log = directory / "perf.jsonl"
    environment = {**os.environ, "CLAUDOCK_PERF_LOG": str(log), "CLAUDOCK_PERF_SCENARIO": "scroll",
                   "CLAUDOCK_PERF_PASSES": str(passes), "CLAUDOCK_PERF_SPEED": str(speed),
                   "CLAUDOCK_PERF_SNAPSHOTS": str(directory)}
    with open(directory / "app.log", "w") as output:
        process = subprocess.Popen([str(binary), "--demo", "--demo-profiles", str(profiles), *app_arguments], cwd=directory,
                                   env=environment, stdout=output, stderr=subprocess.STDOUT)
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            raise RuntimeError(f"scenario did not finish within {timeout}s; see {directory}")
    return log


def percentile(values, fraction):
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(fraction * (len(ordered) - 1))))]


def analyze(log):
    records = [json.loads(line) for line in log.read_text().splitlines() if line.strip()]
    start = next((r for r in records if r["type"] == "start"), {})
    notes = [r["message"] for r in records if r["type"] == "note"]
    marks, cpu = {}, {}
    for record in records:
        if record["type"] == "mark":
            marks.setdefault(record["name"], {})[record["phase"]] = record["t"]
            cpu.setdefault(record["name"], {})[record["phase"]] = record.get("cpu_ms", 0)
    frames = [r for r in records if r["type"] == "frame"]
    source = "display" if len(frames) > 30 else "timer"
    intervals = frames if source == "display" else [r for r in records if r["type"] == "tick"]
    busy = [r for r in records if r["type"] == "busy"]
    counts = [r for r in records if r["type"] == "counts"]

    def counts_at(moment):
        latest = {}
        for record in counts:
            if record["t"] <= moment + 1e-4:
                latest = record["c"]
        return latest

    phases = {}
    for name in PHASES:
        span = marks.get(name, {})
        if "begin" not in span or "end" not in span:
            continue
        begin, end = span["begin"], span["end"]
        duration = max(end - begin, 1e-6)
        inside = [r for r in intervals if begin < r["t"] <= end]
        values = [r["ms"] for r in inside]
        nominal = statistics.median([r.get("nominal", 1000 / 60) for r in inside]) if inside else 1000 / 60
        spans = [r for r in busy if begin < r["t"] <= end]
        stalls = [r["ms"] for r in spans]
        before, after = counts_at(begin), counts_at(end)
        phases[name] = {
            "seconds": round(duration, 2), "frames": len(values), "nominal_ms": round(nominal, 2),
            "p50_ms": round(percentile(values, 0.50), 2), "p95_ms": round(percentile(values, 0.95), 2),
            "p99_ms": round(percentile(values, 0.99), 2), "max_ms": round(max(values, default=0), 2),
            "hitches": sum(1 for v in values if v > 1.5 * nominal),
            "over_16_7ms": sum(1 for v in values if v > 16.7), "over_50ms": sum(1 for v in values if v > 50),
            "hitch_ms_per_s": round(sum(max(0.0, v - nominal) for v in values if v > 1.5 * nominal) / duration, 1),
            "stall_max_ms": round(max(stalls, default=0), 1),
            "stall_cpu_max_ms": round(max((r.get("cpu_ms", r["ms"]) for r in spans), default=0), 1),
            "stalls_over_16_7ms": sum(1 for v in stalls if v > 16.7), "stalls_over_50ms": sum(1 for v in stalls if v > 50),
            "busy_ms_per_s": round(sum(stalls) / duration, 1),
            "cpu_ms_per_s": round((cpu[name]["end"] - cpu[name]["begin"]) / duration, 1),
            "evaluations": {key: after.get(key, 0) - before.get(key, 0) for key in sorted(set(after) | set(before))},
        }
    return {"source": source, "locked": start.get("locked"), "fps": start.get("fps"), "notes": notes, "phases": phases}


def combine(runs):
    combined = {}
    for name in PHASES:
        samples = [run["phases"][name] for run in runs if name in run["phases"]]
        if not samples:
            continue
        best = {metric: min(sample[metric] for sample in samples) for metric in METRICS}
        median = {metric: statistics.median(sample[metric] for sample in samples) for metric in METRICS}
        keys = sorted({key for sample in samples for key in sample["evaluations"]})
        best["evaluations"] = {key: min(sample["evaluations"].get(key, 0) for sample in samples) for key in keys}
        combined[name] = {"best": best, "median": median, "runs": len(samples)}
    return combined


def print_summary(summary):
    print(f"\nframe source: {summary['source']} ({summary['fps']} Hz screen, locked={summary['locked']}); "
          f"best of {summary['runs']} run(s); times in ms")
    header = f"{'phase':<16}{'p50':>7}{'p95':>7}{'p99':>7}{'max':>8}{'hitch':>7}{'>50':>5}{'hitch/s':>9}" \
             f"{'stall':>8}{'cpu':>7}{'>16.7':>7}{'>50':>5}{'busy/s':>8}{'cpu/s':>7}  evaluations"
    print(header)
    for name, phase in summary["phases"].items():
        best = phase["best"]
        evaluations = ", ".join(f"{key}={value}" for key, value in best["evaluations"].items() if value)
        print(f"{name:<16}{best['p50_ms']:>7.1f}{best['p95_ms']:>7.1f}{best['p99_ms']:>7.1f}{best['max_ms']:>8.1f}"
              f"{best['hitches']:>7}{best['over_50ms']:>5}{best['hitch_ms_per_s']:>9.1f}{best['stall_max_ms']:>8.1f}"
              f"{best['stall_cpu_max_ms']:>7.1f}{best['stalls_over_16_7ms']:>7}{best['stalls_over_50ms']:>5}"
              f"{best['busy_ms_per_s']:>8.1f}{best['cpu_ms_per_s']:>7.1f}  {evaluations}")
    print("hitch = frame interval > 1.5x nominal; stall = longest uninterrupted main run-loop span (wall, then its CPU); "
          "busy/s = main-thread wall ms per second in spans >= 4 ms; cpu/s = main-thread CPU ms per second")


def compare(before_path, after_path):
    before, after = json.loads(Path(before_path).read_text()), json.loads(Path(after_path).read_text())
    print(f"{'phase':<16}{'metric':<22}{'before':>10}{'after':>10}{'change':>9}")
    for name in PHASES:
        if name not in before["phases"] or name not in after["phases"]:
            continue
        first, second = before["phases"][name]["best"], after["phases"][name]["best"]
        rows = [(metric, first[metric], second[metric]) for metric in METRICS]
        rows += [(key, first["evaluations"].get(key, 0), second["evaluations"].get(key, 0))
                 for key in sorted(set(first["evaluations"]) | set(second["evaluations"]))]
        for metric, old, new in rows:
            change = "" if old == 0 else f"{(new - old) / old * 100:+.0f}%"
            print(f"{name:<16}{metric:<22}{old:>10}{new:>10}{change:>9}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--profiles", type=int, default=40)
    parser.add_argument("--passes", type=int, default=3)
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--speed", type=float, default=2400, help="scroll speed in points per second")
    parser.add_argument("--timeout", type=float, default=240)
    parser.add_argument("--sort-by-usage", action="store_true", help="enable Highest usage first for this run only")
    parser.add_argument("--out", type=Path, help="directory for logs, snapshots, and summary.json")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--compare", nargs=2, metavar=("BEFORE", "AFTER"), help="print a table from two summary.json files")
    arguments = parser.parse_args()
    if arguments.compare:
        compare(*arguments.compare)
        return
    if sys.platform != "darwin":
        sys.exit("Claudock performance runs require macOS.")
    binary = binary_path(build=not arguments.skip_build)
    # Settings passed as arguments apply to this process only; saved preferences are untouched.
    app_arguments = ["-sortByUsage", "YES"] if arguments.sort_by_usage else []
    out = arguments.out or Path(tempfile.mkdtemp(prefix="claudock-perf-"))
    runs = []
    for index in range(arguments.runs):
        directory = out / f"run-{index + 1}"
        print(f"run {index + 1}/{arguments.runs}: {directory}", flush=True)
        run = analyze(run_once(binary, directory, arguments.profiles, arguments.passes, arguments.speed, arguments.timeout, app_arguments))
        if run["notes"] or len(run["phases"]) < len(PHASES):
            sys.exit(f"scenario incomplete: {run['notes'] or sorted(run['phases'])}")
        (directory / "analysis.json").write_text(json.dumps(run, indent=2))
        runs.append(run)
        time.sleep(1)
    summary = {"profiles": arguments.profiles, "passes": arguments.passes, "runs": len(runs), "app_arguments": app_arguments,
               "source": runs[0]["source"],
               "fps": runs[0]["fps"], "locked": runs[0]["locked"], "phases": combine(runs)}
    (out / "summary.json").write_text(json.dumps(summary, indent=2))
    print_summary(summary)
    print(f"\nlogs, snapshots, and summary.json: {out}")


if __name__ == "__main__":
    main()
