# tls-postcopy-migrate.sh
#!/bin/bash

IP=${1:-"154"}

echo ">>> Setting up TLS credentials and postcopy capabilities"

# Set postcopy capabilities
echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-capabilities", "arguments": {"capabilities":[ { "capability": "postcopy-ram", "state": true}]}}' | sudo socat - /media/qmp-source

# Set TLS credentials
echo '{ "execute": "qmp_capabilities" }{ "execute": "migrate_set_parameter", "arguments": {"tls-creds": "tls0"} }' | sudo socat - /media/qmp-source

# Migrate with TLS using postcopy
echo '{ "execute": "qmp_capabilities" }{ "execute": "migrate", "arguments": {"uri": "tcp:10.22.196.'$IP':4444"} }' | sudo socat - /media/qmp-source

