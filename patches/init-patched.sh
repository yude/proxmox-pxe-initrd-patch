#!/bin/sh

# (C) 2009-2023 Proxmox Server Solutions GmbH <support@proxmox.com>

export PATH=/sbin:/bin:/usr/bin:/usr/sbin

if [ -f /.cd-info ]; then
    . /.cd-info
else
    # NOTE: the only reason for not exiting now is trying to provide a shell
    # for debugging this mess
    /bin/echo "[ERROR] could not source .cd-info file!"
    /bin/echo "[WARN] trying fallback to PVE, but the installation will likely fail."
    /bin/echo "[WARN] check your installation medium and the downloaded ISO"
    PRODUCT="PVE"
    PRODUCTLONG="Proxmox VE"
    RELEASE="?.?"
fi

PRODUCT_LC="$(echo "$PRODUCT" | tr '[:upper:]' '[:lower:]')"

CDID_FN=".$PRODUCT_LC-cd-id.txt"

# busybox needs full paths until proc is mounted

/bin/echo "Welcome to the $PRODUCTLONG $RELEASE (ISO $ISORELEASE) installer!"
/bin/echo "initial setup startup"

/bin/echo "mounting proc filesystem"
/bin/mount -nt proc proc /proc

echo "mounting sys filesystem"
mount -nt sysfs sysfs /sys
if [ -d /sys/firmware/efi ]; then
    echo "EFI boot mode detected, mounting efivars filesystem"
    mount -nt efivarfs efivarfs /sys/firmware/efi/efivars
fi

# ensure we have a devtmpfs, so that we see the changes from the chroot /dev
# managed by udev here too, and thus normal path look ups on devices are in
# sync from the kernel root POV and the installer (ch)root POV
mount -t devtmpfs devtmpfs /dev

# ensure early that the since 5.15 enabled SYSFB_SIMPLEFB is actually usable
modprobe -q "simplefb"

console=tty1

parse_cmdline() {
    root=
    lvm2root=
    proxdebug=0
    # shellcheck disable=SC2013
    for par in $(cat /proc/cmdline); do
        case $par in
            lvm2root=*)
                lvm2root="${par#lvm2root=}"
            ;;
            root=/dev/mapper/*)
                lvm2root="${par#root=}"
            ;;
            root=*)
                root="${par#root=}"
            ;;
            proxdebug)
                proxdebug=1
            ;;
            console=tty*)
                console="${par#console=}"
                console="${console%%,*}"
                echo "console is $console"
            ;;
        esac
    done;
}

myreboot() {
    echo b > /proc/sysrq-trigger
    echo "rebooting..."
    sleep 100
    exit 0
}

debugsh() {
    setsid sh -c "/bin/sh </dev/$console >/dev/$console 2>&1"
}

debugsh_err_reboot() {
    errmsg=$1

    echo "" # try to make the message stand out more
    echo "[ERROR] $errmsg"
    echo "unable to continue (type exit or CTRL-D to reboot)"
    debugsh
    myreboot
}

echo "boot comandline: $(cat /proc/cmdline)"
parse_cmdline

# use mdev as firmware loader
echo /sbin/mdev >/proc/sys/kernel/hotplug
# initially populate /dev through /sys with cold-plugged devices
/sbin/mdev -s

DRIVERS="msdos isofs"
for mod in $DRIVERS; do
    modprobe -q "$mod"
done

filenames=
# Note: skip filenames with spaces (avoid problems with bash IFS)
# Note: busybox only support -regextype 'posix-basic'
for fn in $(find /sys/devices/* -regex '^[^\ ]*/modalias'); do
    filenames="$filenames $fn"
done

modlist=

load_alias() {
    alias_fn=$1

    alias=$(cat "${alias_fn}")
    if [ -n "$alias" ]; then
        for mod in $(modprobe -q -R "$alias" ); do
            mod_found=0
            for m in $modlist; do
                if [ "$m" = "$mod" ]; then
                    mod_found=1
                fi
            done
            if [ ${mod_found} -eq "0" ]; then
                modlist="$modlist $mod"
            fi
        done
    fi
}

load_mods() {
    class_prefix=$1
    for fn in $filenames; do
        dirname=${fn%/*}
        if [ -n "$class_prefix" ]; then
            if [ -f "$dirname/class" ]; then
                class=$(cat "$dirname/class")
                class=${class:2:8}
                if [ "${class_prefix}" = "${class:0:${#class_prefix}}" ]; then
                    load_alias "$fn"
                fi
            fi
        else
            load_alias "$fn"
        fi
    done
}

# for PCI Device classes and subclasses see linux-src/include/linux/pci_ids.h
# load storage drivers

load_mods  06   # PCI_BASE_CLASS_BRIDGE
load_mods  03   # PCI_BASE_CLASS_DISPLAY

# we try to have a load order, so that /dev/sda is on IDE
load_mods  0101 # PCI_CLASS_STORAGE_IDE
load_mods  0106 # PCI_CLASS_STORAGE_SATA
load_mods  0107 # PCI_CLASS_STORAGE_SAS
load_mods  0100 # PCI_CLASS_STORAGE_SCSI
load_mods  01   # PCI_BASE_CLASS_STORAGE

load_mods  02   # PCI_BASE_CLASS_NETWORK

load_mods # all other

echo "loading drivers: $modlist"

for mod in $modlist; do
    modprobe "$mod"
done

stdmod="usb-storage uas usbhid usbkbd hid_generic mac_hid virtio_blk"
for mod in $stdmod; do
    modprobe "$mod"
done

# we have no iscsi daemon, so we need to scan iscsi device manually.
# else we cant boot from iscsi hba because devices are not detected.
for i in /sys/class/scsi_host/host*; do
    host="${i##*/}"
    if [ -d "$i" ] && [ -f "$i/scan" ] && [ -d "/sys/class/iscsi_host/$host" ] ; then
        echo "Scanning iSCSI $host"
        echo "- - -" > "$i/scan"
    fi
done

if [ -n "$lvm2root" ]; then

    printf '%s' "Finding device mapper major and minor numbers: "

    MAJOR=$(sed -n 's/^ *\([0-9]\+\) \+misc$/\1/p' /proc/devices)
    MINOR=$(sed -n 's/^ *\([0-9]\+\) \+device-mapper$/\1/p' /proc/misc)
    if test -n "$MAJOR" -a -n "$MINOR" ; then
        # shellcheck disable=SC2174
        mkdir -p -m 755 /dev/mapper
        mknod -m 600 /dev/mapper/control c "$MAJOR" "$MINOR"
    fi

    echo "($MAJOR,$MINOR)"

    vg=${lvm2root}
    vg=${vg#/dev/mapper/}
    if [ "$vg" = "$1" ]; then
        echo "activating all volume groups"
        lvm vgchange --ignorelockingfailure -aly
    else
        # Split volume group from logical volume.
        vg=$(echo "${vg}" | sed -e 's#\(.*\)\([^-]\)-[^-].*#\1\2#')
        # Reduce padded --'s to -'s
        vg=$(echo "${vg}" | sed -e 's#--#-#g')
        echo "activating volume group $vg"
        lvm vgchange -aly --ignorelockingfailure "${vg}"
    fi

    echo "create /dev/mapper/ entries using vgscan"
    lvm vgscan --mknodes

    echo "trying to mount lvm root: ($lvm2root)"

    found=
    for try in 5 4 3 2 1; do
        for t in ext4 auto; do
            if mount -n -t $t -r "$lvm2root" /mnt; then
                found=ok
                break;
            fi
        done
        if test -n "$found"; then
            break;
        fi
        if test $try -gt 1; then
            echo "testing again in 5 seconds"
            sleep 5
        fi
    done

elif [ -n "$root" ]; then

    case $root in
        /dev/*)
            real_root=$root
        ;;
        *:*)
            dev_min=$((0x${root#*:}))
            dev_maj=$((0x${root%:*}))
            mknod /tmp/rootdev b $dev_maj $dev_min
            real_root=/tmp/rootdev
        ;;
        *)
            dev_min=$((0x$root & 255))
            dev_maj=$((0x$root >> 8))
            mknod /tmp/rootdev b $dev_maj $dev_min
            real_root=/tmp/rootdev
        ;;
    esac

    echo "trying to mount root: $real_root ($root)"

    found=
    for try in 5 4 3 2 1; do
        for t in ext4 auto; do
            if mount -n -t $t -r $real_root /mnt; then
                found=ok
                break;
            fi
        done
        if test -n "$found"; then
            break;
        fi
        if test $try -gt 1; then
            echo "testing again in 5 seconds"
            sleep 5
        fi
    done

else

    # --- PXE: try to fetch ISO over network ---
    /bin/echo "Attempting to fetch ISO via network..."
    /sbin/ip link set lo up 2>/dev/null
    /sbin/ip addr add 127.0.0.1/8 dev lo 2>/dev/null

    # Explicitly load network drivers for common VM NICs
    /sbin/modprobe -q e1000 2>/dev/null
    /sbin/modprobe -q e1000e 2>/dev/null
    /sbin/modprobe -q r8169 2>/dev/null
    /sbin/modprobe -q virtio_pci 2>/dev/null
    /sbin/modprobe -q virtio_net 2>/dev/null

    # Wait for any network interface to appear (predictable names: ens*, enp*, eth*)
    /bin/echo "Waiting for network interfaces..."
    NET_IF=""
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        for iface in /sys/class/net/eth* /sys/class/net/ens* /sys/class/net/enp* /sys/class/net/enx*; do
            if [ -d "$iface" ] && [ "$(basename $iface)" != "lo" ]; then
                NET_IF="$(basename $iface)"
                break 2
            fi
        done
        sleep 1
    done

    if [ -z "$NET_IF" ]; then
        /bin/echo "[WARN] No network interface found after 10 seconds, skipping fetch"
        /bin/echo "Available /sys/class/net/: $(ls /sys/class/net/ 2>/dev/null)"
    else
        /bin/echo "Found network interface: $NET_IF"
        /sbin/ip link set "$NET_IF" up 2>/dev/null

        # Wait for link to come up
        sleep 2



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
        /bin/echo "Routes: $(/sbin/ip route show 2>&1)"

        if /sbin/ip addr show "$NET_IF" | grep -q "inet "; then
            /bin/echo "Network interface $NET_IF is up: $(/sbin/ip addr show "$NET_IF" | grep 'inet ')"
            # Extract fetch= URL from kernel parameters
            FETCH_URL=""
            for par in $(cat /proc/cmdline); do
                case $par in
                    fetch=*)
                        FETCH_URL="${par#fetch=}"
                        ;;
                esac
            done

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
        else
            /bin/echo "[WARN] Network interface $NET_IF has no IP, skipping fetch"
        fi
    fi
    # --- End PXE fetch ---

    cdrom=

    initrdisoimage="/proxmox.iso"

    if [ -f $initrdisoimage ]; then
        # this is useful for PXE boot
        echo "found proxmox ISO image inside initrd image"
        if mount -t iso9660 -o loop,ro $initrdisoimage /mnt >/dev/null 2>&1; then
            cdrom=$initrdisoimage
        fi
    else
        echo "searching for block device containing the ISO $ISONAME-$RELEASE-$ISORELEASE"
        reqid="$(cat "/$CDID_FN")"
        echo "with ISO ID '$reqid'"
        delay=1 # start out with a relatively short delay, often devices get ready quite quickly
        for try in $(seq 1 9); do # 9 tries, each one second more sleep -> 45s total
            for i in /sys/block/hd* /sys/block/sr* /sys/block/scd* /sys/block/sd* /sys/block/nvme*; do
                # don't try to mount /all/ devices, as it produces IO, as a heuristic check all
                # those which are removable and all those which are of type iso9660 (we can mount
                # only those anyway) and those which have it's main partition < 1 GiB (ISO has
                # normally 750MiB) this also gets USB sticks on strange systems where the firmware
                # says it's not removable...
                if [ -d "$i" ]; then
                    basedev="${i##*/}"
                    path="/dev/$basedev"
                    size="$(cat "$i/size")"

                    if [ "$(cat "$i/removable")" = 1 ] ||
                         blkid "$path" | grep -q ' TYPE="iso9660"' ||
                       [ "$size" -lt $(( 1024 * 1024 * 65 )) ]
                    then
                        echo "testing device '$path' for ISO"
                        if mount -t iso9660 -o ro "$path" /mnt >/dev/null 2>&1; then
                            if [ -r "/mnt/$CDID_FN" ] && [ "X$(cat "/mnt/$CDID_FN")" = "X$reqid" ]; then
                                echo "found $PRODUCTLONG ISO"
                                cdrom=$path
                                break
                            else
                                echo "found ISO9660 FS but no, or wrong proxmox cd-id, skipping"
                            fi
                            umount /mnt
                        fi
                    else
                        {
                            echo "dev $i neither removable, nor type 'iso9660' nor smallish, skipping ISO check";
                            echo "  removable: $(cat "$i/removable"), size: $size, blkid: $(blkid "$path")";
                        } >> skipped-devs.txt
                    fi
                fi
            done
            if test -n "$cdrom"; then
                break;
            fi
            if test $try -gt 1; then
                echo "testing again in $delay seconds"
                sleep "$delay"
                # gradually increase sleeps, as HW is either ready quickly or needs tens of seconds
                delay=$((delay + 1))
            fi
        done
    fi

    if [ -z "$cdrom" ]; then
        debugsh_err_reboot "no device with valid ISO found, please check your installation medium"
    fi
fi

if [ $proxdebug -ne 0 ]; then
    echo "Debugging mode (type 'exit' or press CTRL-D to continue startup)"
    debugsh
fi

BASE_SQFS="/mnt/$PRODUCT_LC-base.squashfs"
INSTALLER_SQFS="/mnt/$PRODUCT_LC-installer.squashfs"

if [ -f "$INSTALLER_SQFS" ]; then
    # this is a Proxmox XYZ installation CD

    # hostid (gethostid(3)) is used by zfs to identify which system imported a pool last it needs
    # to be present in /etc/hostid before spl.ko is loaded create it in the installer and copy it
    # over to the targetdir after installation
    dd if=/dev/urandom of=/etc/hostid bs=1 count=4 status=none

    echo "preparing installer mount points and working environment"
    if ! mount -t squashfs -o ro,loop "$BASE_SQFS" /mnt/.base; then
        debugsh_err_reboot "mount '$BASE_SQFS' failed"
    fi

    if ! mount -t squashfs -o ro,loop "$INSTALLER_SQFS" /mnt/.installer; then
        debugsh_err_reboot "mount '$INSTALLER_SQFS' failed"
    fi

    if ! mount -t tmpfs tmpfs /mnt/.workdir; then
        debugsh_err_reboot "mount overlay workdir failed"
    fi

    mkdir /mnt/.workdir/work
    mkdir /mnt/.workdir/upper

    if ! mount -t overlay -o lowerdir=/mnt/.installer:/mnt/.base,upperdir=/mnt/.workdir/upper,workdir=/mnt/.workdir/work  none /mnt/.installer-mp; then
        debugsh_err_reboot "mount overlayfs failed"
    fi

    if ! mount --bind /mnt /mnt/.installer-mp/cdrom; then
        debugsh_err_reboot "bind mount cdrom failed"
    fi

    cp /etc/hostid /mnt/.installer-mp/etc/
    cp /.cd-info /mnt/.installer-mp/ || true

    if [ -x "/mnt/.installer-mp/sbin/unconfigured.sh" ]; then
        mount -t devtmpfs devtmpfs /mnt/.installer-mp/dev

        echo "switching root from initrd to actual installation system"
        # and run the installer (via exec, so hand over PID 1)
        # NOTE: the setsid/redirect dance is really required to have job control in debug shells
        if ! exec switch_root -c /dev/console /mnt/.installer-mp /bin/setsid /bin/sh -c "exec /sbin/unconfigured.sh </dev/$console >/dev/$console 2>&1"; then
            debugsh_err_reboot "unable to switch root to installer ($?)"
        fi
        # NOTE: should never be reached
    else
        debugsh_err_reboot "unable to find installer (/sbin/unconfigured.sh)"
    fi

    echo "unexpected return from installer environment, trigger confused reboot now.."
    cd /

    # Send a SIGKILL to all processes, except for init.
    kill -s KILL -1
    sleep 1

    umount /mnt/.installer-mp/cdrom
    umount /mnt/.installer-mp
    umount /mnt/.workdir/
    umount /mnt/.installer
    umount /mnt/.base

    umount -a -l

    myreboot

else
    # or begin normal init for "rescue" boot
    umount /sys
    umount /proc

    exec /sbin/switch_root -c /dev/console /mnt sbin/init
fi
