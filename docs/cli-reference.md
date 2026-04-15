# CLI Reference

If you want the best feature walkthrough first, start with the [user guide](user-guide.md). This page is the command reference.

`vmangos-manager` is the operational backend for the dashboard, installer-provisioned automation, and direct host administration.

Default installed paths:

- binary: `/opt/mangos/manager/bin/vmangos-manager`
- config: `/opt/mangos/manager/config/manager.conf`
- DB password file: `/opt/mangos/manager/config/.dbpass`

## Install The CLI

From a source checkout:

```bash
cd manager
make test
sudo make install PREFIX=/opt/mangos/manager
```

Or:

```bash
sudo ./manager/install_manager.sh --run-tests
```

To remove installed manager files without deleting `config/`:

```bash
cd manager
sudo make uninstall PREFIX=/opt/mangos/manager
```

## Global Options

```text
-c, --config FILE
-f, --format text|json
-v, --verbose
-h, --help
--version
```

## Dashboard

```bash
vmangos-manager dashboard [--refresh SECONDS] [--theme dark|light]
vmangos-manager dashboard --bootstrap
```

Notes:

- `dashboard --bootstrap` creates the dashboard virtual environment and installs Textual
- `dashboard` reuses Manager's existing JSON status surfaces instead of duplicating status logic
- default refresh interval is `2` seconds

## Server Commands

```bash
vmangos-manager server start [--wait] [--timeout SECONDS]
vmangos-manager server stop [--graceful|--force] [--timeout SECONDS]
vmangos-manager server restart [--timeout SECONDS]
vmangos-manager server status [--format text|json] [--watch] [--interval SECONDS]
```

Notes:

- watch mode is text-only
- default watch interval is `2` seconds
- status includes service state, process details, DB connectivity, disk space, player count, host metrics, alerts, and recent events
- `server start --wait` performs bounded post-start verification

## Logs Commands

```bash
vmangos-manager logs status [--format text|json]
vmangos-manager logs recent [--source all|auth|world] [--window 15m|1h|1d] [--severity all|debug|info|notice|warning|error|critical|alert] [--limit N] [--format text|json]
vmangos-manager logs recent [--source ...] [--window ...] [--severity ...] [--limit N] [--watch|--follow] [--interval SECONDS]
vmangos-manager logs rotate [--force]
vmangos-manager logs test-config
```

Notes:

- `logs status` is the log-rotation and disk-headroom posture check used by the Ops screen
- `logs recent` is the realm-log investigation surface used by the dedicated Logs module
- `logs recent` is scoped to Manager-supported realm sources only: `auth`, `world`, or `all`
- default recent filters are `source=all`, `window=15m`, `severity=all`, and `limit=25`
- watch/follow mode is text-only and re-runs the current filter set every interval
- default watch interval is `2` seconds

## Schedule Commands

```bash
vmangos-manager schedule honor --time 06:00 --daily [--timezone UTC]
vmangos-manager schedule restart --time 04:00 --weekly Sun [--timezone UTC] [--announce "Weekly maintenance"] [--warnings 30,15,5,1]
vmangos-manager schedule list [--format text|json]
vmangos-manager schedule simulate <job-id>
vmangos-manager schedule cancel <job-id>
```

Notes:

- schedules are stored under the Manager root and rendered into `systemd` timer/service units
- `schedule restart` uses journal-only warnings unless `maintenance.announce_command` is configured
- `schedule honor` requires `maintenance.honor_command` in `manager.conf`
- `restart_warnings` defaults to `30,15,5,1`

## Account Commands

```bash
vmangos-manager account create <username> [--password-file PATH|--password-env]
vmangos-manager account list [--online]
vmangos-manager account setgm <username> <0-3>
vmangos-manager account ban <username> <duration> --reason "<words>"
vmangos-manager account unban <username>
vmangos-manager account password <username> [--password-file PATH|--password-env]
```

Notes:

- passwords are never accepted as positional arguments
- supported password inputs are interactive prompt, `--password-file`, and `--password-env`
- usernames are normalized to uppercase to match the VMANGOS auth model

## Backup Commands

```bash
vmangos-manager backup now [--verify]
vmangos-manager backup list [--format text|json]
vmangos-manager backup verify <file> [--level 1|2]
vmangos-manager backup restore <file> [--dry-run]
vmangos-manager backup clean [--keep-last N]
vmangos-manager backup schedule status [--format text|json]
vmangos-manager backup schedule --daily HH:MM
vmangos-manager backup schedule --weekly "Sun 04:00"
```

## Config Commands

```bash
vmangos-manager config create [--path FILE]
vmangos-manager config detect [--format text|json]
vmangos-manager config validate [--format text|json]
vmangos-manager config show [--format text|json]
```

Behavior:

- `config detect` inspects likely VMANGOS install roots and parses `mangosd.conf` / `realmd.conf` when found
- `config detect` attempts to match auth/world service names from `systemd`
- `config detect` prints a proposed `manager.conf` and reports confidence, assumptions, and ambiguity
- `config detect` is read-only; it does not overwrite `manager.conf`
- `config create` includes a `[maintenance]` section for scheduler timezone, honor backend, warning backend, and default restart warnings

## Update Commands

```bash
vmangos-manager update check
vmangos-manager --format json update check
vmangos-manager update inspect
vmangos-manager --format json update inspect
vmangos-manager update plan
vmangos-manager --format json update plan --include-db
vmangos-manager update apply --backup-first
vmangos-manager update apply --backup-first --include-db
```

Behavior:

- `update check` prefers the configured VMANGOS core source tree under `<install_root>/source`
- if no installed source tree is available, `update check` falls back to the current `VMANGOS-Manager` checkout
- `update inspect` performs a read-only DB assessment against the configured `auth`, `world`, and `logs` databases
- `update plan` prints the non-atomic update steps for the configured VMANGOS core tree
- `update plan --include-db` adds DB migration assessment and fails closed when SQL changes need manual review
- `update apply` performs the non-atomic core update workflow in place
- `update apply --include-db` applies only supported timestamped files under `sql/migrations`

Important:

- `update apply` is non-atomic and does not promise rollback
- `update apply` requires either `--backup-first` or explicit confirmation that a verified backup already exists
- `update apply` rejects dirty or divergent VMANGOS source trees
- `update apply --include-db` refuses to mutate the DB if upstream SQL changes fall outside `sql/migrations/<timestamp>_{world|logon|logs}.sql`
- modified, deleted, or renamed SQL files require manual review before running a DB-aware update
- `update apply` does not support JSON output
- if no installed source tree is available, run Manager checkout comparisons from a source checkout or set `VMANGOS_MANAGER_REPO=/path/to/VMANGOS-Manager`

## Common Workflows

Dashboard:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --bootstrap
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --refresh 2
```

Status:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager server status
sudo /opt/mangos/manager/bin/vmangos-manager server status --watch --interval 2
```

Account creation:

```bash
sudo VMANGOS_PASSWORD='ChangeMe7' /opt/mangos/manager/bin/vmangos-manager account create TESTUSER --password-env
```

Backup with verification:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager backup now --verify
```

Recent realm logs:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager logs recent --source all --window 15m --severity warning --limit 25
sudo /opt/mangos/manager/bin/vmangos-manager logs recent --source world --severity error --watch --interval 2
```

Update check from a checkout:

```bash
cd ~/source/VMANGOS-Manager
./manager/bin/vmangos-manager update check
```
