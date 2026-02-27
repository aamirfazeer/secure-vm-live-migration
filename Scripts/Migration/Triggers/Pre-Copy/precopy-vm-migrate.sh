#!/bin/bash

OPTIMIZATION=${1:-"none"}
HBFDP_TYPE=${2:-"sha1"}
IP=${3:-"163"}

set-hash-type () {
        if [ "$HBFDP_TYPE" = "md5" ]
        then
                echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-parameters", "arguments": {"hbfdp-hash-type": 1 }}' | sudo socat - /media/qmp1
        elif [ "$HBFDP_TYPE" = "murmu3" ]
        then
                echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-parameters", "arguments": {"hbfdp-hash-type": 2 }}' | sudo socat - /media/qmp1
        fi
}

if [ "$OPTIMIZATION" = "xbzrle" ]
then
	sleep 5
	echo ">>> Enabling XBZRLE"
	echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-capabilities", "arguments": {"capabilities":[ { "capability": "xbzrle", "state": true } ]}}' | sudo socat - /media/qmp1
	echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-parameters", "arguments": {"xbzrle-cache-size": 4294967296 }}' | sudo socat - /media/qmp1
elif [ "$OPTIMIZATION" = "compress" ]
then
	sleep 5
        echo ">>> Enabling Data Compression"
        echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-capabilities", "arguments": {"capabilities":[ { "capability": "compress", "state": true } ]}}' | sudo socat - /media/qmp1
        echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-parameters" , "arguments": { "compress-level": 1 }}' | sudo socat - /media/qmp1
elif [ "$OPTIMIZATION" = "dtrack" ]
then
        sleep 5
        echo ">>> Enabling Dtrack"
	echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-capabilities", "arguments": {"capabilities":[ { "capability": "dtrack", "state": true } ]}}' | sudo socat - /media/qmp1
elif [ "$OPTIMIZATION" = "hbfdp" ]
then
        sleep 5
        echo ">>> Enabling HBFDP"
        echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-capabilities", "arguments": {"capabilities":[ { "capability": "hbfdp", "state": true } ]}}' | sudo socat - /media/qmp1
        set-hash-type
elif [ "$OPTIMIZATION" = "xbzrle-hbfdp" ]
then
	sleep 5
        echo ">>> Enabling XBZRLE"
        echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-capabilities", "arguments": {"capabilities":[ { "capability": "xbzrle", "state": true } ]}}' | sudo socat - /media/qmp1
	echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-parameters", "arguments": {"xbzrle-cache-size": 8589934592 }}' | sudo socat - /media/qmp1
        sleep 5
        echo ">>> Enabling HBFDP"
        echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-capabilities", "arguments": {"capabilities":[ { "capability": "hbfdp", "state": true } ]}}' | sudo socat - /media/qmp1
	set-hash-type
elif [ "$OPTIMIZATION" = "xbzrle-dtrack" ]
then
	sleep 5
        echo ">>> Enabling XBZRLE"
        echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-capabilities", "arguments": {"capabilities":[ { "capability": "xbzrle", "state": true } ]}}' | sudo socat - /media/qmp1
	echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-parameters", "arguments": {"xbzrle-cache-size": 8589934592 }}' | sudo socat - /media/qmp1
        sleep 5
        echo ">>> Enabling Dtrack"
	echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-capabilities", "arguments": {"capabilities":[ { "capability": "dtrack", "state": true } ]}}' | sudo socat - /media/qmp1
elif [ "$OPTIMIZATION" = "compress-hbfdp" ]
then
        sleep 5
        echo ">>> Enabling Data Compression"
        echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-capabilities", "arguments": {"capabilities":[ { "capability": "compress", "state": true } ]}}' | sudo socat - /media/qmp1
        echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-parameters" , "arguments": { "compress-level": 1 }}' | sudo socat - /media/qmp1
	sleep 5
        echo ">>> Enabling HBFDP"
	echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-capabilities", "arguments": {"capabilities":[ { "capability": "hbfdp", "state": true } ]}}' | sudo socat - /media/qmp1
        set-hash-type
elif [ "$OPTIMIZATION" = "compress-dtrack" ]
then
        sleep 5
        echo ">>> Enabling Data Compression"
        echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-capabilities", "arguments": {"capabilities":[ { "capability": "compress", "state": true } ]}}' | sudo socat - /media/qmp1
        echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-parameters" , "arguments": { "compress-level": 1 }}' | sudo socat - /media/qmp1
	sleep 5
        echo ">>> Enabling Dtrack"
	echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-capabilities", "arguments": {"capabilities":[ { "capability": "dtrack", "state": true } ]}}' | sudo socat - /media/qmp1
fi

# Migrates VM using QMP
echo '{ "execute": "qmp_capabilities" }{ "execute": "migrate", "arguments" : {"uri": "tcp:10.22.196.'$IP':4444"} }' | sudo socat - /media/qmp1