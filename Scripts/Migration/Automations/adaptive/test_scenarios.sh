#!/bin/bash

################################################################################
# Test Scenarios for Adaptive Migration Selector
#
# This script runs various test scenarios to demonstrate the adaptive
# strategy selection based on different conditions
################################################################################

SELECTOR_SCRIPT="./adaptive_migration_selector.sh"

echo "════════════════════════════════════════════════════════════════"
echo "  Adaptive Migration Selector - Test Scenarios"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Test 1: Emergency evacuation (imminent hardware failure)
echo "Test 1: Emergency Evacuation Scenario"
echo "----------------------------------------------------------------------"
echo "Context: Imminent hardware failure detected"
echo "Expected: High urgency should favor TLS for speed with security"
echo ""
bash "$SELECTOR_SCRIPT" \
    --security=high \
    --urgency=high \
    --vm=aamir \
    --iterations=1

echo ""
echo "Press Enter to continue to next test..."
read -r

# Test 2: Routine maintenance
echo ""
echo "Test 2: Routine Maintenance Scenario"
echo "----------------------------------------------------------------------"
echo "Context: Planned server maintenance, minimize disruption"
echo "Expected: Low urgency with high security should use IPsec"
echo ""
bash "$SELECTOR_SCRIPT" \
    --security=high \
    --urgency=low \
    --vm=aamir \
    --iterations=1

echo ""
echo "Press Enter to continue to next test..."
read -r

# Test 3: Balanced scenario
echo ""
echo "Test 3: Balanced Migration Scenario"
echo "----------------------------------------------------------------------"
echo "Context: Load balancing with medium security needs"
echo "Expected: Should adapt based on current system resources"
echo ""
bash "$SELECTOR_SCRIPT" \
    --security=medium \
    --urgency=medium \
    --vm=aamir \
    --size=2048 \
    --iterations=1

echo ""
echo "Press Enter to continue to next test..."
read -r

# Test 4: Performance-critical scenario
echo ""
echo "Test 4: Performance-Critical Scenario"
echo "----------------------------------------------------------------------"
echo "Context: Low security requirement, performance matters most"
echo "Expected: TLS or even DEFAULT if resources are constrained"
echo ""
bash "$SELECTOR_SCRIPT" \
    --security=low \
    --urgency=low \
    --vm=aamir \
    --size=4096 \
    --iterations=1

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  All Test Scenarios Complete"
echo "════════════════════════════════════════════════════════════════"
