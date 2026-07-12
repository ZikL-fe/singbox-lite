# Node Traffic Quota Design

## Goal

Add optional per-node traffic quotas to both Sing-box and Xray nodes. Traffic usage is the sum of uplink and downlink bytes. Nodes without a quota continue to behave exactly as they do today.

## User-visible behavior

- Node creation asks whether to configure a traffic quota. The default is unlimited.
- Supported quota modes:
  - `once`: a one-time total allowance that never resets automatically.
  - `monthly`: resets on a configured day from 1 through 31.
- If a monthly reset day does not exist in a month, reset on that month's final day.
- Node lists show used traffic, total allowance, quota mode, reset information, and status.
- An exceeded node is clearly highlighted as disabled because its traffic allowance was exhausted.
- Node editing can enable or remove a quota, change its size or mode, change the monthly reset day, and reset current usage.
- When usage reaches the allowance, the node is disabled automatically.
- A monthly node is restored after its reset. A one-time node is restored after an operator resets usage or raises/removes its allowance so it is no longer exceeded.
- Enforcement runs periodically, so a node can exceed its allowance by traffic transferred between checks.

## Architecture

Create `traffic_manager.sh` as the shared quota component. `singbox.sh` and `xray_manager.sh` call its command interface instead of duplicating quota logic.

The manager has no permanently resident process. A systemd timer or cron/OpenRC-compatible scheduled entry invokes a one-shot `check` command once per minute. The command reads counters, updates persistent state, performs resets, and disables or restores nodes before exiting.

The statistics APIs must listen only on localhost. Enable only the inbound uplink and downlink statistics needed by this feature.

## Core statistics

### Sing-box

Enable the local V2Ray-compatible statistics API and inbound traffic counters in the generated Sing-box configuration. Use the Xray binary's `api statsquery` command as the concrete client for this compatible API. If Xray is not already installed, install the same Xray binary already managed by this repository as a command-line-only dependency; it is not started as a service and adds no resident memory usage.

This feature targets Sing-box 1.13 and later, matching the core generation currently managed by the repository. Initialization must run a compatibility probe against `v2ray.core.app.stats.command.StatsService/QueryStats` and refuse to enable a quota if the installed core/client pair cannot query counters. Counter names are `inbound>>><tag>>>traffic>>>uplink` and `inbound>>><tag>>>traffic>>>downlink`, parsed from the `statsquery` machine-readable result rather than human-oriented table output.

### Xray

Enable Xray's local API, StatsService, stats policy, and inbound uplink/downlink counters. Query counters through the installed Xray command-line API client.

Create a reserved localhost-only API inbound with a stable tag such as `traffic-api`. Add the required API routing rule and preserve this inbound across all node operations. Node listing, quota accounting, editing, deletion, delete-all, node counts, and port-selection menus must explicitly exclude reserved infrastructure tags. Xray enables inbound accounting through its system policy globally; the checker still queries only limited logical nodes.

For both cores, usage for a node is:

```text
uplink bytes + downlink bytes
```

Core counters can reset after a service restart. Persistent usage is therefore accumulated from non-negative deltas between the current counter and the last observed counter. If a current counter is lower than its previous value, treat the current value as the first delta after a core restart.

A quota belongs to a logical node, not necessarily one inbound. Ordinary nodes have one member tag. Sing-box native Hysteria2 port hopping includes the primary tag plus its `${tag}-hop-*` helper inbounds. Query all matching counters and aggregate them into one current uplink value and one current downlink value before calculating deltas. Store only the aggregate baselines and a member tag pattern, not one baseline per helper inbound. Helper inbounds remain hidden from interactive node lists. Any operation that changes logical-node membership first accounts for current usage, performs the edit, and then establishes a fresh aggregate baseline.

## Persistent data

Store quota state in `/usr/local/etc/sing-box/traffic_limits.json`. Use byte values internally and atomic temporary-file replacement for every update.

Example record:

```json
{
  "singbox:vless-in-443": {
    "core": "singbox",
    "tag": "vless-in-443",
    "mode": "monthly",
    "limit_bytes": 107374182400,
    "used_bytes": 2147483648,
    "reset_day": 1,
    "period_key": "2026-07-01",
    "member_pattern": "^vless-in-443$",
    "last_uplink": 1000,
    "last_downlink": 2000,
    "disabled": false,
    "disabled_reason": null,
    "saved_primary_inbound": null,
    "saved_helper_template": null,
    "saved_helper_range": null
  }
}
```

Use a core-prefixed key so identical tags in Sing-box and Xray cannot collide.

## Disabling and restoring nodes

When a quota is exceeded, remove every inbound belonging to the logical node from the active core configuration. Store an ordinary node as `saved_primary_inbound`. For Sing-box native Hysteria2 port hopping, store the primary inbound plus one helper template and the contiguous helper port range; do not store every generated helper object. Restart only the affected service. Keep metadata, share links, Clash YAML entries, certificates, and quota state intact.

When restoring a node, insert the saved primary inbound and regenerate any Hysteria2 helper inbounds from the saved template and range. Reject conflicting ports before changing the active configuration. Clear the saved definitions and disabled reason only after validation and a successful restart.

Deletion must remove both active and saved inbound forms, quota state, certificates, metadata, and client configuration entries. Port conflict checks must include disabled nodes stored by the quota manager so their reserved ports cannot be reused accidentally.

Node selectors must enumerate the union of active core inbounds and disabled quota records. Port and tag edits must update the quota key, stored tag, logical-node member pattern, saved primary/template/range definitions, metadata, Clash YAML, and statistics identity whether the node is active or disabled. The manager's identity-edit command accepts old/new tags and old/new ports rather than a tag-only rename.

Interactive edits, deletion, scheduled checks, and all related config/metadata/YAML/state writes share the same manager lock so a timer cannot observe or write a half-completed node change.

## Monthly reset calculation

Compute reset dates using the server's local calendar:

1. Clamp the configured reset day to the final valid day of the current month.
2. Define `period_key` as the latest effective reset boundary at or before the current time. A newly created monthly quota uses that boundary, so its first automatic reset occurs at the next boundary.
3. If the computed period key differs from the stored key, set used traffic to zero and set the aggregate baselines to the counters observed during that same check. Do not set baselines to zero while core counters are still increasing.
4. Restore the node if it was disabled only because of quota exhaustion.

For a node intentionally disabled by quota exhaustion, missing counters are expected rather than a query failure. At its monthly reset boundary, reset usage, restore its saved configuration, restart the core, and initialize its aggregate baselines to zero because the restored inbounds begin with fresh counters. A genuine API or query failure for active quota nodes still blocks accounting and state transitions for that core check.

This supports reset days 29, 30, and 31 in shorter months.

## Command interface

`traffic_manager.sh` provides non-interactive commands suitable for scripts and scheduled execution:

```text
init
set <core> <tag> <mode> <limit-bytes> [reset-day]
remove <core> <tag>
reset-usage <core> <tag>
edit-identity <core> <old-tag> <new-tag> <old-port> <new-port>
delete <core> <tag>
status <core> <tag>
list <core>
check
install-schedule
remove-schedule
```

Machine-readable status output is JSON. Interactive scripts format it for terminal display.

## Input and display

- Accept quota input as a positive number plus `MB`, `GB`, or `TB`.
- Reject zero, negative, malformed, or overflowing values.
- Display values using a human-readable binary unit with two decimals where useful.
- Unlimited nodes display `流量限制: 无限制`.
- Exceeded nodes display a red `流量超额，节点已停用` status.

## Compatibility and migration

- Existing installations require no migration: a missing quota file is initialized as `{}`.
- Existing nodes remain unlimited until explicitly configured.
- The script updater downloads `traffic_manager.sh` with the existing child scripts.
- Uninstall removes the scheduled task, local statistics API configuration owned by this feature, quota state, and the installed manager script.
- systemd, OpenRC, and no-init environments remain supported using the repository's existing service-detection patterns.

## Resource constraints

- Do not run a permanent quota-monitor daemon.
- Statistics APIs bind to localhost only.
- Query only configured quota nodes and only their uplink/downlink counters.
- Process counter results as a stream where practical rather than retaining large documents.
- State grows linearly by one bounded record per limited logical node, independent of Hysteria2 helper-port count.
- Avoid restarting a core more than once per check, even if multiple nodes change state.

## Error handling

- Use a lock to prevent overlapping scheduled checks.
- If a statistics query fails, retain previous counters and do not disable or restore nodes based on incomplete data.
- Validate modified core configuration before replacing the active file where the core supports validation.
- On a failed configuration update or restart, restore the previous configuration and retain the previous quota state.
- Log scheduled failures through syslog/logger without printing secrets or share links.
- Treat failure of the statistics compatibility probe as unsupported configuration, not as zero usage.

## Testing

Add shell tests around the manager's pure operations using temporary configuration and state directories:

- quota size parsing and formatting;
- uplink plus downlink delta accumulation;
- counter reset after core restart;
- one-time quota exhaustion;
- monthly reset on ordinary and shortened months;
- disable and restore transformations for both core configuration formats;
- quota rename during port/tag edits;
- unlimited nodes remaining untouched;
- failed statistics reads preserving state;
- multiple state changes causing at most one restart per core.

The manager must expose injectable command paths or environment hooks for the clock, statistics query, core config validation, and service restart operations. Tests use deterministic fake commands and temporary files; they must not require root, live cores, systemd, OpenRC, or network access.

Integration verification should additionally validate generated Sing-box and Xray configurations with installed core binaries on a Linux test host.
