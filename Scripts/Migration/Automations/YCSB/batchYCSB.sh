#!/bin/bash

# ══════════════════════════════════════════════════════════════════════
#  batchYCSB.sh  —  Batch runner for YCSB VM migration experiments
#
#  Usage:
#    ./batchYCSB.sh [--mode=all|plain|tls|ipsec|ssh]
#                   [--type=all|precopy|postcopy|hybrid]
#                   [--rounds=10]
#                   [--optimization=<script>]
#                   [--optimization_script_step=<step>]
#                   [--tunnel_port=4444]
#                   [--log=<folder>]
# ══════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_SCRIPTS="$SCRIPT_DIR/common_scripts"

# ─── Argument parsing ────────────────────────────────────────────────
ARG_TUPLES=(
    "--mode:BATCH_MODE:all"
    "--type:BATCH_TYPE:all"
    "--rounds:ROUNDS:10"
    "--optimization:OPTIMIZATION_SCRIPT:"
    "--optimization_script_step:OPTIMIZATION_SCRIPT_STEP:"
    "--tunnel_port:TUNNEL_PORT:4444"
    "--log:LOG_FOLDER:$(date "+%Y%m%d_%H%M%S")_batch"
)
PARSE_ARGS=("$@")
source "$COMMON_SCRIPTS/arg_parser.sh"

# ─── Sizes and types ─────────────────────────────────────────────────
SIZES=(1024 2048 4096 6144 8192 10240 12288)

[[ "$BATCH_TYPE" == "all" ]] && TYPES=("precopy" "postcopy" "hybrid") || TYPES=("$BATCH_TYPE")
[[ "$BATCH_MODE" == "all" ]] && MODES=("plain" "tls" "ipsec" "ssh")   || MODES=("$BATCH_MODE")

# ─── Validate ────────────────────────────────────────────────────────
for m in "${MODES[@]}"; do
    if [[ "$m" != "plain" && "$m" != "tls" && "$m" != "ipsec" && "$m" != "ssh" ]]; then
        echo "❌ Invalid --mode=$m  (valid: plain, tls, ipsec, ssh, all)"
        exit 1
    fi
done

# ─── Summary ─────────────────────────────────────────────────────────
TOTAL=$((${#MODES[@]} * ${#TYPES[@]} * ${#SIZES[@]} * ROUNDS))
echo "══════════════════════════════════════════════════════════"
echo "  YCSB Batch Migration Runner  |  $(date)"
echo "══════════════════════════════════════════════════════════"
echo "  Modes      : ${MODES[*]}"
echo "  Types      : ${TYPES[*]}"
echo "  Sizes (MB) : ${SIZES[*]}"
echo "  Rounds     : $ROUNDS"
echo "  Log folder : logs/$LOG_FOLDER"
[[ -n "$OPTIMIZATION_SCRIPT" ]] && echo "  Optimization: $OPTIMIZATION_SCRIPT"
echo "  Total runs : $TOTAL"
echo "══════════════════════════════════════════════════════════"

# ─── Helper ──────────────────────────────────────────────────────────
get_script() {
    case "$1" in
        plain)  echo "$SCRIPT_DIR/ycsb.sh" ;;
        tls)    echo "$SCRIPT_DIR/ycsb_tls.sh" ;;
        ipsec)  echo "$SCRIPT_DIR/ycsb_ipsec.sh" ;;
        ssh)    echo "$SCRIPT_DIR/ycsb_ssh.sh" ;;
    esac
}

# ─── Main batch loop ──────────────────────────────────────────────────
COMPLETED=0
SKIPPED=0

for mode in "${MODES[@]}"; do
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  MODE: $(echo "$mode" | tr '[:lower:]' '[:upper:]')"
    echo "╚══════════════════════════════════════════════╝"

    YCSB_SCRIPT=$(get_script "$mode")

    if [[ ! -f "$YCSB_SCRIPT" ]]; then
        echo "❌ Script not found: $YCSB_SCRIPT — skipping mode $mode"
        continue
    fi

    for (( round=1; round<=ROUNDS; round++ )); do
        echo ""
        echo "==================== Round $round / $ROUNDS ===================="

        for type in "${TYPES[@]}"; do
            # Skip multifd + postcopy/hybrid (not compatible)
            if [[ "$OPTIMIZATION_SCRIPT" == *"multifd"* && \
                  ( "$type" == "postcopy" || "$type" == "hybrid" ) ]]; then
                echo "⏭️  Skipping $mode/$type (multifd incompatible with $type)"
                (( SKIPPED++ ))
                continue
            fi

            for size in "${SIZES[@]}"; do
                echo ""
                echo "┌──────────────────────────────────────────────┐"
                echo "│  $mode | $type | ${size}MB | Round $round"
                echo "└──────────────────────────────────────────────┘"

                # Build extra args for ssh mode
                EXTRA_ARGS=()
                [[ "$mode" == "ssh" ]] && EXTRA_ARGS+=("--tunnel_port=$TUNNEL_PORT")

                bash "$YCSB_SCRIPT" \
                    --ram_size="$size" \
                    --type="$type" \
                    --log="$LOG_FOLDER" \
                    --iterations=1 \
                    --optimization="$OPTIMIZATION_SCRIPT" \
                    --optimization_script_step="$OPTIMIZATION_SCRIPT_STEP" \
                    "${EXTRA_ARGS[@]}"

                EXIT_CODE=$?
                (( COMPLETED++ ))
                if [[ $EXIT_CODE -eq 0 ]]; then
                    echo "✅ Done: $mode/$type/${size}MB (Round $round)"
                else
                    echo "⚠️  Non-zero exit ($EXIT_CODE): $mode/$type/${size}MB (Round $round)"
                fi
                echo "──────────────────────────────────────────────"

            done  # sizes
        done      # types

        echo "==================== End of Round $round ===================="
    done          # rounds

    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  MODE COMPLETE: $mode"
    echo "╚══════════════════════════════════════════════╝"
done              # modes

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  BATCH COMPLETE  |  $(date)"
echo "──────────────────────────────────────────────────────────"
echo "  Total attempted : $COMPLETED"
echo "  Skipped         : $SKIPPED"
echo "  Log folder      : logs/$LOG_FOLDER"
echo "══════════════════════════════════════════════════════════"
