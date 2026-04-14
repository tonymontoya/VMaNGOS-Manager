#!/usr/bin/env python3
"""Textual dashboard for VMANGOS Manager."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import threading
from datetime import datetime, timezone
from typing import Any


STATUS_COLORS = {
    "healthy": "#34d399",
    "ok": "#22c55e",
    "active": "#2dd4bf",
    "warning": "#f59e0b",
    "degraded": "#fbbf24",
    "missing": "#f59e0b",
    "stopped": "#f59e0b",
    "inactive": "#f59e0b",
    "critical": "#f87171",
    "failed": "#ef4444",
    "crash-loop": "#fb7185",
    "unreachable": "#fb7185",
    "unavailable": "#94a3b8",
}

ACCENT_GOLD = "#f59e0b"
ACCENT_SKY = "#7dd3fc"
ACCENT_TEAL = "#2dd4bf"
ACCENT_ROSE = "#fb7185"
ACCENT_MUTED = "#cbd5e1"
ACCENT_GREEN = "#34d399"
ACCENT_BLUE = "#3b82f6"

ACTION_STYLES = {
    "info": ("LIVE", ACCENT_SKY),
    "running": ("WORKING", ACCENT_GOLD),
    "success": ("READY", ACCENT_GREEN),
    "warning": ("CHECK", ACCENT_GOLD),
    "error": ("ERROR", ACCENT_ROSE),
}

VIEW_TITLES = {
    "overview": "Overview",
    "monitor": "Monitor",
    "accounts": "Accounts",
    "backups": "Backups",
    "config": "Config",
    "operations": "Operations",
}

VIEW_SUMMARIES = {
    "overview": "Keep a summary-first realm pulse: services, host pressure, players, and alerts.",
    "monitor": "Diagnose host pressure with deeper trends, device saturation, and realm process footprint.",
    "accounts": "Work the selected-account admin flow for provisioning, access, and moderation.",
    "backups": "Check protection posture, then act on the selected archive with confidence.",
    "config": "Confirm Manager's wiring view before you trust higher-level automation.",
    "operations": "Review the maintenance queue and preflight risky change windows.",
}

USERNAME_PATTERN = re.compile(r"^[A-Za-z0-9]{2,32}$")
GM_LEVEL_PATTERN = re.compile(r"^[0-3]$")
DURATION_PATTERN = re.compile(r"^[1-9][0-9]*[smhdw]$")
BAN_REASON_PATTERN = re.compile(r"^[A-Za-z0-9]+(?: [A-Za-z0-9]+)*$")
DAILY_TIME_PATTERN = re.compile(r"^([0-1][0-9]|2[0-3]):[0-5][0-9]$")
WEEKLY_SCHEDULE_PATTERN = re.compile(r"^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) ([0-1][0-9]|2[0-3]):[0-5][0-9]$")
SCHEDULE_TYPE_PATTERN = re.compile(r"^(daily|weekly)$", re.IGNORECASE)
DAY_NAME_PATTERN = re.compile(r"^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$")
WARNINGS_PATTERN = re.compile(r"^[1-9][0-9]*(,[1-9][0-9]*)*$")

TREND_HISTORY_LIMIT = 24
SPARKLINE_BARS = "▁▂▃▄▅▆▇█"
TREND_THRESHOLDS = {
    "cpu": 3.0,
    "memory": 2.0,
    "load": 0.08,
    "disk": 1.0,
    "players": 1.0,
    "io": 2.0,
}


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="VMANGOS Manager Textual dashboard")
    parser.add_argument("--manager-bin", required=True, help="Path to vmangos-manager")
    parser.add_argument("--config", required=True, help="Path to manager.conf")
    parser.add_argument("--refresh", type=int, default=2, help="Refresh interval in seconds")
    parser.add_argument("--theme", choices=("dark", "light"), default="dark", help="Dashboard theme")
    parser.add_argument("--view", choices=tuple(VIEW_TITLES.keys()), default="overview", help="Initial dashboard view")
    parser.add_argument("--screenshot", help="Write an SVG screenshot after the first refresh and exit")
    parser.add_argument(
        "--snapshot-file",
        help="Load dashboard data from a snapshot JSON fixture instead of live manager commands",
    )
    parser.add_argument(
        "--snapshot-json",
        action="store_true",
        help="Print a single aggregated snapshot as JSON and exit",
    )
    return parser.parse_args(argv)


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat()


def parse_manager_json(stdout: str) -> dict[str, Any]:
    payload = json.loads(stdout)
    if not payload.get("success"):
        error = payload.get("error") or {}
        raise RuntimeError(error.get("message") or "manager command failed")
    return payload.get("data") or {}


def run_manager_command(
    manager_bin: str,
    config_path: str,
    command: list[str],
    *,
    parser_mode: str = "envelope",
    use_global_json: bool = False,
) -> dict[str, Any]:
    full_command = [manager_bin, "-c", config_path]
    if use_global_json:
        full_command.extend(["-f", "json"])
    full_command.extend(command)
    completed = subprocess.run(full_command, capture_output=True, text=True, check=False)

    if completed.returncode != 0:
        stderr = (completed.stderr or completed.stdout).strip()
        message = stderr or f"command failed with exit code {completed.returncode}"
        return {
            "ok": False,
            "command": " ".join(command),
            "error": message,
            "exit_code": completed.returncode,
            "data": {},
        }

    try:
        if parser_mode == "envelope":
            data = parse_manager_json(completed.stdout)
        elif parser_mode == "json":
            data = json.loads(completed.stdout)
        else:
            raise ValueError(f"Unsupported parser mode: {parser_mode}")
    except (json.JSONDecodeError, RuntimeError, ValueError) as exc:
        return {
            "ok": False,
            "command": " ".join(command),
            "error": str(exc),
            "exit_code": completed.returncode,
            "data": {},
        }

    return {
        "ok": True,
        "command": " ".join(command),
        "error": "",
        "exit_code": completed.returncode,
        "data": data,
    }


def clamp_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def clamp_float(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def format_mb_from_kb(value_kb: Any) -> str:
    value = clamp_int(value_kb)
    return f"{value / 1024:.1f} MB"


def format_gb_from_kb(value_kb: Any) -> str:
    value = clamp_int(value_kb)
    return f"{value / 1024 / 1024:.1f} GB"


def format_bytes(value_bytes: Any) -> str:
    value = clamp_float(value_bytes)
    units = ["B", "KB", "MB", "GB", "TB"]
    unit_index = 0
    while value >= 1024 and unit_index < len(units) - 1:
        value /= 1024
        unit_index += 1
    if unit_index == 0:
        return f"{int(value)} {units[unit_index]}"
    return f"{value:.1f} {units[unit_index]}"


def format_state(value: Any) -> str:
    text = str(value or "unknown")
    color = STATUS_COLORS.get(text, "white")
    return f"[bold {color}]{text}[/]"


def format_flag(
    value: Any,
    *,
    true_text: str = "yes",
    false_text: str = "no",
    true_color: str = ACCENT_GREEN,
    false_color: str = ACCENT_MUTED,
) -> str:
    if value:
        return f"[bold {true_color}]{true_text}[/]"
    return f"[bold {false_color}]{false_text}[/]"


def truncate_text(value: Any, max_length: int = 76) -> str:
    text = str(value or "")
    if len(text) <= max_length:
        return text
    return f"{text[: max_length - 3]}..."


def escape_markup(value: Any) -> str:
    return str(value or "").replace("[", "\\[").replace("]", "\\]")


def format_error_text(value: Any, max_length: int = 92) -> str:
    text = " ".join(str(value or "unknown error").split())
    message_match = re.search(r'"message":"([^"]+)"', text)
    suggestion_match = re.search(r'"suggestion":"([^"]+)"', text)

    if message_match:
        parts = [message_match.group(1)]
        if suggestion_match:
            parts.append(suggestion_match.group(1))
        text = " ".join(parts)

    return escape_markup(truncate_text(text, max_length))


def parse_optional_float(value: Any) -> float | None:
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def extract_monitoring_sample(snapshot: dict[str, Any]) -> dict[str, Any]:
    sample: dict[str, Any] = {
        "captured_at": str(snapshot.get("captured_at", "") or ""),
        "cpu": None,
        "memory": None,
        "load": None,
        "disk": None,
        "players": None,
        "io": None,
    }

    server = snapshot.get("server", {})
    if not server.get("ok"):
        return sample

    data = server.get("data", {})
    host = data.get("host", {})
    players = data.get("players", {})
    storage_io = data.get("storage_io", {})

    sample["cpu"] = parse_optional_float(host.get("cpu", {}).get("usage_percent"))
    sample["memory"] = parse_optional_float(host.get("memory", {}).get("used_percent"))
    sample["load"] = parse_optional_float(host.get("load", {}).get("load_1"))
    sample["disk"] = parse_optional_float(data.get("checks", {}).get("disk_space", {}).get("used_percent"))
    sample["players"] = parse_optional_float(players.get("online", len(snapshot.get("players", []))))
    if storage_io.get("available"):
        sample["io"] = parse_optional_float(storage_io.get("util_percent"))

    return sample


def append_monitoring_sample(
    history: list[dict[str, Any]],
    snapshot: dict[str, Any],
    max_samples: int = TREND_HISTORY_LIMIT,
) -> list[dict[str, Any]]:
    sample = extract_monitoring_sample(snapshot)
    metric_keys = ("cpu", "memory", "load", "disk", "players", "io")
    if not any(sample.get(key) is not None for key in metric_keys):
        return list(history)

    updated = list(history)
    if updated and updated[-1].get("captured_at") == sample.get("captured_at"):
        updated[-1] = sample
    else:
        updated.append(sample)

    return updated[-max_samples:]


def history_values(history: list[dict[str, Any]], key: str) -> list[float | None]:
    return [parse_optional_float(sample.get(key)) for sample in history]


def render_sparkline(values: list[float | None], width: int = 10) -> str:
    window = list(values[-width:])
    available = [value for value in window if value is not None]
    if not available:
        return "·" * width

    if len(window) < width:
        window = [available[0]] * (width - len(window)) + window

    minimum = min(available)
    maximum = max(available)
    if abs(maximum - minimum) < 0.001:
        return SPARKLINE_BARS[3] * width

    chars: list[str] = []
    for value in window:
        if value is None:
            chars.append("·")
            continue
        index = int(round(((value - minimum) / (maximum - minimum)) * (len(SPARKLINE_BARS) - 1)))
        chars.append(SPARKLINE_BARS[index])
    return "".join(chars)


def strip_markup(value: str) -> str:
    return re.sub(r"\[[^\]]*\]", "", value)


def pad_markup(value: str, width: int) -> str:
    visible_length = len(strip_markup(value))
    return f"{value}{' ' * max(width - visible_length, 0)}"


def compact_metric_state(value: Any) -> str:
    normalized = str(value or "").strip().lower()
    if normalized in ("", "ok", "healthy", "active"):
        return ""
    return f" {normalized}"


def describe_trend(values: list[float | None], metric_key: str) -> str:
    available = [value for value in values if value is not None]
    if len(available) < 2:
        return "warming"

    delta = available[-1] - available[0]
    threshold = TREND_THRESHOLDS.get(metric_key, 1.0)
    if abs(delta) < threshold:
        return "steady"
    return "rising" if delta > 0 else "easing"


def history_window_label(history: list[dict[str, Any]], refresh_interval: int) -> str:
    if len(history) < 2:
        return "warming up"
    seconds = max((len(history) - 1) * max(refresh_interval, 1), 0)
    return f"{len(history)} samples / ~{seconds}s"


def player_key_value(value: Any) -> str:
    candidate = getattr(value, "value", value)
    return "" if candidate is None else str(candidate)


def iso_to_display(value: Any) -> str:
    text = str(value or "")
    if not text:
        return "n/a"
    try:
        normalized = text.replace("Z", "+00:00")
        return datetime.fromisoformat(normalized).astimezone().strftime("%Y-%m-%d %H:%M:%S")
    except ValueError:
        return text


def iso_to_clock(value: Any) -> str:
    text = str(value or "")
    if not text:
        return "n/a"
    try:
        normalized = text.replace("Z", "+00:00")
        return datetime.fromisoformat(normalized).astimezone().strftime("%H:%M:%S")
    except ValueError:
        return text


def schedule_job_type_label(job_type: Any) -> str:
    normalized = str(job_type or "").strip().lower()
    if normalized == "honor":
        return "maintenance"
    if not normalized:
        return "n/a"
    return normalized.replace("_", " ")


def parse_ini_content(content: str) -> dict[str, str]:
    values: dict[str, str] = {}
    section = ""

    for raw_line in content.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip().lower()
            continue
        if "=" not in line or not section:
            continue
        key, value = line.split("=", 1)
        values[f"{section}.{key.strip().lower()}"] = value.strip()

    return values


def normalize_form_values(values: dict[str, Any] | None) -> dict[str, str]:
    normalized: dict[str, str] = {}
    for key, value in (values or {}).items():
        normalized[key] = str(value or "").strip()
    return normalized


def find_selected_account(snapshot: dict[str, Any], selected_account_id: str) -> dict[str, Any] | None:
    accounts = snapshot.get("all_accounts", [])
    if selected_account_id:
        for account in accounts:
            if str(account.get("id", "")) == selected_account_id:
                return account
    return accounts[0] if accounts else None


def find_selected_backup(snapshot: dict[str, Any], selected_backup_file: str) -> dict[str, Any] | None:
    entries = snapshot.get("backups", {}).get("entries", [])
    if selected_backup_file:
        for entry in entries:
            if str(entry.get("file", "")) == selected_backup_file:
                return entry
    return max(entries, key=lambda item: str(item.get("timestamp", ""))) if entries else None


def find_selected_schedule(snapshot: dict[str, Any], selected_schedule_id: str) -> dict[str, Any] | None:
    entries = snapshot.get("schedules", [])
    if selected_schedule_id:
        for entry in entries:
            if str(entry.get("id", "")) == selected_schedule_id:
                return entry
    return entries[0] if entries else None


def format_command_tokens(tokens: list[tuple[str, str]]) -> str:
    return "  ".join(f"[bold {ACCENT_GOLD}]{key}[/] {label}" for key, label in tokens)


def view_command_tokens(active_view: str) -> list[tuple[str, str]]:
    if active_view == "monitor":
        return [
            ("o", "roster"),
            ("s", "start"),
            ("x", "stop"),
            ("R", "restart"),
            ("b", "backup"),
            ("v", "verify"),
        ]
    if active_view == "accounts":
        return [
            ("c", "create"),
            ("p", "reset password"),
            ("g", "set GM"),
            ("n", "ban"),
            ("u", "unban"),
        ]
    if active_view == "backups":
        return [
            ("b", "backup now"),
            ("v", "verify"),
            ("d", "restore dry-run"),
            ("y", "daily timer"),
            ("w", "weekly timer"),
        ]
    if active_view == "operations":
        return [
            ("h", "schedule maintenance"),
            ("m", "schedule restart"),
            ("j", "cancel schedule"),
            ("P", "update plan"),
            ("T", "test logs"),
            ("l", "rotate logs"),
        ]
    if active_view == "config":
        return [("k", "validate config")]
    return [
        ("o", "roster"),
        ("s", "start"),
        ("x", "stop"),
        ("R", "restart"),
        ("b", "backup"),
        ("v", "verify"),
        ("k", "validate config"),
    ]


def render_command_rail(active_view: str) -> str:
    navigation = format_command_tokens(
        [
            ("1", "overview"),
            ("2", "monitor"),
            ("3", "accounts"),
            ("4", "backups"),
            ("5", "config"),
            ("6", "ops"),
        ]
    )
    global_actions = format_command_tokens([("r", "refresh"), ("t", "theme"), ("q", "quit")])
    context_actions = format_command_tokens(view_command_tokens(active_view))
    return "\n".join(
        [
            f"[bold {ACCENT_SKY}]Navigate[/]  {navigation}",
            f"[bold {ACCENT_SKY}]Global[/]    {global_actions}",
            f"[bold {ACCENT_SKY}]This View[/] {context_actions}",
        ]
    )


def build_dashboard_action_request(
    snapshot: dict[str, Any],
    selected_account_id: str,
    selected_backup_file: str,
    selected_schedule_id: str,
    action_name: str,
    form_values: dict[str, Any] | None = None,
) -> dict[str, Any]:
    values = normalize_form_values(form_values)

    if action_name == "account_create":
        username = values.get("username", "")
        password = values.get("password", "")
        confirm_password = values.get("confirm_password", "")
        if not USERNAME_PATTERN.fullmatch(username):
            return {"error": "account create skipped: username must be 2-32 alphanumeric characters"}
        if len(password) < 6 or len(password) > 32:
            return {"error": "account create skipped: password must be 6-32 characters"}
        if password != confirm_password:
            return {"error": "account create skipped: passwords do not match"}
        return {
            "label": f"account create {username}",
            "command": ["account", "create", username, "--password-env"],
            "env": {"VMANGOS_PASSWORD": password},
            "refresh_after": True,
            "view": "accounts",
        }

    if action_name == "config_validate":
        return {
            "label": "config validate",
            "command": ["config", "validate"],
            "env": {},
            "refresh_after": True,
            "view": "config",
        }

    if action_name == "logs_rotate":
        return {
            "label": "logs rotate",
            "command": ["logs", "rotate"],
            "env": {},
            "refresh_after": True,
            "view": "operations",
        }

    if action_name == "logs_test_config":
        return {
            "label": "logs test-config",
            "command": ["logs", "test-config"],
            "env": {},
            "refresh_after": False,
            "view": "operations",
        }

    account = find_selected_account(snapshot, selected_account_id)
    if action_name.startswith("account_"):
        if account is None:
            return {"error": "account action skipped: no account selected"}
        username = str(account.get("username", "")).strip()
        if not username:
            return {"error": "account action skipped: selected account has no username"}

        if action_name == "account_password":
            password = values.get("password", "")
            confirm_password = values.get("confirm_password", "")
            if len(password) < 6 or len(password) > 32:
                return {"error": "password reset skipped: password must be 6-32 characters"}
            if password != confirm_password:
                return {"error": "password reset skipped: passwords do not match"}
            return {
                "label": f"account password {username}",
                "command": ["account", "password", username, "--password-env"],
                "env": {"VMANGOS_PASSWORD": password},
                "refresh_after": True,
                "view": "accounts",
            }

        if action_name == "account_setgm":
            gm_level = values.get("gm_level", "")
            if not GM_LEVEL_PATTERN.fullmatch(gm_level):
                return {"error": "set GM skipped: GM level must be 0, 1, 2, or 3"}
            return {
                "label": f"account setgm {username}",
                "command": ["account", "setgm", username, gm_level],
                "env": {},
                "refresh_after": True,
                "view": "accounts",
            }

        if action_name == "account_ban":
            duration = values.get("duration", "")
            reason = values.get("reason", "")
            if not DURATION_PATTERN.fullmatch(duration):
                return {"error": "account ban skipped: duration must use forms like 30m, 12h, or 7d"}
            if not BAN_REASON_PATTERN.fullmatch(reason):
                return {"error": "account ban skipped: reason must use letters, numbers, and spaces only"}
            return {
                "label": f"account ban {username}",
                "command": ["account", "ban", username, duration, "--reason", reason],
                "env": {},
                "refresh_after": True,
                "view": "accounts",
            }

        if action_name == "account_unban":
            return {
                "label": f"account unban {username}",
                "command": ["account", "unban", username],
                "env": {},
                "refresh_after": True,
                "view": "accounts",
            }

    if action_name.startswith("backup_"):
        backup = find_selected_backup(snapshot, selected_backup_file)
        backup_summary = snapshot.get("backups", {}).get("summary", {})
        backup_dir = str(backup_summary.get("backup_dir", "")).strip()

        if action_name == "backup_restore_dry_run":
            if backup is None or not backup_dir:
                return {"error": "backup restore skipped: no backup selected"}
            backup_file = str(backup.get("file", "")).strip()
            if not backup_file:
                return {"error": "backup restore skipped: selected backup has no file name"}
            backup_path = f"{backup_dir.rstrip('/')}/{backup_file}"
            return {
                "label": f"backup restore dry-run {backup_file}",
                "command": ["backup", "restore", backup_path, "--dry-run"],
                "env": {},
                "refresh_after": False,
                "view": "backups",
            }

        if action_name == "backup_schedule_daily":
            daily_time = values.get("time", "")
            if not DAILY_TIME_PATTERN.fullmatch(daily_time):
                return {"error": "backup schedule skipped: daily time must use HH:MM in 24-hour format"}
            return {
                "label": f"backup schedule daily {daily_time}",
                "command": ["backup", "schedule", "--daily", daily_time],
                "env": {},
                "refresh_after": True,
                "view": "backups",
            }

        if action_name == "backup_schedule_weekly":
            weekly_schedule = values.get("schedule", "")
            if not WEEKLY_SCHEDULE_PATTERN.fullmatch(weekly_schedule):
                return {"error": "backup schedule skipped: weekly value must use 'Mon 04:00' style format"}
            return {
                "label": f"backup schedule weekly {weekly_schedule}",
                "command": ["backup", "schedule", "--weekly", weekly_schedule],
                "env": {},
                "refresh_after": True,
                "view": "backups",
            }

    if action_name in ("schedule_honor_create", "schedule_restart_create"):
        schedule_type = values.get("schedule_type", "").lower()
        time_value = values.get("time", "")
        day = values.get("day", "")
        timezone_value = values.get("timezone", "")

        if not SCHEDULE_TYPE_PATTERN.fullmatch(schedule_type):
            return {"error": "schedule create skipped: type must be daily or weekly"}
        if not DAILY_TIME_PATTERN.fullmatch(time_value):
            return {"error": "schedule create skipped: time must use HH:MM in 24-hour format"}
        if schedule_type == "weekly" and not DAY_NAME_PATTERN.fullmatch(day):
            return {"error": "schedule create skipped: weekly schedules require a day like Sun"}
        if timezone_value and not re.fullmatch(r"^[A-Za-z0-9_+./-]+$", timezone_value):
            return {"error": "schedule create skipped: timezone contains unsupported characters"}

        subcommand = "honor" if action_name == "schedule_honor_create" else "restart"
        command = ["schedule", subcommand, "--time", time_value]
        if schedule_type == "weekly":
            command.extend(["--weekly", day])
        else:
            command.append("--daily")
        if timezone_value:
            command.extend(["--timezone", timezone_value])

        if action_name == "schedule_restart_create":
            warnings = values.get("warnings", "")
            announce = values.get("announce", "")
            if warnings and not WARNINGS_PATTERN.fullmatch(warnings):
                return {"error": "schedule create skipped: warnings must use comma-separated minutes like 30,15,5,1"}
            if warnings:
                command.extend(["--warnings", warnings])
            if announce:
                command.extend(["--announce", announce])

        cadence = f"{schedule_type} {day} {time_value}".strip()
        label = f"schedule {'maintenance' if action_name == 'schedule_honor_create' else 'restart'} {cadence}"
        return {
            "label": label,
            "command": command,
            "env": {},
            "refresh_after": True,
            "view": "operations",
        }

    if action_name == "schedule_cancel":
        schedule = find_selected_schedule(snapshot, selected_schedule_id)
        if schedule is None:
            return {"error": "schedule cancel skipped: no job selected"}
        schedule_id = str(schedule.get("id", "")).strip()
        if not schedule_id:
            return {"error": "schedule cancel skipped: selected schedule has no id"}
        return {
            "label": f"schedule cancel {schedule_id}",
            "command": ["schedule", "cancel", schedule_id],
            "env": {},
            "refresh_after": True,
            "view": "operations",
        }

    return {"error": f"unsupported dashboard action: {action_name}"}


def summarize_backups(entries: list[dict[str, Any]], backup_dir: str) -> dict[str, Any]:
    summary: dict[str, Any] = {
        "count": len(entries),
        "backup_dir": backup_dir,
        "latest_file": "",
        "latest_path": "",
        "latest_timestamp": "",
        "latest_size_bytes": 0,
        "latest_created_by": "",
        "database_count": 0,
    }

    if not entries:
        return summary

    latest = max(entries, key=lambda item: str(item.get("timestamp", "")))
    latest_file = str(latest.get("file", ""))
    summary.update(
        {
            "latest_file": latest_file,
            "latest_path": f"{backup_dir.rstrip('/')}/{latest_file}" if backup_dir and latest_file else latest_file,
            "latest_timestamp": latest.get("timestamp", ""),
            "latest_size_bytes": clamp_int(latest.get("size_bytes", 0)),
            "latest_created_by": latest.get("created_by", ""),
            "database_count": len(latest.get("databases", [])),
        }
    )
    return summary


def empty_snapshot(error_message: str) -> dict[str, Any]:
    return {
        "captured_at": now_iso(),
        "config_path": "",
        "server": {"ok": False, "data": {}, "error": error_message},
        "logs": {"ok": False, "data": {}, "error": error_message},
        "schedule_list": {"ok": False, "data": {}, "error": error_message},
        "update_check": {"ok": False, "data": {}, "error": error_message},
        "update_inspect": {"ok": False, "data": {}, "error": error_message},
        "accounts_online": {"ok": False, "data": {}, "error": error_message},
        "accounts": {"ok": False, "data": {}, "error": error_message},
        "backup_list": {"ok": False, "data": [], "error": error_message},
        "backup_schedule_status": {"ok": False, "data": {}, "error": error_message},
        "config_validate": {"ok": False, "data": {}, "error": error_message},
        "config_show": {"ok": False, "data": {}, "error": error_message},
        "config_summary": {},
        "config_content": "",
        "backups": {"entries": [], "summary": {}},
        "players": [],
        "all_accounts": [],
        "schedules": [],
    }


def load_snapshot_fixture(snapshot_file: str) -> dict[str, Any]:
    with open(snapshot_file, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise ValueError("snapshot fixture must be a JSON object")
    return payload


def extract_seed_metric_history(snapshot: dict[str, Any]) -> list[dict[str, Any]]:
    raw_history = snapshot.get("metric_history", [])
    if not isinstance(raw_history, list):
        return []

    history: list[dict[str, Any]] = []
    for entry in raw_history:
        if not isinstance(entry, dict):
            continue
        history.append(
            {
                "captured_at": str(entry.get("captured_at", "") or ""),
                "cpu": parse_optional_float(entry.get("cpu")),
                "memory": parse_optional_float(entry.get("memory")),
                "load": parse_optional_float(entry.get("load")),
                "disk": parse_optional_float(entry.get("disk")),
                "players": parse_optional_float(entry.get("players")),
                "io": parse_optional_float(entry.get("io")),
            }
        )
    return history[-TREND_HISTORY_LIMIT:]


def build_snapshot(manager_bin: str, config_path: str) -> dict[str, Any]:
    server = run_manager_command(
        manager_bin,
        config_path,
        ["server", "status"],
        parser_mode="envelope",
        use_global_json=True,
    )
    logs = run_manager_command(
        manager_bin,
        config_path,
        ["logs", "status"],
        parser_mode="envelope",
        use_global_json=True,
    )
    online_accounts = run_manager_command(
        manager_bin,
        config_path,
        ["account", "list", "--online"],
        parser_mode="envelope",
        use_global_json=True,
    )
    accounts = run_manager_command(
        manager_bin,
        config_path,
        ["account", "list"],
        parser_mode="envelope",
        use_global_json=True,
    )
    schedules = run_manager_command(
        manager_bin,
        config_path,
        ["schedule", "list"],
        parser_mode="envelope",
        use_global_json=True,
    )
    update_check = run_manager_command(
        manager_bin,
        config_path,
        ["update", "check"],
        parser_mode="envelope",
        use_global_json=True,
    )
    update_inspect = run_manager_command(
        manager_bin,
        config_path,
        ["update", "inspect"],
        parser_mode="envelope",
        use_global_json=True,
    )
    backups = run_manager_command(
        manager_bin,
        config_path,
        ["backup", "list", "--format", "json"],
        parser_mode="json",
        use_global_json=False,
    )
    backup_schedule_status = run_manager_command(
        manager_bin,
        config_path,
        ["backup", "schedule", "status", "--format", "json"],
        parser_mode="envelope",
        use_global_json=False,
    )
    config_validate = run_manager_command(
        manager_bin,
        config_path,
        ["config", "validate", "--format", "json"],
        parser_mode="envelope",
        use_global_json=False,
    )
    config_show = run_manager_command(
        manager_bin,
        config_path,
        ["config", "show", "--format", "json"],
        parser_mode="envelope",
        use_global_json=False,
    )

    config_content = ""
    if config_show["ok"]:
        config_content = str(config_show["data"].get("content", ""))

    config_values = parse_ini_content(config_content)
    backup_entries = backups["data"] if backups["ok"] and isinstance(backups["data"], list) else []
    players = online_accounts["data"].get("accounts", []) if online_accounts["ok"] else []
    all_accounts = accounts["data"].get("accounts", []) if accounts["ok"] else []
    schedule_entries = schedules["data"].get("schedules", []) if schedules["ok"] else []
    backup_dir = config_values.get("backup.backup_dir", "")
    password_file = str(config_values.get("database.password_file", "") or "")
    inline_password = str(config_values.get("database.password", "") or "")
    backup_summary = summarize_backups(backup_entries, backup_dir)

    config_summary = {
        "install_root": config_values.get("server.install_root", ""),
        "auth_service": config_values.get("server.auth_service", ""),
        "world_service": config_values.get("server.world_service", ""),
        "db_host": config_values.get("database.host", ""),
        "db_user": config_values.get("database.user", ""),
        "auth_db": config_values.get("database.auth_db", ""),
        "characters_db": config_values.get("database.characters_db", ""),
        "world_db": config_values.get("database.world_db", ""),
        "logs_db": config_values.get("database.logs_db", ""),
        "backup_dir": backup_dir,
        "db_secret_source": "password_file" if password_file else ("inline" if inline_password else "unset"),
    }

    return {
        "captured_at": now_iso(),
        "config_path": config_path,
        "server": server,
        "logs": logs,
        "schedule_list": schedules,
        "update_check": update_check,
        "update_inspect": update_inspect,
        "accounts_online": online_accounts,
        "accounts": accounts,
        "backup_list": backups,
        "backup_schedule_status": backup_schedule_status,
        "config_validate": config_validate,
        "config_show": config_show,
        "config_summary": config_summary,
        "config_content": config_content,
        "backups": {
            "entries": backup_entries,
            "summary": backup_summary,
        },
        "players": players,
        "all_accounts": all_accounts,
        "schedules": schedule_entries,
    }


def render_action_banner(
    active_view: str,
    snapshot: dict[str, Any],
    last_action: str,
    action_tone: str,
    refresh_interval: int,
) -> str:
    tone_label, tone_color = ACTION_STYLES.get(action_tone, ACTION_STYLES["info"])
    captured_at = iso_to_display(snapshot.get("captured_at"))
    message = escape_markup(truncate_text(last_action or "dashboard started", 140))
    view_title = VIEW_TITLES.get(active_view, active_view.title())
    view_summary = VIEW_SUMMARIES.get(active_view, "Operate the realm from one console.")
    return "\n".join(
        [
            f"[bold {ACCENT_GOLD}]VMaNGOS Manager[/]  [{ACCENT_MUTED}]realm console[/]  [bold {ACCENT_SKY}]{view_title}[/]  [{ACCENT_MUTED}]refresh[/] {refresh_interval}s",
            f"[{ACCENT_MUTED}]last refresh[/] {captured_at}  [{ACCENT_MUTED}]status[/] [bold {tone_color}]{tone_label}[/]",
            "",
            f"[bold {ACCENT_SKY}]This View[/] {escape_markup(view_summary)}",
            f"[{ACCENT_MUTED}]Last action[/] {message}",
        ]
    )


def render_sidebar(active_view: str, last_action: str, snapshot: dict[str, Any], refresh_interval: int) -> str:
    sections = [
        ("overview", "1", "Overview"),
        ("monitor", "2", "Monitor"),
        ("accounts", "3", "Accounts"),
        ("backups", "4", "Backups"),
        ("config", "5", "Config"),
        ("operations", "6", "Ops"),
    ]

    server = snapshot.get("server", {})
    server_data = server.get("data", {}) if server.get("ok") else {}
    services = server_data.get("services", {})
    auth = services.get("auth", {})
    world = services.get("world", {})
    backups = snapshot.get("backups", {}).get("summary", {})
    players_online = len(snapshot.get("players", []))

    lines = [
        f"[bold {ACCENT_GOLD}]VMaNGOS Manager[/]",
        f"[{ACCENT_MUTED}]Realm operator console[/]",
        "",
        f"[bold {ACCENT_SKY}]Modules[/]",
    ]
    for name, key, label in sections:
        if name == active_view:
            lines.append(f"[bold {ACCENT_TEAL}]▶[/] [bold {ACCENT_GOLD}]{key}[/] [bold {ACCENT_TEAL}]{label}[/]")
        else:
            lines.append(f"[{ACCENT_MUTED}]  [/] [bold {ACCENT_GOLD}]{key}[/] [{ACCENT_MUTED}]{label}[/]")

    lines.extend(
        [
            "",
            f"[bold {ACCENT_SKY}]Realm Pulse[/]",
            f"[{ACCENT_MUTED}]Updated[/]  {iso_to_clock(snapshot.get('captured_at'))}",
            f"[{ACCENT_MUTED}]Refresh[/]  {refresh_interval}s",
            f"[{ACCENT_MUTED}]Players[/]  {players_online} online",
            f"[{ACCENT_MUTED}]Backups[/]  {backups.get('count', 0)} known",
            f"[{ACCENT_MUTED}]Auth[/]     {format_state(auth.get('health', auth.get('state', 'unavailable')))}",
            f"[{ACCENT_MUTED}]World[/]    {format_state(world.get('health', world.get('state', 'unavailable')))}",
        ]
    )
    return "\n".join(lines)


def render_service_panel(snapshot: dict[str, Any], active_view: str) -> str:
    server = snapshot["server"]
    if not server["ok"]:
        return "\n".join(
            [
                f"[bold {ACCENT_GOLD}]Realm Services[/]",
                "",
                f"[bold {ACCENT_ROSE}]Server snapshot failed:[/] {format_error_text(server['error'])}",
                "",
                f"[{ACCENT_MUTED}]Current view:[/] {active_view}",
            ]
        )

    data = server["data"]
    auth = data.get("services", {}).get("auth", {})
    world = data.get("services", {}).get("world", {})
    checks = data.get("checks", {})
    db = checks.get("database_connectivity", {})
    auth_restarts = clamp_int(auth.get("restart_count_1h", 0))
    world_restarts = clamp_int(world.get("restart_count_1h", 0))

    return "\n".join(
        [
            f"[bold {ACCENT_GOLD}]Realm Services[/]",
            f"[{ACCENT_MUTED}]Auth, world, and database readiness at a glance.[/]",
            "",
            f"[bold {ACCENT_SKY}]Auth[/]   {format_state(auth.get('health', auth.get('state')))}  [{ACCENT_MUTED}]pid[/] {auth.get('pid', 0)}  [{ACCENT_MUTED}]up[/] {auth.get('uptime_human', 'N/A')}",
            f"[{ACCENT_MUTED}]       cpu[/] {auth.get('cpu_percent', 0)}%  [{ACCENT_MUTED}]mem[/] {auth.get('memory_mb', 0)} MB  [{ACCENT_MUTED}]restarts/1h[/] {auth_restarts}",
            "",
            f"[bold {ACCENT_SKY}]World[/]  {format_state(world.get('health', world.get('state')))}  [{ACCENT_MUTED}]pid[/] {world.get('pid', 0)}  [{ACCENT_MUTED}]up[/] {world.get('uptime_human', 'N/A')}",
            f"[{ACCENT_MUTED}]       cpu[/] {world.get('cpu_percent', 0)}%  [{ACCENT_MUTED}]mem[/] {world.get('memory_mb', 0)} MB  [{ACCENT_MUTED}]restarts/1h[/] {world_restarts}",
            "",
            f"[bold {ACCENT_SKY}]DB[/]     {format_state('ok' if db.get('ok') else db.get('message', 'unreachable'))}  [{ACCENT_MUTED}]check[/] {escape_markup(db.get('message', 'n/a'))}",
        ]
    )


def render_metrics_panel(
    snapshot: dict[str, Any],
    metric_history: list[dict[str, Any]] | None = None,
    refresh_interval: int = 2,
) -> str:
    server = snapshot["server"]
    metric_history = metric_history or []
    lines = [
        f"[bold {ACCENT_GOLD}]Host Metrics[/]",
        f"[{ACCENT_MUTED}]Host pressure, capacity, and trend.[/]",
        f"[{ACCENT_MUTED}]Window[/] {history_window_label(metric_history, refresh_interval)}",
        "",
    ]

    if server["ok"]:
        data = server["data"]
        host = data.get("host", {})
        cpu = host.get("cpu", {})
        memory = host.get("memory", {})
        load = host.get("load", {})
        disk = data.get("checks", {}).get("disk_space", {})
        storage_io = data.get("storage_io", {})
        cpu_history = history_values(metric_history, "cpu")
        memory_history = history_values(metric_history, "memory")
        load_history = history_values(metric_history, "load")
        disk_history = history_values(metric_history, "disk")
        io_history = history_values(metric_history, "io")
        metric_rows = [
            (
                "CPU",
                f"{cpu.get('usage_percent', 0)}% / {cpu.get('cores', 'n/a')}c{compact_metric_state(cpu.get('status', 'unavailable'))}",
                cpu_history,
            ),
            (
                "Memory",
                f"{memory.get('used_percent', 0)}% / {format_gb_from_kb(memory.get('used_kb', 0)).replace(' GB', 'G')}/{format_gb_from_kb(memory.get('total_kb', 0)).replace(' GB', 'G')}{compact_metric_state(memory.get('status', 'unavailable'))}",
                memory_history,
            ),
            (
                "Load",
                f"1m {load.get('load_1', 0)} / 5m {load.get('load_5', 0)}{compact_metric_state(load.get('status', 'unavailable'))}",
                load_history,
            ),
            (
                "Disk",
                f"{disk.get('used_percent', 0)}% / {format_gb_from_kb(disk.get('available_kb', 0)).replace(' GB', 'G')} free{compact_metric_state(disk.get('status', 'unavailable'))}",
                disk_history,
            ),
        ]
        for label, summary, history_values_for_metric in metric_rows:
            label_segment = f"[bold {ACCENT_SKY}]{label:<6}[/]"
            summary_segment = pad_markup(
                summary,
                24,
            )
            lines.append(
                f"{label_segment} {summary_segment}  [{ACCENT_TEAL}]{render_sparkline(history_values_for_metric, width=8)}[/]"
            )
        if storage_io.get("available"):
            io_summary = pad_markup(
                f"{storage_io.get('util_percent', 0)}% / {storage_io.get('read_ops_per_sec', 0)}:{storage_io.get('write_ops_per_sec', 0)} rw{compact_metric_state(storage_io.get('status', 'unavailable'))}",
                24,
            )
            lines.append(
                f"[bold {ACCENT_SKY}]{'I/O':<6}[/] {io_summary}  [{ACCENT_TEAL}]{render_sparkline(io_history, width=8)}[/]"
            )
        else:
            lines.append(
                f"[bold {ACCENT_SKY}]I/O[/]      {format_state(storage_io.get('status', 'unavailable'))}  [{ACCENT_MUTED}]install sysstat/iostat for live disk history[/]"
            )
    else:
        lines.append(f"[bold {ACCENT_ROSE}]Server metrics unavailable:[/] {format_error_text(server['error'])}")

    return "\n".join(lines)


def render_monitor_pressure(
    snapshot: dict[str, Any],
    metric_history: list[dict[str, Any]] | None = None,
    refresh_interval: int = 2,
) -> str:
    server = snapshot["server"]
    metric_history = metric_history or []
    lines = [
        f"[bold {ACCENT_GOLD}]Pressure Deck[/]",
        f"[{ACCENT_MUTED}]Deeper host diagnostics for CPU, memory, load, disk, and I/O.[/]",
        f"[{ACCENT_MUTED}]Window[/] {history_window_label(metric_history, refresh_interval)}",
        "",
    ]

    if not server["ok"]:
        lines.append(f"[bold {ACCENT_ROSE}]Monitor snapshot unavailable:[/] {format_error_text(server['error'])}")
        return "\n".join(lines)

    data = server["data"]
    host = data.get("host", {})
    cpu = host.get("cpu", {})
    memory = host.get("memory", {})
    load = host.get("load", {})
    disk = data.get("checks", {}).get("disk_space", {})
    storage_io = data.get("storage_io", {})
    cpu_history = history_values(metric_history, "cpu")
    memory_history = history_values(metric_history, "memory")
    load_history = history_values(metric_history, "load")
    disk_history = history_values(metric_history, "disk")
    io_history = history_values(metric_history, "io")

    metric_rows = [
        (
            "CPU",
            f"{cpu.get('usage_percent', 0)}% / {cpu.get('cores', 'n/a')} cores{compact_metric_state(cpu.get('status', 'unavailable'))}",
            cpu_history,
            "cpu",
        ),
        (
            "Memory",
            f"{memory.get('used_percent', 0)}% / {format_gb_from_kb(memory.get('used_kb', 0))} of {format_gb_from_kb(memory.get('total_kb', 0))}{compact_metric_state(memory.get('status', 'unavailable'))}",
            memory_history,
            "memory",
        ),
        (
            "Load",
            f"1m {load.get('load_1', 0)}  5m {load.get('load_5', 0)}  15m {load.get('load_15', 0)}{compact_metric_state(load.get('status', 'unavailable'))}",
            load_history,
            "load",
        ),
        (
            "Disk",
            f"{disk.get('used_percent', 0)}% used / {format_gb_from_kb(disk.get('available_kb', 0))} free{compact_metric_state(disk.get('status', 'unavailable'))}",
            disk_history,
            "disk",
        ),
    ]

    for label, summary, values, metric_key in metric_rows:
        lines.append(
            f"[bold {ACCENT_SKY}]{label:<6}[/] {escape_markup(summary)}  [{ACCENT_MUTED}]{describe_trend(values, metric_key)}[/]  [{ACCENT_TEAL}]{render_sparkline(values, width=10)}[/]"
        )

    if storage_io.get("available"):
        io_summary = (
            f"{storage_io.get('util_percent', 0)}% util / {storage_io.get('read_ops_per_sec', 0)}:{storage_io.get('write_ops_per_sec', 0)} ops"
            f"{compact_metric_state(storage_io.get('status', 'unavailable'))}"
        )
        lines.append(
            f"[bold {ACCENT_SKY}]I/O   [/] {escape_markup(io_summary)}  [{ACCENT_MUTED}]{describe_trend(io_history, 'io')}[/]  [{ACCENT_TEAL}]{render_sparkline(io_history, width=10)}[/]"
        )
    else:
        lines.append(f"[bold {ACCENT_SKY}]I/O   [/] {format_state(storage_io.get('status', 'unavailable'))}")
        lines.append(f"[{ACCENT_MUTED}]install [bold {ACCENT_GOLD}]sysstat/iostat[/] for live disk saturation history.")

    return "\n".join(lines)


def render_monitor_processes(snapshot: dict[str, Any]) -> str:
    server = snapshot["server"]
    lines = [
        f"[bold {ACCENT_GOLD}]Realm Process Footprint[/]",
        f"[{ACCENT_MUTED}]Auth/world runtime detail plus DB readiness for diagnosis.[/]",
        "",
    ]

    if not server["ok"]:
        lines.append(f"[bold {ACCENT_ROSE}]Process data unavailable:[/] {format_error_text(server['error'])}")
        return "\n".join(lines)

    data = server["data"]
    services = data.get("services", {})
    db = data.get("checks", {}).get("database_connectivity", {})

    for service_name in ("auth", "world"):
        service = services.get(service_name, {})
        label = service_name.title()
        lines.extend(
            [
                f"[bold {ACCENT_SKY}]{label}[/]  {format_state(service.get('health', service.get('state', 'unavailable')))}  [{ACCENT_MUTED}]pid[/] {service.get('pid', 0)}  [{ACCENT_MUTED}]up[/] {service.get('uptime_human', 'n/a')}",
                f"[{ACCENT_MUTED}]cpu[/] {service.get('cpu_percent', 0)}%  [{ACCENT_MUTED}]mem[/] {service.get('memory_mb', 0)} MB  [{ACCENT_MUTED}]restarts/1h[/] {clamp_int(service.get('restart_count_1h', 0))}  [{ACCENT_MUTED}]crash loop[/] {format_flag(service.get('crash_loop_detected'), true_text='yes', false_text='no', true_color=ACCENT_ROSE)}",
            ]
        )

    lines.extend(
        [
            "",
            f"[bold {ACCENT_SKY}]DB[/]    {format_state('ok' if db.get('ok') else db.get('message', 'unreachable'))}",
            f"[{ACCENT_MUTED}]      check[/] {escape_markup(db.get('message', 'n/a'))}",
        ]
    )
    return "\n".join(lines)


def render_monitor_trends(
    snapshot: dict[str, Any],
    metric_history: list[dict[str, Any]] | None = None,
    refresh_interval: int = 2,
) -> str:
    server = snapshot["server"]
    metric_history = metric_history or []
    lines = [
        f"[bold {ACCENT_GOLD}]Trend Ledger[/]",
        f"[{ACCENT_MUTED}]Compare current value, peak window, and direction at a glance.[/]",
        f"[{ACCENT_MUTED}]Window[/] {history_window_label(metric_history, refresh_interval)}",
        "",
    ]

    if not server["ok"]:
        lines.append(f"[bold {ACCENT_ROSE}]Trend data unavailable:[/] {format_error_text(server['error'])}")
        return "\n".join(lines)

    data = server["data"]
    host = data.get("host", {})
    disk = data.get("checks", {}).get("disk_space", {})
    storage_io = data.get("storage_io", {})
    rows = [
        ("CPU", clamp_float(host.get("cpu", {}).get("usage_percent")), history_values(metric_history, "cpu"), "%"),
        ("Memory", clamp_float(host.get("memory", {}).get("used_percent")), history_values(metric_history, "memory"), "%"),
        ("Load", clamp_float(host.get("load", {}).get("load_1")), history_values(metric_history, "load"), ""),
        ("Disk", clamp_float(disk.get("used_percent")), history_values(metric_history, "disk"), "%"),
    ]

    for label, current_value, values, suffix in rows:
        available = [value for value in values if value is not None]
        peak_text = f"{max(available):.1f}{suffix}" if available else "n/a"
        lines.append(
            f"[bold {ACCENT_SKY}]{label:<6}[/] [{ACCENT_MUTED}]now[/] {current_value:.1f}{suffix}  [{ACCENT_MUTED}]peak[/] {peak_text}  [{ACCENT_MUTED}]trend[/] {describe_trend(values, label.lower())}"
        )

    io_history = history_values(metric_history, "io")
    if storage_io.get("available"):
        available_io = [value for value in io_history if value is not None]
        peak_io = f"{max(available_io):.1f}%" if available_io else "n/a"
        lines.append(
            f"[bold {ACCENT_SKY}]I/O   [/] [{ACCENT_MUTED}]now[/] {clamp_float(storage_io.get('util_percent')):.1f}%  [{ACCENT_MUTED}]peak[/] {peak_io}  [{ACCENT_MUTED}]trend[/] {describe_trend(io_history, 'io')}"
        )
    else:
        lines.append(f"[bold {ACCENT_SKY}]I/O   [/] [{ACCENT_MUTED}]now[/] unavailable  [{ACCENT_MUTED}]peak[/] n/a  [{ACCENT_MUTED}]trend[/] warming")

    return "\n".join(lines)


def render_monitor_storage(snapshot: dict[str, Any]) -> str:
    server = snapshot["server"]
    lines = [
        f"[bold {ACCENT_GOLD}]Storage and Device[/]",
        f"[{ACCENT_MUTED}]Filesystem headroom and disk saturation detail.[/]",
        "",
    ]

    if not server["ok"]:
        lines.append(f"[bold {ACCENT_ROSE}]Storage data unavailable:[/] {format_error_text(server['error'])}")
        return "\n".join(lines)

    data = server["data"]
    disk = data.get("checks", {}).get("disk_space", {})
    storage_io = data.get("storage_io", {})
    lines.extend(
        [
            f"[{ACCENT_MUTED}]Path[/]        {escape_markup(disk.get('path', 'n/a'))}",
            f"[{ACCENT_MUTED}]FS[/]          {escape_markup(disk.get('filesystem', 'n/a'))}  [{ACCENT_MUTED}]used[/] {disk.get('used_percent', 0)}%  [{ACCENT_MUTED}]free[/] {format_gb_from_kb(disk.get('available_kb', 0))}",
            f"[{ACCENT_MUTED}]Status[/]      {format_state(disk.get('status', 'unavailable'))}",
            "",
        ]
    )

    if storage_io.get("available"):
        lines.extend(
            [
                f"[{ACCENT_MUTED}]Device[/]      {escape_markup(storage_io.get('device', 'n/a'))}  [{ACCENT_MUTED}]source[/] {escape_markup(storage_io.get('source', 'n/a'))}",
                f"[{ACCENT_MUTED}]Ops/s[/]       read {storage_io.get('read_ops_per_sec', 0)}  write {storage_io.get('write_ops_per_sec', 0)}",
                f"[{ACCENT_MUTED}]KB/s[/]        read {storage_io.get('read_kbps', 0)}  write {storage_io.get('write_kbps', 0)}",
                f"[{ACCENT_MUTED}]Await[/]       {storage_io.get('await_ms', 0)} ms  [{ACCENT_MUTED}]util[/] {storage_io.get('util_percent', 0)}%",
                f"[{ACCENT_MUTED}]I/O[/]         {format_state(storage_io.get('status', 'unavailable'))}",
            ]
        )
    else:
        lines.extend(
            [
                f"[{ACCENT_MUTED}]Device[/]      n/a",
                f"[{ACCENT_MUTED}]I/O[/]         {format_state(storage_io.get('status', 'unavailable'))}",
                f"[{ACCENT_MUTED}]Note[/]        install [bold {ACCENT_GOLD}]sysstat/iostat[/] to expose live read/write rates and disk wait.",
            ]
        )

    return "\n".join(lines)


def render_player_details(player: dict[str, Any] | None, online_count: int) -> str:
    if not player:
        return "\n".join(
            [
                f"[bold {ACCENT_GOLD}]Selected Player[/]",
                "",
                f"[{ACCENT_MUTED}]Selection[/]    choose a player row to inspect that account.",
                "",
                f"[{ACCENT_MUTED}]Next step[/]    open [bold {ACCENT_GOLD}]Accounts[/] when you need to manage that user.",
            ]
        )

    return "\n".join(
        [
            f"[bold {ACCENT_GOLD}]Selected Player[/]",
            "",
            f"[{ACCENT_MUTED}]Selected[/]     [bold {ACCENT_TEAL}]{escape_markup(player.get('username', '-'))}[/]",
            f"[{ACCENT_MUTED}]Account ID[/]   [bold {ACCENT_SKY}]{player.get('id', 0)}[/]",
            f"[{ACCENT_MUTED}]GM Level[/]     {player.get('gm_level', 0)}",
            f"[{ACCENT_MUTED}]Online[/]       {format_flag(player.get('online'))}",
            f"[{ACCENT_MUTED}]Banned[/]       {format_flag(player.get('banned'), true_color=ACCENT_ROSE)}",
            "",
            f"[{ACCENT_MUTED}]Next step[/]    open [bold {ACCENT_GOLD}]Accounts[/] for password, GM, ban, and unban actions.",
        ]
    )


def render_player_pulse(
    snapshot: dict[str, Any],
    metric_history: list[dict[str, Any]] | None = None,
    refresh_interval: int = 2,
) -> str:
    metric_history = metric_history or []
    server = snapshot.get("server", {})
    server_data = server.get("data", {}) if server.get("ok") else {}
    player_state = server_data.get("players", {})
    players = snapshot.get("players", [])
    online_now = clamp_int(player_state.get("online", len(players)))
    player_history = history_values(metric_history, "players")
    peak_window = int(max(player_history)) if player_history else online_now
    gm_players = [player for player in players if clamp_int(player.get("gm_level", 0)) > 0]
    gm_names = [str(player.get("username", "")).strip() for player in gm_players if str(player.get("username", "")).strip()]
    gm_summary = ", ".join(gm_names[:3]) if gm_names else "none"
    if len(gm_names) > 3:
        gm_summary = f"{gm_summary} +{len(gm_names) - 3}"
    staff_count = len(gm_players)
    player_count = max(online_now - staff_count, 0)
    if staff_count > 0:
        coverage = max(int(round(online_now / staff_count)), 1)
        coverage_text = f"1 GM / {coverage} online"
    else:
        coverage_text = "no staff online"

    return "\n".join(
        [
            f"[bold {ACCENT_GOLD}]Player Pulse[/]",
            f"[{ACCENT_MUTED}]Realm population, trend, and operator-presence summary.[/]",
            "",
            f"[{ACCENT_MUTED}]Online Now[/]   [bold {ACCENT_GOLD}]{online_now}[/]  [{ACCENT_MUTED}]trend[/] {describe_trend(player_history, 'players')}",
            f"[{ACCENT_MUTED}]Peak Window[/] {peak_window}  [{ACCENT_MUTED}]window[/] {history_window_label(metric_history, refresh_interval)}",
            f"[{ACCENT_MUTED}]Count Source[/] {escape_markup(player_state.get('source', 'unavailable'))}",
            f"[{ACCENT_MUTED}]Mix[/]          players={player_count}  staff={staff_count}",
            f"[{ACCENT_MUTED}]GM Coverage[/]  {escape_markup(coverage_text)}",
            f"[{ACCENT_MUTED}]GMs Online[/]   {staff_count}  [{ACCENT_MUTED}]names[/] {escape_markup(truncate_text(gm_summary, 36))}",
            "",
            f"[{ACCENT_MUTED}]Drilldown[/]   [bold {ACCENT_GOLD}]o[/] online roster  [bold {ACCENT_GOLD}]2[/] accounts",
        ]
    )


def render_account_details(account: dict[str, Any] | None, total_accounts: int) -> str:
    if not account:
        return "\n".join(
            [
                f"[bold {ACCENT_GOLD}]Selected Account[/]",
                f"[{ACCENT_MUTED}]Focused account state and account-scoped actions.[/]",
                "",
                f"[{ACCENT_MUTED}]Inventory[/]     {total_accounts} account{'s' if total_accounts != 1 else ''} loaded",
                f"[{ACCENT_MUTED}]Selection[/]    choose a row to inspect or act on an account.",
                "",
                f"[{ACCENT_MUTED}]Actions[/]      create new accounts here, then select a row for account-level changes.",
            ]
        )

    return "\n".join(
        [
            f"[bold {ACCENT_GOLD}]Selected Account[/]",
            f"[{ACCENT_MUTED}]Focused account state and account-scoped actions.[/]",
            "",
            f"[{ACCENT_MUTED}]Inventory[/]     {total_accounts} account{'s' if total_accounts != 1 else ''} loaded",
            f"[{ACCENT_MUTED}]Selected[/]     [bold {ACCENT_TEAL}]{escape_markup(account.get('username', '-'))}[/]",
            f"[{ACCENT_MUTED}]Account ID[/]   [bold {ACCENT_SKY}]{account.get('id', 0)}[/]",
            f"[{ACCENT_MUTED}]GM Level[/]     {account.get('gm_level', 0)}",
            f"[{ACCENT_MUTED}]Online[/]       {format_flag(account.get('online'))}",
            f"[{ACCENT_MUTED}]Banned[/]       {format_flag(account.get('banned'), true_color=ACCENT_ROSE)}",
            "",
            f"[{ACCENT_MUTED}]Actions[/]      reset password, set GM, ban, or unban from this selection.",
        ]
    )


def render_alerts_panel(snapshot: dict[str, Any]) -> str:
    server = snapshot["server"]
    lines = [f"[bold {ACCENT_GOLD}]Alerts and Events[/]", f"[{ACCENT_MUTED}]Recent risk signals and maintenance events.[/]", ""]

    if not server["ok"]:
        lines.append(f"[bold {ACCENT_ROSE}]Alerts unavailable:[/] {server['error']}")
        return "\n".join(lines)

    data = server["data"]
    alerts = data.get("alerts", {})
    active_alerts = alerts.get("active", [])
    recent_events = alerts.get("recent_events", [])

    lines.append(f"[{ACCENT_MUTED}]Overall[/]      {format_state(alerts.get('status', 'healthy'))}  [{ACCENT_MUTED}]active[/] {len(active_alerts)}")
    lines.append(f"[bold {ACCENT_SKY}]Active Alerts[/]")

    if active_alerts:
        for alert in active_alerts[:3]:
            lines.append(
                f"{format_state(alert.get('severity', 'warning'))} {alert.get('source', 'unknown')}: {alert.get('message', '')}"
            )
    else:
        lines.append(f"[bold {STATUS_COLORS['healthy']}]No active alerts[/]")

    lines.append("")
    lines.append(f"[bold {ACCENT_SKY}]Recent Events[/]")
    if recent_events:
        for event in recent_events[:4]:
            lines.append(f"{truncate_text(event.get('timestamp', ''), 19)} {event.get('service', 'unknown')}: {truncate_text(event.get('message', ''), 48)}")
    else:
        lines.append("No recent events in the last 30 minutes.")

    return "\n".join(lines)


def render_backups_summary(snapshot: dict[str, Any], selected_backup: dict[str, Any] | None) -> str:
    backups = snapshot.get("backups", {})
    summary = backups.get("summary", {})
    backup_schedule_status = snapshot.get("backup_schedule_status", {})
    schedule_data = backup_schedule_status.get("data", {}) if backup_schedule_status.get("ok") else {}
    schedule_entries = schedule_data.get("schedules", []) if isinstance(schedule_data.get("schedules", []), list) else []
    configured_schedules = [entry for entry in schedule_entries if entry.get("present")]
    protection_state = "healthy" if summary.get("count", 0) and configured_schedules else ("warning" if summary.get("count", 0) else "critical")
    lines = [
        f"[bold {ACCENT_GOLD}]Backup Readiness[/]",
        "",
        f"[{ACCENT_MUTED}]Protection[/]  {format_state(protection_state)}",
        f"[{ACCENT_MUTED}]Count[/]       {summary.get('count', 0)}",
        f"[{ACCENT_MUTED}]Directory[/]   {summary.get('backup_dir', 'n/a') or 'n/a'}",
    ]

    latest_file = summary.get("latest_file", "")
    if latest_file:
        lines.extend(
            [
                f"[{ACCENT_MUTED}]Latest[/]      {escape_markup(latest_file)}",
                f"[{ACCENT_MUTED}]When[/]        {iso_to_display(summary.get('latest_timestamp'))}",
                f"[{ACCENT_MUTED}]Size[/]        {format_bytes(summary.get('latest_size_bytes', 0))}",
            ]
        )
    else:
        lines.append(f"[{ACCENT_MUTED}]Latest[/]      none")

    lines.extend(["", f"[bold {ACCENT_SKY}]Timer State[/]"])
    if backup_schedule_status.get("ok"):
        if configured_schedules:
            for entry in configured_schedules:
                schedule_name = str(entry.get("id", "backup")).title()
                schedule_health = "healthy" if entry.get("enabled") and entry.get("active") else "warning"
                lines.append(
                    f"[{ACCENT_MUTED}]{schedule_name}[/]       {format_state(schedule_health)}  {escape_markup(entry.get('configured', 'n/a'))}"
                )
                if entry.get("next_run"):
                    lines.append(f"[{ACCENT_MUTED}]             [/]{escape_markup(entry.get('next_run'))}")
        else:
            lines.append(f"[{ACCENT_MUTED}]No backup timers configured yet.[/]")
    else:
        lines.append(f"[bold {ACCENT_ROSE}]Schedule state unavailable:[/] {format_error_text(backup_schedule_status.get('error', 'unknown error'))}")

    if selected_backup:
        lines.extend(
            [
                "",
                f"[bold {ACCENT_SKY}]Selected Backup[/]",
                f"[{ACCENT_MUTED}]File[/]        {escape_markup(selected_backup.get('file', 'n/a'))}",
                f"[{ACCENT_MUTED}]When[/]        {iso_to_display(selected_backup.get('timestamp'))}",
                f"[{ACCENT_MUTED}]Size[/]        {format_bytes(selected_backup.get('size_bytes', 0))}",
                f"[{ACCENT_MUTED}]DBs[/]         {escape_markup(', '.join(selected_backup.get('databases', [])) or 'n/a')}",
                f"[{ACCENT_MUTED}]Created By[/]  {escape_markup(selected_backup.get('created_by', 'n/a'))}",
                "",
                f"[{ACCENT_MUTED}]Ready for[/]   verify or restore dry-run from this selection.",
            ]
        )
    else:
        lines.extend(
            [
                "",
                f"[{ACCENT_MUTED}]Selection[/]   choose a backup row to inspect, verify, or dry-run restore.",
            ]
        )

    return "\n".join(lines)


def render_config_panel(snapshot: dict[str, Any]) -> str:
    validate = snapshot["config_validate"]
    summary = snapshot.get("config_summary", {})
    config_path = str(snapshot.get("config_path", "") or "n/a")
    secret_source = str(summary.get("db_secret_source", "unset") or "unset")
    if secret_source == "password_file":
        secret_label = "external password file"
    elif secret_source == "inline":
        secret_label = "inline value masked"
    else:
        secret_label = "not configured"

    lines = [f"[bold {ACCENT_GOLD}]Configuration Wiring[/]", ""]
    if validate["ok"]:
        valid = validate["data"].get("valid", True)
        lines.append(f"Validation  {format_state('healthy' if valid else 'critical')}")
    else:
        lines.append(f"[bold {ACCENT_ROSE}]Validation failed:[/] {validate['error']}")

    lines.extend(
        [
            "",
            f"[{ACCENT_MUTED}]Config Path[/]   {escape_markup(config_path)}",
            "",
            f"[bold {ACCENT_SKY}]Realm Wiring[/]",
            f"[{ACCENT_MUTED}]Install Root[/]  {summary.get('install_root', 'n/a') or 'n/a'}",
            f"[{ACCENT_MUTED}]Auth Service[/]  {summary.get('auth_service', 'n/a') or 'n/a'}",
            f"[{ACCENT_MUTED}]World Service[/] {summary.get('world_service', 'n/a') or 'n/a'}",
            f"[{ACCENT_MUTED}]Backup Dir[/]    {summary.get('backup_dir', 'n/a') or 'n/a'}",
            "",
            f"[bold {ACCENT_SKY}]Database Wiring[/]",
            f"[{ACCENT_MUTED}]DB Host[/]       {summary.get('db_host', 'n/a') or 'n/a'}",
            f"[{ACCENT_MUTED}]DB User[/]       {summary.get('db_user', 'n/a') or 'n/a'}",
            f"[{ACCENT_MUTED}]DB Secret[/]     {escape_markup(secret_label)}",
            f"[{ACCENT_MUTED}]DB Names[/]      auth={summary.get('auth_db', 'n/a')} world={summary.get('world_db', 'n/a')} chars={summary.get('characters_db', 'n/a')} logs={summary.get('logs_db', 'n/a')}",
            "",
            f"[bold {ACCENT_SKY}]Dashboard Role[/]",
            f"[{ACCENT_MUTED}]Read-only[/]     validate and review wiring here; edit manager.conf and .dbpass in the shell.",
            f"[{ACCENT_MUTED}]CLI[/]           [bold {ACCENT_GOLD}]config detect[/], [bold {ACCENT_GOLD}]config validate[/], [bold {ACCENT_GOLD}]config show[/]",
            f"[{ACCENT_MUTED}]Action[/]        [bold {ACCENT_GOLD}]k[/] validate config",
        ]
    )
    return "\n".join(lines)


def short_commit(value: Any) -> str:
    text = str(value or "")
    return text[:8] if len(text) >= 8 else text or "n/a"


def format_update_assessment(value: Any) -> str:
    text = str(value or "unknown")
    label = text.replace("_", " ")
    if text == "schema_migrations_pending":
        return f"[bold {ACCENT_GOLD}]{label}[/]"
    if text == "manual_review_required":
        return f"[bold {ACCENT_ROSE}]{label}[/]"
    if text == "no_changes":
        return f"[bold {ACCENT_GREEN}]no changes[/]"
    return f"[bold {ACCENT_MUTED}]{label}[/]"


def maintenance_window_state(logs_data: dict[str, Any]) -> str:
    config = logs_data.get("config", {})
    log_counts = logs_data.get("logs", {})
    disk = logs_data.get("disk", {})

    if not logs_data:
        return "unavailable"
    if not config.get("present") or not config.get("in_sync"):
        return "warning"
    if not log_counts.get("sensitive_permissions_ok", False):
        return "warning"
    if clamp_int(disk.get("used_percent", 0)) >= 85:
        return "warning"
    return "healthy"


def render_logs_panel(snapshot: dict[str, Any]) -> str:
    logs = snapshot.get("logs", {})
    queue_count = len(snapshot.get("schedules", []))
    lines = [
        f"[bold {ACCENT_GOLD}]Change Window Readiness[/]",
        "",
        f"[{ACCENT_MUTED}]Can this host safely absorb scheduled maintenance right now?[/]",
        "",
    ]

    if not logs.get("ok"):
        lines.append(f"[bold {ACCENT_ROSE}]Logs snapshot unavailable:[/] {format_error_text(logs.get('error', 'unknown error'))}")
        return "\n".join(lines)

    data = logs.get("data", {})
    config = data.get("config", {})
    log_counts = data.get("logs", {})
    disk = data.get("disk", {})
    policy = data.get("policy", {})
    readiness = maintenance_window_state(data)
    config_state = "healthy" if config.get("present") and config.get("in_sync") else "warning"
    sensitive_state = "healthy" if log_counts.get("sensitive_permissions_ok") else "warning"

    lines.extend(
        [
            f"[{ACCENT_MUTED}]Overall[/]       {format_state(readiness)}",
            f"[{ACCENT_MUTED}]Queue[/]         {queue_count} scheduled task{'s' if queue_count != 1 else ''}",
            f"[{ACCENT_MUTED}]Logs[/]          {format_state(data.get('status', 'unavailable'))}",
            f"[{ACCENT_MUTED}]Rotation[/]      {format_state(config_state)}  present={config.get('present', False)}  in_sync={config.get('in_sync', False)}",
            f"[{ACCENT_MUTED}]Sensitive[/]     {format_state(sensitive_state)}  perms_ok={log_counts.get('sensitive_permissions_ok', False)}",
            f"[{ACCENT_MUTED}]Files[/]         active={log_counts.get('active_files', 0)}  rotated={log_counts.get('rotated_files', 0)}",
            f"[{ACCENT_MUTED}]Headroom[/]      {disk.get('used_percent', 0)}% used  free {format_gb_from_kb(disk.get('available_kb', 0))}",
            f"[{ACCENT_MUTED}]Retention[/]     max={policy.get('max_size', 'n/a')}  min={policy.get('min_size', 'n/a')}",
            "",
            f"[{ACCENT_MUTED}]Schedule Here[/] [bold {ACCENT_GOLD}]h[/] maintenance  [bold {ACCENT_GOLD}]m[/] restart",
            f"[{ACCENT_MUTED}]Support[/]       [bold {ACCENT_GOLD}]T[/] test logs  [bold {ACCENT_GOLD}]l[/] rotate logs",
        ]
    )
    return "\n".join(lines)


def render_update_panel(snapshot: dict[str, Any], update_plan_data: dict[str, Any] | None = None) -> str:
    check = snapshot.get("update_check", {})
    inspect = snapshot.get("update_inspect", {})
    lines = [
        f"[bold {ACCENT_GOLD}]Update Readiness[/]",
        "",
        f"[{ACCENT_MUTED}]Repository drift and database impact before risky code changes.[/]",
        "",
    ]

    if check.get("ok"):
        data = check.get("data", {})
        repo_state = "warning" if data.get("update_available") or data.get("worktree_dirty") else "healthy"
        lines.extend(
            [
                f"[{ACCENT_MUTED}]Repo[/]          {format_state(repo_state)}",
                f"[{ACCENT_MUTED}]Branch[/]        {escape_markup(data.get('branch', 'n/a'))}",
                f"[{ACCENT_MUTED}]Tracking[/]      {escape_markup(data.get('remote_ref', 'n/a'))}",
                f"[{ACCENT_MUTED}]Behind[/]        {data.get('commits_behind', 0)}  [{ACCENT_MUTED}]dirty[/] {data.get('worktree_dirty', False)}",
                f"[{ACCENT_MUTED}]Local[/]         {short_commit(data.get('local_commit'))}",
                f"[{ACCENT_MUTED}]Remote[/]        {short_commit(data.get('remote_commit'))}",
            ]
        )
    else:
        lines.append(f"[bold {ACCENT_ROSE}]Update check unavailable:[/] {format_error_text(check.get('error', 'unknown error'))}")

    lines.extend(["", f"[bold {ACCENT_SKY}]DB Impact[/]"])
    if inspect.get("ok"):
        data = inspect.get("data", {})
        lines.extend(
            [
                f"[{ACCENT_MUTED}]Assessment[/]    {format_update_assessment(data.get('db_assessment', 'unavailable'))}",
                f"[{ACCENT_MUTED}]Automation[/]    {format_flag(data.get('db_automation_supported'), true_text='supported', false_text='manual')}",
                f"[{ACCENT_MUTED}]Pending[/]       {len(data.get('pending_migrations', []))}",
                f"[{ACCENT_MUTED}]Manual Review[/] {len(data.get('manual_review', []))}",
            ]
        )
    else:
        lines.append(f"[{ACCENT_MUTED}]Inspect unavailable:[/] {format_error_text(inspect.get('error', 'no update metadata'))}")

    if update_plan_data:
        lines.extend(["", f"[bold {ACCENT_SKY}]Plan Snapshot[/]"])
        warning_text = str(update_plan_data.get("warning", "") or "")
        if warning_text:
            lines.append(f"[{ACCENT_MUTED}]Warning[/]      {escape_markup(truncate_text(warning_text, 56))}")
        steps = update_plan_data.get("steps", [])
        if isinstance(steps, list) and steps:
            lines.append(f"[{ACCENT_MUTED}]Next[/]         {escape_markup(truncate_text(steps[0], 56))}")
            if len(steps) > 1:
                lines.append(f"[{ACCENT_MUTED}]Then[/]         {escape_markup(truncate_text(steps[1], 56))}")
        else:
            lines.append(f"[{ACCENT_MUTED}]Next[/]         no pending plan steps")
    else:
        lines.extend(
            [
                "",
                f"[bold {ACCENT_SKY}]Plan Snapshot[/]",
                f"[{ACCENT_MUTED}]Next[/]         [bold {ACCENT_GOLD}]P[/] refresh the update plan before a change window.",
            ]
        )

    return "\n".join(lines)


def schedule_label(schedule: dict[str, Any]) -> str:
    schedule_type = str(schedule.get("schedule_type", "") or "")
    day = str(schedule.get("day", "") or "")
    time_value = str(schedule.get("time", "") or "")
    timezone = str(schedule.get("timezone", "") or "")

    if schedule_type == "weekly" and day:
        return f"{day} {time_value} {timezone}".strip()
    return f"{time_value} {timezone}".strip() or "n/a"


def schedule_origin_label(schedule: dict[str, Any]) -> str:
    job_type = str(schedule.get("job_type", "") or "").strip().lower()
    if job_type == "honor":
        return "schedule honor -> maintenance.honor_command"
    if job_type == "restart":
        return "schedule restart -> server restart workflow"
    return "manager scheduler backend"


def render_schedule_intro(schedules: list[dict[str, Any]]) -> str:
    count = len(schedules)
    return "\n".join(
        [
            f"[{ACCENT_MUTED}]Schedule Here[/] [bold {ACCENT_GOLD}]h[/] maintenance  [bold {ACCENT_GOLD}]m[/] restart",
            f"[{ACCENT_MUTED}]Queue Source[/]  schedules appear here after dashboard scheduling or the matching [bold {ACCENT_GOLD}]schedule[/] CLI commands.",
            f"[{ACCENT_MUTED}]Now[/]           {count} scheduled task{'s' if count != 1 else ''} in the queue.",
        ]
    )


def render_schedule_details(
    schedule: dict[str, Any] | None,
    total_schedules: int,
) -> str:
    queue_label = f"{total_schedules} scheduled task{'s' if total_schedules != 1 else ''}"
    if not schedule:
        return "\n".join(
            [
                f"[bold {ACCENT_GOLD}]Selected Schedule[/]",
                f"[{ACCENT_MUTED}]Origin, cadence, and next action for the highlighted schedule.[/]",
                "",
                f"[{ACCENT_MUTED}]Selection[/]     choose a job row from the queue to inspect or cancel it.",
                f"[{ACCENT_MUTED}]Queue[/]         {queue_label}",
                "",
                f"[{ACCENT_MUTED}]Schedule Here[/] [bold {ACCENT_GOLD}]h[/] maintenance  [bold {ACCENT_GOLD}]m[/] restart",
                f"[{ACCENT_MUTED}]CLI Path[/]      [bold {ACCENT_GOLD}]schedule honor[/] or [bold {ACCENT_GOLD}]schedule restart[/]",
                f"[{ACCENT_MUTED}]Next Action[/]   [bold {ACCENT_GOLD}]j[/] cancel the selected schedule once one is highlighted.",
            ]
        )

    warnings = str(schedule.get("warnings", "") or "none")
    announce_message = str(schedule.get("announce_message", "") or "none")
    return "\n".join(
        [
            f"[bold {ACCENT_GOLD}]Selected Schedule[/]",
            f"[{ACCENT_MUTED}]Origin, cadence, and next action for the highlighted schedule.[/]",
            "",
            f"[{ACCENT_MUTED}]Queue[/]         {queue_label}",
            f"[{ACCENT_MUTED}]Schedule ID[/]   {escape_markup(schedule.get('id', 'n/a'))}",
            f"[{ACCENT_MUTED}]Type[/]          {escape_markup(schedule_job_type_label(schedule.get('job_type', 'n/a')))}",
            f"[{ACCENT_MUTED}]Origin[/]        {escape_markup(schedule_origin_label(schedule))}",
            f"[{ACCENT_MUTED}]Cadence[/]       {escape_markup(schedule.get('schedule_type', 'n/a'))}",
            f"[{ACCENT_MUTED}]Schedule[/]      {escape_markup(schedule_label(schedule))}",
            f"[{ACCENT_MUTED}]Next Run[/]      {escape_markup(schedule.get('next_run', 'n/a') or 'n/a')}",
            f"[{ACCENT_MUTED}]Warnings[/]      {escape_markup(warnings)}",
            f"[{ACCENT_MUTED}]Announce[/]      {escape_markup(announce_message)}",
            "",
            f"[{ACCENT_MUTED}]Schedule More[/] [bold {ACCENT_GOLD}]h[/] maintenance  [bold {ACCENT_GOLD}]m[/] restart",
            f"[{ACCENT_MUTED}]Next Action[/]   [bold {ACCENT_GOLD}]j[/] remove this schedule if it is no longer desired.",
        ]
    )


class DashboardRuntimeError(RuntimeError):
    """Raised when the dashboard runtime cannot start."""


def create_app(
    manager_bin: str,
    config_path: str,
    refresh: int,
    theme: str,
    initial_view: str,
    screenshot_path: str | None,
    snapshot_file: str | None = None,
):
    os.environ.setdefault("TEXTUAL_COLOR_SYSTEM", "truecolor")
    if screenshot_path:
        os.environ.pop("NO_COLOR", None)
    try:
        from textual.app import App, ComposeResult
        from textual.containers import Container, Horizontal, Vertical
        from textual.screen import ModalScreen
        from textual.widgets import Button, DataTable, Header, Input, Label, Static
    except ImportError as exc:
        raise DashboardRuntimeError(
            f"Textual runtime import failed: {exc}. Run 'vmangos-manager dashboard --bootstrap' first."
        ) from exc

    class CommandFormScreen(ModalScreen[dict[str, str] | None]):
        BINDINGS = [("escape", "cancel", "Cancel"), ("enter", "submit", "Submit")]

        def __init__(
            self,
            title: str,
            submit_label: str,
            fields: list[dict[str, Any]],
            intro: str = "",
        ) -> None:
            super().__init__()
            self.title = title
            self.submit_label = submit_label
            self.fields = fields
            self.intro = intro

        def compose(self) -> ComposeResult:
            with Container(id="command-modal"):
                yield Static(self.title, id="command-modal-title")
                if self.intro:
                    yield Static(self.intro, id="command-modal-intro")
                for field in self.fields:
                    yield Label(str(field.get("label", "")), classes="command-modal-label")
                    yield Input(
                        value=str(field.get("value", "")),
                        placeholder=str(field.get("placeholder", "")),
                        password=bool(field.get("password", False)),
                        id=f"command-field-{field['name']}",
                    )
                yield Static("", id="command-modal-error")
                with Horizontal(id="command-modal-actions"):
                    yield Button("Cancel", id="command-cancel")
                    yield Button(self.submit_label, id="command-submit", variant="primary")

        def on_mount(self) -> None:
            if getattr(self.app, "theme_name", "dark") == "light":
                self.add_class("theme-light")
            inputs = list(self.query(Input))
            if inputs:
                self.set_focus(inputs[0])
            else:
                self.set_focus(self.query_one("#command-submit", Button))

        def collect_values(self) -> dict[str, str]:
            values: dict[str, str] = {}
            for field in self.fields:
                widget = self.query_one(f"#command-field-{field['name']}", Input)
                values[str(field["name"])] = widget.value
            return values

        def action_cancel(self) -> None:
            self.dismiss(None)

        def action_submit(self) -> None:
            self.dismiss(self.collect_values())

        def on_button_pressed(self, event: Button.Pressed) -> None:
            if event.button.id == "command-cancel":
                self.dismiss(None)
            elif event.button.id == "command-submit":
                self.dismiss(self.collect_values())

    class OnlineRosterScreen(ModalScreen[str | None]):
        BINDINGS = [
            ("escape", "close", "Close"),
            ("q", "close", "Close"),
            ("enter", "open_accounts", "Open In Accounts"),
            ("2", "open_accounts", "Accounts"),
        ]

        def __init__(self, players: list[dict[str, Any]]) -> None:
            super().__init__()
            self.players = players
            self.selected_player_id = ""

        def compose(self) -> ComposeResult:
            with Container(id="roster-modal"):
                yield Static("Online Roster", id="roster-modal-title")
                yield Static("Inspect live online accounts here, then open the selected account in the full Accounts workflow.", id="roster-modal-intro")
                with Horizontal(id="roster-modal-layout"):
                    yield DataTable(id="roster-table", classes="detail-table")
                    yield Static("", id="roster-details", classes="detail-pane")
                with Horizontal(id="roster-modal-actions"):
                    yield Button("Close", id="roster-close")
                    yield Button("Open In Accounts", id="roster-open", variant="primary")

        def on_mount(self) -> None:
            if getattr(self.app, "theme_name", "dark") == "light":
                self.add_class("theme-light")
            table = self.query_one("#roster-table", DataTable)
            table.cursor_type = "row"
            table.zebra_stripes = True
            table.add_columns("ID", "Username", "GM")
            self.refresh_roster()
            self.set_focus(table)

        def refresh_roster(self) -> None:
            table = self.query_one("#roster-table", DataTable)
            table.clear(columns=False)

            selected_index = 0
            for index, player in enumerate(self.players):
                player_id = str(player.get("id", ""))
                if self.selected_player_id and player_id == self.selected_player_id:
                    selected_index = index
                table.add_row(
                    str(player.get("id", "")),
                    str(player.get("username", "")),
                    str(player.get("gm_level", 0)),
                    key=player_id,
                )

            selected_player = self.players[selected_index] if self.players else None
            self.selected_player_id = str(selected_player.get("id", "")) if selected_player else ""
            if self.players:
                table.move_cursor(row=selected_index, column=0, animate=False)
            self.query_one("#roster-details", Static).update(render_player_details(selected_player, len(self.players)))

        def selected_player(self) -> dict[str, Any] | None:
            return next((player for player in self.players if str(player.get("id", "")) == self.selected_player_id), None)

        def update_selected_player(self, row_key: Any) -> None:
            key_value = player_key_value(row_key)
            player = next((candidate for candidate in self.players if str(candidate.get("id", "")) == key_value), None)
            if player is None and self.players:
                player = self.players[0]
            self.selected_player_id = str(player.get("id", "")) if player else ""
            self.query_one("#roster-details", Static).update(render_player_details(player, len(self.players)))

        def action_close(self) -> None:
            self.dismiss(None)

        def action_open_accounts(self) -> None:
            player = self.selected_player()
            self.dismiss(str(player.get("id", "")) if player else None)

        def on_data_table_row_highlighted(self, event: DataTable.RowHighlighted) -> None:
            if event.data_table.id == "roster-table":
                self.update_selected_player(event.row_key)

        def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
            if event.data_table.id == "roster-table":
                self.update_selected_player(event.row_key)
                self.action_open_accounts()

        def on_button_pressed(self, event: Button.Pressed) -> None:
            if event.button.id == "roster-close":
                self.dismiss(None)
            elif event.button.id == "roster-open":
                self.action_open_accounts()

    class VMangosDashboard(App[None]):
        CSS = """
        Screen {
            background: #071522;
            color: #e6edf7;
        }

        Screen.theme-light {
            background: #f6f1e7;
            color: #142033;
        }

        Header {
            background: #143b7a;
            color: #f8fafc;
        }

        Screen.theme-light Header {
            background: #c9e1ff;
            color: #111827;
        }

        Footer {
            background: #0c2340;
            color: #f8fafc;
        }

        Screen.theme-light Footer {
            background: #d8ebff;
            color: #111827;
        }

        #shell {
            layout: horizontal;
            height: 1fr;
        }

        #sidebar {
            width: 32;
            min-width: 32;
            border-right: heavy #f59e0b;
            background: #091827;
            padding: 1 2;
        }

        Screen.theme-light #sidebar {
            border-right: heavy #f59e0b;
            background: #eef6ff;
        }

        #content {
            width: 1fr;
            layout: vertical;
            padding: 1 2 1 1;
        }

        #action-banner {
            height: auto;
            margin-bottom: 1;
            border: heavy #f59e0b;
            background: #11243a;
            padding: 1 2 0 2;
        }

        Screen.theme-light #action-banner {
            border: round #2563eb;
            background: #fff7e8;
        }

        #view-stack {
            height: 1fr;
        }

        #command-rail {
            height: 5;
            margin-top: 1;
            border: heavy #f59e0b;
            background: #0b1a2a;
            padding: 0 2;
        }

        Screen.theme-light #command-rail {
            border: round #2563eb;
            background: #eef6ff;
        }

        .view {
            height: 1fr;
        }

        .hidden {
            display: none;
        }

        .panel {
            border: round #2563eb;
            background: #0d1d30;
            padding: 1 2;
            overflow: auto;
        }

        Screen.theme-light .panel {
            border: round #2563eb;
            background: #fffdf7;
        }

        .hero-panel {
            border: round #f59e0b;
            background: #13243a;
        }

        .accent-panel {
            border: round #14b8a6;
            background: #0f2234;
        }

        .table-panel {
            background: #0a1828;
        }

        #overview-grid {
            layout: grid;
            grid-size: 2 2;
            grid-columns: 1fr 1fr;
            grid-rows: 15 1fr;
            grid-gutter: 1 2;
            height: 1fr;
        }

        #monitor-grid {
            layout: grid;
            grid-size: 2 2;
            grid-columns: 7fr 5fr;
            grid-rows: 1fr 1fr;
            grid-gutter: 1 2;
            height: 1fr;
        }

        .table-detail {
            layout: vertical;
            height: 1fr;
        }

        .table-detail-title {
            height: auto;
            color: #f59e0b;
            text-style: bold;
            padding-bottom: 1;
        }

        Screen.theme-light .table-detail-title {
            color: #1d4ed8;
        }

        .table-detail-body {
            layout: horizontal;
            height: 1fr;
            margin-top: 1;
        }

        #schedule-intro {
            height: auto;
            margin-bottom: 1;
            color: #cbd5e1;
        }

        Screen.theme-light #schedule-intro {
            color: #475569;
        }

        .detail-table {
            width: 1fr;
        }

        .detail-pane {
            width: 42%;
            min-width: 30;
            height: 1fr;
            margin-left: 1;
            border-left: heavy #f59e0b;
            padding-left: 2;
            background: #0d1d30;
        }

        Screen.theme-light .detail-pane {
            border-left: heavy #93c5fd;
            background: #fff9ef;
        }

        #players-table {
            height: 1fr;
            margin-top: 1;
        }

        #player-pulse-pane,
        #alerts-pane {
            min-height: 16;
        }

        #monitor-pressure-pane,
        #monitor-process-pane,
        #monitor-trends-pane,
        #monitor-storage-pane {
            min-height: 14;
        }

        #accounts-table {
            height: 1fr;
        }

        #accounts-layout,
        #backups-layout {
            height: 1fr;
        }

        #accounts-layout {
            layout: horizontal;
        }

        #accounts-table-layout {
            width: 1fr;
            height: 1fr;
            margin-right: 1;
        }

        #account-details {
            width: 40;
            min-width: 36;
            height: 1fr;
        }

        #operations-layout {
            height: 1fr;
            layout: vertical;
        }

        #operations-summary {
            height: 13;
            margin-bottom: 1;
        }

        #logs-pane,
        #update-pane {
            width: 1fr;
            height: 1fr;
        }

        #logs-pane {
            margin-right: 1;
        }

        #schedules-table {
            height: 1fr;
        }

        #backup-summary {
            width: 48;
            min-width: 46;
            height: 1fr;
            margin-right: 1;
        }

        #backups-table-layout {
            width: 1fr;
            height: 1fr;
        }

        DataTable {
            background: #0a1828;
            color: #e6edf7;
        }

        Screen.theme-light DataTable {
            background: #ffffff;
            color: #111827;
        }

        #backups-table {
            height: 1fr;
            width: 1fr;
            margin-top: 1;
        }

        #config-pane {
            height: 1fr;
        }

        CommandFormScreen {
            align: center middle;
            background: rgba(6, 17, 29, 0.78);
        }

        CommandFormScreen.theme-light {
            background: rgba(246, 241, 231, 0.82);
        }

        #command-modal {
            width: 84;
            max-width: 100;
            height: auto;
            border: heavy #f59e0b;
            background: #0c1b2c;
            padding: 1 2 2 2;
        }

        CommandFormScreen.theme-light #command-modal {
            border: round #2563eb;
            background: #fffdf7;
        }

        #command-modal-title {
            text-style: bold;
            color: #f59e0b;
            margin-bottom: 1;
        }

        CommandFormScreen.theme-light #command-modal-title {
            color: #1d4ed8;
        }

        #command-modal-intro {
            color: #cbd5e1;
            margin-bottom: 1;
        }

        CommandFormScreen.theme-light #command-modal-intro {
            color: #475569;
        }

        .command-modal-label {
            margin-top: 1;
            color: #7dd3fc;
            text-style: bold;
        }

        CommandFormScreen.theme-light .command-modal-label {
            color: #1d4ed8;
        }

        #command-modal Input {
            margin-top: 0;
            margin-bottom: 1;
            border: round #1d4ed8;
            background: #102033;
            color: #f8fafc;
        }

        CommandFormScreen.theme-light #command-modal Input {
            border: round #93c5fd;
            background: #ffffff;
            color: #111827;
        }

        #command-modal-error {
            color: #fb7185;
            min-height: 1;
            margin-top: 1;
        }

        #command-modal-actions {
            height: auto;
            margin-top: 2;
        }

        #command-submit {
            margin-left: 1;
        }

        #roster-modal {
            width: 112;
            max-width: 140;
            height: 28;
            border: heavy #f59e0b;
            background: #0c1b2c;
            padding: 1 2 2 2;
        }

        CommandFormScreen.theme-light #roster-modal,
        OnlineRosterScreen.theme-light #roster-modal {
            border: round #2563eb;
            background: #fffdf7;
        }

        #roster-modal-title {
            text-style: bold;
            color: #f59e0b;
            margin-bottom: 1;
        }

        OnlineRosterScreen.theme-light #roster-modal-title {
            color: #1d4ed8;
        }

        #roster-modal-intro {
            color: #cbd5e1;
            margin-bottom: 1;
        }

        OnlineRosterScreen.theme-light #roster-modal-intro {
            color: #475569;
        }

        #roster-modal-layout {
            height: 1fr;
        }

        #roster-table {
            width: 1fr;
            height: 1fr;
            margin-right: 1;
        }

        #roster-details {
            width: 34;
            min-width: 32;
            height: 1fr;
        }

        #roster-modal-actions {
            height: auto;
            margin-top: 1;
        }

        #roster-open {
            margin-left: 1;
        }
        """

        BINDINGS = [
            ("q", "quit", "Quit"),
            ("r", "manual_refresh", "Refresh"),
            ("s", "start_server", "Start"),
            ("x", "stop_server", "Stop"),
            ("R", "restart_server", "Restart"),
            ("o", "open_online_roster", "Roster"),
            ("b", "backup_now", "Backup"),
            ("v", "verify_selected_backup", "Verify"),
            ("c", "create_account", "Create"),
            ("p", "reset_account_password", "Password"),
            ("g", "set_account_gm", "Set GM"),
            ("n", "ban_account", "Ban"),
            ("u", "unban_account", "Unban"),
            ("l", "rotate_logs", "Rotate Logs"),
            ("T", "test_logs_config", "Test Logs"),
            ("h", "create_honor_schedule", "Schedule Maintenance"),
            ("m", "create_restart_schedule", "Schedule Restart"),
            ("P", "refresh_update_plan", "Update Plan"),
            ("d", "restore_selected_backup_dry_run", "Dry Run"),
            ("y", "schedule_daily_backup", "Daily"),
            ("w", "schedule_weekly_backup", "Weekly"),
            ("j", "cancel_selected_schedule", "Cancel Schedule"),
            ("k", "validate_config", "Validate"),
            ("1", "show_overview", "Overview"),
            ("2", "show_monitor", "Monitor"),
            ("3", "show_accounts", "Accounts"),
            ("4", "show_backups", "Backups"),
            ("5", "show_config", "Config"),
            ("6", "show_operations", "Ops"),
            ("t", "toggle_theme", "Theme"),
        ]

        def __init__(self) -> None:
            super().__init__()
            self.manager_bin = manager_bin
            self.config_path = config_path
            self.refresh_interval = refresh
            self.theme_name = theme
            self.screenshot_path = screenshot_path
            self.snapshot_file = snapshot_file
            self.screenshot_taken = False
            self.screenshot_pending = False
            self.active_view = initial_view if initial_view in VIEW_TITLES else "overview"
            self.last_action = "loading dashboard data..."
            self.action_tone = "info"
            self.snapshot = empty_snapshot("waiting for first refresh")
            self.metric_history: list[dict[str, Any]] = []
            self.selected_account_id = ""
            self.selected_backup_file = ""
            self.selected_schedule_id = ""
            self.update_plan_data: dict[str, Any] | None = None
            self.refresh_inflight = False
            self.action_inflight = False

        def compose(self) -> ComposeResult:
            yield Header(show_clock=True)
            with Horizontal(id="shell"):
                yield Static("", id="sidebar")
                with Container(id="content"):
                    yield Static("", id="action-banner")
                    with Container(id="view-stack"):
                        with Container(id="overview-view", classes="view"):
                            with Container(id="overview-grid"):
                                yield Static("", id="service-pane", classes="panel hero-panel")
                                yield Static("", id="metrics-pane", classes="panel accent-panel")
                                yield Static("", id="player-pulse-pane", classes="panel hero-panel")
                                yield Static("", id="alerts-pane", classes="panel accent-panel")
                        with Container(id="monitor-view", classes="view hidden"):
                            with Container(id="monitor-grid"):
                                yield Static("", id="monitor-pressure-pane", classes="panel hero-panel")
                                yield Static("", id="monitor-process-pane", classes="panel accent-panel")
                                yield Static("", id="monitor-trends-pane", classes="panel hero-panel")
                                yield Static("", id="monitor-storage-pane", classes="panel accent-panel")
                        with Container(id="accounts-view", classes="view hidden"):
                            with Horizontal(id="accounts-layout"):
                                with Vertical(classes="panel table-panel", id="accounts-table-layout"):
                                    yield Static("[b]Account Inventory[/b]", classes="table-detail-title")
                                    yield DataTable(id="accounts-table", classes="detail-table")
                                yield Static("", id="account-details", classes="panel hero-panel")
                        with Container(id="backups-view", classes="view hidden"):
                            with Horizontal(id="backups-layout"):
                                yield Static("", id="backup-summary", classes="panel hero-panel")
                                with Vertical(classes="panel table-panel", id="backups-table-layout"):
                                    yield Static("[b]Backup Inventory[/b]", classes="table-detail-title")
                                    yield DataTable(id="backups-table", classes="detail-table")
                        with Container(id="config-view", classes="view hidden"):
                            yield Static("", id="config-pane", classes="panel hero-panel")
                        with Container(id="operations-view", classes="view hidden"):
                            with Vertical(id="operations-layout"):
                                with Horizontal(id="operations-summary"):
                                    yield Static("", id="logs-pane", classes="panel accent-panel")
                                    yield Static("", id="update-pane", classes="panel hero-panel")
                                with Vertical(classes="panel table-panel table-detail", id="schedules-layout"):
                                    yield Static("[b]Scheduled Maintenance[/b]", classes="table-detail-title")
                                    yield Static("", id="schedule-intro")
                                    with Horizontal(classes="table-detail-body"):
                                        yield DataTable(id="schedules-table", classes="detail-table")
                                        yield Static("", id="schedule-details", classes="detail-pane")
                    yield Static("", id="command-rail")

        def on_mount(self) -> None:
            accounts_table = self.query_one("#accounts-table", DataTable)
            accounts_table.cursor_type = "row"
            accounts_table.zebra_stripes = True
            accounts_table.add_columns("ID", "Username", "GM", "Online", "Banned")

            backups_table = self.query_one("#backups-table", DataTable)
            backups_table.cursor_type = "row"
            backups_table.zebra_stripes = True
            backups_table.add_columns("Timestamp", "Size", "File", "Created By")

            schedules_table = self.query_one("#schedules-table", DataTable)
            schedules_table.cursor_type = "row"
            schedules_table.zebra_stripes = True
            schedules_table.add_columns("Type", "Schedule", "Next Run", "ID")

            self.apply_theme()
            self.apply_view_state()
            self.request_snapshot_refresh()
            self.set_interval(self.refresh_interval, self.request_snapshot_refresh)

        def apply_theme(self) -> None:
            self.theme = "tokyo-night" if self.theme_name == "dark" else "catppuccin-latte"
            self.remove_class("theme-light")
            self.remove_class("theme-dark")
            self.add_class(f"theme-{self.theme_name}")

        def apply_view_state(self) -> None:
            for view_name in ("overview", "monitor", "accounts", "backups", "config", "operations"):
                widget = self.query_one(f"#{view_name}-view", Container)
                if view_name == self.active_view:
                    widget.remove_class("hidden")
                else:
                    widget.add_class("hidden")

            self.refresh_chrome()
            if self.active_view == "accounts":
                self.set_focus(self.query_one("#accounts-table", DataTable))
            elif self.active_view == "backups":
                self.set_focus(self.query_one("#backups-table", DataTable))
            elif self.active_view == "operations":
                self.set_focus(self.query_one("#schedules-table", DataTable))

        def refresh_chrome(self) -> None:
            self.query_one("#sidebar", Static).update(
                render_sidebar(self.active_view, self.last_action, self.snapshot, self.refresh_interval)
            )
            self.query_one("#action-banner", Static).update(
                render_action_banner(
                    self.active_view,
                    self.snapshot,
                    self.last_action,
                    self.action_tone,
                    self.refresh_interval,
                )
            )
            self.query_one("#command-rail", Static).update(render_command_rail(self.active_view))

        def request_snapshot_refresh(self) -> None:
            if self.refresh_inflight:
                return
            self.refresh_inflight = True
            threading.Thread(target=self.refresh_snapshot_worker, daemon=True).start()

        def refresh_snapshot_worker(self) -> None:
            try:
                if self.snapshot_file:
                    snapshot = load_snapshot_fixture(self.snapshot_file)
                else:
                    snapshot = build_snapshot(self.manager_bin, self.config_path)
            except Exception as exc:
                snapshot = empty_snapshot(f"snapshot refresh failed: {exc}")
            self.call_from_thread(self.apply_snapshot, snapshot)

        def apply_snapshot(self, snapshot: dict[str, Any]) -> None:
            self.snapshot = snapshot
            if self.last_action == "loading dashboard data...":
                self.last_action = "latest data loaded"
                self.action_tone = "info"
            if not self.metric_history:
                self.metric_history = extract_seed_metric_history(snapshot)
            self.metric_history = append_monitoring_sample(self.metric_history, snapshot)
            self.refresh_inflight = False
            self.query_one("#service-pane", Static).update(render_service_panel(snapshot, self.active_view))
            self.query_one("#metrics-pane", Static).update(render_metrics_panel(snapshot, self.metric_history, self.refresh_interval))
            self.query_one("#player-pulse-pane", Static).update(render_player_pulse(snapshot, self.metric_history, self.refresh_interval))
            self.query_one("#alerts-pane", Static).update(render_alerts_panel(snapshot))
            self.query_one("#monitor-pressure-pane", Static).update(render_monitor_pressure(snapshot, self.metric_history, self.refresh_interval))
            self.query_one("#monitor-process-pane", Static).update(render_monitor_processes(snapshot))
            self.query_one("#monitor-trends-pane", Static).update(render_monitor_trends(snapshot, self.metric_history, self.refresh_interval))
            self.query_one("#monitor-storage-pane", Static).update(render_monitor_storage(snapshot))
            self.query_one("#config-pane", Static).update(render_config_panel(snapshot))
            self.query_one("#logs-pane", Static).update(render_logs_panel(snapshot))
            self.query_one("#update-pane", Static).update(render_update_panel(snapshot, self.update_plan_data))
            self.refresh_accounts(snapshot.get("all_accounts", []))
            self.refresh_backups(snapshot.get("backups", {}).get("entries", []))
            self.refresh_schedules(snapshot.get("schedules", []))
            self.refresh_chrome()
            if self.screenshot_path and not self.screenshot_taken and not self.screenshot_pending:
                self.screenshot_pending = True
                self.set_timer(0.5, self.capture_screenshot_and_exit)

        def capture_screenshot_and_exit(self) -> None:
            self.screenshot_taken = True
            self.save_screenshot(self.screenshot_path)
            self.exit()

        def selected_account(self) -> dict[str, Any] | None:
            return find_selected_account(self.snapshot, self.selected_account_id)

        def selected_backup(self) -> dict[str, Any] | None:
            return find_selected_backup(self.snapshot, self.selected_backup_file)

        def selected_schedule(self) -> dict[str, Any] | None:
            return find_selected_schedule(self.snapshot, self.selected_schedule_id)

        def refresh_accounts(self, accounts: list[dict[str, Any]]) -> None:
            table = self.query_one("#accounts-table", DataTable)
            table.clear(columns=False)

            selected_index = 0
            for index, account in enumerate(accounts):
                account_id = str(account.get("id", ""))
                if self.selected_account_id and account_id == self.selected_account_id:
                    selected_index = index
                table.add_row(
                    str(account.get("id", "")),
                    str(account.get("username", "")),
                    str(account.get("gm_level", 0)),
                    "yes" if account.get("online") else "no",
                    "yes" if account.get("banned") else "no",
                    key=account_id,
                )

            if accounts:
                current_account = accounts[selected_index]
                self.selected_account_id = str(current_account.get("id", ""))
                table.move_cursor(row=selected_index, column=0, animate=False)
                self.query_one("#account-details", Static).update(render_account_details(current_account, len(accounts)))
            else:
                self.selected_account_id = ""
                self.query_one("#account-details", Static).update(render_account_details(None, len(accounts)))

        def refresh_backups(self, entries: list[dict[str, Any]]) -> None:
            table = self.query_one("#backups-table", DataTable)
            table.clear(columns=False)

            selected_entry: dict[str, Any] | None = None
            selected_index = 0
            for index, entry in enumerate(sorted(entries, key=lambda item: str(item.get("timestamp", "")), reverse=True)):
                backup_file = str(entry.get("file", ""))
                if self.selected_backup_file and backup_file == self.selected_backup_file:
                    selected_index = index
                    selected_entry = entry
                table.add_row(
                    iso_to_display(entry.get("timestamp")),
                    format_bytes(entry.get("size_bytes", 0)),
                    backup_file,
                    str(entry.get("created_by", "n/a")),
                    key=backup_file,
                )

            if entries:
                if selected_entry is None:
                    selected_entry = sorted(entries, key=lambda item: str(item.get("timestamp", "")), reverse=True)[selected_index]
                self.selected_backup_file = str(selected_entry.get("file", ""))
                table.move_cursor(row=selected_index, column=0, animate=False)
            else:
                self.selected_backup_file = ""

            self.query_one("#backup-summary", Static).update(
                render_backups_summary(snapshot=self.snapshot, selected_backup=selected_entry)
            )

        def refresh_schedules(self, schedules: list[dict[str, Any]]) -> None:
            table = self.query_one("#schedules-table", DataTable)
            table.clear(columns=False)
            self.query_one("#schedule-intro", Static).update(render_schedule_intro(schedules))

            selected_index = 0
            selected_schedule: dict[str, Any] | None = None
            for index, schedule in enumerate(
                sorted(schedules, key=lambda item: (str(item.get("next_run", "")), str(item.get("id", ""))))
            ):
                schedule_id = str(schedule.get("id", ""))
                if self.selected_schedule_id and schedule_id == self.selected_schedule_id:
                    selected_index = index
                    selected_schedule = schedule
                table.add_row(
                    schedule_job_type_label(schedule.get("job_type", "")),
                    schedule_label(schedule),
                    str(schedule.get("next_run", "") or "n/a"),
                    schedule_id,
                    key=schedule_id,
                )

            if schedules:
                if selected_schedule is None:
                    selected_schedule = sorted(
                        schedules, key=lambda item: (str(item.get("next_run", "")), str(item.get("id", "")))
                    )[selected_index]
                self.selected_schedule_id = str(selected_schedule.get("id", ""))
                table.move_cursor(row=selected_index, column=0, animate=False)
            else:
                self.selected_schedule_id = ""

            self.query_one("#schedule-details", Static).update(
                render_schedule_details(selected_schedule, len(schedules))
            )

        def update_selected_account(self, row_key: Any) -> None:
            key_value = player_key_value(row_key)
            accounts = self.snapshot.get("all_accounts", [])
            account = next((candidate for candidate in accounts if str(candidate.get("id", "")) == key_value), None)
            if account is None and accounts:
                account = accounts[0]
            self.selected_account_id = str(account.get("id", "")) if account else ""
            self.query_one("#account-details", Static).update(render_account_details(account, len(accounts)))

        def update_selected_backup(self, row_key: Any) -> None:
            key_value = player_key_value(row_key)
            entries = self.snapshot.get("backups", {}).get("entries", [])
            entry = next((candidate for candidate in entries if str(candidate.get("file", "")) == key_value), None)
            if entry is None and entries:
                entry = max(entries, key=lambda item: str(item.get("timestamp", "")))
            self.selected_backup_file = str(entry.get("file", "")) if entry else ""
            self.query_one("#backup-summary", Static).update(
                render_backups_summary(snapshot=self.snapshot, selected_backup=entry)
            )

        def update_selected_schedule(self, row_key: Any) -> None:
            key_value = player_key_value(row_key)
            schedules = self.snapshot.get("schedules", [])
            schedule = next((candidate for candidate in schedules if str(candidate.get("id", "")) == key_value), None)
            if schedule is None and schedules:
                schedule = schedules[0]
            self.selected_schedule_id = str(schedule.get("id", "")) if schedule else ""
            self.query_one("#schedule-details", Static).update(
                render_schedule_details(schedule, len(schedules))
            )

        def open_command_form(
            self,
            action_name: str,
            title: str,
            submit_label: str,
            fields: list[dict[str, Any]],
            intro: str = "",
        ) -> None:
            self.push_screen(
                CommandFormScreen(title=title, submit_label=submit_label, fields=fields, intro=intro),
                lambda result, action_name=action_name: self.handle_command_form_result(action_name, result),
            )

        def handle_command_form_result(self, action_name: str, result: dict[str, str] | None) -> None:
            if result is None:
                return
            self.dispatch_dashboard_action(action_name, result)

        def dispatch_dashboard_action(self, action_name: str, form_values: dict[str, Any] | None = None) -> None:
            request = build_dashboard_action_request(
                self.snapshot,
                self.selected_account_id,
                self.selected_backup_file,
                self.selected_schedule_id,
                action_name,
                form_values,
            )
            error = str(request.get("error", ""))
            if error:
                self.set_action_result(error, tone="warning")
                return

            target_view = str(request.get("view", "") or "")
            if target_view and target_view != self.active_view:
                self.active_view = target_view
                self.apply_view_state()

            self.request_command_action(
                str(request["label"]),
                list(request["command"]),
                refresh_after=bool(request.get("refresh_after", True)),
                env=dict(request.get("env", {})),
            )

        def on_data_table_row_highlighted(self, event: DataTable.RowHighlighted) -> None:
            if event.data_table.id == "accounts-table":
                self.update_selected_account(event.row_key)
            elif event.data_table.id == "backups-table":
                self.update_selected_backup(event.row_key)
            elif event.data_table.id == "schedules-table":
                self.update_selected_schedule(event.row_key)

        def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
            if event.data_table.id == "accounts-table":
                self.update_selected_account(event.row_key)
            elif event.data_table.id == "backups-table":
                self.update_selected_backup(event.row_key)
            elif event.data_table.id == "schedules-table":
                self.update_selected_schedule(event.row_key)

        def action_show_overview(self) -> None:
            self.active_view = "overview"
            self.apply_view_state()

        def action_show_monitor(self) -> None:
            self.active_view = "monitor"
            self.apply_view_state()

        def action_show_accounts(self) -> None:
            self.active_view = "accounts"
            self.apply_view_state()

        def action_show_backups(self) -> None:
            self.active_view = "backups"
            self.apply_view_state()

        def action_show_config(self) -> None:
            self.active_view = "config"
            self.apply_view_state()

        def action_show_operations(self) -> None:
            self.active_view = "operations"
            self.apply_view_state()

        def action_manual_refresh(self) -> None:
            self.set_action_result(f"manual refresh requested at {datetime.now().strftime('%H:%M:%S')}", tone="info")
            self.request_snapshot_refresh()

        def action_toggle_theme(self) -> None:
            self.theme_name = "light" if self.theme_name == "dark" else "dark"
            self.apply_theme()
            self.set_action_result(f"theme set to {self.theme_name}", tone="success")
            self.apply_view_state()
            self.query_one("#service-pane", Static).update(render_service_panel(self.snapshot, self.active_view))

        def action_start_server(self) -> None:
            self.request_command_action("start", ["server", "start", "--wait", "--timeout", "60"])

        def action_stop_server(self) -> None:
            self.request_command_action("stop", ["server", "stop", "--timeout", "60"])

        def action_restart_server(self) -> None:
            self.request_command_action("restart", ["server", "restart", "--timeout", "60"])

        def handle_online_roster_result(self, account_id: str | None) -> None:
            if not account_id:
                return
            self.selected_account_id = account_id
            self.active_view = "accounts"
            self.apply_view_state()
            self.refresh_accounts(self.snapshot.get("all_accounts", []))

        def action_open_online_roster(self) -> None:
            players = self.snapshot.get("players", [])
            if not players:
                self.set_action_result("online roster is empty", tone="warning")
                return
            self.push_screen(OnlineRosterScreen(players), self.handle_online_roster_result)

        def action_backup_now(self) -> None:
            self.active_view = "backups"
            self.apply_view_state()
            self.request_command_action("backup", ["backup", "now", "--verify"])

        def action_verify_selected_backup(self) -> None:
            backups = self.snapshot.get("backups", {})
            summary = backups.get("summary", {})
            backup_dir = str(summary.get("backup_dir", ""))
            if not self.selected_backup_file or not backup_dir:
                self.set_action_result("backup verify skipped: no backup selected", tone="warning")
                return

            backup_path = f"{backup_dir.rstrip('/')}/{self.selected_backup_file}"
            self.request_command_action("verify", ["backup", "verify", backup_path, "--level", "1"], refresh_after=False)

        def action_create_account(self) -> None:
            self.active_view = "accounts"
            self.apply_view_state()
            self.open_command_form(
                "account_create",
                "Create Account",
                "Create",
                [
                    {"name": "username", "label": "Username", "placeholder": "PLAYERONE"},
                    {"name": "password", "label": "Password", "password": True},
                    {"name": "confirm_password", "label": "Confirm Password", "password": True},
                ],
                "Create a VMaNGOS account using the existing Manager CLI backend.",
            )

        def action_reset_account_password(self) -> None:
            account = self.selected_account()
            if account is None:
                self.set_action_result("password reset skipped: no account selected")
                return
            username = str(account.get("username", "selected account")).strip()
            self.active_view = "accounts"
            self.apply_view_state()
            self.open_command_form(
                "account_password",
                "Reset Account Password",
                "Reset",
                [
                    {"name": "password", "label": "New Password", "password": True},
                    {"name": "confirm_password", "label": "Confirm Password", "password": True},
                ],
                f"Reset the password for {username}.",
            )

        def action_set_account_gm(self) -> None:
            account = self.selected_account()
            if account is None:
                self.set_action_result("set GM skipped: no account selected")
                return
            username = str(account.get("username", "selected account")).strip()
            self.active_view = "accounts"
            self.apply_view_state()
            self.open_command_form(
                "account_setgm",
                "Set GM Level",
                "Apply",
                [
                    {
                        "name": "gm_level",
                        "label": "GM Level (0-3)",
                        "value": str(account.get("gm_level", 0)),
                        "placeholder": "0",
                    }
                ],
                f"Adjust GM access for {username}.",
            )

        def action_ban_account(self) -> None:
            account = self.selected_account()
            if account is None:
                self.set_action_result("account ban skipped: no account selected")
                return
            username = str(account.get("username", "selected account")).strip()
            self.active_view = "accounts"
            self.apply_view_state()
            self.open_command_form(
                "account_ban",
                "Ban Account",
                "Ban",
                [
                    {"name": "duration", "label": "Duration", "placeholder": "7d"},
                    {"name": "reason", "label": "Reason", "placeholder": "Abuse"},
                ],
                f"Ban {username} with the existing account CLI workflow.",
            )

        def action_unban_account(self) -> None:
            self.dispatch_dashboard_action("account_unban")

        def action_restore_selected_backup_dry_run(self) -> None:
            backup = self.selected_backup()
            if backup is None:
                self.set_action_result("backup restore skipped: no backup selected")
                return
            backup_file = str(backup.get("file", "selected backup")).strip()
            self.active_view = "backups"
            self.apply_view_state()
            self.open_command_form(
                "backup_restore_dry_run",
                "Restore Dry Run",
                "Run Dry Run",
                [],
                f"Run a dry-run restore check for {backup_file}.",
            )

        def action_schedule_daily_backup(self) -> None:
            self.active_view = "backups"
            self.apply_view_state()
            self.open_command_form(
                "backup_schedule_daily",
                "Schedule Daily Backup",
                "Schedule",
                [{"name": "time", "label": "Daily Time (HH:MM)", "value": "04:00", "placeholder": "04:00"}],
                "Install or update the daily backup timer.",
            )

        def action_schedule_weekly_backup(self) -> None:
            self.active_view = "backups"
            self.apply_view_state()
            self.open_command_form(
                "backup_schedule_weekly",
                "Schedule Weekly Backup",
                "Schedule",
                [{"name": "schedule", "label": "Weekly Schedule", "value": "Sun 04:00", "placeholder": "Sun 04:00"}],
                "Install or update the weekly backup timer.",
            )

        def action_validate_config(self) -> None:
            self.dispatch_dashboard_action("config_validate")

        def action_rotate_logs(self) -> None:
            self.active_view = "operations"
            self.apply_view_state()
            self.dispatch_dashboard_action("logs_rotate")

        def action_test_logs_config(self) -> None:
            self.active_view = "operations"
            self.apply_view_state()
            self.dispatch_dashboard_action("logs_test_config")

        def action_create_honor_schedule(self) -> None:
            self.active_view = "operations"
            self.apply_view_state()
            self.open_command_form(
                "schedule_honor_create",
                "Schedule Maintenance",
                "Schedule",
                [
                    {"name": "schedule_type", "label": "Cadence (daily|weekly)", "value": "daily", "placeholder": "daily"},
                    {"name": "day", "label": "Weekly Day", "value": "Sun", "placeholder": "Sun"},
                    {"name": "time", "label": "Time (HH:MM)", "value": "06:00", "placeholder": "06:00"},
                    {"name": "timezone", "label": "Timezone", "value": "UTC", "placeholder": "UTC"},
                ],
                "Schedule the configured maintenance job backend. This uses maintenance.honor_command under the hood.",
            )

        def action_create_restart_schedule(self) -> None:
            self.active_view = "operations"
            self.apply_view_state()
            self.open_command_form(
                "schedule_restart_create",
                "Schedule Restart",
                "Schedule",
                [
                    {"name": "schedule_type", "label": "Cadence (daily|weekly)", "value": "weekly", "placeholder": "weekly"},
                    {"name": "day", "label": "Weekly Day", "value": "Sun", "placeholder": "Sun"},
                    {"name": "time", "label": "Time (HH:MM)", "value": "04:00", "placeholder": "04:00"},
                    {"name": "timezone", "label": "Timezone", "value": "UTC", "placeholder": "UTC"},
                    {"name": "warnings", "label": "Warnings", "value": "30,15,5,1", "placeholder": "30,15,5,1"},
                    {"name": "announce", "label": "Announcement", "value": "Weekly maintenance", "placeholder": "Weekly maintenance"},
                ],
                "Create a scheduled restart with warning timers via the existing Manager scheduler backend.",
            )

        def action_refresh_update_plan(self) -> None:
            self.active_view = "operations"
            self.apply_view_state()
            self.request_update_plan_refresh()

        def action_cancel_selected_schedule(self) -> None:
            schedule = self.selected_schedule()
            if schedule is None:
                self.set_action_result("schedule cancel skipped: no job selected", tone="warning")
                return
            schedule_id = str(schedule.get("id", "selected schedule")).strip()
            self.active_view = "operations"
            self.apply_view_state()
            self.open_command_form(
                "schedule_cancel",
                "Cancel Schedule",
                "Cancel Schedule",
                [],
                f"Remove scheduled task {schedule_id} from Manager and systemd.",
            )

        def request_update_plan_refresh(self) -> None:
            if self.action_inflight:
                self.set_action_result("another dashboard action is already running", tone="warning")
                return
            self.action_inflight = True
            self.set_action_result("update plan running...", tone="running")
            threading.Thread(target=self.run_update_plan_action, daemon=True).start()

        def run_update_plan_action(self) -> None:
            try:
                full_command = [self.manager_bin, "-c", self.config_path, "-f", "json", "update", "plan", "--include-db"]
                completed = subprocess.run(full_command, capture_output=True, text=True, check=False)
                if completed.returncode != 0:
                    output = (completed.stderr or completed.stdout or "").strip().splitlines()
                    message = output[-1] if output else f"update plan exited with code {completed.returncode}"
                    self.call_from_thread(self.set_action_result, f"update plan failed: {message}", "error")
                    return

                try:
                    data = parse_manager_json(completed.stdout)
                except (json.JSONDecodeError, RuntimeError) as exc:
                    self.call_from_thread(self.set_action_result, f"update plan failed: {exc}", "error")
                    return

                self.call_from_thread(self.apply_update_plan_data, data)
            finally:
                self.action_inflight = False

        def apply_update_plan_data(self, data: dict[str, Any]) -> None:
            self.update_plan_data = data
            warning_text = str(data.get("warning", "") or "")
            if warning_text:
                self.set_action_result(f"update plan refreshed: {warning_text}", tone="warning")
            else:
                self.set_action_result("update plan refreshed", tone="success")
            self.query_one("#update-pane", Static).update(render_update_panel(self.snapshot, self.update_plan_data))

        def request_command_action(
            self,
            label: str,
            command: list[str],
            *,
            refresh_after: bool = True,
            env: dict[str, str] | None = None,
        ) -> None:
            if self.action_inflight:
                self.set_action_result("another dashboard action is already running", tone="warning")
                return
            self.action_inflight = True
            self.set_action_result(f"{label} running...", tone="running")
            threading.Thread(
                target=self.run_command_action,
                args=(label, command, refresh_after, env or {}),
                daemon=True,
            ).start()

        def run_command_action(
            self,
            label: str,
            command: list[str],
            refresh_after: bool,
            env: dict[str, str],
        ) -> None:
            try:
                full_command = [self.manager_bin, "-c", self.config_path, *command]
                command_env = os.environ.copy()
                command_env.update(env)
                completed = subprocess.run(full_command, capture_output=True, text=True, check=False, env=command_env)
                output = (completed.stdout or completed.stderr or "").strip().splitlines()
                message = output[-1] if output else f"{label} exited with code {completed.returncode}"
                if completed.returncode == 0:
                    self.call_from_thread(self.set_action_result, f"{label}: {message}", "success")
                    if refresh_after:
                        self.call_from_thread(self.request_snapshot_refresh)
                else:
                    self.call_from_thread(self.set_action_result, f"{label} failed: {message}", "error")
            finally:
                self.action_inflight = False

        def set_action_result(self, message: str, tone: str = "info") -> None:
            self.last_action = message
            self.action_tone = tone
            self.refresh_chrome()
            self.query_one("#service-pane", Static).update(render_service_panel(self.snapshot, self.active_view))
            if self.active_view == "operations":
                self.query_one("#schedule-details", Static).update(
                    render_schedule_details(self.selected_schedule(), len(self.snapshot.get("schedules", [])))
                )
                self.query_one("#update-pane", Static).update(render_update_panel(self.snapshot, self.update_plan_data))

    return VMangosDashboard()


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    if args.snapshot_json:
        print(json.dumps(build_snapshot(args.manager_bin, args.config)))
        return 0

    try:
        app = create_app(
            args.manager_bin,
            args.config,
            args.refresh,
            args.theme,
            args.view,
            args.screenshot,
            args.snapshot_file,
        )
    except DashboardRuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    app.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
