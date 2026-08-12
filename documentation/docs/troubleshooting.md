---
id: troubleshooting
title: Troubleshooting
sidebar_position: 8
---

# Troubleshooting

Most Model Peer failures are one of a handful of orchestration problems. Each has a
distinct signature.

## A reviewer hangs

**Signature:** one reviewer produces nothing for minutes; the run appears frozen.

Every consultation is bounded by a wall-clock timeout, 600 seconds by default:

```bash
model-peer review --timeout 300      # per reviewer
model-peer ask codex --timeout 120
model-peer review --timeout 0        # disable the bound
```

Progress is reported on stderr every 30 seconds, so a slow consultation is
distinguishable from a dead one:

```text
model-peer: Codex still working (120s of 600s).
```

On timeout, Model Peer signals the peer's whole **process group**, not just the
process it launched. Vendor CLIs spawn helper processes that inherit stdout; killing
only the parent leaves those helpers holding the pipe open and the hang survives the
kill. `ask` exits `124` in this case, matching `timeout(1)`.

A reviewer that times out is dropped from the panel rather than taking the whole run
with it — see [Partial panels](#partial-panels) below. Because reviewers run
concurrently, each timeout window starts when the panel does, so one stalled vendor
no longer delays the models behind it.

If a specific CLI hangs consistently, check it outside Model Peer:

```bash
codex exec --sandbox read-only "say hello" </dev/null
```

If that hangs too, the problem is the vendor CLI in your environment — usually
authentication or network — and no Model Peer setting will fix it.

`model-peer doctor --probe` answers this directly. It runs one real consultation
per CLI and reports which ones responded, so a hang shows up as
`no answer within Ns — nothing verified` against that CLI alone rather than as a
mysterious slow review.

## A review looks busy all at once

**Signature:** several models appear to start at the same moment, and stderr lines
from different providers arrive interleaved and in a different order each run.

That is expected. Reviewers are independent, so they run concurrently: all of them
start before Model Peer waits for any of them, and the reviewer phase costs roughly
the slowest model rather than the sum of them.

```text
Starting Claude independent review...
Starting Codex independent review...
Starting Gemini independent review...
model-peer: Codex still working (30s of 600s).
```

Model output itself is buffered per reviewer and replayed after the panel finishes,
in the order the models were requested. stdout therefore never contains interleaved
model responses and does not depend on which reviewer happened to finish first:

```bash
model-peer review > review.txt      # reproducible, whatever the finishing order
```

Interrupting a parallel review with Ctrl-C stops every reviewer and the vendor
process tree beneath each one, so no model call is left running in the background.

Parallel review reduces elapsed time, not provider usage — every requested reviewer
is still invoked exactly once. Aborting a run early may mean more concurrent work
was already consumed than under serial execution.

## Partial panels

A reviewer that times out, exits non-zero, **or exits `0` having produced nothing**
is dropped and named. Synthesis proceeds as long as at least two reviewers produced
a real review, because two independent views are the minimum that makes a
cross-model review worth the name.

```text
model-peer: Codex timed out after 600s; dropping it from the panel.
model-peer: synthesizing from 2 of 3 reviewers; the report will name the gaps.
```

The synthesizer is told which reviewers are missing and instructed to say so in the
report — a gap in coverage is not evidence of safety, and a partial panel must never
read as a complete one.

Fewer than two survivors is refused outright (exit `1`). To restore the older
behavior of refusing whenever any reviewer fails:

```bash
model-peer review --strict
```

## Gemini hangs instead of answering

**Signature:** Gemini produces nothing and never exits. `model-peer doctor --probe`
reports `no answer within Ns — nothing verified`, while `gemini` used
interactively works fine.

Usually an auth mismatch. Gemini records one chosen sign-in method in
`~/.gemini/settings.json`; if that method's credential is missing, a **headless**
run does not fail — it blocks on a prompt that stdin cannot answer. Interactively
it works because Gemini can ask you.

```bash
model-peer doctor
```

```text
Gemini authentication: API key selected, and no GEMINI_API_KEY is visible in the environment
                       or in a .env Gemini would load. It may still hold one in its
                       credential store, which no shell can read — so this is not
                       necessarily a problem...
```

`doctor` deliberately stops short of calling this broken, because it cannot see
everything Gemini can. Mirroring the CLI's own `validateAuthMethod`, these are the
credentials each recorded method actually accepts:

| `selectedType` | What Gemini accepts |
|---|---|
| `oauth-personal`, `compute-default-credentials` | Anything — it performs no local credential check |
| `gemini-api-key` | `GEMINI_API_KEY`, from the environment **or** a `.env` it loads, **or** a key in its own credential store |
| `vertex-ai` | `GOOGLE_CLOUD_PROJECT` **and** `GOOGLE_CLOUD_LOCATION`, **or** `GOOGLE_API_KEY` for express mode |

Gemini searches for that `.env` from the current directory upward, preferring
`<dir>/.gemini/.env` over `<dir>/.env`, then falling back to `~/.gemini/.env` and
`~/.env`. A key set in any of them is invisible to your shell but perfectly visible
to Gemini — which is why a setup can work while `doctor` cannot confirm it.

Fix it by supplying the credential the recorded method expects:

```bash
export GEMINI_API_KEY=...   # for selectedType: gemini-api-key
gemini                      # or re-run interactively and pick another method
```

To settle it rather than guess, run the probe — it is the only check that actually
consults the model:

```bash
model-peer doctor --probe --models gemini
```

The tell that this is auth and not a Model Peer problem: with a *deliberately
wrong* key the same call fails in about a second with HTTP 400, while with no key
it hangs indefinitely.

## Gemini returns nothing at all

**Signature:** Gemini exits `0` immediately, having written no output. Interactively
it complains about an untrusted directory.

Gemini's folder-trust gate blocks work in directories it has not been told to trust,
and headlessly that failure is silent. Model Peer passes `--skip-trust` so a
non-interactive consultation is not a silent no-op.

This is safe here because Model Peer does not rely on the trust gate for its
guarantees: Gemini is already run in Plan mode, with an explicit deny policy for
`write_file`, `replace`, `run_shell_command`, `enter_plan_mode`, and
`exit_plan_mode`, and with extensions disabled via `-e none`. See
[Safety boundaries](safety).

The flag is feature-detected from `gemini --help`, so older builds that lack it are
invoked as before.

Independently of the trust gate, any reviewer returning zero bytes is now treated as
a failure rather than as "this model found no issues".

## New files are missing from a review

**Signature:** a reviewer comments only on modified files and ignores a package you
just created.

This was a real bug, fixed. `git diff HEAD` cannot see untracked files, and
`git status --short` collapses a new directory to a single `?? src/` line — so an
entire new package could reach a reviewer as one path with no filenames and no
contents.

Review context now includes an add-diff for every untracked, non-ignored file:

```text
<git_patch bytes="…" max_embedded_bytes="500000" includes_untracked="true">
```

`.gitignore` is respected, and binaries are summarized as
`Binary files … differ` rather than dumped into the prompt. Confirm what a reviewer
would see with:

```bash
git status --short --branch --untracked-files=all
```

If a file is missing from that list, it is ignored by Git and Model Peer will not
send it.

## A skill is installed but never fires

Only a skill's `name` and `description` reach the model's system prompt; the body
loads when the model decides the skill applies. If a skill never activates, the
description is usually the reason — it has to name the situations that should
trigger it, not just describe what the skill is.

`model-peer update` rewrites the shipped description, so start there:

```bash
model-peer update --check
```

For Gemini specifically, check folder trust. In an untrusted directory it reports
`Skipping project agents due to untrusted folder` and loads no project skills at
all. Trust the directory once from an interactive `gemini` session.

```bash
gemini skills list        # should list cross-model-review
```

## Large diffs get truncated

Patches are embedded up to `MODEL_PEER_MAX_DIFF_BYTES` (default 500000). Beyond
that the patch is truncated with an explicit marker and reviewers are told to
inspect the listed files directly.

```bash
MODEL_PEER_MAX_DIFF_BYTES=1000000 model-peer review
```

Consider reviewing a narrower change instead — a reviewer given half a megabyte of
patch tends toward generic findings.

## Is the read-only contract actually holding?

```bash
model-peer doctor --probe
```

This runs one real consultation per installed CLI in a throwaway repository and
checks **on disk** that nothing was written — a model's assurance that it could
not write is not evidence. See [the reference](reference#doctor---probe).

Worth running after upgrading any of the vendor CLIs, since that is when the
behaviour Model Peer depends on is most likely to have changed.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Too few reviewers completed, or `update --check` found missing or stale files |
| `2` | Usage or validation error |
| `64` | Refused by a chain guard — depth limit or self-consultation |
| `124` | A consultation exceeded its timeout |
| `127` | A required command is not installed |
