## Model & sub-agent routing (token economy)

These rules apply to **every** sub-agent you launch, whatever asked for it: your own judgment, a skill, a plugin, a workflow or a slash command. They are the user's standing instructions and take precedence over the defaults of any plugin. When a skill gives its own model guidance for a role ("cheap model", "most capable model"...), keep its intent and map it onto the tiers below.

### 1. Do you need a sub-agent at all?
- Fewer than ~5 tool calls, or you already know which file to open: do it inline.
- You need the raw details (not just a conclusion) to continue: do it inline.
- Never spawn a sub-agent only to "double-check" something you can check yourself.
- Small plans (≤ 3 tasks) or tightly coupled steps: execute inline instead of one sub-agent per task.
- At most 3 sub-agents running at once (also enforced by `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`); queue the rest.
- Per-task review sub-agents only for non-trivial tasks; otherwise one review pass at the end.

### 2. Always set `model` AND `effort` explicitly on every sub-agent dispatch
An omitted model inherits the session model, often the most expensive one. The user explicitly asks you to set both parameters each time (a hook blocks dispatches without a model).

| Tier | `model` | `effort` | Use for |
|---|---|---|---|
| cheap | `haiku` | `low` | search, reading files/docs/web, summarising, mechanical edits with a complete spec (1–2 files) |
| mid (default) | `sonnet` | `medium` | implementation, multi-file integration, debugging, ordinary code review |
| top | `opus` | `medium` | architecture and design, subtle or high-risk review (concurrency, security, data loss), a fix that failed 3+ rounds |

- `effort: "high"` only for a top-tier task that already failed at medium.
- When unsure between two tiers, pick the lower one; escalate only if the result is not good enough.
- For pure research, prefer the `Explore` agent: it is overridden to pin Haiku/low and a small tool set, which makes it far cheaper than `general-purpose` even on the same model.

### 3. Suggest a session model switch to the user
If the main session model looks oversized or undersized for the current task, say so in one line:
- trivial edit / quick question → Haiku, low
- research, summaries, simple scripts → Sonnet, low
- everyday development → Sonnet, medium
- architecture, tricky bugs, large refactors → Opus, medium (high only if medium failed)
