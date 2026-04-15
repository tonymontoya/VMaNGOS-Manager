# VMANGOS Manager

![CI](https://github.com/tonymontoya/VMANGOS-Manager/actions/workflows/ci.yml/badge.svg)
![Ubuntu 22.04](https://img.shields.io/badge/ubuntu-22.04-E95420)
![Status](https://img.shields.io/badge/status-v0.2%20candidate-0f766e)
![Interface](https://img.shields.io/badge/interface-Textual%20TUI-0f172a)

A terminal-native administration suite for VMANGOS private servers. One installer, one CLI, and a live SSH-native dashboard for everything from provisioning to backups.

![VMANGOS Manager Dashboard](docs/assets/dashboard-overview.svg)

*Real screenshot from the shipped Textual dashboard — not a mockup.*

---

## 🏰 Why VMANGOS Manager?

- **One-Shot Provisioning** — Go from blank Ubuntu 22.04 to a running realm with a single script
- **SSH-Native Dashboard** — A real Textual TUI that runs directly on the server over SSH
- **No More Shell Scraps** — Account admin, backups, logs, scheduling, and updates from one CLI
- **Adopts Existing Realms** — Detects your current VMANGOS install instead of forcing a rebuild
- **Built For Operators** — Every dashboard view maps to a real `vmangos-manager` command you can script

---

## ✨ What's Included

| Component | What It Does | Status |
|---|---|---|
| 🖥️ **Dashboard** | 7-view Textual TUI for live server ops | ✅ Shipped |
| 🚀 **Auto-Installer** | `auto_install.sh` + `vmangos_setup.sh` for Ubuntu 22.04 | ✅ Shipped |
| 🎮 **Server Control** | Start, stop, restart, and health-check `auth` + `world` | ✅ Shipped |
| 👤 **Account Admin** | Create, ban/unban, set GM level, password reset | ✅ Shipped |
| 💾 **Backups** | SQL dumps, verify integrity, dry-run restore, timer scheduling | ✅ Shipped |
| 📝 **Logs** | Filtered `auth`/`world` log investigation via `journald` | ✅ Shipped |
| ⏰ **Scheduling** | `systemd` timer generation for restarts and maintenance | ✅ Shipped |
| 🔄 **Update Planning** | Check, inspect, plan, and apply core + DB updates | ✅ Shipped |

---

## 🚀 Quick Start

### Prerequisites

- Ubuntu 22.04 LTS (fresh or existing)
- Root access (`sudo`)
- WoW 1.12.1 client data (for extraction — optional but recommended)

### Option A — Fresh Host

```bash
# Download the installer scripts
wget https://raw.githubusercontent.com/tonymontoya/VMANGOS-Manager/main/auto_install.sh
wget https://raw.githubusercontent.com/tonymontoya/VMANGOS-Manager/main/vmangos_setup.sh

# Run automated provisioning (VMANGOS + Manager, auto-generated credentials)
sudo bash auto_install.sh
```

Want to pick your own DB names and paths? Use the guided installer instead:

```bash
wget https://raw.githubusercontent.com/tonymontoya/VMANGOS-Manager/main/vmangos_setup.sh
sudo bash vmangos_setup.sh
```

### Option B — Existing VMANGOS Host

```bash
git clone https://github.com/tonymontoya/VMANGOS-Manager.git
cd VMANGOS-Manager/manager
make test
sudo make install PREFIX=/opt/mangos/manager
sudo /opt/mangos/manager/bin/vmangos-manager config detect
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --bootstrap
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --refresh 2
```

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Textual Dashboard                       │
│              (Python / Textual TUI over SSH)                │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    vmangos-manager CLI                      │
│  (Bash entry point: server / account / backup / logs /      │
│   schedule / config / update / dashboard)                   │
└─────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        ▼                     ▼                     ▼
┌───────────────┐    ┌───────────────┐    ┌───────────────┐
│  systemd      │    │  MariaDB      │    │  logrotate    │
│  (auth/world) │    │  (auth/char/  │    │  (realm logs) │
│               │    │  world/logs)  │    │               │
└───────────────┘    └───────────────┘    └───────────────┘
```

**Stack:**
- **CLI:** Bash 4+, `shellcheck`-clean modules
- **Dashboard:** Python 3, Textual
- **Databases:** MariaDB / MySQL
- **Init:** `systemd` services and timers
- **Target OS:** Ubuntu 22.04 LTS

---

## 🖥️ The Dashboard

Launch the TUI in two commands:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --bootstrap  # one-time
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --refresh 2  # run
```

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

## 🛠️ Everyday CLI

```bash
# Server control
sudo vmangos-manager server start --wait
sudo vmangos-manager server restart
sudo vmangos-manager server status --watch

# Account admin
sudo VMANGOS_PASSWORD='ChangeMe7' vmangos-manager account create TESTUSER --password-env
sudo vmangos-manager account setgm TESTUSER 3
sudo vmangos-manager account ban TESTUSER 7d --reason "Exploit abuse"

# Backup + schedule
sudo vmangos-manager backup now --verify
sudo vmangos-manager backup schedule --daily 04:00

# Logs + maintenance
sudo vmangos-manager logs recent --source world --severity error --limit 25
sudo vmangos-manager schedule restart --time 04:00 --weekly Sun
```

---

## 📚 Documentation

| Doc | What You'll Find |
|---|---|
| [🚀 User Guide](docs/user-guide.md) | End-to-end walkthrough of install, dashboard views, and daily rhythm |
| [🔧 Install Automation](docs/install-automation.md) | Deep dive into `auto_install.sh` and `vmangos_setup.sh` |
| [📋 CLI Reference](docs/cli-reference.md) | Complete command reference |
| [🛡️ Security Notes](docs/security.md) | Password handling, DB model, and update safety |
| [🔍 Troubleshooting](docs/troubleshooting.md) | Common problems and diagnostic commands |

---

## 🛡️ Security & Safety

- **No positional passwords** — Passwords are accepted via interactive prompt, `--password-file`, or `--password-env` only
- **File permissions enforced** — Password files must be mode `600` and owned by a trusted user
- **Audit logging** — Every account action is logged with actor and target
- **Fail-closed updates** — `update apply` rejects dirty source trees and unsupported SQL changes

See [Security Notes](docs/security.md) for full details.

---

## 💬 Community & Resources

- [VMANGOS Core](https://github.com/vmangos/core)
- [VMANGOS Database](https://github.com/brotalnia/database)
- [VMANGOS Wiki](https://github.com/vmangos/wiki/wiki)
- [GitHub Issues](https://github.com/tonymontoya/VMANGOS-Manager/issues)

---

## ⚖️ License & Disclaimer

This project is for educational purposes. Running a private WoW server may violate Blizzard's Terms of Service. Use at your own risk.

---

**Built for realm operators who want their tools to feel like software, not glue.**
