# John's Intent-Based Style Library v2

Treat styles as visual goals. Derive per-photo settings from Lightroom-rendered feedback and user-approved references. The numeric values in `styles.json` are conservative fallback settings, not the definition of the style.

## Reference manifest

Keep reference files outside the skill and record them in the current project with relative paths:

```yaml
style_id: john-outdoor-documentary
references:
  - relative_path: references/john_ref_001.jpg
    source_raw: RAW/DSC_0001.NEF
    renderer: Lightroom Classic 15.5
    approved: true
goals:
  skin: natural and restrained
  greens: slightly muted and not yellow
  highlights: soft roll-off
  shadows: open with a subtle cool bias
  contrast: medium
```

Do not hard-code machine-specific `D:\photo\...` paths in the reusable skill.

## Base styles

### `neutral-natural`

- Intent: technically clean, low-drama baseline for mixed subject matter.
- Preserve: believable neutrals, natural skin, recoverable highlights.
- Avoid for: a user-requested stylized or high-contrast delivery.

### `graduation-bright-natural`

- Intent: clean event delivery with gentle microcontrast and controlled greens/yellows.
- Preserve: faces, white clothing, certificates, and highlight detail.
- Avoid for: dramatic stage frames, severe backlight, or high-ISO scenes without a modifier.

### `graduation-documentary`

- Intent: stronger dimensional event coverage without harsh skin or crushed black clothing.
- Preserve: scene depth and documentary atmosphere.
- Avoid for: soft close-up portraits or frames with blocked shadows.

### `warm-cosplay-portrait`

- Intent: warm subject separation with restrained orange skin and subdued foliage.
- Preserve: face exposure and costume color identity.
- Avoid for: neutral documentation and mixed-light interiors.

### `dramatic-fine-art`

- Intent: deeper tonal structure and selective color emphasis for details, flowers, reflections, or competition images.
- Preserve: highlight texture and intentional color accents.
- Avoid for: batch event delivery and skin-critical groups.

## Technical modifiers

### `low-light-noise-controlled`

Use with a base style for high-ISO stage, night, aquarium, or indoor event files. Evaluate noise at 100%, reduce over-sharpening, and keep AI Denoise as a manual recommendation. Prefer an ISO-adaptive preset created by Lightroom when the shoot spans multiple ISO values.

## Matching procedure

1. Ask for or identify approved reference images.
2. Compare target and reference for WB, skin, foliage, sky, neutral objects, highlight roll-off, shadow openness, and global contrast.
3. Select one base style and zero or more technical modifiers per lighting cluster.
4. Adjust the representative RAW through the five-pass workflow.
5. Save the accepted intent and references; do not promote one frame's slider values into a permanent style definition without repeated evidence.
