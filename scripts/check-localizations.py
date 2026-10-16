#!/usr/bin/env python3
"""Checks Resources/*.lproj/Localizable.strings against the source.

- Every user-facing literal found in Sources/ (Text, Button, Label, Toggle,
  Point titles/texts, String(localized:)) must be a key in en.lproj.
- Every language must have exactly the keys of en.lproj.
Interpolations like \\(name) become %@, as Swift does for String values.
Usage: scripts/check-localizations.py   (exit 1 on problems)
"""
import glob, os, re, subprocess, sys, json

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

def keys(path):
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", path], capture_output=True, text=True, check=True).stdout
    return set(json.loads(out).keys())

literal = r'"((?:[^"\\]|\\.)*)"'
patterns = [
    r'\b(?:Text|Button|Label|Toggle)\(\s*' + literal,
    r'\b(?:title|text):\s*' + literal,
    r'String\(localized:\s*' + literal,
]
skip = {"⌘", "12:00", "Tacet"}
found = {}
for path in glob.glob(os.path.join(root, "Sources/Tacet/*.swift")):
    src = open(path, encoding="utf-8").read()
    for pattern in patterns:
        for m in re.finditer(pattern, src):
            raw = m.group(1)
            if raw in skip or not re.search(r"[A-Za-z]", raw):
                continue
            key = re.sub(r"\\\([^)]*\)", "%@", raw).replace("\\n", "\n")
            found.setdefault(key, os.path.basename(path))

base = keys(os.path.join(root, "Resources/en.lproj/Localizable.strings"))
problems = []
for key, file in sorted(found.items()):
    if key not in base:
        problems.append(f"missing in en.lproj ({file}): {key!r}")
for path in sorted(glob.glob(os.path.join(root, "Resources/*.lproj/Localizable.strings"))):
    lang = os.path.basename(os.path.dirname(path))
    k = keys(path)
    for key in sorted(base - k):
        problems.append(f"{lang}: missing {key!r}")
    for key in sorted(k - base):
        problems.append(f"{lang}: extra {key!r}")
print("\n".join(problems) or f"OK: {len(base)} keys, {len(glob.glob(os.path.join(root, 'Resources/*.lproj')))} languages")
sys.exit(1 if problems else 0)
