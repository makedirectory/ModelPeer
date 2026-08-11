---
id: development
title: Development
sidebar_position: 9
---

# Development

Model Peer is one Bash script. There is no build step and no runtime dependencies
beyond the vendor CLIs.

```bash
make test     # smoke tests against stub CLIs; runs check-sync first
make lint     # bash -n over every script, plus shellcheck when installed
make sync     # regenerate install.sh's embedded copy of bin/model-peer
```

Smoke tests use stub CLIs. They do not contact Anthropic, OpenAI, or Google and do
not consume model usage.

## The duplication invariant

`install.sh` must work standalone when piped from `curl`, so it carries a verbatim
copy of `bin/model-peer` inside a heredoc.

**Any change to `bin/model-peer` must be followed by `make sync`.**

`make check-sync` runs as a prerequisite of `make test` and fails the build
otherwise, and the smoke tests independently install and `cmp` the result. This is
the single easiest way to break the repository.

## Releasing

`VERSION` is the source of truth, but the string is duplicated in the CLI banner,
the installer, the pinned `curl` URLs in the docs, and a smoke-test assertion:

```bash
tools/bump-version.sh <major.minor.patch>
```

That rewrites every occurrence, regenerates `install.sh`'s embedded copy and then sweeps **every tracked file** for
the old string, failing if one survives. The sweep is deliberately broader than the
list of files the script rewrites, so a version pinned in a page nobody remembered
to add still fails the bump rather than shipping stale. `CHANGELOG.md` and the
lockfile are excluded on purpose: old releases keep their own numbers, and npm
dependency versions are not ours.

Write release examples as `<major.minor.patch>` rather than a real version, so a
documentation snippet is never mistaken for a pin. Date the `CHANGELOG.md` entry, then tag the merge
commit on `main`.

## Portability

Target **Bash 3.2** — that is what macOS ships, and CI runs macOS as well as Ubuntu.
Avoid:

- `declare -A` (associative arrays)
- `${var^^}` / `${var,,}` case conversion
- `read -t` with fractional seconds
- bare `"${arr[@]}"` on possibly-empty arrays — use `${arr[@]+"${arr[@]}"}`
- `wait -n` — reviewer fan-in waits in requested order instead, which costs nothing
  because every worker has already been started
- GNU `timeout`, `xargs -P`, GNU `parallel` — none of them ship on macOS

## Parallel reviewers

`cmd_review` starts every requested reviewer before waiting for any of them, then
waits for all of them to reach a terminal state before applying the partial-panel
and `--strict` rules. Parallelism changes *when* independent reviewers run, never
what they receive, what they may do, or how their results are judged.

The process bookkeeping is where this is easy to get subtly wrong:

- **Each worker writes its own file.** `run_provider ... > "$tmpdir/$p.txt"`, never
  a `tee`. A backgrounded pipeline puts `PIPESTATUS` somewhere the parent cannot
  read and lets several model responses share one stdout.
- **Replay is deterministic.** Completed reviews are written to stdout after fan-in,
  in requested-model order. Completion order never reaches the user.
- **A dropped reviewer's partial output is destroyed,** not passed along. A
  truncated finding read as a complete review is worse than no review.
- **Each worker leads its own process group** (`set -m` around the background call),
  so cleanup can signal one worker subtree as a unit.
- **Each worker installs its own traps.** Bash resets inherited traps in a subshell,
  which is what makes this safe — a worker running the parent's `mp_cleanup` would
  delete the shared temp directory out from under its siblings. The parent owns the
  temp directory and the worker registry; a worker owns exactly one vendor process
  tree.
- **A signalled worker forwards the signal downward.** `run_with_limit` publishes
  the supervised process group in `MP_LIMIT_CHILD_PID`; killing only the worker
  shell would leave the vendor CLI running as an orphan holding an open model call.
- **INT and TERM re-raise.** Cleaning up and falling through would continue into
  code whose temp directory has just been deleted.

The primary test is a **concurrency barrier**: the stubs record that they started
and then block until every requested reviewer has done the same. Serial
orchestration can never open it. That is far less flaky than asserting elapsed time
on a shared runner, which the suite does only as secondary evidence.

## Architecture notes

Both consultation paths funnel through `run_provider`, which is the single chokepoint
that enforces the guards, pushes the chain, resolves delegation, and computes the
depth budget before delegating to `run_claude` / `run_codex` / `run_gemini`. Put
policy in `run_provider`, not in the per-provider runners — those exist only to
translate a prompt plus a delegation decision into one vendor's CLI flags.

Keep `depth` and `delegation` separate. Depth is a limit; delegation is a permission
resolved from the provider's ability to hold it narrowly. If you add a provider,
decide its delegation support explicitly — defaulting to unsupported is the safe
answer.

New behavior needs a `tests/smoke.sh` assertion. The stubs make this nearly free, and
they can capture generated artifacts: the Gemini stub copies the generated policy
into the log so its deny rules can be asserted at every depth.

## Docs site

The site in `documentation/` is Docusaurus.

```bash
cd documentation
npm install
npm start          # local dev server
npm run build      # production build; fails on broken links
```

It deploys to GitHub Pages from `main` via `.github/workflows/docs.yml`.
