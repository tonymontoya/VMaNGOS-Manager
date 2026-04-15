# Security

For normal usage guidance, see the [User Guide](user-guide.md). This page covers the safety model behind Manager's operational features.

---

## 🛡️ Security Model

VMANGOS Manager is intentionally conservative:

- **No positional passwords** — Passwords are never accepted as CLI positional arguments
- **Strict file permissions** — Password files must be mode `600`
- **Ownership checks** — Password files must be owned by root, the current user, or the invoking sudo user
- **Environment scrubbing** — `VMANGOS_PASSWORD` is unset immediately after use
- **Isolated hashing** — Password hashing does not forward `VMANGOS_PASSWORD` into the hashing subprocess
- **Audit trail** — Account actions emit structured audit log entries

---

## 🔑 Password Handling

| Method | Supported |
|---|---|
| Interactive prompt | ✅ |
| `--password-file PATH` | ✅ |
| `--password-env` | ✅ |
| Positional password arguments | ❌ |
| Plaintext passwords in command examples | ❌ |

---

## 🗄️ Database Access

Manager account management operates directly against the VMANGOS auth schema. This design enables:

- Full account listing
- GM level and ban state visibility
- Schema-aware password/verifier updates
- Deterministic test coverage

**Recommendation:** Use a least-privileged DB user with sufficient rights on:

- `auth`
- `characters`
- `world`
- `logs`

---

## 🔄 Update Model

Manager's update workflow is intentionally non-atomic. The recommended process is:

1. Review incoming changes
2. Take a verified backup
3. Test in a safe environment
4. Apply intentionally during a maintenance window

**Built-in safeguards:**

- Fetches remote metadata and compares commits explicitly
- Prints or executes explicit steps
- Fails closed when SQL changes fall outside the supported migration shape
- Rejects dirty or divergent source trees

---

## ✅ Operational Guidance

- Keep `/opt/mangos/manager/config/.dbpass` readable only by trusted operators
- Restrict MySQL network exposure to trusted hosts
- Prefer `sudo` for service-control and dashboard commands
- Review audit output after account changes
- Run `make test` before installing from a source checkout

---

## 🐛 Reporting

Report security-relevant defects via the [GitHub issue tracker](https://github.com/tonymontoya/VMANGOS-Manager/issues). Please include:

- The affected command
- Whether the issue occurred from a source checkout or installed copy
- A sanitized config snippet if relevant
- Reproduction steps without exposing secrets
