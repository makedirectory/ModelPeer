---
id: intro
title: Introduction
slug: /
sidebar_position: 1
---

# Model Peer

**Cross-model peer review for coding agents.**

Model Peer lets Claude Code, OpenAI Codex CLI, and Google Gemini CLI consult one
another as independent, read-only engineering peers.

```bash
model-peer ask claude "What edge cases am I missing?"
model-peer ask codex "Review this authentication design"
model-peer ask gemini "Challenge this migration plan"

model-peer review
```

## There is no chat between models

This is the part that surprises people. Model Peer is not a conversation between
models — **your agent is the hub**. Each consultation spawns another vendor's CLI,
read-only, gets one answer, and exits. Nothing persists.

```text
Primary agent
    |
    +--> independent peer model
    |        |
    |        +--> advisory response
    |
    +--> primary agent evaluates the advice
```

The peer supplies evidence, not authority. Project rules and invariants still win.

## You do not paste code into the question

The peer starts in your current working directory with read tools enabled. Name
files and symbols and let it look for itself:

```bash
$ model-peer ask codex "What does stack_contains in bin/model-peer guard against?"
# codex reads bin/model-peer itself, then answers
```

## Why

Coding agents can review their own work, but self-review is still self-review.
Model Peer makes it trivial to ask a different model:

> What am I missing?

[`model-peer review`](usage#cross-model-review) goes one step further. Every
available reviewer receives the same Git status and patch independently, without
seeing the other models' conclusions. Only after all reviews finish does a
synthesizer reconcile the findings.

The diagram below is literal: reviewers have nothing to wait on, so they run at the
same time, and a review costs about as long as the slowest model rather than the
sum of them.

```text
              +--> Claude --+
              |             |
git changes --+--> Codex ---+--> synthesis
              |             |
              +--> Gemini --+
```

Because reviewers cannot anchor on each other, agreement between them is real
signal. The synthesizer is explicitly instructed not to accept a claim merely
because several models repeated it.

## Supported CLIs

| Provider | Command | Consultation safety |
|---|---|---|
| Anthropic Claude Code | `claude` | Plan mode, read-only inspection tools, stdin closed |
| OpenAI Codex CLI | `codex` | `--sandbox read-only`, ephemeral session, stdin closed |
| Google Gemini CLI | `gemini` | Plan mode, explicit deny policy, extensions disabled, stdin closed |

Model Peer does not collect or store credentials. Authentication stays with each
official CLI.

## Design principles

1. **Independent review** — reviewers start from the same evidence, not each other's opinions.
2. **Read-only consultation** — asking for advice should not hand over write authority.
3. **Primary-agent ownership** — peer output is evidence, not a command.
4. **Project rules win** — local invariants outrank generic model advice.
5. **No credential handling** — authentication stays with official vendor CLIs.
6. **Bounded chains** — depth is capped and opt-in, and no model ever consults itself.
7. **Review before autonomy** — v0.6.0 analyzes; it does not automatically apply fixes.

## Next

- [Install](install) and authenticate the CLIs you want
- [Usage](usage) for `ask`, `review`, and `doctor`
- [In your workflow](workflow) — `model-peer init`, and how this fits day to day
- [Agent skills](agent-rules) for what the skill says and why
- [Peer-chain depth](depth) for the security model
