#!/bin/bash
#
# Build a Droidspaces-capable GKI kernel for the nubia NX721J (Z60 Ultra, sm8650).
#
# Strategy (same as the proven NX729J recipe):
#   * use the exact ACK commit the phone's stock kernel was built from
#   * use the phone's own /proc/config.gz as the base config
#   * add only the options Droidspaces needs, with the official kABI patch
#   * keep the exact stock version string so vendor_dlkm modules keep loading
#
set -e

WORK=${WORK:-$PWD/work}
OUT=${OUT:-$PWD/out}
ACK_COMMIT=716498f88d0f
REPO_DIR=$(cd "$(dirname "$0")" && pwd)
STOCK_CONFIG="$REPO_DIR/nx721j-stock.config"
FRAGMENT=${FRAGMENT:-$REPO_DIR/config.fragment}
PATCH_VARIANT=${PATCH_VARIANT:-1_2_3}
PATCH="$REPO_DIR/patches/001.GKI-below-6.12-fix_sysvipc_kabi_${PATCH_VARIANT}.patch"
JOBS=${JOBS:-$(nproc)}
export ARCH=arm64
export LLVM=1

mkdir -p "$WORK" "$OUT"
cd "$WORK"

# ------------------------------------------------------------------ source
if [ ! -d "$WORK/ack" ]; then
  echo "=== fetching ACK @ $ACK_COMMIT ==="
  mkdir -p "$WORK/ack"
  curl -L --retry 3 -o "$WORK/ack.tar.gz" \
    "https://android.googlesource.com/kernel/common/+archive/$ACK_COMMIT.tar.gz"
  tar xzf "$WORK/ack.tar.gz" -C "$WORK/ack"
fi
cd "$WORK/ack"

# suppress the trailing '+' that setlocalversion adds when the tree sits inside
# another git checkout: an empty .scmversion and LOCALVERSION= keep the exact
# stock version string so vendor_dlkm modules keep loading.
echo -n "" > .scmversion

# ------------------------------------------------- stock config as base
echo "=== base config = phone stock config ==="
cp "$STOCK_CONFIG" .config
echo "=== merging Droidspaces fragment ==="
cat "$FRAGMENT" >> .config

# ------------------------------------------------------- kABI patch
echo "=== applying SYSVIPC kABI patch ==="
patch -p1 < "$PATCH"

# keep the exact stock version string / don't trim ksyms
sed -i 's|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION="-android14-11-g716498f88d0f-ab11695701"|' .config
sed -i 's|^CONFIG_LOCALVERSION_AUTO=.*|# CONFIG_LOCALVERSION_AUTO is not set|' .config
sed -i 's|^CONFIG_TRIM_UNUSED_KSYMS=.*|# CONFIG_TRIM_UNUSED_KSYMS is not set|' .config
# Vendor modules are signed with nubia's key; MODULE_SIG_PROTECT would reject
# their protected symbol exports (EACCES) and the system would hang at boot.
sed -i 's|^CONFIG_MODULE_SIG_PROTECT=.*|# CONFIG_MODULE_SIG_PROTECT is not set|' .config

make -j"$JOBS" ARCH=arm64 LLVM=1 LOCALVERSION= olddefconfig

echo "=== verify required options ==="
grep -E '^CONFIG_(SYSVIPC|IPC_NS|PID_NS|DEVTMPFS|POSIX_MQUEUE)=' .config || true
grep -E '^CONFIG_LOCALVERSION=' .config

echo "=== building Image ==="
make -j"$JOBS" ARCH=arm64 LLVM=1 LOCALVERSION= Image

cp arch/arm64/boot/Image "$OUT/Image"
echo "=== DONE: $OUT/Image ==="
ls -la "$OUT/Image"
