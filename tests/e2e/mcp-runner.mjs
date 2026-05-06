#!/usr/bin/env node
// E2E harness — drives the built MCP server over stdio (same protocol Claude Desktop uses)
// and runs scripted scenarios against the real Lightroom plugin.
//
// Prereqs:
//   1. Lightroom open, plugin "Start Server" clicked (token file exists, sockets bound)
//   2. server built: `mise run build`
//
// Usage:
//   node tests/e2e/mcp-runner.mjs                 # full read-only suite
//   node tests/e2e/mcp-runner.mjs read            # read-only ops
//   node tests/e2e/mcp-runner.mjs write           # mutating ops (creates collection, sets rating, etc.)
//   node tests/e2e/mcp-runner.mjs develop         # develop module ops
//   node tests/e2e/mcp-runner.mjs failure         # error/edge-case ops
//   node tests/e2e/mcp-runner.mjs all             # everything except import/export
//   node tests/e2e/mcp-runner.mjs tool <name> '<json>'   # one-shot single tool call
//   node tests/e2e/mcp-runner.mjs list-tools      # dump tool catalog from server
//
// Exit code is non-zero if any scenario fails.

import { spawn, execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import { once } from "node:events";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..", "..");
const SERVER_BIN = path.join(REPO_ROOT, "server", "dist", "index.js");

const args = process.argv.slice(2);
const mode = args[0] ?? "read";

class McpClient {
  constructor() {
    this.proc = null;
    this.buf = "";
    this.nextId = 1;
    this.pending = new Map();
    this.stderrTail = [];
  }

  async start() {
    this.proc = spawn("node", [SERVER_BIN], {
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env },
    });
    this.proc.stdout.setEncoding("utf8");
    this.proc.stderr.setEncoding("utf8");
    this.proc.stdout.on("data", (chunk) => this._onStdout(chunk));
    this.proc.stderr.on("data", (chunk) => {
      const lines = chunk.split("\n").filter(Boolean);
      this.stderrTail.push(...lines);
      while (this.stderrTail.length > 50) this.stderrTail.shift();
    });
    this.proc.on("exit", (code) => {
      for (const { reject } of this.pending.values()) {
        reject(new Error(`server exited code=${code}\nstderr tail:\n${this.stderrTail.join("\n")}`));
      }
      this.pending.clear();
    });

    // initialize
    await this._rpc("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "lightroom-mcp-e2e", version: "0.0.0" },
    });
    this._notify("notifications/initialized", {});
    // Wait until a real plugin call succeeds. Plugin's response socket
    // can take a few seconds to accept after a rebind cycle; isReady()
    // alone isn't enough. We poll a cheap call until it returns.
    const deadline = Date.now() + 20_000;
    while (Date.now() < deadline) {
      try {
        const r = await this._rpc(
          "tools/call",
          { name: "list_collections", arguments: { limit: 1 } },
          5_000,
        );
        const text = r?.content?.[0]?.text ?? "";
        if (!r.isError && !text.includes("not connected")) return;
      } catch {}
      await sleep(500);
    }
    throw new Error("plugin did not become ready within 20s");
  }

  _onStdout(chunk) {
    this.buf += chunk;
    let idx;
    while ((idx = this.buf.indexOf("\n")) !== -1) {
      const line = this.buf.slice(0, idx).trim();
      this.buf = this.buf.slice(idx + 1);
      if (!line) continue;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        continue;
      }
      if (msg.id != null && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(JSON.stringify(msg.error)));
        else resolve(msg.result);
      }
    }
  }

  _send(obj) {
    this.proc.stdin.write(JSON.stringify(obj) + "\n");
  }

  _notify(method, params) {
    this._send({ jsonrpc: "2.0", method, params });
  }

  _rpc(method, params, timeoutMs = 35_000) {
    const id = this.nextId++;
    const p = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`rpc timeout: ${method}`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (v) => {
          clearTimeout(timer);
          resolve(v);
        },
        reject: (e) => {
          clearTimeout(timer);
          reject(e);
        },
      });
    });
    this._send({ jsonrpc: "2.0", id, method, params });
    return p;
  }

  listTools() {
    return this._rpc("tools/list", {});
  }

  async callTool(name, toolArgs) {
    const result = await this._rpc("tools/call", { name, arguments: toolArgs ?? {} });
    const text = result?.content?.[0]?.text ?? "";
    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch {
      parsed = text;
    }
    return { isError: !!result.isError, text, parsed };
  }

  async stop() {
    if (!this.proc) return;
    this.proc.stdin.end();
    try {
      await Promise.race([once(this.proc, "exit"), sleep(2000)]);
    } catch {}
    if (this.proc.exitCode === null) this.proc.kill("SIGKILL");
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let pass = 0;
let fail = 0;
const failures = [];

function checkEq(label, got, want) {
  if (got !== want) throw new Error(`${label}: expected ${JSON.stringify(want)}, got ${JSON.stringify(got)}`);
}
function checkTrue(label, cond, ctx) {
  if (!cond) throw new Error(`${label}: ${ctx ?? "expected truthy"}`);
}

async function run(label, fn) {
  process.stdout.write(`▶ ${label} ... `);
  try {
    const out = await fn();
    pass++;
    console.log("OK", out ? `— ${out}` : "");
  } catch (err) {
    fail++;
    failures.push({ label, err });
    console.log("FAIL");
    console.log(`   ${err.message.split("\n").slice(0, 4).join("\n   ")}`);
  }
}

async function main() {
  if (mode === "wrong-token") {
    // Phase 9c — point the server at a token file that doesn't match
    // what the plugin has. Real token file stays untouched, so a crash
    // can't leave the system in a broken state (TOCTOU-safe).
    const fakePath = path.join(os.tmpdir(), `lr_mcp_bad_token_${Date.now()}`);
    fs.writeFileSync(fakePath, "wrong-token-deadbeef");
    process.env.LIGHTROOM_MCP_TOKEN_PATH = fakePath;
    let saw = false;
    try {
      const c = new McpClient();
      try {
        await c.start();
      } catch (err) {
        if (err.message.includes("did not become ready")) saw = true;
        else console.log(`unexpected err: ${err.message}`);
      }
      await c.stop();
    } finally {
      delete process.env.LIGHTROOM_MCP_TOKEN_PATH;
      fs.rmSync(fakePath, { force: true });
    }
    if (saw) console.log("wrong-token: plugin correctly rejected (ready-wait timed out)");
    else console.log("wrong-token: UNEXPECTED — plugin accepted bad token!");
    process.exitCode = saw ? 0 : 1;
    return;
  }

  if (mode === "port-mismatch") {
    // Phase 9d — server uses port 58773 (no plugin there), expect "not connected"
    const c = new McpClient();
    process.env.LIGHTROOM_MCP_REQUEST_PORT = "58773";
    process.env.LIGHTROOM_MCP_RESPONSE_PORT = "58774";
    let saw = false;
    try {
      await c.start();
    } catch (err) {
      if (err.message.includes("did not become ready")) saw = true;
    }
    delete process.env.LIGHTROOM_MCP_REQUEST_PORT;
    delete process.env.LIGHTROOM_MCP_RESPONSE_PORT;
    await c.stop();
    if (saw) console.log("port-mismatch: server correctly failed to connect to wrong ports");
    else console.log("port-mismatch: UNEXPECTED — server reached plugin");
    process.exitCode = saw ? 0 : 1;
    return;
  }

  if (mode === "list-tools") {
    const c = new McpClient();
    await c.start();
    const tools = await c.listTools();
    console.log(JSON.stringify(tools, null, 2));
    await c.stop();
    return;
  }

  if (mode === "tool") {
    const toolName = args[1];
    const toolArgs = args[2] ? JSON.parse(args[2]) : {};
    if (!toolName) {
      console.error("usage: mcp-runner.mjs tool <name> '<json>'");
      process.exit(2);
    }
    const c = new McpClient();
    await c.start();
    const out = await c.callTool(toolName, toolArgs);
    console.log(JSON.stringify(out.parsed ?? out.text, null, 2));
    if (out.isError) process.exitCode = 1;
    await c.stop();
    return;
  }

  const c = new McpClient();
  await c.start();

  const ctx = {};

  if (mode === "read" || mode === "all") {
    await run("tools/list returns 14 tools", async () => {
      const tools = await c.listTools();
      checkEq("tool count", tools.tools.length, 14);
    });

    await run("list_collections smoke", async () => {
      const r = await c.callTool("list_collections", { limit: 5 });
      checkTrue("not error", !r.isError, r.text);
      checkTrue("count is number", typeof r.parsed.count === "number");
      return `count=${r.parsed.count}, returned=${r.parsed.collections.length}`;
    });

    await run("get_selected_photos returns shape", async () => {
      const r = await c.callTool("get_selected_photos", { limit: 5 });
      checkTrue("not error", !r.isError, r.text);
      checkTrue("photos array", Array.isArray(r.parsed.photos));
      ctx.firstSelected = r.parsed.photos[0];
      return `count=${r.parsed.count}`;
    });

    await run("search_photos no filters paginates", async () => {
      const r = await c.callTool("search_photos", { limit: 3 });
      checkTrue("not error", !r.isError, r.text);
      checkTrue("photos array", Array.isArray(r.parsed.photos));
      ctx.firstPhoto = r.parsed.photos[0];
      return `count=${r.parsed.count}, returned=${r.parsed.photos.length}`;
    });

    await run("search_photos rating=5 (may be 0)", async () => {
      const r = await c.callTool("search_photos", { rating: 5, limit: 3 });
      checkTrue("not error", !r.isError, r.text);
      return `count=${r.parsed.count}`;
    });

    await run("get_photo_metadata for first photo", async () => {
      if (!ctx.firstPhoto) throw new Error("no photo to test against");
      const r = await c.callTool("get_photo_metadata", {
        photo_id: String(ctx.firstPhoto.id),
      });
      checkTrue("not error", !r.isError, r.text);
      checkTrue("has filename", typeof r.parsed.filename === "string");
      checkTrue("has developSettings", typeof r.parsed.developSettings === "object");
      return `${r.parsed.filename}`;
    });

    await run("get_photo_metadata by file path", async () => {
      if (!ctx.firstPhoto) throw new Error("no photo to test against");
      const r = await c.callTool("get_photo_metadata", { photo_id: ctx.firstPhoto.path });
      checkTrue("not error", !r.isError, r.text);
      checkEq("path roundtrip", r.parsed.path, ctx.firstPhoto.path);
    });

    await run("list_develop_presets", async () => {
      const r = await c.callTool("list_develop_presets", {});
      checkTrue("not error", !r.isError, r.text);
      checkTrue("count is number", typeof r.parsed.count === "number");
      ctx.firstPreset = r.parsed.presets[0];
      return `count=${r.parsed.count}`;
    });
  }

  if (mode === "write" || mode === "all") {
    const collectionName = `MCP_E2E_${Date.now()}`;
    ctx.collectionName = collectionName;

    await run(`create_collection "${collectionName}"`, async () => {
      const r = await c.callTool("create_collection", { name: collectionName });
      checkTrue("not error", !r.isError, r.text);
      checkEq("success", r.parsed.success, true);
    });

    await run("list_collections includes new collection", async () => {
      const r = await c.callTool("list_collections", { limit: 1000 });
      checkTrue("not error", !r.isError, r.text);
      const found = r.parsed.collections.find((c) => c.name === collectionName);
      checkTrue("found", !!found, `${collectionName} not in list`);
    });

    if (!ctx.firstPhoto) {
      const search = await c.callTool("search_photos", { limit: 1 });
      ctx.firstPhoto = search.parsed.photos?.[0];
    }

    if (ctx.firstPhoto) {
      await run("add_to_collection (first photo)", async () => {
        const r = await c.callTool("add_to_collection", {
          collection_name: collectionName,
          photo_ids: [String(ctx.firstPhoto.id)],
        });
        checkTrue("not error", !r.isError, r.text);
        checkEq("added", r.parsed.added, 1);
      });

      const originalRating = ctx.firstPhoto.rating ?? 0;
      await run("set_rating to 3", async () => {
        const r = await c.callTool("set_rating", {
          photo_ids: [String(ctx.firstPhoto.id)],
          rating: 3,
        });
        checkTrue("not error", !r.isError, r.text);
        checkEq("updated", r.parsed.updated, 1);
      });

      await run("get_photo_metadata reflects rating=3", async () => {
        const r = await c.callTool("get_photo_metadata", {
          photo_id: String(ctx.firstPhoto.id),
        });
        checkEq("rating", r.parsed.rating, 3);
      });

      await run(`set_rating restore to ${originalRating}`, async () => {
        const r = await c.callTool("set_rating", {
          photo_ids: [String(ctx.firstPhoto.id)],
          rating: originalRating,
        });
        checkTrue("not error", !r.isError, r.text);
      });

      const tag = `mcp_e2e_${Date.now()}`;
      await run(`set_keywords add "${tag}"`, async () => {
        const r = await c.callTool("set_keywords", {
          photo_ids: [String(ctx.firstPhoto.id)],
          add_keywords: [tag],
        });
        checkTrue("not error", !r.isError, r.text);
        checkEq("updated", r.parsed.updated, 1);
      });

      await run("get_photo_metadata shows new keyword", async () => {
        const r = await c.callTool("get_photo_metadata", {
          photo_id: String(ctx.firstPhoto.id),
        });
        checkTrue("keyword present", r.parsed.keywords.includes(tag), JSON.stringify(r.parsed.keywords));
      });

      await run(`set_keywords remove "${tag}"`, async () => {
        const r = await c.callTool("set_keywords", {
          photo_ids: [String(ctx.firstPhoto.id)],
          remove_keywords: [tag],
        });
        checkTrue("not error", !r.isError, r.text);
      });

      await run("get_photo_metadata no longer shows keyword", async () => {
        const r = await c.callTool("get_photo_metadata", {
          photo_id: String(ctx.firstPhoto.id),
        });
        // Lua's JSON serializes an empty {} as object, not array. Treat
        // both as "no keywords match the tag we just removed".
        const kws = Array.isArray(r.parsed.keywords) ? r.parsed.keywords : [];
        checkTrue("keyword gone", !kws.includes(tag), JSON.stringify(r.parsed.keywords));
      });
    } else {
      console.log("⚠ skipping photo-mutation tests — catalog appears empty");
    }
  }

  if (mode === "develop" || mode === "all") {
    if (!ctx.firstPhoto) {
      const search = await c.callTool("search_photos", { limit: 1 });
      ctx.firstPhoto = search.parsed.photos?.[0];
    }
    if (!ctx.firstPreset) {
      const list = await c.callTool("list_develop_presets", {});
      ctx.firstPreset = list.parsed.presets?.[0];
    }

    if (ctx.firstPhoto) {
      await run("set_develop_settings Exposure2012=0.5 then 0.0", async () => {
        const r1 = await c.callTool("set_develop_settings", {
          photo_id: String(ctx.firstPhoto.id),
          settings: { Exposure2012: 0.5 },
        });
        checkTrue("first not error", !r1.isError, r1.text);
        const meta = await c.callTool("get_photo_metadata", {
          photo_id: String(ctx.firstPhoto.id),
        });
        checkTrue("exposure ~0.5", Math.abs((meta.parsed.developSettings.exposure ?? 0) - 0.5) < 1e-6,
          `got ${meta.parsed.developSettings.exposure}`);
        const r2 = await c.callTool("set_develop_settings", {
          photo_id: String(ctx.firstPhoto.id),
          settings: { Exposure2012: 0.0 },
        });
        checkTrue("restore not error", !r2.isError, r2.text);
      });

      if (ctx.firstPreset) {
        await run(`apply_develop_preset "${ctx.firstPreset.name}"`, async () => {
          const r = await c.callTool("apply_develop_preset", {
            photo_ids: [String(ctx.firstPhoto.id)],
            preset_name: ctx.firstPreset.name,
          });
          checkTrue("not error", !r.isError, r.text);
          checkEq("applied", r.parsed.applied, 1);
        });
      }
    }
  }

  if (mode === "develop" || mode === "all") {
    // copy_develop_settings (Phase 6) — needs two photos
    const twoPhotos = await c.callTool("search_photos", { limit: 2 });
    if (!twoPhotos.isError && twoPhotos.parsed.photos.length >= 2) {
      const src = twoPhotos.parsed.photos[0];
      const dst = twoPhotos.parsed.photos[1];

      await run("copy_develop_settings (whitelist Contrast2012)", async () => {
        await c.callTool("set_develop_settings", {
          photo_id: String(src.id),
          settings: { Contrast2012: 42 },
        });
        const cp = await c.callTool("copy_develop_settings", {
          source_id: String(src.id),
          target_ids: [String(dst.id)],
          settings: ["Contrast2012"],
        });
        checkTrue("not error", !cp.isError, cp.text);
        checkEq("copied", cp.parsed.copied, 1);
        const dstMeta = await c.callTool("get_photo_metadata", {
          photo_id: String(dst.id),
        });
        checkEq("dst contrast", dstMeta.parsed.developSettings.contrast, 42);
        // restore source
        await c.callTool("set_develop_settings", {
          photo_id: String(src.id),
          settings: { Contrast2012: 0 },
        });
        await c.callTool("set_develop_settings", {
          photo_id: String(dst.id),
          settings: { Contrast2012: 0 },
        });
      });
    }
  }

  if (mode === "export" || mode === "all") {
    // Phase 7b — export to /tmp, verify file + dimensions.
    // Prefer a real photo (rating>=1 typically means actual catalog content,
    // skipping test fixtures like synthetic PNGs that LR refuses to render).
    let search = await c.callTool("search_photos", { rating: 5, limit: 1 });
    if (search.isError || !search.parsed.photos?.length) {
      search = await c.callTool("search_photos", { limit: 1 });
    }
    const photo = search.parsed.photos?.[0];
    if (photo) {
      const dest = path.join(os.tmpdir(), `lr_export_e2e_${Date.now()}`);
      fs.mkdirSync(dest, { recursive: true });
      await run(`export_photos JPEG @1024 → ${dest}`, async () => {
        const r = await c.callTool("export_photos", {
          photo_ids: [String(photo.id)],
          destination: dest,
          format: "jpeg",
          quality: 80,
          width: 1024,
          height: 1024,
        });
        checkTrue("not error", !r.isError, r.text);
        checkEq("exported count", r.parsed.exported, 1);
        // Search recursively in case LR put it in a subfolder, AND search
        // the photo's source folder (in case destinationType was ignored).
        const allInDest = execFileSync("find", [dest, "-type", "f"], { encoding: "utf8" }).trim();
        const jpegs = allInDest.split("\n").filter((p) => /\.(jpe?g)$/i.test(p));
        checkTrue("at least one jpeg", jpegs.length >= 1,
          `dest tree: [${allInDest}], srcDir: ${path.dirname(photo.path)}`);
        const out = jpegs[0];
        const sips = execFileSync("sips", ["-g", "pixelWidth", "-g", "pixelHeight", out], {
          encoding: "utf8",
        });
        const w = Number((sips.match(/pixelWidth: (\d+)/) ?? [])[1]);
        const h = Number((sips.match(/pixelHeight: (\d+)/) ?? [])[1]);
        checkTrue("long edge ≤ 1024", Math.max(w, h) <= 1024, `got ${w}x${h}`);
      });
      // Keep dest around for inspection if test failed
      if (failures.find((f) => f.label.startsWith("export_photos"))) {
        console.log(`(left ${dest} for inspection)`);
      } else {
        fs.rmSync(dest, { recursive: true, force: true });
      }
    }
  }

  if (mode === "pagination" || mode === "all") {
    // Phase 10a — offset/limit slices don't overlap, count is stable
    await run("search_photos pagination is consistent", async () => {
      const a = await c.callTool("search_photos", { limit: 5, offset: 0 });
      const b = await c.callTool("search_photos", { limit: 5, offset: 5 });
      checkEq("count stable", a.parsed.count, b.parsed.count);
      const aIds = new Set(a.parsed.photos.map((p) => String(p.id)));
      const bIds = b.parsed.photos.map((p) => String(p.id));
      const overlap = bIds.filter((id) => aIds.has(id));
      checkEq("no overlap", overlap.length, 0);
      if (a.parsed.count > 5) checkEq("page 1 has_more", a.parsed.has_more, true);
    });

    // Concurrent in-flight calls — exercises dispatcher demux
    await run("Promise.all of three different calls", async () => {
      const [r1, r2, r3] = await Promise.all([
        c.callTool("list_collections", { limit: 1 }),
        c.callTool("search_photos", { limit: 1 }),
        c.callTool("list_develop_presets", {}),
      ]);
      checkTrue("r1 ok", !r1.isError, r1.text);
      checkTrue("r2 ok", !r2.isError, r2.text);
      checkTrue("r3 ok", !r3.isError, r3.text);
    });
  }

  if (mode === "failure" || mode === "all") {
    await run("unknown tool returns isError", async () => {
      const r = await c.callTool("does_not_exist", {});
      checkEq("isError", r.isError, true);
    });

    await run("get_photo_metadata bad id returns isError", async () => {
      const r = await c.callTool("get_photo_metadata", { photo_id: "not-a-real-id-99999" });
      checkEq("isError", r.isError, true);
    });

    await run("set_rating out-of-range returns isError", async () => {
      const r = await c.callTool("set_rating", { photo_ids: ["1"], rating: 9 });
      checkEq("isError", r.isError, true);
    });

    await run("create_collection without name returns isError", async () => {
      const r = await c.callTool("create_collection", {});
      checkEq("isError", r.isError, true);
    });
  }

  await c.stop();

  console.log(`\n${pass} passed, ${fail} failed`);
  if (fail > 0) {
    console.log("\nfailures:");
    for (const f of failures) console.log(`  - ${f.label}: ${f.err.message.split("\n")[0]}`);
    process.exitCode = 1;
  }
}

main().catch((err) => {
  console.error("fatal:", err);
  process.exit(2);
});
