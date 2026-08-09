# Cross-model consultation

<!--
Shared agent rules for Claude Code, Codex CLI, and Gemini CLI.

Copy this into your project as AGENTS.md, then point the other two names at it so
every agent reads the same rules and they can never drift apart:

    cp path/to/examples/AGENTS.md ./AGENTS.md
    ln -sfn AGENTS.md CLAUDE.md
    ln -sfn AGENTS.md GEMINI.md

Add your own project rules below; keep the consultation section intact.
-->

Other model CLIs are available as independent engineering reviewers. Consult them
through Model Peer, which runs them read-only:

```bash
model-peer ask claude "<focused question>"
model-peer ask codex "<focused question>"
model-peer ask gemini "<focused question>"
```

Ask whichever peers are installed other than yourself — Model Peer refuses to let a
model consult itself. `model-peer doctor` lists what is available.

Good reasons to consult a peer:

- architecture decisions
- difficult debugging
- security-sensitive changes
- unfamiliar code
- reviewing a proposed implementation
- checking assumptions
- comparing multiple approaches

The peer sees the working directory read-only, so name files and symbols rather
than pasting large excerpts. Ask one focused question; a peer that has to guess at
scope returns generic advice.

For a full cross-model review of the current diff, with every reviewer working
independently before a synthesizer reconciles them:

```bash
model-peer review "optional focus instructions"
```

Peer models are **advisory**. Evaluate their responses independently before acting.
Project-specific rules and invariants take precedence over generic advice from a
reviewing model. When a peer materially influences a decision, say which model you
asked and whether you accepted or rejected its advice, rather than presenting its
output as a conclusion.

Do not ask a peer to invoke another model. A peer consulted at the default depth
has no ability to do so, and Model Peer's chain guard is the backstop rather than
the primary rule. If a question genuinely warrants a chain, the human raises
`--depth` deliberately.
