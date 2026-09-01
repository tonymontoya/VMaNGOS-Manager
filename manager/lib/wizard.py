#!/usr/bin/env python3
"""One-time install wizard for VMANGOS Manager.

Flow: gate (existing install?) -> form -> review -> launch.

The wizard collects install answers, writes the shell-sourceable
secrets file in the exact auto_install.sh format (root:root 600),
and starts the install through the bash runner
(``installer_unit_start`` in manager/lib/installer.sh).

Pure logic (secrets parsing, defaults, gate table, secrets rendering,
launch command) lives at module level and is tested without a TTY.
"""

from __future__ import annotations

import argparse
import os
import re
import secrets as _secrets
import subprocess
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_SECRETS_FILE = "/root/.vmangos-secrets/setup.conf"
DEFAULT_INSTALL_ROOT = "/opt/mangos"
DEFAULT_CLIENT_DATA = ""
DEFAULT_DB_USER = "mangos"
DEFAULT_OS_USER = "mangos"
PROVISION_TARGETS = ("vmangos_manager", "vmangos_only")
REINSTALL_POLICIES = ("abort", "replace")

PASSWORD_CHARSET = "a-zA-Z0-9!@#$%^&*"
PASSWORD_LENGTH = 24

# Checkpoints at or past the client-data extraction phase: a resume past
# these does not need the client data path to exist.
CHECKPOINTS_CLIENT_DATA_DONE = ("DATA_DONE", "DB_IMPORT_DONE", "SERVICES_DONE")

# Gate actions, produced by the bash layer (vmangos_setup.sh's
# existing_install_action) and consumed here.
GATE_ACTIONS = ("clean", "resume", "replace", "abort")

# Gate outcomes, produced by gate_decision().
OUTCOME_FORM = "form"
OUTCOME_FORM_FRESH = "form-fresh"
OUTCOME_CONFIRM_START_OVER = "confirm-start-over"
OUTCOME_CONFIRM_REPLACE = "confirm-replace"
OUTCOME_REFUSE = "refuse"
OUTCOME_CANCEL = "cancel"

_IDENTIFIER_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9_]*$")


# ---------------------------------------------------------------------------
# Values
# ---------------------------------------------------------------------------


@dataclass
class InstallValues:
    """Every value the wizard writes to setup.conf, in one place."""

    install_root: str
    client_data: str
    auth_db: str
    world_db: str
    characters_db: str
    logs_db: str
    db_user: str
    db_password: str
    os_user: str
    provision_target: str
    # Values the form does not edit: kept from existing secrets or generated.
    sql_admin_user: str = "root"
    sql_admin_ip: str = "%"
    sql_admin_pass: str = ""
    skip_secure_mysql: str = "yes"
    reinstall_policy: str = "abort"


def parse_secrets_file(path: str | Path) -> dict[str, str]:
    """Parse the flat KEY="value" secrets file into a dict.

    Comments, blank lines, and anything unparseable are skipped — this is a
    reader for the known format, not a shell interpreter.
    """
    values: dict[str, str] = {}
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError:
        return values

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, raw_value = line.partition("=")
        key = key.strip()
        raw_value = raw_value.strip()
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            continue
        if len(raw_value) >= 2 and raw_value[0] == '"' and raw_value[-1] == '"':
            raw_value = raw_value[1:-1]
        values[key] = raw_value
    return values


def form_defaults(secrets: dict[str, str]) -> InstallValues:
    """Defaults: existing secrets values when present, else documented defaults.

    Passwords absent from the secrets file are generated (the documented
    auto_install.sh behavior for a fresh host).
    """
    return InstallValues(
        install_root=secrets.get("INSTALLROOT") or DEFAULT_INSTALL_ROOT,
        client_data=secrets.get("CLIENTDATA") or DEFAULT_CLIENT_DATA,
        auth_db=secrets.get("AUTHDB") or "auth",
        world_db=secrets.get("WORLDDB") or "world",
        characters_db=secrets.get("CHARACTERDB") or "characters",
        logs_db=secrets.get("LOGSDB") or "logs",
        db_user=secrets.get("MANGOSDBUSER") or DEFAULT_DB_USER,
        db_password=secrets.get("MANGOSDBPASS") or generate_password(),
        os_user=secrets.get("MANGOSOSUSER") or DEFAULT_OS_USER,
        provision_target=secrets.get("PROVISIONTARGET") or "vmangos_manager",
        sql_admin_user=secrets.get("SQLADMINUSER") or "root",
        sql_admin_ip=secrets.get("SQLADMINIP") or "%",
        sql_admin_pass=secrets.get("SQLADMINPASS") or generate_password(),
        skip_secure_mysql=secrets.get("SKIP_SECURE_MYSQL") or "yes",
        reinstall_policy=secrets.get("REINSTALL_POLICY") or "abort",
    )


def generate_password(length: int = PASSWORD_LENGTH, charset: str = PASSWORD_CHARSET) -> str:
    """Generate a password from the documented charset (crypto-safe)."""
    if length <= 0 or not charset:
        raise ValueError("password length and charset must be positive")
    return "".join(_secrets.choice(charset) for _ in range(length))


# ---------------------------------------------------------------------------
# Gate decision table
# ---------------------------------------------------------------------------


def gate_decision(gate: str, choice: str, confirmation: str, install_root: str) -> str:
    """Pure gate table: (gate, choice, confirmation) -> outcome.

    gate:         clean | resume | replace | abort   (from existing_install_action)
    choice:       "" | resume | start_over | replace | cancel
    confirmation: the typed confirmation; destructive choices must equal install_root.

    Destructive choices (start over / replace) delete the install root; they
    require the install root to be typed. The abort policy is always honored:
    gate=abort refuses and offers no destructive path.
    """
    if gate not in GATE_ACTIONS:
        return OUTCOME_REFUSE

    if gate == "clean":
        return OUTCOME_FORM

    if gate == "resume":
        if choice in ("", "resume"):
            return OUTCOME_FORM
        if choice == "start_over":
            return OUTCOME_FORM_FRESH if confirmation == install_root else OUTCOME_CONFIRM_START_OVER
        return OUTCOME_CANCEL

    if gate == "replace":
        if choice in ("", "replace"):
            return OUTCOME_FORM_FRESH if confirmation == install_root else OUTCOME_CONFIRM_REPLACE
        return OUTCOME_CANCEL

    # gate == "abort"
    return OUTCOME_REFUSE


def client_data_required(resume: bool, checkpoint: str) -> bool:
    """A resume past the extraction phase no longer needs the client data path."""
    if resume and checkpoint in CHECKPOINTS_CLIENT_DATA_DONE:
        return False
    return True


# ---------------------------------------------------------------------------
# Secrets file rendering and writing
# ---------------------------------------------------------------------------


def render_setup_conf(values: InstallValues, generated_at: str) -> str:
    """Render the exact auto_install.sh secrets file format."""
    lines = [
        "# VMANGOS Installation Secrets",
        f"# Generated: {generated_at}",
        "# Permissions: root:root 600",
        "",
        "# Database Admin (root)",
        f'SQLADMINUSER="{values.sql_admin_user}"',
        f'SQLADMINIP="{values.sql_admin_ip}"',
        f'SQLADMINPASS="{values.sql_admin_pass}"',
        "",
        "# VMANGOS Database User",
        f'MANGOSDBUSER="{values.db_user}"',
        f'MANGOSDBPASS="{values.db_password}"',
        "",
        "# OS User for running server",
        f'MANGOSOSUSER="{values.os_user}"',
        "",
        "# Database Names",
        f'AUTHDB="{values.auth_db}"',
        f'WORLDDB="{values.world_db}"',
        f'CHARACTERDB="{values.characters_db}"',
        f'LOGSDB="{values.logs_db}"',
        "",
        "# Installation Paths",
        f'INSTALLROOT="{values.install_root}"',
        f'CLIENTDATA="{values.client_data}"',
        "",
        "# Auto-install settings",
        f'SKIP_SECURE_MYSQL="{values.skip_secure_mysql}"',
        f'PROVISIONTARGET="{values.provision_target}"',
        f'REINSTALL_POLICY="{values.reinstall_policy}"',
        "",
    ]
    return "\n".join(lines)


def utc_timestamp_iso() -> str:
    """A UTC timestamp in the same shape `date -Iseconds` produces."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+00:00")


def write_setup_conf(path: str | Path, values: InstallValues, generated_at: str | None = None) -> Path:
    """Atomically write the secrets file: temp file + rename, 600 root:root."""
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(target.parent, 0o700)
    except OSError:
        # Best effort: the file below is still 600; the directory may not be
        # ours to tighten (non-root test runs).
        pass

    payload = render_setup_conf(values, generated_at or utc_timestamp_iso())

    fd, tmp_name = tempfile.mkstemp(dir=str(target.parent), prefix=".setup.conf.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            os.fchmod(handle.fileno(), 0o600)
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, target)
        try:
            os.chown(target, 0, 0)
        except (OSError, PermissionError):
            # Non-root test runs: ownership is already the invoking user.
            pass
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise
    return target


# ---------------------------------------------------------------------------
# Launch (runner seam)
# ---------------------------------------------------------------------------


def build_launch_command(
    installer_lib: str,
    secrets_file: str,
    setup_script: str,
    fresh: bool = False,
    install_root: str = "",
) -> list[str]:
    """The bash command that starts the install unit through the runner.

    ``installer_lib`` is manager/lib/installer.sh; the runner's
    installer_unit_start does the systemd-run work.

    For a destructive launch (replace / start over) the existing install
    root is removed first via ``installer_clear_install`` — the same
    auto_install.sh replace semantics — so the setup script starts from
    START instead of resuming the old checkpoint.
    """
    if fresh and install_root:
        script = (
            'source "$1" >/dev/null 2>&1 && '
            'installer_clear_install "$2" && '
            'installer_unit_start "$3" "$4"'
        )
        return [
            "bash",
            "-c",
            script,
            "installer",
            installer_lib,
            install_root,
            secrets_file,
            setup_script,
        ]
    script = 'source "$1" >/dev/null 2>&1 && installer_unit_start "$2" "$3"'
    return [
        "bash",
        "-c",
        script,
        "installer",
        installer_lib,
        secrets_file,
        setup_script,
    ]


def launch_install(
    installer_lib: str,
    secrets_file: str,
    setup_script: str,
    fresh: bool = False,
    install_root: str = "",
    runner: Callable[..., Any] | None = None,
) -> tuple[int, str, str]:
    """Start the install unit (clearing the root first when destructive).

    Returns (returncode, stdout, stderr). ``runner`` is the monkeypatch
    seam for tests (defaults to subprocess.run).
    """
    command = build_launch_command(
        installer_lib,
        secrets_file,
        setup_script,
        fresh=fresh,
        install_root=install_root,
    )
    run = runner or subprocess.run
    completed = run(command, capture_output=True, text=True, check=False)
    return int(completed.returncode), completed.stdout or "", completed.stderr or ""


def redact_secrets(text: str, values: InstallValues) -> str:
    """Remove any secret value from a message before it can be shown or logged."""
    result = text
    for field_name in ("db_password", "sql_admin_pass"):
        secret = getattr(values, field_name)
        if secret:
            result = result.replace(secret, "******")
    return result


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------


def validate_values(values: InstallValues, resume: bool, checkpoint: str) -> list[str]:
    """Return the list of validation errors (empty when the form is valid)."""
    errors: list[str] = []

    if not values.install_root:
        errors.append("Install root is required.")

    if not _IDENTIFIER_RE.fullmatch(values.auth_db):
        errors.append("Auth DB name must be a valid identifier (letters, digits, underscore).")
    if not _IDENTIFIER_RE.fullmatch(values.world_db):
        errors.append("World DB name must be a valid identifier (letters, digits, underscore).")
    if not _IDENTIFIER_RE.fullmatch(values.characters_db):
        errors.append("Characters DB name must be a valid identifier (letters, digits, underscore).")
    if not _IDENTIFIER_RE.fullmatch(values.logs_db):
        errors.append("Logs DB name must be a valid identifier (letters, digits, underscore).")

    if not _IDENTIFIER_RE.fullmatch(values.db_user):
        errors.append("DB user must be a valid identifier (letters, digits, underscore).")
    if not values.db_password:
        errors.append("DB password is required (use Generate).")

    if not _IDENTIFIER_RE.fullmatch(values.os_user):
        errors.append("OS user must be a valid identifier (letters, digits, underscore).")

    if values.provision_target not in PROVISION_TARGETS:
        errors.append(f"Provision target must be one of: {', '.join(PROVISION_TARGETS)}.")

    if client_data_required(resume, checkpoint) and not values.client_data:
        errors.append("Client data path is required.")
    elif values.client_data and not os.path.isdir(values.client_data):
        errors.append(f"Client data path does not exist: {values.client_data}")

    return errors


# ---------------------------------------------------------------------------
# Textual wizard
# ---------------------------------------------------------------------------


def create_wizard_app(
    gate: str,
    checkpoint: str,
    secrets: dict[str, str],
    secrets_file: str,
    setup_script: str,
    installer_lib: str,
    runner: Callable[..., Any] | None = None,
):
    """Build the wizard App. Kept behind a factory so tests never import it."""
    from textual.app import App, ComposeResult
    from textual.screen import Screen
    from textual.widgets import Button, Input, Static

    class WizardState:
        """Shared state for the wizard screens."""

        def __init__(self) -> None:
            self.values = form_defaults(secrets)
            self.resume = gate == "resume"
            self.checkpoint = checkpoint or ""
            self.fresh = False  # set when the user chose start-over / replace

    state = WizardState()

    WIZARD_CSS = """
    .wizard-body {
        width: 80;
        height: auto;
        margin: 1 2 0 2;
    }
    .wizard-title {
        text-style: bold;
        margin-bottom: 1;
    }
    .wizard-field {
        margin-bottom: 1;
    }
    .wizard-field-label {
        width: 100%;
    }
    .wizard-actions {
        height: auto;
        margin-top: 2;
    }
    .wizard-actions Button {
        margin-right: 1;
    }
    .wizard-error {
        color: #fb7185;
        margin-bottom: 1;
    }
    .wizard-note {
        text-style: dim;
        margin-bottom: 1;
    }
    .wizard-review {
        width: 100%;
    }
    """

    class WizardScreen(Screen[None]):
        """Base screen with the shared state."""

        def values(self) -> WizardState:
            return self.app.state  # type: ignore[attr-defined]

    class GateScreen(WizardScreen):
        """Existing-install gate: resume / replace / abort / clean."""

        def compose(self) -> ComposeResult:
            st = self.values()
            yield Static("Install Wizard", classes="wizard-title")
            if gate == "resume":
                yield Static(
                    f"Existing partial installation found at {st.values.install_root} "
                    f"(checkpoint: {st.checkpoint or 'unknown'}).",
                )
                yield Static("You can resume from the last checkpoint, or start over.", classes="wizard-note")
                yield Button("Resume from last checkpoint", variant="primary", id="gate-resume")
                yield Button(f"Start over (deletes {st.values.install_root})", variant="error", id="gate-start-over")
            elif gate == "replace":
                yield Static(f"Existing installation found at {st.values.install_root}.")
                yield Static(
                    "REINSTALL_POLICY=replace allows replacing it. Replacement deletes the install root.",
                    classes="wizard-note",
                )
                yield Button(f"Replace (deletes {st.values.install_root})", variant="error", id="gate-replace")
                yield Button("Cancel", id="gate-cancel")
            elif gate == "abort":
                yield Static(f"Existing installation found at {st.values.install_root}.")
                yield Static("REINSTALL_POLICY=abort refuses to replace it.", classes="wizard-note")
                yield Static(
                    f"To replace it, set REINSTALL_POLICY=\"replace\" in {secrets_file} and re-run.",
                    classes="wizard-note",
                )
                yield Button("Close", id="gate-close")
            else:  # clean
                yield Static("No existing installation found. Ready to install.")
                yield Button("Continue to install form", variant="primary", id="gate-continue")

        def on_button_pressed(self, event) -> None:
            st = self.values()
            outcome = None
            if event.button.id == "gate-continue":
                outcome = gate_decision(gate, "", "", st.values.install_root)
            elif event.button.id == "gate-resume":
                outcome = gate_decision(gate, "resume", "", st.values.install_root)
            elif event.button.id == "gate-start-over":
                outcome = gate_decision(gate, "start_over", "", st.values.install_root)
            elif event.button.id == "gate-replace":
                outcome = gate_decision(gate, "replace", "", st.values.install_root)
            elif event.button.id == "gate-cancel":
                outcome = OUTCOME_CANCEL
            elif event.button.id == "gate-close":
                self.app.close_with_code(1)
                return

            if outcome == OUTCOME_FORM:
                st.resume = (gate == "resume")
                self.app.push_form()
            elif outcome == OUTCOME_FORM_FRESH:
                st.fresh = True
                st.resume = False
                self.app.push_form()
            elif outcome in (OUTCOME_CONFIRM_START_OVER, OUTCOME_CONFIRM_REPLACE):
                self.app.push_confirm(outcome)
            elif outcome == OUTCOME_CANCEL:
                self.app.close_with_code(0)
            elif outcome == OUTCOME_REFUSE:
                self.app.close_with_code(1)

    class ConfirmScreen(WizardScreen):
        """Typed confirmation for destructive choices."""

        def __init__(self, outcome: str) -> None:
            super().__init__()
            self.outcome = outcome

        def compose(self) -> ComposeResult:
            st = self.values()
            root = st.values.install_root
            yield Static("Confirm destructive action", classes="wizard-title")
            if self.outcome == OUTCOME_CONFIRM_START_OVER:
                yield Static(f"Starting over deletes {root} and its checkpoints.")
            else:
                yield Static(f"Replacing deletes {root}.")
            yield Static(f'Type the install root to confirm: {root}', classes="wizard-note")
            yield Input(placeholder=root, id="confirm-input")
            yield Button("Confirm", variant="error", id="confirm-yes")
            yield Button("Cancel", id="confirm-no")

        def on_button_pressed(self, event) -> None:
            st = self.values()
            if event.button.id == "confirm-yes":
                typed = self.query_one("#confirm-input", Input).value
                if self.outcome == OUTCOME_CONFIRM_START_OVER:
                    outcome = gate_decision(gate, "start_over", typed, st.values.install_root)
                else:
                    outcome = gate_decision(gate, "replace", typed, st.values.install_root)
                if outcome == OUTCOME_FORM_FRESH:
                    st.fresh = True
                    st.resume = False
                    self.app.push_form()
                else:
                    self.dismiss()
            else:
                self.dismiss()

    class FormScreen(WizardScreen):
        """The install form (10 fields)."""

        FIELD_IDS = (
            ("install_root", "Install root"),
            ("client_data", "Client data path"),
            ("auth_db", "Auth DB name"),
            ("world_db", "World DB name"),
            ("characters_db", "Characters DB name"),
            ("logs_db", "Logs DB name"),
            ("db_user", "DB user"),
            ("db_password", "DB password"),
            ("os_user", "OS user"),
            ("provision_target", "Provision target"),
        )

        def compose(self) -> ComposeResult:
            st = self.values()
            yield Static("Install Form", classes="wizard-title")
            if st.resume:
                yield Static(f"Resuming from checkpoint {st.checkpoint or 'unknown'}.", classes="wizard-note")
            elif st.fresh:
                yield Static(
                    f"Fresh install into {st.values.install_root} "
                    "(the existing install root is deleted before the unit starts).",
                    classes="wizard-note",
                )
            yield Static("", id="form-errors", classes="wizard-error")
            for field_id, label in self.FIELD_IDS:
                yield Static(label, classes="wizard-field-label")
                yield Input(value=getattr(st.values, field_id), id=f"field-{field_id}",
                            classes="wizard-field")
            yield Button("Generate", id="generate-password")
            yield Static(
                f"Provision target: {', '.join(PROVISION_TARGETS)}",
                classes="wizard-note",
            )
            yield Button("Back", id="form-back")
            yield Button("Review", variant="primary", id="form-review")

        def collect(self) -> InstallValues:
            st = self.values()
            values = st.values
            return InstallValues(
                install_root=self.query_one("#field-install_root", Input).value.strip(),
                client_data=self.query_one("#field-client_data", Input).value.strip(),
                auth_db=self.query_one("#field-auth_db", Input).value.strip(),
                world_db=self.query_one("#field-world_db", Input).value.strip(),
                characters_db=self.query_one("#field-characters_db", Input).value.strip(),
                logs_db=self.query_one("#field-logs_db", Input).value.strip(),
                db_user=self.query_one("#field-db_user", Input).value.strip(),
                db_password=self.query_one("#field-db_password", Input).value,
                os_user=self.query_one("#field-os_user", Input).value.strip(),
                provision_target=self.query_one("#field-provision_target", Input).value.strip(),
                sql_admin_user=values.sql_admin_user,
                sql_admin_ip=values.sql_admin_ip,
                sql_admin_pass=values.sql_admin_pass,
                skip_secure_mysql=values.skip_secure_mysql,
                reinstall_policy=values.reinstall_policy,
            )

        def on_button_pressed(self, event) -> None:
            st = self.values()
            if event.button.id == "generate-password":
                self.query_one("#field-db_password", Input).value = generate_password()
            elif event.button.id == "form-back":
                self.dismiss()
            elif event.button.id == "form-review":
                st.values = self.collect()
                errors = validate_values(st.values, st.resume, st.checkpoint)
                error_box = self.query_one("#form-errors", Static)
                if errors:
                    error_box.update("\n".join(errors))
                    return
                error_box.update("")
                self.app.push_review()

    class ReviewScreen(WizardScreen):
        """Summary of every value, with destructive implications named."""

        def compose(self) -> ComposeResult:
            st = self.values()
            v = st.values
            yield Static("Review", classes="wizard-title")

            if st.resume:
                impact = (
                    f"Resuming the existing installation at {v.install_root} "
                    f"(checkpoint {st.checkpoint or 'unknown'}). Existing services may be stopped and reconfigured."
                )
            elif st.fresh:
                impact = (
                    f"REPLACING: deletes {v.install_root} (all data) and reinstalls. "
                    f"Existing VMANGOS services are stopped first."
                )
            else:
                impact = (
                    f"Fresh install into {v.install_root}. MySQL is configured or reused; "
                    f"existing data in {v.install_root} is left untouched unless it exists."
                )
            yield Static(impact, classes="wizard-note")
            yield Static("")

            rows = [
                ("Install root", v.install_root),
                ("Client data path", v.client_data),
                ("Auth DB", v.auth_db),
                ("World DB", v.world_db),
                ("Characters DB", v.characters_db),
                ("Logs DB", v.logs_db),
                ("DB user", v.db_user),
                ("DB password", v.db_password),
                ("OS user", v.os_user),
                ("Provision target", v.provision_target),
                ("SQL admin user", v.sql_admin_user),
                ("SQL admin IP", v.sql_admin_ip),
                ("SQL admin password", v.sql_admin_pass),
                ("Skip secure MySQL", v.skip_secure_mysql),
                ("Reinstall policy", v.reinstall_policy),
            ]
            for label, value in rows:
                yield Static(f"{label}: {value}", classes="wizard-review")
            yield Static(f"Secrets file: {secrets_file} (root:root 600)", classes="wizard-note")

            yield Button("Back", id="review-back")
            yield Button("Confirm & Start Install", variant="primary", id="review-start")

        def on_button_pressed(self, event) -> None:
            if event.button.id == "review-back":
                self.dismiss()
            elif event.button.id == "review-start":
                self.app.push_launch()

    class LaunchScreen(WizardScreen):
        """Writes the secrets file, starts the unit, and reports the result."""

        def compose(self) -> ComposeResult:
            yield Static("Launching", classes="wizard-title")
            yield Static("Starting the install unit...", id="launch-status")
            yield Static("", id="launch-detail", classes="wizard-note")
            yield Button("Close", id="launch-close")

        def on_mount(self) -> None:
            st = self.values()
            status = self.query_one("#launch-status", Static)
            detail = self.query_one("#launch-detail", Static)
            try:
                write_setup_conf(secrets_file, st.values)
                status.update(f"Secrets written to {secrets_file}")
                rc, out, err = launch_install(
                    installer_lib,
                    secrets_file,
                    setup_script,
                    fresh=st.fresh,
                    install_root=st.values.install_root,
                    runner=runner,
                )
                if rc == 0:
                    detail.update(
                        "Install started in systemd unit vmangos-install.\n"
                        "Re-run sudo vmangos-manager install to attach.\n"
                        "journalctl -u vmangos-install -f to watch."
                    )
                    self.app.code = 0
                else:
                    # Show the runner's output verbatim (secrets redacted), and
                    # always name the fix: the journalctl pointer and how to
                    # retry. If the runner already included the diagnosis
                    # (installer.sh appends it on failure) don't duplicate it.
                    combined = (out or "") + ("\n" + err if err else "")
                    body = redact_secrets(combined, st.values).strip()
                    if not body:
                        body = "Install unit failed to start."
                    if "journalctl -u vmangos-install" not in body:
                        body += (
                            "\nDiagnosis: journalctl -u vmangos-install -n 50"
                            "\nRetry: sudo vmangos-manager install"
                        )
                    detail.update(body)
                    self.app.code = 1
            except Exception as exc:  # noqa: BLE001 - surface any failure on the exit screen
                detail.update(redact_secrets(str(exc), st.values))
                self.app.code = 1

        def on_button_pressed(self, event) -> None:
            if event.button.id == "launch-close":
                self.app.close_with_code(self.app.code)

    class InstallWizardApp(App[None]):
        CSS = WIZARD_CSS
        TITLE = "VMANGOS Install Wizard"

        def __init__(self) -> None:
            super().__init__()
            self.state = state
            self.code = 1

        def close_with_code(self, code: int) -> None:
            self.code = code
            self.exit()

        def push_form(self) -> None:
            self.push_screen(FormScreen())

        def push_confirm(self, outcome: str) -> None:
            self.push_screen(ConfirmScreen(outcome))

        def push_review(self) -> None:
            self.push_screen(ReviewScreen())

        def push_launch(self) -> None:
            self.push_screen(LaunchScreen())

        def on_mount(self) -> None:
            self.push_screen(GateScreen())

    return InstallWizardApp()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="VMANGOS one-time install wizard")
    parser.add_argument("--manager-bin", required=True, help="Path to vmangos-manager")
    parser.add_argument("--config", required=True, help="Manager config file")
    parser.add_argument("--secrets-file", default=DEFAULT_SECRETS_FILE, help="Secrets file to write")
    parser.add_argument("--setup-script", required=True, help="Path to vmangos_setup.sh")
    parser.add_argument("--gate", choices=GATE_ACTIONS, default="clean", help="Existing-install gate action")
    parser.add_argument("--checkpoint", default="", help="Resume checkpoint name (if any)")
    parser.add_argument("--installer-lib", default=None, help="Path to installer.sh (runner)")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    secrets = parse_secrets_file(args.secrets_file)

    installer_lib = args.installer_lib
    if not installer_lib:
        # manager/lib/installer.sh sits next to this file.
        installer_lib = str(Path(__file__).resolve().with_name("installer.sh"))

    app = create_wizard_app(
        gate=args.gate,
        checkpoint=args.checkpoint,
        secrets=secrets,
        secrets_file=args.secrets_file,
        setup_script=args.setup_script,
        installer_lib=installer_lib,
    )
    app.run()
    return int(getattr(app, "code", 1) or 0)


if __name__ == "__main__":
    raise SystemExit(main())
