#!/usr/bin/env python3
"""Create dist/update.json for a GitHub release."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = ROOT / "dist" / "update.json"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, help="GitHub owner/repository")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--notes",
        default="Home Assistant update. See the GitHub release notes for details.",
    )
    args = parser.parse_args()

    if not re.fullmatch(r"[^/]+/[^/]+", args.repo):
        parser.error("--repo must look like owner/repository")

    version = (ROOT / "version.txt").read_text(encoding="utf-8").strip()
    base = f"https://github.com/{args.repo}/releases/latest/download"

    manifest = {
        "version": version,
        "notes": args.notes,
        "installers": {
            "client": f"{base}/install-client.lua",
            "switch": f"{base}/install-switch.lua",
            "dimmer": f"{base}/install-dimmer.lua",
            "all": f"{base}/install-all.lua",
        },
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    try:
        shown = args.output.relative_to(ROOT)
    except ValueError:
        shown = args.output
    print(f"wrote {shown} for version {version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
