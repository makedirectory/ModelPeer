---
id: reference
title: CLI reference
sidebar_position: 8
---

# CLI reference

## Commands

```text
model-peer ask <claude|codex|gemini> [--depth N] [--timeout S] "<question>"
command | model-peer ask <claude|codex|gemini> [--depth N] [--timeout S]

model-peer review [--models LIST] [--synthesizer MODEL] [--timeout S]
                  [--strict] ["focus"]

model-peer init [--agents LIST] [--no-command] [--print[=AGENT]] [--dir DIR]
                [--dry-run] [--force]
model-peer update [--check] [--dir DIR]
model-peer trust [--check] [--dir DIR]

model-peer doctor
model-peer --version
```

## `ask`

Consult a single peer.

| Option | Description |
|---|---|
| `--depth N` | Max peer-chain length, 1–10 (default 1) |
| `--timeout S` | Give up after S seconds (default 600, `0` disables). Exits `124` on timeout |
| `--` | End options; everything after is the prompt |
| `-h`, `--help` | Usage |

The prompt may be given as arguments or piped on stdin. Progress is reported on
stderr every 30 seconds while a consultation runs.

## `review`

Fan the current Git working tree out to several models independently, then
synthesize.

| Option | Description |
|---|---|
| `--models LIST` | Comma-separated reviewers (default: all installed) |
| `--synthesizer MODEL` | `claude`, `codex`, or `gemini` |
| `--timeout S` | Per-reviewer timeout in seconds (default 600, `0` disables). Also bounds synthesis |
| `--strict` | Refuse to synthesize unless every reviewer completed |
| `-h`, `--help` | Usage |

Requires a Git working tree and at least two installed reviewers. The synthesizer
defaults to the first available of `claude`, `codex`, `gemini`.

`review` takes no `--depth`. Every reviewer and the synthesizer are leaves: none
consults another model. Three reviewers that can consult each other are not three
independent observations, so this is a property of the command rather than a
setting. Passing `--depth` exits `2` with a pointer to `ask`.

Each reviewer is bounded independently. One that times out, exits non-zero, or
returns no output at all is dropped from the panel and named in the report;
synthesis proceeds while at least two reviewers produced a real review, and is
refused below that. See [Troubleshooting](troubleshooting).

Review context covers tracked changes **and** untracked, non-ignored files, so newly
added code is reviewed rather than merely listed.

## `init`

Install the cross-model review skill into a project. See
[In your workflow](workflow).

| Option | Description |
|---|---|
| `--agents LIST` | Comma-separated: `claude`, `codex`, `gemini` (default: all three) |
| `--no-command` | Skip `.claude/commands/peer-review.md` (the `/peer-review` slash command) |
| `--print[=WHAT]` | Print to stdout and exit. `WHAT` is `review` (default), `consult`, `review-command`, or `consult-command` |
| `--dir DIR` | Target directory (default: the Git root, else the cwd) |
| `--dry-run` | Report what would change; write nothing |
| `--force` | Replace a file at a managed path that Model Peer did not write |
| `-h`, `--help` | Usage |

Files written:

| Agent | Path |
|---|---|
| `claude` | `.claude/skills/cross-model-review/SKILL.md` |
| `claude` | `.claude/skills/cross-model-consult/SKILL.md` |
| `codex` | `.codex/skills/cross-model-{review,consult}/SKILL.md` |
| `gemini` | `.gemini/skills/cross-model-{review,consult}/SKILL.md` |
| `claude` | `.claude/commands/peer-review.md` and `peer-ask.md`, unless `--no-command` |

Two skills, not one: `cross-model-review` cross-checks a diff across the panel,
`cross-model-consult` gets one peer's opinion on one question. They fire on
different cues, and a single description covering both triggers neither well.

`AGENTS.md`, `CLAUDE.md`, and `GEMINI.md` are never read, written, or symlinked.
Every managed file is owned outright and replaced whole, so nothing Model Peer
writes lives inside a file you own.

A file at a managed path that Model Peer did not write is reported and left alone
unless `--force` is given.

## `update`

Refresh the managed files already installed in a project so they match the running
version of Model Peer.

| Option | Description |
|---|---|
| `--check` | Report drift and exit `1` if anything is stale; write nothing. For CI |
| `--dir DIR` | Target directory (default: the Git root, else the cwd) |

`update` only touches files that already exist and that Model Peer wrote. It never
installs an agent that is not already present — use `init` for that — so it cannot
quietly widen what is in your repository. Exits `1` when nothing is installed.

## `trust`

Mark a directory as trusted for Gemini CLI, which otherwise refuses to load
project skills and reports none at all.

| Option | Description |
|---|---|
| `--check` | Report whether the directory is trusted; change nothing. Exits `1` if not |
| `--dir DIR` | Target directory (default: the Git root, else the cwd) |

This adds one `TRUST_FOLDER` entry to `~/.gemini/trustedFolders.json` and changes
nothing else. No other CLI is touched: Codex loads project skills without trust,
and Claude Code asks once, interactively. Because folder trust is a security
control, `init` never does this for you — it only points at the command.

## `doctor`

Reports installed CLIs and their paths, authentication availability, safety defaults,
the per-provider nested-consultation matrix, the effective depth limit, any
active chain, and which Model Peer skills the current project has installed.

## Compatibility commands

| Command | Equivalent |
|---|---|
| `ask-claude "..."` | `model-peer ask claude "..."` |
| `ask-codex "..."` | `model-peer ask codex "..."` |
| `ask-gemini "..."` | `model-peer ask gemini "..."` |
| `ai-review ...` | `model-peer review ...` |

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `MODEL_PEER_REVIEWERS` | all installed | Default review panel, e.g. `claude,codex,gemini` |
| `MODEL_PEER_SYNTHESIZER` | first available | Default synthesis model |
| `MODEL_PEER_MAX_DEPTH` | `1` | Default peer-chain depth limit, 1–10 |
| `MODEL_PEER_TIMEOUT` | `600` | Default per-consultation timeout in seconds; `0` disables |
| `MODEL_PEER_MAX_DIFF_BYTES` | `500000` | Patch bytes embedded in review prompts |
| `MODEL_PEER_BIN_DIR` | `~/.local/bin` | Install directory override |
| `MODEL_PEER_STACK` | — | Managed by Model Peer; the active peer chain |

`MODEL_PEER_STACK` is set by Model Peer for nested calls and should not normally be
set by hand. Setting it manually simulates being inside a chain, which the guards
will enforce.

Example:

```bash
MODEL_PEER_REVIEWERS=codex,gemini model-peer review
```

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Too few reviewers completed, the synthesizer failed, or `update --check` found missing or stale files |
| `2` | Usage or validation error |
| `64` | Refused by a chain guard — depth limit or self-consultation |
| `124` | A consultation exceeded its timeout |
| `127` | A required command is not installed |

## Output streams

Progress, banners, and diagnostics go to **stderr**. Only model output goes to
**stdout**, so consultations stay pipeable:

```bash
model-peer ask codex "Summarize the risk here" > review.md
```
