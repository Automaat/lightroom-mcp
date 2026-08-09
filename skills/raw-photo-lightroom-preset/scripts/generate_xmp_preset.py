#!/usr/bin/env python3
"""Generate conservative Lightroom/Camera Raw XMP fallback presets safely."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any


X_NS = "adobe:ns:meta/"
RDF_NS = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
CRS_NS = "http://ns.adobe.com/camera-raw-settings/1.0/"

ET.register_namespace("x", X_NS)
ET.register_namespace("rdf", RDF_NS)
ET.register_namespace("crs", CRS_NS)

STYLE_CATALOG_PATH = Path(__file__).resolve().parent.parent / "references" / "styles.json"
IMAGE_EXTENSIONS = {
    ".nef", ".nrw", ".dng", ".cr2", ".cr3", ".arw", ".raf", ".rw2",
    ".orf", ".pef", ".srw", ".raw", ".jpg", ".jpeg", ".tif", ".tiff",
    ".png", ".heic", ".psd",
}


def number(kind: str, minimum: float, maximum: float) -> dict[str, Any]:
    return {"kind": kind, "min": minimum, "max": maximum}


FIELD_SPECS: dict[str, dict[str, Any]] = {
    "Profile": {"kind": "string"},
    "WhiteBalance": {"kind": "string"},
    "Temperature": number("float", 2000, 50000),
    "Tint": number("float", -150, 150),
    "Exposure2012": number("float", -5, 5),
    "Contrast2012": number("int", -100, 100),
    "Highlights2012": number("int", -100, 100),
    "Shadows2012": number("int", -100, 100),
    "Whites2012": number("int", -100, 100),
    "Blacks2012": number("int", -100, 100),
    "Texture": number("int", -100, 100),
    "Clarity2012": number("int", -100, 100),
    "Dehaze": number("int", -100, 100),
    "Vibrance": number("int", -100, 100),
    "Saturation": number("int", -100, 100),
    "ToneCurveName2012": {
        "kind": "enum",
        "choices": ["Linear", "Medium Contrast", "Strong Contrast", "Custom"],
    },
    "ToneCurvePV2012": {"kind": "curve"},
    "ToneCurvePV2012Red": {"kind": "curve"},
    "ToneCurvePV2012Green": {"kind": "curve"},
    "ToneCurvePV2012Blue": {"kind": "curve"},
    "ConvertToGrayscale": {"kind": "bool"},
    "Sharpness": number("int", 0, 150),
    "SharpenRadius": number("float", 0.5, 3.0),
    "SharpenDetail": number("int", 0, 100),
    "SharpenEdgeMasking": number("int", 0, 100),
    "LuminanceSmoothing": number("int", 0, 100),
    "LuminanceNoiseReductionDetail": number("int", 0, 100),
    "LuminanceNoiseReductionContrast": number("int", 0, 100),
    "ColorNoiseReduction": number("int", 0, 100),
    "ColorNoiseReductionDetail": number("int", 0, 100),
    "ColorNoiseReductionSmoothness": number("int", 0, 100),
    "LensProfileEnable": number("int", 0, 1),
    "RemoveChromaticAberration": {"kind": "bool"},
    "PostCropVignetteAmount": number("int", -100, 100),
    "PostCropVignetteMidpoint": number("int", 0, 100),
    "PostCropVignetteRoundness": number("int", -100, 100),
    "PostCropVignetteFeather": number("int", 0, 100),
    "GrainAmount": number("int", 0, 100),
    "GrainSize": number("int", 0, 100),
    "GrainFrequency": number("int", 0, 100),
}

for color in ("Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"):
    for prefix in ("HueAdjustment", "SaturationAdjustment", "LuminanceAdjustment"):
        FIELD_SPECS[f"{prefix}{color}"] = number("int", -100, 100)

for key in ("ParametricShadows", "ParametricDarks", "ParametricLights", "ParametricHighlights"):
    FIELD_SPECS[key] = number("int", -100, 100)
for key in ("ParametricShadowSplit", "ParametricMidtoneSplit", "ParametricHighlightSplit"):
    FIELD_SPECS[key] = number("int", 0, 100)
for key in ("ColorGradeShadowHue", "ColorGradeMidtoneHue", "ColorGradeHighlightHue"):
    FIELD_SPECS[key] = number("int", 0, 360)
for key in ("ColorGradeShadowSat", "ColorGradeMidtoneSat", "ColorGradeHighlightSat", "ColorGradeBlending"):
    FIELD_SPECS[key] = number("int", 0, 100)
FIELD_SPECS["ColorGradeBalance"] = number("int", -100, 100)


def qname(namespace: str, tag: str) -> str:
    return f"{{{namespace}}}{tag}"


def attr_name(name: str) -> str:
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", name):
        raise ValueError(f"Invalid Camera Raw setting name: {name}")
    return name


def validate_metadata(value: str, field: str, allow_unicode: bool) -> str:
    value = value.strip()
    if not value:
        raise ValueError(f"{field} must not be empty")
    if not allow_unicode:
        try:
            value.encode("ascii")
        except UnicodeEncodeError as exc:
            raise ValueError(
                f"{field} must be ASCII-safe unless --allow-unicode-metadata is used: {value!r}"
            ) from exc
    return value


def parse_bool(value: Any, key: str) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in {"true", "1", "yes"}:
            return True
        if lowered in {"false", "0", "no"}:
            return False
    raise ValueError(f"{key} expects a boolean")


def parse_curve(value: Any, key: str) -> list[str]:
    if isinstance(value, str):
        items: list[Any] = [part.strip() for part in value.split(";") if part.strip()]
    elif isinstance(value, list):
        items = value
    else:
        raise ValueError(f"{key} expects curve points such as 0,0;128,128;255,255")

    points: list[tuple[int, int]] = []
    for item in items:
        if isinstance(item, str):
            pieces = [part.strip() for part in item.split(",")]
        elif isinstance(item, list) and len(item) == 2:
            pieces = item
        else:
            raise ValueError(f"Invalid point in {key}: {item!r}")
        if len(pieces) != 2:
            raise ValueError(f"Invalid point in {key}: {item!r}")
        try:
            x = int(pieces[0])
            y = int(pieces[1])
        except (TypeError, ValueError) as exc:
            raise ValueError(f"Invalid point in {key}: {item!r}") from exc
        if not 0 <= x <= 255 or not 0 <= y <= 255:
            raise ValueError(f"{key} points must stay within 0..255")
        points.append((x, y))

    if len(points) < 2:
        raise ValueError(f"{key} requires at least two points")
    if points != sorted(points, key=lambda point: point[0]):
        raise ValueError(f"{key} x coordinates must be ordered")
    if len({x for x, _ in points}) != len(points):
        raise ValueError(f"{key} x coordinates must be unique")
    return [f"{x}, {y}" for x, y in points]


def validate_setting(key: str, value: Any) -> str | list[str]:
    spec = FIELD_SPECS.get(key)
    if spec is None:
        raise ValueError(f"Unsupported Camera Raw setting: {key}")
    kind = spec["kind"]

    if kind == "string":
        if not isinstance(value, str) or not value.strip():
            raise ValueError(f"{key} expects a non-empty string")
        return value.strip()
    if kind == "bool":
        return "True" if parse_bool(value, key) else "False"
    if kind == "enum":
        if not isinstance(value, str) or value not in spec["choices"]:
            raise ValueError(f"{key} expects one of: {', '.join(spec['choices'])}")
        return value
    if kind == "curve":
        return parse_curve(value, key)

    if isinstance(value, bool):
        raise ValueError(f"{key} expects a number")
    try:
        numeric = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{key} expects a number") from exc
    if kind == "int" and not numeric.is_integer():
        raise ValueError(f"{key} expects an integer")
    if not spec["min"] <= numeric <= spec["max"]:
        raise ValueError(f"{key} must be between {spec['min']} and {spec['max']}")
    if kind == "int":
        return str(int(numeric))
    if key == "SharpenRadius":
        return f"{numeric:.1f}"
    return format(numeric, ".12g")


def load_catalog(path: Path = STYLE_CATALOG_PATH) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schema_version") != 2:
        raise ValueError("styles.json must use schema_version 2")
    if not isinstance(data.get("base_attrs"), dict):
        raise ValueError("styles.json base_attrs must be an object")
    if not isinstance(data.get("styles"), dict) or not data["styles"]:
        raise ValueError("styles.json must define at least one style")
    if not isinstance(data.get("modifiers", {}), dict):
        raise ValueError("styles.json modifiers must be an object")

    for collection_name in ("styles", "modifiers"):
        for item_id, item in data.get(collection_name, {}).items():
            if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", item_id):
                raise ValueError(f"Invalid {collection_name} id: {item_id}")
            if not isinstance(item, dict) or not isinstance(item.get("settings"), dict):
                raise ValueError(f"{collection_name}.{item_id}.settings must be an object")
            for key, value in item["settings"].items():
                attr_name(key)
                validate_setting(key, value)
    return data


def parse_assignments(values: list[str], unsafe: bool = False) -> dict[str, Any]:
    parsed: dict[str, Any] = {}
    for item in values:
        if "=" not in item:
            raise ValueError(f"override expects KEY=VALUE, got {item!r}")
        raw_key, raw_value = item.split("=", 1)
        key = attr_name(raw_key.strip())
        if key in parsed:
            raise ValueError(f"Duplicate override for {key}")
        value = raw_value.strip()
        if not value:
            raise ValueError(f"{key} must not be empty")
        if unsafe:
            if key in FIELD_SPECS:
                raise ValueError(f"{key} is known; use --set so it is validated")
            parsed[key] = value
        else:
            parsed[key] = validate_setting(key, value)
    return parsed


def render_alt(parent: ET.Element, tag: str, value: str) -> None:
    node = ET.SubElement(parent, qname(CRS_NS, tag))
    alt = ET.SubElement(node, qname(RDF_NS, "Alt"))
    item = ET.SubElement(alt, qname(RDF_NS, "li"))
    item.set(qname("http://www.w3.org/XML/1998/namespace", "lang"), "x-default")
    item.text = value


def render_curve(parent: ET.Element, key: str, points: list[str]) -> None:
    node = ET.SubElement(parent, qname(CRS_NS, key))
    sequence = ET.SubElement(node, qname(RDF_NS, "Seq"))
    for point in points:
        item = ET.SubElement(sequence, qname(RDF_NS, "li"))
        item.text = point


def render_xmp(
    catalog: dict[str, Any],
    style: str,
    name: str,
    group: str,
    modifiers: list[str] | None = None,
    overrides: dict[str, Any] | None = None,
    unsafe_overrides: dict[str, str] | None = None,
) -> str:
    if style not in catalog["styles"]:
        raise ValueError(f"Unknown style: {style}")
    modifiers = modifiers or []
    if len(set(modifiers)) != len(modifiers):
        raise ValueError("Duplicate modifiers are not allowed")

    settings: dict[str, Any] = {}
    for key, value in catalog["styles"][style]["settings"].items():
        settings[key] = validate_setting(key, value)
    for modifier in modifiers:
        if modifier not in catalog.get("modifiers", {}):
            raise ValueError(f"Unknown modifier: {modifier}")
        for key, value in catalog["modifiers"][modifier]["settings"].items():
            settings[key] = validate_setting(key, value)
    settings.update(overrides or {})
    settings.update(unsafe_overrides or {})

    attrs: dict[str, str] = {key: str(value) for key, value in catalog["base_attrs"].items()}
    curves: dict[str, list[str]] = {}
    for key, value in settings.items():
        if isinstance(value, list):
            curves[key] = value
        else:
            attrs[key] = str(value)
    attrs["Cluster"] = group
    attrs["UUID"] = str(uuid.uuid4()).upper()

    root = ET.Element(qname(X_NS, "xmpmeta"), {qname(X_NS, "xmptk"): "Adobe XMP Core"})
    rdf = ET.SubElement(root, qname(RDF_NS, "RDF"))
    description = ET.SubElement(rdf, qname(RDF_NS, "Description"))
    description.set(qname(RDF_NS, "about"), "")
    for key, value in attrs.items():
        description.set(qname(CRS_NS, attr_name(key)), value)
    for key, points in curves.items():
        render_curve(description, key, points)

    render_alt(description, "Name", name)
    render_alt(description, "ShortName", name[:32])
    render_alt(description, "SortName", f"{style} {name}")
    render_alt(description, "Group", group)
    ET.indent(root, space=" ")
    return ET.tostring(root, encoding="unicode", short_empty_elements=True) + "\n"


def looks_like_photo_sidecar(path: Path) -> Path | None:
    if not path.parent.exists():
        return None
    target_stem = path.stem.casefold()
    for sibling in path.parent.iterdir():
        if sibling.stem.casefold() == target_stem and sibling.suffix.casefold() in IMAGE_EXTENSIONS:
            return sibling
    return None


def validate_output_path(path: Path, force: bool) -> None:
    if path.suffix.lower() != ".xmp":
        raise ValueError("output must use the .xmp extension")
    if path.is_symlink():
        raise ValueError("refusing to overwrite a symbolic-link output")
    if path.exists() and path.is_dir():
        raise ValueError("output path is a directory")
    sidecar_for = looks_like_photo_sidecar(path)
    if sidecar_for is not None:
        raise ValueError(f"refusing photo sidecar path; matching image exists: {sidecar_for.name}")
    if path.exists() and not force:
        raise ValueError("output already exists; pass --force to replace this .xmp preset")


def atomic_write(path: Path, content: str, force: bool = False) -> None:
    validate_output_path(path, force)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="\n",
            delete=False,
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
        ) as handle:
            temporary = Path(handle.name)
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def build_parser(catalog: dict[str, Any]) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list-styles", action="store_true", help="Print base style ids and exit.")
    parser.add_argument("--list-modifiers", action="store_true", help="Print modifier ids and exit.")
    parser.add_argument("--schema-info", action="store_true", help="Print style schema target information and exit.")
    parser.add_argument("--style", choices=sorted(catalog["styles"]), help="Base style to render.")
    parser.add_argument(
        "--modifier",
        action="append",
        default=[],
        choices=sorted(catalog.get("modifiers", {})),
        help="Technical modifier; repeat when needed.",
    )
    parser.add_argument("--name", help="Lightroom preset name.")
    parser.add_argument("--group", default="Codex RAW Starting Presets", help="Lightroom preset group.")
    parser.add_argument("--output", type=Path, help="Output .xmp path.")
    parser.add_argument("--force", action="store_true", help="Replace an existing non-sidecar .xmp preset.")
    parser.add_argument("--dry-run", action="store_true", help="Print XMP without writing a file.")
    parser.add_argument("--allow-unicode-metadata", action="store_true", help="Allow Unicode preset name/group.")
    parser.add_argument("--set", action="append", default=[], metavar="KEY=VALUE", help="Validated override.")
    parser.add_argument(
        "--unsafe-set",
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help="Unvalidated research-only override for unknown keys.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    try:
        catalog = load_catalog()
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"error: unable to load style catalog: {exc}", file=sys.stderr)
        return 2

    parser = build_parser(catalog)
    args = parser.parse_args(argv)

    if args.list_styles:
        print("\n".join(sorted(catalog["styles"])))
        return 0
    if args.list_modifiers:
        print("\n".join(sorted(catalog.get("modifiers", {}))))
        return 0
    if args.schema_info:
        print(json.dumps(catalog["tested_target"], ensure_ascii=False, indent=2))
        return 0
    if not args.style or not args.name:
        parser.error("--style and --name are required for generation")
    if not args.dry_run and args.output is None:
        parser.error("--output is required unless --dry-run is used")

    try:
        name = validate_metadata(args.name, "name", args.allow_unicode_metadata)
        group = validate_metadata(args.group, "group", args.allow_unicode_metadata)
        overrides = parse_assignments(args.set)
        unsafe_overrides = parse_assignments(args.unsafe_set, unsafe=True)
        overlap = set(overrides).intersection(unsafe_overrides)
        if overlap:
            raise ValueError(f"Duplicate safe/unsafe override: {', '.join(sorted(overlap))}")
        xmp = render_xmp(
            catalog,
            args.style,
            name,
            group,
            args.modifier,
            overrides,
            unsafe_overrides,
        )
        if args.dry_run:
            print(xmp, end="")
        else:
            atomic_write(args.output, xmp, force=args.force)
            print(args.output)
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
