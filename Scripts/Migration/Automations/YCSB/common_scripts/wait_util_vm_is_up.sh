#!/bin/bash

# ─────────────────────────────────────────────────────────────
# wait_util_vm_is_up.sh  —  Wait until a VM is pingable
# Usage: source wait_util_vm_is_up.sh --ip=<ip> [--timeout=<seconds>]
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARG_TUPLES=(
    "--ip:IP:"
    "--timeout:TIMEOUT:120"
)
PARSE_ARGS=("$@")
source "$SCRIPT_DIR/arg_parser.sh"

if [[ -z "$IP" ]]; then
    echo "❌ Missing required argument: --ip"
    exit 1
fi

INTERVAL=5
ELAPSED=0

echo ">>> Waiting for VM at $IP to become reachable (timeout: ${TIMEOUT}s)..."

while [ $ELAPSED -lt $TIMEOUT ]; do
    # Check ping first, then verify SSH is actually up
    if ping -c 1 -W 2 "$IP" &>/dev/null; then
        if sshpass -p "workingset" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
               root@"$IP" "echo ok" &>/dev/null; then
            echo "✅ VM at $IP is reachable and SSH is up (after ${ELAPSED}s)"
            return 0 2>/dev/null || exit 0
        fi
    fi

    echo ">>> Still waiting for VM at $IP ... (${ELAPSED}s / ${TIMEOUT}s)"
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

echo "❌ VM at $IP did not become reachable within ${TIMEOUT} seconds"
return 1 2>/dev/null || exit 1
