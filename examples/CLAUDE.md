# Cross-model consultation

Codex CLI and Gemini CLI are available as independent engineering reviewers.
Consult them through Model Peer, read-only:

```bash
model-peer ask codex "<focused question>"
model-peer ask gemini "<focused question>"
```

Good reasons to consult a peer model:

- architecture decisions
- difficult debugging
- security-sensitive changes
- unfamiliar code
- reviewing a proposed implementation
- checking assumptions
- comparing multiple approaches

Peer models are **advisory**. Evaluate their responses independently before acting.
Project-specific rules and invariants take precedence over generic advice from a
reviewing model.

When a peer materially influences a decision, say what it recommended and whether
you accepted or rejected the advice rather than presenting its output as a conclusion.

Do not ask a peer model to invoke Claude Code or another model. Model Peer also has
a recursion guard, but avoiding recursive delegation is the primary rule.
