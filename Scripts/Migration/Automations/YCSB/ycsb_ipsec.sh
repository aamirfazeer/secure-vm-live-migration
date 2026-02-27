#!/bin/bash

# ══════════════════════════════════════════════════════════════════════
#  ycsb_ipsec.sh  —  YCSB Workload VM Migration (IPsec / strongSwan)
#
#  Enables IPsec on BOTH source and destination before each iteration,
#  verifies SAs are established, then disables IPsec after the run.
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
    "--log:LOG_FOLDER:$(date "+%Y%m%d_%H%M%S")_ipsec"
    "--ipsec_manager:IPSEC_MANAGER:/mnt/nfs/aamir/Scripts/Migration/Automations/ipsec/ipsec_manager.sh"
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
LOG_ID=""

# ─── IPsec management ────────────────────────────────────────────────
enable_ipsec() {
    echo ">>> Enabling IPsec on SOURCE ($SOURCE_IP)..."
    sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$SOURCE_IP" \
        "bash $IPSEC_MANAGER enable"

    echo ">>> Enabling IPsec on DESTINATION ($DESTINATION_IP)..."
    sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$DESTINATION_IP" \
        "bash $IPSEC_MANAGER enable"

    echo ">>> Waiting for IPsec SAs to establish (10s)..."
    sleep 10

    local src_sa dest_sa
    src_sa=$(sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$SOURCE_IP" \
        "ip xfrm state 2>/dev/null | grep -c '^src'" 2>/dev/null)
    dest_sa=$(sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$DESTINATION_IP" \
        "ip xfrm state 2>/dev/null | grep -c '^src'" 2>/dev/null)

    echo ">>> IPsec SAs — Source: $src_sa | Destination: $dest_sa"
    if [[ "$src_sa" -gt 0 && "$dest_sa" -gt 0 ]]; then
        echo "✅ IPsec active on both machines."
    else
        echo "⚠️  IPsec SA count low — tunnel may not be fully up. Check strongSwan logs if migration fails."
    fi
}

disable_ipsec() {
    echo ">>> Disabling IPsec on SOURCE ($SOURCE_IP)..."
    sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$SOURCE_IP" \
        "bash $IPSEC_MANAGER disable" > /dev/null 2>&1

    echo ">>> Disabling IPsec on DESTINATION ($DESTINATION_IP)..."
    sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$DESTINATION_IP" \
        "bash $IPSEC_MANAGER disable" > /dev/null 2>&1

    echo ">>> IPsec disabled on both machines."
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
    echo ">>> [IPsec] $CURRENT_TYPE — Iteration $ITER"
    echo "=========================================="

    timestamp=$(date "+%Y%m%d_%H%M%S")
    LOG_ID="${CURRENT_TYPE}_ipsec_${VM_IMG}_${RAM_SIZE}_${timestamp}"

    bash "$COMMON_SCRIPTS/terminate_qemu.sh" \
        --source="$SOURCE_IP" --destination="$DESTINATION_IP"

    # 1. Enable IPsec on both machines BEFORE starting VMs
    enable_ipsec

    # 2. Start VMs
    bash "$COMMON_SCRIPTS/start_source_script.sh" \
        --source="$SOURCE_IP" --vm_img="$VM_IMG" --ram_size="$RAM_SIZE" \
        --cores="$CORES" --tap="$TAP" \
        --optimization="$OPTIMIZATION_SCRIPT" \
        --optimization_script_step="$OPTIMIZATION_SCRIPT_STEP"
    sleep 10

    bash "$COMMON_SCRIPTS/start_destination_script.sh" \
        --destination="$DESTINATION_IP" --vm_img="$VM_IMG" --ram_size="$RAM_SIZE" \
        --cores="$CORES" --tap="$TAP" --type="$CURRENT_TYPE" \
        --optimization="$OPTIMIZATION_SCRIPT" \
        --optimization_script_step="$OPTIMIZATION_SCRIPT_STEP"

    # 3. Wait for VM
    bash "$COMMON_SCRIPTS/wait_util_vm_is_up.sh" --ip="$VM_IP"

    bash "$COMMON_SCRIPTS/get_system_usage.sh" \
        --ip="$VM_IP" --password="$VM_PASS" \
        --log_folder="$LOG_FOLDER" --log_id="$LOG_ID"

    # 4. Start workload
    sleep 20
    start_workload
    sleep 20

    # 5. Trigger migration (IPsec is transparent at network layer — uses plain triggers)
    bash "$COMMON_SCRIPTS/trigger_migration.sh" \
        --source="$SOURCE_IP" --type="$CURRENT_TYPE" --mode="ipsec"

    # 6. Monitor completion
    bash "$COMMON_SCRIPTS/get_migration_details.sh" \
        --source="$SOURCE_IP" --log_folder="$LOG_FOLDER" --log_id="$LOG_ID"

    # 7. Collect results
    get_ycsb_results

    # 8. Disable IPsec after migration
    disable_ipsec

    echo ">>> Iteration $ITER complete."
    echo "=========================================="
}

# ─── Main ────────────────────────────────────────────────────────────
echo "══════════════════════════════════════════════"
echo "  YCSB IPsec Migration  |  $(date)"
echo "  VM: $VM_IMG | RAM: ${RAM_SIZE}MB | Type: $TYPE | Iters: $ITERATIONS"
echo "  IPsec Manager: $IPSEC_MANAGER"
echo "══════════════════════════════════════════════"

bash "$COMMON_SCRIPTS/script_init.sh" \
    --log_folder="$LOG_FOLDER" --optimization="$OPTIMIZATION_SCRIPT"

# Start from a clean IPsec state
disable_ipsec

[[ "$TYPE" == "all" ]] && MIGRATION_TYPES=("precopy" "postcopy" "hybrid") || MIGRATION_TYPES=("$TYPE")

for CURRENT_TYPE in "${MIGRATION_TYPES[@]}"; do
    echo ""
    echo "######################################################"
    echo "#  Starting IPsec $CURRENT_TYPE  ($ITERATIONS iterations)"
    echo "######################################################"
    for (( i=1; i<=ITERATIONS; i++ )); do
        run_iteration "$CURRENT_TYPE" "$i"
    done
done

bash "$COMMON_SCRIPTS/terminate_qemu.sh" \
    --source="$SOURCE_IP" --destination="$DESTINATION_IP" \
    --vm_ip="$VM_IP" --password="$VM_PASS"

disable_ipsec

echo ""
echo "══════════════════════════════════════════════"
echo "  IPsec YCSB Complete  |  Logs: logs/$LOG_FOLDER"
echo "══════════════════════════════════════════════"
