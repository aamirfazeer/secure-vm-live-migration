#!/bin/bash

# Default destination IP
DEST_IP=${1:-"10.22.196.154"}
DEST_PORT=${2:-4444}
SSH_USER=${3:-"root"}

echo "Starting SSH tunnel from localhost:$DEST_PORT to $DEST_IP:$DEST_PORT..."

ssh -f -N -L ${DEST_PORT}:localhost:${DEST_PORT} ${SSH_USER}@${DEST_IP} -o StrictHostKeyChecking=no

if [ $? -eq 0 ]; then
    echo "SSH Tunnel established successfully."
else
    echo "Failed to establish SSH Tunnel."
    exit 1
fi

