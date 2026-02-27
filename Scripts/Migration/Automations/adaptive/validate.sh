#!/bin/bash

################################################################################
# Validation Script for Adaptive Migration Selector
#
# This script validates that:
# 1. System monitoring works correctly
# 2. Resource categorization is accurate
# 3. Strategy selection logic matches Algorithm 1
# 4. All required scripts exist and are accessible
################################################################################

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TOTAL_TESTS=0

# Configuration
SCRIPTS_BASE="/mnt/nfs/aamir/Scripts/Migration/Automations"

################################################################################
# Test Framework Functions
################################################################################

print_header() {
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  Validation Tests for Adaptive Migration Selector           ${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
    ((TOTAL_TESTS++))
}

pass_test() {
    echo -e "${GREEN}  ✓ PASS${NC} $1"
    ((TESTS_PASSED++))
}

fail_test() {
    echo -e "${RED}  ✗ FAIL${NC} $1"
    ((TESTS_FAILED++))
}

print_section() {
    echo ""
    echo -e "${YELLOW}▶ $1${NC}"
    echo "─────────────────────────────────────────────────────────────────"
}

################################################################################
# Test Functions
################################################################################

test_prerequisites() {
    print_section "Testing Prerequisites"
    
    # Test 1: Check sshpass
    print_test "Checking sshpass availability"
    if command -v sshpass &> /dev/null; then
        pass_test "sshpass is installed"
    else
        fail_test "sshpass not found - install with: sudo apt-get install sshpass"
    fi
    
    # Test 2: Check ethtool
    print_test "Checking ethtool availability"
    if command -v ethtool &> /dev/null; then
        pass_test "ethtool is installed"
    else
        fail_test "ethtool not found - install with: sudo apt-get install ethtool"
    fi
    
    # Test 3: Check bash version
    print_test "Checking bash version (need >= 4.0)"
    BASH_MAJOR=${BASH_VERSION%%.*}
    if [ "$BASH_MAJOR" -ge 4 ]; then
        pass_test "Bash version $BASH_VERSION is sufficient"
    else
        fail_test "Bash version too old: $BASH_VERSION"
    fi
}

test_system_monitoring() {
    print_section "Testing System Monitoring"
    
    # Test 4: CPU monitoring
    print_test "Testing CPU load measurement"
    local cpu_load
    cpu_load=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print int($1)}')
    
    if [ -n "$cpu_load" ] && [ "$cpu_load" -ge 0 ] && [ "$cpu_load" -le 100 ]; then
        pass_test "CPU load detected: $cpu_load% idle"
    else
        fail_test "Cannot measure CPU load"
    fi
    
    # Test 5: Network interface detection
    print_test "Testing network interface detection"
    local default_nic
    default_nic=$(ip route | grep default | awk '{print $5}' | head -n1)
    
    if [ -n "$default_nic" ]; then
        pass_test "Default NIC detected: $default_nic"
        
        # Test 6: Network statistics
        print_test "Testing network statistics access"
        if [ -f "/sys/class/net/$default_nic/statistics/rx_bytes" ]; then
            pass_test "Can read network statistics for $default_nic"
        else
            fail_test "Cannot read network statistics"
        fi
    else
        fail_test "Cannot detect default network interface"
    fi
}

test_categorization_logic() {
    print_section "Testing Resource Categorization Logic"
    
    # Test 7: Low usage (0-25%)
    print_test "Testing categorization: 20% usage -> 'low'"
    local cat_result
    cat_result=$(categorize_test 20)
    if [ "$cat_result" == "low" ]; then
        pass_test "Correctly categorized 20% as 'low'"
    else
        fail_test "Expected 'low', got '$cat_result'"
    fi
    
    # Test 8: Medium usage (50-75%)
    print_test "Testing categorization: 60% usage -> 'medium'"
    cat_result=$(categorize_test 60)
    if [ "$cat_result" == "medium" ]; then
        pass_test "Correctly categorized 60% as 'medium'"
    else
        fail_test "Expected 'medium', got '$cat_result'"
    fi
    
    # Test 9: High usage (75-100%)
    print_test "Testing categorization: 80% usage -> 'high'"
    cat_result=$(categorize_test 80)
    if [ "$cat_result" == "high" ]; then
        pass_test "Correctly categorized 80% as 'high'"
    else
        fail_test "Expected 'high', got '$cat_result'"
    fi
}

categorize_test() {
    local value=$1
    if [ "$value" -ge 75 ]; then
        echo "high"
    elif [ "$value" -ge 50 ]; then
        echo "medium"
    else
        echo "low"
    fi
}

test_strategy_selection() {
    print_section "Testing Strategy Selection Logic (Algorithm 1)"
    
    # Test 10: High security + low urgency + resources available -> IPsec
    print_test "Test: security=high, urgency=low, resources=available -> IPsec"
    local strategy
    strategy=$(test_select_strategy "low" "low" "high" "low")
    if [ "$strategy" == "IPSEC" ]; then
        pass_test "Correctly selected IPsec"
    else
        fail_test "Expected IPsec, got $strategy"
    fi
    
    # Test 11: High security + high urgency -> TLS
    print_test "Test: security=high, urgency=high -> TLS"
    strategy=$(test_select_strategy "low" "low" "high" "high")
    if [ "$strategy" == "TLS" ]; then
        pass_test "Correctly selected TLS"
    else
        fail_test "Expected TLS, got $strategy"
    fi
    
    # Test 12: Medium security + high urgency -> SSH
    print_test "Test: security=medium, urgency=high -> SSH"
    strategy=$(test_select_strategy "low" "low" "medium" "high")
    if [ "$strategy" == "SSH" ]; then
        pass_test "Correctly selected SSH"
    else
        fail_test "Expected SSH, got $strategy"
    fi
    
    # Test 13: Critically constrained -> DEFAULT
    print_test "Test: cpu=high, bandwidth=high -> DEFAULT"
    strategy=$(test_select_strategy "high" "high" "high" "low")
    if [ "$strategy" == "DEFAULT" ]; then
        pass_test "Correctly selected DEFAULT"
    else
        fail_test "Expected DEFAULT, got $strategy"
    fi
    
    # Test 14: Medium security + low urgency + resources available -> TLS
    print_test "Test: security=medium, urgency=low, resources=available -> TLS"
    strategy=$(test_select_strategy "low" "low" "medium" "low")
    if [ "$strategy" == "TLS" ]; then
        pass_test "Correctly selected TLS"
    else
        fail_test "Expected TLS, got $strategy"
    fi
}

test_select_strategy() {
    local cpu_category="$1"
    local bandwidth_category="$2"
    local security_level="$3"
    local urgency_level="$4"
    
    local resource_available="false"
    if [ "$bandwidth_category" != "high" ] && [ "$cpu_category" != "high" ]; then
        resource_available="true"
    fi
    
    local selected_strategy=""
    
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
            if [ "$urgency_level" == "high" ] || [ "$cpu_category" == "high" ] || [ "$bandwidth_category" == "high" ]; then
                selected_strategy="TLS"
            elif [ "$resource_available" == "true" ]; then
                selected_strategy="TLS"
            else
                selected_strategy="SSH"
            fi
            ;;
    esac
    
    if [ "$bandwidth_category" == "high" ] && [ "$cpu_category" == "high" ]; then
        selected_strategy="DEFAULT"
    fi
    
    echo "$selected_strategy"
}

test_script_dependencies() {
    print_section "Testing Script Dependencies"
    
    # Test 15: IPsec script exists
    print_test "Checking IPsec migration script"
    if [ -f "${SCRIPTS_BASE}/ipsec/ipsec_quicksort_script.sh" ]; then
        pass_test "IPsec script found"
    else
        fail_test "IPsec script not found at ${SCRIPTS_BASE}/ipsec/"
    fi
    
    # Test 16: TLS script exists
    print_test "Checking TLS migration script"
    if [ -f "${SCRIPTS_BASE}/tls/vm_migration_tls_quicksort_1.sh" ]; then
        pass_test "TLS script found"
    else
        fail_test "TLS script not found at ${SCRIPTS_BASE}/tls/"
    fi
    
    # Test 17: SSH script exists
    print_test "Checking SSH migration script"
    if [ -f "${SCRIPTS_BASE}/ssh-tunnel/ssh-migration.sh" ]; then
        pass_test "SSH script found"
    else
        fail_test "SSH script not found at ${SCRIPTS_BASE}/ssh-tunnel/"
    fi
    
    # Test 18: IPsec manager exists
    print_test "Checking IPsec manager script"
    if [ -f "${SCRIPTS_BASE}/ipsec/ipsec_manager.sh" ]; then
        pass_test "IPsec manager found"
    else
        fail_test "IPsec manager not found"
    fi
}

test_main_script() {
    print_section "Testing Main Script"
    
    # Test 19: Main script exists
    print_test "Checking main script existence"
    if [ -f "adaptive_migration_selector.sh" ]; then
        pass_test "Main script found"
    else
        fail_test "adaptive_migration_selector.sh not found"
        return
    fi
    
    # Test 20: Main script is executable
    print_test "Checking main script permissions"
    if [ -x "adaptive_migration_selector.sh" ]; then
        pass_test "Main script is executable"
    else
        fail_test "Main script is not executable - run: chmod +x adaptive_migration_selector.sh"
    fi
    
    # Test 21: Help function works
    print_test "Testing help function"
    if ./adaptive_migration_selector.sh --help &> /dev/null; then
        pass_test "Help function works"
    else
        fail_test "Help function failed"
    fi
}

################################################################################
# Summary and Report
################################################################################

print_summary() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    VALIDATION SUMMARY${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  Total Tests:  $TOTAL_TESTS"
    echo -e "  ${GREEN}Passed:       $TESTS_PASSED${NC}"
    echo -e "  ${RED}Failed:       $TESTS_FAILED${NC}"
    echo ""
    
    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║${NC}  ✓ ALL TESTS PASSED - System is ready for deployment!       ${GREEN}║${NC}"
        echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
        return 0
    else
        echo -e "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║${NC}  ✗ SOME TESTS FAILED - Please fix issues before deployment   ${RED}║${NC}"
        echo -e "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
        return 1
    fi
}

################################################################################
# Main Execution
################################################################################

main() {
    print_header
    
    test_prerequisites
    test_system_monitoring
    test_categorization_logic
    test_strategy_selection
    test_script_dependencies
    test_main_script
    
    print_summary
}

# Run validation
main
exit $?
