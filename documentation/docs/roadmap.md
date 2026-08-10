---
id: roadmap
title: Roadmap
sidebar_position: 10
---

# Roadmap

## Consultation broker

Today a peer that is permitted to consult another model does so by executing
`model-peer` itself, which requires granting it outbound execution capability. Model
Peer scopes that as narrowly as each provider allows, and excludes providers that
cannot scope it at all — but the capability still exists for Claude peers above depth
1.

The intended architecture inverts this. Model Peer owns the recursion, and a peer
*requests* a consultation from the parent process rather than running a command.

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

The parent already knows everything needed to adjudicate: the current depth, the
maximum, the models already visited, the read-only requirements, and the recursion
policy.

```text
Claude requests Gemini
Current depth: 1
Maximum: 2
Gemini not already in call chain
-> allowed
```

Claude never needs `Bash` at all, which restores the strongest possible guarantee:

> Peers remain read-only regardless of consultation depth.

It also removes the uneven provider matrix — Gemini could participate in chains
again, because participation would no longer require shell access.

## Central policy enforcement

Once recursion is brokered centrally, richer policy becomes cheap. Per-model call
budgets, total consultation budgets, and full cycle detection rather than the
self-consultation check that is possible today:

```bash
model-peer review --depth 2 --max-consultations 5 --models claude,codex,gemini
```

```text
Maximum depth:          2
Maximum peer calls:     5
Maximum calls/model:    2
Cycle detection:        on
Write access:           never
Shell access to peers:  never
```

Full cycle detection would reject a chain like:

```text
Claude
 └─ Codex
     └─ Claude   <- cycle
```

which the current self-consultation guard permits, since it only compares against
the immediately preceding model.

## Not planned

**Applying fixes automatically.** Model Peer analyzes; it does not write. Review
before autonomy is a design principle, not a missing feature. The primary agent
owns the decision, and peer output is evidence rather than a command.

## Contributing

Ideas and disagreement are welcome in
[Discussions](https://github.com/makedirectory/ModelPeer/discussions). Security
issues should go through
[private reporting](https://github.com/makedirectory/ModelPeer/security) instead.
