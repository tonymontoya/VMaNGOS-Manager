# Install Automation

This guide covers the raw installer scripts — the **advanced/headless path** — and how to adopt Manager onto an existing VMANGOS host. The primary install story is the wizard: `sudo vmangos-manager install` (see the [User Guide](user-guide.md)). Reach for these scripts when you cannot open a TUI or are driving provisioning from automation.

---

## 🎯 Two Entry Points

| Script | Style | Best For |
|---|---|---|
| `auto_install.sh` | Non-interactive, zero-touch | Fresh Ubuntu hosts; generated defaults |
| `vmangos_setup.sh` | Guided, interactive | Custom paths, DB names, or credentials |

Both target **Ubuntu 22.04/24.04/26.04 LTS** (MariaDB or MySQL 8.4).

---

## 🛠️ What the Installer Handles

- Ubuntu package prerequisites (build tools, MariaDB/MySQL client libraries, Python, etc.)
- VMANGOS source checkout and compilation
- MariaDB database creation and user grants
- Runtime path layout under the chosen install root
- Config generation for `realmd` and `mangosd`
- Client data staging and path normalization
- Optional Manager provisioning under `/opt/mangos/manager`
- Dashboard Python / Textual prerequisites when Manager is included

---

## 🚀 Fresh Host Installation

### Zero-Touch Bootstrap

This path generates secure passwords, picks sane defaults, and runs end-to-end without prompting.

```bash
wget https://raw.githubusercontent.com/tonymontoya/VMaNGOS-Manager/main/auto_install.sh
wget https://raw.githubusercontent.com/tonymontoya/VMaNGOS-Manager/main/vmangos_setup.sh
sudo bash auto_install.sh
```

**What happens:**
- Provisions `VMANGOS + Manager` by default
- Generates passwords stored in `/root/.vmangos-secrets/setup.conf`
- Logs all output to `/var/log/vmangos-install.log`
- Prints credentials and runtime paths at completion

**Reinstall safety:** If `/opt/mangos` already exists, the installer decides how to proceed: a partial install with checkpoints resumes from the last completed phase; an install without checkpoints follows `REINSTALL_POLICY` in `/root/.vmangos-secrets/setup.conf` (`abort` by default, or `replace` to wipe and reinstall).

**Install layout:** the realm owns the install root and the manager sits inside it — `/opt/mangos` and `/opt/mangos/manager`. Nested the other way round (a realm root at or under the manager's prefix, or the manager installed over a realm) the installer refuses before writing a single file; see [The installer refused my install root](troubleshooting.md#the-installer-refused-my-install-root).

### Guided Interactive Install

Use this when you want to choose values during install.

```bash
wget https://raw.githubusercontent.com/tonymontoya/VMaNGOS-Manager/main/vmangos_setup.sh
sudo bash vmangos_setup.sh
```

**Early prompts:**
- Provisioning target (`VMANGOS only` vs `VMANGOS + Manager`)
- Input mode (`Automated` vs `Guided`)

**Guided-only prompts:**
- Installation root
- Database names and credentials
- OS user
- Client data location

---

## 🏠 Existing Host Adoption

If VMANGOS is already installed and you mainly want the Manager experience:

```bash
cd manager
make test
sudo make install PREFIX=/opt/mangos/manager
sudo /opt/mangos/manager/bin/vmangos-manager config detect
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --bootstrap
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --refresh 2
```

The `config detect` command inspects your existing layout and prints a proposed `manager.conf`. It is read-only — nothing is overwritten until you confirm and copy the file into place.

---

## 🔧 Installer Features

- **Retry logic** — Network downloads and git clones retry with backoff
- **Checkpoint/resume** — Interrupted installs can resume from the last completed phase
- **Background build support** — Long compilations can run via `VMANGOS_BACKGROUND_BUILD=1` to prevent SSH timeouts
- **Optional mmaps skip** — `VMANGOS_SKIP_MMAPS=1` skips the hours-long movement-map generation (the server runs without NPC pathfinding); a test seam used by the install-wizard smoke, not needed for real installs
- **Explicit logging** — Everything is written to `/var/log/vmangos-install.log`

---

## ✅ Post-Install Checklist

Run these commands after installation finishes:

```bash
sudo /opt/mangos/manager/bin/vmangos-manager config validate
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --bootstrap
sudo /opt/mangos/manager/bin/vmangos-manager dashboard --refresh 2
```

For the full command reference, see the [CLI Reference](cli-reference.md).
