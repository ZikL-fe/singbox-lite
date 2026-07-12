#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

record_source=$(awk '/^_record_created_tag\(\)/,/^}/' "${ROOT_DIR}/singbox.sh")
normalize_source=$(awk '/^_normalize_public_ip\(\)/,/^}/' "${ROOT_DIR}/singbox.sh")
prompt_source=$(awk '/^_traffic_prompt_for_created_tags\(\)/,/^}/' "${ROOT_DIR}/singbox.sh")
manager_source=$(awk '/^_traffic_manager_is_compatible\(\)/,/^}/' "${ROOT_DIR}/singbox.sh")
diff_source=$(awk '/^_record_config_created_tags\(\)/,/^}/' "${ROOT_DIR}/singbox.sh")
update_source=$(awk '/^_validate_script_update\(\)/,/^}/' "${ROOT_DIR}/singbox.sh")

[ -n "$record_source" ] || { echo "FAIL: _record_created_tag is missing"; exit 1; }
[ -n "$normalize_source" ] || { echo "FAIL: _normalize_public_ip is missing"; exit 1; }
[ -n "$prompt_source" ] || { echo "FAIL: _traffic_prompt_for_created_tags is missing"; exit 1; }
[ -n "$manager_source" ] || { echo "FAIL: _traffic_manager_is_compatible is missing"; exit 1; }
[ -n "$diff_source" ] || { echo "FAIL: _record_config_created_tags is missing"; exit 1; }
[ -n "$update_source" ] || { echo "FAIL: _validate_script_update is missing"; exit 1; }
eval "$record_source"
eval "$normalize_source"
eval "$prompt_source"
eval "$manager_source"
eval "$diff_source"
eval "$update_source"

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

manager_file=$(mktemp)
trap 'rm -f "$manager_file"' EXIT
printf '_tm_ensure_singbox_api() { :; }\nENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true\n' > "$manager_file"
_traffic_manager_is_compatible "$manager_file" || {
    echo "FAIL: expected compatible traffic manager"
    exit 1
}
printf '_tm_ensure_singbox_api() { :; }\n' > "$manager_file"
if _traffic_manager_is_compatible "$manager_file"; then
    echo "FAIL: expected stale traffic manager to be rejected"
    exit 1
fi

CREATED_NODE_TAGS=""
_record_config_created_tags $'old\nexisting' $'old\nexisting\nvless-in-12312'
[ "$CREATED_NODE_TAGS" = "vless-in-12312" ] || {
    printf 'FAIL: unexpected config-created tags: <%s>\n' "$CREATED_NODE_TAGS"
    exit 1
}

valid_update=$(mktemp)
invalid_update=$(mktemp)
trap 'rm -f "$manager_file" "$valid_update" "$invalid_update"' EXIT
printf '#!/usr/bin/env bash\nEXPECTED_UPDATE_MARKER=1\n' > "$valid_update"
printf '#!/usr/bin/env bash\nif then\n' > "$invalid_update"
_validate_script_update "$valid_update" EXPECTED_UPDATE_MARKER || {
    echo "FAIL: expected valid script update"
    exit 1
}
if _validate_script_update "$invalid_update"; then
    echo "FAIL: expected invalid script update to be rejected"
    exit 1
fi

echo "All sing-box helper tests passed"
