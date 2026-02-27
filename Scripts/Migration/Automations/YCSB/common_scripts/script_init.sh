#!/bin/bash

# ─────────────────────────────────────────────────────────────
# script_init.sh  —  Initialize log folder and record config
# Usage: bash script_init.sh --log_folder=<folder> [--optimization=<script>]
# ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ARG_TUPLES=(
    "--log_folder:LOG_FOLDER:"
    "--optimization:OPTIMIZATION_SCRIPT:"
)
PARSE_ARGS=("$@")
source "$SCRIPT_DIR/arg_parser.sh"

if [[ -z "$LOG_FOLDER" ]]; then
    echo "❌ Missing required argument: --log_folder"
    exit 1
fi

mkdir -p "logs/${LOG_FOLDER}"
echo ">>> Created log folder: logs/${LOG_FOLDER}"

if [[ -n "$OPTIMIZATION_SCRIPT" ]]; then
    echo "$OPTIMIZATION_SCRIPT" > "logs/${LOG_FOLDER}/optimization.txt"
    echo ">>> Optimization script recorded: $OPTIMIZATION_SCRIPT"
fi
