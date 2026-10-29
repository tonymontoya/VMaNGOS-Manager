# Troubleshooting

If you are still getting oriented, read the [User Guide](user-guide.md) first. This page is for diagnosing problems once Manager is installed.

---

## 🧙 Install Wizard

### Where everything lives

| Artifact | Location |
|---|---|
| Install journal (live) | `journalctl -u vmangos-install` (add `-f` to follow) |
| Install log (file) | `/var/log/vmangos-install.log` |
| Secrets file | `/root/.vmangos-secrets/setup.conf` (mode `600`, root only) |
| Phase checkpoints | `<install-root>/.install-checkpoints/` |

### The install died and the screen says "Install Failed"

The Failure screen names the phase that died, the error message, and a hint that names the fix. **Retry** re-launches the install from the last completed phase checkpoint — finished phases are skipped, so a retry after a long build does not rebuild from zero. The journal for the failed attempt is preserved:

```bash
sudo journalctl -u vmangos-install --no-pager | less
```

If Retry is not enough, fix what the hint named and re-run `sudo vmangos-manager install` — the same resume-from-checkpoint logic applies.

### The screen says "Install Unit Ended" (not success, not failure)

The install unit exited without the completion marker — most likely an interrupted run (reboot, manual stop) or an older script. Nothing is claimed to be working. Verify where it stopped from the journal, then re-run `sudo vmangos-manager install` to resume from the last checkpoint:

```bash
sudo journalctl -u vmangos-install --no-pager | tail -50
```

### I closed the TUI — is the install still running?

Yes, unless you chose Retry/stop from the Failure screen. The install runs as its own transient systemd unit, not as a child of your terminal. Check it and re-attach:

```bash
systemctl status vmangos-install
sudo vmangos-manager install   # re-attaches the live viewer
```

### The wizard cannot find `vmangos_setup.sh`

The wizard resolves the setup script one directory above the manager's own location (the layout of a repo checkout). Running `./manager/bin/vmangos-manager install` from a checkout always works; a manager installed to a custom prefix needs `vmangos_setup.sh` beside that prefix's parent — link it there:

```bash
sudo ln -sfn /path/to/VMaNGOS-Manager/vmangos_setup.sh /opt/mangos/vmangos_setup.sh
```

---

## ⚙️ Config

### `Configuration file not found`

Check the path passed with `-c` or create the default config at:

```text
/opt/mangos/manager/config/manager.conf
```

### `Configuration file is not readable`

Every subcommand fails with this error when the invoking user cannot read `manager.conf`. The manager config and password file are owned by the service account (`mangos`) with mode `600`/`640`, so a plain user is locked out by design.

One-time fix, as root:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager config grant --user <your-username>
```

This grants group read on the config and `.dbpass` (mode `640`), group write on the backup directory, and adds the user to the service group. **Log out and back in** afterwards — group membership only applies to new sessions.

Note: starting/stopping the realm services and installing systemd timers still require root (`sudo systemctl ...` or run those commands via sudo).

### File permissions are wrong

Manager expects mode `600` (owner only) or `640` (owner + service group) for:

- `manager.conf`
- `.dbpass`
- Password files passed with `--password-file`

---

## 🖥️ Dashboard

### `Textual runtime import failed`

Bootstrap the dashboard environment:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --bootstrap
```

If the venv fails to create, install the required packages:

```bash
sudo apt-get install -y python3 python3-pip python3-venv
```

### Bootstrap stops with "missing ensurepip"

`python3` is installed but the `venv` module is not — typical on a minimal Ubuntu
server image. Manager refuses to create a half-broken environment and tells you the
package to add:

```bash
sudo apt-get install -y python3-venv
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --bootstrap
```

The realm installer already pulls `python3-venv` in; only a Manager-only host (no
realm) hits this.

### Dashboard opens but data is missing

Validate the backend directly:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager server status --format json
sudo /opt/mangos/manager/bin/vmangos-manager logs status --format json
sudo /opt/mangos/manager/bin/vmangos-manager account list --online --format json
```

If `account list --online` fails for a non-root operator, ensure `manager.conf` and `.dbpass` are readable by the account running the dashboard.

---

## 🔄 Updates

### `Update check requires a VMaNGOS-Manager git checkout`

The installed manager under `/opt/mangos/manager` is a bundled copy, not a git repo. Run the command from a source checkout:

```bash
cd ~/source/VMaNGOS-Manager
./manager/bin/vmangos-manager update check
```

Or point to a checkout explicitly:

```bash
VMANGOS_MANAGER_REPO=~/source/VMaNGOS-Manager ./manager/bin/vmangos-manager update check
```

### `Failed to fetch remote metadata`

Checklist:

- Network access to GitHub
- Valid `origin` in the checkout
- Git auth if using a private fork

Helpful commands:

```bash
git remote -v
git fetch origin
git status --short --branch
```

---

## 📊 Status

### Services show inactive

Check systemd directly:

```bash
sudo systemctl status auth
sudo systemctl status world
sudo systemctl status mariadb
```

### DB connectivity check fails

Verify:

- `database.host`
- `database.user`
- `database.password_file`
- MariaDB listener/bind settings

Direct comparison:

```bash
sudo cat /opt/mangos/manager/config/.dbpass
mysql -h 127.0.0.1 -P 3306 -u mangos -p'<password>' -N -B -e "SELECT 1" auth
```

---

## 👤 Accounts

### Password file rejected

Accepted ownership:

- root
- the current effective user
- the invoking sudo user when running through `sudo`

Mode must be `600`.

### `Failed to create account`

Check:

- Auth schema matches the expected VMANGOS baseline
- DB credentials in `manager.conf`
- `auth.account`, `auth.account_access`, `auth.account_banned`, and `auth.realmcharacters` are writable by the manager DB user

---

## 💾 Backups

### Verify fails because metadata is missing

Backup verify is fail-closed for missing metadata. Recreate the backup or repair the metadata sidecar before trusting the archive.

### Restore requires privileged credentials

Restore intentionally refuses to guess privileged DB credentials. Supply them explicitly via `MYSQL_RESTORE_DEFAULTS_FILE` or `MYSQL_RESTORE_PASSWORD` before running a real restore. The check runs in preflight — before any service is stopped — so a missing credential never takes the realm down.

### Restore preflight reports "database rejected the restore credentials"

The auth probe (`SELECT 1` with the restore credentials) failed: wrong password, wrong `MYSQL_RESTORE_USER`, or the database is unreachable. Check the credential values and `mysql -h <host> -P <port> -u root -p` by hand, then rerun `backup restore <file> --preflight`.

### Restore refuses: "no backup of the current databases within 24h"

The safety-backup gate fired. Restore will not overwrite the databases without an undo snapshot of the current state. Rerun with `--backup-first` to take one automatically, or wait for the next scheduled backup.

### Restore exits with RESTORE_PARTIAL

The dump import failed, or the realm did not come back up afterwards. Manager attempts to restart services on either path. Check `systemctl status` for the auth/world units and the database logs; the databases may be inconsistent — if you cannot repair them, restore a different archive using the [Recovery Runbook](user-guide.md#-recovery-runbook). If you passed `--backup-first`, the pre-restore archive of the previous state is your undo path.

### Restore refuses in non-interactive mode without confirmation

Live restore needs either a terminal (you type `RESTORE`) or `--yes`. This is intentional: scripted restores must be explicit. Review the plan with `--dry-run` first. The legacy `FORCE_RESTORE=1` env bypass no longer exists.

---

## 🧪 Validation Commands

Confirm which build is actually on this host:

```bash
/opt/mangos/manager/bin/vmangos-manager --version
```

The second line (`build: git=… describe=… built=…`) is written by `make install`, so
it identifies the exact commit and the moment it was installed — which is what you
need when a host and a checkout disagree. A tree installed without `git` available
reports `unknown` for those fields, and a package built from a tarball can pin them
explicitly:

```bash
make install VMANGOS_BUILD_INFO='git=1a2b3c4 describe=v0.6.0 built=2026-04-01T00:00:00Z'
```

Run the test suite:

```bash
cd manager
make test
```

Validate installed config:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager config validate
```

Validate a source checkout:

```bash
cd /home/tony/source/VMaNGOS-Manager
./manager/bin/vmangos-manager update check
```
