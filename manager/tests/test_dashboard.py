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
import sys
import tempfile
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
    SCROLL_KEYS_CLAIMED_BY_SEARCH,
    SCROLL_KEYS_CLAIMED_BY_TABLE,
    TWO_COLUMN_MINIMUM_WIDTH,
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
    render_alerts_panel,
    render_meter,
    render_monitor_pressure,
    render_monitor_processes,
    render_monitor_trends,
    render_metrics_panel,
    render_player_pulse,
    render_service_panel,
    render_sidebar_target,
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


def add_services_to_fixture(path):
    """Fill the server section so the Overview cards render their data half."""
    with open(path, "r", encoding="utf-8") as handle:
        snapshot = json.load(handle)
    service = {
        "state": "active",
        "health": "healthy",
        "pid": 231004,
        "uptime_human": "5h 30m",
        "cpu_percent": 0.7,
        "memory_mb": 11,
        "restart_count_1h": 0,
    }
    snapshot["server"] = {
        "ok": True,
        "error": "",
        "data": {
            "services": {"auth": dict(service), "world": {**service, "pid": 231051, "memory_mb": 482}},
            "checks": {"database_connectivity": {"ok": True, "message": "reachable"}},
        },
    }
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
    # The documentation fixture: a fully populated host, which is the case that
    # produces the most lines and therefore the one that clips. Generated, because
    # the file under docs/assets is a driver byproduct and absent on a fresh checkout.
    demo_snapshot = demo_snapshot_path()

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


def test_no_view_cuts_the_end_of_a_reading_pane_at_any_size(tmp_path):
    """A card that ends mid-sentence is a card the operator reads wrong.

    The Overview was guarded; the reading views were not, and at 140x52 -- a
    comfortable window, not a cramped one -- the Backups card wanted 37 display rows
    inside a 30-row box. What disappeared was the end: which databases the archive
    covers, who made it, and the one line that says live restore is CLI-only. The Ops
    cards wanted 14 and 22 rows in boxes of 9, so "DB impact and the planned steps"
    was a subtitle over a card that showed neither.

    So prose panes take their natural height and the view scrolls. A table is allowed
    to be taller than the window because it scrolls itself; a wall of text is not,
    because nothing scrolls it for the operator.
    """
    from dashboard import strip_markup

    reading_views = ("accounts", "backups", "config", "logs", "operations")
    demo = demo_snapshot_path()

    for view in reading_views:
        for cols, lines in ((140, 52), (100, 36), (100, 24), (80, 24)):
            app = create_app(
                manager_bin=write_recorder_stub(tmp_path)[0],
                config_path="/dev/null",
                refresh=30,
                theme="dark",
                initial_view=view,
                screenshot_path=None,
                snapshot_file=demo,
            )

            async def scenario(app=app, view=view, cols=cols, lines=lines):
                async with app.run_test(size=(cols, lines)) as pilot:
                    await pilot.pause()
                    await wait_for(lambda: app.snapshot_loaded, message="snapshot to load")
                    body = app.query_one(f"#{view}-view")
                    assert body.styles.overflow_y == "auto", (
                        f"{view} at {cols}x{lines} cannot scroll, so anything taller than the "
                        "window is not cut -- it is gone"
                    )
                    for widget in app.query(f"#{view}-view Static"):
                        text = strip_markup(widget.renderable)
                        needed = sum(
                            len(textwrap.wrap(line, widget.size.width)) or 1
                            for line in text.splitlines()
                        )
                        assert needed <= widget.size.height, (
                            f"{view} at {cols}x{lines} draws {needed} rows of text in "
                            f"{widget.id or type(widget).__name__}, which is {widget.size.height} "
                            f"rows tall; the last {needed - widget.size.height} are invisible:\n"
                            + "\n".join(text.splitlines())
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


def test_the_narrow_overview_and_monitor_stack_rather_than_draw_empty_frames(tmp_path):
    """At 100 columns the two-column grids leave the second row of cards empty.

    Measured on 2026-10-29 at 100x36 (`ops/staging/shots-100col/`): the Monitor view
    drew two bordered boxes containing nothing at all, which is the same failure the
    compact height rules already guard against — a frame with no content reads as a
    broken console, not a small one. Neither grid had a `.narrow` rule.
    """
    for view_name, grid_id in (("overview", "#overview-grid"), ("monitor", "#monitor-grid")):
        app, _log_path = build_app(tmp_path, initial_view=view_name)

        async def scenario(app=app, grid_id=grid_id, view_name=view_name):
            async with app.run_test(size=(100, 36)) as pilot:
                await pilot.pause()
                assert app.screen.has_class("narrow"), f"{view_name}: the screen is not marked narrow"
                grid = app.query_one(grid_id)
                cards = list(app.query(f"{grid_id} > Static"))
                assert len(cards) >= 3, f"{view_name}: only {len(cards)} cards in {grid_id}"
                for card in cards:
                    assert card.region.width >= grid.region.width - 1, (
                        f"{view_name}: a card is {card.region.width} columns wide inside a "
                        f"{grid.region.width}-column grid at 100 columns of terminal"
                    )
                    assert card.region.height >= 6, f"{view_name}: a card is {card.region.height} rows tall"
                    assert str(card.renderable).strip(), f"{view_name}: {card.id} drew an empty frame"
                rows = [card.region.y for card in cards]
                assert len(set(rows)) == len(rows), f"{view_name}: cards still sit side by side"

        asyncio.run(scenario())


def test_the_wide_overview_keeps_its_two_columns(tmp_path):
    """Stacking is a response to width, not a new default.

    "Wide" means wide enough for the *cards*, not merely wider than the old
    NARROW_VIEWPORT_WIDTH: at 140 columns two columns handed each card 45 columns of
    content area while the longest row these cards draw is 53, so the honest layout
    at that window is one column. The sweep in
    test_no_card_draws_a_row_wider_than_the_column_it_was_given pins both sides.
    """
    app, _log_path = build_app(tmp_path, initial_view="overview")

    async def scenario():
        async with app.run_test(size=(180, 52)) as pilot:
            await pilot.pause()
            cards = list(app.query("#overview-grid > Static"))
            assert len(cards) >= 4, "the overview lost a card"
            side_by_side = any(
                a.region.y == b.region.y and a.region.right < b.region.x
                for a in cards
                for b in cards
                if a is not b
            )
            assert side_by_side, "an overview wide enough for two columns stacked them anyway"

    asyncio.run(scenario())


def test_a_narrow_window_drops_the_card_prose_and_keeps_the_card(tmp_path):
    """A sentence about what a card holds costs three rows in a narrow one.

    The wording half of the same decision: the prose is what pushed the data below
    the fold at 100 columns. Dropping it is progressive disclosure, not loss — the
    labels and values stay, and the same sentence survives at a width that can pay
    for it.
    """
    snapshot = add_services_to_fixture(write_snapshot_fixture(tmp_path, make_accounts(8)))

    app, _log_path = build_app(tmp_path, initial_view="overview", snapshot_file=snapshot)

    async def scenario():
        async with app.run_test(size=(100, 36)) as pilot:
            await pilot.pause()
            narrow_text = str(app.query_one("#service-pane").renderable)
            assert "Auth and world services, plus the DB check." not in narrow_text, (
                "the narrow card spends rows describing itself"
            )
            for needed in ("Realm Services", "Auth", "World", "DB"):
                assert needed in narrow_text, f"the narrow card dropped {needed}"

    asyncio.run(scenario())

    app_wide, _ = build_app(tmp_path, initial_view="overview", snapshot_file=snapshot)

    async def wide():
        async with app_wide.run_test(size=(140, 52)) as pilot:
            await pilot.pause()
            wide_text = str(app_wide.query_one("#service-pane").renderable)
            assert "Auth and world services, plus the DB check." in wide_text, (
                "the prose vanished at a width that has room for it"
            )

    asyncio.run(wide())


_DEMO_SNAPSHOT: list[str] = []


def demo_snapshot_path():
    """The documentation fixture: a fully populated realm host, generated here.

    It is the case that produces the most lines per card, and therefore the case in
    which a card runs out of rows first. It is **generated** because
    `docs/assets/dashboard-demo-snapshot.json` is gitignored — the docs driver writes
    it — and a test that opens that path on a fresh checkout gets nothing. The
    panel-geometry test did exactly that on CI, where every card of an empty snapshot
    fits its cell trivially: it passed while measuring no card at all. Building the
    fixture from the same module the driver uses keeps one source of truth, and the
    assertions below make a thin fixture a failure instead of a vacuous pass.
    """
    if not _DEMO_SNAPSHOT:
        root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        sys.path.insert(0, os.path.join(root, "docs", "assets"))
        import generate_dashboard_demo

        snapshot = generate_dashboard_demo.build_snapshot()
        assert snapshot["server"]["ok"], "the demo fixture must describe a reachable host, or an empty card proves nothing"
        assert snapshot["players"], "the demo fixture must carry players, or an empty card proves nothing"
        assert snapshot["server"]["data"]["services"], "the demo fixture must carry services, or an empty card proves nothing"
        directory = tempfile.mkdtemp(prefix="vm-dashboard-demo-")
        path = os.path.join(directory, "dashboard-demo-snapshot.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(snapshot, handle, indent=2)
        _DEMO_SNAPSHOT.append(path)
    return _DEMO_SNAPSHOT[0]


def demo_snapshot():
    with open(demo_snapshot_path(), encoding="utf-8") as handle:
        return json.load(handle)


def demo_history():
    """Twelve samples so a sparkline has a shape to draw."""
    return [
        {
            "cpu": 20.0 + step,
            "memory": 40.0 + step / 2,
            "load": 0.40 + step / 100,
            "disk": 61.0,
            "io": 5.0 + step,
        }
        for step in range(12)
    ]


def metric_row_blocks(text):
    """Each metric's block, measured as (label, rows it occupies).

    A metric starts a block on the line that names it, and the block runs to the
    line before the next metric. That is what an operator counts with their eyes:
    whether Disk is one row down or two.
    """
    labels = ("CPU", "Memory", "Load", "Disk", "I/O")
    lines = [line.strip() for line in strip_markup(text).splitlines() if line.strip()]
    marks = [(index, line.split(maxsplit=1)[0]) for index, line in enumerate(lines) if line.split(maxsplit=1)[0] in labels]
    return [
        (name, (marks[position + 1][0] - index) if position + 1 < len(marks) else len(lines) - index)
        for position, (index, name) in enumerate(marks)
    ]


def test_a_narrow_metric_card_gives_each_metric_one_row():
    """Two rows per metric is a wide-window luxury.

    Host Pressure draws a value row and a meter row per metric, and Trends draws
    a value row and a sparkline row: eight to ten rows for four numbers. Once the
    cards stack, that is the difference between seeing Disk and never knowing the
    card had one. Measured before this change: both cards used two rows per
    metric at every width.
    """
    from dashboard import render_monitor_pressure, render_monitor_trends, strip_markup

    snapshot, history = demo_snapshot(), demo_history()
    for card, render in (("Host Pressure", render_monitor_pressure), ("Trends", render_monitor_trends)):
        narrow = metric_row_blocks(render(snapshot, history, 30, narrow=True))
        assert narrow, f"{card} narrow: no metrics rendered at all"
        for name, rows in narrow:
            assert rows == 1, f"{card} narrow: {name} occupies {rows} rows; one row per metric is the point ({narrow})"

        wide = metric_row_blocks(render(snapshot, history, 30))
        assert len(wide) == len(narrow), f"{card}: the wide card shows {len(wide)} metrics, the narrow one {len(narrow)}"
        assert all(rows == 2 for _, rows in wide), (
            f"{card} wide: metric rows are {wide}; a wide window still pays for the meter/sparkline row"
        )

    # A host with no sysstat has no I/O reading, and the sentence explaining that
    # is precisely the prose a stacked card cannot afford.
    snapshot, history = demo_snapshot(), demo_history()
    no_io = json.loads(json.dumps(snapshot))
    no_io["server"]["data"]["storage_io"] = {"available": False, "status": "unavailable"}
    rows_for_io = [rows for name, rows in metric_row_blocks(render_monitor_pressure(no_io, history, 30, narrow=True)) if name == "I/O"]
    assert rows_for_io and all(rows == 1 for rows in rows_for_io), (
        f"the narrow card spends {rows_for_io} rows explaining that I/O is unavailable"
    )
    assert "install" in strip_markup(render_monitor_pressure(no_io, history, 30)), (
        "the wide card dropped the sentence that says how to get I/O history"
    )

    # The narrow sparkline also stops restating its own scale. "range 20.0–31.0%"
    # is a sentence about the shape, and the shape is right there; spending 17
    # columns on it is how a row ends up wrapped.
    trends_narrow = strip_markup(render_monitor_trends(snapshot, history, 30, narrow=True))
    for phrase in ("range ", "steady at"):
        assert phrase not in trends_narrow, f"the narrow Trends card still says {phrase!r}"
    assert "range " in strip_markup(render_monitor_trends(snapshot, history, 30)), (
        "the wide Trends card dropped the scale sentence its sparkline rows have room for"
    )


def test_a_sparkline_is_measured_against_the_metric_range_not_its_own_window():
    """Block height should answer "how busy", not "how wiggly".

    Measured on the shipped dashboard before this change: a disk usage that moved
    23.0 -> 24.0 was drawn `▁▂▄▂▅▇█▇█▇██` and a cpu that moved 24.0 -> 42.3 was
    drawn a similar full-height climb, because every sparkline normalised to its
    own min and max. Five rows that always run bottom-to-top stacked into one
    staircase in which a one-point drift and an eighteen-point climb were the
    same size, and the numbers next to them contradicted the shape.
    """
    from dashboard import SPARK_BLOCKS, render_monitor_trends, render_sparkline, strip_markup

    loud = [24.0 + step * 1.66 for step in range(12)]
    quiet = [23.0, 23.1, 23.4, 23.2, 23.6, 23.9, 24.0, 23.8, 24.0, 23.9, 24.0, 24.0]

    def heights(markup):
        row = strip_markup(markup).split()[0]
        return [SPARK_BLOCKS.index(char) for char in row if char in SPARK_BLOCKS]

    loud_row = render_sparkline(loud, domain_high=100.0)
    quiet_row = render_sparkline(quiet, domain_high=100.0)
    assert max(heights(quiet_row)) <= 2, f"a metric parked at 23-24% of a 0-100 range drew {quiet_row!r}"
    assert max(heights(loud_row)) > max(heights(quiet_row)), (
        f"cpu at 42% and disk at 24% drew the same height: {loud_row!r} / {quiet_row!r}"
    )

    # The window-relative fallback stays for a quantity with no ceiling, which is
    # what the Players sparkline needs; it must keep filling its own window.
    relative = heights(render_sparkline(quiet))
    assert min(relative) == 0 and max(relative) == len(SPARK_BLOCKS) - 1, (
        f"the no-domain fallback stopped filling its own window: {relative}"
    )

    # The helper is not the feature; the card has to pass the domain.
    trends = strip_markup(render_monitor_trends(demo_snapshot(), demo_history(), 30))
    drawn = [line.split()[0] for line in trends.splitlines() if any(char in SPARK_BLOCKS for char in line)]
    assert len(drawn) >= 4, f"the Trends card drew {len(drawn)} sparklines, expected one per metric"
    assert len(set(drawn)) == len(drawn), f"the Trends card is drawing one shape for every metric again: {drawn}"
    assert max(max(heights(row)) for row in drawn) < len(SPARK_BLOCKS) - 1, (
        f"a metric on a mostly idle host still reaches the ceiling: {drawn}"
    )


def test_a_load_sparkline_is_measured_against_the_machine_not_the_number():
    """Load average has no percentage, so its scale has to come from the box.

    The backend warns at 1x cores and goes critical at 2x -- the same arithmetic
    `normalize_load_percent` uses -- so a load of 1.7 is a quarter of the way to
    trouble on a 2-core box and a rounding error on an 8-core one. A sparkline
    that ignored the core count would draw them identically.
    """
    from dashboard import SPARK_BLOCKS, render_sparkline, spark_domain, strip_markup

    assert spark_domain("load", {"cpu": {"cores": 8}}) == 16.0
    assert spark_domain("load", {"cpu": {"cores": 2}}) == 4.0
    assert spark_domain("cpu", {"cpu": {"cores": 8}}) == 100.0

    series = [0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.65, 1.7, 1.7]

    def heights(markup):
        return [SPARK_BLOCKS.index(char) for char in strip_markup(markup) if char in SPARK_BLOCKS]

    big_box = heights(render_sparkline(series, domain_high=spark_domain("load", {"cpu": {"cores": 8}})))
    small_box = heights(render_sparkline(series, domain_high=spark_domain("load", {"cpu": {"cores": 2}})))
    assert max(small_box) > max(big_box), (
        f"the same load 1.7 should look busier on 2 cores than on 8: {big_box} vs {small_box}"
    )


def test_a_trend_sentence_says_how_far_the_metric_moved():
    """Direction without distance is texture.

    On the demo snapshot every host metric printed the word `rising`: cpu had
    climbed 18.3 points, disk 1.0. Nothing in that column could rank what was
    happening, which is why five rows of it read as a pattern rather than as
    five measurements.
    """
    import re

    from dashboard import describe_trend_with_delta, render_monitor_trends, strip_markup

    loud = [24.0 + step * 1.66 for step in range(12)]
    quiet = [23.0] * 11 + [24.0]
    assert describe_trend_with_delta(loud, "cpu") == f"rising {loud[-1] - loud[0]:+.1f}"
    assert describe_trend_with_delta(quiet, "disk") == "rising +1.0"
    assert describe_trend_with_delta([7.0, 7.0], "cpu") == "steady +0.0"
    assert describe_trend_with_delta([], "cpu") == "warming"

    trends = strip_markup(render_monitor_trends(demo_snapshot(), demo_history(), 30))
    assert re.search(r"(rising|easing|steady) [-+]\d+\.\d", trends), (
        f"the Trends card still gives direction without distance:\n{trends}"
    )


def test_the_alerts_card_says_none_without_a_heading_for_it():
    """A heading over its own negation is two rows saying what one already said.

    Measured on the demo snapshot -- nothing wrong, two events -- the card used 14
    rows at 140x52 and 11 at 100x36, and three of them were a blank row, an
    `Active Alerts` heading, and `No active alerts` sitting under it, while the state
    line two rows up had already printed `healthy  active 0`. Headings now appear
    only when something is under them, and a blank row is spent only between two
    populated blocks in a window wide enough to afford air.
    """
    import copy

    from dashboard import render_alerts_panel, strip_markup

    snapshot = demo_snapshot()
    quiet = strip_markup(render_alerts_panel(snapshot, narrow=True)).splitlines()
    assert "Active Alerts" not in quiet, f"an empty section still has a heading:\n{quiet}"
    assert "No active alerts" in quiet, "the empty state has to stay stated"
    assert "" not in quiet, f"a narrow card is still spending rows on air:\n{quiet}"

    empty = copy.deepcopy(snapshot)
    empty["server"]["data"]["alerts"]["recent_events"] = []
    nothing = strip_markup(render_alerts_panel(empty, narrow=True)).splitlines()
    assert "Recent Events" not in nothing, f"an empty section still has a heading:\n{nothing}"
    assert any("No recent events" in line for line in nothing), "the empty state has to stay stated"

    loud = copy.deepcopy(snapshot)
    loud["server"]["data"]["alerts"]["status"] = "critical"
    loud["server"]["data"]["alerts"]["active"] = [
        {"severity": "warning", "source": "world", "message": "High latency detected"},
    ]
    wide = strip_markup(render_alerts_panel(loud)).splitlines()
    assert "Active Alerts" in wide and "Recent Events" in wide, (
        f"a populated section has to keep its heading:\n{wide}"
    )
    assert wide.count("") == 2, (
        "wide air belongs under the header and between two populated blocks, nowhere else:\n"
        + "\n".join(wide)
    )


def test_a_short_terminal_keeps_the_console_target_inside_the_sidebar(tmp_path):
    """The rail beside the buttons has to end inside the window, not past it.

    The sidebar is 27 rows of content and a 24-row terminal gives it 21, so the last
    six rows -- the Console Target block naming the install prefix, the config, and
    the revision the buttons act on -- sat below the fold with only a mouse wheel to
    reach them. The pulse and target trim below SHORT_VIEWPORT_HEIGHT, and the tail
    is measured inside the column rather than assumed from the copy.
    """
    app, _log_path = build_app(tmp_path, initial_view="overview", snapshot_file=demo_snapshot_path())

    async def scenario():
        async with app.run_test(size=(80, 24)) as pilot:
            await pilot.pause()
            await wait_for(lambda: app.snapshot_loaded, message="snapshot to load")
            assert app.short_sidebar, "a 24-row terminal was not treated as short"
            sidebar = app.query_one("#sidebar")
            target = app.query_one("#sidebar-target")
            assert sidebar.max_scroll_y == 0, f"the sidebar still overflows by {sidebar.max_scroll_y} rows"
            assert target.region.bottom <= sidebar.content_region.bottom, (
                "the Console Target is still below the fold"
            )
            pulse = strip_markup(str(app.query_one("#sidebar-pulse").renderable))
            lines = strip_markup(str(target.renderable))
            assert "install" in lines and "source" in lines, lines
            assert "units" not in lines, lines
            for label in ("Players", "Auth", "World"):
                assert label in pulse, pulse
            for label in ("Refresh", "Backups", "Updated"):
                assert label not in pulse, pulse

    asyncio.run(scenario())


def test_the_sidebar_grows_its_full_copy_back_as_soon_as_it_fits(tmp_path):
    """Trimming is a fit decision, not a smaller default; 30 rows is where it ends.

    SHORT_VIEWPORT_HEIGHT was measured: 27 rows of content plus the header row and
    the column's own padding. A guard that leaves the rail trimmed at a height where
    it fits is a dashboard with less to say than it has room for.
    """
    app, _log_path = build_app(tmp_path, initial_view="overview", snapshot_file=demo_snapshot_path())

    async def scenario():
        async with app.run_test(size=(100, 30)) as pilot:
            await pilot.pause()
            await wait_for(lambda: app.snapshot_loaded, message="snapshot to load")
            assert not app.short_sidebar, "a 30-row terminal fits the rail, so it must not trim"
            sidebar = app.query_one("#sidebar")
            target = app.query_one("#sidebar-target")
            assert sidebar.max_scroll_y == 0, "the roomy rail still does not fit"
            assert target.region.bottom <= sidebar.content_region.bottom, "the tail is still cut"
            pulse = strip_markup(str(app.query_one("#sidebar-pulse").renderable))
            lines = strip_markup(str(target.renderable))
            for label in ("Updated", "Refresh", "Backups"):
                assert label in pulse, pulse
            for label in ("config", "units"):
                assert label in lines, lines

    asyncio.run(scenario())


def test_a_broken_config_refuses_to_be_trimmed_out_of_the_sidebar():
    """A line that only ever reads "ok" can go; a line that reads "invalid" cannot.

    The short rail drops the config and unit names because they are stable between
    installs -- which is exactly why they are safe to drop, and equally why a
    failure in one of them is not. Both snapshots are hand-built so only the config
    verdict differs between them.
    """

    def snapshot_with(validate_ok):
        return {
            "config_summary": {
                "install_root": "/opt/mangos",
                "auth_service": "mangos-auth",
                "world_service": "mangos-world",
            },
            "config_path": "/opt/mangos/manager/config/manager.conf",
            "config_validate": {"ok": validate_ok, "problems": [] if validate_ok else ["db host unreachable"]},
            "update_check": {"ok": True, "data": {"branch": "main", "local_commit": "c6d3339"}},
        }

    healthy = strip_markup(render_sidebar_target(snapshot_with(True), short=True))
    assert "install" in healthy and "source" in healthy, healthy
    assert "config" not in healthy and "units" not in healthy, healthy

    broken = strip_markup(render_sidebar_target(snapshot_with(False), short=True))
    assert "config" in broken and "invalid" in broken, broken
    assert "units" not in broken, broken


def test_the_narrow_window_asks_the_cards_for_their_narrow_form(tmp_path):
    """A card that *can* render one row per metric is not the same as a live card
    that does.

    The bug class is a renderer given a narrow form and a call site that never
    asks for it. Measured here against the text the pane actually drew at 100
    columns, not against a hand-made call to the same function.
    """
    for pane in ("#monitor-pressure-pane", "#monitor-trends-pane"):
        app, _log_path = build_app(tmp_path, initial_view="monitor", snapshot_file=demo_snapshot_path())

        async def scenario(app=app, pane=pane):
            async with app.run_test(size=(100, 36)) as pilot:
                await pilot.pause()
                await wait_for(lambda: app.snapshot_loaded, message="snapshot to load")
                blocks = metric_row_blocks(str(app.query_one(pane).renderable))
                assert blocks, f"{pane}: the live card drew no metrics"
                for name, rows in blocks:
                    assert rows == 1, (
                        f"{pane}: the live card spends {rows} rows on {name} in a 100-column window ({blocks})"
                    )

        asyncio.run(scenario())


def test_a_short_window_does_not_pay_for_the_air_around_its_cards(tmp_path):
    """In a 24-row terminal the chrome is the layout problem, not the cards.

    After the card work, a 100x24 Overview still showed eight rows of content: the
    grid started at row 8 because the header, a row of ``#content`` padding, a five
    row banner (heavy border, a padding row, two lines, another border) and the
    banner's bottom margin together eat a third of the window, with six more rows
    going to the command rail below. ``short`` now drops the padding the borders
    already supply: the grid begins at row 5 and the view shows twelve rows — 12 at
    100 columns, 11 at 80 — and rows below the fold fall from 34 to 30 and 41 to 37.
    A window at or above SHORT_VIEWPORT_HEIGHT is untouched: 100x36 shows 20 rows and
    140x52 shows 34, with the banner keeping its padded form.
    """
    for size, expect_view_rows in (((100, 24), 12), ((80, 24), 11), ((100, 36), 20), ((140, 52), 34)):
        app, _log_path = build_app(tmp_path, initial_view="overview", snapshot_file=demo_snapshot_path())

        async def scenario(app=app, size=size, expect_view_rows=expect_view_rows):
            async with app.run_test(size=size) as pilot:
                await pilot.pause()
                await wait_for(lambda: app.snapshot_loaded, message="snapshot to load")
                view = app.query_one("#overview-view")
                grid = app.query_one("#overview-grid")
                assert view.region.height >= expect_view_rows, (
                    f"at {size[0]}x{size[1]} the cards get {view.region.height} rows, "
                    f"expected at least {expect_view_rows}; chrome above the grid starts at row {grid.region.y}"
                )
                if size[1] < 30:
                    assert grid.region.y <= 5, (
                        f"a {size[1]}-row window put the grid at row {grid.region.y}, "
                        "so the header and banner are spending short-window rows again"
                    )
                else:
                    assert app.query_one("#content").styles.padding.top == 1, (
                        f"a {size[1]}-row window lost the padding a tall window needs"
                    )

        asyncio.run(scenario())


def test_a_card_in_a_short_window_occupies_no_rows_it_does_not_use(tmp_path):
    """A card's height must be its content plus its border, with nothing left over.

    The stacked card floors are a floor, not a target. The 9-row one was written as
    an accounting of a padded card — the Realm Services card's short form is five
    lines, plus two rows of padding, plus two rows of border — and once a compact
    window stopped paying for padding that same floor was painting two blank rows
    inside the first card of the Overview, in the window with the least room of all:
    100x24 showed one card and reported 42 rows below the fold. Measured after the
    floor was made to follow the padding, the same window reports 34 and the
    Overview's content is 42 rows rather than 50. If a card ever carries slack
    again, the equality below fails and names the card.
    """
    for size in ((100, 36), (100, 24)):
        app, _log_path = build_app(tmp_path, initial_view="overview", snapshot_file=demo_snapshot_path())

        async def scenario(app=app, size=size):
            async with app.run_test(size=size) as pilot:
                await pilot.pause()
                await wait_for(lambda: app.snapshot_loaded, message="snapshot to load")
                for card in app.query("#overview-grid > Static"):
                    lines = strip_markup(str(card.renderable)).splitlines()
                    assert card.region.height == len(lines) + 2, (
                        f"{card.id} at {size[0]}x{size[1]}: {len(lines)} rows of text in a "
                        f"{card.region.height}-row card, so {card.region.height - len(lines) - 2} "
                        "rows are painted but say nothing"
                    )

        asyncio.run(scenario())


def test_the_sidebar_never_wraps_a_line_of_its_own_text(tmp_path):
    """The rail may be narrowed, but not so far that its labels lose their values.

    Every number in the sidebar is a label and a value on one line, and a wrapped
    line there is a value alone on a row: "install" over "/opt/mangos" reads as two
    facts about nothing. This measures the rendered rail rather than a constant, so
    it still means something the next time someone rewords a line — the failure that
    produced it was "config    manager.conf ok" at 25 columns in a 23-column rail.
    """
    for size in ((80, 24), (100, 24), (100, 36), (100, 50), (140, 52)):
        app, _log_path = build_app(tmp_path, initial_view="overview", snapshot_file=demo_snapshot_path())

        async def scenario(app=app, size=size):
            async with app.run_test(size=size) as pilot:
                await pilot.pause()
                await wait_for(lambda: app.snapshot_loaded, message="snapshot to load")
                for widget in app.query("#sidebar-head, #sidebar-pulse, #sidebar-target"):
                    lines = strip_markup(str(widget.renderable)).splitlines()
                    available = widget.region.width
                    over = [line for line in lines if len(line) > available]
                    assert not over, (
                        f"{widget.id} at {size[0]}x{size[1]}: {available} columns, and these lines are longer: "
                        + "; ".join(f"{len(line)} {line!r}" for line in over[:3])
                    )

        asyncio.run(scenario())


def test_the_rail_gives_its_columns_back_only_while_its_short_form_is_showing(tmp_path):
    """The width the rail may take is decided by the text it is actually rendering.

    The rail trims its own copy below SHORT_VIEWPORT_HEIGHT, and that short form is
    the only one narrow enough to survive a narrow rail. Gating the narrower rail on
    compactness instead — which is the other short-window class the app already
    carries — shrinks the rail at 100x36 while the long config line is still being
    printed, and that line wraps: measured, the rail is 28 columns and its content
    23 there, and the line is 25. So the gate is the class that tracks the content.
    """
    for height, expect_short, expect_width in ((24, True, 28), (36, False, 32), (52, False, 32)):
        app, _log_path = build_app(tmp_path, initial_view="overview", snapshot_file=demo_snapshot_path())

        async def scenario(app=app, height=height, expect_short=expect_short, expect_width=expect_width):
            async with app.run_test(size=(100, height)) as pilot:
                await pilot.pause()
                await wait_for(lambda: app.snapshot_loaded, message="snapshot to load")
                assert app.screen.has_class("short") is expect_short, (
                    f"a {height}-row window set the short class to {not expect_short}"
                )
                assert app.short_sidebar is expect_short, (
                    f"a {height}-row window trimmed the sidebar copy to {not expect_short}"
                )
                sidebar = app.query_one("#sidebar")
                assert sidebar.region.width == expect_width, (
                    f"a {height}-row window gave the rail {sidebar.region.width} columns, expected {expect_width}"
                )

        asyncio.run(scenario())


def test_a_short_narrow_window_shows_three_of_the_four_cards(tmp_path):
    """Stacking makes a view scrollable; it does not make the cards visible.

    The card floors — 14 rows on the monitor cards, 16 on the pulse and alerts
    cards — were written for the wide two-column layout, where a card spent two
    rows per metric filling them. Stacked in a 36-row window the floor is what
    decides how many cards you can see at all. Measured before this change: the
    monitor cards began at rows 8, 23, 38 and 53 and the overview cards at 8, 23,
    36 and 53, so in both views the bottom two cards were borders behind a scroll.
    """
    for view, grid in (("monitor", "#monitor-grid"), ("overview", "#overview-grid")):
        app, _log_path = build_app(tmp_path, initial_view=view, snapshot_file=demo_snapshot_path())

        async def scenario(app=app, grid=grid, view=view):
            async with app.run_test(size=(100, 36)) as pilot:
                await pilot.pause()
                await wait_for(lambda: app.snapshot_loaded, message="snapshot to load")
                cards = list(app.query(f"{grid} > Static"))
                assert len(cards) == 4, f"{view}: expected four cards, found {len(cards)}"
                height = app.screen.size.height
                inside = [card for card in cards if card.region.y < height - 1]
                assert len(inside) >= 3, (
                    f"{view}: only {len(inside)} of four cards begin inside a {height}-row window: "
                    f"{[(card.id, card.region.y, card.region.height) for card in cards]}"
                )
                for card in cards:
                    drawn = [line for line in strip_markup(str(card.renderable)).splitlines() if line.strip()]
                    assert card.region.height >= len(drawn) + 2, (
                        f"{card.id}: {len(drawn)} rows of content in a {card.region.height}-row card, so the card clips itself"
                    )

        asyncio.run(scenario())


def test_a_narrow_service_card_gives_each_service_one_row(tmp_path):
    """Two rows per service is four rows a short window pays for padding.

    The wide card puts ``cpu``, ``mem`` and ``restarts/1h`` on their own indented
    line under the service name, and separates the services with blank rows. In a
    stacked card that is ten rows for three services. The narrow card keeps every
    number, on the row that names the service, and drops the separators the border
    already provides.
    """
    app, _log_path = build_app(tmp_path, initial_view="overview", snapshot_file=demo_snapshot_path())

    async def scenario():
        async with app.run_test(size=(100, 36)) as pilot:
            await pilot.pause()
            await wait_for(lambda: app.snapshot_loaded, message="snapshot to load")
            rows = [strip_markup(line) for line in str(app.query_one("#service-pane").renderable).splitlines() if line.strip()]
            for service in ("Auth", "World"):
                named = [line for line in rows if line.lstrip().startswith(service)]
                assert len(named) == 1, f"the narrow card spends {len(named)} rows naming {service}: {named}"
                assert "cpu" in named[0] and "mem" in named[0], (
                    f"the narrow {service} row holds only: {named[0]!r}"
                )
            assert not any(line.lstrip().startswith("cpu") for line in rows), (
                "a service still has its metrics on a second row"
            )
            for needed in ("Realm Services", "DB", "Target", "pid"):
                assert needed in "\n".join(rows), f"the narrow service card dropped {needed}"

            # A restart in the last hour is the news, so it takes the row and the
            # uptime sentence steps aside.
            snapshot = json.loads(json.dumps(app.snapshot))
            restarted = {"health": "healthy", "state": "running", "pid": 4242, "cpu_percent": 7.4, "memory_mb": 482, "uptime_human": "5h 30m", "restart_count_1h": 2}
            snapshot["server"]["data"]["services"]["world"] = restarted
            world_row = next(line for line in strip_markup(render_service_panel(snapshot, "overview", narrow=True)).splitlines() if line.lstrip().startswith("World"))
            assert "restarts/1h 2" in world_row, f"a restart in the last hour did not reach the row: {world_row!r}"
            assert "pid" not in world_row, f"a restart row that still carries a pid is a row that wraps: {world_row!r}"
            assert len(world_row) <= 57, f"the restarted service row is {len(world_row)} columns: {world_row!r}"

    asyncio.run(scenario())


def test_a_narrow_pulse_card_keeps_the_numbers_and_drops_the_lists(tmp_path):
    """The pulse card's long tail is a name list and an action reminder.

    Both are available elsewhere without scrolling the card: GM names are in the
    roster, and the open-roster key is in the command rail. The counts stay,
    because the counts are the reason the card exists.
    """
    app, _log_path = build_app(tmp_path, initial_view="overview", snapshot_file=demo_snapshot_path())

    async def scenario():
        async with app.run_test(size=(100, 36)) as pilot:
            await pilot.pause()
            await wait_for(lambda: app.snapshot_loaded, message="snapshot to load")
            text = strip_markup(str(app.query_one("#player-pulse-pane").renderable))
            for needed in ("Online Now", "Peak Window", "Count Source", "Mix", "GM Coverage", "GMs Online", "Roster"):
                assert needed in text, f"the narrow pulse card dropped {needed}"
            assert "names" not in text, "the narrow card spends a row on GM names the roster already lists"
            assert not any(line.strip().startswith("Open") for line in text.splitlines()), (
                "the narrow card repeats a key the command rail already lists"
            )

    asyncio.run(scenario())

    app_wide, _ = build_app(tmp_path, initial_view="overview", snapshot_file=demo_snapshot_path())

    async def wide():
        async with app_wide.run_test(size=(140, 52)) as pilot:
            await pilot.pause()
            await wait_for(lambda: app_wide.snapshot_loaded, message="snapshot to load")
            text = strip_markup(str(app_wide.query_one("#player-pulse-pane").renderable))
            assert "names" in text, "the wide pulse card dropped the GM names it has room for"

    asyncio.run(wide())


def test_a_narrow_process_card_gives_each_process_one_row(tmp_path):
    """The Monitor view's process card is the last two-rows-per-item card.

    Same arithmetic as the Overview's services card: stacked, the indent row costs
    the next card its place in the window. What cannot fit on one row is the
    history, so the row carries one fact of the history — a detected crash loop
    beats a restart count, and both beat the pid, which is the least actionable of
    the three when something is actually wrong.
    """
    app, _log_path = build_app(tmp_path, initial_view="monitor", snapshot_file=demo_snapshot_path())

    async def scenario():
        async with app.run_test(size=(100, 36)) as pilot:
            await pilot.pause()
            await wait_for(lambda: app.snapshot_loaded, message="snapshot to load")
            rows = [strip_markup(line) for line in str(app.query_one("#monitor-process-pane").renderable).splitlines() if line.strip()]
            for process in ("Auth", "World"):
                named = [line for line in rows if line.lstrip().startswith(process)]
                assert len(named) == 1, f"the narrow card spends {len(named)} rows naming {process}: {named}"
                assert "cpu" in named[0] and "mem" in named[0], f"the narrow {process} row holds only: {named[0]!r}"
            assert not any(line.lstrip().startswith("cpu") for line in rows), "a process still has its metrics on a second row"
            assert not any("crash loop no" in line for line in rows), "the narrow card spends columns saying nothing happened"
            assert not any("restarts/1h 0" in line for line in rows), "the narrow card spends columns saying nothing happened"
            assert any("pid" in line for line in rows), "a healthy process lost its pid"
            assert any("DB" in line and "check" in line for line in rows), "the DB check lost its row"

            snapshot = json.loads(json.dumps(app.snapshot))
            world = dict(snapshot["server"]["data"]["services"]["world"])
            world["crash_loop_detected"] = True
            world["restart_count_1h"] = 3
            snapshot["server"]["data"]["services"]["world"] = world
            rendered = strip_markup(render_monitor_processes(snapshot, narrow=True))
            world_row = next(line for line in rendered.splitlines() if line.lstrip().startswith("World"))
            assert "crash loop yes" in world_row, f"the detected crash loop did not reach the row: {world_row!r}"
            assert "restarts/1h" not in world_row and "pid" not in world_row, (
                f"the row that has news also carried the trivia, so it wraps: {world_row!r}"
            )
            assert len(world_row) <= 57, f"the crashing process row is {len(world_row)} columns: {world_row!r}"

    asyncio.run(scenario())


def test_the_wide_process_card_prints_no_denials(tmp_path):
    """"crash loop no" is not a fact anyone acts on, at any width.

    The narrow row already refuses denials; the wide row used to print one per
    service, which spends a dozen columns saying nothing happened and puts the
    denials in the same block as the news — so the eye learns to skim the block.
    The affirmative keeps the narrow row's exact wording, and the wide row is
    measured against the card that draws it rather than a number chosen here
    (standing rule 13 in the ops book: a dropped denial is only a win if the row
    that keeps the news still fits).
    """
    app, _log_path = build_app(tmp_path, initial_view="monitor", snapshot_file=demo_snapshot_path())

    async def scenario():
        async with app.run_test(size=(140, 52)) as pilot:
            await pilot.pause()
            await wait_for(lambda: app.snapshot_loaded, message="snapshot to load")
            pane = app.query_one("#monitor-process-pane")
            rendered = str(pane.renderable)
            width = pane.content_size.width
            assert width > 30, f"the monitor process card has {width} columns of content area at 140 columns wide"
            for line in strip_markup(rendered).splitlines():
                if line.strip():
                    assert len(line) <= width, f"a wide process row is {len(line)} columns in {width} of content area: {line!r}"
            assert "crash loop" not in strip_markup(rendered), "the wide card printed a denial next to a healthy service"
            assert "restarts/1h" in strip_markup(rendered), "the wide card lost the restart count it has room for"

            snapshot = json.loads(json.dumps(app.snapshot))
            world = dict(snapshot["server"]["data"]["services"]["world"])
            world["crash_loop_detected"] = True
            snapshot["server"]["data"]["services"]["world"] = world
            flagged = strip_markup(render_monitor_processes(snapshot, narrow=False))
            line = next(l for l in flagged.splitlines() if "crash loop" in l)
            assert "crash loop yes" in line, f"the crash loop is not stated in the row's own wording: {line!r}"
            assert flagged.count("crash loop") == 1, "a service that is not looping still got a denial"
            for l in flagged.splitlines():
                if l.strip():
                    assert len(l) <= width, (
                        f"the row that gained news grew to {len(l)} columns in {width} of content area: {l!r}"
                    )

    asyncio.run(scenario())


def test_no_card_draws_a_row_wider_than_the_column_it_was_given(tmp_path):
    """Two columns of window is not two columns of card.

    The card grids used to go two-across as soon as the window passed
    NARROW_VIEWPORT_WIDTH, and at 140 columns that handed each Overview card 45
    columns of content area and the Monitor's process card 37 -- while the longest
    row those cards draw is 53. The row wraps, and in a grid a wrapped row is a row
    the card loses: the older narrow rule exists because somebody saw empty bordered
    frames at 100 columns, and this is the same fault at a width nobody had probed.
    Every line the app actually drew is measured against the content area of the
    card that drew it, at widths on both sides of the breakpoint, and the layout is
    checked to still be two columns above it -- a guard that passes because the
    dashboard gave up on side-by-side cards is guarding nothing.
    """
    panes = {
        "overview": ("#overview-grid", ("#service-pane", "#metrics-pane", "#player-pulse-pane", "#alerts-pane")),
        "monitor": ("#monitor-grid", ("#monitor-pressure-pane", "#monitor-process-pane", "#monitor-trends-pane")),
    }
    for width in (100, 122, 140, 150, 158, 170, 200):
        for view, (grid, cards) in panes.items():
            app, _log_path = build_app(tmp_path, initial_view=view, snapshot_file=demo_snapshot_path())

            async def scenario(app=app, grid=grid, cards=cards, width=width, view=view):
                async with app.run_test(size=(width, 52)) as pilot:
                    await pilot.pause()
                    await wait_for(lambda: app.snapshot_loaded, message="snapshot to load")
                    grid_width = app.query_one(grid).content_size.width
                    assert grid_width > 20, f"{view} at {width}: the card grid has {grid_width} columns"
                    for pane in cards:
                        card = app.query_one(pane)
                        area = card.content_size.width
                        # How many columns the grid is really drawing, measured off
                        # the card instead of read out of a Textual style the test
                        # could misread: a single-column card nearly fills the grid,
                        # a two-column card gets about half of it.
                        across = 1 if area > grid_width * 0.8 else 2
                        expected = 2 if width >= TWO_COLUMN_MINIMUM_WIDTH else 1
                        assert across == expected, (
                            f"{view} at {width}: {pane} sits in {area} of {grid_width} grid columns, "
                            f"which is {across} across; expected {expected}"
                        )
                        assert area > 0, f"{view} at {width}: {pane} has no content area"
                        for line in strip_markup(str(card.renderable)).splitlines():
                            if line.strip():
                                assert len(line) <= area, (
                                    f"{view} at {width}: {pane} drew a {len(line)}-column row into "
                                    f"{area} columns of content area, so it wraps: {line!r}"
                                )

            asyncio.run(scenario())


def test_the_narrow_rows_stay_inside_their_card(tmp_path):
    """A row that wraps is a row the card loses.

    Every narrow line is measured against the width of the card that draws it in a
    100-column window: the bound is whatever the card actually has, not a number
    chosen in the source. Measured before this change, the Realm Services row
    pushed ``pid 231004`` onto its own line, so the card spent a row on six digits.
    """
    panes = {
        "monitor": (
            ("#monitor-pressure-pane", lambda snapshot, history: render_monitor_pressure(snapshot, history, 30, narrow=True)),
            ("#monitor-process-pane", lambda snapshot, history: render_monitor_processes(snapshot, narrow=True)),
            ("#monitor-trends-pane", lambda snapshot, history: render_monitor_trends(snapshot, history, 30, narrow=True)),
        ),
        "overview": (
            ("#service-pane", lambda snapshot, history: render_service_panel(snapshot, "overview", narrow=True)),
            ("#metrics-pane", lambda snapshot, history: render_metrics_panel(snapshot, history, 30, narrow=True)),
            ("#player-pulse-pane", lambda snapshot, history: render_player_pulse(snapshot, history, 30, narrow=True)),
            ("#alerts-pane", lambda snapshot, history: render_alerts_panel(snapshot, narrow=True)),
        ),
    }
    for view, cards in panes.items():
        app, _log_path = build_app(tmp_path, initial_view=view, snapshot_file=demo_snapshot_path())

        async def scenario(app=app, cards=cards, view=view):
            async with app.run_test(size=(100, 36)) as pilot:
                await pilot.pause()
                await wait_for(lambda: app.snapshot_loaded, message="snapshot to load")
                snapshot, history = app.snapshot, app.metric_history
                for pane, render in cards:
                    card = app.query_one(pane)
                    # The gutter — border and padding — is what the card spends of
                    # its own width before a single character of content fits.
                    width = card.content_size.width
                    assert width > 30, f"{view}: {pane} has {width} columns of content area, which is not a usable card"
                    for line in strip_markup(render(snapshot, history)).splitlines():
                        assert len(line) <= width, (
                            f"{view}: {pane} drew a {len(line)}-column row into {width} columns of content area, so it wraps: {line!r}"
                        )

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


def test_a_chrome_restatement_with_a_form_open_leaves_the_form_alone(tmp_path):
    """The resize that makes the rail recount its rows must not reach into a modal.

    A pushed screen is the whole display, and the sidebar, banner, and rail it
    covers are not in its widget tree. Restating them then queried nodes that do
    not exist on this screen, and the resulting crash took the open form down with
    it -- the operator losing a half-filled account form because the window
    happened to change size. The chrome waits for the modal to go away.
    """
    app, _log_path = build_app(tmp_path, initial_view="overview", snapshot_file=demo_snapshot_path())

    async def scenario():
        async with app.run_test(size=(140, 52)) as pilot:
            await pilot.pause()
            await wait_for(lambda: app.snapshot_loaded, message="snapshot to load")
            await pilot.press("x")  # stop realm: a confirmation on its own screen
            await pilot.pause()
            assert app.screen.__class__.__name__ == "ConfirmScreen", "no modal opened to test against"
            app.call_after_refresh(app.refresh_chrome)
            await pilot.pause()
            assert app.screen.__class__.__name__ == "ConfirmScreen", (
                "restating the chrome dismissed or crashed the open modal"
            )
            await pilot.press("escape")
            await pilot.pause()
            assert app.screen.__class__.__name__ != "ConfirmScreen", "the modal outstayed its cancel"
            above, below = app.view_scroll_extent()
            assert below > 0, "the base screen forgot how much of the view was out of sight"

    asyncio.run(scenario())


def test_a_stacked_view_can_be_reached_by_keyboard(tmp_path):
    """Cards below the fold have to be reachable without a mouse.

    Measured at 140 columns -- the width the documentation screenshot is taken at
    -- the Overview needs more rows than the window has, and Textual gives that
    overflow to the mouse wheel alone. So the operator on a terminal with no wheel
    did not have a hidden Alerts card; they had no Alerts card at all. These keys
    are the difference between content off-screen and content that does not exist,
    and the assertion is about the last card being inside the window, not about
    any scroll offset.
    """
    app, _log_path = build_app(tmp_path, initial_view="overview", snapshot_file=demo_snapshot_path())

    async def scenario():
        async with app.run_test(size=(140, 52)) as pilot:
            await pilot.pause()
            await wait_for(lambda: app.snapshot_loaded, message="snapshot to load")
            view = app.query_one("#overview-view")
            alerts = app.query_one("#alerts-pane")
            assert view.max_scroll_y > 0, "this has to be a size where the view overflows"
            assert alerts.region.y >= view.content_region.bottom, (
                "the Alerts card should start out of sight, or the test proves nothing"
            )
            await pilot.press("end")
            await pilot.pause()
            assert alerts.region.bottom <= view.content_region.bottom, (
                "End left the last card out of the window"
            )
            assert app.view_scroll_extent()[0] > 0, "at the bottom, the rows must count as above"
            await pilot.press("home")
            await pilot.pause()
            above, below = app.view_scroll_extent()
            assert above == 0, "Home did not return to the top"
            assert below == int(view.max_scroll_y)
            assert alerts.region.y >= view.content_region.bottom

    asyncio.run(scenario())


def test_the_view_also_rolls_one_line_and_one_page_at_a_time(tmp_path):
    """End and Home jump; the operator also wants to stop somewhere in between."""
    app, _log_path = build_app(tmp_path, initial_view="overview", snapshot_file=demo_snapshot_path())

    async def scenario():
        async with app.run_test(size=(140, 52)) as pilot:
            await pilot.pause()
            await wait_for(lambda: app.snapshot_loaded, message="snapshot to load")
            view = app.query_one("#overview-view")
            for _ in range(3):
                await pilot.press("down")
                await pilot.pause()
            assert view.scroll_y == 3, f"three Downs moved it {view.scroll_y} rows"
            await pilot.press("pageup")
            await pilot.pause()
            assert view.scroll_y < 3, "Page Up did not move the view back up"
            await pilot.press("up")
            await pilot.pause()
            assert view.scroll_y < 2, "Up did not move the view one row further"

    asyncio.run(scenario())


def test_the_rail_offers_scroll_only_for_a_view_that_has_more_in_it():
    """No scroll row for a view that fits; the exact count when it does not."""
    plain = strip_markup(render_command_rail("overview")).splitlines()
    assert not any(row.startswith("Scroll") for row in plain), (
        "a view that fits advertised a scroll it cannot perform"
    )
    below = strip_markup(render_command_rail("overview", rows_below=26)).splitlines()
    assert len(below) == len(plain) + 1, "the scroll row did not get its own line"
    assert below[-1].startswith("Scroll"), "the scroll row is not labelled"
    assert "26 rows below" in below[-1]
    for token in ("↑", "↓", "PgUp", "PgDn", "Home", "End"):
        assert token in below[-1], f"the rail named a scroll without naming {token}"
    both = strip_markup(render_command_rail("overview", rows_above=3, rows_below=26)).splitlines()[-1]
    assert "3 rows above" in both and "26 rows below" in both, (
        "standing in the middle of a view, the rail counted only one direction"
    )
    single = strip_markup(render_command_rail("overview", rows_below=1)).splitlines()[-1]
    assert "1 row below" in single and "1 rows" not in single
    narrow = strip_markup(render_command_rail("overview", narrow=True, rows_below=26)).splitlines()
    assert narrow[-1] == below[-1], "the narrow rail reworded the scroll row into something else"
    assert not any(row.startswith("Navigate") for row in narrow)


def test_the_scroll_count_comes_from_the_layout_and_not_from_wish(tmp_path):
    """The rail's promise is measured off the window it is drawn in.

    A 180-column window lays the cards out in two columns and fits them all; the
    same Overview at 140 stacks into a single column and overflows. Both facts are
    the layout's, and the rail has to agree with the layout in each case rather
    than with a constant in the code.
    """
    demo = demo_snapshot_path()

    async def scenario():
        for cols, lines, expect_overflow in ((180, 52, False), (140, 52, True), (100, 36, True)):
            app, _log_path = build_app(tmp_path, initial_view="overview", snapshot_file=demo)
            async with app.run_test(size=(cols, lines)) as pilot:
                await pilot.pause()
                await wait_for(lambda: app.snapshot_loaded, message="snapshot to load")
                above, below = app.view_scroll_extent()
                rail = strip_markup(str(app.query_one("#command-rail", Static).renderable))
                if expect_overflow:
                    assert below > 0, f"{cols}x{lines}: the view overflows but reported nothing"
                    assert f"{below} rows below" in rail, (
                        f"{cols}x{lines}: the rail did not say {below} rows were below"
                    )
                else:
                    assert (above, below) == (0, 0), (
                        f"{cols}x{lines}: reported {above} above and {below} below for a view that fits"
                    )
                    assert "Scroll" not in rail, f"{cols}x{lines}: offered a scroll with nothing to scroll"

    asyncio.run(scenario())


def test_a_focused_table_keeps_its_cursor_when_the_view_also_scrolls(tmp_path):
    """Scroll keys live on the view, not on top of the table being read.

    Accounts at 100 columns stacks, so the view scrolls and the table has its own
    cursor keys for the same arrows. The table is deeper in the tree, so Textual
    gives it the key first; if that ever reverses, the operator moving through a
    list of accounts would instead move the whole view and never notice.
    """
    app, _log_path = build_app(tmp_path, initial_view="accounts")

    async def scenario():
        async with app.run_test(size=(100, 36)) as pilot:
            table = app.query_one("#accounts-table", DataTable)
            await wait_for(lambda: table.row_count > 0, message="accounts table to load")
            view = app.query_one("#accounts-view")
            await pilot.pause()
            assert view.max_scroll_y > 0, "this has to be a size where the view overflows"
            table.focus()
            await pilot.pause()
            for _ in range(2):
                await pilot.press("down")
                await pilot.pause()
            assert table.cursor_row == 2, f"the table cursor moved to row {table.cursor_row}"
            assert view.scroll_y == 0, "the view moved instead of the table cursor"

    asyncio.run(scenario())


def test_a_scroll_key_over_a_modal_does_not_move_the_view_behind_it(tmp_path):
    """A modal is its own screen, so the view underneath keeps its place."""
    app, _log_path = build_app(tmp_path, initial_view="overview", snapshot_file=demo_snapshot_path())

    async def scenario():
        async with app.run_test(size=(140, 52)) as pilot:
            await pilot.pause()
            await wait_for(lambda: app.snapshot_loaded, message="snapshot to load")
            view = app.query_one("#overview-view")
            await pilot.press("end")
            await pilot.pause()
            scrolled = view.scroll_y
            assert scrolled > 0
            await pilot.press("x")  # stop realm: a confirmation on its own screen
            await pilot.pause()
            assert app.screen.__class__.__name__ == "ConfirmScreen", "no modal opened to test against"
            await pilot.press("end")
            await pilot.press("pagedown")
            await pilot.pause()
            assert app.screen.__class__.__name__ == "ConfirmScreen", "a scroll key dismissed the modal"
            assert view.scroll_y == scrolled, "the keys under the modal moved the view behind it"
            await pilot.press("escape")
            await pilot.pause()
            await pilot.press("home")
            await pilot.pause()
            assert view.scroll_y == 0, "the view stopped answering its scroll keys after the modal closed"

    asyncio.run(scenario())


def test_the_rail_stops_naming_keys_a_focused_table_is_already_keeping(tmp_path):
    """A table answers the arrows itself, so the legend must not promise them twice.

    At 100 columns the Accounts table takes the whole width and the account details
    under it fall outside the window, which is a Scroll row the rail has to report.
    The keys it names there cannot be the arrows: DataTable binds all six for its own
    cursor, bindings resolve from the focused widget outward, and pressing down in
    that window moves a row rather than the view. Measured against Textual 0.89: the
    table keeps the view exactly where it is.
    """
    app, _log_path = build_app(tmp_path, initial_view="accounts", snapshot_file=demo_snapshot_path())

    async def scenario():
        async with app.run_test(size=(100, 36)) as pilot:
            await pilot.pause()
            await wait_for(lambda: app.snapshot_loaded, message="snapshot to load")
            table = app.query_one("#accounts-table")
            assert table.has_focus, "the accounts table is not what this window focuses"
            above, below = app.view_scroll_extent()
            assert above + below > 0, "the accounts view stopped overflowing, so this proves nothing"
            await pilot.pause()
            rail = strip_markup(str(app.query_one("#command-rail", Static).renderable))
            assert "the table keeps the arrow keys" in rail, rail
            for glyph in ("\u2191", "\u2193", "PgUp", "PgDn", "Home", "End"):
                assert glyph not in rail, f"the rail still offers {glyph} to a focused table"
            before = app.view_scroll_extent()
            await pilot.press("down")
            await pilot.pause()
            assert app.query_one("#accounts-table").cursor_row == 1, "the table did not keep its own arrow"
            assert app.view_scroll_extent() == before, "the view moved under a key the table owns"

    asyncio.run(scenario())


def test_a_search_box_keeps_its_caret_keys_and_the_rail_says_which(tmp_path):
    """Home and End belong to a focused search field; the arrows still scroll the view.

    The split matters because the legend is read while the operator is typing: naming
    Home over a search box would promise a jump to the top of the view that the Input
    swallows for its caret, and hiding the arrows would hide a scroll that does work.
    """
    app, _log_path = build_app(tmp_path, initial_view="accounts", snapshot_file=demo_snapshot_path())

    async def scenario():
        async with app.run_test(size=(100, 36)) as pilot:
            await pilot.pause()
            await wait_for(lambda: app.snapshot_loaded, message="snapshot to load")
            await pilot.press("/")
            await pilot.pause()
            search = app.query_one("#accounts-search")
            assert search.has_focus, "the search field did not take focus"
            rail = strip_markup(str(app.query_one("#command-rail", Static).renderable))
            assert "Home" not in rail and "End" not in rail, rail
            for glyph in ("\u2191", "\u2193", "PgUp", "PgDn"):
                assert glyph in rail, f"the rail stopped offering {glyph}, which the search field does not claim"
            await pilot.press("home")
            await pilot.pause()
            assert app.view_scroll_extent()[1] > 0, "the view scrolled under a key the search field owns"

    asyncio.run(scenario())


def test_the_widgets_named_as_keeping_keys_really_do(tmp_path):
    """The legend's honesty rests on what Textual's widgets bind, so that is measured.

    The two claim sets are a fact about a dependency, not about this dashboard, and a
    Textual upgrade that hands Home and End to a table would leave the rail quoting a
    key the table eats. Re-reading BINDINGS is the cheapest way to notice.
    """
    from textual.widgets import DataTable, Input

    def bound_keys(widget_class) -> set[str]:
        # A BINDINGS entry can name several keys for one action ("end,ctrl+e").
        return {key.strip() for binding in widget_class.BINDINGS for key in binding.key.split(",")}

    table_keys = bound_keys(DataTable)
    search_keys = bound_keys(Input)
    assert SCROLL_KEYS_CLAIMED_BY_TABLE <= table_keys, sorted(SCROLL_KEYS_CLAIMED_BY_TABLE - table_keys)
    assert SCROLL_KEYS_CLAIMED_BY_SEARCH <= search_keys, sorted(SCROLL_KEYS_CLAIMED_BY_SEARCH - search_keys)
    assert {"up", "down", "pageup", "pagedown"}.isdisjoint(search_keys), (
        "a search field now answers the arrows, and the rail needs to know"
    )


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


def test_a_rail_row_never_parts_a_key_from_the_word_that_explains_it(tmp_path):
    """The rail wraps between key/label pairs, never inside one.

    The rail is a Static, so a row wider than the rail is word-wrapped by the
    renderer, and the renderer breaks between a key and the word that explains it.
    Measured at 100x36 before this test existed: the Overview rail drew "... b backup
    v" and then opened the next line with "verify k validate" -- a key glyph pointing
    at nothing, followed by a word that reads like a key. Nothing in the suite noticed
    because the rail assertions read its markup, and the markup was one correct line;
    the damage was done afterwards, in the renderer.

    So this reads the width the rail actually painted into and the markup the running
    app set, and requires that no line needs re-wrapping and no pair is split. The
    "would have overflowed" guard keeps the case honest: at a width where nothing had
    to wrap, the test would be describing a window that proves nothing.
    """
    demo = demo_snapshot_path()

    async def scenario():
        for cols, lines, expect_overflow in ((100, 36, True), (80, 24, True), (140, 52, False)):
            app, _log_path = build_app(tmp_path, initial_view="overview", snapshot_file=demo)
            async with app.run_test(size=(cols, lines)) as pilot:
                await pilot.pause()
                await wait_for(lambda: app.snapshot_loaded, message="the demo snapshot to load")
                width = app.command_rail_width()
                assert width > 0, f"{cols}x{lines}: the rail reported no content width, so it wrapped by luck"
                rows = strip_markup(str(app.query_one("#command-rail", Static).renderable)).splitlines()
                unwrapped = strip_markup(
                    render_command_rail(
                        "overview",
                        narrow=app.narrow_viewport,
                        rows_below=app.view_scroll_extent()[1],
                    )
                ).splitlines()
                if expect_overflow:
                    assert max(len(row) for row in unwrapped) > width, (
                        f"{cols}x{lines}: no rail row was wider than the rail, so this window cannot show a split"
                    )
                for row in rows:
                    assert len(row) <= width, (
                        f"{cols}x{lines}: the rail emitted a {len(row)}-cell line into a {width}-cell box; "
                        f"the renderer gets the last word again: {row!r}"
                    )
                    assert not re.search(r"\s[a-zA-Z]$", row), (
                        f"{cols}x{lines}: {row!r} ends with a bare key glyph; its label is on the next line"
                    )
                for key, label in view_command_tokens("overview", narrow=app.narrow_viewport):
                    assert any(f"{key} {label}" in row for row in rows), (
                        f"{cols}x{lines}: {key!r} was parted from {label!r}"
                    )

    asyncio.run(scenario())


def test_a_short_roster_does_not_keep_a_frame_it_has_no_rows_for(tmp_path):
    """Eight accounts get a nine-row table, not a window-sized one.

    `#accounts-table { height: 1fr }` laid a 29-row table inside a 31-row border at
    140x52 for a realm with eight accounts — 21 rows of frame holding nothing,
    drawn as a box an operator has to read past to find the bottom. Backups and
    the log roster had the same shape. The height is now chosen against the rows
    the view owns, so the frame stops at the last row instead of at the window.
    """
    app, _log_path = build_app(tmp_path, initial_view="accounts")

    async def scenario():
        async with app.run_test(size=(140, 52)) as pilot:
            table = app.query_one("#accounts-table", DataTable)
            await wait_for(lambda: table.row_count > 0, message="accounts table to load")
            await pilot.pause()
            rows = table.row_count
            panel = app.query_one("#accounts-table-layout")
            view = app.query_one("#accounts-view")
            assert rows == 8, f"this fixture is supposed to hold eight accounts, got {rows}"
            assert table.content_size.height == rows + 1, (
                f"the table holds {rows} rows and was given {table.content_size.height}"
            )
            assert panel.content_size.height < view.content_size.height, (
                f"the roster frame is {panel.content_size.height} rows in a "
                f"{view.content_size.height}-row view: it stretched to the window again"
            )

    asyncio.run(scenario())


def test_a_roster_longer_than_the_window_fills_it_and_scrolls_itself(tmp_path):
    """The exception that keeps the arrow keys working survives the rule above.

    Eighty accounts do not fit, so the table fills the view and scrolls on its
    own: a cursor that moves inside a widget the view cannot follow is how a
    roster becomes unreadable. Both postures have to stay true, and neither may
    be chosen from a number guessed at the terminal's minimum size.
    """
    app, _log_path = build_app(
        tmp_path, initial_view="accounts", accounts=make_accounts(80)
    )

    async def scenario():
        async with app.run_test(size=(140, 52)) as pilot:
            table = app.query_one("#accounts-table", DataTable)
            await wait_for(lambda: table.row_count >= 80, message="eighty-row roster to load")
            await pilot.pause()
            view = app.query_one("#accounts-view")
            assert table.content_size.height < table.row_count, (
                "the table grew to its rows instead of clipping them to the window"
            )
            assert table.content_size.height >= view.content_size.height - 8, (
                f"a roster that does not fit filled only {table.content_size.height} "
                f"rows of a {view.content_size.height}-row view"
            )
            table.focus()
            for _ in range(2):
                await pilot.press("pagedown")
                await pilot.pause()
            assert table.cursor_row > 0, (
                f"pagedown left the cursor on row {table.cursor_row}; the table is not "
                "keeping the arrow keys it is credited with"
            )
            assert table.scroll_y > 0, "the table never scrolled to show the row it selected"

    asyncio.run(scenario())


def test_the_scheduled_tasks_card_holds_what_it_drew_a_border_around(tmp_path):
    """An `1fr` panel inside an auto-height layout collapses to nothing.

    That is what the Operations view shipped with: the Scheduled Tasks border drew
    itself a few rows tall while its title, roster, and details pane were laid out
    underneath it and clipped away, so an operator who pressed 7 found an empty
    box. The card sizes to its content now, and the roster inside it is never
    shorter than the details pane beside it — one border, one bottom edge.
    """
    demo = demo_snapshot_path()

    async def scenario():
        for cols, lines, same_bottom_edge in ((140, 52, True), (100, 36, False)):
            app, _log_path = build_app(
                tmp_path, initial_view="operations", snapshot_file=demo
            )
            async with app.run_test(size=(cols, lines)) as pilot:
                table = app.query_one("#schedules-table", DataTable)
                await wait_for(
                    lambda: table.row_count > 0, message="scheduled tasks table to load"
                )
                await pilot.pause()
                panel = app.query_one("#schedules-layout")
                title = panel.query(".table-detail-title").first()
                details = app.query_one("#schedule-details")
                assert panel.content_size.height > 0, (
                    f"{cols}x{lines}: the card has no height to draw"
                )
                for widget, what in (
                    (title, "the card title"),
                    (table, "the roster"),
                    (details, "the details pane"),
                ):
                    assert widget.region.y >= panel.region.y, (
                        f"{cols}x{lines}: {what} sits above the border drawn around it"
                    )
                    assert widget.region.bottom <= panel.region.bottom, (
                        f"{cols}x{lines}: {what} hangs below the border drawn around it"
                    )
                if same_bottom_edge:
                    assert table.content_size.height >= details.content_size.height, (
                        f"{cols}x{lines}: the roster is {table.content_size.height} rows "
                        f"beside a {details.content_size.height}-row pane — two bottom edges"
                    )

    asyncio.run(scenario())


def test_the_schedules_roster_fits_the_frame_it_was_given(tmp_path):
    """Four columns of this data want more room than the card has.

    The roster is handed 56 columns at 140x52 and 57 at 100x36; Type, Schedule,
    Next Run, and the timer name want 69. Textual's answer is a horizontal
    scrollbar along the bottom of the table and a column nobody can finish
    reading. The timer's name is printed by the details pane beside the table, so
    the roster keeps the three columns that answer what runs, when it runs, and
    when it runs next — and nothing here scrolls sideways.
    """
    demo = demo_snapshot_path()

    async def scenario():
        for cols, lines in ((140, 52), (100, 36)):
            app, _log_path = build_app(
                tmp_path, initial_view="operations", snapshot_file=demo
            )
            async with app.run_test(size=(cols, lines)) as pilot:
                table = app.query_one("#schedules-table", DataTable)
                await wait_for(
                    lambda: table.row_count >= 2, message="two scheduled tasks to load"
                )
                await pilot.pause()
                assert table.row_count >= 2, "a one-row roster cannot measure a column fit"
                assert table.max_scroll_x == 0, (
                    f"{cols}x{lines}: the roster wants {table.virtual_size.width} columns in a "
                    f"{table.content_size.width}-column frame and scrolls sideways"
                )

    asyncio.run(scenario())
