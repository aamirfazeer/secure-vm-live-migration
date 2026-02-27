#!/bin/bash

# ─────────────────────────────────────────────────────────────
# start_source_script.sh  —  Start the VM on the source machine
# Usage: bash start_source_script.sh --source=<ip> --vm_img=<img> --ram_size=<mb> [...]
#
# NOTE: startSource.sh runs QEMU in the FOREGROUND (no & at end).
# We must use nohup + disown on the remote side so QEMU detaches
# from the SSH session. Without this the SSH call blocks indefinitely.
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARG_TUPLES=(
    "--source:SOURCE_IP:"
    "--vm_img:VM_IMG:oltp"
    "--ram_size:RAM_SIZE:1024"
    "--tap:TAP:tap0"
    "--cores:CORES:1"
    "--optimization:OPTIMIZATION_SCRIPT:"
    "--optimization_script_step:OPTIMIZATION_SCRIPT_STEP:"
)
PARSE_ARGS=("$@")
source "$SCRIPT_DIR/arg_parser.sh"

if [[ -z "$SOURCE_IP" ]]; then
    echo "❌ Missing required argument: --source"
    exit 1
fi

echo ">>> Starting Source VM ($VM_IMG, ${RAM_SIZE}MB) on $SOURCE_IP"

# Use nohup + disown so QEMU keeps running after SSH exits.
# Output goes to /tmp/source_vm_<img>.log on the source machine.
sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$SOURCE_IP" \
    "nohup bash /mnt/nfs/aamir/Scripts/General/startSource.sh \
         $VM_IMG $RAM_SIZE $CORES $TAP \
     > /tmp/source_vm_${VM_IMG}.log 2>&1 & disown
     echo '>>> Source VM launch dispatched'"

if [[ -n "$OPTIMIZATION_SCRIPT" ]]; then
    if [[ -z "$OPTIMIZATION_SCRIPT_STEP" || "$OPTIMIZATION_SCRIPT_STEP" == "source" ]]; then
        echo ">>> Applying optimization on source: $OPTIMIZATION_SCRIPT"
        sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$SOURCE_IP" \
            "bash $OPTIMIZATION_SCRIPT"
    fi
fi
