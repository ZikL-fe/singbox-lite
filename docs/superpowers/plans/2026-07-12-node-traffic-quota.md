# Node Traffic Quota Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add optional one-time and monthly uplink-plus-downlink quotas for Sing-box and Xray nodes, with automatic disabling, resetting, restoration, display, and editing.

**Architecture:** Add a focused `traffic_manager.sh` command component that owns quota state, counter deltas, schedule installation, and active/disabled node transformations. Existing interactive scripts call this component for quota prompts and status while continuing to own protocol-specific node creation and client-link metadata.

**Tech Stack:** Bash, jq, Sing-box V2Ray statistics API, Xray StatsService and `xray api statsquery`, systemd timers, cron/OpenRC-compatible scheduling.

---

### Task 1: Pure quota helpers and test harness

**Files:**
- Create: `traffic_manager.sh`
- Create: `tests/test_traffic_manager.sh`

- [ ] Write failing tests for size parsing/formatting, delta accumulation after counter reset, monthly reset boundaries including February, and quota exhaustion.
- [ ] Run tests with Git Bash and verify failures are caused by missing functions.
- [ ] Implement source-safe helper functions and a main guard in `traffic_manager.sh`.
- [ ] Run the helper tests and verify they pass.

### Task 2: Persistent state and logical-node lifecycle

**Files:**
- Modify: `traffic_manager.sh`
- Modify: `tests/test_traffic_manager.sh`

- [ ] Write failing tests using temporary files and injected clock/query/validation/restart commands.
- [ ] Cover create/update/remove/reset status, aggregate member counters, service restart counter resets, atomic state writes, and lock contention.
- [ ] Cover identity/membership edits accounting current traffic before modification and establishing fresh aggregate baselines afterward.
- [ ] Implement `/usr/local/etc/sing-box/traffic_limits.json` state with overridable test paths.
- [ ] Implement disable/restore for Sing-box and Xray, including Hysteria2 primary/template/range persistence.
- [ ] Verify failures preserve configs and quota state.

### Task 3: Statistics API configuration and scheduled enforcement

**Files:**
- Modify: `traffic_manager.sh`
- Modify: `singbox.sh`
- Modify: `xray_manager.sh`
- Modify: `tests/test_traffic_manager.sh`

- [ ] Add failing fixture tests for idempotent Sing-box `experimental.v2ray_api` configuration and Xray reserved API inbound/API/routing/policy configuration.
- [ ] Add failing tests for locating or installing the repository-managed Xray binary as a CLI-only Sing-box statistics client, localhost-only API binding, compatibility probing before `set`, exact counter parsing, and query/setup rollback.
- [ ] Write a deterministic failing test proving multiple node transitions cause at most one restart per core during one `check`.
- [ ] Implement API setup, compatibility probing, exact inbound counter queries, aggregation, and `check`.
- [ ] Implement systemd timer and cron-compatible one-shot scheduling, installed only while quotas exist and removed when the final quota is removed.
- [ ] Ensure active-query failures never count as zero and intentionally disabled nodes can reset and restore.

### Task 4: Sing-box user flows

**Files:**
- Modify: `singbox.sh`
- Modify: `tests/test_traffic_manager.sh`

- [ ] Add failing integration tests for quota prompts, list display, edit actions, usage reset, deletion, port/tag identity edits, disabled-node selection, and disabled-port reservation.
- [ ] Download/install `traffic_manager.sh` with the existing child scripts.
- [ ] Invoke one shared post-create hook only inside each successful protocol/Argo creator after config commit; menus and batch dispatchers never prompt directly. Test exactly one prompt per successfully created logical node and none after a failed creator.
- [ ] Show quota usage and exceeded status in `_view_nodes`.
- [ ] Add an edit-quota menu supporting enable, disable, size/mode/reset-day changes, and usage reset.
- [ ] Update delete and port/tag edit flows to include disabled nodes and keep quota identity synchronized.
- [ ] Hold the traffic-manager lock across each interactive edit/delete transaction covering core config, metadata, YAML, certificates, and quota state.
- [ ] Make counts, selectors, and new-node port-conflict checks use the union of active and disabled logical nodes, including Hysteria2 helper ranges.

### Task 5: Xray user flows and infrastructure filtering

**Files:**
- Modify: `xray_manager.sh`
- Modify: `singbox.sh`
- Modify: `tests/test_traffic_manager.sh`

- [ ] Add failing integration tests for Xray quota prompts, list display, edits, usage reset, deletion, identity edits, disabled-node selection, disabled-port reservation, and API-inbound preservation.
- [ ] Prompt for optional quotas after each of `_add_vless_reality_vision`, `_add_vless_grpc_reality`, `_add_trojan_xhttp_reality`, `_add_trojan_grpc_reality`, `_add_shadowsocks_xray`, `_add_vless_h2_tls`, `_add_vless_grpc_tls`, and `_add_trojan_grpc_tls`.
- [ ] Show quota usage and exceeded status in `_view_xray_nodes`.
- [ ] Add Xray quota editing and usage reset menu entries.
- [ ] Preserve the API inbound during delete-all and exclude it from counts, selection, and conflict logic.
- [ ] Synchronize disabled-node deletion and port/tag changes.
- [ ] Hold the same traffic-manager lock across Xray config, metadata, YAML, certificates, and quota-state edits/deletion.
- [ ] Make every Xray node count/selector use active user inbounds plus disabled quota nodes while excluding the reserved API inbound.

### Task 6: Documentation and verification

**Files:**
- Modify: `README.md`
- Modify: `tests/test_traffic_manager.sh`

- [ ] Document optional quotas, one-time/monthly modes, monthly short-month behavior, enforcement delay, memory model, and commands.
- [ ] Add failing lifecycle tests, then update script download and uninstall flows to install/update `traffic_manager.sh`, remove the final-quota schedule, and remove schedules, feature-owned API configuration, quota state, and the manager script during uninstall.
- [ ] Run `bash -n` on all shell scripts with Git Bash.
- [ ] Run the complete local test suite.
- [ ] Run `git diff --check` and inspect the final diff for secrets and unrelated changes.
- [ ] On a Linux host with jq and the installed Sing-box/Xray binaries, validate both generated configs, run the Sing-box compatibility query, run the Xray stats query, invoke the scheduled `check`, exercise disable/reset/restore, and prove that multiple changes cause at most one restart per core. Treat unavailable Linux integration validation as an explicit incomplete verification item rather than a passing result.
