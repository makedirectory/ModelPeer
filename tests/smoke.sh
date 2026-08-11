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
[[ "$(model-peer --version)" == 'model-peer 0.5.0' ]]

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
