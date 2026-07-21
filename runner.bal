// Runner — configuration, credentials, provider construction, and reporting.
//
// SAFETY: this file never logs a credential. `redact` is applied to every string
// that reaches a report or the terminal, and it is applied to ERROR MESSAGES too,
// because AWS SigV4 errors habitually echo the canonical request back — which
// contains the Authorization header.

import ballerina/ai;
import ballerina/io;
import ballerina/time;
import ballerinax/ai.aws.bedrock;

// ---------------------------------------------------------------------------
// Configuration — supplied by Config.toml (gitignored).
// ---------------------------------------------------------------------------

configurable string accessKeyId = "";
configurable string secretAccessKey = "";
configurable string sessionToken = "";
configurable string bedrockApiKey = "";

configurable int maxTokens = 24;

# Per-entry output budget. 24 tokens is fine for `chat()` (we assert structure,
# not prose) but STARVES the other two:
#   generate() must emit a whole forced tool call - `{"city":"Paris",...}` is 30+
#     tokens before the tool-block scaffolding.
#   agent() must emit a tool_use block, receive the result, then answer in a
#     SECOND turn - each turn capped separately.
# Truncation surfaces as `stopReason: max_tokens` and a decode failure, which the
# old single global reported as a module bug. It was not one.
isolated function maxTokensFor(string entry) returns int {
    match entry {
        "generate" => {
            return maxTokens > 256 ? maxTokens : 256;
        }
        "agent" => {
            return maxTokens > 512 ? maxTokens : 512;
        }
    }
    return maxTokens;
}

# Set true to resolve and construct every case WITHOUT making a network call.
# Construction-time failures (Block D) are fully visible here, for free.
configurable boolean dryRun = false;

# Filter: "" runs everything, "G" runs a block, "G12" runs a single case, and a
# comma list ("G1,G2,G3") runs exactly those. Whitespace around entries is ignored.
configurable string only = "";

# Run a WINDOW of the selected cases: skip the first `offset`, then run at most
# `limit`. `limit = 0` means no limit. This is how you work through the suite a
# few cases at a time without hand-listing ids:
#   offset=0  limit=5   -> cases 1-5
#   offset=5  limit=5   -> cases 6-10
# The window is applied AFTER `only`, over the run order D -> G -> F, which is
# stable because all three block functions return literal lists.
configurable int offset = 0;
configurable int 'limit = 0;

// ---------------------------------------------------------------------------
// Credentials.
// ---------------------------------------------------------------------------

# Static/STS keys, or () when Config.toml supplies none.
isolated function sigv4Credentials() returns bedrock:BedrockCredentials? {
    if accessKeyId == "" || secretAccessKey == "" {
        return ();
    }
    if sessionToken != "" {
        return {accessKeyId, secretAccessKey, sessionToken};
    }
    return {accessKeyId, secretAccessKey};
}

# The Bedrock API key, or () when Config.toml supplies none.
isolated function bearerCredentials() returns bedrock:BedrockCredentials? {
    return bedrockApiKey == "" ? () : {apiKey: bedrockApiKey};
}

# Resolve the credential a case asks for. Returns an explanatory string when the
# required credential is absent, so a missing key SKIPS the case rather than
# failing it — an unconfigured credential is not a module bug.
# Obviously-fake credentials, used ONLY for cases that must fail before any I/O.
# The module runs resolveRoute / guardMantleGuardrail / buildEndpoint before it
# ever constructs a transport, so these guards are fully exercisable offline. Not
# gating them behind real credentials makes the cheapest, highest-value checks
# runnable by anyone, with no AWS account.
final readonly & bedrock:StaticCredentials OFFLINE_PLACEHOLDER = {
    accessKeyId: "AKIAOFFLINEGUARDONLY",
    secretAccessKey: "not-a-real-key-this-case-never-reaches-the-network"
};

# Why a case could not run at all. A DISTINCT TYPE, not an error whose message
# starts with "SKIP: ".
#
# The old scheme encoded skip-ness in an error string and recovered it downstream
# with `msg.startsWith("SKIP: ")`. That silently reclassified any module error
# beginning with those six characters from FAIL to SKIP, and coupled two files
# through a string literal with no shared constant. A skip is not an error; it now
# has its own type and cannot be forged by message text.
public type Skip record {|
    string reason;
|};

isolated function credentialsFor(string auth) returns bedrock:BedrockCredentials|string {
    match auth {
        "sigv4" => {
            bedrock:BedrockCredentials? c = sigv4Credentials();
            return c ?: "no accessKeyId/secretAccessKey in Config.toml";
        }
        "bearer" => {
            bedrock:BedrockCredentials? c = bearerCredentials();
            return c ?: "no bedrockApiKey in Config.toml";
        }
    }
    bedrock:BedrockCredentials? fallback = sigv4Credentials() ?: bearerCredentials();
    return fallback ?: "no credentials of any kind in Config.toml";
}

// ---------------------------------------------------------------------------
// Redaction. Applied to EVERYTHING printed or written.
// ---------------------------------------------------------------------------

# Literal (non-regex) substring replacement. Used instead of a regex because a
# secret may contain regex metacharacters, which would silently corrupt the
# pattern and leave the secret UNREDACTED — the one failure mode we cannot accept.
isolated function replaceLiteral(string haystack, string needle, string replacement)
        returns string {
    if needle == "" {
        return haystack;
    }
    string out = "";
    string rest = haystack;
    while true {
        int? at = rest.indexOf(needle);
        if at is () {
            return out + rest;
        }
        out = out + rest.substring(0, at) + replacement;
        rest = rest.substring(at + needle.length());
    }
}

# Replace any configured secret with a marker. Deliberately value-based rather
# than pattern-based: a pattern can miss, but an exact secret we hold cannot.
public isolated function redact(string s) returns string {
    string out = s;
    foreach string secret in [secretAccessKey, bedrockApiKey, sessionToken] {
        if secret.length() >= 8 {
            out = replaceLiteral(out, secret, "...REDACTED");
        }
    }
    // Header echoes: AWS SigV4 errors habitually quote the canonical request back.
    // A SigV4 header is `AWS4-HMAC-SHA256 Credential=..., SignedHeaders=..., Signature=...`.
    // Stopping at the first space left Credential/SignedHeaders/Signature in the
    // report. Consume to end-of-line instead.
    out = re `(?i:authorization|x-api-key)\s*[:=][^\n\r]*`.replaceAll(out, "...REDACTED-HEADER");
    // Belt-and-braces: kill any lone SigV4 signature that reached us another way.
    out = re `(?i:Signature=)[A-Fa-f0-9]{16,}`.replaceAll(out, "Signature=...REDACTED");
    out = re `(?i:bearer)\s+[A-Za-z0-9._\-]+`.replaceAll(out, "Bearer ...REDACTED");
    // The access key id is not secret, but it identifies the account.
    if accessKeyId.length() >= 8 {
        out = replaceLiteral(out, accessKeyId, "AKIA...REDACTED");
    }
    return out;
}

// ---------------------------------------------------------------------------
// Provider construction — vendor class chosen by the model-id prefix.
// ---------------------------------------------------------------------------

isolated function apiFamilyOf(string family) returns bedrock:ApiFamily {
    match family {
        "CONVERSE" => {
            return bedrock:CONVERSE;
        }
        "INVOKE" => {
            return bedrock:INVOKE;
        }
        "MANTLE" => {
            return bedrock:MANTLE;
        }
    }
    return bedrock:AUTO;
}

# Vendor prefix of a model id, ignoring any CRIS geo prefix.
# `us.anthropic.claude-opus-4-8` -> "anthropic".
isolated function vendorOf(string wireId) returns string {
    // An ARN carries no vendor token, but it MUST still reach the module so its
    // ARN parsing and the imported-model/custom-model guards actually run. Any
    // vendor class routes it: the ARN path is in the shared spine, not the facade.
    // Previously this returned "" and the harness raised its OWN error, which the
    // FAIL_OFFLINE branch then counted as a pass — D6 passed without ever
    // reaching the module, and would still pass if its guard were deleted.
    if wireId.startsWith("arn:") {
        return "anthropic";
    }
    string[] parts = re `\.`.split(wireId);
    foreach string p in parts {
        match p {
            "anthropic"|"openai"|"amazon"|"mistral"|"qwen"|"google"|"deepseek" => {
                return p;
            }
        }
    }
    return "";
}

# Build the right vendor provider for a case.
#
# The wire id (geo prefix included) is passed straight through as a `string`, which
# is the documented escape hatch for any model not in a vendor enum.
isolated function providerFor(Case c) returns ai:ModelProvider|Skip|ai:Error {
    bedrock:BedrockCredentials creds;
    bedrock:BedrockCredentials|string resolved = credentialsFor(c.auth);
    if resolved is string {
        // A case that must fail before any I/O does not need real credentials.
        if c.expect == FAIL_OFFLINE {
            creds = OFFLINE_PLACEHOLDER;
        } else {
            return {reason: resolved};
        }
    } else {
        creds = resolved;
    }
    bedrock:ApiFamily family = apiFamilyOf(c.family);
    string id = c.wireId;
    string region = c.region;
    int budget = maxTokensFor(c.entry);

    // Some models CONSTRAIN temperature (mythos-5 demands 1.0). The module coerces
    // a nil temperature to its own 0.7 default, so "leave it unset" is not an
    // option — the table has to supply the required value explicitly.
    decimal temp = 0.0d;
    if c.model != "" && MODELS.hasKey(c.model) {
        decimal? forced = MODELS.get(c.model).forceTemperature;
        if forced is decimal {
            temp = forced;
        }
    }

    // A guardrail on a Mantle route must be a construction error naming
    // ApplyGuardrail, so the flag has to reach the provider for D5 to mean anything.
    bedrock:GuardrailConfig guardrail = {
        guardrailIdentifier: "gr-live-test-placeholder",
        guardrailVersion: "1"
    };

    match vendorOf(id) {
        "anthropic" => {
            if c.withGuardrail {
                return new bedrock:AnthropicModelProvider(creds, id, region, budget,
                        temp, apiFamily = family, guardrail = guardrail);
            }
            return new bedrock:AnthropicModelProvider(creds, id, region, budget, temp,
                    apiFamily = family);
        }
        "openai" => {
            if c.withGuardrail {
                return new bedrock:OpenAIModelProvider(creds, id, region, budget,
                        temp, apiFamily = family, guardrail = guardrail);
            }
            return new bedrock:OpenAIModelProvider(creds, id, region, budget, temp,
                    apiFamily = family);
        }
        "amazon" => {
            return new bedrock:AmazonModelProvider(creds, id, region, budget, temp,
                    apiFamily = family);
        }
        "mistral" => {
            return new bedrock:MistralModelProvider(creds, id, region, budget, temp,
                    apiFamily = family);
        }
        "qwen" => {
            return new bedrock:QwenModelProvider(creds, id, region, budget, temp,
                    apiFamily = family);
        }
        "google" => {
            return new bedrock:GoogleModelProvider(creds, id, region, budget, temp,
                    apiFamily = family);
        }
        "deepseek" => {
            return new bedrock:DeepSeekModelProvider(creds, id, region, budget, temp,
                    apiFamily = family);
        }
    }
    return error ai:Error(string `no vendor provider for model id '${id}'`);
}

// ---------------------------------------------------------------------------
// Results.
// ---------------------------------------------------------------------------

public enum Verdict {
    PASS,
    FAIL,
    SKIP
}

public type Result record {|
    string id;
    string entry;
    string detail;
    Verdict verdict;
    # Milliseconds the case took, live calls included.
    int ms;
    # First ~200 chars of the model's reply, or the error. Always redacted.
    string evidence;
    string why;
    # True only if this case actually sent a request to AWS. Offline guards and
    # skips are false, which is how `nLive` can be 0 on an all-PASS run.
    boolean live = false;
|};

isolated function mkResult(string id, string entry, string detail, Verdict v, int ms,
        string evidence, string why, boolean live = false) returns Result {
    string e = redact(evidence);
    return {
        id,
        entry,
        detail,
        verdict: v,
        ms,
        evidence: e.length() > 240 ? e.substring(0, 240) + "..." : e,
        why,
        live
    };
}

isolated function nowMs() returns int {
    [int, decimal] [s, f] = time:utcNow(6);
    return s * 1000 + <int>(f * 1000);
}

// ---------------------------------------------------------------------------
// Reporting.
// ---------------------------------------------------------------------------

isolated function selected(string id, string block) returns boolean {
    if only == "" {
        return true;
    }
    foreach string raw in re `,`.split(only) {
        string want = raw.trim();
        if want != "" && (want == block || want == id) {
            return true;
        }
    }
    return false;
}

isolated function printResult(Result r) {
    string mark = r.verdict == PASS ? "PASS" : (r.verdict == SKIP ? "SKIP" : "FAIL");
    io:println(string `[${mark}] ${r.id}  ${r.entry}  ${r.detail}  (${r.ms}ms)`);
    if r.verdict != PASS {
        io:println(string `        why: ${r.why}`);
        io:println(string `        got: ${r.evidence}`);
    }
}

# Write a markdown report to results/. Credentials are already redacted by
# `record`, but `redact` is applied again here as a belt-and-braces pass.
isolated function writeReport(Result[] results, Summary s) returns error? {
    // The totals go in the REPORT, not just the terminal. Previously the header
    // said only "Cases: 60", so a reader skimning the markdown saw 60 rows and no
    // indication that 56 of them never ran.
    string verdictLine = s.nSkip > 0
        ? string `**PASS ${s.nPass} / FAIL ${s.nFail} / SKIP ${s.nSkip}** — ` +
            string `${s.nSkip} case(s) did NOT run. This report does not cover them.`
        : string `**PASS ${s.nPass} / FAIL ${s.nFail} / SKIP 0**`;
    string[] lines = [
        "# Bedrock live run",
        "",
        string `Cases selected: ${results.length()}`,
        verdictLine,
        string `Live calls actually made: ${s.nLive}`,
        "",
        "| id | entry | detail | verdict | ms | evidence |",
        "| --- | --- | --- | --- | --- | --- |"
    ];
    foreach Result r in results {
        string ev = redact(r.evidence);
        ev = replaceLiteral(ev, "|", "\\|");
        ev = replaceLiteral(ev, "\n", " ");
        lines.push(string `| ${r.id} | ${r.entry} | ${r.detail} | ${r.verdict} | ` +
            string `${r.ms} | ${ev} |`);
    }
    check io:fileWriteLines("results/run.md", lines);
}

public type Summary record {|
    int nPass;
    int nFail;
    int nSkip;
    # Cases that actually crossed the network. A run can be all-PASS with this at
    # zero (every Block D guard passes offline) — which is NOT evidence that AWS
    # integration works.
    int nLive;
|};

isolated function tally(Result[] results) returns Summary {
    int nPass = 0;
    int nFail = 0;
    int nSkip = 0;
    int nLive = 0;
    foreach Result r in results {
        match r.verdict {
            PASS => {
                nPass += 1;
            }
            FAIL => {
                nFail += 1;
            }
            _ => {
                nSkip += 1;
            }
        }
        if r.live {
            nLive += 1;
        }
    }
    return {nPass, nFail, nSkip, nLive};
}

# Print the verdict. SKIP is now as loud as FAIL.
#
# The old summary printed SKIP third on one unadorned line and reserved the only
# warning banner for FAIL. A run with no credentials therefore printed
# `PASS 0 FAIL 0 SKIP 60` and read as clean — that exact run is what was committed
# to results/run.md. A skipped case tested NOTHING, so it gets a banner too.
isolated function summarise(Result[] results, Summary s) {
    io:println("");
    io:println(string `PASS ${s.nPass}   FAIL ${s.nFail}   SKIP ${s.nSkip}   ` +
        string `(of ${results.length()} selected)`);
    io:println(string `Live calls that reached AWS: ${s.nLive}`);

    if s.nFail > 0 {
        io:println("");
        io:println("!! FAILURES above. Each prints the expectation it broke.");
    }
    if s.nSkip > 0 {
        io:println("");
        io:println(string `!! ${s.nSkip} CASE(S) SKIPPED — these tested NOTHING.`);
        io:println("   A skip is not a pass. Common cause: Config.toml is missing or");
        io:println("   has no credentials, so the run looks clean while proving nothing.");
        io:println("   Fix the setup and re-run before trusting this result.");
    }
    if s.nLive == 0 && !dryRun {
        io:println("");
        io:println("!! ZERO live calls were made. Nothing was verified against AWS.");
    }
    if s.nFail == 0 && s.nSkip == 0 && s.nLive > 0 {
        io:println("");
        io:println("All selected cases ran and passed.");
    }
}
