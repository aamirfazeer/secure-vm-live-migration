#!/bin/bash

# ─────────────────────────────────────────────────────────────
# start_destination_script.sh  —  Start the VM on the destination machine
# Usage: bash start_destination_script.sh --destination=<ip> --vm_img=<img> --ram_size=<mb> --type=<type> [...]
#
# NOTE: startDestination.sh runs QEMU with & internally, but the script
# then calls postcopy-dst-ram.sh which may block. We background the whole
# SSH call so it never holds up the main script.
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARG_TUPLES=(
    "--destination:DESTINATION_IP:"
    "--vm_img:VM_IMG:oltp"
    "--ram_size:RAM_SIZE:1024"
    "--tap:TAP:tap0"
    "--cores:CORES:1"
    "--type:TYPE:precopy"
    "--optimization:OPTIMIZATION_SCRIPT:"
    "--optimization_script_step:OPTIMIZATION_SCRIPT_STEP:"
)
PARSE_ARGS=("$@")
source "$SCRIPT_DIR/arg_parser.sh"

if [[ -z "$DESTINATION_IP" ]]; then
    echo "❌ Missing required argument: --destination"
    exit 1
fi

if [[ "$TYPE" == "precopy" ]]; then
    POST_COPYABLE="false"
else
    POST_COPYABLE="true"
fi

echo ">>> Starting Destination VM ($VM_IMG, ${RAM_SIZE}MB, post-copyable=$POST_COPYABLE) on $DESTINATION_IP"

# Background the SSH call — startDestination.sh may block on postcopy setup
sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$DESTINATION_IP" \
    "nohup bash /mnt/nfs/aamir/Scripts/Migration/Automations/vm-start/startDestination.sh \
         $VM_IMG $TAP $RAM_SIZE $CORES $POST_COPYABLE \
     > /tmp/dest_vm_${VM_IMG}.log 2>&1 & disown
     echo '>>> Destination VM launch dispatched'" &

if [[ -n "$OPTIMIZATION_SCRIPT" ]]; then
    if [[ -z "$OPTIMIZATION_SCRIPT_STEP" || "$OPTIMIZATION_SCRIPT_STEP" == "destination" ]]; then
        echo ">>> Applying optimization on destination: $OPTIMIZATION_SCRIPT"
        sleep 15  # Give destination QEMU a moment to start before applying
        sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$DESTINATION_IP" \
            "bash $OPTIMIZATION_SCRIPT"
    fi
fi
