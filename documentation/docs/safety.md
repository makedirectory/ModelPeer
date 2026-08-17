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

These flags do not vary with `--depth`. Until v0.7 they did: a Claude peer allowed to
consult another model was given `Bash`, auto-approved solely for
`Bash(model-peer _delegate:*)`, because it had to run Model Peer itself to reach one.
The [consultation broker](depth#what-changed-in-v07) removed the need, so no
provider receives execution at any depth. See [Peer-chain depth](depth).

## Codex

```bash
codex exec --sandbox read-only --ephemeral --skip-git-repo-check "<prompt>" </dev/null
```

`--sandbox read-only` prevents workspace writes. `--ephemeral` avoids persisting a
session, and `--skip-git-repo-check` allows standalone consultation outside a repo.

The read-only sandbox does permit read-only command execution, which is why a Codex
peer could in principle run `model-peer` even though nothing asks it to. Model Peer
marks every provider process as brokered via `MODEL_PEER_BROKERED` and refuses
`ask`, `review`, `init`, `update`, `trust`, and `doctor --probe` when it sees that
marker. The flags themselves do not vary with depth, and the test suite asserts that.

:::caution A guardrail, not a boundary
The marker is an environment variable, so a peer that can execute commands can
clear it. It reliably stops the *inadvertent* case — a model that reaches for a
familiar command — which is the case that actually occurs. It does not stop a
determined or prompt-injected peer, and nothing inside Model Peer can: preventing a
sandbox that permits command execution from running a program on `PATH` is not
something the program itself can enforce.

What that peer would gain is a consultation Model Peer did not authorise — spending
model usage, escaping the deadline, and stepping outside the panel-independence rule.
It gains no write access: whatever it starts is launched by the same read-only
contracts described on this page. Treat the panel rules as protecting the *integrity
of a review you asked for*, not as containment of a hostile model.
:::

## Gemini

```bash
env -u GEMINI_CLI_TRUST_WORKSPACE \
  gemini --approval-mode plan --policy <generated.toml> -e none --skip-trust \
  -p "<prompt>" </dev/null
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

### Why `--skip-trust`

Gemini's folder-trust gate refuses to work in a directory it has not been told to
trust. Headlessly that refusal is **silent**: it exits `0` having produced nothing,
which a review panel would otherwise read as "this reviewer found no issues".

Model Peer trusts the workspace for the session so a consultation is not a silent
no-op. Plan mode, the unconditional deny policy, and `-e none` are passed explicitly
on the command line and apply either way, so the read-only tool contract does not
depend on the trust gate.

### Why the trust variable is cleared

`GEMINI_CLI_TRUST_WORKSPACE=true` is documented as the headless equivalent of
`--skip-trust`. It is not equivalent. The flag satisfies the gate; the variable also
enables MCP servers declared in the workspace's own `.gemini/settings.json`, and
Gemini starts those as local subprocesses during tool discovery.

That happens **before any policy decision and without a model turn**, which is the
part worth internalising: the deny policy governs tool *calls*, not server *startup*.
No rule at priority 999 reaches it, and neither does Plan mode.

Under `model-peer review` the consequence is direct — a repository being reviewed
could specify a command that runs on your machine, in the one workflow whose whole
premise is reading code you do not trust. Model Peer therefore clears the variable
rather than inheriting it, so `--skip-trust` is the single trust mechanism in play
instead of one of two that disagree.

If the variable is not set in your environment, this never applied to you. It is
cleared unconditionally so that stays true regardless of how Model Peer is invoked.

This was found and fixed in v0.6.1, verified against Gemini CLI 0.46.0 with and
without the fix. The smoke suite asserts the variable does not reach the CLI.

The flag is feature-detected from `gemini --help`, so builds that predate it are
invoked exactly as before.

As a second line of defense against silent failure of any kind, a reviewer that
returns zero bytes is treated as a failure rather than as an empty finding list.

**These rules are unconditional.** `--depth` never relaxes them. Before v0.7 that
came at a cost — Gemini could not participate in a consultation chain at all,
because reaching one meant running a command and its policy engine cannot scope
`run_shell_command` to a single program. Since the broker performs consultations on
a peer's behalf, Gemini participates on the same terms as everyone else with the
deny rules still in force. The Plan-mode pair matters specifically because exiting
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
mode or the read-only sandbox, obtains execution of any kind, causes a consultation
the broker did not authorise, or evades the chain guards.
