# VMANGOS Manager

VMANGOS Manager turns a raw Ubuntu VMANGOS host into something that feels operated instead of babysat: automated installation, an opinionated live dashboard, and the CLI automation behind both.

![VMANGOS Manager Textual dashboard](docs/assets/dashboard-overview.svg)

## What It Sells

- automated VMANGOS install and provisioning on Ubuntu 22.04
- a Textual dashboard for live host and realm status
- backups, scheduling, updates, accounts, and config adoption behind the scenes
- pragmatic host-first automation instead of hand-maintained admin scripts

## The Two Main Features

### 1. Install Automation

For a fresh host, the repo ships the installer flow that provisions VMANGOS, configures databases, lays out runtime paths, and can also provision Manager itself under `/opt/mangos/manager`.

Automated install:

```bash
wget https://raw.githubusercontent.com/tonymontoya/VMANGOS-Manager/main/auto_install.sh
wget https://raw.githubusercontent.com/tonymontoya/VMANGOS-Manager/main/vmangos_setup.sh
sudo bash auto_install.sh
```

Interactive install:

```bash
wget https://raw.githubusercontent.com/tonymontoya/VMANGOS-Manager/main/vmangos_setup.sh
sudo bash vmangos_setup.sh
```

The installer handles:

- dependency installation and long-build orchestration
- database creation and credentials
- config generation
- client data staging
- manager provisioning
- dashboard prerequisites for fresh installs

### 2. The Textual Dashboard

The dashboard is the flagship operator experience. It is backed by the same Manager JSON status surfaces used by the CLI, so the TUI is not a separate monitoring stack.

Bootstrap once on a host where Manager is already installed:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --bootstrap
```

Launch it:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --refresh 2
```

The dashboard surfaces:

- auth/world service health, PID, uptime, and quick actions
- host CPU, memory, disk, load, and disk I/O
- online-player table plus player details
- alerts, recent events, and log-rotation health

## Quick Start

Install Manager from a source checkout:

```bash
git clone https://github.com/tonymontoya/VMANGOS-Manager.git
cd VMANGOS-Manager/manager
make test
sudo make install PREFIX=/opt/mangos/manager
```

Or:

```bash
sudo ./manager/install_manager.sh --run-tests
```

Then:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --bootstrap
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --refresh 2
```

## Documentation

- [CLI reference](docs/cli-reference.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Security notes](docs/security.md)
- [Research notes](docs/research)

## Under The Hood

The CLI remains the operational backend for:

- server control and richer status output
- backup and restore workflows
- maintenance scheduling
- update planning and apply flows
- account management
- config detection for existing installs

If you want the command-by-command details, use the CLI reference instead of the README.

## VMaNGOS Context

VMaNGOS is an independent continuation of the Elysium/LightsHope codebases focused on accurate Vanilla WoW content progression across patch eras from 1.2 through 1.12.1.

## Resources

- [VMaNGOS Core](https://github.com/vmangos/core)
- [VMaNGOS Database](https://github.com/brotalnia/database)
- [VMaNGOS Wiki](https://github.com/vmangos/wiki/wiki)
- [Issue Tracker](https://github.com/tonymontoya/VMANGOS-Manager/issues)

## License & Disclaimer

This project is for educational purposes. Running a private WoW server may violate Blizzard's Terms of Service. Use at your own risk.
