# MANUAL

## Overview

Release A ships the `vmangos-manager` CLI for:

- server control and status
- account management
- backup workflows
- read-only update checks

Release B adds explicit config detection for adopting existing VMANGOS installs without changing the runtime model to implicit autodetection.

Default installed paths:

- binary: `/opt/mangos/manager/bin/vmangos-manager`
- config: `/opt/mangos/manager/config/manager.conf`
- DB password file: `/opt/mangos/manager/config/.dbpass`

## Installation

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

## Server Commands

```bash
vmangos-manager server start [--wait]
vmangos-manager server stop [--graceful|--force]
vmangos-manager server restart
vmangos-manager server status [--format text|json] [--watch] [--interval SECONDS]
```

Notes:

- watch mode is text-only
- default watch interval is `2` seconds
- status includes service state, process details, DB connectivity, disk space, and player count

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

## Update Check

```bash
vmangos-manager update check
vmangos-manager --format json update check
vmangos-manager update plan
vmangos-manager update apply --backup-first
```

Behavior:

- `update check` prefers the configured VMANGOS core source tree under `<install_root>/source`
- if no installed source tree is available, `update check` falls back to the current `VMANGOS-Manager` checkout
- `update plan` prints the non-atomic update steps for the configured VMANGOS core tree
- `update apply` performs the non-atomic core update workflow in place

Important:

- `update apply` is non-atomic and does not promise rollback
- `update apply` requires either `--backup-first` or explicit confirmation that a verified backup already exists
- `update apply` rejects dirty or divergent VMANGOS source trees
- `update apply` does not support JSON output
- if no installed source tree is available, run Manager checkout comparisons from a source checkout or set `VMANGOS_MANAGER_REPO=/path/to/VMANGOS-Manager`

## Common Workflows

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

Update check from a checkout:

```bash
cd ~/source/VMANGOS-Manager
./manager/bin/vmangos-manager update check
```
