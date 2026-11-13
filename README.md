# AI Usage Tracker

A Mac menu bar app that shows how much of your Claude plan limits you have left, and where your usage went.
Your data stays on your Mac.

Status: early. Requires macOS 15 or later.

## Install

[Download AI-Usage-Tracker.dmg](https://github.com/ricoarrigoni/ai-usage-tracker/releases/latest/download/AI-Usage-Tracker.dmg)
(always the newest version, also on the [Releases page](https://github.com/ricoarrigoni/ai-usage-tracker/releases)), open it, and drag
**AI Usage Tracker** to **Applications**. The app is signed and notarized by Apple.

Or [build it from source](#build-from-source).

### Turn on limit readings

Your session and weekly limits come from Claude Code's status line. To turn them on, add this to
`~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "\"/Applications/AI Usage Tracker.app/Contents/Resources/statusline-capture.sh\""
  }
}
```

If you built from source, you can point it at `scripts/statusline-capture.sh` in this folder instead.

This **replaces any status line you already have**. To turn it off, remove the `statusLine` key. The
script saves only the limit values, session cost, session ID, Claude Code version and a timestamp to
`~/Library/Application Support/AIUsageTracker/readings.jsonl`, never messages. It uses `/usr/bin/jq`,
which comes with macOS 15.

## Privacy

- The app reads Claude Code logs and any Cowork logs on your Mac and saves only numbers, model,
  project path, session ID and timestamps to `~/Library/Application Support/AIUsageTracker`.
  Message text is never read into the database.
- It never signs in to your Claude account and never sends your usage anywhere: there is no
  analytics or tracking.
- If your Mac's currency isn't US dollars, it downloads the European Central Bank's reference rates
  once a day. That request carries nothing about you or your usage.
- To remove everything it stored, quit the app and delete `~/Library/Application Support/AIUsageTracker`.

See [SECURITY.md](SECURITY.md) to report a security problem.

## Menu bar app

The menu bar shows whichever limit is fuller. The panel shows your current session and weekly limits,
your pace, how recent the readings are, what your logged use would cost at API prices, and today's
usage. **History…** opens a window with usage and cost per day, by project and by model, and your
sessions. A session is Claude's 5-hour limit window. The app checks for new data every 30 seconds.

It sends one notification per window at 80% and at 95%, and has an **Open at login** checkbox.

"Where your limit went" is an estimate. The app measures how many session limit points a dollar of Claude
Code use costs, using Claude Code's own session cost. Any rise that doesn't explain goes to "Chat, Cowork
& other". It stays in "still measuring" until it has three rises of at least 3 points to compare, and
sessions with no status line, such as `claude -p`, count as "other".

Limit readings only change when Claude Code receives a reply.

Costs apply API list prices to the tokens in your logs, including cache reads and writes. They show what
the same use would cost on the API, not what your plan costs. The logs miss some background requests, so
costs are a lower bound. Update `Sources/UsageCore/Pricing.swift` when prices or models change.

Costs appear in the currency of your Mac's region, because your Claude account's billing currency isn't
available on this Mac. Past costs use the latest rate, and amounts stay in dollars until a rate is
available or if the bank doesn't list your currency.

## Build from source

Requires macOS 15 or later and Xcode.

```sh
git clone https://github.com/ricoarrigoni/ai-usage-tracker.git
cd ai-usage-tracker
scripts/install-app.sh   # builds, copies to /Applications and opens it
```

The build signs with your Apple Development certificate when there is one, so macOS keeps the app's
permissions across rebuilds. Without one it uses an ad hoc signature, which works on your own Mac.

## Command line tool

Run it from this folder:

```sh
swift run -c release aiusage                         # today, 7 days, 30 days, everything recorded
swift run -c release aiusage --by project --days 7   # or day, model, source
swift run -c release aiusage --by model --json       # exact numbers
swift test
```

History stays in the database after Claude Code deletes old logs, but logs deleted before the first sync
can't be recovered. Chat has no token counts on this Mac.

Claude Code doesn't log every request. In one measured session, the logs held 69% of the tokens shown
by `/usage`. Most of the difference was cache reads, and output was within 5%, so treat these totals
as a lower bound.

To check the limit readings themselves:

```sh
python3 -I scripts/step1-report.py
```

## Development

`swift run panel-snapshot` renders the panel and history window to `snapshots/`, using your real data.
Git ignores that folder and all `.png`, `.dmg`, `.sqlite` and `.jsonl` files so personal usage can't be
committed by accident. To add an image on purpose, use `git add -f`.

### Making a release

`scripts/make-dmg.sh` builds a signed, notarized `dist/AI-Usage-Tracker.dmg`. It needs a
Developer ID Application certificate and saved notarization credentials; the one-time setup is at the
top of the script. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `packaging/Info.plist`,
run the script, then attach the `.dmg` to a GitHub release. Keep the file name unchanged so the
download link in this README and on the project page keeps working:

```sh
gh release create v0.1.0 dist/AI-Usage-Tracker.dmg --title "0.1.0" --notes "First release"
```

## License

[MIT](LICENSE)
