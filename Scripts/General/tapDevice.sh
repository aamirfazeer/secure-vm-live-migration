#!/bin/bash

MODE="$1"
TAP="$2"

if [ $MODE = 'r' ]; then
	if test -d /sys/class/net/tap0; then
		ip link delete dev $TAP type tap
	fi
	echo "Tap Device $TAP Removed!"
else
	ip tuntap add dev $TAP mode tap
	ip link set dev $TAP master br0
	ip link set dev $TAP up
	echo "Tap Device $TAP Created!"
fi
