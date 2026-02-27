#!/bin/bash

IP=${1:-"154"}

#Initial 
echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-capabilities", "arguments": {"capabilities":[ { "capability": "postcopy-ram", "state": true}]}}' | sudo socat - /media/qmp1

# Migrates VM using QMP
echo '{ "execute": "qmp_capabilities" }{ "execute": "migrate", "arguments" : {"uri": "pp:10.22.196.'$IP':4444"} }' | sudo socat - /media/qmp1
