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

cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == auth && "${2:-}" == status ]]; then exit 0; fi
printf 'CLAUDE ARGS:' >> "$MODEL_PEER_TEST_LOG"
printf ' <%s>' "$@" >> "$MODEL_PEER_TEST_LOG"
if [[ -t 0 ]]; then printf ' STDIN=TTY\n' >> "$MODEL_PEER_TEST_LOG"; else if IFS= read -r -t 1 x; then printf ' STDIN=%s\n' "$x" >> "$MODEL_PEER_TEST_LOG"; else printf ' STDIN=EOF\n' >> "$MODEL_PEER_TEST_LOG"; fi; fi
printf 'claude review output\n'
EOF

cat > "$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == login && "${2:-}" == status ]]; then exit 0; fi
printf 'CODEX ARGS:' >> "$MODEL_PEER_TEST_LOG"
printf ' <%s>' "$@" >> "$MODEL_PEER_TEST_LOG"
if [[ -t 0 ]]; then printf ' STDIN=TTY\n' >> "$MODEL_PEER_TEST_LOG"; else if IFS= read -r -t 1 x; then printf ' STDIN=%s\n' "$x" >> "$MODEL_PEER_TEST_LOG"; else printf ' STDIN=EOF\n' >> "$MODEL_PEER_TEST_LOG"; fi; fi
printf 'codex review output\n'
EOF

cat > "$TMP/bin/gemini" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# model-peer feature-detects --skip-trust from --help before invoking Gemini.
# Answer that without logging, so the probe does not pollute call assertions.
if [[ "$*" == *--help* ]]; then
  printf '      --skip-trust                Trust the current workspace for this session.\n'
  exit 0
fi
printf 'GEMINI ARGS:' >> "$MODEL_PEER_TEST_LOG"
printf ' <%s>' "$@" >> "$MODEL_PEER_TEST_LOG"
# Capture the generated policy; model-peer deletes it as soon as we exit.
prev=''
for a in "$@"; do
  if [[ "$prev" == '--policy' && -f "$a" ]]; then
    { printf '\nGEMINI POLICY BEGIN\n'; cat "$a"; printf '\nGEMINI POLICY END\n'; } >> "$MODEL_PEER_TEST_LOG"
  fi
  prev="$a"
done
if [[ -t 0 ]]; then printf ' STDIN=TTY\n' >> "$MODEL_PEER_TEST_LOG"; else if IFS= read -r -t 1 x; then printf ' STDIN=%s\n' "$x" >> "$MODEL_PEER_TEST_LOG"; else printf ' STDIN=EOF\n' >> "$MODEL_PEER_TEST_LOG"; fi; fi
printf 'gemini review output\n'
EOF
chmod +x "$TMP/bin/claude" "$TMP/bin/codex" "$TMP/bin/gemini"

# Basic CLI/version.
[[ "$(model-peer --version)" == 'model-peer 0.3.0' ]]

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
grep -Fq '<--allowedTools> <Bash(model-peer:*)>' "$LOG"

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

# Reviewers are leaves by default, and the synthesizer is a leaf at any depth.
: > "$LOG"
model-peer review --models claude,codex --synthesizer codex 'depth default' >/dev/null
if grep -Fq 'Remaining peer-chain depth: 1' "$LOG"; then
  echo 'expected reviewers to be leaves at the default depth' >&2; exit 1
fi
: > "$LOG"
model-peer review --models claude,codex --synthesizer codex --depth 2 'depth two' >/dev/null
grep -Fq 'Remaining peer-chain depth: 1' "$LOG"
# Exactly one leaf prompt per reviewer plus the synthesis prompt, and synthesis
# never gets budget to delegate.
[[ "$(grep -c 'Remaining peer-chain depth: 0' "$LOG")" -eq 1 ]]
model-peer review --models claude,codex --depth 10 'ceiling ok' >/dev/null
if model-peer review --models claude,codex --depth 11 'too deep' >/dev/null 2>&1; then
  echo 'expected review --depth 11 to be rejected' >&2; exit 1
else
  [[ $? -eq 2 ]]
fi

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

cd "$ROOT"

# Repo rules installation. `init` must be safe to re-run, must never rewrite
# content outside its managed block, and must only write paths the vendor CLIs
# actually load.
RULES_REPO="$TMP/rules-repo"
mkdir -p "$RULES_REPO"
cd "$RULES_REPO"
git init -q

# --dry-run reports without writing anything.
model-peer init --dry-run > "$TMP/init-dry.txt"
grep -Fq 'dry run' "$TMP/init-dry.txt"
grep -Fq 'AGENTS.md' "$TMP/init-dry.txt"
[[ ! -e AGENTS.md ]]
[[ ! -e .claude ]]

# Default layout: one real AGENTS.md, with CLAUDE.md and GEMINI.md symlinked to
# it, plus the Claude Code slash command.
model-peer init >/dev/null
[[ -f AGENTS.md && ! -L AGENTS.md ]]
[[ "$(readlink CLAUDE.md)" == 'AGENTS.md' ]]
[[ "$(readlink GEMINI.md)" == 'AGENTS.md' ]]
[[ -f .claude/commands/peer-review.md ]]
grep -Fq '<!-- BEGIN MODEL PEER RULES -->' AGENTS.md
grep -Fq '<!-- END MODEL PEER RULES -->' AGENTS.md
grep -Fq 'model-peer review' AGENTS.md
# A peer that loads this file mid-consultation must be told to stand down.
grep -Fq 'while acting as a peer' AGENTS.md
# Codex and Gemini have no per-repo rules directory; writing one would be inert.
[[ ! -e .codex ]]
[[ ! -e .gemini ]]

# Re-running is idempotent and check passes.
cp AGENTS.md "$TMP/agents-first.md"
model-peer init >/dev/null
cmp "$TMP/agents-first.md" AGENTS.md
model-peer rules check >/dev/null

# A stale block is detected and repaired without touching the rest of the file.
printf '\n# Local notes\n\nKeep these.\n' >> AGENTS.md
sed 's/outlived two of your own/outlived one of your own/' AGENTS.md > "$TMP/tampered" && cat "$TMP/tampered" > AGENTS.md
if model-peer rules check >/dev/null 2>&1; then
  echo 'expected rules check to fail on a stale block' >&2; exit 1
else
  [[ $? -eq 1 ]]
fi
model-peer init >/dev/null
model-peer rules check >/dev/null
grep -Fq '# Local notes' AGENTS.md
grep -Fq 'Keep these.' AGENTS.md

# `rules check` fails in a project that has no rules at all.
mkdir -p "$TMP/no-rules"
if model-peer rules check --dir "$TMP/no-rules" >/dev/null 2>&1; then
  echo 'expected rules check to fail with no rules installed' >&2; exit 1
else
  [[ $? -eq 1 ]]
fi

# --split writes one tailored file per CLI, at the path that CLI actually reads,
# so each harness sees only its own rules.
SPLIT_REPO="$TMP/split-repo"
mkdir -p "$SPLIT_REPO"
cd "$SPLIT_REPO"
git init -q
printf '# House rules\n\nNever commit to main.\n' > AGENTS.md
model-peer init --split >/dev/null
[[ -f .claude/rules/cross-model-consultation.md ]]
[[ -f GEMINI.md && ! -L GEMINI.md ]]
[[ ! -e CLAUDE.md ]]
grep -Fq 'Never commit to main.' AGENTS.md
grep -Fq 'You are Codex.' AGENTS.md
grep -Fq 'You are Gemini.' GEMINI.md
grep -Fq 'You are Claude Code.' .claude/rules/cross-model-consultation.md
model-peer rules check >/dev/null

# An existing regular CLAUDE.md keeps its content instead of being replaced by a
# symlink, and a foreign symlink is left alone unless --force is given.
EDGE_REPO="$TMP/edge-repo"
mkdir -p "$EDGE_REPO"
cd "$EDGE_REPO"
git init -q
printf '# Mine\n\nDo not clobber.\n' > CLAUDE.md
ln -s ../elsewhere.md GEMINI.md
model-peer init > "$TMP/init-edge.txt"
[[ ! -L CLAUDE.md ]]
grep -Fq 'Do not clobber.' CLAUDE.md
grep -Fq '<!-- BEGIN MODEL PEER RULES -->' CLAUDE.md
[[ "$(readlink GEMINI.md)" == '../elsewhere.md' ]]
grep -Fq 'skipped' "$TMP/init-edge.txt"
model-peer init --force >/dev/null
[[ "$(readlink GEMINI.md)" == 'AGENTS.md' ]]

# --agents narrows what is written; --no-command skips the slash command.
ONE_REPO="$TMP/one-repo"
mkdir -p "$ONE_REPO"
cd "$ONE_REPO"
git init -q
model-peer init --agents codex --no-command >/dev/null
[[ -f AGENTS.md ]]
[[ ! -e CLAUDE.md ]]
[[ ! -e GEMINI.md ]]
[[ ! -e .claude ]]

# Invalid input is rejected with the usage exit code.
for bad_args in '--agents bogus' '--split extra' '--nope'; do
  # shellcheck disable=SC2086
  if model-peer init $bad_args >/dev/null 2>&1; then
    echo "expected 'model-peer init $bad_args' to be rejected" >&2; exit 1
  else
    [[ $? -eq 2 ]]
  fi
done
if model-peer rules bogus >/dev/null 2>&1; then
  echo 'expected an unknown rules subcommand to be rejected' >&2; exit 1
else
  [[ $? -eq 2 ]]
fi
if model-peer rules print --profile nope >/dev/null 2>&1; then
  echo 'expected an unknown rules profile to be rejected' >&2; exit 1
else
  [[ $? -eq 2 ]]
fi

# `rules print` writes to stdout and touches nothing. Redirect rather than piping
# into `grep -q`: under pipefail, grep exiting on the first match would kill the
# producer with SIGPIPE and fail the pipeline.
cd "$TMP/no-rules"
model-peer rules print > "$TMP/print-shared.md"
grep -Fq '<!-- BEGIN MODEL PEER RULES -->' "$TMP/print-shared.md"
model-peer rules print --profile gemini > "$TMP/print-gemini.md"
grep -Fq 'You are Gemini.' "$TMP/print-gemini.md"
model-peer rules print --command > "$TMP/print-command.md"
grep -Fq 'allowed-tools: Bash(model-peer:*)' "$TMP/print-command.md"
[[ -z "$(ls -A "$TMP/no-rules")" ]]

# The shipped template must match what `init` writes, so the docs cannot drift.
model-peer rules print | diff -u - "$ROOT/examples/AGENTS.md"

# Installer must reproduce the repository binaries exactly.
cd "$ROOT"
bash install.sh --bin-dir "$MODEL_PEER_BIN_DIR" >/dev/null
for cmd in model-peer ask-claude ask-codex ask-gemini ai-review; do
  cmp "$ROOT/bin/$cmd" "$MODEL_PEER_BIN_DIR/$cmd"
done

# Doctor should run with stubs.
"$MODEL_PEER_BIN_DIR/model-peer" doctor >/dev/null

echo 'Model Peer smoke tests passed.'
