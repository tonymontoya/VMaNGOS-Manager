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


def build_wizard(tmp_path, gate="clean", checkpoint="", secrets=None, runner=None):
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
