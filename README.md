# Model Peer

**Cross-model peer review for coding agents.**

Model Peer lets Claude Code, OpenAI Codex CLI, and Google Gemini CLI consult one
another as independent, read-only engineering peers.

```bash
model-peer ask claude "What edge cases am I missing?"
model-peer ask codex "Review this authentication design"
model-peer ask gemini "Challenge this migration plan"

model-peer review
```

The idea is intentionally small:

```text
Primary agent
    |
    +--> independent peer model
    |        |
    |        +--> advisory response
    |
    +--> primary agent evaluates the advice
```

The peer supplies evidence, not authority. Project rules and invariants still win.

**There is no chat between models.** Your agent is the hub. Each consultation spawns
another vendor's CLI, read-only, gets one answer, and exits. Nothing persists.

The peer starts in your current directory with read tools enabled, so you do not
paste code into the question — name files and symbols and let it look:

```bash
$ model-peer ask codex "What does stack_contains in bin/model-peer guard against?"
# codex reads bin/model-peer itself, then answers
```

Cross-model consultation becomes automatic once your agent has rules telling it when
to reach for a peer. See [Agent rules](#agent-rules).

## Why?

Coding agents can review their own work, but self-review is still self-review.
Model Peer makes it trivial to ask a different model:

> What am I missing?

`model-peer review` goes one step further. Every available reviewer receives the
same Git status + patch independently, without seeing the other models' conclusions.
Only after all reviews finish does a synthesizer reconcile the findings.

```text
              +--> Claude --+
              |             |
git changes --+--> Codex ---+--> synthesis
              |             |
              +--> Gemini --+
```

## Supported CLIs

| Provider | Command | Consultation safety |
|---|---|---|
| Anthropic Claude Code | `claude` | Plan mode, read-only inspection tools, stdin closed |
| OpenAI Codex CLI | `codex` | `--sandbox read-only`, ephemeral session, stdin closed |
| Google Gemini CLI | `gemini` | Plan mode, explicit deny policy, extensions disabled, stdin closed |

Model Peer does not collect or store credentials. Authentication stays with each
official CLI.

Official documentation:

- Claude Code: https://code.claude.com/docs/en/cli-reference
- OpenAI Codex CLI: https://developers.openai.com/codex/cli
- Gemini CLI: https://google-gemini.github.io/gemini-cli/docs/

## Install

### From a cloned repository

```bash
./install.sh
```

This installs:

```text
~/.local/bin/model-peer
~/.local/bin/ask-claude
~/.local/bin/ask-codex
~/.local/bin/ask-gemini
~/.local/bin/ai-review
```

The `ask-*` and `ai-review` commands are compatibility shortcuts. The primary
interface is `model-peer`.

For interactive dependency/auth setup:

```bash
./install.sh --setup
```

Model Peer never asks you to paste an API key or password into its installer.
Vendor login flows remain vendor-owned.

### One-line install after publishing

After you create the GitHub repository, replace `YOUR_GITHUB_USERNAME` below:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/model-peer/v0.1.0/install.sh | bash
```

Interactive setup:

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/model-peer/v0.1.0/install.sh | bash -s -- --setup
```

As with any remote shell installer, inspect it before piping it into a shell.

## Usage

### Ask one peer

```bash
model-peer ask claude "Review the caching strategy for failure modes"
model-peer ask codex "Check this authorization design for bypasses"
model-peer ask gemini "Compare these two queue architectures"
```

Prompts can also be piped:

```bash
printf '%s\n' "Review the current migration strategy" | model-peer ask codex
```

Let the peer consult a further model (see [Peer-chain depth](#peer-chain-depth)):

```bash
model-peer ask claude --depth 2 "Is this lock-free queue actually correct?"
```

Compatibility shortcuts:

```bash
ask-claude "..."
ask-codex "..."
ask-gemini "..."
```

### Cross-model review

Inside a Git repository:

```bash
model-peer review
```

Add a focus:

```bash
model-peer review "Focus on authorization, tenant isolation, and data leakage"
```

By default, every installed supported CLI participates. At least two models are
required. Reviewers run independently before synthesis.

Choose reviewers explicitly:

```bash
model-peer review --models claude,codex
model-peer review --models codex,gemini
model-peer review --models claude,codex,gemini
```

Choose the synthesizer:

```bash
model-peer review --synthesizer codex
```

The old command remains available:

```bash
ai-review
```

### Check setup

```bash
model-peer doctor
```

## Safety boundaries

### Codex

Codex consultation uses the known non-interactive pattern:

```bash
codex exec --sandbox read-only "<prompt>" </dev/null
```

Model Peer also adds `--ephemeral` and `--skip-git-repo-check` for standalone
consultation. `--sandbox read-only` prevents normal workspace writes, while
`</dev/null` prevents a nested invocation from waiting for input.

### Claude

Claude consultation runs non-interactively in Plan mode, with only `Read`, `Glob`,
and `Grep` exposed. Bash and file-edit tools are intentionally not provided, and
stdin is closed. This is the only provider whose boundary `--depth` changes: above
depth 1, `Bash` is added and auto-approved solely for `Bash(model-peer:*)`, which
is the narrowest grant Claude Code can express. The
[consultation broker](#consultation-broker) is intended to remove even this.

### Gemini

Gemini consultation starts in `--approval-mode plan`, which Gemini documents as a
strict read-only mode. Model Peer adds a temporary high-priority policy denying
`write_file`, `replace`, shell execution, and entering/exiting Plan mode. Extensions
are disabled with `-e none`, and stdin is closed. **These rules are unconditional**
— `--depth` never relaxes them, which is why a Gemini peer is always a leaf.

This is defense in depth, not a formal security boundary. Upstream CLI behavior can
change. Model Peer deliberately favors conservative consultation over autonomous
execution.

## Peer-chain depth

By default a peer answers on its own and may not consult anyone — one hop, then
back to you. `--depth N` lets the chain grow to `N` models:

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

### Depth is a limit, not a permission

Model Peer keeps two concepts separate, and the distinction is the whole security
model:

```text
depth       maximum recursion depth — how many models may participate
delegation  permission to initiate a further consultation, and by what mechanism
```

The invariant:

> Increasing depth may increase **how many models can participate**.
> Increasing depth must never increase **what a model can do to the host system**.

Nested consultation nevertheless requires limited outbound execution capability for
some providers. Model Peer restricts that capability as narrowly as the provider
permits, and where a provider cannot express a narrow enough restriction, the peer
stays a leaf rather than being handed a general shell.

| Provider | Nested consultation | What delegation actually grants |
|---|---|---|
| Claude | yes | `Bash` auto-approved **only** for `Bash(model-peer:*)` |
| Codex | yes | nothing new — `--sandbox read-only` already permits read-only execution |
| Gemini | **no** | its policy engine can only allow or deny `run_shell_command` wholesale |

Gemini is deliberately excluded. Lifting a blanket shell deny to open one door
would unlock the hallway, and an uneven provider matrix is more honest than
pretending every sandbox has equivalent primitives. A Gemini peer asked to
participate at depth > 1 answers as a leaf and says so on stderr:

```text
model-peer: Gemini cannot initiate nested consultation; answering as a leaf.
```

So the residual widening is exactly one thing: at depth > 1, a Claude peer holds
`Bash` scoped to a single command namespace. That is why nested consultation is
opt-in per invocation rather than on by default.

> **Roadmap.** This is a known implementation limitation, not the intended end
> state. Future versions will broker nested consultations through Model Peer itself
> — a peer will *request* a consultation from the parent process rather than
> executing `model-peer` — so peers remain fully read-only at every depth. See
> [Roadmap](#roadmap).

### Chain guards

Every nested call carries the active chain in `MODEL_PEER_STACK`, e.g.
`claude:codex`. Two independent guards apply, both exiting with code `64`:

**Depth limit** — the chain may not grow past `N`.

```text
depth 1:  Claude -> model-peer ask codex
                        X chain depth 1 already reached
```

**Self-consultation** — a model is never consulted by itself, at any depth. Cross-
model review that is secretly self-review would defeat the point.

```text
depth 5:  Claude -> Codex -> model-peer ask codex
                                 X Codex cannot consult itself
```

The synthesizer in `model-peer review` is always a leaf: it never consults anyone,
regardless of `--depth`. `review` run from a normal shell starts a fresh chain, but
`review` run from inside a peer chain inherits it and cannot escape the guard.

The advisory prompts also tell peers whether they may delegate, and how much depth
remains. The environment marker is the backstop.

## Agent rules

Cross-talk only feels automatic once your agent knows when to reach for a peer.
[`examples/AGENTS.md`](examples/AGENTS.md) is a shared template for all three
ecosystems. Install it as one file under three names so the rules can never drift:

```bash
cp examples/AGENTS.md /path/to/your/project/AGENTS.md
cd /path/to/your/project
ln -sfn AGENTS.md CLAUDE.md
ln -sfn AGENTS.md GEMINI.md
```

`AGENTS.md` is read by Codex, `CLAUDE.md` by Claude Code, and `GEMINI.md` by Gemini
CLI. Relative symlinks survive `git clone`. This repository uses that layout for its
own rules.

The template emphasizes that peer advice is advisory and that project-specific
invariants override generic recommendations.

## Authentication

### Claude Code

```bash
claude auth login
```

### Codex

```bash
codex login
```

### Gemini

Run Gemini interactively and choose the Google login flow:

```bash
gemini
```

Gemini also supports `GEMINI_API_KEY` and Vertex AI authentication. Model Peer does
not read or persist those credentials.

## Dependency installation

`./install.sh` installs only Model Peer by default.

`./install.sh --setup` can offer to install missing CLIs. The installer prefers
official/current installation methods available on the machine and then leaves
authentication to each vendor.

## Environment variables

```text
MODEL_PEER_REVIEWERS        default review panel, e.g. claude,codex,gemini
MODEL_PEER_SYNTHESIZER      default synthesis model
MODEL_PEER_MAX_DEPTH        default peer-chain depth limit, 1-10 (default 1)
MODEL_PEER_MAX_DIFF_BYTES   patch bytes embedded in review prompts (default 500000)
MODEL_PEER_BIN_DIR          install directory override
MODEL_PEER_STACK            managed by Model Peer; the active peer chain
```

Example:

```bash
MODEL_PEER_REVIEWERS=codex,gemini model-peer review
```

## Uninstall

```bash
./uninstall.sh
```

This removes Model Peer commands only. It does not uninstall vendor CLIs or touch
their credentials/configuration.

## Development

```bash
make test     # smoke tests against stub CLIs
make lint     # syntax check, plus shellcheck when installed
make sync     # regenerate install.sh's embedded copy of bin/model-peer
```

Smoke tests use stub CLIs. They do not contact Anthropic, OpenAI, or Google and do
not consume model usage.

`install.sh` must work standalone when piped from `curl`, so it embeds a verbatim
copy of `bin/model-peer`. Run `make sync` after changing that script; `make test`
refuses to run while the two are out of step.

## Roadmap

### Consultation broker

Today a peer that is permitted to consult another model does so by executing
`model-peer` itself, which requires granting it outbound execution capability. The
intended architecture inverts that: Model Peer owns the recursion, and a peer
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

The parent already knows the current depth, the maximum, the models already
visited, the read-only requirements, and the recursion policy, so it can adjudicate
centrally:

```text
Claude requests Gemini
Current depth: 1
Maximum: 2
Gemini not already in call chain
-> allowed
```

Claude never needs `Bash` at all, which restores the strongest possible guarantee:

> Peers remain read-only regardless of consultation depth.

Once recursion is brokered centrally, richer policy becomes cheap to enforce —
per-model call budgets, total consultation budgets, and full cycle detection rather
than the self-consultation check that is possible today:

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

## Design principles

1. **Independent review** — reviewers start from the same evidence, not each other's opinions.
2. **Read-only consultation** — asking for advice should not hand over write authority.
3. **Primary-agent ownership** — peer output is evidence, not a command.
4. **Project rules win** — local invariants outrank generic model advice.
5. **No credential handling** — authentication stays with official vendor CLIs.
6. **Bounded chains** — depth is capped and opt-in, and no model ever consults itself.
7. **Review before autonomy** — v0.1.0 analyzes; it does not automatically apply fixes.

## License

MIT. See [`LICENSE`](LICENSE).

## Disclaimer

Model Peer is an independent open-source project. It is not affiliated with,
endorsed by, or sponsored by Anthropic, OpenAI, or Google. Claude, Codex, and
Gemini are trademarks of their respective owners.
