---
id: reference
title: CLI reference
sidebar_position: 7
---

# CLI reference

## Commands

```text
model-peer ask <claude|codex|gemini> [--depth N] "<focused question>"
command | model-peer ask <claude|codex|gemini> [--depth N]

model-peer review [--models LIST] [--synthesizer MODEL] [--depth N] ["focus"]
model-peer doctor
model-peer --version
```

## `ask`

Consult a single peer.

| Option | Description |
|---|---|
| `--depth N` | Max peer-chain length, 1–10 (default 1) |
| `--` | End options; everything after is the prompt |
| `-h`, `--help` | Usage |

The prompt may be given as arguments or piped on stdin.

## `review`

Fan the current Git working tree out to several models independently, then
synthesize.

| Option | Description |
|---|---|
| `--models LIST` | Comma-separated reviewers (default: all installed) |
| `--synthesizer MODEL` | `claude`, `codex`, or `gemini` |
| `--depth N` | Max peer-chain length per reviewer, 1–10 (default 1) |
| `-h`, `--help` | Usage |

Requires a Git working tree and at least two installed reviewers. The synthesizer
defaults to the first available of `claude`, `codex`, `gemini`, and is always a leaf.

## `doctor`

Reports installed CLIs and their paths, authentication availability, safety defaults,
the per-provider nested-consultation matrix, the effective depth limit, and any
active chain.

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
| `1` | A reviewer or the synthesizer failed |
| `2` | Usage or validation error |
| `64` | Refused by a chain guard — depth limit or self-consultation |
| `127` | A required command is not installed |

## Output streams

Progress, banners, and diagnostics go to **stderr**. Only model output goes to
**stdout**, so consultations stay pipeable:

```bash
model-peer ask codex "Summarize the risk here" > review.md
```
