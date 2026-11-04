# AI Usage Tracker

A Mac menu bar app that shows how much of your AI plan limits you have left, and where your usage went.
Your data stays on your Mac.

Status: early. The menu bar app and command line tool run on one Mac, and setup is still manual.

## Menu bar app

```sh
scripts/build-app.sh
open "dist/AI Usage Tracker.app"
```

The menu bar shows whichever limit is fuller. The panel shows both limits, your pace, how recent the
readings are, and today's logged usage. It checks for new data every 30 seconds and never sends
anything to Claude.

Limit readings come from the status line script described under Step 1, so they only change when
Claude Code receives a reply.

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

Claude Code doesn't log every request. In one measured session, the logs held 69% of the tokens shown
by `/usage`. Most of the difference was cache reads, and output was within 5%, so treat these totals
as a lower bound.

## Step 1: testing the data

`scripts/statusline-capture.sh` is a Claude Code status line command. It saves limit readings to
`~/Library/Application Support/AIUsageTracker/readings.jsonl`. It saves only the limit values, session
cost, session ID, Claude Code version and a timestamp, never messages.

See the results with:

```sh
python3 -I scripts/step1-report.py
```

To turn it off, remove the `statusLine` key from `~/.claude/settings.json`.
