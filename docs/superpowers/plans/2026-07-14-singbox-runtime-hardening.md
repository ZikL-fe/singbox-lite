# Singbox Runtime Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the confirmed local-secret, partial-download, direct-service, and successful-build cleanup hazards from `singbox.sh`.

**Architecture:** Keep the existing single-script structure, but introduce small testable helpers for sensitive temporary files, atomic executable installation, and direct-process verification. Every helper uses a unique same-directory or `${TMPDIR}` path, preserves an existing working target on failure, and propagates a nonzero status to its caller.

**Tech Stack:** Bash 4+, jq, mktemp, curl/wget, fake shell binaries, standalone rootless shell tests.

**Approved spec:** `docs/superpowers/specs/2026-07-14-singbox-shell-hardening-design.md`

**Execution order:** Run after `docs/superpowers/plans/2026-07-14-traffic-quota-hardening.md`. Use `@superpowers:test-driven-development`, `@superpowers:systematic-debugging`, and `@superpowers:verification-before-completion`.

---

## File Map

- Create `tests/test_singbox_security.sh`: main JSON modes, unique link cache, symlink resistance, and validated executable downloads.
- Create `tests/test_singbox_runtime.sh`: direct start/restart and build-directory cleanup.
- Modify `tests/test_singbox_helpers.sh`: source/contract assertions retained from the quota plan.
- Modify `singbox.sh`: atomic JSON, link cache, download helper, direct service management, and build cleanup.

### Task 1: Preserve main config permissions and use a private link cache

**Files:**
- Create: `tests/test_singbox_security.sh`
- Modify: `singbox.sh:716-735,852-877,4375-4575`

- [ ] **Step 1: Write failing atomic JSON tests**

Use the `SINGBOX_LIB_ONLY=1` seam added by the quota plan. Override every path to a temporary directory before invoking helpers. Add:

```bash
test_main_json_update_preserves_mode() {
    local config="$TEST_ROOT/config.json"
    printf '{}\n' > "$config"
    chmod 600 "$config"
    _atomic_modify_json "$config" '.ok = true'
    assert_eq 600 "$(file_mode "$config")" "main config mode"
    jq -e '.ok == true' "$config" >/dev/null
}

test_main_json_failure_preserves_target() {
    local config="$TEST_ROOT/config.json" before
    printf '{"secret":"kept"}\n' > "$config"
    chmod 600 "$config"
    before=$(shasum -a 256 "$config" | awk '{print $1}')
    ! _atomic_modify_json "$config" 'invalid('
    assert_eq "$before" "$(shasum -a 256 "$config" | awk '{print $1}')" "failed update content"
    assert_eq 600 "$(file_mode "$config")" "failed update mode"
}
```

Add a concurrent fixture in which two processes use different temp files; a failure may remove only its own file, never another `config.json.tmp.*` sentinel.

- [ ] **Step 2: Write failing private-cache tests**

Required complete behaviors:

```text
cache path starts with overridden TMPDIR
cache mode is 0600
two processes receive different paths
legacy /tmp/singbox_links.tmp symlink and its victim are untouched
explicit cleanup removes only the generated cache
EXIT cleanup removes the generated cache after a subprocess exits
no literal /tmp/singbox_links.tmp remains in singbox.sh
```

The test must use dummy `vless://fixture` strings, never real node credentials.

- [ ] **Step 3: Run RED test**

```bash
bash tests/test_singbox_security.sh
```

Expected: main JSON mode changes to `644`, cache helpers are missing, and the source still contains the predictable path.

- [ ] **Step 4: Replace main atomic JSON with a unique metadata-preserving write**

Implement the same pattern used by the repaired manager:

```bash
_atomic_modify_json() {
    local file="$1" filter="$2" tmp
    [ -f "$file" ] || return 1
    tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
    cp -p "$file" "$tmp" || { rm -f "$tmp"; return 1; }
    if ! jq "$filter" "$file" > "$tmp" || ! jq empty "$tmp" >/dev/null 2>&1; then
        _error "修改JSON失败: $file"
        rm -f "$tmp"
        return 1
    fi
    if ! mv "$tmp" "$file"; then
        rm -f "$tmp"
        return 1
    fi
}
```

Use unique backups for `_atomic_modify_yaml` as well. Keep in-place yq behavior only if tests prove content/mode rollback; otherwise write to a copied candidate and atomically rename it.

- [ ] **Step 5: Add exact link-cache ownership**

Add process-local `LINK_CACHE_FILE=""` and:

```bash
_create_link_cache() {
    local tmp_root="${TMPDIR:-/tmp}"
    [ -d "$tmp_root" ] || return 1
    _cleanup_link_cache
    LINK_CACHE_FILE=$(mktemp "${tmp_root%/}/singbox-links.XXXXXX") || return 1
    chmod 600 "$LINK_CACHE_FILE" || { rm -f "$LINK_CACHE_FILE"; LINK_CACHE_FILE=""; return 1; }
}

_cleanup_link_cache() {
    if [ -n "${LINK_CACHE_FILE:-}" ] && [ -f "$LINK_CACHE_FILE" ]; then
        rm -f -- "$LINK_CACHE_FILE"
    fi
    LINK_CACHE_FILE=""
}

_cleanup_runtime_files() {
    _cleanup_link_cache
}
```

Register one EXIT trap for `_cleanup_runtime_files`; remove the broad `${SINGBOX_DIR}/*.tmp` and fixed link-cache deletion. `_view_nodes` creates the cache before its pipeline, appends with `printf '%s\n' "$url" >> "$LINK_CACHE_FILE"`, reads only when `-s`, and explicitly cleans after the Base64 prompt. Quote every use.

- [ ] **Step 6: Run GREEN test and syntax check**

```bash
bash tests/test_singbox_security.sh
bash -n singbox.sh
```

- [ ] **Step 7: Commit**

```bash
git add singbox.sh tests/test_singbox_security.sh
git commit -m "fix: protect local node credentials"
```

### Task 2: Install yq atomically and propagate dependency failure

**Files:**
- Modify: `singbox.sh:842-950`
- Modify: `tests/test_singbox_security.sh`

- [ ] **Step 1: Write failing yq download tests**

Use a temporary `YQ_BINARY`, fake downloader directory prepended to `PATH`, and fake version scripts. Cover:

1. downloader writes seven bytes then exits `8`;
2. downloader succeeds with a sufficiently large non-executable payload;
3. candidate executes but `--version` exits nonzero;
4. valid padded candidate prints `yq fixture-version`;
5. an existing destination prints `old-version`.

For cases 1-3, fresh install must leave no destination and an existing destination must remain byte-identical. Case 4 atomically replaces/installs and leaves no candidate. `_install_dependencies` must not write `dependencies.ok` after yq failure.

- [ ] **Step 2: Run RED test**

```bash
bash tests/test_singbox_security.sh
```

Expected: current `_install_yq` returns zero and leaves an executable partial file.

- [ ] **Step 3: Add one atomic executable downloader**

Add before `_install_yq`:

```bash
_download_executable() {
    local url="$1" destination="$2" label="$3" min_bytes="${4:-1048576}"
    local tmp size
    mkdir -p "$(dirname "$destination")" || return 1
    tmp=$(mktemp "${destination}.tmp.XXXXXX") || return 1
    if command -v curl >/dev/null 2>&1; then
        curl -LfsS "$url" -o "$tmp" || { rm -f "$tmp"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$url" -O "$tmp" || { rm -f "$tmp"; return 1; }
    else
        rm -f "$tmp"
        return 1
    fi
    size=$(stat -f '%z' "$tmp" 2>/dev/null || stat -c '%s' "$tmp" 2>/dev/null) || {
        rm -f "$tmp"; return 1;
    }
    [ "$size" -ge "$min_bytes" ] || { rm -f "$tmp"; return 1; }
    chmod +x "$tmp" || { rm -f "$tmp"; return 1; }
    "$tmp" --version >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$destination" || { rm -f "$tmp"; return 1; }
    _success "$label 安装成功"
}
```

The helper never truncates or removes an existing destination before validation. `_install_yq` selects the existing architecture URL and calls the helper. It accepts an existing yq only when `-x` and `--version` both succeed. `_install_dependencies` checks the return status and writes `DEP_STATE_FILE` only after all required tools validate.

- [ ] **Step 4: Run GREEN test**

```bash
bash tests/test_singbox_security.sh
```

- [ ] **Step 5: Commit**

```bash
git add singbox.sh tests/test_singbox_security.sh
git commit -m "fix: install yq atomically"
```

### Task 3: Install cloudflared atomically

**Files:**
- Modify: `singbox.sh:1033-1058`
- Modify: `tests/test_singbox_security.sh`

- [ ] **Step 1: Write failing cloudflared tests**

Reuse the exact partial/invalid/valid/existing destination fixtures from Task 2 with a temporary `CLOUDFLARED_BIN`. Assert an existing plain file no longer counts as installed; only an executable whose `--version` succeeds may short-circuit.

- [ ] **Step 2: Verify RED**

```bash
bash tests/test_singbox_security.sh
```

Expected: current function accepts any existing file and a failed download can leave a partial target.

- [ ] **Step 3: Route cloudflared through `_download_executable`**

Keep the current architecture map and direct GitHub release URL. Propagate `ca-certificates` installation failure. Print the candidate's version only after atomic installation succeeds.

- [ ] **Step 4: Verify GREEN and commit**

```bash
bash tests/test_singbox_security.sh
git add singbox.sh tests/test_singbox_security.sh
git commit -m "fix: install cloudflared atomically"
```

### Task 4: Propagate direct-mode process failures

**Files:**
- Create: `tests/test_singbox_runtime.sh`
- Modify: `singbox.sh:621-690`

- [ ] **Step 1: Write failing direct-service tests**

Source the main script in library mode with temporary config, relay, log, and PID paths. Provide:

```bash
immediate_exit="$TEST_ROOT/false-singbox"
printf '#!/usr/bin/env bash\nexit 23\n' > "$immediate_exit"

long_running="$TEST_ROOT/live-singbox"
printf '#!/usr/bin/env bash\ntrap "exit 0" TERM INT\nwhile :; do sleep 1; done\n' > "$long_running"
chmod +x "$immediate_exit" "$long_running"
```

Set `INIT_SYSTEM=direct` and an injectable `SINGBOX_START_VERIFY_DELAY=0.05`. Assert:

- immediate `start` and `restart` return nonzero;
- stale PID file is removed;
- captured stderr contains no success line;
- live `start`, `status`, `stop`, and `restart` return zero;
- a fake `kill` that succeeds for `-0` but fails termination makes `stop` fail
  and retain the PID file;
- a PID file in a non-writable fixture directory makes cleanup failure visible;
- restart propagates stop or start failure;
- unsupported init/action returns nonzero.

Test cleanup must terminate only the fixture PID.

- [ ] **Step 2: Verify RED**

```bash
bash tests/test_singbox_runtime.sh
```

Expected: immediate-exit start currently returns zero and prints success.

- [ ] **Step 3: Verify the expected process before success**

After writing `$!`, wait `${SINGBOX_START_VERIFY_DELAY:-1}` and require `_is_pid_file_running_cmd "$PID_FILE" "$SINGBOX_BIN"`. On failure, remove the PID file, print `_error`, and return nonzero.

For `stop`, if the recorded PID matches the expected binary, require `kill` to
succeed and poll for exit up to `${SINGBOX_STOP_VERIFY_ATTEMPTS:-20}` iterations
with `${SINGBOX_STOP_VERIFY_DELAY:-0.1}` between checks. If termination fails or
the process remains alive, return nonzero and retain the PID file for diagnosis.
If the process is gone or the PID was stale, require PID-file removal to
succeed. Print success only afterward. The test may shadow Bash's `kill`
function so `kill -0` delegates to `builtin kill` while the terminating call
returns a fixture failure.

Make restart use:

```bash
_manage_service stop || return 1
sleep "${SINGBOX_RESTART_DELAY:-1}"
_manage_service start
```

Return explicit nonzero status from unsupported init systems and actions. Do not print success until command success is known.

- [ ] **Step 4: Verify GREEN**

```bash
bash tests/test_singbox_runtime.sh
bash -n singbox.sh
```

- [ ] **Step 5: Commit**

```bash
git add singbox.sh tests/test_singbox_runtime.sh
git commit -m "fix: report direct service start failures"
```

### Task 5: Remove successful Sing-box build directories

**Files:**
- Modify: `singbox.sh:978-1031`
- Modify: `tests/test_singbox_runtime.sh`

- [ ] **Step 1: Write failing build cleanup tests**

Use existing `SINGBOX_BUILD_PARENT` and `SINGBOX_BUILD_CACHE` seams and temporary install/config paths. Fake:

- `curl` returning `{"tag_name":"v1.2.3"}`;
- `git clone` creating the requested source directory;
- `go build` parsing `-o`, writing an executable that reports `Tags: with_v2ray_api`, and returning success;
- candidate `check` returning zero.

Create a neighboring directory and a cache sentinel. After success assert installed binary exists, no `singbox-lite-build.*` remains, neighbor/cache remain.

Add a failure table for every stage after `build_root` exists:

```text
git clone failure                 -> build root removed
go-tmp directory creation failure -> build root removed
go build failure                  -> build root retained and exact path printed
missing with_v2ray_api tag        -> build root removed
candidate config-check failure    -> build root removed
candidate install/copy failure    -> build root removed
```

Each fixture asserts the neighboring directory and shared build cache remain.
The sole retained compile-failure directory must be named in stderr.

- [ ] **Step 2: Verify RED**

```bash
bash tests/test_singbox_runtime.sh
```

Expected: successful build directory remains.

- [ ] **Step 3: Clean only the successful build root**

Add a local cleanup helper that removes only the exact non-empty `build_root`.
If removal itself fails, it must print the exact retained path before returning
nonzero. Invoke it before returning from go-tmp creation, clone,
tag-validation, candidate-config, and install failures. The compile-failure
branch intentionally retains the tree and must keep its existing message with
the exact path. After the candidate is atomically installed and cache release
completes, remove the exact build root and propagate cleanup failure before
printing success. Never glob `build_parent`; always retain the shared Go cache.

The tests must inject a cleanup failure (through a small removable-command seam
or a fixture that cannot be removed) and assert stderr includes the exact
retained build path. This applies to both a failure branch and the successful
install's final cleanup.

- [ ] **Step 4: Verify GREEN and commit**

```bash
bash tests/test_singbox_runtime.sh
git add singbox.sh tests/test_singbox_runtime.sh
git commit -m "fix: clean successful singbox builds"
```

### Task 6: Run full repository verification and review

**Files:**
- Modify only if verification exposes an in-scope regression.

- [ ] **Step 1: Run all syntax and test checks**

```bash
bash -n singbox.sh traffic_manager.sh xray_manager.sh advanced_relay.sh parser.sh tests/*.sh
for test_file in tests/test_*.sh; do bash "$test_file"; done
git diff --check
```

Expected: every command exits `0`; the known host locale warning may appear, but no test warning/error does.

- [ ] **Step 2: Run static security assertions**

```bash
! rg -n '/tmp/singbox_links\.tmp' singbox.sh
! rg -n 'local tmp="\$\{file\}\.tmp"' singbox.sh
rg -n '_download_executable|_create_link_cache|SINGBOX_START_VERIFY_DELAY' singbox.sh
```

Expected: first two commands exit `0` because no unsafe match remains; helper search shows the intended implementations and call sites.

- [ ] **Step 3: Inspect scope and secrets**

```bash
git status --short
git diff --stat
git diff --check
git diff -- singbox.sh traffic_manager.sh xray_manager.sh README.md tests
```

Expected: `.agent/` remains untracked/unstaged; only planned files changed; fixtures contain synthetic values only.

- [ ] **Step 4: Request independent code review**

Use `@superpowers:requesting-code-review` against the approved spec and both implementation plans. Resolve all correctness/security findings and rerun the complete verification set.

- [ ] **Step 5: Commit any review-only corrections**

```bash
git add singbox.sh traffic_manager.sh xray_manager.sh README.md tests
git commit -m "fix: address shell hardening review"
```

Skip the final commit when review required no changes.

## Platform Verification Note

Local tests prove Bash behavior, file modes for files owned by the test user,
download rollback, and fake-process lifecycle. Root-owned uid/gid preservation,
real systemd/OpenRC behavior, and real Sing-box/Xray config compatibility still
require the disposable Linux integration gate defined in the approved spec and
traffic plan. Report that gate honestly if no Linux runtime is available.
