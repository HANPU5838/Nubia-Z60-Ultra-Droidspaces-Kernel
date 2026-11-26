#!/usr/bin/env python3
"""CRC guard: refuse a kernel build that changes any exported symbol CRC.

The stock nubia vendor modules (GPU/display/camera/audio/...) are built
against the vendor kernel's `__crc_*` values. If the candidate kernel
changes even one of them, those modules refuse to load and Android
bootloops. This script compares Module.symvers of a baseline build (exact
v1.0 config) with the candidate build and fails on any difference.

Usage: crc_guard.py <baseline Module.symvers> <candidate Module.symvers>
"""
import sys


def load(path):
    syms = {}
    with open(path, "r", errors="ignore") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2 and parts[0].startswith("0x"):
                syms[parts[1]] = parts[0]
    return syms


def main():
    base = load(sys.argv[1])
    cand = load(sys.argv[2])
    missing = sorted(s for s in base if s not in cand)
    changed = sorted(
        (s, base[s], cand[s]) for s in base if s in cand and cand[s] != base[s]
    )
    extra = sorted(s for s in cand if s not in base)

    print(f"baseline exported symbols : {len(base)}")
    print(f"candidate exported symbols: {len(cand)}")
    print(f"missing (removed ABI): {len(missing)}")
    print(f"changed CRC (broken ABI): {len(changed)}")
    print(f"new symbols (fine)      : {len(extra)}")
    for s in missing[:30]:
        print(f"  MISSING {s}")
    for s, a, b in changed[:30]:
        print(f"  CHANGED {s}: {a} -> {b}")
    if missing or changed:
        print("CRC GUARD: FAIL - kernel ABI changed, vendor modules would break")
        return 1
    print("CRC GUARD: PASS - no exported symbol CRC changed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
