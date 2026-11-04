#!/bin/bash
# Claude Code status line command: saves limit readings and prints a short summary.
# Saves only rate_limits, session cost, the session ID, the Claude Code version and a timestamp.
# Reversible: remove the "statusLine" key from ~/.claude/settings.json.

DIR="${AI_USAGE_TRACKER_DIR:-$HOME/Library/Application Support/AIUsageTracker}"
JQ=/usr/bin/jq

input=$(cat)
now=$(date +%s)

mkdir -p "$DIR" 2>/dev/null
printf '%s' "$input" | "$JQ" -c --argjson t "$now" \
  '{t: $t, session: .session_id, version: .version, cost_usd: (.cost.total_cost_usd // null), rate_limits: (.rate_limits // null)}' \
  >> "$DIR/readings.jsonl" 2>/dev/null

printf '%s' "$input" | "$JQ" -r '
  def pct($w): if $w.used_percentage == null then "–" else "\($w.used_percentage | floor)%" end;
  if .rate_limits == null then "limits: waiting for first reply"
  else "5h \(pct(.rate_limits.five_hour // {})) · 7d \(pct(.rate_limits.seven_day // {}))"
  end' 2>/dev/null

exit 0
