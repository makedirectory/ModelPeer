---
description: Independent cross-model review of the current working diff
argument-hint: [focus instructions]
allowed-tools: Bash(model-peer:*)
---

<!-- Managed by `model-peer init`. Version 0.6.0. Re-run `model-peer update` to refresh. -->

Run an independent cross-model review of the current working tree with
`model-peer review`, passing `$ARGUMENTS` as the focus when it is non-empty.

Every installed model reviews the same diff without seeing the others'
conclusions, then a synthesizer reconciles them. This takes a few minutes and
prints progress on stderr — let it finish.

Then:

1. Report the synthesized findings, grouped by severity, without softening them.
2. For each finding, say whether you agree and why. A peer does not know this
   project's invariants; project rules win over generic advice.
3. Do not apply any fix unless I ask for it.
