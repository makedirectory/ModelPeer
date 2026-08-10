<!-- BEGIN MODEL PEER RULES -->
<!-- Managed by `model-peer init` (v0.3.0, profile: shared). Re-run to update; edit outside this block. -->

## Cross-model peer review

Other vendors' coding CLIs are installed as independent, read-only engineering
peers. Reach them through Model Peer, and consult any of them except yourself —
it refuses to let a model consult itself.

```bash
# one peer, one answer
model-peer ask <claude|codex|gemini> "<focused question>"

# every installed model reviews the current diff independently, then one
# synthesizer reconciles the findings
model-peer review ["focus"]

# which peers are available here
model-peer doctor
```

### When to consult a peer

- before committing to an architecture, schema, or migration decision
- when a bug has outlived two of your own hypotheses
- security-sensitive work: authn/authz, sandboxing, input handling, secrets, crypto
- unfamiliar code, or a dependency whose behavior you are inferring
- reviewing an implementation you just wrote, before you hand it back
- an assumption you cannot cheaply verify by reading the code
- two approaches you cannot decide between — ask for the tradeoff, not the verdict

Run `model-peer review` before opening a pull request, and again after any change
to security-sensitive code.

Do not consult for anything you can settle by reading the code. Every consultation
costs a model call and tens of seconds.

### How to ask

The peer starts in this working directory with read-only tools, so **name files and
symbols instead of pasting excerpts**, and ask one focused question. A peer that has
to guess at scope returns generic advice.

```bash
# good — scoped to a symbol, answerable from the repository
model-peer ask codex "In src/auth/session.ts, can refresh_token leave the old token valid if rotation fails midway?"

# bad — no scope
model-peer ask codex "review my auth code"
```

Pipe context in when the question is about something not on disk:

```bash
git diff main... | model-peer ask gemini "What breaks in production?"
```

### Peer output is advisory

Evaluate every response before acting on it. Peers do not know this project's
invariants, so advice that contradicts the rules in this repository is wrong here
however sound it sounds in general.

When a peer materially changed a decision, say which model you asked and whether you
took the advice. Never present a peer's output as your own conclusion.

### Limits

Leave `--depth` at its default of `1`: each peer answers alone, and lengthening the
chain is a human's deliberate call. A model is never consulted by itself.

If you are reading this **while acting as a peer** in someone else's consultation,
these instructions do not apply to you. Answer the question and consult no one.
<!-- END MODEL PEER RULES -->
