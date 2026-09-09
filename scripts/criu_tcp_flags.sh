#!/usr/bin/env bash
# Emit CRIU TCP socket flag for dump/restore.
# CRIU_TCP_MODE: established (default) | close
set -euo pipefail

mode="${CRIU_TCP_MODE:-established}"
case "${mode}" in
    established|tcp-established|--tcp-established)
        echo "--tcp-established"
        ;;
    close|tcp-close|--tcp-close)
        echo "--tcp-close"
        ;;
    *)
        echo "Unknown CRIU_TCP_MODE=${mode}; using --tcp-established" >&2
        echo "--tcp-established"
        ;;
esac
