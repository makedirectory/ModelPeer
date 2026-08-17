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

## By default, there is no chat between models

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

`--depth` deliberately relaxes this, and it is opt-in:

```text
depth 1 (default)      primary -> peer -> primary
depth >1 (opt-in)      primary -> peer -> peer -> primary
```

Even then the peer runs nothing. It *asks* Model Peer for the second opinion, and
Model Peer decides whether to perform it.

`model-peer review` keeps its reviewers as leaves unless you pass `--depth`, and even
then a reviewer may only consult a model that is **not** on the panel. Reviewers that
can consult each other are not independent observations, which is the whole point of
the panel.

The peer also starts in your working directory with read tools enabled, so you don't
paste code into the question — name files and symbols and let it look.

## Why

Coding agents can review their own work, but self-review is still self-review.

`model-peer review` fans your Git diff out to every installed model independently.
None of them sees the others' conclusions; only then does a synthesizer reconcile
the findings. Because reviewers can't anchor on each other, agreement between them
is real signal.

Reviewers are independent, so they also run in parallel: a review costs roughly the
slowest model rather than the sum of them, and Model Peer waits for the whole panel
before synthesizing.

```text
              +--> Claude --+
              |             |
git changes --+--> Codex ---+--> synthesis
              |             |
              +--> Gemini --+
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/makedirectory/ModelPeer/v0.7.1/install.sh | bash
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
  created   .claude/skills/cross-model-review/SKILL.md
  created   .claude/skills/cross-model-consult/SKILL.md
  created   .codex/skills/...            (both, per CLI)
  created   .gemini/skills/...
  created   .claude/commands/peer-review.md
  created   .claude/commands/peer-ask.md
```

Two skills, because the tool does two things that fire on different cues:
**review** cross-checks a diff across the whole panel, **consult** gets one peer's
opinion on one question. Each is a self-contained directory in the place each
vendor set aside for skills. **Your `AGENTS.md`, `CLAUDE.md`, and `GEMINI.md` are
never read, written, or symlinked.**

Now the agent consults a peer on its own — before an architecture decision, on a
bug that has outlived two hypotheses, on anything security-sensitive — and tells
you which model it asked and whether it took the advice. In Claude Code you also
get `/peer-review` for a full cross-model review of the current diff.

Commit those files and your team gets the same behavior. After upgrading Model
Peer, `model-peer update` refreshes them; `model-peer update --check` verifies
them in CI.

→ [In your workflow](https://modelpeer.app/workflow) ·
[Agent skills](https://modelpeer.app/agent-rules)

## Commands

```bash
model-peer ask <claude|codex|gemini> "<focused question>"   # consult one peer
model-peer review ["focus instructions"]                    # cross-model review
model-peer init                                             # install the skills
model-peer update [--check]                                 # refresh them
model-peer trust                                            # let Gemini load them
model-peer doctor [--probe]                                 # check setup
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

Where a vendor reads trust settings from the environment, Model Peer supplies them
itself rather than inheriting yours. Gemini's `GEMINI_CLI_TRUST_WORKSPACE` is cleared
before launch: it would otherwise enable MCP servers declared by the workspace, which
Gemini starts as local subprocesses during tool discovery — before any tool policy
applies. A reviewed repository does not get to configure its own reviewer.

Consultation chains are bounded by `--depth` (default 1, ceiling 10), and a model is
never consulted twice in one chain. Depth is a **limit, not a permission** — raising
it increases how many models can participate, never what a model can do to your
system. A peer that wants a second opinion asks for one in its reply; Model Peer
validates the request and performs the consultation itself. No peer is given a shell,
at any depth, and no peer can start a consultation Model Peer did not authorise.

`--timeout` is one deadline for the whole invocation, not a fresh budget per hop, so
`--depth 3 --timeout 600` is a ten-minute operation rather than a possible fifty.
Under `review` the deadline is per reviewer, and a consultation a reviewer starts
comes out of its own budget.

Reviews cover untracked files as well as tracked changes, so new code is reviewed
rather than merely listed.

This is defense in depth, not a formal sandbox. Upstream CLI behavior can change —
`model-peer doctor --probe` runs one real consultation per CLI and verifies on
disk that none of them wrote anything, which is the only way to know it still
holds after a vendor upgrade.

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

## ☕ Coffee?

If a peer caught something before it shipped, I'd genuinely love to hear about it.
If a peer told you something confidently wrong — we've never met, and this is the
first you're hearing of it. (Peers are advisory. It says so above.)

Either way, if it saved you a review cycle, you can buy me a coffee:

**[buy me a coffee →](https://venmo.com/u/Andrew-Schwartz-92)**

## License

MIT, Copyright (c) 2026 Make Directory Developers, LLC. See [`LICENSE`](LICENSE).

Model Peer is an independent open-source project maintained by Make Directory
Developers, LLC. It is not affiliated with, endorsed by, or sponsored by Anthropic,
OpenAI, or Google. Claude, Codex, and Gemini are trademarks of their respective
owners.
