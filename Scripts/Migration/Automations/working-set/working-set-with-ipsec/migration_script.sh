#!/bin/bash

# Complete VM Migration Script with IPsec and Workingset Workload
# Runs all three migration types: precopy, postcopy, and hybrid
# Usage: ./complete_migration_script.sh [options]

# Array of "tuples": --flag:VAR_NAME:default_value
ARG_TUPLES=(
  "--vnc:VNC_NUM:1"
  "--vm:VM:idle"
  "--size:SIZE:1024"
  "--cores:CORES:1"
  "--tap:TAP:tap0"
  "--iterations:ITERATIONS:3"
  "--log:LOG_FOLDER:$(date "+%Y%m%d_%H%M%S")"
  "--optimization:OPTIMIZATION_SCRIPT:"
  "--workingset_size:WORKINGSET_SIZE:"
  "--type:MIGRATION_TYPE:all"
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
    echo "Usage: $0 [--vm=VM] [--size=SIZE] [--cores=CORES] [--tap=TAP] [--iterations=ITERATIONS] [--type=TYPE] [--workingset_size=SIZE] [--optimization=SCRIPT]"
    echo "Migration types: precopy, postcopy, hybrid, all"
    exit 1
  fi
done

# ------------------------------------------------------------------------------------

SOURCE_IP="10.22.196.157"
DESTINATION_IP="10.22.196.155"
VM_IP="10.22.196.203"

LOG_ID=""
POST_COPYABLE=""
MIGRATION=""

# SSH credentials
SOURCE_PASS="primedirective"
DEST_PASS="primedirective"
VM_PASS="workingset"

# IPsec service name
SERVICE_NAME="strongswan-starter"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Validate migration type and set types to run
VALID_TYPES=("precopy" "postcopy" "hybrid" "all")
if [[ ! " ${VALID_TYPES[@]} " =~ " ${MIGRATION_TYPE} " ]]; then
    echo -e "${RED}Error: Invalid migration type '$MIGRATION_TYPE'${NC}"
    echo "Valid types: ${VALID_TYPES[*]}"
    exit 1
fi

# Set migration types array based on input
if [ "$MIGRATION_TYPE" = "all" ]; then
    MIGRATION_TYPES=("precopy" "postcopy" "hybrid")
    echo -e "${BLUE}Running all migration types: ${MIGRATION_TYPES[*]}${NC}"
else
    MIGRATION_TYPES=("$MIGRATION_TYPE")
    echo -e "${BLUE}Running specific migration type: $MIGRATION_TYPE${NC}"
fi

# -------------------------------- IPsec Management Functions --------------------------------

enable_ipsec() {
    echo -e "${BLUE}>>> Enabling IPsec...${NC}"
    
    # Enable for boot
    sudo systemctl enable $SERVICE_NAME 2>/dev/null
    
    # Start the service
    sudo systemctl start $SERVICE_NAME
    
    # Wait a moment for initialization
    sleep 2
    
    # Reload configuration if ipsec command is available
    if command -v ipsec >/dev/null 2>&1; then
        sudo ipsec reload 2>/dev/null
    fi
    
    # Check if service is running
    if systemctl is-active $SERVICE_NAME >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} IPsec enabled and started"
    else
        echo -e "${RED}✗${NC} Failed to start IPsec"
        exit 1
    fi
}

disable_ipsec() {
    echo -e "${BLUE}>>> Disabling IPsec...${NC}"
    
    # Stop connections gracefully
    if command -v ipsec >/dev/null 2>&1; then
        sudo ipsec stop 2>/dev/null
    fi
    
    # Stop the service
    sudo systemctl stop $SERVICE_NAME 2>/dev/null
    
    # Disable from boot
    sudo systemctl disable $SERVICE_NAME 2>/dev/null
    
    # Clear security associations and policies
    sudo ip xfrm state flush 2>/dev/null
    sudo ip xfrm policy flush 2>/dev/null
    
    echo -e "${GREEN}✓${NC} IPsec disabled"
}

# -------------------------------- VM Management Functions --------------------------------

terminate-qemu () {
    sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=60 root@$VM_IP "poweroff" > /dev/null 2>&1
    sleep 5

    DESTINATION_CHECK=$(sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP "pgrep qemu")
    if [[ -n $DESTINATION_CHECK ]]; then
        sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP "pkill qemu"
    fi
    sleep 5
    sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "pkill qemu"
}

get_migration_details() {
    MIGRATION=""
    
    # Wait based on migration type
    if [ "$CURRENT_TYPE" = "precopy" ] || [ "$CURRENT_TYPE" = "hybrid" ]; then
        echo ">>> Waiting for $CURRENT_TYPE migration to complete (allowing for multiple iterations)..."
        sleep 40
    else
        echo ">>> Waiting for $CURRENT_TYPE migration to complete..."
        sleep 20
    fi

    MAX_RETRIES=50
    RETRY=0
    while [[ $MIGRATION != *"completed"* && $RETRY -lt $MAX_RETRIES ]]; do
        sleep 15
        echo ">>> Checking for Migration Status (Attempt $((RETRY + 1))/$MAX_RETRIES)"

        MIGRATION=$(sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
            "bash /mnt/nfs/aamir/Scripts/Migration/Status/migration-status.sh")

        ((RETRY++))
    done

    if [[ $MIGRATION == *"completed"* ]]; then
        echo ">>> Migration completed successfully."
        # Only log migration details
        echo "$MIGRATION" > "logs/${LOG_FOLDER}/${LOG_ID}_migration.txt"
    else
        echo ">>> Migration did not complete after $MAX_RETRIES attempts."
        echo "$MIGRATION" > "logs/${LOG_FOLDER}/${LOG_ID}_migration_incomplete.txt"
    fi
}

start_destination() {
    echo ">>> Starting Destination VM"
    sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP "bash /mnt/nfs/aamir/Scripts/Migration/Automations/vm-start/startDestination.sh $VM $TAP $SIZE $CORES $POST_COPYABLE" &
}

start_source() {
    echo ">>> Starting Source VM"
    sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash /mnt/nfs/aamir/Scripts/General/startSource.sh $VM $SIZE $CORES $TAP" &
}

start_workload() {
    echo ">>> Starting Workingset Workload"
    
    # Calculate workingset size (half of VM RAM if not specified)
    if [[ "$WORKINGSET_SIZE" == "" ]]; then
        WORKINGSET_SIZE=$((SIZE / 2))
        echo ">>> Using default workingset size: ${WORKINGSET_SIZE} MB (half of VM RAM)"
    else
        echo ">>> Using specified workingset size: ${WORKINGSET_SIZE} MB"
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
    
    # Start workingset workload (no output logging, just run in background)
    echo ">>> Starting workingset process with size ${WORKINGSET_SIZE} MB..."
    sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no root@$VM_IP \
    "cd /home/workingset/Desktop && \
    ./workingset $WORKINGSET_SIZE" > /dev/null 2>&1 &
    
    WORKINGSET_PID=$!
    echo ">>> Workingset started with PID: $WORKINGSET_PID"
}

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

    if [ "$CURRENT_TYPE" = "precopy" ]; then
        sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash $TRIGGERS/Pre-Copy/precopy-vm-migrate1.sh"
    elif [ "$CURRENT_TYPE" = "postcopy" ]; then
        sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash $TRIGGERS/Post-Copy/postcopy-vm-migrate.sh"
    elif [ "$CURRENT_TYPE" = "hybrid" ]; then
        sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash $TRIGGERS/Hybrid/hybrid-vm-migrate.sh auto"
    fi
}

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

echo -e "${BLUE}=== Complete VM Migration Test with IPsec ===${NC}"
if [ "$MIGRATION_TYPE" = "all" ]; then
    echo "Testing all migration types: ${MIGRATION_TYPES[*]}"
else
    echo "Testing specific migration type: $MIGRATION_TYPE"
fi
echo "Iterations per type: $ITERATIONS"
echo "VM: $VM, Size: ${SIZE}MB, Cores: $CORES"
echo "Workingset size: ${WORKINGSET_SIZE:-$(($SIZE / 2))}MB"
echo ""

# Enable IPsec at the start
enable_ipsec

# Create logging folder
mkdir -p "logs/${LOG_FOLDER}"
echo "Creating logs/${LOG_FOLDER} folder"

# Run migrations for selected types
for MIGRATION_TYPE_RUN in "${MIGRATION_TYPES[@]}"; do
    echo -e "${YELLOW}=== Starting $MIGRATION_TYPE_RUN Migration Tests ===${NC}"
    
    CURRENT_TYPE="$MIGRATION_TYPE_RUN"
    
    # Set POST_COPYABLE based on migration type
    if [ "$CURRENT_TYPE" = "precopy" ]; then
        POST_COPYABLE="false"
    else
        POST_COPYABLE="true"
    fi
    
    terminate-qemu
    
    for (( i=1; i<=$ITERATIONS; i++ )); do
        echo -e "${BLUE}>>> Starting $CURRENT_TYPE Migration - Iteration $i${NC}"

        timestamp=$(date "+%Y%m%d_%H%M%S")
        LOG_ID="${CURRENT_TYPE}_${VM}_${SIZE}_${timestamp}"

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
        
        echo -e "${GREEN}>>> $CURRENT_TYPE Migration Iteration $i completed${NC}"
        echo ""
    done
    
    echo -e "${GREEN}=== $CURRENT_TYPE Migration Tests Completed ===${NC}"
    echo ""
done

# Disable IPsec at the end (optional)
echo -e "${BLUE}>>> Migration testing completed${NC}"
if [ "$MIGRATION_TYPE" = "all" ]; then
    echo "All migration types completed."
else
    echo "$MIGRATION_TYPE migration completed."
fi
echo "Check logs/${LOG_FOLDER}/ for migration details."
echo ""
echo "IPsec is still enabled. To disable it, run:"
echo "sudo systemctl stop strongswan-starter && sudo systemctl disable strongswan-starter"
