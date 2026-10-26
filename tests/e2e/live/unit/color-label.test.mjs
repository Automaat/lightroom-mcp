import test from "node:test";
import assert from "node:assert/strict";
import { labelForRestore } from "../lib/color-label.mjs";

test("cleared SDK gray labels restore through the write API's none value", () => {
  for (const label of ["gray", "", undefined, null]) assert.equal(labelForRestore(label), "none");
});

test("existing color labels keep their write values", () => {
  for (const label of ["red", "yellow", "green", "blue", "purple", "none"]) {
    assert.equal(labelForRestore(label), label);
  }
});
