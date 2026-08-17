---
id: install
title: Install
sidebar_position: 2
---

# Install

Model Peer is a single Bash script with no runtime dependencies beyond the vendor
CLIs you choose to use.

## One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/makedirectory/ModelPeer/v0.7.1/install.sh | bash
```

Interactive setup, which can offer to install missing CLIs:

```bash
curl -fsSL https://raw.githubusercontent.com/makedirectory/ModelPeer/v0.7.1/install.sh | bash -s -- --setup
```

As with any remote shell installer, inspect it before piping it into a shell.

## From a cloned repository

```bash
git clone https://github.com/makedirectory/ModelPeer.git
cd ModelPeer
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

Model Peer never asks you to paste an API key or password into its installer.
Vendor login flows remain vendor-owned.

Override the install directory with `MODEL_PEER_BIN_DIR` or `--bin-dir`:

```bash
./install.sh --bin-dir /usr/local/bin
```

## Install the vendor CLIs

At least one is required for `ask`; at least two for `review`.

| Provider | Install | Documentation |
|---|---|---|
| Claude Code | [Setup guide](https://code.claude.com/docs/en/setup) | [CLI reference](https://code.claude.com/docs/en/cli-reference) |
| OpenAI Codex CLI | [Codex CLI](https://developers.openai.com/codex/cli) | [Docs](https://developers.openai.com/codex/cli) |
| Gemini CLI | [Get started](https://google-gemini.github.io/gemini-cli/docs/get-started/) | [Docs](https://google-gemini.github.io/gemini-cli/docs/) |

`./install.sh --setup` can offer to install missing CLIs, preferring official
installation methods available on the machine, then leaving authentication to each
vendor.

## Authenticate

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

## Verify

```bash
model-peer doctor
```

`doctor` reports which CLIs are installed, whether authentication looks available,
the safety defaults in force, the per-provider nested-consultation matrix, the
effective peer-chain depth limit and the longest chain actually reachable, and
which Model Peer skills the project you are standing in has installed.

It reads configuration only, so it costs nothing and can be wrong about
credentials a CLI keeps somewhere it cannot see. To settle a question rather than
infer an answer, `model-peer doctor --probe` runs one real consultation per CLI —
see [the reference](reference#doctor---probe).

## Set up a project

Installing Model Peer gives you the command. It does not yet give the coding agent
in a repository any reason to use it. Run this once per project:

```bash
cd ~/code/your-project
model-peer init
```

That installs a `cross-model-review` agent skill where Claude Code, Codex, and
Gemini each look for one, plus a `/peer-review` slash command for Claude Code. It
never touches your `AGENTS.md`, `CLAUDE.md`, or `GEMINI.md`. Commit the result and
your teammates get it too.

→ [In your workflow](workflow)

## Uninstall

```bash
./uninstall.sh
```

This removes Model Peer commands only. It does not uninstall vendor CLIs, touch
their credentials or configuration, or remove skills from your projects — those
are committed to your repositories.
