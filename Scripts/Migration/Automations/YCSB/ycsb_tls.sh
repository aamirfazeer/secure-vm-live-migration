#!/bin/bash

# ══════════════════════════════════════════════════════════════════════
#  ycsb_tls.sh  —  YCSB Workload VM Migration (TLS Encrypted)
# ══════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_SCRIPTS="$SCRIPT_DIR/common_scripts"

# ─── Arguments ───────────────────────────────────────────────────────
ARG_TUPLES=(
    "--vm_img:VM_IMG:oltp"
    "--ram_size:RAM_SIZE:1024"
    "--cores:CORES:1"
    "--tap:TAP:tap0"
    "--type:TYPE:precopy"
    "--iterations:ITERATIONS:10"
    "--log:LOG_FOLDER:$(date "+%Y%m%d_%H%M%S")_tls"
    "--setup_certs:SETUP_CERTS:false"
    "--optimization:OPTIMIZATION_SCRIPT:"
    "--optimization_script_step:OPTIMIZATION_SCRIPT_STEP:"
)
PARSE_ARGS=("$@")
source "$COMMON_SCRIPTS/arg_parser.sh"

# ─── Validate ────────────────────────────────────────────────────────
if [[ "$TYPE" != "precopy" && "$TYPE" != "postcopy" && "$TYPE" != "hybrid" && "$TYPE" != "all" ]]; then
    echo "❌ Invalid --type=$TYPE  (valid: precopy, postcopy, hybrid, all)"
    exit 1
fi

# ─── Infrastructure ──────────────────────────────────────────────────
SOURCE_IP="10.22.196.152"
DESTINATION_IP="10.22.196.154"
VM_IP="10.22.196.209"
VM_PASS="workingset"
CERT_DIR="/etc/pki/qemu"
LOG_ID=""

# ─── TLS helpers ─────────────────────────────────────────────────────
check_tls_certificates() {
    echo ">>> Checking TLS certificates..."
    local missing=()
    [[ ! -f "$CERT_DIR/ca-cert.pem"     ]] && missing+=("CA certificate")
    [[ ! -f "$CERT_DIR/server-cert.pem" ]] && missing+=("Server certificate")
    [[ ! -f "$CERT_DIR/client-cert.pem" ]] && missing+=("Client certificate")
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "❌ Missing certificates: ${missing[*]}"
        echo "   Use --setup_certs=true to auto-provision"
        return 1
    fi
    echo "✅ TLS certificates found."
}

setup_tls_certificates() {
    if [[ "$SETUP_CERTS" == "true" ]]; then
        echo ">>> Setting up TLS certificates on source and destination..."
        sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$SOURCE_IP" \
            "bash /mnt/nfs/aamir/Scripts/Migration/setup_tls_certs.sh"
        sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$DESTINATION_IP" \
            "bash /mnt/nfs/aamir/Scripts/Migration/setup_tls_certs.sh"
        echo ">>> TLS certificate setup complete."
    fi
}

# ─── TLS VM starters ─────────────────────────────────────────────────
start_tls_source() {
    echo ">>> Starting TLS Source VM"
    sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$SOURCE_IP" \
        "nohup bash /mnt/nfs/aamir/Scripts/Migration/Automations/tls/startSourceTLS.sh \
             $VM_IMG $RAM_SIZE $CORES $TAP \
         > /tmp/source_tls_${VM_IMG}.log 2>&1 & disown
         echo '>>> TLS Source VM launch dispatched'"
}

start_tls_destination() {
    local CURRENT_TYPE=$1
    local POST_COPYABLE
    [[ "$CURRENT_TYPE" == "precopy" ]] && POST_COPYABLE="false" || POST_COPYABLE="true"
    echo ">>> Starting TLS Destination VM (post-copyable=$POST_COPYABLE)"
    sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$DESTINATION_IP" \
        "bash /mnt/nfs/aamir/Scripts/Migration/Automations/tls/startDestinationTLS.sh $VM_IMG $TAP $RAM_SIZE $CORES $POST_COPYABLE" &
}

# ─── Workload ────────────────────────────────────────────────────────
start_workload() {
    echo ">>> Starting YCSB Workload in VM"
    sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no root@"$VM_IP" \
        "cd /home/workingset/Desktop/benchbase/target/benchbase-postgres && \
         java -jar benchbase.jar -b ycsb \
              -c config/postgres/sample_ycsb_config.xml \
              -d /home/workingset/Desktop/results/${LOG_ID}_ycsb/ \
              --create=true --load=true --execute=true -s 1 > /dev/null 2>&1 &" &
}

# Wait for VM to come back up after migration (VM moves to destination side)
wait_for_vm_after_migration() {
    local MAX_WAIT=120
    local ELAPSED=0
    local INTERVAL=5
    echo ">>> Waiting for VM at $VM_IP to come back up after migration..."
    sleep 5
    while [ $ELAPSED -lt $MAX_WAIT ]; do
        if sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
               root@"$VM_IP" "echo ok" &>/dev/null; then
            echo "✅ VM back up at $VM_IP after migration (${ELAPSED}s)"
            return 0
        fi
        echo ">>> Still waiting for VM post-migration... (${ELAPSED}s / ${MAX_WAIT}s)"
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    done
    echo "⚠️  VM at $VM_IP did not come back within ${MAX_WAIT}s — attempting results fetch anyway"
    return 1
}

get_ycsb_results() {
    wait_for_vm_after_migration
    echo ">>> Fetching YCSB Results"
    local REMOTE_DIR="/home/workingset/Desktop/results/${LOG_ID}_ycsb/"

    echo ">>> Waiting for $REMOTE_DIR on $VM_IP..."
    local MAX_DIR_WAIT=300
    local DIR_ELAPSED=0
    local DIR_INTERVAL=10

    # Extra stabilization time after migration
    sleep 15

    while [ $DIR_ELAPSED -lt $MAX_DIR_WAIT ]; do
        if sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
               root@"$VM_IP" "[ -d '$REMOTE_DIR' ]" 2>/dev/null; then
            echo ">>> Results directory found, starting rsync"
            break
        fi
        echo ">>> Waiting for results dir... (${DIR_ELAPSED}s / ${MAX_DIR_WAIT}s)"
        sleep $DIR_INTERVAL
        DIR_ELAPSED=$((DIR_ELAPSED + DIR_INTERVAL))
    done

    if [ $DIR_ELAPSED -ge $MAX_DIR_WAIT ]; then
        echo "⚠️  Results directory never appeared after ${MAX_DIR_WAIT}s — skipping rsync"
        return 1
    fi

    sshpass -p "$VM_PASS" rsync \
        -e "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30" \
        -av --progress --no-o --no-g \
        "root@${VM_IP}:${REMOTE_DIR}" \
        "logs/${LOG_FOLDER}/${LOG_ID}_ycsb/"

    sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no root@"$VM_IP" \
        "rm -rf /home/workingset/Desktop/results/*_ycsb"
}

# ─── Single iteration ────────────────────────────────────────────────
run_iteration() {
    local CURRENT_TYPE=$1
    local ITER=$2

    echo ""
    echo "=========================================="
    echo ">>> [TLS] $CURRENT_TYPE — Iteration $ITER"
    echo "=========================================="

    timestamp=$(date "+%Y%m%d_%H%M%S")
    LOG_ID="${CURRENT_TYPE}_tls_${VM_IMG}_${RAM_SIZE}_${timestamp}"

    bash "$COMMON_SCRIPTS/terminate_qemu.sh" \
        --source="$SOURCE_IP" --destination="$DESTINATION_IP"

    start_tls_source
    start_tls_destination "$CURRENT_TYPE"
    echo ">>> Waiting for TLS VMs to initialize (30s)..."
    sleep 30

    if [[ -n "$OPTIMIZATION_SCRIPT" ]]; then
        echo ">>> Running optimization: $OPTIMIZATION_SCRIPT"
        sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$SOURCE_IP" \
            "bash $OPTIMIZATION_SCRIPT"
        sleep 10
    fi

    bash "$COMMON_SCRIPTS/wait_util_vm_is_up.sh" --ip="$VM_IP"

    bash "$COMMON_SCRIPTS/get_system_usage.sh" \
        --ip="$VM_IP" --password="$VM_PASS" \
        --log_folder="$LOG_FOLDER" --log_id="$LOG_ID"

    sleep 20
    start_workload
    sleep 20

    bash "$COMMON_SCRIPTS/trigger_migration.sh" \
        --source="$SOURCE_IP" --type="$CURRENT_TYPE" --mode="tls"

    bash "$COMMON_SCRIPTS/get_migration_details.sh" \
        --source="$SOURCE_IP" --log_folder="$LOG_FOLDER" --log_id="$LOG_ID"

    get_ycsb_results

    echo ">>> Iteration $ITER complete."
    echo "=========================================="
}

# ─── Main ────────────────────────────────────────────────────────────
echo "══════════════════════════════════════════════"
echo "  YCSB TLS Migration  |  $(date)"
echo "  VM: $VM_IMG | RAM: ${RAM_SIZE}MB | Type: $TYPE | Iters: $ITERATIONS"
echo "══════════════════════════════════════════════"

setup_tls_certificates
if ! check_tls_certificates; then
    echo "❌ Aborting: TLS certificates not ready."
    exit 1
fi

bash "$COMMON_SCRIPTS/script_init.sh" \
    --log_folder="$LOG_FOLDER" --optimization="$OPTIMIZATION_SCRIPT"

[[ "$TYPE" == "all" ]] && MIGRATION_TYPES=("precopy" "postcopy" "hybrid") || MIGRATION_TYPES=("$TYPE")

for CURRENT_TYPE in "${MIGRATION_TYPES[@]}"; do
    echo ""
    echo "######################################################"
    echo "#  Starting TLS $CURRENT_TYPE  ($ITERATIONS iterations)"
    echo "######################################################"
    for (( i=1; i<=ITERATIONS; i++ )); do
        run_iteration "$CURRENT_TYPE" "$i"
    done
done

bash "$COMMON_SCRIPTS/terminate_qemu.sh" \
    --source="$SOURCE_IP" --destination="$DESTINATION_IP" \
    --vm_ip="$VM_IP" --password="$VM_PASS"

echo ""
echo "══════════════════════════════════════════════"
echo "  TLS YCSB Complete  |  Logs: logs/$LOG_FOLDER"
echo "══════════════════════════════════════════════"
