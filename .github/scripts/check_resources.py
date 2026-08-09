#!/usr/bin/env python3
# Copyright (C) 2026 SkapaCraft <https://skapacraft.com>
# SPDX-License-Identifier: GPL-3.0-or-later

"""Checks that need no Connect IQ SDK.

The SDK cannot be downloaded in CI without accepting Garmin's licence
interactively, so a compile is not available here. What is available is
everything the compiler would not have caught anyway:

1. Every resource XML parses. A stray ampersand in one translation breaks the
   build for one language only, which is easy to miss locally.
2. Every string id the code asks for exists in the default language, and every
   translation carries the same set of ids, minus the ones deliberately left
   untranslated. A string forgotten in one locale falls back to English on the
   watch of whoever runs it, and there is no way to notice that from a simulator
   running in English. Ids that are meant to stay in the default language go in
   `.github/untranslated.txt`, so "not translated yet" and "not translated on
   purpose" stay distinguishable.
3. The version in manifest.xml matches the newest released entry in
   CHANGELOG.md. This one is here because it is what actually went wrong: the
   two drifted apart twice without anything complaining.
"""

from __future__ import annotations

import glob
import os
import re
import sys
import xml.etree.ElementTree as ET

FAILURES: list[str] = []

# Ids a translation is allowed to omit, one per line, blank lines and # ignored.
UNTRANSLATED_FILE = ".github/untranslated.txt"


def read_untranslated() -> set[str]:
    if not os.path.exists(UNTRANSLATED_FILE):
        return set()
    with open(UNTRANSLATED_FILE, encoding="utf-8") as handle:
        lines = (line.split("#", 1)[0].strip() for line in handle)
        return {line for line in lines if line}


def fail(message: str) -> None:
    FAILURES.append(message)
    print(f"FAIL  {message}")


def ok(message: str) -> None:
    print(f"ok    {message}")


def check_xml_well_formed() -> None:
    files = ["manifest.xml"] + sorted(glob.glob("resources*/**/*.xml", recursive=True))
    for path in files:
        try:
            ET.parse(path)
        except ET.ParseError as exc:
            fail(f"{path} is not well-formed XML: {exc}")
    if not FAILURES:
        ok(f"{len(files)} XML files parse")


def string_ids(path: str) -> set[str]:
    root = ET.parse(path).getroot()
    return {el.attrib["id"] for el in root.iter("string") if "id" in el.attrib}


def check_strings() -> None:
    default = "resources/strings/strings.xml"
    if not os.path.exists(default):
        fail(f"{default} is missing")
        return

    defined = string_ids(default)

    # Every @Strings.foo the project refers to, from code, manifest and layouts.
    referenced: set[str] = set()
    sources = (
        glob.glob("source/**/*.mc", recursive=True)
        + glob.glob("resources*/**/*.xml", recursive=True)
        + ["manifest.xml"]
    )
    for path in sources:
        if path == default:
            continue
        with open(path, encoding="utf-8") as handle:
            referenced |= set(re.findall(r"@Strings\.([A-Za-z0-9_]+)", handle.read()))

    missing = sorted(referenced - defined)
    if missing:
        fail(f"{default} does not define: {', '.join(missing)}")
    else:
        ok(f"{len(referenced)} referenced string ids all defined")

    untranslated = read_untranslated()
    unknown = sorted(untranslated - defined)
    if unknown:
        fail(f"{UNTRANSLATED_FILE} lists ids that do not exist: {', '.join(unknown)}")

    expected = defined - untranslated
    translations = sorted(
        p for p in glob.glob("resources-*/strings/strings.xml") if p != default
    )
    clean = True
    for path in translations:
        ids = string_ids(path)
        absent = sorted(expected - ids)
        extra = sorted(ids - defined)
        if absent:
            fail(f"{path} is missing: {', '.join(absent)}")
            clean = False
        if extra:
            fail(f"{path} defines ids the default language does not: {', '.join(extra)}")
            clean = False
    if translations and clean:
        note = f" ({len(untranslated)} left to the default on purpose)" if untranslated else ""
        ok(f"{len(translations)} translations carry all {len(expected)} ids{note}")


def check_version() -> None:
    with open("manifest.xml", encoding="utf-8") as handle:
        manifest = handle.read()
    match = re.search(r"<iq:application\b[^>]*\bversion=\"([^\"]+)\"", manifest, re.S)
    if not match:
        fail("manifest.xml has no version attribute on <iq:application>")
        return
    manifest_version = match.group(1)

    with open("CHANGELOG.md", encoding="utf-8") as handle:
        headings = re.findall(r"^## \[([^\]]+)\]", handle.read(), re.M)
    released = [h for h in headings if h.lower() != "unreleased"]
    if not released:
        fail("CHANGELOG.md has no released version heading")
        return

    if manifest_version != released[0]:
        fail(
            f"manifest.xml is at {manifest_version}, "
            f"the newest released CHANGELOG entry is {released[0]}"
        )
    else:
        ok(f"manifest.xml and CHANGELOG.md agree on {manifest_version}")


def main() -> int:
    check_xml_well_formed()
    check_strings()
    check_version()
    if FAILURES:
        print(f"\n{len(FAILURES)} check(s) failed")
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
