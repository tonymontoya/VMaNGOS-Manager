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
import pathlib
import textwrap
from datetime import datetime, timedelta, timezone

import pytest
from textual.widgets import DataTable, Input, Select, Static
from textual.widgets._toast import Toast

import re

from dashboard import (
    ACTION_STYLES,
    CHROME_ROLES,
    DASHBOARD_CSS,
    DARK_PALETTE,
    LIGHT_PALETTE,
    NARROW_VIEWPORT_WIDTH,
    create_app,
    empty_snapshot,
    format_flag,
    palette_color,
    iso_to_clock,
    render_action_banner,
    NARROW_ACTION_TOKENS,
    action_entry,
    render_command_rail,
    view_command_tokens,
    strip_markup,
    render_meter,
    render_player_pulse,
    set_palette,
)

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


def build_app(tmp_path, *, initial_view, accounts=None, snapshot_file="default", refresh=30, theme="dark"):
    stub, log_path = write_recorder_stub(tmp_path)
    if accounts is None:
        accounts = make_accounts(8)
    if snapshot_file == "default":
        snapshot_file = write_snapshot_fixture(tmp_path, accounts)
    app = create_app(
        manager_bin=stub,
        config_path="/dev/null",
        refresh=refresh,
        theme=theme,
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
            # The banner always carries the snapshot's captured clock, but only
            # when there is room does it also carry the date: an 80-column
            # headless run is a narrow window, so the readiness gate is the clock.
            captured_clock = iso_to_clock("2026-08-31T00:00:00+00:00")
            await wait_for(
                lambda: captured_clock in str(app.query_one("#action-banner").renderable),
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


# ---------------------------------------------------------------------------
# Palette: the light theme has to be a theme, not a dark screen with a light
# background painted on it.


@pytest.fixture(autouse=True)
def _leave_the_dark_palette_behind():
    """set_palette mutates module globals; no test may leak its palette into the next."""
    yield
    set_palette("dark")


def _luminance(hex_color):
    channels = [int(hex_color[start : start + 2], 16) / 255 for start in (1, 3, 5)]
    linear = [c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


def _contrast(first, second):
    first_lum, second_lum = _luminance(first), _luminance(second)
    lighter, darker = max(first_lum, second_lum), min(first_lum, second_lum)
    return (lighter + 0.05) / (darker + 0.05)


def _surfaces():
    """The surfaces each theme actually draws, read out of DASHBOARD_CSS.

    Read from the CSS rather than restated here: a rule that changes its
    background must move the palette test with it, not quietly stay green.
    """
    match = re.search(r"\n\s+Screen \{\s*background: (#[0-9a-f]{6});", DASHBOARD_CSS)
    dark_screen = match.group(1)
    match = re.search(r"Screen\.theme-light \{\s*background: (#[0-9a-f]{6});", DASHBOARD_CSS)
    light_screen = match.group(1)
    match = re.search(r"\n\s+\.panel \{[^}]*background: (#[0-9a-f]{6});", DASHBOARD_CSS, re.S)
    dark_panel = match.group(1)
    match = re.search(r"Screen\.theme-light \.panel \{[^}]*background: (#[0-9a-f]{6});", DASHBOARD_CSS, re.S)
    light_panel = match.group(1)
    return {
        "dark": (DARK_PALETTE, (dark_screen, dark_panel)),
        "light": (LIGHT_PALETTE, (light_screen, light_panel)),
    }


def test_palette_roles_are_readable_on_their_own_surfaces():
    """Every role colour has to clear its own theme's surfaces.

    The light theme inherited the dark palette for everything built in Python
    rather than CSS, and #cbd5e1 on #f6f1e7 is about 2:1 — legible enough to
    look at, too faint to read. 4.5:1 is the WCAG AA floor for body text, and
    these are labels an operator has to read under time pressure.
    """
    for theme, (palette, surfaces) in _surfaces().items():
        for role, color in palette.items():
            if role in CHROME_ROLES:
                # A scrollbar or a selection block is judged against the text it
                # carries, not the surface behind it; see the chrome test.
                continue
            for surface in surfaces:
                ratio = _contrast(color, surface)
                assert ratio >= 4.5, f"{theme} {role} {color} on {surface} is {ratio:.2f}:1, below 4.5:1"


def test_panels_recolour_when_the_palette_changes():
    """Markup is built from role colours at render time, so a switch is visible."""
    snapshot = empty_snapshot("no manager yet")

    dark = render_player_pulse(snapshot, [], 2)
    set_palette("light")
    light = render_player_pulse(snapshot, [], 2)

    assert DARK_PALETTE["muted"] in dark, "the dark palette is not in the dark render"
    assert DARK_PALETTE["muted"] not in light, "a dark label survived the switch to light"
    assert LIGHT_PALETTE["muted"] in light, "the light palette never reached the markup"

    # Colours captured at def time or import time are the easy way for a stale
    # dark hex to survive, so both paths are exercised — from a known palette.
    set_palette("dark")
    assert DARK_PALETTE["green"] in render_meter("50")
    assert DARK_PALETTE["green"] in format_flag(True)
    assert palette_color(ACTION_STYLES["success"][1]) == DARK_PALETTE["green"]
    set_palette("light")
    assert LIGHT_PALETTE["green"] in render_meter("50")
    assert LIGHT_PALETTE["green"] in format_flag(True)
    assert palette_color(ACTION_STYLES["success"][1]) == LIGHT_PALETTE["green"]


def test_a_narrow_window_gives_the_table_the_width_it_needs(tmp_path):
    """A table squeezed beside a fixed panel is the layout that breaks first.

    Measured before the narrow rules: at 100 columns the Accounts table was about
    twenty columns wide and drew an empty frame, and the Logs table showed three
    of its columns. That reads as a broken console, not a small one. The number
    asserted here is far below what any real table needs and far above what the
    broken layout produced.
    """
    for view_name, table_id in (
        ("accounts", "#accounts-table"),
        ("backups", "#backups-table"),
        ("logs", "#realm-logs-table"),
    ):
        app, _log_path = build_app(tmp_path, initial_view=view_name)

        async def scenario(app=app, table_id=table_id, view_name=view_name):
            async with app.run_test(size=(100, 36)) as pilot:
                await pilot.pause()
                assert app.screen.size.width < NARROW_VIEWPORT_WIDTH
                assert app.screen.has_class("narrow"), f"{view_name}: the screen is not marked narrow"
                table = app.query_one(table_id)
                assert table.region.width >= 45, (
                    f"{view_name} table is {table.region.width} columns wide at 100 columns of terminal"
                )

        asyncio.run(scenario())


def test_a_wide_window_keeps_the_summary_beside_the_table(tmp_path):
    """The stacking must not leak into a window that has room for both panes."""
    app, _log_path = build_app(tmp_path, initial_view="accounts")

    async def scenario():
        async with app.run_test(size=(140, 52)) as pilot:
            await pilot.pause()
            assert not app.screen.has_class("narrow"), "a 140-column window is marked narrow"
            table = app.query_one("#accounts-table")
            details = app.query_one("#account-details")
            assert details.region.x > table.region.right, "the summary stacked below a table that had room beside it"

    import asyncio

    asyncio.run(scenario())


def test_the_narrow_banner_says_the_same_thing_in_fewer_rows():
    """Each wrapped banner row comes straight off the table below it.

    The measured inner width of the banner at a 100-column terminal is about 38
    characters, so the narrow form is checked against a bound a little above that
    rather than against the wide form's length. The view prose is dropped in the
    narrow form because the footer already lists that view's actions.
    """
    snapshot = empty_snapshot("waiting for first refresh")
    narrow = render_action_banner("accounts", snapshot, "reset password for RAIDER01", "success", 2, narrow=True)
    wide = render_action_banner("accounts", snapshot, "reset password for RAIDER01", "success", 2)

    narrow_lines = [line for line in strip_markup(narrow).splitlines() if line.strip()]
    assert narrow_lines, "the narrow banner rendered nothing"
    for line in narrow_lines:
        assert len(line) <= 44, f"narrow banner line is {len(line)} characters, it will wrap: {line!r}"
    assert "This View" not in strip_markup(narrow), "the narrow banner repeats footer help text the table needs room for"
    assert "This View" in strip_markup(wide), "the roomy banner lost its view prose"


def test_every_committed_screenshot_shares_one_geometry():
    """The README is a grid of frames, and a mismatched frame is invisible by eye.

    A light-theme frame once got rendered at the driver default of 80x24 while
    every other frame was 140x52: same filename, same content, a third of the
    width, and it sat in the README unnoticed. The check is on the SVG geometry
    rather than the pixel count, and the floor is there so a uniformly small set
    cannot pass either.
    """
    assets = pathlib.Path(__file__).resolve().parents[2] / "docs" / "assets"
    frames = sorted(assets.glob("dashboard-*.svg"))
    assert frames, "no dashboard screenshots found to check"

    boxes = {}
    for frame in frames:
        match = re.search(r'viewBox="0 0 ([0-9.]+) ([0-9.]+)"', frame.read_text(encoding="utf-8"))
        assert match, f"{frame.name} has no readable viewBox"
        boxes[frame.name] = (float(match.group(1)), float(match.group(2)))

    widths = {box[0] for box in boxes.values()}
    heights = {box[1] for box in boxes.values()}
    assert len(widths) == 1, f"screenshots differ in width: {boxes}"
    assert len(heights) == 1, f"screenshots differ in height: {boxes}"
    # Textual's screenshot SVG advances about 12.3 px per column; 80 columns is
    # 994 px, 140 columns is 1726. Anything under 1400 px is a default-sized frame.
    assert next(iter(widths)) >= 1400, f"screenshots are {next(iter(widths))} px wide — that is a default-sized terminal, not the documented 140 columns"


def _hex(color):
    return "#%02x%02x%02x" % (color.r, color.g, color.b)


def _chrome_rules():
    """The selection-chrome hexes actually written in DASHBOARD_CSS, per theme.

    Read out of the CSS for the same reason _surfaces() is: a rule edited here has
    to move the palette assertion with it, instead of the palette drifting away
    from what the screen paints.
    """
    def grab(pattern):
        match = re.search(pattern, DASHBOARD_CSS, re.S)
        assert match, f"no rule matched {pattern!r} in DASHBOARD_CSS"
        block = match.group(1)
        values = re.findall(
            r"(scrollbar-color|scrollbar-color-hover|scrollbar-color-active|scrollbar-background"
            r"|background|color): (#[0-9a-f]{6});",
            block,
        )
        return {name: value for name, value in values}

    return {
        "dark": {
            "cursor_blur": grab(r"\n\s+DataTable > \.datatable--cursor,[^}]*\{([^}]*)\}"),
            "cursor": grab(r"\n\s+DataTable:focus > \.datatable--cursor,[^}]*\{([^}]*)\}"),
            "scrollbar": grab(r"\n\s+\* \{([^}]*)\}"),
        },
        "light": {
            "cursor_blur": grab(r"Screen\.theme-light DataTable > \.datatable--cursor,[^}]*\{([^}]*)\}"),
            "cursor": grab(r"Screen\.theme-light DataTable:focus > \.datatable--cursor,[^}]*\{([^}]*)\}"),
            "scrollbar": grab(r"Screen\.theme-light \* \{([^}]*)\}"),
        },
    }


def test_selection_chrome_matches_the_palette():
    """Cursor and scrollbar colours come from the palette, not from Textual.

    Left alone, Textual paints the row cursor and every inner scrollbar from its
    own theme variables: a purple that appears in neither palette here, and in the
    light theme a cursor block so pale on white it reads as no selection at all.
    """
    chrome = _chrome_rules()
    for theme, palette in (("dark", DARK_PALETTE), ("light", LIGHT_PALETTE)):
        rules = chrome[theme]
        assert rules["cursor"]["background"] == palette["cursor_bg"]
        assert rules["cursor"]["color"] == palette["cursor_fg"]
        assert rules["cursor_blur"]["background"] == palette["cursor_blur_bg"]
        assert rules["cursor_blur"]["color"] == palette["cursor_blur_fg"]
        assert rules["scrollbar"]["scrollbar-color"] == palette["scrollbar"]
        assert rules["scrollbar"]["scrollbar-background"] == palette["scrollbar_track"]


def test_the_row_cursor_is_readable_in_both_states():
    """Focused and unfocused selection both have to be readable text on a block.

    The unfocused block is the one an operator glances at while their hands are in
    another pane, so it gets the same floor as the focused one. The block also has
    to be distinguishable from the surface it sits on — that is not a text
    contrast question, but a ratio near 1 means "no cursor".
    """
    for theme, (palette, surfaces) in _surfaces().items():
        assert _contrast(palette["cursor_fg"], palette["cursor_bg"]) >= 4.5, f"{theme} focused cursor text"
        assert _contrast(palette["cursor_blur_fg"], palette["cursor_blur_bg"]) >= 4.5, f"{theme} unfocused cursor text"
        for surface in surfaces:
            for role in ("cursor_bg", "cursor_blur_bg"):
                ratio = _contrast(palette[role], surface)
                assert ratio >= 1.4, f"{theme} {role} {palette[role]} on {surface} is {ratio:.2f}:1 — no visible selection block"


def test_a_focused_table_paints_the_cursor_from_the_active_palette(tmp_path):
    """The computed styles, not the CSS text.

    Two separate bugs live here. A rule written against the app node styles
    nothing, and a scrollbar rule written only for Screen leaves every inner pane
    on Textual's purple: scrollbar colour is not inherited, which was measured on
    a nested Vertical (#4f4270 dark, #b89ae5 light). So the nested scroller is
    asserted alongside the cursor.
    """
    for theme, palette in (("dark", DARK_PALETTE), ("light", LIGHT_PALETTE)):
        app, _log_path = build_app(tmp_path, initial_view="accounts", theme=theme)

        async def scenario(app=app, palette=palette):
            async with app.run_test(size=(140, 52)) as pilot:
                await pilot.pause()
                table = app.query_one("#accounts-table")
                cursor = table.get_component_styles("datatable--cursor")
                assert cursor.background is not None, "the row cursor has no background of its own"
                assert _hex(cursor.background) == palette["cursor_bg"], "focused cursor is not the palette colour"
                assert _hex(cursor.color) == palette["cursor_fg"], "focused cursor text is not the palette colour"

                nested = None
                for widget in app.query("*"):
                    if widget is not app.screen and widget.styles.overflow_y == "auto":
                        nested = widget
                        break
                assert nested is not None, "this view has no inner scroller to check"
                assert _hex(nested.styles.scrollbar_color) == palette["scrollbar"], (
                    "an inner scroller is still painted with Textual's default purple"
                )

        asyncio.run(scenario())
        set_palette("dark")


def test_light_theme_classes_land_on_the_screen_not_the_app(tmp_path):
    """Textual matches CSS against widgets.

    Every light override in DASHBOARD_CSS is written as Screen.theme-light, and
    the app node is not a widget: adding the class there styles nothing, which
    is why `t` used to report success and change nothing.
    """
    app, _log_path = build_app(tmp_path, initial_view="overview", theme="light")

    async def scenario():
        async with app.run_test(size=(140, 52)) as pilot:
            await pilot.pause()
            assert app.screen.has_class("theme-light"), "the active screen is not themed light"
            assert not app.screen.has_class("theme-dark")
            # The app node is where this used to go, and it styles nothing there:
            # asserting its absence is what makes this test fail on the old code.
            assert not app.has_class("theme-light"), "the palette class landed on the app node"
            await pilot.press("t")
            await pilot.pause()
            assert app.screen.has_class("theme-dark"), "t did not switch the screen back to dark"
            assert not app.has_class("theme-dark"), "the palette class landed on the app node"

    asyncio.run(scenario())


def test_toggling_the_theme_recolours_the_panels(tmp_path):
    """``t`` has to change the colours the panels are built with, not just report.

    The panes are Rich visuals, and reading their styles out of a widget means
    poking private attributes, so this asserts through the same public seam the
    dashboard uses: the render function fed the app's own snapshot. If the
    toggle stops handing the palette to the render layer, the markup still comes
    back with dark hexes and this fails.
    """
    app, _log_path = build_app(tmp_path, initial_view="overview", theme="dark")

    async def scenario():
        async with app.run_test(size=(140, 52)) as pilot:
            await pilot.pause()
            await wait_for(lambda: app.snapshot_loaded, message="first snapshot")
            before = render_player_pulse(app.snapshot, [], app.refresh_interval)
            assert DARK_PALETTE["muted"] in before, "the dark palette never reached the panel markup"
            await pilot.press("t")
            await wait_for(lambda: app.theme_name == "light", message="toggle to light")
            after = render_player_pulse(app.snapshot, [], app.refresh_interval)
            assert LIGHT_PALETTE["muted"] in after, "the toggle left the panels drawing with dark colours"
            assert DARK_PALETTE["muted"] not in after, "a dark colour survived the toggle"

    asyncio.run(scenario())


def test_a_pushed_modal_inherits_the_active_theme(tmp_path):
    """A confirm dialog with the dark palette on a light screen is its own warning."""
    app, _log_path = build_app(tmp_path, initial_view=MONITOR_KEYS_VIEW, theme="light")

    async def scenario():
        async with app.run_test(size=(140, 52)) as pilot:
            await pilot.pause()
            await pilot.press("x")  # stop, which asks before it acts
            await wait_for(
                lambda: app.screen.__class__.__name__ == "ConfirmScreen",
                message="confirm screen",
            )
            # Both screens in the stack, and not the app node: Textual pushed the
            # class onto modals on its own even when it was set on the app, which
            # is why the main screen — the one an operator actually looks at — was
            # the half that stayed dark.
            for screen in app.screen_stack:
                assert screen.has_class("theme-light"), f"{screen.__class__.__name__} kept the dark palette"
            assert not app.has_class("theme-light"), "the palette class landed on the app node"

    asyncio.run(scenario())


def test_the_rail_is_tall_enough_for_what_it_says(tmp_path):
    """The legend under the view may not be cut off by its own box.

    The rail used a fixed height of five rows. Its Navigate row is a list of
    tokens, and a list wraps: at 100 columns the row took a second line, which
    pushed the third row -- the actions available in the current view -- out of the
    box without trace. A Backups legend at 140 columns was already too wide for
    three rows. These sizes are the widths an operator actually uses, and the
    assertion is about the box versus the wrapped content, not about any string.
    """

    async def scenario():
        for cols, lines in ((140, 52), (100, 36), (80, 24)):
            for view in ("backups", "operations"):
                app, _log_path = build_app(tmp_path, initial_view=view)
                async with app.run_test(size=(cols, lines)) as pilot:
                    await pilot.pause()
                    rail = app.query_one("#command-rail", Static)
                    inner = rail.content_region.width
                    wrapped = rail.get_content_height(rail.region.width, rail.region.width, inner)
                    # The heavy border costs a row top and bottom; nothing else in
                    # this widget has vertical padding.
                    assert rail.region.height >= wrapped + 2, (
                        f"{view} at {cols}x{lines}: the rail is {rail.region.height} rows tall "
                        f"and has to draw {wrapped} rows of keys"
                    )

    asyncio.run(scenario())


def test_the_narrow_rail_rewords_the_actions_and_keeps_all_of_them():
    """Narrow means shorter wording, not fewer actions."""
    for view in ("overview", "monitor", "accounts", "backups", "operations", "config", "logs"):
        wide = strip_markup(render_command_rail(view)).splitlines()
        narrow = strip_markup(render_command_rail(view, narrow=True)).splitlines()
        assert len(wide) == 3 and wide[0].startswith("Navigate"), f"{view}: the wide rail lost its shape"
        assert not any(row.startswith("Navigate") for row in narrow), (
            f"{view}: the narrow rail repeats the Modules list, which already carries the keys"
        )
        # Same rows in the same order, minus Navigate: nothing may get longer.
        for narrow_row, wide_row in zip(narrow, wide[1:]):
            assert len(narrow_row) <= len(wide_row), (
                f"{view}: the narrow rail spent more columns than the wide one"
            )
        wide_keys = {token[0] for token in view_command_tokens(view)}
        narrow_keys = {token[0] for token in view_command_tokens(view, narrow=True)}
        assert wide_keys == narrow_keys, f"{view}: the narrow rail dropped a key, not just a word"
        for (key, wide_label), (_key, narrow_label) in zip(
            view_command_tokens(view), view_command_tokens(view, narrow=True)
        ):
            if wide_label == narrow_label:
                continue
            # A shorter word belongs to the action this view's key runs, never to
            # the letter: "p" means different things two views apart.
            entry = action_entry(view, key)
            assert NARROW_ACTION_TOKENS.get(entry[0]) == narrow_label, (
                f"{view}: {key} narrowed to {narrow_label!r}, which is not what {entry[0]} does"
            )
            assert len(narrow_label) < len(wide_label), (
                f"{view}: {entry[0]} was 'shortened' to {narrow_label!r}"
            )


def test_one_key_one_action_per_view_even_when_the_letter_is_reused(tmp_path):
    """"p" resets a password in Accounts and rehearses a restore in Backups.

    Both views advertise the letter, and a table keyed only by character can hold
    one of the two: the literal silently kept the Backups entry, so Accounts drew
    "restore preflight" in its legend, bound a backup action to p, and left its
    password reset with no key at all.
    """
    assert ("p", "reset password") in view_command_tokens("accounts")
    assert ("p", "restore preflight") in view_command_tokens("backups")

    async def accounts():
        app, _log_path = build_app(tmp_path, initial_view=ACCOUNTS_KEYS_VIEW)
        async with app.run_test(size=(140, 52)) as pilot:
            await pilot.pause()
            await pilot.press("p")
            await wait_for(
                lambda: len(app.screen_stack) > 1,
                message="the password form to open from the Accounts view",
            )
            modal = app.screen_stack[-1]
            assert modal.query_one("#command-field-password", Input)
            assert modal.query_one("#command-field-confirm_password", Input)

    async def backups():
        app, _log_path = build_app(tmp_path, initial_view="backups")
        async with app.run_test(size=(140, 52)) as pilot:
            await pilot.pause()
            await pilot.press("p")
            await wait_for(
                lambda: "preflight" in getattr(app, "last_action", ""),
                message="the restore preflight action to answer",
            )

    asyncio.run(accounts())
    asyncio.run(backups())
