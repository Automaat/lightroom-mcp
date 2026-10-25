import { execFileSync } from "node:child_process";
import { LIGHTROOM_PROCESS_NAME } from "./paths.mjs";

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function osascript(script) {
  return execFileSync("osascript", ["-e", script], { encoding: "utf8" }).trim();
}

export function frontmostProcessName() {
  return osascript('tell application "System Events" to get name of first process whose frontmost is true');
}

export async function ensureLightroomFrontmost({ attempts = 5 } = {}) {
  let front = frontmostProcessName();
  for (let attempt = 0; front !== LIGHTROOM_PROCESS_NAME && attempt < attempts; attempt++) {
    osascript(`tell application "${LIGHTROOM_PROCESS_NAME}" to activate`);
    await sleep(1000);
    front = frontmostProcessName();
  }
  if (front !== LIGHTROOM_PROCESS_NAME) {
    throw new Error(`refusing to send input: frontmost process is "${front}", not ${LIGHTROOM_PROCESS_NAME}`);
  }
}

function quote(text) {
  return `"${text.replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;
}

export async function clickMenuItem(menuName, itemNamePrefix) {
  await ensureLightroomFrontmost();
  return osascript(`
tell application "System Events" to tell process "${LIGHTROOM_PROCESS_NAME}"
  set theMenu to menu ${quote(menuName)} of menu bar 1
  repeat with theItem in menu items of theMenu
    set itemName to ""
    try
      set itemName to name of theItem
    end try
    if itemName is not missing value and itemName starts with ${quote(itemNamePrefix)} then
      click theItem
      return itemName
    end if
  end repeat
  error "menu item not found: ${menuName} > ${itemNamePrefix}"
end tell`);
}

const FIELD_SEPARATOR = "\u001f";
const RECORD_SEPARATOR = "\u001e";
const IGNORED_WINDOW_FRAGMENTS = ["Adobe Photoshop Lightroom Classic", "Lightroom Plug-in Manager"];

export function listModalWindows() {
  const raw = osascript(`
set fieldSep to character id 31
set recordSep to character id 30
tell application "System Events" to tell process "${LIGHTROOM_PROCESS_NAME}"
  set found to {}
  repeat with w in windows
    set wTitle to ""
    set wSubrole to ""
    try
      set wTitle to name of w as text
    end try
    try
      set wSubrole to subrole of w as text
    end try
    if wTitle does not contain "Adobe Photoshop Lightroom Classic" and wTitle does not contain "Lightroom Plug-in Manager" then
      set directButtons to {}
      try
        repeat with b in (buttons of w)
          set end of directButtons to (name of b as text)
        end repeat
      end try
      set looksLikeDialog to wSubrole is "AXDialog" or wSubrole is "AXSystemDialog" or directButtons contains "OK" or directButtons contains "Relaunch"
      if looksLikeDialog then
        set buttonNames to {}
        set labels to {}
        set els to {}
        try
          set els to entire contents of w
        end try
        repeat with e in els
          try
            if role of e is "AXButton" then set end of buttonNames to (name of e as text)
          end try
          try
            if role of e is "AXStaticText" then set end of labels to (value of e as text)
          end try
        end repeat
        set AppleScript's text item delimiters to "|"
        set end of found to wTitle & fieldSep & (buttonNames as text) & fieldSep & (labels as text)
        set AppleScript's text item delimiters to ""
      end if
    end if
  end repeat
  set AppleScript's text item delimiters to recordSep
  return found as text
end tell`);
  return parseModalWindows(raw);
}

export function parseModalWindows(raw) {
  return raw
    .split(RECORD_SEPARATOR)
    .filter(Boolean)
    .map((record) => {
      const [title, buttons, labels] = record.split(FIELD_SEPARATOR);
      return {
        title,
        buttons: buttons ? buttons.split("|").filter(Boolean) : [],
        text: labels ?? "",
      };
    })
    .filter((window) => window.buttons.length > 0)
    .filter((window) => !IGNORED_WINDOW_FRAGMENTS.some((fragment) => window.title.includes(fragment)));
}

const NO_DETECTED_PATTERN = /detected/i;
const ADDRESS_LOOKUP_PATTERN = /address lookup/i;
const DECLINE_BUTTONS = ["Not Now", "No", "Don't Enable", "Disable", "Cancel"];

export function chooseModalButton(window) {
  const haystack = `${window.title} ${window.text}`;
  if (NO_DETECTED_PATTERN.test(haystack) && window.buttons.includes("OK")) return "OK";
  if (ADDRESS_LOOKUP_PATTERN.test(haystack)) {
    return DECLINE_BUTTONS.find((name) => window.buttons.includes(name)) ?? null;
  }
  return null;
}

function onElement(windowTitle, role, name, statements) {
  return osascript(`
tell application "System Events" to tell process "${LIGHTROOM_PROCESS_NAME}"
  set els to entire contents of window ${quote(windowTitle)}
  repeat with e in els
    set r to ""
    set n to ""
    try
      set r to role of e
    end try
    try
      set n to name of e as text
    end try
    if r is ${quote(role)} and n is ${quote(name)} then
      ${statements}
    end if
  end repeat
  error "element not found: ${role} ${name}"
end tell`);
}

export async function clickWindowButton(windowTitle, buttonName) {
  await ensureLightroomFrontmost();
  onElement(windowTitle, "AXButton", buttonName, 'click e\n      return "clicked"');
}

export async function dismissBlockingModals({ rounds = 6, pauseMs = 1500 } = {}) {
  const dismissed = [];
  for (let round = 0; round < rounds; round++) {
    const target = listModalWindows()
      .map((window) => ({ window, button: chooseModalButton(window) }))
      .find((candidate) => candidate.button !== null);
    if (!target) break;
    await clickWindowButton(target.window.title, target.button);
    dismissed.push({ title: target.window.title, text: target.window.text, button: target.button });
    await sleep(pauseMs);
  }
  return dismissed;
}

export async function closePluginManager() {
  const state = osascript(`
tell application "System Events" to tell process "${LIGHTROOM_PROCESS_NAME}"
  if exists window "Lightroom Plug-in Manager" then return "open"
  return "closed"
end tell`);
  if (state === "closed") return false;
  await clickWindowButton("Lightroom Plug-in Manager", "Done");
  return true;
}

const NEW_CATALOG_DIALOG = "Create Folder with New Catalog";

export async function waitForWindow(title, { timeoutMs = 20_000 } = {}) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = osascript(`
tell application "System Events" to tell process "${LIGHTROOM_PROCESS_NAME}"
  if exists window ${quote(title)} then return "yes"
  return "no"
end tell`);
    if (found === "yes") return;
    await sleep(500);
  }
  throw new Error(`window "${title}" did not appear within ${timeoutMs / 1000}s`);
}

export async function submitNewCatalogDialog(folderName, expectedParentName) {
  await ensureLightroomFrontmost();
  const parentName = onElement(NEW_CATALOG_DIALOG, "AXPopUpButton", "Where:", "return value of e");
  if (parentName !== expectedParentName) {
    await clickWindowButton(NEW_CATALOG_DIALOG, "Cancel");
    throw new Error(`New Catalog dialog proposes the folder "${parentName}", expected "${expectedParentName}"; create the catalog by hand and use --adopt-open-catalog`);
  }
  onElement(NEW_CATALOG_DIALOG, "AXTextField", "Save As:", `set focused of e to true\n      set value of e to ${quote(folderName)}\n      return "set"`);
  await sleep(500);
  await clickWindowButton(NEW_CATALOG_DIALOG, "Create");
}

export async function openNewCatalogDialog() {
  await clickMenuItem("File", "New Catalog");
  await waitForWindow(NEW_CATALOG_DIALOG);
}

export async function openRecentCatalog(catalogFileName, { timeoutMs = 30_000 } = {}) {
  await ensureLightroomFrontmost();
  osascript(`
tell application "System Events" to tell process "${LIGHTROOM_PROCESS_NAME}"
  click menu item ${quote(catalogFileName)} of menu 1 of menu item "Open Recent" of menu "File" of menu bar 1
end tell`);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    await sleep(1000);
    const relaunch = listModalWindows().find((window) => window.buttons.includes("Relaunch"));
    if (relaunch) {
      await clickWindowButton(relaunch.title, "Relaunch");
      return;
    }
  }
  throw new Error(`no Relaunch prompt appeared after opening ${catalogFileName}`);
}
