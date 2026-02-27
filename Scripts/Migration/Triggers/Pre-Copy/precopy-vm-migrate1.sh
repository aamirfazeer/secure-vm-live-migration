#!/bin/bash

IP=${1:-"154"}

# Migrates VM using QMP
echo '{ "execute": "qmp_capabilities" }{ "execute": "migrate", "arguments" : {"uri": "tcp:10.22.196.'$IP':4444"} }' | sudo socat - /media/qmp1
