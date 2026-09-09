#!/usr/bin/env bash
# Emit CRIU TCP socket flag for dump/restore.
#
# GHA + QEMU user NAT (10.0.2.15) requires --tcp-close (Mode 2). Porter F09
# --tcp-established needs address-preserving TAP; see porter/CONTRACTS.md §19.
#
# CRIU_TCP_MODE: close (default) | established
set -euo pipefail

mode="${CRIU_TCP_MODE:-close}"
case "${mode}" in
    established|tcp-established|--tcp-established)
        echo "--tcp-established"
        ;;
    close|tcp-close|--tcp-close)
        echo "--tcp-close"
        ;;
    *)
        echo "Unknown CRIU_TCP_MODE=${mode}; using --tcp-close" >&2
        echo "--tcp-close"
        ;;
esac
