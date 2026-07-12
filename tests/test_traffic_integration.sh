#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export PATH="${ROOT_DIR}/.test-bin:${PATH}"
export TRAFFIC_MANAGER_LIB_ONLY=1
source "${ROOT_DIR}/traffic_manager.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export TM_DIR="$tmp/singbox"
export TM_STATE_FILE="$TM_DIR/traffic_limits.json"
export TM_SINGBOX_CONFIG="$TM_DIR/config.json"
export TM_XRAY_CONFIG="$tmp/xray/config.json"
export TM_CRON_FILE="$tmp/traffic.cron"
export TM_LOCK_DIR="$tmp/traffic.lock"
export TM_RESTART_SINGBOX_CMD="printf restarted > '$tmp/singbox.restart'"
export TM_RESTART_XRAY_CMD="printf 'restarted\\n' >> '$tmp/xray.restart'"
export TM_XRAY_BIN="$tmp/fake-xray"
mkdir -p "$TM_DIR" "$tmp/xray"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TM_XRAY_BIN"
chmod +x "$TM_XRAY_BIN"

cat > "$TM_SINGBOX_CONFIG" <<'JSON'
{"inbounds":[{"type":"vless","tag":"vless-in-443","listen":"::","listen_port":443}],"outbounds":[],"route":{"rules":[]}}
JSON
cat > "$TM_XRAY_CONFIG" <<'JSON'
{"inbounds":[{"tag":"xray-vless-8443","listen":"::","port":8443,"protocol":"vless","settings":{}},{"tag":"xray-trojan-9443","listen":"::","port":9443,"protocol":"trojan","settings":{}}],"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}
JSON

_tm_ensure_singbox_api
jq -e '.experimental.v2ray_api.listen == "127.0.0.1:10086" and .experimental.v2ray_api.stats.enabled == true' "$TM_SINGBOX_CONFIG" >/dev/null

_tm_ensure_xray_api
jq -e '.api.tag == "traffic-api" and .policy.system.statsInboundUplink == true and .policy.system.statsInboundDownlink == true' "$TM_XRAY_CONFIG" >/dev/null
jq -e '[.inbounds[] | select(.tag == "traffic-api" and .listen == "127.0.0.1")] | length == 1' "$TM_XRAY_CONFIG" >/dev/null

cat > "$tmp/query" <<'SH'
#!/usr/bin/env bash
if [ "$2" = "vless-in-443" ]; then
    printf '1100\n600\n500\n'
else
    printf '0\n0\n0\n'
fi
SH
chmod +x "$tmp/query"
export TM_STATS_QUERY_CMD="$tmp/query"

_tm_set singbox vless-in-443 once 1000
_tm_check
jq -e '.["singbox:vless-in-443"].used_bytes == 1100 and .["singbox:vless-in-443"].disabled == true' "$TM_STATE_FILE" >/dev/null
jq -e '[.inbounds[] | select(.tag == "vless-in-443")] | length == 0' "$TM_SINGBOX_CONFIG" >/dev/null
test -f "$tmp/singbox.restart"

jq '.["singbox:vless-in-443"].mode="monthly" | .["singbox:vless-in-443"].reset_day=1 | .["singbox:vless-in-443"].period_key="2000-01-01"' "$TM_STATE_FILE" > "$TM_STATE_FILE.tmp"
mv "$TM_STATE_FILE.tmp" "$TM_STATE_FILE"
cat > "$tmp/query" <<'SH'
#!/usr/bin/env bash
printf '0\n0\n0\n'
SH
chmod +x "$tmp/query"
_tm_check
jq -e '.["singbox:vless-in-443"].used_bytes == 0 and .["singbox:vless-in-443"].disabled == false' "$TM_STATE_FILE" >/dev/null
jq -e '[.inbounds[] | select(.tag == "vless-in-443")] | length == 1' "$TM_SINGBOX_CONFIG" >/dev/null

jq '.inbounds += [{"type":"vless","tag":"monthly-active","listen":"::","listen_port":2443}]' "$TM_SINGBOX_CONFIG" > "$TM_SINGBOX_CONFIG.tmp"
mv "$TM_SINGBOX_CONFIG.tmp" "$TM_SINGBOX_CONFIG"
_tm_set singbox monthly-active monthly 10000 1
jq '.["singbox:monthly-active"].used_bytes=500 | .["singbox:monthly-active"].period_key="2000-01-01" | .["singbox:monthly-active"].last_uplink=100 | .["singbox:monthly-active"].last_downlink=100' "$TM_STATE_FILE" > "$TM_STATE_FILE.tmp"
mv "$TM_STATE_FILE.tmp" "$TM_STATE_FILE"
cat > "$tmp/query" <<'SH'
#!/usr/bin/env bash
if [ "$2" = monthly-active ]; then printf '2000\n1200\n800\n'; else printf '0\n0\n0\n'; fi
SH
chmod +x "$tmp/query"
_tm_check
jq -e '.["singbox:monthly-active"].used_bytes == 0 and .["singbox:monthly-active"].last_uplink == 1200 and .["singbox:monthly-active"].last_downlink == 800' "$TM_STATE_FILE" >/dev/null
cat > "$tmp/query" <<'SH'
#!/usr/bin/env bash
if [ "$2" = monthly-active ]; then printf '2300\n1400\n900\n'; else printf '0\n0\n0\n'; fi
SH
chmod +x "$tmp/query"
_tm_check
jq -e '.["singbox:monthly-active"].used_bytes == 300' "$TM_STATE_FILE" >/dev/null

cat > "$tmp/query" <<'SH'
#!/usr/bin/env bash
if [ "$1" = xray ]; then printf '800\n400\n400\n'; else printf '0\n0\n0\n'; fi
SH
chmod +x "$tmp/query"
_tm_set xray xray-vless-8443 once 500
_tm_set xray xray-trojan-9443 once 500
_tm_check
jq -e '.["xray:xray-vless-8443"].disabled == true and .["xray:xray-trojan-9443"].disabled == true' "$TM_STATE_FILE" >/dev/null
jq -e '([.inbounds[] | select(.tag == "traffic-api")] | length) == 1 and ([.inbounds[] | select(.tag != "traffic-api")] | length) == 0' "$TM_XRAY_CONFIG" >/dev/null
test "$(wc -l < "$tmp/xray.restart" | tr -d ' ')" = 1

echo "All traffic manager integration tests passed"
