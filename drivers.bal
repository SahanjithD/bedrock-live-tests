// Drivers — the code that actually exercises the module.
//
// Each driver turns one Case into one Result. The assertions are deliberately
// weak on CONTENT (models are non-deterministic) and strict on STRUCTURE: that a
// reply came back non-empty, that a typed generate() produced the right record
// shape, that an agent actually CALLED the tool, that embeddings came back in
// input order with the right vector count.
//
// The agent cases use one deterministic tool so a correct run has a checkable
// answer instead of a plausible-looking one.

import ballerina/ai;
import ballerina/io;
import ballerinax/ai.aws.bedrock;

// ---------------------------------------------------------------------------
// The shared agent tool.
// ---------------------------------------------------------------------------

# Multiplies two integers. Deliberately an operation models get wrong when they
# answer from memory instead of calling the tool: the expected product is large
# and not a round number, so a correct answer is strong evidence the tool ran.
#
# + a - first factor
# + b - second factor
# + return - the product
@ai:AgentTool
public isolated function multiply(int a, int b) returns int => a * b;

const int FACTOR_A = 3607;
const int FACTOR_B = 4021;
const int EXPECTED_PRODUCT = 14503747; // 3607 * 4021

# The one-word answer every chat case must contain. The question ("Name the capital
# city of France") has a single unambiguous answer in every language the models
# reply in, which is what makes it safe to assert on a non-deterministic system.
const string EXPECTED_CAPITAL = "paris";

// ---------------------------------------------------------------------------
// The generate() target type.
// ---------------------------------------------------------------------------

# A small record with three distinct field types, so a wrong schema shows up as a
# conversion error rather than a plausible-but-wrong value.
public type CityFact record {|
    # City name.
    string city;
    # Country the city is in.
    string country;
    # Rough population in millions.
    decimal populationMillions;
|};

// ---------------------------------------------------------------------------
// chat()
// ---------------------------------------------------------------------------

isolated function driveChat(Case c) returns Result {
    int t0 = nowMs();
    string detail = string `${c.family}->${c.expectedFamily} ${c.region} ${c.wireId}`;

    ai:ModelProvider|Skip|ai:Error provider = providerFor(c);
    if provider is Skip {
        return mkResult(c.id, "chat", detail, SKIP, nowMs() - t0, provider.reason,
                "case did not run — credential not configured");
    }
    if provider is ai:Error {
        return constructionOutcome(c, provider, detail, nowMs() - t0);
    }
    // `withStop` cases fail inside chat() at encode time, not at construction, so
    // constructing successfully is correct for them.
    if c.expect == FAIL_OFFLINE && !c.withStop {
        return mkResult(c.id, "chat", detail, FAIL, nowMs() - t0,
                "provider constructed successfully",
                string `expected a CONSTRUCTION error: ${c.why}`);
    }
    if dryRun {
        return mkResult(c.id, "chat", detail, SKIP, nowMs() - t0,
                "constructed OK; live call skipped (--dry-run)", c.why);
    }

    ai:ChatMessage[] messages = [
        {role: ai:SYSTEM, content: "Answer in at most five words."},
        {role: ai:USER, content: "Name the capital city of France."}
    ];
    // A stop sequence the Responses dialect cannot express; the module must
    // refuse it rather than drop it silently.
    // See driveGenerate: the encode-time guard below is timed, so it must measure
    // the call alone. `t0` includes provider construction and would make the check
    // order-dependent — D4 passed only because an earlier case warmed the JVM.
    ai:ChatAssistantMessage|ai:Error reply;
    int tCall = nowMs();
    if c.withStop {
        reply = provider->chat(messages, [], "STOPHERE");
    } else {
        reply = provider->chat(messages, []);
    }
    int callMs = nowMs() - tCall;
    int ms = nowMs() - t0;

    if reply is ai:Error {
        if c.expect == FAIL_OFFLINE {
            // This refusal must be raised locally at encode time. If it looks like
            // it came back from AWS, the module DROPPED the parameter and shipped
            // the request - the exact bug the case exists to catch.
            string msg = reply.message();
            if isEnvironmentError(msg) || callMs > 400 {
                return mkResult(c.id, "chat", detail, FAIL, ms, msg,
                        "expected a LOCAL refusal before any I/O, but the error " +
                        "looks like it came back from AWS - the parameter was " +
                        "probably sent instead of refused");
            }
            return mkResult(c.id, "chat", detail, PASS, ms, msg, c.why);
        }
        return liveErrorOutcome(c, "chat", detail, reply, ms);
    }
    string? content = reply.content;
    if content is () || content.trim() == "" {
        return mkResult(c.id, "chat", detail, FAIL, ms, "empty content",
                "chat() returned a message with no content", live = true);
    }
    // CORRECTNESS, not just connectivity.
    //
    // A non-empty reply only proves the round trip worked; "I don't know" would have
    // passed. The prompt has exactly one right answer, so requiring it turns a PASS
    // from "AWS answered" into "the model received the prompt, understood it, and
    // the decode returned real content". Deliberately the ONLY content assertion —
    // anything more specific would be scoring the model, not the module.
    if !content.toLowerAscii().includes(EXPECTED_CAPITAL) {
        return mkResult(c.id, "chat", detail, FAIL, ms, content,
                string `reply does not contain "${EXPECTED_CAPITAL}" — the round trip ` +
                string `worked but the model did not answer the question, which ` +
                string `usually means the prompt was mangled in encoding`,
                live = true);
    }
    if c.expect != PASS_LIVE {
        return mkResult(c.id, "chat", detail, FAIL, ms, content,
                string `expected this to FAIL: ${c.why}`, live = true);
    }
    return mkResult(c.id, "chat", detail, PASS, ms, content, c.why, live = true);
}

// ---------------------------------------------------------------------------
// generate()
// ---------------------------------------------------------------------------

isolated function driveGenerate(Case c) returns Result {
    int t0 = nowMs();
    string detail = string `${c.family}->${c.expectedFamily} ${c.region} ${c.wireId}`;

    ai:ModelProvider|Skip|ai:Error provider = providerFor(c);
    if provider is Skip {
        return mkResult(c.id, "generate", detail, SKIP, nowMs() - t0, provider.reason,
                "case did not run — credential not configured");
    }
    if provider is ai:Error {
        return constructionOutcome(c, provider, detail, nowMs() - t0);
    }
    if dryRun {
        return mkResult(c.id, "generate", detail, SKIP, nowMs() - t0,
                "constructed OK; live call skipped (--dry-run)", c.why);
    }

    // Time the CALL, not construction+call. The "did this cross the network?"
    // heuristic below compares against a few hundred ms, and `t0` is taken before
    // the provider is built — so on the first case in a fresh JVM, class loading
    // alone blew the budget and D3 failed with its guard working perfectly. The
    // threshold must only ever see time spent inside generate().
    int tCall = nowMs();
    CityFact|ai:Error got = provider->generate(
            `Give one fact about Paris, France as structured data.`);
    int callMs = nowMs() - tCall;
    int ms = nowMs() - t0;

    if got is ai:Error {
        // A Mantle route MUST refuse a typed target BEFORE any I/O.
        //
        // Checking for the substring "mantle" alone is worthless: it is also the
        // HOSTNAME (bedrock-mantle.{region}.api.aws), so a live call that failed
        // with AccessDenied would match and the case would pass on exactly the
        // regression it exists to catch. Three independent signals instead:
        //   1. the message names the MODEL (Amendment 1 requires it),
        //   2. it says structured output is unsupported (not an auth/network error),
        //   3. it returned too fast to have crossed the network.
        if c.expect == FAIL_OFFLINE {
            string msg = got.message();
            string lower = msg.toLowerAscii();
            boolean namesModel = msg.includes(c.wireId);
            boolean namesReason = lower.includes("structured output")
                || lower.includes("not supported on bedrock-mantle");
            boolean looksNetworked = lower.includes("accessdenied")
                || lower.includes("status code") || lower.includes("connection")
                || callMs > 400;
            if namesModel && namesReason && !looksNetworked {
                return mkResult(c.id, "generate", detail, PASS, ms, msg, c.why);
            }
            string missing = !namesModel ? "does not name the model"
                : (!namesReason ? "does not say structured output is unsupported"
                    : "looks like it crossed the network - the guard did not fire before I/O");
            return mkResult(c.id, "generate", detail, FAIL, ms, msg,
                    string `refusal arrived but ${missing}`);
        }
        return liveErrorOutcome(c, "generate", detail, got, ms);
    }
    if c.expect == FAIL_OFFLINE {
        return mkResult(c.id, "generate", detail, FAIL, ms, got.toJsonString(),
                string `expected a refusal: ${c.why}`, live = true);
    }
    if got.city.trim() == "" || got.country.trim() == "" {
        return mkResult(c.id, "generate", detail, FAIL, ms, got.toJsonString(),
                "record parsed but required string fields are empty", live = true);
    }
    return mkResult(c.id, "generate", detail, PASS, ms, got.toJsonString(), c.why, live = true);
}

// ---------------------------------------------------------------------------
// agent()
// ---------------------------------------------------------------------------

isolated function driveAgent(Case c) returns Result {
    int t0 = nowMs();
    string detail = string `${c.family}->${c.expectedFamily} ${c.region} ${c.wireId}`;

    ai:ModelProvider|Skip|ai:Error provider = providerFor(c);
    if provider is Skip {
        return mkResult(c.id, "agent", detail, SKIP, nowMs() - t0, provider.reason,
                "case did not run — credential not configured");
    }
    if provider is ai:Error {
        return constructionOutcome(c, provider, detail, nowMs() - t0);
    }
    if dryRun {
        return mkResult(c.id, "agent", detail, SKIP, nowMs() - t0,
                "constructed OK; live call skipped (--dry-run)", c.why);
    }

    ai:Agent|ai:Error agent = new (
        systemPrompt = {
            role: "calculator",
            instructions: "Use the multiply tool for any multiplication. " +
                "Reply with the numeric result only."
        },
        model = provider,
        tools = [multiply],
        maxIter = 3
    );
    if agent is ai:Error {
        return mkResult(c.id, "agent", detail, FAIL, nowMs() - t0, agent.message(),
                "ai:Agent construction failed");
    }

    string|ai:Error answer = agent.run(
            string `What is ${FACTOR_A} multiplied by ${FACTOR_B}?`);
    int ms = nowMs() - t0;

    if answer is ai:Error {
        return liveErrorOutcome(c, "agent", detail, answer, ms);
    }
    // The tool ran iff the exact product appears. A model answering from memory
    // gets this wrong — that is the point of choosing an awkward product.
    if !answer.includes(EXPECTED_PRODUCT.toString()) {
        return mkResult(c.id, "agent", detail, FAIL, ms, answer,
                string `agent did not produce ${EXPECTED_PRODUCT} — the tool was ` +
                string `likely never called, or its result was not fed back in`);
    }
    return mkResult(c.id, "agent", detail, PASS, ms, answer, c.why, live = true);
}

// ---------------------------------------------------------------------------
// embed() / batchEmbed()
// ---------------------------------------------------------------------------

# Distinguishable chunks: each carries its index in the text, so an out-of-order
# reassembly is detectable from the vectors alone.
isolated function chunksFor(int n) returns ai:TextChunk[] {
    ai:TextChunk[] chunks = [];
    foreach int i in 0 ..< n {
        chunks.push({content: string `Item number ${i}: a short distinct sentence.`});
    }
    return chunks;
}

isolated function driveEmbed(EmbedCase c) returns Result {
    int t0 = nowMs();
    EmbedCap cap = EMBED_MODELS.get(c.model);
    string detail = string `${cap.id} ${c.region} chunks=${c.chunks}`;

    bedrock:BedrockCredentials|string creds = credentialsFor("default");
    if creds is string {
        return mkResult(c.id, c.entry, detail, SKIP, nowMs() - t0, creds,
                "no credentials configured");
    }

    ai:EmbeddingProvider|ai:Error provider;
    if c.model == "titan-v2" {
        provider = new bedrock:TitanEmbeddingProvider(creds, cap.id, c.region);
    } else {
        bedrock:CohereInputType it = c.inputType == "search_query"
            ? bedrock:SEARCH_QUERY : bedrock:SEARCH_DOCUMENT;
        provider = new bedrock:CohereEmbeddingProvider(creds, cap.id, c.region,
                inputType = it);
    }
    if provider is ai:Error {
        return mkResult(c.id, c.entry, detail, FAIL, nowMs() - t0, provider.message(),
                "embedding provider construction failed");
    }
    if dryRun {
        return mkResult(c.id, c.entry, detail, SKIP, nowMs() - t0,
                "constructed OK; live call skipped (--dry-run)", c.why);
    }

    if c.entry == "embed" {
        ai:Embedding|ai:Error v = provider->embed(chunksFor(1)[0]);
        int ms = nowMs() - t0;
        if v is ai:Error {
            return mkResult(c.id, c.entry, detail, FAIL, ms, v.message(), c.why,
                    live = true);
        }
        if v !is float[] || v.length() == 0 {
            return mkResult(c.id, c.entry, detail, FAIL, ms, v.toString(),
                    "expected a non-empty float vector", live = true);
        }
        // DIMENSION, not just non-emptiness. "length > 0" passed a 1-element
        // vector, so a truncated or wrong-model response was indistinguishable
        // from a correct one. The expected dimension is on the model card.
        if v.length() != cap.dim {
            return mkResult(c.id, c.entry, detail, FAIL, ms,
                    string `dim=${v.length()}`,
                    string `expected a ${cap.dim}-dimension vector for ${cap.id} but ` +
                    string `got ${v.length()} — wrong model, or a truncated response`,
                    live = true);
        }
        return mkResult(c.id, c.entry, detail, PASS, ms,
                string `dim=${v.length()}`, c.why, live = true);
    }

    // ORDER VERIFICATION.
    //
    // The previous check — "no two ADJACENT vectors are byte-identical" — passed on
    // a fully REVERSED array and on a shuffle across the 96/4 batch seam. It did not
    // test what its `why` string claimed. Vectors are opaque floats, so order can
    // only be judged against a known reference: embed the first and last chunk
    // SINGLY, then require them to land at index 0 and n-1 of the batch result.
    // Two extra calls; catches reversal and seam-shuffling directly.
    ai:Chunk[] chunks = chunksFor(c.chunks);
    ai:Embedding|ai:Error refFirst = provider->embed(chunks[0]);
    ai:Embedding|ai:Error refLast = provider->embed(chunks[c.chunks - 1]);
    if refFirst is ai:Error || refLast is ai:Error {
        ai:Error e = refFirst is ai:Error ? refFirst : <ai:Error>refLast;
        return mkResult(c.id, c.entry, detail, FAIL, nowMs() - t0, e.message(),
                "could not embed the reference chunks needed to verify order",
                live = true);
    }

    ai:Embedding[]|ai:Error vs = provider->batchEmbed(chunks);
    int ms = nowMs() - t0;
    if vs is ai:Error {
        return mkResult(c.id, c.entry, detail, FAIL, ms, vs.message(), c.why,
                live = true);
    }
    if vs.length() != c.chunks {
        return mkResult(c.id, c.entry, detail, FAIL, ms,
                string `got ${vs.length()} vectors`,
                string `batchEmbed must return exactly ${c.chunks} vectors, one per ` +
                string `input chunk, in input order`, live = true);
    }
    // Embeddings are deterministic for identical input, so a singly-embedded
    // reference must match its batched position byte for byte.
    if vs[0].toString() != refFirst.toString() {
        return mkResult(c.id, c.entry, detail, FAIL, ms, "index 0 mismatch",
                "the first input's vector is NOT at index 0 — batchEmbed did not " +
                "preserve input order", live = true);
    }
    if vs[c.chunks - 1].toString() != refLast.toString() {
        return mkResult(c.id, c.entry, detail, FAIL, ms,
                string `index ${c.chunks - 1} mismatch`,
                string `the last input's vector is NOT at index ${c.chunks - 1} — ` +
                string `batchEmbed reordered results, likely across a batch seam`,
                live = true);
    }
    // Distinct inputs must still give distinct vectors — guards against a slice
    // being reused to pad a short final batch.
    int identical = 0;
    foreach int i in 1 ..< vs.length() {
        if vs[i].toString() == vs[i - 1].toString() {
            identical += 1;
        }
    }
    if identical > 0 {
        return mkResult(c.id, c.entry, detail, FAIL, ms,
                string `${identical} adjacent vector pairs are identical`,
                "distinct inputs produced identical vectors — a batching bug",
                live = true);
    }
    return mkResult(c.id, c.entry, detail, PASS, ms,
            string `${vs.length()} vectors; first and last verified in input order`,
            c.why, live = true);
}

// ---------------------------------------------------------------------------
// Shared outcome helpers.
// ---------------------------------------------------------------------------

# A construction-time error. For a FAIL_OFFLINE case this is the PASS condition —
# but ONLY if the message names the guard the case claims to exercise.
#
# This used to return PASS on any construction error whatsoever. D5 claimed
# "construction error naming ApplyGuardrail" and never looked for the word; D8
# would have passed on a region typo; D6 on any Anthropic failure at all. Each
# case now declares `expectMessage`, and every substring must appear.
isolated function constructionOutcome(Case c, ai:Error e, string detail, int ms)
        returns Result {
    string msg = e.message();
    if c.expect != FAIL_OFFLINE {
        return mkResult(c.id, c.entry, detail, FAIL, ms, msg,
                "provider construction failed, but this case expected it to succeed");
    }
    // A FAIL_OFFLINE case with no declared expectation asserts nothing. Fail it
    // rather than let it pass vacuously — otherwise the check is opt-in and the
    // next case added silently opts out.
    if c.expectMessage.length() == 0 {
        return mkResult(c.id, c.entry, detail, FAIL, ms, msg,
                "case is FAIL_OFFLINE but declares no expectMessage, so a wrong " +
                "error would pass — add the substrings the guard must produce");
    }
    string lower = msg.toLowerAscii();
    string[] missing = [];
    foreach string want in c.expectMessage {
        if !lower.includes(want.toLowerAscii()) {
            missing.push(want);
        }
    }
    if missing.length() > 0 {
        return mkResult(c.id, c.entry, detail, FAIL, ms, msg,
                string `construction failed as expected, but the message is missing ` +
                string `${missing.toString()} — this is a DIFFERENT error than the ` +
                string `one this case exists to catch: ${c.why}`);
    }
    return mkResult(c.id, c.entry, detail, PASS, ms, msg, c.why);
}

# Errors that mean OUR setup is wrong, not that the module or AWS behaved as
# designed. A FAIL_LIVE case must not be satisfied by one of these — otherwise a
# missing IAM permission silently "proves" whatever the case claimed to prove.
isolated function isEnvironmentError(string message) returns boolean {
    string m = message.toLowerAscii();
    return m.includes("accessdenied") || m.includes("access denied")
        || m.includes("unrecognizedclient") || m.includes("invalidsignature")
        || m.includes("expiredtoken") || m.includes("throttl")
        || m.includes("too many requests") || m.includes("could not resolve")
        || m.includes("connection refused") || m.includes("timeout");
}

# A live call that errored.
isolated function liveErrorOutcome(Case c, string entry, string detail, ai:Error e, int ms)
        returns Result {
    string msg = e.message();
    if c.expect == FAIL_LIVE {
        // The case says AWS should reject this. An auth/throttle/DNS failure is a
        // DIFFERENT rejection and proves nothing about the module.
        if isEnvironmentError(msg) {
            return mkResult(c.id, entry, detail, SKIP, ms, msg,
                    "AWS did reject it, but for an environment reason (auth, quota " +
                    "or network) - this case can only be judged on a working account",
                    live = true);
        }
        return mkResult(c.id, entry, detail, PASS, ms, msg, c.why, live = true);
    }
    return mkResult(c.id, entry, detail, FAIL, ms, msg,
            string `expected a successful call: ${c.why}`, live = true);
}

// ---------------------------------------------------------------------------
// Dispatch.
// ---------------------------------------------------------------------------

isolated function runCase(Case c) returns Result {
    match c.entry {
        "chat" => {
            return driveChat(c);
        }
        "generate" => {
            return driveGenerate(c);
        }
        "agent" => {
            return driveAgent(c);
        }
    }
    // "special" cases assert construction behaviour only.
    int t0 = nowMs();
    string detail = string `${c.family} ${c.region} ${c.wireId}`;
    ai:ModelProvider|Skip|ai:Error p = providerFor(c);
    if p is Skip {
        return mkResult(c.id, c.entry, detail, SKIP, nowMs() - t0, p.reason,
                "case did not run — credential not configured");
    }
    if p is ai:Error {
        return constructionOutcome(c, p, detail, nowMs() - t0);
    }
    return mkResult(c.id, c.entry, detail, c.expect == FAIL_OFFLINE ? FAIL : PASS,
            nowMs() - t0, "provider constructed", c.why);
}

# Runs the selected cases and returns the tally.
#
# Returns the Summary rather than nothing so `main` can set a non-zero exit code.
# Previously this returned `error?` that only a filesystem failure could populate,
# so `bal run` exited 0 no matter how many cases failed — the suite could not gate
# anything, and a human had to read the terminal to learn the result.
public isolated function runAll() returns Summary|error {
    Result[] results = [];

    // `offset`/`limit` window, applied after `only`, over the stable D -> G -> F
    // order. `seen` counts SELECTED cases, so the window is over what you asked
    // for, not over the whole suite.
    int seen = 0;
    int taken = 0;

    foreach Case c in blockD() {
        if selected(c.id, c.block) {
            seen += 1;
            if seen > offset && ('limit == 0 || taken < 'limit) {
                taken += 1;
                Result r = runCase(c);
                printResult(r);
                results.push(r);
            }
        }
    }
    foreach Case c in blockG() {
        if selected(c.id, c.block) {
            seen += 1;
            if seen > offset && ('limit == 0 || taken < 'limit) {
                taken += 1;
                Result r = runCase(c);
                printResult(r);
                results.push(r);
            }
        }
    }
    foreach EmbedCase c in blockF() {
        if selected(c.id, "F") {
            seen += 1;
            if seen > offset && ('limit == 0 || taken < 'limit) {
                taken += 1;
                Result r = driveEmbed(c);
                printResult(r);
                results.push(r);
            }
        }
    }

    if results.length() == 0 {
        io:println("");
        io:println(string `!! NO CASES SELECTED (only='${only}', offset=${offset}, ` +
            string `limit=${'limit}). Nothing ran.`);
        io:println(string `   ${seen} case(s) matched the filter but fell outside the window.`);
    }

    Summary s = tally(results);
    summarise(results, s);
    check writeReport(results, s);
    io:println("");
    io:println(string `Report written to results/run.md (credentials redacted). ` +
        string `Window: ${seen} matched, ${taken} run.`);
    return s;
}
