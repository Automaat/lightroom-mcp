# Adjustments when creating masks

`create_gradient_mask`, `create_brush_mask` and `create_range_mask` accept an
optional, non-empty `adjustments` object. It uses the same unprefixed slider
names as `create_mask`, for example `"adjustments": {"exposure": 1}`.

The create call writes the geometry and sliders together, confirms the slider
values in Develop, and restores the previous masks if either check fails.
It uses one Develop session. Calls without `adjustments` keep their behavior.

`adjustments` cannot be combined with `mask_id`: adding a component must
preserve that existing mask's sliders. Unknown sliders and out-of-range
values fail validation. The Lightroom 15.6 and process-version 15.4 limits
remain unchanged.
