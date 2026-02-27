#!/bin/bash

# Script to stop all SSH tunnels between 10.22.196.155 and 10.22.196.158
# Usage: ./stop_all_ssh_tunnels.sh

HOST_155="10.22.196.157"
HOST_158="10.22.196.155"
SSH_PASSWORD="primedirective"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}     SSH Tunnel Stopper${NC}"
    echo -e "${BLUE}  $HOST_155 ↔ $HOST_158${NC}"
    echo -e "${BLUE}================================${NC}"
    echo ""
}

stop_ssh_tunnels_on_host() {
    local host=$1
    local host_name=$2
    
    echo -e "${YELLOW}Stopping SSH tunnels on $host_name ($host):${NC}"
    
    # Kill SSH tunnel processes (those with -L, -R, -D flags)
    echo "  Killing SSH tunnel processes..."
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no root@$host \
        "pkill -f 'ssh.*-[LRD]'" 2>/dev/null
    
    # Kill autossh processes (from your output showing autossh to AWS)
    echo "  Killing autossh processes..."
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no root@$host \
        "pkill autossh" 2>/dev/null
    
    # Kill specific SSH connections between the two hosts
    echo "  Killing SSH connections between hosts..."
    if [ "$host" = "$HOST_155" ]; then
        # On 155, kill connections to 158
        sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no root@$host \
            "pkill -f 'ssh.*$HOST_158'" 2>/dev/null
    else
        # On 158, kill connections to 155
        sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no root@$host \
            "pkill -f 'ssh.*$HOST_155'" 2>/dev/null
    fi
    
    # Kill any remaining SSH processes that might be tunnels
    echo "  Cleaning up any remaining tunnel processes..."
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no root@$host \
        "for pid in \$(lsof -ti :2222,:3333,:4444,:4445,:8080,:9090 -sTCP:LISTEN 2>/dev/null); do kill \$pid 2>/dev/null; done" 2>/dev/null
    
    sleep 2
    echo -e "  ${GREEN}✓${NC} Cleanup completed on $host_name"
}

verify_cleanup() {
    echo -e "${YELLOW}Verifying tunnel cleanup:${NC}"
    
    # Check for remaining SSH tunnel processes on both hosts
    local tunnels_155=$(sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no root@$HOST_155 \
        "ps aux | grep -E 'ssh.*-[LRD]|autossh' | grep -v grep" 2>/dev/null)
    
    local tunnels_158=$(sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no root@$HOST_158 \
        "ps aux | grep -E 'ssh.*-[LRD]|autossh' | grep -v grep" 2>/dev/null)
    
    if [[ -z "$tunnels_155" && -z "$tunnels_158" ]]; then
        echo -e "  ${GREEN}✓${NC} All SSH tunnels stopped successfully"
    else
        echo -e "  ${YELLOW}⚠${NC} Some tunnel processes may still be running:"
        if [[ -n "$tunnels_155" ]]; then
            echo -e "    ${BLUE}Host $HOST_155:${NC}"
            echo "$tunnels_155" | sed 's/^/      /'
        fi
        if [[ -n "$tunnels_158" ]]; then
            echo -e "    ${BLUE}Host $HOST_158:${NC}"
            echo "$tunnels_158" | sed 's/^/      /'
        fi
    fi
}

check_cross_connectivity() {
    echo -e "${YELLOW}Checking if tunnel connectivity is disabled:${NC}"
    
    # Try to connect through tunnel (should fail now)
    local result_155_to_158=$(timeout 10 sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no root@$HOST_155 \
        "timeout 5 sshpass -p '$SSH_PASSWORD' ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no root@$HOST_158 'echo TUNNEL_TEST'" 2>/dev/null)
    
    if [[ "$result_155_to_158" == "TUNNEL_TEST" ]]; then
        echo -e "  ${YELLOW}⚠${NC} Direct SSH still works (this is normal - only tunnels are stopped)"
    else
        echo -e "  ${GREEN}✓${NC} Cross connectivity check completed"
    fi
}

# Force stop function for stubborn processes
force_stop_all() {
    echo -e "${RED}Force stopping all SSH-related processes (use with caution):${NC}"
    
    # This is more aggressive - kills all SSH connections except the current one
    local current_connection_155=$(sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no root@$HOST_155 \
        "who am i | awk '{print \$NF}' | tr -d '()'" 2>/dev/null)
    
    local current_connection_158=$(sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no root@$HOST_158 \
        "who am i | awk '{print \$NF}' | tr -d '()'" 2>/dev/null)
    
    echo "  Current connections: $current_connection_155, $current_connection_158"
    echo "  This will preserve your current SSH sessions but kill tunnel processes"
    
    # Kill all SSH processes except those belonging to current sessions
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no root@$HOST_155 \
        "pkill -f 'ssh.*-' 2>/dev/null || true" 2>/dev/null
    
    sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no root@$HOST_158 \
        "pkill -f 'ssh.*-' 2>/dev/null || true" 2>/dev/null
    
    echo -e "  ${GREEN}✓${NC} Force stop completed"
}

# Main execution
print_header

echo -e "${BLUE}Stopping SSH tunnels between $HOST_155 and $HOST_158${NC}"
echo ""

# Stop tunnels on both hosts
stop_ssh_tunnels_on_host $HOST_155 "Host 155"
stop_ssh_tunnels_on_host $HOST_158 "Host 158"

echo ""
verify_cleanup
echo ""
check_cross_connectivity

echo ""
echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}           SUMMARY${NC}"
echo -e "${BLUE}================================${NC}"
echo -e "${GREEN}✓${NC} SSH tunnel stopping process completed"
echo -e "${YELLOW}Note:${NC} Direct SSH connectivity between hosts is preserved"
echo -e "${YELLOW}Note:${NC} You can restart tunnels anytime using your migration scripts"
echo ""

# Optional: Ask if user wants to force stop everything
read -p "Do you want to force stop ALL SSH processes (more aggressive)? [y/N]: " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    force_stop_all
    echo ""
    verify_cleanup
fi

echo -e "${GREEN}Done!${NC}"
