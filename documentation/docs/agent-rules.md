---
id: agent-rules
title: Agent skills
sidebar_position: 5
---

# Agent skills

Running `model-peer ask` by hand works, but it is not where the value is.
Cross-model consultation only feels automatic once your coding agent knows *when*
to reach for a peer — and that is a skill, not a feature.

[In your workflow](workflow) covers installing it. This page is about what it says
and why.

## Install it

```bash
model-peer init                    # a skill per CLI, plus the slash command
model-peer init --agents codex     # just one
model-peer init --print            # print it; place it yourself
model-peer update                  # refresh after upgrading Model Peer
```

Everything `init` writes is self-contained and owned by Model Peer. Your
`AGENTS.md`, `CLAUDE.md`, and `GEMINI.md` are never touched — see
[In your workflow](workflow).

## What the skill says

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

Those conditions also appear in the skill's `description`, not only its body. Only
the name and description reach the model's system prompt; the body loads when the
model activates the skill. A description that just says what the skill *is* would
never fire.

### Do not consult when

The skill says so explicitly: *do not consult for anything you can settle by
reading the code.* Every consultation costs a model call and tens of seconds. An
agent that asks a peer about something it could have grepped is burning your
vendor quota to look diligent.

### How to ask

The peer starts in the same working directory with read-only tools, so the skill
tells the agent to **name files and symbols rather than paste excerpts**, and to ask
exactly one focused question:

```bash
# good — scoped to a symbol, answerable from the repository
model-peer ask codex "In src/auth/session.ts, can refresh_token leave the old token valid if rotation fails midway?"

# bad — no scope, so the answer will be generic
model-peer ask codex "review my auth code"
```

### Peer output is advisory

This is the part that matters most, and the part the skill has to state
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

The skill tells agents to leave `--depth` at `1`, so each peer answers alone.
Lengthening a chain is a human's deliberate call, not something an agent should
reach for. See [Peer-chain depth](depth).

### A note for peers reading the file

A skill is discoverable by whichever agent is running in the directory — including
a peer that Model Peer just spawned there. The body ends with:

> If you are reading this **while acting as a peer** in someone else's
> consultation, these instructions do not apply to you. Answer the question you
> were asked.

A peer cannot act on those instructions anyway: it has no shell, `model-peer`
refuses to run for a brokered process, and the [chain guard](depth) would refuse
the call even if it did. This line is the layer above all of that, and it is free.

## Where each CLI looks

| Path | Read by | Written by `init` |
|---|---|---|
| `.claude/skills/<name>/SKILL.md` | Claude Code | yes |
| `.codex/skills/<name>/SKILL.md` | Codex CLI | yes |
| `.gemini/skills/<name>/SKILL.md` | Gemini CLI | yes |
| `.claude/commands/*.md` | Claude Code slash commands | yes |
| `CLAUDE.md`, `AGENTS.md`, `GEMINI.md` | the respective CLI | **never** |

All three vendors converged on the same shape — a directory containing a
`SKILL.md` with YAML frontmatter — which is what lets Model Peer install one
concept everywhere instead of three.

Verified against the shipping CLIs rather than their docs: `gemini skills list`
reports the project skill, a `codex exec` run lists it among its available skills,
and Claude Code quotes its description back from the system prompt.

Two near-misses worth knowing: `.codex/rules/` holds Starlark `.rules` files
governing command execution, not agent context, so markdown there is ignored; and
`.agents/skills/` is a Gemini-only alias that Codex and Claude Code do not read.

## Verifying

```bash
model-peer update --check
```

Exits `1` if a managed file is missing or does not match what your installed
version of Model Peer would write, so a skill cannot quietly rot after an upgrade.
Run `model-peer update` to repair it.
