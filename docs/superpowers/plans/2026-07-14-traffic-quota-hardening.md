# Traffic Quota Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make quota accounting, locking, identity edits, scheduling, deletion, and uninstall transactional and fail-safe for both Sing-box and Xray nodes.

**Architecture:** `traffic_manager.sh` remains the single owner of quota state and counter interpretation. Interactive scripts hold one exported owner lock across config, metadata, YAML, quota, and restart operations; manager CLI mutations either borrow that lock or acquire and release their own. Identity edits use a post-settlement checkpoint so rollback never loses the old tag's final traffic delta.

**Tech Stack:** Bash 4+, jq, temporary shell fixtures, Sing-box V2Ray statistics API, Xray StatsService, systemd/cron/OpenRC scheduling.

**Approved spec:** `docs/superpowers/specs/2026-07-14-singbox-shell-hardening-design.md`

**Execution order:** Complete this plan before `docs/superpowers/plans/2026-07-14-singbox-runtime-hardening.md`. Use `@superpowers:test-driven-development` for every behavior, `@superpowers:systematic-debugging` for unexpected failures, and `@superpowers:verification-before-completion` before claiming completion.

---

## File Map

- Create `tests/traffic_test_helpers.sh`: shared rootless fixture, fake cores, mode assertions, and state/config builders.
- Create `tests/test_traffic_atomic.sh`: state validation and permission-preserving atomic replacement.
- Create `tests/test_traffic_locking.sh`: owner/borrower/stale/contention/concurrency behavior.
- Create `tests/test_traffic_accounting.sh`: strict counters, reset, and monthly retry behavior.
- Create `tests/test_traffic_schedule.sh`: `set`, remove, purge, clear, and schedule rollback.
- Create `tests/test_traffic_identity.sh`: settlement and ordinary/Hysteria2 identity transactions.
- Create `tests/test_traffic_lifecycle.sh`: Sing-box, Xray, Argo, delete, and uninstall integration using fake files/services.
- Modify `tests/test_traffic_manager.sh`: pure numeric validation and query-contract coverage.
- Modify `tests/test_traffic_integration.sh`: shared fixtures and retained happy-path coverage.
- Modify `tests/test_port_validation.sh`: cross-core disabled-port reservation.
- Modify `traffic_manager.sh`: all quota primitives and command routing.
- Modify `singbox.sh`: parent lock, port/identity, Argo, uninstall, and client integration.
- Modify `xray_manager.sh`: parent lock and minimum create/delete/edit/uninstall hooks.
- Modify `README.md`: correct the Sing-box statistics-client requirement.

### Task 1: Build a deterministic rootless quota test harness

**Files:**
- Create: `tests/traffic_test_helpers.sh`
- Modify: `tests/test_traffic_integration.sh:1`

- [ ] **Step 1: Add the shared fixture without changing production behavior**

Create the helper with this public surface:

```bash
#!/usr/bin/env bash

TM_TEST_ROOT=""

tm_setup_fixture() {
    TM_TEST_ROOT=$(mktemp -d)
    export TM_DIR="$TM_TEST_ROOT/singbox"
    export TM_STATE_FILE="$TM_DIR/traffic_limits.json"
    export TM_SINGBOX_CONFIG="$TM_DIR/config.json"
    export TM_XRAY_CONFIG="$TM_TEST_ROOT/xray/config.json"
    export TM_CRON_FILE="$TM_TEST_ROOT/traffic.cron"
    export TM_LOCK_DIR="$TM_TEST_ROOT/traffic.lock"
    export TM_XRAY_BIN="$TM_TEST_ROOT/fake-xray"
    export TM_V2RAY_CLIENT_BIN="$TM_TEST_ROOT/fake-v2ray"
    export TM_SINGBOX_BIN="$TM_TEST_ROOT/fake-singbox"
    export TM_RESTART_SINGBOX_CMD="printf 'restart\\n' >> '$TM_TEST_ROOT/singbox.restart'"
    export TM_RESTART_XRAY_CMD="printf 'restart\\n' >> '$TM_TEST_ROOT/xray.restart'"
    mkdir -p "$TM_DIR" "$TM_TEST_ROOT/xray"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TM_XRAY_BIN"
    chmod +x "$TM_XRAY_BIN"
    cp "$TM_XRAY_BIN" "$TM_V2RAY_CLIENT_BIN"
    cp "$TM_XRAY_BIN" "$TM_SINGBOX_BIN"
}

tm_teardown_fixture() {
    [ -n "${TM_TEST_ROOT:-}" ] && rm -rf "$TM_TEST_ROOT"
}

tm_assert_eq() {
    [ "$1" = "$2" ] || {
        printf 'FAIL: %s\nexpected: %s\nactual: %s\n' "$3" "$1" "$2" >&2
        return 1
    }
}

tm_file_mode() {
    stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

tm_write_query() {
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\n' "$1" > "$TM_TEST_ROOT/query"
    chmod +x "$TM_TEST_ROOT/query"
    export TM_STATS_QUERY_CMD="$TM_TEST_ROOT/query"
}
```

Keep fixture functions source-safe and do not install an EXIT trap in the helper; each test owns cleanup.

- [ ] **Step 2: Refactor the existing integration test to use the helper**

Replace duplicated temp-path/fake-binary setup in `tests/test_traffic_integration.sh` while preserving every current assertion.

- [ ] **Step 3: Run the existing tests**

Run:

```bash
bash tests/test_traffic_manager.sh
bash tests/test_traffic_integration.sh
```

Expected: both exit `0`; no production file has changed yet.

- [ ] **Step 4: Commit the harness**

```bash
git add tests/traffic_test_helpers.sh tests/test_traffic_integration.sh
git commit -m "test: share traffic manager fixtures"
```

### Task 2: Validate numbers and preserve sensitive file metadata

**Files:**
- Create: `tests/test_traffic_atomic.sh`
- Modify: `tests/test_traffic_manager.sh:20`
- Modify: `traffic_manager.sh:10-161`

- [ ] **Step 1: Write failing numeric and state tests**

Add assertions covering:

```bash
safe_max=9007199254740991
tm_assert_eq "$safe_max" "$(_tm_validate_uint "$safe_max")" "accept safe maximum"
! _tm_validate_uint 9007199254740992
! _tm_validate_uint -1
! _tm_validate_uint 1.5
! _tm_parse_size 999999999999999999TB
```

In `tests/test_traffic_atomic.sh`, create these complete cases:

```bash
test_missing_state_is_private() {
    rm -f "$TM_STATE_FILE"
    _tm_init
    tm_assert_eq 600 "$(tm_file_mode "$TM_STATE_FILE")" "new state mode"
    jq -e 'type == "object" and length == 0' "$TM_STATE_FILE" >/dev/null
}

test_empty_state_is_rejected() {
    : > "$TM_STATE_FILE"
    ! _tm_init
    [ ! -s "$TM_STATE_FILE" ]
}

test_atomic_update_preserves_mode() {
    printf '%s\n' '{"singbox:node-a":{"core":"singbox","tag":"node-a","mode":"once","limit_bytes":100,"used_bytes":0,"reset_day":null,"period_key":null,"last_uplink":0,"last_downlink":0,"disabled":false}}' > "$TM_STATE_FILE"
    chmod 600 "$TM_STATE_FILE"
    _tm_atomic_jq '.["singbox:node-a"].used_bytes = 1'
    tm_assert_eq 600 "$(tm_file_mode "$TM_STATE_FILE")" "state mode preserved"
    jq -e '.["singbox:node-a"].used_bytes == 1' "$TM_STATE_FILE" >/dev/null
}
```

Add equivalent mode assertions around `_tm_ensure_singbox_api`, `_tm_ensure_xray_api`, `_tm_disable_node`, `_tm_restore_node`, cleanup, and restart rollback. A failed jq/validator must leave content, mode, uid, and gid unchanged and must not remove an unrelated `*.tmp` file.

- [ ] **Step 2: Run RED tests**

Run:

```bash
bash tests/test_traffic_manager.sh
bash tests/test_traffic_atomic.sh
```

Expected: failures for missing `_tm_validate_uint`, overflow acceptance, empty-state reset, and `600 -> 644` config replacement.

- [ ] **Step 3: Implement safe decimal validation**

Add this primitive before `_tm_parse_size` and use it before every Bash comparison/arithmetic or jq `tonumber`:

```bash
TM_MAX_SAFE_INTEGER=9007199254740991

_tm_validate_uint() {
    local value="${1:-}" normalized
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    normalized="$value"
    while [ "${#normalized}" -gt 1 ] && [[ "$normalized" == 0* ]]; do
        normalized="${normalized#0}"
    done
    if [ "${#normalized}" -gt "${#TM_MAX_SAFE_INTEGER}" ] ||
       { [ "${#normalized}" -eq "${#TM_MAX_SAFE_INTEGER}" ] && [[ "$normalized" > "$TM_MAX_SAFE_INTEGER" ]]; }; then
        return 1
    fi
    printf '%s' "$normalized"
}

_tm_validate_positive_uint() {
    local value
    value=$(_tm_validate_uint "${1:-}") || return 1
    [ "$value" != 0 ] || return 1
    printf '%s' "$value"
}
```

Run same-length lexical comparison under `LC_ALL=C` locally inside the validator. Make `_tm_parse_size` validate its computed result, make `_tm_counter_delta` fail for invalid counters, and make `_tm_is_exceeded` return nonzero rather than printing a false answer for invalid input.

- [ ] **Step 4: Implement one permission-preserving JSON replacement primitive**

Add `_tm_atomic_json <file> <filter> <validator-function> [jq args...]`:

```bash
_tm_atomic_json() {
    local file="$1" filter="$2" validator="$3" tmp
    shift 3
    [ -f "$file" ] || return 1
    tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
    cp -p "$file" "$tmp" || { rm -f "$tmp"; return 1; }
    if ! jq "$@" "$filter" "$file" > "$tmp" ||
       ! jq empty "$tmp" >/dev/null 2>&1 ||
       ! "$validator" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$file"; then
        rm -f "$tmp"
        return 1
    fi
}
```

Provide `_tm_validate_state_candidate`, `_tm_validate_singbox_candidate`, and
`_tm_validate_xray_candidate` wrappers. The core wrappers call
`_tm_validate_config <core> <candidate>` before rename; the state wrapper checks
the full state schema. Use `:` only for JSON files that have no stronger
validator. Make `_tm_atomic_jq` delegate to it for `TM_STATE_FILE`. Convert every
config replacement in `_tm_ensure_*_api`, `_tm_disable_node`,
`_tm_restore_node`, `_tm_cleanup`, and rollback helpers to the same primitive.
Create missing state with a same-directory `mktemp`, `umask 077`, and atomic
rename. Existing empty/invalid state must return nonzero. Validate record
numeric fields with jq before accepting state.

- [ ] **Step 5: Run GREEN tests and existing integration**

```bash
bash tests/test_traffic_manager.sh
bash tests/test_traffic_atomic.sh
bash tests/test_traffic_integration.sh
```

Expected: all exit `0`; mode assertions remain stable.

- [ ] **Step 6: Commit**

```bash
git add traffic_manager.sh tests/test_traffic_manager.sh tests/test_traffic_atomic.sh
git commit -m "fix: validate and preserve quota state"
```

### Task 3: Enforce a strict counter and probe contract

**Files:**
- Modify: `traffic_manager.sh:338-365,463-485`
- Modify: `tests/test_traffic_manager.sh`
- Create: `tests/test_traffic_accounting.sh`

- [ ] **Step 1: Write failing counter tests**

Test injected responses with a table loop:

```bash
for invalid in '' $'0\n0' $'0\n0\n0\n0' $'nope\n0\n0' $'-1\n0\n-1' $'9007199254740992\n0\n0'; do
    tm_write_query "$invalid"
    ! _tm_query_counters singbox node-a
done
```

Create fake built-in clients returning `{}`, malformed JSON, one direction only, and both directions with numeric strings. Assert `_tm_probe` rejects the first three and returns zero only for the complete response. Assert `_tm_check` increments `stats_failures`, sets `last_error`, and preserves usage/baselines for invalid output.

Extract `_traffic_show_line` in a focused main-script fixture. Feed status with
nonzero `last_uplink`/`last_downlink` and assert the rendered line says
`当前核心计数` before `上行`/`下行`; it must not present those baselines as the
node's accumulated directional totals.

- [ ] **Step 2: Run RED tests**

```bash
bash tests/test_traffic_manager.sh
bash tests/test_traffic_accounting.sh
```

Expected: `{}` currently produces `0/0/0` and probe incorrectly succeeds.

- [ ] **Step 3: Normalize all counter sources**

Add `_tm_validate_counter_output` that reads exactly three lines, validates each with `_tm_validate_uint`, verifies `total == uplink + downlink`, and prints normalized values. Route `TM_STATS_QUERY_CMD` through it.

For built-in clients, use one jq program to collect matching uplink and downlink
arrays. Validate every raw member value as an integer in
`0..9007199254740991` before aggregation, then require both arrays to be
non-empty and require each aggregate and their total to remain in range. A
negative and positive member must not be allowed to cancel into a valid-looking
sum. Emit the three-line contract and then run the same shell validator. Do not
use `add // 0` for an empty match.

Move `_tm_check`'s `stats_failures=0`/`last_error=null` update until after output validation and array assignment succeed.

Update `_traffic_show_line` so the baseline line is explicitly labeled, for
example `当前核心计数: 上行 ... | 下行 ...`. Keep `used_bytes / limit_bytes`
as the only accumulated quota total.

- [ ] **Step 4: Run GREEN tests**

```bash
bash tests/test_traffic_manager.sh
bash tests/test_traffic_accounting.sh
bash tests/test_traffic_integration.sh
```

- [ ] **Step 5: Commit**

```bash
git add traffic_manager.sh tests/test_traffic_manager.sh tests/test_traffic_accounting.sh
git commit -m "fix: reject incomplete traffic counters"
```

### Task 4: Make lock ownership safe and mutation commands self-locking

**Files:**
- Create: `tests/test_traffic_locking.sh`
- Modify: `traffic_manager.sh:301-314,445-503,582-606`
- Modify: `singbox.sh:91-100`
- Modify: `xray_manager.sh:137-144`

- [ ] **Step 1: Write failing ownership and concurrency tests**

Cover these exact outcomes:

```text
parent owner acquire -> child mutation borrows -> lock still exists
wrong owner release -> nonzero -> lock still exists
direct mutation -> own lock removed on return
dead PID lock -> reclaimed
busy mutation -> nonzero
busy scheduled check -> zero without mutation
two serialized set/purge operations -> neither state update is lost
```

Use a FIFO or ready/release files in a fake validator to pause process A deterministically while process B observes contention; never use arbitrary long sleeps.

- [ ] **Step 2: Run RED test**

```bash
bash tests/test_traffic_locking.sh
```

Expected: wrong owner can currently delete the lock, mutation CLI commands do not self-lock, and a borrowed lock is not distinguished from an owned lock.

- [ ] **Step 3: Implement owned/borrowed locking**

Make `_tm_acquire_lock` set process-local `TM_LOCK_ACQUIRED=true|false` and `TM_LOCK_BORROWED=true|false`. A matching existing owner is borrowed. `_tm_release_lock` reads the recorded PID and refuses removal unless it matches `${TM_LOCK_OWNER_PID:-$$}`.

Add `_tm_run_locked function args...` that releases only when this process created the lock:

```bash
_tm_run_locked() {
    local fn="$1" rc
    shift
    _tm_acquire_lock || return 1
    "$fn" "$@"; rc=$?
    [ "${TM_LOCK_ACQUIRED:-false}" = true ] && _tm_release_lock || true
    return "$rc"
}
```

Route every mutating CLI command (`init`, `set`, `remove/delete`,
`reset-usage`, `edit-identity`, `clear-core`, `purge`, `restore`,
`install-schedule`, `remove-schedule`, and `cleanup`) through it. Keep only
`status`, `list`, `port-in-use`, `probe`, `parse-size`, and `format-bytes`
unlocked. Keep `acquire-lock`/`release-lock` as explicit owner operations and
keep `_tm_check`'s special busy-is-success behavior.

In both interactive wrappers, `export TM_LOCK_OWNER_PID=$$` before acquire, maintain a same-shell nesting depth, release only at depth zero, and unset the export after release so every child manager command sees the parent owner.

- [ ] **Step 4: Run GREEN and integration tests**

```bash
bash tests/test_traffic_locking.sh
bash tests/test_traffic_integration.sh
```

- [ ] **Step 5: Commit**

```bash
git add traffic_manager.sh singbox.sh xray_manager.sh tests/test_traffic_locking.sh
git commit -m "fix: serialize quota mutations"
```

### Task 5: Correct active reset and disabled restore baselines

**Files:**
- Modify: `traffic_manager.sh:239-272,420-443`
- Modify: `tests/test_traffic_accounting.sh`

- [ ] **Step 1: Write failing reset tests**

Create active state with `used=500`, baselines `100/100`, and query `2000/1200/800`. After `reset-usage`, assert `used=0`, baselines `1200/800`; a second check with the same counters must leave usage zero. Query failure must preserve the full record byte-for-byte.

Create a disabled record with saved inbound. Successful reset must restore/restart it with zero baselines. A failed restart must restore disabled config and the original record.

Inject a failure into the state update that sets `used_bytes=0` after restore
transformation. Assert the node remains disabled, its saved inbound and original
usage remain, active config is unchanged, and no successful restart is reported.

- [ ] **Step 2: Verify RED**

```bash
bash tests/test_traffic_accounting.sh
```

Expected: current active reset writes `0/0`, then re-adds `2000` bytes.

- [ ] **Step 3: Implement separate active/disabled paths**

For active nodes, query first and perform one atomic state update with current
directional baselines. For disabled nodes, extend `_tm_restore_transaction` (or
add a dedicated reset transaction) so restore transformation and the
`used_bytes=0`/zero-baseline state update are both staged before restart. Keep
the original config and state snapshot until both writes and the restart
succeed. Any state-write or restart failure restores the disabled config and
entire original record, restarting the old core only if candidate config had
already been started. Propagate every failure.

- [ ] **Step 4: Verify GREEN**

```bash
bash tests/test_traffic_accounting.sh
bash tests/test_traffic_integration.sh
```

- [ ] **Step 5: Commit**

```bash
git add traffic_manager.sh tests/test_traffic_accounting.sh
git commit -m "fix: reset quota counter baselines"
```

### Task 6: Retry failed monthly restores without rolling back independent work

**Files:**
- Modify: `traffic_manager.sh:445-503`
- Modify: `tests/test_traffic_accounting.sh`

- [ ] **Step 1: Write failing monthly retry tests**

Add fixtures for:

- saved node restore blocked by an occupied port;
- config validator failure;
- affected-core restart failure;
- active monthly rollover with malformed/incomplete counters;
- one failed restore plus an independent active record whose valid usage must persist;
- multiple successful changes for one core causing exactly one restart.

For every failed restore, assert old `period_key`, `used_bytes`, disabled flag, saved inbound, and config remain; assert `last_error` is retryable and the next check attempts restore again.

For invalid counters during an active-node rollover, assert period, usage, and
baselines remain unchanged; `stats_failures` increments, `last_error` remains
visible, and the overall check returns nonzero. It must not silently skip the
rollover or clear a previous error.

- [ ] **Step 2: Verify RED**

```bash
bash tests/test_traffic_accounting.sh
```

Expected: current code advances the period after `_tm_restore_node` failure and returns success.

- [ ] **Step 3: Implement staged per-core checkpoints**

Do not update period/usage until restore transformation succeeds. Route active
rollover queries through the same strict counter/error helper as ordinary
checks; invalid output sets `check_failed` and leaves the rollover pending.
Track `check_failed`, `changed_singbox`, and `changed_xray`. Snapshot each
affected core's config and relevant post-query state before its first mutation.
Restart each changed core once. If one core restart fails, restore that core's
checkpoint and retry its old config; do not discard already committed
independent state from the other core. Record failure and return nonzero after
processing.

- [ ] **Step 4: Verify GREEN**

```bash
bash tests/test_traffic_accounting.sh
bash tests/test_traffic_integration.sh
```

- [ ] **Step 5: Commit**

```bash
git add traffic_manager.sh tests/test_traffic_accounting.sh
git commit -m "fix: retry monthly quota restoration"
```

### Task 7: Make schedule lifecycle transactional

**Files:**
- Create: `tests/test_traffic_schedule.sh`
- Modify: `traffic_manager.sh:165-212,253-299,505-551`

- [ ] **Step 1: Write failing schedule tests**

Cover:

```text
first set + schedule failure -> original state/config restored, no schedule
set with pre-existing schedule + failure -> existing schedule preserved
purge one of two records -> exit 0, schedule remains
clear Sing-box while Xray remains -> schedule remains
clear final core -> schedule removed
remove final record -> schedule removed
```

Use only `TM_CRON_FILE` locally. Add injectable systemd/OpenRC command/path seams only where needed for Linux integration; do not write `/etc` in tests.

- [ ] **Step 2: Verify RED**

```bash
bash tests/test_traffic_schedule.sh
```

Expected: `set` leaves state on schedule failure, `purge` returns `1`, and `clear-core` leaves the final schedule.

- [ ] **Step 3: Keep transaction snapshots through schedule success**

Record entry state/config and whether a schedule existed. On any failure, restore content and metadata, restart the restored core if candidate config was started, and remove only schedule artifacts created by this attempt. Make `_tm_purge`, `_tm_remove`, and `_tm_clear_core` explicitly return zero after successful state deletion; centralize the `state length == 0` schedule decision.

- [ ] **Step 4: Verify GREEN**

```bash
bash tests/test_traffic_schedule.sh
bash tests/test_traffic_integration.sh
```

- [ ] **Step 5: Commit**

```bash
git add traffic_manager.sh tests/test_traffic_schedule.sh
git commit -m "fix: roll back quota schedule failures"
```

### Task 8: Settle usage and make identity edits two-phase

**Files:**
- Create: `tests/test_traffic_identity.sh`
- Modify: `traffic_manager.sh:274-280,320-326,582-606`

- [ ] **Step 1: Write failing manager identity tests**

Test:

- `settle-usage` adds the old tag's final delta exactly once;
- ordinary rename replaces only the old primary stats member;
- Hysteria2 rename replaces primary and every `-hop-<port>` member while preserving unrelated members;
- identity prepare failure leaves state/config unchanged;
- rollback before core restart restores the old key with settled baselines;
- rollback after old config is restarted preserves settled `used_bytes` but zeros old baselines.

- [ ] **Step 2: Verify RED**

```bash
bash tests/test_traffic_identity.sh
```

Expected: `settle-usage` is missing and current `edit-identity` never changes stats membership.

- [ ] **Step 3: Implement settlement and provisional identity mutation**

Add `settle-usage <core> <tag>` using the same delta logic as `_tm_check`. It is idempotent for unchanged counters and is a mutating locked CLI command.

Change `edit-identity` so the caller invokes it after settlement but before candidate restart. In one rollback-capable operation it:

- renames the quota key/tag/member pattern;
- updates saved primary tag/port when present;
- resets the provisional new baselines to zero;
- for Sing-box, replaces old primary/helper entries in `experimental.v2ray_api.stats.inbounds` with the actual new config members;
- validates state and candidate config and propagates failure.

The interactive caller, not the manager, owns the post-settlement checkpoint and decides whether rollback uses settled baselines (no restart occurred) or zero baselines (old config was restarted).

- [ ] **Step 4: Verify GREEN**

```bash
bash tests/test_traffic_identity.sh
bash tests/test_traffic_integration.sh
```

- [ ] **Step 5: Commit**

```bash
git add traffic_manager.sh tests/test_traffic_identity.sh
git commit -m "fix: preserve quota identity accounting"
```

### Task 9: Integrate identity, locking, Argo, Xray, and uninstall lifecycles

**Files:**
- Create: `tests/test_traffic_lifecycle.sh`
- Modify: `tests/test_port_validation.sh`
- Modify: `singbox.sh:425-452,1213-1509,1581-1646,1905-1972,2203-2298,4577-5129,5912-6183`
- Modify: `xray_manager.sh:100-144,569-600,1310-1470`

- [ ] **Step 1: Add source-safe test seams and failing lifecycle tests**

Guard bottom-level menu execution with `SINGBOX_LIB_ONLY=1` and `XRAY_MANAGER_LIB_ONLY=1`, without skipping function definitions. In the test, override all live paths and service commands before invoking extracted prompt-free helpers.

Add cross-core port test: a fake manager returns success only for `port-in-use xray 2443`; `_check_port_conflict 2443` must reject it.

Add active/disabled ordinary and Hysteria2 port edit fixtures that assert settlement call order, stats membership, metadata/YAML/cert/helper updates, restart, state commit, and both rollback variants.

Add active/disabled Argo delete and Argo uninstall fixtures. After purge and a simulated future monthly check, no tag may reappear.

Add an Argo creation fixture that pauses the config mutation, attempts a
scheduled check, and proves the parent owner lock remains held through config,
metadata/YAML, quota prompt, service restart, and compatibility probe. A failed
create must release the lock without leaving a quota record.

Add Xray create/delete/delete-all/port-edit/uninstall fixtures asserting the parent lock spans all writes and manager failures are not suppressed.

Add main uninstall fixture asserting manager cleanup runs while its script/config still exist and before `$SINGBOX_DIR` removal.

Make the fake manager's `cleanup` return nonzero and assert uninstall aborts
before removing Sing-box or Xray directories, schedule artifacts, or the
manager. It must return nonzero and print no uninstall-success message, leaving
the files available for a retry.

Add ordinary Sing-box deletion fixtures for one active limited node and for
delete-all. Force `purge`/`clear-core` failure after config, metadata, and YAML
candidate mutations. Assert the operation returns nonzero, restores every file
and active service, retains the quota record, and prints no success message.
Also cover the successful paths and final-schedule removal.

- [ ] **Step 2: Verify RED**

```bash
bash tests/test_port_validation.sh
bash tests/test_traffic_lifecycle.sh
```

- [ ] **Step 3: Implement Sing-box transaction helpers**

Extract prompt-free `_apply_singbox_port_identity_edit`. Under the parent lock:

1. call `settle-usage` and copy the post-settlement state checkpoint;
2. validate the requested port after settlement, against OS sockets,
   active configs, and both cores' disabled reservations;
3. provisionally call `edit-identity` before changing node config;
4. update config/metadata/YAML/certs/Hysteria2 helpers/nftables;
5. validate and restart;
6. on pre-restart failure restore old files plus the post-settlement state;
7. on post-restart failure restore/restart old config, retain settled usage, and zero old baselines;
8. print success only after the whole transaction succeeds.

Settlement must remain durable even when new-port validation rejects the edit.

Make single, batch, and Argo node creation acquire the same parent lock across
config write, metadata/YAML, quota prompt, restart, and probe.

Refactor ordinary single deletion and delete-all into rollback-capable parent
transactions. Snapshot config, metadata, YAML, certificates, and post-settlement
quota state before destructive writes. Treat `purge` and `clear-core` as
required operations: remove `2>/dev/null || true`, propagate failure, restore
all snapshots, and restart the restored service when the candidate config had
been started. Announce success only after manager state and schedule cleanup
both succeed.

- [ ] **Step 4: Implement Argo and Xray lifecycle hooks**

Extract `_delete_argo_tag` shared by menu deletion, disabled-node deletion, and uninstall. Always use `purge`, never `remove/delete`, so a disabled inbound is not temporarily restored. Purge before metadata is discarded.

Apply the same two-phase settlement pattern to `_apply_xray_port_identity_edit`. Make Xray create/delete/delete-all/uninstall use the exported parent lock. Remove `2>/dev/null || true` from required manager mutations and abort/rollback on failure.

- [ ] **Step 5: Fix main uninstall ordering**

Run manager `cleanup` as a required operation before deleting Sing-box/Xray
config directories. If cleanup fails, abort uninstall and retain the manager and
both config directories so the user can retry; never suppress this status.
After successful cleanup, release the parent lock before deleting the
manager/lock path. Remove the legacy `/usr/local/bin/v2ray-api` artifact during
idempotent cleanup.

- [ ] **Step 6: Verify GREEN**

```bash
bash tests/test_port_validation.sh
bash tests/test_traffic_lifecycle.sh
bash tests/test_traffic_identity.sh
bash tests/test_traffic_locking.sh
bash tests/test_traffic_integration.sh
```

- [ ] **Step 7: Commit**

```bash
git add singbox.sh xray_manager.sh traffic_manager.sh tests/test_port_validation.sh tests/test_traffic_lifecycle.sh
git commit -m "fix: close node quota lifecycles"
```

### Task 10: Consolidate the statistics client and verify the quota plan

**Files:**
- Modify: `singbox.sh:2335-2411,5217-5263`
- Modify: `traffic_manager.sh:7-8,116-148,553-568`
- Modify: `tests/test_singbox_helpers.sh`
- Modify: `README.md:27-42`

- [ ] **Step 1: Add failing static/lifecycle assertions**

Assert the duplicate `_install_v2ray_api_client` function and eager
`_do_update_singbox` call are absent, the manager still maps
`x86_64 -> v2ray-linux-64`, `aarch64 -> arm64-v8a`, and
`armv7l -> arm32-v7a`, and checksum failure leaves no destination executable.
Add downloader fixtures proving:

```text
archive/checksum/extract failure -> existing destination byte-identical
candidate chmod failure          -> existing destination byte-identical
candidate version failure        -> existing destination byte-identical
successful install               -> candidate built beside destination, then atomic rename
```

Assert no `${destination}.tmp.*` remains. Allow `/usr/local/bin/v2ray-api` only
as a legacy uninstall cleanup target.

- [ ] **Step 2: Verify RED**

```bash
bash tests/test_singbox_helpers.sh
```

- [ ] **Step 3: Remove duplicate installation and correct documentation**

Delete the main-script installer and eager call. Harden
`_tm_download_verified_client`: download/check/extract in its private archive
directory, then create a unique candidate with `mktemp` in
`dirname "$destination"`, copy the extracted binary into it, `chmod +x`, and
run its version command before `mv` atomically replaces the destination. Any
failure removes the candidate and preserves a working destination. Apply the
same installation primitive to both V2Ray and Xray CLI-only clients.

Keep the manager's checksum-verified lazy installation under
`/usr/local/lib/singbox-lite`. Update README to state that enabling the first
Sing-box quota installs a CLI-only V2Ray client and does not require an
installed/running Xray service.

- [ ] **Step 4: Run the complete quota verification**

```bash
bash -n singbox.sh traffic_manager.sh xray_manager.sh advanced_relay.sh parser.sh tests/*.sh
bash tests/test_port_validation.sh
bash tests/test_singbox_helpers.sh
bash tests/test_traffic_manager.sh
bash tests/test_traffic_atomic.sh
bash tests/test_traffic_locking.sh
bash tests/test_traffic_accounting.sh
bash tests/test_traffic_schedule.sh
bash tests/test_traffic_identity.sh
bash tests/test_traffic_lifecycle.sh
bash tests/test_traffic_integration.sh
git diff --check
```

Expected: every command exits `0`; no test writes outside its temporary directory.

- [ ] **Step 5: Inspect security and scope**

```bash
git status --short
git diff --stat
git diff -- singbox.sh traffic_manager.sh xray_manager.sh README.md tests
```

Expected: only planned files changed; `.agent/` remains untracked and unstaged; no secret/share-link fixture contains live credentials.

- [ ] **Step 6: Commit**

```bash
git add singbox.sh traffic_manager.sh tests/test_singbox_helpers.sh README.md
git commit -m "fix: use one verified stats client"
```

## Linux Integration Gate

After local tests, use a disposable supported Linux host if available:

```bash
sudo bash traffic_manager.sh install-schedule
sudo bash traffic_manager.sh set singbox <test-tag> once 104857600
sudo bash traffic_manager.sh probe singbox <test-tag>
sudo bash traffic_manager.sh check
```

Validate real Sing-box and Xray configs, systemd or OpenRC schedule creation,
disable/reset/restore, one restart per changed core, and mode/owner preservation
for root-owned files. If no Linux runtime is available, record this as an
unverified integration gate; do not claim it passed from macOS fixtures.
