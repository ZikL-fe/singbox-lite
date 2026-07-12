#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export TRAFFIC_MANAGER_LIB_ONLY=1
source "${ROOT_DIR}/traffic_manager.sh"

failures=0

assert_eq() {
    local expected="$1" actual="$2" name="$3"
    if [ "$expected" != "$actual" ]; then
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"
        failures=$((failures + 1))
    else
        printf 'PASS: %s\n' "$name"
    fi
}

assert_eq 1073741824 "$(_tm_parse_size '1GB')" "parse GB"
assert_eq 1610612736 "$(_tm_parse_size '1.5 GB')" "parse decimal GB"
assert_eq 104857600 "$(_tm_parse_size '100mb')" "parse lowercase MB"
assert_eq "" "$(_tm_parse_size '0GB' 2>/dev/null || true)" "reject zero"
assert_eq "1.50 GB" "$(_tm_format_bytes 1610612736)" "format GB"

assert_eq 500 "$(_tm_counter_delta 1500 1000)" "normal counter delta"
assert_eq 200 "$(_tm_counter_delta 200 1000)" "counter reset delta"

assert_eq 29 "$(_tm_effective_reset_day 2028 2 31)" "leap-year month end"
assert_eq 28 "$(_tm_effective_reset_day 2027 2 31)" "ordinary February month end"
assert_eq 30 "$(_tm_effective_reset_day 2026 4 31)" "April month end"
assert_eq 15 "$(_tm_effective_reset_day 2026 4 15)" "ordinary reset day"
assert_eq "2026-02-28" "$(_tm_period_key 2026-03-01 31)" "period before March reset"
assert_eq "2026-03-31" "$(_tm_period_key 2026-03-31 31)" "period on reset boundary"

assert_eq true "$(_tm_is_exceeded 100 100)" "quota reached"
assert_eq false "$(_tm_is_exceeded 99 100)" "quota remains"

for required_function in _tm_ensure_singbox_api _tm_ensure_xray_api _tm_query_counters _tm_check _tm_install_schedule; do
    if ! declare -f "$required_function" >/dev/null 2>&1; then
        printf 'FAIL: required enforcement function missing: %s\n' "$required_function"
        failures=$((failures + 1))
    else
        printf 'PASS: enforcement function exists: %s\n' "$required_function"
    fi
done

if [ "$failures" -ne 0 ]; then
    printf '\n%d test(s) failed\n' "$failures"
    exit 1
fi

printf '\nAll traffic manager helper tests passed\n'
