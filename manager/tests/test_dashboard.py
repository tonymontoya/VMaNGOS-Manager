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

import pytest
from textual.widgets import DataTable

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
    if not os.path.exists(log_path):
        return []
    with open(log_path, "r", encoding="utf-8") as handle:
        return [line.strip() for line in handle.read().splitlines() if line.strip()]


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


def build_app(tmp_path, *, initial_view, accounts=None):
    stub, log_path = write_recorder_stub(tmp_path)
    if accounts is None:
        accounts = make_accounts(8)
    snapshot_file = write_snapshot_fixture(tmp_path, accounts)
    app = create_app(
        manager_bin=stub,
        config_path="/dev/null",
        refresh=30,
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
