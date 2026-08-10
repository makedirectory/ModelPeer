---
id: safety
title: Safety boundaries
sidebar_position: 7
---

# Safety boundaries

Model Peer's premise is that asking for advice should not hand over write authority.
Each provider is launched with the most conservative non-interactive configuration
it supports.

:::warning Defense in depth, not a formal sandbox
These controls depend on upstream CLI behavior, which can change. Model Peer is not
a security boundary for untrusted repositories or prompts, and should not be your
only isolation layer.
:::

## Common to every provider

- **stdin is closed** with `</dev/null`. A nested CLI that inherits a live stdin can
  hang forever waiting for input.
- **No writes.** No provider is given file-editing tools.
- **No general shell.** The only execution any peer can receive is scoped to the
  `model-peer` command namespace, and only where a provider can express that scope.
- **Chain guards** via `MODEL_PEER_STACK`: a depth limit, and no model consulting
  itself.

## Claude

```bash
claude -p --permission-mode plan --tools "Read,Glob,Grep" \
  --disable-slash-commands --no-session-persistence "<prompt>" </dev/null
```

Runs non-interactively in Plan mode with only `Read`, `Glob`, and `Grep` exposed.
Bash and file-edit tools are intentionally not provided.

This is the only provider whose boundary `--depth` changes. Above depth 1, `Bash` is
added and auto-approved solely for `Bash(model-peer:*)` — the narrowest grant Claude
Code can express. See [Peer-chain depth](depth#the-residual-widening-stated-plainly).

## Codex

```bash
codex exec --sandbox read-only --ephemeral --skip-git-repo-check "<prompt>" </dev/null
```

`--sandbox read-only` prevents workspace writes. `--ephemeral` avoids persisting a
session, and `--skip-git-repo-check` allows standalone consultation outside a repo.

Codex is the one provider where delegation grants **no new capability at all** — the
read-only sandbox already permits read-only execution, so the CLI flags are byte
identical with and without delegation. Only the prompt differs. Model Peer's test
suite asserts this.

## Gemini

```bash
gemini --approval-mode plan --policy <generated.toml> -e none -p "<prompt>" </dev/null
```

`--approval-mode plan` is documented upstream as a strict read-only mode. Model Peer
adds a temporary high-priority deny policy, generated per call into a temp directory
and removed afterwards:

```toml
[[rule]]
toolName = "write_file"
decision = "deny"
priority = 999

[[rule]]
toolName = "replace"
decision = "deny"
priority = 999

[[rule]]
toolName = "run_shell_command"
decision = "deny"
priority = 999

[[rule]]
toolName = "exit_plan_mode"
decision = "deny"
priority = 999

[[rule]]
toolName = "enter_plan_mode"
decision = "deny"
priority = 999
```

Extensions are disabled with `-e none`.

**These rules are unconditional.** `--depth` never relaxes them, which is why a
Gemini peer is always a leaf. The Plan-mode pair matters specifically because exiting
Plan mode is how a peer would otherwise escape read-only.

## Credentials

Model Peer does not read, store, prompt for, or transmit credentials. Authentication
stays entirely with the official vendor CLIs, and the installer never asks you to
paste an API key or password.

## Reporting a vulnerability

Report privately through
[GitHub's private vulnerability reporting](https://github.com/makedirectory/ModelPeer/security)
rather than opening a public issue with exploit details. Most valuable are issues
that break a documented boundary — a peer that writes to the workspace, escapes Plan
mode or the read-only sandbox, obtains execution beyond what its delegation permits,
or evades the chain guards.
