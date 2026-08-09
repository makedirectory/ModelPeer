#!/usr/bin/env bash
set -euo pipefail

VERSION="0.1.0"
BIN_DIR="${MODEL_PEER_BIN_DIR:-$HOME/.local/bin}"
DO_SETUP=0
INSTALL_DEPS=0
DO_LOGIN=0

usage() {
  cat <<'USAGE'
Model Peer installer v0.1.0

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

VERSION="0.1.0"
PROGRAM="model-peer"

usage() {
  cat <<'USAGE'
Model Peer v0.1.0 — cross-model peer review for coding agents.

Usage:
  model-peer ask claude "<focused question>"
  model-peer ask codex "<focused question>"
  model-peer ask gemini "<focused question>"
  command | model-peer ask <claude|codex|gemini>

  model-peer review [options] ["focus instructions"]
  model-peer doctor
  model-peer --version

Ask options:
  --depth N              Max peer-chain length, 1-10 (default: 1)

Review options:
  --models LIST          Comma-separated reviewers (default: all installed)
  --synthesizer MODEL    claude, codex, or gemini (default: first available in
                         claude,codex,gemini order)
  --depth N              Max peer-chain length for each reviewer, 1-10 (default: 1)

Peer-chain depth:
  Depth 1 (default) means a peer answers on its own and may not consult anyone.
  Depth N lets a chain grow to N models: claude -> codex -> gemini is depth 3.
  Raising depth above 1 also grants peers the minimal tool needed to call out
  (shell access), so it is a deliberate widening of the read-only sandbox.
  A model can never be consulted by itself, at any depth.

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

err() { printf 'model-peer: %s\n' "$*" >&2; }

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
  local delegation

  if (( remaining > 0 )); then
    delegation="You may consult one further peer with \`model-peer ask <model> \"<question>\"\` if a
genuinely independent perspective would change your answer. $remaining more level(s) are
permitted. Prefer answering directly: every hop costs time and dilutes accountability.
If you do consult a peer, say which model you asked and what you took from it."
  else
    delegation="Do not invoke Claude Code, Codex CLI, Gemini CLI, Model Peer, or any other model.
Do not delegate the decision back to another agent."
  fi

  cat <<PROMPT
You are being consulted as an independent engineering peer through Model Peer.
Answer the user's focused question. Inspect the current workspace read-only when useful.
Do not modify files.

$delegation

Your advice is advisory. Project-specific rules and invariants take precedence.
Reason independently, distinguish evidence from assumptions, and call out uncertainty.

Consulted model: $provider
Remaining peer-chain depth: $remaining

User question:
$prompt
PROMPT
}

run_claude() {
  local prompt="$1" stack="$2" remaining="$3" max_depth="$4"
  provider_installed claude || {
    err "'claude' was not found on PATH."
    err 'Install Claude Code: https://code.claude.com/docs/en/setup'
    return 127
  }

  local bridge_prompt tools
  bridge_prompt="$(consultation_prompt Claude "$prompt" "$remaining")"

  # Read-only inspection only. Bash is added solely so a peer can reach
  # model-peer when the chain is allowed to grow, and is auto-approved for
  # nothing else.
  tools='Read,Glob,Grep'
  local -a nested_args=()
  if (( remaining > 0 )); then
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
  local prompt="$1" stack="$2" remaining="$3" max_depth="$4"
  provider_installed codex || {
    err "'codex' was not found on PATH."
    err 'Install Codex CLI: https://developers.openai.com/codex/cli'
    return 127
  }

  local bridge_prompt
  bridge_prompt="$(consultation_prompt Codex "$prompt" "$remaining")"

  MODEL_PEER_STACK="$stack" MODEL_PEER_MAX_DEPTH="$max_depth" \
    codex exec \
      --sandbox read-only \
      --ephemeral \
      --skip-git-repo-check \
      "$bridge_prompt" \
      </dev/null
}

run_gemini() {
  local prompt="$1" stack="$2" remaining="$3" max_depth="$4"
  provider_installed gemini || {
    err "'gemini' was not found on PATH."
    err 'Install Gemini CLI: https://google-gemini.github.io/gemini-cli/docs/get-started/'
    return 127
  }

  local bridge_prompt tmpdir policy status
  bridge_prompt="$(consultation_prompt Gemini "$prompt" "$remaining")"
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
toolName = "exit_plan_mode"
decision = "deny"
priority = 999

[[rule]]
toolName = "enter_plan_mode"
decision = "deny"
priority = 999
POLICY

  # Shell stays denied unless the chain is allowed to grow, because reaching
  # model-peer is the only way a Gemini peer can consult anyone.
  if (( remaining <= 0 )); then
    cat >> "$policy" <<'POLICY'

[[rule]]
toolName = "run_shell_command"
decision = "deny"
priority = 999
POLICY
  fi

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

  local stack remaining
  stack="$(push_stack "$provider")"
  remaining=$(( max_depth - $(stack_depth) - 1 ))

  case "$provider" in
    claude) run_claude "$prompt" "$stack" "$remaining" "$max_depth" ;;
    codex)  run_codex  "$prompt" "$stack" "$remaining" "$max_depth" ;;
    gemini) run_gemini "$prompt" "$stack" "$remaining" "$max_depth" ;;
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
              answers alone. Above 1, the peer may consult a further model and
              is granted shell access to do so. Use -- to end options when the
              prompt itself starts with a dash.
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

  local effective_depth
  if effective_depth="$(resolve_max_depth '' 2>/dev/null)"; then
    printf '\nPeer-chain depth limit: %s (max %s)\n' "$effective_depth" "$DEPTH_CEILING"
  else
    printf '\nPeer-chain depth limit: invalid MODEL_PEER_MAX_DEPTH=%s\n' "${MODEL_PEER_MAX_DEPTH:-}"
  fi
  if [[ -n "${MODEL_PEER_STACK:-}" ]]; then
    printf 'Active peer chain:      %s (depth %s)\n' "$MODEL_PEER_STACK" "$(stack_depth)"
  fi
  if (( effective_depth > 1 )) 2>/dev/null; then
    printf 'Note: depth > 1 grants peers shell access so they can call out.\n'
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
