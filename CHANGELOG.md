# Changelog

All notable changes to Model Peer are documented here.

## 0.6.0 - 2026-08-10

A correctness and security release. Several documented guarantees were stronger
than what the code enforced; each one below was reproduced before it was fixed,
and each has a regression test.

### Fixed

- **A model could appear twice in one chain.** `check_chain` compared only the
  last entry of `MODEL_PEER_STACK`, so `claude → claude` was blocked but
  `claude → codex → claude` was permitted — a model reviewing its own work one
  hop removed, which is exactly what the guarantee ruled out. The guard now tests
  membership across the whole chain.
- **A peer could raise the ceiling it inherited.** `--depth` took precedence over
  the inherited `MODEL_PEER_MAX_DEPTH`, so a peer running under a limit of 2
  could request `--depth 10` and get it, contradicting "the limit propagates down
  the chain". Inside a chain the inherited value is now a hard cap: a peer may
  lower it, never raise it, and the clamp is reported.
- **Synthesis was unbounded.** Every reviewer was bounded by `--timeout`, but the
  synthesis call omitted the argument and fell through to "no limit", so a hung
  synthesizer could hang the run indefinitely after every reviewer succeeded.
- **A delegating Claude peer was granted more than the prompt allowed.** The
  grant was `Bash(model-peer:*)`, and `model-peer` stopped being a read-only
  executable when `init` and `update` arrived — a peer could have rewritten the
  workspace's skills. Delegation now grants `Bash(model-peer _delegate:*)` only.
- Temporary directories are removed on interrupt, not just on the normal path.
  The review context holds the diff and the contents of untracked files, and an
  interrupted run left it in the system temp directory.

### Added

- `model-peer _delegate <model> "<question>"`, the only command a delegating peer
  is authorized to run. It inherits every limit, accepts no options, and cannot
  reach `init`, `update`, `review`, `trust`, or `doctor`. The executable
  capability now matches what the prompt authorizes rather than depending on the
  peer choosing to obey it.
- `model-peer trust` marks a directory as trusted for Gemini CLI, which otherwise
  refuses to load project skills and reports none at all. It adds one
  `TRUST_FOLDER` entry to `~/.gemini/trustedFolders.json` and touches nothing
  else. Codex loads project skills without trust and Claude Code prompts
  interactively, so neither is modified. Folder trust is a security control, so
  `init` never does this for you.
- A second skill. `cross-model-review` cross-checks a diff across the panel;
  `cross-model-consult` gets one peer's opinion on one question. They fire on
  different cues, and one description covering both triggers neither well. Each
  gets its own slash command: `/peer-review` and `/peer-ask`.

### Changed

- **`review` no longer accepts `--depth`.** Reviewers and the synthesizer are
  always leaves. Reviewers that can consult one another are not independent
  observations, which is the entire value of the panel — and the review prompt
  already told reviewers not to consult anyone, contradicting the outer
  consultation prompt at depth > 1. `--depth` now exits `2` pointing at `ask`.
  `ask` explores; `review` cross-checks.
- The README heading is now "By default, there is no chat between models", with
  the depth-1 and depth-\>1 topologies shown, since `ask --depth` genuinely does
  let one model consume another's answer.
- **This project now runs `model-peer init` on itself.** The skills under
  `.claude/`, `.codex/`, and `.gemini/` are the real installed artifacts, live in
  the repository that produces them. `make sync` refreshes them with
  `model-peer update`, and `make check-sync` fails the build when they drift from
  `bin/model-peer` — so the dogfood and the drift check are the same thing.
- `examples/` is removed, superseded by the above. It predated `init` and had
  become a third copy of the skill text, after `bin/model-peer` and the copy
  embedded in `install.sh`. The skills are the examples, and they are installable.
- The hand-written `.claude/rules/cross-model-consultation.md`,
  `.codex/rules/cross-model-consultation.md`, and `.gemini/global_rules.md` are
  deleted. The first duplicated the consult skill and drifted from it; the other
  two were never loaded by anything.
- `init --print` takes `review`, `consult`, `review-command`, or
  `consult-command`.

Thanks to the reviewer who worked through `main` as a maintainer would; items 1–5
above came from that read.

## 0.5.0 - 2026-08-10

Setup is now a skill. Every file `init` writes is self-contained and owned by
Model Peer, in the directory each vendor set aside for exactly this. Nothing of
the developer's is read, written, or symlinked.

```text
.claude/skills/cross-model-review/SKILL.md
.codex/skills/cross-model-review/SKILL.md
.gemini/skills/cross-model-review/SKILL.md
.claude/commands/peer-review.md
```

### Added

- `model-peer update` refreshes the managed files already installed in a project
  so they match the running version. It only touches files that already exist and
  that Model Peer wrote, and never installs an agent that is not already present,
  so it cannot quietly widen a repository's footprint.
- `model-peer update --check` reports drift and exits `1` without writing —
  the CI form.
- `model-peer init --print[=AGENT]` writes a `SKILL.md` to stdout and touches
  nothing. `AGENT` is `claude`, `codex`, `gemini`, or `command`.
- A managed-file marker, so Model Peer can tell a file it wrote from one a
  developer put at the same path. Foreign files are reported and left alone
  unless `--force`.

### Changed

- **`init` installs an agent skill per CLI instead of editing rules files.** All
  three vendors support `<vendor-dir>/skills/<name>/SKILL.md`, which is the only
  mechanism common to them that is self-contained. Because nothing Model Peer
  writes lives inside a file someone else owns, managed files are compared and
  replaced whole — no marker surgery — which is what makes `update` tractable.
- `AGENTS.md`, `CLAUDE.md`, and `GEMINI.md` are never read, written, appended to,
  or symlinked. `--agents` defaults to all three CLIs again, because including
  one no longer means editing anything of yours.
- The skill's `description` carries the trigger conditions, not just a summary.
  Only `name` and `description` reach the model's system prompt; the body loads
  on activation, so a description that merely says what the skill is would never
  fire it.
- `model-peer rules <install|print|check>` is replaced by `init` and `update`.
- `model-peer doctor` reports which skills the current project has installed.
- `examples/AGENTS.md` becomes `examples/SKILL.md`, generated from
  `model-peer init --print`.
- `init` warns that Gemini only loads project skills in a trusted folder, rather
  than leaving the developer to discover an empty `gemini skills list`.

### Fixed

- Corrects a claim made in 0.3.0. `.codex/rules/` **is** a real directory Codex
  reads, but it holds Starlark `.rules` files controlling which commands Codex may
  run outside its sandbox — a permissions mechanism, not agent context. Markdown
  there is still ignored, but not for the reason previously documented.
- `.agents/skills/` is a Gemini-only alias; Codex and Claude Code do not read it,
  so each vendor's own directory is used.

Skill discovery was verified against the shipping CLIs rather than their
documentation: `gemini skills list` reports the installed skill, a `codex exec`
run lists it among its available skills, and Claude Code quotes its description
back from the system prompt.

## 0.4.0 - 2026-08-10

`model-peer init` was intrusive. It wrote the developer's `AGENTS.md`, and
symlinked `CLAUDE.md` and `GEMINI.md` to it — rearranging root context files that
belong to the project, not to Model Peer. A tool that does that uninvited does not
get run twice.

### Changed

- **`init` now writes only files Model Peer owns.** By default that is
  `.claude/rules/cross-model-consultation.md` and `.claude/commands/peer-review.md`,
  and nothing else. `AGENTS.md` and `GEMINI.md` are never written unless their CLI
  is named in `--agents`; `CLAUDE.md` is never written at all; no symlinks are ever
  created.
- `--agents` now defaults to `claude` rather than all three. Claude Code is the
  only one of the three with a per-repository rules directory, so it is the only
  one that can be wired up without editing a file the developer owns. Opt in with
  `model-peer init --agents claude,codex,gemini`.
- A default run states what it deliberately left alone, and how to include it, so
  nobody assumes Codex and Gemini were wired up when they were not.
- `--split` was removed. Every profile is per-CLI now, so the flag had nothing left
  to select; it exits `2` with the replacement command rather than being silently
  ignored.
- `tools/bump-version.sh` sweeps every tracked file for the old version rather
  than only the files it rewrites, and regenerates `examples/AGENTS.md` alongside
  the embedded installer copy.

### Fixed

- **A symlinked `AGENTS.md` or `GEMINI.md` was written through.** In the old
  `--split` layout, writing the Gemini block to a `GEMINI.md` that symlinked to
  `AGENTS.md` silently rewrote `AGENTS.md` under a profile meant for a different
  model. Symlinked context files are now refused unless `--force`.
- The default run never created `.claude/rules/`, so the one file Model Peer can
  install non-intrusively was the one thing `init` did not write. On a repo whose
  `.gitignore` covers `.claude/*`, reverting the intrusive edits left the slash
  command as the only surviving artifact — which read as "init only installs the
  Claude command".

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
