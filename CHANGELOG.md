# Changelog

All notable changes to Model Peer are documented here.

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
