#!/usr/bin/env bash
set -euo pipefail

VERSION="0.5.0"
BIN_DIR="${MODEL_PEER_BIN_DIR:-$HOME/.local/bin}"
DO_SETUP=0
INSTALL_DEPS=0
DO_LOGIN=0

usage() {
  cat <<'USAGE'
Model Peer installer v0.5.0

Usage:
  ./install.sh [options]

Options:
  --setup           Interactively offer missing CLI installation and vendor login
  --install-deps    Install missing supported CLIs when a supported installer exists
  --login           Launch vendor-owned login/setup flows
  --bin-dir DIR     Install into DIR instead of ~/.local/bin
  -h, --help        Show help
  -V, --version     Show installer version

The installer never asks for, reads, or stores API keys or passwords itself.
USAGE
}

while (( $# > 0 )); do
  case "$1" in
    --setup) DO_SETUP=1 ;;
    --install-deps) INSTALL_DEPS=1 ;;
    --login) DO_LOGIN=1 ;;
    --bin-dir)
      shift
      [[ $# -gt 0 ]] || { echo 'model-peer: --bin-dir requires a value' >&2; exit 2; }
      BIN_DIR="$1"
      ;;
    -h|--help) usage; exit 0 ;;
    -V|--version) printf 'model-peer installer %s
' "$VERSION"; exit 0 ;;
    *) echo "model-peer: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

has_tty() { [[ -r /dev/tty && -w /dev/tty ]]; }
ask_yes_no() {
  local q="$1" default="${2:-n}" suffix='[y/N]' answer=''
  [[ "$default" == y ]] && suffix='[Y/n]'
  has_tty || return 1
  printf '%s %s ' "$q" "$suffix" > /dev/tty
  IFS= read -r answer < /dev/tty || true
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

ensure_path() {
  mkdir -p "$BIN_DIR"
  case ":$PATH:" in *":$BIN_DIR:"*) return ;; esac
  local rc=''
  case "${SHELL:-}" in */zsh) rc="$HOME/.zshrc" ;; */bash) rc="$HOME/.bashrc" ;; esac
  if [[ "$BIN_DIR" == "$HOME/.local/bin" && -n "$rc" ]]; then
    touch "$rc"
    if ! grep -Fq '# >>> model-peer PATH >>>' "$rc"; then
      cat >> "$rc" <<'PATHBLOCK'

# >>> model-peer PATH >>>
export PATH="$HOME/.local/bin:$PATH"
# <<< model-peer PATH <<<
PATHBLOCK
      printf 'Added ~/.local/bin to PATH in %s
' "$rc"
    fi
  else
    printf 'NOTE: ensure %s is on PATH.
' "$BIN_DIR" >&2
  fi
}

write_commands() {
  cat > "$BIN_DIR/model-peer" <<'__MODEL_PEER__'
#!/usr/bin/env bash
set -euo pipefail

VERSION="0.5.0"
PROGRAM="model-peer"

usage() {
  cat <<'USAGE'
Model Peer v0.5.0 — cross-model peer review for coding agents.

Usage:
  model-peer ask claude "<focused question>"
  model-peer ask codex "<focused question>"
  model-peer ask gemini "<focused question>"
  command | model-peer ask <claude|codex|gemini>

  model-peer review [options] ["focus instructions"]

  model-peer init [options]            Install the cross-model review skill
  model-peer update [--check]          Refresh installed files to this version
  model-peer doctor
  model-peer --version

Ask options:
  --depth N              Max peer-chain length, 1-10 (default: 1)
  --timeout S            Give up on the peer after S seconds (default: 600,
                         0 disables). Exits 124 on timeout.

Review options:
  --models LIST          Comma-separated reviewers (default: all installed)
  --synthesizer MODEL    claude, codex, or gemini (default: first available in
                         claude,codex,gemini order)
  --depth N              Max peer-chain length for each reviewer, 1-10 (default: 1)
  --timeout S            Per-reviewer timeout in seconds (default: 600, 0 off).
                         A reviewer that times out, fails, or returns nothing is
                         dropped and named; synthesis needs two survivors.
  --strict               Refuse to synthesize unless every reviewer completed

Init options:
  --agents LIST          Comma-separated: claude, codex, gemini (default: all)
  --no-command           Skip the Claude Code /peer-review slash command
  --print[=AGENT]        Print the SKILL.md to stdout; write nothing
  --dry-run              Report what would change; write nothing

  init writes only self-contained files Model Peer owns, under each vendor's
  skills directory. Your AGENTS.md, CLAUDE.md, and GEMINI.md are never touched.

Peer-chain depth:
  Depth is a limit, never a permission. Depth 1 (default) means a peer answers on
  its own. Depth N lets a chain grow to N models: claude -> codex -> gemini is 3.
  A model can never be consulted by itself, at any depth.

  Nested consultation additionally requires limited outbound execution, which
  Model Peer scopes as narrowly as each provider allows. Where a provider cannot
  scope it to Model Peer alone, that peer stays a leaf rather than being granted
  a general shell. Run 'model-peer doctor' for the per-provider matrix.

Environment:
  MODEL_PEER_REVIEWERS        Default comma-separated review model list
  MODEL_PEER_SYNTHESIZER      Default synthesis model
  MODEL_PEER_MAX_DEPTH        Default peer-chain depth limit, 1-10 (1)
  MODEL_PEER_TIMEOUT          Default per-consultation timeout in seconds (600)
  MODEL_PEER_MAX_DIFF_BYTES   Max patch bytes embedded in review prompt (500000)
  MODEL_PEER_STACK            Managed by Model Peer; the active peer chain

Compatibility commands installed with Model Peer:
  ask-claude, ask-codex, ask-gemini, ai-review
USAGE
}

err() { printf '%s: %s\n' "$PROGRAM" "$*" >&2; }
note() { printf '%s: %s\n' "$PROGRAM" "$*" >&2; }

provider_label() {
  case "$1" in
    claude) printf 'Claude' ;;
    codex) printf 'Codex' ;;
    gemini) printf 'Gemini' ;;
    *) printf '%s' "$1" ;;
  esac
}

provider_installed() {
  command -v "$1" >/dev/null 2>&1
}

DEFAULT_MAX_DEPTH=1
DEPTH_CEILING=10

# MODEL_PEER_STACK is the chain of models already active, e.g. "claude:codex".
# Its length is the current depth; the depth limit caps how long it may grow.
stack_depth() {
  local stack="${MODEL_PEER_STACK:-}"
  [[ -n "$stack" ]] || { printf '0'; return; }
  local IFS=:
  local parts
  read -r -a parts <<< "$stack"
  printf '%s' "${#parts[@]}"
}

stack_last() {
  local stack="${MODEL_PEER_STACK:-}"
  printf '%s' "${stack##*:}"
}

push_stack() {
  local provider="$1"
  local stack="${MODEL_PEER_STACK:-}"
  printf '%s' "${stack:+$stack:}$provider"
}

# Resolve the depth limit from --depth, then MODEL_PEER_MAX_DEPTH, then the default.
resolve_max_depth() {
  local requested="$1"
  local depth="${requested:-${MODEL_PEER_MAX_DEPTH:-$DEFAULT_MAX_DEPTH}}"
  [[ "$depth" =~ ^[0-9]+$ ]] || {
    err "depth must be an integer between 1 and $DEPTH_CEILING (got '$depth')."
    return 2
  }
  (( depth >= 1 && depth <= DEPTH_CEILING )) || {
    err "depth must be between 1 and $DEPTH_CEILING (got $depth)."
    return 2
  }
  printf '%s' "$depth"
}

# Depth and delegation are deliberately separate concepts:
#
#   depth       maximum recursion depth — a limit, never a permission
#   delegation  permission to initiate a further consultation, and the mechanism
#
# Depth alone never widens what a peer can do to the host system. Delegation is
# granted only where a provider's sandbox can constrain it to Model Peer itself.
#
#   claude   namespaced  Bash auto-approved only for Bash(model-peer:*)
#   codex    sandboxed   read-only sandbox already permits this; nothing is added
#   gemini   unsupported policy can only allow/deny run_shell_command wholesale,
#                        so delegating would unlock the hallway to open one door
provider_delegation_support() {
  case "$1" in
    claude) printf 'namespaced' ;;
    codex)  printf 'sandboxed' ;;
    gemini) printf 'unsupported' ;;
    *)      printf 'unsupported' ;;
  esac
}

# Resolve the delegation permission for a peer about to be spawned. Depth budget
# is necessary but not sufficient: the provider must also be able to hold the
# permission narrowly.
resolve_delegation() {
  local provider="$1" remaining="$2"
  if (( remaining <= 0 )); then
    printf 'none'
    return
  fi
  case "$(provider_delegation_support "$provider")" in
    namespaced) printf 'namespaced' ;;
    sandboxed)  printf 'sandboxed' ;;
    *)          printf 'none' ;;
  esac
}

# Two independent guards: the chain may not exceed the depth limit, and a model
# may never be consulted by itself. The second holds at every depth.
check_chain() {
  local provider="$1" max_depth="$2"
  local depth
  depth="$(stack_depth)"

  if [[ "$(stack_last)" == "$provider" ]]; then
    err "blocked: $(provider_label "$provider") cannot consult itself (chain=${MODEL_PEER_STACK:-empty})."
    return 64
  fi
  if (( depth >= max_depth )); then
    err "blocked: peer chain depth limit reached (depth=$depth, limit=$max_depth, chain=${MODEL_PEER_STACK:-empty})."
    err "Raise it with --depth N (max $DEPTH_CEILING) or MODEL_PEER_MAX_DEPTH."
    return 64
  fi
  return 0
}

DEFAULT_TIMEOUT=600
TIMEOUT_EXIT=124
HEARTBEAT_SECONDS=30

# Resolve the per-consultation timeout from --timeout, then MODEL_PEER_TIMEOUT,
# then the default. 0 disables it.
resolve_timeout() {
  local requested="$1"
  local secs="${requested:-${MODEL_PEER_TIMEOUT:-$DEFAULT_TIMEOUT}}"
  [[ "$secs" =~ ^[0-9]+$ ]] || {
    err "timeout must be a non-negative integer number of seconds (got '$secs')."
    return 2
  }
  printf '%s' "$secs"
}

# Run a command under a wall-clock limit, reporting progress on stderr so a
# multi-minute consultation is not indistinguishable from a hung one.
#
# macOS ships no coreutils `timeout`, so this polls instead. The child is asked to
# stop with TERM and killed with KILL if it ignores that. Returns 124 on timeout,
# matching the convention `timeout(1)` uses.
run_with_limit() {
  local label="$1" secs="$2"
  shift 2

  if (( secs <= 0 )); then
    "$@"
    return
  fi

  # Job control puts the child in its own process group, so the whole tree can be
  # signalled by negating the pid. Signalling only the direct child is not enough:
  # a vendor CLI that spawns helpers leaves them holding the inherited stdout, and
  # the pipeline downstream never sees EOF — the hang survives the kill.
  set -m
  "$@" &
  local pid=$!
  set +m

  local waited=0 status=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= secs )); then
      err "$label exceeded the ${secs}s timeout; stopping it."
      kill_tree "$pid"
      return "$TIMEOUT_EXIT"
    fi
    sleep 1
    waited=$(( waited + 1 ))
    if (( waited % HEARTBEAT_SECONDS == 0 )); then
      note "$label still working (${waited}s of ${secs}s)."
    fi
  done

  if wait "$pid" 2>/dev/null; then
    status=0
  else
    status=$?
  fi
  return "$status"
}

# TERM the process group, give it a few seconds, then KILL. Reaping happens with
# stderr redirected because the shell announces a signalled job on its own.
kill_tree() {
  local pid="$1" grace=0
  {
    kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    while (( grace < 5 )) && kill -0 "$pid" 2>/dev/null; do
      sleep 1
      grace=$(( grace + 1 ))
    done
    kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" || true
  } 2>/dev/null
}

read_prompt() {
  if (( $# > 0 )); then
    printf '%s' "$*"
  elif [[ ! -t 0 ]]; then
    cat
  else
    return 2
  fi
}

require_nonempty_prompt() {
  local prompt="$1"
  [[ -n "${prompt//[[:space:]]/}" ]] || {
    err 'prompt is empty.'
    return 2
  }
}

consultation_prompt() {
  local provider="$1"
  local prompt="$2"
  local remaining="$3"
  local delegation="$4"
  local delegation_rule

  if [[ "$delegation" == 'none' ]]; then
    delegation_rule="Do not invoke Claude Code, Codex CLI, Gemini CLI, Model Peer, or any other model.
Do not delegate the decision back to another agent."
    remaining=0
  else
    delegation_rule="You may consult one further peer with \`model-peer ask <model> \"<question>\"\` if a
genuinely independent perspective would change your answer. $remaining more level(s) are
permitted. Consult nothing else: that command is the only execution you are authorized
to perform. Prefer answering directly, since every hop costs time and dilutes
accountability. If you do consult a peer, say which model you asked and what you took
from it."
  fi

  cat <<PROMPT
You are being consulted as an independent engineering peer through Model Peer.
Answer the user's focused question. Inspect the current workspace read-only when useful.
Do not modify files.

$delegation_rule

Your advice is advisory. Project-specific rules and invariants take precedence.
Reason independently, distinguish evidence from assumptions, and call out uncertainty.

Consulted model: $provider
Remaining peer-chain depth: $remaining

User question:
$prompt
PROMPT
}

run_claude() {
  local prompt="$1" stack="$2" remaining="$3" max_depth="$4" delegation="$5"
  provider_installed claude || {
    err "'claude' was not found on PATH."
    err 'Install Claude Code: https://code.claude.com/docs/en/setup'
    return 127
  }

  local bridge_prompt tools
  bridge_prompt="$(consultation_prompt Claude "$prompt" "$remaining" "$delegation")"

  # Read-only inspection only. Delegation adds Bash, auto-approved for the single
  # model-peer command namespace and nothing else. This is the narrowest grant
  # the provider can express, not a general shell.
  tools='Read,Glob,Grep'
  local -a nested_args=()
  if [[ "$delegation" == 'namespaced' ]]; then
    tools='Read,Glob,Grep,Bash'
    nested_args=(--allowedTools 'Bash(model-peer:*)')
  fi

  MODEL_PEER_STACK="$stack" MODEL_PEER_MAX_DEPTH="$max_depth" \
    claude -p \
      --permission-mode plan \
      --tools "$tools" \
      ${nested_args[@]+"${nested_args[@]}"} \
      --disable-slash-commands \
      --no-session-persistence \
      "$bridge_prompt" \
      </dev/null
}

run_codex() {
  local prompt="$1" stack="$2" remaining="$3" max_depth="$4" delegation="$5"
  provider_installed codex || {
    err "'codex' was not found on PATH."
    err 'Install Codex CLI: https://developers.openai.com/codex/cli'
    return 127
  }

  # Codex flags are identical either way: --sandbox read-only already permits
  # read-only command execution, so delegation grants no new capability here and
  # changes only what the prompt authorizes.
  local bridge_prompt
  bridge_prompt="$(consultation_prompt Codex "$prompt" "$remaining" "$delegation")"

  MODEL_PEER_STACK="$stack" MODEL_PEER_MAX_DEPTH="$max_depth" \
    codex exec \
      --sandbox read-only \
      --ephemeral \
      --skip-git-repo-check \
      "$bridge_prompt" \
      </dev/null
}

# Cached: --help costs a process spawn but no model call, and the answer cannot
# change within one run.
GEMINI_SKIP_TRUST_SUPPORT=''
gemini_supports_skip_trust() {
  if [[ -z "$GEMINI_SKIP_TRUST_SUPPORT" ]]; then
    if gemini --help 2>/dev/null | grep -Fq -- '--skip-trust'; then
      GEMINI_SKIP_TRUST_SUPPORT=yes
    else
      GEMINI_SKIP_TRUST_SUPPORT=no
    fi
  fi
  [[ "$GEMINI_SKIP_TRUST_SUPPORT" == yes ]]
}

run_gemini() {
  local prompt="$1" stack="$2" remaining="$3" max_depth="$4" delegation="$5"
  provider_installed gemini || {
    err "'gemini' was not found on PATH."
    err 'Install Gemini CLI: https://google-gemini.github.io/gemini-cli/docs/get-started/'
    return 127
  }

  # Gemini is always a leaf: resolve_delegation never returns anything but 'none'
  # for it, so the deny policy below is unconditional.
  local bridge_prompt tmpdir policy status
  bridge_prompt="$(consultation_prompt Gemini "$prompt" "$remaining" "$delegation")"
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/model-peer-gemini.XXXXXX")"
  policy="$tmpdir/read-only.toml"

  # Plan mode is read-only upstream. These explicit deny rules are a second line
  # of defense, including blocking the tool that can exit Plan mode.
  cat > "$policy" <<'POLICY'
[[rule]]
toolName = "write_file"
decision = "deny"
priority = 999

[[rule]]
toolName = "replace"
decision = "deny"
priority = 999

[[rule]]
toolName = "run_shell_command"
decision = "deny"
priority = 999

[[rule]]
toolName = "exit_plan_mode"
decision = "deny"
priority = 999

[[rule]]
toolName = "enter_plan_mode"
decision = "deny"
priority = 999
POLICY

  # Gemini refuses to act in a directory its folder-trust gate has not blessed,
  # and headlessly that is a silent no-op: it exits 0 having produced nothing,
  # which a review panel would otherwise treat as "this reviewer found nothing".
  # --skip-trust trusts the workspace for this one session. It is safe here
  # precisely because the deny policy above is passed explicitly and extensions
  # are off, so the tighter grant does not depend on the trust gate. Older Gemini
  # builds lack the flag, so only pass it when this one advertises it.
  local -a trust_args=()
  if gemini_supports_skip_trust; then
    trust_args=(--skip-trust)
  fi

  if MODEL_PEER_STACK="$stack" MODEL_PEER_MAX_DEPTH="$max_depth" \
      gemini \
        --approval-mode plan \
        --policy "$policy" \
        -e none \
        ${trust_args[@]+"${trust_args[@]}"} \
        -p "$bridge_prompt" \
        </dev/null; then
    status=0
  else
    status=$?
  fi

  rm -rf "$tmpdir"
  return "$status"
}

# run_provider owns the chain: it validates the guards, pushes the provider, and
# computes how much depth is left for the peer it is about to spawn.
run_provider() {
  local provider="$1" max_depth="$2" prompt="$3" timeout="${4:-0}"
  require_nonempty_prompt "$prompt" || return

  case "$provider" in
    claude|codex|gemini) ;;
    *) err "unknown model '$provider'. Use claude, codex, or gemini."; return 2 ;;
  esac

  check_chain "$provider" "$max_depth" || return 64

  local stack remaining delegation label
  stack="$(push_stack "$provider")"
  remaining=$(( max_depth - $(stack_depth) - 1 ))
  delegation="$(resolve_delegation "$provider" "$remaining")"
  label="$(provider_label "$provider")"

  # A depth budget the provider cannot safely hold is reported, never silently
  # converted into a wider sandbox.
  if (( remaining > 0 )) && [[ "$delegation" == 'none' ]]; then
    note "$label cannot initiate nested consultation; answering as a leaf."
    note "Reason: its policy engine cannot scope execution to model-peer alone. See README."
  fi

  local status=0
  if run_with_limit "$label" "$timeout" \
      "run_$provider" "$prompt" "$stack" "$remaining" "$max_depth" "$delegation"; then
    status=0
  else
    status=$?
  fi

  if (( status == TIMEOUT_EXIT )); then
    err "$label produced no answer within ${timeout}s."
    err 'Raise or disable the limit with --timeout N (0 disables it).'
  fi
  return "$status"
}

cmd_ask() {
  local provider='' depth_arg='' timeout_arg=''
  local -a rest=()

  while (( $# > 0 )); do
    case "$1" in
      --depth)
        shift; (( $# > 0 )) || { err '--depth requires a value.'; return 2; }
        depth_arg="$1"
        ;;
      --depth=*) depth_arg="${1#--depth=}" ;;
      --timeout)
        shift; (( $# > 0 )) || { err '--timeout requires a value.'; return 2; }
        timeout_arg="$1"
        ;;
      --timeout=*) timeout_arg="${1#--timeout=}" ;;
      -h|--help)
        cat <<'USAGE'
Usage:
  model-peer ask <claude|codex|gemini> [--depth N] [--timeout S] "<question>"
  command | model-peer ask <claude|codex|gemini> [--depth N] [--timeout S]

  --depth N     Max peer-chain length, 1-10 (default: 1). Depth 1 means the peer
                answers alone. Above 1, the peer may consult a further model where
                its provider can scope that execution to model-peer alone; peers
                whose sandbox cannot express that stay leaves. Use -- to end
                options when the prompt itself starts with a dash.
  --timeout S   Give up on the peer after S seconds (default: 600, 0 disables).
                Progress is reported on stderr every 30s so a slow consultation
                is distinguishable from a hung one. Exits 124 on timeout.
USAGE
        return 0
        ;;
      --) shift; if (( $# > 0 )); then rest+=("$@"); fi; break ;;
      -*) err "unknown ask option: $1"; return 2 ;;
      *)
        if [[ -z "$provider" ]]; then provider="$1"; else rest+=("$1"); fi
        ;;
    esac
    shift
  done

  [[ -n "$provider" ]] || { err 'ask requires a model: claude, codex, or gemini.'; return 2; }

  local max_depth timeout
  max_depth="$(resolve_max_depth "$depth_arg")" || return 2
  timeout="$(resolve_timeout "$timeout_arg")" || return 2

  local prompt
  if ! prompt="$(read_prompt ${rest[@]+"${rest[@]}"})"; then
    err 'ask requires a prompt argument or piped stdin.'
    return 2
  fi
  run_provider "$provider" "$max_depth" "$prompt" "$timeout"
}

installed_reviewers() {
  local out=() p
  for p in claude codex gemini; do
    provider_installed "$p" && out+=("$p")
  done
  local IFS=,
  printf '%s' "${out[*]}"
}

split_models() {
  local csv="$1"
  local IFS=,
  read -r -a MODELS <<< "$csv"
}

make_review_context() {
  local root="$1" output="$2" max_bytes="$3"
  local status_file patch_file untracked_file patch_bytes
  status_file="${output}.status"
  patch_file="${output}.patch"
  untracked_file="${output}.untracked"

  # -uall matters: `git status --short` collapses a new directory to a single
  # "?? src/" line, so an entire new package can reach a reviewer as one entry
  # with no filenames at all.
  git status --short --branch --untracked-files=all > "$status_file"
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    git diff --no-ext-diff --no-color HEAD -- > "$patch_file"
  else
    git diff --no-ext-diff --no-color -- > "$patch_file"
  fi

  # Untracked files are invisible to `git diff` at any revision, so new code —
  # usually the code most in need of review — would otherwise be described only
  # by its path. Synthesize an add-diff for each one against /dev/null. Ignored
  # files stay out via --exclude-standard, and git renders binaries as a one-line
  # "Binary files differ" rather than dumping bytes into the prompt.
  : > "$untracked_file"
  git ls-files --others --exclude-standard -z |
    while IFS= read -r -d '' path; do
      git diff --no-ext-diff --no-color --no-index -- /dev/null "$path" || true
    done >> "$untracked_file"
  if [[ -s "$untracked_file" ]]; then
    cat "$untracked_file" >> "$patch_file"
  fi
  rm -f "$untracked_file"

  patch_bytes="$(wc -c < "$patch_file" | tr -d ' ')"
  {
    printf '<git_status>\n'
    cat "$status_file"
    printf '</git_status>\n\n'
    printf '<git_patch bytes="%s" max_embedded_bytes="%s" includes_untracked="true">\n' "$patch_bytes" "$max_bytes"
    if (( patch_bytes > max_bytes )); then
      head -c "$max_bytes" "$patch_file"
      printf '\n\n[Model Peer truncated the patch after %s bytes. Inspect listed files read-only for additional context.]\n' "$max_bytes"
    else
      cat "$patch_file"
    fi
    printf '\n</git_patch>\n'
  } > "$output"

  rm -f "$status_file" "$patch_file"
}

review_prompt() {
  local provider="$1" focus="$2" context_file="$3"
  cat <<PROMPT
You are one independent reviewer in a cross-model engineering review.
Other models receive the same starting evidence; you do not see their conclusions.

Review focus:
$focus

Review the current Git working tree. The status and patch are included below. The
patch covers tracked changes and new untracked files alike, so a file added in this
change appears as an add-diff rather than only as a path. You may inspect relevant
workspace files using read-only capabilities when useful, especially surrounding
code not represented in the patch.
Do not modify files and do not consult any other model.

Report only actionable findings. For each finding include:
- severity: critical, high, medium, or low
- file/path and line or symbol when possible
- why it matters
- recommended fix
- confidence: high, medium, or low

Also identify important test gaps. Avoid style-only comments unless they create a
real maintenance or correctness risk. If the changes look sound, say so explicitly.

Reviewer: $provider

$(cat "$context_file")
PROMPT
}

synthesis_prompt() {
  local focus="$1" reviews_dir="$2" dropped="${3:-}"
  local coverage='Every reviewer in the panel completed.'
  if [[ -n "${dropped//[[:space:]]/}" ]]; then
    coverage="These reviewers did NOT complete and contributed nothing:

$dropped
Their absence is a gap in coverage, not evidence of safety. Say so plainly in the
report, and do not describe the review as complete."
  fi

  cat <<PROMPT
You are the synthesis editor for an independent cross-model engineering review.
Do not inspect the repository, use tools, or consult another model. Reconcile the
reviewers' evidence; do not accept a claim merely because multiple models repeated it.

Review focus:
$focus

Panel coverage:
$coverage

Produce a decisive final report with:
1. Final prioritized findings, deduplicated
2. Which reviewer(s) raised each finding
3. Confidence: high, medium, or low
4. Recommended next action
5. Disagreements or likely false positives worth noting
6. Any gap in panel coverage, stated explicitly
7. A short "Looks good" conclusion if nothing material remains

<claude_review>
$(cat "$reviews_dir/claude.txt" 2>/dev/null || printf '[not run]')
</claude_review>

<codex_review>
$(cat "$reviews_dir/codex.txt" 2>/dev/null || printf '[not run]')
</codex_review>

<gemini_review>
$(cat "$reviews_dir/gemini.txt" 2>/dev/null || printf '[not run]')
</gemini_review>
PROMPT
}

cmd_review() {
  local reviewers="${MODEL_PEER_REVIEWERS:-}"
  local synthesizer="${MODEL_PEER_SYNTHESIZER:-}"
  local depth_arg=''
  local timeout_arg=''
  local strict=0
  local focus=''

  while (( $# > 0 )); do
    case "$1" in
      --models)
        shift; (( $# > 0 )) || { err '--models requires a value.'; return 2; }
        reviewers="$1"
        ;;
      --synthesizer)
        shift; (( $# > 0 )) || { err '--synthesizer requires a value.'; return 2; }
        synthesizer="$1"
        ;;
      --depth)
        shift; (( $# > 0 )) || { err '--depth requires a value.'; return 2; }
        depth_arg="$1"
        ;;
      --depth=*) depth_arg="${1#--depth=}" ;;
      --timeout)
        shift; (( $# > 0 )) || { err '--timeout requires a value.'; return 2; }
        timeout_arg="$1"
        ;;
      --timeout=*) timeout_arg="${1#--timeout=}" ;;
      --strict) strict=1 ;;
      -h|--help)
        cat <<'USAGE'
Usage:
  model-peer review [--models claude,codex,gemini] [--synthesizer MODEL]
                    [--depth N] [--timeout S] [--strict] ["focus"]

By default, every installed supported model reviews independently. At least two
reviewers are required. Claude is preferred for synthesis when installed, then
Codex, then Gemini. Set MODEL_PEER_REVIEWERS or MODEL_PEER_SYNTHESIZER to change defaults.

--depth N (1-10, default 1) caps the chain length for each reviewer. At depth 1 a
reviewer works alone. The synthesizer is always a leaf and never consults anyone.

--timeout S (default 600, 0 disables) bounds each reviewer independently, so one
hung model cannot cost you the whole panel. A reviewer that times out, fails, or
returns nothing at all is dropped and named in the report; synthesis proceeds as
long as at least two reviewers produced a real review. --strict restores the old
behavior of refusing to synthesize unless every reviewer succeeded.

The review covers untracked files as well as tracked changes, so newly added code
is reviewed rather than merely listed.
USAGE
        return 0
        ;;
      --) shift; focus="$*"; break ;;
      -*) err "unknown review option: $1"; return 2 ;;
      *) focus="${focus:+$focus }$1" ;;
    esac
    shift
  done

  local max_depth timeout
  max_depth="$(resolve_max_depth "$depth_arg")" || return 2
  timeout="$(resolve_timeout "$timeout_arg")" || return 2

  command -v git >/dev/null 2>&1 || { err "'git' is required for review."; return 127; }
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    err 'review must be run inside a Git working tree.'
    return 2
  }

  [[ -n "$reviewers" ]] || reviewers="$(installed_reviewers)"
  split_models "$reviewers"

  local valid=() p
  for p in "${MODELS[@]}"; do
    case "$p" in
      claude|codex|gemini) ;;
      '') continue ;;
      *) err "unknown review model '$p'."; return 2 ;;
    esac
    provider_installed "$p" || {
      err "reviewer '$p' is requested but not installed."
      return 127
    }
    valid+=("$p")
  done

  (( ${#valid[@]} >= 2 )) || {
    err 'review requires at least two installed models for cross-model review.'
    err 'Install another supported CLI or pass --models with at least two available models.'
    return 2
  }

  if [[ -z "$synthesizer" ]]; then
    for p in claude codex gemini; do
      if provider_installed "$p"; then synthesizer="$p"; break; fi
    done
  fi
  case "$synthesizer" in claude|codex|gemini) ;; *) err "invalid synthesizer '$synthesizer'."; return 2 ;; esac
  provider_installed "$synthesizer" || { err "synthesizer '$synthesizer' is not installed."; return 127; }

  focus="${focus:-Review the current working tree for correctness, regressions, security issues, missing tests, and unnecessary complexity.}"
  local root tmpdir context max_bytes prompt failed=0
  root="$(git rev-parse --show-toplevel)"
  cd "$root"
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/model-peer-review.XXXXXX")"
  context="$tmpdir/context.txt"
  max_bytes="${MODEL_PEER_MAX_DIFF_BYTES:-500000}"
  [[ "$max_bytes" =~ ^[0-9]+$ ]] || { err 'MODEL_PEER_MAX_DIFF_BYTES must be an integer.'; return 2; }
  make_review_context "$root" "$context" "$max_bytes"

  printf '\nModel Peer review: %s\n' "$(IFS=,; echo "${valid[*]}")" >&2
  printf 'Reviewers run independently; synthesis: %s\n' "$synthesizer" >&2
  if (( timeout > 0 )); then
    printf 'Per-reviewer timeout: %ss\n' "$timeout" >&2
  else
    printf 'Per-reviewer timeout: disabled\n' >&2
  fi

  # Kept as a counter plus a newline-delimited string rather than arrays: Bash 3.2
  # expands an empty array under `set -u` as an error, and this stays readable.
  local completed=0 dropped='' reason rc
  for p in "${valid[@]}"; do
    printf '\n=== %s independent review ===\n\n' "$(provider_label "$p")" >&2
    prompt="$(review_prompt "$p" "$focus" "$context")"
    # The inherited chain is preserved deliberately: at top level it is empty, so
    # each reviewer starts fresh, but a review launched from inside a peer chain
    # stays subject to the same depth guard and cannot escape it.
    #
    # tee keeps the review streaming to the terminal as it arrives while also
    # capturing it for synthesis; PIPESTATUS[0] is the reviewer's own status,
    # read inside the `if` so `set -e` cannot abort first.
    if run_provider "$p" "$max_depth" "$prompt" "$timeout" | tee "$tmpdir/$p.txt"; then
      rc=0
    else
      rc="${PIPESTATUS[0]}"
    fi

    reason=''
    if (( rc == TIMEOUT_EXIT )); then
      reason="timed out after ${timeout}s"
    elif (( rc != 0 )); then
      reason="failed with exit $rc"
    elif [[ ! -s "$tmpdir/$p.txt" ]]; then
      # A reviewer that exits 0 having written nothing has not reviewed anything.
      # Gemini's folder-trust gate failed exactly this way, and an empty file
      # would otherwise reach the synthesizer as "this model found no issues".
      reason='produced no output'
    fi

    if [[ -n "$reason" ]]; then
      err "$(provider_label "$p") $reason; dropping it from the panel."
      printf '[reviewer %s and was dropped from the panel]\n' "$reason" > "$tmpdir/$p.txt"
      dropped="${dropped}$(provider_label "$p") — $reason
"
      failed=1
    else
      completed=$(( completed + 1 ))
    fi
  done

  # A cross-model review needs at least two independent views to be worth the
  # name. Below that the result is one opinion with extra ceremony, so refuse
  # rather than dress it up as a panel.
  if (( strict == 1 )) && (( failed == 1 )); then
    err '--strict: refusing to synthesize because a reviewer did not complete.'
    rm -rf "$tmpdir"
    return 1
  fi
  if (( completed < 2 )); then
    err "only $completed reviewer(s) completed; refusing to synthesize a panel of fewer than two."
    err 'Raise --timeout, drop the failing model with --models, or check model-peer doctor.'
    rm -rf "$tmpdir"
    return 1
  fi
  if (( failed == 1 )); then
    note "synthesizing from $completed of ${#valid[@]} reviewers; the report will name the gaps."
  fi

  printf '\n=== Final synthesis (%s) ===\n\n' "$(provider_label "$synthesizer")" >&2
  prompt="$(synthesis_prompt "$focus" "$tmpdir" "$dropped")"
  local synth_status=0
  # Synthesis is always a leaf: give it exactly enough depth to run and none to
  # spend, so the final report can never be outsourced.
  local synth_depth=$(( $(stack_depth) + 1 ))
  if run_provider "$synthesizer" "$synth_depth" "$prompt"; then
    synth_status=0
  else
    synth_status=$?
  fi
  rm -rf "$tmpdir"
  return "$synth_status"
}

# ---------------------------------------------------------------------------
# Repo setup: skills
#
# `model-peer init` installs an agent skill so the coding agent a developer works
# with knows when to reach for a peer. Every file it writes is one Model Peer
# owns outright, in a directory the vendor set aside for exactly this:
#
#   .claude/skills/cross-model-review/SKILL.md
#   .codex/skills/cross-model-review/SKILL.md
#   .gemini/skills/cross-model-review/SKILL.md
#   .claude/commands/peer-review.md            (Claude Code slash command)
#
# AGENTS.md, CLAUDE.md, and GEMINI.md are the developer's. Model Peer never reads
# from, writes to, or symlinks them. That is the whole point of using skills: a
# self-contained directory can be rewritten wholesale by `model-peer update`,
# with no marker surgery inside a file someone else owns.
#
# Verified against the shipping CLIs, not the docs:
#   gemini  `gemini skills list` reports a project skill (folder trust required)
#   codex   `codex exec` lists it among available skills
#   claude  .claude/skills and SKILL.md are both in the binary
#
# `.codex/rules/` is a real directory but holds Starlark `.rules` files that
# govern command execution, not agent context. Markdown there is ignored.
# `.agents/skills/` is a Gemini-only alias; Codex and Claude do not read it.
#
# Only name and description reach the system prompt; the body is loaded when the
# model activates the skill. The description therefore has to carry the trigger
# conditions, or the skill never fires. Keep it concrete.
# ---------------------------------------------------------------------------

SKILL_NAME='cross-model-review'
# Backticks below are literal Markdown, not command substitution.
# shellcheck disable=SC2016
SKILL_MANAGED_MARKER='<!-- Managed by `model-peer init`.'
MP_DRY_RUN=0
MP_FORCE=0

agent_skill_path() {
  printf '.%s/skills/%s/SKILL.md' "$1" "$SKILL_NAME"
}

COMMAND_FILE='.claude/commands/peer-review.md'

# The two peers of a given agent, in a stable order.
agent_peer_a() {
  case "$1" in claude) printf 'codex' ;; codex|gemini) printf 'claude' ;; *) printf 'codex' ;; esac
}

agent_peer_b() {
  case "$1" in gemini) printf 'codex' ;; *) printf 'gemini' ;; esac
}

agent_peer_spec() {
  case "$1" in
    claude) printf '<codex|gemini>' ;;
    codex)  printf '<claude|gemini>' ;;
    gemini) printf '<claude|codex>' ;;
    *)      printf '<claude|codex|gemini>' ;;
  esac
}

# Quoted heredoc so the Markdown backticks stay literal; the per-agent values are
# substituted afterwards with '#' as the delimiter, because the peer spec
# contains '|'.
skill_body() {
  local agent="$1" spec peer_a peer_b label peer_a_label peer_b_label
  spec="$(agent_peer_spec "$agent")"
  peer_a="$(agent_peer_a "$agent")"
  peer_b="$(agent_peer_b "$agent")"
  label="$(provider_label "$agent")"
  peer_a_label="$(provider_label "$peer_a")"
  peer_b_label="$(provider_label "$peer_b")"

  sed -e "s#@@SPEC@@#$spec#g" \
      -e "s#@@PEER_A@@#$peer_a#g" \
      -e "s#@@PEER_B@@#$peer_b#g" \
      -e "s#@@LABEL@@#$label#g" \
      -e "s#@@PEER_A_LABEL@@#$peer_a_label#g" \
      -e "s#@@PEER_B_LABEL@@#$peer_b_label#g" <<'BODY'
---
name: cross-model-review
description: Consult @@PEER_A_LABEL@@ or @@PEER_B_LABEL@@ as an independent read-only peer through Model Peer, or run a full cross-model review of the current diff. Use before committing to an architecture, schema, or migration decision; on security-sensitive work such as authn/authz, sandboxing, input handling, secrets, or crypto; when a bug has outlived two hypotheses; when reviewing an implementation before handing it back; and before opening a pull request.
---

# Cross-model peer review

You are @@LABEL@@. **@@PEER_A_LABEL@@** and **@@PEER_B_LABEL@@** are available as
independent, read-only engineering peers. Reach them through Model Peer.

```bash
# one peer, one answer
model-peer ask @@SPEC@@ "<focused question>"

# every installed model reviews the current diff independently, then one
# synthesizer reconciles the findings
model-peer review ["focus"]

# which peers are available here
model-peer doctor
```

## When to consult a peer

- before committing to an architecture, schema, or migration decision
- when a bug has outlived two of your own hypotheses
- security-sensitive work: authn/authz, sandboxing, input handling, secrets, crypto
- unfamiliar code, or a dependency whose behavior you are inferring
- reviewing an implementation you just wrote, before you hand it back
- an assumption you cannot cheaply verify by reading the code
- two approaches you cannot decide between — ask for the tradeoff, not the verdict

Run `model-peer review` before opening a pull request, and again after any change
to security-sensitive code.

Do not consult for anything you can settle by reading the code. Every consultation
costs a model call and tens of seconds.

## How to ask

The peer starts in this working directory with read-only tools, so **name files and
symbols instead of pasting excerpts**, and ask one focused question. A peer that has
to guess at scope returns generic advice.

```bash
# good — scoped to a symbol, answerable from the repository
model-peer ask @@PEER_A@@ "In src/auth/session.ts, can refresh_token leave the old token valid if rotation fails midway?"

# bad — no scope
model-peer ask @@PEER_A@@ "review my auth code"
```

Pipe context in when the question is about something not on disk:

```bash
git diff main... | model-peer ask @@PEER_B@@ "What breaks in production?"
```

## Peer output is advisory

Evaluate every response before acting on it. Peers do not know this project's
invariants, so advice that contradicts the rules in this repository is wrong here
however sound it sounds in general.

When a peer materially changed a decision, say which model you asked and whether you
took the advice. Never present a peer's output as your own conclusion.

## Limits

Leave `--depth` at its default of `1`: each peer answers alone, and lengthening the
chain is a human's deliberate call. A model is never consulted by itself.

If you are reading this **while acting as a peer** in someone else's consultation,
these instructions do not apply to you. Answer the question and consult no one.
BODY
}

# Every managed file carries this line, which is how `update` and `check` tell a
# file Model Peer owns from one a developer wrote by hand.
skill_file() {
  local agent="$1"
  skill_body "$agent" | awk -v marker="$SKILL_MANAGED_MARKER" -v version="$VERSION" '
    NR == 1 { print; next }
    !done && $0 == "---" {
      print
      print ""
      printf "%s Version %s. Re-run `model-peer update` to refresh; local edits are replaced. -->\n", marker, version
      done = 1
      next
    }
    { print }
  '
}

command_file_body() {
  cat <<CMD
---
description: Independent cross-model review of the current working diff
argument-hint: [focus instructions]
allowed-tools: Bash(model-peer:*)
---

$SKILL_MANAGED_MARKER Version $VERSION. Re-run \`model-peer update\` to refresh. -->

Run an independent cross-model review of the current working tree with
\`model-peer review\`, passing \`\$ARGUMENTS\` as the focus when it is non-empty.

Every installed model reviews the same diff without seeing the others'
conclusions, then a synthesizer reconciles them. This takes a few minutes and
prints progress on stderr — let it finish.

Then:

1. Report the synthesized findings, grouped by severity, without softening them.
2. For each finding, say whether you agree and why. A peer does not know this
   project's invariants; project rules win over generic advice.
3. Do not apply any fix unless I ask for it.
CMD
}

# Managed files are owned outright, so they are compared and replaced whole. No
# marker surgery, because nothing Model Peer writes lives inside someone else's
# file any more.
mp_desired_content() {
  local rel="$1"
  case "$rel" in
    "$COMMAND_FILE") command_file_body ;;
    .claude/*) skill_file claude ;;
    .codex/*)  skill_file codex ;;
    .gemini/*) skill_file gemini ;;
  esac
}

mp_is_managed() {
  [[ -f "$1" ]] && grep -Fq "$SKILL_MANAGED_MARKER" "$1"
}

# Prints one status word: created | updated | current | conflict
mp_apply_file() {
  local path="$1" rel="$2" desired
  desired="$(mp_desired_content "$rel")"

  if [[ ! -e "$path" ]]; then
    if (( MP_DRY_RUN == 0 )); then
      mkdir -p "$(dirname "$path")"
      printf '%s\n' "$desired" > "$path"
    fi
    printf 'created'
    return
  fi

  # Someone else's file at our path: never clobber it without --force.
  if ! mp_is_managed "$path" && (( MP_FORCE == 0 )); then
    printf 'conflict'
    return
  fi

  if [[ "$(cat "$path")" == "$desired" ]]; then
    printf 'current'
    return
  fi

  if (( MP_DRY_RUN == 0 )); then
    printf '%s\n' "$desired" > "$path"
  fi
  printf 'updated'
}

mp_report() {
  printf '  %-9s %s\n' "$1" "$2"
}

mp_in_list() {
  local needle="$1" csv="$2" item
  local IFS=,
  for item in $csv; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

mp_validate_agents() {
  local csv="$1" item
  [[ -n "${csv//[[:space:],]/}" ]] || { err '--agents requires at least one model.'; return 2; }
  local IFS=,
  for item in $csv; do
    case "$item" in
      claude|codex|gemini|'') ;;
      *) err "unknown agent '$item'. Use claude, codex, or gemini."; return 2 ;;
    esac
  done
  return 0
}

mp_target_dir() {
  local requested="$1"
  if [[ -n "$requested" ]]; then
    [[ -d "$requested" ]] || { err "no such directory: $requested"; return 2; }
    ( cd "$requested" && pwd )
    return
  fi
  if command -v git >/dev/null 2>&1 && git rev-parse --show-toplevel >/dev/null 2>&1; then
    git rev-parse --show-toplevel
    return
  fi
  pwd
}

# Every file init manages, for the given agents, as "relative-path" lines.
mp_managed_files() {
  local agents="$1" want_command="$2" agent
  for agent in claude codex gemini; do
    mp_in_list "$agent" "$agents" || continue
    agent_skill_path "$agent"
    printf '\n'
  done
  if (( want_command == 1 )) && mp_in_list claude "$agents"; then
    printf '%s\n' "$COMMAND_FILE"
  fi
}

init_usage() {
  cat <<'USAGE'
Usage:
  model-peer init [options]

Installs the cross-model review skill so your coding agent knows when to reach for
a peer, plus the /peer-review slash command for Claude Code.

Everything it writes is a file Model Peer owns, in the directory each vendor set
aside for skills:

  .claude/skills/cross-model-review/SKILL.md
  .codex/skills/cross-model-review/SKILL.md
  .gemini/skills/cross-model-review/SKILL.md
  .claude/commands/peer-review.md

Your AGENTS.md, CLAUDE.md, and GEMINI.md are never read, written, or symlinked.
Run `model-peer update` after upgrading to refresh what is installed.

Options:
  --agents LIST    Comma-separated: claude, codex, gemini (default: all three,
                   so a teammate on a different CLI is covered too)
  --no-command     Skip .claude/commands/peer-review.md
  --print          Write the SKILL.md to stdout and exit; touch nothing
  --dir DIR        Target directory (default: the Git root, else the cwd)
  --dry-run        Report what would change; write nothing
  --force          Replace a file at one of these paths that Model Peer does not
                   manage. Without it, such a file is reported and left alone.
  -h, --help       This help
USAGE
}

cmd_init() {
  local agents='claude,codex,gemini' dir='' want_command=1 print_only='' rel path status
  MP_DRY_RUN=0
  MP_FORCE=0

  while (( $# > 0 )); do
    case "$1" in
      --agents)
        shift; (( $# > 0 )) || { err '--agents requires a value.'; return 2; }
        agents="$1"
        ;;
      --agents=*) agents="${1#--agents=}" ;;
      --dir)
        shift; (( $# > 0 )) || { err '--dir requires a value.'; return 2; }
        dir="$1"
        ;;
      --dir=*) dir="${1#--dir=}" ;;
      --no-command) want_command=0 ;;
      --print) print_only='claude' ;;
      --print=*) print_only="${1#--print=}" ;;
      --dry-run) MP_DRY_RUN=1 ;;
      --force) MP_FORCE=1 ;;
      -h|--help) init_usage; return 0 ;;
      --split)
        err '--split was removed: init writes self-contained skills, one per agent.'
        return 2
        ;;
      -*) err "unknown init option: $1"; return 2 ;;
      *) err "init takes no positional arguments (got '$1')."; return 2 ;;
    esac
    shift
  done

  if [[ -n "$print_only" ]]; then
    case "$print_only" in
      claude|codex|gemini) skill_file "$print_only" ;;
      command) command_file_body ;;
      *) err "unknown --print target '$print_only'. Use claude, codex, gemini, or command."; return 2 ;;
    esac
    return 0
  fi

  mp_validate_agents "$agents" || return 2

  local root
  root="$(mp_target_dir "$dir")" || return 2

  if (( MP_DRY_RUN == 1 )); then
    printf 'Model Peer — dry run, nothing written\n'
  else
    printf 'Model Peer\n'
  fi
  printf '  target    %s\n\n' "$root"

  local conflicts=0
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    path="$root/$rel"
    status="$(mp_apply_file "$path" "$rel")"
    if [[ "$status" == 'conflict' ]]; then
      mp_report 'skipped' "$rel (not managed by Model Peer; --force to replace)"
      conflicts=1
    else
      mp_report "$status" "$rel"
    fi
  done <<EOF
$(mp_managed_files "$agents" "$want_command")
EOF

  if (( MP_DRY_RUN == 1 )); then
    printf '\nRe-run without --dry-run to apply.\n'
    return 0
  fi

  printf '\nNothing outside these paths was touched.\n'
  printf 'Commit them so your team gets the same behavior.\n'
  if mp_in_list gemini "$agents"; then
    printf '\nGemini only loads project skills in a trusted folder. If it reports\n'
    # shellcheck disable=SC2016  # literal Markdown backticks
    printf 'none, trust this directory once from an interactive `gemini` session.\n'
  fi
  if (( conflicts == 1 )); then
    printf '\nSome paths were left alone because Model Peer did not write them.\n'
    printf 'Inspect them, then re-run with --force to replace.\n'
  fi
  printf '\nNext:  model-peer doctor        # confirm at least two CLIs are installed\n'
  printf '       model-peer review        # cross-model review of the current diff\n'
  if (( want_command == 1 )) && mp_in_list claude "$agents"; then
    printf '       /peer-review             # the same, from inside Claude Code\n'
  fi
}

update_usage() {
  cat <<'USAGE'
Usage:
  model-peer update [--check] [--dir DIR]

Refreshes the Model Peer files already installed in this project so they match
the version of Model Peer you are running. Only files Model Peer manages are
touched, and only those that already exist — update never installs a new agent,
so it cannot quietly widen what is in your repository. Use `init` for that.

  --check     Report drift and exit 1 if anything is missing or stale; write
              nothing. Suitable for CI.
  --dir DIR   Target directory (default: the Git root, else the cwd)
USAGE
}

cmd_update() {
  local check=0 dir='' rel path desired agent
  MP_DRY_RUN=0
  MP_FORCE=0

  while (( $# > 0 )); do
    case "$1" in
      --check) check=1; MP_DRY_RUN=1 ;;
      --dir)
        shift; (( $# > 0 )) || { err '--dir requires a value.'; return 2; }
        dir="$1"
        ;;
      --dir=*) dir="${1#--dir=}" ;;
      -h|--help) update_usage; return 0 ;;
      -*) err "unknown update option: $1"; return 2 ;;
      *) err "update takes no positional arguments (got '$1')."; return 2 ;;
    esac
    shift
  done

  local root
  root="$(mp_target_dir "$dir")" || return 2

  local found=0 stale=0 unmanaged=0
  for agent in claude codex gemini; do
    rel="$(agent_skill_path "$agent")"
    path="$root/$rel"
    [[ -e "$path" ]] || continue
    found=1
    if ! mp_is_managed "$path"; then
      mp_report 'foreign' "$rel (not written by Model Peer; left alone)"
      unmanaged=1
      continue
    fi
    desired="$(mp_desired_content "$rel")"
    if [[ "$(cat "$path")" == "$desired" ]]; then
      mp_report 'current' "$rel"
    else
      (( check == 1 )) || printf '%s\n' "$desired" > "$path"
      mp_report "$( (( check == 1 )) && printf 'stale' || printf 'updated' )" "$rel"
      stale=1
    fi
  done

  path="$root/$COMMAND_FILE"
  if [[ -e "$path" ]]; then
    found=1
    if mp_is_managed "$path"; then
      desired="$(mp_desired_content "$COMMAND_FILE")"
      if [[ "$(cat "$path")" == "$desired" ]]; then
        mp_report 'current' "$COMMAND_FILE"
      else
        (( check == 1 )) || printf '%s\n' "$desired" > "$path"
        mp_report "$( (( check == 1 )) && printf 'stale' || printf 'updated' )" "$COMMAND_FILE"
        stale=1
      fi
    else
      mp_report 'foreign' "$COMMAND_FILE (not written by Model Peer; left alone)"
      unmanaged=1
    fi
  fi

  if (( found == 0 )); then
    err 'no Model Peer files found in this project. Run: model-peer init'
    return 1
  fi
  if (( check == 1 )) && (( stale == 1 )); then
    err 'installed files are out of date. Run: model-peer update'
    return 1
  fi
  if (( unmanaged == 1 )); then
    note 'some paths hold files Model Peer did not write; they were left alone.'
  fi
  return 0
}

# Missing skills are the single most common reason consultation never happens.
doctor_repo_skills() {
  local root rel agent found=0
  root="$(mp_target_dir '')" || return 0
  for agent in claude codex gemini; do
    rel="$(agent_skill_path "$agent")"
    [[ -f "$root/$rel" ]] || continue
    if (( found == 0 )); then
      printf '\nProject skills in %s\n' "$root"
      found=1
    fi
    printf '  %s\n' "$rel"
  done
  if [[ -f "$root/$COMMAND_FILE" ]]; then
    if (( found == 0 )); then
      printf '\nProject skills in %s\n' "$root"
      found=1
    fi
    printf '  %s\n' "$COMMAND_FILE"
  fi
  if (( found == 0 )); then
    printf '\nProject skills: none in %s (run: model-peer init)\n' "$root"
  fi
}

cmd_doctor() {
  printf 'Model Peer v%s\n\n' "$VERSION"
  local p found=0
  for p in claude codex gemini; do
    if provider_installed "$p"; then
      found=1
      printf '%-8s  installed  %s\n' "$(provider_label "$p")" "$(command -v "$p")"
    else
      printf '%-8s  missing\n' "$(provider_label "$p")"
    fi
  done
  printf '\nSafety defaults\n'
  printf '  Claude  plan mode; Read/Glob/Grep only; stdin closed\n'
  printf '  Codex   read-only sandbox; ephemeral session; stdin closed\n'
  printf '  Gemini  plan mode + deny policy; extensions disabled; stdin closed\n'
  printf '  Gemini  workspace trusted for the session so headless runs are not silent no-ops\n'
  printf '  All     chain guard via MODEL_PEER_STACK; no model consults itself\n'
  printf '  All     peers never write, and never gain a general shell\n'

  printf '\nNested consultation support\n'
  for p in claude codex gemini; do
    case "$(provider_delegation_support "$p")" in
      namespaced) printf '  %-8s yes   execution scoped to the model-peer command namespace\n' "$(provider_label "$p")" ;;
      sandboxed)  printf '  %-8s yes   read-only sandbox already permits it; nothing added\n' "$(provider_label "$p")" ;;
      *)          printf '  %-8s no    cannot scope execution to model-peer alone; always a leaf\n' "$(provider_label "$p")" ;;
    esac
  done

  local effective_timeout
  if effective_timeout="$(resolve_timeout '' 2>/dev/null)"; then
    if (( effective_timeout > 0 )); then
      printf '\nConsultation timeout:   %ss per peer\n' "$effective_timeout"
    else
      printf '\nConsultation timeout:   disabled\n'
    fi
  else
    printf '\nConsultation timeout:   invalid MODEL_PEER_TIMEOUT=%s\n' "${MODEL_PEER_TIMEOUT:-}"
  fi

  local effective_depth
  if effective_depth="$(resolve_max_depth '' 2>/dev/null)"; then
    printf '\nPeer-chain depth limit: %s (max %s)\n' "$effective_depth" "$DEPTH_CEILING"
  else
    printf '\nPeer-chain depth limit: invalid MODEL_PEER_MAX_DEPTH=%s\n' "${MODEL_PEER_MAX_DEPTH:-}"
  fi
  if [[ -n "${MODEL_PEER_STACK:-}" ]]; then
    printf 'Active peer chain:      %s (depth %s)\n' "$MODEL_PEER_STACK" "$(stack_depth)"
  fi

  if provider_installed claude; then
    if claude auth status >/dev/null 2>&1; then
      printf '\nClaude authentication: available\n'
    else
      printf '\nClaude authentication: not confirmed (run: claude auth login)\n'
    fi
  fi
  if provider_installed codex; then
    if codex login status >/dev/null 2>&1; then
      printf 'Codex authentication:  available\n'
    else
      printf 'Codex authentication:  not confirmed (run: codex login)\n'
    fi
  fi
  if provider_installed gemini; then
    if [[ -n "${GEMINI_API_KEY:-}${GOOGLE_API_KEY:-}${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
      printf 'Gemini authentication: environment-based auth detected\n'
    else
      printf 'Gemini authentication: installed; cached OAuth is verified on first request (run: gemini)\n'
    fi
  fi

  doctor_repo_skills

  (( found == 1 )) || return 1
}

main() {
  case "${1:-}" in
    ask)
      shift
      cmd_ask "$@"
      ;;
    review)
      shift
      cmd_review "$@"
      ;;
    init)
      shift
      cmd_init "$@"
      ;;
    update)
      shift
      cmd_update "$@"
      ;;
    doctor)
      shift
      (( $# == 0 )) || { err 'doctor takes no arguments.'; return 2; }
      cmd_doctor
      ;;
    -h|--help|help|'') usage ;;
    -V|--version|version) printf 'model-peer %s\n' "$VERSION" ;;
    *) err "unknown command '$1'."; usage >&2; return 2 ;;
  esac
}

main "$@"
__MODEL_PEER__
  chmod +x "$BIN_DIR/model-peer"

  cat > "$BIN_DIR/ask-claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/model-peer" ask claude "$@"
EOF
  cat > "$BIN_DIR/ask-codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/model-peer" ask codex "$@"
EOF
  cat > "$BIN_DIR/ask-gemini" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/model-peer" ask gemini "$@"
EOF
  cat > "$BIN_DIR/ai-review" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/model-peer" review "$@"
EOF
  chmod +x "$BIN_DIR/ask-claude" "$BIN_DIR/ask-codex" "$BIN_DIR/ask-gemini" "$BIN_DIR/ai-review"
}

install_claude() {
  command -v claude >/dev/null 2>&1 && return 0
  printf '%s\n' "Installing Claude Code with Anthropic's native installer..."
  curl -fsSL https://claude.ai/install.sh | bash
}

install_codex() {
  command -v codex >/dev/null 2>&1 && return 0
  if command -v npm >/dev/null 2>&1; then
    printf '
Installing Codex CLI with npm...
'
    npm install -g @openai/codex
  else
    printf 'Codex is missing and npm is unavailable. See https://developers.openai.com/codex/cli
' >&2
    return 1
  fi
}

install_gemini() {
  command -v gemini >/dev/null 2>&1 && return 0
  if command -v brew >/dev/null 2>&1; then
    printf '
Installing Gemini CLI with Homebrew...
'
    brew install gemini-cli
  elif command -v npm >/dev/null 2>&1; then
    printf '
Installing Gemini CLI with npm...
'
    npm install -g @google/gemini-cli
  else
    printf 'Gemini is missing and neither Homebrew nor npm is available. See https://google-gemini.github.io/gemini-cli/docs/get-started/
' >&2
    return 1
  fi
}

setup_dependencies() {
  local p
  for p in claude codex gemini; do
    command -v "$p" >/dev/null 2>&1 && continue
    if (( INSTALL_DEPS == 1 )); then
      "install_$p" || true
    elif (( DO_SETUP == 1 )) && ask_yes_no "Install missing $p CLI?" n; then
      "install_$p" || true
    fi
  done
}

setup_login() {
  if (( DO_LOGIN == 0 && DO_SETUP == 0 )); then return; fi

  if command -v claude >/dev/null 2>&1; then
    if ! claude auth status >/dev/null 2>&1; then
      if (( DO_LOGIN == 1 )) || ask_yes_no 'Launch Claude login?' y; then
        claude auth login || true
      fi
    fi
  fi

  if command -v codex >/dev/null 2>&1; then
    if ! codex login status >/dev/null 2>&1; then
      if (( DO_LOGIN == 1 )) || ask_yes_no 'Launch Codex login?' y; then
        codex login || true
      fi
    fi
  fi

  if command -v gemini >/dev/null 2>&1; then
    if (( DO_LOGIN == 1 )) || ask_yes_no 'Launch Gemini setup/login? (skip if already authenticated)' n; then
      gemini || true
    fi
  fi
}

ensure_path
write_commands
setup_dependencies
export PATH="$BIN_DIR:$PATH"
setup_login

printf '
Model Peer v%s installed in %s
' "$VERSION" "$BIN_DIR"
printf 'Try:
'
printf '  model-peer doctor
'
printf '  model-peer ask codex "Review this architecture"
'
printf '  model-peer review
'
