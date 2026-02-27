#!/bin/bash

AUTO=${1:-"false"}
IP=${2:-"154"}

# Ready Postcopy RAM
echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-capabilities", "arguments": {"capabilities":[ { "capability": "postcopy-ram", "state": true}]}}'  | sudo socat - /media/qmp1

# Migrates VM using QMP
echo '{ "execute": "qmp_capabilities" }{ "execute": "migrate", "arguments" : {"uri": "tcp:10.22.196.'$IP':4444"} }' | sudo socat - /media/qmp1

if [ "$AUTO" = "true" ]
then
	sleep 5
	echo ">>> Switching to Postcopy"
	echo '{ "execute": "qmp_capabilities" }{ "execute": "migrate-start-postcopy"}'  | sudo socat - /media/qmp1
fi
