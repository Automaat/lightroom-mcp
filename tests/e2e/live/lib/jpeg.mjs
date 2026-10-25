import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { encodePng } from "./png.mjs";

const JPEG_QUALITY = "95";

export function encodeJpegWithSips(canvas) {
  if (process.platform !== "darwin") throw new Error("JPEG fixtures are encoded with sips and need macOS");
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "lrmcp-jpeg-"));
  try {
    const pngPath = path.join(scratch, "in.png");
    const jpegPath = path.join(scratch, "out.jpg");
    fs.writeFileSync(pngPath, encodePng(canvas));
    execFileSync("sips", ["-s", "format", "jpeg", "-s", "formatOptions", JPEG_QUALITY, pngPath, "--out", jpegPath], {
      stdio: "ignore",
    });
    return fs.readFileSync(jpegPath);
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
}
