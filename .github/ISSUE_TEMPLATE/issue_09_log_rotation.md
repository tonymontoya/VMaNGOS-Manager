---
name: Issue #9 - Log Rotation
about: Configure log rotation for VMANGOS server logs
title: '[Release B] Log Rotation'
labels: 'release-b, enhancement, priority-medium'
assignees: ''
---

# Issue #9: Log Rotation

## Description
Configure system log rotation for VMANGOS server logs to prevent disk space exhaustion.

## Background
From live system analysis:
- 13 log file types in `/opt/mangos/logs/mangosd/`
- Log format: Timestamped entries (e.g., `2026-04-12 15:38:26`)
- Permissions: `mangos:mangos`, mode 644
- Logs grow continuously without rotation

## Log File Structure
```
/opt/mangos/logs/
├── mangosd/              # World server logs
│   ├── Server.log        # Main server log
│   ├── DBErrors.log      # Database errors
│   ├── Anticheat.log     # Anti-cheat events
│   ├── Bg.log            # Battleground events
│   ├── Char.log          # Character operations
│   ├── Chat.log          # Chat logging
│   ├── gm_critical.log   # GM critical actions
│   ├── LevelUp.log       # Character leveling
│   ├── Loot.log          # Loot distribution
│   ├── Movement.log      # Movement logging
│   ├── Network.log       # Network events
│   ├── Perf.log          # Performance metrics
│   ├── Ra.log            # RA console logging
│   ├── Scripts.log       # Script engine
│   └── Trades.log        # Trade transactions
├── realmd/               # Auth server logs
└── honor/                # Honor system logs
```

## Requirements

### Logrotate Configuration
Create `/etc/logrotate.d/vmangos`:

```
/opt/mangos/logs/*/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 644 mangos mangos
    sharedscripts
    postrotate
        # Signal services to reopen logs (if supported)
        /bin/kill -HUP $(pidof mangosd) 2>/dev/null || true
        /bin/kill -HUP $(pidof realmd) 2>/dev/null || true
    endscript
}
```

### CLI Integration
```bash
vmangos-manager logs rotate [--force]
vmangos-manager logs status
```

### Features
- [ ] Daily rotation
- [ ] Keep 30 days of history
- [ ] Compression of old logs
- [ ] Handle service log reload (SIGHUP)
- [ ] Create missing log files with correct permissions

### Installation
```bash
sudo cp logrotate/vmangos /etc/logrotate.d/
sudo chmod 644 /etc/logrotate.d/vmangos
sudo logrotate -d /etc/logrotate.d/vmangos  # Test config
```

## Testing
- [ ] Log rotation works manually (`logrotate -f`)
- [ ] Services continue logging after rotation
- [ ] Compressed logs readable (`zcat`)
- [ ] Old logs properly deleted after 30 days

## Estimated Effort
1 hour

## Dependencies
- Requires Release A (vmangos_setup.sh) complete
- Requires log files in `/opt/mangos/logs/`

## Related
- [RELEASE_B_PLAN.md](../../RELEASE_B_PLAN.md)
