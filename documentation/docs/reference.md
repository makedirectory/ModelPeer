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

model-peer review [--models LIST] [--synthesizer MODEL] [--depth N]
                  [--timeout S] [--strict] ["focus"]

model-peer init [--agents LIST] [--no-command] [--dir DIR] [--dry-run] [--force]
model-peer rules install [same options as init]
model-peer rules print [--profile shared|claude|codex|gemini] [--command]
model-peer rules check [--dir DIR]

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
| `--depth N` | Max peer-chain length per reviewer, 1–10 (default 1) |
| `--timeout S` | Per-reviewer timeout in seconds (default 600, `0` disables) |
| `--strict` | Refuse to synthesize unless every reviewer completed |
| `-h`, `--help` | Usage |

Requires a Git working tree and at least two installed reviewers. The synthesizer
defaults to the first available of `claude`, `codex`, `gemini`, and is always a leaf.

Each reviewer is bounded independently. One that times out, exits non-zero, or
returns no output at all is dropped from the panel and named in the report;
synthesis proceeds while at least two reviewers produced a real review, and is
refused below that. See [Troubleshooting](troubleshooting).

Review context covers tracked changes **and** untracked, non-ignored files, so newly
added code is reviewed rather than merely listed.

## `init` / `rules install`

Install the cross-model consultation rules into a project. `model-peer init` is a
shorthand for `model-peer rules install`. See [In your workflow](workflow).

| Option | Description |
|---|---|
| `--agents LIST` | Comma-separated: `claude`, `codex`, `gemini` (default: `claude`) |
| `--no-command` | Skip `.claude/commands/peer-review.md` (the `/peer-review` slash command) |
| `--dir DIR` | Target directory (default: the Git root, else the cwd) |
| `--dry-run` | Report what would change; write nothing |
| `--force` | Overwrite a slash command that is not Model Peer's, and write through a symlinked `AGENTS.md`/`GEMINI.md` |
| `-h`, `--help` | Usage |

Files written:

| Agent | File | Default |
|---|---|---|
| `claude` | `.claude/rules/cross-model-consultation.md` | yes |
| `claude` | `.claude/commands/peer-review.md` | yes, unless `--no-command` |
| `codex` | `AGENTS.md` | **no** — opt in with `--agents codex` |
| `gemini` | `GEMINI.md` | **no** — opt in with `--agents gemini` |

`CLAUDE.md` is never written, and no symlinks are created.

Claude Code is the only one of the three with a per-repository rules directory, so
it is the only one Model Peer can wire up without editing a file you own. Codex
reads `AGENTS.md` and Gemini reads `GEMINI.md`; those are yours, hence opt-in.
There is no per-repo rules directory for either, so `init` never creates `.codex/`
or `.gemini/` — files there are inert.

Content lives between `<!-- BEGIN MODEL PEER RULES -->` and
`<!-- END MODEL PEER RULES -->`. Everything outside those markers is never
rewritten, so re-running is safe and idempotent. A symlinked context file is
refused rather than written through, unless `--force`.

## `rules print`

Write the rules to stdout without touching any file.

| Option | Description |
|---|---|
| `--profile P` | `shared` (default), `claude`, `codex`, or `gemini` |
| `--command` | Print the `/peer-review` slash command instead |

## `rules check`

Verify that every managed block in the project matches what this version of Model
Peer would write. The profile is recorded in each block, so both layouts verify
correctly.

| Option | Description |
|---|---|
| `--dir DIR` | Target directory (default: the Git root, else the cwd) |

Exits `0` when everything is current, `1` when a block is missing or stale.
Suitable for CI.

## `doctor`

Reports installed CLIs and their paths, authentication availability, safety defaults,
the per-provider nested-consultation matrix, the effective depth limit, any
active chain, and whether the current project has rules installed.

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
| `1` | Too few reviewers completed, the synthesizer failed, or `rules check` found missing or stale rules |
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
