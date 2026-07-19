// Case generator — turns the capability table into the exact list of cases.
//
// Nothing here hardcodes a combination. Every case is derived from `MODELS`, so
// when a card changes you edit one row and the case list follows.

# What a case does when it runs.
public enum Expect {
    # A live call that should succeed.
    PASS_LIVE,
    # Must fail, and fail in the module BEFORE any network call (visible in --dry-run).
    FAIL_OFFLINE,
    # Must fail, but only AWS can tell us so (a live call that should error).
    FAIL_LIVE
}

# One generated case.
public type Case record {|
    # Stable id, e.g. "A3", "C7" — what `--case` filters on.
    string id;
    string block;
    # "chat" | "generate" | "agent" | "embed" | "batchEmbed" | "special"
    string entry;
    # Capability-table key, or "" for cases that aren't model-driven.
    string model;
    # Model id actually put on the wire (may carry a geo prefix).
    string wireId;
    string region;
    # AUTO | CONVERSE | INVOKE | MANTLE
    string family;
    # Family the resolver should land on (differs from `family` when AUTO).
    string expectedFamily;
    Expect expect;
    # Credential to sign with: "default" (whatever Config.toml supplies), "sigv4"
    # (force static keys), "bearer" (force the Bedrock API key). Both endpoints
    # accept both, and the pairing is a real code path — see AUTH_PICKS.
    string auth = "default";
    # Attach a guardrail config. On a Mantle route this must be a CONSTRUCTION
    # error naming ApplyGuardrail (D5) — without this flag nothing triggers it.
    boolean withGuardrail = false;
    # Pass a stop sequence. The Responses dialect has no stop parameter, so the
    # module must REFUSE rather than silently drop it (D4).
    boolean withStop = false;
    # Printed with the verdict so the terminal explains itself.
    string why;
|};

// Blocks A, B and C were REMOVED. Each varied a single axis (A: entry x family on
// one model; B: one chat per model; C: region and CRIS sweeps) and every case they
// contained is either subsumed by the curated Block G in `pairwise.bal` or was
// redundant coverage that cost a live call without exercising new module code.
// Block D (expected failures) and Block G (necessary combinations) are the suite.

// ---------------------------------------------------------------------------
// Block D — expected failures. Most cost nothing (they fail before I/O).
// ---------------------------------------------------------------------------
public isolated function blockD() returns Case[] {
    return [
        {
            id: "D1",
            block: "D",
            entry: "chat",
            model: "deepseek-r1",
            wireId: "deepseek.r1-v1:0",
            region: "us-east-1",
            family: "AUTO",
            expectedFamily: "CONVERSE",
            expect: FAIL_LIVE,
            why: "bare R1 is In-Region NO everywhere; AWS must reject it"
        },
        {
            id: "D2",
            block: "D",
            entry: "chat",
            model: "sonnet-4-6",
            wireId: "anthropic.claude-sonnet-4-6",
            region: "us-east-1",
            family: "MANTLE",
            expectedFamily: "MANTLE",
            expect: FAIL_OFFLINE,
            why: "runtime-only model forced to Mantle -> 'not available on Mantle'"
        },
        {
            id: "D3",
            block: "D",
            entry: "generate",
            model: "opus-4-8",
            wireId: "anthropic.claude-opus-4-8",
            region: "us-east-1",
            family: "AUTO",
            expectedFamily: "MANTLE",
            expect: FAIL_OFFLINE,
            why: "typed generate() on an AUTO-routed Mantle model; error must name the model + bedrock-mantle"
        },
        {
            id: "D4",
            block: "D",
            entry: "chat",
            model: "gpt-5-4",
            wireId: "openai.gpt-5.4",
            region: "us-east-1",
            family: "MANTLE",
            expectedFamily: "MANTLE",
            expect: FAIL_OFFLINE,
            withStop: true,
            why: "`stop` on the Responses dialect: no such parameter, must refuse " +
                "not drop. NOTE: this refusal happens inside chat() at encode time, " +
                "not at construction, so it is invisible under --dry-run — but it " +
                "still costs nothing because it fails before any I/O."
        },
        {
            id: "D5",
            block: "D",
            entry: "special",
            model: "opus-4-8",
            wireId: "anthropic.claude-opus-4-8",
            region: "us-east-1",
            family: "MANTLE",
            expectedFamily: "MANTLE",
            expect: FAIL_OFFLINE,
            withGuardrail: true,
            why: "guardrail on a Mantle route -> construction error naming ApplyGuardrail"
        },
        {
            id: "D6",
            block: "D",
            entry: "special",
            model: "",
            wireId: "arn:aws:bedrock:us-east-1:123456789012:imported-model/abc123def456",
            region: "us-east-1",
            family: "INVOKE",
            expectedFamily: "INVOKE",
            expect: FAIL_OFFLINE,
            why: "imported-model/ ARN without modelSchema -> construction error"
        },
        // D7 REMOVED. Its premise was wrong: `CohereEmbeddingConfig.inputType`
        // has a default of SEARCH_DOCUMENT in the module, so "Cohere without
        // inputType" is unrepresentable and cannot produce a construction error.
        // The real Cohere input_type assertions live in Block F (F5/F6).
        {
            id: "D8",
            block: "D",
            entry: "special",
            model: "",
            wireId: "anthropic.claude-opus-4-8",
            region: "cn-north-1",
            family: "MANTLE",
            expectedFamily: "MANTLE",
            expect: FAIL_OFFLINE,
            why: "Mantle on a non-api.aws partition -> construction error"
        }
    ];
}

