# TROUBLESHOOTING

## Config Problems

### `Configuration file not found`

Check the path passed with `-c` or install the default config at:

```text
/opt/mangos/manager/config/manager.conf
```

### Config or password file permissions are wrong

Release A expects mode `600` for:

- `manager.conf`
- `.dbpass`
- password files passed with `--password-file`

## Update Check Problems

### `Update check requires a VMANGOS-Manager git checkout`

The installed manager under `/opt/mangos/manager` is a bundled copy, not a git repo. Run the command from a source checkout:

```bash
cd ~/source/VMANGOS-Manager
./manager/bin/vmangos-manager update check
```

Or point the command at a checkout explicitly:

```bash
VMANGOS_MANAGER_REPO=~/source/VMANGOS-Manager ./manager/bin/vmangos-manager update check
```

### `Failed to fetch remote metadata`

Check:

- network access to GitHub
- that the checkout has a valid `origin`
- local git auth if using a private fork

Helpful commands:

```bash
git remote -v
git fetch origin
git status --short --branch
```

## Status Problems

### Services show inactive

Validate systemd directly:

```bash
sudo systemctl status auth
sudo systemctl status world
sudo systemctl status mariadb
```

### DB connectivity check fails

Check:

- `database.host`
- `database.user`
- `database.password_file`
- MariaDB listener/bind settings

On the Ubuntu host, this is a useful comparison:

```bash
sudo cat /opt/mangos/manager/config/.dbpass
mysql -h 10.0.1.6 -P 3306 -u mangos -p'<password>' -N -B -e "SELECT 1" auth
```

## Account Problems

### Password file rejected

Accepted password-file ownership is:

- root
- the current effective user
- the invoking sudo user when running through `sudo`

Mode must still be `600`.

### `Failed to create account`

Check:

- auth schema matches the Release A baseline
- DB credentials in `manager.conf`
- `auth.account`, `auth.account_access`, `auth.account_banned`, and `auth.realmcharacters` are writable by the manager DB user

## Backup Problems

### Verify fails because metadata is missing

Release A backup verify is fail-closed for missing metadata. Recreate the backup or repair the metadata sidecar before trusting the archive.

### Restore requires privileged credentials

Release A restore intentionally refuses to guess privileged DB credentials. Supply the required credentials explicitly before running a real restore.

## Validation Commands

Manager tests:

```bash
cd manager
make test
```

Installed manager config check:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager config validate
```

Host-side source checkout validation:

```bash
cd /home/tony/source/VMANGOS-Manager
./manager/bin/vmangos-manager update check
```
