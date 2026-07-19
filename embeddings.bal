// Block F — embedding providers.
//
// These have no routing ladder (Invoke-only), so the combination axes that drive
// Block G collapse. What matters instead is BATCHING: Titan's wire format takes a
// single `inputText` string, so a batch of n becomes n sequential calls, while
// Cohere takes a `texts` array capped at 96, so a batch of n becomes ceil(n/96).
// Both must return results in INPUT ORDER — and an off-by-one or an out-of-order
// merge is invisible unless the vectors are distinguishable, which is why the
// order cases use distinct inputs rather than repeated ones.

# An embedding case.
public type EmbedCase record {|
    string id;
    # "embed" | "batchEmbed"
    string entry;
    # EMBED_MODELS key.
    string model;
    string region;
    # Number of chunks to send.
    int chunks;
    # Cohere only: "search_document" | "search_query".
    string? inputType = ();
    string why;
|};

# Requests this case should cost, derived from the model's wire batch limit —
# Titan 1 per call, Cohere 96. Printed with the verdict for context; not asserted,
# because request count is not observable without instrumenting the transport.
# The ceil(n/limit) split itself is unit-tested in the module.
public isolated function expectedRequests(EmbedCase c) returns int {
    int batchLimit = EMBED_MODELS.get(c.model).maxBatchSize;
    return (c.chunks + batchLimit - 1) / batchLimit;
}

public isolated function blockF() returns EmbedCase[] {
    return [
        // --- Titan: single `inputText` STRING, batch = n sequential calls ---
        {
            id: "F1",
            entry: "embed",
            model: "titan-v2",
            region: "us-east-1",
            chunks: 1,
            why: "Titan single embed; `inputText` must be a bare STRING, not an array"
        },
        {
            id: "F3",
            entry: "batchEmbed",
            model: "titan-v2",
            region: "us-east-1",
            chunks: 10,
            why: "ORDER: 10 distinguishable chunks must come back in input order; " +
                "a concurrent fan-out that loses ordering fails here"
        },
        {
            id: "F4",
            entry: "embed",
            model: "titan-v2",
            region: "us-west-2",
            chunks: 1,
            why: "Titan in a second region. (NOTE: `inputTokenCount` is NOT asserted — " +
                "`ai:Embedding` does not carry it, so it is unreachable from here; " +
                "the module's own codec tests cover it.)"
        },
        // --- Cohere: `texts` ARRAY capped at 96, `input_type` REQUIRED ---
        {
            id: "F5",
            entry: "embed",
            model: "cohere-en-v3",
            region: "us-east-1",
            chunks: 1,
            inputType: "search_document",
            why: "Cohere single embed over the `texts` ARRAY shape. (Wire-level " +
                "assertions on `texts`/`input_type` live in the module's codec " +
                "tests; this proves the call round-trips against real AWS.)"
        },
        {
            id: "F6",
            entry: "embed",
            model: "cohere-en-v3",
            region: "us-east-1",
            chunks: 1,
            inputType: "search_query",
            why: "the OTHER input_type accepted end-to-end. A wrong value degrades " +
                "retrieval SILENTLY rather than erroring, so this cannot detect a " +
                "swap — it only proves SEARCH_QUERY is accepted. The emitted value " +
                "is asserted offline in the module's codec tests."
        },
        {
            id: "F7",
            entry: "batchEmbed",
            model: "cohere-en-v3",
            region: "us-east-1",
            chunks: 100,
            inputType: "search_document",
            why: "THE batching case: 100 chunks split 96 + 4, and the driver verifies " +
                "the first and last vectors land at index 0 and 99 — i.e. order is " +
                "preserved ACROSS the seam. (Request COUNT is not observable from " +
                "here; `expectedRequests` documents intent only.)"
        },
        {
            id: "F8",
            entry: "batchEmbed",
            model: "cohere-en-v3",
            region: "us-east-1",
            chunks: 96,
            inputType: "search_document",
            why: "boundary: exactly 96 = the batch limit. Order is verified at both " +
                "ends. (That it is ONE request rather than two is not observable " +
                "here; the ceil(n/limit) split is unit-tested in the module.)"
        }
    ];
}
