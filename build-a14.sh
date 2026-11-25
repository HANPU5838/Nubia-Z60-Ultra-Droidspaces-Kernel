#!/bin/bash
#
# Build a "perfect" Droidspaces + NetHunter GKI kernel for the nubia NX721J
# (Z60 Ultra, sm8650) on ANDROID 14 / MyOS 14.5.6MR2.
#
# Target: kernel 6.1.68-android14-11-g716498f88d0f-ab11695701
#
# Recipe:
#   * ACK android14-6.1 at commit 716498f88d0f (the exact vendor kernel base)
#   * the device's own stock /proc/config.gz (legacy/nx721j-a14-stock.config)
#   * v1.0 Droidspaces options (SYSVIPC, POSIX_MQUEUE, namespaces, DEVTMPFS, MACVLAN,
#     netfilter extras) + legacy SYSVIPC kABI patch
#   * v1.2 CRC-SAFE additions only (pure new code, no core-struct changes):
#     nftables, socket diag, NFS/9P/BTRFS, BBR/CAKE/ZSWAP, RNDIS gadget,
#     USB serial / CDC / usbnet host / BT-USB drivers
#   * VARIANT=baseline -> build the exact v1.0 config (CRC reference)
#   * VARIANT=v12      -> build the candidate fragment (default)
#   * vendor module-signing public cert embedded (legacy/certs/nubia-signing-key-a14.pem)
#   * MODULE_SIG_PROTECT disabled, TRIM_UNUSED_KSYMS off
#   * exact stock version string, AOSP clang r487747c
#
# NEVER enable CONFIG_CFS_BANDWIDTH or CONFIG_CGROUP_PIDS: both change exported
# symbol CRCs and the stock vendor modules refuse to load (endless reboot).
#
set -e

VARIANT=${VARIANT:-v12}
WORK=${WORK:-$PWD/work-a14-$VARIANT}
OUT=${OUT:-$PWD/out-a14-$VARIANT}
ACK_COMMIT=716498f88d0f
KVER_STRING="-android14-11-g716498f88d0f-ab11695701"
REPO_DIR=$(cd "$(dirname "$0")" && pwd)
STOCK_CONFIG="$REPO_DIR/legacy/nx721j-a14-stock.config"
if [ "$VARIANT" = "baseline" ]; then
  FRAGMENT="$REPO_DIR/config.fragment"      # exact v1.0 config (CRC reference)
else
  FRAGMENT="$REPO_DIR/config.fragment.a14"  # v1.2 candidate
fi
PATCH="$REPO_DIR/legacy/001.GKI-below-6.12-fix_sysvipc_kabi_3_4_5.patch"
CERT="$REPO_DIR/legacy/certs/nubia-signing-key-a14.pem"
JOBS=${JOBS:-$(nproc)}
export ARCH=arm64
export LLVM=1

mkdir -p "$WORK" "$OUT"

# ---------------------------------------------------------------- source
if [ ! -d "$WORK/ack" ]; then
  mkdir -p "$WORK/ack"
  ACK_OK=0
  for attempt in 1 2 3 4 5; do
    echo "=== downloading ACK archive (attempt $attempt) ==="
    rm -f "$WORK/ack.tar.gz"
    if curl -L --retry 3 --retry-delay 5 -o "$WORK/ack.tar.gz" \
         "https://android.googlesource.com/kernel/common/+archive/$ACK_COMMIT.tar.gz" \
       && tar tzf "$WORK/ack.tar.gz" > /dev/null 2>&1; then
      ACK_OK=1
      break
    fi
    sleep 10
  done
  [ "$ACK_OK" = "1" ] || { echo "ACK archive download failed"; exit 1; }
  tar xzf "$WORK/ack.tar.gz" -C "$WORK/ack"
fi
cd "$WORK/ack"

# keep the exact stock version string: no '+' suffix from setlocalversion
echo -n "" > .scmversion

# ---------------------------------------------------------------- host-tool compat
# ubuntu-24.04 runners ship glibc >= 2.38, whose string.h is const-correct for
# strchr(). The 6.1.68 copy of tools/lib/bpf trips -Werror with clang 17.
# This only affects the host helper (resolve_btfids), never the kernel Image.
if grep -q "next_path = strchr(s, ':');" tools/lib/bpf/libbpf.c 2>/dev/null; then
  sed -i "s|next_path = strchr(s, ':');|next_path = (char *)strchr(s, ':');|" tools/lib/bpf/libbpf.c
  echo "=== patched libbpf strchr const-cast ==="
fi
if grep -q 'override CFLAGS += -Werror -Wall' tools/lib/bpf/Makefile 2>/dev/null; then
  sed -i 's|override CFLAGS += -Werror -Wall|override CFLAGS += -Wall|' tools/lib/bpf/Makefile
  echo "=== relaxed -Werror for host libbpf build ==="
fi

# ---------------------------------------------------------------- config
echo "=== base config = phone stock config (MyOS 14.5.6MR2 / Android 14) ==="
cp "$STOCK_CONFIG" .config
echo "=== merging v1.1 fragment ==="
cat "$FRAGMENT" >> .config

echo "=== applying SYSVIPC kABI patch (6.1.68) ==="
patch -p1 < "$PATCH"

sed -i "s|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION=\"$KVER_STRING\"|" .config
sed -i 's|^CONFIG_LOCALVERSION_AUTO=.*|# CONFIG_LOCALVERSION_AUTO is not set|' .config
sed -i 's|^CONFIG_TRIM_UNUSED_KSYMS=.*|# CONFIG_TRIM_UNUSED_KSYMS is not set|' .config

# Vendor modules are signed with nubia's key: disable protected-symbol
# enforcement and trust the vendor's public module-signing certificate.
sed -i 's|^CONFIG_MODULE_SIG_PROTECT=.*|# CONFIG_MODULE_SIG_PROTECT is not set|' .config
sed -i "s|^CONFIG_SYSTEM_TRUSTED_KEYS=.*|CONFIG_SYSTEM_TRUSTED_KEYS=\"$CERT\"|" .config

make -j"$JOBS" ARCH=arm64 LLVM=1 LOCALVERSION= olddefconfig

echo "=== verify required options ==="
grep -E '^CONFIG_(SYSVIPC|IPC_NS|PID_NS|DEVTMPFS|POSIX_MQUEUE|USER_NS)=' .config || true
grep -E '^CONFIG_LOCALVERSION=' .config
grep -E '^# CONFIG_(CFS_BANDWIDTH|CGROUP_PIDS) is not set' .config || true
echo "--- v1.1 features ---"
grep -E '^CONFIG_(NF_TABLES|CGROUP_DEVICE|CHECKPOINT_RESTORE|TCP_CONG_BBR|ZSWAP|SECURITY_YAMA|SECURITY_APPARMOR|USB_CONFIGFS_RNDIS|NFS_FS|9P_FS|BTRFS_FS)=' .config || true

echo "=== building Image ==="
make -j"$JOBS" ARCH=arm64 LLVM=1 LOCALVERSION= Image

# Module.symvers (the per-symbol CRC table) is produced by the modpost stage,
# which only runs when the module target is built. Build the modules too so the
# CRC guard has real data to compare.
echo "=== building modules (produces Module.symvers for the CRC guard) ==="
make -j"$JOBS" ARCH=arm64 LLVM=1 LOCALVERSION= modules

cp arch/arm64/boot/Image "$OUT/Image"
cp Module.symvers "$OUT/Module.symvers"
echo "=== done: $OUT/Image ($(stat -c%s "$OUT/Image") bytes) ==="
echo "=== symvers: $OUT/Module.symvers ($(wc -l < "$OUT/Module.symvers") exported symbols) ==="
ls -la "$OUT/Image"
strings "$OUT/Image" | grep -m1 'SMP preempt mod_unload'
