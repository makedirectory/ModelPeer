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

An agent skill for each CLI, plus a slash command for Claude Code:

```text
.claude/skills/cross-model-review/SKILL.md      review the current diff
.claude/skills/cross-model-consult/SKILL.md     ask one peer a question
.codex/skills/...                               both, per CLI
.gemini/skills/...
.claude/commands/peer-review.md                 /peer-review
.claude/commands/peer-ask.md                    /peer-ask
```

Two skills, because the tool does two things that fire on different cues.
**Review** cross-checks a diff across the whole panel; **consult** gets one peer's
opinion on one question. A single skill covering both had a description that was a
list of unrelated triggers, which is the shape that stops a skill activating when
it should.

That is the whole footprint. **Your `AGENTS.md`, `CLAUDE.md`, and `GEMINI.md` are
never read, written, or symlinked.** Every path above is one Model Peer owns
outright, which is what makes [`model-peer update`](#keeping-it-current) possible:
a self-contained directory can be replaced wholesale, with no marker surgery
inside a file you wrote.

Each skill is addressed to the CLI that loads it and names its two peers — the
Codex one opens *"You are Codex. Claude and Gemini are available as independent,
read-only engineering peers"* — so every harness sees instructions written for it.

Narrow it if you like, and preview before committing to anything:

```bash
model-peer init --agents claude,codex   # skip Gemini
model-peer init --no-command            # skip the slash command
model-peer init --dry-run               # report; write nothing
model-peer init --print=review          # dump a SKILL.md to stdout
model-peer init --print=consult
```

:::note How skills load, and why the description matters
A skill is a self-contained directory the vendor discovers on its own. Only the
`name` and `description` from the frontmatter reach the model's system prompt; the
body is loaded when the model decides the skill applies.

That is why the shipped description spells out the trigger conditions — architecture
decisions, security-sensitive work, a bug that outlived two hypotheses, before a
pull request — rather than just saying what the skill is. A vague description means
the skill never fires.
:::

:::caution Gemini needs a trusted folder
Gemini skips project skills in a directory its folder-trust gate has not blessed,
reporting `Skipping project agents due to untrusted folder`. One command fixes it:

```bash
model-peer trust        # adds one TRUST_FOLDER entry for this directory
gemini skills list      # should now list both skills
```

That writes a single entry to `~/.gemini/trustedFolders.json` and nothing else.
Codex loads project skills without trust, and Claude Code asks you once
interactively, so neither is touched. Since folder trust is a security control,
`init` never does this for you — it only points at the command.

(Model Peer's own consultations were never affected: those pass `--skip-trust`.)
:::

## Why skills, and not your rules files

Claude Code, Codex, and Gemini each read a project context file — `CLAUDE.md`,
`AGENTS.md`, and `GEMINI.md`. Those belong to your project, and a tool that edits
them uninvited does not get run twice.

Skills are the one mechanism all three support that is *self-contained*: a
directory Model Peer creates, owns, and can update, sitting alongside your files
rather than inside them.

Two paths that look like they should work and do not:

- **`.codex/rules/`** is real, but it holds Starlark `.rules` files that control
  which commands Codex may run outside its sandbox. It is a permissions mechanism,
  not agent context; markdown there is ignored.
- **`.agents/skills/`** is a Gemini-only alias. Codex and Claude Code do not read
  it, so Model Peer uses each vendor's own directory.

## The three moments it changes

### 1. Mid-task, when the agent is unsure

The skill tells your agent to consult a peer before an architecture decision, on a
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

Reviewers run at the same time, so the panel looks busy all at once: progress from
several models interleaves on stderr, and nothing reaches stdout until every
reviewer has finished. A long quiet stretch is the panel working, not a hang — see
[Troubleshooting](troubleshooting#a-review-looks-busy-all-at-once).

### 3. From inside Claude Code

`init` also installs a slash command, so you never have to leave the session:

```text
/peer-review
/peer-review auth flow and session rotation
```

It runs `model-peer review`, reports the synthesized findings ungarnished, and
then says for each one whether it agrees and why. It will not apply fixes unless
you ask.

## Keeping it current

The skill text changes between Model Peer versions. After upgrading:

```bash
model-peer update
```

```text
  current   .claude/skills/cross-model-review/SKILL.md
  updated   .codex/skills/cross-model-review/SKILL.md
  current   .claude/commands/peer-review.md
```

`update` only touches files that already exist and that Model Peer wrote. It never
installs an agent you did not ask for — use `init` for that — and a file at one of
those paths that Model Peer did not write is reported and left alone.

To verify without writing, for CI:

```bash
model-peer update --check
```

Exits `0` when everything matches this version, `1` when something is missing or
stale.

```yaml
- name: Check agent skills
  run: |
    curl -fsSL https://raw.githubusercontent.com/makedirectory/ModelPeer/v0.6.2/install.sh | bash
    ~/.local/bin/model-peer update --check
```

## Rolling it out to a team

1. One person runs `model-peer init` and commits the four files.
2. Everyone else runs the [installer](install) once, for the `model-peer` command
   itself. The skills are already in the repo.
3. Nobody needs the same CLIs. `model-peer doctor` reports what each machine has,
   and `ask` needs one peer while `review` needs two.

Costs are worth stating plainly: every consultation is a real model call against
the developer's own vendor account, and a full `review` across three models takes
minutes. The shipped skill tells agents not to consult for anything answerable by
reading the code, which is the difference between a useful habit and a bill.

Want to read the text before installing anything? `model-peer init --print`
writes it to stdout and touches nothing. There is no separate `examples/`
directory: the skills are the examples, and they are installable.

## Next

- [Agent skills](agent-rules) — what the skill says, and why
- [Usage](usage) — `ask`, `review`, and `doctor` in full
- [CLI reference](reference) — every flag
