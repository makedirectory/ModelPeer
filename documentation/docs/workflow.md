---
id: workflow
title: In your workflow
sidebar_position: 4
---

# In your workflow

Installing Model Peer globally gives *you* a command. It does not give your coding
agent a habit. Until the agent working in a repository knows that peers exist and
when reaching for one is worth the wait, nothing changes — you will remember
`model-peer` for the first two days and then forget it.

Closing that gap is one command, run once per repository:

```bash
cd ~/code/your-project
model-peer init
```

## What `init` writes

By default, one shared rules file that all three CLIs read:

```text
AGENTS.md                        the rules (Codex reads this)
CLAUDE.md -> AGENTS.md           symlink (Claude Code)
GEMINI.md -> AGENTS.md           symlink (Gemini CLI)
.claude/commands/peer-review.md  the /peer-review slash command
```

Git stores those symlinks as symlinks (mode `120000`), so they survive `git clone`
and cannot drift apart. Commit all four and your teammates get the same behavior
without doing anything.

Prefer one tailored file per CLI — each addressing that model directly and naming
its two peers?

```bash
model-peer init --split
```

```text
.claude/rules/cross-model-consultation.md    "You are Claude Code. Codex and Gemini are…"
AGENTS.md                                    "You are Codex. Claude and Gemini are…"
GEMINI.md                                    "You are Gemini. Claude and Codex are…"
```

Each harness loads only its own file, so a developer using Gemini sees the Gemini
rules and never the Claude ones. Use whichever CLIs you like; install all three
files and every teammate is covered.

:::note Paths that actually get loaded
`init` only writes files the vendor CLIs genuinely read: Claude Code globs
`.claude/rules/**/*.md` and reads `CLAUDE.md`, Codex reads `AGENTS.md` (and
`AGENTS.override.md`), and Gemini reads `GEMINI.md`.

There is no per-repository rules directory for Codex or Gemini. A
`.codex/rules/*.md` or `.gemini/global_rules.md` file looks tidy and is never
loaded — Codex's extra context filenames come from the global
`project_doc_fallback_filenames` config key, not from the repo. `init` will not
create those paths.
:::

`init` never overwrites your work. Its output lives between
`<!-- BEGIN MODEL PEER RULES -->` and `<!-- END MODEL PEER RULES -->`; everything
outside those markers is left exactly as it was. If you already have an `AGENTS.md`
full of project conventions, the block is appended below them. Re-running updates
the block in place, so upgrading Model Peer and re-running `init` is safe.

Preview before committing to anything:

```bash
model-peer init --dry-run
```

## The three moments it changes

### 1. Mid-task, when the agent is unsure

The rules tell your agent to consult a peer before an architecture decision, on a
bug that has outlived two hypotheses, on anything security-sensitive, and when it
is choosing between two approaches. In practice you see this in the transcript:

```text
> This touches the tenant isolation check, so I'll get an independent read
  before I commit to it.

  model-peer ask codex "In src/db/scope.ts, can withTenant() be bypassed when
  the caller passes an already-scoped query builder?"

  Codex flagged that the guard is skipped for pre-scoped builders. That is
  real — I checked scope.ts:88. Fixing it before continuing.
```

The value is not that Codex was right. It is that the agent said *which model it
asked* and *whether it accepted the advice*, so you can audit the reasoning instead
of taking a laundered opinion.

### 2. Before a pull request

```bash
model-peer review "Focus on the tenant isolation changes"
```

Every installed model reviews the same diff without seeing the others'
conclusions, then a synthesizer reconciles them. This is the one to run before you
open a PR, and again after any change to security-sensitive code.

Because reviewers cannot anchor on each other, agreement between them is real
signal — and the synthesizer is explicitly told not to accept a claim merely
because several models repeated it.

### 3. From inside Claude Code

`init` also installs a slash command, so you never have to leave the session:

```text
/peer-review
/peer-review auth flow and session rotation
```

It runs `model-peer review`, reports the synthesized findings ungarnished, and
then says for each one whether it agrees and why. It will not apply fixes unless
you ask.

Skip it with `model-peer init --no-command`.

## Keeping the rules current

Model Peer's rules text changes between versions. Verify a project is up to date:

```bash
model-peer rules check
```

It exits `0` when every managed block matches what your installed version would
write, and `1` when a block is missing or stale. It works with either layout — the
profile is recorded in each block, so it checks whatever is actually installed.

In CI:

```yaml
- name: Check agent rules
  run: |
    curl -fsSL https://raw.githubusercontent.com/makedirectory/ModelPeer/v0.3.0/install.sh | bash
    ~/.local/bin/model-peer rules check
```

When it fails, `model-peer init` repairs it.

## Rolling it out to a team

1. One person runs `model-peer init` and commits the result.
2. Everyone else runs the [installer](install) once, for the `model-peer` command
   itself. The rules are already in the repo.
3. Nobody needs the same CLIs. `model-peer doctor` reports what each machine has,
   and `ask` needs one peer while `review` needs two.

Costs are worth stating plainly: every consultation is a real model call against
the developer's own vendor account, and a full `review` across three models takes
minutes. The shipped rules tell agents not to consult for anything answerable by
reading the code, which is the difference between a useful habit and a bill.

## If you would rather not run `init`

Print the rules and paste them wherever you like:

```bash
model-peer rules print                     # the shared block
model-peer rules print --profile gemini    # tailored for Gemini
model-peer rules print --command           # the /peer-review slash command
```

The same text ships as
[`examples/AGENTS.md`](https://github.com/makedirectory/ModelPeer/blob/main/examples/AGENTS.md),
which is generated from `rules print` so the two can never disagree.

## Next

- [Agent rules](agent-rules) — what the rules actually say, and why
- [Usage](usage) — `ask`, `review`, and `doctor` in full
- [CLI reference](reference) — every flag
