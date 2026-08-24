from __future__ import annotations

import hashlib
import importlib.util
import tempfile
import unittest
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path


SKILL_DIR = Path(__file__).resolve().parents[1]
SCRIPT_PATH = SKILL_DIR / "scripts" / "generate_xmp_preset.py"
SPEC = importlib.util.spec_from_file_location("generate_xmp_preset", SCRIPT_PATH)
assert SPEC and SPEC.loader
GEN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GEN)

CRS = "http://ns.adobe.com/camera-raw-settings/1.0/"
RDF = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"


class GeneratorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.catalog = GEN.load_catalog()

    def render(self, style: str = "neutral-natural", **kwargs: object) -> str:
        return GEN.render_xmp(
            self.catalog,
            style,
            "Test Preset",
            "Codex Test",
            **kwargs,
        )

    def test_all_styles_generate_and_parse(self) -> None:
        for style in self.catalog["styles"]:
            ET.fromstring(self.render(style))

    def test_uuid_is_valid_and_unique(self) -> None:
        first = ET.fromstring(self.render())
        second = ET.fromstring(self.render())
        key = f"{{{CRS}}}UUID"
        first_id = next(first.iter(f"{{{RDF}}}Description")).attrib[key]
        second_id = next(second.iter(f"{{{RDF}}}Description")).attrib[key]
        self.assertNotEqual(first_id, second_id)
        uuid.UUID(first_id)
        uuid.UUID(second_id)

    def test_xml_escapes_metadata(self) -> None:
        xml = GEN.render_xmp(self.catalog, "neutral-natural", "A & B <Test>", "G & G")
        root = ET.fromstring(xml)
        name = root.find(f".//{{{CRS}}}Name/{{{RDF}}}Alt/{{{RDF}}}li")
        self.assertEqual(name.text, "A & B <Test>")

    def test_defaults_do_not_reset_profile_wb_or_lens(self) -> None:
        root = ET.fromstring(self.render())
        attrs = next(root.iter(f"{{{RDF}}}Description")).attrib
        for key in ("Profile", "WhiteBalance", "LensProfileEnable", "RemoveChromaticAberration"):
            self.assertNotIn(f"{{{CRS}}}{key}", attrs)

    def test_unknown_key_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "Unsupported"):
            GEN.parse_assignments(["TotallyMadeUpSetting=999"])

    def test_invalid_numeric_type_and_range_are_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "expects a number"):
            GEN.parse_assignments(["Exposure2012=abc"])
        with self.assertRaisesRegex(ValueError, "between"):
            GEN.parse_assignments(["HueAdjustmentOrange=900"])

    def test_duplicate_override_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            GEN.parse_assignments(["Exposure2012=0.2", "Exposure2012=0.3"])

    def test_tone_curve_uses_rdf_sequence(self) -> None:
        overrides = GEN.parse_assignments(["ToneCurvePV2012=0,0;128,126;255,255"])
        root = ET.fromstring(self.render(overrides=overrides))
        points = root.findall(
            f".//{{{CRS}}}ToneCurvePV2012/{{{RDF}}}Seq/{{{RDF}}}li"
        )
        self.assertEqual([point.text for point in points], ["0, 0", "128, 126", "255, 255"])
        description = next(root.iter(f"{{{RDF}}}Description"))
        self.assertNotIn(f"{{{CRS}}}ToneCurvePV2012", description.attrib)

    def test_unicode_metadata_requires_opt_in(self) -> None:
        with self.assertRaisesRegex(ValueError, "ASCII-safe"):
            GEN.validate_metadata("畢業典禮", "name", allow_unicode=False)
        self.assertEqual(
            GEN.validate_metadata("畢業典禮", "name", allow_unicode=True),
            "畢業典禮",
        )

    def test_output_must_be_xmp_and_original_hash_is_unchanged(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            raw = Path(temp) / "DSC_0001.NEF"
            raw.write_bytes(b"fake raw bytes")
            before = hashlib.sha256(raw.read_bytes()).hexdigest()
            with self.assertRaisesRegex(ValueError, r"\.xmp"):
                GEN.atomic_write(raw, self.render())
            after = hashlib.sha256(raw.read_bytes()).hexdigest()
            self.assertEqual(before, after)

    def test_existing_output_requires_force(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "preset.xmp"
            output.write_text("old", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "already exists"):
                GEN.atomic_write(output, self.render())
            self.assertEqual(output.read_text(encoding="utf-8"), "old")
            GEN.atomic_write(output, self.render(), force=True)
            ET.fromstring(output.read_text(encoding="utf-8"))

    def test_force_still_refuses_photo_sidecar(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            raw = Path(temp) / "DSC_0001.NEF"
            sidecar = Path(temp) / "DSC_0001.xmp"
            raw.write_bytes(b"raw")
            sidecar.write_text("existing sidecar", encoding="utf-8")
            before = hashlib.sha256(sidecar.read_bytes()).hexdigest()
            with self.assertRaisesRegex(ValueError, "sidecar"):
                GEN.atomic_write(sidecar, self.render(), force=True)
            self.assertEqual(before, hashlib.sha256(sidecar.read_bytes()).hexdigest())

    def test_force_refuses_full_name_sidecar(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            raw = Path(temp) / "DSC_0001.NEF"
            sidecar = Path(temp) / "DSC_0001.NEF.xmp"
            raw.write_bytes(b"raw")
            sidecar.write_text("existing sidecar", encoding="utf-8")
            before = hashlib.sha256(sidecar.read_bytes()).hexdigest()
            with self.assertRaisesRegex(ValueError, "sidecar"):
                GEN.atomic_write(sidecar, self.render(), force=True)
            self.assertEqual(before, hashlib.sha256(sidecar.read_bytes()).hexdigest())

    def test_force_refuses_sidecar_for_less_common_raw_extensions(self) -> None:
        for extension in (".crw", ".mrw", ".rwl", ".sr2", ".x3f", ".gpr"):
            with tempfile.TemporaryDirectory() as temp:
                raw = Path(temp) / f"IMG_1{extension}"
                sidecar = Path(temp) / "IMG_1.xmp"
                raw.write_bytes(b"raw")
                sidecar.write_text("existing sidecar", encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "sidecar"):
                    GEN.atomic_write(sidecar, self.render(), force=True)
                self.assertEqual(sidecar.read_text(encoding="utf-8"), "existing sidecar")

    def test_force_refuses_symlinked_output(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / "real.xmp"
            target.write_text("original", encoding="utf-8")
            link = Path(temp) / "link.xmp"
            link.symlink_to(target)
            with self.assertRaisesRegex(ValueError, "symbolic-link"):
                GEN.atomic_write(link, self.render(), force=True)
            self.assertEqual(target.read_text(encoding="utf-8"), "original")

    def test_control_characters_are_rejected(self) -> None:
        for field in ("name", "group"):
            with self.assertRaisesRegex(ValueError, "control characters"):
                GEN.validate_metadata("Bad\x01Name", field, False)
            with self.assertRaisesRegex(ValueError, "control characters"):
                GEN.validate_metadata("Bad\x01Name", field, True)

    def test_grayscale_preset_declares_a_monochrome_treatment(self) -> None:
        root = ET.fromstring(self.render(overrides={"ConvertToGrayscale": "True"}))
        description = root.find(f"{{{RDF}}}RDF/{{{RDF}}}Description")
        assert description is not None
        self.assertEqual(description.get(f"{{{CRS}}}ConvertToGrayscale"), "True")
        self.assertEqual(description.get(f"{{{CRS}}}Treatment"), "Black & White")
        self.assertEqual(description.get(f"{{{CRS}}}SupportsMonochrome"), "True")
        self.assertEqual(description.get(f"{{{CRS}}}SupportsColor"), "False")

    def test_colour_preset_keeps_the_colour_treatment(self) -> None:
        root = ET.fromstring(self.render())
        description = root.find(f"{{{RDF}}}RDF/{{{RDF}}}Description")
        assert description is not None
        self.assertEqual(description.get(f"{{{CRS}}}Treatment"), "Color")
        self.assertEqual(description.get(f"{{{CRS}}}SupportsMonochrome"), "False")

    def test_sidecar_detection_is_case_insensitive(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            raw = Path(temp) / "DSC_0002.NEF"
            raw.write_bytes(b"raw")
            sidecar = Path(temp) / "dsc_0002.xmp"
            with self.assertRaisesRegex(ValueError, "sidecar"):
                GEN.atomic_write(sidecar, self.render())

    def test_modifier_is_composable(self) -> None:
        root = ET.fromstring(
            self.render(
                style="graduation-documentary",
                modifiers=["low-light-noise-controlled"],
            )
        )
        attrs = next(root.iter(f"{{{RDF}}}Description")).attrib
        self.assertEqual(attrs[f"{{{CRS}}}LuminanceSmoothing"], "15")
        self.assertEqual(attrs[f"{{{CRS}}}Contrast2012"], "12")
        self.assertEqual(attrs[f"{{{CRS}}}SharpenRadius"], "1.0")


if __name__ == "__main__":
    unittest.main()
