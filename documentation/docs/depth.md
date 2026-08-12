---
id: depth
title: Peer-chain depth
sidebar_position: 6
---

# Peer-chain depth

By default a peer answers on its own and may not consult anyone — one hop, then back
to you. `--depth N` lets the chain grow to `N` models:

```bash
model-peer ask claude "..."                 # depth 1: claude answers alone
model-peer ask claude --depth 2 "..."       # claude may consult one further peer
model-peer review --depth 2 "..."           # each reviewer may consult one peer
```

```text
depth 1     you -> claude
depth 2     you -> claude -> codex
depth 3     you -> claude -> codex -> gemini
```

Valid values are `1` to `10`. Set a different default with `MODEL_PEER_MAX_DEPTH`.
The limit propagates down the chain, so a peer cannot raise its own ceiling.

That range is wider than it looks useful. Because a model may never appear twice in
one chain, the longest chain possible is the number of distinct models you have
installed — three today — and `--depth 4` and above do nothing at all.
`model-peer doctor` reports both numbers so you do not have to work that out:

```text
Peer-chain depth limit: 1 (ceiling 10)
Longest usable chain:   3 (a model may not appear twice, and 3 installed)
```

The `10` is a sanity bound on the argument, not a safety property. What makes depth
safe is the no-repeat rule and the delegation matrix below, and neither depends on
that number.

:::tip Depth is chain length, not hop count
`--depth 1` means one model participates and answers alone. It is not "one extra
hop".
:::

## Depth is a limit, not a permission

Model Peer keeps two concepts deliberately separate, and the distinction is the whole
security model:

```text
depth       maximum recursion depth — how many models may participate
delegation  permission to initiate a further consultation, and by what mechanism
```

The invariant:

> Increasing depth may increase **how many models can participate**.
>
> Increasing depth must never increase **what a model can do to the host system**.

A depth *budget* is necessary but not sufficient. It becomes an actual permission
only where a provider's sandbox can hold that permission narrowly.

| Provider | Nested consultation | What delegation actually grants |
|---|---|---|
| Claude | yes | `Bash` auto-approved **only** for `Bash(model-peer:*)` |
| Codex | yes | nothing new — `--sandbox read-only` already permits read-only execution |
| Gemini | **no** | its policy engine can only allow or deny `run_shell_command` wholesale |

### Why Gemini is excluded

Gemini's policy engine cannot scope execution to a single command. Granting nested
consultation would mean lifting the shell deny entirely — unlocking the hallway to
open one door. An uneven provider matrix is more honest than pretending every
sandbox has equivalent primitives, so a Gemini peer is always a leaf and its deny
rules are unconditional at every depth.

A Gemini peer asked to participate beyond depth 1 answers as a leaf and says so:

```text
model-peer: Gemini cannot initiate nested consultation; answering as a leaf.
```

A depth budget a provider cannot safely hold is **reported**, never silently
converted into a wider sandbox.

### The residual widening, stated plainly

Exactly one thing changes when you raise depth: a Claude peer holds `Bash` scoped to
a single command namespace. That is the narrowest grant Claude Code can express, but
it is still a change to the execution boundary, which is why nested consultation is
opt-in per invocation rather than on by default.

This is a known implementation limitation, not the intended end state. The
[consultation broker](roadmap#consultation-broker) will remove it by having peers
*request* a consultation from the parent process rather than executing anything.

## Chain guards

Every nested call carries the active chain in `MODEL_PEER_STACK`, for example
`claude:codex`. Two independent guards apply, both exiting with code `64`.

### Depth limit

The chain may not grow past `N`.

```text
depth 1:  Claude -> model-peer ask codex
                        X chain depth 1 already reached
```

```text
model-peer: blocked: peer chain depth limit reached (depth=1, limit=1, chain=claude).
model-peer: Raise it with --depth N (max 10) or MODEL_PEER_MAX_DEPTH.
```

### Self-consultation

A model never appears twice in one chain, at any depth, so no model reviews its own work even one hop removed. Cross-model review that is
secretly self-review would defeat the point — without this guard, `--depth 3` would
permit `claude -> claude -> claude`.

```text
depth 5:  Claude -> Codex -> model-peer ask codex
                                 X Codex cannot consult itself
```

```text
model-peer: blocked: Codex cannot consult itself (chain=claude:codex).
```

### Interaction with `review`

The synthesizer is always a leaf: it never consults anyone, regardless of `--depth`.

`review` launched from a normal shell starts a fresh chain, because the caller is
the orchestrator rather than a link in the chain. `review` launched from *inside* a
peer chain inherits that chain and cannot escape the guard.

The advisory prompts also tell peers whether they may delegate and how much depth
remains, so the prompt and the actual capability can never disagree. The environment
marker is the backstop, not the primary rule.
