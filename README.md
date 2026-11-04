# AI Usage Tracker

A Mac menu bar app that shows how much of your AI plan limits you have left, and where your usage went.
Your data stays on your Mac.

Status: early. The menu bar app and command line tool run on one Mac, and setup is still manual.

## Menu bar app

```sh
scripts/install-app.sh   # builds, copies to /Applications and opens it
```

The app sends one notification per window at 80% and at 95%, and has an **Open at login** checkbox.
It signs with your Apple Development certificate when there is one, so macOS keeps its permissions
across rebuilds.

The menu bar shows whichever limit is fuller. The panel shows your current session and weekly limits,
your pace, how recent the readings are, what your logged use would cost at API prices, and today's
usage. **History…** opens a window with usage and cost per day, by project and by model, and your
sessions. A session is Claude's 5-hour limit window. The app checks for new data every 30 seconds and never sends anything
to Claude.

"Where your limit went" is an estimate. The app measures how many session limit points a dollar of Claude
Code use costs, using Claude Code's own session cost. Any rise that doesn't explain goes to "Chat, Cowork
& other". It stays in "still measuring" until it has three rises of at least 3 points to compare, and
sessions with no status line, such as `claude -p`, count as "other".

Limit readings come from the status line script described under Step 1, so they only change when
Claude Code receives a reply.

Costs apply API list prices to the tokens in your logs, including cache reads and writes. They show what
the same use would cost on the API, not what your plan costs. The logs miss some background requests, so
costs are a lower bound. Update `Sources/UsageCore/Pricing.swift` when prices or models change.

Costs appear in the currency of your Mac's region, because your Claude account's billing currency isn't
available on this Mac. If that currency isn't US dollars, the app downloads the European Central Bank's
reference rates once a day. That request carries nothing about you or your usage. Past costs use the
latest rate, and amounts stay in dollars until a rate is available or if the bank doesn't list your
currency.

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
