#!/bin/bash

QMP_SOCKET=${1:-"/media/qmp1"}
TUNNEL_PORT=${2:-"4444"}
AUTO_SWITCH=${3:-"true"}

echo "Triggering Hybrid VM migration via SSH tunnel..."

# Enable postcopy capabilities first
echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-capabilities", "arguments": {"capabilities":[ { "capability": "postcopy-ram", "state": true}]}}' \
    | sudo socat - "$QMP_SOCKET"

# Start precopy migration through SSH tunnel
echo '{ "execute": "qmp_capabilities" }{ "execute": "migrate", "arguments" : {"uri": "tcp:127.0.0.1:'$TUNNEL_PORT'"} }' \
    | sudo socat - "$QMP_SOCKET"

# Auto switch to postcopy if enabled
if [ "$AUTO_SWITCH" = "true" ]; then
    echo "Waiting 5 seconds before switching to postcopy..."
    sleep 5
    echo "Switching to Postcopy..."
    echo '{ "execute": "qmp_capabilities" }{ "execute": "migrate-start-postcopy"}' \
        | sudo socat - "$QMP_SOCKET"
fi
