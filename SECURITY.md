# SECURITY

## Release A Security Model

VMANGOS Manager Release A is intentionally conservative:

- passwords are not accepted as positional CLI arguments
- password files must be mode `600`
- password files must be owned by root, the current user, or the invoking sudo user
- `VMANGOS_PASSWORD` is unset after use
- password hashing is performed without forwarding `VMANGOS_PASSWORD` into the hashing subprocess environment
- account actions emit audit log entries

## Password Handling

Supported password input paths:

- interactive prompt
- `--password-file PATH`
- `--password-env`

Unsupported by design:

- positional password arguments
- plaintext password values embedded into normal command examples

## Database Access

Release A account management operates directly against the VMANGOS auth schema. This was chosen because Release A needs:

- full account listing
- GM level state
- ban state
- schema-aware password/verifier updates
- deterministic test coverage

The manager should use a least-privileged DB user that can perform the required operations on:

- `auth`
- `characters`
- `world`
- `logs`

## Git Update Model

Release A only provides `update check`.

It does not apply updates automatically. The command:

- fetches remote metadata
- compares local and remote commits
- prints manual steps

This non-atomic model is deliberate. Operators should review incoming changes, test them, then reinstall manager files intentionally.

## Operational Guidance

- keep `/opt/mangos/manager/config/.dbpass` readable only by trusted operators
- restrict MySQL network exposure to trusted hosts
- prefer running service-control commands with `sudo`
- review audit output after account changes
- run `make test` before installing from a source checkout

## Reporting

Use the GitHub issue tracker for security-relevant defects in this repository. Include:

- the affected command
- whether the issue was seen from a source checkout or an installed copy
- a sanitized config snippet if relevant
- reproduction steps without exposing secrets
