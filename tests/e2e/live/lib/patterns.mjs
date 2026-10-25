export const ORIENTATIONS = [1, 2, 3, 4, 5, 6, 7, 8];

export const CORNER_COLORS = {
  topLeft: [220, 40, 40],
  topRight: [40, 200, 60],
  bottomLeft: [50, 80, 230],
  bottomRight: [240, 210, 40],
};

const ORIENTATION_BACKGROUND = [90, 90, 90];
const ORIENTATION_GLYPH = [245, 245, 245];

export function createCanvas(width, height, fill = [0, 0, 0]) {
  const rgb = new Uint8Array(width * height * 3);
  for (let i = 0; i < rgb.length; i += 3) rgb.set(fill, i);
  return { width, height, rgb };
}

export function fillRect(canvas, x, y, width, height, color) {
  const x0 = Math.max(0, Math.round(x));
  const y0 = Math.max(0, Math.round(y));
  const x1 = Math.min(canvas.width, Math.round(x + width));
  const y1 = Math.min(canvas.height, Math.round(y + height));
  for (let py = y0; py < y1; py++) {
    for (let px = x0; px < x1; px++) canvas.rgb.set(color, (py * canvas.width + px) * 3);
  }
}

export function pixelAt(canvas, x, y) {
  const i = (y * canvas.width + x) * 3;
  return [canvas.rgb[i], canvas.rgb[i + 1], canvas.rgb[i + 2]];
}

export function createRng(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function hsvToRgb(hueDegrees, saturation, value) {
  const hue = (((hueDegrees % 360) + 360) % 360) / 60;
  const sector = Math.floor(hue);
  const fraction = hue - sector;
  const p = value * (1 - saturation);
  const q = value * (1 - saturation * fraction);
  const t = value * (1 - saturation * (1 - fraction));
  const [r, g, b] = [
    [value, t, p],
    [q, value, p],
    [p, value, t],
    [p, q, value],
    [t, p, value],
    [value, p, q],
  ][sector % 6];
  return [Math.round(r * 255), Math.round(g * 255), Math.round(b * 255)];
}

export function displayedSize(width, height, orientation) {
  return orientation >= 5 ? { width: height, height: width } : { width, height };
}

function storedCoordinate(orientation, dx, dy, width, height) {
  switch (orientation) {
    case 1:
      return [dx, dy];
    case 2:
      return [width - 1 - dx, dy];
    case 3:
      return [width - 1 - dx, height - 1 - dy];
    case 4:
      return [dx, height - 1 - dy];
    case 5:
      return [dy, dx];
    case 6:
      return [dy, height - 1 - dx];
    case 7:
      return [width - 1 - dy, height - 1 - dx];
    case 8:
      return [width - 1 - dy, dx];
    default:
      throw new Error(`orientation must be 1..8, got ${orientation}`);
  }
}

export function applyOrientation(canvas, orientation) {
  const size = displayedSize(canvas.width, canvas.height, orientation);
  const displayed = createCanvas(size.width, size.height);
  for (let dy = 0; dy < size.height; dy++) {
    for (let dx = 0; dx < size.width; dx++) {
      const [sx, sy] = storedCoordinate(orientation, dx, dy, canvas.width, canvas.height);
      displayed.rgb.set(pixelAt(canvas, sx, sy), (dy * size.width + dx) * 3);
    }
  }
  return displayed;
}

export function buildOrientationPattern(width = 1000, height = 600) {
  const canvas = createCanvas(width, height, ORIENTATION_BACKGROUND);
  const square = Math.round(Math.min(width, height) * 0.2);
  fillRect(canvas, 0, 0, square, square, CORNER_COLORS.topLeft);
  fillRect(canvas, width - square, 0, square, square, CORNER_COLORS.topRight);
  fillRect(canvas, 0, height - square, square, square, CORNER_COLORS.bottomLeft);
  fillRect(canvas, width - square, height - square, square, square, CORNER_COLORS.bottomRight);
  fillRect(canvas, width * 0.3, height * 0.2, width * 0.08, height * 0.6, ORIENTATION_GLYPH);
  fillRect(canvas, width * 0.3, height * 0.2, width * 0.28, height * 0.1, ORIENTATION_GLYPH);
  fillRect(canvas, width * 0.3, height * 0.45, width * 0.2, height * 0.09, ORIENTATION_GLYPH);
  return canvas;
}

export function expectedDisplayedCorners(orientation) {
  const storedCorners = createCanvas(2, 2);
  storedCorners.rgb.set(CORNER_COLORS.topLeft, 0);
  storedCorners.rgb.set(CORNER_COLORS.topRight, 3);
  storedCorners.rgb.set(CORNER_COLORS.bottomLeft, 6);
  storedCorners.rgb.set(CORNER_COLORS.bottomRight, 9);
  const displayed = applyOrientation(storedCorners, orientation);
  return {
    topLeft: pixelAt(displayed, 0, 0),
    topRight: pixelAt(displayed, 1, 0),
    bottomLeft: pixelAt(displayed, 0, 1),
    bottomRight: pixelAt(displayed, 1, 1),
  };
}

function colorDistance(a, b) {
  return Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
}

export function classifyOrientation(sampledCorners) {
  const ranked = ORIENTATIONS.map((orientation) => {
    const expected = expectedDisplayedCorners(orientation);
    const distance = Object.keys(expected).reduce(
      (sum, corner) => sum + colorDistance(expected[corner], sampledCorners[corner]),
      0,
    );
    return { orientation, distance };
  }).sort((a, b) => a.distance - b.distance);
  return { orientation: ranked[0].orientation, distance: ranked[0].distance, runnerUpDistance: ranked[1].distance };
}

export function sampleCorners(pixels, insetFraction = 0.04) {
  const at = (fx, fy) => {
    const cx = Math.round(fx * (pixels.w - 1));
    const cy = Math.round(fy * (pixels.h - 1));
    let r = 0;
    let g = 0;
    let b = 0;
    let n = 0;
    for (let y = Math.max(0, cy - 1); y <= Math.min(pixels.h - 1, cy + 1); y++) {
      for (let x = Math.max(0, cx - 1); x <= Math.min(pixels.w - 1, cx + 1); x++) {
        const i = y * pixels.w + x;
        r += pixels.R[i];
        g += pixels.G[i];
        b += pixels.B[i];
        n++;
      }
    }
    return [(r / n) * 255, (g / n) * 255, (b / n) * 255];
  };
  return {
    topLeft: at(insetFraction, insetFraction),
    topRight: at(1 - insetFraction, insetFraction),
    bottomLeft: at(insetFraction, 1 - insetFraction),
    bottomRight: at(1 - insetFraction, 1 - insetFraction),
  };
}

const CHART80_HUE_COUNT = 12;
const CHART80_HUE_STEP_DEGREES = 30;
const CHART80_HSV_VARIANTS = [
  [1, 1],
  [0.6, 1],
  [1, 0.6],
  [0.35, 0.85],
  [0.6, 0.4],
  [0.25, 0.55],
];
const CHART80_GRAY_COUNT = 8;
const CHART80_GRAY_FIRST = 16;
const CHART80_GRAY_LAST = 240;

export const CHART80_LAYOUT = { columns: 10, rows: 8, patchSize: 100 };
export const RAMP256_LAYOUT = { columns: 16, rows: 16, patchSize: 64 };

export function chart80Patches() {
  const colorPatches = CHART80_HSV_VARIANTS.flatMap(([saturation, value]) =>
    Array.from({ length: CHART80_HUE_COUNT }, (_, hue) =>
      hsvToRgb(hue * CHART80_HUE_STEP_DEGREES, saturation, value),
    ),
  );
  const grayPatches = Array.from({ length: CHART80_GRAY_COUNT }, (_, i) => {
    const level = Math.round(
      CHART80_GRAY_FIRST + (i * (CHART80_GRAY_LAST - CHART80_GRAY_FIRST)) / (CHART80_GRAY_COUNT - 1),
    );
    return [level, level, level];
  });
  return [...colorPatches, ...grayPatches];
}

export function ramp256Patches() {
  return Array.from({ length: 256 }, (_, level) => [level, level, level]);
}

function paintPatchGrid(layout, patches) {
  const canvas = createCanvas(layout.columns * layout.patchSize, layout.rows * layout.patchSize);
  patches.forEach((color, index) => {
    const column = index % layout.columns;
    const row = Math.floor(index / layout.columns);
    fillRect(canvas, column * layout.patchSize, row * layout.patchSize, layout.patchSize, layout.patchSize, color);
  });
  return canvas;
}

export function buildChart80() {
  return paintPatchGrid(CHART80_LAYOUT, chart80Patches());
}

export function buildRamp256() {
  return paintPatchGrid(RAMP256_LAYOUT, ramp256Patches());
}

export function patchCenterFraction(layout, index) {
  const column = index % layout.columns;
  const row = Math.floor(index / layout.columns);
  return { x: (column + 0.5) / layout.columns, y: (row + 0.5) / layout.rows };
}

const WIDE_PLAIN_LEVEL = 110;
const WIDE_PLAIN_NOISE = 2;

export function buildWidePlain(width = 1000, height = 600, seed = 1) {
  const canvas = createCanvas(width, height);
  const random = createRng(seed);
  for (let i = 0; i < canvas.rgb.length; i += 3) {
    const level = WIDE_PLAIN_LEVEL + Math.round((random() * 2 - 1) * WIDE_PLAIN_NOISE);
    canvas.rgb[i] = level;
    canvas.rgb[i + 1] = level;
    canvas.rgb[i + 2] = level;
  }
  return canvas;
}

export function buildPano(width = 2400, height = 240) {
  const canvas = createCanvas(width, height);
  const rampHeight = Math.round(height * 0.2);
  for (let x = 0; x < width; x++) {
    const hue = hsvToRgb((x / width) * 360, 0.55, 0.75);
    const level = Math.round((x / (width - 1)) * 255);
    for (let y = 0; y < height; y++) {
      canvas.rgb.set(y < height - rampHeight ? hue : [level, level, level], (y * width + x) * 3);
    }
  }
  return canvas;
}
