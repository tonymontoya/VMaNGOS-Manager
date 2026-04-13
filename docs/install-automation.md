# Install Automation

VMANGOS Manager ships two installer entry points aimed at different operator styles:

- `auto_install.sh` for a mostly hands-off first-time host bootstrap
- `vmangos_setup.sh` for guided interactive installation and provisioning

Both target Ubuntu 22.04 and are designed around a full VMANGOS host lifecycle rather than just copying binaries into place.

## What The Installer Handles

- Ubuntu package prerequisites for building and running VMANGOS
- source checkout and build orchestration
- MariaDB database creation and grants
- runtime path layout under the chosen install root
- config generation for `realmd` and `mangosd`
- client data staging and path normalization
- optional Manager provisioning under `/opt/mangos/manager`
- dashboard Python/Textual prerequisites when Manager is provisioned

## Recommended Paths

### Zero-Touch Bootstrap

Use this when you want the installer to generate credentials and carry the host through with minimal prompting:

```bash
wget https://raw.githubusercontent.com/tonymontoya/VMANGOS-Manager/main/auto_install.sh
wget https://raw.githubusercontent.com/tonymontoya/VMANGOS-Manager/main/vmangos_setup.sh
sudo bash auto_install.sh
```

This flow:

- generates secure random passwords
- stores setup secrets under `/root/.vmangos-secrets/setup.conf`
- runs the full install non-interactively
- prints the resulting credentials and runtime paths at the end

### Guided Interactive Install

Use this when you want to choose paths, database names, or provisioning behavior during install:

```bash
wget https://raw.githubusercontent.com/tonymontoya/VMANGOS-Manager/main/vmangos_setup.sh
sudo bash vmangos_setup.sh
```

Expect prompts for:

- installation root
- database names and credentials
- OS user
- client data location
- optional Manager provisioning

## Existing Host Adoption

If VMANGOS is already installed and you mainly want the Manager experience:

1. Install Manager under `/opt/mangos/manager`
2. Run config detection
3. Review the proposed config
4. Bootstrap and launch the dashboard

Example:

```bash
cd manager
make test
sudo make install PREFIX=/opt/mangos/manager
sudo /opt/mangos/manager/bin/vmangos-manager config detect
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --bootstrap
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --refresh 2
```

## Installer Characteristics

The installer is intentionally pragmatic rather than minimal:

- retry logic around network operations
- checkpoint/resume support for interrupted installs
- logging to `/var/log/vmangos-install.log`
- support for long-running compilation on a real server host
- explicit file generation instead of hidden runtime autodetection

## After Install

Typical first commands:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager config validate
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --bootstrap
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --refresh 2
```

For lower-level command details, use the [CLI reference](cli-reference.md).
