#!/usr/bin/env python3
"""Generate a reproducible demo snapshot for dashboard screenshots."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timedelta, timezone


def build_players() -> list[dict[str, object]]:
    players: list[dict[str, object]] = []
    for index in range(1, 51):
        players.append(
            {
                "id": 2000 + index,
                "username": f"RAIDER{index:02d}",
                "gm_level": 3 if index == 1 else (2 if index in (2, 3) else (1 if index % 9 == 0 else 0)),
                "online": True,
                "banned": False,
            }
        )
    return players


def build_accounts() -> list[dict[str, object]]:
    return [
        {"id": 2001, "username": "RAIDER01", "gm_level": 3, "online": True, "banned": False},
        {"id": 2002, "username": "RAIDER02", "gm_level": 2, "online": True, "banned": False},
        {"id": 2003, "username": "RAIDER03", "gm_level": 2, "online": True, "banned": False},
        {"id": 2012, "username": "CRAFTER12", "gm_level": 0, "online": False, "banned": False},
        {"id": 2024, "username": "BANKALT24", "gm_level": 0, "online": False, "banned": False},
        {"id": 2033, "username": "ARENA33", "gm_level": 1, "online": True, "banned": False},
        {"id": 2041, "username": "QUEST41", "gm_level": 0, "online": False, "banned": False},
        {"id": 2049, "username": "NIGHT49", "gm_level": 0, "online": True, "banned": False},
    ]


def build_metric_history(captured_at: datetime) -> list[dict[str, object]]:
    trend_rows = [
        (24.0, 48.0, 0.92, 23.0, 34.0, 16.0),
        (26.5, 49.0, 1.01, 23.0, 36.0, 18.0),
        (28.0, 50.0, 1.08, 23.0, 37.0, 17.0),
        (29.5, 51.0, 1.14, 23.0, 39.0, 18.5),
        (31.0, 52.0, 1.21, 23.0, 41.0, 19.5),
        (33.5, 54.0, 1.28, 23.0, 43.0, 21.0),
        (35.0, 55.0, 1.36, 24.0, 44.0, 22.0),
        (36.0, 57.0, 1.44, 24.0, 46.0, 23.0),
        (38.5, 58.0, 1.53, 24.0, 47.0, 24.5),
        (40.0, 60.0, 1.61, 24.0, 49.0, 26.0),
        (41.0, 61.0, 1.68, 24.0, 50.0, 27.5),
    ]
    history: list[dict[str, object]] = []
    total_rows = len(trend_rows)
    for index, (cpu, memory, load, disk, players, io_util) in enumerate(trend_rows):
        history.append(
            {
                "captured_at": (captured_at - timedelta(seconds=(total_rows - index) * 2)).isoformat(),
                "cpu": cpu,
                "memory": memory,
                "load": load,
                "disk": disk,
                "players": players,
                "io": io_util,
            }
        )
    return history


def build_backup_entries() -> list[dict[str, object]]:
    entries: list[dict[str, object]] = []
    sizes = [734003200, 723517440, 719323136, 716177408, 712982528, 709885952]
    for day_offset, size_bytes in enumerate(sizes):
        stamp = datetime(2026, 4, 14 - day_offset, 5, 10, tzinfo=timezone.utc).isoformat()
        entries.append(
            {
                "timestamp": stamp,
                "size_bytes": size_bytes,
                "file": f"vmangos-backup-202604{14 - day_offset:02d}-051000.tar.gz",
                "created_by": "schedule",
                "databases": ["auth", "characters", "world", "logs"],
            }
        )
    return entries


def build_snapshot() -> dict[str, object]:
    captured_at = datetime(2026, 4, 14, 5, 22, 18, tzinfo=timezone.utc)
    players = build_players()
    accounts = build_accounts()
    metric_history = build_metric_history(captured_at)
    backup_entries = build_backup_entries()
    config_content = (
        "[server]\n"
        "install_root=/opt/mangos\n"
        "auth_service=auth\n"
        "world_service=world\n\n"
        "[database]\n"
        "host=127.0.0.1\n"
        "user=vmangos\n"
        "auth_db=auth\n"
        "characters_db=characters\n"
        "world_db=world\n"
        "logs_db=logs\n\n"
        "[backup]\n"
        "backup_dir=/opt/mangos/backups\n"
    )
    schedules = [
        {
            "job_type": "restart",
            "schedule_type": "weekly",
            "day": "Sun",
            "time": "05:00",
            "timezone": "UTC",
            "id": "restart-weekly",
            "next_run": "2026-04-19 05:00 UTC",
            "warnings": "30,15,5,1",
            "announce_message": "Realm restart in progress soon.",
        },
        {
            "job_type": "honor",
            "schedule_type": "daily",
            "day": "",
            "time": "03:00",
            "timezone": "UTC",
            "id": "maintenance-daily",
            "next_run": "2026-04-15 03:00 UTC",
            "warnings": "none",
            "announce_message": "none",
        },
    ]

    return {
        "captured_at": captured_at.isoformat(),
        "config_path": "/opt/mangos/manager/config/manager.conf",
        "metric_history": metric_history,
        "server": {
            "ok": True,
            "error": "",
            "data": {
                "install_root": "/opt/mangos",
                "services": {
                    "auth": {
                        "service": "auth",
                        "state": "active",
                        "running": True,
                        "pid": 231004,
                        "uptime_seconds": 19842,
                        "uptime_human": "5h 30m",
                        "memory_mb": 11,
                        "cpu_percent": 0.7,
                        "health": "healthy",
                        "restart_count_1h": 0,
                        "crash_loop_detected": False,
                    },
                    "world": {
                        "service": "world",
                        "state": "active",
                        "running": True,
                        "pid": 231051,
                        "uptime_seconds": 19788,
                        "uptime_human": "5h 29m",
                        "memory_mb": 482,
                        "cpu_percent": 7.4,
                        "health": "healthy",
                        "restart_count_1h": 0,
                        "crash_loop_detected": False,
                    },
                },
                "checks": {
                    "database_connectivity": {"ok": True, "message": "ok"},
                    "disk_space": {
                        "ok": True,
                        "path": "/opt/mangos",
                        "filesystem": "/dev/nvme0n1p2",
                        "total_kb": 251658240,
                        "used_kb": 60397978,
                        "available_kb": 180879104,
                        "used_percent": 24,
                        "status": "ok",
                    },
                },
                "players": {"online": 50, "query_ok": True, "source": "auth.account.online"},
                "host": {
                    "cpu": {"usage_percent": 42.3, "status": "ok", "cores": 8},
                    "memory": {
                        "total_kb": 16777216,
                        "used_kb": 10485760,
                        "available_kb": 6291456,
                        "used_percent": 62.5,
                        "status": "ok",
                    },
                    "load": {"load_1": 1.74, "load_5": 1.52, "load_15": 1.31, "status": "ok"},
                },
                "storage_io": {
                    "available": True,
                    "device": "nvme0n1",
                    "source": "/dev/nvme0n1p2",
                    "read_ops_per_sec": 14.2,
                    "write_ops_per_sec": 33.8,
                    "read_kbps": 712.4,
                    "write_kbps": 1821.6,
                    "await_ms": 2.4,
                    "util_percent": 29.1,
                    "status": "ok",
                },
                "alerts": {
                    "status": "healthy",
                    "active": [],
                    "recent_events": [
                        {"timestamp": "05:18", "service": "world", "message": "backup verify dry-run completed", "raw": "backup verify dry-run completed"},
                        {"timestamp": "05:12", "service": "schedule", "message": "nightly maintenance task scheduled", "raw": "nightly maintenance task scheduled"},
                    ],
                },
            },
        },
        "logs": {
            "ok": True,
            "error": "",
            "data": {
                "status": "ok",
                "config": {"present": True, "in_sync": True},
                "logs": {"active_files": 8, "rotated_files": 21, "sensitive_permissions_ok": True},
                "disk": {"used_percent": 24, "available_kb": 180879104},
                "policy": {"max_size": "100M", "min_size": "1M"},
            },
        },
        "schedule_list": {"ok": True, "error": "", "data": {"schedules": schedules}},
        "update_check": {
            "ok": True,
            "error": "",
            "data": {
                "update_available": False,
                "branch": "main",
                "remote_ref": "origin/main",
                "commits_behind": 0,
                "worktree_dirty": False,
                "local_commit": "ebcd6f93d4112b3c0f89edefc47c3663c1a7555c",
                "remote_commit": "ebcd6f93d4112b3c0f89edefc47c3663c1a7555c",
            },
        },
        "update_inspect": {
            "ok": True,
            "error": "",
            "data": {
                "db_assessment": "no_changes",
                "db_automation_supported": False,
                "pending_migrations": [],
                "manual_review": [],
            },
        },
        "accounts_online": {"ok": True, "error": "", "data": {"accounts": players}},
        "accounts": {"ok": True, "error": "", "data": {"accounts": accounts}},
        "backup_list": {"ok": True, "error": "", "data": backup_entries},
        "backup_schedule_status": {
            "ok": True,
            "error": "",
            "data": {
                "configured_count": 1,
                "schedules": [
                    {
                        "id": "daily",
                        "timer": "vmangos-backup-daily.timer",
                        "present": True,
                        "enabled": True,
                        "active": True,
                        "configured": "daily 05:10",
                        "description": "Run VMANGOS backup daily at 05:10",
                        "next_run": "2026-04-15 05:10:00 UTC",
                        "timer_path": "/etc/systemd/system/vmangos-backup-daily.timer",
                    },
                    {
                        "id": "weekly",
                        "timer": "vmangos-backup-weekly.timer",
                        "present": False,
                        "enabled": False,
                        "active": False,
                        "configured": "n/a",
                        "description": "",
                        "next_run": "",
                        "timer_path": "/etc/systemd/system/vmangos-backup-weekly.timer",
                    },
                ],
            },
        },
        "config_validate": {"ok": True, "error": "", "data": {"valid": True, "issues": []}},
        "config_show": {"ok": True, "error": "", "data": {"content": config_content}},
        "config_summary": {
            "install_root": "/opt/mangos",
            "auth_service": "auth",
            "world_service": "world",
            "db_host": "127.0.0.1",
            "db_user": "vmangos",
            "auth_db": "auth",
            "characters_db": "characters",
            "world_db": "world",
            "logs_db": "logs",
            "backup_dir": "/opt/mangos/backups",
            "db_secret_source": "password_file",
        },
        "config_content": config_content,
        "backups": {
            "entries": backup_entries,
            "summary": {
                "count": 6,
                "backup_dir": "/opt/mangos/backups",
                "latest_file": "vmangos-backup-20260414-051000.tar.gz",
                "latest_timestamp": "2026-04-14T05:10:00+00:00",
                "latest_size_bytes": 734003200,
                "latest_created_by": "schedule",
                "database_count": 4,
            },
        },
        "players": players,
        "all_accounts": accounts,
        "schedules": schedules,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Generate a dashboard demo snapshot")
    parser.add_argument("--output", help="Write JSON to a file instead of stdout")
    args = parser.parse_args(argv)

    payload = json.dumps(build_snapshot(), indent=2)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as handle:
            handle.write(payload)
            handle.write("\n")
    else:
        sys.stdout.write(payload)
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
