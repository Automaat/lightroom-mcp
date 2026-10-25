#!/usr/bin/env node
import { openRecentCatalog } from "./lib/ax.mjs";

const catalogFileName = process.argv[2];
if (!catalogFileName) {
  console.error("usage: open-recent-catalog.mjs <catalog file name, as listed in File > Open Recent>");
  process.exit(2);
}
await openRecentCatalog(catalogFileName);
console.log(`relaunching into ${catalogFileName}`);
