# Unreleased

- `delete_empty_masks` is removed. Use `delete_masks` with only `photo_ids` to delete empty masks on up to 1000 photos (LrC 14+), preserving module and selection. Existing `photo_id` calls with `mask_ids`, `tool_ids` or `all` keep their behavior (LrC 11+). The two forms cannot be mixed; each retains its result fields.
- `search_photos`, `get_selected_photos`, and `get_collection_photos` now omit `path` from default rows. Pass `include_path: true` to include it. Rows retain `id`, `filename`, `rating`, and `dateTimeOriginal`; use `id` with metadata and write tools. Photo IDs and file paths remain accepted as selectors. Pagination is unchanged.
- `list_collections` now omits `parent`. Its `name` remains the full collection path, such as `Trips / 2026 / Paris`, accepted as `collection_name` by collection tools.
- Shared Develop, guarded-mask and coordinate guidance now arrives once through MCP server instructions. Tool descriptions are shorter; tool schemas and results are unchanged.
- `list_develop_presets` now returns up to 100 presets by default. Use `limit` and `offset` to page through matches until `has_more` is false. `count` is the total after filtering, including when `limit` is 0.
- Narrow preset discovery with `query` (case-insensitive name substring) and `folder` (exact, case-sensitive folder name). Use `Plugin Develop Presets` for plugin checkpoints.
- Preset list rows now contain only `name`, `folder`, `scope` and `uuid`. Use `get_develop_preset` with `preset_uuid` to retrieve `file`. Other preset tool results and selectors are unchanged.
