"""Install wizard tests (#102).

Seams (agreed):
- Pure logic (secrets parsing, defaults, gate table, secrets rendering,
  launch command) is tested directly, no TTY.
- The running app: create_wizard_app(...) driven via App.run_test() --
  button presses and DOM assertions only.
- The runner: create_wizard_app(runner=fake) -- the fake records the
  command and returns a canned result, so no systemd is involved.
"""

import asyncio
import os

import pytest
from textual.widgets import Button, Static

import wizard as w

pytestmark = pytest.mark.filterwarnings("ignore::pytest.PytestUnhandledThreadExceptionWarning")

SECRETS_KEYS = (
    "SQLADMINUSER",
    "SQLADMINIP",
    "SQLADMINPASS",
    "MANGOSDBUSER",
    "MANGOSDBPASS",
    "MANGOSOSUSER",
    "AUTHDB",
    "WORLDDB",
    "CHARACTERDB",
    "LOGSDB",
    "INSTALLROOT",
    "CLIENTDATA",
    "SKIP_SECURE_MYSQL",
    "PROVISIONTARGET",
    "REINSTALL_POLICY",
)


def write_fixture_secrets(directory, **overrides):
    """A setup.conf in the auto_install.sh format, values overridable."""
    values = {
        "SQLADMINUSER": "root",
        "SQLADMINIP": "%",
        "SQLADMINPASS": "Adm1n!Pass",
        "MANGOSDBUSER": "mangos",
        "MANGOSDBPASS": "M4ng0s!Pass",
        "MANGOSOSUSER": "mangos",
        "AUTHDB": "auth",
        "WORLDDB": "world",
        "CHARACTERDB": "characters",
        "LOGSDB": "logs",
        "INSTALLROOT": os.path.join(directory, "installroot"),
        "CLIENTDATA": os.path.join(directory, "clientdata"),
        "SKIP_SECURE_MYSQL": "yes",
        "PROVISIONTARGET": "vmangos_manager",
        "REINSTALL_POLICY": "abort",
    }
    values.update(overrides)
    path = os.path.join(directory, "setup.conf")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(
            "# VMANGOS Installation Secrets\n"
            "# Generated: 2026-08-01T00:00:00+00:00\n"
            "# Permissions: root:root 600\n"
        )
        for key, value in values.items():
            handle.write(f'{key}="{value}"\n')
    return path


def make_values(client_data="/tmp/exists", db_password="db-pass", sql_admin_pass="admin-pass"):
    return w.InstallValues(
        install_root="/opt/mangos",
        client_data=client_data,
        auth_db="auth",
        world_db="world",
        characters_db="characters",
        logs_db="logs",
        db_user="mangos",
        db_password=db_password,
        os_user="mangos",
        provision_target="vmangos_manager",
        sql_admin_pass=sql_admin_pass,
    )


# ---------------------------------------------------------------------------
# Pure layer
# ---------------------------------------------------------------------------


def test_generate_password_charset_and_length():
    for _ in range(50):
        password = w.generate_password()
        assert len(password) == 24
        assert set(password) <= set(w.PASSWORD_CHARSET)


def test_generate_password_rejects_bad_arguments():
    with pytest.raises(ValueError):
        w.generate_password(length=0)
    with pytest.raises(ValueError):
        w.generate_password(charset="")


def test_gate_decision_table():
    root = "/opt/mangos"
    assert w.gate_decision("clean", "", "", root) == "form"
    assert w.gate_decision("clean", "resume", "", root) == "form"

    assert w.gate_decision("resume", "", "", root) == "form"
    assert w.gate_decision("resume", "resume", "", root) == "form"
    assert w.gate_decision("resume", "start_over", "wrong", root) == "confirm-start-over"
    assert w.gate_decision("resume", "start_over", root, root) == "form-fresh"
    assert w.gate_decision("resume", "cancel", "", root) == "cancel"

    assert w.gate_decision("replace", "", "", root) == "confirm-replace"
    assert w.gate_decision("replace", "replace", "wrong", root) == "confirm-replace"
    assert w.gate_decision("replace", "replace", root, root) == "form-fresh"
    assert w.gate_decision("replace", "cancel", "", root) == "cancel"

    # The abort policy is always honored: no destructive path exists.
    assert w.gate_decision("abort", "replace", root, root) == "refuse"
    assert w.gate_decision("abort", "start_over", root, root) == "refuse"

    assert w.gate_decision("bogus", "", "", root) == "refuse"


def test_client_data_exemption():
    assert w.client_data_required(False, "") is True
    assert w.client_data_required(True, "START") is True
    assert w.client_data_required(True, "SOURCE_DONE") is True
    assert w.client_data_required(True, "DATA_DONE") is False
    assert w.client_data_required(True, "DB_IMPORT_DONE") is False
    assert w.client_data_required(True, "SERVICES_DONE") is False


def test_form_defaults_from_fixture_secrets(tmp_path):
    os.makedirs(os.path.join(tmp_path, "clientdata"), exist_ok=True)
    secrets_path = write_fixture_secrets(tmp_path, INSTALLROOT="/srv/vm", AUTHDB="authdb")
    secrets = w.parse_secrets_file(secrets_path)
    values = w.form_defaults(secrets)

    assert values.install_root == "/srv/vm"
    assert values.client_data == os.path.join(str(tmp_path), "clientdata")
    assert values.auth_db == "authdb"
    assert values.world_db == "world"
    assert values.db_user == "mangos"
    assert values.db_password == "M4ng0s!Pass"
    assert values.sql_admin_pass == "Adm1n!Pass"
    assert values.provision_target == "vmangos_manager"
    assert values.reinstall_policy == "abort"


def test_form_defaults_generate_missing_passwords(tmp_path):
    values = w.form_defaults({})
    assert len(values.db_password) == 24
    assert set(values.db_password) <= set(w.PASSWORD_CHARSET)
    assert len(values.sql_admin_pass) == 24
    assert values.install_root == "/opt/mangos"
    assert values.provision_target == "vmangos_manager"


def test_render_setup_conf_exact_format():
    values = make_values()
    text = w.render_setup_conf(values, "2026-09-01T00:00:00+00:00")

    lines = text.splitlines()
    assert lines[0] == "# VMANGOS Installation Secrets"
    assert lines[1] == "# Generated: 2026-09-01T00:00:00+00:00"
    assert lines[2] == "# Permissions: root:root 600"

    for key in SECRETS_KEYS:
        assert any(line.startswith(f'{key}="') for line in lines), key

    assert 'MANGOSDBPASS="db-pass"' in lines
    assert 'SQLADMINPASS="admin-pass"' in lines
    assert 'INSTALLROOT="/opt/mangos"' in lines
    assert 'REINSTALL_POLICY="abort"' in lines

    # Every key exactly once, in the documented order.
    order = [line.split("=")[0] for line in lines if "=" in line and not line.startswith("#")]
    assert order == list(SECRETS_KEYS)


def test_write_setup_conf_permissions_atomic_and_parseable(tmp_path):
    values = make_values()
    target = os.path.join(str(tmp_path), "nested", "setup.conf")
    w.write_setup_conf(target, values, "2026-09-01T00:00:00+00:00")

    assert (os.stat(target).st_mode & 0o777) == 0o600
    assert (os.stat(os.path.dirname(target)).st_mode & 0o777) == 0o700

    parsed = w.parse_secrets_file(target)
    assert set(parsed) == set(SECRETS_KEYS)
    assert parsed["MANGOSDBPASS"] == "db-pass"
    assert parsed["INSTALLROOT"] == "/opt/mangos"

    litter = [x for x in os.listdir(os.path.dirname(target)) if x.startswith(".setup.conf.")]
    assert not litter


def test_write_setup_conf_replaces_existing(tmp_path):
    target = os.path.join(str(tmp_path), "setup.conf")
    first = make_values()
    first.db_password = "first"
    w.write_setup_conf(target, first, "2026-09-01T00:00:00+00:00")
    second = make_values()
    second.db_password = "second"
    w.write_setup_conf(target, second, "2026-09-01T00:00:01+00:00")
    assert w.parse_secrets_file(target)["MANGOSDBPASS"] == "second"


def test_redact_secrets():
    values = make_values()
    text = f"db={values.db_password} admin={values.sql_admin_pass}"
    masked = w.redact_secrets(text, values)
    assert values.db_password not in masked
    assert values.sql_admin_pass not in masked
    assert masked == "db=****** admin=******"


def test_build_launch_command():
    cmd = w.build_launch_command("/lib/installer.sh", "/sec", "/setup.sh")
    assert cmd[0] == "bash"
    assert cmd[1] == "-c"
    assert "installer_unit_start" in cmd[2]
    assert "installer_clear_install" not in cmd[2]
    assert "/lib/installer.sh" in cmd
    assert "/sec" in cmd
    assert "/setup.sh" in cmd


def test_build_launch_command_fresh_clears_before_start():
    cmd = w.build_launch_command(
        "/lib/installer.sh", "/sec", "/setup.sh", fresh=True, install_root="/opt/mangos"
    )
    script = cmd[2]
    assert "installer_clear_install" in script
    assert "installer_unit_start" in script
    # The clear must happen before the start.
    assert script.index("installer_clear_install") < script.index("installer_unit_start")
    assert "/opt/mangos" in cmd
    assert "/sec" in cmd
    assert "/setup.sh" in cmd


def test_launch_install_stub_runner():
    captured = {}

    class Completed:
        returncode = 0
        stdout = "Install started as vmangos-install.service\n"
        stderr = ""

    def fake_runner(command, **kwargs):
        captured["command"] = command
        captured["kwargs"] = kwargs
        return Completed()

    rc, out, err = w.launch_install("/lib/installer.sh", "/sec", "/setup.sh", runner=fake_runner)
    assert rc == 0
    assert "vmangos-install" in out
    assert err == ""
    assert "installer_unit_start" in captured["command"][2]
    assert captured["kwargs"].get("check") is False


def test_launch_install_failure_propagates():
    class Completed:
        returncode = 1
        stdout = ""
        stderr = "systemd-run failed to start vmangos-install.service\n"

    def fake_runner(command, **kwargs):
        return Completed()

    rc, out, err = w.launch_install("/lib/installer.sh", "/sec", "/setup.sh", runner=fake_runner)
    assert rc == 1
    assert "systemd-run failed" in err


def test_validate_values_accepts_valid_form(tmp_path):
    client = os.path.join(str(tmp_path), "client")
    os.makedirs(client, exist_ok=True)
    values = make_values(client_data=client)
    assert w.validate_values(values, False, "") == []


def test_validate_values_requires_client_data_when_fresh():
    values = make_values(client_data="")
    errors = w.validate_values(values, False, "")
    assert any("Client data path is required" in e for e in errors)


def test_validate_values_exempts_client_data_on_late_resume():
    values = make_values(client_data="")
    assert w.validate_values(values, True, "DATA_DONE") == []
    assert w.validate_values(values, True, "DB_IMPORT_DONE") == []
    assert w.validate_values(values, True, "SERVICES_DONE") == []


def test_validate_values_rejects_bad_identifiers(tmp_path):
    client = os.path.join(str(tmp_path), "client")
    os.makedirs(client, exist_ok=True)
    values = make_values(client_data=client)
    values.auth_db = "bad-db"
    values.db_user = "9lives"
    errors = w.validate_values(values, False, "")
    assert any("Auth DB" in e for e in errors)
    assert any("DB user" in e for e in errors)


def test_validate_values_requires_password(tmp_path):
    client = os.path.join(str(tmp_path), "client")
    os.makedirs(client, exist_ok=True)
    values = make_values(client_data=client)
    values.db_password = ""
    errors = w.validate_values(values, False, "")
    assert any("DB password" in e for e in errors)


# ---------------------------------------------------------------------------
# Wizard app flow (pilot, fake runner, no systemd)
# ---------------------------------------------------------------------------


async def wait_for(predicate, timeout=10.0, message="condition"):
    for _ in range(int(timeout / 0.05)):
        if predicate():
            return
        await asyncio.sleep(0.05)
    raise AssertionError(f"timed out waiting for {message}")


def build_wizard(
    tmp_path,
    gate="clean",
    checkpoint="",
    secrets=None,
    runner=None,
    attach=False,
    install_root="",
):
    if secrets is None:
        os.makedirs(os.path.join(tmp_path, "clientdata"), exist_ok=True)
        secrets = w.parse_secrets_file(write_fixture_secrets(tmp_path))
    secrets_file = os.path.join(str(tmp_path), "out.conf")
    installer_lib = os.path.join(str(tmp_path), "installer.sh")
    setup_script = os.path.join(str(tmp_path), "vmangos_setup.sh")
    with open(setup_script, "w", encoding="utf-8") as handle:
        handle.write("#!/usr/bin/env bash\nexit 0\n")
    app = w.create_wizard_app(
        gate=gate,
        checkpoint=checkpoint,
        secrets=secrets if isinstance(secrets, dict) else w.parse_secrets_file(secrets),
        secrets_file=secrets_file,
        setup_script=setup_script,
        installer_lib=installer_lib,
        runner=runner,
        attach=attach,
        install_root=install_root,
    )
    return app, secrets_file


def make_fake_runner(rc=0, stdout="", stderr=""):
    calls = []

    class Completed:
        pass

    def fake_runner(command, **kwargs):
        calls.append(command)
        completed = Completed()
        completed.returncode = rc
        completed.stdout = stdout
        completed.stderr = stderr
        return completed

    return fake_runner, calls


def screen_name(app):
    return app.screen.__class__.__name__


def screen_text(app):
    """The text of every Static on the current screen, joined."""
    parts = []
    for widget in app.screen.query(Static):
        renderable = widget.renderable
        parts.append(renderable if isinstance(renderable, str) else str(renderable))
    return "\n".join(parts)


def screen_shows(app, name, needle):
    """True when the screen has switched AND its text contains needle.

    After push_screen the stack updates immediately but the new screen's
    widgets compose on a later event-loop cycle — under load an immediate
    screen_text can legitimately read ''. Gating wait_for on this predicate
    waits out that compose race instead of asserting against a blank screen.
    """
    return screen_name(app) == name and needle in screen_text(app)


async def focus_widget(pilot, app, widget_id, max_tabs=60):
    """Tab until the widget with widget_id has focus (deterministic)."""
    for _ in range(max_tabs):
        focused = app.screen.focused
        if focused is not None and getattr(focused, "id", None) == widget_id:
            return
        await pilot.press("tab")
        await pilot.pause()
    raise AssertionError(f"could not focus widget {widget_id!r}")


def test_clean_gate_proceeds_to_form_and_launches(tmp_path):
    fake_runner, calls = make_fake_runner(
        rc=0,
        stdout="Install started as vmangos-install.service\nFollow progress with: journalctl -u vmangos-install -f\n",
    )
    app, secrets_file = build_wizard(tmp_path, gate="clean", runner=fake_runner)

    async def scenario():
        async with app.run_test() as pilot:
            await pilot.pause()
            assert screen_name(app) == "GateScreen"
            await pilot.press("enter")  # Continue to install form
            await pilot.pause()
            assert screen_name(app) == "FormScreen"

            # All fields are pre-filled from the fixture secrets; go straight
            # to Review.
            await focus_widget(pilot, app, "form-review")
            await pilot.press("enter")
            await pilot.pause()
            assert screen_name(app) == "ReviewScreen"

            await focus_widget(pilot, app, "review-start")
            await pilot.press("enter")
            await pilot.pause()
            assert screen_name(app) == "LaunchScreen"

            detail = app.query_one("#launch-detail")
            await wait_for(
                lambda: "Install started in systemd unit vmangos-install" in str(detail.renderable),
                message="launch success text",
            )
            assert app.code == 0

    asyncio.run(scenario())

    assert len(calls) == 1
    assert secrets_file in calls[0]
    assert "installer_unit_start" in calls[0][2]

    assert os.path.exists(secrets_file)
    assert (os.stat(secrets_file).st_mode & 0o777) == 0o600
    parsed = w.parse_secrets_file(secrets_file)
    assert set(parsed) == set(SECRETS_KEYS)


def test_resume_gate_defaults_to_resume_path(tmp_path):
    fake_runner, calls = make_fake_runner(rc=0, stdout="ok\n")
    app, _ = build_wizard(tmp_path, gate="resume", checkpoint="SOURCE_DONE", runner=fake_runner)

    async def scenario():
        async with app.run_test() as pilot:
            await pilot.pause()
            assert screen_name(app) == "GateScreen"
            assert "SOURCE_DONE" in screen_text(app)
            await pilot.press("enter")  # Resume (first button, default)
            await pilot.pause()
            assert screen_name(app) == "FormScreen"
            assert "Resuming from checkpoint SOURCE_DONE" in screen_text(app)

    asyncio.run(scenario())
    assert calls == []


def test_resume_past_data_done_exempts_client_data(tmp_path):
    fake_runner, calls = make_fake_runner(rc=0, stdout="ok\n")
    app, _ = build_wizard(tmp_path, gate="resume", checkpoint="DATA_DONE", runner=fake_runner)

    async def scenario():
        async with app.run_test() as pilot:
            await pilot.pause()
            await pilot.press("enter")  # Resume
            await pilot.pause()
            assert screen_name(app) == "FormScreen"

            # Clear the client data field: past DATA_DONE it is no longer required.
            app.query_one("#field-client_data").value = ""
            await focus_widget(pilot, app, "form-review")
            await pilot.press("enter")
            await pilot.pause()
            assert screen_name(app) == "ReviewScreen"

    asyncio.run(scenario())


def test_form_rejects_missing_client_data(tmp_path):
    fake_runner, calls = make_fake_runner(rc=0, stdout="ok\n")
    secrets = {"CLIENTDATA": "/does/not/exist"}
    app, _ = build_wizard(tmp_path, gate="clean", secrets=secrets, runner=fake_runner)

    async def scenario():
        async with app.run_test() as pilot:
            await pilot.pause()
            await pilot.press("enter")
            await pilot.pause()
            assert screen_name(app) == "FormScreen"
            await focus_widget(pilot, app, "form-review")
            await pilot.press("enter")
            await pilot.pause()
            # Still on the form: the bad client data path failed validation.
            assert screen_name(app) == "FormScreen"
            assert "does not exist" in str(app.query_one("#form-errors").renderable)

    asyncio.run(scenario())
    assert calls == []


def test_abort_gate_refuses_and_never_launches(tmp_path):
    fake_runner, calls = make_fake_runner(rc=0, stdout="ok\n")
    app, secrets_file = build_wizard(tmp_path, gate="abort", runner=fake_runner)

    async def scenario():
        async with app.run_test() as pilot:
            await pilot.pause()
            assert screen_name(app) == "GateScreen"
            assert "REINSTALL_POLICY=abort refuses" in screen_text(app)
            button_ids = [b.id for b in app.screen.query(Button)]
            assert "gate-replace" not in button_ids
            assert "gate-start-over" not in button_ids
            assert "gate-close" in button_ids

    asyncio.run(scenario())
    assert calls == []
    assert not os.path.exists(secrets_file)


def test_start_over_requires_typed_confirmation(tmp_path):
    fake_runner, calls = make_fake_runner(rc=0, stdout="ok\n")
    root = os.path.join(str(tmp_path), "installroot")
    app, _ = build_wizard(tmp_path, gate="resume", checkpoint="SOURCE_DONE", runner=fake_runner)

    async def scenario():
        async with app.run_test() as pilot:
            await pilot.pause()
            await focus_widget(pilot, app, "gate-start-over")
            await pilot.press("enter")
            await pilot.pause()
            assert screen_name(app) == "ConfirmScreen"

            # Wrong confirmation: back to the gate, nothing launched.
            await pilot.press(*"nope")
            await focus_widget(pilot, app, "confirm-yes")
            await pilot.press("enter")
            await pilot.pause()
            assert screen_name(app) == "GateScreen"
            assert calls == []

            # Correct confirmation: fresh form.
            await focus_widget(pilot, app, "gate-start-over")
            await pilot.press("enter")
            await pilot.pause()
            assert screen_name(app) == "ConfirmScreen"
            await pilot.press(*root)
            await focus_widget(pilot, app, "confirm-yes")
            await pilot.press("enter")
            await pilot.pause()
            assert screen_name(app) == "FormScreen"
            assert "Fresh install" in screen_text(app)

    asyncio.run(scenario())
    assert calls == []


def test_start_over_launch_clears_root_before_start(tmp_path):
    """Destructive path: after typed confirm, launch clears the root first."""
    fake_runner, calls = make_fake_runner(rc=0, stdout="ok\n")
    root = os.path.join(str(tmp_path), "installroot")
    app, _ = build_wizard(tmp_path, gate="resume", checkpoint="SOURCE_DONE", runner=fake_runner)

    async def scenario():
        async with app.run_test() as pilot:
            await pilot.pause()
            await focus_widget(pilot, app, "gate-start-over")
            await pilot.press("enter")
            await pilot.pause()
            assert screen_name(app) == "ConfirmScreen"
            await pilot.press(*root)
            await focus_widget(pilot, app, "confirm-yes")
            await pilot.press("enter")
            await pilot.pause()
            assert screen_name(app) == "FormScreen"

            await focus_widget(pilot, app, "form-review")
            await pilot.press("enter")
            await pilot.pause()
            assert screen_name(app) == "ReviewScreen"
            assert "REPLACING" in screen_text(app)

            await focus_widget(pilot, app, "review-start")
            await pilot.press("enter")
            await pilot.pause()
            assert screen_name(app) == "LaunchScreen"
            detail = app.query_one("#launch-detail")
            await wait_for(
                lambda: "Install started in systemd unit vmangos-install" in str(detail.renderable),
                message="launch success text",
            )
            assert app.code == 0

    asyncio.run(scenario())

    assert len(calls) == 1
    command = calls[0]
    script = command[2]
    # The destructive launch must clear the root, then start the unit.
    assert "installer_clear_install" in script
    assert "installer_unit_start" in script
    assert script.index("installer_clear_install") < script.index("installer_unit_start")
    assert root in command


def test_runner_failure_is_shown_and_exits_nonzero(tmp_path):
    stderr = "systemd-run failed to start vmangos-install.service\nDiagnosis: journalctl -u vmangos-install -n 50\n"
    fake_runner, _ = make_fake_runner(rc=1, stderr=stderr)
    app, _ = build_wizard(tmp_path, gate="clean", runner=fake_runner)

    async def scenario():
        async with app.run_test() as pilot:
            await pilot.pause()
            await pilot.press("enter")
            await pilot.pause()
            await focus_widget(pilot, app, "form-review")
            await pilot.press("enter")
            await pilot.pause()
            await focus_widget(pilot, app, "review-start")
            await pilot.press("enter")
            await pilot.pause()
            assert screen_name(app) == "LaunchScreen"
            detail = app.query_one("#launch-detail")
            await wait_for(
                lambda: "systemd-run failed to start" in str(detail.renderable),
                message="runner failure text",
            )
            assert "Diagnosis: journalctl -u vmangos-install -n 50" in str(detail.renderable)
            assert app.code == 1

    asyncio.run(scenario())


def test_runner_output_with_passwords_is_redacted(tmp_path):
    fake_runner, _ = make_fake_runner(rc=1, stderr="leak M4ng0s!Pass and Adm1n!Pass\n")
    app, _ = build_wizard(tmp_path, gate="clean", runner=fake_runner)

    async def scenario():
        async with app.run_test() as pilot:
            await pilot.pause()
            await pilot.press("enter")
            await pilot.pause()
            await focus_widget(pilot, app, "form-review")
            await pilot.press("enter")
            await pilot.pause()
            await focus_widget(pilot, app, "review-start")
            await pilot.press("enter")
            await pilot.pause()
            detail = app.query_one("#launch-detail")
            await wait_for(lambda: "******" in str(detail.renderable), message="redacted output")
            text = str(detail.renderable)
            assert "M4ng0s!Pass" not in text
            assert "Adm1n!Pass" not in text

    asyncio.run(scenario())


def test_runner_empty_failure_still_names_the_fix(tmp_path):
    """Even with no runner output, the failure screen must name the fix."""
    fake_runner, _ = make_fake_runner(rc=1, stdout="", stderr="")
    app, _ = build_wizard(tmp_path, gate="clean", runner=fake_runner)

    async def scenario():
        async with app.run_test() as pilot:
            await pilot.pause()
            await pilot.press("enter")
            await pilot.pause()
            await focus_widget(pilot, app, "form-review")
            await pilot.press("enter")
            await pilot.pause()
            await focus_widget(pilot, app, "review-start")
            await pilot.press("enter")
            await pilot.pause()
            assert screen_name(app) == "LaunchScreen"
            detail = app.query_one("#launch-detail")
            await wait_for(
                lambda: "Install unit failed to start" in str(detail.renderable),
                message="fallback text",
            )
            text = str(detail.renderable)
            # The fix must be named even when the runner produced no output.
            assert "journalctl -u vmangos-install" in text
            assert "Retry: sudo vmangos-manager install" in text
            assert app.code == 1

    asyncio.run(scenario())


# ---------------------------------------------------------------------------
# Viewer (#103): marker parsing, tracking, retry — pure logic
# ---------------------------------------------------------------------------


def test_parse_marker_well_formed():
    m = w.parse_marker("@@VMANGOS v1 phase=build event=progress percent=42 step=\"Compiling the core\"")
    assert m == {
        "phase": "build",
        "event": "progress",
        "percent": "42",
        "step": "Compiling the core",
    }


def test_parse_marker_quoted_and_escaped():
    # A marker whose value is quoted and contains escaped quotes.
    m = w.parse_marker("@@VMANGOS v1 phase=build event=error msg=\"it failed \\\"badly\\\"\" hint=\"fix it\"")
    assert m["phase"] == "build"
    assert m["event"] == "error"
    assert m["msg"] == 'it failed "badly"'
    assert m["hint"] == "fix it"


def test_parse_marker_requires_phase_and_event():
    # Missing event -> not a usable marker.
    assert w.parse_marker("@@VMANGOS v1 phase=build") is None
    # Wrong protocol version -> ignored.
    assert w.parse_marker("@@VMANGOS v2 phase=build event=start") is None
    # A non-marker log line -> ignored.
    assert w.parse_marker("some ordinary journal line") is None
    # An unterminated quoted value -> malformed, ignored (never crash).
    assert w.parse_marker("@@VMANGOS v1 phase=build event=progress step=\"unterminated") is None
    # A token without '=' -> malformed, ignored.
    assert w.parse_marker("@@VMANGOS v1 phase=build event=start garbage") is None
    # A value with no key -> malformed, ignored.
    assert w.parse_marker("@@VMANGOS v1 =value") is None


def test_marker_tracker_states_and_progress():
    t = w.MarkerTracker()
    for line in (
        "@@VMANGOS v1 phase=prerequisites event=start",
        "@@VMANGOS v1 phase=prerequisites event=done",
        "@@VMANGOS v1 phase=build event=progress percent=30 step=\"Compiling\"",
        "@@VMANGOS v1 phase=build event=progress percent=90 step=\"Linking\"",
        "@@VMANGOS v1 phase=build event=done",
        "@@VMANGOS v1 phase=services event=start",
    ):
        m = w.parse_marker(line)
        assert m is not None
        t.apply(m)
    assert t.phase_state["prerequisites"] == "done"
    assert t.phase_state["build"] == "done"
    assert t.phase_state["services"] == "running"
    assert t.current_phase == "services"
    assert t.progress["build"] == ("90", "Linking")
    assert not t.completed and not t.failed


def test_marker_tracker_failure_and_completion():
    t = w.MarkerTracker()
    t.apply(w.parse_marker("@@VMANGOS v1 phase=build event=error msg=\"boom\" hint=\"check disk\""))
    assert t.failed
    assert t.failure == ("build", "boom", "check disk")
    assert t.phase_state["build"] == "failed"

    t2 = w.MarkerTracker()
    t2.apply(w.parse_marker("@@VMANGOS v1 phase=install event=done server_ip=1.2.3.4"))
    assert t2.completed
    assert t2.install_done["server_ip"] == "1.2.3.4"


def test_render_progress_honest_bar():
    t = w.MarkerTracker()
    t.apply(w.parse_marker("@@VMANGOS v1 phase=build event=progress percent=50 step=\"Compiling\""))
    rendered = w.render_progress(t)
    assert "50%" in rendered and "Compiling" in rendered
    assert "\u2588" in rendered  # a bar is drawn when the phase emits progress

    # A phase that emits no progress markers shows no bar.
    t2 = w.MarkerTracker()
    t2.apply(w.parse_marker("@@VMANGOS v1 phase=prerequisites event=start"))
    rendered2 = w.render_progress(t2)
    assert "\u2588" not in rendered2 and "Working on Prerequisites" in rendered2


def test_build_retry_command_stop_then_start():
    cmd = w.build_retry_command("/lib/installer.sh", "/sec", "/setup.sh")
    script = cmd[2]
    assert "installer_unit_stop" in script
    assert "installer_unit_start" in script
    assert script.index("installer_unit_stop") < script.index("installer_unit_start")
    assert "/sec" in cmd and "/setup.sh" in cmd


def test_retry_install_uses_runner_seam():
    calls = []

    def fake_runner(command, **kwargs):
        calls.append(command)

        class Completed:
            returncode = 0
            stdout = ""
            stderr = ""

        return Completed()

    rc, out, err = w.retry_install("/lib/installer.sh", "/sec", "/setup.sh", runner=fake_runner)
    assert rc == 0 and out == "" and err == ""
    assert len(calls) == 1
    assert "installer_unit_stop" in calls[0][2]


def test_checkpoint_progress_text():
    assert w.checkpoint_progress_text("") == "Install starting..."
    assert w.checkpoint_progress_text("START") == "Install starting..."
    assert "Build complete" in w.checkpoint_progress_text("BUILD_DONE")
    assert "Configuration in progress" in w.checkpoint_progress_text("BUILD_DONE")
    assert "finishing up" in w.checkpoint_progress_text("SERVICES_DONE")
    assert "CHECKPOINT_XYZ" in w.checkpoint_progress_text("CHECKPOINT_XYZ")


def test_read_checkpoint_missing_is_empty(tmp_path):
    root = str(tmp_path / "installroot")
    assert w.read_checkpoint(root) == ""
    os.makedirs(os.path.join(root, ".install-checkpoints"), exist_ok=True)
    with open(os.path.join(root, ".install-checkpoints", "checkpoint"), "w") as handle:
        handle.write("BUILD_DONE\n")
    assert w.read_checkpoint(root) == "BUILD_DONE"


# ---------------------------------------------------------------------------
# Viewer (#103): fake-worker scenarios (stub journalctl on PATH, no systemd)
# ---------------------------------------------------------------------------


def make_fake_journalctl(tmp_path, lines, delay=0.05, args_log=None):
    """An executable 'journalctl' that emits the given lines, then exits.

    Returns the bin dir to prepend to PATH so the viewer's Popen(["journalctl", ...])
    resolves to this stub instead of a real journalctl. If ``args_log`` is given,
    every invocation's argv is appended to it (one per line) so a test can assert
    on the flags used (e.g. that a retry re-attach used ``-n 0``).
    """
    bin_dir = os.path.join(str(tmp_path), "fakebin")
    os.makedirs(bin_dir, exist_ok=True)
    script_path = os.path.join(bin_dir, "journalctl")
    data_path = os.path.join(str(tmp_path), "journalctl_lines.txt")
    if args_log is None:
        args_log = os.path.join(str(tmp_path), "journalctl_args.log")
    with open(data_path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    with open(script_path, "w", encoding="utf-8") as handle:
        handle.write("#!/usr/bin/env bash\n")
        handle.write(f'DATA="{data_path}"\n')
        handle.write(f'DELAY="{delay}"\n')
        handle.write(f'ARGS_LOG="{args_log}"\n')
        handle.write('printf "%s\\n" "$*" >> "$ARGS_LOG"\n')
        handle.write("while IFS= read -r line; do\n")
        handle.write('    printf "%s\\n" "$line"\n')
        handle.write('    sleep "$DELAY"\n')
        handle.write('done < "$DATA"\n')
    os.chmod(script_path, 0o755)
    return bin_dir


def make_fake_systemctl(tmp_path, state):
    """An executable 'systemctl' that reports a constant ActiveState.

    Returns the bin dir to prepend to PATH so the viewer's unit-state polls
    resolve to this stub. For a unit that changes state over time (active,
    then dies) use :func:`make_fake_systemctl_transition` — a call-counted
    sequence loses its first state whenever a poll times out under load (the
    stub advances even though the caller never reads the result), which used
    to make the unit-state tests flake.
    """
    return _write_systemctl_stub(tmp_path, f'print("ActiveState={state}")\n')


def make_fake_systemctl_transition(tmp_path, first_state, then_state, first_seconds):
    """An executable 'systemctl' whose ActiveState depends on wall-clock time.

    Reports ``first_state`` until ``first_seconds`` have elapsed since the
    first poll, then ``then_state`` forever — time-based, so a poll that times
    out under load consumes nothing: the transition lands when a caller
    actually observes it, not when the Nth call happens.
    """
    stamp = os.path.join(str(tmp_path), "systemctl_stamp.txt")
    body = (
        "import time\n"
        f"STAMP = {stamp!r}\n"
        "try:\n"
        "    t0 = float(open(STAMP).read())\n"
        "except OSError:\n"
        "    t0 = time.time()\n"
        "    open(STAMP, 'w').write(repr(t0))\n"
        f"state = {first_state!r} if time.time() - t0 < {first_seconds!r} else {then_state!r}\n"
        'print("ActiveState=" + state)\n'
    )
    return _write_systemctl_stub(tmp_path, body)


def _write_systemctl_stub(tmp_path, body):
    bin_dir = os.path.join(str(tmp_path), "fakebin")
    os.makedirs(bin_dir, exist_ok=True)
    script_path = os.path.join(bin_dir, "systemctl")
    with open(script_path, "w", encoding="utf-8") as handle:
        handle.write("#!/usr/bin/env python3\n")
        handle.write(body)
    os.chmod(script_path, 0o755)
    return bin_dir


def journalctl_args_log(tmp_path):
    """The journalctl argv log the fake wrote (last line = last invocation)."""
    path = os.path.join(str(tmp_path), "journalctl_args.log")
    try:
        with open(path, encoding="utf-8") as handle:
            lines = [line for line in handle.read().splitlines() if line.strip()]
    except OSError:
        return []
    return lines


def with_path_prepended(bin_dir):
    """Context manager that prepends bin_dir to PATH for the viewer's child."""
    import contextlib

    @contextlib.contextmanager
    def _manager():
        old = os.environ.get("PATH", "")
        os.environ["PATH"] = bin_dir + os.pathsep + old
        try:
            yield
        finally:
            os.environ["PATH"] = old

    return _manager()


def test_viewer_checklist_renders_from_markers(tmp_path):
    # Phase markers (no terminal marker) -> the checklist renders states and
    # the running phase shows in progress.
    lines = [
        "@@VMANGOS v1 phase=prerequisites event=done",
        "@@VMANGOS v1 phase=build event=progress percent=60 step=\"Compiling\"",
        "@@VMANGOS v1 phase=build event=done",
        "@@VMANGOS v1 phase=config event=start",
    ]
    bin_dir = make_fake_journalctl(tmp_path, lines, delay=0.1)
    app, _ = build_wizard(tmp_path, attach=True)

    with with_path_prepended(bin_dir):

        async def scenario():
            async with app.run_test() as pilot:
                await pilot.pause()
                assert screen_name(app) == "ViewerScreen"
                await wait_for(
                    lambda: "Prerequisites" in screen_text(app)
                    and "Build" in screen_text(app)
                    and "Configuration" in screen_text(app),
                    message="checklist rendered",
                )
                text = screen_text(app)
                # The running phase is marked in progress.
                assert "Configuration" in text and "in progress" in text
                # The completed build is not pending.
                build_line = next(line for line in text.splitlines() if "Build" in line)
                assert "pending" not in build_line

        asyncio.run(scenario())


def test_viewer_completion_shows_address_and_realmlist(tmp_path):
    # The install-done marker transitions to the completion screen, which
    # shows the server address, the realmlist line, and the next steps.
    lines = [
        "@@VMANGOS v1 phase=prerequisites event=done",
        "@@VMANGOS v1 phase=build event=done",
        "@@VMANGOS v1 phase=install event=done server_ip=10.0.0.5 auth_port=3724 world_port=8085",
    ]
    bin_dir = make_fake_journalctl(tmp_path, lines, delay=0.1)
    app, _ = build_wizard(tmp_path, attach=True)

    with with_path_prepended(bin_dir):

        async def scenario():
            async with app.run_test() as pilot:
                await pilot.pause()
                assert screen_name(app) == "ViewerScreen"
                await wait_for(lambda: screen_name(app) == "CompletionScreen", message="completion screen")
                text = screen_text(app)
                assert "10.0.0.5" in text
                # The realmlist line has no port (the installer prints
                # 'set realmlist $SERVERIP'); a port would break the client.
                assert "set realmlist 10.0.0.5" in text
                assert "SET REALMLIST 10.0.0.5 3724" not in text
                assert "Next steps" in text
                assert "world port 8085" in text
                # The unprivileged follow-up is named (dashboard + grant).
                assert "vmangos-manager" in text
                assert "config grant --user" in text

        asyncio.run(scenario())


def test_viewer_failure_shows_phase_hint_tail_and_retry(tmp_path):
    lines = [
        "@@VMANGOS v1 phase=build event=progress percent=55 step=\"Compiling\"",
        "fatal: disk full",
        "@@VMANGOS v1 phase=build event=error msg=\"out of space\" hint=\"free up disk space on /opt\"",
    ]
    bin_dir = make_fake_journalctl(tmp_path, lines)
    fake_runner, calls = make_fake_runner(rc=0, stdout="restarted\n")
    app, _ = build_wizard(tmp_path, attach=True, runner=fake_runner)

    with with_path_prepended(bin_dir):

        async def scenario():
            async with app.run_test() as pilot:
                await pilot.pause()
                await wait_for(lambda: screen_name(app) == "FailureScreen", message="failure screen")
                text = screen_text(app)
                # What failed / why / the fix, plus the raw tail.
                assert "Build" in text
                assert "out of space" in text
                assert "free up disk space on /opt" in text
                assert "disk full" in text  # last raw log lines are shown

                # Retry issues stop -> start (resume from checkpoint), then
                # re-attaches to a fresh viewer with no history.
                await focus_widget(pilot, app, "failure-retry")
                await pilot.press("enter")
                await wait_for(lambda: screen_name(app) == "ViewerScreen", message="re-attach after retry")

        asyncio.run(scenario())

    retry_calls = [c for c in calls if "installer_unit_stop" in " ".join(c)]
    assert len(retry_calls) == 1
    script = retry_calls[0][2]
    assert script.index("installer_unit_stop") < script.index("installer_unit_start")

    # The re-attach must have used -n 0 (no history) so the prior failure's
    # markers are not replayed (which would immediately fail again).
    args = journalctl_args_log(tmp_path)
    assert args, "the re-attached viewer should have started a journal tail"
    tokens = args[-1].split()
    assert "-n" in tokens and tokens[tokens.index("-n") + 1] == "0", (
        f"retry re-attach must use -n 0, got: {args[-1]!r}"
    )


def test_viewer_detach_never_stops_the_unit(tmp_path):
    # The install is still running (a progress marker, no terminal marker).
    lines = ["@@VMANGOS v1 phase=build event=progress percent=40 step=\"Compiling\""]
    bin_dir = make_fake_journalctl(tmp_path, lines, delay=0.2)
    fake_runner, calls = make_fake_runner(rc=0)
    app, _ = build_wizard(tmp_path, attach=True, runner=fake_runner)

    with with_path_prepended(bin_dir):

        async def scenario():
            async with app.run_test() as pilot:
                await pilot.pause()
                assert screen_name(app) == "ViewerScreen"
                await wait_for(lambda: "40%" in screen_text(app), message="progress shown")
                # Detach: kills the journal child only, never the unit.
                await focus_widget(pilot, app, "viewer-detach")
                await pilot.press("enter")

        asyncio.run(scenario())

    # Detaching must not have issued any unit stop (or any) runner command.
    assert calls == []


def test_viewer_marker_starvation_falls_back_to_checkpoint(tmp_path):
    # A script that emits no markers: the viewer polls the checkpoint file and
    # shows the raw log pane, and never crashes.
    install_root = str(tmp_path / "installroot")
    os.makedirs(os.path.join(install_root, ".install-checkpoints"), exist_ok=True)
    with open(os.path.join(install_root, ".install-checkpoints", "checkpoint"), "w") as handle:
        handle.write("SOURCE_DONE\n")
    lines = [
        "plain log: fetching source",
        "plain log: extracting",
        "@@VMANGOS v1 malformed marker without event",
    ]
    bin_dir = make_fake_journalctl(tmp_path, lines, delay=0.1)
    app, _ = build_wizard(tmp_path, attach=True, install_root=install_root)

    with with_path_prepended(bin_dir):

        async def scenario():
            async with app.run_test() as pilot:
                await pilot.pause()
                assert screen_name(app) == "ViewerScreen"
                # The checkpoint fallback is shown (SOURCE_DONE -> source done,
                # build in progress), and the raw log pane is present.
                await wait_for(
                    lambda: "Source" in screen_text(app) and "Build in progress" in screen_text(app),
                    message="checkpoint fallback",
                )
                await wait_for(
                    lambda: "plain log: extracting" in screen_text(app),
                    message="raw log pane",
                )
                # The malformed marker line is shown in the log but never crashed.
                assert screen_name(app) == "ViewerScreen"

        asyncio.run(scenario())


def test_launch_success_offers_follow_to_viewer(tmp_path):
    # Straight after the launch flow, the success screen offers to attach.
    fake_runner, calls = make_fake_runner(rc=0, stdout="started\n")
    bin_dir = make_fake_journalctl(
        tmp_path,
        [
            "@@VMANGOS v1 phase=build event=progress percent=10 step=\"Compiling\"",
            "@@VMANGOS v1 phase=install event=done server_ip=10.1.1.1",
        ],
    )
    app, _ = build_wizard(tmp_path, gate="clean", runner=fake_runner)

    with with_path_prepended(bin_dir):

        async def scenario():
            async with app.run_test() as pilot:
                await pilot.pause()
                await pilot.press("enter")
                await pilot.pause()
                await focus_widget(pilot, app, "form-review")
                await pilot.press("enter")
                await pilot.pause()
                await focus_widget(pilot, app, "review-start")
                await pilot.press("enter")
                await pilot.pause()
                assert screen_name(app) == "LaunchScreen"
                # The Follow button appears on success.
                await wait_for(
                    lambda: any(b.id == "launch-follow" for b in app.screen.query(Button)),
                    message="follow button",
                )
                await focus_widget(pilot, app, "launch-follow")
                await pilot.press("enter")
                await pilot.pause()
                assert screen_name(app) == "ViewerScreen"
                await wait_for(lambda: screen_name(app) == "CompletionScreen", message="completion after follow")
                assert "10.1.1.1" in screen_text(app)

        asyncio.run(scenario())

    # The launch itself started the unit (one runner call, no stop).
    assert len(calls) == 1
    assert "installer_unit_start" in calls[0][2]
    assert "installer_unit_stop" not in calls[0][2]


def test_viewer_detects_unit_failure_without_markers(tmp_path, monkeypatch):
    # A unit that dies without emitting event=error (kill -9, or a crash): the
    # viewer polls the unit state and detects the failure, instead of spinning
    # "in progress" forever. The unit is active first (seen_active) then fails.
    # The stub's active window is wall-clock based and the poll interval is
    # shrunk through the module seam: under load, a poll that times out must
    # not consume the "active" observation (the old counter-based stub did,
    # which is what made this test flake — #113).
    monkeypatch.setattr(w, "UNIT_STATE_POLL_SECONDS", 0.1)
    lines = ["plain log: doing work"]  # no markers at all
    make_fake_journalctl(tmp_path, lines, delay=0.05)
    make_fake_systemctl_transition(tmp_path, "active", "failed", first_seconds=5.0)
    fake_runner, calls = make_fake_runner(rc=0)
    app, _ = build_wizard(tmp_path, attach=True, runner=fake_runner)

    with with_path_prepended(os.path.join(str(tmp_path), "fakebin")):

        async def scenario():
            async with app.run_test() as pilot:
                await pilot.pause()
                assert screen_name(app) == "ViewerScreen"
                # The unit dies without a marker; the state checker catches it.
                # The predicate gates on the screen text too: the blank-screen
                # window between push_screen and compose is what flaked (#113).
                await wait_for(
                    lambda: screen_shows(app, "FailureScreen", "stopped without finishing"),
                    message="marker-less failure detected",
                    timeout=20.0,
                )
                text = screen_text(app)
                assert "stopped without finishing" in text

        asyncio.run(scenario())

    # The failure was detected from the unit state, not a marker; no retry yet.
    assert calls == []


def test_viewer_detects_unit_ended_without_completion(tmp_path, monkeypatch):
    # A unit that ends (zero exit) without emitting the completion marker (an
    # older script): the viewer shows "ended" (not success, not failure) and
    # points the user at the journal to verify. Same seam + wall-clock stub as
    # the failure test above (#113).
    monkeypatch.setattr(w, "UNIT_STATE_POLL_SECONDS", 0.1)
    lines = ["plain log: doing work", "plain log: done"]  # no completion marker
    make_fake_journalctl(tmp_path, lines, delay=0.05)
    make_fake_systemctl_transition(tmp_path, "active", "inactive", first_seconds=5.0)
    fake_runner, calls = make_fake_runner(rc=0)
    app, _ = build_wizard(tmp_path, attach=True, runner=fake_runner)

    with with_path_prepended(os.path.join(str(tmp_path), "fakebin")):

        async def scenario():
            async with app.run_test() as pilot:
                await pilot.pause()
                assert screen_name(app) == "ViewerScreen"
                # The unit ends without a completion marker; the state
                # checker catches it. Same text-gated predicate: the
                # blank-screen window between push_screen and compose is what
                # flaked here (#113).
                await wait_for(
                    lambda: screen_shows(app, "EndedScreen", "Install Unit Ended"),
                    message="unit-ended detected",
                    timeout=20.0,
                )
                text = screen_text(app)
                assert "Install Unit Ended" in text
                assert "journalctl" in text  # the journal pointer is shown
                assert "vmangos-manager" in text  # the dashboard follow-up

        asyncio.run(scenario())

    # No retry was issued (the unit already ended; the user verifies manually).
    assert calls == []


def test_viewer_redacts_secrets_in_log_pane(tmp_path):
    # A journal line that echoes a secret (a password on a command line) must
    # be redacted in the live log pane.
    lines = ["mysql -pM4ng0s!Pass -e 'SELECT 1'"]
    make_fake_journalctl(tmp_path, lines, delay=0.1)
    app, _ = build_wizard(tmp_path, attach=True)

    with with_path_prepended(os.path.join(str(tmp_path), "fakebin")):

        async def scenario():
            async with app.run_test() as pilot:
                await pilot.pause()
                await wait_for(lambda: "mysql" in screen_text(app), message="log line")
                text = screen_text(app)
                assert "M4ng0s!Pass" not in text  # the secret is redacted
                assert "******" in text

        asyncio.run(scenario())


def test_failure_tail_redacts_secrets(tmp_path):
    # The failure tail (raw log lines) can echo a secret; it must be redacted.
    lines = [
        "mysql -pM4ng0s!Pass -e 'SELECT 1'",
        "fatal: db down",
        "@@VMANGOS v1 phase=database event=error msg=\"db down\" hint=\"check the db\"",
    ]
    make_fake_journalctl(tmp_path, lines, delay=0.1)
    app, _ = build_wizard(tmp_path, attach=True)

    with with_path_prepended(os.path.join(str(tmp_path), "fakebin")):

        async def scenario():
            async with app.run_test() as pilot:
                await pilot.pause()
                await wait_for(lambda: screen_name(app) == "FailureScreen", message="failure screen")
                text = screen_text(app)
                assert "M4ng0s!Pass" not in text  # the tail is redacted
                assert "******" in text

        asyncio.run(scenario())


def test_viewer_detach_with_q_key(tmp_path):
    # Ctrl+C / q detaches (kills the journal child only, never the unit).
    lines = ["@@VMANGOS v1 phase=build event=progress percent=40 step=\"Compiling\""]
    make_fake_journalctl(tmp_path, lines, delay=0.2)
    fake_runner, calls = make_fake_runner(rc=0)
    app, _ = build_wizard(tmp_path, attach=True, runner=fake_runner)

    with with_path_prepended(os.path.join(str(tmp_path), "fakebin")):

        async def scenario():
            async with app.run_test() as pilot:
                await pilot.pause()
                assert screen_name(app) == "ViewerScreen"
                await wait_for(lambda: "40%" in screen_text(app), message="progress shown")
                # Detach with the q key (not the button).
                await pilot.press("q")
                await pilot.pause()

        asyncio.run(scenario())

    # Detaching must not have issued any unit stop (or any) runner command.
    assert calls == []


def test_viewer_retry_failure_shows_error(tmp_path):
    # If the retry command fails (non-zero rc), the error is shown and the
    # viewer stays on the failure screen (no re-attach).
    lines = ["@@VMANGOS v1 phase=build event=error msg=\"boom\" hint=\"fix it\""]
    make_fake_journalctl(tmp_path, lines, delay=0.1)
    fake_runner, calls = make_fake_runner(rc=1, stderr="Failed to start vmangos-install.service\n")
    app, _ = build_wizard(tmp_path, attach=True, runner=fake_runner)

    with with_path_prepended(os.path.join(str(tmp_path), "fakebin")):

        async def scenario():
            async with app.run_test() as pilot:
                await pilot.pause()
                await wait_for(lambda: screen_name(app) == "FailureScreen", message="failure screen")
                await focus_widget(pilot, app, "failure-retry")
                await pilot.press("enter")
                # The retry failed: the error is shown, and we stay on the
                # failure screen (no re-attach).
                await wait_for(
                    lambda: "Failed to start" in screen_text(app),
                    message="retry error shown",
                )
                assert screen_name(app) == "FailureScreen"

        asyncio.run(scenario())

    # The retry command was issued (stop -> start), even though it failed.
    retry_calls = [c for c in calls if "installer_unit_stop" in " ".join(c)]
    assert len(retry_calls) == 1
    script = retry_calls[0][2]
    assert script.index("installer_unit_stop") < script.index("installer_unit_start")


def test_installer_unit_name_single_source_of_truth():
    # Declined review point 9 keeps the unit name defined in both layers
    # (bash runner + python viewer) to avoid a per-attach subprocess. This
    # guard makes drift loud: renaming the unit in one file without the
    # other would make the viewer silently watch the wrong journal.
    import re
    from pathlib import Path

    lib_dir = Path(w.__file__).resolve().parent
    bash = (lib_dir / "installer.sh").read_text()
    py = (lib_dir / "wizard.py").read_text()
    bash_name = re.search(r'INSTALLER_UNIT_NAME="([^"]+)"', bash)
    py_name = re.search(r'INSTALLER_UNIT_NAME = "([^"]+)"', py)
    assert bash_name and py_name, "INSTALLER_UNIT_NAME definitions not found"
    assert bash_name.group(1) == py_name.group(1)
