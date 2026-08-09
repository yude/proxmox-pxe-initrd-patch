# Proxmox VE 9.2 PXE Boot with Bootimus（ネットワークインストール環境の構築）

## 概要

Bootimus（iPXE メニューサーバー）を使って、Proxmox VE 9.2 をネットワーク経由で PXE インストールする環境を構築する手順。

**Bootimus は proxyDHCP のみ稼働**（DHCP サーバーではない）。そのため、インストール対象の VM は静的 IP を手動設定する必要がある。

---

## 前提条件

| 項目 | 値 |
|------|-----|
| Bootimus ホスト | Docker コンテナで稼働（macvlan） |
| Bootimus IP | 192.168.0.2 |
| サブネット | 192.168.0.0/24 |
| DHCP サーバー | **なし**（proxyDHCP のみ） |
| HTTP サーバー | Bootimus 内蔵（:8080） |
| TFTP サーバー | Bootimus 内蔵（:69） |

---

## 手順

### 1. Proxmox ISO イメージを Bootimus にアップロード

Bootimus の管理 UI (`http://<bootimus-ip>:8081`) から Proxmox VE 9.2 の ISO をアップロードする。

ISO は **そのまま配信される**（パッチ不要）。アップロード後、Bootimus が自動的に:
- `kernel`（vmlinuz）と `initrd` を抽出して `/boot/<image>/` に配置
- PXE メニュー項目を生成

### 2. initrd の init スクリプトにパッチを適用

Bootimus コンテナ内で initrd を展開し、`/init` をパッチする。

```bash
# Bootimus コンテナに接続
docker exec -it <bootimus-container-id> sh

# initrd を展開
mkdir -p /tmp/proxmox-initrd-mod
cd /tmp/proxmox-initrd-mod
zstd -d /data/isos/<image>/initrd -o /tmp/initrd.cpio
cpio -idm < /tmp/initrd.cpio
```

### 3. パッチ内容（`/init` スクリプトの修正点）

以下 **3箇所** を修正する：

#### 修正1: `/bin/ip` → `/sbin/ip`

```bash
# 全置換
sed -i 's|/bin/ip |/sbin/ip |g' init
```

**理由**: Proxmox の initrd 内では `ip` コマンドは `/sbin/ip` に存在する。`/bin/ip` は存在しない。

#### 修正2: DHCP ファースト + 静的 IP フォールバック

`/bin/ip` は存在しないため、元コードの DHCP + static IP フォールバックが全て失敗する。
以下に修正:

```bash
# 新コード（DHCP を試行 → 失敗時に静的 IP にフォールバック）

# Try DHCP first
if [ -x /sbin/udhcpc ]; then
    /bin/echo "Requesting DHCP on $NET_IF..."
    /sbin/udhcpc -i "$NET_IF" -n -t 3
    DHCP_RC=$?
    /bin/echo "udhcpc exit code: $DHCP_RC"
else
    /bin/echo "[WARN] udhcpc not found, skipping DHCP"
    DHCP_RC=1
fi

# If DHCP failed, configure static IP
if ! /sbin/ip addr show "$NET_IF" | grep -q "inet "; then
    /bin/echo "DHCP failed, configuring static IP..."
    /sbin/ip addr add 192.168.0.2/24 dev "$NET_IF"
    /sbin/ip route add default via 192.168.0.1 dev "$NET_IF"
    sleep 1
    /bin/echo "Static IP configured: 192.168.0.2/24 gw 192.168.0.1"
fi

/bin/echo "IP config: $(/sbin/ip addr show "$NET_IF" 2>&1)"
/bin/echo "Routes: $(/sbin/ip route show "$NET_IF" 2>&1)"
```

**修正点:**
- `-q`（quiet）を外してログ出力を有効化
- `2>/dev/null` を外してエラーを確認可能に
- DHCP 失敗時にのみ静的 IP にフォールバック
- `udhcpc` の終了コードを出力してデバッグ可能に

#### 修正3: ISO ダウンロード先を disk に変更

initrd の tmpfs は数百MB しか確保できず、1.7GB の ISO が収まらない。
`/dev/sda` にパーティションを作成し、そこに ISO をダウンロードする。

```bash
# 既存コード（削除）
if [ -n "$FETCH_URL" ]; then
    /bin/echo "Downloading ISO from $FETCH_URL to /proxmox.iso"
    /bin/echo "(This may take several minutes for a 1.7GB file...)"
    /bin/echo "Starting download..."
    /usr/bin/wget --tries=3 --timeout=60 -O /proxmox.iso "$FETCH_URL"
    if [ $? -eq 0 ] && [ -s /proxmox.iso ]; then
        /bin/echo "ISO download successful: $(ls -lh /proxmox.iso)"
    else
        /bin/echo "[WARN] Failed to download ISO, removing partial file"
        rm -f /proxmox.iso
    fi
else
    /bin/echo "[WARN] No fetch= parameter found in kernel cmdline"
fi
```

以下に置換:
```bash
# 新コード
if [ -n "$FETCH_URL" ]; then
    # Initramfs tmpfs too small for 1.7GB ISO - use disk
    ISO_TARGET="/proxmox.iso"
    if [ -b /dev/sda ]; then
        /bin/echo "Partitioning /dev/sda for temp ISO storage..."
        echo -e "o\nn\np\n1\n\n\nw" | /sbin/fdisk /dev/sda 2>/dev/null
        /sbin/losetup -d /dev/loop0 2>/dev/null
        sleep 1
        /sbin/mkfs.ext2 -F /dev/sda1 2>/dev/null
        /bin/mkdir -p /iso_disk
        /bin/mount -t ext2 /dev/sda1 /iso_disk 2>/dev/null
        if [ $? -eq 0 ]; then
            ISO_TARGET="/iso_disk/proxmox.iso"
            /bin/echo "Using disk-backed storage: $ISO_TARGET"
        fi
    fi
    /bin/echo "Downloading ISO from $FETCH_URL to $ISO_TARGET"
    /bin/echo "(This may take several minutes for a 1.7GB file...)"
    /usr/bin/wget --tries=3 --timeout=60 -O "$ISO_TARGET" "$FETCH_URL"
    if [ $? -eq 0 ] && [ -s "$ISO_TARGET" ]; then
        /bin/echo "ISO download successful: $(ls -lh $ISO_TARGET)"
        if [ "$ISO_TARGET" != "/proxmox.iso" ]; then
            /bin/ln -sf "$ISO_TARGET" /proxmox.iso
        fi
    else
        /bin/echo "[WARN] Failed to download ISO, removing partial file"
        rm -f "$ISO_TARGET"
    fi
else
    /bin/echo "[WARN] No fetch= parameter found in kernel cmdline"
fi
```

**注意**: インストール後に Proxmox は `/dev/sda` を再パーティションするため、一時的な使用で問題ない。

### 4. initrd を再圧縮

```bash
cd /tmp/proxmox-initrd-mod
chmod 755 init

# cpio に圧縮 → zstd で圧縮
find . | cpio -o -H newc 2>/dev/null | zstd -15 > /data/isos/<image>/initrd
```

**重要**: `init` ファイルの権限が `755` であることを必ず確認すること。
`644` のままだとカーネルが `Failed to execute /init (error -13)` で失敗する。

### 5. Bootimus の boot_params を設定

Bootimus の管理 UI から、Proxmox イメージの **boot_params** を以下に設定:

```
initrd=initrd boot=live priority=critical ip=dhcp fetch=http://<bootimus-ip>:8080/isos/<image-name>.iso console=ttyS0
```

| パラメータ | 説明 |
|-----------|------|
| `initrd=initrd` | カーネルが initrd をロードするよう指定 |
| `boot=live` | Proxmox のライブブートモード |
| `priority=critical` | インストーラーの優先度設定 |
| `ip=dhcp` | カーネルパラメータ（init 内で静的IPに上書き） |
| `fetch=http://...` | ISO のダウンロード元 URL |
| `console=ttyS0` | シリアルコンソール出力 |

### 6. インストール対象 VM の作成

Proxmox VE 上で VM を作成:

| 設定項目 | 値 |
|---------|-----|
| NIC | **e1000**（virtio ではドライバー不足で起動不可） |
| ブート | UEFI |
| VGA | `serial0` |
| serial0 | `socket` |
| メモリ | 2GB 以上 |
| ディスク | 32GB 以上 |

VM config の例 (`/etc/pve/qemu-server/<vmid>.conf`):
```
boot: order=net0
cores: 2
cpu: host
efidisk0: local-lvm:vm-900-disk-0,efitype=4m,pre-enrolled-keys=1
memory: 2048
name: pxe-test
net0: e1000=BC:24:11:4E:07:40,bridge=vmbr0
scsihw: virtio-scsi-pci
serial0: socket
vga: serial0
```

### 7. 起動と確認

```bash
# VM を起動
qm start <vmid>

# シリアルコンソールを確認
qm terminal <vmid>
```

正常に起動すれば以下のような出力が確認できる:

```
Found network interface: eth0
Configuring static IP on eth0...
Static IP configured: 192.168.0.2/24 gw 192.168.0.1
Using disk-backed storage: /iso_disk/proxmox.iso
Downloading ISO from http://192.168.0.2:8080/isos/... to /iso_disk/proxmox.iso
ISO download successful: ...
found proxmox ISO image inside initrd image
preparing installer mount points and working environment
switching root from initrd to actual installation system
Starting the installer GUI - see tty2 (CTRL+ALT+F2) for any errors...
```

---

## トラブルシューティング

### `Failed to execute /init (error -13)`
- `init` ファイルの権限が `755` でない → `chmod 755 init` 後に再圧縮

### `modprobe: FATAL: Module shpchp not found`
- 無視して良い。非必須モジュール。

### `e1000` ドライバーが見つからない
- initrd に `e1000.ko` と `mii.ko` が含まれていない。Proxmox ISO 内の squashfs から抽出して追加:

```bash
# Proxmox ISO をマウントして squashfs を展開
mount -o loop proxmox-ve_9.2-1.iso /mnt/iso
mkdir /tmp/squash
mount -o loop,ro /mnt/iso/pve-installer.squashfs /tmp/squash

# e1000.ko を initrd にコピー
cp /tmp/squash/lib/modules/*/kernel/drivers/net/ethernet/intel/e1000/e1000.ko \
   /tmp/proxmox-initrd-mod/lib/modules/7.0.2-6-pve/kernel/drivers/net/ethernet/intel/e1000/
cp /tmp/squash/lib/modules/*/kernel/drivers/net/mii.ko \
   /tmp/proxmox-initrd-mod/lib/modules/7.0.2-6-pve/kernel/drivers/net/mii.ko

# modules.alias と modules.dep もコピー
cp /tmp/squash/lib/modules/*/modules.alias \
   /tmp/proxmox-initrd-mod/lib/modules/7.0.2-6-pve/
cp /tmp/squash/lib/modules/*/modules.dep \
   /tmp/proxmox-initrd-mod/lib/modules/7.0.2-6-pve/

# カーネルバージョンを確認して上記パスを調整
```

### VM がネットワークに到達できない
- NIC が **e1000** であることを確認（virtio はドライバー不足）
- Bootimus の proxyDHCP が稼働していることを確認

### シリアルコンソールに接続できない
- VM config で `vga: serial0` と `serial0: socket` を設定
- `qm terminal <vmid>` で接続

---

## アーキテクチャ図

```
┌──────────────────────────────────────────────────────────────┐
│                     PXE Boot Flow                            │
│                                                              │
│  VM (PXE)                        Bootimus (192.168.0.2)   │
│  ┌─────────┐   DHCP/ProxyDHCP   ┌──────────┐               │
│  │ iPXE    │◄───────────────────│ :67 UDP  │               │
│  │         │   TFTP             │ :4011    │               │
│  │         │◄───────────────────│ :69 UDP  │               │
│  │         │   kernel+initrd    │          │               │
│  │         │◄───────────────────│          │               │
│  └────┬────┘                    │          │               │
│       │                         │          │               │
│  ┌────▼────┐   HTTP GET ISO     │          │               │
│  │ Linux   │───────────────────►│ :8080 TCP│               │
│  │ kernel  │   (1.7GB)          │          │               │
│  │         │                    └──────────┘               │
│  │ +init   │                                               │
│  │ (static │   ┌──────────┐                                │
│  │  IP)    │   │ /dev/sda │ (ISO ダウンロード先)           │
│  │         │   │ ext2     │                                │
│  └────┬────┘   └──────────┘                                │
│       │                                                     │
│  ┌────▼──────────────┐                                     │
│  │ Proxmox Installer │                                     │
│  │ (switch_root)     │                                     │
│  └───────────────────┘                                     │
└──────────────────────────────────────────────────────────────┘
```
