#!/bin/bash

# ─────────────────────────────────────────────────────────────
# trigger_migration.sh  —  Trigger the correct migration script
# Usage: bash trigger_migration.sh --source=<ip> --type=<precopy|postcopy|hybrid> [--mode=<plain|tls|ipsec|ssh>] [--tunnel_port=<port>]
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARG_TUPLES=(
    "--source:SOURCE_IP:"
    "--type:TYPE:precopy"
    "--mode:MODE:plain"
    "--tunnel_port:TUNNEL_PORT:4444"
)
PARSE_ARGS=("$@")
source "$SCRIPT_DIR/arg_parser.sh"

if [[ -z "$SOURCE_IP" ]]; then
    echo "❌ Missing required argument: --source"
    exit 1
fi

TRIGGERS="/mnt/nfs/aamir/Scripts/Migration/Triggers"
SSH_TUNNEL_DIR="/mnt/nfs/aamir/Scripts/Migration/Automations/ssh-tunnel"

echo ">>> Triggering [$MODE] $TYPE migration from $SOURCE_IP"

case "$MODE" in

    plain|ipsec)
        if [[ "$TYPE" == "precopy" ]]; then
            sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$SOURCE_IP" \
                "bash $TRIGGERS/Pre-Copy/precopy-vm-migrate1.sh"
        elif [[ "$TYPE" == "postcopy" ]]; then
            sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$SOURCE_IP" \
                "bash $TRIGGERS/Post-Copy/postcopy-vm-migrate.sh"
        elif [[ "$TYPE" == "hybrid" ]]; then
            sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$SOURCE_IP" \
                "bash $TRIGGERS/Hybrid/hybrid-vm-migrate.sh auto"
        fi
        ;;

    tls)
        if [[ "$TYPE" == "precopy" ]]; then
            sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$SOURCE_IP" \
                "bash $TRIGGERS/TLS/tls-precopy-migrate.sh"
        elif [[ "$TYPE" == "postcopy" ]]; then
            sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$SOURCE_IP" \
                "bash $TRIGGERS/TLS/tls-postcopy-migrate.sh"
        elif [[ "$TYPE" == "hybrid" ]]; then
            sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$SOURCE_IP" \
                "bash $TRIGGERS/TLS/tls-hybrid-migrate.sh auto"
        fi
        ;;

    ssh)
        QMP_SOCKET="/media/qmp1"
        if [[ "$TYPE" == "precopy" ]]; then
            sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$SOURCE_IP" \
                "bash $SSH_TUNNEL_DIR/secure-precopy-migrate.sh $QMP_SOCKET $TUNNEL_PORT" > /dev/null 2>&1
        elif [[ "$TYPE" == "postcopy" ]]; then
            sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$SOURCE_IP" \
                "bash $SSH_TUNNEL_DIR/secure-postcopy-migrate.sh $QMP_SOCKET $TUNNEL_PORT" > /dev/null 2>&1
        elif [[ "$TYPE" == "hybrid" ]]; then
            sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@"$SOURCE_IP" \
                "bash $SSH_TUNNEL_DIR/secure-hybrid-migrate.sh $QMP_SOCKET $TUNNEL_PORT true" > /dev/null 2>&1
        fi
        ;;

    *)
        echo "❌ Unknown migration mode: $MODE (valid: plain, tls, ipsec, ssh)"
        exit 1
        ;;
esac

echo ">>> Migration trigger sent."
