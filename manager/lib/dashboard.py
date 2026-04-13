#!/usr/bin/env python3
"""Textual dashboard for VMANGOS Manager."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import threading
from datetime import datetime, timezone
from typing import Any


STATUS_COLORS = {
    "healthy": "green",
    "ok": "green",
    "active": "green",
    "warning": "yellow",
    "degraded": "yellow",
    "missing": "yellow",
    "stopped": "yellow",
    "inactive": "yellow",
    "critical": "red",
    "failed": "red",
    "crash-loop": "red",
    "unreachable": "red",
    "unavailable": "bright_black",
}


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="VMANGOS Manager Textual dashboard")
    parser.add_argument("--manager-bin", required=True, help="Path to vmangos-manager")
    parser.add_argument("--config", required=True, help="Path to manager.conf")
    parser.add_argument("--refresh", type=int, default=2, help="Refresh interval in seconds")
    parser.add_argument("--theme", choices=("dark", "light"), default="dark", help="Dashboard theme")
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


def run_manager_json(manager_bin: str, config_path: str, command: list[str]) -> dict[str, Any]:
    full_command = [manager_bin, "-c", config_path, "-f", "json", *command]
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
        data = parse_manager_json(completed.stdout)
    except (json.JSONDecodeError, RuntimeError) as exc:
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


def build_snapshot(manager_bin: str, config_path: str) -> dict[str, Any]:
    server = run_manager_json(manager_bin, config_path, ["server", "status"])
    logs = run_manager_json(manager_bin, config_path, ["logs", "status"])
    accounts = run_manager_json(manager_bin, config_path, ["account", "list", "--online"])

    return {
        "captured_at": now_iso(),
        "server": server,
        "logs": logs,
        "accounts": accounts,
        "players": accounts["data"].get("accounts", []) if accounts["ok"] else [],
    }


def clamp_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def format_mb_from_kb(value_kb: Any) -> str:
    value = clamp_int(value_kb)
    return f"{value / 1024:.1f} MB"


def format_gb_from_kb(value_kb: Any) -> str:
    value = clamp_int(value_kb)
    return f"{value / 1024 / 1024:.1f} GB"


def format_state(value: Any) -> str:
    text = str(value or "unknown")
    color = STATUS_COLORS.get(text, "white")
    return f"[bold {color}]{text}[/]"


def player_key_value(value: Any) -> str:
    candidate = getattr(value, "value", value)
    return "" if candidate is None else str(candidate)


def render_service_panel(snapshot: dict[str, Any], last_action: str) -> str:
    server = snapshot["server"]
    if not server["ok"]:
        return "\n".join(
            [
                "[b]Service Overview[/b]",
                "",
                f"[red]Server snapshot failed:[/] {server['error']}",
                "",
                "[b]Hotkeys[/b]",
                "r refresh  s start  x stop  shift+r restart  t theme  q quit",
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
            "[b]Service Overview[/b]",
            "",
            f"Auth   {format_state(auth.get('health', auth.get('state')))}  pid {auth.get('pid', 0)}  up {auth.get('uptime_human', 'N/A')}",
            f"World  {format_state(world.get('health', world.get('state')))}  pid {world.get('pid', 0)}  up {world.get('uptime_human', 'N/A')}",
            "",
            f"DB     {format_state('ok' if db.get('ok') else db.get('message', 'unreachable'))}",
            f"Users  [bold]{players.get('online', 0)}[/] online via {players.get('source', 'unavailable')}",
            "",
            f"Last action: {last_action}",
            "",
            "[b]Hotkeys[/b]",
            "r refresh  s start  x stop  shift+r restart  t theme  q quit",
        ]
    )


def render_metrics_panel(snapshot: dict[str, Any]) -> str:
    server = snapshot["server"]
    logs = snapshot["logs"]
    lines = ["[b]Host Metrics[/b]", ""]

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
                f"CPU      {cpu.get('usage_percent', 0)}%  {format_state(cpu.get('status', 'unavailable'))}  cores {cpu.get('cores', 0)}",
                f"Memory   {memory.get('used_percent', 0)}%  {format_state(memory.get('status', 'unavailable'))}  {format_mb_from_kb(memory.get('used_kb', 0))} used",
                f"Load     {load.get('load_1', 0)} / {load.get('load_5', 0)} / {load.get('load_15', 0)}  {format_state(load.get('status', 'unavailable'))}",
                f"Disk     {disk.get('used_percent', 0)}%  {format_state(disk.get('status', 'unavailable'))}  free {format_gb_from_kb(disk.get('available_kb', 0))}",
            ]
        )
        if storage_io.get("available"):
            lines.append(
                f"I/O      {storage_io.get('util_percent', 0)}% util  {format_state(storage_io.get('status', 'unavailable'))}  {storage_io.get('device', 'n/a')}"
            )
        else:
            lines.append(
                f"I/O      {format_state(storage_io.get('status', 'unavailable'))}  install sysstat/iostat for live disk stats"
            )
    else:
        lines.append(f"[red]Server metrics unavailable:[/] {server['error']}")

    lines.extend(["", "[b]Log Rotation[/b]"])
    if logs["ok"]:
        data = logs["data"]
        config = data.get("config", {})
        log_counts = data.get("logs", {})
        disk = data.get("disk", {})
        lines.extend(
            [
                f"Health   {format_state(data.get('status', 'unavailable'))}",
                f"Config   present={config.get('present', False)}  in_sync={config.get('in_sync', False)}",
                f"Files    active={log_counts.get('active_files', 0)}  rotated={log_counts.get('rotated_files', 0)}",
                f"Disk     {disk.get('used_percent', 0)}% used  free {format_gb_from_kb(disk.get('available_kb', 0))}",
            ]
        )
    else:
        lines.append(f"[red]Logs snapshot unavailable:[/] {logs['error']}")

    return "\n".join(lines)


def render_player_details(player: dict[str, Any] | None) -> str:
    if not player:
        return "[b]Player Details[/b]\n\nNo online players."

    return "\n".join(
        [
            "[b]Player Details[/b]",
            "",
            f"ID        {player.get('id', 0)}",
            f"Username  {player.get('username', '-')}",
            f"GM Level  {player.get('gm_level', 0)}",
            f"Online    {'yes' if player.get('online') else 'no'}",
            f"Banned    {'yes' if player.get('banned') else 'no'}",
        ]
    )


def render_alerts_panel(snapshot: dict[str, Any]) -> str:
    server = snapshot["server"]
    lines = ["[b]Alerts and Events[/b]", ""]

    if not server["ok"]:
        lines.append(f"[red]Alerts unavailable:[/] {server['error']}")
        return "\n".join(lines)

    data = server["data"]
    alerts = data.get("alerts", {})
    active_alerts = alerts.get("active", [])
    recent_events = alerts.get("recent_events", [])

    lines.append(f"Overall  {format_state(alerts.get('status', 'healthy'))}")
    lines.append("")
    lines.append("[b]Active Alerts[/b]")

    if active_alerts:
        for alert in active_alerts[:6]:
            lines.append(f"{format_state(alert.get('severity', 'warning'))} {alert.get('source', 'unknown')}: {alert.get('message', '')}")
    else:
        lines.append("[green]No active alerts[/]")

    lines.append("")
    lines.append("[b]Recent Events[/b]")
    if recent_events:
        for event in recent_events[:8]:
            timestamp = str(event.get("timestamp", ""))[-8:]
            lines.append(f"{timestamp} {event.get('service', 'unknown')}: {event.get('message', '')}")
    else:
        lines.append("No recent events in the last 30 minutes.")

    return "\n".join(lines)


class DashboardRuntimeError(RuntimeError):
    """Raised when the dashboard runtime cannot start."""


def create_app(manager_bin: str, config_path: str, refresh: int, theme: str):
    try:
        from textual.app import App, ComposeResult
        from textual.containers import Container, Vertical
        from textual.widgets import DataTable, Footer, Header, Static
    except ImportError as exc:
        raise DashboardRuntimeError(
            f"Textual runtime import failed: {exc}. Run 'vmangos-manager dashboard --bootstrap' first."
        ) from exc

    class VMangosDashboard(App[None]):
        CSS = """
        Screen {
            background: #08131f;
            color: #f8fafc;
        }

        Screen.theme-light {
            background: #f4efe3;
            color: #111827;
        }

        Header {
            background: #133b5c;
            color: #f8fafc;
        }

        Screen.theme-light Header {
            background: #d4e6f8;
            color: #111827;
        }

        Footer {
            background: #0f2538;
            color: #f8fafc;
        }

        Screen.theme-light Footer {
            background: #dbeafe;
            color: #111827;
        }

        #grid {
            layout: grid;
            grid-size: 2 2;
            grid-columns: 1fr 1fr;
            grid-rows: 1fr 1fr;
            grid-gutter: 1 2;
            height: 1fr;
            padding: 1 2;
        }

        .panel {
            border: round #2dd4bf;
            background: #0d1b2a;
            padding: 1 2;
            overflow: auto;
        }

        Screen.theme-light .panel {
            border: round #2563eb;
            background: #fffdf7;
        }

        #players-pane {
            layout: vertical;
        }

        #players-table {
            height: 1fr;
            margin-top: 1;
        }

        #player-details {
            height: 7;
            margin-top: 1;
            border-top: heavy #334155;
            padding-top: 1;
        }

        Screen.theme-light #player-details {
            border-top: heavy #93c5fd;
        }
        """

        BINDINGS = [
            ("q", "quit", "Quit"),
            ("r", "manual_refresh", "Refresh"),
            ("s", "start_server", "Start"),
            ("x", "stop_server", "Stop"),
            ("R", "restart_server", "Restart"),
            ("t", "toggle_theme", "Theme"),
        ]

        def __init__(self) -> None:
            super().__init__()
            self.manager_bin = manager_bin
            self.config_path = config_path
            self.refresh_interval = refresh
            self.theme_name = theme
            self.last_action = "dashboard started"
            self.snapshot = {
                "captured_at": now_iso(),
                "server": {"ok": False, "data": {}, "error": "waiting for first refresh"},
                "logs": {"ok": False, "data": {}, "error": "waiting for first refresh"},
                "accounts": {"ok": False, "data": {}, "error": "waiting for first refresh"},
                "players": [],
            }
            self.selected_player_id = ""
            self.refresh_inflight = False
            self.action_inflight = False

        def compose(self) -> ComposeResult:
            yield Header(show_clock=True)
            with Container(id="grid"):
                yield Static("", id="service-pane", classes="panel")
                yield Static("", id="metrics-pane", classes="panel")
                with Vertical(id="players-pane", classes="panel"):
                    yield Static("[b]Online Players[/b]")
                    yield DataTable(id="players-table")
                    yield Static("", id="player-details")
                yield Static("", id="alerts-pane", classes="panel")
            yield Footer()

        def on_mount(self) -> None:
            players_table = self.query_one("#players-table", DataTable)
            players_table.cursor_type = "row"
            players_table.zebra_stripes = True
            players_table.add_columns("ID", "Username", "GM", "Online", "Banned")
            self.apply_theme()
            self.set_focus(players_table)
            self.request_snapshot_refresh()
            self.set_interval(self.refresh_interval, self.request_snapshot_refresh)

        def apply_theme(self) -> None:
            self.remove_class("theme-light")
            self.remove_class("theme-dark")
            self.add_class(f"theme-{self.theme_name}")

        def request_snapshot_refresh(self) -> None:
            if self.refresh_inflight:
                return
            self.refresh_inflight = True
            threading.Thread(target=self.refresh_snapshot_worker, daemon=True).start()

        def refresh_snapshot_worker(self) -> None:
            snapshot = build_snapshot(self.manager_bin, self.config_path)
            self.call_from_thread(self.apply_snapshot, snapshot)

        def apply_snapshot(self, snapshot: dict[str, Any]) -> None:
            self.snapshot = snapshot
            self.refresh_inflight = False
            self.query_one("#service-pane", Static).update(render_service_panel(snapshot, self.last_action))
            self.query_one("#metrics-pane", Static).update(render_metrics_panel(snapshot))
            self.query_one("#alerts-pane", Static).update(render_alerts_panel(snapshot))
            self.refresh_players(snapshot.get("players", []))

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
                    "yes" if player.get("online") else "no",
                    "yes" if player.get("banned") else "no",
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

        def update_selected_player(self, row_key: Any) -> None:
            key_value = player_key_value(row_key)
            players = self.snapshot.get("players", [])
            player = next((candidate for candidate in players if str(candidate.get("id", "")) == key_value), None)
            if player is None and players:
                player = players[0]
            self.selected_player_id = str(player.get("id", "")) if player else ""
            self.query_one("#player-details", Static).update(render_player_details(player))

        def on_data_table_row_highlighted(self, event: DataTable.RowHighlighted) -> None:
            self.update_selected_player(event.row_key)

        def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
            self.update_selected_player(event.row_key)

        def action_manual_refresh(self) -> None:
            self.last_action = f"manual refresh at {datetime.now().strftime('%H:%M:%S')}"
            self.request_snapshot_refresh()

        def action_toggle_theme(self) -> None:
            self.theme_name = "light" if self.theme_name == "dark" else "dark"
            self.apply_theme()
            self.last_action = f"theme set to {self.theme_name}"
            self.query_one("#service-pane", Static).update(render_service_panel(self.snapshot, self.last_action))

        def action_start_server(self) -> None:
            self.request_server_action("start", ["--wait", "--timeout", "60"])

        def action_stop_server(self) -> None:
            self.request_server_action("stop", ["--timeout", "60"])

        def action_restart_server(self) -> None:
            self.request_server_action("restart", ["--timeout", "60"])

        def request_server_action(self, action_name: str, extra_args: list[str]) -> None:
            if self.action_inflight:
                return
            self.action_inflight = True
            threading.Thread(
                target=self.run_server_action,
                args=(action_name, extra_args),
                daemon=True,
            ).start()

        def run_server_action(self, action_name: str, extra_args: list[str]) -> None:
            try:
                command = [self.manager_bin, "-c", self.config_path, "server", action_name, *extra_args]
                completed = subprocess.run(command, capture_output=True, text=True, check=False)
                output = (completed.stdout or completed.stderr or "").strip().splitlines()
                message = output[-1] if output else f"{action_name} exited with code {completed.returncode}"
                if completed.returncode == 0:
                    self.call_from_thread(self.set_action_result, f"{action_name}: {message}")
                    self.call_from_thread(self.request_snapshot_refresh)
                else:
                    self.call_from_thread(self.set_action_result, f"{action_name} failed: {message}")
            finally:
                self.action_inflight = False

        def set_action_result(self, message: str) -> None:
            self.last_action = message
            self.query_one("#service-pane", Static).update(render_service_panel(self.snapshot, self.last_action))

    return VMangosDashboard()


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    snapshot = build_snapshot(args.manager_bin, args.config)

    if args.snapshot_json:
        print(json.dumps(snapshot))
        return 0

    try:
        app = create_app(args.manager_bin, args.config, args.refresh, args.theme)
    except DashboardRuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    app.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
