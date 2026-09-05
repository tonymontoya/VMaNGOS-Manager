# Install-wizard smoke (issue #104)

A real, end-to-end install smoke. It runs the install-wizard stack — the
runner (`manager/lib/installer.sh`), `vmangos_setup.sh`, the marker protocol,
and the viewer — against **reality**: real apt, real MySQL/MariaDB, a real
MangOS build, real MPQ extraction, real systemd services, real markers, and a
real retry. It exercises the #104 acceptance scenarios plus two folded-in
additions:

* the **transient-unit name-recreation edge** after a completed run, and
* **watching for the viewer flake** under long runs.

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
# Full smoke (build image -> container -> manager -> secrets -> start ->
# scenarios -> watch to completion -> verify -> teardown). ~4.5 h on a 10-core
# workstation (MoveMapGen dominates — see Runtime expectations).
tests/smoke/wizard_smoke.sh

# A single phase (each is independently testable):
tests/smoke/wizard_smoke.sh --phase build-image
tests/smoke/wizard_smoke.sh --phase setup
tests/smoke/wizard_smoke.sh --phase manager
tests/smoke/wizard_smoke.sh --phase secrets
tests/smoke/wizard_smoke.sh --phase start
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

## What each scenario checks

| Scenario | Assertion |
|---|---|
| `start` | The runner launches the unit; `ActiveState=active`. |
| `kill-reattach` | Kill the viewer's journal session; the unit **keeps running**; re-attach works. |
| `failure-retry` | Stop the unit (forced failure); the runner's retry path (`installer_unit_stop` + `installer_unit_start`) restarts it with the checkpoint intact. |
| `watch` | Markers stream until the terminal `phase=install event=done` marker. |
| `completion` | Terminal marker present; `auth` + `world` services active; realmlist fields (`server_ip`/`auth_port`/`world_port`) present. |
| `name-recreation` | After a completed run, `systemd-run --unit=vmangos-install` with the same name succeeds (the `--collect` edge). |
| `flake-watch` | The viewer async suite is re-run N times (`SMOKE_FLAKE_RUNS`, default 5) to watch for the known single flake. |

## Runtime expectations

A full clean run is **~4.5 hours** on a 10-core workstation. The breakdown
(from a recorded run): image build + container + manager + secrets + start
~3 min; prerequisites ~5 min; database (mysql-server install) ~1 min; source
~1 min; MangOS build ~5 min; DBC/map + vmap extraction ~2 min; **MoveMapGen
~2.5 h**; db import ~1-2 min; service bring-up ~1 min. MoveMapGen is
single-threaded and generates mmaps for every map that has vmaps — the two
large continent maps (Elwynn Forest, Dustwallow Marsh) each take well over an
hour — so it is the dominant cost and the only reason a clean run can exceed
4 h. The `watch` phase has a **6 h** ceiling by default
(`SMOKE_WATCH_TIMEOUT` / `SMOKE_INSTALL_TIMEOUT` to override).

If you only need to re-exercise the viewer/runner (not the full build),
snapshot the container after the source phase (`docker commit`) so a re-smoke
can start from `SOURCE_DONE` — the build + extraction + db-import phases are
the expensive, already-proven part.

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
* **Database server: assume fresh, detect-and-use (this branch):** the
  installer assumes no SQL server is present and installs `mysql-server`
  (non-interactive, auto-enabled). `ensure_database_server` first checks for
  an already-running, reachable server and uses it instead, and installs
  `mysql-client` when a server is running but no usable client is present —
  so existing hosts are adopted rather than double-provisioned.
* **Regression fixed (this branch):** the prerequisites phase requested both
  `libmariadb-dev` and `default-libmysqlclient-dev`. On current Ubuntu those
  conflict in apt (`libmariadb-dev` Conflicts `libmysqlclient-dev`, which
  `default-libmysqlclient-dev` Depends on), so the whole prerequisite install
  failed to resolve. Fixed in `vmangos_setup.sh` by requesting
  `default-libmysqlclient-dev` alone (the virtual package that resolves to the
  system MySQL client library, which the MangOS CMake `FindMySQL` module
  accepts). The smoke caught this on first run; the prerequisites phase now
  passes.
* **`--collect` + marker-less failure (documented):** because the runner uses
  `systemd-run --collect`, a *failed* unit is unregistered and immediately
  reports `ActiveState=inactive` (not `failed`). The viewer therefore detects
  a failure via the `event=error` marker (which works), not via
  `ActiveState=failed` (which is unobservable under `--collect`). An *unmarked*
  `set -e` death would fall through to the EndedScreen rather than the
  FailureScreen — this is the gap tracked by #111 (error-marker gaps), which
  closes it.
