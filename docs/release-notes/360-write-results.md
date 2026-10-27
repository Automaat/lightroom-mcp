# Compact write results

Write tools keep `success`, counts, missing IDs, created IDs, resolved identities,
SDK readbacks and warnings. They omit request echoes and count-only sentences.
Read results, write effects, arguments and errors stay the same.

| Tools | Result change |
| --- | --- |
| `create_collection`, `create_smart_collection` | Omit the creation sentence; keep the resolved `path`. |
| `add_to_collection`, `remove_from_collection` | Omit count-only `message`; keep membership and missing-ID counts. |
| `delete_collection` | Keep `photo_count`; `message` only reminds that photos stay in the catalog. |
| `set_keywords`, `remove_keyword_subtree` | Omit count-only `message`; keep updated/removed counts and missing IDs where provided. |
| `rename_keyword` | Omit the summary sentence; keep `old_path`, `new_path` and `photo_count`. |
| `set_rating`, `set_flag`, `set_color_label` | Omit `rating`, `flag` or `label` echoes and count-only `message`. |
| `set_gps` | Omit `latitude`, `longitude`, `altitude`, `altitude_cleared` and count-only `message`; keep `updated` and `missing`. |
| `set_location`, `set_metadata` | Omit count-only `message`; keep `updated`, `fields` and `missing`. |
| `import_photos` | Omit the imported-count sentence. Keep unsupported-extension notes, counts and unfinished paths. |
| `export_photos`, `export_photo_metadata` | Omit count-only `message`; keep the resolved destination and existing counts/missing or unfinished IDs. |
| `create_develop_preset` | Omit `source_photo_id` and `settings` echoes; keep the preset identity, file, visibility and checkpoint note. |
| `apply_develop_preset` | `message` contains only AI-update warnings or minimum-version guidance; keep the resolved preset identity and all outcome counts. |
| `copy_develop_settings` | Omit the `source` echo and count sentence; keep AI-update warnings/version guidance, counts and missing IDs. Dry-run results stay the same. |
| `apply_denoise` | Omit the requested `amount`; keep per-photo outcomes, counts, timing and Activity Center/retry guidance. |
| `set_process_version` | Omit the requested top-level `version`; keep each photo's actual `previous_version`/`new_version`, status, counts and retry IDs. |
| `create_mask_batch` | Omit requested `type`/`adjustments` and count sentence; keep per-photo outcomes, mask IDs, counts, timing and blocking-alert guidance. |

Use returned counts and IDs to handle outcomes. Read photo or mask metadata when
the workflow needs stored values; an echoed request was not a readback.
