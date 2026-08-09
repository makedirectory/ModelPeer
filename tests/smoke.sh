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
printf 'GEMINI ARGS:' >> "$MODEL_PEER_TEST_LOG"
printf ' <%s>' "$@" >> "$MODEL_PEER_TEST_LOG"
if [[ -t 0 ]]; then printf ' STDIN=TTY\n' >> "$MODEL_PEER_TEST_LOG"; else if IFS= read -r -t 1 x; then printf ' STDIN=%s\n' "$x" >> "$MODEL_PEER_TEST_LOG"; else printf ' STDIN=EOF\n' >> "$MODEL_PEER_TEST_LOG"; fi; fi
printf 'gemini review output\n'
EOF
chmod +x "$TMP/bin/claude" "$TMP/bin/codex" "$TMP/bin/gemini"

# Basic CLI/version.
[[ "$(model-peer --version)" == 'model-peer 0.1.0' ]]

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

# Depth 1 keeps Claude tool-restricted; depth > 1 grants only the shell needed
# to reach model-peer, scoped by --allowedTools.
: > "$LOG"
model-peer ask claude 'leaf' >/dev/null
grep -Fq '<--tools> <Read,Glob,Grep>' "$LOG"
! grep -Fq 'allowedTools' "$LOG"
: > "$LOG"
model-peer ask claude --depth 2 'may delegate' >/dev/null
grep -Fq '<--tools> <Read,Glob,Grep,Bash>' "$LOG"
grep -Fq '<--allowedTools> <Bash(model-peer:*)>' "$LOG"

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
! grep -Fq 'Remaining peer-chain depth: 1' "$LOG"
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

# Installer must reproduce the repository binaries exactly.
cd "$ROOT"
bash install.sh --bin-dir "$MODEL_PEER_BIN_DIR" >/dev/null
for cmd in model-peer ask-claude ask-codex ask-gemini ai-review; do
  cmp "$ROOT/bin/$cmd" "$MODEL_PEER_BIN_DIR/$cmd"
done

# Doctor should run with stubs.
"$MODEL_PEER_BIN_DIR/model-peer" doctor >/dev/null

echo 'Model Peer smoke tests passed.'
