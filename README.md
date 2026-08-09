# proxmox-pxe-initrd-patch

Proxmox VE 9.2 の initrd にパッチを当てて、Bootimus 経由の PXE ネットワークインストールを可能にするスクリプト群。

## 背景

Bootimus（iPXE メニューサーバー）を使って Proxmox VE を PXE インストールする場合、以下の問題がある：

1. **`/bin/ip` が存在しない** — Proxmox の initrd 内では `ip` コマンドは `/sbin/ip` に存在する
2. **initrd の tmpfs が小さすぎる** — 1.7GB の ISO イメージをダウンロードするのに tmpfs では容量不足
3. **`udhcpc` の出力が見えない** — `-q` フラグでログが抑制され、デバッグが困難

このリポジトリは上記3点を修正する。

## 修正内容

| # | 問題 | 修正 |
|---|------|------|
| 1 | `/bin/ip` が存在しない | 全ての `/bin/ip` を `/sbin/ip` に置換 |
| 2 | initrd tmpfs に ISO が収まらない | `/dev/sda` に ext2 パーティションを作成してダウンロード先に利用 |
| 3 | `udhcpc` のログが見えない | `-q` フラグを除去、終了コードを出力 |

### 修正の概要

```
┌─────────────────────────────────────────────────────────┐
│  修正前 (Proxmox 元 init)                               │
│                                                         │
│  udhcpc -i eth0 -n -q -t 3 2>/dev/null  ← ハングする  │
│  /bin/ip addr add ...                     ← 存在しない  │
│  wget -O /proxmox.iso ...                 ← tmpfs 溢流  │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  修正後                                                  │
│                                                         │
│  udhcpc -i eth0 -n -t 3                   ← ログ出力有  │
│  /sbin/ip addr add ...                     ← パス修正    │
│  fdisk /dev/sda + mkfs.ext2               ← disk利用    │
│  wget -O /iso_disk/proxmox.iso ...        ← disk DL     │
└─────────────────────────────────────────────────────────┘
```

## 使い方

### 前提条件

- Bootimus コンテナ内で `zstd`, `cpio`, `fdisk`, `mkfs.ext2` が利用可能であること
- Proxmox VE 9.2 の ISO が Bootimus にアップロード済みであること

### 方法1: スクリプトを使う

```bash
# パッチ済み initrd を作成
./scripts/patch-initrd.sh /data/isos/proxmox-ve_9.2-1/initrd

# 出力: /data/isos/proxmox-ve_9.2-1/initrd.patched
```

### 方法2: 手動でパッチを適用

```bash
# initrd を展開
mkdir -p /tmp/initrd-mod && cd /tmp/initrd-mod
zstd -d /data/isos/proxmox-ve_9.2-1/initrd -o initrd.cpio
cpio -idm < initrd.cpio

# パッチを適用
patch -p1 < /path/to/patches/init.patch

# 権限修正 + 再圧縮
chmod 755 init
find . | cpio -o -H newc | zstd -15 > /data/isos/proxmox-ve_9.2-1/initrd
```

## ディレクトリ構成

```
proxmox-pxe-initrd-patch/
├── README.md              # このファイル
├── scripts/
│   └── patch-initrd.sh    # initrd をパッチするスクリプト
└── patches/
    ├── init.patch          # unified diff パッチ
    ├── init-original.sh    # 元の init スクリプト（参照用）
    └── init-patched.sh     # パッチ後の init スクリプト（参照用）
```

## Bootimus の設定

パッチ済み initrd をデプロイした後、Bootimus の管理 UI で boot_params を設定する：

```
initrd=initrd boot=live priority=critical ip=dhcp fetch=http://<bootimus-ip>:8080/isos/proxmox-ve_9.2-1.iso console=ttyS0
```

## VM の要件

| 項目 | 設定 |
|------|------|
| NIC | **e1000**（virtio ではドライバー不足） |
| ブート | UEFI |
| VGA | `serial0` |
| serial0 | `socket` |
| ディスク | 32GB 以上（ISO ダウンロードに一時利用） |

## 動作確認

```bash
# VM 起動後、DHCP で IP を取得し ISO をダウンロードする
qm start <vmid>

# Bootimus のログで確認
docker logs <bootimus-container> --since 60s | grep "ISO Download"

# VM に ping が通ることを確認
ping <vm-ip>
```

## 注意事項

- `/dev/sda` は ISO ダウンロードの一時保存先として使用される。Proxmox インストーラーは後にディスクを再パーティションするため、問題ない
- 静的 IP フォールバックのアドレス (`192.168.0.2`) は環境に合わせて `patches/init.patch` を修正すること
- e1000 ドライバーが initrd に含まれていない場合は、Proxmox ISO 内の squashfs から抽出して追加が必要
