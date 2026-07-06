#!/usr/bin/env bash
# Fixture tests for tier-router.sh. Each case pipes a canned hook input through
# the script with controlled policy/override paths and asserts on stdout.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/../hooks/tier-router.sh"
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

# 8. shipped default: same dispatch NOT denied (deny ships empty)
out="$(run policy-shipped.json "" input-implementer-opus.json)"
check "shipped policy does not deny implementer+opus" "" "$out"

# 9. malformed override -> shipped policy still routes
out="$(run policy-shipped.json override-malformed.json input-explore-nomodel.json)"
check "malformed override ignored, shipped policy routes" '.hookSpecificOutput.updatedInput.model == "sonnet"' "$out"

# 10. override array replaces wholesale (skip list replaced drops Plan)
out="$(run policy-aes.json override-replace-skip.json input-plan-nomodel.json)"
check "override replaces skip array (Plan now routed)" '.hookSpecificOutput.updatedInput.model == "sonnet"' "$out"

# 11. invalid tier value -> no injection
out="$(run policy-badtier.json "" input-explore-nomodel.json)"
check "invalid tier (sonet) not injected" "" "$out"

# 12. malformed stdin -> fail open
out="$(echo 'not json{{{' | TIER_ROUTER_POLICY="$FX/policy-shipped.json" TIER_ROUTER_OVERRIDE="$TMP/none.json" "$SCRIPT")"
check "malformed stdin fails open" "" "$out"

# 13. missing policy.json -> fail open
out="$(TIER_ROUTER_POLICY="$TMP/missing.json" TIER_ROUTER_OVERRIDE="$TMP/none.json" "$SCRIPT" <"$FX/input-explore-nomodel.json")"
check "missing policy fails open" "" "$out"

# 14. Agent tool_name variant handled same as Task
out="$(run policy-shipped.json "" input-explore-agenttool.json)"
check "Agent tool_name variant routed" '.hookSpecificOutput.updatedInput.model == "sonnet"' "$out"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
