# AI Usage Tracker

A Mac menu bar app that shows how much of your AI plan limits you have left, and where your usage went.
Your data stays on your Mac.

Status: testing the data sources. There is no app yet.

## Step 1: testing the data

`scripts/statusline-capture.sh` is a Claude Code status line command. It saves limit readings to
`~/Library/Application Support/AIUsageTracker/readings.jsonl`. It saves only the limit values, session
ID, Claude Code version and a timestamp, never messages.

See the results with:

```sh
python3 -I scripts/step1-report.py
```

To turn it off, remove the `statusLine` key from `~/.claude/settings.json`.
