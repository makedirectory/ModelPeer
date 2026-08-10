# Cross-model consultation

Three independent engineering reviewers are available — **Codex**, **Claude**, and Gemini — and **Model Peer** orchestrates them. Use them to pressure-test a decision or review a change against a model with no stake in it.

When running as **Gemini**, do not consult another Gemini instance. Prefer Codex or Claude as independent peers.

## Model Peer (preferred)

`model-peer` (installed globally, `~/.local/bin/model-peer`) runs cross-model review and synthesises the results. It scopes each provider's execution as narrowly as that provider allows, so you do **not** pass sandbox flags yourself.

```bash
# Review the current working diff across the available independent models, synthesised:
model-peer review ["focused instructions"]

# Restrict the reviewers or pick who synthesises:
model-peer review --models codex,claude --synthesizer gemini ["focus"]

# Ask one peer a focused question, or pipe context in:
model-peer ask codex "<focused question>"
git diff | model-peer ask claude "review this diff for correctness"
```

`--depth N` (default 1) limits how long a peer chain may grow; depth 1 means each peer answers alone. A model is never consulted by itself. `model-peer doctor` prints the per-provider execution matrix.

## Direct, single-tool (when you want one reviewer without Model Peer)

```bash
# Codex, read-only:
codex exec --sandbox read-only "<focused question>" </dev/null

# Claude, non-interactive and restricted to read-only code inspection:
claude -p --permission-mode plan --tools "Read,Glob,Grep" "<focused question>"
```

You can also pipe context directly to either reviewer:

```bash
git diff | codex exec --sandbox read-only \
  "Review this diff for correctness, regressions, and missing edge cases." </dev/null

git diff | claude -p --permission-mode plan --tools "Read,Glob,Grep" \
  "Review this diff for correctness, regressions, and missing edge cases."
```

For Codex, both pieces are intentional:

* `--sandbox read-only` prevents the consultation from modifying the working tree.
* `</dev/null` prevents Codex from waiting for additional stdin when no piped context is being provided.

For Claude, all three pieces are intentional:

* `-p` runs Claude non-interactively and exits after the response.
* `--permission-mode plan` starts Claude in its read-only planning mode.
* `--tools "Read,Glob,Grep"` further restricts the available built-in tools so the reviewer can inspect the repository but cannot edit files or execute shell commands.

## Good reasons to consult

* architecture decisions
* difficult debugging
* security-sensitive changes
* unfamiliar code
* reviewing a proposed implementation
* checking assumptions
* comparing multiple approaches

## These reviewers are advisory

Evaluate every response independently before acting. They have no context on this project's invariants, so an answer that violates the project-specific rules is wrong here regardless of how sound it looks in general.

Say what a reviewer recommended and whether you took the advice, rather than presenting its output as a conclusion.

Do not ask Codex or Claude to invoke Gemini or another peer themselves. Keep `--depth` low unless a chain is clearly needed — this prevents recursive agent-to-agent loops. Model Peer already enforces that a model is never its own peer.
