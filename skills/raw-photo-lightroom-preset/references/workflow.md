# RAW-First Lightroom Workflow v2

## 1. Establish provenance

For each RAW/preview pair, record:

- `relative_raw_path`
- `relative_preview_path`
- RAW and preview stem
- capture time, camera model, dimensions, and file size when available
- renderer: Lightroom Classic or Camera Raw
- renderer version
- baseline profile
- whether Catalog edits, sidecar XMP, virtual copies, or RAW+JPEG pairing already exist
- export time and export settings
- `provenance_status`: `confirmed`, `ambiguous`, or `missing`

Do not pair by basename alone when two folders contain the same stem. Require relative paths plus metadata. Missing, duplicate, or conflicting matches become `未分類`.

If the master RAW already has edits, do not reset it. Use a user-approved virtual copy, duplicate catalog, or dedicated representative photo. If none is available, stop before mutation.

## 2. Culling contract

Keep selection, editing need, and style confidence separate.

### `selection_status`

- `交付候選` (`delivery_candidate`): strong composition, focus, and expression.
- `保留` (`keep`): worth retaining but not a delivery priority.
- `淘汰` (`reject`): clear technical or content failure when the user asked for rejection decisions.
- `待確認` (`uncertain`): duplicate ambiguity or insufficient evidence.

### `edit_status`

- `RAW 待檢` (`raw_review_required`): ordinary JPG only or RAW render missing.
- `輕微全域調整` (`minor_global_adjustment`): global exposure, WB, tone, or color likely sufficient.
- `需局部調整` (`local_edit_required`): masks, crop, healing, subject/background separation, or local skin work is needed.
- `未知` (`unknown`): evidence is insufficient.

### `style_status`

- `已分類` (`classified`)
- `未分類` (`unclassified`)

Use `confidence`: `high`, `medium`, or `low`. A camera JPG can support `selection_status`, but it cannot by itself establish a final `edit_status` or preset direction.

## 3. Cluster before editing

Cluster by lighting and intent, not only event name. Typical splits include outdoor shade, indoor warm/mixed light, stage light, backlight, and high ISO. Choose one representative RAW per cluster and keep difficult outliers separate.

Do not create one universal preset for visibly different clusters.

## 4. Closed-loop editing passes

Export every comparison from Lightroom into a unique, initially empty folder. Use one photo per folder when the MCP export response does not return exact filenames.

### Pass 0 - Baseline

- Read current metadata and develop settings.
- Export the current Lightroom render.
- Record baseline settings and file hash/path.
- Record the reference image and the user's intent, if provided.

### Pass 1 - Technical correction

Adjust only WB, Exposure, Highlights, Shadows, Whites, and Blacks. Target usable exposure, protected skin/highlights, and plausible shadows. Do not add creative color here.

### Pass 2 - Tonal shape

Adjust Contrast and small Whites/Blacks refinements. Use a point curve only when the active integration can round-trip it reliably. Describe the tonal goal, such as soft highlight roll-off, before setting numbers.

### Pass 3 - Color correction

Correct Temperature/Tint first, then bounded HSL changes based on visible subjects such as skin, foliage, sky, neutral objects, and artificial lighting. Do not map an event label directly to arbitrary HSL values.

### Pass 4 - Creative look

Apply only the controls supported by the active route. Keep creative choices distinct from technical correction. If Color Grading, Calibration, or Point Color cannot be read back and rendered reliably, leave them for Lightroom manual finishing.

### Pass 5 - Detail/noise

Use ISO, camera, subject texture, and a 100% check. Treat low-light/noise as a modifier, not a style. AI Denoise remains a manual recommendation unless the active route explicitly supports and verifies it.

Use one or two render/inspect cycles per pass and stop after eight total renders unless the user asks for deeper iteration. Stop earlier when changes oscillate, the visual gain is negligible, or the remaining work is local/subjective.

## 5. Checkpoints and batch application

After each pass, record:

- previous and new setting values
- rendered output path
- visible improvement and regression notes
- whether the pass is accepted, reverted, or pending

Do not copy settings to a cluster until the representative before/after is approved. Copy only the fields intended for that cluster; avoid silently copying crop, lens state, profile, WB, or detail settings.

## 6. Preset handoff

Prefer this order:

1. When preset-roundtrip MCP tools are available, read the approved historical preset, create a uniquely versioned plugin checkpoint from explicit intended fields, and compare the two.
2. Export the accepted checkpoint without overwriting an existing file. Import it into the target Lightroom version and round-trip export it when high confidence is required.
3. Use Lightroom Create Preset when the preset must be visible in the Develop panel; plugin-managed SDK checkpoints are hidden by design.
4. Use the bundled generator only when Lightroom export is unavailable and the required settings are within its validated subset.

Every handoff includes:

- cluster and representative photo
- preset filename and group
- included and intentionally excluded settings
- expected per-frame Exposure/WB range
- skin, noise, and detail checks
- photos that need local edits or a separate preset
- four validation levels from `SKILL.md`

## 7. Report shape

Provide a concise Markdown summary plus a machine-readable CSV/JSON row for every photo when the user needs operational handoff. Do not invent star/color-label mappings. If requested, define them as a separate Lightroom mapping layer with explicit columns such as `selection_status`, `edit_status`, `style_status`, `confidence`, and `compliance_status`.
