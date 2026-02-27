# tls-hybrid-migrate.sh
#!/bin/bash

AUTO=${1:-"false"}
IP=${2:-"154"}

echo ">>> Setting up TLS credentials and hybrid migration"

# Set postcopy capabilities
echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-capabilities", "arguments": {"capabilities":[ { "capability": "postcopy-ram", "state": true}]}}' | sudo socat - /media/qmp-source

# Set TLS credentials
echo '{ "execute": "qmp_capabilities" }{ "execute": "migrate_set_parameter", "arguments": {"tls-creds": "tls0"} }' | sudo socat - /media/qmp-source

# Start migration with TLS
echo '{ "execute": "qmp_capabilities" }{ "execute": "migrate", "arguments": {"uri": "tcp:10.22.196.'$IP':4444"} }' | sudo socat - /media/qmp-source

if [ "$AUTO" = "true" ]; then
    sleep 5
    echo ">>> Switching to Postcopy"
    echo '{ "execute": "qmp_capabilities" }{ "execute": "migrate-start-postcopy"}' | sudo socat - /media/qmp-source
fi
