#!/bin/bash
# patch-initrd.sh — Proxmox VE 9.2 initrd をパッチして PXE ブート可能にする
#
# 使い方:
#   ./scripts/patch-initrd.sh <initrd-path> [output-path]
#
# 例:
#   ./scripts/patch-initrd.sh /path/to/proxmox-ve_9.2-1/initrd
#   ./scripts/patch-initrd.sh /path/to/initrd /path/to/initrd.patched
#
# 前提条件:
#   - zstd, cpio, fdisk, mkfs.ext2 がホストに存在すること
#   - Bootimus コンテナ内で実行する場合、これらがコンテナ内にインストールされていること

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH_DIR="${SCRIPT_DIR}/../patches"
WORK_DIR=$(mktemp -d)
INITRD_SRC="${1:?Usage: $0 <initrd-path> [output-path]}"
INITRD_OUT="${2:-${INITRD_SRC}.patched}"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

echo "=== Proxmox VE 9.2 PXE initrd patcher ==="
echo "Source:  $INITRD_SRC"
echo "Output:  $INITRD_OUT"
echo "Work:    $WORK_DIR"
echo

# 1. initrd を展開
echo "[1/4] Extracting initrd..."
INITRD_DIR="${WORK_DIR}/initrd"
mkdir -p "$INITRD_DIR"
cd "$INITRD_DIR"

# zstd で解凍して cpio を展開
zstd -d "$INITRD_SRC" -o "${WORK_DIR}/initrd.cpio" --rm 2>/dev/null || \
zstd -d "$INITRD_SRC" -o "${WORK_DIR}/initrd.cpio"
cpio -idm < "${WORK_DIR}/initrd.cpio" 2>/dev/null
rm -f "${WORK_DIR}/initrd.cpio"

echo "  init size: $(wc -c < init) bytes"
echo "  init perms: $(ls -la init | awk '{print $1}')"

# 2. パッチを適用
echo "[2/4] Applying patches..."
PATCH_FILE="${PATCH_DIR}/init.patch"

if [ ! -f "$PATCH_FILE" ]; then
    echo "ERROR: Patch file not found: $PATCH_FILE"
    exit 1
fi

# パッチのパスを調整して適用
sed "s|--- /tmp/original_init.txt.*|--- a/init|;s|+++ /tmp/final_init.txt.*|+++ b/init|" \
    "$PATCH_FILE" | patch -p1 --no-backup-if-mismatch

echo "  Patched init size: $(wc -c < init) bytes"

# 3. init の権限を修正
echo "[3/4] Fixing permissions..."
chmod 755 init
echo "  init perms: $(ls -la init | awk '{print $1}')"

# 4. initrd を再圧縮
echo "[4/4] Repacking initrd..."
cd "$INITRD_DIR"
find . | cpio -o -H newc 2>/dev/null | zstd -15 > "$INITRD_OUT"

echo
echo "=== Done ==="
echo "Patched initrd: $INITRD_OUT ($(ls -lh "$INITRD_OUT" | awk '{print $5}'))"
echo
echo "Next steps:"
echo "  1. Copy $INITRD_OUT to Bootimus: /data/isos/<image>/initrd"
echo "  2. Set boot_params in Bootimus admin UI:"
echo "     initrd=initrd boot=live priority=critical ip=dhcp fetch=http://<bootimus-ip>:8080/isos/<image>.iso console=ttyS0"
echo "  3. Create VM with e1000 NIC, UEFI boot, serial0: socket, vga: serial0"
