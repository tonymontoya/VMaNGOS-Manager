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

The command rail shows the most important actions for the active screen, while the sidebar keeps navigation and realm pulse visible at all times.

## How To Read The Screen

The dashboard works best when each region has a clear job:

- the top banner tells you the active view, why that view exists, and the result of the last action
- the sidebar is always-on navigation plus realm pulse
- the command rail is the single action surface for navigation, refresh, and view-specific work
- the main panels are where view-specific work happens

The rule to keep in mind is simple:

- summary counts belong in summary panels
- detail panes belong to the selected row or selected object

If a panel starts mixing realm-wide counters into a selected-item view, that is usually an IA defect, not an operator requirement.

If you are new to Manager, the best first pass is simple:

1. Start in `Overview` and make sure the host and services look sane.
2. Visit `Config` and verify Manager is reading the right install root, service names, and databases.
3. Visit `Backups` and confirm the protection story before you trust any update or maintenance workflow.
4. Visit `Accounts` so you know where user actions live before you need them under pressure.
5. Finish in `Ops` and review the maintenance queue plus change-window readiness.

## Overview View

![Overview view](assets/dashboard-overview.svg)

This is the screen you leave open when you want live awareness of the realm.

What it is best at:

- checking whether `auth` and `world` are healthy
- seeing CPU, memory, load, disk, player count, and short-term trends
- spotting whether players are actually online and whether staff are present
- jumping quickly into stop, start, restart, backup, verify, and config validation actions

Use this view when:

- you just logged into the host
- you are validating that a restart actually settled
- you want a top-like operational snapshot instead of several separate shell commands

Panel roles in this view:

- `Realm Services` is the fast service and DB pulse plus per-service footprint
- `Host Metrics` is the machine-level pressure and capacity panel only
- `Player Pulse` is the summary-first population panel: online count, trend, player/staff mix, and GM coverage
- `Alerts and Events` is the fast-read maintenance and risk panel

The full online roster is still available, but it is now a drill-down instead of taking over summary space:

- press `o` from `Overview` to open the live online roster
- press `Enter` from that roster to jump straight into the selected account in `Accounts`

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
3. Use the command rail actions for this view: `c`, `p`, `g`, `n`, `u`.
4. Let the dashboard feed you back into the updated table state after the action completes.

This is especially useful for GMs and operators who do not want to remember a pile of account-management command forms.

In this view, `Account Inventory` is the inventory and `Selected Account` is the action surface. Global counts should not be mixed into that right-hand pane.

## Backups View

![Backups view](assets/dashboard-backups.svg)

The Backups view turns backup inventory into something you can actually inspect and act on.

Use it to:

- see what backups exist
- confirm when the latest backup was taken
- verify a backup before trusting it
- dry-run a restore plan
- review the currently configured backup timers
- queue daily or weekly backup scheduling

Recommended habit:

1. Use `b` to create a new backup before risky maintenance.
2. Use `v` to verify important backups instead of assuming the archive is good.
3. Use `d` to review a restore dry-run before a real restore event ever happens.

This is one of the biggest quality-of-life wins in Manager. Backup discipline becomes part of the normal operator experience instead of a separate ritual.

Current boundary:

- the dashboard shows protection posture, backup inventory, and configured timer state
- `Backup Readiness` is the summary and selected-backup decision panel
- `Backup Inventory` is the archive list you browse and act from
- creating or replacing daily and weekly backup timers is available in the dashboard
- cleanup policy changes, timer removal, and deeper backup surgery still live in the CLI or systemd today

## Config View

![Config view](assets/dashboard-config.svg)

Config is the confidence screen. It tells you how Manager understands the host it is running on.

Use it to:

- validate the current `manager.conf`
- confirm install root, service names, database host, and DB names
- sanity-check backup directory wiring
- confirm how Manager is sourcing DB credentials without exposing them in plaintext

This screen is especially valuable after:

- adopting an existing host
- changing service names or install paths
- reinstalling Manager onto a machine with an older realm layout

Release C boundary:

- this view is intentionally read-only
- edit `manager.conf` and `.dbpass` in the shell, then return here to validate the result

The panel is grouped into `Realm Wiring`, `Database Wiring`, and `Dashboard Role` so it is easier to spot whether the problem is host wiring, DB targeting, or a workflow misunderstanding.

If the configuration wiring view looks wrong, fix that before you trust any higher-level workflow.

## Operations View

![Operations view](assets/dashboard-operations.svg)

Operations is the maintenance queue and change-window preflight screen.

Use it for:

- seeing what maintenance is already queued
- inspecting or canceling a selected honor or restart job
- checking log guardrails before a maintenance window
- reviewing update readiness and DB impact before risky source changes

Read it in this order:

1. Start with `Maintenance Queue` to see what restart or honor work is already scheduled.
2. Use `Selected Job` to inspect cadence, warnings, and cancellation impact for the highlighted item.
3. Glance at `Maintenance Guardrails` to confirm logs and storage are not about to betray the window.
4. Use `Update Readiness` when the next change involves source pulls or database movement.

Recommended flow before a realm update:

1. Review `Maintenance Queue` so you know whether any restart work is already timed near the window.
2. Review `Update Readiness` and the DB-impact summary.
3. Generate or refresh the update plan.
4. Take and verify a backup.
5. Only then move into a real update workflow.

The command rail follows the same hierarchy as the screen: queue actions first, then update planning, then log guardrail actions. If a task is not in the rail, it is probably still a CLI-first path for now.

## Updates Workflow

Manager treats updates like an operator workflow, not a blind pull-and-pray event.

Use this sequence:

1. Open `Ops` and start with the maintenance queue so you understand what is already scheduled.
2. Check `Update Readiness` to see whether the change is code-only or likely to include database work.
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
3. Visit `Operations` when you need to understand queued maintenance or preflight a risky change window.
4. Use `Accounts` for user-facing admin changes instead of one-off SQL.
5. Use `Config` whenever the host wiring changes or Manager behavior looks suspicious.

## When To Drop To The CLI

The dashboard should be your main control surface, but the CLI still matters when you need:

- direct automation in shell scripts
- raw JSON output for integration or debugging
- non-interactive host workflows
- command-by-command precision for an unusual task

## Dashboard Coverage Today

This is the current dashboard-to-CLI split for Release C:

| Area | In dashboard now | Still outside the dashboard |
| --- | --- | --- |
| Server | status, start, stop, restart | text watch mode, raw JSON output |
| Accounts | account inventory, create, password reset, GM changes, ban, unban, account visibility | scripted bulk workflows |
| Backups | backup readiness, inventory, backup now, verify, restore dry-run, timer visibility, daily/weekly timer create | cleanup, timer removal, live restore |
| Config | validation plus read-only configuration wiring summary | config creation, detect, show, and file editing |
| Operations | maintenance queue, honor and restart scheduling, schedule cancel, logs guardrails, update planning visibility | update apply and other source-tree workflows |

Use these supporting docs when you need that lower-level surface:

- [CLI reference](cli-reference.md)
- [Troubleshooting](troubleshooting.md)
- [Security notes](security.md)

## Final Advice

Manager is strongest when you let it be the place where routine realm operations live.

Install it cleanly, validate the config early, keep the dashboard close at hand, and treat backups and update planning as first-class workflows instead of afterthoughts.
