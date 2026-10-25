#!/usr/bin/env node
import { listSnapshots, restoreSnapshot, snapshotThrowawayCatalog } from "./lib/snapshot.mjs";

const [command, argument] = process.argv.slice(2);

if (command === "snapshot") {
  const result = snapshotThrowawayCatalog(argument ?? "snapshot");
  console.log(result.snapshotPath);
} else if (command === "list") {
  console.log(listSnapshots().join("\n"));
} else if (command === "restore" && argument && process.argv[4]) {
  console.log(restoreSnapshot(argument, { catalogPath: process.argv[4] }));
} else {
  console.error("usage: catalog-snapshot.mjs snapshot [label] | list | restore <snapshot-dir-name> <throwaway-catalog-path>");
  process.exit(2);
}
