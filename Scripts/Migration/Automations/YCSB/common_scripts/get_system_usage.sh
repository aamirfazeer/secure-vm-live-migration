#!/bin/bash

# ─────────────────────────────────────────────────────────────
# get_system_usage.sh  —  Stream system usage from a VM into a log file
# Usage: bash get_system_usage.sh --ip=<ip> --password=<pass> --log_folder=<f> --log_id=<id>
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARG_TUPLES=(
    "--ip:IP:"
    "--password:PASSWORD:"
    "--log_folder:LOG_FOLDER:"
    "--log_id:LOG_ID:"
)
PARSE_ARGS=("$@")
source "$SCRIPT_DIR/arg_parser.sh"

if [[ -z "$IP" || -z "$PASSWORD" ]]; then
    echo "❌ Missing required arguments: --ip, --password"
    exit 1
fi

echo ">>> Monitoring system usage on $IP"
LOG_FILE="logs/${LOG_FOLDER}/${LOG_ID}_system_usage.log"
mkdir -p "logs/${LOG_FOLDER}"

sshpass -p "${PASSWORD}" \
    ssh -o StrictHostKeyChecking=no root@"${IP}" \
    "bash -s" <<'EOF' > "$LOG_FILE" &
#!/bin/bash
echo "timestamp,cpu_idle,mem_total_kb,mem_free_kb,mem_available_kb"
while true; do
    TS=$(date "+%Y-%m-%d %H:%M:%S")
    CPU_IDLE=$(top -bn1 | grep "Cpu(s)" | awk '{print $8}' | tr -d '%id,')
    MEM=$(cat /proc/meminfo | awk '/MemTotal|MemFree|MemAvailable/{printf "%s ", $2}')
    echo "$TS,$CPU_IDLE,$MEM"
    sleep 2
done
EOF

echo ">>> System usage logging started → $LOG_FILE (PID: $!)"
