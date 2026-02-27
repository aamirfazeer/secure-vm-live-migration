#!/bin/bash

# Complete VM Migration Script with TLS and Workingset Workload
# Runs all three migration types: precopy, postcopy, and hybrid with TLS encryption
# Usage: ./complete_migration_tls_script.sh [options]

# Array of "tuples": --flag:VAR_NAME:default_value
ARG_TUPLES=(
  "--vnc:VNC_NUM:1"
  "--vm:VM:idle"
  "--size:SIZE:1024"
  "--cores:CORES:1"
  "--tap:TAP:tap0"
  "--type:TYPE:"
  "--iterations:ITERATIONS:3"
  "--log:LOG_FOLDER:$(date "+%Y%m%d_%H%M%S")_tls"
  "--optimization:OPTIMIZATION_SCRIPT:"
  "--workingset_size:WORKINGSET_SIZE:"
  "--setup-certs:SETUP_CERTS:false"
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

SOURCE_IP="10.22.196.155"
DESTINATION_IP="10.22.196.158"
VM_IP="10.22.196.203"

LOG_ID=""
POST_COPYABLE=""
MIGRATION=""
MIGRATION_TYPES=("precopy" "postcopy" "hybrid")
CERT_DIR="/etc/pki/qemu"

# SSH credentials
SOURCE_PASS="primedirective"
DEST_PASS="primedirective"
VM_PASS="workingset"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# -------------------------------- TLS Management Functions --------------------------------

check_tls_certificates() {
    echo ">>> Checking TLS certificates..."
    
    local missing_certs=()
    
    if [ ! -f "$CERT_DIR/ca-cert.pem" ]; then
        missing_certs+=("CA certificate")
    fi
    if [ ! -f "$CERT_DIR/server-cert.pem" ]; then
        missing_certs+=("Server certificate")
    fi
    if [ ! -f "$CERT_DIR/client-cert.pem" ]; then
        missing_certs+=("Client certificate")
    fi
    
    if [ ${#missing_certs[@]} -gt 0 ]; then
        echo ">>> ERROR: Missing certificates: ${missing_certs[*]}"
        echo ">>> Run setup_tls_certs.sh first or use --setup-certs=true"
        return 1
    fi
    
    echo -e "${GREEN}✓${NC} TLS certificates found and ready"
    return 0
}

setup_tls_certificates() {
    if [[ "$SETUP_CERTS" == "true" ]]; then
        echo -e "${BLUE}>>> Setting up TLS certificates on both machines...${NC}"
        
        # Setup on source
        echo ">>> Setting up certificates on source machine..."
        sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash /mnt/nfs/aamir/Scripts/Migration/setup_tls_certs.sh"
        
        # Setup on destination
        echo ">>> Setting up certificates on destination machine..."
        sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP "bash /mnt/nfs/aamir/Scripts/Migration/setup_tls_certs.sh"
        
        echo -e "${GREEN}✓${NC} TLS certificate setup completed"
    fi
}

# -------------------------------- VM Management Functions --------------------------------

terminate-qemu() {
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

    MAX_RETRIES=60
    RETRY=0
    while [[ $MIGRATION != *"completed"* && $RETRY -lt $MAX_RETRIES ]]; do
        sleep 15
        echo ">>> Checking for Migration Status (Attempt $((RETRY + 1))/$MAX_RETRIES)"

        MIGRATION=$(sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
            "bash /mnt/nfs/aamir/Scripts/Migration/Status/migration-status.sh")

        ((RETRY++))
    done

    if [[ $MIGRATION == *"completed"* ]]; then
        echo -e "${GREEN}>>> $CURRENT_TYPE Migration completed successfully.${NC}"
        # Only log migration details
        echo "$MIGRATION" > "logs/${LOG_FOLDER}/${LOG_ID}_migration.txt"
    else
        echo -e "${RED}>>> $CURRENT_TYPE Migration did not complete after $MAX_RETRIES attempts.${NC}"
        echo "$MIGRATION" > "logs/${LOG_FOLDER}/${LOG_ID}_migration_incomplete.txt"
    fi
}

# Starting TLS-enabled destination
start_tls_destination() {
    echo ">>> Starting TLS-enabled Destination VM"
    sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP "bash /mnt/nfs/aamir/Scripts/Migration/Automations/tls/startDestinationTLS.sh $VM $TAP $SIZE $CORES $POST_COPYABLE" &
}

# Starting TLS-enabled source
start_tls_source() {
    echo ">>> Starting TLS-enabled Source VM"
    sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash /mnt/nfs/aamir/Scripts/Migration/Automations/tls/startSourceTLS.sh $VM $SIZE $CORES $TAP" &
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

trigger_tls_migration() {
    echo ">>> Triggering TLS-Encrypted $CURRENT_TYPE Migration"

    if [ "$CURRENT_TYPE" = "precopy" ]; then
        sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash $TRIGGERS/TLS/tls-precopy-migrate.sh"
    elif [ "$CURRENT_TYPE" = "postcopy" ]; then
        sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash $TRIGGERS/TLS/tls-postcopy-migrate.sh"
    elif [ "$CURRENT_TYPE" = "hybrid" ]; then
        sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash $TRIGGERS/TLS/tls-hybrid-migrate.sh auto"
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

echo -e "${BLUE}=== Complete VM Migration Test with TLS Encryption ===${NC}"
if [[ "$TYPE" != "" ]]; then
    echo "Testing migration type: $TYPE"
else
    echo "Testing all migration types: precopy, postcopy, hybrid"
fi
echo "Iterations per type: $ITERATIONS"
echo "VM: $VM, Size: ${SIZE}MB, Cores: $CORES"
echo "Workingset size: ${WORKINGSET_SIZE:-$(($SIZE / 2))}MB"
echo ""

# Setup TLS certificates if requested
setup_tls_certificates

# Check if TLS certificates exist
if ! check_tls_certificates; then
    echo -e "${RED}>>> Please ensure TLS certificates are properly set up on both machines${NC}"
    echo ">>> Use --setup-certs=true to automatically set up certificates"
    exit 1
fi

# Create logging folder
mkdir -p "logs/${LOG_FOLDER}"
echo "Creating logs/${LOG_FOLDER} folder"

# Determine which migration types to run
if [[ "$TYPE" != "" ]]; then
    # Validate the specified type
    if [[ ! " ${MIGRATION_TYPES[@]} " =~ " ${TYPE} " ]]; then
        echo -e "${RED}>>> ERROR: Invalid migration type '$TYPE'. Valid types: precopy, postcopy, hybrid${NC}"
        exit 1
    fi
    MIGRATION_TYPES=("$TYPE")
    echo ">>> Running single migration type: $TYPE"
else
    echo ">>> Running all migration types: precopy, postcopy, hybrid"
fi

# Run migrations for specified or all types
for MIGRATION_TYPE in "${MIGRATION_TYPES[@]}"; do
    echo -e "${YELLOW}=== Starting $MIGRATION_TYPE Migration Tests with TLS ===${NC}"
    
    CURRENT_TYPE="$MIGRATION_TYPE"
    
    # Set POST_COPYABLE based on migration type
    if [ "$CURRENT_TYPE" = "precopy" ]; then
        POST_COPYABLE="false"
    else
        POST_COPYABLE="true"
    fi
    
    terminate-qemu
    
    for (( i=1; i<=$ITERATIONS; i++ )); do
        echo -e "${BLUE}>>> Starting $CURRENT_TYPE TLS Migration - Iteration $i${NC}"

        timestamp=$(date "+%Y%m%d_%H%M%S")
        LOG_ID="${CURRENT_TYPE}_tls_${VM}_${SIZE}_${timestamp}"

        start_tls_source
        start_tls_destination
        echo ">>> Waiting for TLS-enabled VMs to initialize..."
        sleep 35  # Increased wait time for TLS setup
        
        run_optimization_script
        sleep 10
        
        # Start workload and verify it's running
        start_workload
        sleep 20
        check_workload_status
        sleep 10
        
        trigger_tls_migration
        get_migration_details
        
        # Final workload status check
        echo ">>> Final workload status check..."
        check_workload_status
        
        terminate-qemu
        sleep 10
        
        echo -e "${GREEN}>>> $CURRENT_TYPE TLS Migration Iteration $i completed${NC}"
        echo ""
    done
    
    echo -e "${GREEN}=== $CURRENT_TYPE TLS Migration Tests Completed ===${NC}"
    echo ""
done

echo -e "${BLUE}>>> TLS-Enabled Migration testing completed for all types${NC}"
echo "Check logs/${LOG_FOLDER}/ for migration details."
echo ""
echo -e "${YELLOW}Note: TLS certificates remain configured for future use${NC}"
