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
silently override that pin):

```json
{
  "mode": "allowlist",
  "route": {
    "Explore": "sonnet",
    "general-purpose": "sonnet",
    "claude-code-guide": "sonnet",
    "statusline-setup": "haiku"
  },
  "skip": ["fork", "Plan"],
  "deny": [],
  "debug": false
}
```

### User override

Create `~/.claude/tier-router.json` to tune policy without touching the plugin.
Objects deep-merge; **arrays and scalars replace wholesale**. A malformed
override is ignored (shipped policy stays active).

Power-user mode routes everything that isn't skip-listed:

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
      "reason": "Never promote the implementer to Opus — plan harder or route to another model family."
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
| `deny` | `{agent, model, reason}` combos to block even when explicitly requested |
| `debug` | `true` adds a transcript `systemMessage` per routing action (default: log-file only) |

Tiers are validated against `sonnet\|opus\|haiku`; an invalid value skips
injection rather than emitting a broken tool call.

## Behavior details

- **Explicit `model` on a dispatch always wins** — only ever passed through or
  denied, never rewritten.
- **Fail open**: malformed stdin, missing `jq`, unreadable policy → exit 0, no
  output, dispatch proceeds untouched.
- **Log**: one line per routing action (timestamp, agent type, tier — never
  prompt content) to `~/.claude/hooks/state/tier-router.log`, best-effort.
- **Replace-bug safe**: `updatedInput` currently replaces the whole tool input
  (anthropics/claude-code#30770), so the hook always emits the full original
  input with `model` merged in — correct under both replace and merge semantics.
- **Keep this the only input-modifying hook on Agent/Task** — parallel
  `updatedInput` hooks race (last writer wins).
- Hooks fire for main-thread dispatches only (anthropics/claude-code#34692);
  nested subagent dispatches inherit their already-tiered parent.

## Tests

```bash
tests/run.sh
```

Fixture harness — pipes canned hook inputs through the script with controlled
policy/override paths and asserts on stdout. No Claude Code required.

## License

MIT
