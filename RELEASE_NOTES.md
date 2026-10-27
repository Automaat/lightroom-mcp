# Unreleased

- The default tool list now contains only core catalog and metadata tools. Enable `LIGHTROOM_MCP_TOOLSETS=develop`, `masks`, `develop,masks`, or `all` in your MCP server environment to restore Develop or mask tools after upgrading. Desktop bundle users can set **Enabled toolsets**. Core is always enabled. Restart the server to apply a change; hidden tools are also refused when called. Develop includes `create_virtual_copies` and `summarize_develop_settings`.

- `get_mask` replaces `get_mask_adjustments`, `get_mask_curves` and `get_mask_point_colors`. Pass `photo_id` and `mask_id`; omit `kinds` to read all three in one Develop session, or select `adjustments`, `curves` and/or `point_colors`. Results contain `adjustments`, `curves`, `swatches` and per-kind `unavailable`; unsupported/unreadable kinds appear in `errors`, and a request with no readable kind fails. The set tools are unchanged.
- Write results omit request echoes and count-only messages while retaining counts, IDs, readbacks and actionable warnings. See [the changed tools and fields](docs/release-notes/360-write-results.md).
- `set_rating` and `set_flag` are replaced by `set_rating_and_flag`. Pass `photo_ids` and `rating`, `flag`, or both; both fields are saved in one write. Rating `0` clears stars and flag `"none"` clears the pick flag. Omitted fields stay unchanged. Results contain `success`, `updated` and `missing`.
- `set_rating_and_flag`, `get_photo_metadata` and the three mask creation tools publish plain object schemas for Claude Code. Rating-or-flag, exclusive single/batch photo selectors and the mask-id/creation-adjustments exclusion are enforced before dispatch; handlers, sections, geometry, sliders and results are unchanged.
- Readiness failures now return one short line with the cause and next action. Full port diagnoses remain in stderr logs.
- Invalid photo IDs now produce one type-validation clause. Handler errors omit the leading Lua source position; error conditions and accepted ID values are unchanged.

- `search_photos`, `get_selected_photos`, and `get_collection_photos` now omit `path` from default rows. Pass `include_path: true` to include it. Rows retain `id`, `filename`, `rating`, and `dateTimeOriginal`; use `id` with metadata and write tools. Photo IDs and file paths remain accepted as selectors. Pagination is unchanged.
- `list_collections` now omits `parent`. Its `name` remains the full collection path, such as `Trips / 2026 / Paris`, accepted as `collection_name` by collection tools.
- Shared Develop, guarded-mask and coordinate guidance now arrives once through MCP server instructions. Tool descriptions are shorter; tool schemas and results are unchanged.
- `list_develop_presets` now returns up to 100 presets by default. Use `limit` and `offset` to page through matches until `has_more` is false. `count` is the total after filtering, including when `limit` is 0.
- Narrow preset discovery with `query` (case-insensitive name substring) and `folder` (exact, case-sensitive folder name). Use `Plugin Develop Presets` for plugin checkpoints.
- Preset list rows now contain only `name`, `folder`, `scope` and `uuid`. Use `get_develop_preset` with `preset_uuid` to retrieve `file`. Other preset tool results and selectors are unchanged.
