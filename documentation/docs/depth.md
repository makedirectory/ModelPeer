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
safe is the no-repeat rule and the fact that peers execute nothing, and neither
depends on that number.

:::tip Depth is chain length, not hop count
`--depth 1` means one model participates and answers alone. It is not "one extra
hop".
:::

## Depth is a limit, not a permission

The invariant:

> Increasing depth may increase **how many models can participate**.
>
> Increasing depth must never increase **what a model can do to the host system**.

Since v0.7 this holds without qualification, because a peer never launches anything.
It *asks*.

```text
you
 └─ model-peer
     └─ Claude
         │  emits a consultation request in its reply, then stops
         ▼
        the broker, inside the same model-peer process
         │  parses it, validates it, runs the consultation
         ▼
        Codex
         │
         ▼
        the broker frames the answer as evidence
         ▼
        Claude, next turn
```

Claude never launches Codex. Claude never launches `model-peer`. Claude executes
nothing at all. The parent invocation owns the whole chain, which means:

| Provider | Nested consultation | What raising depth grants it |
|---|---|---|
| Claude | yes | nothing — `Read,Glob,Grep`, plan mode, at every depth |
| Codex | yes | nothing — `--sandbox read-only --ephemeral`, at every depth |
| Gemini | yes | nothing — plan mode and the same unconditional deny policy |

### What changed in v0.7

Before the broker, a peer that wanted a second opinion had to run `model-peer`
itself, so depth had to buy it a shell grant. Model Peer scoped that as narrowly as
each provider allowed — Claude got `Bash` auto-approved only for
`Bash(model-peer _delegate:*)` — but the grant existed, and it varied by vendor.
Gemini was permanently a leaf, not because its opinion was worth less but because
its policy engine can only allow or deny `run_shell_command` wholesale.

The broker removes the requirement rather than working around it. There is no
`_delegate` command any more, no `--allowedTools` on any invocation, and no
per-provider capability matrix — every model participates on identical terms
because the transport is text.

:::note The framing is not a security boundary
The request block carries a per-turn identifier, and Model Peer only recognises a
block carrying the one it issued for the turn in progress. That prevents
protocol-shaped text in a diff, a document, or another model's output from being
read as a request — it does not stop a peer from asking. The security boundary is
validation: a peer may emit any block it likes, and the broker still decides whether
the requested model runs.
:::

## What the broker validates

Every request is checked before anything runs:

```text
was an identifier issued for this turn, and does the block carry it?
is the requested model one of claude, codex, gemini, and installed?
is it the requesting peer itself?
does it already appear on the active path?
is it a member of the active review panel?
would this exceed the maximum chain depth?
```

A peer can spend only the authority the original invocation already granted, and can
never increase it. A denied request comes back to the requester as a framed packet
with a reason, and the run continues:

```text
model-peer: claude -> codex consultation denied: codex is a member of this review panel
```

A failed nested consultation is **evidence unavailable**, not failure of your
original request. The requester carries on and its own invocation decides the exit
status.

## Turns, and why a chain terminates

Consultation capability is granted per turn by issuing an identifier, and taken away
by withholding one. Before the first turn Model Peer works out who is available:

```text
available = installed − already on the path − the peer itself − the review panel
turn budget = available + 1
```

The last turn never carries an identifier, so the peer has to answer. Capability
disappears rather than being parsed away, and each turn spends exactly one unit of
the budget whether the peer cooperates or not.

```text
ask claude --depth 2, all three installed

turn 1   identifier issued, available = codex, gemini
         Claude requests Codex               -> granted
turn 2   identifier issued, available = gemini
         Claude requests Gemini              -> granted
turn 3   no identifier                       -> Claude answers
```

Note what that implies: breadth is not bounded by depth. `claude -> codex` and
`claude -> gemini` are both depth 2 and neither is a repeat. Total spend is bounded
by how many models you have installed, not by `--depth` — which is fine at three
providers and becomes a reason to add consultation budgets at four.

## One deadline, not one per hop

`--timeout` bounds what you asked Model Peer to do. It is resolved once, as a
deadline, and every hop spends what is left of it:

```text
deadline  = start + timeout
remaining = deadline − now
```

```text
model-peer ask claude --depth 3 --timeout 600

Claude turn 1  consumes 180s
Codex          gets at most 420s
Claude turn 2  consumes  60s
Gemini         gets at most 360s
```

Resolving a *duration* instead would have made that command a possible ~3000s
operation. Under `review` the rule applies per reviewer, independently, so
`review --timeout 600` means exactly what it meant before: each reviewer gets 600
seconds, and a consultation one of them starts comes out of its own budget and
nobody else's.

`--timeout 0` disables the limit, at every depth.

## Chain guards

Every nested call carries the active chain in `MODEL_PEER_STACK`, for example
`claude:codex`. Two independent guards apply, both exiting with code `64`.

### Depth limit

The chain may not grow past `N`.

```text
depth 1:  Claude requests Codex
                     X chain depth 1 already reached
```

At the top level that is a usage error and exits `64`. Reached through a peer's
request it is a denial, which comes back to the peer as evidence:

```text
model-peer: claude -> codex consultation denied: maximum depth reached
```

### Self-consultation

A model never appears twice in one chain, at any depth, so no model reviews its own
work even one hop removed. Cross-model review that is secretly self-review would
defeat the point — without this guard, `--depth 3` would permit
`claude -> claude -> claude`.

```text
depth 5:  Claude -> Codex requests Codex
                              X Codex cannot consult itself
```

Membership is tested across the whole path, not just its tail, so
`claude -> codex -> claude` is refused as well.

### Interaction with `review`

Reviewers are leaves by default, and the synthesizer is a leaf always, regardless of
`--depth`.

`review --depth 2` lets a reviewer consult a model that is **not** on the panel:

```text
panel: claude, codex

claude reviewer -> gemini    allowed
claude reviewer -> codex     denied — panel member
```

The denial is not about self-consultation. It is that one reviewer's findings would
become partly dependent on another panel member's reasoning, and the synthesizer
would then read correlated findings as independent agreement — the same class of
misreport as an empty review file reading as "found no issues".

`MODEL_PEER_MAX_DEPTH` does not reach `review`. Giving a panel depth changes what
agreement between two reviewers means, so it has to be asked for explicitly.

When a reviewer does consult a peer, Model Peer sends the consulted model the same
review packet the panel received, and ignores a reviewer-supplied `CONTEXT` with a
note:

```text
model-peer: reviewer-supplied CONTEXT ignored; using immutable review context
```

The reviewer chooses the question. Model Peer chooses what repository evidence
crosses the boundary. Otherwise a reviewer could forward the two lines supporting the
conclusion it had already reached, omit the rest of the diff, and get agreement the
panel would record as corroboration — which a reviewer summarising to stay inside a
byte cap would do by accident, with no bad intent required.

`review` launched from a normal shell starts a fresh chain, because the caller is
the orchestrator rather than a link in the chain. `review` launched from *inside* a
peer chain inherits that chain and cannot escape the guard.

The prompts tell peers exactly how much depth remains and whether this turn may
request a consultation, so prompt and capability can never disagree.
