#!/bin/bash

VM=${1:-"original"}
SIZE=${2:-1024}
CORES=${3:-1}
TAP=${4:-"tap0"}

if test -d /sys/class/net/$TAP; then
	echo "Tap Device $TAP Already in Use"
else
	ip tuntap add dev $TAP mode tap
	ip link set dev $TAP master br0
	ip link set dev $TAP up
fi

echo "Source VM Started"

sudo qemu-system-x86_64 \
	-name source \
	-machine pc-i440fx-2.8 \
	-smp $CORES \
	-boot c \
	-m $SIZE \
	-vnc :2 \
	-drive file=/mnt/nfs/aamir/vm-images/$VM.img,if=virtio \
	-net nic,model=virtio,macaddr=52:54:00:12:34:11 \
	-net tap,ifname=$TAP,script=no,downscript=no \
	-cpu host --enable-kvm \
	-qmp "unix:/media/qmp1,server,nowait" 

echo "Source VM Stopped"

