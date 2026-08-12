# Changelog

All notable changes to Model Peer are documented here.

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
