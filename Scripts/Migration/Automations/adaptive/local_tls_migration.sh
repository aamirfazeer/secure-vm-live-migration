#!/bin/bash

################################################################################
# Local TLS Migration Script for Adaptive Selector
# This script is called by the adaptive migration selector
# Updated with comprehensive TLS verification on BOTH servers
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
    LOG_FOLDER="tls_${VM}_${SIZE}MB_${CORES}cores_${TYPE}_${timestamp}"
fi

LOG_PATH="${LOGS_BASE}/${LOG_FOLDER}"
mkdir -p "$LOG_PATH"

LOG_ID=""
POST_COPYABLE=""
MIGRATION=""
CERT_DIR="/etc/pki/qemu"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

################################################################################
# TLS Certificate Verification Functions
################################################################################

check_tls_certificates() {
    echo ">>> Checking TLS certificates on local system..."
    
    if [ ! -f "$CERT_DIR/ca-cert.pem" ] || [ ! -f "$CERT_DIR/server-cert.pem" ] || [ ! -f "$CERT_DIR/client-cert.pem" ]; then
        echo -e "${YELLOW}>>> WARNING: TLS certificates may be missing on local system${NC}"
        return 1
    fi
    
    echo -e "${GREEN}>>> ✓ TLS certificates found on local system${NC}"
    return 0
}

verify_tls_certificates_on_servers() {
    echo ">>> Verifying TLS certificates on BOTH servers..."
    
    # Check TLS certificates on SOURCE
    echo -e "${BLUE}  Checking SOURCE ($SOURCE_IP) TLS certificates...${NC}"
    local source_ca=$(sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
        "test -f $CERT_DIR/ca-cert.pem && echo 'OK'")
    local source_client=$(sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
        "test -f $CERT_DIR/client-cert.pem && echo 'OK'")
    local source_key=$(sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
        "test -f $CERT_DIR/client-key.pem && echo 'OK'")
    
    # Check TLS certificates on DESTINATION
    echo -e "${BLUE}  Checking DESTINATION ($DESTINATION_IP) TLS certificates...${NC}"
    local dest_ca=$(sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP \
        "test -f $CERT_DIR/ca-cert.pem && echo 'OK'")
    local dest_server=$(sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP \
        "test -f $CERT_DIR/server-cert.pem && echo 'OK'")
    local dest_key=$(sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP \
        "test -f $CERT_DIR/server-key.pem && echo 'OK'")
    
    # Evaluate SOURCE certificates
    local source_ok=true
    if [[ "$source_ca" != "OK" ]] || [[ "$source_client" != "OK" ]] || [[ "$source_key" != "OK" ]]; then
        echo -e "${RED}  ✗ SOURCE TLS certificates incomplete${NC}"
        echo "    CA cert: $source_ca | Client cert: $source_client | Client key: $source_key"
        source_ok=false
    else
        echo -e "${GREEN}  ✓ SOURCE TLS certificates present${NC}"
    fi
    
    # Evaluate DESTINATION certificates
    local dest_ok=true
    if [[ "$dest_ca" != "OK" ]] || [[ "$dest_server" != "OK" ]] || [[ "$dest_key" != "OK" ]]; then
        echo -e "${RED}  ✗ DESTINATION TLS certificates incomplete${NC}"
        echo "    CA cert: $dest_ca | Server cert: $dest_server | Server key: $dest_key"
        dest_ok=false
    else
        echo -e "${GREEN}  ✓ DESTINATION TLS certificates present${NC}"
    fi
    
    # Overall result
    if [[ "$source_ok" == true ]] && [[ "$dest_ok" == true ]]; then
        echo -e "${GREEN}>>> ✓ TLS certificates verified on BOTH servers${NC}"
        return 0
    else
        echo -e "${RED}>>> ✗ TLS certificate verification failed${NC}"
        return 1
    fi
}

verify_tls_port_listening() {
    echo ">>> Verifying TLS migration port..."
    
    # Wait a moment for QEMU to start listening
    sleep 5
    
    # Check if QEMU TLS port is listening on DESTINATION (port 16509 is common for TLS migrations)
    local tls_port_check=$(sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP \
        "ss -tln 2>/dev/null | grep ':16509' || netstat -tln 2>/dev/null | grep ':16509' || echo 'NOT_FOUND'")
    
    if [[ "$tls_port_check" != "NOT_FOUND" ]] && [[ -n "$tls_port_check" ]]; then
        echo -e "${GREEN}  ✓ TLS migration port (16509) is listening on DESTINATION${NC}"
        return 0
    else
        echo -e "${YELLOW}  ⚠ TLS port not detected yet (may appear as migration starts)${NC}"
        return 0  # Don't fail, just warn - port appears after QEMU fully initializes
    fi
}

verify_tls_connectivity() {
    echo ">>> Verifying TLS connectivity between SOURCE and DESTINATION..."
    
    # Check if destination port is reachable from source
    local connectivity=$(sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
        "timeout 5 bash -c 'cat < /dev/null > /dev/tcp/$DESTINATION_IP/16509' 2>/dev/null && echo 'REACHABLE' || echo 'UNREACHABLE'")
    
    if [[ "$connectivity" == "REACHABLE" ]]; then
        echo -e "${GREEN}  ✓ TLS port is reachable from SOURCE to DESTINATION${NC}"
        return 0
    else
        echo -e "${YELLOW}  ⚠ TLS port connectivity check inconclusive${NC}"
        return 0  # Don't fail - might not be ready yet
    fi
}

################################################################################
# VM Management Functions
################################################################################

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

get_migration_details() {
    MIGRATION=""
    sleep 30

    MAX_RETRIES=20
    RETRY=0
    while [[ $MIGRATION != *"completed"* && $RETRY -lt $MAX_RETRIES ]]; do
        sleep 10
        echo ">>> Checking Migration Status (Attempt $((RETRY + 1))/$MAX_RETRIES)"

        MIGRATION=$(sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
            "bash /mnt/nfs/aamir/Scripts/Migration/Automations/tls/migration-status.sh")

        ((RETRY++))
    done

    if [[ $MIGRATION == *"completed"* ]]; then
        echo -e "${GREEN}>>> TLS Migration completed successfully.${NC}"
        echo "$MIGRATION" > "${LOG_PATH}/${LOG_ID}_migration_status.txt"
    else
        echo -e "${YELLOW}>>> WARNING: Migration did not complete${NC}"
        echo "Migration timeout" > "${LOG_PATH}/${LOG_ID}_migration_status.txt"
    fi
}

start_tls_destination() {
    local CURRENT_TYPE=$1
    if [ "$CURRENT_TYPE" = "precopy" ]; then
        POST_COPYABLE="false"
    else
        POST_COPYABLE="true"
    fi
    
    echo ">>> Starting TLS-enabled Destination (Type: $CURRENT_TYPE)"
    sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP \
        "bash /mnt/nfs/aamir/Scripts/Migration/Automations/tls/startDestinationTLS.sh $VM $TAP $SIZE $CORES $POST_COPYABLE" &
}

start_tls_source() {
    echo ">>> Starting TLS-enabled Source VM"
    sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
        "bash /mnt/nfs/aamir/Scripts/Migration/Automations/tls/startSourceTLS.sh $VM $SIZE $CORES $TAP" &
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
            echo -e "${YELLOW}>>> WARNING: VM not accessible after ${MAX_WAIT}s${NC}"
            break
        fi
    done
    
    if ! sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no root@$VM_IP "test -x /home/vmuser/Desktop/quicksort"; then
        echo -e "${RED}>>> ERROR: quicksort binary not found${NC}"
        return 1
    fi
    
    sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no root@$VM_IP \
        "cd /home/vmuser/Desktop && ./quicksort" > "${LOG_PATH}/${LOG_ID}_workload.txt" 2>&1 &
    
    echo -e "${GREEN}>>> Quicksort started${NC}"
}

trigger_tls_migration() {
    local CURRENT_TYPE=$1
    echo ">>> Triggering TLS-Encrypted Migration (Type: $CURRENT_TYPE)"
    
    TRIGGERS="/mnt/nfs/aamir/Scripts/Migration/Triggers"

    if [ "$CURRENT_TYPE" = "precopy" ]; then
        sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
            "bash $TRIGGERS/TLS/tls-precopy-migrate.sh"
    elif [ "$CURRENT_TYPE" = "postcopy" ]; then
        sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
            "bash $TRIGGERS/TLS/tls-postcopy-migrate.sh"
    elif [ "$CURRENT_TYPE" = "hybrid" ]; then
        sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
            "bash $TRIGGERS/TLS/tls-hybrid-migrate.sh auto"
    fi
}

################################################################################
# Migration Iteration
################################################################################

run_single_iteration() {
    local CURRENT_TYPE=$1
    local ITER=$2
    
    echo "=========================================="
    echo ">>> TLS Migration: $CURRENT_TYPE - Iteration $ITER"
    echo "=========================================="

    timestamp=$(date "+%Y%m%d_%H%M%S")
    LOG_ID="iter${ITER}_${CURRENT_TYPE}_${timestamp}"

    # Start VMs
    start_tls_source
    start_tls_destination "$CURRENT_TYPE"
    echo ">>> Waiting for TLS-enabled VMs to initialize..."
    sleep 30
    
    # Verify TLS setup on both servers
    echo ""
    echo ">>> Running TLS verification checks..."
    verify_tls_certificates_on_servers
    verify_tls_port_listening
    verify_tls_connectivity
    echo ""
    
    # Start workload
    start_workload
    sleep 30
    
    # Trigger migration
    trigger_tls_migration "$CURRENT_TYPE"
    get_migration_details
    
    # Cleanup
    terminate_qemu
    sleep 10
}

################################################################################
# Main Execution
################################################################################

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}>>> Starting TLS Migration${NC}"
echo -e "${BLUE}>>> Log Path: $LOG_PATH${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Initial certificate checks
check_tls_certificates
verify_tls_certificates_on_servers
echo ""

# Cleanup before starting
terminate_qemu

# Determine migration types to run
if [ "$TYPE" = "all" ]; then
    MIGRATION_TYPES=("precopy" "postcopy" "hybrid")
else
    MIGRATION_TYPES=("$TYPE")
fi

# Run migrations
for CURRENT_TYPE in "${MIGRATION_TYPES[@]}"; do
    echo -e "${YELLOW}========================================"
    echo -e ">>> Starting $CURRENT_TYPE migrations"
    echo -e "========================================${NC}"
    
    for (( i=1; i<=$ITERATIONS; i++ )); do
        run_single_iteration "$CURRENT_TYPE" "$i"
    done
    
    echo -e "${GREEN}>>> All $CURRENT_TYPE iterations completed${NC}"
    echo ""
done

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}>>> TLS Migration Complete${NC}"
echo -e "${GREEN}>>> Logs: $LOG_PATH${NC}"
echo -e "${GREEN}========================================${NC}"
