---
id: usage
title: Usage
sidebar_position: 3
---

# Usage

## Set up a project

```bash
model-peer init
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

Every reviewer receives the same Git status and patch and works independently. Only
after all reviews complete does a synthesizer reconcile them.

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

### When a reviewer stalls

Each reviewer is bounded independently — 600 seconds by default — and reports
progress on stderr every 30 seconds:

```bash
model-peer review --timeout 300
model-peer review --timeout 0      # no bound
```

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
Model Peer v0.5.0

Claude    installed  2.1.227    /Users/you/.local/bin/claude
Codex     installed  0.147.0    /opt/homebrew/bin/codex
Gemini    missing

Safety defaults
  Claude  plan mode; Read/Glob/Grep only; stdin closed
  Codex   read-only sandbox; ephemeral session; stdin closed
  Gemini  plan mode + deny policy; extensions disabled; stdin closed
  Gemini  workspace trusted for the session so headless runs are not silent no-ops
  All     chain guard via MODEL_PEER_STACK; no model consults itself
  All     peers never write, and never gain a general shell

Nested consultation support
  Claude   yes   execution scoped to the model-peer command namespace
  Codex    yes   read-only sandbox already permits it; nothing added
  Gemini   no    cannot scope execution to model-peer alone; always a leaf

Consultation timeout:   600s per peer

Peer-chain depth limit: 1 (max 10)

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
