#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
function_source=$(awk '/^_is_valid_port\(\)/,/^}/' "${ROOT_DIR}/singbox.sh")

if [ -z "$function_source" ]; then
    echo "FAIL: _is_valid_port is missing"
    exit 1
fi

eval "$function_source"

for port in 1 443 65535; do
    if ! _is_valid_port "$port"; then
        echo "FAIL: expected valid port: $port"
        exit 1
    fi
done

for port in '' 0 65536 123123 abc -1 1.5; do
    if _is_valid_port "$port"; then
        echo "FAIL: expected invalid port: $port"
        exit 1
    fi
done

echo "All port validation tests passed"
