#!/bin/bash
#
# Build a Droidspaces-capable GKI kernel for the nubia NX721J (Z60 Ultra, sm8650).
#
# Recipe:
#   * ACK android14-6.1 at the exact commit the stock kernel was built from
#   * the phone's own /proc/config.gz as the base config
#   * Droidspaces options + the official SYSVIPC kABI patch (3_4_5 variant)
#   * vendor module-signing public cert embedded (extracted from stock kernel)
#   * MODULE_SIG_PROTECT disabled, TRIM_UNUSED_KSYMS off
#   * exact stock version string, AOSP clang r487747c
#
# NEVER enable CONFIG_CFS_BANDWIDTH or CONFIG_CGROUP_PIDS: both change exported
# symbol CRCs and the stock vendor modules refuse to load (endless reboot).
#
set -e

WORK=${WORK:-$PWD/work}
OUT=${OUT:-$PWD/out}
ACK_COMMIT=716498f88d0f
REPO_DIR=$(cd "$(dirname "$0")" && pwd)
STOCK_CONFIG="$REPO_DIR/nx721j-stock.config"
FRAGMENT="$REPO_DIR/config.fragment"
PATCH_VARIANT=${PATCH_VARIANT:-3_4_5}
PATCH="$REPO_DIR/patches/001.GKI-below-6.12-fix_sysvipc_kabi_${PATCH_VARIANT}.patch"
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
echo "=== base config = phone stock config ==="
cp "$STOCK_CONFIG" .config
echo "=== merging Droidspaces fragment ==="
cat "$FRAGMENT" >> .config

case "${ENHANCE:-0}" in
  net) echo "=== merging net fragment ==="; cat "$REPO_DIR/config-net.fragment" >> .config ;;
  n1)  echo "=== merging n1 fragment ===";  cat "$REPO_DIR/config-n1.fragment" >> .config ;;
  n2)  echo "=== merging n2 fragment ===";  cat "$REPO_DIR/config-n2.fragment" >> .config ;;
  n3)  echo "=== merging n3 fragment ===";  cat "$REPO_DIR/config-n3.fragment" >> .config ;;
  fs)  echo "=== merging fs fragment ===";  cat "$REPO_DIR/config-fs.fragment" >> .config ;;
  sec) echo "=== merging sec fragment ==="; cat "$REPO_DIR/config-sec.fragment" >> .config ;;
  1)   echo "=== merging enhancement fragment ==="; cat "$REPO_DIR/config-enhance.fragment" >> .config ;;
esac

echo "=== applying SYSVIPC kABI patch ($PATCH_VARIANT) ==="
patch -p1 < "$PATCH"

sed -i 's|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION="-android14-11-g716498f88d0f-ab11695701"|' .config
sed -i 's|^CONFIG_LOCALVERSION_AUTO=.*|# CONFIG_LOCALVERSION_AUTO is not set|' .config
sed -i 's|^CONFIG_TRIM_UNUSED_KSYMS=.*|# CONFIG_TRIM_UNUSED_KSYMS is not set|' .config

# The vendor modules are signed with nubia's key: disable the protected-symbol
# enforcement and trust the vendor's public module-signing certificate.
sed -i 's|^CONFIG_MODULE_SIG_PROTECT=.*|# CONFIG_MODULE_SIG_PROTECT is not set|' .config
sed -i "s|^CONFIG_SYSTEM_TRUSTED_KEYS=.*|CONFIG_SYSTEM_TRUSTED_KEYS=\"$REPO_DIR/certs/nubia-signing-key.pem\"|" .config

# two passes: some options (NF_TABLES_*, NFT_*) only become visible once
# their parent symbol is resolved in the first pass
make -j"$JOBS" ARCH=arm64 LLVM=1 LOCALVERSION= olddefconfig
make -j"$JOBS" ARCH=arm64 LLVM=1 LOCALVERSION= olddefconfig

case "${ENHANCE:-0}" in
  net) ENH_FRAG="$REPO_DIR/config-net.fragment" ;;
  n1)  ENH_FRAG="$REPO_DIR/config-n1.fragment" ;;
  n2)  ENH_FRAG="$REPO_DIR/config-n2.fragment" ;;
  n3)  ENH_FRAG="$REPO_DIR/config-n3.fragment" ;;
  fs)  ENH_FRAG="$REPO_DIR/config-fs.fragment" ;;
  sec) ENH_FRAG="$REPO_DIR/config-sec.fragment" ;;
  1)   ENH_FRAG="$REPO_DIR/config-enhance.fragment" ;;
  *)   ENH_FRAG="" ;;
esac
if [ -n "$ENH_FRAG" ]; then
  echo "=== verify enhancement options (dropped ones will be listed) ==="
  grep -E '^CONFIG_[A-Z0-9_]+=y' "$ENH_FRAG" | sed 's/=y//' | while read -r opt; do
    if ! grep -qE "^$opt=y" .config; then echo "  MISSING: $opt"; fi
  done
fi

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
