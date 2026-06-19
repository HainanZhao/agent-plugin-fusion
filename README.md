# fusion

A Claude Code plugin that brings the **fusion / mixture-of-agents** idea (à la
[OpenRouter's fusion API](https://openrouter.ai/)) to coding agents: fan the
*same* task out to several agents in **parallel**, then let your Claude session
**synthesize** the best combined result. The baseline Claude candidate runs as a
**subagent in your working tree**; every other agent runs headless in its own
**git worktree** so they never collide.

```mermaid
flowchart TD
    task([task]) --> run[fusion-run]
    task --> sub["Claude subagent<br/>(in the main tree)"]
    run -->|git worktree| wg["worktree: gemini<br/>gemini -p …"]
    run -->|git worktree| wx["worktree: … configurable<br/>codex / opencode / @claude:model"]
    sub --> agg{{Claude session<br/>= aggregator}}
    wg --> agg
    wx --> agg
    agg --> out[(merged result in<br/>your working tree)]

    classDef task fill:#fde68a,stroke:#d97706,stroke-width:2px,color:#111
    classDef run fill:#a7f3d0,stroke:#059669,stroke-width:2px,color:#111
    classDef claude fill:#ddd6fe,stroke:#7c3aed,stroke-width:2px,color:#111
    classDef gemini fill:#bfdbfe,stroke:#2563eb,stroke-width:2px,color:#111
    classDef other fill:#fbcfe8,stroke:#db2777,stroke-width:2px,color:#111
    classDef agg fill:#fed7aa,stroke:#ea580c,stroke-width:3px,color:#111
    classDef out fill:#bbf7d0,stroke:#16a34a,stroke-width:3px,color:#111

    class task task
    class run run
    class sub claude
    class wg gemini
    class wx other
    class agg agg
    class out out
```

## Install

Run these **one at a time** (not as a single paste). First add the marketplace:

```text
/plugin marketplace add https://github.com/HainanZhao/agent-plugin-fusion.git
```

then install the plugin:

```text
/plugin install fusion@fusion-marketplace
```

This gives you **`/fusion:run`** and **`/fusion:cleanup`** (plugin commands are
always `plugin:command`).

**Requires** a git repo plus the CLIs for the agents you use. Built-ins (each run
headless): `claude`, `gemini`, `codex`, `opencode`. Any other headless CLI works
as a `custom` agent.

## Usage

```text
/fusion:run add retry-with-backoff to the HTTP client and cover it with a test
```

Runs the baseline Claude as a subagent in your tree and the other agents in
worktrees (in parallel), then synthesizes the best combined change into your
working tree and cleans up.

### Picking the roster inline

Prefix the task with `@agent[:model]` tokens. **Claude is always folded in**, so
named agents are fused *with* Claude:

```text
/fusion:run @gemini:gemini-3.1-pro fix the race   # Claude + Gemini              (merge of 2)
/fusion:run @gemini @codex add a test             # Claude + Gemini + Codex      (merge of 3)
/fusion:run @claude:opus @gemini refactor auth    # Claude + Claude·opus + Gemini (merge of 3)
/fusion:run add retry logic                        # default: Claude + Gemini
```

An explicit `@claude:model` is an **extra** candidate (its own worktree, merged
too) — not a duplicate of the baseline. Only `@tokens` naming a known/configured
agent are consumed. Set `FUSION_BASE_AGENT=""` to drop the implicit Claude
baseline; set `FUSION_CLAUDE_MODE=worktree` to run the baseline Claude headless in
a worktree instead of as a subagent.

### Cleanup

Automatic: `/fusion:run` cleans its own run (set `FUSION_KEEP=1` to keep
candidates), and a SessionStart hook prunes stale runs. Manual:
`/fusion:cleanup <RUN_ID> | --all | --stale [HOURS]`.

## How isolation works

Agents branch from `HEAD` into `fusion/<runid>/<agent>` worktrees (so
**uncommitted changes aren't seen** — commit first if needed). Each worktree is a flat
**sibling** of the repo at the same depth —
`<repo-parent>/<repo-name>-fusion-<runid>-<agent>` (e.g. `myproj-fusion-…-claude`
next to `myproj`). Same depth matters: relative paths in your repo config (e.g.
Gemini settings pointing at `../lib`) resolve the same from a worktree as from
the repo. Override the parent dir with `FUSION_WORKTREE_DIR` (note: that nests
them and breaks `../` depth). Run artifacts live in `.fusion/runs/<runid>/`
(auto-excluded from git).

The **baseline Claude candidate is the exception**: it runs as a subagent
directly in your working tree (no worktree — that's the whole point of saving a
folder), so the tree *is* modified during the run, then the worktree agents'
diffs are reconciled into it. Commit/stash first if you want a clean baseline.
Set `FUSION_CLAUDE_MODE=worktree` to make Claude run headless in a worktree like
the others (tree stays pristine until merge, at the cost of one more folder).

## Configuration

All via environment variables (`<KEY>` = agent name upper-cased, non-alphanumerics
→ `_`).

| Variable | Default | Meaning |
|---|---|---|
| `FUSION_AGENTS` | `claude gemini` | Default roster (when no inline `@agent`). |
| `FUSION_BASE_AGENT` | `claude` | Agent always added to an inline roster. Empty = none. |
| `FUSION_CLAUDE_MODE` | `subagent` | Baseline Claude as a `subagent` in the main tree (no worktree) or `worktree` (headless, own worktree). |
| `FUSION_KIND_<KEY>` | inferred | `claude`\|`gemini`\|`codex`\|`opencode`\|`custom`. |
| `FUSION_MODEL_<KEY>` | — | Model for that agent (e.g. `opus`, `o4-mini`). |
| `FUSION_EXTRA_<KEY>` | — | Extra CLI flags for a known-kind agent. |
| `FUSION_CMD_<KEY>` | — | `custom` agent command (`bash -c`, with `$FUSION_PROMPT`/`$FUSION_MODEL`). |
| `FUSION_CLAUDE_PERM` | `bypassPermissions` | `claude --permission-mode` (full tools; `acceptEdits` blocks Bash headless). |
| `FUSION_GEMINI_APPROVAL` | `yolo` | `gemini --approval-mode`. |
| `FUSION_GEMINI_TRUST` | `true` | Trust the worktree (`GEMINI_CLI_TRUST_WORKSPACE`) so Gemini's trusted-folder gate doesn't abort (exit 55). |
| `FUSION_GEMINI_ISOLATE_FLAGS` | `-e none --allowed-mcp-server-names none` | Isolate Gemini from your global MCP servers/extensions (invalid in a throwaway worktree). Empty = inherit them. |
| `FUSION_CODEX_FLAGS` | `--full-auto` | `codex exec` autonomy flags. |
| `FUSION_OPENCODE_FLAGS` | `--dangerously-skip-permissions` | `opencode run` autonomy flags. |
| `FUSION_TIMEOUT` | `0` | Per-agent timeout (s); `0` = none. |
| `FUSION_BASE_REF` | `HEAD` | Ref the worktrees branch from. |
| `FUSION_WORKTREE_DIR` | — | Override worktree parent. Default: flat sibling `<repo-parent>/<repo-name>-fusion-<runid>-<agent>` (preserves `../` depth). |

```bash
# four agents; two Claudes at different models + Gemini; or a custom CLI
export FUSION_AGENTS="claude gemini codex opencode"
export FUSION_AGENTS="opus sonnet gemini" FUSION_KIND_OPUS=claude FUSION_MODEL_OPUS=opus
export FUSION_KIND_MYCLI=custom FUSION_CMD_MYCLI='mycli run --task "$FUSION_PROMPT"'
```

## Notes

- Each agent is a full headless session — fusion is slower and more
  token/credit-hungry than one run; that's the trade for quality.
- Agents auto-approve tools but are sandboxed to their worktree. Review the
  synthesized diff before committing.
- The merge is Claude's judgment, not a mechanical `git merge`, so it can combine
  ideas that would otherwise conflict.
