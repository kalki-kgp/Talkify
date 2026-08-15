#!/usr/bin/env python3
"""Copy Swift sources into a SwiftPM staging tree with `#Preview` blocks removed.

Command Line Tools ship the Observation and Testing macro plugins but not
`PreviewsMacros`, so `#Preview` is the one construct in this codebase that a
build without Xcode cannot expand. Stripping the blocks on the way into the
staging tree keeps the repository itself untouched — nothing here edits a file
under `Talkify/`.
"""

import argparse
import os
import re
import shutil


def strip_previews(text):
  """Remove every `#Preview ... { ... }` declaration, brace-matched.

  Braces inside string literals and comments do not count, so a preview whose
  body contains `Text("}")` still ends where it really ends.
  """
  out = []
  i = 0
  n = len(text)
  while True:
    start = find_preview(text, i)
    if start is None:
      out.append(text[i:])
      break
    out.append(text[i:start])
    body = text.find("{", start)
    if body == -1:
      out.append(text[start:])
      break
    end = match_brace(text, body)
    if end is None:
      out.append(text[start:])
      break
    # Swallow the newline the declaration sat on so no blank gap is left.
    i = end + 1
    if i < n and text[i] == "\n":
      i += 1
  return "".join(out)


def find_preview(text, start):
  """Index of the next `#Preview` that begins a line, or None."""
  at = text.find("#Preview", start)
  while at != -1:
    line_start = text.rfind("\n", 0, at) + 1
    if text[line_start:at].strip() == "":
      return line_start
    at = text.find("#Preview", at + 1)
  return None


def match_brace(text, open_index):
  """Index of the `}` closing the `{` at `open_index`, or None."""
  depth = 0
  i = open_index
  n = len(text)
  while i < n:
    c = text[i]
    if c == "/" and i + 1 < n and text[i + 1] == "/":
      i = text.find("\n", i)
      if i == -1:
        return None
      continue
    if c == "/" and i + 1 < n and text[i + 1] == "*":
      close = text.find("*/", i + 2)
      if close == -1:
        return None
      i = close + 2
      continue
    if text.startswith('"""', i):
      close = text.find('"""', i + 3)
      if close == -1:
        return None
      i = close + 3
      continue
    if c == '"':
      i += 1
      while i < n and text[i] != '"':
        i += 2 if text[i] == "\\" else 1
      i += 1
      continue
    if c == "{":
      depth += 1
    elif c == "}":
      depth -= 1
      if depth == 0:
        return i
    i += 1
  return None


def strip_main(text):
  """Drop the `@main` attribute so this copy can link beside another entry point."""
  return re.sub(r"^@main\n", "", text, flags=re.MULTILINE)


def drop_testable_import(text, module):
  """Drop `@testable import <module>` — the test runner is that module."""
  return re.sub(rf"^@testable import {re.escape(module)}\n", "", text, flags=re.MULTILINE)


def stage(source_dir, destination_dir, options):
  shutil.rmtree(destination_dir, ignore_errors=True)
  staged = 0
  stripped = 0
  for root, _, files in os.walk(source_dir):
    for name in sorted(files):
      if not name.endswith(".swift"):
        continue
      source = os.path.join(root, name)
      relative = os.path.relpath(source, source_dir)
      destination = os.path.join(destination_dir, relative)
      os.makedirs(os.path.dirname(destination), exist_ok=True)
      with open(source, encoding="utf-8") as handle:
        text = handle.read()
      rewritten = strip_previews(text)
      if rewritten != text:
        stripped += 1
      if options.strip_main:
        rewritten = strip_main(rewritten)
      if options.drop_testable_import:
        rewritten = drop_testable_import(rewritten, options.drop_testable_import)
      with open(destination, "w", encoding="utf-8") as handle:
        handle.write(rewritten)
      staged += 1
  return staged, stripped


if __name__ == "__main__":
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("source_dir")
  parser.add_argument("destination_dir")
  parser.add_argument(
    "--strip-main",
    action="store_true",
    help="drop the @main attribute (for a copy that links beside another entry point)"
  )
  parser.add_argument(
    "--drop-testable-import",
    metavar="MODULE",
    help="drop `@testable import MODULE` lines"
  )
  arguments = parser.parse_args()
  count, previews = stage(arguments.source_dir, arguments.destination_dir, arguments)
  print(f"staged {count} Swift files ({previews} with #Preview blocks removed)")
