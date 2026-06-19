#!/usr/bin/env bash
#
# fusion-run.sh — Run ONE task across MULTIPLE coding agents, in parallel, each
# inside its own isolated git worktree, and capture every agent's transcript
# and diff for later synthesis.
#
# Inspired by OpenRouter's "fusion" idea: rather than trusting a single model,
# fan the same task out to several independent agents and merge the best of
# their outputs. Git worktrees guarantee the agents never step on each other —
# each gets a private checkout on its own throwaway branch.
#
# This script ONLY produces the candidate solutions. The merge/synthesis step
# is performed by the calling Claude session (see commands/fusion.md), which
# plays the role of the "aggregator" model in a fusion pipeline.
#
# ---------------------------------------------------------------------------
# Usage:
#   fusion-run.sh "the task prompt"
#   echo "the task prompt" | fusion-run.sh
#
# Configuration (all optional, via environment):
#   FUSION_AGENTS          Space-separated roster.   Default: "claude gemini"
#   FUSION_KIND_<KEY>      Agent kind: claude|gemini|codex|opencode|custom
#                          (default inferred from key name; unknown => custom).
#   FUSION_MODEL_<KEY>     Model passed to that agent (optional).
#   FUSION_EXTRA_<KEY>     Extra raw CLI flags appended to a known-kind agent.
#   FUSION_CMD_<KEY>       For kind=custom: a command line run via `bash -c`
#                          inside the worktree, with $FUSION_PROMPT and
#                          $FUSION_MODEL exported for it to use.
#   FUSION_CLAUDE_PERM     claude --permission-mode value.  Default:
#                          bypassPermissions (all tools incl. Bash, no prompts,
#                          since each agent is sandboxed to its worktree). Use
#                          acceptEdits for edits-only (Bash blocked in headless).
#   FUSION_GEMINI_APPROVAL gemini --approval-mode value.     Default: yolo
#   FUSION_GEMINI_TRUST    true => trust the worktree (GEMINI_CLI_TRUST_WORKSPACE)
#                          so Gemini's trusted-folder gate doesn't abort. Default: true
#   FUSION_GEMINI_ISOLATE_FLAGS  flags isolating Gemini from the user's MCP
#                          servers + extensions (invalid in a throwaway worktree).
#                          Default: "-e none --allowed-mcp-server-names none". Empty = inherit.
#   FUSION_CODEX_FLAGS     codex exec autonomy flags.        Default: --full-auto
#   FUSION_OPENCODE_FLAGS  opencode run autonomy flags. Default: --dangerously-skip-permissions
#   FUSION_TIMEOUT         Per-agent timeout in seconds.     Default: 0 (none)
#   FUSION_BASE_REF        Git ref the worktrees branch from. Default: HEAD
#   FUSION_WORKTREE_DIR    Override the worktree parent dir. Default places each
#                          worktree as a flat repo sibling:
#                          <repo-parent>/<repo-name>-fusion-<runid>-<agent>
#
# Where <KEY> is the agent name upper-cased with non-alphanumerics turned to
# "_" (e.g. agent "gpt-5" => FUSION_KIND_GPT_5).
# ---------------------------------------------------------------------------

set -uo pipefail

err()  { printf 'fusion: %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# --- locate the repo we are operating on ----------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "not inside a git repository — fusion needs git worktrees to isolate agents. Run 'git init' first."

# --- read the task prompt --------------------------------------------------
PROMPT="${1:-}"
if [ -z "$PROMPT" ] && [ ! -t 0 ]; then
  PROMPT="$(cat)"
fi
[ -n "$PROMPT" ] || die "no task prompt given (pass as arg or on stdin)."

# normalise an agent key into an env-var-safe suffix (bash 3.2 / macOS safe:
# avoids the bash-4 ${x^^} uppercase expansion).
keyvar() { printf '%s' "$1" | LC_ALL=C tr 'a-z' 'A-Z' | LC_ALL=C tr -c 'A-Z0-9' '_'; }

# resolve env override with a default: envget VAR_NAME default
envget() { local n="$1"; printf '%s' "${!n:-$2}"; }

# --- config ---------------------------------------------------------------
AGENTS="${FUSION_AGENTS:-claude gemini}"
BASE_AGENT="${FUSION_BASE_AGENT-claude}"
# How the baseline Claude candidate runs: "subagent" (in the main tree, no
# worktree — saves a folder; the orchestrating session spawns it) or "worktree"
# (headless `claude -p` in its own worktree, like every other agent). Only the
# BASELINE claude is affected; an explicit @claude:model is always a separate
# worktree candidate.
CLAUDE_MODE="${FUSION_CLAUDE_MODE:-subagent}"
BASE_REF="${FUSION_BASE_REF:-HEAD}"
TIMEOUT="${FUSION_TIMEOUT:-0}"
CLAUDE_PERM="${FUSION_CLAUDE_PERM:-bypassPermissions}"
GEMINI_APPROVAL="${FUSION_GEMINI_APPROVAL:-yolo}"
# Each worktree is a brand-new path Gemini has never seen, so it fails its
# trusted-folder gate (exit 55) and silently downgrades --approval-mode. The
# worktree IS the sandbox, so trust it. true => export GEMINI_CLI_TRUST_WORKSPACE.
GEMINI_TRUST="${FUSION_GEMINI_TRUST:-true}"
# Gemini otherwise inherits the user's global MCP servers + extensions, which
# aren't valid in a throwaway worktree (e.g. an uninitialised codegraph index)
# and can fatally error the headless turn. Default to isolating from both; set
# empty to inherit them.
# Note: `-` (not `:-`) so that setting it empty explicitly disables isolation.
GEMINI_ISOLATE_FLAGS="${FUSION_GEMINI_ISOLATE_FLAGS--e none --allowed-mcp-server-names none}"
CODEX_FLAGS="${FUSION_CODEX_FLAGS:---full-auto}"
OPENCODE_FLAGS="${FUSION_OPENCODE_FLAGS:---dangerously-skip-permissions}"
# Where each agent's worktree goes. By default it's a flat SIBLING of the repo at
# the same directory depth — <repo-parent>/<repo-name>-fusion-<runid>-<agent> —
# so relative paths in the repo's config (e.g. Gemini settings pointing at
# ../lib) resolve the same as they do from the repo itself. Override the parent
# with FUSION_WORKTREE_DIR (then worktrees are FUSION_WORKTREE_DIR/<runid>/<agent>,
# which does NOT preserve ../ depth — only use it if your repo has no such links).
REPO_PARENT="$(dirname "$REPO_ROOT")"
REPO_NAME="$(basename "$REPO_ROOT")"
# args: <runid> <agent>  ->  prints the worktree path
worktree_path() {
  if [ -n "${FUSION_WORKTREE_DIR:-}" ]; then
    printf '%s/%s/%s' "$FUSION_WORKTREE_DIR" "$1" "$2"
  else
    printf '%s/%s-fusion-%s-%s' "$REPO_PARENT" "$REPO_NAME" "$1" "$2"
  fi
}

# --- inline roster: leading @agent[:model] tokens on the prompt ------------
# e.g.  fusion-run.sh "@gemini:gemini-3.1-pro  refactor the parser"
# Inline agents are ADDED to a baseline agent (Claude by default), so:
#   @gemini:x <task>            -> fuse claude + gemini          (2 candidates)
#   @gemini @codex <task>       -> fuse claude + gemini + codex  (3 candidates)
#   @claude:opus @gemini <task> -> fuse claude(baseline) + claude:opus + gemini
#                                  (an explicit @claude:model is an EXTRA candidate
#                                   in its own worktree, NOT a duplicate baseline)
# The baseline is FUSION_BASE_AGENT (default "claude"); set it empty to run only
# the agents you list. Only @tokens naming a KNOWN/configured agent are consumed,
# so a task that legitimately begins with "@something" is left intact.
is_known_agent() {
  case "$1" in claude|gemini|codex|opencode) return 0 ;; esac
  local kv k c; kv="$(keyvar "$1")"; k="FUSION_KIND_$kv"; c="FUSION_CMD_$kv"
  [ -n "${!k:-}" ] && return 0
  [ -n "${!c:-}" ] && return 0
  case " $AGENTS " in *" $1 "*) return 0 ;; esac
  return 1
}
infer_kind() {
  case "$1" in claude) printf claude ;; gemini) printf gemini ;;
               codex) printf codex ;; opencode) printf opencode ;;
               *) printf custom ;; esac
}

inline_agents=""
while [[ "$PROMPT" =~ ^@([^[:space:]:]+)(:([^[:space:]]+))?[[:space:]]+(.*)$ ]]; do
  name="${BASH_REMATCH[1]}"; model="${BASH_REMATCH[3]}"; rest="${BASH_REMATCH[4]}"
  is_known_agent "$name" || break
  key="$name"
  # An explicit @baseline:model (e.g. @claude:opus when claude is the baseline)
  # is a distinct extra candidate — give it its own key so it gets its own
  # worktree and isn't conflated with the baseline subagent.
  if [ "$name" = "$BASE_AGENT" ] && [ -n "$model" ]; then
    key="$name-$(printf '%s' "$model" | LC_ALL=C tr -c 'A-Za-z0-9' '-')"
    export "FUSION_KIND_$(keyvar "$key")=$(infer_kind "$name")"
  fi
  # de-dupe keys within this run
  while [[ " $inline_agents " == *" $key "* ]]; do key="$key-x"; done
  inline_agents+="${inline_agents:+ }$key"
  [ -n "$model" ] && export "FUSION_MODEL_$(keyvar "$key")=$model"
  PROMPT="$rest"
done
if [ -n "$inline_agents" ]; then
  [ -n "$PROMPT" ] || die "agents specified but no task given."
  # Always fold in the baseline agent unless already listed or disabled (empty).
  if [ -n "$BASE_AGENT" ] && [[ " $inline_agents " != *" $BASE_AGENT "* ]]; then
    AGENTS="$BASE_AGENT $inline_agents"
  else
    AGENTS="$inline_agents"
  fi
fi

RUNID="$(date +%Y%m%d-%H%M%S)-$$"
RUNDIR="$REPO_ROOT/.fusion/runs/$RUNID"
mkdir -p "$RUNDIR"

# Keep fusion's bookkeeping out of the user's git status.
EXCLUDE_FILE="$REPO_ROOT/.git/info/exclude"
if [ -f "$EXCLUDE_FILE" ] && ! grep -qxF '.fusion/' "$EXCLUDE_FILE" 2>/dev/null; then
  printf '.fusion/\n' >> "$EXCLUDE_FILE"
fi

run_one() {
  local key="$1"
  local KV; KV="$(keyvar "$key")"
  local kind model extra
  kind="$(envget "FUSION_KIND_$KV" "")"
  model="$(envget "FUSION_MODEL_$KV" "")"
  extra="$(envget "FUSION_EXTRA_$KV" "")"

  if [ -z "$kind" ]; then
    case "$key" in
      claude)   kind=claude ;;
      gemini)   kind=gemini ;;
      codex)    kind=codex ;;
      opencode) kind=opencode ;;
      *)        kind=custom ;;
    esac
  fi

  local status_file="$RUNDIR/$key.status"

  # The baseline Claude runs as a subagent in the main tree (no worktree) — the
  # orchestrating session spawns it; the script just records the intent.
  if [ "$key" = "$BASE_AGENT" ] && [ "$kind" = "claude" ] && [ "$CLAUDE_MODE" = "subagent" ]; then
    printf 'mode=subagent model=%s\n' "$model" > "$status_file"
    err "[$key] subagent mode — runs in the main tree (no worktree)"
    return 0
  fi

  local wt; wt="$(worktree_path "$RUNID" "$key")"
  local branch="fusion/$RUNID/$key"
  local log="$RUNDIR/$key.log"

  mkdir -p "$(dirname "$wt")"
  if ! git -C "$REPO_ROOT" worktree add -b "$branch" "$wt" "$BASE_REF" >>"$log" 2>&1; then
    err "[$key] failed to create worktree"
    printf 'worktree-failed' > "$status_file"
    return 0
  fi

  # Build the invocation. The ${arr[@]+"${arr[@]}"} idiom expands to nothing for
  # an empty array without tripping `set -u` on bash < 4.4 (e.g. macOS 3.2).
  local -a cmd
  local extra_arr=(); [ -n "$extra" ] && read -r -a extra_arr <<< "$extra"

  case "$kind" in
    claude)
      cmd=(claude -p "$PROMPT" --permission-mode "$CLAUDE_PERM")
      [ -n "$model" ] && cmd+=(--model "$model")
      cmd+=(${extra_arr[@]+"${extra_arr[@]}"})
      ;;
    gemini)
      # Trust the worktree (it's the sandbox) so Gemini doesn't abort on its
      # trusted-folder gate. Exported here in run_one's own (backgrounded)
      # subshell, so it only affects this agent.
      [ "$GEMINI_TRUST" = "true" ] && export GEMINI_CLI_TRUST_WORKSPACE=true
      cmd=(gemini -p "$PROMPT" --approval-mode "$GEMINI_APPROVAL")
      [ -n "$model" ] && cmd+=(--model "$model")
      local gi_arr=(); [ -n "$GEMINI_ISOLATE_FLAGS" ] && read -r -a gi_arr <<< "$GEMINI_ISOLATE_FLAGS"
      cmd+=(${gi_arr[@]+"${gi_arr[@]}"})
      cmd+=(${extra_arr[@]+"${extra_arr[@]}"})
      ;;
    codex)
      # OpenAI Codex CLI headless: `codex exec <prompt>`. --full-auto = auto
      # approve + workspace-write sandbox (the documented CI/unattended mode).
      local codex_arr=(); read -r -a codex_arr <<< "$CODEX_FLAGS"
      cmd=(codex exec)
      cmd+=(${codex_arr[@]+"${codex_arr[@]}"})
      [ -n "$model" ] && cmd+=(--model "$model")
      cmd+=(${extra_arr[@]+"${extra_arr[@]}"} "$PROMPT")
      ;;
    opencode)
      # opencode headless: `opencode run <message>`. Model is provider/model.
      local oc_arr=(); read -r -a oc_arr <<< "$OPENCODE_FLAGS"
      cmd=(opencode run)
      cmd+=(${oc_arr[@]+"${oc_arr[@]}"})
      [ -n "$model" ] && cmd+=(--model "$model")
      cmd+=(${extra_arr[@]+"${extra_arr[@]}"} "$PROMPT")
      ;;
    custom)
      local tmpl; tmpl="$(envget "FUSION_CMD_$KV" "")"
      [ -n "$tmpl" ] || { err "[$key] kind=custom but FUSION_CMD_$KV is unset"; printf 'no-command' > "$status_file"; return 0; }
      cmd=(bash -c "$tmpl")
      ;;
    *)
      err "[$key] unknown kind '$kind'"; printf 'bad-kind' > "$status_file"; return 0
      ;;
  esac

  err "[$key] starting ($kind${model:+, model=$model}) in $wt"

  local rc
  (
    cd "$wt" || exit 97
    export FUSION_PROMPT="$PROMPT" FUSION_MODEL="$model"
    if [ "$TIMEOUT" != "0" ]; then
      timeout "$TIMEOUT" "${cmd[@]}"
    else
      "${cmd[@]}"
    fi
  ) >>"$log" 2>&1
  rc=$?

  # Capture everything the agent changed as an applyable diff.
  git -C "$wt" add -A >/dev/null 2>&1
  git -C "$wt" diff --cached --binary > "$RUNDIR/$key.diff" 2>/dev/null
  git -C "$wt" diff --cached --stat   > "$RUNDIR/$key.stat" 2>/dev/null
  local changed; changed="$(git -C "$wt" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')"

  printf 'exit=%s changed=%s wt=%s branch=%s\n' "$rc" "$changed" "$wt" "$branch" > "$status_file"
  err "[$key] done (exit=$rc, files changed=$changed)"
}

# --- fan out ---------------------------------------------------------------
err "run $RUNID — task: $PROMPT"
pids=()
for agent in $AGENTS; do
  run_one "$agent" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done

# Partition the roster into worktree agents and main-tree subagents.
worktree_agents=""; subagents=""
for agent in $AGENTS; do
  if grep -q '^mode=subagent' "$RUNDIR/$agent.status" 2>/dev/null; then
    subagents="${subagents:+$subagents }$agent"
  else
    worktree_agents="${worktree_agents:+$worktree_agents }$agent"
  fi
done

# --- machine-readable manifest for the synthesizer -------------------------
{
  printf 'FUSION_RUN_ID=%s\n' "$RUNID"
  printf 'FUSION_RUN_DIR=%s\n' "$RUNDIR"
  printf 'FUSION_REPO=%s\n' "$REPO_ROOT"
  printf 'FUSION_AGENTS=%s\n' "$AGENTS"
  printf 'FUSION_WORKTREE_AGENTS=%s\n' "$worktree_agents"
  printf 'FUSION_SUBAGENTS=%s\n' "$subagents"
  printf 'FUSION_CLAUDE_MODEL=%s\n' "$(envget "FUSION_MODEL_$(keyvar "$BASE_AGENT")" "")"
  printf 'FUSION_TASK=%s\n' "$PROMPT"
} > "$RUNDIR/manifest.env"

# --- human-readable summary to stdout --------------------------------------
echo "==================== FUSION RUN $RUNID ===================="
echo "repo:    $REPO_ROOT"
echo "task:    $PROMPT"
echo "outputs: $RUNDIR"
echo "----------------------------------------------------------"
for agent in $AGENTS; do
  status="$(cat "$RUNDIR/$agent.status" 2>/dev/null || echo 'NO STATUS')"
  echo "[$agent] $status"
  if [ -s "$RUNDIR/$agent.stat" ]; then
    sed 's/^/    /' "$RUNDIR/$agent.stat"
  fi
done
echo "----------------------------------------------------------"
if [ -n "$worktree_agents" ]; then
  echo "Worktree candidates (read these diffs to synthesize):"
  for agent in $worktree_agents; do
    echo "  $agent: transcript=$RUNDIR/$agent.log  diff=$RUNDIR/$agent.diff"
  done
fi
if [ -n "$subagents" ]; then
  echo "Main-tree candidates (the orchestrator runs these as subagents):"
  for agent in $subagents; do
    echo "  $agent: run as a subagent in the repo, then read its changes via 'git diff'"
  done
fi
echo "Cleanup when done:  fusion-cleanup.sh $RUNID"
echo "=========================================================="
