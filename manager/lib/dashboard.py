#!/usr/bin/env python3
"""Textual dashboard for VMANGOS Manager."""

from __future__ import annotations

import argparse
import json
import os
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


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="VMANGOS Manager Textual dashboard")
    parser.add_argument("--manager-bin", required=True, help="Path to vmangos-manager")
    parser.add_argument("--config", required=True, help="Path to manager.conf")
    parser.add_argument("--refresh", type=int, default=2, help="Refresh interval in seconds")
    parser.add_argument("--theme", choices=("dark", "light"), default="dark", help="Dashboard theme")
    parser.add_argument("--screenshot", help="Write an SVG screenshot after the first refresh and exit")
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


def truncate_text(value: Any, max_length: int = 76) -> str:
    text = str(value or "")
    if len(text) <= max_length:
        return text
    return f"{text[: max_length - 3]}..."


def escape_markup(value: Any) -> str:
    return str(value or "").replace("[", "\\[").replace("]", "\\]")


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
        "server": {"ok": False, "data": {}, "error": error_message},
        "logs": {"ok": False, "data": {}, "error": error_message},
        "accounts_online": {"ok": False, "data": {}, "error": error_message},
        "accounts": {"ok": False, "data": {}, "error": error_message},
        "backup_list": {"ok": False, "data": [], "error": error_message},
        "config_validate": {"ok": False, "data": {}, "error": error_message},
        "config_show": {"ok": False, "data": {}, "error": error_message},
        "config_summary": {},
        "config_content": "",
        "backups": {"entries": [], "summary": {}},
        "players": [],
        "all_accounts": [],
    }


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
    backups = run_manager_command(
        manager_bin,
        config_path,
        ["backup", "list", "--format", "json"],
        parser_mode="json",
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
    backup_dir = config_values.get("backup.backup_dir", "")
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
    }

    return {
        "captured_at": now_iso(),
        "server": server,
        "logs": logs,
        "accounts_online": online_accounts,
        "accounts": accounts,
        "backup_list": backups,
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
    }


def render_sidebar(active_view: str, last_action: str) -> str:
    sections = [
        ("overview", "1", "Overview"),
        ("accounts", "2", "Accounts"),
        ("backups", "3", "Backups"),
        ("config", "4", "Config"),
    ]

    lines = [f"[bold {ACCENT_GOLD}]Manager Console[/]", "", f"[bold {ACCENT_SKY}]Views[/]"]
    for name, key, label in sections:
        if name == active_view:
            lines.append(f"[bold {ACCENT_TEAL}]▶[/] [bold {ACCENT_GOLD}]{key}[/] [bold {ACCENT_TEAL}]{label}[/]")
        else:
            lines.append(f"[{ACCENT_MUTED}]  [/] [bold {ACCENT_GOLD}]{key}[/] [{ACCENT_MUTED}]{label}[/]")

    lines.extend(
        [
            "",
            f"[bold {ACCENT_SKY}]Actions[/]",
            f"[bold {ACCENT_GOLD}]r[/]  refresh",
            f"[bold {ACCENT_GOLD}]s[/]  start server",
            f"[bold {ACCENT_GOLD}]x[/]  stop server",
            f"[bold {ACCENT_GOLD}]R[/]  restart server",
            f"[bold {ACCENT_GOLD}]b[/]  backup now",
            f"[bold {ACCENT_GOLD}]v[/]  verify backup",
            f"[bold {ACCENT_GOLD}]t[/]  theme",
            f"[bold {ACCENT_GOLD}]q[/]  quit",
            "",
            f"[bold {ACCENT_SKY}]Last Action[/]",
            f"[{ACCENT_MUTED}]{escape_markup(truncate_text(last_action, 80)) or 'dashboard started'}[/]",
        ]
    )
    return "\n".join(lines)


def render_service_panel(snapshot: dict[str, Any], active_view: str) -> str:
    server = snapshot["server"]
    if not server["ok"]:
        return "\n".join(
            [
                f"[bold {ACCENT_GOLD}]Service Overview[/]",
                "",
                f"[bold {ACCENT_ROSE}]Server snapshot failed:[/] {server['error']}",
                "",
                f"[{ACCENT_MUTED}]Current view:[/] {active_view}",
            ]
        )

    data = server["data"]
    auth = data.get("services", {}).get("auth", {})
    world = data.get("services", {}).get("world", {})
    checks = data.get("checks", {})
    db = checks.get("database_connectivity", {})
    players = data.get("players", {})

    return "\n".join(
        [
            f"[bold {ACCENT_GOLD}]Service Overview[/]",
            "",
            f"[bold {ACCENT_SKY}]Auth[/]   {format_state(auth.get('health', auth.get('state')))}  [{ACCENT_MUTED}]pid[/] {auth.get('pid', 0)}  [{ACCENT_MUTED}]up[/] {auth.get('uptime_human', 'N/A')}",
            f"[bold {ACCENT_SKY}]World[/]  {format_state(world.get('health', world.get('state')))}  [{ACCENT_MUTED}]pid[/] {world.get('pid', 0)}  [{ACCENT_MUTED}]up[/] {world.get('uptime_human', 'N/A')}",
            "",
            f"[bold {ACCENT_SKY}]DB[/]     {format_state('ok' if db.get('ok') else db.get('message', 'unreachable'))}",
            f"[bold {ACCENT_SKY}]Users[/]  [bold {ACCENT_GOLD}]{players.get('online', 0)}[/] [{ACCENT_MUTED}]online via[/] {players.get('source', 'unavailable')}",
            "",
            f"[{ACCENT_MUTED}]Snapshot[/] {iso_to_display(snapshot.get('captured_at'))}",
        ]
    )


def render_metrics_panel(snapshot: dict[str, Any]) -> str:
    server = snapshot["server"]
    logs = snapshot["logs"]
    lines = [f"[bold {ACCENT_GOLD}]Host Metrics[/]", ""]

    if server["ok"]:
        data = server["data"]
        host = data.get("host", {})
        cpu = host.get("cpu", {})
        memory = host.get("memory", {})
        load = host.get("load", {})
        disk = data.get("checks", {}).get("disk_space", {})
        storage_io = data.get("storage_io", {})
        lines.extend(
            [
                f"[bold {ACCENT_SKY}]CPU[/]      {cpu.get('usage_percent', 0)}%  {format_state(cpu.get('status', 'unavailable'))}  [{ACCENT_MUTED}]cores[/] {cpu.get('cores', 0)}",
                f"[bold {ACCENT_SKY}]Memory[/]   {memory.get('used_percent', 0)}%  {format_state(memory.get('status', 'unavailable'))}  {format_mb_from_kb(memory.get('used_kb', 0))} [{ACCENT_MUTED}]used[/]",
                f"[bold {ACCENT_SKY}]Load[/]     {load.get('load_1', 0)} / {load.get('load_5', 0)} / {load.get('load_15', 0)}  {format_state(load.get('status', 'unavailable'))}",
                f"[bold {ACCENT_SKY}]Disk[/]     {disk.get('used_percent', 0)}%  {format_state(disk.get('status', 'unavailable'))}  [{ACCENT_MUTED}]free[/] {format_gb_from_kb(disk.get('available_kb', 0))}",
            ]
        )
        if storage_io.get("available"):
            lines.append(
                f"[bold {ACCENT_SKY}]I/O[/]      {storage_io.get('util_percent', 0)}% [{ACCENT_MUTED}]util[/]  {format_state(storage_io.get('status', 'unavailable'))}  {storage_io.get('device', 'n/a')}"
            )
        else:
            lines.append(
                f"[bold {ACCENT_SKY}]I/O[/]      {format_state(storage_io.get('status', 'unavailable'))}  [{ACCENT_MUTED}]install sysstat/iostat for live disk stats[/]"
            )
    else:
        lines.append(f"[bold {ACCENT_ROSE}]Server metrics unavailable:[/] {server['error']}")

    lines.extend(["", f"[bold {ACCENT_SKY}]Log Rotation[/]"])
    if logs["ok"]:
        data = logs["data"]
        config = data.get("config", {})
        log_counts = data.get("logs", {})
        disk = data.get("disk", {})
        lines.extend(
            [
                f"[bold {ACCENT_SKY}]Health[/]   {format_state(data.get('status', 'unavailable'))}",
                f"[bold {ACCENT_SKY}]Config[/]   present={config.get('present', False)}  in_sync={config.get('in_sync', False)}",
                f"[bold {ACCENT_SKY}]Files[/]    active={log_counts.get('active_files', 0)}  rotated={log_counts.get('rotated_files', 0)}",
                f"[bold {ACCENT_SKY}]Disk[/]     {disk.get('used_percent', 0)}% [{ACCENT_MUTED}]used[/]  [{ACCENT_MUTED}]free[/] {format_gb_from_kb(disk.get('available_kb', 0))}",
            ]
        )
    else:
        lines.append(f"[bold {ACCENT_ROSE}]Logs snapshot unavailable:[/] {logs['error']}")

    return "\n".join(lines)


def render_player_details(player: dict[str, Any] | None) -> str:
    if not player:
        return "\n".join(
            [
                f"[bold {ACCENT_GOLD}]Player Details[/]",
                "",
                f"[{ACCENT_MUTED}]No online players.[/]",
                "",
                f"[{ACCENT_MUTED}]See[/] [bold {ACCENT_GOLD}]Accounts[/]",
            ]
        )

    return "\n".join(
        [
            f"[bold {ACCENT_GOLD}]Player Details[/]",
            "",
            f"[{ACCENT_MUTED}]ID[/]         [bold {ACCENT_SKY}]{player.get('id', 0)}[/]",
            f"[{ACCENT_MUTED}]Username[/]   [bold {ACCENT_TEAL}]{player.get('username', '-')}[/]",
            f"[{ACCENT_MUTED}]GM Level[/]   {player.get('gm_level', 0)}",
            f"[{ACCENT_MUTED}]Online[/]     {'yes' if player.get('online') else 'no'}",
            f"[{ACCENT_MUTED}]Banned[/]     {'yes' if player.get('banned') else 'no'}",
            "",
            f"[{ACCENT_MUTED}]See[/] [bold {ACCENT_GOLD}]Accounts[/]",
        ]
    )


def render_account_details(account: dict[str, Any] | None, total_accounts: int) -> str:
    if not account:
        return "\n".join(
            [
                f"[bold {ACCENT_GOLD}]Account Details[/]",
                "",
                f"[{ACCENT_MUTED}]Accounts loaded:[/] {total_accounts}",
                "",
                f"[{ACCENT_MUTED}]Select an account row to inspect it.[/]",
            ]
        )

    return "\n".join(
        [
            f"[bold {ACCENT_GOLD}]Account Details[/]",
            "",
            f"[{ACCENT_MUTED}]ID[/]         [bold {ACCENT_SKY}]{account.get('id', 0)}[/]",
            f"[{ACCENT_MUTED}]Username[/]   [bold {ACCENT_TEAL}]{account.get('username', '-')}[/]",
            f"[{ACCENT_MUTED}]GM Level[/]   {account.get('gm_level', 0)}",
            f"[{ACCENT_MUTED}]Online[/]     {'yes' if account.get('online') else 'no'}",
            f"[{ACCENT_MUTED}]Banned[/]     {'yes' if account.get('banned') else 'no'}",
            "",
            f"[{ACCENT_MUTED}]Accounts loaded:[/] {total_accounts}",
            "",
            f"[{ACCENT_MUTED}]Mutation flows remain CLI-backed in this slice.[/]",
        ]
    )


def render_alerts_panel(snapshot: dict[str, Any]) -> str:
    server = snapshot["server"]
    lines = [f"[bold {ACCENT_GOLD}]Alerts and Events[/]", ""]

    if not server["ok"]:
        lines.append(f"[bold {ACCENT_ROSE}]Alerts unavailable:[/] {server['error']}")
        return "\n".join(lines)

    data = server["data"]
    alerts = data.get("alerts", {})
    active_alerts = alerts.get("active", [])
    recent_events = alerts.get("recent_events", [])

    lines.append(f"Overall  {format_state(alerts.get('status', 'healthy'))}")
    lines.append("")
    lines.append(f"[bold {ACCENT_SKY}]Active Alerts[/]")

    if active_alerts:
        for alert in active_alerts[:6]:
            lines.append(
                f"{format_state(alert.get('severity', 'warning'))} {alert.get('source', 'unknown')}: {alert.get('message', '')}"
            )
    else:
        lines.append(f"[bold {STATUS_COLORS['healthy']}]No active alerts[/]")

    lines.append("")
    lines.append(f"[bold {ACCENT_SKY}]Recent Events[/]")
    if recent_events:
        for event in recent_events[:8]:
            lines.append(f"{truncate_text(event.get('timestamp', ''), 19)} {event.get('service', 'unknown')}: {truncate_text(event.get('message', ''), 48)}")
    else:
        lines.append("No recent events in the last 30 minutes.")

    return "\n".join(lines)


def render_backups_summary(snapshot: dict[str, Any], selected_backup: dict[str, Any] | None) -> str:
    backups = snapshot.get("backups", {})
    summary = backups.get("summary", {})
    lines = [
        f"[bold {ACCENT_GOLD}]Backups[/]",
        "",
        f"[{ACCENT_MUTED}]Count[/]      {summary.get('count', 0)}",
        f"[{ACCENT_MUTED}]Directory[/]  {summary.get('backup_dir', 'n/a') or 'n/a'}",
    ]

    latest_file = summary.get("latest_file", "")
    if latest_file:
        lines.extend(
            [
                f"[{ACCENT_MUTED}]Latest[/]     {escape_markup(latest_file)}",
                f"[{ACCENT_MUTED}]When[/]       {iso_to_display(summary.get('latest_timestamp'))}",
                f"[{ACCENT_MUTED}]Size[/]       {format_bytes(summary.get('latest_size_bytes', 0))}",
            ]
        )
    else:
        lines.append(f"[{ACCENT_MUTED}]Latest[/]     none")

    if selected_backup:
        lines.extend(
            [
                "",
                f"[bold {ACCENT_SKY}]Selected Backup[/]",
                f"[{ACCENT_MUTED}]File[/]       {escape_markup(selected_backup.get('file', 'n/a'))}",
                f"[{ACCENT_MUTED}]When[/]       {iso_to_display(selected_backup.get('timestamp'))}",
                f"[{ACCENT_MUTED}]Size[/]       {format_bytes(selected_backup.get('size_bytes', 0))}",
                f"[{ACCENT_MUTED}]DBs[/]        {escape_markup(', '.join(selected_backup.get('databases', [])) or 'n/a')}",
                f"[{ACCENT_MUTED}]Created By[/] {escape_markup(selected_backup.get('created_by', 'n/a'))}",
                "",
                f"[{ACCENT_MUTED}]Action hotkeys:[/]",
                f"[bold {ACCENT_GOLD}]b[/]  run backup now --verify",
                f"[bold {ACCENT_GOLD}]v[/]  verify selected backup",
            ]
        )
    else:
        lines.extend(
            [
                "",
                f"[{ACCENT_MUTED}]No backup selected.[/]",
                "",
                f"[{ACCENT_MUTED}]Action hotkeys:[/]",
                f"[bold {ACCENT_GOLD}]b[/]  run backup now --verify",
                f"[bold {ACCENT_GOLD}]v[/]  verify selected backup",
            ]
        )

    return "\n".join(lines)


def render_config_panel(snapshot: dict[str, Any]) -> str:
    validate = snapshot["config_validate"]
    summary = snapshot.get("config_summary", {})
    content = snapshot.get("config_content", "")
    preview_lines = content.splitlines()[:16]
    preview = "\n".join(escape_markup(line) for line in preview_lines) if preview_lines else "No config content available."

    lines = [f"[bold {ACCENT_GOLD}]Config Overview[/]", ""]
    if validate["ok"]:
        valid = validate["data"].get("valid", True)
        lines.append(f"Validation  {format_state('healthy' if valid else 'critical')}")
    else:
        lines.append(f"[bold {ACCENT_ROSE}]Validation failed:[/] {validate['error']}")

    lines.extend(
        [
            "",
            f"[{ACCENT_MUTED}]Install Root[/]  {summary.get('install_root', 'n/a') or 'n/a'}",
            f"[{ACCENT_MUTED}]Auth Service[/]  {summary.get('auth_service', 'n/a') or 'n/a'}",
            f"[{ACCENT_MUTED}]World Service[/] {summary.get('world_service', 'n/a') or 'n/a'}",
            f"[{ACCENT_MUTED}]DB Host[/]       {summary.get('db_host', 'n/a') or 'n/a'}",
            f"[{ACCENT_MUTED}]DB User[/]       {summary.get('db_user', 'n/a') or 'n/a'}",
            f"[{ACCENT_MUTED}]Backup Dir[/]    {summary.get('backup_dir', 'n/a') or 'n/a'}",
            f"[{ACCENT_MUTED}]DB Names[/]      auth={summary.get('auth_db', 'n/a')} world={summary.get('world_db', 'n/a')} chars={summary.get('characters_db', 'n/a')} logs={summary.get('logs_db', 'n/a')}",
            "",
            f"[bold {ACCENT_SKY}]Config Preview[/]",
            preview,
        ]
    )
    return "\n".join(lines)


class DashboardRuntimeError(RuntimeError):
    """Raised when the dashboard runtime cannot start."""


def create_app(
    manager_bin: str,
    config_path: str,
    refresh: int,
    theme: str,
    screenshot_path: str | None,
):
    os.environ.setdefault("TEXTUAL_COLOR_SYSTEM", "truecolor")
    if screenshot_path:
        os.environ.pop("NO_COLOR", None)
    try:
        from textual.app import App, ComposeResult
        from textual.containers import Container, Horizontal, Vertical
        from textual.widgets import DataTable, Footer, Header, Static
    except ImportError as exc:
        raise DashboardRuntimeError(
            f"Textual runtime import failed: {exc}. Run 'vmangos-manager dashboard --bootstrap' first."
        ) from exc

    class VMangosDashboard(App[None]):
        CSS = """
        Screen {
            background: #06111d;
            color: #e6edf7;
        }

        Screen.theme-light {
            background: #f6f1e7;
            color: #142033;
        }

        Header {
            background: #1447a6;
            color: #f8fafc;
        }

        Screen.theme-light Header {
            background: #c9e1ff;
            color: #111827;
        }

        Footer {
            background: #0a2a43;
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
            width: 24;
            min-width: 24;
            border-right: heavy #f59e0b;
            background: #0b1726;
            padding: 1 1;
        }

        Screen.theme-light #sidebar {
            border-right: heavy #f59e0b;
            background: #eef6ff;
        }

        #content {
            width: 1fr;
            padding: 1 2;
        }

        .view {
            height: 1fr;
        }

        .hidden {
            display: none;
        }

        .panel {
            border: round #14b8a6;
            background: #102033;
            padding: 1 2;
            overflow: auto;
        }

        Screen.theme-light .panel {
            border: round #2563eb;
            background: #fffdf7;
        }

        #overview-grid {
            layout: grid;
            grid-size: 2 2;
            grid-columns: 1fr 1fr;
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
        }

        .table-detail-body {
            layout: vertical;
            height: 1fr;
            margin-top: 1;
        }

        .detail-table {
            width: 1fr;
        }

        .detail-pane {
            width: 1fr;
            height: 1fr;
            margin-top: 1;
            border-top: heavy #334155;
            padding-top: 1;
        }

        Screen.theme-light .detail-pane {
            border-top: heavy #93c5fd;
        }

        #players-table {
            height: 1fr;
        }

        #accounts-table {
            height: 12;
        }

        #accounts-layout,
        #backups-layout {
            height: 1fr;
            layout: vertical;
        }

        #backup-summary {
            height: auto;
            margin-bottom: 1;
        }

        #backups-table {
            height: 1fr;
        }

        #config-pane {
            height: 1fr;
        }
        """

        BINDINGS = [
            ("q", "quit", "Quit"),
            ("r", "manual_refresh", "Refresh"),
            ("s", "start_server", "Start"),
            ("x", "stop_server", "Stop"),
            ("R", "restart_server", "Restart"),
            ("b", "backup_now", "Backup"),
            ("v", "verify_selected_backup", "Verify"),
            ("1", "show_overview", "Overview"),
            ("2", "show_accounts", "Accounts"),
            ("3", "show_backups", "Backups"),
            ("4", "show_config", "Config"),
            ("t", "toggle_theme", "Theme"),
        ]

        def __init__(self) -> None:
            super().__init__()
            self.manager_bin = manager_bin
            self.config_path = config_path
            self.refresh_interval = refresh
            self.theme_name = theme
            self.screenshot_path = screenshot_path
            self.screenshot_taken = False
            self.screenshot_pending = False
            self.active_view = "overview"
            self.last_action = "dashboard started"
            self.snapshot = empty_snapshot("waiting for first refresh")
            self.selected_player_id = ""
            self.selected_account_id = ""
            self.selected_backup_file = ""
            self.refresh_inflight = False
            self.action_inflight = False

        def compose(self) -> ComposeResult:
            yield Header(show_clock=True)
            with Horizontal(id="shell"):
                yield Static("", id="sidebar")
                with Container(id="content"):
                    with Container(id="overview-view", classes="view"):
                        with Container(id="overview-grid"):
                            yield Static("", id="service-pane", classes="panel")
                            yield Static("", id="metrics-pane", classes="panel")
                            with Vertical(id="players-pane", classes="panel"):
                                yield Static("[b]Online Players[/b]", classes="table-detail-title")
                                yield DataTable(id="players-table")
                            yield Static("", id="player-details", classes="panel")
                    with Container(id="accounts-view", classes="view hidden"):
                        with Vertical(classes="panel table-detail", id="accounts-layout"):
                            yield Static("[b]Accounts[/b]", classes="table-detail-title")
                            with Horizontal(classes="table-detail-body"):
                                yield DataTable(id="accounts-table", classes="detail-table")
                                yield Static("", id="account-details", classes="detail-pane")
                    with Container(id="backups-view", classes="view hidden"):
                        with Horizontal(id="backups-layout"):
                            yield Static("", id="backup-summary", classes="panel")
                            yield DataTable(id="backups-table", classes="panel")
                    with Container(id="config-view", classes="view hidden"):
                        yield Static("", id="config-pane", classes="panel")
            yield Footer()

        def on_mount(self) -> None:
            players_table = self.query_one("#players-table", DataTable)
            players_table.cursor_type = "row"
            players_table.zebra_stripes = True
            players_table.add_columns("ID", "Username", "GM")

            accounts_table = self.query_one("#accounts-table", DataTable)
            accounts_table.cursor_type = "row"
            accounts_table.zebra_stripes = True
            accounts_table.add_columns("ID", "Username", "GM", "Online", "Banned")

            backups_table = self.query_one("#backups-table", DataTable)
            backups_table.cursor_type = "row"
            backups_table.zebra_stripes = True
            backups_table.add_columns("Timestamp", "Size", "File", "Created By")

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
            for view_name in ("overview", "accounts", "backups", "config"):
                widget = self.query_one(f"#{view_name}-view", Container)
                if view_name == self.active_view:
                    widget.remove_class("hidden")
                else:
                    widget.add_class("hidden")

            self.query_one("#sidebar", Static).update(render_sidebar(self.active_view, self.last_action))
            if self.active_view == "overview":
                self.set_focus(self.query_one("#players-table", DataTable))
            elif self.active_view == "accounts":
                self.set_focus(self.query_one("#accounts-table", DataTable))
            elif self.active_view == "backups":
                self.set_focus(self.query_one("#backups-table", DataTable))

        def request_snapshot_refresh(self) -> None:
            if self.refresh_inflight:
                return
            self.refresh_inflight = True
            threading.Thread(target=self.refresh_snapshot_worker, daemon=True).start()

        def refresh_snapshot_worker(self) -> None:
            try:
                snapshot = build_snapshot(self.manager_bin, self.config_path)
            except Exception as exc:
                snapshot = empty_snapshot(f"snapshot refresh failed: {exc}")
            self.call_from_thread(self.apply_snapshot, snapshot)

        def apply_snapshot(self, snapshot: dict[str, Any]) -> None:
            self.snapshot = snapshot
            self.refresh_inflight = False
            self.query_one("#service-pane", Static).update(render_service_panel(snapshot, self.active_view))
            self.query_one("#metrics-pane", Static).update(render_metrics_panel(snapshot))
            self.query_one("#config-pane", Static).update(render_config_panel(snapshot))
            self.refresh_players(snapshot.get("players", []))
            self.refresh_accounts(snapshot.get("all_accounts", []))
            self.refresh_backups(snapshot.get("backups", {}).get("entries", []))
            self.query_one("#sidebar", Static).update(render_sidebar(self.active_view, self.last_action))
            if self.screenshot_path and not self.screenshot_taken and not self.screenshot_pending:
                self.screenshot_pending = True
                self.set_timer(0.5, self.capture_screenshot_and_exit)

        def capture_screenshot_and_exit(self) -> None:
            self.screenshot_taken = True
            self.save_screenshot(self.screenshot_path)
            self.exit()

        def refresh_players(self, players: list[dict[str, Any]]) -> None:
            table = self.query_one("#players-table", DataTable)
            table.clear(columns=False)

            selected_index = 0
            for index, player in enumerate(players):
                player_id = str(player.get("id", ""))
                if self.selected_player_id and player_id == self.selected_player_id:
                    selected_index = index
                table.add_row(
                    str(player.get("id", "")),
                    str(player.get("username", "")),
                    str(player.get("gm_level", 0)),
                    key=player_id,
                )

            if players:
                current_player = players[selected_index]
                self.selected_player_id = str(current_player.get("id", ""))
                table.move_cursor(row=selected_index, column=0, animate=False)
                self.query_one("#player-details", Static).update(render_player_details(current_player))
            else:
                self.selected_player_id = ""
                self.query_one("#player-details", Static).update(render_player_details(None))

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

        def update_selected_player(self, row_key: Any) -> None:
            key_value = player_key_value(row_key)
            players = self.snapshot.get("players", [])
            player = next((candidate for candidate in players if str(candidate.get("id", "")) == key_value), None)
            if player is None and players:
                player = players[0]
            self.selected_player_id = str(player.get("id", "")) if player else ""
            self.query_one("#player-details", Static).update(render_player_details(player))

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

        def on_data_table_row_highlighted(self, event: DataTable.RowHighlighted) -> None:
            if event.data_table.id == "players-table":
                self.update_selected_player(event.row_key)
            elif event.data_table.id == "accounts-table":
                self.update_selected_account(event.row_key)
            elif event.data_table.id == "backups-table":
                self.update_selected_backup(event.row_key)

        def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
            if event.data_table.id == "players-table":
                self.update_selected_player(event.row_key)
            elif event.data_table.id == "accounts-table":
                self.update_selected_account(event.row_key)
            elif event.data_table.id == "backups-table":
                self.update_selected_backup(event.row_key)

        def action_show_overview(self) -> None:
            self.active_view = "overview"
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

        def action_manual_refresh(self) -> None:
            self.last_action = f"manual refresh at {datetime.now().strftime('%H:%M:%S')}"
            self.query_one("#sidebar", Static).update(render_sidebar(self.active_view, self.last_action))
            self.request_snapshot_refresh()

        def action_toggle_theme(self) -> None:
            self.theme_name = "light" if self.theme_name == "dark" else "dark"
            self.apply_theme()
            self.last_action = f"theme set to {self.theme_name}"
            self.apply_view_state()
            self.query_one("#service-pane", Static).update(render_service_panel(self.snapshot, self.active_view))

        def action_start_server(self) -> None:
            self.request_command_action("start", ["server", "start", "--wait", "--timeout", "60"])

        def action_stop_server(self) -> None:
            self.request_command_action("stop", ["server", "stop", "--timeout", "60"])

        def action_restart_server(self) -> None:
            self.request_command_action("restart", ["server", "restart", "--timeout", "60"])

        def action_backup_now(self) -> None:
            self.active_view = "backups"
            self.apply_view_state()
            self.request_command_action("backup", ["backup", "now", "--verify"])

        def action_verify_selected_backup(self) -> None:
            backups = self.snapshot.get("backups", {})
            summary = backups.get("summary", {})
            backup_dir = str(summary.get("backup_dir", ""))
            if not self.selected_backup_file or not backup_dir:
                self.last_action = "backup verify skipped: no backup selected"
                self.query_one("#sidebar", Static).update(render_sidebar(self.active_view, self.last_action))
                return

            backup_path = f"{backup_dir.rstrip('/')}/{self.selected_backup_file}"
            self.request_command_action("verify", ["backup", "verify", backup_path, "--level", "1"], refresh_after=False)

        def request_command_action(
            self,
            label: str,
            command: list[str],
            *,
            refresh_after: bool = True,
        ) -> None:
            if self.action_inflight:
                return
            self.action_inflight = True
            threading.Thread(
                target=self.run_command_action,
                args=(label, command, refresh_after),
                daemon=True,
            ).start()

        def run_command_action(self, label: str, command: list[str], refresh_after: bool) -> None:
            try:
                full_command = [self.manager_bin, "-c", self.config_path, *command]
                completed = subprocess.run(full_command, capture_output=True, text=True, check=False)
                output = (completed.stdout or completed.stderr or "").strip().splitlines()
                message = output[-1] if output else f"{label} exited with code {completed.returncode}"
                if completed.returncode == 0:
                    self.call_from_thread(self.set_action_result, f"{label}: {message}")
                    if refresh_after:
                        self.call_from_thread(self.request_snapshot_refresh)
                else:
                    self.call_from_thread(self.set_action_result, f"{label} failed: {message}")
            finally:
                self.action_inflight = False

        def set_action_result(self, message: str) -> None:
            self.last_action = message
            self.query_one("#sidebar", Static).update(render_sidebar(self.active_view, self.last_action))
            self.query_one("#service-pane", Static).update(render_service_panel(self.snapshot, self.active_view))

    return VMangosDashboard()


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    if args.snapshot_json:
        print(json.dumps(build_snapshot(args.manager_bin, args.config)))
        return 0

    try:
        app = create_app(args.manager_bin, args.config, args.refresh, args.theme, args.screenshot)
    except DashboardRuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    app.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
