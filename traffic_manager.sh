#!/usr/bin/env bash

TM_DIR="${TM_DIR:-/usr/local/etc/sing-box}"
TM_STATE_FILE="${TM_STATE_FILE:-${TM_DIR}/traffic_limits.json}"
TM_LOCK_DIR="${TM_LOCK_DIR:-/tmp/singbox-lite-traffic.lock}"
TM_SCRIPT_PATH="${TM_SCRIPT_PATH:-/usr/local/etc/sing-box/traffic_manager.sh}"
TM_XRAY_CLIENT_BIN="${TM_XRAY_CLIENT_BIN:-/usr/local/lib/singbox-lite/xray-api}"

_tm_parse_size() {
    local input number unit
    input=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
    if [[ ! "$input" =~ ^([0-9]+([.][0-9]+)?)(MB|GB|TB)$ ]]; then
        return 1
    fi
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[3]}"
    awk -v n="$number" -v u="$unit" 'BEGIN {
        m = 1048576
        if (u == "GB") m *= 1024
        if (u == "TB") m *= 1048576
        value = int(n * m)
        if (value <= 0) exit 1
        printf "%.0f", value
    }'
}

_tm_format_bytes() {
    awk -v b="${1:-0}" 'BEGIN {
        if (b >= 1099511627776) printf "%.2f TB", b / 1099511627776
        else if (b >= 1073741824) printf "%.2f GB", b / 1073741824
        else if (b >= 1048576) printf "%.2f MB", b / 1048576
        else if (b >= 1024) printf "%.2f KB", b / 1024
        else printf "%d B", b
    }'
}

_tm_counter_delta() {
    local current="${1:-0}" previous="${2:-0}"
    if [ "$current" -ge "$previous" ]; then
        echo $((current - previous))
    else
        echo "$current"
    fi
}

_tm_effective_reset_day() {
    local year="$1" month=$((10#$2)) requested="$3" last
    case "$month" in
        1|3|5|7|8|10|12) last=31 ;;
        4|6|9|11) last=30 ;;
        2)
            if { [ $((year % 400)) -eq 0 ] || { [ $((year % 4)) -eq 0 ] && [ $((year % 100)) -ne 0 ]; }; }; then last=29; else last=28; fi
            ;;
        *) return 1 ;;
    esac
    [ "$requested" -gt "$last" ] && echo "$last" || echo "$requested"
}

_tm_is_exceeded() {
    [ "${1:-0}" -ge "${2:-1}" ] && echo true || echo false
}

_tm_require_jq() {
    command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; return 1; }
}

_tm_stats_client() {
    [ -x "${TM_XRAY_BIN:-/usr/local/bin/xray}" ] && { echo "${TM_XRAY_BIN:-/usr/local/bin/xray}"; return; }
    [ -x "$TM_XRAY_CLIENT_BIN" ] && { echo "$TM_XRAY_CLIENT_BIN"; return; }
    return 1
}

_tm_ensure_stats_client() {
    _tm_stats_client >/dev/null 2>&1 && return 0
    command -v unzip >/dev/null 2>&1 || { echo "unzip is required" >&2; return 1; }
    command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum is required" >&2; return 1; }
    local arch asset tmp url expected actual
    case "$(uname -m)" in x86_64|amd64) asset=64;; aarch64|arm64) asset=arm64-v8a;; armv7l) asset=arm32-v7a;; *) return 1;; esac
    tmp=$(mktemp -d) || return 1
    url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${asset}.zip"
    if command -v curl >/dev/null 2>&1; then
        curl -LfsS "$url" -o "$tmp/xray.zip" && curl -LfsS "${url}.dgst" -o "$tmp/xray.zip.dgst" || { rm -rf "$tmp"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$url" -O "$tmp/xray.zip" && wget -q "${url}.dgst" -O "$tmp/xray.zip.dgst" || { rm -rf "$tmp"; return 1; }
    else rm -rf "$tmp"; return 1; fi
    expected=$(grep -Eio '[a-f0-9]{64}' "$tmp/xray.zip.dgst" | head -1); actual=$(sha256sum "$tmp/xray.zip" | awk '{print $1}')
    [ -n "$expected" ] && [ "${expected,,}" = "${actual,,}" ] || { echo "Xray checksum verification failed" >&2; rm -rf "$tmp"; return 1; }
    unzip -qo "$tmp/xray.zip" xray -d "$tmp" || { rm -rf "$tmp"; return 1; }
    mkdir -p "$(dirname "$TM_XRAY_CLIENT_BIN")" && mv "$tmp/xray" "$TM_XRAY_CLIENT_BIN" && chmod +x "$TM_XRAY_CLIENT_BIN"
    rm -rf "$tmp"
}

_tm_validate_config() {
    local core="$1" file="$2" output
    if [ "$core" = singbox ]; then
        [ -x "${TM_SINGBOX_BIN:-/usr/local/bin/sing-box}" ] || return 1
        output=$(ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM=true ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true "${TM_SINGBOX_BIN:-/usr/local/bin/sing-box}" check -c "$file" 2>&1) || {
            printf 'sing-box config validation failed:\n%s\n' "$output" >&2
            return 1
        }
    else
        local client; client=$(_tm_stats_client) || return 1
        output=$("$client" run -test -config "$file" 2>&1) || {
            printf 'xray config validation failed:\n%s\n' "$output" >&2
            return 1
        }
    fi
}

_tm_init() {
    _tm_require_jq || return 1
    mkdir -p "$TM_DIR"
    [ -s "$TM_STATE_FILE" ] || printf '{}\n' > "$TM_STATE_FILE"
    jq empty "$TM_STATE_FILE" >/dev/null 2>&1 || { echo "invalid traffic state" >&2; return 1; }
}

_tm_atomic_jq() {
    local filter="$1" tmp="${TM_STATE_FILE}.tmp.$$"
    shift
    jq "$@" "$filter" "$TM_STATE_FILE" > "$tmp" && mv "$tmp" "$TM_STATE_FILE" || { rm -f "$tmp"; return 1; }
}

_tm_key() { printf '%s:%s' "$1" "$2"; }

_tm_set() {
    local core="$1" tag="$2" mode="$3" limit="$4" reset_day="${5:-}" defer_probe="${6:-false}" key pattern period="" config backup_dir
    [[ "$core" =~ ^(singbox|xray)$ ]] || return 1
    [[ "$mode" =~ ^(once|monthly)$ ]] || return 1
    [[ "$limit" =~ ^[0-9]+$ ]] && [ "$limit" -gt 0 ] || return 1
    if [ "$mode" = monthly ]; then
        [[ "$reset_day" =~ ^[0-9]+$ ]] && [ "$reset_day" -ge 1 ] && [ "$reset_day" -le 31 ] || return 1
        period=$(_tm_period_key "$(date +%F)" "$reset_day") || return 1
    else
        reset_day=""
    fi
    _tm_init || return 1
    backup_dir=$(mktemp -d) || return 1
    cp "$TM_STATE_FILE" "$backup_dir/state.json"
    config=$(_tm_config_path "$core"); [ -f "$config" ] && cp "$config" "$backup_dir/config.json"
    key=$(_tm_key "$core" "$tag")
    pattern="^${tag}(-hop-[0-9]+)?$"
    if [ "$core" = singbox ]; then
        local helper_count helper_min helper_max
        helper_count=$(jq --arg t "$tag" '[.inbounds[]?.tag | select(startswith($t + "-hop-"))] | length' "$config" 2>/dev/null || echo 0)
        if [ "$helper_count" -gt 512 ]; then echo "traffic quotas support at most 512 native Hysteria2 helper inbounds" >&2; rm -rf "$backup_dir"; return 1; fi
        if [ "$helper_count" -gt 0 ]; then
            read -r helper_min helper_max < <(jq -r --arg t "$tag" '[.inbounds[] | select(.tag | startswith($t + "-hop-")) | .listen_port] | [min,max] | @tsv' "$config" | tr -d '\r')
            if [ "$helper_count" -ne $((helper_max - helper_min + 1)) ]; then echo "Hysteria2 helper ports must be contiguous for traffic quotas" >&2; rm -rf "$backup_dir"; return 1; fi
        fi
    fi
    _tm_ensure_stats_client || { echo "failed to prepare traffic statistics client" >&2; rm -rf "$backup_dir"; return 1; }
    if [ "$core" = singbox ]; then
        _tm_ensure_singbox_api "$tag" || { echo "failed to enable sing-box traffic statistics API" >&2; rm -rf "$backup_dir"; return 1; }
    else
        _tm_ensure_xray_api || { echo "failed to enable xray traffic statistics API" >&2; rm -rf "$backup_dir"; return 1; }
    fi
    _tm_atomic_jq '. + {($k): ((.[$k] // {}) + {core:$c,tag:$t,mode:$m,limit_bytes:($l|tonumber),used_bytes:(.[$k].used_bytes // 0),reset_day:(if $r=="" then null else ($r|tonumber) end),period_key:(if $p=="" then null else $p end),member_pattern:$pat,last_uplink:(.[$k].last_uplink // 0),last_downlink:(.[$k].last_downlink // 0),disabled:(.[$k].disabled // false),disabled_reason:(.[$k].disabled_reason // null)})}' \
        --arg k "$key" --arg c "$core" --arg t "$tag" --arg m "$mode" --arg l "$limit" --arg r "$reset_day" --arg p "$period" --arg pat "$pattern" || { echo "failed to save traffic quota state" >&2; [ -f "$backup_dir/config.json" ] && cp "$backup_dir/config.json" "$config"; rm -rf "$backup_dir"; return 1; }
    if [ "$(jq -r --arg k "$key" '.[$k].disabled // false' "$TM_STATE_FILE")" = true ] && [ "$(jq -r --arg k "$key" '.[$k].used_bytes < .[$k].limit_bytes' "$TM_STATE_FILE")" = true ]; then
        if ! _tm_restore_transaction "$core" "$tag"; then cp "$backup_dir/state.json" "$TM_STATE_FILE"; [ -f "$backup_dir/config.json" ] && cp "$backup_dir/config.json" "$config"; rm -rf "$backup_dir"; return 1; fi
        defer_probe=true
    fi
    if [ "$defer_probe" != true ]; then
        if ! _tm_restart_core "$core" || ! _tm_probe "$core" "$tag"; then
            cp "$backup_dir/state.json" "$TM_STATE_FILE"; [ -f "$backup_dir/config.json" ] && cp "$backup_dir/config.json" "$config"
            _tm_restart_core "$core" >/dev/null 2>&1 || true
            rm -rf "$backup_dir"; return 1
        fi
    fi
    rm -rf "$backup_dir"
    _tm_install_schedule || { echo "failed to install traffic quota schedule" >&2; return 1; }
}

_tm_period_key() {
    local today="$1" requested="$2" year month day effective prev_year prev_month
    IFS=- read -r year month day <<< "$today"
    effective=$(_tm_effective_reset_day "$year" "$month" "$requested") || return 1
    if [ $((10#$day)) -ge "$effective" ]; then
        printf '%04d-%02d-%02d' "$year" "$((10#$month))" "$effective"
        return
    fi
    prev_year="$year"; prev_month=$((10#$month - 1))
    if [ "$prev_month" -eq 0 ]; then prev_month=12; prev_year=$((year - 1)); fi
    effective=$(_tm_effective_reset_day "$prev_year" "$prev_month" "$requested") || return 1
    printf '%04d-%02d-%02d' "$prev_year" "$prev_month" "$effective"
}

_tm_status() {
    _tm_init || return 1
    local key; key=$(_tm_key "$1" "$2")
    jq -c --arg k "$key" '.[$k] // null' "$TM_STATE_FILE"
}

_tm_list() {
    _tm_init || return 1
    jq -c --arg c "$1" 'to_entries[] | select(.value.core == $c) | .value + {key:.key}' "$TM_STATE_FILE"
}

_tm_restore_transaction() {
    local core="$1" tag="$2" config backup_dir
    backup_dir=$(mktemp -d) || return 1
    config=$(_tm_config_path "$core")
    cp "$TM_STATE_FILE" "$backup_dir/state.json"; [ -f "$config" ] && cp "$config" "$backup_dir/config.json"
    _tm_restore_node "$core" "$tag" || { rm -rf "$backup_dir"; return 1; }
    if ! _tm_restart_core "$core"; then
        cp "$backup_dir/state.json" "$TM_STATE_FILE"; [ -f "$backup_dir/config.json" ] && cp "$backup_dir/config.json" "$config"
        _tm_restart_core "$core" >/dev/null 2>&1 || true
        rm -rf "$backup_dir"; return 1
    fi
    rm -rf "$backup_dir"
}

_tm_remove() {
    _tm_init || return 1
    local key; key=$(_tm_key "$1" "$2")
    if [ "$(jq -r --arg k "$key" '.[$k].disabled // false' "$TM_STATE_FILE")" = true ]; then
        _tm_restore_transaction "$1" "$2" || return 1
    fi
    _tm_atomic_jq 'del(.[$k])' --arg k "$key" || return 1
    if [ "$(jq 'length' "$TM_STATE_FILE")" -eq 0 ]; then
        _tm_remove_schedule
    fi
}

_tm_reset_usage() {
    _tm_init || return 1
    local key; key=$(_tm_key "$1" "$2")
    if [ "$(jq -r --arg k "$key" '.[$k].disabled // false' "$TM_STATE_FILE")" = true ]; then
        _tm_restore_transaction "$1" "$2" || return 1
    fi
    _tm_atomic_jq 'if .[$k] then .[$k].used_bytes=0 | .[$k].last_uplink=0 | .[$k].last_downlink=0 else . end' --arg k "$key"
}

_tm_edit_identity() {
    _tm_init || return 1
    local core="$1" old_tag="$2" new_tag="$3" old_port="$4" new_port="$5" old_key new_key pattern
    old_key=$(_tm_key "$core" "$old_tag"); new_key=$(_tm_key "$core" "$new_tag")
    pattern="^${new_tag}(-hop-[0-9]+)?$"
    _tm_atomic_jq 'if .[$ok] then . + {($nk): (.[$ok] | .tag=$nt | .member_pattern=$pat | .saved_primary_inbound=(if .saved_primary_inbound then (.saved_primary_inbound | .tag=$nt | if has("listen_port") and .listen_port == ($op|tonumber) then .listen_port=($np|tonumber) elif has("port") and .port == ($op|tonumber) then .port=($np|tonumber) else . end) else null end) | .last_uplink=0 | .last_downlink=0)} | del(.[$ok]) else . end' \
        --arg ok "$old_key" --arg nk "$new_key" --arg ot "$old_tag" --arg nt "$new_tag" --arg pat "$pattern" --arg op "$old_port" --arg np "$new_port"
}

_tm_port_in_use() {
    _tm_init || return 1
    local core="$1" port="$2"
    jq -e --arg c "$core" --argjson p "$port" 'any(.[]; .core == $c and (((.saved_primary_inbound.listen_port // .saved_primary_inbound.port // 0) == $p) or ((.saved_helper_start // 0) <= $p and $p <= (.saved_helper_end // -1))))' "$TM_STATE_FILE" >/dev/null
}

_tm_clear_core() {
    _tm_init || return 1
    _tm_atomic_jq 'with_entries(select(.value.core != $c))' --arg c "$1"
}

_tm_purge() {
    _tm_init || return 1
    local key; key=$(_tm_key "$1" "$2")
    _tm_atomic_jq 'del(.[$k])' --arg k "$key" || return 1
    [ "$(jq 'length' "$TM_STATE_FILE")" -eq 0 ] && _tm_remove_schedule
}

_tm_acquire_lock() {
    local owner="${TM_LOCK_OWNER_PID:-$$}" existing=""
    if mkdir "$TM_LOCK_DIR" 2>/dev/null; then printf '%s\n' "$owner" > "$TM_LOCK_DIR/pid"; return 0; fi
    [ -s "$TM_LOCK_DIR/pid" ] && existing=$(cat "$TM_LOCK_DIR/pid" 2>/dev/null)
    [ "$existing" = "$owner" ] && return 0
    if [ -z "$existing" ] || ! kill -0 "$existing" 2>/dev/null; then
        rm -rf "$TM_LOCK_DIR" 2>/dev/null
        mkdir "$TM_LOCK_DIR" 2>/dev/null || return 1
        printf '%s\n' "$owner" > "$TM_LOCK_DIR/pid"
        return 0
    fi
    return 1
}
_tm_release_lock() { rm -rf "$TM_LOCK_DIR" 2>/dev/null || true; }

_tm_config_path() {
    [ "$1" = xray ] && echo "${TM_XRAY_CONFIG:-/usr/local/etc/xray/config.json}" || echo "${TM_SINGBOX_CONFIG:-${TM_DIR}/config.json}"
}

_tm_ensure_singbox_api() {
    _tm_require_jq || return 1
    local config tmp tag="${1:-}"
    config="${TM_SINGBOX_CONFIG:-${TM_DIR}/config.json}"; tmp="${config}.tmp.$$"
    [ -f "$config" ] || return 1
    jq --arg t "$tag" '([.inbounds[]?.tag | select(. == $t or startswith($t + "-hop-"))]) as $members | .experimental = (.experimental // {}) | .experimental.v2ray_api = ((.experimental.v2ray_api // {}) + {listen:(env.TM_SINGBOX_API_LISTEN // "127.0.0.1:10086"), stats:((.experimental.v2ray_api.stats // {}) + {enabled:true,inbounds:((.experimental.v2ray_api.stats.inbounds // []) + $members | unique)})})' "$config" > "$tmp" || return 1
    _tm_validate_config singbox "$tmp" && mv "$tmp" "$config" || { rm -f "$tmp"; return 1; }
}

_tm_ensure_xray_api() {
    _tm_require_jq || return 1
    local config tmp port
    config="${TM_XRAY_CONFIG:-/usr/local/etc/xray/config.json}"; tmp="${config}.tmp.$$"; port="${TM_XRAY_API_PORT:-10085}"
    [ -f "$config" ] || return 1
    jq --argjson p "$port" '.api = ((.api // {}) + {tag:"traffic-api",services:((.api.services // []) + ["StatsService"] | unique)}) | .stats = (.stats // {}) | .policy = (.policy // {}) | .policy.system = ((.policy.system // {}) + {statsInboundUplink:true,statsInboundDownlink:true}) | .inbounds = ([.inbounds[]? | select(.tag != "traffic-api")] + [{tag:"traffic-api",listen:"127.0.0.1",port:$p,protocol:"dokodemo-door",settings:{address:"127.0.0.1"}}]) | .routing = (.routing // {}) | .routing.rules = ([.routing.rules[]? | select(.inboundTag == null or (.inboundTag | index("traffic-api") | not))] + [{type:"field",inboundTag:["traffic-api"],outboundTag:"traffic-api"}])' "$config" > "$tmp" || return 1
    _tm_validate_config xray "$tmp" && mv "$tmp" "$config" || { rm -f "$tmp"; return 1; }
}

_tm_query_counters() {
    local core="$1" tag="$2" endpoint pattern raw
    if [ -n "${TM_STATS_QUERY_CMD:-}" ]; then
        "$TM_STATS_QUERY_CMD" "$core" "$tag"
        return
    fi
    endpoint="${TM_XRAY_API_LISTEN:-127.0.0.1:10085}"
    [ "$core" = singbox ] && endpoint="${TM_SINGBOX_API_LISTEN:-127.0.0.1:10086}"
    pattern="inbound>>>${tag}"
    local client; client=$(_tm_stats_client) || return 1
    raw=$("$client" api statsquery --server="$endpoint" -pattern "$pattern" 2>/dev/null) || return 1
    echo "$raw" | jq -r --arg t "$tag" '[.stat[]? | select((.name | startswith("inbound>>>" + $t + ">>>")) or (.name | startswith("inbound>>>" + $t + "-hop-"))) | select(.name | endswith(">>>uplink") or endswith(">>>downlink")) | (.value|tonumber)] | add // 0' 2>/dev/null
    echo "$raw" | jq -r --arg t "$tag" '[.stat[]? | select((.name | startswith("inbound>>>" + $t + ">>>")) or (.name | startswith("inbound>>>" + $t + "-hop-"))) | select(.name | endswith(">>>uplink")) | (.value|tonumber)] | add // 0' 2>/dev/null
    echo "$raw" | jq -r --arg t "$tag" '[.stat[]? | select((.name | startswith("inbound>>>" + $t + ">>>")) or (.name | startswith("inbound>>>" + $t + "-hop-"))) | select(.name | endswith(">>>downlink")) | (.value|tonumber)] | add // 0' 2>/dev/null
}

_tm_probe() {
    local counters; counters=$(_tm_query_counters "$1" "$2") || return 1
    [ "$(printf '%s\n' "$counters" | wc -l)" -ge 3 ]
}

_tm_restart_core() {
    local core="$1"
    if [ "$core" = singbox ]; then
        if [ -n "${TM_RESTART_SINGBOX_CMD:-}" ]; then eval "$TM_RESTART_SINGBOX_CMD"
        elif command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then systemctl restart sing-box
        elif command -v rc-service >/dev/null 2>&1; then rc-service sing-box restart
        else
            local sb_bin="${TM_SINGBOX_BIN:-/usr/local/bin/sing-box}" sb_pid="${TM_SINGBOX_PID_FILE:-/tmp/sing-box.pid}" sb_log="${TM_SINGBOX_LOG_FILE:-/var/log/sing-box.log}"
            if [ -s "$sb_pid" ]; then local old_pid; old_pid=$(cat "$sb_pid" 2>/dev/null); _tm_pid_matches "$old_pid" "$sb_bin" && kill "$old_pid" 2>/dev/null || true; fi
            nohup "$sb_bin" run -c "$(_tm_config_path singbox)" -c "${TM_RELAY_CONFIG:-${TM_DIR}/relay.json}" >> "$sb_log" 2>&1 & echo $! > "$sb_pid"
            sleep 1; kill -0 "$(cat "$sb_pid")" 2>/dev/null
        fi
    else
        if [ -n "${TM_RESTART_XRAY_CMD:-}" ]; then eval "$TM_RESTART_XRAY_CMD"
        elif command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then systemctl restart xray
        elif command -v rc-service >/dev/null 2>&1; then rc-service xray restart
        else
            local xr_bin; xr_bin=$(_tm_stats_client) || return 1
            local xr_pid="${TM_XRAY_PID_FILE:-/tmp/xray.pid}" xr_log="${TM_XRAY_LOG_FILE:-/var/log/xray.log}"
            if [ -s "$xr_pid" ]; then local old_pid; old_pid=$(cat "$xr_pid" 2>/dev/null); _tm_pid_matches "$old_pid" "$xr_bin" && kill "$old_pid" 2>/dev/null || true; fi
            nohup "$xr_bin" run -c "$(_tm_config_path xray)" >> "$xr_log" 2>&1 & echo $! > "$xr_pid"
            sleep 1; kill -0 "$(cat "$xr_pid")" 2>/dev/null
        fi
    fi
}

_tm_pid_matches() {
    local pid="$1" binary="$2"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
    if [ -r "/proc/${pid}/cmdline" ]; then tr '\0' ' ' < "/proc/${pid}/cmdline" | grep -Fq "$binary"
    else ps -p "$pid" -o args= 2>/dev/null | grep -Fq "$binary"; fi
}

_tm_disable_node() {
    local core="$1" tag="$2" config tmp key backup saved primary helper_count helper_min helper_max helper_template
    config=$(_tm_config_path "$core"); [ -f "$config" ] || return 1
    key=$(_tm_key "$core" "$tag"); tmp="${config}.tmp.$$"; backup="${config}.traffic-bak.$$"; cp "$config" "$backup"
    primary=$(jq -c --arg t "$tag" '.inbounds[] | select(.tag == $t)' "$config" | head -1)
    helper_count=$(jq --arg t "$tag" '[.inbounds[]? | select(.tag | startswith($t + "-hop-"))] | length' "$config")
    if [ "$helper_count" -gt 0 ]; then
        helper_min=$(jq -r --arg t "$tag" '[.inbounds[] | select(.tag | startswith($t + "-hop-")) | .listen_port] | min' "$config" | tr -d '\r')
        helper_max=$(jq -r --arg t "$tag" '[.inbounds[] | select(.tag | startswith($t + "-hop-")) | .listen_port] | max' "$config" | tr -d '\r')
        helper_template=$(jq -c --arg t "$tag" 'first(.inbounds[] | select(.tag | startswith($t + "-hop-")) | del(.tag,.listen_port))' "$config")
    fi
    jq --arg t "$tag" '.inbounds |= map(select(.tag != $t and ((.tag | startswith($t + "-hop-")) | not)))' "$config" > "$tmp" || { rm -f "$tmp" "$backup"; return 1; }
    _tm_validate_config "$core" "$tmp" && mv "$tmp" "$config" || { rm -f "$tmp" "${tmp}.json" "$backup"; return 1; }
    if ! _tm_atomic_jq ' .[$k].disabled=true | .[$k].disabled_reason="quota" | .[$k].saved_primary_inbound=$p | .[$k].saved_helper_template=$h | .[$k].saved_helper_start=(if $hs=="" then null else ($hs|tonumber) end) | .[$k].saved_helper_end=(if $he=="" then null else ($he|tonumber) end) ' --arg k "$key" --argjson p "${primary:-null}" --argjson h "${helper_template:-null}" --arg hs "${helper_min:-}" --arg he "${helper_max:-}"; then
        mv "$backup" "$config"; return 1
    fi
    rm -f "$backup"
}

_tm_restore_node() {
    local core="$1" tag="$2" config tmp key backup saved primary template start end p
    config=$(_tm_config_path "$core"); [ -f "$config" ] || return 1
    key=$(_tm_key "$core" "$tag"); tmp="${config}.tmp.$$"; backup="${config}.traffic-bak.$$"; cp "$config" "$backup"
    primary=$(jq -c --arg k "$key" '.[$k].saved_primary_inbound // null' "$TM_STATE_FILE")
    template=$(jq -c --arg k "$key" '.[$k].saved_helper_template // null' "$TM_STATE_FILE")
    start=$(jq -r --arg k "$key" '.[$k].saved_helper_start // empty' "$TM_STATE_FILE" | tr -d '\r'); end=$(jq -r --arg k "$key" '.[$k].saved_helper_end // empty' "$TM_STATE_FILE" | tr -d '\r')
    if [ "$primary" = null ] || [ -z "$primary" ]; then
        saved=$(jq -c --arg k "$key" '.[$k].saved_inbounds // []' "$TM_STATE_FILE")
    else
        saved="[$primary]"
        if [ "$template" != null ] && [ -n "$start" ] && [ -n "$end" ]; then
            for ((p=start; p<=end; p++)); do saved=$(jq -c --argjson s "$saved" --argjson t "$template" --arg tag "${tag}-hop-${p}" --argjson port "$p" '$s + [($t + {tag:$tag,listen_port:$port})]' <<< '{}'); done
        fi
    fi
    [ "$saved" != '[]' ] || { rm -f "$backup"; return 0; }
    if jq -e --argjson s "$saved" 'any($s[] as $node; any(.inbounds[]?; ((.listen_port // .port // 0) == ($node.listen_port // $node.port // -1)) or .tag == $node.tag))' "$config" >/dev/null 2>&1; then rm -f "$backup"; return 1; fi
    jq --argjson s "$saved" '.inbounds = ((.inbounds // []) + $s)' "$config" > "$tmp" || { rm -f "$tmp" "$backup"; return 1; }
    _tm_validate_config "$core" "$tmp" && mv "$tmp" "$config" || { rm -f "$tmp" "$backup"; return 1; }
    if ! _tm_atomic_jq ' .[$k].disabled=false | .[$k].disabled_reason=null | .[$k].saved_inbounds=null | .[$k].saved_primary_inbound=null | .[$k].saved_helper_template=null | .[$k].saved_helper_start=null | .[$k].saved_helper_end=null | .[$k].last_uplink=0 | .[$k].last_downlink=0 ' --arg k "$key"; then
        mv "$backup" "$config"; return 1
    fi
    rm -f "$backup"
}

_tm_check() {
    _tm_init || return 1
    _tm_acquire_lock || return 0
    local rollback_dir; rollback_dir=$(mktemp -d) || { _tm_release_lock; return 1; }
    cp "$TM_STATE_FILE" "$rollback_dir/state.json"
    [ -f "$(_tm_config_path singbox)" ] && cp "$(_tm_config_path singbox)" "$rollback_dir/singbox.json"
    [ -f "$(_tm_config_path xray)" ] && cp "$(_tm_config_path xray)" "$rollback_dir/xray.json"
    local changed_singbox=false changed_xray=false key core tag mode limit used old_u old_d current_u current_d delta_u delta_d now_period saved_period
    while IFS=$'\t' read -r key core tag mode limit used saved_period; do
        [ -n "$key" ] || continue
        local reset_day; reset_day=$(jq -r --arg k "$key" '.[$k].reset_day // 0' "$TM_STATE_FILE")
        if [ "$mode" = monthly ] && [ "$reset_day" -gt 0 ]; then
            now_period=$(_tm_period_key "$(date +%F)" "$reset_day")
            if [ "$now_period" != "$saved_period" ]; then
                if [ "$(jq -r --arg k "$key" '.[$k].disabled // false' "$TM_STATE_FILE")" = true ]; then
                    _tm_restore_node "$core" "$tag" && { [ "$core" = singbox ] && changed_singbox=true || changed_xray=true; }
                    _tm_atomic_jq '.[$k].used_bytes=0 | .[$k].period_key=$p | .[$k].last_uplink=0 | .[$k].last_downlink=0' --arg k "$key" --arg p "$now_period"
                else
                    local reset_counters reset_u=0 reset_d=0
                    reset_counters=$(_tm_query_counters "$core" "$tag") || continue
                    mapfile -t _tm_reset_counts <<< "$reset_counters"
                    [ "${#_tm_reset_counts[@]}" -ge 3 ] || continue
                    reset_u="${_tm_reset_counts[1]}"; reset_d="${_tm_reset_counts[2]}"
                    _tm_atomic_jq '.[$k].used_bytes=0 | .[$k].period_key=$p | .[$k].last_uplink=$up | .[$k].last_downlink=$down' --arg k "$key" --arg p "$now_period" --argjson up "$reset_u" --argjson down "$reset_d"
                fi
                continue
            fi
        fi
        [ "$(jq -r --arg k "$key" '.[$k].disabled // false' "$TM_STATE_FILE")" = true ] && continue
        local counters
        if ! counters=$(_tm_query_counters "$core" "$tag"); then
            _tm_atomic_jq '.[$k].stats_failures=((.[$k].stats_failures // 0)+1) | .[$k].last_error="stats query failed"' --arg k "$key" || true
            command -v logger >/dev/null 2>&1 && logger -t singbox-lite-traffic "statistics query failed for ${core}:${tag}"
            continue
        fi
        _tm_atomic_jq '.[$k].stats_failures=0 | .[$k].last_error=null' --arg k "$key" || true
        mapfile -t _tm_counts <<< "$counters"; [ "${#_tm_counts[@]}" -ge 3 ] || continue
        current_u="${_tm_counts[1]}"; current_d="${_tm_counts[2]}"
        old_u=$(jq -r --arg k "$key" '.[$k].last_uplink // 0' "$TM_STATE_FILE"); old_d=$(jq -r --arg k "$key" '.[$k].last_downlink // 0' "$TM_STATE_FILE")
        delta_u=$(_tm_counter_delta "$current_u" "$old_u"); delta_d=$(_tm_counter_delta "$current_d" "$old_d"); used=$((used + delta_u + delta_d))
        _tm_atomic_jq '.[$k].used_bytes=$u | .[$k].last_uplink=$up | .[$k].last_downlink=$down' --arg k "$key" --argjson u "$used" --argjson up "$current_u" --argjson down "$current_d"
        if [ "$(_tm_is_exceeded "$used" "$limit")" = true ]; then
            _tm_disable_node "$core" "$tag" && { [ "$core" = singbox ] && changed_singbox=true || changed_xray=true; }
        fi
    done < <(jq -r 'to_entries[] | [.key,.value.core,.value.tag,.value.mode,(.value.limit_bytes|tostring),(.value.used_bytes|tostring),(.value.period_key // "")] | @tsv' "$TM_STATE_FILE" | tr -d '\r')
    local restart_failed=false
    [ "$changed_singbox" = true ] && ! _tm_restart_core singbox && restart_failed=true
    [ "$changed_xray" = true ] && ! _tm_restart_core xray && restart_failed=true
    if [ "$restart_failed" = true ]; then
        cp "$rollback_dir/state.json" "$TM_STATE_FILE"
        [ -f "$rollback_dir/singbox.json" ] && cp "$rollback_dir/singbox.json" "$(_tm_config_path singbox)"
        [ -f "$rollback_dir/xray.json" ] && cp "$rollback_dir/xray.json" "$(_tm_config_path xray)"
        [ "$changed_singbox" = true ] && _tm_restart_core singbox >/dev/null 2>&1 || true
        [ "$changed_xray" = true ] && _tm_restart_core xray >/dev/null 2>&1 || true
        rm -rf "$rollback_dir"; _tm_release_lock; return 1
    fi
    rm -rf "$rollback_dir"
    _tm_release_lock
}

_tm_install_schedule() {
    local script="${TM_SCRIPT_PATH:-$0}" cron_file="${TM_CRON_FILE:-}"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] && [ -z "${TM_CRON_FILE:-}" ]; then
        cat > /etc/systemd/system/singbox-lite-traffic.service <<EOF
[Unit]
Description=singbox-lite traffic quota check
[Service]
Type=oneshot
ExecStart=${script} check
EOF
        cat > /etc/systemd/system/singbox-lite-traffic.timer <<'EOF'
[Unit]
Description=Run singbox-lite traffic quota check every minute
[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s
[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable --now singbox-lite-traffic.timer >/dev/null 2>&1
    elif [ -n "$cron_file" ]; then
        mkdir -p "$(dirname "$cron_file")" || return 1
        printf '* * * * * root %s check >/dev/null 2>&1\n' "$script" > "$cron_file"
    elif [ -d /etc/crontabs ]; then
        cron_file=/etc/crontabs/root
        touch "$cron_file"
        sed -i '/# singbox-lite-traffic$/d' "$cron_file"
        printf '* * * * * %s check >/dev/null 2>&1 # singbox-lite-traffic\n' "$script" >> "$cron_file"
        command -v rc-service >/dev/null 2>&1 && rc-service crond restart >/dev/null 2>&1 || true
    else
        cron_file=/etc/cron.d/singbox-lite-traffic
        mkdir -p /etc/cron.d
        printf '* * * * * root %s check >/dev/null 2>&1\n' "$script" > "$cron_file"
    fi
}

_tm_remove_schedule() {
    rm -f "${TM_CRON_FILE:-/etc/cron.d/singbox-lite-traffic}"
    [ -f /etc/crontabs/root ] && sed -i '/# singbox-lite-traffic$/d' /etc/crontabs/root
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now singbox-lite-traffic.timer >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/singbox-lite-traffic.timer /etc/systemd/system/singbox-lite-traffic.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

_tm_cleanup() {
    _tm_remove_schedule
    local config tmp
    config="${TM_SINGBOX_CONFIG:-${TM_DIR}/config.json}"
    if [ -f "$config" ]; then
        tmp="${config}.tmp.$$"
        jq 'if .experimental.v2ray_api.listen == "127.0.0.1:10086" then del(.experimental.v2ray_api) else . end | if (.experimental // {} | length) == 0 then del(.experimental) else . end' "$config" > "$tmp" && mv "$tmp" "$config"
    fi
    config="${TM_XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
    if [ -f "$config" ]; then
        tmp="${config}.tmp.$$"
        jq 'if .api.tag == "traffic-api" then del(.api) else . end | .inbounds = [.inbounds[]? | select(.tag != "traffic-api")] | .routing.rules = [.routing.rules[]? | select(.outboundTag != "traffic-api")] | if .policy.system then del(.policy.system.statsInboundUplink,.policy.system.statsInboundDownlink) else . end' "$config" > "$tmp" && mv "$tmp" "$config"
    fi
    [ "$TM_XRAY_CLIENT_BIN" = "/usr/local/lib/singbox-lite/xray-api" ] && rm -f "$TM_XRAY_CLIENT_BIN"
}

_tm_usage() {
    cat <<'EOF'
traffic_manager.sh init
traffic_manager.sh set <singbox|xray> <tag> <once|monthly> <bytes> [reset-day]
traffic_manager.sh status <singbox|xray> <tag>
traffic_manager.sh remove <singbox|xray> <tag>
traffic_manager.sh reset-usage <singbox|xray> <tag>
traffic_manager.sh parse-size <size>
traffic_manager.sh format-bytes <bytes>
EOF
}

_tm_main() {
    local cmd="${1:-}"; shift || true
    case "$cmd" in
        init) _tm_init ;;
        set) _tm_set "$@" ;;
        status) _tm_status "$@" ;;
        list) _tm_list "$@" ;;
        remove|delete) _tm_remove "$@" ;;
        reset-usage) _tm_reset_usage "$@" ;;
        edit-identity) _tm_edit_identity "$@" ;;
        port-in-use) _tm_port_in_use "$@" ;;
        clear-core) _tm_clear_core "$@" ;;
        purge) _tm_purge "$@" ;;
        restore) _tm_restore_transaction "$@" ;;
        check) _tm_check ;;
        probe) _tm_probe "$@" ;;
        install-schedule) _tm_install_schedule ;;
        remove-schedule) _tm_remove_schedule ;;
        cleanup) _tm_cleanup ;;
        acquire-lock) _tm_acquire_lock ;;
        release-lock) _tm_release_lock ;;
        parse-size) _tm_parse_size "$@" ;;
        format-bytes) _tm_format_bytes "$@" ;;
        *) _tm_usage; return 1 ;;
    esac
}

if [ "${TRAFFIC_MANAGER_LIB_ONLY:-0}" != 1 ]; then
    _tm_main "$@"
fi
