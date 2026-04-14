# VMaNGOS Manager

![CI](https://github.com/tonymontoya/VMANGOS-Manager/actions/workflows/ci.yml/badge.svg)
![Ubuntu 22.04](https://img.shields.io/badge/ubuntu-22.04-E95420)
![Release](https://img.shields.io/badge/release-v0.1.0-0f766e)
![Interface](https://img.shields.io/badge/interface-Textual%20TUI-0f172a)

Stop running a VMaNGOS realm from shell scraps, one-off SQL, and tribal knowledge. VMaNGOS Manager turns install, operations, backups, account administration, and update planning into one terminal-native admin product built for real realm operators.

![VMANGOS Manager Textual dashboard](docs/assets/dashboard-overview.svg)

The screenshot above is generated from the shipped dashboard renderer against a reproducible demo snapshot. It is not a painted mockup.

## What You Get

- fresh-host install automation for `VMANGOS only` or `VMANGOS + Manager`
- existing-host adoption through config detection instead of forced rebuilds
- a real Textual TUI you can run directly on the server over SSH
- integrated workflows for accounts, backups, logs, schedules, config checks, and updates
- one operational backend shared by the CLI, dashboard, and automation flows

In practice, that means less time stitching together service commands, SQL snippets, backup habits, and update notes by hand, and more time running the realm from one place.

## Why It Sticks

VMaNGOS already gives communities a strong server core. What it usually does not give them is a polished operator layer.

Manager closes that gap. It helps you bring a host online faster, keep routine admin work in one place, and give your realm a control surface that feels intentional instead of improvised.

## Start The Right Way

### Fresh Host

For a blank Ubuntu 22.04 machine, the repo ships two installer entry points. Both can provision either:

- `VMANGOS only`
- `VMANGOS + Manager`

Both paths support:

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

The installer handles the heavy lifting that usually gets lost in private notes:

- dependency installation and long-build orchestration
- database creation and credentials
- config generation
- client data staging
- manager provisioning under `/opt/mangos/manager`
- dashboard prerequisites when Manager is included

`auto_install.sh` stays non-interactive and defaults to `VMANGOS + Manager` with automated inputs. `vmangos_setup.sh` prompts early for the provisioning target and input mode so the operator knows exactly what path they are taking before the long-running phases start.

### Existing Host

If you already have VMaNGOS running, Manager does not force you into a reinstall story. Install it, detect the local layout, then launch the dashboard:

```bash
git clone https://github.com/tonymontoya/VMANGOS-Manager.git
cd VMANGOS-Manager/manager
make test
sudo make install PREFIX=/opt/mangos/manager
sudo /opt/mangos/manager/bin/vmangos-manager config detect
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --bootstrap
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --refresh 2
```

## The TUI Is The Product Moment

The dashboard is the thing most VMaNGOS admins are not used to getting: a terminal UI that actually feels like a product.

It is not a detached frontend experiment. It runs on the same Manager commands and JSON surfaces used by the CLI, which keeps the interface honest and useful on a real server.

Bootstrap once:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --bootstrap
```

Launch it:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --refresh 2
```

Inside the dashboard you get:

- auth/world service health, PID, uptime, and control actions
- host CPU, memory, disk, load, disk I/O, and short-term monitoring trends
- online player visibility and account inspection
- backup visibility plus verify, schedule, and restore dry-run entry points
- account workflows for create, password reset, GM level changes, and ban or unban actions
- log rotation and config visibility for safer day-two operations

It keeps the deployment terminal-first while still giving admins something that looks and feels deliberate.

## Learn The Product

- [User guide](docs/user-guide.md)
- [Install automation reference](docs/install-automation.md)
- [CLI reference](docs/cli-reference.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Security notes](docs/security.md)

Start with the user guide if you want the best end-to-end walkthrough of what Manager can do.

## Why Trust It

- validated on a real Ubuntu VMaNGOS host, not just mocked local shell tests
- the dashboard screenshot in this README is generated from the shipped Textual app export path using a reproducible demo payload
- the test suite covers config, status, logs, schedule, backup, update, account, and dashboard seams

## VMaNGOS Context

VMaNGOS is an independent continuation of the Elysium/LightsHope codebases focused on accurate Vanilla WoW content progression across patch eras from 1.2 through 1.12.1.

## Resources

- [VMaNGOS Core](https://github.com/vmangos/core)
- [VMaNGOS Database](https://github.com/brotalnia/database)
- [VMaNGOS Wiki](https://github.com/vmangos/wiki/wiki)
- [Issue Tracker](https://github.com/tonymontoya/VMANGOS-Manager/issues)

## License & Disclaimer

This project is for educational purposes. Running a private WoW server may violate Blizzard's Terms of Service. Use at your own risk.
