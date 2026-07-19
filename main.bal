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

public function main() returns error? {
    io:println(auditNecessary());
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
    check runAll();
}
