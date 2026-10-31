#!/usr/bin/env python3
"""Generates the typed string accessors of GGCore from Ghostgram/Strings/<lang>/*.json.

Writes Ghostgram/GGCore/Sources/Strings/Generated/{GGStrings,GGStringsData}.swift. The generated
files are committed. Run after every edit of the JSON files, then run check.py.

    python3 Ghostgram/Strings/generate.py
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import strings_model  # noqa: E402


def generate(root, generated_dir):
    """Returns (diagnostics, written file names)."""
    diagnostics = strings_model.Diagnostics()
    files = strings_model.render_all(root, diagnostics)
    if diagnostics.errors:
        return diagnostics, []
    os.makedirs(generated_dir, exist_ok=True)
    written = []
    for name, content in sorted(files.items()):
        path = os.path.join(generated_dir, name)
        existing = None
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as handle:
                existing = handle.read()
        if existing != content:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(content)
            written.append(name)
    return diagnostics, written


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=strings_model.default_root(), help="Ghostgram/Strings directory")
    parser.add_argument("--output", default=None, help="directory for the generated Swift files")
    arguments = parser.parse_args(argv)

    root = os.path.abspath(arguments.root)
    output = os.path.abspath(arguments.output) if arguments.output else strings_model.default_generated_dir(root)
    diagnostics, written = generate(root, output)
    for message in diagnostics.warnings:
        print("warning: %s" % message)
    for message in diagnostics.errors:
        print("error: %s" % message)
    if diagnostics.errors:
        print("generate.py: %d error(s), nothing written" % len(diagnostics.errors))
        return 1
    if written:
        print("generate.py: updated %s" % ", ".join(written))
    else:
        print("generate.py: up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
