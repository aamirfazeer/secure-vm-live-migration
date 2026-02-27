#!/bin/bash

VM="$1"
TAP="$2"
SIZE="$3"
CORES="$4"
POST="$5"

CERT_DIR="/etc/pki/qemu"

if test -d /sys/class/net/$TAP; then
    echo ">>> Tap Device $TAP Already in Use"
else
    ip tuntap add dev $TAP mode tap
    ip link set dev $TAP master br0
    ip link set dev $TAP up
fi

echo ">>> Starting Destination VM with TLS support"

# Enable postcopy-ram capability for hybrid migrations
sudo /mnt/nfs/aamir/Qemu/qemu-8.1.2/qemu-8.1.2/build/qemu-system-x86_64 \
    -name destination-tls \
    -smp $CORES \
    -boot c \
    -m $SIZE \
    -vnc :1 \
    -drive file=/mnt/nfs/aamir/vm-images/$VM.img,if=virtio \
    -net nic,model=virtio,macaddr=52:54:00:12:34:11 \
    -net tap,ifname=$TAP,script=no,downscript=no \
    -cpu host --enable-kvm \
    -qmp "unix:/media/qmp-destination,server,nowait" \
    -object tls-creds-x509,id=tls0,dir=$CERT_DIR,endpoint=server,verify-peer=yes \
    -global migration.x-postcopy-ram=on \
    -incoming tcp:0:4444 &

sleep 2

TRIGGERS=/mnt/nfs/aamir/Scripts/Migration/Triggers/

if [ "$POST" = "true" ]; then
    bash $TRIGGERS/Post-Copy/postcopy-dst-ram.sh
fi
