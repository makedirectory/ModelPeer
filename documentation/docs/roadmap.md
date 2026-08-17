---
id: roadmap
title: Roadmap
sidebar_position: 10
---

# Roadmap

## Consultation broker — done in v0.7

The broker shipped. A peer no longer executes anything to consult another model: it
*requests* a consultation, and the parent Model Peer invocation performs it.

```text
                model-peer
                    |
          +---------+---------+
          v                   v
       Claude               Codex
          |
          | "I'd like a Gemini opinion"
          v
      model-peer broker
          |
          v
        Gemini
```

That removed the last capability grant. Claude no longer receives `Bash` at any
depth, `_delegate` is gone, and the uneven provider matrix went with it — Gemini
participates in chains again, because participation no longer requires shell access.

> Peers remain read-only regardless of consultation depth.

See [Peer-chain depth](depth) for how requests are validated and how the turn budget
guarantees a chain terminates.

## Consultation budgets

Depth is not what actually bounds spend. A model may never appear twice on one path,
so with three providers a chain rooted at one model can initiate at most two further
consultations — the roster is the real limit, and `--depth` above 3 has never done
anything.

That stops being true at a fourth provider, which is when budgets become a
requirement rather than an option:

```bash
model-peer review --depth 2 --max-consultations 5 --models claude,codex,gemini
```

```text
Maximum depth:          2
Maximum peer calls:     5
Maximum calls/model:    2
Cycle detection:        on (already enforced)
Write access:           never
Shell access to peers:  never
```

Cycle detection is **done** — the CHANGELOG records which release. A chain like:

```text
Claude
 └─ Codex
     └─ Claude   <- rejected
```

is refused, because the guard tests membership across the whole chain rather than
only against the immediately preceding model. What remains is the per-model and
total call budgets above.

## MCP

All three vendor CLIs support stdio MCP servers, and MCP is a real structured tool
interface — but it is deliberately not how the broker works. A JSON-RPC 2.0 server
means either a JSON parser written in Bash 3.2 or a runtime dependency, and Model
Peer is one dependency-free Bash script. It also inverts ownership: a stdio MCP
server is spawned by the peer's CLI, so the broker would become a child of the peer
rather than part of the parent.

If MCP proves useful, it belongs in a separate package wrapping the public Model
Peer interface, not inside the core script.

## Same-panel consultation

`review` currently denies a reviewer's request for a fellow panel member. Allowing
it is conceivable, but only alongside telling the synthesizer which findings are
correlated — otherwise the report presents an echo as corroboration.

## Not planned

**Applying fixes automatically.** Model Peer analyzes; it does not write. Review
before autonomy is a design principle, not a missing feature. The primary agent
owns the decision, and peer output is evidence rather than a command.

## Contributing

Ideas and disagreement are welcome in
[Discussions](https://github.com/makedirectory/ModelPeer/discussions). Security
issues should go through
[private reporting](https://github.com/makedirectory/ModelPeer/security) instead.
