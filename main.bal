// Entry point.
//
//   bal run -- -Cdasun.bedrock_live_tests.listOnly=true   # print the plan only
//   bal run -- -Cdasun.bedrock_live_tests.dryRun=true     # construct, no AWS calls
//   bal run -- -Cdasun.bedrock_live_tests.only=G12        # one case
//   bal run -- -Cdasun.bedrock_live_tests.only=F          # one block
//   bal run                                               # everything
//
// See RUNBOOK.md.

import ballerina/io;

# Print the plan without constructing or calling anything.
configurable boolean listOnly = false;

# Treat SKIPs as failure for the exit code. On by default: a skipped case tested
# nothing, and the whole point of the exit code is that "clean" must mean "actually
# ran and actually passed". Set false only when you deliberately expect skips (e.g.
# you have SigV4 keys but no Bedrock API key, so the `bearer` cases cannot run).
configurable boolean strict = true;

public function main() returns error? {
    // The audit is a GATE, not a printout. It reports unservable picks and codecs
    // no case reaches — exactly the rot it exists to detect. It used to print and
    // be ignored, so a case list that had stopped covering a codec still ran a
    // full green suite.
    string audit = auditNecessary();
    io:println(audit);
    if audit.startsWith("Block G audit FAILED") {
        return error("Block G audit failed — the case list no longer covers what it " +
            "claims. Fix the list before running; results would not mean what the " +
            "case descriptions say.");
    }
    io:println("");

    if listOnly {
        foreach Case c in blockD() {
            io:println(string `  ${c.id}  ${c.entry}  ${c.family}->${c.expectedFamily}  ` +
                string `${c.region}  ${c.auth}  ${c.wireId}  [${c.expect}]`);
        }
        foreach Case c in blockG() {
            io:println(string `  ${c.id}  ${c.entry}  ${c.family}->${c.expectedFamily}  ` +
                string `${c.region}  ${c.auth}  ${c.wireId}  [${c.expect}]`);
        }
        foreach EmbedCase c in blockF() {
            io:println(string `  ${c.id}  ${c.entry}  ${c.model}  ${c.region}  ` +
                string `chunks=${c.chunks}  reqs=${expectedRequests(c)}`);
        }
        return;
    }

    if dryRun {
        io:println("DRY RUN - providers are constructed but no request is sent.");
        io:println("");
    }

    Summary s = check runAll();

    // Non-zero exit on anything that is not a clean, complete pass. `bal run`
    // previously exited 0 regardless of the result, so nothing downstream could
    // gate on this suite and a human had to read the terminal to learn the answer.
    if s.nFail > 0 {
        return error(string `${s.nFail} case(s) FAILED.`);
    }
    if strict && s.nSkip > 0 && !dryRun {
        return error(string `${s.nSkip} case(s) SKIPPED — they tested nothing. ` +
            string `Fix the setup, or pass -Cdasun.bedrock_live_tests.strict=false ` +
            string `if the skips are expected.`);
    }
}
