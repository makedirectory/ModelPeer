# Model Peer

[![test](https://github.com/makedirectory/ModelPeer/actions/workflows/test.yml/badge.svg)](https://github.com/makedirectory/ModelPeer/actions/workflows/test.yml)
[![docs](https://github.com/makedirectory/ModelPeer/actions/workflows/docs.yml/badge.svg)](https://modelpeer.app)
[![release](https://img.shields.io/github/v/release/makedirectory/ModelPeer)](https://github.com/makedirectory/ModelPeer/releases)
[![license](https://img.shields.io/github/license/makedirectory/ModelPeer)](LICENSE)

**Cross-model peer review for coding agents.**

Model Peer lets Claude Code, OpenAI Codex CLI, and Google Gemini CLI consult one
another as independent, read-only engineering peers.

📖 **[Documentation](https://modelpeer.app)**

```bash
model-peer ask codex "Review this authentication design for bypasses"
model-peer review
```

## There is no chat between models

This is the part that surprises people. **Your agent is the hub.** Each consultation
spawns another vendor's CLI, read-only, gets one answer, and exits. Nothing persists.

```text
Primary agent
    |
    +--> independent peer model --> advisory response
    |
    +--> primary agent evaluates the advice
```

The peer supplies evidence, not authority. Project rules and invariants still win.

The peer also starts in your working directory with read tools enabled, so you don't
paste code into the question — name files and symbols and let it look.

## Why

Coding agents can review their own work, but self-review is still self-review.

`model-peer review` fans your Git diff out to every installed model independently.
None of them sees the others' conclusions; only then does a synthesizer reconcile
the findings. Because reviewers can't anchor on each other, agreement between them
is real signal.

```text
              +--> Claude --+
              |             |
git changes --+--> Codex ---+--> synthesis
              |             |
              +--> Gemini --+
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/makedirectory/ModelPeer/v0.2.0/install.sh | bash
```

Or clone and run `./install.sh`. As with any remote shell installer, inspect it
first. Model Peer never asks you to paste an API key — authentication stays with
each vendor CLI.

→ [Full install guide](https://modelpeer.app/install)

## Set up a project

Installing Model Peer globally gives *you* a command. It does not give the coding
agent in your repository a habit. One command per project fixes that:

```bash
cd ~/code/your-project
model-peer init
```

```text
  created   AGENTS.md
  linked    CLAUDE.md -> AGENTS.md
  linked    GEMINI.md -> AGENTS.md
  created   .claude/commands/peer-review.md (/peer-review)
```

Now the agent consults a peer on its own — before an architecture decision, on a
bug that has outlived two hypotheses, on anything security-sensitive — and tells
you which model it asked and whether it took the advice. In Claude Code you also
get `/peer-review` for a full cross-model review of the current diff.

Commit those files and your team gets the same behavior. Re-running only rewrites
the block between its own markers, so your existing rules are safe. Prefer one
tailored file per CLI? `model-peer init --split`.

→ [In your workflow](https://modelpeer.app/workflow) ·
[Agent rules](https://modelpeer.app/agent-rules)

## Commands

```bash
model-peer ask <claude|codex|gemini> "<focused question>"   # consult one peer
model-peer review ["focus instructions"]                    # cross-model review
model-peer init [--split]                                   # install repo rules
model-peer rules <install|print|check>                      # manage those rules
model-peer doctor                                           # check setup
```

Every consultation is bounded (`--timeout`, 600s default) and reports progress on
stderr. A reviewer that hangs, fails, or returns nothing is dropped and named rather
than taking the whole panel with it.

→ [Usage](https://modelpeer.app/usage) ·
[CLI reference](https://modelpeer.app/reference)

## Safety

Peers are launched with the most conservative non-interactive configuration each
vendor supports: Plan mode or a read-only sandbox, no file-editing tools, no general
shell, and stdin closed. Model Peer stores no credentials.

Consultation chains are bounded by `--depth` (default 1, ceiling 10), and no model
is ever consulted by itself. Depth is a **limit, not a permission** — raising it
increases how many models can participate, never what a model can do to your system.

Reviews cover untracked files as well as tracked changes, so new code is reviewed
rather than merely listed.

This is defense in depth, not a formal sandbox. Upstream CLI behavior can change.

→ [Safety boundaries](https://modelpeer.app/safety) ·
[Peer-chain depth](https://modelpeer.app/depth) ·
[Troubleshooting](https://modelpeer.app/troubleshooting)

## Development

```bash
make test     # smoke tests against stub CLIs; no model usage
make lint     # syntax check, plus shellcheck when installed
make sync     # regenerate install.sh's embedded copy of bin/model-peer
```

→ [Development](https://modelpeer.app/development) ·
[Roadmap](https://modelpeer.app/roadmap)

## Community

Questions and ideas are welcome in
[Discussions](https://github.com/makedirectory/ModelPeer/discussions).
Security issues should go through
[private reporting](https://github.com/makedirectory/ModelPeer/security) rather
than a public issue.

## License

MIT, Copyright (c) 2026 Make Directory Developers, LLC. See [`LICENSE`](LICENSE).

Model Peer is an independent open-source project maintained by Make Directory
Developers, LLC. It is not affiliated with, endorsed by, or sponsored by Anthropic,
OpenAI, or Google. Claude, Codex, and Gemini are trademarks of their respective
owners.
