---
description: Run a coding task across Claude + Gemini (configurable) in isolated git worktrees, then synthesize the best combined result.
argument-hint: <the task to fuse, e.g. "add retry logic to the http client">
---

# Fusion

You are the **aggregator** in a fusion pipeline (think OpenRouter's fusion API,
but for coding agents). The idea: independent agents each attempt the same task
in isolation, then you merge the best of their work into a single superior
result. Each agent runs in its own **git worktree** so they never overwrite one
another.

Task to fuse: **$ARGUMENTS**

If `$ARGUMENTS` is empty, ask the user what task to fuse, then stop.

## Phase 1 — Preflight

1. Confirm the working directory is a git repository (`git rev-parse --show-toplevel`).
   - If not, tell the user fusion needs git for worktree isolation and offer to run `git init`. Stop until resolved.
2. Check the tree is reasonably clean (`git status --short`). Uncommitted changes
   are fine — the agents branch from `HEAD`, so **uncommitted work in the main
   tree is NOT seen by the agents**. If there are uncommitted changes that matter
   to the task, suggest the user commit (or stash-then-commit) first so the
   agents start from the right baseline. Let them decide.

## Phase 2 — Fan out

Run the orchestrator. It creates one worktree per agent, runs them **in
parallel**, and captures each agent's transcript + diff:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/fusion-run.sh" "$ARGUMENTS"
```

This can take a while (each agent is a full headless coding session). Default
roster is `claude gemini`; respect any `FUSION_*` env the user has set (see the
plugin README). The command prints a summary block ending in
`==== FUSION RUN <id> ====` with the run directory and per-agent artifact paths.

## Phase 3 — Study both candidates

From the printed run directory, for **each** agent:
- Read `<agent>.diff` — the actual changes it produced.
- Read `<agent>.log` (at least the tail) — its reasoning, and any errors.
- Note its `.status` (exit code + files changed). An agent may have failed,
  produced nothing, or gone off-task — judge accordingly.

Build a clear mental model of **how the two approaches differ**: structure,
correctness, edge cases, naming, tests, scope creep.

## Phase 4 — Synthesize (the actual fusion)

Do **not** simply pick a winner or blindly `git apply` one diff. Produce the
best *combined* solution, applying it directly to the main working tree:

- Take the stronger overall structure as the base.
- Graft in superior pieces from the other (a cleaner helper, a missed edge case,
  a better test, clearer naming).
- Drop anything wrong, hallucinated, or out of scope.
- If one agent failed or its output is unusable, fall back to the other and say so.
- Reconcile conflicts using your own judgment and the surrounding code's
  conventions — you have full repo context the sub-agents did not share.

Apply the merged result with your normal Edit/Write tools in the main repo. Run
the project's tests/build if available to validate the fused result.

## Phase 5 — Report & clean up

Give the user a concise comparison:
- One line per agent: what it did, strengths, weaknesses, exit status.
- What you took from each and why (the fusion decisions).
- The final state of the working tree (files changed, test results).

Then offer cleanup of the scratch worktrees/branches:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/fusion-cleanup.sh" <RUN_ID>
```

Don't run cleanup until the user is satisfied — the worktrees and diffs are
useful if they want to inspect a raw candidate.
