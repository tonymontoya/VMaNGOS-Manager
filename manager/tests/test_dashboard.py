"""Textual pilot tests for dashboard UX (#92).

Seams (agreed):
- The running app: create_app(...) driven via App.run_test() -- key presses
  and widget/DOM assertions only, no private-attribute poking.
- The manager CLI: --manager-bin points at a recording stub, so dispatched
  commands are asserted through the real public interface.
- Snapshot fixtures: --snapshot-file feeds the app deterministic data.
"""

import asyncio
import json
import os
import textwrap
from datetime import datetime, timedelta, timezone

import pytest
from textual.widgets import DataTable, Select
from textual.widgets._toast import Toast

from dashboard import create_app, empty_snapshot

# The app's daemon refresh worker can still be mid-call when the pilot
# tears the app down; its post-exit thread exception is teardown noise,
# not a product defect.
pytestmark = pytest.mark.filterwarnings("ignore::pytest.PytestUnhandledThreadExceptionWarning")

ACCOUNTS_KEYS_VIEW = "accounts"
MONITOR_KEYS_VIEW = "monitor"


def write_recorder_stub(directory):
    """A manager-bin stand-in that records every invocation, one line each."""
    log_path = os.path.join(directory, "commands.log")
    stub_path = os.path.join(directory, "manager-stub")
    with open(stub_path, "w", encoding="utf-8") as handle:
        handle.write(
            "#!/usr/bin/env bash\n"
            f"printf '%s\\n' \"$*\" >> '{log_path}'\n"
            "exit 0\n"
        )
    os.chmod(stub_path, 0o755)
    return stub_path, log_path


def recorded_commands(log_path):
    """Commands the dashboard dispatched at the stub manager.

    The one-off `--version` probe is how the console learns what it is
    driving: read-only, no side effects, and not an action — so tests that
    assert "nothing was dispatched" must not trip over it.
    """
    if not os.path.exists(log_path):
        return []
    with open(log_path, "r", encoding="utf-8") as handle:
        return [
            line.strip()
            for line in handle.read().splitlines()
            if line.strip() and not line.strip().endswith("--version")
        ]


def make_accounts(count):
    return [
        {
            "id": 1000 + index,
            "username": f"user{index:03d}",
            "gm_level": 3 if index % 4 == 0 else 0,
            "online": index % 2 == 0,
            "banned": index % 7 == 3,
        }
        for index in range(count)
    ]


def write_snapshot_fixture(directory, accounts):
    snapshot = empty_snapshot("fixture")
    snapshot["captured_at"] = "2026-08-31T00:00:00+00:00"
    snapshot["accounts"] = {"ok": True, "error": "", "data": {"accounts": accounts}}
    snapshot["accounts_online"] = {"ok": True, "error": "", "data": {"accounts": []}}
    snapshot["all_accounts"] = accounts
    snapshot["players"] = []
    path = os.path.join(directory, "snapshot.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(snapshot, handle)
    return path


def add_backups_to_fixture(path, *, age_seconds=300, credentials_ready=False):
    """Give a snapshot fixture one fresh backup so the Backups view fills in."""
    with open(path, "r", encoding="utf-8") as handle:
        snapshot = json.load(handle)
    timestamp = (
        datetime.now(timezone.utc) - timedelta(seconds=age_seconds)
    ).isoformat()
    backup_file = "vmangos_backup_20260908_120000.sql.gz"
    backup_dir = "/opt/mangos/backups"
    snapshot["restore_credentials_ready"] = credentials_ready
    snapshot["backups"] = {
        "entries": [
            {
                "file": backup_file,
                "timestamp": timestamp,
                "size_bytes": 2048,
                "created_by": "vmangos-manager 0.3.0",
                "databases": ["auth", "characters"],
            }
        ],
        "summary": {
            "count": 1,
            "backup_dir": backup_dir,
            "latest_file": backup_file,
            "latest_path": f"{backup_dir}/{backup_file}",
            "latest_timestamp": timestamp,
            "latest_size_bytes": 2048,
        },
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(snapshot, handle)


def build_app(tmp_path, *, initial_view, accounts=None, snapshot_file="default", refresh=30):
    stub, log_path = write_recorder_stub(tmp_path)
    if accounts is None:
        accounts = make_accounts(8)
    if snapshot_file == "default":
        snapshot_file = write_snapshot_fixture(tmp_path, accounts)
    app = create_app(
        manager_bin=stub,
        config_path="/dev/null",
        refresh=refresh,
        theme="dark",
        initial_view=initial_view,
        screenshot_path=None,
        snapshot_file=snapshot_file,
    )
    return app, log_path


async def wait_for(predicate, timeout=10.0, message="condition"):
    for _ in range(int(timeout / 0.05)):
        if predicate():
            return
        await asyncio.sleep(0.05)
    raise AssertionError(f"timed out waiting for {message}")


def test_destructive_keys_do_not_fire_outside_their_views(tmp_path):
    app, log_path = build_app(tmp_path, initial_view=ACCOUNTS_KEYS_VIEW)

    async def scenario():
        async with app.run_test() as pilot:
            table = app.query_one("#accounts-table", DataTable)
            await wait_for(lambda: table.row_count > 0, message="accounts table to load")
            await pilot.press("x")  # stop realm -- monitor/overview only
            await pilot.press("R")  # restart realm -- monitor/overview only
            await pilot.press("s")  # start realm -- monitor/overview only
            await pilot.press("b")  # backup now -- monitor/backups only
            await asyncio.sleep(0.5)
            assert recorded_commands(log_path) == []

    asyncio.run(scenario())


def test_scoped_keys_still_fire_in_their_own_view(tmp_path):
    app, log_path = build_app(tmp_path, initial_view=MONITOR_KEYS_VIEW)

    async def scenario():
        async with app.run_test() as pilot:
            await pilot.press("x")  # stop realm -- advertised in monitor
            await pilot.pause()
            assert app.screen.__class__.__name__ == "ConfirmScreen"
            await pilot.press("enter")  # confirm the destructive action
            await wait_for(
                lambda: any("server stop" in line for line in recorded_commands(log_path)),
                message="stop command to be dispatched",
            )
            # Let the action worker's follow-up refresh land on the live app
            # instead of racing the teardown.
            await asyncio.sleep(0.4)
            await pilot.pause()

    asyncio.run(scenario())


def test_stop_requires_confirmation(tmp_path):
    app, log_path = build_app(tmp_path, initial_view=MONITOR_KEYS_VIEW)

    async def scenario():
        async with app.run_test() as pilot:
            await pilot.press("x")
            await pilot.pause()
            assert app.screen.__class__.__name__ == "ConfirmScreen"
            assert recorded_commands(log_path) == []
            await pilot.press("enter")  # explicit confirm
            await wait_for(
                lambda: any("server stop" in line for line in recorded_commands(log_path)),
                message="confirmed stop to be dispatched",
            )
            await asyncio.sleep(0.4)
            await pilot.pause()

    asyncio.run(scenario())


def test_stop_confirmation_escape_cancels(tmp_path):
    app, log_path = build_app(tmp_path, initial_view=MONITOR_KEYS_VIEW)

    async def scenario():
        async with app.run_test() as pilot:
            await pilot.press("x")
            await pilot.pause()
            assert app.screen.__class__.__name__ == "ConfirmScreen"
            await pilot.press("escape")
            await pilot.pause()
            assert app.screen.__class__.__name__ != "ConfirmScreen"
            await asyncio.sleep(0.4)
            assert recorded_commands(log_path) == []

    asyncio.run(scenario())


def test_restart_requires_confirmation(tmp_path):
    app, log_path = build_app(tmp_path, initial_view=MONITOR_KEYS_VIEW)

    async def scenario():
        async with app.run_test() as pilot:
            await pilot.press("R")
            await pilot.pause()
            assert app.screen.__class__.__name__ == "ConfirmScreen"
            await pilot.press("escape")
            await pilot.pause()
            await asyncio.sleep(0.4)
            assert recorded_commands(log_path) == []

    asyncio.run(scenario())


def test_unban_requires_confirmation(tmp_path):
    app, log_path = build_app(tmp_path, initial_view=ACCOUNTS_KEYS_VIEW)

    async def scenario():
        async with app.run_test() as pilot:
            table = app.query_one("#accounts-table", DataTable)
            await wait_for(lambda: table.row_count > 0, message="accounts table to load")
            await pilot.press("down")  # highlight a row -> selection
            await pilot.press("u")
            await pilot.pause()
            assert app.screen.__class__.__name__ == "ConfirmScreen"
            assert recorded_commands(log_path) == []
            await pilot.press("enter")
            await wait_for(
                lambda: any("account unban" in line for line in recorded_commands(log_path)),
                message="confirmed unban to be dispatched",
            )
            await asyncio.sleep(0.4)
            await pilot.pause()

    asyncio.run(scenario())


def test_accounts_search_finds_one_account_in_500(tmp_path):
    app, _log_path = build_app(tmp_path, initial_view=ACCOUNTS_KEYS_VIEW, accounts=make_accounts(500))

    async def scenario():
        async with app.run_test() as pilot:
            table = app.query_one("#accounts-table", DataTable)
            await wait_for(lambda: table.row_count == 500, timeout=30.0, message="500 accounts to load")
            await pilot.press("/")
            await pilot.pause()
            await pilot.press(*"user123")
            await wait_for(lambda: table.row_count == 1, message="filter to narrow to one row")
            await pilot.press("escape")
            await wait_for(lambda: table.row_count == 500, message="escape to clear the filter")

    asyncio.run(scenario())


def test_accounts_sort_cycles_columns(tmp_path):
    accounts = list(reversed(make_accounts(30)))
    app, _log_path = build_app(tmp_path, initial_view=ACCOUNTS_KEYS_VIEW, accounts=accounts)

    async def scenario():
        async with app.run_test() as pilot:
            table = app.query_one("#accounts-table", DataTable)
            await wait_for(lambda: table.row_count == 30, message="accounts table to load")

            def first_username():
                row = table.get_row_at(0)
                return str(row[1])

            assert first_username() == "user029"  # fixture arrives reversed
            await pilot.press("S")  # sort by ID ascending
            await pilot.pause()
            assert first_username() == "user000"
            await pilot.press("S")  # sort by Username ascending
            await pilot.pause()
            assert first_username() == "user000"
            await pilot.press("S")  # sort by GM ascending: gm=0 rows first
            await pilot.pause()
            assert first_username() == "user001"  # user000 has gm 3
            for _ in range(3):  # Online, Banned, then back to natural order
                await pilot.press("S")
            await pilot.pause()
            assert first_username() == "user029"

    asyncio.run(scenario())


def test_create_account_form_validates_inline(tmp_path):
    app, log_path = build_app(tmp_path, initial_view=ACCOUNTS_KEYS_VIEW)

    async def scenario():
        async with app.run_test() as pilot:
            table = app.query_one("#accounts-table", DataTable)
            await wait_for(lambda: table.row_count > 0, message="accounts table to load")
            await pilot.press("c")
            await pilot.pause()
            await pilot.press(*"a!")  # invalid username: too short, non-alphanumeric
            await pilot.press("enter")
            await pilot.pause()
            assert app.screen.__class__.__name__ == "CommandFormScreen", "form must stay open on invalid input"
            error_text = str(app.query_one("#command-modal-error").renderable)
            assert "username must be 2-32 alphanumeric characters" in error_text
            assert recorded_commands(log_path) == []
            await pilot.press("escape")
            await asyncio.sleep(0.3)
            await pilot.pause()

    asyncio.run(scenario())


def test_create_account_form_dispatches_valid_input(tmp_path):
    app, log_path = build_app(tmp_path, initial_view=ACCOUNTS_KEYS_VIEW)

    async def scenario():
        async with app.run_test() as pilot:
            table = app.query_one("#accounts-table", DataTable)
            await wait_for(lambda: table.row_count > 0, message="accounts table to load")
            await pilot.press("c")
            await pilot.pause()
            await pilot.press(*"playerone")
            await pilot.press("tab")
            await pilot.press(*"seekrit1")
            await pilot.press("tab")
            await pilot.press(*"seekrit1")
            await pilot.press("enter")
            await wait_for(
                lambda: any("account create" in line for line in recorded_commands(log_path)),
                message="account create to be dispatched",
            )
            await asyncio.sleep(0.4)
            await pilot.pause()

    asyncio.run(scenario())


def test_accounts_create_still_opens_its_form(tmp_path):
    app, _log_path = build_app(tmp_path, initial_view=ACCOUNTS_KEYS_VIEW)

    async def scenario():
        async with app.run_test() as pilot:
            table = app.query_one("#accounts-table", DataTable)
            await wait_for(lambda: table.row_count > 0, message="accounts table to load")
            await pilot.press("c")
            await pilot.pause()
            assert app.screen.__class__.__name__ == "CommandFormScreen"
            assert app.query_one("#command-modal-error") is not None
            await pilot.press("escape")
            await asyncio.sleep(0.3)
            await pilot.pause()

    asyncio.run(scenario())


def test_logs_filters_use_select_dropdowns(tmp_path):
    # Live mode (no fixture): the post-filter refresh records the real
    # `logs recent` argv through the manager stub.
    app, log_path = build_app(tmp_path, initial_view="logs", snapshot_file=None)

    async def scenario():
        # Taller pilot terminal: the four-dropdown form plus buttons exceed
        # the default 24-row test screen.
        async with app.run_test(size=(100, 50)) as pilot:
            await pilot.press("f")
            await pilot.pause()
            assert app.screen.__class__.__name__ == "CommandFormScreen"
            selects = list(app.screen.query(Select))
            assert len(selects) == 4, "all four filter fields must be dropdowns"
            assert not list(app.screen.query("Input")), "no free-text filter fields left"
            # Focus starts on source; tab twice to reach severity, then
            # expand (enter), move to Debug (one down), and pick it (enter).
            await pilot.press("tab")
            await pilot.press("tab")
            await pilot.press("enter")
            await pilot.press("down")
            await pilot.press("enter")
            await pilot.pause()
            assert app.query_one("#command-field-severity", Select).value == "debug"
            await pilot.click("#command-submit")
            await wait_for(
                lambda: any(
                    "logs recent" in line and "--severity debug" in line for line in recorded_commands(log_path)
                ),
                message="refresh to run with the picked severity",
            )
            await asyncio.sleep(0.3)
            await pilot.pause()

    asyncio.run(scenario())


def test_action_completion_shows_notification(tmp_path):
    app, log_path = build_app(tmp_path, initial_view=MONITOR_KEYS_VIEW)

    async def scenario():
        async with app.run_test(notifications=True) as pilot:
            await pilot.press("x")
            await pilot.press("enter")
            await wait_for(
                lambda: any("server stop" in line for line in recorded_commands(log_path)),
                message="confirmed stop to be dispatched",
            )
            await wait_for(lambda: len(list(app.query("Toast"))) > 0, message="completion toast")
            toast_text = " ".join(str(toast.render()) for toast in app.query("Toast"))
            assert "stop" in toast_text.lower()
            await asyncio.sleep(0.4)
            await pilot.pause()

    asyncio.run(scenario())


def test_refresh_failure_notifies_once_per_outage(tmp_path):
    app, _log_path = build_app(tmp_path, initial_view="overview")
    fixture = os.path.join(tmp_path, "snapshot.json")

    async def scenario():
        async with app.run_test(notifications=True) as pilot:
            await wait_for(
                lambda: "2026-08-31" in str(app.query_one("#action-banner").renderable),
                message="fixture snapshot to load",
            )
            os.remove(fixture)
            await pilot.press("r")
            await wait_for(lambda: len(list(app.query("Toast"))) == 1, message="failure toast")
            toast_text = " ".join(str(toast.render()) for toast in app.query("Toast"))
            assert "refresh failed" in toast_text.lower()
            await pilot.press("r")  # consecutive failure: suppressed, no spam
            await asyncio.sleep(0.6)
            assert len(list(app.query("Toast"))) == 1, "consecutive failures must not re-toast"
            await asyncio.sleep(0.2)
            await pilot.pause()

    asyncio.run(scenario())


def test_refresh_pauses_while_modal_open(tmp_path):
    # refresh=2 with a 1.0s modal window: no interval tick can fire, so the
    # only possible refreshes are the ones the code starts itself.
    app, log_path = build_app(tmp_path, initial_view=MONITOR_KEYS_VIEW, snapshot_file=None, refresh=2)

    async def scenario():
        async with app.run_test() as pilot:
            def status_calls():
                return len([line for line in recorded_commands(log_path) if "server status" in line])

            await wait_for(lambda: status_calls() >= 1, message="first snapshot to load")
            await asyncio.sleep(0.3)
            base = status_calls()
            await pilot.press("x")
            await pilot.pause()
            assert app.screen.__class__.__name__ == "ConfirmScreen"
            await pilot.press("r")  # manual refresh attempt during the modal
            await asyncio.sleep(1.0)
            assert status_calls() == base, "no refresh may start while a modal is open"
            await pilot.press("escape")
            await wait_for(lambda: status_calls() > base, message="deferred refresh to run after dismissal")

    asyncio.run(scenario())


def test_sidebar_click_switches_view(tmp_path):
    app, _log_path = build_app(tmp_path, initial_view=ACCOUNTS_KEYS_VIEW)

    async def scenario():
        async with app.run_test() as pilot:
            table = app.query_one("#accounts-table", DataTable)
            await wait_for(lambda: table.row_count > 0, message="accounts table to load")
            await pilot.click("#sidebar-item-overview")
            await pilot.pause()
            assert not app.query_one("#overview-view").has_class("hidden")
            assert app.query_one("#accounts-view").has_class("hidden")
            assert app.query_one("#sidebar-item-overview").has_class("active")

    asyncio.run(scenario())


def test_backups_view_shows_restore_readiness(tmp_path):
    app, _log_path = build_app(tmp_path, initial_view="backups")
    add_backups_to_fixture(os.path.join(tmp_path, "snapshot.json"), age_seconds=300, credentials_ready=False)

    async def scenario():
        async with app.run_test() as pilot:
            table = app.query_one("#backups-table", DataTable)
            await wait_for(lambda: table.row_count > 0, message="backups table to load")
            await pilot.pause()
            panel = str(app.query_one("#backup-summary").renderable)
            assert "Restore Readiness" in panel
            assert "not in this session" in panel, "missing credentials must carry env-var guidance"
            assert "within 24h window" in panel, "a fresh backup must read as within the safety window"
            assert "press p on a selected backup" in panel
            assert "--preflight" in panel

    asyncio.run(scenario())


def test_backups_preflight_key_dispatches_selected_backup(tmp_path):
    app, log_path = build_app(tmp_path, initial_view="backups")
    add_backups_to_fixture(os.path.join(tmp_path, "snapshot.json"))

    async def scenario():
        async with app.run_test() as pilot:
            table = app.query_one("#backups-table", DataTable)
            await wait_for(lambda: table.row_count > 0, message="backups table to load")
            await pilot.press("down")  # highlight the backup row -> selection
            await pilot.press("p")
            await wait_for(
                lambda: any(
                    "backup restore /opt/mangos/backups/vmangos_backup_20260908_120000.sql.gz --preflight" in line
                    for line in recorded_commands(log_path)
                ),
                message="preflight to be dispatched for the selected backup",
            )
            await asyncio.sleep(0.4)
            await pilot.pause()

    asyncio.run(scenario())


def test_command_palette_switches_view(tmp_path):
    app, _log_path = build_app(tmp_path, initial_view=ACCOUNTS_KEYS_VIEW)

    async def scenario():
        async with app.run_test() as pilot:
            table = app.query_one("#accounts-table", DataTable)
            await wait_for(lambda: table.row_count > 0, message="accounts table to load")
            await pilot.press("ctrl+p")
            await pilot.pause()
            assert app.screen.__class__.__name__ == "CommandPalette"
            await pilot.press(*"over")
            await asyncio.sleep(0.3)
            await pilot.press("enter")
            await pilot.pause()
            assert app.screen.__class__.__name__ != "CommandPalette"
            assert not app.query_one("#overview-view").has_class("hidden")

    asyncio.run(scenario())


def write_version_stub(directory):
    """Stub that answers --version, so the console can name what it drives."""
    log_path = os.path.join(directory, "commands.log")
    stub_path = os.path.join(directory, "manager-stub-version")
    with open(stub_path, "w", encoding="utf-8") as handle:
        handle.write(
            "#!/usr/bin/env bash\n"
            f"printf '%s\\n' \"$*\" >> '{log_path}'\n"
            "if [[ \"$*\" == *--version* ]]; then\n"
            "  printf 'VMaNGOS Manager version 0.6.0\\n  build: git=deadbeef describe=v0.6.0\\n'\n"
            "fi\n"
            "exit 0\n"
        )
    os.chmod(stub_path, 0o755)
    return stub_path, log_path


def panel_text(app, selector):
    rendered = app.query_one(selector).render()
    return getattr(rendered, "plain", None) or str(rendered)


def test_dashboard_panels_fit_their_grid_cells(tmp_path):
    """A line that does not fit its panel is a line the operator never sees.

    The Overview quietly lost Disk and I/O to exactly this: each metric row
    wrapped to two lines, the panel was already at its height, and the last
    metrics simply disappeared. Panels are measured against their cells here
    so that class of bug cannot come back quietly.
    """
    from dashboard import (
        render_alerts_panel,
        render_metrics_panel,
        render_monitor_pressure,
        render_monitor_processes,
        render_monitor_storage,
        render_monitor_trends,
        render_player_pulse,
        render_service_panel,
        strip_markup,
    )

    grid_panes = {
        "overview": (
            "#service-pane",
            "#metrics-pane",
            "#player-pulse-pane",
            "#alerts-pane",
        ),
        "monitor": (
            "#monitor-pressure-pane",
            "#monitor-process-pane",
            "#monitor-trends-pane",
            "#monitor-storage-pane",
        ),
    }
    # The shipped documentation fixture: a fully populated host, which is the
    # case that produces the most lines and therefore the one that clips.
    demo_snapshot = os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
        "docs",
        "assets",
        "dashboard-demo-snapshot.json",
    )

    for view, panes in grid_panes.items():
        app = create_app(
            manager_bin=write_recorder_stub(tmp_path)[0],
            config_path="/dev/null",
            refresh=30,
            theme="dark",
            initial_view=view,
            screenshot_path=None,
            snapshot_file=demo_snapshot,
        )

        async def scenario(app=app, view=view, panes=panes):
            async with app.run_test(size=(140, 52)) as pilot:
                await pilot.pause()
                await wait_for(lambda: app.snapshot_loaded, message="snapshot to load")
                snapshot, history = app.snapshot, app.metric_history
                producers = {
                    "#service-pane": lambda: render_service_panel(snapshot, view),
                    "#metrics-pane": lambda: render_metrics_panel(snapshot, history, 30),
                    "#player-pulse-pane": lambda: render_player_pulse(snapshot, history, 30),
                    "#alerts-pane": lambda: render_alerts_panel(snapshot),
                    "#monitor-pressure-pane": lambda: render_monitor_pressure(snapshot, history, 30),
                    "#monitor-process-pane": lambda: render_monitor_processes(snapshot),
                    "#monitor-trends-pane": lambda: render_monitor_trends(snapshot, history, 30),
                    "#monitor-storage-pane": lambda: render_monitor_storage(snapshot),
                }
                for selector in panes:
                    widget = app.query_one(selector)
                    inner_width = widget.size.width
                    needed = sum(
                        len(textwrap.wrap(line, inner_width)) or 1
                        for line in strip_markup(producers[selector]()).splitlines()
                    )
                    assert needed <= widget.size.height, (
                        f"{view} {selector} needs {needed} lines, shows {widget.size.height}"
                    )

        asyncio.run(scenario())


def test_sidebar_names_the_release_it_drives(tmp_path):
    """A console that cannot name its build cannot be trusted to audit one."""
    stub, _log_path = write_version_stub(tmp_path)
    app = create_app(
        manager_bin=stub,
        config_path="/dev/null",
        refresh=30,
        theme="dark",
        initial_view="overview",
        screenshot_path=None,
        snapshot_file=write_snapshot_fixture(tmp_path, make_accounts(4)),
    )

    async def scenario():
        async with app.run_test() as pilot:
            await pilot.pause()
            await wait_for(lambda: "0.6.0" in panel_text(app, "#sidebar-head"), message="release version in the sidebar")

    asyncio.run(scenario())


def test_unconfigured_host_is_told_once(tmp_path):
    """A fresh host reads as 'set me up', not as a wall of identical failures."""
    stub, _log_path = write_recorder_stub(tmp_path)
    failure = {
        "ok": False,
        "data": {},
        "error": (
            '{"success":false,"error":{"code":"CONFIG_NOT_FOUND",'
            '"message":"Configuration file not found: /opt/mangos/manager/config/manager.conf",'
            '"suggestion":"Create one with: vmangos-manager config create --path /opt/mangos/manager/config/manager.conf"}}'
        ),
    }
    snapshot = {
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "config_path": "/opt/mangos/manager/config/manager.conf",
        "players": [],
        "all_accounts": [],
        "log_events": [],
        "schedules": [],
        "backups": {"entries": [], "summary": {}},
        "config_summary": {},
        "config_content": "",
        "metric_history": [],
    }
    for key in (
        "server",
        "logs",
        "realm_logs",
        "schedule_list",
        "accounts_online",
        "accounts",
        "backup_list",
        "backup_schedule_status",
        "config_validate",
        "config_show",
        "update_check",
        "update_inspect",
    ):
        snapshot[key] = dict(failure)

    fixture_path = os.path.join(tmp_path, "fresh.json")
    with open(fixture_path, "w", encoding="utf-8") as handle:
        json.dump(snapshot, handle)

    app = create_app(
        manager_bin=stub,
        config_path="/opt/mangos/manager/config/manager.conf",
        refresh=30,
        theme="dark",
        initial_view="overview",
        screenshot_path=None,
        snapshot_file=fixture_path,
    )

    async def scenario():
        async with app.run_test() as pilot:
            await pilot.pause()
            banner = panel_text(app, "#action-banner")
            services = panel_text(app, "#service-pane")
            alerts = panel_text(app, "#alerts-pane")
            assert "Setup" in banner, "banner names the setup problem"
            assert "no configuration" in banner, "banner states the state in plain words"
            assert "config create" in banner, "banner carries the command that resolves it"
            assert "awaiting configuration" in services, "panels say what they are waiting for"
            assert "Getting this host online" in alerts, "alerts panel carries the checklist"
            combined = banner + services + alerts
            assert "CONFIG_NOT_FOUND" not in combined, "internal error codes stay internal"
            assert "not fetched for this view" not in combined, "unfetched bookkeeping stays invisible"

    asyncio.run(scenario())
