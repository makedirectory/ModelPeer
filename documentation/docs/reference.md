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

model-peer init <claude|codex|gemini|all> [--no-command] [--print[=AGENT]]
                [--dir DIR] [--dry-run] [--force]
model-peer update [--check] [--dir DIR]
model-peer trust [--check] [--dir DIR]

model-peer doctor [--probe] [--models LIST] [--timeout S]
model-peer --version
```

## `ask`

Consult a single peer.

| Option | Description |
|---|---|
| `--depth N` | Max peer-chain length, 1–10 (default 1). Above 1 the peer may ask Model Peer to consult a further model; it never runs anything itself |
| `--timeout S` | Give up after S seconds (default 600, `0` disables). Exits `124` on timeout. One deadline for the whole invocation: a nested consultation spends what is left, never a fresh budget |
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
| `--depth N` | Max chain length per reviewer, 1–10 (default 1). Above 1 a reviewer may consult a model **outside** the panel |
| `--timeout S` | Per-reviewer deadline in seconds (default 600, `0` disables). Also bounds synthesis |
| `--strict` | Refuse to synthesize unless every reviewer completed |
| `-h`, `--help` | Usage |

Requires a Git working tree and at least two installed reviewers. The synthesizer
defaults to the first available of `claude`, `codex`, `gemini`.

Reviewers are leaves at the default depth, and the synthesizer is a leaf always.
`--depth 2` lets a reviewer consult a model that is not on the panel; a request for
a panel member is denied, because two reviewers whose findings share a source are
not two independent observations. The synthesizer counts as a panel member even
when it is not reviewing — it reconciles every review, so seeding it through a
consultation would have it meet its own opinion again as someone else's finding.
`MODEL_PEER_MAX_DEPTH` does not apply here — a panel gets depth only when you ask
for it explicitly.

**`--depth` above 1 does nothing on the default panel.** The default is every
installed model, so there is no model outside the panel left to consult and every
reviewer runs as a leaf regardless. It has an effect only when you narrow the panel
with `--models`, leaving an installed model outside it:

```bash
model-peer review --models codex,gemini --synthesizer codex --depth 2
# claude is outside the panel, so a reviewer may consult it
```

Model Peer says which case you are in when the run starts rather than leaving depth
to look effective when it is not.

When a reviewer does consult a peer, Model Peer supplies the canonical review
context and ignores a reviewer-authored `CONTEXT`, announcing the substitution on
stderr. The reviewer chooses the question; Model Peer chooses what repository
evidence crosses.

`review` fans the working tree out to all requested reviewers **concurrently**.
Each reviewer has its own timeout, running from the moment the panel starts. Model
Peer waits for every requested reviewer to finish, fail, or time out before
applying the partial-panel or `--strict` rules and starting synthesis, so a
reviewer still running never has its evidence skipped. Synthesis itself is serial.

Each reviewer is bounded independently. One that times out, exits non-zero, or
returns no output at all is dropped from the panel and named in the report;
synthesis proceeds while at least two reviewers produced a real review, and is
refused below that. See [Troubleshooting](troubleshooting).

Reviewer output is buffered per reviewer and replayed on stdout in the order the
models were requested, never the order they finished, so concurrent responses
cannot interleave and a redirected run is reproducible.

Review context covers tracked changes **and** untracked, non-ignored files, so newly
added code is reviewed rather than merely listed.

## `init`

Install the cross-model review skill into a project. See
[In your workflow](workflow).

Name the agents whose directories `init` may write. There is no default: a bare
`model-peer init` lists the choices, writes nothing, and exits `2`.

| Argument | Description |
|---|---|
| `<AGENT>` | `claude`, `codex`, `gemini`, `all`, or a comma-separated subset. Required |

| Option | Description |
|---|---|
| `--agents LIST` | The same selection, for scripts that already pass it |
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

Reports installed CLIs with their versions and paths, authentication
availability, safety defaults, the per-provider nested-consultation matrix, the
effective depth limit and timeout, any active chain, and which Model Peer skills
the current project has installed.

### `doctor --probe`

| Option | Description |
|---|---|
| `--probe` | Run one real consultation per installed CLI and verify the read-only contract |
| `--models LIST` | Limit the probe to these CLIs |
| `--timeout S` | Per-probe timeout in seconds (default 600) |

The smoke suite runs against stub CLIs. That is right for CI, but it verifies the
flags Model Peer passes, not what the vendors do with them — and every wrong
assumption this project has shipped was of the second kind.

`--probe` closes that gap. It creates a throwaway Git repository containing a
token file and a sentinel, asks each installed CLI to read the token **and to try
to modify the sentinel and create a file**, then checks the result.

The judgement comes from the filesystem, never from the reply. A model claiming
it could not write proves nothing; an unchanged checksum does. The prompt asks
the peer to attempt a write precisely so the disk can answer.

```text
Claude    2.1.227
  ok        read the workspace (quoted the probe token)
  ok        sentinel.txt unchanged
  ok        created no files

Gemini    0.46.0
  timeout   no answer within 600s — nothing verified

Verified read-only: Claude, Codex
Not verified:       Gemini — no usable answer, so the contract is
                    untested for them, not confirmed.
```

A peer that never answers is reported as **unverified**, not as a pass. Exit `1`
covers both a safety failure and an inconclusive run; a safety failure is called
out separately and loudly, because it means the read-only contract did not hold.

:::caution This consumes real usage
One model call per CLI, against your own vendor account. Re-run it after
upgrading a CLI — that is the moment the assumptions underneath Model Peer are
most likely to have moved.
:::

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
| `MODEL_PEER_MAX_DEPTH` | `1` | Default depth limit for `ask`, 1–10. Inside a chain it is the inherited cap: a peer may lower it, never raise it. `review` does not take it as a default |
| `MODEL_PEER_TIMEOUT` | `600` | Default timeout in seconds; `0` disables. One deadline per invocation, and per reviewer under `review` |
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
