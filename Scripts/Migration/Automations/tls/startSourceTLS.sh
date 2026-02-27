#!/bin/bash

VM="$1"
SIZE="$2"
CORES="$3"
TAP="$4"

CERT_DIR="/etc/pki/qemu"

if test -d /sys/class/net/$TAP; then
    printf ">>> Tap Device %s Already in Use\n" $TAP
else
    ip tuntap add dev $TAP mode tap
    ip link set dev $TAP master br0
    ip link set dev $TAP up
fi

echo ">>> Starting VM in Source with TLS support"

sudo /mnt/nfs/aamir/Qemu/qemu-8.1.2/qemu-8.1.2/build/qemu-system-x86_64 \
    -name source-tls \
    -smp $CORES \
    -boot c \
    -m $SIZE \
    -vnc :2 \
    -drive file=/mnt/nfs/aamir/vm-images/$VM.img,if=virtio \
    -net nic,model=virtio,macaddr=52:54:00:12:34:11 \
    -net tap,ifname=$TAP,script=no,downscript=no \
    -cpu host --enable-kvm \
    -qmp "unix:/media/qmp-source,server,nowait" \
    -object tls-creds-x509,id=tls0,dir=$CERT_DIR,endpoint=client,verify-peer=yes
