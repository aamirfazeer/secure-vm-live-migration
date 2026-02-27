#!/bin/bash
set -euo pipefail

################################################################################
# Test ALL scenarios for Adaptive Migration Selector
# - Covers all security/urgency combinations (3x3 = 9)
# - Adds "resource forcing" tests to ensure all strategies appear:
#   ipsec, ssh, tls, default
# Requirements: size=8192 (8GB), cores=1, iterations=10, vm=aamir
################################################################################

SELECTOR_SCRIPT="./adaptive_migration_selector.sh"

VM="aamir"
SIZE_MB=8192
CORES=1
ITERATIONS=5

LOG_DIR="./logs"
mkdir -p "$LOG_DIR"

timestamp() { date +"%Y%m%d_%H%M%S"; }

run_case () {
  local label="$1"
  shift
  local log_file="$LOG_DIR/${label}_$(timestamp).log"

  echo "=================================================================="
  echo "CASE: $label"
  echo "CMD : bash $SELECTOR_SCRIPT $*"
  echo "LOG : $log_file"
  echo "------------------------------------------------------------------"

  # Run and tee output to log
  set +e
  bash "$SELECTOR_SCRIPT" "$@" 2>&1 | tee "$log_file"
  local rc=${PIPESTATUS[0]}
  set -e

  echo "------------------------------------------------------------------"
  echo "EXIT: $rc"
  echo "=================================================================="
  echo ""
}

echo "════════════════════════════════════════════════════════════════"
echo "  Adaptive Migration Selector - FULL Scenario Matrix + Coverage"
echo "  VM=$VM | SIZE=${SIZE_MB}MB (8GB) | CORES=$CORES | ITER=$ITERATIONS"
echo "════════════════════════════════════════════════════════════════"
echo ""

# ------------------------------------------------------------------
# 1) Full 3x3 matrix tests (all security/urgency combos)
# ------------------------------------------------------------------
SEC_LEVELS=(low medium high)
URG_LEVELS=(low medium high)

for sec in "${SEC_LEVELS[@]}"; do
  for urg in "${URG_LEVELS[@]}"; do
    label="matrix_sec-${sec}_urg-${urg}"
    run_case "$label" \
      --security="$sec" \
      --urgency="$urg" \
      --vm="$VM" \
      --size="$SIZE_MB" \
      --cores="$CORES" \
      --iterations="$ITERATIONS"
  done
done

# ------------------------------------------------------------------
# 2) Coverage forcing tests (to make sure ipsec/ssh/tls/default appear)
#    These assume your selector considers system constraints.
#    If your selector ignores these knobs, these still run harmlessly.
# ------------------------------------------------------------------

# Force DEFAULT: pretend resources are very constrained
run_case "force_default_constrained" \
  --security=low \
  --urgency=low \
  --vm="$VM" \
  --size="$SIZE_MB" \
  --cores="$CORES" \
  --iterations="$ITERATIONS" 

# Force TLS: high urgency + decent resources
run_case "force_tls_fast_secure" \
  --security=high \
  --urgency=high \
  --vm="$VM" \
  --size="$SIZE_MB" \
  --cores="$CORES" \
  --iterations="$ITERATIONS" 

# Force IPsec: high security + low urgency + decent resources
run_case "force_ipsec_strong_security" \
  --security=high \
  --urgency=low \
  --vm="$VM" \
  --size="$SIZE_MB" \
  --cores="$CORES" \
  --iterations="$ITERATIONS"

# Force SSH: medium security + medium urgency (or whatever your mapping is)
run_case "force_ssh_middle_ground" \
  --security=medium \
  --urgency=medium \
  --vm="$VM" \
  --size="$SIZE_MB" \
  --cores="$CORES" \
  --iterations="$ITERATIONS" 

# ------------------------------------------------------------------
# 3) Summary: count which strategies appeared in logs
# ------------------------------------------------------------------
echo "════════════════════════════════════════════════════════════════"
echo "  Summary (strategy occurrences in logs)"
echo "════════════════════════════════════════════════════════════════"

# Adjust these grep patterns to match your selector's exact output lines.
grep -Rhi --line-number -E "STRATEGY|Selected strategy|Using strategy|Chosen strategy|ipsec|ssh|tls|default" "$LOG_DIR" \
  | tee "$LOG_DIR/summary_$(timestamp).txt" >/dev/null

for s in ipsec ssh tls default; do
  count=$(grep -Rhi -E "\b${s}\b" "$LOG_DIR" | wc -l | tr -d ' ')
  echo "$s : $count"
done

echo ""
echo "Done. Logs are in: $LOG_DIR"
echo "Tip: open the latest summary file in logs/summary_*.txt"
