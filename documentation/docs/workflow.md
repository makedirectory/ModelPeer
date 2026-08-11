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

Only files Model Peer owns:

```text
.claude/rules/cross-model-consultation.md   the rules (Claude Code loads it)
.claude/commands/peer-review.md             the /peer-review slash command
```

**Your `AGENTS.md`, `CLAUDE.md`, and `GEMINI.md` are not touched**, and no symlinks
are created. Commit the two files above and your teammates get the same behavior.

:::note Why only Claude Code, by default
Claude Code is the only one of the three with a per-repository rules directory. It
globs `.claude/rules/**/*.md`, so Model Peer can add a file of its own and be
loaded automatically without editing anything of yours.

Codex and Gemini have no equivalent. The only per-repo files they read are
`AGENTS.md` (Codex, plus `AGENTS.override.md`) and `GEMINI.md` (Gemini) — and those
are yours. A `.codex/rules/*.md` or `.gemini/global_rules.md` file looks like it
should work and is never loaded; Codex's extra context filenames come from the
global `project_doc_fallback_filenames` config key, not from the repository.

So wiring up Codex and Gemini means writing into your files, and Model Peer will
not do that unless you ask for it by name.
:::

## Including Codex and Gemini

Name them explicitly:

```bash
model-peer init --agents claude,codex,gemini
```

```text
  current   .claude/rules/cross-model-consultation.md
  appended  AGENTS.md (your content above is untouched)
  created   GEMINI.md
  current   .claude/commands/peer-review.md (/peer-review)
```

Each file is tailored to the model that reads it — the Codex block opens "You are
Codex. Claude and Gemini are installed alongside you…" — so every harness sees
rules addressed to it and never to the others.

Even opted in, `init` confines itself to a marked region:

```markdown
# My project

Run `make test` before committing.

<!-- BEGIN MODEL PEER RULES -->
...managed content...
<!-- END MODEL PEER RULES -->
```

Everything outside those markers is left exactly as it was, on every re-run. An
existing `AGENTS.md` gets the block appended below your own rules; upgrading Model
Peer and re-running updates the block in place.

If `GEMINI.md` is a symlink to `AGENTS.md` — a common way to share one file across
CLIs — `init` refuses rather than writing through it, since that would rewrite the
linked file under a profile meant for a different model.

## Staying fully in control

If you would rather place the text yourself, `init` is optional. Print it and put
it wherever you like:

```bash
model-peer rules print --profile codex >> AGENTS.md
model-peer rules print --profile gemini >> GEMINI.md
model-peer rules print                       # model-agnostic version
model-peer rules print --command             # the /peer-review slash command
```

Preview what `init` would do without writing anything:

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
    curl -fsSL https://raw.githubusercontent.com/makedirectory/ModelPeer/v0.4.0/install.sh | bash
    ~/.local/bin/model-peer rules check
```

When it fails, `model-peer init` repairs it.

## Rolling it out to a team

1. One person runs `model-peer init` and commits the result. If your team uses
   Codex or Gemini too, that is the moment to decide whether to add
   `--agents claude,codex,gemini` and take the managed block in `AGENTS.md` and
   `GEMINI.md`.
2. Everyone else runs the [installer](install) once, for the `model-peer` command
   itself. The rules are already in the repo.
3. Nobody needs the same CLIs. `model-peer doctor` reports what each machine has,
   and `ask` needs one peer while `review` needs two.

Costs are worth stating plainly: every consultation is a real model call against
the developer's own vendor account, and a full `review` across three models takes
minutes. The shipped rules tell agents not to consult for anything answerable by
reading the code, which is the difference between a useful habit and a bill.

The model-agnostic text also ships as
[`examples/AGENTS.md`](https://github.com/makedirectory/ModelPeer/blob/main/examples/AGENTS.md),
generated from `rules print` so the two can never disagree.

## Next

- [Agent rules](agent-rules) — what the rules actually say, and why
- [Usage](usage) — `ask`, `review`, and `doctor` in full
- [CLI reference](reference) — every flag
