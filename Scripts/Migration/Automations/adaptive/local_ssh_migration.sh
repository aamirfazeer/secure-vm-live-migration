#!/bin/bash

################################################################################
# Local SSH Migration Script for Adaptive Selector
# This script is called by the adaptive migration selector
################################################################################

# Array of "tuples": --flag:VAR_NAME:default_value
ARG_TUPLES=(
  "--vm:VM:idle"
  "--size:SIZE:1024"
  "--cores:CORES:1"
  "--tap:TAP:tap0"
  "--type:TYPE:precopy"
  "--iterations:ITERATIONS:10"
  "--log:LOG_FOLDER:"
  "--tunnel-port:TUNNEL_PORT:4444"
)

# Initialize variables with defaults
for tuple in "${ARG_TUPLES[@]}"; do
  IFS=":" read -r FLAG VAR DEFAULT <<< "$tuple"
  declare "$VAR=$DEFAULT"
done

# Parse arguments
for ARG in "$@"; do
  KEY="${ARG%%=*}"
  VALUE="${ARG#*=}"
  MATCHED=false

  for tuple in "${ARG_TUPLES[@]}"; do
    IFS=":" read -r FLAG VAR DEFAULT <<< "$tuple"
    if [[ "$KEY" == "$FLAG" ]]; then
      declare "$VAR=$VALUE"
      MATCHED=true
      break
    fi
  done

  if ! $MATCHED; then
    echo "Unknown argument: $ARG"
    exit 1
  fi
done

SOURCE_IP="10.22.196.152"
DESTINATION_IP="10.22.196.154"
VM_IP="10.22.196.250"

# SSH credentials
SOURCE_PASS="primedirective"
DEST_PASS="primedirective"
VM_PASS="vmpassword"

# Logs directory
LOGS_BASE="/mnt/nfs/aamir/Scripts/Migration/Automations/adaptive/logs"

# If LOG_FOLDER not provided, create default one
if [ -z "$LOG_FOLDER" ]; then
    timestamp=$(date "+%Y%m%d_%H%M%S")
    LOG_FOLDER="ssh_${VM}_${SIZE}MB_${CORES}cores_${TYPE}_${timestamp}"
fi

LOG_PATH="${LOGS_BASE}/${LOG_FOLDER}"
mkdir -p "$LOG_PATH"

LOG_ID=""
POST_COPYABLE=""
MIGRATION=""

SSH_TUNNEL_DIR="/mnt/nfs/aamir/Scripts/Migration/Automations/ssh-tunnel"

terminate_qemu() {
    sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=60 root@$VM_IP "poweroff" > /dev/null 2>&1
    sleep 5

    DESTINATION_CHECK=$(sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP "pgrep qemu")
    if [[ -n $DESTINATION_CHECK ]]; then
        sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP "pkill qemu"
    fi
    sleep 5
    sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "pkill qemu"
}

setup_ssh_tunnel() {
    echo ">>> Setting up SSH tunnel on port $TUNNEL_PORT..."
    
    # Stop existing tunnel
    sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
        "bash $SSH_TUNNEL_DIR/stop-ssh-tunnel.sh $TUNNEL_PORT" > /dev/null 2>&1
    sleep 5
    
    # Start new tunnel
    sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
        "sshpass -p '$DEST_PASS' ssh -f -N -L ${TUNNEL_PORT}:localhost:${TUNNEL_PORT} root@${DESTINATION_IP} -o StrictHostKeyChecking=no -o ServerAliveInterval=30" > /dev/null 2>&1
    
    sleep 10
    
    TUNNEL_CHECK=$(sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
        "lsof -ti :$TUNNEL_PORT -sTCP:LISTEN")
    
    if [[ -n $TUNNEL_CHECK ]]; then
        echo ">>> SSH tunnel established (PID: $TUNNEL_CHECK)"
        return 0
    else
        echo ">>> ERROR: Failed to establish SSH tunnel"
        return 1
    fi
}

cleanup_ssh_tunnel() {
    echo ">>> Cleaning up SSH tunnel..."
    sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
        "bash $SSH_TUNNEL_DIR/stop-ssh-tunnel.sh $TUNNEL_PORT" > /dev/null 2>&1
}

get_migration_details() {
    MIGRATION=""
    sleep 30

    MAX_RETRIES=20
    RETRY=0
    while [[ $MIGRATION != *"completed"* && $RETRY -lt $MAX_RETRIES ]]; do
        sleep 10
        echo ">>> Checking Migration Status (Attempt $((RETRY + 1))/$MAX_RETRIES)"

        MIGRATION=$(sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
            "bash /mnt/nfs/aamir/Scripts/Migration/Status/migration-status.sh")

        ((RETRY++))
    done

    if [[ $MIGRATION == *"completed"* ]]; then
        echo ">>> Migration completed successfully."
        echo "$MIGRATION" > "${LOG_PATH}/${LOG_ID}_migration_status.txt"
    else
        echo ">>> Migration timeout"
        echo "Migration timeout" > "${LOG_PATH}/${LOG_ID}_migration_status.txt"
    fi
}

start_destination() {
    local CURRENT_TYPE=$1
    echo ">>> Starting Destination VM for $CURRENT_TYPE"
    
    if [ "$CURRENT_TYPE" = "precopy" ]; then
        POST_COPYABLE="false"
    else
        POST_COPYABLE="true"
    fi
    
    sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP \
        "bash /mnt/nfs/aamir/Scripts/Migration/Automations/vm-start/startDestination.sh $VM $TAP $SIZE $CORES $POST_COPYABLE" &
}

start_source() {
    echo ">>> Starting Source VM"
    sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
        "bash /mnt/nfs/aamir/Scripts/General/startSource.sh $VM $SIZE $CORES $TAP" &
}

start_workload() {
    echo ">>> Starting Quicksort Workload"
    
    echo ">>> Waiting for VM to be ready..."
    MAX_WAIT=60
    WAIT_COUNT=0
    while ! sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@$VM_IP "echo 'VM Ready'" > /dev/null 2>&1; do
        sleep 5
        WAIT_COUNT=$((WAIT_COUNT + 5))
        if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
            echo ">>> WARNING: VM not accessible after ${MAX_WAIT}s"
            break
        fi
    done
    
    if ! sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no root@$VM_IP "test -x /home/vmuser/Desktop/quicksort"; then
        echo ">>> ERROR: quicksort binary not found"
        return 1
    fi
    
    sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no root@$VM_IP \
        "cd /home/vmuser/Desktop && ./quicksort" > "${LOG_PATH}/${LOG_ID}_workload.txt" 2>&1 &
    
    echo ">>> Quicksort started"
}

trigger_secure_migration() {
    local CURRENT_TYPE=$1
    echo ">>> Triggering Secure $CURRENT_TYPE Migration via SSH Tunnel"

    if [ "$CURRENT_TYPE" = "precopy" ]; then
        sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
            "bash $SSH_TUNNEL_DIR/secure-precopy-migrate.sh /media/qmp1 $TUNNEL_PORT" > /dev/null 2>&1
    elif [ "$CURRENT_TYPE" = "postcopy" ]; then
        sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
            "bash $SSH_TUNNEL_DIR/secure-postcopy-migrate.sh /media/qmp1 $TUNNEL_PORT" > /dev/null 2>&1
    elif [ "$CURRENT_TYPE" = "hybrid" ]; then
        sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
            "bash $SSH_TUNNEL_DIR/secure-hybrid-migrate.sh /media/qmp1 $TUNNEL_PORT true" > /dev/null 2>&1
    fi
}

run_single_iteration() {
    local CURRENT_TYPE=$1
    local ITER=$2
    
    echo "=========================================="
    echo ">>> SSH Tunnel Migration: $CURRENT_TYPE - Iteration $ITER"
    echo "=========================================="

    timestamp=$(date "+%Y%m%d_%H%M%S")
    LOG_ID="iter${ITER}_${CURRENT_TYPE}_${timestamp}"

    start_source
    start_destination "$CURRENT_TYPE"
    sleep 30
    
    if ! setup_ssh_tunnel; then
        echo ">>> ERROR: SSH tunnel setup failed"
        return 1
    fi
    
    start_workload
    sleep 30
    
    trigger_secure_migration "$CURRENT_TYPE"
    get_migration_details
    
    terminate_qemu
    cleanup_ssh_tunnel
    sleep 10
}

# Main execution
echo ">>> Starting SSH Tunnel Migration"
echo ">>> Log Path: $LOG_PATH"

terminate_qemu
cleanup_ssh_tunnel

if [ "$TYPE" = "all" ]; then
    MIGRATION_TYPES=("precopy" "postcopy" "hybrid")
else
    MIGRATION_TYPES=("$TYPE")
fi

for CURRENT_TYPE in "${MIGRATION_TYPES[@]}"; do
    for (( i=1; i<=$ITERATIONS; i++ )); do
        run_single_iteration "$CURRENT_TYPE" "$i"
    done
done

echo ">>> SSH Tunnel Migration Complete"
echo ">>> Logs: $LOG_PATH"
