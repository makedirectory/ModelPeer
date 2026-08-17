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

It is served from the custom domain **https://modelpeer.app**, which depends on
three things staying in agreement: `documentation/static/CNAME` (Docusaurus copies
it verbatim into the build, and GitHub Pages reads it), and `url` / `baseUrl` in
`docusaurus.config.js`. Reverting `baseUrl` to `/ModelPeer/` breaks every asset
path on the live site. Link to docs pages from the README as
`https://modelpeer.app/<page>`, never as a `github.io` URL.

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

**This project runs `model-peer init` on itself.** The skills under `.claude/`,
`.codex/`, and `.gemini/` are not documentation — they are the artifacts Model
Peer installs, live in the repository that produces them. `make sync` refreshes
them via `model-peer update`, and `make check-sync` fails the build if they drift
from `bin/model-peer`. So the dogfood and the drift check are the same thing, and
there is no separate `examples/` directory to keep in step.

Do not hand-edit those files; edit `skill_body_review` / `skill_body_consult` in
`bin/model-peer` and run `make sync`. Do not re-add `.claude/rules/`,
`.codex/rules/`, or `.gemini/global_rules.md`: the first duplicates the consult
skill, and the other two are inert.

`bin/ask-claude`, `bin/ask-codex`, `bin/ask-gemini`, and `bin/ai-review` are
four-line compatibility shims that `exec` into `model-peer`; they are also embedded
in `install.sh`.

### Command structure

`bin/model-peer` dispatches from `main` into `cmd_ask`, `cmd_review`, `cmd_init`,
`cmd_update`, `cmd_trust`, or `cmd_doctor`. Every consultation funnels through
`run_provider` — the user's, and every one the broker performs on a peer's behalf.
It is the single chokepoint that enforces the guards, pushes the chain, and computes
the depth budget before either handing off to `mp_broker_run` or invoking
`run_claude` / `run_codex` / `run_gemini` directly. Put policy in `run_provider`,
not in the per-provider runners — those take a finished prompt and no policy
arguments at all, and exist only to translate it into one vendor's CLI flags.

### The peer chain

`MODEL_PEER_STACK` is a colon-separated chain of the models already active
(`claude:codex`). Its length is the current depth. `run_provider` enforces two
independent guards via `check_chain`:

1. The chain may not exceed the depth limit (`--depth`, then
   `MODEL_PEER_MAX_DEPTH`, then 1; ceiling 10). Exceeding it exits `64`.
2. A model may never be consulted by itself, at any depth. Also exits `64`.

### The consultation broker

The invariant to preserve in any change here:

> Increasing depth may increase how many models can participate.
> Increasing depth must never increase what a model can do to the host system.

Since v0.7 this holds without qualification, because a peer executes nothing. It
emits a delimited request block in its ordinary output; `run_provider` hands the
turn loop to `mp_broker_run`, which parses it, validates it, performs the
consultation through `run_provider`, frames the answer, and re-invokes the same peer
with it.

> Peers think and request. Model Peer executes and controls.

Do not reintroduce a second nested-consultation path. `_delegate` was removed
precisely because two paths would mean the weaker one defined the security model.
There is no `--allowedTools` on any invocation, no per-provider delegation matrix,
and adding a provider no longer requires deciding its "delegation support".

Rules that are easy to erode, in rough order of how much damage losing them does:

- **The parser looks for the exact nonce issued for the current turn, and nothing
  else** (`mp_parse_request`). There is no "find any block" path. A block carrying a
  stale, absent, or mismatched nonce is ordinary output: neither parsed nor
  stripped, and it survives into whatever the continuation replays. This repository
  contains the protocol in its own source tree and Model Peer reviews Model Peer, so
  a generic scan would broker its own documentation.
- **The nonce is framing, not authority.** It prevents accidental interpretation of
  protocol-shaped text. Never describe it as a security boundary; the boundary is
  `mp_broker_deny_reason`, which decides whether the requested provider runs no
  matter what a peer emits.
- **Field headers are recognized in template order only.** A bare header that would
  move backwards is value text, so a `QUESTION` quoting a diff containing a line
  reading exactly `MODEL` cannot supply the target when the peer declared none.
  The deny gate would have caught it anyway — that is the point of having a gate —
  but the parser closes the class rather than leaning on it.
- **The final turn carries no nonce.** Capability disappears rather than being
  parsed away, so there is no case where the parent has stripped a request block and
  is holding nothing. `turn budget = available + 1` is what makes the sequence
  terminate whether or not the peer cooperates.
- **Only the immediately preceding turn is replayed.** `T3 = task + T2 output +
  result 2`, never an accumulating transcript. Measured at depth 3, T3 came out
  *smaller* than T2. An earlier design had the peer write an explicit `NOTES`
  handoff; two prototype runs showed it wrote its reasoning twice and the cap
  truncated the second copy mid-sentence. Do not add it back.
- **Nothing in the continuation may read as "stop looking and answer."** A
  prototype that took thirty-eight agentic turns read the vendor's shipping source
  and overturned a false premise that the three-turn answers had inherited and
  reported fluently. A low turn count is an efficiency metric, not a correctness
  one — the same doctrine as "silence is failure, not consent", pointed the other
  way.
- **Under `review`, Model Peer owns the repository evidence** (`mp_broker_context`).
  A reviewer-supplied `CONTEXT` is ignored, not rejected, and the substitution is
  announced. The peer decides what question to ask; Model Peer decides what evidence
  crosses. Letting a reviewer author it lets it forward the two lines supporting its
  own conclusion and omit the rest — which a reviewer summarising to fit a byte cap
  does by accident.

`--timeout` is a **deadline**, resolved once per invocation by `mp_begin_deadline`,
with every hop deriving its budget from `mp_budget`. Resolving a duration per call
turned `--depth 3 --timeout 600` into a possible ~3000s operation. `review` sets one
deadline per reviewer inside the worker subshell, which is also what makes the panel
roster and the review context worker-private for free.

`cmd_review` deliberately does not overwrite `MODEL_PEER_STACK`. At top level the
chain is empty, so each reviewer starts fresh; a review launched from inside a peer
chain inherits that chain and cannot escape the guard. The synthesizer is forced to
be a leaf by passing it a depth limit of exactly `stack_depth + 1`, and `--depth`
never reaches it.

`MP_PANEL_ROSTER` blocks a reviewer from consulting a fellow panel member. That is
not a self-consultation rule — it exists because one reviewer's findings would
otherwise depend on another panel member's reasoning, and the synthesizer would read
correlated findings as independent agreement. Keep it out of prompts and out of the
provider environment: a peer does not need to know why a request would be denied
before making it, and the denial explains it afterwards.

Every provider process is launched with `MODEL_PEER_BROKERED=1` and a
`MODEL_PEER_MAX_DEPTH` equal to the current depth. `main` refuses `ask`, `review`,
`init`, `update`, and `trust` when the marker is set. This matters for Codex, whose
read-only sandbox permits command execution: nothing asks it to run `model-peer`, and
now the attempt fails rather than starting a consultation outside the broker.

### Repo setup (`init` / `update`)

`model-peer init` installs an agent skill so the developer's own coding agent
knows when to reach for a peer. `model-peer update` refreshes what is installed.

Everything written is a file Model Peer owns outright:

```text
.claude/skills/cross-model-review/SKILL.md
.codex/skills/cross-model-review/SKILL.md
.gemini/skills/cross-model-review/SKILL.md
.claude/commands/peer-review.md
```

Four invariants:

1. **Never touch a file the developer owns.** `AGENTS.md`, `CLAUDE.md`, and
   `GEMINI.md` are theirs. Model Peer does not read, write, append to, or symlink
   them. Earlier versions did, and it was the right thing to rip out — a tool that
   rearranges someone's root context files uninvited does not get run twice.
   Skills exist precisely so a vendor-supported capability can live *beside* those
   files instead of inside them.
2. **Managed files are owned whole.** Because nothing lives inside a foreign file,
   there is no marker surgery: `mp_apply_file` compares and replaces the entire
   file. That is what makes `update` tractable. A file at a managed path that
   Model Peer did not write is detected via `SKILL_MANAGED_MARKER`, reported, and
   left alone unless `--force`.
3. **Only write paths a vendor CLI actually loads, verified against the shipping
   CLI.** All three read `<vendor-dir>/skills/<name>/SKILL.md`. Confirmed live:
   `gemini skills list` reports it, `codex exec` lists it among its skills, and
   Claude Code quotes its description from the system prompt. Two traps: Codex's
   `.codex/rules/` holds Starlark `.rules` files for command permissions, not
   agent context, so markdown there is inert; and `.agents/skills/` is a
   Gemini-only alias. Verify before adding a path.
4. **The description carries the trigger.** Only `name` and `description` reach
   the system prompt; the body loads on activation. A description that says what
   the skill *is* rather than *when to use it* means the skill never fires. When
   editing `skill_body`, keep the trigger conditions in the frontmatter.

`update` deliberately refreshes only what already exists and never installs a new
agent, so it cannot quietly widen a repository's footprint. `--check` is the CI
form and writes nothing.

Gemini skips project skills in an untrusted folder, which `init` says out loud
rather than leaving the developer to discover an empty `gemini skills list`.

### Orchestration robustness

A peer that never answers is the failure mode that costs the most, because it
costs a whole review. Three rules hold here:

1. **Every consultation is bounded.** `run_with_limit` polls rather than shelling
   out to `timeout(1)`, which macOS does not ship. On expiry it signals the
   **process group** — `set -m` puts the child in its own group first. Signalling
   only the direct child leaves vendor helper processes holding the inherited
   stdout, so a downstream reader never sees EOF and the hang outlives the kill.
   This is easy to reintroduce; the smoke test asserts no orphan survives.
2. **Silence is failure, not consent.** A reviewer that exits `0` with zero bytes
   has reviewed nothing. Gemini's folder-trust gate failed exactly this way, and
   an empty file reaching the synthesizer reads as "this model found no issues" —
   the most dangerous possible misreport.
3. **A partial panel must say it is partial.** One reviewer failing drops that
   reviewer, not the run, but `synthesis_prompt` receives the dropped list and is
   told a gap in coverage is not evidence of safety. Synthesis below two surviving
   reviewers is refused outright: a one-model panel is not a cross-model review.

### Parallel reviewers

Reviewers are independent, so they are scheduled independently: `cmd_review` starts
every requested reviewer before waiting for any, then waits for all of them to reach
a terminal state before applying the partial-panel and `--strict` rules.

> Parallelism changes **when** independent reviewers run, never what they receive,
> what they may do, or how their results are judged.

The scheduling is the easy part; the process bookkeeping is where this goes wrong.

- Each reviewer writes its own file (`run_provider ... > "$tmpdir/$p.txt"`). Do not
  reintroduce `tee` here — a backgrounded pipeline puts `PIPESTATUS` out of the
  parent's reach and lets several model responses share one stdout.
- Completed reviews are replayed after fan-in, in **requested-model order**.
  Completion order must never be observable. A dropped reviewer's partial output is
  overwritten, not replayed: a truncated finding read as a complete review is worse
  than no review.
- Each worker leads its own process group (`set -m` around the background call) and
  installs its **own** traps. Bash resets inherited traps in a subshell, which is
  what makes this safe — a worker running the parent's `mp_cleanup` would delete the
  shared temp directory out from under its siblings. Parent owns the temp directory
  and the worker registry; a worker owns exactly one vendor process tree.
- A signalled worker forwards the signal down via `MP_LIMIT_CHILD_PID`, which
  `run_with_limit` publishes. Killing the worker shell alone leaves the vendor CLI
  running as an orphan holding an open model call.
- Top-level `INT`/`TERM` re-raise after cleanup. Cleaning up and falling through
  continues into code whose temp directory has just been removed.

Fan-in waits in requested order, which serializes nothing because every worker is
already running — that is why no `wait -n` is needed, and Bash 3.2 does not have it.

The primary test is a **concurrency barrier**: stubs record that they started and
block until every requested reviewer has. Serial orchestration can never open it.
Wall-clock assertions are secondary evidence only. Note that a background job
started without job control has SIGINT set to *ignored* and cannot trap it, so the
interrupt test enables `set -m` — without that it silently proves nothing.

### Review context

`make_review_context` must show reviewers the code under review, which is not what
`git diff` alone provides. Untracked files are invisible to `git diff` at any
revision, and `git status --short` collapses a new directory to one `?? src/` entry,
so a whole new package can arrive as a single path. Context therefore uses
`--untracked-files=all` and synthesizes an add-diff per untracked file with
`git diff --no-index -- /dev/null <path>`. Keep `--exclude-standard` so ignored
files stay out, and never use `git add -N` to make untracked files diffable — that
mutates the developer's index, and a review command must not.

### Provider safety contracts

Each runner is a read-only consultation contract, tightened per vendor. None of it
varies with depth:

| Provider | Contract, at every depth |
|---|---|
| `claude` | plan mode, `--tools Read,Glob,Grep`, stdin closed |
| `codex` | `--sandbox read-only --ephemeral`, stdin closed |
| `gemini` | plan mode, generated deny policy, `-e none`, `--skip-trust`, stdin closed |

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
