#!/bin/bash

NAME="$1"
DIR=/mnt/nfs/aamir/vm-images

qemu-img create -f qcow2 $DIR/$NAME.img 15G

echo 'Starting VM'

sudo qemu-system-x86_64 \
	-hda $DIR/$NAME.img \
	-cdrom /mnt/nfs/iso/ubuntu-desktop-14.04.6.iso \
	-boot d \
	-smp 4 \
	-m 8192 \
	-vnc :1 \
	-enable-kvm

echo 'VM Stopped'
