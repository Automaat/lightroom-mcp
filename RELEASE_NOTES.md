# Unreleased

- `search_photos`, `get_selected_photos`, and `get_collection_photos` now omit `path` from default rows. Pass `include_path: true` to include it. Rows retain `id`, `filename`, `rating`, and `dateTimeOriginal`; use `id` with metadata and write tools. Photo IDs and file paths remain accepted as selectors. Pagination is unchanged.
- `list_collections` now omits `parent`. Its `name` remains the full collection path, such as `Trips / 2026 / Paris`, accepted as `collection_name` by collection tools.
