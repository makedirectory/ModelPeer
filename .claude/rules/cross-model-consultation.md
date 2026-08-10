# Cross-model consultation

Three independent engineering reviewers are available — **Codex**, **Gemini**, and Claude — and **Model Peer** orchestrates them. Use them to pressure-test a decision or review a change against a model with no stake in it.

## Model Peer (preferred)

`model-peer` (installed globally, `~/.local/bin/model-peer`) runs cross-model review and synthesises the results. It scopes each provider's execution as narrowly as that provider allows, so you do **not** pass sandbox flags yourself.

```
# Review the current working diff across all installed models, synthesised:
model-peer review ["focused instructions"]

# Restrict the reviewers or pick who synthesises:
model-peer review --models codex,gemini --synthesizer claude ["focus"]

# Ask one peer a focused question, or pipe context in:
model-peer ask codex "<focused question>"
git diff | model-peer ask gemini "review this diff for correctness"
```

`--depth N` (default 1) limits how long a peer chain may grow; depth 1 means each peer answers alone. A model is never consulted by itself. `model-peer doctor` prints the per-provider execution matrix.

## Direct, single-tool (when you want one reviewer without Model Peer)

```
# Codex, read-only:
codex exec --sandbox read-only "<focused question>" </dev/null

# Gemini, non-interactive and read-only:
gemini -p "<focused question>" --approval-mode plan
```

For Codex both flags matter: `--sandbox read-only` (Codex otherwise runs `workspace-write` with `approval: never`, so a consultation could modify the tree) and `</dev/null` (it otherwise waits on stdin). For Gemini, `-p` is headless and `--approval-mode plan` is its read-only mode.

## Good reasons to consult

- architecture decisions
- difficult debugging
- security-sensitive changes
- unfamiliar code
- reviewing a proposed implementation
- checking assumptions
- comparing multiple approaches

## These reviewers are advisory

Evaluate every response independently before acting. They have no context on this project's invariants, so an answer that violates the two-clocks rule or the honesty rules (see the other files in `.claude/rules/`) is wrong here regardless of how sound it looks in general. Say what a reviewer recommended and whether you took the advice, rather than presenting its output as a conclusion.

Do not ask a peer to invoke Claude Code, and keep `--depth` low unless a chain is clearly needed — this prevents recursive agent-to-agent loops. (Model Peer already enforces that a model is never its own peer.)
