# Named preview sizes

- `get_photo_preview` accepts `size: "cull"` (512) and `size: "detail"` (1024).
- Numeric sizes 64–2048, the default 512, reported dimensions, and existing preview limits stay unchanged. Batch previews still accept numeric sizes only.
- The tool description includes earlier approximate Claude token costs: about 650 tokens for culling and 2.5k for detail. Costs depend on the image and model and repeat while the image stays in conversation history.
- Live Lightroom Classic 15.6 measurement on the throwaway `arw_14bit` fixture: 512 returned 900×600 (266,376 bytes); 1024 returned 1800×1200 (1,070,011 bytes). Token costs were not remeasured.
