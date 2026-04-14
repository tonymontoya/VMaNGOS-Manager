# User Guide

VMaNGOS Manager is at its best when you use it as a complete operator layer, not just a pile of commands. This guide is the shortest path to that outcome.

It shows you how to:

- bring Manager onto a fresh or existing VMaNGOS host
- launch the dashboard and understand each screen
- use the built-in workflows for accounts, backups, config checks, logs, schedules, and update planning
- settle into a practical daily operating routine

All screenshots in this guide are generated from the shipped dashboard renderer against a reproducible demo snapshot.

## Choose Your Starting Path

### Fresh Ubuntu 22.04 Host

Use the installer when you want Manager to help bring the whole realm online.

Fast path:

```bash
wget https://raw.githubusercontent.com/tonymontoya/VMANGOS-Manager/main/auto_install.sh
wget https://raw.githubusercontent.com/tonymontoya/VMANGOS-Manager/main/vmangos_setup.sh
sudo bash auto_install.sh
```

Use this when you want:

- the lowest-friction way to provision `VMANGOS + Manager`
- generated credentials and sane defaults
- one repeatable installer path instead of a private host checklist

If you want more control during install, use:

```bash
wget https://raw.githubusercontent.com/tonymontoya/VMANGOS-Manager/main/vmangos_setup.sh
sudo bash vmangos_setup.sh
```

That guided path lets you choose install root, DB values, provisioning target, and related host settings.

For deeper installer details, use the [install automation reference](install-automation.md).

### Existing VMaNGOS Host

If the realm is already running, Manager can adopt it without forcing a rebuild.

```bash
git clone https://github.com/tonymontoya/VMANGOS-Manager.git
cd VMANGOS-Manager/manager
make test
sudo make install PREFIX=/opt/mangos/manager
sudo /opt/mangos/manager/bin/vmangos-manager config detect
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --bootstrap
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --refresh 2
```

The key step is `config detect`. It gives Manager a read-only first pass at your existing realm layout so you are not wiring every path, service, and database by hand.

## First Dashboard Launch

After Manager is installed, bootstrap the Textual runtime once:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --bootstrap
```

Then launch the operator console:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --refresh 2
```

The dashboard is organized into five views:

- `Overview`
- `Accounts`
- `Backups`
- `Config`
- `Ops`

The footer shows the most important hotkeys for the active screen, while the sidebar keeps the realm pulse visible at all times.

If you are new to Manager, the best first pass is simple:

1. Start in `Overview` and make sure the host and services look sane.
2. Visit `Config` and verify Manager is reading the right install root, service names, and databases.
3. Visit `Backups` and confirm the protection story before you trust any update or maintenance workflow.
4. Visit `Accounts` so you know where user actions live before you need them under pressure.
5. Finish in `Ops` and review scheduled work, logs, and update state.

## Overview View

![Overview view](assets/dashboard-overview.svg)

This is the screen you leave open when you want live awareness of the realm.

What it is best at:

- checking whether `auth` and `world` are healthy
- seeing CPU, memory, load, disk, player count, and short-term trends
- spotting whether players are actually online
- jumping quickly into stop, start, restart, backup, verify, and config validation actions

Use this view when:

- you just logged into the host
- you are validating that a restart actually settled
- you want a top-like operational snapshot instead of several separate shell commands

## Accounts View

![Accounts view](assets/dashboard-accounts.svg)

This is where Manager starts feeling like a real realm admin tool instead of a command wrapper.

Use the Accounts view when you need to:

- create a new account
- reset a password
- assign or remove GM levels
- ban or unban a user
- inspect whether an account is online or already restricted

Recommended flow:

1. Move to `Accounts` with `2`.
2. Highlight the account you care about.
3. Use the hotkeys shown in the footer: `c`, `p`, `g`, `n`, `u`.
4. Let the dashboard feed you back into the updated table state after the action completes.

This is especially useful for GMs and operators who do not want to remember a pile of account-management command forms.

## Backups View

![Backups view](assets/dashboard-backups.svg)

The Backups view turns backup inventory into something you can actually inspect and act on.

Use it to:

- see what backups exist
- confirm when the latest backup was taken
- verify a backup before trusting it
- dry-run a restore plan
- queue daily or weekly backup scheduling

Recommended habit:

1. Use `b` to create a new backup before risky maintenance.
2. Use `v` to verify important backups instead of assuming the archive is good.
3. Use `d` to review a restore dry-run before a real restore event ever happens.

This is one of the biggest quality-of-life wins in Manager. Backup discipline becomes part of the normal operator experience instead of a separate ritual.

## Config View

![Config view](assets/dashboard-config.svg)

Config is the confidence screen. It tells you how Manager understands the host it is running on.

Use it to:

- validate the current `manager.conf`
- confirm install root, service names, database host, and DB names
- sanity-check backup directory wiring
- preview the effective config without opening files manually

This screen is especially valuable after:

- adopting an existing host
- changing service names or install paths
- reinstalling Manager onto a machine with an older realm layout

If the Config view looks wrong, fix that before you trust any higher-level workflow.

## Operations View

![Operations view](assets/dashboard-operations.svg)

Operations is where the day-two admin workflows come together.

Use it for:

- log rotation health and test runs
- scheduled honor or restart jobs
- schedule cancellation
- update planning and DB-impact awareness

This screen is the best answer to, "What maintenance is queued, and what happens if I update now?"

Recommended flow before a realm update:

1. Review the update state and DB-impact summary.
2. Generate or refresh the update plan.
3. Take and verify a backup.
4. Only then move into a real update workflow.

## Updates Workflow

Manager treats updates like an operator workflow, not a blind pull-and-pray event.

Use this sequence:

1. Open `Ops` and review the current update state.
2. Check whether the update is code-only or likely to include database work.
3. Create and verify a backup before you touch the source tree.
4. Run the update plan so the work is visible as explicit steps.
5. Execute the update during a maintenance window instead of improvising live.

Why this matters:

- you can see whether Manager thinks the local checkout is clean, behind, or diverged
- you get DB-impact awareness before you are halfway through an update
- you keep backup verification attached to the same workflow instead of relying on memory

The goal is not to make updates look risk-free. The goal is to surface the important facts early enough that the operator stays in control.

## Daily Operating Routine

If you want a stable realm without living in the CLI all day, this is a good default rhythm:

1. Open `Overview` and confirm services, players, and host pressure look sane.
2. Check `Backups` and make sure recent protection exists before risky work.
3. Visit `Operations` when planning maintenance, restart jobs, or update work.
4. Use `Accounts` for user-facing admin changes instead of one-off SQL.
5. Use `Config` whenever the host wiring changes or Manager behavior looks suspicious.

## When To Drop To The CLI

The dashboard should be your main control surface, but the CLI still matters when you need:

- direct automation in shell scripts
- raw JSON output for integration or debugging
- non-interactive host workflows
- command-by-command precision for an unusual task

Use these supporting docs when you need that lower-level surface:

- [CLI reference](cli-reference.md)
- [Troubleshooting](troubleshooting.md)
- [Security notes](security.md)

## Final Advice

Manager is strongest when you let it be the place where routine realm operations live.

Install it cleanly, validate the config early, keep the dashboard close at hand, and treat backups and update planning as first-class workflows instead of afterthoughts.
