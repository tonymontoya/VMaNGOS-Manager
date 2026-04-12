---
name: Issue #8 - Backup System
about: Database backup and restore functionality
title: '[Release B] Backup System'
labels: 'release-b, enhancement, priority-high'
assignees: ''
---

# Issue #8: Backup System

## Description
Implement automated database backup and restore functionality for VMANGOS server.

## Background
From live system testing:
- World DB: 150MB → 28MB compressed (4.25x ratio) in 1.3s
- Full backup of all databases: ~2s total
- MySQL binlog is OFF (incremental backups deferred to Release C)

## Requirements

### Core Features
- [ ] Full database backups (auth, characters, world, logs)
- [ ] Compression (gzip, configurable level)
- [ ] Checksum verification (SHA256)
- [ ] Metadata tracking in `vmangos_mgr.backups` table
- [ ] Backup restore functionality
- [ ] Automated pruning based on retention policy
- [ ] Pre-backup disk space checking

### CLI Commands
```bash
vmangos-manager backup create [--compress-level 6] [--no-lock]
vmangos-manager backup list [--format json] [--all|--active]
vmangos-manager backup restore <id> [--database <name>] [--verify-only]
vmangos-manager backup prune [--keep-days 7] [--dry-run]
vmangos-manager backup verify <id>
```

### Database Schema
```sql
CREATE TABLE vmangos_mgr.backups (
    id INT AUTO_INCREMENT PRIMARY KEY,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    type ENUM('full') DEFAULT 'full',
    databases JSON NOT NULL,
    size_bytes_raw BIGINT NOT NULL,
    size_bytes_compressed BIGINT NOT NULL,
    compression_ratio DECIMAL(4,2) NOT NULL,
    checksum VARCHAR(64) NOT NULL,
    path VARCHAR(512) NOT NULL,
    status ENUM('active', 'restoring', 'restored', 'expired', 'failed') DEFAULT 'active',
    expires_at TIMESTAMP NOT NULL,
    duration_seconds DECIMAL(6,2),
    INDEX idx_status (status),
    INDEX idx_expires (expires_at)
);
```

### Automation
- [ ] systemd timer for scheduled backups (`vmangos-backup.timer`)
- [ ] Default schedule: Daily at 03:00
- [ ] Configurable via `manager.conf`

### Configuration
```ini
[backup]
enabled = true
path = /opt/mangos/backups
retention_days = 7
compress_level = 6
schedule = 0 3 * * *
timeout_seconds = 300
```

## Security Considerations
- Backup files must have mode 600 (owner read/write only)
- Backup directory must be owned by `mangos` user
- Database credentials stored in secure defaults file
- Lock mechanism prevents concurrent backup/restore operations

## Testing
- [ ] Full backup → verify → restore cycle
- [ ] Checksum verification detects corruption
- [ ] Concurrent backup/operation locking works
- [ ] Disk full scenario handled gracefully
- [ ] Unit tests > 90% coverage

## Estimated Effort
2-3 days

## Dependencies
- Requires Release A (vmangos_setup.sh) complete
- Requires `vmangos_mgr` database user with SELECT, LOCK TABLES privileges

## Related
- [RELEASE_B_PLAN.md](../../RELEASE_B_PLAN.md)
