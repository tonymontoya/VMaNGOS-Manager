# User Guide

VMaNGOS Manager is at its best when you use it as a complete operator layer, not just a pile of commands. This guide is the shortest path from install to confident day-to-day operation.

It shows you how to:

- bring Manager onto a fresh or existing VMaNGOS host
- launch the dashboard and understand each screen
- use the built-in workflows for monitoring, accounts, backups, config checks, logs, schedules, and update planning
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

The dashboard is organized into six views:

- `Overview`
- `Monitor`
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

- summary panels answer the operator question first
- detail panes belong to the selected row or selected object

If a panel starts mixing realm-wide counters into a selected-item view, that is usually an IA defect, not an operator requirement.

If you are new to Manager, the best first pass is simple:

1. Start in `Overview` and make sure the host and services look sane.
2. Visit `Monitor` when you want to understand host pressure, disk saturation, or realm process footprint in more detail.
3. Visit `Config` and verify Manager is reading the right install root, service names, and databases.
4. Visit `Backups` and confirm the protection story before you trust any update or maintenance workflow.
5. Visit `Accounts` so you know where user actions live before you need them under pressure.
6. Finish in `Ops` and review the maintenance queue plus change-window readiness.

## Overview View

![Overview view](assets/dashboard-overview.svg)

This is the screen you leave open when you want live awareness of the realm.

What it is best at:

- checking whether `auth` and `world` are healthy
- seeing headline CPU, memory, load, disk, player count, and short-term trends
- spotting whether players are actually online and whether staff are present
- jumping quickly into stop, start, restart, backup, verify, and config validation actions

Use this view when:

- you just logged into the host
- you are validating that a restart actually settled
- you want a top-like operational snapshot instead of several separate shell commands
- you want to know whether to worry before you move into the deeper `Monitor` screen

Panel roles in this view:

- `Realm Services` is the fast service and DB pulse plus per-service footprint
- `Host Metrics` is the machine-level headline pressure panel only
- `Player Pulse` is the summary-first population panel: online count, trend, player/staff mix, and GM coverage
- `Alerts and Events` is the fast-read maintenance and risk panel

If `Overview` tells you something is off but not why, switch to `Monitor`. That split is intentional: `Overview` stays summary-first, while `Monitor` carries the denser diagnostic surface.

The full online roster is still available, but it is now a drill-down instead of taking over summary space:

- press `o` from `Overview` to open the live online roster
- press `Enter` from that roster to jump straight into the selected account in `Accounts`

## Monitor View

![Monitor view](assets/dashboard-monitor.svg)

Monitor is the diagnosis screen. It exists so `Overview` can stay fast and readable instead of trying to become a cramped terminal copy of `htop`, `df`, and `iostat` all at once.

Use it when you need to:

- explain CPU, memory, load, disk, or I/O pressure instead of just noticing it
- compare current values against the recent monitoring window
- inspect `auth` and `world` process footprint in one place
- understand whether storage contention is likely driving realm instability

Read it in this order:

1. Start with `Pressure Deck` for the current host picture plus short rolling trends.
2. Move to `Realm Process Footprint` to check whether `auth` or `world` is the source of pressure.
3. Use `Trend Ledger` to compare current values against the recent peak window.
4. Finish with `Storage and Device` when disk saturation, filesystem headroom, or missing `iostat` tooling might explain what you are seeing.

This screen is intentionally denser than `Overview`, but it still follows the same rule: each panel has a clear job. The goal is better diagnosis, not more noise.

If you have room, run the dashboard in a taller terminal before you camp on `Monitor`. It makes the trend and storage panels easier to absorb at a glance.

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

1. Move to `Accounts` with `3`.
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

Still handled in the shell:

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

Still handled in the shell:

- this view is intentionally read-only
- edit `manager.conf` and `.dbpass` in the shell, then return here to validate the result

The panel is grouped into `Realm Wiring`, `Database Wiring`, and `Dashboard Role` so it is easier to spot whether the problem is host wiring, DB targeting, or a workflow misunderstanding.

If the configuration wiring view looks wrong, fix that before you trust any higher-level workflow.

## Operations View

![Operations view](assets/dashboard-operations.svg)

Operations is the maintenance scheduling and change-window screen.

Use it for:

- deciding whether the host is ready for scheduled maintenance
- scheduling maintenance tasks or restart windows from the Ops surface
- seeing what maintenance is already queued
- inspecting or canceling a selected schedule
- reviewing update readiness and DB impact before risky source changes

Read it in this order:

1. Start with `Change Window Readiness` to confirm logs, storage, and queue state look safe enough for maintenance work.
2. Use the on-screen schedule paths to create a maintenance task or scheduled restart from the Ops surface.
3. Review `Scheduled Maintenance` to confirm what is already queued and when it will fire.
4. Use `Selected Schedule` to inspect origin, cadence, warnings, and cancellation impact for the highlighted item.
5. Use `Update Readiness` when the next change involves source pulls or database movement.

Recommended flow before a realm update:

1. Review `Change Window Readiness` so you know whether the host and log posture are healthy enough for the window.
2. Review `Scheduled Maintenance` so you know whether any restart work is already timed near the window.
3. Review `Update Readiness` and the DB-impact summary.
4. Generate or refresh the update plan.
5. Take and verify a backup.
6. Only then move into a real update workflow.

Jobs shown in `Scheduled Maintenance` come from the Ops scheduling actions in the dashboard or the matching `schedule` CLI commands. The command rail still mirrors those paths, but the screen now calls out where maintenance gets created so the queue does not feel detached from the workflow.

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
2. Use `Monitor` when `Overview` shows pressure and you need the deeper host or process explanation.
3. Check `Backups` and make sure recent protection exists before risky work.
4. Visit `Operations` when you need to understand queued maintenance or preflight a risky change window.
5. Use `Accounts` for user-facing admin changes instead of one-off SQL.
6. Use `Config` whenever the host wiring changes or Manager behavior looks suspicious.

## When To Drop To The CLI

The dashboard should be your main control surface, but the CLI still matters when you need:

- direct automation in shell scripts
- raw JSON output for integration or debugging
- non-interactive host workflows
- command-by-command precision for an unusual task

## Dashboard vs CLI

Use the dashboard for everyday operation, then drop to the CLI for the narrower paths listed here:

| Area | Use the dashboard for | Use the CLI for |
| --- | --- | --- |
| Server | summary status, start, stop, restart | text watch mode, raw JSON output |
| Monitor | deeper host diagnostics, trend comparison, process footprint, storage saturation detail | ad hoc host-native tooling and custom one-off investigation |
| Accounts | account inventory, create, password reset, GM changes, ban, unban, account visibility | scripted bulk workflows |
| Backups | backup readiness, inventory, backup now, verify, restore dry-run, timer visibility, daily/weekly timer create | cleanup, timer removal, live restore |
| Config | validation plus read-only configuration wiring summary | config creation, detect, show, and file editing |
| Operations | maintenance queue, maintenance/restart scheduling, schedule cancel, logs guardrails, update planning visibility | update apply and other source-tree workflows |

Use these supporting docs when you need that lower-level surface:

- [CLI reference](cli-reference.md)
- [Troubleshooting](troubleshooting.md)
- [Security notes](security.md)

## Operating Style

Manager is strongest when you let it be the place where routine realm operations live.

Install it cleanly, validate the config early, keep the dashboard close at hand, and treat backups and update planning as first-class workflows instead of afterthoughts.
