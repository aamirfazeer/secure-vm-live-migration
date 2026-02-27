#!/bin/bash

# ─────────────────────────────────────────────────────────────
# arg_parser.sh  —  Generic argument parser
#
# Usage: define ARG_TUPLES and PARSE_ARGS, then source this file
#
#   ARG_TUPLES=(
#     "--flag:VAR_NAME:default_value"
#     ...
#   )
#   PARSE_ARGS=("$@")          # capture args before sourcing
#   source arg_parser.sh
#
# When sourced from a helper script that receives explicit args,
# set PARSE_ARGS to the helper's own "$@" before sourcing.
# ─────────────────────────────────────────────────────────────

# Initialize variables with defaults
for tuple in "${ARG_TUPLES[@]}"; do
    IFS=":" read -r FLAG VAR DEFAULT <<< "$tuple"
    declare "$VAR=$DEFAULT"
done

# Parse from PARSE_ARGS (never from $@ directly — avoids parent shell leakage)
for ARG in "${PARSE_ARGS[@]}"; do
    KEY="${ARG%%=*}"
    VALUE="${ARG#*=}"
    MATCHED=false

    for tuple in "${ARG_TUPLES[@]}"; do
        IFS=":" read -r FLAG VAR DEFAULT <<< "$tuple"
        if [[ "$KEY" == "$FLAG" ]]; then
            declare "$VAR=$VALUE"
            MATCHED=true
            break
        fi
    done

    if ! $MATCHED; then
        echo "❌ Unknown argument: $ARG"
        exit 1
    fi
done

# Reset for next use
PARSE_ARGS=()
