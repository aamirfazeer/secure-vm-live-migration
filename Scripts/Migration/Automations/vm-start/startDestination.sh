#!/bin/bash

VM="$1"
TAP="$2"
RAM="$3"
CORE="$4"
POST="$5"

if test -d /sys/class/net/$TAP; then
        echo ">>> Tap Device $TAP Already in Use"
else
        ip tuntap add dev $TAP mode tap
        ip link set dev $TAP master br0
        ip link set dev $TAP up
fi
echo "Destination VM Started"
sudo qemu-system-x86_64 \
        -name base \
	-machine pc-i440fx-2.8 \
        -smp $CORE \
        -boot c \
        -m $RAM \
        -vnc :1 \
        -drive file=/mnt/nfs/aamir/vm-images/$VM.img,if=virtio \
        -net nic,model=virtio,macaddr=52:54:00:12:34:11 \
        -net tap,ifname=$TAP,script=no,downscript=no \
        -cpu host --enable-kvm \
        -qmp "unix:/media/qmp1,server,nowait" \
        -incoming tcp:0:4444 &

sleep 2

TRIGGERS=/mnt/nfs/aamir/Scripts/Migration/Triggers/

if [ "$POST" = "true" ]
then
        bash  $TRIGGERS/Post-Copy/postcopy-dst-ram.sh
fi

