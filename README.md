# VMaNGOS Manager

![CI](https://github.com/tonymontoya/VMANGOS-Manager/actions/workflows/ci.yml/badge.svg)
![Ubuntu 22.04](https://img.shields.io/badge/ubuntu-22.04-E95420)
![Release](https://img.shields.io/badge/release-v0.1.0-0f766e)
![Interface](https://img.shields.io/badge/interface-Textual%20TUI-0f172a)

VMaNGOS Manager is the operator layer VMaNGOS usually does not get out of the box. It can stand up a fresh Ubuntu host, adopt an existing realm install, and put a real terminal dashboard on top of the day-two work instead of leaving admins buried in shell history, scattered notes, and ad hoc SQL.

![VMANGOS Manager Textual dashboard](docs/assets/dashboard-overview.svg)

This screenshot is generated from the shipped Textual dashboard renderer against a reproducible demo snapshot, not a hand-edited mockup.

## Why Admins Install It

- take a blank Ubuntu 22.04 host to `VMANGOS only` or `VMANGOS + Manager` without maintaining a private install playbook
- adopt an already-running realm through config detection instead of rebuilding the machine from scratch
- run a real terminal-native dashboard on the server itself without needing GNOME, KDE, or a separate web stack
- unify backups, logs, account operations, scheduling, updates, and status under one operator surface and one CLI backend

## Install Automation

For a fresh Ubuntu 22.04 host, the repo ships installer flows that can provision either:

- `VMANGOS only`
- `VMANGOS + Manager`

Both installer paths support:

- `Automated`
- `Guided`

Automated install:

```bash
wget https://raw.githubusercontent.com/tonymontoya/VMANGOS-Manager/main/auto_install.sh
wget https://raw.githubusercontent.com/tonymontoya/VMANGOS-Manager/main/vmangos_setup.sh
sudo bash auto_install.sh
```

Guided install:

```bash
wget https://raw.githubusercontent.com/tonymontoya/VMANGOS-Manager/main/vmangos_setup.sh
sudo bash vmangos_setup.sh
```

The installer handles the ugly parts that usually get scattered across local notes:

- dependency installation and long-build orchestration
- database creation and credentials
- config generation
- client data staging
- manager provisioning under `/opt/mangos/manager`
- dashboard prerequisites when Manager is included

`auto_install.sh` stays non-interactive and defaults to `VMANGOS + Manager` with automated inputs. `vmangos_setup.sh` prompts early for the provisioning target and input mode so the operator knows what path they are on before the long-running phases start.

Use the [install automation guide](docs/install-automation.md) for the full installer story.

## A TUI Worth Running On The Server

The dashboard is the headline feature. It is a terminal operator console built on the same Manager commands and JSON output used by the CLI, so the UI stays grounded in the real product instead of drifting into a separate frontend fiction.

Bootstrap once:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --bootstrap
```

Launch it:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --refresh 2
```

The dashboard gives you a practical top-like realm view with:

- auth/world service health, PID, uptime, and control actions
- host CPU, memory, disk, load, disk I/O, and short-term monitoring trends
- online player visibility and account inspection
- backup visibility plus verify, schedule, and restore dry-run entry points
- account workflows for create, password reset, GM level changes, and ban or unban actions
- log rotation and config visibility for safer day-two operations

It keeps the deployment terminal-first while still giving admins something that feels intentional and productized.

## Existing Host Adoption

If you already have VMaNGOS running, Manager does not force a reinstall story. Install it, detect the local layout, then bootstrap the dashboard:

```bash
git clone https://github.com/tonymontoya/VMANGOS-Manager.git
cd VMANGOS-Manager/manager
make test
sudo make install PREFIX=/opt/mangos/manager
sudo /opt/mangos/manager/bin/vmangos-manager config detect
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --bootstrap
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --refresh 2
```

The lower-level command surface still exists for operators who prefer it. Use the [CLI reference](docs/cli-reference.md) for command-by-command detail instead of packing that material into the README.

## Proof

- validated on a real Ubuntu VMaNGOS host, not just mocked local shell tests
- the dashboard screenshot in this README is generated from the shipped Textual app export path using a reproducible demo payload
- the test suite covers config, status, logs, schedule, backup, update, account, and dashboard seams

## Documentation

- [Install automation](docs/install-automation.md)
- [CLI reference](docs/cli-reference.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Security notes](docs/security.md)
- [Research notes](docs/research)

If you want command-by-command detail, use the CLI reference instead of the README.

## VMaNGOS Context

VMaNGOS is an independent continuation of the Elysium/LightsHope codebases focused on accurate Vanilla WoW content progression across patch eras from 1.2 through 1.12.1.

## Resources

- [VMaNGOS Core](https://github.com/vmangos/core)
- [VMaNGOS Database](https://github.com/brotalnia/database)
- [VMaNGOS Wiki](https://github.com/vmangos/wiki/wiki)
- [Issue Tracker](https://github.com/tonymontoya/VMANGOS-Manager/issues)

## License & Disclaimer

This project is for educational purposes. Running a private WoW server may violate Blizzard's Terms of Service. Use at your own risk.
