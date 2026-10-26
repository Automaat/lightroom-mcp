`get_photo_metadata` now accepts `photo_ids` to read up to 100 photos inline in one call. Use either `photo_id` or `photo_ids`, never both.

Batch results contain `photos` in request order and a `missing` list of unresolved identifiers. IDs and file paths can be mixed; repeated identifiers return repeated entries. The existing `sections` option applies to every photo in the batch. Single-photo responses stay unchanged.
