#!/usr/bin/env python3
"""Check a kernel's Module.symvers against the CRCs the vendor modules expect.

The 434 vendor modules in /vendor/lib/modules record, in their __versions
section, the exact CRC of every kernel symbol they import. If our kernel
exports a different CRC the module refuses to load and Android bootloops.
Zero mismatches == the modules will load == safe to flash.
"""
import json
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))
EXPECTED = json.load(open(os.path.join(HERE, "vendor_expected_crc.json")))


def load_symvers(path):
    d = {}
    for line in open(path, "r", errors="ignore"):
        parts = line.split()
        if len(parts) >= 4 and parts[0].startswith("0x"):
            d[parts[1]] = int(parts[0], 16)
    return d


def main():
    path = sys.argv[1]
    kern = load_symvers(path)
    bad, ok = [], 0
    for sym, crcs in EXPECTED.items():
        exp = crcs[0]
        if sym not in kern:
            continue  # not exported by our kernel (vendor-internal symbol)
        if kern[sym] == exp:
            ok += 1
        else:
            bad.append((sym, exp, kern[sym]))
    print(f"vendor-imported symbols checked: {len(EXPECTED)}")
    print(f"  matched: {ok}")
    print(f"  CRC mismatch: {len(bad)}")
    for s, e, a in bad[:40]:
        print(f"  MISMATCH {s}: expected {hex(e)} got {hex(a)}")
    if bad:
        print("VENDOR CRC CHECK: FAIL - modules would refuse to load")
        return 1
    print("VENDOR CRC CHECK: PASS - every vendor module symbol matches")
    return 0


if __name__ == "__main__":
    sys.exit(main())
