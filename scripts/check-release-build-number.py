#!/usr/bin/env python3
"""Reject release build numbers already used by a Git tag or GitHub release."""

import argparse
import pathlib
import re
import sys


VERSION_PATTERN = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
BUILD_PATTERN = r"[1-9][0-9]*"
MAX_BUILD_NUMBER = 2**63 - 1  # Must fit Inklet's Swift Int update comparison.


def validate(version_path, tags_path):
    metadata = {}
    for line in version_path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or key not in ("INKLET_VERSION", "INKLET_BUILD_NUMBER") or key in metadata:
            raise ValueError("VERSION must declare each version field exactly once.")
        metadata[key] = value

    version = metadata.get("INKLET_VERSION", "")
    build = metadata.get("INKLET_BUILD_NUMBER", "")
    if not re.fullmatch(VERSION_PATTERN, version):
        raise ValueError("INKLET_VERSION must be a canonical major.minor.patch version.")
    if not re.fullmatch(BUILD_PATTERN, build) or int(build) > MAX_BUILD_NUMBER:
        raise ValueError("INKLET_BUILD_NUMBER must be a positive integer that fits a Swift Int.")

    highest = 0
    for tag in tags_path.read_text().splitlines():
        match = re.fullmatch(rf"v{VERSION_PATTERN}-({BUILD_PATTERN})", tag)
        if match:
            highest = max(highest, int(match.group(1)))
    if int(build) <= highest:
        raise ValueError(
            f"Build {build} must be greater than previously used build {highest}. "
            "Increment both fields in VERSION before building; include draft releases."
        )
    return f"Release build number verified: {version} ({build}); previous maximum: {highest}."


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version_file", type=pathlib.Path)
    parser.add_argument("release_tags_file", type=pathlib.Path,
                        help="One tag per line, including all Git tags and draft release tags")
    arguments = parser.parse_args()
    try:
        print(validate(arguments.version_file, arguments.release_tags_file))
    except (OSError, ValueError) as error:
        print(f"Release build-number check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
