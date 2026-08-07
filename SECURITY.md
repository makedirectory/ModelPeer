# Security

Model Peer is designed for **consultation**, not autonomous execution.

- Claude Code is launched in Plan mode with only read-oriented inspection tools.
- Codex CLI is launched with `--sandbox read-only` and stdin redirected from `/dev/null`.
- Gemini CLI is launched in Plan mode with a temporary policy that denies write,
  replace, shell, and Plan-mode transition tools; extensions are disabled.
- Nested calls carry `MODEL_PEER_STACK` to block model recursion.

These controls depend on upstream CLI implementations and are not a formal sandbox
or security guarantee. Do not use Model Peer as the sole isolation boundary for
untrusted repositories or prompts.

Please report security-sensitive issues privately to the repository owner rather
than opening a public issue with exploit details.
