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

## Linux / macOS / already inside WSL

```bash
./start.sh --start
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

Protocol PDFs are written to the `protocols/` folder next to `start.sh` — always the same file per match, overwritten on every save. Pass `--protocols-path DIR` (or set `RINKDESK_PROTOCOLS_PATH`) to put them in another folder instead.

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
