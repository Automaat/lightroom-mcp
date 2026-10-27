# Unreleased

- Readiness failures now return one short line with the cause and next action. Full port diagnoses remain in stderr logs.
- Invalid photo IDs now produce one type-validation clause. Handler errors omit the leading Lua source position; error conditions and accepted ID values are unchanged.

- `list_develop_presets` now returns up to 100 presets by default. Use `limit` and `offset` to page through matches until `has_more` is false. `count` is the total after filtering, including when `limit` is 0.
- Narrow preset discovery with `query` (case-insensitive name substring) and `folder` (exact, case-sensitive folder name). Use `Plugin Develop Presets` for plugin checkpoints.
- Preset list rows now contain only `name`, `folder`, `scope` and `uuid`. Use `get_develop_preset` with `preset_uuid` to retrieve `file`. Other preset tool results and selectors are unchanged.
