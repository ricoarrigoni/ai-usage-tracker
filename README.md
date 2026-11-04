# AI Usage Tracker

A Mac menu bar app that shows how much of your AI plan limits you have left, and where your usage went.
Your data stays on your Mac.

Status: the log reader and command line tool work. There is no menu bar app yet.

## Command line tool

Requires macOS 15 or later and Xcode. Run it from this folder:

```sh
swift run -c release aiusage                         # today, 7 days, 30 days, everything recorded
swift run -c release aiusage --by project --days 7   # or day, model, source
swift run -c release aiusage --by model --json       # exact numbers
swift test
```

It counts tokens from Claude Code logs and any Cowork logs on this Mac, and saves only numbers,
model, project path, session ID and timestamps to
`~/Library/Application Support/AIUsageTracker/usage.sqlite`. Message text is never read into the
database, and nothing leaves your Mac. History stays in the database after Claude Code deletes old
logs, but logs deleted before the first sync can't be recovered. Chat has no token counts on this Mac.

## Step 1: testing the data

`scripts/statusline-capture.sh` is a Claude Code status line command. It saves limit readings to
`~/Library/Application Support/AIUsageTracker/readings.jsonl`. It saves only the limit values, session
ID, Claude Code version and a timestamp, never messages.

See the results with:

```sh
python3 -I scripts/step1-report.py
```

To turn it off, remove the `statusLine` key from `~/.claude/settings.json`.
