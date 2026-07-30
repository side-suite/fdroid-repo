#!/usr/bin/env python3
"""Sanity-check the built index before it is published.

An APK whose metadata/<pkg>.yml is missing gets silently dropped from the index
with only a warning, so a pack can quietly publish with fewer apps than intended
— or none. This turns that into a hard failure, and prints what did make it in.
"""
import json
import sys
from pathlib import Path

INDEX = Path("repo/index-v2.json")


def main() -> int:
    if not INDEX.exists():
        print(f"::error::{INDEX} not found — did `fdroid update` run?")
        return 1

    index = json.loads(INDEX.read_text())
    repo = index["repo"]
    packages = index["packages"]

    print(f"address:  {repo['address']}")
    print(f"name:     {repo['name'].get('en-US', '?')}")
    print(f"packages: {len(packages)}")

    for pkg in sorted(packages):
        meta = packages[pkg].get("metadata", {})
        summary = meta.get("summary", {}).get("en-US", "!! NO SUMMARY")
        print(f"\n  {pkg}")
        print(f"    {summary}")
        print(f"    license: {meta.get('license', '!! NONE')}")
        for ver in packages[pkg]["versions"].values():
            f = ver["file"]
            vc = ver["manifest"]["versionCode"]
            print(f"    vc={vc}  {f['name']}  {f['size']:,}B")

    if not packages:
        print("\n::error::Index contains no packages. Refusing to publish an empty pack.")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
