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
READINGS = os.path.join(HOME, "Library/Application Support/AIUsageTracker/readings.jsonl")
DESKTOP = os.path.join(HOME, "Library/Application Support/Claude")


def stamp(t):
    return dt.datetime.fromtimestamp(t).strftime("%m-%d %H:%M")


def pct(reading, window):
    w = (reading.get("rate_limits") or {}).get(window) or {}
    return w.get("used_percentage")


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
    last = with_limits[0] if with_limits else None
    for r in with_limits[1:]:
        fh0, fh1 = pct(last, "five_hour"), pct(r, "five_hour")
        sd0, sd1 = pct(last, "seven_day"), pct(r, "seven_day")
        if (fh0, sd0) == (fh1, sd1):
            continue
        hits = [n for t, n in usage if last["t"] < t <= r["t"]]
        print(f"{stamp(last['t']):<12} {stamp(r['t']):<12} {f'{fh0}>{fh1}':>9} {f'{sd0}>{sd1}':>9} "
              f"{len(hits):>11} {sum(hits):>13,}")
        last = r

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
