#!/bin/bash

# Complete VM Migration Script with TLS and Workingset Workload
# Supports multiple VM sizes and migration types automatically
# Usage: ./migration_tls_script.sh [options]
# Example: ./migration_tls_script.sh --type=all --size=all --iterations=15

# Array of "tuples": --flag:VAR_NAME:default_value
ARG_TUPLES=(
  "--vnc:VNC_NUM:1"
  "--vm:VM:ycsbNew"
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

SOURCE_IP="10.22.196.154"
DESTINATION_IP="10.22.196.155"
VM_IP="10.22.196.203"

LOG_ID=""
POST_COPYABLE=""
MIGRATION=""
MIGRATION_TYPES=("precopy" "postcopy" "hybrid")
VM_SIZES=(2048 4096 8192 12288 16384)  # 2GB, 4GB, 8GB, 12GB, 16GB
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

    MAX_RETRIES=80
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
    echo ">>> Starting TLS-enabled Destination VM (Size: ${CURRENT_SIZE}MB)"
    sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP "bash /mnt/nfs/aamir/Scripts/Migration/Automations/tls/startDestinationTLS.sh $VM $TAP $CURRENT_SIZE $CORES $POST_COPYABLE" &
}

# Starting TLS-enabled source
start_tls_source() {
    echo ">>> Starting TLS-enabled Source VM (Size: ${CURRENT_SIZE}MB)"
    sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash /mnt/nfs/aamir/Scripts/Migration/Automations/tls/startSourceTLS.sh $VM $CURRENT_SIZE $CORES $TAP" &
}

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
    
    # Start workingset workload (no output logging, just run in background)
    echo ">>> Starting workingset process with size ${CURRENT_WORKINGSET_SIZE} MB..."
    sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no root@$VM_IP \
    "cd /home/workingset/Desktop && \
    ./workingset $CURRENT_WORKINGSET_SIZE" > /dev/null 2>&1 &
    
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
echo "Source IP: $SOURCE_IP"
echo "Destination IP: $DESTINATION_IP"
echo ""

# Handle --type parameter
if [[ "$TYPE" == "all" ]]; then
    echo "Testing all migration types: precopy postcopy hybrid"
    TYPES_TO_RUN=("${MIGRATION_TYPES[@]}")
elif [[ "$TYPE" != "" ]]; then
    # Validate the specified type
    if [[ ! " ${MIGRATION_TYPES[@]} " =~ " ${TYPE} " ]]; then
        echo -e "${RED}>>> ERROR: Invalid migration type '$TYPE'. Valid types: precopy, postcopy, hybrid, all${NC}"
        exit 1
    fi
    echo "Testing migration type: $TYPE"
    TYPES_TO_RUN=("$TYPE")
else
    echo "Testing all migration types: precopy postcopy hybrid"
    TYPES_TO_RUN=("${MIGRATION_TYPES[@]}")
fi

# Handle --size parameter
if [[ "$SIZE" == "all" ]]; then
    echo "Testing all VM sizes: ${VM_SIZES[@]} MB"
    SIZES_TO_RUN=("${VM_SIZES[@]}")
else
    echo "Testing VM size: ${SIZE} MB"
    SIZES_TO_RUN=("$SIZE")
fi

echo "Iterations per type: $ITERATIONS"
echo "VM: $VM, Cores: $CORES"
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
echo ""

# Summary file
SUMMARY_FILE="logs/${LOG_FOLDER}/test_summary.txt"
echo "=== Migration Test Summary ===" > "$SUMMARY_FILE"
echo "Start Time: $(date)" >> "$SUMMARY_FILE"
echo "Source: $SOURCE_IP" >> "$SUMMARY_FILE"
echo "Destination: $DESTINATION_IP" >> "$SUMMARY_FILE"
echo "VM: $VM" >> "$SUMMARY_FILE"
echo "Migration Types: ${TYPES_TO_RUN[@]}" >> "$SUMMARY_FILE"
echo "VM Sizes: ${SIZES_TO_RUN[@]} MB" >> "$SUMMARY_FILE"
echo "Iterations per configuration: $ITERATIONS" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"

# Counter for overall progress
TOTAL_TESTS=$((${#TYPES_TO_RUN[@]} * ${#SIZES_TO_RUN[@]} * ITERATIONS))
CURRENT_TEST=0

# Run migrations for all combinations of size and type
for VM_SIZE in "${SIZES_TO_RUN[@]}"; do
    echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  Testing VM Size: ${VM_SIZE} MB ($(($VM_SIZE / 1024))GB)  ║${NC}"
    echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    CURRENT_SIZE="$VM_SIZE"
    
    for MIGRATION_TYPE in "${TYPES_TO_RUN[@]}"; do
        echo -e "${YELLOW}=== Starting $MIGRATION_TYPE Migration Tests (${VM_SIZE}MB) ===${NC}"
        
        CURRENT_TYPE="$MIGRATION_TYPE"
        
        # Set POST_COPYABLE based on migration type
        if [ "$CURRENT_TYPE" = "precopy" ]; then
            POST_COPYABLE="false"
        else
            POST_COPYABLE="true"
        fi
        
        terminate-qemu
        
        for (( i=1; i<=$ITERATIONS; i++ )); do
            CURRENT_TEST=$((CURRENT_TEST + 1))
            echo -e "${BLUE}>>> Starting $CURRENT_TYPE TLS Migration - Size: ${VM_SIZE}MB - Iteration $i/$ITERATIONS (Test $CURRENT_TEST/$TOTAL_TESTS)${NC}"

            timestamp=$(date "+%Y%m%d_%H%M%S")
            LOG_ID="${CURRENT_TYPE}_tls_${VM}_${VM_SIZE}MB_iter${i}_${timestamp}"

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
            
            # Log to summary
            if [[ $MIGRATION == *"completed"* ]]; then
                echo "[SUCCESS] $CURRENT_TYPE - ${VM_SIZE}MB - Iteration $i" >> "$SUMMARY_FILE"
            else
                echo "[FAILED] $CURRENT_TYPE - ${VM_SIZE}MB - Iteration $i" >> "$SUMMARY_FILE"
            fi
            
            terminate-qemu
            sleep 10
            
            echo -e "${GREEN}>>> $CURRENT_TYPE TLS Migration (${VM_SIZE}MB) Iteration $i completed${NC}"
            echo ""
        done
        
        echo -e "${GREEN}=== $CURRENT_TYPE TLS Migration Tests (${VM_SIZE}MB) Completed ===${NC}"
        echo ""
    done
    
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  Completed all tests for ${VM_SIZE}MB  ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
done

# Final summary
echo "End Time: $(date)" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"
echo "Total tests completed: $CURRENT_TEST" >> "$SUMMARY_FILE"

echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  TLS-Enabled Migration Testing Completed  ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Check logs/${LOG_FOLDER}/ for detailed migration logs."
echo "Summary available in: $SUMMARY_FILE"
echo ""
echo -e "${YELLOW}Note: TLS certificates remain configured for future use${NC}"
