#!/bin/bash

################################################################################
# Deployment Script for Adaptive Migration Selector
#
# This script deploys the adaptive migration selector to your infrastructure
################################################################################

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SOURCE_HOST="root@10.22.196.158"
DEPLOY_PATH="/mnt/nfs/aamir/Scripts/Migration/Automations"
PASSWORD="primedirective"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC}  Deploying Adaptive Secure VM Migration Selector          ${BLUE}║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Function to print step
print_step() {
    echo -e "${YELLOW}▶${NC} $1"
}

# Function to print success
print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

# Function to print error
print_error() {
    echo -e "${RED}✗${NC} $1"
}

# Step 1: Check prerequisites
print_step "Checking prerequisites..."

if ! command -v sshpass &> /dev/null; then
    print_error "sshpass not found. Please install: sudo apt-get install sshpass"
    exit 1
fi

print_success "Prerequisites OK"

# Step 2: Test connection
print_step "Testing SSH connection to $SOURCE_HOST..."

if sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$SOURCE_HOST" "echo 'Connection OK'" &> /dev/null; then
    print_success "SSH connection successful"
else
    print_error "Cannot connect to $SOURCE_HOST"
    exit 1
fi

# Step 3: Create deployment directory
print_step "Creating deployment directory..."

sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$SOURCE_HOST" \
    "mkdir -p ${DEPLOY_PATH}/adaptive"

print_success "Directory created: ${DEPLOY_PATH}/adaptive"

# Step 4: Copy main script
print_step "Copying adaptive_migration_selector.sh..."

if [ ! -f "adaptive_migration_selector.sh" ]; then
    print_error "adaptive_migration_selector.sh not found in current directory"
    exit 1
fi

sshpass -p "$PASSWORD" scp -o StrictHostKeyChecking=no \
    adaptive_migration_selector.sh \
    "${SOURCE_HOST}:${DEPLOY_PATH}/adaptive/"

sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$SOURCE_HOST" \
    "chmod +x ${DEPLOY_PATH}/adaptive/adaptive_migration_selector.sh"

print_success "Main script deployed"

# Step 5: Copy test scenarios
print_step "Copying test_scenarios.sh..."

if [ -f "test_scenarios.sh" ]; then
    sshpass -p "$PASSWORD" scp -o StrictHostKeyChecking=no \
        test_scenarios.sh \
        "${SOURCE_HOST}:${DEPLOY_PATH}/adaptive/"
    
    sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$SOURCE_HOST" \
        "chmod +x ${DEPLOY_PATH}/adaptive/test_scenarios.sh"
    
    print_success "Test scenarios deployed"
else
    print_error "test_scenarios.sh not found (optional)"
fi

# Step 6: Copy documentation
print_step "Copying documentation..."

if [ -f "IMPLEMENTATION_GUIDE.md" ]; then
    sshpass -p "$PASSWORD" scp -o StrictHostKeyChecking=no \
        IMPLEMENTATION_GUIDE.md \
        "${SOURCE_HOST}:${DEPLOY_PATH}/adaptive/"
    print_success "Implementation guide deployed"
fi

if [ -f "QUICK_REFERENCE.txt" ]; then
    sshpass -p "$PASSWORD" scp -o StrictHostKeyChecking=no \
        QUICK_REFERENCE.txt \
        "${SOURCE_HOST}:${DEPLOY_PATH}/adaptive/"
    print_success "Quick reference deployed"
fi

# Step 7: Verify deployment
print_step "Verifying deployment..."

DEPLOYED_FILES=$(sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$SOURCE_HOST" \
    "ls -la ${DEPLOY_PATH}/adaptive/" | wc -l)

if [ "$DEPLOYED_FILES" -gt 3 ]; then
    print_success "Deployment verified"
else
    print_error "Deployment verification failed"
    exit 1
fi

# Step 8: Create convenience symlink
print_step "Creating convenience symlink..."

sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "$SOURCE_HOST" \
    "ln -sf ${DEPLOY_PATH}/adaptive/adaptive_migration_selector.sh \
     /usr/local/bin/adaptive-migrate 2>/dev/null || true"

print_success "Symlink created: /usr/local/bin/adaptive-migrate"

# Step 9: Final instructions
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║${NC}  Deployment Successful!                                     ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Deployed files:${NC}"
echo "  • ${DEPLOY_PATH}/adaptive/adaptive_migration_selector.sh"
echo "  • ${DEPLOY_PATH}/adaptive/test_scenarios.sh"
echo "  • ${DEPLOY_PATH}/adaptive/IMPLEMENTATION_GUIDE.md"
echo "  • ${DEPLOY_PATH}/adaptive/QUICK_REFERENCE.txt"
echo ""
echo -e "${YELLOW}Quick start:${NC}"
echo ""
echo "  1. SSH to source host:"
echo "     ssh root@10.22.196.158"
echo ""
echo "  2. Run with symlink:"
echo "     adaptive-migrate --security=high --urgency=low --vm=test_vm"
echo ""
echo "  3. Or run directly:"
echo "     cd ${DEPLOY_PATH}/adaptive"
echo "     ./adaptive_migration_selector.sh --security=medium --urgency=medium"
echo ""
echo "  4. View documentation:"
echo "     cat ${DEPLOY_PATH}/adaptive/QUICK_REFERENCE.txt"
echo "     less ${DEPLOY_PATH}/adaptive/IMPLEMENTATION_GUIDE.md"
echo ""
echo "  5. Run tests:"
echo "     cd ${DEPLOY_PATH}/adaptive"
echo "     ./test_scenarios.sh"
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
