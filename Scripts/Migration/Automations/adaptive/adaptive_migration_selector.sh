#!/bin/bash

################################################################################
# Adaptive Secure Live VM Migration Strategy Selector
# 
# This script automatically:
# 1. Monitors system CPU load and network bandwidth
# 2. Categorizes resources into quality buckets
# 3. Applies Algorithm 1 to select optimal secure migration strategy
# 4. Executes the selected migration with appropriate parameters
################################################################################

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
SOURCE_IP="10.22.196.152"
DESTINATION_IP="10.22.196.154"
VM_IP="10.22.196.250"

# Default parameters (can be overridden by command line)
SECURITY_LEVEL="medium"  # high, medium, low
URGENCY_LEVEL="medium"   # high, medium, low
VM_NAME="idle"
VM_SIZE="1024"
CORES="1"
TAP="tap0"
ITERATIONS="10"
MIGRATION_NIC=""         # Will auto-detect if empty

# Scripts directory - LOCAL scripts in adaptive folder
SCRIPTS_BASE="/mnt/nfs/aamir/Scripts/Migration/Automations/adaptive"
IPSEC_SCRIPT="${SCRIPTS_BASE}/local_ipsec_migration.sh"
TLS_SCRIPT="${SCRIPTS_BASE}/local_tls_migration.sh"
SSH_SCRIPT="${SCRIPTS_BASE}/local_ssh_migration.sh"
DEFAULT_SCRIPT="${SCRIPTS_BASE}/local_ipsec_migration.sh"

IPSEC_MANAGER="${SCRIPTS_BASE}/ipsec_manager.sh"

# Logs directory - inside adaptive folder
LOGS_BASE="${SCRIPTS_BASE}/logs"

################################################################################
# Helper Functions
################################################################################

print_header() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BLUE}Adaptive Secure VM Migration Strategy Selector${NC}           ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_section() {
    echo -e "\n${YELLOW}▶ $1${NC}"
    echo "────────────────────────────────────────────────────────────────"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

################################################################################
# System Monitoring Functions
################################################################################

# Auto-detect default network interface
detect_network_interface() {
    local nic
    
    # Try to get interface with default route
    nic=$(ip route | grep default | awk '{print $5}' | head -n1)
    
    if [ -z "$nic" ]; then
        # Fallback: get first UP interface that's not loopback
        nic=$(ip link show | grep -E "state UP" | grep -v "lo:" | head -n1 | awk -F': ' '{print $2}')
    fi
    
    if [ -z "$nic" ]; then
        # Last resort: look for br0 or any bridge
        nic=$(ip link show | grep -E "br[0-9]" | head -n1 | awk -F': ' '{print $2}')
    fi
    
    echo "$nic"
}

# Measure current CPU load (returns percentage 0-100)
measure_cpu_load() {
    local cpu_idle
    cpu_idle=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print int($1)}')
    local cpu_usage=$((100 - cpu_idle))
    echo "$cpu_usage"
}

# Measure current bandwidth usage on migration NIC (returns percentage 0-100)
measure_bandwidth_usage() {
    local nic="$1"
    
    # Check if interface exists
    if [ ! -d "/sys/class/net/$nic" ]; then
        echo "0"
        return 1
    fi
    
    # Get link speed (in Mbps)
    local link_speed
    link_speed=$(ethtool "$nic" 2>/dev/null | grep "Speed:" | awk '{print $2}' | sed 's/Mb\/s//')
    
    # If we can't get link speed, assume 1000 Mbps
    if [ -z "$link_speed" ] || [ "$link_speed" == "Unknown!" ]; then
        link_speed=1000
    fi
    
    # Check if statistics files exist
    if [ ! -f "/sys/class/net/$nic/statistics/rx_bytes" ]; then
        echo "0"
        return 1
    fi
    
    # Sample network traffic for 2 seconds
    local rx_bytes_1 tx_bytes_1 rx_bytes_2 tx_bytes_2
    
    rx_bytes_1=$(cat /sys/class/net/"$nic"/statistics/rx_bytes 2>/dev/null || echo "0")
    tx_bytes_1=$(cat /sys/class/net/"$nic"/statistics/tx_bytes 2>/dev/null || echo "0")
    
    sleep 2
    
    rx_bytes_2=$(cat /sys/class/net/"$nic"/statistics/rx_bytes 2>/dev/null || echo "0")
    tx_bytes_2=$(cat /sys/class/net/"$nic"/statistics/tx_bytes 2>/dev/null || echo "0")
    
    # Calculate bytes transferred in 2 seconds
    local rx_diff=$((rx_bytes_2 - rx_bytes_1))
    local tx_diff=$((tx_bytes_2 - tx_bytes_1))
    
    # Total bytes per second
    local total_bytes=$(( (rx_diff + tx_diff) / 2 ))
    
    # Convert to Mbps
    local mbps=$(awk "BEGIN {printf \"%.2f\", ($total_bytes * 8) / 1000000}")
    
    # Calculate percentage of link capacity
    local usage_percent=$(awk "BEGIN {printf \"%.0f\", ($mbps / $link_speed) * 100}")
    
    # Ensure it's a valid number
    if [ -z "$usage_percent" ] || [ "$usage_percent" == "" ]; then
        usage_percent=0
    fi
    
    echo "$usage_percent"
}

# Categorize value into bucket: low, medium, high
categorize_resource() {
    local value=$1
    
    # Ensure value is a number
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "low"
        return
    fi
    
    if [ "$value" -ge 75 ]; then
        echo "high"
    elif [ "$value" -ge 50 ]; then
        echo "medium"
    else
        echo "low"
    fi
}

# Calculate available percentage (inverse of usage)
calculate_available() {
    local usage=$1
    
    # Ensure usage is a number
    if ! [[ "$usage" =~ ^[0-9]+$ ]]; then
        echo "0"
        return
    fi
    
    echo $((100 - usage))
}

################################################################################
# Migration Strategy Selection (Algorithm 1)
################################################################################

select_migration_strategy() {
    local cpu_load_category="$1"
    local bandwidth_category="$2"
    local security_level="$3"
    local urgency_level="$4"
    
    local resource_available="false"
    
    # Step 1: Evaluate resource availability
    if [ "$bandwidth_category" != "high" ] && [ "$cpu_load_category" != "high" ]; then
        resource_available="true"
    fi
    
    local selected_strategy=""
    
    # Step 2: Select strategy based on security level
    case "$security_level" in
        "high")
            if [ "$resource_available" == "true" ] && [ "$urgency_level" != "high" ]; then
                selected_strategy="IPSEC"
            elif [ "$urgency_level" == "high" ]; then
                selected_strategy="TLS"
            else
                selected_strategy="IPSEC"
            fi
            ;;
            
        "medium")
            if [ "$urgency_level" == "high" ] || [ "$bandwidth_category" == "high" ]; then
                selected_strategy="SSH"
            elif [ "$resource_available" == "true" ]; then
                selected_strategy="TLS"
            else
                selected_strategy="SSH"
            fi
            ;;
            
        "low")
            if [ "$urgency_level" == "high" ] || [ "$cpu_load_category" == "high" ] || [ "$bandwidth_category" == "high" ]; then
                selected_strategy="TLS"
            elif [ "$resource_available" == "true" ]; then
                selected_strategy="TLS"
            else
                selected_strategy="SSH"
            fi
            ;;
            
        *)
            selected_strategy="TLS"
            ;;
    esac
    
    # Step 3: Override if resources are critically constrained
    if [ "$bandwidth_category" == "high" ] && [ "$cpu_load_category" == "high" ]; then
        selected_strategy="DEFAULT"
    fi
    
    # Output ONLY the strategy name
    echo "$selected_strategy"
}

################################################################################
# Migration Execution Functions
################################################################################

execute_migration() {
    local strategy="$1"
    local log_folder="$2"
    
    print_section "Executing Migration Strategy: $strategy"
    
    local migration_script=""
    local extra_params=""
    
    case "$strategy" in
    "IPSEC")
        log_info "Enabling IPsec on BOTH servers..."
        
        # Enable IPsec on SOURCE
        log_info "  Enabling IPsec on SOURCE ($SOURCE_IP)..."
        sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
            "bash $IPSEC_MANAGER enable" > /dev/null 2>&1
        
        # Enable IPsec on DESTINATION
        log_info "  Enabling IPsec on DESTINATION ($DESTINATION_IP)..."
        sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP \
            "bash $IPSEC_MANAGER enable" > /dev/null 2>&1
        
        sleep 5
        
        # Verify IPsec on both servers
        log_info "Verifying IPsec establishment..."
        SOURCE_IPSEC=$(sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
            "systemctl is-active strongswan-starter")
        DEST_IPSEC=$(sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP \
            "systemctl is-active strongswan-starter")
        
        if [[ "$SOURCE_IPSEC" == "active" ]] && [[ "$DEST_IPSEC" == "active" ]]; then
            log_info "  ✓ IPsec active on both servers"
        else
            log_warning "  ⚠ IPsec may not be fully active"
            log_warning "    Source: $SOURCE_IPSEC | Destination: $DEST_IPSEC"
        fi
        
        migration_script="$IPSEC_SCRIPT"
        log_info "Using IPsec-secured migration"
        ;;
            
        "TLS")
            migration_script="$TLS_SCRIPT"
            log_info "Using TLS-secured migration"
            ;;
            
        "SSH")
            migration_script="$SSH_SCRIPT"
            log_info "Using SSH tunnel-secured migration"
            ;;
            
        "DEFAULT")
            log_info "Disabling IPsec for default migration..."
            sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
                "bash $IPSEC_MANAGER disable" > /dev/null 2>&1
            sleep 3
            
            migration_script="$DEFAULT_SCRIPT"
            log_info "Using unencrypted migration (performance priority)"
            ;;
            
        *)
            log_error "Unknown strategy: $strategy"
            exit 1
            ;;
    esac
    
    # Map urgency level to migration type
    local migration_type="precopy"
    case "$URGENCY_LEVEL" in
        "high")
            migration_type="hybrid"
            ;;
        "medium")
            migration_type="precopy"
            ;;
        "low")
            migration_type="precopy"
            ;;
    esac
    
    # Build command with log folder parameter
    local cmd="bash $migration_script \
        --vm=$VM_NAME \
        --size=$VM_SIZE \
        --cores=$CORES \
        --tap=$TAP \
        --type=$migration_type \
        --iterations=$ITERATIONS \
        --log=$log_folder \
        $extra_params"
    
    log_info "Executing migration command..."
    log_info "Migration Type: $migration_type"
    log_info "Log Folder: $log_folder"
    echo ""
    echo -e "${BLUE}Command:${NC} $cmd"
    echo ""
    
    # Execute
    eval "$cmd"
    
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        log_info "Migration completed successfully!"
    else
        log_error "Migration failed with exit code: $exit_code"
    fi
    
    return $exit_code
}

################################################################################
# Usage and Argument Parsing
################################################################################

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Adaptive Secure VM Migration Strategy Selector

OPTIONS:
    --security=LEVEL      Security level: high, medium, low (default: medium)
    --urgency=LEVEL       Urgency level: high, medium, low (default: medium)
    --vm=NAME            VM name (default: idle)
    --size=MB            VM memory size in MB (default: 1024)
    --cores=NUM          Number of vCPUs (default: 1)
    --tap=INTERFACE      TAP interface (default: tap0)
    --iterations=NUM     Number of iterations (default: 10)
    --nic=INTERFACE      Network interface to monitor (default: auto-detect)
    --help               Show this help message

EXAMPLES:
    $0 --security=high --urgency=high --vm=critical --iterations=1
    $0 --security=medium --urgency=medium --vm=app --size=2048
    $0 --security=high --urgency=low --vm=web --iterations=5

EOF
}

parse_arguments() {
    for arg in "$@"; do
        case "$arg" in
            --security=*)
                SECURITY_LEVEL="${arg#*=}"
                ;;
            --urgency=*)
                URGENCY_LEVEL="${arg#*=}"
                ;;
            --vm=*)
                VM_NAME="${arg#*=}"
                ;;
            --size=*)
                VM_SIZE="${arg#*=}"
                ;;
            --cores=*)
                CORES="${arg#*=}"
                ;;
            --tap=*)
                TAP="${arg#*=}"
                ;;
            --iterations=*)
                ITERATIONS="${arg#*=}"
                ;;
            --nic=*)
                MIGRATION_NIC="${arg#*=}"
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $arg"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Validate inputs
    if [[ ! "$SECURITY_LEVEL" =~ ^(high|medium|low)$ ]]; then
        log_error "Invalid security level: $SECURITY_LEVEL"
        exit 1
    fi
    
    if [[ ! "$URGENCY_LEVEL" =~ ^(high|medium|low)$ ]]; then
        log_error "Invalid urgency level: $URGENCY_LEVEL"
        exit 1
    fi
}

################################################################################
# Main Execution
################################################################################

main() {
    print_header
    
    # Parse command line arguments
    parse_arguments "$@"
    
    # Auto-detect network interface if not specified
    if [ -z "$MIGRATION_NIC" ]; then
        MIGRATION_NIC=$(detect_network_interface)
        if [ -z "$MIGRATION_NIC" ]; then
            log_error "Could not auto-detect network interface. Please specify with --nic=<interface>"
            exit 1
        fi
    fi
    
    # Display configuration
    print_section "Configuration"
    log_info "VM Name: $VM_NAME"
    log_info "VM Size: ${VM_SIZE}MB"
    log_info "vCPUs: $CORES"
    log_info "Security Level: $SECURITY_LEVEL"
    log_info "Urgency Level: $URGENCY_LEVEL"
    log_info "Iterations: $ITERATIONS"
    log_info "Monitoring NIC: $MIGRATION_NIC"
    
    # Measure system resources
    print_section "System Resource Monitoring"
    
    log_info "Measuring CPU load..."
    local cpu_usage
    cpu_usage=$(measure_cpu_load)
    local cpu_available=$(calculate_available "$cpu_usage")
    log_info "CPU Usage: ${cpu_usage}% | Available: ${cpu_available}%"
    
    log_info "Measuring bandwidth usage on $MIGRATION_NIC..."
    local bandwidth_usage
    bandwidth_usage=$(measure_bandwidth_usage "$MIGRATION_NIC")
    
    # Handle case where bandwidth measurement failed
    if [ "$bandwidth_usage" == "0" ] || [ -z "$bandwidth_usage" ]; then
        log_warning "Could not measure bandwidth on $MIGRATION_NIC, assuming 0% usage"
        bandwidth_usage=0
    fi
    
    local bandwidth_available=$(calculate_available "$bandwidth_usage")
    log_info "Bandwidth Usage: ${bandwidth_usage}% | Available: ${bandwidth_available}%"
    
    # Categorize resources
    print_section "Resource Categorization"
    local cpu_category
    cpu_category=$(categorize_resource "$cpu_usage")
    log_info "CPU Load Category: $cpu_category"
    
    local bandwidth_category
    bandwidth_category=$(categorize_resource "$bandwidth_usage")
    log_info "Bandwidth Category: $bandwidth_category"
    
    # Select migration strategy
    print_section "Strategy Selection"
    log_info "Applying Algorithm 1..."
    log_info "  Input: CPU=$cpu_category, Bandwidth=$bandwidth_category"
    log_info "  Input: Security=$SECURITY_LEVEL, Urgency=$URGENCY_LEVEL"
    
    local selected_strategy
    selected_strategy=$(select_migration_strategy \
        "$cpu_category" \
        "$bandwidth_category" \
        "$SECURITY_LEVEL" \
        "$URGENCY_LEVEL")
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  Selected Strategy: ${CYAN}$selected_strategy${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Create log folder with proper naming including all parameters and timestamp
    local timestamp=$(date "+%Y%m%d_%H%M%S")
    local LOG_FOLDER="adaptive_${selected_strategy}_${VM_NAME}_${VM_SIZE}MB_${CORES}cores_sec-${SECURITY_LEVEL}_urg-${URGENCY_LEVEL}_${timestamp}"
    local LOG_PATH="${LOGS_BASE}/${LOG_FOLDER}"
    
    # Create logs directory
    mkdir -p "$LOG_PATH"
    log_info "Log directory created: $LOG_PATH"
    
    # Save configuration to log folder
    cat > "${LOG_PATH}/config.txt" << EOF
Migration Configuration
=======================
Timestamp: $(date)
Strategy: $selected_strategy
VM Name: $VM_NAME
VM Size: ${VM_SIZE}MB
vCPUs: $CORES
TAP Interface: $TAP
Iterations: $ITERATIONS

Resource Status:
----------------
CPU Usage: ${cpu_usage}% (Category: $cpu_category)
Bandwidth Usage: ${bandwidth_usage}% (Category: $bandwidth_category)
Network Interface: $MIGRATION_NIC

Parameters:
-----------
Security Level: $SECURITY_LEVEL
Urgency Level: $URGENCY_LEVEL

Source: $SOURCE_IP
Destination: $DESTINATION_IP
VM IP: $VM_IP
EOF
    
    # Execute migration
    execute_migration "$selected_strategy" "$LOG_FOLDER"
    
  # Cleanup (disable IPsec if it was enabled)
    if [ "$selected_strategy" == "IPSEC" ]; then
        log_info "Disabling IPsec on BOTH servers after migration..."
        
        log_info "  Disabling IPsec on SOURCE..."
        sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$SOURCE_IP \
            "bash $IPSEC_MANAGER disable" > /dev/null 2>&1
        
        log_info "  Disabling IPsec on DESTINATION..."
        sshpass -p "primedirective" ssh -o StrictHostKeyChecking=no root@$DESTINATION_IP \
            "bash $IPSEC_MANAGER disable" > /dev/null 2>&1
        
        log_info "  ✓ IPsec disabled on both servers"
    fi
    
    print_section "Migration Complete"
    log_info "Timestamp: $(date)"
    log_info "All logs saved to: $LOG_PATH"
}

# Run main function
main "$@"
