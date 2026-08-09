---
id: agent-rules
title: Agent rules
sidebar_position: 4
---

# Agent rules

Running `model-peer ask` by hand works, but it is not where the value is. Cross-model
consultation only feels automatic once your coding agent knows *when* to reach for a
peer — and that is a rules file, not a feature.

## One file, three names

Each ecosystem reads a different filename. Rather than maintaining three copies that
drift apart, keep one real file and symlink the other two:

```bash
cp examples/AGENTS.md /path/to/your/project/AGENTS.md
cd /path/to/your/project
ln -sfn AGENTS.md CLAUDE.md
ln -sfn AGENTS.md GEMINI.md
```

| File | Read by |
|---|---|
| `AGENTS.md` | OpenAI Codex CLI |
| `CLAUDE.md` | Claude Code |
| `GEMINI.md` | Gemini CLI |

Relative symlinks survive `git clone`, and Git stores them as symlinks (mode
`120000`) rather than duplicating content. Model Peer's own repository uses exactly
this layout.

## What the template says

[`examples/AGENTS.md`](https://github.com/makedirectory/ModelPeer/blob/main/examples/AGENTS.md)
ships as a starting point. The substance:

- Consult peers for architecture decisions, difficult debugging, security-sensitive
  changes, unfamiliar code, implementation review, checking assumptions, and
  comparing approaches.
- Ask whichever peers are installed other than yourself — Model Peer refuses to let
  a model consult itself.
- Name files and symbols instead of pasting large excerpts, since the peer can read
  the working directory.
- Peer advice is **advisory**. Evaluate it independently; project-specific rules and
  invariants take precedence over generic advice from a reviewing model.
- When a peer materially influences a decision, say which model you asked and
  whether you accepted or rejected its advice, rather than presenting its output as
  a conclusion.

That last point matters more than it looks. An agent that silently launders a peer's
opinion into its own conclusion removes exactly the accountability that made the
consultation worth doing.

## Adding it to an existing rules file

If you already have an `AGENTS.md`, append the consultation section rather than
replacing your file, and keep your own project rules above it. The precedence rule —
project invariants beat generic model advice — should stay near the consultation
instructions so it is read in the same breath.
