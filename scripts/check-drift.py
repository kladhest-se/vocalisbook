#!/usr/bin/env python3
"""Fail when intentionally identical platform implementations diverge."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
GROUPS = {
    "BackgroundDownloadCoordinator.swift": ("iOS", "macOS"),
    "EmbeddedChapterReader.swift": ("iOS", "macOS", "tvOS"),
    "NowPlayingFields.swift": ("iOS", "macOS", "tvOS"),
    "PlaybackAction.swift": ("iOS", "macOS", "tvOS"),
    "PlaybackRules.swift": ("iOS", "macOS", "tvOS"),
    "StoreLocation.swift": ("iOS", "macOS"),
}

failed = False
for filename, platforms in GROUPS.items():
    paths = [ROOT / "Platform" / platform / "Sources/Platform" / filename
             for platform in platforms]
    if not all(path.is_file() for path in paths):
        print(f"Missing platform copy: {filename}", file=sys.stderr)
        failed = True
    elif any(path.read_bytes() != paths[0].read_bytes() for path in paths[1:]):
        print(f"Platform copies differ: {filename} ({', '.join(platforms)})", file=sys.stderr)
        failed = True
if failed:
    sys.exit(1)
print(f"Platform drift checks passed ({len(GROUPS)} groups).")
