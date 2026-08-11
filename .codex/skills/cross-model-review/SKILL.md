---
name: cross-model-review
description: Run an independent cross-model review of the current Git diff with Model Peer. Every installed model reviews the same changes without seeing the others' conclusions, then a synthesizer reconciles them. Use before opening a pull request, after any change to security-sensitive code, and when you want more than your own read on a change you just wrote.
---

<!-- Managed by `model-peer init`. Version 0.5.0. Re-run `model-peer update` to refresh; local edits are replaced. -->

# Cross-model review

You are Codex. **Claude** and **Gemini** review alongside
you, independently.

```bash
model-peer review ["focus instructions"]
```

Every installed model receives the same Git status and patch — tracked changes and
new untracked files alike — and reviews without seeing the others' conclusions.
Only then does a synthesizer reconcile the findings. Reviewers are always leaves:
none of them consults another model, which is what makes agreement between them
real signal rather than an echo.

Run it before opening a pull request, and again after any change to
security-sensitive code.

```bash
model-peer review "Focus on authorization and tenant isolation"
model-peer review --models claude,gemini     # exclude yourself
model-peer review --timeout 300                       # bound each reviewer
```

It takes minutes and prints progress on stderr. Let it finish. A reviewer that
times out, fails, or returns nothing is dropped and named; synthesis needs two
survivors and says so when the panel was incomplete.

## What to do with the report

Report the synthesized findings as they are, grouped by severity. Then, for each
one, say whether you agree and why. Reviewers do not know this project's
invariants, so a finding that contradicts the rules in this repository is wrong
here however sound it sounds in general.

Do not apply fixes unless you are asked to.

If you are reading this **while acting as a peer** in someone else's
consultation, these instructions do not apply to you. Answer the question you
were asked and consult no one.
