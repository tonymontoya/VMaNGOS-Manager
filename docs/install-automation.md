# Install Automation

This guide covers the two installer entry points and how to adopt Manager onto an existing VMANGOS host. If you are new to Manager, start with the [User Guide](user-guide.md) for the full product walkthrough.

---

## 🎯 Two Entry Points

| Script | Style | Best For |
|---|---|---|
| `auto_install.sh` | Non-interactive, zero-touch | Fresh Ubuntu hosts; generated defaults |
| `vmangos_setup.sh` | Guided, interactive | Custom paths, DB names, or credentials |

Both target **Ubuntu 22.04 LTS**.

---

## 🛠️ What the Installer Handles

- Ubuntu package prerequisites (build tools, MariaDB client, Python, etc.)
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
wget https://raw.githubusercontent.com/tonymontoya/VMANGOS-Manager/main/auto_install.sh
wget https://raw.githubusercontent.com/tonymontoya/VMANGOS-Manager/main/vmangos_setup.sh
sudo bash auto_install.sh
```

**What happens:**
- Provisions `VMANGOS + Manager` by default
- Generates passwords stored in `/root/.vmangos-secrets/setup.conf`
- Logs all output to `/var/log/vmangos-install.log`
- Prints credentials and runtime paths at completion

**Reinstall safety:** If `/opt/mangos` already exists, the installer aborts unless you set `REINSTALL_POLICY="replace"` in `/root/.vmangos-secrets/setup.conf`.

### Guided Interactive Install

Use this when you want to choose values during install.

```bash
wget https://raw.githubusercontent.com/tonymontoya/VMANGOS-Manager/main/vmangos_setup.sh
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
