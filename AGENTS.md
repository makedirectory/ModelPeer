# AGENTS.md

This file provides guidance to coding agents working in this repository. It is the
single source of truth for all three ecosystems: `CLAUDE.md` (Claude Code) and
`GEMINI.md` (Gemini CLI) are symlinks to this file. Edit `AGENTS.md`; never replace
a symlink with a copy.

## What this is

Model Peer is a cross-model peer-review bridge. It lets one coding agent consult a
different vendor's CLI (`claude`, `codex`, `gemini`) as an independent, read-only
engineering peer, and fans a Git diff out to several models for independent review
before a synthesizer reconciles the findings.

There is no build step, no dependencies, and no runtime beyond Bash and the vendor
CLIs. The entire product is one Bash script.

## Commands

```bash
make test     # smoke tests against stub CLIs; runs check-sync first
make lint     # bash -n over every script, plus shellcheck when installed
make sync     # regenerate install.sh's embedded copy of bin/model-peer
```

The docs site lives in `documentation/` (Docusaurus, deployed to GitHub Pages by
`.github/workflows/docs.yml`). It is the only part of the repo with Node
dependencies; the tool itself stays dependency-free.

```bash
cd documentation && npm install && npm run build   # build fails on broken links
```

User-facing behavior changes need the matching page updated under `documentation/docs/`,
not only the README. The README is the entry point; the site is the reference.

`tests/smoke.sh` is a single linear script with no test-case selection. To run one
assertion in isolation, copy its block into a scratch file that reuses the stub
setup from the top of `tests/smoke.sh`. The stubs log invocations to
`$MODEL_PEER_TEST_LOG` and never contact a real model or consume usage.

Target Bash 3.2 — that is what macOS ships, and CI runs macOS. Avoid `declare -A`,
`${var^^}`, `read -t` with fractional seconds, and bare `"${arr[@]}"` on possibly
empty arrays (use `${arr[@]+"${arr[@]}"}`).

## Architecture

### The duplication invariant

`install.sh` must work standalone when piped from `curl`, so it carries a verbatim
copy of `bin/model-peer` inside a `<<'__MODEL_PEER__'` heredoc. **Any change to
`bin/model-peer` must be followed by `make sync`.** `make check-sync` fails the
build otherwise, and `tests/smoke.sh` independently installs and `cmp`s the result.
This is the single easiest way to break the repo.

`examples/AGENTS.md` is the second copy: it is generated from
`model-peer rules print`, so any change to the rules text needs `make sync` too.
`make check-sync` and `tests/smoke.sh` both diff it.

`bin/ask-claude`, `bin/ask-codex`, `bin/ask-gemini`, and `bin/ai-review` are
four-line compatibility shims that `exec` into `model-peer`; they are also embedded
in `install.sh`.

### Command structure

`bin/model-peer` dispatches from `main` into `cmd_ask`, `cmd_review`,
`cmd_rules_install`, `cmd_rules`, or `cmd_doctor`. Both consultation paths funnel
through `run_provider`, which is the
single chokepoint that enforces the guards, pushes the chain, and computes the
depth budget before delegating to `run_claude` / `run_codex` / `run_gemini`. Put
policy in `run_provider`, not in the per-provider runners — those exist only to
translate a prompt plus a depth budget into one vendor's CLI flags.

### The peer chain

`MODEL_PEER_STACK` is a colon-separated chain of the models already active
(`claude:codex`). Its length is the current depth. `run_provider` enforces two
independent guards via `check_chain`:

1. The chain may not exceed the depth limit (`--depth`, then
   `MODEL_PEER_MAX_DEPTH`, then 1; ceiling 10). Exceeding it exits `64`.
2. A model may never be consulted by itself, at any depth. Also exits `64`.

### Depth vs. delegation

These are two separate concepts and must stay separate:

```text
depth       maximum recursion depth — a limit, never a permission
delegation  permission to initiate a further consultation, and the mechanism
```

The invariant to preserve in any change here:

> Increasing depth may increase how many models can participate.
> Increasing depth must never increase what a model can do to the host system.

`remaining = max_depth - new_depth` is only a *budget*. `resolve_delegation` turns
that budget into an actual permission, and returns `none` unless the provider can
hold the permission narrowly (`provider_delegation_support`):

- `claude` → `namespaced`: `Bash` auto-approved only for `Bash(model-peer:*)`
- `codex` → `sandboxed`: read-only sandbox already permits it; **no flags change**
- `gemini` → `unsupported`: its policy engine only allows or denies
  `run_shell_command` wholesale, so it is always a leaf and its deny rules are
  unconditional

A depth budget a provider cannot safely hold is reported on stderr via `note`,
never silently converted into a wider sandbox. If you add a provider, decide its
delegation support explicitly; defaulting to `unsupported` is the safe answer.

`consultation_prompt` takes the resolved delegation, not the raw budget — a peer
that may not delegate is told so and sees `Remaining peer-chain depth: 0`, even if
depth remained. Prompt and capability must never disagree.

The long-term fix is a consultation broker (see the README roadmap): peers request
a consultation from the parent process instead of executing `model-peer`, removing
the last capability grant. Changes that deepen the current shell-based approach are
moving away from that.

`cmd_review` deliberately does not overwrite `MODEL_PEER_STACK`. At top level the
chain is empty, so each reviewer starts fresh; a review launched from inside a peer
chain inherits that chain and cannot escape the guard. The synthesizer is forced to
be a leaf by passing it a depth limit of exactly `stack_depth + 1`.

### Repo rules (`init` / `rules`)

`model-peer init` writes the consultation rules into a developer's project. The
rules text lives in `rules_body` as a quoted heredoc with `@@SPEC@@`, `@@PEER_A@@`,
and `@@PEER_B@@` placeholders substituted afterwards — quoted so the Markdown
backticks stay literal, substituted with `#` as the sed delimiter because the peer
spec contains `|`.

Two invariants:

1. **Only write paths a vendor CLI actually loads.** Claude Code globs
   `.claude/rules/**/*.md` and reads `CLAUDE.md`; Codex reads `AGENTS.md` and
   `AGENTS.override.md`; Gemini reads `GEMINI.md`. Codex and Gemini have no
   per-repo rules directory — `.codex/rules/*.md` and `.gemini/global_rules.md`
   are inert, since Codex's extra context filenames come from the global
   `project_doc_fallback_filenames` key. Verify against the shipping CLI before
   adding a path.
2. **Never rewrite content outside the markers.** Everything between
   `<!-- BEGIN MODEL PEER RULES -->` and `<!-- END MODEL PEER RULES -->` is
   Model Peer's; everything else belongs to the developer. `--force` relinks
   symlinks and replaces the slash command, and still never touches a regular
   file's own content.

The profile (`shared`, `claude`, `codex`, `gemini`) is recorded in the managed
header comment, which is how `rules check` knows what to compare a file against
without being told the layout. Changing the header format breaks `check` on every
already-installed repo.

### Provider safety contracts

Each runner is a read-only consultation contract, tightened per vendor:

| Provider | Baseline | With delegation |
|---|---|---|
| `claude` | plan mode, `--tools Read,Glob,Grep`, stdin closed | adds `Bash`, auto-approved only for `Bash(model-peer:*)` |
| `codex` | `--sandbox read-only --ephemeral`, stdin closed | identical flags; only the prompt differs |
| `gemini` | plan mode, generated deny policy, `-e none`, stdin closed | n/a — never delegates |

Gemini's policy TOML is generated per call into a temp dir and removed afterwards.
Deny rules for `write_file`, `replace`, `run_shell_command`, `enter_plan_mode`, and
`exit_plan_mode` are unconditional — the Plan-mode pair matters because exiting plan
mode is how a peer would escape read-only. The smoke-test stub copies the generated
policy into the log so these rules can be asserted at every depth.

Every runner closes stdin with `</dev/null`. A nested CLI that inherits a live
stdin can hang forever waiting for input.

## Conventions

- Exit codes carry meaning: `2` usage/validation, `64` chain guard refusal, `127`
  missing dependency. Preserve them; the tests assert on them.
- Progress and diagnostics go to stderr; only model output goes to stdout, so
  `model-peer ask ... | ...` stays pipeable.
- Prompts are heredocs at the top of their command's section. When changing what a
  peer is permitted to do, change the prompt and the tool grant together.
- New behavior needs a `tests/smoke.sh` assertion. The stubs make this nearly free.

## Cross-model consultation

This project is its own best user. Codex and Gemini are available as independent
reviewers; consult them read-only:

```bash
model-peer ask codex "<focused question>"
model-peer ask gemini "<focused question>"
```

Worth a peer's time: architecture decisions, security-sensitive changes to the
sandbox contracts above, difficult debugging, reviewing a proposed implementation,
checking assumptions, comparing approaches.

Peer models are **advisory**. Evaluate their responses independently before acting.
Project-specific rules and invariants take precedence over generic advice from a
reviewing model. When a peer materially influences a decision, say which model you
asked and whether you accepted or rejected the advice, rather than presenting its
output as a conclusion.

Do not ask a peer to invoke another model unless you deliberately raised `--depth`.
The chain guard is the backstop, not the primary rule.
