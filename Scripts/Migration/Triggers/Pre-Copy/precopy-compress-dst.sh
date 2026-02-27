#!/bin/bash
echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-capabilities", "arguments": {"capabilities":[ { "capability": "compress", "state": true } ]}}' | sudo socat - /media/qmp1
echo '{"execute": "qmp_capabilities"}{"execute": "migrate-set-parameters" , "arguments": { "compress-level": 1 }}' | sudo socat - /media/qmp1
