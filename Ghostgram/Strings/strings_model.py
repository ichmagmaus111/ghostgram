"""Shared model of the Ghostgram string tables, used by generate.py and check.py.

Source layout: Ghostgram/Strings/<lang>/<namespace>.json, each a flat {"key": "text"} object.
A key is "<namespace>.<screen>.<string>" or "<namespace>.<string>"; the first segment is the file
name. Plural forms are separate keys "<key>#<category>" (CLDR categories) and always take {count}.
Substitutions are named: "Deleted {date}". "{{" and "}}" are literal braces.
"""

import json
import os
import re
import unicodedata

LANGUAGES = ["en", "ru", "uk", "ar"]
BASE_LANGUAGE = "en"
# Missing keys in these languages are errors; in the others a warning until the translation wave.
COMPLETE_LANGUAGES = ["en", "ru"]

PLURAL_CATEGORIES = {
    "en": ["one", "other"],
    "ru": ["one", "few", "many", "other"],
    "uk": ["one", "few", "many", "other"],
    "ar": ["zero", "one", "two", "few", "many", "other"],
}
ALL_PLURAL_CATEGORIES = ["zero", "one", "two", "few", "many", "other"]

SEGMENT_RE = re.compile(r"^[a-z][A-Za-z0-9]*$")
ARGUMENT_RE = re.compile(r"^[a-z][A-Za-z0-9]*$")
TOKEN_RE = re.compile(r"\{\{|\}\}|\{([^{}]*)\}|[{}]")
CYRILLIC_RE = re.compile(r"[Ѐ-ӿԀ-ԯ]")

# Leaf names that are Swift keywords are emitted with backticks; these can not be used at all.
FORBIDDEN_LEAVES = {"self", "Self", "init", "deinit", "subscript", "Type", "Protocol", "_"}
# Nested enum names that would shadow what the generated code refers to.
FORBIDDEN_ENUMS = {"Swift", "GGLocalization", "GGStrings", "Type", "Self", "Protocol", "Any", "AnyObject"}
SWIFT_KEYWORDS = {
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init",
    "inout", "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public",
    "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case", "catch",
    "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat",
    "return", "throw", "switch", "where", "while", "as", "is", "nil", "super", "self", "true", "false",
    "try", "throws", "any", "some", "await", "async",
}


class Diagnostics:
    def __init__(self):
        self.errors = []
        self.warnings = []

    def error(self, message):
        self.errors.append(message)

    def warning(self, message):
        self.warnings.append(message)


def default_root():
    return os.path.dirname(os.path.abspath(__file__))


def default_generated_dir(root):
    return os.path.normpath(os.path.join(root, "..", "GGCore", "Sources", "Strings", "Generated"))


def split_key(key):
    """Returns (base, category) where category is None for a plain key."""
    if "#" in key:
        base, category = key.split("#", 1)
        return base, category
    return key, None


def placeholders(text, diagnostics=None, where=""):
    """Named placeholders in order of first appearance."""
    result = []
    for match in TOKEN_RE.finditer(text):
        token = match.group(0)
        if token in ("{{", "}}"):
            continue
        if token in ("{", "}"):
            if diagnostics is not None:
                diagnostics.error("%s: unbalanced brace in %r (use {{ and }} for literal braces)" % (where, text))
            continue
        name = match.group(1)
        if not ARGUMENT_RE.match(name) or name in SWIFT_KEYWORDS:
            if diagnostics is not None:
                diagnostics.error("%s: invalid placeholder {%s}" % (where, name))
            continue
        if name not in result:
            result.append(name)
    return result


def load_tables(root, diagnostics):
    """Reads every <lang>/<namespace>.json. Returns ({lang: {key: text}}, {lang: {key: path}})."""
    tables = {}
    origins = {}
    for language in LANGUAGES:
        tables[language] = {}
        origins[language] = {}
        directory = os.path.join(root, language)
        if not os.path.isdir(directory):
            continue
        for name in sorted(os.listdir(directory)):
            if not name.endswith(".json"):
                continue
            path = os.path.join(directory, name)
            namespace = name[:-len(".json")]
            relative = os.path.relpath(path, root)
            if not SEGMENT_RE.match(namespace):
                diagnostics.error("%s: file name must be a camelCase namespace" % relative)
                continue
            try:
                with open(path, "r", encoding="utf-8") as handle:
                    content = json.load(handle)
            except (OSError, ValueError) as error:
                diagnostics.error("%s: can not parse JSON: %s" % (relative, error))
                continue
            if not isinstance(content, dict):
                diagnostics.error("%s: top level must be an object" % relative)
                continue
            for key, value in content.items():
                if not isinstance(value, str):
                    diagnostics.error("%s: %s: value must be a string" % (relative, key))
                    continue
                base, category = split_key(key)
                segments = base.split(".")
                if segments[0] != namespace:
                    diagnostics.error("%s: key %s must start with \"%s.\"" % (relative, key, namespace))
                    continue
                if len(segments) < 2:
                    diagnostics.error("%s: key %s needs at least two segments" % (relative, key))
                    continue
                bad = [segment for segment in segments if not SEGMENT_RE.match(segment)]
                if bad:
                    diagnostics.error("%s: key %s: segments must be camelCase identifiers" % (relative, key))
                    continue
                if segments[-1] in FORBIDDEN_LEAVES:
                    diagnostics.error("%s: key %s: last segment can not be %r" % (relative, key, segments[-1]))
                    continue
                enums = [pascal(segment) for segment in segments[:-1]]
                if any(name in FORBIDDEN_ENUMS for name in enums):
                    diagnostics.error("%s: key %s: a segment collides with a reserved type name" % (relative, key))
                    continue
                if category is not None and category not in ALL_PLURAL_CATEGORIES:
                    diagnostics.error("%s: key %s: unknown plural category %r" % (relative, key, category))
                    continue
                if key in tables[language]:
                    diagnostics.error("%s: duplicate key %s (also in %s)" % (relative, key, origins[language][key]))
                    continue
                tables[language][key] = value
                origins[language][key] = relative
    return tables, origins


def pascal(segment):
    return segment[:1].upper() + segment[1:]


class Entry:
    """One accessor: a plain string or a plural group."""

    def __init__(self, base, kind, arguments, doc):
        self.base = base
        self.kind = kind
        self.arguments = arguments
        self.doc = doc

    @property
    def segments(self):
        return self.base.split(".")

    @property
    def accessor_path(self):
        segments = self.segments
        return ".".join([pascal(segment) for segment in segments[:-1]] + [segments[-1]])


def build_entries(tables, diagnostics):
    """Accessors are generated from the base language."""
    base_table = tables.get(BASE_LANGUAGE, {})
    groups = {}
    for key in base_table:
        base, category = split_key(key)
        group = groups.setdefault(base, {"plain": None, "plural": {}})
        if category is None:
            group["plain"] = key
        else:
            group["plural"][category] = key
    entries = []
    for base in sorted(groups):
        group = groups[base]
        if group["plain"] is not None and group["plural"]:
            diagnostics.error("%s: key is both a plain string and a plural" % base)
            continue
        if group["plain"] is not None:
            text = base_table[group["plain"]]
            arguments = placeholders(text, diagnostics, "%s/%s" % (BASE_LANGUAGE, base))
            entries.append(Entry(base, "plain", arguments, text))
        else:
            arguments = []
            for category in ALL_PLURAL_CATEGORIES:
                key = group["plural"].get(category)
                if key is None:
                    continue
                for name in placeholders(base_table[key], diagnostics, "%s/%s" % (BASE_LANGUAGE, key)):
                    if name not in arguments:
                        arguments.append(name)
            if "count" in arguments:
                arguments.remove("count")
            arguments.insert(0, "count")
            doc = base_table.get(group["plural"].get("other") or sorted(group["plural"].values())[0])
            entries.append(Entry(base, "plural", arguments, doc))
    # A leaf and a nested enum may share a spelling only when their case differs, which the
    # camelCase/PascalCase split already guarantees; two accessors with one path can not exist.
    return entries


def swift_identifier(name):
    if name in SWIFT_KEYWORDS:
        return "`%s`" % name
    return name


def swift_doc(text):
    single = text.replace("\r", " ").replace("\n", "⏎")
    if len(single) > 160:
        single = single[:157] + "..."
    return single


def render_strings_swift(entries):
    tree = {"children": {}, "leaves": []}
    for entry in entries:
        node = tree
        for segment in entry.segments[:-1]:
            node = node["children"].setdefault(pascal(segment), {"children": {}, "leaves": []})
        node["leaves"].append(entry)

    lines = [
        "// Generated by Ghostgram/Strings/generate.py from Ghostgram/Strings/<lang>/*.json. Do not edit.",
        "// Every accessor is computed: a translated string is never stored, so a language switch applies at once.",
        "",
        "public enum GGStrings {",
    ]

    def emit(node, indent):
        pad = "    " * indent
        first = True
        for entry in sorted(node["leaves"], key=lambda item: item.segments[-1]):
            if not first:
                lines.append("")
            first = False
            name = swift_identifier(entry.segments[-1])
            lines.append("%s/// %s" % (pad, swift_doc(entry.doc)))
            if entry.kind == "plain" and not entry.arguments:
                lines.append("%spublic static var %s: Swift.String {" % (pad, name))
                lines.append("%s    return GGLocalization.shared.string(\"%s\")" % (pad, entry.base))
                lines.append("%s}" % pad)
                continue
            parameters = []
            pairs = []
            for argument in entry.arguments:
                if argument == "count":
                    parameters.append("count: Swift.Int")
                    if entry.kind == "plain":
                        pairs.append("(\"count\", Swift.String(count))")
                else:
                    parameters.append("%s: Swift.String" % argument)
                    pairs.append("(\"%s\", %s)" % (argument, argument))
            signature = "%spublic static func %s(%s) -> Swift.String {" % (pad, name, ", ".join(parameters))
            lines.append(signature)
            if entry.kind == "plain":
                lines.append("%s    return GGLocalization.shared.format(\"%s\", [%s])" % (pad, entry.base, ", ".join(pairs)))
            else:
                lines.append("%s    return GGLocalization.shared.plural(\"%s\", count: count, [%s])" % (pad, entry.base, ", ".join(pairs)))
            lines.append("%s}" % pad)
        for name in sorted(node["children"]):
            if not first:
                lines.append("")
            first = False
            lines.append("%spublic enum %s {" % (pad, name))
            emit(node["children"][name], indent + 1)
            lines.append("%s}" % pad)

    emit(tree, 1)
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def escape_for_swift_source(text):
    """JSON text with every invisible or line-breaking character written as a \\u escape."""
    output = []
    for character in text:
        category = unicodedata.category(character)
        if category in ("Cc", "Cf", "Zl", "Zp", "Co", "Cs"):
            code = ord(character)
            if code > 0xFFFF:
                code -= 0x10000
                output.append("\\u%04x\\u%04x" % (0xD800 + (code >> 10), 0xDC00 + (code & 0x3FF)))
            else:
                output.append("\\u%04x" % code)
        else:
            output.append(character)
    return "".join(output)


def raw_swift_literal(text):
    hashes = 1
    while ('"' + "#" * hashes) in text or ("\\" + "#" * hashes) in text:
        hashes += 1
    return "#" * hashes + '"' + text + '"' + "#" * hashes


def namespace_chunks(table):
    """{namespace: compact JSON} for one language, one chunk per namespace."""
    namespaces = {}
    for key, value in table.items():
        namespaces.setdefault(key.split(".", 1)[0], {})[key] = value
    chunks = []
    for namespace in sorted(namespaces):
        text = json.dumps(namespaces[namespace], ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        chunks.append((namespace, escape_for_swift_source(text)))
    return chunks


def render_data_swift(tables):
    lines = [
        "// Generated by Ghostgram/Strings/generate.py from Ghostgram/Strings/<lang>/*.json. Do not edit.",
        "// String tables as raw JSON literals, one per namespace, parsed lazily on first use. There are no",
        "// bundle resources, so the app and every extension see the same strings.",
        "",
        "enum GGStringsData {",
        "    static let languages: [String] = [%s]" % ", ".join("\"%s\"" % language for language in LANGUAGES),
        "",
        "    static func chunks(for language: String) -> [String]? {",
        "        switch language {",
    ]
    for language in LANGUAGES:
        lines.append("        case \"%s\":" % language)
        lines.append("            return GGStringsData.%s" % language)
    lines.append("        default:")
    lines.append("            return nil")
    lines.append("        }")
    lines.append("    }")
    for language in LANGUAGES:
        lines.append("")
        chunks = namespace_chunks(tables.get(language, {}))
        if not chunks:
            lines.append("    private static let %s: [String] = []" % language)
            continue
        lines.append("    private static let %s: [String] = [" % language)
        for namespace, text in chunks:
            lines.append("        // %s" % namespace)
            lines.append("        %s," % raw_swift_literal(text))
        lines.append("    ]")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def render_all(root, diagnostics):
    """Returns {file name: content} of the generated Swift sources."""
    tables, _ = load_tables(root, diagnostics)
    entries = build_entries(tables, diagnostics)
    return {
        "GGStrings.swift": render_strings_swift(entries),
        "GGStringsData.swift": render_data_swift(tables),
    }
