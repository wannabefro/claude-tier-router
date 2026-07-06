# tier-router

Deterministic model-tier routing for Claude Code subagent dispatches.

## Why

Subagents default to `model: inherit` — every `Agent`/`Task` dispatch without an
explicit model runs on your **main-thread model**. If you drive sessions on an
expensive tier, every exploration, doc lookup, and review persona silently bills
at that tier too.

This plugin is a single PreToolUse hook that injects a policy-driven default
`model` into dispatches that don't set one. Explicit models are never modified,
so deliberate escalation keeps working. Everything is data-driven and fails
open: a routing hook must never break dispatches.

## Install

```bash
claude plugin marketplace add <owner>/claude-tier-router   # or a local path
claude plugin install tier-router@claude-tier-router
```

Restart Claude Code to activate the hook.

## Policy

Shipped defaults (`policy.json`) are conservative — **allowlist mode** routes
only the built-in agents that are safe to tier and never touches agents whose
authors may have pinned a model in frontmatter (a per-invocation model would
silently override that pin). A no-model `implementer` dispatch is routed to
`sonnet` rather than inheriting the main-thread model, and explicit
`implementer`+`opus`/`fable` dispatches are denied out of the box — the
"never promote the implementer above Sonnet" rule is enforced, not just
documented:

```json
{
  "mode": "allowlist",
  "route": {
    "Explore": "sonnet",
    "general-purpose": "sonnet",
    "claude-code-guide": "sonnet",
    "statusline-setup": "haiku",
    "implementer": "sonnet"
  },
  "skip": ["fork", "Plan"],
  "deny": [
    {
      "agent": "implementer",
      "model": "opus",
      "reason": "Never promote the implementer to Opus or above: plan harder so Sonnet can write it, keep it in the main thread, or route to a different family (best-of-n)."
    },
    {
      "agent": "implementer",
      "model": "fable",
      "reason": "Never promote the implementer to Opus or above: plan harder so Sonnet can write it, keep it in the main thread, or route to a different family (best-of-n)."
    }
  ],
  "debug": false
}
```

### User override

Create `~/.claude/tier-router.json` to tune policy without touching the plugin.
Multi-profile setups are respected: with `CLAUDE_CONFIG_DIR` set, the override
is read from (and the log written under) that directory instead of `~/.claude`.
Objects deep-merge; **arrays and scalars replace wholesale** — this includes
`deny`. If your override sets `deny` at all, it must restate any shipped
entries you still want (see the example below); otherwise upgrading past this
version silently drops the shipped `implementer`+`opus`/`fable` protection. A
malformed override is ignored (shipped policy stays active).

Power-user mode routes everything that isn't skip-listed, restating both
shipped deny entries plus a project-specific one:

```json
{
  "mode": "all-except-skip",
  "default": "sonnet",
  "haiku": ["statusline-setup", "my-mechanical-agent"],
  "skip": ["fork", "Plan"],
  "deny": [
    {
      "agent": "implementer",
      "model": "opus",
      "reason": "Never promote the implementer to Opus or above: plan harder so Sonnet can write it, keep it in the main thread, or route to a different family (best-of-n)."
    },
    {
      "agent": "implementer",
      "model": "fable",
      "reason": "Never promote the implementer to Opus or above: plan harder so Sonnet can write it, keep it in the main thread, or route to a different family (best-of-n)."
    }
  ]
}
```

Only use `all-except-skip` when you know your agent roster: it overrides
frontmatter-pinned models on any agent not in `skip`.

### Fields

| Field | Meaning |
|---|---|
| `mode` | `allowlist` (route only `route`-listed types) or `all-except-skip` (route everything not in `skip`) |
| `route` | allowlist mode: `subagent_type` → tier |
| `default` / `haiku` | all-except-skip mode: fallback tier, and types forced to haiku |
| `skip` | types never touched (`fork` ignores model overrides; `Plan` earns main-model reasoning) |
| `deny` | `{agent, model, reason}` combos to block, whether the model was requested explicitly or resolved by routing |
| `debug` | `true` adds a transcript `systemMessage` per routing action (default: log-file only) |

Tiers are validated against `sonnet\|opus\|haiku`; an invalid value skips
injection rather than emitting a broken tool call.

## Behavior details

- **Explicit `model` on a dispatch always wins** — only ever passed through or
  denied, never rewritten.
- **Deny rules apply to both explicit and routed models** — a computed tier
  that matches a deny rule is blocked instead of injected, so a misconfigured
  `route`/`default` can't hand out a combination the policy forbids. Deny
  matches are exact-name only (no wildcard/rank semantics): denying `opus`
  does not deny `fable`, and a future tier above Fable needs its own entry.
- **Permission rules are not bypassed**: per current Claude Code docs, `ask`/
  `deny` rules in `settings.json` are re-evaluated regardless of what this
  hook's `permissionDecision` returns — `allow` + `updatedInput` does not
  skip them. Hooks fire for main-thread dispatches only
  (anthropics/claude-code#34692); nested subagent dispatches inherit their
  already-tiered parent.
- **Fail open**: malformed stdin, missing `jq`, unreadable policy, or a
  malformed `deny` list → exit 0, no output (or normal injection on the
  inject path), dispatch proceeds.
- **Log**: one line per routing action (timestamp, agent type, action, tier —
  never prompt content) to `~/.claude/hooks/state/tier-router.log`,
  best-effort. `action` is `inject`, `deny`, or `explicit` (a non-denied
  explicit-model dispatch); `deny` lines carry a trailing `via=explicit` or
  `via=inject` token identifying which path blocked the dispatch.
- **Replace-bug safe**: `updatedInput` currently replaces the whole tool input
  (anthropics/claude-code#30770), so the hook always emits the full original
  input with `model` merged in — correct under both replace and merge semantics.
- **Keep this the only input-modifying hook on Agent/Task** — parallel
  `updatedInput` hooks race (last writer wins).

## Stats

`stats.sh [DAYS]` summarizes the log: counts by action, by action x tier, by
agent, and deny sources broken out by `via` (explicit escalation blocked vs.
a contradictory routing config). Reads `TIER_ROUTER_LOG`
(default `~/.claude/hooks/state/tier-router.log`); a missing or empty log
prints a friendly message and exits 0. Pass a positive integer to limit to
the last N days:

```bash
stats.sh        # all-time
stats.sh 7      # last 7 days
```

## Tests

```bash
tests/run.sh
```

Fixture harness — pipes canned hook inputs through the script with controlled
policy/override paths and asserts on stdout. No Claude Code required.

## License

MIT
