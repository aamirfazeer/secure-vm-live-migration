#!/bin/bash

# Array of "tuples": --flag:VAR_NAME:default_value
ARG_TUPLES=(
  "--vnc:VNC_NUM:1"
  "--vm:VM:ycsbNew"
  "--size:SIZE:all"
  "--cores:CORES:1"
  "--tap:TAP:tap0"
  "--type:TYPE:precopy"
  "--iterations:ITERATIONS:10"
  "--log:LOG_FOLDER:$(date "+%Y%m%d_%H%M%S")"
  "--optimization:OPTIMIZATION_SCRIPT:"
  "--workingset_size:WORKINGSET_SIZE:"
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
# ------------------------------------------------------------------------------------

SOURCE_IP="10.22.196.154"
DESTINATION_IP="10.22.196.155"
VM_IP="10.22.196.203"

LOG_ID=""
POST_COPYABLE=""
MIGRATION=""

# SSH credentials
SOURCE_PASS="primedirective"
DEST_PASS="primedirective"
VM_PASS="workingset"

# Define VM sizes to test (in MB)
if [ "$SIZE" = "all" ]; then
    VM_SIZES=(2048 4096 8192 12288 16384)
    echo "Running tests for all VM sizes: ${VM_SIZES[*]} MB"
else
    VM_SIZES=("$SIZE")
    echo "Running tests for single VM size: $SIZE MB"
fi

# Validate migration type and set types to run
VALID_TYPES=("precopy" "postcopy" "hybrid" "all")
if [[ ! " ${VALID_TYPES[@]} " =~ " ${TYPE} " ]]; then
    echo "Error: Invalid migration type '$TYPE'"
    echo "Valid types: ${VALID_TYPES[*]}"
    exit 1
fi

# Set migration types array based on input
if [ "$TYPE" = "all" ]; then
    MIGRATION_TYPES=("precopy" "postcopy" "hybrid")
    echo "Running all migration types: ${MIGRATION_TYPES[*]}"
else
    MIGRATION_TYPES=("$TYPE")
    echo "Running specific migration type: $TYPE"
fi

terminate-qemu () {
    sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=60 root@$VM_IP "poweroff" > /dev/null 2>&1
    sleep 5

    DESTINATION_CHECK=$(sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP "pgrep qemu")
    if [[ -n $DESTINATION_CHECK ]];
    then
        sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP "pkill qemu"
    fi
    sleep 5
    sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "pkill qemu"
}

get_migration_details() {
    MAX_ITERATIONS=65
    CHECK_INTERVAL=5
    
    echo ">>> Waiting for $CURRENT_TYPE migration (max ${MAX_ITERATIONS} iterations)"
    
    # Initial delay to let migration start
    sleep 10
    
    while true; do
        STATUS=$(sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
            "bash /mnt/nfs/aamir/Scripts/Migration/Status/migration-status.sh")
        
        # Case 1: Migration completed successfully
        if echo "$STATUS" | grep -qi "completed"; then
            echo ">>> Migration completed successfully"
            echo "$STATUS" > "logs/${LOG_FOLDER}/${LOG_ID}_migration.txt"
            break
        fi
        
        # Case 2: Max iteration reached inside QEMU
        if echo "$STATUS" | grep -qi "Maximum # of Iterations Reached"; then
            echo ">>> Migration stopped due to max iteration limit (QEMU)"
            echo "$STATUS" > "logs/${LOG_FOLDER}/${LOG_ID}_migration_max_iter.txt"
            break
        fi
        
        # Case 3: Extract current iteration number
        ITER=$(echo "$STATUS" | grep -oE "Iteration[[:space:]]+[0-9]+" | tail -1 | awk '{print $2}')
        
        if [[ -n "$ITER" ]]; then
            echo ">>> Current iteration: ${ITER}/${MAX_ITERATIONS}"
            
            if [[ "$ITER" -ge "$MAX_ITERATIONS" ]]; then
                echo ">>> Iteration ${ITER} reached threshold (${MAX_ITERATIONS}), stopping wait"
                echo "$STATUS" > "logs/${LOG_FOLDER}/${LOG_ID}_migration_forced_stop.txt"
                break
            fi
        else
            echo ">>> Waiting for migration to start..."
        fi
        
        sleep $CHECK_INTERVAL
    done
}

# ---------------- Making Destination Ready  -------------------
start_destination() {
    echo ">>> Starting Destination VM (Size: ${CURRENT_SIZE}MB)"
    sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP "bash /mnt/nfs/aamir/Scripts/Migration/Automations/vm-start/startDestination.sh $VM $TAP $CURRENT_SIZE $CORES $POST_COPYABLE" &
}

# Starting the VM in Source Machine
start_source() {
    echo ">>> Starting Source VM (Size: ${CURRENT_SIZE}MB)"
    sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash /mnt/nfs/aamir/Scripts/General/startSource.sh $VM $CURRENT_SIZE $CORES $TAP" &
}

# ----------------- Starting the Workload - WORKINGSET VERSION -------------------
start_workload() {
    echo ">>> Starting Workingset Workload"
    
    # Calculate workingset size (half of VM RAM if not specified)
    if [[ "$WORKINGSET_SIZE" == "" ]]; then
        CURRENT_WORKINGSET_SIZE=$((CURRENT_SIZE / 2))
        echo ">>> Using default workingset size: ${CURRENT_WORKINGSET_SIZE} MB (half of VM RAM)"
    else
        CURRENT_WORKINGSET_SIZE="$WORKINGSET_SIZE"
        echo ">>> Using specified workingset size: ${CURRENT_WORKINGSET_SIZE} MB"
    fi
    
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
    
    # Test if workingset binary exists and is executable
    echo ">>> Checking workingset binary..."
    if ! sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no root@$VM_IP "test -x /home/workingset/Desktop/workingset"; then
        echo ">>> ERROR: workingset binary not found or not executable"
        return 1
    fi
    
    # Start workingset workload
    echo ">>> Starting workingset process with size ${CURRENT_WORKINGSET_SIZE} MB..."
    sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no root@$VM_IP \
    "cd /home/workingset/Desktop && \
    ./workingset $CURRENT_WORKINGSET_SIZE" > /dev/null 2>&1 &
    
    # Store the background process PID for potential cleanup
    WORKINGSET_PID=$!
    echo ">>> Workingset started with PID: $WORKINGSET_PID"
}

# Add function to check workingset status
check_workload_status() {
    echo ">>> Checking workingset status..."
    local processes=$(sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no root@$VM_IP "pgrep workingset" 2>/dev/null)
    if [ -n "$processes" ]; then
        echo ">>> Workingset processes running: $processes"
        return 0
    else
        echo ">>> No workingset processes found"
        return 1
    fi
}

TRIGGERS=/mnt/nfs/aamir/Scripts/Migration/Triggers

trigger_migration() {
    echo ">>> Triggering $CURRENT_TYPE Migration"

    if [ "$CURRENT_TYPE" = "precopy" ]
    then
        sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash $TRIGGERS/Pre-Copy/precopy-vm-migrate1.sh"
    elif [ "$CURRENT_TYPE" = "postcopy" ]
    then
        sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash $TRIGGERS/Post-Copy/postcopy-vm-migrate.sh"
    elif [ "$CURRENT_TYPE" = "hybrid" ]
    then
        sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash $TRIGGERS/Hybrid/hybrid-vm-migrate.sh auto"
    fi
}

# --------------------------------  create the logging folder if doesn't exist -----------------------------
mkdir -p "logs/${LOG_FOLDER}"
echo "Creating logs/${LOG_FOLDER} folder"

# --------------------------------  Start optimization script if provided -----------------------------
run_optimization_script() {
    if [[ "$OPTIMIZATION_SCRIPT" != "" ]]; then
        echo ">>> Running Optimization Script: $OPTIMIZATION_SCRIPT"
        sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash $OPTIMIZATION_SCRIPT"
        echo $OPTIMIZATION_SCRIPT > "logs/${LOG_FOLDER}/optimization.txt"
        echo ">>> Optimization Script Completed"
    else
        echo ">>> No Optimization Script Provided"
    fi
}

# -------------------------------- Main Execution --------------------------------

echo "========================================================"
echo "=== VM Migration Test with Working Set ==="
echo "========================================================"
if [ "$TYPE" = "all" ]; then
    echo "Testing all migration types: ${MIGRATION_TYPES[*]}"
else
    echo "Testing specific migration type: $TYPE"
fi
if [ "$SIZE" = "all" ]; then
    echo "Testing all VM sizes: ${VM_SIZES[*]} MB"
else
    echo "Testing single VM size: $SIZE MB"
fi
echo "Iterations per type: $ITERATIONS"
echo "VM: $VM, Cores: $CORES"
echo "Source IP: $SOURCE_IP"
echo "Destination IP: $DESTINATION_IP"
echo "========================================================"
echo ""

# Run migrations for each VM size
for VM_SIZE in "${VM_SIZES[@]}"; do
    CURRENT_SIZE="$VM_SIZE"
    echo "========================================================"
    echo "=== Testing VM Size: ${CURRENT_SIZE}MB (${CURRENT_SIZE}MB RAM) ==="
    echo "=== Working Set: $((CURRENT_SIZE / 2))MB ==="
    echo "========================================================"
    echo ""
    
    # Run migrations for selected types
    for MIGRATION_TYPE_RUN in "${MIGRATION_TYPES[@]}"; do
        echo "=== Starting $MIGRATION_TYPE_RUN Migration Tests (${CURRENT_SIZE}MB) ==="
        
        CURRENT_TYPE="$MIGRATION_TYPE_RUN"
        
        # Set POST_COPYABLE based on migration type
        if [ "$CURRENT_TYPE" = "precopy" ]; then
            POST_COPYABLE="false"
        else
            POST_COPYABLE="true"
        fi
        
        terminate-qemu
        
        for (( i=1; i<=$ITERATIONS; i++ )); do
            echo ">>> Starting $CURRENT_TYPE Migration (${CURRENT_SIZE}MB) - Iteration $i"

            timestamp=$(date "+%Y%m%d_%H%M%S")
            LOG_ID="${CURRENT_TYPE}_${VM}_${CURRENT_SIZE}MB_${timestamp}"

            start_source
            start_destination
            echo ">>> Waiting for VMs to initialize..."
            sleep 30
            
            run_optimization_script
            sleep 10
            
            # Start workload and verify it's running
            start_workload
            sleep 20
            check_workload_status
            sleep 10
            
            trigger_migration
            get_migration_details
            
            # Final workload status check
            echo ">>> Final workload status check..."
            check_workload_status
            
            terminate-qemu
            sleep 10
            
            echo ">>> $CURRENT_TYPE Migration (${CURRENT_SIZE}MB) Iteration $i completed"
            echo ""
        done
        
        echo "=== $CURRENT_TYPE Migration Tests (${CURRENT_SIZE}MB) Completed ==="
        echo ""
    done
    
    echo "========================================================"
    echo "=== Completed All Tests for ${CURRENT_SIZE}MB VM ==="
    echo "========================================================"
    echo ""
done

echo "========================================================"
echo ">>> Migration testing completed for all configurations"
if [ "$TYPE" = "all" ]; then
    echo "All migration types completed."
else
    echo "$TYPE migration completed."
fi
if [ "$SIZE" = "all" ]; then
    echo "All VM sizes completed: ${VM_SIZES[*]} MB"
else
    echo "Single VM size completed: $SIZE MB"
fi
echo "Check logs/${LOG_FOLDER}/ for migration details."
echo "========================================================"
