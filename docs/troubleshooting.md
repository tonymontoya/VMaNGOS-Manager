# Troubleshooting

If you are still getting oriented, read the [User Guide](user-guide.md) first. This page is for diagnosing problems once Manager is installed.

---

## ⚙️ Config

### `Configuration file not found`

Check the path passed with `-c` or create the default config at:

```text
/opt/mangos/manager/config/manager.conf
```

### File permissions are wrong

Manager expects mode `600` for:

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

### `Update check requires a VMANGOS-Manager git checkout`

The installed manager under `/opt/mangos/manager` is a bundled copy, not a git repo. Run the command from a source checkout:

```bash
cd ~/source/VMANGOS-Manager
./manager/bin/vmangos-manager update check
```

Or point to a checkout explicitly:

```bash
VMANGOS_MANAGER_REPO=~/source/VMANGOS-Manager ./manager/bin/vmangos-manager update check
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

Restore intentionally refuses to guess privileged DB credentials. Supply them explicitly via `MYSQL_RESTORE_DEFAULTS_FILE` or `MYSQL_RESTORE_PASSWORD` before running a real restore.

---

## 🧪 Validation Commands

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
cd /home/tony/source/VMANGOS-Manager
./manager/bin/vmangos-manager update check
```
