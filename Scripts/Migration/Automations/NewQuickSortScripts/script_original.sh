#!/bin/bash

# =====================================================================
# QuickSort Migration Test Script
# =====================================================================

# ------------------------- Configuration -------------------------
SOURCE_IP="10.22.196.155"
DESTINATION_IP="10.22.196.158"
VM_IP="10.22.196.250"
VM_PASSWORD="vmpassword"
HOST_PASSWORD="primedirective"

# Script Paths
MIGRATION_TRIGGERS="/mnt/nfs/aamir/Scripts/Migration/Triggers"
MIGRATION_STATUS_SCRIPT="/mnt/nfs/aamir/Scripts/Migration/Status/migration-status.sh"
VM_START_SCRIPT="/mnt/nfs/aamir/Scripts/General/startSource.sh"
DESTINATION_SCRIPT="/mnt/nfs/aamir/Scripts/Migration/Automations/vm-start/startDestination.sh"
TAP_SCRIPT="/mnt/nfs/aamir/Scripts/General/tapDevice.sh"

# ------------------------- Default Parameters -------------------------
VM_IMG="idle"
RAM_SIZE="1024"
CPU_CORES="1"
MIGRATION_TYPE="precopy"  # Options: precopy, postcopy, hybrid
ITERATIONS=10
LOG_FOLDER="logs/$(date "+%Y%m%d_%H%M%S")"
SOURCE_TAP="tap0"
DEST_TAP="tap0"
TIMEOUT=360

# ------------------------- Parse Arguments -------------------------
for ARG in "$@"; do
    case $ARG in
        --vm_img=*)
            VM_IMG="${ARG#*=}"
            ;;
        --ram_size=*)
            RAM_SIZE="${ARG#*=}"
            ;;
        --cpu_cores=*)
            CPU_CORES="${ARG#*=}"
            ;;
        --type=*)
            MIGRATION_TYPE="${ARG#*=}"
            ;;
        --iterations=*)
            ITERATIONS="${ARG#*=}"
            ;;
        --log=*)
            LOG_FOLDER="logs/${ARG#*=}"
            ;;
        --source_ip=*)
            SOURCE_IP="${ARG#*=}"
            ;;
        --dest_ip=*)
            DESTINATION_IP="${ARG#*=}"
            ;;
        --vm_ip=*)
            VM_IP="${ARG#*=}"
            ;;
        *)
            echo "Unknown argument: $ARG"
            ;;
    esac
done

# ------------------------- Helper Functions -------------------------

initialize_logs() {
    echo ">>> Initializing log folder: $LOG_FOLDER"
    mkdir -p "$LOG_FOLDER"
    echo "Migration Type: $MIGRATION_TYPE" > "$LOG_FOLDER/test_config.txt"
    echo "VM Image: $VM_IMG" >> "$LOG_FOLDER/test_config.txt"
    echo "RAM Size: $RAM_SIZE MB" >> "$LOG_FOLDER/test_config.txt"
    echo "CPU Cores: $CPU_CORES" >> "$LOG_FOLDER/test_config.txt"
    echo "Iterations: $ITERATIONS" >> "$LOG_FOLDER/test_config.txt"
}

terminate_qemu() {
    echo ">>> Terminating QEMU processes"
    
    # Try graceful VM shutdown
    sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@$VM_IP "poweroff" &>/dev/null
    sleep 5
    
    # Kill QEMU on destination
    sshpass -p "$HOST_PASSWORD" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP "pkill qemu" &>/dev/null
    sleep 3
    
    # Kill QEMU on source
    sshpass -p "$HOST_PASSWORD" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "pkill qemu" &>/dev/null
    sleep 3
}

wait_for_vm() {
    local ip=$1
    local timeout=${2:-60}
    local elapsed=0
    
    echo ">>> Waiting for VM at $ip to be reachable"
    
    while [ $elapsed -lt $timeout ]; do
        if ping -c 1 -W 2 "$ip" &>/dev/null; then
            echo "✅ VM at $ip is reachable"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    echo "❌ VM at $ip did not respond within $timeout seconds"
    return 1
}

start_source_vm() {
    echo ">>> Starting Source VM on $SOURCE_IP"
    
    sshpass -p "$HOST_PASSWORD" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
        "bash $VM_START_SCRIPT $VM_IMG $RAM_SIZE $CPU_CORES $SOURCE_TAP" > /dev/null 2>&1 &
    
    sleep 10
}

start_destination_vm() {
    echo ">>> Starting Destination VM on $DESTINATION_IP"
    
    local enable_postcopy="false"
    if [[ "$MIGRATION_TYPE" == "postcopy" ]] || [[ "$MIGRATION_TYPE" == "hybrid" ]]; then
        enable_postcopy="true"
    fi
    
    sshpass -p "$HOST_PASSWORD" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP \
        "bash $DESTINATION_SCRIPT $VM_IMG $DEST_TAP $RAM_SIZE $CPU_CORES $enable_postcopy" > /dev/null 2>&1 &
    
    sleep 5
}

start_system_monitoring() {
    local log_id=$1
    echo ">>> Starting system usage monitoring"
    
    sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no root@$VM_IP \
        'while true; do echo "=== $(date) ==="; top -bn1 | head -n 20; free -m; sleep 2; done' \
        > "$LOG_FOLDER/${log_id}_system_usage.log" 2>&1 &
    
    MONITOR_PID=$!
}

stop_system_monitoring() {
    if [[ -n "$MONITOR_PID" ]]; then
        kill $MONITOR_PID 2>/dev/null
    fi
}

start_quicksort_workload() {
    local log_id=$1
    echo ">>> Starting QuickSort workload"
    
    sshpass -p "$VM_PASSWORD" ssh -o StrictHostKeyChecking=no root@$VM_IP \
        "cd /home/vmuser/Desktop && ./quicksort" > "$LOG_FOLDER/${log_id}_quicksort.txt" 2>&1 &
    
    WORKLOAD_PID=$!
}

trigger_migration() {
    echo ">>> Triggering $MIGRATION_TYPE migration"
    
    case $MIGRATION_TYPE in
        precopy)
            sshpass -p "$HOST_PASSWORD" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
                "bash $MIGRATION_TRIGGERS/Pre-Copy/precopy-vm-migrate1.sh" &
            ;;
        postcopy)
            sshpass -p "$HOST_PASSWORD" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
                "bash $MIGRATION_TRIGGERS/Post-Copy/postcopy-vm-migrate.sh" &
            ;;
        hybrid)
            sshpass -p "$HOST_PASSWORD" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
                "bash $MIGRATION_TRIGGERS/Hybrid/hybrid-vm-migrate.sh auto" &
            ;;
        *)
            echo "❌ Unknown migration type: $MIGRATION_TYPE"
            exit 1
            ;;
    esac
    
    # Give the trigger command time to start
    sleep 2
}

wait_for_migration_completion() {
    local log_id=$1
    local elapsed=0
    
    echo ">>> Waiting for migration to complete (timeout: ${TIMEOUT}s)"
    
    while [ $elapsed -lt $TIMEOUT ]; do
        echo ">>> Checking migration status (Elapsed: ${elapsed}s)"
        
        MIGRATION_STATUS=$(sshpass -p "$HOST_PASSWORD" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
            "bash $MIGRATION_STATUS_SCRIPT" 2>/dev/null)
        
        # Debug: Show first 200 chars of status
        # echo "DEBUG: ${MIGRATION_STATUS:0:200}"
        
        # Check if migration completed
        if [[ $MIGRATION_STATUS == *'"status": "completed"'* ]] || [[ $MIGRATION_STATUS == *'"status":"completed"'* ]]; then
            echo "✅ Migration completed successfully"
            sleep 5
            echo "$MIGRATION_STATUS" > "$LOG_FOLDER/${log_id}_migration_status.txt"
            return 0
        fi
        
        # Check if migration is still active
        if [[ $MIGRATION_STATUS == *'"status": "active"'* ]] || [[ $MIGRATION_STATUS == *'"status":"active"'* ]]; then
            echo "    Migration in progress..."
        elif [[ $MIGRATION_STATUS == *'"status"'* ]]; then
            # Extract and show status if it's something else
            status=$(echo "$MIGRATION_STATUS" | grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1)
            echo "    Migration status: $status"
        fi
        
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    echo "❌ Migration did not complete within $TIMEOUT seconds"
    echo "$MIGRATION_STATUS" > "$LOG_FOLDER/${log_id}_migration_failed.txt"
    return 1
}

# ------------------------- Main Execution -------------------------

echo "=========================================="
echo "  QuickSort VM Migration Test Script"
echo "=========================================="
echo "VM Image: $VM_IMG"
echo "RAM: ${RAM_SIZE}MB | Cores: $CPU_CORES"
echo "Migration Type: $MIGRATION_TYPE"
echo "Iterations: $ITERATIONS"
echo "Log Folder: $LOG_FOLDER"
echo "=========================================="

initialize_logs

for (( i=1; i<=$ITERATIONS; i++ )); do
    echo ""
    echo "=========================================="
    echo "  Iteration $i of $ITERATIONS"
    echo "=========================================="
    
    # Clean up any existing QEMU processes
    terminate_qemu
    
    # Generate unique log ID
    timestamp=$(date "+%Y%m%d_%H%M%S")
    LOG_ID="${MIGRATION_TYPE}_${VM_IMG}_${RAM_SIZE}MB_${timestamp}"
    
    echo ">>> Log ID: $LOG_ID"
    
    # Step 1: Start VMs
    echo "--- Step 1: Starting VMs ---"
    start_source_vm
    start_destination_vm
    
    # Step 2: Wait for VM to be ready
    echo "--- Step 2: Waiting for VM ---"
    if ! wait_for_vm $VM_IP 120; then
        echo "❌ Iteration $i failed: VM not reachable"
        continue
    fi
    
    # Step 3: Start monitoring
    echo "--- Step 3: Starting Monitoring ---"
    start_system_monitoring "$LOG_ID"
    
    # Step 4: Wait 10s after VM is up, then start workload
    echo "--- Step 4: Starting Workload ---"
    echo ">>> Waiting 10 seconds after VM is up before starting QuickSort..."
    sleep 10
    start_quicksort_workload "$LOG_ID"
    
    # Step 5: Wait 10s after QuickSort starts, then trigger migration
    echo "--- Step 5: Triggering Migration ---"
    echo ">>> Waiting 10 seconds after QuickSort starts before triggering migration..."
    sleep 10
    trigger_migration
    
    # Step 6: Wait for migration completion
    echo "--- Step 6: Waiting for Completion ---"
    if wait_for_migration_completion "$LOG_ID"; then
        echo "✅ Iteration $i completed successfully"
    else
        echo "❌ Iteration $i failed"
    fi
    
    # Stop monitoring
    stop_system_monitoring
    
    # Wait 20s after migration completes before termination
    echo ">>> Waiting 20 seconds after migration completion before cleanup..."
    sleep 20
    
    echo "=========================================="
done

# Final cleanup
echo ""
echo ">>> Final cleanup"
terminate_qemu

echo ""
echo "=========================================="
echo "  All iterations completed!"
echo "  Results saved in: $LOG_FOLDER"
echo "=========================================="
