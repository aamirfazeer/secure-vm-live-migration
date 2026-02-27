#!/bin/bash

# Complete VM Migration Script with SSH Tunnels and Workingset Workload
# Runs all three migration types: precopy, postcopy, and hybrid with SSH tunnel encryption
# Now supports multiple VM sizes with --size=all
# Usage: ./migration_ssh_script.sh [options]

# Array of "tuples": --flag:VAR_NAME:default_value
ARG_TUPLES=(
  "--vnc:VNC_NUM:1"
  "--vm:VM:ycsbNew"
  "--size:SIZE:1024"
  "--cores:CORES:1"
  "--tap:TAP:tap0"
  "--type:TYPE:all"
  "--iterations:ITERATIONS:3"
  "--log:LOG_FOLDER:$(date "+%Y%m%d_%H%M%S")_ssh"
  "--optimization:OPTIMIZATION_SCRIPT:"
  "--workingset_size:WORKINGSET_SIZE:"
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
    echo "Usage: $0 [--vm=VM] [--size=SIZE] [--cores=CORES] [--tap=TAP] [--iterations=ITERATIONS] [--type=TYPE] [--workingset_size=SIZE] [--optimization=SCRIPT] [--tunnel-port=PORT]"
    echo "Migration types: precopy, postcopy, hybrid, all"
    echo "VM sizes: 2048, 4096, 8192, 12288, 16384, all (in MB)"
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

# SSH Tunnel Scripts Paths
SSH_TUNNEL_DIR="/mnt/nfs/aamir/Scripts/Migration/Automations/ssh-tunnel"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Validate migration type and set types to run
VALID_TYPES=("precopy" "postcopy" "hybrid" "all")
if [[ ! " ${VALID_TYPES[@]} " =~ " ${TYPE} " ]]; then
    echo -e "${RED}Error: Invalid migration type '$TYPE'${NC}"
    echo "Valid types: ${VALID_TYPES[*]}"
    exit 1
fi

# Set migration types array based on input
if [ "$TYPE" = "all" ]; then
    MIGRATION_TYPES=("precopy" "postcopy" "hybrid")
    echo -e "${BLUE}Running all migration types: ${MIGRATION_TYPES[*]}${NC}"
else
    MIGRATION_TYPES=("$TYPE")
    echo -e "${BLUE}Running specific migration type: $TYPE${NC}"
fi

# Validate VM size and set sizes to run
VALID_SIZES=("2048" "4096" "8192" "12288" "16384" "all")
if [[ ! " ${VALID_SIZES[@]} " =~ " ${SIZE} " ]]; then
    echo -e "${RED}Error: Invalid VM size '$SIZE'${NC}"
    echo "Valid sizes: ${VALID_SIZES[*]} (in MB)"
    exit 1
fi

# Set VM sizes array based on input
if [ "$SIZE" = "all" ]; then
    VM_SIZES=(2048 4096 8192 12288 16384)
    echo -e "${BLUE}Running tests for all VM sizes: ${VM_SIZES[*]} MB${NC}"
else
    VM_SIZES=("$SIZE")
    echo -e "${BLUE}Running test for VM size: ${SIZE} MB${NC}"
fi

# -------------------------------- SSH Tunnel Management Functions --------------------------------

setup_ssh_tunnel() {
    echo -e "${BLUE}>>> Setting up SSH tunnel...${NC}"
    
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
        echo -e "${GREEN}✓${NC} SSH tunnel established successfully (PID: $TUNNEL_CHECK)"
        return 0
    else
        echo -e "${RED}✗${NC} Failed to establish SSH tunnel"
        return 1
    fi
}

cleanup_ssh_tunnel() {
    echo ">>> Cleaning up SSH tunnel..."
    sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
        "bash $SSH_TUNNEL_DIR/stop-ssh-tunnel.sh $TUNNEL_PORT" > /dev/null 2>&1
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
        echo -e "${GREEN}>>> $CURRENT_TYPE Migration completed successfully.${NC}"
        # Only log migration details
        echo "$MIGRATION" > "logs/${LOG_FOLDER}/${LOG_ID}_migration.txt"
    else
        echo -e "${RED}>>> $CURRENT_TYPE Migration did not complete after $MAX_RETRIES attempts.${NC}"
        echo "$MIGRATION" > "logs/${LOG_FOLDER}/${LOG_ID}_migration_incomplete.txt"
    fi
}

start_destination() {
    echo ">>> Starting Destination VM"
    sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP \
        "bash /mnt/nfs/aamir/Scripts/Migration/Automations/vm-start/startDestination.sh $VM $TAP $CURRENT_SIZE $CORES $POST_COPYABLE" &
}

start_source() {
    echo ">>> Starting Source VM"
    sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
        "bash /mnt/nfs/aamir/Scripts/General/startSource.sh $VM $CURRENT_SIZE $CORES $TAP" &
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

trigger_secure_migration() {
    echo -e "${YELLOW}>>> Triggering Secure $CURRENT_TYPE Migration via SSH Tunnel${NC}"

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

echo -e "${BLUE}========================================================${NC}"
echo -e "${BLUE}=== VM Migration Test with SSH Tunnels ===${NC}"
echo -e "${BLUE}========================================================${NC}"
if [ "$TYPE" = "all" ]; then
    echo "Testing all migration types: ${MIGRATION_TYPES[*]}"
else
    echo "Testing specific migration type: $TYPE"
fi

if [ "$SIZE" = "all" ]; then
    echo "Testing all VM sizes: ${VM_SIZES[*]} MB"
else
    echo "Testing VM size: ${SIZE} MB"
fi

echo "Iterations per type: $ITERATIONS"
echo "VM: $VM, Cores: $CORES"
echo "Source IP: $SOURCE_IP"
echo "Destination IP: $DESTINATION_IP"
echo "SSH Tunnel Port: $TUNNEL_PORT"
echo -e "${BLUE}========================================================${NC}"

# Create logging folder
mkdir -p "logs/${LOG_FOLDER}"
echo "Creating logs/${LOG_FOLDER} folder"

# Initial cleanup
terminate-qemu
cleanup_ssh_tunnel

# Run migrations for each VM size
for CURRENT_SIZE in "${VM_SIZES[@]}"; do
    echo -e "${BLUE}========================================================${NC}"
    echo -e "${BLUE}=== Testing VM Size: ${CURRENT_SIZE}MB (${CURRENT_SIZE}MB RAM) ===${NC}"
    echo -e "${BLUE}=== Working Set: $((CURRENT_SIZE / 2))MB ===${NC}"
    echo -e "${BLUE}========================================================${NC}"
    
    # Run migrations for specified or all types
    for MIGRATION_TYPE in "${MIGRATION_TYPES[@]}"; do
        echo -e "${YELLOW}=== Starting $MIGRATION_TYPE Migration Tests with SSH Tunnels (${CURRENT_SIZE}MB) ===${NC}"
        
        CURRENT_TYPE="$MIGRATION_TYPE"
        
        # Set POST_COPYABLE based on migration type
        if [ "$CURRENT_TYPE" = "precopy" ]; then
            POST_COPYABLE="false"
        else
            POST_COPYABLE="true"
        fi
        
        terminate-qemu
        cleanup_ssh_tunnel
        
        for (( i=1; i<=$ITERATIONS; i++ )); do
            echo "========================================="
            echo -e "${BLUE}>>> Starting $CURRENT_TYPE SSH Migration (${CURRENT_SIZE}MB) - Iteration $i${NC}"
            echo "========================================="

            timestamp=$(date "+%Y%m%d_%H%M%S")
            LOG_ID="${CURRENT_TYPE}_ssh_${VM}_${CURRENT_SIZE}MB_${timestamp}"

            # Step 1: Start VMs
            start_source
            start_destination
            echo ">>> Waiting for VMs to initialize..."
            sleep 30
            
            # Step 2: Setup SSH Tunnel
            if ! setup_ssh_tunnel; then
                echo -e "${RED}>>> ERROR: Failed to setup SSH tunnel, skipping iteration $i${NC}"
                continue
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
            trigger_secure_migration
            
            # Step 6: Monitor migration completion
            get_migration_details
            
            # Step 7: Final status checks
            echo ">>> Final workload status check..."
            check_workload_status
            
            # Step 8: Cleanup
            terminate-qemu
            cleanup_ssh_tunnel
            sleep 10
            
            echo -e "${GREEN}>>> $CURRENT_TYPE SSH Migration (${CURRENT_SIZE}MB) Iteration $i completed${NC}"
            echo ""
        done
        
        echo -e "${GREEN}=== $CURRENT_TYPE SSH Migration Tests (${CURRENT_SIZE}MB) Completed ===${NC}"
        echo ""
    done
    
    echo -e "${GREEN}=== All migrations for ${CURRENT_SIZE}MB completed ===${NC}"
    echo ""
done

echo -e "${BLUE}========================================================${NC}"
echo -e "${BLUE}>>> SSH-Tunnel Migration testing completed${NC}"
echo -e "${BLUE}========================================================${NC}"
if [ "$TYPE" = "all" ]; then
    echo "All migration types completed for all sizes."
else
    echo "$TYPE migration completed for all sizes."
fi
echo "Check logs/${LOG_FOLDER}/ for migration details."
echo ""
echo -e "${YELLOW}Note: SSH tunnels have been cleaned up${NC}"
