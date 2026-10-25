#!/usr/bin/env node
import path from "node:path";
import { CANDIDATE_BUNDLE_DIR } from "./lib/paths.mjs";
import { installCandidateBundle, latestBackup, restoreBundle } from "./lib/plugin-bundle.mjs";

const [command, argument] = process.argv.slice(2);

if (command === "install") {
  const candidateDirectory = path.resolve(argument ?? CANDIDATE_BUNDLE_DIR);
  const result = installCandidateBundle({ candidateDirectory });
  console.log(`backup: ${result.backupDirectory}`);
  console.log("installed bundle verified identical to the candidate (diff -rq)");
  if (result.needsFullLightroomRestart) {
    console.log(`added Lua files need a full Lightroom restart (Reload Plug-in does not see them): ${result.addedLuaFiles.join(", ")}`);
  } else {
    console.log("no added Lua files: mise run plugin:reload is enough");
  }
} else if (command === "restore") {
  const backupDirectory = path.resolve(argument ?? latestBackup().backupDirectory);
  restoreBundle({ backupDirectory });
  console.log(`restored ${backupDirectory} and verified it with diff -rq; restart Lightroom if Lua files were removed`);
} else {
  console.error("usage: install-bundle.mjs install [candidate-dir] | restore [backup-dir]");
  process.exit(2);
}
