// Block G — the NECESSARY combinations of (entry x apiFamily x region x CRIS x model).
//
// This is a curated list, not a sweep. The full cross-product is 2688 cells and
// ~421 are valid, but most valid cells are redundant: region and CRIS prefix only
// affect host construction and the model-id string, so re-testing them across many
// models proves nothing new.
//
// What is NOT redundant is the CODEC. The module hand-writes ten distinct request
// encoders, and a bug in one is invisible to the other nine. So the selection rule
// is: a case is included only if it is the ONLY case exercising some module code
// path. Every row below records what it uniquely covers, and `auditNecessary`
// proves the set still covers all ten codecs if someone edits the list.
//
// Region/CRIS coverage is folded onto cases that must exist anyway rather than
// spent on dedicated rows.

# A curated case, with the justification for its existence.
type Pick record {|
    string entry;
    # Capability-table key.
    string model;
    string region;
    # "" for a bare id, else "us" | "eu" | "global".
    string geo = "";
    string family;
    # "default" | "sigv4" | "bearer" — which credential to sign with.
    string auth = "default";
    # Expected outcome. Defaults to a successful live call; set FAIL_LIVE for a
    # pick whose own description predicts AWS will reject it, so the run is not
    # scored against an outcome the table already says is wrong.
    Expect expect = PASS_LIVE;
    # The module code path this row is the sole (or primary) exerciser of.
    string covers;
|};

// ---------------------------------------------------------------------------
// 1. Codec coverage — one live chat per distinct request encoder. Non-negotiable:
//    an unexercised codec is an untested codec.
// ---------------------------------------------------------------------------
final readonly & Pick[] CODEC_PICKS = [
    {
        entry: "chat",
        model: "opus-4-8",
        region: "us-east-1",
        family: "CONVERSE",
        covers: "Converse encoder + top-level `system` hoisting"
    },
    {
        entry: "chat",
        model: "opus-4-8",
        region: "us-east-1",
        family: "INVOKE",
        covers: "Invoke-Anthropic: `anthropic_version: bedrock-2023-05-31` BODY field"
    },
    {
        entry: "chat",
        model: "nova-pro",
        region: "us-east-1",
        family: "INVOKE",
        covers: "Invoke-Nova: `schemaVersion: messages-v1` body field"
    },
    {
        entry: "chat",
        model: "mistral-7b",
        region: "us-east-1",
        family: "INVOKE",
        covers: "Invoke-Mistral TEXT-completion dialect (`<s>[INST]...[/INST]`)"
    },
    {
        entry: "chat",
        model: "gpt-oss-120b",
        region: "us-east-1",
        family: "INVOKE",
        covers: "Invoke-OpenAI; id contains a colon -> SigV4 URI double-encoding"
    },
    {
        entry: "chat",
        model: "deepseek-v3-2",
        region: "us-east-1",
        family: "INVOKE",
        covers: "Invoke-DeepSeek encoder"
    },
    {
        entry: "chat",
        model: "qwen3-32b",
        region: "us-east-1",
        family: "INVOKE",
        covers: "Invoke-Qwen encoder"
    },
    {
        entry: "chat",
        model: "opus-4-8",
        region: "us-east-1",
        family: "MANTLE",
        covers: "Mantle /anthropic/v1/messages: `anthropic-version` HEADER (vs the " +
            "Invoke BODY field above) + bedrock-mantle signing scope"
    },
    {
        entry: "chat",
        model: "qwen3-32b",
        region: "us-east-1",
        family: "MANTLE",
        covers: "Mantle /v1/chat/completions; mantleId DIFFERS from the runtime id " +
            "(`qwen.qwen3-32b` vs `qwen.qwen3-32b-v1:0`)"
    },
    {
        entry: "chat",
        model: "gpt-5-4",
        region: "us-east-1",
        family: "MANTLE",
        covers: "Mantle /openai/v1/responses dialect"
    }
];

// ---------------------------------------------------------------------------
// 2. Resolver — AUTO must land where Amendment 2 says it lands.
// ---------------------------------------------------------------------------
final readonly & Pick[] RESOLVER_PICKS = [
    {
        entry: "chat",
        model: "opus-4-8",
        region: "us-east-1",
        family: "AUTO",
        covers: "Amendment 2: dual-homed model under AUTO must resolve to MANTLE"
    },
    {
        entry: "chat",
        model: "nova-pro",
        region: "us-east-1",
        family: "AUTO",
        covers: "AUTO on a runtime-only model falls through to CONVERSE"
    },
    {
        entry: "chat",
        model: "opus-4-8",
        region: "us-east-1",
        geo: "us",
        family: "AUTO",
        covers: "THE GEO GUARD: a CRIS prefix keeps a Mantle-capable model on " +
            "CONVERSE, and the `us.` prefix survives onto the wire"
    }
];

// ---------------------------------------------------------------------------
// 3. CRIS + region — folded together: each row carries a prefix AND a region that
//    no other row visits.
// ---------------------------------------------------------------------------
final readonly & Pick[] REGION_PICKS = [
    {
        entry: "chat",
        model: "sonnet-5",
        region: "eu-west-1",
        geo: "eu",
        family: "CONVERSE",
        covers: "`eu.` profile from a EU region: non-us-east-1 host + signing region"
    },
    {
        entry: "chat",
        model: "opus-4-8",
        region: "us-east-1",
        geo: "global",
        family: "CONVERSE",
        covers: "`global.` inference profile"
    },
    {
        entry: "chat",
        model: "deepseek-r1",
        region: "us-east-1",
        geo: "us",
        family: "CONVERSE",
        covers: "CRIS-ONLY model: bare id is In-Region NO everywhere, so the " +
            "profile prefix is the only way to reach it at all"
    },
    {
        entry: "chat",
        model: "qwen3-32b",
        region: "ap-northeast-1",
        family: "CONVERSE",
        covers: "APAC region: third partition-region host + signing region"
    }
];

// ---------------------------------------------------------------------------
// 4. generate() — structured output via forced tool use. The tool-forcing shape
//    differs per family, so each family that supports it needs one.
// ---------------------------------------------------------------------------
final readonly & Pick[] GENERATE_PICKS = [
    {
        entry: "generate",
        model: "opus-4-8",
        region: "us-east-1",
        family: "CONVERSE",
        covers: "Converse `toolConfig.toolChoice.tool` forcing + typedesc->schema"
    },
    {
        entry: "generate",
        model: "opus-4-8",
        region: "us-east-1",
        family: "INVOKE",
        covers: "Invoke-Anthropic `tool_choice` forcing — a DIFFERENT shape from " +
            "Converse; parses tool-call args back into the record"
    },
    {
        entry: "generate",
        model: "qwen3-32b",
        region: "us-east-1",
        family: "CONVERSE",
        covers: "forced tool use on a NON-Anthropic model (vendors honor forcing " +
            "differently even behind the uniform Converse toolConfig)"
    }
];

// ---------------------------------------------------------------------------
// 5. agent() — the multi-turn tool loop. Distinct from generate(): it must read
//    tool-call blocks back OUT of a response and feed results in as a new turn,
//    so it exercises the DECODE side of each dialect.
// ---------------------------------------------------------------------------
final readonly & Pick[] AGENT_PICKS = [
    {
        entry: "agent",
        model: "opus-4-8",
        region: "us-east-1",
        family: "CONVERSE",
        covers: "agent loop over Converse: decode toolUse blocks, round-trip results"
    },
    {
        entry: "agent",
        model: "opus-4-8",
        region: "us-east-1",
        family: "INVOKE",
        covers: "agent loop over Invoke-Anthropic: multi-turn round-trip of " +
            "`tool_use`/`tool_result` blocks, which generate() never does " +
            "(it stops after one forced call)"
    },
    {
        entry: "agent",
        model: "qwen3-32b",
        region: "us-east-1",
        family: "MANTLE",
        covers: "agent loop over Mantle /v1/chat/completions: tool_calls decode"
    },
    {
        entry: "agent",
        model: "gpt-5-4",
        region: "us-east-1",
        family: "MANTLE",
        covers: "agent loop over Mantle Responses: this is the ONLY live exercise " +
            "of the FLAT `{type, name}` tool_choice shape (bug A1) and of the " +
            "Responses tool-call decode"
    }
];

// ---------------------------------------------------------------------------
// 6. Auth x endpoint. Both endpoints accept BOTH SigV4 and a Bedrock API key, but
//    they are different signing paths: SigV4 builds a canonical request and signs
//    it with the route's scope (`bedrock` vs `bedrock-mantle`), while a bearer key
//    is a header. Mantle-with-SigV4 in particular has never been exercised — the
//    Mantle work was all done against an API key.
// ---------------------------------------------------------------------------
final readonly & Pick[] AUTH_PICKS = [
    {
        entry: "chat",
        model: "opus-4-8",
        region: "us-east-1",
        family: "CONVERSE",
        auth: "sigv4",
        covers: "SigV4 on bedrock-runtime, signing scope `bedrock`"
    },
    {
        entry: "chat",
        model: "opus-4-8",
        region: "us-east-1",
        family: "CONVERSE",
        auth: "bearer",
        covers: "Bedrock API key on bedrock-runtime"
    },
    {
        entry: "chat",
        model: "opus-4-8",
        region: "us-east-1",
        family: "MANTLE",
        auth: "sigv4",
        covers: "SigV4 on bedrock-mantle, signing scope `bedrock-mantle` — the " +
            "previously UNTESTED path; also proves the separate IAM namespace " +
            "`bedrock-mantle:CreateInference` is what actually gates it"
    },
    {
        entry: "chat",
        model: "opus-4-8",
        region: "us-east-1",
        family: "MANTLE",
        auth: "bearer",
        covers: "Bedrock API key on bedrock-mantle (`x-api-key` per the AWS curl)"
    }
];

// ---------------------------------------------------------------------------
// 7. Breadth. These are NOT sole-exercisers — the code path each one takes is
//    already covered above. They are here because a codec is shared machinery but a
//    MODEL is not: vendors differ in what they accept for the same encoder (a
//    required temperature, a rejected top_k, a stop-sequence cap, a tool-forcing
//    dialect they honor loosely). One live call per model per surface is the only
//    way to find that class of problem.
// ---------------------------------------------------------------------------
final readonly & Pick[] BREADTH_PICKS = [
    // Models the necessary set never calls at all.
    {
        entry: "chat",
        model: "sonnet-4-6",
        region: "us-east-1",
        geo: "global",
        family: "CONVERSE",
        covers: "sonnet-4-6 is In-Region ONLY in eu-west-2, so `global.` is how it " +
            "is reachable from us-east-1 at all"
    },
    {
        entry: "chat",
        model: "mythos-5",
        region: "us-east-1",
        family: "MANTLE",
        covers: "mythos-5 quirk: temperature MUST be 1.0 and top_k is unsupported — " +
            "a naive default-params call is expected to be REJECTED here"
    },
    {
        entry: "chat",
        model: "gemma-4-31b",
        region: "us-east-1",
        family: "MANTLE",
        covers: "second model on the Mantle Responses dialect (Google, not OpenAI)"
    },
    // Second surface for dual-homed models tested only once above.
    {
        entry: "chat",
        model: "gpt-oss-120b",
        region: "us-east-1",
        family: "MANTLE",
        covers: "second mantleId-differs model: `openai.gpt-oss-120b` on Mantle vs " +
            "`openai.gpt-oss-120b-1:0` on Invoke"
    },
    {
        entry: "chat",
        model: "sonnet-5",
        region: "us-east-1",
        family: "MANTLE",
        covers: "sonnet-5 on Mantle /anthropic/v1/messages"
    },
    {
        entry: "chat",
        model: "deepseek-v3-2",
        region: "us-east-1",
        family: "MANTLE",
        covers: "deepseek-v3-2 on Mantle /v1/chat/completions"
    },
    {
        entry: "chat",
        model: "mistral-large-3",
        region: "us-east-1",
        family: "MANTLE",
        covers: "mistral-large-3 on Mantle /v1/chat/completions"
    },
    {
        entry: "chat",
        model: "mistral-large-3",
        region: "us-east-1",
        family: "INVOKE",
        covers: "INVOKE_MISTRAL_CHAT_CODEC — the `messages`/`tools` Mistral dialect. " +
            "Distinct from mistral-7b's TEXT codec, and previously reached by NO " +
            "case while the audit still claimed full codec coverage."
    },
    {
        entry: "chat",
        model: "gemma-3-27b",
        region: "us-east-1",
        family: "MANTLE",
        covers: "gemma-3-27b Mantle path is /v1/chat/completions — DIFFERENT from " +
            "gemma-4's /openai/v1/responses under the same vendor prefix"
    },
    // us-west-2: a region no necessary case visits.
    {
        entry: "chat",
        model: "mistral-large-3",
        region: "us-west-2",
        family: "CONVERSE",
        covers: "us-west-2 host + signing region"
    },
    {
        entry: "chat",
        model: "deepseek-v3-2",
        region: "us-west-2",
        family: "MANTLE",
        covers: "us-west-2 on the MANTLE endpoint (different host family entirely: " +
            "bedrock-mantle.us-west-2.api.aws)"
    },
    // generate() breadth — tool-forcing is where vendors diverge most.
    {
        entry: "generate",
        model: "nova-pro",
        region: "us-east-1",
        family: "INVOKE",
        covers: "forced tool use through the Nova Invoke body (schemaVersion + tools)"
    },
    {
        entry: "generate",
        model: "mistral-large-3",
        region: "us-east-1",
        family: "CONVERSE",
        covers: "forced tool use, Mistral"
    },
    {
        entry: "generate",
        model: "deepseek-r1",
        region: "us-east-1",
        geo: "us",
        family: "CONVERSE",
        covers: "structured output on a reasoning model via a CRIS profile"
    },
    // agent() breadth — the multi-turn decode side per dialect.
    {
        entry: "agent",
        model: "qwen3-32b",
        region: "us-east-1",
        family: "CONVERSE",
        covers: "agent loop over Converse on a non-Anthropic model"
    },
    {
        entry: "agent",
        model: "mistral-large-3",
        region: "us-east-1",
        family: "MANTLE",
        covers: "agent loop over Mantle chat-completions, second vendor"
    },
    {
        entry: "agent",
        model: "gemma-4-31b",
        region: "us-east-1",
        family: "MANTLE",
        covers: "agent loop over Mantle Responses, second vendor"
    },
    {
        entry: "agent",
        model: "sonnet-5",
        region: "us-east-1",
        family: "MANTLE",
        covers: "agent loop over Mantle /anthropic/v1/messages — the Messages " +
            "dialect's tool_use decode, which no other agent case reaches"
    }
];

# The full set, in run order.
public isolated function necessaryPicks() returns Pick[] {
    Pick[] all = [];
    foreach Pick[] group in [CODEC_PICKS, RESOLVER_PICKS, REGION_PICKS,
            GENERATE_PICKS, AGENT_PICKS, AUTH_PICKS, BREADTH_PICKS] {
        all.push(...group);
    }
    return all;
}

// ---------------------------------------------------------------------------
// Block G.
// ---------------------------------------------------------------------------

public isolated function blockG() returns Case[] {
    Case[] cases = [];
    int n = 1;
    foreach Pick p in necessaryPicks() {
        ModelCap m = MODELS.get(p.model);
        string resolved = p.family == "AUTO" ? autoFamilyFor(m, p.geo != "") : p.family;
        // ALWAYS pass the canonical (bedrock-runtime) id. Where Mantle serves the
        // model under a different id, the MODULE performs that substitution from
        // its MANTLE_CAPABLE table, which is keyed by the runtime id. Passing the
        // Mantle id here would break that lookup — the caller is not meant to know
        // about it. `m.mantleId` therefore describes what we EXPECT ON THE WIRE,
        // which is asserted by the echo server, not by what we send.
        string wireId = p.geo == "" ? m.id : string `${p.geo}.${m.id}`;
        cases.push({
            id: string `G${n}`,
            block: "G",
            entry: p.entry,
            model: p.model,
            wireId,
            region: p.region,
            family: p.family,
            expectedFamily: resolved,
            expect: p.expect,
            auth: p.auth,
            why: p.covers
        });
        n += 1;
    }
    return cases;
}

// ---------------------------------------------------------------------------
// Audit — a curated list rots silently. This proves the set is still sound.
// ---------------------------------------------------------------------------

# Is this pick one the capability table says AWS actually serves? Catches a
# hand-picked combination that looks reasonable but cannot run (e.g. a bare id in a
# region where In-Region is NO, or a geo prefix the model has no profile for).
isolated function pickIsServed(Pick p) returns string? {
    ModelCap m = MODELS.get(p.model);
    if (p.family == "CONVERSE" || p.family == "INVOKE") && !m.runtime {
        return "forces a runtime family but the model is Mantle-only";
    }
    if p.family == "MANTLE" && !m.mantle {
        return "forces MANTLE but the model is not served there";
    }
    if p.geo == "" {
        if !bareCallableIn(m, p.region) {
            return string `bare id is not In-Region in ${p.region}`;
        }
    } else {
        if p.family == "MANTLE" {
            return "a CRIS prefix has no meaning on Mantle";
        }
        if !geoValid(m, p.geo) {
            return string `no '${p.geo}.' profile exists for this model`;
        }
        if p.geo != "global" && !p.region.startsWith(p.geo + "-") {
            return string `'${p.geo}.' profile is not reachable from ${p.region}`;
        }
    }
    if (p.entry == "agent" || p.entry == "generate") && !m.tools {
        return "entry needs tool calling; this model has none";
    }
    string resolved = p.family == "AUTO" ? autoFamilyFor(m, p.geo != "") : p.family;
    if p.entry == "generate" && !supportsStructuredOutput(resolved) {
        return "typed generate() resolves onto a Mantle route, which refuses it";
    }
    return ();
}

# The codecs the module ACTUALLY implements, named as in its `codecs.bal`.
#
# This list was previously derived from vendor prefixes, which overstated coverage
# in two ways:
#   - `openai.`, `qwen.` AND `zai.` all resolve to INVOKE_OPENAI_CHAT_CODEC
#     (codecs.bal:171-173), so "INVOKE:openai" and "INVOKE:qwen" were ONE codec
#     counted twice;
#   - `mistral.` splits into TWO codecs by exact id (`usesMistralTextDialect`), and
#     collapsing them hid that INVOKE_MISTRAL_CHAT_CODEC was reached by nothing.
# The audit printed "all 10 codecs reached" while a real codec had zero coverage.
final readonly & string[] REQUIRED_CODECS = [
    "CONVERSE_CODEC",
    "INVOKE_ANTHROPIC_CODEC",
    "INVOKE_NOVA_CODEC",
    "INVOKE_MISTRAL_TEXT_CODEC",
    "INVOKE_MISTRAL_CHAT_CODEC",
    "INVOKE_OPENAI_CHAT_CODEC",
    "INVOKE_DEEPSEEK_CODEC",
    "MANTLE:/anthropic/v1/messages",
    "MANTLE:/v1/chat/completions",
    "MANTLE:/openai/v1/responses"
];

# Mirrors `usesMistralTextDialect` in the module's codecs.bal — an ALLOWLIST of the
# legacy `prompt`/`<s>[INST]` dialect. Everything else under `mistral.` speaks chat
# completion. Keep in sync with the module.
isolated function isMistralTextDialect(string id) returns boolean
    => id.startsWith("mistral.mistral-7b-instruct") || id.startsWith("mistral.mixtral-")
        || id.startsWith("mistral.mistral-large-2402");

# Which codec a pick lands on. Mirrors `selectInvokeCodec` in codecs.bal — if that
# function changes, this must change with it, or the audit goes back to lying.
isolated function codecOf(Pick p) returns string {
    ModelCap m = MODELS.get(p.model);
    string resolved = p.family == "AUTO" ? autoFamilyFor(m, p.geo != "") : p.family;
    if resolved == "CONVERSE" {
        return "CONVERSE_CODEC";
    }
    if resolved == "MANTLE" {
        return string `MANTLE:${m.mantlePath ?: "?"}`;
    }
    if m.id.startsWith("anthropic.") {
        return "INVOKE_ANTHROPIC_CODEC";
    }
    if m.id.startsWith("amazon.") {
        return "INVOKE_NOVA_CODEC";
    }
    if m.id.startsWith("mistral.") {
        return isMistralTextDialect(m.id) ? "INVOKE_MISTRAL_TEXT_CODEC"
            : "INVOKE_MISTRAL_CHAT_CODEC";
    }
    if m.id.startsWith("deepseek.") {
        return "INVOKE_DEEPSEEK_CODEC";
    }
    // openai. / qwen. / zai. share ONE codec.
    return "INVOKE_OPENAI_CHAT_CODEC";
}

# Audit report, printed by `--dry-run`: unservable picks, and any codec the
# curated list fails to reach.
public isolated function auditNecessary() returns string {
    string[] problems = [];
    map<boolean> reached = {};
    int n = 1;
    foreach Pick p in necessaryPicks() {
        string? bad = pickIsServed(p);
        if bad is string {
            problems.push(string `G${n} (${p.model}): ${bad}`);
        }
        reached[codecOf(p)] = true;
        n += 1;
    }
    foreach string codec in REQUIRED_CODECS {
        if !reached.hasKey(codec) {
            problems.push(string `NO CASE REACHES CODEC: ${codec}`);
        }
    }
    if problems.length() == 0 {
        return string `Block G audit: ${n - 1} cases, all servable, all ` +
            string `${REQUIRED_CODECS.length()} codecs reached.`;
    }
    return string `Block G audit FAILED:` +
        string:'join("", ...problems.map(isolated function(string s) returns string
            => string `${"\n"}  - ${s}`));
}
