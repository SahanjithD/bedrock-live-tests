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
PASS 4   FAIL 0   SKIP 56   (of 60 selected)
Live calls that reached AWS: 0
```

The SKIP banner fires here — that is correct for a dry run and does not affect the
exit code. `strict` skip-checking is suppressed under `dryRun`.

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
bal run -- -Cdasun.bedrock_live_tests.only=G1,G2,G3  # a specific few
bal run -- -Cdasun.bedrock_live_tests.only=F         # embeddings only
```

Start with `only=G1` (one Converse chat) to confirm credentials work before
spending the full run.

### Running a few at a time

`offset` and `limit` take a window of the selected cases, in the fixed run order
D → G → F. This is the way to work through the suite in small batches without
listing ids by hand:

```bash
bal run -- -Cdasun.bedrock_live_tests.offset=0  -Cdasun.bedrock_live_tests.limit=5   # 1-5
bal run -- -Cdasun.bedrock_live_tests.offset=5  -Cdasun.bedrock_live_tests.limit=5   # 6-10
bal run -- -Cdasun.bedrock_live_tests.offset=10 -Cdasun.bedrock_live_tests.limit=5   # 11-15
```

The window applies **after** `only`, so you can page within one block:
`only=G offset=0 limit=5` gives G1–G5. `bal run -- -Cdasun.bedrock_live_tests.listOnly=true`
prints the full ordered list so you can map positions to ids.

### Exit codes

`bal run` exits **non-zero** if anything failed, and — by default — also if
anything was **skipped**. A skipped case tested nothing, so a run full of skips is
not a pass. If skips are expected (say you have SigV4 keys but no Bedrock API key,
so G26/G28 cannot run), silence that with:

```bash
bal run -- -Cdasun.bedrock_live_tests.strict=false
```

Failures always exit non-zero regardless of `strict`.

Results print live and land in `results/run.md`, which is gitignored. The report
header carries the PASS/FAIL/SKIP totals and the number of calls that actually
reached AWS.

## 5. What a PASS means — and what it does not

Read this before reporting a green run as "the module works".

**A green run is not automatically a meaningful run.** Check three numbers, in this
order:

1. **SKIP count.** A skip ran nothing. The most common cause is a missing or empty
   `Config.toml`, which skips all 56 live cases while the terminal shows no
   failures. The suite now prints a banner and exits non-zero for this, but read
   the number yourself.
2. **"Live calls that reached AWS".** This can be `0` on an all-PASS run — the
   Block D guards all pass offline. Zero live calls means nothing was verified
   against AWS at all.
3. **PASS count**, last.

**What a Block G PASS asserts:** the provider constructed, AWS accepted the request
and returned 2xx, and a non-empty response decoded.

**What it does not assert:**

| Not checked | Why |
| --- | --- |
| Request bytes on the wire | There is no echo server (see *No echo server*, below). Every `covers` string describing a header, body field, codec dialect, signing scope or id substitution states **intent** — which module path the case walks — not a verified result. Those belong in the module's offline codec tests. |
| `expectedFamily` | `resolveRoute` is module-private and no provider exposes its resolved route. The harness computes the expected family for **display only**, so `AUTO->MANTLE` in the output is what we predicted, not what happened. RESOLVER_PICKS prove "an AUTO call worked", not "AUTO landed correctly". |
| Answer correctness (`chat`) | Only non-emptiness. `"I cannot help with that"` passes. Deliberate — models are non-deterministic and this is a codec suite. |
| Field *values* (`generate`) | Only that the record parsed and two string fields are non-blank. A wrong city passes. |
| Request **count** (`embed`) | Not observable without instrumenting the transport. `expectedRequests` documents intent. |

**What is genuinely verified:** Block D guards now assert the *specific* error text
(`expectMessage`), so a different construction failure no longer passes. Block F
verifies embedding **order** against singly-embedded reference vectors and asserts
the vector **dimension**. `agent` requires the exact product `14503747` in the
answer — strong evidence the tool ran, though a model that multiplies correctly on
its own would also pass.

## 6. Reading a failure

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

## 7. Safety

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

