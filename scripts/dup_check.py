#!/usr/bin/env python3
"""Reject a kernel whose vmlinux exports a symbol that a vendor module also exports.

Module loading fails with "exports duplicate symbol ... (owned by kernel)" and
every module that depends on it never loads. On NX721J this is how a built-in
RNDIS broke usb_f_gsi -> ipam -> ipa_* -> qca_cld3 (WiFi).

Usage: dup_check.py <Module.symvers>
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
VENDOR = json.load(open(os.path.join(HERE, "vendor_exports.json")))


def main():
    kern = {}
    for line in open(sys.argv[1], "r", errors="ignore"):
        parts = line.split()
        if len(parts) >= 4 and parts[2] == "vmlinux":
            kern[parts[1]] = parts[0]
    conflicts = sorted(s for s in VENDOR if s in kern)
    print(f"kernel vmlinux exports: {len(kern)}")
    print(f"vendor module exports: {len(VENDOR)}")
    print(f"duplicate-symbol conflicts: {len(conflicts)}")
    for s in conflicts[:40]:
        print(f"  CONFLICT {s} also exported by {VENDOR[s]}")
    # informational: module-vs-module overlaps (harmless, we do not ship modules)
    mod_overlap = 0
    for line in open(sys.argv[1], "r", errors="ignore"):
        parts = line.split()
        if len(parts) >= 4 and parts[2] != "vmlinux" and parts[1] in VENDOR:
            mod_overlap += 1
    print(f"(module-vs-module symbol overlaps, informational: {mod_overlap})")
    if conflicts:
        print("DUP CHECK: FAIL - duplicate symbols would block vendor modules")
        return 1
    print("DUP CHECK: PASS - no kernel/vendor duplicate exports")
    return 0


if __name__ == "__main__":
    sys.exit(main())
