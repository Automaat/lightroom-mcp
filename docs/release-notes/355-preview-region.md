# Preview a region

`get_photo_preview` accepts an optional `region`:

```json
{
  "photo_id": 914,
  "region": { "x": 0.2, "y": 0.1, "width": 0.25, "height": 0.25 }
}
```

Coordinates are normalized to the rendered preview after Lightroom applies
develop crop and rotation. The origin is top-left; x increases right and y
increases down. The rectangle must fit inside the frame. Pixel bounds round
outward, so a positive region returns at least one pixel in each direction.

For regions, the server increases the requested source size by dividing `size`
(default 512) by the region's longest normalized side, capped at 2048. Lightroom
can return a smaller source to meet its preview limits. `requested_size` reports
the source request; `width`, `height` and `bytes` report the cropped JPEG. The
server encodes it at quality 90, lowering quality only to keep it within 3.5 MiB.
The longest edge stays at most 2000 pixels.

Calls without `region` retain their existing arguments, metadata and JPEG bytes.
Batch previews are unchanged. No runtime dependency is added.
