# Codex Tool Tracking Design

## Goal

Extend toolytics so one dashboard aggregates Claude Code and local Codex tool
calls, while retaining the existing cumulative-history guarantees.

## Scope

- Scan `~/.codex/sessions/**/*.jsonl` in addition to Claude transcripts.
- Add a runtime dimension: `claude` or `codex`.
- Add an All / Claude / Codex dashboard filter.
- Preserve existing Claude history by migrating its five-column CSV rows to
  `runtime=claude` on the next build.
- Classify Codex session files as `agent` when a `session_meta` record contains
  `thread_source: "subagent"` or `source.subagent`; otherwise classify them as
  `main`.

## Data Model

`history.csv` becomes:

```
date,runtime,triggered_by,project,tool,count
```

The replace-by-covered-group key becomes
`(date, runtime, triggered_by, project)`. Claude and Codex scans are therefore
independently authoritative and cannot erase each other's rows. An existing
five-column row is read as a Claude row before the six-column file is written.

## Collection

For each Codex JSONL file, scan its `session_meta` and `turn_context` records
to derive the project label from `cwd` and its direct/delegated attribution.
Then count each `response_item` whose payload is a `function_call` or
`custom_tool_call`, using `payload.name` as the tool name. Call IDs are unique
in the observed local session corpus, so no extra persistence or deduplication
table is required.

Codex currently records no per-call token-usage structure equivalent to
Claude's `message.usage`; `tokens.csv`, price aggregation, injection metrics,
and the skill inventory remain Claude-only for this change.

## Dashboard

The inlined tool rows use the new six-field shape. A `Runtime` control filters
the same client-side aggregation used by the existing date, project, trigger,
and search controls. The copy identifies both transcript roots and defines
Direct/Delegated consistently for both products.

## Verification

Extend `./build.sh --selfcheck` with fixtures that prove:

1. Codex main and subagent session metadata classify as `main` and `agent`.
2. Both Codex call payload types produce a named tool call.
3. Migrating a legacy Claude history row retains it as `runtime=claude`.
4. Replace-by-covered-group retains a same-date row from the other runtime.

Run the self-check, a no-browser build into a temporary `TOOLYTICS_HOME`, and
inspect the generated dashboard data for Codex rows and both trigger values.
