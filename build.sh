#!/bin/bash
#
# Build a Droidspaces-capable GKI kernel for the nubia NX721J (Z60 Ultra, sm8650).
#
# Target system: NebulaOS 2.0.8 (Android 16), kernel 6.1.145-android14-11-g11c274d0441f-ab14259673
#
# Recipe:
#   * ACK android14-6.1 at the exact commit the vendor kernel was built from
#   * the device's own /proc/config.gz as the base config
#   * Droidspaces options + a rebased SYSVIPC kABI patch (ABI padding in struct task_struct)
#   * vendor module-signing public cert embedded (extracted from the NebulaOS boot image)
#   * MODULE_SIG_PROTECT disabled, TRIM_UNUSED_KSYMS off
#   * exact stock version string, AOSP clang r487747c
#
# NEVER enable CONFIG_CFS_BANDWIDTH or CONFIG_CGROUP_PIDS: both change exported
# symbol CRCs and the stock vendor modules refuse to load (endless reboot).
#
set -e

WORK=${WORK:-$PWD/work}
OUT=${OUT:-$PWD/out}
ACK_COMMIT=11c274d0441f
KVER_STRING="-android14-11-g11c274d0441f-ab14259673"
REPO_DIR=$(cd "$(dirname "$0")" && pwd)
STOCK_CONFIG="$REPO_DIR/nx721j-stock.config"
FRAGMENT="$REPO_DIR/config.fragment"
PATCH="$REPO_DIR/patches/001.GKI-6.1.145-fix_sysvipc_kabi.patch"
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

# ---------------------------------------------------------------- config
echo "=== base config = phone stock config (NebulaOS 2.0.8 / Android 16) ==="
cp "$STOCK_CONFIG" .config
echo "=== merging Droidspaces fragment ==="
cat "$FRAGMENT" >> .config

echo "=== applying SYSVIPC kABI patch (6.1.145) ==="
patch -p1 < "$PATCH"

sed -i "s|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION=\"$KVER_STRING\"|" .config
sed -i 's|^CONFIG_LOCALVERSION_AUTO=.*|# CONFIG_LOCALVERSION_AUTO is not set|' .config
sed -i 's|^CONFIG_TRIM_UNUSED_KSYMS=.*|# CONFIG_TRIM_UNUSED_KSYMS is not set|' .config

# The vendor modules are signed with nubia's key: disable the protected-symbol
# enforcement and trust the vendor's public module-signing certificate.
sed -i 's|^CONFIG_MODULE_SIG_PROTECT=.*|# CONFIG_MODULE_SIG_PROTECT is not set|' .config
sed -i "s|^CONFIG_SYSTEM_TRUSTED_KEYS=.*|CONFIG_SYSTEM_TRUSTED_KEYS=\"$REPO_DIR/certs/nubia-signing-key.pem\"|" .config

make -j"$JOBS" ARCH=arm64 LLVM=1 LOCALVERSION= olddefconfig

echo "=== verify required options ==="
grep -E '^CONFIG_(SYSVIPC|IPC_NS|PID_NS|DEVTMPFS|POSIX_MQUEUE|USER_NS)=' .config || true
grep -E '^CONFIG_LOCALVERSION=' .config
grep -E '^# CONFIG_(CFS_BANDWIDTH|CGROUP_PIDS) is not set' .config || true

echo "=== building Image ==="
make -j"$JOBS" ARCH=arm64 LLVM=1 LOCALVERSION= Image

cp arch/arm64/boot/Image "$OUT/Image"
echo "=== done: $OUT/Image ==="
ls -la "$OUT/Image"
strings "$OUT/Image" | grep -m1 'SMP preempt mod_unload'
