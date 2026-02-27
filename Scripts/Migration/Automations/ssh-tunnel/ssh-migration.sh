#!/bin/bash

# SSH Tunnel-Based Secure VM Migration with Quicksort Workload

# Array of "tuples": --flag:VAR_NAME:default_value
ARG_TUPLES=(
  "--vnc:VNC_NUM:1"
  "--vm:VM:idle"
  "--size:SIZE:1024"
  "--cores:CORES:1"
  "--tap:TAP:tap0"
  "--type:TYPE:precopy"
  "--iterations:ITERATIONS:10"
  "--log:LOG_FOLDER:$(date "+%Y%m%d_%H%M%S")_ssh"
  "--optimization:OPTIMIZATION_SCRIPT:"
  "--tunnel-port:TUNNEL_PORT:4444"
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

# SSH credentials
SOURCE_PASS="primedirective"
DEST_PASS="primedirective"
VM_PASS="vmpassword"

# SSH Tunnel Scripts Paths
SSH_TUNNEL_DIR="/mnt/nfs/aamir/Scripts/Migration/Automations/ssh-tunnel"
TRIGGERS_DIR="/mnt/nfs/aamir/Scripts/Migration/Triggers"

terminate-qemu () {
    echo ">>> Terminating QEMU processes..."
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
    echo ">>> Setting up SSH tunnel..."
    
    # Stop any existing tunnel first
    sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
        "bash $SSH_TUNNEL_DIR/stop-ssh-tunnel.sh $TUNNEL_PORT" > /dev/null 2>&1
    
    sleep 5
    
    # Start new SSH tunnel with password authentication
    echo ">>> Starting SSH tunnel on port $TUNNEL_PORT..."
    sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
        "sshpass -p '$DEST_PASS' ssh -f -N -L ${TUNNEL_PORT}:localhost:${TUNNEL_PORT} root@${DESTINATION_IP} -o StrictHostKeyChecking=no -o ServerAliveInterval=30" > /dev/null 2>&1
    
    # Verify tunnel is established
    sleep 10
    TUNNEL_CHECK=$(sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
        "lsof -ti :$TUNNEL_PORT -sTCP:LISTEN")
    
    if [[ -n $TUNNEL_CHECK ]]; then
        echo ">>> SSH tunnel established successfully (PID: $TUNNEL_CHECK)"
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

    MAX_RETRIES=10
    RETRY=0
    while [[ $MIGRATION != *"completed"* && $RETRY -lt $MAX_RETRIES ]]; do
        sleep 10
        echo ">>> Checking for Migration Status (Attempt $((RETRY + 1))/$MAX_RETRIES)"

        MIGRATION=$(sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
            "bash /mnt/nfs/aamir/Scripts/Migration/Status/migration-status.sh")

        ((RETRY++))
    done

    if [[ $MIGRATION == *"completed"* ]]; then
        echo ">>> Migration completed successfully."
        echo $MIGRATION > "logs/${LOG_FOLDER}/${LOG_ID}_vm.txt"
    else
        echo ">>> Migration did not complete after $MAX_RETRIES attempts."
        echo "Migration timeout after $MAX_RETRIES attempts" > "logs/${LOG_FOLDER}/${LOG_ID}_vm.txt"
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
    
    sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP \
        "bash /mnt/nfs/aamir/Scripts/Migration/Automations/vm-start/startDestination.sh $VM $TAP $SIZE $CORES $POST_COPYABLE" &

    sleep 30
}

# Starting the VM in Source Machine
start_source() {
    echo ">>> Starting Source VM"
    sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
        "bash /mnt/nfs/aamir/Scripts/General/startSource.sh $VM $SIZE $CORES $TAP" &
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

# Add function to check quicksort status
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

trigger_secure_migration() {
    local CURRENT_TYPE=$1
    echo ">>> Triggering Secure $CURRENT_TYPE Migration via SSH Tunnel"

    if [ "$CURRENT_TYPE" = "precopy" ]; then
        echo ">>> Starting Pre-copy migration through SSH tunnel..."
        sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
            "bash $SSH_TUNNEL_DIR/secure-precopy-migrate.sh /media/qmp1 $TUNNEL_PORT" > /dev/null 2>&1
            
    elif [ "$CURRENT_TYPE" = "postcopy" ]; then
        echo ">>> Starting Post-copy migration through SSH tunnel..."
        sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
            "bash $SSH_TUNNEL_DIR/secure-postcopy-migrate.sh /media/qmp1 $TUNNEL_PORT" > /dev/null 2>&1
            
    elif [ "$CURRENT_TYPE" = "hybrid" ]; then
        echo ">>> Starting Hybrid migration through SSH tunnel..."
        sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
            "bash $SSH_TUNNEL_DIR/secure-hybrid-migrate.sh /media/qmp1 $TUNNEL_PORT true" > /dev/null 2>&1
    else
        echo ">>> ERROR: Unknown migration type: $CURRENT_TYPE"
        return 1
    fi
}

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

# Function to run a single migration iteration
run_single_ssh_iteration() {
    local CURRENT_TYPE=$1
    local ITER=$2
    
    echo "=========================================="
    echo ">>> Starting SSH Tunnel $CURRENT_TYPE Migration Iteration $ITER"
    echo "=========================================="

    timestamp=$(date "+%Y%m%d_%H%M%S")
    LOG_ID="${CURRENT_TYPE}_ssh_${VM}_${SIZE}_${timestamp}"

    # Step 1: Start VMs
    start_source
    start_destination "$CURRENT_TYPE"
    echo ">>> Waiting for VMs to initialize..."
    sleep 30
    
    # Step 2: Setup SSH Tunnel
    if ! setup_ssh_tunnel; then
        echo ">>> ERROR: Failed to setup SSH tunnel, skipping iteration $ITER"
        return 1
    fi
    
    # Step 3: Run optimization if provided
    run_optimization_script
    sleep 10
    
    # Step 4: Start workload and verify
    start_workload
    sleep 20
    check_workload_status
    sleep 10
    
    # Step 5: Trigger secure migration
    trigger_secure_migration "$CURRENT_TYPE"
    
    # Step 6: Monitor migration completion
    get_migration_details
    
    # Step 7: Final status checks
    echo ">>> Final workload status check..."
    check_workload_status
    
    # Step 8: Cleanup
    terminate-qemu
    cleanup_ssh_tunnel
    sleep 10
    
    # Step 9: Verify log files
    echo ">>> Checking log files..."
    if [ -f "logs/${LOG_FOLDER}/${LOG_ID}_quick_sort.txt" ]; then
        LOG_SIZE=$(wc -c < "logs/${LOG_FOLDER}/${LOG_ID}_quick_sort.txt")
        echo ">>> Quicksort log size: ${LOG_SIZE} bytes"
        if [ $LOG_SIZE -eq 0 ]; then
            echo ">>> WARNING: Quicksort log file is empty!"
        fi
    else
        echo ">>> ERROR: Quicksort log file not created!"
    fi
    
    if [ -f "logs/${LOG_FOLDER}/${LOG_ID}_vm.txt" ]; then
        echo ">>> Migration details log created successfully"
    else
        echo ">>> WARNING: Migration details log not found!"
    fi
    
    echo ">>> Iteration $ITER completed. Waiting before next iteration..."
    sleep 15
}

# ================================ MAIN EXECUTION ================================

echo ">>> SSH Tunnel-Based Secure VM Migration Started"

# Create the logging folder
mkdir -p "logs/${LOG_FOLDER}"
echo ">>> Creating logs/${LOG_FOLDER} folder"

# Initial cleanup
terminate-qemu
cleanup_ssh_tunnel

# Check if type is "all" - if so, run all three types
if [ "$TYPE" = "all" ]; then
    echo "=========================================="
    echo "Running ALL SSH tunnel migration types: precopy, postcopy, hybrid"
    echo "VM: $VM | Size: ${SIZE}MB | Cores: $CORES | Iterations per type: $ITERATIONS"
    echo "Source: $SOURCE_IP | Destination: $DESTINATION_IP"
    echo "Tunnel Port: $TUNNEL_PORT"
    echo "=========================================="
    
    MIGRATION_TYPES=("precopy" "postcopy" "hybrid")
    
    for CURRENT_TYPE in "${MIGRATION_TYPES[@]}"; do
        echo ""
        echo "######################################################"
        echo "# Starting SSH $CURRENT_TYPE migration phase ($ITERATIONS iterations)"
        echo "######################################################"
        echo ""
        
        for (( i=1; i<=$ITERATIONS; i++ )); do
            run_single_ssh_iteration "$CURRENT_TYPE" "$i"
        done
        
        echo ""
        echo "######################################################"
        echo "# Completed all SSH $CURRENT_TYPE migrations"
        echo "######################################################"
        echo ""
        sleep 5
    done
    
    echo "=========================================="
    echo "ALL SSH TUNNEL MIGRATIONS COMPLETED!"
    echo "Total iterations: $((ITERATIONS * 3))"
    echo "Check logs at: logs/${LOG_FOLDER}/"
    echo "=========================================="
else
    # Single type migration (original behavior)
    echo "Running SSH tunnel $TYPE migration with $ITERATIONS iterations"
    echo "Source: $SOURCE_IP | Destination: $DESTINATION_IP"
    echo "Tunnel Port: $TUNNEL_PORT"
    
    for (( i=1; i<=$ITERATIONS; i++ )); do
        run_single_ssh_iteration "$TYPE" "$i"
    done
fi

echo "========================================="
echo ">>> All secure migration iterations completed!"
echo ">>> Logs saved in: logs/${LOG_FOLDER}/"
echo "========================================="
