---
name: Issue #10 - Health Monitoring
about: Health checks and monitoring for VMANGOS services
title: '[Release B] Health Monitoring'
labels: 'release-b, enhancement, priority-high'
assignees: ''
---

# Issue #10: Health Monitoring

## Description
Implement health monitoring and alerting for VMANGOS server components.

## Background
From live system observation:
- World service restart loops detected (702 restarts/hour caused by DB config issue)
- Services can appear "active" in systemd but be non-functional
- Need proactive detection of issues before players are affected

## Requirements

### Health Check Components

| Check | Method | Alert Threshold |
|-------|--------|-----------------|
| Auth service | `systemctl is-active auth` | CRITICAL if inactive |
| World service | `systemctl is-active world` | CRITICAL if inactive |
| Service restarts | `journalctl` restart counter | WARNING if > 10/hour |
| Online players | `auth.account.online` query | Info only |
| Disk usage | `df /opt/mangos` | WARNING at 90%, CRITICAL at 95% |
| DB connectivity | `mysqladmin ping` | CRITICAL if unreachable |
| DB response time | Query timing | Log if > 1000ms |

### Database Schema
```sql
-- Health check results
CREATE TABLE vmangos_mgr.health_checks (
    id INT AUTO_INCREMENT PRIMARY KEY,
    checked_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    auth_active BOOLEAN NOT NULL,
    world_active BOOLEAN NOT NULL,
    auth_restarts_1h INT DEFAULT 0,
    world_restarts_1h INT DEFAULT 0,
    online_players INT DEFAULT 0,
    disk_usage_percent INT NOT NULL,
    disk_free_gb DECIMAL(6,2) NOT NULL,
    db_reachable BOOLEAN NOT NULL,
    db_response_ms INT,
    errors JSON,
    INDEX idx_checked_at (checked_at)
);

-- Alert history
CREATE TABLE vmangos_mgr.alerts (
    id INT AUTO_INCREMENT PRIMARY KEY,
    triggered_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    alert_type VARCHAR(64) NOT NULL,
    severity ENUM('info', 'warning', 'critical') NOT NULL,
    message TEXT NOT NULL,
    resolved_at TIMESTAMP NULL,
    INDEX idx_unresolved (resolved_at, severity)
);
```

### CLI Commands
```bash
vmangos-manager health check [--alert] [--format json]
vmangos-manager health status [--format json] [--last N]
vmangos-manager health alerts [--unresolved] [--resolve <id>]
```

### Health Check Output (JSON)
```json
{
  "success": true,
  "timestamp": "2026-04-12T15:30:00+00:00",
  "data": {
    "services": {
      "auth": {"active": true, "restarts_1h": 0},
      "world": {"active": true, "restarts_1h": 2}
    },
    "players": {"online": 42},
    "system": {
      "disk_usage_percent": 45,
      "disk_free_gb": 892.5
    },
    "database": {"reachable": true, "response_ms": 12}
  },
  "alerts": []
}
```

### Alert Conditions
| Condition | Severity | Action |
|-----------|----------|--------|
| world_active = false | CRITICAL | Log to syslog, record in alerts table |
| auth_active = false | CRITICAL | Log to syslog, record in alerts table |
| world_restarts_1h > 10 | WARNING | Record in alerts table |
| disk_usage_percent > 90 | WARNING | Record in alerts table |
| disk_usage_percent > 95 | CRITICAL | Log to syslog, record in alerts table |
| db_reachable = false | CRITICAL | Log to syslog, record in alerts table |

### Automation
- [ ] systemd timer for periodic checks (`vmangos-health.timer`)
- [ ] Check interval: Every 5 minutes
- [ ] Alert on check: `--alert` flag triggers alert evaluation

### Systemd Units
**Timer:** `/etc/systemd/system/vmangos-health.timer`
```ini
[Unit]
Description=VMANGOS Health Check Timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

**Service:** `/etc/systemd/system/vmangos-health.service`
```ini
[Unit]
Description=VMANGOS Health Check

[Service]
Type=oneshot
ExecStart=/opt/mangos/manager/bin/vmangos-manager health check --alert
User=root
```

### Configuration
```ini
[health]
enabled = true
check_interval_minutes = 5
disk_warning_percent = 90
disk_critical_percent = 95
restart_warning_threshold = 10
alert_methods = syslog
```

## Testing
- [ ] Health check records to database correctly
- [ ] Alert triggers on service stop
- [ ] Restart loop detection works
- [ ] Disk space warnings at correct thresholds
- [ ] JSON output valid and complete
- [ ] Unit tests > 90% coverage

## Estimated Effort
1-2 days

## Dependencies
- Requires Release A (vmangos_setup.sh) complete
- Requires running VMANGOS server for testing
- Requires `vmangos_mgr` database user

## Related
- [RELEASE_B_PLAN.md](../../RELEASE_B_PLAN.md)
- Issue #8 (Backup System) - shares systemd timer pattern
