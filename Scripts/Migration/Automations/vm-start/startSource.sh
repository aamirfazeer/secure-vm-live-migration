#!/bin/bash

VM="$1"
TAP="$2"
RAM="$3"
CORE="$4"

if test -d /sys/class/net/$TAP; then
	printf ">>> Tap Device %s Already in Use\n" $TAP
else
	ip tuntap add dev $TAP mode tap
	ip link set dev $TAP master br0
	ip link set dev $TAP up
fi

echo ">>> Starting VM in Source"

sudo qemu-system-x86_64 \
	-name base \
	-smp $CORE \
	-boot c \
	-m $RAM \
	-vnc :1 \
	-drive file=$VM,if=virtio \
	-net nic,model=virtio,macaddr=52:54:00:12:34:11 \
	-net tap,ifname=$TAP,script=no,downscript=no \
	-cpu host --enable-kvm \
	-qmp "unix:/media/qmp1,server,nowait" &
