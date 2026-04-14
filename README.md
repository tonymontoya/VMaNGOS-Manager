# VMaNGOS Manager

![CI](https://github.com/tonymontoya/VMANGOS-Manager/actions/workflows/ci.yml/badge.svg)
![Ubuntu 22.04](https://img.shields.io/badge/ubuntu-22.04-E95420)
![Release](https://img.shields.io/badge/release-v0.1.0-0f766e)
![Interface](https://img.shields.io/badge/interface-Textual%20TUI-0f172a)

VMaNGOS Manager gives Classic WoW servers something they usually do not get: a real operator experience. It automates host installation, provisions the moving pieces around the realm, and puts a live terminal dashboard on top instead of expecting admins to live in scattered shell commands.

![VMANGOS Manager Textual dashboard](docs/assets/dashboard-overview.svg)

This screenshot is a real, demo-backed dashboard export generated from the Manager TUI.

## What It Unlocks

- fresh-host install automation for Ubuntu 22.04, including `VMANGOS only` or `VMANGOS + Manager`
- existing-host adoption through config detection instead of forcing a rebuild-from-scratch story
- a terminal-native TUI that gives VMaNGOS admins a real control surface without needing GNOME or KDE
- integrated day-two operations for status, logs, backups, account administration, scheduling, and updates
- one CLI backend that the dashboard, automation, and docs all agree on

## Why It Lands

VMaNGOS already has powerful server software. What it usually does not have is a cohesive operator layer.

Manager closes that gap. It turns host setup, service control, monitoring, backup safety rails, and account administration into one product instead of a pile of shell history, one-off SQL snippets, and private host notes.

## The Two Big Selling Points

### 1. Install Automation That Can Also Bring Manager Along

For a fresh Ubuntu 22.04 host, the repo ships installer flows that can provision:

- `VMANGOS only`
- `VMANGOS + Manager`

And they support two input modes:

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

### 2. A TUI Worth Running on a Real Server

The dashboard is the crowning feature. It is a terminal operator console, not a fake demo surface. It rides on the same Manager commands and JSON outputs used by the CLI, so the UI stays grounded in the actual product behavior.

Bootstrap once:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --bootstrap
```

Launch it:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --refresh 2
```

The TUI now gives you a practical top-like realm view with:

- auth/world service health, PID, uptime, and control actions
- host CPU, memory, disk, load, and disk I/O
- online player visibility and account inspection
- backup visibility plus verify, schedule, and restore dry-run entry points
- account workflows for create, password reset, GM level changes, and ban or unban actions
- log rotation and config visibility for safer day-two operations

This matters for the VMaNGOS audience because it keeps the deployment terminal-first while still giving admins something that feels intentional and productized.

## Start Here

### Fresh Host

Let the installer provision the realm and bring Manager with it:

```bash
sudo bash auto_install.sh
```

### Existing VMaNGOS Host

Install Manager, detect the local realm layout, then bootstrap the dashboard:

```bash
git clone https://github.com/tonymontoya/VMANGOS-Manager.git
cd VMANGOS-Manager/manager
make test
sudo make install PREFIX=/opt/mangos/manager
sudo /opt/mangos/manager/bin/vmangos-manager config detect
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --bootstrap
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --refresh 2
```

## What Sits Behind The UI

Manager is not just a dashboard skin. Under the hood it provides:

- server control and richer status output
- backup creation, verification, restore dry-runs, and scheduling
- account management and GM administration
- maintenance scheduling
- update planning and apply workflows
- config creation, detection, validation, and inspection
- log rotation checks and operational health visibility

## Proof

- validated on a real Ubuntu VMaNGOS host, not just mocked local shell tests
- the dashboard screenshot in this README is generated from the shipped Textual app export path
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
