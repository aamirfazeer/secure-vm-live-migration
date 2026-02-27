#!/bin/bash

# Default forwarded port
FORWARD_PORT=${1:-4444}

echo "Looking for SSH tunnel on port $FORWARD_PORT..."

# Find SSH PID listening on TCP port (IPv4 or IPv6)
TUNNEL_PID=$(sudo lsof -ti :$FORWARD_PORT -sTCP:LISTEN)

if [ -z "$TUNNEL_PID" ]; then
    echo "No active SSH tunnel found on port $FORWARD_PORT."
else
    echo "Stopping SSH tunnel with PID $TUNNEL_PID..."
    sudo kill "$TUNNEL_PID"
    echo "SSH tunnel on port $FORWARD_PORT stopped."
fi

