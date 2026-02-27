#!/bin/bash

################################################################################
# IPsec (strongSwan) Management Script for Adaptive Migration
# Usage: ./ipsec_manager.sh [start|stop|restart|status|disable|enable]
################################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SERVICE_NAME="strongswan-starter"

print_status() {
    echo -e "${BLUE}=== IPsec Status ===${NC}"
    
    # Check service status
    if systemctl is-active $SERVICE_NAME >/dev/null 2>&1; then
        echo -e "Service: ${GREEN}ACTIVE${NC}"
    else
        echo -e "Service: ${RED}INACTIVE${NC}"
    fi
    
    if systemctl is-enabled $SERVICE_NAME >/dev/null 2>&1; then
        echo -e "Boot startup: ${GREEN}ENABLED${NC}"
    else
        echo -e "Boot startup: ${RED}DISABLED${NC}"
    fi
    
    # Check connections
    local sa_count=$(ip xfrm state 2>/dev/null | grep -c "^src")
    local policy_count=$(ip xfrm policy 2>/dev/null | grep -c "^src.*dst.*dir")
    
    echo "Security Associations: $sa_count"
    echo "IPsec Policies: $policy_count"
    
    if command -v ipsec >/dev/null 2>&1; then
        local connections=$(ipsec status 2>/dev/null)
        if [[ -n "$connections" ]]; then
            echo -e "${YELLOW}Active Connections:${NC}"
            echo "$connections" | sed 's/^/  /'
        fi
    fi
    echo ""
}

stop_ipsec() {
    echo -e "${YELLOW}Stopping IPsec...${NC}"
    
    # Stop connections gracefully
    if command -v ipsec >/dev/null 2>&1; then
        sudo ipsec stop 2>/dev/null
    fi
    
    # Stop the service
    sudo systemctl stop $SERVICE_NAME 2>/dev/null
    
    # Clear security associations and policies
    echo "Clearing security associations and policies..."
    sudo ip xfrm state flush 2>/dev/null
    sudo ip xfrm policy flush 2>/dev/null
    
    echo -e "${GREEN}✓${NC} IPsec stopped"
}

start_ipsec() {
    echo -e "${YELLOW}Starting IPsec...${NC}"
    
    # Start the service
    sudo systemctl start $SERVICE_NAME
    
    # Wait a moment for initialization
    sleep 2
    
    # Reload configuration if ipsec command is available
    if command -v ipsec >/dev/null 2>&1; then
        sudo ipsec reload 2>/dev/null
    fi
    
    echo -e "${GREEN}✓${NC} IPsec started"
}

disable_ipsec() {
    echo -e "${YELLOW}Disabling IPsec (will not start at boot)...${NC}"
    
    # Stop first
    stop_ipsec
    
    # Disable from boot
    sudo systemctl disable $SERVICE_NAME 2>/dev/null
    
    echo -e "${GREEN}✓${NC} IPsec disabled"
}

enable_ipsec() {
    echo -e "${YELLOW}Enabling IPsec (will start at boot)...${NC}"
    
    # Enable for boot
    sudo systemctl enable $SERVICE_NAME
    
    # Start now
    start_ipsec
    
    echo -e "${GREEN}✓${NC} IPsec enabled"
}

restart_ipsec() {
    echo -e "${YELLOW}Restarting IPsec...${NC}"
    
    stop_ipsec
    sleep 2
    start_ipsec
    
    echo -e "${GREEN}✓${NC} IPsec restarted"
}

case "${1:-status}" in
    "start")
        start_ipsec
        print_status
        ;;
    "stop")
        stop_ipsec
        print_status
        ;;
    "restart")
        restart_ipsec
        print_status
        ;;
    "disable")
        disable_ipsec
        print_status
        ;;
    "enable")
        enable_ipsec
        print_status
        ;;
    "status")
        print_status
        ;;
    *)
        echo "Usage: $0 [start|stop|restart|status|disable|enable]"
        echo ""
        echo "Commands:"
        echo "  start    - Start IPsec service"
        echo "  stop     - Stop IPsec service (temporary)"
        echo "  restart  - Restart IPsec service"
        echo "  disable  - Stop and disable IPsec (permanent)"
        echo "  enable   - Enable and start IPsec"
        echo "  status   - Show current status (default)"
        echo ""
        print_status
        ;;
esac
