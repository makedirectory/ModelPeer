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
tools/bump-version.sh 0.3.0
```

That rewrites every occurrence, regenerates the embedded installer copy, and fails
if any stale occurrence survives. Date the `CHANGELOG.md` entry, then tag the merge
commit on `main`.

## Portability

Target **Bash 3.2** — that is what macOS ships, and CI runs macOS as well as Ubuntu.
Avoid:

- `declare -A` (associative arrays)
- `${var^^}` / `${var,,}` case conversion
- `read -t` with fractional seconds
- bare `"${arr[@]}"` on possibly-empty arrays — use `${arr[@]+"${arr[@]}"}`

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
