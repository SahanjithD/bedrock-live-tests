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

# Filter: "" runs everything, "G" runs a block, "G12" runs a single case.
configurable string only = "";

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
isolated function providerFor(Case c) returns ai:ModelProvider|ai:Error {
    bedrock:BedrockCredentials creds;
    bedrock:BedrockCredentials|string resolved = credentialsFor(c.auth);
    if resolved is string {
        // A case that must fail before any I/O does not need real credentials.
        if c.expect == FAIL_OFFLINE {
            creds = OFFLINE_PLACEHOLDER;
        } else {
            return error ai:Error(string `SKIP: ${resolved}`);
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
|};

isolated function mkResult(string id, string entry, string detail, Verdict v, int ms,
        string evidence, string why) returns Result {
    string e = redact(evidence);
    return {
        id,
        entry,
        detail,
        verdict: v,
        ms,
        evidence: e.length() > 240 ? e.substring(0, 240) + "..." : e,
        why
    };
}

isolated function nowMs() returns int {
    [int, decimal] [s, f] = time:utcNow(6);
    return s * 1000 + <int>(f * 1000);
}

// ---------------------------------------------------------------------------
// Reporting.
// ---------------------------------------------------------------------------

isolated function selected(string id, string block) returns boolean
    => only == "" || only == block || only == id;

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
isolated function writeReport(Result[] results) returns error? {
    string[] lines = [
        "# Bedrock live run",
        "",
        string `Cases: ${results.length()}`,
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

isolated function summarise(Result[] results) {
    int nPass = 0;
    int nFail = 0;
    int nSkip = 0;
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
    }
    io:println("");
    io:println(string `PASS ${nPass}   FAIL ${nFail}   SKIP ${nSkip}   (of ${results.length()})`);
    if nFail > 0 {
        io:println("Failures above. Each prints the expectation it broke.");
    }
}
