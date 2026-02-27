#!/bin/bash

# ─────────────────────────────────────────────────────────────
# get_migration_details.sh  —  Poll until migration completes
# Usage: bash get_migration_details.sh --source=<ip> --log_folder=<f> --log_id=<id> [--timeout=<sec>]
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARG_TUPLES=(
    "--source:SOURCE_IP:"
    "--timeout:TIMEOUT:360"
    "--log_folder:LOG_FOLDER:"
    "--log_id:LOG_ID:"
)
PARSE_ARGS=("$@")
source "$SCRIPT_DIR/arg_parser.sh"

if [[ -z "$SOURCE_IP" || -z "$LOG_FOLDER" || -z "$LOG_ID" ]]; then
    echo "❌ Missing required arguments: --source, --log_folder, --log_id"
    exit 1
fi

MIGRATION=""
INTERVAL=5
ELAPSED=0

echo ">>> Polling migration status on $SOURCE_IP (timeout: ${TIMEOUT}s)..."

while [ $ELAPSED -lt $TIMEOUT ]; do
    echo ">>> Checking migration status (elapsed: ${ELAPSED}s / ${TIMEOUT}s)..."

    MIGRATION=$(sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$SOURCE_IP" \
        "bash /mnt/nfs/aamir/Scripts/Migration/Status/migration-status.sh")

    if [[ $MIGRATION == *"completed"* ]]; then
        echo "✅ Migration completed successfully."
        sleep 5
        echo "$MIGRATION" > "logs/${LOG_FOLDER}/${LOG_ID}_vm.txt"
        exit 0
    fi

    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

echo "❌ Migration did not complete after ${TIMEOUT} seconds."
echo "Migration timeout after ${TIMEOUT} seconds" > "logs/${LOG_FOLDER}/${LOG_ID}_vm.txt"
exit 1
