# Install-wizard smoke (issue #104)

A real, end-to-end install smoke. It runs the install-wizard stack — the
wizard TUI, the runner (`manager/lib/installer.sh`), `vmangos_setup.sh`, the
marker protocol, and the viewer — against **reality**: the install is
launched by driving `vmangos-manager install` in a pty like a user (gate
button, typed form answers, review confirm), real apt, real MySQL/MariaDB, a
real MangOS build, real MPQ extraction, real systemd services, real markers,
and a real verified retry. It exercises the #104 acceptance scenarios plus
two folded-in additions:

* the **transient-unit name-recreation edge** after a completed run, and
* **watching for the known viewer flake** (issue #113) under long runs.

Everything runs inside a throwaway privileged systemd Docker container. It
**never** touches bds (the live realm). The client-data cache is kept on the
host and re-mounted on every run, so re-smokes are cheap.

## Why a privileged systemd container

The install runner launches the install as a transient systemd unit
(`systemd-run --unit=vmangos-install --collect`) and the viewer polls
`systemctl`/`journalctl`. To validate that for real, the container must run
systemd as PID 1. The base image installs systemd; two things are load-bearing
and easy to break (see the `Dockerfile`):

* **No** `VOLUME ["/sys/fs/cgroup"]` — a Docker volume shadows the cgroup
  filesystem with ext4 and systemd dies (exit 255).
* Run with `--privileged --cgroupns=host` so the container sees the host
  cgroup2 hierarchy, which is writable under `--privileged`.

## Prerequisites

* Docker (daemon reachable, no sudo needed in this environment).
* A client-data directory with `base.MPQ` (defaults to `/home/tony/Data`;
  override with `--client-data PATH`).
* Network access (apt, github.com, PyPI).

## Run

```sh
# Full smoke (build image -> container -> manager -> TUI launch -> scenarios
# -> watch to completion -> verify -> teardown). ~4.5 h on a 10-core
# workstation (MoveMapGen dominates — see Runtime expectations).
tests/smoke/wizard_smoke.sh

# A single phase (each is independently testable):
tests/smoke/wizard_smoke.sh --phase build-image
tests/smoke/wizard_smoke.sh --phase setup
tests/smoke/wizard_smoke.sh --phase manager
tests/smoke/wizard_smoke.sh --phase tui-launch
tests/smoke/wizard_smoke.sh --phase tui-attach
tests/smoke/wizard_smoke.sh --phase kill-reattach
tests/smoke/wizard_smoke.sh --phase failure-retry
tests/smoke/wizard_smoke.sh --phase watch
tests/smoke/wizard_smoke.sh --phase completion
tests/smoke/wizard_smoke.sh --phase name-recreation
tests/smoke/wizard_smoke.sh --phase flake-watch
tests/smoke/wizard_smoke.sh --phase teardown

# Keep the container for inspection (skip teardown):
tests/smoke/wizard_smoke.sh --keep
```

Tear down and prepare for a fresh run (keeps the client-data cache):

```sh
tests/smoke/reset.sh
```

## How the TUI is driven

The wizard is not bypassed: `tui-launch` runs `vmangos-manager install`
inside a detached tmux session (a real pty with a fixed 140x60 size), feeds
keystrokes with `tmux send-keys`, and asserts on the rendered screen text
(`tmux capture-pane` gives plain text, no ANSI noise). The keystroke script:
Enter (gate continue) → Tab, type the client-data path, Tab x11, Enter
(review) → Tab, Enter (confirm & start) → Enter (follow the install — the
viewer attaches) → q (detach). Every screen is captured to
`/tmp/vmangos-smoke-evidence/` **on the host** (override with
`SMOKE_EVIDENCE_DIR`) and printed into the smoke log. The wizard itself
writes the secrets file and starts the unit — the smoke never pre-writes
secrets or calls the runner directly on the launch path.

## What each scenario checks

| Scenario | Assertion |
|---|---|
| `tui-launch` | Gate → form → review → launch → follow (viewer attaches) → q (detach) driven in a pty; the TUI writes the secrets (right values, mode 600) and starts the unit (`ActiveState=active`); the app exits 0 after detaching; screen evidence captured. |
| `tui-attach` | Re-running `install` while the unit runs attaches the live viewer (checklist renders); `q` detaches, the app exits 0, and the unit **keeps running**. |
| `kill-reattach` | Kill the viewer's journal session; the unit **keeps running**; re-attach works. |
| `failure-retry` | Stop the unit after the first phase checkpoint; the runner's retry path (`installer_unit_stop` + `installer_unit_start` — what the FailureScreen's Retry runs) restarts it. Resume is **verified three ways**: the retried invocation logs `Resuming from checkpoint: <captured>`, no completed phase re-ran (prerequisites never starts again), and the checkpoint then advances past the captured one. |
| `watch` | Markers stream until the terminal `phase=install event=done` marker. |
| `completion` | Terminal marker present; `auth` + `world` services active; realmlist fields (`server_ip`/`auth_port`/`world_port`) present. |
| `name-recreation` | After a completed run, the runner re-creates the unit name (`installer_unit_start`) and the unit runs our installer; it is stopped again via `installer_unit_stop` (a real re-install goes through the wizard's gate — this exercises the `--collect` name edge). |
| `flake-watch` | The viewer async suite is re-run N times (`SMOKE_FLAKE_RUNS`, default 5). A reproduction of the known unit-state detection race (#113 — both `test_viewer_detects_unit_failure_without_markers` and its sibling `..._unit_ended_without_completion`) is captured — log + traceback — and **tolerated**; any other failure is unknown and fails the smoke. |

## Runtime expectations

A full clean run is **~4.5 hours** on a 10-core workstation. The breakdown
(from a recorded run): image build + container + manager + TUI launch ~3 min;
prerequisites ~5 min; database (mysql-server install) ~1 min; source ~1 min;
MangOS build ~5 min; DBC/map + vmap extraction ~2 min; **MoveMapGen ~2.5 h**;
db import ~1-2 min; service bring-up ~1 min. MoveMapGen is single-threaded
and generates mmaps for every map that has vmaps — the two large continent
maps (Elwynn Forest, Dustwallow Marsh) each take well over an hour — so it is
the dominant cost and the only reason a clean run can exceed 4 h. The `watch`
phase has a **6 h** ceiling by default (`SMOKE_WATCH_TIMEOUT` /
`SMOKE_INSTALL_TIMEOUT` to override). `failure-retry` waits for the first
phase checkpoint before forcing its failure (prerequisites' real apt, ~5 min;
`SMOKE_PREREQS_TIMEOUT`, default 25 min, and `SMOKE_ADVANCE_TIMEOUT`,
default 15 min, bound the two waits).

If you only need to re-exercise the viewer/runner (not the full build),
snapshot the container after the source phase (`docker commit`) so a re-smoke
can start from `SOURCE_DONE` — the build + extraction + db-import phases are
the expensive, already-proven part. This stays a manual README-only
optimization; the smoke itself does not automate it.

The client-data cache (`/home/tony/Data`, ~5.2 GB of MPQs) is mounted read-only
and kept across runs, so the extraction/db-import phases are reproducible
without re-downloading.

## Findings

* **Extraction on a read-only client-data mount (fixed, this branch):**
  `mapextractor` resolves every archive through a `Data/` entry — it opens
  `<root>/Data/<file>.MPQ`. A bare top-level MPQ directory (like a mounted
  client-data folder) needs a `Data -> .` self-symlink to satisfy that layout;
  a working install ships exactly that. `prepare_extraction_root` used to
  return early whenever the service user could read the MPQs directly, which
  skipped the symlink entirely — fine on a writable client dir, but on a
  read-only mount the self-symlink can never be created and the extractor
  fails with `Invalid Map.dbc file format!` / `Extracted 0 DBC files`. The
  function now guarantees a `Data/`-resolvable root, cheapest first: use the
  client dir if it already exposes `Data/`; add the self-symlink in place if
  the dir is writable; otherwise stage a **symlink farm** in
  `$INSTALLROOT/client-data` (per-MPQ symlinks + `Interface` + `Data -> .`),
  reusing a valid staging root across resumes. A full copy remains the last
  resort when the client data is not readable by the service user at all.
  Verified by running the real `mapextractor` against a `:ro` mount
  (158 DBCs + 2429 maps extracted).
* **Database server: fresh-host install, running-server adoption (this
  branch):** the installer provisions `mysql-server` on a host with no SQL
  server, and adopts an already-running server — but only when it can
  actually administer it (`mysql -e "SELECT 1"` as root via the local
  socket, the exact connection every later statement uses). A
  running-but-unreachable server is refused **at adoption time** with a
  specific error marker; the first version of this change silently adopted
  it and failed later at `FLUSH PRIVILEGES` with a misleading hint. Covered
  by mocked tests for all paths (adopt / install / refused, with and without
  a pre-existing client).
* **Regression fixed (this branch):** the prerequisites phase requested both
  `libmariadb-dev` and `default-libmysqlclient-dev`. On current Ubuntu those
  conflict in apt (`libmariadb-dev` Conflicts `libmysqlclient-dev`, which
  `default-libmysqlclient-dev` Depends on), so the whole prerequisite install
  failed to resolve. Fixed in `vmangos_setup.sh` by requesting
  `default-libmysqlclient-dev` alone (the virtual package that resolves to
  the system MySQL client library, which the MangOS CMake `FindMySQL` module
  accepts). The smoke caught this on first run; the prerequisites phase now
  passes.
* **`unzip` missing from prerequisites (fixed, this branch):** the world-DB
  import downloads a zipped dump; without `unzip` it fell through to a bogus
  legacy SQL file (`ERROR 1146 ... Table 'world.migrations' doesn't exist`)
  and failed with a confusing db-import error marker. Added to the package
  list.
* **`--collect` + marker-less failure (documented):** because the runner uses
  `systemd-run --collect`, a *failed* unit is unregistered and immediately
  reports `ActiveState=inactive` (not `failed`). The viewer therefore detects
  a failure via the `event=error` marker (which works), not via
  `ActiveState=failed` (which is unobservable under `--collect`). An *unmarked*
  `set -e` death would fall through to the EndedScreen rather than the
  FailureScreen — this is the gap tracked by #111 (error-marker gaps), which
  closes it.
* **Known viewer-test race (watched, not failed on):** the viewer's
  unit-state checker thread (2 s poll) races the 0.5 s UI tick inside two
  tests (`test_viewer_detects_unit_failure_without_markers` and
  `test_viewer_detects_unit_ended_without_completion`). Observed
  intermittently in review and locally during this rework; tracked by #113.
  The smoke watches for it and captures the traceback instead of failing —
  unknown test failures still fail the smoke.
* **PATH-installed manager needs the setup script beside the install root
  (arranged, this branch):** the wizard resolves `vmangos_setup.sh` one
  directory above the manager prefix (the layout of a repo checkout), so a
  manager installed to a prefix and driven via PATH needs
  `<parent-of-prefix>/vmangos_setup.sh` to exist. The smoke pre-installs the
  manager to `/opt/vmangos-manager` — deliberately **outside** the install
  root, because the gate treats an existing `/opt/mangos` as an existing
  installation — and links the mounted repo's script to
  `/opt/vmangos_setup.sh`; a fresh host running from its checkout already
  has this layout.
