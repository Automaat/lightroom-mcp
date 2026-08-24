# Lightroom MCP Integration

## Evaluated baseline

Upstream repository: `https://github.com/Automaat/lightroom-mcp`

Evaluation snapshot: 2026-08-09, release `v0.9.0`; main commit inspected: `b05c845a546a42a6bc719f06f9310ce9cad8f7b1`.

Preset-roundtrip fork: `https://github.com/John-owo/lightroom-mcp`, branch `feat/preset-roundtrip`. Detect tools at runtime because an installed server may still be upstream `v0.9.0`.

Detect available tools at runtime because main can differ from the installed release.

## Why it helps

The integration adds the missing feedback loop:

- `get_selected_photos`: identify representatives selected in Lightroom.
- `get_photo_metadata`: read EXIF and a partial Develop state.
- `set_develop_settings`: apply bounded global/HSL/detail settings.
- `export_photos`: render the actual Lightroom result for visual comparison.
- `copy_develop_settings`: apply an approved subset to a cluster.
- `get_develop_preset`: read exact historical preset settings.
- `compare_develop_presets`: diff an approved look and a versioned candidate.
- `create_develop_preset`: capture explicit settings from a representative as a plugin-managed checkpoint.
- `export_develop_preset`: copy an exportable backing file without overwriting.

This improves setting selection. It does not by itself create a canonical preset XMP.

## Current gaps

- No direct `render_preview` tool; use `export_photos` to a new empty review folder.
- Export returns a destination and count, not exact output filenames. Export one representative per unique folder and inspect the new file.
- No virtual-copy, snapshot, undo, reset, or restore tool.
- Upstream `v0.9.0` has no create/export preset tools; the local fork adds them.
- Adobe's SDK creates plugin-managed presets that are hidden from the Develop panel. Use versioned names and export/import the accepted file, or create a visible canonical preset through Lightroom's UI.
- A preset can be exported only when Lightroom exposes a backing file. Built-in presets can lack one, and the backing format is determined by Lightroom.
- `get_photo_metadata` exposes only part of Develop state.
- The local fork's `set_develop_settings`, `copy_develop_settings`, and `create_develop_preset` allowlists include common global, HSL, detail, lens, crop, vignette, grain, and master/RGB point-curve arrays. They still do not expose Profile, Color Grading, Calibration, or Point Color.
- Tool schemas allow number/string/boolean values but do not enforce Lightroom-specific numeric ranges. Apply the bounds in the v2 workflow or fallback generator.
- `copy_develop_settings` without an explicit field list copies the full source settings. Always provide the intended field list for cluster work.

## Safe closed-loop sequence

1. Require Lightroom Classic to be open and the Lightroom MCP plugin server to report connected sockets.
2. Use a user-selected representative or an explicitly approved test photo.
3. Capture metadata/develop settings and export baseline.
4. Read the approved historical preset when one exists.
5. Change only the current pass's keys with bounded values.
6. Re-read settings and export to a new empty folder.
7. Inspect before/after. Create a uniquely versioned plugin checkpoint only for explicit intended fields.
8. Compare the candidate checkpoint against the approved historical preset and record the diff.
9. Continue, revert by applying recorded values when possible, or stop for manual Lightroom work.
10. Export the accepted checkpoint to a new filename, import/round-trip it in Lightroom, then copy an approved subset only after user approval.

Do not use this route on a master edit when the baseline cannot be restored with the available tool subset.

## Preset creation decision

- Best with the fork: create a versioned plugin checkpoint from explicit intended fields, compare it to the approved look, export it, then import/round-trip it in Lightroom.
- Best for a visible Develop-panel preset: use Lightroom's Create Preset UI from the accepted representative and select only intended fields.
- Acceptable fallback: use `generate_xmp_preset.py` for supported global settings, then import and visually validate it in Lightroom.
- Not acceptable: wrap the old one-shot XMP generator in MCP and call that a closed loop.

## Installation boundary

This is an optional local dependency. Do not install packages, edit Codex MCP configuration, or install a Lightroom plugin unless the user requests that setup. A newly configured MCP server normally requires restarting the local Codex client before its tools become available in a new task.
