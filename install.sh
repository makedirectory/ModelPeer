#!/usr/bin/env bash
set -euo pipefail

VERSION="0.2.0"
BIN_DIR="${MODEL_PEER_BIN_DIR:-$HOME/.local/bin}"
DO_SETUP=0
INSTALL_DEPS=0
DO_LOGIN=0

usage() {
  cat <<'USAGE'
Model Peer installer v0.2.0

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

VERSION="0.2.0"
PROGRAM="model-peer"

usage() {
  cat <<'USAGE'
Model Peer v0.2.0 — cross-model peer review for coding agents.

Usage:
  model-peer ask claude "<focused question>"
  model-peer ask codex "<focused question>"
  model-peer ask gemini "<focused question>"
  command | model-peer ask <claude|codex|gemini>

  model-peer review [options] ["focus instructions"]

  model-peer init [options]            Install the consultation rules in a repo
  model-peer rules <install|print|check>
  model-peer doctor
  model-peer --version

Ask options:
  --depth N              Max peer-chain length, 1-10 (default: 1)

Review options:
  --models LIST          Comma-separated reviewers (default: all installed)
  --synthesizer MODEL    claude, codex, or gemini (default: first available in
                         claude,codex,gemini order)
  --depth N              Max peer-chain length for each reviewer, 1-10 (default: 1)

Init options:
  --split                One tailored rules file per CLI instead of a shared
                         AGENTS.md with CLAUDE.md and GEMINI.md symlinked to it
  --agents LIST          Comma-separated: claude, codex, gemini (default: all)
  --no-command           Skip the Claude Code /peer-review slash command
  --dry-run              Report what would change; write nothing

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

  if MODEL_PEER_STACK="$stack" MODEL_PEER_MAX_DEPTH="$max_depth" \
      gemini \
        --approval-mode plan \
        --policy "$policy" \
        -e none \
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
  local provider="$1" max_depth="$2" prompt="$3"
  require_nonempty_prompt "$prompt" || return

  case "$provider" in
    claude|codex|gemini) ;;
    *) err "unknown model '$provider'. Use claude, codex, or gemini."; return 2 ;;
  esac

  check_chain "$provider" "$max_depth" || return 64

  local stack remaining delegation
  stack="$(push_stack "$provider")"
  remaining=$(( max_depth - $(stack_depth) - 1 ))
  delegation="$(resolve_delegation "$provider" "$remaining")"

  # A depth budget the provider cannot safely hold is reported, never silently
  # converted into a wider sandbox.
  if (( remaining > 0 )) && [[ "$delegation" == 'none' ]]; then
    note "$(provider_label "$provider") cannot initiate nested consultation; answering as a leaf."
    note "Reason: its policy engine cannot scope execution to model-peer alone. See README."
  fi

  case "$provider" in
    claude) run_claude "$prompt" "$stack" "$remaining" "$max_depth" "$delegation" ;;
    codex)  run_codex  "$prompt" "$stack" "$remaining" "$max_depth" "$delegation" ;;
    gemini) run_gemini "$prompt" "$stack" "$remaining" "$max_depth" "$delegation" ;;
  esac
}

cmd_ask() {
  local provider='' depth_arg=''
  local -a rest=()

  while (( $# > 0 )); do
    case "$1" in
      --depth)
        shift; (( $# > 0 )) || { err '--depth requires a value.'; return 2; }
        depth_arg="$1"
        ;;
      --depth=*) depth_arg="${1#--depth=}" ;;
      -h|--help)
        cat <<'USAGE'
Usage:
  model-peer ask <claude|codex|gemini> [--depth N] "<focused question>"
  command | model-peer ask <claude|codex|gemini> [--depth N]

  --depth N   Max peer-chain length, 1-10 (default: 1). Depth 1 means the peer
              answers alone. Above 1, the peer may consult a further model where
              its provider can scope that execution to model-peer alone; peers
              whose sandbox cannot express that stay leaves. Use -- to end
              options when the prompt itself starts with a dash.
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

  local max_depth
  max_depth="$(resolve_max_depth "$depth_arg")" || return 2

  local prompt
  if ! prompt="$(read_prompt ${rest[@]+"${rest[@]}"})"; then
    err 'ask requires a prompt argument or piped stdin.'
    return 2
  fi
  run_provider "$provider" "$max_depth" "$prompt"
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
  local status_file patch_file patch_bytes
  status_file="${output}.status"
  patch_file="${output}.patch"

  git status --short --branch > "$status_file"
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    git diff --no-ext-diff --no-color HEAD -- > "$patch_file"
  else
    git diff --no-ext-diff --no-color -- > "$patch_file"
  fi

  patch_bytes="$(wc -c < "$patch_file" | tr -d ' ')"
  {
    printf '<git_status>\n'
    cat "$status_file"
    printf '</git_status>\n\n'
    printf '<git_patch bytes="%s" max_embedded_bytes="%s">\n' "$patch_bytes" "$max_bytes"
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

Review the current Git working tree. The status and patch are included below.
You may inspect relevant workspace files using read-only capabilities when useful,
especially untracked files or surrounding code not fully represented in the patch.
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
  local focus="$1" reviews_dir="$2"
  cat <<PROMPT
You are the synthesis editor for an independent cross-model engineering review.
Do not inspect the repository, use tools, or consult another model. Reconcile the
reviewers' evidence; do not accept a claim merely because multiple models repeated it.

Review focus:
$focus

Produce a decisive final report with:
1. Final prioritized findings, deduplicated
2. Which reviewer(s) raised each finding
3. Confidence: high, medium, or low
4. Recommended next action
5. Disagreements or likely false positives worth noting
6. A short "Looks good" conclusion if nothing material remains

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
      -h|--help)
        cat <<'USAGE'
Usage:
  model-peer review [--models claude,codex,gemini] [--synthesizer MODEL]
                    [--depth N] ["focus"]

By default, every installed supported model reviews independently. At least two
reviewers are required. Claude is preferred for synthesis when installed, then
Codex, then Gemini. Set MODEL_PEER_REVIEWERS or MODEL_PEER_SYNTHESIZER to change defaults.

--depth N (1-10, default 1) caps the chain length for each reviewer. At depth 1 a
reviewer works alone. The synthesizer is always a leaf and never consults anyone.
USAGE
        return 0
        ;;
      --) shift; focus="$*"; break ;;
      -*) err "unknown review option: $1"; return 2 ;;
      *) focus="${focus:+$focus }$1" ;;
    esac
    shift
  done

  local max_depth
  max_depth="$(resolve_max_depth "$depth_arg")" || return 2

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

  for p in "${valid[@]}"; do
    printf '\n=== %s independent review ===\n\n' "$(provider_label "$p")" >&2
    prompt="$(review_prompt "$p" "$focus" "$context")"
    # The inherited chain is preserved deliberately: at top level it is empty, so
    # each reviewer starts fresh, but a review launched from inside a peer chain
    # stays subject to the same depth guard and cannot escape it.
    if run_provider "$p" "$max_depth" "$prompt" | tee "$tmpdir/$p.txt"; then
      :
    else
      err "$p review failed."
      failed=1
      printf '[review failed]\n' > "$tmpdir/$p.txt"
    fi
  done

  (( failed == 0 )) || {
    err 'one or more reviewers failed; refusing to synthesize an incomplete panel.'
    rm -rf "$tmpdir"
    return 1
  }

  printf '\n=== Final synthesis (%s) ===\n\n' "$(provider_label "$synthesizer")" >&2
  prompt="$(synthesis_prompt "$focus" "$tmpdir")"
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
# Repo rules
#
# `model-peer init` drops the consultation rules into a project so the agent a
# developer actually works with knows when to reach for a peer. These files are
# for that primary agent, not for peers: a consulted peer is already told to
# consult no one, and the block repeats that for the case where a peer loads the
# file anyway because it runs in the same working directory.
#
# Only write paths the vendor CLIs genuinely load:
#
#   Claude Code  CLAUDE.md, and every .claude/rules/**/*.md
#   Codex CLI    AGENTS.md (also AGENTS.override.md)
#   Gemini CLI   GEMINI.md
#
# Codex and Gemini have no per-repo rules directory. A .codex/rules/ file or a
# .gemini/global_rules.md is inert — Codex's extra context filenames come from
# the global project_doc_fallback_filenames key, not from the repo — so init
# never creates one. Verify before adding a path here.
# ---------------------------------------------------------------------------

RULES_BEGIN='<!-- BEGIN MODEL PEER RULES -->'
RULES_END='<!-- END MODEL PEER RULES -->'
RULES_CLAUDE_FILE='.claude/rules/cross-model-consultation.md'
RULES_COMMAND_FILE='.claude/commands/peer-review.md'
RULES_DRY_RUN=0
RULES_FORCE=0

# Profiles: 'shared' is model-agnostic, for one file every CLI reads. The others
# address one CLI directly and name its two peers, for the --split layout.
# Backticks here are literal Markdown, not command substitution.
# shellcheck disable=SC2016
rules_lead() {
  case "$1" in
    claude) printf 'You are Claude Code. **Codex** and **Gemini** are installed alongside you as\nindependent, read-only engineering peers. Reach them through Model Peer.\n' ;;
    codex)  printf 'You are Codex. **Claude** and **Gemini** are installed alongside you as\nindependent, read-only engineering peers. Reach them through Model Peer.\n' ;;
    gemini) printf 'You are Gemini. **Claude** and **Codex** are installed alongside you as\nindependent, read-only engineering peers. Reach them through Model Peer.\n' ;;
    *)      printf 'Other vendors'"'"' coding CLIs are installed as independent, read-only engineering\npeers. Reach them through Model Peer, and consult any of them except yourself —\nit refuses to let a model consult itself.\n' ;;
  esac
}

rules_peer_spec() {
  case "$1" in
    claude) printf '<codex|gemini>' ;;
    codex)  printf '<claude|gemini>' ;;
    gemini) printf '<claude|codex>' ;;
    *)      printf '<claude|codex|gemini>' ;;
  esac
}

rules_peer_a() {
  case "$1" in claude) printf 'codex' ;; codex|gemini) printf 'claude' ;; *) printf 'codex' ;; esac
}

rules_peer_b() {
  case "$1" in gemini) printf 'codex' ;; *) printf 'gemini' ;; esac
}

# The body is a quoted heredoc so its backticks stay literal Markdown; the three
# per-profile values are substituted afterwards. '#' is the sed delimiter because
# the peer spec contains '|'.
rules_body() {
  local profile="$1" spec peer_a peer_b
  spec="$(rules_peer_spec "$profile")"
  peer_a="$(rules_peer_a "$profile")"
  peer_b="$(rules_peer_b "$profile")"
  sed -e "s#@@SPEC@@#$spec#g" -e "s#@@PEER_A@@#$peer_a#g" -e "s#@@PEER_B@@#$peer_b#g" <<'BODY'

```bash
# one peer, one answer
model-peer ask @@SPEC@@ "<focused question>"

# every installed model reviews the current diff independently, then one
# synthesizer reconciles the findings
model-peer review ["focus"]

# which peers are available here
model-peer doctor
```

### When to consult a peer

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

### How to ask

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

### Peer output is advisory

Evaluate every response before acting on it. Peers do not know this project's
invariants, so advice that contradicts the rules in this repository is wrong here
however sound it sounds in general.

When a peer materially changed a decision, say which model you asked and whether you
took the advice. Never present a peer's output as your own conclusion.

### Limits

Leave `--depth` at its default of `1`: each peer answers alone, and lengthening the
chain is a human's deliberate call. A model is never consulted by itself.

If you are reading this **while acting as a peer** in someone else's consultation,
these instructions do not apply to you. Answer the question and consult no one.
BODY
}

# shellcheck disable=SC2016  # backticks are literal Markdown
rules_block() {
  local profile="$1"
  printf '%s\n' "$RULES_BEGIN"
  printf '<!-- Managed by `model-peer init` (v%s, profile: %s). Re-run to update; edit outside this block. -->\n' \
    "$VERSION" "$profile"
  printf '\n## Cross-model peer review\n\n'
  rules_lead "$profile"
  rules_body "$profile"
  printf '%s\n' "$RULES_END"
}

# The Claude Code slash command is managed whole-file rather than as a block: it
# has YAML front matter, so appending to a foreign file would corrupt it.
rules_command_body() {
  cat <<'CMD'
---
description: Independent cross-model review of the current working diff
argument-hint: [focus instructions]
allowed-tools: Bash(model-peer:*)
---

<!-- Managed by `model-peer init`. Re-run with --force to update. -->

Run an independent cross-model review of the current working tree with
`model-peer review`, passing `$ARGUMENTS` as the focus when it is non-empty.

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

rules_file_block() {
  awk -v b="$RULES_BEGIN" -v e="$RULES_END" '
    $0 == b { inb = 1 }
    inb { print }
    inb && $0 == e { exit }
  ' "$1"
}

rules_file_profile() {
  sed -n 's/^<!-- Managed by .*profile: \([a-z][a-z]*\)).*/\1/p' "$1" | head -1
}

# Creates the file, refreshes an existing managed block in place, or appends the
# block to a file that does not have one. Content outside the markers is never
# touched. Prints one status word.
rules_apply_block() {
  local file="$1" profile="$2" new tmp blk
  new="$(rules_block "$profile")"

  if [[ ! -e "$file" ]]; then
    if (( RULES_DRY_RUN == 0 )); then
      mkdir -p "$(dirname "$file")"
      printf '%s\n' "$new" > "$file"
    fi
    printf 'created'
    return
  fi

  if grep -Fqx "$RULES_BEGIN" "$file"; then
    if [[ "$(rules_file_block "$file")" == "$new" ]]; then
      printf 'current'
      return
    fi
    if (( RULES_DRY_RUN == 0 )); then
      tmp="$(mktemp "${TMPDIR:-/tmp}/model-peer-rules.XXXXXX")"
      blk="$tmp.block"
      printf '%s\n' "$new" > "$blk"
      awk -v b="$RULES_BEGIN" -v e="$RULES_END" -v nb="$blk" '
        $0 == b && !done { inb = 1; while ((getline line < nb) > 0) print line; close(nb); done = 1; next }
        inb { if ($0 == e) inb = 0; next }
        { print }
      ' "$file" > "$tmp"
      cat "$tmp" > "$file"
      rm -f "$tmp" "$blk"
    fi
    printf 'updated'
    return
  fi

  if (( RULES_DRY_RUN == 0 )); then
    # tail -c 1 strips a trailing newline, so a non-empty result means the file
    # does not end with one and the block would otherwise run onto the last line.
    if [[ -s "$file" && -n "$(tail -c 1 "$file")" ]]; then
      printf '\n' >> "$file"
    fi
    printf '\n%s\n' "$new" >> "$file"
  fi
  printf 'appended'
}

rules_apply_link() {
  local link="$1" target="$2"
  if [[ -L "$link" ]]; then
    if [[ "$(readlink "$link")" == "$target" ]]; then
      printf 'current'
      return
    fi
    if (( RULES_FORCE == 1 )); then
      (( RULES_DRY_RUN == 1 )) || ln -sfn "$target" "$link"
      printf 'relinked'
      return
    fi
    printf 'conflict'
    return
  fi
  if [[ -e "$link" ]]; then
    printf 'regular'
    return
  fi
  if (( RULES_DRY_RUN == 0 )); then
    mkdir -p "$(dirname "$link")"
    ln -s "$target" "$link"
  fi
  printf 'linked'
}

rules_apply_command() {
  local file="$1" new
  new="$(rules_command_body)"
  if [[ ! -e "$file" ]]; then
    if (( RULES_DRY_RUN == 0 )); then
      mkdir -p "$(dirname "$file")"
      printf '%s\n' "$new" > "$file"
    fi
    printf 'created'
    return
  fi
  if [[ "$(cat "$file")" == "$new" ]]; then
    printf 'current'
    return
  fi
  if (( RULES_FORCE == 1 )); then
    (( RULES_DRY_RUN == 1 )) || printf '%s\n' "$new" > "$file"
    printf 'updated'
    return
  fi
  printf 'skipped'
}

rules_report() {
  printf '  %-9s %s\n' "$1" "$2"
}

rules_in_list() {
  local needle="$1" csv="$2" item
  local IFS=,
  for item in $csv; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

rules_validate_agents() {
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

rules_target_dir() {
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

rules_install_usage() {
  cat <<'USAGE'
Usage:
  model-peer init [options]            # same as: model-peer rules install
  model-peer rules install [options]

Writes the cross-model consultation rules into a project, so the coding agent you
work with knows when to reach for a peer. Re-running refreshes the managed block
and leaves everything around it alone.

Options:
  --split          One tailored file per CLI, each naming that CLI's two peers:
                     claude  -> .claude/rules/cross-model-consultation.md
                     codex   -> AGENTS.md
                     gemini  -> GEMINI.md
                   Default instead writes one shared AGENTS.md and symlinks
                   CLAUDE.md and GEMINI.md to it, so all three read one file.
  --agents LIST    Comma-separated: claude, codex, gemini (default: all three,
                   so a teammate on a different CLI still gets the rules)
  --no-command     Skip .claude/commands/peer-review.md (the /peer-review
                   slash command for Claude Code)
  --dir DIR        Target directory (default: the Git root, else the cwd)
  --dry-run        Report what would change; write nothing
  --force          Overwrite files Model Peer owns outright — the slash command,
                   and a CLAUDE.md/GEMINI.md symlink pointing elsewhere. Content
                   outside a managed block in a regular file is never rewritten.
  -h, --help       This help
USAGE
}

cmd_rules_install() {
  local split=0 agents='claude,codex,gemini' dir='' want_command=1 item
  RULES_DRY_RUN=0
  RULES_FORCE=0

  while (( $# > 0 )); do
    case "$1" in
      --split) split=1 ;;
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
      --dry-run) RULES_DRY_RUN=1 ;;
      --force) RULES_FORCE=1 ;;
      -h|--help) rules_install_usage; return 0 ;;
      -*) err "unknown init option: $1"; return 2 ;;
      *) err "init takes no positional arguments (got '$1')."; return 2 ;;
    esac
    shift
  done

  rules_validate_agents "$agents" || return 2

  local root
  root="$(rules_target_dir "$dir")" || return 2

  if (( RULES_DRY_RUN == 1 )); then
    printf 'Model Peer rules — dry run, nothing written\n'
  else
    printf 'Model Peer rules\n'
  fi
  printf '  target    %s\n\n' "$root"

  local status
  if (( split == 1 )); then
    if rules_in_list claude "$agents"; then
      status="$(rules_apply_block "$root/$RULES_CLAUDE_FILE" claude)"
      rules_report "$status" "$RULES_CLAUDE_FILE"
    fi
    if rules_in_list codex "$agents"; then
      status="$(rules_apply_block "$root/AGENTS.md" codex)"
      rules_report "$status" 'AGENTS.md'
    fi
    if rules_in_list gemini "$agents"; then
      status="$(rules_apply_block "$root/GEMINI.md" gemini)"
      rules_report "$status" 'GEMINI.md'
    fi
  else
    # AGENTS.md is the anchor in shared mode even when Codex is not selected:
    # it is the file the symlinks point at.
    status="$(rules_apply_block "$root/AGENTS.md" shared)"
    rules_report "$status" 'AGENTS.md'

    local name
    for name in CLAUDE.md GEMINI.md; do
      case "$name" in
        CLAUDE.md) rules_in_list claude "$agents" || continue ;;
        GEMINI.md) rules_in_list gemini "$agents" || continue ;;
      esac
      status="$(rules_apply_link "$root/$name" 'AGENTS.md')"
      case "$status" in
        regular)
          # A real file with the developer's own rules in it. Add the block
          # rather than replacing their work with a symlink.
          status="$(rules_apply_block "$root/$name" shared)"
          rules_report "$status" "$name (regular file, not linked)"
          ;;
        conflict)
          rules_report 'skipped' "$name (symlink to $(readlink "$root/$name"); --force to relink)"
          ;;
        *)
          rules_report "$status" "$name -> AGENTS.md"
          ;;
      esac
    done
  fi

  if (( want_command == 1 )) && rules_in_list claude "$agents"; then
    status="$(rules_apply_command "$root/$RULES_COMMAND_FILE")"
    case "$status" in
      skipped) rules_report 'skipped' "$RULES_COMMAND_FILE (exists; --force to overwrite)" ;;
      *)       rules_report "$status" "$RULES_COMMAND_FILE (/peer-review)" ;;
    esac
  fi

  if (( RULES_DRY_RUN == 1 )); then
    printf '\nRe-run without --dry-run to apply.\n'
    return 0
  fi

  printf '\nCommit these files so your team gets them too.\n'
  printf 'Next:  model-peer doctor        # confirm at least two CLIs are installed\n'
  printf '       model-peer review        # cross-model review of the current diff\n'
  if (( want_command == 1 )) && rules_in_list claude "$agents"; then
    printf '       /peer-review             # the same, from inside Claude Code\n'
  fi
}

cmd_rules_print() {
  local profile='shared'
  while (( $# > 0 )); do
    case "$1" in
      --profile)
        shift; (( $# > 0 )) || { err '--profile requires a value.'; return 2; }
        profile="$1"
        ;;
      --profile=*) profile="${1#--profile=}" ;;
      --command) rules_command_body; return 0 ;;
      -h|--help)
        cat <<'USAGE'
Usage:
  model-peer rules print [--profile shared|claude|codex|gemini]
  model-peer rules print --command

Writes the rules block to stdout without touching any file, so you can review it,
pipe it, or paste it into an existing rules file yourself. --command prints the
Claude Code /peer-review slash command instead.
USAGE
        return 0
        ;;
      *) err "unknown print option: $1"; return 2 ;;
    esac
    shift
  done
  case "$profile" in
    shared|claude|codex|gemini) ;;
    *) err "unknown profile '$profile'. Use shared, claude, codex, or gemini."; return 2 ;;
  esac
  rules_block "$profile"
}

# Layout-agnostic: check whatever is installed rather than assuming a layout. The
# profile is read back out of each managed block, so a --split repo and a shared
# repo both verify correctly.
cmd_rules_check() {
  local dir=''
  while (( $# > 0 )); do
    case "$1" in
      --dir)
        shift; (( $# > 0 )) || { err '--dir requires a value.'; return 2; }
        dir="$1"
        ;;
      --dir=*) dir="${1#--dir=}" ;;
      -h|--help)
        cat <<'USAGE'
Usage:
  model-peer rules check [--dir DIR]

Verifies that every Model Peer rules block in the project matches the rules this
version of Model Peer would write. Exits 0 when everything is current, 1 when a
block is missing or stale. Suitable for CI.
USAGE
        return 0
        ;;
      *) err "unknown check option: $1"; return 2 ;;
    esac
    shift
  done

  local root
  root="$(rules_target_dir "$dir")" || return 2

  local found=0 stale=0 file profile rel
  for rel in AGENTS.md CLAUDE.md GEMINI.md "$RULES_CLAUDE_FILE"; do
    file="$root/$rel"
    [[ -e "$file" ]] || continue
    # A symlink resolves to a file checked in its own right; checking it twice
    # would compare the same block against two different profiles.
    if [[ -L "$file" ]]; then
      printf '  %-9s %s -> %s\n' 'link' "$rel" "$(readlink "$file")"
      continue
    fi
    grep -Fqx "$RULES_BEGIN" "$file" || continue
    found=1
    profile="$(rules_file_profile "$file")"
    [[ -n "$profile" ]] || profile='shared'
    if [[ "$(rules_file_block "$file")" == "$(rules_block "$profile")" ]]; then
      printf '  %-9s %s (profile: %s)\n' 'current' "$rel" "$profile"
    else
      printf '  %-9s %s (profile: %s)\n' 'stale' "$rel" "$profile"
      stale=1
    fi
  done

  file="$root/$RULES_COMMAND_FILE"
  if [[ -e "$file" ]]; then
    if [[ "$(cat "$file")" == "$(rules_command_body)" ]]; then
      printf '  %-9s %s\n' 'current' "$RULES_COMMAND_FILE"
    else
      printf '  %-9s %s\n' 'stale' "$RULES_COMMAND_FILE"
      stale=1
    fi
  fi

  if (( found == 0 )); then
    err 'no Model Peer rules found in this project. Run: model-peer init'
    return 1
  fi
  if (( stale == 1 )); then
    err 'rules are out of date. Run: model-peer init'
    return 1
  fi
  return 0
}

cmd_rules() {
  case "${1:-}" in
    install) shift; cmd_rules_install "$@" ;;
    print)   shift; cmd_rules_print "$@" ;;
    check)   shift; cmd_rules_check "$@" ;;
    -h|--help|'')
      cat <<'USAGE'
Usage:
  model-peer rules install [options]   Write the rules into this project
  model-peer rules print [--profile P] Print the rules block to stdout
  model-peer rules check [--dir DIR]   Verify the installed rules are current

`model-peer init` is a shorthand for `model-peer rules install`.
Run any subcommand with --help for its options.
USAGE
      ;;
    *) err "unknown rules subcommand '$1'. Use install, print, or check."; return 2 ;;
  esac
}

# Reports whether the project the developer is standing in has rules installed.
# Missing rules are the single most common reason consultation never happens.
doctor_repo_rules() {
  local root rel file found=0
  root="$(rules_target_dir '')" || return 0
  for rel in AGENTS.md CLAUDE.md GEMINI.md "$RULES_CLAUDE_FILE"; do
    file="$root/$rel"
    [[ -f "$file" ]] || continue
    grep -Fqx "$RULES_BEGIN" "$file" >/dev/null 2>&1 || continue
    if (( found == 0 )); then
      printf '\nProject rules in %s\n' "$root"
      found=1
    fi
    printf '  %s\n' "$rel"
  done
  if (( found == 0 )); then
    printf '\nProject rules: none in %s (run: model-peer init)\n' "$root"
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

  doctor_repo_rules

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
      cmd_rules_install "$@"
      ;;
    rules)
      shift
      cmd_rules "$@"
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
