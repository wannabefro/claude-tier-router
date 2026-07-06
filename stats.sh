#!/usr/bin/env bash
# Summarizes hooks/tier-router.sh's log: counts by action, action x tier, by
# agent, and deny sources by via. Read-only; tolerates a missing/empty log.
set -uo pipefail

usage() { echo "usage: stats.sh [DAYS]" >&2; }

if [ $# -gt 1 ]; then
  usage
  exit 1
fi

DAYS=""
if [ $# -eq 1 ]; then
  case "$1" in
    ''|0|*[!0-9]*) usage; exit 1 ;;
    *) DAYS="$1" ;;
  esac
fi

LOG_FILE="${TIER_ROUTER_LOG:-$HOME/.claude/hooks/state/tier-router.log}"

if [ ! -s "$LOG_FILE" ]; then
  echo "No log data at $LOG_FILE yet."
  exit 0
fi

# Timestamps are UTC (date -u in the hook); compute the cutoff the same way.
# BSD date (-v) and GNU date (-d) spell relative offsets differently.
CUTOFF=""
if [ -n "$DAYS" ]; then
  CUTOFF="$(date -u -v-"$DAYS"d +%Y-%m-%d 2>/dev/null || date -u -d "$DAYS days ago" +%Y-%m-%d 2>/dev/null)"
  if [ -z "$CUTOFF" ]; then
    echo "error: could not compute a $DAYS-day cutoff date" >&2
    exit 1
  fi
fi

awk -v cutoff="$CUTOFF" '
  {
    if (cutoff != "" && substr($1, 1, 10) < cutoff) next
    action = ""; tier = ""; agent = ""; via = ""
    for (i = 1; i <= NF; i++) {
      split($i, kv, "=")
      if (kv[1] == "action") action = kv[2]
      else if (kv[1] == "tier") tier = kv[2]
      else if (kv[1] == "agent") agent = kv[2]
      else if (kv[1] == "via") via = kv[2]
    }
    if (action == "") next
    total++
    action_count[action]++
    if (tier != "") action_tier_count[action " " tier]++
    if (agent != "") agent_count[agent]++
    if (action == "deny" && via != "") { deny_via_count[via]++; saw_via = 1 }
  }
  END {
    if (total == 0) { print "No matching log lines in window."; exit 0 }
    print "By action:"
    for (a in action_count) printf "  %s: %d\n", a, action_count[a]
    print ""
    print "By action x tier:"
    for (k in action_tier_count) printf "  %s: %d\n", k, action_tier_count[k]
    print ""
    print "By agent:"
    for (a in agent_count) printf "  %s: %d\n", a, agent_count[a]
    print ""
    print "Deny by source (via):"
    if (saw_via) { for (v in deny_via_count) printf "  %s: %d\n", v, deny_via_count[v] }
    else print "  (none)"
  }
' "$LOG_FILE"
