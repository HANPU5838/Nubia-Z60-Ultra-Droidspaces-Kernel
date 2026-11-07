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

# suppress the trailing '+' that setlocalversion adds when the tree sits inside
# another git checkout: an empty .scmversion and LOCALVERSION= keep the exact
# stock version string so vendor_dlkm modules keep loading.
echo -n "" > .scmversion

# ------------------------------------------------- stock config as base
echo "=== base config = phone stock config ==="
cp "$STOCK_CONFIG" .config
echo "=== merging Droidspaces fragment ==="
cat "$FRAGMENT" >> .config

if [ "${NET_HUNTER:-0}" = "1" ]; then
  echo "=== merging NetHunter fragment ==="
  cat "$REPO_DIR/config-nethunter.fragment" >> .config
fi

# ------------------------------------------------------- kABI patch
echo "=== applying SYSVIPC kABI patch ==="
patch -p1 < "$PATCH"

if [ "${CRC_BYPASS:-0}" = "1" ]; then
  echo "=== applying CRC tolerance patch ==="
  patch -p1 < "$REPO_DIR/patches/002-tolerate-crc-drift.patch"
fi

# keep the exact stock version string / don't trim ksyms
sed -i 's|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION="-android14-11-g716498f88d0f-ab11695701"|' .config
sed -i 's|^CONFIG_LOCALVERSION_AUTO=.*|# CONFIG_LOCALVERSION_AUTO is not set|' .config
sed -i 's|^CONFIG_TRIM_UNUSED_KSYMS=.*|# CONFIG_TRIM_UNUSED_KSYMS is not set|' .config
# Vendor modules are signed with nubia's key; MODULE_SIG_PROTECT would reject
# their protected symbol exports (EACCES) and the system would hang at boot.
sed -i 's|^CONFIG_MODULE_SIG_PROTECT=.*|# CONFIG_MODULE_SIG_PROTECT is not set|' .config

# Trust the vendor's public module-signing certificate (extracted from the stock
# kernel image) so the GKI-signed vendor modules verify instead of tainting.
sed -i "s|^CONFIG_SYSTEM_TRUSTED_KEYS=.*|CONFIG_SYSTEM_TRUSTED_KEYS=\"$REPO_DIR/certs/nubia-signing-key.pem\"|" .config

# Optional single-feature experiments (ENABLE_CFS / ENABLE_PIDS); both off by
# default because enabling them changes exported symbol CRCs and the stock
# vendor modules then refuse to load (bootloop).
if [ "${ENABLE_CFS:-0}" = "1" ]; then
  sed -i 's|^# CONFIG_CFS_BANDWIDTH is not set|CONFIG_CFS_BANDWIDTH=y|' .config
fi
if [ "${ENABLE_PIDS:-0}" = "1" ]; then
  sed -i 's|^# CONFIG_CGROUP_PIDS is not set|CONFIG_CGROUP_PIDS=y|' .config
fi

make -j"$JOBS" ARCH=arm64 LLVM=1 LOCALVERSION= olddefconfig

echo "=== verify required options ==="
grep -E '^CONFIG_(SYSVIPC|IPC_NS|PID_NS|DEVTMPFS|POSIX_MQUEUE)=' .config || true
grep -E '^CONFIG_LOCALVERSION=' .config

echo "=== building Image ==="
make -j"$JOBS" ARCH=arm64 LLVM=1 LOCALVERSION= Image

if [ "${NET_HUNTER:-0}" = "1" ]; then
  echo "=== building NetHunter wireless modules ==="
  mkdir -p "$OUT/modules"
  for t in \
    drivers/net/wireless/ath/ath.ko \
    drivers/net/wireless/ath/ath9k/ath9k_htc.ko \
    drivers/net/wireless/ath/carl9170/carl9170.ko \
    drivers/net/wireless/ralink/rt2x00/rt2x00lib.ko \
    drivers/net/wireless/ralink/rt2x00/rt2x00usb.ko \
    drivers/net/wireless/ralink/rt2x00/rt2800usb.ko \
    drivers/net/wireless/mediatek/mt7601u/mt7601u.ko \
    drivers/net/wireless/realtek/rtl8xxxu/rtl8xxxu.ko \
    drivers/net/wireless/intersil/p54/p54usb.ko \
    drivers/net/wireless/zydas/zd1211rw/zd1211rw.ko ; do
    make -j"$JOBS" ARCH=arm64 LLVM=1 LOCALVERSION= "$t" || echo "  (skip $t)"
  done
  find drivers/net/wireless -name '*.ko' -exec cp {} "$OUT/modules/" \; 2>/dev/null || true
  echo "modules built:"; ls -la "$OUT/modules" 2>/dev/null || true
fi

cp arch/arm64/boot/Image "$OUT/Image"
echo "=== DONE: $OUT/Image ==="
ls -la "$OUT/Image"
