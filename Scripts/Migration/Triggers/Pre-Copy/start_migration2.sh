#!/bin/bash

# Default to .158 if no IP suffix is provided
IP_SUFFIX=${1:-"158"}
DESTINATION_IP="10.22.196.${IP_SUFFIX}"
QMP_SOCKET="/media/qmp1" # Or whatever your QMP socket path is

# Check if QMP socket exists
if [ ! -S "$QMP_SOCKET" ]; then
    echo "Error: QMP socket $QMP_SOCKET not found."
    exit 1
fi

echo "Migrating to ${DESTINATION_IP}:4444"
echo "Sending QMP commands to ${QMP_SOCKET}"

# QMP commands:
# 1. Enable QMP capabilities (standard first command)
# 2. Disable XBZRLE (to see more raw pages)
# 3. Disable generic compression (to see more raw pages)
# 4. Initiate migration
COMMANDS='{ "execute": "qmp_capabilities" }
          { "execute": "migrate_set_capability", "arguments": { "capability": "xbzrle", "state": false } }
          { "execute": "migrate_set_capability", "arguments": { "capability": "compress", "state": false } }
          { "execute": "migrate", "arguments": { "uri": "tcp:'"${DESTINATION_IP}"':4444" } }'

echo "Executing QMP: ${COMMANDS}"

# Send commands to QMP socket
echo "${COMMANDS}" | sudo socat - "${QMP_SOCKET}"

# Optional: You might want to query migration status afterwards
# sleep 5 # Give migration some time to start
# echo '{ "execute": "qmp_capabilities" }{ "execute": "query-migrate" }' | sudo socat - "${QMP_SOCKET}"
