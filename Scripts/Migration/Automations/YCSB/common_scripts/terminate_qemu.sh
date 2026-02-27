#!/bin/bash

# ─────────────────────────────────────────────────────────────
# terminate_qemu.sh  —  Gracefully shut down VMs and kill QEMU
# Usage: bash terminate_qemu.sh --source=<ip> --destination=<ip> [--vm_ip=<ip>] [--password=<pass>]
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARG_TUPLES=(
    "--source:SOURCE_IP:"
    "--destination:DESTINATION_IP:"
    "--vm_ip:VM_IP:"
    "--password:VM_PASSWORD:vmpassword"
)
PARSE_ARGS=("$@")
source "$SCRIPT_DIR/arg_parser.sh"

if [[ -z "$SOURCE_IP" || -z "$DESTINATION_IP" ]]; then
    echo "❌ Missing required arguments: --source, --destination"
    exit 1
fi

echo ">>>>>> Terminating QEMU processes on source and destination"

if [[ -n "$VM_IP" ]]; then
    echo ">>> Powering off VM at $VM_IP..."
    sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=60 root@"$VM_IP" "poweroff" > /dev/null 2>&1
    sleep 10
fi

sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$DESTINATION_IP" "pkill qemu" > /dev/null 2>&1
sleep 5
sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$SOURCE_IP" "pkill qemu" > /dev/null 2>&1
sleep 5

echo ">>> QEMU processes terminated"
