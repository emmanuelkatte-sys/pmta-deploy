#!/usr/bin/env python3
"""Pack pmta-bundle-v1 -> gui/assets/pmta-bundle-v1.tar.gz + update bundle_pmta.txt"""
from __future__ import annotations

import sys
from pathlib import Path

ASSETS = Path(__file__).resolve().parent
sys.path.insert(0, str(ASSETS))

from _repack_common import pack_tree, sha256_file, write_bundle_meta

SRC = ASSETS / "pmta-bundle-v1"
OUT = ASSETS / "pmta-bundle-v1.4.tar.gz"
META = ASSETS / "bundle_pmta.txt"
ARC_TOP = "pmta-bundle-v1"


def main() -> None:
    if not (SRC / "PowerMTA-5.0r8.deb").is_file() and not (SRC / "config").exists():
        raise SystemExit(f"missing source: {SRC}")
    print(f"Packing {SRC} -> {OUT}")
    added, skipped = pack_tree(SRC, OUT, arc_prefix=ARC_TOP)
    digest = sha256_file(OUT)
    size_mb = OUT.stat().st_size / (1024 * 1024)
    write_bundle_meta(
        META,
        title="PowerMTA bundle. SHA256 is the local tar; frozen EXE uses BUNDLE_URL.",
        bundled=OUT.name,
        sha256=digest,
    )
    print(f"Done: {size_mb:.1f} MB  files={added} skipped={skipped}")
    print(f"SHA256: {digest}")
    print(f"Updated: {META}")


if __name__ == "__main__":
    main()
