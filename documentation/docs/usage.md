---
id: usage
title: Usage
sidebar_position: 3
---

# Usage

## Set up a project

```bash
model-peer init all       # or name the ones you use: init claude,codex
```

Installs a `cross-model-review` skill under `.claude/skills/`, `.codex/skills/`,
and `.gemini/skills/`, plus the `/peer-review` slash command for Claude Code, so
your coding agent reaches for a peer on its own. Everything it writes is
self-contained and owned by Model Peer — your `AGENTS.md`, `CLAUDE.md`, and
`GEMINI.md` are never touched. Run `model-peer update` after upgrading.

→ [In your workflow](workflow) · [Agent rules](agent-rules)

## Ask one peer

```bash
model-peer ask claude "Review the caching strategy for failure modes"
model-peer ask codex "Check this authorization design for bypasses"
model-peer ask gemini "Compare these two queue architectures"
```

The peer runs in your current working directory with read-only inspection tools, so
reference files and symbols rather than pasting excerpts. One focused question works
far better than a broad one — a peer that has to guess at scope returns generic
advice.

Prompts can be piped:

```bash
printf '%s\n' "Review the current migration strategy" | model-peer ask codex
git diff | model-peer ask codex "What breaks in production?"
```

Let the peer consult a further model — see [Peer-chain depth](depth):

```bash
model-peer ask claude --depth 2 "Is this lock-free queue actually correct?"
```

The peer does not run anything to do that. It asks Model Peer for the consultation
in its reply, Model Peer performs it, and the answer comes back to the peer as
evidence. Progress shows on stderr:

```text
model-peer: claude -> codex consultation (depth 2/2)
model-peer: claude -> codex consultation complete
```

`--timeout` covers the whole chain, not each hop.

If your prompt begins with a dash, end the options first:

```bash
model-peer ask codex -- "--force is documented but unimplemented, right?"
```

Compatibility shortcuts:

```bash
ask-claude "..."
ask-codex "..."
ask-gemini "..."
```

## Cross-model review

Inside a Git repository:

```bash
model-peer review
```

Every reviewer receives the same Git status and patch and works independently. They
also run **in parallel** — independent reviewers have nothing to wait on, so the
panel costs roughly the slowest reviewer rather than the sum of all of them. Only
after all reviews reach a terminal state does a synthesizer reconcile them.

Parallel review reduces elapsed time, not provider usage: every requested reviewer
is still invoked exactly once.

The patch covers **untracked files as well as tracked changes**, so a package you
just created is reviewed rather than merely listed as a path.

Add a focus:

```bash
model-peer review "Focus on authorization, tenant isolation, and data leakage"
```

By default every installed supported CLI participates. **At least two models are
required** — a one-model panel is not a cross-model review.

Choose reviewers explicitly:

```bash
model-peer review --models claude,codex
model-peer review --models codex,gemini
model-peer review --models claude,codex,gemini
```

Choose the synthesizer:

```bash
model-peer review --synthesizer codex
```

Claude is preferred for synthesis when installed, then Codex, then Gemini. The
synthesizer is always a leaf: it never consults a peer, regardless of `--depth`.

Reviewers are leaves too unless you say otherwise. `--depth 2` lets a reviewer
consult a model that is **not** on the panel — useful when the panel is two models
and a third is installed:

```bash
model-peer review --models claude,codex --depth 2
```

A request for a fellow panel member is refused, because agreement between two
reviewers that shared a source is not two independent observations.

### When a reviewer stalls

Each reviewer is bounded independently — 600 seconds by default — and reports
progress on stderr every 30 seconds:

```bash
model-peer review --timeout 300
model-peer review --timeout 0      # no bound
```

Because reviewers run concurrently, each timeout window starts when the panel does.
One vendor hanging for the full 600 seconds no longer delays the *start* of the
others — they finish while it stalls, and it is dropped when its own limit expires.

A reviewer that times out, fails, or returns nothing at all is dropped from the
panel and named. Synthesis proceeds while at least two reviewers produced a real
review, and the synthesizer is told which are missing so a partial panel is never
reported as a complete one:

```text
model-peer: Codex timed out after 300s; dropping it from the panel.
model-peer: synthesizing from 2 of 3 reviewers; the report will name the gaps.
```

`--strict` refuses to synthesize unless every reviewer completed.

→ [Troubleshooting](troubleshooting)

The old command remains available:

```bash
ai-review
```

### What reviewers are asked for

Each reviewer is asked for actionable findings only, with severity, file and line or
symbol, why it matters, a recommended fix, and a confidence level — plus important
test gaps. Style-only comments are discouraged unless they create real maintenance
or correctness risk. If the changes look sound, reviewers are told to say so
explicitly.

The synthesizer produces prioritized deduplicated findings, attributes each to the
reviewers who raised it, and calls out disagreements and likely false positives. It
is explicitly instructed **not** to accept a claim merely because several models
repeated it.

### Large diffs

Patches are embedded up to `MODEL_PEER_MAX_DIFF_BYTES` (default 500000). Beyond
that the patch is truncated with a marker, and reviewers are told to inspect the
listed files directly for the remainder.

## Check setup

```bash
model-peer doctor
```

```text
Model Peer v0.8.1

Claude    installed  2.1.227    /Users/you/.local/bin/claude
Codex     installed  0.147.0    /opt/homebrew/bin/codex
Gemini    missing

Safety defaults
  Claude  plan mode; Read/Glob/Grep only; stdin closed
  Codex   read-only sandbox; ephemeral session; stdin closed
  Gemini  plan mode + deny policy; extensions disabled; stdin closed
  Gemini  workspace trusted for the session so headless runs are not silent no-ops
  All     chain guard via MODEL_PEER_STACK; no model consults itself
  All     peers never write, and never gain a shell — at any depth

Nested consultation
  Brokered by Model Peer. A peer asks for a consultation in its reply and
  Model Peer performs it, so no provider is granted execution to reach one.
  Claude   yes   requests are parsed from its output and validated here
  Codex    yes   requests are parsed from its output and validated here
  Gemini   n/a   not installed

Consultation timeout:   600s per invocation

Peer-chain depth limit: 1 (ceiling 10)
Longest usable chain:   2 (a model may not appear twice, and 2 installed)

Project skills in /Users/you/code/your-project
  .claude/skills/cross-model-review/SKILL.md
  .codex/skills/cross-model-review/SKILL.md
  .claude/commands/peer-review.md
```

If the last section reads `Project skills: none`, the agent in that repository has
no reason to consult anyone — run [`model-peer init`](workflow).

To check that the read-only contract actually holds against the CLIs you have
installed, rather than against Model Peer's own flags:

```bash
model-peer doctor --probe
```

That runs one real consultation per CLI and verifies on disk that none of them
wrote anything. It consumes usage — see [the reference](reference#doctor---probe).

## Exit codes

| Code | Meaning |
|---|---|
| `0` | success |
| `1` | too few reviewers completed, the synthesizer failed, or `update --check` found drift |
| `2` | usage or validation error |
| `64` | refused by a chain guard (depth limit or self-consultation) |
| `124` | a consultation exceeded its timeout |
| `127` | a required command is not installed |

Progress and diagnostics go to stderr; only model output goes to stdout, so
`model-peer ask ... | ...` stays pipeable.
