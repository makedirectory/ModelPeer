#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/model-peer-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/repo"
export HOME="$TMP/home"
export PATH="$TMP/bin:$ROOT/bin:$PATH"
export MODEL_PEER_BIN_DIR="$TMP/install-bin"
LOG="$TMP/calls.log"
export MODEL_PEER_TEST_LOG="$LOG"
export MP_TEST_LIB="$TMP/bin/stub-lib.sh"

# Shared stub behaviour. Reviewers run concurrently, so several stubs append to
# the call log at once — and a review prompt is larger than a single write(), so
# two records interleaved mid-prompt would break every assertion that greps for a
# contiguous string. mkdir is atomic and serves as the lock; the spin is bounded
# so a stub killed by one of the timeout tests can never wedge the others.
cat > "$MP_TEST_LIB" <<'LIB'
mp_stub_append_file() {
  local dest="$1" src="$2" i=0
  while (( i < 200 )); do
    if mkdir "$dest.lock" 2>/dev/null; then
      cat "$src" >> "$dest"
      rmdir "$dest.lock" 2>/dev/null || true
      return 0
    fi
    sleep 0.05
    i=$(( i + 1 ))
  done
  cat "$src" >> "$dest"
}

# One record per invocation: argv, the generated Gemini policy when one was passed
# (model-peer deletes it as soon as the stub exits), and whether stdin was closed.
mp_stub_log() {
  local name="$1" tmp prev='' a x=''
  shift
  tmp="$(mktemp "${TMPDIR:-/tmp}/mp-stub.XXXXXX")"
  {
    printf '%s ARGS:' "$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
    printf ' <%s>' "$@"
    for a in "$@"; do
      if [[ "$prev" == '--policy' && -f "$a" ]]; then
        printf '\nGEMINI POLICY BEGIN\n'
        cat "$a"
        printf '\nGEMINI POLICY END\n'
      fi
      prev="$a"
    done
    if [[ -t 0 ]]; then
      printf ' STDIN=TTY\n'
    elif IFS= read -r -t 1 x; then
      printf ' STDIN=%s\n' "$x"
    else
      printf ' STDIN=EOF\n'
    fi
  } > "$tmp"
  mp_stub_append_file "$MODEL_PEER_TEST_LOG" "$tmp"
  rm -f "$tmp"
}

# The concurrency barrier: each reviewer records that it started, then blocks
# until every requested reviewer has done the same. Serial orchestration can never
# open it, which makes this a structural proof of fan-out rather than a
# wall-clock guess. Inert unless MP_TEST_BARRIER_DIR is set.
mp_stub_barrier() {
  local name="$1" dir="${MP_TEST_BARRIER_DIR:-}" waited=0 seen wanted m
  [[ -n "$dir" ]] || return 0
  : > "$dir/started-$name"
  wanted=0
  for m in ${MP_TEST_BARRIER_MODELS:-}; do wanted=$(( wanted + 1 )); done
  while (( waited < 200 )); do
    seen=0
    for m in ${MP_TEST_BARRIER_MODELS:-}; do
      if [[ -e "$dir/started-$m" ]]; then seen=$(( seen + 1 )); fi
    done
    if (( seen >= wanted )); then return 0; fi
    sleep 0.1
    waited=$(( waited + 1 ))
  done
  printf 'barrier never opened for %s\n' "$name" >&2
  return 1
}
LIB

cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "$MP_TEST_LIB"
if [[ "${1:-}" == auth && "${2:-}" == status ]]; then exit 0; fi
if [[ "${1:-}" == --version ]]; then printf '9.9.9\n'; exit 0; fi
mp_stub_log claude "$@"
mp_stub_barrier claude
printf 'claude review output\n'
EOF

cat > "$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "$MP_TEST_LIB"
if [[ "${1:-}" == login && "${2:-}" == status ]]; then exit 0; fi
if [[ "${1:-}" == --version ]]; then printf '9.9.9\n'; exit 0; fi
mp_stub_log codex "$@"
mp_stub_barrier codex
printf 'codex review output\n'
EOF

cat > "$TMP/bin/gemini" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "$MP_TEST_LIB"
# model-peer feature-detects --skip-trust from --help before invoking Gemini.
# Answer that without logging, so the probe does not pollute call assertions.
if [[ "$*" == *--help* ]]; then
  printf '      --skip-trust                Trust the current workspace for this session.\n'
  exit 0
fi
if [[ "${1:-}" == --version ]]; then printf '9.9.9\n'; exit 0; fi
mp_stub_log gemini "$@"
mp_stub_barrier gemini
printf 'gemini review output\n'
EOF
chmod +x "$TMP/bin/claude" "$TMP/bin/codex" "$TMP/bin/gemini"

# Basic CLI/version.
[[ "$(model-peer --version)" == 'model-peer 0.5.1' ]]

# Ask dispatch + safety args + stdin closure.
printf 'sentinel\n' | model-peer ask codex 'review this' >/dev/null
model-peer ask claude 'review this' >/dev/null
model-peer ask gemini 'review this' >/dev/null

grep -Fq '<--sandbox> <read-only>' "$LOG"
grep -Fq '<--ephemeral>' "$LOG"
grep -Fq '<--permission-mode> <plan>' "$LOG"
grep -Fq '<--tools> <Read,Glob,Grep>' "$LOG"
grep -Fq '<--approval-mode> <plan>' "$LOG"
grep -Fq '<--policy>' "$LOG"
grep -Fq '<-e> <none>' "$LOG"
[[ "$(grep -c 'STDIN=EOF' "$LOG")" -ge 3 ]]

# Self-consultation guard: a model may never be consulted by itself, at any depth.
for m in claude codex gemini; do
  if MODEL_PEER_STACK="$m" model-peer ask "$m" 'loop' >/dev/null 2>&1; then
    echo "expected recursive $m call to fail" >&2; exit 1
  else
    [[ $? -eq 64 ]]
  fi
  if MODEL_PEER_STACK="$m" model-peer ask "$m" --depth 10 'loop' >/dev/null 2>&1; then
    echo "expected recursive $m call to fail even at depth 10" >&2; exit 1
  else
    [[ $? -eq 64 ]]
  fi
done

# Cycle detection across the WHOLE chain, not just its tail. Blocking only
# claude -> claude while permitting claude -> codex -> claude still lets a model
# review its own work one hop removed.
for m in claude codex gemini; do
  if MODEL_PEER_STACK="codex:gemini:claude" model-peer ask "$m" --depth 5 'cycle' >/dev/null 2>&1; then
    echo "expected $m to be blocked as already present in the chain" >&2; exit 1
  else
    [[ $? -eq 64 ]]
  fi
done
if MODEL_PEER_STACK='claude:codex' model-peer ask claude --depth 3 'loop' >/dev/null 2>&1; then
  echo 'expected claude -> codex -> claude to be blocked' >&2; exit 1
else
  [[ $? -eq 64 ]]
fi
# A model not yet in the chain is still allowed.
MODEL_PEER_STACK='claude:codex' model-peer ask gemini --depth 3 'fresh' >/dev/null

# A peer cannot raise the ceiling it inherited. Inside a chain the inherited
# limit is a cap, not a default, otherwise any peer could buy itself more hops.
: > "$LOG"
MODEL_PEER_MAX_DEPTH=2 MODEL_PEER_STACK='claude' \
  model-peer ask codex --depth 10 'escalate' >/dev/null 2>"$TMP/clamp.err"
grep -Fq 'exceeds the inherited limit' "$TMP/clamp.err"
# Clamped to 2, so the peer is told it has no budget left rather than 8 levels.
grep -Fq 'Remaining peer-chain depth: 0' "$LOG"
# Lowering below the inherited limit is still allowed.
MODEL_PEER_MAX_DEPTH=5 MODEL_PEER_STACK='claude' model-peer ask codex --depth 2 'lower' >/dev/null

# Depth guard: default depth 1 permits one hop and no more.
model-peer ask codex 'top level' >/dev/null
if MODEL_PEER_STACK='claude' model-peer ask codex 'second hop' >/dev/null 2>&1; then
  echo 'expected depth-1 chain to block a second hop' >&2; exit 1
else
  [[ $? -eq 64 ]]
fi

# --depth raises the ceiling; the chain is carried in MODEL_PEER_STACK.
MODEL_PEER_STACK='claude' model-peer ask codex --depth 2 'second hop' >/dev/null
MODEL_PEER_STACK='claude' model-peer ask codex --depth=2 'second hop' >/dev/null
MODEL_PEER_MAX_DEPTH=2 MODEL_PEER_STACK='claude' model-peer ask codex 'env depth' >/dev/null
if MODEL_PEER_STACK='claude:codex' model-peer ask gemini --depth 2 'third hop' >/dev/null 2>&1; then
  echo 'expected depth-2 chain to block a third hop' >&2; exit 1
else
  [[ $? -eq 64 ]]
fi
MODEL_PEER_STACK='claude:codex' model-peer ask gemini --depth 3 'third hop' >/dev/null

# Depth values outside 1-10 and non-numeric values are rejected.
for bad in 0 11 abc -1; do
  if model-peer ask codex --depth "$bad" 'x' >/dev/null 2>&1; then
    echo "expected --depth $bad to be rejected" >&2; exit 1
  else
    [[ $? -eq 2 ]]
  fi
done

# Depth 1 keeps Claude tool-restricted; delegation scopes execution to the
# model-peer command namespace rather than granting a general shell.
: > "$LOG"
model-peer ask claude 'leaf' >/dev/null
grep -Fq '<--tools> <Read,Glob,Grep>' "$LOG"
if grep -Fq 'allowedTools' "$LOG"; then
  echo 'expected no --allowedTools grant at depth 1' >&2; exit 1
fi
: > "$LOG"
model-peer ask claude --depth 2 'may delegate' >/dev/null
grep -Fq '<--tools> <Read,Glob,Grep,Bash>' "$LOG"
# The grant must name the crippled entry point, not `model-peer` wholesale:
# `model-peer init`/`update` write files, so a broad grant would let a peer
# rewrite the workspace's skills.
grep -Fq '<--allowedTools> <Bash(model-peer _delegate:*)>' "$LOG"
if grep -Fq '<Bash(model-peer:*)>' "$LOG"; then
  echo 'expected no unrestricted model-peer grant' >&2; exit 1
fi
# The prompt must authorize exactly the command the sandbox permits.
grep -Fq 'model-peer _delegate <model>' "$LOG"

# The delegate entry point is deliberately incapable of anything else.
for bad in 'init' 'update' 'review' 'trust' 'doctor'; do
  if model-peer _delegate "$bad" >/dev/null 2>&1; then
    echo "expected _delegate to reject '$bad' as a provider" >&2; exit 1
  else
    [[ $? -eq 2 ]]
  fi
done
if model-peer _delegate codex --depth 9 'x' >/dev/null 2>&1; then
  echo 'expected _delegate to reject options' >&2; exit 1
else
  [[ $? -eq 2 ]]
fi
model-peer _delegate codex 'a real question' >/dev/null

# Core invariant: depth is a limit, not a permission. Gemini's sandbox cannot
# scope execution to model-peer alone, so run_shell_command stays denied at every
# depth and Gemini is always a leaf.
for d in 1 2 10; do
  : > "$LOG"
  model-peer ask gemini --depth "$d" "depth $d" >/dev/null 2>"$TMP/gemini.err"
  # The deny rule is present in the generated policy at every depth.
  grep -Fq 'GEMINI POLICY BEGIN' "$LOG"
  awk '/GEMINI POLICY BEGIN/,/GEMINI POLICY END/' "$LOG" | grep -Fq 'run_shell_command'
  awk '/GEMINI POLICY BEGIN/,/GEMINI POLICY END/' "$LOG" | grep -Fq 'exit_plan_mode'
  # And Gemini always receives leaf instructions.
  grep -Fq 'Do not invoke Claude Code' "$LOG"
  grep -Fq 'Remaining peer-chain depth: 0' "$LOG"
done
# The downgrade is reported, not silent.
grep -Fq 'cannot initiate nested consultation' "$TMP/gemini.err"

# Codex delegation adds no CLI capability; only the prompt changes.
: > "$LOG"
model-peer ask codex 'leaf' >/dev/null
codex_leaf_args="$(grep -c '<--sandbox> <read-only>' "$LOG")"
: > "$LOG"
model-peer ask codex --depth 2 'may delegate' >/dev/null
[[ "$(grep -c '<--sandbox> <read-only>' "$LOG")" -eq "$codex_leaf_args" ]]
grep -Fq 'You may consult one further peer' "$LOG"

# The depth limit propagates to the peer so a nested call inherits the ceiling.
: > "$LOG"
model-peer ask codex --depth 3 'propagate' >/dev/null
grep -Fq 'Remaining peer-chain depth: 2' "$LOG"
: > "$LOG"
model-peer ask codex 'no delegation' >/dev/null
grep -Fq 'Remaining peer-chain depth: 0' "$LOG"
grep -Fq 'Do not invoke Claude Code' "$LOG"

# Compatibility aliases.
ask-claude 'alias' >/dev/null
ask-codex 'alias' >/dev/null
ask-gemini 'alias' >/dev/null

# Review flow in a stub git repo.
cd "$TMP/repo"
git init -q
git config user.email test@example.com
git config user.name Test
printf 'one\n' > demo.txt
git add demo.txt
git commit -qm init
printf 'two\n' >> demo.txt
model-peer review --models claude,codex,gemini --synthesizer claude 'focus test' >/dev/null
ai-review --models claude,codex --synthesizer codex 'compat review' >/dev/null

# Reviewers and the synthesizer are ALWAYS leaves. Three reviewers that can
# consult each other are not three independent observations, so this is not
# configurable: --depth is refused outright rather than silently ignored.
: > "$LOG"
model-peer review --models claude,codex --synthesizer codex 'leaves' >/dev/null
if grep -Fq 'Remaining peer-chain depth: 1' "$LOG"; then
  echo 'expected every reviewer to be a leaf' >&2; exit 1
fi
# One leaf prompt per reviewer plus one for synthesis.
[[ "$(grep -c 'Remaining peer-chain depth: 0' "$LOG")" -eq 3 ]]
for d in 2 10; do
  if model-peer review --models claude,codex --depth "$d" 'chain' >/dev/null 2>&1; then
    echo "expected review --depth $d to be rejected" >&2; exit 1
  else
    [[ $? -eq 2 ]]
  fi
done
if model-peer review --models claude,codex --depth=2 'chain' >/dev/null 2>&1; then
  echo 'expected review --depth=2 to be rejected' >&2; exit 1
else
  [[ $? -eq 2 ]]
fi

# A model may not appear twice in one panel — the same rule the chain guard applies
# within a chain. Two copies of one model are one opinion counted twice, and both
# would own the same reviewer output file: serially the second overwrote the first,
# in parallel they race, and either way the panel reports itself complete.
for dup in 'gemini,gemini' 'claude,codex,claude'; do
  if model-peer review --models "$dup" --synthesizer claude 'dupes' >/dev/null 2>"$TMP/dupe.err"; then
    echo "expected --models $dup to be rejected" >&2; exit 1
  else
    [[ $? -eq 2 ]]
  fi
  grep -Fq 'listed more than once' "$TMP/dupe.err"
done

# A review launched from inside a peer chain stays under the depth guard.
if MODEL_PEER_STACK='claude:codex' model-peer review --models claude,codex 'nested' >/dev/null 2>&1; then
  echo 'expected nested review to be blocked by the depth guard' >&2; exit 1
fi

# Gemini's folder-trust gate makes a headless run a silent no-op in an untrusted
# directory, so the workspace is trusted for the session. The stub advertises the
# flag in --help, which is how model-peer feature-detects it.
: > "$LOG"
model-peer ask gemini 'trust' >/dev/null
grep -Fq '<--skip-trust>' "$LOG"

# Timeouts. A hung peer must be bounded, must not leave orphans holding the pipe
# open, and must exit 124.
cat > "$TMP/bin/hang" <<'EOF'
#!/usr/bin/env bash
sleep 120
EOF
chmod +x "$TMP/bin/hang"
cat > "$TMP/bin/codex-hang" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == login && "${2:-}" == status ]]; then exit 0; fi
hang
EOF
chmod +x "$TMP/bin/codex-hang"

HANG_START="$(date +%s)"
cp "$TMP/bin/codex" "$TMP/bin/codex.real"
cp "$TMP/bin/codex-hang" "$TMP/bin/codex"
if model-peer ask codex --timeout 3 'this will hang' >/dev/null 2>"$TMP/hang.err"; then
  echo 'expected a hung peer to fail' >&2; exit 1
else
  [[ $? -eq 124 ]]
fi
HANG_ELAPSED=$(( $(date +%s) - HANG_START ))
# Bounded near the limit rather than running to the stub's 120s sleep.
(( HANG_ELAPSED < 30 )) || { echo "timeout did not bound the run ($HANG_ELAPSED s)" >&2; exit 1; }
grep -Fq 'exceeded the 3s timeout' "$TMP/hang.err"
# The whole process group is signalled, so no grandchild survives holding stdout.
if pgrep -f 'sleep 120' >/dev/null 2>&1; then
  echo 'timeout left an orphaned grandchild behind' >&2; exit 1
fi

# --timeout 0 disables the limit, and a bad value is a usage error.
cp "$TMP/bin/codex.real" "$TMP/bin/codex"
model-peer ask codex --timeout 0 'no limit' >/dev/null
model-peer ask codex --timeout=30 'explicit' >/dev/null
MODEL_PEER_TIMEOUT=45 model-peer ask codex 'env timeout' >/dev/null
for bad in abc -1 1.5; do
  if model-peer ask codex --timeout "$bad" 'x' >/dev/null 2>&1; then
    echo "expected --timeout $bad to be rejected" >&2; exit 1
  else
    [[ $? -eq 2 ]]
  fi
done

cd "$TMP/repo"

# Synthesis is bounded like every other consultation. A hung synthesizer would
# otherwise hang the run forever, after every reviewer had already succeeded.
cp "$TMP/bin/claude" "$TMP/bin/claude.real"
cat > "$TMP/bin/claude.hang" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == auth && "${2:-}" == status ]]; then exit 0; fi
hang
EOF
chmod +x "$TMP/bin/claude.hang"
SYNTH_START="$(date +%s)"
cp "$TMP/bin/claude.hang" "$TMP/bin/claude"
if model-peer review --models codex,gemini --synthesizer claude --timeout 3 \
    'bounded synthesis' >/dev/null 2>"$TMP/synth.err"; then
  echo 'expected a hung synthesizer to fail rather than hang' >&2; exit 1
else
  [[ $? -eq 124 ]]
fi
SYNTH_ELAPSED=$(( $(date +%s) - SYNTH_START ))
(( SYNTH_ELAPSED < 40 )) || { echo "synthesis was not bounded ($SYNTH_ELAPSED s)" >&2; exit 1; }
grep -Fq 'exceeded the 3s timeout' "$TMP/synth.err"
cp "$TMP/bin/claude.real" "$TMP/bin/claude"

# A reviewer that hangs is dropped, and synthesis still runs on the survivors.
cp "$TMP/bin/codex-hang" "$TMP/bin/codex"
model-peer review --models claude,codex,gemini --synthesizer claude --timeout 3 \
  'partial panel' >/dev/null 2>"$TMP/partial.err"
grep -Fq 'dropping it from the panel' "$TMP/partial.err"
grep -Fq 'synthesizing from 2 of 3 reviewers' "$TMP/partial.err"

# --strict restores refuse-on-any-failure.
if model-peer review --models claude,codex,gemini --synthesizer claude --timeout 3 \
    --strict 'strict panel' >/dev/null 2>&1; then
  echo 'expected --strict to refuse an incomplete panel' >&2; exit 1
else
  [[ $? -eq 1 ]]
fi

# Fewer than two survivors is not a cross-model review, so it is refused.
if model-peer review --models codex,gemini --synthesizer claude --timeout 3 \
    'one survivor' >/dev/null 2>"$TMP/onesurvivor.err"; then
  echo 'expected a one-reviewer panel to be refused' >&2; exit 1
else
  [[ $? -eq 1 ]]
fi
grep -Fq 'refusing to synthesize a panel of fewer than two' "$TMP/onesurvivor.err"
cp "$TMP/bin/codex.real" "$TMP/bin/codex"

# A reviewer that exits 0 with no output has not reviewed anything; an empty file
# must not reach the synthesizer as "this model found no issues".
cat > "$TMP/bin/gemini.silent" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *--help* ]]; then printf '      --skip-trust  Trust the workspace\n'; exit 0; fi
exit 0
EOF
chmod +x "$TMP/bin/gemini.silent"
cp "$TMP/bin/gemini" "$TMP/bin/gemini.real"
cp "$TMP/bin/gemini.silent" "$TMP/bin/gemini"
model-peer review --models claude,codex,gemini --synthesizer claude \
  'silent reviewer' >/dev/null 2>"$TMP/silent.err"
grep -Fq 'produced no output; dropping it from the panel' "$TMP/silent.err"
cp "$TMP/bin/gemini.real" "$TMP/bin/gemini"

# The synthesizer is told which reviewers are missing, so a partial panel cannot
# be reported as a complete one.
: > "$LOG"
cp "$TMP/bin/codex-hang" "$TMP/bin/codex"
model-peer review --models claude,codex,gemini --synthesizer claude --timeout 3 \
  'coverage note' >/dev/null 2>&1
grep -Fq 'Panel coverage:' "$LOG"
grep -Fq 'did NOT complete and contributed nothing' "$LOG"
grep -Fq 'not evidence of safety' "$LOG"
cp "$TMP/bin/codex.real" "$TMP/bin/codex"

# A complete panel says so, and says nothing about gaps.
: > "$LOG"
model-peer review --models claude,codex --synthesizer claude 'full panel' >/dev/null 2>&1
grep -Fq 'Every reviewer in the panel completed.' "$LOG"

# Untracked files must reach reviewers. `git diff HEAD` cannot see them, and
# `git status --short` collapses a whole new directory to one "?? src/" line, so
# a new package would otherwise be reviewed as a path with no contents.
mkdir -p "$TMP/repo/src/newpkg"
printf 'def handler(x):\n    return eval(x)\n' > "$TMP/repo/src/newpkg/handler.py"
printf '\x00\x01binary\x00' > "$TMP/repo/src/newpkg/blob.bin"
printf 'ignored\n' > "$TMP/repo/skipme.log"
printf '*.log\n' > "$TMP/repo/.gitignore"
: > "$LOG"
model-peer review --models claude,codex --synthesizer claude 'untracked' >/dev/null 2>&1
grep -Fq 'includes_untracked="true"' "$LOG"
grep -Fq 'src/newpkg/handler.py' "$LOG"
grep -Fq 'return eval(x)' "$LOG"
# Binaries are summarized, not dumped into the prompt.
grep -Fq 'Binary files /dev/null and b/src/newpkg/blob.bin differ' "$LOG"
# Ignored files stay out.
if grep -Fq 'skipme.log' "$LOG"; then
  echo 'expected gitignored files to stay out of the review context' >&2; exit 1
fi
rm -rf "$TMP/repo/src" "$TMP/repo/skipme.log" "$TMP/repo/.gitignore"

# ---------------------------------------------------------------------------
# Parallel reviewers. Independent reviewers are scheduled independently: every
# requested reviewer starts before the parent waits for any of them.
# ---------------------------------------------------------------------------

# The concurrency barrier is the primary proof, and far less flaky than asserting
# elapsed time on a shared CI runner. Each stub records that it started and blocks
# until all three have; under serial orchestration the first reviewer can never
# observe the others, so it fails and the panel collapses.
BARRIER="$TMP/barrier"
mkdir -p "$BARRIER"
MP_TEST_BARRIER_DIR="$BARRIER" MP_TEST_BARRIER_MODELS='claude codex gemini' \
  model-peer review --models claude,codex,gemini --synthesizer claude --timeout 60 \
  'concurrency barrier' >/dev/null 2>"$TMP/barrier.err"
for m in claude codex gemini; do
  [[ -e "$BARRIER/started-$m" ]] || { echo "expected $m to have started" >&2; exit 1; }
done
grep -Fq 'Starting Claude independent review...' "$TMP/barrier.err"
grep -Fq 'Starting Gemini independent review...' "$TMP/barrier.err"
for label in Claude Codex Gemini; do
  grep -Fq "$label completed." "$TMP/barrier.err"
done
rm -rf "$BARRIER"

# Reviewer output must never interleave on stdout, and the replay must follow the
# requested model list rather than completion order. These stubs finish in exactly
# the reverse of the requested order and emit their reviews line by line.
mk_chatty_stub() {
  local m="$1" delay="$2" tag
  tag="$(printf '%s' "$m" | tr '[:lower:]' '[:upper:]')"
  cat > "$TMP/bin/$m" <<STUB
#!/usr/bin/env bash
set -euo pipefail
if [[ "\$*" == *--help* ]]; then printf '      --skip-trust  Trust the workspace\n'; exit 0; fi
if [[ "\$*" == *'synthesis editor'* ]]; then printf 'SYNTHESIS\n'; exit 0; fi
sleep $delay
printf '$tag-A\n'
sleep 0.3
printf '$tag-B\n'
sleep 0.3
printf '$tag-C\n'
STUB
  chmod +x "$TMP/bin/$m"
}
mk_chatty_stub claude 2
mk_chatty_stub codex 1
mk_chatty_stub gemini 0
model-peer review --models claude,codex,gemini --synthesizer claude \
  'replay order' > "$TMP/replay.out" 2>/dev/null
for tag in CLAUDE CODEX GEMINI; do
  printf '%s-A\n%s-B\n%s-C\n' "$tag" "$tag" "$tag" > "$TMP/expect-block.txt"
  grep -A2 "^$tag-A\$" "$TMP/replay.out" | cmp -s - "$TMP/expect-block.txt" \
    || { echo "expected $tag output to replay as one contiguous block" >&2; exit 1; }
done
# Gemini finished first and Claude last, but replay follows the requested order.
replay_line() { grep -n "^$1\$" "$TMP/replay.out" | head -1 | cut -d: -f1; }
[[ "$(replay_line CLAUDE-A)" -lt "$(replay_line CODEX-A)" ]] \
  || { echo 'expected replay in requested order, not completion order' >&2; exit 1; }
[[ "$(replay_line CODEX-A)" -lt "$(replay_line GEMINI-A)" ]] \
  || { echo 'expected replay in requested order, not completion order' >&2; exit 1; }

# Secondary evidence only: three reviewers that each take 4s must not cost 12s.
# The threshold is deliberately generous so a loaded runner does not fail it.
for m in claude codex gemini; do
  cat > "$TMP/bin/$m" <<STUB
#!/usr/bin/env bash
set -euo pipefail
if [[ "\$*" == *--help* ]]; then printf '      --skip-trust  Trust the workspace\n'; exit 0; fi
if [[ "\$*" == *'synthesis editor'* ]]; then printf 'synthesis\n'; exit 0; fi
sleep 5
printf '$m review\n'
STUB
  chmod +x "$TMP/bin/$m"
done
OVERLAP_START="$(date +%s)"
model-peer review --models claude,codex,gemini --synthesizer claude 'overlap' >/dev/null 2>&1
OVERLAP_ELAPSED=$(( $(date +%s) - OVERLAP_START ))
(( OVERLAP_ELAPSED < 12 )) \
  || { echo "reviewers did not overlap (${OVERLAP_ELAPSED}s for three 5s reviewers)" >&2; exit 1; }

# Synthesis must not start until every requested reviewer has reached a terminal
# state, even though one of them finishes long before the other.
MARKERS="$TMP/markers.txt"
: > "$MARKERS"
for m in codex gemini; do
  case "$m" in codex) delay=3 ;; *) delay=1 ;; esac
  cat > "$TMP/bin/$m" <<STUB
#!/usr/bin/env bash
set -euo pipefail
if [[ "\$*" == *--help* ]]; then printf '      --skip-trust  Trust the workspace\n'; exit 0; fi
printf '$m-start\n' >> "\$MP_TEST_MARKERS"
sleep $delay
printf '$m-end\n' >> "\$MP_TEST_MARKERS"
printf '$m review\n'
STUB
  chmod +x "$TMP/bin/$m"
done
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'synthesis-start\n' >> "$MP_TEST_MARKERS"
printf 'final report\n'
STUB
chmod +x "$TMP/bin/claude"
MP_TEST_MARKERS="$MARKERS" model-peer review --models codex,gemini --synthesizer claude \
  'synthesis ordering' >/dev/null 2>&1
marker_line() { grep -n "^$1\$" "$MARKERS" | head -1 | cut -d: -f1; }
for m in codex gemini; do
  [[ "$(marker_line "$m-end")" -lt "$(marker_line synthesis-start)" ]] \
    || { echo "expected synthesis to start only after $m finished" >&2; exit 1; }
done

# A reviewer that emits a partial answer and then hangs has reviewed nothing. Its
# half-written finding must reach neither stdout nor the synthesizer: a truncated
# finding read as a complete one is worse than no finding at all.
cp "$TMP/bin/claude.real" "$TMP/bin/claude"
cp "$TMP/bin/gemini.real" "$TMP/bin/gemini"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == login && "${2:-}" == status ]]; then exit 0; fi
printf 'CODEX-PARTIAL-FINDING\n'
sleep 111
STUB
chmod +x "$TMP/bin/codex"
: > "$LOG"
model-peer review --models claude,codex,gemini --synthesizer claude --timeout 3 \
  'partial output' > "$TMP/partial-out.txt" 2>/dev/null
if grep -Fq 'CODEX-PARTIAL-FINDING' "$TMP/partial-out.txt"; then
  echo 'expected a dropped reviewer partial answer to stay off stdout' >&2; exit 1
fi
if grep -Fq 'CODEX-PARTIAL-FINDING' "$LOG"; then
  echo 'expected a dropped reviewer partial answer to stay out of synthesis' >&2; exit 1
fi
grep -Fq 'timed out after 3s and was dropped from the panel' "$LOG"

# --strict refuses to synthesize, but the reviews that did complete are still
# replayed: hiding finished work because a sibling failed helps nobody.
if model-peer review --models claude,codex,gemini --synthesizer claude --timeout 3 \
    --strict 'strict replay' > "$TMP/strict-out.txt" 2>/dev/null; then
  echo 'expected --strict to refuse an incomplete panel' >&2; exit 1
else
  [[ $? -eq 1 ]]
fi
grep -Fq 'claude review output' "$TMP/strict-out.txt"
grep -Fq 'gemini review output' "$TMP/strict-out.txt"
cp "$TMP/bin/codex.real" "$TMP/bin/codex"

# Ctrl-C during a parallel review must take down every worker and every vendor
# process tree beneath them. Parallelizing widens that tree, which is why this
# matters more here than it did serially.
cat > "$TMP/bin/blocker" <<'STUB'
#!/usr/bin/env bash
exec sleep 137
STUB
chmod +x "$TMP/bin/blocker"
for m in claude codex gemini; do
  cat > "$TMP/bin/$m" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *--help* ]]; then printf '      --skip-trust  Trust the workspace\n'; exit 0; fi
blocker
STUB
  chmod +x "$TMP/bin/$m"
done
# Compare against a snapshot rather than an empty temp directory: an unrelated
# stale directory from some earlier run must not be read as this run's leak.
REVIEW_TMP_BEFORE="$(ls -d "${TMPDIR:-/tmp}"/model-peer-review.* 2>/dev/null || true)"
# Job control has to be on here. Bash sets SIGINT to *ignored* in a background job
# when job control is off, and a signal ignored on entry cannot be trapped — so
# without this the interrupt is swallowed and the test silently proves nothing.
# With it, this is the same signal disposition a user gets pressing Ctrl-C.
set -m
model-peer review --models claude,codex,gemini --synthesizer claude --timeout 120 \
  'interrupt' >/dev/null 2>&1 &
INT_PID=$!
set +m
sleep 5
INT_START="$(date +%s)"
kill -INT "$INT_PID"
if wait "$INT_PID"; then INT_RC=0; else INT_RC=$?; fi
INT_ELAPSED=$(( $(date +%s) - INT_START ))
# Re-raising the signal is what makes this the conventional 130 rather than
# whatever the interrupted statement happened to return.
(( INT_RC == 130 )) \
  || { echo "expected an interrupted review to exit 130 (got $INT_RC)" >&2; exit 1; }
# And it must stop the panel, not merely clean up and let it run to its timeout.
(( INT_ELAPSED < 30 )) \
  || { echo "interrupt did not stop the panel promptly (${INT_ELAPSED}s)" >&2; exit 1; }
sleep 2
if pgrep -f 'sleep 137' >/dev/null 2>&1; then
  echo 'interrupt left an orphaned vendor process behind' >&2; exit 1
fi
REVIEW_TMP_AFTER="$(ls -d "${TMPDIR:-/tmp}"/model-peer-review.* 2>/dev/null || true)"
if [[ "$REVIEW_TMP_BEFORE" != "$REVIEW_TMP_AFTER" ]]; then
  echo 'interrupt left the review temp directory behind' >&2; exit 1
fi
for m in claude codex gemini; do
  cp "$TMP/bin/$m.real" "$TMP/bin/$m"
done

# ---------------------------------------------------------------------------
# Cost safety. Every model invocation spends the user's money, so anything that
# can be decided without one must be decided without one. Validation, guards,
# help, and every --dry-run/--print/--check path must reach their answer having
# consulted nobody.
# ---------------------------------------------------------------------------

# Runs the command and fails if it invoked any model. The stubs answer --version
# and the vendors' auth/help probes without logging, because those cost nothing.
no_model_call() {
  : > "$LOG"
  "$@" >/dev/null 2>&1 || true
  if grep -q 'ARGS:' "$LOG"; then
    echo "expected '$*' to invoke no model, but it did:" >&2
    grep 'ARGS:' "$LOG" | cut -c1-120 >&2
    exit 1
  fi
}

# Informational and setup commands.
no_model_call model-peer --version
no_model_call model-peer --help
no_model_call model-peer ask --help
no_model_call model-peer review --help
no_model_call model-peer init --help
no_model_call model-peer update --help
no_model_call model-peer doctor
no_model_call model-peer init --dry-run
no_model_call model-peer init --print
no_model_call model-peer update --check
no_model_call model-peer trust --check

# Every validation error. A run that spends three consultations and *then*
# discovers its arguments were wrong has charged the user for nothing.
no_model_call model-peer review --models gemini,gemini
no_model_call model-peer review --models bogus
no_model_call model-peer review --models claude
no_model_call model-peer review --depth 2
no_model_call model-peer review --timeout abc
no_model_call model-peer review --nope
no_model_call env MODEL_PEER_MAX_DIFF_BYTES=abc model-peer review --models claude,codex
no_model_call model-peer ask bogus 'question'
no_model_call model-peer ask codex --depth 0
no_model_call model-peer ask codex --depth 11
no_model_call model-peer ask codex --timeout -1
no_model_call model-peer ask codex --nope 'question'
no_model_call model-peer _delegate init
no_model_call model-peer _delegate codex --depth 9 'question'

# Chain-guard refusals decide from the chain alone and must never pay to find out.
no_model_call env MODEL_PEER_STACK=codex model-peer ask codex 'self'
no_model_call env MODEL_PEER_STACK=codex:gemini:claude model-peer ask claude --depth 5 'cycle'
no_model_call env MODEL_PEER_STACK=claude model-peer ask codex 'depth limit'
no_model_call env MODEL_PEER_STACK='claude:codex' model-peer review --models claude,codex 'nested'

# An empty prompt is rejected before the peer is launched.
no_model_call sh -c 'model-peer ask codex </dev/null'

# review outside a Git working tree, checked before anything is spent.
mkdir -p "$TMP/not-a-repo"
( cd "$TMP/not-a-repo" && no_model_call model-peer review --models claude,codex )

# Exactly one consultation per requested reviewer, plus exactly one synthesis.
# A double-invocation anywhere here silently doubles the bill.
: > "$LOG"
model-peer review --models claude,codex,gemini --synthesizer claude 'exactly once' >/dev/null 2>&1
[[ "$(grep -c '^CODEX ARGS:' "$LOG")" -eq 1 ]] \
  || { echo 'expected Codex to be consulted exactly once' >&2; exit 1; }
[[ "$(grep -c '^GEMINI ARGS:' "$LOG")" -eq 1 ]] \
  || { echo 'expected Gemini to be consulted exactly once' >&2; exit 1; }
# Claude reviews and synthesizes here, so exactly twice and no more.
[[ "$(grep -c '^CLAUDE ARGS:' "$LOG")" -eq 2 ]] \
  || { echo 'expected Claude to be consulted exactly twice' >&2; exit 1; }

# A reviewer that times out is dropped, never retried. Retrying would duplicate
# usage and quietly extend the timeout the user asked for.
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
. "$MP_TEST_LIB"
if [[ "${1:-}" == login && "${2:-}" == status ]]; then exit 0; fi
if [[ "${1:-}" == --version ]]; then printf '9.9.9\n'; exit 0; fi
mp_stub_log codex "$@"
sleep 111
STUB
chmod +x "$TMP/bin/codex"
: > "$LOG"
model-peer review --models claude,codex,gemini --synthesizer claude --timeout 3 \
  'no retry' >/dev/null 2>&1
[[ "$(grep -c '^CODEX ARGS:' "$LOG")" -eq 1 ]] \
  || { echo 'expected a timed-out reviewer to be dropped, not retried' >&2; exit 1; }
cp "$TMP/bin/codex.real" "$TMP/bin/codex"

# ---------------------------------------------------------------------------
# Workspace integrity. A consultation is a read. Nothing Model Peer does to
# answer one may change a single byte, mode, or index entry the user owns.
# ---------------------------------------------------------------------------

# Captures content, untracked files, file modes, and the Git index. The index
# matters on its own: `git add -N` would make untracked files diffable and is
# exactly the shortcut a review command must not take.
snapshot_workspace() {
  {
    git status --porcelain=v1 --untracked-files=all
    git diff --no-ext-diff --no-color
    git diff --cached --no-ext-diff --no-color
    git ls-files -s
    # ls is fine here: the snapshot is only ever compared with another snapshot
    # taken by this same function on this same platform.
    # shellcheck disable=SC2012
    find . -path ./.git -prune -o -type f -print | sort | while read -r f; do
      ls -l "$f" | awk '{ print $1, $NF }'
    done
  } > "$1" 2>&1
}

snapshot_workspace "$TMP/ws-before.txt"
model-peer ask codex 'workspace integrity' >/dev/null 2>&1
model-peer ask gemini 'workspace integrity' >/dev/null 2>&1
model-peer review --models claude,codex,gemini --synthesizer claude \
  'workspace integrity' >/dev/null 2>&1
snapshot_workspace "$TMP/ws-after.txt"
if ! cmp -s "$TMP/ws-before.txt" "$TMP/ws-after.txt"; then
  echo 'model-peer modified the workspace:' >&2
  diff "$TMP/ws-before.txt" "$TMP/ws-after.txt" >&2 || true
  exit 1
fi

# The review context file holds the entire diff, including untracked files. On a
# shared machine that directory must not be readable by anyone else.
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == login && "${2:-}" == status ]]; then exit 0; fi
if [[ "${1:-}" == --version ]]; then printf '9.9.9\n'; exit 0; fi
for d in "${TMPDIR:-/tmp}"/model-peer-review.*; do
  [[ -d "$d" ]] || continue
  ls -ld "$d" | awk '{ print "REVIEWTMP", $1 }' >> "$MP_TEST_PERMS"
done
printf 'codex review output\n'
STUB
chmod +x "$TMP/bin/codex"
: > "$TMP/perms.txt"
MP_TEST_PERMS="$TMP/perms.txt" model-peer review --models claude,codex \
  --synthesizer claude 'temp permissions' >/dev/null 2>&1
grep -Fq 'REVIEWTMP drwx------' "$TMP/perms.txt" \
  || { echo 'expected the review temp directory to exist and be private' >&2; exit 1; }
if grep '^REVIEWTMP ' "$TMP/perms.txt" | grep -qv 'drwx------'; then
  echo 'review temp directory is readable by other users' >&2; exit 1
fi
cp "$TMP/bin/codex.real" "$TMP/bin/codex"

# ---------------------------------------------------------------------------
# Security. Prompts, focus strings, and filenames are data. None of them may
# reach a shell, and no consultation on any path may relax the read-only
# contract or gain execution.
# ---------------------------------------------------------------------------

# Command substitution in a focus string is data, not code. The single quotes are
# the point of the test: these must reach the model verbatim and never a shell.
# shellcheck disable=SC2016
model-peer review --models claude,codex --synthesizer claude \
  '$(touch pwned-focus) `touch pwned-focus2`; touch pwned-focus3' >/dev/null 2>&1
# ...and so is a prompt.
# shellcheck disable=SC2016
model-peer ask codex '$(touch pwned-ask) `touch pwned-ask2`' >/dev/null 2>&1
# ...and so is a filename, which reaches git while the review context is built.
# shellcheck disable=SC2016
printf 'payload\n' > '$(touch pwned-file).txt'
model-peer review --models claude,codex --synthesizer claude 'hostile filename' >/dev/null 2>&1
for bad in pwned-focus pwned-focus2 pwned-focus3 pwned-ask pwned-ask2 pwned-file; do
  if [[ -e "$bad" ]]; then
    echo "expected '$bad' never to be created: input was executed as a command" >&2
    exit 1
  fi
done
# shellcheck disable=SC2016
rm -f '$(touch pwned-file).txt'

# The read-only contract holds on the review and synthesis paths, not only on
# ask. This is where a regression would be least visible and most expensive.
: > "$LOG"
model-peer review --models claude,codex,gemini --synthesizer claude 'contract' >/dev/null 2>&1
# Claude reviews and synthesizes: both in plan mode, both read-only tools.
[[ "$(grep -c '<--permission-mode> <plan>' "$LOG")" -eq 2 ]]
[[ "$(grep -c '<--tools> <Read,Glob,Grep>' "$LOG")" -eq 2 ]]
grep -Fq '<--sandbox> <read-only>' "$LOG"
grep -Fq '<--ephemeral>' "$LOG"
grep -Fq '<--approval-mode> <plan>' "$LOG"
grep -Fq '<-e> <none>' "$LOG"
# Gemini's deny policy is generated for a reviewer too, not just for ask.
awk '/GEMINI POLICY BEGIN/,/GEMINI POLICY END/' "$LOG" | grep -Fq 'run_shell_command'
awk '/GEMINI POLICY BEGIN/,/GEMINI POLICY END/' "$LOG" | grep -Fq 'exit_plan_mode'
awk '/GEMINI POLICY BEGIN/,/GEMINI POLICY END/' "$LOG" | grep -Fq 'write_file'
# Stdin is closed for all four consultations; a live stdin can hang a nested CLI.
[[ "$(grep -c 'STDIN=EOF' "$LOG")" -eq 4 ]]
# No reviewer and no synthesizer is ever granted execution, and every one of them
# is told it is a leaf. Prompt and capability must never disagree.
[[ "$(grep -c 'Remaining peer-chain depth: 0' "$LOG")" -eq 4 ]]
[[ "$(grep -c 'Do not invoke Claude Code' "$LOG")" -eq 4 ]]
for forbidden in 'allowedTools' '<Bash' 'model-peer _delegate <model>'; do
  if grep -Fq "$forbidden" "$LOG"; then
    echo "expected no '$forbidden' anywhere on the review path" >&2; exit 1
  fi
done

# Depth cannot be smuggled into a review through the environment either: the
# reviewers are leaves by construction, not by argument parsing.
: > "$LOG"
MODEL_PEER_MAX_DEPTH=10 model-peer review --models claude,codex --synthesizer claude \
  'env depth' >/dev/null 2>&1
if grep -Fq 'You may consult one further peer' "$LOG"; then
  echo 'expected MODEL_PEER_MAX_DEPTH not to grant reviewers delegation' >&2; exit 1
fi
[[ "$(grep -c 'Remaining peer-chain depth: 0' "$LOG")" -eq 3 ]]

cd "$ROOT"

# Repo setup. `init` installs a self-contained skill per agent and must never
# read, write, or symlink a file the developer owns.
SKILL_REPO="$TMP/skill-repo"
mkdir -p "$SKILL_REPO"
cd "$SKILL_REPO"
git init -q

# --dry-run reports without writing anything.
model-peer init --dry-run > "$TMP/init-dry.txt"
grep -Fq 'dry run' "$TMP/init-dry.txt"
grep -Fq '.claude/skills/cross-model-review/SKILL.md' "$TMP/init-dry.txt"
[[ ! -e .claude && ! -e .codex && ! -e .gemini ]]

# A developer's own context files must survive untouched, including a symlink
# layout, which an earlier version wrote through.
printf '# House rules\n\nNever commit to main.\n' > AGENTS.md
ln -s AGENTS.md CLAUDE.md
ln -s AGENTS.md GEMINI.md
cp AGENTS.md "$TMP/agents-before.md"

model-peer init > "$TMP/init.txt"
cmp "$TMP/agents-before.md" AGENTS.md
[[ "$(readlink CLAUDE.md)" == 'AGENTS.md' ]]
[[ "$(readlink GEMINI.md)" == 'AGENTS.md' ]]

# Two self-contained skills per agent, plus a slash command for each.
for a in claude codex gemini; do
  [[ -f ".$a/skills/cross-model-review/SKILL.md" ]]
  [[ -f ".$a/skills/cross-model-consult/SKILL.md" ]]
done
[[ -f .claude/commands/peer-review.md ]]
[[ -f .claude/commands/peer-ask.md ]]
# review and consult fire on different cues, so their descriptions must differ.
grep -Fq 'cross-model review of the current Git diff' .codex/skills/cross-model-review/SKILL.md
grep -Fq 'independent second opinion' .codex/skills/cross-model-consult/SKILL.md
# No stray markdown in Codex's rules directory: that path holds Starlark .rules
# files governing command execution, and markdown there is ignored.
[[ ! -e .codex/rules ]]
[[ ! -e .gemini/global_rules.md ]]

# Only name and description reach the system prompt before activation, so the
# description has to carry the trigger conditions or the skill never fires.
head -5 .codex/skills/cross-model-review/SKILL.md > "$TMP/fm.txt"
grep -Fq 'name: cross-model-review' "$TMP/fm.txt"
grep -Fq 'description:' "$TMP/fm.txt"
grep -Fq 'before opening a pull request' "$TMP/fm.txt"
# Frontmatter must be the very first line, or the vendors reject the file.
[[ "$(head -1 .codex/skills/cross-model-review/SKILL.md)" == '---' ]]

# Each skill is addressed to the agent that reads it and names its two peers.
for s in cross-model-review cross-model-consult; do
  grep -Fq 'You are Claude.' ".claude/skills/$s/SKILL.md"
  grep -Fq 'You are Codex.'  ".codex/skills/$s/SKILL.md"
  grep -Fq 'You are Gemini.' ".gemini/skills/$s/SKILL.md"
  if grep -Fq 'You are Claude.' ".codex/skills/$s/SKILL.md"; then
    echo "expected the Codex $s skill not to address Claude" >&2; exit 1
  fi
  # A peer that activates a skill mid-consultation must be told to stand down.
  grep -Fq 'while acting as a peer' ".claude/skills/$s/SKILL.md"
done

# Re-running is idempotent, and update reports no drift.
cp .codex/skills/cross-model-review/SKILL.md "$TMP/skill-first.md"
model-peer init >/dev/null
cmp "$TMP/skill-first.md" .codex/skills/cross-model-review/SKILL.md
model-peer update >/dev/null
model-peer update --check >/dev/null

# `update` refreshes a stale file and `--check` reports drift without writing.
printf 'LOCAL EDIT\n' >> .gemini/skills/cross-model-review/SKILL.md
cp .gemini/skills/cross-model-review/SKILL.md "$TMP/tampered.md"
if model-peer update --check > "$TMP/check.txt" 2>&1; then
  echo 'expected update --check to fail on a stale file' >&2; exit 1
else
  [[ $? -eq 1 ]]
fi
grep -Fq 'stale' "$TMP/check.txt"
# --check must not have written anything.
cmp "$TMP/tampered.md" .gemini/skills/cross-model-review/SKILL.md
model-peer update > "$TMP/update.txt"
grep -Fq 'updated' "$TMP/update.txt"
model-peer update --check >/dev/null
if grep -Fq 'LOCAL EDIT' .gemini/skills/cross-model-review/SKILL.md; then
  echo 'expected update to replace a locally edited managed file' >&2; exit 1
fi

# `update` never installs an agent that is not already present, so it cannot
# quietly widen what is in the repository.
rm -rf .gemini
model-peer update >/dev/null
[[ ! -e .gemini ]]

# A file Model Peer did not write is never clobbered without --force.
FOREIGN="$TMP/foreign-repo"
mkdir -p "$FOREIGN/.claude/skills/cross-model-review"
printf 'my own skill\n' > "$FOREIGN/.claude/skills/cross-model-review/SKILL.md"
model-peer init --dir "$FOREIGN" --agents claude > "$TMP/foreign.txt"
grep -Fq 'skipped' "$TMP/foreign.txt"
grep -Fq 'my own skill' "$FOREIGN/.claude/skills/cross-model-review/SKILL.md"
# update leaves it alone too, rather than adopting it.
model-peer update --dir "$FOREIGN" > "$TMP/foreign-update.txt" 2>&1
grep -Fq 'foreign' "$TMP/foreign-update.txt"
grep -Fq 'my own skill' "$FOREIGN/.claude/skills/cross-model-review/SKILL.md"
# --force replaces it.
model-peer init --dir "$FOREIGN" --agents claude --force >/dev/null
grep -Fq 'name: cross-model-review' "$FOREIGN/.claude/skills/cross-model-review/SKILL.md"

# `update` in a project with nothing installed is an error, not a silent success.
mkdir -p "$TMP/empty-repo"
if model-peer update --dir "$TMP/empty-repo" >/dev/null 2>&1; then
  echo 'expected update to fail with nothing installed' >&2; exit 1
else
  [[ $? -eq 1 ]]
fi

# --agents narrows what is written; --no-command skips the slash command.
ONE_REPO="$TMP/one-repo"
mkdir -p "$ONE_REPO"
cd "$ONE_REPO"
git init -q
model-peer init --agents codex --no-command >/dev/null
[[ -f .codex/skills/cross-model-review/SKILL.md ]]
[[ ! -e .claude ]]
[[ ! -e .gemini ]]

# --print writes to stdout and touches nothing.
PRINT_REPO="$TMP/print-repo"
mkdir -p "$PRINT_REPO"
cd "$PRINT_REPO"
model-peer init --print > "$TMP/print.md"
grep -Fq 'name: cross-model-review' "$TMP/print.md"
model-peer init --print=consult > "$TMP/print-consult.md"
grep -Fq 'name: cross-model-consult' "$TMP/print-consult.md"
model-peer init --print=review-command > "$TMP/print-cmd.md"
grep -Fq 'allowed-tools: Bash(model-peer:*)' "$TMP/print-cmd.md"
model-peer init --print=consult-command > "$TMP/print-cmd2.md"
grep -Fq 'second opinion' "$TMP/print-cmd2.md"
if model-peer init --print=bogus >/dev/null 2>&1; then
  echo 'expected an unknown --print target to be rejected' >&2; exit 1
else
  [[ $? -eq 2 ]]
fi
[[ -z "$(ls -A "$PRINT_REPO")" ]]

# --split is gone and says what to do instead.
if model-peer init --split >/dev/null 2>"$TMP/split.err"; then
  echo 'expected --split to be rejected' >&2; exit 1
else
  [[ $? -eq 2 ]]
fi
grep -Fq 'was removed' "$TMP/split.err"

# Invalid input is rejected with the usage exit code.
for bad_args in '--agents bogus' 'stray-positional' '--nope'; do
  # shellcheck disable=SC2086
  if model-peer init $bad_args >/dev/null 2>&1; then
    echo "expected 'model-peer init $bad_args' to be rejected" >&2; exit 1
  else
    [[ $? -eq 2 ]]
  fi
done
if model-peer update --nope >/dev/null 2>&1; then
  echo 'expected an unknown update option to be rejected' >&2; exit 1
else
  [[ $? -eq 2 ]]
fi

# `trust` writes only Gemini's trusted-folder file, and only for one directory.
TRUST_HOME="$TMP/trust-home"
mkdir -p "$TRUST_HOME/.gemini"
printf '{\n  "/pre/existing": "TRUST_FOLDER"\n}\n' > "$TRUST_HOME/.gemini/trustedFolders.json"
if HOME="$TRUST_HOME" model-peer trust --dir "$TMP/repo" --check >/dev/null 2>&1; then
  echo 'expected trust --check to report an untrusted directory' >&2; exit 1
else
  [[ $? -eq 1 ]]
fi
HOME="$TRUST_HOME" model-peer trust --dir "$TMP/repo" >/dev/null
HOME="$TRUST_HOME" model-peer trust --dir "$TMP/repo" --check >/dev/null
grep -Fq '/pre/existing' "$TRUST_HOME/.gemini/trustedFolders.json"
grep -Fq 'TRUST_FOLDER' "$TRUST_HOME/.gemini/trustedFolders.json"
# Idempotent: a second run must not duplicate the entry.
HOME="$TRUST_HOME" model-peer trust --dir "$TMP/repo" >/dev/null
[[ "$(grep -c "$TMP/repo" "$TRUST_HOME/.gemini/trustedFolders.json")" -eq 1 ]]
# No other CLI's configuration is touched: Codex loads project skills without
# trust, and Claude Code prompts once interactively.
[[ ! -e "$TRUST_HOME/.codex" ]]
[[ ! -e "$TRUST_HOME/.claude.json" ]]

cd "$ROOT"


# `doctor --probe` runs one real consultation per CLI and judges the result from
# the filesystem, never from what the model claims. Against stubs we can drive
# each outcome exactly.
cd "$TMP/repo"

# Versions appear in the normal listing, so bug reports carry them.
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == auth && "${2:-}" == status ]]; then exit 0; fi
if [[ "${1:-}" == --version ]]; then printf '9.9.9 (Claude Code)\n'; exit 0; fi
printf 'CLAUDE ARGS:' >> "$MODEL_PEER_TEST_LOG"
printf ' <%s>' "$@" >> "$MODEL_PEER_TEST_LOG"
# A well-behaved peer: reads the token, refuses to write.
if [[ -f probe-token.txt ]]; then cat probe-token.txt; fi
printf 'claude review output\n'
EOF
chmod +x "$TMP/bin/claude"
model-peer doctor > "$TMP/doctor.txt" 2>&1
grep -Fq '9.9.9' "$TMP/doctor.txt"

# A peer that reads but does not write is verified clean.
model-peer doctor --probe --models claude --timeout 20 > "$TMP/probe-ok.txt" 2>&1
grep -Fq 'quoted the probe token' "$TMP/probe-ok.txt"
grep -Fq 'sentinel.txt unchanged' "$TMP/probe-ok.txt"
grep -Fq 'Verified read-only: Claude' "$TMP/probe-ok.txt"

# A peer that writes is a safety failure, detected on disk even though the stub
# never says so — this is the whole point of the command.
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == auth && "${2:-}" == status ]]; then exit 0; fi
if [[ "${1:-}" == --version ]]; then printf '9.9.9\n'; exit 0; fi
printf 'MODIFIED\n' > sentinel.txt
: > probe-write-test.txt
printf 'I was unable to modify anything.\n'
EOF
chmod +x "$TMP/bin/claude"
if model-peer doctor --probe --models claude --timeout 20 > "$TMP/probe-bad.txt" 2>&1; then
  echo 'expected a writing peer to fail the probe' >&2; exit 1
else
  [[ $? -eq 1 ]]
fi
grep -Fq 'sentinel.txt WAS MODIFIED' "$TMP/probe-bad.txt"
grep -Fq 'created probe-write-test.txt' "$TMP/probe-bad.txt"
grep -Fq 'read-only contract did not hold' "$TMP/probe-bad.txt"

# A peer that never answers is inconclusive, not a pass. Reporting "no peer
# modified the workspace" there would be true and misleading at once.
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == auth && "${2:-}" == status ]]; then exit 0; fi
if [[ "${1:-}" == --version ]]; then printf '9.9.9\n'; exit 0; fi
hang
EOF
chmod +x "$TMP/bin/claude"
if model-peer doctor --probe --models claude --timeout 3 > "$TMP/probe-hang.txt" 2>&1; then
  echo 'expected an unanswered probe to be reported as unverified' >&2; exit 1
else
  [[ $? -eq 1 ]]
fi
grep -Fq 'nothing verified' "$TMP/probe-hang.txt"
grep -Fq 'Not verified:' "$TMP/probe-hang.txt"
if grep -Fq 'Verified read-only: Claude' "$TMP/probe-hang.txt"; then
  echo 'expected a hung peer not to be reported as verified' >&2; exit 1
fi
cp "$TMP/bin/claude.real" "$TMP/bin/claude"

# The probe leaves nothing behind.
[[ -z "$(ls -d "${TMPDIR:-/tmp}"/model-peer-probe.* 2>/dev/null)" ]]

# Gemini records its chosen auth method in settings.json. The state that matters
# is "configured for an API key with no key present": headless, Gemini blocks on a
# prompt stdin cannot answer, so a review hangs instead of failing. doctor used to
# call that "cached OAuth is verified on first request", which is exactly wrong.
AUTH_HOME="$TMP/auth-home"
mkdir -p "$AUTH_HOME/.gemini"

printf '{"security":{"auth":{"selectedType":"gemini-api-key"}}}\n' \
  > "$AUTH_HOME/.gemini/settings.json"
HOME="$AUTH_HOME" model-peer doctor > "$TMP/auth1.txt" 2>&1
grep -Fq 'BROKEN' "$TMP/auth1.txt"
grep -Fq 'will hang' "$TMP/auth1.txt"

HOME="$AUTH_HOME" GEMINI_API_KEY=present model-peer doctor > "$TMP/auth2.txt" 2>&1
grep -Fq 'API key (configured, key present)' "$TMP/auth2.txt"
if grep -Fq 'BROKEN' "$TMP/auth2.txt"; then
  echo 'expected a present API key to satisfy the api-key auth type' >&2; exit 1
fi

# OAuth selected but nobody signed in is equally broken.
printf '{"security":{"auth":{"selectedType":"oauth-personal"}}}\n' \
  > "$AUTH_HOME/.gemini/settings.json"
printf '{"active": null, "old": []}\n' > "$AUTH_HOME/.gemini/google_accounts.json"
HOME="$AUTH_HOME" model-peer doctor > "$TMP/auth3.txt" 2>&1
grep -Fq 'no account is signed in' "$TMP/auth3.txt"
printf '{"active": "me@example.com", "old": []}\n' > "$AUTH_HOME/.gemini/google_accounts.json"
HOME="$AUTH_HOME" model-peer doctor > "$TMP/auth4.txt" 2>&1
grep -Fq 'OAuth (signed in)' "$TMP/auth4.txt"

# No settings file at all is a fresh install, not a fault.
rm -f "$AUTH_HOME/.gemini/settings.json" "$AUTH_HOME/.gemini/google_accounts.json"
HOME="$AUTH_HOME" model-peer doctor > "$TMP/auth5.txt" 2>&1
grep -Fq 'no method chosen yet' "$TMP/auth5.txt"
if grep -Fq 'BROKEN' "$TMP/auth5.txt"; then
  echo 'expected a fresh install not to be reported as broken' >&2; exit 1
fi

# doctor still rejects stray arguments.
if model-peer doctor --bogus >/dev/null 2>&1; then
  echo 'expected doctor to reject an unknown option' >&2; exit 1
else
  [[ $? -eq 2 ]]
fi

cd "$ROOT"

# Installer must reproduce the repository binaries exactly.
cd "$ROOT"
bash install.sh --bin-dir "$MODEL_PEER_BIN_DIR" >/dev/null
for cmd in model-peer ask-claude ask-codex ask-gemini ai-review; do
  cmp "$ROOT/bin/$cmd" "$MODEL_PEER_BIN_DIR/$cmd"
done

# Doctor should run with stubs.
"$MODEL_PEER_BIN_DIR/model-peer" doctor >/dev/null

echo 'Model Peer smoke tests passed.'
