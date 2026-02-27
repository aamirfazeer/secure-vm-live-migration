#!/bin/bash

QMP_SOCKET=${1:-"/media/qmp1"}
TUNNEL_PORT=${2:-"4444"}

echo "Triggering Pre-copy VM migration via SSH tunnel..."

echo '{ "execute": "qmp_capabilities" }{ "execute": "migrate", "arguments" : {"uri": "tcp:127.0.0.1:'$TUNNEL_PORT'"} }' \
    | sudo socat - "$QMP_SOCKET"
