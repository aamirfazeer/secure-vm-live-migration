#!/bin/bash

# TLS-Enabled VM Migration Automation Script with Quicksort Workload

# Array of "tuples": --flag:VAR_NAME:default_value
ARG_TUPLES=(
  "--vnc:VNC_NUM:1"
  "--vm:VM:idle"
  "--size:SIZE:1024"
  "--cores:CORES:1"
  "--tap:TAP:tap0"
  "--type:TYPE:precopy"
  "--iterations:ITERATIONS:10"
  "--log:LOG_FOLDER:$(date "+%Y%m%d_%H%M%S")_tls"
  "--optimization:OPTIMIZATION_SCRIPT:"
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

SOURCE_IP="10.22.196.158"
DESTINATION_IP="10.22.196.155"
VM_IP="10.22.196.250"

LOG_ID=""
POST_COPYABLE=""
MIGRATION=""
CERT_DIR="/etc/pki/qemu"

# SSH credentials
SOURCE_PASS="primedirective"
DEST_PASS="primedirective"
VM_PASS="vmpassword"

# Check if TLS certificates exist
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
    
    echo ">>> TLS certificates found and ready"
    return 0
}

# Setup TLS certificates if requested
setup_tls_certificates() {
    if [[ "$SETUP_CERTS" == "true" ]]; then
        echo ">>> Setting up TLS certificates on both machines..."
        
        # Setup on source
        echo ">>> Setting up certificates on source machine..."
        sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash /mnt/nfs/aamir/Scripts/Migration/setup_tls_certs.sh"
        
        # Setup on destination
        echo ">>> Setting up certificates on destination machine..."
        sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP "bash /mnt/nfs/aamir/Scripts/Migration/setup_tls_certs.sh"
        
        echo ">>> TLS certificate setup completed"
    fi
}

terminate-qemu() {
    sshpass -p "vmpassword" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=60 root@$VM_IP "poweroff" > /dev/null 2>&1
    sleep 5

    DESTINATION_CHECK=$(sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP "pgrep qemu")
    if [[ -n $DESTINATION_CHECK ]]; then
        sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP "pkill qemu"
    fi
    sleep 5
    sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "pkill qemu"
}

get_migration_details() {
    MIGRATION=""
    sleep 30

    MAX_RETRIES=20
    RETRY=0
    while [[ $MIGRATION != *"completed"* && $RETRY -lt $MAX_RETRIES ]]; do
        sleep 10
        echo ">>> Checking for Migration Status (Attempt $((RETRY + 1))/$MAX_RETRIES)"

        MIGRATION=$(sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
            "bash /mnt/nfs/aamir/Scripts/Migration/Status/migration-status.sh")

        ((RETRY++))
    done

    if [[ $MIGRATION == *"completed"* ]]; then
        echo ">>> TLS Migration completed successfully."
        echo $MIGRATION > "logs/${LOG_FOLDER}/${LOG_ID}_vm.txt"
    else
        echo "TLS Migration did not complete after $MAX_RETRIES attempts."
    fi
}

if [ "$TYPE" = "precopy" ]; then
    POST_COPYABLE="false"
else
    POST_COPYABLE="true"
fi

# Starting TLS-enabled destination
start_tls_destination() {
    echo ">>> Starting TLS-enabled Destination VM"
    sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP "bash /mnt/nfs/aamir/Scripts/Migration/Automations/tls/startDestinationTLS.sh $VM $TAP $SIZE $CORES $POST_COPYABLE" &
}

# Starting TLS-enabled source
start_tls_source() {
    echo ">>> Starting TLS-enabled Source VM"
    sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash /mnt/nfs/aamir/Scripts/Migration/Automations/tls/startSourceTLS.sh $VM $SIZE $CORES $TAP" &
}

# Start workload (same as original)
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

# Check workload status
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

trigger_tls_migration() {
    echo ">>> Triggering TLS-Encrypted Migration"

    if [ "$TYPE" = "precopy" ]; then
        sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash $TRIGGERS/TLS/tls-precopy-migrate.sh"
    elif [ "$TYPE" = "postcopy" ]; then
        sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash $TRIGGERS/TLS/tls-postcopy-migrate.sh"
    elif [ "$TYPE" = "hybrid" ]; then
        sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP "bash $TRIGGERS/TLS/tls-hybrid-migrate.sh auto"
    fi
}

# Create logging folder
mkdir -p "logs/${LOG_FOLDER}"
echo "Creating logs/${LOG_FOLDER} folder"

# Run optimization script
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

# Main execution
echo ">>> TLS-Enabled VM Migration Automation Started"

# Setup certificates if requested
setup_tls_certificates

# Check if certificates exist (locally - adjust path if running remotely)
if ! check_tls_certificates; then
    echo ">>> Please ensure TLS certificates are properly set up on both machines"
    exit 1
fi

terminate-qemu

for (( i=1; i<=$ITERATIONS; i++ )); do
    echo ">>> Starting TLS Migration Iteration $i"

    timestamp=$(date "+%Y%m%d_%H%M%S")
    LOG_ID="${TYPE}_tls_${VM}_${SIZE}_${timestamp}"

    start_tls_source
    start_tls_destination
    echo ">>> Waiting for TLS-enabled VMs to initialize..."
    sleep 30  # Increased wait time for TLS setup
    
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
   
    sleep 20

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
    
    echo ">>> TLS Migration Iteration $i completed"
done

echo ">>> TLS-Enabled VM Migration Automation Completed"
