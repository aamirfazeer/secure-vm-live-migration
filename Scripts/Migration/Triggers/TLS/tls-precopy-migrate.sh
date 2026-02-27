# tls-precopy-migrate.sh
#!/bin/bash

IP=${1:-"154"}

echo ">>> Setting up TLS credentials and migrating with precopy"

# Set TLS credentials
echo '{ "execute": "qmp_capabilities" }{ "execute": "migrate_set_parameter", "arguments": {"tls-creds": "tls0"} }' | sudo socat - /media/qmp-source

# Migrate with TLS
echo '{ "execute": "qmp_capabilities" }{ "execute": "migrate", "arguments": {"uri": "tcp:10.22.196.'$IP':4444"} }' | sudo socat - /media/qmp-source
