import { execFileSync } from "node:child_process";
import { requireThrowawayCatalog } from "./catalog-guard.mjs";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const NEWLINE_PLACEHOLDER = "~NL~";
const FIELD_SEPARATOR = "@@SEP@@";

export function sqliteRows(catalogPath, query) {
  const out = execFileSync("sqlite3", ["-readonly", "-separator", "|", catalogPath, query], { encoding: "utf8" });
  return out.trim().split("\n").filter(Boolean).map((line) => line.split("|"));
}

export function developHistory(catalogPath, photoId) {
  return sqliteRows(
    catalogPath,
    `select id_local, name from Adobe_libraryImageDevelopHistoryStep where image=${Number(photoId)} order by id_local`,
  ).map(([id, name]) => ({ id: Number(id), name }));
}

export function storedSettingsRow(catalogPath, photoId) {
  const out = execFileSync(
    "sqlite3",
    [
      "-readonly",
      "-separator",
      FIELD_SEPARATOR,
      catalogPath,
      `select hasBigData, replace(text, char(10), '${NEWLINE_PLACEHOLDER}') from Adobe_imageDevelopSettings where image=${Number(photoId)}`,
    ],
    { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
  ).trim();
  if (!out) return null;
  const separator = out.indexOf(FIELD_SEPARATOR);
  return {
    hasBigData: out.slice(0, separator) === "1",
    text: out.slice(separator + FIELD_SEPARATOR.length).replaceAll(NEWLINE_PLACEHOLDER, "\n"),
  };
}

export async function readFlushedSettings(session, photoId, flushPhotoId, { pauseMs = 1500, maxReads = 6 } = {}) {
  const catalogPath = requireThrowawayCatalog();
  await session.toolOrThrow("list_masks", { photo_id: flushPhotoId });
  await sleep(4000);
  let previous = null;
  for (let read = 0; read < maxReads; read++) {
    const row = storedSettingsRow(catalogPath, photoId);
    if (previous && row && previous.text === row.text) return row;
    previous = row;
    await sleep(pauseMs);
  }
  throw new Error(`stored settings of ${photoId} did not stabilise in ${maxReads} reads (two equal reads needed)`);
}

function matchingBraceBlock(text, start) {
  let depth = 0;
  for (let i = start; i < text.length; i++) {
    if (text[i] === "{") depth++;
    else if (text[i] === "}") {
      depth--;
      if (depth === 0) return text.slice(start, i + 1);
    }
  }
  return "";
}

export function maskGroupsText(settingsText) {
  const key = settingsText.indexOf("MaskGroupBasedCorrections = ");
  if (key < 0) return "";
  return matchingBraceBlock(settingsText, settingsText.indexOf("{", key));
}

export function parseLuaTable(source) {
  let position = 0;
  const skipWhitespace = () => {
    while (position < source.length && /\s/.test(source[position])) position++;
  };
  const parseString = () => {
    let cursor = position + 1;
    let out = "";
    while (source[cursor] !== '"') {
      if (source[cursor] === "\\") cursor++;
      out += source[cursor++];
    }
    position = cursor + 1;
    return out;
  };
  const parseValue = () => {
    skipWhitespace();
    if (source[position] === "{") return parseTable();
    if (source[position] === '"') return parseString();
    const word = /^[^,}\s]+/.exec(source.slice(position))[0];
    position += word.length;
    if (word === "true") return true;
    if (word === "false") return false;
    if (word === "nil") return null;
    return Number(word);
  };
  const parseTable = () => {
    position++;
    const array = [];
    const object = {};
    let hasKeys = false;
    for (;;) {
      skipWhitespace();
      if (source[position] === "}") {
        position++;
        return hasKeys ? object : array;
      }
      if (source[position] === ",") {
        position++;
        continue;
      }
      const rest = source.slice(position);
      const bare = /^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*/.exec(rest);
      const quoted = /^\["([^"]+)"\]\s*=\s*/.exec(rest);
      const keyMatch = bare ?? quoted;
      if (keyMatch) {
        position += keyMatch[0].length;
        object[keyMatch[1]] = parseValue();
        hasKeys = true;
      } else {
        array.push(parseValue());
      }
    }
  };
  return parseValue();
}

export function storedMaskGroups(settingsText) {
  const text = maskGroupsText(settingsText);
  if (!text) return [];
  const parsed = parseLuaTable(text);
  return Array.isArray(parsed) ? parsed : [];
}

export function summarizeMaskGroups(groups) {
  return groups.map((group) => ({
    id: group.CorrectionID,
    name: group.CorrectionName,
    exposure: group.LocalExposure2012,
    contrast: group.LocalContrast2012,
    components: (group.CorrectionMasks ?? []).map((mask) => ({
      id: mask.MaskID,
      what: mask.What,
      inverted: mask.MaskInverted,
      blend: mask.MaskBlendMode,
    })),
  }));
}
