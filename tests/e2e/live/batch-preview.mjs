#!/usr/bin/env node
import assert from "node:assert/strict";
import jpeg from "../../../server/node_modules/jpeg-js/index.js";
import { openLiveSession, requireFixtureId } from "./lib/live-catalog.mjs";

const { session, marker } = await openLiveSession();
const ids = ["wide_plain", "pano", "orient_6"].map(key => requireFixtureId(marker, key));
const photoId = ids[0];
let original, originalReason;
try {
  const response = await session.rpc("tools/call", { name: "get_photo_previews", arguments: { photo_ids: ids } });
  assert.equal(response.isError, undefined);
  const data = JSON.parse(response.content[0].text);
  const images = response.content.filter(block => block.type === "image");
  assert.equal(data.complete, true);
  assert.equal(images.length, 3);
  assert.deepEqual(data.previews.map(item => String(item.requested_id)), ids.map(String));
  for (const [index, image] of images.entries()) {
    const pixels = jpeg.decode(Buffer.from(image.data, "base64"), { useTArray: true });
    assert.ok(Math.max(pixels.width, pixels.height) <= 2000);
    assert.equal(data.previews[index].image_index, index + 1);
    console.log(JSON.stringify({ photo_id: ids[index], width: pixels.width, height: pixels.height }));
  }
  original = (await session.toolOrThrow("get_photo_metadata", { photo_id: photoId })).data;
  originalReason = (await session.toolOrThrow("get_ai_metadata", { photo_ids: [photoId] })).data.photos[0].reason ?? "";
  await session.toolOrThrow("set_flag", { photo_ids: [photoId], flag: "reject" });
  await session.toolOrThrow("set_color_label", { photo_ids: [photoId], label: "yellow" });
  await session.toolOrThrow("set_ai_metadata", { photo_ids: [photoId], reason: "Live batch-preview cull verification" });
  const metadata = (await session.toolOrThrow("get_photo_metadata", { photo_id: photoId })).data;
  assert.equal(metadata.pickStatus, -1);
  assert.equal(metadata.colorLabel, "yellow");
  const ai = (await session.toolOrThrow("get_ai_metadata", { photo_ids: [photoId] })).data;
  assert.equal(ai.photos[0].reason, "Live batch-preview cull verification");
  console.log("pass batch previews, reject flag, yellow label and private reason");
} finally {
  try {
    if (original && originalReason !== undefined) {
      await session.toolOrThrow("set_flag", { photo_ids: [photoId], flag: ({ "-1": "reject", "1": "pick" })[original.pickStatus] ?? "none" });
      await session.toolOrThrow("set_color_label", { photo_ids: [photoId], label: original.colorLabel || "none" });
      await session.toolOrThrow("set_ai_metadata", { photo_ids: [photoId], reason: originalReason });
      const restored = (await session.toolOrThrow("get_photo_metadata", { photo_id: photoId })).data;
      assert.equal(restored.pickStatus, original.pickStatus);
      assert.equal(restored.colorLabel, original.colorLabel);
      const ai = (await session.toolOrThrow("get_ai_metadata", { photo_ids: [photoId] })).data;
      assert.equal(ai.photos[0].reason ?? "", originalReason);
      console.log("pass exact flag, label and reason baseline restored");
    }
  } finally {
    await session.stop();
  }
}
