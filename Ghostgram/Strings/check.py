#!/usr/bin/env python3
"""Checks the Ghostgram string tables against each other and against the code.

    python3 Ghostgram/Strings/check.py [--strict] [--allow-unused] [--no-upstream] [--code DIR ...]

Errors (exit code 1):
  - JSON that does not parse, non-string values, a key whose first segment is not its file name,
    segments that are not camelCase identifiers, duplicate keys;
  - a key missing from en or ru, or present in a language but not in en;
  - placeholders that differ between languages, a plural without {count} in its en "other" form,
    missing CLDR plural forms in en / ru;
  - Cyrillic in en;
  - generated Swift that is out of date (run generate.py);
  - a GGStrings accessor in code that does not exist, a key that no code uses.
Warnings (errors with --strict): keys or plural forms missing in uk / ar (filled in the translation wave).

Usage is found by scanning Swift files for full accessor paths (`GGStrings.Core.requiresRestart`).
Do not alias the enums (`let s = GGStrings.Core`): the check would report those keys as unused.
"""

import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import strings_model  # noqa: E402
from strings_model import BASE_LANGUAGE, COMPLETE_LANGUAGES, LANGUAGES, PLURAL_CATEGORIES  # noqa: E402

ACCESSOR_RE = re.compile(r"GGStrings((?:\s*\.\s*`?[A-Za-z_][A-Za-z0-9_]*`?)+)")
LITERAL_KEY_RE = re.compile(r"\"([a-z][A-Za-z0-9]*(?:\.[a-z][A-Za-z0-9]*)+)\"")
LIST_LIMIT = 25


def split_tables(tables):
    """Per language: plain {key: text} and plural {base: {category: text}}."""
    plain = {}
    plural = {}
    for language, table in tables.items():
        plain[language] = {}
        plural[language] = {}
        for key, text in table.items():
            base, category = strings_model.split_key(key)
            if category is None:
                plain[language][key] = text
            else:
                plural[language].setdefault(base, {})[category] = text
    return plain, plural


def report_missing(diagnostics, language, keys, strict, what):
    if not keys:
        return
    complete = language in COMPLETE_LANGUAGES
    shown = keys[:LIST_LIMIT]
    rest = len(keys) - len(shown)
    message = "%s: %d %s missing: %s%s" % (
        language, len(keys), what, ", ".join(shown), (" ... and %d more" % rest) if rest > 0 else "")
    if complete or strict:
        diagnostics.error(message)
    else:
        diagnostics.warning(message)


def check_tables(tables, origins, diagnostics, strict):
    plain, plural = split_tables(tables)
    base_plain = plain.get(BASE_LANGUAGE, {})
    base_plural = plural.get(BASE_LANGUAGE, {})

    for key, text in sorted(tables.get(BASE_LANGUAGE, {}).items()):
        if strings_model.CYRILLIC_RE.search(text):
            diagnostics.error("%s: %s: Cyrillic in en" % (origins[BASE_LANGUAGE][key], key))

    for base, forms in sorted(base_plural.items()):
        other = forms.get("other")
        if other is None or "count" not in strings_model.placeholders(other):
            diagnostics.error("en: plural %s: the \"other\" form must exist and contain {count}" % base)

    for language in LANGUAGES:
        language_plain = plain.get(language, {})
        language_plural = plural.get(language, {})
        if language != BASE_LANGUAGE:
            for key in sorted(set(language_plain) - set(base_plain)):
                diagnostics.error("%s: key %s is not in en" % (origins[language][key], key))
            for base in sorted(set(language_plural) - set(base_plural)):
                diagnostics.error("%s: plural %s is not in en" % (language, base))
            report_missing(diagnostics, language, sorted(set(base_plain) - set(language_plain)), strict, "key(s)")
            report_missing(diagnostics, language, sorted(set(base_plural) - set(language_plural)), strict, "plural(s)")

        for key in sorted(set(base_plain) & set(language_plain)):
            where = origins[language][key]
            expected = set(strings_model.placeholders(base_plain[key]))
            actual = set(strings_model.placeholders(language_plain[key], diagnostics, where))
            if expected != actual:
                diagnostics.error("%s: %s: placeholders %s, en has %s" % (
                    where, key, sorted(actual), sorted(expected)))

        required = PLURAL_CATEGORIES.get(language, ["other"])
        for base in sorted(set(base_plural) & set(language_plural)):
            forms = language_plural[base]
            missing = [category for category in required if category not in forms]
            if missing:
                message = "%s: plural %s: missing forms %s" % (language, base, ", ".join(missing))
                if language in COMPLETE_LANGUAGES or strict:
                    diagnostics.error(message)
                else:
                    diagnostics.warning(message)
            extra = [category for category in forms if category not in required]
            if extra:
                diagnostics.warning("%s: plural %s: forms %s are never used for %s" % (
                    language, base, ", ".join(sorted(extra)), language))
            expected = set()
            for text in base_plural[base].values():
                expected.update(strings_model.placeholders(text))
            expected.discard("count")
            union = set()
            for category, text in forms.items():
                names = set(strings_model.placeholders(text, diagnostics, "%s/%s#%s" % (language, base, category)))
                names.discard("count")
                if not names.issubset(expected):
                    diagnostics.error("%s: plural %s#%s: unknown placeholders %s" % (
                        language, base, category, sorted(names - expected)))
                union.update(names)
            if union != expected:
                diagnostics.error("%s: plural %s: placeholders %s, en has %s" % (
                    language, base, sorted(union), sorted(expected)))


def check_generated(root, generated_dir, diagnostics):
    scratch = strings_model.Diagnostics()
    files = strings_model.render_all(root, scratch)
    if scratch.errors:
        return
    for name, content in sorted(files.items()):
        path = os.path.join(generated_dir, name)
        try:
            with open(path, "r", encoding="utf-8") as handle:
                existing = handle.read()
        except OSError:
            existing = None
        if existing != content:
            diagnostics.error("%s is out of date: run Ghostgram/Strings/generate.py" % os.path.relpath(path, os.path.dirname(root)))


def swift_files(directories, excluded):
    seen = set()
    for directory in directories:
        for current, folders, names in os.walk(directory):
            folders[:] = [folder for folder in folders if not folder.startswith(".") and folder not in ("bazel-out", "build-input")]
            if any(os.path.abspath(current).startswith(path) for path in excluded):
                continue
            for name in names:
                if name.endswith(".swift"):
                    path = os.path.abspath(os.path.join(current, name))
                    if path not in seen:
                        seen.add(path)
                        yield path


def scan_code(entries, code_directories, runtime_directory, excluded, diagnostics):
    """Returns the set of used base keys."""
    leaves = {}
    enums = set()
    for entry in entries:
        leaves[entry.accessor_path] = entry.base
        parts = entry.accessor_path.split(".")
        for index in range(1, len(parts)):
            enums.add(".".join(parts[:index]))
    known_bases = set(leaves.values())
    used = set()
    runtime_prefix = os.path.abspath(runtime_directory) if runtime_directory else None
    for path in swift_files(code_directories, excluded):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError:
            continue
        if "GGStrings" in text:
            for match in ACCESSOR_RE.finditer(text):
                parts = [part.strip().strip("`") for part in match.group(1).split(".")]
                parts = [part for part in parts if part]
                if not parts or parts[0] == "self":
                    continue
                prefix = []
                resolved = False
                for part in parts:
                    candidate = ".".join(prefix + [part])
                    if candidate in leaves:
                        used.add(leaves[candidate])
                        resolved = True
                        break
                    if candidate in enums:
                        prefix.append(part)
                        continue
                    break
                if not resolved and len(prefix) < len(parts):
                    line = text.count("\n", 0, match.start()) + 1
                    diagnostics.error("%s:%d: unknown accessor GGStrings.%s" % (path, line, ".".join(parts)))
        if runtime_prefix and path.startswith(runtime_prefix):
            for match in LITERAL_KEY_RE.finditer(text):
                if match.group(1) in known_bases:
                    used.add(match.group(1))
    return used


def run(root, generated_dir, code_directories, strict=False, allow_unused=False, runtime_directory=None):
    diagnostics = strings_model.Diagnostics()
    tables, origins = strings_model.load_tables(root, diagnostics)
    entries = strings_model.build_entries(tables, diagnostics)
    check_tables(tables, origins, diagnostics, strict)
    check_generated(root, generated_dir, diagnostics)
    excluded = [os.path.abspath(generated_dir), os.path.abspath(root)]
    used = scan_code(entries, code_directories, runtime_directory, excluded, diagnostics)
    unused = sorted(entry.base for entry in entries if entry.base not in used)
    if unused:
        shown = unused[:LIST_LIMIT]
        rest = len(unused) - len(shown)
        message = "%d key(s) are not used by any code: %s%s" % (
            len(unused), ", ".join(shown), (" ... and %d more" % rest) if rest > 0 else "")
        if allow_unused:
            diagnostics.warning(message)
        else:
            diagnostics.error(message)
    return diagnostics


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=strings_model.default_root(), help="Ghostgram/Strings directory")
    parser.add_argument("--generated", default=None, help="directory of the generated Swift files")
    parser.add_argument("--code", action="append", default=[], help="extra directory to scan for usage")
    parser.add_argument("--no-upstream", action="store_true", help="scan only Ghostgram/, not submodules/ and Telegram/")
    parser.add_argument("--strict", action="store_true", help="treat missing uk / ar translations as errors")
    parser.add_argument("--allow-unused", action="store_true", help="report unused keys as warnings")
    arguments = parser.parse_args(argv)

    root = os.path.abspath(arguments.root)
    generated = os.path.abspath(arguments.generated) if arguments.generated else strings_model.default_generated_dir(root)
    ghostgram = os.path.dirname(root)
    repository = os.path.dirname(ghostgram)
    code = [ghostgram] + [os.path.abspath(path) for path in arguments.code]
    if not arguments.no_upstream:
        for name in ("submodules", "Telegram"):
            path = os.path.join(repository, name)
            if os.path.isdir(path):
                code.append(path)
    runtime = os.path.join(ghostgram, "GGCore", "Sources")

    diagnostics = run(root, generated, code, arguments.strict, arguments.allow_unused, runtime)
    for message in diagnostics.warnings:
        print("warning: %s" % message)
    for message in diagnostics.errors:
        print("error: %s" % message)
    print("check.py: %d error(s), %d warning(s)" % (len(diagnostics.errors), len(diagnostics.warnings)))
    return 1 if diagnostics.errors else 0


if __name__ == "__main__":
    sys.exit(main())
