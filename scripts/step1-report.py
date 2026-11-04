#!/usr/bin/env python3
"""Step 1 report: do limit readings move, and does logged activity explain the movement?

Run with: python3 -I scripts/step1-report.py
Reads numbers, timestamps and file dates only. Never reads or prints message text.
"""
import datetime as dt
import glob
import json
import os
from collections import Counter

HOME = os.path.expanduser("~")
DATA_DIR = os.environ.get("AI_USAGE_TRACKER_DIR", os.path.join(HOME, "Library/Application Support/AIUsageTracker"))
READINGS = os.path.join(DATA_DIR, "readings.jsonl")
WINDOW_SLACK = 60  # seconds; reset times this close count as the same window
DESKTOP = os.path.join(HOME, "Library/Application Support/Claude")


def stamp(t):
    return dt.datetime.fromtimestamp(t).strftime("%m-%d %H:%M")


def merged_timeline(rows):
    """Combine readings from all sessions into one (time, five_hour, seven_day) timeline.

    Open sessions can hold older values or be missing a window. Usage only rises within a
    window, so keep the highest value for the newest window and ignore anything older.
    """
    current = {}
    timeline = []
    for r in rows:
        limits = r.get("rate_limits") or {}
        for name in ("five_hour", "seven_day"):
            w = limits.get(name) or {}
            value, resets = w.get("used_percentage"), w.get("resets_at")
            if value is None or resets is None:
                continue
            have = current.get(name)
            if have is None or resets > have[1] + WINDOW_SLACK:
                current[name] = (value, resets)
            elif resets >= have[1] - WINDOW_SLACK and value > have[0]:
                current[name] = (value, have[1])
        state = tuple((current.get(n) or (None,))[0] for n in ("five_hour", "seven_day"))
        if not timeline or timeline[-1][1:] != state:
            timeline.append((r["t"], *state))
    return timeline


def load_readings():
    if not os.path.exists(READINGS):
        return []
    rows = []
    with open(READINGS, errors="ignore") as f:
        for line in f:
            try:
                rows.append(json.loads(line))
            except ValueError:
                pass
    return sorted(rows, key=lambda r: r["t"])


def load_claude_code_usage():
    """One (time, tokens) per unique response, so repeated log lines count once."""
    by_id = {}
    for path in glob.glob(os.path.join(HOME, ".claude/projects/**/*.jsonl"), recursive=True):
        with open(path, errors="ignore") as f:
            for line in f:
                if '"usage"' not in line:
                    continue
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                m = o.get("message") if isinstance(o, dict) else None
                if not (isinstance(m, dict) and isinstance(m.get("usage"), dict) and m.get("id")):
                    continue
                ts = o.get("timestamp")
                if not ts:
                    continue
                e = by_id.setdefault(m["id"], {"ts": ts, "usage": {}})
                for k, v in m["usage"].items():
                    if isinstance(v, int):
                        e["usage"][k] = max(e["usage"].get(k, 0), v)
    out = []
    for e in by_id.values():
        t = dt.datetime.fromisoformat(e["ts"].replace("Z", "+00:00")).timestamp()
        out.append((t, sum(e["usage"].values())))
    return out


def main():
    rows = load_readings()
    if not rows:
        print("No readings yet. Send a message in Claude Code, then run this again.")
        return

    with_limits = [r for r in rows if r.get("rate_limits")]
    start, end = rows[0]["t"], rows[-1]["t"]
    print(f"Readings: {len(rows)} from {stamp(start)} to {stamp(end)}")
    print(f"With limits: {len(with_limits)}, sessions: {len({r.get('session') for r in rows})}")
    print(f"Windows seen: {dict(Counter(k for r in with_limits for k in r['rate_limits']))}")

    # Long gaps show when nothing was being measured.
    gaps = sorted(((b["t"] - a["t"]) / 3600 for a, b in zip(rows, rows[1:])), reverse=True)
    print(f"Longest gaps (hours): {[round(g, 1) for g in gaps[:5]]}")

    # Each change in a limit, next to the Claude Code activity in that interval.
    usage = load_claude_code_usage()
    print("\nChanges in limits:")
    print(f"{'from':<12} {'to':<12} {'5h':>9} {'7d':>9} {'CC replies':>11} {'CC tokens':>13}")
    timeline = merged_timeline(with_limits)
    for (t0, fh0, sd0), (t1, fh1, sd1) in zip(timeline, timeline[1:]):
        hits = [n for t, n in usage if t0 < t <= t1]
        print(f"{stamp(t0):<12} {stamp(t1):<12} {f'{fh0}>{fh1}':>9} {f'{sd0}>{sd1}':>9} "
              f"{len(hits):>11} {sum(hits):>13,}")
    if timeline:
        print(f"Latest: 5h {timeline[-1][1]}%, 7d {timeline[-1][2]}%")

    # A second, independent source of limit readings.
    path = os.path.join(DESKTOP, "plan-usage-history.json")
    if os.path.exists(path):
        with open(path) as f:
            samples = [s for s in json.load(f).get("samples", []) if s["t"] / 1000 >= start]
        print(f"\nDesktop app readings since start: {len(samples)}")
        for s in samples[-10:]:
            print(f"  {stamp(s['t'] / 1000)}  {s['u']}")

    # Did Cowork leave anything on this Mac?
    fresh = [
        p
        for p in glob.glob(os.path.join(DESKTOP, "local-agent-mode-sessions/**/*.jsonl"), recursive=True)
        if os.path.getmtime(p) >= start
    ]
    print(f"\nCowork log files changed since start: {len(fresh)}")


if __name__ == "__main__":
    main()
