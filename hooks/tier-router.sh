#!/usr/bin/env bash
# PreToolUse tier router for Agent/Task dispatches.
#
# Subagents default to `model: inherit`, so every dispatch without an explicit
# model runs on the main-thread model — usually the most expensive tier. This
# hook injects a policy-driven default model into dispatches that don't set
# one, and can deny configured agent+model combinations.
#
# Policy resolution: shipped policy.json, overlaid by ~/.claude/tier-router.json
# (objects deep-merge, arrays and scalars REPLACE). A malformed override is
# ignored — the shipped policy stays active.
#
# Explicit models are never modified (per-invocation > frontmatter, so blanket
# injection would silently override author-pinned agents; `allowlist` mode
# guards the same risk for unlisted agents) — they are only ever passed
# through or denied. Deny rules also apply to the injected tier, so a
# misconfigured route/default can't hand out a combination the policy forbids.
#
# Fail-open by design: any parse/IO error exits 0 with no output, leaving the
# dispatch exactly as it was. A routing hook must never break dispatches.
#
# Returning `permissionDecision: "allow"` does not bypass settings.json
# ask/deny rules — Claude Code re-evaluates those regardless of what a
# PreToolUse hook returns.
#
# NOTE: updatedInput REPLACES the tool input rather than merging (CC #30770),
# so we always emit the full original tool_input with the model merged in.
# Constraint: keep this the ONLY input-modifying hook on Task/Agent — parallel
# hooks that both return updatedInput race (last writer wins).
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_FILE="${TIER_ROUTER_POLICY:-$SCRIPT_DIR/../policy.json}"
OVERRIDE_FILE="${TIER_ROUTER_OVERRIDE:-$HOME/.claude/tier-router.json}"
LOG_FILE="${TIER_ROUTER_LOG:-$HOME/.claude/hooks/state/tier-router.log}"

INPUT="$(cat)" || exit 0
echo "$INPUT" | jq -e . >/dev/null 2>&1 || exit 0

AGENT_TYPE="$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null)"
[ -z "$AGENT_TYPE" ] && exit 0
EXPLICIT_MODEL="$(echo "$INPUT" | jq -r '.tool_input.model // empty' 2>/dev/null)"
TOOL_NAME="$(echo "$INPUT" | jq -r '.tool_name // "?"' 2>/dev/null)"

POLICY="$(cat "$POLICY_FILE" 2>/dev/null)" || exit 0
echo "$POLICY" | jq -e . >/dev/null 2>&1 || exit 0

# Overlay user override; jq's * deep-merges objects and replaces arrays/scalars.
if [ -f "$OVERRIDE_FILE" ] && jq -e . "$OVERRIDE_FILE" >/dev/null 2>&1; then
  POLICY="$(jq -s '.[0] * .[1]' "$POLICY_FILE" "$OVERRIDE_FILE" 2>/dev/null)" || POLICY="$(cat "$POLICY_FILE")"
fi

log_action() { # action tier [via]
  local via="${3:-}" via_token=""
  [ -n "$via" ] && via_token=" via=$via"
  { mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null &&
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) tool=$TOOL_NAME agent=$AGENT_TYPE action=$1 tier=${2:-}$via_token" >>"$LOG_FILE"; } 2>/dev/null || true
}

deny_reason() { # model -> deny reason for $AGENT_TYPE+model, empty if no match or lookup fails
  echo "$POLICY" | jq -r --arg a "$AGENT_TYPE" --arg m "$1" \
    '(.deny // []) | map(select(.agent == $a and .model == $m)) | first | .reason // empty' 2>/dev/null
}

deny_output() { # reason -> emit the deny hook decision
  jq -n --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
}

# --- Explicit model: pass through unless a deny rule matches -----------------
if [ -n "$EXPLICIT_MODEL" ]; then
  DENIED="$(deny_reason "$EXPLICIT_MODEL")"
  if [ -n "$DENIED" ]; then
    log_action deny "$EXPLICIT_MODEL" explicit
    deny_output "$DENIED"
    exit 0
  fi
  log_action explicit "$EXPLICIT_MODEL"
  exit 0
fi

# --- No model: route per policy mode -----------------------------------------
MODE="$(echo "$POLICY" | jq -r '.mode // "allowlist"')"
TIER=""
if [ "$MODE" = "allowlist" ]; then
  TIER="$(echo "$POLICY" | jq -r --arg a "$AGENT_TYPE" '(.route // {})[$a] // empty')"
  [ -z "$TIER" ] && exit 0
else # all-except-skip
  if echo "$POLICY" | jq -e --arg a "$AGENT_TYPE" '(.skip // []) | index($a)' >/dev/null 2>&1; then
    exit 0
  fi
  if echo "$POLICY" | jq -e --arg a "$AGENT_TYPE" '(.haiku // []) | index($a)' >/dev/null 2>&1; then
    TIER="haiku"
  else
    TIER="$(echo "$POLICY" | jq -r '.default // "sonnet"')"
  fi
fi

case "$TIER" in sonnet|opus|haiku) ;; *) exit 0 ;; esac

# A computed tier can still land on a denied agent+model combo (e.g. a
# misconfigured route/default); block it instead of injecting. A genuine jq
# failure here (malformed deny) falls through to normal injection — fail-open.
DENIED="$(deny_reason "$TIER")"
if [ -n "$DENIED" ]; then
  log_action deny "$TIER" inject
  deny_output "$DENIED"
  exit 0
fi

UPDATED="$(echo "$INPUT" | jq --arg m "$TIER" '.tool_input + {model: $m}' 2>/dev/null)" || exit 0
[ -z "$UPDATED" ] && exit 0

log_action inject "$TIER"

DEBUG="$(echo "$POLICY" | jq -r '.debug // false')"
if [ "$DEBUG" = "true" ]; then
  jq -n --argjson u "$UPDATED" --arg msg "tier-router: $AGENT_TYPE -> $TIER" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", updatedInput: $u}, systemMessage: $msg}'
else
  jq -n --argjson u "$UPDATED" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", updatedInput: $u}}'
fi
exit 0
