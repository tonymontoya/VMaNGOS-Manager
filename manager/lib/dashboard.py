#!/usr/bin/env python3
"""Textual dashboard for VMANGOS Manager."""

from __future__ import annotations

import argparse
import getpass
import json
import os
import re
import subprocess
import sys
import threading
from datetime import datetime, timezone
from typing import Any, Callable


# A colour is only readable relative to what sits behind it, so the tables and
# the panel markup name *roles*, and a palette turns a role into a hex for the
# theme in use. Without that indirection the light theme inherits colours picked
# against the dark screen: #cbd5e1 labels on #f6f1e7 are about 2:1, which is why
# a light screen looked half-painted rather than light.
DARK_PALETTE = {
    "muted": "#cbd5e1",
    "gold": "#f59e0b",
    "sky": "#7dd3fc",
    "teal": "#2dd4bf",
    "rose": "#fb7185",
    "green": "#34d399",
    "green_strong": "#22c55e",
    "blue": "#3b82f6",
    "amber": "#f59e0b",
    "amber_soft": "#fbbf24",
    "red": "#ef4444",
    "red_soft": "#f87171",
    "slate": "#94a3b8",
    # Selection chrome. Textual paints the row cursor and the scrollbars from its
    # own theme variables, whose default is a purple that appears in neither
    # palette here. A cursor the operator cannot see is worse than no cursor, and
    # a scrollbar in a colour the theme never chose makes the light theme look
    # like a different program.
    "cursor_bg": "#2563eb",
    "cursor_fg": "#f8fafc",
    "cursor_blur_bg": "#274463",
    "cursor_blur_fg": "#e6edf7",
    "scrollbar": "#3b82f6",
    "scrollbar_hover": "#7dd3fc",
    "scrollbar_active": "#7dd3fc",
    "scrollbar_track": "#12283c",
}

LIGHT_PALETTE = {
    "muted": "#475569",
    "gold": "#9a3412",
    "sky": "#0369a1",
    "teal": "#0f766e",
    "rose": "#b91c1c",
    "green": "#166534",
    "green_strong": "#166534",
    "blue": "#1d4ed8",
    "amber": "#9a3412",
    "amber_soft": "#92400e",
    "red": "#b91c1c",
    "red_soft": "#b91c1c",
    "slate": "#57606a",
    # See DARK_PALETTE: the same roles, chosen for ink-on-paper surfaces.
    "cursor_bg": "#1d4ed8",
    "cursor_fg": "#ffffff",
    "cursor_blur_bg": "#b9c6d6",
    "cursor_blur_fg": "#142033",
    "scrollbar": "#5a6673",
    "scrollbar_hover": "#1d4ed8",
    "scrollbar_active": "#1d4ed8",
    "scrollbar_track": "#e7e1d6",
}

STATUS_COLORS = {
    "healthy": "green",
    "ok": "green_strong",
    "active": "teal",
    "warning": "amber",
    "degraded": "amber_soft",
    "missing": "amber",
    "notice": "sky",
    "info": "sky",
    "debug": "slate",
    "stopped": "amber",
    "inactive": "amber",
    "critical": "red_soft",
    "error": "red",
    "alert": "red",
    "emergency": "red",
    "failed": "red",
    "crash-loop": "rose",
    "unreachable": "rose",
    "unavailable": "slate",
}

ACCENT_GOLD = DARK_PALETTE["gold"]
ACCENT_SKY = DARK_PALETTE["sky"]
ACCENT_TEAL = DARK_PALETTE["teal"]
ACCENT_ROSE = DARK_PALETTE["rose"]
ACCENT_MUTED = DARK_PALETTE["muted"]
ACCENT_GREEN = DARK_PALETTE["green"]
ACCENT_BLUE = DARK_PALETTE["blue"]

_ACCENT_NAMES = {
    "gold": "ACCENT_GOLD",
    "sky": "ACCENT_SKY",
    "teal": "ACCENT_TEAL",
    "rose": "ACCENT_ROSE",
    "muted": "ACCENT_MUTED",
    "green": "ACCENT_GREEN",
    "blue": "ACCENT_BLUE",
}

CURRENT_PALETTE = DARK_PALETTE


# Roles that describe a filled block rather than ink on a surface: a selection
# block or a scrollbar. They are judged against the text they carry, not against
# the panel behind them, so the ink-on-surface test skips them and the chrome
# test covers them.
CHROME_ROLES = frozenset(
    {
        "cursor_bg",
        "cursor_fg",
        "cursor_blur_bg",
        "cursor_blur_fg",
        "scrollbar",
        "scrollbar_hover",
        "scrollbar_active",
        "scrollbar_track",
    }
)


def palette_color(role: str) -> str:
    """The hex for a role in the palette the dashboard is currently drawing with."""
    return CURRENT_PALETTE[role]


def set_palette(theme: str) -> dict:
    """Point every accent name at one palette, and return it.

    Panel markup is built from ACCENT_* at render time, so rebinding those names
    recolours every panel on the next repaint without threading a palette object
    through 360 call sites. Anything that would otherwise keep a stale copy —
    ACTION_STYLES and keyword defaults — stores a role instead, so there is
    nowhere left for a dark hex to survive a switch to light.
    """
    global CURRENT_PALETTE
    CURRENT_PALETTE = LIGHT_PALETTE if theme == "light" else DARK_PALETTE
    for role, name in _ACCENT_NAMES.items():
        globals()[name] = CURRENT_PALETTE[role]
    return CURRENT_PALETTE

ACTION_STYLES = {
    "info": ("Ready", "sky"),
    "running": ("Running", "gold"),
    "success": ("Complete", "green"),
    "warning": ("Attention", "gold"),
    "error": ("Failed", "rose"),
}

VIEW_TITLES = {
    "overview": "Overview",
    "monitor": "Monitor",
    "accounts": "Accounts",
    "backups": "Backups",
    "config": "Config",
    "logs": "Logs",
    "operations": "Operations",
}

VIEW_SUMMARIES = {
    "overview": "Services, host pressure, players, and alerts in one screen.",
    "monitor": "Trends, disk device detail, and per-service resource use.",
    "accounts": "Create accounts; select one for password, GM, ban, and unban.",
    "backups": "Backup health and timer state; select an archive to verify or dry-run.",
    "config": "Read-only view of manager.conf; k re-validates it.",
    "logs": "Recent auth/world events under the current filters; f changes them.",
    "operations": "Maintenance readiness, scheduled tasks, and update planning.",
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
LOG_WINDOW_PATTERN = re.compile(r"^[1-9][0-9]*[mhd]$")
LOG_SEVERITY_PATTERN = re.compile(r"^(all|debug|info|notice|warning|error|critical|alert)$", re.IGNORECASE)
LOG_SOURCE_PATTERN = re.compile(r"^(all|auth|world)$", re.IGNORECASE)
LOG_LIMIT_PATTERN = re.compile(r"^[1-9][0-9]{0,2}$")

TREND_HISTORY_LIMIT = 24
METER_FILLED = "█"
METER_EMPTY = "·"

# Logs filter dropdown options (label, value). The Select widgets in the
# logs filter form offer exactly these; the regex backstays in
# handle_logs_filter_result stay as a dispatch guard.
LOG_FILTER_OPTIONS: dict[str, list[tuple[str, str]]] = {
    "source": [("All sources", "all"), ("Auth", "auth"), ("World", "world")],
    "window": [("5 minutes", "5m"), ("15 minutes", "15m"), ("30 minutes", "30m"), ("1 hour", "1h"), ("6 hours", "6h"), ("12 hours", "12h"), ("1 day", "1d")],
    "severity": [
        ("All severities", "all"),
        ("Debug", "debug"),
        ("Info", "info"),
        ("Notice", "notice"),
        ("Warning", "warning"),
        ("Error", "error"),
        ("Critical", "critical"),
        ("Alert", "alert"),
    ],
    "limit": [("10 events", "10"), ("25 events", "25"), ("50 events", "50"), ("100 events", "100"), ("200 events", "200")],
}

# Below this many rows the Overview and Monitor grids cannot fit both of their
# design-height rows. The second row is `1fr`, so it collapses to a border and
# the panels inside it vanish — an empty frame reads as a crash. Past that
# threshold the grids fall back to natural heights and the view scrolls.
COMPACT_VIEWPORT_HEIGHT = 46
# Below this many rows the sidebar stops fitting, measured rather than guessed: its
# content is 27 rows (head, seven modules, pulse, target) and the column has
# rows - 1 header - 2 padding of its own, so 30 rows is the first height that holds
# all of it. Hiding the Console Target block is the failure mode -- in a 24-row
# terminal that is exactly the block naming the prefix, the config, and the revision
# the buttons act on, and nothing but a mouse wheel brings it back.
SHORT_VIEWPORT_HEIGHT = 30

# Below this many columns, a fixed side panel and a 1fr table cannot both be
# read: at 100 columns the Accounts table is left with roughly twenty columns and
# renders as an empty frame, which looks like a broken console rather than a small
# one. The measured number is where a 1fr pane stops clearing about 30 columns
# once a 40-wide detail panel and the 32-wide sidebar are subtracted.
NARROW_VIEWPORT_WIDTH = 122

# A second column is only worth taking if it can hold the widest row the cards in
# it draw. Measured rather than remembered: the longest line any card produces in
# wide mode is 53 columns (the Monitor process card's cpu/mem/restarts row), and
# the card grids share out what the 32-wide sidebar and the gutters leave over. At
# a 140-column window that handed each Overview card 45 columns and the Monitor's
# process card 37, so those rows wrapped and the card spent a row on the overflow
# -- the same failure the .narrow rule already prevents below 122 columns, at a
# width nobody had probed. Two columns need this much window; below it the grids
# stack and the view scrolls.
TWO_COLUMN_MINIMUM_WIDTH = 158

# Sidebar module rows (view_id, nav key, label). The sidebar items, the
# command-rail Navigate row, and the command palette all derive from this.
SIDEBAR_MODULES: list[tuple[str, str, str]] = [
    ("overview", "1", "Overview"),
    ("monitor", "2", "Monitor"),
    ("accounts", "3", "Accounts"),
    ("backups", "4", "Backups"),
    ("config", "5", "Config"),
    ("logs", "6", "Logs"),
    ("operations", "7", "Ops"),
]
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
    parser.add_argument("--refresh", type=int, default=5, help="Refresh interval in seconds")
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


def run_manager_subprocess(full_command: list[str], env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    """The only subprocess.run call site in the dashboard.

    Every manager CLI interaction — snapshot reads and action writes —
    routes through here so argv construction, environment merging, and
    capture behavior stay uniform.
    """
    command_env = os.environ.copy()
    if env:
        command_env.update(env)
    return subprocess.run(full_command, capture_output=True, text=True, check=False, env=command_env)


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
    env: dict[str, str] | None = None,
) -> dict[str, Any]:
    full_command = [manager_bin, "-c", config_path]
    if use_global_json:
        full_command.extend(["-f", "json"])
    full_command.extend(command)
    completed = run_manager_subprocess(full_command, env=env)

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
        elif parser_mode == "raw":
            data = completed.stdout
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
    color = palette_color(STATUS_COLORS.get(text, "muted"))
    return f"[bold {color}]{text}[/]"


def metric_health_color(value: Any) -> str:
    normalized = str(value or "unknown").strip().lower()
    return palette_color(STATUS_COLORS.get(normalized, "muted"))


def format_flag(
    value: Any,
    *,
    true_text: str = "yes",
    false_text: str = "no",
    true_color: str | None = None,
    false_color: str | None = None,
) -> str:
    # None rather than an ACCENT_* default: a default is evaluated once, at
    # def time, and would keep a dark hex after a switch to light.
    yes = true_color or palette_color("green")
    no = false_color or palette_color("muted")
    if value:
        return f"[bold {yes}]{true_text}[/]"
    return f"[bold {no}]{false_text}[/]"


def truncate_text(value: Any, max_length: int = 76) -> str:
    text = str(value or "")
    if len(text) <= max_length:
        return text
    return f"{text[: max_length - 3]}..."


def escape_markup(value: Any) -> str:
    return str(value or "").replace("[", "\\[").replace("]", "\\]")


LOG_TIMESTAMP_RE = re.compile(
    r"^\s*\[\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:[+-]\d{4}|Z)?\]\s*"
)
LOG_LEVEL_RE = re.compile(
    r"^\s*\[(?:DEBUG|INFO|NOTICE|WARNING|WARN|ERROR|ERR|CRITICAL|CRIT|ALERT|EMERG)\]\s*",
    re.IGNORECASE,
)
LOG_SEVERITY_RE = re.compile(
    r"\[(DEBUG|INFO|NOTICE|WARNING|WARN|ERROR|ERR|CRITICAL|CRIT|ALERT|EMERG)\]",
    re.IGNORECASE,
)
LOG_SEVERITY_RANK = {
    "debug": 0,
    "info": 0,
    "notice": 1,
    "warn": 2,
    "warning": 2,
    "err": 3,
    "error": 3,
    "crit": 4,
    "critical": 4,
    "alert": 5,
    "emerg": 5,
}


def split_log_lines(value: Any) -> list[str]:
    """Turn a captured Manager stderr blob into human message lines.

    Manager's logger prefixes each line with a bracketed timestamp and level.
    A panel quotes one line, so those prefixes are noise — and truncation
    used to cut them mid-timestamp, which is how a fresh host ended up
    reading a message whose tail was a chopped-off clock.
    """
    lines: list[str] = []
    for raw in str(value or "").splitlines():
        line = LOG_LEVEL_RE.sub("", LOG_TIMESTAMP_RE.sub("", raw.strip()))
        if line:
            lines.append(line)
    return lines


def primary_log_line(lines: list[str]) -> str:
    """Pick the line that explains the failure.

    Manager logs the failure and then a follow-up hint, both at `[ERROR]`.
    The message comes first, so severity wins and ties go to the earliest
    line — the hint belongs in the banner's Next step, not the panel body.
    """
    if not lines:
        return "unknown error"
    best_line = lines[0]
    best_rank = -1
    for line in lines:
        match = LOG_SEVERITY_RE.search(line)
        rank = LOG_SEVERITY_RANK.get(match.group(1).lower(), 0) if match else 0
        if rank > best_rank:
            best_line, best_rank = line, rank
    return best_line


def error_message_text(value: Any, *, with_suggestion: bool = True) -> str:
    """The human message inside a captured failure, log prefixes removed."""
    raw = str(value or "unknown error")
    message_match = re.search(r'"message":"([^"]+)"', raw)
    suggestion_match = re.search(r'"suggestion":"([^"]+)"', raw)
    if message_match:
        parts = [message_match.group(1)]
        if suggestion_match and with_suggestion:
            parts.append(suggestion_match.group(1))
        return " ".join(parts)
    return primary_log_line(split_log_lines(raw))


def format_error_text(value: Any, max_length: int = 92, *, with_suggestion: bool = True) -> str:
    return escape_markup(
        truncate_text(" ".join(error_message_text(value, with_suggestion=with_suggestion).split()), max_length)
    )


# A host with no usable manager.conf fails *every* backend call with the same
# error. Recognising that state once turns four panels of identical raw log
# noise into one sentence and the command that fixes it.
SETUP_STATE_LABELS = {
    "ready": "configured",
    "missing": "no configuration",
    "unreadable": "configuration not readable",
    "invalid": "configuration invalid",
}
CONFIG_MISSING_MARKERS = (
    "configuration file not found",
    "config file not found",
    "no such file or directory",
)
CONFIG_UNREADABLE_MARKERS = (
    "configuration file is not readable",
    "permission denied",
)


def setup_state_for_error(error_text: Any) -> str:
    """Classify one backend failure as a configuration problem, or ''."""
    message = error_message_text(error_text).lower()
    if any(marker in message for marker in CONFIG_MISSING_MARKERS):
        return "missing"
    if any(marker in message for marker in CONFIG_UNREADABLE_MARKERS):
        return "unreadable"
    return ""


def classify_setup_state(snapshot: dict[str, Any], manager_bin: str = "") -> dict[str, Any]:
    """One verdict for the whole dashboard, plus the command that resolves it."""
    states = []
    detail_source = ""
    for key in ("server", "config_show", "config_validate", "accounts_online"):
        result = snapshot.get(key)
        if isinstance(result, dict) and not result.get("ok", True):
            state = setup_state_for_error(result.get("error", ""))
            if state:
                states.append(state)
                if not detail_source:
                    detail_source = str(result.get("error", ""))

    state = ""
    for candidate in ("missing", "unreadable"):
        if candidate in states:
            state = candidate
            break
    if not states:
        validate = snapshot.get("config_validate")
        if isinstance(validate, dict) and validate.get("ok") and validate.get("data", {}).get("valid") is False:
            state = "invalid"

    if not state:
        return {"state": "ready", "label": SETUP_STATE_LABELS["ready"], "next_step": "", "detail": ""}

    bin_name = manager_bin or "vmangos-manager"
    if state == "missing":
        next_step = (
            f"sudo {bin_name} config create   — or provision the whole host with "
            f"sudo {bin_name} install"
        )
    elif state == "unreadable":
        try:
            operator = getpass.getuser()
        except Exception:
            operator = "<username>"
        next_step = f"sudo {bin_name} config grant --user {operator}"
    else:
        detail = format_error_text(snapshot.get("config_validate", {}).get("error", ""), 160)
        next_step = f"sudo {bin_name} config validate   — {detail}"

    return {
        "state": state,
        "label": SETUP_STATE_LABELS[state],
        "next_step": next_step,
        "bin": bin_name,
        # Message only: the remedy already lives in next_step, and quoting it
        # twice turns the banner headline into a run-on sentence.
        "detail": format_error_text(detail_source, 160, with_suggestion=False),
    }


def is_setup_failure(snapshot: dict[str, Any], error_text: Any) -> bool:
    """True when this error is just the dashboard-wide setup state echoing."""
    state = (snapshot.get("setup") or {}).get("state", "ready")
    return state in ("missing", "unreadable") and setup_state_for_error(error_text) == state


def backend_failure_lines(snapshot: dict[str, Any], result: dict[str, Any], subject: str) -> list[str]:
    """One explanation per failure instead of one per panel.

    While the host is unconfigured, panels say what they are waiting for and
    point at the banner, which carries the single actionable error once.
    """
    error = result.get("error", "unknown error")
    if is_setup_failure(snapshot, error):
        return [f"[{ACCENT_MUTED}]{escape_markup(subject)} — awaiting configuration.[/]"]
    return [f"[bold {ACCENT_ROSE}]{escape_markup(subject)}:[/] {format_error_text(error)}"]


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


def normalize_percent(value: Any) -> float:
    return max(0.0, min(100.0, clamp_float(value)))


def normalize_load_percent(load_value: Any, cores: Any) -> float:
    load_float = max(0.0, clamp_float(load_value))
    core_count = max(1.0, clamp_float(cores, 1.0))
    # Align the bar scale with the same thresholds the backend uses:
    # warning at 1x cores and critical at 2x cores.
    return min(100.0, (load_float / (core_count * 2.0)) * 100.0)


def render_meter(
    value: Any,
    *,
    width: int = 12,
    color: str | None = None,
    show_minimum_for_positive: bool = False,
) -> str:
    color = color or palette_color("green")
    percent = normalize_percent(value)
    filled = int(round((percent / 100.0) * width))
    if show_minimum_for_positive and percent > 0 and filled == 0:
        filled = 1
    filled = max(0, min(width, filled))
    return f"[bold {color}]{METER_FILLED * filled}[/][{ACCENT_MUTED}]{METER_EMPTY * (width - filled)}[/]"


def format_metric_peak(values: list[float | None], metric_key: str) -> str:
    available = [value for value in values if value is not None]
    if not available:
        return "n/a"

    peak = max(available)
    if metric_key == "load":
        return f"{peak:.2f}"
    return f"{peak:.1f}%"


def describe_trend(values: list[float | None], metric_key: str) -> str:
    available = [value for value in values if value is not None]
    if len(available) < 2:
        return "warming"

    delta = available[-1] - available[0]
    threshold = TREND_THRESHOLDS.get(metric_key, 1.0)
    if abs(delta) < threshold:
        return "steady"
    return "rising" if delta > 0 else "easing"


def describe_trend_with_delta(values: list[float | None], metric_key: str) -> str:
    """The direction, and how far it actually went.

    Measured on the demo snapshot, all five host metrics printed the word
    `rising` — cpu had climbed 18.3 points and disk 1.0. Direction without
    distance makes five rows indistinguishable, which is the reason the trend
    column reads as texture instead of information.
    """
    available = [value for value in values if value is not None]
    if len(available) < 2:
        return "warming"
    delta = available[-1] - available[0]
    return f"{describe_trend(values, metric_key)} {delta:+.1f}"


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


def iso_age_seconds(value: Any) -> int | None:
    """Age in seconds of an ISO timestamp; None when missing or unparsable."""
    text = str(value or "")
    if not text:
        return None
    try:
        normalized = text.replace("Z", "+00:00")
        parsed = datetime.fromisoformat(normalized)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return max(0, int((datetime.now(timezone.utc) - parsed).total_seconds()))
    except ValueError:
        return None


# Mirrors RESTORE_SAFETY_BACKUP_MAX_AGE_SECONDS in lib/backup.sh: a live
# restore refuses to overwrite the current databases unless the newest
# backup is at most this old (or --backup-first is passed).
RESTORE_SAFETY_WINDOW_SECONDS = 24 * 3600


def summarize_restore_readiness(snapshot: dict[str, Any]) -> dict[str, Any]:
    """Restore readiness from snapshot data only (no subprocess calls).

    Credentials reflect the dashboard process environment: the CLI sees the
    same env when launched from this session, and a plain shell may have more.
    """
    summary = snapshot.get("backups", {}).get("summary", {})
    latest_age = iso_age_seconds(summary.get("latest_timestamp"))
    within_window = latest_age is not None and latest_age <= RESTORE_SAFETY_WINDOW_SECONDS
    return {
        "credentials_ready": bool(snapshot.get("restore_credentials_ready")),
        "latest_age_seconds": latest_age,
        "within_safety_window": within_window,
    }


def format_age(seconds: int | None) -> str:
    if seconds is None:
        return "unknown"
    if seconds < 60:
        return f"{seconds}s ago"
    if seconds < 3600:
        return f"{seconds // 60}m ago"
    if seconds < 86400:
        return f"{seconds // 3600}h ago"
    return f"{seconds // 86400}d ago"


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


def normalize_logs_query(values: dict[str, Any] | None = None) -> dict[str, str]:
    normalized = normalize_form_values(values)
    return {
        "source": (normalized.get("source") or "all").lower(),
        "window": (normalized.get("window") or "15m").lower(),
        "severity": (normalized.get("severity") or "all").lower(),
        "limit": normalized.get("limit") or "25",
    }


def player_summary(snapshot: dict[str, Any]) -> dict[str, Any]:
    server = snapshot.get("server", {})
    server_data = server.get("data", {}) if server.get("ok") else {}
    player_state = server_data.get("players", {})
    roster = snapshot.get("players", [])
    online_count = clamp_int(player_state.get("online", len(roster)))
    gm_players = [player for player in roster if clamp_int(player.get("gm_level", 0)) > 0]
    gm_names = [str(player.get("username", "")).strip() for player in gm_players if str(player.get("username", "")).strip()]
    gm_summary = ", ".join(gm_names[:3]) if gm_names else "none"
    if len(gm_names) > 3:
        gm_summary = f"{gm_summary} +{len(gm_names) - 3}"
    staff_count = len(gm_players)
    player_count = max(online_count - staff_count, 0)

    if roster:
        roster_source = "online roster"
    elif online_count > 0:
        roster_source = "count-only"
    else:
        roster_source = "empty roster"

    return {
        "online_count": online_count,
        "count_source": str(player_state.get("source", "unavailable") or "unavailable"),
        "roster_count": len(roster),
        "roster_source": roster_source,
        "gm_names": gm_names,
        "gm_summary": gm_summary,
        "staff_count": staff_count,
        "player_count": player_count,
    }


def find_selected_account(snapshot: dict[str, Any], selected_account_id: str) -> dict[str, Any] | None:
    accounts = snapshot.get("all_accounts", [])
    if selected_account_id:
        for account in accounts:
            if str(account.get("id", "")) == selected_account_id:
                return account
    return accounts[0] if accounts else None


def latest_backup_entry(entries: list[dict[str, Any]]) -> dict[str, Any] | None:
    return max(entries, key=lambda item: str(item.get("timestamp", ""))) if entries else None


def find_selected_backup(snapshot: dict[str, Any], selected_backup_file: str) -> dict[str, Any] | None:
    entries = snapshot.get("backups", {}).get("entries", [])
    if selected_backup_file:
        for entry in entries:
            if str(entry.get("file", "")) == selected_backup_file:
                return entry
    return latest_backup_entry(entries)


def find_selected_schedule(snapshot: dict[str, Any], selected_schedule_id: str) -> dict[str, Any] | None:
    entries = snapshot.get("schedules", [])
    if selected_schedule_id:
        for entry in entries:
            if str(entry.get("id", "")) == selected_schedule_id:
                return entry
    return entries[0] if entries else None


def log_entry_key(entry: dict[str, Any]) -> str:
    return "|".join(
        [
            str(entry.get("timestamp", "") or ""),
            str(entry.get("source", "") or ""),
            str(entry.get("message", "") or ""),
        ]
    )


def find_selected_log_entry(snapshot: dict[str, Any], selected_log_key: str) -> dict[str, Any] | None:
    entries = snapshot.get("log_events", [])
    if selected_log_key:
        for entry in entries:
            if log_entry_key(entry) == selected_log_key:
                return entry
    return entries[0] if entries else None


def natural_sort_key(text: str) -> list[tuple[int, object]]:
    """Sort key that orders embedded digit runs numerically ("1000" > "999")."""
    return [
        (0, int(part)) if part.isdigit() else (1, part)
        for part in re.split(r"(\d+)", text.lower())
    ]


class SelectionTable:
    """Single implementation of the select-a-row DataTable pattern.

    rebuild() re-renders rows, preserves the current selection by key when
    it still exists, moves the cursor without animation, and returns the
    selected entry so the caller can refresh its detail pane. Callers
    pre-sort entries; the controller never reorders them unless the user
    picked a sort column (set_sort), which applies after the substring
    filter (set_filter).
    """

    def __init__(self, table: Any, titles: list[str] | None = None) -> None:
        self.table = table
        self.titles = list(titles or [])
        self._rendered: tuple[tuple[str, tuple[str, ...]], ...] | None = None
        self.filter_text = ""
        self.sort_column: int | None = None
        self._frame_height: Any = None
        self._height_retry_pending = False

    def set_filter(self, text: str) -> None:
        normalized = text.strip().lower()
        if normalized == self.filter_text:
            return
        self.filter_text = normalized
        # A filter change must redraw even when the underlying data did not.
        self._rendered = None

    def set_sort(self, column_index: int | None) -> None:
        if column_index == self.sort_column:
            return
        self.sort_column = column_index
        self._rendered = None
        self.apply_sort_indicator()

    # A table is the one widget on this dashboard allowed a height it did not
    # earn, because a roster longer than the window has to scroll itself: the view
    # cannot follow a cursor that moves inside a widget. The other half of that
    # rule was missing. `#accounts-table { height: 1fr }` hands a realm with eight
    # accounts a 29-row table inside a 31-row frame at 140x52 — measured with
    # `ops/tools/dashboard_probe_roster_frames.py`, 21 rows of bordered nothing,
    # the same shape under a two-row schedule list and under six log events.
    ROSTER_FRAME_TOLERANCE = 3

    def apply_frame_height(self, row_count: int) -> None:
        """Give a roster as much frame as its rows need, and no more.

        Short roster: the table gets its rows plus a header, so the panel stops at
        the last row instead of stretching to the window. Long roster: it keeps
        filling and scrolls internally, which is what the arrow keys, the cursor,
        and the search box depend on. Between those two, a table is never shorter
        than the pane sitting beside it in the same row: two ragged edges inside
        one border look like a bug even when each half is sized correctly.

        The window this is measured against is the **view**, not the panel: the
        panel's own height is the thing this method changes, and a first attempt
        that compared against it flapped — once the frame had shrunk, the next
        refresh concluded the roster no longer fit and stretched it back out. The
        view's height is set by the screen and does not move when a roster does.
        """
        panel = self.table.parent
        if panel is None:
            return
        wanted = row_count + 1  # the header row is content too
        beside = 0
        # `styles.layout` is a layout object (`<horizontal>`), not its name: the
        # first version of this compared it to a string, was always false, and left
        # the Operations roster shorter than the pane beside it.
        if type(getattr(panel.styles, "layout", None)).__name__ == "HorizontalLayout":
            beside = max(
                (
                    sibling.content_size.height
                    for sibling in panel.children
                    if sibling is not self.table and sibling.display != "none"
                ),
                default=0,
            )
        view = next(
            (node for node in self.table.ancestors_with_self if node.has_class("view")),
            None,
        )
        available = (
            view.content_size.height if view is not None else panel.content_size.height
        )
        if available <= 0:
            # Nothing has been laid out yet — a view that is hidden, or an app that
            # has not drawn its first frame. Measuring nothing here is how an
            # eight-row roster got the long-roster posture: zero rows is always
            # fewer than the rows it needs, so the table filled a window that was
            # not on screen. Ask again once there is a frame to measure.
            if not self._height_retry_pending:
                self._height_retry_pending = True
                self.table.call_after_refresh(lambda: self.retry_frame_height(row_count))
            return
        if wanted + self.ROSTER_FRAME_TOLERANCE >= available:
            height: Any = "1fr"
        else:
            height = max(wanted, beside)
            if beside > wanted and not self._height_retry_pending:
                # The height came from a pane whose text is rendered after this
                # table is: at the moment of the rebuild it still held the previous
                # selection's lines. One more pass, once the pane has been written.
                self._height_retry_pending = True
                self.table.call_after_refresh(lambda: self.retry_frame_height(row_count))
        if height == self._frame_height:
            return
        self._frame_height = height
        self.table.styles.height = height

    def retry_frame_height(self, row_count: int) -> None:
        """Decide again, now that the layout has been drawn at least once."""
        self._height_retry_pending = False
        self.apply_frame_height(row_count)

    def apply_sort_indicator(self) -> None:
        if not self.titles:
            return
        for index, column in enumerate(self.table.columns.values()):
            title = self.titles[index] if index < len(self.titles) else str(column.label)
            column.label = f"{title} ▲" if index == self.sort_column else title

    def rebuild(
        self,
        entries: list[dict[str, Any]],
        *,
        key_fn: Callable[[dict[str, Any]], str],
        row_fn: Callable[[dict[str, Any]], list[str]],
        current_key: str,
    ) -> tuple[str, dict[str, Any] | None]:
        rows = [
            (key_fn(entry), tuple(row_fn(entry)), entry)
            for entry in entries
        ]
        if self.filter_text:
            rows = [row for row in rows if self.filter_text in " ".join(row[1]).lower()]
        if self.sort_column is not None and rows and self.sort_column < len(rows[0][1]):
            column = self.sort_column
            # Ties break on the first column (ID/timestamp) so equal keys
            # get a deterministic, sensible order instead of caller order.
            rows.sort(
                key=lambda row: (
                    natural_sort_key(str(row[1][column])),
                    natural_sort_key(str(row[1][0])),
                )
            )
        rendered = tuple((key, cells) for key, cells, _entry in rows)
        self.apply_frame_height(len(rendered))

        if self._rendered is not None and rendered == self._rendered:
            # Data unchanged: leave the table (and the user's cursor) alone.
            # Detail panes still refresh from the returned entry.
            selected = next((entry for _key, _cells, entry in rows if _key == current_key), None)
            return (current_key if selected is not None else "", selected)

        self._rendered = rendered
        self.table.clear(columns=False)

        selected_index = 0
        selected: dict[str, Any] | None = None
        for index, (key_value, row_values) in enumerate(rendered):
            if current_key and key_value == current_key:
                selected_index = index
                selected = next((entry for _key, _cells, entry in rows if _key == key_value), None)
            self.table.add_row(*row_values, key=key_value)

        if not rendered:
            return "", None

        if selected is None:
            selected_key = rendered[selected_index][0]
            selected = next((entry for _key, _cells, entry in rows if _key == selected_key), None)
        self.table.move_cursor(row=selected_index, column=0, animate=False)
        return (key_fn(selected) if selected is not None else "", selected)


def fit_rail_row(
    prefix: tuple[str, str],
    items: list[tuple[str, str]],
    width: int,
    separator: str = "  ",
) -> str:
    """Pack whole markup/plain pairs into lines no wider than ``width`` cells.

    The rail is a Static, so a row longer than its content area is word-wrapped by
    the renderer, and the renderer breaks between a key and the word that explains
    it. Measured, not assumed: at 100x36 the Overview rail drew "This View o roster
    ... b backup v" and then "verify k validate" on the next line. A lone key glyph
    at the end of a line points at nothing, and the label that opens the next line
    reads like a key. A non-breaking space does not help -- probed against the wrap
    actually in use, the splitter treats U+00A0 as whitespace like any other space,
    so it moved the break but did not remove it.

    Given the width, the wrapping is done here instead, and a pair is the smallest
    thing that may move to the next line. Continuation lines are indented to the
    first pair so the legend still reads as one row. Without a width (the first
    paint, before any layout) the row is left as one line and the renderer decides,
    which is what happened for every release before this one.
    """
    if not items:
        return prefix[0]
    if width <= 0:
        return prefix[0] + separator.join(markup for markup, _ in items)

    indent = " " * len(prefix[1])
    lines: list[str] = []
    current = prefix[0]
    used = len(prefix[1])
    sep_width = len(separator)
    for markup, plain in items:
        # The label is padded to the shared column already, so the first pair on the
        # first line hangs from it with no extra gap; only later pairs pay it.
        gap = 0 if (used == len(prefix[1]) and not lines) else sep_width
        if used + gap + len(plain) <= width:
            current += separator[:gap] + markup
            used += gap + len(plain)
            continue
        lines.append(current.rstrip())
        current = (indent if len(indent) else "") + markup
        used = len(indent) + len(plain)
    lines.append(current.rstrip())
    return "\n".join(lines)


RAIL_LABEL_COLUMN = 10


def rail_label(text: str) -> tuple[str, str]:
    """The sky-coloured name that opens a rail row, padded to the shared column.

    Returned as (markup, plain) because the packer needs both: the markup to emit
    and the plain cell count to spend against the width.
    """
    plain = text.ljust(RAIL_LABEL_COLUMN)
    return f"[bold {ACCENT_SKY}]{text}[/]" + " " * (RAIL_LABEL_COLUMN - len(text)), plain


def format_command_tokens(
    tokens: list[tuple[str, str]],
    *,
    width: int = 0,
    prefix: tuple[str, str] = ("", ""),
) -> str:
    """Key/label pairs for one rail row, wrapped between pairs when a width is known."""
    items = [
        (f"[bold {ACCENT_GOLD}]{key}[/] {label}", f"{key} {label}")
        for key, label in tokens
    ]
    if not items:
        return prefix[0]
    if width <= 0:
        return prefix[0] + "  ".join(markup for markup, _ in items)
    # Two spaces between pairs is the readable form; a single space is tried only
    # when the roomy form would cost the rail a row of its own, because a row the
    # rail grows by is a row the cards below the fold lose.
    roomy = fit_rail_row(prefix, items, width, separator="  ")
    tight = fit_rail_row(prefix, items, width, separator=" ")
    return tight if len(tight.splitlines()) < len(roomy.splitlines()) else roomy


# Single source of truth for which command keys are active in which view.
# The command rail advertises exactly these keys, and the per-view containers
# install exactly these bindings — the rail and the keyboard can no longer
# disagree.
KEY_ACTION_DESCRIPTIONS: dict[str, tuple[str, str, str]] = {
    "o": ("open_online_roster", "Roster", "roster"),
    "s": ("start_server", "Start", "start"),
    "x": ("stop_server", "Stop", "stop"),
    "R": ("restart_server", "Restart", "restart"),
    "b": ("backup_now", "Backup", "backup"),
    "v": ("verify_selected_backup", "Verify", "verify"),
    "c": ("create_account", "Create", "create"),
    "p": ("reset_account_password", "Password", "reset password"),
    "g": ("set_account_gm", "Set GM", "set GM"),
    "n": ("ban_account", "Ban", "ban"),
    "u": ("unban_account", "Unban", "unban"),
    "l": ("rotate_logs", "Rotate Logs", "rotate"),
    "T": ("test_logs_config", "Test Config", "test config"),
    "h": ("create_honor_schedule", "Schedule Maintenance", "maintenance"),
    "m": ("create_restart_schedule", "Schedule Restart", "restart"),
    "P": ("refresh_update_plan", "Update Plan", "plan"),
    "d": ("restore_selected_backup_dry_run", "Dry Run", "restore dry-run"),
    "y": ("schedule_daily_backup", "Daily", "daily timer"),
    "w": ("schedule_weekly_backup", "Weekly", "weekly timer"),
    "j": ("cancel_selected_schedule", "Remove Task", "remove task"),
    "k": ("validate_config", "Validate", "validate config"),
    "f": ("filter_logs", "Filters", "filters"),
    "/": ("table_search", "Search", "search"),
    "S": ("sort_table", "Sort", "sort"),
}

# The same letter does a different job in two views: "p" resets an account's
# password in Accounts and runs a restore preflight in Backups. A single table
# keyed by character cannot hold both -- the literal silently kept whichever came
# last, which left the Accounts view advertising and binding a backup action while
# its password reset had no key at all. Views that disagree declare it here.
VIEW_KEY_ACTIONS: dict[str, dict[str, tuple[str, str, str]]] = {
    "backups": {
        "p": ("restore_selected_backup_preflight", "Preflight", "restore preflight"),
    },
}


def action_entry(view_id: str, key: str) -> tuple[str, str, str]:
    """The (action, label, token) triple for one key in one view.

    Everything the dashboard says about a key -- the command rail, the banner's
    "This View" row, and the binding actually installed on the view container --
    has to come from here, or the keyboard and the legend drift apart.
    """
    return VIEW_KEY_ACTIONS.get(view_id, {}).get(key, KEY_ACTION_DESCRIPTIONS[key])


VIEW_KEYS: dict[str, list[str]] = {
    "overview": ["o", "s", "x", "R", "b", "v", "k"],
    "monitor": ["o", "s", "x", "R", "b", "v"],
    "accounts": ["c", "p", "g", "n", "u", "/", "S"],
    "backups": ["b", "v", "d", "p", "y", "w", "/", "S"],
    "operations": ["h", "m", "j", "P", "T", "l", "/", "S"],
    "config": ["k"],
    "logs": ["f", "/", "S"],
}


# The command rail's "This View" row is the only place the view's own keys are
# spelled out, so it is the row that must survive a small terminal. In the narrow
# form each token carries the shortest wording that still says what the key does;
# the wording differs, the actions do not.
#
# Keyed by action, not by letter. "p" resets a password in Accounts and rehearses
# a restore in Backups, so a shorter word attached to the letter would put the
# wrong action's name next to the key -- the same mistake the key table made.
NARROW_ACTION_TOKENS: dict[str, str] = {
    "restore_selected_backup_dry_run": "dry-run",
    "restore_selected_backup_preflight": "preflight",
    "validate_config": "validate",
    "schedule_daily_backup": "daily",
    "schedule_weekly_backup": "weekly",
    "cancel_selected_schedule": "remove",
    "test_logs_config": "test",
    "create_honor_schedule": "maint",
}


# A stacked view is taller than the window that holds it, and Textual hands that
# overflow to the mouse wheel alone. On a 140-column terminal -- the width the
# README screenshot is taken at -- the Overview needs 61 rows inside a 35-row
# view, so the Alerts card sits 26 rows past the fold and an operator with a
# keyboard and no wheel never learns it exists. These keys go on every view
# container so the cards below the fold can be reached, and the command rail
# says so with the number of rows still out of sight, measured from the layout
# rather than guessed.
#
# They belong to the view container and not the app: a modal is a separate
# screen, so a scroll key over a form can never move the view underneath it, and
# in a table view the table has focus and keeps its own cursor keys, because
# Textual resolves bindings from the focused widget outward.
VIEW_SCROLL_KEYS: list[tuple[str, str, str]] = [
    ("up", "scroll_view_up", "Scroll Up"),
    ("down", "scroll_view_down", "Scroll Down"),
    ("pageup", "scroll_view_page_up", "Page Up"),
    ("pagedown", "scroll_view_page_down", "Page Down"),
    ("home", "scroll_view_home", "To Top"),
    ("end", "scroll_view_end", "To Bottom"),
]

# Spelled the way a terminal labels those keys, because unlike a command key the
# name of the key is the whole of what it does: "pageup page" would be two words
# for one idea, and this row has to stay short enough to fit beside the count.
SCROLL_RAIL_TOKENS: tuple[str, ...] = ("↑", "↓", "PgUp", "PgDn", "Home", "End")

# A focused table binds those same six keys for its own cursor, and a focused
# search box binds Home and End for its own caret. Bindings resolve from the
# focused widget outward, so in those windows the view never hears the key and the
# rail would be advertising a scroll that a table is quietly eating. Measured off
# Textual 0.89's DataTable.BINDINGS and Input.BINDINGS -- the same measurement the
# test re-takes, because this is a claim about a dependency and not about this file.
SCROLL_KEYS_CLAIMED_BY_TABLE: frozenset[str] = frozenset(
    {"up", "down", "pageup", "pagedown", "home", "end"}
)
SCROLL_KEYS_CLAIMED_BY_SEARCH: frozenset[str] = frozenset({"home", "end"})


def scroll_rail_tokens(focused: object) -> tuple[str, ...]:
    """Which scroll keys the rail may name, given what has focus right now."""
    from textual.widgets import DataTable, Input  # local: as in the app factory, so the
    # render layer stays importable by code that never opens a terminal.

    claimed: frozenset[str] = frozenset()
    if isinstance(focused, DataTable):
        claimed = SCROLL_KEYS_CLAIMED_BY_TABLE
    elif isinstance(focused, Input):
        claimed = SCROLL_KEYS_CLAIMED_BY_SEARCH
    return tuple(
        token
        for (key, _action, _description), token in zip(VIEW_SCROLL_KEYS, SCROLL_RAIL_TOKENS)
        if key not in claimed
    )


def scroll_rail_row(
    rows_above: int,
    rows_below: int,
    tokens: tuple[str, ...] | None = None,
    width: int = 0,
) -> str:
    """The rail row that says this view has more in it, and how to reach it.

    Returns "" when the view fits: a legend for a scroll that cannot happen is a
    promise the layout would break, and it costs a row the cards could use.

    ``tokens`` names the keys that will actually reach the view from here; left
    unset it names all of them. When the focused widget has claimed every one -- a
    table answers the arrows itself -- the row says who holds them instead of
    inventing a binding, because a legend is a promise about a keypress.
    """
    parts = []
    if rows_above > 0:
        parts.append(f"{rows_above} row{'s' if rows_above != 1 else ''} above")
    if rows_below > 0:
        parts.append(f"{rows_below} row{'s' if rows_below != 1 else ''} below")
    if not parts:
        return ""
    if tokens is None:
        tokens = SCROLL_RAIL_TOKENS
    # None means "name every scroll key"; an empty tuple means a focused widget is
    # keeping them, which is a different answer and must not collapse into the first
    # one -- an early version of this packing used ``tokens or SCROLL_RAIL_TOKENS``,
    # and the suite caught a focused table being offered arrows it would never see.
    chosen = SCROLL_RAIL_TOKENS if tokens is None else tuple(tokens)
    items: list[tuple[str, str]] = [
        (f"[bold {ACCENT_GOLD}]{token}[/]", token) for token in chosen
    ]
    if not items:
        items = [(f"[{ACCENT_MUTED}]the table keeps the arrow keys[/]", "the table keeps the arrow keys")]
    # The count travels as one item: "21 rows below" split across a line break would
    # leave the number orphaned from what it counts.
    items.append((f"[{ACCENT_MUTED}]{' · '.join(parts)}[/]", " · ".join(parts)))
    return fit_rail_row(rail_label("Scroll"), items, width)


def view_command_tokens(active_view: str, narrow: bool = False) -> list[tuple[str, str]]:
    keys = VIEW_KEYS.get(active_view, VIEW_KEYS["overview"])
    tokens = []
    for key in keys:
        entry = action_entry(active_view, key)
        label = NARROW_ACTION_TOKENS.get(entry[0], entry[2]) if narrow else entry[2]
        tokens.append((key, label))
    return tokens


def make_view_bindings(view_id: str) -> list[tuple[str, str, str]]:
    return [
        # "app." prefix: the binding lives on the view container, but the
        # action method lives on the App class.
        (key, f"app.{action_entry(view_id, key)[0]}", action_entry(view_id, key)[1])
        for key in VIEW_KEYS.get(view_id, [])
    ] + [
        # Same arrangement for the scroll keys: the letter is only live while
        # this view is the focused one, and the App does the moving so it can
        # repaint the rail's count in the same breath.
        (key, f"app.{action}", description)
        for key, action, description in VIEW_SCROLL_KEYS
    ] + (
        # Escape clears the table search when one is open in this view.
        [("escape", "app.table_search_escape", "Clear Search")]
        if view_id in TABLE_VIEW_SEARCH_IDS
        else []
    )


TABLE_VIEW_SEARCH_IDS: dict[str, str] = {
    "accounts": "accounts-search",
    "backups": "backups-search",
    "logs": "logs-search",
    "operations": "schedules-search",
}

TABLE_VIEW_SELECTION_KEYS: dict[str, str] = {
    "accounts": "accounts",
    "backups": "backups",
    "logs": "logs",
    "operations": "schedules",
}

SEARCH_INPUT_TO_SELECTION: dict[str, str] = {
    search_id: selection_key for selection_key, search_id in TABLE_VIEW_SEARCH_IDS.items()
}


def render_command_rail(
    active_view: str,
    narrow: bool = False,
    rows_above: int = 0,
    rows_below: int = 0,
    scroll_tokens: tuple[str, ...] | None = None,
    width: int = 0,
) -> str:
    """The key legend under every view.

    In the narrow form the Navigate row is dropped: the Modules list in the
    sidebar already names every view with the key that opens it, one line each,
    and repeating those seven tokens across the content column is what wrapped and
    pushed the view's own actions out of the box. The row that carries the actions
    possible *here* is the one that stays.

    The Scroll row appears only when the caller -- which reads it from the live
    layout -- reports rows sitting outside the window, so a window that fits
    everything does not advertise a scroll it cannot perform. Which keys the row
    names is the caller's business too: a focused table answers the arrows itself,
    and the legend quotes the keys this window will honour, not the ones some other
    widget has already taken.
    """
    global_label = rail_label("Global")
    view_label = rail_label("This View")
    global_actions = format_command_tokens(
        [("r", "refresh"), ("t", "theme"), ("q", "quit")], width=width, prefix=global_label
    )
    context_actions = format_command_tokens(
        view_command_tokens(active_view, narrow=narrow), width=width, prefix=view_label
    )
    if narrow:
        rows = [global_actions, context_actions]
    else:
        navigation = format_command_tokens(
            [(key, label.lower()) for _view, key, label in SIDEBAR_MODULES],
            width=width,
            prefix=rail_label("Navigate"),
        )
        rows = [navigation, global_actions, context_actions]
    scroll_row = scroll_rail_row(rows_above, rows_below, scroll_tokens, width=width)
    if scroll_row:
        rows.append(scroll_row)
    return "\n".join(rows)


def validate_command_form_values(action_name: str, values: dict[str, Any]) -> str:
    """Field validation for command forms, shared by the modal (inline
    errors before dismissal) and build_dashboard_action_request (the
    authoritative backstop for every dispatch path). Returns a
    human-readable error, or "" when the values pass."""
    if action_name == "account_create":
        if not USERNAME_PATTERN.fullmatch(values.get("username", "")):
            return "account create skipped: username must be 2-32 alphanumeric characters"
        if len(values.get("password", "")) < 6 or len(values.get("password", "")) > 32:
            return "account create skipped: password must be 6-32 characters"
        if values.get("password", "") != values.get("confirm_password", ""):
            return "account create skipped: passwords do not match"
    elif action_name == "account_password":
        if len(values.get("password", "")) < 6 or len(values.get("password", "")) > 32:
            return "password reset skipped: password must be 6-32 characters"
        if values.get("password", "") != values.get("confirm_password", ""):
            return "password reset skipped: passwords do not match"
    elif action_name == "account_setgm":
        if not GM_LEVEL_PATTERN.fullmatch(values.get("gm_level", "")):
            return "set GM skipped: GM level must be 0, 1, 2, or 3"
    elif action_name == "account_ban":
        if not DURATION_PATTERN.fullmatch(values.get("duration", "")):
            return "account ban skipped: duration must use forms like 30m, 12h, or 7d"
        if not BAN_REASON_PATTERN.fullmatch(values.get("reason", "")):
            return "account ban skipped: reason must use letters, numbers, and spaces only"
    elif action_name == "backup_schedule_daily":
        if not DAILY_TIME_PATTERN.fullmatch(values.get("time", "")):
            return "backup schedule skipped: daily time must use HH:MM in 24-hour format"
    elif action_name == "backup_schedule_weekly":
        if not WEEKLY_SCHEDULE_PATTERN.fullmatch(values.get("schedule", "")):
            return "backup schedule skipped: weekly value must use 'Mon 04:00' style format"
    elif action_name in ("schedule_honor_create", "schedule_restart_create"):
        schedule_type = values.get("schedule_type", "").lower()
        if not SCHEDULE_TYPE_PATTERN.fullmatch(schedule_type):
            return "schedule create skipped: type must be daily or weekly"
        if not DAILY_TIME_PATTERN.fullmatch(values.get("time", "")):
            return "schedule create skipped: time must use HH:MM in 24-hour format"
        if schedule_type == "weekly" and not DAY_NAME_PATTERN.fullmatch(values.get("day", "")):
            return "schedule create skipped: weekly schedules require a day like Sun"
        timezone_value = values.get("timezone", "")
        if timezone_value and not re.fullmatch(r"^[A-Za-z0-9_+./-]+$", timezone_value):
            return "schedule create skipped: timezone contains unsupported characters"
        if action_name == "schedule_restart_create":
            warnings_value = values.get("warnings", "")
            if warnings_value and not WARNINGS_PATTERN.fullmatch(warnings_value):
                return "schedule create skipped: warnings must use comma-separated minutes like 30,15,5,1"
    return ""


def build_dashboard_action_request(
    snapshot: dict[str, Any],
    selected_account_id: str,
    selected_backup_file: str,
    selected_schedule_id: str,
    action_name: str,
    form_values: dict[str, Any] | None = None,
) -> dict[str, Any]:
    values = normalize_form_values(form_values)

    # Field validation is shared with the form modal; selection-dependent
    # guards (no account/backup/task selected) stay below, per action.
    form_error = validate_command_form_values(action_name, values)
    if form_error:
        return {"error": form_error}

    if action_name == "account_create":
        username = values.get("username", "")
        password = values.get("password", "")
        return {
            "label": f"account create {username}",
            "command": ["account", "create", username, "--password-env"],
            "env": {"VMANGOS_PASSWORD": password},
            "refresh_after": True,
            "view": "accounts",
            "feedback": {
                "success_receipt": f"Created account {username}.",
                "success_next": "Stay in Accounts to set GM access, reset the password again, or ban the account if needed.",
                "failure_next": "Check username policy and auth DB connectivity, then retry from Accounts.",
            },
        }

    if action_name == "config_validate":
        return {
            "label": "config validate",
            "command": ["config", "validate"],
            "env": {},
            "refresh_after": True,
            "view": "config",
            "feedback": {
                "success_receipt": "Re-read manager.conf and re-checked it against the current host.",
                "success_next": "If validation still looks wrong, fix manager.conf or .dbpass in the shell and re-run validation here.",
                "failure_next": "Review manager.conf and .dbpass in the shell, then validate again from Config.",
            },
        }

    if action_name == "logs_rotate":
        return {
            "label": "logs rotate",
            "command": ["logs", "rotate"],
            "env": {},
            "refresh_after": True,
            "view": "operations",
            "feedback": {
                "success_receipt": "Requested a log rotation cycle for the realm host.",
                "success_next": "Review Maintenance Readiness after refresh to confirm rotation posture and disk headroom.",
                "failure_next": "Check logrotate config and permissions, then retry from Operations.",
            },
        }

    if action_name == "logs_test_config":
        return {
            "label": "logs test-config",
            "command": ["logs", "test-config"],
            "env": {},
            "refresh_after": False,
            "view": "operations",
            "feedback": {
                "success_receipt": "Validated the current log rotation configuration.",
                "success_next": "If readiness still looks risky here, inspect log config in the shell before the next maintenance window.",
                "failure_next": "Fix log rotation config in the shell, then rerun the test from Operations.",
            },
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
            return {
                "label": f"account password {username}",
                "command": ["account", "password", username, "--password-env"],
                "env": {"VMANGOS_PASSWORD": password},
                "refresh_after": True,
                "view": "accounts",
                "feedback": {
                    "success_receipt": f"Reset the password for {username}.",
                    "success_next": "Deliver the new credential out-of-band, then use the selected account row to confirm other access state if needed.",
                    "failure_next": f"Retry the password reset for {username} from Accounts after correcting the input or auth DB issue.",
                },
            }

        if action_name == "account_setgm":
            gm_level = values.get("gm_level", "")
            return {
                "label": f"account setgm {username}",
                "command": ["account", "setgm", username, gm_level],
                "env": {},
                "refresh_after": True,
                "view": "accounts",
                "feedback": {
                    "success_receipt": f"Set GM level {gm_level} for {username}.",
                    "success_next": "Let the Accounts table refresh, then confirm the new GM level in the selected row.",
                    "failure_next": f"Review the selected account and GM level input for {username}, then retry from Accounts.",
                },
            }

        if action_name == "account_ban":
            duration = values.get("duration", "")
            reason = values.get("reason", "")
            return {
                "label": f"account ban {username}",
                "command": ["account", "ban", username, duration, "--reason", reason],
                "env": {},
                "refresh_after": True,
                "view": "accounts",
                "feedback": {
                    "success_receipt": f"Banned {username} for {duration}.",
                    "success_next": "Let Accounts refresh, then confirm the banned state before moving on to other moderation work.",
                    "failure_next": f"Review the duration and reason for {username}, then retry the ban from Accounts.",
                },
            }

        if action_name == "account_unban":
            return {
                "label": f"account unban {username}",
                "command": ["account", "unban", username],
                "env": {},
                "refresh_after": True,
                "view": "accounts",
                "feedback": {
                    "success_receipt": f"Removed active bans for {username}.",
                    "success_next": "Let Accounts refresh, then confirm the banned flag is cleared for the selected account.",
                    "failure_next": f"Retry the unban for {username} from Accounts after checking auth DB connectivity.",
                },
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
                "feedback": {
                    "success_receipt": f"Completed a restore dry-run for {backup_file}.",
                    "success_next": "Review the plan, then press p for the full preflight; live restore stays in the CLI and only runs during an approved recovery window.",
                    "failure_next": "Inspect the archive path and backup health, then retry the dry-run from Backups.",
                },
            }

        if action_name == "backup_restore_preflight":
            if backup is None or not backup_dir:
                return {"error": "restore preflight skipped: no backup selected"}
            backup_file = str(backup.get("file", "")).strip()
            if not backup_file:
                return {"error": "restore preflight skipped: selected backup has no file name"}
            backup_path = f"{backup_dir.rstrip('/')}/{backup_file}"
            return {
                "label": f"backup restore preflight {backup_file}",
                "command": ["backup", "restore", backup_path, "--preflight"],
                "env": {},
                "refresh_after": False,
                "view": "backups",
                "feedback": {
                    "success_receipt": f"Restore preflight passed for {backup_file}.",
                    "success_next": "All readiness checks passed; if you decide to recover, run the live restore from the CLI during an approved recovery window.",
                    "failure_next": "Fix the failed checks (credentials, auth probe, or a fresh safety backup via --backup-first), then rerun the preflight from Backups.",
                },
            }

        if action_name == "backup_schedule_daily":
            daily_time = values.get("time", "")
            return {
                "label": f"backup schedule daily {daily_time}",
                "command": ["backup", "schedule", "--daily", daily_time],
                "env": {},
                "refresh_after": True,
                "view": "backups",
                "feedback": {
                    "success_receipt": f"Updated the daily backup schedule for {daily_time}.",
                    "success_next": "Review Timer State after refresh to confirm the next run and overall protection posture.",
                    "failure_next": "Check the requested time and timer permissions, then retry from Backups.",
                },
            }

        if action_name == "backup_schedule_weekly":
            weekly_schedule = values.get("schedule", "")
            return {
                "label": f"backup schedule weekly {weekly_schedule}",
                "command": ["backup", "schedule", "--weekly", weekly_schedule],
                "env": {},
                "refresh_after": True,
                "view": "backups",
                "feedback": {
                    "success_receipt": f"Updated the weekly backup schedule for {weekly_schedule}.",
                    "success_next": "Review Timer State after refresh to confirm the next weekly run and protection posture.",
                    "failure_next": "Check the requested weekly schedule format and retry from Backups.",
                },
            }

    if action_name in ("schedule_honor_create", "schedule_restart_create"):
        schedule_type = values.get("schedule_type", "").lower()
        time_value = values.get("time", "")
        day = values.get("day", "")
        timezone_value = values.get("timezone", "")

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
            "feedback": {
                "success_receipt": (
                    f"Scheduled a {'maintenance task' if action_name == 'schedule_honor_create' else 'restart window'} for {cadence} {timezone_value}".strip()
                ),
                "success_next": "Review Scheduled Tasks after refresh so you can confirm the queue entry, next run, and warnings.",
                "failure_next": "Check the cadence, time, timezone, and warning inputs, then retry from Operations.",
            },
        }

    if action_name == "schedule_cancel":
        schedule = find_selected_schedule(snapshot, selected_schedule_id)
        if schedule is None:
            return {"error": "task removal skipped: no task selected"}
        schedule_id = str(schedule.get("id", "")).strip()
        if not schedule_id:
            return {"error": "task removal skipped: selected task has no id"}
        return {
            "label": f"remove task {schedule_id}",
            "command": ["schedule", "cancel", schedule_id],
            "env": {},
            "refresh_after": True,
            "view": "operations",
            "feedback": {
                "success_receipt": f"Removed scheduled task {schedule_id}.",
                "success_next": "Review the queue after refresh before you create or approve more maintenance work.",
                "failure_next": f"Retry removing {schedule_id} from Operations after checking the selected task.",
            },
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

    latest = latest_backup_entry(entries)
    if latest is None:
        return summary

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
        "setup": {"state": "pending", "label": "starting up", "next_step": "", "detail": ""},
        "server": {"ok": False, "data": {}, "error": error_message},
        "logs": {"ok": False, "data": {}, "error": error_message},
        "realm_logs": {"ok": False, "data": {}, "error": error_message},
        "schedule_list": {"ok": False, "data": {}, "error": error_message},
        "update_check": {"ok": False, "data": {}, "error": error_message},
        "update_inspect": {"ok": False, "data": {}, "error": error_message},
        "accounts_online": {"ok": False, "data": {}, "error": error_message},
        "accounts": {"ok": False, "data": {}, "error": error_message},
        "backup_list": {"ok": False, "data": {}, "error": error_message},
        "backup_schedule_status": {"ok": False, "data": {}, "error": error_message},
        "config_validate": {"ok": False, "data": {}, "error": error_message},
        "config_show": {"ok": False, "data": {}, "error": error_message},
        "config_summary": {},
        "config_content": "",
        "backups": {"entries": [], "summary": {}},
        "players": [],
        "all_accounts": [],
        "log_events": [],
        "schedules": [],
    }


def load_snapshot_fixture(snapshot_file: str) -> dict[str, Any]:
    with open(snapshot_file, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise ValueError("snapshot fixture must be a JSON object")
    # Fixtures render like live hosts, including the setup verdict.
    payload.setdefault("setup", classify_setup_state(payload, ""))
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


# Which snapshot result keys each view keeps fresh; unlisted keys are
# carried over from the previous snapshot (or error-defaults on first
# load). None means "fetch everything" (first load, manual refresh,
# --snapshot-json fixture capture).
VIEW_SNAPSHOT_KEYS: dict[str | None, frozenset[str]] = {
    None: frozenset(
        {
            "server",
            "logs",
            "realm_logs",
            "accounts_online",
            "accounts",
            "schedule_list",
            "update_check",
            "update_inspect",
            "backup_list",
            "backup_schedule_status",
            "config_validate",
            "config_show",
        }
    ),
    "overview": frozenset({"server", "accounts_online"}),
    "monitor": frozenset({"server"}),
    "accounts": frozenset({"accounts_online", "accounts"}),
    "backups": frozenset({"backup_list", "backup_schedule_status", "config_show"}),
    "config": frozenset({"config_validate", "config_show"}),
    "logs": frozenset({"logs", "realm_logs", "schedule_list"}),
    "operations": frozenset({"server", "logs", "schedule_list", "update_check", "update_inspect"}),
}


def not_fetched_result(key: str) -> dict[str, Any]:
    return {"ok": False, "data": {}, "error": f"{key} not fetched for this view", "command": "", "exit_code": -1}


def carry_snapshot_result(
    previous: dict[str, Any] | None,
    key: str,
    needed: bool,
    run_fn: Callable[[], dict[str, Any]],
) -> dict[str, Any]:
    if needed:
        return run_fn()
    carried = (previous or {}).get(key)
    if isinstance(carried, dict) and carried.get("ok"):
        return carried
    return not_fetched_result(key)


def build_snapshot(
    manager_bin: str,
    config_path: str,
    logs_query: dict[str, Any] | None = None,
    view: str | None = None,
    previous: dict[str, Any] | None = None,
) -> dict[str, Any]:
    query = normalize_logs_query(logs_query)
    needed = VIEW_SNAPSHOT_KEYS.get(view, VIEW_SNAPSHOT_KEYS[None])

    def run(command: list[str], *, use_global_json: bool = True) -> dict[str, Any]:
        return run_manager_command(
            manager_bin,
            config_path,
            command,
            parser_mode="envelope",
            use_global_json=use_global_json,
        )

    server = carry_snapshot_result(previous, "server", "server" in needed, lambda: run(["server", "status"]))
    logs = carry_snapshot_result(previous, "logs", "logs" in needed, lambda: run(["logs", "status"]))
    realm_logs = carry_snapshot_result(
        previous,
        "realm_logs",
        "realm_logs" in needed,
        lambda: run(
            [
                "logs",
                "recent",
                "--source",
                query["source"],
                "--window",
                query["window"],
                "--severity",
                query["severity"],
                "--limit",
                query["limit"],
            ]
        ),
    )
    online_accounts = carry_snapshot_result(
        previous, "accounts_online", "accounts_online" in needed, lambda: run(["account", "list", "--online"])
    )
    accounts = carry_snapshot_result(previous, "accounts", "accounts" in needed, lambda: run(["account", "list"]))
    schedules = carry_snapshot_result(previous, "schedule_list", "schedule_list" in needed, lambda: run(["schedule", "list"]))
    update_check = carry_snapshot_result(previous, "update_check", "update_check" in needed, lambda: run(["update", "check"]))
    update_inspect = carry_snapshot_result(previous, "update_inspect", "update_inspect" in needed, lambda: run(["update", "inspect"]))
    backups = carry_snapshot_result(
        previous, "backup_list", "backup_list" in needed, lambda: run(["backup", "list", "--format", "json"], use_global_json=False)
    )
    backup_schedule_status = carry_snapshot_result(
        previous,
        "backup_schedule_status",
        "backup_schedule_status" in needed,
        lambda: run(["backup", "schedule", "status", "--format", "json"], use_global_json=False),
    )
    config_validate = carry_snapshot_result(
        previous,
        "config_validate",
        "config_validate" in needed,
        lambda: run(["config", "validate", "--format", "json"], use_global_json=False),
    )
    config_show = carry_snapshot_result(
        previous, "config_show", "config_show" in needed, lambda: run(["config", "show", "--format", "json"], use_global_json=False)
    )

    config_content = ""
    if config_show["ok"]:
        config_content = str(config_show["data"].get("content", ""))

    config_values = parse_ini_content(config_content)
    backup_entries = backups["data"].get("backups", []) if backups["ok"] else []
    players = online_accounts["data"].get("accounts", []) if online_accounts["ok"] else []
    all_accounts = accounts["data"].get("accounts", []) if accounts["ok"] else []
    log_events = realm_logs["data"].get("events", []) if realm_logs["ok"] else []
    schedule_entries = schedules["data"].get("schedules", []) if schedules["ok"] else []
    backup_dir = config_values.get("backup.backup_dir", "")
    password_file = str(config_values.get("database.password_file", "") or "")
    inline_password = str(config_values.get("database.password", "") or "")
    backup_summary = summarize_backups(backup_entries, backup_dir)
    setup = classify_setup_state(
        {
            "server": server,
            "config_show": config_show,
            "config_validate": config_validate,
            "accounts_online": online_accounts,
        },
        manager_bin,
    )

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
        "setup": setup,
        "server": server,
        "logs": logs,
        "realm_logs": realm_logs,
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
        # Restore credentials are env-only (never in the config); readiness
        # here reflects this dashboard session's environment.
        "restore_credentials_ready": bool(
            os.environ.get("MYSQL_RESTORE_DEFAULTS_FILE") or os.environ.get("MYSQL_RESTORE_PASSWORD")
        ),
        "backups": {
            "entries": backup_entries,
            "summary": backup_summary,
        },
        "players": players,
        "all_accounts": all_accounts,
        "log_events": log_events,
        "schedules": schedule_entries,
    }


def render_action_banner(
    active_view: str,
    snapshot: dict[str, Any],
    last_action: str,
    action_tone: str,
    refresh_interval: int,
    action_receipt: str = "",
    action_next_step: str = "",
    action_view_context: str | None = None,
    setup: dict[str, Any] | None = None,
    narrow: bool = False,
) -> str:
    tone_label, tone_role = ACTION_STYLES.get(action_tone, ACTION_STYLES["info"])
    tone_color = palette_color(tone_role)
    captured_at = escape_markup(iso_to_display(snapshot.get("captured_at")))
    # In a narrow window the banner is the first thing that grows, and every row
    # it takes comes off the table below it. The message is the part that can be
    # shortened without losing the state it reports: the tone label already says
    # whether the last action worked.
    message_room = 44 if narrow else 140
    message = escape_markup(truncate_text(last_action or "dashboard started", message_room))
    receipt = escape_markup(truncate_text(action_receipt or "", 140))
    next_step = escape_markup(truncate_text(action_next_step or "", 140))
    view_title = VIEW_TITLES.get(active_view, active_view.title())
    view_summary = VIEW_SUMMARIES.get(active_view, "")
    show_follow_up = not action_view_context or active_view == action_view_context
    # In a narrow window each wrapped line of this banner comes straight off the
    # table below it, so the banner states the same facts in fewer characters:
    # the view name replaces the "realm console" tag, and the last action is
    # reported by its tone rather than its prose (the Ops view keeps the full
    # receipt, and a failure still reads as one because the tone is red).
    if narrow:
        lines = [
            f"[bold {ACCENT_GOLD}]VMaNGOS Manager[/]  [bold {ACCENT_SKY}]{view_title}[/]  [{ACCENT_MUTED}]refresh[/] {refresh_interval}s",
            f"[{ACCENT_MUTED}]refresh[/] {iso_to_clock(snapshot.get('captured_at'))}  "
            f"[{ACCENT_MUTED}]action[/] [bold {tone_color}]{tone_label}[/]",
        ]
    else:
        lines = [
            f"[bold {ACCENT_GOLD}]VMaNGOS Manager[/]  [{ACCENT_MUTED}]realm console[/]  [bold {ACCENT_SKY}]{view_title}[/]  [{ACCENT_MUTED}]refresh[/] {refresh_interval}s",
            f"[{ACCENT_MUTED}]last refresh[/] {captured_at}  [{ACCENT_MUTED}]last action[/] [bold {tone_color}]{tone_label}[/] [{ACCENT_MUTED}]—[/] {message}",
        ]
    # The footer's "This View" row already names the actions available in the
    # current view, so in a narrow window the prose is the part that goes: it is a
    # restatement, and it costs two to four rows of table.
    if view_summary and not narrow:
        lines.extend(["", f"[bold {ACCENT_SKY}]This View[/] {escape_markup(view_summary)}"])
    # A host that cannot serve data yet gets one explanation here, not one
    # per panel — and the command that resolves it.
    setup_state = (setup or {}).get("state", "ready")
    if setup_state not in ("ready", "pending"):
        label = str((setup or {}).get("label", ""))
        detail = str((setup or {}).get("detail", ""))
        headline = f"{label} — {detail}" if detail else label
        lines.extend(["", f"[bold {ACCENT_ROSE}]Setup[/] {escape_markup(truncate_text(headline, 150))}"])
        setup_next = str((setup or {}).get("next_step", ""))
        if setup_next:
            lines.append(f"[{ACCENT_MUTED}]Next[/] {escape_markup(truncate_text(setup_next, 150))}")
    if show_follow_up and receipt:
        lines.append(f"[{ACCENT_MUTED}]Receipt[/] {receipt}")
    if show_follow_up and next_step:
        lines.append(f"[{ACCENT_MUTED}]Next[/] {next_step}")
    return "\n".join(lines)


def fetch_release_info(manager_bin: str, config_path: str) -> dict[str, Any]:
    """Ask the CLI what it is, so the dashboard can say the same thing.

    The TUI used to have no idea which Manager build it was driving, which is
    the same identity gap that made a deployed host unverifiable.
    """
    result = run_manager_command(manager_bin, config_path, ["--version"], parser_mode="raw")
    release = {"version": "", "build": "", "available": bool(result["ok"])}
    if not result["ok"]:
        return release
    for line in str(result["data"]).splitlines():
        line = line.strip()
        match = re.search(r"version\s+([0-9][\w.\-]*)", line)
        if match and not release["version"]:
            release["version"] = match.group(1)
        elif line.startswith("build:"):
            release["build"] = line[len("build:"):].strip()
    return release


def render_sidebar_head(
    release: dict[str, Any] | None = None,
    setup: dict[str, Any] | None = None,
) -> str:
    release = release or {}
    setup = setup or {}
    lines = [f"[bold {ACCENT_GOLD}]VMaNGOS Manager[/]"]
    version = release.get("version", "") if release else ""
    if version:
        lines.append(f"[{ACCENT_MUTED}]release[/] [bold {ACCENT_SKY}]{escape_markup(version)}[/]")
    state = (setup or {}).get("state", "ready")
    if state not in ("ready", "pending"):
        lines.append(f"[bold {ACCENT_ROSE}]![/] [{ACCENT_MUTED}]{escape_markup((setup or {}).get('label', ''))}[/]")
    lines.extend(["", f"[bold {ACCENT_SKY}]Modules[/]"])
    return "\n".join(lines)


def render_sidebar_module(view_id: str, key: str, label: str, active: bool) -> str:
    if active:
        return f"[bold {ACCENT_TEAL}]▶[/] [bold {ACCENT_GOLD}]{key}[/] [bold {ACCENT_TEAL}]{label}[/]"
    return f"[{ACCENT_MUTED}]  [/] [bold {ACCENT_GOLD}]{key}[/] [{ACCENT_MUTED}]{label}[/]"


def render_sidebar_pulse(
    snapshot: dict[str, Any], refresh_interval: int, short: bool = False
) -> str:
    """The realm's pulse, in the 32-column rail beside the buttons.

    In a short terminal the pulse trims to the lines that answer "is it up, and is
    anyone in it". The refresh cadence and the backup count are not facts an
    operator acts on from the rail -- the cadence is in the banner and the backups
    are a key away -- and losing them is what keeps the Console Target below in
    view instead of scrolled out of the window.
    """
    server = snapshot.get("server", {})
    server_data = server.get("data", {}) if server.get("ok") else {}
    services = server_data.get("services", {})
    auth = services.get("auth", {})
    world = services.get("world", {})
    backups = snapshot.get("backups", {}).get("summary", {})
    players = player_summary(snapshot)

    lines: list[str] = [] if short else [""]
    lines.append(f"[bold {ACCENT_SKY}]Realm Pulse[/]")
    if not short:
        lines.append(
            f"[{ACCENT_MUTED}]Updated[/]  {escape_markup(iso_to_clock(snapshot.get('captured_at')))}"
        )
        lines.append(f"[{ACCENT_MUTED}]Refresh[/]  {refresh_interval}s")
        lines.append(f"[{ACCENT_MUTED}]Backups[/]  {backups.get('count', 0)} stored")
    lines.append(f"[{ACCENT_MUTED}]Players[/]  {players.get('online_count', 0)} online")
    lines.append(
        f"[{ACCENT_MUTED}]Auth[/]     {format_state(auth.get('health', auth.get('state', 'unavailable')))}"
    )
    lines.append(
        f"[{ACCENT_MUTED}]World[/]    {format_state(world.get('health', world.get('state', 'unavailable')))}"
    )
    return "\n".join(lines)


def render_sidebar_target(snapshot: dict[str, Any], short: bool = False) -> str:
    """What this console is pointed at, kept where the operator is looking.

    Every action in this panel runs against whatever the config file names, not
    against whatever the operator last cd'd into. On a host with a stale clone
    or a second config lying around, that distinction is the difference between
    restarting the realm and restarting the wrong thing, so the target is stated
    beside the buttons instead of three screens away in the config view. The
    sidebar is 32 columns with 2 of padding on each side, so every line here has
    to fit in 28 — which is why the config is named rather than pathed.
    """
    summary = snapshot.get("config_summary") or {}
    validate = snapshot.get("config_validate") or {}
    update = (snapshot.get("update_check") or {}).get("data") or {}

    # In a short terminal the block keeps the two lines that say where this console
    # acts and on which revision; the config name and the unit names are stable
    # between installs and are the first thing to go. A *broken* config is the
    # exception: a line that only ever reads "ok" can be trimmed, a line that reads
    # "invalid" cannot, so it stays whether or not the rail is short.
    lines: list[str] = [] if short else [""]
    lines.append(f"[bold {ACCENT_SKY}]Console Target[/]")

    install_root = str(summary.get("install_root") or "")
    lines.append(f"[{ACCENT_MUTED}]install[/]  {escape_markup(install_root or 'unknown')}")

    config_path = str(snapshot.get("config_path") or "")
    config_name = config_path.rsplit("/", 1)[-1] if config_path else "unknown"
    if not validate:
        config_state, config_tone = "unknown", ACCENT_MUTED
    elif validate.get("ok"):
        config_state, config_tone = "ok", ACCENT_TEAL
    else:
        config_state, config_tone = "invalid", ACCENT_ROSE
    if not short or config_state != "ok":
        lines.append(
            f"[{ACCENT_MUTED}]config[/]    {escape_markup(config_name)} [{config_tone}]{config_state}[/]"
        )

    units = ", ".join(
        str(name) for name in (summary.get("auth_service"), summary.get("world_service")) if name
    )
    if units and not short:
        lines.append(f"[{ACCENT_MUTED}]units[/]     {escape_markup(units)}")

    branch = str(update.get("branch") or "")
    commit = str(update.get("local_commit") or "")[:7]
    if branch or commit:
        behind = int(update.get("commits_behind") or 0)
        if behind:
            state, tone = f"{behind} behind", ACCENT_GOLD
        elif update.get("worktree_dirty"):
            state, tone = "worktree dirty", ACCENT_GOLD
        else:
            state, tone = "current", ACCENT_TEAL
        source = f"{branch}@{commit}" if branch else commit
        lines.append(f"[{ACCENT_MUTED}]source[/]    {escape_markup(source)}")
        lines.append(f"{'':10}[{tone}]{escape_markup(state)}[/]")

    return "\n".join(lines)


def render_service_panel(snapshot: dict[str, Any], active_view: str, narrow: bool = False) -> str:
    server = snapshot["server"]
    if not server["ok"]:
        lines = [
            f"[bold {ACCENT_GOLD}]Realm Services[/]",
            "",
            *backend_failure_lines(snapshot, server, "Server snapshot failed"),
        ]
        if not is_setup_failure(snapshot, server["error"]):
            lines.extend(["", f"[{ACCENT_MUTED}]Current view:[/] {active_view}"])
        return "\n".join(lines)

    data = server["data"]
    auth = data.get("services", {}).get("auth", {})
    world = data.get("services", {}).get("world", {})
    checks = data.get("checks", {})
    db = checks.get("database_connectivity", {})
    auth_restarts = clamp_int(auth.get("restart_count_1h", 0))
    world_restarts = clamp_int(world.get("restart_count_1h", 0))
    summary = snapshot.get("config_summary", {})

    def service_row(name: str, pad: str, service: dict[str, Any], restarts: int) -> str:
        row = (
            f"[bold {ACCENT_SKY}]{name}[/]{pad}{format_state(service.get('health', service.get('state')))}"
            f"  [{ACCENT_MUTED}]cpu[/] {service.get('cpu_percent', 0)}%"
            f"  [{ACCENT_MUTED}]mem[/] {service.get('memory_mb', 0)} MB"
        )
        # One row has room for one piece of history. A restart in the last hour is
        # that piece, so it displaces the pid; with nothing to report the pid takes
        # the slot, and uptime — which the Monitor view's process card carries in
        # every window size — steps aside rather than pushing a line wrap.
        if restarts:
            return row + f"  [{ACCENT_MUTED}]restarts/1h[/] {restarts}"
        return row + f"  [{ACCENT_MUTED}]pid[/] {service.get('pid', 0)}"

    if narrow:
        # Stacked, this card gets about a dozen rows for three services. Every
        # number stays; the indent and the blank separators are what the border
        # already gives you.
        lines = [
            f"[bold {ACCENT_GOLD}]Realm Services[/]",
            service_row("Auth", "   ", auth, auth_restarts),
            service_row("World", "  ", world, world_restarts),
            f"[bold {ACCENT_SKY}]DB[/]     {format_state('ok' if db.get('ok') else db.get('message', 'unreachable'))}  [{ACCENT_MUTED}]check[/] {escape_markup(db.get('message', 'n/a'))}",
        ]
    else:
        lines = [
            f"[bold {ACCENT_GOLD}]Realm Services[/]",
            f"[{ACCENT_MUTED}]Auth and world services, plus the DB check.[/]",
            "",
            f"[bold {ACCENT_SKY}]Auth[/]   {format_state(auth.get('health', auth.get('state')))}  [{ACCENT_MUTED}]pid[/] {auth.get('pid', 0)}  [{ACCENT_MUTED}]up[/] {auth.get('uptime_human', 'N/A')}",
            f"[{ACCENT_MUTED}]       cpu[/] {auth.get('cpu_percent', 0)}%  [{ACCENT_MUTED}]mem[/] {auth.get('memory_mb', 0)} MB  [{ACCENT_MUTED}]restarts/1h[/] {auth_restarts}",
            "",
            f"[bold {ACCENT_SKY}]World[/]  {format_state(world.get('health', world.get('state')))}  [{ACCENT_MUTED}]pid[/] {world.get('pid', 0)}  [{ACCENT_MUTED}]up[/] {world.get('uptime_human', 'N/A')}",
            f"[{ACCENT_MUTED}]       cpu[/] {world.get('cpu_percent', 0)}%  [{ACCENT_MUTED}]mem[/] {world.get('memory_mb', 0)} MB  [{ACCENT_MUTED}]restarts/1h[/] {world_restarts}",
            "",
            f"[bold {ACCENT_SKY}]DB[/]     {format_state('ok' if db.get('ok') else db.get('message', 'unreachable'))}  [{ACCENT_MUTED}]check[/] {escape_markup(db.get('message', 'n/a'))}",
        ]

    # Name the realm this console is pointed at: a screen full of green means
    # nothing if it is the wrong host. One line, because this panel's row is
    # fixed and a wrapped line is a silently dropped line.
    install_root = str(summary.get("install_root", "") or "")
    if install_root:
        services = ", ".join(part for part in (summary.get("auth_service", ""), summary.get("world_service", "")) if part)
        lines.append(
            f"[bold {ACCENT_SKY}]Target[/]  {escape_markup(install_root)}"
            + (f"  [{ACCENT_MUTED}]units[/] {escape_markup(services)}" if services else "")
        )

    return "\n".join(lines)


def render_metrics_panel(
    snapshot: dict[str, Any],
    metric_history: list[dict[str, Any]] | None = None,
    refresh_interval: int = 2,
    narrow: bool = False,
) -> str:
    server = snapshot["server"]
    metric_history = metric_history or []
    lines = [
        f"[bold {ACCENT_GOLD}]Host Metrics[/]",
        *([] if narrow else [f"[{ACCENT_MUTED}]CPU, memory, load, disk, and I/O on the realm host.[/]"]),
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
        cpu_percent = normalize_percent(cpu.get("usage_percent", 0))
        memory_percent = normalize_percent(memory.get("used_percent", 0))
        load_percent = normalize_load_percent(load.get("load_1", 0), cpu.get("cores", 1))
        disk_percent = normalize_percent(disk.get("used_percent", 0))
        metric_rows = [
            (
                "CPU",
                f"{cpu_percent:.1f}% / {cpu.get('cores', 'n/a')}c{compact_metric_state(cpu.get('status', 'unavailable'))}",
                cpu.get("status", "unavailable"),
                cpu_percent,
            ),
            (
                "Memory",
                f"{memory_percent:.1f}% / {format_gb_from_kb(memory.get('used_kb', 0)).replace(' GB', 'G')}/{format_gb_from_kb(memory.get('total_kb', 0)).replace(' GB', 'G')}{compact_metric_state(memory.get('status', 'unavailable'))}",
                memory.get("status", "unavailable"),
                memory_percent,
            ),
            (
                "Load",
                f"1m {load.get('load_1', 0)} / 5m {load.get('load_5', 0)}{compact_metric_state(load.get('status', 'unavailable'))}",
                load.get("status", "unavailable"),
                load_percent,
            ),
            (
                "Disk",
                f"{disk_percent:.1f}% / {format_gb_from_kb(disk.get('available_kb', 0)).replace(' GB', 'G')} free{compact_metric_state(disk.get('status', 'unavailable'))}",
                disk.get("status", "unavailable"),
                disk_percent,
            ),
        ]
        for label, summary, status, percent in metric_rows:
            label_segment = f"[bold {ACCENT_SKY}]{label:<6}[/]"
            # Bar first, value after: the row stays inside the panel width,
            # which previously wrapped every metric onto two lines and pushed
            # Disk and I/O out of the panel entirely.
            lines.append(
                f"{label_segment} {render_meter(percent, width=12, color=metric_health_color(status), show_minimum_for_positive=(label == 'Load'))} {escape_markup(summary)}"
            )
        if storage_io.get("available"):
            io_percent = normalize_percent(storage_io.get("util_percent", 0))
            io_summary_text = (
                f"{io_percent:.1f}% / {storage_io.get('read_ops_per_sec', 0)}:{storage_io.get('write_ops_per_sec', 0)} rw"
                f"{compact_metric_state(storage_io.get('status', 'unavailable'))}"
            )
            lines.append(
                f"[bold {ACCENT_SKY}]{'I/O':<6}[/] {render_meter(io_percent, width=12, color=metric_health_color(storage_io.get('status', 'unavailable')))} {escape_markup(io_summary_text)}"
            )
        else:
            lines.append(
                f"[bold {ACCENT_SKY}]I/O[/]      {format_state(storage_io.get('status', 'unavailable'))}  [{ACCENT_MUTED}]sysstat/iostat gives live disk history[/]"
            )
    else:
        lines.extend(backend_failure_lines(snapshot, server, "Server metrics unavailable"))

    return "\n".join(lines)


def render_monitor_pressure(
    snapshot: dict[str, Any],
    metric_history: list[dict[str, Any]] | None = None,
    refresh_interval: int = 2,
    narrow: bool = False,
) -> str:
    server = snapshot["server"]
    metric_history = metric_history or []
    lines = [
        f"[bold {ACCENT_GOLD}]Host Pressure[/]",
        *([] if narrow else [f"[{ACCENT_MUTED}]Current value, window peak, and trend per metric.[/]"]),
        f"[{ACCENT_MUTED}]Window[/] {history_window_label(metric_history, refresh_interval)}",
    ]

    if not server["ok"]:
        lines.extend(backend_failure_lines(snapshot, server, "Monitor snapshot unavailable"))
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
    cpu_percent = normalize_percent(cpu.get("usage_percent", 0))
    memory_percent = normalize_percent(memory.get("used_percent", 0))
    load_percent = normalize_load_percent(load.get("load_1", 0), cpu.get("cores", 1))
    disk_percent = normalize_percent(disk.get("used_percent", 0))

    metric_rows = [
        (
            "CPU",
            f"{cpu_percent:.1f}% / {cpu.get('cores', 'n/a')} cores{compact_metric_state(cpu.get('status', 'unavailable'))}",
            f"{cpu_percent:.1f}% / {cpu.get('cores', 'n/a')}c{compact_metric_state(cpu.get('status', 'unavailable'))}",
            cpu_history,
            "cpu",
            cpu.get("status", "unavailable"),
            cpu_percent,
        ),
        (
            "Memory",
            f"{memory_percent:.1f}% / {format_gb_from_kb(memory.get('used_kb', 0))} of {format_gb_from_kb(memory.get('total_kb', 0))}{compact_metric_state(memory.get('status', 'unavailable'))}",
            f"{memory_percent:.1f}% / {format_gb_from_kb(memory.get('used_kb', 0)).replace(' GB', 'G')}/{format_gb_from_kb(memory.get('total_kb', 0)).replace(' GB', 'G')}{compact_metric_state(memory.get('status', 'unavailable'))}",
            memory_history,
            "memory",
            memory.get("status", "unavailable"),
            memory_percent,
        ),
        (
            "Load",
            f"1m {load.get('load_1', 0)}  5m {load.get('load_5', 0)}  15m {load.get('load_15', 0)}{compact_metric_state(load.get('status', 'unavailable'))}",
            f"1m {load.get('load_1', 0)} / 5m {load.get('load_5', 0)}{compact_metric_state(load.get('status', 'unavailable'))}",
            load_history,
            "load",
            load.get("status", "unavailable"),
            load_percent,
        ),
        (
            "Disk",
            f"{disk_percent:.1f}% used / {format_gb_from_kb(disk.get('available_kb', 0))} free{compact_metric_state(disk.get('status', 'unavailable'))}",
            f"{disk_percent:.1f}% / {format_gb_from_kb(disk.get('available_kb', 0)).replace(' GB', 'G')} free{compact_metric_state(disk.get('status', 'unavailable'))}",
            disk_history,
            "disk",
            disk.get("status", "unavailable"),
            disk_percent,
        ),
    ]

    for label, summary, summary_narrow, values, metric_key, status, percent in metric_rows:
        peak_text = format_metric_peak(values, metric_key)
        if narrow:
            # One row per metric: the value, a meter short enough to sit beside
            # it, and the window peak. The trend word and the 15-minute average
            # are the first things to go, because a wrapped row is a metric an
            # operator never sees.
            lines.append(
                f"[bold {ACCENT_SKY}]{label:<6}[/] {escape_markup(summary_narrow)}  "
                f"{render_meter(percent, width=10, color=metric_health_color(status), show_minimum_for_positive=(metric_key == 'load'))}"
                f"  [{ACCENT_MUTED}]peak[/] {peak_text}"
            )
            continue
        lines.extend(
            [
                f"[bold {ACCENT_SKY}]{label:<6}[/] {format_state(status)}  {escape_markup(summary)}",
                f"{render_meter(percent, width=24, color=metric_health_color(status), show_minimum_for_positive=(metric_key == 'load'))}  [{ACCENT_MUTED}]peak[/] {peak_text}  [{ACCENT_MUTED}]trend[/] {describe_trend(values, metric_key)}",
            ]
        )

    if storage_io.get("available"):
        io_percent = normalize_percent(storage_io.get("util_percent", 0))
        peak_io = format_metric_peak(io_history, "io")
        io_summary = (
            f"{io_percent:.1f}% util / {storage_io.get('read_ops_per_sec', 0)}:{storage_io.get('write_ops_per_sec', 0)} ops"
            f"{compact_metric_state(storage_io.get('status', 'unavailable'))}"
        )
        if narrow:
            lines.append(
                f"[bold {ACCENT_SKY}]I/O   [/] {io_percent:.1f}% / "
                f"{storage_io.get('read_ops_per_sec', 0)}:{storage_io.get('write_ops_per_sec', 0)} ops{compact_metric_state(storage_io.get('status', 'unavailable'))}  "
                f"{render_meter(io_percent, width=10, color=metric_health_color(storage_io.get('status', 'unavailable')))}"
                f"  [{ACCENT_MUTED}]peak[/] {peak_io}"
            )
        else:
            lines.extend(
                [
                    f"[bold {ACCENT_SKY}]I/O   [/] {format_state(storage_io.get('status', 'unavailable'))}  {escape_markup(io_summary)}",
                    f"{render_meter(io_percent, width=24, color=metric_health_color(storage_io.get('status', 'unavailable')))}  [{ACCENT_MUTED}]peak[/] {peak_io}  [{ACCENT_MUTED}]trend[/] {describe_trend(io_history, 'io')}",
                ]
            )
    else:
        lines.append(f"[bold {ACCENT_SKY}]I/O   [/] {format_state(storage_io.get('status', 'unavailable'))}")
        if not narrow:
            lines.append(f"[{ACCENT_MUTED}]install [bold {ACCENT_GOLD}]sysstat/iostat[/] for live disk saturation history.")

    return "\n".join(lines)


def crash_loop_flag() -> str:
    """The crash-loop flag, in the one wording both card widths print.

    Only the affirmative is ever drawn. A denial next to every service is not a fact
    an operator acts on, and a block that leads with denials trains the eye to skip
    the block that carries the news — which is the same reason the narrow row omits
    it, and it applies just as hard when the card has room to spare.
    """
    return f"[{ACCENT_MUTED}]crash loop[/] {format_flag(True, true_text='yes', true_color=ACCENT_ROSE)}"


def render_monitor_processes(snapshot: dict[str, Any], narrow: bool = False) -> str:
    server = snapshot["server"]
    lines = [
        f"[bold {ACCENT_GOLD}]Realm Processes[/]",
        *([] if narrow else [f"[{ACCENT_MUTED}]Per-service CPU, memory, uptime, and restart history.[/]"]),
        "",
    ]

    if not server["ok"]:
        lines.extend(backend_failure_lines(snapshot, server, "Process data unavailable"))
        return "\n".join(lines)

    data = server["data"]
    services = data.get("services", {})
    db = data.get("checks", {}).get("database_connectivity", {})

    for service_name in ("auth", "world"):
        service = services.get(service_name, {})
        label = service_name.title()
        restarts = clamp_int(service.get("restart_count_1h", 0))
        if narrow:
            row = (
                f"[bold {ACCENT_SKY}]{label}[/]  {format_state(service.get('health', service.get('state', 'unavailable')))}"
                f"  [{ACCENT_MUTED}]cpu[/] {service.get('cpu_percent', 0)}%"
                f"  [{ACCENT_MUTED}]mem[/] {service.get('memory_mb', 0)} MB"
            )
            # One row of history, most actionable first. "no restarts, no crash
            # loop" costs a dozen columns to say nothing changed, and the pid is
            # the least useful number on a row that has news.
            if service.get("crash_loop_detected"):
                row += f"  {crash_loop_flag()}"
            elif restarts:
                row += f"  [{ACCENT_MUTED}]restarts/1h[/] {restarts}"
            else:
                row += f"  [{ACCENT_MUTED}]pid[/] {service.get('pid', 0)}"
            lines.append(row)
            continue
        lines.extend(
            [
                f"[bold {ACCENT_SKY}]{label}[/]  {format_state(service.get('health', service.get('state', 'unavailable')))}  [{ACCENT_MUTED}]pid[/] {service.get('pid', 0)}  [{ACCENT_MUTED}]up[/] {service.get('uptime_human', 'n/a')}",
                f"[{ACCENT_MUTED}]cpu[/] {service.get('cpu_percent', 0)}%  [{ACCENT_MUTED}]mem[/] {service.get('memory_mb', 0)} MB  "
                + (f"{crash_loop_flag()}  " if service.get("crash_loop_detected") else "")
                + f"[{ACCENT_MUTED}]restarts/1h[/] {restarts}",
            ]
        )

    if narrow and db.get("ok"):
        lines.extend(
            [
                "",
                f"[bold {ACCENT_SKY}]DB[/]    {format_state('ok')}  [{ACCENT_MUTED}]check[/] {escape_markup(db.get('message', 'n/a'))}",
            ]
        )
    else:
        # A DB that is not ok has a message, and the message is the reason; it
        # keeps its own row at every window size.
        lines.extend(
            [
                "",
                f"[bold {ACCENT_SKY}]DB[/]    {format_state('ok' if db.get('ok') else db.get('message', 'unreachable'))}",
                f"[{ACCENT_MUTED}]      check[/] {escape_markup(db.get('message', 'n/a'))}",
            ]
        )
    return "\n".join(lines)


SPARK_BLOCKS = "▁▂▃▄▅▆▇█"
TREND_COLORS = {
    "rising": ACCENT_GOLD,
    "falling": ACCENT_TEAL,
    "steady": ACCENT_SKY,
    "warming": ACCENT_MUTED,
}


def spark_domain(metric_key: str, host: dict[str, Any]) -> float:
    """The range over which this metric's own thresholds live.

    A percentage tops out at 100. A load average has no percentage: its warning
    is 1x cores and its critical is 2x cores, the same arithmetic
    `normalize_load_percent` uses, so the ceiling is 2x the core count. That is
    also why the same load 1.7 must be drawn differently on a 2-core and an
    8-core box: it means something different on each.
    """
    if metric_key == "load":
        return max(1.0, clamp_float(host.get("cpu", {}).get("cores", 1), 1.0) * 2.0)
    return 100.0


def render_sparkline(
    values: list[float | None],
    *,
    width: int = 22,
    color: str = ACCENT_SKY,
    suffix: str = "",
    trend: str = "",
    show_scale: bool = True,
    domain_high: float | None = None,
) -> str:
    """The shape of the window, not just its endpoints.

    `now` and `peak` say what happened; the eye wants the path that got
    there, and the refresh loop already keeps that history.

    `domain_high` decides what the block height *means*. With it, height is the
    value's position in the metric's real range (0-100% for a percentage, 0-2x
    cores for a load average). Without it the window's own min and max set the
    scale, and every window fills the row: measured on the demo snapshot, a disk
    usage that moved 23.0 -> 24.0 was drawn `▁▁▁▁▁▁██████`, the same full-height
    climb as a cpu that moved 24.0 -> 42.3. Both rows were true about direction
    and false about size, and five of them stacked became one uniform staircase
    in which nothing stands out because everything shouts.
    """
    samples = values[-width:]
    available = [value for value in samples if value is not None]
    if len(available) < 2:
        return f"[{ACCENT_MUTED}]collecting samples…[/]"

    low, high = min(available), max(available)
    span = high - low
    cells: list[str] = []
    last_block = len(SPARK_BLOCKS) - 1
    if domain_high is not None and domain_high > 0:
        for value in samples:
            if value is None:
                cells.append("·")
                continue
            index = int(round((max(0.0, value) / domain_high) * last_block))
            cells.append(SPARK_BLOCKS[max(0, min(last_block, index))])
    else:
        # No domain: fall back to the window's own extremes, which is the right
        # answer for a count with no ceiling (players online) and the wrong one
        # for a percentage. Callers that know their range pass it.
        for value in samples:
            if value is None:
                cells.append("·")
            elif span <= 0:
                cells.append(SPARK_BLOCKS[len(SPARK_BLOCKS) // 2])
            else:
                index = int(round(((value - low) / span) * (len(SPARK_BLOCKS) - 1)))
                cells.append(SPARK_BLOCKS[max(0, min(len(SPARK_BLOCKS) - 1, index))])

    if not show_scale:
        return f"[{color}]{''.join(cells)}[/]"
    scale = f"steady at {low:.1f}{suffix}" if span <= 0 else f"range {low:.1f}–{high:.1f}{suffix}"
    tail = f"{trend} · {scale}" if trend else scale
    return f"[{color}]{''.join(cells)}[/]  [{ACCENT_MUTED}]{escape_markup(tail)}[/]"


def trend_color(values: list[float | None], metric_key: str) -> str:
    return TREND_COLORS.get(describe_trend(values, metric_key).split()[0], ACCENT_SKY)


def render_monitor_trends(
    snapshot: dict[str, Any],
    metric_history: list[dict[str, Any]] | None = None,
    refresh_interval: int = 2,
    narrow: bool = False,
) -> str:
    server = snapshot["server"]
    metric_history = metric_history or []
    # The window rides on the title line: this panel has exactly enough rows
    # for five metrics, and a spent row is a metric nobody sees.
    lines = [
        f"[bold {ACCENT_GOLD}]Trends[/]  [{ACCENT_MUTED}]{history_window_label(metric_history, refresh_interval)}[/]",
        "",
    ]

    if not server["ok"]:
        lines.extend(backend_failure_lines(snapshot, server, "Trend data unavailable"))
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
        domain = spark_domain(label.lower(), host)
        available = [value for value in values if value is not None]
        # The reading on screen is part of the window, so the peak can never
        # print below it — "now 42.3  peak 41.0" reads as a broken gauge.
        peak_text = f"{max(available + [current_value]):.1f}{suffix}" if available or current_value is not None else "n/a"
        if narrow:
            # One row per metric: value, peak, and a short sparkline. The scale
            # sentence ("range 20.0–31.0") repeats what the shape already says,
            # and it is the part that costs the second row.
            lines.append(
                f"[bold {ACCENT_SKY}]{label:<6}[/] {current_value:.1f}{suffix}  [{ACCENT_MUTED}]peak[/] {peak_text}  "
                f"{render_sparkline(values, width=10, color=trend_color(values, label.lower()), show_scale=False, domain_high=domain)}"
            )
            continue
        lines.append(
            f"[bold {ACCENT_SKY}]{label:<6}[/] [{ACCENT_MUTED}]now[/] {current_value:.1f}{suffix}  [{ACCENT_MUTED}]peak[/] {peak_text}"
        )
        lines.append(
            f"         {render_sparkline(values, color=trend_color(values, label.lower()), suffix=suffix, trend=describe_trend_with_delta(values, label.lower()), domain_high=domain)}"
        )

    io_history = history_values(metric_history, "io")
    if storage_io.get("available"):
        available_io = [value for value in io_history if value is not None]
        io_now = clamp_float(storage_io.get("util_percent"))
        peak_io = f"{max(available_io + [io_now]):.1f}%"
        if narrow:
            lines.append(
                f"[bold {ACCENT_SKY}]I/O   [/] {io_now:.1f}%  [{ACCENT_MUTED}]peak[/] {peak_io}  "
                f"{render_sparkline(io_history, width=10, color=trend_color(io_history, 'io'), show_scale=False, domain_high=spark_domain('io', host))}"
            )
        else:
            lines.append(
                f"[bold {ACCENT_SKY}]I/O   [/] [{ACCENT_MUTED}]now[/] {io_now:.1f}%  [{ACCENT_MUTED}]peak[/] {peak_io}"
            )
            lines.append(
                f"         {render_sparkline(io_history, color=trend_color(io_history, 'io'), suffix='%', trend=describe_trend_with_delta(io_history, 'io'), domain_high=spark_domain('io', host))}"
            )
    else:
        lines.append(f"[bold {ACCENT_SKY}]I/O   [/] [{ACCENT_MUTED}]now[/] unavailable  [{ACCENT_MUTED}]peak[/] n/a  [{ACCENT_MUTED}]trend[/] warming")

    return "\n".join(lines)


def render_monitor_storage(snapshot: dict[str, Any]) -> str:
    server = snapshot["server"]
    # This pane sits in the narrow right column, so its rows are kept inside
    # roughly 40 columns: a wrapped row here is a row the operator never sees.
    lines = [
        f"[bold {ACCENT_GOLD}]Storage[/]",
        "",
    ]

    if not server["ok"]:
        lines.extend(backend_failure_lines(snapshot, server, "Storage data unavailable"))
        return "\n".join(lines)

    data = server["data"]
    disk = data.get("checks", {}).get("disk_space", {})
    storage_io = data.get("storage_io", {})
    lines.extend(
        [
            f"[{ACCENT_MUTED}]Path[/]    {escape_markup(disk.get('path', 'n/a'))}",
            f"[{ACCENT_MUTED}]FS[/]      {escape_markup(disk.get('filesystem', 'n/a'))}",
            f"[{ACCENT_MUTED}]Space[/]   {disk.get('used_percent', 0)}% used  {format_gb_from_kb(disk.get('available_kb', 0))} free",
            f"[{ACCENT_MUTED}]Status[/]  {format_state(disk.get('status', 'unavailable'))}",
            "",
        ]
    )

    if storage_io.get("available"):
        lines.extend(
            [
                f"[{ACCENT_MUTED}]Device[/]  {escape_markup(storage_io.get('device', 'n/a'))} [{ACCENT_MUTED}]from[/] {escape_markup(storage_io.get('source', 'n/a'))}",
                f"[{ACCENT_MUTED}]Ops/s[/]   read {storage_io.get('read_ops_per_sec', 0)}  write {storage_io.get('write_ops_per_sec', 0)}",
                f"[{ACCENT_MUTED}]KB/s[/]    read {storage_io.get('read_kbps', 0)}  write {storage_io.get('write_kbps', 0)}",
                f"[{ACCENT_MUTED}]Await[/]   {storage_io.get('await_ms', 0)} ms  [{ACCENT_MUTED}]util[/] {storage_io.get('util_percent', 0)}%",
                f"[{ACCENT_MUTED}]I/O[/]     {format_state(storage_io.get('status', 'unavailable'))}",
            ]
        )
    else:
        lines.extend(
            [
                f"[{ACCENT_MUTED}]Device[/]  n/a",
                f"[{ACCENT_MUTED}]I/O[/]     {format_state(storage_io.get('status', 'unavailable'))}",
                f"[{ACCENT_MUTED}]Note[/]    install [bold {ACCENT_GOLD}]sysstat/iostat[/] for live disk rates.",
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
    narrow: bool = False,
) -> str:
    metric_history = metric_history or []
    players = snapshot.get("players", [])
    summary = player_summary(snapshot)
    online_now = int(summary.get("online_count", 0))
    player_history = history_values(metric_history, "players")
    peak_window = int(max(player_history)) if player_history else online_now
    staff_count = int(summary.get("staff_count", 0))
    player_count = int(summary.get("player_count", 0))
    if staff_count > 0:
        coverage = max(int(round(online_now / staff_count)), 1)
        coverage_text = f"1 GM / {coverage} online"
    else:
        coverage_text = "no staff online"

    lines = [
        f"[bold {ACCENT_GOLD}]Player Pulse[/]",
        *([] if narrow else [f"[{ACCENT_MUTED}]Who is online, the window peak, and staff coverage.[/]"]),
        "",
            f"[{ACCENT_MUTED}]Online Now[/]   [bold {ACCENT_GOLD}]{online_now}[/]  [{ACCENT_MUTED}]trend[/] {describe_trend(player_history, 'players')}",
            f"[{ACCENT_MUTED}]Peak Window[/] {peak_window}  [{ACCENT_MUTED}]window[/] {history_window_label(metric_history, refresh_interval)}",
            f"[{ACCENT_MUTED}]Count Source[/] {escape_markup(str(summary.get('count_source', 'unavailable')))}",
            f"[{ACCENT_MUTED}]Mix[/]          players={player_count}  staff={staff_count}",
            f"[{ACCENT_MUTED}]GM Coverage[/]  {escape_markup(coverage_text)}",
        f"[{ACCENT_MUTED}]GMs Online[/]   {staff_count}"
        # The GM names belong to the roster, which is one key away; at narrow
        # widths the row they cost is a row of counts the operator cannot see.
        + ("" if narrow else f"  [{ACCENT_MUTED}]names[/] {escape_markup(truncate_text(summary.get('gm_summary', 'none'), 36))}"),
        f"[{ACCENT_MUTED}]Roster[/]       {summary.get('roster_count', len(players))} visible  [{ACCENT_MUTED}]mode[/] {escape_markup(str(summary.get('roster_source', 'unknown')))}",
    ]
    if not narrow:
        lines.extend(
            [
                "",
                f"[{ACCENT_MUTED}]Open[/]        [bold {ACCENT_GOLD}]o[/] online roster  [bold {ACCENT_GOLD}]2[/] accounts",
            ]
        )
    return "\n".join(lines)


def render_account_details(account: dict[str, Any] | None, total_accounts: int) -> str:
    if not account:
        return "\n".join(
            [
                f"[bold {ACCENT_GOLD}]Selected Account[/]",
                "",
                f"[{ACCENT_MUTED}]Inventory[/]     {total_accounts} account{'s' if total_accounts != 1 else ''} loaded",
                f"[{ACCENT_MUTED}]Selection[/]    choose a row to inspect or act on an account.",
            ]
        )

    return "\n".join(
        [
            f"[bold {ACCENT_GOLD}]Selected Account[/]",
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


def view_nav_key(view_id: str) -> str:
    for candidate, key, _label in SIDEBAR_MODULES:
        if candidate == view_id:
            return key
    return "?"


def render_setup_checklist(snapshot: dict[str, Any], *, compact: bool = False) -> list[str]:
    """How to get an unconfigured host online, shown where the operator looks.

    A brand-new host used to answer with the same raw error in four panels.
    One short path replaces that: the compact form fits an Overview tile, the
    full form belongs on the Config screen where there is room for the actual
    commands.
    """
    setup = snapshot.get("setup") or {}
    state = setup.get("state", "ready")
    bin_name = setup.get("bin") or "vmangos-manager"

    if state == "missing":
        if compact:
            return [
                f"[bold {ACCENT_SKY}]Getting this host online[/]",
                f"[{ACCENT_MUTED}]Manager is installed; it has no configuration here yet.[/]",
                f"[{ACCENT_MUTED}]Open Config ({view_nav_key('config')}) — it names the command that finishes setup.[/]",
            ]
        return [
            f"[bold {ACCENT_SKY}]Getting this host online[/]",
            f"[{ACCENT_MUTED}]Manager is installed; it just has no configuration here yet.[/]",
            "",
            f"[bold {ACCENT_GOLD}]1[/]  Adopt a realm that already exists:   [bold {ACCENT_SKY}]sudo {bin_name} config detect[/]",
            f"[bold {ACCENT_GOLD}]2[/]  Or describe this host by hand:       [bold {ACCENT_SKY}]sudo {bin_name} config create[/]",
            f"[bold {ACCENT_GOLD}]3[/]  Or build the realm from scratch:     [bold {ACCENT_SKY}]sudo {bin_name} install[/]",
            "",
            f"[{ACCENT_MUTED}]Every panel on this screen fills in once that config exists.[/]",
        ]
    if state == "unreadable":
        if compact:
            return [
                f"[bold {ACCENT_SKY}]Reading the configuration[/]",
                f"[{ACCENT_MUTED}]It exists; this user cannot open it.[/]",
                f"[{ACCENT_MUTED}]Open Config ({view_nav_key('config')}) for the grant command.[/]",
            ]
        return [
            f"[bold {ACCENT_SKY}]Reading the configuration[/]",
            f"[{ACCENT_MUTED}]The config exists but this user cannot open it.[/]",
            "",
            f"[bold {ACCENT_GOLD}]1[/]  Grant this account access:  [bold {ACCENT_SKY}]{escape_markup(setup.get('next_step', ''))}[/]",
            f"[bold {ACCENT_GOLD}]2[/]  Re-open the dashboard — no sudo needed after that.",
            "",
            f"[{ACCENT_MUTED}]Manager keeps its config group-readable (mode 640) so operators are never root.[/]",
        ]
    return []


def render_alerts_panel(snapshot: dict[str, Any], narrow: bool = False) -> str:
    server = snapshot["server"]
    lines = [
        f"[bold {ACCENT_GOLD}]Alerts and Events[/]",
        *([] if narrow else [f"[{ACCENT_MUTED}]Anything currently wrong, plus recent service events.[/]"]),
        *([] if narrow else [""]),
    ]

    if not server["ok"]:
        lines.extend(backend_failure_lines(snapshot, server, "Alerts unavailable"))
        checklist = render_setup_checklist(snapshot, compact=True)
        if checklist:
            lines.append("")
            lines.extend(checklist)
        return "\n".join(lines)

    data = server["data"]
    alerts = data.get("alerts", {})
    active_alerts = alerts.get("active", [])
    recent_events = alerts.get("recent_events", [])

    lines.append(f"[{ACCENT_MUTED}]Overall[/]      {format_state(alerts.get('status', 'healthy'))}  [{ACCENT_MUTED}]active[/] {len(active_alerts)}")

    # Rows are what this card is made of, and two of them used to be spent on
    # nothing: a heading with only its own negation under it ("Active Alerts" over
    # "No active alerts" — three lines to say the state line already said), and a
    # blank row between blocks the coloured headings already separate. A heading is
    # printed when it has content under it, and the only blank left is the air under
    # the header in a window wide enough to afford it. What the card now spends its
    # rows on is the state line, the alerts, and the events.
    if active_alerts:
        lines.append(f"[bold {ACCENT_SKY}]Active Alerts[/]")
        for alert in active_alerts[:3]:
            lines.append(
                f"{format_state(alert.get('severity', 'warning'))} {escape_markup(alert.get('source', 'unknown'))}: {escape_markup(truncate_text(alert.get('message', ''), 64))}"
            )
    else:
        lines.append(f"[bold {palette_color(STATUS_COLORS['healthy'])}]No active alerts[/]")

    if recent_events:
        if active_alerts and not narrow:
            lines.append("")
        lines.append(f"[bold {ACCENT_SKY}]Recent Events[/]")
        for event in recent_events[:4]:
            lines.append(f"{escape_markup(truncate_text(event.get('timestamp', ''), 19))} {escape_markup(event.get('service', 'unknown'))}: {escape_markup(truncate_text(event.get('message', ''), 48))}")
    else:
        lines.append(f"[{ACCENT_MUTED}]No recent events in the last 30 minutes.[/]")

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
        f"[{ACCENT_MUTED}]Directory[/]   {escape_markup(summary.get('backup_dir', 'n/a') or 'n/a')}",
    ]

    latest_file = summary.get("latest_file", "")
    if latest_file:
        lines.extend(
            [
                f"[{ACCENT_MUTED}]Latest[/]      {escape_markup(latest_file)}",
                f"[{ACCENT_MUTED}]When[/]        {escape_markup(iso_to_display(summary.get('latest_timestamp')))}",
                f"[{ACCENT_MUTED}]Size[/]        {format_bytes(summary.get('latest_size_bytes', 0))}",
            ]
        )
    else:
        lines.append(f"[{ACCENT_MUTED}]Latest[/]      none")

    lines.extend(["", f"[bold {ACCENT_SKY}]Timer State[/]"])
    if backup_schedule_status.get("ok"):
        if configured_schedules:
            for entry in configured_schedules:
                schedule_name = escape_markup(str(entry.get("id", "backup")).title())
                schedule_health = "healthy" if entry.get("enabled") and entry.get("active") else "warning"
                lines.append(
                    f"[{ACCENT_MUTED}]{schedule_name}[/]       {format_state(schedule_health)}  {escape_markup(entry.get('configured', 'n/a'))}"
                )
                if entry.get("next_run"):
                    lines.append(f"[{ACCENT_MUTED}]             [/]{escape_markup(entry.get('next_run'))}")
        else:
            lines.append(f"[{ACCENT_MUTED}]No backup timers configured yet.[/]")
    else:
        lines.extend(backend_failure_lines(snapshot, backup_schedule_status, "Schedule state unavailable"))

    readiness = summarize_restore_readiness(snapshot)
    lines.extend(
        [
            "",
            f"[bold {ACCENT_GOLD}]Restore Readiness[/]",
            f"[{ACCENT_MUTED}]Credentials[/]  {format_state('healthy' if readiness['credentials_ready'] else 'warning')}"
            + (
                ""
                if readiness["credentials_ready"]
                else f"  not in this session — set MYSQL_RESTORE_DEFAULTS_FILE or MYSQL_RESTORE_PASSWORD in the shell that runs vmangos-manager"
            ),
        ]
    )
    if readiness["latest_age_seconds"] is None:
        if summary.get("count", 0):
            lines.append(f"[{ACCENT_MUTED}]Safety Copy[/]  {format_state('warning')}  latest backup age unknown")
        else:
            lines.append(f"[{ACCENT_MUTED}]Safety Copy[/]  {format_state('critical')}  no backups yet")
    elif readiness["within_safety_window"]:
        lines.append(
            f"[{ACCENT_MUTED}]Safety Copy[/]  {format_state('healthy')}  latest backup {format_age(readiness['latest_age_seconds'])} (within 24h window)"
        )
    else:
        lines.append(
            f"[{ACCENT_MUTED}]Safety Copy[/]  {format_state('warning')}  latest backup {format_age(readiness['latest_age_seconds'])} — live restore will require --backup-first"
        )
    lines.append(
        f"[{ACCENT_MUTED}]Preflight[/]   press p on a selected backup, or run vmangos-manager backup restore <file> --preflight"
    )

    if selected_backup:
        lines.extend(
            [
                "",
                f"[bold {ACCENT_SKY}]Selected Backup[/]",
                f"[{ACCENT_MUTED}]File[/]        {escape_markup(selected_backup.get('file', 'n/a'))}",
                f"[{ACCENT_MUTED}]When[/]        {escape_markup(iso_to_display(selected_backup.get('timestamp')))}",
                f"[{ACCENT_MUTED}]Size[/]        {format_bytes(selected_backup.get('size_bytes', 0))}",
                f"[{ACCENT_MUTED}]DBs[/]         {escape_markup(', '.join(selected_backup.get('databases', [])) or 'n/a')}",
                f"[{ACCENT_MUTED}]Created By[/]  {escape_markup(selected_backup.get('created_by', 'n/a'))}",
                "",
                f"[{ACCENT_MUTED}]Safety[/]      live restore is CLI-only: preflight, then run vmangos-manager backup restore <file> --yes",
            ]
        )
    else:
        lines.extend(
            [
                "",
                f"[{ACCENT_MUTED}]Selection[/]   choose a backup row to inspect it.",
                f"[{ACCENT_MUTED}]Safety[/]      live restore is CLI-only: preflight, then run vmangos-manager backup restore <file> --yes",
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

    lines = [f"[bold {ACCENT_GOLD}]Configuration[/]", ""]
    setup = snapshot.get("setup") or {}
    if setup.get("state") in ("missing", "unreadable"):
        # A host with nothing to show should say what is missing and how to
        # finish, not print a column of n/a.
        lines.extend(render_setup_checklist(snapshot))
        state_note = (
            "the file does not exist yet"
            if setup.get("state") == "missing"
            else "the file exists but this user cannot read it"
        )
        lines.extend(
            [
                "",
                f"[{ACCENT_MUTED}]Config Path[/]   {escape_markup(config_path)}  [{ACCENT_MUTED}]({state_note})[/]",
                "",
                f"[bold {ACCENT_SKY}]Safety[/]",
                f"[{ACCENT_MUTED}]Read-only[/]     edit manager.conf and .dbpass in the shell, never here.",
                f"[{ACCENT_MUTED}]Least-privilege[/] config stays mode 640 group-readable so operators run without root.",
            ]
        )
        return "\n".join(lines)

    if validate["ok"]:
        valid = validate["data"].get("valid", True)
        lines.append(f"Validation  {format_state('healthy' if valid else 'critical')}")
    else:
        lines.append(f"[bold {ACCENT_ROSE}]Validation failed:[/] {format_error_text(validate['error'])}")

    lines.extend(
        [
            "",
            f"[{ACCENT_MUTED}]Config Path[/]   {escape_markup(config_path)}",
            "",
            f"[bold {ACCENT_SKY}]Server Settings[/]",
            f"[{ACCENT_MUTED}]Install Root[/]  {escape_markup(summary.get('install_root', 'n/a') or 'n/a')}",
            f"[{ACCENT_MUTED}]Auth Service[/]  {escape_markup(summary.get('auth_service', 'n/a') or 'n/a')}",
            f"[{ACCENT_MUTED}]World Service[/] {escape_markup(summary.get('world_service', 'n/a') or 'n/a')}",
            f"[{ACCENT_MUTED}]Backup Dir[/]    {escape_markup(summary.get('backup_dir', 'n/a') or 'n/a')}",
            "",
            f"[bold {ACCENT_SKY}]Database Settings[/]",
            f"[{ACCENT_MUTED}]DB Host[/]       {escape_markup(summary.get('db_host', 'n/a') or 'n/a')}",
            f"[{ACCENT_MUTED}]DB User[/]       {escape_markup(summary.get('db_user', 'n/a') or 'n/a')}",
            f"[{ACCENT_MUTED}]DB Secret[/]     {escape_markup(secret_label)}",
            f"[{ACCENT_MUTED}]DB Names[/]      auth={escape_markup(summary.get('auth_db', 'n/a'))} world={escape_markup(summary.get('world_db', 'n/a'))} chars={escape_markup(summary.get('characters_db', 'n/a'))} logs={escape_markup(summary.get('logs_db', 'n/a'))}",
            "",
            f"[bold {ACCENT_SKY}]Safety[/]",
            f"[{ACCENT_MUTED}]Read-only[/]     edit manager.conf and .dbpass in the shell, never here.",
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


def summarize_named_counts(counts: dict[str, Any], preferred_order: list[str] | None = None) -> str:
    if not isinstance(counts, dict) or not counts:
        return "none"

    ordered_keys: list[str] = []
    preferred = preferred_order or []
    for key in preferred:
        if key in counts:
            ordered_keys.append(key)
    for key in sorted(counts.keys()):
        if key not in ordered_keys:
            ordered_keys.append(key)

    parts: list[str] = []
    for key in ordered_keys:
        parts.append(f"{key}={counts.get(key, 0)}")
    return "  ".join(parts)


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


def render_realm_logs_summary(snapshot: dict[str, Any]) -> str:
    realm_logs = snapshot.get("realm_logs", {})
    lines = [
        f"[bold {ACCENT_GOLD}]Realm Logs[/]",
        "",
        f"[{ACCENT_MUTED}]Recent auth/world events; each refresh re-reads the current filters.[/]",
        "",
    ]

    if not realm_logs.get("ok"):
        lines.extend(
            [
                *backend_failure_lines(snapshot, realm_logs, "Log view unavailable"),
                "",
                f"[{ACCENT_MUTED}]Next[/] verify logs recent works from the CLI, then retry [bold {ACCENT_GOLD}]r[/] refresh.",
                f"[{ACCENT_MUTED}]Filters[/] [bold {ACCENT_GOLD}]f[/] adjust source, window, severity, and limit",
            ]
        )
        return "\n".join(lines)

    data = realm_logs.get("data", {})
    filters = data.get("filters", {})
    summary = data.get("summary", {})
    capabilities = data.get("capabilities", {})
    source_counts = summarize_named_counts(summary.get("source_counts", {}), ["auth", "world"])
    severity_counts = summarize_named_counts(
        summary.get("severity_counts", {}),
        ["critical", "error", "warning", "notice", "info", "debug"],
    )
    available_sources = ", ".join(summary.get("available_sources", [])) or "none"
    events_returned = clamp_int(summary.get("events_returned", 0))
    top_severity = summarize_named_counts(summary.get("severity_counts", {}), ["critical", "error", "warning"])
    latest_event = snapshot.get("log_events", [None])[0]
    latest_summary = "none in current window"
    if latest_event:
        latest_summary = (
            f"{iso_to_clock(latest_event.get('timestamp'))} "
            f"{latest_event.get('source', 'unknown')}: "
            f"{truncate_text(latest_event.get('message', ''), 40)}"
        )

    lines.extend(
        [
            f"[{ACCENT_MUTED}]Filters[/]       source={escape_markup(str(filters.get('source', 'all')))}  window={escape_markup(str(filters.get('window', '15m')))}  severity={escape_markup(str(filters.get('severity', 'all')))}  limit={filters.get('limit', 25)}",
            f"[{ACCENT_MUTED}]Events[/]        {events_returned} visible  [{ACCENT_MUTED}]latest[/] {escape_markup(latest_summary)}",
            f"[{ACCENT_MUTED}]Top Severity[/]  {escape_markup(top_severity)}",
            f"[{ACCENT_MUTED}]By Source[/]     {escape_markup(source_counts)}",
            f"[{ACCENT_MUTED}]By Severity[/]   {escape_markup(severity_counts)}",
            f"[{ACCENT_MUTED}]Source[/]        {escape_markup(str(summary.get('backing', 'unavailable')))} journal; {summary.get('sources_available', 0)}/{summary.get('sources_requested', 0)} feeds ({escape_markup(available_sources)})",
        ]
    )
    capability_limits = []
    if not capabilities.get("severity_filter_supported", False):
        capability_limits.append("severity filtering unsupported")
    if not capabilities.get("time_window_supported", False):
        capability_limits.append("time windows unsupported")
    if capability_limits:
        lines.append(f"[{ACCENT_MUTED}]Limits[/]        {escape_markup('; '.join(capability_limits))} by this log source")
    lines.extend(
        [
            "",
            f"[{ACCENT_MUTED}]Escalate[/]      [bold {ACCENT_GOLD}]7[/] Operations schedules the fix",
        ]
    )
    return "\n".join(lines)


def render_log_event_details(entry: dict[str, Any] | None, total_count: int) -> str:
    lines = [
        f"[bold {ACCENT_GOLD}]Selected Event[/]",
        "",
        f"[{ACCENT_MUTED}]The highlighted log entry in full.[/]",
        "",
        f"[{ACCENT_MUTED}]Window[/] {total_count} visible event{'s' if total_count != 1 else ''}",
    ]

    if entry is None:
        lines.extend(
            [
                "",
                f"[{ACCENT_MUTED}]No event selected. Use [bold {ACCENT_GOLD}]f[/] to widen the filter or wait for the next refresh.[/]",
            ]
        )
        return "\n".join(lines)

    lines.extend(
        [
            "",
            f"[{ACCENT_MUTED}]Time[/]       {escape_markup(iso_to_display(entry.get('timestamp')))}",
            f"[{ACCENT_MUTED}]Source[/]     {escape_markup(str(entry.get('source', 'unknown')))}",
            f"[{ACCENT_MUTED}]Severity[/]   {format_state(entry.get('severity', 'info'))}",
            f"[{ACCENT_MUTED}]Service[/]    {escape_markup(str(entry.get('service', 'n/a')))}",
            f"[{ACCENT_MUTED}]Unit[/]       {escape_markup(str(entry.get('unit', 'n/a')))}",
            f"[{ACCENT_MUTED}]Identifier[/] {escape_markup(str(entry.get('identifier', 'n/a')))}",
            "",
            f"[bold {ACCENT_SKY}]Message[/]",
            f"{escape_markup(str(entry.get('message', '')))}",
        ]
    )
    return "\n".join(lines)


def render_logs_panel(snapshot: dict[str, Any]) -> str:
    logs = snapshot.get("logs", {})
    queue_count = len(snapshot.get("schedules", []))
    lines = [
        f"[bold {ACCENT_GOLD}]Maintenance Readiness[/]",
        "",
        f"[{ACCENT_MUTED}]Log rotation, permissions, and disk headroom; check before a maintenance window.[/]",
        "",
    ]

    if not logs.get("ok"):
        lines.extend(backend_failure_lines(snapshot, logs, "Logs snapshot unavailable"))
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
            f"[{ACCENT_MUTED}]Log Health[/]    {format_state(data.get('status', 'unavailable'))}",
            f"[{ACCENT_MUTED}]Rotation[/]      {format_state(config_state)}  present={config.get('present', False)}  in_sync={config.get('in_sync', False)}",
            f"[{ACCENT_MUTED}]Sensitive[/]     {format_state(sensitive_state)}  perms_ok={log_counts.get('sensitive_permissions_ok', False)}",
            f"[{ACCENT_MUTED}]Files[/]         active={log_counts.get('active_files', 0)}  rotated={log_counts.get('rotated_files', 0)}",
            f"[{ACCENT_MUTED}]Headroom[/]      {disk.get('used_percent', 0)}% used  free {format_gb_from_kb(disk.get('available_kb', 0))}",
            f"[{ACCENT_MUTED}]Retention[/]     max={escape_markup(str(policy.get('max_size', 'n/a')))}  min={escape_markup(str(policy.get('min_size', 'n/a')))}",
            "",
            f"[{ACCENT_MUTED}]Safety[/]      live rotation and timer changes are CLI/root; this panel only reads state.",
        ]
    )
    return "\n".join(lines)


def render_update_panel(snapshot: dict[str, Any], update_plan_data: dict[str, Any] | None = None) -> str:
    check = snapshot.get("update_check", {})
    inspect = snapshot.get("update_inspect", {})
    lines = [
        f"[bold {ACCENT_GOLD}]Change Window Readiness[/]",
        "",
        f"[{ACCENT_MUTED}]How far behind origin, DB impact, and the planned steps.[/]",
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

    lines.extend(
        [
            "",
            f"[bold {ACCENT_SKY}]Safety[/]",
            f"[{ACCENT_MUTED}]Apply[/]         updates run from the shell (vmangos-manager update apply), after a backup.",
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
        return "maintenance task scheduled by Manager"
    if job_type == "restart":
        return "restart window scheduled by Manager"
    return "scheduled by Manager"


def render_schedule_intro(schedules: list[dict[str, Any]]) -> str:
    count = len(schedules)
    return "\n".join(
        [
            f"[{ACCENT_MUTED}]Queue[/]         {count} scheduled task{'s' if count != 1 else ''} loaded from systemd timers.",
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
                f"[bold {ACCENT_GOLD}]Selected Task[/]",
                f"[{ACCENT_MUTED}]What this task is, when it runs next, and how to cancel it.[/]",
                "",
                f"[{ACCENT_MUTED}]Selection[/]     choose a job row from the queue to inspect or cancel it.",
                f"[{ACCENT_MUTED}]Queue[/]         {queue_label}",
                "",
                f"[{ACCENT_MUTED}]Safety[/]      cancel removes the timers from systemd immediately.",
            ]
        )

    warnings = str(schedule.get("warnings", "") or "none")
    announce_message = str(schedule.get("announce_message", "") or "none")
    return "\n".join(
        [
            f"[bold {ACCENT_GOLD}]Selected Task[/]",
            f"[{ACCENT_MUTED}]What this task is, when it runs next, and how to cancel it.[/]",
            "",
            f"[{ACCENT_MUTED}]Queue[/]         {queue_label}",
            f"[{ACCENT_MUTED}]Task ID[/]       {escape_markup(schedule.get('id', 'n/a'))}",
            f"[{ACCENT_MUTED}]Type[/]          {escape_markup(schedule_job_type_label(schedule.get('job_type', 'n/a')))}",
            f"[{ACCENT_MUTED}]Origin[/]        {escape_markup(schedule_origin_label(schedule))}",
            f"[{ACCENT_MUTED}]Cadence[/]       {escape_markup(schedule.get('schedule_type', 'n/a'))}",
            f"[{ACCENT_MUTED}]Schedule[/]      {escape_markup(schedule_label(schedule))}",
            f"[{ACCENT_MUTED}]Next Run[/]      {escape_markup(schedule.get('next_run', 'n/a') or 'n/a')}",
            f"[{ACCENT_MUTED}]Warnings[/]      {escape_markup(warnings)}",
            f"[{ACCENT_MUTED}]Announce[/]      {escape_markup(announce_message)}",
            "",
            f"[{ACCENT_MUTED}]Next Action[/]   [bold {ACCENT_GOLD}]j[/] remove this task if it is no longer desired.",
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
        from textual.command import DiscoveryHit, Hit, Hits, Provider
        from textual.containers import Container, Horizontal, Vertical
        from textual.screen import ModalScreen
        from textual.widgets import Button, DataTable, Header, Input, Label, Select, Static
    except ImportError as exc:
        raise DashboardRuntimeError(
            f"Textual runtime import failed: {exc}. Run 'vmangos-manager dashboard --bootstrap' first."
        ) from exc

    def make_form_control(field: dict[str, Any]) -> Input | Select:
        """One input control per form field spec.

        Fields with a non-empty "options" list render as a Select dropdown
        (labels shown, values dispatched); everything else stays an Input.
        The Select's initial value falls back to the first option when the
        spec's current value is not among the choices.
        """
        options = [(str(label), str(value)) for label, value in field.get("options") or []]
        control_id = f"command-field-{field['name']}"
        if options:
            current = str(field.get("value", ""))
            if current not in [value for _label, value in options]:
                current = options[0][1]
            return Select(options, value=current, allow_blank=False, id=control_id, classes="command-field")
        return Input(
            value=str(field.get("value", "")),
            placeholder=str(field.get("placeholder", "")),
            password=bool(field.get("password", False)),
            id=control_id,
            classes="command-field",
        )

    class CommandFormScreen(ModalScreen[dict[str, str] | None]):
        BINDINGS = [("escape", "cancel", "Cancel"), ("enter", "submit", "Submit")]

        def __init__(
            self,
            title: str,
            submit_label: str,
            fields: list[dict[str, Any]],
            intro: str = "",
            action_name: str = "",
        ) -> None:
            super().__init__()
            self.title = title
            self.submit_label = submit_label
            self.fields = fields
            self.intro = intro
            self.action_name = action_name

        def compose(self) -> ComposeResult:
            with Container(id="command-modal"):
                yield Static(self.title, id="command-modal-title")
                if self.intro:
                    yield Static(self.intro, id="command-modal-intro")
                for field in self.fields:
                    yield Label(str(field.get("label", "")), classes="command-modal-label")
                    yield make_form_control(field)
                yield Static("", id="command-modal-error")
                with Horizontal(id="command-modal-actions"):
                    yield Button("Cancel", id="command-cancel")
                    yield Button(self.submit_label, id="command-submit", variant="primary")

        def on_mount(self) -> None:
            if getattr(self.app, "theme_name", "dark") == "light":
                self.add_class("theme-light")
            controls = list(self.query(".command-field"))
            if controls:
                self.set_focus(controls[0])
            else:
                self.set_focus(self.query_one("#command-submit", Button))

        def collect_values(self) -> dict[str, str]:
            values: dict[str, str] = {}
            for field in self.fields:
                widget = self.query_one(f"#command-field-{field['name']}")
                values[str(field["name"])] = str(getattr(widget, "value", ""))
            return values

        def action_cancel(self) -> None:
            self.dismiss(None)

        def action_submit(self) -> None:
            values = self.collect_values()
            error = validate_command_form_values(self.action_name, values)
            if error:
                # Inline, in the modal: bad input must not close the form and
                # lose what the user already typed.
                self.query_one("#command-modal-error", Static).update(error)
                return
            self.dismiss(values)

        def on_input_submitted(self, event: Input.Submitted) -> None:
            # Enter inside a field is consumed by the Input itself; submit
            # from here so the keyboard path and the button path agree.
            self.action_submit()

        def on_input_changed(self, event: Input.Changed) -> None:
            self.query_one("#command-modal-error", Static).update("")

        def on_select_changed(self, event: Select.Changed) -> None:
            self.query_one("#command-modal-error", Static).update("")

        def on_button_pressed(self, event: Button.Pressed) -> None:
            if event.button.id == "command-cancel":
                self.dismiss(None)
            elif event.button.id == "command-submit":
                self.action_submit()

    class ConfirmScreen(ModalScreen[bool]):
        BINDINGS = [
            ("escape", "cancel", "Cancel"),
            ("enter", "confirm", "Confirm"),
        ]

        def __init__(self, title: str, message: str, confirm_label: str = "Confirm") -> None:
            super().__init__()
            self.title_text = title
            self.message_text = message
            self.confirm_label = confirm_label

        def compose(self) -> ComposeResult:
            with Container(id="confirm-modal"):
                yield Static(self.title_text, id="confirm-modal-title")
                yield Static(self.message_text, id="confirm-modal-message")
                with Horizontal(id="command-modal-actions"):
                    yield Button("Cancel", id="confirm-cancel")
                    yield Button(self.confirm_label, id="confirm-confirm", variant="error")

        def on_mount(self) -> None:
            if getattr(self.app, "theme_name", "dark") == "light":
                self.add_class("theme-light")
            self.set_focus(self.query_one("#confirm-confirm", Button))

        def action_cancel(self) -> None:
            self.dismiss(False)

        def action_confirm(self) -> None:
            self.dismiss(True)

        def on_button_pressed(self, event: Button.Pressed) -> None:
            if event.button.id == "confirm-cancel":
                self.dismiss(False)
            elif event.button.id == "confirm-confirm":
                self.dismiss(True)

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
            self.roster_table = SelectionTable(table)
            self.refresh_roster()
            self.set_focus(table)

        def refresh_roster(self) -> None:
            self.selected_player_id, selected_player = self.roster_table.rebuild(
                self.players,
                key_fn=lambda player: str(player.get("id", "")),
                row_fn=lambda player: [
                    str(player.get("id", "")),
                    escape_markup(player.get("username", "")),
                    str(player.get("gm_level", 0)),
                ],
                current_key=self.selected_player_id,
            )
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

    class SidebarItem(Static):
        """One clickable module row in the sidebar."""

        def __init__(self, view_id: str, key: str, label: str) -> None:
            super().__init__("", id=f"sidebar-item-{view_id}", classes="sidebar-item")
            self.view_id = view_id
            self.item_key = key
            self.item_label = label

        def on_click(self) -> None:
            self.app.switch_view(self.view_id)

    class DashboardCommandProvider(Provider):
        """Command palette entries: view navigation, refresh, theme."""

        def _entries(self) -> list[tuple[str, Any]]:
            app = self.app
            entries = [(f"Go to {VIEW_TITLES[view_id]}", getattr(app, f"action_show_{view_id}")) for view_id, _key, _label in SIDEBAR_MODULES]
            entries.append(("Manual refresh", app.action_manual_refresh))
            entries.append(("Toggle theme", app.action_toggle_theme))
            return entries

        async def discover(self) -> Hits:
            for display, command in self._entries():
                yield DiscoveryHit(display, command, help="Dashboard")

        async def search(self, query: str) -> Hits:
            matcher = self.matcher(query)
            for display, command in self._entries():
                score = matcher.match(display)
                if score > 0:
                    yield Hit(score, matcher.highlight(display), command, help="Dashboard")

    # One focusable container class per view carrying that view's command
    # bindings. Binding resolution walks the focused widget's ancestors, so
    # the keys are live exactly while a descendant of the view container (its
    # table, or the container itself) has focus.
    view_containers = {
        view_id: type(
            f"{view_id.capitalize()}ViewContainer",
            (Container,),
            {"BINDINGS": make_view_bindings(view_id), "can_focus": True},
        )
        for view_id in VIEW_KEYS
    }

    class VMangosDashboard(App[None]):
        CSS = DASHBOARD_CSS

        # ctrl+p opens Textual's command palette; our provider adds view
        # navigation, manual refresh, and the theme toggle to the built-ins.
        COMMANDS = App.COMMANDS | {DashboardCommandProvider}

        # Only navigation and app utilities stay global. Every command key
        # lives on its view's container (see view_containers below), so it
        # fires only while that view is focused — matching what the command
        # rail advertises.
        BINDINGS = [
            ("q", "quit", "Quit"),
            ("r", "manual_refresh", "Refresh"),
            ("1", "show_overview", "Overview"),
            ("2", "show_monitor", "Monitor"),
            ("3", "show_accounts", "Accounts"),
            ("4", "show_backups", "Backups"),
            ("5", "show_config", "Config"),
            ("6", "show_logs", "Logs"),
            ("7", "show_operations", "Ops"),
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
            self.last_action_receipt = ""
            self.last_action_next_step = ""
            self.last_action_view = self.active_view
            self.action_tone = "info"
            self.snapshot = empty_snapshot("waiting for first refresh")
            self.release_info: dict[str, Any] = {}
            self.metric_history: list[dict[str, Any]] = []
            self.selected_account_id = ""
            self.selected_backup_file = ""
            self.selected_log_key = ""
            self.selected_schedule_id = ""
            self.logs_query = normalize_logs_query()
            self.update_plan_data: dict[str, Any] | None = None
            self.refresh_inflight = False
            self.refresh_pending = False
            self.refresh_force_full = False
            self.last_refresh_failed = False
            self.snapshot_loaded = False
            self.action_inflight = False
            # Decided from the screen size, re-decided on resize and after the first
            # layout pass; the banner wording is written against it.
            self.narrow_viewport = False
            self.short_sidebar = False

        def compose(self) -> ComposeResult:
            # icon= keeps Textual's default glyph out of the header: it is
            # U+2B58, which most terminal fonts do not carry, so the first thing
            # an operator sees is a tofu box.
            yield Header(show_clock=True, icon="◆")
            with Horizontal(id="shell"):
                with Vertical(id="sidebar"):
                    yield Static("", id="sidebar-head")
                    for view_id, key, label in SIDEBAR_MODULES:
                        yield SidebarItem(view_id, key, label)
                    yield Static("", id="sidebar-pulse")
                    yield Static("", id="sidebar-target")
                with Container(id="content"):
                    yield Static("", id="action-banner")
                    with Container(id="view-stack"):
                        with view_containers["overview"](id="overview-view", classes="view"):
                            with Container(id="overview-grid"):
                                yield Static("", id="service-pane", classes="panel hero-panel")
                                yield Static("", id="metrics-pane", classes="panel accent-panel")
                                yield Static("", id="player-pulse-pane", classes="panel hero-panel")
                                yield Static("", id="alerts-pane", classes="panel accent-panel")
                        with view_containers["monitor"](id="monitor-view", classes="view hidden"):
                            with Container(id="monitor-grid"):
                                yield Static("", id="monitor-pressure-pane", classes="panel hero-panel")
                                yield Static("", id="monitor-process-pane", classes="panel accent-panel")
                                yield Static("", id="monitor-trends-pane", classes="panel hero-panel")
                                yield Static("", id="monitor-storage-pane", classes="panel accent-panel")
                        with view_containers["accounts"](id="accounts-view", classes="view hidden"):
                            with Horizontal(id="accounts-layout"):
                                with Vertical(classes="panel table-panel", id="accounts-table-layout"):
                                    yield Static("[b]Account Inventory[/b]", classes="table-detail-title")
                                    yield Input(placeholder="filter rows - Enter keeps, Esc clears", id="accounts-search", classes="table-search hidden")
                                    yield DataTable(id="accounts-table", classes="detail-table")
                                yield Static("", id="account-details", classes="panel hero-panel")
                        with view_containers["backups"](id="backups-view", classes="view hidden"):
                            with Horizontal(id="backups-layout"):
                                yield Static("", id="backup-summary", classes="panel hero-panel")
                                with Vertical(classes="panel table-panel", id="backups-table-layout"):
                                    yield Static("[b]Backup Inventory[/b]", classes="table-detail-title")
                                    yield Input(placeholder="filter rows - Enter keeps, Esc clears", id="backups-search", classes="table-search hidden")
                                    yield DataTable(id="backups-table", classes="detail-table")
                        with view_containers["config"](id="config-view", classes="view hidden"):
                            yield Static("", id="config-pane", classes="panel hero-panel")
                        with view_containers["logs"](id="logs-view", classes="view hidden"):
                            with Vertical(id="realm-logs-layout"):
                                yield Static("", id="realm-logs-summary", classes="panel hero-panel")
                                with Horizontal(id="realm-logs-body"):
                                    with Vertical(classes="panel table-panel", id="realm-logs-table-layout"):
                                        yield Static("[b]Recent Events[/b]", classes="table-detail-title")
                                        yield Input(placeholder="filter rows - Enter keeps, Esc clears", id="logs-search", classes="table-search hidden")
                                        yield DataTable(id="realm-logs-table", classes="detail-table")
                                    yield Static("", id="realm-log-details", classes="panel accent-panel")
                        with view_containers["operations"](id="operations-view", classes="view hidden"):
                            with Vertical(id="operations-layout"):
                                with Horizontal(id="operations-summary"):
                                    yield Static("", id="logs-pane", classes="panel accent-panel")
                                    yield Static("", id="update-pane", classes="panel hero-panel")
                                with Vertical(classes="panel table-panel table-detail", id="schedules-layout"):
                                    yield Static("[b]Scheduled Tasks[/b]", classes="table-detail-title")
                                    yield Static("", id="schedule-intro")
                                    yield Input(placeholder="filter rows - Enter keeps, Esc clears", id="schedules-search", classes="table-search hidden")
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

            realm_logs_table = self.query_one("#realm-logs-table", DataTable)
            realm_logs_table.cursor_type = "row"
            realm_logs_table.zebra_stripes = True
            realm_logs_table.add_columns("Time", "Source", "Severity", "Message")

            schedules_table = self.query_one("#schedules-table", DataTable)
            schedules_table.cursor_type = "row"
            schedules_table.zebra_stripes = True
            # Three columns, and the count is a measurement. The card gives the
            # roster 56 columns at 140x52 (the details pane takes the rest); four
            # columns of this data want 69, which is a horizontal scrollbar across
            # the bottom of the table and an ID column nobody can read. The timer's
            # name is printed by the details pane beside it, one glance away, so the
            # roster spends its columns on what the operator asks first: what runs,
            # when it runs, and when that happens next.
            schedules_table.add_columns("Type", "Schedule", "Next Run")

            # Long-lived controllers so unchanged data can skip table churn.
            self.selection_tables = {
                "accounts": SelectionTable(accounts_table, titles=["ID", "Username", "GM", "Online", "Banned"]),
                "backups": SelectionTable(backups_table, titles=["Timestamp", "Size", "File", "Created By"]),
                "logs": SelectionTable(realm_logs_table, titles=["Time", "Source", "Severity", "Message"]),
                "schedules": SelectionTable(schedules_table, titles=["Type", "Schedule", "Next Run"]),
            }

            # Identity before data: the console states which Manager build it
            # is driving even when nothing on the host answers yet.
            self.release_info = fetch_release_info(self.manager_bin, self.config_path)

            self.apply_theme()
            self.apply_view_state()
            self.apply_view_density()
            # At mount the screen has no size yet, so the density decision above is
            # taken from a zero-sized screen — which marked every terminal compact
            # (and, newly, narrow) until the window was resized. The deferred call
            # runs after the first layout pass, when the screen knows its size;
            # on_resize covers every change after that.
            self.call_after_refresh(self.apply_view_density)
            self.set_interval(self.refresh_interval, self.request_snapshot_refresh)

        def apply_theme(self) -> None:
            """Put the palette on the screens, not on the app node.

            Every light-palette override in DASHBOARD_CSS is written as
            ``Screen.theme-light`` (plus ``CommandFormScreen.theme-light`` and
            ``ConfirmScreen.theme-light``). Textual matches CSS against widgets,
            and the app node is not one, so the previous version — which added
            ``theme-light`` to the app — styled nothing: ``t`` and ``--theme
            light`` both redrew the same dark screen and reported success. The
            class now goes on every screen in the stack, including any modal
            already open, and is re-applied when a screen becomes active.
            """
            self.theme = "tokyo-night" if self.theme_name == "dark" else "catppuccin-latte"
            set_palette(self.theme_name)
            for screen in self.screen_stack:
                screen.set_class(self.theme_name == "light", "theme-light")
                screen.set_class(self.theme_name == "dark", "theme-dark")

        def on_screen_resume(self, event: object) -> None:
            """A modal pushed on top of the main screen inherits its palette."""
            self.apply_theme()

        def apply_view_density(self) -> None:
            """Pick the roomy or the scrolling grid layout for the active screen.

            The class lands on the screen rather than the app because Textual
            matches CSS against the screen and its widgets; a class on the app
            node styles nothing. Modals carry their own palette, so they are not
            part of this.
            """
            # App.size is the terminal the driver is talking to, and it is known
            # before the first layout pass; screen.size is zero until then, which
            # once made every session start out compact and narrow.
            compact = self.size.height < COMPACT_VIEWPORT_HEIGHT
            self.screen.set_class(compact, "compact")
            narrow = self.size.width < NARROW_VIEWPORT_WIDTH
            self.screen.set_class(narrow, "narrow")
            # The card grids stack on their own rule: two columns of card content
            # need more window than two columns of *window*, because a column that
            # is narrower than the row inside it is a row the card loses.
            self.screen.set_class(self.size.width < TWO_COLUMN_MINIMUM_WIDTH, "stacked")
            # The sidebar trims on its own height rule, decided from App.size for the
            # same reason the others are: before the first layout pass there is no
            # screen size to ask.
            self.short_sidebar = self.size.height < SHORT_VIEWPORT_HEIGHT
            # The class exists so the rail's width can follow the rail's own content:
            # the sidebar text is shortened below SHORT_VIEWPORT_HEIGHT, and that short
            # form is the only one narrow enough to survive a narrow rail. Without the
            # class, a window that is compact but not short — 100x36, measured — would
            # shrink the rail while still printing its long config line, and the line
            # would wrap.
            self.screen.set_class(self.short_sidebar, "short")
            if narrow != self.narrow_viewport:
                # The banner text is written for the room available, not merely
                # styled for it, so the decision has to be re-taken here: a window
                # that starts narrow and is widened keeps the cramped wording until
                # something else happens to repaint the banner.
                self.narrow_viewport = narrow
                self.refresh_chrome()

        def on_resize(self, event: object) -> None:
            self.apply_view_density()
            # The rail quotes how many rows of this view sit outside the window,
            # and a resize is precisely the moment that number changes. The scroll
            # extents are only known once the new layout has been worked out, so
            # the restatement waits for the layout pass instead of measuring the
            # window that is already gone.
            self.call_after_refresh(self.refresh_chrome)

        def apply_view_state(self) -> None:
            for view_name in ("overview", "monitor", "accounts", "backups", "config", "logs", "operations"):
                widget = self.query_one(f"#{view_name}-view", Container)
                if view_name == self.active_view:
                    widget.remove_class("hidden")
                else:
                    widget.add_class("hidden")

            self.refresh_chrome()
            # The newly visible view's data buckets may be stale — fetch
            # them fresh (coalesced with any inflight refresh).
            self.request_snapshot_refresh()
            if self.active_view == "accounts":
                self.set_focus(self.query_one("#accounts-table", DataTable))
            elif self.active_view == "backups":
                self.set_focus(self.query_one("#backups-table", DataTable))
            elif self.active_view == "logs":
                self.set_focus(self.query_one("#realm-logs-table", DataTable))
            elif self.active_view == "operations":
                self.set_focus(self.query_one("#schedules-table", DataTable))
            else:
                # Views without a table focus the view container itself so
                # its scoped command bindings are live.
                self.set_focus(self.query_one(f"#{self.active_view}-view", Container))

        def refresh_chrome(self) -> None:
            if self.modal_open():
                # The sidebar, the banner, and the rail live on the base screen,
                # so a query for them fails while a form or a confirmation covers
                # it. Nothing on that covered screen is being read, so there is
                # nothing to restate: the chrome comes back when the modal closes
                # and the next refresh finds the base screen current again.
                return
            self.query_one("#sidebar-head", Static).update(
                render_sidebar_head(self.release_info, self.snapshot.get("setup"))
            )
            for view_id, key, label in SIDEBAR_MODULES:
                item = self.query_one(f"#sidebar-item-{view_id}", SidebarItem)
                item.update(render_sidebar_module(view_id, key, label, active=view_id == self.active_view))
                item.set_class(view_id == self.active_view, "active")
            self.query_one("#sidebar-pulse", Static).update(
                render_sidebar_pulse(
                    self.snapshot, self.refresh_interval, short=self.short_sidebar
                )
            )
            self.query_one("#sidebar-target", Static).update(
                render_sidebar_target(self.snapshot, short=self.short_sidebar)
            )
            self.query_one("#action-banner", Static).update(
                render_action_banner(
                    self.active_view,
                    self.snapshot,
                    self.last_action,
                    self.action_tone,
                    self.refresh_interval,
                    self.last_action_receipt,
                    self.last_action_next_step,
                    self.last_action_view,
                    self.snapshot.get("setup"),
                    narrow=self.narrow_viewport,
                )
            )
            rows_above, rows_below = self.view_scroll_extent()
            self.query_one("#command-rail", Static).update(
                render_command_rail(
                    self.active_view,
                    narrow=self.narrow_viewport,
                    rows_above=rows_above,
                    rows_below=rows_below,
                    scroll_tokens=scroll_rail_tokens(self.focused),
                    width=self.command_rail_width(),
                )
            )

        def command_rail_width(self) -> int:
            """How wide the rail paints, so its rows can be wrapped by the pair.

            Read off the widget rather than computed from the viewport: the heavy
            border and the two-column padding both take cells, and a number guessed
            here is a row that wraps in the renderer anyway. Before the first layout
            pass there is no width to read, and 0 means "leave the row as one line"
            -- which is what every release up to this one did, permanently.
            """
            from textual.dom import NoMatches

            try:
                return self.query_one("#command-rail", Static).content_size.width
            except NoMatches:
                return 0

        async def on_key(self, event: object) -> None:
            """Restate the legend after any key, because a key is how focus moves.

            Which scroll keys the rail may quote depends on what holds focus, and a
            Textual 0.89 Focus event never reaches the App -- measured, not assumed:
            an on_focus handler on this class was never called, while on_key sees
            every key including Tab. The restatement is deferred a beat so the legend
            is drawn from the focus the key produced, not the focus it replaced.
            """
            self.call_after_refresh(self.refresh_chrome)

        def view_scroll_extent(self) -> tuple[int, int]:
            """Rows of the active view above and below what the window shows.

            Read from the live layout rather than counted from the cards: the
            rail is about to quote these numbers, and a count that disagreed with
            what the window could actually move would be a figure nobody could
            check. Before the first layout pass both are zero, which is the
            truthful answer -- there is nothing to report yet.
            """
            try:
                view = self.query_one(f"#{self.active_view}-view", Container)
            except Exception:
                return 0, 0
            above = int(round(view.scroll_y))
            below = int(round(view.max_scroll_y - view.scroll_y))
            return max(0, above), max(0, below)

        def modal_open(self) -> bool:
            # Any pushed screen (form, confirm, roster, command palette)
            # counts; the base screen is the only entry when none is open.
            return len(self.screen_stack) > 1

        def request_snapshot_refresh(self, *, full: bool = False) -> None:
            # Coalesce instead of dropping: if a refresh is already running,
            # remember that another one is wanted and run it when the
            # current worker finishes (see apply_snapshot). While a modal is
            # open, also hold off — refreshing under a dialog rebuilds the
            # tables the user is looking at (see resume_pending_refresh).
            if full:
                self.refresh_force_full = True
            if self.refresh_inflight or self.modal_open():
                self.refresh_pending = True
                return
            self.refresh_inflight = True
            threading.Thread(target=self.refresh_snapshot_worker, daemon=True).start()

        def resume_pending_refresh(self) -> None:
            """Run a refresh that was deferred while a modal was open."""
            if self.refresh_pending and not self.refresh_inflight and not self.modal_open():
                self.refresh_pending = False
                self.request_snapshot_refresh()

        def refresh_snapshot_worker(self) -> None:
            try:
                if self.snapshot_file:
                    snapshot = load_snapshot_fixture(self.snapshot_file)
                elif self.snapshot_loaded and not self.refresh_force_full:
                    # Only the active view's buckets are fetched fresh; the
                    # rest carry over from the previous snapshot.
                    snapshot = build_snapshot(
                        self.manager_bin,
                        self.config_path,
                        self.logs_query,
                        view=self.active_view,
                        previous=self.snapshot,
                    )
                else:
                    snapshot = build_snapshot(self.manager_bin, self.config_path, self.logs_query)
                self.last_refresh_failed = False
            except Exception as exc:
                snapshot = empty_snapshot(f"snapshot refresh failed: {exc}")
                # One toast per outage: notify on the ok -> failed transition
                # only, so a host that stays down does not spam every tick.
                if not self.last_refresh_failed:
                    self.call_from_thread(
                        self.notify,
                        f"Dashboard refresh failed: {exc}",
                        title="Refresh failed",
                        severity="error",
                    )
                self.last_refresh_failed = True
            self.call_from_thread(self.apply_snapshot, snapshot)

        def apply_snapshot(self, snapshot: dict[str, Any]) -> None:
            self.snapshot = snapshot
            self.snapshot_loaded = True
            if self.last_action == "loading dashboard data...":
                self.last_action = "latest data loaded"
                self.action_tone = "info"
            if not self.metric_history:
                self.metric_history = extract_seed_metric_history(snapshot)
            self.metric_history = append_monitoring_sample(self.metric_history, snapshot)
            self.refresh_inflight = False
            self.refresh_force_full = False
            self.repaint()
            if self.screenshot_path and not self.screenshot_taken and not self.screenshot_pending:
                self.screenshot_pending = True
                self.set_timer(0.5, self.capture_screenshot_and_exit)
            # A refresh requested while this one was running must not be
            # dropped — run it now that the UI thread is free again.
            if self.refresh_pending:
                self.refresh_pending = False
                self.request_snapshot_refresh()

        def repaint(self) -> None:
            """Redraw every pane and table from the snapshot in hand.

            Split out of apply_snapshot because the palette can change while the
            data has not. Re-running apply_snapshot to recolour would append the
            same sample to the monitor history again, so the repaint is its own
            step: same data, new colours.
            """
            snapshot = self.snapshot
            self.query_one("#service-pane", Static).update(render_service_panel(snapshot, self.active_view, narrow=self.narrow_viewport))
            self.query_one("#metrics-pane", Static).update(render_metrics_panel(snapshot, self.metric_history, self.refresh_interval, narrow=self.narrow_viewport))
            self.query_one("#player-pulse-pane", Static).update(render_player_pulse(snapshot, self.metric_history, self.refresh_interval, narrow=self.narrow_viewport))
            self.query_one("#alerts-pane", Static).update(render_alerts_panel(snapshot, narrow=self.narrow_viewport))
            self.query_one("#monitor-pressure-pane", Static).update(render_monitor_pressure(snapshot, self.metric_history, self.refresh_interval, narrow=self.narrow_viewport))
            self.query_one("#monitor-process-pane", Static).update(render_monitor_processes(snapshot, narrow=self.narrow_viewport))
            self.query_one("#monitor-trends-pane", Static).update(render_monitor_trends(snapshot, self.metric_history, self.refresh_interval, narrow=self.narrow_viewport))
            self.query_one("#monitor-storage-pane", Static).update(render_monitor_storage(snapshot))
            self.query_one("#config-pane", Static).update(render_config_panel(snapshot))
            self.query_one("#realm-logs-summary", Static).update(render_realm_logs_summary(snapshot))
            self.query_one("#logs-pane", Static).update(render_logs_panel(snapshot))
            self.query_one("#update-pane", Static).update(render_update_panel(snapshot, self.update_plan_data))
            self.refresh_accounts(snapshot.get("all_accounts", []))
            self.refresh_backups(snapshot.get("backups", {}).get("entries", []))
            self.refresh_logs(snapshot.get("log_events", []))
            self.refresh_schedules(snapshot.get("schedules", []))
            self.refresh_chrome()

        def capture_screenshot_and_exit(self) -> None:
            self.screenshot_taken = True
            self.save_screenshot(self.screenshot_path)
            self.exit()

        def selected_account(self) -> dict[str, Any] | None:
            return find_selected_account(self.snapshot, self.selected_account_id)

        def selected_backup(self) -> dict[str, Any] | None:
            return find_selected_backup(self.snapshot, self.selected_backup_file)

        def selected_log_entry(self) -> dict[str, Any] | None:
            return find_selected_log_entry(self.snapshot, self.selected_log_key)

        def selected_schedule(self) -> dict[str, Any] | None:
            return find_selected_schedule(self.snapshot, self.selected_schedule_id)

        def refresh_accounts(self, accounts: list[dict[str, Any]]) -> None:
            self.selected_account_id, account = self.selection_tables["accounts"].rebuild(
                accounts,
                key_fn=lambda account: str(account.get("id", "")),
                row_fn=lambda account: [
                    str(account.get("id", "")),
                    escape_markup(account.get("username", "")),
                    str(account.get("gm_level", 0)),
                    "yes" if account.get("online") else "no",
                    "yes" if account.get("banned") else "no",
                ],
                current_key=self.selected_account_id,
            )
            self.query_one("#account-details", Static).update(render_account_details(account, len(accounts)))

        def refresh_backups(self, entries: list[dict[str, Any]]) -> None:
            ordered = sorted(entries, key=lambda item: str(item.get("timestamp", "")), reverse=True)
            self.selected_backup_file, selected_entry = self.selection_tables["backups"].rebuild(
                ordered,
                key_fn=lambda entry: str(entry.get("file", "")),
                row_fn=lambda entry: [
                    escape_markup(iso_to_display(entry.get("timestamp"))),
                    escape_markup(format_bytes(entry.get("size_bytes", 0))),
                    escape_markup(str(entry.get("file", ""))),
                    escape_markup(str(entry.get("created_by", "n/a"))),
                ],
                current_key=self.selected_backup_file,
            )
            self.query_one("#backup-summary", Static).update(
                render_backups_summary(snapshot=self.snapshot, selected_backup=selected_entry)
            )

        def refresh_logs(self, entries: list[dict[str, Any]]) -> None:
            self.selected_log_key, selected_entry = self.selection_tables["logs"].rebuild(
                entries,
                key_fn=log_entry_key,
                row_fn=lambda entry: [
                    escape_markup(iso_to_display(entry.get("timestamp"))),
                    escape_markup(str(entry.get("source", ""))),
                    escape_markup(str(entry.get("severity", ""))),
                    escape_markup(truncate_text(entry.get("message", ""), 84)),
                ],
                current_key=self.selected_log_key,
            )
            self.query_one("#realm-log-details", Static).update(
                render_log_event_details(selected_entry, len(entries))
            )

        def refresh_schedules(self, schedules: list[dict[str, Any]]) -> None:
            self.query_one("#schedule-intro", Static).update(render_schedule_intro(schedules))
            ordered = sorted(
                schedules, key=lambda item: (str(item.get("next_run", "")), str(item.get("id", "")))
            )
            self.selected_schedule_id, selected_schedule = self.selection_tables["schedules"].rebuild(
                ordered,
                key_fn=lambda schedule: str(schedule.get("id", "")),
                row_fn=lambda schedule: [
                    escape_markup(schedule_job_type_label(schedule.get("job_type", ""))),
                    escape_markup(schedule_label(schedule)),
                    escape_markup(str(schedule.get("next_run", "") or "n/a")),
                ],
                current_key=self.selected_schedule_id,
            )
            self.query_one("#schedule-details", Static).update(
                render_schedule_details(selected_schedule, len(schedules))
            )

        def update_selected_account(self, row_key: Any) -> None:
            account = find_selected_account(self.snapshot, player_key_value(row_key))
            self.selected_account_id = str(account.get("id", "")) if account else ""
            self.query_one("#account-details", Static).update(
                render_account_details(account, len(self.snapshot.get("all_accounts", [])))
            )

        def update_selected_backup(self, row_key: Any) -> None:
            entry = find_selected_backup(self.snapshot, player_key_value(row_key))
            self.selected_backup_file = str(entry.get("file", "")) if entry else ""
            self.query_one("#backup-summary", Static).update(
                render_backups_summary(snapshot=self.snapshot, selected_backup=entry)
            )

        def update_selected_log(self, row_key: Any) -> None:
            entry = find_selected_log_entry(self.snapshot, player_key_value(row_key))
            self.selected_log_key = log_entry_key(entry) if entry else ""
            self.query_one("#realm-log-details", Static).update(
                render_log_event_details(entry, len(self.snapshot.get("log_events", [])))
            )

        def update_selected_schedule(self, row_key: Any) -> None:
            schedule = find_selected_schedule(self.snapshot, player_key_value(row_key))
            self.selected_schedule_id = str(schedule.get("id", "")) if schedule else ""
            self.query_one("#schedule-details", Static).update(
                render_schedule_details(schedule, len(self.snapshot.get("schedules", [])))
            )

        def table_row_handlers(self) -> dict[str, Any]:
            return {
                "accounts-table": self.update_selected_account,
                "backups-table": self.update_selected_backup,
                "realm-logs-table": self.update_selected_log,
                "schedules-table": self.update_selected_schedule,
            }

        def open_command_form(
            self,
            action_name: str,
            title: str,
            submit_label: str,
            fields: list[dict[str, Any]],
            intro: str = "",
        ) -> None:
            self.push_screen(
                CommandFormScreen(
                    title=title,
                    submit_label=submit_label,
                    fields=fields,
                    intro=intro,
                    action_name=action_name,
                ),
                lambda result, action_name=action_name: self.handle_command_form_result(action_name, result),
            )

        def handle_command_form_result(self, action_name: str, result: dict[str, str] | None) -> None:
            if result is None:
                self.resume_pending_refresh()
                return
            self.dispatch_dashboard_action(action_name, result)

        def request_confirmation(self, title: str, message: str, on_confirm, confirm_label: str = "Confirm") -> None:
            def handle(confirmed: bool) -> None:
                if confirmed:
                    on_confirm()
                else:
                    self.resume_pending_refresh()

            self.push_screen(
                ConfirmScreen(title=title, message=message, confirm_label=confirm_label),
                handle,
            )

        def active_search_input(self) -> Input | None:
            search_id = TABLE_VIEW_SEARCH_IDS.get(self.active_view)
            if not search_id:
                return None
            return self.query_one(f"#{search_id}", Input)

        def action_table_search(self) -> None:
            search_input = self.active_search_input()
            if search_input is None:
                return
            search_input.remove_class("hidden")
            self.set_focus(search_input)

        def close_table_search(self, *, clear: bool) -> None:
            search_input = self.active_search_input()
            if search_input is None or search_input.has_class("hidden"):
                return
            search_input.add_class("hidden")
            if clear:
                search_input.value = ""
            self.set_focus(self.query_one(f"#{self.active_view}-view", Container))

        def action_table_search_escape(self) -> None:
            self.close_table_search(clear=True)

        def action_sort_table(self) -> None:
            selection_key = TABLE_VIEW_SELECTION_KEYS.get(self.active_view)
            if selection_key is None:
                return
            controller = self.selection_tables[selection_key]
            column_count = len(controller.titles)
            if not column_count:
                return
            current = controller.sort_column
            nxt = None if current is not None and current + 1 >= column_count else 0 if current is None else current + 1
            controller.set_sort(nxt)
            self.rebuild_selection_table(selection_key)
            if nxt is None:
                self.set_action_result("table sort cleared", tone="info")
            else:
                self.set_action_result(f"table sorted by {controller.titles[nxt]}", tone="info")

        def on_input_changed(self, event: Input.Changed) -> None:
            selection_key = SEARCH_INPUT_TO_SELECTION.get(str(event.input.id or ""))
            if selection_key is None:
                return
            controller = self.selection_tables[selection_key]
            controller.set_filter(event.value)
            self.rebuild_selection_table(selection_key)

        def on_input_submitted(self, event: Input.Submitted) -> None:
            if str(event.input.id or "") in SEARCH_INPUT_TO_SELECTION:
                self.close_table_search(clear=False)

        def rebuild_selection_table(self, selection_key: str) -> None:
            if selection_key == "accounts":
                self.refresh_accounts(self.snapshot.get("all_accounts", []))
            elif selection_key == "backups":
                self.refresh_backups(self.snapshot.get("backups", {}).get("entries", []))
            elif selection_key == "logs":
                self.refresh_logs(self.snapshot.get("log_events", []))
            elif selection_key == "schedules":
                self.refresh_schedules(self.snapshot.get("schedules", []))

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
                feedback=dict(request.get("feedback", {})),
            )

        def on_data_table_row_highlighted(self, event: DataTable.RowHighlighted) -> None:
            handler = self.table_row_handlers().get(str(event.data_table.id))
            if handler:
                handler(event.row_key)

        def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
            handler = self.table_row_handlers().get(str(event.data_table.id))
            if handler:
                handler(event.row_key)

        def switch_view(self, view_id: str) -> None:
            """Switch to a view from any entry point (keys, sidebar clicks)."""
            if view_id not in VIEW_TITLES or view_id == self.active_view:
                return
            self.active_view = view_id
            self.apply_view_state()

        def action_show_overview(self) -> None:
            self.switch_view("overview")

        def action_show_monitor(self) -> None:
            self.switch_view("monitor")

        def action_show_accounts(self) -> None:
            self.switch_view("accounts")

        def action_show_backups(self) -> None:
            self.switch_view("backups")

        def action_show_config(self) -> None:
            self.switch_view("config")

        def action_show_logs(self) -> None:
            self.switch_view("logs")

        def action_show_operations(self) -> None:
            self.switch_view("operations")

        def move_active_view(self, move: str) -> None:
            """Scroll the view the operator is standing in, and restate what is left.

            The scroll keys sit on the view container, so a modal -- which is a
            different screen -- can never move the view behind it, and a focused
            table keeps its own cursor keys because Textual resolves bindings from
            the focused widget outward. No animation: over SSH an animated scroll
            reads as lag before it reads as movement.
            """
            view = self.query_one(f"#{self.active_view}-view", Container)
            getattr(view, move)(animate=False)
            # The rail's count is the only clue that a card is out of sight, so it
            # moves with the view rather than waiting for the next refresh tick.
            self.refresh_chrome()

        def action_scroll_view_up(self) -> None:
            self.move_active_view("scroll_up")

        def action_scroll_view_down(self) -> None:
            self.move_active_view("scroll_down")

        def action_scroll_view_page_up(self) -> None:
            self.move_active_view("scroll_page_up")

        def action_scroll_view_page_down(self) -> None:
            self.move_active_view("scroll_page_down")

        def action_scroll_view_home(self) -> None:
            self.move_active_view("scroll_home")

        def action_scroll_view_end(self) -> None:
            self.move_active_view("scroll_end")

        def action_manual_refresh(self) -> None:
            self.set_action_result(
                f"manual refresh requested at {datetime.now().strftime('%H:%M:%S')}",
                tone="info",
                receipt="Requested a fresh full dashboard snapshot from Manager.",
            )
            self.request_snapshot_refresh(full=True)

        def action_toggle_theme(self) -> None:
            self.theme_name = "light" if self.theme_name == "dark" else "dark"
            self.apply_theme()
            self.set_action_result(
                f"theme set to {self.theme_name}",
                tone="success",
                receipt=f"Switched the dashboard theme to {self.theme_name}.",
            )
            # Every pane is built from ACCENT_* at render time, so the switch is
            # only visible once the panels are rebuilt from the current snapshot.
            self.repaint()
            self.refresh_chrome()

        def action_start_server(self) -> None:
            self.request_command_action(
                "start",
                ["server", "start", "--wait", "--timeout", "60"],
                feedback={
                    "success_receipt": "Requested a realm start.",
                    "success_next": "Stay in Overview or Logs until auth and world both settle healthy.",
                    "failure_next": "Inspect service health and recent logs, then retry the start when the host is ready.",
                },
            )

        def action_stop_server(self) -> None:
            self.request_confirmation(
                "Stop the realm?",
                "Auth and world services will be stopped and connected players disconnected.",
                lambda: self.request_command_action(
                    "stop",
                    ["server", "stop", "--timeout", "60"],
                    feedback={
                        "success_receipt": "Requested a realm stop.",
                        "success_next": "Confirm auth and world settle inactive before backups, updates, or maintenance work.",
                        "failure_next": "Inspect service health and logs, then retry the stop when the host is ready.",
                    },
                ),
                confirm_label="Stop realm",
            )

        def action_restart_server(self) -> None:
            self.request_confirmation(
                "Restart the realm?",
                "Auth and world services will be restarted; players disconnect until the realm is back.",
                lambda: self.request_command_action(
                    "restart",
                    ["server", "restart", "--timeout", "60"],
                    feedback={
                        "success_receipt": "Requested a realm restart.",
                        "success_next": "Use Overview and Logs to confirm the realm settles cleanly after the restart.",
                        "failure_next": "Inspect service health and recent logs, then retry the restart when the host is ready.",
                    },
                ),
                confirm_label="Restart realm",
            )

        def handle_online_roster_result(self, account_id: str | None) -> None:
            if not account_id:
                self.resume_pending_refresh()
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
            self.request_command_action(
                "backup",
                ["backup", "now", "--verify"],
                feedback={
                    "success_receipt": "Started a fresh backup with verification enabled.",
                    "success_next": "Stay in Backups after refresh to review the new archive and protection posture.",
                    "failure_next": "Review backup directory access and DB connectivity, then retry from Backups.",
                },
            )

        def action_verify_selected_backup(self) -> None:
            backups = self.snapshot.get("backups", {})
            summary = backups.get("summary", {})
            backup_dir = str(summary.get("backup_dir", ""))
            if not self.selected_backup_file or not backup_dir:
                self.set_action_result("backup verify skipped: no backup selected", tone="warning")
                return

            backup_path = f"{backup_dir.rstrip('/')}/{self.selected_backup_file}"
            self.request_command_action(
                "verify",
                ["backup", "verify", backup_path, "--level", "1"],
                refresh_after=False,
                feedback={
                    "success_receipt": f"Verified backup {self.selected_backup_file}.",
                    "success_next": "If you need recovery planning, use dry-run (d) or preflight (p) here; live restore stays in the CLI.",
                    "failure_next": "Inspect the selected archive and retry verification from Backups.",
                },
            )

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
                "Create a new VMaNGOS account from the dashboard account workflow.",
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
                f"Ban {username} from the dashboard moderation workflow.",
            )

        def action_unban_account(self) -> None:
            account = self.selected_account()
            if account is None:
                self.set_action_result("account unban skipped: no account selected")
                return
            username = str(account.get("username", "selected account"))
            self.request_confirmation(
                f"Unban {username}?",
                f"The ban on {username} will be lifted immediately.",
                lambda: self.dispatch_dashboard_action("account_unban"),
                confirm_label="Unban account",
            )

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

        def action_restore_selected_backup_preflight(self) -> None:
            backup = self.selected_backup()
            if backup is None:
                self.set_action_result("restore preflight skipped: no backup selected", tone="warning")
                return
            backup_file = str(backup.get("file", "selected backup")).strip()
            self.active_view = "backups"
            self.apply_view_state()
            self.dispatch_dashboard_action("backup_restore_preflight")

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

        def handle_logs_filter_result(self, result: dict[str, str] | None) -> None:
            if result is None:
                return

            query = normalize_logs_query(result)
            if not LOG_SOURCE_PATTERN.fullmatch(query["source"]):
                self.set_action_result("logs filter skipped: source must be all, auth, or world", tone="warning")
                return
            if not LOG_WINDOW_PATTERN.fullmatch(query["window"]):
                self.set_action_result("logs filter skipped: window must look like 15m, 1h, or 1d", tone="warning")
                return
            if not LOG_SEVERITY_PATTERN.fullmatch(query["severity"]):
                self.set_action_result("logs filter skipped: severity must be all, debug, info, notice, warning, error, critical, or alert", tone="warning")
                return
            if not LOG_LIMIT_PATTERN.fullmatch(query["limit"]) or int(query["limit"]) > 200:
                self.set_action_result("logs filter skipped: limit must be between 1 and 200", tone="warning")
                return

            self.logs_query = query
            self.selected_log_key = ""
            self.active_view = "logs"
            self.apply_view_state()
            self.set_action_result(
                f"logs filters set: {query['source']} {query['window']} {query['severity']} limit {query['limit']}",
                tone="info",
                receipt=f"Focused the realm event feed on source={query['source']}, window={query['window']}, severity={query['severity']}, limit={query['limit']}.",
                next_step="Inspect Selected Event here, then move to Operations only if the incident becomes maintenance or change-window work.",
            )
            self.request_snapshot_refresh()

        def action_filter_logs(self) -> None:
            self.active_view = "logs"
            self.apply_view_state()
            self.push_screen(
                CommandFormScreen(
                    title="Log Filters",
                    submit_label="Apply",
                    fields=[
                        {
                            "name": "source",
                            "label": "Source",
                            "type": "select",
                            "options": LOG_FILTER_OPTIONS["source"],
                            "value": self.logs_query["source"],
                        },
                        {
                            "name": "window",
                            "label": "Window",
                            "type": "select",
                            "options": LOG_FILTER_OPTIONS["window"],
                            "value": self.logs_query["window"],
                        },
                        {
                            "name": "severity",
                            "label": "Severity",
                            "type": "select",
                            "options": LOG_FILTER_OPTIONS["severity"],
                            "value": self.logs_query["severity"],
                        },
                        {
                            "name": "limit",
                            "label": "Limit",
                            "type": "select",
                            "options": LOG_FILTER_OPTIONS["limit"],
                            "value": self.logs_query["limit"],
                        },
                    ],
                    intro="Tune the realm log feed shown in this module. The dashboard will keep following the current filters on each refresh.",
                ),
                self.handle_logs_filter_result,
            )

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
                "Create a scheduled maintenance task using Manager's configured maintenance command.",
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
                "Create a scheduled restart window with warning timers.",
            )

        def action_refresh_update_plan(self) -> None:
            self.active_view = "operations"
            self.apply_view_state()
            self.request_update_plan_refresh()

        def action_cancel_selected_schedule(self) -> None:
            schedule = self.selected_schedule()
            if schedule is None:
                self.set_action_result("task removal skipped: no task selected", tone="warning")
                return
            schedule_id = str(schedule.get("id", "selected schedule")).strip()
            self.active_view = "operations"
            self.apply_view_state()
            self.open_command_form(
                "schedule_cancel",
                "Remove Scheduled Task",
                "Remove Task",
                [],
                f"Remove scheduled task {schedule_id} from Manager and systemd.",
            )

        def request_update_plan_refresh(self) -> None:
            if self.action_inflight:
                self.set_action_result("another dashboard action is already running", tone="warning")
                return
            self.action_inflight = True
            view_context = self.active_view
            self.set_action_result(
                "update plan running...",
                tone="running",
                receipt="Checking repo drift and DB impact for the next change window.",
                view_context=view_context,
            )
            threading.Thread(target=self.run_update_plan_action, args=(view_context,), daemon=True).start()

        def run_update_plan_action(self, view_context: str) -> None:
            try:
                result = run_manager_command(
                    self.manager_bin,
                    self.config_path,
                    ["update", "plan", "--include-db"],
                    use_global_json=True,
                )
                if not result["ok"]:
                    message = result["error"].strip().splitlines()[-1] if result["error"].strip() else f"update plan exited with code {result['exit_code']}"
                    self.call_from_thread(self.set_action_result, f"update plan failed: {message}", "error", "", "", view_context)
                    return

                self.call_from_thread(self.apply_update_plan_data, result["data"], view_context)
            except Exception as exc:  # noqa: BLE001 - daemon thread: never die silently
                self.call_from_thread(
                    self.set_action_result,
                    f"update plan failed: {exc}",
                    "error",
                    "",
                    "",
                    view_context,
                )
            finally:
                self.action_inflight = False

        def apply_update_plan_data(self, data: dict[str, Any], view_context: str | None = None) -> None:
            self.update_plan_data = data
            warning_text = str(data.get("warning", "") or "")
            if warning_text:
                self.set_action_result(
                    f"update plan refreshed: {warning_text}",
                    tone="warning",
                    receipt="Generated a change-window plan and flagged follow-up work before code changes.",
                    next_step="Review Change Window Readiness, then confirm backups and maintenance timing before any CLI update apply step.",
                    view_context=view_context,
                )
            else:
                self.set_action_result(
                    "update plan refreshed",
                    tone="success",
                    receipt="Generated a fresh change-window plan with current repo and DB impact.",
                    next_step="Review the plan snapshot here, then continue the actual update workflow from the CLI after backup and maintenance prep.",
                    view_context=view_context,
                )
            self.query_one("#update-pane", Static).update(render_update_panel(self.snapshot, self.update_plan_data))

        def request_command_action(
            self,
            label: str,
            command: list[str],
            *,
            refresh_after: bool = True,
            env: dict[str, str] | None = None,
            feedback: dict[str, str] | None = None,
        ) -> None:
            if self.action_inflight:
                self.set_action_result("another dashboard action is already running", tone="warning")
                return
            self.action_inflight = True
            view_context = self.active_view
            running_receipt = ""
            if feedback:
                running_receipt = feedback.get("success_receipt", "")
            self.set_action_result(f"{label} running...", tone="running", receipt=running_receipt, view_context=view_context)
            threading.Thread(
                target=self.run_command_action,
                args=(label, command, refresh_after, env or {}, feedback or {}, view_context),
                daemon=True,
            ).start()

        def run_command_action(
            self,
            label: str,
            command: list[str],
            refresh_after: bool,
            env: dict[str, str],
            feedback: dict[str, str],
            view_context: str,
        ) -> None:
            try:
                result = run_manager_command(
                    self.manager_bin,
                    self.config_path,
                    command,
                    parser_mode="raw",
                    env=env,
                )
                output = (result["data"] or result["error"] or "").strip().splitlines()
                message = output[-1] if output else f"{label} exited with code {result['exit_code']}"
                if result["ok"]:
                    receipt = feedback.get("success_receipt", "")
                    next_step = feedback.get("success_next", "")
                    self.call_from_thread(
                        self.set_action_result,
                        f"{label}: {message}",
                        "success",
                        receipt,
                        next_step,
                        view_context,
                    )
                    if refresh_after:
                        self.call_from_thread(self.request_snapshot_refresh)
                else:
                    receipt = feedback.get("failure_receipt", "")
                    next_step = feedback.get("failure_next", "")
                    self.call_from_thread(
                        self.set_action_result,
                        f"{label} failed: {message}",
                        "error",
                        receipt,
                        next_step,
                        view_context,
                    )
            except Exception as exc:  # noqa: BLE001 - daemon thread: never die silently
                self.call_from_thread(
                    self.set_action_result,
                    f"{label} failed: {exc}",
                    "error",
                    "",
                    "",
                    view_context,
                )
            finally:
                self.action_inflight = False

        def set_action_result(
            self,
            message: str,
            tone: str = "info",
            receipt: str = "",
            next_step: str = "",
            view_context: str | None = None,
        ) -> None:
            self.last_action = message
            self.last_action_receipt = receipt
            self.last_action_next_step = next_step
            self.last_action_view = view_context or self.active_view
            self.action_tone = tone
            self.refresh_chrome()
            self.query_one("#service-pane", Static).update(render_service_panel(self.snapshot, self.active_view, narrow=self.narrow_viewport))
            if self.active_view == "operations":
                self.query_one("#schedule-details", Static).update(
                    render_schedule_details(self.selected_schedule(), len(self.snapshot.get("schedules", [])))
                )
                self.query_one("#update-pane", Static).update(render_update_panel(self.snapshot, self.update_plan_data))
            # Toasts for action completion (success/attention/failure); the
            # info and running tones are progress, not outcomes.
            if tone in ("success", "warning", "error"):
                tone_label = ACTION_STYLES.get(tone, ACTION_STYLES["info"])[0]
                severity = {"success": "information", "warning": "warning", "error": "error"}[tone]
                self.notify(receipt or message, title=tone_label, severity=severity)

    return VMangosDashboard()


DASHBOARD_CSS = """
        Screen {
            background: #071522;
            color: #e6edf7;
            scrollbar-color: #3b82f6;
            scrollbar-color-hover: #7dd3fc;
            scrollbar-color-active: #7dd3fc;
            scrollbar-background: #12283c;
            scrollbar-corner-color: #12283c;
        }

        Screen.theme-light {
            background: #f6f1e7;
            color: #142033;
            scrollbar-color: #5a6673;
            scrollbar-color-hover: #1d4ed8;
            scrollbar-color-active: #1d4ed8;
            scrollbar-background: #e7e1d6;
            scrollbar-corner-color: #e7e1d6;
        }

        /* Scrollbar colour is not inherited: Textual reads it off each scrollable
           widget, so a rule on Screen alone leaves every inner pane painted in
           Textual's default purple (measured: #4f4270 dark, #b89ae5 light — a hue
           neither palette contains). The universal rule is what makes the whole
           tree honest; Screen keeps its own copy so the background it paints
           behind a scrollbar is the one it chose. */
        * {
            scrollbar-color: #3b82f6;
            scrollbar-color-hover: #7dd3fc;
            scrollbar-color-active: #7dd3fc;
            scrollbar-background: #12283c;
            scrollbar-corner-color: #12283c;
        }

        Screen.theme-light * {
            scrollbar-color: #5a6673;
            scrollbar-color-hover: #1d4ed8;
            scrollbar-color-active: #1d4ed8;
            scrollbar-background: #e7e1d6;
            scrollbar-corner-color: #e7e1d6;
        }

        Header {
            background: #143b7a;
            color: #f8fafc;
        }

        Screen.theme-light Header {
            background: #c9e1ff;
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
            overflow-y: auto;
        }

        Screen.theme-light #sidebar {
            border-right: heavy #f59e0b;
            background: #eef6ff;
        }

        #sidebar-head {
            height: auto;
        }

        .sidebar-item {
            width: 1fr;
            height: 1;
            padding: 0 1;
            background: transparent;
        }

        .sidebar-item:hover {
            background: #12283f;
        }

        Screen.theme-light .sidebar-item:hover {
            background: #dbeafe;
        }

        .sidebar-item.active {
            background: #0f2233;
        }

        Screen.theme-light .sidebar-item.active {
            background: #cfe8ff;
        }

        #sidebar-pulse {
            height: auto;
            margin-top: 1;
        }

        #sidebar-target {
            height: auto;
            margin-top: 1;
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

        /* The rail is the only place a keyboard operator learns what this view
           can do, so it may never clip its own rows. Its Navigate row is a list
           of tokens, and that list wraps when the content column is narrower than
           about 140 columns; a fixed height of 5 then pushes the third row -- the
           view's own actions -- out of the box entirely. Height follows content,
           and the scrollable view above gives the row up instead. */
        #command-rail {
            height: auto;
            min-height: 5;
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

        /* Short terminals: the two-row grids are sized for a tall window.
           When the remainder after the fixed first row is zero, the lower
           panels become empty frames, which reads as a broken console rather
           than a small one. Below COMPACT_VIEWPORT_HEIGHT the panels take
           their natural height and the view scrolls instead. */
        .compact #overview-grid {
            height: auto;
            grid-rows: 15 auto;
        }

        .compact #monitor-grid {
            height: auto;
            grid-rows: 18 auto;
        }

        .compact #overview-view,
        .compact #monitor-view {
            overflow-y: auto;
        }

        /* Narrow terminals. The layout that fails first is a fixed side panel
           beside a 1fr table: measured at 100 columns the Accounts table was left
           about twenty columns wide and drew an empty frame, which reads as a
           broken console rather than a small one. Below NARROW_VIEWPORT_WIDTH the
           pairs stack, each pane gets the full width, and the view scrolls. */
        .narrow #accounts-layout,
        .narrow #backups-layout {
            layout: vertical;
            height: auto;
        }

        .narrow #accounts-table-layout {
            width: 1fr;
            height: auto;
            min-height: 12;
            margin-right: 0;
            margin-bottom: 1;
        }

        .narrow #account-details {
            width: 1fr;
            height: auto;
        }

        .narrow #backups-table-layout {
            width: 1fr;
            height: auto;
            min-height: 12;
        }

        .narrow #backup-summary {
            width: 1fr;
            min-width: 0;
            height: auto;
            margin-right: 0;
            margin-bottom: 1;
        }

        .narrow .table-detail-body {
            layout: vertical;
            height: auto;
        }

        .narrow .table-detail {
            /* The body stacks vertically here, so the card's floor has to cover a
               roster sitting on top of its details pane instead of beside it. */
            min-height: 22;
        }

        .narrow .detail-pane {
            width: 1fr;
            height: auto;
            margin-left: 0;
            margin-top: 1;
            border-left: none;
            border-top: heavy #f59e0b;
            padding-left: 0;
            padding-top: 1;
        }

        Screen.theme-light .narrow .detail-pane {
            border-left: none;
            border-top: heavy #93c5fd;
        }

        /* Panels that reserve a fixed height for prose: in a 36-row window the
           reservation is the view. They take their natural height instead and the
           view scrolls. */
        .narrow #realm-logs-layout {
            height: auto;
        }

        .narrow #realm-logs-summary,
        .narrow #operations-summary {
            height: auto;
            margin-bottom: 1;
        }

        .narrow #operations-summary {
            layout: vertical;
        }

        .narrow #logs-pane,
        .narrow #update-pane {
            width: 1fr;
            height: auto;
            margin-right: 0;
            margin-bottom: 1;
        }

        .narrow #realm-logs-body,
        .narrow #roster-modal-layout {
            layout: vertical;
            height: auto;
            min-height: 14;
        }

        .narrow #accounts-view,
        .narrow #backups-view,
        .narrow #logs-view,
        .narrow #config-view,
        .narrow #operations-view {
            overflow-y: auto;
        }

        /* The card grids never got a narrow form. At 100 columns each card is
           handed about 46 columns, which cannot hold a title, a sentence about
           what the card contains, and a line of data: the second row of the grid
           collapsed into bordered frames with nothing in them. Below
           NARROW_VIEWPORT_WIDTH the cards take the full width and stack, and the
           view scrolls -- which is what a small window is for. */
        .narrow #overview-grid,
        .narrow #monitor-grid,
        .stacked #overview-grid,
        .stacked #monitor-grid {
            grid-size: 1 4;
            grid-columns: 1fr;
            grid-rows: auto auto auto auto;
            height: auto;
        }

        /* The rail is 32 columns wide at every width. That is a third of a
           100-column terminal and two fifths of an 80-column one, and the cards
           beside it need about 53 columns before their own lines stop wrapping:
           measured at 80 columns the Overview asked for 60 rows of content to hold
           four cards whose unwrapped height is 47, every extra row a line the card
           had to break.

           So the rail gives four columns back — in the one band where its own text can
           afford it, which is a measurement rather than a hedge. The rail keeps 2
           columns of padding on each side and loses a column to its own scrollbar when
           its content is taller than the window, so 28 leaves 23 usable. The short
           form of the Console Target block has a longest line of 22 and fits; the long
           form's "config    manager.conf ok" is 25 and broke in half at 100x36, which
           is compact but not short. A window tall enough to keep that line has vertical
           room to spare and its card lines are not wrapping, so the rail keeps its 32
           columns there. A test boots every band and refuses any wrapped line in the
           rail, so these numbers stay honest if the wording changes. */
        .short.narrow #sidebar {
            width: 28;
            min-width: 28;
        }

        /* A short window spends two rows per card on padding, and the Overview has
           four of them: eight rows gone from a 24-row terminal that can show twenty.
           The border is what separates one card from the next; the padding only ever
           separated a card's title from its own border. */
        .compact .panel {
            padding: 0 2;
        }

        .narrow #overview-view,
        .narrow #monitor-view,
        .stacked #overview-view,
        .stacked #monitor-view {
            overflow-y: auto;
        }

        /* The 14-row floor on the monitor cards belongs to the wide two-column
           layout, where each card had two rows per metric to fill. Stacked, the
           floor is what decides how many cards a short window can show at all:
           at 36 rows it showed one and a half. With one row per metric a full
           card is seven rows of data, so the floor drops to hold that and the
           scroll is spent on the card that genuinely has more to say. */
        .narrow #monitor-pressure-pane,
        .narrow #monitor-process-pane,
        .narrow #monitor-trends-pane,
        .narrow #monitor-storage-pane,
        .narrow #service-pane,
        .narrow #metrics-pane,
        .narrow #player-pulse-pane,
        .narrow #alerts-pane,
        .stacked #monitor-pressure-pane,
        .stacked #monitor-process-pane,
        .stacked #monitor-trends-pane,
        .stacked #monitor-storage-pane,
        .stacked #service-pane,
        .stacked #metrics-pane,
        .stacked #player-pulse-pane,
        .stacked #alerts-pane {
            min-height: 9;
        }

        /* The 9 above is an accounting of the padded card, not a preference: the
           Realm Services card's short form is five lines, and five lines plus two
           rows of padding plus two rows of border is exactly nine. A compact window
           spends no rows on padding, so the same floor would be painting two blank
           rows inside the first card — in the window with the least room of all. The
           floor drops to what the content plus the border actually is. */
        .compact.narrow #service-pane,
        .compact.narrow #metrics-pane,
        .compact.narrow #player-pulse-pane,
        .compact.narrow #alerts-pane,
        .compact.stacked #service-pane,
        .compact.stacked #metrics-pane,
        .compact.stacked #player-pulse-pane,
        .compact.stacked #alerts-pane {
            min-height: 7;
        }

        /* The rows left to take in a window this short are not inside the cards,
           they are the air around them. Measured at 100x24: the grid began at row 8
           and the view could show eight of its own rows. Above it sat one row of
           header, one row of #content's top padding, five rows of banner (heavy
           border, a padding row, two lines, another border), and one row of the
           banner's bottom margin; six more rows below went to the command rail.
           Three of those rows are decoration a border already supplies, and a
           24-row terminal cannot afford decoration. The cards keep their gutters —
           what goes away is the padding above the first card and inside the banner. */
        .short #content {
            padding: 0 2 0 1;
        }

        .short #action-banner {
            padding-top: 0;
            margin-bottom: 0;
        }

        /* Equal columns. The split used to be 7fr 5fr, which handed the narrower
           column to the card with the longest row: the process card needs 53
           columns and got 37 at a 140-column window, while the pressure card needed
           50 and got 54. */
        #monitor-grid {
            layout: grid;
            grid-size: 2 2;
            grid-columns: 1fr 1fr;
            grid-rows: 18 1fr;
            grid-gutter: 1 2;
            height: 1fr;
        }

        .table-detail {
            layout: vertical;
            /* auto, and it has to stay auto. This card lives inside
               `#operations-layout { height: auto }` in a view that scrolls, and an
               `1fr` panel in an auto layout resolves to zero rows: the Scheduled
               Tasks border drew itself four rows tall at 140x52 while the title,
               the roster, and the details pane were placed underneath it and
               clipped out of sight. Pressing 7 showed an empty box. The roster's
               own height is decided in Python for the same reason — see
               SelectionTable.apply_frame_height. */
            height: auto;
            min-height: 14;
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
            /* auto: the details pane beside the roster is prose, and the card has
               to grow to hold it. Nothing inside this row is allowed a `1fr`
               height, or the row has nothing to resolve it against and the table
               outgrows the border around it. */
            height: auto;
            min-height: 10;
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
            height: auto;
        }

        #accounts-layout {
            layout: horizontal;
        }

        #accounts-table-layout {
            width: 1fr;
            height: auto;
            min-height: 12;
            margin-right: 1;
        }

        #account-details {
            width: 40;
            min-width: 36;
            height: auto;
            min-height: 9;
        }

        #operations-layout {
            height: auto;
            layout: vertical;
        }

        #operations-summary {
            height: auto;
            margin-bottom: 1;
        }

        #logs-pane,
        #update-pane {
            width: 1fr;
            height: auto;
            min-height: 9;
        }

        #logs-pane {
            margin-right: 1;
        }

        #schedules-table {
            height: 1fr;
            min-height: 8;
        }

        #schedule-details {
            height: auto;
            min-height: 9;
        }

        #backup-summary {
            width: 48;
            min-width: 46;
            height: auto;
            min-height: 12;
            margin-right: 1;
        }

        #backups-table-layout {
            width: 1fr;
            height: auto;
            min-height: 12;
        }

        DataTable {
            background: #0a1828;
            color: #e6edf7;
        }

        Screen.theme-light DataTable {
            background: #ffffff;
            color: #111827;
        }

        /* Row cursor. Left to Textual, the cursor is painted from its own theme
           variables: a purple that belongs to no palette in this file, and in the
           light theme a pale block on white that reads as nothing at all. Both the
           focused and the unfocused state are set here, because the unfocused one
           is what the operator sees while reading a panel they are not in. */
        DataTable > .datatable--cursor,
        DataTable > .datatable--header-cursor,
        DataTable > .datatable--fixed-cursor {
            background: #274463;
            color: #e6edf7;
        }

        DataTable:focus > .datatable--cursor,
        DataTable:focus > .datatable--header-cursor,
        DataTable:focus > .datatable--fixed-cursor {
            background: #2563eb;
            color: #f8fafc;
        }

        Screen.theme-light DataTable > .datatable--cursor,
        Screen.theme-light DataTable > .datatable--header-cursor,
        Screen.theme-light DataTable > .datatable--fixed-cursor {
            background: #b9c6d6;
            color: #142033;
        }

        Screen.theme-light DataTable:focus > .datatable--cursor,
        Screen.theme-light DataTable:focus > .datatable--header-cursor,
        Screen.theme-light DataTable:focus > .datatable--fixed-cursor {
            background: #1d4ed8;
            color: #ffffff;
        }

        #backups-table {
            height: 1fr;
            width: 1fr;
            margin-top: 1;
        }

        #config-pane {
            height: auto;
            min-height: 12;
        }

        #realm-logs-layout {
            height: auto;
            layout: vertical;
        }

        #realm-logs-summary {
            height: auto;
            min-height: 9;
            margin-bottom: 1;
        }

        #realm-logs-body {
            height: 1fr;
        }

        #realm-logs-table-layout {
            width: 1fr;
            height: auto;
            min-height: 12;
            margin-right: 1;
        }

        #realm-logs-table {
            height: 1fr;
            margin-top: 1;
        }

        #realm-log-details {
            width: 42;
            min-width: 36;
            height: auto;
            min-height: 9;
        }

        /* Reading panes are prose the operator has to be able to finish, so they
           take their natural height at every width and the view scrolls instead of
           cutting them. This is not a small-window rule: measured at 140x52, which is
           a comfortable window, the Backups card wanted 37 display rows in a 30-row
           box, and what fell off the end was the databases the archive covers, who
           made it, and the one line telling you live restore is CLI-only. The Ops
           cards wanted 14 and 22 rows in boxes of 9. Tables are the exception — a
           table that is taller than the window can scroll itself — so they keep a
           floor rather than a natural height. */
        #accounts-view,
        #backups-view,
        #logs-view,
        #config-view,
        #operations-view {
            overflow-y: auto;
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

        .table-search {
            margin: 0 0 1 0;
            border: round #14b8a6;
        }

        .table-search.hidden {
            display: none;
        }

        #confirm-modal {
            width: 72;
            max-width: 100;
            height: auto;
            border: heavy #ef4444;
            background: #0c1b2c;
            padding: 1 2 2 2;
        }

        ConfirmScreen.theme-light #confirm-modal {
            border: round #dc2626;
            background: #fffdf7;
        }

        #confirm-modal-title {
            text-style: bold;
            color: #f87171;
            margin-bottom: 1;
        }

        ConfirmScreen.theme-light #confirm-modal-title {
            color: #b91c1c;
        }

        #confirm-modal-message {
            color: #e6edf7;
            margin-bottom: 1;
        }

        ConfirmScreen.theme-light #confirm-modal-message {
            color: #142033;
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

        #command-modal Select {
            margin-top: 0;
            margin-bottom: 1;
            border: round #1d4ed8;
            background: #102033;
            color: #f8fafc;
            width: 1fr;
        }

        CommandFormScreen.theme-light #command-modal Select {
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
