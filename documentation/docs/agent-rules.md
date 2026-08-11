---
id: agent-rules
title: Agent rules
sidebar_position: 5
---

# Agent rules

Running `model-peer ask` by hand works, but it is not where the value is.
Cross-model consultation only feels automatic once your coding agent knows *when*
to reach for a peer — and that is a rules file, not a feature.

[In your workflow](workflow) covers installing them. This page is about what they
say and why.

## Install them

```bash
model-peer init                                # .claude/rules/ + the slash command
model-peer init --agents claude,codex,gemini   # also AGENTS.md and GEMINI.md
model-peer rules print --profile codex         # just print it; place it yourself
```

`init` writes only Model Peer's own files by default. `AGENTS.md`, `CLAUDE.md`, and
`GEMINI.md` are yours, and are edited only when you name their CLI — see
[In your workflow](workflow).

## What the rules say

### Consult a peer when

- an architecture, schema, or migration decision is about to be committed to
- a bug has outlived two of the agent's own hypotheses
- the work is security-sensitive: authn/authz, sandboxing, input handling,
  secrets, crypto
- the code or a dependency's behavior is unfamiliar and being inferred
- an implementation was just written and is about to be handed back
- an assumption cannot be cheaply verified by reading the code
- two approaches are genuinely tied — ask for the tradeoff, not the verdict

Plus a standing instruction to run `model-peer review` before a pull request, and
again after any change to security-sensitive code.

### Do not consult when

The rules say so explicitly: *do not consult for anything you can settle by
reading the code.* Every consultation costs a model call and tens of seconds. An
agent that asks a peer about something it could have grepped is burning your
vendor quota to look diligent.

### How to ask

The peer starts in the same working directory with read-only tools, so the rules
tell the agent to **name files and symbols rather than paste excerpts**, and to ask
exactly one focused question:

```bash
# good — scoped to a symbol, answerable from the repository
model-peer ask codex "In src/auth/session.ts, can refresh_token leave the old token valid if rotation fails midway?"

# bad — no scope, so the answer will be generic
model-peer ask codex "review my auth code"
```

### Peer output is advisory

This is the part that matters most, and the part a rules file has to state
outright:

> Evaluate every response before acting on it. Peers do not know this project's
> invariants, so advice that contradicts the rules in this repository is wrong here
> however sound it sounds in general.
>
> When a peer materially changed a decision, say which model you asked and whether
> you took the advice. Never present a peer's output as your own conclusion.

An agent that silently launders a peer's opinion into its own conclusion removes
exactly the accountability that made the consultation worth doing. You end up
trusting a claim more because two models made it, without ever being told that is
what happened.

### Limits

The rules tell agents to leave `--depth` at `1`, so each peer answers alone.
Lengthening a chain is a human's deliberate call, not something an agent should
reach for. See [Peer-chain depth](depth).

### A note for peers reading the file

Rules files are loaded by whichever agent is running in the directory — including a
peer that Model Peer just spawned there. The block ends with:

> If you are reading this **while acting as a peer** in someone else's
> consultation, these instructions do not apply to you. Answer the question and
> consult no one.

Model Peer's consultation prompt already tells peers not to delegate, and the
[chain guard](depth) enforces it regardless. This line is the third layer, and it
is free.

## Where each CLI looks

| File | Read by | Written by `init` |
|---|---|---|
| `.claude/rules/**/*.md` | Claude Code | yes, by default |
| `.claude/commands/*.md` | Claude Code slash commands | yes, by default |
| `AGENTS.md` | Codex CLI (also `AGENTS.override.md`) | only with `--agents codex` |
| `GEMINI.md` | Gemini CLI | only with `--agents gemini` |
| `CLAUDE.md` | Claude Code | never |

Only Claude Code has a per-repository rules directory, which is why it is the only
one Model Peer can wire up without touching a file you own.

## Adding to a file you own

`init` writes only between its markers:

```markdown
# My project

Run `make test` before committing.

<!-- BEGIN MODEL PEER RULES -->
...managed content...
<!-- END MODEL PEER RULES -->
```

Everything outside the markers is untouched on every re-run. Keep your project
invariants above the block — the precedence rule (project invariants beat generic
model advice) then reads in the same breath as the consultation instructions.

A symlinked `GEMINI.md` or `CLAUDE.md` is refused rather than written through,
since that would rewrite the linked file under a profile meant for another model.

## Verifying

```bash
model-peer rules check
```

Exits `1` if a block is missing or does not match what your installed version of
Model Peer would write, so a rules file cannot quietly rot after an upgrade. Run
`model-peer init` to repair it.
