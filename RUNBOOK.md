# Bedrock live test suite — runbook

Manually-run live tests for `ballerinax/ai.aws.bedrock`. **You** run these against
your AWS account; nothing here runs automatically and nothing calls AWS without
credentials you supply.

- **60 cases**: 7 expected-failure (Block D), 46 combination (Block G), 7 embedding
  (Block F).
- **~56 billable calls.** Still well under a dollar; budget ~10 min. Note the three
  `batchEmbed` cases make 2 extra single-embed calls each, to obtain reference
  vectors for the order check.
- **Token budget is per entry point**, not global: `chat()` uses `maxTokens` (24),
  `generate()` at least 256, `agent()` at least 512. A single small global starved
  the tool-calling paths and made them fail as if the module were broken.

---

## 1. Publish the module locally

The suite depends on `ballerinax/ai.aws.bedrock` from the **local** repository, so
you must publish it before the suite will resolve.

```bash
cd <module repo>/ballerina
bal pack
bal push --repository=local
```

Re-run this **every time you change the module** — otherwise you are testing the
previously published copy.

## 2. Configure credentials

```bash
cd bedrock-live-tests
cp Config.toml.template Config.toml
$EDITOR Config.toml
```

`Config.toml` is gitignored. Never commit it.

Fill in **both** credential kinds if you want the full run: cases G25–G28 test
SigV4 and the Bedrock API key against both endpoints, and a case whose credential
is missing is reported `SKIP`, not `FAIL`.

**Mantle needs a separate IAM permission.** `bedrock:InvokeModel` is *not* enough —
the Mantle endpoint is gated by `bedrock-mantle:CreateInference`, a different IAM
namespace. Without it, every `MANTLE` case fails `AccessDenied` with nothing in the
message explaining why. This is the single most likely cause of a bad first run.

## 3. Dry run first — costs nothing

```bash
bal run -- -Cdasun.bedrock_live_tests.dryRun=true
```

This constructs every provider and makes **zero network calls**. It proves your
config parses and surfaces every construction-time failure for free. Expect:

```
PASS 4   FAIL 0   SKIP 56   (of 60)
```

The 4 passes are Block D construction guards firing correctly, and each prints the
module's own error text as evidence. If any Block D case FAILs here, stop — a guard
that should fire before I/O is not firing.

**This step needs no credentials.** Cases that must fail before any I/O are
constructed with an obvious placeholder credential, because the module runs its
route/guardrail/partition guards before it ever builds a transport. You can run the
dry run on a machine with no AWS account at all.

## 4. Live run

```bash
bal run                                              # everything
bal run -- -Cdasun.bedrock_live_tests.only=D         # one block
bal run -- -Cdasun.bedrock_live_tests.only=G12       # one case
bal run -- -Cdasun.bedrock_live_tests.only=F         # embeddings only
```

Start with `only=G1` (one Converse chat) to confirm credentials work before
spending the full run.

Results print live and land in `results/run.md`, which is gitignored.

## 5. Reading a failure

Every non-pass prints the expectation it broke and the evidence:

```
[FAIL] G9  chat  MANTLE->MANTLE us-east-1 qwen.qwen3-32b-v1:0  (412ms)
        why: Mantle /v1/chat/completions; mantleId DIFFERS from the runtime id
        got: <the actual error, credentials redacted>
```

Before filing a module bug, rule out these three:

| Symptom | Likely cause |
| --- | --- |
| every MANTLE case `AccessDenied` | missing `bedrock-mantle:CreateInference` |
| one model 4xx on a *bare* id | that region is In-Region **NO** — check its row in `capability.bal` |
| `mythos-5` denied | Preview/Beta model; your account may not be entitled |

## Safety

- **Credentials are never printed or written.** `redact()` in `runner.bal` strips
  every configured secret from all output, including error messages — AWS SigV4
  errors routinely echo the canonical request back, which contains the
  `Authorization` header.
- Redaction is **literal**, not regex-based, so a secret containing regex
  metacharacters cannot corrupt the pattern and leak.
- The access key id is masked too. It is not secret, but it identifies the account.

## Open questions and known gaps

### G4 is a deciding experiment, not just a test

**Two first-party AWS sources disagree about Mistral 7B's Invoke body**, and this
suite does not resolve the conflict — it is designed to settle it empirically.

- `model-parameters-mistral-text-completion.html` names Mistral 7B Instruct as a
  **text-completion** model: body is `prompt` with a `<s>[INST]…[/INST]` template.
  The module follows this (`usesMistralTextDialect` in `codecs.bal`).
- The **model card** for the same model gives an InvokeModel sample posting
  `{"messages": [...], "max_tokens": 1024}` — the **chat** dialect — and marks
  Converse as supported.

If **G4 fails with a ValidationException naming `prompt` or `messages`**, the card
is right and the module must drop `mistral-7b-instruct` from
`usesMistralTextDialect`. **Do not change the module before running G4.** If G4
passes, the parameter page is right and the module is already correct.

### Fixed after an independent review

An audit found several cases that passed without testing anything. All are fixed;
recorded here because the failure modes are worth knowing about:

- **D6 never reached the module.** An ARN carries no vendor token, so the harness
  raised its own "no vendor provider" error, which the FAIL_OFFLINE branch counted
  as a pass. The imported-model guard could have been deleted with D6 still green.
- **D3 accepted any error containing "mantle"** — which is also the *hostname*. A
  live call that 403'd would have matched. It now requires the message to name the
  model, to say structured output is unsupported, and to have returned too fast to
  have crossed the network.
- **`batchEmbed` never checked order.** The old check ("no two adjacent vectors are
  identical") passed on a fully reversed array. It now embeds the first and last
  chunk singly and requires them at index 0 and n-1.
- **The "all 10 codecs" claim was false.** `openai.`/`qwen.`/`zai.` share one codec,
  and `INVOKE_MISTRAL_CHAT_CODEC` was reached by nothing. `codecOf` now mirrors the
  module's real registry and a pick was added for the orphaned codec.
- **`FAIL_LIVE` accepted any error**, so a missing IAM permission "proved" whatever
  the case claimed. Environment errors (auth, throttle, DNS) now report SKIP.
- **`expectedRequests` was never asserted** but was printed as if it had been. It is
  now labelled documentation-only; the batch split is unit-tested in the module.

### Resolved since the first draft

- ~~Three rows `regionsVerified: false`~~ — **closed.** All three had real model
  cards (they were previously cited to *parameter* pages, which have no
  availability table). Every row in the table is now verified against a card.
- ~~`mantleId` substitution not asserted~~ — **this gap was mis-stated.** The
  substitution is asserted *offline* in the module's own resolver tests
  (`resolver_test.bal` for `gpt-oss-120b`, `new_models_test.bal` for
  `qwen3-coder-480b` and now `qwen3-32b`). That is the correct place for a wire-shape
  assertion — a live suite proves the call works, a unit test proves the id is right.
  **No echo server is needed, and none is built.** Building one would also require a
  base-URL override the module does not expose.

