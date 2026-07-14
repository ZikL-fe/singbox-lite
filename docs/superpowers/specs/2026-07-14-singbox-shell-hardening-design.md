# Singbox Shell Reliability Hardening Design

## Goal

Fix the confirmed reliability, quota-accounting, lifecycle, and local-secret
handling bugs in `singbox.sh` and `traffic_manager.sh` without redesigning the
node-management product or increasing its resident-memory footprint.

The resulting scripts must preserve correct traffic accounting across resets,
port changes, service restarts, deletion, and uninstall. Failures must be
reported as failures and must not leave partially enabled quotas or weakened
file permissions.

## Scope

### In scope

- `traffic_manager.sh` quota state, counter queries, locking, atomic writes,
  schedule lifecycle, node disable/restore, reset, and identity edits.
- `singbox.sh` quota integration, Argo quota lifecycle, uninstall ordering,
  disabled-port checks, secure link-cache handling, dependency downloads,
  direct service status propagation, and successful build cleanup.
- The minimum `xray_manager.sh` changes needed to use the shared traffic lock
  and preserve the quota lifecycle for Xray node creation, deletion, and port
  edits.
- Existing README statements that are contradicted by the corrected client
  installation flow.
- Deterministic shell regression tests using temporary directories and fake
  commands. Tests must not modify live services or `/usr/local`.

### Out of scope

- A general rewrite of the 6,000-line main script.
- Independent `advanced_relay.sh` and `parser.sh` input-validation work.
- Generic Xray service-manager behavior unrelated to quota transactions.
- Replacing the custom Sing-box build strategy or adding a resident daemon.
- Changing quota modes, reset semantics, supported protocols, or the one-minute
  enforcement interval.

## Confirmed defects

The implementation must cover every defect below. Each item already has either
a minimal reproduction or a direct lifecycle trace in the current code.

1. An active node reset writes counter baselines as zero, so the next check
   re-adds all traffic accumulated by the core before the reset.
2. A Sing-box tag/port edit changes quota identity without changing
   `experimental.v2ray_api.stats.inbounds` or settling the old counters. The new
   tag can therefore remain uncounted indefinitely.
3. Empty statistics responses are converted to three zero values, so the
   compatibility probe reports success even when the requested counters do not
   exist.
4. A failed monthly restore still advances `period_key`, preventing another
   restore attempt until the following month.
5. A failed schedule installation leaves committed quota state and API config
   even though `set` reports failure.
6. `_tm_purge` returns failure after a successful deletion whenever another
   record remains, while `_tm_clear_core` leaves the schedule installed after
   removing the final record.
7. Atomic JSON replacement creates new files with the process umask instead of
   preserving the original mode and ownership. A `0600` config can become
   `0644`.
8. An existing empty state file is silently replaced with `{}`, making active
   quota nodes unlimited after state truncation.
9. Oversized byte values are accepted even though Bash arithmetic and jq cannot
   represent them safely.
10. Argo deletion and uninstall omit quota-state cleanup. A disabled monthly
    Argo node can be restored after the user deleted it.
11. Main uninstall deletes the manager before invoking its cleanup, leaving
    timers, cron entries, and CLI-only statistics clients behind.
12. The recently added V2Ray installer uses nonexistent release asset names,
    writes to a path the manager never reads, skips checksum verification, and
    has its failure ignored.
13. Sing-box port conflict checks reserve disabled Sing-box ports but not
    disabled Xray ports, so a later restore can fail with a cross-core conflict.
14. Node links containing UUIDs and passwords are written to the predictable
    `/tmp/singbox_links.tmp` path, which is normally world-readable and can be
    pre-created as a symlink.
15. `yq` and cloudflared downloads can write a partial file directly to the
    final path and then treat that file as installed.
16. Direct-mode Sing-box start/restart can return success after the child has
    already exited.
17. Successful Sing-box builds leave the complete source/build directory under
    `/var/tmp` on every update.

## Architecture

`traffic_manager.sh` remains the only owner of quota state, statistics-client
selection, counter interpretation, schedule management, and saved disabled
inbounds. Interactive scripts own protocol-specific config, metadata, YAML,
certificates, and prompts, but every related mutation participates in the same
traffic-manager lock.

The repair uses four focused boundaries:

1. **Validated quota primitives** validate byte integers, state files, raw
   counter results, and node identity before arithmetic.
2. **Permission-preserving JSON replacement** writes to a same-directory
   temporary file that inherits the original file's metadata, validates the
   result, and atomically renames it.
3. **Explicit transactions** keep rollback snapshots until schedule/config/
   state/service work has succeeded and make lock ownership reentrant for child
   manager commands invoked by an interactive parent transaction.
4. **Lifecycle hooks** settle usage before identity changes and remove quota
   state before Argo/main uninstall can discard the files needed for cleanup.

No new process remains resident. The existing one-shot timer or cron execution
model is retained.

## Quota state and numeric rules

The existing JSON record format remains compatible. Existing records need no
offline migration.

- `used_bytes`, `last_uplink`, `last_downlink`, and `limit_bytes` must be
  non-negative JSON integers within the exact safe range `0..9007199254740991`.
- `limit_bytes` must additionally be greater than zero.
- CLI inputs are validated as decimal strings before Bash arithmetic or jq
  `tonumber` is used. Values above the safe maximum are rejected.
- `_tm_parse_size` applies the same maximum after converting MB/GB/TB.
- A missing state file is initialized to `{}` with mode `0600`.
- An existing empty or invalid state file is an error. It is never silently
  reset. The error prevents quota mutation/checking and is surfaced to the
  caller.
- Existing records may omit optional diagnostic fields. Read paths continue to
  provide compatible defaults.

The recently displayed `last_uplink` and `last_downlink` values are counter
baselines, not lifetime directional totals. The UI must label them as current
core counters rather than total directional usage; `used_bytes` remains the
authoritative accumulated quota usage. This avoids inventing unrecoverable
historical direction data for existing records.

## Counter query contract

`_tm_query_counters` returns exactly three validated decimal lines:

```text
total
uplink
downlink
```

For the built-in V2Ray/Xray clients, the raw JSON must contain both the expected
uplink and downlink names for the requested logical node. Missing `.stat`, an
empty match, a missing direction, malformed JSON, non-numeric values, negative
values, or values outside the safe range cause a nonzero return.

The injectable `TM_STATS_QUERY_CMD` test hook is normalized through the same
three-line numeric validator. A command returning zero is not sufficient if its
payload is incomplete.

`_tm_probe` succeeds only when this complete contract succeeds. Scheduled
checks retain prior counters and record `last_error` on any contract failure.

## Reset behavior

For an active node, `reset-usage` first queries the current aggregate counters.
Only after a valid response does it atomically set:

- `used_bytes = 0`
- `last_uplink = current_uplink`
- `last_downlink = current_downlink`

If the query fails, state is unchanged and the command fails.

For a quota-disabled node, reset restores its saved inbound transactionally and
restarts the affected core. The restored inbound starts with fresh counters, so
the baselines remain zero. Any restore or restart failure rolls back config and
state.

## Monthly restore behavior

At a new monthly period, a disabled node is restored before its period and usage
are advanced. If restoration, config validation, or the eventual core restart
fails:

- the prior config and state are restored;
- `period_key`, `used_bytes`, and disabled state remain unchanged;
- a retryable error is recorded;
- the check returns nonzero after processing any other independent records.

The next scheduled run therefore retries the same monthly restoration. A core
is still restarted at most once per check, regardless of how many nodes change.

## Identity and port edits

Every limited-node tag/port edit follows this order while holding the shared
lock:

1. Query and persist the old logical node's final counter delta.
2. Validate the requested port against active OS sockets, active configs, and
   disabled reservations from both Sing-box and Xray.
3. Build updated core config, metadata, client YAML, certificates, and quota
   state in rollback-capable temporary files.
4. Replace old Sing-box statistics members with the new primary/helper member
   tags in `experimental.v2ray_api.stats.inbounds`.
5. Validate the candidate config and restart the core.
6. Commit the renamed quota key/tag/member pattern and establish zero baselines
   for the new core counters.

Step 1 is a durable settlement boundary, not part of the state that later steps
may undo. The edit transaction keeps a post-settlement checkpoint containing
the old identity and the newly accumulated `used_bytes`.

- If a later step fails before the core is restarted, config/metadata/YAML are
  restored while the post-settlement state and its observed old-tag baselines
  remain valid.
- If candidate config was started and rollback has to restart the restored old
  config, the post-settlement `used_bytes` is retained under the old identity,
  but `last_uplink` and `last_downlink` are set to zero because the restored
  core starts fresh counters.
- A rollback must never restore the pre-settlement usage snapshot; doing so
  would permanently lose the final old-tag delta after a core restart.

For every failure, the old identity, stats membership, metadata, YAML, and
active config are restored around that post-settlement quota checkpoint.
Ordinary and native Hysteria2 nodes share the same behavior.

The manager exposes a non-interactive usage-settlement command for step 1. Its
identity-edit operation updates state and statistics membership as one logical
transaction rather than silently dropping the old counters.

## Locking

Scheduled checks and every interactive node create/edit/delete operation that
can overlap a quota check use the same lock directory.

- A parent interactive transaction exports its owner PID before invoking child
  manager commands.
- A child may borrow a lock owned by that parent but does not release it.
- A command that acquired the lock itself releases only its own lock.
- Release verifies the recorded owner before removing the lock directory.
- Mutating manager CLI commands acquire the lock automatically when they are
  not already inside an interactive transaction.
- Read-only `status`, `list`, `parse-size`, and `format-bytes` commands do not
  acquire the lock.
- Contention returns a clear nonzero status for interactive mutations; a
  scheduled `check` may exit successfully when another valid owner is working.

Tests use deterministic synchronization to prove two concurrent state updates
cannot lose one another.

## Atomic files and permissions

All state and core-config replacements use same-directory `mktemp` files.

- Existing mode and ownership are copied to the temporary file before writing.
- New sensitive state is created as `0600`.
- jq output must be valid and any available core config validator must pass
  before rename.
- Rename occurs only after writes complete.
- Failure removes only the current process's temporary file.
- Tests assert both content and mode before/after API enable, disable, restore,
  state update, and rollback.

The implementation must avoid broad cleanup globs that can delete another
concurrent process's temporary files.

## Schedule and `set` transaction

`set` holds the manager lock and treats schedule installation as part of the
same transaction. It must never return failure with newly committed quota state
that lacks an installed schedule.

The implementation records whether a schedule and any quota records existed at
entry. On failure it restores state/config and removes only schedule artifacts
created by that attempt. If the core had already been restarted with candidate
config, it is restarted again after restoration.

`purge`, `remove`, and `clear-core` return zero after successful deletion.
They remove the schedule only when no records for either core remain. Clearing
one core preserves the schedule if the other core still has records.

## Argo and uninstall lifecycle

Argo create/delete/uninstall operations hold the shared traffic lock.

- Deleting an active or disabled Argo node removes its quota record and any
  saved inbound without temporarily restoring the node.
- Argo uninstall purges every affected tag before discarding metadata.
- A later monthly check cannot recreate a deleted Argo inbound.

Main uninstall invokes traffic-manager cleanup before deleting
`$SINGBOX_DIR`. Cleanup removes systemd units, cron/OpenRC entries, feature-owned
API configuration, and CLI-only clients. It also removes the unused legacy
`/usr/local/bin/v2ray-api` artifact if a prior release installed it.

Cleanup is idempotent and safe when no quota was ever configured.

## Statistics client installation

The duplicate `_install_v2ray_api_client` implementation in `singbox.sh` is
removed. Quota setup delegates exclusively to the manager's verified downloader
and canonical path under `/usr/local/lib/singbox-lite`.

- Architecture mapping remains `64`, `arm64-v8a`, and `arm32-v7a`.
- The archive checksum must match the upstream `.dgst` file before extraction.
- Downloads go to a temporary directory and are atomically installed.
- A failed download leaves no executable at the destination.
- Sing-box core installation does not eagerly download this optional client;
  enabling the first quota installs it as part of the one-click flow.

README text is updated to state that a running Xray service is not required for
Sing-box quotas.

## Secure link cache

Node share links use a per-process file created by `mktemp` under
`${TMPDIR:-/tmp}` with mode `0600`. All reads and appends use that exact path.
The EXIT cleanup removes only that file.

No predictable path is opened for append, no pre-existing symlink is followed,
and concurrent script instances cannot read or overwrite each other's cache.
The cache is deleted after display and on abnormal shell exit.

## Dependency download safety

`yq` and cloudflared installation use temporary downloads and validate the
candidate before replacing an existing executable.

- Downloader failure, an empty/implausibly small payload, or failed version
  execution returns nonzero and deletes the candidate.
- Existing working binaries remain untouched on update failure.
- Successful candidates are made executable and atomically renamed into place.
- Dependency cache state is written only after all required candidates pass.

No new third-party mirror or trust source is added.

## Direct service and build cleanup

In direct mode, Sing-box start/restart waits briefly and verifies that the new
PID is still the expected binary. Immediate exit removes the stale PID file and
returns failure. Callers print success only after the service command succeeds.

After a successful custom Sing-box build and binary installation, the unique
source/build directory is removed. A failed build may retain its directory only
when the error message names that path for diagnosis. The shared Go build cache
is intentionally retained.

## Error handling

- No failure is converted into a success message or zero exit status.
- Rollback errors are reported separately from the initiating failure.
- Secrets, share links, UUIDs, passwords, and raw configs are not written to
  logs.
- Scheduled failures use `logger` when available and preserve the last valid
  state.
- Cleanup operations are idempotent.

## Testing

Tests extend the repository's existing standalone Bash harnesses and remain
rootless. They use fake binaries, injected command hooks, and temporary paths.

### Traffic manager regression tests

- active reset establishes current baselines and does not re-add old traffic;
- disabled reset restores with zero baselines;
- ordinary and Hysteria2 identity edits settle old usage and update API members;
- identity-edit rollback before/after core restart retains the settled delta and
  uses baselines appropriate to the restored process;
- empty, missing-direction, malformed, negative, and overflowing counters fail;
- monthly restore conflict retains the old period and retries later;
- schedule installation failure restores config and state;
- purge with remaining records returns zero;
- clear-core preserves/removes schedule at the correct times;
- empty state and oversized quota inputs are rejected;
- concurrent mutations do not lose state;
- config/state mode is preserved through all atomic replacements.

### Main-script integration tests

- disabled reservations from either core block Sing-box port selection;
- Argo active/disabled deletion and uninstall purge quota state;
- main uninstall calls cleanup before deleting the manager directory;
- no duplicate V2Ray installer or legacy consumer path remains;
- link cache is unique, `0600`, symlink-safe, and cleaned;
- failed yq/cloudflared downloads leave existing binaries unchanged;
- direct-mode immediate exit returns failure and clears its PID file;
- successful build cleanup removes only its unique build directory.

### Verification commands

At minimum:

```bash
bash -n singbox.sh traffic_manager.sh xray_manager.sh advanced_relay.sh parser.sh tests/*.sh
bash tests/test_port_validation.sh
bash tests/test_singbox_helpers.sh
bash tests/test_traffic_manager.sh
bash tests/test_traffic_integration.sh
git diff --check
```

New focused test files may be added when extracting whole functions into the
existing tests would make them fragile.

A Linux integration pass should additionally validate generated configs with
real Sing-box/Xray binaries and exercise systemd or OpenRC schedule creation.
If no Linux runtime is available in the workspace, this remains an explicitly
reported verification limitation rather than being treated as passed.

## Completion criteria

The change is complete when every confirmed defect has a failing regression
test observed before its fix, all focused and existing tests pass afterward,
shell syntax and diff hygiene pass, file modes are proven stable, and final
review finds no unresolved correctness or security issue in the changed paths.
