#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

record_source=$(awk '/^_record_created_tag\(\)/,/^}/' "${ROOT_DIR}/singbox.sh")
normalize_source=$(awk '/^_normalize_public_ip\(\)/,/^}/' "${ROOT_DIR}/singbox.sh")
prompt_source=$(awk '/^_traffic_prompt_for_created_tags\(\)/,/^}/' "${ROOT_DIR}/singbox.sh")

[ -n "$record_source" ] || { echo "FAIL: _record_created_tag is missing"; exit 1; }
[ -n "$normalize_source" ] || { echo "FAIL: _normalize_public_ip is missing"; exit 1; }
[ -n "$prompt_source" ] || { echo "FAIL: _traffic_prompt_for_created_tags is missing"; exit 1; }
eval "$record_source"
eval "$normalize_source"
eval "$prompt_source"

CREATED_NODE_TAGS=""
_record_created_tag "node-a"
_record_created_tag "node-a"
_record_created_tag "node-b"
[ "$CREATED_NODE_TAGS" = $'node-a\nnode-b' ] || {
    printf 'FAIL: unexpected created tags: <%s>\n' "$CREATED_NODE_TAGS"
    exit 1
}

PROMPTED_TAGS=""
_traffic_prompt_for_tag() {
    PROMPTED_TAGS="${PROMPTED_TAGS:+${PROMPTED_TAGS}$'\n'}$2"
}
CREATED_NODE_TAGS=$'node-a\nnode-a-hop-20000\nnode-b'
_traffic_prompt_for_created_tags singbox
[ "$PROMPTED_TAGS" = $'node-a\nnode-b' ] || {
    printf 'FAIL: unexpected prompted tags: <%s>\n' "$PROMPTED_TAGS"
    exit 1
}

normalized=$(_normalize_public_ip $'203.0.113.10\r\n203.0.113.11\n')
[ "$normalized" = "203.0.113.10" ] || {
    echo "FAIL: expected first normalized IP, got: <$normalized>"
    exit 1
}

echo "All sing-box helper tests passed"
