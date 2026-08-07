# Model Peer v0.1.0

Initial public release.

Model Peer gives Claude Code, Codex CLI, and Gemini CLI a small common interface for
independent engineering consultation:

```bash
model-peer ask claude "..."
model-peer ask codex "..."
model-peer ask gemini "..."
model-peer review
```

`model-peer review` runs all installed reviewers independently against the same Git
status + patch, then asks one model to synthesize the findings. It is review-only;
no fixes are applied.

Safety defaults are intentionally conservative: Claude runs in Plan mode with
read-only inspection tools, Codex runs in a read-only sandbox with stdin closed,
and Gemini runs in Plan mode with an additional deny policy and extensions disabled.

This release is intentionally small. The goal is to test whether cross-model peer
review is useful enough to become a normal part of coding-agent workflows.
