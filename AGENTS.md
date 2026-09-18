# rinkdesk-run — agent guide

Run-only checkout: pull the published images and run the desk. No app source
here (see [`../rinkdesk/AGENTS.md`](../rinkdesk/AGENTS.md) for the app).

| Path | What it is |
|---|---|
| `app.conf` | App identity (name, prefix, services, volumes, paths) read by the shared scripts |
| `start.sh` | Thin wrapper: runs `common/ops/start.sh` for this checkout |
| `scripts/setup-server-as-root.sh` | Thin wrapper: runs `common/ops/setup-server-as-root.sh` |
| `common/` | Submodule with the shared backend, web and ops framework |
| `scripts/admin/` | nginx site template + `admin.env` for the host script |
| `docker-compose.yml` | The stack the images run as |

The lifecycle and host logic live in `common/ops/` (a git submodule), parameterized
by `app.conf`. Edit `common/`, not copies in this repo; there are no local
`scripts/lib/` duplicates any more.

## The hard rule: host operations live in the host script

**Every setup or configuration operation on a host belongs in
`scripts/setup-server-as-root.sh`.** It is the single, root-run, idempotent
place where a machine is prepared: system packages, Homebrew, subuid range, user
namespaces, the `rinkdesk` alias, lingering, the registry login, the CI deploy
key, nginx/TLS, and installing the boot service (Phase 2). Read-only checks
(`--status`, `loginctl show-user`, logs) are fine to run by hand.

- Do **not** document or script host setup as loose commands in a README or a
  workflow. Point at the script instead:
  `sudo scripts/setup-server-as-root.sh USER [flags]`.
- New host setup, teardown, or configuration goes in that script, behind a flag,
  using the `step` / `step_ok` / `step_info` logging and staying safe to re-run.
- `start.sh` runs the desk; it is not for host preparation. It may *call* the
  host script's Phase 2 (`--install-service`), never reimplement it.
- When you add a host step, add it to the script first, then (if useful) one line
  in `README.md` / `scripts/manual.txt` that invokes the script.

## Conventions

- Every host setup or lifecycle change belongs in `common/ops/` (then bump the
  submodule), not in the wrappers here. Point at the wrapper commands in docs.
- App-specific values (names, services, volumes, paths) go in `app.conf`, never
  hardcoded in a script.
- Commit messages are short and lower-case, with a prefix: `start:`, `setup:`,
  `compose:`, `docs:`.
