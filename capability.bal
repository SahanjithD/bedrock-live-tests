// Per-model capability table — DATA, every row cited to its AWS model card.
//
// This exists so the case generator emits only combinations that AWS actually
// serves. A blind cartesian product of (entry point x family x region x prefix x
// model) is mostly invalid cells, and each invalid cell fails for a reason that
// has nothing to do with the module under test — which is how a live suite starts
// lying to you.


# One model's live-testable surface, as stated by its model card.
public type ModelCap record {|
    # bedrock-runtime model id (what the caller passes).
    string id;
    # bedrock-mantle id when it differs from `id`; () when identical or no Mantle.
    string? mantleId = ();
    # Served on bedrock-runtime (Converse/Invoke)?
    boolean runtime;
    # Served on bedrock-mantle?
    boolean mantle;
    # Mantle URL path; () when not on Mantle.
    string? mantlePath = ();
    # Regions where the BARE id is callable (In-Region = YES).
    string[] inRegion = [];
    # CRIS geo prefixes that exist for this model ("us", "eu", "jp", "au").
    string[] geoPrefixes = [];
    # Global inference profile (`global.` prefix) offered?
    boolean globalProfile = false;
    # Supports tool calling? False rules out `agent` AND typed `generate()`, both
    # of which are built on forced tool use.
    boolean tools = true;
    # Temperature this model REQUIRES, when it constrains the value. The module
    # coerces a nil temperature to its 0.7 default (`temperature ?: DEFAULT_TEMPERATURE`
    # in provider_common.bal), so "omit it" is not expressible — an explicit value is
    # the only way. () means "no constraint; use the suite default".
    decimal? forceTemperature = ();
    # Anything that makes a naive call fail (e.g. required temperature).
    string? quirk = ();
    # The card this row was read from.
    string card;
|};

public final readonly & map<ModelCap> MODELS = {
    // ---------------- Anthropic ----------------
    // NOTE (source conflict, surfaced not resolved): the Programmatic Access row
    // gives In-Region endpoint URL = "N/A" for bedrock-runtime, while the Regional
    // Availability table marks In-Region YES for us-east-1 and the card's own
    // Converse sample calls the BARE id in us-east-1. We follow the sample + the
    // availability table. If a bare-id In-Region call 400s, this is the first
    // thing to re-read.
    "opus-4-8": {
        id: "anthropic.claude-opus-4-8",
        runtime: true,
        mantle: true,
        mantlePath: "/anthropic/v1/messages",
        // us-west-2 is In-Region NO — a bare call there must use `us.` instead.
        inRegion: ["us-east-1", "eu-north-1", "eu-west-1", "ap-northeast-1", "ap-southeast-4"],
        geoPrefixes: ["us", "eu", "jp", "au"],
        globalProfile: true,
        card: "https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-opus-4-8.html"
    },
    "sonnet-5": {
        id: "anthropic.claude-sonnet-5",
        runtime: true,
        mantle: true,
        mantlePath: "/anthropic/v1/messages",
        inRegion: ["us-east-1", "eu-north-1", "eu-west-1", "ap-southeast-4"],
        geoPrefixes: ["us", "eu", "au"],
        globalProfile: true,
        card: "https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-5.html"
    },
    // Runtime-ONLY (bedrock-mantle marked NO) — forcing MANTLE must fail.
    // In-Region is YES in eu-west-2 ONLY; every other region is geo/global. A bare
    // call in us-east-1 is therefore INVALID for this model.
    "sonnet-4-6": {
        id: "anthropic.claude-sonnet-4-6",
        runtime: true,
        mantle: false,
        inRegion: ["eu-west-2"],
        geoPrefixes: ["us", "eu", "au", "jp"],
        globalProfile: true,
        card: "https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-4-6.html"
    },
    "mythos-5": {
        id: "anthropic.claude-mythos-5",
        runtime: false,
        mantle: true,
        mantlePath: "/anthropic/v1/messages",
        inRegion: ["us-east-1"],
        // Card: "temperature must be 1.0 or unset". The module cannot send "unset",
        // so 1.0 is mandatory here — 0.7 would be rejected by AWS.
        forceTemperature: 1.0,
        // VERIFIED: In-Region YES in us-east-1 only; Geo NO, Global NO.
        quirk: "temperature MUST be 1.0 or unset; top_p must be >=0.99 and <1.0 or " +
            "unset; top_k NOT supported; requires opting in to provider data " +
            "sharing (data retention mode `provider_data_share`). PREVIEW/Beta " +
            "with limited access — the account may simply not be entitled.",
        card: "https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-mythos-5.html"
    },
    // ---------------- OpenAI ----------------
    "gpt-5-4": {
        id: "openai.gpt-5.4",
        runtime: false,
        mantle: true,
        mantlePath: "/openai/v1/responses",
        inRegion: ["us-east-1", "us-east-2", "us-west-2", "us-gov-west-1"],
        quirk: "Responses dialect has NO stop-sequence parameter; the module refuses " +
            "`stop`/`stopSequences` rather than dropping them. Base URL is " +
            "`/openai/v1`, which the card explicitly contrasts with the `/v1` " +
            "responses path other models use.",
        card: "https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-54.html"
    },
    // Different id per endpoint — the classic wrong-id-on-the-wire trap.
    "gpt-oss-120b": {
        id: "openai.gpt-oss-120b-1:0",
        mantleId: "openai.gpt-oss-120b",
        runtime: true,
        mantle: true,
        mantlePath: "/v1/chat/completions",
        inRegion: ["us-east-1", "us-east-2", "us-west-2", "eu-central-1", "eu-north-1",
            "eu-south-1", "eu-west-1", "eu-west-2", "ap-northeast-1", "ap-south-1",
            "ap-southeast-2", "ap-southeast-3", "ap-southeast-4", "sa-east-1",
            "us-gov-west-1"],
        // The ONLY CRIS profile is GovCloud: `us-gov.openai.gpt-oss-120b-1:0`.
        geoPrefixes: ["us-gov"],
        quirk: "id contains a colon -> exercises SigV4 double-encoding of the URI",
        card: "https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-openai-gpt-oss-120b.html"
    },
    // ---------------- Amazon ----------------
    "nova-pro": {
        id: "amazon.nova-pro-v1:0",
        runtime: true,
        mantle: false,
        // CAREFUL: us-east-2 / us-west-1 / us-west-2 are In-Region **NO** for Nova
        // Pro — they are Geo-only. A bare id there is invalid; use `us.`.
        inRegion: ["us-east-1", "eu-west-2", "ap-southeast-2", "ap-southeast-3",
            "me-central-1", "us-gov-west-1"],
        geoPrefixes: ["us", "eu"],
        quirk: "Invoke body requires \"schemaVersion\": \"messages-v1\"",
        card: "https://docs.aws.amazon.com/bedrock/latest/userguide/model-parameters-nova.html"
    },
    // ---------------- Mistral ----------------
    "mistral-large-3": {
        id: "mistral.mistral-large-3-675b-instruct",
        runtime: true,
        mantle: true,
        mantlePath: "/v1/chat/completions",
        inRegion: ["us-east-1", "us-east-2", "us-west-2", "eu-north-1", "eu-west-2",
            "ap-northeast-1", "ap-south-1", "ap-southeast-2", "ap-southeast-3",
            "ap-southeast-4", "sa-east-1"],
        card: "https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-mistral-ai-mistral-large-3.html"
    },
    "mistral-7b": {
        id: "mistral.mistral-7b-instruct-v0:2",
        runtime: true,
        mantle: false,
        inRegion: ["us-east-1", "us-west-2", "ca-central-1", "eu-west-1", "eu-west-2",
            "eu-west-3", "ap-south-1", "ap-southeast-2", "sa-east-1"],
        tools: false,
        // *** UNRESOLVED FIRST-PARTY SOURCE CONFLICT — DO NOT SILENTLY PICK ONE ***
        // The module routes `mistral.mistral-7b-instruct*` to the TEXT-completion
        // codec, emitting `prompt` with a `<s>[INST]...[/INST]` template. That
        // follows model-parameters-mistral-text-completion.html, which names
        // Mistral 7B Instruct as a supported model of that dialect.
        //
        // BUT this model's own CARD gives an InvokeModel sample that posts
        // `{"messages": [...], "max_tokens": 1024}` — the CHAT dialect. The card
        // also marks Converse as supported, which the older parameter page predates.
        //
        // Both are first-party AWS sources and they disagree. Case G4 (chat /
        // INVOKE / mistral-7b) is therefore the DECIDING EXPERIMENT: if it fails
        // with a ValidationException naming `prompt` or `messages`, the card is
        // right and `usesMistralTextDialect` in the module's codecs.bal must drop
        // the `mistral-7b-instruct` prefix. Do not change the module before
        // running it.
        //
        // `tools: false` is kept as the conservative choice: the card's feature
        // matrix is collapsed in the rendered page, so tool support is unconfirmed.
        quirk: "DIALECT CONFLICT: the module sends text-completion `prompt`; the " +
            "model card's own Invoke sample sends `messages`. G4 decides it.",
        card: "https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-mistral-ai-mistral-7b-instruct.html"
    },
    // ---------------- DeepSeek ----------------
    "deepseek-v3-2": {
        id: "deepseek.v3.2",
        runtime: true,
        mantle: true,
        mantlePath: "/v1/chat/completions",
        inRegion: ["us-east-1", "us-east-2", "us-west-2", "eu-north-1", "eu-west-2",
            "ap-northeast-1", "ap-south-1", "ap-southeast-2", "ap-southeast-3",
            "ap-southeast-4", "sa-east-1"],
        card: "https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-deepseek-deepseek-v3-2.html"
    },
    // CRIS-ONLY: In-Region is NO in every region, so the BARE id is uncallable
    // anywhere. Only `us.deepseek.r1-v1:0` resolves. Global not offered.
    "deepseek-r1": {
        id: "deepseek.r1-v1:0",
        runtime: true,
        mantle: false,
        inRegion: [],
        geoPrefixes: ["us"],
        globalProfile: false,
        quirk: "bare id is uncallable in EVERY region; requires the `us.` profile",
        card: "https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-deepseek-deepseek-r1.html"
    },
    // ---------------- Qwen ----------------
    "qwen3-32b": {
        id: "qwen.qwen3-32b-v1:0",
        mantleId: "qwen.qwen3-32b",
        runtime: true,
        mantle: true,
        mantlePath: "/v1/chat/completions",
        inRegion: ["us-east-1", "us-east-2", "us-west-2", "eu-central-1", "eu-north-1",
            "eu-south-1", "eu-west-1", "eu-west-2", "ap-northeast-1", "ap-south-1",
            "ap-southeast-2", "ap-southeast-3", "ap-southeast-4", "sa-east-1"],
        card: "https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-qwen-qwen3-32b.html"
    },
    // ---------------- Google ----------------
    // Gemma 3's Mantle path is `/v1/chat/completions` — DIFFERENT from Gemma 4's
    // `/openai/v1/responses`. One vendor prefix, two Mantle path families.
    "gemma-3-27b": {
        id: "google.gemma-3-27b-it",
        runtime: true,
        mantle: true,
        mantlePath: "/v1/chat/completions",
        inRegion: ["us-east-1", "us-east-2", "us-west-2", "eu-central-1", "eu-north-1",
            "eu-south-1", "eu-west-1", "eu-west-2", "ap-northeast-1", "ap-south-1",
            "ap-southeast-2", "ap-southeast-3", "ap-southeast-4", "sa-east-1"],
        card: "https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-3-27b-pt.html"
    },
    "gemma-4-31b": {
        id: "google.gemma-4-31b",
        runtime: false,
        mantle: true,
        mantlePath: "/openai/v1/responses",
        inRegion: ["us-east-1", "us-east-2", "us-west-2", "eu-central-1"],
        quirk: "Mantle-ONLY; Converse/Invoke/Messages all NO -> no structured " +
            "output. PARALLEL TOOL CALLS ARE NOT SUPPORTED — an agent turn that " +
            "requests two tools at once will fail here and nowhere else.",
        card: "https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-google-gemma-4-31b.html"
    }
};

# Embedding models (Invoke-only, no routing ladder).
public type EmbedCap record {|
    string id;
    # Wire batch limit: Titan 1, Cohere 96.
    int maxBatchSize;
    string[] inRegion = [];
    string? quirk = ();
    string card;
|};

public final readonly & map<EmbedCap> EMBED_MODELS = {
    // Invoke-only, bedrock-mantle NO, no Geo/Global profiles. In-Region YES in 22
    // regions — the widest coverage in this table.
    "titan-v2": {
        id: "amazon.titan-embed-text-v2:0",
        maxBatchSize: 1,
        inRegion: ["us-east-1", "us-east-2", "us-west-2", "us-gov-east-1", "us-gov-west-1",
            "ca-central-1", "eu-central-1", "eu-central-2", "eu-north-1", "eu-south-1",
            "eu-south-2", "eu-west-1", "eu-west-2", "eu-west-3", "ap-northeast-1",
            "ap-northeast-2", "ap-northeast-3", "ap-south-1", "ap-south-2",
            "ap-southeast-2", "sa-east-1"],
        quirk: "sends `inputText` as a bare STRING; batch = n sequential calls",
        card: "https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-amazon-titan-text-embeddings-v2.html"
    },
    // Invoke-only, bedrock-mantle NO, no Geo/Global profiles. NOTE: us-east-2 is
    // In-Region NO here but YES for Titan — the two embedding models do NOT have
    // the same regional footprint.
    "cohere-en-v3": {
        id: "cohere.embed-english-v3",
        maxBatchSize: 96,
        inRegion: ["us-east-1", "us-west-2", "ca-central-1", "eu-central-1", "eu-west-1",
            "eu-west-2", "eu-west-3", "ap-northeast-1", "ap-south-1", "ap-southeast-1",
            "ap-southeast-2", "sa-east-1"],
        quirk: "sends `texts` ARRAY; `input_type` is REQUIRED; no token count",
        card: "https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-cohere-embed-english.html"
    }
};

// ---------------------------------------------------------------------------
// Derived predicates — the generator asks these, never hardcodes a combination.
// ---------------------------------------------------------------------------


# Where AUTO lands: MANTLE -> CONVERSE -> INVOKE (Amendment 2). A geo prefix keeps
# the call on the runtime surface, so AUTO + prefix resolves to CONVERSE.
public isolated function autoFamilyFor(ModelCap m, boolean geoPrefixed) returns string {
    if geoPrefixed {
        return "CONVERSE";
    }
    return m.mantle ? "MANTLE" : "CONVERSE";
}

# Typed `generate()` needs a non-Mantle route; a Mantle route must refuse it.
public isolated function supportsStructuredOutput(string family) returns boolean
    => family != "MANTLE";

# Is a BARE-id call valid in this region?
public isolated function bareCallableIn(ModelCap m, string region) returns boolean
    => m.inRegion.indexOf(region) is int;

# Is `<prefix>.<id>` a real inference profile for this model?
public isolated function geoValid(ModelCap m, string prefix) returns boolean
    => prefix == "global" ? m.globalProfile : m.geoPrefixes.indexOf(prefix) is int;
