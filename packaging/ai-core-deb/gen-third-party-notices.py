#!/usr/bin/env python3
"""Generate the third-party stanzas of the Debian copyright file for the
bundled venv wheels.

The lmlinux-ai-core package redistributes prebuilt PyPI wheels (litert-lm
and its dependency closure), so their license texts must ship with the
package. This script walks the venv's site-packages, reads each
distribution's dist-info (METADATA + RECORD + bundled license files), and
emits machine-readable copyright-format stanzas:

  - Files:      the distribution's module paths and dist-info dir, derived
                from its RECORD (paths are relative to site-packages)
  - Copyright:  the Author/Author-email metadata (fallback: the name)
  - License:    the License-Expression/License identifier, followed by the
                full license text when the wheel bundles one (LICENSE /
                NOTICE files in the dist-info or its licenses/ dir)
  - Comment:    name==version and the project home-page for traceability

Usage: gen-third-party-notices.py <venv-root>
Prints the stanzas to stdout; build-deb.sh appends them to the static
copyright header (copyright.in). Stdlib only — runs on any build host.
"""

import email.parser
import sys
from pathlib import Path


def fold(text):
    """Fold text into copyright-format continuation lines: one leading
    space per line, '.' for blank lines."""
    out = []
    for line in text.rstrip("\n").split("\n"):
        out.append(" " + line if line.strip() else " .")
    return "\n".join(out)


def license_files(dist_info):
    """Bundled license/notice files for a dist-info: (licenses, notices).
    LICENSE files first, NOTICE files second (some licenses, including
    Apache-2.0 section 4, require NOTICE retention)."""
    licenses = []
    notices = []
    for pattern in ("LICENSE*", "LICENCE*"):
        licenses.extend(sorted(dist_info.glob(pattern)))
        licenses.extend(sorted(dist_info.glob("licenses/" + pattern)))
    for pattern in ("NOTICE*",):
        notices.extend(sorted(dist_info.glob(pattern)))
        notices.extend(sorted(dist_info.glob("licenses/" + pattern)))
    return licenses, notices


# Licenses whose full text ships in /usr/share/common-licenses on every
# Debian system: the identifier alone is the correct copyright-file form
# (embedding the full text is a lintian error).
COMMON_LICENSES = {"Apache-2.0"}


def normalize_license_id(identifier):
    identifier = " ".join(identifier.split())
    if identifier.lower() in ("apache 2.0", "apache-2.0"):
        return "Apache-2.0"
    return identifier


def record_top_levels(dist_info, site):
    """Top-level site-packages paths owned by this distribution, from its
    RECORD (authoritative file list). Returns site-relative paths."""
    record = dist_info / "RECORD"
    if not record.is_file():
        return []
    tops = set()
    dist_name = dist_info.name
    for line in record.read_text(errors="replace").split("\n"):
        path = line.split(",", 1)[0].strip()
        if not path or path.startswith("..") or path.startswith("/"):
            continue
        if path.startswith(dist_name + "/"):
            continue
        top = path.split("/", 1)[0]
        if top in ("__pycache__",):
            continue
        tops.add(top)
    return sorted(tops)


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    venv = Path(sys.argv[1])
    sites = sorted(venv.glob("lib/python*/site-packages"))
    if not sites:
        print("error: no site-packages under %s" % venv, file=sys.stderr)
        return 1
    site = sites[0]
    prefix = "opt/ai-core/venv/lib/%s/%s" % (site.parent.name, site.name)

    print()
    print("# Bundled third-party distributions (prebuilt PyPI wheels,")
    print("# redistributed as-is under their own licenses).")
    print()

    for dist_info in sorted(site.glob("*.dist-info")):
        metadata_file = dist_info / "METADATA"
        if not metadata_file.is_file():
            print("# WARNING: no METADATA in %s" % dist_info.name)
            continue
        msg = email.parser.Parser().parsestr(
            metadata_file.read_text(errors="replace")
        )
        name = msg.get("Name") or dist_info.name
        version = msg.get("Version") or "?"
        author = msg.get("Author") or msg.get("Author-email") or name
        home = msg.get("Home-page") or ""
        license_id = normalize_license_id(
            (msg.get("License-Expression") or msg.get("License") or "UNKNOWN").strip()
        )
        license_text = None
        notice_text = None
        # A long/multi-line License field is already the full text.
        if "\n" in license_id or len(license_id) > 100:
            license_text = license_id
            license_id = "other"
        else:
            licenses, notices = license_files(dist_info)
            chunks = []
            for part in licenses:
                text = part.read_text(errors="replace").strip()
                if not text:
                    continue
                if len(licenses) > 1:
                    chunks.append("--- %s ---" % part.name)
                chunks.append(text)
            if chunks:
                license_text = "\n\n".join(chunks)
            if notices:
                notice_text = "\n\n".join(
                    part.read_text(errors="replace").strip() for part in notices
                ).strip()
        if license_id in COMMON_LICENSES:
            # The identifier alone is the correct form; the full text is in
            # /usr/share/common-licenses on every Debian system.
            license_text = None
        elif license_id == "UNKNOWN" and license_text \
                and "Redistribution and use in source and binary forms" \
                in license_text[:2000]:
            # Wheel ships the license text but no License field; the text is
            # the canonical 3-clause BSD (kept in full below).
            license_id = "BSD-3-Clause"

        tops = record_top_levels(dist_info, site)
        files = [prefix + "/" + top for top in tops]
        files.append(prefix + "/" + dist_info.name)
        print("Files: %s" % ", ".join(files))
        print("Copyright: %s" % author)
        print("License: %s" % license_id)
        if license_text:
            print(fold(license_text))
        elif license_id in COMMON_LICENSES:
            print(" On Debian systems, the complete text is available in")
            print(" /usr/share/common-licenses/%s." % license_id)
        elif home:
            print(" Comment: no license text bundled in the wheel; identifier")
            print("  from the metadata, project: %s" % home)
        comment = "bundled from PyPI wheel %s==%s" % (name, version)
        if home:
            comment += " (%s)" % home
        if notice_text:
            comment += (
                "\nUpstream NOTICE (retained with the bundled wheel):\n"
                + notice_text
            )
        folded_comment = fold(comment).splitlines()
        print("Comment:%s" % folded_comment[0])
        for line in folded_comment[1:]:
            print(line)
        print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
