# VMANGOS Manager

![CI](https://github.com/tonymontoya/VMaNGOS-Manager/actions/workflows/ci.yml/badge.svg)
![Ubuntu 22.04–26.04](https://img.shields.io/badge/ubuntu-22.04--26.04-E95420)
![Release](https://img.shields.io/badge/release-v0.7.33-0f766e)
![Interface](https://img.shields.io/badge/interface-Textual%20TUI-0f172a)

An SSH terminal-native administration suite for VMANGOS private servers optimized for performance and security. 

![VMANGOS Manager Dashboard](docs/assets/dashboard-overview.svg)

*Real screenshot from the shipped Textual dashboard — not a mockup.*

---

## Why VMANGOS Manager?

- **One-Shot Provisioning** — Go from blank Ubuntu 22.04 to a running realm with a single script
- **SSH-Native Dashboard** — A text-based UI that runs directly on the server ore remotely over SSH
- **No More Shell Scripts** — Account admin, backups, logs, scheduling, and updates from one CLI
- **Adopts Existing Realms** — Detects your current VMANGOS install instead of forcing a rebuild
- **Built For Operators** — Every dashboard view maps to a real `vmangos-manager` command you can script

---

## Documentation

| Doc | What You'll Find |
|---|---|
| [🚀 User Guide](docs/user-guide.md) | End-to-end walkthrough of the install wizard, dashboard views, and daily rhythm |
| [🔧 Install Automation](docs/install-automation.md) | Deep dive into `auto_install.sh` and `vmangos_setup.sh` (advanced/headless path) |
| [📋 CLI Reference](docs/cli-reference.md) | Complete command reference |
| [🛡️ Security Notes](docs/security.md) | Password handling, DB model, and update safety |
| [🔍 Troubleshooting](docs/troubleshooting.md) | Common problems and diagnostic commands |

---

## What's Included

| Component | What It Does | Status |
|---|---|---|
| 🧙 **Install Wizard** | `vmangos-manager install` — forms, review, detachable systemd-run install, live viewer, checkpoint retry |
| 🖥️ **Dashboard** | 7-view Textual TUI for live server ops |
| 🛠️ **Install Scripts** | `auto_install.sh` + `vmangos_setup.sh` (advanced/headless path) |
| 🎮 **Server Control** | Start, stop, restart, and health-check `auth` + `world` |
| 👤 **Account Admin** | Create, ban/unban, set GM level, password reset |
| 💾 **Backups** | SQL dumps, verify integrity, dry-run + guarded preflight restore, timer scheduling |
| 📝 **Logs** | Filtered `auth`/`world` log investigation via `journald` |
| ⏰ **Scheduling** | `systemd` timer generation for restarts and maintenance |
| 🔄 **Update Planning** | Check, inspect, plan, and apply core + DB updates |

---

## Quick Start

### Prerequisites

- **Ubuntu 22.04, 24.04, or 26.04 LTS** (fresh or existing) — each is exercised in CI
- Root access (`sudo`)
- `python3-venv` on the host if you want the dashboard (`sudo apt-get install -y python3-venv`)
- WoW 1.12.1 client data (for extraction)

Manager installs and runs read-only against a host before any realm exists, and
tells you its exact release and build:

```bash
/opt/mangos/manager/bin/vmangos-manager --version
# VMANGOS Manager version 0.7.0
#   build: git=2a55757 describe=v0.6.0-4-g2a55757 built=2026-10-29T05:52:03Z
```

### Option A — Fresh Host: the Install Wizard (recommended)

```bash
git clone https://github.com/tonymontoya/VMaNGOS-Manager.git
cd VMaNGOS-Manager
sudo ./manager/bin/vmangos-manager install --bootstrap  # one-time (Textual deps)
sudo ./manager/bin/vmangos-manager install              # the wizard
```

The wizard walks you through the forms (install root, client data path, database names and credentials), shows a review, and launches the install as its own systemd unit: **closing the TUI never stops it** — re-run `install` to re-attach, and a failed phase offers Retry from the last checkpoint. See the [User Guide](docs/user-guide.md) for the full walkthrough.

### Headless Installs (advanced)

For automation or hosts where a TUI is impractical, the raw scripts remain in-tree:

```bash
wget https://raw.githubusercontent.com/tonymontoya/VMaNGOS-Manager/main/auto_install.sh
wget https://raw.githubusercontent.com/tonymontoya/VMaNGOS-Manager/main/vmangos_setup.sh

# Run automated provisioning (VMANGOS + Manager, auto-generated credentials)
sudo bash auto_install.sh
```

To pick your own DB names and paths non-interactively, drive `vmangos_setup.sh` directly with environment variables — see the [Install Automation Reference](docs/install-automation.md).

### Option B — Existing VMANGOS Host

```bash
git clone https://github.com/tonymontoya/VMaNGOS-Manager.git
cd VMaNGOS-Manager/manager
make test
sudo make install PREFIX=/opt/mangos/manager
sudo /opt/mangos/manager/bin/vmangos-manager config detect
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --bootstrap
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --refresh 2
```

---

## The Dashboard

Launch the UI in two commands:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --bootstrap  # one-time
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --refresh 2  # run
```

(First install the realm with `vmangos-manager install` — see Option A above.)

### Dashboard Views

| View | Purpose | Screenshot |
|---|---|---|
| **Overview** | Realm pulse: services, host metrics, players, alerts | ![Overview](docs/assets/dashboard-overview.svg) |
| **Monitor** | Deep diagnostics: trends, disk I/O, process footprint | ![Monitor](docs/assets/dashboard-monitor.svg) |
| **Accounts** | Create, reset passwords, set GM, ban/unban | ![Accounts](docs/assets/dashboard-accounts.svg) |
| **Backups** | Inventory, verify, dry-run, schedule timers | ![Backups](docs/assets/dashboard-backups.svg) |
| **Config** | Read-only wiring validation | ![Config](docs/assets/dashboard-config.svg) |
| **Logs** | Filtered `auth`/`world` log investigation | ![Logs](docs/assets/dashboard-logs.svg) |
| **Operations** | Maintenance readiness, scheduled tasks, update planning | ![Operations](docs/assets/dashboard-operations.svg) |

---

## Everyday CLI

```bash
# Server control
sudo /opt/mangos/manager/bin/vmangos-manager server start --wait
sudo /opt/mangos/manager/bin/vmangos-manager server restart
sudo /opt/mangos/manager/bin/vmangos-manager server status --watch

# Account admin
sudo VMANGOS_PASSWORD='ChangeMe7' /opt/mangos/manager/bin/vmangos-manager account create TESTUSER --password-env
sudo /opt/mangos/manager/bin/vmangos-manager account setgm TESTUSER 3
sudo /opt/mangos/manager/bin/vmangos-manager account ban TESTUSER 7d --reason "Exploit abuse"

# Backup + schedule
sudo /opt/mangos/manager/bin/vmangos-manager backup now --verify
sudo /opt/mangos/manager/bin/vmangos-manager backup schedule --daily 04:00

# Logs + maintenance
sudo /opt/mangos/manager/bin/vmangos-manager logs recent --source world --severity error --limit 25
sudo /opt/mangos/manager/bin/vmangos-manager schedule restart --time 04:00 --weekly Sun
```

---

## Security & Safety

- **No positional passwords** — Passwords are accepted via interactive prompt, `--password-file`, or `--password-env` only
- **File permissions enforced** — Password files must be mode `600` and owned by a trusted user
- **Audit logging** — Every account action is logged with actor and target
- **Fail-closed updates** — `update apply` rejects dirty source trees and unsupported SQL changes

See [Security Notes](docs/security.md) for full details.

---

## Community & Resources

- [VMANGOS Core](https://github.com/vmangos/core)
- [VMANGOS Database](https://github.com/brotalnia/database)
- [VMANGOS Wiki](https://github.com/vmangos/wiki/wiki)
- [GitHub Issues](https://github.com/tonymontoya/VMaNGOS-Manager/issues)

---

## License & Disclaimer

This project is for educational purposes. Running a private WoW server may violate Blizzard's Terms of Service. Use at your own risk.
