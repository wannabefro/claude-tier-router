#!/usr/bin/env bash
# Fixture tests for tier-router.sh and stats.sh. Each case pipes a canned hook
# input through the script with controlled policy/override paths and asserts
# on stdout; log/stats cases grep a per-case log or output file instead.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/../hooks/tier-router.sh"
STATS="$DIR/../stats.sh"
FX="$DIR/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export TIER_ROUTER_LOG="$TMP/test.log"

PASS=0; FAIL=0

run() { # policy override_file input_fixture -> stdout
  local policy="$1" override="$2" input="$3"
  local ov="$TMP/no-override.json"
  [ -n "$override" ] && ov="$FX/$override"
  TIER_ROUTER_POLICY="$FX/$policy" TIER_ROUTER_OVERRIDE="$ov" "$SCRIPT" <"$FX/$input"
}

check() { # name expected_jq_expr actual_output
  local name="$1" expr="$2" out="$3"
  if [ -z "$expr" ]; then
    if [ -z "$out" ]; then echo "PASS: $name"; PASS=$((PASS+1)); else echo "FAIL: $name — expected no output, got: $out"; FAIL=$((FAIL+1)); fi
  else
    if echo "$out" | jq -e "$expr" >/dev/null 2>&1; then echo "PASS: $name"; PASS=$((PASS+1)); else echo "FAIL: $name — expr '$expr' false for: ${out:-<empty>}"; FAIL=$((FAIL+1)); fi
  fi
}

check_log() { # name pattern file -> greps pattern as a literal substring
  local name="$1" pattern="$2" file="$3"
  if [ -f "$file" ] && grep -qF -- "$pattern" "$file" 2>/dev/null; then
    echo "PASS: $name"; PASS=$((PASS+1))
  else
    echo "FAIL: $name — pattern '$pattern' not found in ${file}"; FAIL=$((FAIL+1))
  fi
}

days_ago() { # n -> YYYY-MM-DD in UTC
  date -u -v-"$1"d +%Y-%m-%d 2>/dev/null || date -u -d "$1 days ago" +%Y-%m-%d
}

# 1. allowlist: listed type, no model -> tier injected, ALL original fields preserved
out="$(run policy-shipped.json "" input-explore-nomodel.json)"
check "allowlist listed type injects sonnet" \
  '.hookSpecificOutput.updatedInput.model == "sonnet" and .hookSpecificOutput.updatedInput.prompt == "look around" and .hookSpecificOutput.updatedInput.description == "explore" and .hookSpecificOutput.updatedInput.run_in_background == true' "$out"

# 2. allowlist: unlisted type, no model -> untouched (frontmatter-pinned agents safe)
out="$(run policy-shipped.json "" input-custom-nomodel.json)"
check "allowlist unlisted type untouched" "" "$out"

# 3. all-except-skip: unknown type -> default tier
out="$(run policy-aes.json "" input-custom-nomodel.json)"
check "all-except-skip unknown -> default sonnet" '.hookSpecificOutput.updatedInput.model == "sonnet"' "$out"

# 4. all-except-skip: haiku-listed type -> haiku
out="$(run policy-aes.json "" input-statusline-nomodel.json)"
check "all-except-skip haiku list -> haiku" '.hookSpecificOutput.updatedInput.model == "haiku"' "$out"

# 5. all-except-skip: skip-listed (fork, Plan) -> untouched
out="$(run policy-aes.json "" input-fork-nomodel.json)"
check "all-except-skip fork skipped" "" "$out"
out="$(run policy-aes.json "" input-plan-nomodel.json)"
check "all-except-skip Plan skipped" "" "$out"

# 6. explicit model on routed type -> pass-through
out="$(run policy-shipped.json "" input-explore-opus.json)"
check "explicit model passes through" "" "$out"

# 7. deny rule match (override adds implementer+opus deny)
out="$(run policy-shipped.json override-sam.json input-implementer-opus.json)"
check "deny implementer+opus with override" \
  '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | length > 0)' "$out"

# 8. shipped default: implementer+opus denied out of the box (closes the never-promote-above-Sonnet gap)
out="$(run policy-shipped.json "" input-implementer-opus.json)"
check "shipped policy denies implementer+opus" \
  '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | length > 0)' "$out"

# 9. shipped default: implementer+fable denied out of the box (Fable is a tier above Opus)
out="$(run policy-shipped.json "" input-implementer-fable.json)"
check "shipped policy denies implementer+fable" \
  '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | length > 0)' "$out"

# 10. shipped default: no-model implementer routed to sonnet instead of inheriting the main-thread model
out="$(run policy-shipped.json "" input-implementer-nomodel.json)"
check "shipped policy routes no-model implementer to sonnet" \
  '.hookSpecificOutput.updatedInput.model == "sonnet"' "$out"

# 11. sync guard: canonical policy.json and its test mirror must not drift
if diff -q <(jq -S . "$DIR/../policy.json") <(jq -S . "$FX/policy-shipped.json") >/dev/null 2>&1; then
  echo "PASS: policy.json and tests/fixtures/policy-shipped.json are in sync"; PASS=$((PASS+1))
else
  echo "FAIL: policy.json and tests/fixtures/policy-shipped.json have drifted"; FAIL=$((FAIL+1))
fi

# 12. malformed override -> shipped policy still routes
out="$(run policy-shipped.json override-malformed.json input-explore-nomodel.json)"
check "malformed override ignored, shipped policy routes" '.hookSpecificOutput.updatedInput.model == "sonnet"' "$out"

# 13. override array replaces wholesale (skip list replaced drops Plan)
out="$(run policy-aes.json override-replace-skip.json input-plan-nomodel.json)"
check "override replaces skip array (Plan now routed)" '.hookSpecificOutput.updatedInput.model == "sonnet"' "$out"

# 14. invalid tier value -> no injection
out="$(run policy-badtier.json "" input-explore-nomodel.json)"
check "invalid tier (sonet) not injected" "" "$out"

# 15. malformed stdin -> fail open
out="$(echo 'not json{{{' | TIER_ROUTER_POLICY="$FX/policy-shipped.json" TIER_ROUTER_OVERRIDE="$TMP/none.json" "$SCRIPT")"
check "malformed stdin fails open" "" "$out"

# 16. missing policy.json -> fail open
out="$(TIER_ROUTER_POLICY="$TMP/missing.json" TIER_ROUTER_OVERRIDE="$TMP/none.json" "$SCRIPT" <"$FX/input-explore-nomodel.json")"
check "missing policy fails open" "" "$out"

# 17. Agent tool_name variant handled same as Task
out="$(run policy-shipped.json "" input-explore-agenttool.json)"
check "Agent tool_name variant routed" '.hookSpecificOutput.updatedInput.model == "sonnet"' "$out"

# 18. injection path enforces deny: a misconfigured route resolving to a denied tier blocks, not injects
out="$(run policy-denyinject.json "" input-implementer-nomodel.json)"
check "inject-path deny blocks misconfigured route" \
  '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | length > 0)' "$out"
LOGFILE="$TMP/case18.log"
TIER_ROUTER_LOG="$LOGFILE" run policy-denyinject.json "" input-implementer-nomodel.json >/dev/null
check_log "inject-path deny logs via=inject" "action=deny tier=opus via=inject" "$LOGFILE"

# 19. inject-path regression guard: unrelated agent still injects; a deny entry missing "model" doesn't false-match by agent alone
out="$(run policy-denyinject.json "" input-explore-nomodel.json)"
check "inject-path deny doesn't block unrelated agent / model-less deny entry" \
  '.hookSpecificOutput.updatedInput.model == "sonnet"' "$out"

# 20. malformed deny array on injection path fails open (genuine jq failure falls through to normal injection)
out="$(run policy-denyinject-malformed.json "" input-implementer-nomodel.json)"
check "malformed deny array fails open on injection path" '.hookSpecificOutput.updatedInput.model == "opus"' "$out"

# 21. explicit denied dispatch logs via=explicit
LOGFILE="$TMP/case21.log"
TIER_ROUTER_LOG="$LOGFILE" run policy-shipped.json override-sam.json input-implementer-opus.json >/dev/null
check_log "explicit deny logs via=explicit" "action=deny tier=opus via=explicit" "$LOGFILE"

# 22. explicit non-denied dispatch: stdout untouched, log gains an action=explicit line
LOGFILE="$TMP/case22.log"
out="$(TIER_ROUTER_LOG="$LOGFILE" run policy-shipped.json "" input-explore-opus.json)"
check "explicit non-denied dispatch leaves stdout untouched" "" "$out"
check_log "explicit non-denied dispatch logs action=explicit" "agent=Explore action=explicit tier=opus" "$LOGFILE"

# 23. stats.sh: sample log with known mixed lines -> counts by action, action x tier, agent, and deny by via
OUTFILE="$TMP/stats-sample.out"
TIER_ROUTER_LOG="$FX/log-sample.txt" "$STATS" >"$OUTFILE" 2>&1
check_log "stats: action counts (inject)" "inject: 3" "$OUTFILE"
check_log "stats: action counts (deny)" "deny: 2" "$OUTFILE"
check_log "stats: action counts (explicit)" "explicit: 2" "$OUTFILE"
check_log "stats: action x tier (inject sonnet)" "inject sonnet: 2" "$OUTFILE"
check_log "stats: by agent (implementer)" "implementer: 3" "$OUTFILE"
check_log "stats: deny by via=explicit" "explicit: 1" "$OUTFILE"
check_log "stats: deny by via=inject" "inject: 1" "$OUTFILE"

# 24. stats.sh: days-window argument excludes lines older than the window
WINLOG="$TMP/window.log"
TODAY="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OLDDAY="$(days_ago 10)T09:00:00Z"
{
  echo "$TODAY tool=Task agent=Explore action=inject tier=sonnet"
  echo "$OLDDAY tool=Task agent=Explore action=inject tier=sonnet"
} >"$WINLOG"
WINOUT="$TMP/window.out"
TIER_ROUTER_LOG="$WINLOG" "$STATS" 2 >"$WINOUT" 2>&1
check_log "stats: days-window excludes lines older than the window" "inject: 1" "$WINOUT"

# 25. stats.sh: non-integer argument -> usage message, exit 1
STATS_OUT="$("$STATS" abc 2>&1)"; STATS_RC=$?
if [ "$STATS_RC" -eq 1 ] && echo "$STATS_OUT" | grep -qi usage; then
  echo "PASS: stats.sh non-integer argument -> usage, exit 1"; PASS=$((PASS+1))
else
  echo "FAIL: stats.sh non-integer argument -> usage, exit 1 (rc=$STATS_RC out=$STATS_OUT)"; FAIL=$((FAIL+1))
fi

# 26. stats.sh: missing/empty log -> friendly message, exit 0, no error output
STATS_ERR="$TMP/stats-missing.err"
STATS_OUT="$(TIER_ROUTER_LOG="$TMP/does-not-exist.log" "$STATS" 2>"$STATS_ERR")"; STATS_RC=$?
if [ "$STATS_RC" -eq 0 ] && [ -n "$STATS_OUT" ] && [ ! -s "$STATS_ERR" ]; then
  echo "PASS: stats.sh missing log -> friendly message, exit 0"; PASS=$((PASS+1))
else
  echo "FAIL: stats.sh missing log -> friendly message, exit 0 (rc=$STATS_RC out=$STATS_OUT err=$(cat "$STATS_ERR" 2>/dev/null))"; FAIL=$((FAIL+1))
fi

# 27. CLAUDE_CONFIG_DIR profile: override read from and log written under the profile dir
PROFILE="$TMP/profile"
mkdir -p "$PROFILE"
cat >"$PROFILE/tier-router.json" <<'EOF'
{"deny": [{"agent": "Explore", "model": "opus", "reason": "profile-dir override active"}]}
EOF
out="$(env -u TIER_ROUTER_OVERRIDE -u TIER_ROUTER_LOG CLAUDE_CONFIG_DIR="$PROFILE" TIER_ROUTER_POLICY="$FX/policy-shipped.json" "$SCRIPT" <"$FX/input-explore-opus.json")"
check "CLAUDE_CONFIG_DIR: profile override honored" \
  '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("profile-dir"))' "$out"
check_log "CLAUDE_CONFIG_DIR: log written under profile dir" "agent=Explore action=deny tier=opus via=explicit" "$PROFILE/hooks/state/tier-router.log"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
