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
with it — see [Partial panels](#partial-panels) below.

If a specific CLI hangs consistently, check it outside Model Peer:

```bash
codex exec --sandbox read-only "say hello" </dev/null
```

If that hangs too, the problem is the vendor CLI in your environment — usually
authentication or network — and no Model Peer setting will fix it. `model-peer
doctor` reports what authentication it can see.

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

## Large diffs get truncated

Patches are embedded up to `MODEL_PEER_MAX_DIFF_BYTES` (default 500000). Beyond
that the patch is truncated with an explicit marker and reviewers are told to
inspect the listed files directly.

```bash
MODEL_PEER_MAX_DIFF_BYTES=1000000 model-peer review
```

Consider reviewing a narrower change instead — a reviewer given half a megabyte of
patch tends toward generic findings.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Too few reviewers completed, or `rules check` found missing or stale rules |
| `2` | Usage or validation error |
| `64` | Refused by a chain guard — depth limit or self-consultation |
| `124` | A consultation exceeded its timeout |
| `127` | A required command is not installed |
