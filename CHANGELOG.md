# Changelog

All notable changes to Model Peer are documented here.

## 0.8.0 - 2026-08-17

`init` no longer installs three vendor directories by default.

### Changed

- **`model-peer init` requires the agents it may write for.** It installed
  `.claude/`, `.codex/`, and `.gemini/` by default, on the reasoning that a
  teammate on a different CLI is then covered too. In a repository whose team uses
  one CLI that is two vendor directories nobody asked for, and a tool that writes
  them uninvited does not get run twice — the same rule that keeps `init` out of
  `AGENTS.md`, applied to the directories it does own.

  The selection is now positional: `model-peer init claude`,
  `model-peer init claude,codex`, or `model-peer init all` for the previous
  behaviour. A bare `model-peer init` names the choices, writes nothing, and exits
  `2`. `--agents LIST` still works and means the same thing, so existing scripts
  keep running. `--print` is unaffected; it never wrote anything.

## 0.7.1 - 2026-08-17

Review follow-ups to the consultation broker. Four gaps, and the documentation that
was claiming more than the code held.

### Fixed

- **`doctor --probe` is refused for a peer.** The brokered-peer refusal covered
  `ask`, `review`, `init`, `update`, and `trust` on the grounds that `doctor` is
  read-only. `--probe` is not: it runs one real consultation per installed CLI, and
  clears `MODEL_PEER_STACK` to do it. It therefore spent model usage and erased the
  chain guard — every property the refusal exists to deny, reached through a command
  that looked diagnostic.

- **The synthesizer counts as a panel member.** It reads every review and reconciles
  them, so a reviewer that consulted it would meet its own opinion again as another
  reviewer's independent finding — and two reviewers doing it would have the
  synthesizer read that back as corroboration between them.

  With three providers installed this makes `--depth` above 1 inert whenever the
  synthesizer sits outside the panel, because nobody is left who has not already
  seen the change. `--depth` has an effect when the synthesizer is *inside* the
  panel and an installed model is outside it.

- **Reviewer prompts follow availability rather than `--depth`.** The default panel
  is every installed model, so there was never anyone outside it to consult and the
  reviewer ran as a leaf — while its prompt still offered a consultation and forbade
  one in the same breath. Prompt and capability must never disagree. The startup
  banner had the same fault and now reports which case the run is in instead of
  letting depth look effective when it is not.

- **`QUESTION` is bounded at 8192 bytes,** as `CONTEXT` already was. Under `review`
  Model Peer supplies the repository evidence so a reviewer cannot forward only the
  lines supporting its own conclusion — but `QUESTION` crossed verbatim and
  unbounded, so the same excerpt pasted there had the identical effect. Truncation
  is reported on stderr and marked in the packet the peer receives.

### Changed

- **`MODEL_PEER_BROKERED` is documented as a guardrail, not a boundary.** The safety
  page described it as though a peer's attempt to run Model Peer fails. It is an
  environment variable, and a provider whose sandbox permits command execution can
  clear it. It reliably stops the inadvertent case, which is the one that occurs,
  and nothing inside Model Peer can do more than that. What a determined or
  prompt-injected peer would gain is an unauthorised consultation — spending usage
  and stepping outside the panel rules — never write access.

## 0.7.0 - 2026-08-13

### Added

- **The consultation broker.** A peer that wants a second opinion no longer runs
  anything to get one. It emits a request in its reply, Model Peer validates it,
  performs the consultation, and hands the answer back as evidence on the peer's
  next turn.

  ```text
  Claude
    │  "I'd like Codex's read on the fan-in loop"   (in its output, then stops)
    ▼
  the broker, inside the same model-peer process
    │  parse → validate → run → frame
    ▼
  Claude, next turn
  ```

  The transport is a delimited block in ordinary text, so every provider speaks it
  on identical terms and none of them needs a tool call or a shell to participate.

  > Peers think and request. Model Peer executes and controls.

  A request is checked against the same policy the invocation started with: the
  model must be installed, must not be the requester, must not already be on the
  active path, must not be a member of the active review panel, and must fit inside
  the depth limit. A denial comes back to the peer as a framed packet with a reason
  and the run continues — a nested model that cannot answer is evidence
  unavailable, not failure of your original request.

  Consultation capability is granted per turn and taken away by withholding it. The
  final turn carries no identifier, so the peer has to answer; each turn spends one
  unit of the budget whether the peer cooperates or not.

- **`review --depth N`.** Reviewers stay leaves by default. Above 1 a reviewer may
  consult a model that is **not** on the panel; a request for a panel member is
  denied. That denial is not about self-consultation — one reviewer's findings would
  become partly dependent on another panel member's reasoning, and the synthesizer
  would then read correlated findings as independent agreement. The synthesizer is
  a leaf regardless. `MODEL_PEER_MAX_DEPTH` does not reach `review`: giving a panel
  depth changes what agreement between two reviewers means, so it must be explicit.

  When a reviewer does consult a peer, Model Peer sends the consulted model the same
  review packet the panel received and ignores a reviewer-authored `CONTEXT`, saying
  so on stderr. The reviewer chooses the question; Model Peer chooses what
  repository evidence crosses. Otherwise a reviewer could forward the two lines
  supporting the conclusion it had already reached, get agreement on that evidence,
  and have the panel record it as corroboration — which a reviewer summarising to
  stay inside a byte cap would do by accident.

### Changed

- **Gemini can participate in consultation chains.** It was excluded not because its
  opinion was worth less but because reaching a consultation meant running a
  command, and its policy engine can only allow or deny `run_shell_command`
  wholesale. The broker removed the requirement, so Gemini now participates with its
  deny rules unchanged and fully in force.

- **`--timeout` is one deadline for the invocation, not a fresh budget per hop.**
  Resolving a *duration* once per provider call and applying it again at every hop
  turned

  ```bash
  model-peer ask claude --depth 3 --timeout 600
  ```

  into a possible ~3000-second operation — five model turns, each granted a full ten
  minutes. That was a silent redefinition of the flag. Model Peer now resolves a
  deadline once and every subsequent call gets what is left of it. Nothing new
  happens at expiry: `run_with_limit`, exit `124`, the same message.

  Under `review` the rule is per reviewer, independently, so `review --timeout 600`
  means exactly what it always did. A consultation a reviewer starts spends that
  reviewer's remaining time and no sibling's.

  This supersedes the 0.6.2 fix, which propagated the resolved duration to a nested
  peer. That was correct for the mechanism it patched and is now deleted with it.

- `doctor` no longer prints a per-provider nested-consultation matrix, because there
  is no longer a per-provider difference to report.

### Removed

- **`model-peer _delegate`, and the shell grant that existed to reach it.** Claude
  peers above depth 1 were given `Bash`, auto-approved for
  `Bash(model-peer _delegate:*)` — the narrowest grant Claude Code can express, but
  a grant. `--allowedTools` no longer appears on any invocation at any depth, and
  the smoke suite asserts it.

  The broker replaces that path rather than coexisting with it. Two nested
  consultation paths would mean the weaker one defined the security model.

  With `provider_delegation_support` and `resolve_delegation` gone, adding a
  provider no longer requires deciding what kind of shell grant it can hold.

### Security

- **Peers are read-only at every depth, without qualification.** The residual
  widening documented since depth was introduced — one provider holding a
  namespaced `Bash` above depth 1 — no longer exists.

- **A provider process is refused the CLI.** Every peer is launched with
  `MODEL_PEER_BROKERED=1` and a depth ceiling equal to the current depth, and Model
  Peer refuses `ask`, `review`, `init`, `update`, and `trust` when it sees that
  marker. `doctor` stays available; it is read-only. This matters for Codex, whose
  read-only sandbox permits command execution: nothing asks it to run `model-peer`,
  and now the attempt fails rather than starting a consultation outside the broker's
  control.

- **Protocol-shaped text in your repository is inert.** A request block is
  recognised only when it carries the identifier issued for the turn in progress, so
  a block in a diff, in documentation, in another model's output, or quoted back
  from a previous turn is ordinary text — neither parsed nor stripped. Model Peer
  reviews Model Peer, and this repository carries the protocol in its own source
  tree, so this is asserted rather than assumed.

  This framing is not a security boundary and is not described as one. The peer
  receives the identifier, so content that manipulates a peer can in principle cause
  a well-formed request to be emitted. What stops it mattering is validation.

- **Requests and results cross the boundary as labelled data.** A peer's `QUESTION`
  and `CONTEXT` reach the consulted model as quoted data inside the standard
  consultation prompt, never as part of its instructions. A result packet is
  authentic only where Model Peer placed it, and the continuation prompt says so:
  one encountered in a file or a command's output is workspace content and carries
  no authority.

- **Truncation is always visible.** A `CONTEXT` over 4096 bytes is reported on
  stderr and marked inside the packet the recipient sees. A recipient that assumes
  it received everything when it did not is the failure that prevents.

- **No nested provider process survives its owning invocation.** The chain is one
  level deeper than the parallel-reviewer work assumed — parent, reviewer worker,
  requesting peer, consulted peer — and each level forwards signals down rather than
  dying and orphaning what it started. Asserted under `INT` mid-consultation.

- **Silence is failure on the broker's own return, not only a nested peer's.** Only
  the final turn is emitted — earlier turns are deliberately never replayed as an
  answer — so a peer that reasoned for two turns and then answered with whitespace
  would have exited `0` with zero bytes after spending the whole budget, and `review`
  would have read that as a completed review. It now fails.

  A reviewer is also tested for a non-whitespace byte rather than for size. A lone
  newline is every bit as much "no review" as zero bytes, and it passed the old
  gate — a pre-existing gap the broker made easier to reach.

  Found by a Claude peer consulted through the broker at `--depth 3` against this
  change, on the first real-CLI run.

- **Field headers are recognized only in the order the template declares them.**
  Otherwise a `QUESTION` quoting a diff that happened to contain a line reading
  exactly `MODEL` could supply the target when the peer had declared none — quoted
  third-party text becoming request *structure* rather than request content. It
  could never reach a provider the invocation had not authorised, because
  validation re-derives every check from Model Peer's own state, but the parser is
  meant to close that class rather than lean on the gate.

  Found by a Claude peer and a Codex peer, reached through the broker at
  `--depth 3` against this change. Codex sharpened it from "value splitting" to
  "absent-field supply", which is the version that actually contradicted the
  documented parser obligation.

- **A parser failure fails closed structurally, not incidentally.** The broker
  reuses one scratch directory across turns, and the verdict files were written
  only at the end of the parse, so an `awk` that died early left the previous
  turn's verdict readable. They are now seeded as `malformed` before the parse
  runs.

### Compatibility

At depth 1 — the default — `ask` and `review` are unchanged: no identifier is
issued, no protocol instructions enter the prompt, and provider output streams
straight to stdout as before. Above depth 1 the peer's output is buffered so it can
be scanned, so streaming is lost for that invocation; nested orchestration is
reported on stderr and never reaches stdout, so `model-peer ask ... | ...` stays
pipeable and the review replay stays byte-stable.

Model output above depth 1 is not byte-identical to 0.6.2. Introducing consultation
instructions into a prompt can change generated text.

## 0.6.2 - 2026-08-12

### Fixed

- **`--timeout` now applies below the top level.** `run_claude` and `run_codex`
  handed a nested peer `MODEL_PEER_STACK` and `MODEL_PEER_MAX_DEPTH` but not
  `MODEL_PEER_TIMEOUT`. A delegating peer's consultation therefore re-resolved the
  timeout from an unset variable and fell back to the 600s default:

  ```bash
  model-peer ask claude --depth 2 --timeout 60   # nested peer got 600s, not 60
  ```

  Ten times the requested bound, in the direction that costs money. The resolved
  value now travels with the rest of the chain state, so `--timeout` and
  `MODEL_PEER_TIMEOUT` mean the same thing at every depth, and `--timeout 0` is
  inherited as disabled rather than re-defaulted.

  Only reachable at `--depth 2` or greater, which is opt-in and off by default.

  This bounds **each hop**, not the whole chain: N consultations can still total
  N × timeout. Turning `--timeout` into a single deadline spanning a chain needs a
  component that owns the whole loop, which is the consultation broker's job rather
  than a patch to the per-call path.

## 0.6.1 - 2026-08-12

### Fixed

- **Gemini no longer inherits `GEMINI_CLI_TRUST_WORKSPACE`.** Gemini documents
  `GEMINI_CLI_TRUST_WORKSPACE=true` as the headless equivalent of `--skip-trust`.
  Inside Gemini the two are not equivalent: the environment variable additionally
  enables MCP servers declared in the workspace's own `.gemini/settings.json`, and
  Gemini launches those as local subprocesses during tool discovery — before any
  policy decision, and without a model turn.

  Plan mode, the generated deny policy, and `-e none` all govern tool *calls*. None
  of them govern server *startup*. So under `model-peer review`, a repository being
  reviewed could specify a command that ran on the reviewer's machine.

  `--skip-trust` on its own never did this; only the inherited variable did, and
  `run_gemini` passed the environment through unchanged. It is now cleared, making
  `--skip-trust` the single trust mechanism Model Peer relies on rather than one of
  two with divergent behaviour. Verified against Gemini CLI 0.46.0, with and without
  the fix, using the flags Model Peer actually passes.

  If you run Model Peer against repositories you do not control, this is worth
  taking. If that variable is not set in your environment, you were never exposed.

  The smoke tests now assert that the variable does not reach the CLI, so the
  contract is checked rather than assumed.

## 0.6.0 - 2026-08-11

### Added

- **`doctor` reports the longest chain that is actually reachable**, alongside the
  configured limit. `--depth` accepts up to 10, but a model may never appear twice
  in one chain, so the real cap is how many distinct models you have installed —
  three. Depth above that has never done anything, and nothing said so:

  ```text
  Peer-chain depth limit: 1 (ceiling 10)
  Longest usable chain:   3 (a model may not appear twice, and 3 installed)
  ```

- The installer now says how to finish setup. Installing Model Peer globally gives
  *you* a command; it does not give the coding agent in your repository a habit.
  That takes `model-peer init`, once per project, and nobody runs a command they
  were never told about.

### Changed

- **`model-peer review` now runs independent reviewers concurrently** rather than
  serially. Reviewer wall-clock time is therefore approximately the slowest
  requested reviewer rather than the sum of all reviewer runtimes.

  ```text
  serial:    Claude + Codex + Gemini + synthesis
  parallel:  max(Claude, Codex, Gemini) + synthesis
  ```

  The practical benefit is larger than the arithmetic suggests: a vendor that hangs
  for its full timeout no longer delays the *start* of every reviewer behind it.
  Each reviewer's timeout window now begins when the panel does.

  Parallel review reduces elapsed time, not provider usage. Every requested
  reviewer is still invoked exactly once.

- **Reviewer output is buffered per reviewer and replayed in panel order.**
  Concurrent model responses cannot interleave on stdout, and the replay follows
  the order the models were requested rather than the order they finished, so
  `model-peer review > review.txt` is reproducible.

- Existing timeout, partial-panel, `--strict`, empty-output, and synthesis
  semantics are unchanged. Synthesis still begins only after every requested
  reviewer has finished, failed, or timed out, and is still refused below two
  surviving reviewers.

### Fixed

- **`doctor` called a working Gemini setup BROKEN.** 0.5.1 taught it to read the
  sign-in method recorded in `~/.gemini/settings.json` and check the matching
  credential. The reading was right; the checks were wrong in every branch, so it
  replaced a false "fine" with a false "broken" — which is worse, because it sends
  people to fix what is not wrong and teaches them to ignore the one diagnostic
  that matters.

  The checks now mirror Gemini CLI's own `validateAuthMethod`, read out of the
  shipping bundle rather than inferred:

  | `selectedType` | Model Peer used to require | Gemini actually accepts |
  |---|---|---|
  | `oauth-personal` | an active account in `google_accounts.json` | anything — it performs no local check, and never reads that file |
  | `gemini-api-key` | `GEMINI_API_KEY` or `GOOGLE_API_KEY` in the environment | `GEMINI_API_KEY` from the environment **or a `.env` it loads itself**, **or a key in its credential store** |
  | `vertex-ai` | `GOOGLE_APPLICATION_CREDENTIALS` or `GOOGLE_CLOUD_PROJECT` | `GOOGLE_CLOUD_PROJECT` **and** `GOOGLE_CLOUD_LOCATION`, or `GOOGLE_API_KEY` |

  Model Peer now also searches for a `.env` the way Gemini does — from the current
  directory upward, preferring `<dir>/.gemini/.env`, then `~/.gemini/.env` and
  `~/.env` — checking only whether the variable is assigned, never reading its
  value.

  One source stays invisible: Gemini can hold an API key in its own credential
  store, which no shell can read. So `doctor` no longer states a verdict it cannot
  support. It reports what it can see, says plainly what it cannot, and points at
  `doctor --probe`, which settles the question by actually consulting the model.

- **`SIGINT`/`SIGTERM` ran the cleanup and then carried on.** The handler removed
  the review temp directory and returned, and the shell continued into code whose
  temp directory no longer existed — so an interrupted review kept consulting
  models and exited on whatever the interrupted statement happened to return.
  Both signals now stop the panel and re-raise, giving the conventional `130`/`143`.

  Interrupting a parallel review also stops every reviewer worker and the vendor
  process tree beneath each one, so no model call is left running in the
  background against your account.

- **A model listed twice in `--models` ran twice and was reported as two
  reviewers.** `--models gemini,gemini,gemini` invoked Gemini three times — three
  times the usage — while all three wrote the same `gemini.txt`. Serially the last
  one overwrote the others; concurrently they raced. The synthesizer then received
  a single review and was told every reviewer in the panel completed, which is the
  exact misreport the panel exists to prevent.

  Duplicates are now a usage error (exit `2`), applying the rule the chain guard
  already enforced within a chain: a model may not appear twice.

  ```text
  model-peer: review model 'gemini' is listed more than once; a panel needs distinct models.
  ```

## 0.5.1 - 2026-08-11

### Fixed

- **`doctor` reported a broken Gemini setup as fine.** It printed "cached OAuth is
  verified on first request" whenever no auth environment variable was set,
  without reading the sign-in method Gemini actually recorded in
  `~/.gemini/settings.json`. The state it hid is the worst one: configured for an
  API key with no key present, Gemini does not fail — headless, with stdin closed,
  it blocks on an auth prompt nobody can answer, and a review simply hangs.

  `doctor` now reads the recorded method and checks the matching credential,
  naming the problem instead of a multi-minute hang:

  ```text
  Gemini authentication: BROKEN — configured for an API key, but neither GEMINI_API_KEY
                         nor GOOGLE_API_KEY is set. Headless calls will hang rather
                         than fail...
  ```

  API-key, Vertex AI, OAuth, and not-yet-configured are each reported distinctly.

  Found by `doctor --probe` from 0.5.0: the probe reported Gemini as unverified,
  and the cause turned out to be local auth rather than anything in Model Peer —
  which is the separation the probe was added to make.

## 0.5.0 - 2026-08-11

### Added

- **`model-peer doctor --probe`** runs one real consultation per installed CLI in
  a throwaway Git repository and checks that the read-only contract actually
  holds. The smoke suite runs against stubs, which verifies the flags Model Peer
  passes but not what the vendors do with them — and every wrong assumption this
  project has shipped was of the second kind.

  The judgement comes from the filesystem, never from the reply. The probe asks
  each peer to read a token **and to attempt to modify a sentinel file and create
  a new one**, then checks the sentinel's contents and the directory listing. A
  model claiming it could not write proves nothing; an unchanged file does.

  A peer that times out or returns nothing is reported as **unverified**, not as
  a pass. `--models` and `--timeout` narrow the run. It consumes real usage, so
  it is opt-in and never part of plain `doctor`.
- `model-peer doctor` reports each CLI's version alongside its path, so a bug
  report carries the versions of the three tools whose behaviour Model Peer
  depends on.

Running the probe immediately earned its place: Claude 2.1.227 and Codex 0.147.0
verified clean, while Gemini 0.46.0 did not answer at all. A direct
`gemini -p` call in the same directory hung identically, which is the distinction
the probe exists to draw — the vendor CLI, not Model Peer's wrapping.

## 0.4.0 - 2026-08-10

Setup became a skill, and the chain guards were brought in line with what the
documentation already promised.

In 0.3.0 `model-peer init` wrote the developer's `AGENTS.md` and symlinked
`CLAUDE.md` and `GEMINI.md` to it. That was the wrong shape: a tool that
rearranges someone's root context files uninvited does not get run twice. It now
installs self-contained agent skills instead, in the directory each vendor set
aside for them, and touches nothing else.

```text
.claude/skills/cross-model-review/SKILL.md      .claude/commands/peer-review.md
.claude/skills/cross-model-consult/SKILL.md     .claude/commands/peer-ask.md
.codex/skills/...                               (both, per CLI)
.gemini/skills/...
```

### Added

- `model-peer update` refreshes the installed files to match the running version,
  and `--check` reports drift and exits `1` without writing, for CI. It only
  touches files that already exist and that Model Peer wrote, and never installs
  an agent that is not already present, so it cannot quietly widen a repository.
- `model-peer trust` marks a directory as trusted for Gemini CLI, which otherwise
  refuses to load project skills and reports none at all. It adds one
  `TRUST_FOLDER` entry to `~/.gemini/trustedFolders.json` and nothing else. Codex
  loads project skills without trust and Claude Code prompts interactively, so
  neither is modified. Folder trust is a security control, so `init` never does
  this for you.
- `model-peer _delegate <model> "<question>"`, the only command a delegating peer
  is authorized to run. It inherits every limit, accepts no options, and cannot
  reach `init`, `update`, `review`, `trust`, or `doctor`.
- Two skills, not one. `cross-model-review` cross-checks a diff across the panel;
  `cross-model-consult` gets one peer's opinion on one question. They fire on
  different cues, and one description covering both triggers neither well.
- `model-peer init --print[=WHAT]` writes a skill or slash command to stdout and
  touches nothing. `--dry-run` previews the whole install.
- `model-peer doctor` reports which skills the current project has installed.

### Changed

- **`init` never reads, writes, appends to, or symlinks `AGENTS.md`,
  `CLAUDE.md`, or `GEMINI.md`.** Everything it writes is a file Model Peer owns
  outright, which is also what makes `update` tractable: managed files are
  compared and replaced whole, with no marker surgery inside a foreign file.
- **`review` no longer accepts `--depth`.** Reviewers and the synthesizer are
  always leaves. Reviewers that can consult one another are not independent
  observations, which is the entire value of the panel — and the review prompt
  already told reviewers to consult no one, contradicting the outer consultation
  prompt above depth 1. `ask` explores; `review` cross-checks.
- The skill `description` carries the trigger conditions rather than a summary.
  Only `name` and `description` reach the model's system prompt; the body loads
  on activation, so a description that says what a skill *is* never fires it.
- **This project runs `model-peer init` on itself.** The skills under `.claude/`,
  `.codex/`, and `.gemini/` are the real installed artifacts, live in the
  repository that produces them. `make sync` refreshes them and `make check-sync`
  fails the build when they drift, so dogfooding and drift detection are the same
  files. `examples/` is removed as redundant, along with the hand-written
  `.claude/rules/cross-model-consultation.md` that had already drifted from it.
- `model-peer rules <install|print|check>` is replaced by `init` and `update`.
- The README heading is now "By default, there is no chat between models", since
  `ask --depth` genuinely does let one model consume another's answer.

### Fixed

- **A model could appear twice in one chain.** The guard compared only the last
  entry of `MODEL_PEER_STACK`, so `claude → claude` was blocked while
  `claude → codex → claude` was permitted — a model reviewing its own work one hop
  removed. Membership is now tested across the whole chain.
- **A peer could raise the ceiling it inherited.** `--depth` beat the inherited
  `MODEL_PEER_MAX_DEPTH`, contradicting "the limit propagates down the chain".
  Inside a chain the inherited value is now a cap: lowerable, never raisable.
- **Synthesis was unbounded.** Every reviewer was bounded by `--timeout`, but the
  synthesis call omitted the argument and fell through to no limit, so a hung
  synthesizer could hang the run after every reviewer had succeeded.
- **A delegating Claude peer was granted more than the prompt allowed.** The
  grant was `Bash(model-peer:*)`, and `model-peer` stopped being a read-only
  executable once `init` and `update` existed. Delegation now grants
  `Bash(model-peer _delegate:*)` only, so the capability matches the prompt.
- Temporary directories are removed on interrupt, not only on the normal path.
  The review context holds the diff and the contents of untracked files.
- Corrects a claim made in 0.3.0: `.codex/rules/` **is** a real directory Codex
  reads, but it holds Starlark `.rules` files governing which commands may run
  outside the sandbox — a permissions mechanism, not agent context. Markdown
  there is still ignored, but not for the reason previously documented.
  `.agents/skills/` is a Gemini-only alias that Codex and Claude Code do not read.

Skill discovery was verified against the shipping CLIs rather than their
documentation: `gemini skills list` reports the installed skills, a `codex exec`
run lists them among its available skills, and Claude Code quotes their
descriptions back from the system prompt.

Thanks to the reviewer who worked through `main` as a maintainer would; four of
the fixes above came from that read.

## 0.3.0 - 2026-08-10

Repository setup and orchestration robustness. `model-peer init` closes the gap
between installing the tool and an agent ever using it; the review path is
hardened against the failure modes that cost a whole run.

### Added

- `model-peer init` (alias for `model-peer rules install`) installs the
  cross-model consultation rules into a repository. Default layout is one shared
  `AGENTS.md` with `CLAUDE.md` and `GEMINI.md` symlinked to it; `--split` writes
  one tailored file per CLI, each addressing that model directly and naming its
  two peers. `--agents`, `--dir`, `--no-command`, `--dry-run`, and `--force`
  narrow or preview the result.
- Rules are written between `<!-- BEGIN MODEL PEER RULES -->` and
  `<!-- END MODEL PEER RULES -->`. Content outside the markers is never rewritten,
  so `init` is idempotent, appends below an existing `AGENTS.md`, and refreshes in
  place after an upgrade.
- `model-peer rules print [--profile P] [--command]` writes the rules to stdout
  without touching a file.
- `model-peer rules check` verifies that every managed block matches what the
  installed version would write; exits `1` when a block is missing or stale, for
  CI. It reads each block's recorded profile, so both layouts verify correctly.
- `.claude/commands/peer-review.md`, giving Claude Code a `/peer-review` slash
  command that runs a cross-model review of the current diff and reports the
  synthesis with its own agreement or disagreement. Skip it with `--no-command`.
- `--timeout S` on `ask` and `review`, plus `MODEL_PEER_TIMEOUT`, defaulting to
  600 seconds; `0` disables it. Consultations report progress on stderr every 30
  seconds, so a slow peer is distinguishable from a hung one. Exits `124` on
  timeout, matching `timeout(1)`.
- `review --strict` refuses to synthesize unless every reviewer completed, which
  was the behavior before this release.
- `model-peer doctor` reports the effective consultation timeout and whether the
  current project has rules installed.
- Documentation: "In your workflow" covering the three moments consultation
  actually happens, team rollout, and CI verification; and "Troubleshooting"
  covering hangs, partial panels, Gemini's trust gate, and missing untracked
  files. `agent-rules` now explains what the rules say rather than how to copy a
  file.

### Changed

- A reviewer that times out, fails, or returns nothing is dropped from the panel
  and named, instead of failing the entire run. Synthesis proceeds while at least
  two reviewers produced a real review, and is refused below that — two
  independent views are the minimum that makes a cross-model review worth the
  name. The synthesizer is told which reviewers are missing and instructed to
  report the gap, so a partial panel is never presented as a complete one.
- `examples/AGENTS.md` is generated from `model-peer rules print`. `make sync`
  regenerates it and `make check-sync` fails the build on drift, so the shipped
  template can no longer disagree with what `init` writes.
- The rules text tells agents not to consult for anything answerable by reading
  the code, and ends with a stand-down line for a model that loads the file while
  acting as a peer in someone else's consultation.
- The documentation site moved to its own domain, <https://modelpeer.app>, via
  `documentation/static/CNAME` and matching `url` / `baseUrl`.

### Fixed

- **Untracked files were invisible to reviewers.** Review context was built from
  `git diff HEAD`, which cannot see untracked files, and `git status --short`
  collapses a new directory to a single `?? src/` line — so an entire new package
  reached reviewers as one path, with no filenames and no contents. Context now
  includes an add-diff for every untracked, non-ignored file, uses
  `--untracked-files=all` for the status listing, and marks the patch
  `includes_untracked="true"`. Binaries are summarized rather than dumped.
- **A hung peer could hang the whole run indefinitely.** Consultations are now
  bounded, and on timeout the peer's entire process group is signalled rather
  than just the process Model Peer launched. Signalling only the direct child
  left vendor helper processes holding the inherited stdout, so the downstream
  pipeline never saw EOF and the hang survived the kill.
- **Gemini failed silently in untrusted directories.** Its folder-trust gate
  refuses to work headlessly and exits `0` having produced nothing, which a panel
  read as "this reviewer found no issues". Model Peer now passes `--skip-trust`,
  feature-detected from `gemini --help`. This does not widen the boundary: Plan
  mode, the unconditional deny policy, and `-e none` are all passed explicitly and
  never depended on the trust gate.
- **An empty review counted as a clean review.** A reviewer that exits `0` with
  zero bytes of output is now treated as a failure.
- `init` writes only paths the vendor CLIs genuinely load: `.claude/rules/**/*.md`
  and `CLAUDE.md` for Claude Code, `AGENTS.md` for Codex, `GEMINI.md` for Gemini.
  A `.codex/rules/*.md` or `.gemini/global_rules.md` file is never read by those
  CLIs — Codex's extra context filenames come from the global
  `project_doc_fallback_filenames` key, not from the repository — so Model Peer
  does not create them.

## 0.2.0 - 2026-08-09

### Added

- `--depth N` on `ask` and `review`, plus `MODEL_PEER_MAX_DEPTH`, to cap peer-chain
  length. Default `1` (a peer answers alone), ceiling `10`. The limit propagates
  down the chain, so a peer cannot raise its own ceiling.
- Depth-aware consultation prompts: peers are told how much chain depth remains and
  whether they may delegate.
- Delegation as a concept distinct from depth. Depth is a limit and never a
  permission; delegation is the separate permission to initiate a further
  consultation, granted only where a provider can scope it to Model Peer alone.
  Claude gets `Bash` auto-approved solely for `Bash(model-peer:*)`; Codex gains no
  new capability at all; Gemini never delegates, because its policy engine can only
  allow or deny `run_shell_command` wholesale. A depth budget a provider cannot
  safely hold is reported on stderr rather than converted into a wider sandbox.
- `model-peer doctor` reports the per-provider nested-consultation matrix, the
  effective depth limit, and any active chain.
- `make sync` / `tools/sync-installer.sh` to regenerate the copy of `bin/model-peer`
  embedded in `install.sh`, and `make check-sync` to fail the build on drift.
- `tools/bump-version.sh` to rewrite the release string everywhere it is duplicated.

### Changed

- `MODEL_PEER_STACK` is now a depth-bearing chain (`claude:codex`) rather than a
  membership marker. The self-consultation guard still applies at every depth.
- `model-peer review` no longer overwrites `MODEL_PEER_STACK`, so a review launched
  from inside a peer chain stays subject to the depth guard instead of escaping it.
- The review synthesizer is always a leaf and never consults a peer, at any depth.
- Agent rules consolidated to a single `examples/AGENTS.md` template intended to be
  symlinked as `CLAUDE.md` and `GEMINI.md`; the per-vendor example copies are gone.
- This repository now carries its own `AGENTS.md` under that layout.

### Fixed

- CI had never passed on this repository. `make lint` failed shellcheck from the
  first commit (`SC2034`: `PROGRAM` was set but never used). `err` now uses it, and
  the lint target is clean on both ubuntu and macOS runners.
- Smoke-test stubs used `read -t 0.05`, which is invalid on the Bash 3.2 that macOS
  ships and printed an error on every stubbed call.
- The README's one-line install pointed at a `YOUR_GITHUB_USERNAME` placeholder, so
  the documented `curl` command could never have worked.

## 0.1.0 - 2026-08-07

### Added

- `model-peer` root CLI.
- `model-peer ask claude`, `model-peer ask codex`, and `model-peer ask gemini`.
- `model-peer review` with independent multi-model review and final synthesis.
- Claude Code, OpenAI Codex CLI, and Google Gemini CLI support.
- Read-only consultation defaults for all three providers.
- Gemini Plan mode plus explicit temporary deny policy.
- `MODEL_PEER_STACK` recursion protection.
- Compatibility shortcuts: `ask-claude`, `ask-codex`, `ask-gemini`, `ai-review`.
- `model-peer doctor` setup diagnostics.
- Self-contained installer, uninstaller, example agent rules, and stub smoke tests.
