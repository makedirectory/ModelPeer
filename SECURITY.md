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

## Reporting a vulnerability

Please report security-sensitive issues **privately**, rather than opening a public
issue with exploit details.

Use GitHub's private vulnerability reporting:

1. Go to the [Security tab](https://github.com/makedirectory/ModelPeer/security).
2. Choose **Report a vulnerability**.

That opens a private channel visible only to the maintainers. Expect an initial
response within a week.

Please include the Model Peer version (`model-peer --version`), the vendor CLI and
version involved, and the smallest reproduction you can manage.

### Scope

Most valuable are issues that break a documented boundary — a peer that writes to
the workspace, escapes Plan mode or the read-only sandbox, obtains execution beyond
what its delegation permits, or evades the chain guards.

Model Peer's controls depend on upstream CLI behavior and are not a formal sandbox.
Reports that amount to "the vendor CLI can be prompted into doing something" are
better filed with that vendor, though we still want to know if Model Peer's defaults
make it materially easier.
