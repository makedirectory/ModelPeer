# Cross-model consultation

Claude Code and Codex CLI are available as independent engineering reviewers.
Consult them through Model Peer:

```bash
model-peer ask claude "<focused question>"
model-peer ask codex "<focused question>"
```

Use peer consultation for architecture decisions, difficult debugging, security-
sensitive changes, unfamiliar code, implementation review, checking assumptions,
or comparing approaches.

Peer advice is advisory. Evaluate it independently. Project-specific rules and
invariants take precedence over generic reviewer advice. State when peer advice
materially changed the decision.

Do not ask a peer model to invoke Gemini CLI or another model. Model Peer has a
recursion guard as a second line of defense.
