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
stdin is closed.

### Gemini

Gemini consultation starts in `--approval-mode plan`, which Gemini documents as a
strict read-only mode. Model Peer adds a temporary high-priority policy denying
`write_file`, `replace`, shell execution, and entering/exiting Plan mode. Extensions
are disabled with `-e none`, and stdin is closed.

This is defense in depth, not a formal security boundary. Upstream CLI behavior can
change. Model Peer deliberately favors conservative consultation over autonomous
execution.

## Recursion protection

Every nested call carries a `MODEL_PEER_STACK` marker. If a model already exists in
the call chain, Model Peer refuses to invoke it again and exits with code `64`.

```text
Claude -> model-peer ask codex -> Codex -> model-peer ask claude
                                      X Claude is already in the stack
```

The advisory prompts also tell models not to invoke another model. The environment
marker is the backstop.

## Agent rules

Examples are included for all three ecosystems:

- [`examples/CLAUDE.md`](examples/CLAUDE.md)
- [`examples/AGENTS.md`](examples/AGENTS.md)
- [`examples/GEMINI.md`](examples/GEMINI.md)

The Claude example intentionally emphasizes that peer advice is advisory and that
project-specific invariants override generic recommendations.

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
MODEL_PEER_MAX_DIFF_BYTES   patch bytes embedded in review prompts (default 500000)
MODEL_PEER_BIN_DIR          install directory override
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
make test
make lint
```

Smoke tests use stub CLIs. They do not contact Anthropic, OpenAI, or Google and do
not consume model usage.

## Design principles

1. **Independent review** — reviewers start from the same evidence, not each other's opinions.
2. **Read-only consultation** — asking for advice should not hand over write authority.
3. **Primary-agent ownership** — peer output is evidence, not a command.
4. **Project rules win** — local invariants outrank generic model advice.
5. **No credential handling** — authentication stays with official vendor CLIs.
6. **No recursive loops** — prompts and `MODEL_PEER_STACK` both guard against cross-calls.
7. **Review before autonomy** — v0.1.0 analyzes; it does not automatically apply fixes.

## License

MIT. See [`LICENSE`](LICENSE).

## Disclaimer

Model Peer is an independent open-source project. It is not affiliated with,
endorsed by, or sponsored by Anthropic, OpenAI, or Google. Claude, Codex, and
Gemini are trademarks of their respective owners.
