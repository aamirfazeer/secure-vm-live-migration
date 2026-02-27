#!/bin/bash

# Array of "tuples": --flag:VAR_NAME:default_value
ARG_TUPLES=(
  "--vnc:VNC_NUM:1"
  "--vm:VM:idle"
  "--size:SIZE:1024"
  "--cores:CORES:1"
  "--tap:TAP:tap0"
  "--type:TYPE:precopy"
  "--iterations:ITERATIONS:10"
  "--log:LOG_FOLDER:$(date "+%Y%m%d_%H%M%S")"
  "--optimization:OPTIMIZATION_SCRIPT:"
)

# ------------------------------- Do not change --------------------------------------
# Initialize variables with defaults
for tuple in "${ARG_TUPLES[@]}"; do
  IFS=":" read -r FLAG VAR DEFAULT <<< "$tuple"
  declare "$VAR=$DEFAULT"
done

# Parse arguments
for ARG in "$@"; do
  KEY="${ARG%%=*}"   # --flag
  VALUE="${ARG#*=}"  # value
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

# ------------------------------------------------------------------------------------

SOURCE_IP="10.22.196.152"
DESTINATION_IP="10.22.196.154"
VM_IP="10.22.196.250"

LOG_ID=""
POST_COPYABLE=""
MIGRATION=""

# SSH credentials (you may need to update these)
SOURCE_PASS="primedirective"
DEST_PASS="primedirective"
VM_PASS="vmpassword"

terminate-qemu () {
    sshpass -p "vmpassword" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=60 root@$VM_IP "poweroff" > /dev/null 2>&1
    sleep 5

    DESTINATION_CHECK=$(sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP "pgrep qemu")
    if [[ -n $DESTINATION_CHECK ]];
    then
        sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP "pkill qemu"
    fi
    sleep 5
    sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "pkill qemu"
}

get_migration_details() {
    MIGRATION=""
    sleep 30

    MAX_RETRIES=10
    RETRY=0
    while [[ $MIGRATION != *"completed"* && $RETRY -lt $MAX_RETRIES ]]; do
        sleep 10
        echo ">>> Checking for Migration Status (Attempt $((RETRY + 1))/$MAX_RETRIES)"

        MIGRATION=$(sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
            "bash /mnt/nfs/aamir/Scripts/Migration/Status/migration-status.sh")

        ((RETRY++))
    done

    if [[ $MIGRATION == *"completed"* ]]; then
        echo ">>> Migration completed successfully."

        # Write the Migration Details to
        echo $MIGRATION > "logs/${LOG_FOLDER}/${LOG_ID}_vm.txt"
    else
        echo "Migration did not complete after $MAX_RETRIES attempts."
    fi
}

# ---------------- Making Destination Ready  -------------------
start_destination() {
    local CURRENT_TYPE=$1
    echo ">>> Starting Destination VM for $CURRENT_TYPE"
    
    if [ "$CURRENT_TYPE" = "precopy" ]; then
        POST_COPYABLE="false"
    else
        POST_COPYABLE="true"
    fi
    
    sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP "bash /mnt/nfs/aamir/Scripts/Migration/Automations/vm-start/startDestination.sh $VM $TAP $SIZE $CORES $POST_COPYABLE" &
}

# Starting the VM in Source Machine
start_source() {
    echo ">>> Starting Source VM"
    sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash /mnt/nfs/aamir/Scripts/General/startSource.sh $VM $SIZE $CORES $TAP" &
}

# ----------------- Starting the Workload -------------------
start_workload() {
    echo ">>> Starting Quicksort Workload"
    
    # Wait for VM to be fully accessible
    echo ">>> Waiting for VM to be ready..."
    MAX_WAIT=60
    WAIT_COUNT=0
    while ! sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@$VM_IP "echo 'VM Ready'" > /dev/null 2>&1; do
        sleep 5
        WAIT_COUNT=$((WAIT_COUNT + 5))
        if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
            echo ">>> WARNING: VM not accessible after ${MAX_WAIT}s, proceeding anyway"
            break
        fi
        echo ">>> Waiting for VM... (${WAIT_COUNT}s)"
    done
    
    # Test if quicksort binary exists and is executable
    echo ">>> Checking quicksort binary..."
    if ! sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no root@$VM_IP "test -x /home/vmuser/Desktop/quicksort"; then
        echo ">>> ERROR: quicksort binary not found or not executable"
        return 1
    fi
    
    # Start quicksort with clean output (only timer output)
    echo ">>> Starting quicksort process..."
    sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no root@$VM_IP \
    "cd /home/vmuser/Desktop && \
    ./quicksort" > "logs/${LOG_FOLDER}/${LOG_ID}_quick_sort.txt" 2>&1 &
    
    # Store the background process PID for potential cleanup
    QUICKSORT_PID=$!
    echo ">>> Quicksort started with PID: $QUICKSORT_PID"
}

# Check quicksort status
check_workload_status() {
    echo ">>> Checking quicksort status..."
    local processes=$(sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no root@$VM_IP "pgrep quicksort" 2>/dev/null)
    if [ -n "$processes" ]; then
        echo ">>> Quicksort processes running: $processes"
        return 0
    else
        echo ">>> No quicksort processes found"
        return 1
    fi
}

TRIGGERS=/mnt/nfs/aamir/Scripts/Migration/Triggers

trigger_migration() {
    local CURRENT_TYPE=$1
    echo ">>> Triggering $CURRENT_TYPE Migration"

    if [ "$CURRENT_TYPE" = "precopy" ]
    then
        sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash $TRIGGERS/Pre-Copy/precopy-vm-migrate1.sh"
    elif [ "$CURRENT_TYPE" = "postcopy" ]
    then
        sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash  $TRIGGERS/Post-Copy/postcopy-vm-migrate.sh"
    elif [ "$CURRENT_TYPE" = "hybrid" ]
    then
        sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash $TRIGGERS/Hybrid/hybrid-vm-migrate.sh auto"
    fi
}

# --------------------------------  Start optimization script if provided -----------------------------
run_optimization_script() {
    if [[ "$OPTIMIZATION_SCRIPT" != "" ]]; then
        echo ">>> Running Optimization Script: $OPTIMIZATION_SCRIPT"
        sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash $OPTIMIZATION_SCRIPT"
        echo $OPTIMIZATION_SCRIPT > "logs/${LOG_FOLDER}/optimization.txt"
        echo ">>> Optimization Script Completed"
    else
        echo ">>> No Optimization Script Provided"
    fi
}

# Function to run a single migration iteration
run_single_iteration() {
    local CURRENT_TYPE=$1
    local ITER=$2
    
    echo "=========================================="
    echo ">>> Starting $CURRENT_TYPE Migration Iteration $ITER"
    echo "=========================================="

    timestamp=$(date "+%Y%m%d_%H%M%S")
    LOG_ID="${CURRENT_TYPE}_${VM}_${SIZE}_${timestamp}"

    start_source
    start_destination "$CURRENT_TYPE"
    echo ">>> Waiting for VMs to initialize..."
    sleep 30
    
    run_optimization_script
    sleep 10
    
    # Start workload and verify it's running
    start_workload
    sleep 20
    check_workload_status
    sleep 10
    
    trigger_migration "$CURRENT_TYPE"
    get_migration_details
    
    # Final workload status check
    echo ">>> Final workload status check..."
    check_workload_status

    terminate-qemu
    sleep 10
    
    # Check log file size
    if [ -f "logs/${LOG_FOLDER}/${LOG_ID}_quick_sort.txt" ]; then
        LOG_SIZE=$(wc -c < "logs/${LOG_FOLDER}/${LOG_ID}_quick_sort.txt")
        echo ">>> Quicksort log size: ${LOG_SIZE} bytes"
        if [ $LOG_SIZE -eq 0 ]; then
            echo ">>> WARNING: Quicksort log file is empty!"
        fi
    else
        echo ">>> ERROR: Quicksort log file not created!"
    fi
}

# ================================ MAIN EXECUTION ================================

# Create the logging folder
mkdir -p "logs/${LOG_FOLDER}"
echo "Creating logs/${LOG_FOLDER} folder"

# Initial cleanup
terminate-qemu

# Check if type is "all" - if so, run all three types
if [ "$TYPE" = "all" ]; then
    echo "=========================================="
    echo "Running ALL migration types: precopy, postcopy, hybrid"
    echo "VM: $VM | Size: ${SIZE}MB | Cores: $CORES | Iterations per type: $ITERATIONS"
    echo "=========================================="
    
    MIGRATION_TYPES=("precopy" "postcopy" "hybrid")
    
    for CURRENT_TYPE in "${MIGRATION_TYPES[@]}"; do
        echo ""
        echo "######################################################"
        echo "# Starting $CURRENT_TYPE migration phase ($ITERATIONS iterations)"
        echo "######################################################"
        echo ""
        
        for (( i=1; i<=$ITERATIONS; i++ )); do
            run_single_iteration "$CURRENT_TYPE" "$i"
        done
        
        echo ""
        echo "######################################################"
        echo "# Completed all $CURRENT_TYPE migrations"
        echo "######################################################"
        echo ""
        sleep 5
    done
    
    echo "=========================================="
    echo "ALL MIGRATIONS COMPLETED!"
    echo "Total iterations: $((ITERATIONS * 3))"
    echo "Check logs at: logs/${LOG_FOLDER}/"
    echo "=========================================="
else
    # Single type migration (original behavior)
    echo "Running $TYPE migration with $ITERATIONS iterations"
    
    for (( i=1; i<=$ITERATIONS; i++ )); do
        run_single_iteration "$TYPE" "$i"
    done
fi
