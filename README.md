# RinkDesk (run-only)

No source code and no data dumps. `./start.sh --start` pulls Docker images
and starts the desk. This is the only `start.sh`.

Proprietary — © Maciej Hubisz. All rights reserved. Use, modify, fork, or
redistribute only with the author's written permission. See `LICENSE`.

## Windows (WSL + Docker)

1. PowerShell **as Administrator**: `wsl --install` (Ubuntu is fine). Reboot if asked.
2. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/)
   and turn on **Settings → Resources → WSL integration** for that distro.
3. Clone and start:

```powershell
git clone https://github.com/MaciejHubisz/rinkdesk-run.git
cd rinkdesk-run
.\scripts\windows.cmd --start
```

Browser: http://127.0.0.1:8765/ — sign in `admin` / `admin` (or `ref` / `ref`).

### Make protocols land in a shared Google Drive folder (Windows)

So new protocol PDFs are shared the moment they are written, run the one-time
helper once per PC (PowerShell **as Administrator** from `rinkdesk-run`):

```powershell
powershell -ExecutionPolicy Bypass -File scripts\Setup-ProtocolsDrive.ps1 `
  -OwnerEmail maciej@example.com -Share ref@example.com,trener@example.com
```

It installs official Google Drive for desktop, restricts sign-in to `-OwnerEmail`,
mounts My Drive as drive letter `-DriveLetter` (default `G`), and creates the
protocols folder + `_setup.txt` marker in My Drive. Expect exactly one interactive
Google login; everything else is automatic. If the drive was not ready yet, re-run
the same command (idempotent). One step stays manual: sharing the folder — Drive for
desktop cannot grant sharing from the CLI, so share the protocols folder once in the
browser window it opens (the share list is printed). Then point the app at it:

```powershell
.\scripts\windows.cmd --start --protocols-path "G:\My Drive\protocols"
```

See the top of `scripts\Setup-ProtocolsDrive.ps1` for all options.

## Linux / macOS / already inside WSL

```bash
./start.sh --start
```

Tab completion for the flags works like any other Linux command. Enable it
once by sourcing the completion script (add the line to your `~/.bashrc` to
make it permanent):

```bash
source scripts/start-completion.bash
# then ./start.sh --for<TAB> → --force-recreate / --force-pull
```

| Command | What it does |
|---|---|
| `./start.sh --start` | Pull images, start or resume, keep data |
| `./start.sh --start --export-path DIR` | Same, and bind snapshot exports to a local folder |
| `./start.sh --start --protocols-path DIR` | Same, and write generated protocol PDFs to a local folder |
| `./start.sh --start --force-pull` | Skip local build; pull from hub (fail if pull fails) |
| `./start.sh --force-recreate` | Wipe Postgres, pull, start empty |
| `./start.sh --stop` | Stop containers (data kept) |
| `./start.sh --manual` | How the desk works |

Without `--export-path`, snapshot JSON lives in the Docker volume `rinkdesk-exports`. With it, Settings → export writes into that folder (`archive/` plus the latest file) and copies each team’s logo PNG next to the JSON; import restores both. Pass the flag each time you start, or set `RINKDESK_EXPORTS_PATH`.

Protocol PDFs are written to the `protocols/` folder next to `start.sh` — always the same file per match, overwritten on every save. Pass `--protocols-path DIR` (or set `RINKDESK_PROTOCOLS_PATH`) to put them in another folder instead — e.g. `G:\My Drive\protocols` to share them via Google Drive (see the Windows setup above).

```bash
./start.sh --start --export-path ~/rinkdesk-exports
./start.sh --start --protocols-path ~/rinkdesk-protocols
```

```powershell
.\scripts\windows.cmd --start --export-path D:\rinkdesk-exports
.\scripts\windows.cmd --start --protocols-path D:\rinkdesk-protocols
```

Team logos: drop a PNG into the `team-logos/` folder next to `start.sh`, named
after the team short name (e.g. `orly_logo.png` for `ORŁY`). There is no upload
and no per-team field — a missing file simply shows a neutral "no logo" crest.
Export bundles those images with the JSON dump; import restores them. See
`team-logos/README.md`.

If pull fails, GHCR packages `rinkdesk-backend` and `rinkdesk-web` may still
be private — the publisher must set them Public.
