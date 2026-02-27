#!/bin/bash

QMP_SOCKET=${1:-"/media/qmp1"}
TUNNEL_PORT=${2:-"4444"}

echo "Triggering Post-copy VM migration via SSH tunnel..."

# Enable postcopy capabilities first
echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-capabilities", "arguments": {"capabilities":[ { "capability": "postcopy-ram", "state": true}]}}' \
    | sudo socat - "$QMP_SOCKET"

# Start migration through SSH tunnel
echo '{ "execute": "qmp_capabilities" }{ "execute": "migrate", "arguments" : {"uri": "tcp:127.0.0.1:'$TUNNEL_PORT'"} }' \
    | sudo socat - "$QMP_SOCKET"
