---
description: Run a coding task across Claude + other agents (Gemini/Codex/…) in parallel, then synthesize the best combined result.
argument-hint: '[@agent[:model] …] <task>  e.g. @gemini:gemini-3.1-pro add retry logic'
---

# Fusion

You are the **aggregator** in a fusion pipeline (think OpenRouter's fusion API,
but for coding agents). Independent agents each attempt the *same* task, then you
merge the best of their work into one superior result.

Candidates come from two places:
- **The baseline Claude candidate** runs as a **subagent in the main working
  tree** (no worktree — this is what saves a folder).
- **Every other agent** (Gemini, Codex, opencode, and any extra `@claude:model`)
  runs headless in its **own git worktree** so they never collide.

Task to fuse (may begin with an inline roster): **$ARGUMENTS**

If `$ARGUMENTS` is empty, ask the user what task to fuse, then stop.

**Inline roster (optional).** The task may start with `@agent[:model]` tokens,
which are *added to* the baseline Claude:

- `@gemini:gemini-3.1-pro fix the race` → **Claude + Gemini** (2 candidates).
- `@gemini @codex add a test` → **Claude + Gemini + Codex** (3 candidates).
- `@claude:opus @gemini …` → **Claude (baseline) + Claude·opus + Gemini** — an
  explicit `@claude:model` is an *extra* candidate in its own worktree, **not** a
  duplicate of the baseline.

You do **not** parse `@tokens` for the worktree agents — pass `$ARGUMENTS`
verbatim to the script, which resolves the roster.

## Phase 1 — Preflight

1. Confirm a git repo (`git rev-parse --show-toplevel`); if not, offer `git init` and stop.
2. **Important — this mode edits your working tree.** The baseline Claude
   subagent works directly in the main tree, so the tree changes during the run.
   Run `git status --short`; if there are uncommitted changes, recommend the user
   commit or stash first so its work (and the final merge) is cleanly separable
   and recoverable. Let them decide. (Worktree agents branch from `HEAD`, so they
   don't see uncommitted work either way.)

## Phase 2 — Fan out (in parallel)

Determine whether the baseline Claude runs as a subagent: **yes by default**,
**unless** the user set `FUSION_CLAUDE_MODE=worktree` or `FUSION_BASE_AGENT=""`.

In a **single turn**, launch both of these so they run concurrently:

1. **Worktree agents** — run the orchestrator (it creates a worktree per agent,
   skipping the baseline Claude when in subagent mode):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/fusion-run.sh" "$ARGUMENTS"
   ```

2. **Baseline Claude candidate** (only if subagent mode is active) — launch the
   `fusion-candidate` subagent via the Task tool, working in the **current
   directory** (the main tree). Its prompt is the task with any leading
   `@agent[:model]` tokens stripped off. If the user set `FUSION_MODEL_CLAUDE`,
   pass it as the subagent's model. If the `fusion-candidate` agent type isn't
   available, use a general-purpose subagent and paste the candidate rules
   (implement fully in-place, match conventions, stay in scope, don't commit).

Each agent is a full coding session, so this takes a while. The script prints a
summary ending in `==== FUSION RUN <id> ====`; note the run directory.

## Phase 3 — Gather the candidates

Read `<run-dir>/manifest.env`. It lists `FUSION_WORKTREE_AGENTS`,
`FUSION_SUBAGENTS`, and `FUSION_TASK`.

- **Worktree candidates** (`FUSION_WORKTREE_AGENTS`): for each, read
  `<agent>.diff` (its changes), the tail of `<agent>.log` (reasoning/errors), and
  `<agent>.status` (exit code, files changed). An agent may have failed or gone
  off-task — judge accordingly.
- **Main-tree candidate** (`FUSION_SUBAGENTS`, normally `claude`): its work is
  already in the working tree. Read it with `git diff HEAD` plus any new untracked
  files. Use the subagent's final summary too.

Build a clear picture of how the approaches differ: structure, correctness, edge
cases, tests, naming, scope.

## Phase 4 — Synthesize (the actual fusion)

Produce the best *combined* result in the main working tree. Do **not** just pick
a winner or blindly `git apply` a diff.

- The baseline Claude candidate's work is already in the tree — treat it as your
  starting point when it's the strongest, and graft in superior pieces from the
  worktree agents (a cleaner helper, a missed edge case, a better test).
- If a worktree agent's approach is clearly better, replace accordingly — apply
  its diff or re-implement, then layer in the best of the rest.
- Drop anything wrong, hallucinated, or out of scope. Reconcile conflicts with
  your own judgment and the repo's conventions (you have full context the
  candidates lacked).
- Run the project's tests/build if available to validate the fused result.

## Phase 5 — Report & clean up

Give a concise comparison: one line per candidate (what it did, strengths,
weaknesses, status), what you took from each and why, and the final tree state
(files changed, test results).

Then **clean up automatically** (worktrees are no longer needed — the merge is in
the main tree):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/fusion-cleanup.sh" <RUN_ID>
```

Skip cleanup, saying so, if: the user set `FUSION_KEEP=1`/`true` (tell them where
the raw candidates live), or synthesis failed / you're unsure the merge is right.
(A SessionStart hook also auto-prunes stale runs, so nothing accumulates.)
