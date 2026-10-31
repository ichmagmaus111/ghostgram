#!/usr/bin/env python3
"""Tests of generate.py and check.py on small fixture trees.

    python3 Ghostgram/Strings/tests/test_tools.py
"""

import json
import os
import shutil
import sys
import tempfile
import unittest

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, TOOLS)

import check  # noqa: E402
import generate  # noqa: E402
import strings_model  # noqa: E402


class Fixture:
    """Ghostgram/{Strings,GGCore/Sources/Strings/Generated,Code} in a temporary directory."""

    def __init__(self):
        self.base = tempfile.mkdtemp(prefix="gg-strings-")
        self.root = os.path.join(self.base, "Strings")
        self.generated = os.path.join(self.base, "GGCore", "Sources", "Strings", "Generated")
        self.code = os.path.join(self.base, "Code")
        os.makedirs(self.root)
        os.makedirs(self.code)

    def write_table(self, language, namespace, table):
        directory = os.path.join(self.root, language)
        os.makedirs(directory, exist_ok=True)
        with open(os.path.join(directory, namespace + ".json"), "w", encoding="utf-8") as handle:
            json.dump(table, handle, ensure_ascii=False)

    def write_code(self, name, text):
        with open(os.path.join(self.code, name), "w", encoding="utf-8") as handle:
            handle.write(text)

    def generate(self):
        diagnostics, _ = generate.generate(self.root, self.generated)
        return diagnostics

    def check(self, strict=False, allow_unused=False):
        return check.run(self.root, self.generated, [self.code], strict=strict, allow_unused=allow_unused)

    def remove(self):
        shutil.rmtree(self.base, ignore_errors=True)


VALID_EN = {
    "demo.title": "Title",
    "demo.screen.deletedAt": "Deleted {date}",
    "demo.files#one": "{count} file",
    "demo.files#other": "{count} files",
    "demo.default": "Default",
}
VALID_RU = {
    "demo.title": "Заголовок",
    "demo.screen.deletedAt": "Удалено {date}",
    "demo.files#one": "{count} файл",
    "demo.files#few": "{count} файла",
    "demo.files#many": "{count} файлов",
    "demo.files#other": "{count} файла",
    "demo.default": "По умолчанию",
}
VALID_CODE = """
let a = GGStrings.Demo.title
let b = GGStrings.Demo.Screen.deletedAt(date: "x")
let c = GGStrings.Demo.files(count: 2)
let d = GGStrings.Demo.`default`.uppercased()
"""


class ToolsTests(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture()
        self.fixture.write_table("en", "demo", VALID_EN)
        self.fixture.write_table("ru", "demo", VALID_RU)
        self.fixture.write_code("Demo.swift", VALID_CODE)

    def tearDown(self):
        self.fixture.remove()

    def errors_after_generate(self, **options):
        diagnostics = self.fixture.generate()
        self.assertEqual(diagnostics.errors, [])
        return self.fixture.check(**options).errors

    def test_valid_tree_passes(self):
        self.assertEqual(self.errors_after_generate(), [])
        warnings = self.fixture.check().warnings
        self.assertTrue(any("uk" in warning for warning in warnings))

    def test_generated_accessors(self):
        self.fixture.generate()
        with open(os.path.join(self.fixture.generated, "GGStrings.swift"), encoding="utf-8") as handle:
            text = handle.read()
        self.assertIn("public enum Demo {", text)
        self.assertIn("public static var title: Swift.String {", text)
        self.assertIn("public static func deletedAt(date: Swift.String) -> Swift.String {", text)
        self.assertIn("GGLocalization.shared.format(\"demo.screen.deletedAt\", [(\"date\", date)])", text)
        self.assertIn("public static func files(count: Swift.Int) -> Swift.String {", text)
        self.assertIn("GGLocalization.shared.plural(\"demo.files\", count: count, [])", text)
        self.assertIn("public static var `default`: Swift.String {", text)
        with open(os.path.join(self.fixture.generated, "GGStringsData.swift"), encoding="utf-8") as handle:
            data = handle.read()
        self.assertIn("static let languages: [String] = [\"en\", \"ru\", \"uk\", \"ar\"]", data)
        self.assertIn("private static let uk: [String] = []", data)

    def test_generation_is_stable(self):
        self.fixture.generate()
        _, written = generate.generate(self.fixture.root, self.fixture.generated)
        self.assertEqual(written, [])

    def test_stale_generated_files_are_reported(self):
        self.fixture.generate()
        table = dict(VALID_EN)
        table["demo.title"] = "Changed"
        self.fixture.write_table("en", "demo", table)
        errors = self.fixture.check().errors
        self.assertTrue(any("out of date" in error for error in errors), errors)

    def test_missing_russian_key_is_an_error(self):
        table = dict(VALID_RU)
        del table["demo.title"]
        self.fixture.write_table("ru", "demo", table)
        errors = self.errors_after_generate()
        self.assertTrue(any("ru: 1 key(s) missing: demo.title" in error for error in errors), errors)

    def test_missing_ukrainian_key_is_a_warning_unless_strict(self):
        self.fixture.write_table("uk", "demo", {"demo.title": "Заголовок"})
        self.assertEqual(self.errors_after_generate(), [])
        strict = self.fixture.check(strict=True).errors
        self.assertTrue(any(error.startswith("uk:") for error in strict), strict)

    def test_key_only_in_russian_is_an_error(self):
        table = dict(VALID_RU)
        table["demo.extra"] = "Лишний"
        self.fixture.write_table("ru", "demo", table)
        errors = self.errors_after_generate()
        self.assertTrue(any("demo.extra is not in en" in error for error in errors), errors)

    def test_placeholder_mismatch(self):
        table = dict(VALID_RU)
        table["demo.screen.deletedAt"] = "Удалено {when}"
        self.fixture.write_table("ru", "demo", table)
        errors = self.errors_after_generate()
        self.assertTrue(any("placeholders" in error and "demo.screen.deletedAt" in error for error in errors), errors)

    def test_missing_plural_form_in_russian(self):
        table = dict(VALID_RU)
        del table["demo.files#few"]
        self.fixture.write_table("ru", "demo", table)
        errors = self.errors_after_generate()
        self.assertTrue(any("missing forms few" in error for error in errors), errors)

    def test_plural_needs_count_in_english_other(self):
        table = dict(VALID_EN)
        table["demo.files#other"] = "files"
        self.fixture.write_table("en", "demo", table)
        errors = self.errors_after_generate()
        self.assertTrue(any("must exist and contain {count}" in error for error in errors), errors)

    def test_cyrillic_in_english(self):
        table = dict(VALID_EN)
        table["demo.title"] = "Заголовок"
        self.fixture.write_table("en", "demo", table)
        errors = self.errors_after_generate()
        self.assertTrue(any("Cyrillic in en" in error for error in errors), errors)

    def test_key_prefix_must_match_the_file(self):
        self.fixture.write_table("en", "other", {"demo.stray": "Stray"})
        errors = self.fixture.check().errors
        self.assertTrue(any("must start with \"other.\"" in error for error in errors), errors)

    def test_invalid_segments_and_placeholders(self):
        self.fixture.write_table("en", "bad", {"bad.Upper": "x", "bad.ok": "{1}", "bad.self": "x"})
        diagnostics = self.fixture.generate()
        joined = "\n".join(diagnostics.errors)
        self.assertIn("camelCase", joined)
        self.assertIn("invalid placeholder {1}", joined)
        self.assertIn("can not be 'self'", joined)

    def test_unused_key(self):
        self.fixture.write_code("Demo.swift", "let a = GGStrings.Demo.title\n")
        errors = self.errors_after_generate()
        self.assertTrue(any("not used by any code" in error for error in errors), errors)
        self.assertEqual(self.fixture.check(allow_unused=True).errors, [])

    def test_unknown_accessor(self):
        self.fixture.write_code("Extra.swift", "let x = GGStrings.Demo.missing\nlet y = GGStrings.Nope.title\n")
        errors = self.errors_after_generate()
        self.assertEqual(len([error for error in errors if "unknown accessor" in error]), 2, errors)

    def test_raw_literal_survives_hashes_and_quotes(self):
        table = dict(VALID_EN)
        table["demo.title"] = "Say \"#hi\" and \\#(x)"
        self.fixture.write_table("en", "demo", table)
        self.fixture.generate()
        with open(os.path.join(self.fixture.generated, "GGStringsData.swift"), encoding="utf-8") as handle:
            data = handle.read()
        # `"#` and `\#` occur in the text, so the literal needs two hashes.
        self.assertIn('##"{', data)
        self.assertNotIn('###"', data)

    def test_invisible_characters_are_escaped(self):
        table = dict(VALID_EN)
        table["demo.title"] = "a b‍c‮d"
        self.fixture.write_table("en", "demo", table)
        self.fixture.generate()
        with open(os.path.join(self.fixture.generated, "GGStringsData.swift"), encoding="utf-8") as handle:
            data = handle.read()
        self.assertNotIn(" ", data)
        self.assertNotIn("‮", data)
        self.assertIn("\\u2028", data)
        chunk = strings_model.namespace_chunks({"demo.title": "a b"})[0][1]
        self.assertEqual(json.loads(chunk), {"demo.title": "a b"})


if __name__ == "__main__":
    unittest.main()
